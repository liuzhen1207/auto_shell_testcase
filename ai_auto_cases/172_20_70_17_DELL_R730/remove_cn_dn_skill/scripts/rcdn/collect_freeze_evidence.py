"""Collect the on-disk evidence of a frozen replica difference, ready to hand to R&D.

Run this **immediately after** ``freeze_on_diff`` stops the run (the cluster must still hold the case's data):
``rcdn run`` wipes the database before the next case, so anything not copied now is gone.

What it gathers per host (the whole point is that the comparison must be replica-level, not cluster-level):

* ``consensus/data_region/<db>_<region>/`` listings -- the progress markers are named ``<nodeId>-<appliedIndex>``,
  so each replica's own applied index and its record of its peers are visible on disk;
* ``wal/<db>-<region>/`` listings + sizes -- note the WAL is truncated by the checkpoint after every memtable
  flush, so it is usually empty and cannot be used to prove whether a row was applied;
* a TsFile inventory (path, size, mtime) for the affected database;
* the diagnostic log lines emitted by the patched build (``snapshot taken``/``snapshot loaded``/``build channel``/
  ``receive baseline``/``RECEIVE GAP``);
* the current region map from the SQL client.

Usage::

    PYTHONPATH=scripts python3 -m rcdn.collect_freeze_evidence conf/cluster.diagnostic.conf \
        --out ../frozen/evidence_case3 --device d_80 [--db usr_sod0]
"""

from __future__ import annotations

import json
import pathlib
import sys
import time

from rcdn.cli import _build, load_config

REMOTE = """
D={db_dir}
echo '## consensus dirs'
find $D/data/datanode/consensus/data_region -maxdepth 2 -mindepth 1 -printf '%p\\t%s\\t%TY-%Tm-%Td %TH:%TM:%TS\\n' 2>/dev/null | sort
echo '## wal dirs'
find $D/data/datanode/wal -maxdepth 2 -mindepth 1 -printf '%p\\t%s\\t%TY-%Tm-%Td %TH:%TM:%TS\\n' 2>/dev/null | sort
echo '## tsfiles'
find $D/data/datanode/data -name '*.tsfile' -printf '%p\\t%s\\t%TY-%Tm-%Td %TH:%TM:%TS\\n' 2>/dev/null | sort
echo '## diagnostics'
grep -hE 'IoTConsensus..diagnostic' $D/logs/log_datanode_all.log 2>/dev/null | tail -200
echo '## local data regions'
ls $D/data/datanode/consensus/data_region 2>/dev/null
"""


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    cfg = load_config(pathlib.Path(argv[0]))
    out = pathlib.Path(argv[argv.index("--out") + 1]) if "--out" in argv else pathlib.Path("frozen/evidence")
    device = argv[argv.index("--device") + 1] if "--device" in argv else ""
    db = argv[argv.index("--db") + 1] if "--db" in argv else "usr_sod0"
    out.mkdir(parents=True, exist_ok=True)

    _, log, ssh, sql = _build(cfg, "evidence", True)
    hosts = getattr(cfg, "dn_hosts", None) or cfg.all_hosts
    script = REMOTE.replace("{db_dir}", cfg.get("DB_DIR"))

    progress: dict[str, dict[str, str]] = {}
    for host in hosts:
        res = ssh.run(host, script, check=False)
        text = getattr(res, "out", "") or ""
        (out / f"{host}.txt").write_text(text)
        section = None
        for line in text.splitlines():
            if line.startswith("## "):
                section = line[3:].strip()
                continue
            if section == "consensus dirs" and line.strip():
                path = line.split("\t")[0]
                name = pathlib.PurePosixPath(path).name
                parent = pathlib.PurePosixPath(path).parent.name
                node, _, index = name.partition("-")
                if node.isdigit() and index.isdigit():
                    progress.setdefault(parent, {})[f"{host}:{node}"] = index
        print(f"  {host}: 收集 {len(text.splitlines())} 行")

    (out / "progress_markers.json").write_text(json.dumps(progress, indent=2, sort_keys=True))
    print("\n  各 region 的进度标记（<region>: <副本:节点> = 已写索引）:")
    for region in sorted(progress):
        row = ", ".join(f"{k}={v}" for k, v in sorted(progress[region].items()))
        print(f"    {region:<10} {row}")

    for label, stmt in (
        ("regions", "show regions"),
        ("devices", f"show devices from {db}" if db else ""),
    ):
        if not stmt:
            continue
        try:
            text = sql.sql(cfg.cli_host, stmt, check=False)
        except Exception as exc:  # noqa: BLE001 - evidence collection must never abort the bundle
            text = f"<{type(exc).__name__}: {exc}>"
        (out / f"sql_{label}.txt").write_text(str(text))
        print(f"  SQL {label}: {len(str(text).splitlines())} 行")

    meta = {
        "when": time.strftime("%Y-%m-%d %H:%M:%S"),
        "device": device,
        "db": db,
        "hosts": hosts,
        "note": "frozen scene: `rcdn run` wipes the database before the next case, so this copy is the evidence",
    }
    (out / "META.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))
    print(f"\n  已写入 {out}（含 progress_markers.json / 每节点清单 / 诊断日志 / SQL 输出）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
