#!/usr/bin/env python3
"""Capture, per replica-shape stage, the exact (device, time) inventory of the compared table.

Why this exists
---------------
The consistency gate compares per-device **counts** between the all-nodes-up baseline and
each stop-<node> capture.  A difference of 1 tells you a row is missing (or extra), but not
*which* row -- and the next case resets the cluster, so the answer is gone within minutes.
Counts also cannot tell the two directions apart:

  * present only in the all-up baseline  -> the survivor lost a row the stopped node had;
  * present only in a stop capture       -> the stopped node holds an extra row
                                            (duplicate, or snapshot/stream overlap).

One write is a single row (`BATCH_SIZE_PER_WRITE=1`, `DEVICE_NUM_PER_WRITE=1`), so the
per-device timestamp inventories are directly comparable and the set difference names the
exact `(device, time)`.

Each stage is read with a **single** `select device_id, time ... order by time`, so a stage
never straddles the moment a node is stopped (per-device queries would take minutes and
mix two cluster shapes).

Usage:  python3 sentinel_times.py <run-dir>
"""
from __future__ import annotations

import collections
import datetime
import pathlib
import re
import sys
import time

SKILL = pathlib.Path(__file__).resolve().parents[2]  # <skill>/scripts/rcdn/<this file>
sys.path.insert(0, str(SKILL / "scripts"))

from rcdn.config import load_config  # noqa: E402
from rcdn.remote import SqlClient, SshRunner  # noqa: E402

TABLE_OF = {"table": "tab_0", "table_view": "wv_0_v", "tree": "root.test.g_0.**"}
RE_ROW = re.compile(r"^\|\s*(?P<device>[^|]+?)\s*\|\s*(?P<stamp>[^|]+?)\s*\|$")


def _split_tree_rows(out: str) -> dict[str, list[str]]:
    """Per-device time lists from a wide tree result (``Time | path.sensor | ...``).

    The tree dialect returns one column per (device, sensor) path, so a row's device
    is the column header minus its last path segment.  Null cells are skipped: a
    device that has no value in a row simply has no row at that timestamp.
    """
    per_device: dict[str, list[str]] = collections.defaultdict(list)
    header: list[str] | None = None
    for line in out.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if header is None or cells[0] == "Time":
            header = cells
            continue
        if set(cells) == {"-"} or cells[0] in {"", "-"}:
            continue
        stamp = cells[0]
        for name, value in zip(header[1:], cells[1:]):
            if value in {"", "null", "NULL"}:
                continue
            device = name.rsplit(".", 1)[0]
            per_device[device].append(stamp)
    return per_device


def main() -> int:
    # Optional args: the run dir, then `--conf=<file>` and (default on) "only stages that
    # appear after this watcher starts".
    # Why `--conf`: this watcher queries the *cluster under test*, and several builds
    # (RC2/RC3/RC4/instrumented) coexist in conf/*.conf; a hard-coded default silently
    # captures the wrong cluster's rows.
    # Why newer-only: started late, the watcher would otherwise replay every pre-existing
    # `.norm` against whatever shape the cluster happens to be in *now*, filing
    # mislabelled inventories. Pass --allow-old-norm to keep the old replay behaviour.
    positional = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = {
        a.split("=")[0]: a.split("=", 1)[1]
        for a in sys.argv[1:]
        if a.startswith("--") and "=" in a
    }
    run_dir = pathlib.Path(positional[0])
    conf = opts.get("--conf", "conf/cluster.conf")
    newer_only = "--allow-old-norm" not in sys.argv
    out_dir = run_dir / "sentinel"
    out_dir.mkdir(parents=True, exist_ok=True)
    cfg = load_config(conf if pathlib.Path(conf).is_absolute() else SKILL / conf)
    started_at = time.time()
    ssh = SshRunner(cfg, out_dir / "scratch")
    sql = SqlClient(cfg, ssh, out_dir / "scratch")
    log_path = out_dir / "sentinel.log"

    def say(message: str) -> None:
        line = f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}  {message}"
        print(line, flush=True)
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")

    def capture(case: str, stage: str, model: str) -> None:
        table = TABLE_OF[model]
        # The case name is part of the file name: every case sweeps the same five
        # stop_* stages, so a stage-only name makes case 2/3 silently reuse case 1's
        # inventory (measured: it cost the exact timestamps of a real diff).
        target = out_dir / f"{case}__{stage}__{model}.times"
        if target.exists():
            return
        if model == "tree":
            # Measured gap: the tree model was skipped entirely, and the one hit whose diff
            # was in root.test.g_0 therefore had no per-row inventory to fall back on.
            statement = f"select * from {table} order by time;"
            dialect = None
        else:
            statement = f"select device_id, time from usr_sod0.{table} order by time;"
            dialect = "table"
        try:
            # Measured: a single-shot query returns "no rows" whenever the cluster is
            # mid-stop/mid-election, which silently turned every stop_* capture into
            # CAPTURE-EMPTY -- exactly the window a replica difference appears in.  Retry
            # with a short backoff and rotate hosts so one down node cannot blind us.
            _hosts = [cfg.cli_host] + [h for h in list(cfg.dn_hosts) if h != cfg.cli_host]
            out = ""
            _last: object = None
            for _try in range(1, 16):
                _host = _hosts[(_try - 1) % len(_hosts)]
                try:
                    _out = sql.sql(_host, statement, dialect=dialect, timeout=60, check=False) or ""
                    if _out.strip() and "Msg:" not in _out:
                        out = _out
                        break
                    _last = _out.strip()[:120]
                except Exception as _exc:  # keep the sentinel alive
                    _last = _exc
                time.sleep(2)
            if not out:
                say(f"capture {case}/{stage}/{model} FAILED after retries: {_last}")
                target.write_text("# CAPTURE-EMPTY\n", encoding="utf-8")
                return
        except Exception as exc:  # keep the sentinel alive
            say(f"capture {case}/{stage}/{model} FAILED: {exc}")
            return
        (out_dir / f"{case}__{stage}__{model}.raw").write_text(out, encoding="utf-8")
        per_device: dict[str, list[str]] = collections.defaultdict(list)
        if model == "tree":
            per_device = _split_tree_rows(out)
        else:
            for line in out.splitlines():
                match = RE_ROW.match(line)
                if match:
                    per_device[match.group("device")].append(match.group("stamp"))
        if not per_device:
            # An empty result is a FAILED capture (node down / query error), not a
            # replica difference.  Mark it so the comparison cannot turn it into
            # "every device is missing" (measured: stop_11_101_10_10 rows=0 was
            # reported as DIFFERS on 101 devices).
            target.write_text("# CAPTURE-EMPTY\n", encoding="utf-8")
            say(f"capture {case}/{stage}/{model}: EMPTY (query failed / node down)")
            return
        lines = [f"{device}\t{len(stamps)}\t{','.join(stamps)}" for device, stamps in sorted(per_device.items())]
        target.write_text("\n".join(lines) + "\n", encoding="utf-8")
        total = sum(len(v) for v in per_device.values())
        say(f"captured case={case} stage={stage} model={model}: {len(per_device)} devices, {total} rows -> {target.name}")

    say(f"sentinel started for {run_dir}" + (" (newer-only)" if newer_only else ""))
    RE_COUNT = re.compile(r"^\|\s*(?P<device>[^|]+?)\s*\|\s*(?P<count>\d+)\s*\|")

    def counts_of(path: pathlib.Path) -> dict[str, int]:
        found: dict[str, int] = {}
        if path.is_file():
            for row in path.read_text(encoding="utf-8", errors="replace").splitlines():
                hit = RE_COUNT.match(row)
                if hit:
                    found[hit.group("device").strip()] = int(hit.group("count"))
        return found

    def probe_differing(case: str, stage: str, model: str) -> None:
        """Name the exact missing (device, time) while the cluster is still up.

        Measured gap (2026-09-30): the stage captures record counts only, and the wide tree
        capture (`select * from root.test.g_0.**`) can come back truncated, so a hit left the
        row unidentifiable even though its logs were archived -- and by the time the harness
        stops the cluster the live probe has nothing left to ask.  Here, at the moment the
        stage's capture lands, ask every DataNode that is still up for the exact timestamps of
        just the devices whose count moved.  A handful of small queries, and the answer is
        row-exact and per-replica.
        """
        case_dir = run_dir / "cases" / case
        base = counts_of(case_dir / f"baseline_{model}.raw")
        cur = counts_of(case_dir / f"{stage}_{model}.raw")
        if not base or not cur:
            return
        differing = [d for d in sorted(set(base) & set(cur)) if base[d] != cur[d]][:8]
        if not differing:
            return
        stop_host = stage.split("_", 1)[1].replace("_", ".") if stage.startswith("stop_") else ""
        target = out_dir / f"ROWS_{case}__{stage}__{model}.txt"
        lines = [f"# per-replica row inventory  case={case} stage={stage} model={model}",
                 f"# stopped node: {stop_host or '(none)'}  devices with a count difference: {len(differing)}"]
        for device in differing:
            if model == "tree":
                statement, dialect = f"select time from {device} order by time;", None
            else:
                statement = (f"select time from usr_sod0.{TABLE_OF.get(model, '')} "
                             f"where device_id = '{device}' order by time;")
                dialect = "table"
            per_node: dict[str, list[str]] = {}
            for host in cfg.dn_hosts:
                if host == stop_host:
                    continue
                try:
                    out = sql.sql(host, statement, dialect=dialect, timeout=120, check=False)
                except Exception as exc:  # noqa: BLE001 - one bad node must not stop the probe
                    lines.append(f"  via {host}: query FAILED: {exc}")
                    continue
                stamps = []
                for row in out.splitlines():
                    if not row.strip().startswith("|"):
                        continue
                    cell = row.strip().strip("|").split("|")[0].strip()
                    if cell.lower() == "time" or not cell or set(cell) <= {"-"}:
                        continue
                    stamps.append(cell)
                if stamps:
                    per_node[host] = stamps
            union = sorted({s for v in per_node.values() for s in v})
            lines.append(f"## {model} {device}  baseline={base[device]} stage={cur[device]} union={len(union)}")
            for host, seen in per_node.items():
                missing = [s for s in union if s not in set(seen)]
                lines.append(f"  via {host}: {len(seen)} rows"
                             + ("" if not missing else f"  MISSING {len(missing)}"))
                for stamp in missing[:5]:
                    lines.append(f"    MISSING on {host}: {device} @ {stamp}")
        target.write_text("\n".join(lines) + "\n", encoding="utf-8")
        say(f"row probe {case}/{stage}/{model}: {len(differing)} differing device(s) -> {target.name}")
    seen: set[pathlib.Path] = set()
    deadline = time.time() + 8 * 3600
    while time.time() < deadline:
        time.sleep(3)
        for norm in sorted(run_dir.glob("cases/*/*.norm")):
            if norm in seen:
                continue
            # A stage file that already existed when this watcher started belongs to a
            # cluster shape that is gone; capturing it now would file the current shape's
            # rows under another stage's name.
            if newer_only and norm.stat().st_mtime < started_at:
                seen.add(norm)
                continue
            seen.add(norm)
            stem = norm.stem
            case = norm.parent.name
            for candidate in sorted(TABLE_OF, key=len, reverse=True):
                if stem.endswith("_" + candidate):
                    stage = stem[: -(len(candidate) + 1)]
                    capture(case, stage, candidate)
                    try:
                        probe_differing(case, stage, candidate)
                    except Exception as exc:  # noqa: BLE001 - a probe must never kill the watcher
                        say(f"row probe {case}/{stage}/{candidate} FAILED: {exc}")
                    break
    say("sentinel deadline reached, exiting")
    return 0


if __name__ == "__main__":
    sys.exit(main())

