#!/bin/bash
# PowerGuard 安装脚本
#
#   ./install.sh                     交互式安装（推荐）
#   ./install.sh --yes               全自动，全用默认值
#   ./install.sh --recipient you@icloud.com --yes
#   ./install.sh --dry-run           只打印会做什么，不改动系统
#
# 它做的事：
#   1. 把命令行脚本拷到 ~/Library/Application Support/PowerGuard/cli/
#   2. 生成配置文件（已存在则不覆盖，除非 --force-config）
#   3. 添加 iMessage 收件人
#   4. 发一条测试消息自检（这一步很重要：没收到就说明权限没给）
#   5. 装载 launchd 后台服务（登录自动启动）
#   6. 把菜单栏 App 装到 ~/Applications/
#
# 不需要 sudo，请千万不要用 sudo 运行（那会把东西装到 /var/root 下）。

set -u

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$SRC_DIR/lib/common.sh" ]; then
  printf '❌ 找不到 %s/lib/common.sh，请在完整的 power-guard 目录里运行本脚本。\n' "$SRC_DIR" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
. "$SRC_DIR/lib/common.sh"
# providers.sh 提供 pg_detect_provider（下面要用它确认电池数据源可用）
# shellcheck source=lib/providers.sh
. "$SRC_DIR/lib/providers.sh"

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
ASSUME_YES=false
DRY_RUN=false
DO_TEST=true
DO_AGENT=true
DO_APP=true
DO_OPEN_APP=true
FORCE_CONFIG=false
RECIPIENTS=""
APP_SRC=""

usage() {
  cat <<'EOF'
用法：./install.sh [选项]

  --yes               全自动安装，不提问（用默认值）
  --recipient <地址>  预先添加一个 iMessage 收件人（可重复使用）
  --no-test           跳过"发测试消息"这一步
  --no-agent          只安装文件，不装载 launchd 后台服务
  --no-app            不安装菜单栏 App
  --no-open           装完不自动打开 App
  --force-config      覆盖已存在的 config.conf（默认保留你的配置）
  --app <路径>        指定要安装的 PowerGuard.app
  --dry-run           只打印将要执行的操作，不真正改动系统
  -h, --help          显示这份帮助

常用组合：
  ./install.sh --yes --recipient you@icloud.com
  ./install.sh --dry-run
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true ;;
    --dry-run) DRY_RUN=true ;;
    --no-test) DO_TEST=false ;;
    --no-agent) DO_AGENT=false ;;
    --no-app) DO_APP=false ;;
    --no-open) DO_OPEN_APP=false ;;
    --force-config) FORCE_CONFIG=true ;;
    --recipient)
      shift
      [ $# -gt 0 ] || { printf '❌ --recipient 后面要跟地址\n' >&2; exit 2; }
      RECIPIENTS="${RECIPIENTS}${1}"$'\n' ;;
    --app)
      shift
      [ $# -gt 0 ] || { printf '❌ --app 后面要跟路径\n' >&2; exit 2; }
      APP_SRC="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数：%s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# 输出小工具
# ---------------------------------------------------------------------------
step() { printf '\n── %s ─────────────────────────────\n' "$*"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '   ✅ %s\n' "$*"; }
warn() { printf '   ⚠️  %s\n' "$*"; }
die()  { printf '\n❌ %s\n' "$*" >&2; exit 1; }

# 执行命令；dry-run 时只打印
run() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '   [试运行] %s\n' "$*"
    return 0
  fi
  "$@"
}

# 提问，带默认值；--yes 或非交互时直接返回默认值
ask() {
  local prompt="$1" def="${2:-}" ans=""
  if [ "$ASSUME_YES" = "true" ]; then printf '%s' "$def"; return 0; fi
  if [ ! -t 0 ] && [ ! -e /dev/tty ]; then printf '%s' "$def"; return 0; fi
  if [ -n "$def" ]; then
    read -r -p "   $prompt [$def]: " ans </dev/tty 2>/dev/null || ans=""
  else
    read -r -p "   $prompt: " ans </dev/tty 2>/dev/null || ans=""
  fi
  printf '%s' "${ans:-$def}"
}

# 是否继续；$2 为默认答案（y/n）
confirm() {
  local prompt="$1" def="${2:-y}" ans=""
  if [ "$ASSUME_YES" = "true" ]; then
    [ "$def" = "y" ] && return 0 || return 1
  fi
  if [ ! -e /dev/tty ]; then [ "$def" = "y" ] && return 0 || return 1; fi
  read -r -p "   $prompt [$def] " ans </dev/tty 2>/dev/null || ans="$def"
  ans="${ans:-$def}"
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# ---------------------------------------------------------------------------
# 0. 环境检查
# ---------------------------------------------------------------------------
printf '%s\n' "PowerGuard ${PG_VERSION} 安装程序"
[ "$DRY_RUN" = "true" ] && printf '%s\n' "（试运行模式：不会改动任何东西）"

step "0/6 环境检查"

[ "$(uname -s)" = "Darwin" ] || die "这个工具只能在 macOS 上运行。"

if [ "$(id -u)" = "0" ]; then
  die "请不要用 sudo 运行。sudo 会把服务和配置装到 /var/root 下，用你自己的账号重新运行即可。"
fi

MACOS_VER="$(pg_macos_version)"
MACOS_MAJOR="$(pg_macos_major)"
info "macOS ${MACOS_VER}（$(uname -m)）"
if [ "${MACOS_MAJOR:-0}" -lt 11 ] 2>/dev/null; then
  die "需要 macOS 11 或更新版本。"
fi
if pg_is_newer_than_verified; then
  warn "macOS ${MACOS_MAJOR} 比已验证的最高版本（${PG_VERIFIED_MAX_MAJOR}）还新，已启用兼容探测模式。"
  warn "如果读数不对，请运行 doctor.sh 并把报告发出来。"
fi

BASH_VER="$(/bin/bash --version 2>/dev/null | head -1)"
info "${BASH_VER:-/bin/bash 版本未知}"

for tool in /usr/bin/osascript /usr/bin/curl /usr/bin/plutil /bin/launchctl; do
  [ -x "$tool" ] || die "缺少系统组件：$tool"
done
ok "系统组件齐全"

if [ -d /System/Applications/Messages.app ] || [ -d /Applications/Messages.app ]; then
  ok "找到「信息」App"
else
  warn "没找到「信息」App —— iMessage 提醒会失败，但本地通知仍可用。"
fi

# 电量数据源能用吗
PG_PROVIDER=""
pg_detect_provider
if [ "$?" -eq 2 ]; then
  warn "这台 Mac 没有电池（台式机）？后台服务仍会启动，但不会有电量提醒。"
elif [ -n "${PG_PROVIDER:-}" ]; then
  ok "电量数据源可用：${PG_PROVIDER}"
else
  warn "暂时读不到电池数据，安装后请用 doctor.sh 检查。"
fi

# ---------------------------------------------------------------------------
# 1. 安装命令行脚本
# ---------------------------------------------------------------------------
step "1/6 安装命令行脚本"

CLI_DIR="$PG_SUPPORT/cli"
CLI="$CLI_DIR/powerguard.sh"

info "目标目录：${CLI_DIR}"
run mkdir -p "$CLI_DIR/lib"

if [ "$DRY_RUN" != "true" ]; then
  for f in powerguard.sh doctor.sh uninstall.sh install.sh com.powerguard.plist config.example; do
    [ -f "$SRC_DIR/$f" ] && cp -f "$SRC_DIR/$f" "$CLI_DIR/$f"
  done
  for f in "$SRC_DIR"/lib/*.sh; do
    [ -f "$f" ] && cp -f "$f" "$CLI_DIR/lib/"
  done
  chmod +x "$CLI_DIR"/*.sh 2>/dev/null
  ok "已拷贝 $(ls "$CLI_DIR"/*.sh "$CLI_DIR"/lib/*.sh 2>/dev/null | wc -l | tr -d ' ') 个脚本"
else
  info "[试运行] 拷贝 powerguard.sh / doctor.sh / install.sh / uninstall.sh / lib/*.sh 到 ${CLI_DIR}"
fi

# ---------------------------------------------------------------------------
# 2. 配置文件
# ---------------------------------------------------------------------------
step "2/6 配置文件"

if [ -f "$PG_CONFIG" ] && [ "$FORCE_CONFIG" != "true" ]; then
  ok "已存在，保留你现有的配置：${PG_CONFIG}"
  info "（想重置成默认值：加 --force-config 重跑，或直接改这个文件）"
else
  if [ "$DRY_RUN" = "true" ]; then
    info "[试运行] 从 config.example 生成 ${PG_CONFIG}"
  else
    pg_ensure_dirs
    if [ -f "$SRC_DIR/config.example" ]; then
      cp -f "$SRC_DIR/config.example" "$PG_CONFIG"
    else
      printf '# PowerGuard 配置（默认值见 lib/common.sh）\n' > "$PG_CONFIG"
    fi
    chmod 600 "$PG_CONFIG" 2>/dev/null
    # 让当前进程用上新配置
    pg_load_config
    ok "已生成 ${PG_CONFIG}（权限 600，只有你自己能读）"
  fi
fi

# 日志和状态文件位置确认
if [ "$DRY_RUN" != "true" ]; then
  pg_ensure_dirs
  info "数据目录：${PG_SUPPORT}"
  info "日志文件：${PG_LOG}"
fi

# ---------------------------------------------------------------------------
# 3. 收件人
# ---------------------------------------------------------------------------
step "3/6 iMessage 收件人"

if [ "$ASSUME_YES" != "true" ] && [ "$DRY_RUN" != "true" ]; then
  printf '%s\n' "   填一个能收到 iMessage 的地址：手机号（+8613800138000）或 Apple ID 邮箱。"
  printf '%s\n' "   最推荐填你自己的 Apple ID 邮箱 —— 发给自己不要钱，而且会同步到你的"
  printf '%s\n' "   iPhone / iPad / Apple Watch / 这台 Mac 上，等于一次覆盖所有设备。"
  printf '%s\n' "   直接回车表示跳过（之后可以在菜单栏 App 里加，或改 recipients.list）。"
  n=0
  while [ "$n" -lt 5 ]; do
    addr="$(ask "收件人地址（回车结束）" "")"
    [ -n "$addr" ] || break
    RECIPIENTS="${RECIPIENTS}${addr}"$'\n'
    n=$((n + 1))
  done
fi

ADDED=0
SKIPPED=0
if [ -n "$RECIPIENTS" ]; then
  while IFS= read -r addr; do
    addr="$(printf '%s' "$addr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$addr" ] || continue
    if [ "$DRY_RUN" = "true" ]; then
      info "[试运行] 添加收件人 ${addr}"
      ADDED=$((ADDED + 1))
      continue
    fi
    case "$addr" in
      *@*) : ;;
      +*|[0-9]*) : ;;
      *) warn "看起来不像邮箱也不像手机号，仍然照加了：${addr}" ;;
    esac
    if /bin/bash "$CLI" recipients add "$addr" >/dev/null 2>&1; then
      ok "已添加 ${addr}"
      ADDED=$((ADDED + 1))
    else
      SKIPPED=$((SKIPPED + 1))
      warn "添加失败或已存在：${addr}"
    fi
  done <<< "$RECIPIENTS"
fi

if [ "$DRY_RUN" != "true" ]; then
  # 用 status --plain 里的 recipients= 拿准确数量（recipients list 带表头，不能数行数）
  RCOUNT="$(/bin/bash "$CLI" status --plain 2>/dev/null | awk -F= '/^recipients=/{print $2; exit}')"
  RCOUNT="$(printf '%s' "${RCOUNT:-0}" | tr -dc '0-9')"
  RCOUNT="${RCOUNT:-0}"
  if [ "$RCOUNT" -gt 0 ]; then
    ok "当前共 ${RCOUNT} 个收件人"
  else
    warn "还没有任何收件人 —— 提醒只会显示在本机通知中心，不会到手机。"
  fi
fi

# ---------------------------------------------------------------------------
# 4. 测试消息
# ---------------------------------------------------------------------------
step "4/6 测试消息（重要）"

if [ "$DO_TEST" != "true" ]; then
  info "已按 --no-test 跳过。"
elif [ "$DRY_RUN" = "true" ]; then
  info "[试运行] 执行 powerguard.sh test"
elif [ "${RCOUNT:-0}" -eq 0 ]; then
  info "没有收件人，跳过。"
else
  info "正在发送测试消息，请稍等（第一次可能要 10 秒左右）…"
  if /bin/bash "$CLI" test; then
    ok "测试消息已发出！请查看你的 iPhone / Mac 上的「信息」。"
  else
    printf '\n'
    warn "测试消息发送失败 —— 这几乎都是「自动化」权限没给。"
    printf '%s\n' "   请打开：系统设置 → 隐私与安全性 → 自动化"
    printf '%s\n' "   找到运行本脚本的程序（「终端」或「PowerGuard」），勾上「信息」。"
    printf '%s\n' "   如果你刚才看到过系统弹窗问「是否允许…控制信息 App」，要点「好」。"
    printf '%s\n' "   设置好之后随时可以重新测试："
    printf '     /bin/bash "%s" test\n' "$CLI"
    printf '\n'
    if ! confirm "权限没配好，仍然继续安装后台服务吗？（后台会每隔一段时间重试）" "y"; then
      die "已取消安装。修好权限后重新运行 ./install.sh 即可。"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. 后台服务（launchd）
# ---------------------------------------------------------------------------
step "5/6 后台监控服务"

if [ "$DO_AGENT" != "true" ]; then
  info "已按 --no-agent 跳过。"
else
  PLIST_SRC="$CLI_DIR/com.powerguard.plist"
  PLIST_DST="$HOME/Library/LaunchAgents/$PG_LABEL.plist"
  info "服务文件：${PLIST_DST}"

  if [ "$DRY_RUN" = "true" ]; then
    info "[试运行] 用真实路径替换 __PG_EXEC__ / __PG_OUT__ / __PG_ERR__ 并写入 ${PLIST_DST}"
    info "[试运行] launchctl unload -w ${PLIST_DST}（若已装载）"
    info "[试运行] launchctl load -w ${PLIST_DST}"
  else
    if [ ! -f "$PLIST_SRC" ]; then
      warn "找不到 plist 模板 ${PLIST_SRC}，跳过后台服务。"
    else
      mkdir -p "$HOME/Library/LaunchAgents"
      EXEC_X="$(xml_escape "$CLI")"
      OUT_X="$(xml_escape "$PG_LOGDIR/launchd.out.log")"
      ERR_X="$(xml_escape "$PG_LOGDIR/launchd.err.log")"
      # 用 | 作分隔符，因为路径里可能有 /
      sed -e "s|__PG_EXEC__|$EXEC_X|g" \
          -e "s|__PG_OUT__|$OUT_X|g" \
          -e "s|__PG_ERR__|$ERR_X|g" \
          "$PLIST_SRC" > "$PLIST_DST"

      if plutil -lint "$PLIST_DST" >/dev/null 2>&1; then
        ok "服务描述文件已生成"
      else
        warn "plutil 校验没通过，但还是先试着装载；失败请看 doctor.sh 报告。"
      fi

      # 先卸载旧的（忽略"没装载"的报错）
      launchctl unload -w "$PLIST_DST" >/dev/null 2>&1 || true
      pg_sleep 1

      # 注意：launchctl load 即使失败也常常返回 0（错误只打到 stderr），
      # 所以这里一律以「launchctl list 里能不能看到这个 label」为准。
      LOAD_OUT="$(launchctl load -w "$PLIST_DST" 2>&1 || true)"
      if ! launchctl list "$PG_LABEL" >/dev/null 2>&1; then
        BOOT_OUT="$(launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>&1 || true)"
        LOAD_OUT="${LOAD_OUT}${BOOT_OUT}"
      fi

      if launchctl list "$PG_LABEL" >/dev/null 2>&1; then
        ok "后台服务已装载（登录后会自动启动）"
      else
        warn "launchctl 没能装载这个服务。原样输出如下："
        printf '%s\n' "$LOAD_OUT" | sed 's/^/     /'
        printf '     手动重试：launchctl load -w "%s"\n' "$PLIST_DST"
        printf '     还是不行就看：%s\n' "$PG_LOGDIR/launchd.err.log"
      fi

      # 等一下看它是不是真的活着
      pg_sleep 4
      if launchctl list "$PG_LABEL" >/dev/null 2>&1; then
        AGENT_PID="$(launchctl list "$PG_LABEL" 2>/dev/null | awk -F'= ' '/"PID"/{gsub(/;/,"",$2); print $2}')"
        if [ -n "${AGENT_PID:-}" ]; then
          ok "服务正在运行（PID ${AGENT_PID}）"
        else
          warn "服务已登记但没在跑。看看日志：tail -20 \"$PG_LOGDIR/powerguard.log\""
        fi
      else
        warn "后台服务当前不在运行，请按上面的提示处理（或运行 doctor.sh）。"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 6. 菜单栏 App
# ---------------------------------------------------------------------------
step "6/6 菜单栏 App"

if [ "$DO_APP" != "true" ]; then
  info "已按 --no-app 跳过。"
else
  if [ -z "$APP_SRC" ]; then
    for cand in "$SRC_DIR/app/PowerGuard.app" "$SRC_DIR/PowerGuard.app"; do
      [ -d "$cand" ] && APP_SRC="$cand" && break
    done
  fi

  if [ -z "$APP_SRC" ] || [ ! -d "$APP_SRC" ]; then
    info "没有找到 PowerGuard.app（可以先运行 app/build-app.sh 生成）。"
    info "不影响使用：命令行和后台服务已经装好了。"
  else
    APP_DST="$HOME/Applications/PowerGuard.app"
    info "从 ${APP_SRC}"
    info "装到 ${APP_DST}"
    if [ "$DRY_RUN" = "true" ]; then
      info "[试运行] 拷贝 App 并清除隔离属性"
    else
      mkdir -p "$HOME/Applications"
      rm -rf "$APP_DST"
      if cp -R "$APP_SRC" "$APP_DST" 2>/dev/null; then
        xattr -cr "$APP_DST" 2>/dev/null || true
        ok "App 已安装"
        if [ "$DO_OPEN_APP" = "true" ] && confirm "现在就打开菜单栏 App 吗？" "y"; then
          open "$APP_DST" 2>/dev/null && ok "已打开，请看屏幕右上角菜单栏的 🔌/🔋 图标"
        fi
      else
        warn "拷贝失败，请手动把 PowerGuard.app 拖到「应用程序」文件夹。"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 完成
# ---------------------------------------------------------------------------
printf '\n%s\n' "════════════════════════════════════════════"
printf '%s\n' " 安装完成"
printf '%s\n' "════════════════════════════════════════════"
printf '\n%s\n' "常用命令（复制即用）："
printf '   看状态      /bin/bash "%s" status\n' "$CLI"
printf '   加收件人    /bin/bash "%s" recipients add 你的地址\n' "$CLI"
printf '   发测试消息  /bin/bash "%s" test\n' "$CLI"
printf '   暂停/恢复   /bin/bash "%s" off   /  on\n' "$CLI"
printf '   看日志      tail -30 "%s"\n' "$PG_LOG"
printf '   体检报告    /bin/bash "%s"\n' "$CLI_DIR/doctor.sh"
printf '   卸载        /bin/bash "%s" --purge --yes\n' "$CLI_DIR/uninstall.sh"
printf '\n%s\n' "文件位置："
printf '   配置        %s\n' "$PG_CONFIG"
printf '   收件人      %s\n' "$PG_SUPPORT/recipients.list"
printf '   日志        %s\n' "$PG_LOG"
printf '\n%s\n' "如果没收到提醒，按顺序检查："
printf '%s\n' "   1. 系统设置 → 隐私与安全性 → 自动化 → 允许「信息」"
printf '%s\n' "   2. 跑一次 doctor.sh，看「测试 iMessage」那一节"
printf '%s\n' "   3. 收件人如果填的是手机号、对方又不是 iMessage 用户，会变成短信（可能收费）"
printf '\n%s\n' "两点提醒："
printf '%s\n' "   · 这个工具只能「提醒」你，救不了正在跑的服务器。真要防断电，请配 UPS。"
printf '%s\n' "   · 长期插着电当服务器会加速电池老化，建议开「优化电池充电」或用 AlDente 限制充电上限。"
