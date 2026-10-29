#!/usr/bin/env python3
"""Name the exact (device, time) behind a replica-count difference, and its direction.

Reads the per-stage inventories written by `sentinel_times.py`
(`<run-dir>/sentinel/<stage>__<model>.times`, one line per device:
`device<TAB>count<TAB>t1,t2,...`) and compares every stop stage against the all-online
baseline.

The direction matters and counts cannot show it:

  * a timestamp present only in the baseline  -> the survivor lost that row;
  * a timestamp present only in a stop stage  -> the stopped node holds an extra row
                                                (duplicate, or snapshot/stream overlap).

Usage:  python3 diff_stage_times.py <run-dir> [--model table|table_view]
"""
from __future__ import annotations

import argparse
import pathlib
import sys


def load(path: pathlib.Path) -> dict[str, set[str]] | None:
    """Per-device stamps, or None when the capture is unusable.

    An empty capture means the query failed (the stage stopped the node the client
    was talking to, or the CLI errored) -- NOT that every row is missing.  Reporting
    it as a diff turned one failed capture into "DIFFERS on 101 device(s)" on
    2026-09-30, so an empty file is skipped instead.
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    if "# CAPTURE-EMPTY" in text:
        return None
    data: dict[str, set[str]] = {}
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        device, _count, stamps = parts[0], parts[1], parts[2]
        data[device] = {s for s in stamps.split(",") if s}
    # No devices at all means the capture never produced a table (connection error):
    # before this check, such files were compared as "baseline has everything, stage
    # has nothing" and printed DIFFERS on every device.
    return data or None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=pathlib.Path)
    parser.add_argument("--model", default=None)
    args = parser.parse_args()

    sentinel = args.run_dir / "sentinel"
    if not sentinel.is_dir():
        print(f"  no sentinel directory under {args.run_dir}")
        return 1

    # Files are `<case>__<stage>__<model>.times`; only compare within one case,
    # because every case sweeps the same stop_* stages and a cross-case comparison
    # would report a diff between two different datasets.
    parsed: dict[tuple[str, str], dict[str, pathlib.Path]] = {}
    for path in sorted(sentinel.glob("*__*.times")):
        parts = path.name[: -len(".times")].split("__")
        if len(parts) != 3:
            continue
        case, model, _stage = parts[0], parts[2], parts[1]
        if args.model and model != args.model:
            continue
        parsed.setdefault((case, model), {})[parts[1]] = path

    for (case, model), stages in sorted(parsed.items()):
        baseline = stages.get("baseline")
        if baseline is None:
            print(f"\n=== case={case} model={model}: no baseline capture; cannot compare")
            continue
        base = load(baseline)
        if base is None:
            print(f"\n=== case={case} model={model}: baseline capture is EMPTY (query failed); skipping")
            continue
        print(f"\n=== case={case}  model={model}  baseline rows={sum(len(v) for v in base.values())} "
              f"devices={len(base)}")
        for stage, path in sorted(stages.items()):
            if stage in ("baseline", "settle1_a", "settle1_b") or stage.startswith("settle"):
                continue
            other = load(path)
            if other is None:
                print(f"  {stage:<24} capture EMPTY (query failed / node down) -- skipped")
                continue
            lost, extra, devices = [], [], []
            for device in sorted(set(base) | set(other)):
                left, right = base.get(device, set()), other.get(device, set())
                if left == right:
                    continue
                devices.append(device)
                lost.extend((device, stamp) for stamp in sorted(left - right))
                extra.extend((device, stamp) for stamp in sorted(right - left))
            verdict = "same" if not devices else f"DIFFERS on {len(devices)} device(s)"
            print(f"  {stage:<24} rows={sum(len(v) for v in other.values()):<7} {verdict}")
            for device, stamp in lost:
                print(f"      MISSING on the surviving replica: {device} @ {stamp}")
            for device, stamp in extra:
                print(f"      EXTRA on the stopped replica   : {device} @ {stamp}")
    if not parsed:
        print("  no per-stage captures found (sentinel must run while the cases do)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
