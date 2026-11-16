#!/bin/bash
#
# 一条龙发布（替代当前不可用的 GitHub Actions）：
#   预检 → 构建打包 → 资产校验 → 记录 feed → 生成各通道清单 → 打印/执行上传命令
#
#   Scripts/release.sh --tag v1.0.0-beta1                 # 只做到本地产物 + 清单，打印上传命令
#   Scripts/release.sh --tag v1.0.0-beta1 --publish       # 真的上传（用本机 gh 账号，需用户自己跑）
#   Scripts/release.sh --tag v1.0.0 --skip-build          # 复用 dist/ 里已有 zip（重发清单时用）
#
# 本脚本**不做** git 提交 / 打 tag / 改可见性：这些由上层统一处理。
# --publish 会向 GitHub 上传资产与清单，属于用户账号操作；默认不执行。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source "$ROOT/Config/naming.env"
# shellcheck disable=SC1091
source "$ROOT/Config/release.env"

TAG=""
SKIP_BUILD=0
PUBLISH=0
DMG_MODE="auto"          # auto: 只有 stable 出 dmg；always / never
ALLOW_ALPHA_PUBLISH=0
NOTES_URL=""

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag) TAG="${2:-}"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --publish) PUBLISH=1; shift ;;
        --dmg) DMG_MODE="always"; shift ;;
        --no-dmg) DMG_MODE="never"; shift ;;
        --allow-alpha-publish) ALLOW_ALPHA_PUBLISH=1; shift ;;
        --notes-url) NOTES_URL="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$TAG" ]] || { echo "缺少 --tag" >&2; exit 2; }
STAGE="$(bash "$ROOT/Scripts/version-check.sh" --stage "$TAG")"
ASSET="$(bash "$ROOT/Scripts/naming.sh" --asset "$TAG")"
step() { printf '\n== %s\n' "$1"; }

step "1/6 版本规则"
bash "$ROOT/Scripts/version-check.sh" "$TAG"

step "2/6 命名与敏感内容"
bash "$ROOT/Scripts/naming.sh" --check
bash "$ROOT/Scripts/scan-content.sh" --tree | tail -3

step "3/6 构建状态（只读检查，不做任何 git 写操作）"
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "[release] FAIL 本地没有 tag $TAG（tag 是版本唯一事实来源）" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "[release] FAIL 工作区有未提交改动：产物会包含 tag 之外的代码，版本不可复现。" >&2
    echo "[release]      先让改动进入提交（由上层执行），或明确接受风险后手工构建。" >&2
    git status --short >&2
    exit 1
fi
HEAD_SHA="$(git rev-parse HEAD)"
TAG_SHA="$(git rev-parse "$TAG^{commit}")"
[[ "$HEAD_SHA" == "$TAG_SHA" ]] || {
    echo "[release] FAIL HEAD($HEAD_SHA) 不在 tag $TAG($TAG_SHA) 上" >&2; exit 1;
}
COMMITS="$(git rev-list --count "$TAG^{commit}")"
echo "[release] tag=$TAG commit=${TAG_SHA:0:8} commits=$COMMITS stage=$STAGE"

step "4/6 构建 + 打包"
mkdir -p "$ROOT/dist"
if [[ "$SKIP_BUILD" == "1" ]]; then
    echo "[release] 跳过构建，复用 dist/$ASSET"
else
    TAG="$TAG" VERIFY_TAG="$TAG" CONFIG=release PACKAGE=1 \
        OUT="$ROOT/build/$APP_BUNDLE_NAME.app" DIST="$ROOT/dist" \
        bash "$ROOT/Scripts/make-app.sh"
fi
bash "$ROOT/Scripts/release-verify.sh" --expect-build "$COMMITS" "$TAG" "$ROOT/dist/$ASSET"

if [[ "$DMG_MODE" == "always" || ( "$DMG_MODE" == "auto" && "$STAGE" == "stable" ) ]]; then
    step "4b/6 首次安装用 dmg"
    bash "$ROOT/Scripts/make-dmg.sh" "$ROOT/build/$APP_BUNDLE_NAME.app" --tag "$TAG" --out "$ROOT/dist"
else
    echo "[release] 跳过 dmg（stage=$STAGE；stable 才默认出 dmg）"
fi

step "5/6 记录并生成清单"
bash "$ROOT/Scripts/release-feed.sh" --add "$TAG" "$ROOT/dist/$ASSET" --notes-url "$NOTES_URL"
bash "$ROOT/Scripts/release-feed.sh" --emit

step "6/6 上传命令"
GH_REPO="$UPDATE_OWNER/$UPDATE_REPO"
PRE_FLAG=""
if [[ "$STAGE" != "stable" ]]; then PRE_FLAG="--prerelease --latest=false"; fi

cat <<EOF

# 1) 发布版本资产（首次发布 stable 时不要带 --prerelease）
gh release create $TAG --repo $GH_REPO \\
  dist/$ASSET dist/$ASSET.sha256 \\
  --title "$TAG" --generate-notes $PRE_FLAG

# 2) 把清单挂到 tag 固定为 $FEED_TAG 的 Release 上（URL 与版本无关）
gh release view $FEED_TAG --repo $GH_REPO >/dev/null 2>&1 || \\
  gh release create $FEED_TAG --repo $GH_REPO --prerelease --latest=false \\
    --title "更新清单" --notes "客户端更新检查读取这两个文件，不要删除本 Release。"
gh release upload $FEED_TAG dist/feed/$FEED_STABLE_ASSET dist/feed/$FEED_BETA_ASSET \\
  --repo $GH_REPO --clobber

# 3) 上传后自查（匿名可见性 + 镜像实测）
#    Scripts/probe-mirrors.sh --tag $TAG
EOF

if [[ "$DMG_MODE" == "always" || ( "$DMG_MODE" == "auto" && "$STAGE" == "stable" ) ]]; then
    echo "# 4) dmg（可选，首次安装用）"
    echo "gh release upload $TAG dist/${APP_REPO}-${TAG}.dmg dist/${APP_REPO}-${TAG}.dmg.sha256 --repo $GH_REPO --clobber"
fi

echo
echo "# 注意：Release/feed/items.jsonl 已被修改，需要由上层提交，否则下次发布不知道这条记录。"

if [[ "$PUBLISH" == "1" ]]; then
    if [[ "$STAGE" == "alpha" && "$ALLOW_ALPHA_PUBLISH" != "1" ]]; then
        echo "[release] 拒绝发布 alpha：alpha 只在开发机内部使用（见 Release/RELEASE-PLAN.md 第 4 节）" >&2
        exit 1
    fi
    # shellcheck disable=SC2086
    gh release create "$TAG" --repo "$GH_REPO" \
        "$ROOT/dist/$ASSET" "$ROOT/dist/$ASSET.sha256" \
        --title "$TAG" --generate-notes $PRE_FLAG
    if ! gh release view "$FEED_TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
        gh release create "$FEED_TAG" --repo "$GH_REPO" --prerelease --latest=false \
            --title "更新清单" --notes "客户端更新检查读取这两个文件，不要删除本 Release。"
    fi
    gh release upload "$FEED_TAG" \
        "$ROOT/dist/feed/$FEED_STABLE_ASSET" "$ROOT/dist/feed/$FEED_BETA_ASSET" \
        --repo "$GH_REPO" --clobber
    echo "[release] 已上传 $TAG 与清单"
fi
