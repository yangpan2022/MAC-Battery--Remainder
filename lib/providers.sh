#!/bin/bash
# PowerGuard - 电量/电源探测层
#
# 设计目标：对 macOS 版本变化免疫。
# 不假设任何一种输出格式永远不变，而是维护一条降级链：
#   1) IOKit   ioreg -rn AppleSmartBattery -w0   —— 数值型，最稳，Apple Silicon 原生
#   2) pmset   pmset -g batt                     —— 人类可读，用于交叉校验与剩余时间
#   3) sysprof system_profiler SPPowerDataType   —— 文本化兜底
# 主提供者失败会自动切换，并每 5 分钟重新探测一次。
#
# 探测结果（全局）：
#   PGV_OK        true/false
#   PGV_ON_AC     true/false
#   PGV_PCT       0-100 整数
#   PGV_CHARGING  true/false
#   PGV_FULL      true/false
#   PGV_MINUTES   整数分钟，空字符串表示未知
#   PGV_TEMP_C    摄氏度整数，空字符串表示未知
#   PGV_NOBATTERY true 表示这台机器没有电池（Mac mini / Studio）

PG_PROVIDER=""
PG_PROVIDER_CANDIDATES="iokit pmset sysprof"

pg_reset_power_vars() {
  PGV_OK=false
  PGV_ON_AC=""
  PGV_PCT=""
  PGV_CHARGING=""
  PGV_FULL=""
  PGV_MINUTES=""
  PGV_TEMP_C=""
  PGV_NOBATTERY=false
}

pg_is_num() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

pg_valid_minutes() {
  # iokit 用 65535 表示"不适用"，需要过滤
  pg_is_num "$1" || return 1
  [ "$1" -gt 0 ] 2>/dev/null || return 1
  [ "$1" -lt 65535 ] 2>/dev/null || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 提供者 1：IOKit
# ---------------------------------------------------------------------------
PG_IO_LINE=""

pg_io() {
  printf '%s\n' "$PG_IO_LINE" | grep -oE "\"$1\" = [^,]*" | head -1 | sed -E "s/^\"$1\" = //"
}

pg_probe_iokit() {
  PG_IO_LINE=""
  local line
  line=$(ioreg -rn AppleSmartBattery -w0 2>/dev/null)
  [ -n "$line" ] || return 1
  PG_IO_LINE="$line"

  local installed
  installed=$(pg_io BatteryInstalled)
  if [ "$installed" != "Yes" ]; then
    # 没有电池节点，或节点存在但未安装电池
    if [ -z "$installed" ]; then return 1; fi
    PGV_NOBATTERY=true
    return 2
  fi

  local ext chg full rawcur rawmax cur max temp a2e a2f
  ext=$(pg_io ExternalConnected)
  [ -n "$ext" ] || return 1
  case "$ext" in
    Yes) PGV_ON_AC=true ;;
    No)  PGV_ON_AC=false ;;
    *)   return 1 ;;
  esac

  # 百分比：优先用原始容量比值（真实百分比，含电池损耗），否则退回 CurrentCapacity
  rawcur=$(pg_io AppleRawCurrentCapacity)
  rawmax=$(pg_io AppleRawMaxCapacity)
  if pg_is_num "$rawcur" && pg_is_num "$rawmax" && [ "$rawmax" -gt 0 ]; then
    PGV_PCT=$(( (rawcur * 100 + rawmax / 2) / rawmax ))
  else
    cur=$(pg_io CurrentCapacity)
    max=$(pg_io MaxCapacity)
    pg_is_num "$cur" || return 1
    if pg_is_num "$max" && [ "$max" -gt 100 ]; then
      PGV_PCT=$(( (cur * 100 + max / 2) / max ))
    else
      PGV_PCT="$cur"
    fi
  fi
  [ "$PGV_PCT" -gt 100 ] 2>/dev/null && PGV_PCT=100
  [ "$PGV_PCT" -lt 0 ] 2>/dev/null && PGV_PCT=0

  chg=$(pg_io IsCharging)
  case "$chg" in Yes) PGV_CHARGING=true ;; *) PGV_CHARGING=false ;; esac
  full=$(pg_io FullyCharged)
  case "$full" in Yes) PGV_FULL=true ;; *) PGV_FULL=false ;; esac

  if [ "$PGV_ON_AC" = "true" ]; then
    if [ "$PGV_CHARGING" = "true" ]; then
      a2f=$(pg_io AvgTimeToFull)
      pg_valid_minutes "$a2f" && PGV_MINUTES="$a2f"
    fi
  else
    a2e=$(pg_io AvgTimeToEmpty)
    if pg_valid_minutes "$a2e"; then
      PGV_MINUTES="$a2e"
    else
      a2e=$(pg_io TimeRemaining)
      pg_valid_minutes "$a2e" && PGV_MINUTES="$a2e"
    fi
  fi

  temp=$(pg_io Temperature)
  if pg_is_num "$temp" && [ "$temp" -gt 0 ] && [ "$temp" -lt 20000 ]; then
    PGV_TEMP_C=$(( temp / 100 ))
  fi

  PGV_OK=true
  return 0
}

# ---------------------------------------------------------------------------
# 提供者 2：pmset
# ---------------------------------------------------------------------------
pg_probe_pmset() {
  local out
  out=$(pmset -g batt 2>/dev/null)
  [ -n "$out" ] || return 1

  local first line2
  first=$(printf '%s\n' "$out" | head -1)
  line2=$(printf '%s\n' "$out" | sed -n '2p')

  case "$first" in
    *"'AC Power'"*)      PGV_ON_AC=true ;;
    *"'Battery Power'"*) PGV_ON_AC=false ;;
    *"'UPS Power'"*)     PGV_ON_AC=false ;;
    *) return 1 ;;
  esac

  # 没有第二行 = 桌面机，无电池
  if [ -z "$line2" ]; then
    PGV_NOBATTERY=true
    return 2
  fi

  local pct
  pct=$(printf '%s\n' "$line2" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
  pg_is_num "$pct" || return 1
  PGV_PCT="$pct"

  # 中间字段：discharging / charging / charged / AC attached / finishing charge
  local st
  st=$(printf '%s\n' "$line2" | awk -F';' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  PGV_CHARGING=false
  PGV_FULL=false
  case "$st" in
    discharging) PGV_CHARGING=false ;;
    charging|"finishing charge") PGV_CHARGING=true ;;
    charged) PGV_FULL=true ;;
    "AC attached") PGV_CHARGING=false ;;
  esac

  local rem
  rem=$(printf '%s\n' "$line2" | grep -oE '[0-9]+:[0-9]{2} remaining' | head -1)
  if [ -n "$rem" ]; then
    local h m
    h="${rem%%:*}"
    m=$(printf '%s' "$rem" | sed -E 's/^[0-9]+:([0-9]{2}).*/\1/')
    if pg_is_num "$h" && pg_is_num "$m"; then
      PGV_MINUTES=$(( h * 60 + m ))
    fi
  fi

  PGV_OK=true
  return 0
}

# ---------------------------------------------------------------------------
# 提供者 3：system_profiler（兜底，通常 0.1~3 秒）
# ---------------------------------------------------------------------------
pg_probe_sysprof() {
  local out
  out=$(system_profiler SPPowerDataType 2>/dev/null)
  [ -n "$out" ] || return 1

  local pct
  pct=$(printf '%s\n' "$out" | sed -n 's/.*State of Charge (%): *\([0-9][0-9]*\).*/\1/p' | head -1)
  if [ -z "$pct" ]; then
    PGV_NOBATTERY=true
    return 2
  fi
  PGV_PCT="$pct"

  local src
  src=$(printf '%s\n' "$out" | awk '/AC Power:/{s="AC"} /Battery Power:/{s="BAT"} /Current Power Source: Yes/{print s}' | head -1)
  case "$src" in
    AC)  PGV_ON_AC=true ;;
    BAT) PGV_ON_AC=false ;;
    *)   return 1 ;;
  esac

  local chg full
  chg=$(printf '%s\n' "$out" | sed -n 's/^ *Charging: *\(Yes\|No\).*/\1/p' | head -1)
  case "$chg" in Yes) PGV_CHARGING=true ;; *) PGV_CHARGING=false ;; esac
  full=$(printf '%s\n' "$out" | sed -n 's/^ *Fully Charged: *\(Yes\|No\).*/\1/p' | head -1)
  case "$full" in Yes) PGV_FULL=true ;; *) PGV_FULL=false ;; esac

  PGV_OK=true
  return 0
}

# ---------------------------------------------------------------------------
# 调度
# ---------------------------------------------------------------------------
# 这台机器到底有没有电池（台式机/iMac/Mac mini 没有）
# 注意：pmset 第一行的 'Battery Power' 是"当前用电池供电"，不代表有电池，
# 所以要跳过第一行，只看后面那条形如 "94%; discharging;" 的电池明细行。
pg_has_battery() {
  local out
  out="$(/usr/bin/pmset -g batt 2>/dev/null | tail -n +2 || true)"
  case "$out" in
    *%*) printf 'true' ;;
    *)   printf 'false' ;;
  esac
}

pg_probe_with() {
  pg_reset_power_vars
  case "$1" in
    iokit)   pg_probe_iokit ;;
    pmset)   pg_probe_pmset ;;
    sysprof) pg_probe_sysprof ;;
    *) return 1 ;;
  esac
}

# 尝试某个提供者，把结果存进 PG_TMP_* 供比较
pg_probe_capture() {
  pg_probe_with "$1"
  PG_TMP_RC=$?
  PG_TMP_OK=$PGV_OK
  PG_TMP_ON_AC=$PGV_ON_AC
  PG_TMP_PCT=$PGV_PCT
  PG_TMP_CHARGING=$PGV_CHARGING
  PG_TMP_FULL=$PGV_FULL
  PG_TMP_MINUTES=$PGV_MINUTES
  PG_TMP_TEMP=$PGV_TEMP_C
  PG_TMP_NOBAT=$PGV_NOBATTERY
}

# 运行所有提供者做一次探测，选定主提供者，并交叉校验
# 返回 0 = 至少有一个可用；2 = 确认无电池；1 = 全部失败
pg_detect_provider() {
  local iokit_ok=false pmset_ok=false sysprof_ok=false nob=false
  local iokit_ac="" iokit_pct="" pmset_ac="" pmset_pct=""

  pg_probe_capture iokit
  if [ "$PG_TMP_OK" = "true" ]; then
    iokit_ok=true; iokit_ac="$PG_TMP_ON_AC"; iokit_pct="$PG_TMP_PCT"
  elif [ "$PG_TMP_NOBAT" = "true" ]; then
    nob=true
  fi

  pg_probe_capture pmset
  if [ "$PG_TMP_OK" = "true" ]; then
    pmset_ok=true; pmset_ac="$PG_TMP_ON_AC"; pmset_pct="$PG_TMP_PCT"
  elif [ "$PG_TMP_NOBAT" = "true" ]; then
    nob=true
  fi

  if [ "$iokit_ok" = "false" ] && [ "$pmset_ok" = "false" ]; then
    pg_probe_capture sysprof
    if [ "$PG_TMP_OK" = "true" ]; then
      sysprof_ok=true
    elif [ "$PG_TMP_NOBAT" = "true" ]; then
      nob=true
    fi
  fi

  # 交叉校验：两个主提供者对不上就记日志（以 IOKit 为准）
  if [ "$iokit_ok" = "true" ] && [ "$pmset_ok" = "true" ]; then
    local d=$(( iokit_pct - pmset_pct ))
    [ "$d" -lt 0 ] && d=$(( -d ))
    if [ "$d" -gt 2 ]; then
      pg_log_warn "provider disagreement: iokit=${iokit_pct}% pmset=${pmset_pct}% (以 iokit 为准)"
    fi
    if [ "$iokit_ac" != "$pmset_ac" ]; then
      pg_log_warn "provider disagreement: AC 状态 iokit=${iokit_ac} pmset=${pmset_ac} (以 iokit 为准)"
    fi
  fi

  local chosen=""
  if [ "$iokit_ok" = "true" ]; then chosen=iokit
  elif [ "$pmset_ok" = "true" ]; then chosen=pmset
  elif [ "$sysprof_ok" = "true" ]; then chosen=sysprof
  fi

  if [ -n "$chosen" ]; then
    if [ "$PG_PROVIDER" != "$chosen" ]; then
      pg_log_info "provider switched: '${PG_PROVIDER:-none}' -> '${chosen}'"
    fi
    PG_PROVIDER="$chosen"
    return 0
  fi

  if [ "$nob" = "true" ]; then
    pg_log_warn "未检测到电池（可能是 Mac mini / Mac Studio 这类无电池机型）"
    return 2
  fi

  pg_log_error "三层提供者全部失败：ioreg / pmset / system_profiler 都读不到电源状态"
  return 1
}

# 读取一次电源状态。主提供者失败时立刻重新探测。
# 返回 0 成功 / 2 无电池 / 1 失败
pg_read_power() {
  if [ -n "$PG_PROVIDER" ]; then
    pg_probe_with "$PG_PROVIDER"
    if [ "$PGV_OK" = "true" ]; then
      pg_fill_minutes_from_pmset
      return 0
    fi
    pg_log_warn "提供者 '$PG_PROVIDER' 读取失败，重新探测"
  fi

  local rc=0
  pg_detect_provider || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  pg_probe_with "$PG_PROVIDER"
  if [ "$PGV_OK" != "true" ]; then
    pg_log_error "重新探测后仍无法读取电源状态（provider=${PG_PROVIDER}）"
    return 1
  fi
  pg_fill_minutes_from_pmset
  return 0
}

# 主提供者给不出剩余时间时，借用 pmset 的估算（pmset 调用约 15ms）
pg_fill_minutes_from_pmset() {
  [ -n "$PGV_MINUTES" ] && return 0
  [ "$PG_PROVIDER" = "pmset" ] && return 0
  local saved_on_ac saved_pct saved_chg saved_full
  saved_on_ac="$PGV_ON_AC"; saved_pct="$PGV_PCT"
  saved_chg="$PGV_CHARGING"; saved_full="$PGV_FULL"
  if pg_probe_pmset >/dev/null 2>&1; then
    if [ -n "$PGV_MINUTES" ] && [ "$PGV_ON_AC" = "$saved_on_ac" ]; then
      PGV_MINUTES="$PGV_MINUTES"
    else
      PGV_MINUTES=""
    fi
  fi
  PGV_ON_AC="$saved_on_ac"; PGV_PCT="$saved_pct"
  PGV_CHARGING="$saved_chg"; PGV_FULL="$saved_full"
  PGV_OK=true
  return 0
}
