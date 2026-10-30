"""PG-UPG（1.3 → 2.0 升级族）用例集。

阶段分组由 conf 键 ``PG_UPG_PHASE`` 决定（``pre`` / ``post`` / 空）：
阶段不匹配的用例 ``ctx.skip("请在 PG_UPG_PHASE=<pre|post> 档位下运行")`` —— SKIP 不是 PASS。

* ``pre``（PG-UPG-01..07）：1.3 集群上的**升级前基线**，重点是"1.3 默认 AUTO
  不积极扩容"（6 个不同 slot 只到最小组数）。
* ``post``（PG-UPG-08..16）：2.0 集群上的**升级后行为**，核心是"同一份 conf
  （没有策略键）在 2.0 下默认变成 PROACTIVE"。

证据分三层：

1. ``pgkit.upgrade`` 写的 ``upgrade_pre.json`` / ``upgrade_post.json``（版本号、conf
   策略键读回、库组数观测、回滚点）；
2. 本模块用 ``record_fact`` 累积的 ``upg_<phase>_facts.json``（设备清单、slot、
   行数、设备→组映射、库详情快照）——同时写本轮 run_dir 与
   ``<RESULT_DIR>/pg_upgrade/`` 稳定副本，因为 ``upgrade`` 与 ``run`` 是两个命令、
   run_dir 不同；
3. 每个用例自己的 ``evidence/*.json``（走查用）。

判定纪律与 ``cases.py`` 完全一致：``ctx.check`` 记断言、收尾三件套自动追加。
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from . import compat13
from . import pgapi
from . import slots as pslots
from .cases import (
    CaseSpec,
    Ctx,
    detect_v13,
    device_set,
    ensure_write_tree,
    expect_cap,
    expect_groups,
    expected_cap,
    reset_db,
    write_devices,
)

#: 升级族使用的（树模型）库名。**跨阶段稳定**：post 用例靠这些名字找升级前的数据。
DB_MAIN = "root.pg_upg_main"     # 01：1 设备 1 测点基线
DB_AUTO = "root.pg_upg_auto"     # 02/09/12/13：AUTO 基线 / 升级后 PROACTIVE 扩容
DB_TP = "root.pg_upg_tp"         # 04/10：时间分区
DB_MULTI = ("root.pg_upg_m1", "root.pg_upg_m2", "root.pg_upg_m3")  # 05：多库分摊
DB_RECREATE = "root.pg_upg_recreate"  # 14：升级后 drop/重建
DB_SCHEMA = "root.pg_upg_schema"      # 16：升级后 Schema 侧扩容

AUTO_DEVICES = 6      # 02：AUTO 基线写入的不同 slot 数（K）
NEW_DEVICES = 6       # 09：升级后新增的不同 slot 数（K'）
SCHEMA_DEVICES = 5    # 16：Schema 侧扩容的 K

SLOT_MISMATCH = "请在 PG_UPG_PHASE=<pre|post> 档位下运行"
SYSTEM_MARKERS = ("root.__system", "root.__audit", "__audit", "information_schema")

#: 激活态缓存（DB_DIR → 探测结果），避免每例都查一次。
_ACT_CACHE: dict[str, dict] = {}


def _sql_health(ctx: Ctx) -> dict:
    """**一条** ``SHOW CLUSTER`` 同时判定：集群是否已激活、SQL 通道是否真的可用。

    升级族的源版本是 **1.3.7 < 2.0.10.1**，按环境激活策略
    （``/data/deepseek/ai-bug-verify/skills/timechodb-rn-verify/references/activation.md`` 规则 2）
    内置 ``03`` 试用码**不受支持**，必须用绑定机器的 ``00``/``01`` 正式码。
    未激活的集群只允许查询，升级用例（要写入并落盘升级前数据）不可能得出有效结论 ⇒ 整族 SKIP，
    绝不写成 PASS（也不能因环境限制写成 FAIL）。

    UPG-1.3: 同时把"语句能不能真的执行"纳入前置。pg_upg13_run 里每条语句都返回
    ``ErrorCan't execute sql because801: Authentication failed.``（1.3 默认密码是
    ``root``，conf 里却是 2.x 的 ``TimechoDB@2021``）或 ``Require more params input …
    usage: IoTDB``（1.3 的 start-cli.sh 不认 ``-sql_dialect``）；旧实现既没把 801 判成
    错误，也不检查这些前置，于是 16 例一路跑成 7 FAIL —— 那是**环境/凭据问题**，
    按本技能的判定纪律应整体 SKIP 并写明原因，不是产品结论。
    """
    key = (ctx.cfg.raw("DB_DIR") or "default").strip()
    cached = _ACT_CACHE.get(key)
    if cached is not None:
        return cached
    status = {"activated": True, "sql_ok": True, "detail": "", "notes": []}
    try:
        outcome = ctx.api.run("show cluster")
        output = outcome.output or ""
        status["notes"] = list(getattr(ctx.sql, "notes", []) or [])
        if compat13.looks_like_auth_error(output):
            status["sql_ok"] = False
            status["detail"] = (
                f"SQL 认证失败（801 Authentication failed；DB_USER="
                f"{ctx.cfg.raw('DB_USER') or 'root'}）；1.3 的默认密码是 root，"
                f"2.0 起才是 TimechoDB@2021。原始回复：{' '.join(output.split())[:300]}")
        elif compat13.looks_like_cli_usage_error(output):
            status["sql_ok"] = False
            status["detail"] = (
                "SQL 语句从未执行：start-cli.sh 打印了用法提示"
                f"（Require more params input … usage: IoTDB …）："
                f"{' '.join(output.split())[:300]}")
        elif not outcome.ok:
            status["sql_ok"] = False
            status["detail"] = f"show cluster 失败：{' '.join(output.split())[:300]}"
        if "UNACTIVATED" in output.upper():
            status["activated"] = False
    except Exception as exc:  # noqa: BLE001 - 查询失败不拦（保持旧口径）
        status["notes"] = list(getattr(ctx.sql, "notes", []) or [])
        status["detail"] = f"show cluster 异常：{exc}"
    _ACT_CACHE[key] = status
    return status


def _activated(ctx: Ctx) -> bool:
    """集群是否已激活（查不到就当作已激活，避免误 SKIP）。"""
    return bool(_sql_health(ctx).get("activated", True))



# --------------------------------------------------------------------- 阶段/证据
def phase_of(ctx: Ctx) -> str:
    return (ctx.cfg.raw("PG_UPG_PHASE") or "").strip().lower()


def need_phase(ctx: Ctx, wanted: str) -> bool:
    """阶段不匹配 ⇒ skip（不判 PASS），返回 False。"""
    got = phase_of(ctx)
    if got != wanted:
        ctx.skip(f"{SLOT_MISMATCH}（当前 PG_UPG_PHASE={got or '空'}，本用例属于 {wanted}）")
        return False
    health = _sql_health(ctx)
    if not health.get("sql_ok", True):
        # UPG-1.3: SQL 通道不可用（801 认证 / CLI 参数被拒 / show cluster 失败）⇒ 整族 SKIP。
        # 旧实现在这里直接往下跑，把"语句从未执行"读成 count=-1、组数=-1，最终产出 7 条
        # 假 FAIL。凭据/参数问题不是产品结论。
        ctx.skip("环境/凭据限制：SQL 通道不可用 ⇒ 升级族整体 SKIP（非产品结论）。"
                 + str(health.get("detail") or ""))
        return False
    if not health.get("activated", True):
        ctx.skip("环境限制：升级源版本 1.3.7 < 2.0.10.1，内置 03 试用码不受支持，需 00/01 正式码"
                 "（绑定机器，见 timechodb-rn-verify/references/activation.md 规则 2）；"
                 "集群未激活无法写入 ⇒ 升级族整体 SKIP（非产品结论）")
        return False
    for note in health.get("notes") or []:
        ctx.note(f"    {note}")
    return True


def _stable_evidence_dir(ctx: Ctx) -> Path | None:
    """``<RESULT_DIR>/pg_upgrade/``（不可写时退回技能内 ``results/pg_upgrade/``）。"""
    for candidate in (Path(ctx.cfg.result_dir) / "pg_upgrade",
                      Path(__file__).resolve().parents[2] / "results" / "pg_upgrade"):
        try:
            candidate.mkdir(parents=True, exist_ok=True)
            return candidate
        except OSError:
            continue
    return None


def evidence_dirs(ctx: Ctx) -> list[Path]:
    """证据查找顺序：显式 conf 键 → 稳定目录 → 本轮 run_dir → 其它 run_dir（新→旧）。"""
    dirs: list[Path] = []
    explicit = (ctx.cfg.raw("PG_UPG_EVIDENCE_DIR") or "").strip()
    if explicit:
        dirs.append(Path(explicit).expanduser())
    stable = _stable_evidence_dir(ctx)
    if stable is not None:
        dirs.append(stable)
    dirs.append(Path(ctx.run_dir))
    try:
        root = Path(ctx.cfg.result_dir)
        for entry in sorted(root.glob("*"), key=lambda p: p.stat().st_mtime, reverse=True):
            if entry.is_dir():
                dirs.append(entry)
    except OSError:
        pass
    dirs.append(Path(__file__).resolve().parents[2] / "results")
    seen: list[Path] = []
    for directory in dirs:
        if directory not in seen:
            seen.append(directory)
    return seen


def find_evidence(ctx: Ctx, name: str) -> Path | None:
    for directory in evidence_dirs(ctx):
        candidate = directory / name
        if candidate.is_file():
            return candidate
    return None


def upstream_evidence(ctx: Ctx, name: str) -> dict:
    """读 ``pgkit.upgrade`` 写的证据文件；找不到返回 ``{}``。"""
    path = find_evidence(ctx, name)
    if path is None:
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        ctx.note(f"    WARN: 证据 {path} 读取失败：{exc}")
        return {}
    ctx.note(f"    读取证据 {path}")
    return data if isinstance(data, dict) else {}


def facts_file(ctx: Ctx, phase: str = "") -> Path:
    return Path(ctx.run_dir) / f"upg_{phase or phase_of(ctx)}_facts.json"


def record_fact(ctx: Ctx, key, value=None) -> dict:
    """累积本阶段事实；同时写稳定副本，供另一个 run_dir 里的 post 用例读取。"""
    path = facts_file(ctx)
    data: dict = {}
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            data = {}
    data.setdefault("phase", phase_of(ctx))
    data["updated_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(key, dict):
        data.update(key)
    else:
        data[key] = value
    text = json.dumps(data, ensure_ascii=False, indent=2)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    except OSError as exc:
        ctx.note(f"    WARN: 写 {path} 失败：{exc}")
    stable = _stable_evidence_dir(ctx)
    if stable is not None:
        try:
            (stable / path.name).write_text(text, encoding="utf-8")
        except OSError:
            pass
    ctx.note(f"    事实记录 {key if isinstance(key, str) else '批量'} → {path.name}")
    return data


def load_facts(ctx: Ctx, phase: str) -> dict:
    name = f"upg_{phase}_facts.json"
    for directory in ([Path(ctx.run_dir)] + evidence_dirs(ctx)):
        candidate = directory / name
        if candidate.is_file():
            try:
                data = json.loads(candidate.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            return data if isinstance(data, dict) else {}
    return {}


def load_pre_facts(ctx: Ctx) -> dict:
    return load_facts(ctx, "pre")


def add_targets(ctx: Ctx, mapping: dict[str, int]) -> None:
    """把 ``目标 → 期望行数`` 并入本阶段 targets（供 06/15 对拍）。"""
    merged = dict(load_facts(ctx, phase_of(ctx)).get("targets") or {})
    merged.update(mapping)
    record_fact(ctx, "targets", merged)


def write_case_evidence(ctx: Ctx, name: str, payload: dict) -> Path:
    directory = Path(ctx.case_dir) / "evidence"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    ctx.note(f"    证据写出 {path}")
    return path


# ------------------------------------------------------------------- 策略读回
def read_policy_key(ctx: Ctx, key: str) -> dict[str, str]:
    """逐主机读**生效** conf 里该键的值；只返回真的有该键的主机。"""
    found: dict[str, str] = {}
    for host in ctx.cfg.all_hosts:
        value = ctx.props.read(host, keys=(key,)).get(key)
        if value is not None:
            found[host] = value
    return found


def policy_state(ctx: Ctx) -> tuple[str, dict]:
    keys = ("schema_region_group_extension_policy", "data_region_group_extension_policy")
    per_host: dict[str, dict[str, str]] = {}
    for host in ctx.cfg.all_hosts:
        try:
            per_host[host] = ctx.props.read(host, keys=keys)
        except Exception as exc:  # noqa: BLE001 - 读不到也要留证
            per_host[host] = {"_error": str(exc)}
    values = {v for entry in per_host.values() for k, v in entry.items()
              if not k.startswith("_")}
    if not values:
        state = "absent"
    elif len(values) == 1:
        state = values.pop()
    else:
        state = "mixed:" + ",".join(sorted(values))
    return state, per_host


def post_is_proactive(ctx: Ctx) -> tuple[bool, str]:
    """2.0 侧当前生效的 data 策略是不是 PROACTIVE（无键 ⇒ 代码默认值 PROACTIVE）。"""
    found = read_policy_key(ctx, "data_region_group_extension_policy")
    if not found:
        return True, "conf 无该键 ⇒ 2.0 代码默认值 PROACTIVE"
    values = set(found.values())
    return values == {"PROACTIVE"}, f"conf 显式写入 {sorted(values)}"


# ---------------------------------------------------- UPG-1.3 兼容观测层
# 1.3 与 2.x 的**可观测口径**不同；下面每个 helper 都只做一件事：
# 用 1.3 也成立的写法取同一个事实，并**在返回值里写明用的是哪个口径**（不伪造、不静默）。
def is_v13(ctx: Ctx) -> tuple[bool, str]:
    """``(是否 1.x 线, 依据)``；见 ``cases.detect_v13``（运行时 show cluster 优先）。"""
    return detect_v13(ctx)


def region_group_probe(ctx: Ctx, db: str, kind: str) -> tuple[int, bool]:
    """``SHOW (SCHEMA|DATA) REGIONS`` 去重出的逻辑组数 ``(组数, 是否可观测)``。

    UPG-1.3: 1.3 同样支持 ``SHOW (DATA|SCHEMA) REGIONS [OF DATABASE db]``
    （包内 ``IoTDBSqlParser$ShowRegionsContext`` 带 SCHEMA/DATA/OF/DATABASE/ON NODEID
    终结符），列里有 ``RegionId|Type|Status|Database|SeriesSlotNum|…``，
    因此"按 RegionId 去重"就是 1.3 上可用的组数口径（2.x 也用它做交叉核对）。
    语句不可用/没有 RegionId 列时返回 ``(-1, False)``，绝不把 0 当成"0 组"。
    """
    outcome = ctx.api.show_regions(db, kind=kind, dialect="tree")
    if not outcome.ok:
        return -1, False
    id_col = ctx.api.column(outcome.rows, *pgapi.REGION_ID_COLUMNS)
    if not id_col:
        return -1, False
    ids = {(row.get(id_col) or "").strip() for row in outcome.rows}
    ids.discard("")
    return len(ids), True


def group_count_compat(ctx: Ctx, db: str, kind: str) -> tuple[int, str]:
    """组数 ``(数量, 口径)``：库详情优先，1.3 上读不到时退回 ``SHOW REGIONS`` 去重。"""
    detail = ctx.api.db_group_num(db, kind, dialect="tree")
    if detail >= 0:
        return detail, "SHOW DATABASES DETAILS"
    dedup, ok = region_group_probe(ctx, db, kind)
    if ok:
        return dedup, "SHOW REGIONS 去重（1.3 等价口径）"
    return -1, "不可观测"


def count_rows_compat(ctx: Ctx, target: str, *, dialect: str = "tree") -> tuple[int, str]:
    """设备行数 ``(行数, 口径)``；1.3 不依赖 2.x 的 ``count(*)`` 输出形态。

    UPG-1.3: 1.3 的稳定写法是 ``select * from <device>``，CLI 末尾会打印
    ``Total line number = N``（1.3 的 ``iotdb-cli`` 里就是这个字符串），直接取 N；
    再兜底 ``select count(s0)``；都失败才返回 ``-1``（不伪造 0）。
    """
    if not is_v13(ctx)[0]:
        return ctx.api.count_rows(target, dialect=dialect), "2.x count(*)"
    outcome = ctx.api.run(f"select * from {target}", dialect=dialect)
    if outcome.ok:
        total = compat13.parse_total_line_number(outcome.output or "")
        if total is not None:
            return total, "1.3 select * + Total line number"
        rows = [r for r in outcome.rows if any((v or "").strip() for v in r.values())]
        if rows:
            return len(rows), "1.3 select * 结果行数"
    fallback = ctx.api.run(f"select count(s0) from {target}", dialect=dialect)
    if fallback.ok:
        counts = []
        for row in fallback.rows:
            for value in row.values():
                try:
                    counts.append(int(float(str(value).strip())))
                except (TypeError, ValueError):
                    continue
        if counts:
            return max(counts), "1.3 select count(s0)"
    return -1, "1.3 计数口径全部失败"


def group_nums_compat(ctx: Ctx, db: str, *, dialect: str = "tree") -> dict:
    """``{schema, data, schema_max, data_max, schema_src, data_src, detail…}``。

    UPG-1.3: 1.3 的 ``SHOW DATABASES DETAILS`` **确实**带
    ``SchemaRegionGroupNum/MaxSchemaRegionGroupNum/DataRegionGroupNum/MaxDataRegionGroupNum``
    （包内 ``ColumnHeaderConstant.showStorageGroupsDetailColumnHeaders``，
    11 列 = 5 个库属性 + 6 个组数/上下限）；只有该语句不可用或列缺失时才退回
    ``SHOW REGIONS`` 去重，并把"用的是哪个口径"写进 ``*_src`` —— 绝不填假数字。
    """
    detail_s = ctx.api.db_group_num(db, "SCHEMA", dialect=dialect)
    detail_d = ctx.api.db_group_num(db, "DATA", dialect=dialect)
    if detail_s >= 0:
        schema, schema_src = detail_s, "SHOW DATABASES DETAILS"
    else:
        schema, dedup_ok = region_group_probe(ctx, db, "SCHEMA")
        schema_src = "SHOW REGIONS 去重（1.3 等价口径）" if dedup_ok else "不可观测"
        schema = schema if dedup_ok else -1
    if detail_d >= 0:
        data, data_src = detail_d, "SHOW DATABASES DETAILS"
    else:
        data, dedup_ok = region_group_probe(ctx, db, "DATA")
        data_src = "SHOW REGIONS 去重（1.3 等价口径）" if dedup_ok else "不可观测"
        data = data if dedup_ok else -1
    return {
        "schema": schema, "data": data,
        "schema_max": ctx.api.db_max_group_num(db, "SCHEMA", dialect=dialect),
        "data_max": ctx.api.db_max_group_num(db, "DATA", dialect=dialect),
        "schema_src": schema_src, "data_src": data_src,
    }


def expect_groups_compat(ctx: Ctx, label: str, db: str, dialect: str, *,
                         schema: int | None = None, data: int | None = None) -> None:
    """组数断言；2.x 走原 ``expect_groups``（口径一字不改），1.3 走兼容分支。

    UPG-1.3（1.3 分支）：与 2.x 一样要求**双口径**，只是把"库详情"这一路换成 1.3 的
    ``SHOW DATABASES DETAILS``（组数列见 ``showStorageGroupsDetailColumnHeaders``），
    另一路仍是 ``SHOW REGIONS`` 按 RegionId 去重。**每个可用口径都必须等于期望值**；
    某口径不可观测时在 detail 里写明（不当作通过），两个口径都不可观测 ⇒ ``ctx.skip``
    并注明原因（不伪造、不判 PASS）。
    """
    v13, why = is_v13(ctx)
    if not v13:
        expect_groups(ctx, label, db, dialect, schema=schema, data=data)
        return
    detail_s = ctx.api.db_group_num(db, "SCHEMA", dialect=dialect)
    detail_d = ctx.api.db_group_num(db, "DATA", dialect=dialect)
    dedup_s, dedup_s_ok = region_group_probe(ctx, db, "SCHEMA")
    dedup_d, dedup_d_ok = region_group_probe(ctx, db, "DATA")
    evidence = {
        "版本依据": why,
        "库详情原文": ctx.api.database_details(dialect).get(db, {}),
        "组数": {"schema_detail": detail_s, "schema_dedup": dedup_s,
                 "data_detail": detail_d, "data_dedup": dedup_d},
        "区域快照": {"schema": ctx.api.snapshot(db, kind="SCHEMA", dialect=dialect),
                     "data": ctx.api.snapshot(db, kind="DATA", dialect=dialect)},
    }
    unobservable = 0
    checks = (("Schema", schema, detail_s, detail_s >= 0, dedup_s, dedup_s_ok),
              ("Data", data, detail_d, detail_d >= 0, dedup_d, dedup_d_ok))
    for kind, want, num_detail, detail_ok, num_dedup, dedup_ok in checks:
        if want is None:
            continue
        sources: list[tuple[str, int]] = []
        if detail_ok:
            sources.append(("库详情 SHOW DATABASES DETAILS", num_detail))
        if dedup_ok:
            sources.append(("SHOW REGIONS 去重", num_dedup))
        if not sources:
            unobservable += 1
            ctx.note(f"    {kind} 组数在 1.3 下不可观测（库详情无组数列、SHOW REGIONS 也不可用）"
                     f"⇒ 跳过该口径断言，不伪造")
            continue
        passed = all(value == want for _, value in sources)
        ctx.check(f"{label}：{kind}RegionGroup 数应为 {want}（1.3 双口径）", passed,
                  "、".join(f"{name}={value}" for name, value in sources)
                  + ("" if len(sources) == 2 else "；另一口径在 1.3 下不可观测（不据此判通过）"),
                  evidence=json.dumps(evidence, ensure_ascii=False)[:4000])
    if unobservable and unobservable == sum(1 for _, want, *_ in checks if want is not None):
        ctx.skip("1.3 下组数不可观测（SHOW DATABASES DETAILS 无组数列且 SHOW REGIONS 不可用）："
                 "跳过组数断言并留证，按 SKIP 处理（不伪造组数、不判 PASS）")


def time_partition_interval_compat(ctx: Ctx, db: str) -> tuple[int, str, str]:
    """``(interval_ms, 口径, 探测到的 conf 路径)``。

    UPG-1.3: 首选 SQL 读回（1.3 的 ``SHOW DATABASES DETAILS`` 同样有
    ``TimePartitionInterval`` 列）；1.3 上若读不到，再**探测真实配置文件**
    （``conf/iotdb-system.properties`` → ``iotdb-common.properties`` →
    ``iotdb-engine.properties``，见 ``pgprops.CANDIDATE_FILES``）读
    ``time_partition_interval``，并把探测到的路径写进证据 —— 先探测再读，不猜文件名。
    """
    interval = ctx.api.db_time_partition_interval(db, dialect="tree")
    if interval > 0:
        return (interval,
                "SHOW DATABASES 系（DETAILS 优先，1.3 的 details 不可用时回退 show databases）"
                "的 TimePartitionInterval 列", "")
    v13, _why = is_v13(ctx)
    if not v13:
        return interval, "SHOW DATABASES DETAILS（读不到）", ""
    host = ctx.cfg.cli_host
    path = ctx.props.resolved_path(host) if ctx.props is not None else ""
    if not path:
        return -1, "1.3: conf 文件探测失败", ""
    try:
        readback = ctx.props.read(host, keys=("time_partition_interval",))
    except Exception as exc:  # noqa: BLE001 - 读不到就当作不可观测
        return -1, f"1.3: 读 {path} 失败（{exc}）", path
    raw = readback.get("time_partition_interval")
    try:
        value = int(str(raw).strip())
    except (TypeError, ValueError):
        value = -1
    return value, f"1.3: conf 读回 {path}:time_partition_interval", path


def settle_groups(ctx: Ctx, db: str, *, dialect: str = "tree", seconds: int = 40,
                  interval: int = 4) -> tuple[int, int, int, int]:
    """等到组数连续两次读数一致再返回 ``(schema, data, schema_max, data_max)``。

    1.3 的 AUTO 扩容是**异步**的（按数据量/落盘触发），立即读会拿到中途值；
    2.0 的 PROACTIVE 扩容在写入路径上同步完成，但同样等一次更稳。

    UPG-1.3: 组数经 ``group_count_compat`` 取 —— 1.3 上 ``SHOW DATABASES DETAILS`` 若
    给不出组数列，就退回 ``SHOW REGIONS`` 去重（不再是永远读成 -1）。
    """
    deadline = time.time() + seconds
    last: tuple[int, int] | None = None
    stable = 0
    while True:
        snapshot = (group_count_compat(ctx, db, "SCHEMA")[0],
                    group_count_compat(ctx, db, "DATA")[0])
        if snapshot == last:
            stable += 1
        else:
            stable = 0
            last = snapshot
        if stable >= 1 or time.time() >= deadline:
            break
        time.sleep(interval)
    schema, data = last if last else (snapshot[0], snapshot[1])
    return (schema, data,
            ctx.api.db_max_group_num(db, "SCHEMA", dialect=dialect),
            ctx.api.db_max_group_num(db, "DATA", dialect=dialect))


def distinct_new_devices(ctx: Ctx, db: str, count: int, prefix: str,
                         exclude: list[str]) -> list[str]:
    """生成 ``count`` 个新设备，保证 slot 既不互相撞、也不与 ``exclude`` 撞。"""
    slot_num = int(ctx.cfg.raw("PG_SERIES_SLOT_NUM") or 1000)
    used = {pslots.tree_device_slot(db, device, slot_num) for device in exclude}
    picked: list[str] = []
    for device in pslots.find_distinct_slot_devices(db, count + len(used) + 8,
                                                   slot_num=slot_num, prefix=prefix):
        slot = pslots.tree_device_slot(db, device, slot_num)
        if slot in used:
            continue
        used.add(slot)
        picked.append(device)
        if len(picked) >= count:
            break
    return picked


def canonical_targets(ctx: Ctx, facts: dict) -> dict[str, int]:
    """已写设备 → 期望行数；facts 缺失时按确定性命名重建（用于单跑某条用例）。"""
    targets = dict(facts.get("targets") or {})
    if targets:
        return targets
    targets = {f"{DB_MAIN}.d0": 1, f"{DB_TP}.tp0": 1, f"{DB_TP}.tp1": 1}
    for device in device_set(ctx, DB_AUTO, AUTO_DEVICES, prefix="pga"):
        targets[f"{DB_AUTO}.{device}"] = 1
    for index, db in enumerate(DB_MULTI, start=1):
        targets[f"{db}.m{index}"] = 1
    return targets


def regionid_probe(ctx: Ctx, device: str, *, kind: str = "DATA") -> tuple[bool, str]:
    """``SHOW (DATA|SCHEMA) REGIONID WHERE DEVICE=...`` 是否可用（1.3 需按 kind 分别试）。

    UPG-1.3: 1.3.7 的语法解析器里**有** ``GetRegionIdContext``（SHOW DATA/SCHEMA REGIONID
    WHERE …），但 data region 的解析要落到具体时间分区，1.3 在缺省时间范围时可能返回空集
    或报错；因此这里不预设"1.3 不支持"，而是**先试 data、再试 schema**，两种都拿不到才记
    "不可观测"（用例据此 SKIP 并留证，绝不伪造映射）。
    """
    if kind.upper().startswith("S"):
        outcome = ctx.api.run(f"show schema regionid where device={device}",
                              dialect="tree", timeout=60)
    else:
        outcome = ctx.api.device_region_id(device, dialect="tree", timeout=60)
    return outcome.ok, (outcome.output or "").strip()


def _schema_regionid(ctx: Ctx, device: str):
    """``SHOW SCHEMA REGIONID WHERE DEVICE=…``（1.3 的 schema region 也支持该语法）。"""
    return ctx.api.run(f"show schema regionid where device={device}",
                       dialect="tree", timeout=60)


def region_id_of(outcome) -> str:
    """从 ``SHOW … REGIONID`` 的结果里取 RegionId 文本（取不到返回 ``""``）。"""
    if not outcome.ok or not outcome.rows:
        return ""
    column = outcome.rows[0].keys()
    wanted = {name.lower() for name in pgapi.REGION_ID_COLUMNS}
    for name in column:
        if name.strip().lower() in wanted:
            return (outcome.rows[0].get(name) or "").strip()
    # 1.3 的该结果只有一列（RegionId），列名不匹配时退回第一列
    first = outcome.rows[0]
    return (next(iter(first.values())) or "").strip() if first else ""


def post_phase_or_skip(ctx: Ctx, case_id: str) -> dict | None:
    """post 用例的公共前置：阶段正确 + 读得到 pre 事实。"""
    if not need_phase(ctx, "post"):
        return None
    pre = load_pre_facts(ctx)
    if not pre:
        ctx.skip(f"{case_id} 找不到 upg_pre_facts.json（pre 轮未跑或结果目录不同）；"
                 f"请先跑 PG_UPG_PHASE=pre 档的 upgrade + PG-UPG-01..07")
        return None
    return pre


# ------------------------------------------------------------------ pre（1.3）
def case_upg01_pre_baseline(ctx: Ctx) -> None:
    """PG-UPG-01 1.3 基线：建树库写 1 设备 1 测点，记录组数与上限。"""
    if not need_phase(ctx, "pre"):
        return
    db = reset_db(ctx, "tree", DB_MAIN)
    device = "d0"
    ensure_write_tree(ctx, db, device, 1, sensors=("s0",))
    # UPG-1.3: 1.3 用 `select * …` + CLI 的 "Total line number = N" 计数，
    # 不依赖 2.x 的 `count(*)` 输出形态（见 count_rows_compat）。
    rows, rows_how = count_rows_compat(ctx, f"{db}.{device}")
    settle_groups(ctx, db)                      # 等组数稳定（读数丢弃，下面重读并带口径）
    nums = group_nums_compat(ctx, db)
    schema, data = nums["schema"], nums["data"]
    schema_max, data_max = nums["schema_max"], nums["data_max"]
    min_schema = int(ctx.cfg.raw("PG_MIN_SCHEMA_PER_DB") or 1)
    min_data = int(ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    ctx.check("1.3 写入 1 设备 1 测点后可查（count=1）", rows == 1,
              f"count={rows}（计数口径：{rows_how}）")
    if schema < 0 or data < 0:
        ctx.skip(f"1.3 组数不可观测（schema 口径={nums['schema_src']}、"
                 f"data 口径={nums['data_src']}）⇒ 跳过组数基线断言，按 SKIP 处理（不伪造）")
    else:
        ctx.check("1.3 建库写入后 Schema/Data 组数均 >= 1（记录基线，AUTO 口径由 02 判定）",
                  schema >= 1 and data >= 1,
                  f"schema={schema}（{nums['schema_src']}） data={data}（{nums['data_src']}）"
                  f" schema_max={schema_max} data_max={data_max}")
    record_fact(ctx, "main", {
        "db": db, "device": device, "sensor": "s0", "ts": 1,
        "groups": {"schema": schema, "data": data,
                   "schema_max": schema_max, "data_max": data_max},
        "group_sources": {"schema": nums["schema_src"], "data": nums["data_src"]},
        "count_method": rows_how,
        "min": {"schema": min_schema, "data": min_data},
    })
    add_targets(ctx, {f"{db}.{device}": 1})
    write_case_evidence(ctx, "upg01_baseline.json", {
        "db": db, "device": device, "rows": rows, "count_method": rows_how,
        "groups": {"schema": schema, "data": data},
        "group_sources": {"schema": nums["schema_src"], "data": nums["data_src"]},
        "max": {"schema": schema_max, "data": data_max},
        "min": {"schema": min_schema, "data": min_data},
        "policy_state": policy_state(ctx)[0],
        "version_hint": is_v13(ctx)[1],
    })


def case_upg02_pre_auto_floor(ctx: Ctx) -> None:
    """PG-UPG-02 1.3 默认 AUTO：6 个不同 slot 只到最小组数（不积极扩容）。"""
    if not need_phase(ctx, "pre"):
        return
    db = reset_db(ctx, "tree", DB_AUTO)
    devices = device_set(ctx, db, AUTO_DEVICES, prefix="pga")
    write_devices(ctx, db, devices, model="tree")
    settle_groups(ctx, db)                     # 等组数稳定（读数丢弃，下面带口径重读）
    nums = group_nums_compat(ctx, db)
    schema, data = nums["schema"], nums["data"]
    schema_max, data_max = nums["schema_max"], nums["data_max"]
    min_schema = int(ctx.cfg.raw("PG_MIN_SCHEMA_PER_DB") or 1)
    min_data = int(ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    distinct = pslots.distinct_slot_count(db, devices)
    slots = pslots.slot_map(db, devices)
    ctx.check(f"{AUTO_DEVICES} 个设备确实落在 {AUTO_DEVICES} 个互不相同的 slot（harness 计算）",
              distinct == AUTO_DEVICES, f"distinct={distinct}", evidence=json.dumps(slots))
    # UPG-1.3: 组数口径按版本分支（1.3: 库详情 → 不可观测再退回 SHOW REGIONS 去重）
    expect_groups_compat(ctx, f"1.3 AUTO 基线（{AUTO_DEVICES} 个不同 slot）", db, "tree",
                         schema=min_schema, data=min_data)
    if data < 0:
        ctx.skip(f"1.3 下 Data 组数不可观测（口径={nums['data_src']}）⇒ "
                 f"跳过'AUTO 不积极扩容'基线，按 SKIP 处理（不伪造组数）")
    else:
        ctx.check(f"升级前不积极扩容的基线：Data 组数（{data}）< 不同 slot 数（{distinct}），"
                  f"且等于最小组数（{min_data}）",
                  data == min_data and data < distinct,
                  f"组数={data}（{nums['data_src']}） 最小组数={min_data} 不同slot={distinct} "
                  f"上限={data_max}（若 1.3 的 AUTO 真的扩到 {distinct}，本条即升级族的关键发现）",
                  evidence=json.dumps({"slots": slots, "schema": schema, "data": data,
                                       "schema_max": schema_max, "data_max": data_max,
                                       "group_sources": {"schema": nums["schema_src"],
                                                         "data": nums["data_src"]}}))
    record_fact(ctx, "auto", {
        "db": db, "devices": devices, "slots": slots, "distinct_slots": distinct,
        "groups": {"schema": schema, "data": data,
                   "schema_max": schema_max, "data_max": data_max},
        "group_sources": {"schema": nums["schema_src"], "data": nums["data_src"]},
        "min": {"schema": min_schema, "data": min_data},
    })
    add_targets(ctx, {f"{db}.{device}": 1 for device in devices})
    write_case_evidence(ctx, "upg02_auto_baseline.json", {
        "db": db, "devices": devices, "slots": slots,
        "groups": {"schema": schema, "data": data},
        "group_sources": {"schema": nums["schema_src"], "data": nums["data_src"]},
        "max": {"schema": schema_max, "data": data_max},
        "min": {"schema": min_schema, "data": min_data},
        "policy_state": policy_state(ctx)[0],
        "version_hint": is_v13(ctx)[1],
    })


def case_upg03_pre_policy_absent(ctx: Ctx) -> None:
    """PG-UPG-03 1.3 conf 里策略键不存在或为 AUTO，且模板不认 PROACTIVE。"""
    if not need_phase(ctx, "pre"):
        return
    state, per_host = policy_state(ctx)
    ctx.check("1.3 生效 conf 里两个策略键要么不存在、要么就是 AUTO（不存在 PROACTIVE）",
              state in ("absent", "AUTO"), f"读回状态={state}",
              evidence=json.dumps(per_host, ensure_ascii=False))
    # UPG-1.3: 模板文件名按 1.3/2.x 两种布局**探测**后再 grep（1.3.7 企业包仍是
    # conf/iotdb-system.properties.template；1.2 及更早叫 iotdb-engine.properties.template）。
    template, hits = "", -1
    if ctx.cfg.cn_hosts:
        host = ctx.cfg.cn_hosts[0]
        db_dir = ctx.cfg.get("DB_DIR")
        for name in ("iotdb-system.properties.template",
                     "iotdb-engine.properties.template",
                     "iotdb-common.properties.template"):
            candidate = f"{db_dir}/conf/{name}"
            res = ctx.ssh.run(host,
                              f"[[ -f {candidate} ]] && grep -c PROACTIVE {candidate} || echo MISSING",
                              check=False)
            text = (res.out or "").strip().splitlines()
            if not text or text[-1] == "MISSING":
                continue
            template = candidate
            try:
                hits = int(text[-1])
            except ValueError:
                hits = -1
            break
        if hits < 0:
            ctx.note(f"    读不到 1.3 包内模板（试过 {db_dir}/conf/*.properties.template）："
                     f"跳过'模板不认 PROACTIVE'子断言")
        else:
            ctx.check("1.3 包内模板不出现 PROACTIVE（1.3 没有该策略值）", hits == 0,
                      f"grep -c PROACTIVE {template} = {hits}")
    upstream = upstream_evidence(ctx, "upgrade_pre.json")
    if upstream:
        ctx.check("upgrade_pre.json 记录的 1.3 策略状态与本用例读回一致",
                  upstream.get("policy_state") == state,
                  f"证据={upstream.get('policy_state')} 读回={state}")
        ctx.check("upgrade_pre.json 的 1.3 版本号与本轮 conf 的 PG_UPGRADE_FROM_VERSION 一致",
                  str(upstream.get("from_version", "")).startswith(
                      (ctx.cfg.raw("PG_UPGRADE_FROM_VERSION") or "1.3")),
                  f"证据={upstream.get('from_version')} "
                  f"conf={ctx.cfg.raw('PG_UPGRADE_FROM_VERSION') or '1.3'}")
    else:
        ctx.note("    未找到 upgrade_pre.json（未跑 pre 档 upgrade）：跳过交叉核对")
    record_fact(ctx, "policy", {"state": state, "per_host": per_host,
                                "template_proactive_hits": hits})
    write_case_evidence(ctx, "upg03_policy.json", {
        "policy_state": state, "per_host": per_host,
        "template_proactive_hits": hits,
        "template_path": template,
    })


def case_upg04_pre_time_partition(ctx: Ctx) -> None:
    """PG-UPG-04 1.3 用 ``db_time_partition_interval`` 算边界，写分区 0/1 数据。

    **跨分区写入的"后半段"故意留给 PG-UPG-10**：升级后在**第 3 个**分区写入，
    才能观察到"新时间分区触发补组"。因此本用例只写分区 0 与分区 1，并记录
    ``post_ts = 2 * interval + origin`` 供升级后使用。
    """
    if not need_phase(ctx, "pre"):
        return
    db = reset_db(ctx, "tree", DB_TP)
    # UPG-1.3: 首选 SQL 读回（1.3 的 SHOW DATABASES DETAILS 也有 TimePartitionInterval 列），
    # 读不到时探测真实 conf 文件名再读 time_partition_interval（先探测、不猜文件名）。
    interval, interval_src, conf_path = time_partition_interval_compat(ctx, db)
    conf_interval = int(ctx.cfg.raw("PG_TIME_PARTITION_INTERVAL") or 0)
    ctx.check("db_time_partition_interval 读回值 = conf 的 PG_TIME_PARTITION_INTERVAL（毫秒）",
              interval > 0 and interval == conf_interval,
              f"读回={interval}（口径：{interval_src}"
              + (f"；文件 {conf_path}" if conf_path else "") + f"） conf={conf_interval}"
              + ("（注意：单位是毫秒，模板默认 604800000；config.py 的 DEFAULTS 写的是 "
                 "604800，本档必须显式设为 604800000）" if conf_interval == 604800 else ""))
    if interval <= 0:
        ctx.skip(f"1.3 下读不到 time_partition_interval（口径：{interval_src}）⇒ "
                 f"无法构造分区 0/1 的边界，跳过本用例的时间分区写入与断言（不伪造时间戳）")
        return
    origin = 1000
    ts_p0, ts_p1 = origin, interval + origin
    ts_p2 = 2 * interval + origin
    dev_p0, dev_p1, dev_p2 = "tp0", "tp1", "tp2"
    ensure_write_tree(ctx, db, dev_p0, ts_p0, sensors=("s0",))
    ensure_write_tree(ctx, db, dev_p1, ts_p1, sensors=("s0",))
    schema, data, schema_max, data_max = settle_groups(ctx, db)
    rows0, how0 = count_rows_compat(ctx, f"{db}.{dev_p0}")
    rows1, how1 = count_rows_compat(ctx, f"{db}.{dev_p1}")
    ctx.check("分区 0 与分区 1 的写入都可查（各 1 行）", rows0 == 1 and rows1 == 1,
              f"p0={rows0} p1={rows1}（计数口径：{how0} / {how1}）")
    ctx.check(f"两个时间分区跨度为 {interval} ms（= time_partition_interval）",
              ts_p1 - ts_p0 == interval, f"t1-t0={ts_p1 - ts_p0} interval={interval}")
    record_fact(ctx, "tp", {
        "db": db, "interval_ms": interval, "origin": origin,
        "interval_source": interval_src, "conf_path": conf_path,
        "timestamps": {"p0": ts_p0, "p1": ts_p1, "p2": ts_p2},
        "devices": {"p0": dev_p0, "p1": dev_p1, "p2": dev_p2},
        "groups_pre": {"schema": schema, "data": data,
                       "schema_max": schema_max, "data_max": data_max},
    })
    add_targets(ctx, {f"{db}.{dev_p0}": 1, f"{db}.{dev_p1}": 1})
    write_case_evidence(ctx, "upg04_time_partition.json", {
        "db": db, "interval_ms": interval,
        "interval_source": interval_src, "conf_path": conf_path,
        "timestamps": {"p0": ts_p0, "p1": ts_p1, "p2": ts_p2},
        "devices": {"p0": dev_p0, "p1": dev_p1, "p2": dev_p2},
        "groups": {"schema": schema, "data": data},
        "max": {"schema": schema_max, "data": data_max},
        "version_hint": is_v13(ctx)[1],
    })


def case_upg05_pre_multi_db(ctx: Ctx) -> None:
    """PG-UPG-05 建多个库（升级后对比上限分摊）。"""
    if not need_phase(ctx, "pre"):
        return
    made: dict[str, dict] = {}
    for index, db in enumerate(DB_MULTI, start=1):
        reset_db(ctx, "tree", db)
        device = f"m{index}"
        ensure_write_tree(ctx, db, device, 1, sensors=("s0",))
        schema, data, schema_max, data_max = settle_groups(ctx, db)
        made[db] = {"device": device, "schema": schema, "data": data,
                    "schema_max": schema_max, "data_max": data_max}
        ctx.note(f"    {db}: device={device} schema={schema} data={data} "
                 f"max={schema_max}/{data_max}")
        add_targets(ctx, {f"{db}.{device}": 1})
    details = ctx.api.database_details("tree")
    user_dbs = sorted(db for db in details if not any(m in db for m in SYSTEM_MARKERS))
    # UPG-1.3: 1.3 的 `show databases details` 若不可用，pgapi 会回落到 `show databases`
    # 只取库名（1.3 的该语句只有 5 列、没有组数列）；库名足以判"3 个库是否真的建起来"，
    # 组数由 group_nums_compat 单独按可用口径取，不在这里硬凑。
    ctx.check(f"{len(DB_MULTI)} 个额外库都已建立并写入（当前普通树库 {len(user_dbs)} 个）",
              len(made) == len(DB_MULTI) and len(user_dbs) >= len(DB_MULTI),
              f"made={sorted(made)} user_dbs={user_dbs} 版本依据={is_v13(ctx)[1]}")
    caps = {db: {"schema": expected_cap(ctx, "SCHEMA", "tree", db),
                 "data": expected_cap(ctx, "DATA", "tree", db)} for db in user_dbs}
    record_fact(ctx, "multi", {"dbs": made, "user_dbs": user_dbs, "expected_cap": caps})
    write_case_evidence(ctx, "upg05_multi_db.json", {
        "dbs": made, "user_dbs": user_dbs, "expected_cap": caps,
        "databases_details": details,
    })


def case_upg06_pre_snapshot(ctx: Ctx) -> None:
    """PG-UPG-06 记录 ``SHOW DATABASES DETAILS`` 快照与升级前行数。"""
    if not need_phase(ctx, "pre"):
        return
    facts = load_facts(ctx, "pre")
    targets = canonical_targets(ctx, facts)
    details = ctx.api.database_details("tree")
    # UPG-1.3: 逐设备行数改用 count_rows_compat（1.3 = select * + "Total line number"）
    rows: dict[str, int] = {}
    methods: dict[str, str] = {}
    for target in sorted(targets):
        rows[target], methods[target] = count_rows_compat(ctx, target)
    bad = {target: value for target, value in rows.items() if value != 1}
    ctx.check(f"升级前 {len(rows)} 个已写设备各有 1 行数据（快照基线）", not bad,
              (f"异常={bad}" if bad else f"全部 count=1；设备数={len(rows)}")
              + f"；计数口径={sorted(set(methods.values()))}",
              evidence=json.dumps(rows, ensure_ascii=False))
    user_dbs = sorted(db for db in details if not any(m in db for m in SYSTEM_MARKERS))
    ctx.check(f"升级前普通树库数量 >= 5（含 01/02/04/05 建的库）", len(user_dbs) >= 5,
              f"user_dbs={user_dbs}（版本依据={is_v13(ctx)[1]}）")
    payload = {"databases_details": details, "row_counts": rows, "user_dbs": user_dbs,
               "count_methods": methods, "version_hint": is_v13(ctx)[1]}
    record_fact(ctx, "snapshot", payload)
    record_fact(ctx, "targets", {target: 1 for target in rows})
    write_case_evidence(ctx, "upgrade_pre_snapshot.json", payload)


def case_upg07_pre_device_groups(ctx: Ctx) -> None:
    """PG-UPG-07 记录设备→RegionGroup 映射（1.3 若两种 REGIONID 语句都不可用则 SKIP）。

    UPG-1.3: 1.3.7 的语法解析器里**存在** ``SHOW DATA/SCHEMA REGIONID WHERE …``
    （``IoTDBSqlParser$GetRegionIdContext``，输出只有一列 ``RegionId``），所以本用例
    不再假设"1.3 无该 SQL"：先按 ``show data regionid where device=…`` 逐个取，取不到
    再退回 ``show schema regionid where device=…``；两种都拿不到才 ``ctx.skip`` 并把
    原始回复写进证据（**不伪造映射**，也不把"语句不支持"判成产品缺陷）。
    """
    if not need_phase(ctx, "pre"):
        return
    facts = load_facts(ctx, "pre")
    targets = canonical_targets(ctx, facts)
    devices = sorted(targets)
    supported, raw = regionid_probe(ctx, devices[0])
    kind_used = "DATA"
    if not supported:
        supported, raw = regionid_probe(ctx, devices[0], kind="SCHEMA")
        kind_used = "SCHEMA"
    mapping: dict[str, str] = {}
    if not supported:
        ctx.note(f"    SHOW DATA/SCHEMA REGIONID 均不可用（原始回复：{raw[:200]}）"
                 f"⇒ 只记录语句可用性，SKIP 映射断言")
        ctx.skip("1.3 下 SHOW DATA REGIONID / SHOW SCHEMA REGIONID 都取不到结果 ⇒ "
                 "设备→RegionGroup 映射不可观测，按 SKIP 处理（不伪造映射）")
    else:
        queried: dict[str, str] = {}
        for device in devices:
            outcome = ctx.api.device_region_id(device, dialect="tree", timeout=60) \
                if kind_used == "DATA" else _schema_regionid(ctx, device)
            if not outcome.ok:
                # 1.3 的 data region 解析要落到具体时间分区，缺省时间范围可能返回空集；
                # 换另一种 kind 再试一次，两种都空才把该设备记为"取不到"。
                outcome = _schema_regionid(ctx, device) if kind_used == "DATA" \
                    else ctx.api.device_region_id(device, dialect="tree", timeout=60)
            queried[device] = region_id_of(outcome)
        missing = sorted(device for device, gid in queried.items() if not gid)
        # 只把**取到**的映射写进事实（空串会让 post 侧把它当成 RegionGroup=""）
        mapping = {device: gid for device, gid in queried.items() if gid}
        ctx.check(f"1.3 下 {len(devices)} 个已写设备都能查到所属 RegionGroup"
                  f"（口径：SHOW {kind_used} REGIONID）",
                  not missing, f"missing={missing}", evidence=json.dumps(queried))
    record_fact(ctx, "device_groups", {"supported": supported, "kind": kind_used,
                                       "mapping": mapping,
                                       "missing": sorted(d for d in devices
                                                         if d not in mapping),
                                       "probe_raw": raw[:500]})
    write_case_evidence(ctx, "device_groups_pre.json", {
        "supported": supported, "kind": kind_used, "mapping": mapping,
        "probe_raw": raw[:2000], "version_hint": is_v13(ctx)[1],
    })


# ----------------------------------------------------------------- post（2.0）
def case_upg08_post_version(ctx: Ctx) -> None:
    """PG-UPG-08 升级后版本号为 2.0（``SHOW CLUSTER`` 的 Version 列）。"""
    if not need_phase(ctx, "post"):
        return
    outcome = ctx.api.run("show cluster")
    column = ctx.api.column(outcome.rows, "Version")
    versions = sorted({(row.get(column) or "").strip() for row in outcome.rows
                       if (row.get(column) or "").strip()}) if column else []
    observed = versions[0] if versions else ""
    want_major = (ctx.cfg.raw("PG_UPGRADE_TO_VERSION") or "2.0").strip()
    want_full = (ctx.cfg.raw("DB_VERSION") or "").strip()
    ctx.check("升级后 SHOW CLUSTER 可读，且含 Version 列",
              bool(column) and bool(observed),
              f"columns={list(outcome.rows[0].keys()) if outcome.rows else []} "
              f"version列={column!r} 观测={observed!r}",
              evidence=(outcome.output or "")[:2000])
    ctx.check(f"升级后版本号属于 {want_major} 线（实测 {observed or '未知'}）",
              bool(observed) and (observed.startswith(want_major) or want_major in observed),
              f"observed={observed} want_major={want_major}")
    if want_full:
        ctx.check(f"升级后版本号包含 conf 的 DB_VERSION={want_full}",
                  want_full in observed, f"observed={observed}")
    upstream = upstream_evidence(ctx, "upgrade_post.json")
    if upstream:
        recorded = str(upstream.get("observation", {}).get("observed_version") or "")
        ctx.check("upgrade_post.json 记录的 2.0 版本与本用例观测一致",
                  recorded == observed or (recorded and observed and recorded in observed),
                  f"证据={recorded} 观测={observed}")
        ctx.check("upgrade_post.json 的目标包不是 1.3 包（升级确实换了包）",
                  str(upstream.get("to_tarball", "")) != str(upstream.get("from_tarball", "")),
                  f"from={upstream.get('from_tarball')} to={upstream.get('to_tarball')}")
    else:
        ctx.note("    未找到 upgrade_post.json（未跑 post 档 upgrade）：跳过交叉核对")
    record_fact(ctx, "version", {"observed": observed, "column": column,
                                 "want_major": want_major, "db_version": want_full,
                                 "versions": versions})
    write_case_evidence(ctx, "upg08_version.json", {
        "observed": observed, "versions": versions, "column": column,
        "want_major": want_major, "db_version": want_full,
        "show_cluster_raw": (outcome.output or "")[:4000],
    })


def case_upg09_post_proactive(ctx: Ctx) -> None:
    """PG-UPG-09 【核心】升级后对已有数据再写新 slot ⇒ 2.0 默认值语义变成 PROACTIVE。

    同时把"独立性断言"写在同一用例里，按 **pre 档位** 选分支（两种子情形不能在
    同一轮里同时构造）：

    * pre 档 ``PG_OMIT_POLICY_KEYS=true`` 或 ``PG_{SCHEMA,DATA}_POLICY`` 为空/PROACTIVE
      ⇒ 1.3 conf **无策略键** ⇒ 升级后必须走 2.0 代码默认值 **PROACTIVE**（积极扩容）。
    * pre 档 ``PG_{SCHEMA,DATA}_POLICY=AUTO`` ⇒ 1.3 conf **显式 AUTO** ⇒ 升级后必须
      **保持 AUTO**（不积极扩容），读写回都要自证。

    因此本用例在两种档位下都判定，分支由 ``upg_pre_facts.json`` 里的
    ``policy.state``（PG-UPG-03 记录）决定。
    """
    pre = post_phase_or_skip(ctx, "PG-UPG-09")
    if pre is None:
        return
    auto = pre.get("auto") or {}
    db = auto.get("db") or DB_AUTO
    pre_devices = list(auto.get("devices") or [])
    min_data = int((auto.get("min") or {}).get("data")
                   or ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    min_schema = int((auto.get("min") or {}).get("schema")
                     or ctx.cfg.raw("PG_MIN_SCHEMA_PER_DB") or 1)
    pre_groups = auto.get("groups") or {}
    pre_state = str((pre.get("policy") or {}).get("state") or "").strip()
    if not pre_state:
        upstream = upstream_evidence(ctx, "upgrade_pre.json")
        pre_state = str(upstream.get("policy_state") or "").strip()
    if not pre_state:
        pre_state = policy_state(ctx)[0]
    state, per_host = policy_state(ctx)
    before = ctx.api.db_group_num(db, "DATA", dialect="tree")
    ctx.check(f"前置：升级前的库 {db} 与 {len(pre_devices)} 个设备在升级后仍可见",
              before >= 0 and bool(pre_devices),
              f"data_groups={before} 升级前设备数={len(pre_devices)} "
              f"升级前组数={pre_groups}")
    new_devices = distinct_new_devices(ctx, db, NEW_DEVICES, "pgu", exclude=pre_devices)
    if len(new_devices) < NEW_DEVICES:
        ctx.skip(f"无法为 {db} 生成 {NEW_DEVICES} 个不与升级前撞槽的新设备"
                 f"（只生成 {len(new_devices)} 个）")
        return
    write_devices(ctx, db, new_devices, model="tree")
    schema, data, schema_max, data_max = settle_groups(ctx, db)
    union = pre_devices + new_devices
    distinct = pslots.distinct_slot_count(db, union)
    ctx.check("harness 自证：新旧设备合起来仍是互不相同的 slot（未与升级前撞槽）",
              distinct == len(union), f"distinct={distinct} total={len(union)}",
              evidence=json.dumps(pslots.slot_map(db, union)))

    if pre_state.upper() == "AUTO":
        ctx.note("  分支：升级前 conf **显式写了 AUTO** ⇒ 断言 2.0 保持 AUTO（独立性断言）")
        ctx.check("2.0 conf 仍读回 AUTO（显式配置不被新版本默认值覆盖）",
                  state.upper() == "AUTO", f"读回状态={state}",
                  evidence=json.dumps(per_host, ensure_ascii=False))
        ctx.check(f"AUTO 保持的行为证据：新增 {len(new_devices)} 个不同 slot 后 Data 组数"
                  f"仍是最小组数 {min_data}（不积极扩容）",
                  data == min_data,
                  f"升级前={before} 升级后={data} 最小组数={min_data} 上限={data_max}")
        ctx.check(f"AUTO 保持：Data 组数（{data}）< 不同 slot 数（{distinct}）",
                  data < distinct, f"组数={data} 不同slot={distinct}")
        record_fact(ctx, "proactive", {
            "branch": "auto-preserved", "db": db, "new_devices": new_devices,
            "distinct_slots": distinct, "before": before, "after": data,
            "min_data": min_data, "policy_state": state,
        })
        write_case_evidence(ctx, "upg09_auto_preserved.json", {
            "branch": "auto-preserved", "policy_state": state, "per_host": per_host,
            "before": before, "after": data, "min_data": min_data,
            "distinct_slots": distinct, "new_devices": new_devices,
        })
        return

    ctx.note("  分支：升级前 conf **没有策略键** ⇒ 断言 2.0 走代码默认值 PROACTIVE（核心）")
    ctx.check("升级前 conf 无策略键（1.3 侧走默认 AUTO）",
              pre_state.lower() in ("absent", ""), f"pre_state={pre_state!r}")
    ctx.check("升级过程没有把策略键写进 2.0 conf（仍无键 ⇒ 走代码默认值 PROACTIVE）",
              state.lower() in ("absent", ""), f"升级后读回状态={state!r}",
              evidence=json.dumps(per_host, ensure_ascii=False))
    cap_data = expected_cap(ctx, "DATA", "tree", db)
    cap_schema = expected_cap(ctx, "SCHEMA", "tree", db)
    want_data = min(distinct, cap_data)
    ctx.check(f"核心断言：升级后对**已有数据**再写 {len(new_devices)} 个新 slot ⇒ Data 组数"
              f"增到 min({distinct}, 上限 {cap_data}) = {want_data}",
              data == want_data,
              f"升级前={before}（最小组数={min_data}） 升级后={data} 期望={want_data}",
              evidence=json.dumps({"before": before, "after": data,
                                   "projected": want_data, "cap": cap_data,
                                   "distinct_slots": distinct}))
    ctx.check("PROACTIVE 的行为证据：升级后组数严格大于最小组数、且大于升级前",
              data > min_data and data > before,
              f"升级后={data} 最小组数={min_data} 升级前={before}")
    expect_groups(ctx, "升级后 PROACTIVE 扩容（库详情 & 区域去重两口径）", db, "tree",
                  schema=min(distinct, cap_schema), data=want_data)
    record_fact(ctx, "proactive", {
        "branch": "default-proactive", "db": db, "new_devices": new_devices,
        "distinct_slots": distinct, "before": before, "after": data,
        "want": want_data, "cap_data": cap_data, "cap_schema": cap_schema,
        "min_data": min_data, "min_schema": min_schema, "policy_state": state,
    })
    write_case_evidence(ctx, "upg09_proactive.json", {
        "branch": "default-proactive", "policy_state": state, "per_host": per_host,
        "before": before, "after": data, "want": want_data, "cap_data": cap_data,
        "distinct_slots": distinct, "new_devices": new_devices,
    })


def case_upg10_post_time_partition(ctx: Ctx) -> None:
    """PG-UPG-10 升级后往**新时间分区**写入触发补组。"""
    pre = post_phase_or_skip(ctx, "PG-UPG-10")
    if pre is None:
        return
    proactive, why = post_is_proactive(ctx)
    if not proactive:
        ctx.skip(f"2.0 侧为 AUTO 档位（{why}）：'新分区触发补组'只在 PROACTIVE 档位下有意义")
        return
    tp = pre.get("tp") or {}
    if not tp:
        ctx.skip("缺少 PG-UPG-04 的时间分区事实（upg_pre_facts.json/tp）")
        return
    db = tp["db"]
    device = (tp.get("devices") or {}).get("p2", "tp2")
    ts = (tp.get("timestamps") or {}).get("p2")
    pre_groups = tp.get("groups_pre") or {}
    before = ctx.api.db_group_num(db, "DATA", dialect="tree")
    cap_before = expected_cap(ctx, "DATA", "tree", db)
    snapshot_before = ctx.api.snapshot(db, kind="DATA", dialect="tree")
    ensure_write_tree(ctx, db, device, int(ts), sensors=("s0",))
    schema, data, schema_max, data_max = settle_groups(ctx, db)
    cap_after = expected_cap(ctx, "DATA", "tree", db)
    want = min(before + 1, cap_after)
    ctx.check(f"升级前该库有 {before} 个 Data 组（04 记录 {pre_groups.get('data')}）",
              before >= 0 and before == pre_groups.get("data", before),
              f"当前={before} 04记录={pre_groups.get('data')}")
    ctx.check(f"升级后在第 3 个时间分区（t={ts}）写入 ⇒ Data 组数补到 "
              f"min({before}+1, 上限 {cap_after}) = {want}",
              data == want, f"升级前={before} 升级后={data} 期望={want} 上限={cap_after}")
    ctx.check("补组后新写入的数据可查（count=1）",
              ctx.api.count_rows(f"{db}.{device}", dialect="tree") == 1,
              f"count={ctx.api.count_rows(f'{db}.{device}', dialect='tree')}")
    record_fact(ctx, "tp_post", {"db": db, "device": device, "ts": ts, "before": before,
                                 "after": data, "want": want, "cap": cap_after})
    write_case_evidence(ctx, "upg10_time_partition.json", {
        "db": db, "device": device, "ts": ts, "before": before, "after": data,
        "want": want, "cap": cap_after, "cap_before": cap_before,
        "snapshot_before": snapshot_before,
        "snapshot_after": ctx.api.snapshot(db, kind="DATA", dialect="tree"),
    })


def case_upg11_post_cap(ctx: Ctx) -> None:
    """PG-UPG-11 升级后 ``Max{Schema,Data}RegionGroupNum`` 与公式一致。"""
    if not need_phase(ctx, "post"):
        return
    candidates = [DB_AUTO, DB_TP, DB_MAIN, DB_SCHEMA] + list(DB_MULTI)
    checked = 0
    for db in candidates:
        if ctx.api.db_group_num(db, "DATA", dialect="tree") < 0:
            ctx.note(f"    {db} 不在集群里，跳过上限比对")
            continue
        expect_cap(ctx, f"升级后 {db}", db, "tree")
        checked += 1
    ctx.check("至少有一个升级前的库参与上限比对", checked > 0, f"checked={checked}")
    record_fact(ctx, "caps", {db: {"schema": expected_cap(ctx, "SCHEMA", "tree", db),
                                   "data": expected_cap(ctx, "DATA", "tree", db)}
                              for db in candidates
                              if ctx.api.db_group_num(db, "DATA", dialect="tree") >= 0})


def case_upg12_post_hot_reload(ctx: Ctx) -> None:
    """PG-UPG-12 升级后热加载策略：set_config + 读回自证 + 行为 + 恢复。

    会修改（并恢复）持久化 conf：``SET CONFIGURATION`` 是**落盘**的，所以本用例必须
    在 PG-UPG-09 之后跑（09 依赖"升级后无策略键"的形态）。结束时若 pre 档位是
    "无键"，会把该行重新注释掉以恢复出厂形态。
    """
    pre = post_phase_or_skip(ctx, "PG-UPG-12")
    if pre is None:
        return
    key = "data_region_group_extension_policy"
    db = DB_AUTO
    min_data = int(ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    proactive, why = post_is_proactive(ctx)
    if not proactive:
        ctx.skip(f"2.0 侧为 AUTO 档位（{why}）：热加载切换只在 PROACTIVE 档位下判定")
        return
    before = ctx.api.db_group_num(db, "DATA", dialect="tree")
    cap = expected_cap(ctx, "DATA", "tree", db)
    ctx.check(f"前置：升级后 {db} 已按 PROACTIVE 扩容（组数 {before} > 最小组数 {min_data}）",
              before > min_data, f"before={before} min={min_data}")
    post_facts = load_facts(ctx, "post")
    known = (list((pre.get("auto") or {}).get("devices") or [])
             + list((post_facts.get("proactive") or {}).get("new_devices") or []))

    ctx.mark_harness_action("热加载 data 策略为 AUTO", pad=20)
    ctx.req(ctx.api.set_config(key, "AUTO"), "热加载 AUTO")
    on_disk = read_policy_key(ctx, key)
    ctx.check("SET CONFIGURATION 落盘自证：conf 读回 data 策略 = AUTO",
              bool(on_disk) and all(v == "AUTO" for v in on_disk.values()),
              f"读出={on_disk}", evidence=json.dumps(on_disk, ensure_ascii=False))
    dev_auto = distinct_new_devices(ctx, db, 1, "pgh", exclude=known)
    if not dev_auto:
        ctx.skip("无法生成新的不同 slot 设备用于热加载行为断言")
        return
    ensure_write_tree(ctx, db, dev_auto[0], 5, sensors=("s0",))
    _, after_auto, _, _ = settle_groups(ctx, db)
    ctx.check("AUTO 下新 slot 不再积极扩容（组数不增）", after_auto == before,
              f"AUTO 前={before} AUTO 后={after_auto}")

    ctx.mark_harness_action("热加载 data 策略回 PROACTIVE", pad=20)
    ctx.req(ctx.api.set_config(key, "PROACTIVE"), "热加载回 PROACTIVE")
    back = read_policy_key(ctx, key)
    ctx.check("恢复后 conf 读回 data 策略 = PROACTIVE",
              bool(back) and all(v == "PROACTIVE" for v in back.values()),
              f"读出={back}", evidence=json.dumps(back, ensure_ascii=False))
    pre_state = str((pre.get("policy") or {}).get("state") or "").strip().lower()
    if pre_state in ("absent", ""):
        ctx.props.remove_keys((key,), hosts=ctx.cfg.all_hosts)
        ctx.note("    升级前该键不存在 ⇒ 注释掉该行，恢复'无键'出厂形态"
                 "（运行期已是 PROACTIVE，下次重启仍取默认值 PROACTIVE）")
        ctx.check("恢复出厂形态：该键已不再是 ACTIVE 行",
                  key not in read_policy_key(ctx, key),
                  f"仍有 ACTIVE 行：{read_policy_key(ctx, key)}")
    dev_pro = distinct_new_devices(ctx, db, 1, "pgi", exclude=known + dev_auto)
    if not dev_pro:
        ctx.skip("无法生成第二个新的不同 slot 设备用于切回后的行为断言")
        return
    ensure_write_tree(ctx, db, dev_pro[0], 6, sensors=("s0",))
    _, after_pro, _, _ = settle_groups(ctx, db)
    ctx.check(f"切回 PROACTIVE 后新 slot 继续扩容（组数 = min({before}+1, {cap})）",
              after_pro == min(before + 1, cap),
              f"切回前={after_auto} 切回后={after_pro} 期望={min(before + 1, cap)}")
    record_fact(ctx, "hot_reload", {
        "key": key, "before": before, "after_auto": after_auto,
        "after_proactive": after_pro, "want_after_proactive": min(before + 1, cap),
        "on_disk_auto": on_disk, "on_disk_proactive": back,
        "devices": {"auto": dev_auto[0], "proactive": dev_pro[0]},
    })
    write_case_evidence(ctx, "upg12_hot_reload.json", {
        "key": key, "before": before, "after_auto": after_auto,
        "after_proactive": after_pro, "on_disk_auto": on_disk,
        "on_disk_proactive": back, "pre_state": pre_state,
    })


def case_upg13_post_same_slot_sensor(ctx: Ctx) -> None:
    """PG-UPG-13 升级后新增测点（同 slot）不建组。"""
    pre = post_phase_or_skip(ctx, "PG-UPG-13")
    if pre is None:
        return
    devices = list((pre.get("auto") or {}).get("devices") or [])
    if not devices:
        ctx.skip("缺少 PG-UPG-02 的设备清单（upg_pre_facts.json/auto.devices）")
        return
    db = (pre.get("auto") or {}).get("db") or DB_AUTO
    device = devices[0]
    slot_num = int(ctx.cfg.raw("PG_SERIES_SLOT_NUM") or 1000)
    slot_before = pslots.tree_device_slot(db, device, slot_num)
    before = ctx.api.db_group_num(db, "DATA", dialect="tree")
    group_before = ctx.api.device_group(f"{db}.{device}", dialect="tree")
    rows_before = ctx.api.count_rows(f"{db}.{device}", dialect="tree")
    ensure_write_tree(ctx, db, device, 2, sensors=("s_new",))
    schema, after, schema_max, data_max = settle_groups(ctx, db)
    slot_after = pslots.tree_device_slot(db, device, slot_num)
    group_after = ctx.api.device_group(f"{db}.{device}", dialect="tree")
    rows_after = ctx.api.count_rows(f"{db}.{device}", dialect="tree")
    ctx.check("harness 自证：新增测点没有改变设备 slot", slot_before == slot_after,
              f"slot {slot_before} -> {slot_after}")
    ctx.check(f"同 slot 新增测点不建组（Data 组数保持 {before}）", after == before,
              f"新增前={before} 新增后={after}（上限={data_max}）")
    if group_before and group_after:
        ctx.check("该设备仍属同一个 RegionGroup", group_before == group_after,
                  f"{group_before} -> {group_after}")
    # H-31: 2.x 的 count(*) 是"每测点一列"，同设备新增测点不会增加行数；
    # 必须直接查 count(<新测点>) == 1，而不是比较 count_rows。
    _out = ctx.api.run(f"select count(s_new) from {db}.{device}")
    _nums = [int(x) for x in __import__("re").findall(r"\|\s*(\d+)\s*\|", str(_out))]
    _cnt = max(_nums) if _nums else -1
    ctx.check(f"新测点可查（count(s_new) = 1）", _cnt == 1,
              f"count(s_new)={_cnt} out={str(_out)[:80]}")
    record_fact(ctx, "same_slot_sensor", {
        "db": db, "device": device, "slot": slot_after, "groups": {"before": before,
                                                                   "after": after},
        "rows": {"before": rows_before, "after": rows_after},
        "group_ids": {"before": group_before, "after": group_after},
    })
    write_case_evidence(ctx, "upg13_same_slot_sensor.json", {
        "db": db, "device": device, "slot_before": slot_before, "slot_after": slot_after,
        "groups": {"before": before, "after": after}, "schema": schema,
        "rows": {"before": rows_before, "after": rows_after},
        "group_ids": {"before": group_before, "after": group_after},
    })


def case_upg14_post_recreate(ctx: Ctx) -> None:
    """PG-UPG-14 升级后 drop 库再建再写仍正常（PROACTIVE 档位按下限/上限判）。"""
    if not need_phase(ctx, "post"):
        return
    proactive, why = post_is_proactive(ctx)
    db = DB_RECREATE
    reset_db(ctx, "tree", db)
    schema0, data0, schema_max0, data_max0 = settle_groups(ctx, db)
    if proactive:
        ctx.check("重建后的空库不预建 RegionGroup（PROACTIVE：空库 0 组）",
                  schema0 == 0 and data0 == 0,
                  f"schema={schema0} data={data0}")
    else:
        ctx.note(f"    AUTO 档位（{why}）：空库会预置最小/固定组数，跳过'空库 0 组'断言")
    devices = device_set(ctx, db, 4, prefix="pgr")
    write_devices(ctx, db, devices, model="tree")
    schema, data, schema_max, data_max = settle_groups(ctx, db)
    cap_data = expected_cap(ctx, "DATA", "tree", db)
    cap_schema = expected_cap(ctx, "SCHEMA", "tree", db)
    min_data = int(ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    want_data = min(4, cap_data) if proactive else min_data
    want_schema = min(4, cap_schema) if proactive else int(
        ctx.cfg.raw("PG_MIN_SCHEMA_PER_DB") or 1)
    ctx.check(f"重建后写入 4 个不同 slot：Data 组数 = {want_data}"
              f"（{'PROACTIVE' if proactive else 'AUTO'} 口径）",
              data == want_data, f"实际={data} 期望={want_data} 上限={cap_data}")
    ctx.check(f"重建后 Schema 组数 = {want_schema}", schema == want_schema,
              f"实际={schema} 期望={want_schema} 上限={cap_schema}")
    expect_groups(ctx, "升级后 drop/重建库", db, "tree",
                  schema=want_schema, data=want_data)
    rows = {device: ctx.api.count_rows(f"{db}.{device}", dialect="tree")
            for device in devices}
    ctx.check("重建库的 4 行数据都可查", all(value == 1 for value in rows.values()),
              f"{rows}")
    record_fact(ctx, "recreate", {"db": db, "devices": devices,
                                  "empty_groups": {"schema": schema0, "data": data0},
                                  "groups": {"schema": schema, "data": data},
                                  "proactive": proactive})
    add_targets(ctx, {f"{db}.{device}": 1 for device in devices})
    write_case_evidence(ctx, "upg14_recreate.json", {
        "db": db, "devices": devices, "proactive": proactive,
        "empty_groups": {"schema": schema0, "data": data0},
        "groups": {"schema": schema, "data": data}, "rows": rows,
        "max": {"schema": schema_max, "data": data_max},
    })


def case_upg15_post_data_preserved(ctx: Ctx) -> None:
    """PG-UPG-15 升级后升级前的行数不丢（与 06 快照一致）。"""
    pre = post_phase_or_skip(ctx, "PG-UPG-15")
    if pre is None:
        return
    snapshot = pre.get("snapshot") or {}
    rows = dict(snapshot.get("row_counts") or {})
    if not rows:
        rows = canonical_targets(ctx, pre)
        ctx.note(f"    未找到 06 的 row_counts，回落用确定性目标清单（{len(rows)} 个）")
    bad: dict[str, dict] = {}
    for target, want in sorted(rows.items()):
        got = ctx.api.count_rows(target, dialect="tree")
        if got != want:
            bad[target] = {"want": want, "got": got}
    ctx.check(f"升级前写入的 {len(rows)} 个设备的行数在升级后不丢（count_rows 与 06 一致）",
              not bad, f"不一致={bad}" if bad else "全部一致",
              evidence=json.dumps(rows, ensure_ascii=False))
    before_dbs = set(snapshot.get("user_dbs") or [])
    now_details = ctx.api.database_details("tree")
    now_dbs = {db for db in now_details if not any(m in db for m in SYSTEM_MARKERS)}
    missing = sorted(before_dbs - now_dbs)
    ctx.check("升级前的普通树库在升级后都存在（库元数据不丢）", not missing,
              f"missing={missing} before={sorted(before_dbs)} now={sorted(now_dbs)}")
    upstream = upstream_evidence(ctx, "upgrade_post.json")
    if upstream:
        post_detail = (upstream.get("observation", {}).get("databases_details", {})
                       or {}).get("tree", {})
        still = sorted(db for db in before_dbs if db in post_detail)
        ctx.check("upgrade_post.json 的库快照里也能看到升级前的库（升级完成时即存在）",
                  len(still) == len(before_dbs),
                  f"缺失={sorted(before_dbs - set(still))}")
    record_fact(ctx, "preserved", {"checked": len(rows), "bad": bad,
                                   "dbs_missing": missing})
    write_case_evidence(ctx, "upg15_data_preserved.json", {
        "expected_rows": rows, "bad": bad, "missing_dbs": missing,
        "now_dbs": sorted(now_dbs),
    })


def case_upg16_post_schema_proactive(ctx: Ctx) -> None:
    """PG-UPG-16 升级后 Schema 侧同样按 PROACTIVE 扩容。"""
    pre = post_phase_or_skip(ctx, "PG-UPG-16")
    if pre is None:
        return
    proactive, why = post_is_proactive(ctx)
    if not proactive:
        ctx.skip(f"2.0 侧为 AUTO 档位（{why}）：Schema 侧 PROACTIVE 断言只在 PROACTIVE 档位下有意义")
        return
    db = DB_SCHEMA
    reset_db(ctx, "tree", db)
    cap_schema = expected_cap(ctx, "SCHEMA", "tree", db)
    cap_data = expected_cap(ctx, "DATA", "tree", db)
    min_schema = int(ctx.cfg.raw("PG_MIN_SCHEMA_PER_DB") or 1)
    devices = device_set(ctx, db, SCHEMA_DEVICES, prefix="pgs")
    write_devices(ctx, db, devices, model="tree")
    schema, data, schema_max, data_max = settle_groups(ctx, db)
    want_schema = min(SCHEMA_DEVICES, cap_schema)
    ctx.check(f"升级后新建库写 {SCHEMA_DEVICES} 个不同 slot ⇒ Schema 组数 = "
              f"min({SCHEMA_DEVICES}, 上限 {cap_schema}) = {want_schema}",
              schema == want_schema,
              f"实际={schema} 期望={want_schema} 上限={schema_max}")
    ctx.check(f"Schema 侧的行为是 PROACTIVE（组数 {schema} 不是 1.3 AUTO 的最小组数 "
              f"{min_schema}）",
              schema > min_schema or want_schema <= min_schema,
              f"schema={schema} min_schema={min_schema} want={want_schema}")
    expect_groups(ctx, "升级后 Schema 侧 PROACTIVE 扩容", db, "tree",
                  schema=want_schema, data=min(SCHEMA_DEVICES, cap_data))
    record_fact(ctx, "schema_side", {"db": db, "devices": devices,
                                     "schema": schema, "data": data,
                                     "want_schema": want_schema,
                                     "cap_schema": cap_schema})
    add_targets(ctx, {f"{db}.{device}": 1 for device in devices})
    write_case_evidence(ctx, "upg16_schema_proactive.json", {
        "db": db, "devices": devices,
        "groups": {"schema": schema, "data": data},
        "want_schema": want_schema, "cap_schema": cap_schema,
        "cap_data": cap_data, "min_schema": min_schema,
        "max": {"schema": schema_max, "data": data_max},
    })


# ------------------------------------------------------------------- 注册表
SPECS: list[CaseSpec] = []


def _add(case_id: str, title: str, priority: str, fn, *, gate: bool = False,
         note: str = "") -> None:
    SPECS.append(CaseSpec(case_id=case_id, area="升级", model="tree", title=title,
                          priority=priority, fn=fn, gate=gate, note=note))


_add("PG-UPG-01", "1.3 基线：建树库写 1 设备 1 测点并记录组数", "P0",
     case_upg01_pre_baseline, note="PG_UPG_PHASE=pre")
_add("PG-UPG-02", "1.3 默认 AUTO：6 个不同 slot 只到最小组数（升级前不积极扩容）", "P0",
     case_upg02_pre_auto_floor, gate=True, note="PG_UPG_PHASE=pre")
_add("PG-UPG-03", "1.3 conf 策略键不存在或为 AUTO，且模板不认 PROACTIVE", "P0",
     case_upg03_pre_policy_absent, note="PG_UPG_PHASE=pre")
_add("PG-UPG-04", "1.3 用 db_time_partition_interval 算分区边界并写分区 0/1 数据", "P1",
     case_upg04_pre_time_partition, note="PG_UPG_PHASE=pre")
_add("PG-UPG-05", "1.3 建多个库（升级后对比上限分摊）", "P1",
     case_upg05_pre_multi_db, note="PG_UPG_PHASE=pre")
_add("PG-UPG-06", "记录 SHOW DATABASES DETAILS 快照与行数（升级前）", "P0",
     case_upg06_pre_snapshot, note="PG_UPG_PHASE=pre")
_add("PG-UPG-07", "记录设备→RegionGroup 映射（升级前）", "P1",
     case_upg07_pre_device_groups, note="PG_UPG_PHASE=pre")

_add("PG-UPG-08", "升级后版本号为 2.0（SHOW CLUSTER 的 Version 列）", "P0",
     case_upg08_post_version, gate=True, note="PG_UPG_PHASE=post")
_add("PG-UPG-09", "【核心】升级后已有库写新 slot 按 PROACTIVE 扩容（含 无键⇒PROACTIVE / "
                  "显式AUTO⇒保持AUTO 的独立性断言）", "P0",
     case_upg09_post_proactive, gate=True, note="PG_UPG_PHASE=post；分支依赖 pre 档位")
_add("PG-UPG-10", "升级后新时间分区写入触发补组", "P0",
     case_upg10_post_time_partition, note="PG_UPG_PHASE=post；依赖 04")
_add("PG-UPG-11", "升级后 Max*RegionGroupNum 与公式一致", "P0",
     case_upg11_post_cap, note="PG_UPG_PHASE=post")
_add("PG-UPG-12", "升级后热加载策略：set_config + 读回自证 + 恢复", "P0",
     case_upg12_post_hot_reload, note="PG_UPG_PHASE=post；会改 conf，须在 09 之后")
_add("PG-UPG-13", "升级后新增测点（同 slot）不建组", "P1",
     case_upg13_post_same_slot_sensor, note="PG_UPG_PHASE=post")
_add("PG-UPG-14", "升级后 drop 库再建再写仍正常（PROACTIVE 扩容）", "P1",
     case_upg14_post_recreate, note="PG_UPG_PHASE=post")
_add("PG-UPG-15", "升级后升级前的行数不丢（与 06 快照一致）", "P0",
     case_upg15_post_data_preserved, note="PG_UPG_PHASE=post；依赖 06")
_add("PG-UPG-16", "升级后 Schema 侧同样按 PROACTIVE 扩容", "P1",
     case_upg16_post_schema_proactive, note="PG_UPG_PHASE=post")
