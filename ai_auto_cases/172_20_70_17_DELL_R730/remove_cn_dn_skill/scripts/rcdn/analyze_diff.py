"""Read a finished case's artifacts and say *why* replicas disagreed.

A consistency sweep that ends in `replica inconsistency: '<q>' result differs
while <host> is down` only says that replicas disagreed.  Naming the cause means
combining four things that are already on disk after such a run:

1. **the direction** of the disagreement -- the baseline vs each stopped-node
   capture.  A row count that goes *down* when a node is stopped and *up* in
   another capture is two replicas holding different rows; the direction alone
   never says which one is wrong.
2. **which node's view is short** -- from the forensic capture, which re-ran the
   disagreeing query through every node that was still up.
3. **the file-level difference** -- the per-replica TsFile inventory, which shows
   a file that some replicas hold and others never received.  That is the
   signature of a migration snapshot that silently skipped a TsFile, and it is
   invisible to any query.
4. **what was migrating, and what restarted** -- the region create/snapshot/
   snapshot-load events and the restart windows in the DataNode logs, plus
   whether a TsFile entered closing before a snapshot started and finished
   flushing after it completed (the one timing window that can drop a file).

This runs entirely offline against a run directory: no cluster, no ssh.  It
prints evidence, not a verdict -- several of these signals are ambiguous on
their own, and the point is to put them side by side.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from .verify import compare_replica_inventories

TSFILE_RE = re.compile(r"/([0-9]+-[0-9]+-[0-9]+-[0-9]+\.tsfile)")
REGION_PATH_RE = re.compile(r"(?:sequence|unsequence)/([A-Za-z._0-9]+)/(\d+)/\d+")
LOG_LINE_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d+) .*?(\S+):(\d+) - (.*)$")


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


# ----------------------------------------------------------------------
# 1. the direction of the disagreement
# ----------------------------------------------------------------------
def report_direction(artifacts: Path) -> list[str]:
    out: list[str] = []
    base_files = sorted(artifacts.glob("baseline_*.norm"))
    if not base_files:
        return ["no baseline_*.norm captured -- nothing to compare against"]
    for base_file in base_files:
        query = base_file.stem[len("baseline_") :]
        base_lines = _read(base_file).splitlines()
        base_map = {}
        for line in base_lines:
            base_map[line.split("|", 1)[0]] = line
        for stop in sorted(artifacts.glob(f"stop_*_{query}.norm")):
            host = stop.stem[len("stop_") : -len(f"_{query}")].replace("_", ".")
            got_lines = _read(stop).splitlines()
            got_map = {}
            for line in got_lines:
                got_map[line.split("|", 1)[0]] = line
            keys = sorted(set(base_map) | set(got_map))
            diffs = [k for k in keys if base_map.get(k) != got_map.get(k)]
            if not diffs:
                out.append(f"  {query} while {host} is down: identical")
                continue
            out.append(f"  {query} while {host} is down: {len(diffs)} differing key(s)")
            for k in diffs[:5]:
                b, g = base_map.get(k), got_map.get(k)
                if b is None:
                    note = "only in this capture"
                elif g is None:
                    note = "missing from this capture"
                else:
                    bv = b.split("|")[1:]
                    gv = g.split("|")[1:]
                    lower = sum(1 for x, y in zip(bv, gv) if _num(y) < _num(x))
                    higher = sum(1 for x, y in zip(bv, gv) if _num(y) > _num(x))
                    note = f"{higher} column(s) higher, {lower} lower than the baseline"
                out.append(f"      {k}: baseline={b!r}")
                out.append(f"      {' ' * len(k)}  observed={g!r}  ({note})")
    return out


def _num(text: str) -> float:
    try:
        return float(text)
    except ValueError:
        return float("nan")


# ----------------------------------------------------------------------
# 2/3. the forensic capture
# ----------------------------------------------------------------------
def report_forensics(artifacts: Path) -> list[str]:
    out: list[str] = []
    reports = sorted(artifacts.glob("forensic_*_missing_files.txt"))
    if not reports:
        out.append("  no forensic capture present (an older run, or the diff was not "
                   "detected by the instrumented code)")
        return out
    for report in reports:
        text = _read(report)
        out.append(f"  --- {report.name}")
        for line in text.splitlines():
            stripped = line.strip()
            if (
                stripped.startswith("via ")
                or stripped.startswith("DataNodes:")
                or stripped.startswith("object (.bin)")
                or stripped.startswith("none:")
                or stripped.startswith("present on:")
                or stripped.startswith("MISSING on:")
            ):
                out.append(f"      {stripped}")
            elif stripped.endswith((".tsfile", ".resource")):
                out.append(f"      CANDIDATE {stripped}")
    return out


def _per_host_inventories(artifacts: Path):
    """Yield (source, {host: {path: {file}}}) for every captured inventory."""
    for tsv in sorted(artifacts.glob("forensic_*_files.tsv")):
        per_host: dict[str, dict[str, set[str]]] = {}
        for line in _read(tsv).splitlines():
            parts = line.split("\t")
            if len(parts) != 3:
                continue
            host, path, name = parts
            if name.endswith(".tsfile") or name.endswith(".resource"):
                per_host.setdefault(host, {}).setdefault(path, set()).add(name)
        if len(per_host) >= 2:
            yield tsv, per_host


def report_missing_files(artifacts: Path) -> list[str]:
    """Which TsFiles do some replicas hold and others lack?

    Uses the same comparison as the capture itself, so this reading and the one
    baked into the artifact can never disagree.
    """
    out: list[str] = []
    found = False
    for tsv, per_host in _per_host_inventories(artifacts):
        out.append(f"  --- {tsv.name}: {len(per_host)} replica(s)")
        for path, name, holders, absent in compare_replica_inventories(per_host):
            found = True
            out.append(
                f"      {path}: {name}\n"
                f"          present on: {', '.join(holders)}   MISSING on: {', '.join(absent)}"
            )
    if not found:
        out = ["  no TsFile/.resource differs between replicas -- a snapshot omission is "
               "therefore NOT what diverged them"]
    return out


def report_when_missing_files_were_created(
    artifacts: Path, log_backup: Path | None
) -> list[str]:
    """Tell an omitted snapshot member apart from writes that arrived too late.

    Both leave the same shallow signature: a .tsfile some replicas hold and
    another does not.  A TsFile's name starts with the millisecond timestamp of
    its first write, and the logs carry each region's snapshot completion time,
    so the two can be separated:

    * created **after** its region's snapshot -> it was not a member of that
      snapshot at all; the replica is missing post-snapshot data;
    * created **before** it -> it could have been a member that `createSnapshot`
      skipped, which is TDB-406.
    """
    if log_backup is None:
        return ["  no log backup, so file creation times cannot be matched to snapshots"]

    snap_done: dict[str, list[str]] = {}
    for host_dir in sorted(log_backup.glob("dn_*")):
        log = host_dir / "log_datanode_all.log"
        if not log.exists():
            continue
        for line in _read(log).splitlines():
            m = LOG_LINE_RE.match(line)
            if not m:
                continue
            ts, _cls, _ln, msg = m.groups()
            if "Successfully take snapshot for" in msg:
                rm = re.search(r"for ([A-Za-z._0-9]+)-(\d+)", msg)
                if rm:
                    snap_done.setdefault(f"{rm.group(1)}/{rm.group(2)}", []).append(ts)

    out: list[str] = []
    found = False
    for _tsv, per_host in _per_host_inventories(artifacts):
        for path, name, _holders, absent in compare_replica_inventories(per_host):
            found = True
            made = _tsfile_time(name)
            region = "/".join(path.split("/")[-3:-1])
            snaps = snap_done.get(region, [])
            if made is None or not snaps:
                out.append(
                    f"  {path}/{name}: missing on {', '.join(absent)} (no creation time "
                    f"or no snapshot on record for {region} to compare against)"
                )
                continue
            out.append(
                f"  {path}/{name}: missing on {', '.join(absent)}; created {made}; "
                f"snapshot(s) of {region} completed {', '.join(snaps)}"
            )
            if [t for t in snaps if made > t]:
                out.append(
                    "      -> created AFTER its region's snapshot, so it was never a member "
                    "of it: this replica is missing post-snapshot writes (tail loss)"
                )
            else:
                out.append(
                    "      -> created BEFORE its region's snapshot, so it could have been a "
                    "member that createSnapshot skipped (TDB-406 consistent)"
                )
    if not found:
        out = ["  nothing to compare: no per-replica file difference was captured"]
    return out


def _tsfile_time(name: str) -> str | None:
    """A TsFile is named `<firstWriteMillis>-<version>-<...>.tsfile`."""
    import datetime

    m = re.match(r"(\d{10,})", name)
    if not m:
        return None
    try:
        return datetime.datetime.fromtimestamp(int(m.group(1)) / 1000).strftime(
            "%Y-%m-%d %H:%M:%S"
        )
    except (OverflowError, OSError, ValueError):
        return None


# ----------------------------------------------------------------------
def materialize(log_backup: Path) -> Path:
    """The backed-up node logs are usually per-node `.tar.gz` archives.

    Extract them once into a temporary directory so the log readers can treat
    the result as a plain tree of `dn_<host>/log_datanode_*.log`.  An already
    extracted tree is returned unchanged.
    """
    if any(log_backup.glob("dn_*/log_datanode_all.log")):
        return log_backup
    archives = sorted(log_backup.glob("*.tar.gz"))
    if not archives:
        return log_backup
    import tarfile
    import tempfile

    dest = Path(tempfile.mkdtemp(prefix="rcdn_diff_"))
    for archive in archives:
        try:
            with tarfile.open(archive) as tar:
                tar.extractall(dest)  # noqa: S202  (our own backup archives)
        except (tarfile.TarError, OSError):
            continue
    return dest


def report_migration(log_backup: Path) -> list[str]:
    out: list[str] = []
    if not log_backup.is_dir():
        return [f"  no log backup at {log_backup}"]
    for host_dir in sorted(log_backup.glob("dn_*")):
        host = host_dir.name[len("dn_") :]
        log = host_dir / "log_datanode_all.log"
        if not log.exists():
            continue
        targets: list[str] = []
        sources: list[str] = []
        loads: list[str] = []
        restarts: list[str] = []
        for line in _read(log).splitlines():
            m = LOG_LINE_RE.match(line)
            if not m:
                continue
            ts, _cls, _ln, msg = m.groups()
            if "create new region DataRegion" in msg or "succeed to create new region" in msg:
                rm = re.search(r"(DataRegion\[\d+\])", msg)
                targets.append(f"{ts} {rm.group(1) if rm else '?'} (target)")
            elif "Start to transmit snapshots" in msg:
                nf = re.search(r"\((\d+) files", msg)
                sources.append(f"{ts} {nf.group(1) if nf else '?'} files (source)")
            elif "Loading snapshot for" in msg:
                rm = re.search(r"for ([A-Za-z._0-9]+)-(\d+)", msg)
                loads.append(f"{ts} {rm.group(0)[4:] if rm else '?'}")
            elif "Shutdown-Hook" in msg or "Start to read config file" in msg:
                restarts.append(ts)
        out.append(f"  --- {host}")
        for label, rows in (("snapshot source", sources), ("migration target", targets),
                            ("snapshot loaded", loads)):
            if rows:
                out.append(f"      {label}:")
                out.extend(f"        {r}" for r in rows)
        if restarts:
            out.append(f"      restart/shutdown markers: {', '.join(restarts[:4])}")
    return out


def report_snapshot_closing(log_backup: Path) -> list[str]:
    """The TDB-406 window: a file already closing when a snapshot started.

    A file that the *snapshot itself* closes is awaited and included, so the
    interesting case is a file that entered closing BEFORE the snapshot started
    and finished flushing AFTER the snapshot completed.  That is the only
    ordering in which `createSnapshot` observes `isClosed() == false` and skips
    the file while reporting success.
    """
    out: list[str] = []
    if not log_backup.is_dir():
        return out
    for host_dir in sorted(log_backup.glob("dn_*")):
        host = host_dir.name[len("dn_") :]
        log = host_dir / "log_datanode_all.log"
        if not log.exists():
            continue
        closes: list[tuple[str, str, str]] = []
        flushed: dict[str, str] = {}
        snap_start: list[tuple[str, str]] = []
        snap_done: list[tuple[str, str]] = []
        for line in _read(log).splitlines():
            m = LOG_LINE_RE.match(line)
            if not m:
                continue
            ts, _cls, _ln, msg = m.groups()
            if "Async close tsfile" in msg:
                fm, rm = TSFILE_RE.search(msg), REGION_PATH_RE.search(msg)
                if fm and rm:
                    closes.append((ts, fm.group(1), f"{rm.group(1)}/{rm.group(2)}"))
            elif "compression ratio" in msg:
                fm = TSFILE_RE.search(msg)
                if fm:
                    flushed[fm.group(1)] = ts
            elif "start to take snapshot" in msg:
                snap_start.append((ts, ""))
            elif "Successfully take snapshot for" in msg:
                rm = re.search(r"for ([A-Za-z._0-9]+)-(\d+)", msg)
                if rm:
                    snap_done.append((ts, f"{rm.group(1)}/{rm.group(2)}"))
        hits = []
        for ts_close, name, region in closes:
            ts_flush = flushed.get(name)
            if not ts_flush:
                continue
            for ts_done, done_region in snap_done:
                if done_region != region:
                    continue
                # The condition is simply: the file was still mid-close when the
                # snapshot completed.  A file the snapshot itself closed is
                # awaited by syncCloseAllWorkingTsFileProcessors and finishes
                # before the snapshot completes, so it never matches; only a
                # close that came from somewhere else and was not awaited does.
                if ts_close < ts_done and ts_flush > ts_done:
                    hits.append((region, name, ts_close, ts_flush, ts_done))
        out.append(f"  --- {host}")
        if hits:
            for region, name, ts_close, ts_flush, ts_done in hits:
                out.append(
                    f"      TDB-406 WINDOW: region {region} file {name} entered closing at "
                    f"{ts_close}, flushed at {ts_flush}, snapshot completed at {ts_done}"
                )
        else:
            out.append("      no file was mid-close across a snapshot of its own region")
    return out


# ----------------------------------------------------------------------
def find_log_backup(run_dir: Path, case_id: str) -> Path | None:
    summary = run_dir / "summary.tsv"
    for line in _read(summary).splitlines():
        parts = line.split("\t")
        if len(parts) >= 5 and parts[0] == case_id and parts[4].startswith("/"):
            return Path(parts[4])
    backup_root = run_dir / "log_backup"
    if backup_root.is_dir():
        cands = sorted(backup_root.glob(f"{case_id}_*"))
        if cands:
            return cands[-1]
    return None


def run(run_dir: Path, case_id: str) -> int:
    artifacts = run_dir / "cases" / case_id
    print(f"### diff analysis: {case_id}")
    print(f"    artifacts : {artifacts}")
    if not artifacts.is_dir():
        print(f"    no artifacts directory -- nothing to analyze")
        return 2

    print("\n## 1. direction of the disagreement (baseline vs each stopped-node capture)")
    print("\n".join(report_direction(artifacts)))

    print("\n## 2. which node's view is short (forensic per-node re-run)")
    print("\n".join(report_forensics(artifacts)))

    print("\n## 3. files some replicas hold and others do not")
    print("\n".join(report_missing_files(artifacts)))

    log_backup = find_log_backup(run_dir, case_id)
    if log_backup is not None:
        log_backup = materialize(log_backup)
    print(f"\n## 4. migration events and restarts  (logs: {log_backup})")
    print("\n".join(report_migration(log_backup) if log_backup else ["  log backup not found"]))

    print("\n## 5. was any TsFile mid-close across a snapshot? (the TDB-406 window)")
    print("\n".join(report_snapshot_closing(log_backup) if log_backup else ["  log backup not found"]))

    print("\n## 6. when were the files that some replicas lack created?")
    print("\n".join(report_when_missing_files_were_created(artifacts, log_backup)))

    print("\n## reading\n"
          "  * a CANDIDATE / MISSING file in section 3 with section 5 quiet -> the file was lost\n"
          "    some other way; check section 4 for a restarted replica that never caught up.\n"
          "  * a file MISSING on exactly one replica + a WINDOW hit in section 5 -> TDB-406.\n"
          "  * no differences in section 3 -> the replicas hold the same files, so the\n"
          "    divergence is not a snapshot omission at all; look at the restart and the\n"
          "    failed sync-log batches instead.")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: analyze_diff.py <run-dir> <case-id>", file=sys.stderr)
        print("   eg: analyze_diff.py rc3_run/results/run_20260922_161521 dn_remove_restart",
              file=sys.stderr)
        return 2
    return run(Path(argv[1]), argv[2])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
