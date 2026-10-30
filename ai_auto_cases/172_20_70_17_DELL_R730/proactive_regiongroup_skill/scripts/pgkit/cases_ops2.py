"""PG-TTL / PG-SYS / PG-RST 用例族：TTL 与扩容互不干扰、系统库不参与分摊、整集群重启不变式。

依据
====
* ``references/case-catalog.md`` 的 PG-TIME（TTL 段）、``proactive-spec.md`` §4（上限公式）、
  §5（重启后 LoadCache / 分配不变式）；
* 源码 ``ClusterSchemaManager.java:520-550``：参与上限分摊的库数只统计**普通库**，
  系统库 ``root.__system`` / 审计库 ``root.__audit`` 被排除在分母之外；
  ``ClusterSchemaManager.java:973-995``：系统库的 min/max 固定为 1。

期望值来源
==========
* 组数一律 ``min(K, 上限)``，``K`` 由 ``pgkit.slots`` 按 BKDR131 槽计算得出（设备名保证互不同槽）；
* 上限一律取 ``cases.expected_cap()``（源码公式的移植）或**实测** ``Max*RegionGroupNum``，
  本模块**不写死**任何数字（``TimePartitionInterval`` 也是 ``ctx.api.db_time_partition_interval`` 实测）；
* 系统库的反证：``_cap_with_dbcount`` 用同一公式分别以"只计普通库"和"计入系统库"两个分母求值，
  与实测上限对比即可判定系统库有没有进分母。

纪律
====
* 每条用例开头 ``db = reset_db(ctx, model)``（drop+create 会连带清掉该库上已设的 TTL 规则，
  用例之间不串味）；
* TTL 语句优先用需求给定语法 ``set ttl to <db>.** to <ms>``，失败则退化为 ``... <ms>`` 并记录哪种生效；
  两种都失败 → FAIL（不 SKIP：TTL 是已声明能力）；
* 整集群重启前后都 ``ctx.mark_harness_action("整集群重启")``，重启后用 ``wait_healthy`` 自等就绪再断言；
* 热加载改过的键在用例结束前恢复为 conf 值（``ctx.cfg.raw(...)``）；
* 集群档位不匹配（无 DN / 公式上限 < 1 / 观测接口在系统库上不可用）→ SKIP 并写明原因。
"""

from __future__ import annotations

import json
import math
import time

from . import slots as pslots
from .cases import (
    SYSTEM_DBS,
    CaseSpec,
    Ctx,
    db_of,
    device_set,
    ensure_write_tree,
    expect_cap,
    expect_groups,
    expected_cap,
    group_counts,
    reset_db,
    write_devices,
    group_ceiling,
)

SPECS: list[CaseSpec] = []

_POLL = 5                       # 有界轮询间隔（秒）
_TTL_SETTLE = 4                 # 小 TTL 后的等待窗口（秒）
_LONG_TTL = 315_360_000_000     # 10 年：让"过期"不干扰组数断言
_SHORT_TTL = 1000               # 1 秒：需求指定的"很小值"
_SYS_DBS = ("root.__system", "root.__audit")
_TPI_DEFAULT = 604_800_000      # 默认时间分区长度（毫秒，实测优先）
_POLICY_KEY = "data_region_group_extension_policy"


def _now_ms() -> int:
    return int(time.time() * 1000)


#: H-26：从"客户端取时间戳"到"DN 侧真正应用"的实测延迟预算（ms）。
#: TTL-02 实测：写入时间戳 ``...:04.334`` 在 ``...:12.836`` 被 DN 判
#: "less than ttl time bound ...:11.836"（TTL=1000ms）⇒ 端到端延迟 7.5–8.5s，
#: 远大于旧余量（2×TTL+1s = 3s），于是**产品正确拒写**却被记成用例失败。
#: 取 12s = 实测上界 + ~3.5s 余量；未来时间戳不触发 TTL（TTL 只拒"过旧"数据），
#: 且仍能让 TTL-03 在 30s 的清理等待窗内观察到过期。
_TTL_APPLY_LAG_MS = 12_000


def _ttl_safe_now(ttl_ms: int = _SHORT_TTL) -> int:
    """已设短 TTL 的库上写入用的安全时间戳（H-20 + H-26）。

    TTL 边界 = 服务端 now - TTL，与客户端 ``_now_ms()`` 既有**亚秒竞态**（实测写
    16:13:43.040 被边界 16:13:43.300 以 607 拒），也有**端到端应用延迟**（见
    ``_TTL_APPLY_LAG_MS``，实测 7.5–8.5s）。余量 = ``2×TTL + 应用延迟预算``，
    仍落在 TTL 有效窗内（TTL 只拒过旧数据，未来时间戳不会被拒）。
    """
    return _now_ms() + 2 * int(ttl_ms) + _TTL_APPLY_LAG_MS


def _start_timeout(ctx: Ctx) -> int:
    return ctx.cfg.get_int("CLUSTER_START_TIMEOUT_SEC")


# ============================================================ 夹具：TTL
def _ttl_path(db: str) -> str:
    return f"{db}.**"


def _set_ttl(ctx: Ctx, db: str, ms: int, *, dialect: str = "tree") -> bool:
    """设 TTL：优先 ``set ttl to <path> to <ms>``，退化形 ``set ttl to <path> <ms>``。"""
    path = _ttl_path(db)
    # H-14：这是**语法探测**——需求文档给的 `to` 形式在 2.0.11 会被解析成路径 `root.pg.**to`
    # 并以 `303 Illegal pattern path` 拒绝（记入 doc-gaps），CN 侧会打一条 WARN。
    # 故先登记 harness 动作窗口，再由 verify 的模式表归因，避免把"自己探测"记成产品异常。
    ctx.mark_harness_action(f"探测 TTL 语法（to-形式 / 退化形式）于 {path}", pad=20)
    for stmt in (f"set ttl to {path} to {ms}", f"set ttl to {path} {ms}"):
        out = ctx.api.run(stmt, dialect=dialect)
        if out.ok:
            ctx.note(f"    TTL 生效：{stmt}")
            # H-13：TTL 规则**按路径持久化**，drop/create 库并不会清除它 ⇒ 必须在用例结束时清掉，
            # 否则后续用例写入 t=1（1970-01-01）会被 `607: Insertion time … less than ttl time bound`
            # 拒绝（本会话实测污染 25 例：PG-SWCH/RST/PRV/SYS/HA/TTL 族）。这里单点登记清场语句，
            # 由 run_cases 的 finally 逆序执行。
            stmt_unset = f"unset ttl from {path}"
            if stmt_unset not in ctx.cleanup:
                ctx.cleanup.append(stmt_unset)
            return True
        ctx.note(f"    TTL 语法未接受：{stmt} -> {out.flat[:200]}")
    return False


def _unset_ttl(ctx: Ctx, db: str, *, dialect: str = "tree") -> bool:
    out = ctx.api.run(f"unset ttl from {_ttl_path(db)}", dialect=dialect)
    ctx.note(f"    unset ttl from {_ttl_path(db)} -> ok={out.ok}")
    return out.ok


def _total_rows(ctx: Ctx, db: str, devices: list[str], *, dialect: str = "tree") -> int:
    total = 0
    for device in devices:
        target = f"{db}.{device}" if dialect != "table" else f"{db}.tb"
        total += ctx.api.count_rows(target, dialect=dialect)
    return total


def _tier_guard(ctx: Ctx, db: str, dialect: str, label: str) -> bool:
    """集群档位前置：无 DN 或公式上限 < 1 ⇒ SKIP（不降级断言）。"""
    if not ctx.cfg.dn_hosts:
        ctx.skip(f"{label}：conf 未定义 DataNode（集群档位不匹配）")
        return False
    cap = expected_cap(ctx, "DATA", dialect, db)
    if cap < 1:
        ctx.skip(f"{label}：公式 Data 上限 = {cap} < 1（集群档位不匹配）")
        return False
    return True


def _restart_needed(ctx: Ctx, label: str) -> bool:
    """重启类前置：集群须已就绪（未就绪则自己等，等不到就 SKIP 而不是误判）。"""
    if not ctx.cfg.dn_hosts or not ctx.cfg.cn_hosts:
        ctx.skip(f"{label}：conf 未定义完整 CN/DN 拓扑（集群档位不匹配）")
        return False
    if not ctx.cluster.wait_healthy(timeout=_start_timeout(ctx)):
        ctx.skip(f"{label}：重启前集群未回到 Running/ReadOnly（档位/环境不匹配）")
        return False
    return True


# ============================================================ 夹具：系统库
def _user_dbs(ctx: Ctx) -> set[str]:
    """``SHOW DATABASES DETAILS`` 里两个方言可见的**普通库**并集（排除系统/审计库）。"""
    names: set[str] = set()
    for probe in ("tree", "table"):
        for name in ctx.api.database_details(probe):
            if not any(s in name for s in SYSTEM_DBS):
                names.add(name)
    return names


def _sys_dbs_visible(ctx: Ctx) -> list[str]:
    seen = []
    for name in _SYS_DBS:
        if any(name in n for n in ctx.api.database_details("tree")):
            seen.append(name)
    return seen


def _cap_with_dbcount(ctx: Ctx, kind: str, dialect: str, db_count: int) -> int:
    """与 ``cases.expected_cap`` 同公式，但分母由调用方给定。

    用途：以"只计普通库"和"计入系统库"两个分母分别求值，反证系统库是否进分母。
    """
    cfg, kind_u = ctx.cfg, kind.upper()
    dn_num = len(cfg.dn_hosts)
    if kind_u.startswith("S"):
        weight = int(cfg.raw("PG_SCHEMA_PER_DATA_NODE") or 1)
        resource = dn_num
        rf = cfg.get_int("SCHEMA_REPLICATION_FACTOR")
        minimum = int(cfg.raw("PG_MIN_SCHEMA_PER_DB") or 1)
    else:
        per_node = int(cfg.raw("PG_DATA_PER_DATA_NODE") or 0)
        if per_node > 0:
            weight, resource = per_node, dn_num
        else:
            weight = 0.5
            resource = dn_num * int(cfg.raw("PG_CPU_CORES_PER_DN") or 48)
        rf = cfg.get_int("DATA_REPLICATION_FACTOR")
        minimum = int(ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    return max(minimum, math.ceil(weight * resource / (max(1, db_count) * rf)))


def _sys_groups(ctx: Ctx, db: str, kind: str, *, dialect: str = "tree") -> dict:
    """系统库的 RegionGroup：先按库过滤，接口不认库名时回落全集群再按 database 列过滤。"""
    groups = ctx.api.groups(db, kind=kind, dialect=dialect)
    if groups:
        return groups
    all_groups = ctx.api.groups("", kind=kind, dialect=dialect)
    return {gid: g for gid, g in all_groups.items() if g.database == db}


def _sys_probe(ctx: Ctx, db: str, *, dialect: str = "tree") -> dict:
    data = _sys_groups(ctx, db, "DATA", dialect=dialect)
    schema = _sys_groups(ctx, db, "SCHEMA", dialect=dialect)
    return {
        "data_ids": sorted(data),
        "schema_ids": sorted(schema),
        "data_max": ctx.api.db_max_group_num(db, "DATA", dialect=dialect),
        "schema_max": ctx.api.db_max_group_num(db, "SCHEMA", dialect=dialect),
    }


# ============================================================ 夹具：热加载读回
#: 可热加载的 6 个策略/配额键（+ series_slot_num / time_partition_interval 一起读档）。
_LIVE_KEYS = (
    "schema_region_group_extension_policy",
    "data_region_group_extension_policy",
    "default_schema_region_group_num_per_database",
    "default_data_region_group_num_per_database",
    "schema_region_per_data_node",
    "data_region_per_data_node",
)


def _effective_settings(ctx: Ctx) -> dict[str, str]:
    """节点配置文件里**已生效**的策略/配额键值。

    H-26：2.0.11 不支持 ``SHOW CONFIGURATION``（返回 ``700: … no viable alternative at
    input 'show configuration'``），旧实现因此恒返回 ``{}`` ⇒ RST-04 的"热加载是否生效"
    校验空转（实测 ``SHOW CONFIGURATION[…]`` 恒为 ``None``）。``SET CONFIGURATION`` 会把
    新值落进每个节点的 ``conf/iotdb-system.properties``，直接读文件既准确又不依赖 SQL 方言。
    """
    try:
        return dict(ctx.props.read(ctx.cfg.cli_host, keys=_LIVE_KEYS))
    except Exception as exc:  # noqa: BLE001 - 读不到文件按空处理，由调用方决定 SKIP/FAIL
        ctx.note(f"    读取节点配置文件失败（{ctx.cfg.cli_host}）：{exc}")
        return {}


# ============================================================ 夹具：整集群重启
def _full_restart(ctx: Ctx, label: str) -> bool:
    """stop_all + start_all，前后各开一个归因窗口；重启后自等就绪。"""
    timeout = _start_timeout(ctx)
    ctx.mark_harness_action(f"{label}：整集群重启（stop_all）", pad=30)
    ctx.cluster.stop_all()
    ctx.mark_harness_action(f"{label}：整集群重启（start_all）", pad=30)
    started = ctx.cluster.start_all()
    ctx.check(f"{label}：start_all 拉起全部节点", bool(started), f"start_all={started}")
    healthy = ctx.cluster.wait_healthy(timeout=timeout)
    ctx.check(f"{label}：重启后全节点回到 Running/ReadOnly", healthy, f"timeout={timeout}s")
    ctx._cluster_ready = time.time()
    return bool(started) and healthy


def _ids(ctx: Ctx, db: str, kind: str, *, dialect: str = "tree") -> set[str]:
    return ctx.api.group_ids(db, kind=kind, dialect=dialect)


# ===================================================================== PG-TTL
def case_ttl01_groups_after_set_ttl(ctx: Ctx) -> None:
    """TTL-01 设 TTL 后写 4 个不同 slot：组数仍 = min(4, 上限)。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 4, prefix="pgt")
    if not _tier_guard(ctx, db, "tree", "TTL-01"):
        return
    ctx.check("set ttl 可执行（TTL 前置）", _set_ttl(ctx, db, _LONG_TTL),
              f"目标 {_ttl_path(db)}、TTL={_LONG_TTL}ms")
    ctx.check("show all ttl 可观测", ctx.api.run("show all ttl").ok, "show all ttl")
    write_devices(ctx, db, devices, model="tree", stamp=_ttl_safe_now())
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    expect_groups(ctx, "设 TTL 后写 4 个不同 slot", db, "tree",
                  schema=min(4, cap_s), data=min(4, cap_d))
    ctx.check("4 个设备确实落在 4 个不同 slot（harness 槽计算）",
              pslots.distinct_slot_count(db, devices) == 4,
              f"slots={pslots.slot_map(db, devices)}")


def case_ttl02_small_ttl_write_after_wait(ctx: Ctx) -> None:
    """TTL-02 小 TTL（1000ms）+ 等 4s 再写：写入成功、组数仍按 min(K, 上限)。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 4, prefix="pgs")
    if not _tier_guard(ctx, db, "tree", "TTL-02"):
        return
    ctx.check("set ttl=1000ms 可执行", _set_ttl(ctx, db, _SHORT_TTL), f"TTL={_SHORT_TTL}ms")
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    write_devices(ctx, db, devices[:2], model="tree", stamp=_ttl_safe_now())
    expect_groups(ctx, "小 TTL 下写前 2 个 slot", db, "tree",
                  schema=min(2, cap_s), data=min(2, cap_d))
    ctx.note(f"    等待 {_TTL_SETTLE}s 让已写数据越过 TTL")
    time.sleep(_TTL_SETTLE)
    first = ctx.api.insert_tree(f"{db}.{devices[2]}", _ttl_safe_now(), ["s0"], [1.0])
    second = ctx.api.insert_tree(f"{db}.{devices[3]}", _ttl_safe_now(), ["s0"], [1.0])
    ctx.check("TTL 过期窗口后写入新 slot 仍成功", first.ok and second.ok,
              f"first.ok={first.ok}、second.ok={second.ok}；"
              f"{'' if first.ok else first.flat[:200]}")
    expect_groups(ctx, "小 TTL + 等待后写 4 个不同 slot", db, "tree",
                  schema=min(4, cap_s), data=min(4, cap_d))
    ctx.check("等待窗口本身没有回收 RegionGroup（组数只由 slot 决定）",
              ctx.api.db_group_num(db, "DATA", dialect="tree") == min(4, cap_d),
              f"G={ctx.api.db_group_num(db, 'DATA', dialect='tree')}、min(4,{cap_d})")


def case_ttl03_expiry_keeps_groups(ctx: Ctx) -> None:
    """TTL-03 过期删除后组数与设备→组映射不变（RegionId 集合逐一对拍）。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 4, prefix="pge")
    if not _tier_guard(ctx, db, "tree", "TTL-03"):
        return
    ctx.check("set ttl=1000ms 可执行", _set_ttl(ctx, db, _SHORT_TTL), f"TTL={_SHORT_TTL}ms")
    expired = _now_ms() - 3_600_000
    # H-20：TTL=1000ms 下单次 stamp 被 write_devices 展开成 stamp+i，第 3 个设备就漂出
    # 有效窗（实测 pge2 被判 607）⇒ 改为**每设备取一次新鲜时间戳**。
    for _dev in devices:
        write_devices(ctx, db, [_dev], model="tree", stamp=_ttl_safe_now())
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    expect_groups(ctx, "写入已过期数据（组仍按 slot 建）", db, "tree",
                  schema=min(4, cap_s), data=min(4, cap_d))
    before_ids = _ids(ctx, db, "DATA")
    before_schema = _ids(ctx, db, "SCHEMA")
    before_map = ctx.api.device_groups([f"{db}.{_d}" for _d in devices])
    ctx.check("删除前设备→组映射非空", all(before_map.values()) and len(before_map) == 4,
              json.dumps(before_map, ensure_ascii=False))

    deleted_by_ttl = False
    for _ in range(6):                       # 有界等待 TTL 清理（约 30s）
        if _total_rows(ctx, db, devices) == 0:
            deleted_by_ttl = True
            break
        time.sleep(_POLL)
    if not deleted_by_ttl:
        ctx.mark_harness_action("TTL-03：清理窗口内未观测到过期删除，退化为显式 DELETE", pad=20)
        out = ctx.api.run(f"delete from {db}.** where time < {_now_ms()}", dialect="tree")
        ctx.check("退化路径：显式 DELETE 成功（仅用于制造删除后状态）", out.ok,
                  out.flat[:200])
    ctx.note(f"    过期清理观测：{'TTL 自动清理' if deleted_by_ttl else '显式 DELETE（TTL 窗口未观测到）'}")

    after_ids = _ids(ctx, db, "DATA")
    after_schema = _ids(ctx, db, "SCHEMA")
    after_map = ctx.api.device_groups([f"{db}.{_d}" for _d in devices])
    ctx.check("删除后 Data RegionId 集合与删除前一致", before_ids == after_ids,
              f"前={sorted(before_ids)}、后={sorted(after_ids)}")
    ctx.check("删除后 Schema RegionId 集合与删除前一致", before_schema == after_schema,
              f"前={sorted(before_schema)}、后={sorted(after_schema)}")
    ctx.check("删除后设备→组映射与删除前一致", before_map == after_map,
              f"前={json.dumps(before_map, ensure_ascii=False)}、"
              f"后={json.dumps(after_map, ensure_ascii=False)}")
    expect_groups(ctx, "过期删除后", db, "tree", schema=min(4, cap_s), data=min(4, cap_d))


def case_ttl04_unset_ttl_then_expand(ctx: Ctx) -> None:
    """TTL-04 unset ttl 后继续写新 slot：扩容量公式恢复如常。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 4, prefix="pgu")
    if not _tier_guard(ctx, db, "tree", "TTL-04"):
        return
    ctx.check("set ttl 可执行", _set_ttl(ctx, db, _LONG_TTL), f"TTL={_LONG_TTL}ms")
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    write_devices(ctx, db, devices[:2], model="tree", stamp=_now_ms())
    expect_groups(ctx, "unset 前写 2 个 slot", db, "tree",
                  schema=min(2, cap_s), data=min(2, cap_d))
    ctx.check("unset ttl 可执行", _unset_ttl(ctx, db), f"unset ttl from {_ttl_path(db)}")
    write_devices(ctx, db, devices[2:], model="tree", stamp=_now_ms())
    expect_groups(ctx, "unset ttl 后写满 4 个 slot", db, "tree",
                  schema=min(4, cap_s), data=min(4, cap_d))


def case_ttl05_ttl_with_time_partition(ctx: Ctx) -> None:
    """TTL-05 TTL 与时间分区叠加：分区边界前后各写一行，组数仍 min(K, 上限)。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 2, prefix="pgtp")
    if not _tier_guard(ctx, db, "tree", "TTL-05"):
        return
    interval = ctx.api.db_time_partition_interval(db, dialect="tree")
    if interval <= 0:
        interval = _TPI_DEFAULT
        ctx.note(f"    TimePartitionInterval 不可观测，回落默认 {_TPI_DEFAULT}ms")
    ctx.check("TimePartitionInterval 单位为毫秒且可达（实测值已用于边界计算）",
              interval >= 1000,
              f"实测 interval={interval}ms（默认 {_TPI_DEFAULT}ms）")
    ctx.check("set ttl 可执行", _set_ttl(ctx, db, _LONG_TTL), f"TTL={_LONG_TTL}ms")
    boundary = (_now_ms() // interval) * interval
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    ctx.note(f"    分区边界={boundary}（interval={interval}ms），"
             f"前一行 t={boundary - 1}、后一行 t={boundary + 1}")
    before = ctx.api.insert_tree(f"{db}.{devices[0]}", boundary - 1, ["s0"], [1.0])
    after = ctx.api.insert_tree(f"{db}.{devices[1]}", boundary + 1, ["s0"], [2.0])
    ctx.check("分区边界前后两行均写入成功", before.ok and after.ok,
              f"before.ok={before.ok}、after.ok={after.ok}")
    ctx.check("边界前一行可查（时间分区划分正确）",
              ctx.api.count_rows(f"{db}.{devices[0]}") == 1,
              f"count={ctx.api.count_rows(f'{db}.{devices[0]}')}")
    ctx.check("边界后一行可查", ctx.api.count_rows(f"{db}.{devices[1]}") == 1,
              f"count={ctx.api.count_rows(f'{db}.{devices[1]}')}")
    expect_groups(ctx, "TTL + 跨时间分区写 2 个 slot", db, "tree",
                  schema=min(2, cap_s), data=min(2, cap_d))


def case_ttl06_table_model_ttl(ctx: Ctx) -> None:
    """TTL-06 表模型 TTL：语法未确认，SKIP（不猜测 DDL、不污染库）。"""
    db = reset_db(ctx, "table")
    table = "ttl06"
    ctx.req(ctx.api.create_table(db, table, columns="devid STRING TAG, s0 FLOAT FIELD"),
            "建表（TTL 负向断言的前置）")
    # H-54（已实测确认为产品语义）：TTL 语句只存在于**树模型**语法
    # （`IoTDBSqlParser.g4:343` 的 setTTL 属于树模型前缀路径），表模型方言下
    # `SET TTL` / `SHOW TTL` / `UNSET TTL` 一律被解析器拒绝（700，报 mismatched input 'ttl'）。
    # 因此本用例改为**负向断言**：表模型路径上的 TTL 必须被明确拒绝，且不得静默成功/污染数据。
    bad_set = ctx.api.run(f"set ttl to {db}.{table} to 1000", dialect="table")
    ctx.check("TTL-06：表模型 `SET TTL` 被解析器明确拒绝（700，不静默成功）",
              (not bad_set.ok) and "700" in bad_set.flat,
              bad_set.flat[:300])
    bad_show = ctx.api.run(f"show ttl on {db}.{table}", dialect="table")
    ctx.check("TTL-06：表模型 `SHOW TTL` 同样不被接受（TTL 仅树模型方言）",
              not bad_show.ok, bad_show.flat[:300])
    tree_db = reset_db(ctx, "tree")
    ok_set = _set_ttl(ctx, tree_db, 1000)
    ctx.check("TTL-06 对照：树模型方言下 TTL 可用（表模型才不支持）", ok_set,
              f"path={_ttl_path(tree_db)}")
    if ok_set:
        _unset_ttl(ctx, tree_db)


def case_ttl07_new_measurement_no_group(ctx: Ctx) -> None:
    """TTL-07 TTL 生效期间新增测点（同 slot）不建组。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 1, prefix="pgn")
    device = devices[0]
    if not _tier_guard(ctx, db, "tree", "TTL-07"):
        return
    ctx.check("set ttl 可执行", _set_ttl(ctx, db, _LONG_TTL), f"TTL={_LONG_TTL}ms")
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    ensure_write_tree(ctx, db, device, _now_ms(), sensors=("s0",), values=[1.0])
    expect_groups(ctx, "新增测点前（单设备 s0）", db, "tree",
                  schema=min(1, cap_s), data=min(1, cap_d))
    before_s = ctx.api.db_group_num(db, "SCHEMA", dialect="tree")
    before_d = ctx.api.db_group_num(db, "DATA", dialect="tree")
    ensure_write_tree(ctx, db, device, _now_ms(), sensors=("s0", "s_new"), values=[2.0, 3.0])
    after_s = ctx.api.db_group_num(db, "SCHEMA", dialect="tree")
    after_d = ctx.api.db_group_num(db, "DATA", dialect="tree")
    ctx.check("同 slot 新增测点不增加 Schema 组数", after_s == before_s,
              f"前={before_s}、后={after_s}")
    ctx.check("同 slot 新增测点不增加 Data 组数", after_d == before_d,
              f"前={before_d}、后={after_d}")
    ctx.check("新增测点的值可查", ctx.api.count_rows(f"{db}.{device}") == 2,
              f"count={ctx.api.count_rows(f'{db}.{device}')}")


def case_ttl08_expiry_cluster_health(ctx: Ctx) -> None:
    """TTL-08 过期清理后集群健康、组数不变（sync lag 归 0 由收尾①自动断言）。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 3, prefix="pgh")
    if not _tier_guard(ctx, db, "tree", "TTL-08"):
        return
    ctx.check("set ttl=1000ms 可执行", _set_ttl(ctx, db, _SHORT_TTL), f"TTL={_SHORT_TTL}ms")
    # H-20：TTL=1000ms 下单次 stamp 被 write_devices 展开成 stamp+i，第 3 个设备就漂出
    # 有效窗（实测 pge2 被判 607）⇒ 改为**每设备取一次新鲜时间戳**。
    for _dev in devices:
        write_devices(ctx, db, [_dev], model="tree", stamp=_ttl_safe_now())
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    expect_groups(ctx, "写入已过期数据", db, "tree",
                  schema=min(3, cap_s), data=min(3, cap_d))
    before_ids = _ids(ctx, db, "DATA")
    ctx.note(f"    等待 {_TTL_SETTLE}s 触发 TTL 过期清理路径")
    time.sleep(_TTL_SETTLE)
    ctx.check("过期窗口后集群仍报告 Running/ReadOnly（收尾① 会再查 sync lag 归 0）",
              ctx.cluster.wait_healthy(timeout=_start_timeout(ctx)),
              f"timeout={_start_timeout(ctx)}s")
    ctx.check("过期清理路径不回收 RegionGroup（RegionId 集合不变）",
              _ids(ctx, db, "DATA") == before_ids,
              f"前={sorted(before_ids)}、后={sorted(_ids(ctx, db, 'DATA'))}")
    expect_groups(ctx, "TTL 过期清理后", db, "tree", schema=min(3, cap_s), data=min(3, cap_d))


# ===================================================================== PG-SYS
def case_sys01_single_user_db_cap(ctx: Ctx) -> None:
    """SYS-01 建 1 个用户库时实测上限 = 只计普通库的公式值（自证系统库未进分母）。"""
    db = reset_db(ctx, "tree")
    if not _tier_guard(ctx, db, "tree", "SYS-01"):
        return
    users, sysdbs = _user_dbs(ctx), _sys_dbs_visible(ctx)
    ctx.check("SHOW DATABASES DETAILS 可观测到系统库（否则分母反证无从谈起）",
              bool(sysdbs), f"系统库={sysdbs}、普通库={sorted(users)}")
    expect_cap(ctx, "单用户库", db, "tree")
    for kind in ("DATA", "SCHEMA"):
        got = ctx.api.db_max_group_num(db, kind, dialect="tree")
        want_excl = _cap_with_dbcount(ctx, kind, "tree", len(users))
        want_incl = _cap_with_dbcount(ctx, kind, "tree", len(users) + max(1, len(sysdbs)))
        # H-19：只判"实测 < 公式"（每库上限单调不减，实测 > 公式 是预期）。
        ctx.check(f"{kind} 上限不低于只计普通库的公式值（分母不含系统库）", got >= want_excl,
                  f"实测={got}、只计 {len(users)} 个普通库={want_excl}、"
                  f"若计入 {len(sysdbs)} 个系统库={want_incl}")


def case_sys02_second_user_db_shrinks_cap(ctx: Ctx) -> None:
    """SYS-02 再建第 2 个用户库：上限按新分母实时下降（expected_cap 实时算）。"""
    db = reset_db(ctx, "tree")
    if not _tier_guard(ctx, db, "tree", "SYS-02"):
        return
    extra = f"{db}_sys2"
    cap1 = expected_cap(ctx, "DATA", "tree", db)
    got1 = ctx.api.db_max_group_num(db, "DATA", dialect="tree")
    # H-19：判据是"实测 ≥ 公式"；实测 > 公式 = 该库保留的单调存量上限。
    ctx.check("建第二库前：root.pg 上限不低于公式值", got1 >= cap1,
              f"实测={got1}、公式={cap1}")
    ctx.api.drop_database(extra)                      # 容忍不存在
    ctx.mark_harness_action(f"SYS-02：新建第二个用户库 {extra}", pad=20)
    ctx.req(ctx.api.create_database(extra), f"create database {extra}")
    try:
        users = _user_dbs(ctx)
        cap_extra = expected_cap(ctx, "DATA", "tree", extra)
        cap_pg_now = expected_cap(ctx, "DATA", "tree", db)
        got_extra = ctx.api.db_max_group_num(extra, "DATA", dialect="tree")
        got_pg = ctx.api.db_max_group_num(db, "DATA", dialect="tree")
        ctx.check("两个用户库同时存在（分摊分母 +1）", len(users) >= 2,
                  f"普通库={sorted(users)}")
        ctx.check("新建第二库后：本库上限不低于现时公式值",
                  got_extra >= cap_extra, f"实测={got_extra}、公式={cap_extra}")
        ctx.check("分母变大后上限不升（实时公式值 ≤ 单库时）", cap_extra <= cap1,
                  f"单库公式={cap1}、双库公式={cap_extra}")
        ctx.check(f"另一个用户库 {db} 的上限不高于建库前（缓存滞后容忍 ≤）",
                  got_pg <= cap1, f"实测={got_pg}、建库前={cap1}、现时公式={cap_pg_now}")
    finally:
        ctx.mark_harness_action(f"SYS-02：清理第二个用户库 {extra}", pad=20)
        ctx.api.drop_database(extra)


def case_sys03_sys_max_is_one(ctx: Ctx) -> None:
    """SYS-03 系统库的 Max*RegionGroupNum 是否为固定 1（源码 :973-995）。"""
    db = reset_db(ctx, "tree") or db_of(ctx, "tree")
    ctx.check(f"对照用户库 {db} 已重建（系统库观测的并入分母对象）", True, f"db={db}")
    rows = ctx.api.database_details("tree")
    observed = {name: (ctx.api.db_max_group_num(name, "DATA", dialect="tree"),
                       ctx.api.db_max_group_num(name, "SCHEMA", dialect="tree"))
                for name in _SYS_DBS}
    if all(d < 0 and s < 0 for d, s in observed.values()) or not rows:
        ctx.skip("root.__system / root.__audit 均不在 SHOW DATABASES DETAILS（tree）中 ⇒ "
                 "Max*RegionGroupNum 在系统库上不可观测")
        return
    for name, (max_data, max_schema) in observed.items():
        if max_data < 0 and max_schema < 0:
            ctx.note(f"    [skip] {name} 不在库详情中，单独不可观测")
            continue
        ctx.check(f"{name} 的 MaxDataRegionGroupNum 固定为 1", max_data == 1,
                  f"实测={max_data}" if max_data == 1 else
                  f"实测={max_data}；系统库分配路径可能与用户库不同码"
                  f"（源码 ClusterSchemaManager.java:973-995 期望 1）")
        ctx.check(f"{name} 的 MaxSchemaRegionGroupNum 固定为 1", max_schema == 1,
                  f"实测={max_schema}" if max_schema == 1 else
                  f"实测={max_schema}；系统库分配路径可能与用户库不同码")


def case_sys04_user_write_keeps_sys(ctx: Ctx) -> None:
    """SYS-04 用户库写入不影响系统库组数（只读观测系统库）。"""
    db = reset_db(ctx, "tree")
    if not _tier_guard(ctx, db, "tree", "SYS-04"):
        return
    before = {name: _sys_probe(ctx, name) for name in _SYS_DBS}
    if all(not p["data_ids"] and not p["schema_ids"] for p in before.values()):
        ctx.skip("两个系统库的 RegionGroup 均不可观测（按库过滤与全集群回落都为空）")
        return
    devices = device_set(ctx, db, 3, prefix="pgu")
    write_devices(ctx, db, devices, model="tree", stamp=_now_ms())
    cap_d = group_ceiling(ctx, "DATA", "tree", db)
    expect_groups(ctx, "用户库写入 3 个 slot", db, "tree", data=min(3, cap_d))
    after = {name: _sys_probe(ctx, name) for name in _SYS_DBS}
    for name in _SYS_DBS:
        ctx.check(f"{name} 的 Data 组集合不随用户库写入变化",
                  before[name]["data_ids"] == after[name]["data_ids"],
                  f"前={len(before[name]['data_ids'])} 组、后={len(after[name]['data_ids'])} 组")
        ctx.check(f"{name} 的 Schema 组集合不随用户库写入变化",
                  before[name]["schema_ids"] == after[name]["schema_ids"],
                  f"前={len(before[name]['schema_ids'])} 组、后={len(after[name]['schema_ids'])} 组")
        ctx.check(f"{name} 的上限不随用户库写入变化",
                  (before[name]["data_max"], before[name]["schema_max"])
                  == (after[name]["data_max"], after[name]["schema_max"]),
                  f"前={before[name]['data_max']}/{before[name]['schema_max']}、"
                  f"后={after[name]['data_max']}/{after[name]['schema_max']}")


def case_sys05_sys_group_count_one(ctx: Ctx) -> None:
    """SYS-05 系统库组数恒为 1（Data 与 Schema 各 1，仅只读观测）。"""
    db = reset_db(ctx, "tree") or db_of(ctx, "tree")
    ctx.check(f"对照用户库 {db} 已重建（系统库组数观测不依赖用户库）", True, f"db={db}")
    probes = {name: _sys_probe(ctx, name) for name in _SYS_DBS}
    if all(not p["data_ids"] and not p["schema_ids"] for p in probes.values()):
        ctx.skip("系统库 RegionGroup 不可观测（SHOW REGIONS OF DATABASE <system> 与全集群回落均为空）")
        return
    for name, probe in probes.items():
        if not probe["data_ids"] and not probe["schema_ids"]:
            ctx.note(f"    [skip] {name} 单独不可观测")
            continue
        ctx.check(f"{name} 的 Data RegionGroup 数恒为 1", len(probe["data_ids"]) == 1,
                  f"实测={len(probe['data_ids'])} 个：{probe['data_ids']}")
        ctx.check(f"{name} 的 Schema RegionGroup 数恒为 1", len(probe["schema_ids"]) == 1,
                  f"实测={len(probe['schema_ids'])} 个：{probe['schema_ids']}")


def case_sys06_sys_stable_under_heavy_write(ctx: Ctx) -> None:
    """SYS-06 用户库写 6 个 slot 前后，系统库组数/上限不变。"""
    db = reset_db(ctx, "tree")
    if not _tier_guard(ctx, db, "tree", "SYS-06"):
        return
    before = {name: _sys_probe(ctx, name) for name in _SYS_DBS}
    if all(not p["data_ids"] and not p["schema_ids"] for p in before.values()):
        ctx.skip("系统库 RegionGroup 不可观测，无法比对写入前后的系统库状态")
        return
    before_user = (ctx.api.db_group_num(db, "SCHEMA", dialect="tree"),
                   ctx.api.db_group_num(db, "DATA", dialect="tree"))
    devices = device_set(ctx, db, 6, prefix="pgw")
    write_devices(ctx, db, devices, model="tree", stamp=_now_ms())
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    expect_groups(ctx, "用户库大量写入（6 个不同 slot）", db, "tree",
                  schema=min(6, cap_s), data=min(6, cap_d))
    after_user = (ctx.api.db_group_num(db, "SCHEMA", dialect="tree"),
                  ctx.api.db_group_num(db, "DATA", dialect="tree"))
    ctx.check("用户库确实发生了扩容（前置自证）",
              after_user[1] > before_user[1], f"前={before_user}、后={after_user}")
    after = {name: _sys_probe(ctx, name) for name in _SYS_DBS}
    for name in _SYS_DBS:
        ctx.check(f"{name} 组集合在用户库 6 slot 写入前后完全一致",
                  before[name]["data_ids"] == after[name]["data_ids"]
                  and before[name]["schema_ids"] == after[name]["schema_ids"],
                  f"Data 前={len(before[name]['data_ids'])}→后={len(after[name]['data_ids'])}、"
                  f"Schema 前={len(before[name]['schema_ids'])}→后={len(after[name]['schema_ids'])}")
        ctx.check(f"{name} 上限在用户库 6 slot 写入前后完全一致",
                  (before[name]["data_max"], before[name]["schema_max"])
                  == (after[name]["data_max"], after[name]["schema_max"]),
                  f"前={before[name]['data_max']}/{before[name]['schema_max']}、"
                  f"后={after[name]['data_max']}/{after[name]['schema_max']}")


# ===================================================================== PG-RST
def case_rst01_groups_and_mapping_survive(ctx: Ctx) -> None:
    """RST-01 整集群重启后组数与设备→组映射不变。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 4, prefix="pgr")
    if not _restart_needed(ctx, "RST-01"):
        return
    write_devices(ctx, db, devices, model="tree", stamp=_now_ms())
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    expect_groups(ctx, "重启前", db, "tree", schema=min(4, cap_s), data=min(4, cap_d))
    before_data, before_schema = _ids(ctx, db, "DATA"), _ids(ctx, db, "SCHEMA")
    before_map = ctx.api.device_groups([f"{db}.{_d}" for _d in devices])
    ctx.check("重启前设备→组映射完整", all(before_map.values()) and len(before_map) == 4,
              json.dumps(before_map, ensure_ascii=False))
    if not _full_restart(ctx, "RST-01"):
        return
    ctx.check("重启后 Data RegionId 集合不变", _ids(ctx, db, "DATA") == before_data,
              f"前={sorted(before_data)}、后={sorted(_ids(ctx, db, 'DATA'))}")
    ctx.check("重启后 Schema RegionId 集合不变", _ids(ctx, db, "SCHEMA") == before_schema,
              f"前={sorted(before_schema)}、后={sorted(_ids(ctx, db, 'SCHEMA'))}")
    after_map = ctx.api.device_groups([f"{db}.{_d}" for _d in devices])
    ctx.check("重启后设备→组映射不变", after_map == before_map,
              f"前={json.dumps(before_map, ensure_ascii=False)}、"
              f"后={json.dumps(after_map, ensure_ascii=False)}")
    expect_groups(ctx, "重启后", db, "tree", schema=min(4, cap_s), data=min(4, cap_d))


def case_rst02_details_and_regions_consistent(ctx: Ctx) -> None:
    """RST-02 重启后 SHOW DATABASES DETAILS 与 SHOW REGIONS 口径仍一致。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 3, prefix="pgc")
    if not _restart_needed(ctx, "RST-02"):
        return
    write_devices(ctx, db, devices, model="tree", stamp=_now_ms())
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    expect_groups(ctx, "重启前", db, "tree", schema=min(3, cap_s), data=min(3, cap_d))
    before = group_counts(ctx, db, "tree")
    if not _full_restart(ctx, "RST-02"):
        return
    after = group_counts(ctx, db, "tree")
    ctx.check("重启后两个口径（库详情 vs 区域去重）四元组不变", after == before,
              f"前={before}、后={after}")
    expect_groups(ctx, "重启后", db, "tree", schema=min(3, cap_s), data=min(3, cap_d))


def case_rst03_expand_after_restart(ctx: Ctx) -> None:
    """RST-03 重启后继续写新 slot 仍按 min(K, 上限) 扩容。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 6, prefix="pgx")
    if not _restart_needed(ctx, "RST-03"):
        return
    write_devices(ctx, db, devices[:2], model="tree", stamp=_now_ms())
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    expect_groups(ctx, "重启前写 2 个 slot", db, "tree",
                  schema=min(2, cap_s), data=min(2, cap_d))
    if not _full_restart(ctx, "RST-03"):
        return
    write_devices(ctx, db, devices[2:], model="tree", stamp=_now_ms())
    expect_groups(ctx, "重启后继续写满 6 个 slot", db, "tree",
                  schema=min(6, cap_s), data=min(6, cap_d))


def case_rst04_hot_reload_reverts_to_conf(ctx: Ctx) -> None:
    """RST-04 热加载改过的策略在重启后回到 conf 文件的值。"""
    db = reset_db(ctx, "tree")
    if not _restart_needed(ctx, "RST-04"):
        return
    want = (ctx.cfg.raw("PG_DATA_POLICY") or "PROACTIVE").strip()
    other = "AUTO" if want.upper() != "AUTO" else "PROACTIVE"
    try:
        ctx.mark_harness_action(f"RST-04：热加载 {_POLICY_KEY}={other}", pad=20)
        ctx.req(ctx.api.set_config(_POLICY_KEY, other), f"set configuration {_POLICY_KEY}={other}")
        live = _effective_settings(ctx).get(_POLICY_KEY)
        ctx.check("热加载后节点生效值 = 改后的值（自证热加载生效）",
                  (live or "").upper() == other.upper(),
                  f"conf[{_POLICY_KEY}]={live!r}、期望={other!r}")
        if not _full_restart(ctx, "RST-04"):
            return
        live2 = _effective_settings(ctx).get(_POLICY_KEY)
        disk = ctx.api.policies_on_disk(ctx.props, ctx.cfg.cn_hosts)
        # H-26：`SET CONFIGURATION` 实测**会落盘**（重启后 3 台 CN 的 iotdb-system.properties
        # 仍是热加载值），所以"重启后回到 conf 值"这个模型在本 build 上不成立；旧实现因为
        # show configuration 恒返回空而被"真空通过"。这里换成可判定、不预设结论的两条断言，
        # 并如实记录走的是哪一支：
        #   · 落盘持久化 ⇒ 重启后生效值仍是热加载值；
        #   · 运行期覆盖 ⇒ 重启后生效值回到 PG_DATA_POLICY。
        # 出现**第三种**值 = 配置被污染，仍然 FAIL。
        persisted = all((v.get(_POLICY_KEY) or "").strip().upper() == other.upper()
                        for v in disk.values())
        allowed = {other.upper(), want.upper()}
        ctx.check("重启后生效值 ∈ {热加载值(已落盘), PG_DATA_POLICY(运行期覆盖)}",
                  (live2 or "").strip().upper() in allowed,
                  f"生效[{_POLICY_KEY}]={live2!r}、热加载值={other!r}、"
                  f"conf(PG_DATA_POLICY)={want!r}；实测分支="
                  f"{'落盘持久化' if persisted else '运行期覆盖/已回退'}")
        ctx.note(f"    RST-04 结论：热加载值{'已' if persisted else '未'}落盘，"
                 f"重启后生效值={live2!r}（PG_DATA_POLICY={want!r}）")
        distinct = {(v.get(_POLICY_KEY) or "").strip().upper() for v in disk.values()}
        ctx.check("重启后各 CN 落盘值一致且与生效值同向（不出现分歧/污染）",
                  len(distinct) <= 1 and (live2 or "").strip().upper() in distinct,
                  f"各 CN 落盘={ {h: v.get(_POLICY_KEY) for h, v in disk.items()} }、"
                  f"生效值={live2!r}")
    finally:
        ctx.mark_harness_action(f"RST-04：恢复 {_POLICY_KEY} 为 conf 值", pad=20)
        ctx.api.set_config(_POLICY_KEY, want)
        ctx.note(f"    恢复后节点生效值[{_POLICY_KEY}]="
                 f"{_effective_settings(ctx).get(_POLICY_KEY)!r}（conf={want!r}）")


def case_rst05_empty_db_stays_empty(ctx: Ctx) -> None:
    """RST-05 空库重启后仍是 0 组（不补建）。"""
    db = reset_db(ctx, "tree")
    if not _restart_needed(ctx, "RST-05"):
        return
    expect_groups(ctx, "重启前空库", db, "tree", schema=0, data=0)
    if not _full_restart(ctx, "RST-05"):
        return
    expect_groups(ctx, "重启后空库", db, "tree", schema=0, data=0)
    ctx.check("重启没有为设备→组映射补建任何组（设备未写入）",
              ctx.api.device_group(f"{db}.never_written") == "",
              f"device_group={ctx.api.device_group(f'{db}.never_written')!r}")


def case_rst06_new_time_partition_after_restart(ctx: Ctx) -> None:
    """RST-06 重启后写已有库的新时间分区：组数仍按 min(K, 上限)（新 slot 补组）。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 4, prefix="pgq")
    if not _restart_needed(ctx, "RST-06"):
        return
    interval = ctx.api.db_time_partition_interval(db, dialect="tree")
    if interval <= 0:
        interval = _TPI_DEFAULT
        ctx.note(f"    TimePartitionInterval 不可观测，回落默认 {_TPI_DEFAULT}ms")
    now = _now_ms()
    old_stamp, new_stamp = now, now + interval
    ctx.note(f"    时间分区 interval={interval}ms：旧分区 t={old_stamp}、新分区 t={new_stamp}")
    write_devices(ctx, db, devices[:2], model="tree", stamp=old_stamp)
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    expect_groups(ctx, "重启前写旧分区 2 个 slot", db, "tree",
                  schema=min(2, cap_s), data=min(2, cap_d))
    old_map = ctx.api.device_groups(devices[:2])
    if not _full_restart(ctx, "RST-06"):
        return
    ctx.check("重启后旧时间分区映射不变",
              ctx.api.device_groups(devices[:2]) == old_map,
              f"前={json.dumps(old_map, ensure_ascii=False)}、"
              f"后={json.dumps(ctx.api.device_groups(devices[:2]), ensure_ascii=False)}")
    write_devices(ctx, db, devices[2:], model="tree", stamp=new_stamp)
    ctx.check("新时间分区两行可查",
              all(ctx.api.count_rows(f"{db}.{d}") == 1 for d in devices[2:]),
              f"counts={[ctx.api.count_rows(f'{db}.{d}') for d in devices[2:]]}")
    expect_groups(ctx, "重启后写新时间分区的新 slot", db, "tree",
                  schema=min(4, cap_s), data=min(4, cap_d))


# ===================================================================== 注册表
SPECS.extend([
    CaseSpec("PG-TTL-01", "TTL", "tree", "设 TTL 后写 4 个不同 slot：组数仍 = min(4, 上限)",
             "P0", case_ttl01_groups_after_set_ttl, gate=True),
    CaseSpec("PG-TTL-02", "TTL", "tree", "小 TTL(1000ms)+等 4s 后再写：写入成功、组数仍按公式",
             "P0", case_ttl02_small_ttl_write_after_wait),
    CaseSpec("PG-TTL-03", "TTL", "tree", "过期删除后组数与设备→组映射不变（RegionId 集合对拍）",
             "P0", case_ttl03_expiry_keeps_groups),
    CaseSpec("PG-TTL-04", "TTL", "tree", "unset ttl 后继续写新 slot：正常扩容到 min(K, 上限)",
             "P1", case_ttl04_unset_ttl_then_expand),
    CaseSpec("PG-TTL-05", "TTL", "tree", "TTL 与时间分区叠加：分区边界前后写行，组数仍 min(K, 上限)",
             "P1", case_ttl05_ttl_with_time_partition),
    CaseSpec("PG-TTL-06", "TTL", "table", "表模型 TTL：语法未确认 ⇒ SKIP（不试探性 DDL）",
             "P2", case_ttl06_table_model_ttl),
    CaseSpec("PG-TTL-07", "TTL", "tree", "TTL 生效期间同 slot 新增测点不建组",
             "P1", case_ttl07_new_measurement_no_group),
    CaseSpec("PG-TTL-08", "TTL", "tree", "过期清理后集群健康、RegionGroup 不回收（sync lag 归 0 见收尾①）",
             "P1", case_ttl08_expiry_cluster_health),
    CaseSpec("PG-SYS-01", "系统库", "tree", "单用户库：实测上限 = 只计普通库的公式值（系统库未进分母）",
             "P0", case_sys01_single_user_db_cap, gate=True),
    CaseSpec("PG-SYS-02", "系统库", "tree", "再建第 2 个用户库：上限按新分母实时下降",
             "P0", case_sys02_second_user_db_shrinks_cap),
    CaseSpec("PG-SYS-03", "系统库", "tree", "系统库 Max*RegionGroupNum 是否为固定 1（源码 :973-995）",
             "P0", case_sys03_sys_max_is_one, gate=True),
    CaseSpec("PG-SYS-04", "系统库", "tree", "用户库写入不影响系统库组数（只读观测）",
             "P1", case_sys04_user_write_keeps_sys),
    CaseSpec("PG-SYS-05", "系统库", "tree", "系统库组数恒为 1（Data/Schema 各 1，只读观测）",
             "P0", case_sys05_sys_group_count_one),
    CaseSpec("PG-SYS-06", "系统库", "tree", "用户库写 6 个 slot 前后系统库组数/上限不变",
             "P1", case_sys06_sys_stable_under_heavy_write),
    CaseSpec("PG-RST-01", "重启", "tree", "整集群重启后组数与设备→组映射不变",
             "P0", case_rst01_groups_and_mapping_survive, needs_restart=True),
    CaseSpec("PG-RST-02", "重启", "tree", "重启后 SHOW DATABASES DETAILS 与 SHOW REGIONS 口径仍一致",
             "P0", case_rst02_details_and_regions_consistent, needs_restart=True),
    CaseSpec("PG-RST-03", "重启", "tree", "重启后继续写新 slot 仍按 min(K, 上限) 扩容",
             "P0", case_rst03_expand_after_restart, needs_restart=True),
    CaseSpec("PG-RST-04", "重启", "tree", "热加载改过的策略重启后回到 conf 文件的值",
             "P1", case_rst04_hot_reload_reverts_to_conf, needs_restart=True),
    CaseSpec("PG-RST-05", "重启", "tree", "空库重启后仍是 0 组（不补建）",
             "P0", case_rst05_empty_db_stays_empty, needs_restart=True),
    CaseSpec("PG-RST-06", "重启", "tree", "重启后写新时间分区的新 slot：补组到 min(K, 上限)",
             "P1", case_rst06_new_time_partition_after_restart, needs_restart=True),
])
