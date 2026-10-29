#!/usr/bin/env python3
"""把 TREEVIEW 的 results/*/cases/*/result.json 汇总成一份 Markdown 报告。

用法：python3 aggregate_tv.py <results_dir> <out.md> [--prefix tv]
同一用例多次运行取 run_id 最大（字典序）的那次。
"""
import json
import pathlib
import sys

results = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
prefix = sys.argv[4] if len(sys.argv) > 4 and sys.argv[3] == "--prefix" else ""

runs = [d for d in results.iterdir() if d.is_dir() and d.name.startswith(prefix)]
# 同一用例可能跑过多次（tv / tv2 / tv3 接力，或修复后复跑）：
# 按 result.json 的**修改时间**取最新，而不是按 run 目录名字典序
# （字典序下 "tv_" > "tv3_"，会把旧结果当最新）。
latest: dict[str, tuple[float, dict]] = {}
for run in runs:
    cdir = run / "cases"
    if not cdir.is_dir():
        continue
    for case_dir in cdir.iterdir():
        f = case_dir / "result.json"
        if f.is_file():
            try:
                rec = json.loads(f.read_text(encoding="utf-8"))
            except Exception:
                continue
            mt = f.stat().st_mtime
            if case_dir.name not in latest or mt > latest[case_dir.name][0]:
                latest[case_dir.name] = (mt, rec)
latest = {k: v[1] for k, v in latest.items()}

order = {k: i for i, k in enumerate(sorted(latest))}
counts: dict[str, int] = {}
for r in latest.values():
    counts[r.get("status", "?")] = counts.get(r.get("status", "?"), 0) + 1

lines = ["# 树转表视图（Tree View）测试结果", ""]
lines.append(f"- 用例数：{len(latest)}")
for k in ("PASS", "FAIL", "SKIP", "INVALID"):
    if counts.get(k):
        lines.append(f"- {k}：{counts[k]}")
lines += ["", "## 用例结果", "", "| 用例 | 结果 | 耗时(s) | 失败断言 |", "|---|---|---|---|"]
for cid in sorted(latest):
    r = latest[cid]
    fails = [c["name"] for c in r.get("checks", []) if not c["ok"]]
    first = fails[0][:60] if fails else ""
    lines.append(f"| {cid} | {r.get('status')} | {r.get('seconds', 0):.0f} | {first} |")

fails_all = [(cid, r) for cid, r in sorted(latest.items()) if r.get("status") == "FAIL"]
if fails_all:
    lines += ["", "## FAIL 明细", ""]
    for cid, r in fails_all:
        lines.append(f"### {cid}")
        for c in r.get("checks", []):
            if not c["ok"]:
                lines.append(f"- **{c['name']}**：{c.get('detail', '')[:400]}")
        lines.append("")

out.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"written {out}: {len(latest)} cases, counts={counts}")
