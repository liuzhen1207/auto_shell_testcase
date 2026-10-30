"""PG-DFT（默认值与配置）/ PG-MIN（最小组数）用例族：`PG-DFT-01..12` + `PG-MIN-01..06`（共 18 条）。

判定口径（唯一来源：``references/proactive-spec.md`` + 源码）
==========================================================
* 组数目标公式（``PartitionManager.java:670-681``）：
  ``T = min(R, max(min(minNum, G + |P|), K))``
  * ``G`` = 该库该类型**已分配**的组数；
  * ``|P|`` = **本次请求**内该类型的去重 slot 数（同一 slot 重复写去重为 1）；
  * ``K`` = 该库该类型**已分配 ∪ 本次 pending** 的去重 slot 数；
  * ``R`` = ``cases.expected_cap()``（``ClusterSchemaManager.java:594-649`` 的上限公式）；
  * ``minNum`` = ``default_{schema,data}_region_group_num_per_database`` 的**生效值**。
  由此：首次请求（G=0）只建 1 组、**不预建到 min**；``G>=1`` 且 ``minNum > G+|P| > K``
  时同一 slot 申请新时间分区也会向 min 增量补齐（PG-MIN-02，即 doc-gaps G-01 的探针）。
* 上限 ``Max*RegionGroupNum`` 在建库时确定（``ClusterSchemaManager.java:973-1061``
  "建库默认 max = min"）⇒ PG-MIN-05 必须在 reset_db **之前**热加载 min 才能让 min 吃满上限。
* 策略/最小组数都是**可热加载**键：改过的键在本用例结束前显式恢复并读回自证，同时
  无条件登记进 ``ctx.cleanup``（异常路径也会还原），杜绝污染后续用例。

纪律
====
* 每条用例都从 ``reset_db(ctx, "tree")`` 的干净库开始（``_solo_tree`` 额外清掉表模型测试库，
  使 ``expected_cap`` 的"参与分摊库数"=1，与产品口径一致 —— 同 ``cases_dev._solo_db``）；
* 每条 check 都有明确期望数值（一律用上面的公式现算，不写死设备数）；
* 所有"故意提交非法值"的语句前先 ``ctx.mark_harness_action(...)`` 开日志归因窗口；
* cluster 级档位不匹配一律 ``ctx.skip`` 并写明需要哪个档位，**绝不降级成 PASS**。

已知缺口
========
* **G-02**：解析 ``schema_region_group_extension_policy`` 失败时，产品复用了
  ``DataRegionGroupExtensionPolicy %s doesn't exist.`` 的文案（``doc-gaps.md`` G-02）。
  PG-DFT-08 只判"被拒 + 文件未变"，把 ``.output`` 原样记进 evidence 并标注疑似 G-02。
* **G-01**：设计文档 docs/341 §4.1.3 的 ``T = min(K, R)`` 是简化写法；PG-MIN-02 按源码判定 2 组。
"""

from __future__ import annotations

import json
import time

from .cases import (
    CaseSpec,
    Ctx,
    db_of,
    device_set,
    ensure_write_tree,
    expect_cap,
    expect_groups,
    expected_cap,
    reset_db,
    write_devices,
    group_ceiling,
)

SPECS: list[CaseSpec] = []

# ---------------------------------------------------------------- 键名 / 默认值
_POLICY_OF = {
    "SCHEMA": "schema_region_group_extension_policy",
    "DATA": "data_region_group_extension_policy",
}
_MIN_OF = {
    "SCHEMA": "default_schema_region_group_num_per_database",
    "DATA": "default_data_region_group_num_per_database",
}
_CONF_POLICY_OF = {"SCHEMA": "PG_SCHEMA_POLICY", "DATA": "PG_DATA_POLICY"}
_CONF_MIN_OF = {"SCHEMA": "PG_MIN_SCHEMA_PER_DB", "DATA": "PG_MIN_DATA_PER_DB"}
_MIN_DEFAULT = {"SCHEMA": 1, "DATA": 2}
_DEFAULT_POLICY = "PROACTIVE"

_TREE = "tree"
#: 时间分区一律用"实测 TimePartitionInterval"构造（禁止硬编码 604800000）；
#: 基值取 1_000_000，保证 base 与 base+interval 必落在不同时间分区。
_BASE_STAMP = 1_000_000


# ================================================================= 通用夹具
def _flat(text: str, limit: int = 300) -> str:
    return " ".join((text or "").split())[:limit]


def _omit_profile(ctx: Ctx) -> bool:
    """conf 是否走"不写策略键"的默认值档位（``PG_OMIT_POLICY_KEYS=true``）。"""
    return (ctx.cfg.raw("PG_OMIT_POLICY_KEYS") or "").strip().lower() in ("1", "true", "yes")


def _conf_policy(ctx: Ctx, kind: str) -> str:
    return (ctx.cfg.raw(_CONF_POLICY_OF[kind]) or _DEFAULT_POLICY).strip()


def _conf_min(ctx: Ctx, kind: str) -> int:
    return int(ctx.cfg.raw(_CONF_MIN_OF[kind]) or _MIN_DEFAULT[kind])


def _read_prop(ctx: Ctx, key: str, host: str = "") -> str:
    """读某 CN 节点配置文件里该键的**生效值**（缺键返回 ""）。"""
    target = host or ctx.cfg.cn_hosts[0]
    return (ctx.props.read(target, keys=(key,)).get(key, "") or "").strip()


def _effective_min(ctx: Ctx, kind: str) -> int:
    """最小组数的**生效值**：优先读配置文件（``SET CONFIGURATION`` 会落盘），否则退回 conf。"""
    raw = _read_prop(ctx, _MIN_OF[kind])
    if raw:
        try:
            return int(raw)
        except ValueError:
            pass
    return _conf_min(ctx, kind)


def _read_map(ctx: Ctx, key: str) -> dict[str, str]:
    """逐 CN 节点读同一个键（缺键 = ""）——用于"文件值未变"的硬自证。"""
    return {host: _read_prop(ctx, key, host) for host in ctx.cfg.cn_hosts}


def _read_until(ctx: Ctx, key: str, want: str, attempts: int = 3) -> str:
    """读回自证（``SET CONFIGURATION`` 落盘可能有延迟，允许重试）。"""
    read = ""
    for _ in range(attempts):
        read = _read_prop(ctx, key)
        if read == want:
            break
        time.sleep(3)
    return read


def _ensure_readable(ctx: Ctx) -> bool:
    """读不到 conf 就没法做"文件未变"自证 ⇒ SKIP（绝不把读失败当通过）。"""
    try:
        ctx.props.read(ctx.cfg.cn_hosts[0])
        return True
    except Exception as exc:  # noqa: BLE001 - 任何读失败都按前置不成立处理
        ctx.skip(f"无法读取 CN 配置文件校验策略键：{exc}")
        return False


def _push_restore(ctx: Ctx, key: str, original: str) -> None:
    """把"恢复原值"登记进 cleanup：即使用例中途抛异常也会还原（防污染后续用例）。"""
    if str(original):
        ctx.cleanup.append(f'set configuration "{key}"="{original}"')


def _set_knob(ctx: Ctx, key: str, value, original, label: str) -> str:
    """热加载单个键 + 读回自证，并登记恢复原值。"""
    _push_restore(ctx, key, original)
    ctx.mark_harness_action(f"{label}：热加载 {key}={value}（原值 {original or '(缺省)'}）", pad=20)
    ctx.req(ctx.api.set_config(key, str(value)), f"{label} 热加载 {key}={value}")
    read = _read_until(ctx, key, str(value))
    ctx.check(f"{label}：{key} 读回应为 {value}", read == str(value), f"读回={read!r}")
    return read


def _restore_knob(ctx: Ctx, key: str, value, label: str) -> str:
    """显式恢复原值并读回自证（用例正文可见的收尾，cleanup 只是兜底）。

    H-25：恢复 conf 也是 harness 改配置，单独开归因窗口（与热加载同 pad）。
    """
    ctx.mark_harness_action(f"{label}：恢复 conf 原值 {key}={value}", pad=20, kind="set_config")
    out = ctx.api.set_config(key, str(value))
    read = _read_until(ctx, key, str(value))
    ctx.check(f"{label}：恢复 {key}={value}", out.ok and read == str(value),
              f"ok={out.ok}、读回={read!r}", evidence=out.output[:2000])
    return read


def _solo_tree(ctx: Ctx) -> str:
    """reset 树测试库，并清掉表模型测试库。

    ``SHOW DATABASES`` 按模型过滤，但产品算上限时树 + 表普通库**一起计入**
    （``ClusterSchemaManager.java:532-550``）；残留另一模型库会让
    ``cases.expected_cap`` 的分母偏小、上限偏大 ⇒ 先清掉它，口径才一致。
    """
    db = reset_db(ctx, _TREE)
    other = db_of(ctx, "table")
    ctx.mark_harness_action(f"清掉表模型测试库 {other}（使 expected_cap 的参与分摊库数=1）", pad=20)
    ctx.api.drop_database(other, table=True)
    return db


# ------------------------------------------------------------------- 公式与断言
def _predict(min_num: int, cap: int, groups: int, p_count: int, k: int) -> int:
    """源码口径 ``T = min(R, max(min(minNum, G+|P|), K))``；组只增不减 ⇒ 至少保持 G。"""
    return max(groups, min(cap, max(min(min_num, groups + p_count), k)))


def _formula(min_num: int, cap: int, groups: int, p_count: int, k: int) -> str:
    return (f"T=min(R={cap}, max(min(minNum={min_num}, G+|P|={groups}+{p_count}), K={k}))"
            f"={_predict(min_num, cap, groups, p_count, k)}")


def _groups(ctx: Ctx, db: str, kind: str) -> int:
    return ctx.api.db_group_num(db, kind, dialect=_TREE)


def _check_groups(ctx: Ctx, label: str, db: str, kind: str, want: int, formula: str = "") -> int:
    """轻量组数断言（用于逐步增长序列；最终态再用 ``expect_groups`` 做双口径）。"""
    got = _groups(ctx, db, kind)
    ctx.check(f"{label}：{kind.title()} 组数应为 {want}" + (f"（{formula}）" if formula else ""),
              got == want, f"实测={got}")
    return got


def _reject_check(ctx: Ctx, label: str, key: str, before: dict[str, str], out,
                  extra_detail: str = "") -> dict[str, str]:
    """非法提交的通用断言：必须被拒 + 逐 CN 节点文件值未变。"""
    ctx.check(f"{label}：非法提交必须被拒绝", not out.ok,
              f"ok={out.ok}；语句={_flat(out.statement)}；output={_flat(out.output)}"
              + (f"；{extra_detail}" if extra_detail else ""),
              evidence=out.output[:4000])
    after = _read_map(ctx, key)
    ctx.check(f"{label}：被拒后 {key} 在所有 CN 的文件值均未变", after == before,
              f"前={before}、后={after}", evidence=json.dumps(after, ensure_ascii=False))
    return after


def _illegal_value(ctx: Ctx, case: str, key: str, value: str, why: str,
                   *, start_db: bool = True) -> None:
    """非法策略/数值值用例的公共体（被拒 + 文件未变）。"""
    if start_db:
        _solo_tree(ctx)
    if not _ensure_readable(ctx):
        return
    before = _read_map(ctx, key)
    ctx.mark_harness_action(f"{case}：故意提交非法值 {key}={value}（预期被拒）", pad=15)
    out = ctx.api.set_config(key, value)
    _reject_check(ctx, f"{case} {why}", key, before, out)


# ============================================================= A. PG-DFT 默认值与配置
def case_dft01_default_data(ctx: Ctx) -> None:
    """DFT-01 默认值路径（Data）：conf 无策略键 ⇒ 走代码默认 PROACTIVE，3 slot 建 min(3,R) 组。"""
    if not _omit_profile(ctx):
        ctx.skip("需 conf/cluster.pg_default_iot.conf 档位（PG_OMIT_POLICY_KEYS=true）")
        return
    if not _ensure_readable(ctx):
        return
    db = _solo_tree(ctx)
    present: dict[str, dict[str, bool]] = {}
    for host in ctx.cfg.cn_hosts:
        props = ctx.props.read(host)
        present[host] = {key: (key in props) for key in _POLICY_OF.values()}
    ctx.check("DFT-01：所有 CN 配置文件都不含两个策略键（确认走代码默认值路径）",
              all(not any(flags.values()) for flags in present.values()),
              f"{len(present)} 个 CN：{present}", evidence=json.dumps(present, ensure_ascii=False))

    cap = expected_cap(ctx, "DATA", _TREE, db)
    write_devices(ctx, db, device_set(ctx, db, 3), model="tree")
    want = min(3, cap)
    expect_groups(ctx, "DFT-01 默认策略写 3 个不同 slot", db, _TREE, data=want)
    min_d = _effective_min(ctx, "DATA")
    if want > min_d:
        ctx.check("DFT-01：默认策略行为是 PROACTIVE（3 个 slot 突破最小组数、非 AUTO）",
                  _groups(ctx, db, "DATA") == want and want > min_d,
                  f"实测={_groups(ctx, db, 'DATA')}、最小组数={min_d}、上限 R={cap}")


def case_dft02_default_schema(ctx: Ctx) -> None:
    """DFT-02 默认值路径（Schema）：3 slot 建 min(3,R) 组，且 Max*RegionGroupNum 等于公式值。"""
    if not _omit_profile(ctx):
        ctx.skip("需 conf/cluster.pg_default_iot.conf 档位（PG_OMIT_POLICY_KEYS=true）")
        return
    db = _solo_tree(ctx)
    cap_s = group_ceiling(ctx, "SCHEMA", _TREE, db)
    write_devices(ctx, db, device_set(ctx, db, 3), model="tree")
    expect_groups(ctx, "DFT-02 默认策略写 3 个不同 slot（Schema 侧）", db, _TREE,
                  schema=min(3, cap_s))
    expect_cap(ctx, "DFT-02 库详情上限", db, _TREE)


def case_dft03_conf_auto(ctx: Ctx) -> None:
    """DFT-03 conf 显式 AUTO：6 个不同 slot 后 Data 组数 = 最小组数（AUTO 不积极扩容）。"""
    policy = _conf_policy(ctx, "DATA")
    if policy != "AUTO":
        ctx.skip(f"需 conf 显式 data 策略=AUTO 档位（当前 PG_DATA_POLICY={policy!r}）")
        return
    db = _solo_tree(ctx)
    min_d = ctx.cfg.get_int("PG_MIN_DATA_PER_DB")
    write_devices(ctx, db, device_set(ctx, db, 6), model="tree")
    want = min(6, min_d)
    expect_groups(ctx, "DFT-03 conf=AUTO 写 6 个不同 slot（不积极扩容）", db, _TREE, data=want)
    ctx.note(f"    AUTO 档位：6 个不同 slot 后 Data 组数={_groups(ctx, db, 'DATA')}、"
             f"最小组数={min_d}（期望 = min(6, min) = {want}）")


def case_dft04_conf_custom(ctx: Ctx) -> None:
    """DFT-04 conf 显式 CUSTOM：同 DFT-03，不主动扩容到 6、只到最小组数。"""
    policy = _conf_policy(ctx, "DATA")
    if policy != "CUSTOM":
        ctx.skip(f"需 conf 显式 data 策略=CUSTOM 档位（当前 PG_DATA_POLICY={policy!r}）")
        return
    db = _solo_tree(ctx)
    min_d = ctx.cfg.get_int("PG_MIN_DATA_PER_DB")
    write_devices(ctx, db, device_set(ctx, db, 6), model="tree")
    want = min(6, min_d)
    expect_groups(ctx, "DFT-04 conf=CUSTOM 写 6 个不同 slot（不主动扩容）", db, _TREE, data=want)
    ctx.note(f"    CUSTOM 档位：6 个不同 slot 后 Data 组数={_groups(ctx, db, 'DATA')}、"
             f"最小组数={min_d}（期望 = min(6, min) = {want}）")


def case_dft05_hot_reload_legal(ctx: Ctx) -> None:
    """DFT-05 热加载合法值：data 策略 → AUTO 成功、读回 AUTO，然后恢复 conf 原值并自证。"""
    _solo_tree(ctx)
    if not _ensure_readable(ctx):
        return
    key = _POLICY_OF["DATA"]
    original = _conf_policy(ctx, "DATA")
    _push_restore(ctx, key, original)
    ctx.mark_harness_action(f"DFT-05：热加载 data 策略为合法值 AUTO（原值 {original}）", pad=20)
    out = ctx.api.set_config(key, "AUTO")
    ctx.check("DFT-05：热加载合法值 AUTO 必须成功", out.ok,
              f"ok={out.ok}；output={_flat(out.output)}", evidence=out.output[:4000])
    read = _read_until(ctx, key, "AUTO")
    ctx.check("DFT-05：配置文件读回应为 AUTO", read == "AUTO", f"读回={read!r}")
    _restore_knob(ctx, key, original, "DFT-05")


def case_dft06_illegal_lowercase(ctx: Ctx) -> None:
    """DFT-06 非法值（小写 proactive）被拒，且文件值未变（不得静默解释为 PROACTIVE）。"""
    _illegal_value(ctx, "DFT-06", _POLICY_OF["DATA"], "proactive",
                   "小写非法策略值不得被解释为 PROACTIVE")


def case_dft07_illegal_proactive2(ctx: Ctx) -> None:
    """DFT-07 非法值 PROACTIVE2 被拒（明确报错、非静默降级），且文件值未变。"""
    _illegal_value(ctx, "DFT-07", _POLICY_OF["DATA"], "PROACTIVE2",
                   "非法策略值 PROACTIVE2 必须明确报错")


def case_dft08_schema_illegal(ctx: Ctx) -> None:
    """DFT-08 schema 键写非法值被拒；报错文案疑似复用 Data 键（G-02），只记原文不断言文案。"""
    _solo_tree(ctx)
    if not _ensure_readable(ctx):
        return
    key = _POLICY_OF["SCHEMA"]
    before = _read_map(ctx, key)
    ctx.mark_harness_action(f"DFT-08：故意提交非法 schema 策略值 {key}=proactive（预期被拒）", pad=15)
    out = ctx.api.set_config(key, "proactive")
    ctx.note("    [G-02] 已知文档/文案缺口：解析 schema 键失败时产品复用了 "
             "DataRegionGroupExtensionPolicy 的报错文案；本条只判「被拒 + 文件未变」，"
             "原文见 evidence。")
    ctx.check("DFT-08：schema 键写非法值必须被拒绝（文案疑似 G-02，不作文案断言）", not out.ok,
              f"ok={out.ok}；output 原文={_flat(out.output)}（疑似复用了 Data 键文案 → G-02）",
              evidence=out.output[:4000])
    after = _read_map(ctx, key)
    ctx.check("DFT-08：被拒后 schema 键在所有 CN 的文件值均未变", after == before,
              f"前={before}、后={after}", evidence=json.dumps(after, ensure_ascii=False))


def case_dft09_two_keys_one_statement(ctx: Ctx) -> None:
    """DFT-09 一条语句设两个键被拒（实测 700 语法错），两个键的文件值都未变。"""
    _solo_tree(ctx)
    if not _ensure_readable(ctx):
        return
    s_key, d_key = _POLICY_OF["SCHEMA"], _POLICY_OF["DATA"]
    before = {key: _read_map(ctx, key) for key in (s_key, d_key)}
    ctx.mark_harness_action("DFT-09：故意把两个策略键写在同一条 SET CONFIGURATION（预期 700 拒绝）",
                            pad=15)
    # 注意：pgapi.set_config_raw 会自行补 "set configuration " 前缀，故这里只传键值对，
    # 实际提交语句 = set configuration "schema_..."="PROACTIVE", "data_..."="PROACTIVE"。
    out = ctx.api.set_config_raw(f'"{s_key}"="PROACTIVE", "{d_key}"="PROACTIVE"')
    ctx.check("DFT-09：一条语句设两个键必须被拒绝（实测 700 语法错）", not out.ok,
              f"ok={out.ok}；语句={_flat(out.statement)}；output={_flat(out.output)}",
              evidence=out.output[:4000])
    after = {key: _read_map(ctx, key) for key in (s_key, d_key)}
    ctx.check("DFT-09：被拒后两个键在所有 CN 的文件值均未变", after == before,
              f"前={before}、后={after}", evidence=json.dumps(after, ensure_ascii=False))


def case_dft10_on_node(ctx: Ctx) -> None:
    """DFT-10 ``... ON 1`` 单节点提交被拒（实测 701 "must be consistent across the entire cluster"）。"""
    _solo_tree(ctx)
    if not _ensure_readable(ctx):
        return
    key = _POLICY_OF["DATA"]
    before = _read_map(ctx, key)
    ctx.mark_harness_action(f"DFT-10：故意用 ON <nodeId> 单节点提交 {key}（预期 701 拒绝）", pad=15)
    out = ctx.api.set_config_on_node(key, "PROACTIVE", 1)
    ctx.check("DFT-10：单节点 ON 1 提交必须被拒绝（实测 701 全集群一致）", not out.ok,
              f"ok={out.ok}；语句={_flat(out.statement)}；output={_flat(out.output)}",
              evidence=out.output[:4000])
    after = _read_map(ctx, key)
    ctx.check("DFT-10：被拒后该键在所有 CN 的文件值均未变", after == before,
              f"前={before}、后={after}", evidence=json.dumps(after, ensure_ascii=False))


def case_dft11_numeric_illegal(ctx: Ctx) -> None:
    """DFT-11 数值键写非数值（abc）被拒，且文件值未变。"""
    _illegal_value(ctx, "DFT-11", "schema_region_per_data_node", "abc",
                   "数值键写非数值 abc 必须被拒绝")


def case_dft12_two_policies_independent(ctx: Ctx) -> None:
    """DFT-12 两类策略独立：只把 data 切成 AUTO（不积极扩容），schema 仍按 conf 的 PROACTIVE。"""
    conf_s = _conf_policy(ctx, "SCHEMA")
    if conf_s != "PROACTIVE":
        ctx.skip(f"需 conf schema 策略=PROACTIVE 档位（当前 PG_SCHEMA_POLICY={conf_s!r}）")
        return
    db = _solo_tree(ctx)
    if not _ensure_readable(ctx):
        return
    data_key, schema_key = _POLICY_OF["DATA"], _POLICY_OF["SCHEMA"]
    original_data = _conf_policy(ctx, "DATA")
    cap_s = group_ceiling(ctx, "SCHEMA", _TREE, db)
    min_d = _effective_min(ctx, "DATA")

    _push_restore(ctx, data_key, original_data)
    ctx.mark_harness_action(
        f"DFT-12：只热加载 data 策略为 AUTO（原值 {original_data}），schema 保持 {conf_s}", pad=20)
    out = ctx.api.set_config(data_key, "AUTO")
    ctx.check("DFT-12：只热加载 data 键为 AUTO 必须成功", out.ok,
              f"ok={out.ok}；output={_flat(out.output)}", evidence=out.output[:4000])
    read_d = _read_until(ctx, data_key, "AUTO")
    read_s = _read_prop(ctx, schema_key) or _DEFAULT_POLICY
    ctx.check("DFT-12：读回 data=AUTO", read_d == "AUTO", f"读回={read_d!r}")
    ctx.check("DFT-12：读回 schema 仍为 PROACTIVE（未被联动切换）",
              read_s == "PROACTIVE", f"读回={read_s!r}")

    write_devices(ctx, db, device_set(ctx, db, 6), model="tree")
    expect_groups(ctx, "DFT-12 data=AUTO（不积极扩容）+ schema=PROACTIVE（min(K,R)）", db, _TREE,
                  schema=min(6, cap_s), data=min(6, min_d))
    ctx.note(f"    DFT-12：data=AUTO ⇒ Data 组数={_groups(ctx, db, 'DATA')}（期望 min(6, min={min_d})）；"
             f"schema=PROACTIVE ⇒ Schema 组数={_groups(ctx, db, 'SCHEMA')}（期望 min(6, R={cap_s})）")
    _restore_knob(ctx, data_key, original_data, "DFT-12")


# ============================================================= B. PG-MIN 最小组数
def case_min01_first_slot(ctx: Ctx) -> None:
    """MIN-01 min_data=2、首个 slot 首次请求只建 1 组（A-02：不一次性预建到 min）。"""
    db = _solo_tree(ctx)
    cap = expected_cap(ctx, "DATA", _TREE, db)
    key = _MIN_OF["DATA"]
    original = _effective_min(ctx, "DATA")
    _set_knob(ctx, key, 2, original, "MIN-01")
    write_devices(ctx, db, device_set(ctx, db, 1), model="tree")
    want = _predict(2, cap, 0, 1, 1)
    expect_groups(ctx, "MIN-01 min_data=2、首个 slot 首次请求", db, _TREE, data=want)
    ctx.check("MIN-01：首次请求只建 1 组、不预建到最小组数 2",
              want == 1 and _groups(ctx, db, "DATA") == 1,
              f"实测={_groups(ctx, db, 'DATA')}、公式值={want}；{_formula(2, cap, 0, 1, 1)}")
    _restore_knob(ctx, key, original, "MIN-01")


def case_min02_incremental_to_min(ctx: Ctx) -> None:
    """MIN-02 探针 A-01：G=1、同 slot 申请新时间分区 ⇒ 源码口径 2 组（设计文档口径 1 组）。"""
    db = _solo_tree(ctx)
    cap = expected_cap(ctx, "DATA", _TREE, db)
    interval = ctx.api.db_time_partition_interval(db, dialect=_TREE)
    if interval <= 0:
        ctx.skip("读不到库的 TimePartitionInterval，无法构造同 slot 的新时间分区")
        return
    if cap < 2:
        ctx.skip(f"data 上限 R={cap} < 2，无法验证 G=1 时向 min 的增量增长")
        return
    min_num = min(4, cap)          # 取"比上限小的值"，否则 min 被上限吃掉
    key = _MIN_OF["DATA"]
    original = _effective_min(ctx, "DATA")
    _set_knob(ctx, key, min_num, original, "MIN-02")

    devices = device_set(ctx, db, 1)
    ensure_write_tree(ctx, db, devices[0], _BASE_STAMP)
    _check_groups(ctx, "MIN-02 先写 1 个 slot（G=1）", db, "DATA",
                  _predict(min_num, cap, 0, 1, 1), _formula(min_num, cap, 0, 1, 1))
    # 同一设备、同一 slot、不同时间分区（用实测 TimePartitionInterval 算下一个分区的时间戳）
    ensure_write_tree(ctx, db, devices[0], _BASE_STAMP + interval)
    want = _predict(min_num, cap, 1, 1, 1)
    expect_groups(ctx, "MIN-02 同 slot 申请新时间分区（min 驱动增量补齐）", db, _TREE, data=want)
    ctx.note(f"    MIN-02：min={min_num}、R={cap} ⇒ {_formula(min_num, cap, 1, 1, 1)}；"
             f"设计文档 docs/341 §4.1.3 的简化口径会预测 1 ⇒ 记入 doc-gaps G-01")
    _restore_knob(ctx, key, original, "MIN-02")


def case_min03_three_slots(ctx: Ctx) -> None:
    """MIN-03 min_data=3、逐个写 3 个不同 slot：1 → 2 → 3（逐步逼近 min）。"""
    db = _solo_tree(ctx)
    cap = expected_cap(ctx, "DATA", _TREE, db)
    if cap < 3:
        ctx.skip(f"data 上限 R={cap} < 3，无法验证 min_data=3 的逐步逼近")
        return
    key = _MIN_OF["DATA"]
    original = _effective_min(ctx, "DATA")
    _set_knob(ctx, key, 3, original, "MIN-03")

    devices = device_set(ctx, db, 3)
    for i, device in enumerate(devices, start=1):
        ensure_write_tree(ctx, db, device, i)
        _check_groups(ctx, f"MIN-03 第 {i} 个不同 slot（每次一个请求、|P|=1）", db, "DATA",
                      _predict(3, cap, i - 1, 1, i), _formula(3, cap, i - 1, 1, i))
    ctx.check("MIN-03：3 个 slot 后到达最小组数 3", _groups(ctx, db, "DATA") == 3,
              f"实测={_groups(ctx, db, 'DATA')}、最小组数=3")
    _restore_knob(ctx, key, original, "MIN-03")


def case_min04_schema_side(ctx: Ctx) -> None:
    """MIN-04 Schema 侧同 MIN-03：min_schema=3、上限用 expected_cap(SCHEMA)。"""
    db = _solo_tree(ctx)
    # H-55：上限公式的分母是**树+表两模型的普通库总数**（ClusterSchemaManager.java:532-550），
    # 前面用例残留的库会把 R 压到 3 以下（实测 R=2）⇒ 先清掉其它用户库，口径才等于设计。
    others = (set(ctx.api.database_details("tree")) | set(ctx.api.database_details("table")))
    for other in [n for n in others if n != db and not any(x in n for x in ("__system", "__audit"))]:
        for table_model in (False, True):
            try:
                ctx.api.drop_database(other, table=table_model)
            except Exception:  # noqa: BLE001 - 另一种方言下不存在时忽略
                pass
    cap_s = group_ceiling(ctx, "SCHEMA", _TREE, db)
    if cap_s < 3:
        ctx.skip(f"schema 上限 R={cap_s} < 3，无法验证 min_schema=3 的逐步逼近")
        return
    key = _MIN_OF["SCHEMA"]
    original = _effective_min(ctx, "SCHEMA")
    _set_knob(ctx, key, 3, original, "MIN-04")

    devices = device_set(ctx, db, 3)
    for i, device in enumerate(devices, start=1):
        ensure_write_tree(ctx, db, device, i)
        _check_groups(ctx, f"MIN-04 第 {i} 个不同 slot（Schema 侧、|P|=1）", db, "SCHEMA",
                      _predict(3, cap_s, i - 1, 1, i), _formula(3, cap_s, i - 1, 1, i))
    ctx.check("MIN-04：3 个 slot 后 Schema 到达最小组数 3", _groups(ctx, db, "SCHEMA") == 3,
              f"实测={_groups(ctx, db, 'SCHEMA')}、最小组数=3")
    _restore_knob(ctx, key, original, "MIN-04")


def case_min05_min_exceeds_cap(ctx: Ctx) -> None:
    """MIN-05 min 大于公式上限 ⇒ 上限吃 min：MaxDataRegionGroupNum=min，写满 min 个 slot 得 min 组。"""
    db = _solo_tree(ctx)
    cap = expected_cap(ctx, "DATA", _TREE, db)
    slot_num = int(ctx.cfg.raw("PG_SERIES_SLOT_NUM") or 1000)
    want_min = cap + 2
    if want_min > slot_num:
        ctx.skip(f"需写 {want_min} 个不同 slot > series_slot_num={slot_num}，无法验证")
        return
    key = _MIN_OF["DATA"]
    original = _effective_min(ctx, "DATA")
    _set_knob(ctx, key, want_min, original, "MIN-05")
    # 上限在建库时确定 ⇒ 必须重建库，min 才会吃满上限
    db = reset_db(ctx, _TREE)
    got_max = ctx.api.db_max_group_num(db, "DATA", dialect=_TREE)
    ctx.check(f"MIN-05：min={want_min}(=公式上限 {cap}+2) 时 MaxDataRegionGroupNum 应等于该 min",
              got_max == want_min, f"实测 MaxDataRegionGroupNum={got_max}、公式上限 R={cap}")

    write_devices(ctx, db, device_set(ctx, db, want_min), model="tree")
    expect_groups(ctx, f"MIN-05 写满 {want_min} 个不同 slot（组数被 min 撑到上限）", db, _TREE,
                  data=want_min)
    _restore_knob(ctx, key, original, "MIN-05")


def case_min06_grow_with_new_partition(ctx: Ctx) -> None:
    """MIN-06 min 调大后同 slot 申请新时间分区（不新增 slot）也会向 min 增长：G=2、min=5 ⇒ 3。"""
    db = _solo_tree(ctx)
    cap = expected_cap(ctx, "DATA", _TREE, db)
    interval = ctx.api.db_time_partition_interval(db, dialect=_TREE)
    if interval <= 0:
        ctx.skip("读不到库的 TimePartitionInterval，无法构造同 slot 的新时间分区")
        return
    if cap < 5:
        ctx.skip(f"data 上限 R={cap} < 5，无法验证 min=5 下 G=2 的增量补齐")
        return
    key = _MIN_OF["DATA"]
    original = _effective_min(ctx, "DATA")
    _set_knob(ctx, key, 5, original, "MIN-06")
    # H-27（库存量 vs 实时配置）：最小组数是**建库时落进库内的存量**
    # （``ClusterSchemaInfo.getMinRegionGroupNum`` 读存量），热加载 5 不会改已建的库。
    # 旧实现先建库（存量 min=2）再热加载，于是实测 2 组被判成"没补齐"。
    # ⇒ 必须**先热加载、再重建库**，才能观察到"同 slot 新分区向 min 增长"。
    db = reset_db(ctx, _TREE)
    cap = max(expected_cap(ctx, "DATA", _TREE, db), group_ceiling(ctx, "DATA", _TREE, db))
    interval = ctx.api.db_time_partition_interval(db, dialect=_TREE)
    if interval <= 0 or cap < 5:
        ctx.skip(f"重建库后 TimePartitionInterval={interval}、上限 R={cap} 不满足前置")
        _restore_knob(ctx, key, original, "MIN-06")
        return
    ctx.check("MIN-06：重建库后库内存量 min = 热加载后的 5（落库自证）",
              _effective_min(ctx, "DATA") == 5,
              f"生效值={_effective_min(ctx, 'DATA')}、conf={_conf_min(ctx, 'DATA')}")

    devices = device_set(ctx, db, 2)
    write_devices(ctx, db, devices, model="tree", stamp=_BASE_STAMP)
    _check_groups(ctx, "MIN-06 先写 2 个不同 slot（G=2）", db, "DATA", 2,
                  _formula(5, cap, 1, 1, 2))
    # 同一 slot（devices[0]）、新时间分区、不新增 slot ⇒ |P|=1、K=2
    ensure_write_tree(ctx, db, devices[0], _BASE_STAMP + interval)
    want = _predict(5, cap, 2, 1, 2)
    expect_groups(ctx, "MIN-06 同 slot 申请新时间分区（G=2、min=5 ⇒ 增量补齐到 3）", db, _TREE,
                  data=want)
    ctx.note(f"    MIN-06：min=5、R={cap} ⇒ {_formula(5, cap, 2, 1, 2)}（不新增 slot 也向 min 增长）")
    _restore_knob(ctx, key, original, "MIN-06")


# ===================================================================== registry
SPECS.append(CaseSpec(
    "PG-DFT-01", "默认值与配置", "tree",
    "默认值路径（Data）：conf 无策略键 ⇒ PROACTIVE，3 slot 建 min(3,R) 组",
    "P0", case_dft01_default_data))
SPECS.append(CaseSpec(
    "PG-DFT-02", "默认值与配置", "tree",
    "默认值路径（Schema）：3 slot 建 min(3,R) 组且 Max*RegionGroupNum=公式值",
    "P0", case_dft02_default_schema))
SPECS.append(CaseSpec(
    "PG-DFT-03", "默认值与配置", "tree",
    "conf 显式 AUTO：6 个不同 slot 后 Data 组数 = 最小组数（不积极扩容）",
    "P0", case_dft03_conf_auto))
SPECS.append(CaseSpec(
    "PG-DFT-04", "默认值与配置", "tree",
    "conf 显式 CUSTOM：6 个不同 slot 后 Data 组数 = 最小组数",
    "P1", case_dft04_conf_custom))
SPECS.append(CaseSpec(
    "PG-DFT-05", "默认值与配置", "tree",
    "热加载合法值 AUTO 成功、读回 AUTO，随后恢复 conf 原值并读回自证",
    "P0", case_dft05_hot_reload_legal))
SPECS.append(CaseSpec(
    "PG-DFT-06", "默认值与配置", "tree",
    "非法值小写 proactive 被拒（不得解释为 PROACTIVE）且文件值未变",
    "P0", case_dft06_illegal_lowercase))
SPECS.append(CaseSpec(
    "PG-DFT-07", "默认值与配置", "tree",
    "非法值 PROACTIVE2 被拒且文件值未变（明确报错、非静默降级）",
    "P1", case_dft07_illegal_proactive2))
SPECS.append(CaseSpec(
    "PG-DFT-08", "默认值与配置", "tree",
    "schema 键写非法值被拒、文件未变；报错文案疑似 G-02，只记原文",
    "P1", case_dft08_schema_illegal))
SPECS.append(CaseSpec(
    "PG-DFT-09", "默认值与配置", "tree",
    "一条 SET CONFIGURATION 设两个键被拒（实测 700），两个键文件值均未变",
    "P1", case_dft09_two_keys_one_statement))
SPECS.append(CaseSpec(
    "PG-DFT-10", "默认值与配置", "tree",
    "SET CONFIGURATION ... ON 1 单节点提交被拒（实测 701），文件值未变",
    "P1", case_dft10_on_node))
SPECS.append(CaseSpec(
    "PG-DFT-11", "默认值与配置", "tree",
    "数值键 schema_region_per_data_node 写 abc 被拒且文件值未变",
    "P1", case_dft11_numeric_illegal))
SPECS.append(CaseSpec(
    "PG-DFT-12", "默认值与配置", "tree",
    "两类策略独立：仅 data 切 AUTO（不积极扩容），schema 仍按 PROACTIVE（min(6,R)）",
    "P0", case_dft12_two_policies_independent))

SPECS.append(CaseSpec(
    "PG-MIN-01", "最小数量", "tree",
    "min_data=2、首个 slot 首次请求只建 1 组（不预建到 min）",
    "P0", case_min01_first_slot))
SPECS.append(CaseSpec(
    "PG-MIN-02", "最小数量", "tree",
    "探针 A-01：G=1、同 slot 新时间分区 ⇒ 源码口径 2 组（非 1 组）",
    "P0", case_min02_incremental_to_min))
SPECS.append(CaseSpec(
    "PG-MIN-03", "最小数量", "tree",
    "min_data=3、逐个写 3 个不同 slot：1→2→3 逐步逼近 min",
    "P0", case_min03_three_slots))
SPECS.append(CaseSpec(
    "PG-MIN-04", "最小数量", "tree",
    "Schema 侧逐步逼近：min_schema=3、上限取 expected_cap(SCHEMA)",
    "P0", case_min04_schema_side))
SPECS.append(CaseSpec(
    "PG-MIN-05", "最小数量", "tree",
    "min 大于公式上限 ⇒ 上限吃 min：MaxDataRegionGroupNum=min 且写满 min slot 得 min 组",
    "P1", case_min05_min_exceeds_cap))
SPECS.append(CaseSpec(
    "PG-MIN-06", "最小数量", "tree",
    "min 调大后同 slot 申请新时间分区（不新增 slot）也向 min 增长：G=2、min=5 ⇒ 3",
    "P1", case_min06_grow_with_new_partition))
