"""PROACTIVE（RegionGroup 积极扩容）可观测操作层。

设计原则：**一切断言只依赖本模块暴露的可观测量**，且每个方法都把 SQL 原文与原始输出
留在用例的 ``actions.log`` 里（通过 ``self.trace``）。

观测口径（源码依据 `ColumnHeaderConstant.showRegionColumnHeaders:576-591`）：
``SHOW (SCHEMA|DATA) REGIONS`` 每行是**一个副本**，列为
``RegionId | Type | Status | Database | SeriesSlotNum | TimeSlotNum | DataNodeId | RpcAddress |
RpcPort | InternalAddress | Role | CreateTime | TsfileSize | CompressionRatio | ObjectSize``。
⇒ **组数 = 去重后的 RegionId 数**，副本行数 = 组数 × 副本数
（IT 同口径：``IoTDBProactiveRegionGroupDistributionIT:1393-1424``，注释原文
"SHOW REGIONS returns replicas, not logical groups: deduplicate IDs before checking G and 3*G"）。

因此本模块**不会**用"行数"当组数（既有技能里 H-27 类假 PASS 的根因）。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

from .helpers import num
from . import compat13

REGION_ID_COLUMNS = ("RegionId", "region_id", "RegionID", "RegionGroupId")
DATABASE_COLUMNS = ("Database", "database", "DatabaseName")
TYPE_COLUMNS = ("Type", "type")
STATUS_COLUMNS = ("Status", "status")
SERIES_SLOT_COLUMNS = ("SeriesSlotNum", "series_slot_num")
TIME_SLOT_COLUMNS = ("TimeSlotNum", "time_slot_num")
DN_ID_COLUMNS = ("DataNodeId", "data_node_id")
ROLE_COLUMNS = ("Role", "role")


@dataclass
class Outcome:
    statement: str
    output: str
    ok: bool
    dialect: str | None = None
    rows: list[dict[str, str]] = field(default_factory=list)

    @property
    def flat(self) -> str:
        return " ".join(self.output.split())


@dataclass
class RegionGroup:
    """一个逻辑 RegionGroup（同一 RegionId 的全部副本行）。"""

    group_id: str
    database: str
    region_type: str
    status: str = ""
    series_slots: int = 0
    time_slots: int = 0
    replicas: list[str] = field(default_factory=list)
    roles: list[str] = field(default_factory=list)
    raw: list[dict[str, str]] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "group_id": self.group_id,
            "database": self.database,
            "region_type": self.region_type,
            "status": self.status,
            "series_slots": self.series_slots,
            "time_slots": self.time_slots,
            "replicas": sorted(self.replicas),
            "roles": self.roles,
        }


class PgApi:
    """PROACTIVE 用例的操作层（SQL / 策略 / 权限 / benchmark）。"""

    def __init__(self, cfg, sql, ssh, log) -> None:
        self.cfg = cfg
        self.sql = sql
        self.ssh = ssh
        self.log = log
        #: 由 runner 注入，使每条语句落进用例的 actions.log
        self.trace = None
        self._last: Outcome | None = None

    # ================================================================ 执行
    def run(self, statement: str, *, dialect: str | None = None, timeout: int = 300,
            host: str = "", user: str = "", password: str = "") -> Outcome:
        target = host or self.cfg.cli_host
        raw = self.sql.sql(target, statement, dialect=dialect, timeout=timeout,
                           check=False, user=user, password=password)
        from .remote import looks_like_sql_error, parse_table

        error = looks_like_sql_error(raw)
        rows = [] if error else parse_table(raw)
        outcome = Outcome(statement=statement, output=raw, ok=not error,
                          dialect=dialect, rows=rows)
        self._last = outcome
        if self.trace:
            self.trace(statement, raw)
        return outcome

    def run_as(self, user: str, password: str, statement: str, *,
               dialect: str | None = None, timeout: int = 300) -> Outcome:
        """以另一个用户执行语句（权限用例；普通用户 pg_normal 无 SYSTEM）。"""
        return self.run(statement, dialect=dialect, timeout=timeout,
                        user=user, password=password)

    @staticmethod
    def header(output: str) -> list[str]:
        for line in output.splitlines():
            stripped = line.strip()
            if stripped.startswith("|") and not re.match(r"^\|[-+|\s]+\|?$", stripped):
                return [c.strip() for c in stripped.strip("|").split("|")]
        return []

    @staticmethod
    def column(rows: list[dict[str, str]], *names: str) -> str:
        if not rows:
            return ""
        wanted = {n.lower() for n in names}
        for key in rows[0]:
            if key.strip().lower() in wanted:
                return key
        return ""

    # ============================================================ 区域组观测
    def show_regions(self, db: str = "", *, kind: str = "DATA", dialect: str = "tree",
                     node_id: int | None = None, timeout: int = 120) -> Outcome:
        """``SHOW (SCHEMA|DATA) REGIONS``：树 ``OF DATABASE`` / 表 ``FROM``。

        ``db`` 为空时查全集群（系统库也会出现，供 PG-SYS 族如实记录）。
        """
        kind_sql = "SCHEMA" if kind.upper().startswith("S") else "DATA"
        tree = dialect != "table"
        if db:
            clause = f" OF DATABASE {db}" if tree else f" FROM {db}"
        else:
            clause = ""
        node_clause = f" ON NODEID {node_id}" if node_id else ""
        stmt = f"show {kind_sql.lower()} regions{clause}{node_clause}"
        if not tree:
            stmt = f"show {kind_sql.lower()} regions{clause}"
        return self.run(stmt, dialect=dialect, timeout=timeout)

    def groups(self, db: str = "", *, kind: str = "DATA", dialect: str = "tree",
               node_id: int | None = None) -> dict[str, RegionGroup]:
        """按 RegionId 去重后的逻辑 RegionGroup 表。"""
        outcome = self.show_regions(db, kind=kind, dialect=dialect, node_id=node_id)
        result: dict[str, RegionGroup] = {}
        if not outcome.ok:
            return result
        id_col = self.column(outcome.rows, *REGION_ID_COLUMNS)
        if not id_col:
            return result
        db_col = self.column(outcome.rows, *DATABASE_COLUMNS)
        type_col = self.column(outcome.rows, *TYPE_COLUMNS)
        status_col = self.column(outcome.rows, *STATUS_COLUMNS)
        series_col = self.column(outcome.rows, *SERIES_SLOT_COLUMNS)
        time_col = self.column(outcome.rows, *TIME_SLOT_COLUMNS)
        dn_col = self.column(outcome.rows, *DN_ID_COLUMNS)
        role_col = self.column(outcome.rows, *ROLE_COLUMNS)
        for row in outcome.rows:
            gid = row.get(id_col, "").strip()
            if not gid:
                continue
            group = result.get(gid)
            if group is None:
                group = RegionGroup(group_id=gid,
                                    database=(row.get(db_col, "").strip() if db_col else ""),
                                    region_type=(row.get(type_col, "").strip() if type_col else kind))
                result[gid] = group
            if status_col:
                group.status = row.get(status_col, "").strip() or group.status
            if series_col:
                group.series_slots = max(group.series_slots, int(num(row.get(series_col, "0"))))
            if time_col:
                group.time_slots = max(group.time_slots, int(num(row.get(time_col, "0"))))
            if dn_col:
                dn = row.get(dn_col, "").strip()
                if dn and dn not in group.replicas:
                    group.replicas.append(dn)
            if role_col:
                role = row.get(role_col, "").strip()
                if role and role not in group.roles:
                    group.roles.append(role)
            group.raw.append(row)
        return result

    def group_count(self, db: str = "", *, kind: str = "DATA", dialect: str = "tree") -> int:
        return len(self.groups(db, kind=kind, dialect=dialect))

    def group_ids(self, db: str = "", *, kind: str = "DATA", dialect: str = "tree") -> set[str]:
        return set(self.groups(db, kind=kind, dialect=dialect))

    def replica_count(self, db: str = "", *, kind: str = "DATA", dialect: str = "tree") -> int:
        """副本行数（= 组数 × 副本数；用于 PG-OBS-04 口径自证）。"""
        outcome = self.show_regions(db, kind=kind, dialect=dialect)
        if not outcome.ok:
            return -1
        id_col = self.column(outcome.rows, *REGION_ID_COLUMNS)
        if not id_col:
            return -1
        return sum(1 for r in outcome.rows if r.get(id_col, "").strip())

    def slot_counts(self, db: str, *, kind: str = "DATA", dialect: str = "tree") -> dict[str, int]:
        return {gid: g.series_slots for gid, g in self.groups(db, kind=kind, dialect=dialect).items()}

    # ---------------------------------------------------------------- 库级详情
    def database_details(self, dialect: str = "tree") -> dict[str, dict[str, str]]:
        """``SHOW DATABASES DETAILS``（表模型回落 ``information_schema.databases``）。

        列（`ColumnHeaderConstant.showDatabasesDetailColumnHeaders:521-534`）：
        ``Database | SchemaReplicationFactor | DataReplicationFactor | TimePartitionOrigin |
        TimePartitionInterval | SchemaRegionGroupNum | MaxSchemaRegionGroupNum |
        DataRegionGroupNum | MaxDataRegionGroupNum | NeedLastCache``
        ⇒ **组数与上限都是直接可观测的**，不必靠副本行数推断。
        """
        outcome = self.run("show databases details", dialect=dialect)
        rows = outcome.rows if outcome.ok else []
        if not rows and dialect == "table":
            outcome = self.run("select * from information_schema.databases", dialect="table")
            rows = outcome.rows if outcome.ok else []
        # UPG-1.3: 1.3 的 `SHOW DATABASES` 只有 5 列（Database / SchemaReplicationFactor /
        # DataReplicationFactor / TimePartitionOrigin / TimePartitionInterval），没有组数列；
        # 但 `SHOW DATABASES DETAILS` 在 1.3.7 里是**存在**的（包内 IoTDBSqlParser 的
        # ShowDatabasesContext 带 DETAILS 终结符，showStorageGroupsDetailColumnHeaders 含
        # SchemaRegionGroupNum…）。因此这里只在 details **真的不可用**（无行/报错）且确认
        # 是 1.3 线时回落到 `show databases`，只为拿到库名；组数由 cases_upg 用
        # `SHOW REGIONS` 去重另算，2.x 分支完全不变。
        if not rows and dialect != "table" and compat13.conf_says_v13(self.cfg):
            outcome = self.run("show databases", dialect=dialect)
            rows = outcome.rows if outcome.ok else []
        db_col = self.column(rows, "Database", "database", "database_name")
        return {r.get(db_col, "").strip(): r for r in rows
                if db_col and r.get(db_col, "").strip()}

    def db_group_num(self, db: str, kind: str, *, dialect: str = "tree") -> int:
        """库详情里的组数（``SchemaRegionGroupNum`` / ``DataRegionGroupNum``）。"""
        row = self.database_details(dialect).get(db)
        if not row:
            return -1
        names = ("SchemaRegionGroupNum", "schema_region_group_num") if kind.upper().startswith("S") \
            else ("DataRegionGroupNum", "data_region_group_num")
        col = self.column([row], *names)
        return int(num(row.get(col, "-1"))) if col else -1

    def db_max_group_num(self, db: str, kind: str, *, dialect: str = "tree") -> int:
        """库详情里的上限（``MaxSchemaRegionGroupNum`` / ``MaxDataRegionGroupNum``）。"""
        row = self.database_details(dialect).get(db)
        if not row:
            return -1
        names = ("MaxSchemaRegionGroupNum", "max_schema_region_group_num") \
            if kind.upper().startswith("S") else ("MaxDataRegionGroupNum", "max_data_region_group_num")
        col = self.column([row], *names)
        return int(num(row.get(col, "-1"))) if col else -1

    def db_time_partition_interval(self, db: str, *, dialect: str = "tree") -> int:
        row = self.database_details(dialect).get(db)
        if not row:
            return -1
        col = self.column([row], "TimePartitionInterval", "time_partition_interval")
        return int(num(row.get(col, "-1"))) if col else -1

    def statuses(self, db: str, *, kind: str = "DATA", dialect: str = "tree") -> dict[str, str]:
        return {gid: g.status for gid, g in self.groups(db, kind=kind, dialect=dialect).items()}

    def snapshot(self, db: str, *, kind: str = "DATA", dialect: str = "tree") -> dict:
        """写证据用：组数、每组 slot 数、副本、状态、原始行。"""
        groups = self.groups(db, kind=kind, dialect=dialect)
        return {
            "database": db,
            "kind": kind,
            "dialect": dialect,
            "group_count": len(groups),
            "replica_rows": sum(len(g.raw) for g in groups.values()),
            "groups": [g.as_dict() for g in sorted(groups.values(), key=lambda g: g.group_id)],
        }

    def snapshot_all(self, dbs, *, dialect: str = "tree") -> dict:
        return {kind: {db: self.snapshot(db, kind=kind, dialect=dialect) for db in dbs}
                for kind in ("SCHEMA", "DATA")}

    # ======================================================== 设备 → 组映射
    def device_region_id(self, device: str, *, dialect: str = "tree",
                         time_range: str = "", timeout: int = 120) -> Outcome:
        clause = f" and {time_range}" if time_range else ""
        return self.run(f"show data regionid where device={device}{clause}",
                        dialect=dialect, timeout=timeout)

    def device_group(self, device: str, *, dialect: str = "tree",
                     time_range: str = "") -> str:
        """设备当前所属 DataRegionGroup 的 RegionId（失败返回 ""）。

        H-21b：``show data regionid where device=…`` **只认完整设备路径**（``root.db.dev``）；
        传短名（``dev``）或测量路径（``root.db.dev.s0``）都会返回空集。此处对短名直接留痕，
        避免调用点再次拿到"全空串"而把它误当产品行为。
        """
        if "." not in device:
            self._last_error = f"device_group: 需要完整设备路径，收到短名 {device!r}"
            return ""
        outcome = self.device_region_id(device, dialect=dialect, time_range=time_range)
        if not outcome.ok or not outcome.rows:
            return ""
        col = self.column(outcome.rows, *REGION_ID_COLUMNS)
        return outcome.rows[0].get(col, "").strip() if col else ""

    def device_groups(self, devices, *, dialect: str = "tree") -> dict[str, str]:
        return {d: self.device_group(d, dialect=dialect) for d in devices}

    def timeslot_count(self, *, device: str = "", db: str = "", region_id: str = "",
                       dialect: str = "tree", start: int | None = None,
                       end: int | None = None) -> int:
        where = ""
        if device:
            where = f"device={device}"
        elif region_id:
            where = f"regionid={region_id}"
        elif db:
            where = f"database={db}"
        else:
            return -1
        if start is not None:
            where += f" and starttime={start}"
        if end is not None:
            where += f" and endtime={end}"
        outcome = self.run(f"count timeslotid where {where}", dialect=dialect)
        if not outcome.ok or not outcome.rows:
            return -1
        for value in outcome.rows[0].values():
            m = re.search(r"-?\d+", str(value))
            if m:
                return int(m.group(0))
        return -1

    # ============================================================== 策略配置
    def set_config(self, key: str, value: str, *, user: str = "", password: str = "",
                   timeout: int = 120) -> Outcome:
        """热加载单个键（需求 §3.2：一次一个键、不得指定单节点）。"""
        return self.run(f'set configuration "{key}"="{value}"', timeout=timeout,
                        user=user or self.cfg.raw("DB_USER"),
                        password=password or self.cfg.raw("DB_PASSWORD"))

    def set_config_raw(self, entries: str, *, user: str = "", password: str = "",
                       timeout: int = 120) -> Outcome:
        """原样提交（用于"两条键写一条语句"等非法形态用例）。"""
        return self.run(f"set configuration {entries}", timeout=timeout,
                        user=user or self.cfg.raw("DB_USER"),
                        password=password or self.cfg.raw("DB_PASSWORD"))

    def set_config_on_node(self, key: str, value: str, node_id: int) -> Outcome:
        return self.run(f'set configuration "{key}"="{value}" on {node_id}')

    POLICY_KEYS = ("schema_region_group_extension_policy",
                   "data_region_group_extension_policy",
                   "default_schema_region_group_num_per_database",
                   "default_data_region_group_num_per_database",
                   "schema_region_per_data_node",
                   "data_region_per_data_node",
                   "series_slot_num",
                   "time_partition_interval",
                   "data_partition_allocation_strategy")

    def policies_on_disk(self, props, hosts=None) -> dict[str, dict[str, str]]:
        """逐节点直接读 conf 文件里的策略键 —— 比 ``SHOW CONFIGURATION`` 更硬的自证。"""
        return {host: props.read(host, keys=self.POLICY_KEYS)
                for host in (hosts or (self.cfg.cn_hosts + self.cfg.dn_hosts))}

    # ============================================================ 用户与权限
    def create_user(self, user: str, password: str) -> Outcome:
        return self.run(f"create user {user} '{password}'")

    def drop_user(self, user: str) -> Outcome:
        return self.run(f"drop user {user}")

    def grant_system(self, user: str) -> Outcome:
        return self.run(f"grant system to user {user}")

    def revoke_system(self, user: str) -> Outcome:
        return self.run(f"revoke system from user {user}")

    def grant_write(self, db: str, user: str, *, dialect: str = "tree") -> Outcome:
        target = f"root.{db}" if dialect != "table" and not db.startswith("root.") else db
        return self.run(f"grant write on {target}.** to user {user}", dialect=dialect)

    def grant_all(self, user: str) -> Outcome:
        return self.run(f"grant all to user {user}")

    # ============================================================== 库 / 表
    def create_database(self, db: str, *, table: bool = False, extra: str = "") -> Outcome:
        return self.run(f"create database {db}{extra}", dialect="table" if table else None)

    def drop_database(self, db: str, *, table: bool = False) -> Outcome:
        if table:
            return self.run(f"drop database if exists {db}", dialect="table")
        return self.run(f"drop database {db}")

    def create_timeseries(self, path: str, dtype: str = "FLOAT") -> Outcome:
        return self.run(f"create timeseries {path} with datatype={dtype}, "
                        f"encoding=PLAIN, compression=SNAPPY")

    def show_timeseries(self, pattern: str = "root.**") -> Outcome:
        return self.run(f"show timeseries {pattern}", dialect="tree")

    def create_table(self, db: str, table: str,
                     columns: str = "devid STRING TAG, s0 FLOAT FIELD", extra: str = "") -> Outcome:
        return self.run(f"create table {db}.{table} ({columns}){extra}", dialect="table")

    def show_tables(self, db: str) -> Outcome:
        return self.run(f"show tables from {db}", dialect="table")

    # ================================================================ 写入
    def insert_tree(self, device: str, stamp: int, measurements: list[str],
                    values: list) -> Outcome:
        cols = ", ".join(measurements)
        vals = ", ".join(str(v) for v in values)
        return self.run(f"insert into {device}(timestamp, {cols}) values({stamp}, {vals})",
                        dialect="tree")

    def insert_tree_many(self, device: str, rows: list[tuple[int, list[str], list]]) -> Outcome:
        """一次多行 ``insert``（批量请求用例：单次请求含多个 slot/多行）。"""
        head = f"insert into {device}(timestamp, {', '.join(rows[0][1])}) values"
        body = ", ".join(f"({stamp}, {', '.join(str(v) for v in vals)})"
                         for stamp, _cols, vals in rows)
        return self.run(f"{head} {body}", dialect="tree")

    def insert_table(self, db: str, table: str, columns: list[str], values: list) -> Outcome:
        cols = ", ".join(columns)
        vals = ", ".join(values)
        return self.run(f"insert into {db}.{table}({cols}) values({vals})", dialect="table")

    def insert_table_rows(self, db: str, table: str, stamp: int, device: str,
                          columns: list[str], values: list) -> Outcome:
        cols = ", ".join(["time", "devid"] + columns)
        vals = ", ".join([str(stamp), f"'{device}'"] + [str(v) for v in values])
        return self.run(f"insert into {db}.{table}({cols}) values({vals})", dialect="table")

    def insert_table_many(self, db: str, table: str, tag_col: str, rows: list[tuple]) -> Outcome:
        """多设备批量写（表模型）：rows = [(stamp, tag, [values])]。"""
        value_cols = [f"s{i}" for i in range(len(rows[0][2]))]
        head = f"insert into {db}.{table}(time, {tag_col}, {', '.join(value_cols)}) values"
        body = ", ".join(f"({stamp}, '{tag}', {', '.join(str(v) for v in vals)})"
                         for stamp, tag, vals in rows)
        return self.run(f"{head} {body}", dialect="table")

    def flush(self) -> Outcome:
        return self.run("flush")

    def count_rows(self, target: str, *, dialect: str = "tree", where: str = "") -> int:
        """``select count(*)`` 的行数。

        H-26：多测点/多字段时结果集是**一行多列**（每列一个 count(序列)），旧实现只看第一列，
        于是 `devid` 上 s0=2 / s_new=1 会被读成 1（TTL-07 假 FAIL）。行数语义 = 各列 count 的
        **最大值**（每列统计的是"该序列非空的行数"，行数不小于任何一列，且在无 NULL 时相等）。
        """
        clause = f" where {where}" if where else ""
        outcome = self.run(f"select count(*) from {target}{clause}", dialect=dialect)
        if not outcome.ok or not outcome.rows:
            return -1
        counts: list[int] = []
        for row in outcome.rows:
            for value in row.values():
                m = re.search(r"-?\d+", str(value))
                if m:
                    counts.append(int(m.group(0)))
        return max(counts) if counts else -1

    # ============================================================= 日志/证据
    def write_snapshot(self, path: Path, payload: dict) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        return path

    # ============================================================== benchmark
    def bench_ssh(self, command: str, *, timeout: int = 1800) -> tuple[int, str]:
        """在客户端机（密码登录）执行命令，返回 ``(rc, 输出)``。

        本机没有 sshpass，因此用 ``SSH_ASKPASS`` + ``setsid`` 喂密码（本会话实测可用的写法）。
        密码脚本写到 run 目录旁的隐藏文件，不进仓库、不进报告。
        """
        import subprocess

        bench = self.cfg.raw("PG_BENCH_SSH") or ""
        if not bench:
            return 127, "PG_BENCH_SSH 未配置"
        user, _, host = bench.partition("@")
        password = self.cfg.raw("PG_BENCH_PASSWORD") or ""
        askpass = self.cfg.result_dir.parent / ".bench_askpass.sh"
        askpass.parent.mkdir(parents=True, exist_ok=True)
        askpass.write_text(f"#!/bin/sh\nprintf '%s\\n' {json.dumps(password)}\n", encoding="utf-8")
        askpass.chmod(0o700)
        argv = ["setsid", "-w", "timeout", str(timeout), "ssh",
                "-o", "StrictHostKeyChecking=no", "-o", "PreferredAuthentications=password",
                "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1",
                f"{user}@{host}", command]
        env = dict(os.environ, SSH_ASKPASS=str(askpass), SSH_ASKPASS_REQUIRE="force")
        try:
            proc = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL,
                                  capture_output=True, text=True, timeout=timeout + 120, check=False)
        except subprocess.TimeoutExpired as exc:
            return 124, f"超时：{exc}"
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")

    def bench_run(self, *, dialect: str, db_name: str, device_number: int, sensor_number: int,
                  duration_ms: int, tag: str, out_dir: Path, bench_line: str = "v20",
                  table_number: int = 1, data_client_number: int = 2,
                  batch_size: int = 10) -> dict:
        """在客户端机跑一轮 iot-benchmark，返回 {ok, ingestion, output}。

        判据与既有约定一致：抓 ``INGESTION a b c d``，要求 rc=0 且 a>0、c=0、d=0。
        """
        key = "PG_BENCH_V20_DIR" if bench_line == "v20" else "PG_BENCH_V13_DIR"
        pkg_dir = self.cfg.raw(key)
        if not pkg_dir:
            return {"ok": False, "ingestion": None, "output": f"{key} 未配置"}
        zip_name = ("iot-benchmark-iotdb-2.0-java17.zip" if bench_line == "v20"
                    else "iot-benchmark-iotdb-1.3-java17.zip")
        inner = "iot-benchmark-iotdb-2.0" if bench_line == "v20" else "iot-benchmark-iotdb-1.3"
        db_switch = "IoTDB-200-SESSION_BY_TABLET" if bench_line == "v20" else "IoTDB-130-SESSION_BY_TABLET"
        template = (Path(__file__).resolve().parents[2] / "conf" / "bench_template.properties")
        hosts = ",".join(self.cfg.dn_hosts)
        ports = ",".join(self.cfg.raw("DB_RPC_PORT") or "6667" for _ in self.cfg.dn_hosts)
        body = template.read_text(encoding="utf-8").format(
            db_switch=db_switch, dialect=dialect, hosts=hosts, ports=ports,
            username=self.cfg.raw("DB_USER"), password=self.cfg.raw("DB_PASSWORD"),
            db_name=db_name, device_number=device_number, sensor_number=sensor_number,
            table_number=table_number if dialect == "table" else 1,
            data_client_number=data_client_number, batch_size=batch_size,
            test_max_time_ms=duration_ms,
            start_time=f"{datetime.datetime.now():%Y-%m-%dT%H:%M:%S}+08:00",
            operation_proportion="91:2:1:0:1:0:1:1:2:1:0:0:0"
                                 if dialect == "table" else "91:2:1:1:1:0:1:1:2:1:0:0:0",
            datatype_proportion="0:0:0:0:0:0:8:0:3:0:1"
                                if dialect == "table" else "0:1:1:1:1:1:2:1:3:1:0")
        conf_dir = out_dir / f"bench_conf_{tag}"
        conf_dir.mkdir(parents=True, exist_ok=True)
        (conf_dir / "config.properties").write_text(body, encoding="utf-8")
        out_file = out_dir / f"bench_{tag}.out"
        script = (
            f"set -e; source /etc/profile; cd {pkg_dir}; "
            f"[ -d {inner} ] || unzip -q -o {zip_name}; "
            f"cp -f {inner}/conf/logback.xml {inner}/conf/function.xml {conf_dir}/ 2>/dev/null || true; "
            f"nohup {pkg_dir}/{inner}/benchmark.sh -cf {conf_dir} -heapsize 512m -maxheapsize 1G "
            f"> {out_file} 2>&1 & echo BENCH_PID=$!"
        )
        code, output = self.bench_ssh(script, timeout=120)
        if code != 0:
            return {"ok": False, "ingestion": None, "output": output[-2000:]}
        deadline = time.time() + duration_ms / 1000.0 + 600
        tail = ""
        while time.time() < deadline:
            time.sleep(20)
            _rc, tail = self.bench_ssh(f"tail -n 120 {out_file}", timeout=120)
            if re.search(r"^\s*INGESTION\s+\d+", tail, re.M) or "Exception" in tail:
                break
        ingestion = re.search(r"^\s*INGESTION\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$", tail, re.M)
        ok = bool(ingestion) and int(ingestion.group(1)) > 0 \
            and int(ingestion.group(3)) == 0 and int(ingestion.group(4)) == 0
        self.bench_ssh(f"pkill -f 'cn.edu.tsinghua.iot.benchmark.App' || true", timeout=60)
        return {"ok": ok, "ingestion": ingestion.groups() if ingestion else None,
                "output": tail[-4000:], "out_file": str(out_file)}
