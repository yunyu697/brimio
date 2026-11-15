#!/bin/bash
#
# 命名配置的读取器 / 生成器。
#
#   Scripts/naming.sh --get APP_BUNDLE_ID      # 取单个值（给别的脚本用）
#   Scripts/naming.sh --env                    # 输出可 source 的整段（已展开模板）
#   Scripts/naming.sh --emit-swift             # 重新生成 Sources/Brimio/Generated/Naming.swift
#   Scripts/naming.sh --check                  # 校验生成文件与配置一致（CI / selftest 用）
#   Scripts/naming.sh --asset v0.1.0-alpha1    # 打印该 tag 对应的 Release 资产名
#
# 唯一的输入是 `Config/naming.env`。任何名字要改，只改那一处。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/Config/naming.env"
SWIFT_OUT="$ROOT/Sources/Brimio/Generated/Naming.swift"

if [[ ! -f "$CONFIG" ]]; then
    echo "naming.sh: 缺少配置 $CONFIG" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG"

asset_name() {
    local tag="$1"
    local template="${RELEASE_ASSET_TEMPLATE//\{repo\}/$APP_REPO}"
    echo "${template//\{tag\}/$tag}"
}

# {tag} 之前的固定前缀，用于从资产名反解 tag。
asset_prefix() {
    local template="${RELEASE_ASSET_TEMPLATE//\{repo\}/$APP_REPO}"
    echo "${template%%\{tag\}*}"
}

emit_swift() {
    mkdir -p "$(dirname "$SWIFT_OUT")"
    cat > "$SWIFT_OUT" <<SWIFT
// 本文件由 \`Scripts/naming.sh --emit-swift\` 从 \`Config/naming.env\` 生成，不要手改。
// 改名字：编辑 Config/naming.env，然后重跑该命令（\`--check\` 会在 selftest / CI 里发现漂移）。
enum Naming {
    /// 产品显示名。
    static let appDisplayName = "$APP_DISPLAY_NAME"
    /// .app 包名 / 可执行名。
    static let bundleName = "$APP_BUNDLE_NAME"
    /// 反向域名 bundle id。
    static let bundleID = "$APP_BUNDLE_ID"
    /// 设置窗口标题。
    static let settingsWindowTitle = "$SETTINGS_WINDOW_TITLE"
    /// 更新检查的数据源。
    static let updateOwner = "$UPDATE_OWNER"
    static let updateRepo = "$UPDATE_REPO"

    /// Release 资产名。模板来自 Config/naming.env 的 RELEASE_ASSET_TEMPLATE，
    /// 更新检查器用它匹配资产，打包脚本用它命名产物——两边同源。
    static func releaseAssetName(tag: String) -> String {
        "$(asset_name '{tag}')".replacingOccurrences(of: "{tag}", with: tag)
    }

    /// 从资产名反解 tag；不匹配任何模板形状时返回 nil（更新检查器的「命名不符」用例）。
    static func versionTag(fromAssetName name: String) -> String? {
        let suffix = ".zip"
        let prefix = "$(asset_prefix)"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return String(name[start..<end])
    }
}
SWIFT
    echo "naming.sh: wrote $SWIFT_OUT"
}

case "${1:-}" in
    --get)
        key="${2:-}"
        [[ -n "$key" ]] || { echo "naming.sh: --get 需要 KEY" >&2; exit 1; }
        eval "value=\${$key:-}"
        [[ -n "$value" ]] || { echo "naming.sh: 未定义的 KEY: $key" >&2; exit 1; }
        printf '%s\n' "$value"
        ;;
    --env)
        echo "APP_DISPLAY_NAME=$APP_DISPLAY_NAME"
        echo "APP_BUNDLE_NAME=$APP_BUNDLE_NAME"
        echo "APP_REPO=$APP_REPO"
        echo "APP_BUNDLE_ID=$APP_BUNDLE_ID"
        echo "SETTINGS_WINDOW_TITLE=$SETTINGS_WINDOW_TITLE"
        echo "UPDATE_OWNER=$UPDATE_OWNER"
        echo "UPDATE_REPO=$UPDATE_REPO"
        echo "RELEASE_ASSET_TEMPLATE=$RELEASE_ASSET_TEMPLATE"
        ;;
    --emit-swift)
        emit_swift
        ;;
    --check)
        tmp="$(mktemp)"
        before="$SWIFT_OUT"
        SWIFT_OUT="$tmp"
        emit_swift >/dev/null
        SWIFT_OUT="$before"
        if [[ ! -f "$SWIFT_OUT" ]]; then
            echo "naming.sh: 生成文件不存在：$SWIFT_OUT（跑 --emit-swift）" >&2
            rm -f "$tmp"
            exit 1
        fi
        if diff -u "$SWIFT_OUT" "$tmp" >/dev/null; then
            echo "[NAMING] OK  生成文件与 Config/naming.env 一致"
            rm -f "$tmp"
            exit 0
        fi
        echo "[NAMING] FAIL 生成文件与 Config/naming.env 不一致：" >&2
        diff -u "$SWIFT_OUT" "$tmp" >&2 || true
        rm -f "$tmp"
        exit 1
        ;;
    --asset)
        [[ -n "${2:-}" ]] || { echo "naming.sh: --asset 需要 tag" >&2; exit 1; }
        asset_name "$2"
        ;;
    *)
        echo "用法：naming.sh --get KEY | --env | --emit-swift | --check | --asset <tag>" >&2
        exit 1
        ;;
esac
