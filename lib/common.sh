#!/bin/bash
# PowerGuard - 公共库：路径、日志、配置、状态文件
# 目标：完全兼容 macOS 自带的 bash 3.2，零外部依赖

# 统一 PATH：本程序是按 macOS 自带的 BSD 版 sed/grep/awk 写的，
# 而用户的终端里 PATH 常被 Homebrew / conda 改写（GNU sed 的 -i 用法完全不同），
# launchd 下的 PATH 又非常干净。这里固定优先使用系统自带工具，保证两种环境表现一致。
# 注意：ioreg 和 system_profiler 在 /usr/sbin，不在 /usr/bin。
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin${PATH:+:$PATH}"
export PATH

PG_NAME="PowerGuard"
PG_VERSION="1.0.0"
PG_LABEL="com.powerguard.agent"
PG_MENUBAR_LABEL="com.powerguard.menubar"

# ---------------------------------------------------------------------------
# 路径
#   PG_ROOT   : 代码所在目录（脚本、lib、app）
#   PG_SUPPORT: 数据目录（配置、收件人、状态）
# 两者在生产环境是同一个目录，开发时可用 POWERGUARD_HOME 重定向数据目录。
# ---------------------------------------------------------------------------
PG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -n "${POWERGUARD_HOME:-}" ]; then
  PG_SUPPORT="$POWERGUARD_HOME"
else
  PG_SUPPORT="$HOME/Library/Application Support/PowerGuard"
fi

PG_CONFIG="$PG_SUPPORT/config.conf"
PG_RECIPIENTS="$PG_SUPPORT/recipients.list"
PG_STATE="$PG_SUPPORT/state"
PG_DISABLED_FLAG="$PG_SUPPORT/disabled"
PG_HELPERS="$PG_SUPPORT/helpers"

PG_LOGDIR="$HOME/Library/Logs/PowerGuard"
if [ -n "${POWERGUARD_LOGDIR:-}" ]; then
  PG_LOGDIR="$POWERGUARD_LOGDIR"
fi
PG_LOG="$PG_LOGDIR/powerguard.log"

PG_LAUNCHAGENTS="$HOME/Library/LaunchAgents"

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
pg_ensure_dirs() {
  [ -d "$PG_SUPPORT" ] || mkdir -p "$PG_SUPPORT" 2>/dev/null
  [ -d "$PG_LOGDIR" ] || mkdir -p "$PG_LOGDIR" 2>/dev/null
  if [ ! -d "$PG_LOGDIR" ] || [ ! -w "$PG_LOGDIR" ]; then
    # 日志目录不可用（权限/沙箱）时退回数据目录，保证日志不丢
    PG_LOGDIR="$PG_SUPPORT"
    PG_LOG="$PG_LOGDIR/powerguard.log"
  fi
  [ -d "$PG_HELPERS" ] || mkdir -p "$PG_HELPERS" 2>/dev/null
}

pg_rotate_log() {
  # 按大小轮转，保留一份归档；归档超过保留天数则删除
  [ -f "$PG_LOG" ] || return 0
  local maxkb="${PG_LOG_MAX_KB:-2048}"
  local size
  size=$(wc -c < "$PG_LOG" 2>/dev/null | tr -d ' ')
  [ -n "$size" ] || return 0
  if [ "$size" -gt $((maxkb * 1024)) ] 2>/dev/null; then
    mv -f "$PG_LOG" "$PG_LOG.1" 2>/dev/null
  fi
  if [ -f "$PG_LOG.1" ]; then
    local days="${PG_LOG_RETENTION_DAYS:-7}"
    if [ -n "$(find "$PG_LOG.1" -mtime +"$days" 2>/dev/null)" ]; then
      rm -f "$PG_LOG.1" 2>/dev/null
    fi
  fi
}

pg_log() {
  # pg_log LEVEL message...
  local lvl="$1"; shift
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  local line="$ts [$lvl] $*"
  pg_rotate_log
  # 注意重定向顺序：必须先 2>/dev/null 再 >> 文件。若反着写，文件打不开时
  # shell 自己报的 "No such file or directory" 会落到还没被重定向的 stderr 上。
  printf '%s\n' "$line" 2>/dev/null >> "$PG_LOG"
  case "$lvl" in
    ERROR|WARN) printf '%s\n' "$line" >&2 ;;
    *) if [ "${PG_VERBOSE:-false}" = "true" ]; then printf '%s\n' "$line" >&2; fi ;;
  esac
}

pg_log_info()  { pg_log INFO "$@"; }
pg_log_warn()  { pg_log WARN "$@"; }
pg_log_error() { pg_log ERROR "$@"; }

# ---------------------------------------------------------------------------
# 配置：默认值 + 用户覆盖
# ---------------------------------------------------------------------------
pg_load_config() {
  # 轮询与阈值
  PG_POLL_INTERVAL=20
  PG_TH_30=30
  PG_TH_20=20
  PG_TH_10=10
  PG_HYSTERESIS=5
  PG_AC_COOLDOWN=120

  # 通知开关
  PG_NOTIFY_AC_LOST=true
  PG_NOTIFY_AC_RESTORE=true
  PG_NOTIFY_THRESHOLD=true
  PG_LOCAL_NOTIFY=true
  PG_LOCAL_SOUND="Glass"
  PG_IMESSAGE_ENABLED=true

  # 备用通道（默认全关，留空即禁用）
  PG_BARK_URL=""
  PG_NTFY_URL=""
  PG_WEBHOOK_URL=""

  # 低电量动作（默认关闭，预留）
  PG_ACTION_ENABLED=false
  PG_ACTION_THRESHOLD=5
  PG_ACTION_COMMAND=""

  # 日志与诊断
  PG_LOG_RETENTION_DAYS=7
  PG_LOG_MAX_KB=2048
  PG_VERBOSE=false
  PG_HOSTNAME=""

  if [ -f "$PG_CONFIG" ]; then
    # 先语法检查：配置写坏了也不至于让监控崩掉
    if /bin/bash -n "$PG_CONFIG" 2>/dev/null; then
      # shellcheck disable=SC1090
      . "$PG_CONFIG"
    else
      printf 'PowerGuard: 配置文件语法错误，已忽略：%s\n' "$PG_CONFIG" >&2
    fi
  fi

  if [ -z "$PG_HOSTNAME" ]; then
    PG_HOSTNAME=$(scutil --get ComputerName 2>/dev/null || hostname 2>/dev/null || echo "Mac")
  fi
}

# ---------------------------------------------------------------------------
# 状态文件：简单的 key=value 行，读用 grep，写用整文件重写
# ---------------------------------------------------------------------------
pg_state_get() {
  [ -f "$PG_STATE" ] || return 1
  local v
  v=$(grep -E "^$1=" "$PG_STATE" 2>/dev/null | head -1 | cut -d= -f2-)
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

pg_state_set_many() {
  # 用法：pg_state_set_many key=value key=value ...
  local tmp="$PG_STATE.tmp"
  local out
  out=$(mktemp "${TMPDIR:-/tmp}/pgstate.XXXXXX") || return 1
  local pair key
  # 先把所有想要设置的 key 收集起来
  local -a keys
  keys=()
  for pair in "$@"; do
    keys[${#keys[@]}]="${pair%%=*}"
  done
  # 保留旧文件中未被覆盖的键
  if [ -f "$PG_STATE" ]; then
    while IFS= read -r line; do
      case "$line" in
        *=*) key="${line%%=*}" ;;
        *) continue ;;
      esac
      local skip=false k
      for k in "${keys[@]}"; do
        if [ "$k" = "$key" ]; then skip=true; break; fi
      done
      if [ "$skip" = "false" ]; then printf '%s\n' "$line" >> "$out"; fi
    done < "$PG_STATE"
  fi
  for pair in "$@"; do printf '%s\n' "$pair" >> "$out"; done
  mv -f "$out" "$PG_STATE" 2>/dev/null
  return 0
}

pg_state_set() { pg_state_set_many "$1=$2"; }

# ---------------------------------------------------------------------------
# 杂项
# ---------------------------------------------------------------------------
pg_now() { date +%s; }

pg_macos_version() {
  sw_vers -productVersion 2>/dev/null || echo "0"
}

pg_macos_build() {
  sw_vers -buildVersion 2>/dev/null || echo ""
}

pg_macos_major() {
  local v
  v=$(pg_macos_version)
  printf '%s' "${v%%.*}"
}

# 已知验证过的最高主版本；更高的版本自动进入 verbose 以便快速适配
PG_VERIFIED_MAX_MAJOR=26

pg_is_newer_than_verified() {
  local m
  m=$(pg_macos_major)
  case "$m" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$m" -gt "$PG_VERIFIED_MAX_MAJOR" ]
}

pg_urlencode() {
  # 纯 bash 的 URL 编码，逐字节处理（LC_ALL=C 保证多字节字符按字节切分）
  # 注意：高字节（>=0x80）经 printf '%d' "'$c" 会得到负数，必须 & 255 掩码
  local LC_ALL=C
  local s="$1" i c code hex out=""
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out="$out$c" ;;
      *)
        printf -v code '%d' "'$c" 2>/dev/null || code=0
        code=$(( code & 255 ))
        printf -v hex '%02X' "$code"
        out="$out%$hex"
        ;;
    esac
  done
  printf '%s' "$out"
}

pg_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

pg_human_minutes() {
  # 输入分钟数，输出“X 小时 Y 分”
  local m="$1"
  case "$m" in ''|*[!0-9]*) printf '未知'; return ;; esac
  if [ "$m" -le 0 ]; then printf '未知'; return; fi
  if [ "$m" -ge 60 ]; then
    printf '%d 小时 %d 分' $((m / 60)) $((m % 60))
  else
    printf '%d 分钟' "$m"
  fi
}

# 带超时执行命令（macOS 没有 coreutils 的 timeout）
pg_run_timeout() {
  local t="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$t"; kill -9 "$pid" 2>/dev/null ) &
  local wd=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill -9 "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  return $rc
}

# 可被信号打断的 sleep：launchd 发 SIGTERM 时能立刻退出，不必等满一个轮询周期
pg_sleep() {
  local t="${1:-1}"
  case "$t" in ''|*[!0-9]*) t=1 ;; esac
  sleep "$t" &
  local pid=$!
  wait "$pid" 2>/dev/null
  return 0
}
