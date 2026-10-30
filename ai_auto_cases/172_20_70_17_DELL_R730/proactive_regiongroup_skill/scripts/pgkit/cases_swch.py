"""PG-SWCH（策略切换）/ PG-PRV（权限）用例族：`PG-SWCH-01..12` + `PG-PRV-01..08`（共 20 条）。

判定口径（唯一来源：``references/proactive-spec.md`` §3 + ``doc-gaps.md`` G-01 + 源码）
====================================================================================
对单个库、单种 Region 类型（``PartitionManager.java:654-699``）：:

    minimumTarget = min(minNum, G + |P|)          # 只数"本次请求"的不同 slot
    T             = min(R, max(minimumTarget, K)) # PROACTIVE：再按 slot 总数取大
    delta         = max(0, T - G)                 # 组数只增不减

其中 ``G`` = 已有组数、``|P|`` = 本次请求内去重 slot 数、``K = |S ∪ P|``（历史 slot ∪
本次 slot）、``R`` = ``cases.expected_cap()``、``minNum`` = 该类最小组数的**生效值**。

**策略差异**（catalog `SWCH-01/02/11` + spec §8.1：AUTO 恒为 min、PROACTIVE 才按 K 扩张）：
* ``PROACTIVE``：完整公式，``T = min(R, max(min(minNum, G+|P|), K))`` —— 会因历史 slot
  数 K 积极扩容（catalog SWCH-01：AUTO 停在 2 组，切 PROACTIVE 后对**已有 slot** 写新时间
  分区即补到 ``min(K,R)``）；
* ``AUTO`` / ``CUSTOM``：**不参与 K 项**，``T = min(R, max(G, min(minNum, G+|P|)))`` ——
  只顺着 ``G+|P|`` 增量逼近 ``minNum``，到顶后新 slot 不再增长（SWCH-02/03/11）。
本模块的 ``_want()`` / ``_want_str()`` 就是上面两条公式的 Python 现算，**所有期望值都由它
产生**，不写死任何组数。

纪律
====
* 每条用例先 ``_solo_tree(ctx)``（= ``reset_db`` + 清掉另一方言测试库，使 ``expected_cap``
  的"参与分摊库数"=1）；
* 热加载改过的键在用例结束前显式恢复成 ``ctx.cfg.raw(...)``（``_conf_policy`` 兜底默认值）
  并读回自证；``_set_knob`` 同时把恢复语句登记进 ``ctx.cleanup``，异常路径也会还原；
* 所有"故意非法 / 预期被拒"的动作（非法值、普通用户越权）前先 ``ctx.mark_harness_action``
  开日志归因窗口；
* cluster 级档位不匹配（上限不够、缺 DN、读不到 conf）一律 ``ctx.skip`` 写明原因，
  **绝不降级成 PASS**；每条 check 都有明确期望值（公式现算或显式二选一结论）。
* 权限用例创建的用户一律登记 ``ctx.cleanup`` 删除（``_setup_user`` 负责）。

已知缺口 / 未覆盖
=================
* **G-02**：非法策略值被拒时产品复用 Data 键文案；SWCH-10 只判"被拒 + 文件未变 + 行为
  仍按原策略"，不作文案断言。
* catalog 的 ``SWCH-12``（切换与新建组**并发**）需要并发写负载（``ctx.api.bench_run`` /
  iot-benchmark），本模块的 SWCH-12 按父任务书落到"切换后新增 slot 按新策略"，并发形态未覆盖。
* ``PG-PRV-03/07/08`` 的"产品允许 / 可见"分支是**事实记录**：两种结论都算有效，但必须
  在 detail 与 note 里写清是哪一种。
"""

from __future__ import annotations

import json
import time

from . import slots as pslots
from .cases import (
    CaseSpec,
    Ctx,
    device_set,
    ensure_write_tree,
    expect_groups,
    expected_cap,
    group_counts,
    write_devices,
    group_ceiling,
)
from .cases_cfg import (
    _BASE_STAMP,
    _POLICY_OF,
    _TREE,
    _conf_min,
    _conf_policy,
    _effective_min,
    _ensure_readable,
    _flat,
    _push_restore,
    _read_map,
    _read_prop,
    _read_until,
    _restore_knob,
    _set_knob,
    _solo_tree,
)

SPECS: list[CaseSpec] = []

#: 策略键的合法值（区分大小写，spec §1）
_LEGAL = ("CUSTOM", "AUTO", "PROACTIVE")
#: 用户配置键（None/空 ⇒ SKIP，写明 conf 未配置该用户）
_USER_KEYS = {
    "normal": ("PG_NORMAL_USER", "PG_NORMAL_PASSWORD"),
    "system": ("PG_SYSTEM_USER", "PG_SYSTEM_PASSWORD"),
}
_SLOT_NUM_DEFAULT = 1000


# ============================================================== 公式与槽计算
def _slot_num(ctx: Ctx) -> int:
    return int(ctx.cfg.raw("PG_SERIES_SLOT_NUM") or _SLOT_NUM_DEFAULT)


def _slot_of(ctx: Ctx, db: str, device: str) -> int:
    return pslots.tree_device_slot(db, device, slot_num=_slot_num(ctx))


def _want(policy: str, min_num: int, cap: int, groups: int, p_count: int, k: int) -> int:
    """源码口径的组数目标（组只增不减 ⇒ 结果不低于 G）。

    H-27：``CUSTOM`` 的语义**不是**"停在 minNum"，而是"**补满** ``maxRegionGroupNum``"
    （``PartitionManager.java:701-722`` ``customExtendRegionGroupIfNecessary``）。
    首轮实测把它按"停在 minNum"建模，于是 CUSTOM 下实测 60（= R）被判成失败。
    """
    p = (policy or "PROACTIVE").upper()
    base = min(min_num, groups + p_count)          # minimumTarget
    if p == "PROACTIVE":
        target = min(cap, max(base, k))            # 参与 K 项
    elif p == "CUSTOM":
        target = cap                               # H-27：补满 R
    else:                                          # AUTO：不参与 K 项
        target = min(cap, base)
    return max(groups, target)


def _want_str(policy: str, min_num: int, cap: int, groups: int, p_count: int, k: int) -> str:
    p = (policy or "PROACTIVE").upper()
    base = min(min_num, groups + p_count)
    want = _want(policy, min_num, cap, groups, p_count, k)
    if p == "PROACTIVE":
        return (f"T=min(R={cap}, max(minimumTarget=min(minNum={min_num}, G+|P|={groups}+{p_count})"
                f"={base}, K={k}))={want}")
    if p == "CUSTOM":
        return (f"T=R={cap}（CUSTOM 一次补满，customExtendRegionGroupIfNecessary）={want}；"
                f"max(G={groups}, R)={want}")
    return (f"T=min(R={cap}, minimumTarget=min(minNum={min_num}, G+|P|={groups}+{p_count})={base})"
            f"（{policy} 不参与 K={k} 项）={want}")


def _groups(ctx: Ctx, db: str, kind: str) -> int:
    return ctx.api.db_group_num(db, kind, dialect=_TREE)


def _step(ctx: Ctx, label: str, db: str, kind: str, policy: str, min_num: int, cap: int,
          written: set, device: str, stamp: int, new_slot: bool | None = None) -> int:
    """写一个设备（单条请求、单 slot）后断言该类组数 = 公式现算值；返回本次观测组数。

    ``written`` 为**截至目前已写过的 slot 集合**（不含本次）；函数返回后不修改它，
    由调用方决定何时加入（同一 slot 写新时间分区时 K 不变，正是靠这一点表达）。

    H-27（双写记账）：``|P|`` 只能数**本次请求内真的新增**的 slot。同一设备先写 SCHEMA
    再写 DATA 时，第二条 insert 没有新 slot，旧实现仍按 ``|P|=1`` 代入
    ``minimumTarget=min(minNum, G+1)``，把 ``G+|P|`` 记虚高（SWCH-05/06/11）。
    现按 ``slot in written`` 自动判定；跨类双写时由调用方显式传 ``new_slot``。
    """
    slot = _slot_of(ctx, db, device)
    groups = _groups(ctx, db, kind)
    p_count = (0 if slot in written else 1) if new_slot is None else int(bool(new_slot))
    k = len(set(written) | {slot})
    want = _want(policy, min_num, cap, groups, p_count, k)
    ensure_write_tree(ctx, db, device, stamp)
    got = _groups(ctx, db, kind)
    ctx.check(f"{label}：写 {device}（|P|={p_count}、K={k}）后 {kind} 组数应为 {want}"
              f"（{_want_str(policy, min_num, cap, groups, p_count, k)}）", got == want,
              f"实测={got}", evidence=json.dumps(
                  {"db": db, "kind": kind, "policy": policy, "slot": slot, "written": sorted(written),
                   "P": p_count, "K": k, "G": groups, "want": want, "got": got},
                  ensure_ascii=False))
    return got


def _toggle(policy: str) -> str:
    """取一个与当前值不同的合法策略（用差异最大的 AUTO ↔ PROACTIVE）。"""
    return "AUTO" if (policy or "").upper() == "PROACTIVE" else "PROACTIVE"


def _cap_or_skip(ctx: Ctx, label: str, db: str, need: int) -> int:
    """组数建模用的 Data 上限 R。

    H-19/H-10：产品按库保留**单调不减**的上限，组数跟着**自报值**走；公式只作"档位够不够"
    的门槛。旧实现拿公式当 R，自报 60 / 公式 30 时会把正确的组数判成超限。
    """
    formula = expected_cap(ctx, "DATA", _TREE, db)
    if not ctx.cfg.dn_hosts:
        ctx.skip(f"{label}：conf 未定义 DataNode（集群档位不匹配）")
        return 0
    if formula < need:
        ctx.skip(f"{label}：公式 Data 上限 R={formula} < 需求 {need}（集群档位不匹配）")
        return 0
    return max(formula, group_ceiling(ctx, "DATA", _TREE, db))


# ================================================================== 用户夹具
def _user_conf(ctx: Ctx, label: str, kind: str):
    name_key, pw_key = _USER_KEYS[kind]
    name = (ctx.cfg.raw(name_key) or "").strip()
    pw = (ctx.cfg.raw(pw_key) or "").strip()
    if not name or not pw:
        ctx.skip(f"{label}：conf 未配置该用户（{name_key} / {pw_key} 为空）")
        return None
    return name, pw


def _setup_user(ctx: Ctx, label: str, kind: str, *, system: bool = False):
    """创建（必要时重建）测试用户并登记 ``ctx.cleanup`` 删除；返回 (name, password) 或 None。"""
    got = _user_conf(ctx, label, kind)
    if got is None:
        return None
    name, pw = got
    # 先登记删除：即使创建后任何一步抛异常，finally/cleanup 也会把用户删掉。
    ctx.cleanup.append(f"drop user {name}")
    out = ctx.api.create_user(name, pw)
    if not out.ok and "exist" in (out.output or "").lower():
        ctx.note(f"    用户 {name} 已存在（前序残留），先删除再重建以固定密码")
        ctx.api.drop_user(name)
        out = ctx.api.create_user(name, pw)
    if not out.ok:
        ctx.skip(f"{label}：无法创建用户 {name}（{_flat(out.output)}）")
        return None
    ctx.note(f"    已创建用户 {name}（kind={kind}）")
    if system:
        grant = ctx.api.grant_system(name)
        if not grant.ok:
            ctx.skip(f"{label}：无法授予 {name} SYSTEM 权限（{_flat(grant.output)}）")
            return None
        ctx.note(f"    已授予 {name} SYSTEM 权限")
    return name, pw


def _register_write(ctx: Ctx, out, db: str, device: str) -> None:
    """普通用户用原始 SQL 写入成功时补登记对拍查询（否则收尾②会误判"未写数据"）。"""
    if out.ok:
        ctx.note_data_written(db, device, "tree")


# ===================================================================== PG-SWCH
def case_swch01_auto_to_proactive(ctx: Ctx) -> None:
    """SWCH-01 AUTO（多 slot 只到 min）→ 切 PROACTIVE → **已有 slot 写新时间分区** 补到 min(K,R)。"""
    db = _solo_tree(ctx)
    min_num = _effective_min(ctx, "DATA")
    n_slots = min(group_ceiling(ctx, "DATA", _TREE, db), max(min_num + 2, 4))
    cap = _cap_or_skip(ctx, "SWCH-01", db, n_slots)
    if not cap:
        return
    if n_slots < min_num + 1:
        ctx.skip(f"SWCH-01：上限 R={cap} 不足以让 slot 数（{n_slots}）超过 minNum={min_num}"
                 f"（集群档位不匹配）")
        return
    interval = ctx.api.db_time_partition_interval(db, dialect=_TREE)
    if interval <= 0:
        ctx.skip("SWCH-01：读不到库 TimePartitionInterval，无法构造同 slot 的新时间分区")
        return
    if not _ensure_readable(ctx):
        return
    key, original = _POLICY_OF["DATA"], _conf_policy(ctx, "DATA")
    devices = device_set(ctx, db, n_slots)
    if pslots.distinct_slot_count(db, devices) != n_slots:
        ctx.skip(f"SWCH-01：harness 无法造出 {n_slots} 个互不相同 slot 的设备（档位不匹配）")
        return
    # ---- AUTO 阶段：逐 slot 写入，组数只逼近 minNum，不随 K 增长
    _set_knob(ctx, key, "AUTO", original, "SWCH-01")
    written: set = set()
    for i, device in enumerate(devices):
        _step(ctx, f"SWCH-01 AUTO 第 {i + 1}/{n_slots} 个 slot", db, "DATA", "AUTO",
              min_num, cap, written, device, _BASE_STAMP + i)
        written.add(_slot_of(ctx, db, device))
    g_auto = _groups(ctx, db, "DATA")
    ctx.check("SWCH-01：AUTO 收敛到 min(minNum,R)，不出现 PROACTIVE 式积极扩容",
              g_auto == min(min_num, cap) and g_auto < n_slots,
              f"minNum={min_num}、R={cap}、{n_slots} slot ⇒ AUTO 组数={g_auto}（期望 {min(min_num, cap)}）")
    # ---- 切回 PROACTIVE：只对**已有 slot** 写新时间分区（|P|=1、K 不变）⇒ 按公式补组
    _set_knob(ctx, key, "PROACTIVE", original, "SWCH-01")
    ctx.check("SWCH-01：切回 PROACTIVE 后已有组不回收", _groups(ctx, db, "DATA") == g_auto,
              f"切换前={g_auto}、切换后={_groups(ctx, db, 'DATA')}")
    k_same = len(written)                      # 已有 slot 写新时间分区：K 不变
    want = _want("PROACTIVE", min_num, cap, g_auto, 1, k_same)
    ensure_write_tree(ctx, db, devices[0], _BASE_STAMP + interval)
    got = _groups(ctx, db, "DATA")
    ctx.check(f"SWCH-01：已有 slot 写新时间分区（|P|=1、K={k_same} 不变）后 Data 组数应为 {want}"
              f"（{_want_str('PROACTIVE', min_num, cap, g_auto, 1, k_same)}）", got == want,
              f"实测={got}")
    ctx.check("SWCH-01：PROACTIVE 下该请求确实推动组数增长（K 项生效）", want > g_auto,
              f"切换前 {g_auto} → 公式期望 {want}、实测 {got}",
              evidence=json.dumps({"minNum": min_num, "R": cap, "K": k_same}, ensure_ascii=False))
    expect_groups(ctx, "SWCH-01 切回 PROACTIVE 后的最终态", db, _TREE, data=want)
    _restore_knob(ctx, key, original, "SWCH-01")


def case_swch02_proactive_to_auto(ctx: Ctx) -> None:
    """SWCH-02 PROACTIVE → AUTO：已有组保留不回收，且新 slot 不再积极扩容。"""
    _switch_reject_growth(ctx, "SWCH-02", "AUTO")


def case_swch03_proactive_to_custom(ctx: Ctx) -> None:
    """SWCH-03 PROACTIVE → CUSTOM：已有组保留，新 slot 由 CUSTOM（逼近 minNum）接管。"""
    _switch_reject_growth(ctx, "SWCH-03", "CUSTOM")


def _switch_reject_growth(ctx: Ctx, label: str, target: str) -> None:
    """PROACTIVE 基线（含 minNum）→ 切 target：保留已有组、新 slot 不积极扩容。"""
    db = _solo_tree(ctx)
    min_num = _effective_min(ctx, "DATA")
    baseline = max(3, min_num)                       # 保证 baseline ≥ minNum ⇒ AUTO/CUSTOM 到顶
    cap = _cap_or_skip(ctx, label, db, baseline + 2)
    if not cap:
        return
    if not _ensure_readable(ctx):
        return
    key, original = _POLICY_OF["DATA"], _conf_policy(ctx, "DATA")
    devices = device_set(ctx, db, baseline + 2)
    if pslots.distinct_slot_count(db, devices) != baseline + 2:
        ctx.skip(f"{label}：harness 无法造出 {baseline + 2} 个不同 slot 的设备")
        return
    _set_knob(ctx, key, "PROACTIVE", original, label)
    written: set = set()
    for i in range(baseline):
        _step(ctx, f"{label} PROACTIVE 基线 {i + 1}/{baseline}", db, "DATA", "PROACTIVE",
              min_num, cap, written, devices[i], _BASE_STAMP + i)
        written.add(_slot_of(ctx, db, devices[i]))
    before = _groups(ctx, db, "DATA")
    ctx.check(f"{label}：PROACTIVE 基线 {baseline} 个 slot 得 {min(baseline, cap)} 组",
              before == min(baseline, cap),
              f"实测={before}（minNum={min_num}、R={cap}）")
    # ---- 切换到 target
    _set_knob(ctx, key, target, original, label)
    after_switch = _groups(ctx, db, "DATA")
    ctx.check(f"{label}：切到 {target} 后已有 {before} 组保留不回收", after_switch == before,
              f"切换前={before}、切换后={after_switch}")
    # ---- 新 slot：AUTO 不参与 K 项（停在 G）；CUSTOM 则**一次补满 R**（H-27）
    for j in range(2):
        _step(ctx, f"{label} {target} 新 slot {j + 1}/2", db, "DATA", target,
              min_num, cap, written, devices[baseline + j], _BASE_STAMP + 100 + j)
        written.add(_slot_of(ctx, db, devices[baseline + j]))
    k_all = len(written)
    g_final = _groups(ctx, db, "DATA")
    tgt_want = _want(target, min_num, cap, before, 1, k_all)
    pro_want = _want("PROACTIVE", min_num, cap, before, 1, k_all)
    if target.upper() == "CUSTOM":
        # H-27：CUSTOM 的语义是"补满 maxRegionGroupNum"，不是"停在 minNum"。
        ctx.check(f"{label}：CUSTOM 下新 slot 请求补满 R={cap}（不停在 {before}）",
                  g_final == cap and tgt_want == cap,
                  f"实测={g_final}、CUSTOM 期望={tgt_want}、R={cap}；"
                  f"对照 PROACTIVE 同批 slot 只到 min(K,R)={pro_want}")
        ctx.check(f"{label}：策略差异自证 —— CUSTOM 补满 R={cap}，PROACTIVE 只到 min(K,R)={pro_want}",
                  tgt_want == cap and cap >= pro_want,
                  f"CUSTOM 期望={tgt_want}、PROACTIVE 期望={pro_want}")
    else:
        ctx.check(f"{label}：新 slot 在 {target} 下不再增长（停在 {before}）",
                  g_final == before and tgt_want == before,
                  f"实测={g_final}、公式={tgt_want}；对照 PROACTIVE 同批 slot 会扩到 {pro_want}")
        ctx.check(f"{label}：策略差异自证 —— PROACTIVE 会扩到 K={k_all}，{target} 不扩",
                  pro_want > tgt_want,
                  f"PROACTIVE 期望={pro_want}、{target} 期望={tgt_want}")
    expect_groups(ctx, f"{label} 切到 {target} 后的最终态", db, _TREE, data=g_final)
    _restore_knob(ctx, key, original, label)


def case_swch04_custom_to_proactive(ctx: Ctx) -> None:
    """SWCH-04 CUSTOM（一次补满 R）→ PROACTIVE：不回收、不超 R，新 slot 按 min(K,R)。"""
    db = _solo_tree(ctx)
    min_num = _effective_min(ctx, "DATA")
    cap = _cap_or_skip(ctx, "SWCH-04", db, 3)
    if not cap:
        return
    if not _ensure_readable(ctx):
        return
    ctx.check("SWCH-04：CUSTOM 配额来源 = default_data_region_group_num_per_database 生效值",
              _effective_min(ctx, "DATA") == _conf_min(ctx, "DATA"),
              f"生效值={_effective_min(ctx, 'DATA')}、conf={_conf_min(ctx, 'DATA')}")
    key, original = _POLICY_OF["DATA"], _conf_policy(ctx, "DATA")
    devices = device_set(ctx, db, 4)
    if pslots.distinct_slot_count(db, devices) != 4:
        ctx.skip("SWCH-04：harness 无法造出足够多的不同 slot 设备")
        return
    _set_knob(ctx, key, "CUSTOM", original, "SWCH-04")
    written: set = set()
    # H-27：CUSTOM 的语义是"补满 R"（customExtendRegionGroupIfNecessary），
    # 所以**第一个** slot 请求就会把组数补到 R；旧实现按"停在 minNum"建模，实测 60 判失败。
    _step(ctx, "SWCH-04 CUSTOM 首个 slot（一次补满 R）", db, "DATA", "CUSTOM",
          min_num, cap, written, devices[0], _BASE_STAMP)
    written.add(_slot_of(ctx, db, devices[0]))
    before = _groups(ctx, db, "DATA")
    ctx.check(f"SWCH-04：CUSTOM 下首个 slot 请求即补满 R={cap}（不是停在 minNum={min_num}）",
              before == cap, f"实测={before}、R={cap}、minNum={min_num}")
    # ---- 切 PROACTIVE：不回收；组数已到 R ⇒ 新 slot 只在 min(K,R) 内（= R，不超上限）
    _set_knob(ctx, key, "PROACTIVE", original, "SWCH-04")
    ctx.check("SWCH-04：切 PROACTIVE 后历史组不回收（需求 §3.2 保留历史组）",
              _groups(ctx, db, "DATA") == before,
              f"切换前={before}、切换后={_groups(ctx, db, 'DATA')}")
    # K 只数**真正写入过**的 slot（∪ 本次），不要为了凑数把未写的设备算进去。
    k_all = len(written) + 1
    want = _want("PROACTIVE", min_num, cap, before, 1, k_all)
    got = _step(ctx, "SWCH-04 切 PROACTIVE 后新 slot", db, "DATA", "PROACTIVE",
                min_num, cap, written, devices[3], _BASE_STAMP + 100)
    ctx.check(f"SWCH-04：PROACTIVE 下新 slot 组数 = min(K,R)={want}（已到 R 则保持 R，不回收不超）",
              got == want and want == max(before, min(cap, k_all)),
              f"实测={got}、公式={want}",
              evidence=json.dumps({"minNum": min_num, "R": cap, "K": k_all,
                                   "custom_filled": before}, ensure_ascii=False))
    expect_groups(ctx, "SWCH-04 切 PROACTIVE 后的最终态", db, _TREE, data=want)
    _restore_knob(ctx, key, original, "SWCH-04")


def _one_kind_switch(ctx: Ctx, label: str, switched_kind: str) -> None:
    """SWCH-05/06 公共体：只切 ``switched_kind``，另一类必须仍按**原策略**公式增长。"""
    db = _solo_tree(ctx)
    if not ctx.cfg.dn_hosts:
        ctx.skip(f"{label}：conf 未定义 DataNode（集群档位不匹配）")
        return
    other_kind = "SCHEMA" if switched_kind == "DATA" else "DATA"
    # H-19：组数建模用**产品自报上限**（单调存量），公式只作档位门槛。
    cap_of = {k: max(expected_cap(ctx, k, _TREE, db), group_ceiling(ctx, k, _TREE, db))
              for k in ("SCHEMA", "DATA")}
    min_of = {k: _effective_min(ctx, k) for k in ("SCHEMA", "DATA")}
    if min(cap_of.values()) < 1:
        ctx.skip(f"{label}：公式上限 {cap_of} 不足以写入（集群档位不匹配）")
        return
    if not _ensure_readable(ctx):
        return
    orig = {k: _conf_policy(ctx, k) for k in ("SCHEMA", "DATA")}
    target = _toggle(orig[switched_kind])
    ctx.check(f"{label}：切换目标值 {target} 是合法值且与原值 {orig[switched_kind]} 不同",
              target in _LEGAL and target != orig[switched_kind],
              f"orig={orig[switched_kind]}、target={target}")
    step_devices = device_set(ctx, db, 5)
    if pslots.distinct_slot_count(db, step_devices) < 5:
        ctx.skip(f"{label}：harness 只造出 {pslots.distinct_slot_count(db, step_devices)} 个不同 slot，"
                 f"不足 5 个（档位不匹配）")
        return
    written: set = set()
    # ---- 基线：两类都按**原策略**写入前 3 个 slot
    for i, device in enumerate(step_devices[:3]):
        # H-27：同一设备的第一条 insert 才创造 slot（|P|=1），第二条是"同 slot 补写"（|P|=0）。
        for j, kind in enumerate(("SCHEMA", "DATA")):
            _step(ctx, f"{label} 基线 {i + 1}/3（{kind}）", db, kind, orig[kind],
                  min_of[kind], cap_of[kind], written, device, _BASE_STAMP + i,
                  new_slot=(j == 0))
        written.add(_slot_of(ctx, db, device))
    before = {k: _groups(ctx, db, k) for k in ("SCHEMA", "DATA")}
    # ---- 只切一类
    key = _POLICY_OF[switched_kind]
    _set_knob(ctx, key, target, orig[switched_kind], label)
    after_switch = {k: _groups(ctx, db, k) for k in ("SCHEMA", "DATA")}
    ctx.check(f"{label}：切换 {switched_kind} 策略后两类已有组均不回收",
              after_switch == before, f"前={before}、后={after_switch}")
    # ---- 继续写新 slot：被切类按 target，另一类按原策略
    for j, device in enumerate(step_devices[3:5]):
        for m, kind in enumerate(("SCHEMA", "DATA")):
            policy = target if kind == switched_kind else orig[kind]
            _step(ctx, f"{label} 切换后新 slot {j + 1}（{kind}，策略 {policy}）", db, kind, policy,
                  min_of[kind], cap_of[kind], written, device, _BASE_STAMP + 200 + j,
                  new_slot=(m == 0))
        written.add(_slot_of(ctx, db, device))
    # ---- 显式断言"另一类未受影响"：其组数 == 原策略公式现算值
    k_all = len(written)
    for kind in ("SCHEMA", "DATA"):
        # H-27（只切一类）：被切的那一类必须用**切换后**的策略算期望值；
        # 旧实现两类都用 orig[kind]，于被切类仍套原策略公式（SWCH-05/06 交叉校验错）。
        policy = target if kind == switched_kind else orig[kind]
        want = _want(policy, min_of[kind], cap_of[kind], before[kind], 1, k_all)
        got = _groups(ctx, db, kind)
        ctx.check(f"{label}：{kind} 按策略 {policy} 的公式值 {want}"
                  + ("（本用例未切该类）" if kind != switched_kind
                     else f"（本用例只切了该类：{orig[kind]}→{target}）"),
                  got == want,
                  f"实测={got}、公式={_want_str(policy, min_of[kind], cap_of[kind], before[kind], 1, k_all)}")
    expect_groups(ctx, f"{label} 最终态", db, _TREE,
                  schema=_groups(ctx, db, "SCHEMA"), data=_groups(ctx, db, "DATA"))
    _restore_knob(ctx, key, orig[switched_kind], label)


def case_swch05_only_data_switch(ctx: Ctx) -> None:
    """SWCH-05 只切 data 策略：schema 组数不受影响，严格按原策略公式。"""
    _one_kind_switch(ctx, "SWCH-05", "DATA")


def case_swch06_only_schema_switch(ctx: Ctx) -> None:
    """SWCH-06 只切 schema 策略：data 组数不受影响，严格按原策略公式。"""
    _one_kind_switch(ctx, "SWCH-06", "SCHEMA")


def case_swch07_switch_creates_no_group(ctx: Ctx) -> None:
    """SWCH-07 切换动作本身不建组（需求 §3.1）：切换前后 SHOW DATABASES DETAILS 组数完全不变。"""
    db = _solo_tree(ctx)
    cap = _cap_or_skip(ctx, "SWCH-07", db, 2)
    if not cap:
        return
    if not _ensure_readable(ctx):
        return
    devices = device_set(ctx, db, 2)
    write_devices(ctx, db, devices, model="tree", stamp=_BASE_STAMP)
    before = group_counts(ctx, db, _TREE)
    ctx.check("SWCH-07：前置已建组（组数 > 0，切换前后对比才有意义）",
              before[0] > 0 and before[2] > 0, f"SHOW DATABASES DETAILS/区域去重={before}")
    for kind in ("DATA", "SCHEMA"):
        key, original = _POLICY_OF[kind], _conf_policy(ctx, kind)
        target = _toggle(original)
        _set_knob(ctx, key, target, original, f"SWCH-07 切 {kind}")
        after = group_counts(ctx, db, _TREE)
        ctx.check(f"SWCH-07：切 {kind} 策略（{original}→{target}）前后组数完全不变"
                  f"（切换不产生 RegionGroup）", after == before,
                  f"前={before}、后={after}",
                  evidence=json.dumps(ctx.api.database_details(_TREE).get(db, {}), ensure_ascii=False))
        _restore_knob(ctx, key, original, f"SWCH-07 切 {kind}")


def case_swch08_mapping_unchanged(ctx: Ctx) -> None:
    """SWCH-08 历史分区映射不变：切换前后同一批设备的 Data RegionGroup 逐一相同。"""
    db = _solo_tree(ctx)
    cap = _cap_or_skip(ctx, "SWCH-08", db, 4)
    if not cap:
        return
    if not _ensure_readable(ctx):
        return
    devices = device_set(ctx, db, 4)
    write_devices(ctx, db, devices, model="tree", stamp=_BASE_STAMP)
    # H-44：``show data regionid where device=…`` 只认完整设备路径，短名一律返回空集
    full = [d if d.startswith(db + ".") else f"{db}.{d}" for d in devices]
    before = ctx.api.device_groups(full, dialect=_TREE)
    if not all(before.values()):
        ctx.skip(f"SWCH-08：设备→RegionGroup 映射尚不可见（{before}），无法验证映射不变")
        return
    ctx.check("SWCH-08：前置 4 台设备的 Data RegionGroup 映射均已可见",
              len(before) == 4 and all(before.values()), f"映射={before}")
    for kind in ("DATA", "SCHEMA"):
        key, original = _POLICY_OF[kind], _conf_policy(ctx, kind)
        target = _toggle(original)
        _set_knob(ctx, key, target, original, f"SWCH-08 切 {kind}")
        after = ctx.api.device_groups(full, dialect=_TREE)
        same = {d: (before[d] == after.get(d)) for d in full}
        ctx.check(f"SWCH-08：切 {kind} 策略（{original}→{target}）后设备→RegionGroup 映射逐一相同",
                  after == before and all(same.values()),
                  f"前={before}、后={after}", evidence=json.dumps(same, ensure_ascii=False))
        _restore_knob(ctx, key, original, f"SWCH-08 切 {kind}")
    ctx.check("SWCH-08：切换并恢复后映射仍与最初一致",
              ctx.api.device_groups(full, dialect=_TREE) == before,
              f"最初={before}、结束={ctx.api.device_groups(full, dialect=_TREE)}")


def case_swch09_restart_reloads_conf(ctx: Ctx) -> None:
    """SWCH-09 切换 + 整集群重启：重启从 **conf 文件**重新加载，断言重启后 == ctx.cfg.raw(PG_DATA_POLICY)。

    说明：``SET CONFIGURATION`` 会把新值写进节点 conf 文件（``_set_knob`` 的读回自证即证明
    这一点），而 ``start_all`` 不重写 conf ⇒ 若把热加载值留在文件里，重启后生效的会是**热加载
    值**。本用例按父任务书的口径断言"重启后等于 conf 值 ``ctx.cfg.raw('PG_DATA_POLICY')``"，
    因此在重启前先把该键**显式恢复为 conf 值**，再重启验证"启动时按 conf 文件生效"（行为级
    自证：重启后新 slot 的组数按 conf 策略的公式增长）。
    """
    db = _solo_tree(ctx)
    min_num = _effective_min(ctx, "DATA")
    cap = _cap_or_skip(ctx, "SWCH-09", db, 3)
    if not cap:
        return
    if not ctx.cfg.cn_hosts:
        ctx.skip("SWCH-09：conf 未定义 ConfigNode（集群档位不匹配）")
        return
    if not _ensure_readable(ctx):
        return
    if not ctx.cluster.wait_healthy(timeout=ctx.cfg.get_int("CLUSTER_START_TIMEOUT_SEC")):
        ctx.skip("SWCH-09：重启前集群未回到 Running/ReadOnly（档位/环境不匹配）")
        return
    want = _conf_policy(ctx, "DATA")
    other = _toggle(want)
    key = _POLICY_OF["DATA"]
    devices = device_set(ctx, db, 3)
    written: set = set()
    _step(ctx, "SWCH-09 重启前写入（按 conf 策略）", db, "DATA", want,
          min_num, cap, written, devices[0], _BASE_STAMP)
    written.add(_slot_of(ctx, db, devices[0]))
    g_before = _groups(ctx, db, "DATA")
    # ---- 热加载成 other，落盘自证
    _set_knob(ctx, key, other, want, "SWCH-09")
    ctx.check("SWCH-09：热加载已写入节点 conf 文件（读回 = 热加载值）",
              _read_until(ctx, key, other) == other, f"读回={_read_prop(ctx, key)!r}")
    # ---- 重启前把键恢复为 conf 值（否则重启会重新加载热加载值，见 docstring）
    _restore_knob(ctx, key, want, "SWCH-09")
    timeout = ctx.cfg.get_int("CLUSTER_START_TIMEOUT_SEC")
    ctx.mark_harness_action("SWCH-09：整集群重启（stop_all）", pad=30)
    ctx.cluster.stop_all()
    ctx.mark_harness_action("SWCH-09：整集群重启（start_all）", pad=30)
    started = ctx.cluster.start_all()
    ctx.check("SWCH-09：start_all 拉起全部节点", bool(started), f"start_all={started}")
    healthy = ctx.cluster.wait_healthy(timeout=timeout)
    ctx.check("SWCH-09：重启后全节点回到 Running/ReadOnly", healthy, f"timeout={timeout}s")
    ctx._cluster_ready = time.time()
    if not (started and healthy):
        return
    # ---- 重启后：文件值与生效行为都必须等于 conf 值
    read = _read_until(ctx, key, want)
    ctx.check(f"SWCH-09：重启后配置文件值 = conf 值 {want}", read == want, f"读回={read!r}")
    ctx.check("SWCH-09：重启后已有组保留（策略切换+重启不回收）",
              _groups(ctx, db, "DATA") >= g_before,
              f"重启前={g_before}、重启后={_groups(ctx, db, 'DATA')}")
    k_all = len(written) + 1
    got = _step(ctx, "SWCH-09 重启后新 slot（按 conf 策略）", db, "DATA", want,
                min_num, cap, written, devices[1], _BASE_STAMP + 300)
    ctx.check(f"SWCH-09：重启后生效策略 == conf 值 {want}（行为级自证）",
              got == _want(want, min_num, cap, g_before, 1, k_all),
              f"实测={got}、conf 策略公式={_want_str(want, min_num, cap, g_before, 1, k_all)}；"
              f"ctx.cfg.raw('PG_DATA_POLICY')={ctx.cfg.raw('PG_DATA_POLICY')!r}")
    _restore_knob(ctx, key, want, "SWCH-09")


def case_swch10_illegal_value(ctx: Ctx) -> None:
    """SWCH-10 非法策略值被拒：set_config.ok is False、文件未变、行为仍按原策略。"""
    db = _solo_tree(ctx)
    cap = _cap_or_skip(ctx, "SWCH-10", db, 2)
    if not cap:
        return
    if not _ensure_readable(ctx):
        return
    key, original = _POLICY_OF["DATA"], _conf_policy(ctx, "DATA")
    _push_restore(ctx, key, original)                 # 万一非法值意外生效，cleanup 也会还原
    before = _read_map(ctx, key)
    illegal = "AUTO2"
    ctx.mark_harness_action(f"SWCH-10：故意提交非法策略值 {key}={illegal}（预期被拒）", pad=15)
    out = ctx.api.set_config(key, illegal)
    ctx.check(f"SWCH-10：非法值 {illegal} 必须被拒绝（ok is False）", not out.ok,
              f"ok={out.ok}；语句={_flat(out.statement)}；output={_flat(out.output)}",
              evidence=out.output[:4000])
    after = _read_map(ctx, key)
    ctx.check(f"SWCH-10：被拒后 {key} 在所有 CN 的配置文件值均未变", after == before,
              f"前={before}、后={after}", evidence=json.dumps(after, ensure_ascii=False))
    # 行为未变：新 slot 仍按**原策略**公式增长
    min_num = _effective_min(ctx, "DATA")
    devices = device_set(ctx, db, 2)
    written: set = set()
    for i, device in enumerate(devices):
        _step(ctx, f"SWCH-10 被拒后写入 {i + 1}/2（原策略 {original}）", db, "DATA", original,
              min_num, cap, written, device, _BASE_STAMP + i)
        written.add(_slot_of(ctx, db, device))


def case_swch11_new_measurements_same_slot(ctx: Ctx) -> None:
    """SWCH-11 AUTO 下仅新增测点（同 slot、K 不变）不新建 RegionGroup：Schema/Data 组数均不变。"""
    db = _solo_tree(ctx)
    if not ctx.cfg.dn_hosts:
        ctx.skip("SWCH-11：conf 未定义 DataNode（集群档位不匹配）")
        return
    # H-19：组数建模用自报上限（单调存量）。
    cap_of = {k: max(expected_cap(ctx, k, _TREE, db), group_ceiling(ctx, k, _TREE, db))
              for k in ("SCHEMA", "DATA")}
    min_of = {k: _effective_min(ctx, k) for k in ("SCHEMA", "DATA")}
    # H-27（断言错类）：本用例只把 **DATA** 策略切到 AUTO；SCHEMA 仍是 conf 口径
    # （PROACTIVE ⇒ 会按 K 扩张到 min(K,R)），旧实现两类都套 AUTO 公式，于是在
    # SCHEMA 侧拿 minNum 当期望（实测 5 vs 期望 1）。
    orig = {k: _conf_policy(ctx, k) for k in ("SCHEMA", "DATA")}
    policy_of = {"DATA": "AUTO", "SCHEMA": orig["SCHEMA"]}
    # 让 DATA 到 AUTO 目标 min(minNum,R)、SCHEMA 到 min(K,R)（= slot 数，需 ≤ R）
    n_slots = max(1, min(min_of["DATA"], cap_of["DATA"]))
    if cap_of["DATA"] < n_slots or cap_of["SCHEMA"] < n_slots:
        ctx.skip(f"SWCH-11：上限 {cap_of} 不足以让两类都到目标 {n_slots}（集群档位不匹配）")
        return
    if not _ensure_readable(ctx):
        return
    key, original = _POLICY_OF["DATA"], _conf_policy(ctx, "DATA")
    devices = device_set(ctx, db, n_slots)
    if pslots.distinct_slot_count(db, devices) != n_slots:
        ctx.skip(f"SWCH-11：harness 无法造出 {n_slots} 个不同 slot 的设备")
        return
    _set_knob(ctx, key, "AUTO", original, "SWCH-11")
    written: set = set()
    for i, device in enumerate(devices):
        # H-27：同一设备只有第一条 insert 新增 slot（|P|=1），第二条是补写（|P|=0）。
        for j, kind in enumerate(("SCHEMA", "DATA")):
            _step(ctx, f"SWCH-11 AUTO 建立 slot {i + 1}/{n_slots}（{kind}，策略 {policy_of[kind]}）",
                  db, kind, policy_of[kind], min_of[kind], cap_of[kind], written, device,
                  _BASE_STAMP + i, new_slot=(j == 0))
        written.add(_slot_of(ctx, db, device))
    before = {k: _groups(ctx, db, k) for k in ("SCHEMA", "DATA")}
    target_of = {k: min(cap_of[k], n_slots if policy_of[k].upper() == "PROACTIVE"
                        else min_of[k]) for k in ("SCHEMA", "DATA")}
    ctx.check("SWCH-11：前置两类组数均已到各自策略目标（DATA=AUTO min(minNum,R)；"
              "SCHEMA=按原策略）", before == target_of,
              f"实测={before}、目标={target_of}、策略={policy_of}、minNum={min_of}、R={cap_of}")
    # 同一设备补写新测点（同 slot、不新增 slot ⇒ K 不变、|P|=0）
    d0 = devices[0]
    k_same = len(written)
    want = {k: _want(policy_of[k], min_of[k], cap_of[k], before[k], 0, k_same)
            for k in ("SCHEMA", "DATA")}
    ensure_write_tree(ctx, db, d0, _BASE_STAMP + 500, sensors=("s0", "s1", "s2"))
    after = {k: _groups(ctx, db, k) for k in ("SCHEMA", "DATA")}
    for kind in ("SCHEMA", "DATA"):
        ctx.check(f"SWCH-11：同 slot 仅新增测点后 {kind} 组数应不变（K={k_same}、|P|=0）",
                  after[kind] == before[kind] == want[kind],
                  f"前={before[kind]}、后={after[kind]}、公式={want[kind]}"
                  f"（策略={policy_of[kind]}；"
                  f"{_want_str(policy_of[kind], min_of[kind], cap_of[kind], before[kind], 0, k_same)}）")
    ctx.check("SWCH-11：Schema 与 Data 组数都不因新增测点增长",
              after == before, f"前={before}、后={after}")
    _restore_knob(ctx, key, original, "SWCH-11")


def case_swch12_new_slots_follow_new_policy(ctx: Ctx) -> None:
    """SWCH-12 切换后新增 slot 按新策略：PROACTIVE→AUTO 不增；再切回 PROACTIVE 增到公式值。"""
    db = _solo_tree(ctx)
    min_num = _effective_min(ctx, "DATA")
    base = max(min_num, 2)
    cap = _cap_or_skip(ctx, "SWCH-12", db, base + 3)
    if not cap:
        return
    if not _ensure_readable(ctx):
        return
    key, original = _POLICY_OF["DATA"], _conf_policy(ctx, "DATA")
    devices = device_set(ctx, db, base + 3)
    if pslots.distinct_slot_count(db, devices) != base + 3:
        ctx.skip("SWCH-12：harness 无法造出足够多的不同 slot 设备")
        return
    _set_knob(ctx, key, "PROACTIVE", original, "SWCH-12")
    written: set = set()
    for i in range(base):
        _step(ctx, f"SWCH-12 PROACTIVE 基线 {i + 1}/{base}", db, "DATA", "PROACTIVE",
              min_num, cap, written, devices[i], _BASE_STAMP + i)
        written.add(_slot_of(ctx, db, devices[i]))
    g_pro = _groups(ctx, db, "DATA")
    # ---- 切 AUTO：两个新 slot 不增长
    _set_knob(ctx, key, "AUTO", original, "SWCH-12")
    for j in range(2):
        _step(ctx, f"SWCH-12 AUTO 新 slot {j + 1}/2", db, "DATA", "AUTO",
              min_num, cap, written, devices[base + j], _BASE_STAMP + 400 + j)
        written.add(_slot_of(ctx, db, devices[base + j]))
    g_auto = _groups(ctx, db, "DATA")
    ctx.check(f"SWCH-12：切 AUTO 后两个新 slot 不增长（保持 {g_pro}）", g_auto == g_pro,
              f"PROACTIVE 后={g_pro}、AUTO 新 slot 后={g_auto}")
    # ---- 再切回 PROACTIVE：下一个新 slot 增到公式值 min(K,R)
    _set_knob(ctx, key, "PROACTIVE", original, "SWCH-12")
    k_all = len(written) + 1
    want = _want("PROACTIVE", min_num, cap, g_auto, 1, k_all)
    got = _step(ctx, "SWCH-12 切回 PROACTIVE 后新 slot", db, "DATA", "PROACTIVE",
                min_num, cap, written, devices[base + 2], _BASE_STAMP + 500)
    ctx.check(f"SWCH-12：切回 PROACTIVE 后新 slot 增到公式值 {want}（K={k_all}）且严格大于 AUTO 态 {g_auto}",
              got == want and want > g_auto,
              f"实测={got}、公式={_want_str('PROACTIVE', min_num, cap, g_auto, 1, k_all)}")
    ctx.check("SWCH-12：切换不回收（AUTO 阶段组数 ≥ PROACTIVE 基线）", g_auto >= g_pro,
              f"基线={g_pro}、AUTO 后={g_auto}")
    expect_groups(ctx, "SWCH-12 最终态", db, _TREE, data=got)
    _restore_knob(ctx, key, original, "SWCH-12")


# ====================================================================== PG-PRV
def case_prv01_normal_user_hot_reload_denied(ctx: Ctx) -> None:
    """PRV-01 普通用户（无 SYSTEM）热加载策略被拒（not .ok），且配置未变（props 读回）。"""
    db = _solo_tree(ctx)
    got = _setup_user(ctx, "PRV-01", "normal")
    if got is None:
        return
    name, pw = got
    if not _ensure_readable(ctx):
        return
    key, original = _POLICY_OF["DATA"], _conf_policy(ctx, "DATA")
    _push_restore(ctx, key, original)
    before = _read_map(ctx, key)
    target = _toggle(original)
    ctx.mark_harness_action(f"PRV-01：普通用户 {name} 尝试热加载 {key}={target}（预期被拒）", pad=15)
    out = ctx.api.set_config(key, target, user=name, password=pw)
    ctx.check(f"PRV-01：普通用户 {name} 热加载策略必须被拒（需求 §3.2 需 SYSTEM）", not out.ok,
              f"ok={out.ok}；语句={_flat(out.statement)}；output={_flat(out.output)}",
              evidence=out.output[:4000])
    after = _read_map(ctx, key)
    ctx.check(f"PRV-01：被拒后 {key} 在所有 CN 的配置文件值均未变", after == before,
              f"前={before}、后={after}", evidence=json.dumps(after, ensure_ascii=False))
    if out.ok:                                        # 意外成功也必须还原，避免污染后续用例
        _restore_knob(ctx, key, original, "PRV-01 异常成功回滚")
    ctx.check("PRV-01：测试库仍存在（被拒动作未破坏 fixture）",
              ctx.api.db_group_num(db, "DATA", dialect=_TREE) >= 0, f"库={db}")


def case_prv02_system_user_hot_reload_ok(ctx: Ctx) -> None:
    """PRV-02 授 SYSTEM 的用户执行同样的热加载成功，读回自证；结束恢复 conf 原值。"""
    db = _solo_tree(ctx)
    got = _setup_user(ctx, "PRV-02", "system", system=True)
    if got is None:
        return
    name, pw = got
    if not _ensure_readable(ctx):
        return
    key, original = _POLICY_OF["DATA"], _conf_policy(ctx, "DATA")
    _push_restore(ctx, key, original)
    target = _toggle(original)
    ctx.mark_harness_action(f"PRV-02：SYSTEM 用户 {name} 热加载 {key}={target}（预期成功）", pad=20)
    out = ctx.api.set_config(key, target, user=name, password=pw)
    ctx.check(f"PRV-02：SYSTEM 用户 {name} 热加载策略必须成功", out.ok,
              f"ok={out.ok}；output={_flat(out.output)}", evidence=out.output[:4000])
    read = _read_until(ctx, key, target)
    ctx.check(f"PRV-02：配置文件读回应为 {target}（权限+生效自证）", read == target,
              f"读回={read!r}")
    ctx.check(f"PRV-02：测试库仍存在（权限用例不得破坏 fixture）",
              ctx.api.db_group_num(db, "DATA", dialect=_TREE) >= 0, f"库={db}")
    _restore_knob(ctx, key, original, "PRV-02")
    ctx.check("PRV-02：恢复后文件值回到 conf 原值", _read_prop(ctx, key) == original,
              f"读回={_read_prop(ctx, key)!r}、conf={original!r}")


def case_prv03_normal_user_create_db(ctx: Ctx) -> None:
    """PRV-03 普通用户建库/写入：明确二选一 —— 被拒（结论 A）或产品允许（结论 B，事实记录）。

    无论哪种结论，都断言"建库与写入的结果一致"：建库被拒 ⇒ 写入也必须被拒；
    建库成功（产品允许普通用户建库）⇒ 对自己新建的库写入也必须成功并可被 root 查到。
    """
    _solo_tree(ctx)
    got = _setup_user(ctx, "PRV-03", "normal")
    if got is None:
        return
    name, pw = got
    other = "root.prv03"
    ctx.cleanup.append(f"drop database {other}")
    insert_sql = f"insert into {other}.d0(timestamp, s0) values(1, 1.0)"
    ctx.mark_harness_action(
        f"PRV-03：普通用户 {name} 尝试建库 {other} 并写入（预期被拒；若产品允许则如实记录）", pad=15)
    out_create = ctx.api.run(f"create database {other}", user=name, password=pw)
    out_write = ctx.api.run(insert_sql, dialect=_TREE, user=name, password=pw)
    denied = not out_create.ok
    ctx.check("PRV-03：建库与写入结论一致（被拒⇒都拒；允许⇒都成）",
              (denied and not out_write.ok) or (not denied and out_write.ok),
              f"建库={'被拒' if denied else '成功'}、写入={'被拒' if not out_write.ok else '成功'}；"
              f"建库原文={_flat(out_create.output)}；写入原文={_flat(out_write.output)}",
              evidence=json.dumps({"create": out_create.output[:1500],
                                   "write": out_write.output[:1500]}, ensure_ascii=False))
    if denied:
        ctx.check("PRV-03 结论 A：普通用户建库被拒，且拒绝信息非空（权限/语法类明确报错）",
                  bool(out_create.output.strip()), f"output={_flat(out_create.output)}")
        ctx.note("    PRV-03 明确结论 A：产品**不允许**普通用户建库（建库与写入均被拒）。")
    else:
        ctx.check("PRV-03 结论 B：产品允许普通用户建库，则写入也必须成功（事实记录，不判缺陷）",
                  out_write.ok, f"write output={_flat(out_write.output)}")
        _register_write(ctx, out_write, other, "d0")
        ctx.check("PRV-03 结论 B：普通用户写入的数据可被 root 查到（count=1）",
                  ctx.api.count_rows(f"{other}.d0", dialect=_TREE) == 1,
                  f"count={ctx.api.count_rows(f'{other}.d0', dialect=_TREE)}")
        ctx.note("    PRV-03 明确结论 B：产品**允许**普通用户建库并写入自己新建的库（事实记录）。")


def case_prv04_normal_user_granted_rw(ctx: Ctx) -> None:
    """PRV-04 普通用户对**已授权**库读写正常；对未授权库写入被拒（对照）。"""
    db = _solo_tree(ctx)
    got = _setup_user(ctx, "PRV-04", "normal")
    if got is None:
        return
    name, pw = got
    other = "root.prv04x"
    ctx.cleanup.append(f"drop database {other}")
    ctx.mark_harness_action(f"PRV-04：root 给 {name} 授权 write on {db}.**", pad=15)
    grant = ctx.api.grant_write(db, name, dialect=_TREE)
    ctx.check(f"PRV-04：授权语句必须成功（grant write on {db}.** to user {name}）", grant.ok,
              f"ok={grant.ok}；output={_flat(grant.output)}", evidence=grant.output[:2000])
    granted_sql = f"insert into {db}.prv04d(timestamp, s0) values(1, 1.0)"
    out_ok = ctx.api.run(granted_sql, dialect=_TREE, user=name, password=pw)
    ctx.check(f"PRV-04：普通用户在已授权库 {db} 写入必须成功", out_ok.ok,
              f"ok={out_ok.ok}；output={_flat(out_ok.output)}", evidence=out_ok.output[:2000])
    _register_write(ctx, out_ok, db, "prv04d")
    if out_ok.ok:
        ctx.check("PRV-04：已授权库写入的数据可被 root 查到（count=1）",
                  ctx.api.count_rows(f"{db}.prv04d", dialect=_TREE) == 1,
                  f"count={ctx.api.count_rows(f'{db}.prv04d', dialect=_TREE)}")
    # 对照：未授权的库
    ctx.req(ctx.api.create_database(other), f"create database {other}（root，用于未授权对照）")
    denied_sql = f"insert into {other}.d0(timestamp, s0) values(1, 1.0)"
    out_deny = ctx.api.run(denied_sql, dialect=_TREE, user=name, password=pw)
    ctx.check(f"PRV-04：普通用户对未授权库 {other} 写入必须被拒（授权边界对照）", not out_deny.ok,
              f"ok={out_deny.ok}；output={_flat(out_deny.output)}", evidence=out_deny.output[:2000])


def case_prv05_denied_action_keeps_state(ctx: Ctx) -> None:
    """PRV-05 权限拒绝后配置与组数均未变（越权失败是无副作用的）。"""
    db = _solo_tree(ctx)
    cap = _cap_or_skip(ctx, "PRV-05", db, 2)
    if not cap:
        return
    got = _setup_user(ctx, "PRV-05", "normal")
    if got is None:
        return
    name, pw = got
    if not _ensure_readable(ctx):
        return
    devices = device_set(ctx, db, 2)
    write_devices(ctx, db, devices, model="tree", stamp=_BASE_STAMP)
    counts_before = group_counts(ctx, db, _TREE)
    key, original = _POLICY_OF["DATA"], _conf_policy(ctx, "DATA")
    _push_restore(ctx, key, original)
    cfg_before = _read_map(ctx, key)
    target = _toggle(original)
    ctx.mark_harness_action(f"PRV-05：普通用户 {name} 越权热加载 {key}={target}（预期被拒）", pad=15)
    out = ctx.api.set_config(key, target, user=name, password=pw)
    ctx.check("PRV-05：越权热加载必须被拒", not out.ok,
              f"ok={out.ok}；output={_flat(out.output)}", evidence=out.output[:2000])
    cfg_after = _read_map(ctx, key)
    ctx.check(f"PRV-05：被拒后 {key} 配置未变", cfg_after == cfg_before,
              f"前={cfg_before}、后={cfg_after}")
    counts_after = group_counts(ctx, db, _TREE)
    ctx.check("PRV-05：被拒后库组数（SHOW DATABASES DETAILS 双口径）未变",
              counts_after == counts_before, f"前={counts_before}、后={counts_after}")


def case_prv06_revoke_system_then_denied(ctx: Ctx) -> None:
    """PRV-06 撤销 SYSTEM 后热加载被拒（grant → 生效 → revoke → 被拒 的闭环）。"""
    db = _solo_tree(ctx)
    got = _setup_user(ctx, "PRV-06", "system", system=True)
    if got is None:
        return
    name, pw = got
    if not _ensure_readable(ctx):
        return
    key, original = _POLICY_OF["DATA"], _conf_policy(ctx, "DATA")
    _push_restore(ctx, key, original)
    target = _toggle(original)
    # ① 授权期内：热加载成功（证明 SYSTEM 确实生效）
    ctx.mark_harness_action(f"PRV-06：{name}（已授 SYSTEM）热加载 {key}={target}（预期成功）", pad=20)
    out_granted = ctx.api.set_config(key, target, user=name, password=pw)
    ctx.check("PRV-06：授权期内热加载必须成功（闭环第一步）", out_granted.ok,
              f"ok={out_granted.ok}；output={_flat(out_granted.output)}", evidence=out_granted.output[:2000])
    _restore_knob(ctx, key, original, "PRV-06 授权期内回滚")
    # ② 撤销 SYSTEM
    ctx.mark_harness_action(f"PRV-06：撤销 {name} 的 SYSTEM 权限（revoke system）", pad=15)
    revoke = ctx.api.revoke_system(name)
    ctx.check(f"PRV-06：revoke system from user {name} 必须成功", revoke.ok,
              f"ok={revoke.ok}；output={_flat(revoke.output)}", evidence=revoke.output[:2000])
    before = _read_map(ctx, key)
    # ③ 撤销后再热加载：必须被拒且文件未变
    ctx.mark_harness_action(f"PRV-06：{name}（已撤销 SYSTEM）再次热加载 {key}={target}（预期被拒）", pad=15)
    out_denied = ctx.api.set_config(key, target, user=name, password=pw)
    ctx.check("PRV-06：撤销 SYSTEM 后热加载必须被拒（闭环第三步）", not out_denied.ok,
              f"ok={out_denied.ok}；output={_flat(out_denied.output)}", evidence=out_denied.output[:2000])
    after = _read_map(ctx, key)
    ctx.check(f"PRV-06：被拒后 {key} 配置文件值未变", after == before,
              f"前={before}、后={after}")
    if out_denied.ok:
        _restore_knob(ctx, key, original, "PRV-06 异常成功回滚")


def case_prv07_normal_user_observability(ctx: Ctx) -> None:
    """PRV-07 组数与上限对普通用户是否可观测：明确断言"可见（A）"或"不可见且为权限拒绝（B）"。"""
    db = _solo_tree(ctx)
    cap = _cap_or_skip(ctx, "PRV-07", db, 2)
    if not cap:
        return
    got = _setup_user(ctx, "PRV-07", "normal")
    if got is None:
        return
    name, pw = got
    devices = device_set(ctx, db, 2)
    write_devices(ctx, db, devices, model="tree", stamp=_BASE_STAMP)
    counts = group_counts(ctx, db, _TREE)
    ctx.check("PRV-07：前置库已建组（可见性判定才有意义）", counts[2] > 0, f"组数双口径={counts}")
    # H-28：结论 A 的前置是**先授权**。未授任何权限的普通用户看不到 root.pg 是产品**正确**
    # 行为（实测输出里自然没有该库），旧实现把它当成"结论 A 不成立"而判失败。
    ctx.mark_harness_action(f"PRV-07：授予 {name} 测试库读权限（可见性判定的前置）", pad=15)
    grant = ctx.api.grant_write(db, name, dialect=_TREE)
    ctx.check(f"PRV-07 前置：grant write on {db}.** to user {name} 成功", grant.ok,
              f"ok={grant.ok}；output={_flat(grant.output)}")
    out = ctx.api.run("show databases details", dialect=_TREE, user=name, password=pw)
    if out.ok:
        ctx.check(f"PRV-07 结论 A：普通用户**可见** SHOW DATABASES DETAILS，且输出包含测试库 {db}"
                  f"（组数/上限对普通用户可观测）", db in out.output,
                  f"输出片段={_flat(out.output, 400)}", evidence=out.output[:3000])
        ctx.note("    PRV-07 明确结论 A：SHOW DATABASES DETAILS 对普通用户**可见**。")
    else:
        low = (out.output or "").lower()
        denied_marker = any(w in low for w in ("privilege", "permission", "not authorized",
                                               "unauthorized", "forbidden", "no permission"))
        ctx.check("PRV-07 结论 B：普通用户**不可见** SHOW DATABASES DETAILS（组数/上限不可观测），"
                  "且拒绝信息是权限类错误（非语法/内部错误）", denied_marker,
                  f"output={_flat(out.output, 400)}", evidence=out.output[:3000])
        ctx.note("    PRV-07 明确结论 B：SHOW DATABASES DETAILS 对普通用户**不可见**（权限拒绝）。")


def case_prv08_normal_user_show_regions(ctx: Ctx) -> None:
    """PRV-08 SHOW REGIONS 类观测对普通用户是否可见：明确断言"可见（A）"或"不可见且为权限拒绝（B）"。"""
    db = _solo_tree(ctx)
    cap = _cap_or_skip(ctx, "PRV-08", db, 2)
    if not cap:
        return
    got = _setup_user(ctx, "PRV-08", "normal")
    if got is None:
        return
    name, pw = got
    devices = device_set(ctx, db, 2)
    write_devices(ctx, db, devices, model="tree", stamp=_BASE_STAMP)
    root_view = ctx.api.show_regions(db, kind="DATA", dialect=_TREE)
    ctx.check("PRV-08：前置 root 可见该库 DATA REGIONS（对照基线）", root_view.ok and bool(root_view.rows),
              f"ok={root_view.ok}；rows={len(root_view.rows)}")
    out = ctx.api.run(f"show data regions of database {db}", dialect=_TREE, user=name, password=pw)
    if out.ok:
        ctx.check("PRV-08 结论 A：普通用户**可见** SHOW DATA REGIONS OF DATABASE（区域观测可读），"
                  "且至少返回一行区域记录", bool(out.rows),
                  f"rows={len(out.rows)}；输出片段={_flat(out.output, 300)}", evidence=out.output[:3000])
        ctx.note("    PRV-08 明确结论 A：SHOW DATA REGIONS 对普通用户**可见**。")
    else:
        low = (out.output or "").lower()
        denied_marker = any(w in low for w in ("privilege", "permission", "not authorized",
                                               "unauthorized", "forbidden", "no permission"))
        ctx.check("PRV-08 结论 B：普通用户**不可见** SHOW DATA REGIONS（区域观测不可读），"
                  "且拒绝信息是权限类错误（非语法/内部错误）", denied_marker,
                  f"output={_flat(out.output, 400)}", evidence=out.output[:3000])
        ctx.note("    PRV-08 明确结论 B：SHOW DATA REGIONS 对普通用户**不可见**（权限拒绝）。")


# ===================================================================== registry
SPECS.append(CaseSpec(
    "PG-SWCH-01", "策略切换", "tree",
    "AUTO（N slot 只到 min）→ 切 PROACTIVE → 已有 slot 写新时间分区按公式补到 min(K,R)",
    "P0", case_swch01_auto_to_proactive))
SPECS.append(CaseSpec(
    "PG-SWCH-02", "策略切换", "tree",
    "PROACTIVE → AUTO：已有组保留不回收，新 slot 不再积极扩容",
    "P0", case_swch02_proactive_to_auto))
SPECS.append(CaseSpec(
    "PG-SWCH-03", "策略切换", "tree",
    "PROACTIVE → CUSTOM：已有组保留，新 slot 由 CUSTOM（逼近 minNum）接管",
    "P0", case_swch03_proactive_to_custom))
SPECS.append(CaseSpec(
    "PG-SWCH-04", "策略切换", "tree",
    "CUSTOM（配额=minNum）→ PROACTIVE：不回收，新 slot 恢复积极扩容到 min(K,R)",
    "P0", case_swch04_custom_to_proactive))
SPECS.append(CaseSpec(
    "PG-SWCH-05", "策略切换", "tree",
    "只切 data 策略：schema 组数不受影响，严格按原策略公式增长",
    "P0", case_swch05_only_data_switch))
SPECS.append(CaseSpec(
    "PG-SWCH-06", "策略切换", "tree",
    "只切 schema 策略：data 组数不受影响，严格按原策略公式增长",
    "P0", case_swch06_only_schema_switch))
SPECS.append(CaseSpec(
    "PG-SWCH-07", "策略切换", "tree",
    "切换动作本身不建组：切换前后 SHOW DATABASES DETAILS 组数完全不变（需求 §3.1）",
    "P0", case_swch07_switch_creates_no_group))
SPECS.append(CaseSpec(
    "PG-SWCH-08", "策略切换", "tree",
    "历史映射不变：切换前后设备→Data RegionGroup 逐一相同",
    "P0", case_swch08_mapping_unchanged))
SPECS.append(CaseSpec(
    "PG-SWCH-09", "策略切换", "tree",
    "切换 + 整集群重启：重启按 conf 文件生效，断言重启后 == ctx.cfg.raw(PG_DATA_POLICY)",
    "P0", case_swch09_restart_reloads_conf, needs_restart=True))
SPECS.append(CaseSpec(
    "PG-SWCH-10", "策略切换", "tree",
    "非法值切换被拒（ok is False）、文件未变，且行为仍按原策略",
    "P0", case_swch10_illegal_value))
SPECS.append(CaseSpec(
    "PG-SWCH-11", "策略切换", "tree",
    "AUTO 下仅新增测点（同 slot、K 不变）不建组：Schema/Data 组数均不变",
    "P0", case_swch11_new_measurements_same_slot))
SPECS.append(CaseSpec(
    "PG-SWCH-12", "策略切换", "tree",
    "切换后新增 slot 按新策略：PROACTIVE→AUTO 不增；再切回 PROACTIVE 增到公式值",
    "P0", case_swch12_new_slots_follow_new_policy))

SPECS.append(CaseSpec(
    "PG-PRV-01", "权限", "tree",
    "普通用户热加载策略被拒（not .ok）且配置未变（props 读回）",
    "P0", case_prv01_normal_user_hot_reload_denied))
SPECS.append(CaseSpec(
    "PG-PRV-02", "权限", "tree",
    "授 SYSTEM 的用户热加载成功并读回自证，结束恢复 conf 原值",
    "P0", case_prv02_system_user_hot_reload_ok))
SPECS.append(CaseSpec(
    "PG-PRV-03", "权限", "tree",
    "普通用户建库/写入：明确二选一结论（被拒 A / 产品允许 B 的事实记录）",
    "P1", case_prv03_normal_user_create_db))
SPECS.append(CaseSpec(
    "PG-PRV-04", "权限", "tree",
    "普通用户对已授权库写入成功，对未授权库写入被拒（授权边界对照）",
    "P0", case_prv04_normal_user_granted_rw))
SPECS.append(CaseSpec(
    "PG-PRV-05", "权限", "tree",
    "权限拒绝后配置与组数（双口径）均未变",
    "P0", case_prv05_denied_action_keeps_state))
SPECS.append(CaseSpec(
    "PG-PRV-06", "权限", "tree",
    "撤销 SYSTEM 后热加载被拒（grant 生效 → revoke → 被拒 闭环）",
    "P0", case_prv06_revoke_system_then_denied))
SPECS.append(CaseSpec(
    "PG-PRV-07", "权限", "tree",
    "组数与上限对普通用户是否可观测：明确断言可见（A）或不可见且为权限拒绝（B）",
    "P1", case_prv07_normal_user_observability))
SPECS.append(CaseSpec(
    "PG-PRV-08", "权限", "tree",
    "SHOW REGIONS 类观测对普通用户是否可见：明确断言可见（A）或不可见且为权限拒绝（B）",
    "P1", case_prv08_normal_user_show_regions))
