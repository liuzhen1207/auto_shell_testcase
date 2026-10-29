"""PG-MSR 测点规模 / PG-TIME 时间分区 用例族。

覆盖：``references/case-catalog.md`` 的 **PG-MSR（MSR-01..16）** 与 **PG-TIME（TIME-01..12）**
两段；判定口径唯一来源 ``references/proactive-spec.md``（源码口径
``iotdb-core/confignode/.../partition/PartitionManager.java:655-698``）：

    minimumTarget = min(minNum, G + |P|)             # |P| = 本次请求里缺失分区的不同 series slot 数
    T             = min(R, max(minimumTarget, K))    # K = |S ∪ P|
    delta         = max(0, T - G)

本模块的两条铁律（必须在标题/断言里体现，不得写成"测点数越多组越多"）：

1. **测点数不改变 series slot**。单设备只有 1 个 slot ⇒ Schema/Data 组数只由 ``min(1, R)``
   决定，与测点数无关；要制造多 slot 必须换设备名（``device_set()``）。
   benchmark 大规模用例用产品侧 ``SHOW DATA SERIESSLOTID WHERE DATABASE=<db>`` **实测 K**，
   绝不按"测点数/设备数"推断。
2. **同 slot 的新时间分区不增加 K**，但会以 ``|P|=1`` 触发"增量逼近最小组数"：Data 组由 1
   补到 ``min(minNum, R)``（默认 ``PG_MIN_DATA_PER_DB=2``）；Schema 组不随时间分区变化。
   时间分区边界一律用 ``SHOW DATABASES DETAILS`` 的 ``TimePartitionInterval`` 实测值计算，
   **禁止硬编码 604800、禁止把秒当毫秒**。

环境口径（2026-10-14 源码核验 + 集群实测）：

* ``SHOW DATABASES DETAILS`` 的 ``TimePartitionInterval`` 单位是**毫秒**：默认 604800000
  （源码 ``CommonConfig.DEFAULT_TIME_PARTITION_INTERVAL = 604_800_000L``）；本 conf
  ``PG_TIME_PARTITION_INTERVAL=604800`` ⇒ 实测列值 604800（≈10min，便于造跨分区数据）。
* **表模型方言不支持区域/时间槽观测子句**：``SHOW (DATA|SCHEMA) REGIONID`` 与
  ``SHOW (TIMESLOTID|TIMEPARTITION)`` 在表方言直接抛 ``SemanticException``
  （``AstBuilder.java:1781/1785``）⇒ **凡是要观测时间分区/时间槽计数的断言只在树模型做**；
  表模型用例只断言 ``SHOW DATABASES DETAILS``（``Schema/DataRegionGroupNum`` 与
  ``Max*RegionGroupNum``）、``SHOW REGIONS`` 去重与写入行数，不写"表模型下 TIMESLOTID 计数一致"
  这类必然报错的断言。
* 参与分摊库数是**树 + 表普通库一起算**（``ClusterSchemaManager.java:530``），而
  ``SHOW DATABASES`` 按方言过滤（``ClusterSchemaInfo.getDatabaseNames``）⇒ ``cases.expected_cap()``
  已改为取两个方言的并集。本模块每次都用"观测上限 == 公式上限"自证（不一致即 FAIL，不静默降级），
  且 benchmark 之后重新实时计算（``_refresh_caps``），不缓存旧值；另一模型的库是否残留不影响判定。
* benchmark 判据（``references/proactive-knobs.md`` §6）：输出抓 ``INGESTION <a> <b> <c> <d>``，
  要求 ``rc=0`` 且 ``a>0``、``c=0``、``d=0``；前置（``PG_BENCH_SSH``/目录/包/java）不成立
  **必须 SKIP 并写明原因**；写入失败（输出含异常）判 FAIL；既无 ``INGESTION`` 行又无异常时
  按"未确认 benchmark 输出格式"SKIP，绝不用"没报错"当通过。
"""

from __future__ import annotations

import json
from dataclasses import dataclass

from . import slots as pslots
from .cases import (
    CaseSpec,
    Ctx,
    device_set,
    dialect_of,
    ensure_write_table,
    expect_groups,
    expected_cap,
    reset_db,
)

SPECS: list[CaseSpec] = []

TREE_SENSOR = "s0"
TABLE = "tb"
#: benchmark 前置所需的 conf 键与包名（与 pgapi.PgApi.bench_run 保持一致）
_BENCH = {
    "v20": ("PG_BENCH_V20_DIR", "iot-benchmark-iotdb-2.0-java17.zip"),
    "v13": ("PG_BENCH_V13_DIR", "iot-benchmark-iotdb-1.3-java17.zip"),
}


# ============================================================== 模块内私有 helper
@dataclass
class _Env:
    """一个用例的干净库上下文（含实测时间分区轴与公式上限）。"""

    db: str
    model: str
    dialect: str
    cap_s: int
    cap_d: int
    min_s: int
    min_d: int
    origin: int
    interval: int  # ms，来自 SHOW DATABASES DETAILS（禁止硬编码）


def _min_num(ctx: Ctx, kind: str) -> int:
    default = 2 if kind.upper().startswith("D") else 1
    key = "PG_MIN_DATA_PER_DB" if kind.upper().startswith("D") else "PG_MIN_SCHEMA_PER_DB"
    return int(ctx.cfg.raw(key) or default)


def _predict(min_num: int, cap: int, groups: int, p_count: int, k: int) -> int:
    """源码口径：``T = min(R, max(min(minNum, G+|P|), K))``；组只增不减 ⇒ 至少保持 G。"""
    return max(groups, min(cap, max(min(min_num, groups + p_count), k)))


@dataclass
class _Trace:
    """按源码公式推进的期望轨迹：每次请求登记 ``(|P|, K)`` 得到该步应达到的组数。

    最终态断言必须用它，**不能**图省事写 ``min(minNum, R)``：组数只按 ``|P|`` 增量逼近最小组数，
    请求次数不够时到不了 ``minNum``（例如 ``PG_MIN_DATA_PER_DB=4`` 而只写了 2 个新时间分区，
    终态是 3 而不是 4）。
    """

    min_num: int
    cap: int
    groups: int = 0

    def step(self, p_count: int, k: int) -> int:
        self.groups = _predict(self.min_num, self.cap, self.groups, p_count, k)
        return self.groups


def _row_int(row: dict, names: tuple[str, ...], default: int = 0) -> int:
    wanted = {n.lower() for n in names}
    for key, value in row.items():
        if key.strip().lower() in wanted:
            try:
                return int(str(value).strip())
            except ValueError:
                return default
    return default


def _caps(ctx: Ctx, db: str, dialect: str) -> tuple[int, int] | None:
    """自证 ``Max*RegionGroupNum`` 不低于源码公式；低了返回 None（用例提前返回，避免二次假 FAIL）。

    返回给用例建模用的 ``(R_schema, R_data)`` 取**产品自报上限**（H-10/H-19）：
    组数按 ``min(K, R)`` 逼近，R 用自报值才对得上实测（用公式会把"上限 5 / 组数 5"
    误判成"期望 3"）。
    """
    want, bad, observed_caps = {}, {}, {}
    for kind in ("SCHEMA", "DATA"):
        want[kind] = expected_cap(ctx, kind, dialect, db)
        observed = ctx.api.db_max_group_num(db, kind, dialect=dialect)
        observed_caps[kind] = observed
        # H-19：产品按库保存**单调不减**的上限（H-10）。库数变多/资源重算后源码公式会低于
        # 已存上限，此时 observed > want 是**预期**行为，不判 FAIL；只有 observed < want
        # （低于应有值，如 D-04 表模型被钉在最小值）才是真不一致。
        if observed < want[kind]:
            bad[kind] = observed
    ctx.check(
        "库上限与源码公式一致（参与分摊库数 = 库详情口径自证）",
        not bad,
        f"公式={want}、实测={observed_caps}"
        + (f"、不一致={bad}" if bad else "（实测 ≥ 公式，H-19 通过）"),
        evidence=json.dumps(ctx.api.database_details(dialect), ensure_ascii=False)[:2000],
    )
    if bad:
        return None
    # H-19/H-10：建模用**自报**上限（单调存量），公式只作下界。
    return (max(want["SCHEMA"], observed_caps["SCHEMA"]),
            max(want["DATA"], observed_caps["DATA"]))


def _prepare(ctx: Ctx, model: str) -> _Env | None:
    """每个用例的统一前置：PROACTIVE×2 校验 → reset_db 干净库 → 上限自证 → 空库断言。"""
    policies = {k: ctx.cfg.raw(k) for k in ("PG_SCHEMA_POLICY", "PG_DATA_POLICY")}
    if any(value != "PROACTIVE" for value in policies.values()):
        ctx.skip(f"本轮 conf 策略 {policies} 非 PROACTIVE×2；请用 conf/cluster.pg_2011snap_iot.conf 运行")
        return None
    db = reset_db(ctx, model)
    dialect = dialect_of(model)
    caps = _caps(ctx, db, dialect)
    if caps is None:
        return None
    expect_groups(ctx, "写入前空库（空库不预建）", db, dialect, schema=0, data=0)
    row = ctx.api.database_details(dialect).get(db, {})
    interval = ctx.api.db_time_partition_interval(db, dialect=dialect)
    if interval <= 0:
        ctx.skip("SHOW DATABASES DETAILS 未给出有效 TimePartitionInterval，无法按实测值算分区边界")
        return None
    return _Env(
        db=db,
        model=model,
        dialect=dialect,
        cap_s=caps[0],
        cap_d=caps[1],
        min_s=_min_num(ctx, "SCHEMA"),
        min_d=_min_num(ctx, "DATA"),
        origin=_row_int(row, ("TimePartitionOrigin", "time_partition_origin"), 0),
        interval=interval,
    )


def _refresh_caps(ctx: Ctx, env: _Env) -> _Env:
    """benchmark 之后重新自证上限（大规模用例可能新建了库，分母会变）。"""
    caps = _caps(ctx, env.db, env.dialect)
    if caps is not None:
        env.cap_s, env.cap_d = caps
    return env


def _partition_of(stamp: int, env: _Env) -> int:
    return (stamp - env.origin) // env.interval


def _check_data(ctx: Ctx, env: _Env, label: str, want: int, formula: str = "") -> int:
    """轻量 Data 组数断言（用于逐步增长序列；最终态再用 expect_groups 做双口径）。"""
    got = ctx.api.db_group_num(env.db, "DATA", dialect=env.dialect)
    name = f"{label}：Data 组数应为 {want}" + (f"（{formula}）" if formula else "")
    ctx.check(name, got == want, f"实测={got}")
    return got


def _check_schema(ctx: Ctx, env: _Env, label: str, want: int, formula: str = "") -> int:
    got = ctx.api.db_group_num(env.db, "SCHEMA", dialect=env.dialect)
    name = f"{label}：Schema 组数应为 {want}" + (f"（{formula}）" if formula else "")
    ctx.check(name, got == want, f"实测={got}")
    return got


# ---------------------------------------------------------------- 写入（夹具）
def _tree_row(ctx: Ctx, env: _Env, device: str, sensors: tuple[str, ...], stamp: int,
              values: list | None = None) -> list:
    vals = list(values) if values is not None else [float(i + 1) for i in range(len(sensors))]
    ctx.req(ctx.api.insert_tree(f"{env.db}.{device}", stamp, list(sensors), vals),
            f"insert {env.db}.{device}@{stamp}（{len(sensors)} 测点）")
    ctx.note_data_written(env.db, device, "tree")  # 收尾②对拍查询（按对象名去重）
    return vals


def _tree_rows(ctx: Ctx, env: _Env, device: str, sensors: tuple[str, ...], stamps: list[int]) -> list:
    """一次多行 insert：同一 slot 的多个新时间分区落在**同一个请求**里（|P| 仍为 1）。"""
    vals = [float(i + 1) for i in range(len(sensors))]
    rows = [(stamp, list(sensors), list(vals)) for stamp in stamps]
    ctx.req(ctx.api.insert_tree_many(f"{env.db}.{device}", rows),
            f"insert {env.db}.{device} 多分区 {stamps}（{len(sensors)} 测点）")
    ctx.note_data_written(env.db, device, "tree")
    return vals


def _create_table(ctx: Ctx, env: _Env, table: str, fields: int) -> None:
    columns = "devid STRING TAG, " + ", ".join(f"s{i} FLOAT FIELD" for i in range(fields))
    ctx.req(ctx.api.create_table(env.db, table, columns=columns), f"create table {env.db}.{table}")


def _table_row(ctx: Ctx, env: _Env, table: str, tag: str, stamp: int, fields: int,
               values: list | None = None) -> list:
    vals = list(values) if values is not None else [float(i + 1) for i in range(fields)]
    ensure_write_table(ctx, env.db, table, tag, stamp=stamp, fields=fields, values=vals)
    return vals


def _table_rows(ctx: Ctx, env: _Env, table: str, tag_col: str, rows: list[tuple]) -> None:
    ctx.req(ctx.api.insert_table_many(env.db, table, tag_col, rows),
            f"insert {env.db}.{table} 批量 {len(rows)} 行")
    ctx.note_data_written(env.db, table, "table")


# ---------------------------------------------------------------- 观测（产品 SQL）
def _slot_k(ctx: Ctx, env: _Env, kind: str) -> int:
    """产品侧 K：``SHOW {DATA|SCHEMA} SERIESSLOTID WHERE DATABASE=<db>`` 的行数（树方言）。"""
    outcome = ctx.api.run(f"show {kind.lower()} seriesslotid where database={env.db}", dialect="tree")
    return len(outcome.rows) if outcome.ok else -1


def _expect_k(ctx: Ctx, env: _Env, kind: str, want: int, why: str) -> None:
    got = _slot_k(ctx, env, kind)
    ctx.check(f"{kind} series slot 数应为 {want}（{why}）", got == want,
              f"实测 SHOW {kind} SERIESSLOTID 行数={got}")


def _partitions(ctx: Ctx, env: _Env) -> int:
    """库级不同时间分区数：``COUNT TIMESLOTID WHERE DATABASE=<db>``（仅树模型可用）。"""
    return ctx.api.timeslot_count(db=env.db, dialect="tree")


def _partitions_of(ctx: Ctx, env: _Env, device: str) -> int:
    return ctx.api.timeslot_count(device=f"{env.db}.{device}", dialect="tree")


def _timeslot_rows(ctx: Ctx, env: _Env, device: str = "") -> int:
    where = f"device={env.db}.{device}" if device else f"database={env.db}"
    outcome = ctx.api.run(f"show timeslotid where {where}", dialect="tree")
    return len(outcome.rows) if outcome.ok else -1


def _series_count(ctx: Ctx, env: _Env, device: str) -> int:
    outcome = ctx.api.show_timeseries(f"{env.db}.{device}.**")
    return len(outcome.rows) if outcome.ok else -1


def _cell(ctx: Ctx, sql: str, dialect: str, column: str = "") -> str:
    outcome = ctx.api.run(sql, dialect=dialect)
    if not outcome.ok or not outcome.rows:
        return ""
    row = outcome.rows[0]
    if column:
        for key, value in row.items():
            if column.lower() in key.strip().lower():
                return str(value).strip()
    values = [str(v).strip() for v in row.values()]
    return values[-1] if values else ""


def _float(text: str) -> float | None:
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def _expect_value(ctx: Ctx, label: str, sql: str, dialect: str, column: str, want: float) -> None:
    text = _cell(ctx, sql, dialect, column)
    got = _float(text)
    ctx.check(label, got is not None and abs(got - want) < 1e-6,
              f"实测={got}、期望={want}", evidence=f"{sql} -> {text}")


def _slot_num(ctx: Ctx) -> int:
    """产品 series slot 数（hash 取模上限）：harness 侧算 slot 必须与它一致。"""
    return int(ctx.cfg.raw("PG_SERIES_SLOT_NUM") or 1000)


def _need_slots(ctx: Ctx, want: int, what: str) -> bool:
    """前置检查：``device_set()`` 要求 count 个互不相同 slot，slot 总数不足时它会死循环。"""
    n = _slot_num(ctx)
    if n < want:
        ctx.skip(f"{what} 需要 {want} 个互不相同 slot，但本轮 PG_SERIES_SLOT_NUM={n}"
                 "（不足以保证互异 slot；harness 生成器在此配置下不可满足）")
        return False
    return True


def _expect_tree_slots(ctx: Ctx, label: str, db: str, devices: list[str], want: int) -> None:
    got = pslots.distinct_slot_count(db, devices, slot_num=_slot_num(ctx))
    ctx.check(f"{label}：harness BKDR131 计算的不同 slot 数应为 {want}", got == want, f"实测={got}")


def _expect_table_slots(ctx: Ctx, label: str, tags: list[str], want: int) -> None:
    got = pslots.distinct_tag_slot_count(TABLE, tags, slot_num=_slot_num(ctx))
    ctx.check(f"{label}：harness BKDR131 计算的不同 TAG slot 数应为 {want}", got == want, f"实测={got}")


def _first_table(ctx: Ctx, env: _Env) -> str:
    outcome = ctx.api.show_tables(env.db)
    if not outcome.ok:
        return ""
    for row in outcome.rows:
        for key, value in row.items():
            if key.strip().lower() in ("tablename", "table", "name") and str(value).strip():
                return str(value).strip()
    return ""


# ---------------------------------------------------------------- benchmark 夹具
def _bench_precheck(ctx: Ctx, bench_line: str = "v20") -> bool:
    """benchmark 前置：PG_BENCH_SSH / 目录 / 包 / java。不成立 ⇒ SKIP 并写明原因。"""
    key, zip_name = _BENCH[bench_line]
    if not ctx.cfg.raw("PG_BENCH_SSH"):
        ctx.skip("PG_BENCH_SSH 未配置（未指定 benchmark 客户端机）")
        return False
    pkg = ctx.cfg.raw(key)
    if not pkg:
        ctx.skip(f"{key} 未配置（benchmark 目录缺失）")
        return False
    command = (
        f"test -d {pkg} && echo DIR_OK || echo DIR_MISSING; "
        f"test -f {pkg}/{zip_name} && echo ZIP_OK || echo ZIP_MISSING; "
        "source /etc/profile >/dev/null 2>&1; command -v java >/dev/null 2>&1 && echo JAVA_OK || echo JAVA_MISSING"
    )
    try:
        code, output = ctx.api.bench_ssh(command, timeout=120)
    except Exception as exc:  # noqa: BLE001 - 客户端机不可达属于前置不成立
        ctx.skip(f"无法通过 PG_BENCH_SSH 访问客户端机：{type(exc).__name__}: {exc}")
        return False
    if code != 0:
        ctx.skip(f"客户端机 {ctx.cfg.raw('PG_BENCH_SSH')} 命令失败（rc={code}）：{output.strip()[:200]}")
        return False
    missing = [w for w in ("DIR_MISSING", "ZIP_MISSING", "JAVA_MISSING") if w in output]
    if missing:
        ctx.skip(f"benchmark 前置不成立：{missing}（{key}={pkg}，包 {zip_name}）")
        return False
    return True


def _bench_write(ctx: Ctx, *, dialect: str, db_name: str, device_number: int, sensor_number: int,
                 duration_ms: int, tag: str, bench_line: str = "v20") -> bool:
    """跑一轮 benchmark 并按 knobs §6 判据判定（a>0、c=0、d=0、rc=0）。"""
    try:
        res = ctx.api.bench_run(
            dialect=dialect, db_name=db_name, device_number=device_number,
            sensor_number=sensor_number, duration_ms=duration_ms, tag=tag,
            out_dir=ctx.case_dir / "bench", bench_line=bench_line, data_client_number=2,
            batch_size=10,
        )
    except Exception as exc:  # noqa: BLE001 - benchmark 编排失败属 harness 前置
        ctx.skip(f"benchmark 客户端编排异常（{type(exc).__name__}: {exc}）")
        return False
    ingestion = res.get("ingestion")
    output = str(res.get("output") or "")
    ctx.note(f"benchmark INGESTION={ingestion} ok={res.get('ok')} out_file={res.get('out_file', '')}")
    if ingestion is None:
        if "Exception" in output or "Execution fail" in output:
            ctx.check("benchmark 写入成功（INGESTION a>0、c=0、d=0 且 rc=0）", False,
                      "benchmark 输出无 INGESTION 行且含异常", evidence=output[-4000:])
        else:
            ctx.skip("未确认 benchmark 输出格式：输出中既无 INGESTION <a> <b> <c> <d> 行，也无异常标记"
                     f"（可能是本轮未跑到写入阶段）；tail={output[-600:]}")
        return False
    parts = [str(x).strip() for x in (ingestion.split() if isinstance(ingestion, str) else ingestion)]
    if len(parts) != 4:
        ctx.skip(f"benchmark 输出格式未确认：INGESTION 字段数={len(parts)}（期望 4 个整数）：{parts}")
        return False
    a, b, c, d = (int(x) for x in parts)
    ok = bool(res.get("ok")) and a > 0 and c == 0 and d == 0
    ctx.check("benchmark 写入成功（rc=0 且 INGESTION a>0、c=0、d=0）", ok,
              f"INGESTION a={a} b={b} c={c} d={d}", evidence=output[-4000:])
    return ok


def _locate_bench_db(ctx: Ctx, base_db: str, dialect: str) -> str:
    """benchmark 实际写入的库：树模型固定 root.<name>；表模型取 <name>/<name>_<i> 中组数最大者。"""
    details = ctx.api.database_details(dialect)
    if base_db in details:
        return base_db
    prefix = base_db.split(".")[-1] + "_"
    candidates = [name for name in details if name.startswith(prefix)]
    if not candidates:
        return base_db
    return max(candidates, key=lambda name: ctx.api.db_group_num(name, "DATA", dialect=dialect))


def _cli_sample_tree(ctx: Ctx, env: _Env) -> None:
    """CLI 侧独立 COUNT 校验（不依赖 benchmark 自报）。"""
    outcome = ctx.api.show_timeseries(f"{env.db}.**")
    if not outcome.ok or not outcome.rows:
        ctx.check("CLI 侧可查到 benchmark 写入的 series", False,
                  f"SHOW TIMESERIES 行数={len(outcome.rows) if outcome.ok else -1}")
        return
    first = ""
    for row in outcome.rows:
        for key, value in row.items():
            if key.strip().lower() == "timeseries" and str(value).strip():
                first = str(value).strip()
                break
        if first:
            break
    rows = ctx.api.count_rows(first, dialect="tree") if first else -1
    ctx.check("CLI 侧 COUNT 校验：样本 series 行数 > 0（不依赖 benchmark 自报）", rows > 0,
              f"series 总数={len(outcome.rows)}、样本={first}、行数={rows}")
    if first:
        # benchmark 是外部客户端写入 ⇒ harness 侧登记对拍查询，让收尾②真正做副本对拍
        device = first.replace("`", "").rsplit(".", 1)[0]
        rel = device[len(env.db) + 1:] if device.startswith(env.db + ".") else device
        ctx.note_data_written(env.db, rel, "tree")


def _bench_groups_tree(ctx: Ctx, env: _Env, label: str, k: int, partitions: int) -> None:
    """树模型：K 由 SERIESSLOTID 实测、分区数由 COUNT TIMESLOTID 实测 ⇒ 组数可精确判定。"""
    want = min(env.cap_d, max(min(env.min_d, partitions), k))
    expect_groups(ctx, f"{label}（K={k}、分区数={partitions} ⇒ min(R,max(min(minNum,|P|),K))）",
                  env.db, env.dialect, data=want)
    got = ctx.api.db_group_num(env.db, "DATA", dialect=env.dialect)
    ctx.check(f"组数封顶 = 上限（分区/测点增长不得突破 R={env.cap_d}）", got <= env.cap_d,
              f"组数={got}")


def _bench_groups_table(ctx: Ctx, env: _Env, label: str, k: int) -> None:
    """表模型：方言不支持 ``SHOW REGIONID/TIMESLOTID``（AstBuilder 抛 SemanticException）⇒
    只断言库详情计数与 ``SHOW REGIONS`` 去重一致、不超上限、且落在公式允许的取值集合里。

    单设备 K=1 时组数 = ``min(R, max(min(minNum,|P|),1))``：``|P|`` 是该请求引入的新时间分区数，
    不可观测 ⇒ 结果只能是 ``min(1,R)``（未跨分区）或 ``min(minNum,R)``（跨了分区）；两者都由公式给出。
    """
    possible = sorted({min(k, env.cap_d), min(env.min_d, env.cap_d)})
    detail = ctx.api.db_group_num(env.db, "DATA", dialect=env.dialect)
    dedup = ctx.api.group_count(env.db, kind="DATA", dialect=env.dialect)
    ctx.check(f"{label}：DataRegionGroupNum ∈ {possible}（K={k} ⇒ min(K,R) 或 min(minNum,R)）",
              detail in possible, f"实测详情={detail}、公式允许集合={possible}")
    ctx.check("表模型 SHOW DATABASES DETAILS 与 SHOW REGIONS 去重口径一致",
              detail >= 0 and detail == dedup, f"详情={detail}、区域去重={dedup}")
    ctx.check(f"组数不超上限 R={env.cap_d}", detail <= env.cap_d, f"实测={detail}")
    expect_groups(ctx, f"{label}（Schema 组只由 slot 数决定）", env.db, env.dialect,
                  schema=min(k, env.cap_s))


# ================================================================ PG-MSR 用例
def case_msr01_tree_1x1(ctx: Ctx) -> None:
    """MSR-01 树模型 1 设备 × 1 测点：组数只由 **1 个 slot** 决定（min(1,R)）。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    device = device_set(ctx, env.db, 1)[0]
    _expect_tree_slots(ctx, "1 个设备名", env.db, [device], 1)
    _tree_row(ctx, env, device, (TREE_SENSOR,), 1)
    _expect_k(ctx, env, "DATA", 1, "1 设备 × 1 测点只占 1 个 slot")
    _expect_k(ctx, env, "SCHEMA", 1, "1 设备 × 1 测点只占 1 个 slot")
    expect_groups(ctx, "1 设备 × 1 测点（测点数不增加 slot ⇒ min(1,R)）", env.db, env.dialect,
                  schema=min(1, env.cap_s), data=min(1, env.cap_d))
    rows = ctx.api.count_rows(f"{env.db}.{device}.{TREE_SENSOR}", dialect="tree")
    ctx.check("行数 = 1", rows == 1, f"实测={rows}")
    _expect_value(ctx, "抽样值 s0=1", f"select s0 from {env.db}.{device} where time=1", "tree", "s0", 1.0)


def case_msr02_table_1x1(ctx: Ctx) -> None:
    """MSR-02 表模型 1 表 1 TAG × 1 FIELD：与树同口径（1 个 slot ⇒ min(1,R)）。"""
    env = _prepare(ctx, "table")
    if env is None:
        return
    tag = device_set(ctx, env.db, 1, dialect="table", prefix="pgt")[0]
    _expect_table_slots(ctx, "1 个 TAG", [tag], 1)
    _table_row(ctx, env, TABLE, tag, 1, 1)
    expect_groups(ctx, "表模型 1 设备 × 1 测点（min(1,R)）", env.db, env.dialect,
                  schema=min(1, env.cap_s), data=min(1, env.cap_d))
    rows = ctx.api.count_rows(f"{env.db}.{TABLE}", dialect="table")
    ctx.check("行数 = 1", rows == 1, f"实测={rows}")
    _expect_value(ctx, "抽样值 s0=1", f"select s0 from {env.db}.{TABLE} where devid='{tag}'",
                  "table", "s0", 1.0)


def case_msr03_tree_1x10_three_partitions(ctx: Ctx) -> None:
    """MSR-03 树模型 1 设备 × 10 测点 × 3 时间分区（同请求）：组数仍 min(1,R)=1。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    device = device_set(ctx, env.db, 1)[0]
    sensors = tuple(f"s{i}" for i in range(10))
    stamps = [env.origin + k * env.interval + 1 for k in range(3)]
    _tree_rows(ctx, env, device, sensors, stamps)
    _expect_k(ctx, env, "DATA", 1, "3 个新时间分区在同一请求里只算 1 个 slot")
    _expect_k(ctx, env, "SCHEMA", 1, "测点数不改变 slot")
    expect_groups(ctx, "1 设备 × 10 测点 × 3 分区（|P|=1、K=1 ⇒ min(1,R)）", env.db, env.dialect,
                  schema=min(1, env.cap_s), data=min(1, env.cap_d))
    series = _series_count(ctx, env, device)
    ctx.check("测点数 = 10（SHOW TIMESERIES 行数）", series == 10, f"实测={series}")
    parts = _partitions_of(ctx, env, device)
    ctx.check("时间分区数 = 3", parts == 3, f"实测={parts}")
    rows = ctx.api.count_rows(f"{env.db}.{device}.{TREE_SENSOR}", dialect="tree")
    ctx.check("行数 = 3（每个分区一行）", rows == 3, f"实测={rows}")
    _expect_value(ctx, "抽样值 s9=10", f"select s9 from {env.db}.{device} where time={stamps[0]}",
                  "tree", "s9", 10.0)


def case_msr04_table_1x10_three_partitions(ctx: Ctx) -> None:
    """MSR-04 表模型 1 TAG × 10 FIELD × 3 时间分区（同请求）：组数仍 min(1,R)。"""
    env = _prepare(ctx, "table")
    if env is None:
        return
    tag = device_set(ctx, env.db, 1, dialect="table", prefix="pgt")[0]
    _create_table(ctx, env, TABLE, 10)
    stamps = [env.origin + k * env.interval + 1 for k in range(3)]
    rows = [(stamp, tag, [float(i + 1) for i in range(10)]) for stamp in stamps]
    _table_rows(ctx, env, TABLE, "devid", rows)
    expect_groups(ctx, "表 1 设备 × 10 测点 × 3 分区（min(1,R)）", env.db, env.dialect,
                  schema=min(1, env.cap_s), data=min(1, env.cap_d))
    total = ctx.api.count_rows(f"{env.db}.{TABLE}", dialect="table")
    ctx.check("行数 = 3", total == 3, f"实测={total}")
    _expect_value(ctx, "抽样值 s9=10", f"select s9 from {env.db}.{TABLE} where devid='{tag}'",
                  "table", "s9", 10.0)


def _msr_tree_ladder(ctx: Ctx, sensors_n: int, samples: tuple[int, ...]) -> None:
    """1 设备 × N 测点（树，单分区）的公共体：组数恒 min(1,R)，测点数由 SHOW TIMESERIES 实测。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    device = device_set(ctx, env.db, 1)[0]
    sensors = tuple(f"s{i}" for i in range(sensors_n))
    _tree_row(ctx, env, device, sensors, 1)
    _expect_k(ctx, env, "DATA", 1, f"{sensors_n} 个测点不增加 slot")
    _expect_k(ctx, env, "SCHEMA", 1, f"{sensors_n} 个测点不增加 slot")
    expect_groups(ctx, f"1 设备 × {sensors_n} 测点（测点数不改变 slot ⇒ min(1,R)）",
                  env.db, env.dialect, schema=min(1, env.cap_s), data=min(1, env.cap_d))
    series = _series_count(ctx, env, device)
    ctx.check(f"测点数 = {sensors_n}（SHOW TIMESERIES 行数）", series == sensors_n, f"实测={series}")
    for index in samples:
        _expect_value(ctx, f"抽样值 s{index}={index + 1}",
                      f"select s{index} from {env.db}.{device} where time=1",
                      "tree", f"s{index}", float(index + 1))


def case_msr05_tree_1x100(ctx: Ctx) -> None:
    """MSR-05 树模型 1 设备 × 100 测点：组数仍 min(1,R)=1（小规模 SQL 写）。"""
    _msr_tree_ladder(ctx, 100, (0, 49, 99))


def case_msr06_table_1x100(ctx: Ctx) -> None:
    """MSR-06 表模型 1 TAG × 100 FIELD：组数仍 min(1,R)=1。"""
    env = _prepare(ctx, "table")
    if env is None:
        return
    tag = device_set(ctx, env.db, 1, dialect="table", prefix="pgt")[0]
    _expect_table_slots(ctx, "1 个 TAG", [tag], 1)
    _table_row(ctx, env, TABLE, tag, 1, 100)
    expect_groups(ctx, "表模型 1 设备 × 100 测点（min(1,R)）", env.db, env.dialect,
                  schema=min(1, env.cap_s), data=min(1, env.cap_d))
    total = ctx.api.count_rows(f"{env.db}.{TABLE}", dialect="table")
    ctx.check("行数 = 1", total == 1, f"实测={total}")
    for index in (0, 49, 99):
        _expect_value(ctx, f"抽样值 s{index}={index + 1}",
                      f"select s{index} from {env.db}.{TABLE} where devid='{tag}'",
                      "table", f"s{index}", float(index + 1))


def case_msr07_tree_1x1000(ctx: Ctx) -> None:
    """MSR-07 树模型 1 设备 × 1000 测点：**测点数不增加 slot**，组数仍 min(1,R)=1。"""
    _msr_tree_ladder(ctx, 1000, (0, 499, 999))


def case_msr08_table_1x1000(ctx: Ctx) -> None:
    """MSR-08 表模型 1 TAG × 1000 FIELD：组数仍 min(1,R)=1。"""
    env = _prepare(ctx, "table")
    if env is None:
        return
    tag = device_set(ctx, env.db, 1, dialect="table", prefix="pgt")[0]
    _expect_table_slots(ctx, "1 个 TAG", [tag], 1)
    _table_row(ctx, env, TABLE, tag, 1, 1000)
    expect_groups(ctx, "表模型 1 设备 × 1000 测点（min(1,R)）", env.db, env.dialect,
                  schema=min(1, env.cap_s), data=min(1, env.cap_d))
    total = ctx.api.count_rows(f"{env.db}.{TABLE}", dialect="table")
    ctx.check("行数 = 1", total == 1, f"实测={total}")
    for index in (0, 499, 999):
        _expect_value(ctx, f"抽样值 s{index}={index + 1}",
                      f"select s{index} from {env.db}.{TABLE} where devid='{tag}'",
                      "table", f"s{index}", float(index + 1))


def _msr_bench_single_device(ctx: Ctx, model: str, sensor_number: int, duration_ms: int,
                             tag: str) -> None:
    """1 设备 × N 测点的大规模公共体（benchmark；K 必须由产品侧 SERIESSLOTID 实测）。"""
    env = _prepare(ctx, model)
    if env is None:
        return
    if not _bench_precheck(ctx, "v20"):
        return
    bench_db = env.db.split(".")[-1] if model == "tree" else env.db
    if not _bench_write(ctx, dialect=env.dialect, db_name=bench_db, device_number=1,
                        sensor_number=sensor_number, duration_ms=duration_ms, tag=tag):
        return
    env.db = _locate_bench_db(ctx, env.db, env.dialect)
    _refresh_caps(ctx, env)
    label = f"1 设备 × {sensor_number} 测点（benchmark）"
    if model == "tree":
        # 树模型：K 与时间分区数都能在产品侧实测 ⇒ 组数可精确判定
        k = _slot_k(ctx, env, "DATA")
        ctx.check(f"{sensor_number} 测点写入后 Data series slot 数 = 1（测点数不增加 slot）",
                  k == 1, f"实测 SHOW DATA SERIESSLOTID 行数={k}")
        _cli_sample_tree(ctx, env)
        partitions = _partitions(ctx, env)
        if partitions < 0:
            ctx.skip(f"无法对 {env.db} 观测 COUNT TIMESLOTID ⇒ 无法按公式判定组数")
            return
        _bench_groups_tree(ctx, env, label, k, partitions)
        _check_schema(ctx, env, "Schema 组只由 slot 数决定（测点数无关）", min(k, env.cap_s),
                      f"K={k} ⇒ min(K,R)")
        return
    # 表模型：方言不支持 SHOW REGIONID/TIMESLOTID（AstBuilder 抛 SemanticException）⇒
    # 只断言 SHOW DATABASES DETAILS / SHOW REGIONS 与写入行数
    k = 1  # DEVICE_NUMBER=1 ⇒ 1 个 TAG = 1 个 slot（结构事实，非"按测点数推断"）
    table = _first_table(ctx, env)
    rows = ctx.api.count_rows(f"{env.db}.{table}", dialect="table") if table else -1
    ctx.check("CLI 侧 COUNT 校验：表行数 > 0（不依赖 benchmark 自报）", rows > 0,
              f"表={table}、行数={rows}")
    if table:
        ctx.note_data_written(env.db, table, "table")  # 收尾②副本对拍查询
    _bench_groups_table(ctx, env, label, k)


def case_msr09_tree_10k_sensors_bench(ctx: Ctx) -> None:
    """MSR-09 树模型 1 设备 × 1 万测点（benchmark）：组数仍 min(K,R)，K=1。"""
    _msr_bench_single_device(ctx, "tree", 10000, 120000, "msr09")


def case_msr10_table_10k_sensors_bench(ctx: Ctx) -> None:
    """MSR-10 表模型 1 设备 × 1 万测点（benchmark）：组数仍 min(K,R)，K=1。"""
    _msr_bench_single_device(ctx, "table", 10000, 120000, "msr10")


def case_msr11_tree_100k_sensors_bench(ctx: Ctx) -> None:
    """MSR-11 树模型 1 设备 × 10 万测点（benchmark，full 档）：组数仍 min(K,R)。"""
    _msr_bench_single_device(ctx, "tree", 100000, 240000, "msr11")


def case_msr12_table_100k_sensors_bench(ctx: Ctx) -> None:
    """MSR-12 表模型 1 设备 × 10 万测点（benchmark，full 档）：组数仍 min(K,R)。"""
    _msr_bench_single_device(ctx, "table", 100000, 240000, "msr12")


def case_msr13_tree_multi_device_multi_sensor(ctx: Ctx) -> None:
    """MSR-13 多设备 × 多测点（树，100 设备 × 100 测点 = 1 万点，SQL）：组数 = min(K,R)、K=100。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    if not _need_slots(ctx, 100, "MSR-13（100 设备）"):
        return
    devices = device_set(ctx, env.db, 100)
    _expect_tree_slots(ctx, "100 个设备名", env.db, devices, 100)
    sensors = tuple(f"s{i}" for i in range(100))
    for index, device in enumerate(devices, start=1):
        _tree_row(ctx, env, device, sensors, index)
    _expect_k(ctx, env, "DATA", 100, "100 个不同 slot 的设备（测点数不参与 K）")
    _expect_k(ctx, env, "SCHEMA", 100, "100 个不同 slot 的设备")
    trace = _Trace(env.min_d, env.cap_d)
    for index in range(1, 101):
        trace.step(1, index)
    expect_groups(ctx, f"100 设备 × 100 测点（逐步 |P|=1、K=1..100 ⇒ {trace.groups}）",
                  env.db, env.dialect, schema=min(100, env.cap_s), data=trace.groups)
    first_series = _series_count(ctx, env, devices[0])
    ctx.check("单设备测点数 = 100", first_series == 100, f"实测={first_series}")
    rows = ctx.api.count_rows(f"{env.db}.{devices[0]}.{TREE_SENSOR}", dialect="tree")
    ctx.check("首个设备行数 = 1", rows == 1, f"实测={rows}")


def case_msr14_table_multi_device_multi_sensor(ctx: Ctx) -> None:
    """MSR-14 多设备 × 多测点（表，100 TAG × 100 FIELD = 1 万点，单请求）：组数 = min(K,R)。"""
    env = _prepare(ctx, "table")
    if env is None:
        return
    if not _need_slots(ctx, 100, "MSR-14（100 TAG）"):
        return
    tags = device_set(ctx, env.db, 100, dialect="table", prefix="pgt")
    _expect_table_slots(ctx, "100 个 TAG", tags, 100)
    _create_table(ctx, env, TABLE, 100)
    rows = [(index + 1, tag, [float(i + 1) for i in range(100)]) for index, tag in enumerate(tags)]
    _table_rows(ctx, env, TABLE, "devid", rows)
    trace = _Trace(env.min_d, env.cap_d)
    want = trace.step(100, 100)   # 单请求：|P|=K=100
    expect_groups(ctx, f"100 TAG × 100 FIELD 单请求（|P|=K=100 ⇒ {want}）", env.db, env.dialect,
                  schema=min(100, env.cap_s), data=want)
    total = ctx.api.count_rows(f"{env.db}.{TABLE}", dialect="table")
    ctx.check("行数 = 100（每个 TAG 一行）", total == 100, f"实测={total}")
    _expect_value(ctx, "抽样值 s99=100（首行）",
                  f"select s99 from {env.db}.{TABLE} where devid='{tags[0]}'", "table", "s99", 100.0)


def case_msr15_tree_10k_devices_bench(ctx: Ctx) -> None:
    """MSR-15 ≥1 万设备（tree benchmark）：K 由产品侧 SERIESSLOTID 实测，组数 = min(K,R)。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    if not _bench_precheck(ctx, "v20"):
        return
    if not _bench_write(ctx, dialect="tree", db_name=env.db.split(".")[-1], device_number=10000,
                        sensor_number=1, duration_ms=240000, tag="msr15"):
        return
    env.db = _locate_bench_db(ctx, env.db, env.dialect)
    _refresh_caps(ctx, env)
    k = _slot_k(ctx, env, "DATA")
    slot_num = int(ctx.cfg.raw("PG_SERIES_SLOT_NUM") or 1000)
    ctx.check("K 由产品侧 SHOW DATA SERIESSLOTID 实测且 1 ≤ K ≤ series_slot_num（不按设备数推断）",
              1 <= k <= slot_num, f"实测 K={k}、series_slot_num={slot_num}")
    _cli_sample_tree(ctx, env)
    partitions = _partitions(ctx, env)
    if partitions < 0:
        ctx.skip(f"无法对 {env.db} 观测时间分区数 ⇒ 无法按公式判定组数")
        return
    _bench_groups_tree(ctx, env, f"1 万设备 × 1 测点（benchmark，实测 K={k}）", k=k, partitions=partitions)


def case_msr16_tree_same_device_partitions_sensors(ctx: Ctx) -> None:
    """MSR-16 同一设备：跨 3 时间分区 + 新增测点 + 新增时间分区，slot 恒为 1。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    device = device_set(ctx, env.db, 1)[0]
    sensors = tuple(f"s{i}" for i in range(10))
    # ① 同一请求内 3 个不同时间分区：|P|=1、K=1 ⇒ min(1,R)=1
    trace = _Trace(env.min_d, env.cap_d)
    _tree_rows(ctx, env, device, sensors, [env.origin + k * env.interval + 1 for k in range(3)])
    _expect_k(ctx, env, "DATA", 1, "多时间分区仍是 1 个 slot")
    _check_data(ctx, env, "① 单请求写 3 个时间分区", trace.step(1, 1), "G=0、|P|=1、K=1 ⇒ 1")
    # ② 新增测点（已有分区）：不建新分区、不增 slot ⇒ 不触发扩容
    more = sensors + ("s10", "s11")
    _tree_row(ctx, env, device, more, env.origin + 1)
    _check_data(ctx, env, "② 同设备新增 2 个测点（已有分区）", trace.step(0, 1), "|P|=0 ⇒ 不触发扩容")
    # ③ 新增时间分区（单独请求）：不增 K，但按 |P|=1 逼近最小组数
    _tree_row(ctx, env, device, sensors, env.origin + 3 * env.interval + 1)
    _check_data(ctx, env, "③ 单独请求写新时间分区", trace.step(1, 1),
                f"|P|=1、K=1 ⇒ 累计 {trace.groups}")
    expect_groups(ctx, f"最终（测点数与分区数都不改变 slot 数 ⇒ {trace.groups}）",
                  env.db, env.dialect, schema=min(1, env.cap_s), data=trace.groups)
    series = _series_count(ctx, env, device)
    ctx.check("测点数 = 12（新增测点已建）", series == 12, f"实测={series}")
    parts = _partitions_of(ctx, env, device)
    ctx.check("时间分区数 = 4", parts == 4, f"实测={parts}")
    rows = ctx.api.count_rows(f"{env.db}.{device}.{TREE_SENSOR}", dialect="tree")
    ctx.check("行数 = 4", rows == 4, f"实测={rows}")


# =============================================================== PG-TIME 用例
def case_time01_same_slot_new_partition_growth(ctx: Ctx) -> None:
    """TIME-01 同 slot 新时间分区：不增 K，但 |P|=1 增量逼近最小组数（关键公式）。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    device = device_set(ctx, env.db, 1)[0]
    trace = _Trace(env.min_d, env.cap_d)
    for index in range(3):
        stamp = env.origin + index * env.interval + 1
        _tree_row(ctx, env, device, (TREE_SENSOR,), stamp)
        _check_data(ctx, env, f"第 {index + 1} 个时间分区写入后", trace.step(1, 1),
                    "|P|=1、K=1 ⇒ min(R,max(min(minNum,G+1),1))")
    expect_groups(ctx, f"同 slot 多时间分区（3 次 |P|=1 后 ⇒ {trace.groups}，与分区数无关）",
                  env.db, env.dialect, schema=min(1, env.cap_s), data=trace.groups)
    parts = _partitions_of(ctx, env, device)
    ctx.check("COUNT TIMESLOTID = 3（3 个时间分区）", parts == 3, f"实测={parts}")
    rows = ctx.api.count_rows(f"{env.db}.{device}.{TREE_SENSOR}", dialect="tree")
    ctx.check("行数 = 3", rows == 3, f"实测={rows}")


def case_time02_batch_existing_slots_new_partition(ctx: Ctx) -> None:
    """TIME-02 K 个已存在 slot 同时写新时间分区：|P|=K 也只按公式补组。"""
    env = _prepare(ctx, "table")
    if env is None:
        return
    if not _need_slots(ctx, 3, "TIME-02（3 个互异 slot）"):
        return
    tags = device_set(ctx, env.db, 3, dialect="table", prefix="pgt")
    _expect_table_slots(ctx, "3 个 TAG", tags, 3)
    groups = 0
    for index, tag in enumerate(tags, start=1):
        _table_row(ctx, env, TABLE, tag, env.origin + 1, 1)
        want = _predict(env.min_d, env.cap_d, groups, 1, index)
        groups = _check_data(ctx, env, f"第 {index} 个不同 slot 首次写入后", want,
                             f"|P|=1、K={index} ⇒ min(K,R)")
    stamp = env.origin + env.interval + 1
    _table_rows(ctx, env, TABLE, "devid", [(stamp, tag, [float(i + 1)]) for i, tag in enumerate(tags)])
    want = _predict(env.min_d, env.cap_d, groups, 3, 3)
    groups = _check_data(ctx, env, "3 个已存在 slot 同请求写新时间分区", want,
                         f"G={groups}、|P|=3、K=3 ⇒ min(R,max(min(minNum,G+3),3))")
    expect_groups(ctx, "Schema 组不随时间分区变化", env.db, env.dialect, schema=min(3, env.cap_s))
    total = ctx.api.count_rows(f"{env.db}.{TABLE}", dialect="table")
    ctx.check("行数 = 6（3 个 slot × 2 个时间分区）", total == 6, f"实测={total}")


def case_time03_partition_boundary(ctx: Ctx) -> None:
    """TIME-03 时间分区边界：用实测 TimePartitionInterval 算边界，前后各写一行。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    read_back = ctx.api.db_time_partition_interval(env.db, dialect=env.dialect)
    ctx.check("边界按 SHOW DATABASES DETAILS 实测 TimePartitionInterval 计算（未硬编码 604800）",
              read_back == env.interval and env.interval > 0,
              f"读回 interval={read_back}ms、origin={env.origin}ms")
    base = env.origin + env.interval  # 分区 1 的起点
    frames = [("分区0末", base - 1), ("分区1首", base),
              ("分区1末", base + env.interval - 1), ("分区2首", base + env.interval)]
    parts = sorted({_partition_of(stamp, env) for _, stamp in frames})
    ctx.check("4 个边界时间戳落在 3 个时间分区（前后同一分区各一行）", parts == [0, 1, 2],
              f"stamps={[s for _, s in frames]} ⇒ partitions={parts}")
    device = device_set(ctx, env.db, 1)[0]
    trace = _Trace(env.min_d, env.cap_d)
    for label, stamp in frames:
        _tree_row(ctx, env, device, (TREE_SENSOR,), stamp)
        p_count = 0 if label == "分区1末" else 1  # 与"分区1首"同一分区 ⇒ 无缺失分区
        _check_data(ctx, env, f"{label}（stamp={stamp}）写入后", trace.step(p_count, 1),
                    f"|P|={p_count}、K=1 ⇒ min(R,max(min(minNum,G+{p_count}),1))")
    expect_groups(ctx, f"边界前后写入（4 次请求累计 ⇒ {trace.groups}）", env.db, env.dialect,
                  schema=min(1, env.cap_s), data=trace.groups)
    parts = _partitions_of(ctx, env, device)
    ctx.check("COUNT TIMESLOTID = 3", parts == 3, f"实测={parts}")
    rows = ctx.api.count_rows(f"{env.db}.{device}.{TREE_SENSOR}", dialect="tree")
    ctx.check("行数 = 4", rows == 4, f"实测={rows}")
    _expect_value(ctx, "边界上侧取样（分区1首 stamp 的值）",
                  f"select s0 from {env.db}.{device} where time={base}", "tree", "s0", 1.0)


def case_time04_same_slot_across_many_partitions(ctx: Ctx) -> None:
    """TIME-04 跨多个时间分区写同一 slot：组数收敛到 min(minNum,R)，与分区数无关。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    device = device_set(ctx, env.db, 1)[0]
    trace = _Trace(env.min_d, env.cap_d)
    for index in range(6):
        _tree_row(ctx, env, device, (TREE_SENSOR,), env.origin + index * env.interval + 1)
        _check_data(ctx, env, f"第 {index + 1}/6 个时间分区写入后", trace.step(1, 1),
                    "|P|=1、K=1")
    expect_groups(ctx, f"6 个时间分区后（6 次 |P|=1 ⇒ {trace.groups}）", env.db, env.dialect,
                  schema=min(1, env.cap_s), data=trace.groups)
    parts = _partitions_of(ctx, env, device)
    ctx.check("COUNT TIMESLOTID = 6", parts == 6, f"实测={parts}")
    rows = ctx.api.count_rows(f"{env.db}.{device}.{TREE_SENSOR}", dialect="tree")
    ctx.check("行数 = 6", rows == 6, f"实测={rows}")


def case_time05_new_partition_plus_new_slot(ctx: Ctx) -> None:
    """TIME-05 新时间分区 + 新 slot 混合请求：K 取并集（已有 slot 也进 |P|）。"""
    env = _prepare(ctx, "table")
    if env is None:
        return
    if not _need_slots(ctx, 4, "TIME-05（1 基线 + 3 个互异 slot）"):
        return
    newer = device_set(ctx, env.db, 3, dialect="table", prefix="pgn")
    n = _slot_num(ctx)
    taken = {pslots.table_slot(TABLE, [tag], n) for tag in newer}
    first = ""
    for index in range(50):
        candidate = f"pge{index}"
        if pslots.table_slot(TABLE, [candidate], n) not in taken:
            first = candidate
            break
    if not first:
        ctx.skip("无法构造与 3 个新 TAG 不同 slot 的基线 TAG")
        return
    trace = _Trace(env.min_d, env.cap_d)
    _table_row(ctx, env, TABLE, first, env.origin + 1, 1)
    _check_data(ctx, env, "基线 slot 首次写入", trace.step(1, 1), "G=0、|P|=1、K=1")
    request_slots = taken | {pslots.table_slot(TABLE, [first], n)}
    k = len(request_slots)
    stamp = env.origin + env.interval + 1
    _table_rows(ctx, env, TABLE, "devid",
                [(stamp, first, [1.0])] + [(stamp, tag, [float(i + 2)]) for i, tag in enumerate(newer)])
    _check_data(ctx, env, "已有 slot + 3 个新 slot 同请求写新时间分区", trace.step(k, k),
                f"|P|={k}、K={k} ⇒ 并集去重，累计 {trace.groups}")
    expect_groups(ctx, f"混合请求后（|P|=K={k} ⇒ {trace.groups}）", env.db, env.dialect,
                  schema=min(k, env.cap_s), data=trace.groups)
    total = ctx.api.count_rows(f"{env.db}.{TABLE}", dialect="table")
    ctx.check("行数 = 5（基线 1 行 + 混合请求 4 行）", total == 5, f"实测={total}")


def case_time06_show_timeslot_matches_partitions(ctx: Ctx) -> None:
    """TIME-06 SHOW TIMESLOTID 行数与写入分区数一致（DEVICE / DATABASE 两个口径）。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    device = device_set(ctx, env.db, 1)[0]
    trace = _Trace(env.min_d, env.cap_d)
    for index in range(4):
        _tree_row(ctx, env, device, (TREE_SENSOR,), env.origin + index * env.interval + 1)
        trace.step(1, 1)
    by_device = _timeslot_rows(ctx, env, device)
    by_db = _timeslot_rows(ctx, env)
    ctx.check("SHOW TIMESLOTID WHERE DEVICE 行数 = 写入分区数 4", by_device == 4, f"实测={by_device}")
    ctx.check("SHOW TIMESLOTID WHERE DATABASE 行数 = 4（单设备下与 DEVICE 一致）",
              by_db == 4, f"实测={by_db}")
    expect_groups(ctx, f"时间分区不增加 slot（4 次 |P|=1、K=1 ⇒ {trace.groups}）",
                  env.db, env.dialect, schema=min(1, env.cap_s), data=trace.groups)


def case_time07_count_timeslot_consistency(ctx: Ctx) -> None:
    """TIME-07 COUNT TIMESLOTID 口径一致：K 个 slot × P 个分区 ⇒ 库级去重 = P、逐设备 = P。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    if not _need_slots(ctx, 3, "TIME-07（3 个互异 slot）"):
        return
    devices = device_set(ctx, env.db, 3)
    _expect_tree_slots(ctx, "3 个设备名", env.db, devices, 3)
    trace, assigned = _Trace(env.min_d, env.cap_d), set()
    for device in devices:
        assigned.add(pslots.tree_device_slot(env.db, device, _slot_num(ctx)))
        k_now = len(assigned)  # 此刻已分配（有数据）的 slot 数 = K
        for index in range(3):
            _tree_row(ctx, env, device, (TREE_SENSOR,), env.origin + index * env.interval + 1)
            _check_data(ctx, env, f"{device} 第 {index + 1} 个分区后（已分配 {k_now} 个 slot）",
                        trace.step(1, k_now), f"|P|=1、K={k_now}")
    per_device = [_partitions_of(ctx, env, device) for device in devices]
    ctx.check("每个设备 COUNT TIMESLOTID = 3（3 个时间分区）", per_device == [3, 3, 3],
              f"实测={per_device}")
    db_count = _partitions(ctx, env)
    ctx.check("库级 COUNT TIMESLOTID = 3（按时间分区去重，不是 K×P=9）", db_count == 3,
              f"实测={db_count}（K×P=9）")
    ctx.check("逐设备之和 = K×P = 9（两个口径互证）", sum(per_device) == 9,
              f"实测={sum(per_device)}")
    expect_groups(ctx, f"K=3 × P=3 后组数（9 次 |P|=1 ⇒ {trace.groups}）", env.db, env.dialect,
                  schema=min(3, env.cap_s), data=trace.groups)


def case_time08_append_old_partition_no_growth(ctx: Ctx) -> None:
    """TIME-08 老时间分区追加：重复访问已有分区不触发扩容。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    device = device_set(ctx, env.db, 1)[0]
    groups = 0
    for index in range(3):
        _tree_row(ctx, env, device, (TREE_SENSOR,), env.origin + index * env.interval + 1)
        want = _predict(env.min_d, env.cap_d, groups, 1, 1)
        groups = _check_data(ctx, env, f"首次写入第 {index + 1} 个分区", want, f"|P|=1、K=1")
    before = groups
    for index in (0, 1):
        _tree_row(ctx, env, device, (TREE_SENSOR,), env.origin + index * env.interval + 2)
        groups = _check_data(ctx, env, f"老分区 {index} 追加一行",
                             _predict(env.min_d, env.cap_d, groups, 0, 1),
                             "已有分区 ⇒ |P|=0、不触发扩容")
    ctx.check("老分区追加不建新组", groups == before, f"追加前={before}、追加后={groups}")
    parts = _partitions_of(ctx, env, device)
    ctx.check("COUNT TIMESLOTID 仍为 3（未新增时间分区）", parts == 3, f"实测={parts}")
    rows = ctx.api.count_rows(f"{env.db}.{device}.{TREE_SENSOR}", dialect="tree")
    ctx.check("行数 = 5（3 首次 + 2 追加）", rows == 5, f"实测={rows}")


def case_time09_out_of_order_writes(ctx: Ctx) -> None:
    """TIME-09 乱序写（老分区新数据）：组数与老分区映射都不变。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    device = device_set(ctx, env.db, 1)[0]
    groups, seen = 0, set()
    for index in (3, 0, 2, 1):
        stamp = env.origin + index * env.interval + 1
        _tree_row(ctx, env, device, (TREE_SENSOR,), stamp)
        p_count = 0 if index in seen else 1
        seen.add(index)
        groups = _check_data(ctx, env, f"乱序写入分区 {index}", _predict(env.min_d, env.cap_d, groups, p_count, 1),
                             f"|P|={p_count}、K=1")
    start = env.origin + 1
    end = env.origin + env.interval - 1
    window = f"time >= {start} and time <= {end}"
    mapping_before = ctx.api.device_group(f"{env.db}.{device}", time_range=window)
    _tree_row(ctx, env, device, (TREE_SENSOR,), start + 1)  # 老分区（分区 0）新数据
    groups = _check_data(ctx, env, "老分区 0 补写新数据",
                         _predict(env.min_d, env.cap_d, groups, 0, 1), "已有分区 ⇒ |P|=0")
    mapping_after = ctx.api.device_group(f"{env.db}.{device}", time_range=window)
    ctx.check("老分区映射不变（SHOW DATA REGIONID + timeRange 前后一致）",
              bool(mapping_before) and mapping_before == mapping_after,
              f"before={mapping_before} after={mapping_after}", evidence=f"时间窗口 {window}")
    parts = _partitions_of(ctx, env, device)
    ctx.check("COUNT TIMESLOTID = 4（乱序写不新增分区）", parts == 4, f"实测={parts}")
    rows = ctx.api.count_rows(f"{env.db}.{device}.{TREE_SENSOR}", dialect="tree")
    ctx.check("行数 = 5", rows == 5, f"实测={rows}")


def case_time10_partitions_do_not_grow_unbounded(ctx: Ctx) -> None:
    """TIME-10 分区数增长不使组数无限增长：K=6 时组数停在 min(K,R)，且从不超 R。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    if not _need_slots(ctx, 6, "TIME-10（6 个互异 slot）"):
        return
    devices = device_set(ctx, env.db, 6)
    _expect_tree_slots(ctx, "6 个设备名", env.db, devices, 6)
    trace = _Trace(env.min_d, env.cap_d)
    for index, device in enumerate(devices, start=1):  # 第一轮：逐个新 slot
        _tree_row(ctx, env, device, (TREE_SENSOR,), env.origin + 1)
        _check_data(ctx, env, f"第 {index}/6 个新 slot", trace.step(1, index), f"|P|=1、K={index}")
    for index in (1, 2, 3):  # 后续轮次：每个已有 slot 各写一个新时间分区（6 个独立请求）
        for device in devices:
            _tree_row(ctx, env, device, (TREE_SENSOR,), env.origin + index * env.interval + 1)
        for _ in range(6):
            want = trace.step(1, 6)
        _check_data(ctx, env, f"第 {index + 1} 轮（6 个请求，各 |P|=1、K=6）", want,
                    f"累计期望={want}")
        ctx.check(f"第 {index + 1} 轮组数不超上限 R={env.cap_d}", want <= env.cap_d, f"期望={want}")
    expect_groups(ctx, f"6 slot × 4 时间分区（分区数增长不突破上限 ⇒ {trace.groups}）",
                  env.db, env.dialect, schema=min(6, env.cap_s), data=trace.groups)
    parts = _partitions(ctx, env)
    ctx.check("库级 COUNT TIMESLOTID = 4（所有 slot 共用 4 个分区）", parts == 4, f"实测={parts}")


def case_time11_table_same_tag_new_partition(ctx: Ctx) -> None:
    """TIME-11 表模型同 TAG 新时间分区：与树模型同口径（不增 K，按 |P|=1 补组）。"""
    env = _prepare(ctx, "table")
    if env is None:
        return
    tag = device_set(ctx, env.db, 1, dialect="table", prefix="pgt")[0]
    trace = _Trace(env.min_d, env.cap_d)
    for index in range(3):
        _table_row(ctx, env, TABLE, tag, env.origin + index * env.interval + 1, 1)
        _check_data(ctx, env, f"表模型第 {index + 1} 个时间分区", trace.step(1, 1), "|P|=1、K=1")
    expect_groups(ctx, f"表模型同 TAG 多时间分区（3 次 |P|=1 ⇒ {trace.groups}）", env.db, env.dialect,
                  schema=min(1, env.cap_s), data=trace.groups)
    total = ctx.api.count_rows(f"{env.db}.{TABLE}", dialect="table")
    ctx.check("行数 = 3", total == 3, f"实测={total}")


def case_time12_hundred_partitions_single_device(ctx: Ctx) -> None:
    """TIME-12 单设备 100 个时间分区：组数收敛到 min(minNum,R)，不随分区数增长。"""
    env = _prepare(ctx, "tree")
    if env is None:
        return
    device = device_set(ctx, env.db, 1)[0]
    trace = _Trace(env.min_d, env.cap_d)
    for index in range(100):
        _tree_row(ctx, env, device, (TREE_SENSOR,), env.origin + index * env.interval + 1)
        _check_data(ctx, env, f"第 {index + 1}/100 个时间分区", trace.step(1, 1),
                    "|P|=1、K=1 ⇒ 收敛到 min(minNum,R)")
    cap_min = min(env.cap_d, env.min_d)
    ctx.check("100 个 |P|=1 请求足够收敛到 min(minNum,R)（源码口径；catalog 写『组数仍 1』与公式不符）",
              trace.groups == cap_min, f"公式终值={trace.groups}、min(minNum={env.min_d},R={env.cap_d})={cap_min}")
    expect_groups(ctx, f"单设备 100 个时间分区（按公式应为 {trace.groups}，不是 1）",
                  env.db, env.dialect, schema=min(1, env.cap_s), data=trace.groups)
    parts = _partitions_of(ctx, env, device)
    ctx.check("COUNT TIMESLOTID = 100", parts == 100, f"实测={parts}")
    rows = ctx.api.count_rows(f"{env.db}.{device}.{TREE_SENSOR}", dialect="tree")
    ctx.check("行数 = 100", rows == 100, f"实测={rows}")


# ===================================================================== registry
SPECS.extend([
    CaseSpec("PG-MSR-01", "测点规模", "tree", "1 设备 × 1 测点：组数只由 1 个 slot 决定（min(1,R)）",
             "P0", case_msr01_tree_1x1, gate=True, note="tier=core"),
    CaseSpec("PG-MSR-02", "测点规模", "table", "表模型 1 设备 × 1 测点（与树同口径）",
             "P1", case_msr02_table_1x1, note="tier=core"),
    CaseSpec("PG-MSR-03", "测点规模", "tree", "1 设备 × 10 测点 × 3 时间分区（同请求）仍 min(1,R)",
             "P1", case_msr03_tree_1x10_three_partitions, note="tier=core"),
    CaseSpec("PG-MSR-04", "测点规模", "table", "表模型 1 设备 × 10 测点 × 3 时间分区仍 min(1,R)",
             "P1", case_msr04_table_1x10_three_partitions, note="tier=core"),
    CaseSpec("PG-MSR-05", "测点规模", "tree", "1 设备 × 100 测点：测点数不增加 slot",
             "P1", case_msr05_tree_1x100, note="tier=core"),
    CaseSpec("PG-MSR-06", "测点规模", "table", "表模型 1 设备 × 100 测点",
             "P1", case_msr06_table_1x100, note="tier=core"),
    CaseSpec("PG-MSR-07", "测点规模", "tree", "1 设备 × 1000 测点：组数仍 min(1,R)",
             "P0", case_msr07_tree_1x1000, note="tier=core"),
    CaseSpec("PG-MSR-08", "测点规模", "table", "表模型 1 设备 × 1000 测点",
             "P1", case_msr08_table_1x1000, note="tier=core"),
    CaseSpec("PG-MSR-09", "测点规模", "tree", "1 设备 × 1 万测点（benchmark，K 实测=1）",
             "P1", case_msr09_tree_10k_sensors_bench, note="tier=core; benchmark"),
    CaseSpec("PG-MSR-10", "测点规模", "table", "表模型 1 设备 × 1 万测点（benchmark，K 实测=1）",
             "P1", case_msr10_table_10k_sensors_bench, note="tier=core; benchmark"),
    CaseSpec("PG-MSR-11", "测点规模", "tree", "1 设备 × 10 万测点（benchmark，full 档）",
             "P2", case_msr11_tree_100k_sensors_bench, note="tier=full; benchmark"),
    CaseSpec("PG-MSR-12", "测点规模", "table", "表模型 1 设备 × 10 万测点（benchmark，full 档）",
             "P2", case_msr12_table_100k_sensors_bench, note="tier=full; benchmark"),
    CaseSpec("PG-MSR-13", "测点规模", "tree", "多设备 × 多测点：100 设备 × 100 测点（K=100）",
             "P1", case_msr13_tree_multi_device_multi_sensor, note="tier=core"),
    CaseSpec("PG-MSR-14", "测点规模", "table", "多设备 × 多测点：100 TAG × 100 FIELD（K=100）",
             "P1", case_msr14_table_multi_device_multi_sensor, note="tier=core"),
    CaseSpec("PG-MSR-15", "测点规模", "tree", "≥1 万设备 × 1 测点（benchmark，K 由产品侧实测）",
             "P2", case_msr15_tree_10k_devices_bench, note="tier=full; benchmark"),
    CaseSpec("PG-MSR-16", "测点规模", "tree", "同一设备跨 3 分区 + 新增测点 + 新增时间分区",
             "P1", case_msr16_tree_same_device_partitions_sensors, note="tier=core"),

    CaseSpec("PG-TIME-01", "时间分区", "tree", "同 slot 新时间分区按 T=min(R,max(min(minNum,G+|P|),K)) 补组",
             "P0", case_time01_same_slot_new_partition_growth, gate=True, note="tier=core"),
    CaseSpec("PG-TIME-02", "时间分区", "table", "K 个已存在 slot 同时写新时间分区",
             "P1", case_time02_batch_existing_slots_new_partition, note="tier=core"),
    CaseSpec("PG-TIME-03", "时间分区", "tree", "时间分区边界由实测 TimePartitionInterval 计算",
             "P0", case_time03_partition_boundary, note="tier=core"),
    CaseSpec("PG-TIME-04", "时间分区", "tree", "同一 slot 跨 6 个时间分区（组数不随分区增长）",
             "P1", case_time04_same_slot_across_many_partitions, note="tier=core"),
    CaseSpec("PG-TIME-05", "时间分区", "table", "新时间分区 + 新 slot 混合请求：K 取并集",
             "P1", case_time05_new_partition_plus_new_slot, note="tier=core"),
    CaseSpec("PG-TIME-06", "时间分区", "tree", "SHOW TIMESLOTID 行数 = 写入分区数（DEVICE/DATABASE）",
             "P1", case_time06_show_timeslot_matches_partitions, note="tier=core"),
    CaseSpec("PG-TIME-07", "时间分区", "tree", "COUNT TIMESLOTID 口径一致（库级去重 = P、逐设备 = P）",
             "P1", case_time07_count_timeslot_consistency, note="tier=core"),
    CaseSpec("PG-TIME-08", "时间分区", "tree", "老时间分区追加：已有分区不触发扩容",
             "P1", case_time08_append_old_partition_no_growth, note="tier=core"),
    CaseSpec("PG-TIME-09", "时间分区", "tree", "乱序写（老分区新数据）：组数与老分区映射不变",
             "P1", case_time09_out_of_order_writes, note="tier=core"),
    CaseSpec("PG-TIME-10", "时间分区", "tree", "分区数增长不使组数无限增长（封顶 min(K,R)）",
             "P0", case_time10_partitions_do_not_grow_unbounded, note="tier=core"),
    CaseSpec("PG-TIME-11", "时间分区", "table", "表模型同 TAG 新时间分区（与树同口径）",
             "P1", case_time11_table_same_tag_new_partition, note="tier=core"),
    CaseSpec("PG-TIME-12", "时间分区", "tree", "单设备 100 个时间分区：组数收敛到 min(minNum,R)",
             "P1", case_time12_hundred_partitions_single_device, note="tier=core"),
])
