#!/bin/bash
#
# 镜像实测：对 Config/mirrors.env 里每个启用的镜像做两组探测。
#
#   A) 我们的真实资产（默认取 v1.0.0-alpha1）——验「能不能取到我们的包」
#   B) 一个公开的小资产（默认 stedolan/jq 的 jq-macos-arm64）——验「镜像本身活着没有」
#
# 为什么要两组：仓库私有期间，A 一定是 404/401，但那不说明镜像挂了；
# 只有 B 通过而 A 失败，才能断定「镜像可用，只是资产不可见」（需要公开分发或凭据）。
#
#   Scripts/probe-mirrors.sh                       # 默认端口/资产
#   Scripts/probe-mirrors.sh --tag v1.0.0-beta1 --asset brimio-v1.0.0-beta1.zip
#   Scripts/probe-mirrors.sh --timeout 8
#
# 只读：不发上传、不改配置、不落盘。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/Config/naming.env"
# shellcheck disable=SC1091
source "$ROOT/Config/mirrors.env"

TAG="v1.0.0-alpha1"
ASSET="$(bash "$ROOT/Scripts/naming.sh" --asset "$TAG")"
SAMPLE_REPO_TAG="stedolan/jq/releases/download/jq-1.7"
SAMPLE_ASSET="jq-macos-arm64"
TIMEOUT=12

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag) TAG="${2:-}"; ASSET="$(bash "$ROOT/Scripts/naming.sh" --asset "$TAG")"; shift 2 ;;
        --asset) ASSET="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

probe() { # url -> "code bytes total_s"
    local url="$1" out
    out="$(curl -sS -o /dev/null -m "$TIMEOUT" -r 0-4095 -L \
        -w '%{http_code} %{size_download} %{time_total}' "$url" 2>/dev/null)"
    [[ -z "$out" ]] && out="000 0 0"
    echo "$out"
}

printf '%-12s %-14s %-22s %-20s %s\n' "mirror" "flags" "我们的资产(code/B/s)" "公共样本(code/B/s)" "判定"
echo '----------------------------------------------------------------------------------------------------'

n=1
while [[ "$n" -le "${MIRROR_COUNT:-0}" ]]; do
    id_var="MIRROR_${n}_ID"; tpl_var="MIRROR_${n}_TEMPLATE"
    en_var="MIRROR_${n}_ENABLED"; pub_var="MIRROR_${n}_PUBLIC_ONLY"
    id="${!id_var:-}"; tpl="${!tpl_var:-}"; enabled="${!en_var:-1}"; public_only="${!pub_var:-0}"
    n=$((n + 1))
    [[ -n "$id" && -n "$tpl" ]] || continue
    if [[ "$enabled" != "1" ]]; then
        printf '%-12s %-14s %-22s %-20s %s\n' "$id" "disabled" "-" "-" "未启用（占位）"
        continue
    fi

    our_url="${tpl//\{owner\}/$UPDATE_OWNER}"
    our_url="${our_url//\{repo\}/$UPDATE_REPO}"
    our_url="${our_url//\{tag\}/$TAG}"
    our_url="${our_url//\{asset\}/$ASSET}"

    sample_url="${tpl//\{owner\}/stedolan}"
    sample_url="${sample_url//\{repo\}/jq}"
    sample_url="${sample_url//\{tag\}/jq-1.7}"
    sample_url="${sample_url//\{asset\}/$SAMPLE_ASSET}"

    read -r oc ob ot <<< "$(probe "$our_url")"
    read -r sc sb st <<< "$(probe "$sample_url")"

    verdict="?"
    case "$oc" in
        200|206) verdict="可用（能取到我们的包）" ;;
        401|403|404)
            case "$sc" in
                200|206) verdict="可达，但取不到我们的资产（私有/未同步）" ;;
                *) verdict="镜像本身异常" ;;
            esac
            ;;
        *)
            case "$sc" in
                200|206) verdict="镜像可用，但本机到该域名的连接不稳" ;;
                *) verdict="不可达" ;;
            esac
            ;;
    esac

    printf '%-12s %-14s %-22s %-20s %s\n' \
        "$id" "public=$public_only" \
        "$oc/${ob}B/${ot}s" \
        "$sc/${sb}B/${st}s" \
        "$verdict"
done

echo
echo "[probe] 说明：code=206 表示 Range 请求被支持（只取了 4KB 预览，未下载整包）。"
echo "[probe] 本结果只代表当前网络与当前时刻；GitHub 直连会 302 到 objects.githubusercontent.com，"
echo "[probe] 部分网络对那个域名的策略与 github.com 不同，请以本机实测为准。"
