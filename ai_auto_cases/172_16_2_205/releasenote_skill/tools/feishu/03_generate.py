import json, os, re

base = r"D:\IDEA\deepseek\cloud1_ip205"
repo = r"D:\IDEA\deepseek\_repo_auto_shell_testcase\ai_auto_cases\172_16_2_205\releasenote_skill"
outdir = os.path.join(repo, "cases")
rows = json.load(open(os.path.join(base, "candidates.json"), encoding="utf-8"))

MANUAL = set("""
0684 0686 0683 0698 0679 0687 0670 0699 0744 0423 0779 0734 0711 0715 0295 0732 0365 0648 0616 0635
""".split())

def balance(s):
    return s.count("(") - s.count(")")

def quote_open(s):
    return s.count("'") % 2 == 1 or s.count('"') % 2 == 1

def rebuild(text):
    """把被换行截断的 SQL 拼回完整语句"""
    lines = [l.rstrip() for l in text.splitlines()]
    start = end = None
    for i, l in enumerate(lines):
        if re.search(r"复现步骤|复现过程|操作步骤", l) and start is None:
            start = i
        if start is not None and re.search(r"研发侧|问题原因|解决方案|影响分析|复测结果", l):
            end = i
            break
    if start is None: start = 0
    if end is None: end = len(lines)
    seg = lines[start:end]

    SQL_HEAD = re.compile(r"^(create|insert|select|alter|drop|set|show|delete|flush|grant|revoke|list|desc|explain|count)\b", re.I)
    stmts, buf = [], ""
    for raw in seg:
        s = raw.strip()
        s = re.sub(r"^(IoTDB>|iotdb>|>)\s*", "", s)
        s = re.sub(r"^\[[^\]]*\]\s*", "", s)
        s = re.sub(r"^--.*", "", s).strip()
        if not s or s.startswith("```") or re.search(r"\$\{|\bimg\b|\.png|\.jpg|http", s, re.I):
            continue
        if buf:
            buf += " " + s
        elif SQL_HEAD.match(s):
            buf = s
        else:
            continue
        # 判断是否结束
        if buf.endswith(";") or (balance(buf) <= 0 and not quote_open(buf)):
            for part in buf.split(";"):
                part = part.strip()
                if part and SQL_HEAD.match(part) and len(part) > 7:
                    stmts.append(part)
            buf = ""
    if buf:
        for part in buf.split(";"):
            part = part.strip()
            if part and SQL_HEAD.match(part) and len(part) > 7:
                stmts.append(part)
    # 去重
    seen, out = set(), []
    for s in stmts:
        k = s.lower()
        if k not in seen:
            seen.add(k); out.append(s)
    return out

def dialect_of(sqls):
    j = "\n".join(sqls)
    if re.search(r"\broot\.[a-zA-Z0-9_]+\.[a-zA-Z0-9_]", j, re.I):
        return "T"
    if re.search(r"create\s+table\s+\w+\s*\(", j, re.I):
        return "Q"
    return "T"

def q(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")

made = []
for r in rows:
    num = r.get("num")
    if not num or num in MANUAL:
        continue
    did = f"TIMECHODB-{num}"
    # 用原始文档重新拼接
    txt = open(os.path.join(base, "feishu_docs", f"{num}.md"), encoding="utf-8", errors="ignore").read()
    stmts = rebuild(txt)
    # 去掉裸 use / flush；去掉明显跨库依赖
    stmts = [s for s in stmts if not re.match(r"(?i)^use\b", s)]
    if not stmts:
        continue
    d = dialect_of(stmts)
    title = r["title"].replace(did, "").strip("【】 []").strip()
    short = title[:58].replace("|", "/")
    fn = os.path.join(outdir, f"TIMECHODB_{num}_v2.0.13.1.sh")

    L = []
    L.append("#!/bin/bash")
    L.append("# ============================================================================")
    L.append(f"# 来源缺陷单：{did}")
    L.append(f"#   {r['title'][:110]}")
    L.append("#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）")
    L.append("#   验证版本：2.0.13.1 / ab6d3de")
    L.append(f"#   预期摘要：{r['expect'][:110]}")
    L.append("# ============================================================================")
    L.append(f"RN{num}_SQL=(")
    for s in stmts:
        L.append(f'"{q(s)}"')
    L.append(")")
    L.append("")
    L.append(f"case_RN{num}() {{")
    L.append("  local st out unexpected=0")
    L.append(f"  for st in \"${{RN{num}_SQL[@]}}\"; do")
    L.append(f"    out=$( {d} \"$st\" )")
    L.append("    # 幂等：对象已存在视为可接受")
    L.append("    if echo \"$out\" | grep -qiE 'already exists|already been created'; then")
    L.append("      ok \"已存在(幂等): $(echo \"$st\" | cut -c1-55)\"; continue")
    L.append("    fi")
    L.append("    if echo \"$out\" | grep -qiE 'Exception|ERROR|internal error|NullPointerException'; then")
    L.append("      unexpected=$((unexpected+1))")
    L.append("      fail \"$(echo \"$st\" | cut -c1-65) -> $(echo \"$out\" | head -1 | cut -c1-110)\"")
    L.append("    else")
    L.append("      ok \"$(echo \"$st\" | cut -c1-55)\"")
    L.append("    fi")
    L.append("  done")
    L.append("}")
    L.append("")
    L.append("CASES+=(")
    L.append(f'"{did} 自动抽取|{did}|功能|{short}|case_RN{num}"')
    L.append(")")
    open(fn, "w", encoding="utf-8", newline="\n").write("\n".join(L) + "\n")
    made.append({"num": num, "fn": f"cases/TIMECHODB_{num}_v2.0.13.1.sh", "n": len(stmts), "dialect": d, "title": r["title"]})

print("重新生成:", len(made))
json.dump(made, open(os.path.join(base, "generated2.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
