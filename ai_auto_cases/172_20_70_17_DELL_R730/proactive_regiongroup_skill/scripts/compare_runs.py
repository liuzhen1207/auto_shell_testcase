#!/usr/bin/env python3
"""对比两次全量轮的逐例结论。

用法：
    python3 scripts/compare_runs.py <新 run 目录> [旧 run 目录 ...]

行为：
* 每个 run 目录读取 `cases/<ID>/result.json` 的 `status` / `checks`；
* 旧轮若是分段跑的（如 pg_full_iot_final + pg_iot_resume），可传多个目录，按顺序合并
  （后面的目录覆盖同名用例）；
* 输出：状态计数表、逐例状态迁移、仍失败的用例及其首个失败 check 明细。

只读脚本，不修改任何结果。
"""
from __future__ import annotations

import collections
import json
import pathlib
import sys

STATUSES = ["PASS", "FAIL", "SKIP", "INVALID"]


def load(run_dir: pathlib.Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    cases = run_dir / "cases"
    if not cases.is_dir():
        print(f"  ! {run_dir} 没有 cases/ 目录", file=sys.stderr)
        return out
    for f in sorted(cases.glob("*/result.json")):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            print(f"  ! 读不了 {f}: {e}", file=sys.stderr)
            continue
        out[d.get("case_id") or f.parent.name] = d
    return out


def counts(cases: dict[str, dict]) -> dict[str, int]:
    c = collections.Counter(d.get("status") for d in cases.values())
    return {s: c.get(s, 0) for s in STATUSES}


def first_fail(d: dict) -> str:
    for chk in d.get("checks") or []:
        if not chk.get("ok"):
            return f"{chk.get('name', '')[:70]} | {str(chk.get('detail', ''))[:90]}"
    return d.get("error") or ""


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    new_dir = pathlib.Path(argv[1])
    old_dirs = [pathlib.Path(p) for p in argv[2:]]

    new = load(new_dir)
    old: dict[str, dict] = {}
    for d in old_dirs:
        old.update(load(d))

    if not new:
        print(f"{new_dir} 里没有可用结果")
        return 1

    cn, co = counts(new), counts(old)
    total = sum(cn.values())
    print(f"新轮 {new_dir}: 共 {total} 例")
    header = "状态" + "".join(f"{s:>9}" for s in STATUSES) + f"{'通过率':>10}"
    print(header)
    for label, c, n in (("新轮", cn, total), ("旧轮", co, sum(co.values()) or 1)):
        rate = f"{c['PASS'] / n * 100:.1f}%"
        print(f"{label}" + "".join(f"{c[s]:>9}" for s in STATUSES) + f"{rate:>10}")

    if old:
        print("\n状态迁移（仅列出变化的用例）")
        changed = 0
        for cid in sorted(new):
            a = (old.get(cid) or {}).get("status")
            b = new[cid].get("status")
            if a and a != b:
                changed += 1
                print(f"  {cid:<12} {a:>6} -> {b:<6} {new[cid].get('title', '')[:46]}")
        print(f"  共 {changed} 例状态变化")

    bad = [cid for cid in sorted(new) if new[cid].get("status") == "FAIL"]
    if bad:
        print(f"\n新轮 FAIL {len(bad)} 例：")
        for cid in bad:
            print(f"  {cid:<12} {new[cid].get('title', '')[:44]} | {first_fail(new[cid])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
