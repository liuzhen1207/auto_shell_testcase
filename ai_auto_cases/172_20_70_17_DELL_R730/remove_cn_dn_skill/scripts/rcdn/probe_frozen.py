"""Read the per-replica row inventory off a cluster that was left frozen by a hit.

Why this exists: `ABORT_ON_REPLICA_DIFF` stops a run the moment a case reports a
replica inconsistency, so the hit case's cluster is still serving its data.  The
count-level difference is already in the case's `*.raw` captures; what was missing
on the earlier hits was the *direction* -- which timestamps one replica has and the
other does not.  This tool takes the differing devices from those captures and asks
the live cluster for their exact timestamps, one device at a time.

Run it right after the run stops (the next run's `prepare` wipes the data):

    python3 -m rcdn.probe_frozen <run_dir> <case_id> [--conf conf/...] [--max-devices N]
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys

SKILL = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SKILL / "scripts"))

from rcdn.config import load_config  # noqa: E402
from rcdn.remote import SqlClient, SshRunner  # noqa: E402

RE_COUNT = re.compile(r"^\|\s*(?P<device>[^|]+?)\s*\|\s*(?P<count>\d+)\s*\|")
TABLE_OF = {"table": "tab_0", "table_view": "wv_0_v"}


def _counts(path: pathlib.Path) -> dict[str, int]:
    out: dict[str, int] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = RE_COUNT.match(line)
        if match:
            out[match.group("device").strip()] = int(match.group("count"))
    return out


def _differing_devices(case_dir: pathlib.Path, max_devices: int) -> list[tuple[str, str, dict[str, int]]]:
    """(model, device, {stage: count}) for every device whose count is not constant."""
    found: list[tuple[str, str, dict[str, int]]] = []
    for model in ("tree", "table", "table_view", "object", "object_view"):
        base_path = case_dir / f"baseline_{model}.raw"
        base = _counts(base_path)
        if not base:
            continue
        stages = {p.stem.split(f"_{model}")[0]: p for p in sorted(case_dir.glob(f"*_{model}.raw"))}
        per_device: dict[str, dict[str, int]] = collections.defaultdict(dict)
        for stage, path in stages.items():
            for device, count in _counts(path).items():
                per_device[device][stage] = count
        for device, counts in sorted(per_device.items()):
            values = set(counts.values())
            if len(values) > 1:
                found.append((model, device, counts))
    return found[:max_devices]


def _timestamps(sql: SqlClient, cfg, model: str, device: str, host: str | None = None) -> list[str]:
    if model == "tree":
        statement = f"select time from {device} order by time;"
        dialect = None
    else:
        table = TABLE_OF.get(model)
        if table is None:
            return []
        statement = f"select time from usr_sod0.{table} where device_id = '{device}' order by time;"
        dialect = "table"
    out = sql.sql(host or cfg.cli_host, statement, dialect=dialect, timeout=300, check=False)
    stamps = []
    for line in out.splitlines():
        if not line.strip().startswith("|"):
            continue
        cell = line.strip().strip("|").split("|")[0].strip()
        # The header row spells the column "Time" in the tree dialect and "time" in the
        # table dialect; matching only the former filed the header as a timestamp.
        if cell.lower() == "time" or not cell or set(cell) <= {"-"}:
            continue
        stamps.append(cell)
    return stamps


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=pathlib.Path)
    parser.add_argument("case_id")
    parser.add_argument("--conf", default="conf/cluster.conf")
    parser.add_argument("--max-devices", type=int, default=8)
    parser.add_argument("--per-node", action="store_true",
                        help="also query through every DataNode in turn and report, per node, "
                             "which timestamps it cannot see (row-level, per-replica)")
    parser.add_argument("--out", type=pathlib.Path, default=None)
    args = parser.parse_args(argv)

    case_dir = args.run_dir / "cases" / args.case_id
    if not case_dir.is_dir():
        print(f"no such case dir: {case_dir}")
        return 1
    differing = _differing_devices(case_dir, args.max_devices)
    conf = args.conf if pathlib.Path(args.conf).is_absolute() else SKILL / args.conf
    cfg = load_config(str(conf))
    out_path = args.out or (args.run_dir / f"PROBE_{args.case_id.replace('#', '_')}.md")
    ssh = SshRunner(cfg, args.run_dir / "probe_scratch")
    sql = SqlClient(cfg, ssh, args.run_dir / "probe_scratch")

    lines = [f"# frozen-cluster row inventory: {args.case_id}", ""]
    lines.append(f"cluster: {','.join(cfg.dn_hosts)}  db_dir={cfg.get('DB_DIR')}")
    lines.append("")
    if not differing:
        lines.append("no count-level difference in the case's own captures")
    for model, device, counts in differing:
        detail = "  ".join(f"{stage}={count}" for stage, count in sorted(counts.items()))
        lines.append(f"## {model} {device}")
        lines.append(f"counts: {detail}")
        try:
            stamps = _timestamps(sql, cfg, model, device)
        except Exception as exc:  # noqa: BLE001 - keep going, this is a live probe
            lines.append(f"live query FAILED: {exc}")
            lines.append("")
            continue
        lines.append(f"live rows now (via {cfg.cli_host}): {len(stamps)}")
        # The live cluster is frozen in the stage that detected the diff, so the live
        # count matching baseline vs a stop stage says which side the row belongs to.
        if stamps:
            lines.append(f"first={stamps[0]}  last={stamps[-1]}")
        if args.per_node:
            # The row-level answer to "which replica is short": ask each DataNode in turn for
            # the same device and diff the timestamp sets against their union.  A count-level
            # diff cannot do this -- and a count that recovers a minute later is a visibility
            # lag, not a divergence, so the live (post-restart) state is the one that decides.
            per_node: dict[str, list[str]] = {}
            for host in cfg.dn_hosts:
                try:
                    per_node[host] = _timestamps(sql, cfg, model, device, host=host)
                except Exception as exc:  # noqa: BLE001 - keep probing the other nodes
                    per_node[host] = []
                    lines.append(f"  via {host}: query FAILED: {exc}")
            union = sorted(set().union(*per_node.values())) if per_node else []
            lines.append(f"  union over {len(per_node)} nodes: {len(union)} rows")
            for host, seen in per_node.items():
                seen_set = set(seen)
                missing = [s for s in union if s not in seen_set]
                lines.append(f"  via {host}: {len(seen)} rows"
                             + ("" if not missing else f"  MISSING {len(missing)}"))
                for stamp in missing[:5]:
                    lines.append(f"    MISSING on {host}: {device} @ {stamp}")
        lines.append("")
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {out_path}")
    for line in lines[:40]:
        print("  " + line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
