#!/bin/bash
#
# 打「首次安装用」的 dmg（拖到 /Applications）。更新通道仍然只走 zip：
# dmg 要挂载，适合人手动装；zip 直接 ditto 展开，适合程序替换。
#
#   Scripts/make-dmg.sh build/Brimio.app --tag v1.0.0
#   Scripts/make-dmg.sh build/Brimio.app --tag v1.0.0 --out dist
#
# 产出 dist/<repo>-<tag>.dmg 与同名 .sha256（内容只写裸文件名）。
# 不做签名、不公证：首次打开会被 Gatekeeper 拦，绕行方式见 Release/RELEASE-PLAN.md 第 8 节。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/Config/naming.env"

APP=""
TAG=""
OUT="$ROOT/dist"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag) TAG="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) APP="$1"; shift ;;
    esac
done

[[ -n "$APP" && -d "$APP" ]] || { echo "用法：make-dmg.sh <App.app> --tag <vX.Y.Z>" >&2; exit 2; }
[[ -n "$TAG" ]] || { echo "缺少 --tag" >&2; exit 2; }

PLIST="$APP/Contents/Info.plist"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
TAG_SHORT="${TAG#v}"; TAG_SHORT="${TAG_SHORT%%-*}"
[[ "$SHORT" == "$TAG_SHORT" ]] || { echo "FAIL plist version=$SHORT 与 tag=$TAG 不一致" >&2; exit 1; }
[[ "$BUNDLE_ID" == "$APP_BUNDLE_ID" ]] || { echo "FAIL bundle id=$BUNDLE_ID" >&2; exit 1; }

DMG_NAME="${APP_REPO}-${TAG}.dmg"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
DMG="$OUT/$DMG_NAME"

STAGE="$(mktemp -d)"
MOUNT="$(mktemp -d)"
cleanup() {
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
    rm -rf "$STAGE" "$MOUNT"
}
trap cleanup EXIT

# 布局：左边 app，右边 /Applications 快捷方式（Finder 里就是「拖过去」）。
ditto "$APP" "$STAGE/$APP_BUNDLE_NAME.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -quiet -volname "$APP_DISPLAY_NAME $TAG" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "$DMG"

# 回读：挂载只读，确认包内版本与权限没在打包过程中损坏。
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
INSIDE_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT/$APP_BUNDLE_NAME.app/Contents/Info.plist")"
INSIDE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MOUNT/$APP_BUNDLE_NAME.app/Contents/Info.plist")"
[[ -x "$MOUNT/$APP_BUNDLE_NAME.app/Contents/MacOS/$APP_BUNDLE_NAME" ]] || { echo "FAIL dmg 内可执行文件缺失" >&2; exit 1; }
[[ -L "$MOUNT/Applications" ]] || { echo "FAIL dmg 内缺少 /Applications 快捷方式" >&2; exit 1; }
hdiutil detach "$MOUNT" -quiet
[[ "$INSIDE_SHORT" == "$SHORT" && "$INSIDE_BUILD" == "$BUILD" ]] || {
    echo "FAIL dmg 内版本回读不一致：$INSIDE_SHORT/$INSIDE_BUILD" >&2; exit 1;
}

( cd "$OUT" && shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256" )
echo "[dmg] $DMG"
echo "[dmg] version=$SHORT build=$BUILD size=$(stat -f%z "$DMG")"
echo "[dmg] 注意：dmg 只用于首次安装；自动更新走 zip（见 Release/RELEASE-PLAN.md 第 7 节）"
