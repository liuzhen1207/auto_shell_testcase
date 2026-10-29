#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_matrix_report.py -- 合并专项 skill 的结果汇总 / 双协议报告生成

背景：结果散落在多个 CSV 与 .out 里（全量轮、定点复跑、单用例补跑、B 段 V2 …），
      同一用例同一协议可能有多轮；且历史上出现过"远端脚本被截断导致的假失败"。
      本工具把它们汇总成「52 条用例 × 双协议」的**权威表**，并支持一份**作废清单**。

用法（在 skill 根目录执行）：
    python3 tools/build_matrix_report.py [--skill .] [--out docs/MATRIX_52x2.md]

产出：
    results/final_results.csv   case,protocol,result,elapsedSeconds,failCount,time,source,validity,note
    docs/MATRIX_52x2.md         总览 + 52 行主表 + 作废清单 + 历史轨迹 + 缺失清单
退出码：0（总是成功；数据缺失只体现在报告里）
"""
import argparse, csv, glob, os, re, sys

PROTOS = ["IoTConsensus", "IoTConsensusV2"]
CASE_RE = re.compile(r"^(CO|DT|CR|W)-\d{2}$")
# .out 里的 RESULT 行： [time] RESULT FAIL fail_flag=11 case=<name> consensus=<proto> build=<b> elapsed=1029s
OUT_RE = re.compile(
    r"^\[(?P<time>[^\]]+)\]\s+RESULT\s+(?P<result>PASS|FAIL)\s+fail_flag=(?P<ff>\d+)\s+case=(?P<case>\S+)\s+consensus=(?P<proto>\S+).*?elapsed=(?P<el>\d+)s"
)

def load_case_map(skill):
    """cases.tsv: id<TAB>script<TAB>... -> 两个方向的名字映射"""
    id2script, script2id = {}, {}
    p = os.path.join(skill, "cases", "cases.tsv")
    if not os.path.exists(p):
        return id2script, script2id
    for line in open(p, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 2 and CASE_RE.match(f[0]):
            id2script[f[0]] = f[1]
            script2id[os.path.basename(f[1])] = f[0]
    return id2script, script2id

def norm_case(name, script2id):
    n = os.path.basename(name.strip())
    if CASE_RE.match(n):
        return n
    base = re.sub(r"_(IoTConsensusV2|IoTConsensus)\.sh$", ".sh", n)
    return script2id.get(base)

def load_invalidated(skill):
    """results/INVALIDATED.tsv: case<TAB>protocol<TAB>source<TAB>reason"""
    rows = []
    p = os.path.join(skill, "results", "INVALIDATED.tsv")
    if not os.path.exists(p):
        return rows
    for line in open(p, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 3:
            rows.append({"case": f[0], "protocol": f[1], "source": f[2], "reason": f[3] if len(f) > 3 else ""})
    return rows

def load_gates(skill):
    """results/EXPECTED_GATES.tsv: case<TAB>protocol<TAB>reason —— 已知缺陷门禁，FAIL 属预期"""
    gates = {}
    p = os.path.join(skill, "results", "EXPECTED_GATES.tsv")
    if not os.path.exists(p):
        return gates
    for line in open(p, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 2:
            gates[(f[0], f[1])] = f[2] if len(f) > 2 else ""
    return gates

def collect(skill, script2id):
    recs = []
    rdir = os.path.join(skill, "results")
    for p in sorted(glob.glob(os.path.join(rdir, "*.csv"))):
        src = os.path.basename(p)
        if src in ("final_results.csv", "perf_baseline.csv"):
            continue
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                for row in csv.DictReader(fh):
                    cid = norm_case(row.get("caseName") or "", script2id)
                    proto = (row.get("consensus") or "").strip()
                    if not cid or proto not in PROTOS:
                        continue
                    recs.append({
                        "case": cid, "protocol": proto,
                        "result": (row.get("result") or "UNKNOWN").strip(),
                        "elapsed": (row.get("elapsedSeconds") or "").strip(),
                        "fail": (row.get("failCount") or "").strip(),
                        "time": (row.get("Time") or "").strip(),
                        "source": src,
                        "build": (row.get("build") or "").strip(),
                    })
        except Exception as e:
            print("WARN 读 %s 失败: %s" % (src, e), file=sys.stderr)
    for p in sorted(glob.glob(os.path.join(rdir, "*.out"))):
        src = os.path.basename(p)
        try:
            for line in open(p, encoding="utf-8", errors="replace"):
                m = OUT_RE.match(line.strip())
                if not m:
                    continue
                cid = norm_case(m.group("case"), script2id)
                proto = m.group("proto").strip()
                if not cid or proto not in PROTOS:
                    continue
                recs.append({
                    "case": cid, "protocol": proto, "result": m.group("result"),
                    "elapsed": m.group("el"), "fail": m.group("ff"),
                    "time": m.group("time"), "source": src, "build": "",
                })
        except Exception:
            pass
    # 去重：同一 (case,protocol,time,elapsed,result,source) 只留一条
    seen, out = set(), []
    for r in recs:
        k = (r["case"], r["protocol"], r["time"], r["elapsed"], r["result"], r["source"])
        if k in seen:
            continue
        seen.add(k); out.append(r)
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skill", default=".")
    ap.add_argument("--out", default="docs/MATRIX_52x2.md")
    ap.add_argument("--build", default="", help="只统计 build 含该子串的记录（例如 ebaf9da 只看 RC8）")
    a = ap.parse_args()
    skill = os.path.abspath(a.skill)
    id2script, script2id = load_case_map(skill)
    ids = sorted(id2script.keys()) or ["CO-01"]
    inval = load_invalidated(skill)
    gates = load_gates(skill)
    recs = collect(skill, script2id)
    if a.build:
        before = len(recs)
        recs = [r for r in recs if a.build in (r.get("build") or "")]
        print("按 build=%s 过滤：%d → %d 条记录" % (a.build, before, len(recs)))

    def is_invalid(r):
        for v in inval:
            if v["case"] == r["case"] and v["protocol"] == r["protocol"]:
                if v["source"] == "*" or v["source"] in r["source"] or v["source"] in r["time"]:
                    return v
        return None

    for r in recs:
        v = is_invalid(r)
        r["validity"] = "invalidated" if v else "valid"
        r["note"] = (v["reason"] if v else "")

    # 当前结论：每 (case,protocol) 取 valid 里最新的（按 time 字符串排序，ISO 可直接比）
    current = {}
    for r in recs:
        if r["validity"] != "valid":
            continue
        k = (r["case"], r["protocol"])
        if k not in current or (r["time"] or "") >= (current[k]["time"] or ""):
            current[k] = r

    # final_results.csv
    fcsv = os.path.join(skill, "results", "final_results.csv")
    with open(fcsv, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["case", "protocol", "result", "elapsedSeconds", "failCount", "time", "source", "validity", "note"])
        for cid in ids:
            for proto in PROTOS:
                r = current.get((cid, proto))
                if r:
                    w.writerow([cid, proto, r["result"], r["elapsed"], r["fail"], r["time"], r["source"], "valid", ""])
                else:
                    w.writerow([cid, proto, "MISSING", "", "", "", "", "missing", "无有效结果（未跑或全部被作废）"])

    # 预期门禁失败（已知缺陷的门禁，先算出来供总览使用）
    gate_fails = []
    for cid in ids:
        for proto in PROTOS:
            r = current.get((cid, proto))
            if r and r["result"] == "FAIL" and (cid, proto) in gates:
                gate_fails.append("%s/%s" % (cid, proto))

    # 统计
    stat = {p: {"PASS": 0, "FAIL": 0, "UNKNOWN": 0, "MISSING": 0} for p in PROTOS}
    for cid in ids:
        for proto in PROTOS:
            r = current.get((cid, proto))
            stat[proto][r["result"] if r and r["result"] in ("PASS", "FAIL", "UNKNOWN") else "MISSING"] += 1
    agree = dis = miss = 0
    for cid in ids:
        a1, a2 = current.get((cid, "IoTConsensus")), current.get((cid, "IoTConsensusV2"))
        if not a1 or not a2:
            miss += 1
        elif a1["result"] == a2["result"]:
            agree += 1
        else:
            dis += 1

    lines = []
    A = lines.append
    # 专项名按用例 ID 前缀自动判定（同一份工具被 compaction / crud / wal 复用）
    pref = ids[0].split("-")[0] if ids else "CO"
    skill_name = {"CO": "合并（compaction）", "DT": "合并（compaction）",
                  "CR": "CRUD", "W": "WAL"}.get(pref, "专项")
    A("# %s：%d 条用例 × 双协议 结果总表（自动生成）\n" % (skill_name, len(ids)))
    A("> 由 `tools/build_matrix_report.py` 生成；数据源 `results/*.csv` + `results/*.out`；"
      "作废规则见 `results/INVALIDATED.tsv`。**请勿手工编辑**。\n")
    A("## 1. 总览\n")
    A("| 协议 | PASS | FAIL | UNKNOWN | MISSING |")
    A("| --- | --- | --- | --- |")
    for p in PROTOS:
        A("| %s | %d | %d | %d | %d |" % (p, stat[p]["PASS"], stat[p]["FAIL"], stat[p]["UNKNOWN"], stat[p]["MISSING"]))
    A("\n双协议一致性：**一致 %d** / 分歧 %d / 缺 %d（共 %d 条用例）" % (agree, dis, miss, len(ids)))
    if gate_fails:
        A("\n其中**预期门禁失败**（已知缺陷的门禁，非新回归失败）：%s" % "、".join(sorted(set(gate_fails))))
    A("## 2. 主表\n")
    A("| 用例 | 脚本 | V1（IoTConsensus） | V2（IoTConsensusV2） | 一致性 | 备注 |")
    A("| --- | --- | --- | --- | --- | --- |")
    dis_cases, notes = [], []
    for cid in ids:
        a1, a2 = current.get((cid, "IoTConsensus")), current.get((cid, "IoTConsensusV2"))
        def cell(r, proto=None):
            if not r:
                return "—"
            txt = "%s (%ss%s)" % (r["result"], r["elapsed"], "" if r["result"] == "PASS" else " fail=%s" % r["fail"])
            if proto and r["result"] == "FAIL" and (cid, proto) in gates:
                txt += " **[预期门禁]**"
            return txt
        if not a1 or not a2:
            cons, note = "缺", "缺：" + ("V1 " if not a1 else "") + ("V2" if not a2 else "")
        elif a1["result"] == a2["result"]:
            cons, note = "一致", ""
        else:
            cons, note = "**分歧**", "V1=%s V2=%s" % (a1["result"], a2["result"])
            dis_cases.append(cid)
        if cid == "CO-35":
            note = (note + " ").strip() + " V2 fail=44 / V1 fail=1：已定性为用例 harness 缺陷（命令替换吞换行导致相位静默跳过），修复中"
        gate_note = ""
        for proto in PROTOS:
            if (cid, proto) in gates and current.get((cid, proto)) and current[(cid, proto)]["result"] == "FAIL":
                gate_note = "预期门禁：" + gates[(cid, proto)]
        if gate_note:
            note = ((note + " ") if note else "") + gate_note
        A("| %s | %s | %s | %s | %s | %s |" % (cid, os.path.basename(id2script.get(cid, "")),
                                               cell(a1, "IoTConsensus"), cell(a2, "IoTConsensusV2"), cons, note))
    A("\n## 3. 作废清单（不参与当前结论）\n")
    if inval:
        A("| 用例 | 协议 | 来源 | 原因 |")
        A("| --- | --- | --- | --- |")
        for v in inval:
            A("| %s | %s | %s | %s |" % (v["case"], v["protocol"], v["source"], v["reason"]))
    else:
        A("（无）")
    A("\n## 4. 历史轨迹（各轮，按时间）\n")
    A("```")
    for cid in ids:
        rs = sorted([r for r in recs if r["case"] == cid], key=lambda x: x["time"] or "")
        if not rs:
            continue
        A("%s:" % cid)
        for r in rs:
            A("   %s  %-15s %-5s %6ss fail=%-4s %s%s" % (
                r["time"], r["protocol"], r["result"], r["elapsed"], r["fail"], r["source"],
                "   [作废]" if r["validity"] == "invalidated" else ""))
    A("```")
    A("\n## 5. 缺失项（需补跑）\n")
    for cid in ids:
        for proto in PROTOS:
            if (cid, proto) not in current:
                A("- %s / %s" % (cid, proto))
    A("\n## 6. 分歧用例\n")
    A(", ".join(dis_cases) if dis_cases else "（无）")

    outp = os.path.join(skill, a.out)
    os.makedirs(os.path.dirname(outp), exist_ok=True)
    open(outp, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("已生成: %s" % outp)
    print("已生成: %s" % fcsv)
    print("总览: " + " | ".join("%s PASS=%d FAIL=%d UNKNOWN=%d MISSING=%d" % (p, stat[p]["PASS"], stat[p]["FAIL"], stat[p]["UNKNOWN"], stat[p]["MISSING"]) for p in PROTOS))
    print("一致性: 一致=%d 分歧=%d 缺=%d" % (agree, dis, miss))

if __name__ == "__main__":
    main()
