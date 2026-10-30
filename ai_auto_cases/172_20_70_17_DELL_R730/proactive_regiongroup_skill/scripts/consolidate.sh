#!/usr/bin/env bash
# 汇总所有轮次结果为一份中文 FINAL_SUMMARY.md（可反复运行，随运行推进自动更新）。
# 用法: bash scripts/consolidate.sh [results 根]    默认 <skill>/results
for cand in "${1:-}" "$(cd "$(dirname "$0")/.." && pwd)" "$(cd "$(dirname "$0")/../iotdb-proactive-regiongroup" && pwd)" /home/ubuntu/remove_cn_dn/pg_build; do
  [ -n "$cand" ] && [ -d "$cand/results" ] && cd "$cand" && break
done
python3 - <<'PY'
import json, glob, collections, datetime, pathlib
runs = []
dirs = sorted(set(glob.glob("results/*/")) | set(glob.glob("iotdb-proactive-regiongroup/results/*/")))
for d in dirs:
    fs = glob.glob(d + "cases/*/result.json")
    if fs:
        runs.append((d.rstrip("/").split("/")[-1], [json.load(open(f)) for f in fs]))
out = [f"# TDB-367 PROACTIVE 回归 —— 最终汇总（{datetime.datetime.now():%Y-%m-%d %H:%M}）", ""]
out.append("| 轮次 | 用例数 | PASS | FAIL | SKIP | INVALID |")
out.append("|---|---|---|---|---|---|")
total = collections.Counter()
allfails = []
for name, cases in runs:
    c = collections.Counter(x["status"] for x in cases)
    total.update(c)
    out.append(f"| {name} | {len(cases)} | {c.get('PASS',0)} | {c.get('FAIL',0)} | "
               f"{c.get('SKIP',0)} | {c.get('INVALID',0)} |")
    for x in cases:
        if x["status"] == "FAIL":
            bad = "; ".join(ch["name"] for ch in x["checks"] if not ch["ok"])
            allfails.append((name, x["case_id"], bad))
out += ["", f"**合计**：{sum(total.values())} 例（PASS={total.get('PASS',0)}、FAIL={total.get('FAIL',0)}、"
        f"SKIP={total.get('SKIP',0)}、INVALID={total.get('INVALID',0)}）", ""]
if allfails:
    out.append("## 全部 FAIL（需按 DEFECT_CANDIDATES.md / HARNESS_FINDINGS.md 逐条定性）")
    out.append("")
    for run, cid, bad in allfails:
        out.append(f"* `{run}` / **{cid}**：{bad[:200]}")
else:
    out.append("（暂无 FAIL）")
out += ["", "> 口径：判定与证据见各轮 `cases/<CASE_ID>/result.json`；产品缺陷与 harness 问题分别登记在",
        "> `DEFECT_CANDIDATES.md` 与 `HARNESS_FINDINGS.md`，两者不得混记。"]
pathlib.Path("FINAL_SUMMARY.md").write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"  已写出 FINAL_SUMMARY.md：{len(runs)} 个轮次、{sum(total.values())} 例")
PY
