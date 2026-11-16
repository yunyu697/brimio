#!/bin/bash
#
# 更新清单（feed）的生成器。单一数据源：Release/feed/items.jsonl（每行一条已发布记录）。
#
#   Scripts/release-feed.sh --add v1.0.0-beta1 dist/brimio-v1.0.0-beta1.zip
#   Scripts/release-feed.sh --emit                    # 写 dist/feed/feed-stable.json + feed-beta.json
#   Scripts/release-feed.sh --emit --out /tmp/feed --include-alpha
#   Scripts/release-feed.sh --list
#
# 通道模型（两道闸）：
#   1) 生成时按 stage 过滤：stable 清单只含 stable；beta 清单含 stable/beta/rc；alpha 永不进公开清单。
#   2) 客户端取条目后再按同一张表过滤一次（见 Scripts/fetch-update.sh）。
#
# 清单里写死「期望 sha256 + 版本串 + build」，客户端下载后逐字节比对；
# 本项目不做签名，sha256 就是唯一完整性依据（见 Release/RELEASE-PLAN.md 第 8 节）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/Config/naming.env"
# shellcheck disable=SC1091
source "$ROOT/Config/release.env"

ITEMS="$ROOT/Release/feed/items.jsonl"
OUT="$ROOT/dist/feed"
MODE=""
TAG=""
ASSET=""
INCLUDE_ALPHA=0
RELEASED_AT=""
NOTES_URL=""

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --add) MODE="add"; TAG="${2:-}"; ASSET="${3:-}"; shift 3 ;;
        --emit) MODE="emit"; shift ;;
        --list) MODE="list"; shift ;;
        --out) OUT="${2:-}"; shift 2 ;;
        --include-alpha) INCLUDE_ALPHA=1; shift ;;
        --released-at) RELEASED_AT="${2:-}"; shift 2 ;;
        --notes-url) NOTES_URL="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$ITEMS")"
[[ -f "$ITEMS" ]] || : > "$ITEMS"

case "$MODE" in
    add)
        [[ -n "$TAG" && -n "$ASSET" ]] || { echo "--add 需要 <tag> <asset.zip>" >&2; exit 2; }

        # 已有记录不允许覆盖：同一个 tag 重新打包会让已经下载过的用户拿不到新包，
        # 且 build 相同、sha 不同，客户端无法判断谁新。要改就换 tag。
        if python3 - "$ITEMS" "$TAG" <<'PY'
import json, sys
path, tag = sys.argv[1], sys.argv[2]
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if line and json.loads(line).get("tag") == tag:
        sys.exit(0)
sys.exit(1)
PY
        then
            echo "[feed] FAIL $TAG 已在 $ITEMS 中；不允许覆盖已发布记录（请换 tag）" >&2
            exit 1
        fi

        VERIFY_JSON="$(bash "$ROOT/Scripts/release-verify.sh" --json "$TAG" "$ASSET")"
        [[ -n "${RELEASED_AT:-}" ]] || RELEASED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        VERIFY_JSON="$VERIFY_JSON" python3 - "$ITEMS" "$TAG" "$RELEASED_AT" "${NOTES_URL:-}" \
            "https://github.com/$UPDATE_OWNER/$UPDATE_REPO/releases/download" <<'PY'
import json, os, sys
items_path, tag, released_at, notes_url, base = sys.argv[1:6]
rec = json.loads(os.environ["VERIFY_JSON"])
record = {
    "tag": rec["tag"],
    "version": rec["version"],
    "build": rec["build"],
    "stage": rec["stage"],
    "order_key": rec["order_key"],
    "released_at": released_at,
    "min_os": rec["min_os"],
    "asset": rec["asset"],
    "size": rec["size"],
    "sha256": rec["sha256"],
    "arch": rec["arch"],
    "url": f"{base}/{tag}/{rec['asset']}",
    "notes_url": notes_url,
}
line = json.dumps(record, ensure_ascii=False, sort_keys=True)
with open(items_path, "a", encoding="utf-8") as fh:
    fh.write(line + "\n")
print(f"[feed] add  tag={record['tag']} build={record['build']} stage={record['stage']} "
      f"size={record['size']} sha256={record['sha256'][:12]}…")
PY
        ;;

    emit)
        mkdir -p "$OUT"
        OUT="$OUT" python3 - "$ITEMS" "$OUT" "$FEED_SCHEMA" "$FEED_STABLE_ASSET" \
            "$FEED_BETA_ASSET" "$FEED_ALPHA_ASSET" "$MIN_MACOS" "$CHANNEL_STABLE_SEES" \
            "$CHANNEL_BETA_SEES" "$INCLUDE_ALPHA" <<'PY'
import json, os, sys, datetime
(items_path, out_dir, schema, stable_asset, beta_asset, alpha_asset,
 min_os, stable_sees, beta_sees, include_alpha) = sys.argv[1:11]
items = []
with open(items_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line:
            items.append(json.loads(line))

plan = [
    ("stable", stable_asset, set(stable_sees.split())),
    ("beta", beta_asset, set(beta_sees.split())),
]
if include_alpha == "1":
    plan.append(("alpha", alpha_asset, {"stable", "beta", "rc", "alpha"}))

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for channel, asset_name, sees in plan:
    visible = [it for it in items if it["stage"] in sees]
    visible.sort(key=lambda it: (it["build"], it["order_key"]), reverse=True)
    doc = {
        "schema": int(schema),
        "channel": channel,
        "generated_at": now,
        "min_os": min_os,
        "item_count": len(visible),
        "items": visible,
    }
    path = os.path.join(out_dir, asset_name)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2, sort_keys=False)
        fh.write("\n")
    stages = ",".join(sorted({it["stage"] for it in visible})) or "-"
    print(f"[feed] emit {channel:<6} items={len(visible):<2} stages={stages:<12} -> {path}")
PY
        ;;

    list)
        python3 - "$ITEMS" <<'PY'
import json, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if line:
        rows.append(json.loads(line))
rows.sort(key=lambda r: (r["build"], r["order_key"]))
print(f"{'tag':<22}{'build':>6}  {'stage':<7}{'size':>9}  sha256[:12]")
for r in rows:
    print(f"{r['tag']:<22}{r['build']:>6}  {r['stage']:<7}{r['size']:>9}  {r['sha256'][:12]}")
print(f"total={len(rows)}")
PY
        ;;

    *)
        usage >&2
        exit 2
        ;;
esac
