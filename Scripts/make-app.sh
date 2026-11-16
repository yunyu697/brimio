#!/bin/bash
#
# 把 SwiftPM 产物打成最小 .app。
#
# 为什么需要它：Automation（Apple Events）授权是 TCC 按「调用方 app 的身份」记录的。
# 直接 `swift run` / 跑裸二进制时，TCC 会把授权记在启动它的终端（Trae / Terminal）头上，
# 「被拒绝 → 面板引导 → 跳系统设置」这条路径就测不出来。打成带 bundle id 的 .app 后，
# 授权弹窗、拒绝、跳设置才是真实路径。
#
# 名字与版本都不在本脚本里硬编码：
#   - 显示名 / .app 名 / 可执行名 / bundle id / 资产模板 ← `Config/naming.env`
#   - 版本号 ← git tag（唯一事实来源），本脚本只做注入与一致性校验
#
# 产出是**未签名**的 .app：不跑 codesign、不额外 chmod（cp 本身就保留了可执行位）。
#
# 用法：
#   bash Scripts/make-app.sh                      # debug
#   CONFIG=release bash Scripts/make-app.sh       # release
#   PACKAGE=1 CONFIG=release bash Scripts/make-app.sh
#                                                 # 额外产出 Release 资产 zip（dist/<asset>）
#
# 可选环境变量：
#   SCRATCH=/abs/scratch   # `swift build --scratch-path`
#   OUT=/abs/Brimio.app    # 指定 .app 输出位置，默认 $ROOT/build/<APP_NAME>.app
#   PACKAGE=1              # 额外打 zip，命名取自 naming.sh 的资产模板
#   DIST=/abs/dir          # zip 输出目录，默认 $ROOT/dist
#   TAG=v1.0.0-alpha1      # 直接指定版本，优先级高于 git describe（无仓库时演练用）
#   VERIFY_TAG=v1.0.0...   # CI 传入 ref 上的 tag；与 TAG 不同即 FAIL
#
# 版本规则（与 Scripts/version-check.sh、CI 同一套）：
#   有精确 tag  -> CFBundleShortVersionString = tag 去掉 v 与后缀，CFBundleVersion = 提交数
#                  注入后读回 plist 比对，不等于 tag 即 FAIL
#   没有 tag    -> 0.0.0 / 0，并打印 WARN（本地开发态；发布产物必须来自 tag）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 命名单一来源
# shellcheck disable=SC1091
source "$ROOT/Config/naming.env"

APP_NAME="$APP_BUNDLE_NAME"
APP_BUNDLE_ID_FINAL="$APP_BUNDLE_ID"
CONFIG="${CONFIG:-debug}"

BUILD_ARGS=(--package-path "$ROOT" -c "$CONFIG")
if [[ -n "${SCRATCH:-}" ]]; then
    BUILD_ARGS+=(--scratch-path "$SCRATCH")
fi

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

# MARK: - 版本注入

# tag 来源优先级：环境变量 TAG > git describe --exact-match。
# 前者用于「没有仓库也要验证注入链路」的场景（本地演练、CI 的 workflow_dispatch）。
if [[ -n "${TAG:-}" ]]; then
    VERSION_SOURCE="env TAG"
elif TAG="$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null)"; then
    VERSION_SOURCE="git tag"
else
    TAG=""
    VERSION_SOURCE="no tag (dev)"
fi

# CI 会把 ref 上的 tag 另外传进来（VERIFY_TAG 或 GITHUB_REF_NAME）。
# 注入源与 ref 不一致 = 「代码不是从那个 tag 构建的」，必须 FAIL。
VERIFY_TAG="${VERIFY_TAG:-${GITHUB_REF_NAME:-}}"
if [[ -n "$VERIFY_TAG" && -n "$TAG" && "$VERIFY_TAG" != "$TAG" ]]; then
    echo "[make-app] FAIL VERIFY_TAG=$VERIFY_TAG 与 TAG=$TAG 不一致：tag 与注入值必须同源" >&2
    exit 1
fi

if [[ -n "$TAG" ]]; then
    # 非法 tag 直接终止，不允许把不合规的版本打进包。
    if ! VERSION_REPORT="$(bash "$ROOT/Scripts/version-check.sh" "$TAG" 2>&1)"; then
        echo "[make-app] FAIL 非法 tag：$TAG" >&2
        echo "$VERSION_REPORT" >&2
        exit 1
    fi
    SHORT_VERSION="${TAG#v}"
    SHORT_VERSION="${SHORT_VERSION%%-*}"
    # 完整 tag 与通道写进 plist 的独立键：CFBundleShortVersionString 会丢掉 -alphaN 后缀，
    # 只靠它无法区分 alpha 与正式版，更新检查器和「关于」面板需要这两个键。
    RELEASE_CHANNEL="$(bash "$ROOT/Scripts/version-check.sh" --stage "$TAG")"
    # CFBundleVersion 规则：优先提交数（单调递增，覆盖任意 tag）；没有 git 时退回
    # 预发布序号（alphaN / RCN 的 N），正式版为 0。两者都不手写。
    if COMMITS="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null)"; then
        BUILD_NUMBER="$COMMITS"
        BUILD_SOURCE="提交数"
    else
        if [[ "$TAG" =~ -(alpha|RC)([0-9]+)$ ]]; then
            BUILD_NUMBER="${BASH_REMATCH[2]}"
        else
            BUILD_NUMBER="0"
        fi
        BUILD_SOURCE="预发布序号"
    fi
else
    SHORT_VERSION="0.0.0"
    BUILD_NUMBER="0"
    BUILD_SOURCE="dev"
    RELEASE_CHANNEL="dev"
    echo "[make-app] WARN 当前 HEAD 没有精确 tag：注入 0.0.0/0，仅供本地调试；发布产物必须由 tag 构建" >&2
fi

APP="${OUT:-$ROOT/build/$APP_NAME.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# cp 保留源文件的可执行位，不需要再 chmod。
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# NSAppleEventsUsageDescription 是 Automation 弹窗里给用户看的理由文案；
# 缺了它，macOS 会直接拒绝 Apple Event（-1743），弹窗都不会出现。
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_BUNDLE_ID_FINAL}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>读取当前播放的曲目信息，并控制播放/上一首/下一首。</string>
    <key>BrimioReleaseTag</key>
    <string>${TAG:-}</string>
    <key>BrimioChannel</key>
    <string>${RELEASE_CHANNEL}</string>
</dict>
</plist>
PLIST

# MARK: - 注入校验（tag 与 plist 不一致即 FAIL）

read_plist() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null
}

PLIST_SHORT="$(read_plist CFBundleShortVersionString)"
PLIST_BUILD="$(read_plist CFBundleVersion)"
PLIST_ID="$(read_plist CFBundleIdentifier)"

if [[ "$PLIST_SHORT" != "$SHORT_VERSION" || "$PLIST_BUILD" != "$BUILD_NUMBER" ]]; then
    echo "[make-app] FAIL 注入值回读不一致：plist=$PLIST_SHORT/$PLIST_BUILD 期望=$SHORT_VERSION/$BUILD_NUMBER" >&2
    exit 1
fi
if [[ -n "$TAG" ]]; then
    EXPECTED_SHORT="${TAG#v}"
    EXPECTED_SHORT="${EXPECTED_SHORT%%-*}"
    if [[ "$PLIST_SHORT" != "$EXPECTED_SHORT" ]]; then
        echo "[make-app] FAIL tag=$TAG 与 CFBundleShortVersionString=$PLIST_SHORT 不一致" >&2
        exit 1
    fi
fi
if [[ "$PLIST_ID" != "$APP_BUNDLE_ID_FINAL" ]]; then
    echo "[make-app] FAIL bundle id 回读不一致：$PLIST_ID" >&2
    exit 1
fi
if [[ -n "$TAG" ]]; then
    PLIST_TAG="$(read_plist BrimioReleaseTag)"
    PLIST_CHANNEL="$(read_plist BrimioChannel)"
    if [[ "$PLIST_TAG" != "$TAG" || "$PLIST_CHANNEL" != "$RELEASE_CHANNEL" ]]; then
        echo "[make-app] FAIL 发布标记回读不一致：tag=$PLIST_TAG channel=$PLIST_CHANNEL 期望=$TAG/$RELEASE_CHANNEL" >&2
        exit 1
    fi
fi

echo "[make-app] ${APP}（未签名）"
echo "[make-app] version=${SHORT_VERSION} build=${BUILD_NUMBER}（${BUILD_SOURCE}） tag=${TAG:-<none>} from ${VERSION_SOURCE}"
echo "[make-app] bundle-id=${PLIST_ID} name=${APP_NAME} display=${APP_DISPLAY_NAME}"
echo "[make-app] 二进制来源：${BIN_DIR}/${APP_NAME}"
shasum -a 256 "$APP/Contents/MacOS/$APP_NAME" | awk '{print "[make-app] sha256(bundle)=" $1}'
shasum -a 256 "$BIN_DIR/$APP_NAME" | awk '{print "[make-app] sha256(built)=" $1}'

# MARK: - Release 资产（命名规则与更新检查器同源）

if [[ "${PACKAGE:-0}" == "1" ]]; then
    if [[ -n "$TAG" ]]; then
        ASSET="$(bash "$ROOT/Scripts/naming.sh" --asset "$TAG")"
    else
        ASSET="$(bash "$ROOT/Scripts/naming.sh" --asset "0.0.0-dev")"
    fi
    DIST="${DIST:-$ROOT/dist}"
    mkdir -p "$DIST"
    rm -f "$DIST/$ASSET" "$DIST/$ASSET.sha256"
    # ditto 保留 bundle 的资源分叉与权限，是 macOS 上打 .app 压缩包的正确工具。
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ASSET"
    # 校验文件里只写裸文件名：带绝对路径的话，用户下载后 `shasum -c` 会指向构建机上的路径而失败。
    ( cd "$DIST" && shasum -a 256 "$ASSET" | tee "$ASSET.sha256" )
    echo "[make-app] asset=$(basename "$DIST/$ASSET")"
fi

echo "[make-app] 启动：open \"$APP\""
