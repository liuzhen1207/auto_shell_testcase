#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LBAC 用例一致性自检（回归前必跑，防止遗漏）。

检查项：
  1) cases.tsv 的 ID 唯一、连续（LB-001..LB-NNN 无空洞）
  2) cases.tsv 中每个「会执行」的用例，其函数 case_LBxxx 在对应脚本中存在
  3) cases/*.sh 里 CASES+=(...) 声明的 ID 与 cases.tsv 完全一致（无多、无少）
  4) registry.tsv 与 cases.tsv 的 ID 集合一致
  5) 汇总统计与最近一轮结果对齐（执行+条件执行+跳过 == 总数）

用法：python tools/check_cases.py [--quiet]
返回码：0 一致；1 发现不一致（打印明细）
"""
import io
import os
import re
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES_DIR = os.path.join(BASE, "cases")
CASES_TSV = os.path.join(BASE, "cases.tsv")
REGISTRY = os.path.join(BASE, "registry.tsv")

errors = []
warnings = []


def load_cases_tsv():
    rows = []
    with io.open(CASES_TSV, encoding="utf-8") as f:
        for ln, line in enumerate(f, 1):
            p = line.rstrip("\n").split("\t")
            if len(p) < 6 or not p[0].startswith("LB-"):
                continue
            rows.append((p[0], p[1], p[2], p[3], p[4], p[5], ln))
    return rows


def load_declarations():
    decl = {}
    for fn in sorted(os.listdir(CASES_DIR)):
        if not fn.endswith(".sh"):
            continue
        path = os.path.join(CASES_DIR, fn)
        with io.open(path, encoding="utf-8") as f:
            text = f.read()
        for m in re.finditer(r'^"(LB-\d{3})\|', text, re.M):
            decl.setdefault(m.group(1), []).append(fn)
    return decl


def load_functions():
    funcs = set()
    for fn in sorted(os.listdir(CASES_DIR)):
        if not fn.endswith(".sh"):
            continue
        with io.open(os.path.join(CASES_DIR, fn), encoding="utf-8") as f:
            text = f.read()
        funcs.update(re.findall(r"^case_(LB\d{3})\(\)", text, re.M))
    return funcs


def load_registry():
    ids = {}
    if not os.path.exists(REGISTRY):
        return None
    with io.open(REGISTRY, encoding="utf-8") as f:
        next(f, None)
        for line in f:
            p = line.rstrip("\n").split("\t")
            if p and p[0].startswith("LB-"):
                ids[p[0]] = p
    return ids


def main():
    quiet = "--quiet" in sys.argv
    rows = load_cases_tsv()
    ids = [r[0] for r in rows]

    # 1) 唯一 + 连续
    if len(ids) != len(set(ids)):
        dup = sorted({i for i in ids if ids.count(i) > 1})
        errors.append("cases.tsv 存在重复 ID：%s" % ", ".join(dup))
    nums = sorted(int(i.split("-")[1]) for i in ids)
    if nums and nums != list(range(1, len(nums) + 1)):
        missing = [n for n in range(1, max(nums) + 1) if n not in nums]
        if missing:
            errors.append("cases.tsv ID 不连续，缺少：%s" % ", ".join("LB-%03d" % n for n in missing))

    # 2) 函数存在（跳过类允许没有函数，由跳过原因判定）
    decl = load_declarations()
    funcs = load_functions()
    for cid, _f, _m, _t, _d, func, ln in rows:
        num = cid.replace("LB-", "")
        key = "LB" + num          # 脚本内函数名为 case_LBxxx
        if cid not in decl:
            errors.append("%s（cases.tsv 第 %d 行）未在任何 cases/*.sh 的 CASES 中声明" % (cid, ln))
        if key not in funcs and cid not in SKIP_OK:
            errors.append("%s 缺少函数 case_%s（且未标注为跳过类）" % (cid, key))
        if func and key in funcs and func != "case_" + key:
            warnings.append("%s 的 func 列是 %s，但脚本中函数名为 case_%s" % (cid, func, key))

    # 3) 声明与清单一致
    tsv_set, decl_set = set(ids), set(decl)
    for x in sorted(decl_set - tsv_set):
        errors.append("%s 在脚本中声明，但 cases.tsv 中没有" % x)
    for x in sorted(tsv_set - decl_set):
        errors.append("%s 在 cases.tsv 中，但脚本中没有声明" % x)

    # 4) 总账一致
    reg = load_registry()
    if reg is None:
        warnings.append("registry.tsv 不存在，跳过总账比对（可运行 tools/gen_registry.py 生成）")
    else:
        for x in sorted(tsv_set - set(reg)):
            errors.append("%s 未纳入 registry.tsv（总账遗漏）" % x)
        for x in sorted(set(reg) - tsv_set):
            errors.append("%s 在 registry.tsv 中但已从 cases.tsv 删除（总账需重新生成）" % x)

    # 5) 统计
    print("用例总数：%d" % len(ids))
    if reg:
        from collections import Counter
        c = Counter(r[6] for r in reg.values())
        print("总账状态：执行 %d / 条件执行 %d / 跳过 %d" % (c.get("执行", 0), c.get("条件执行", 0), c.get("跳过", 0)))
        if sum(c.values()) != len(ids):
            errors.append("总账状态合计 %d != 用例总数 %d" % (sum(c.values()), len(ids)))

    if warnings and not quiet:
        print("\n警告：")
        for w in warnings:
            print("  - " + w)
    if errors:
        print("\n发现 %d 处不一致：" % len(errors))
        for e in errors:
            print("  [FAIL] " + e)
        return 1
    print("\n一致性检查通过：cases.tsv / cases/*.sh / registry.tsv 三者对齐。")
    return 0


# 已知「跳过类」用例：无执行函数（需求待确认或语法不支持）
SKIP_OK = {
    "LB-143", "LB-144", "LB-146", "LB-154", "LB-158", "LB-159", "LB-160",
    "LB-196", "LB-197",
}

if __name__ == "__main__":
    sys.exit(main())
