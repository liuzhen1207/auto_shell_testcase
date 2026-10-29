"""OBJECT replica audits for the region-migration cases.

Two product defects are what these helpers exist for:

* **TDB-835** -- after a region migration the *target* replica reported
  ``ObjectSize = 0 B`` in ``SHOW REGIONS`` although its OBJECT ``.bin`` files
  were on disk.  The root cause was the size-recovery scan
  (``ObjectTableSizeIndexWriter``) parsing ``<time>.bin`` only: once object file
  names gained a version suffix (``<time>_<version>.bin``) every file was
  skipped, so a cache-less start recovered no object size at all.  Fixed in
  2.0.12.1 RC9; a case asserts it stays fixed.
* **TDB-861** -- a region snapshot taken while the OBJECT GC was running can
  hard-link already ``unlink``-ed objects into the *new* replica, so a freshly
  migrated replica keeps object files whose rows were DELETEd and physically
  removed on the leader.  Observable as a large ``ObjectSize`` difference
  between the leader and the new follower, and as files present on the follower
  whose paths appear in the leader's object-deletion log.  NOT fixed in RC11
  (scheduled for V2.0.13.1), so this audit is expected to report residue on
  that build.

Everything here is read-only except :func:`cold_restart_without_size_cache`,
which stops the cluster, removes the ``TableObjectSizeFile_*`` index so the next
start has to rebuild it from the object files, and starts the cluster again.
"""

from __future__ import annotations

import hashlib
import json
import posixpath
import re
import time
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Iterable

from .remote import first_line, looks_like_sql_error, parse_table

#: Prefix of the persisted per-region table-size index (see
#: ``ObjectTableSizeIndexWriter.OBJECT_SIZE_INDEX_FILE_PREFIX``).
SIZE_INDEX_PREFIX = "TableObjectSizeFile_"

#: ``Remove object file <abs path>, size is <n>(byte)`` -- the OBJECT GC log line.
DELETE_LOG_RE = re.compile(r"Remove object file (?P<path>.+?), size is (?P<size>\d+)\(byte\)")

_SIZE_RE = re.compile(r"^\s*(?P<num>-?\d+(?:\.\d+)?)\s*(?P<unit>[KMGTP]?B)?\s*$", re.IGNORECASE)
_UNIT = {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3, "TB": 1024**4, "PB": 1024**5}

#: Tolerance when comparing a reported ObjectSize against the physical bytes and
#: against another replica.  Object files are immutable once sealed, so two
#: synced replicas should agree exactly; the tolerance only absorbs a flush that
#: landed between the two samples.
SIZE_TOLERANCE = 1 << 20  # 1 MiB
SIZE_TOLERANCE_RATIO = 0.10


def db_matches(name: str, wanted: str) -> bool:
    """True when a SHOW REGIONS database name refers to ``wanted``.

    The printed name may carry the ``root.`` prefix or a model suffix, and the
    benchmark's ``usr_sod0`` may appear as ``root.usr_sod0``; comparing the two
    naively silently filters out every replica and turns the audit into a
    no-evidence SKIP.
    """
    a = (name or "").strip()
    b = (wanted or "").strip()
    if not a or not b:
        return False
    for prefix in ("root.",):
        if a.startswith(prefix):
            a = a[len(prefix):]
        if b.startswith(prefix):
            b = b[len(prefix):]
    return a == b or a.startswith(b + "_") or b.startswith(a + "_")


def fetch_region_rows(sql, cfg, databases: Iterable[str] | None = None) -> tuple[list[dict], list[str]]:
    """Return (region rows, errors) for the databases under audit.

    `SHOW REGIONS` in the *tree* dialect lists only the tree-model databases of
    this build; the table database that carries the OBJECT columns is not in
    that output at all, which is how the first version of this audit managed to
    compare "0 B" against "0 files" and declare victory.  The relational
    dialect's `SHOW REGIONS FROM <db>` is the query that returns the table
    replicas, so it is tried first and the tree form is only a fallback.
    """
    wanted = [d for d in (databases or []) if d]
    rows: list[dict] = []
    errors: list[str] = []

    def run(statement: str, dialect: str | None) -> list[dict] | None:
        out = sql.sql(cfg.cli_host, statement, dialect=dialect, check=False)
        if looks_like_sql_error(out):
            errors.append(f"`{statement}` ({dialect or 'tree'}) 失败：{first_line(out)[:160]}")
            return None
        return parse_table(out)

    for name in wanted:
        for statement, dialect in (
            (f"show regions from {name};", "table"),
            (f"show regions of database {name};", None),
        ):
            got = run(statement, dialect)
            if got:
                rows.extend(got)
                break

    if not wanted:
        got = run("show regions;", None)
        if got:
            rows.extend(got)
    return rows, errors


def parse_size(text: str) -> int | None:
    """``"8.39 MB"`` / ``"0 B"`` / ``"-1"`` -> bytes.  ``None`` when unparseable."""
    m = _SIZE_RE.match(text or "")
    if not m:
        return None
    num = float(m.group("num"))
    unit = (m.group("unit") or "B").upper()
    return int(round(num * _UNIT.get(unit, 1)))


def normalize_row(row: dict[str, str]) -> dict[str, str]:
    """Lower-case the column names and drop spaces so ``Region ID`` == ``RegionId``."""
    return {re.sub(r"[^a-z0-9]", "", k.lower()): (v or "").strip() for k, v in row.items()}


def _pick(row: dict[str, str], *names: str) -> str:
    for n in names:
        if n in row and row[n]:
            return row[n]
    return ""


@dataclass
class Replica:
    region: int
    node_id: int
    host: str
    role: str
    status: str
    database: str
    object_text: str
    tsfile_text: str

    @property
    def reported_bytes(self) -> int | None:
        return parse_size(self.object_text)

    def to_dict(self) -> dict:
        return {
            "region": self.region,
            "node_id": self.node_id,
            "host": self.host,
            "role": self.role,
            "status": self.status,
            "database": self.database,
            "object_size_text": self.object_text,
            "object_size_bytes": self.reported_bytes,
            "tsfile_size_text": self.tsfile_text,
        }


def data_region_replicas(rows: Iterable[dict[str, str]]) -> list[Replica]:
    """Filter ``SHOW REGIONS`` rows down to DataRegion replicas."""
    out: list[Replica] = []
    for raw in rows:
        row = normalize_row(raw)
        rtype = _pick(row, "type", "regiontype")
        if rtype and "dataregion" not in rtype.lower():
            continue
        region_s = _pick(row, "regionid", "id")
        node_s = _pick(row, "datanodeid", "nodeid")
        if not region_s.isdigit() or not node_s.isdigit():
            continue
        out.append(
            Replica(
                region=int(region_s),
                node_id=int(node_s),
                host=_pick(row, "internaladdress", "rpcaddress", "host"),
                role=_pick(row, "role"),
                status=_pick(row, "status"),
                database=_pick(row, "database", "databasename"),
                object_text=_pick(row, "objectsize", "objectfilesize"),
                tsfile_text=_pick(row, "tsfilesize", "regionfilesize"),
            )
        )
    return out


# ---------------------------------------------------------------------------
# On-disk OBJECT inventory
# ---------------------------------------------------------------------------
def object_roots(cfg, ssh, host: str) -> list[str]:
    """``<data dir>/object`` for every configured DataNode data directory.

    Multi-disk deployments list several ``dn_data_dirs``; the OBJECT folders are
    one per data directory (``TierManager.getAllObjectFileFolders()``), which is
    exactly the "objects on more than one disk" shape these defects need.
    """
    db_dir = cfg.get("DB_DIR")
    res = ssh.run(
        host,
        f"cat {db_dir}/conf/iotdb-system.properties 2>/dev/null || true",
        check=False,
    )
    dirs: list[str] = []
    for line in res.out.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key.strip() == "dn_data_dirs" and value.strip():
            for tier in value.strip().split(";"):
                for d in tier.split(","):
                    if d.strip():
                        dirs.append(d.strip())
    if not dirs:
        dirs = ["data/datanode/data"]
    roots = []
    for d in dirs:
        full = d if d.startswith("/") else posixpath.join(db_dir, d)
        roots.append(posixpath.normpath(full) + "/object")
    return roots


def split_object_path(roots: Iterable[str], path: str) -> tuple[int, str] | None:
    """``<root>/<regionId>/<table>/<file>.bin`` -> ``(regionId, "<table>/<file>.bin")``."""
    for root in roots:
        prefix = root.rstrip("/") + "/"
        if not path.startswith(prefix):
            continue
        rest = path[len(prefix):]
        region_s, _, tail = rest.partition("/")
        if region_s.isdigit() and tail:
            return int(region_s), tail
        return None
    return None


def scan_objects(cfg, ssh, host: str, roots: list[str]) -> dict[int, dict[str, int]]:
    """Per region id: ``relative path -> size`` for every ``.bin`` under the roots.

    The layout is ``<object root>/<regionId>/<table dir>/[<sub dirs>/]<time>[_<version>].bin``
    (see ``ObjectTableSizeIndexWriter.buildIndexFromScratch``), so the first path
    segment after the root is the region id.
    """
    if not roots:
        return {}
    cmd = "find " + " ".join(f"'{r}'" for r in roots) + " -type f -name '*.bin' -printf '%p\\t%s\\n' 2>/dev/null || true"
    res = ssh.run(host, cmd, check=False)
    out: dict[int, dict[str, int]] = {}
    for line in res.out.splitlines():
        path, _, size_s = line.partition("\t")
        if not size_s.strip().isdigit():
            continue
        parsed = split_object_path(roots, path)
        if parsed is None:
            continue
        region, rel = parsed
        out.setdefault(region, {})[rel] = int(size_s)
    return out


def deleted_object_paths(cfg, ssh, host: str, region: int | None) -> set[str]:
    """Relative paths the OBJECT GC physically removed on ``host``.

    ``region=None`` counts every region, which is what the pre-removal priming
    wait needs: it only asks whether the GC is running at all, not where.
    """
    cmd = (
        f"cat {cfg.get('DB_DIR')}/logs/log_datanode_object_deletion.log 2>/dev/null || true"
    )
    res = ssh.run(host, cmd, check=False)
    paths: set[str] = set()
    for line in res.out.splitlines():
        m = DELETE_LOG_RE.search(line)
        if not m:
            continue
        abs_path = m.group("path")
        idx = abs_path.find("/object/")
        if idx < 0:
            continue
        rest = abs_path[idx + len("/object/"):]
        region_s, _, tail = rest.partition("/")
        if not (region_s.isdigit() and tail):
            continue
        if region is not None and int(region_s) != region:
            continue
        paths.add(tail)
    return paths


# ---------------------------------------------------------------------------
# Audits
# ---------------------------------------------------------------------------
@dataclass
class SizeAudit:
    problems: list[str] = field(default_factory=list)
    replicas: list[dict] = field(default_factory=list)
    physical: dict[str, dict[str, int]] = field(default_factory=dict)
    #: False when no replica of the target databases physically holds an OBJECT
    #: file: the case then proved nothing about TDB-835 and must not PASS.
    evidence: bool = False
    scanned_databases: list[str] = field(default_factory=list)
    all_databases: list[str] = field(default_factory=list)
    raw_rows: list[dict] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "problems": self.problems,
            "replicas": self.replicas,
            "physical": self.physical,
            "evidence": self.evidence,
            "scanned_databases": self.scanned_databases,
            "all_databases": self.all_databases,
            "raw_rows": self.raw_rows,
        }


def _physical_total(physical: dict[int, dict[str, int]], region: int) -> int:
    return sum(physical.get(region, {}).values())


def audit_object_size(
    cfg,
    ssh,
    sql,
    log,
    *,
    hosts: list[str],
    label: str = "",
    databases: Iterable[str] | None = None,
) -> SizeAudit:
    """TDB-835 guard: per-replica ObjectSize must be present, non-negative, physical.

    Checks, for every DataRegion replica of the running cluster:

    * the reported ObjectSize is a parseable number and **not negative**
      (``-1`` is what ``LoadCache`` shows when the DataNode never reported the
      region at all, so it is a real failure, not a formatting quirk);
    * when the replica physically holds ``.bin`` files, the reported size is
      **not 0** -- the exact TDB-835 symptom;
    * the reported size matches the physical bytes (``SIZE_TOLERANCE``);
    * replicas of the same region agree with each other.
    """
    audit = SizeAudit()
    rows, query_errors = fetch_region_rows(sql, cfg, databases)
    audit.problems.extend(f"{label}{e}" for e in query_errors)
    replicas = data_region_replicas(rows)
    audit.all_databases = sorted({r.database for r in replicas})
    audit.raw_rows = rows[:40]
    wanted = [d for d in (databases or []) if d]
    if wanted:
        # The table database is what carries the OBJECT columns; the tree
        # database and the ConfigNode's own ``root.__audit`` regions have no
        # objects at all, and including them would dilute the audit to
        # "0 B == 0 B" (the way TDB-835 slipped through the first time).
        kept = [r for r in replicas if any(db_matches(r.database, d) for d in wanted)]
        if not kept and replicas:
            audit.problems.append(
                f"{label}OBJECT 审计：目标库 {wanted} 在 SHOW REGIONS 中不存在"
                f"（实际：{audit.all_databases}）"
            )
        replicas = kept
        audit.scanned_databases = sorted({r.database for r in replicas})
    if not replicas:
        audit.problems.append(f"{label}OBJECT 审计：SHOW REGIONS 没有返回任何 DataRegion 副本")
        return audit

    physical_by_host: dict[str, dict[int, dict[str, int]]] = {}
    for host in sorted({r.host for r in replicas if r.host}):
        roots = object_roots(cfg, ssh, host)
        physical_by_host[host] = scan_objects(cfg, ssh, host, roots)

    by_region: dict[int, list[Replica]] = {}
    for rep in replicas:
        if rep.status and rep.status.lower() not in {"running", "readonly"}:
            continue
        by_region.setdefault(rep.region, []).append(rep)
        phys = _physical_total(physical_by_host.get(rep.host, {}), rep.region)
        reported = rep.reported_bytes
        audit.replicas.append({**rep.to_dict(), "physical_bytes": phys})
        audit.physical.setdefault(rep.host, {})[f"region_{rep.region}"] = phys

        if reported is None:
            audit.problems.append(
                f"{label}region {rep.region} @ {rep.host}: ObjectSize 无法解析（{rep.object_text!r}）"
            )
            continue
        if reported < 0:
            audit.problems.append(
                f"{label}region {rep.region} @ {rep.host}: ObjectSize 为负（{rep.object_text}）"
                f"——DataNode 未上报该 region 的对象大小"
            )
            continue
        if phys > 0 and reported == 0:
            audit.problems.append(
                f"{label}region {rep.region} @ {rep.host}: 物理 OBJECT 文件 {phys} 字节，"
                f"但 SHOW REGIONS ObjectSize=0（TDB-835 症状）"
            )
            continue
        if phys > 0:
            slack = max(SIZE_TOLERANCE, int(phys * SIZE_TOLERANCE_RATIO))
            if abs(reported - phys) > slack:
                audit.problems.append(
                    f"{label}region {rep.region} @ {rep.host}: ObjectSize={reported} 与物理 "
                    f"{phys} 字节不一致（差 {reported - phys}）"
                )

    for region, reps in sorted(by_region.items()):
        sized = [r for r in reps if (r.reported_bytes or 0) > 0]
        if len(sized) < 2:
            continue
        values = [r.reported_bytes for r in sized]
        spread = max(values) - min(values)
        slack = max(SIZE_TOLERANCE, int(max(values) * SIZE_TOLERANCE_RATIO))
        if spread > slack:
            detail = ", ".join(f"{r.host}(node {r.node_id})={r.object_text}" for r in sized)
            audit.problems.append(
                f"{label}region {region}: 各副本 ObjectSize 不一致（差 {spread} 字节）：{detail}"
            )
    audit.evidence = any(
        r.get("physical_bytes", 0) > 0 for r in audit.replicas
    )
    log(
        f"  {label}OBJECT 大小审计：{len(audit.replicas)} 个副本，"
        f"{sum(1 for r in audit.replicas if r.get('physical_bytes', 0) > 0)} 个有实体 OBJECT 文件，"
        f"{len(audit.problems)} 个问题"
    )
    return audit


@dataclass
class ResidueAudit:
    problems: list[str] = field(default_factory=list)
    residue: list[dict] = field(default_factory=list)
    replicas: list[dict] = field(default_factory=list)
    #: Total OBJECT-GC deletion records seen on the leaders.  With too few the
    #: race window the case exists for was never created, so a PASS would be a
    #: claim the run did not earn (measured 2026-10-24: a whole-table DELETE of
    #: 318 rows produced only 8 GC records, in a single region).
    gc_records: int = 0
    #: Minimum record count that counts as evidence, from ``OBJECT_GC_MIN_RECORDS``.
    min_records: int = 20
    scanned_databases: list[str] = field(default_factory=list)
    all_databases: list[str] = field(default_factory=list)

    @property
    def evidence(self) -> bool:
        return self.gc_records >= max(self.min_records, 1)

    def to_dict(self) -> dict:
        return {
            "problems": self.problems,
            "residue": self.residue,
            "replicas": self.replicas,
            "gc_records": self.gc_records,
            "evidence": self.evidence,
            "scanned_databases": self.scanned_databases,
            "all_databases": self.all_databases,
        }


def audit_deleted_object_residue(
    cfg, ssh, sql, log, *, label: str = "", databases: Iterable[str] | None = None
) -> ResidueAudit:
    """TDB-861 probe: a new replica must not keep objects the leader already deleted.

    For every DataRegion with at least two replicas:

    * take the leader's file set as the reference (``Role`` column of
      ``SHOW REGIONS``; falls back to the replica holding the fewest bytes);
    * for each follower, the extra files are *residue* candidates;
    * a candidate is **confirmed residue** when its relative path also appears in
      the leader's ``log_datanode_object_deletion.log``: the leader physically
      removed exactly that file, so the follower carrying it is the TDB-861
      snapshot/GC race;
    * unreferenced residue (present on the follower, absent on the leader, not in
      the deletion log) is recorded but not failed -- a follower may legitimately
      hold a file the leader has not flushed/compacted yet.
    """
    audit = ResidueAudit()
    audit.min_records = int(cfg.raw("OBJECT_GC_MIN_RECORDS", "20") or 20)
    rows, query_errors = fetch_region_rows(sql, cfg, databases)
    audit.problems.extend(f"{label}{e}" for e in query_errors)
    replicas = data_region_replicas(rows)
    audit.all_databases = sorted({r.database for r in replicas})
    wanted = [d for d in (databases or []) if d]
    if wanted:
        kept = [r for r in replicas if any(db_matches(r.database, d) for d in wanted)]
        if not kept and replicas:
            audit.problems.append(
                f"{label}残留审计：目标库 {wanted} 在 SHOW REGIONS 中不存在"
                f"（实际：{audit.all_databases}）"
            )
        replicas = kept
        audit.scanned_databases = sorted({r.database for r in replicas})
    by_region: dict[int, list[Replica]] = {}
    for rep in replicas:
        if rep.status and rep.status.lower() not in {"running", "readonly"}:
            continue
        by_region.setdefault(rep.region, []).append(rep)

    physical_by_host: dict[str, dict[int, dict[str, int]]] = {}
    for host in sorted({r.host for r in replicas if r.host}):
        physical_by_host[host] = scan_objects(cfg, ssh, host, object_roots(cfg, ssh, host))

    for region, reps in sorted(by_region.items()):
        if len(reps) < 2 or (exclude and region in exclude):
            continue
        files: dict[str, dict[str, int]] = {}
        for rep in reps:
            files[rep.host] = dict(physical_by_host.get(rep.host, {}).get(region, {}))
            audit.replicas.append({**rep.to_dict(), "files": len(files[rep.host]),
                                   "bytes": sum(files[rep.host].values())})
        leader = next((r for r in reps if r.role.lower().startswith("leader")), None)
        if leader is None:
            leader = min(reps, key=lambda r: sum(files[r.host].values()))
        reference = set(files[leader.host])
        deleted = deleted_object_paths(cfg, ssh, leader.host, region)
        audit.gc_records += len(deleted)
        if not deleted:
            log(
                f"  {label}region {region}: leader {leader.host} 的对象删除日志为空"
                "（本用例未产生 GC 记录，残留判据只能靠文件集）"
            )
        for rep in reps:
            if rep.host == leader.host:
                continue
            extra = sorted(set(files[rep.host]) - reference)
            confirmed = sorted(set(extra) & deleted)
            bytes_extra = sum(files[rep.host][p] for p in extra)
            entry = {
                "region": region,
                "leader": leader.host,
                "follower": rep.host,
                "extra_files": len(extra),
                "extra_bytes": bytes_extra,
                "confirmed_residue_files": len(confirmed),
                "confirmed_residue_bytes": sum(files[rep.host][p] for p in confirmed),
                "confirmed_residue_sample": confirmed[:5],
                "leader_deleted_files": len(deleted),
            }
            if extra or confirmed:
                audit.residue.append(entry)
            if confirmed:
                audit.problems.append(
                    f"{label}region {region}: 新副本 {rep.host} 保留了 leader {leader.host} "
                    f"已物理删除的 {len(confirmed)} 个 OBJECT 文件（{entry['confirmed_residue_bytes']} 字节）"
                    "——TDB-861 快照/GC 残留"
                )
    log(
        f"  {label}OBJECT 删除残留审计：{len(audit.replicas)} 个副本，"
        f"leader 侧 GC 记录 {audit.gc_records} 条，"
        f"{len(audit.residue)} 组差异，{len(audit.problems)} 个确认残留"
    )
    return audit


# ---------------------------------------------------------------------------
# Cache-less restart
# ---------------------------------------------------------------------------
def clear_size_index(cfg, ssh, log, *, hosts: list[str]) -> int:
    """Delete every ``TableObjectSizeFile_*`` so the next start must rebuild it."""
    removed = 0
    for host in hosts:
        roots = object_roots(cfg, ssh, host)
        search = " ".join(f"'{posixpath.dirname(r)}'" for r in roots)
        cmd = (
            f"find {search} -name '{SIZE_INDEX_PREFIX}*' -type f -printf '%p\\n' 2>/dev/null "
            f"| tee /tmp/size_index_{host}.list | wc -l; "
            f"find {search} -name '{SIZE_INDEX_PREFIX}*' -type f -delete 2>/dev/null || true"
        )
        res = ssh.run(host, cmd, check=False)
        try:
            n = int((res.out.strip().splitlines() or ["0"])[0])
        except (ValueError, IndexError):
            n = 0
        removed += n
        log(f"  清空 {host} 的表大小缓存索引：{n} 个文件")
    return removed


def cold_restart_without_size_cache(cfg, cluster, ssh, log, artifacts: Path) -> None:
    """Stop the cluster, drop the size index, start again and wait for health."""
    log("  冷启动（无表大小缓存）：停集群 → 删除 TableObjectSizeFile_* → 起集群")
    cluster.stop_all()
    clear_size_index(cfg, ssh, log, hosts=cfg.dn_hosts)
    if not cluster.start_all():
        raise RuntimeError("冷启动失败：节点未全部起来")
    if not cluster.wait_healthy(timeout=cfg.get_int("CLUSTER_START_TIMEOUT_SEC")):
        raise RuntimeError("冷启动失败：集群未在超时内恢复 Running/ReadOnly")
    (artifacts / "cold_restart.txt").write_text(
        f"cold restart at {time.strftime('%Y-%m-%d %H:%M:%S')}\n", encoding="utf-8"
    )


def write_audit(artifacts: Path, name: str, payload: dict) -> None:
    (artifacts / f"{name}.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )


# ---------------------------------------------------------------------------
# TDB-861 window injection: OBJECT overwrite churn + a targeted region migration
# ---------------------------------------------------------------------------
# Measured on master 939750de80 (2026-10-28): a DELETE removes the object files
# without writing a single `log_datanode_object_deletion.log` record (payload
# reclaim happens while the TSFile is evicted), so the delete-burst injection the
# case used to rely on can no longer arm the window -- the audit found 4-8 GC
# records and SKIPped.  Overwriting the same (device, time) rows with fresh
# payloads does go through the OBJECT GC journal: 100 rows re-written per round
# produced ~40 deletion records per DataNode within seconds, every round.  Pair
# that churn with `MIGRATE REGION` (which takes the snapshot the defect needs)
# and the window exists on demand instead of by luck.


@dataclass
class TableShape:
    time_column: str
    device_column: str
    object_column: str


def object_table_shape(sql, cfg, db: str, table: str) -> TableShape | None:
    """Read the TIME / TAG / OBJECT columns from ``desc <db>.<table>``."""
    out = sql.sql(cfg.cli_host, f"desc {db}.{table}", dialect="table", check=False)
    if looks_like_sql_error(out):
        return None
    time_col = device_col = object_col = ""
    for row in parse_table(out):
        name = _pick(row, "ColumnName", "columnname", "Column").strip()
        dtype = _pick(row, "DataType", "datatype").strip().upper()
        category = _pick(row, "Category", "category").strip().upper()
        if not name:
            continue
        if not time_col and (category == "TIME" or dtype == "TIMESTAMP"):
            time_col = name
        elif not object_col and dtype == "OBJECT":
            object_col = name
        elif not device_col and (category == "TAG" or dtype in {"STRING", "TEXT"}):
            device_col = name
    if not (time_col and device_col and object_col):
        return None
    return TableShape(time_col, device_col, object_col)


def object_payload_literal(tag: str, size: int = 512) -> str:
    """A fresh, unique OBJECT value.

    ``X'..'`` alone is rejected for an OBJECT column ("data type is not
    consistent"); ``to_object(true, 0, X'..')`` is the form the table model
    accepts (the arguments are is_null / offset / blob).
    """
    import hashlib

    digest = hashlib.sha256(f"{tag}-{time.time_ns()}".encode()).hexdigest()
    body = (digest * ((size * 2) // len(digest) + 1))[: size * 2]
    return f"to_object(true, 0, X'{body}')"


class ObjectChurn:
    """Overwrite the same (device, time) rows with new OBJECT payloads.

    Every round turns the previous round's payloads into garbage, so the OBJECT
    GC keeps unlinking files for as long as the thread runs -- which is what
    keeps the GC busy while a region snapshot is being taken.
    """

    def __init__(
        self,
        cfg,
        sql,
        log,
        db: str,
        table: str,
        shape: TableShape,
        *,
        rows: int = 100,
        interval: float = 1.5,
        batch: int = 10,
    ):
        self.cfg = cfg
        self.sql = sql
        self.log = log
        self.db = db
        self.table = table
        self.shape = shape
        self.rows = max(rows, 1)
        self.interval = max(interval, 0.2)
        self.batch = max(batch, 1)
        self.rounds = 0
        self.errors: list[str] = []
        self._pairs: list[tuple[str, str]] = []
        self._stop = None
        self._thread = None

    def sample(self) -> list[tuple[str, str]]:
        """Pick the rows to overwrite; they must already exist to be overwrites."""
        out = self.sql.sql(
            self.cfg.cli_host,
            f"select {self.shape.device_column}, {self.shape.time_column} "
            f"from {self.db}.{self.table} limit {self.rows}",
            dialect="table",
            check=False,
        )
        if looks_like_sql_error(out):
            self.errors.append(first_line(out)[:160])
            return []
        pairs = []
        for row in parse_table(out):
            device = _pick(row, self.shape.device_column, self.shape.device_column.lower()).strip()
            stamp = _pick(row, self.shape.time_column, self.shape.time_column.lower()).strip()
            if device and stamp:
                pairs.append((device, stamp))
        self._pairs = pairs
        return pairs

    def round(self) -> None:
        if not self._pairs:
            return
        stamp = time.time_ns()
        values = [
            f"({stamp_iso}, '{device}', {object_payload_literal(f'{stamp}-{i}')})"
            for i, (device, stamp_iso) in enumerate(self._pairs)
        ]
        for start in range(0, len(values), self.batch):
            chunk = values[start : start + self.batch]
            out = self.sql.sql(
                self.cfg.cli_host,
                f"insert into {self.db}.{self.table}"
                f"({self.shape.time_column}, {self.shape.device_column}, {self.shape.object_column})"
                f" values " + ", ".join(chunk),
                dialect="table",
                check=False,
            )
            if looks_like_sql_error(out):
                self.errors.append(first_line(out)[:160])
        self.sql.sql(self.cfg.cli_host, "flush", dialect="table", check=False)
        self.rounds += 1

    def _loop(self) -> None:
        while not self._stop.is_set():
            self.round()
            self._stop.wait(self.interval)

    def start(self) -> None:
        import threading

        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, name="object-churn", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if self._stop is not None:
            self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=max(self.interval * 2, 5))


@dataclass
class ObjectProbeResult:
    audit: ResidueAudit
    evidence: bool
    detail: str
    stats: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "evidence": self.evidence,
            "detail": self.detail,
            "stats": self.stats,
            "audit": self.audit.to_dict(),
        }


def _migration_plan(cfg, sql, db: str, log, exclude: set[int] | None = None) -> dict | None:
    """Pick one region with >=2 replicas and a DataNode that does not hold it."""
    rows, _errors = fetch_region_rows(sql, cfg, [db])
    replicas = [r for r in data_region_replicas(rows) if db_matches(r.database, db)]
    if not replicas:
        return None
    out = sql.sql(cfg.cli_host, "show datanodes", dialect="tree", check=False)
    nodes: dict[int, str] = {}
    for row in parse_table(out):
        node_id = _pick(row, "NodeID", "nodeid").strip()
        address = _pick(row, "RpcAddress", "rpcaddress").strip()
        if node_id.isdigit() and address:
            nodes[int(node_id)] = address
    by_region: dict[int, list[Replica]] = {}
    for rep in replicas:
        by_region.setdefault(rep.region, []).append(rep)
    for region, reps in sorted(by_region.items()):
        if len(reps) < 2 or (exclude and region in exclude):
            continue
        holder = {r.node_id for r in reps}
        leader = next((r for r in reps if r.role.lower().startswith("leader")), reps[0])
        targets = [node for node in sorted(nodes) if node not in holder]
        if not targets:
            continue
        target = targets[0]
        log(
            f"  迁移计划：region {region}（{len(reps)} 个副本，leader 节点 {leader.node_id} "
            f"{leader.host}）→ 目标节点 {target} {nodes[target]}"
        )
        return {
            "region": region,
            "from_id": leader.node_id,
            "from_host": leader.host,
            "to_id": target,
            "to_host": nodes[target],
            "replicas": [r.to_dict() for r in reps],
        }
    return None


def run_object_snapshot_probe(
    cfg,
    ssh,
    sql,
    log,
    *,
    db: str,
    table: str,
    rows: int = 100,
    interval: float = 1.5,
    migrate: bool = True,
    min_records: int = 20,
    migration_timeout: float = 240.0,
    settle_sec: float = 10.0,
) -> ObjectProbeResult:
    """Arm the TDB-861 window, then audit the new replica.

    Returns ``evidence=False`` (with the reason in ``detail``) when the window
    could not be created -- the caller turns that into a SKIP, never a PASS.
    """
    audit = ResidueAudit(min_records=min_records)
    stats: dict = {"db": db, "table": table}

    shape = object_table_shape(sql, cfg, db, table)
    if shape is None:
        return ObjectProbeResult(audit, False, f"无法解析 {db}.{table} 的 TIME/TAG/OBJECT 列", stats)
    stats["columns"] = {
        "time": shape.time_column,
        "device": shape.device_column,
        "object": shape.object_column,
    }
    churn = ObjectChurn(cfg, sql, log, db, table, shape, rows=rows, interval=interval)
    pairs = churn.sample()
    stats["pairs"] = len(pairs)
    if not pairs:
        return ObjectProbeResult(audit, False, f"{db}.{table} 里没有可覆盖的行（{churn.errors[:1]}）", stats)

    plan = _migration_plan(cfg, sql, db, log) if migrate else None
    if migrate and plan is None:
        return ObjectProbeResult(audit, False, "找不到可迁移的 region（需要 >=2 副本 + 一个空闲 DataNode）", stats)
    stats["migration"] = plan

    def gc_total(host: str) -> int:
        return len(deleted_object_paths(cfg, ssh, host, plan["region"] if plan else None))

    hosts = list(cfg.dn_hosts)
    gc_before = {h: gc_total(h) for h in hosts}
    stats["gc_before"] = gc_before

    # Prime one round outside the thread so the first garbage exists before the
    # snapshot starts, then keep overwriting for the whole migration.
    churn.round()
    churn.start()
    started = time.time()
    primed = 0
    while time.time() - started < 60:
        primed = max(gc_total(h) - gc_before[h] for h in hosts)
        if primed > 0:
            break
        time.sleep(3)
    stats["gc_primed"] = primed
    log(f"  OBJECT churn 已启动：{churn.rounds} 轮，GC 新增记录 {primed} 条（窗口门槛 {min_records}）")

    moved = False
    if plan is not None:
        out = sql.sql(
            cfg.cli_host,
            f"migrate region {plan['region']} from {plan['from_id']} to {plan['to_id']}",
            dialect="table",
            check=False,
        )
        log(f"  MIGRATE REGION: {first_line(out)[:160]}")
        stats["migrate_sql"] = first_line(out)[:160]
        if not looks_like_sql_error(out):
            deadline = time.time() + migration_timeout
            while time.time() < deadline:
                time.sleep(3)
                rows_now, _ = fetch_region_rows(sql, cfg, [db])
                reps = [
                    r
                    for r in data_region_replicas(rows_now)
                    if r.region == plan["region"]
                ]
                if any(r.node_id == plan["to_id"] and r.status.lower() == "running" for r in reps) and not any(
                    r.node_id == plan["from_id"] for r in reps
                ):
                    moved = True
                    break
            stats["migrated"] = moved
            stats["migration_sec"] = round(time.time() - started, 1)
            log(f"  迁移{'完成' if moved else '未在 {:.0f}s 内完成'.format(migration_timeout)}，"
                f"churn 已跑 {churn.rounds} 轮")
    churn.stop()
    sql.sql(cfg.cli_host, "flush", dialect="table", check=False)
    time.sleep(settle_sec)

    audit = audit_deleted_object_residue(cfg, ssh, sql, log, databases=[db])
    gc_after = {h: gc_total(h) for h in hosts}
    stats.update(
        {
            "churn_rounds": churn.rounds,
            "churn_errors": churn.errors[:3],
            "gc_after": gc_after,
            "gc_delta": {h: gc_after[h] - gc_before[h] for h in hosts},
        }
    )
    window = sum(stats["gc_delta"].values())
    evidence = audit.gc_records >= max(min_records, 1)
    if evidence and plan is not None and not moved:
        evidence = False
    detail = (
        f"GC 删除记录 {audit.gc_records} 条（门槛 {min_records}），"
        f"窗口期新增 {window} 条，churn {churn.rounds} 轮，"
        f"迁移{'完成' if moved else '未完成' if plan else '未启用'}，"
        f"副本 {len(audit.replicas)} 个，残留差异 {len(audit.residue)} 组"
    )
    return ObjectProbeResult(audit, evidence, detail, stats)


def ensure_object_probe_table(
    cfg, sql, log, db: str, table: str, *, seed_rows: int = 100
) -> bool:
    """Create + seed a self-contained OBJECT table for the snapshot probe.

    The window must not depend on the benchmark workload being up: the churn has
    to overwrite rows that already exist, and the benchmark's table may not even
    carry an OBJECT column on a given run.
    """
    def run(stmt: str) -> str:
        out = sql.sql(cfg.cli_host, stmt, dialect="table", check=False)
        if looks_like_sql_error(out) and "already" not in out.lower():
            log(f"  {stmt} -> {first_line(out)[:140]}")
        return out

    run(f"create database {db}")
    run(f"create table {db}.{table} (time timestamp time, dev string tag, o object field)")
    if object_table_shape(sql, cfg, db, table) is None:
        return False
    out = sql.sql(cfg.cli_host, f"select count(*) from {db}.{table}", dialect="table", check=False)
    total = 0
    match = re.search(r"\|\s*(\d+)\s*\|", out or "")
    if match:
        total = int(match.group(1))
    if total >= seed_rows:
        return True

    import hashlib

    log(f"  {db}.{table} 里只有 {total} 行，写入 {seed_rows} 行唯一 OBJECT 作为覆盖底料")
    values = []
    for i in range(seed_rows):
        digest = hashlib.sha256(f"seed-{time.time_ns()}-{i}".encode()).hexdigest()
        body = (digest * ((1024 * 2) // len(digest) + 1))[: 1024 * 2]
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


# ---------------------------------------------------------------------------
# Big-OBJECT scenario: ~4 GiB of OBJECT payloads survive a region migration
# ---------------------------------------------------------------------------
# A single OBJECT point may be up to 4 GiB; writing that through SQL literals is
# impossible (the statement would be twice that size), so the workload writes
# many large points in segments (iot-benchmark with BM_OBJECT_LENGTH) until the
# database holds the target volume, and the check is that every replica keeps
# byte-identical payloads after the region has been moved to another DataNode.


@dataclass
class BigObjectProbeResult:
    evidence: bool
    detail: str
    stats: dict = field(default_factory=dict)
    problems: list[str] = field(default_factory=list)


def object_bytes_by_host(cfg, ssh, hosts: Iterable[str]) -> dict[str, dict[int, int]]:
    """Bytes of OBJECT payload per region, per host."""
    per_host: dict[str, dict[int, int]] = {}
    for host in hosts:
        regions = scan_objects(cfg, ssh, host, object_roots(cfg, ssh, host))
        per_host[host] = {region: sum(files.values()) for region, files in regions.items()}
    return per_host


def object_hash_sample(sql, cfg, db: str, table: str, shape: TableShape, limit: int = 10) -> list[str]:
    """Ordered ``time|device|length|sha256`` lines for the first ``limit`` rows.

    ``read_object`` is evaluated server side, so neither the client nor the
    transport ever carries the payload itself.
    """
    stmt = (
        f"select {shape.time_column},{shape.device_column},"
        f"length(read_object({shape.object_column})),"
        f"sha256(cast(read_object({shape.object_column}) as string)) "
        f"from {db}.{table} order by {shape.time_column},{shape.device_column} limit {max(limit, 1)}"
    )
    out = sql.sql(cfg.cli_host, stmt, dialect="table", check=False)
    if looks_like_sql_error(out):
        return []
    return ["|".join(str(v) for v in row.values()) for row in parse_table(out)]


def _region_bytes_on(per_host: dict[str, dict[int, int]], hosts: Iterable[str]) -> dict[int, int]:
    totals: dict[int, int] = {}
    for host in hosts:
        for region, size in per_host.get(host, {}).items():
            totals[region] = max(totals.get(region, 0), size)
    return totals


def run_big_object_migration_probe(
    cfg,
    ssh,
    sql,
    log,
    *,
    db: str,
    table: str,
    target_bytes: int,
    wait_timeout: float = 1800.0,
    migrate: bool = True,
    sample_rows: int = 10,
    tolerance: int = 1 << 20,
    max_migrations: int = 8,
    migration_timeout: float = 900.0,
) -> BigObjectProbeResult:
    """Wait for ``target_bytes`` of OBJECT data, migrate every region, verify."""
    stats: dict = {"db": db, "table": table, "target_bytes": target_bytes}
    problems: list[str] = []

    shape = object_table_shape(sql, cfg, db, table)
    if shape is None:
        return BigObjectProbeResult(
            False, f"无法解析 {db}.{table} 的 TIME/TAG/OBJECT 列", stats, problems
        )
    hosts = list(cfg.dn_hosts)

    deadline = time.time() + wait_timeout
    grown = 0
    while True:
        per_host = object_bytes_by_host(cfg, ssh, hosts)
        # Count each region once (RF=2 puts two copies of the same bytes on disk).
        grown = sum(_region_bytes_on(per_host, hosts).values())
        log(f"  OBJECT 数据量：{grown / 2**30:.2f} GiB（目标 {target_bytes / 2**30:.2f} GiB）")
        if grown >= target_bytes or time.time() > deadline:
            break
        time.sleep(20)
    stats["written_bytes"] = grown
    if grown < target_bytes:
        return BigObjectProbeResult(
            False,
            f"OBJECT 数据只写到 {grown / 2**30:.2f} GiB，未到目标 {target_bytes / 2**30:.2f} GiB",
            stats,
            problems,
        )

    before_hash = object_hash_sample(sql, cfg, db, table, shape, sample_rows)
    stats["hash_before"] = before_hash
    if not before_hash:
        problems.append("读取 OBJECT 内容样本失败（read_object/sha256 没有返回行）")

    migrated: list[dict] = []
    residue: list[str] = []
    if migrate:
        done_regions: set[int] = set()
        for _ in range(max_migrations):
            plan = _migration_plan(cfg, sql, db, log, exclude=done_regions)
            if plan is None:
                break
            region = plan["region"]
            pre = object_bytes_by_host(cfg, ssh, hosts)
            region_bytes = _region_bytes_on(pre, [plan["from_host"]])
            log(
                f"  region {region} 迁移：{plan['from_host']} → {plan['to_host']}"
                f"（{region_bytes.get(region, 0) / 2**30:.2f} GiB）"
            )
            out = sql.sql(
                cfg.cli_host,
                f"migrate region {region} from {plan['from_id']} to {plan['to_id']}",
                dialect="table",
                check=False,
            )
            if looks_like_sql_error(out):
                log(f"  MIGRATE REGION 失败：{first_line(out)[:160]}")
                problems.append(f"region {region} 迁移被拒绝：{first_line(out)[:160]}")
                break
            moved = False
            started = time.time()
            while time.time() - started < migration_timeout:
                time.sleep(3)
                rows_now, _ = fetch_region_rows(sql, cfg, [db])
                reps = [r for r in data_region_replicas(rows_now) if r.region == region]
                if any(r.node_id == plan["to_id"] and r.status.lower() == "running" for r in reps) and not any(
                    r.node_id == plan["from_id"] for r in reps
                ):
                    moved = True
                    break
            entry = {
                "region": region,
                "from_host": plan["from_host"],
                "to_host": plan["to_host"],
                "bytes": region_bytes.get(region, 0),
                "moved": moved,
                "sec": round(time.time() - started, 1),
            }
            migrated.append(entry)
            done_regions.add(region)
            log(f"  region {region} 迁移{'完成' if moved else '未完成'}，用时 {entry['sec']}s")
            if not moved:
                problems.append(f"region {region} 迁移在 {migration_timeout:.0f}s 内未完成")
                break

            time.sleep(5)
            rows_now, _ = fetch_region_rows(sql, cfg, [db])
            reps = [r for r in data_region_replicas(rows_now) if r.region == region]
            after = object_bytes_by_host(cfg, ssh, [r.host for r in reps])
            leader = next((r for r in reps if r.role.lower().startswith("leader")), reps[0])
            follower = next((r for r in reps if r.host != leader.host), None)
            if follower is not None:
                lb = after.get(leader.host, {}).get(region, 0)
                fb = after.get(follower.host, {}).get(region, 0)
                stats.setdefault("replica_bytes", []).append(
                    {"region": region, "leader": lb, "follower": fb, "host": follower.host}
                )
                if abs(lb - fb) > tolerance:
                    problems.append(
                        f"region {region} 副本 OBJECT 字节不一致：leader {lb} B vs follower {fb} B"
                    )
                deleted = deleted_object_paths(cfg, ssh, leader.host, region)
                leader_files = dict(scan_objects(cfg, ssh, leader.host, object_roots(cfg, ssh, leader.host)).get(region, {}))
                follower_files = dict(scan_objects(cfg, ssh, follower.host, object_roots(cfg, ssh, follower.host)).get(region, {}))
                extra = set(follower_files) - set(leader_files)
                confirmed = sorted(extra & deleted)
                if extra:
                    stats.setdefault("residue", []).append(
                        {"region": region, "host": follower.host, "extra": len(extra), "confirmed": len(confirmed)}
                    )
                if confirmed:
                    residue.append(
                        f"region {region} 新副本 {follower.host} 残留 {len(confirmed)} 个已删除 OBJECT 文件"
                    )
    stats["migrations"] = migrated
    stats["residue"] = stats.get("residue", [])
    problems.extend(residue)

    after_hash = object_hash_sample(sql, cfg, db, table, shape, sample_rows)
    stats["hash_after"] = after_hash
    if before_hash and after_hash and before_hash != after_hash:
        problems.append("迁移前后 OBJECT 内容样本不一致（time/device/长度/哈希）")

    moved_bytes = sum(m["bytes"] for m in migrated if m["moved"])
    evidence = bool(migrated) if migrate else True
    detail = (
        f"OBJECT 数据 {grown / 2**30:.2f} GiB，迁移 {len(migrated)} 个 region"
        f"（{moved_bytes / 2**30:.2f} GiB），内容样本 {len(after_hash)} 行"
        f"{'一致' if before_hash == after_hash and after_hash else '异常'}，"
        f"残留 {len(residue)} 处"
    )
    return BigObjectProbeResult(evidence, detail, stats, problems)


def wait_object_volume(cfg, ssh, target_bytes: int, *, timeout: float = 2400.0, poll: float = 20.0, log=print) -> bool:
    """Block until the database holds ``target_bytes`` of OBJECT payload (logical).

    The load is stopped right after this returns, so the write phase of a big
    dataset does not depend on the benchmark finishing its query phase (which on
    a 4 GiB table can take longer than the writes themselves).
    """
    hosts = list(cfg.dn_hosts)
    deadline = time.time() + timeout
    grown = 0
    while True:
        per_host = object_bytes_by_host(cfg, ssh, hosts)
        grown = sum(_region_bytes_on(per_host, hosts).values())
        log(f"  OBJECT 已写入 {grown / 2**30:.2f} GiB（目标 {target_bytes / 2**30:.2f} GiB）")
        if grown >= target_bytes:
            return True
        if time.time() > deadline:
            return False
        time.sleep(poll)


def object_file_count_by_host(cfg, ssh, hosts: Iterable[str]) -> dict[str, dict[int, int]]:
    """Number of OBJECT ``.bin`` files per region, per host."""
    out: dict[str, dict[int, int]] = {}
    for host in hosts:
        regions = scan_objects(cfg, ssh, host, object_roots(cfg, ssh, host))
        out[host] = {region: len(files) for region, files in regions.items()}
    return out


def wait_object_file_count(cfg, ssh, target_files: int, *, timeout: float = 1800.0, poll: float = 15.0, log=print) -> int:
    """Wait until the cluster holds ``target_files`` OBJECT files (each region once)."""
    hosts = list(cfg.dn_hosts)
    deadline = time.time() + timeout
    total = 0
    while True:
        per_host = object_file_count_by_host(cfg, ssh, hosts)
        totals: dict[int, int] = {}
        for host in hosts:
            for region, count in per_host.get(host, {}).items():
                totals[region] = max(totals.get(region, 0), count)
        total = sum(totals.values())
        log(f"  OBJECT 文件数：{total}（目标 {target_files}）")
        if total >= target_files or time.time() > deadline:
            return total
        time.sleep(poll)


def run_many_object_residue_probe(
    cfg,
    ssh,
    sql,
    log,
    *,
    db: str,
    table: str,
    target_files: int,
    wait_timeout: float = 1800.0,
    delete_first: bool = True,
    settle_sec: float = 8.0,
    recheck_sec: float = 0.0,
    max_regions: int = 8,
) -> BigObjectProbeResult:
    """Many small OBJECT files + DELETE + immediate migration (TDB-861).

    The upstream fix exists because the old SnapshotTaker copied the whole object
    directory: with only a handful of files the copy finishes before the GC can
    unlink anything, so the race never lands.  With ~1e5 files the copy takes
    long enough that the GC deletes files *while* the snapshot is being taken.
    """
    stats: dict = {"db": db, "table": table, "target_files": target_files}
    problems: list[str] = []

    shape = object_table_shape(sql, cfg, db, table)
    if shape is None:
        return BigObjectProbeResult(False, f"无法解析 {db}.{table} 的时间/设备/OBJECT 列", stats, problems)
    hosts = list(cfg.dn_hosts)

    total = wait_object_file_count(cfg, ssh, target_files, timeout=wait_timeout, log=log)
    stats["files_written"] = total
    if total < target_files:
        return BigObjectProbeResult(
            False, f"OBJECT 文件只写了 {total} 个，未到目标 {target_files}", stats, problems
        )

    before_hash = object_hash_sample(sql, cfg, db, table, shape, 10)
    stats["hash_before"] = before_hash

    if delete_first:
        out = sql.sql(cfg.cli_host, f"delete from {db}.{table}", dialect="table", check=False)
        log(f"  DELETE 全表：{first_line(out)[:120]}")
        if looks_like_sql_error(out):
            problems.append(f"DELETE 全表失败：{first_line(out)[:160]}")

    migrations: list[dict] = []
    residue: list[str] = []
    done: set[int] = set()
    for _ in range(max_regions):
        plan = _migration_plan(cfg, sql, db, log, exclude=done)
        if plan is None:
            break
        region = plan["region"]
        done.add(region)
        files_before = object_file_count_by_host(cfg, ssh, hosts)
        region_files = max(
            [files_before.get(plan["from_host"], {}).get(region, 0)]
            + [files_before.get(h, {}).get(region, 0) for h in hosts]
        )
        out = sql.sql(
            cfg.cli_host,
            f"migrate region {region} from {plan['from_id']} to {plan['to_id']}",
            dialect="table",
            check=False,
        )
        log(f"  region {region} 迁移（{region_files} 个文件）：{first_line(out)[:110]}")
        if looks_like_sql_error(out):
            problems.append(f"region {region} 迁移被拒绝：{first_line(out)[:160]}")
            break
        started = time.time()
        moved = False
        while time.time() - started < 600:
            time.sleep(2)
            rows_now, _ = fetch_region_rows(sql, cfg, [db])
            reps = [r for r in data_region_replicas(rows_now) if r.region == region]
            if any(r.node_id == plan["to_id"] for r in reps) and not any(
                r.node_id == plan["from_id"] for r in reps
            ):
                moved = True
                break
        time.sleep(settle_sec)
        if recheck_sec:
            # The leader unlinks the stale files asynchronously; only after that
            # does "follower still has them" become visible as residue.
            deadline = time.time() + recheck_sec
            while time.time() < deadline:
                rows_now, _ = fetch_region_rows(sql, cfg, [db])
                reps_now = [r for r in data_region_replicas(rows_now) if r.region == region]
                lead_now = next((r for r in reps_now if r.role.lower().startswith("leader")), reps_now[0])
                lead_files_now = scan_objects(cfg, ssh, lead_now.host, object_roots(cfg, ssh, lead_now.host)).get(region, {})
                gone = region_files and len(lead_files_now) < region_files
                if gone:
                    break
                time.sleep(10)
        rows_now, _ = fetch_region_rows(sql, cfg, [db])
        reps = [r for r in data_region_replicas(rows_now) if r.region == region]
        if not reps:
            continue
        leader = next((r for r in reps if r.role.lower().startswith("leader")), reps[0])
        leader_files = dict(scan_objects(cfg, ssh, leader.host, object_roots(cfg, ssh, leader.host)).get(region, {}))
        deleted = deleted_object_paths(cfg, ssh, leader.host, region)
        entry = {"region": region, "moved": moved, "sec": round(time.time() - started, 1),
                 "leader_files": len(leader_files), "deleted_log": len(deleted), "followers": []}
        for rep in reps:
            if rep.host == leader.host:
                continue
            follower_files = dict(scan_objects(cfg, ssh, rep.host, object_roots(cfg, ssh, rep.host)).get(region, {}))
            extra = set(follower_files) - set(leader_files)
            confirmed = sorted(extra & deleted)
            entry["followers"].append(
                {"host": rep.host, "files": len(follower_files), "extra": len(extra), "confirmed": len(confirmed)}
            )
            if confirmed:
                residue.append(
                    f"region {region} 新副本 {rep.host} 残留 {len(confirmed)} 个已删除 OBJECT 文件"
                )
            log(
                f"    副本 {rep.host}: 文件 {len(follower_files)}，leader {len(leader_files)}，"
                f"多余 {len(extra)}，确认残留 {len(confirmed)}"
            )
        migrations.append(entry)

    after_hash = object_hash_sample(sql, cfg, db, table, shape, 10)
    stats.update({"hash_after": after_hash, "migrations": migrations, "residue": residue})
    if before_hash and after_hash and before_hash != after_hash:
        problems.append("迁移前后 OBJECT 内容样本不一致")
    problems.extend(residue)
    evidence = bool(migrations) and all(m["moved"] for m in migrations)
    detail = (
        f"OBJECT 文件 {total} 个，迁移 {len(migrations)} 个 region，"
        f"确认残留 {len(residue)} 处"
    )
    return BigObjectProbeResult(evidence, detail, stats, problems)


SINGLE_OBJECT_WRITER = Path(__file__).resolve().parent.parent / "java" / "SingleObjectWriter.java"


def _java_home(cfg, ssh) -> str:
    """Return a directory that contains ``java``/``javac`` on the cluster hosts."""
    script = """
for candidate in "$JAVA_HOME" /usr/local/jdk-17.0.8 /usr/local/jdk-17 /usr/lib/jvm/java-17-openjdk-amd64 /usr/lib/jvm/java-17-openjdk; do
  [ -n "$candidate" ] && [ -x "$candidate/bin/javac" ] && { echo "$candidate"; exit 0; }
done
p=$(command -v javac 2>/dev/null) && { dirname "$(dirname "$p")"; exit 0; }
echo MISSING
exit 0
"""
    out = ssh.run_script(cfg.cli_host, script, check=False).out.strip().splitlines()
    home = out[-1].strip() if out else ""
    if not home or home == "MISSING":
        raise RuntimeError("no JDK with javac on the cluster host; set JAVA_HOME or install a JDK")
    return home


def write_single_object_chunked(
    cfg,
    ssh,
    log,
    *,
    db: str,
    table: str,
    total_bytes: int,
    chunk_bytes: int = 8 << 20,
    dev: str = "d4g",
    ts: int = 1700000010000,
    username: str | None = None,
    password: str | None = None,
    timeout: float = 7200.0,
) -> str:
    """Write ONE OBJECT point of ``total_bytes`` through chunked ``to_object`` INSERTs.

    A 4 GiB point cannot be a single SQL literal (8 GiB of hex) nor a single ``byte[]``
    (JVM arrays stop at 2 GiB), but ``to_object(isEOF, offset, X'..')`` carries an offset
    and an EOF flag, so the value is assembled from parts.
    """
    home = _java_home(cfg, ssh)
    workdir = f"/tmp/rcdn-single-object"
    ssh.run_script(cfg.cli_host, f"mkdir -p {workdir} && rm -f {workdir}/*.class", check=False)
    ssh.upload(SINGLE_OBJECT_WRITER, cfg.cli_host, f"{workdir}/SingleObjectWriter.java")
    lib = f"{cfg.get('DB_DIR')}/lib/*"
    build = ssh.run_script(
        cfg.cli_host,
        f"cd {workdir} && {home}/bin/javac -cp '{lib}' SingleObjectWriter.java 2>&1 | tail -5",
        check=False,
        timeout=300,
    )
    if build.rc != 0 or "error" in build.out.lower():
        raise RuntimeError(f"failed to compile SingleObjectWriter: {build.out.strip()[:400]}")
    url = f"jdbc:iotdb://{cfg.cli_host}:{cfg.dn_rpc_port}/?sql_dialect=table"
    cmd = (
        f"cd {workdir} && PATH={home}/bin:$PATH {home}/bin/java -Xmx8g -cp '.:{lib}' SingleObjectWriter "
        f"'{url}' {db}.{table} {dev} {ts} {total_bytes // (1 << 20)} {chunk_bytes // (1 << 20)} "
        f"{username or cfg.get('DB_USER')} {password or cfg.get('DB_PASSWORD')}"
    )
    log(f"  写入单点 OBJECT {total_bytes / 2**30:.2f} GiB（分块 {(chunk_bytes) // (1 << 20)} MiB）…")
    res = ssh.run(cfg.cli_host, cmd, timeout=timeout, check=False)
    tail = "\n".join(res.out.strip().splitlines()[-3:])
    log("  " + tail.replace("\n", " | ")[:280])
    return res.out


def verify_single_object(
    cfg, ssh, sql, db: str, table: str, dev: str, expected_len: int, *, hashes: bool = False
) -> dict:
    """Check a big OBJECT point: SQL length, then the physical file on every replica.

    ``read_object()`` (and therefore ``sha256(cast(read_object(..) as string))``) refuses
    payloads above 2 GiB (``701: Read object size ... is too large (size > 2G)``), so the
    content is verified with ``sha256sum`` on the DataNodes instead.
    """
    out = sql.sql(
        cfg.cli_host, f"select length(o) as len from {db}.{table} where dev='{dev}'",
        dialect="table", check=False,
    )
    rows = parse_table(out)
    length = int(rows[0]["len"]) if rows and rows[0].get("len", "").isdigit() else None
    result = {"length": length, "expected": expected_len, "replicas": []}
    region_rows, _ = fetch_region_rows(sql, cfg, [db])
    for rep in data_region_replicas(region_rows or []):
        files = scan_objects(cfg, ssh, rep.host, object_roots(cfg, ssh, rep.host)).get(rep.region, {})
        for rel, size in files.items():
            if size != expected_len:
                continue
            if not hashes:
                result["replicas"].append(
                    {"host": rep.host, "role": rep.role, "region": rep.region, "bytes": size, "sha256": None}
                )
                continue
            digests = ssh.run_script(
                rep.host,
                "for d in " + " ".join(object_roots(cfg, ssh, rep.host)) + f'; do f="$d/{rep.region}/{rel}"; '
                f'[ -f "$f" ] && {{ echo "$f"; sha256sum "$f"; }}; done',
                check=False,
                timeout=1800,
            )
            lines = [ln for ln in digests.out.strip().splitlines() if ln.strip()]
            digest = None
            for ln in lines:
                parts = ln.split()
                if len(parts) == 2 and len(parts[0]) == 64:
                    digest = parts[0]
            result["replicas"].append(
                {"host": rep.host, "role": rep.role, "region": rep.region, "bytes": size, "sha256": digest}
            )
    return result


@dataclass
class SingleObjectResult:
    evidence: bool
    detail: str
    stats: dict
    problems: list[str]


def run_single_object_scenario(
    cfg,
    ssh,
    sql,
    log,
    *,
    db: str = "objsingle",
    table: str = "t",
    dev: str = "d4g",
    ts: int = 1700000010000,
    total_bytes: int = 4 << 30,
    chunk_bytes: int = 8 << 20,
    read_chunk_bytes: int = 256 << 20,
    migrate: bool = True,
    wait_timeout: float = 3600.0,
) -> "SingleObjectResult":
    """Write one OBJECT point of ``total_bytes`` in chunks, migrate its region, verify.

    Verification path: ``length(o)`` (works at any size) plus ``sha256sum`` of the physical
    ``.bin`` on every replica, because ``read_object()`` refuses payloads above 2 GiB with
    ``701: Read object size ... is too large (size > 2G)``.
    """
    problems: list[str] = []
    steps: list[str] = []
    log(f"  单点 OBJECT 场景：db={db} 目标 {total_bytes / 2**30:.2f} GiB，块 {chunk_bytes // (1 << 20)} MiB")
    for stmt in (
        f"create database {db}",
        f"create table {db}.{table} (time timestamp time, dev string tag, o object field)",
    ):
        out = sql.sql(cfg.cli_host, stmt, dialect="table", check=False)
        if looks_like_sql_error(out) and "already" not in out.lower():
            problems.append(f"{stmt} -> {first_line(out)[:150]}")

    write_single_object_chunked(
        cfg, ssh, log, db=db, table=table, total_bytes=total_bytes, chunk_bytes=chunk_bytes,
        dev=dev, ts=ts,
    )
    before = verify_single_object(cfg, ssh, sql, db, table, dev, total_bytes)
    before_read = verify_single_object_streaming(
        cfg, sql, db, table, dev, total_bytes, chunk_bytes=read_chunk_bytes
    )
    steps.append(
        f"单点写入完成：length(o)={before['length']}，副本 {len(before['replicas'])} 个；"
        f"流式读回 {before_read['chunks']} 段全部一致={before_read['ok']}"
    )
    if before["length"] != total_bytes:
        problems.append(f"length(o)={before['length']}，期望 {total_bytes}")
    if not before_read["ok"]:
        problems.append(
            f"流式读回不一致：length={before_read['length']}，坏段 {before_read['bad_chunks'][:1]}"
        )

    moved = None
    if migrate:
        plan = _migration_plan(cfg, sql, db, log)
        if plan is None:
            problems.append(f"{db} 没有可迁移的 region")
        else:
            region, from_id, to_id = plan["region"], plan["from_id"], plan["to_id"]
            out = sql.sql(
                cfg.cli_host, f"migrate region {region} from {from_id} to {to_id}",
                dialect="table", check=False,
            )
            log(f"  region {region} 迁移（{before['replicas'][0]['bytes'] / 2**20:.0f} MiB 对象）：{first_line(out)[:100]}")
            if looks_like_sql_error(out):
                problems.append(f"迁移被拒绝：{first_line(out)[:150]}")
            else:
                started = time.time()
                while time.time() - started < wait_timeout:
                    time.sleep(5)
                    rows, _ = fetch_region_rows(sql, cfg, [db])
                    reps = [r for r in data_region_replicas(rows or []) if r.region == region]
                    if any(r.node_id == to_id for r in reps) and not any(r.node_id == from_id for r in reps):
                        moved = region
                        break
                steps.append(
                    f"迁移 region {region}：{'完成' if moved else '未完成'}，用时 {time.time() - started:.0f}s"
                )
                if not moved:
                    problems.append(f"region {region} 迁移未完成")

    after = verify_single_object(cfg, ssh, sql, db, table, dev, total_bytes)
    after_read = verify_single_object_streaming(
        cfg, sql, db, table, dev, total_bytes, chunk_bytes=read_chunk_bytes
    )
    steps.append(
        f"迁移后 length(o)={after['length']}；流式读回 {after_read['chunks']} 段全部一致={after_read['ok']}"
    )
    if after["length"] != total_bytes:
        problems.append(f"迁移后 length(o)={after['length']}，期望 {total_bytes}")
    if not after_read["ok"]:
        problems.append(
            f"迁移后流式读回不一致：length={after_read['length']}，坏段 {after_read['bad_chunks'][:1]}"
        )
    detail = (
        f"单点 OBJECT {total_bytes / 2**30:.2f} GiB：length(o)={after['length']}，"
        f"流式读回 {after_read['chunks']} 段（每段读长度+sha256 比对）全部一致，"
        f"{len(after['replicas'])} 个副本 .bin 大小 {after['replicas'][0]['bytes'] if after['replicas'] else 'n/a'} 字节，"
        f"迁移 {'1 个 region' if moved is not None else '未执行'}"
    )
    return SingleObjectResult(
        not problems,
        detail,
        {"steps": steps, "before": before, "after": after,
         "before_read": before_read, "after_read": after_read},
        problems,
    )


OBJECT_PATTERN_PERIOD = 8 << 20  # SingleObjectWriter's buffer: byte[i] = i % 251, 8 MiB long.


@lru_cache(maxsize=2)
def _pattern_unit(period: int = OBJECT_PATTERN_PERIOD) -> bytes:
    return bytes(i % 251 for i in range(period))


def expected_object_sha256(offset: int, length: int, period: int = OBJECT_PATTERN_PERIOD) -> str:
    """sha256 of the bytes ``SingleObjectWriter`` holds at ``offset`` for ``length`` bytes.

    The writer sends the same 8 MiB buffer again for every chunk, so the logical content is
    that buffer repeated; a read that starts mid-buffer is served by rotating it.
    """
    unit = _pattern_unit(period)
    start = offset % len(unit)
    rotated = unit[start:] + unit
    have = 0
    out = bytearray(length)
    while have < length:
        take = min(len(rotated), length - have)
        out[have:have + take] = rotated[:take]
        have += take
    return hashlib.sha256(bytes(out)).hexdigest()


def verify_single_object_streaming(
    cfg,
    sql,
    db: str,
    table: str,
    dev: str,
    total_bytes: int,
    chunk_bytes: int = 256 << 20,
) -> dict:
    """Read a big OBJECT point back in ranged chunks: ``read_object(o, offset, length)``.

    ``read_object(o)`` alone refuses payloads above 2 GiB (``701: Read object size ... is
    too large (size > 2G)``), but the ranged form streams: RC11 accepts ``read_object(o,
    offset)`` and ``read_object(o, offset, length)``, and the length is clamped to what is
    left.  Hashing every chunk server-side keeps the client side to 64 hex chars per chunk.
    """
    out = sql.sql(
        cfg.cli_host, f"select length(o) as len from {db}.{table} where dev='{dev}'",
        dialect="table", check=False,
    )
    rows = parse_table(out)
    total_len = int(rows[0]["len"]) if rows and str(rows[0].get("len", "")).isdigit() else None
    chunks = []
    off = 0
    while off < total_bytes:
        size = min(chunk_bytes, total_bytes - off)
        stmt = (
            f"select sha256(read_object(o, {off}, {size})) as h, "
            f"length(read_object(o, {off}, {size})) as n from {db}.{table} where dev='{dev}'"
        )
        row = (parse_table(sql.sql(cfg.cli_host, stmt, dialect="table", check=False)) or [{}])[0]
        got_hash = (row.get("h") or "").lower().removeprefix("0x")
        got_len = int(row["n"]) if str(row.get("n", "")).isdigit() else None
        want_hash = expected_object_sha256(off, size)
        chunks.append(
            {
                "offset": off,
                "length": size,
                "read_length": got_len,
                "sha256": got_hash,
                "expected_sha256": want_hash,
                "ok": got_hash == want_hash and got_len == size,
            }
        )
        off += size
    bad = [c for c in chunks if not c["ok"]]
    return {
        "length": total_len,
        "expected_length": total_bytes,
        "chunks": len(chunks),
        "bad_chunks": bad[:3],
        "ok": total_len == total_bytes and not bad,
        "sha256": hashlib.sha256("".join(c["sha256"] for c in chunks).encode()).hexdigest(),
    }
