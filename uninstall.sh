#!/bin/bash
# PowerGuard 卸载脚本
#   ./uninstall.sh                停服务 + 删除开机启动项（保留配置和日志）
#   ./uninstall.sh --purge        连配置、日志、已安装的程序一起删掉
#   ./uninstall.sh --yes          不再逐项确认
set -u

PG_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$PG_DIR/lib/common.sh"

PURGE=false
ASSUME_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --purge|--all) PURGE=true ;;
    --yes|-y) ASSUME_YES=true ;;
    -h|--help)
      printf '%s\n' "用法：./uninstall.sh [--purge] [--yes]"
      exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

confirm() {  # confirm <提示>
  if [ "$ASSUME_YES" = "true" ]; then return 0; fi
  printf '%s [y/N] ' "$1"
  local a=""
  read -r a || true
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

printf '%s\n' "PowerGuard 卸载"
printf '%s\n' "----------------------------------------"

# ---------------------------------------------------------------------------
# 1. 停止并移除 launchd 服务
# ---------------------------------------------------------------------------
for label in "$PG_LABEL" "$PG_MENUBAR_LABEL"; do
  plist="$PG_LAUNCHAGENTS/$label.plist"
  if [ -f "$plist" ]; then
    printf '停止服务 %s …\n' "$label"
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist" && printf '  已删除 %s\n' "$plist"
  else
    printf '（未安装 %s，跳过）\n' "$label"
  fi
done

# launchd 有时会晚一点才真正杀掉进程，稍等一下再兜底
pg_sleep 2 || sleep 2
for pat in "powerguard.sh run" "PowerGuard.app/Contents/MacOS/PowerGuard"; do
  pids="$(pgrep -f "$pat" 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    printf '结束残留进程：%s\n' "$(printf '%s' "$pids" | tr '\n' ' ')"
    printf '%s\n' "$pids" | while IFS= read -r pid; do
      [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
  fi
done

# ---------------------------------------------------------------------------
# 2. 菜单栏 App
# ---------------------------------------------------------------------------
for app in "$HOME/Applications/PowerGuard.app" "/Applications/PowerGuard.app" "$PG_DIR/app/PowerGuard.app"; do
  if [ -d "$app" ]; then
    if confirm "删除菜单栏 App：$app ？"; then
      rm -rf "$app" && printf '已删除 %s\n' "$app"
    else
      printf '保留 %s\n' "$app"
    fi
  fi
done

# ---------------------------------------------------------------------------
# 3. 已安装的 CLI 副本
# ---------------------------------------------------------------------------
CLI_COPY="$PG_SUPPORT/cli"
if [ "$PURGE" = "true" ]; then
  for path in "$PG_SUPPORT" "$PG_LOGDIR"; do
    if [ -e "$path" ]; then
      if confirm "彻底删除 $path ？（配置、收件人、日志、状态都会没）"; then
        rm -rf "$path" && printf '已删除 %s\n' "$path"
      else
        printf '保留 %s\n' "$path"
      fi
    fi
  done
else
  printf '\n配置和日志都保留着：\n'
  printf '  配置   %s\n' "$PG_CONFIG"
  printf '  收件人 %s\n' "$PG_RECIPIENTS"
  printf '  日志   %s\n' "$PG_LOG"
  [ -d "$CLI_COPY" ] && printf '  CLI 副本 %s\n' "$CLI_COPY"
  printf '\n想连这些一起删掉，就再跑一次：./uninstall.sh --purge\n'
fi

printf '\n%s\n' "----------------------------------------"
printf '%s\n' "完成。系统设置里残留的「自动化」授权可以不管，也可以手动清掉："
printf '%s\n' "  系统设置 → 隐私与安全性 → 自动化"
