import json, os, re, sys

base = os.path.dirname(os.path.abspath(__file__))
idx = json.load(open(os.path.join(base, "feishu_index.json"), encoding="utf-8-sig"))
docdir = os.path.join(base, "feishu_docs")

SKIP_TITLE = re.compile(
    r"pipe|Pipe|同步|接收端|发送端|双活|订阅|Workbench|气象局|缩容|扩容|[Rr]egion|迁移|集群|压测|并发读写|"
    r"监控|面板|仪表|load|LOAD|SSL|ssl|加密|WAL|AINode|UDF|function|审计|三权分立|安全包|mqtt|MQTT|"
    r"\.bat|重启|升级|磁盘满|OOM|内存泄露|泄漏|性能|耗时|benchmark|bm|黑名单|模板|template|"
    r"配额|license|激活|卸载|安装|部署|用户手册|需求|建议|优化日志|日志优化"
)

SQL_RE = re.compile(r"^\s*(create|insert|select|alter|drop|set|show|delete|flush|use|grant|revoke|list|count|desc|explain)\b", re.I)

def extract_sql(text):
    """从"复现步骤"到"研发侧/问题原因"之间提取 SQL 语句"""
    lines = [l.rstrip() for l in text.splitlines()]
    start = end = None
    for i, l in enumerate(lines):
        if re.search(r"复现步骤|复现过程|操作步骤", l) and start is None:
            start = i
        if start is not None and re.search(r"研发侧|问题原因|解决方案|影响分析|复测结果", l):
            end = i
            break
    if start is None:
        start = 0
    if end is None:
        end = len(lines)
    seg = lines[start:end]
    stmts = []
    for l in seg:
        s = l.strip()
        s = re.sub(r"^(IoTDB>|iotdb>|>)\s*", "", s)
        s = re.sub(r"^\[[^\]]*\]\s*", "", s)
        s = re.sub(r"^--.*", "", s)
        s = re.sub(r"^#.*", "", s)
        if not s:
            continue
        if s.startswith("```"):
            continue
        if not SQL_RE.match(s):
            continue
        s = s.rstrip(";").strip()
        if len(s) < 8:
            continue
        # 跳过明显非 SQL 的
        if re.search(r"\$\{|\bimg\b|\.png|\.jpg|http", s, re.I):
            continue
        stmts.append(s)
    # 去重保序
    seen, out = set(), []
    for s in stmts:
        k = s.lower()
        if k in seen:
            continue
        seen.add(k)
        out.append(s)
    return out

rows = []
for it in idx:
    if not it.get("file"):
        continue
    p = os.path.join(docdir, it["file"])
    txt = open(p, encoding="utf-8", errors="ignore").read()
    title = it["name"]
    if SKIP_TITLE.search(title):
        continue
    sql = extract_sql(txt)
    if not sql:
        continue
    # 至少要有 create/insert/alter/select 这类可执行语句
    rows.append({
        "num": it["num"], "title": title, "file": it["file"],
        "n_sql": len(sql),
        "has_ddl": any(re.match(r"(?i)^(create|alter|drop)", s) for s in sql),
        "has_dml": any(re.match(r"(?i)^(insert|select|delete)", s) for s in sql),
        "expect": (re.search(r"预期结果[：:]?\s*\n?(.{0,200})", txt, re.S) or [None, ""])[1].strip().replace("\n", " ")[:160],
        "sql": sql,
    })

with open(os.path.join(base, "candidates.json"), "w", encoding="utf-8") as f:
    json.dump(rows, f, ensure_ascii=False, indent=1)

print("候选数:", len(rows))
print("有 DDL+DML 的:", sum(1 for r in rows if r["has_ddl"] and r["has_dml"]))
print("仅 DDL:", sum(1 for r in rows if r["has_ddl"] and not r["has_dml"]))
print("\n=== 前 8 个样本 ===")
for r in rows[:8]:
    print(f"\n[{r['num']}] {r['title'][:70]}")
    for s in r["sql"][:6]:
        print("   SQL:", s[:110])
    print("   预期:", r["expect"][:90])
