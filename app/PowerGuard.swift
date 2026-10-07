// PowerGuard 菜单栏 App
// ---------------------------------------------------------------------------
// 一个没有 Dock 图标的菜单栏小程序，功能：
//   * 显示当前电源/电量，以及后台服务是否在跑
//   * 暂停 / 恢复提醒
//   * 增删 iMessage 收件人
//   * 发一条测试消息
//   * 立即检查一次、打开配置/日志/诊断报告
//   * 启动 / 停止后台监控服务
//   * 登录时自动启动
//
// 真正的检测逻辑全在 powerguard.sh 里，这个 App 只做三件事：
//   读（powerguard.sh status --plain）→ 显示 → 写（调用各种子命令）。
// 所以即使 App 挂了，后台服务照样会提醒你。
//
// 构建：见同目录 build-app.sh（swiftc 直接编，不需要 Xcode）
// 兼容：macOS 13.0+（Intel / Apple Silicon 通用二进制）
// ---------------------------------------------------------------------------

import AppKit
import Foundation

#if canImport(ServiceManagement)
import ServiceManagement
#endif

let PG_APP_VERSION = "1.0.0"
let PG_REFRESH_SECONDS: TimeInterval = 5.0

// ---------------------------------------------------------------------------
// 日志（写到 ~/Library/Logs/PowerGuard/menubar.log，方便排错）
// ---------------------------------------------------------------------------
let pgLogPath: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return home + "/Library/Logs/PowerGuard/menubar.log"
}()

func pgLog(_ message: String) {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(df.string(from: Date())) [MENUBAR] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let fm = FileManager.default
    let dir = (pgLogPath as NSString).deletingLastPathComponent
    if !fm.fileExists(atPath: dir) {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    if let fh = FileHandle(forWritingAtPath: pgLogPath) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        fm.createFile(atPath: pgLogPath, contents: data)
    }
}

// ---------------------------------------------------------------------------
// 路径
// ---------------------------------------------------------------------------
enum PGPaths {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static var supportDir: String { home + "/Library/Application Support/PowerGuard" }
    static var launchAgentsDir: String { home + "/Library/LaunchAgents" }
    static let agentLabel = "com.powerguard.agent"
    static var agentPlist: String { launchAgentsDir + "/" + agentLabel + ".plist" }

    /// 按优先级找一个可用的 powerguard.sh
    static func locateCLI() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []

        // 1) 用户手动指定过的
        if let saved = UserDefaults.standard.string(forKey: "cliPath"), !saved.isEmpty {
            candidates.append(saved)
        }
        // 2) 安装脚本放到数据目录里的正式副本（最稳）
        candidates.append(supportDir + "/cli/powerguard.sh")
        // 3) App 包内自带
        if let res = Bundle.main.resourcePath {
            candidates.append(res + "/powerguard.sh")
        }
        // 4) 开发布局：.../power-guard/app/PowerGuard.app → ../../powerguard.sh
        let bundle = Bundle.main.bundlePath as NSString
        let appDir = bundle.deletingLastPathComponent            // .../power-guard/app
        let cliDir = (appDir as NSString).deletingLastPathComponent  // .../power-guard
        candidates.append(cliDir + "/powerguard.sh")
        // 5) 常见手工位置
        for d in ["Desktop/power-guard", "Documents/power-guard", "Downloads/power-guard", "power-guard"] {
            candidates.append(home + "/" + d + "/powerguard.sh")
        }
        // 6) PATH
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                candidates.append(String(dir) + "/powerguard.sh")
            }
        }

        for c in candidates where fm.isExecutableFile(atPath: c) {
            return c
        }
        // 兜底：只要求文件存在（有些情况下可执行位会丢）
        for c in candidates where fm.fileExists(atPath: c) {
            return c
        }
        return nil
    }
}

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------
struct PGStatus {
    var fields: [String: String] = [:]

    private func raw(_ key: String) -> String { fields[key] ?? "" }

    var readOK: Bool { raw("read_ok") == "true" }
    var onAC: Bool { raw("on_ac") == "true" }
    var pct: Int { Int(raw("pct")) ?? -1 }
    var charging: Bool { raw("charging") == "true" }
    var full: Bool { raw("full") == "true" }
    var enabled: Bool { raw("enabled") != "false" }
    var agentLoaded: Bool { raw("agent_loaded") == "true" }
    var imessageEnabled: Bool { raw("imessage_enabled") != "false" }
    var stateCN: String { raw("state_cn") }
    var hostname: String { raw("hostname") }
    var provider: String { raw("provider") }
    var minutesText: String { raw("minutes_text") }
    var tempC: String { raw("temp_c") }
    var thresholds: String { raw("thresholds") }
    var pollInterval: String { raw("poll_interval") }
    var updatedAgo: String { raw("updated_ago") }
    var lastEvent: String { raw("last_event") }
    var lastEventAgo: String { raw("last_event_ago") }
    var recipientCount: Int { Int(raw("recipients")) ?? 0 }
    var configPath: String { raw("config") }
    var logPath: String { raw("log") }
    var recipientsPath: String { raw("recipients_path") }

    var batteryText: String {
        if pct < 0 { return "?" }
        return "\(pct)%"
    }

    /// 菜单栏上显示的文字
    var menuBarTitle: String {
        if !readOK { return "⚠️" }
        if onAC { return pct >= 0 ? "🔌 \(pct)%" : "🔌" }
        return pct >= 0 ? "🔋 \(pct)%" : "🔋"
    }

    /// 第一行摘要
    var summary: String {
        if !readOK { return "读不到电源状态" }
        var s = onAC ? "已接入电源" : "使用电池"
        if pct >= 0 { s += " · \(pct)%" }
        if full { s += "（已充满）" }
        else if charging { s += "（充电中）" }
        return s
    }
}

func pgParseStatus(_ text: String) -> PGStatus {
    var st = PGStatus()
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let idx = line.firstIndex(of: "=") else { continue }
        let key = String(line[line.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { st.fields[key] = value }
    }
    return st
}

func pgReadRecipients(path: String) -> [String] {
    guard !path.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var out: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var l = String(line).trimmingCharacters(in: .whitespaces)
        if l.isEmpty || l.hasPrefix("#") { continue }
        if let h = l.firstIndex(of: "#") { l = String(l[l.startIndex..<h]) }
        l = l.trimmingCharacters(in: .whitespaces)
        if !l.isEmpty { out.append(l) }
    }
    return out
}

// ---------------------------------------------------------------------------
// 调用命令行
// ---------------------------------------------------------------------------
enum PGCLI {
    /// 用 /bin/bash 执行一个脚本（脚本里用的是 bash 3.2 语法，必须交给 bash 跑）
    @discardableResult
    static func run(_ script: String, _ args: [String], timeout: TimeInterval = 30) -> (Int32, String) {
        return runRaw("/bin/bash", [script] + args, timeout: timeout)
    }

    /// 同步执行任意可执行文件（在后台队列里用），返回 (退出码, 合并后的输出)
    @discardableResult
    static func runRaw(_ executable: String, _ args: [String], timeout: TimeInterval = 30) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        // 和 lib/common.sh 里的策略保持一致：优先用系统自带工具
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        env["LANG"] = env["LANG"] ?? "zh_CN.UTF-8"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        do {
            try p.run()
        } catch {
            return (-1, "无法执行：\(error.localizedDescription)")
        }

        // 看门狗：卡住了就杀掉，避免 App 一直转圈
        let watchdog = DispatchWorkItem {
            if p.isRunning { p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()

        let out = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    }
}

// ---------------------------------------------------------------------------
// 主界面
// ---------------------------------------------------------------------------
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var status = PGStatus()
    private var cliPath: String?
    private var busy = false
    private var lastOutput = ""
    private let work = DispatchQueue(label: "com.powerguard.menubar.work")
    private var timer: Timer?

    // MARK: 生命周期
    func applicationDidFinishLaunching(_ notification: Notification) {
        pgLog("启动 PowerGuard 菜单栏 \(PG_APP_VERSION)")
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        statusItem.button?.toolTip = "PowerGuard"

        cliPath = PGPaths.locateCLI()
        if let c = cliPath {
            pgLog("使用命令行：\(c)")
        } else {
            pgLog("⚠️ 没有找到 powerguard.sh")
        }

        rebuildMenu()
        refresh()

        let t = Timer(timeInterval: PG_REFRESH_SECONDS, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func applicationWillTerminate(_ notification: Notification) {
        pgLog("退出")
    }

    // MARK: 刷新
    func refresh() {
        guard let cli = cliPath else {
            status = PGStatus()
            rebuildMenu()
            return
        }
        guard !busy else { return }
        busy = true
        work.async { [weak self] in
            let (code, out) = PGCLI.run(cli, ["status", "--plain"], timeout: 20)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                if code == 0 {
                    self.status = pgParseStatus(out)
                    self.lastOutput = out
                } else {
                    pgLog("status 失败（rc=\(code)）：\(out)")
                }
                self.rebuildMenu()
            }
        }
    }

    /// 执行一个子命令，完成后刷新并（可选）弹窗告知结果
    private func perform(_ args: [String], title: String, showAlert: Bool = false, then: (() -> Void)? = nil) {
        guard let cli = cliPath else { return }
        busy = true
        setStatusTitle("⏳")
        work.async { [weak self] in
            let (code, out) = PGCLI.run(cli, args, timeout: 60)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                pgLog("\(args.joined(separator: " ")) → rc=\(code)：\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                if showAlert {
                    self.showResult(title: title, ok: code == 0, text: out)
                }
                self.refresh()
                then?()
            }
        }
    }

    /// 执行一个独立脚本（install.sh / doctor.sh 这类）
    private func performScript(_ script: String, _ args: [String], title: String, showAlert: Bool = true) {
        busy = true
        setStatusTitle("⏳")
        work.async { [weak self] in
            let (code, out) = PGCLI.run(script, args, timeout: 180)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                pgLog("\(script) \(args.joined(separator: " ")) → rc=\(code)")
                if showAlert { self.showResult(title: title, ok: code == 0, text: out) }
                self.refresh()
            }
        }
    }

    private func setStatusTitle(_ s: String) {
        statusItem.button?.title = s
    }

    private func showResult(title: String, ok: Bool, text: String) {
        let alert = NSAlert()
        alert.messageText = ok ? "\(title)成功" : "\(title)失败"
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = body.isEmpty ? (ok ? "已完成。" : "没有更多信息，可打开日志查看。") : String(body.prefix(1500))
        alert.alertStyle = ok ? .informational : .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: 菜单
    private func rebuildMenu() {
        guard let button = statusItem.button else { return }
        button.title = busy ? "⏳" : status.menuBarTitle
        button.toolTip = status.readOK
            ? "PowerGuard · \(status.summary)\(status.agentLoaded ? "" : " · 后台服务未运行")"
            : "PowerGuard · 读不到电源状态"

        let menu = NSMenu()
        menu.autoenablesItems = false

        // --- 状态区 ---
        var head = status.summary
        if !status.hostname.isEmpty { head = status.hostname + " · " + head }
        menu.addItem(disabled(head))
        if status.readOK {
            var detail: [String] = []
            if !status.minutesText.isEmpty && status.minutesText != "未知" { detail.append("剩余 \(status.minutesText)") }
            if !status.tempC.isEmpty && status.tempC != "0" { detail.append("温度 \(status.tempC)°C") }
            if !status.provider.isEmpty { detail.append("数据源 \(status.provider)") }
            if !detail.isEmpty { menu.addItem(disabled(detail.joined(separator: " · "))) }
            menu.addItem(disabled("更新于 \(status.updatedAgo.isEmpty ? "—" : status.updatedAgo)"))
        }
        if !status.lastEvent.isEmpty {
            menu.addItem(disabled("上次提醒：\(lastEventCN(status.lastEvent)) · \(status.lastEventAgo)"))
        }
        menu.addItem(disabled(status.enabled ? "提醒：运行中（阈值 \(status.thresholds)%）" : "提醒：已暂停"))
        menu.addItem(disabled(status.agentLoaded ? "后台服务：运行中 ✅" : "后台服务：未运行 ⚠️"))

        menu.addItem(.separator())

        // --- 常用动作 ---
        menu.addItem(item(status.enabled ? "暂停提醒" : "恢复提醒", #selector(toggleEnabled)))
        menu.addItem(item("立即检查一次", #selector(checkNow)))
        menu.addItem(item("发送测试消息", #selector(sendTest)))

        // --- 收件人 ---
        let rcptList = pgReadRecipients(path: status.recipientsPath)
        let rcptItem = NSMenuItem(title: "收件人（\(rcptList.count)）", action: nil, keyEquivalent: "")
        let rcptMenu = NSMenu()
        rcptMenu.autoenablesItems = false
        if rcptList.isEmpty {
            rcptMenu.addItem(disabled("还没有收件人"))
        } else {
            for r in rcptList {
                let mi = NSMenuItem(title: "移除  \(r)", action: #selector(removeRecipient(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = r
                mi.isEnabled = !busy
                rcptMenu.addItem(mi)
            }
        }
        rcptMenu.addItem(.separator())
        rcptMenu.addItem(item("添加收件人…", #selector(addRecipient)))
        rcptMenu.addItem(disabled("提示：填自己的 Apple ID 邮箱最省事"))
        rcptItem.submenu = rcptMenu
        menu.addItem(rcptItem)

        menu.addItem(.separator())

        // --- 服务 ---
        menu.addItem(item(status.agentLoaded ? "停止后台服务" : "启动后台服务", #selector(toggleAgent)))
        if status.agentLoaded {
            menu.addItem(item("重启后台服务", #selector(restartAgent)))
        }
        let loginItem = NSMenuItem(title: "登录时自动启动菜单栏", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = launchAtLoginEnabled() ? .on : .off
        loginItem.isEnabled = !busy
        menu.addItem(loginItem)

        menu.addItem(.separator())

        // --- 打开文件 ---
        menu.addItem(item("打开配置文件", #selector(openConfig)))
        menu.addItem(item("打开日志", #selector(openLog)))
        menu.addItem(item("生成诊断报告…", #selector(runDoctor)))
        menu.addItem(item("选择 powerguard.sh…", #selector(pickCLI)))
        menu.addItem(item("重新加载", #selector(reloadNow)))

        menu.addItem(.separator())
        let about = disabled("PowerGuard \(PG_APP_VERSION)\(cliPath == nil ? " · ⚠️ 未找到命令行" : "")")
        menu.addItem(about)
        menu.addItem(item("退出菜单栏", #selector(quit)))

        statusItem.menu = menu
        if cliPath == nil {
            statusItem.button?.title = "⚠️"
        }
    }

    private func lastEventCN(_ e: String) -> String {
        switch e {
        case "power_lost": return "断电"
        case "power_restored": return "恢复供电"
        case "low_battery": return "低电量"
        default: return e
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.isEnabled = !busy
        return mi
    }

    // MARK: 动作
    @objc private func toggleEnabled() {
        perform(status.enabled ? ["off"] : ["on"], title: status.enabled ? "暂停提醒" : "恢复提醒")
    }

    @objc private func checkNow() {
        perform(["once"], title: "立即检查", showAlert: true)
    }

    @objc private func sendTest() {
        perform(["test"], title: "发送测试消息", showAlert: true)
    }

    @objc private func reloadNow() {
        refresh()
    }

    @objc private func addRecipient() {
        let alert = NSAlert()
        alert.messageText = "添加 iMessage 收件人"
        alert.informativeText = """
        推荐填你自己的 Apple ID 邮箱（例如 you@icloud.com）：
        发给自己完全免费，而且会自动同步到你的 iPhone / iPad / Apple Watch。

        也可以填别人的邮箱或 +86 手机号（手机号必须带 +86，发短信可能收费）。
        """
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "you@icloud.com 或 +8613800138000"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        perform(["recipients", "add", v], title: "添加收件人", showAlert: true)
    }

    @objc private func removeRecipient(_ sender: NSMenuItem) {
        guard let addr = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "移除收件人 \(addr) ？"
        alert.informativeText = "之后不会再给这个地址发提醒。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(["recipients", "remove", addr], title: "移除收件人", showAlert: true)
    }

    @objc private func toggleAgent() {
        if status.agentLoaded {
            perform(["off"], title: "暂停提醒")   // 先暂停，避免还在发通知
            pgLog("请求停止后台服务")
            let (rc, out) = PGCLI.runRaw("/bin/launchctl", ["unload", "-w", PGPaths.agentPlist], timeout: 15)
            pgLog("launchctl unload → rc=\(rc) \(out)")
            if rc != 0 {
                showResult(title: "停止后台服务", ok: false, text: out.isEmpty ? "launchctl unload 失败" : out)
            }
            refresh()
            return
        }
        if FileManager.default.fileExists(atPath: PGPaths.agentPlist) {
            let (rc, out) = PGCLI.runRaw("/bin/launchctl", ["load", "-w", PGPaths.agentPlist], timeout: 15)
            pgLog("launchctl load → rc=\(rc) \(out)")
            if rc != 0 {
                showResult(title: "启动后台服务", ok: false, text: out.isEmpty ? "launchctl load 失败" : out)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
            return
        }
        // 还没装过：跑一次安装脚本（不装 App、不测试、全自动）
        guard let cli = cliPath else { return }
        let dir = (cli as NSString).deletingLastPathComponent
        let installer = dir + "/install.sh"
        guard FileManager.default.fileExists(atPath: installer) else {
            showResult(title: "启动后台服务", ok: false, text: "没找到 \(installer)，请先在终端运行 ./install.sh")
            return
        }
        performScript(installer, ["--yes", "--no-app", "--no-test"], title: "安装后台服务")
    }

    @objc private func restartAgent() {
        perform(["restart"], title: "重启后台服务", showAlert: true)
    }

    @objc private func openConfig() {
        var path = status.configPath
        if path.isEmpty { path = PGPaths.supportDir + "/config.conf" }
        if !FileManager.default.fileExists(atPath: path) {
            // 第一次：从模板生成一份
            if let cli = cliPath {
                let dir = (cli as NSString).deletingLastPathComponent
                let example = dir + "/config.example"
                if FileManager.default.fileExists(atPath: example) {
                    try? FileManager.default.createDirectory(atPath: PGPaths.supportDir, withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(atPath: example, toPath: path)
                }
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openLog() {
        var path = status.logPath
        if path.isEmpty { path = PGPaths.home + "/Library/Logs/PowerGuard/powerguard.log" }
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            showResult(title: "打开日志", ok: false, text: "日志还不存在：\(path)")
        }
    }

    @objc private func runDoctor() {
        guard let cli = cliPath else { return }
        let dir = (cli as NSString).deletingLastPathComponent
        let doctor = dir + "/doctor.sh"
        guard FileManager.default.fileExists(atPath: doctor) else {
            showResult(title: "生成诊断报告", ok: false, text: "没找到 \(doctor)")
            return
        }
        busy = true
        setStatusTitle("⏳")
        work.async { [weak self] in
            let stamp = Int(Date().timeIntervalSince1970)
            let out = NSHomeDirectory() + "/Desktop/PowerGuard-诊断-\(stamp).txt"
            let (code, text) = PGCLI.run(doctor, ["--out", out], timeout: 120)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                if code == 0, FileManager.default.fileExists(atPath: out) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: out))
                } else {
                    self.showResult(title: "生成诊断报告", ok: false, text: text)
                }
                self.refresh()
            }
        }
    }

    @objc private func pickCLI() {
        let panel = NSOpenPanel()
        panel.title = "选择 powerguard.sh"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "cliPath")
        cliPath = url.path
        pgLog("手动指定命令行：\(url.path)")
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 登录项
    private func launchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            let svc = SMAppService.mainApp
            do {
                if svc.status == .enabled {
                    try svc.unregister()
                    pgLog("已关闭登录时自动启动")
                } else {
                    try svc.register()
                    pgLog("已开启登录时自动启动")
                }
            } catch {
                showResult(title: "设置登录项", ok: false,
                           text: "\(error.localizedDescription)\n\n可以把 PowerGuard.app 拖到「系统设置 → 通用 → 登录项」里手动添加。")
            }
            rebuildMenu()
        } else {
            showResult(title: "设置登录项", ok: false, text: "需要 macOS 13 或更高版本。")
        }
    }
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
@main
struct PowerGuardMain {
    static func main() {
        // 自检模式：不打开界面，只把解析到的状态打印出来（方便在终端里验证）
        if CommandLine.arguments.contains("--selftest") {
            let cli = PGPaths.locateCLI()
            print("cli=\(cli ?? "【未找到】")")
            guard let cli = cli else { exit(1) }
            let (code, out) = PGCLI.run(cli, ["status", "--plain"], timeout: 20)
            print("rc=\(code)")
            let st = pgParseStatus(out)
            print("menuBarTitle=\(st.menuBarTitle)")
            print("summary=\(st.summary)")
            print("agentLoaded=\(st.agentLoaded)")
            print("recipients=\(pgReadRecipients(path: st.recipientsPath))")
            print("--- 原始输出 ---")
            print(out)
            exit(code == 0 ? 0 : 1)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        _ = delegate   // 保住强引用
        app.run()
    }
}
