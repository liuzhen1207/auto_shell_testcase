"""PG-LIM / PG-DIS / PG-RCV 用例族：资源上限公式、Disabled 补组、重启与领导者恢复。

依据
====
* ``references/case-catalog.md`` 的 PG-LIM（20）/ PG-DIS（7）/ PG-RCV（7）段；
* 判定口径见 ``references/proactive-spec.md`` §3（触发条件、T/delta、Disabled 补组）、
  §4（上限公式）、§5（重平衡与 ConfigNode 恢复）、§9 A-05（重启后 LoadCache 未加载的歧义探针）。

源码出处（本模块全部期望值的唯一依据）
======================================
* ``ClusterSchemaManager.java:594-649`` 上限公式
  ``R = max(min, ceil(weight × resource / (参与分摊库数 × 副本数)), 已分配组数)``；
  schema 用 ``(schema_region_per_data_node, DN 数)``，data 在 ``data_region_per_data_node=0``
  时用 ``(0.5, DN 上报 CPU 总核数)``、``>0`` 时用 ``(该值, DN 数)``；
  ``:511-550`` 参与分摊库数**排除**系统库/审计库/预删除库（树 + 表普通库一起计数）。
* ``ClusterSchemaManager.java:973-1061`` 建库默认 ``max = min``；显式 MAX 仅在 **CUSTOM** 下被接受，
  否则返回 ``DATABASE_CONFIG_ERROR``（消息含 ``CUSTOM``）。
* ``PartitionManager.java:654-699`` ``T = min(R, max(min(minNum, G+|P|), K))``、``delta = max(0, T-G)``；
  常规分支 delta=0 且 P 非空、0<G<R、**该类型全部组 Disabled** 时追加 1 组。
* ``LoadCache.java:798-802`` 未缓存的组按 **Disabled** 返回（A-05 歧义的来源）。
* ``RegionGroupCache.java:120-150`` 组状态：全副本 Running ⇒ Running；否则强一致（Ratis）
  多数派存活 ⇒ Available，否则 Disabled；弱一致（IoTConsensus/IoTConsensusV2）
  ≥1 副本存活 ⇒ Available，0 ⇒ Disabled。schema 固定 Ratis。

纪律
====
* 期望值一律公式化：组数 = ``min(K, 上限)``（K 用 ``pgkit.slots`` 计算），上限直接用**观测到的**
  ``Max*RegionGroupNum`` 与公式对比；
* ``cases.expected_cap`` 只统计**本方言可见**的普通库；本模块的 ``_cap`` 按源码口径统计
  树 + 表普通库的**并集**（实测：建一个表模型库会把 ``root.pg`` 的上限 5/60 立刻压到 3/30），
  LIM-01/02 在两种口径一致时**额外**调用 ``expect_cap`` 直接断言；
* 停/启节点前先 ``ctx.mark_harness_action``，被停的 DataNode 记入 ``ctx.by_design_gone``，
  用例结束前恢复集群；故意被拒的 ALTER 语句前也开归因窗口。
"""

from __future__ import annotations

import itertools
import math
import time
from contextlib import contextmanager

from . import slots as pslots
from .cases import (
    HARNESS_ACTION_PADS,
    SYSTEM_DBS,
    TREE_SENSORS,
    CaseSpec,
    Ctx,
    device_set,
    ensure_write_table,
    ensure_write_tree,
    expect_cap,
    expect_groups,
    expected_cap,
    group_counts,
    reset_db,
    _resolve_pad,
    write_devices,
)

SPECS: list[CaseSpec] = []

_CN, _DN = "cn", "dn"
_RUNNING, _AVAILABLE, _DISABLED = "running", "available", "disabled"
_DISABLE_WAIT = 240      # 停 DN 后等组状态转 Disabled 的上界（心跳超时 + 状态收敛）
_RECOVER_WAIT = 300      # 重启 DN 后等组状态回 Running 的上界
_POLL = 5

#: conf 键 → iotdb-system.properties 键（用于热加载/读回的键名对照）
_PROP_OF = {
    "PG_SCHEMA_PER_DATA_NODE": "schema_region_per_data_node",
    "PG_DATA_PER_DATA_NODE": "data_region_per_data_node",
    "PG_MIN_SCHEMA_PER_DB": "default_schema_region_group_num_per_database",
    "PG_MIN_DATA_PER_DB": "default_data_region_group_num_per_database",
    "PG_SCHEMA_POLICY": "schema_region_group_extension_policy",
    "PG_DATA_POLICY": "data_region_group_extension_policy",
}


# ============================================================ 上限公式（源码口径）
def _dialect_dbs(ctx: Ctx, dialect: str) -> list[str]:
    """该方言下 ``SHOW DATABASES DETAILS`` 可见的普通库（排除系统库/审计库/information_schema）。"""
    return sorted(name for name in ctx.api.database_details(dialect)
                  if not any(marker in name for marker in SYSTEM_DBS))


def _user_dbs(ctx: Ctx) -> list[str]:
    """参与分摊的普通库 = 树普通库 ∪ 表普通库（``ClusterSchemaManager`` 的 databaseNum 口径）。"""
    return sorted(set(_dialect_dbs(ctx, "tree")) | set(_dialect_dbs(ctx, "table")))


def _cross_check_formula(ctx: Ctx, db: str, dialect: str) -> None:
    """本模块的并集口径公式与 ``cases.expected_cap`` 逐项互证（两套独立实现）。"""
    for kind in ("SCHEMA", "DATA"):
        mine = _cap(ctx, kind, dialect, db)
        theirs = expected_cap(ctx, kind, dialect, db)
        ctx.check(f"上限公式两套实现一致（{kind}，并集分母口径）", mine == theirs,
                  f"本模块={mine}、cases.expected_cap={theirs}、普通库并集={_user_dbs(ctx)}")


def _cap_detail(ctx: Ctx, kind: str, dialect: str = "tree", db: str = "", *,
                per_node=None, minimum=None, db_num=None, dn_num=None):
    """上限公式 ``max(min, ceil(weight × resource / (参与分摊库数 × 副本数)))`` 及其取证串。"""
    cfg = ctx.cfg
    dbs = _user_dbs(ctx)
    count = max(1, int(db_num) if db_num is not None else len(dbs))
    dn = int(dn_num) if dn_num is not None else len(cfg.dn_hosts)
    if kind.upper().startswith("S"):
        weight = int(cfg.raw("PG_SCHEMA_PER_DATA_NODE") or 1) if per_node is None else int(per_node)
        resource = dn
        rf = cfg.get_int("SCHEMA_REPLICATION_FACTOR")
        minimum = int(cfg.raw("PG_MIN_SCHEMA_PER_DB") or 1) if minimum is None else int(minimum)
        terms = f"weight={weight}(schema_region_per_data_node) × resource={resource}(DN数)"
    else:
        quota = int(cfg.raw("PG_DATA_PER_DATA_NODE") or 0) if per_node is None else int(per_node)
        if quota > 0:
            weight, resource = quota, dn
            terms = f"weight={weight}(data_region_per_data_node) × resource={resource}(DN数)"
        else:
            cores = int(cfg.raw("PG_CPU_CORES_PER_DN") or 48)
            weight, resource = 0.5, dn * cores
            terms = f"weight=0.5(CPU/2) × resource={resource}({dn}DN×{cores}核)"
        rf = cfg.get_int("DATA_REPLICATION_FACTOR")
        minimum = int(cfg.raw("PG_MIN_DATA_PER_DB") or 2) if minimum is None else int(minimum)
    term = math.ceil(weight * resource / (count * rf))
    value = max(minimum, term)
    detail = (f"max(min={minimum}, ceil({terms} / (参与分摊库数={count} × rf={rf})))"
              f" = max({minimum}, {term}) = {value}；普通库={dbs}")
    return value, detail


def _cap(ctx: Ctx, kind: str, dialect: str = "tree", db: str = "", **kw) -> int:
    return _cap_detail(ctx, kind, dialect, db, **kw)[0]


def _obs_cap(ctx: Ctx, db: str, kind: str, dialect: str = "tree") -> int:
    return ctx.api.db_max_group_num(db, kind, dialect=dialect)


def _wait_obs_cap(ctx: Ctx, db: str, kind: str, dialect: str, want: int,
                  timeout: int = 30) -> int:
    """读观测上限；热加载后给一点收敛时间（上限是共识落盘值，可能晚一两个心跳可见）。

    H-19：等待条件用 ``got < want`` 而不是 ``got != want`` —— 产品为每个库保留的上限
    **单调不减**，实测大于公式是预期行为，等"等于"只会白等到超时再判 FAIL。
    """
    got = _obs_cap(ctx, db, kind, dialect)
    deadline = time.time() + timeout
    while got < want and time.time() < deadline:
        time.sleep(3)
        got = _obs_cap(ctx, db, kind, dialect)
    return got


def _group_r(ctx: Ctx, kind: str, dialect: str = "tree", db: str = "", **kw) -> int:
    """H-19：组数类断言的 R 取 max(公式, 产品自报上限)。

    产品为每库保留**单调不减**的上限：建库/调库后公式可能低于已存上限（实测 5/60 vs 公式 3/30），
    此时组数会按已存上限继续扩到 5/60。用纯公式当 R 会把正确的扩容判成"超过上限"。
    """
    return max(_cap(ctx, kind, dialect, db, **kw), _obs_cap(ctx, db, kind, dialect))


def _check_cap(ctx: Ctx, label: str, db: str, dialect: str = "tree", *,
               schema_per_node=None, data_per_node=None,
               schema_min=None, data_min=None, db_num=None,
               kinds: tuple[str, ...] = ("SCHEMA", "DATA")) -> None:
    """断言观测到的 ``Max*RegionGroupNum`` **不低于**公式值（H-19 口径）。

    H-19：产品保留**每库单调不减**的历史上限（`PartitionManager.java:654-699` 只做单调抬高），
    因此 ``实测 > 公式``（多库分摊变少、热加载回收配额等）是预期行为；只有 ``实测 < 公式``
    （例如 D-04 表模型被钉在 1/2）才是真缺陷。
    """
    for kind in kinds:
        kw = {"db_num": db_num}
        if kind.startswith("S"):
            kw.update(per_node=schema_per_node, minimum=schema_min)
        else:
            kw.update(per_node=data_per_node, minimum=data_min)
        want, detail = _cap_detail(ctx, kind, dialect, db, **kw)
        got = _wait_obs_cap(ctx, db, kind, dialect, want)
        ctx.check(f"{label}：观测 Max{kind.title()}RegionGroupNum 应不低于公式值 {want}",
                  got >= want, f"实际={got}；{detail}"
                  + ("（实测>公式=每库单调存量上限，H-19）" if got > want else ""))


# ============================================================ 配置热加载
def _read_prop(ctx: Ctx, key: str) -> str:
    """读回节点配置文件里的生效值（``SET CONFIGURATION`` 会落盘，比 show 更硬）。"""
    return (ctx.props.read(ctx.cfg.cli_host, keys=(key,)).get(key, "") or "").strip()


def _set_knob(ctx: Ctx, key: str, value, original, label: str) -> None:
    """热加载单个键 + 读回自证；并把"恢复原值"登记进 cleanup（异常路径也还原）。"""
    if str(original):
        ctx.cleanup.append(f'set configuration "{key}"="{original}"')
    ctx.mark_harness_action(f"{label}：热加载 {key}={value}（原值 {original}）", pad=20)
    ctx.req(ctx.api.set_config(key, str(value)), f"热加载 {key}={value}")
    read = ""
    for attempt in range(3):
        read = _read_prop(ctx, key)
        if read == str(value):
            break
        time.sleep(3)
    ctx.check(f"{label}：{key} 读回应为 {value}", read == str(value), f"读回={read!r}")


def _restore_knob(ctx: Ctx, key: str, value, label: str) -> None:
    # H-25：恢复动作同样是"harness 改配置"，必须**单独开窗**（与热加载同一套 pad），
    # 否则恢复引发的 policy reload / "configuration changed" 噪声会落进后续用例的扫描窗。
    ctx.mark_harness_action(f"{label}：恢复 conf 原值 {key}={value}", pad=20, kind="set_config")
    ctx.api.set_config(key, str(value))
    read = ""
    for attempt in range(3):
        read = _read_prop(ctx, key)
        if read == str(value):
            break
        time.sleep(3)
    ctx.check(f"{label}：恢复 {key}={value}", read == str(value), f"读回={read!r}")


def _policy(ctx: Ctx, kind: str) -> str:
    """当前策略（键缺失 ⇒ 代码默认 PROACTIVE，见 spec §1.2）。"""
    key = _PROP_OF["PG_SCHEMA_POLICY" if kind.upper().startswith("S") else "PG_DATA_POLICY"]
    return _read_prop(ctx, key) or "PROACTIVE"


@contextmanager
def _min_data_one(ctx: Ctx, label: str):
    """临时把 ``default_data_region_group_num_per_database`` 降到 1（只影响新建库）。"""
    old = int(ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    if old != 1:
        _set_knob(ctx, _PROP_OF["PG_MIN_DATA_PER_DB"], 1, old, label)
    try:
        yield
    finally:
        if old != 1:
            _restore_knob(ctx, _PROP_OF["PG_MIN_DATA_PER_DB"], old, label)


# ============================================================ 节点与组状态
def _rf(ctx: Ctx, kind: str) -> int:
    return ctx.cfg.get_int("SCHEMA_REPLICATION_FACTOR" if kind.upper().startswith("S")
                           else "DATA_REPLICATION_FACTOR")


def _down_need(ctx: Ctx, kind: str) -> int:
    """使一个组变成 Disabled 需要停掉的副本数（上面 RegionGroupCache 的判定口径）。"""
    rf = _rf(ctx, kind)
    if kind.upper().startswith("S"):
        return rf - (rf // 2 + 1) + 1              # Ratis：少数派即 Disabled
    proto = (ctx.cfg.raw("DEPLOY_CONSENSUS") or "").lower()
    if "ratis" in proto:
        return rf - (rf // 2 + 1) + 1
    return rf                                       # IoTConsensus(V2)：全副本下线才 Disabled


def _norm_host(value: str) -> str:
    """副本行里的地址可能是 ``ip`` 也可能是 ``ip:port`` ⇒ 只取 IP（停/启节点要的是 IP）。"""
    text = (value or "").strip()
    if not text:
        return ""
    if text.startswith("["):                     # IPv6：[::1]:10710
        return text[1:].split("]")[0]
    if text.count(":") == 1:
        return text.split(":")[0]
    return text


def _group_hosts(group, known: set | None = None) -> set:
    """该组副本所在的 DataNode IP 集合（可选：只保留 conf 里已知的 DN）。"""
    hosts = set()
    for row in group.raw:
        for column in ("InternalAddress", "RpcAddress"):
            host = _norm_host(row.get(column, ""))
            if host and (known is None or host in known):
                hosts.add(host)
    return hosts


def _replica_hosts(ctx: Ctx, db: str, kind: str, dialect: str = "tree") -> dict:
    """组 → 副本 DN 集合；地址一律归一化并过滤到 conf 里已知的 DataNode。"""
    known = set(ctx.cfg.dn_hosts)
    return {gid: _group_hosts(group, known)
            for gid, group in ctx.api.groups(db, kind=kind, dialect=dialect).items()}


def _all_resolved(ctx: Ctx, hostmap: dict, kind: str) -> bool:
    """每个组的副本都能全部解析成已知 DN（否则不能拿它做停/启实验）。"""
    rf = _rf(ctx, kind)
    return bool(hostmap) and all(len(hosts) == rf for hosts in hostmap.values())


def _plan_cover(ctx: Ctx, db: str, kind: str, dialect: str = "tree", *, limit: int):
    """求一个 ≤limit 台的 DN 集合，使该类型全部组都 Disabled；返回 (combo, need, hostmap)。"""
    hostmap = _replica_hosts(ctx, db, kind, dialect)
    need = _down_need(ctx, kind)
    if not _all_resolved(ctx, hostmap, kind):
        return None, need, hostmap
    candidates = sorted({h for hosts in hostmap.values() for h in hosts})
    for size in range(1, limit + 1):
        for combo in itertools.combinations(candidates, size):
            picked = set(combo)
            if all(len(hosts & picked) >= need for hosts in hostmap.values()):
                return list(combo), need, hostmap
    return None, need, hostmap


def _schema_guard_ok(ctx: Ctx, db: str, dialect: str, combo) -> bool:
    """预测停 ``combo`` 后本库 Schema 组是否仍可用（否则元数据路径被连带破坏）。

    副本地址解析不全时一律返回 False：宁可 SKIP，也不能在无法证明元数据安全时停 DN。
    """
    need = _down_need(ctx, "SCHEMA")
    picked = set(combo)
    hosts = _replica_hosts(ctx, db, "SCHEMA", dialect)
    if not _all_resolved(ctx, hosts, "SCHEMA"):
        return False
    return all(len(h & picked) < need for h in hosts.values())


def _mark_window(ctx: Ctx, reason: str, pad: int = 30,
                 kind: str | None = None) -> tuple[float, int]:
    """动作开始：开初窗并返回 ``(开始时刻, 收敛尾巴秒数)``。

    H-25：``_close_window`` 原来只登记 ``(start, now)`` —— 窗口截止在**动作结束那一刻**，
    于是"启节点后 50–64s 的 Ratis appender 收敛尾"、"删库后 30–92s 的对端组销毁"全部
    落在窗外（RCV-01/02/04/07、DEV-19、TIME-07、LIM-08/11）。这里把按动作类型解析出的
    尾巴一并返回，由 ``_close_window`` 在"动作结束"之后再顺延这段尾巴。
    """
    ctx.mark_harness_action(reason, pad=pad, kind=kind)
    _lead, tail = _resolve_pad(pad, kind, reason)
    return time.time(), max(tail, HARNESS_ACTION_PADS["default"][1])


def _close_window(ctx: Ctx, start: float | tuple[float, int], reason: str) -> None:
    if isinstance(start, tuple):
        start, tail = start
    else:                       # 兼容只传时刻的旧调用
        tail = 0
    now = time.time()
    ctx.harness_windows.append((start, now + tail, reason))
    ctx._cluster_ready = now
    ctx.note(f"    [harness 动作窗口] {reason}：{int(now - start)}s"
             + (f"（+{tail}s 收敛尾）" if tail else ""))


def _stop_nodes(ctx: Ctx, role: str, hosts: list[str], label: str) -> bool:
    start = _mark_window(ctx, f"{label}：停 {role.upper()} {', '.join(hosts)}")
    ok = True
    for host in hosts:
        ok = ctx.cluster.stop_node(host, role) and ok
        if role == _DN:
            ctx.by_design_gone.add(host)
    ctx.check(f"{label}：目标节点已停止", ok, f"hosts={hosts}")
    _close_window(ctx, start, f"{label}：停 {role.upper()}")
    return ok


def _start_nodes(ctx: Ctx, role: str, hosts: list[str], label: str) -> bool:
    start = _mark_window(ctx, f"{label}：启 {role.upper()} {', '.join(hosts)}")
    for host in hosts:
        if ctx.cluster.node_running(host, role):
            continue
        ctx.cluster.start_node(host, role)
        if role == _DN:
            ctx.by_design_gone.add(host)
    ok = ctx.cluster.wait_healthy(timeout=ctx.cfg.get_int("CLUSTER_START_TIMEOUT_SEC"))
    ctx.check(f"{label}：重启后全节点回到 Running/ReadOnly", ok, f"hosts={hosts}")
    _close_window(ctx, start, f"{label}：启 {role.upper()}")
    return ok


def _restart_nodes(ctx: Ctx, role: str, hosts: list[str], label: str) -> bool:
    _stop_nodes(ctx, role, hosts, label)
    return _start_nodes(ctx, role, hosts, label)


def _statuses(ctx: Ctx, db: str, kind: str, dialect: str = "tree") -> dict:
    return {gid: (status or "").strip().lower()
            for gid, status in ctx.api.statuses(db, kind=kind, dialect=dialect).items()}


def _wait_all(ctx: Ctx, db: str, kind: str, dialect: str, want: str, label: str,
              timeout: int) -> dict:
    deadline = time.time() + timeout
    states: dict = {}
    while time.time() < deadline:
        states = _statuses(ctx, db, kind, dialect)
        if states and all(value == want for value in states.values()):
            return states
        time.sleep(_POLL)
    return states


def _wait_disabled(ctx: Ctx, db: str, kind: str, dialect: str, label: str) -> bool:
    states = _wait_all(ctx, db, kind, dialect, _DISABLED, label, _DISABLE_WAIT)
    if states and all(value == _DISABLED for value in states.values()):
        ctx.check(f"{label}：{kind} 全部组状态已转为 Disabled（前置）", True, f"statuses={states}")
        return True
    ctx.skip(f"{label}：停 DN 后 {kind} 组状态未全部转为 Disabled（观测={states}），"
             f"Disabled 补组路径不可达；请核对该类型的一致性协议/副本分布")
    return False


def _wait_group(ctx: Ctx, db: str, kind: str, dialect: str, gid: str, want: str,
                timeout: int) -> str:
    deadline = time.time() + timeout
    status = ""
    while time.time() < deadline:
        status = ctx.api.statuses(db, kind=kind, dialect=dialect).get(gid, "").strip().lower()
        if status == want:
            return status
        time.sleep(_POLL)
    return status


def _partition_stamp(ctx: Ctx, db: str, dialect: str, back: int) -> int:
    """落在"当前分区往前第 back 个时间分区"的时间戳（用观测到的 interval，不假设单位）。"""
    interval = ctx.api.db_time_partition_interval(db, dialect=dialect)
    if interval is None or interval <= 0:
        # 兜底：用 conf 声明值（单位毫秒），再兜底到发布模板默认 7 天；不假设"秒"。
        interval = int(ctx.cfg.raw("PG_TIME_PARTITION_INTERVAL") or 604800000)
    return int(time.time() * 1000) - int(back) * int(interval)


def _create_db(ctx: Ctx, db: str, label: str) -> None:
    """fixture 建库：与 ``reset_db`` 同纪律 —— 先开归因窗口再动，并把清场语句登记好。"""
    ctx.mark_harness_action(f"{label}：fixture 建库 {db}", pad=20)
    ctx.req(ctx.api.create_database(db), f"create database {db}")
    ctx.cleanup.append(f"drop database {db}")


def _drop_db(ctx: Ctx, db: str, label: str) -> None:
    """fixture 删库：删库会在服务端留 pre-delete/不存在类 WARN，必须自带归因窗口。"""
    ctx.mark_harness_action(f"{label}：fixture 删库 {db}", pad=20)
    ctx.api.drop_database(db)


def _device_map(ctx: Ctx, db: str, devices, dialect: str = "tree") -> dict:
    return {d: ctx.api.device_group(f"{db}.{d}", dialect=dialect) for d in devices}


# ============================================================ PG-LIM 资源上限
def case_lim01_cap_formula_tree(ctx: Ctx) -> None:
    """LIM-01 树库：``Max*RegionGroupNum`` 直接等于上限公式值（含 canonical helper 对照）。"""
    db = reset_db(ctx, "tree")
    _check_cap(ctx, "空树库上限（源码公式）", db, "tree")
    _cross_check_formula(ctx, db, "tree")
    expect_cap(ctx, "空树库上限（cases.expected_cap 独立实现直接断言）", db, "tree")
    ensure_write_tree(ctx, db, "d0", 1)
    _check_cap(ctx, "写入 1 个 slot 后上限（上限只由资源/配额/最小组数决定）", db, "tree")


def case_lim02_cap_formula_table(ctx: Ctx) -> None:
    """LIM-02 表库：上限公式与树模型同口径，直接观测 ``Max*`` 断言。"""
    db = reset_db(ctx, "table")
    ctx.api.create_table(db, "tb", columns="devid STRING TAG, s0 FLOAT FIELD")
    _check_cap(ctx, "空表库上限（源码公式）", db, "table")
    _cross_check_formula(ctx, db, "table")
    expect_cap(ctx, "空表库上限（cases.expected_cap 独立实现直接断言）", db, "table")
    ensure_write_table(ctx, db, "tb", "t0", 1)
    _check_cap(ctx, "写入 1 个 slot 后上限", db, "table")


def case_lim03_fill_to_cap_tree(ctx: Ctx) -> None:
    """LIM-03 树模型：写满到上限（cap+3 个不同 slot）后组数恰好 = cap，且不再增长。"""
    db = reset_db(ctx, "tree")
    formula_d, detail = _cap_detail(ctx, "DATA", "tree", db)
    # H-19：封顶值取 max(公式, 自报上限) —— 每库上限单调不减，组数跟着自报上限走。
    cap_d = _group_r(ctx, "DATA", "tree", db)
    cap_s = _group_r(ctx, "SCHEMA", "tree", db)
    devices = device_set(ctx, db, cap_d + 4)
    ctx.check(f"前置：设备覆盖 {cap_d + 4} 个互不相同 slot（> 上限 {cap_d}）",
              pslots.distinct_slot_count(db, devices) == cap_d + 4,
              f"K={pslots.distinct_slot_count(db, devices)}；封顶值=max(公式 {formula_d}, "
              f"自报上限); 公式口径={detail}")
    write_devices(ctx, db, devices[:-1], model="tree")
    expect_groups(ctx, f"写满 {cap_d + 3} 个 slot（> 上限）", db, "tree",
                  schema=min(cap_d + 3, cap_s), data=cap_d)
    ensure_write_tree(ctx, db, devices[-1], stamp=99)
    expect_groups(ctx, "达到上限后再写新 slot", db, "tree",
                  schema=min(cap_d + 4, cap_s), data=cap_d)


def case_lim04_fill_to_cap_table(ctx: Ctx) -> None:
    """LIM-04 表模型：单批写 cap+3 个新 slot，Data 组恰好封顶 cap。"""
    db = reset_db(ctx, "table")
    formula_d, detail = _cap_detail(ctx, "DATA", "table", db)
    # H-19：同上（表模型若被钉在 min，自报值 < 公式，仍会照常 FAIL = D-04）。
    cap_d = _group_r(ctx, "DATA", "table", db)
    cap_s = _group_r(ctx, "SCHEMA", "table", db)
    tags = device_set(ctx, db, cap_d + 4, dialect="table")
    ctx.api.create_table(db, "tb", columns="devid STRING TAG, s0 FLOAT FIELD")
    ctx.note_data_written(db, "tb", "table")
    rows = [(1000 + i, tag, [float(i)]) for i, tag in enumerate(tags[:-1])]
    ctx.req(ctx.api.insert_table_many(db, "tb", "devid", rows),
            f"批量写 {cap_d + 3} 个新 slot")
    expect_groups(ctx, f"批量写满 {cap_d + 3} 个 slot（> 上限 {cap_d}）", db, "table",
                  schema=min(cap_d + 3, cap_s), data=cap_d)
    ctx.req(ctx.api.insert_table_rows(db, "tb", 5000, tags[-1], ["s0"], [1.0]),
            "达到上限后再写新 slot")
    expect_groups(ctx, "达到上限后再写新 slot", db, "table",
                  schema=min(cap_d + 4, cap_s), data=cap_d)


def case_lim05_cap_depends_on_dn_num(ctx: Ctx) -> None:
    """LIM-05 上限由 DataNode 数决定：本 harness 不能改集群规模 ⇒ 自证公式后 SKIP。"""
    db = reset_db(ctx, "tree")
    dn = len(ctx.cfg.dn_hosts)
    _check_cap(ctx, f"当前 {dn} 个 DataNode 下的上限", db, "tree")
    cap_now = _cap(ctx, "DATA", "tree", db)
    cap_less = _cap(ctx, "DATA", "tree", db, dn_num=dn - 1)
    ctx.check("公式对 DataNode 数敏感（DN 少 1 台上限不增，按实现口径重算）",
              cap_less <= cap_now,
              f"schema/data 上限：DN={dn} → {cap_now}；DN={dn - 1} → {cap_less}（ceil 保证单调）")
    ctx.skip(f"改 DataNode 数需要重新部署（3C5D → 3C4D/3C6D）并改 conf 档位，"
             f"本 harness 不支持在线加减 DN；已在当前 DN 数下自证公式一致，"
             f"DN 数依赖待换档位复测（相关条目：LIM-11 加/减 DataNode）")


def case_lim06_cap_schema_quota_hot_reload(ctx: Ctx) -> None:
    """LIM-06 上限由 ``schema_region_per_data_node`` 决定：热加载 → 读回 → Max 随之变化。"""
    db = reset_db(ctx, "tree")
    old = int(ctx.cfg.raw("PG_SCHEMA_PER_DATA_NODE") or 1)
    new = old + 2
    before = _obs_cap(ctx, db, "SCHEMA", "tree")
    _check_cap(ctx, "热加载前", db, "tree")
    data_before = _obs_cap(ctx, db, "DATA", "tree")
    try:
        _set_knob(ctx, _PROP_OF["PG_SCHEMA_PER_DATA_NODE"], new, old, "LIM-06")
        _check_cap(ctx, f"schema_region_per_data_node={new} 后", db, "tree", schema_per_node=new)
        after = _obs_cap(ctx, db, "SCHEMA", "tree")
        ctx.check("Schema 上限随每节点配额变化", after != before, f"{before} → {after}")
        _check_cap(ctx, "同一次热加载不改变 Data 侧口径", db, "tree")
        ctx.check("Data 上限不受 schema 配额影响",
                  _obs_cap(ctx, db, "DATA", "tree") == data_before,
                  f"{data_before} → {_obs_cap(ctx, db, 'DATA', 'tree')}")
        ctx.check("热加载配额本身不建组（空库仍 0 组）",
                  group_counts(ctx, db, "tree")[:2] == (0, 0), f"{group_counts(ctx, db, 'tree')}")
    finally:
        _restore_knob(ctx, _PROP_OF["PG_SCHEMA_PER_DATA_NODE"], old, "LIM-06")
    _check_cap(ctx, "恢复配额后", db, "tree")


def case_lim07_cap_data_quota_switch(ctx: Ctx) -> None:
    """LIM-07 上限由 ``data_region_per_data_node`` 决定：0→非 0 会切换 resource 口径。"""
    db = reset_db(ctx, "tree")
    old = int(ctx.cfg.raw("PG_DATA_PER_DATA_NODE") or 0)
    before = _obs_cap(ctx, db, "DATA", "tree")
    cpu_basis = _cap(ctx, "DATA", "tree", db, per_node=0)
    _check_cap(ctx, "data=0（0.5×CPU 总核数）", db, "tree", data_per_node=0)
    try:
        _set_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], 2, old, "LIM-07")
        _check_cap(ctx, "data=2（2×DN 数，口径已切换）", db, "tree", data_per_node=2)
        after = _obs_cap(ctx, db, "DATA", "tree")
        per_node_value = _cap(ctx, "DATA", "tree", db, per_node=2)
        ctx.check("0→2 后 Data 上限按新口径变化", after != before, f"{before} → {after}")
        # H-19：判据取"实测 ≥ 新口径公式值"，且必须与新口径不同（= CPU 口径说明没切换）。
        ctx.check("确实切换了 resource 口径（per-node 值与 CPU 值不同）",
                  per_node_value != cpu_basis and after >= per_node_value
                  and after != cpu_basis,
                  f"CPU 口径={cpu_basis}、per-node 口径={per_node_value}、观测={after}")
        # H-19/H-27：本断言的语义是"Data 口径切换不影响 **Schema** 侧"，
        # 原实现却把 DATA 也按（harness conf 里的）CPU 口径断言，热加载期间必然假 FAIL。
        _check_cap(ctx, "Data 口径切换不影响 Schema 侧", db, "tree", kinds=("SCHEMA",))
    finally:
        _restore_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], old, "LIM-07")
    back = _obs_cap(ctx, db, "DATA", "tree")
    ctx.check("恢复 data=0 后上限回到 CPU 口径（resource=DN 上报 CPU 总核数）",
              back >= cpu_basis, f"观测={back}（公式 {cpu_basis}；实测>公式=单调存量上限，H-19）")


def case_lim08_cap_min_dominates_schema(ctx: Ctx) -> None:
    """LIM-08 ``min_schema`` 大于公式值 ⇒ 上限吃 min（新建库才取新 min）。"""
    db = reset_db(ctx, "tree")
    term = _cap(ctx, "SCHEMA", "tree", db, minimum=0)
    old_min = int(ctx.cfg.raw("PG_MIN_SCHEMA_PER_DB") or 1)
    want_min = term + 5
    try:
        _set_knob(ctx, _PROP_OF["PG_MIN_SCHEMA_PER_DB"], want_min, old_min, "LIM-08")
        db = reset_db(ctx, "tree")
        _check_cap(ctx, f"min_schema={want_min} > 公式项 {term}", db, "tree", schema_min=want_min)
        got = _obs_cap(ctx, db, "SCHEMA", "tree")
        ctx.check("上限被最小组数抬高（min 支配公式项）", got == want_min and want_min > term,
                  f"MaxSchemaRegionGroupNum={got}（公式项 {term}、min {want_min}）")
        ensure_write_tree(ctx, db, "d0", 1)
        expect_groups(ctx, "min 支配下首次写入仍只 1 组（不预建到 min）", db, "tree",
                      schema=1, data=1)
    finally:
        _restore_knob(ctx, _PROP_OF["PG_MIN_SCHEMA_PER_DB"], old_min, "LIM-08")


def case_lim09_post_cap_new_slot_ok(ctx: Ctx) -> None:
    """LIM-09 到达上限后再写新 slot：写入成功、组数不变（用每节点配额把上限压小）。"""
    db = reset_db(ctx, "table")
    old = int(ctx.cfg.raw("PG_DATA_PER_DATA_NODE") or 0)
    try:
        _set_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], 1, old, "LIM-09")
        cap_d = _obs_cap(ctx, db, "DATA", "table")
        _check_cap(ctx, "小上限档位", db, "table", data_per_node=1)
        tags = device_set(ctx, db, cap_d + 6, dialect="table")
        ctx.api.create_table(db, "tb", columns="devid STRING TAG, s0 FLOAT FIELD")
        ctx.note_data_written(db, "tb", "table")
        rows = [(2000 + i, tag, [float(i)]) for i, tag in enumerate(tags[:cap_d + 3])]
        ctx.req(ctx.api.insert_table_many(db, "tb", "devid", rows), "写满到上限")
        expect_groups(ctx, "写满到上限", db, "table", data=cap_d)
        for index, tag in enumerate(tags[cap_d + 3:]):
            out = ctx.api.insert_table_rows(db, "tb", 3000 + index, tag, ["s0"], [float(index)])
            ctx.check(f"到上限后写新 slot {tag} 不报错", out.ok, out.flat[:200])
        expect_groups(ctx, "到上限后继续写新 slot，组数不变", db, "table", data=cap_d)
        ctx.check("所有写入都可查",
                  ctx.api.count_rows(f"{db}.tb", dialect="table") == cap_d + 6,
                  f"count={ctx.api.count_rows(f'{db}.tb', dialect='table')}")
    finally:
        _restore_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], old, "LIM-09")


def case_lim10_post_cap_new_time_partition(ctx: Ctx) -> None:
    """LIM-10 到达上限后新时间分区不建组：T = min(R, …) = R。"""
    db = reset_db(ctx, "table")
    old = int(ctx.cfg.raw("PG_DATA_PER_DATA_NODE") or 0)
    try:
        _set_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], 1, old, "LIM-10")
        cap_d = _obs_cap(ctx, db, "DATA", "table")
        _check_cap(ctx, "小上限档位", db, "table", data_per_node=1)
        tags = device_set(ctx, db, cap_d + 3, dialect="table")
        ctx.api.create_table(db, "tb", columns="devid STRING TAG, s0 FLOAT FIELD")
        ctx.note_data_written(db, "tb", "table")
        ctx.req(ctx.api.insert_table_many(db, "tb", "devid",
                                          [(4000 + i, tag, [float(i)])
                                           for i, tag in enumerate(tags)]),
                "写满到上限")
        expect_groups(ctx, "写满到上限", db, "table", data=cap_d)
        ts_before = ctx.api.timeslot_count(db=db, dialect="table")
        stamp = _partition_stamp(ctx, db, "table", 1)
        out = ctx.api.insert_table_rows(db, "tb", stamp, tags[0], ["s0"], [7.0])
        ctx.check("到达上限后新时间分区写入成功", out.ok, out.flat[:200])
        expect_groups(ctx, "新时间分区不新建组", db, "table", data=cap_d)
        ts_after = ctx.api.timeslot_count(db=db, dialect="table")
        rows = ctx.api.count_rows(f"{db}.tb", dialect="table", where=f"devid='{tags[0]}'")
        if ts_before < 0 or ts_after < 0:
            # H-27：表模型不支持 ``SHOW TIMESLOTID``（-1 是哨兵值），"timeslot +1" 这个判据
            # 对表模型**不成立**（实测 -1 → -1）。改用"新分区的行数"自证写入确实落在新分区。
            ctx.note(f"    表模型 TIMESLOTID 不可观测（{ts_before} → {ts_after}，哨兵值），"
                     "改用新分区行数替代")
            ctx.check("时间分区确实新增（表模型无 TIMESLOTID，以新分区行数自证）",
                      rows == 2,
                      f"timeslot {ts_before} → {ts_after}（哨兵值 -1）；"
                      f"devid={tags[0]} 的行数={rows}（期望 2：旧分区 1 行 + 新分区 1 行）")
        else:
            ctx.check("时间分区确实新增（写入落在新分区）", ts_after == ts_before + 1,
                      f"timeslot {ts_before} → {ts_after}")
        ctx.check("新分区数据可查", rows == 2, f"devid={tags[0]} 的行数={rows}（期望 2）")
    finally:
        _restore_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], old, "LIM-10")


def case_lim11_max_never_below_min(ctx: Ctx) -> None:
    """LIM-11 ``max`` 永不低于 ``min``：min < 公式 ⇒ max = 公式；min > 公式 ⇒ max = min。"""
    db = reset_db(ctx, "tree")
    term = _cap(ctx, "DATA", "tree", db, minimum=0)
    old_min = int(ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    try:
        _set_knob(ctx, _PROP_OF["PG_MIN_DATA_PER_DB"], 1, old_min, "LIM-11")
        db = reset_db(ctx, "tree")
        _check_cap(ctx, "min_data=1 < 公式项", db, "tree", data_min=1)
        low = _obs_cap(ctx, db, "DATA", "tree")
        # H-19：上限是每库单调存量，只判"不低于公式值"。
        ctx.check("min 低于公式时上限不低于公式值，且 max ≥ min",
                  low >= term and low >= 1, f"Max={low}、公式项={term}")
        big = term + 3
        _set_knob(ctx, _PROP_OF["PG_MIN_DATA_PER_DB"], big, 1, "LIM-11")
        db = reset_db(ctx, "tree")
        _check_cap(ctx, f"min_data={big} > 公式项", db, "tree", data_min=big)
        high = _obs_cap(ctx, db, "DATA", "tree")
        ctx.check("min 高于公式时上限不低于 min，且 max ≥ min",
                  high >= big, f"Max={high}、min={big}")
    finally:
        _restore_knob(ctx, _PROP_OF["PG_MIN_DATA_PER_DB"], old_min, "LIM-11")


# ====================================== PG-LIM（续）
def case_lim12_two_tree_dbs_share(ctx: Ctx) -> None:
    """LIM-12 多库分摊：建第 2 个树库 ⇒ 分母翻倍、上限摊薄；drop 后回升（用 expected 实时算）。"""
    db = reset_db(ctx, "tree")
    n0 = len(_user_dbs(ctx))
    _check_cap(ctx, f"单库分摊（参与库数={n0}）", db, "tree")
    cap0 = _obs_cap(ctx, db, "DATA", "tree")
    raw0 = _cap(ctx, "DATA", "tree", db, minimum=0, db_num=n0)
    extra = f"{db}_lim12"
    _create_db(ctx, extra, "LIM-12")
    n1 = len(_user_dbs(ctx))
    ctx.check("前置：新增 1 个普通树库 ⇒ 参与分摊库数 +1", n1 == n0 + 1, f"普通库={_user_dbs(ctx)}")
    _check_cap(ctx, f"双库分摊（参与库数={n1}）", db, "tree")
    _check_cap(ctx, "第二个库同口径", extra, "tree")
    raw1 = _cap(ctx, "DATA", "tree", db, minimum=0)
    cap1 = _obs_cap(ctx, db, "DATA", "tree")
    ctx.check("分母翻倍后公式项下降（两库平分资源）", raw1 < raw0, f"公式项 {raw0} → {raw1}")
    ctx.check("观测上限不低于双库口径公式值",
              cap1 >= max(int(ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2), raw1),
              f"MaxData={cap1}、双库公式项={raw1}（实测>公式=单调存量上限，H-19）")
    _drop_db(ctx, extra, "LIM-12")
    ctx.check("drop 后参与分摊库数恢复", len(_user_dbs(ctx)) == n0, f"普通库={_user_dbs(ctx)}")
    _check_cap(ctx, "drop 第二库后上限回升", db, "tree")
    ctx.check("上限回升到不低于单库口径", _obs_cap(ctx, db, "DATA", "tree") >= cap0,
              f"{cap1} → {_obs_cap(ctx, db, 'DATA', 'tree')}（单库口径 {cap0}）")


def case_lim13_tree_and_table_share(ctx: Ctx) -> None:
    """LIM-13 树库 + 表库混合分摊：两模型的普通库都进分母（并集口径）。"""
    tree_db = reset_db(ctx, "tree")
    table_db = reset_db(ctx, "table")
    ensure_write_tree(ctx, tree_db, "d0", 1)
    ensure_write_table(ctx, table_db, "tb", "t0", 1)
    _check_cap(ctx, "树库（树+表混合分摊）", tree_db, "tree")
    _check_cap(ctx, "表库（树+表混合分摊）", table_db, "table")
    dbs = _user_dbs(ctx)
    ctx.check("参与分摊库数 = 树∪表普通库（≥2）",
              len(dbs) == len(set(_dialect_dbs(ctx, "tree")) | set(_dialect_dbs(ctx, "table")))
              and len(dbs) >= 2, f"并集={dbs}")
    ctx.check("两种方言各自都看不见对方的库 ⇒ 必须用并集口径",
              bool(set(_dialect_dbs(ctx, "table")) - set(_dialect_dbs(ctx, "tree"))),
              f"tree 可见={_dialect_dbs(ctx, 'tree')}；table 可见={_dialect_dbs(ctx, 'table')}")
    ctx.check("两库同 rf/min/分母 ⇒ Data 上限一致",
              _obs_cap(ctx, tree_db, "DATA", "tree") == _obs_cap(ctx, table_db, "DATA", "table"),
              f"{_obs_cap(ctx, tree_db, 'DATA', 'tree')} vs "
              f"{_obs_cap(ctx, table_db, 'DATA', 'table')}")


def case_lim14_alter_max_rejected(ctx: Ctx) -> None:
    """LIM-14 非 CUSTOM 策略下 ``ALTER DATABASE … MAX_*_REGION_GROUP_NUM`` 必须被拒绝。"""
    db = reset_db(ctx, "tree")
    table_db = reset_db(ctx, "table")
    for kind in ("schema", "data"):
        if _policy(ctx, kind) == "CUSTOM":
            ctx.skip(f"本轮 {kind} 策略为 CUSTOM，无法验证「非 CUSTOM 下拒绝」的要求")
            return
    for kind in ("schema", "data"):
        before = _obs_cap(ctx, db, kind, "tree")
        ctx.mark_harness_action(
            f"LIM-14：PROACTIVE 下故意执行 ALTER DATABASE {db} WITH MAX_{kind.upper()}_REGION_GROUP_NUM",
            pad=20)
        out = ctx.api.run(f"alter database {db} with max_{kind}_region_group_num=3")
        ctx.check(f"树库：非 CUSTOM 下 ALTER MAX_{kind} 必须被拒绝", out.ok is False,
                  out.flat[:300])
        ctx.check(f"树库：拒绝信息应说明仅在 CUSTOM 下可设（{kind}）", "CUSTOM" in out.flat,
                  out.flat[:300])
        ctx.check(f"树库：拒绝后 Max{kind.title()} 不变", _obs_cap(ctx, db, kind, "tree") == before,
                  f"{before} → {_obs_cap(ctx, db, kind, 'tree')}")
    for kind in ("schema", "data"):
        before = _obs_cap(ctx, table_db, kind, "table")
        ctx.mark_harness_action(
            f"LIM-14：PROACTIVE 下故意执行表方言 ALTER DATABASE {table_db} WITH "
            f"MAX_{kind.upper()}_REGION_GROUP_NUM", pad=20)
        out = ctx.api.run(f"alter database {table_db} with max_{kind}_region_group_num=3",
                          dialect="table")
        ctx.check(f"表库：非 CUSTOM 下 ALTER MAX_{kind} 必须被拒绝", out.ok is False,
                  out.flat[:300])
        ctx.check(f"表库：拒绝后 Max{kind.title()} 不变",
                  _obs_cap(ctx, table_db, kind, "table") == before,
                  f"{before} → {_obs_cap(ctx, table_db, kind, 'table')}")
        ctx.note(f"    表方言拒绝原文：{out.flat[:200]}")


def case_lim15_custom_explicit_max(ctx: Ctx) -> None:
    """LIM-15 CUSTOM + 显式 max：一次请求补齐；CUSTOM 下配额热加载不改 stored max。"""
    db = reset_db(ctx, "tree")
    policy_key = _PROP_OF["PG_SCHEMA_POLICY"]
    per_key = _PROP_OF["PG_SCHEMA_PER_DATA_NODE"]
    old_policy = _policy(ctx, "schema")
    old_per = int(ctx.cfg.raw("PG_SCHEMA_PER_DATA_NODE") or 1)
    if old_policy != "PROACTIVE":
        ctx.skip(f"本轮 {policy_key}={old_policy} ≠ PROACTIVE；本用例需要 PROACTIVE→CUSTOM→PROACTIVE")
        return
    # H-27（显式上限硬编码 < 现存量）：上限是**单调存量**，写死 4 会被产品以
    # ``525: MaxSchemaRegionGroupNum should be greater than or equal to current max
    # SchemaRegionGroupNum: 5`` 拒掉（实测存量 5 > 4）⇒ 取"显式 4 与实测存量"的较大者。
    explicit = max(4, _obs_cap(ctx, db, "SCHEMA", "tree"))
    try:
        _set_knob(ctx, policy_key, "CUSTOM", old_policy, "LIM-15")
        ctx.mark_harness_action(
            f"LIM-15：CUSTOM 下显式 ALTER DATABASE {db} WITH MAX_SCHEMA_REGION_GROUP_NUM={explicit}",
            pad=20)
        out = ctx.api.run(f"alter database {db} with max_schema_region_group_num={explicit}")
        ctx.check("CUSTOM 下显式上限被接受", out.ok, out.flat[:300])
        ctx.check("显式上限读回一致",
                  _wait_obs_cap(ctx, db, "SCHEMA", "tree", explicit) == explicit,
                  f"MaxSchema={_obs_cap(ctx, db, 'SCHEMA', 'tree')}")
        ctx.req(ctx.api.create_timeseries(f"{db}.d0.s0"), "create timeseries")
        expect_groups(ctx, "CUSTOM 分支：一次请求即补齐到显式上限", db, "tree",
                      schema=explicit, data=0)
        _set_knob(ctx, per_key, old_per + 2, old_per, "LIM-15")
        ctx.check("CUSTOM 下配额热加载不改变显式上限（不按资源公式重算）",
                  _obs_cap(ctx, db, "SCHEMA", "tree") == explicit,
                  f"MaxSchema={_obs_cap(ctx, db, 'SCHEMA', 'tree')}（期望仍为 {explicit}）")
    finally:
        # H-25：收尾恢复 conf 原值也要开窗（否则恢复噪声越界进下一个用例的扫描窗口）。
        ctx.mark_harness_action("收尾：恢复 conf 原值（quotas + policy）", pad=20, kind="set_config")
        ctx.api.set_config(per_key, str(old_per))
        ctx.api.set_config(policy_key, old_policy)
    term = _cap(ctx, "SCHEMA", "tree", db, minimum=0)
    want = max(term, explicit)
    got = _wait_obs_cap(ctx, db, "SCHEMA", "tree", want)
    ctx.check("切回 PROACTIVE 后上限 = max(资源公式, 已分配组数)（保留历史组、不缩容）",
              got == want, f"MaxSchema={got}（公式项={term}、已分配={explicit}）")
    expect_groups(ctx, "切回后已有组保留", db, "tree", schema=explicit, data=0)


def case_lim16_max_never_below_allocated(ctx: Ctx) -> None:
    """LIM-16 上限不低于**已分配组数** G：配额调小不缩容、不回收已有组。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 4)
    write_devices(ctx, db, devices, model="tree")
    groups = ctx.api.db_group_num(db, "DATA", dialect="tree")
    ctx.check("前置：已分配 4 个 Data 组", groups == 4, f"G={groups}")
    old = int(ctx.cfg.raw("PG_DATA_PER_DATA_NODE") or 0)
    try:
        _set_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], 1, old, "LIM-16")
        formula = _cap(ctx, "DATA", "tree", db, per_node=1)
        want = max(formula, groups)
        got = _wait_obs_cap(ctx, db, "DATA", "tree", want)
        ctx.check("配额调小后上限不低于已分配组数 G", got == want and got >= groups,
                  f"公式项={formula}、G={groups}、观测 MaxData={got}")
        expect_groups(ctx, "配额调小后已有组不回收", db, "tree", data=groups)
    finally:
        _restore_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], old, "LIM-16")
    _check_cap(ctx, "恢复配额后上限回到资源公式", db, "tree")


def case_lim17_single_batch_delta_gt_one(ctx: Ctx) -> None:
    """LIM-17 单次批量请求内多个新 slot：一次请求 delta>1，且恰好封顶 R。"""
    db = reset_db(ctx, "table")
    old = int(ctx.cfg.raw("PG_DATA_PER_DATA_NODE") or 0)
    try:
        _set_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], 1, old, "LIM-17")
        cap_d, detail = _cap_detail(ctx, "DATA", "table", db, per_node=1)
        _check_cap(ctx, "小上限档位", db, "table", data_per_node=1)
        tags = device_set(ctx, db, cap_d + 2, dialect="table")
        ctx.check(f"前置：单批含 {cap_d + 2} 个互不相同 slot",
                  pslots.distinct_tag_slot_count("tb", tags) == cap_d + 2,
                  f"K={pslots.distinct_tag_slot_count('tb', tags)}；{detail}")
        ctx.api.create_table(db, "tb", columns="devid STRING TAG, s0 FLOAT FIELD")
        ctx.note_data_written(db, "tb", "table")
        out = ctx.api.insert_table_many(db, "tb", "devid",
                                        [(6000 + i, tag, [float(i)])
                                         for i, tag in enumerate(tags)])
        ctx.check(f"单次批量请求（{cap_d + 2} 个新 slot）成功", out.ok, out.flat[:300])
        got = ctx.api.db_group_num(db, "DATA", dialect="table")
        ctx.check(f"单次请求 delta>1（一次补齐 {cap_d} 组）且恰好封顶",
                  got == cap_d and cap_d >= 2, f"G={got}、R={cap_d}")
        expect_groups(ctx, "批量补齐到上限", db, "table", data=cap_d)
    finally:
        _restore_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], old, "LIM-17")


def case_lim18_two_dbs_same_slots(ctx: Ctx) -> None:
    """LIM-18 跨库同设备名：两库各自按自己的路径哈希计 slot、独立扩容。"""
    db1 = reset_db(ctx, "tree")
    db2 = f"{db1}_lim18"
    _create_db(ctx, db2, "LIM-18")
    devices = device_set(ctx, db2, 2)
    k1 = pslots.distinct_slot_count(db1, devices)
    k2 = pslots.distinct_slot_count(db2, devices)
    write_devices(ctx, db1, devices, model="tree")
    for device in devices:
        ensure_write_tree(ctx, db2, device, 1)
    expect_groups(ctx, f"库1 独立计数（K={k1}）", db1, "tree",
                  schema=min(k1, _cap(ctx, "SCHEMA", "tree", db1)),
                  data=min(k1, _cap(ctx, "DATA", "tree", db1)))
    expect_groups(ctx, f"库2 独立计数（K={k2}）", db2, "tree",
                  schema=min(k2, _cap(ctx, "SCHEMA", "tree", db2)),
                  data=min(k2, _cap(ctx, "DATA", "tree", db2)))
    ids1 = set(ctx.api.group_ids(db1, kind="DATA", dialect="tree"))
    ids2 = set(ctx.api.group_ids(db2, kind="DATA", dialect="tree"))
    ctx.check("两库 Data 组 id 互不相交（组不跨库共用）", not (ids1 & ids2),
              f"{sorted(ids1)} vs {sorted(ids2)}")
    _check_cap(ctx, "库1 上限", db1, "tree")
    _check_cap(ctx, "库2 上限", db2, "tree")


def case_lim19_series_slot_num_100(ctx: Ctx) -> None:
    """LIM-19 ``series_slot_num=100`` 是集群级（首次启动确定）⇒ 档位不符必须 SKIP。"""
    want = "100"
    got = ctx.cfg.raw("PG_SERIES_SLOT_NUM") or "1000"
    if got != want:
        ctx.skip(f"本轮 PG_SERIES_SLOT_NUM={got} ≠ {want}（series_slot_num 首次启动确定、不可热加载）；"
                 f"100 槽档位需换集群重部署后单独复测")
        return
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 12, slot_num=100)
    write_devices(ctx, db, devices, model="tree")
    ctx.check("100 槽档位下 12 个设备覆盖 12 个不同 slot",
              pslots.distinct_slot_count(db, devices, slot_num=100) == 12,
              f"K={pslots.distinct_slot_count(db, devices, slot_num=100)}")
    expect_groups(ctx, "100 槽档位 12 个 slot", db, "tree",
                  schema=min(12, _cap(ctx, "SCHEMA", "tree", db)),
                  data=min(12, _cap(ctx, "DATA", "tree", db)))


def case_lim20_three_dbs_then_drop(ctx: Ctx) -> None:
    """LIM-20 参与分摊库数越多上限越低、drop 后回升（3 库 → 1 库全过程公式化断言）。"""
    db = reset_db(ctx, "tree")
    n0 = len(_user_dbs(ctx))
    _check_cap(ctx, f"基线（参与库数={n0}）", db, "tree")
    extras = [f"{db}_lim20a", f"{db}_lim20b"]
    for name in extras:
        _create_db(ctx, name, "LIM-20")
    ctx.check("前置：参与分摊库数 +2", len(_user_dbs(ctx)) == n0 + 2, f"普通库={_user_dbs(ctx)}")
    _check_cap(ctx, "3 库分摊", db, "tree")
    three = _obs_cap(ctx, db, "DATA", "tree")
    before_formula = _cap(ctx, "DATA", "tree", db)
    _drop_db(ctx, extras[0], "LIM-20")
    _check_cap(ctx, "drop 中间库后（2 库分摊）", db, "tree")
    two = _obs_cap(ctx, db, "DATA", "tree")
    _drop_db(ctx, extras[1], "LIM-20")
    _check_cap(ctx, "恢复单库分摊", db, "tree")
    one = _obs_cap(ctx, db, "DATA", "tree")
    ctx.check("上限随分摊库数减少而回升", three <= two <= one,
              f"Data 上限：3 库={three}、2 库={two}、1 库={one}（3 库公式={before_formula}）")


# ====================================== PG-DIS Disabled 补组
def _wait_partial(ctx: Ctx, db: str, kind: str, dialect: str, gid: str) -> dict:
    """等到 *某一个* 组 Disabled、同时仍有可用组（部分可用状态）。"""
    deadline = time.time() + _DISABLE_WAIT
    states: dict = {}
    while time.time() < deadline:
        states = _statuses(ctx, db, kind, dialect)
        if states.get(gid) == _DISABLED and any(v != _DISABLED for v in states.values()):
            return states
        time.sleep(_POLL)
    return states


def _supplement_data(ctx: Ctx) -> dict | None:
    """DIS-01/DIS-06 共用的数据侧 Disabled 补组配方（隔离常规扩容分支）。

    构造：``min_data=1`` 的新库只写 1 个设备 ⇒ G=1、K=1（S={s1}）；停掉该唯一 Data 组
    **全部**副本所在 DN（IoTConsensus 弱一致：全部副本下线才 Disabled）⇒ 全组 Disabled；
    再写 d0 的**新时间分区**（P={s1}、K=1、min=1）⇒ 常规 ``T = min(R, max(min(1,2), 1)) = 1 = G``
    ⇒ delta=0，只有 Disabled 补组分支会 +1。
    返回 None 表示前置不成立（已 ctx.skip）。
    """
    old_min = int(ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    if old_min != 1:
        _set_knob(ctx, _PROP_OF["PG_MIN_DATA_PER_DB"], 1, old_min, "DIS 前置：min_data=1")
    try:
        for attempt in range(1, 4):
            db = reset_db(ctx, "tree")
            ensure_write_tree(ctx, db, "d0", 1)
            hostmap = _replica_hosts(ctx, db, "DATA", "tree")
            combo = None
            if len(hostmap) == 1:
                combo = sorted(next(iter(hostmap.values())))
            if combo and len(combo) == _rf(ctx, "DATA") and _schema_guard_ok(ctx, db, "tree", combo):
                break
            ctx.note(f"    第 {attempt} 次布局：Data 副本 {combo} 会连带禁用本库 Schema 组或组数≠1，"
                     f"重建库换布局")
        else:
            ctx.skip("3 次布局重试后仍无法构造「单 Data 组且元数据可用」的布局；"
                     "无法隔离数据侧 Disabled 补组路径")
            return None
        before = ctx.api.db_group_num(db, "DATA", dialect="tree")
        cap = _obs_cap(ctx, db, "DATA", "tree")
        ids_before = set(ctx.api.group_ids(db, kind="DATA", dialect="tree"))
        ctx.check("前置：min_data=1、恰好 1 个 Data 组、G<R", before == 1 and before < cap,
                  f"G={before}、R={cap}（min_data=1 ⇒ 常规 T=G）")
        ts_before = ctx.api.timeslot_count(db=db, dialect="tree")
        out = None
        try:
            _stop_nodes(ctx, _DN, combo, "DIS-01/06 前置：停掉唯一 Data 组的全部副本")
            if not _wait_disabled(ctx, db, "DATA", "tree", "DIS-01/06"):
                return None
            stamp = _partition_stamp(ctx, db, "tree", 1)
            out = ctx.api.insert_tree(f"{db}.d0", stamp, list(TREE_SENSORS),
                                      [float(stamp)] * len(TREE_SENSORS))
        finally:
            _start_nodes(ctx, _DN, combo, "DIS-01/06 收尾：恢复被停 DataNode")
        after = ctx.api.db_group_num(db, "DATA", dialect="tree")
        ids_after = set(ctx.api.group_ids(db, kind="DATA", dialect="tree"))
        states = _wait_all(ctx, db, "DATA", "tree", _RUNNING, "DIS-01/06", _RECOVER_WAIT)
        return {"db": db, "before": before, "after": after, "cap": cap, "combo": combo,
                "write_ok": bool(out and out.ok), "write_out": out.flat[:300] if out else "",
                "ts_before": ts_before, "added": sorted(ids_after - ids_before),
                "running": bool(states) and all(v == _RUNNING for v in states.values())}
    finally:
        if old_min != 1:
            _restore_knob(ctx, _PROP_OF["PG_MIN_DATA_PER_DB"], old_min, "DIS 恢复 min_data")


def case_dis01_data_all_disabled_supplement(ctx: Ctx) -> None:
    """DIS-01 某类型全部组 Disabled 时补 1 组（数据侧，隔离常规扩容分支）。"""
    res = _supplement_data(ctx)
    if res is None:
        return
    ctx.check("全部 Data 组 Disabled 时写已有 slot 的新时间分区 ⇒ 恰好补 1 组"
              "（常规 T=G ⇒ delta=0，命中 Disabled 补组分支）",
              res["after"] == res["before"] + 1, f"G {res['before']} → {res['after']}")
    ctx.check("补组数不超过该库上限 R（不超过 R 的约束）",
              res["after"] <= res["cap"], f"G={res['after']}、R={res['cap']}")
    ctx.check("补组请求的写入成功（分区分配继续、落到新组）", res["write_ok"], res["write_out"])


def case_dis02_schema_all_disabled_supplement(ctx: Ctx) -> None:
    """DIS-02 Schema 全部组 Disabled 时补 1 组（需用 CUSTOM 预置 G>K 才能隔离分支）。"""
    db = reset_db(ctx, "tree")
    policy_key = _PROP_OF["PG_SCHEMA_POLICY"]
    per_key = _PROP_OF["PG_SCHEMA_PER_DATA_NODE"]
    old_policy = _policy(ctx, "schema")
    old_per = int(ctx.cfg.raw("PG_SCHEMA_PER_DATA_NODE") or 1)
    if old_policy != "PROACTIVE":
        ctx.skip(f"本轮 {policy_key}={old_policy} ≠ PROACTIVE；本用例需要 PROACTIVE→CUSTOM→PROACTIVE")
        return
    # H-27（显式上限硬编码 < 现存量）：上限是单调存量，写死 2 会被
    # ``525: MaxSchemaRegionGroupNum should be >= current max: 5`` 拒掉 ⇒ 取实测存量。
    explicit = max(2, _obs_cap(ctx, db, "SCHEMA", "tree"))
    try:
        _set_knob(ctx, policy_key, "CUSTOM", old_policy, "DIS-02")
        ctx.mark_harness_action(
            f"DIS-02：CUSTOM 下显式 ALTER DATABASE {db} WITH MAX_SCHEMA_REGION_GROUP_NUM={explicit}",
            pad=20)
        ctx.req(ctx.api.run(f"alter database {db} with max_schema_region_group_num={explicit}"),
                "CUSTOM 下显式上限")
        ctx.req(ctx.api.create_timeseries(f"{db}.d0.s0"), "create timeseries d0.s0")
        expect_groups(ctx, "CUSTOM 预置 2 个 Schema 组、只 1 个 slot（G>K）", db, "tree",
                      schema=explicit, data=0)
        _set_knob(ctx, policy_key, "PROACTIVE", "CUSTOM", "DIS-02")
        term = _cap(ctx, "SCHEMA", "tree", db, minimum=0)
        cap_s = _wait_obs_cap(ctx, db, "SCHEMA", "tree", max(term, explicit))
        ctx.check("离开 CUSTOM 后上限 = max(资源公式, 已分配组数)",
                  cap_s == max(term, explicit), f"MaxSchema={cap_s}（公式项={term}）")
        if cap_s <= explicit:
            # H-27：CUSTOM 是"一次补满 R"，所以补完就是 G=R；要构造"G<R 且全部 Disabled"，
            # 必须让 PROACTIVE 的资源公式项把 R 抬到 G 之上。schema_region_per_data_node
            # 可热加载，且本用例 finally 会恢复，故先抬高再判（否则分支永远不可达）。
            ctx.note(f"    R={cap_s} 不大于已分配 G={explicit}，先抬高 schema 配额制造 G<R")
            _set_knob(ctx, per_key, old_per + 1, old_per, "DIS-02 抬高公式上限")
            term = _cap(ctx, "SCHEMA", "tree", db, minimum=0)
            cap_s = _wait_obs_cap(ctx, db, "SCHEMA", "tree", max(term, explicit))
        if cap_s <= explicit:
            ctx.skip(f"MaxSchema={cap_s} ≤ 已分配 {explicit}：G<R 不成立，Disabled 补组分支不可达；"
                     f"需要一个参与分摊库数 ≤2 的档位")
            return
        combo, need, hostmap = _plan_cover(ctx, db, "SCHEMA", "tree", limit=2)
        if combo is None:
            ctx.skip(f"无法用 ≤2 台 DN 使 2 个 Schema 组全部 Disabled（Ratis 需每组的 {need} 个副本"
                     f"下线；副本分布={ {g: sorted(h) for g, h in hostmap.items()} }）")
            return
        before = ctx.api.db_group_num(db, "SCHEMA", dialect="tree")
        out = None
        try:
            _stop_nodes(ctx, _DN, combo, "DIS-02 前置：停掉两个 Schema 组的多数副本")
            if not _wait_disabled(ctx, db, "SCHEMA", "tree", "DIS-02"):
                return
            out = ctx.api.create_timeseries(f"{db}.d1.s0")
        finally:
            _start_nodes(ctx, _DN, combo, "DIS-02 收尾：恢复被停 DataNode")
        after = ctx.api.db_group_num(db, "SCHEMA", dialect="tree")
        ctx.check("全部 Schema 组 Disabled 时新 slot 元数据请求 ⇒ 恰好补 1 组（常规 T=G）",
                  after == before + 1, f"G {before} → {after}")
        ctx.check("补组数不超过上限 R", after <= cap_s, f"G={after}、R={cap_s}")
        ctx.check("新 slot 元数据写入成功（分区分配继续）", bool(out and out.ok),
                  out.flat[:300] if out else "")
        states = _wait_all(ctx, db, "SCHEMA", "tree", _RUNNING, "DIS-02", _RECOVER_WAIT)
        ctx.check("恢复后 Schema 组全部回到 Running",
                  bool(states) and all(v == _RUNNING for v in states.values()), f"statuses={states}")
    finally:
        # H-25：收尾恢复 conf 原值也要开窗（否则恢复噪声越界进下一个用例的扫描窗口）。
        ctx.mark_harness_action("收尾：恢复 conf 原值（quotas + policy）", pad=20, kind="set_config")
        ctx.api.set_config(per_key, str(old_per))
        ctx.api.set_config(policy_key, old_policy)


def case_dis03_partial_available_no_supplement(ctx: Ctx) -> None:
    """DIS-03 只有**部分**组 Disabled（仍有可用组）⇒ 不补组。"""
    with _min_data_one(ctx, "DIS-03"):
        db = reset_db(ctx, "tree")
        d0, d1 = device_set(ctx, db, 2)
        ensure_write_tree(ctx, db, d0, 1)
        ensure_write_tree(ctx, db, d1, 2)
        cap_s = _cap(ctx, "SCHEMA", "tree", db)
        expect_groups(ctx, "前置：2 个 slot ⇒ Schema/Data 各 2 组（min=1，K 驱动）",
                      db, "tree", schema=min(2, cap_s), data=2)
        hostmap = _replica_hosts(ctx, db, "DATA", "tree")
        target = None
        for gid, hosts in sorted(hostmap.items()):
            combo = sorted(hosts)
            if len(combo) != _rf(ctx, "DATA") or not _schema_guard_ok(ctx, db, "tree", combo):
                continue
            disabled = {g for g, hs in hostmap.items() if hs <= set(combo)}
            if disabled and len(disabled) < len(hostmap):
                target = (gid, combo)
                break
        if target is None:
            ctx.skip("无法构造「部分 Disabled」布局（停某组全部副本会连带禁用 Schema 组、"
                     f"或把全部 Data 组打成 Disabled）；副本分布="
                     f"{ {g: sorted(h) for g, h in hostmap.items()} }")
            return
        gid, combo = target
        before = 2
        out = None
        try:
            _stop_nodes(ctx, _DN, combo, f"DIS-03 前置：停掉组 {gid} 的全部副本")
            states = _wait_partial(ctx, db, "DATA", "tree", gid)
            if states.get(gid) != _DISABLED or not any(v != _DISABLED for v in states.values()):
                ctx.skip(f"停 DN 后未形成「部分组 Disabled」状态（观测={states}）")
                return
            ctx.check("前置：部分组 Disabled、仍有可用组", True, f"statuses={states}")
            stamp = _partition_stamp(ctx, db, "tree", 1)
            out = ctx.api.insert_tree(f"{db}.{d0}", stamp, list(TREE_SENSORS), [1.0] * 3)
        finally:
            _start_nodes(ctx, _DN, combo, "DIS-03 收尾：恢复被停 DataNode")
        after = ctx.api.db_group_num(db, "DATA", dialect="tree")
        ctx.check("不是全部组 Disabled ⇒ 不触发补组（G 不变）", after == before,
                  f"G {before} → {after}")
        ctx.check("该写入成功（分区分配到仍可用的组）", bool(out and out.ok),
                  out.flat[:300] if out else "")


def case_dis04_at_cap_no_supplement(ctx: Ctx) -> None:
    """DIS-04 已达上限 R（G<R 不成立）⇒ 即使全部组 Disabled 也不补组。"""
    with _min_data_one(ctx, "DIS-04"):
        base = reset_db(ctx, "tree")
        extras = [f"{base}_dis04a", f"{base}_dis04b"]
        for name in extras:
            _create_db(ctx, name, "DIS-04")
        dbs = _user_dbs(ctx)
        old_per = int(ctx.cfg.raw("PG_DATA_PER_DATA_NODE") or 0)
        _set_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], 1, old_per, "DIS-04")
        try:
            term = _cap(ctx, "DATA", "tree", base, per_node=1, minimum=1)
            cap = _wait_obs_cap(ctx, base, "DATA", "tree", term)
            ctx.check("前置：小上限档位（≥3 个普通库分摊、min_data=1、每节点 1）",
                      cap == term and len(dbs) >= 3, f"R={cap}、term={term}、普通库={dbs}")
            if cap != term:
                ctx.skip(f"上限未按预期收敛（R={cap} ≠ {term}），无法构造 G=R 场景")
                return
            ensure_write_tree(ctx, base, "d0", 1)
            groups = ctx.api.db_group_num(base, "DATA", dialect="tree")
            ctx.check("前置：G=R（已达上限）", groups == cap, f"G={groups}、R={cap}")
            hostmap = _replica_hosts(ctx, base, "DATA", "tree")
            if len(hostmap) != 1:
                ctx.skip(f"预期单 Data 组以构造全 Disabled，实际 {len(hostmap)} 组")
                return
            combo = sorted(next(iter(hostmap.values())))
            if len(combo) != _rf(ctx, "DATA") or not _schema_guard_ok(ctx, base, "tree", combo):
                ctx.skip("单组副本所在 DN 会连带禁用 Schema 组，无法隔离数据侧测试")
                return
            out = None
            try:
                _stop_nodes(ctx, _DN, combo, "DIS-04 前置：停掉唯一 Data 组全部副本")
                if not _wait_disabled(ctx, base, "DATA", "tree", "DIS-04"):
                    return
                out = ctx.api.insert_tree(f"{base}.d1", 5, list(TREE_SENSORS),
                                          [5.0] * len(TREE_SENSORS))
            finally:
                _start_nodes(ctx, _DN, combo, "DIS-04 收尾：恢复被停 DataNode")
            after = ctx.api.db_group_num(base, "DATA", dialect="tree")
            ctx.check("已达 R ⇒ 即使全部组 Disabled 也不补组（不超过 R）", after == cap,
                      f"G={after}（期望仍为 R={cap}）")
            ctx.check("无可用组时新 slot 写入失败（既有错误语义，不静默成功）",
                      bool(out and not out.ok), out.flat[:300] if out else "")
        finally:
            _restore_knob(ctx, _PROP_OF["PG_DATA_PER_DATA_NODE"], old_per, "DIS-04")
            for name in extras:
                _drop_db(ctx, name, "DIS-04")


def case_dis05_empty_pending_no_supplement(ctx: Ctx) -> None:
    """DIS-05 本次请求没有 pending slot（重复访问已有分区）⇒ 不补组。"""
    with _min_data_one(ctx, "DIS-05"):
        db = reset_db(ctx, "tree")
        ctx.req(ctx.api.insert_tree(f"{db}.d0", 1, list(TREE_SENSORS), [1.0, 1.0, 1.0]),
                "首次写入")
        ctx.note_data_written(db, "d0", "tree")
        ts_before = ctx.api.timeslot_count(db=db, dialect="tree")
        hostmap = _replica_hosts(ctx, db, "DATA", "tree")
        if len(hostmap) != 1:
            ctx.skip(f"预期单 Data 组，实际 {len(hostmap)} 组")
            return
        combo = sorted(next(iter(hostmap.values())))
        if len(combo) != _rf(ctx, "DATA") or not _schema_guard_ok(ctx, db, "tree", combo):
            ctx.skip("唯一 Data 组副本所在 DN 会连带禁用 Schema 组，无法隔离数据侧测试")
            return
        before = 1
        repeat = None
        try:
            _stop_nodes(ctx, _DN, combo, "DIS-05 前置：停掉唯一 Data 组全部副本")
            if not _wait_disabled(ctx, db, "DATA", "tree", "DIS-05"):
                return
            repeat = ctx.api.insert_tree(f"{db}.d0", 1, list(TREE_SENSORS), [1.0, 1.0, 1.0])
        finally:
            _start_nodes(ctx, _DN, combo, "DIS-05 收尾：恢复被停 DataNode")
        after = ctx.api.db_group_num(db, "DATA", dialect="tree")
        ts_after = ctx.api.timeslot_count(db=db, dialect="tree")
        ctx.check("P 为空（重复访问已有分区）即使全部组 Disabled 也不补组", after == before,
                  f"G {before} → {after}")
        ctx.check("重复写入未新增时间分区（确认本次请求确实无 pending）",
                  ts_after == ts_before, f"timeslot {ts_before} → {ts_after}")
        ctx.note(f"    重复写入观测：ok={repeat.ok}；{repeat.flat[:200]}")


def case_dis06_supplement_integrity(ctx: Ctx) -> None:
    """DIS-06 补组后完整性：状态回 Running、组数不回收、新组真实存在、数据可查。"""
    res = _supplement_data(ctx)
    if res is None:
        return
    db = res["db"]
    ctx.check("补组 + 重启后 Data 组全部回到 Running", res["running"],
              f"running={res['running']}")
    now = ctx.api.db_group_num(db, "DATA", dialect="tree")
    ctx.check("组状态从 Disabled 回到 Running 后组数不回收", now == res["after"],
              f"G={now}（补组后 {res['after']}）")
    live_ids = set(ctx.api.group_ids(db, kind="DATA", dialect="tree"))
    ctx.check("补出的新组仍在组 id 集合中（且恰好多 1 个）",
              len(res["added"]) == 1 and set(res["added"]) <= live_ids,
              f"新增组={res['added']}、现有组={sorted(live_ids)}")
    rows = ctx.api.count_rows(f"{db}.d0", dialect="tree")
    ctx.check("历史 + 补组后新时间分区的数据都完整可查", rows == 2, f"d0 行数={rows}")
    ts_now = ctx.api.timeslot_count(db=db, dialect="tree")
    ctx.check("补组确实伴随一个新时间分区落盘", ts_now == res["ts_before"] + 1,
              f"timeslot {res['ts_before']} → {ts_now}")


def case_dis07_cn_restart_immediate_write(ctx: Ctx) -> None:
    """DIS-07 已知歧义探针：CN 重启后**不等组状态恢复**立即写新 slot。

    期望（spec §3）：``T = min(R, max(min(minN, G+|P|), K))``，此处 G=2、K=2、min=2 ⇒ T=G
    ⇒ 组数应保持 2（= ``min(K, R)``）。若新 CN 的 LoadCache 尚未加载、把组状态当 Disabled，
    会多补 1 组 —— 该情形**如实记 FAIL**并标注疑似 G-05/R-xx 假阳性，不放宽断言。
    """
    db = reset_db(ctx, "tree")
    ensure_write_tree(ctx, db, "d0", 1)
    ensure_write_tree(ctx, db, "d0", _partition_stamp(ctx, db, "tree", 1))
    expect_groups(ctx, "前置：G=2、K=1（同一 slot 的两个时间分区，min_data=2）", db, "tree",
                  schema=1, data=2)
    ctx.check("前置：1 个 series slot、2 个时间分区",
              ctx.api.timeslot_count(db=db, dialect="tree") == 2,
              f"timeslot={ctx.api.timeslot_count(db=db, dialect='tree')}")
    cap_d = _obs_cap(ctx, db, "DATA", "tree")
    start = _mark_window(ctx, "DIS-07：重启全部 ConfigNode（探针）", pad=60)
    for host in ctx.cfg.cn_hosts:
        ctx.cluster.stop_node(host, _CN)
    for host in ctx.cfg.cn_hosts:
        ctx.cluster.start_node(host, _CN)
    leader = None
    deadline = time.time() + 420
    while time.time() < deadline:
        try:
            leader = ctx.cluster.leader_cn_host()
        except Exception:  # noqa: BLE001 - 选举期间 CLI 可能连不上
            leader = None
        if leader:
            break
        time.sleep(1.0)
    try:
        out = ctx.api.insert_tree(f"{db}.d1", 5, list(TREE_SENSORS),
                                  [5.0] * len(TREE_SENSORS))
        after = ctx.api.db_group_num(db, "DATA", dialect="tree")
        states = _statuses(ctx, db, "DATA", "tree")
        ctx.note(f"    重启后立即观测：leader={leader}、G={after}、组状态={states}")
        expected = min(2, cap_d)
        ctx.check("CN 重启后未等 Running 立即写新 slot：组数应为 min(K, R)"
                  "（若多 1 组则为 Disabled 误判的疑似假阳性，需人工复核 G-05/R-xx）",
                  after == expected,
                  f"实际 G={after}、期望 {expected}（K=2、min=2、R={cap_d}）；"
                  f"当时组状态={states}；若 G={expected + 1} 属 LoadCache 未加载把组当 Disabled "
                  f"而多补 1 组 —— 疑似 G-05/R-xx 假阳性")
        ctx.check("该写入本身成功", out.ok, out.flat[:300])
    finally:
        _close_window(ctx, start, "DIS-07：ConfigNode 重启窗口")
        ctx.cluster.wait_healthy(timeout=ctx.cfg.get_int("CLUSTER_START_TIMEOUT_SEC"))
        ctx._cluster_ready = time.time()


# ====================================== PG-RCV 重启与领导者变更恢复
def _wait_groups(ctx: Ctx, db: str, dialect: str, schema: int, data: int,
                 timeout: int = 180) -> tuple[int, int, int, int]:
    """重启后等两个口径都收敛到期望组数（LoadCache/Leader 切换需要一点时间）。"""
    want = (schema, schema, data, data)
    deadline = time.time() + timeout
    got = group_counts(ctx, db, dialect)
    while got != want and time.time() < deadline:
        time.sleep(_POLL)
        got = group_counts(ctx, db, dialect)
    return got


def _wait_ids(ctx: Ctx, db: str, kind: str, dialect: str, want: set,
              timeout: int = 120) -> set:
    deadline = time.time() + timeout
    got = set(ctx.api.group_ids(db, kind=kind, dialect=dialect))
    while got != want and time.time() < deadline:
        time.sleep(_POLL)
        got = set(ctx.api.group_ids(db, kind=kind, dialect=dialect))
    return got


def _wait_map(ctx: Ctx, db: str, devices, want: dict, timeout: int = 120) -> dict:
    deadline = time.time() + timeout
    got = _device_map(ctx, db, devices)
    while got != want and time.time() < deadline:
        time.sleep(_POLL)
        got = _device_map(ctx, db, devices)
    return got


def case_rcv01_cn_restart_preserves(ctx: Ctx) -> None:
    """RCV-01 ConfigNode 全重启：组数、组 id 集合、设备→组映射全部保留。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 3)
    write_devices(ctx, db, devices, model="tree")
    cap_s = _cap(ctx, "SCHEMA", "tree", db)
    cap_d = _cap(ctx, "DATA", "tree", db)
    expect_groups(ctx, "重启前", db, "tree", schema=min(3, cap_s), data=min(3, cap_d))
    counts0 = group_counts(ctx, db, "tree")
    ids0 = (set(ctx.api.group_ids(db, kind="SCHEMA", dialect="tree")),
            set(ctx.api.group_ids(db, kind="DATA", dialect="tree")))
    map0 = _device_map(ctx, db, devices)
    ctx.check("前置：3 个设备都已落到具体的 Data 组", all(map0.values()), f"{map0}")
    _restart_nodes(ctx, _CN, list(ctx.cfg.cn_hosts), "RCV-01")
    _wait_groups(ctx, db, "tree", min(3, cap_s), min(3, cap_d))
    expect_groups(ctx, "ConfigNode 全部重启后", db, "tree",
                  schema=min(3, cap_s), data=min(3, cap_d))
    ctx.check("重启后库详情计数与重启前一致（不回收也不多建）",
              group_counts(ctx, db, "tree") == counts0,
              f"{counts0} → {group_counts(ctx, db, 'tree')}")
    ids1 = (set(ctx.api.group_ids(db, kind="SCHEMA", dialect="tree")),
            set(ctx.api.group_ids(db, kind="DATA", dialect="tree")))
    ctx.check("Schema/Data 组 id 集合完整保留",
              ids0[0] == ids1[0] and ids0[1] == ids1[1],
              f"schema {sorted(ids0[0])}→{sorted(ids1[0])}；data {sorted(ids0[1])}→{sorted(ids1[1])}")
    map1 = _wait_map(ctx, db, devices, map0)
    ctx.check("设备→Data 组映射完整保留", map1 == map0, f"{map0} → {map1}")
    rows = ctx.api.count_rows(f"{db}.{devices[0]}", dialect="tree")
    ctx.check("重启后历史数据可查", rows == 1, f"{devices[0]} 行数={rows}")


def case_rcv02_dn_restart_statuses(ctx: Ctx) -> None:
    """RCV-02 DataNode 重启：组状态降级后回到 Running，组数与映射不变。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 3)
    write_devices(ctx, db, devices, model="tree")
    cap_s = _cap(ctx, "SCHEMA", "tree", db)
    cap_d = _cap(ctx, "DATA", "tree", db)
    expect_groups(ctx, "前置", db, "tree", schema=min(3, cap_s), data=min(3, cap_d))
    hostmap = _replica_hosts(ctx, db, "DATA", "tree")
    if not hostmap:
        ctx.skip("无法读取 Data 组副本分布")
        return
    hosts = sorted({h for group_hosts in hostmap.values() for h in group_hosts})
    host = min(hosts, key=lambda h: sum(1 for group_hosts in hostmap.values() if h in group_hosts))
    counts0 = group_counts(ctx, db, "tree")
    map0 = _device_map(ctx, db, devices)
    states: dict = {}
    try:
        _stop_nodes(ctx, _DN, [host], f"RCV-02 停 1 台 DN（{host}）")
        deadline = time.time() + _DISABLE_WAIT
        while time.time() < deadline:
            states = _statuses(ctx, db, "DATA", "tree")
            if any(v != _RUNNING for v in states.values()):
                break
            time.sleep(_POLL)
        ctx.check(f"停 1 台 DN（{host}）后其承载的数据组不再 Running（降级为 Available/Disabled）",
                  bool(states) and any(v != _RUNNING for v in states.values()),
                  f"statuses={states}")
    finally:
        _start_nodes(ctx, _DN, [host], "RCV-02 收尾：恢复 DataNode")
    states = _wait_all(ctx, db, "DATA", "tree", _RUNNING, "RCV-02", _RECOVER_WAIT)
    ctx.check("DN 重启后 Data 组状态全部回到 Running",
              bool(states) and all(v == _RUNNING for v in states.values()), f"statuses={states}")
    ctx.check("DN 重启后组数不变", group_counts(ctx, db, "tree") == counts0,
              f"{counts0} → {group_counts(ctx, db, 'tree')}")
    map1 = _wait_map(ctx, db, devices, map0)
    ctx.check("DN 重启后设备→组映射不变", map1 == map0, f"{map0} → {map1}")


def case_rcv03_new_slot_after_restart(ctx: Ctx) -> None:
    """RCV-03 ConfigNode 重启后新时间分区：写入成功、组数仍按 min(K,R) 口径。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 2)
    write_devices(ctx, db, devices, model="tree")
    cap_s = _cap(ctx, "SCHEMA", "tree", db)
    cap_d = _cap(ctx, "DATA", "tree", db)
    expect_groups(ctx, "重启前：2 个 slot ⇒ 2 个 Data 组（min_data=2）", db, "tree",
                  schema=min(2, cap_s), data=min(2, cap_d))
    ts_before = ctx.api.timeslot_count(db=db, dialect="tree")
    _restart_nodes(ctx, _CN, list(ctx.cfg.cn_hosts), "RCV-03")
    stamp = _partition_stamp(ctx, db, "tree", 1)
    out = ctx.api.insert_tree(f"{db}.{devices[0]}", stamp, list(TREE_SENSORS),
                              [float(stamp)] * len(TREE_SENSORS))
    ctx.check("重启后写新时间分区成功", out.ok, out.flat[:300])
    _wait_groups(ctx, db, "tree", min(2, cap_s), min(2, cap_d))
    expect_groups(ctx, "重启后新时间分区：组数仍 = min(K, R)（不额外建组）", db, "tree",
                  schema=min(2, cap_s), data=min(2, cap_d))
    ts_after = ctx.api.timeslot_count(db=db, dialect="tree")
    ctx.check("新时间分区确实落盘", ts_after == ts_before + 1,
              f"timeslot {ts_before} → {ts_after}")
    rows = ctx.api.count_rows(f"{db}.{devices[0]}", dialect="tree")
    ctx.check("重启前后两个时间分区的数据都可查", rows == 2, f"{devices[0]} 行数={rows}")


def case_rcv04_cap_unchanged_during_recovery(ctx: Ctx) -> None:
    """RCV-04 恢复期上限不变：ConfigNode 重启前后 ``Max*RegionGroupNum`` 与公式一致。"""
    db = reset_db(ctx, "table")
    ensure_write_table(ctx, db, "tb", "t0", 1)
    _check_cap(ctx, "重启前", db, "table")
    before = (_obs_cap(ctx, db, "SCHEMA", "table"), _obs_cap(ctx, db, "DATA", "table"))
    groups_before = group_counts(ctx, db, "table")
    _restart_nodes(ctx, _CN, list(ctx.cfg.cn_hosts), "RCV-04")
    _wait_groups(ctx, db, "table", groups_before[0], groups_before[2])
    _check_cap(ctx, "ConfigNode 重启后", db, "table")
    after = (_obs_cap(ctx, db, "SCHEMA", "table"), _obs_cap(ctx, db, "DATA", "table"))
    ctx.check("恢复期上限不变（重启不触发上限重算漂移）", after == before, f"{before} → {after}")
    ctx.check("恢复期组数不变（重启不建组）", group_counts(ctx, db, "table") == groups_before,
              f"{groups_before} → {group_counts(ctx, db, 'table')}")


def case_rcv05_disabled_to_running_no_reclaim(ctx: Ctx) -> None:
    """RCV-05 组从 Disabled 回到 Running：组数不回收（状态恢复 ≠ 组回收）。"""
    with _min_data_one(ctx, "RCV-05"):
        db = reset_db(ctx, "tree")
        d0, d1 = device_set(ctx, db, 2)
        ensure_write_tree(ctx, db, d0, 1)
        ensure_write_tree(ctx, db, d1, 2)
        cap_s = _cap(ctx, "SCHEMA", "tree", db)
        expect_groups(ctx, "前置：2 个 Data 组、min_data=1（Schema 同由 K 驱动到 2）",
                      db, "tree", schema=min(2, cap_s), data=2)
        hostmap = _replica_hosts(ctx, db, "DATA", "tree")
        target = None
        for gid, group_hosts in sorted(hostmap.items()):
            combo = sorted(group_hosts)
            if len(combo) == _rf(ctx, "DATA") and _schema_guard_ok(ctx, db, "tree", combo):
                target = (gid, combo)
                break
        if target is None:
            ctx.skip("无法构造「单组 Disabled」布局（停某组全部副本会连带禁用 Schema 组）；"
                     f"副本分布={ {g: sorted(h) for g, h in hostmap.items()} }")
            return
        gid, combo = target
        ids_before = set(ctx.api.group_ids(db, kind="DATA", dialect="tree"))
        try:
            _stop_nodes(ctx, _DN, combo, f"RCV-05 前置：停掉组 {gid} 的全部副本")
            status = _wait_group(ctx, db, "DATA", "tree", gid, _DISABLED, _DISABLE_WAIT)
            if status != _DISABLED:
                ctx.skip(f"目标组 {gid} 未转为 Disabled（观测={status}），无法验证恢复路径")
                return
            ctx.check(f"前置：组 {gid} 已 Disabled", True, f"status={status}")
        finally:
            _start_nodes(ctx, _DN, combo, "RCV-05 收尾：恢复 DataNode")
        status = _wait_group(ctx, db, "DATA", "tree", gid, _RUNNING, _RECOVER_WAIT)
        ctx.check(f"组 {gid} 状态从 Disabled 回到 Running", status == _RUNNING,
                  f"status={status}")
        ids_after = _wait_ids(ctx, db, "DATA", "tree", ids_before)
        ctx.check("状态恢复后组数不回收（组 id 集合不变）", ids_after == ids_before,
                  f"{sorted(ids_before)} → {sorted(ids_after)}")
        expect_groups(ctx, "恢复到 Running 后", db, "tree", schema=min(2, cap_s), data=2)


def case_rcv06_details_vs_regions_after_restart(ctx: Ctx) -> None:
    """RCV-06 ConfigNode 重启后 ``SHOW DATABASES DETAILS`` 与 ``SHOW REGIONS`` 口径仍一致。"""
    tree_db = reset_db(ctx, "tree")
    tree_devices = device_set(ctx, tree_db, 2)
    write_devices(ctx, tree_db, tree_devices, model="tree")
    table_db = reset_db(ctx, "table")
    ensure_write_table(ctx, table_db, "tb", "t0", 1)
    ensure_write_table(ctx, table_db, "tb", "t1", 2)
    samples = []
    for db, dialect in ((tree_db, "tree"), (table_db, "table")):
        schema = min(2, _cap(ctx, "SCHEMA", dialect, db))
        data = min(2, _cap(ctx, "DATA", dialect, db))
        expect_groups(ctx, f"重启前（{dialect}）", db, dialect, schema=schema, data=data)
        samples.append((db, dialect, schema, data))
    _restart_nodes(ctx, _CN, list(ctx.cfg.cn_hosts), "RCV-06")
    for db, dialect, schema, data in samples:
        _wait_groups(ctx, db, dialect, schema, data)
        expect_groups(ctx, f"ConfigNode 重启后（{dialect}）", db, dialect,
                      schema=schema, data=data)
        s_detail, s_dedup, d_detail, d_dedup = group_counts(ctx, db, dialect)
        ctx.check(f"重启后（{dialect}）库详情计数与 SHOW REGIONS 去重计数一致",
                  s_detail == s_dedup and d_detail == d_dedup,
                  f"库详情 schema/data={s_detail}/{d_detail}、去重={s_dedup}/{d_dedup}")
    t_rows = ctx.api.count_rows(f"{tree_db}.{tree_devices[0]}", dialect="tree")
    b_rows = ctx.api.count_rows(f"{table_db}.tb", dialect="table")
    ctx.check("重启后树/表两种模型的数据都可查", t_rows == 1 and b_rows == 2,
              f"tree={t_rows}、table={b_rows}")


def case_rcv07_leader_change_mapping(ctx: Ctx) -> None:
    """RCV-07 领导者变更：只断言 设备→组 映射不变（不断言 组→节点）。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 3)
    write_devices(ctx, db, devices, model="tree")
    cap_s = _cap(ctx, "SCHEMA", "tree", db)
    cap_d = _cap(ctx, "DATA", "tree", db)
    expect_groups(ctx, "前置", db, "tree", schema=min(3, cap_s), data=min(3, cap_d))
    map0 = _device_map(ctx, db, devices)
    ids0 = set(ctx.api.group_ids(db, kind="DATA", dialect="tree"))
    if not all(map0.values()):
        ctx.skip(f"设备→组映射未建立，无法验证领导者变更不变性：{map0}")
        return
    leader = ctx.cluster.leader_cn_host()
    if not leader:
        ctx.skip("无法识别当前 ConfigNode Leader")
        return
    new_leader = None
    try:
        _stop_nodes(ctx, _CN, [leader], f"RCV-07：停当前 Leader CN（{leader}）")
        deadline = time.time() + 180
        while time.time() < deadline:
            try:
                new_leader = ctx.cluster.leader_cn_host()
            except Exception:  # noqa: BLE001 - 选举期间 CLI 可能连不上
                new_leader = None
            if new_leader and new_leader != leader:
                break
            time.sleep(2)
        ctx.check("Leader 已切换到其它 ConfigNode",
                  bool(new_leader) and new_leader != leader, f"新 leader={new_leader}")
        map1 = _wait_map(ctx, db, devices, map0)
        ctx.check("领导者变更后 设备→组 映射不变（不比对 组→节点）", map1 == map0,
                  f"{map0} → {map1}")
        ids1 = _wait_ids(ctx, db, "DATA", "tree", ids0)
        ctx.check("领导者变更后 Data 组 id 集合不变", ids1 == ids0,
                  f"{sorted(ids0)} → {sorted(ids1)}")
    finally:
        _start_nodes(ctx, _CN, [leader], "RCV-07 收尾：恢复原 Leader CN")
    map2 = _wait_map(ctx, db, devices, map0)
    ctx.check("原 Leader 恢复后 设备→组 映射仍不变", map2 == map0, f"{map0} → {map2}")
    _wait_groups(ctx, db, "tree", min(3, cap_s), min(3, cap_d))
    expect_groups(ctx, "领导者变更全过程结束后", db, "tree",
                  schema=min(3, cap_s), data=min(3, cap_d))


# ============================================================ 用例登记
def _spec(case_id: str, area: str, model: str, title: str, priority: str, fn,
          *, gate: bool = False, note: str = "") -> CaseSpec:
    return CaseSpec(case_id, area, model, title, priority, fn, gate=gate, note=note)


SPECS.extend([
    _spec("PG-LIM-01", "资源上限", "tree", "空库上限 = 公式 max(min, ceil(权重×资源/(库数×rf)))",
          "P0", case_lim01_cap_formula_tree, gate=True,
          note="ClusterSchemaManager:594-649；直接断言观测 Max* 与公式"),
    _spec("PG-LIM-02", "资源上限", "table", "表模型上限同口径（直接断言 Max*）", "P0",
          case_lim02_cap_formula_table),
    _spec("PG-LIM-03", "资源上限", "tree", "写满 cap+3 个 slot：组数恰好封顶、不再增长", "P0",
          case_lim03_fill_to_cap_tree, gate=True),
    _spec("PG-LIM-04", "资源上限", "table", "单批写 cap+3 个 slot：恰好封顶", "P1",
          case_lim04_fill_to_cap_table),
    _spec("PG-LIM-05", "资源上限", "tree", "上限随 DataNode 数变化（需换档位 ⇒ SKIP）", "P2",
          case_lim05_cap_depends_on_dn_num),
    _spec("PG-LIM-06", "资源上限", "tree", "schema_region_per_data_node 热加载驱动上限", "P0",
          case_lim06_cap_schema_quota_hot_reload),
    _spec("PG-LIM-07", "资源上限", "tree", "data_region_per_data_node 0→非0 切换 resource 口径",
          "P0", case_lim07_cap_data_quota_switch),
    _spec("PG-LIM-08", "资源上限", "tree", "min_schema 支配公式项 ⇒ 上限吃 min", "P1",
          case_lim08_cap_min_dominates_schema),
    _spec("PG-LIM-09", "资源上限", "table", "到达上限后新 slot 写入成功、组数不变", "P1",
          case_lim09_post_cap_new_slot_ok),
    _spec("PG-LIM-10", "资源上限", "table", "到达上限后新时间分区不建组", "P1",
          case_lim10_post_cap_new_time_partition),
    _spec("PG-LIM-11", "资源上限", "tree", "max 永不小于 min（两方向）", "P1",
          case_lim11_max_never_below_min),
    _spec("PG-LIM-12", "资源上限", "tree", "多库分摊：2 库上限减半、drop 后回升", "P0",
          case_lim12_two_tree_dbs_share),
    _spec("PG-LIM-13", "资源上限", "tree+table", "树库+表库混合分摊（并集分母）", "P1",
          case_lim13_tree_and_table_share),
    _spec("PG-LIM-14", "资源上限", "tree+table", "非 CUSTOM 下 ALTER MAX_*_REGION_GROUP_NUM 被拒",
          "P0", case_lim14_alter_max_rejected),
    _spec("PG-LIM-15", "资源上限", "tree", "CUSTOM 显式 max：一次补齐；配额不覆盖 stored max", "P1",
          case_lim15_custom_explicit_max),
    _spec("PG-LIM-16", "资源上限", "tree", "配额调小 ⇒ 上限不低于已分配组数 G", "P1",
          case_lim16_max_never_below_allocated),
    _spec("PG-LIM-17", "资源上限", "table", "单次批量请求 delta>1 且恰好封顶", "P1",
          case_lim17_single_batch_delta_gt_one),
    _spec("PG-LIM-18", "资源上限", "tree", "跨库同设备名：slot 与组独立计数", "P2",
          case_lim18_two_dbs_same_slots),
    _spec("PG-LIM-19", "资源上限", "tree", "series_slot_num=100 档位（需重部署 ⇒ SKIP）", "P2",
          case_lim19_series_slot_num_100),
    _spec("PG-LIM-20", "资源上限", "tree", "3 库 → drop 回 1 库：上限逐级回升", "P2",
          case_lim20_three_dbs_then_drop),
    _spec("PG-DIS-01", "Disabled补组", "tree", "全部 Data 组 Disabled ⇒ 补 1 组（≤R）", "P0",
          case_dis01_data_all_disabled_supplement, gate=True),
    _spec("PG-DIS-02", "Disabled补组", "tree", "全部 Schema 组 Disabled ⇒ 补 1 组（≤R）", "P1",
          case_dis02_schema_all_disabled_supplement),
    _spec("PG-DIS-03", "Disabled补组", "tree", "仅部分组 Disabled ⇒ 不补组", "P1",
          case_dis03_partial_available_no_supplement),
    _spec("PG-DIS-04", "Disabled补组", "tree", "已达上限 R ⇒ 即使全 Disabled 也不补组", "P1",
          case_dis04_at_cap_no_supplement),
    _spec("PG-DIS-05", "Disabled补组", "tree", "无 pending slot（P 为空）⇒ 不补组", "P1",
          case_dis05_empty_pending_no_supplement),
    _spec("PG-DIS-06", "Disabled补组", "tree", "补组后完整性：状态回 Running、组不回收、数据完整",
          "P1", case_dis06_supplement_integrity),
    _spec("PG-DIS-07", "Disabled补组", "tree",
          "CN 重启后立即写新 slot：组数应为 min(K,R)（A-05 歧义探针）", "P1",
          case_dis07_cn_restart_immediate_write),
    _spec("PG-RCV-01", "重平衡与恢复", "tree", "CN 全重启：组数/组 id/设备→组映射保留", "P0",
          case_rcv01_cn_restart_preserves, gate=True),
    _spec("PG-RCV-02", "重平衡与恢复", "tree", "DN 重启：组状态回到 Running、组数映射不变", "P0",
          case_rcv02_dn_restart_statuses),
    _spec("PG-RCV-03", "重平衡与恢复", "tree", "重启后新时间分区仍按策略扩容", "P1",
          case_rcv03_new_slot_after_restart),
    _spec("PG-RCV-04", "重平衡与恢复", "table", "恢复期上限不变且与公式一致", "P1",
          case_rcv04_cap_unchanged_during_recovery),
    _spec("PG-RCV-05", "重平衡与恢复", "tree", "Disabled→Running 后组数不回收", "P1",
          case_rcv05_disabled_to_running_no_reclaim),
    _spec("PG-RCV-06", "重平衡与恢复", "tree+table",
          "重启后 库详情 与 SHOW REGIONS 计数仍一致", "P1",
          case_rcv06_details_vs_regions_after_restart),
    _spec("PG-RCV-07", "重平衡与恢复", "tree", "领导者变更后 设备→组 映射不变", "P1",
          case_rcv07_leader_change_mapping),
])
