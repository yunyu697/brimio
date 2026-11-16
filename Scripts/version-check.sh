#!/bin/bash
# 版本号校验。唯一事实来源是 git tag，本脚本只做语法与范围检查，不改任何文件。
#
# 格式：vMAJOR.MINOR.PATCH[-alphaN|-betaN|-RCN]
#   - 必须带小写 v 前缀
#   - alpha / beta 必须小写、RC 必须大写，不含点号
#   - MAJOR 任意非负整数
#   - MINOR / PATCH 必须在 0..10（≥11 非法）
#   - alphaN / betaN / RCN 的 N 必须 ≥1（从 1 开始，alpha0 与「没有后缀的正式版」无法区分）
#
# 用法：
#   Scripts/version-check.sh v1.0.0        # 合法 exit 0；非法 exit 1 并打印原因
#   Scripts/version-check.sh --self-test   # 跑全部样例用例
#   Scripts/version-check.sh --stage v1.0.0-beta2   # 打印 alpha|beta|rc|stable
#   Scripts/version-check.sh --order-key v1.0.0-beta2  # 打印可排序键 00001.00000.00000.1.00002
#   Scripts/version-check.sh --compare A B  # 按 order-key 比较，打印 -1|0|1
#
# 比较规则（发布链路唯一口径）：
#   build（CFBundleVersion = 提交数）是更新判定的唯一单调键；
#   order-key 只用于排序与「同版本不同 stage」的判定。
#   两者不可互换：CFBundleShortVersionString 会丢掉 -alphaN 后缀，版本串自身无法区分 alpha 与正式版。
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"

fail() {
    echo "INVALID  $1  ($2)"
    exit 1
}

validate() {
    local version="$1"

    if [ -z "$version" ]; then
        fail "<empty>" "版本号为空"
    fi
    if [[ "$version" != v* ]]; then
        fail "$version" "缺少小写 v 前缀"
    fi

    # 先拆成 base 与后缀：后缀只认 -alphaN / -RCN
    local base="${version#v}"
    local suffix=""
    local prerelease=""
    if [[ "$base" == *-* ]]; then
        suffix="${base#*-}"
        base="${base%%-*}"
        prerelease=1
    fi

    if [[ ! "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        fail "$version" "主体必须是 MAJOR.MINOR.PATCH 三段纯数字"
    fi

    local major="${base%%.*}"
    local rest="${base#*.}"
    local minor="${rest%%.*}"
    local patch="${rest#*.}"

    # 禁止前导零（v01.0.0 / v1.00.0），避免与 plist / 排序歧义
    for part in "$major" "$minor" "$patch"; do
        if [ "${#part}" -gt 1 ] && [ "${part:0:1}" = "0" ]; then
            fail "$version" "数字段不允许前导零"
        fi
    done

    if [ "$minor" -gt 10 ]; then
        fail "$version" "MINOR=$minor 超出 0..10"
    fi
    if [ "$patch" -gt 10 ]; then
        fail "$version" "PATCH=$patch 超出 0..10"
    fi

    if [ -n "$prerelease" ]; then
        if [[ "$suffix" =~ ^alpha([1-9][0-9]*)$ ]]; then
            :
        elif [[ "$suffix" =~ ^beta([1-9][0-9]*)$ ]]; then
            :
        elif [[ "$suffix" =~ ^RC([1-9][0-9]*)$ ]]; then
            :
        elif [[ "$suffix" =~ ^(alpha|beta|RC)0$ ]]; then
            fail "$version" "序号 0 非法：从 1 开始，0 与正式版无法区分"
        elif [[ "$suffix" =~ ^(alpha|beta|RC)$ ]]; then
            fail "$version" "缺少序号 N"
        else
            fail "$version" "后缀只允许 alphaN / betaN / RCN（alpha、beta 小写，RC 大写），不允许点号或其它写法"
        fi
    fi

    echo "VALID    $version  (MAJOR=$major MINOR=$minor PATCH=$patch${suffix:+ suffix=$suffix})"
    exit 0
}

run_self_test() {
    local failures=0
    local total=0

    expect_ok() {
        total=$((total + 1))
        if bash "$ROOT/version-check.sh" "$1" >/dev/null 2>&1; then
            echo "PASS  accept  $1"
        else
            echo "FAIL  accept  $1（期望合法却判非法）"
            failures=$((failures + 1))
        fi
    }

    expect_bad() {
        total=$((total + 1))
        if bash "$ROOT/version-check.sh" "$1" >/dev/null 2>&1; then
            echo "FAIL  reject  $1（期望非法却判合法）"
            failures=$((failures + 1))
        else
            echo "PASS  reject  $1"
        fi
    }

    expect_ok v1.0.0
    expect_ok v1.0.0-alpha1
    expect_ok v1.0.0-beta1
    expect_ok v1.0.0-RC1
    expect_ok v1.10.10
    expect_ok v12.0.0
    expect_ok v1.0.0-alpha11
    expect_ok v1.0.0-RC27

    expect_bad v1.11.0
    expect_bad v1.0.11
    expect_bad v1.0.0-alpha
    expect_bad v1.0.0-alpha0
    expect_bad v1.0.0-beta0
    expect_bad v1.0.0-Beta1
    expect_bad v1.0.0-rc1
    expect_bad v1.0.0-rc.1
    expect_bad v1.0
    expect_bad 1.0.0

    # stage / order-key / compare 的语义用例：alpha < beta < rc < stable
    expect_eq() {
        total=$((total + 1))
        local got="$1" want="$2" what="$3"
        if [ "$got" = "$want" ]; then
            echo "PASS  $what == $want"
        else
            echo "FAIL  $what：got=$got want=$want"
            failures=$((failures + 1))
        fi
    }

    expect_eq "$(bash "$ROOT/version-check.sh" --stage v1.0.0-alpha2)" alpha "--stage alpha2"
    expect_eq "$(bash "$ROOT/version-check.sh" --stage v1.0.0-beta1)" beta "--stage beta1"
    expect_eq "$(bash "$ROOT/version-check.sh" --stage v1.0.0-RC1)" rc "--stage RC1"
    expect_eq "$(bash "$ROOT/version-check.sh" --stage v1.0.0)" stable "--stage 正式版"
    expect_eq "$(bash "$ROOT/version-check.sh" --compare v1.0.0-alpha1 v1.0.0-beta1)" -1 "alpha1 < beta1"
    expect_eq "$(bash "$ROOT/version-check.sh" --compare v1.0.0-RC9 v1.0.0)" -1 "RC9 < 正式版"
    expect_eq "$(bash "$ROOT/version-check.sh" --compare v1.0.1-alpha1 v1.0.0)" 1 "1.0.1-alpha1 > 1.0.0"
    expect_eq "$(bash "$ROOT/version-check.sh" --compare v1.0.0-beta2 v1.0.0-beta2)" 0 "同一个 tag"
    expect_eq "$(bash "$ROOT/version-check.sh" --order-key v1.0.0-beta2)" "00001.00000.00000.1.00002" "order-key beta2"

    echo "[VERSION] $((total - failures))/$total cases passed"
    if [ "$failures" -ne 0 ]; then
        exit 1
    fi
}

# MARK: - stage / order-key / compare

# 拆分 tag，输出 "major minor patch rank num"；rank：alpha=0 beta=1 rc=2 stable=3
split_tag() {
    local tag="$1"
    local base="${tag#v}"
    local suffix=""
    if [[ "$base" == *-* ]]; then
        suffix="${base#*-}"
        base="${base%%-*}"
    fi
    local major minor patch rank=3 num=0
    IFS=. read -r major minor patch <<< "$base"
    case "$suffix" in
        alpha*) rank=0; num="${suffix#alpha}" ;;
        beta*)  rank=1; num="${suffix#beta}" ;;
        RC*)    rank=2; num="${suffix#RC}" ;;
    esac
    printf '%s %s %s %s %s\n' "$major" "$minor" "$patch" "$rank" "$num"
}

stage_of() {
    local tag="$1" rank
    rank="$(split_tag "$tag" | awk '{print $4}')"
    case "$rank" in
        0) echo alpha ;;
        1) echo beta ;;
        2) echo rc ;;
        *) echo stable ;;
    esac
}

order_key_of() {
    local tag="$1" major minor patch rank num
    read -r major minor patch rank num <<< "$(split_tag "$tag")"
    printf '%05d.%05d.%05d.%d.%05d\n' "$major" "$minor" "$patch" "$rank" "$num"
}

# 打印 -1 / 0 / 1；只做字符串化的字段比较，不依赖 sort -V（macOS 上没有）。
compare_tags() {
    local a="$1" b="$2"
    local ka kb i fa fb
    ka="$(order_key_of "$a")"
    kb="$(order_key_of "$b")"
    IFS=. read -r -a ka <<< "$ka"
    IFS=. read -r -a kb <<< "$kb"
    for i in 0 1 2 3 4; do
        fa=$((10#${ka[$i]}))
        fb=$((10#${kb[$i]}))
        if [ "$fa" -lt "$fb" ]; then echo -1; return 0; fi
        if [ "$fa" -gt "$fb" ]; then echo 1; return 0; fi
    done
    echo 0
}

# 新模式的公共前置：非法 tag 不允许进入比较，直接按原规则报错退出。
require_valid() {
    local tag="$1"
    if ! bash "$ROOT/version-check.sh" "$tag" >/dev/null 2>&1; then
        echo "INVALID  $tag  (先跑一次 Scripts/version-check.sh $tag 看原因)" >&2
        exit 1
    fi
}

if [ "${1:-}" = "--self-test" ]; then
    run_self_test
elif [ "${1:-}" = "--stage" ]; then
    require_valid "${2:-}"
    stage_of "${2:-}"
elif [ "${1:-}" = "--order-key" ]; then
    require_valid "${2:-}"
    order_key_of "${2:-}"
elif [ "${1:-}" = "--compare" ]; then
    require_valid "${2:-}"
    require_valid "${3:-}"
    compare_tags "${2:-}" "${3:-}"
else
    validate "${1:-}"
fi
