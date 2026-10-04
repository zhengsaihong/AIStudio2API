#!/bin/bash
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WEBHOOK="$(cat /opt/aistudio2api/.feishu_webhook)"

JSON=$(/usr/bin/python3 - <<'PY'
import json
import subprocess
from collections import Counter, defaultdict
from datetime import datetime, timezone, timedelta

TZ = timezone(timedelta(hours=8))

raw = subprocess.run(
    [
        "/usr/bin/journalctl",
        "-u", "aistudio2api-go",
        "--since", datetime.now(TZ).strftime("%Y-%m-%d 00:00:00"),
        "-o", "cat",
        "--no-pager",
    ],
    capture_output=True,
    text=True,
    check=True,
).stdout

rows = []

for line in raw.splitlines():
    pos = line.find("{")
    if pos < 0 or '"event":"request.finished"' not in line:
        continue

    try:
        event = json.loads(line[pos:])
        request = event.get("request") or {}
        model = request.get("model") or ""
        path = request.get("path") or ""

        # 只统计图片生成请求，排除 /v1/models、/.env 等系统请求
        if "image" not in model:
            continue
        if "generateContent" not in path and "/images/generations" not in path:
            continue
        if not request.get("id"):
            continue

        rows.append(request)
    except (ValueError, KeyError):
        continue

today = datetime.now(TZ).strftime("%Y-%m-%d")

if not rows:
    text = "AI Studio 用量日报 %s\n今天没有图片请求。" % today
else:
    total = len(rows)
    success = sum(r.get("state") == "completed" for r in rows)
    failed = total - success
    images = sum(
        r.get("state") == "completed"
        and (r.get("upstream_bytes") or 0) >= 1000000
        for r in rows
    )
    rate = success * 100 / total if total else 0

    lines = [
        "AI Studio 用量日报 %s" % today,
        "",
        "图片请求：%d" % total,
        "成功：%d" % success,
        "失败/拦截/取消：%d" % failed,
        "出图：%d" % images,
        "成功率：%.1f%%" % rate,
        "",
        "按模型：",
    ]

    by_model = defaultdict(Counter)
    for r in rows:
        model = r.get("model") or "(none)"
        by_model[model]["requests"] += 1
        if (
            r.get("state") == "completed"
            and (r.get("upstream_bytes") or 0) >= 1000000
        ):
            by_model[model]["images"] += 1

    for model, count in sorted(
        by_model.items(),
        key=lambda item: item[1]["requests"],
        reverse=True,
    ):
        lines.append(
            "%s：请求 %d，出图 %d"
            % (model, count["requests"], count["images"])
        )

    text = "\n".join(lines)

payload = {
    "msg_type": "text",
    "content": {"text": text},
}

print(json.dumps(payload, ensure_ascii=False))
PY
)

for attempt in 1 2 3; do
    RESPONSE="$(curl -sS \
      -X POST \
      -H 'Content-Type: application/json' \
      --data "$JSON" \
      "$WEBHOOK")" || RESPONSE=""

    echo "第 ${attempt} 次飞书返回：${RESPONSE}"

    if /usr/bin/python3 - "$RESPONSE" <<'PY_CHECK'
import json
import sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)

raise SystemExit(0 if data.get("code") == 0 else 1)
PY_CHECK
    then
        echo "飞书发送成功"
        exit 0
    fi

    if [ "$attempt" -lt 3 ]; then
        echo "飞书发送失败，70 秒后重试"
        sleep 70
    fi
done

echo "飞书连续 3 次发送失败"
exit 1
