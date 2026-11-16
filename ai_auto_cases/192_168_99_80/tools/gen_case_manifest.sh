#!/bin/bash
# ============================================================================
# gen_case_manifest.sh —— 生成"所有 skill 用例"的主清单（机器可读 + 人读）
#   用法： bash tools/gen_case_manifest.sh [--build 83183d0]
#   输出： manifest/skill_cases_manifest.tsv   机器可读（每次回归对账用）
#          manifest/SKILL_CASES_MANIFEST.md    人读（含各 skill 统计与未跑清单）
#   说明： 各 skill 的 cases.tsv 列布局不同，脚本按"含 cases/ 或 .sh 的那一列"识别用例文件列，
#          第 1 列为编号，最后一列为说明；没有 cases.tsv 的 skill（如 treeview）按文件名枚举。
# ============================================================================
set -u
A=/data/iotdb/autotest
BUILD="83183d0"
while [ $# -gt 0 ]; do case "$1" in --build) BUILD="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$A/manifest"

python3 - "$A" "$BUILD" <<'PY'
import csv, os, re, sys, glob, collections

A, TARGET = sys.argv[1], sys.argv[2]
skills = sorted(os.path.basename(p) for p in glob.glob(A + "/*_skill") if os.path.isdir(p))

def read_results(path):
    """returns list of dict(time, build, consensus, case, result, elapsed)"""
    out = []
    if not os.path.exists(path):
        return out
    csv.field_size_limit(10**7)
    with open(path, errors="replace") as f:
        for p in csv.reader(f):
            if len(p) < 6 or p[0].strip() in ("Time", ""):
                continue
            out.append(dict(time=p[0], build=p[1], consensus=p[2], case=p[3],
                            result=p[4], elapsed=p[5]))
    return out

def norm(n):
    n = re.sub(r"\.sh$", "", n.strip())
    return re.sub(r"_(org\.apache\.iotdb\.[A-Za-z0-9_.]+|IoTConsensusV2|IoTConsensus)$", "", n)

rows = []
for s in skills:
    d = os.path.join(A, s)
    tsv = os.path.join(d, "cases", "cases.tsv")
    entries = []  # (id, file, dialect, group, need_restart, notes)
    if os.path.exists(tsv):
        for line in open(tsv, errors="replace"):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = [c.strip() for c in line.split("\t")]
            filecol = next((c for c in cols if c.endswith(".sh") or c.startswith("cases/")), "")
            if not filecol:
                continue
            cid = cols[0]
            rest = [c for c in cols[1:] if c != filecol]
            dialect = next((c for c in rest if c in ("tree", "table", "both", "common")), "")
            group = next((c for c in rest if c in ("file/region", "path/region/file", "smoke", "official",
                                                   "scene", "param", "param2", "perf", "remove", "ttl",
                                                   "combo", "repair", "scale", "dtype", "ha", "regression",
                                                   "load", "write", "delete", "object", "tree", "table", "reuse")), "")
            need = next((c for c in rest if c in ("yes", "no", "reuse")), "")
            notes = cols[-1] if len(cols) > 2 else ""
            entries.append((cid, filecol, dialect, group, need, notes))
    else:
        for f in sorted(glob.glob(d + "/cases/**/*.sh", recursive=True)):
            base = os.path.basename(f)
            if base.startswith("_"):
                continue
            rel = os.path.relpath(f, d)
            title = ""
            try:
                for line in open(f, errors="replace").read().split("\n")[1:8]:
                    if line.startswith("#") and not line.startswith("# ===") and line.strip("# ").strip():
                        title = line.strip("# ").strip(); break
            except Exception:
                pass
            entries.append((base[:-3], rel, "", "", "", title))

    res = read_results(os.path.join(d, "results", "test_result.csv"))
    by_case = collections.defaultdict(list)
    for r in res:
        by_case[norm(r["case"])].append(r)

    for cid, filecol, dialect, group, need, notes in entries:
        key = norm(os.path.basename(filecol))
        mine = by_case.get(key, [])
        tgt = [r for r in mine if TARGET in r["build"]]
        last = mine[-1] if mine else None
        tgt_last = tgt[-1] if tgt else None
        rows.append(dict(
            skill=s, id=cid, file=filecol, dialect=dialect, group=group, need_restart=need,
            notes=(notes or "").replace("\t", " ")[:120],
            target_build=TARGET,
            target_result=(tgt_last["result"] + " " + tgt_last["elapsed"] + "s") if tgt_last else "未跑",
            last_build=(last["build"] if last else ""),
            last_result=(last["result"] + " " + last["elapsed"] + "s") if last else "",
        ))

# ---- TSV ----
out = os.path.join(A, "manifest", "skill_cases_manifest.tsv")
with open(out, "w", encoding="utf-8", newline="\n") as f:
    f.write("\t".join(["skill", "id", "file", "dialect", "group", "need_restart",
                       "notes", f"result_{TARGET}", "last_build", "last_result"]) + "\n")
    for r in rows:
        f.write("\t".join([r["skill"], r["id"], r["file"], r["dialect"], r["group"], r["need_restart"],
                           r["notes"], r["target_result"], r["last_build"], r["last_result"]]) + "\n")

# ---- Markdown ----
md = os.path.join(A, "manifest", "SKILL_CASES_MANIFEST.md")
per = collections.OrderedDict()
for r in rows:
    per.setdefault(r["skill"], []).append(r)
total = len(rows)
ran = sum(1 for r in rows if r["target_result"] != "未跑")
with open(md, "w", encoding="utf-8", newline="\n") as f:
    f.write("# 全部 skill 用例主清单\n\n")
    f.write(f"- 目标构建：**{TARGET}**\n")
    f.write(f"- 用例总数：**{total}**；该构建有结果：**{ran}**；未跑：**{total - ran}**\n")
    f.write(f"- 机器可读清单：`manifest/skill_cases_manifest.tsv`\n")
    f.write(f"- 覆盖率检查：`bash tools/check_case_coverage.sh {TARGET}`（有未跑则退出码 2）\n\n")
    f.write("| skill | 用例数 | 该构建已跑 | 未跑 |\n| --- | --- | --- | --- |\n")
    for s, rs in per.items():
        n = len(rs); k = sum(1 for r in rs if r["target_result"] != "未跑")
        f.write(f"| {s} | {n} | {k} | {n-k} |\n")
    f.write(f"| **合计** | **{total}** | **{ran}** | **{total-ran}** |\n\n")
    for s, rs in per.items():
        f.write(f"## {s}（{len(rs)} 条）\n\n")
        f.write("| 编号 | 用例文件 | 方言 | 分组 | 需重启 | 说明 | 该构建结果 | 最近构建 |\n")
        f.write("| --- | --- | --- | --- | --- | --- | --- | --- |\n")
        for r in rs:
            note = r["notes"].replace("|", "/")[:70]
            f.write(f"| {r['id']} | {r['file']} | {r['dialect']} | {r['group']} | {r['need_restart']} "
                    f"| {note} | {r['target_result']} | {r['last_build']} |\n")
        f.write("\n")
print(f"已生成：\n  {out}\n  {md}\n  用例总数={total}，{TARGET} 已跑={ran}，未跑={total-ran}")
PY
