#!/usr/bin/env python3
"""汇总 sec_skill 每条用例、每种模式的最新一次运行的全部断言，生成 Markdown。"""
import io, os, re, glob, time

RES = "/data/iotdb/autotest/sec_skill/results"
OUT = "/data/iotdb/autotest/sec_skill/docs/ASSERTIONS_20261117.md"

files = sorted(glob.glob(os.path.join(RES, "SEC-*.out")))
latest = {}   # (case, mode) -> (mtime, path)

for p in files:
    try:
        txt = io.open(p, encoding="utf-8", errors="ignore").read()
    except Exception:
        continue
    m = re.search(r"RESULT (PASS|FAIL) fail_flag=(\d+) case=(SEC-\d+)_(normal|sep)", txt)
    if not m:
        continue
    case, mode = m.group(3), m.group(4)
    mt = os.path.getmtime(p)
    if (case, mode) not in latest or mt > latest[(case, mode)][0]:
        latest[(case, mode)] = (mt, p, txt)

def parse(txt):
    """返回 [(kind, text)]；kind ∈ PASS/WARN/FAIL/RESULT。"""
    items = []
    for line in txt.splitlines():
        m = re.match(r"^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\] (PASS|WARN|FAIL) (.*)$", line)
        if m:
            items.append((m.group(1), m.group(2).strip()))
            continue
        m = re.match(r"^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\] RESULT (PASS|FAIL) fail_flag=(\d+) .*?elapsed=(\d+)s passes=(\d+) warns=(\d+)", line)
        if m:
            items.append(("RESULT", f"{m.group(1)} fail_flag={m.group(2)} elapsed={m.group(3)}s passes={m.group(4)} warns={m.group(5)}"))
    return items

cases = sorted({c for c, _ in latest}, key=lambda s: int(s.split("-")[1]))
lines = []
lines.append("# sec_skill 断言清单（16 条 × 双模式，最新一轮）")
lines.append("")
lines.append("> 生成时间：%s；数据源：`results/SEC-*.out`（每个 (用例,模式) 取 mtime 最新的一份）。" % time.strftime("%Y-%m-%d %H:%M:%S"))
lines.append("> 断言前缀含义：`PASS` 通过 / `WARN` 记录性提示（不判失败） / `FAIL` 失败。")
lines.append("")

# 汇总表
lines.append("## 一、汇总")
lines.append("")
lines.append("| 用例 | 模式 | 结果 | PASS 数 | WARN 数 | FAIL 数 | 耗时 |")
lines.append("| --- | --- | --- | --- | --- | --- | --- |")
for c in cases:
    for mode in ("normal", "sep"):
        if (c, mode) not in latest:
            continue
        items = parse(latest[(c, mode)][2])
        res = next((t for k, t in items if k == "RESULT"), "")
        pn = sum(1 for k, _ in items if k == "PASS")
        wn = sum(1 for k, _ in items if k == "WARN")
        fn = sum(1 for k, _ in items if k == "FAIL")
        m = re.search(r"elapsed=(\d+s)", res)
        lines.append(f"| {c} | {mode} | {res.split()[0] if res else '?'} | {pn} | {wn} | {fn} | {m.group(1) if m else '-'} |")
lines.append("")

# 明细
lines.append("## 二、逐条断言")
lines.append("")
for c in cases:
    for mode in ("normal", "sep"):
        if (c, mode) not in latest:
            continue
        items = parse(latest[(c, mode)][2])
        res = next((t for k, t in items if k == "RESULT"), "")
        lines.append(f"### {c} · {mode}")
        lines.append("")
        lines.append(f"`{res}`")
        lines.append("")
        for k, t in items:
            if k == "RESULT":
                continue
            mark = {"PASS": "✅", "WARN": "⚠️", "FAIL": "❌"}[k]
            # 简化长文本
            t = re.sub(r"\s+", " ", t)
            if len(t) > 300:
                t = t[:300] + "…"
            lines.append(f"- {mark} {t}")
        lines.append("")

io.open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
print("written:", OUT, len("\n".join(lines)), "chars,", len(lines), "lines")
