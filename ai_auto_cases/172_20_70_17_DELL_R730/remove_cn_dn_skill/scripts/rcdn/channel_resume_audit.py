"""Audit IoTConsensus channels for silent resume gaps (no snapshot needed).

Why this exists
---------------
The receiver accepts a batch purely on ``request.getStartSyncIndex() == nextSyncIndex``
(IoTConsensusServerImpl, SyncLogCacheQueue) -- there is no leader term, no log epoch, and
no lower bound.  So when a DataRegion's consensus log is re-created during a
REMOVE DATANODE/leader change (the new log restarts at index 1) while a follower still
holds ``nextSyncIndex`` from the *old* log, the follower silently accepts a start that is
already past the new log's beginning and never applies ``[logStart, first)``.

Measured shape (run_20260923_143231, case dn_remove_restart#3, table database usr_sod0 =
DataRegion[6], diff detected as "'table_view' result differs while 11.101.10.6 is down"):

    .8 (node 1) -> .10 : startSyncIndex 1   .. 282     15:16:20 -> 15:16:25
    .8 (node 1) -> .6  : startSyncIndex 25  .. 282     15:16:27        <-- 1..24 never sent
    .6 (node 2) -> .8/.10 : startSyncIndex 1 .. 3      15:16:35        <-- new log, index 1 again
    row at 2026-09-23T15:16:25.301 exists on .8/.10 but not on .6

This tool re-derives that condition from the diagnostic build's logs:

  * leader side   ``build channel: region=..., initialSyncIndex=..., minSyncIndex=...``
                  ``snapshot taken: region=..., searchIndexAtSnapshot=..., minSyncIndex=...``
  * follower side ``receive baseline: region=..., source=..., incoming=[start, end]``

For every (region, follower, source) channel it takes the smallest index the leader ever
offered for that region (L) and the follower's first accepted index (F).  ``F > L`` means
the follower never applied ``[L, F)`` -- a silent hole of ``F - L`` entries, which neither
syncLag nor the case's own replica comparison is guaranteed to surface.

Usage::

    PYTHONPATH=scripts python3 -m rcdn.channel_resume_audit <run-dir-or-log-dir> [...]
    PYTHONPATH=scripts python3 -m rcdn.channel_resume_audit --raw DIR      # plain .log files
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys
import tarfile

BUILD = re.compile(
    r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}).*?build channel: region=(DataRegion\[\d+\]),"
    r".*?nodeId=(\d+)\)?,\s*initialSyncIndex=(-?\d+),\s*minSyncIndex=(-?\d+),\s*leaderSearchIndex=(-?\d+)"
)
SNAP = re.compile(
    r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}).*?snapshot taken: region=(DataRegion\[\d+\]),"
    r".*?searchIndexAtSnapshot=(-?\d+),\s*minSyncIndex=(-?\d+)"
)
BASELINE = re.compile(
    r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}).*?receive baseline: region=(DataRegion\[\d+\]),"
    r"\s*source=(\S+?),\s*incoming=\[(-?\d+),\s*(-?\d+)\]"
)


def _iter_texts(root: pathlib.Path, raw: bool):
    if raw:
        for f in sorted(root.rglob("*.log")):
            yield f.name, f.read_text(errors="replace")
        return
    for arc in sorted(root.rglob("*.tar.gz")):
        try:
            with tarfile.open(arc) as tf:
                for m in tf.getmembers():
                    if not m.isfile() or m.size > 600 * 1024 * 1024:
                        continue
                    fh = tf.extractfile(m)
                    if fh is not None:
                        yield m.name, fh.read().decode("utf-8", "replace")
        except (tarfile.TarError, OSError) as exc:  # noqa: BLE001
            print(f"  ! {arc.name}: {exc}", file=sys.stderr)


def audit(root: pathlib.Path, raw: bool) -> tuple[list[str], int, int]:
    builds: dict[str, list[tuple[str, str, int, int]]] = collections.defaultdict(list)
    snaps: dict[str, list[tuple[str, int, int]]] = collections.defaultdict(list)
    firsts: dict[tuple[str, str, str], tuple[str, int, int]] = {}
    for name, text in _iter_texts(root, raw):
        host = re.search(r"(?:dn_)?((?:\d+_)+?\d+)", name)
        host = host.group(1).replace("_", ".") if host else name
        for ts, reg, node, init, minsync, _lead in BUILD.findall(text):
            builds[reg].append((ts, host, int(node), int(init), int(minsync)))
        for ts, reg, at, minsync in SNAP.findall(text):
            snaps[reg].append((ts, int(at), int(minsync)))
        for ts, reg, src, start, end in BASELINE.findall(text):
            key = (reg, host, src)
            cur = firsts.get(key)
            if cur is None or (ts, int(start)) < (cur[0], cur[1]):
                firsts[key] = (ts, int(start), int(end))

    findings: list[str] = []
    checked = 0
    regions = sorted(set(list(builds) + list(snaps) + [k[0] for k in firsts]),
                     key=lambda r: int(re.search(r"\d+", r).group()))
    for reg in regions:
        low = [m for *_x, m in [(b[0], b[1], b[3], b[4]) for b in builds[reg]]] + [m for _t, _a, m in snaps[reg]]
        low = [m for m in low if m >= 0]
        log_start = min(low) if low else None
        follower_firsts: dict[tuple[str, str], tuple[str, int, int]] = {}
        for (r, host, src), val in firsts.items():
            if r == reg:
                follower_firsts[(host, src)] = val
        if log_start is None or not follower_firsts:
            continue
        for (host, src), (ts, start, end) in sorted(follower_firsts.items()):
            checked += 1
            if start > log_start:
                findings.append(
                    f"{reg}: follower {host} (from source {src}) first accepted index {start} "
                    f"at {ts}, but the region's log starts at {log_start} -> never applied "
                    f"[{log_start}, {start - 1}] ({start - log_start} entries)"
                )
    return findings, checked, len(regions)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("roots", nargs="+", help="run dirs, log_backup dirs or (with --raw) log dirs")
    ap.add_argument("--raw", action="store_true", help="read plain .log/.txt files instead of tar.gz")
    args = ap.parse_args(argv)

    total = 0
    for root in args.roots:
        p = pathlib.Path(root)
        if not p.exists():
            print(f"  missing: {p}")
            continue
        findings, checked, nregions = audit(p, args.raw)
        total += len(findings)
        print(f"\n== {p}")
        print(f"   regions={nregions}  channels checked={checked}  gaps found={len(findings)}")
        for f in findings:
            print(f"   ★ {f}")
        if not findings:
            print("   无静默丢段：每个通道的首条索引都 <= 该 region 日志起点")
    print(f"\n合计发现的静默丢段: {total}")
    return 1 if total else 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
