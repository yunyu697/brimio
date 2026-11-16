#!/bin/bash
#
# 提交内容敏感信息扫描。命中即失败（exit 1），并逐条打印文件:行号。
#
#   bash Scripts/scan-content.sh          # 自动：有 git 就用 index，没有就扫工作区
#   bash Scripts/scan-content.sh --tree   # 强制扫工作区（提交前、尚无 .git 时用）
#
# 扫描对象 = 将进入仓库的文件：
#   git 模式   `git ls-files`（CI 里就是 checkout 出来的全部被跟踪文件）
#   tree 模式  工作区全部文件 − .gitignore 覆盖的构建/渲染产物
#
# 规则分两类：
#   1) 路径：构建产物、渲染 PNG、.DS_Store、.app、zip —— 这些根本不该进仓库；
#   2) 内容：本机绝对路径、主机名、用户名、真实姓名、邮箱、token 前缀、私钥块。
#
# 只读，不修改任何文件。退出码：0 = 干净，1 = 有命中，2 = 环境不满足。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

mode="auto"
[[ "${1:-}" == "--tree" ]] && mode="tree"
if [[ "$mode" == "auto" ]]; then
    if git rev-parse --git-dir >/dev/null 2>&1; then mode="git"; else mode="tree"; fi
fi

files=()
ignored=()

if [[ "$mode" == "git" ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(git ls-files)
    while IFS= read -r f; do [[ -n "$f" ]] && ignored+=("$f"); done \
        < <(git status --porcelain --ignored=matching 2>/dev/null | awk '$1=="!!"{print $2}')
    echo "[SCAN] 模式=git（index）"
else
    # 工作区模式：显式跳过 .gitignore 覆盖的目录/文件类型。
    while IFS= read -r f; do files+=("$f"); done < <(
        find . -type f \
            -not -path "./.git/*" \
            -not -path "./.build/*" \
            -not -path "./.notch-build/*" \
            -not -path "./build/*" \
            -not -path "./dist/*" \
            -not -path "./Snapshots/*" \
            -not -path "*.app/*" \
            -not -name "*.png" -not -name "*.jpg" -not -name "*.jpeg" \
            -not -name "*.heic" -not -name "*.tiff" \
            -not -name "*.zip" -not -name "*.dmg" \
            -not -name ".DS_Store" -not -name "._*" \
            | sed 's|^\./||' | sort
    )
    for d in .build .notch-build build dist Snapshots .git; do
        [[ -e "$d" ]] && ignored+=("$d/")
    done
    echo "[SCAN] 模式=tree（工作区）"
fi

hits=0
echo "[SCAN] 候选文件 ${#files[@]} 个"

# MARK: - 路径规则

path_rules=(
    '(^|/)\.DS_Store$|DS_Store 元数据'
    '\.png$|渲染产物 PNG（可能含桌面或其他窗口内容）'
    '\.(jpg|jpeg|heic|tiff)$|截图/照片'
    '^build/|构建产物 build/'
    '^\.notch-build/|构建缓存 .notch-build/'
    '^\.build/|SwiftPM 缓存 .build/'
    '^dist/|分发包 dist/'
    '\.app/|.app bundle'
    '\.(zip|dmg)$|归档产物'
    '(^|/)Snapshots/|离屏渲染快照目录'
)

for f in "${files[@]}"; do
    for rule in "${path_rules[@]}"; do
        pattern="${rule%%|*}"
        reason="${rule#*|}"
        if [[ "$f" =~ $pattern ]]; then
            echo "[SCAN] HIT  path  $f  ($reason)"
            hits=$((hits + 1))
        fi
    done
done

# MARK: - 内容规则

grep_hits() {
    # $1 = reason，其余 = grep 参数
    local reason="$1"; shift
    local out
    if [[ "$mode" == "git" ]]; then
        out="$(git grep -I -n "$@" -- . 2>/dev/null || true)"
    else
        out="$(grep -I -n "$@" -- "${files[@]}" 2>/dev/null | sed 's|^\./||' || true)"
    fi
    [[ -z "$out" ]] && return 0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "[SCAN] HIT  content  $line  ($reason)"
        hits=$((hits + 1))
    done <<< "$out"
}

# 邮箱允许 GitHub noreply 与 example.com，其余一律报出来人工判断。
grep_hits "本机绝对路径 /Users/<user>" -E '/Users/[A-Za-z0-9._-]+'
grep_hits "本机绝对路径 /home/<user>" -E '/home/[A-Za-z0-9._-]+'
grep_hits "GitHub token" -E 'gh[pousr]_[A-Za-z0-9]{20,}'
grep_hits "GitHub fine-grained token" -E 'github_pat_[A-Za-z0-9_]{20,}'
grep_hits "API key（sk- 前缀）" -E 'sk-[A-Za-z0-9]{16,}'
grep_hits "AWS access key" -E 'AKIA[0-9A-Z]{16}'
grep_hits "私钥块" -E '\-\-\-\-\-BEGIN [A-Z ]*PRIVATE KEY\-\-\-\-\-'
grep_hits "JWT" -E 'eyJhbGciOi[A-Za-z0-9_-]{10,}'

# 主机名 / 用户名 / 真实姓名：取不到就跳过；CI 上取到的 runner/root 不算。
dyn_patterns=()
host="$(scutil --get LocalHostName 2>/dev/null || hostname 2>/dev/null || true)"
[[ -n "${host:-}" ]] && dyn_patterns+=("$host|主机名")
user="$(whoami 2>/dev/null || true)"
[[ -n "${user:-}" && "$user" != "runner" && "$user" != "root" ]] && dyn_patterns+=("$user|用户名")
fullname="$(id -F 2>/dev/null || true)"
[[ -n "${fullname:-}" && "$fullname" != "root" ]] && dyn_patterns+=("$fullname|真实姓名")

for entry in "${dyn_patterns[@]}"; do
    value="${entry%%|*}"
    reason="${entry#*|}"
    # 太短的值（如 2-3 字符）会误报一片，跳过。
    [[ ${#value} -lt 4 ]] && continue
    if [[ "$mode" == "git" ]]; then
        out="$(git grep -I -n -F "$value" -- . 2>/dev/null || true)"
    else
        out="$(grep -I -n -F "$value" -- "${files[@]}" 2>/dev/null | sed 's|^\./||' || true)"
    fi
    [[ -z "$out" ]] && continue
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "[SCAN] HIT  identity  $line  ($reason: $value)"
        hits=$((hits + 1))
    done <<< "$out"
done

# 邮箱（排除 noreply 与 example.com）
if [[ "$mode" == "git" ]]; then
    email_out="$(git grep -I -n -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -- . 2>/dev/null || true)"
else
    email_out="$(grep -I -n -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
        -- "${files[@]}" 2>/dev/null | sed 's|^\./||' || true)"
fi
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
        *users.noreply.github.com*|*@example.com*) continue ;;
    esac
    echo "[SCAN] HIT  email  $line  (邮箱地址)"
    hits=$((hits + 1))
done <<< "$email_out"

# MARK: - 被忽略的路径（报告用，不算命中）

echo "[SCAN] 被 .gitignore 排除的路径（${#ignored[@]} 项）："
for p in "${ignored[@]}"; do echo "  $p"; done

if [[ $hits -eq 0 ]]; then
    echo "[SCAN] PASS  0 hit in ${#files[@]} file(s)"
    exit 0
fi

echo "[SCAN] FAIL  $hits hit(s) —— 清理后再提交" >&2
exit 1
