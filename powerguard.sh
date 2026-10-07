#!/bin/bash
# PowerGuard —— 主命令
# 兼容 macOS 自带 bash 3.2，无外部依赖
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

pg_ensure_dirs
pg_load_config

# launchd 停止时会发 SIGTERM，直接干净退出（pg_sleep 里用的是可打断的 wait）
trap 'pg_log_info "收到退出信号，停止监控"; exit 0' TERM INT HUP

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
pg_agent_loaded() {
  [ -f "$PG_LAUNCHAGENTS/$PG_LABEL.plist" ] || return 1
  launchctl list "$PG_LABEL" >/dev/null 2>&1
}

pg_menubar_loaded() {
  [ -f "$PG_LAUNCHAGENTS/$PG_MENUBAR_LABEL.plist" ] || return 1
  launchctl list "$PG_MENUBAR_LABEL" >/dev/null 2>&1
}

pg_ago_text() {
  local ts="${1:-}" now d
  case "$ts" in ''|*[!0-9]*) printf '未知'; return ;; esac
  if [ "$ts" -eq 0 ]; then printf '从未'; return; fi
  now=$(pg_now)
  d=$(( now - ts ))
  if [ "$d" -lt 0 ]; then printf '刚刚'
  elif [ "$d" -lt 60 ]; then printf '%d 秒前' "$d"
  elif [ "$d" -lt 3600 ]; then printf '%d 分钟前' $(( d / 60 ))
  elif [ "$d" -lt 86400 ]; then printf '%d 小时前' $(( d / 3600 ))
  else printf '%d 天前' $(( d / 86400 )); fi
}

pg_enabled_text() {
  if [ -f "$PG_DISABLED_FLAG" ]; then printf '已暂停'; else printf '运行中'; fi
}

# ---------------------------------------------------------------------------
# 帮助
# ---------------------------------------------------------------------------

usage_full() {
  printf '%s\n' "PowerGuard $PG_VERSION —— Mac 电源/电量提醒（断电 + 低电量，推送到 iPhone）"
  printf '\n%s\n' "用法：./powerguard.sh <命令> [参数]"
  cat <<'EOF'

常用命令：
  status [--plain]              查看当前状态（--plain 输出 key=value，供菜单栏 App 解析）
  once                          立刻检查一次（会按规则发送通知）
  test [地址]                   发送测试消息；不带地址则发给所有收件人
  logs [行数]                   查看最近日志（默认 40 行）
  doctor [--save]               打印诊断报告（--save 同时写入文件）

收件人管理：
  recipients list               列出所有收件人
  recipients add <地址> [备注]  添加收件人（邮箱或手机号）
  recipients remove <地址>      删除收件人
  recipients open               用文本编辑器打开收件人文件

开关：
  on | enable                   恢复提醒
  off | disable                 暂停提醒（仍在后台采集状态）
  restart                       重启后台服务

其他：
  run                           前台运行监控循环（由 launchd 调用）
  version                       显示版本
  help                          显示帮助
EOF
  printf '\n文件位置：\n'
  printf '  配置    %s\n' "$PG_CONFIG"
  printf '  收件人  %s\n' "$PG_RECIPIENTS"
  printf '  状态    %s\n' "$PG_STATE"
  printf '  日志    %s\n' "$PG_LOG"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
cmd_status() {
  local plain=false
  [ "${1:-}" = "--plain" ] && plain=true

  local rc=0
  pg_read_power || rc=$?

  local on_ac pct charging full minutes temp
  if [ "$rc" -eq 0 ]; then
    on_ac="$PGV_ON_AC"; pct="$PGV_PCT"; charging="$PGV_CHARGING"
    full="$PGV_FULL"; minutes="${PGV_MINUTES:-0}"; temp="${PGV_TEMP_C:-}"
  else
    on_ac=$(pg_st_get on_ac unknown)
    pct=$(pg_st_get pct "")
    charging=$(pg_st_get charging false)
    full=$(pg_st_get full false)
    minutes=$(pg_st_get minutes 0)
    temp=$(pg_st_get temp_c "")
  fi

  local enabled agent mb recipients updated_ts last_ev last_ev_ts
  if [ -f "$PG_DISABLED_FLAG" ]; then enabled=false; else enabled=true; fi
  if pg_agent_loaded; then agent=true; else agent=false; fi
  if pg_menubar_loaded; then mb=true; else mb=false; fi
  recipients=$(pg_recipients_count)
  updated_ts=$(pg_st_get updated_ts 0)
  last_ev=$(pg_st_get last_event "")
  last_ev_ts=$(pg_st_get last_event_ts 0)

  if [ "$plain" = "true" ]; then
    printf 'version=%s\n' "$PG_VERSION"
    printf 'hostname=%s\n' "$PG_HOSTNAME"
    printf 'macos=%s\n' "$(pg_macos_version)"
    printf 'provider=%s\n' "$PG_PROVIDER"
    printf 'read_ok=%s\n' "$( [ "$rc" -eq 0 ] && printf true || printf false )"
    printf 'on_ac=%s\n' "$on_ac"
    printf 'state_cn=%s\n' "$(pg_power_state_cn "$on_ac")"
    printf 'pct=%s\n' "$pct"
    printf 'charging=%s\n' "$charging"
    printf 'full=%s\n' "$full"
    printf 'minutes=%s\n' "${minutes:-0}"
    printf 'minutes_text=%s\n' "$(pg_human_minutes "${minutes:-0}")"
    printf 'temp_c=%s\n' "$temp"
    printf 'enabled=%s\n' "$enabled"
    printf 'agent_loaded=%s\n' "$agent"
    printf 'menubar_loaded=%s\n' "$mb"
    printf 'recipients=%s\n' "$recipients"
    printf 'imessage_enabled=%s\n' "$PG_IMESSAGE_ENABLED"
    printf 'thresholds=%s,%s,%s\n' "$PG_TH_30" "$PG_TH_20" "$PG_TH_10"
    printf 'poll_interval=%s\n' "$PG_POLL_INTERVAL"
    printf 'updated_ago=%s\n' "$(pg_ago_text "$updated_ts")"
    printf 'updated_ts=%s\n' "$updated_ts"
    printf 'last_event=%s\n' "$last_ev"
    if [ -n "$last_ev" ]; then
      printf 'last_event_ago=%s\n' "$(pg_ago_text "$last_ev_ts")"
    else
      printf 'last_event_ago=\n'
    fi
    printf 'config=%s\n' "$PG_CONFIG"
    printf 'log=%s\n' "$PG_LOG"
    printf 'recipients_path=%s\n' "$PG_RECIPIENTS"
    printf 'support_dir=%s\n' "$PG_SUPPORT"
    printf 'root_dir=%s\n' "$PG_ROOT"
    return 0
  fi

  printf '%s %s（%s，macOS %s）\n' "$PG_NAME" "$PG_VERSION" "$PG_HOSTNAME" "$(pg_macos_version)"
  printf '  %-4s %s\n' '电源' "$(pg_power_state_cn "$on_ac")"
  if [ "$rc" -eq 0 ]; then
    printf '  %-4s %s%%%s\n' '电量' "$pct" \
      "$( [ "$full" = "true" ] && printf '（已充满）' || { [ "$charging" = "true" ] && printf '（充电中）'; } )"
    printf '  %-4s %s\n' '剩余' "$(pg_human_minutes "${minutes:-0}")"
    printf '  %-4s %s°C\n' '温度' "${temp:-未知}"
  else
    printf '  %-4s %s\n' '电量' "${pct:-未知}%（实时读取失败，显示的是上次记录）"
  fi
  printf '  %-4s %s\n' '来源' "$PG_PROVIDER"
  printf '  %-4s %s（%s）\n' '提醒' "$(pg_enabled_text)" "$( [ "$enabled" = "true" ] && printf 'on' || printf 'off' )"
  printf '  %-4s %s\n' '服务' "$( [ "$agent" = "true" ] && printf '已加载' || printf '未加载（提醒不会自动触发）' )"
  printf '  %-4s %s\n' '菜单' "$( [ "$mb" = "true" ] && printf '已运行' || printf '未运行' )"
  printf '  %-4s %s 个（%s）\n' '推送' "$recipients" \
    "$( [ "$PG_IMESSAGE_ENABLED" = "true" ] && printf '已启用' || printf '已停用' )"
  printf '  %-4s %s / %s / %s%%（间隔 %ss）\n' '阈值' "$PG_TH_30" "$PG_TH_20" "$PG_TH_10" "$PG_POLL_INTERVAL"
  printf '  %-4s %s\n' '更新' "$(pg_ago_text "$updated_ts")"
  if [ -n "$last_ev" ]; then
    printf '  %-4s %s（%s）\n' '事件' "$last_ev" "$(pg_ago_text "$last_ev_ts")"
  fi
  printf '  %-4s %s\n' '日志' "$PG_LOG"
  return 0
}

# ---------------------------------------------------------------------------
# 其他命令
# ---------------------------------------------------------------------------
cmd_once() {
  echo "立刻检查一次（若满足条件会发送通知）……"
  local rc=0
  pg_monitor_tick || rc=$?
  echo
  cmd_status
  return "$rc"
}

cmd_test() {
  local target="${1:-}"
  pg_ensure_helpers
  local msg
  msg="PowerGuard 测试消息
来自 $PG_HOSTNAME
时间 $(date '+%Y-%m-%d %H:%M:%S')
收到这条消息说明 iMessage 通道可用。"

  if [ -n "$target" ]; then
    if pg_send_imessage_to "$target" "$msg"; then
      printf '✅ 已发送测试消息到 %s\n' "$target"
      return 0
    fi
    printf '❌ 发送失败：%s\n' "$target" >&2
    pg_imessage_error_hint >&2
    return 1
  fi

  if [ "$(pg_recipients_count)" = "0" ]; then
    printf '还没有配置收件人。先添加一个（推荐填你自己的 Apple ID 邮箱，发给自己是免费的）：\n' >&2
    printf '  %s recipients add your-apple-id@example.com\n' "$0" >&2
    return 1
  fi

  if pg_notify_imessage "$msg"; then
    printf '✅ 测试消息已发送给全部 %s 个收件人\n' "$(pg_recipients_count)"
    return 0
  fi
  printf '❌ 测试消息发送失败\n' >&2
  pg_imessage_error_hint >&2
  return 1
}

cmd_recipients() {
  local sub="${1:-list}"
  case "$sub" in
    list|ls)
      local n
      n=$(pg_recipients_count)
      if [ "$n" = "0" ]; then
        printf '（空）还没有配置收件人。\n'
        printf '添加：%s recipients add your-apple-id@example.com\n' "$0"
        return 0
      fi
      printf '共 %s 个收件人（%s）：\n' "$n" "$PG_RECIPIENTS"
      pg_recipients | awk '{ printf "  %2d. %s\n", NR, $0 }'
      ;;
    add)
      local handle="${2:-}"
      if [ -z "$handle" ]; then
        printf '用法：%s recipients add <邮箱或手机号> [备注]\n' "$0" >&2
        return 1
      fi
      if pg_recipient_exists "$handle"; then
        printf '该收件人已存在：%s（当前共 %s 个）\n' "$handle" "$(pg_recipients_count)"
        return 0
      fi
      pg_recipient_add "$handle" "${3:-}" || return 1
      printf '✅ 已添加：%s（当前共 %s 个）\n' "$handle" "$(pg_recipients_count)"
      printf '提示：可以现在发一条测试消息 → %s test\n' "$0"
      ;;
    remove|rm|del|delete)
      local handle="${2:-}"
      if [ -z "$handle" ]; then
        printf '用法：%s recipients remove <邮箱或手机号>\n' "$0" >&2
        return 1
      fi
      pg_recipient_remove "$handle" || return 1
      printf '✅ 已删除：%s（当前共 %s 个）\n' "$handle" "$(pg_recipients_count)"
      ;;
    open|edit)
      "${EDITOR:-/usr/bin/open}" -t "$PG_RECIPIENTS" 2>/dev/null || /usr/bin/open -t "$PG_RECIPIENTS"
      ;;
    *)
      printf '未知子命令：%s\n用法：%s recipients list|add|remove|open\n' "$sub" "$0" >&2
      return 1
      ;;
  esac
}

cmd_off() {
  pg_ensure_dirs
  : > "$PG_DISABLED_FLAG"
  pg_log_info "提醒已暂停（off）"
  printf '⏸  已暂停提醒。后台仍在采集状态，重新开启：%s on\n' "$0"
}

cmd_on() {
  rm -f "$PG_DISABLED_FLAG" 2>/dev/null
  pg_log_info "提醒已恢复（on）"
  printf '▶️  已恢复提醒。\n'
}

cmd_restart() {
  if [ -f "$PG_LAUNCHAGENTS/$PG_LABEL.plist" ]; then
    launchctl unload "$PG_LAUNCHAGENTS/$PG_LABEL.plist" 2>/dev/null || true
    pg_sleep 1
    launchctl load "$PG_LAUNCHAGENTS/$PG_LABEL.plist" 2>/dev/null || true
    printf '🔄 已重启后台服务 %s\n' "$PG_LABEL"
  else
    printf '后台服务尚未安装，请先运行 ./install.sh\n' >&2
    return 1
  fi
}

cmd_logs() {
  local n="${1:-40}"
  case "$n" in ''|*[!0-9]*) n=40 ;; esac
  if [ -f "$PG_LOG" ]; then
    tail -n "$n" "$PG_LOG"
  else
    printf '还没有日志文件：%s\n' "$PG_LOG" >&2
    return 1
  fi
}

cmd_doctor() {
  local script="$PG_DIR/doctor.sh"
  if [ ! -f "$script" ]; then
    printf '缺少 doctor.sh\n' >&2
    return 1
  fi
  /bin/bash "$script" "$@"
}

# ---------------------------------------------------------------------------
# 分发
# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  case "$cmd" in
    run)         shift; pg_monitor_loop false ;;
    once)        shift; cmd_once ;;
    status)      shift; cmd_status "${1:-}" ;;
    test|send)   shift; cmd_test "${1:-}" ;;
    recipients|recipient|r) shift; cmd_recipients "$@" ;;
    on|enable)   cmd_on ;;
    off|disable) cmd_off ;;
    restart)     cmd_restart ;;
    logs|log)    shift; cmd_logs "${1:-40}" ;;
    doctor)      shift; cmd_doctor "$@" ;;
    version|-v|--version) printf '%s %s\n' "$PG_NAME" "$PG_VERSION" ;;
    help|-h|--help) usage_full ;;
    *) printf '未知命令：%s\n\n' "$cmd" >&2; usage_full >&2; return 1 ;;
  esac
}

main "$@"
