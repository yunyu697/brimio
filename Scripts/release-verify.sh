#!/bin/bash
#
# 发布资产校验：把一个 .zip 当成「已经上传到 Release 的东西」来验证。
#
# 校验链（任一失败即 exit 1）：
#   1. 资产存在、非空、后缀与 Config/release.env 的 UPDATE_ASSET_FORMAT 一致
#   2. 同名 .sha256 存在；内容只写「裸文件名」，`shasum -a 256 -c` 能直接过
#   3. zip 内恰好一个顶层 <APP>.app；没有绝对路径 / `..` 条目
#   4. Info.plist：bundle id、short version、build、通道标记、最低系统版本
#   5. 可执行文件是 Mach-O（架构写进输出，arm64-only 的包在 Intel 上跑不了）
#
# 为什么不用签名：本项目不分发签名包（无证书、不公证），完整性只靠 sha256。
# 因此这里必须把「哈希 + 版本串 + 包内 plist」三者绑在一起核对，缺一不可。
#
# 用法：
#   Scripts/release-verify.sh v1.0.0-beta1 dist/brimio-v1.0.0-beta1.zip
#   Scripts/release-verify.sh --expect-sha <hex> v1.0.0-beta1 dist/...
#   Scripts/release-verify.sh --json v1.0.0-beta1 dist/...      # 单行 JSON，给脚本吃
#
# 退出码：0 通过，1 失败，2 用法错误
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/Config/naming.env"
# shellcheck disable=SC1091
source "$ROOT/Config/release.env"

JSON=0
EXPECT_SHA=""
EXPECT_BUILD=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON=1; shift ;;
        --expect-sha) EXPECT_SHA="${2:-}"; shift 2 ;;
        --expect-build) EXPECT_BUILD="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

TAG="${ARGS[0]:-}"
ASSET="${ARGS[1]:-}"
if [[ -z "$TAG" || -z "$ASSET" ]]; then
    echo "用法：release-verify.sh [--json] [--expect-sha HEX] [--expect-build N] <tag> <asset.zip>" >&2
    exit 2
fi

hits=0
report() { # key value
    if [[ "$JSON" -eq 0 ]]; then echo "[verify] $1=$2"; fi
}
fail() {
    echo "[verify] FAIL $1" >&2
    hits=$((hits + 1))
}
ok() { # key value
    report "$1" "$2"
}

# MARK: - 1. 资产基本形态

if [[ ! -f "$ASSET" ]]; then
    fail "资产不存在：$ASSET"
    echo "[verify] RESULT FAIL" >&2
    exit 1
fi
ASSET="$(cd "$(dirname "$ASSET")" && pwd)/$(basename "$ASSET")"
ASSET_NAME="$(basename "$ASSET")"
SIZE="$(stat -f%z "$ASSET")"
if [[ "$SIZE" -le 0 ]]; then fail "资产为空"; fi
case "$UPDATE_ASSET_FORMAT" in
    zip) [[ "$ASSET_NAME" == *.zip ]] || fail "资产后缀不是 .zip：$ASSET_NAME" ;;
    *) fail "Config/release.env 里 UPDATE_ASSET_FORMAT=$UPDATE_ASSET_FORMAT 不受支持" ;;
esac

# 命名必须与模板同源，否则镜像/更新器按模板拼出来的 URL 会 404。
EXPECTED_ASSET="$(bash "$ROOT/Scripts/naming.sh" --asset "$TAG")"
if [[ "$ASSET_NAME" != "$EXPECTED_ASSET" ]]; then
    fail "资产名 $ASSET_NAME 与命名模板 $EXPECTED_ASSET 不一致"
fi
ok asset "$ASSET_NAME"
ok size "$SIZE"

# MARK: - 2. sha256 文件

SHA256="$(shasum -a 256 "$ASSET" | awk '{print $1}')"
ok sha256 "$SHA256"

SHA_FILE="${ASSET}.sha256"
if [[ ! -f "$SHA_FILE" ]]; then
    fail "缺少校验文件：$(basename "$SHA_FILE")"
else
    SHA_LINE="$(head -1 "$SHA_FILE")"
    # 只允许「<64位hex><两个空格><裸文件名>」，带路径会让用户 `shasum -c` 指向构建机路径。
    if [[ ! "$SHA_LINE" =~ ^([0-9a-f]{64})\ \ (.+)$ ]]; then
        fail ".sha256 格式非法（期望：<hex>  <裸文件名>）"
    else
        FILE_SHA="${BASH_REMATCH[1]}"
        FILE_NAME="${BASH_REMATCH[2]}"
        [[ "$FILE_NAME" == "$ASSET_NAME" ]] || fail ".sha256 里写的是 $FILE_NAME，不是裸文件名 $ASSET_NAME"
        [[ "$FILE_SHA" == "$SHA256" ]] || fail ".sha256 内容与实测哈希不一致"
    fi
fi

if [[ -n "$EXPECT_SHA" && "$EXPECT_SHA" != "$SHA256" ]]; then
    fail "清单里的 sha256=$EXPECT_SHA 与实测=$SHA256 不一致"
fi

# MARK: - 3. zip 结构

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! unzip -tq "$ASSET" >/dev/null 2>&1; then
    fail "zip 完整性检查失败（unzip -t）"
    echo "[verify] RESULT FAIL ($hits)" >&2
    exit 1
fi

ENTRIES="$(unzip -Z1 "$ASSET")"
if grep -q -E '(^/|(^|/)\.\.(/|$))' <<< "$ENTRIES"; then
    fail "zip 内含绝对路径或 `..` 条目"
fi

TOP_LEVEL="$(awk -F/ 'NF>1 || $0 ~ /\/$/{print $1}' <<< "$ENTRIES" | sort -u | grep -v '^__MACOSX$' || true)"
TOP_COUNT="$(grep -c . <<< "$TOP_LEVEL" || true)"
if [[ "$TOP_COUNT" != "1" ]]; then
    fail "zip 顶层应当只有 1 个条目，实际 ${TOP_COUNT} 个：$(tr '\n' ' ' <<< "$TOP_LEVEL")"
fi
APP_DIR="${TOP_LEVEL%%/}"
if [[ "$APP_DIR" != "$APP_BUNDLE_NAME.app" ]]; then
    fail "顶层目录 $APP_DIR 不是 $APP_BUNDLE_NAME.app"
fi

PLIST_ENTRY="$APP_DIR/Contents/Info.plist"
BIN_ENTRY="$APP_DIR/Contents/MacOS/$APP_BUNDLE_NAME"
if ! grep -qx "$PLIST_ENTRY" <<< "$ENTRIES"; then fail "zip 内缺少 $PLIST_ENTRY"; fi
if ! grep -qx "$BIN_ENTRY" <<< "$ENTRIES"; then fail "zip 内缺少 $BIN_ENTRY"; fi
if [[ "$hits" -gt 0 ]]; then
    echo "[verify] RESULT FAIL ($hits)" >&2
    exit 1
fi

# MARK: - 4. 包内 Info.plist

plist_get() { # key
    unzip -p "$ASSET" "$PLIST_ENTRY" 2>/dev/null | plutil -extract "$1" raw -o - - 2>/dev/null
}

BUNDLE_ID="$(plist_get CFBundleIdentifier)"
SHORT="$(plist_get CFBundleShortVersionString)"
BUILD="$(plist_get CFBundleVersion)"
MIN_OS="$(plist_get LSMinimumSystemVersion)"
PLIST_TAG="$(plist_get BrimioReleaseTag)"
PLIST_CHANNEL="$(plist_get BrimioChannel)"

TAG_SHORT="${TAG#v}"; TAG_SHORT="${TAG_SHORT%%-*}"
STAGE="$(bash "$ROOT/Scripts/version-check.sh" --stage "$TAG")"
ORDER_KEY="$(bash "$ROOT/Scripts/version-check.sh" --order-key "$TAG")"

[[ "$BUNDLE_ID" == "$APP_BUNDLE_ID" ]] || fail "bundle id=$BUNDLE_ID 期望=$APP_BUNDLE_ID"
[[ "$SHORT" == "$TAG_SHORT" ]] || fail "CFBundleShortVersionString=$SHORT 与 tag $TAG 不一致"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "CFBundleVersion=$BUILD 不是数字"
if [[ -n "$EXPECT_BUILD" && "$BUILD" != "$EXPECT_BUILD" ]]; then
    fail "CFBundleVersion=$BUILD 与期望 $EXPECT_BUILD 不一致"
fi
[[ "$MIN_OS" == "$MIN_MACOS" ]] || fail "LSMinimumSystemVersion=$MIN_OS 期望=$MIN_MACOS"
# BrimioReleaseTag/BrimioChannel 是 make-app.sh 新注入的键；alpha1 及更早的包没有，
# 缺失只告警不失败，避免把历史资产判死。
if [[ -z "$PLIST_TAG" ]]; then
    report warn "包内没有 BrimioReleaseTag（历史资产），通道只能从 tag 反推"
else
    [[ "$PLIST_TAG" == "$TAG" ]] || fail "包内 BrimioReleaseTag=$PLIST_TAG 与 tag 不一致"
    [[ "$PLIST_CHANNEL" == "$STAGE" ]] || fail "包内 BrimioChannel=$PLIST_CHANNEL 与 stage=$STAGE 不一致"
fi

# MARK: - 5. 可执行文件

FILE_OUT="$(unzip -p "$ASSET" "$BIN_ENTRY" 2>/dev/null | file -b -)"
[[ "$FILE_OUT" == *Mach-O* ]] || fail "可执行文件不是 Mach-O：$FILE_OUT"
ARCH="unknown"
case "$FILE_OUT" in
    *universal*) ARCH="universal" ;;
    *arm64*) ARCH="arm64" ;;
    *x86_64*) ARCH="x86_64" ;;
esac
ok arch "$ARCH"
ok bundle_id "$BUNDLE_ID"
ok version "$SHORT"
ok build "$BUILD"
ok stage "$STAGE"
ok order_key "$ORDER_KEY"
ok min_os "$MIN_OS"

if [[ "$hits" -gt 0 ]]; then
    echo "[verify] RESULT FAIL ($hits)" >&2
    exit 1
fi

if [[ "$JSON" -eq 1 ]]; then
    python3 - "$TAG" "$SHORT" "$BUILD" "$STAGE" "$ORDER_KEY" "$BUNDLE_ID" "$MIN_OS" \
        "$ASSET_NAME" "$SIZE" "$SHA256" "$ARCH" <<'PY'
import json, sys
tag, short, build, stage, order_key, bid, min_os, asset, size, sha, arch = sys.argv[1:12]
print(json.dumps({
    "tag": tag, "version": short, "build": int(build), "stage": stage,
    "order_key": order_key, "bundle_id": bid, "min_os": min_os,
    "asset": asset, "size": int(size), "sha256": sha, "arch": arch,
}, ensure_ascii=False, sort_keys=True))
PY
else
    echo "[verify] PASS  $TAG  $ASSET_NAME  build=$BUILD stage=$STAGE arch=$ARCH"
fi
exit 0
