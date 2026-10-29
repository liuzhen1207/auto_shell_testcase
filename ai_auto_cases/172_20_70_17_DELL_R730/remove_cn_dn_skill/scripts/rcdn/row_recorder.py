#!/usr/bin/env python3
"""Record per-device row inventories on its own clock, so a hit can name the exact missing row.

Why this exists (measured 2026-10-01): the exact `(device, time)` can only be read while the
cluster is up, and the harness's own stage captures hold counts only.  Triggering a probe when a
stage's `.norm` lands is too late -- that is the moment the case finishes and the harness stops the
cluster, so the probe for the failing stage was killed mid-query and left nothing behind.

So this recorder does not depend on the harness's timing at all: every `--interval` seconds it asks
one node for the timestamps of every device of a model and appends a compact sample under
`<run-dir>/rowlog/`.  After a hit, diffing consecutive samples names the device whose row set shrank
and the exact timestamp -- while the evidence is still on the cluster.

    python3 row_recorder.py <run-dir> --conf conf/cluster.0928jt_storm.conf [--interval 45]
                            [--model tree] [--max-seconds 14400]
"""
from __future__ import annotations

import argparse
import datetime
import pathlib
import re
import sys
import time

SKILL = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SKILL / "scripts"))

from rcdn.config import load_config  # noqa: E402
from rcdn.remote import SqlClient, SshRunner  # noqa: E402

RE_COUNT = re.compile(r"^\|\s*(?P<device>[^|]+?)\s*\|\s*(?P<count>\d+)\s*\|")


def devices_of(case_dir: pathlib.Path, model: str) -> list[str]:
    for name in (f"baseline_{model}.raw", f"stop_11_101_10_6_{model}.raw",
                 f"stop_11_101_10_7_{model}.raw"):
        path = case_dir / name
        if not path.is_file():
            continue
        found = []
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            hit = RE_COUNT.match(line)
            if hit:
                found.append(hit.group("device").strip())
        if found:
            return found
    return []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=pathlib.Path)
    ap.add_argument("--conf", default="conf/cluster.0928jt_storm.conf")
    ap.add_argument("--model", default="tree")
    ap.add_argument("--interval", type=int, default=45)
    ap.add_argument("--max-seconds", type=int, default=14400)
    args = ap.parse_args()

    out_dir = args.run_dir / "rowlog"
    out_dir.mkdir(parents=True, exist_ok=True)
    log = out_dir / "row_recorder.log"

    def say(message: str) -> None:
        line = f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}  {message}"
        print(line, flush=True)
        with log.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")

    conf = args.conf if pathlib.Path(args.conf).is_absolute() else SKILL / args.conf
    cfg = load_config(str(conf))
    ssh = SshRunner(cfg, out_dir / "scratch")
    sql = SqlClient(cfg, ssh, out_dir / "scratch")
    deadline = time.time() + args.max_seconds
    devices: list[str] = []
    say(f"row recorder started for {args.run_dir} (model={args.model}, every {args.interval}s)")
    while time.time() < deadline:
        if not devices:
            for case_dir in sorted((args.run_dir / "cases").glob("*")):
                devices = devices_of(case_dir, args.model)
                if devices:
                    say(f"device list from {case_dir.name}: {len(devices)} devices")
                    break
        if devices:
            sample: list[str] = [f"# {datetime.datetime.now():%F %T} model={args.model} via={cfg.cli_host}"]
            good = 0
            for device in devices:
                statement = (f"select time from {device} order by time;" if args.model == "tree"
                             else f"select time from usr_sod0.{args.model} where device_id = "
                                  f"'{device}' order by time;")
                try:
                    out = sql.sql(cfg.cli_host, statement, dialect=None, timeout=30, check=False)
                except Exception:  # noqa: BLE001 - a failed sample must not stop the recorder
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
                    good += 1
                    sample.append(f"{device}\t{len(stamps)}\t{','.join(stamps)}")
            stamp_file = out_dir / f"{int(time.time())}.tsv"
            stamp_file.write_text("\n".join(sample) + "\n", encoding="utf-8")
            say(f"sample {stamp_file.name}: {good}/{len(devices)} devices answered")
        time.sleep(args.interval)
    say("row recorder deadline reached, exiting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
