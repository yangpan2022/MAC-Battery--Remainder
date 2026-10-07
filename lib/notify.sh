#!/bin/bash
# PowerGuard - 通知层
#
# 通道：
#   主通道  iMessage（可多个收件人，逐个发送）
#   辅通道  macOS 本地通知
#   备份     Bark / ntfy / 通用 Webhook（默认留空即禁用）
#
# 设计要点：
#   - 消息正文通过 argv 传给 AppleScript，彻底规避引号/emoji/换行的转义问题
#   - 三种 AppleScript 发送策略依次尝试，兼容不同 macOS 版本
#   - 发送失败会重试并落到日志；全部失败时再发一条本地通知，绝不静默

PG_IMESSAGE_MAX_RETRY=3
PG_IMESSAGE_RETRY_SLEEP=3
PG_OSASCRIPT_TIMEOUT=20

# ---------------------------------------------------------------------------
# 收件人管理
# ---------------------------------------------------------------------------
pg_recipients_file() { printf '%s' "$PG_RECIPIENTS"; }

pg_recipients() {
  # 输出所有有效收件人，一行一个
  [ -f "$PG_RECIPIENTS" ] || return 0
  local line handle
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    handle="${line%%#*}"
    handle=$(printf '%s' "$handle" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$handle" ] || continue
    printf '%s\n' "$handle"
  done < "$PG_RECIPIENTS"
}

pg_recipients_count() {
  local n
  n=$(pg_recipients | grep -c . 2>/dev/null)
  printf '%s' "${n:-0}"
}

pg_recipient_exists() {
  local want="$1" h
  while IFS= read -r h; do
    [ "$h" = "$want" ] && return 0
  done <<EOF
$(pg_recipients)
EOF
  return 1
}

pg_recipient_add() {
  local handle="$1" note="${2:-}"
  [ -n "$handle" ] || { printf '错误：收件人地址不能为空\n' >&2; return 1; }
  case "$handle" in
    *@*) ;;
    +*|[0-9]*) ;;
    *) printf '警告：%s 看起来不像邮箱或手机号，仍将写入\n' "$handle" >&2 ;;
  esac
  if pg_recipient_exists "$handle"; then
    printf '已存在，跳过：%s\n' "$handle" >&2
    return 0
  fi
  pg_ensure_dirs
  if [ ! -f "$PG_RECIPIENTS" ]; then
    printf '# PowerGuard iMessage 收件人列表\n# 一行一个，邮箱或手机号均可；# 之后是备注\n' > "$PG_RECIPIENTS"
  fi
  if [ -n "$note" ]; then
    printf '%s    # %s\n' "$handle" "$note" >> "$PG_RECIPIENTS"
  else
    printf '%s\n' "$handle" >> "$PG_RECIPIENTS"
  fi
  return 0
}

pg_recipient_remove() {
  local handle="$1"
  [ -f "$PG_RECIPIENTS" ] || { printf '收件人列表不存在\n' >&2; return 1; }
  local tmp="$PG_RECIPIENTS.tmp" line h found=1
  : > "$tmp"
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) printf '%s\n' "$line" >> "$tmp"; continue ;;
    esac
    h="${line%%#*}"
    h=$(printf '%s' "$h" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ "$h" = "$handle" ]; then
      found=0
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$PG_RECIPIENTS"
  mv -f "$tmp" "$PG_RECIPIENTS"
  return $found
}

# ---------------------------------------------------------------------------
# AppleScript 辅助脚本
# ---------------------------------------------------------------------------
pg_ensure_helpers() {
  pg_ensure_dirs
  cat > "$PG_HELPERS/notify.applescript" <<'APPLESCRIPT'
on run argv
	set theTitle to item 1 of argv
	set theBody to item 2 of argv
	set theSound to item 3 of argv
	if theSound is "" then
		display notification theBody with title theTitle
	else
		display notification theBody with title theTitle sound name theSound
	end if
end run
APPLESCRIPT

  cat > "$PG_HELPERS/imessage_buddy.applescript" <<'APPLESCRIPT'
on run argv
	set targetHandle to item 1 of argv
	set msgText to item 2 of argv
	tell application "Messages"
		set targetService to 1st service whose service type = iMessage
		set targetBuddy to buddy targetHandle of targetService
		send msgText to targetBuddy
	end tell
end run
APPLESCRIPT

  cat > "$PG_HELPERS/imessage_participant.applescript" <<'APPLESCRIPT'
on run argv
	set targetHandle to item 1 of argv
	set msgText to item 2 of argv
	tell application "Messages"
		set targetAccount to 1st account whose service type = iMessage
		set targetParticipant to participant targetHandle of targetAccount
		send msgText to targetParticipant
	end tell
end run
APPLESCRIPT

  cat > "$PG_HELPERS/imessage_chat.applescript" <<'APPLESCRIPT'
on run argv
	set targetHandle to item 1 of argv
	set msgText to item 2 of argv
	set chatID to "iMessage;-;" & targetHandle
	tell application "Messages"
		send msgText to text chat id chatID
	end tell
end run
APPLESCRIPT
}

# ---------------------------------------------------------------------------
# iMessage
# ---------------------------------------------------------------------------
pg_imessage_error_hint() {
  local err="${1:-}"
  case "$err" in
    *-1743*|*"Not authorized"*|*"not allowed"*|*"不允许"*)
      pg_log_error "iMessage 发送被系统拒绝：需要授予自动化权限。"
      pg_log_error "  打开 系统设置 → 隐私与安全性 → 自动化，勾选允许「终端」/「osascript」/「PowerGuard」控制「信息」"
      pg_log_error "  若列表里没有条目，先在终端手动执行一次：osascript -e 'tell application \"Messages\" to get name'"
      ;;
    *-10004*|*"权限违例"*|*"privilege violation"*|*"Privilege violation"*)
      pg_log_error "iMessage 发送失败：权限违例（-10004）。"
      pg_log_error "  通常是「自动化」权限没给；也可能是当前进程被沙箱/安全策略限制，发不了 Apple 事件。"
      pg_log_error "  打开 系统设置 → 隐私与安全性 → 自动化，允许控制「信息」。"
      pg_log_error "  如果你是在受限环境（沙箱、SSH 远程会话、被 MDM 管理的机器）里跑，"
      pg_log_error "  请回到目标 Mac 本机的「终端」里执行一次 powerguard.sh test 再确认。"
      ;;
    *"Messages got an error"*|*"-1728"*)
      pg_log_error "iMessage 发送失败：目标地址可能不是 iMessage 用户，或 Messages 未登录。"
      ;;
    *"Application isn"*|*"-600"*|*"Connection is invalid"*)
      pg_log_error "iMessage 发送失败：Messages 未运行或未登录 Apple ID。"
      ;;
    *)
      # 没传错误文本时（或错误里有别的花样），给一份通用排查清单
      pg_log_error "iMessage 发送失败的常见原因，按顺序排查："
      pg_log_error "  1) 没给「自动化」权限：系统设置 → 隐私与安全性 → 自动化 → 允许控制「信息」"
      pg_log_error "  2) 「信息」App 没有登录 iMessage，或发送时它没能启动"
      pg_log_error "  3) 收件人不是 iMessage 用户（会退化成短信，可能需要 iPhone 短信转发）"
      pg_log_error "  更详细的现场信息：跑一次 doctor.sh --test"
      ;;
  esac
}

pg_send_imessage_to() {
  local handle="$1" text="$2"
  local strategy out rc attempt

  for strategy in imessage_buddy imessage_participant imessage_chat; do
    attempt=1
    while [ "$attempt" -le "$PG_IMESSAGE_MAX_RETRY" ]; do
      out=$(pg_run_timeout "$PG_OSASCRIPT_TIMEOUT" \
              osascript "$PG_HELPERS/$strategy.applescript" "$handle" "$text" 2>&1)
      rc=$?
      if [ "$rc" -eq 0 ]; then
        pg_log_info "iMessage 已发送 -> $handle (策略=$strategy, 第 $attempt 次)"
        return 0
      fi
      if [ "$rc" -eq 137 ]; then
        pg_log_warn "iMessage 发送超时 -> $handle (策略=$strategy, 第 $attempt 次)"
      else
        pg_log_warn "iMessage 发送失败 -> $handle (策略=$strategy, 第 $attempt 次) rc=$rc: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
        pg_imessage_error_hint "$out"
        # 权限类错误是全局性的：重试、换策略都不会有用，
        # 而且每次都要等 osascript 超时，白等好几分钟。直接放弃，返回 2 让上层也知道。
        case "$out" in
          *-1743*|*"Not authorized"*|*-10004*|*"权限违例"*|*"privilege violation"*|*"Privilege violation"*)
            pg_log_error "这是权限/安全策略类错误，跳过剩余重试与策略。"
            return 2 ;;
        esac
      fi
      attempt=$(( attempt + 1 ))
      [ "$attempt" -le "$PG_IMESSAGE_MAX_RETRY" ] && pg_sleep "$PG_IMESSAGE_RETRY_SLEEP"
    done
  done

  pg_log_error "iMessage 发送彻底失败 -> ${handle}（三种策略各重试 $PG_IMESSAGE_MAX_RETRY 次）"
  return 1
}

pg_notify_imessage() {
  local text="$1"
  [ "$PG_IMESSAGE_ENABLED" = "true" ] || { pg_log_info "iMessage 通道已禁用，跳过"; return 0; }
  local count
  count=$(pg_recipients_count)
  if [ "$count" -eq 0 ]; then
    pg_log_warn "没有配置任何 iMessage 收件人，跳过手机推送（用 powerguard.sh recipients add 添加）"
    return 1
  fi
  local handle ok=0 fail=0 rc=0 aborted=false
  while IFS= read -r handle; do
    [ -n "$handle" ] || continue
    if pg_send_imessage_to "$handle" "$text"; then
      ok=$(( ok + 1 ))
    else
      rc=$?
      fail=$(( fail + 1 ))
      if [ "$rc" -eq 2 ]; then
        aborted=true
        break
      fi
    fi
  done <<EOF
$(pg_recipients)
EOF
  if [ "$aborted" = "true" ]; then
    pg_log_warn "遇到权限类错误，已跳过剩余收件人（同一个原因会影响所有收件人）"
  fi
  pg_log_info "iMessage 汇总：成功 $ok 个，失败 $fail 个"
  [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 本地通知
# ---------------------------------------------------------------------------
pg_notify_local() {
  local title="$1" body="$2" sound="${3:-}"
  [ "$PG_LOCAL_NOTIFY" = "true" ] || return 0
  [ -n "$sound" ] || sound="$PG_LOCAL_SOUND"
  local out rc
  out=$(pg_run_timeout 10 osascript "$PG_HELPERS/notify.applescript" "$title" "$body" "$sound" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    pg_log_warn "本地通知发送失败 rc=$rc: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 备用通道（默认留空 = 关闭）
# ---------------------------------------------------------------------------
pg_notify_backup_channels() {
  local title="$1" body="$2"
  local rc=0

  if [ -n "$PG_BARK_URL" ]; then
    local json
    json=$(printf '{"title":"%s","body":"%s","group":"PowerGuard"}' \
            "$(pg_json_escape "$title")" "$(pg_json_escape "$body")")
    if curl -s -m 10 -X POST "$PG_BARK_URL" \
         -H 'Content-Type: application/json; charset=utf-8' \
         --data-binary "$json" >/dev/null 2>&1; then
      pg_log_info "Bark 已推送"
    else
      pg_log_warn "Bark 推送失败"
      rc=1
    fi
  fi

  if [ -n "$PG_NTFY_URL" ]; then
    if curl -s -m 10 -X POST "$PG_NTFY_URL" \
         -H "Title: $(printf '%s' "$title" | tr -d '\n')" \
         -H 'Priority: high' \
         -H 'Tags: battery' \
         --data-binary "$body" >/dev/null 2>&1; then
      pg_log_info "ntfy 已推送"
    else
      pg_log_warn "ntfy 推送失败"
      rc=1
    fi
  fi

  if [ -n "$PG_WEBHOOK_URL" ]; then
    local wjson
    wjson=$(printf '{"source":"PowerGuard","host":"%s","title":"%s","body":"%s"}' \
              "$(pg_json_escape "$PG_HOSTNAME")" \
              "$(pg_json_escape "$title")" "$(pg_json_escape "$body")")
    if curl -s -m 10 -X POST "$PG_WEBHOOK_URL" \
         -H 'Content-Type: application/json; charset=utf-8' \
         --data-binary "$wjson" >/dev/null 2>&1; then
      pg_log_info "Webhook 已推送"
    else
      pg_log_warn "Webhook 推送失败"
      rc=1
    fi
  fi

  return $rc
}

# ---------------------------------------------------------------------------
# 统一入口
#   pg_notify <事件名> <标题> <正文> [是否静音]
# ---------------------------------------------------------------------------
pg_notify() {
  local event="$1" title="$2" body="$3" quiet="${4:-false}"
  if [ -f "$PG_DISABLED_FLAG" ]; then
    # 二次保险：暂停（off）时任何事件都不外发
    pg_log_info "已暂停（off），跳过通知：[$event] $title"
    return 0
  fi
  pg_ensure_helpers

  pg_log_info "事件[$event] $title | $body"

  local imsg_ok=0 backup_ok=0
  if [ "$quiet" = "true" ]; then
    pg_log_info "静音模式（仅本地通知）"
  else
    if pg_notify_imessage "$title
$body"; then
      imsg_ok=1
    fi
    if pg_notify_backup_channels "$title" "$body"; then
      backup_ok=1
    fi
  fi

  pg_notify_local "$title" "$body"

  if [ "$quiet" != "true" ] && [ "$imsg_ok" -eq 0 ] && [ "$backup_ok" -eq 0 ]; then
    pg_log_error "所有远程通道均失败，仅本地通知已发出"
    pg_notify_local "PowerGuard 推送失败" "无法通过 iMessage 送达，请检查权限与收件人配置" "Basso"
    return 1
  fi
  return 0
}
