#!/bin/bash
#
# 端到端模拟：用本地假包 + 本地 http 服务，把「镜像切换 + sha256 校验 + 通道隔离」跑通。
# 不联网、不碰 dist/、不碰 Release/、不上传任何东西；全部在 mktemp 目录里完成。
#
#   Scripts/update-sim.sh          # 跑全部场景，逐条 PASS/FAIL
#   Scripts/update-sim.sh --keep   # 保留临时目录，便于看现场
#
# 场景：
#   S1 前两个镜像失效（404 / 同体积但内容被改），第三个镜像成功 → 仍然安全拿到包
#   S2 所有镜像都不可用 → 退出码 4，且不留下半成品文件
#   S3 stable 清单里混入 beta 条目 → 客户端拒绝跨通道升级
#   S4 清单里的 build 不高于本机 → 不更新（防降级 / 防重放）
#   S5 非 loopback 的明文 http 清单 → 拒绝（只有 https 和本机调试例外）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/Config/naming.env"
# shellcheck disable=SC1091
source "$ROOT/Config/release.env"

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    if [[ "$KEEP" == "1" ]]; then
        echo "[sim] 保留工作目录：$WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

PASS=0
FAIL=0
check() { # 描述 期望 实际
    if [[ "$2" == "$3" ]]; then
        echo "PASS  $1（期望=$2 实际=$3）"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $1（期望=$2 实际=$3）"
        FAIL=$((FAIL + 1))
    fi
}

TAG="v1.0.0-beta1"
STAGE="$("$ROOT/Scripts/version-check.sh" --stage "$TAG")"
ASSET="$(bash "$ROOT/Scripts/naming.sh" --asset "$TAG")"

# MARK: - 造一个最小但「结构合法」的假 app
APP="$WORK/stage/$APP_BUNDLE_NAME.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${APP_BUNDLE_NAME}</string>
    <key>CFBundleIdentifier</key><string>${APP_BUNDLE_ID}</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>6</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>BrimioReleaseTag</key><string>${TAG}</string>
    <key>BrimioChannel</key><string>${STAGE}</string>
</dict>
</plist>
PLIST
# 用系统自带的 Mach-O 冒充可执行文件（release-verify 会检查 file 结果里有 Mach-O）
cp /usr/bin/true "$APP/Contents/MacOS/$APP_BUNDLE_NAME"

GOOD="$WORK/good/$ASSET"
mkdir -p "$WORK/good" "$WORK/feed"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$GOOD"
( cd "$WORK/good" && shasum -a 256 "$ASSET" > "$ASSET.sha256" )

SIZE="$(stat -f%z "$GOOD")"
SHA="$(shasum -a 256 "$GOOD" | awk '{print $1}')"

# 同体积、内容被改的「投毒包」：只翻转一个字节，保证体积检查过不了关、只有哈希能抓到。
mkdir -p "$WORK/bad" "$WORK/empty"
python3 - "$GOOD" "$WORK/bad/$ASSET" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, "rb").read())
data[200] ^= 0xFF
open(dst, "wb").write(data)
PY
BAD_SHA="$(shasum -a 256 "$WORK/bad/$ASSET" | awk '{print $1}')"
check "投毒包与原包体积相同（确保只有 sha256 能识别）" "$SIZE" "$(stat -f%z "$WORK/bad/$ASSET")"

# MARK: - 清单

mk_feed() { # 输出路径 通道 build stage
    python3 - "$1" "$2" "$3" "$4" "$TAG" "$SIZE" "$SHA" "$ASSET" "$MIN_MACOS" <<'PY'
import json, sys, datetime
out, channel, build, stage, tag, size, sha, asset, min_os = sys.argv[1:10]
doc = {
    "schema": 1, "channel": channel,
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "min_os": min_os, "item_count": 1,
    "items": [{
        "tag": tag, "version": "1.0.0", "build": int(build), "stage": stage,
        "order_key": "00001.00000.00000.1.00001",
        "released_at": "2026-11-16T00:00:00Z", "min_os": min_os,
        "asset": asset, "size": int(size), "sha256": sha, "arch": "arm64",
        "url": f"https://github.com/{'yunyu697'}/brimio/releases/download/{tag}/{asset}",
        "notes_url": "",
    }],
}
json.dump(doc, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
}

mk_feed "$WORK/feed/feed-beta.json" beta 6 "$STAGE"
mk_feed "$WORK/feed/feed-stable.json" stable 6 beta   # 故意把 beta 条目塞进 stable 清单
mk_feed "$WORK/feed/feed-old.json" beta 3 "$STAGE"    # 比本机旧

# MARK: - 本地 http 服务（三个镜像目录：404 / 投毒 / 正常）
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
mkdir -p "$WORK/serve"
ln -s "$WORK/empty" "$WORK/serve/m0"
ln -s "$WORK/bad" "$WORK/serve/m1"
ln -s "$WORK/good" "$WORK/serve/m2"
( cd "$WORK/serve" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null || true
for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/good/$ASSET" && break
    sleep 0.1
done

mk_mirrors() { # 输出路径 端口
    cat > "$1" <<EOF
MIRROR_COUNT=3
MIRROR_1_ID=m0-dead
MIRROR_1_TEMPLATE=http://127.0.0.1:$2/m0/{asset}
MIRROR_1_PUBLIC_ONLY=1
MIRROR_1_ENABLED=1
MIRROR_2_ID=m1-poisoned
MIRROR_2_TEMPLATE=http://127.0.0.1:$2/m1/{asset}
MIRROR_2_PUBLIC_ONLY=1
MIRROR_2_ENABLED=1
MIRROR_3_ID=m2-good
MIRROR_3_TEMPLATE=http://127.0.0.1:$2/m2/{asset}
MIRROR_3_PUBLIC_ONLY=1
MIRROR_3_ENABLED=1
EOF
}
mk_mirrors "$WORK/mirrors.env" "$PORT"

FETCH="$ROOT/Scripts/fetch-update.sh"

# MARK: - S1 失败切换
echo '--- S1 失效 → 投毒 → 正常'
rm -rf "$WORK/out1"
OUT1="$(bash "$FETCH" --feed "$WORK/feed/feed-beta.json" --channel beta --current-build 5 \
    --mirrors-file "$WORK/mirrors.env" --dest "$WORK/out1" 2>&1)"
RC=$?
check "S1 退出码（最终成功）" 0 "$RC"
grep -q 'mirror=m0-dead *result=http_404' <<< "$OUT1" && r1=seen || r1=missing
grep -q 'mirror=m1-poisoned *result=hash_mismatch' <<< "$OUT1" && r2=seen || r2=missing
grep -q 'mirror=m2-good *result=ok' <<< "$OUT1" && r3=seen || r3=missing
check "S1 第一跳 404" seen "$r1"
check "S1 第二跳识别投毒包" seen "$r2"
check "S1 第三跳成功" seen "$r3"
check "S1 落盘哈希正确" "$SHA" "$(shasum -a 256 "$WORK/out1/$ASSET" 2>/dev/null | awk '{print $1}')"
check "S1 投毒包哈希不同（对照组）" "different" "$([[ "$BAD_SHA" != "$SHA" ]] && echo different || echo same)"

# MARK: - S2 全失败
echo '--- S2 全部失效'
rm -rf "$WORK/out2"
OUT2="$(bash "$FETCH" --feed "$WORK/feed/feed-beta.json" --channel beta --current-build 5 \
    --mirrors-file "$WORK/mirrors.env" --dest "$WORK/out2" --skip-mirror m2-good 2>&1)"
RC=$?
check "S2 退出码（校验失败）" 4 "$RC"
check "S2 未留下半成品" "" "$(ls -A "$WORK/out2" 2>/dev/null | grep -v '^$' | tr '\n' ' ' | sed 's/ *$//')"

# MARK: - S3 通道隔离
echo '--- S3 stable 清单里混入 beta'
OUT3="$(bash "$FETCH" --feed "$WORK/feed/feed-stable.json" --channel stable --current-build 5 \
    --mirrors-file "$WORK/mirrors.env" --dest "$WORK/out3" 2>&1)"
check "S3 stable 通道拒绝 beta 条目" 2 "$?"

# MARK: - S4 防降级
echo '--- S4 清单比本机旧'
OUT4="$(bash "$FETCH" --feed "$WORK/feed/feed-old.json" --channel beta --current-build 5 \
    --mirrors-file "$WORK/mirrors.env" --dest "$WORK/out4" 2>&1)"
check "S4 不降级" 2 "$?"

# MARK: - S5 明文 http 拒绝
echo '--- S5 明文 http 清单'
OUT5="$(bash "$FETCH" --feed http://example.com/feed.json --channel beta --current-build 5 \
    --mirrors-file "$WORK/mirrors.env" --dest "$WORK/out5" 2>&1)"
check "S5 拒绝非 loopback http" 3 "$?"

echo
echo "[sim] $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
