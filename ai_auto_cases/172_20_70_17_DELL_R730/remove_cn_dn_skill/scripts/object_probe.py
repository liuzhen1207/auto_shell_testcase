#!/usr/bin/env python3
"""Standalone TDB-861 window probe: OBJECT churn + MIGRATE REGION + residue audit.

The `dn_object_delete_residue` case uses the same helper
(`rcdn.object_audit.run_object_snapshot_probe`); this entry point exists so the
window can be armed and measured on its own -- no benchmark, no REMOVE, one
region -- which is how the injection was debugged.

    scripts/object_probe.py --conf conf/cluster.conf --db objprobe --table t
    scripts/object_probe.py --conf conf/cluster.conf --db objprobe --table t --no-migrate

Exit code: 0 = window armed and audit clean, 1 = confirmed residue (the defect
reproduced), 2 = window not armed (would be a SKIP inside a case run).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from rcdn.config import load_config  # noqa: E402
from rcdn.object_audit import object_table_shape, run_object_snapshot_probe  # noqa: E402
from rcdn.remote import SqlClient, SshRunner, first_line, looks_like_sql_error  # noqa: E402


SEED_ROWS = 100


def ensure_table(sql, cfg, db: str, table: str, log) -> bool:
    def run(stmt: str, dialect: str = "table") -> str:
        out = sql.sql(cfg.cli_host, stmt, dialect=dialect, check=False)
        if looks_like_sql_error(out) and "already" not in out:
            log(f"  {stmt} -> {first_line(out)[:140]}")
        return out

    run(f"create database {db}")
    run(f"create table {db}.{table} (time timestamp time, dev string tag, o object field)")
    if object_table_shape(sql, cfg, db, table) is None:
        return False
    out = sql.sql(cfg.cli_host, f"select count(*) from {db}.{table}", dialect="table", check=False)
    total = 0
    import re

    match = re.search(r"\|\s*(\d+)\s*\|", out)
    if match:
        total = int(match.group(1))
    if total >= SEED_ROWS:
        return True
    log(f"  表里只有 {total} 行，先写入 {SEED_ROWS} 行唯一 OBJECT 作为覆盖底料")
    import hashlib

    values = []
    for i in range(SEED_ROWS):
        digest = hashlib.sha256(f"seed-{time.time_ns()}-{i}".encode()).hexdigest()
        body = (digest * 16)[:1024]
        values.append(f"({i}, 'd{i}', to_object(true, 0, X'{body}'))")
    for start in range(0, len(values), 10):
        chunk = values[start : start + 10]
        out = sql.sql(
            cfg.cli_host,
            f"insert into {db}.{table}(time, dev, o) values " + ", ".join(chunk),
            dialect="table",
            check=False,
        )
        if looks_like_sql_error(out):
            log(f"  seed insert 失败：{first_line(out)[:140]}")
            return False
    sql.sql(cfg.cli_host, "flush", dialect="table", check=False)
    time.sleep(3)
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conf", required=True)
    ap.add_argument("--db", default="objprobe")
    ap.add_argument("--table", default="t")
    ap.add_argument("--rows", type=int, default=100, help="每轮覆盖的行数")
    ap.add_argument("--interval", type=float, default=1.5, help="两轮覆盖之间的秒数")
    ap.add_argument("--min-records", type=int, default=20, help="判定窗口成立的 GC 删除记录门槛")
    ap.add_argument("--timeout", type=float, default=240.0, help="等迁移完成的秒数")
    ap.add_argument("--no-migrate", action="store_true", help="只做 churn，不触发迁移（对照用）")
    ap.add_argument("--out", default="", help="把结果写到这个 JSON 文件")
    args = ap.parse_args()

    cfg = load_config(Path(args.conf))
    stamp = time.strftime("%Y%m%d_%H%M%S")
    artifacts = Path("results") / f"object_probe_{stamp}"
    artifacts.mkdir(parents=True, exist_ok=True)
    ssh = SshRunner(cfg, artifacts)
    sql = SqlClient(cfg, ssh, artifacts)
    log = lambda msg: print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)

    if not ensure_table(sql, cfg, args.db, args.table, log):
        log("无法准备探针表")
        return 2

    result = run_object_snapshot_probe(
        cfg,
        ssh,
        sql,
        log,
        db=args.db,
        table=args.table,
        rows=args.rows,
        interval=args.interval,
        migrate=not args.no_migrate,
        min_records=args.min_records,
        migration_timeout=args.timeout,
    )
    payload = result.to_dict()
    payload["stamp"] = stamp
    payload["artifacts"] = str(artifacts)
    if args.out:
        Path(args.out).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    (artifacts / "object_probe.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    log(f"结论：{'窗口成立' if result.evidence else '窗口未成立'} — {result.detail}")
    if not result.evidence:
        return 2
    if result.audit.problems:
        for problem in result.audit.problems:
            log(f"  确认残留：{problem}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
