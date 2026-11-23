#!/bin/bash
# Builds 音乐.app (arm64 only) and packs it into a distributable DMG.
#
#   ./tools/make-dmg.sh                 → build/音乐-<version>.dmg
#
# The app is ad-hoc signed (no Developer ID on this machine), so the receiving
# Mac has to get past Gatekeeper once. The DMG ships a tiny "首次打开.command"
# that clears the quarantine flag, plus the standard drag-to-Applications link.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="音乐"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 1.0)"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"
STAGE="$ROOT/build/dmg"

echo "▸ arm64 build (Apple silicon only — no Intel support)"
./build.sh >/dev/null
APP="$ROOT/build/$APP_NAME.app"

echo "▸ sign inside-out (ad-hoc)"
# Nested code has to be signed before the bundle that contains it.
if [ -d "$APP/Contents/Frameworks" ]; then
    find "$APP/Contents/Frameworks" -depth -name "*.framework" -o -depth -name "*.dylib" | while read -r item; do
        codesign --force --sign - "$item" >/dev/null 2>&1 || true
    done
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
codesign --verify --deep --strict "$APP"

echo "▸ resource bundle check"
# SwiftPM's Bundle.module looks next to the .app and in this machine's .build
# directory — neither exists on the receiving Mac, and the resulting fatalError
# only shows up there. Fail the build here instead.
HIDDEN="$ROOT/.build.hidden-for-check"
if [ -d "$ROOT/.build" ]; then mv "$ROOT/.build" "$HIDDEN"; fi
restore_build() { if [ -d "$HIDDEN" ]; then mv "$HIDDEN" "$ROOT/.build"; fi; }
trap restore_build EXIT
CHECK="$ROOT/build/resource-check.app"
rm -rf "$CHECK"
cp -R "$APP" "$CHECK"
if ! "$CHECK/Contents/MacOS/Music" --resource-check; then
    echo "✗ the resource bundle is not reachable from inside the app"
    exit 1
fi
rm -rf "$CHECK"
restore_build
trap - EXIT

echo "▸ staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/首次打开.command" <<'SCRIPT'
#!/bin/bash
# 这个脚本做三件事：检查这台 Mac 是否满足要求、清掉下载带来的隔离标记、试跑一次并
# 把失败原因留在窗口里。双击即可。
cd "$(dirname "$0")" || exit 1

APP="$(pwd)/音乐.app"
if [ -d "/Applications/音乐.app" ]; then
    APP="/Applications/音乐.app"
fi

echo "音乐 — 启动检查"
echo "----------------------------------------"
printf '机器架构：%s\n' "$(uname -m)"
printf '系统版本：macOS %s\n' "$(sw_vers -productVersion)"
printf 'App 位置：%s\n\n' "$APP"
echo

ARCH="$(uname -m)"
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"

if [ "$ARCH" != "arm64" ]; then
    printf '✗ 这台 Mac 是 %s（Intel）。这个 App 只有 Apple 芯片（arm64）版本，\n' "$ARCH"
    echo "  在 Intel Mac 上无法运行 —— 这是刻意的，不做 Intel 兼容。"
    echo
    echo "（按任意键关闭）"; read -n 1 -s; exit 1
fi

if [ "${MAJOR:-0}" -lt 14 ]; then
    printf '✗ 需要 macOS 14 或更高，当前是 macOS %s。\n' "$(sw_vers -productVersion)"
    echo
    echo "（按任意键关闭）"; read -n 1 -s; exit 1
fi

echo "▸ 清除隔离标记"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP" 2>/dev/null && echo "  签名校验通过" || echo "  （签名校验失败，继续尝试启动）"
echo

echo "▸ 启动一次，看看有没有报错"
LOG="$(mktemp "${TMPDIR:-/tmp}/music-launch.XXXXXX")"
"$APP/Contents/MacOS/Music" >"$LOG" 2>&1 &
PID=$!
sleep 3

if kill -0 "$PID" 2>/dev/null; then
    printf '  ✓ 已启动（进程 %s），正常应该已经看到窗口了。\n' "$PID"
    echo
    echo "以后直接双击「音乐」即可，不需要再跑这个脚本。"
else
    echo "  ✗ 启动失败，下面是它的输出："
    echo "  ----------------------------------------"
    sed 's/^/  /' "$LOG"
    echo "  ----------------------------------------"
    echo "  把这段文字发给我，我来定位。"
fi
rm -f "$LOG"

echo
echo "（按任意键关闭本窗口）"
read -n 1 -s
SCRIPT
chmod +x "$STAGE/首次打开.command"

cat > "$STAGE/请先看我.txt" <<'TEXT'
音乐 — 原生 macOS 音乐播放器
==============================

安装
1. 把「音乐.app」拖到 Applications 文件夹（右边那个快捷方式）。
2. 双击「首次打开.command」，它会清掉 macOS 给下载文件加的隔离标记。
3. 双击「音乐」启动。

如果第 2 步不想用脚本，也可以在「系统设置 → 隐私与安全性」里
点「仍要打开」，或者右键点 App 选「打开」。

首次启动会显示内置示例资料库（截图里的 Aimer 三张专辑）。
要听自己的音乐：⌘O 选择音乐文件夹，扫描完成后会自动缓存，
之后启动不再重新扫描（⌘R 可强制重扫）。

TEXT
printf '\n版本 %s · Apple 芯片（arm64），需要 macOS 14 或更高。Intel Mac 不支持（没有 x86_64 切片）。\n' \
    "$VERSION" >> "$STAGE/请先看我.txt"

echo "▸ hdiutil"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ $DMG  ($(du -h "$DMG" | cut -f1))"
