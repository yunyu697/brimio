#!/bin/bash
#
# 更新检查 + 下载 + 校验。本轮不含「安装」（替换 /Applications 里的 app 属于应用内行为，
# 需要改 Sources/，不在本轮范围）；这里负责把「可信的包」安全地拿到本地。
#
# 流程（每一步失败都有明确出口，不存在跳过校验的分支）：
#   1. 取清单：https / 本机 file；拒绝明文 http（loopback 除外，仅用于本地模拟）
#   2. 选条目：通道可见性 → build 严格大于本机 → 最低系统版本
#   3. 逐镜像下载：按 Config/mirrors.env 顺序；每个候选都校验「字节数 + sha256」
#   4. 包内交叉核对：调用 Scripts/release-verify.sh，比对 tag / build / bundle id
#   5. 落盘 + 写同名 .sha256（与发布约定一致的裸文件名格式）
#
# 用法：
#   Scripts/fetch-update.sh --feed dist/feed/feed-stable.json --current-app build/Brimio.app
#   Scripts/fetch-update.sh --feed https://.../feed-beta.json --channel beta --current-build 4
#   Scripts/fetch-update.sh ... --use-gh            # 私有仓库：用 gh 凭据作为第 0 候选
#   Scripts/fetch-update.sh ... --mirrors-file X    # 换一份镜像清单（本地模拟用）
#   Scripts/fetch-update.sh ... --dry-run           # 只看有没有更新，不下载
#
# 退出码：0 已下载并通过校验 / 2 无更新 / 3 取清单失败（含离线）/ 4 校验失败 / 5 用法错误
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/Config/naming.env"
# shellcheck disable=SC1091
source "$ROOT/Config/release.env"

FEED=""
CHANNEL="auto"
CURRENT_APP=""
CURRENT_BUILD=""
CURRENT_TAG=""
DEST="$HOME/Downloads"
TIMEOUT="$DOWNLOAD_TIMEOUT_SECONDS"
USE_GH=0
DRY_RUN=0
MIRRORS_FILE="$ROOT/Config/mirrors.env"
ONLY_MIRROR=""
SKIP_MIRROR=""

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --feed) FEED="${2:-}"; shift 2 ;;
        --channel) CHANNEL="${2:-}"; shift 2 ;;
        --current-app) CURRENT_APP="${2:-}"; shift 2 ;;
        --current-build) CURRENT_BUILD="${2:-}"; shift 2 ;;
        --current-tag) CURRENT_TAG="${2:-}"; shift 2 ;;
        --dest) DEST="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        --use-gh) USE_GH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --mirrors-file) MIRRORS_FILE="${2:-}"; shift 2 ;;
        --only-mirror) ONLY_MIRROR="${2:-}"; shift 2 ;;
        --skip-mirror) SKIP_MIRROR="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 5 ;;
    esac
done

if [[ -z "$FEED" ]]; then echo "[update] 需要 --feed <url|path>" >&2; exit 5; fi

# MARK: - 本机状态

CURRENT_OS="$(sw_vers -productVersion)"
if [[ -n "$CURRENT_APP" ]]; then
    PLIST="$CURRENT_APP/Contents/Info.plist"
    [[ -f "$PLIST" ]] || { echo "[update] 找不到 $PLIST" >&2; exit 5; }
    CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null)"
    CURRENT_TAG="$(/usr/libexec/PlistBuddy -c 'Print :BrimioReleaseTag' "$PLIST" 2>/dev/null || true)"
    INSTALLED_CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print :BrimioChannel' "$PLIST" 2>/dev/null || true)"
else
    INSTALLED_CHANNEL=""
fi
[[ -n "$CURRENT_BUILD" && "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || {
    echo "[update] 需要 --current-app 或 --current-build（正整数）" >&2; exit 5;
}

if [[ "$CHANNEL" == "auto" ]]; then
    case "$INSTALLED_CHANNEL" in
        alpha) CHANNEL="alpha" ;;
        beta|rc) CHANNEL="beta" ;;
        *) CHANNEL="stable" ;;
    esac
fi
case "$CHANNEL" in
    stable) SEES="$CHANNEL_STABLE_SEES" ;;
    beta)   SEES="$CHANNEL_BETA_SEES" ;;
    alpha)  SEES="stable beta rc alpha" ;;
    *) echo "[update] --channel 只支持 stable|beta|alpha|auto" >&2; exit 5 ;;
esac
echo "[update] installed build=$CURRENT_BUILD tag=${CURRENT_TAG:-?} channel=${INSTALLED_CHANNEL:-?} os=$CURRENT_OS"
echo "[update] feed=$FEED requested-channel=$CHANNEL sees=[$SEES]"

# MARK: - 1. 取清单

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FEED_RAW="$TMP/feed.json"

fetch_feed() {
    local url="$1"
    case "$url" in
        file://*)
            local path="${url#file://}"
            [[ -f "$path" ]] || return 3
            cat "$path"
            ;;
        https://*)
            curl -fsSL --proto '=https' --proto-redir '=https' \
                --connect-timeout 8 --max-time "$TIMEOUT" --max-redirs 5 "$url"
            ;;
        http://127.0.0.1*|http://localhost*)
            # 仅本地模拟：loopback 上的明文 http 不经过网络。
            curl -fsSL --proto '=http,https' --connect-timeout 5 --max-time "$TIMEOUT" "$url"
            ;;
        *)
            # 本机文件路径：发布者在本地先自测清单，不产生网络请求。
            if [[ "$url" != *://* && -f "$url" ]]; then
                cat "$url"
            else
                echo "[update] 拒绝非 https 的清单地址：$url" >&2
                return 3
            fi
            ;;
    esac
}

if ! fetch_feed "$FEED" > "$FEED_RAW"; then
    echo "[update] SKIP 清单获取失败（离线 / 404 / 证书问题）。不会影响使用，下次周期或手动再试。" >&2
    exit 3
fi

# MARK: - 2. 选条目（通道 + build + 最低系统版本）

ITEM_ENV="$TMP/item.env"
if ! python3 - "$FEED_RAW" "$CHANNEL" "$SEES" "$CURRENT_BUILD" "$CURRENT_OS" > "$ITEM_ENV" <<'PY'
import json, sys
feed_path, channel, sees, current_build, current_os = sys.argv[1:6]
sees = set(sees.split())
data = json.load(open(feed_path, encoding="utf-8"))
if data.get("schema") != 1:
    print("[update] 清单 schema 不受支持", file=sys.stderr)
    sys.exit(2)
if data.get("channel") != channel:
    print(f"[update] 清单通道 {data.get('channel')} 与请求通道 {channel} 不一致", file=sys.stderr)
    sys.exit(2)

def ver_tuple(v):
    return tuple(int(p) for p in v.split("."))

os_now = ver_tuple(current_os)
cands = []
for it in data.get("items", []):
    if it.get("stage") not in sees:
        continue                      # 通道过滤：stable 用户永远看不到 beta/alpha
    if int(it.get("build", 0)) <= int(current_build):
        continue                      # 防降级 / 防重放
    if ver_tuple(it.get("min_os", "0")) > os_now:
        continue
    cands.append(it)

if not cands:
    print("NONE=1")
    sys.exit(0)
best = max(cands, key=lambda it: (int(it["build"]), it.get("order_key", "")))
for key in ("tag", "version", "build", "stage", "asset", "size", "sha256", "url", "min_os"):
    print(f"{key}={best[key]}")
print("NONE=0")
PY
then
    echo "[update] FAIL 清单解析失败" >&2
    exit 3
fi
# shellcheck disable=SC1090
source "$ITEM_ENV"

if [[ "${NONE:-1}" == "1" ]]; then
    echo "[update] NO-UPDATE 本机 build=$CURRENT_BUILD 已是该通道最新（或清单没有可用的更新版本）"
    exit 2
fi

echo "[update] available tag=$tag build=$build stage=$stage size=$size sha256=${sha256:0:16}…"
if [[ "$DRY_RUN" == "1" ]]; then
    echo "[update] DRY-RUN 不下载"
    exit 0
fi

# MARK: - 3. 逐镜像下载 + 校验

mkdir -p "$DEST"
PART="$TMP/download.part"
TARGET="$DEST/$asset"
TRIES_LOG="$TMP/tries.log"
: > "$TRIES_LOG"
FAIL_REASONS=0

record() { # mirror result detail
    printf '%-14s %-6s %s\n' "$1" "$2" "$3" >> "$TRIES_LOG"
    printf '[update] try mirror=%-14s result=%-6s %s\n' "$1" "$2" "$3"
}

# 第 0 候选：私有仓库用 gh 凭据（凭据只存在本机 gh 配置里，不落仓库、不进包）。
if [[ "$USE_GH" == "1" ]]; then
    if gh auth status >/dev/null 2>&1; then
        if gh release download "$tag" --repo "$UPDATE_OWNER/$UPDATE_REPO" \
            --pattern "$asset" --dir "$TMP/gh" --clobber >/dev/null 2>&1; then
            ACTUAL="$(shasum -a 256 "$TMP/gh/$asset" 2>/dev/null | awk '{print $1}')"
            if [[ "$ACTUAL" == "$sha256" ]]; then
                record gh-cli ok "sha256 match"
                cp "$TMP/gh/$asset" "$TARGET"
                printf '%s  %s\n' "$sha256" "$asset" > "$TARGET.sha256"
                VERIFIED_FROM="gh-cli"
            else
                record gh-cli hash_mismatch "got=${ACTUAL:0:12} want=${sha256:0:12}"
            fi
        else
            record gh-cli fail "gh release download 失败"
        fi
    else
        record gh-cli skip "gh 未登录"
    fi
fi

# shellcheck disable=SC1090
if [[ -f "$MIRRORS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MIRRORS_FILE"
else
    echo "[update] FAIL 镜像清单不存在：$MIRRORS_FILE" >&2
    exit 5
fi

if [[ -z "${VERIFIED_FROM:-}" ]]; then
    n=1
    while [[ "$n" -le "${MIRROR_COUNT:-0}" ]]; do
        id_var="MIRROR_${n}_ID"; tpl_var="MIRROR_${n}_TEMPLATE"
        en_var="MIRROR_${n}_ENABLED"; pub_var="MIRROR_${n}_PUBLIC_ONLY"
        id="${!id_var:-}"; tpl="${!tpl_var:-}"; enabled="${!en_var:-1}"; public_only="${!pub_var:-0}"
        n=$((n + 1))
        [[ -n "$id" && -n "$tpl" ]] || continue
        [[ "$enabled" == "1" ]] || continue
        [[ -z "$ONLY_MIRROR" || "$ONLY_MIRROR" == "$id" ]] || continue
        [[ -z "$SKIP_MIRROR" || "$SKIP_MIRROR" != "$id" ]] || continue
        # 私有模式下第三方反代取不到资产（实测 404），直接跳过，省掉无意义的超时等待。
        if [[ "$USE_GH" == "1" && "$public_only" == "1" ]]; then
            record "$id" skip "PUBLIC_ONLY=1，私有模式不尝试"
            continue
        fi

        url="${tpl//\{owner\}/$UPDATE_OWNER}"
        url="${url//\{repo\}/$UPDATE_REPO}"
        url="${url//\{tag\}/$tag}"
        url="${url//\{asset\}/$asset}"

        case "$url" in
            https://*) CURL_PROTO=(--proto '=https' --proto-redir '=https') ;;
            http://127.0.0.1*|http://localhost*) CURL_PROTO=(--proto '=http,https') ;;
            *)
                record "$id" reject "非 https 地址"
                continue
                ;;
        esac

        rm -f "$PART"
        if ! curl -fsSL "${CURL_PROTO[@]}" --connect-timeout 8 --max-time "$TIMEOUT" \
            -o "$PART" "$url" 2>"$TMP/curl.err"; then
            code="$(grep -o 'returned error: [0-9]*' "$TMP/curl.err" | awk '{print $3}' | head -1)"
            if [[ -n "$code" ]]; then
                record "$id" "http_$code" "public_only=$public_only"
            else
                record "$id" fail "$(tr -d '\n' < "$TMP/curl.err" | cut -c1-90)"
            fi
            continue
        fi

        got_size="$(stat -f%z "$PART" 2>/dev/null || echo 0)"
        if [[ "$got_size" != "$size" ]]; then
            record "$id" size_mismatch "got=$got_size want=$size"
            rm -f "$PART"
            continue
        fi
        got_sha="$(shasum -a 256 "$PART" | awk '{print $1}')"
        if [[ "$got_sha" != "$sha256" ]]; then
            record "$id" hash_mismatch "got=${got_sha:0:12} want=${sha256:0:12}"
            rm -f "$PART"
            continue
        fi

        record "$id" ok "sha256 match"
        mv "$PART" "$TARGET"
        printf '%s  %s\n' "$sha256" "$asset" > "$TARGET.sha256"
        VERIFIED_FROM="$id"
        break
    done
fi

if [[ -z "${VERIFIED_FROM:-}" ]]; then
    echo "[update] FAIL 所有候选都失败。没有任何一份通过校验，未写入任何包。" >&2
    echo "[update] 明细：" >&2
    sed 's/^/[update]   /' "$TRIES_LOG" >&2
    exit 4
fi

# MARK: - 4. 包内交叉核对（tag / build / bundle id / 体积 / 哈希）

if ! bash "$ROOT/Scripts/release-verify.sh" --expect-sha "$sha256" --expect-build "$build" \
    "$tag" "$TARGET" >/dev/null 2>"$TMP/verify.err"; then
    echo "[update] FAIL 包内元数据与清单不符，已删除下载物：" >&2
    sed 's/^/[update]   /' "$TMP/verify.err" >&2
    rm -f "$TARGET" "$TARGET.sha256"
    exit 4
fi

echo "[update] OK 来源=$VERIFIED_FROM tag=$tag build=$build"
echo "[update] asset=$TARGET"
echo "[update] sha256=$sha256"
echo "[update] 安装（需用户手动执行，本轮不做自动替换）："
echo "[update]   rm -rf /Applications/$APP_BUNDLE_NAME.app && ditto -x -k \"$TARGET\" /tmp/brimio-stage && mv /tmp/brimio-stage/$APP_BUNDLE_NAME.app /Applications/"
exit 0
