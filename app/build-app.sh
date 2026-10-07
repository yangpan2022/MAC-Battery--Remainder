#!/bin/bash
# 构建 PowerGuard.app（菜单栏 App）
#
#   ./build-app.sh            编译出 app/PowerGuard.app（通用二进制：arm64 + x86_64）
#   ./build-app.sh --run      编译完顺便打开看看
#   ./build-app.sh --no-universal   只编当前架构（快一点）
#
# 只需要 Xcode 命令行工具（xcode-select --install），不需要完整 Xcode。
# 部署目标写死 macOS 13.0，所以编译出来的 App 能直接在 M1 + macOS 13 上跑。
set -u

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$APP_DIR/PowerGuard.swift"
NAME="PowerGuard"
BUNDLE="$APP_DIR/$NAME.app"
VERSION="1.0.0"
MIN_MACOS="13.0"

DO_RUN=false
UNIVERSAL=true
while [ $# -gt 0 ]; do
  case "$1" in
    --run) DO_RUN=true ;;
    --no-universal) UNIVERSAL=false ;;
    -h|--help)
      printf '%s\n' "用法：./build-app.sh [--run] [--no-universal]"
      exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

printf '%s\n' "== PowerGuard 菜单栏 App 构建 =="

if ! command -v swiftc >/dev/null 2>&1; then
  printf '%s\n' "❌ 找不到 swiftc。" >&2
  printf '%s\n' "   请先安装 Xcode 命令行工具：xcode-select --install" >&2
  exit 1
fi
printf '   swiftc   %s\n' "$(swiftc --version 2>/dev/null | head -1)"
printf '   SDK      %s\n' "$(xcrun --show-sdk-version 2>/dev/null || echo 未知)"
printf '   部署目标 macOS %s\n' "$MIN_MACOS"

if [ ! -f "$SRC" ]; then
  printf '❌ 找不到源码：%s\n' "$SRC" >&2
  exit 1
fi

CONTENTS="$BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

# swiftc / clang 默认把临时文件和模块缓存写到 /var/folders 下的系统临时目录；
# 在某些受限环境（沙箱、被管理的机器）那里写不进去，会报
#   error: unable to open output file '.../ModuleCache/.../SwiftShims.pcm': Operation not permitted
# 并连带报出误导性的 "this SDK is not supported by the compiler"。
# 统一改到工作目录下，顺便让重复构建快一点。
BUILD_DIR="$APP_DIR/.build"
MOD_CACHE="$BUILD_DIR/swift-module-cache"
CLANG_CACHE="$BUILD_DIR/clang-module-cache"
mkdir -p "$BUILD_DIR/tmp" "$MOD_CACHE" "$CLANG_CACHE" 2>/dev/null || true
if [ -d "$BUILD_DIR/tmp" ] && [ -w "$BUILD_DIR/tmp" ]; then
  TMPDIR="$BUILD_DIR/tmp"; export TMPDIR
fi

printf '%s\n' "-> 清理旧产物"
rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# ---------------------------------------------------------------------------
# 编译
# ---------------------------------------------------------------------------
compile_arch() {  # compile_arch <架构> <输出文件>
  local arch="$1" out="$2"
  printf '%s\n' "-> 编译 ${arch} …"
  swiftc \
    -O -swift-version 5 -parse-as-library \
    -target "${arch}-apple-macos${MIN_MACOS}" \
    -module-cache-path "$MOD_CACHE" \
    -Xcc "-fmodules-cache-path=$CLANG_CACHE" \
    -framework AppKit \
    -o "$out" \
    "$SRC" || return 1
}

BIN="$MACOS_DIR/$NAME"
rm -f "$MACOS_DIR"/"$NAME".*
if [ "$UNIVERSAL" = "true" ]; then
  ARM="$MACOS_DIR/$NAME.arm64"
  INTEL="$MACOS_DIR/$NAME.x86_64"
  compile_arch arm64 "$ARM"  || { printf '%s\n' "❌ arm64 编译失败" >&2; exit 1; }
  if compile_arch x86_64 "$INTEL"; then
    printf '%s\n' "-> 合并成通用二进制"
    lipo -create -output "$BIN" "$ARM" "$INTEL" || cp "$ARM" "$BIN"
    rm -f "$ARM" "$INTEL"
  else
    printf '%s\n' "⚠️ x86_64 编译失败，只保留 arm64（M 系列芯片够用）"
    mv "$ARM" "$BIN"
    rm -f "$INTEL"
  fi
else
  compile_arch "$(uname -m)" "$BIN" || { printf '%s\n' "❌ 编译失败" >&2; exit 1; }
fi
chmod +x "$BIN"
printf '   产物 %s（%s）\n' "$BIN" "$(lipo -archs "$BIN" 2>/dev/null || echo '?')"

# ---------------------------------------------------------------------------
# Info.plist
# ---------------------------------------------------------------------------
printf '%s\n' "-> 写 Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.powerguard.menubar</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <!-- 菜单栏程序，不在 Dock 里显示、不抢焦点 -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <!-- 通过 AppleScript 控制「信息」App 时必须有这个说明，否则系统会直接拒绝 -->
  <key>NSAppleEventsUsageDescription</key>
  <string>PowerGuard 需要通过「信息」App 把断电和低电量提醒发到你的 iPhone。</string>
  <key>NSHumanReadableCopyright</key><string>PowerGuard $VERSION</string>
</dict>
</plist>
PLIST

if ! plutil -lint "$CONTENTS/Info.plist" >/dev/null 2>&1; then
  printf '%s\n' "❌ Info.plist 格式有问题" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 顺手把命令行脚本塞进 App 里，这样 App 单独拷走也能用
# ---------------------------------------------------------------------------
if [ -f "$APP_DIR/../powerguard.sh" ]; then
  printf '%s\n' "-> 把命令行脚本打包进 App/Contents/Resources"
  mkdir -p "$RES_DIR/lib"
  cp "$APP_DIR/../powerguard.sh" "$RES_DIR/powerguard.sh"
  cp "$APP_DIR/../lib/"*.sh "$RES_DIR/lib/"
  # 这几个让 App 自带"安装/卸载后台服务"的能力：菜单里的「启动后台服务」
  # 会调用与命令行同目录的 install.sh，所以 Resources 里的布局要和仓库一致。
  for f in doctor.sh install.sh uninstall.sh config.example com.powerguard.plist; do
    if [ -f "$APP_DIR/../$f" ]; then
      cp "$APP_DIR/../$f" "$RES_DIR/$f"
    else
      printf '   （跳过 %s：还没写）\n' "$f"
    fi
  done
  chmod +x "$RES_DIR"/*.sh 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 签名（ad-hoc 就够：本机自用，不需要开发者账号）
#
# 必须先 xattr -cr 再签名：拷贝进来的脚本带隔离/扩展属性时，codesign 会报
#   "resource fork, Finder information, or similar detritus not allowed"
# 而拒绝签名。
# ---------------------------------------------------------------------------
printf '%s\n' "-> 清扩展属性 + ad-hoc 签名"
signed=false
attempt=1
while [ "$attempt" -le 3 ]; do
  # FinderInfo 和文件提供者（桌面/iCloud）的属性会被系统随时加回来，
  # 所以每次签名前都清一遍，失败就重试。
  xattr -cr "$BUNDLE" 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$BUNDLE" 2>/dev/null || true
  xattr -d "com.apple.fileprovider.fpfs#P" "$BUNDLE" 2>/dev/null || true
  if codesign --force --deep --sign - "$BUNDLE" 2>/dev/null; then
    signed=true
    break
  fi
  attempt=$(( attempt + 1 ))
  sleep 1
done

if [ "$signed" = "true" ]; then
  printf '   %s\n' "$(codesign -dv "$BUNDLE" 2>&1 | grep -E 'Identifier|Signature' | tr '\n' ' ')"
else
  printf '%s\n' "⚠️ 签名失败（一般不影响本机运行；若被 Gatekeeper 拦，右键 → 打开）"
  codesign --force --deep --sign - "$BUNDLE" 2>&1 | head -3 | sed 's/^/   /'
fi

# 清掉隔离属性，避免从别的机器拷贝过来后打不开
xattr -cr "$BUNDLE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------
printf '%s\n' "-> 自检（--selftest：跑一次命令行解析，不打开界面）"
if "$BIN" --selftest 2>&1 | sed 's/^/   /' | head -12; then
  printf '%s\n' "   ✅ App 可执行、能读到状态"
else
  printf '%s\n' "   ⚠️ 自检返回非 0，看看上面的输出"
fi

printf '\n%s\n' "完成：$BUNDLE"
printf '   $ open "%s"      # 打开看看\n' "$BUNDLE"
printf '   想让它开机自启：在菜单里勾「登录时自动启动菜单栏」\n'

if [ "$DO_RUN" = "true" ]; then
  open "$BUNDLE"
fi
