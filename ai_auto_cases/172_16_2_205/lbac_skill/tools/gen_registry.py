#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 LBAC 用例总账（CASE_REGISTRY.md + registry.tsv）。

数据源：
  cases.tsv                                        —— 用例清单（id/文件/模块/类型/描述/函数）
  docs/results_20261113/r_normal.tsv, r_sep.tsv    —— IoTConsensus 双模式
  docs/results_20261114_v2/a1.tsv, a2.tsv          —— IoTConsensusV2 双模式
用法：python tools/gen_registry.py
"""
import csv
import io
import os
import re

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES_TSV = os.path.join(BASE, "cases.tsv")
RUNS = [
    ("io_normal", os.path.join(BASE, "docs", "results_20261113", "r_normal.tsv")),
    ("io_sep", os.path.join(BASE, "docs", "results_20261113", "r_sep.tsv")),
    ("v2_normal", os.path.join(BASE, "docs", "results_20261114_v2", "a1.tsv")),
    ("v2_sep", os.path.join(BASE, "docs", "results_20261114_v2", "a2.tsv")),
]
OUT_TSV = os.path.join(BASE, "registry.tsv")
OUT_MD = os.path.join(BASE, "docs", "CASE_REGISTRY.md")

COLS = ["id", "file", "module", "type", "desc", "func",
        "status", "skip_reason", "io_normal", "io_sep", "v2_normal", "v2_sep"]


def read_tsv(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with io.open(path, encoding="utf-8-sig") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 7:
                rows.append(p)
    return rows


def main():
    cases = []
    with io.open(CASES_TSV, encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) < 6 or not p[0].startswith("LB-"):
                continue
            cases.append({"id": p[0], "file": p[1], "module": p[2], "type": p[3],
                          "desc": p[4], "func": p[5]})

    verdict = {k: {} for k, _ in RUNS}
    detail = {k: {} for k, _ in RUNS}
    for key, path in RUNS:
        for r in read_tsv(path):
            verdict[key][r[0]] = r[3]
            detail[key][r[0]] = r[6] if len(r) > 6 else ""

    rows = []
    for c in cases:
        v = {k: verdict[k].get(c["id"], "") for k, _ in RUNS}
        vals = [x for x in v.values() if x]
        if vals and all(x == "SKIP" for x in vals):
            status = "跳过"
        elif "SKIP" in v.values() and "PASS" in v.values():
            status = "条件执行"
        elif vals:
            status = "执行"
        else:
            status = "未运行"
        reason = ""
        for k, _ in RUNS:
            if v[k] == "SKIP":
                reason = detail[k].get(c["id"], "")
                if reason:
                    break
        rows.append([c["id"], c["file"], c["module"], c["type"], c["desc"], c["func"],
                     status, reason.replace("\t", " "),
                     v["io_normal"] or "-", v["io_sep"] or "-",
                     v["v2_normal"] or "-", v["v2_sep"] or "-"])

    with io.open(OUT_TSV, "w", encoding="utf-8", newline="\n") as f:
        f.write("\t".join(COLS) + "\n")
        for r in rows:
            f.write("\t".join(r) + "\n")

    # Markdown
    from collections import OrderedDict
    groups = OrderedDict()
    for r in rows:
        groups.setdefault(r[2], []).append(r)
    total = len(rows)
    run_cnt = sum(1 for r in rows if r[6] == "执行")
    cond_cnt = sum(1 for r in rows if r[6] == "条件执行")
    skip_cnt = sum(1 for r in rows if r[6] == "跳过")

    md = []
    md.append("# LBAC 用例总账（回归对照基准）\n")
    md.append("> 本文件由 `tools/gen_registry.py` 自动生成，请勿手工编辑；新增/删改用例后重新生成。\n")
    md.append("> 回归前先跑 `python tools/check_cases.py`，确认用例清单、脚本函数、总账三者一致（防止遗漏）。\n")
    md.append("")
    md.append("| 项 | 数量 |")
    md.append("| --- | ---: |")
    md.append("| 用例总数 | %d |" % total)
    md.append("| 常规执行 | %d |" % run_cnt)
    md.append("| 条件执行（仅三权分立） | %d |" % cond_cnt)
    md.append("| 跳过（不适用/待确认） | %d |" % skip_cnt)
    md.append("")
    md.append("判决列说明：`io_*` = IoTConsensus；`v2_*` = IoTConsensusV2；`normal` = 普通模式；`sep` = 三权分立；`-` = 该轮未参与。")
    md.append("")
    for mod, rs in groups.items():
        md.append("## %s（%d 条）\n" % (mod, len(rs)))
        md.append("| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | v2普通 | v2三权 |")
        md.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
        for r in rs:
            desc = r[4].replace("|", "\\|")
            md.append("| %s | %s | %s | %s | %s | %s | %s | %s |" %
                      (r[0], r[3], desc, r[6], r[8], r[9], r[10], r[11]))
        md.append("")
    md.append("## 跳过明细\n")
    md.append("| 用例 | 原因 |")
    md.append("| --- | --- |")
    for r in rows:
        if r[6] in ("跳过", "条件执行"):
            md.append("| %s | %s |" % (r[0], r[7] or "-"))
    md.append("")

    with io.open(OUT_MD, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(md))
    print("registry.tsv: %d 行（执行 %d / 条件 %d / 跳过 %d）" % (total, run_cnt, cond_cnt, skip_cnt))
    print("CASE_REGISTRY.md: %d 个模块" % len(groups))


if __name__ == "__main__":
    main()
