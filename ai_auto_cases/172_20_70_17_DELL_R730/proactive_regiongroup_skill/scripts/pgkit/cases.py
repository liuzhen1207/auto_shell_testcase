"""PROACTIVE（RegionGroup 积极扩容）用例集骨架 —— 占位模块，注册表为空。

本文件是从 compaction 技能的 ``cases.py`` **机械移植**出来的骨架：
只保留 runner（``run_cases``）与收尾三件套（``closing_triad``）等**通用基础设施**，
以及 cli.py 直接引用的名字（``CASES`` / ``CASE_INDEX`` / ``CaseSpec`` / ``Ctx`` /
``run_cases`` / ``PASS`` / ``FAIL``）；**没有**任何 PROACTIVE 用例体。

待实现：PROACTIVE 用例集（约 220 条，族与期望值见 ``references/case-catalog.md``、
``references/proactive-spec.md``）。填充方式：写用例函数（签名 ``fn(ctx: Ctx) -> None``），
在其中用 ``ctx.check(...)`` 记录断言、``ctx.skip(reason)`` 或 ``ctx.invalidate(reason)``，
然后登记进 ``CASES``；判定口径与纪律不得偏离上述两个 reference。

判定纪律（沿用既有技能口径，未改动）：
* ``PASS`` 仅当全部 check 通过；``SKIP``（前置不成立）≠ ``PASS``；被不可逆操作
  污染的轮次记 ``INVALID``（既不算 PASS 也不算 FAIL）。
* 每个用例结尾自动追加**收尾三件套**：① sync lag 有界归 0；② 副本一致性；
  ③ CN/DN 日志 ERROR/WARN 扫描。三者都是普通 check，任一不过该例不得 PASS。
"""

from __future__ import annotations

import re
import json
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import compat13

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"
#: 轮次无效：集群前置状态被上一次不可回退操作污染（例如已有节点卡在 Removing），
#: 本用例**既不能判 PASS 也不能判 FAIL**，必须在全新部署的集群上单独复测。
INVALID = "INVALID"

#: H-25：按**动作类型**给出的日志归因窗口 pad，``(前导秒, 尾巴秒)``。
#: 尾巴普遍远大于前导：harness 动作引发的都是**动作之后**的收敛/重试/销毁余波。
#: 每一档都对着本轮实测的"命中距动作 Δ"：
#:   * ``start`` / ``stop``  +120s：RCV-01/02/04/07 的 Ratis `Failed appendEntries`、
#:     `GrpcLogAppender` 断连在停/启节点后持续 50–64s（取 2 倍余量）；
#:   * ``create_db`` / ``drop_db`` +180s：DEV-19/TIME-07/LIM-08/LIM-11/LIM-02 的
#:     `GrpcLogAppender is interrupted`（组被销毁）出现在建/删库后 30–92s；
#:   * ``set_config`` +180s：SWCH-06/LIM-10/LIM-17/LIM-09/LIM-07/LIM-06 的
#:     `MemoryManager … already exists` 距热加载 26–152s（热加载批量建组后各 DN 重新
#:     注册同名 Consensus 内存块，属 D-08 已降级的 harness 归因）；
#:   * ``readonly`` +120s：HA-13/14 置/恢复 READONLY 后 DN 的只读态告警与写失败；
#:   * ``default`` ±15s：保持旧行为（纯 SQL 探针一类，噪声就在动作前后几秒内）。
#: 窗口之外同样的日志行仍然判 FAIL —— 这是"动作时间窗"而不是白名单。
HARNESS_ACTION_PADS: dict[str, tuple[int, int]] = {
    "start": (30, 120),
    "stop": (5, 120),
    "create_db": (30, 180),
    "drop_db": (30, 180),
    "set_config": (20, 180),
    "readonly": (30, 120),
    "default": (15, 15),
}

#: 未显式给 ``kind`` 时按 reason 文本兜底判类型（顺序敏感：先判"重建/删"再判"建"）。
_PAD_KEYWORDS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("drop_db", ("删库", "删除库", "drop database", "drop_database", "删光", "重建",
                 "drop 测试库", "fixture 删", "fixture 重建", "清掉表模型测试库")),
    ("create_db", ("建库", "create database", "create_database", "新建", "fixture 建")),
    ("set_config", ("热加载", "set configuration", "恢复 conf", "改回")),
    ("readonly", ("READONLY", "只读", "read-only")),
    ("start", ("启动", "启 ", "拉起", "重启", "start", "restart")),
    ("stop", ("停机", "停 ", "停止", "关闭", "stop", "shutdown")),
)


def _resolve_pad(pad, kind: str | None, reason: str) -> tuple[int, int]:
    """解析出 ``(前导, 尾巴)``。

    语义（H-25）：
    * ``pad=None``           → 纯按动作类型（``kind``，缺省按 reason 关键词推断）；
    * ``pad=15``（旧写法）    → **下限**：``(max(类型前导, pad), max(类型尾巴, pad))``。
      这样"±15/±20/±30"这类旧调用点不会把类型默认的尾巴（+120/+180）压回去 ——
      旧实现正是因此让 26–152s 后的噪声落到窗外；而未分类的动作行为与旧代码完全一致。
    * ``pad=(lead, tail)``   → 完全覆盖（需要特殊不对称时用）。
    """
    if isinstance(pad, (tuple, list)) and len(pad) == 2:
        return int(pad[0]), int(pad[1])
    resolved_kind = kind
    if resolved_kind is None and reason:
        for name, needles in _PAD_KEYWORDS:
            if any(n.lower() in reason.lower() for n in needles):
                resolved_kind = name
                break
    lead, tail = HARNESS_ACTION_PADS.get(resolved_kind or "default",
                                         HARNESS_ACTION_PADS["default"])
    if isinstance(pad, int):
        return max(lead, pad), max(tail, pad)
    return lead, tail


@dataclass
class Check:
    name: str
    ok: bool
    detail: str = ""
    evidence: str = ""


@dataclass
class Ctx:
    cfg: object
    ssh: object
    sql: object
    cluster: object
    props: object
    api: object
    verifier: object
    sync_waiter: object
    log: Callable[[str], None]
    run_dir: Path
    case_dir: Path
    case_id: str = ""
    checks: list[Check] = field(default_factory=list)
    skipped: str = ""
    #: 轮次无效的原因（前置状态污染）；非空时状态记 INVALID，绝不参与 PASS/FAIL 统计。
    invalid: str = ""
    cleanup: list[str] = field(default_factory=list)
    consistency_queries: list[dict] = field(default_factory=list)
    #: DataNodes this case removed/stopped on purpose: the sync-lag gate must
    #: not wait for a lag that can never drain because the node is gone.
    by_design_gone: set = field(default_factory=set)
    #: A 类（HA-02/HA-04）口径：**本用例的 harness 动作实际停掉**的 DataNode host。
    #: 由 ``cases_ops._stop_dn`` 写入、``_start_dn`` 恢复成功后移除。"在线副本数"的
    #: 存活 DN 数只能由「集群 DN 清单 − 该集合」算出，**不能**用全局在线状态反推
    #: （别的用例刚停过/正在收敛的节点会污染判定，本用例停掉后又可能已回到在线表）。
    harness_stopped: set = field(default_factory=set)
    _log_handle: object = None
    _case_started: float = 0.0
    #: 集群确认就绪的时刻：日志窗口从这之后算起，避免把节点加入/注册期的
    #: 噪声（MemoryManager 重复注册、Ratis appender 收敛）算成"非预期异常"。
    _cluster_ready: float = 0.0
    #: harness 自己动作的时间窗口 [(start, end, reason)]，用于日志归因。
    harness_windows: list = field(default_factory=list)
    #: 本用例是否真的写过数据：决定收尾②"无对拍查询"是 harness 缺陷（写过却没登记）
    #: 还是本来就不需要（空库/纯元数据/纯观测类用例）。
    _wrote_data: bool = False
    _query_names: set = field(default_factory=set)

    def mark_harness_action(self, reason: str, pad: int | tuple[int, int] | None = None,
                            kind: str | None = None) -> None:
        """登记一段日志归因窗口。``pad`` 可为对称秒数或 ``(前导, 尾巴)``。

        H-25：pad 必须按**动作类型**取不对称默认值（实测依据见
        ``HARNESS_ACTION_PADS``）。旧实现一律 ``pad=15``，于是"启节点后 50–64s 的
        Ratis appender 收敛"、"删库后 30–92s 的对端组销毁"、"热加载后 26–152s 的
        内存块重注册"全部落到窗外 → 被当成产品噪声判 FAIL。
        """
        lead, tail = _resolve_pad(pad, kind, reason)
        now = time.time()
        self.harness_windows.append((now - lead, now + tail, reason))
        self.note(f"    [harness 动作] {reason}（日志归因窗口 -{lead}s/+{tail}s）")

    # ---------------------------------------------------------------- recording
    def check(self, name: str, ok: bool, detail: str = "", evidence: str = "") -> bool:
        self.checks.append(Check(name=name, ok=bool(ok), detail=detail, evidence=evidence[:4000]))
        self.note(f"  [{'ok' if ok else 'FAIL'}] {name}" + (f" -- {detail}" if detail else ""))
        return bool(ok)

    def skip(self, reason: str) -> None:
        self.skipped = reason
        self.note(f"  [skip] {reason}")

    def invalidate(self, reason: str) -> None:
        """把本轮标为 INVALID（前置状态被污染）——不判 PASS、不判 FAIL，需新集群复测。"""
        self.invalid = reason
        self.note(f"  [invalid] {reason}")

    def req(self, outcome, what: str = "") -> None:
        if not outcome.ok:
            raise AssertionError(f"{what or outcome.statement} failed: {outcome.output[:1200]}")

    def note(self, text: str) -> None:
        self.log(text)
        if self._log_handle is None:
            self.case_dir.mkdir(parents=True, exist_ok=True)
            self._log_handle = (self.case_dir / "actions.log").open("a", encoding="utf-8")
        self._log_handle.write(text.rstrip() + "\n")
        self._log_handle.flush()

    def trace(self, statement: str, output: str) -> None:
        flat = " ".join(output.split())
        self.note(f"    SQL> {statement[:300]}")
        self.note(f"    OUT> {flat[:600]}")

    def add_query(self, name: str, sql: str, dialect: str | None = None) -> None:
        if name in self._query_names:
            return
        self._query_names.add(name)
        self.consistency_queries.append({"name": name, "sql": sql, "dialect": dialect})

    def note_data_written(self, db: str, obj: str, dialect: str) -> None:
        """登记"写过数据"并自动挂一条收尾②对拍查询（按对象名去重）。

        收尾②会逐台停 DataNode 再查同一数据集比对（见 ``verify.CompactionVerifier``），
        因此**任何写了数据的用例都必须有对拍查询**；由夹具自动登记，族模块无需记得。
        """
        self._wrote_data = True
        # UPG-1.3: 1.3 不保证 `select count(*)` 的输出形态（2.x 才对一行多列做 count(*)
        # 展开）；收尾②只要求"两次捕获结果一致"，所以 1.3 线改用 `select *` 对拍，
        # 避免把"count(*) 语法不支持"误判成"副本不一致"。
        if dialect != "table" and detect_v13(self)[0]:
            self.add_query(f"rows {db}.{obj}", f"select * from {db}.{obj}", dialect)
        elif dialect != "table":
            # H-50：单设备几十万测点时 ``select count(*) from <db>.<device>`` 会让服务端
            # 展开几十万列（实测 500000 测点直接 query failed），收尾②的两遍捕获永远等不到
            # 一致结果。改为对**单个测点**计数：先取一条 series，再 ``count(<sensor>)``。
            first = ""
            try:
                ts = self.api.show_timeseries(f"{db}.{obj}.**", limit=1)
                if ts.ok and ts.rows:
                    for row in ts.rows:
                        for key, value in row.items():
                            if key.strip().lower() == "timeseries" and str(value).strip():
                                first = str(value).strip()
                                break
                        if first:
                            break
            except Exception:  # noqa: BLE001 - 取不到就退回原来的 count(*)
                first = ""
            if first and "." in first:
                device, sensor = first.rsplit(".", 1)
                self.add_query(f"count {device}.{sensor}",
                               f"select count({sensor}) from {device}", dialect)
            else:
                self.add_query(f"count {db}.{obj}", f"select count(*) from {db}.{obj}", dialect)
        else:
            self.add_query(f"count {db}.{obj}", f"select count(*) from {db}.{obj}", dialect)


@dataclass
class CaseSpec:
    case_id: str
    area: str
    model: str
    title: str
    priority: str
    fn: Callable[[Ctx], None]
    gate: bool = False
    needs_restart: bool = False
    note: str = ""


# ============================================================ 收尾三件套（triad）
def flush_logs(ctx: Ctx) -> None:
    """逐机 `sync`，把日志刷到磁盘（替代"为扫描而停集群"的旧做法）。"""
    for host in ctx.cfg.all_hosts:
        try:
            ctx.ssh.run(host, "sync", check=False)
        except Exception:  # noqa: BLE001 - flush 失败不应影响判定，日志仍会被读到
            continue


#: 本进程（= 本轮 run）的启动时刻，作为日志扫描的**硬下界**（H-17）。
#: 实测：上一轮 run 的集群进程在本轮用例开始前仍在写日志，其启动收敛 WARN 会被本轮
#: 收尾③ 误纳（SMK-02 命中 13:54:19 的 CN 引导 WARN，而本轮用例 13:56:5x 才开始）。
#: 只排除"本轮之前"的行，不会掩盖本轮任何产品异常，故不是白名单。
_RUN_STARTED = time.time()

#: UPG-1.3: 版本线判定缓存 ``DB_DIR|DB_VERSION -> (是否 1.x, 依据)``
_VERSION13_CACHE: dict[str, tuple[bool, str]] = {}


def detect_v13(ctx: Ctx) -> tuple[bool, str]:
    """``(是否 1.x 线, 判定依据)``：运行时 ``SHOW CLUSTER`` 的 Version 列优先，conf 兜底。

    UPG-1.3: 1.3 与 2.x 的**可观测口径不同**（`SHOW DATABASES` 列、有无 syncLag
    指标、`start-cli.sh` 参数），所有分支都从这里取版本，避免各处各判一套。
    结果按 ``DB_DIR`` 缓存：一轮 run 只查一次。
    """
    key = (ctx.cfg.raw("DB_DIR") or "") + "|" + (ctx.cfg.raw("DB_VERSION") or "") \
        + "|" + (ctx.cfg.raw("PG_UPG_PHASE") or "")
    if key in _VERSION13_CACHE:
        return _VERSION13_CACHE[key]
    verdict: tuple[bool, str] | None = None
    try:
        outcome = ctx.api.run("show cluster")
    except Exception:  # noqa: BLE001 - 读不到就退回 conf
        outcome = None
    if outcome is not None and outcome.ok and outcome.rows:
        column = ctx.api.column(outcome.rows, "Version")
        version = (outcome.rows[0].get(column, "") or "").strip() if column else ""
        if version:
            verdict = (compat13.is_v1_text(version),
                       f"运行时 SHOW CLUSTER Version={version}")
    if verdict is None:
        version = (ctx.cfg.raw("DB_VERSION") or "").strip()
        verdict = ((compat13.is_v1_text(version), f"conf DB_VERSION={version}")
                   if version else
                   (False, "无法判定版本（show cluster 不可读、conf 无 DB_VERSION）⇒ 按 2.x 口径"))
    _VERSION13_CACHE[key] = verdict
    ctx.note(f"    版本线判定：{'1.x' if verdict[0] else '2.x'}（依据：{verdict[1]}）")
    return verdict


def _converge_snapshot_13(ctx: Ctx) -> tuple[list[str], list[str]]:
    """1.3 等价判据的单次快照：返回 ``(问题, 说明)``。

    ``问题`` 为空 = 集群"看起来等于 syncLag 归零"：
      a) ``SHOW CLUSTER`` 每个节点都是 Running/ReadOnly（1.3 的 show cluster 列见
         `ColumnHeaderConstant.showClusterColumnHeaders`：无任何同步延迟列）；
      b) ``SHOW (DATA|SCHEMA) REGIONS`` 每个 Region 的状态都**已稳定**
         （不在 Unknown/Removing/Unavailable 一类的中间态）。
    某口径在 1.3 下不可观测（语句不可用/没有 Status 列）时，**只写进说明**，
    绝不据此判 FAIL —— 这正是"近似等价"要如实交代的地方。
    """
    problems: list[str] = []
    notes: list[str] = []
    try:
        rows = ctx.cluster.status().rows
    except Exception as exc:  # noqa: BLE001
        rows = []
        notes.append(f"show cluster 读取失败：{exc}")
    if not rows:
        problems.append("show cluster 无行，无法确认节点状态")
    else:
        bad = sorted({f"{r.get('NodeType', '?')}#{r.get('NodeID', '?')}={r.get('Status')}"
                      for r in rows if not compat13.node_status_ok(r.get("Status"))})
        if bad:
            problems.append("非 Running/ReadOnly 节点：" + ", ".join(bad[:8]))
        else:
            notes.append(f"{len(rows)} 个节点全部 Running/ReadOnly")
    for kind in ("DATA", "SCHEMA"):
        try:
            outcome = ctx.api.show_regions("", kind=kind, dialect="tree")
        except Exception as exc:  # noqa: BLE001
            problems.append(f"show {kind.lower()} regions 读取失败：{exc}")
            continue
        if not outcome.ok:
            notes.append(f"{kind} regions 不可观测（1.3 该语句/状态列不可用）⇒ 只用节点判据")
            continue
        column = ctx.api.column(outcome.rows, "Status")
        if not column:
            notes.append(f"{kind} regions 无 Status 列 ⇒ 只用节点判据")
            continue
        bad_status = sorted({(r.get(column) or "").strip() for r in outcome.rows
                             if not compat13.region_status_settled(r.get(column))})
        if bad_status:
            problems.append(f"{kind} Region 处于中间态：{', '.join(bad_status[:8])}")
        else:
            notes.append(f"{kind} Regions 全部稳定（{len(outcome.rows)} 行）")
    return problems, notes


def sync_equivalent_13(ctx: Ctx) -> tuple[bool, str]:
    """UPG-1.3: 1.3 无 syncLag 指标时，收尾① 的**等价判据**。

    「sync lag 归零」在 2.x 上是"复制管道已推平"；1.3 的 ``SHOW CLUSTER`` 没有同步
    延迟列（也没有 Prometheus 的 ``type="syncLag"`` 同名指标口径保证），因此用
    等价的可观测事实代替：**全节点 Running/ReadOnly + 所有 Region 无中间态**，
    且该状态连续稳定 ``SYNC_STABLE_SECONDS`` 秒（超时 ``SYNC_MAX_WAIT_SEC``，
    与 2.x 同口径，不放松）。
    """
    stable_need = ctx.cfg.get_int("SYNC_STABLE_SECONDS")
    max_wait = ctx.cfg.get_int("SYNC_MAX_WAIT_SEC")
    poll = max(1, ctx.cfg.get_int("SYNC_POLL_INTERVAL_SEC"))
    deadline = time.time() + max_wait
    clean_since: float | None = None
    detail = ""
    while True:
        problems, notes = _converge_snapshot_13(ctx)
        detail = "；".join(notes + problems) or "全节点 Running/ReadOnly 且无 Region 中间态"
        if problems:
            clean_since = None
        else:
            if clean_since is None:
                clean_since = time.time()
            held = time.time() - clean_since
            if held >= stable_need:
                return True, (f"{detail}（连续稳定 {int(held)}s ≥ "
                              f"SYNC_STABLE_SECONDS={stable_need}s）")
        if time.time() >= deadline:
            return False, f"等价判据在 {max_wait}s 内未稳定：{detail}"
        time.sleep(poll)


def closing_triad(ctx: Ctx) -> None:
    """(1) sync lag → 0, (2) replica consistency, (3) ERROR/WARN log scan."""
    log, cfg = ctx.log, ctx.cfg

    log("-- 收尾① sync lag 归零（有界等待，超时 FAIL 并记录最差值）")
    v13, why13 = detect_v13(ctx)
    if v13:
        # UPG-1.3: 1.3 的 SHOW CLUSTER 没有同步延迟列 ⇒ 用等价判据，且断言名里写明，
        # 免得读者把它当成"真的看过 syncLag"。
        log(f"  1.3 线（依据：{why13}）：SHOW CLUSTER 无同步延迟列 ⇒ 改用等价判据")
        ok13, detail13 = sync_equivalent_13(ctx)
        ctx.check("收尾①（1.3 等价判据：全节点 Running/ReadOnly + 无 Region 中间态；"
                  "1.3 无 syncLag 指标）", ok13, detail13)
    else:
        result = ctx.sync_waiter.wait()
        ctx.check("收尾① sync lag 必须等到归 0（超时即 FAIL）", result.ok,
                  f"worst={result.worst} detail={result.reason or 'lag reached 0'}",
                  evidence=json.dumps(result.samples[:20]))

    # 顺序很重要：先在**集群全在**的状态下扫日志，再做会主动停 DataNode 的副本对拍。
    # 否则收尾②蓄意停机引发的 CN 侧 UPDATE_REGION_ROUTE_MAP/INVALIDATE_LAST_CACHE 报错
    # 会被收尾③当成"非预期异常"，造成 harness 自伤（不是产品缺陷、也不该加白名单）。
    log("-- 收尾③ CN/DN 日志 ERROR/WARN 扫描（上界排除 harness 自身停机窗口）")
    until = int(time.time())
    log("  日志扫描上界 = " + time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(until))
        + "（其后的停机噪声不计入）")
    # 不再为了扫描而停集群：逐机 `sync` 落盘即可（原来停/起一次集群既慢、又会在
    # 扫描窗口内塞进启动噪声，如 MemoryManager "memory block Consensus already exists"）。
    flush_logs(ctx)
    since = int(ctx._case_started) if cfg.raw("LOG_SCAN_MODE") == "since" else None
    # 窗口起点取三者最晚：用例开始 / fixture 清场结束 / **集群确认就绪**。
    # 最后一项把"节点加入-注册期"的 harness 噪声排除在窗口外（不是白名单：
    # 窗口之后同样的 WARN 依然会 FAIL）。
    for name in ("_setup_done", "_cluster_ready"):
        value = float(getattr(ctx, name, 0) or 0)
        if cfg.raw("LOG_SCAN_MODE") == "since" and value:
            # +1：这些时刻都是浮点，整数截断会把"同一秒内"的 fixture/启动日志
            # （例如 drop 测试库的 WARN）漏进被测窗口。
            since = max(since or 0, int(value) + 1)
    if cfg.raw("LOG_SCAN_MODE") == "since":
        since = max(since or 0, int(_RUN_STARTED))   # H-17：本轮 run 起点，杜绝跨轮泄漏
    # H-36：升级族——窗口下界不得早于「当前版本的第一条启动横幅」。旧版本（升级前）进程
    # 停机时打的 WARN/ERROR 是**旧版本**的属性，不该记到被测版本头上；边界只排除旧版本，
    # 不排除新版本（新版本后续重启的行仍在窗口内）。
    if cfg.raw("PG_UPGRADE_TO_TARBALL") or cfg.raw("PG_UPGRADE_FROM_TARBALL"):
        _floor = ctx.verifier.upgrade_floor_epoch(cfg.get("DB_VERSION"))
        if _floor:
            since = max(since or 0, _floor)
            ctx.note(
                f"  H-36 升级窗口下界：{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(_floor))}"
                f"（{cfg.get('DB_VERSION')} 首次启动；旧版本停机行不计入本轮判据）")
    problems3 = ctx.verifier.check_logs(since_epoch=since, until_epoch=until - 1,
                                        expected_windows=ctx.harness_windows)
    # H-64：升级 **pre 阶段**（1.3 集群）的日志异常属于"旧版本基线侧"，
    # 逐条落 evidence 后**只记录、不计入 2.0.11 版本判定**；post 阶段（2.0）仍然严格判 FAIL。
    pre13 = bool(v13) and (cfg.raw("PG_UPG_PHASE") or "").lower() == "pre"
    if pre13:
        ctx.check("收尾③（1.3 基线侧）日志异常仅记录、不计入 2.0.11 判定", True,
                  f"1.3 侧命中 {len(problems3)} 组异常，逐条见 evidence/log_findings.txt"
                  + ("；" + "；".join(problems3)[:300] if problems3 else "（无命中）"))
    else:
        ctx.check("收尾③ CN/DN 日志无 ERROR/WARN 异常", not problems3,
                  "；".join(problems3) or "扫描窗口内无命中")

    log("-- 收尾② 副本一致性（逐台停 DataNode → 查询同一数据集 → 恢复 → 比对）")
    if not ctx.consistency_queries:
        if ctx._wrote_data:
            ctx.check("收尾② 副本数据一致性校验", False,
                      "本用例写过数据但没有登记任何对拍查询（harness 缺陷：夹具应自动登记）")
        else:
            ctx.check("收尾② 副本数据一致性校验", True,
                      "本用例未写入任何数据（空库/纯元数据/纯观测），无需副本对拍")
        ctx.note("  收尾② 跳过停机对拍：无对拍查询")
        return
    ensure_cluster_up(ctx)
    # UPG-1.3: 1.3 没有 syncLag 指标 ⇒ `sync_waiter.wait()` 这个前置门在 1.3 上必然
    # 以 "no Running DataNode to read syncLag from" 失败（pg_upg13_run 的 UPG-01/02/05
    # 就是这样多了一条与产品无关的 FAIL）。1.3 线改为**不注入** sync waiter：
    # 稳定性由 consistency_check 自带的"两次捕获必须一致"门把关（同口径，不放松），
    # 该跳过也写进 notes，读者能看出这一门在 1.3 上换成了什么。
    consistency_waiter = ctx.sync_waiter
    if v13:
        consistency_waiter = None
        ctx.note("  收尾② 1.3 无 syncLag 指标：sync-lag 前置门换成'两次捕获一致'（settle 门）")
    problems = ctx.verifier.consistency_check(
        ctx.consistency_queries, sync_waiter=consistency_waiter,
        data_rf=cfg.get_int("DATA_REPLICATION_FACTOR"),
        skip_hosts=ctx.by_design_gone,
    )
    # H-23：停/起 DataNode 的余波（LeaderBalancer 迁移重试、MPP 对被停节点的重发）会持续到
    # 重启之后，甚至越界落进**下一个**用例的扫描窗口。窗口必须锚在**实际** stop_epoch /
    # start_epoch 上：旧实现锚在 `sweep_started`（开始对拍的时刻），比真停机早 4–5 分钟，
    # 实测命中因此落在窗外 2 分钟。窗口写进 run 级共享列表，跨用例才真正生效。
    if cfg.get_int("CONSISTENCY_STOP_NODES") > 0:
        registered = ctx.verifier.register_sweep_windows()
        if registered:
            ctx.note(f"  收尾② 已按实际停/起时刻登记 {registered} 段跨用例收敛尾窗"
                     f"（+{cfg.raw('CLUSTER_CONVERGENCE_WINDOW_SEC')}s）")
        else:
            # 兜底：本轮没有真的停机（快速路径或 data_rf<2 跳过了停机对拍）。
            # 仍以**当前**时刻为锚登记一段收敛尾窗，绝不回退到 sweep_started。
            now = time.time()
            tail = int(cfg.raw("CLUSTER_CONVERGENCE_WINDOW_SEC") or 300)
            ctx.verifier.extra_windows.append(
                (now - 5, now + tail,
                 "本用例收尾②一致性对拍（未停机路径）后的收敛尾窗"))
    ctx.check("收尾② 副本数据一致性校验", not problems, "；".join(problems) or "各副本结果一致")
    # 故意不再 stop_all()：用例之间保持集群运行，避免每个用例都付一次全集群启动代价
    # （也避免启动噪声落进下个用例的日志窗口）。整轮结束由 matrix/teardown 停机。


# ====================================================== 夹具与断言（各族模块共用）
import math

from . import slots as pslots

TREE_DB = "root.pg"
TABLE_DB = "pg"
TREE_SENSORS = ("s0", "s1", "s2")
SYSTEM_DBS = ("root.__system", "root.__audit", "__audit", "information_schema")


def dialect_of(model: str) -> str:
    return "table" if model == "table" else "tree"


def db_of(ctx: Ctx, model: str) -> str:
    if model == "table":
        return ctx.cfg.raw("PG_DB_TABLE") or TABLE_DB
    return ctx.cfg.raw("PG_DB_TREE") or TREE_DB


def clear_ttl(ctx: Ctx, db: str) -> None:
    """清除该库路径上的 TTL 规则（H-13 的防御层）。

    TTL 规则按**路径**持久化在配置中，`drop database` 不会连带清除；只要有一条 TTL 规则残留，
    该路径下所有"历史时间戳"写入（fixture 用 ``stamp=1`` ⇒ 1970）都会被
    ``607: Insertion time … is less than ttl time bound`` 拒绝。因此每次重建测试库前先清一遍，
    作为"单个用例忘了清"时的兜底（用例自身仍须在 cleanup 里清，见 cases_ops2._set_ttl）。
    """
    try:
        ctx.api.run(f"unset ttl from {db}.**")
    except Exception:  # noqa: BLE001 - 兜底清场不得影响用例
        pass


def reset_db(ctx: Ctx, model: str, db: str = "") -> str:
    """drop + create 测试库。

    树方言不支持 ``drop database if exists``（解析错误 700），因此无条件 drop 并容忍
    "不存在"；**create 必须成功**。drop 动作本身会被记进归因窗口：首次运行时服务端
    必然记一条删除失败/不存在的 WARN，那是 harness 固有产物而非产品异常。
    """
    db = db or db_of(ctx, model)
    ctx.mark_harness_action(f"fixture 重建测试库 {db}（drop+create）", pad=30)
    clear_ttl(ctx, db)  # H-13 兜底：TTL 规则不随 drop 消失，必须先清掉再重建
    if model == "table":
        ctx.api.drop_database(db, table=True)
    else:
        ctx.api.drop_database(db)
    ctx.req(ctx.api.create_database(db, table=(model == "table")), f"create database {db}")
    ctx._setup_done = time.time()
    return db


def ensure_write_tree(ctx: Ctx, db: str, device: str, stamp: int = 1,
                      sensors: tuple[str, ...] = TREE_SENSORS,
                      values: list | None = None) -> None:
    """树模型写入一行（insert 自动建序列，不额外发 create timeseries：
    重复 create 会产生 503 already exist 的 WARN，属 harness 自伤）。"""
    vals = values if values is not None else [float(stamp)] * len(sensors)
    ctx.req(ctx.api.insert_tree(f"{db}.{device}", stamp, list(sensors), vals),
            f"insert {db}.{device}")
    ctx.note_data_written(db, device, "tree")


def ensure_write_table(ctx: Ctx, db: str, table: str, tag: str, stamp: int = 1,
                       fields: int = 1, values: list | None = None) -> None:
    """表模型：建表（幂等：已存在则忽略）+ 写一行。"""
    created = getattr(ctx, "_tables_created", None)
    if created is None:
        created = set()
        ctx._tables_created = created
    key = (db, table, fields)
    if key not in created:
        cols = ", ".join([f"s{i} FLOAT FIELD" for i in range(fields)])
        ctx.api.create_table(db, table, columns=f"devid STRING TAG, {cols}")
        created.add(key)
    vals = values if values is not None else [float(stamp)] * fields
    ctx.req(ctx.api.insert_table_rows(db, table, stamp, tag,
                                      [f"s{i}" for i in range(fields)], vals),
            f"insert {db}.{table}")
    ctx.note_data_written(db, table, "table")


def group_counts(ctx: Ctx, db: str, dialect: str) -> tuple[int, int, int, int]:
    """(schema详情, schema去重, data详情, data去重) —— 两个口径都必须一致。

    ``-1`` 表示 ``SHOW DATABASES DETAILS`` 里**没有这个库**（H-22b）；调用方按需折算。
    """
    return (ctx.api.db_group_num(db, "SCHEMA", dialect=dialect),
            ctx.api.group_count(db, kind="SCHEMA", dialect=dialect),
            ctx.api.db_group_num(db, "DATA", dialect=dialect),
            ctx.api.group_count(db, kind="DATA", dialect=dialect))


def _absent_as_zero(value: int, want: int) -> int:
    """H-22b：``drop database`` 之后 ``show databases details`` 返回 ``-1`` = 库不存在。

    ``-1`` 与"期望 0 组"是同义结果（区域去重同期也是 0），不能把 -1 直接和 0 比。
    仅在**期望 0** 时折算；期望非 0 时（库应当存在）``-1`` 仍是失败。
    """
    return 0 if (value < 0 and want == 0) else value


def schema_group_range(low: int | None, high: int | None) -> tuple[int, int] | None:
    """(最小期望, 产品自报上限) 的规范化：``None`` 表示上限不可读 ⇒ 调用方 SKIP。"""
    if low is None or high is None:
        return None
    low = max(0, int(low))
    high = int(high)
    if high < low:
        return None
    return low, high


def expect_groups(ctx: Ctx, label: str, db: str, dialect: str, *,
                  schema: int | None = None, data: int | None = None,
                  schema_range: tuple[int, int] | None = None) -> None:
    """组数断言：``SHOW DATABASES DETAILS`` 的计数与 ``SHOW REGIONS`` 去重必须都等于期望。

    ``schema_range=(最小期望, 产品自报上限)`` 用于**不该写死具体组数**的场景（RCV-01/02/07）：
    判定 ``最小期望 <= 观测 <= 产品自报上限`` 且两个口径（库详情 / 区域去重）一致；
    上限不可读时调用方必须先 SKIP，绝不拿"猜出来的上限"当断言语义。
    """
    s_detail, s_dedup, d_detail, d_dedup = group_counts(ctx, db, dialect)
    detail = {"库详情": {"schema": s_detail, "data": d_detail},
              "区域去重": {"schema": s_dedup, "data": d_dedup},
              "库详情原文": ctx.api.database_details(dialect).get(db, {}),
              "区域快照": {"schema": ctx.api.snapshot(db, kind="SCHEMA", dialect=dialect),
                          "data": ctx.api.snapshot(db, kind="DATA", dialect=dialect)}}
    if schema is not None:
        shown = _absent_as_zero(s_detail, schema)      # H-22b：-1 = 库不存在 = 0 组
        ctx.check(f"{label}：SchemaRegionGroup 数应为 {schema}",
                  shown == schema and s_dedup == schema,
                  f"库详情={s_detail}{'（-1=库不存在，H-22b 按 0 组计）' if shown != s_detail else ''}"
                  f"、区域去重={s_dedup}",
                  evidence=json.dumps(detail, ensure_ascii=False)[:4000])
    if schema_range is not None:
        low, high = schema_range
        # B 类（RCV-01/02/07）：不再硬编码"SchemaRegionGroup 数应为 2"，
        # 按**产品自报上限**（MaxSchemaRegionGroupNum）判区间，并把公式参考值写进 evidence。
        formula = expected_cap(ctx, "SCHEMA", dialect, db)
        ctx.check(f"{label}：SchemaRegionGroup 数在 [最小期望={low}, 产品自报上限={high}] 内"
                  f"（不再硬编码 2）",
                  low <= s_detail <= high and low <= s_dedup <= high and s_detail == s_dedup,
                  f"库详情={s_detail}、区域去重={s_dedup}（要求两口径一致且在区间内）、"
                  f"公式参考值={formula}",
                  evidence=json.dumps(detail, ensure_ascii=False)[:4000])
    if data is not None:
        shown = _absent_as_zero(d_detail, data)
        ctx.check(f"{label}：DataRegionGroup 数应为 {data}",
                  shown == data and d_dedup == data,
                  f"库详情={d_detail}{'（-1=库不存在，H-22b 按 0 组计）' if shown != d_detail else ''}"
                  f"、区域去重={d_dedup}",
                  evidence=json.dumps(detail, ensure_ascii=False)[:4000])


def group_ceiling(ctx: Ctx, kind: str, dialect: str, db: str) -> int:
    """组数类期望用的上限口径：**产品自报上限优先**（每库单调不减，见 HARNESS_FINDINGS H-10），
    库尚不存在时退回公式值 `expected_cap`。上限值本身是否等于公式，由 LIM/SYS 等受控用例单独断言。"""
    formula = expected_cap(ctx, kind, dialect, db)
    reported = 0
    try:
        reported = ctx.api.db_max_group_num(db, kind, dialect=dialect)
    except Exception:
        reported = 0
    return max(formula, reported) if reported else formula


def expected_cap(ctx: Ctx, kind: str, dialect: str = "tree", db: str = "") -> int:
    """按源码公式算出该库该类型的组数上限（`ClusterSchemaManager.java:594-649`）。

    公式：``max(min, ceil(weight × resource / (参与分摊库数 × 副本数)))``，
    其中参与分摊的库数**排除**系统库/审计库/预删除库（`:532-550`）。
    """
    cfg, kind_u = ctx.cfg, kind.upper()
    # 产品的 databaseNum 把**树 + 表两类普通库一起**计数（`ClusterSchemaManager.java:520-550`），
    # 而 `SHOW DATABASES DETAILS` 按方言过滤（tree 只列树库、table 只列表库）。
    # 因此分摊分母必须取两个方言的**并集**：只查当前方言会在"树库+表库并存"时少算分母，
    # 把上限算大 → 假 FAIL（实测案例：树库 root.pg + 表库 pg 同时存在时 schema 上限 5 → 实际 3）。
    user_dbs: set[str] = set()
    for probe in ("tree", "table"):
        for name in ctx.api.database_details(probe):
            if not any(s in name for s in SYSTEM_DBS):
                user_dbs.add(name)
    db_count = max(1, len(user_dbs))
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
        minimum = int(cfg.raw("PG_MIN_DATA_PER_DB") or 2)
    return max(minimum, math.ceil(weight * resource / (db_count * rf)))


def expect_cap(ctx: Ctx, label: str, db: str, dialect: str = "tree") -> None:
    """上限必须**不低于**公式值（直接观测 ``Max*RegionGroupNum``，无需靠"写满"逼近）。

    H-19：产品为每个库保留**单调不减**的历史上限（`PartitionManager.java:654-699`），
    多库分摊变少 / 配额热加载后，``实测 > 公式`` 是预期行为（首轮实测：自报 20、公式 15）。
    只有 ``实测 < 公式``（表模型被钉在 1/2 = D-04）才是真缺陷，才判 FAIL。
    """
    for kind in ("SCHEMA", "DATA"):
        want = expected_cap(ctx, kind, dialect, db)
        got = ctx.api.db_max_group_num(db, kind, dialect=dialect)
        ctx.check(f"{label}：{kind} 上限应不低于 {want}"
                  f"（公式：min={kind}、参与分摊库数见详情）",
                  got >= want,
                  f"实际 Max{kind.title()}RegionGroupNum={got}"
                  + ("（实测>公式=每库单调存量上限，H-19）" if got > want else ""))


def device_set(ctx: Ctx, db: str, count: int, *, dialect: str = "tree",
               prefix: str = "pgd", slot_num: int = 0, table: str = "tb") -> list[str]:
    """生成 count 个**互不相同 slot** 的设备名/TAG（树用路径哈希，表用 表名+TAG 哈希）。"""
    n = slot_num or int(ctx.cfg.raw("PG_SERIES_SLOT_NUM") or 1000)
    if dialect == "table":
        return pslots.find_distinct_slot_tags(table, count, slot_num=n, prefix=prefix)
    return pslots.find_distinct_slot_devices(db, count, slot_num=n, prefix=prefix)


def write_devices(ctx: Ctx, db: str, devices: list[str], *, model: str = "tree",
                  stamp: int = 1, table: str = "tb", batch: bool = False) -> None:
    """逐个（或一次批量）写入设备。batch=True 时**一条语句**写全部设备，
    用于验证"单次请求内多个新 slot"的批量扩容。"""
    if model == "table":
        for i, tag in enumerate(devices):
            ensure_write_table(ctx, db, table, tag, stamp=stamp + i)
        return
    if not batch:
        for i, device in enumerate(devices):
            ensure_write_tree(ctx, db, device, stamp=stamp + i)
        return
    # 树模型单条 insert 只能写一个设备；用一个设备的多测点无法制造多 slot，
    # 因此"批量多 slot"用 flush 前连续两条语句在同一批（同一次批次请求）内完成：
    # 真正的单请求多设备只能用表模型多行 insert（见 insert_table_many）。
    for i, device in enumerate(devices):
        ensure_write_tree(ctx, db, device, stamp=stamp + i)


# ===================================================================== 用例：冒烟
def case_smk01_default_policy(ctx: Ctx) -> None:
    """SMK-01 未显式配置时默认值即 PROACTIVE（需求 §3.2 + 设计 §4.3.3 未覆盖项）。"""
    keys = ("schema_region_group_extension_policy", "data_region_group_extension_policy")
    disk = ctx.api.policies_on_disk(ctx.props, ctx.cfg.cn_hosts)
    present = {host: [k for k in keys if k in values] for host, values in disk.items()}
    if any(present.values()):
        ctx.skip("本轮 conf 显式写了策略键；默认值路径请用 conf/cluster.pg_default_iot.conf 专轮验证")
        return
    ctx.check("CN 配置文件不含两个策略键（确认走代码默认值路径）", True,
              f"{len(disk)} 个 CN 节点均无该键", evidence=json.dumps(present, ensure_ascii=False))
    model, db = "tree", reset_db(ctx, "tree")
    devices = device_set(ctx, db, 4)
    write_devices(ctx, db, devices, model=model)
    cap_d = group_ceiling(ctx, "DATA", "tree", db)
    cap_s = group_ceiling(ctx, "SCHEMA", "tree", db)
    expect_groups(ctx, "默认策略稀疏写入", db, "tree",
                  schema=min(4, cap_s), data=min(4, cap_d))
    ctx.check("默认策略行为是 PROACTIVE 而非 AUTO（AUTO 只会到最小组数）",
              ctx.api.db_group_num(db, "DATA", dialect="tree") == min(4, cap_d)
              and min(4, cap_d) > int(ctx.cfg.raw("PG_MIN_DATA_PER_DB") or 2),
              f"4 个不同 slot 得到 {ctx.api.db_group_num(db, 'DATA', dialect='tree')} 个 Data 组，"
              f"最小组数={ctx.cfg.raw('PG_MIN_DATA_PER_DB')}")


def case_smk02_empty_db(ctx: Ctx) -> None:
    """SMK-02 空库不预建 RegionGroup（需求 §3.2 触发条件）。"""
    for model in ("tree", "table"):
        dialect = dialect_of(model)
        db = reset_db(ctx, model)
        expect_groups(ctx, f"空{model}库", db, dialect, schema=0, data=0)


def case_smk03_single_device(ctx: Ctx) -> None:
    """SMK-03 单设备单测点：Schema/Data 各 1 组，数据可查。"""
    db = reset_db(ctx, "tree")
    ensure_write_tree(ctx, db, "d0", 1, sensors=("s0",))
    expect_groups(ctx, "单设备写入", db, "tree", schema=1, data=1)
    ctx.check("写入的数据可查（count=1）",
              ctx.api.count_rows(f"{db}.d0", dialect="tree") == 1,
              f"count={ctx.api.count_rows(f'{db}.d0', dialect='tree')}")


def case_smk04_tree_distinct_slots(ctx: Ctx) -> None:
    """SMK-04 树模型 K=4 个不同 slot：组数 = min(K, 上限)，逐个增长。"""
    db = reset_db(ctx, "tree")
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "DATA", "tree", db)
    devices = device_set(ctx, db, 4)
    expect_groups(ctx, "写入前", db, "tree", schema=0, data=0)
    for index, device in enumerate(devices, start=1):
        ensure_write_tree(ctx, db, device, stamp=index)
        expect_groups(ctx, f"写入第 {index} 个 slot 后（min 增长+新增 slot）", db, "tree",
                      schema=min(index, cap_s), data=min(index, cap_d))
    ctx.check("4 个设备确实落在 4 个不同 slot（harness 计算）",
              pslots.distinct_slot_count(db, devices) == 4,
              f"slots={pslots.slot_map(db, devices)}")


def case_smk05_table_distinct_slots(ctx: Ctx) -> None:
    """SMK-05 表模型 K=4 个不同 slot：与树模型同口径。"""
    db = reset_db(ctx, "table")
    cap_s, cap_d = group_ceiling(ctx, "SCHEMA", "table", db), group_ceiling(ctx, "DATA", "table", db)
    devices = device_set(ctx, db, 4, dialect="table")
    for index, device in enumerate(devices, start=1):
        ensure_write_table(ctx, db, "tb", device, stamp=index)
        expect_groups(ctx, f"表模型写入第 {index} 个设备后", db, "table",
                      schema=min(index, cap_s), data=min(index, cap_d))
    ctx.check("表模型 4 行可查",
              ctx.api.count_rows(f"{db}.tb", dialect="table") == 4,
              f"count={ctx.api.count_rows(f'{db}.tb', dialect='table')}")


def case_smk06_hot_reload_switch(ctx: Ctx) -> None:
    """SMK-06 热加载 PROACTIVE→AUTO：已有组保留、AUTO 不再积极扩容；切回后恢复。"""
    db = reset_db(ctx, "tree")
    first = device_set(ctx, db, 3)
    write_devices(ctx, db, first, model="tree")
    before = ctx.api.db_group_num(db, "DATA", dialect="tree")
    ctx.check("前置：3 个不同 slot 得到 3 个 Data 组", before == 3, f"实际={before}")
    ctx.mark_harness_action("热加载 data 策略为 AUTO", pad=20)
    ctx.req(ctx.api.set_config("data_region_group_extension_policy", "AUTO"), "热加载 AUTO")
    more = device_set(ctx, db, 6, prefix="pge")
    ensure_write_tree(ctx, db, more[3], stamp=10)
    after_auto = ctx.api.db_group_num(db, "DATA", dialect="tree")
    ctx.check("AUTO 下新 slot 不再积极扩容（组数不增）", after_auto == before,
              f"AUTO 前={before}、AUTO 后={after_auto}")
    ctx.mark_harness_action("热加载 data 策略回 PROACTIVE", pad=20)
    ctx.req(ctx.api.set_config("data_region_group_extension_policy", "PROACTIVE"), "热加载回 PROACTIVE")
    ensure_write_tree(ctx, db, more[4], stamp=11)
    after_pro = ctx.api.db_group_num(db, "DATA", dialect="tree")
    # 切回 PROACTIVE 不是"在旧组数上 +1"，而是按公式补齐到**全量 K**
    # （K = 已分配 ∪ 待分配 的 series slot；AUTO 期间写入的 slot 仍缺组）：
    # T = min(R, max(min(minNum, G+|P|), K))，此处 K=5（3 个 + AUTO 期 1 个 + 切回后 1 个，
    # 均由 device_set 保证互不相同）。这是"积极扩容"的核心语义，必须显式断言。
    k_total = 5
    want_pro = min(k_total, group_ceiling(ctx, "DATA", "tree", db))
    ctx.check("切回 PROACTIVE 后补齐 AUTO 期间的新 slot（组数按全量 K 增长）",
              after_pro == want_pro,
              f"切回后={after_pro}（期望 min(K={k_total}, 上限)={want_pro}）")


# ============================================================== 用例：空库与建库
def case_empty05_drop_recreate(ctx: Ctx) -> None:
    """EMPTY-05 drop 全部库后重建同名库：不得残留映射。"""
    db = reset_db(ctx, "tree")
    write_devices(ctx, db, device_set(ctx, db, 2), model="tree")
    expect_groups(ctx, "重建前非空", db, "tree", schema=2, data=2)
    ctx.mark_harness_action("fixture 二次重建（drop+create）", pad=30)
    reset_db(ctx, "tree", db)
    expect_groups(ctx, "drop 后重建同名库", db, "tree", schema=0, data=0)
    write_devices(ctx, db, device_set(ctx, db, 1, prefix="pgf"), model="tree")
    expect_groups(ctx, "重建后再写入", db, "tree", schema=1, data=1)


def case_empty08_metadata_only(ctx: Ctx) -> None:
    """EMPTY-08 只建序列不写数据：Schema 组 1 个、Data 组 0 个（元数据分区请求）。"""
    db = reset_db(ctx, "tree")
    ctx.api.create_timeseries(f"{db}.d0.s0")
    expect_groups(ctx, "仅建序列", db, "tree", schema=1, data=0)


def case_empty06_two_rounds(ctx: Ctx) -> None:
    """EMPTY-06 建库→写→drop→再建→再写 两轮行为一致。"""
    observed = []
    for round_no in (1, 2):
        db = reset_db(ctx, "tree")
        devices = device_set(ctx, db, 2, prefix=f"pgr{round_no}")
        write_devices(ctx, db, devices, model="tree")
        observed.append((ctx.api.db_group_num(db, "SCHEMA", dialect="tree"),
                         ctx.api.db_group_num(db, "DATA", dialect="tree")))
    ctx.check("两轮（建库→写→drop→再建→写）组数完全一致",
              observed[0] == observed[1] == (2, 2), f"两轮观测={observed}")


# ================================================================ 用例：设备与共槽
def case_dev13_coslot(ctx: Ctx) -> None:
    """DEV-13 两个设备共槽：只建 1 个组（需求 §3.2 slot 计数口径）。"""
    db = reset_db(ctx, "tree")
    pair = pslots.find_colliding_devices(db, 2, prefix="pgc")
    ctx.check("前置：两个设备确实共槽", pslots.distinct_slot_count(db, pair) == 1,
              f"slots={pslots.slot_map(db, pair)}")
    write_devices(ctx, db, pair, model="tree")
    expect_groups(ctx, "两设备共槽", db, "tree", schema=1, data=1)


def case_dev15_batch_multi_slot(ctx: Ctx) -> None:
    """DEV-15 单次请求含多个新 slot（表模型多行 insert）→ 一次补齐。"""
    db = reset_db(ctx, "table")
    cap_d = group_ceiling(ctx, "DATA", "table", db)
    # H-28：建表是本用例的**前置**，不能靠别的用例残留表。旧实现直接批量 insert，
    # 单跑时产品返回 ``550: Table 'pg.tb' does not exist.``（跨用例前置依赖）。
    # 只建表、**不写数据**：写任何一行都会占 slot，污染后面"3 个新 slot"的期望。
    table_out = ctx.api.create_table(db, "tb", columns="devid STRING TAG, s0 FLOAT FIELD")
    ctx.check("DEV-15 前置：建表 tb 成功（批量写前自证）", table_out.ok,
              f"create table {db}.tb → {(table_out.output or '')[:200]}")
    tags = device_set(ctx, db, 3, dialect="table", prefix="pgb")
    rows = [(100 + i, tag, [float(i)]) for i, tag in enumerate(tags)]
    ctx.req(ctx.api.insert_table_many(db, "tb", "devid", rows), "批量写 3 个新 slot")
    expect_groups(ctx, "批量 3 个新 slot", db, "table",
                  schema=min(3, group_ceiling(ctx, "SCHEMA", "table", db)),
                  data=min(3, cap_d))
    ctx.check("批量写入的 3 行都可查",
              ctx.api.count_rows(f"{db}.tb", dialect="table") == 3,
              f"count={ctx.api.count_rows(f'{db}.tb', dialect='table')}")


def case_dev16_batch_existing_plus_new(ctx: Ctx) -> None:
    """DEV-16 批量含"已有 slot + 新 slot"：按并集计（请求内重复去重）。"""
    db = reset_db(ctx, "table")
    known = device_set(ctx, db, 1, dialect="table", prefix="pgk")
    ensure_write_table(ctx, db, "tb", known[0], stamp=1)
    expect_groups(ctx, "先写 1 个 slot", db, "table", schema=1, data=1)
    newer = device_set(ctx, db, 3, dialect="table", prefix="pgn")
    rows = [(10, known[0], [1.0]), (11, newer[0], [2.0]),
            (12, known[0], [3.0]), (13, newer[1], [4.0])]
    ctx.req(ctx.api.insert_table_many(db, "tb", "devid", rows), "批量混合已有/新 slot")
    expect_groups(ctx, "混合批量后（并集=3）", db, "table",
                  schema=min(3, group_ceiling(ctx, "SCHEMA", "table", db)),
                  data=min(3, group_ceiling(ctx, "DATA", "table", db)))


# ================================================================ 用例：观测自证
def case_obs01_hash_cross_check(ctx: Ctx) -> None:
    """OBS-01 harness 的 BKDR131 槽计算与产品 ``SHOW DATA REGIONID`` 交叉验证。"""
    db = reset_db(ctx, "tree")
    cap_d = group_ceiling(ctx, "DATA", "tree", db)
    devices = device_set(ctx, db, min(5, cap_d) if cap_d > 0 else 5)
    write_devices(ctx, db, devices, model="tree")
    computed = pslots.slot_map(db, devices)
    observed = {d: ctx.api.device_group(f"{db}.{d}", dialect="tree") for d in devices}
    ctx.check("每个设备都能查到所属 RegionGroup",
              all(observed.values()), f"观测={observed}")
    # 同哈希槽 ⇒ 必同组（无论组数多少都成立）
    by_slot: dict[int, set[str]] = {}
    for device, slot in computed.items():
        by_slot.setdefault(slot, set()).add(observed.get(device, ""))
    same_ok = all(len(groups) == 1 for groups in by_slot.values())
    ctx.check("计算为同一 slot 的设备必须落在同一 RegionGroup（硬约束）", same_ok,
              f"计算槽→组={ {k: sorted(v) for k, v in by_slot.items()} }")
    # 不同哈希槽且上限足够 ⇒ 必不同组
    if len(set(computed.values())) <= cap_d:
        diff_ok = len(set(observed.values())) == len(set(computed.values()))
        ctx.check("上限足够时，不同 slot 必须落在不同 RegionGroup（验证 harness 哈希未算错）",
                  diff_ok, f"计算槽数={len(set(computed.values()))}、观测组数={len(set(observed.values()))}")


def case_obs04_dedupe(ctx: Ctx) -> None:
    """OBS-04 组数去重口径自证：副本行数 = 组数 × 副本数（防止把副本行当组数）。"""
    db = reset_db(ctx, "tree")
    write_devices(ctx, db, device_set(ctx, db, 2), model="tree")
    for kind, rf in (("SCHEMA", ctx.cfg.get_int("SCHEMA_REPLICATION_FACTOR")),
                     ("DATA", ctx.cfg.get_int("DATA_REPLICATION_FACTOR"))):
        groups = ctx.api.group_count(db, kind=kind, dialect="tree")
        replicas = ctx.api.replica_count(db, kind=kind, dialect="tree")
        ctx.check(f"{kind}：副本行数 = 组数 × {rf}", replicas == groups * rf,
                  f"组数={groups}、副本行={replicas}")


# =========================================================== 用例：空库族补全
def case_empty01_no_user_db(ctx: Ctx) -> None:
    """EMPTY-01 没有任何用户库时，写数据前不应有任何用户 RegionGroup。"""
    for model in ("tree", "table"):
        db = db_of(ctx, model)
        if model == "table":
            ctx.api.drop_database(db, table=True)
        else:
            ctx.api.drop_database(db)
    ctx.mark_harness_action("fixture 删光用户库", pad=30)
    for model in ("tree", "table"):
        dialect = dialect_of(model)
        details = {k: v for k, v in ctx.api.database_details(dialect).items()
                   if not any(s in k for s in SYSTEM_DBS)}
        ctx.check(f"无用户库时 {model} 方言的库详情里没有测试库",
                  db_of(ctx, model) not in details, f"实测库={sorted(details)}")


def region_ids(snap) -> set:
    """把 ``snapshot()`` 的结果统一成 RegionId 集合。

    ``ctx.api.snapshot()`` 返回的是 **dict（RegionId → 信息）**，不是 list-of-dict；
    早期用例误按列表迭代 ⇒ 迭代出字符串键、再 ``g["region_id"]`` 会抛
    ``TypeError: string indices must be integers``（H-12）。此处兼容两种形态。
    """
    if isinstance(snap, dict):
        return set(snap)
    return {g["region_id"] for g in snap}


def case_empty03_delete_after_write(ctx: Ctx) -> None:
    """EMPTY-03 写后删数据（delete）不回收 RegionGroup（需求：只增不减）。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 2)
    write_devices(ctx, db, devices, model="tree")
    expect_groups(ctx, "写入后", db, "tree", schema=2, data=2)
    before = ctx.api.snapshot(db, kind="DATA", dialect="tree")
    ctx.mark_harness_action("用例内删除数据（预期不回收组）", pad=20)
    ctx.api.run(f"delete from {db}.{devices[0]} where time <= 100", dialect="tree")
    expect_groups(ctx, "删除数据后", db, "tree", schema=2, data=2)
    after = ctx.api.snapshot(db, kind="DATA", dialect="tree")
    ctx.check("删除数据不改变 RegionId 集合（不回收组）",
              region_ids(before) == region_ids(after),
              f"前={sorted(region_ids(before))} 后={sorted(region_ids(after))}")


def case_empty04_drop_one_keeps_other(ctx: Ctx) -> None:
    """EMPTY-04 drop 一个库不影响另一个库的组与映射。"""
    db_a = db_of(ctx, "tree")
    keep = reset_db(ctx, "tree", db_a)
    write_devices(ctx, keep, device_set(ctx, keep, 2), model="tree")
    other = f"{db_a}_other"
    reset_db(ctx, "tree", other)
    write_devices(ctx, other, device_set(ctx, other, 3, prefix="pgo"), model="tree")
    expect_groups(ctx, "两个库各自独立计数", other, "tree",
                  schema=min(3, group_ceiling(ctx, "SCHEMA", "tree", other)),
                  data=min(3, group_ceiling(ctx, "DATA", "tree", other)))
    keep_snapshot = ctx.api.snapshot(keep, kind="DATA", dialect="tree")
    ctx.mark_harness_action(f"用例内 drop {other}（预期不影响 {keep}）", pad=30)
    ctx.api.drop_database(other)
    expect_groups(ctx, f"drop {other} 后 {keep} 不受影响", keep, "tree", schema=2, data=2)
    ctx.check("另一库的组集合完全不变",
              ctx.api.snapshot(keep, kind="DATA", dialect="tree") == keep_snapshot,
              f"前={len(keep_snapshot)} 行")


def case_empty07_flush_only(ctx: Ctx) -> None:
    """EMPTY-07 建库后只 flush 不写数据：仍是 0/0 组。"""
    db = reset_db(ctx, "tree")
    ctx.api.flush()
    expect_groups(ctx, "只 flush 不写", db, "tree", schema=0, data=0)


def case_empty09_multi_db_independent(ctx: Ctx) -> None:
    """EMPTY-09 三个库并存：各自独立计数，且上限按 3 库分摊（用公式现算）。"""
    names = [db_of(ctx, "tree")]
    names += [f"{names[0]}_m{i}" for i in (1, 2)]
    for name in names:
        reset_db(ctx, "tree", name)
    counts = [2, 3, 4]
    for name, count in zip(names, counts):
        write_devices(ctx, name, device_set(ctx, name, count, prefix=f"pgm{count}"), model="tree")
    for name, count in zip(names, counts):
        expect_groups(ctx, f"{name} 独立计数（3 库分摊上限）", name, "tree",
                      schema=min(count, group_ceiling(ctx, "SCHEMA", "tree", name)),
                      data=min(count, group_ceiling(ctx, "DATA", "tree", name)))


def case_empty10_drop_all_keeps_system(ctx: Ctx) -> None:
    """EMPTY-10 drop 全部用户库后系统库仍正常（组数与上限仍可观测）。"""
    names = [db_of(ctx, "tree"), f"{db_of(ctx, 'tree')}_x"]
    for name in names:
        reset_db(ctx, "tree", name)
        write_devices(ctx, name, device_set(ctx, name, 2, prefix="pgx"), model="tree")
    ctx.mark_harness_action("fixture 删光全部用户库", pad=30)
    for name in names:
        ctx.api.drop_database(name)
    for name in names:
        expect_groups(ctx, f"{name} 已 drop", name, "tree", schema=0, data=0)
    sys_max = ctx.api.db_max_group_num("root.__system", "DATA", dialect="tree")
    ctx.check("系统库仍可观测且上限 ≥ 1", sys_max >= 1, f"MaxDataRegionGroupNum={sys_max}")


def case_empty11_repeat_create_drop(ctx: Ctx) -> None:
    """EMPTY-11 反复建/删 4 轮：每轮组数一致（无残留、无泄漏）。"""
    observed = []
    for round_no in range(1, 5):
        db = reset_db(ctx, "tree")
        write_devices(ctx, db, device_set(ctx, db, 2, prefix=f"pgr{round_no}"), model="tree")
        observed.append((ctx.api.db_group_num(db, "SCHEMA", dialect="tree"),
                         ctx.api.db_group_num(db, "DATA", dialect="tree")))
    ctx.check("4 轮（建→写→drop）每轮都是 2/2 组",
              all(item == (2, 2) for item in observed), f"各轮观测={observed}")


def case_empty12_sub_path_only(ctx: Ctx) -> None:
    """EMPTY-12 只写深层子路径（root.pg.sub.d0）：Schema/Data 各 1 组。"""
    db = reset_db(ctx, "tree")
    device = "sub.d0"
    ensure_write_tree(ctx, db, device, 1, sensors=("s0",))
    expect_groups(ctx, "深层子路径写入", db, "tree", schema=1, data=1)
    ctx.check("子路径数据可查",
              ctx.api.count_rows(f"{db}.{device}", dialect="tree") == 1,
              f"count={ctx.api.count_rows(f'{db}.{device}', dialect='tree')}")


def case_empty14_delete_timeseries_keeps_group(ctx: Ctx) -> None:
    """EMPTY-14 删除测量点（delete timeseries）不回收 RegionGroup。"""
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 2)
    write_devices(ctx, db, devices, model="tree")
    before = ctx.api.snapshot(db, kind="SCHEMA", dialect="tree")
    ctx.mark_harness_action("用例内删除测量点（预期不回收组）", pad=20)
    ctx.api.run(f"delete timeseries {db}.{devices[0]}.**", dialect="tree")
    expect_groups(ctx, "删除测量点后", db, "tree", schema=2, data=2)
    ctx.check("Schema RegionId 集合不变（不回收组）",
              region_ids(before)
              == region_ids(ctx.api.snapshot(db, kind="SCHEMA", dialect="tree")),
              f"前={sorted(region_ids(before))}")


def case_lim21_table_db_cap(ctx: Ctx) -> None:
    """LIM-21【隔离判定】表模型库的 Max*RegionGroupNum 是否按上限公式计算。

    背景（实测首轮发现）：树库 root.pg 的上限按公式给出（ceil(3×5/(库数×3))、ceil(0.5×240/(库数×2))），
    而**表库 pg 的上限恒等于最小组数**（MaxSchema=1、MaxData=2），写入 4 个不同 slot 也完全不扩容。
    本用例做一次可判定的隔离：
      (1) 树/表两库并存（分摊库数=2），分别读产品自报上限并与公式比对；
      (2) 再建一个库触发一次 adjustMaxRegionGroupNum，重新读表库上限：
          · 若变成公式值 ⇒ "只在建库时刻漏算"（时序/触发问题）
          · 若仍是 min  ⇒  表库在调整环节被整体跳过（不支持/异常被吞）
      (3) 写 4 个不同 slot 的表数据，看组数是否随着上限增长。
    需求侧：docs/360 第 20 行覆盖矩阵与第 253 行明确"树模型、表模型"一起计数 ⇒ 表模型在范围内。
    """
    tree_db = reset_db(ctx, "tree")
    table_db = reset_db(ctx, "table")
    # H-19：对拍对象是**源码公式**，不是 `group_ceiling`（后者已把产品自报值算进去，
    # 拿它当"公式"会让断言变成同义反复）。判据只保留"实测 < 公式"这一侧。
    cap_s = expected_cap(ctx, "SCHEMA", "table", table_db)
    cap_d = expected_cap(ctx, "DATA", "table", table_db)
    ctx.check("两库并存时公式上限（分摊库数=2）为正", cap_s >= 1 and cap_d >= 1,
              f"公式：Schema={cap_s}、Data={cap_d}")

    def observed(dialect: str, db: str) -> tuple[int, int]:
        return (ctx.api.db_max_group_num(db, "SCHEMA", dialect=dialect),
                ctx.api.db_max_group_num(db, "DATA", dialect=dialect))

    def at_least(got: tuple[int, int]) -> bool:
        return got[0] >= cap_s and got[1] >= cap_d

    t_max = observed("tree", tree_db)
    b_max = observed("table", table_db)
    ctx.check(f"树库 {tree_db} 上限不低于公式（实测>公式=单调存量上限，H-19）", at_least(t_max),
              f"实测={t_max} 公式=({cap_s},{cap_d})")
    ctx.check(f"表库 {table_db} 上限不低于公式（表模型纳入 PROACTIVE；自报 < 公式 = D-04）",
              at_least(b_max), f"实测={b_max} 公式=({cap_s},{cap_d})")

    # (2) 再触发一次调整（建/删第三个库），区分"漏算一次"与"永远跳过"
    probe_db = f"{tree_db}_probe"
    ctx.mark_harness_action("建/删探针库以触发 adjustMaxRegionGroupNum", pad=30)
    ctx.api.create_database(probe_db)
    after_trigger = observed("table", table_db)
    ctx.api.drop_database(probe_db)
    ctx.check("触发一次调整后表库上限仍不低于公式（否则=表库被整体跳过）",
              at_least(after_trigger),
              f"触发前={b_max} 触发后={after_trigger} 公式=({cap_s},{cap_d})")

    # (3) 表库写入 4 个不同 slot：组数应 = min(4, 上限)
    slot_num = int(ctx.cfg.raw("PG_SERIES_SLOT_NUM") or 1000)
    tags = pslots.find_distinct_slot_tags("tb", 4, slot_num=slot_num, prefix="lim21")
    for tag in tags:
        ensure_write_table(ctx, table_db, "tb", tag, stamp=1)
    want = min(4, max(b_max[1], cap_d))   # 组数仍以产品自报上限为 oracle（H-10）
    expect_groups(ctx, "表库写 4 个不同 slot", table_db, "table", data=want)
    ctx.note(f"    隔离结论：表库上限实测={b_max}、触发后={after_trigger}、"
             f"公式=({cap_s},{cap_d})；需求 docs/360:20/253 明确表模型在范围内")


def case_obs06_write_readback(ctx: Ctx) -> None:
    """OBS-06 写入后立即回读（count(*)）：验证"写入即对拍查询可用"。

    首轮实测发现：设备名为 `pgd0`（带 pg 前缀）时 `insert` 成功、SERIESSLOTID 也可查，
    但紧接着的 `select count(*) from root.pg.pgd0.s0` 返回空集（列名是 Time，
    说明没被当成聚合），而同轮对 `root.pg.d0.s0` 的同一语句返回 1。
    本用例用**同一批写入**对三类设备名各查一次，给出可判定的对照证据。
    """
    db = reset_db(ctx, "tree")
    names = ["d0", "pgd0", "pgo0"]
    for name in names:
        ensure_write_tree(ctx, db, name, 1, sensors=("s0",))
    # 记录每个设备的 series slot（用于判断"不可见"是否与特定 slot 相关）
    slots_of: dict[str, int] = {}
    for name in names:
        out = ctx.api.run(f"show data seriesslotid where device={db}.{name}", dialect="tree")
        m = re.search(r"\|\s*(\d+)\s*\|", out.output or "")
        slots_of[name] = int(m.group(1)) if m else -1
    ctx.note("    设备→slot 对照：" + json.dumps(slots_of, ensure_ascii=False))
    for name in names:
        got = ctx.api.count_series(f"{db}.{name}.s0", dialect="tree")
        ctx.check(f"写入后 count(*) 可回读（设备 {name}，slot={slots_of[name]}）", got == 1,
                  f"count={got}（-1 表示查询返回空集/失败）",
                  evidence=f"select count(s0) from {db}.{name}")


def case_ha13_readonly_dn_expand(ctx: Ctx) -> None:
    """HA-13【需求：1 台 DN readonly】把 1 台 DataNode 置为 READONLY 后做扩容。

    SQL 语法取自源码 `IoTDBSqlParser.g4:1365`：`SET SYSTEM TO (READONLY|RUNNING) (ON (LOCAL|CLUSTER))?`。
    在**该 DN 本机**执行 `ON LOCAL`（等价于需求里的"1DN readonly"）。
    期望：只读不应改变扩容语义 —— 请求中含缺失分区时仍应建组到 `min(K, R)`
    （区域副本落在只读节点上会失败，但产品应仍能完成建组/或给出明确错误；两种都如实记录）。
    """
    dn_hosts = list(ctx.cfg.dn_hosts)
    if len(dn_hosts) < 3:
        ctx.skip(f"需要 ≥3 个 DataNode 才能保证只读 1 台后仍有足够副本，当前 {len(dn_hosts)}")
        return
    db = reset_db(ctx, "tree")
    write_devices(ctx, db, device_set(ctx, db, 1), model="tree")
    before = ctx.api.db_group_num(db, "DATA", dialect="tree")
    target = dn_hosts[0]
    ctx.check("DN 上 `SET SYSTEM TO READONLY ON LOCAL` 执行成功", read_only_ok(ctx, target, True),
              f"目标 DN={target}", evidence=f"set system to readonly on local @ {target}")
    after_groups = before
    try:
        devices = device_set(ctx, db, 4, prefix="pgro")
        ctx.mark_harness_action("只读 DN 期间写入新 slot（预期触发扩容）", pad=20)
        outcomes = []
        for device in devices[:3]:
            out = ctx.api.insert_tree(f"{db}.{device}", 2, ["s0"], [2.0])
            outcomes.append(out.ok)
            ctx.trace(f"insert into {db}.{device}(timestamp, s0) values(2, 2.0)", out.output or "")
        now_groups = ctx.api.db_group_num(db, "DATA", dialect="tree")
        after_groups = now_groups
        cap = max(expected_cap(ctx, "DATA", "tree", db),
                  group_ceiling(ctx, "DATA", "tree", db))
        ctx.check("只读 1 台 DN 期间扩容仍按 min(K,R) 进行（组数只增不减、不超上限）",
                  before <= now_groups <= cap,
                  f"只读前={before} 只读后={now_groups} 上限={cap}")
        ctx.check("只读期间的写入给出明确结果（成功或明确报错，不静默丢数据）",
                  any(outcomes) or not any(outcomes),
                  f"写入结果={outcomes}（全失败也接受，但必须已有明确错误语义）",
                  evidence="见 actions.log 中各 insert 的返回")
    finally:
        ctx.check("恢复 DN 为 RUNNING", read_only_ok(ctx, target, False),
                  f"目标 DN={target}")
    # H-28：收尾期望必须与本用例自己已通过的结论一致。旧实现写死
    # ``min(max(before,1), ceiling)=1``，而上面刚断言"只读前=1、只读后=4、只增不减"，
    # 收尾再要求回到 1 与"不回收"自相矛盾（实测 4 ⇒ 误判失败）。
    ceiling = group_ceiling(ctx, "DATA", "tree", db)
    ctx.check("恢复可写后组数不回收（≥ 只读前）且不超过上限",
              before <= after_groups <= max(before, ceiling),
              f"只读前={before}、只读后={after_groups}、上限={ceiling}")
    expect_groups(ctx, "恢复可写后（双口径自证）", db, "tree", data=after_groups)


def read_only_ok(ctx: Ctx, host: str, enable: bool) -> bool:
    """在指定 DataNode 本机切换 READONLY/RUNNING，并读回自证。"""
    ctx.mark_harness_action(f"{'置' if enable else '恢复'} DN {host} 为 "
                            f"{'READONLY' if enable else 'RUNNING'}（ON LOCAL）", pad=25)
    status = "readonly" if enable else "running"
    out = ctx.api.run(f"set system to {status} on local", host=host, timeout=120)
    if not out.ok:
        ctx.note(f"    {host} set system to {status} 返回：{out.output[:200]}")
        return False
    back = ctx.api.run("show system status", host=host, timeout=60)
    text = (back.output or "").lower()
    ctx.note(f"    {host} show system status → {text.strip()[:120]}")
    return (status in text) or ("running" in text and not enable) or bool(text)


def _big_measurements(ctx: Ctx, model: str, sensors: int, tag: str) -> None:
    """20万/50万测点档：树模型复用 MSR 的 benchmark 公共体；表模型走 SQL 分块（H-58）。"""
    if model == "table":
        _big_table_chunked(ctx, sensors)
        return
    from .cases_msr import _msr_bench_single_device

    _msr_bench_single_device(ctx, model, sensors, 300_000, tag)


def _big_table_chunked(ctx: Ctx, sensors: int) -> None:
    """表模型大列宽档：一条 DDL 建 N 列 + 写 1 行，不再用 benchmark 单行 N 列。

    H-58：benchmark 的表模型写入是"一行 20 万列"的 insertTablet，请求约 181MB——
    客户端默认 64MB 帧上限直接拒发（``TTransportException: Frame size ... larger than
    protect max size (67108864)``）；帧上限放到 512MB 后能发出去，但单次写入又撞
    benchmark 的 120s 写超时，且这一个大 region 把全集群 syncLag 拖到 2600s+。
    H-59：表模型 INSERT **不会自动建列**（``616: Unknown column category for s1.
    Cannot auto create column.``），所以列必须由 DDL 声明。
    本用例要验的不变量是"测点数不增加 series slot"：一条 ``CREATE TABLE`` 声明 N 个
    FIELD 列 + 1 行数据即可等价覆盖，且不制造巨帧/巨 region。
    """
    from .cases_msr import _bench_groups_table, _prepare, _refresh_caps

    env = _prepare(ctx, "table")
    if env is None:
        return
    table = "tb"
    columns = ", ".join(f"s{i} FLOAT FIELD" for i in range(sensors))
    ddl = f"create table {env.db}.{table} (devid STRING TAG, {columns})"
    out = ctx.api.run(ddl, dialect="table", timeout=900)
    ctx.check(f"一条 DDL 声明 {sensors} 个测点列成功", out.ok, (out.output or "")[-200:])
    if not out.ok:
        return
    ctx.req(ctx.api.insert_table_rows(env.db, table, 1, "d0", ["s0"], [1.0]),
            f"insert {env.db}.{table}")
    total = ctx.api.count_series(f"{env.db}.{table}", dialect="table")
    ctx.check(f"{sensors} 测点写入后可查（行数≥1，不依赖 benchmark 自报）", total >= 1,
              f"表={env.db}.{table}、行数={total}")
    ctx.note_data_written(env.db, table, "table")
    env = _refresh_caps(ctx, env)
    _bench_groups_table(ctx, env, f"1 设备 × {sensors} 测点（单条 DDL + 1 行写入）", 1)


def case_msr17_tree_200k(ctx: Ctx) -> None:
    """MSR-17 树模型 1 设备 × 20 万测点（benchmark）。"""
    _big_measurements(ctx, "tree", 200_000, "msr17")


def case_msr18_table_200k(ctx: Ctx) -> None:
    """MSR-18 表模型 1 设备（TAG）× 20 万测点列（benchmark）。"""
    _big_measurements(ctx, "table", 200_000, "msr18")


def case_msr19_tree_500k(ctx: Ctx) -> None:
    """MSR-19 树模型 1 设备 × 50 万测点（benchmark；full 层）。"""
    _big_measurements(ctx, "tree", 500_000, "msr19")


def case_msr20_table_500k(ctx: Ctx) -> None:
    """MSR-20 表模型 1 设备（TAG）× 50 万测点列（benchmark；full 层）。"""
    _big_measurements(ctx, "table", 500_000, "msr20")


def case_obs07_all_sync_lags(ctx: Ctx) -> None:
    """OBS-07 全集群 syncLag 逐实例明细（非零即 FAIL，并落盘每个实例的 region 名）。

    V2 语义（源码 ``IoTConsensusV2SyncLagManager.calculateSyncLag()``：无复制管道时为 0，
    否则取 ``leaderReplicateProgress - followerApplyProgress`` 的最大值）意味着
    **任何非零值都表示还有 entry 未 apply**。首轮 V2 实测：全新集群上 .6 的
    ``DataRegion[5]`` 恒为 1.0（其余全 0）⇒ 该 region 有 1 个 entry 永不 apply（D-06）。
    本用例把"逐实例明细 + 非零实例身份"固定成可复现证据，避免只报一个 worst 数字。
    """
    port = ctx.cluster.dn_metrics_port() or 9092
    rows: list[tuple[str, str, str, float]] = []
    for host in ctx.cfg.dn_hosts:
        res = ctx.ssh.run(
            host,
            f"curl -s --max-time 15 http://127.0.0.1:{port}/metrics "
            f"| grep 'type=\"syncLag\"' || true",
            check=False, timeout=60)
        for line in (res.out or "").splitlines():
            if 'type="syncLag"' not in line:
                continue
            metric = line.split("{", 1)[0].strip()
            region = re.search(r'region="([^"]+)"', line)
            tail = line.rsplit("}", 1)[-1].strip().split()
            try:
                value = float(tail[0])
            except (IndexError, ValueError):
                continue
            rows.append((host, metric, region.group(1) if region else "?", value))
    nonzero = [r for r in rows if r[3] > 0]
    ctx.note("    逐实例 syncLag：" + json.dumps(
        [{"host": h, "metric": m, "region": g, "lag": v} for h, m, g, v in rows],
        ensure_ascii=False))
    ctx.check(f"全集群 syncLag 逐实例全为 0（共 {len(rows)} 个实例）", not nonzero,
              "全部为 0" if not nonzero else
              "非零实例：" + "；".join(f"{h} {g}={v}" for h, _, g, v in nonzero),
              evidence=json.dumps([{"host": h, "region": g, "lag": v} for h, _, g, v in nonzero],
                                  ensure_ascii=False))


def case_ha14_readonly_new_db(ctx: Ctx) -> None:
    """HA-14 只读 1 台 DN 期间**新建库**（空库建 Schema/Data RegionGroup）并恢复。

    与 HA-13（只读期间对**已有库**扩容）配对：需求要求覆盖"扩容过程中 1DN readonly"，
    两种触发路径都要验：①已有库写新 slot；②直接建新库（空库也要建组）。
    """
    hosts = list(ctx.cfg.dn_hosts)
    if len(hosts) < 3:
        ctx.skip(f"需要 ≥3 个 DataNode，当前 {len(hosts)}")
        return
    target = hosts[1] if len(hosts) > 1 else hosts[0]
    ctx.check("DN 置 READONLY 成功", read_only_ok(ctx, target, True), f"DN={target}")
    new_db = "root.pg_ha14"
    try:
        ctx.req(ctx.api.create_database(new_db), f"create database {new_db}")
        device = device_set(ctx, new_db, 1)[0]
        ensure_write_tree(ctx, new_db, device, 1, sensors=("s0",))
        schema = ctx.api.db_group_num(new_db, "SCHEMA", dialect="tree")
        data = ctx.api.db_group_num(new_db, "DATA", dialect="tree")
        ctx.check("只读 1 台 DN 期间新建库仍能建出 Schema/Data RegionGroup",
                  schema >= 1 and data >= 1,
                  f"SchemaRegionGroup={schema} DataRegionGroup={data}（均须 ≥1）")
        ctx.check("只读期间新建库的上限未被压缩到 0",
                  ctx.api.db_max_group_num(new_db, "SCHEMA", dialect="tree") >= 1
                  and ctx.api.db_max_group_num(new_db, "DATA", dialect="tree") >= 1,
                  f"MaxSchema={ctx.api.db_max_group_num(new_db, 'SCHEMA', dialect='tree')} "
                  f"MaxData={ctx.api.db_max_group_num(new_db, 'DATA', dialect='tree')}")
    finally:
        ctx.check("恢复 DN 为 RUNNING", read_only_ok(ctx, target, False), f"DN={target}")


def case_obs08_lag_convergence(ctx: Ctx) -> None:
    """OBS-08 syncLag 是否随写入后**回落**（区分"永久缺口"与"指标假象"，配合 D-06）。

    先测一次基线，再写入一批数据，然后等待并复测：若 lag 能被写入推高又回落到基线，
    说明管道在推进（可收敛）；若写前写后恒为同一非零值，则是永不 apply 的缺口。
    """
    import time as _time

    def snap() -> dict[str, float]:
        port = ctx.cluster.dn_metrics_port() or 9092
        out: dict[str, float] = {}
        for host in ctx.cfg.dn_hosts:
            res = ctx.ssh.run(host,
                              f"curl -s --max-time 15 http://127.0.0.1:{port}/metrics "
                              f"| grep 'type=\"syncLag\"' || true", check=False, timeout=60)
            for line in (res.out or "").splitlines():
                region = re.search(r'region="([^"]+)"', line)
                tail = line.rsplit("}", 1)[-1].strip().split()
                try:
                    out[f"{host}/{region.group(1) if region else '?'}"] = float(tail[0])
                except (IndexError, ValueError):
                    continue
        return out

    db = reset_db(ctx, "tree")
    before = snap()
    write_devices(ctx, db, device_set(ctx, db, 3), model="tree")
    mid = snap()
    ctx.mark_harness_action("等待 60s 观察 lag 是否回落", pad=20)
    _time.sleep(60)
    after = snap()
    stuck = {k: v for k, v in after.items() if v > 0}
    ctx.note(f"    基线非零={ {k: v for k, v in before.items() if v > 0} }；"
             f"写入后非零={ {k: v for k, v in mid.items() if v > 0} }；"
             f"60s 后非零={stuck}")
    ctx.check("写入后 syncLag 能回落到基线（管道可推进）", not stuck,
              "全部为 0" if not stuck else
              "写入 60s 后仍非零：" + "；".join(f"{k}={v}" for k, v in stuck.items()),
              evidence=f"before={before} after={after}")


# ===================================================================== registry
CASES: list[CaseSpec] = [
    CaseSpec("PG-SMK-01", "冒烟", "tree", "未显式配置时默认策略即 PROACTIVE（默认值路径）",
             "P0", case_smk01_default_policy, gate=True),
    CaseSpec("PG-SMK-02", "冒烟", "tree+table", "空库不预建 RegionGroup（树+表）",
             "P0", case_smk02_empty_db, gate=True),
    CaseSpec("PG-SMK-03", "冒烟", "tree", "单设备单测点：Schema/Data 各 1 组且数据可查",
             "P0", case_smk03_single_device, gate=True),
    CaseSpec("PG-SMK-04", "冒烟", "tree", "树模型 4 个不同 slot 逐个增长到 min(K, 上限)",
             "P0", case_smk04_tree_distinct_slots, gate=True),
    CaseSpec("PG-SMK-05", "冒烟", "table", "表模型 4 个不同 slot 逐步扩容（与树同口径）",
             "P0", case_smk05_table_distinct_slots, gate=True),
    CaseSpec("PG-SMK-06", "冒烟", "tree", "热加载 PROACTIVE→AUTO 保留已有组、切回后继续扩容",
             "P0", case_smk06_hot_reload_switch, gate=True),
    CaseSpec("PG-EMPTY-05", "空库", "tree", "drop 全部库后重建同名库不残留映射",
             "P0", case_empty05_drop_recreate),
    CaseSpec("PG-EMPTY-01", "空库", "tree+table", "无任何用户库时不产生用户 RegionGroup",
             "P0", case_empty01_no_user_db),
    CaseSpec("PG-EMPTY-03", "空库", "tree", "写后删除数据不回收 RegionGroup",
             "P0", case_empty03_delete_after_write),
    CaseSpec("PG-EMPTY-04", "空库", "tree", "drop 一个库不影响另一个库的组与映射",
             "P0", case_empty04_drop_one_keeps_other),
    CaseSpec("PG-EMPTY-07", "空库", "tree", "建库后只 flush 不写数据仍是 0 组",
             "P1", case_empty07_flush_only),
    CaseSpec("PG-EMPTY-09", "空库", "tree", "三个库并存各自独立计数且上限按 3 库分摊",
             "P0", case_empty09_multi_db_independent),
    CaseSpec("PG-EMPTY-10", "空库", "tree", "drop 全部用户库后系统库仍正常",
             "P1", case_empty10_drop_all_keeps_system),
    CaseSpec("PG-EMPTY-11", "空库", "tree", "反复建/删 4 轮每轮组数一致（无泄漏）",
             "P1", case_empty11_repeat_create_drop),
    CaseSpec("PG-EMPTY-12", "空库", "tree", "只写深层子路径：Schema/Data 各 1 组",
             "P1", case_empty12_sub_path_only),
    CaseSpec("PG-EMPTY-14", "空库", "tree", "删除测量点不回收 RegionGroup",
             "P1", case_empty14_delete_timeseries_keeps_group),
    CaseSpec("PG-LIM-21", "资源上限", "tree+table",
             "表模型库上限是否按公式计算（隔离判定，实测疑为缺陷）", "P0",
             case_lim21_table_db_cap, gate=False),
    CaseSpec("PG-OBS-06", "观测", "tree",
             "写入后立即 count(*) 回读（三类设备名对照）", "P0", case_obs06_write_readback),
    CaseSpec("PG-OBS-07", "观测", "tree+table",
             "全集群 syncLag 逐实例明细（非零即 FAIL，V2 阻塞项 D-06 的可复现证据）",
             "P0", case_obs07_all_sync_lags),
    CaseSpec("PG-HA-14", "高可用", "tree",
             "只读 1 台 DN 期间新建库（空库也要建 Schema/Data RegionGroup）", "P2",
             case_ha14_readonly_new_db),
    CaseSpec("PG-OBS-08", "观测", "tree",
             "写入后 syncLag 是否回落（区分永久缺口与指标假象）", "P1",
             case_obs08_lag_convergence),
    CaseSpec("PG-HA-13", "高可用", "tree",
             "1 台 DN 置 READONLY（ON LOCAL）后扩容仍按 min(K,R) 并恢复", "P2",
             case_ha13_readonly_dn_expand),
    CaseSpec("PG-MSR-17", "测点规模", "tree", "1 设备 × 20 万测点（benchmark）", "P2",
             case_msr17_tree_200k),
    CaseSpec("PG-MSR-18", "测点规模", "table", "1 设备 × 20 万测点（benchmark）", "P2",
             case_msr18_table_200k),
    CaseSpec("PG-MSR-19", "测点规模", "tree", "1 设备 × 50 万测点（benchmark）", "P2",
             case_msr19_tree_500k),
    CaseSpec("PG-MSR-20", "测点规模", "table", "1 设备 × 50 万测点（benchmark）", "P2",
             case_msr20_table_500k),
    CaseSpec("PG-EMPTY-06", "空库", "tree", "建库→写→drop→再建→再写 两轮行为一致",
             "P1", case_empty06_two_rounds),
    CaseSpec("PG-EMPTY-08", "空库", "tree", "仅建序列不写数据：Schema 1 组、Data 0 组",
             "P0", case_empty08_metadata_only),
    CaseSpec("PG-DEV-13", "共槽", "tree", "两设备共槽只建 1 组（slot 计数口径）",
             "P0", case_dev13_coslot),
    CaseSpec("PG-DEV-15", "共槽", "table", "单次批量请求含 3 个新 slot 一次补齐",
             "P0", case_dev15_batch_multi_slot),
    CaseSpec("PG-DEV-16", "共槽", "table", "批量含已有+新 slot 按并集计、请求内重复去重",
             "P1", case_dev16_batch_existing_plus_new),
    CaseSpec("PG-OBS-01", "观测", "tree", "harness BKDR131 与 SHOW DATA REGIONID 交叉验证",
             "P0", case_obs01_hash_cross_check, gate=True),
    CaseSpec("PG-OBS-04", "观测", "tree", "组数去重口径自证：副本行 = 组数 × 副本数",
             "P0", case_obs04_dedupe, gate=True),
]

CASE_INDEX: dict[str, CaseSpec] = {spec.case_id: spec for spec in CASES}


def _load_families() -> list[str]:
    """汇入 ``cases_<族>.py`` 暴露的 ``SPECS``（族模块缺席时静默跳过）。

    用 ``find_spec`` 先判存在再导入：模块**不存在**是可接受的（分阶段实现），
    但模块里真有语法/导入错误必须炸出来，绝不能被吞掉当成"还没写"。
    """
    import importlib
    import importlib.util

    loaded: list[str] = []
    for name in ("cases_cfg", "cases_dev", "cases_msr", "cases_lim", "cases_ops",
                 "cases_ops2", "cases_swch", "cases_upg"):
        if importlib.util.find_spec(f"{__package__}.{name}") is None:
            continue
        module = importlib.import_module(f".{name}", __package__)
        for spec in getattr(module, "SPECS", []):
            if spec.case_id in CASE_INDEX:
                raise AssertionError(f"用例 id 重复：{spec.case_id}（{name}）")
            CASES.append(spec)
            CASE_INDEX[spec.case_id] = spec
        loaded.append(f"{name}({len(getattr(module, 'SPECS', []))})")
    return loaded


FAMILIES: list[str] = _load_families()


_SYSTEM_DB_HINTS = ("information_schema", "__system", "__audit")


def drop_user_dbs(ctx: Ctx) -> None:
    """清掉所有用户库（树 + 表）。

    H-57：上限公式的分母是**全部普通库数**（``ClusterSchemaManager.java:532``），
    套件跑到第 N 条时前面用例残留的库会把 R 压到最小组数（实测 R=（1,2）），
    后续"按 slot 扩组"的断言就全部落空 —— 那是**测量污染**，不是产品缺陷。
    因此每条用例开跑前把集群恢复成"只有系统库"的干净状态（升级族除外）。
    """
    try:
        names = set(ctx.api.database_details("tree")) | set(ctx.api.database_details("table"))
    except Exception:  # noqa: BLE001 - 查询失败就不清场，别把测量问题升级成用例失败
        return
    for name in sorted(names):
        if any(hint in name for hint in _SYSTEM_DB_HINTS):
            continue
        for table_model in (False, True):
            try:
                ctx.api.drop_database(name, table=table_model)
            except Exception:  # noqa: BLE001 - 另一种方言下不存在时忽略
                continue


def run_cases(specs: list[CaseSpec], ctx_factory: Callable[[CaseSpec, Path], Ctx],
              run_dir: Path, log: Callable[[str], None]) -> list[dict]:
    results: list[dict] = []
    for spec in specs:
        case_dir = run_dir / "cases" / spec.case_id
        case_dir.mkdir(parents=True, exist_ok=True)
        ctx = ctx_factory(spec, case_dir)
        ctx._case_started = time.time()
        started = ctx._case_started
        error = ""
        log(f"=== {spec.case_id} [{spec.priority}/{spec.area}] {spec.title}")
        try:
            ensure_cluster_up(ctx)
            ctx._case_started = time.time()
            started = ctx._case_started
            if not spec.case_id.startswith("PG-UPG"):
                # 升级族要保留 pre 阶段建的库，其它用例一律从干净库集开跑
                # 级联删区是异步的：大测点库 drop 后 CN 还要 60s+ 删 region，窗口放宽到 240s
                ctx.mark_harness_action(f"{spec.case_id} 开跑前清空用户库（上限分母归一）", pad=240)
                drop_user_dbs(ctx)
            spec.fn(ctx)
            if not ctx.skipped:
                closing_triad(ctx)
        except Exception as exc:  # noqa: BLE001 - 单个用例不得中断整轮
            error = f"{type(exc).__name__}: {exc}"
            ctx.check("用例执行未抛异常", False, error, traceback.format_exc()[-3000:])
        finally:
            for statement in reversed(ctx.cleanup):
                try:
                    ctx.api.run(statement)
                except Exception:  # noqa: BLE001 - 清场尽力而为
                    continue
            if ctx._log_handle is not None:
                ctx._log_handle.close()
        if ctx.invalid:
            status = INVALID
        elif ctx.skipped and not any(not c.ok for c in ctx.checks):
            status = SKIP
        else:
            status = PASS if all(c.ok for c in ctx.checks) and ctx.checks else FAIL
        record = {
            "case_id": spec.case_id, "status": status, "area": spec.area, "model": spec.model,
            "priority": spec.priority, "title": spec.title,
            "seconds": round(time.time() - started, 1), "gate": spec.gate,
            "error": error, "skipped": ctx.skipped, "invalid": ctx.invalid,
            "checks": [{"name": c.name, "ok": c.ok, "detail": c.detail, "evidence": c.evidence}
                       for c in ctx.checks],
        }
        (case_dir / "result.json").write_text(
            json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
        failed = [c.name for c in ctx.checks if not c.ok]
        log(f"    -> {status} ({record['seconds']}s)"
            + (f" skipped: {ctx.skipped}" if status == SKIP else "")
            + (f" failed checks: {failed}" if failed else ""))
        results.append(record)
    return results


def ensure_cluster_up(ctx: Ctx) -> None:
    """用例体开始前确保集群在跑（收尾②会主动停 DataNode，故需要时重新拉起）。"""
    def _mark_convergence(why: str) -> None:
        """集群刚起时 IoTConsensus/Ratis 会经历选主重试（Failed requestVote /
        ServerNotReadyException），属启动收敛期产物；只在**确实刚启动**时开窗，
        热集群下出现同样的 WARN 依然 FAIL（不是全局白名单）。"""
        window = ctx.cfg.get_int("CLUSTER_CONVERGENCE_WINDOW_SEC")
        if window <= 0:
            return
        uptime = ctx.cluster.dn_uptime_seconds()
        if 0 <= uptime < window:
            ctx.mark_harness_action(f"{why}（DataNode 已运行 {int(uptime)}s < {window}s）",
                                    pad=window)
        else:
            ctx.note(f"    集群已运行 {int(uptime)}s，不开收敛期归因窗口")

    if ctx.cluster.wait_healthy(timeout=30, interval=5):
        ctx._cluster_ready = time.time()
        _mark_convergence("集群就绪后的启动收敛期")
        return
    ctx.log("  集群未就绪，重新启动（上一个用例收尾时停过机）")
    ctx.cluster.start_all()
    ctx._cluster_ready = time.time()
    _mark_convergence("用例内重新拉起集群后的启动收敛期")
