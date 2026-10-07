#!/bin/bash
# PowerGuard - 监控主循环与状态机
#
# 状态文件里保存的键：
#   on_ac            上次已知的电源状态（true/false/unknown）
#   pct              上次读到的电量百分比
#   minutes          上次读到的剩余/所需分钟数
#   provider         当前可用的数据源（iokit/pmset/sysprof）
#   armed_30/20/10   阈值是否处于“待触发”（1）还是“已触发过”（0）
#   ac_pending       等待去抖确认的电源事件（lost/restored/空）
#   ac_pending_ts    上面这个事件的起始时间
#   ac_lost_notified 是否已经通知过“断电”（决定恢复时要不要通知）
#   action_done      低电量自动动作是否已执行
#   fail_count       连续读取失败次数
#   fail_notified    是否已就“读取失败”告警过
#   heartbeat_ts     最近一次心跳日志时间
#   updated_ts       最近一次成功读取时间
#   last_event_ts / last_event 最近一次通知事件（供菜单栏显示）

# ---------------------------------------------------------------------------
# 状态读取小工具
# ---------------------------------------------------------------------------
pg_st_get() {
  # pg_st_get KEY 默认值
  local v
  v=$(pg_state_get "$1" 2>/dev/null) || v=""
  if [ -z "$v" ]; then printf '%s' "$2"; else printf '%s' "$v"; fi
}

pg_st_set() { pg_state_set "$1" "$2"; }

# ---------------------------------------------------------------------------
# 提示文本
# ---------------------------------------------------------------------------
pg_status_line() {
  # 一句话状态，供日志/通知正文使用
  local s="$PG_HOSTNAME "
  if [ "$PGV_ON_AC" = "true" ]; then
    s="${s}已接入电源"
  else
    s="${s}正在使用电池"
  fi
  s="${s}，电量 ${PGV_PCT}%"
  if [ "$PGV_FULL" = "true" ]; then
    s="${s}（已充满）"
  elif [ "$PGV_CHARGING" = "true" ]; then
    s="${s}（充电中）"
  fi
  if pg_is_num "$PGV_MINUTES" && [ "$PGV_MINUTES" -gt 0 ]; then
    if [ "$PGV_ON_AC" = "true" ]; then
      s="${s}，约 $(pg_human_minutes "$PGV_MINUTES") 后充满"
    else
      s="${s}，预计剩余 $(pg_human_minutes "$PGV_MINUTES")"
    fi
  fi
  printf '%s' "$s"
}

pg_power_state_cn() {
  case "$1" in
    true) printf '已接入电源' ;;
    false) printf '使用电池' ;;
    *) printf '未知' ;;
  esac
}

# ---------------------------------------------------------------------------
# 初始化
# ---------------------------------------------------------------------------
pg_state_init() {
  [ -f "$PG_STATE" ] && return 0
  pg_state_set_many \
    "on_ac=unknown" "pct=" "minutes=" "provider=" \
    "armed_30=1" "armed_20=1" "armed_10=1" \
    "ac_pending=" "ac_pending_ts=0" "ac_lost_notified=0" \
    "action_done=0" "fail_count=0" "fail_notified=0" \
    "heartbeat_ts=0" "updated_ts=0" "last_event_ts=0" "last_event="
}

# 接入电源时把所有阈值重新武装，并允许低电量动作再次执行
pg_rearm_all() {
  pg_state_set_many "armed_30=1" "armed_20=1" "armed_10=1" "action_done=0"
}

# ---------------------------------------------------------------------------
# 电源事件（带去抖）
# ---------------------------------------------------------------------------
pg_handle_power_transition() {
  # 参数：新状态(true/false)。只在状态确实变化时调用
  local on_ac="$1" now="$2"
  local pending kind
  if [ "$on_ac" = "true" ]; then pending="restored"; kind="接入电源"; else pending="lost"; kind="断开电源"; fi
  pg_log_info "检测到电源变化 → ${kind}（${PG_AC_COOLDOWN}s 去抖后再确认）"
  pg_state_set_many "ac_pending=$pending" "ac_pending_ts=$now"

  # 接入电源立刻重新武装（不等去抖），避免短时间内再次拔电时漏报
  if [ "$on_ac" = "true" ]; then pg_rearm_all; fi
}

pg_settle_power_event() {
  # 参数：now；返回 0 表示本次确实发过通知
  local now="$1" pending ts
  pending=$(pg_st_get ac_pending "")
  [ -n "$pending" ] || return 1
  ts=$(pg_st_get ac_pending_ts 0)
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  [ $(( now - ts )) -ge "$PG_AC_COOLDOWN" ] || return 1

  local notified=0
  case "$pending" in
    lost)
      if [ "$PG_NOTIFY_AC_LOST" = "true" ]; then
        pg_notify power_lost \
          "⚡️ 电源已断开" \
          "$PG_HOSTNAME 已切换到电池供电。
$(pg_status_line)
请检查电源线/插排是否被误碰；若正在跑重要任务，建议尽快恢复供电。"
        notified=1
      fi
      pg_st_set ac_lost_notified 1
      ;;
    restored)
      if [ "$(pg_st_get ac_lost_notified 0)" = "1" ] && [ "$PG_NOTIFY_AC_RESTORE" = "true" ]; then
        pg_notify power_restored \
          "✅ 电源已恢复" \
          "$PG_HOSTNAME 已重新接入电源。
$(pg_status_line)"
        notified=1
      fi
      pg_st_set ac_lost_notified 0
      ;;
  esac
  pg_state_set_many "ac_pending=" "ac_pending_ts=0"
  [ "$notified" = "1" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# 电量阈值
# ---------------------------------------------------------------------------
pg_threshold_list() {
  # 输出配置里有效的提醒阈值，从高到低
  local t
  for t in "$PG_TH_30" "$PG_TH_20" "$PG_TH_10"; do
    case "$t" in ''|*[!0-9]*|0) continue ;; esac
    printf '%s\n' "$t"
  done
}

pg_fire_threshold() {
  local t="$1" pct="$PGV_PCT" tip pl
  if [ "$t" -le 10 ]; then
    tip="电量极低，本机可能随时强制关机。"
  elif [ "$t" -le 20 ]; then
    tip="请立即接入电源。"
  else
    tip="建议尽快接入电源。"
  fi
  pl=""
  if pg_is_num "$PGV_MINUTES" && [ "$PGV_MINUTES" -gt 0 ]; then
    pl="
预计剩余 $(pg_human_minutes "$PGV_MINUTES")。"
  fi
  pg_notify low_battery \
    "🔋 电量仅剩 ${pct}%（低于 ${t}%）" \
    "$PG_HOSTNAME 电池电量 ${pct}%。${pl}
${tip}"
}

pg_check_all_thresholds() {
  # 只播报“当前已跌破的最低那一档”，并把更宽松的档位一起标记为已播报。
  # 否则电量已经很低时才拔掉电源，会一次性补发 30%/20%/10% 三条消息。
  local t best="" pct="$PGV_PCT"
  pg_is_num "$pct" || return 1

  # 1) 迟滞重新武装：回到 阈值+HYSTERESIS 以上才重新武装
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ "$(pg_st_get "armed_$t" 1)" = "0" ] && [ "$pct" -ge $(( t + PG_HYSTERESIS )) ]; then
      pg_st_set "armed_$t" 1
      pg_log_info "阈值 ${t}% 重新武装（当前 ${pct}%）"
    fi
  done <<EOF
$(pg_threshold_list)
EOF

  # 2) 找出当前电量已跌破的最低那一档
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ "$pct" -le "$t" ]; then best="$t"; fi
  done <<EOF
$(pg_threshold_list)
EOF
  [ -n "$best" ] || return 1

  # 3) 还没播报过就播报一次，并把所有不严于它的档位标记为已播报
  if [ "$(pg_st_get "armed_$best" 1)" = "1" ]; then
    pg_fire_threshold "$best"
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      if [ "$t" -ge "$best" ]; then pg_st_set "armed_$t" 0; fi
    done <<EOF
$(pg_threshold_list)
EOF
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 可选的低电量自动动作
# ---------------------------------------------------------------------------
pg_check_action() {
  [ "$PG_ACTION_ENABLED" = "true" ] || return 1
  [ -n "$PG_ACTION_COMMAND" ] || return 1
  [ "$PGV_ON_AC" = "false" ] || return 1
  [ "$(pg_st_get action_done 0)" = "1" ] && return 1
  pg_is_num "$PGV_PCT" || return 1
  [ "$PGV_PCT" -le "$PG_ACTION_THRESHOLD" ] || return 1

  pg_log_warn "电量 ${PGV_PCT}% ≤ ${PG_ACTION_THRESHOLD}%，执行自动动作：$PG_ACTION_COMMAND"
  pg_notify action "$(printf '🛑 电量 %s%%，正在执行自动动作' "$PGV_PCT")" \
    "$PG_HOSTNAME 电量已降到 ${PGV_PCT}%，即将执行：
$PG_ACTION_COMMAND"
  pg_st_set action_done 1
  # 给通知留出送达时间，再执行动作
  pg_sleep 5
  local out rc=0
  out=$(pg_run_timeout 60 /bin/sh -c "$PG_ACTION_COMMAND" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    pg_log_info "自动动作执行成功"
  else
    pg_log_error "自动动作执行失败（rc=${rc}）：$out"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 读取失败的响亮告警
# ---------------------------------------------------------------------------
pg_handle_read_failure() {
  local n
  n=$(pg_st_get fail_count 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$(( n + 1 ))
  pg_st_set fail_count "$n"

  if [ "$n" -ge 3 ] && [ "$(pg_st_get fail_notified 0)" != "1" ]; then
    pg_log_error "连续 ${n} 次无法读取电源状态，监控已失效！"
    if [ "$PG_LOCAL_NOTIFY" = "true" ]; then
      pg_notify_local "PowerGuard 无法读取电源状态" \
        "连续 ${n} 次读取失败。请运行 ./powerguard.sh doctor 并在目标机上检查系统版本兼容性。" "Basso"
    fi
    pg_st_set fail_notified 1
  fi
}

# ---------------------------------------------------------------------------
# 一次完整的检查
# ---------------------------------------------------------------------------
pg_monitor_tick() {
  local now rc=0
  pg_load_config   # 每轮重新读取配置：改完 config.conf 无需重启监控
  now=$(pg_now)

  pg_read_power || rc=$?

  if [ "$rc" -eq 2 ]; then
    pg_log_warn "未检测到电池（台式机或电池不可用），PowerGuard 无实际作用"
    pg_state_set_many "provider=$PG_PROVIDER" "updated_ts=$now" "nobattery=1"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    pg_update_menubar_extras "$now"
    pg_handle_read_failure
    return 1
  fi

  # 读取成功
  if [ "$(pg_st_get fail_count 0)" != "0" ] || [ "$(pg_st_get fail_notified 0)" = "1" ]; then
    pg_log_info "电源状态读取已恢复正常"
    pg_state_set_many "fail_count=0" "fail_notified=0"
  fi

  local disabled=false
  [ -f "$PG_DISABLED_FLAG" ] && disabled=true

  local on_ac prev_ac
  on_ac="$PGV_ON_AC"
  prev_ac=$(pg_st_get on_ac unknown)

  if [ "$prev_ac" != "unknown" ] && [ "$prev_ac" != "$on_ac" ]; then
    pg_handle_power_transition "$on_ac" "$now"
  fi

  # 状态落盘（菜单栏 App 与 status 都读这里）
  pg_state_set_many \
    "on_ac=$on_ac" \
    "pct=$PGV_PCT" \
    "minutes=${PGV_MINUTES:-0}" \
    "provider=$PG_PROVIDER" \
    "nobattery=0" \
    "charging=$PGV_CHARGING" \
    "full=$PGV_FULL" \
    "temp_c=${PGV_TEMP_C:-}" \
    "updated_ts=$now"

  if [ "$disabled" = "true" ]; then
    # 暂停期间不通知，但继续跟踪状态；待确认的电源事件直接丢弃，避免恢复后补发旧告警
    pg_log_info "已暂停（$PG_DISABLED_FLAG 存在），跳过通知：$(pg_status_line)"
    pg_state_set_many "ac_pending=" "ac_pending_ts=0"
    pg_update_menubar_extras "$now"
    return 0
  fi

  pg_settle_power_event "$now" || true

  if [ "$on_ac" = "false" ]; then
    if [ "$PG_NOTIFY_THRESHOLD" = "true" ]; then pg_check_all_thresholds; fi
    pg_check_action || true
  fi

  pg_update_menubar_extras "$now"
  return 0
}

pg_update_menubar_extras() {
  # 心跳：每 30 分钟写一条状态日志，方便判断监控是否还活着
  local now="$1" hb
  hb=$(pg_st_get heartbeat_ts 0)
  case "$hb" in ''|*[!0-9]*) hb=0 ;; esac
  if [ $(( now - hb )) -ge 1800 ]; then
    pg_log_info "心跳：$(pg_status_line)"
    pg_st_set heartbeat_ts "$now"
  fi
}

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------
pg_monitor_loop() {
  local once="${1:-false}"
  pg_ensure_dirs
  pg_state_init
  pg_detect_provider >/dev/null 2>&1 || true
  pg_log_info "启动监控（间隔 ${PG_POLL_INTERVAL}s，数据源 ${PG_PROVIDER}，主机 ${PG_HOSTNAME}）"
  if pg_is_newer_than_verified; then
    pg_log_warn "macOS $(pg_macos_version) 高于已验证版本，已进入兼容模式；若读数异常请运行 ./powerguard.sh doctor"
  fi

  while :; do
    pg_monitor_tick
    if [ "$once" = "true" ]; then break; fi
    pg_sleep "$PG_POLL_INTERVAL"
  done
}
