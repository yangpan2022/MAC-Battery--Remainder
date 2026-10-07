#!/bin/bash
# PowerGuard 诊断工具
#   ./doctor.sh              在终端里打印一份体检报告
#   ./doctor.sh --save       另存为文件（默认桌面），方便发给别人看
#   ./doctor.sh --out <路径>  指定另存位置
#   ./doctor.sh --test       顺便发一条测试消息，验证 iMessage 通道
# 兼容 macOS 自带 bash 3.2，无外部依赖。
set -u

PG_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$PG_DIR/lib/common.sh"
# shellcheck source=lib/providers.sh
. "$PG_DIR/lib/providers.sh"
# shellcheck source=lib/notify.sh
. "$PG_DIR/lib/notify.sh"
# shellcheck source=lib/monitor.sh
. "$PG_DIR/lib/monitor.sh"

DO_SAVE=false
DO_TEST=false
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --save) DO_SAVE=true ;;
    --out) DO_SAVE=true; shift; OUT="${1:-}" ;;
    --test) DO_TEST=true ;;
    -h|--help)
      printf '%s\n' "用法：./doctor.sh [--save] [--out 路径] [--test]"
      exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

pg_ensure_dirs
pg_load_config

TMPREPORT="$(mktemp -t powerguard-doctor)" || exit 1
REPORT="$TMPREPORT"
trap 'rm -f "$TMPREPORT"' EXIT

say() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$REPORT"; }
# 把一段外部命令的输出逐行写进报告（注意：管道里的 while 在子 shell 里，
#  但 say 只往文件追加，所以子 shell 不影响结果）
say_block() {
  local indent="${1:-}" line
  while IFS= read -r line; do
    say "${indent}${line}"
  done
}
sec() { say ""; say "----------------------------------------------------------------"; say "$1"; say "----------------------------------------------------------------"; }
# 终端里中日韩字符占 2 列，printf 的 %-16s 只数字符，所以自己算显示宽度
disp_width() {
  local s="$1" chars bytes
  chars=$(printf '%s' "$s" | wc -m | tr -d ' ')
  bytes=$(printf '%s' "$s" | LC_ALL=C wc -c | tr -d ' ')
  case "$chars" in ''|*[!0-9]*) chars=0 ;; esac
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  printf '%s' $(( chars + ( bytes - chars ) / 2 ))
}

kv() {
  local label="${1:-}" val="${2:-}" w pad line
  w=$(disp_width "$label")
  pad=$(( 18 - w ))
  [ "$pad" -lt 1 ] && pad=1
  line="$(printf '  %s%*s %s' "$label" "$pad" '' "$val")"
  say "$line"
}

mask_str() {
  local s="${1:-}" n
  n=${#s}
  if [ "$n" -le 4 ]; then printf '***'; return; fi
  printf '%s***%s' "${s:0:2}" "${s:$(( n - 2 )):2}"
}

ioreg_val() {
  printf '%s\n' "${IOREG_LINE:-}" | grep -oE "\"$1\" = [^,]*" | head -1 | sed -E "s/^\"$1\" = //"
}

say "================================================================"
say " PowerGuard 诊断报告"
say " 生成时间：$(date '+%Y-%m-%d %H:%M:%S %z')"
say "================================================================"

# ---------------------------------------------------------------------------
sec "1. 基本信息"
kv "程序版本" "$PG_NAME $PG_VERSION"
kv "macOS" "$(pg_macos_version) (build $(pg_macos_build))"
kv "系统主版本" "$(pg_macos_major)"
if pg_is_newer_than_verified; then
  kv "兼容性" "⚠️ 系统版本高于已验证的 macOS ${PG_VERIFIED_MAX_MAJOR}，处于兼容模式"
else
  kv "兼容性" "✅ 在已验证范围内（≤ macOS ${PG_VERIFIED_MAX_MAJOR}）"
fi
kv "机型" "$(sysctl -n hw.model 2>/dev/null || echo 未知)"
kv "芯片" "$(sysctl -n machdep.cpu.brand_string 2>/dev/null | sed 's/^ *//' || echo 未知)"
kv "主机名" "$PG_HOSTNAME"
kv "当前用户" "$(id -un)"
kv "bash 版本" "${BASH_VERSION}（路径 ${BASH}）"
kv "有电池" "$( [ "$(pg_has_battery)" = "true" ] && echo 是 || echo '否 —— 这是台式机/无电池机型' )"

# ---------------------------------------------------------------------------
sec "2. 后台服务状态"
for pair in "$PG_LABEL:监控服务" "$PG_MENUBAR_LABEL:菜单栏 App"; do
  label="${pair%%:*}"
  name="${pair##*:}"
  plist="$PG_LAUNCHAGENTS/$label.plist"
  if [ -f "$plist" ]; then
    kv "$name" "已安装（${plist}）"
  else
    kv "$name" "未安装"
  fi
  if launchctl list "$label" >/dev/null 2>&1; then
    info="$(launchctl list "$label" 2>/dev/null | grep -E '"PID"|"LastExitStatus"' | tr -d '\n' | sed 's/[[:space:]]\+/ /g')"
    kv "" "launchd：已装载 $info"
  else
    kv "" "launchd：未装载"
  fi
done
if [ -f "$PG_DISABLED_FLAG" ]; then
  kv "提醒开关" "⏸ 已暂停（存在 ${PG_DISABLED_FLAG}）"
else
  kv "提醒开关" "▶️ 运行中"
fi
running="$(pgrep -fl 'powerguard.sh run' 2>/dev/null | head -3 || true)"
if [ -n "$running" ]; then
  kv "进程" "发现：$(printf '%s' "$running" | tr '\n' ' ')"
else
  kv "进程" "没有发现正在运行的 powerguard.sh run"
fi

# ---------------------------------------------------------------------------
sec "3. 数据源探测"
rc=0
pg_detect_provider; rc=$?
kv "选用数据源" "${PG_PROVIDER:-none}"
case "$rc" in
  0) kv "探测结果" "✅ 正常" ;;
  2) kv "探测结果" "⚠️ 没有检测到电池（台式机？）" ;;
  *) kv "探测结果" "❌ 所有数据源都失败了" ;;
esac

rc=0
pg_read_power || rc=$?
if [ "$PGV_OK" = "true" ]; then
  kv "读取" "✅ 成功"
  kv "接通电源" "$PGV_ON_AC"
  kv "电量" "$PGV_PCT %"
  kv "充电中" "$PGV_CHARGING"
  kv "已充满" "$PGV_FULL"
  kv "剩余时间" "${PGV_MINUTES} 分钟"
  kv "温度" "$PGV_TEMP_C ℃"
else
  kv "读取" "❌ 失败（rc=${rc}）"
fi

for p in iokit pmset sysprof; do
  rc=0
  pg_probe_with "$p"; rc=$?
  case "$rc" in
    0) kv "$p" "✅ OK=$PGV_OK AC=$PGV_ON_AC PCT=$PGV_PCT CHG=$PGV_CHARGING FULL=$PGV_FULL MIN=$PGV_MINUTES TEMP=$PGV_TEMP_C" ;;
    2) kv "$p" "⚠️ 没有电池" ;;
    *) kv "$p" "❌ 失败（rc=${rc}）" ;;
  esac
done

# ---------------------------------------------------------------------------
sec "4. 原始读数（排错用）"
if [ "$(pg_has_battery)" = "true" ]; then
  IOREG_LINE="$(pg_run_timeout 5 ioreg -rn AppleSmartBattery -w0 2>/dev/null || true)"
  if [ -n "$IOREG_LINE" ]; then
    say "  [ioreg -rn AppleSmartBattery -w0]"
    for k in ExternalConnected IsCharging FullyCharged CurrentCapacity MaxCapacity AppleRawCurrentCapacity AppleRawMaxCapacity DesignCapacity Amperage Voltage Temperature AvgTimeToEmpty TimeRemaining AvgTimeToFull BatteryInstalled PermanentFailureStatus; do
      v="$(ioreg_val "$k")"
      [ -n "$v" ] && kv "  $k" "$v"
    done
  else
    say "  [ioreg] 没有输出（这台机器可能读不到智能电池信息）"
  fi
fi

say ""
say "  [pmset -g batt]"
pm_out="$(pg_run_timeout 10 /usr/bin/pmset -g batt 2>&1 || true)"
if [ -n "$pm_out" ]; then
  printf '%s\n' "$pm_out" | say_block "    "
else
  say "    （没有输出，命令可能失败）"
fi

say ""
say "  [system_profiler SPPowerDataType] 关键行"
sp_out="$(pg_run_timeout 30 system_profiler SPPowerDataType 2>/dev/null || true)"
if [ -n "$sp_out" ]; then
  printf '%s\n' "$sp_out" | grep -E 'State of Charge|Charging|Fully Charged|Condition|Cycle Count|Current Power Source|Connected|Wattage' | sed 's/^ *//' | say_block "    "
else
  say "    （没有输出或超时）"
fi

# ---------------------------------------------------------------------------
sec "5. 文件与权限"
for p in "$PG_SUPPORT:数据目录" "$PG_LOGDIR:日志目录" "$PG_HELPERS:AppleScript 助手目录"; do
  d="${p%%:*}"
  label="${p##*:}"
  if [ -d "$d" ]; then
    if [ -w "$d" ]; then kv "$label" "✅ 可写  $d"
    else kv "$label" "❌ 不可写  $d"; fi
  else
    kv "$label" "❌ 不存在  $d"
  fi
done
kv "配置文件" "$( [ -f "$PG_CONFIG" ] && echo "存在  $PG_CONFIG" || echo "不存在（会用默认值）" )"
kv "收件人文件" "$( [ -f "$PG_RECIPIENTS" ] && echo "存在  $PG_RECIPIENTS" || echo "不存在" )"
if [ -f "$PG_CONFIG" ]; then
  if /bin/bash -n "$PG_CONFIG" 2>/dev/null; then
    kv "配置语法" "✅ 正常"
  else
    kv "配置语法" "❌ 有语法错误（当前被忽略，用的是默认值！）"
  fi
fi

# ---------------------------------------------------------------------------
sec "6. 配置（密钥已隐藏）"
if [ -f "$PG_CONFIG" ]; then
  while IFS= read -r line; do
    case "$line" in
      *URL=*)
        key="${line%%=*}"
        val="${line#*=}"
        if [ -n "$(printf '%s' "$val" | tr -d "\"' ")" ]; then
          say "  ${key}=<已设置，已隐藏>"
        else
          say "  ${key}="
        fi ;;
      *) say "  $line" ;;
    esac
  done < "$PG_CONFIG"
else
  say "  （没有配置文件，全部使用默认值）"
fi

# ---------------------------------------------------------------------------
sec "7. 通知通道"
kv "iMessage" "$PG_IMESSAGE_ENABLED"
kv "本机通知" "${PG_LOCAL_NOTIFY}（声音：${PG_LOCAL_SOUND:-无}）"
kv "Bark" "$( [ -n "$PG_BARK_URL" ] && printf '已配置' || printf '未配置' )"
kv "ntfy" "$( [ -n "$PG_NTFY_URL" ] && printf '已配置' || printf '未配置' )"
kv "Webhook" "$( [ -n "$PG_WEBHOOK_URL" ] && printf '已配置' || printf '未配置' )"
n="$(pg_recipients_count)"
kv "收件人数量" "$n"
if [ "$n" != "0" ]; then
  pg_recipients | while IFS= read -r r; do
    say "    - $(mask_str "$r")"
  done
fi
kv "Messages.app" "$( [ -d /System/Applications/Messages.app ] && echo '存在' || echo '找不到！' )"

# ---------------------------------------------------------------------------
sec "8. AppleScript 助手自检"
pg_ensure_helpers
for f in notify imessage_buddy imessage_participant imessage_chat; do
  src="$PG_HELPERS/$f.applescript"
  if [ ! -f "$src" ]; then kv "$f" "❌ 缺少 $src"; continue; fi
  out="$(mktemp -t pgscpt)"
  rc=0
  pg_run_timeout 30 /usr/bin/osacompile -o "$out" "$src" >/dev/null 2>&1 || rc=$?
  rm -f "$out"
  if [ "$rc" = "0" ]; then kv "$f.applescript" "✅ 可编译"
  elif [ "$rc" = "137" ]; then kv "$f.applescript" "❌ 超时"
  else kv "$f.applescript" "❌ 编译失败（rc=${rc}）"; fi
done

say ""
say "  本机通知实测（会弹一个横幅）："
rc=0
pg_run_timeout 20 /usr/bin/osascript -e 'display notification "PowerGuard 诊断：本机通知可用" with title "PowerGuard"' >/dev/null 2>&1 || rc=$?
if [ "$rc" = "0" ]; then say "    ✅ 成功"
else say "    ❌ 失败（rc=${rc}）—— 检查 系统设置 → 通知 → 脚本编辑器/终端 是否被静音"; fi

if [ "$DO_TEST" = "true" ]; then
  say ""
  say "  iMessage 实测："
  if cmd_msg="PowerGuard 诊断测试
来自 $PG_HOSTNAME
时间 $(date '+%Y-%m-%d %H:%M:%S')"; pg_notify_imessage "$cmd_msg"; then
    say "    ✅ 已交给 Messages.app 发送（成功与否请看手机）"
  else
    say "    ❌ 发送失败"
    pg_imessage_error_hint 2>&1 | say_block "    "
  fi
fi

# ---------------------------------------------------------------------------
sec "9. 运行状态文件"
if [ -f "$PG_STATE" ]; then
  say_block "  " < "$PG_STATE"
else
  say "  （还没有状态文件，说明监控程序从未成功跑过一轮）"
fi

# ---------------------------------------------------------------------------
sec "10. 日志尾部（最近 40 行）"
if [ -f "$PG_LOG" ]; then
  tail -n 40 "$PG_LOG" | say_block "  "
else
  say "  （没有日志：${PG_LOG}）"
fi
if [ -f "$PG_LOGDIR/launchd.err.log" ] && [ -s "$PG_LOGDIR/launchd.err.log" ]; then
  say ""
  say "  [launchd.err.log 尾部]"
  tail -n 20 "$PG_LOGDIR/launchd.err.log" | say_block "  "
fi

# ---------------------------------------------------------------------------
sec "11. 如果推送不到 iPhone，按顺序检查"
say "  1) 系统设置 → 隐私与安全性 → 自动化：允许「终端 / PowerGuard」控制「信息」"
say "     （macOS 13：系统偏好设置 → 安全性与隐私 → 隐私 → 自动化）"
say "     macOS 14+ 还应看一眼 隐私与安全性 → 信息 是否被关掉"
say "  2) 打开「信息」App，确认已经用 Apple ID 登录，并且能给收件人发出一条普通消息"
say "  3) 收件人建议填你自己的 Apple ID 邮箱（发给自己免费且多设备同步）"
say "     填手机号时必须是 +86 开头、不带空格和横杠，否则会退化成付费短信"
say "  4) 跑一次：./powerguard.sh test    然后 ./doctor.sh --test"
say "  5) 还不行就用备用通道：在 config.conf 里填 PG_BARK_URL 或 PG_NTFY_URL"

say ""
say "================================================================"
say " 报告结束"
say "================================================================"

if [ "$DO_SAVE" = "true" ]; then
  if [ -z "$OUT" ]; then
    OUT="$HOME/Desktop/PowerGuard-诊断-$(date '+%Y%m%d-%H%M%S').txt"
  fi
  if cp "$TMPREPORT" "$OUT" 2>/dev/null; then
    printf '\n📄 报告已保存：%s\n' "$OUT"
  else
    printf '\n❌ 无法写入：%s\n' "$OUT" >&2
    exit 1
  fi
fi
