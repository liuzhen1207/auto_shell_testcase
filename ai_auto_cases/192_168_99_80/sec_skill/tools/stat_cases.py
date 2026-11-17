import csv, os, collections

p = "/data/iotdb/autotest/sec_skill/results/test_result.csv"
rows = []
if os.path.exists(p):
    with open(p, encoding="utf-8", errors="ignore") as f:
        rows = list(csv.DictReader(f))

latest = {}
for r in rows:
    case = (r.get("caseName") or "").strip()
    mode = (r.get("mode") or "").strip()
    if not case or not mode:
        continue
    latest[(case, mode)] = r

cases = sorted({c for c, m in latest})
print(f"CSV 记录总数: {len(rows)}")
print(f"用例数（去重）: {len(cases)}")
print()
print(f"{'用例':<8}{'normal':<30}{'sep':<30}")
for c in cases:
    a = latest.get((c, "normal"))
    b = latest.get((c, "sep"))
    fa = f"{a['result']} {a['elapsedSeconds']}s fail={a['failCount']}" if a else "— 未跑 —"
    fb = f"{b['result']} {b['elapsedSeconds']}s fail={b['failCount']}" if b else "— 未跑 —"
    print(f"{c:<8}{fa:<30}{fb:<30}")

both = sum(1 for c in cases if (c, "normal") in latest and (c, "sep") in latest)
only_n = [c for c in cases if (c, "normal") in latest and (c, "sep") not in latest]
only_s = [c for c in cases if (c, "sep") in latest and (c, "normal") not in latest]
print()
print(f"两模式都跑过: {both}/{len(cases)}")
print(f"仅 normal: {only_n or '无'}")
print(f"仅 sep   : {only_s or '无'}")
print()
print("== 各模式最新一轮 PASS/FAIL 汇总 ==")
for mode in ("normal", "sep"):
    res = [latest[(c, mode)]["result"] for c in cases if (c, mode) in latest]
    print(f"  {mode}: {len(res)} 条  PASS={res.count('PASS')}  FAIL={res.count('FAIL')}")
