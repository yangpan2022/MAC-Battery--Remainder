#!/bin/bash
# 状态机回归测试：用打桩的电源读数驱动 monitor 逻辑，不需要真实电池
set -u
PG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export POWERGUARD_HOME="$PG_DIR/.testhome/sm"
export POWERGUARD_LOGDIR="$POWERGUARD_HOME/logs"
rm -rf "$POWERGUARD_HOME"; mkdir -p "$POWERGUARD_HOME"

cat > "$POWERGUARD_HOME/config.conf" <<'EOF'
PG_AC_COOLDOWN=0
PG_LOCAL_NOTIFY=false
EOF

. "$PG_DIR/lib/common.sh"
. "$PG_DIR/lib/providers.sh"
. "$PG_DIR/lib/notify.sh"
. "$PG_DIR/lib/monitor.sh"

pg_ensure_dirs; pg_load_config
FAIL=0
NOTIFY_LOG="$POWERGUARD_HOME/notify.log"
: > "$NOTIFY_LOG"

# ---- 打桩 ----
FAKE_AC=true; FAKE_PCT=100
pg_read_power() {
  PGV_OK=true; PGV_ON_AC="$FAKE_AC"; PGV_PCT="$FAKE_PCT"
  PGV_CHARGING=false; PGV_FULL=false; PGV_MINUTES=120
  PGV_TEMP_C=30; PGV_NOBATTERY=false; PG_PROVIDER=fake
  return 0
}
pg_notify() { printf '%s\n' "$1" >> "$NOTIFY_LOG"; printf '      >>> 通知[%s] %s\n' "$1" "$2"; return 0; }
pg_notify_local() { :; }
pg_update_menubar_extras() { :; }

step() {
  FAKE_AC="$1"; FAKE_PCT="$2"
  printf '%s\n' "--- $3 (AC=$1 pct=$2) ---"
  pg_monitor_tick >/dev/null 2>&1 || true
}
expect() {  # expect <事件名> <累计次数>
  local n
  n=$(grep -c "^$1\$" "$NOTIFY_LOG" 2>/dev/null || true)
  if [ "$n" = "$2" ]; then
    printf '      ✅ %s 累计 %s 次\n' "$1" "$n"
  else
    printf '      ❌ %s 期望 %s 次，实际 %s 次\n' "$1" "$2" "$n"; FAIL=$((FAIL+1))
  fi
}
assert_state() {  # assert_state <键> <期望值>
  local v
  v=$(pg_state_get "$1" 2>/dev/null) || v=""
  if [ "$v" = "$2" ]; then
    printf '      ✅ %s=%s\n' "$1" "$v"
  else
    printf '      ❌ %s 期望 %s，实际 "%s"\n' "$1" "$2" "$v"; FAIL=$((FAIL+1))
  fi
}

pg_state_init

step true  100 "插电 100%（初始）"
expect power_lost 0; expect low_battery 0
assert_state on_ac true

step false 100 "拔电（应只报断电）"
expect power_lost 1; expect low_battery 0

step false 45  "45%（不报）"
expect low_battery 0

step false 30  "30%（报一次低电量）"
expect low_battery 1
assert_state armed_30 0

step false 28  "28%（不重复报）"
expect low_battery 1

step false 31  "31%（迟滞未回充，不重新武装）"
expect low_battery 1
assert_state armed_30 0

step false 36  "36%（重新武装 30% 档）"
expect low_battery 1
assert_state armed_30 1

step false 30  "再降到 30%（应再报一次）"
expect low_battery 2

step false 20  "20%（报 20% 档）"
expect low_battery 3
assert_state armed_20 0

step false 12  "12%（未跌破 10%，不报）"
expect low_battery 3

step false 11  "11%（仍不报）"
expect low_battery 3

step true  11  "插电（应报恢复供电，并重新武装全部档位）"
expect power_restored 1
assert_state armed_30 1; assert_state armed_20 1; assert_state armed_10 1

step true  50  "充电中（不报）"
expect power_restored 1

step false 12  "12% 时拔电：只应报断电 + 一档低电量（不能一次补发三条）"
expect power_lost 2
expect low_battery 4

# ---- 暂停（off）期间不应外发任何通知 ----
printf '%s\n' "--- 暂停期间（off flag 存在）---"
: > "$PG_DISABLED_FLAG"
FAKE_AC=true; FAKE_PCT=40
pg_monitor_tick >/dev/null 2>&1 || true
FAKE_AC=false; FAKE_PCT=9
pg_monitor_tick >/dev/null 2>&1 || true
expect power_lost 2
expect low_battery 4
assert_state ac_pending ""
rm -f "$PG_DISABLED_FLAG"

# ---- 去抖：短时间内插拔不应产生通知 ----
# 注意：pg_monitor_tick 每轮都会重新读取 config.conf，去抖时间必须写进配置文件
printf '%s\n' "--- 去抖（AC_COOLDOWN=120）---"
cat > "$PG_CONFIG" <<'EOF'
PG_AC_COOLDOWN=120
PG_LOCAL_NOTIFY=true
EOF
rm -f "$PG_STATE"; pg_state_init
FAKE_AC=true; FAKE_PCT=80
pg_monitor_tick >/dev/null 2>&1 || true
FAKE_AC=false
pg_monitor_tick >/dev/null 2>&1 || true
expect power_lost 2
FAKE_AC=true
pg_monitor_tick >/dev/null 2>&1 || true
expect power_restored 1
expect power_lost 2
# 去抖期内插回电源：事件仍处于"待确认"状态（AC 稳定到 120s 才会播报恢复供电）
assert_state ac_pending restored

# 真正的断电（超过去抖时间）应报
FAKE_AC=false
pg_monitor_tick >/dev/null 2>&1 || true
pg_state_set ac_pending_ts 0
pg_monitor_tick >/dev/null 2>&1 || true
expect power_lost 3
expect power_restored 1

# ---- 读取失败告警 ----
printf '%s\n' "--- 读取失败（连续 3 次应告警）---"
pg_read_power() { PGV_OK=false; PG_PROVIDER=none; return 1; }
local_alarms=0
pg_notify_local() { local_alarms=$(( local_alarms + 1 )); printf '      >>> 本地告警：%s\n' "$1"; }
i=1
while [ "$i" -le 4 ]; do
  pg_monitor_tick >/dev/null 2>&1 || true
  i=$(( i + 1 ))
done
assert_state fail_count 4
assert_state fail_notified 1
if [ "$local_alarms" = "1" ]; then
  printf '      ✅ 本地告警恰好 1 次\n'
else
  printf '      ❌ 本地告警期望 1 次，实际 %s 次\n' "$local_alarms"; FAIL=$((FAIL+1))
fi

printf '\n===== 结果：%s =====\n' "$( [ "$FAIL" = "0" ] && printf '全部通过' || printf "%s 项失败" "$FAIL" )"

# 测试在仓库里建了个假的 data 目录（$PG_DIR/.testhome），跑完清掉；
# 想留着看现场就 PG_KEEP=1 bash tests/smoke-test.sh
if [ "${PG_KEEP:-0}" != "1" ]; then
  rm -rf "$PG_DIR/.testhome"
fi

exit "$FAIL"
