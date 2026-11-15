#!/bin/bash
# 版本号校验。唯一事实来源是 git tag，本脚本只做语法与范围检查，不改任何文件。
#
# 格式：vMAJOR.MINOR.PATCH[-alphaN|-RCN]
#   - 必须带小写 v 前缀
#   - alpha 必须小写、RC 必须大写，不含点号
#   - MAJOR 任意非负整数
#   - MINOR / PATCH 必须在 0..10（≥11 非法）
#   - alphaN / RCN 的 N 必须 ≥1（从 1 开始，alpha0 与「没有后缀的正式版」无法区分）
#
# 用法：
#   Scripts/version-check.sh v1.0.0        # 合法 exit 0；非法 exit 1 并打印原因
#   Scripts/version-check.sh --self-test   # 跑全部样例用例
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
        elif [[ "$suffix" =~ ^RC([1-9][0-9]*)$ ]]; then
            :
        elif [[ "$suffix" =~ ^alpha0$ ]]; then
            fail "$version" "alpha0 非法：序号从 1 开始，0 与正式版无法区分"
        elif [[ "$suffix" =~ ^(alpha|RC)$ ]]; then
            fail "$version" "缺少序号 N"
        else
            fail "$version" "后缀只允许 alphaN（小写 alpha）或 RCN（大写 RC），不允许点号或其它写法"
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
    expect_ok v1.0.0-RC1
    expect_ok v1.10.10
    expect_ok v12.0.0
    expect_ok v1.0.0-alpha11
    expect_ok v1.0.0-RC27

    expect_bad v1.11.0
    expect_bad v1.0.11
    expect_bad v1.0.0-alpha
    expect_bad v1.0.0-alpha0
    expect_bad v1.0.0-rc1
    expect_bad v1.0.0-rc.1
    expect_bad v1.0
    expect_bad 1.0.0

    echo "[VERSION] $((total - failures))/$total cases passed"
    if [ "$failures" -ne 0 ]; then
        exit 1
    fi
}

if [ "${1:-}" = "--self-test" ]; then
    run_self_test
else
    validate "${1:-}"
fi
