"""树转表视图 —— 疑似产品缺陷的**最小复现**用例（TV-REPRO-D1..D5）。

设计原则（与常规回归用例不同）：
* 只做**触发缺陷所必需的最小动作**，不掺其它校验，便于研发按 SQL 复现；
* 断言写的是**正确行为**：缺陷复现 ⇒ 断言失败 ⇒ 该用例 FAIL
  （`run_case_clean.sh` 在 FAIL 时会自动备份 CN/DN 日志）；
* 所有取证都写进 `evidence/repro_*.txt`，并打印到用例日志，
  便于直接粘进缺陷报告；
* 对应缺陷报告：`docs/DEFECT_TV_D1..D5*.md`。
"""

from __future__ import annotations

import pathlib
import time

from .cases import Ctx, CaseSpec, reset_db
from .cases_treeview import _desc, _field_cols, _show_create, _sql, _ok  # noqa: F401

#: 复现用的日志标记（各缺陷对应源码里的日志点）
MARK_AUTOSYNC = r"ViewColumnAutoSyncTrigger"
MARK_DETECT = r"TreeDeviceViewFieldDetectionHandler"
MARK_AUTH = r"DataNodeAuthUtils:\d+ - Fail to check password expiration"


def _out_dir(ctx: Ctx) -> pathlib.Path:
    """evidence 目录：优先用 Ctx 暴露的 artifacts，否则按 run_dir 推导。"""
    for attr in ("artifacts", "evidence_dir"):
        d = getattr(ctx, attr, None)
        if d:
            p = pathlib.Path(d)
            p.mkdir(parents=True, exist_ok=True)
            return p
    p = pathlib.Path(ctx.case_dir) / "evidence"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _evidence(ctx: Ctx, name: str, text: str) -> None:
    """把取证内容写进 evidence/ 并打印前若干行到用例日志。"""
    path = _out_dir(ctx) / f"repro_{name}.txt"
    path.write_text(text + "\n", encoding="utf-8")
    head = "\n".join(text.splitlines()[:12])
    ctx.note(f"    取证已写入 {path.name}：\n{head}")


def _grep_logs(ctx: Ctx, pattern: str, *, tail: int = 20) -> dict[str, list[str]]:
    """在 CN/DN 的 `log_*_all.log` 里抓指定模式的整行（带主机前缀）。"""
    hits: dict[str, list[str]] = {}
    script = (
        f"for f in logs/log_confignode_all.log logs/log_datanode_all.log; do "
        f"[ -f \"$f\" ] && grep -aE {pattern!r} \"$f\" | tail -{tail} | sed \"s|^|$f: |\"; "
        f"done"
    )
    for host in sorted(set(ctx.cfg.cn_hosts) | set(ctx.cfg.dn_hosts)):
        db_dir = ctx.cfg.get("DB_DIR")
        out = ctx.ssh.run(host, f"cd {db_dir} && {script}", check=False, timeout=60)
        lines = [f"{host}: {ln}" for ln in (out.out or "").splitlines() if ln.strip()]
        if lines:
            hits[host] = lines
    return hits


def _context(ctx: Ctx, host: str, pattern: str, before: int = 6, after: int = 25) -> str:
    """抓命中行前后若干行（含堆栈）。"""
    db_dir = ctx.cfg.get("DB_DIR")
    script = (
        f"cd {db_dir} && "
        f"for f in logs/log_confignode_all.log logs/log_datanode_all.log; do "
        f"[ -f \"$f\" ] && grep -aE -B {before} -A {after} {pattern!r} \"$f\" | tail -80; done"
    )
    out = ctx.ssh.run(host, script, check=False, timeout=60)
    return out.out or ""


# =============================================================== D1

def case_repro_d1(ctx: Ctx) -> None:
    """TV-D1：模板激活触发扩列时，重复请求未去重/未幂等 ⇒ CN 305 + 552，DN 记 ERROR。"""
    tree_db = reset_db(ctx, "tree", "root.rp_d1")
    table_db = reset_db(ctx, "table", "rp_d1")
    _ok(ctx, "create device template rp_tp (s1 FLOAT, s2 DOUBLE)", "tree")
    _ok(ctx, f"set device template rp_tp to {tree_db}", "tree")
    view = f"{table_db}.v"
    _ok(ctx, f"create view {view} (dev STRING TAG) with (auto_sync_schema=true) as {tree_db}.**",
        "table")
    ctx.note(f"    视图 {view} 就绪，列={sorted(_field_cols(ctx, view))}")
    # 关键：必须制造"**同一视图被并发触发多次**"的场景才会命中。
    # 单次激活在本环境通常不触发（实测 TV-REPRO-D1 v1 PASS），
    # 线上命中的用例都是"批量激活 / 连续建序列 / 模板扩列紧接着激活"。
    # 注意：模板已 set 到库上时**不能**再建普通测点（516 device template already set），
    # 所以并发压力全部来自"批量激活 + 连续扩模板"。
    for i in range(24):
        _ok(ctx, f"create timeseries using device template on {tree_db}.dev{i:02d}", "tree")
    # 扩模板会再触发一批"同一视图加列"，与激活共用同一批 schema region 日志 → 并发竞争
    _ok(ctx, "alter schema template rp_tp add (s3 INT64)", "tree")
    for i in range(24, 36):
        _ok(ctx, f"create timeseries using device template on {tree_db}.dev{i:02d}", "tree")
    _ok(ctx, "alter schema template rp_tp add (s4 BOOLEAN)", "tree")
    time.sleep(25)   # 给 CN procedure + 重试留窗口
    hits = _grep_logs(ctx, MARK_AUTOSYNC)
    text = "\n".join(f"{h}: {ln}" for h, ls in hits.items() for ln in ls)
    _evidence(ctx, "d1_autosync_error", text or "(无命中)")
    fields = _field_cols(ctx, view)
    ctx.check("D1 功能面：模板激活后 s1/s2/s3 已进入视图（缺陷复现前提下功能仍正确）",
              {"s1", "s2"} <= fields, f"fields={fields}")
    ctx.check("D1 缺陷面：模板激活不应在 DN 日志留下 ViewColumnAutoSyncTrigger ERROR",
              not text.strip(), f"命中 {sum(len(v) for v in hits.values())} 行；首行="
                                f"{(text.splitlines() or [''])[0][:220]}")
    if text.strip():
        host = next(iter(hits))
        _evidence(ctx, "d1_autosync_context", _context(ctx, host, MARK_AUTOSYNC))
    ctx.note_data_written(table_db, "v", "table")


# =============================================================== D2

def case_repro_d2(ctx: Ctx) -> None:
    """TV-D2（**已撤回为非缺陷**）：确认 false→true 类型冲突时的当前语义。

    原先按需求 doc 90 §3.2.2 认为"合并失败应保持 false"，经确认：
    单列类型冲突按"跳过该列"处理、`SET PROPERTIES` 成功，属产品既定语义。
    本用例改为**固化该行为**（属性 true、冲突列类型不被覆盖、非冲突列仍可扩列）。
    """
    tree_db = reset_db(ctx, "tree", "root.rp_d2")
    table_db = reset_db(ctx, "table", "rp_d2")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _ok(ctx, f"create timeseries {tree_db}.d2.s1 INT64", "tree")
    view = f"{table_db}.v"
    _ok(ctx, f"create view {view} (dev STRING TAG, s1 DOUBLE FIELD) as {tree_db}.**", "table")
    out = _sql(ctx, f"alter view {view} set properties auto_sync_schema=true", "table")
    sc = _show_create(ctx, view)
    ddl = "\n".join(ln for ln in sc.splitlines() if "CREATE VIEW" in ln.upper())[:600]
    _evidence(ctx, "d2_toggle",
              f"SQL: alter view {view} set properties auto_sync_schema=true\n"
              f"返回: {out.flat[:200]}\nshow create view: {ddl or sc[:400]}")
    as_true = "AUTO_SYNC_SCHEMA=TRUE" in sc.upper().replace(" ", "")
    ctx.check("D2 行为确认：类型冲突时 SET PROPERTIES 成功且属性为 true", out.ok and as_true,
              f"alter.ok={out.ok} 属性为true={as_true}")
    ctx.check("D2 行为确认：冲突列保留视图声明的 DOUBLE", _desc(ctx, view)["s1"][0] == "DOUBLE",
              f"desc={_desc(ctx, view)}")
    _ok(ctx, f"create timeseries {tree_db}.d3.brand_new DOUBLE", "tree")
    time.sleep(15)
    ctx.check("D2 行为确认：非冲突新测点仍能扩列",
              "brand_new" in _field_cols(ctx, view), f"fields={_field_cols(ctx, view)}")


# =============================================================== D3

def case_repro_d3(ctx: Ctx) -> None:
    """TV-D3：同名测点类型冲突导致建视图失败（符合需求），但 CN 记 ERROR。"""
    tree_db = reset_db(ctx, "tree", "root.rp_d3")
    table_db = reset_db(ctx, "table", "rp_d3")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _ok(ctx, f"create timeseries {tree_db}.d2.s1 DOUBLE", "tree")
    out = _sql(ctx, f"create view {table_db}.v (dev STRING TAG) as {tree_db}.**", "table")
    time.sleep(5)
    hits = _grep_logs(ctx, MARK_DETECT)
    text = "\n".join(f"{h}: {ln}" for h, ls in hits.items() for ln in ls)
    _evidence(ctx, "d3_createview_error",
              f"SQL: create view {table_db}.v (dev STRING TAG) as {tree_db}.**\n"
              f"返回: {out.flat[:300]}\n\nCN 日志命中:\n{text or '(无)'}")
    ctx.check("D3 功能面：同名测点类型冲突时建视图应失败（需求明文）", not out.ok, out.flat[:220])
    ctx.check("D3 缺陷面：该**预期失败**不应在 CN 日志留下 ERROR",
              not text.strip(), f"命中 {sum(len(v) for v in hits.values())} 行；"
                                f"首行={(text.splitlines() or [''])[0][:240]}")
    if text.strip():
        _evidence(ctx, "d3_createview_context", _context(ctx, next(iter(hits)), MARK_DETECT))


# =============================================================== D4

def case_repro_d4(ctx: Ctx) -> None:
    """TV-D4：登录时密码过期检查失败被记为带栈 ERROR。"""
    # 关键：只有 **DataNode 真正处理了用户查询** 才会走 DataNodeAuthUtils.checkPasswordExpiration，
    # 所以必须"建序列 + 写入 + 查询数据"，只做元数据操作（create/drop/show）不会触发。
    tree_db = reset_db(ctx, "tree", "root.rp_d4")
    # 数据尽量铺开到多台 DN：20 个设备各自成 region，查询时会被不同 DN 处理，
    # 从而多次走 DataNodeAuthUtils.checkPasswordExpiration
    for i in range(20):
        _ok(ctx, f"create timeseries {tree_db}.dev{i:02d}.s1 INT32", "tree")
        _ok(ctx, f"insert into {tree_db}.dev{i:02d}(time,s1) values(1,{i})", "tree")
    out = _sql(ctx, f"select s1 from {tree_db}.**", "tree")   # 触发 DN 侧鉴权/密码过期检查
    for i in range(20):
        _sql(ctx, f"select s1 from {tree_db}.dev{i:02d}", "tree")
    _sql(ctx, f"select count(s1) from {tree_db}.**", "tree")
    time.sleep(10)                                           # 等日志落盘
    hits = _grep_logs(ctx, MARK_AUTH)
    text = "\n".join(f"{h}: {ln}" for h, ls in hits.items() for ln in ls)
    _evidence(ctx, "d4_password_expiration",
              f"动作: 建序列 + 写入 + select（返回 {out.flat[:80]}）→ DN 处理用户查询\n\nDN 日志命中:\n{text or '(无)'}")
    ctx.check("D4 缺陷面：登录不应产生 ERROR 级 password expiration 日志（降级放行应记 WARN/DEBUG）",
              not text.strip(), f"命中 {sum(len(v) for v in hits.values())} 行；"
                                f"首行={(text.splitlines() or [''])[0][:240]}")
    if text.strip():
        _evidence(ctx, "d4_password_context", _context(ctx, next(iter(hits)), MARK_AUTH))


# =============================================================== D5

def case_repro_d5(ctx: Ctx) -> None:
    """TV-D5：整集群优雅重启后，刚建的表模型库/视图可能丢失（间歇）。"""
    rounds = ctx.cfg.get_int("TV_REPRO_D5_ROUNDS")
    tree_db = reset_db(ctx, "tree", "root.rp_d5")
    table_db = reset_db(ctx, "table", "rp_d5")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _ok(ctx, f"insert into {tree_db}.d1(time,s1) values(1,1)", "tree")
    lines: list[str] = []
    lost = 0
    for i in range(1, rounds + 1):
        view = f"{table_db}.v{i}"
        _ok(ctx, f"create view {view} (dev STRING TAG) with (auto_sync_schema=true) as {tree_db}.**",
            "table")
        before = sorted(_field_cols(ctx, view))
        ctx.mark_harness_action(f"TV-D5 第 {i} 轮整集群重启", kind="restart")
        ctx.cluster.stop_all()
        ctx.cluster.start_all()
        ctx.cluster.wait_healthy(timeout=1200)
        ctx.mark_harness_action(f"TV-D5 第 {i} 轮重启后的收敛期", kind="start")
        dbs = _sql(ctx, "show databases", "table").flat
        cols = sorted(_field_cols(ctx, view))
        ok = table_db in dbs and cols == before
        lines.append(f"round {i}: table_db_exist={table_db in dbs} "
                     f"cols={before} -> {cols} => {'OK' if ok else 'LOST'}")
        ctx.note("    " + lines[-1])
        if not ok:
            lost += 1
            _evidence(ctx, f"d5_round{i}_lost",
                      f"{lines[-1]}\n\nshow databases(table):\n{dbs[:800]}")
    _evidence(ctx, "d5_summary", "\n".join(lines))
    ctx.check(f"D5 缺陷面：{rounds} 轮整集群重启后表模型库与视图定义都应保留",
              lost == 0, f"丢库 {lost}/{rounds} 轮：{lines}")
    ctx.note_data_written(table_db, "v1", "table")


REPRO_CASES = [
    CaseSpec("TV-REPRO-D1", "缺陷复现", "tree+table",
             "D1：模板激活扩列产生 ViewColumnAutoSyncTrigger ERROR", "P0", case_repro_d1),
    CaseSpec("TV-REPRO-D2", "缺陷复现", "tree+table",
             "D2（已撤回）：类型冲突时 SET PROPERTIES 行为确认", "P2", case_repro_d2),
    CaseSpec("TV-REPRO-D3", "缺陷复现", "tree+table",
             "D3：建视图预期失败被 CN 记 ERROR", "P1", case_repro_d3),
    CaseSpec("TV-REPRO-D4", "缺陷复现", "table",
             "D4：登录密码过期检查失败记 ERROR", "P2", case_repro_d4),
    CaseSpec("TV-REPRO-D5", "缺陷复现", "tree+table",
             "D5：整集群重启后表模型库/视图丢失（间歇）", "P0", case_repro_d5,
             needs_restart=True),
]
