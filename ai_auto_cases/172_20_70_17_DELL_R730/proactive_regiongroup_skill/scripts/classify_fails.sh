#!/usr/bin/env bash
# 用法: bash classify_fails.sh [run-id]   （默认 pg_core_iot2）
# 输出每个 FAIL 用例的：失败检查名 + 关键数值/首条日志命中，便于逐条定性（D-xx 产品 / H-xx harness）
# results 根目录自动探测：优先 $PG_ROOT，其次脚本同级/上一级的 results（兼容驱动机与客户端机）
for cand in "${PG_ROOT:-}" "$(cd "$(dirname "$0")" && pwd)" "$(cd "$(dirname "$0")/.." && pwd)" "$(cd "$(dirname "$0")/../iotdb-proactive-regiongroup" && pwd)"; do
  [ -n "$cand" ] && [ -d "$cand/results" ] && cd "$cand" && break
done
R="${1:-pg_core_iot2}"
python3 - "$R" <<'PY'
import json, glob, sys, re
run = sys.argv[1]
rows = sorted(glob.glob(f"results/{run}*/cases/*/result.json"))
if not rows:
    print(f"  {run}: 无已完成用例"); raise SystemExit
fails = 0
for f in rows:
    d = json.load(open(f))
    if d["status"] != "FAIL":
        continue
    fails += 1
    print(f"\n== {d['case_id']}  {d.get('title','')[:60]}")
    for c in d["checks"]:
        if c["ok"]:
            continue
        name, det = c["name"][:58], str(c.get("detail", ""))
        print(f"   - {name}")
        if "ERROR/WARN" in c["name"]:
            for m in re.finditer(r"(dn@[\d.]+|cn@[\d.]+)[:：].*?(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)[^\n]*?WARN\s+([\w.$]+:\d+)\s*-\s*([^;]{0,90})", det):
                print(f"       日志: {m.group(1)} {m.group(2)} {m.group(3)} :: {m.group(4).strip()[:88]}")
                break
            hosts = sorted(set(re.findall(r'(?:dn|cn)@([\d.]+)', det)))
            print("       受影响节点: " + str(hosts))
        elif det:
            print(f"       实测: {det[:150]}")
print(f"\n  共 {fails} 条 FAIL / {len(rows)} 条已完成")
PY
