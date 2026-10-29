#!/usr/bin/env python3
"""Turn a finished `rcdn matrix` run directory into a Chinese markdown baseline.

    python3 scripts/report_matrix.py results/matrix_20261024_184111 \
        --title "2.0.12.1 RC11（ea4f835）remove CN/DN 回归基线" \
        --build 2.0.12.1 --commit ea4f835 --topology 3C5D \
        -o 最终基线_30.md

The generator only reads `summary.tsv` and each case's `result.json`; it does
not decide verdicts.  Anything it cannot classify is copied verbatim into the
"未归类" section instead of being smoothed over.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path


def read_summary(run_dir: Path) -> list[dict[str, str]]:
    path = run_dir / "summary.tsv"
    if not path.exists():
        raise SystemExit(f"{path} 不存在；先把这个 run 跑完")
    rows: list[dict[str, str]] = []
    header: list[str] | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        cells = line.split("\t")
        if header is None:
            header = cells
            continue
        rows.append({h: (cells[i] if i < len(cells) else "") for i, h in enumerate(header)})
    return rows


def case_steps(run_dir: Path, case_id: str) -> list[str]:
    path = run_dir / "cases" / case_id / "result.json"
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return []
    return [str(s) for s in data.get("steps", [])]


def fmt_duration(sec: float) -> str:
    sec = float(sec or 0)
    h, rem = divmod(int(sec), 3600)
    m, s = divmod(rem, 60)
    return f"{h}h{m:02d}m" if h else f"{m}m{s:02d}s"


def object_evidence(run_dir: Path, case_id: str) -> str:
    """One line summarising the OBJECT audit artifacts of a case, if any."""
    base = run_dir / "cases" / case_id
    bits: list[str] = []
    for name, label in (
        ("object_size_audit.json", "迁移后"),
        ("object_size_audit_cold.json", "冷启动后"),
        ("object_residue_audit.json", "删除残留"),
    ):
        path = base / name
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        if "gc_records" in data:
            bits.append(f"{label} GC 记录 {data['gc_records']} 条 / 确认残留 {len(data.get('problems', []))} 处")
        else:
            physical = sum(1 for r in data.get("replicas", []) if r.get("physical_bytes", 0) > 0)
            bits.append(
                f"{label} {len(data.get('replicas', []))} 副本（{physical} 个有实体 OBJECT）/ 问题 {len(data.get('problems', []))}"
            )
    return "；".join(bits)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir")
    ap.add_argument("--title", default="remove CN/DN 回归基线")
    ap.add_argument("--build", default="")
    ap.add_argument("--commit", default="")
    ap.add_argument("--topology", default="3C5D")
    ap.add_argument("--notes", default="")
    ap.add_argument("-o", "--out", default="")
    args = ap.parse_args()

    run_dir = Path(args.run_dir)
    rows = read_summary(run_dir)
    total = len(rows)
    counts: dict[str, int] = {}
    for row in rows:
        counts[row.get("status", "?")] = counts.get(row.get("status", "?"), 0) + 1
    total_sec = sum(float(r.get("elapsed_sec") or 0) for r in rows)

    lines: list[str] = []
    lines.append(f"# {args.title}")
    lines.append("")
    meta = [f"- 运行目录：`{run_dir}`"]
    if args.build:
        meta.append(f"- 被测版本：**{args.build}**" + (f"（commit `{args.commit}`）" if args.commit else ""))
    meta.append(f"- 拓扑：**{args.topology}**")
    meta.append(f"- 用例数：**{total}**；耗时：**{fmt_duration(total_sec)}**")
    meta.append(
        "- 结论："
        + " / ".join(
            f"**{k} {v}**" for k, v in sorted(counts.items(), key=lambda kv: -kv[1])
        )
    )
    if args.notes:
        meta.append(f"- 备注：{args.notes}")
    meta.append(f"- 生成时间：{time.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.extend(meta)
    lines.append("")

    for status in ("FAIL", "SKIP"):
        subset = [r for r in rows if r.get("status") == status]
        if not subset:
            continue
        lines.append(f"## {status}（{len(subset)}）")
        lines.append("")
        for row in subset:
            cid = row.get("case_id", "")
            lines.append(f"### `{cid}` — {fmt_duration(float(row.get('elapsed_sec') or 0))}")
            problems = [p for p in (row.get("problems") or "").split(" | ") if p.strip()]
            for problem in problems:
                lines.append(f"- {problem}")
            evidence = object_evidence(run_dir, cid)
            if evidence:
                lines.append(f"- OBJECT 审计证据：{evidence}")
            steps = [
                s
                for s in case_steps(run_dir, cid)
                if "审计说明" in s or "前置条件" in s or "未能注入" in s
            ]
            for step in steps[:5]:
                lines.append(f"- {step}")
            lines.append("")

    lines.append("## 全部用例")
    lines.append("")
    lines.append("| # | 用例 | 结果 | 耗时 | 说明 |")
    lines.append("|---|------|------|------|------|")
    for i, row in enumerate(rows, 1):
        cid = row.get("case_id", "")
        note = (row.get("problems") or "").split(" | ")[0][:120]
        evidence = object_evidence(run_dir, cid)
        if evidence:
            note = (note + "；" if note else "") + evidence
        lines.append(
            f"| {i} | `{cid}` | {row.get('status', '')} | "
            f"{fmt_duration(float(row.get('elapsed_sec') or 0))} | {note} |"
        )
    lines.append("")

    text = "\n".join(lines) + "\n"
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"written {args.out}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
