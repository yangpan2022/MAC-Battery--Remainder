# PowerGuard

给「当服务器用的 Mac 笔记本」做的小工具：**一断电、或者电量跌到 30% / 20% / 10% 的时候，立刻把提醒推到你的 iPhone 上。**

它由两部分组成，可以只用其中一部分：

| 部分 | 是什么 | 需要什么 |
| --- | --- | --- |
| **核心层** | 纯 Bash 写的监控 + 推送（`powerguard.sh` + `lib/`），零第三方依赖 | macOS 自带的 bash / osascript |
| **菜单栏 App** | 可选的可视化界面（`app/PowerGuard.app`）：状态显示、收件人管理、暂停/恢复、发测试消息 | macOS 13+ |

> **先说清楚一件事**：这个工具只能**提醒**你，救不了正在跑的服务器。
> 真要防意外断电，需要 UPS。另外，笔记本长期插着电当服务器会加速电池老化，
> 建议打开「优化电池充电」，或用 [AlDente](https://apphousekitchen.com/) 之类的工具限制充电上限。

---

## 目录

- [30 秒上手](#30-秒上手)
- [它会提醒你什么](#它会提醒你什么)
- [为什么走 iMessage（而不是系统通知）](#为什么走-imessage而不是系统通知)
- [安装](#安装)
- [权限设置（最关键的一步）](#权限设置最关键的一步)
- [管理收件人](#管理收件人)
- [配置文件](#配置文件)
- [命令行参考](#命令行参考)
- [菜单栏 App](#菜单栏-app)
- [日志与状态文件](#日志与状态文件)
- [出问题了自己查](#出问题了自己查)
- [卸载](#卸载)
- [常见问题](#常见问题)
- [已知限制](#已知限制)
- [给开发者](#给开发者)

---

## 30 秒上手

```bash
cd power-guard

# 1. 先看看它会做什么（不会改动系统）
./install.sh --dry-run

# 2. 真正安装（会问你收件人地址，并给你发一条测试消息自检）
./install.sh

# 3. 看状态
./powerguard.sh status
```

安装脚本会：把脚本拷到 `~/Library/Application Support/PowerGuard/cli/`、生成配置文件、
添加你给的收件人、**发一条测试消息**（这一步没收到就说明权限没给，见下一节）、
装载 launchd 后台服务（登录自动启动）、并把菜单栏 App 装到 `~/Applications/`。

全自动（无人值守）写法：

```bash
./install.sh --yes --recipient "you@icloud.com"
```

---

## 它会提醒你什么

| 事件 | 触发条件 | 默认 |
| --- | --- | --- |
| **断开电源** | 从接电变成用电池，且持续断开超过 `PG_AC_COOLDOWN`（默认 120 秒） | ✅ |
| **恢复供电** | 从用电池变回接电 | ✅ |
| **电量 30%** | 跌破 30% | ✅ |
| **电量 20%** | 跌破 20% | ✅ |
| **电量 10%** | 跌破 10% | ✅ |

两个防止「轰炸」的机制，都是实测过的：

- **阈值迟滞**：每个档位在一次放电中**只提醒一次**，电量回到「阈值 + `PG_HYSTERESIS`（默认 5）」以上才重新武装。
  所以 30% 报过之后，31% ↔ 30% 来回抖动不会重复报，要先回到 35% 以上才算数。
- **只报最低那档**：如果一次掉得太快（比如插着电的时候已经 12%，拔电后直接 11%），
  **只会发 10% 这一条**，不会把 30%/20%/10% 三条一次性补发给你。
- **断电去抖**：拔掉电源 120 秒内又插回去，不会报「断电」（手滑碰掉线不算事故）；
  但如果你在去抖窗口内又拔了，它会如实报出来。

可选：电量低于 `PG_ACTION_THRESHOLD`（默认 5%）时执行一条自定义命令（`PG_ACTION_COMMAND`）。
**默认关闭**——这条命令是直接执行的 shell，写错了会直接关掉你的服务器。

---

## 为什么走 iMessage（而不是系统通知）

很多人第一反应是「Mac 上弹个通知，iPhone 不就能收到吗」——**不能**。
Apple 只做了 iPhone → Mac 的镜像（iPhone Mirroring），反过来没有原生通道，
Mac 的通知不会跑到 iPhone 上。所以要做到「手机也能收到」，必须走一条外部通道，这里选了 iMessage。

选它的理由和注意事项：

- **免费**：iMessage（蓝色气泡）走流量，不花短信费。
- **发给自己最划算**：把**你自己的 Apple ID 邮箱**（例如 `you@icloud.com`）填进收件人，
  这条消息会同步到你的 iPhone / iPad / Apple Watch / 其它 Mac ——
  一次发送等于覆盖所有设备，**不需要**填好几个收件人。
- **绿色气泡要小心**：如果收件人是手机号、而且对方（或你自己）没开通 iMessage，
  消息会退化成运营商短信。在 Mac 上发短信需要 iPhone 开启「短信转发」，
  而且**可能产生短信费**。所以优先用 Apple ID 邮箱，不要用手机号。
- **多个收件人 = 逐条单发**：AppleScript 不能可靠地创建群聊，
  所以填了 3 个人就是发 3 条 1 对 1 消息。**发给别人，别人就会收到你的断电告警**，请谨慎。
- **系统通知仍然会发**：本机还会弹一条 macOS 通知（`PG_LOCAL_NOTIFY`），
  这样你人就在电脑旁边时能立刻看到。
- **备用通道**：万一以后 macOS 把 AppleScript 权限收得更紧，可以启用
  Bark / ntfy / 通用 Webhook（配置里留空即禁用）。默认全是关的。

如果所有远程通道都失败，它会**再补发一条本机通知**说明「推送失败」——不会静悄悄地什么都不说。

---

## 安装

### 系统要求

- macOS **11 或更新**（菜单栏 App 需要 **13+**；已在 macOS 13.0.1 上作为目标验证过，
  开发机在 macOS 26.6.2 上实测通过）。macOS 27 尚未发布，程序不写死版本判断，
  而是「多层探测 + 自动降级 + 失败大声报错」，遇到更新的系统会走兼容模式。
- 不需要 Homebrew、不需要 Python、不需要 Xcode。**只用 macOS 自带的工具。**
- Apple Silicon / Intel 都可以（菜单栏 App 是 arm64 + x86_64 通用二进制）。

### 三种装法

```bash
# A. 交互式（推荐）：会一步步问你
./install.sh

# B. 全自动
./install.sh --yes --recipient "you@icloud.com"

# C. 只看它要干什么，不动系统
./install.sh --dry-run
```

常用参数：

| 参数 | 作用 |
| --- | --- |
| `--yes` | 不提问，全用默认值 |
| `--recipient <地址>` | 预先添加收件人（可重复多次） |
| `--no-test` | 跳过「发测试消息自检」 |
| `--no-agent` | 只装文件，不装载后台服务 |
| `--no-app` | 不安装菜单栏 App |
| `--force-config` | 覆盖已存在的 `config.conf` |
| `--dry-run` | 只打印操作，不改动系统 |

> ⚠️ **不要用 sudo 运行。** sudo 会把服务和配置装到 `/var/root` 下，
> 那样菜单栏 App 和你的账号都读不到。脚本检测到 root 会直接拒绝执行。

### 一台完全陌生的 Mac 上，怎么确认真的装好了

安装脚本的最后一步是「发测试消息」，跑完后请按顺序确认：

1. 你的 iPhone 上收到了那条测试消息；
2. `./powerguard.sh status` 里「服务」显示**已装载**、「数据源」显示 `iokit`；
3. `./powerguard.sh logs 20` 里能看到「启动监控」和心跳日志。

三条都过了才算真的好了。

---

## 权限设置（最关键的一步）

PowerGuard 是通过 AppleScript 让「信息」App 帮你发消息的。
macOS 从 10.14 起就要求你**手工授权**这类控制，没给权限就会发送失败（错误码 `-1743`）。

第一次发消息时系统会弹窗问「是否允许…控制『信息』App」，**一定要点「好」**。
如果当时手滑点了「不允许」，或者压根没弹窗，就手动去开：

| 系统版本 | 路径 |
| --- | --- |
| **macOS 13 Ventura** | 系统偏好设置 → 安全性与隐私 → 隐私 → **自动化** → 找到「终端」/「PowerGuard」→ 勾选「信息」 |
| **macOS 14 / 15** | 系统设置 → 隐私与安全性 → **自动化** → 找到「终端」/「PowerGuard」→ 勾选「信息」 |
| **macOS 26** | 系统设置 → 隐私与安全性 → **自动化** → 找到「终端」/「PowerGuard」→ 勾选「信息」 |

另外两处权限（一般不用管，出问题再来看）：

- **通知**：想让本机弹横幅，需要在 系统设置 → 通知 里允许「终端」/「PowerGuard」发通知。
- **完全磁盘访问**：**不需要**。PowerGuard 不读你的文件。

授权之后随时可以重测：

```bash
./powerguard.sh test
```

### 「信息」App 本身也要是好的

- 必须**已登录 iMessage**（打开「信息」，随便发一条消息试试）；
- 发送时**「信息」App 会在后台短暂启动**，这是正常的（首次会慢 5～10 秒）；
- 如果一直卡住，先手工打开「信息」App 发一条消息，确认它能发出去。

---

## 管理收件人

三种方式，效果完全一样（都在往同一个文件里写）：

**① 菜单栏 App**（最方便）：点图标 → 收件人 → 添加收件人… / 移除某个地址。

**② 命令行**：

```bash
./powerguard.sh recipients list             # 列出
./powerguard.sh recipients add you@icloud.com   # 添加
./powerguard.sh recipients remove you@icloud.com # 删除
./powerguard.sh recipients open             # 用编辑器打开名单文件
```

**③ 直接编辑文件**：

```
~/Library/Application Support/PowerGuard/recipients.list
```

每行一个地址，`#` 开头是注释，空行会被忽略。改了**立刻生效**，不用重启。

> 强烈建议第一行填你自己的 Apple ID 邮箱。发给自己免费，而且所有苹果设备都会响。

---

## 配置文件

```
~/Library/Application Support/PowerGuard/config.conf
```

它其实是一段 bash 片段（`键=值`），**改完不用重启服务**——监控循环每一轮都会重新读它。
菜单栏 App 里有「打开配置文件」。关键项（完整注释见 `config.example`）：

| 键 | 默认值 | 说明 |
| --- | --- | --- |
| `PG_POLL_INTERVAL` | `20` | 每隔几秒读一次电源状态 |
| `PG_TH_30` / `PG_TH_20` / `PG_TH_10` | `30` / `20` / `10` | 三个低电量阈值（%），改成别的数字也行 |
| `PG_HYSTERESIS` | `5` | 迟滞：回升到「阈值 + 该值」才重新武装 |
| `PG_AC_COOLDOWN` | `120` | 断开电源持续多少秒才算「真断电」 |
| `PG_NOTIFY_AC_LOST` / `PG_NOTIFY_AC_RESTORE` / `PG_NOTIFY_THRESHOLD` | `true` | 各事件的推送开关 |
| `PG_LOCAL_NOTIFY` | `true` | 本机也弹通知 |
| `PG_LOCAL_SOUND` | `"Glass"` | 本机通知声音（留空 `""` 静音） |
| `PG_IMESSAGE_ENABLED` | `true` | iMessage 通道总开关 |
| `PG_BARK_URL` / `PG_NTFY_URL` / `PG_WEBHOOK_URL` | `""` | 备用通道，留空即禁用 |
| `PG_ACTION_ENABLED` | `false` | 低电量自动动作（危险，默认关） |
| `PG_ACTION_THRESHOLD` / `PG_ACTION_COMMAND` | `5` / `""` | 动作的阈值和命令 |
| `PG_LOG_RETENTION_DAYS` / `PG_LOG_MAX_KB` | `7` / `2048` | 日志保留天数 / 轮转大小 |
| `PG_VERBOSE` | `false` | 每次心跳都记日志（排错时临时打开） |
| `PG_HOSTNAME` | `""` | 通知标题里的主机名，留空自动取「电脑名称」 |

---

## 命令行参考

```bash
./powerguard.sh <命令> [参数]
```

| 命令 | 说明 |
| --- | --- |
| `status` | 看当前状态（电源、电量、剩余时间、温度、数据源、服务是否在跑） |
| `status --plain` | 输出 `key=value`，供菜单栏 App 解析 |
| `once` | 立刻检查一次（会按规则发通知，用于验证） |
| `test [地址]` | 发测试消息；不带地址就发给所有收件人 |
| `logs [行数]` | 看最近日志（默认 40 行） |
| `doctor [--save]` | 打印诊断报告（`--save` 同时存成文件） |
| `recipients list\|add\|remove\|open` | 收件人管理 |
| `on` / `off` | 恢复 / 暂停提醒（暂停时不推送，但仍采集状态） |
| `restart` | 重启后台服务 |
| `run` | 前台运行监控循环（由 launchd 调用） |
| `version` / `help` | 版本 / 帮助 |

`./powerguard.sh status` 输出示例：

```
PowerGuard 1.0.0 · MacBook Pro
  电源  🔌 已接入电源
  电量  100%（已充满）
  剩余  已充满
  温度  30.9 ℃
  来源  iokit（首选数据源）
  服务  ✅ 已装载
  ...
```

---

## 菜单栏 App

装了之后点菜单栏上的 🔌 / 🔋 图标就能看到状态。菜单里有：

- **状态**：电源、电量、剩余时间、温度、数据源、上次更新时间、上次提醒内容；
- **暂停提醒 / 恢复提醒**：对应 `off` / `on`；
- **立即检查一次**、**发送测试消息**；
- **收件人**：列出、添加（弹输入框）、移除；
- **后台服务**：启动 / 停止 / 重启；
- **登录时自动启动菜单栏**；
- **打开配置文件 / 打开日志 / 生成诊断报告**（报告会存到桌面）/ **选择 powerguard.sh…**（当脚本不在默认位置时）。

App 界面上的图标含义：

| 图标 | 含义 |
| --- | --- |
| 🔌 100% | 已接电源（数字是电量） |
| 🔋 63% | 正在用电池 |
| ⚠️ | 读不到电源数据（点开看详情，或跑 doctor） |

### 自己编译 App

仓库里已经有编好的 `app/PowerGuard.app`（arm64 + x86_64，部署目标 macOS 13.0，ad-hoc 签名）。
想自己编：

```bash
cd app
./build-app.sh              # 通用二进制
./build-app.sh --run        # 编完直接打开
./build-app.sh --no-universal   # 只编当前架构（快一些）
```

需要 Xcode 命令行工具（`xcode-select --install`），**不需要**完整 Xcode。
构建脚本会把命令行脚本一起打进 App，所以 `PowerGuard.app` 可以单独拷到别的 Mac 上用，
连「安装后台服务」都能在 App 菜单里直接完成。

---

## 日志与状态文件

```
~/Library/Application Support/PowerGuard/
├── cli/                 # 安装后的脚本本体（powerguard.sh、lib/、doctor.sh…）
├── config.conf          # 配置（权限 600）
├── recipients.list      # 收件人名单
├── state                # 运行状态（防止重复提醒用的，删掉会重新武装所有阈值）
├── disabled             # 存在这个文件 = 已暂停（powerguard.sh off 会创建它）
└── helpers/             # 自动生成的 AppleScript 小工具

~/Library/Logs/PowerGuard/
├── powerguard.log       # 主日志
├── launchd.out.log      # 后台服务的标准输出
└── launchd.err.log      # 后台服务的标准错误

~/Library/LaunchAgents/com.powerguard.agent.plist   # 后台服务定义
~/Applications/PowerGuard.app                       # 菜单栏 App
```

常见操作：

```bash
tail -f ~/Library/Logs/PowerGuard/powerguard.log    # 实时看日志
launchctl list com.powerguard.agent                 # 看服务状态（有 PID 就是在跑）
launchctl unload ~/Library/LaunchAgents/com.powerguard.agent.plist   # 临时停掉
launchctl load   ~/Library/LaunchAgents/com.powerguard.agent.plist   # 再启动
```

---

## 出问题了自己查

先跑这个，它会检查 11 项并生成一份可以直接贴出来的报告：

```bash
./doctor.sh              # 屏幕上打印
./doctor.sh --save       # 同时存到文件
```

常见症状：

| 症状 | 原因 | 怎么办 |
| --- | --- | --- |
| 一条消息都没收到 | 「自动化」权限没给 | 见[权限设置](#权限设置最关键的一步)，然后 `./powerguard.sh test` |
| 日志里 `-1743` / `Not authorized` | 同上（AppleScript 被拒绝） | 同上；改完权限后 `./powerguard.sh restart` |
| 日志里 `-1728` | 「信息」App 里找不到那个会话对象 | 先手工给该收件人发一条消息，让会话存在 |
| 日志里 `-600` | 「信息」App 没在运行 / 卡住了 | 手工打开「信息」，或 `killall Messages` 后重试 |
| 消息变成绿色（短信） | 收件人是手机号且不是 iMessage 用户 | 改成 Apple ID 邮箱 |
| 「状态」里「来源」是 `pmset` 或 `system_profiler` | 首选数据源 iokit 不可用，已自动降级 | 正常现象，不用管；若三路全失败会大声报错 |
| 电量不更新 / 恒为 100% | 不是笔记本，或数据源被系统改了 | 跑 `./doctor.sh`，把报告发出来 |
| 服务显示「未装载」 | launchd 没装载成功 | `launchctl load -w ~/Library/LaunchAgents/com.powerguard.agent.plist`，看报错 |
| 每小时都被提醒一次 | 阈值迟滞被反复触发 | 把 `PG_HYSTERESIS` 调大（例如 8） |
| 改了配置没生效 | 文件写错了（语法错误会被忽略并记警告） | `bash -n ~/Library/Application\ Support/PowerGuard/config.conf` |

---

## 卸载

```bash
# 停止并删掉后台服务、菜单栏 App（保留你的配置和日志）
./uninstall.sh

# 连配置、日志、收件人一起删干净
./uninstall.sh --purge --yes
```

装好之后也可以直接用安装目录里的那份：

```bash
~/Library/Application\ Support/PowerGuard/cli/uninstall.sh --purge --yes
```

---

## 常见问题

**Q：为什么不直接发系统通知，非要走 iMessage？**
Mac 的通知不会同步到 iPhone（Apple 只做了反方向）。见[上一节](#为什么走-imessage而不是系统通知)。

**Q：多个收件人会变成群聊吗？**
不会，是**逐个 1 对 1 单发**。AppleScript 创建群聊不可靠，所以没做。

**Q：费流量 / 费钱吗？**
iMessage 本身走网络、不收费。只有退化成运营商短信时才可能收费——所以用 Apple ID 邮箱，别用手机号。

**Q：会不会一直占着「信息」App？**
不会，发送完它就退回后台。发送前 `osascript` 有 20 秒超时保护，不会卡死监控循环。

**Q：断电 2 分钟才提醒，是不是太久了？**
`PG_AC_COOLDOWN` 默认 120 秒是防抖动（手滑碰掉电源线不该算事故）。
想更灵敏就改小，例如 `PG_AC_COOLDOWN=30`。

**Q：会不会很费电？**
每 20 秒读一次 `ioreg`（实测约 12 毫秒），基本可以忽略。

**Q：能不能顺便在低电量时自动关机/挂起任务？**
可以但**不建议**，所以默认关闭。确实需要就把 `PG_ACTION_ENABLED` 打开并写好 `PG_ACTION_COMMAND`，
自己先手工测一遍那条命令。

---

## 已知限制

- **它只是提醒，不是 UPS。** 断电就是断，进程该挂还是会挂。
- **AppleScript 通道随时可能被收紧。** macOS 一年比一年严，所以预留了 Bark / ntfy / Webhook 备用通道。
- **macOS 27 没有实机验证过**（写这个的时候还没发布）。程序不写死解析规则，
  而是按 `ioreg` → `pmset` → `system_profiler` 的顺序探测、失败自动降级、
  版本超出已验证范围会记一条警告，全失败会大声报错而不是假装正常。
- **只支持 macOS。** iPhone 端的推送依赖 macOS 上的「信息」App。

---

## 给开发者

- 全部代码兼容 **macOS 自带的 bash 3.2**（没有 `declare -A`、`mapfile`、`${var^^}`、`&>>`）。
  写 shell 时注意一个坑：**变量后面紧跟中文/全角符号必须写成 `${VAR}`**，
  否则 bash 3.2 会把中文字节当成变量名的一部分。批量修复：

  ```bash
  LANG=C perl -pi -e 's/\$([A-Za-z_][A-Za-z0-9_]*)(?=[\x80-\xFF])/\${$1}/g' *.sh lib/*.sh
  ```

- **不要用 `sudo` 跑测试**；脚本里所有路径都基于 `$HOME`。
- 想在仓库里测试而不污染真实环境，用环境变量重定向数据目录：

  ```bash
  export POWERGUARD_HOME="$PWD/.testhome/support"
  export POWERGUARD_LOGDIR="$PWD/.testhome/logs"
  ./powerguard.sh status
  ```

- 状态机（阈值迟滞、断电去抖、只报最低档、暂停、连续读取失败告警）有一套打桩冒烟测试，
  它会把 `pg_read_power` / `pg_notify` 换成假数据后逐轮驱动 `pg_monitor_tick`，
  跑完自动清掉临时目录（`PG_KEEP=1` 可以留着看现场）：

  ```bash
  /bin/bash tests/smoke-test.sh
  ```

  注意：`pg_monitor_tick` 每轮都会重新加载 `config.conf`，
  所以**测试里想把 `PG_*` 改掉，必须写进配置文件**，在 shell 里直接赋值会被覆盖。

- 数据源探测的真实结论（macOS 26 实测）：`ioreg -rn AppleSmartBattery -a`（XML 输出）
  已经失效，必须用文本解析；带空格的 `" = "` 才能把顶层键和嵌套 `BatteryData` 区分开。
  这正是保留三层探测的原因。

---

MIT License · PowerGuard 1.0.0
