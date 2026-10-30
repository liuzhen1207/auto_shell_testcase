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
#: 副本行里可能携带地址的列（优先 ``InternalAddress``：它已经是产品给出的 IP）。
ADDRESS_COLUMNS = ("InternalAddress", "internal_address", "InternalEndPoint",
                   "internal_end_point", "RpcAddress", "rpc_address")
#: ``SHOW (DATANODES|CLUSTER)`` 里的节点标识/类型列（列名在 1.3/2.x 之间会变）。
NODE_ID_COLUMNS = ("NodeID", "NodeId", "node_id", "DataNodeId", "data_node_id", "Id", "id")
NODE_TYPE_COLUMNS = ("NodeType", "node_type", "Type", "type")
NODE_ADDRESS_COLUMNS = ("InternalAddress", "internal_address", "InternalEndPoint",
                        "internal_end_point", "RpcAddress", "rpc_address",
                        "Address", "address", "Host", "host")


def normalize_address(value: str) -> str:
    """地址归一化：``ip:port`` / ``[v6]:port`` / 纯 IP（或主机名）→ 去掉端口的地址。

    副本行里的地址既可能是 ``11.101.10.7`` 也可能是 ``11.101.10.7:10730``，
    停/启节点与"在线集合"比较都只认 IP（A 类：DataNodeId 与 IP 混用的根因之一）。

    * **纯数字**一律判成 ``DataNodeId``（裸 id，不是地址）⇒ 返回 ``""``，交给
      ``NodeID -> IP`` 映射处理，避免把 ``4`` 当成"地址 4"与 IP 直接比较；
    * 非空且非纯数字的标识（IP、``ip:port``、主机名）都算地址，去端口后返回 ——
      用主机名部署的集群两侧口径一致，不会被误判成"无法归一化"；
    * 空值返回 ``""``。
    """
    text = (value or "").strip()
    if not text:
        return ""
    if text.startswith("TEndPoint("):              # TEndPoint(ip:11.101.10.9, port:10730)
        inner = text[len("TEndPoint("):]
        found = re.search(r"(?:ip|address)\s*[:=]\s*([^,)\s]+)", inner)
        return normalize_address(found.group(1)) if found else ""
    if text.isdigit():                             # 裸 DataNodeId，不是地址
        return ""
    if text.startswith("["):                       # IPv6：[::1]:10710
        return text[1:].split("]")[0]
    if text.count(":") == 1:                       # IPv4:port / host:port
        return text.split(":")[0]
    return text


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
    #: 副本的**原始**标识（``DataNodeId`` 列的裸 id，如 ``"4"``）——保留原值便于对账。
    replicas: list[str] = field(default_factory=list)
    #: A 类（HA-02/HA-04）口径：副本标识**归一化到 IP** 之后的结果（``show datanodes``
    #: 的 ``NodeID -> InternalAddress`` 映射 + 行内 ``InternalAddress`` 列）。
    #: 裸 id、``ip:port``、纯 IP 三种写法在这里统一成同一个 DN 的 IP。
    replica_addresses: list[str] = field(default_factory=list)
    #: 无法归一化的副本原值（映射缺失）——**保留**并写进 detail/evidence，绝不静默丢弃。
    unmapped_replicas: list[str] = field(default_factory=list)
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
            "replica_addresses": sorted(self.replica_addresses),
            "unmapped_replicas": sorted(self.unmapped_replicas),
            "roles": self.roles,
        }


class PgApi:
    """PROACTIVE 用例的操作层（SQL / 策略 / 权限 / benchmark）。"""

    #: ``NodeID -> IP`` 映射的缓存时长（秒）。副本断言一次用例里会反复读同一份
    #: ``SHOW REGIONS``，绝不能每读一次就多发一条 ``show datanodes``。
    NODE_MAP_TTL = 20.0

    def __init__(self, cfg, sql, ssh, log) -> None:
        self.cfg = cfg
        self.sql = sql
        self.ssh = ssh
        self.log = log
        #: 由 runner 注入，使每条语句落进用例的 actions.log
        self.trace = None
        self._last: Outcome | None = None
        #: A 类：``NodeID -> InternalAddress(IP)``（``show datanodes`` / ``show cluster``）。
        #: **只增不减**：NodeID 与地址的对应关系在一个集群生命周期内不变，而节点被 harness
        #: 停掉后表里可能少一行 —— 合并（而不是替换）才不会让"停机后同一副本"从可映射
        #: 变成不可映射，也就不会把"被停节点上的副本"误判成"越界/未知副本"。
        self._node_map: dict[str, str] = {}
        self._node_map_at: float = 0.0

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

    # ==================================================== 副本标识归一化（A 类）
    def node_inventory(self, *, refresh: bool = False) -> dict[str, str]:
        """``NodeID -> InternalAddress(IP)``：副本标识归一化的唯一映射源。

        取 ``show datanodes``（列随机型/版本变化，用 ``NODE_ID_COLUMNS`` 兼容）；
        不可用时回退 ``show cluster``（只取 ``NodeType`` 含 ``data`` 的行）。
        **不按在线状态过滤**：被 harness 停掉的节点也必须留在映射里，否则停机窗口内
        副本行里的裸 id（如 ``4``）会变成"无法映射"，从而被误判成"越界副本"。
        结果**只增不减**并缓存 ``NODE_MAP_TTL`` 秒。
        """
        now = time.time()
        if self._node_map and not refresh and (now - self._node_map_at) < self.NODE_MAP_TTL:
            return dict(self._node_map)
        merged = dict(self._node_map)
        for statement, only_datanodes in (("show datanodes", False), ("show cluster", True)):
            try:
                outcome = self.run(statement)
            except Exception:  # noqa: BLE001 - 映射是"尽力而为"，取不到就走 unmapped 分支
                continue
            if not outcome.ok or not outcome.rows:
                continue
            id_col = self.column(outcome.rows, *NODE_ID_COLUMNS)
            addr_col = self.column(outcome.rows, *NODE_ADDRESS_COLUMNS)
            type_col = self.column(outcome.rows, *NODE_TYPE_COLUMNS)
            if not id_col or not addr_col:
                continue
            if only_datanodes and not type_col:
                # ``show cluster`` 的 NodeID 在 CN/DN 之间**各自编号**（CN:1-3、DN:1-5），
                # 没有 NodeType 列就无法把 CN 行剔掉 —— 宁可不要这份映射（副本会进
                # unmapped 并被断言点名），也不能把 CN 的 NodeID 冒充成 DN 地址。
                continue
            found = 0
            for row in outcome.rows:
                if only_datanodes and type_col:
                    node_type = (row.get(type_col) or "").strip().lower()
                    if node_type and "data" not in node_type:
                        continue
                node_id = (row.get(id_col) or "").strip()
                address = normalize_address(row.get(addr_col) or "")
                if node_id and address:
                    merged[node_id] = address
                    found += 1
            if found:
                break
        if merged:
            self._node_map = merged
            self._node_map_at = now
        return dict(self._node_map)

    @classmethod
    def replica_address(cls, row: dict[str, str], id_map: dict[str, str]) -> tuple[str, bool]:
        """副本行 → ``(归一化 IP, 是否成功映射)``。

        优先级：行内 ``InternalAddress``（产品直接给出的 IP）> ``RpcAddress`` >
        ``DataNodeId`` 查 ``id_map``。三种写法（裸 id / ``ip:port`` / 纯 IP）在这里
        统一到同一个 DN 的 IP；映射缺失时**保留原值**并返回 ``False``，由调用方在
        detail 里注明（绝不静默丢弃，也绝不伪造一个 IP）。
        """
        for column in ADDRESS_COLUMNS:
            address = normalize_address(row.get(column) or "")
            if address:
                return address, True
        for column in DN_ID_COLUMNS:
            value = (row.get(column) or "").strip()
            if not value:
                continue
            if value in id_map:
                return id_map[value], True
            return value, False
        return "", False

    def groups(self, db: str = "", *, kind: str = "DATA", dialect: str = "tree",
               node_id: int | None = None) -> dict[str, RegionGroup]:
        """按 RegionId 去重后的逻辑 RegionGroup 表。

        副本标识同时保留**原始值**（``replicas``，``DataNodeId`` 裸 id）与**归一化 IP**
        （``replica_addresses``）；无法归一化的原值进 ``unmapped_replicas``。
        """
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
        id_map = self.node_inventory()          # 一次读取、逐行复用（20s 缓存）
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
            address, mapped = self.replica_address(row, id_map)
            if address:
                if mapped:
                    if address not in group.replica_addresses:
                        group.replica_addresses.append(address)
                elif address not in group.unmapped_replicas:
                    # 映射缺失：保留原值并在 evidence 里注明（A 类纪律：不静默丢弃）
                    group.unmapped_replicas.append(address)
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

    def grant_system(self, user: str, *, scope: str = "root.**") -> Outcome:
        """授予 SYSTEM 权限。

        H-45：语法是 ``GRANT <privileges> ON <prefixPath> TO USER <user>``（IoTDBSqlParser.g4:1228），
        ``grant system to user x`` 缺 ``ON`` 必然 700 解析失败（旧实现据此 SKIP 了 PRV-02/06）。
        """
        return self.run(f"grant system on {scope} to user {user}")

    def set_system(self, mode: str, *, host: str = "") -> Outcome:
        """``SET SYSTEM TO READONLY|RUNNING [ON LOCAL|CLUSTER]``。

        H-45b：IoTDBSqlParser.g4:1369 提供该语句，用它就能制造"只读 DataNode"档位
        （HA-08 之前因为没有只读接口一直 SKIP）。
        """
        # 不带 ON 时默认作用于 CLUSTER（会把语句派发到整集群）；HA-08 期间集群里有停机 DN，
        # 派发到它就 1007 失败 ⇒ 必须显式 ON LOCAL，只切换当前 DN。
        return self.run(f"set system to {mode.lower()} on local", host=host)

    def revoke_system(self, user: str, *, scope: str = "root.**") -> Outcome:
        """撤销 SYSTEM 权限（H-45：同样需要 ``ON <prefixPath>``，见 IoTDBSqlParser.g4:1248）。"""
        return self.run(f"revoke system on {scope} from user {user}")

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

    def show_timeseries(self, pattern: str = "root.**", *, limit: int = 0) -> Outcome:
        sql = f"show timeseries {pattern}"
        if limit > 0:
            sql += f" limit {limit}"
        return self.run(sql, dialect="tree")

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

    def count_series(self, target: str, *, dialect: str = "tree", where: str = "") -> int:
        """``select count(<sensor>) from <db>.<device>`` —— 精确到测点的行数。

        H-37（2026-10-20 干净集群实锤）：2.x 的 ``count(*)`` 语义是"路径下**各测点**的行数"
        （一个测点一列，见 H-31）。因此把 ``<db>.<device>.<sensor>`` 这种**测点级路径**直接
        塞进 ``count(*)`` 会返回空集 —— 测点路径下没有子测点，``count_rows`` 于是返回 -1。
        正确写法是把测点提到投影里：``select count(<sensor>) from <db>.<device>``。
        """
        if target.count(".") < 2:
            return self.count_rows(target, dialect=dialect, where=where)
        db_device, sensor = target.rsplit(".", 1)
        clause = f" where {where}" if where else ""
        outcome = self.run(f"select count({sensor}) from {db_device}{clause}", dialect=dialect)
        if not outcome.ok or not outcome.rows:
            return -1
        for row in outcome.rows:
            for value in row.values():
                m = re.search(r"-?\d+", str(value))
                if m:
                    return int(m.group(0))
        return -1

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
            is_client_bind="true" if device_number >= (1 + data_client_number) else "false",
            # 大规模测点档位：每测点约 1 行即可验证 slot/组数，避免 9000 万点落盘拖慢可见性
            loop=(12 if sensor_number >= 10000 else
                  max(200, min(20000, (device_number * sensor_number) // max(1, batch_size)))),
            test_max_time_ms=duration_ms,
            start_time=f"{datetime.datetime.now():%Y-%m-%dT%H:%M:%S}+08:00",
            operation_proportion="91:2:1:0:1:0:1:1:2:1:0:0:0"
                                 if dialect == "table" else "91:2:1:1:1:0:1:1:2:1:0:0:0",
            datatype_proportion="0:0:0:0:0:0:8:0:3:0:1"
                                if dialect == "table" else "0:1:1:1:1:1:2:1:3:1:0",
            # H-58：客户端 thrift 帧上限（默认 64MB）要能装下表模型的大列宽请求
            thrift_frame=(self.cfg.raw("PG_BENCH_FRAME_SIZE") or "536870912"),
            write_timeout_ms=(self.cfg.raw("PG_BENCH_WRITE_TIMEOUT_MS") or "600000"))
        # 关键：benchmark 跑在客户端机上，配置与输出必须落在**客户端机**的路径，
        # 再把结果取回本地证据目录（本地 out_dir 在客户端机上不存在，直接重定向会静默失败）。
        conf_dir = out_dir / f"bench_conf_{tag}"
        conf_dir.mkdir(parents=True, exist_ok=True)
        (conf_dir / "config.properties").write_text(body, encoding="utf-8")
        out_file = out_dir / f"bench_{tag}.out"
        remote_dir = f"/tmp/pgbench_{tag}"
        remote_conf = f"{remote_dir}/config.properties"
        remote_out = f"{remote_dir}/bench.out"
        # 先清掉上一轮残留的 benchmark，避免"边写边 drop 库"（服务端 507）的竞态
        self.bench_ssh("pkill -f 'cn.edu.tsinghua.iot.benchmark.App' || true", timeout=60)
        push = (
            f"set -e; mkdir -p {remote_dir}; rm -f {remote_out}; cat > {remote_conf} <<'PGEOF'\n"
            f"{body}\nPGEOF\necho CONF_OK"
        )
        code, output = self.bench_ssh(push, timeout=120)
        if code != 0:
            return {"ok": False, "ingestion": None, "output": f"配置写入客户端机失败：{output[-1500:]}"}
        script = (
            f"set -e; source /etc/profile; cd {pkg_dir}; "
            f"[ -d {inner} ] || unzip -q -o {zip_name}; "
            f"cp -f {inner}/conf/logback.xml {inner}/conf/function.xml {remote_dir}/ 2>/dev/null || true; "
            f"cd {remote_dir}; "
            # H-47：50 万测点档位下 benchmark 客户端默认 1G 堆直接 OOM
            # (java.lang.OutOfMemoryError: Java heap space)，堆上限按档位放大到 8G。
            f"nohup {pkg_dir}/{inner}/benchmark.sh -cf {remote_dir} -heapsize 1G -maxheapsize 8G "
            f"> {remote_out} 2>&1 & echo BENCH_PID=$!"
        )
        code, output = self.bench_ssh(script, timeout=120)
        if code != 0:
            return {"ok": False, "ingestion": None, "output": output[-2000:]}
        deadline = time.time() + duration_ms / 1000.0 + 600
        tail = ""
        while time.time() < deadline:
            time.sleep(20)
            _rc, tail = self.bench_ssh(f"tail -n 120 {remote_out} 2>/dev/null", timeout=120)
            if re.search(r"^\s*INGESTION\s+\d+", tail, re.M) or "Exception" in tail:
                break
        # 实际输出行尾还有吞吐列：``INGESTION 903 90300000 0 0 1369974.90``，
        # 只取前 4 个整数（操作数、点数、失败数、失败数），不要求行尾。
        ingestion = re.search(r"^\s*INGESTION\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", tail, re.M)
        ok = bool(ingestion) and int(ingestion.group(1)) > 0 \
            and int(ingestion.group(3)) == 0 and int(ingestion.group(4)) == 0
        self.bench_ssh(f"pkill -f 'cn.edu.tsinghua.iot.benchmark.App' || true", timeout=60)
        # 把客户端机上的输出取回本地证据目录（失败不影响判据）
        try:
            _rc, full = self.bench_ssh(f"cat {remote_out} 2>/dev/null | tail -n 2000", timeout=180)
            if full:
                out_file.write_text(full, encoding="utf-8", errors="replace")
            _rc, conf_text = self.bench_ssh(f"cat {remote_conf} 2>/dev/null", timeout=180)
            if conf_text:
                (conf_dir / "config.remote.properties").write_text(conf_text, encoding="utf-8")
        except Exception:  # noqa: BLE001 - 证据回传失败不影响判定
            pass
        return {"ok": ok, "ingestion": ingestion.groups() if ingestion else None,
                "output": tail[-4000:], "out_file": str(out_file)}
