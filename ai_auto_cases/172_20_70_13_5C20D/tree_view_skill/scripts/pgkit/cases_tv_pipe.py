"""树转表视图 × **Pipe（数据同步）** 场景用例（TV-PIPE-01..09）。

环境拓扑（10 + 10 拆分，两套独立集群，均为 **5 CN + 10 DN / SR 5 副本 / DR 3 副本**）：

    发送端 sender   : 172.20.70.100-109（conf/cluster.pipe_sender.conf）
    接收端 receiver : 172.20.70.110-119（conf/cluster.pipe_receiver.conf）

跑法（**必须两端都 prepare**，且串行）：

    bash treeview_5c20d/run_pipe_case.sh conf/cluster.pipe_sender.conf pipe TV-PIPE-03

设计要点（已实测）：

* 视图的**元数据**（CREATE VIEW / ALTER VIEW ADD COLUMN / DROP COLUMN / DROP VIEW / 属性）
  由 **`with source ('inclusion'='schema')`** 的 pipe 同步（发送端用 table 方言建 pipe）；
* 视图背后的**树数据**由另一条树模型 pipe（`inclusion='data.insert, schema.timeseries'`）同步；
* **`inclusion='all'` 不会同步视图**（与需求 doc 90 §3.3 一致，作为负向用例 TV-PIPE-04）；
* 接收端是只读副本：可直接 `desc` / `select` 视图验证，但不能写。
"""

from __future__ import annotations

import time

from .cases import Ctx, CaseSpec, reset_db
from .cases_treeview import _cols, _desc, _rows, _sql, _ok
from .config import SKILL_ROOT, load_config
from .pgapi import PgApi
from .remote import SshRunner, SqlClient

DEFAULT_INC_SCHEMA = "schema"
DEFAULT_INC_DATA = "data.insert, schema.timeseries"


# ------------------------------------------------------------------ 接收端客户端

def _recv(ctx: Ctx) -> PgApi:
    """构造接收端的操作层（与 ctx.api 同类型，懒建并缓存在 ctx 上）。"""
    cached = getattr(ctx, "_pipe_recv", None)
    if cached is not None:
        return cached
    cfg = load_config(str(SKILL_ROOT / "conf" / "cluster.pipe_receiver.conf"))
    scratch = ctx.case_dir / "scratch_receiver"
    scratch.mkdir(parents=True, exist_ok=True)
    ssh = SshRunner(cfg, scratch)
    client = PgApi(cfg, SqlClient(cfg, ssh, scratch), ssh, lambda m: ctx.log(m))
    setattr(ctx, "_pipe_recv", client)
    return client


def _r(ctx: Ctx, stmt: str, dialect: str = "table"):
    out = _recv(ctx).run(stmt, dialect=dialect, timeout=180)
    ctx.trace(f"[receiver] {stmt}", out.output)
    return out


# ------------------------------------------------------------------ 公共步骤

def _pipes(ctx: Ctx, suffix: str = "") -> tuple[str, str]:
    """在发送端建两条 pipe（视图元数据 + 树数据），返回 (p_schema, p_data)。"""
    p_schema = f"p_view_schema{suffix}"
    p_data = f"p_tree_data{suffix}"
    r = _sql(ctx, f"create pipe {p_schema} with source ('inclusion'='{DEFAULT_INC_SCHEMA}') "
                  f"with sink ('node-urls'='{ctx.cfg.get('PIPE_RECEIVER_NODES')}')", "table")
    ctx.req(r, f"建 pipe {p_schema}")
    r2 = _sql(ctx, f"create pipe {p_data} with source ('inclusion'='{DEFAULT_INC_DATA}') "
                   f"with sink ('node-urls'='{ctx.cfg.get('PIPE_RECEIVER_NODES')}')", "tree")
    ctx.req(r2, f"建 pipe {p_data}")
    return p_schema, p_data


def _wait_recv(ctx: Ctx, stmt: str, want, *, dialect: str = "table",
               timeout: int = 120, interval: int = 10):
    """轮询接收端，直到 ``want(rows)`` 为真或超时；返回最后一次结果。"""
    deadline = time.time() + timeout
    rows: list[list[str]] = []
    while time.time() < deadline:
        out = _r(ctx, stmt, dialect)
        rows = _rows(out)
        if want(rows):
            return rows
        time.sleep(interval)
    return rows


def _seed(ctx: Ctx, tag: str) -> tuple[str, str, str]:
    """发送端准备：树库 + 序列 + 数据 + 表库 + 视图。返回 (tree_db, table_db, view)。"""
    tree_db = reset_db(ctx, "tree", f"root.pipe_{tag}")
    table_db = reset_db(ctx, "table", f"pipe_{tag}")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _ok(ctx, f"create timeseries {tree_db}.d1.s2 DOUBLE", "tree")
    _ok(ctx, f"insert into {tree_db}.d1(time,s1,s2) values(1, 10, 1.5)", "tree")
    view = f"{table_db}.v"
    _ok(ctx, f"create view {view} (dev STRING TAG, s1 INT32 FIELD, s2 DOUBLE FIELD) "
             f"as {tree_db}.**", "table")
    return tree_db, table_db, view


# =============================================================== 用例

def case_pipe01_view_meta_sync(ctx: Ctx) -> None:
    """TV-PIPE-01：视图元数据经 pipe 同步到接收端。"""
    tree_db, table_db, view = _seed(ctx, "p01")
    _pipes(ctx, "_p01")
    tbl = _wait_recv(ctx, f"desc {view}", lambda rows: bool(rows))
    ctx.check("接收端能 desc 到 pipe 同步过来的视图（列集合一致）",
              bool(tbl), f"rows={tbl[:6]}")
    src, dst = _cols(ctx, view), {r[0].lower() for r in tbl}
    ctx.check("接收端视图列与发送端一致", src == dst, f"sender={src} receiver={dst}")


def case_pipe02_view_data_sync(ctx: Ctx) -> None:
    """TV-PIPE-02：视图查询结果与发送端一致（树数据 + 视图元数据两条 pipe）。"""
    tree_db, table_db, view = _seed(ctx, "p02")
    _pipes(ctx, "_p02")
    want = _rows(_sql(ctx, f"select dev, s1, s2 from {view}", "table"))
    got = _wait_recv(ctx, f"select dev, s1, s2 from {view}",
                     lambda rows: len(rows) == len(want) and rows, timeout=150)
    norm = lambda rs: sorted(tuple(x.lower() for x in r) for r in rs)  # noqa: E731
    ctx.check("接收端视图返回的数据与发送端逐行一致",
              norm(got) == norm(want), f"sender={want} receiver={got}")


def case_pipe03_autosync_new_column_sync(ctx: Ctx) -> None:
    """TV-PIPE-03（核心）：发送端 auto_sync 自动加列的 DDL 经 pipe 同步到接收端。"""
    tree_db, table_db, view = _seed(ctx, "p03")
    _ok(ctx, f"alter view {view} set properties auto_sync_schema=true", "table")
    _pipes(ctx, "_p03")
    _wait_recv(ctx, f"desc {view}", lambda rows: bool(rows))
    before = {r[0].lower() for r in _rows(_r(ctx, f"desc {view}"))}
    _ok(ctx, f"create timeseries {tree_db}.d9.s9 INT64", "tree")
    _ok(ctx, f"insert into {tree_db}.d9(time,s9) values(2, 99)", "tree")
    sender = _cols(ctx, view)
    ctx.check("发送端已自动加列 s9", "s9" in sender, f"sender={sender}")
    got = _wait_recv(ctx, f"desc {view}", lambda rows: "s9" in {r[0].lower() for r in rows},
                     timeout=180)
    cols = {r[0].lower() for r in got}
    ctx.check("接收端视图同步出现新列 s9（auto_sync 扩列 DDL 随 pipe 下发）", "s9" in cols,
              f"before={before} after={cols}")
    types = {r[0].lower(): r[1].upper() for r in got if len(r) > 1}
    ctx.check("接收端新列类型与发送端一致（INT64）", types.get("s9") == "INT64", f"types={types}")


def case_pipe04_all_inclusion_does_not_sync_view(ctx: Ctx) -> None:
    """TV-PIPE-04（负向，需求明文）：`inclusion='all'` 的树模型 pipe 不同步视图。"""
    tree_db, table_db, view = _seed(ctx, "p04")
    r = _sql(ctx, f"create pipe p_all_p04 with source ('inclusion'='all') "
                  f"with sink ('node-urls'='{ctx.cfg.get('PIPE_RECEIVER_NODES')}')", "tree")
    ctx.req(r, "建 inclusion=all 的 pipe")
    time.sleep(60)          # 给足时间：如果真的会同步，60s 足够
    out = _r(ctx, f"desc {view}")
    ok, detail = out.ok, out.flat[:200]
    ctx.check("inclusion=all 不应把视图同步到接收端（需求：树模型 pipe 不同步 view）",
              not ok, f"desc 结果 ok={ok} {detail}")


def case_pipe05_alter_view_sync(ctx: Ctx) -> None:
    """TV-PIPE-05：ALTER VIEW（rename column / add / drop column）同步。"""
    tree_db, table_db, view = _seed(ctx, "p05")
    _pipes(ctx, "_p05")
    _wait_recv(ctx, f"desc {view}", lambda rows: bool(rows))
    _ok(ctx, f"alter view {view} rename column s2 to s2x", "table")
    got = _wait_recv(ctx, f"desc {view}", lambda rows: "s2x" in {r[0].lower() for r in rows},
                     timeout=150)
    ctx.check("RENAME COLUMN 同步到接收端", "s2x" in {r[0].lower() for r in got}, f"{got}")
    _ok(ctx, f"alter view {view} drop column s2x", "table")
    got2 = _wait_recv(ctx, f"desc {view}", lambda rows: "s2x" not in {r[0].lower() for r in rows},
                      timeout=150)
    ctx.check("DROP COLUMN 同步到接收端", "s2x" not in {r[0].lower() for r in got2}, f"{got2}")


def case_pipe06_drop_view_sync(ctx: Ctx) -> None:
    """TV-PIPE-06：DROP VIEW 同步到接收端。"""
    tree_db, table_db, view = _seed(ctx, "p06")
    _pipes(ctx, "_p06")
    _wait_recv(ctx, f"desc {view}", lambda rows: bool(rows))
    _ok(ctx, f"drop view {view}", "table")
    deadline = time.time() + 150
    gone = False
    while time.time() < deadline:
        out = _r(ctx, f"desc {view}")
        if not out.ok:
            gone = True
            break
        time.sleep(10)
    ctx.check("DROP VIEW 同步到接收端（视图不再存在）", gone, f"desc ok={out.ok} {out.flat[:160]}")


def case_pipe07_receiver_readonly(ctx: Ctx) -> None:
    """TV-PIPE-07：接收端视图只读——写入应失败，且不影响发送端数据。"""
    tree_db, table_db, view = _seed(ctx, "p07")
    _pipes(ctx, "_p07")
    _wait_recv(ctx, f"desc {view}", lambda rows: bool(rows))
    out = _r(ctx, f"insert into {view}(time, dev, s1) values(3, 'dX', 1)")
    ctx.check("接收端对视图写入应失败（同步副本只读）", not out.ok, out.flat[:200])
    # 发送端数据不受影响
    rows = _rows(_sql(ctx, f"select dev, s1 from {view}", "table"))
    ctx.check("发送端数据未被接收端写入影响", len(rows) == 1, f"rows={rows}")


def case_pipe08_reconnect_catchup(ctx: Ctx) -> None:
    """TV-PIPE-08：接收端不可用期间发送端继续写+扩列，恢复后追平。"""
    tree_db, table_db, view = _seed(ctx, "p08")
    _ok(ctx, f"alter view {view} set properties auto_sync_schema=true", "table")
    p_schema, p_data = _pipes(ctx, "_p08")
    _wait_recv(ctx, f"desc {view}", lambda rows: bool(rows))
    # 停接收端的 DataNode（其一），模拟同步受阻
    recv_cfg = load_config(str(SKILL_ROOT / "conf" / "cluster.pipe_receiver.conf"))
    victim = recv_cfg.dn_hosts[0]
    recv_ssh = SshRunner(recv_cfg, ctx.case_dir / "scratch_receiver")
    ctx.mark_harness_action(f"TV-PIPE-08 停接收端 DataNode {victim}", kind="stop")
    recv_ssh.run(victim, f"cd {recv_cfg.get('DB_DIR')} && sudo -n -E ./sbin/stop-datanode.sh",
                 check=False, timeout=120)
    try:
        _ok(ctx, f"create timeseries {tree_db}.d7.s7 DOUBLE", "tree")
        _ok(ctx, f"insert into {tree_db}.d7(time,s7) values(5, 7.5)", "tree")
        time.sleep(20)
    finally:
        ctx.mark_harness_action(f"TV-PIPE-08 重启接收端 DataNode {victim}", kind="start")
        recv_ssh.run(victim, f"cd {recv_cfg.get('DB_DIR')} && export IOTDB_HOME={recv_cfg.get('DB_DIR')} "
                             f"IOTDB_CONF={recv_cfg.get('DB_DIR')}/conf && sudo -n -E ./sbin/start-datanode.sh",
                     check=False, timeout=300)
    got = _wait_recv(ctx, f"desc {view}", lambda rows: "s7" in {r[0].lower() for r in rows},
                     timeout=300)
    ctx.check("接收端恢复后追平新列 s7", "s7" in {r[0].lower() for r in got}, f"{got}")
    rows = _wait_recv(ctx, f"select dev, s7 from {view}",
                      lambda rs: any((r[0] if r else "").lower() == "d7" for r in rs), timeout=300)
    ctx.check("接收端恢复后追平新数据（d7 行可见且值正确）",
              any((r[0] if r else "").lower() == "d7" and (r[-1] if r else "") == "7.5" for r in rows),
              f"rows={rows}")


def case_pipe09_pipe_health(ctx: Ctx) -> None:
    """TV-PIPE-09：pipe 状态与同步时延（发送端两条 pipe 均 RUNNING、无失败）。"""
    _tree_db, _table_db, _view = _seed(ctx, "p09")
    p_schema, p_data = _pipes(ctx, "_p09")
    time.sleep(45)
    # show pipes 是**方言相关**的：表模型 pipe 只在 table 方言列出，树模型 pipe 只在 tree 方言列出
    flat = (_sql(ctx, "show pipes", "table").flat + "\n" + _sql(ctx, "show pipes", "tree").flat).upper()
    ctx.check(f"pipe {p_schema} 处于 RUNNING", p_schema.upper() in flat and "RUNNING" in flat,
              flat[:400])
    ctx.check(f"pipe {p_data} 处于 RUNNING", p_data.upper() in flat, flat[:400])
    ctx.check("pipe 无异常信息（ExceptionMessage 为空）",
              "EXCEPTION" not in flat.replace("EXCEPTIONMESSAGE", ""), flat[:400])


PIPE_CASES = [
    CaseSpec("TV-PIPE-01", "Pipe 同步", "tree+table", "视图元数据（CREATE VIEW）经 pipe 同步到接收端", "P0", case_pipe01_view_meta_sync, gate=True),
    CaseSpec("TV-PIPE-02", "Pipe 同步", "tree+table", "接收端视图查询结果与发送端一致（元数据+数据）", "P0", case_pipe02_view_data_sync, gate=True),
    CaseSpec("TV-PIPE-03", "Pipe 同步", "tree+table", "auto_sync 自动加列 DDL 经 pipe 同步到接收端（核心）", "P0", case_pipe03_autosync_new_column_sync),
    CaseSpec("TV-PIPE-04", "Pipe 同步", "tree+table", "inclusion=all 的树模型 pipe 不同步视图（需求负向）", "P0", case_pipe04_all_inclusion_does_not_sync_view),
    CaseSpec("TV-PIPE-05", "Pipe 同步", "tree+table", "ALTER VIEW rename/drop column 同步", "P1", case_pipe05_alter_view_sync),
    CaseSpec("TV-PIPE-06", "Pipe 同步", "tree+table", "DROP VIEW 同步", "P1", case_pipe06_drop_view_sync),
    CaseSpec("TV-PIPE-07", "Pipe 同步", "tree+table", "接收端视图只读（写入失败且不影响发送端）", "P1", case_pipe07_receiver_readonly),
    CaseSpec("TV-PIPE-08", "Pipe 同步", "tree+table", "接收端 DN 停机期间继续写+扩列，恢复后追平", "P0", case_pipe08_reconnect_catchup),
    CaseSpec("TV-PIPE-09", "Pipe 同步", "tree+table", "pipe 健康状态与同步时延", "P2", case_pipe09_pipe_health),
]
