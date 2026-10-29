"""Watch a run for a 305 hit and extract the *real* reason from the DataNode logs.

A `305 INTERNAL_SERVER_ERROR` with the text `no detailed failure reason in
QueryStateMachine` is what the client sees when `QueryExecution.retry()` exhausts
`MAX_RETRY_COUNT` (3): the last `transitionToQueued()` cleared both
`failureException` and `failureStatus`, and the exhaustion path calls the no-arg
`transitionToFailed()`, so nothing is recorded.  The real reason is the *first*
failure that triggered the retries -- normally a 306 `DISPATCH_ERROR` raised by
`FragmentInstanceDispatcherImpl.dispatchRemoteFailed()` when a FragmentInstance
cannot be sent to a DataNode endpoint.

This watcher polls `<run-dir>/cases/*/result.json`; as soon as a case reports a
305 it writes `<run-dir>/305_reports/<case>.md` holding, for that case:

  * the failing SQL and the problems list,
  * `[ReachMaxRetryCount]`, `[Retry] retry count is`, `[WaitBeforeRetry]`,
  * `can't execute request on node ...` (the swallowed dispatch failure),
  * `can't connect to node ...` (the 306 message prefix),

grouped per host, with the endpoint counts, so the target of the failed dispatch
is visible at a glance.

Usage:
    PYTHONPATH=scripts python3 -m rcdn.watch_305 <run-dir> [--interval 20]
"""

from __future__ import annotations

import collections
import json
import pathlib
import re
import sys
import tarfile
import time

KEYS = (
    "[ReachMaxRetryCount]",
    "[Retry] retry count is",
    "[WaitBeforeRetry]",
    "can't execute request on node",
    "can't connect to node",
    "ERROR_WHEN_EXECUTING_QUERY",
    "error when executing query",
    "DISPATCH_ERROR",
    "306",
)
LOG_SUFFIXES = (
    "log_datanode_all.log",
    "log_datanode_debug.log",
    "log_datanode_warn.log",
    "log_datanode_error.log",
)
RE_DISPATCH_TARGET = re.compile(r"can't execute request on node\s+(\S+?)\s+in second try")
RE_CANT_CONNECT = re.compile(r"can't connect to node (\S+)")


def _ts(line: str):
    m = re.match(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),(\d{3})", line)
    if not m:
        return None
    import datetime as _dt
    try:
        t = _dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    return t.timestamp() + int(m.group(2)) / 1000.0


def scan_case(case_dir: pathlib.Path, log_root: pathlib.Path) -> str:
    """Build the report body for one 305 case."""
    out = [f"# 305 hit: {case_dir.name}\n"]
    result = json.loads((case_dir / "result.json").read_text())
    out.append(f"- status: {result.get('status')}")
    for prob in result.get("problems") or []:
        out.append(f"- problem: {str(prob)[:500]}")
    for step in result.get("steps") or []:
        s = str(step)
        if "cluster ready" in s:
            out.append(f"- cluster: {s[:400]}")
        if "remov" in s.lower() and ("submitted" in s.lower() or "problem" in s.lower()):
            out.append(f"- remove: {s[:300]}")

    backups = sorted(log_root.glob(f"{case_dir.name}_*"))
    if not backups:
        out.append("\n(no log backup found for this case)")
        return "\n".join(out)
    backup = backups[-1]
    out.append(f"\nlog backup: `{backup.name}`\n")

    targets: collections.Counter = collections.Counter()
    connects: collections.Counter = collections.Counter()
    per_host: dict[str, list[str]] = {}

    for arc in sorted(backup.glob("*.tar.gz")):
        host = arc.name.split(".")[0]
        lines: list[str] = []
        try:
            with tarfile.open(arc) as tf:
                for member in tf.getmembers():
                    if not member.isfile() or not member.name.endswith(LOG_SUFFIXES):
                        continue
                    fh = tf.extractfile(member)
                    if fh is None:
                        continue
                    lines.extend(fh.read().decode("utf-8", "replace").split("\n"))
        except (tarfile.TarError, OSError):
            continue
        if not lines:
            continue
        # anchors: the retry-exhaustion marker and every retry attempt
        anchors = [t for t in (_ts(l) for l in lines if "[ReachMaxRetryCount]" in l or "[Retry] retry count is" in l) if t]
        # the hidden reason: dispatch failures, or any WARN/ERROR around the anchors
        keep: list[str] = []
        for line in lines:
            if any(k in line for k in KEYS):
                keep.append(line)
                m = RE_DISPATCH_TARGET.search(line)
                if m:
                    targets[m.group(1)] += 1
                m = RE_CANT_CONNECT.search(line)
                if m:
                    connects[m.group(1)] += 1
                continue
            if not anchors:
                continue
            t = _ts(line)
            if t is None:
                continue
            if any(abs(t - a) <= 60 for a in anchors) and (" WARN " in line or " ERROR " in line):
                keep.append(line)
        if keep:
            per_host[host] = keep

    if targets:
        out.append("## failed dispatch targets (the swallowed reason)")
        for ep, n in targets.most_common():
            out.append(f"- `{ep}` x{n}")
    if connects:
        out.append("\n## `can't connect to node` (306 message)")
        for ep, n in connects.most_common():
            out.append(f"- `{ep}` x{n}")
    for host in sorted(per_host):
        out.append(f"\n## {host} ({len(per_host[host])} lines)")
        seen = set()
        for line in per_host[host][:120]:
            sig = line[45:150]
            if sig in seen:
                continue
            seen.add(sig)
            out.append(f"    {line[:300]}")
    return "\n".join(out)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    run_dir = pathlib.Path(sys.argv[1])
    interval = 20.0
    if "--interval" in sys.argv:
        interval = float(sys.argv[sys.argv.index("--interval") + 1])
    log_root = run_dir / "log_backup"
    report_dir = run_dir / "305_reports"
    done: set[str] = set()
    print(f"watching {run_dir} every {interval:.0f}s for 305", flush=True)
    while True:
        for case_dir in sorted((run_dir / "cases").glob("*/")):
            if case_dir.name in done:
                continue
            result_file = case_dir / "result.json"
            if not result_file.exists():
                continue
            done.add(case_dir.name)
            try:
                text = result_file.read_text()
            except OSError:
                continue
            if '"status": "FAIL"' not in text and "FAIL" not in text:
                continue
            if "305" not in text:
                continue
            body = scan_case(case_dir, log_root)
            report_dir.mkdir(parents=True, exist_ok=True)
            target = report_dir / f"{case_dir.name}.md"
            target.write_text(body)
            print(f"305 HIT: {case_dir.name} -> {target}", flush=True)
        time.sleep(interval)


if __name__ == "__main__":
    raise SystemExit(main())
