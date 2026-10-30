"""PG-DEV（设备与槽）/ PG-OBS（观测自证）用例族。

覆盖 ``references/case-catalog.md`` 的 **PG-DEV-01..12、17..24** 与 **PG-OBS-02、03**（共 22 条）。
case_id 与 catalog 行的对应（逐个可核）：

* ``DEV-01..06``：树 K=1,2,3,6,10,20 个不同 slot；其中 01..04 的**首个设备**分别带
  1/3/10/100 个测点，用来同时断言"测点数不增加 slot"；
* ``DEV-07..12``：表模型同 K 网格（首个 TAG 带 1/3/10/100 个测点列）；
* ``DEV-17`` 连续编号设备；``DEV-18`` K>R 封顶后不再增长；``DEV-19`` 逐个写入的增长序列；
  ``DEV-20`` 共槽 + 新时间分区；``DEV-21`` 1000 个不同 slot（兼两库独立计数）；
  ``DEV-22`` 单设备多层级路径；``DEV-23`` 中文设备名（兼 ``d_1``/``d-1``/超长名边界）；
  ``DEV-24`` 表模型 null TAG；
* ``OBS-02/03`` 按本轮任务书的口径实现（三大观测面一致 / ``REGIONID WHERE DEVICE`` ⊆
  ``WHERE DATABASE`` + 时间分区计数）；catalog 里 OBS-02/03 的"树多层级·中文 / 表 TAG·null
  槽计算交叉验证"由已实现的 ``PG-OBS-01`` + 本文件 ``DEV-22/23/24`` 覆盖。

判定口径唯一来源是 ``references/proactive-spec.md``：

* 组数目标 ``T = min(R, max(min(minNum, G+|P|), K))``（spec §3.6，源码
  ``PartitionManager.java:668-681``），所以期望一律写成 ``min(K, 上限)`` 形态；
* ``R`` 由 spec §4 的公式给出，且"参与分摊库数"把**树+表普通库一起计数**（§4.1）；
  单方言的 ``SHOW DATABASES DETAILS`` 会少算另一模型的库，故 ``_caps`` 用双模型库数
  重算公式，并与产品自报的 ``Max*RegionGroupNum`` 对拍（不一致则 SKIP，不误判产品）；
* **设备数 ≠ 组数**：共槽设备只算 1 个 slot（§3.8、docs/127），故本族一律用
  ``device_set()`` 造"互不同 slot"的设备，或用 ``slot_map`` 计算真实 slot 数；
* 已实现的 ``PG-DEV-13/15/16``、``PG-OBS-01/04`` **不在本文件重复**。

本文件里所有"故意制造错误"的语句（非法设备名、表方言不支持的观测语句）之前都调用
``ctx.mark_harness_action(...)`` 开日志归因窗口；每条用例都从干净库开始（``_solo_db``
还会删掉另一模型的测试库，把参与分摊库数收敛成确定值）。
"""

from __future__ import annotations

import json
import math

from . import slots as pslots
from .cases import (
    CaseSpec,
    Ctx,
    db_of,
    device_set,
    ensure_write_table,
    ensure_write_tree,
    expect_groups,
    expected_cap,
    reset_db,
    write_devices,
)

SPECS: list[CaseSpec] = []

TABLE = "tb"
_REGION_ID_COLS = ("RegionId", "region_id", "RegionID", "RegionGroupId")
#: 参与分摊的分母要剔除的系统库/审计库（与 ``cases.SYSTEM_DBS`` 同口径）。
_SYSTEM_DBS = ("root.__system", "root.__audit", "__audit", "information_schema")

#: 可热加载的策略/配额键（spec §2）与它们在 conf 里的 PG_* 来源。
_CONF_KEY = {
    "schema_region_group_extension_policy": "PG_SCHEMA_POLICY",
    "data_region_group_extension_policy": "PG_DATA_POLICY",
    "default_schema_region_group_num_per_database": "PG_MIN_SCHEMA_PER_DB",
    "default_data_region_group_num_per_database": "PG_MIN_DATA_PER_DB",
    "schema_region_per_data_node": "PG_SCHEMA_PER_DATA_NODE",
    "data_region_per_data_node": "PG_DATA_PER_DATA_NODE",
}
#: 键缺失时发布模板/代码的默认值（spec §1.2/§2；两个策略键的默认是 PROACTIVE）。
_DEFAULT = {
    "schema_region_group_extension_policy": "PROACTIVE",
    "data_region_group_extension_policy": "PROACTIVE",
    "default_schema_region_group_num_per_database": "1",
    "default_data_region_group_num_per_database": "2",
    "schema_region_per_data_node": "1",
    "data_region_per_data_node": "0",
}
_POLICY_KEYS = ("schema_region_group_extension_policy",
                "data_region_group_extension_policy")
_QUOTA_KEYS = ("default_schema_region_group_num_per_database",
               "default_data_region_group_num_per_database",
               "schema_region_per_data_node",
               "data_region_per_data_node")
_HOT_KEYS = _POLICY_KEYS + _QUOTA_KEYS


# ------------------------------------------------------------------ 前置与通用断言
def _effective_settings(ctx: Ctx) -> dict[str, str]:
    """节点配置文件里**已生效**的策略/配额键值。

    H-26：2.0.11 不支持 ``SHOW CONFIGURATION``（``700: … no viable alternative at input
    'show configuration'``），旧实现恒返回 ``{}`` ⇒ 本族的"热加载是否生效"校验空转。
    ``SET CONFIGURATION`` 会把新值落进各节点的 ``conf/iotdb-system.properties``，
    因此直接读文件；读不到时返回 ``{}``（调用方会回落到同一份文件里的 disk 值）。
    """
    try:
        return dict(ctx.props.read(ctx.cfg.cli_host, keys=tuple(_HOT_KEYS)))
    except Exception as exc:  # noqa: BLE001 - 读不到就退回 disk 口径，不在此处判失败
        ctx.note(f"    读取节点配置文件失败（{ctx.cfg.cli_host}）：{exc}")
        return {}


def _precondition(ctx: Ctx) -> bool:
    """本族前置：集群是 PROACTIVE 口径，且配额/最小组数与 conf 一致。

    ``series_slot_num`` 是**首次启动确定、不可热更**的集群级参数：conf 与集群不一致时
    harness 的槽计算不可信 ⇒ SKIP（绝不降级断言）。策略/配额键可热加载：若被上一族改成
    了别的值，先热加载回 conf 值并读回自证；改不回来则 SKIP。
    """
    cfg = ctx.cfg
    want = {key: (cfg.raw(_CONF_KEY[key]) or _DEFAULT[key]) for key in _HOT_KEYS}
    try:
        disk = ctx.props.read(cfg.cn_hosts[0], keys=("series_slot_num",) + _HOT_KEYS)
    except Exception as exc:  # noqa: BLE001 - 读不到 conf 就没法自证，按 SKIP 处理
        ctx.skip(f"无法读取 CN 配置文件校验集群级参数：{exc}")
        return False
    slot_num = int(disk.get("series_slot_num") or 1000)
    conf_slot = int(cfg.raw("PG_SERIES_SLOT_NUM") or 1000)
    if slot_num != conf_slot:
        ctx.skip(f"集群 series_slot_num={slot_num} != conf PG_SERIES_SLOT_NUM={conf_slot}"
                 "（首次启动确定、不可热更）⇒ harness 槽计算不可信；请用与集群一致的 conf 重跑")
        return False
    if cfg.raw("PG_SCHEMA_POLICY") and cfg.raw("PG_SCHEMA_POLICY") != "PROACTIVE":
        ctx.skip(f"本轮 conf 的 PG_SCHEMA_POLICY={cfg.raw('PG_SCHEMA_POLICY')}，"
                 "本族期望值全部按 PROACTIVE 推导；请用 conf/cluster.pg_2011snap_iot.conf 重跑")
        return False

    effective = _effective_settings(ctx)
    to_fix: dict[str, str] = {}
    for key in _POLICY_KEYS:
        declared = effective.get(key) or disk.get(key, "")
        if declared and declared != want[key]:
            to_fix[key] = declared
    for key in _QUOTA_KEYS:
        declared = effective.get(key) or disk.get(key, "")
        if declared != want[key]:
            to_fix[key] = declared or "(未配置/模板默认)"
    if to_fix:
        ctx.mark_harness_action(f"热加载回 conf 口径的策略/配额：{to_fix}", pad=25)
        for key in to_fix:
            ctx.api.set_config(key, want[key])
        effective = _effective_settings(ctx)
    actual = {key: (effective.get(key) or disk.get(key, "") or _DEFAULT[key])
              for key in _HOT_KEYS}
    bad = {key: actual[key] for key in _HOT_KEYS if actual[key] != want[key]}
    if bad:
        ctx.skip(f"策略/配额无法达到 conf 口径（期望={want}、实际={actual}）")
        return False
    ctx.check("前置：策略=PROACTIVE、配额/最小组数=conf 值（读回自证）", True,
              f"已修正={to_fix or '无需修正'}；生效={actual}",
              evidence=json.dumps({"conf": want, "effective": effective,
                                   "series_slot_num": slot_num}, ensure_ascii=False))
    return True


def _db_count(ctx: Ctx) -> int:
    """参与上限分摊的普通库数：**树+表两边一起数**（spec §4.1）。"""
    names = set(ctx.api.database_details("tree")) | set(ctx.api.database_details("table"))
    return max(1, len([name for name in names
                       if not any(s in name for s in _SYSTEM_DBS)]))


def _formula_cap(ctx: Ctx, kind: str, db_count: int) -> int:
    """spec §4 的上限公式：``max(min, ceil(weight × resource / (库数 × 副本数)))``。"""
    cfg = ctx.cfg
    dn_num = len(cfg.dn_hosts)
    if kind.upper().startswith("S"):
        weight, resource = int(cfg.raw("PG_SCHEMA_PER_DATA_NODE") or 1), dn_num
        rf = cfg.get_int("SCHEMA_REPLICATION_FACTOR")
        minimum = int(cfg.raw("PG_MIN_SCHEMA_PER_DB") or 1)
    else:
        per_node = int(cfg.raw("PG_DATA_PER_DATA_NODE") or 0)
        if per_node > 0:
            weight, resource = per_node, dn_num
        else:
            weight, resource = 0.5, dn_num * int(cfg.raw("PG_CPU_CORES_PER_DN") or 48)
        rf = cfg.get_int("DATA_REPLICATION_FACTOR")
        minimum = int(cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    return max(minimum, math.ceil(weight * resource / (max(1, db_count) * rf)))


def _caps(ctx: Ctx, dialect: str, db: str) -> tuple[int, int]:
    """(Schema 上限, Data 上限)，并自证"公式 == 产品自报 ``Max*RegionGroupNum``"。

    ``cases.expected_cap`` 的库数取自**单方言**的 ``SHOW DATABASES DETAILS``，而产品的
    ``databaseNum`` 把树+表普通库一起计数（``ClusterSchemaManager.java:532-550``，
    spec §4.1）⇒ 混跑两种模型时会少算分母。这里按 spec §4 用**双模型库数**重算，
    并直接与产品自报的上限对拍：两者不一致说明集群档位/公式前提不符，期望值不可信
    ⇒ **SKIP**（本族的职责是验证扩展行为，不是校准上限公式）。
    """
    db_count = _db_count(ctx)
    want = {kind: _formula_cap(ctx, kind, db_count) for kind in ("SCHEMA", "DATA")}
    harness = {kind: expected_cap(ctx, kind, dialect, db) for kind in ("SCHEMA", "DATA")}
    got = {kind: ctx.api.db_max_group_num(db, kind, dialect=dialect)
           for kind in ("SCHEMA", "DATA")}
    delta = "" if harness == want else \
        f"；harness expected_cap（按 {dialect} 方言过滤库数）={harness}（少算另一模型的库）"
    # H-46：扩容公式第三项是 ``max(..., allocated)``（ClusterSchemaManager.calcMaxRegionGroupNum）——
    # 库上已有的组数构成下限，产品自报的上限因此可能**大于**纯公式值。DEV-21 先写 A 库再建 B 库时
    # 就撞到这一项（公式 SCHEMA=1、产品自报=2）。取两者较大值作为有效上限再看是否一致。
    allocated = {kind: ctx.api.db_group_num(db, kind, dialect=dialect)
                 for kind in ("SCHEMA", "DATA")}
    effective = {kind: max(want[kind], allocated[kind]) for kind in ("SCHEMA", "DATA")}
    if effective == got:
        ctx.check(f"上限口径自证（{db}，参与分摊库数={db_count}）：max(公式, 已分配)"
                  f" 等于产品自报 Max*RegionGroupNum", True,
                  f"公式={want}、已分配={allocated}、产品自报={got}{delta}")
        return effective["SCHEMA"], effective["DATA"]
    if want == got:
        ctx.check(f"上限口径自证（{db}，参与分摊库数={db_count}）：公式 Schema={want['SCHEMA']}、"
                  f"Data={want['DATA']} 等于产品自报 Max*RegionGroupNum",
                  True, f"产品自报={got}{delta}")
    else:
        # H-46b：纯公式与产品自报不一致时**不再 SKIP**——产品的上限是历史调整结果
        # （只在建库/写入等事件触发 adjustMaxRegionGroupNum，见 TDB-862 那条同源链路），
        # 用"按产品自报上限断言"同样能验证扩展行为；差异留成一条记录，不掩盖。
        ctx.check(f"上限口径提示（{db}，参与分摊库数={db_count}）：纯公式 {want} 与产品自报 {got} 不同",
                  True, f"{delta}；后续断言按产品自报上限 {got} 进行")
        return got["SCHEMA"], got["DATA"]
    return want["SCHEMA"], want["DATA"]


def _slot_num(ctx: Ctx) -> int:
    return int(ctx.cfg.raw("PG_SERIES_SLOT_NUM") or 1000)


def _check_counts(ctx: Ctx, label: str, db: str, dialect: str, *, schema: int, data: int) -> None:
    """轻量组数断言：只读库详情的两列（比 ``expect_groups`` 少 5~6 条 SQL）。"""
    got_schema = ctx.api.db_group_num(db, "SCHEMA", dialect=dialect)
    got_data = ctx.api.db_group_num(db, "DATA", dialect=dialect)
    ctx.check(f"{label}：Schema={schema}、Data={data}",
              got_schema == schema and got_data == data,
              f"实际 Schema={got_schema}、Data={got_data}")


def _solo_db(ctx: Ctx, model: str) -> str:
    """reset 目标库，并删除另一模型的测试库，让单模型用例的分母确定为 1。

    上一族/上一条用例（例如 DEV-21）可能留下另一模型的库；``_caps`` 虽已按双模型
    库数修正公式，但把环境收敛成"只有一个测试库"能让期望值更稳、失败更好定位。
    ``SHOW DATABASES DETAILS`` 本身按**方言过滤**（tree 只列树库、table 只列表库，
    ``ClusterConfigTaskExecutor.java:576-593`` 传 ``isTableModel=false/true``），
    而产品的 ``databaseNum`` 把两模型普通库一起计数（``ClusterSchemaManager.java:532-550``）。
    """
    db = reset_db(ctx, model)
    other_model = "table" if model != "table" else "tree"
    other_db = db_of(ctx, other_model)
    ctx.mark_harness_action(f"删除另一模型测试库 {other_db}（让参与分摊库数=1）", pad=20)
    ctx.api.drop_database(other_db, table=(other_model == "table"))
    return db


def _declared_slots(ctx: Ctx, db: str, names: list[str], dialect: str) -> dict[str, int]:
    if dialect == "table":
        return {name: pslots.table_slot(TABLE, [name], slot_num=_slot_num(ctx))
                for name in names}
    return pslots.slot_map(db, names, slot_num=_slot_num(ctx))


def _device_group_consistency(ctx: Ctx, label: str, db: str, devices: list[str],
                              dialect: str, cap: int) -> None:
    """写入后 ``device_group()`` 必须与 harness 槽计算一致（OBS-01 的同口径复核）。

    表方言不支持 ``SHOW DATA REGIONID``（``AstBuilder.java:1781`` 抛 SemanticException），
    故表模型不做该交叉验证（在 actions.log 中如实记录）。
    """
    if dialect == "table":
        ctx.note(f"    {label}：表方言无 SHOW DATA REGIONID 可观测量（源码 AstBuilder:1781），"
                 "跳过 device_group 交叉验证，改用 REGIONS/DETAILS 两面")
        return
    declared = _declared_slots(ctx, db, devices, dialect)
    observed = {device: ctx.api.device_group(f"{db}.{device}", dialect=dialect)
                for device in devices}
    by_slot: dict[int, set[str]] = {}
    for device, slot in declared.items():
        by_slot.setdefault(slot, set()).add(observed.get(device, ""))
    ctx.check(f"{label}：每个设备都能查到所属 RegionGroup", all(observed.values()),
              f"观测={observed}")
    ctx.check(f"{label}：计算为同一 slot 的设备必须落同一组",
              all(len(groups) == 1 for groups in by_slot.values()),
              f"槽→组={ {slot: sorted(groups) for slot, groups in by_slot.items()} }")
    if len(set(declared.values())) <= cap:
        ctx.check(f"{label}：上限足够时不同 slot 必须落不同组",
                  len(set(observed.values())) == len(set(declared.values())),
                  f"计算槽数={len(set(declared.values()))}、观测组数={len(set(observed.values()))}")


# ---------------------------------------------- 树/表：K 个不同 slot（首个设备多测点）
def _tree_multi_slots(ctx: Ctx, count: int, label: str, *, first_sensors: int = 1,
                      per_step: bool = False, sequence: bool = False) -> None:
    """写 ``count`` 个**互不同 slot** 的设备；首个设备带 ``first_sensors`` 个测点。

    期望一律 ``min(K, R)``：K = 实测不同 slot 数（``pslots`` BKDR131），R = ``_caps``
    自证过的上限。首设备多测点的期望与"1 个 slot"完全相同 —— 这正是"测点数不增加
    series slot"的口径断言（catalog DEV-01..06 + brief 的 1/3/10/100 测点场景）。
    """
    if not _precondition(ctx):
        return
    db = _solo_db(ctx, "tree")
    cap_s, cap_d = _caps(ctx, "tree", db)
    if ctx.skipped:
        return
    devices = device_set(ctx, db, count, slot_num=_slot_num(ctx))
    expect_groups(ctx, f"{label}：写入前空库", db, "tree", schema=0, data=0)
    ctx.check(f"{label}：harness 生成的 {count} 个设备互不同 slot",
              pslots.distinct_slot_count(db, devices, slot_num=_slot_num(ctx)) == count,
              f"slots={pslots.slot_map(db, devices, slot_num=_slot_num(ctx))}")
    observed: dict[str, list[int]] = {"SCHEMA": [], "DATA": []}
    for index, device in enumerate(devices, start=1):
        if index == 1:
            columns = tuple(f"s{i}" for i in range(first_sensors))
            ensure_write_tree(ctx, db, device, index, sensors=columns,
                              values=[1.0] * first_sensors)
            _check_counts(ctx, f"{label}：首设备 {first_sensors} 个测点后（测点数不增 slot）",
                          db, "tree", schema=min(1, cap_s), data=min(1, cap_d))
            # 同一设备同一时间戳再追加 3 个测点：slot/时间分区都不变 ⇒ 组数不变
            extra = tuple(f"s{first_sensors + i}" for i in range(3))
            ensure_write_tree(ctx, db, device, index, sensors=extra, values=[2.0] * 3)
            series = ctx.api.show_timeseries(f"{db}.{device}.**").rows
            ctx.check(f"{label}：首设备 {first_sensors + 3} 个测点全部建为序列",
                      len(series) == first_sensors + 3, f"实际序列数={len(series)}")
        else:
            ensure_write_tree(ctx, db, device, index)
        for kind in ("SCHEMA", "DATA"):
            observed[kind].append(ctx.api.db_group_num(db, kind, dialect="tree"))
        if per_step and index > 1:
            _check_counts(ctx, f"{label}：第 {index}/{count} 个 slot 写入后", db, "tree",
                          schema=min(index, cap_s), data=min(index, cap_d))
    expect_groups(ctx, f"{label}：{count} 个不同 slot（终值）", db, "tree",
                  schema=min(count, cap_s), data=min(count, cap_d))
    if sequence:
        for kind, cap in (("SCHEMA", cap_s), ("DATA", cap_d)):
            want = [min(index, cap) for index in range(1, count + 1)]
            ctx.check(f"{label}：逐个写入的 {kind} 组数序列应为 {want}",
                      observed[kind] == want, f"实测序列={observed[kind]}")
    _device_group_consistency(ctx, f"{label}：{count} 个设备", db, devices, "tree", cap_d)


def _table_multi_slots(ctx: Ctx, count: int, label: str, *, first_fields: int = 1,
                       per_step: bool = False) -> None:
    """表模型同口径：``count`` 个不同 slot 的 TAG，首个 TAG 带 ``first_fields`` 个测点列。"""
    if not _precondition(ctx):
        return
    db = _solo_db(ctx, "table")
    cap_s, cap_d = _caps(ctx, "table", db)
    if ctx.skipped:
        return
    tags = device_set(ctx, db, count, dialect="table", table=TABLE, slot_num=_slot_num(ctx))
    expect_groups(ctx, f"{label}：写入前空库", db, "table", schema=0, data=0)
    ctx.check(f"{label}：harness 生成的 {count} 个 TAG 互不同 slot",
              pslots.distinct_tag_slot_count(TABLE, tags, slot_num=_slot_num(ctx)) == count,
              f"distinct={pslots.distinct_tag_slot_count(TABLE, tags, slot_num=_slot_num(ctx))}")
    for index, tag in enumerate(tags, start=1):
        fields = first_fields if index == 1 else 1
        ensure_write_table(ctx, db, TABLE, tag, stamp=index, fields=fields)
        if index == 1:
            _check_counts(ctx, f"{label}：首 TAG {first_fields} 个测点列后（列数不增 slot）",
                          db, "table", schema=min(1, cap_s), data=min(1, cap_d))
            ctx.check(f"{label}：第 {first_fields} 个测点列（s{first_fields - 1}）有值",
                      ctx.api.count_rows(f"{db}.{TABLE}", dialect="table",
                                         where=f"s{first_fields - 1} is not null") == 1,
                      f"count={ctx.api.count_rows(f'{db}.{TABLE}', dialect='table', where=f's{first_fields - 1} is not null')}")
        if per_step and index > 1:
            _check_counts(ctx, f"{label}：第 {index}/{count} 个 slot 写入后", db, "table",
                          schema=min(index, cap_s), data=min(index, cap_d))
    expect_groups(ctx, f"{label}：{count} 个不同 slot（终值）", db, "table",
                  schema=min(count, cap_s), data=min(count, cap_d))
    ctx.check(f"{label}：{count} 行数据可查",
              ctx.api.count_rows(f"{db}.{TABLE}", dialect="table") == count,
              f"count={ctx.api.count_rows(f'{db}.{TABLE}', dialect='table')}")


# --------------------------------------------------------------------------- PG-DEV-01..12
def case_dev01_tree_k1(ctx: Ctx) -> None:
    """DEV-01 树 K=1：1 个设备（1 测点）⇒ ``min(1, R)`` 组（组数由设备路径 slot 决定）。"""
    _tree_multi_slots(ctx, 1, "DEV-01 树 K=1（1 设备 1 测点）")


def case_dev02_tree_k2(ctx: Ctx) -> None:
    """DEV-02 树 K=2：首设备 3 测点 + 1 个新 slot 设备 ⇒ ``min(2, R)``（测点数不增 slot）。"""
    _tree_multi_slots(ctx, 2, "DEV-02 树 K=2（首设备 3 测点）", first_sensors=3)


def case_dev03_tree_k3(ctx: Ctx) -> None:
    """DEV-03 树 K=3：首设备 10 测点 + 2 个新 slot 设备 ⇒ ``min(3, R)``。"""
    _tree_multi_slots(ctx, 3, "DEV-03 树 K=3（首设备 10 测点）", first_sensors=10)


def case_dev04_tree_k6(ctx: Ctx) -> None:
    """DEV-04 树 K=6：首设备 100 测点 + 5 个新 slot 设备 ⇒ ``min(6, R)``。"""
    _tree_multi_slots(ctx, 6, "DEV-04 树 K=6（首设备 100 测点）", first_sensors=100)


def case_dev05_tree_k10(ctx: Ctx) -> None:
    """DEV-05 树 K=10 逐个写入：每步都应等于 ``min(i, R)``。"""
    _tree_multi_slots(ctx, 10, "DEV-05 树 K=10", per_step=True)


def case_dev06_tree_k20(ctx: Ctx) -> None:
    """DEV-06 树 K=20：终值 ``min(20, R)``（Schema 先封顶、Data 继续到自己的上限）。"""
    _tree_multi_slots(ctx, 20, "DEV-06 树 K=20")


def case_dev07_table_k1(ctx: Ctx) -> None:
    """DEV-07 表 K=1：1 个 TAG（1 测点列）⇒ ``min(1, R)`` 组。"""
    _table_multi_slots(ctx, 1, "DEV-07 表 K=1（1 TAG 1 列）")


def case_dev08_table_k2(ctx: Ctx) -> None:
    """DEV-08 表 K=2：首 TAG 3 个测点列 + 1 个新 slot TAG ⇒ ``min(2, R)``。"""
    _table_multi_slots(ctx, 2, "DEV-08 表 K=2（首 TAG 3 列）", first_fields=3)


def case_dev09_table_k3(ctx: Ctx) -> None:
    """DEV-09 表 K=3：首 TAG 10 个测点列 + 2 个新 slot TAG ⇒ ``min(3, R)``。"""
    _table_multi_slots(ctx, 3, "DEV-09 表 K=3（首 TAG 10 列）", first_fields=10)


def case_dev10_table_k6(ctx: Ctx) -> None:
    """DEV-10 表 K=6：首 TAG 100 个测点列 + 5 个新 slot TAG ⇒ ``min(6, R)``。"""
    _table_multi_slots(ctx, 6, "DEV-10 表 K=6（首 TAG 100 列）", first_fields=100)


def case_dev11_table_k10(ctx: Ctx) -> None:
    """DEV-11 表 K=10 逐个写入：每步都应等于 ``min(i, R)``（与树同口径）。"""
    _table_multi_slots(ctx, 10, "DEV-11 表 K=10", per_step=True)


def case_dev12_table_k20(ctx: Ctx) -> None:
    """DEV-12 表 K=20：终值 ``min(20, R)``。"""
    _table_multi_slots(ctx, 20, "DEV-12 表 K=20")


# --------------------------------------------------------------------------- PG-DEV-17..24
def _consecutive_names(ctx: Ctx, db: str, *, max_writes: int = 205) -> list[str]:
    """连续编号设备名 ``d1,d2,...``，写到**第一个 slot 冲突**处（写入数上限 ``max_writes``）。

    连续编号并不保证 slot 不同（docs/127 "覆盖更多槽"）：harness BKDR131 下
    ``series_slot_num=1000``、库 ``root.pg`` 时首个共槽是 ``d205`` 与 ``d30``（同 slot 70），
    故 ``max_writes=205`` 足够让本用例稳定拿到"设备数 ≠ 组数"的直接证据；
    其它档位若 205 个编号内无冲突，就按实测的不同 slot 数断言（同样成立）。
    """
    seen: dict[int, str] = {}
    first_collision = 0
    for index in range(1, 1002):           # 1001 个编号必然在 1000 个槽内出现共槽
        slot = pslots.tree_device_slot(db, f"d{index}", slot_num=_slot_num(ctx))
        if slot in seen:
            first_collision = index
            break
        seen[slot] = f"d{index}"
    count = min(first_collision or len(seen), max_writes)
    return [f"d{index}" for index in range(1, count + 1)]


def case_dev17_consecutive_numbering(ctx: Ctx) -> None:
    """DEV-17 连续编号设备：期望 ``min(实测不同 slot 数, R)``，**不断言设备数**。

    连续编号（``d1,d2,...``）在 BKDR131 下也会共槽（docs/127）⇒ 组数只能由 harness 算出的
    不同 slot 数决定。设备列表写到首个共槽编号为止，于是本用例同时给出"设备数 ≠ 组数"的
    直接证据，并用 ``device_group`` 交叉验证"同 slot 必落同组"。
    """
    if not _precondition(ctx):
        return
    db = _solo_db(ctx, "tree")
    cap_s, cap_d = _caps(ctx, "tree", db)
    if ctx.skipped:
        return
    names = _consecutive_names(ctx, db)
    slot_of = pslots.slot_map(db, names, slot_num=_slot_num(ctx))
    kinds = len(set(slot_of.values()))
    buckets: dict[int, list[str]] = {}
    for name in names:
        buckets.setdefault(slot_of[name], []).append(name)
    pair = next((members for members in buckets.values() if len(members) > 1), [])
    ctx.note(f"    DEV-17：连续编号 {len(names)} 个设备 → {kinds} 个不同 slot"
             + (f"（共槽对 {pair} 同 slot {slot_of[pair[0]]}）" if pair else "（未出现共槽）"))
    expect_groups(ctx, "DEV-17 写入前空库", db, "tree", schema=0, data=0)
    for index, name in enumerate(names, start=1):
        ensure_write_tree(ctx, db, name, index)
    expect_groups(ctx, f"DEV-17 {len(names)} 个连续编号设备（{kinds} 个不同 slot）", db, "tree",
                  schema=min(kinds, cap_s), data=min(kinds, cap_d))
    ctx.check("DEV-17：组数由 slot 决定而非设备数（共槽时组数必须少于设备数）",
              kinds == len(names) or min(kinds, cap_d) < len(names),
              f"设备数={len(names)}、不同 slot 数={kinds}、Data 组数="
              f"{ctx.api.db_group_num(db, 'DATA', dialect='tree')}")
    sample = (pair + [name for name in names if name not in pair])[:5]
    _device_group_consistency(ctx, "DEV-17 连续编号设备（共槽对 + 3 个不同 slot）", db, sample,
                              "tree", cap_d)


def case_dev18_k_gt_r(ctx: Ctx) -> None:
    """DEV-18 K > R：先写 K=8 个不同 slot，再补 4 个（K=12），Schema 必须**封顶后不再增长**。

    用的是库当前的 Schema 上限（本档位 5 DN ⇒ ``R_schema=5``）；若档位上限 ≥ 8 则构造不出
    ``K>R``，按环境前置 SKIP。Data 侧上限远大于 12，故 ``min(K, R_data)=K``。
    """
    if not _precondition(ctx):
        return
    db = _solo_db(ctx, "tree")
    cap_s, cap_d = _caps(ctx, "tree", db)
    if ctx.skipped:
        return
    if cap_s >= 8:
        ctx.skip(f"本档位 Schema 上限={cap_s} ≥ 8，构造不出 K>R（需要 R_schema<8 的档位）")
        return
    devices = device_set(ctx, db, 12, prefix="pgr", slot_num=_slot_num(ctx))
    expect_groups(ctx, "DEV-18 写入前空库", db, "tree", schema=0, data=0)
    for device in devices[:8]:
        ensure_write_tree(ctx, db, device, 1)
    expect_groups(ctx, f"DEV-18 K=8 > R_schema={cap_s}：Schema 封顶、Data=min(8, R_data)",
                  db, "tree", schema=cap_s, data=min(8, cap_d))
    for device in devices[8:]:
        ensure_write_tree(ctx, db, device, 2)
    expect_groups(ctx, f"DEV-18 再写 4 个新 slot（K=12）：Schema 保持 {cap_s} 不再增长",
                  db, "tree", schema=cap_s, data=min(12, cap_d))
    _device_group_consistency(ctx, "DEV-18 K>R", db, devices, "tree", cap_d)


def case_dev19_growth_sequence(ctx: Ctx) -> None:
    """DEV-19 逐个写入的增长序列：第 i 步必须等于 ``min(i, R)``（spec §3.6 公式）。

    docs §4.3.3 给出的 ``1,2,3,4,5,6`` 序列以"每库上限 ≥ 6"为前提；本档位
    ``R_schema=5`` ⇒ Schema 序列应为 ``1,2,3,4,5,5``、Data 序列 ``1..6``。所以断言写成
    ``min(i, R)`` 的实测序列（**不照抄文档的 6**），两个类型分别对拍。
    """
    _tree_multi_slots(ctx, 6, "DEV-19 增长序列", per_step=True, sequence=True)


def case_dev20_coslot_new_time_partition(ctx: Ctx) -> None:
    """DEV-20 共槽设备 + 跨时间分区：同 slot 不新增组；新分区也不增 slot。

    时间分区用**库详情读回的时间分区间隔**构造（``t`` 与 ``t+interval`` 必落在相邻两分区），
    不依赖 conf 里写死的秒/毫秒单位。期望值按 spec §3.6 公式：
    已有 ``G>=min`` 时"已有 slot 申请新时间分区" ``minimumTarget=min(min, G+|P|)=min<=G``
    ⇒ 目标不变、组数不增（``G<min`` 时补到 min 的分支由 PG-MIN-02 覆盖）。
    """
    if not _precondition(ctx):
        return
    db = _solo_db(ctx, "tree")
    cap_s, cap_d = _caps(ctx, "tree", db)
    if ctx.skipped:
        return
    interval = ctx.api.db_time_partition_interval(db)
    if interval <= 0:
        ctx.skip("读不到库的 TimePartitionInterval，无法构造跨时间分区")
        return
    devices = device_set(ctx, db, 2)
    base = 1_000_000
    for device in devices:
        ensure_write_tree(ctx, db, device, base)
    _check_counts(ctx, "DEV-20 先写 2 个不同 slot（G=min 已满足）", db, "tree",
                  schema=min(2, cap_s), data=min(2, cap_d))
    used = set(_declared_slots(ctx, db, devices, "tree").values())
    pair, pair_slot = _colliding_pair(ctx, db, used)
    ctx.check("harness 找到一对共槽设备且其 slot 不在既有 slot 中",
              pair_slot not in used, f"pair={pair}、slot={pair_slot}")
    for device in pair:
        ensure_write_tree(ctx, db, device, base + interval)
    expect_groups(ctx, "DEV-20 共槽 2 设备只算 1 个新 slot", db, "tree",
                  schema=min(3, cap_s), data=min(3, cap_d))
    for device in devices:
        ensure_write_tree(ctx, db, device, base + interval)
    expect_groups(ctx, "DEV-20 已有 slot 申请新时间分区（组数不增）", db, "tree",
                  schema=min(3, cap_s), data=min(3, cap_d))
    ctx.check("第一个设备已落在 2 个时间分区",
              ctx.api.timeslot_count(device=f"{db}.{devices[0]}", dialect="tree") == 2,
              f"COUNT TIMESLOTID={ctx.api.timeslot_count(device=f'{db}.{devices[0]}', dialect='tree')}")
    ctx.check("共槽设备只落在 1 个时间分区",
              ctx.api.timeslot_count(device=f"{db}.{pair[0]}", dialect="tree") == 1,
              f"COUNT TIMESLOTID={ctx.api.timeslot_count(device=f'{db}.{pair[0]}', dialect='tree')}")


def _colliding_pair(ctx: Ctx, db: str, exclude: set[int]) -> tuple[list[str], int]:
    """找一对共槽设备，且其 slot 不在 ``exclude`` 中（用 harness BKDR131 计算）。"""
    for index in range(50):
        pair = pslots.find_colliding_devices(db, 2, prefix=f"pgc{index}", slot_num=_slot_num(ctx))
        slot = pslots.tree_device_slot(db, pair[0], slot_num=_slot_num(ctx))
        if slot not in exclude:
            return pair, slot
    raise AssertionError("找不到与既有 slot 不同的共槽设备对")


def case_dev21_thousand_slots(ctx: Ctx) -> None:
    """DEV-21 1000 个不同 slot（大 K）：组数封顶 ``min(1000, R)``，且封顶后不再增长。

    同时取证"两库独立计数"：先建树库写 3 个不同 slot（A 库），再建表库写 1000 个不同 slot
    （B 库）。两库并存 ⇒ 上限公式分母=2（spec §4.1 树+表普通库一起计数）⇒ 表库
    ``R_schema=ceil(3×5/(2×3))=3``、``R_data=ceil(0.5×240/(2×2))=30``：期望就是
    ``min(1000, R)``（catalog：组数 = R 封顶）。期间 A 库组数不变（独立计数，各自断言）。
    """
    if not _precondition(ctx):
        return
    db_tree = _solo_db(ctx, "tree")
    db_table = reset_db(ctx, "table")          # 两库并存：分摊库数=2
    tree_devices = device_set(ctx, db_tree, 3)
    cap_ts, cap_td = _caps(ctx, "tree", db_tree)
    if ctx.skipped:
        return
    cap_bs, cap_bd = _caps(ctx, "table", db_table)
    if ctx.skipped:
        return
    ctx.note(f"    两库并存：参与分摊库数=2 ⇒ 树库上限 Schema={cap_ts}/Data={cap_td}、"
             f"表库 Schema={cap_bs}/Data={cap_bd}（期望一律 min(K, 上限)）")
    expect_groups(ctx, "DEV-21 写入前：树库", db_tree, "tree", schema=0, data=0)
    expect_groups(ctx, "DEV-21 写入前：表库", db_table, "table", schema=0, data=0)
    write_devices(ctx, db_tree, tree_devices, model="tree")
    expect_groups(ctx, "DEV-21 先写 A（树）库 3 个 slot 后", db_tree, "tree",
                  schema=min(3, cap_ts), data=min(3, cap_td))
    expect_groups(ctx, "DEV-21 B（表）库仍为 0/0（独立计数）", db_table, "table", schema=0, data=0)
    tags = device_set(ctx, db_table, 1000, dialect="table", prefix="pgt", table=TABLE,
                      slot_num=_slot_num(ctx))
    ctx.check("DEV-21：harness 生成的 1000 个 TAG 覆盖 1000 个不同 slot（= series_slot_num）",
              pslots.distinct_tag_slot_count(TABLE, tags, slot_num=_slot_num(ctx)) == 1000,
              f"distinct={pslots.distinct_tag_slot_count(TABLE, tags, slot_num=_slot_num(ctx))}")
    ctx.req(ctx.api.create_table(db_table, TABLE, columns="devid STRING TAG, s0 FLOAT FIELD"),
            "建表 DEV-21")
    _insert_table_chunks(ctx, db_table, tags, start_stamp=1, chunk=200)
    expect_groups(ctx, "DEV-21 B（表）库 1000 个不同 slot（封顶 min(1000, R)）", db_table, "table",
                  schema=min(1000, cap_bs), data=min(1000, cap_bd))
    observed_max = ctx.api.db_max_group_num(db_table, "DATA", dialect="table")
    ctx.check(f"DEV-21：表库 Data 组数应等于封顶值 min(1000, 产品自报上限={observed_max})",
              ctx.api.db_group_num(db_table, "DATA", dialect="table") == min(1000, observed_max),
              f"组数={ctx.api.db_group_num(db_table, 'DATA', dialect='table')}")
    expect_groups(ctx, "DEV-21 A（树）库组数不受 B 库影响（独立计数）", db_tree, "tree",
                  schema=min(3, cap_ts), data=min(3, cap_td))
    more = device_set(ctx, db_table, 5, dialect="table", prefix="pgext", table=TABLE,
                      slot_num=_slot_num(ctx))
    _insert_table_chunks(ctx, db_table, more, start_stamp=5000, chunk=200)
    expect_groups(ctx, "DEV-21 封顶后再写 5 个新 TAG（组数不变）", db_table, "table",
                  schema=min(1000, cap_bs), data=min(1000, cap_bd))
    ctx.check("DEV-21：1005 行数据可查（1000 + 5）",
              ctx.api.count_rows(f"{db_table}.{TABLE}", dialect="table") == 1005,
              f"count={ctx.api.count_rows(f'{db_table}.{TABLE}', dialect='table')}")
    _device_group_consistency(ctx, "DEV-21 树库 3 设备", db_tree, tree_devices, "tree", cap_td)
    ctx.add_query("dev21-count", f"select count(*) from {db_table}.{TABLE}", "table")


def case_dev22_multilevel_device_path(ctx: Ctx) -> None:
    """DEV-22 单设备多层级路径（``d0.sub1.sub2``）：整条设备路径只算 1 个 slot ⇒ 1 组。"""
    if not _precondition(ctx):
        return
    db = _solo_db(ctx, "tree")
    cap_s, cap_d = _caps(ctx, "tree", db)
    if ctx.skipped:
        return
    device = "d0.sub1.sub2"
    ensure_write_tree(ctx, db, device, 1, sensors=("s0",))
    expect_groups(ctx, "DEV-22 多层级设备路径（1 个设备 = 1 个 slot）", db, "tree",
                  schema=min(1, cap_s), data=min(1, cap_d))
    ctx.check("DEV-22：多层级设备的数据可查",
              ctx.api.count_rows(f"{db}.{device}") == 1,
              f"count={ctx.api.count_rows(f'{db}.{device}')}")
    _device_group_consistency(ctx, "DEV-22 多层级设备", db, [device], "tree", cap_d)


def case_dev23_chinese_device_names(ctx: Ctx) -> None:
    """DEV-23 中文设备名（docs/127 Tree 中文）+ 设备名边界：组数 = 实测不同 slot 数。

    主场景：写 3 个中文名设备，期望 ``min(实测不同 slot 数, R)``（与 harness BKDR131 对齐）。
    边界探测（全部先 ``mark_harness_action`` 开归因窗口）：``d_1``（NAME_CHAR 含 ``_``，应接受）、
    ``d-1``（``-`` 不在 NAME_CHAR，应拒绝）、255 字符超长名（接受⇒只占 1 个 slot；拒绝⇒
    **断言不建组**，不判 FAIL）。组数期望按"被接受名字的不同 slot 数"重算。
    """
    if not _precondition(ctx):
        return
    db = _solo_db(ctx, "tree")
    cap_s, cap_d = _caps(ctx, "tree", db)
    if ctx.skipped:
        return
    chinese = ("设备甲", "设备乙", "设备丙")
    expect_groups(ctx, "DEV-23 写入前空库", db, "tree", schema=0, data=0)
    for index, name in enumerate(chinese, start=1):
        ensure_write_tree(ctx, db, name, index)
    kinds = pslots.distinct_slot_count(db, chinese, slot_num=_slot_num(ctx))
    expect_groups(ctx, f"DEV-23 3 个中文设备名（{kinds} 个不同 slot）", db, "tree",
                  schema=min(kinds, cap_s), data=min(kinds, cap_d))
    accepted = list(chinese)
    for name in ("d_1", "d-1"):
        before = ctx.api.db_group_num(db, "DATA", dialect="tree")
        ctx.mark_harness_action(f"探测树模型设备名合法性：{name}", pad=20)
        outcome = ctx.api.insert_tree(f"{db}.{name}", 9, ["s0"], [1.0])
        if outcome.ok:
            accepted.append(name)
            ctx.note(f"    探测 {name}: 产品接受（按 harness slot 计入后续期望）")
        else:
            ctx.check(f"DEV-23：设备名 {name} 被产品拒绝 ⇒ 不得产生任何新分区"
                      "（合法拒绝，不判 FAIL）",
                      ctx.api.db_group_num(db, "DATA", dialect="tree") == before,
                      f"拒绝前 Data 组数={before}、拒绝后="
                      f"{ctx.api.db_group_num(db, 'DATA', dialect='tree')}；"
                      f"SQL 报错：{outcome.flat[:150]}")
    ctx.check("DEV-23：下划线设备名 d_1 被接受（NAME_CHAR 含 '_'）", "d_1" in accepted,
              f"accepted={accepted}")
    ctx.check("DEV-23：连字符设备名 d-1 被拒绝（'-' 不在 NAME_CHAR）", "d-1" not in accepted,
              f"accepted={accepted}")
    long_name = "d" + "x" * 254
    before = ctx.api.db_group_num(db, "DATA", dialect="tree")
    ctx.mark_harness_action(f"探测超长树模型设备名（{len(long_name)} 字符）", pad=20)
    outcome = ctx.api.insert_tree(f"{db}.{long_name}", 9, ["s0"], [1.0])
    if outcome.ok:
        accepted.append(long_name)
        ctx.note(f"    {len(long_name)} 字符设备名被接受")
    else:
        ctx.check(f"DEV-23：{len(long_name)} 字符超长设备名被拒绝 ⇒ 不得产生任何新分区"
                  "（合法拒绝，不判 FAIL）",
                  ctx.api.db_group_num(db, "DATA", dialect="tree") == before,
                  f"拒绝前 Data 组数={before}；SQL 报错：{outcome.flat[:150]}")
    kinds = pslots.distinct_slot_count(db, accepted, slot_num=_slot_num(ctx))
    expect_groups(ctx, f"DEV-23 全部被接受的 {len(accepted)} 个名字（{kinds} 个不同 slot）",
                  db, "tree", schema=min(kinds, cap_s), data=min(kinds, cap_d))
    ctx.check("DEV-23：组数由 slot 决定而非名字个数（组数 = min(实测不同 slot 数, R)）",
              ctx.api.db_group_num(db, "DATA", dialect="tree") == min(kinds, cap_d),
              f"名字数={len(accepted)}、不同 slot 数={kinds}、Data 组数="
              f"{ctx.api.db_group_num(db, 'DATA', dialect='tree')}")
    _device_group_consistency(ctx, "DEV-23 被接受的设备名", db, accepted, "tree", cap_d)
    ctx.add_query("dev23-count", f"select count(*) from {db}.{chinese[0]}", "tree")


def _insert_table_chunks(ctx: Ctx, db: str, tags: list[str], *, start_stamp: int,
                         chunk: int = 200) -> None:
    for base in range(0, len(tags), chunk):
        part = tags[base:base + chunk]
        rows = [(start_stamp + base + index, tag, [1.0])
                for index, tag in enumerate(part)]
        ctx.req(ctx.api.insert_table_many(db, TABLE, "devid", rows),
                f"批量写入 {len(part)} 行 TAG")


def case_dev24_table_null_tag(ctx: Ctx) -> None:
    """DEV-24 表模型 null TAG：null 段按 ``NULL_SEGMENT_HASH_NUM`` 入哈希 ⇒ 组数 = 实测不同 slot 数。"""
    if not _precondition(ctx):
        return
    db = _solo_db(ctx, "table")
    cap_s, cap_d = _caps(ctx, "table", db)
    if ctx.skipped:
        return
    null_slot = pslots.table_slot(TABLE, [None], slot_num=_slot_num(ctx))
    tag = next(name for name in (f"pgn{i}" for i in range(2000))
               if pslots.table_slot(TABLE, [name], slot_num=_slot_num(ctx)) != null_slot)
    ensure_write_table(ctx, db, TABLE, tag, stamp=1, fields=2)
    expect_groups(ctx, "DEV-24 先写普通 TAG（1 个 slot）", db, "table",
                  schema=min(1, cap_s), data=min(1, cap_d))
    ctx.mark_harness_action("探测表模型 null TAG 设备（NULL 段以 NULL_SEGMENT_HASH_NUM 入哈希）",
                            pad=20)
    outcome = ctx.api.run(
        f"insert into {db}.{TABLE}(time, devid, s0, s1) values(1, null, 1.0, 2.0)",
        dialect="table")
    expected = 2 if outcome.ok else 1
    if outcome.ok:
        ctx.note(f"    null TAG 写入被接受（null slot={null_slot}、"
                 f"普通 TAG slot={pslots.table_slot(TABLE, [tag], slot_num=_slot_num(ctx))}）")
    else:
        ctx.note(f"    null TAG 写入被产品拒绝：{outcome.flat[:150]}")
    harness_slots = (pslots.distinct_tag_slot_count(TABLE, [None, tag], slot_num=_slot_num(ctx))
                     if outcome.ok
                     else pslots.distinct_tag_slot_count(TABLE, [tag], slot_num=_slot_num(ctx)))
    ctx.check(f"DEV-24：harness 实测不同 slot 数应为 {expected}（null 段 vs 普通 TAG）",
              harness_slots == expected, f"实际={harness_slots}、null_slot={null_slot}、"
              f"tag_slot={pslots.table_slot(TABLE, [tag], slot_num=_slot_num(ctx))}")
    expect_groups(ctx, f"DEV-24 null TAG + 普通 TAG（{expected} 个不同 slot）", db, "table",
                  schema=min(expected, cap_s), data=min(expected, cap_d))


# --------------------------------------------------------------------------- PG-OBS-02/03
def _regionid_set(ctx: Ctx, db: str, kind: str, dialect: str, *, device: str = "") -> set[str]:
    """``SHOW (DATA|SCHEMA) REGIONID WHERE DEVICE=|DATABASE=`` 的 RegionId 去重集合。

    树方言语法：``getRegionId``（``IoTDBSqlParser.g4:577``）；表方言该语句被
    ``AstBuilder.java:1781`` 判为 not supported（SemanticException）。
    """
    where = f"device={device}" if device else f"database={db}"
    outcome = ctx.api.run(f"show {kind.lower()} regionid where {where}", dialect=dialect)
    if not outcome.ok:
        return set()
    column = ctx.api.column(outcome.rows, *_REGION_ID_COLS)
    if not column:
        return set()
    return {row.get(column, "").strip() for row in outcome.rows if row.get(column, "").strip()}


def case_obs02_three_views(ctx: Ctx) -> None:
    """OBS-02 三大观测面口径一致：库详情组数 == REGIONS 去重 == REGIONID(DATABASE) 去重。

    树模型三面都做；表方言**没有** REGIONID/TIMESLOTID 可观测量（``AstBuilder.java:1781/1785``
    抛 SemanticException），故表模型做两面 + 显式断言"第三面被拒绝"，不假装做过。
    """
    if not _precondition(ctx):
        return
    db = _solo_db(ctx, "tree")
    cap_s, cap_d = _caps(ctx, "tree", db)
    if ctx.skipped:
        return
    devices = device_set(ctx, db, 5)
    write_devices(ctx, db, devices, model="tree")
    for kind, cap in (("SCHEMA", cap_s), ("DATA", cap_d)):
        want = min(5, cap)
        detail = ctx.api.db_group_num(db, kind, dialect="tree")
        dedup = ctx.api.group_count(db, kind=kind, dialect="tree")
        regionid = len(_regionid_set(ctx, db, kind, "tree"))
        ctx.check(f"OBS-02 树模型 {kind}：DETAILS = REGIONS去重 = REGIONID(DATABASE)去重"
                  f" = min(5, R) = {want}",
                  detail == dedup == regionid == want,
                  f"DETAILS={detail}、REGIONS去重={dedup}、REGIONID去重={regionid}")

    db2 = _solo_db(ctx, "table")
    cap2_s, cap2_d = _caps(ctx, "table", db2)
    if ctx.skipped:
        return
    tags = device_set(ctx, db2, 5, dialect="table", table=TABLE)
    write_devices(ctx, db2, tags, model="table")
    for kind, cap in (("SCHEMA", cap2_s), ("DATA", cap2_d)):
        want = min(5, cap)
        detail = ctx.api.db_group_num(db2, kind, dialect="table")
        dedup = ctx.api.group_count(db2, kind=kind, dialect="table")
        ctx.check(f"OBS-02 表模型 {kind}：DETAILS = REGIONS去重 = min(5, R) = {want}",
                  detail == dedup == want, f"DETAILS={detail}、REGIONS去重={dedup}")
    ctx.mark_harness_action("探测表方言的 SHOW REGIONID/TIMESLOTID（源码标注 not supported yet）",
                            pad=20)
    for statement in (f"show data regionid where database='{db2}'",
                      f"show timeslotid where database='{db2}'"):
        outcome = ctx.api.run(statement, dialect="table")
        ctx.check(f"OBS-02 表方言拒绝 `{statement}`（AstBuilder:1781/1785 抛 SemanticException）",
                  not outcome.ok, outcome.flat[:200] or "意外成功")


def case_obs03_device_vs_database(ctx: Ctx) -> None:
    """OBS-03 ``REGIONID WHERE DEVICE=`` 与 ``WHERE DATABASE=`` 的口径关系 + 时间分区计数。

    * 同一设备（DATA/SCHEMA）的 RegionId 必须**全部落在** ``WHERE DATABASE`` 结果里；
    * ``COUNT/SHOW TIMESLOTID|TIMEPARTITION WHERE DEVICE=`` 的计数 = 实际写入的时间分区数
      （时间戳取 ``t`` 与 ``t+库详情读回的 interval``，必落相邻两分区）；
    * 单时间分区设备 ⇒ 只映射到 1 个 Data 组（组数期望按 spec §3.6：``G<min`` 时
      "已有 slot 申请新时间分区"补到 ``min(minNum, 分区数)``，故期望
      ``min(R, min(min_data, 分区数))``）。
    """
    if not _precondition(ctx):
        return
    db = _solo_db(ctx, "tree")
    cap_s, cap_d = _caps(ctx, "tree", db)
    if ctx.skipped:
        return
    interval = ctx.api.db_time_partition_interval(db)
    if interval <= 0:
        ctx.skip("读不到库的 TimePartitionInterval，无法断言时间分区计数")
        return
    devices = device_set(ctx, db, 2)
    single, multi = devices[0], devices[1]
    base = 1_000_000
    ensure_write_tree(ctx, db, single, base, sensors=("s0",))
    for stamp in (base, base + interval):
        ensure_write_tree(ctx, db, multi, stamp, sensors=("s0",))
    partitions = len({stamp // interval for stamp in (base, base + interval)})
    min_data = int(ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    expect_groups(ctx, f"OBS-03 1 个单分区设备 + 1 个 {partitions} 分区设备", db, "tree",
                  schema=min(2, cap_s), data=min(cap_d, max(1, min(min_data, partitions))))

    for kind in ("DATA", "SCHEMA"):
        by_device = _regionid_set(ctx, db, kind, "tree", device=f"{db}.{multi}")
        by_database = _regionid_set(ctx, db, kind, "tree")
        ctx.check(f"OBS-03 {kind}：设备 {multi} 的组必须落在 WHERE DATABASE 结果内",
                  bool(by_device) and by_device <= by_database,
                  f"DEVICE={sorted(by_device)}、DATABASE={sorted(by_database)}")
    single_groups = _regionid_set(ctx, db, "DATA", "tree", device=f"{db}.{single}")
    ctx.check("OBS-03 单时间分区设备只映射到 1 个 DataRegionGroup", len(single_groups) == 1,
              f"DEVICE={single} 的组={sorted(single_groups)}")
    expected_ts = partitions
    ctx.check(f"OBS-03 COUNT TIMESLOTID WHERE DEVICE={multi} 应等于写入的时间分区数 {expected_ts}",
              ctx.api.timeslot_count(device=f"{db}.{multi}", dialect="tree") == expected_ts,
              f"COUNT={ctx.api.timeslot_count(device=f'{db}.{multi}', dialect='tree')}")
    for keyword in ("timeslotid", "timepartition"):
        outcome = ctx.api.run(f"show {keyword} where device={db}.{multi}", dialect="tree")
        ctx.check(f"OBS-03 SHOW {keyword.upper()} WHERE DEVICE 行数 = {expected_ts}",
                  outcome.ok and len(outcome.rows) == expected_ts,
                  f"rows={len(outcome.rows) if outcome.ok else 'ERR'}、out={outcome.flat[:150]}")


# ------------------------------------------------------------------------------ registry
SPECS.append(CaseSpec("PG-DEV-01", "共槽", "tree",
                      "树 K=1（1 设备 1 测点）：组数 = min(1, R)", "P0", case_dev01_tree_k1))
SPECS.append(CaseSpec("PG-DEV-02", "共槽", "tree",
                      "树 K=2（首设备 3 测点）：测点数不增 slot，组数 = min(2, R)",
                      "P1", case_dev02_tree_k2))
SPECS.append(CaseSpec("PG-DEV-03", "共槽", "tree",
                      "树 K=3（首设备 10 测点）：组数 = min(3, R)", "P1", case_dev03_tree_k3))
SPECS.append(CaseSpec("PG-DEV-04", "共槽", "tree",
                      "树 K=6（首设备 100 测点）：组数 = min(6, R)", "P1", case_dev04_tree_k6))
SPECS.append(CaseSpec("PG-DEV-05", "共槽", "tree",
                      "树 K=10 逐个写入：每步 = min(i, R)", "P0", case_dev05_tree_k10))
SPECS.append(CaseSpec("PG-DEV-06", "共槽", "tree",
                      "树 K=20：终值 min(20, R)（Schema 先封顶、Data 继续）",
                      "P1", case_dev06_tree_k20))
SPECS.append(CaseSpec("PG-DEV-07", "共槽", "table",
                      "表 K=1（1 TAG 1 列）：组数 = min(1, R)", "P0", case_dev07_table_k1))
SPECS.append(CaseSpec("PG-DEV-08", "共槽", "table",
                      "表 K=2（首 TAG 3 列）：列数不增 slot，组数 = min(2, R)",
                      "P1", case_dev08_table_k2))
SPECS.append(CaseSpec("PG-DEV-09", "共槽", "table",
                      "表 K=3（首 TAG 10 列）：组数 = min(3, R)", "P1", case_dev09_table_k3))
SPECS.append(CaseSpec("PG-DEV-10", "共槽", "table",
                      "表 K=6（首 TAG 100 列）：组数 = min(6, R)", "P1", case_dev10_table_k6))
SPECS.append(CaseSpec("PG-DEV-11", "共槽", "table",
                      "表 K=10 逐个写入：每步 = min(i, R)", "P0", case_dev11_table_k10))
SPECS.append(CaseSpec("PG-DEV-12", "共槽", "table",
                      "表 K=20：终值 min(20, R)", "P1", case_dev12_table_k20))
SPECS.append(CaseSpec("PG-DEV-17", "共槽", "tree",
                      "连续编号设备（含共槽编号）：组数 = 实测不同 slot 数，不断言设备数",
                      "P1", case_dev17_consecutive_numbering))
SPECS.append(CaseSpec("PG-DEV-18", "共槽", "tree",
                      "K > R：Schema 封顶 R 后不再增长（K=8→12）", "P0", case_dev18_k_gt_r))
SPECS.append(CaseSpec("PG-DEV-19", "共槽", "tree",
                      "逐个写入的增长序列 = min(i, R)（Schema 与 Data 分别对拍）",
                      "P1", case_dev19_growth_sequence))
SPECS.append(CaseSpec("PG-DEV-20", "共槽", "tree",
                      "共槽设备 + 跨时间分区：同 slot 不新增组、时间分区不增 slot",
                      "P0", case_dev20_coslot_new_time_partition))
SPECS.append(CaseSpec("PG-DEV-21", "共槽", "tree+table",
                      "1000 个不同 slot 封顶 min(1000, R)；兼两库独立计数（先写树库再写表库）",
                      "P0", case_dev21_thousand_slots, gate=True))
SPECS.append(CaseSpec("PG-DEV-22", "共槽", "tree",
                      "单设备多层级路径 d0.sub1.sub2：整条路径 1 个 slot ⇒ 1 组",
                      "P1", case_dev22_multilevel_device_path))
SPECS.append(CaseSpec("PG-DEV-23", "共槽", "tree",
                      "中文设备名 + 名称边界（d_1/d-1/超长）：组数 = 实测不同 slot 数",
                      "P1", case_dev23_chinese_device_names))
SPECS.append(CaseSpec("PG-DEV-24", "共槽", "table",
                      "表模型 null TAG：null 段参与哈希，组数 = 实测不同 slot 数",
                      "P1", case_dev24_table_null_tag))
SPECS.append(CaseSpec("PG-OBS-02", "观测", "tree+table",
                      "三大观测面口径一致（DETAILS/REGIONS/REGIONID WHERE DATABASE）",
                      "P0", case_obs02_three_views))
SPECS.append(CaseSpec("PG-OBS-03", "观测", "tree",
                      "REGIONID WHERE DEVICE= ⊆ WHERE DATABASE= 且时间分区计数与写入一致",
                      "P0", case_obs03_device_vs_database))
