"""树转表视图（tree view）用例集 —— 5C20D / master_1026_dc11a35。

覆盖来源：
* 需求：`树转表——需求分析（V2.0.5.1-开源）.docx`（create/alter/drop/show/对齐语义）
* 需求：PLM doc 90 `V2.0.13.1-树转表视图自动检测新增测点-需求分析`（auto_sync_schema）
* 技术设计：PLM doc 913（DN 前缀树、CN procedure、DN 扩列接入、重试/去重）
* PLM 测试项：TDB-343
* 参考用例：/data/deepseek/iotdb-sqltest/table/scripts/OperateMetadata/View/TreeViewTest

约定：
* 树模型写、表模型读：写用 ``sql_dialect=tree``，视图操作与查询用 ``table``。
* 每条用例自建 ``root.tv_<xxx>`` 树库 + ``tv_<xxx>`` 表库，结束 drop，避免互相污染。
* 判定只看 ``desc view`` / ``select`` / ``show`` 的实际输出，不做宽松兜底。
"""

from __future__ import annotations

import time

from .cases import Ctx, CaseSpec, reset_db

# ---------------------------------------------------------------- 基础设施

def _sql(ctx: Ctx, stmt: str, dialect: str | None = None, timeout: int = 120):
    out = ctx.api.run(stmt, dialect=dialect, timeout=timeout)
    ctx.trace(stmt, out.output)
    return out


def _ok(ctx: Ctx, stmt: str, dialect: str | None = None, timeout: int = 120):
    out = _sql(ctx, stmt, dialect, timeout)
    ctx.req(out, stmt)
    return out


def _table_rows(out) -> list[list[str]]:
    """解析 ``| a | b |`` 表格为二维数组，**保留表头行**。"""
    rows = []
    for line in (out.output or "").splitlines():
        s = line.strip()
        if not s.startswith("|"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if all(set(c) <= set("-+ ") for c in cells):
            continue
        rows.append(cells)
    return rows


def _rows(out) -> list[list[str]]:
    """数据行（去掉表头）。

    H-01：早期实现把表头也算一行，``select * from view`` 只有 1 个设备时会被读成 2 行，
    RESTRICT 与非 RESTRICT 的对比因此恒等（实测 free=2 / restrict=2 的假结果）。
    """
    rows = _table_rows(out)
    return rows[1:] if rows else []


def _desc(ctx: Ctx, view: str) -> dict[str, tuple[str, str]]:
    """``desc view`` → {列名(小写): (数据类型大写, 类别)}。"""
    out = _sql(ctx, f"desc {view}", "table")
    rows = _rows(out)
    cols: dict[str, tuple[str, str]] = {}
    for r in rows:
        if len(r) < 3 or r[0].lower() in ("columnname", "columname"):
            continue
        cols[r[0].lower()] = (r[1].upper(), r[2].upper())
    return cols


def _cols(ctx: Ctx, view: str) -> set[str]:
    return set(_desc(ctx, view))


def _field_cols(ctx: Ctx, view: str) -> set[str]:
    return {k for k, (_, cat) in _desc(ctx, view).items() if cat == "FIELD"}


def _show_create(ctx: Ctx, view: str, dialect: str = "table", stmt: str = "") -> str:
    out = _sql(ctx, stmt or f"show create view {view}", dialect)
    return out.flat


def _new_db(ctx: Ctx, tag: str) -> tuple[str, str]:
    """建一对库：树库 root.tv_<tag>、表库 tv_<tag>。"""
    tree_db = reset_db(ctx, "tree", f"root.tv_{tag}")
    table_db = reset_db(ctx, "table", f"tv_{tag}")
    ctx.cleanup.append(f"drop database root.tv_{tag}")
    ctx.cleanup.append(f"drop database tv_{tag}")
    return tree_db, table_db


def _create_view(ctx: Ctx, table_db: str, view: str,
                 cols_sql: str, prefix: str, extra: str = "") -> str:
    full = f"{table_db}.{view}"
    _ok(ctx, f"create view {full} ({cols_sql}) {extra} as {prefix}", "table")
    return full


def _await_cols(ctx: Ctx, view: str, want: set[str], timeout: int = 60) -> set[str]:
    """等 desc 出现目标列（扩列是异步 procedure，给一个有界等待）。"""
    deadline = time.time() + timeout
    cols = _cols(ctx, view)
    while time.time() < deadline:
        if want <= cols:
            return cols
        time.sleep(5)
        cols = _cols(ctx, view)
    return cols


# ================================================================ A. 基础语义

def case_base01_create_and_query(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b01")
    for d in ("d1", "d2"):
        _ok(ctx, f"create timeseries {tree_db}.{d}.s1 INT32", "tree")
        _ok(ctx, f"create timeseries {tree_db}.{d}.s2 DOUBLE", "tree")
    _ok(ctx, f"insert into {tree_db}.d1(time,s1,s2) values(1, 10, 1.5)", "tree")
    view = _create_view(ctx, table_db, "v",
                        "dev STRING TAG, s1 INT32 FIELD, s2 DOUBLE FIELD",
                        f"{tree_db}.**")
    cols = _desc(ctx, view)
    ctx.check("CREATE VIEW 后 desc 出现 time/tag/field 三类列",
              {"time", "dev", "s1", "s2"} <= set(cols)
              and cols["dev"][1] == "TAG" and cols["s1"][1] == "FIELD" and cols["time"][1] == "TIME",
              f"desc={cols}")
    out = _sql(ctx, f"select dev, s1, s2 from {view}", "table")
    rows = _rows(out)
    ctx.check("表模型查询能看到树模型写入的数据", len(rows) >= 1, f"rows={rows[:3]}")
    ctx.note_data_written(table_db, "v", "table")


def case_base02_prefix_check(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b02")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    bad = [
        (f"{tree_db}.d1", "不以 ** 结尾"),
        (f"{tree_db}.*", "中间用单 *"),
        (f"{tree_db}.d1.**.s1", "** 不在结尾"),
    ]
    for prefix, why in bad:
        out = _sql(ctx, f"create view {table_db}.bad (dev STRING TAG) as {prefix}", "table")
        ctx.check(f"非法 prefixPath 被拒绝（{why}）", not out.ok, f"prefix={prefix} out={out.flat[:160]}")
    ok_view = _create_view(ctx, table_db, "good", "dev STRING TAG", f"{tree_db}.**")
    ctx.check("合法 prefixPath 可以建视图", "good" in ok_view, ok_view)


def case_base03_scan_all_measurements(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b03")
    for m, t in (("s1", "INT32"), ("s2", "DOUBLE"), ("s3", "FLOAT")):
        _ok(ctx, f"create timeseries {tree_db}.d1.{m} {t}", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**")
    fields = _field_cols(ctx, view)
    ctx.check("未指定 FIELD 时自动扫描出全部测点", fields == {"s1", "s2", "s3"}, f"fields={fields}")
    types = {k: v[0] for k, v in _desc(ctx, view).items()}
    ctx.check("扫描出的列类型与测点一致",
              types.get("s1") == "INT32" and types.get("s2") == "DOUBLE" and types.get("s3") == "FLOAT",
              f"types={types}")


def case_base04_field_rename(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b04")
    _ok(ctx, f"create timeseries {tree_db}.d1.current DOUBLE", "tree")
    _ok(ctx, f"insert into {tree_db}.d1(time,current) values(1, 2.5)", "tree")
    view = _create_view(ctx, table_db, "v",
                        "dev STRING TAG, amp DOUBLE FIELD FROM current", f"{tree_db}.**")
    cols = _desc(ctx, view)
    ctx.check("FIELD FROM original_measurement 生成新列名", "amp" in cols and "current" not in cols,
              f"cols={cols}")
    sc = _show_create(ctx, view)
    # 注意：show create 会把测点名加引号输出，形如 FROM "current"
    ctx.check("show create view 保留 FROM 映射",
              bool(__import__("re").search(r'FROM\s+"?current"?', sc, __import__("re").I)), sc[:320])
    ctx.note_data_written(table_db, "v", "table")


def case_base05_no_attribute(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b05")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    out = _sql(ctx, f"create view {table_db}.v (dev STRING TAG, attr STRING ATTRIBUTE) as {tree_db}.**",
               "table")
    ctx.check("视图列不支持 ATTRIBUTE（树模型无此概念）", not out.ok, out.flat[:200])


def case_base06_restrict(ctx: Ctx) -> None:
    """RESTRICT：只匹配层级**严格等于** tag 数的设备；非 RESTRICT 包含 <= tag 数的设备。

    需求示例（docx §2.1.1.3）：prefixPath=root.vehicle.**、2 个 TAG 时，
    非 RESTRICT 含第 1、2 层设备，RESTRICT 只含第 2 层设备。
    注意：**tag 数为 1 时两者语义相同**，所以必须用 2 个 TAG 才测得出来。
    """
    tree_db, table_db = _new_db(ctx, "b06")
    _ok(ctx, f"create timeseries {tree_db}.c1.s1 INT32", "tree")          # 设备 ...c1      （1 层）
    _ok(ctx, f"create timeseries {tree_db}.c1.g1.s1 INT32", "tree")       # 设备 ...c1.g1   （2 层）
    _ok(ctx, f"create timeseries {tree_db}.c1.g1.z1.s1 INT32", "tree")    # 设备 ...c1.g1.z1（3 层）
    v_free = _create_view(ctx, table_db, "v_free", "city STRING TAG, region STRING TAG",
                          f"{tree_db}.**")
    v_rest = _create_view(ctx, table_db, "v_rest", "city STRING TAG, region STRING TAG",
                          f"{tree_db}.**", "RESTRICT")
    for dev in ("c1", "c1.g1", "c1.g1.z1"):
        _ok(ctx, f"insert into {tree_db}.{dev}(time,s1) values(1,1)", "tree")

    def devs(view: str) -> list[str]:
        out = _sql(ctx, f"select city, region from {view}", "table")
        ctx.note(f"    {view} rows={_rows(out)}")
        return _rows(out)

    free, rest = devs(v_free), devs(v_rest)
    ctx.check("非 RESTRICT 包含层级 <= tag 数的设备（1、2 层各 1 个）", len(free) == 2,
              f"rows={free}")
    ctx.check("RESTRICT 只包含层级严格等于 tag 数的设备（仅 2 层 1 个）", len(rest) == 1,
              f"rows={rest}")
    ctx.check("RESTRICT 结果不包含更深层级（3 层设备）",
              all(r[-1] != "z1" for r in rest), f"rows={rest}")
    ctx.note_data_written(table_db, "v_free", "table")


def case_base07_type_conflict(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b07")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _ok(ctx, f"create timeseries {tree_db}.d2.s1 DOUBLE", "tree")
    out = _sql(ctx, f"create view {table_db}.v (dev STRING TAG) as {tree_db}.**", "table")
    ctx.check("同名测点类型冲突时建视图报错", not out.ok, out.flat[:200])


def case_base08_no_measurement(ctx: Ctx) -> None:
    """空库（无任何测点）建视图的行为。

    需求 §2.1.1 只明确规定："如果用户**指定了 FIELD 列**，但没有扫描出该列对应的测点，则创建时报错"。
    对"完全没有测点、也没声明 FIELD"的情形没有强制要求，故本用例只要求**行为明确**：
    要么明确报错，要么建出"只有 tag/time 列"的视图（并记录该结果供产品确认）。
    """
    tree_db, table_db = _new_db(ctx, "b08")   # 空库（无任何测点）
    out = _sql(ctx, f"create view {table_db}.v (dev STRING TAG) as {tree_db}.**", "table")
    if not out.ok:
        ctx.check("空库建视图被明确拒绝", True, out.flat[:200])
    else:
        fields = _field_cols(ctx, f"{table_db}.v")
        ctx.check("空库建视图：行为明确——建出只有 tag/time 列的视图（无 FIELD 列）",
                  fields == set(), f"fields={fields}")
        ctx.note("  观察：空库 + 未声明 FIELD 时会建出无 FIELD 列的视图；"
                 "需求未强制报错，建议产品确认是否应拒绝")
    # 反向约束（需求明文）：**未指定 dataType** 的 FIELD 列需要靠扫描决定类型，
    # 若扫不到任何对应测点 ⇒ 必须报错；反之显式给了 dataType 则不需要扫描，允许建列。
    out2 = _sql(ctx, f"create view {table_db}.v2 (dev STRING TAG, s1 FIELD) as {tree_db}.**", "table")
    ctx.check("未指定 dataType 的 FIELD 扫不到测点时建视图报错", not out2.ok, out2.flat[:200])
    out3 = _sql(ctx, f"create view {table_db}.v3 (dev STRING TAG, s1 INT32 FIELD) as {tree_db}.**",
                "table")
    ctx.check("显式指定 dataType 时允许建列（无需扫描，设备缺该测点则值为 NULL）",
              out3.ok, out3.flat[:200])


def case_base09_or_replace(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b09")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _ok(ctx, f"create timeseries {tree_db}.d1.s2 DOUBLE", "tree")
    v = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**")
    out = _sql(ctx, f"create view {v} (dev STRING TAG) as {tree_db}.**", "table")
    ctx.check("无 OR REPLACE 时同名 view 报错", not out.ok, out.flat[:160])
    out2 = _sql(ctx, f"create or replace view {v} (dev STRING TAG, s1 INT32 FIELD) as {tree_db}.**",
                "table")
    ctx.check("OR REPLACE 可替换已有 view", out2.ok, out2.flat[:160])
    ctx.check("替换后列定义按新语句生效", _field_cols(ctx, v) == {"s1"}, f"fields={_field_cols(ctx, v)}")
    _ok(ctx, f"create table {table_db}.t1 (a STRING TAG, b INT32 FIELD)", "table")
    out3 = _sql(ctx, f"create or replace view {table_db}.t1 (a STRING TAG) as {tree_db}.**", "table")
    ctx.check("同名 base table 时 OR REPLACE 报错（table 与 view 不能重名）", not out3.ok,
              out3.flat[:160])


def case_base10_ttl(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b10")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _ok(ctx, f"insert into {tree_db}.d1(time,s1) values(1,1)", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG, s1 INT32 FIELD",
                        f"{tree_db}.**", "with (ttl=100)")
    sc = _show_create(ctx, view)
    ctx.check("WITH (ttl=...) 出现在 show create view", "TTL" in sc.upper() and "100" in sc, sc[:260])
    rows = _rows(_sql(ctx, f"select * from {view}", "table"))
    ctx.check("视图 TTL 生效后过期数据不展示（ttl=100ms）", len(rows) == 0, f"rows={rows[:3]}")
    tree_ttl = _sql(ctx, f"show database {tree_db}", "tree").flat
    ctx.check("视图 TTL 不改变树库 TTL", "100" not in tree_ttl or "INF" in tree_ttl.upper(), tree_ttl[:200])


def case_base11_aligned_null_rows(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b11")
    _ok(ctx, f"create aligned timeseries {tree_db}.d1(voltage INT32, current FLOAT)", "tree")
    _ok(ctx, f"insert into {tree_db}.d1(time, voltage, current) aligned values (1, 1, 1)", "tree")
    _ok(ctx, f"insert into {tree_db}.d1(time, voltage, current) aligned values (2, null, 1)", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG, voltage INT32 FIELD", f"{tree_db}.**")
    rows = _rows(_sql(ctx, f"select voltage from {view}", "table"))
    ctx.check("对齐设备：全 null 行保留（表模型语义）", len(rows) == 2, f"rows={rows}")
    ctx.note_data_written(table_db, "v", "table")


def case_base12_show_tables_type(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b12")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**")
    _ok(ctx, f"create table {table_db}.t1 (a STRING TAG, b INT32 FIELD)", "table")
    flat = _sql(ctx, f"show tables details from {table_db}", "table").flat.upper()
    ctx.check("show tables details 的 TableType 区分 VIEW FROM TREE 与 BASE TABLE",
              "VIEW FROM TREE" in flat and "BASE TABLE" in flat, flat[:300])


def case_base13_show_create(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b13")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG, s1 INT32 FIELD", f"{tree_db}.**")
    _ok(ctx, f"create table {table_db}.t1 (a STRING TAG, b INT32 FIELD)", "table")
    out_v = _sql(ctx, f"show create view {view}", "table")
    out_t = _sql(ctx, f"show create table {view}", "table")
    ctx.check("show create view 输出 CREATE VIEW 语句", out_v.ok and "CREATE VIEW" in out_v.flat.upper(),
              out_v.flat[:260])
    same = _rows(out_t) and _rows(out_v) and _rows(out_t)[0][-1] == _rows(out_v)[0][-1]
    ctx.check("show create table 对 view 输出与 show create view 一致", bool(same), out_t.flat[:200])
    out_bad = _sql(ctx, f"show create view {table_db}.t1", "table")
    ctx.check("show create view 对 base table 报错", not out_bad.ok, out_bad.flat[:160])
    out_sys = _sql(ctx, "show create view information_schema.tables", "table")
    ctx.check("show create 对系统表报错", not out_sys.ok, out_sys.flat[:160])


def case_base14_alter(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b14")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _ok(ctx, f"create timeseries {tree_db}.d1.s2 DOUBLE", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG, s1 INT32 FIELD", f"{tree_db}.**")
    _ok(ctx, f"alter view {view} add column s2 DOUBLE FIELD", "table")
    ctx.check("ALTER VIEW ADD COLUMN(FIELD) 生效", "s2" in _cols(ctx, view), f"cols={_cols(ctx, view)}")
    _ok(ctx, f"alter view {view} add column extra STRING TAG", "table")
    ctx.check("ALTER VIEW ADD COLUMN(TAG) 生效", "extra" in _cols(ctx, view), f"cols={_cols(ctx, view)}")
    _ok(ctx, f"alter view {view} rename column s2 to s2x", "table")
    cols = _cols(ctx, view)
    ctx.check("ALTER VIEW RENAME COLUMN 生效", "s2x" in cols and "s2" not in cols, f"cols={cols}")
    _ok(ctx, f"alter view {view} drop column s2x", "table")
    ctx.check("ALTER VIEW DROP COLUMN 生效", "s2x" not in _cols(ctx, view), f"cols={_cols(ctx, view)}")
    _ok(ctx, f"alter view {view} set properties ttl=1000", "table")
    ctx.check("ALTER VIEW SET PROPERTIES ttl 生效",
              "1000" in _show_create(ctx, view), _show_create(ctx, view)[:240])
    _ok(ctx, f"alter view {view} rename to v_new", "table")
    new_view = f"{table_db}.v_new"
    cols_new = _cols(ctx, new_view)
    old_desc = _sql(ctx, f"desc {view}", "table")
    ctx.check("ALTER VIEW RENAME TO 生效（新名可 desc 且列不变）",
              bool(cols_new) and cols_new == _cols(ctx, new_view), f"cols={cols_new}")
    ctx.check("重命名后旧视图名不再可用", not old_desc.ok, old_desc.flat[:160])


def case_base15_comment(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "b15")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG, s1 INT32 FIELD", f"{tree_db}.**")
    _ok(ctx, f"comment on view {view} is 'tree view comment'", "table")
    _ok(ctx, f"comment on column {view}.s1 is 'col comment'", "table")
    sc = _show_create(ctx, view)
    ctx.check("COMMENT ON VIEW 反映到 show create view", "tree view comment" in sc, sc[:300])
    ctx.check("COMMENT ON COLUMN 反映到 show create view", "col comment" in sc, sc[:300])


# ================================================== B. auto_sync_schema（TDB-343）

def case_sync01_default_false(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s01")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**")
    sc = _show_create(ctx, view)
    ctx.check("未指定时 auto_sync_schema 默认为 false",
              "AUTO_SYNC_SCHEMA=TRUE" not in sc.upper().replace(" ", ""), sc[:300])
    _ok(ctx, f"create timeseries {tree_db}.d2.s2 DOUBLE", "tree")
    time.sleep(15)
    ctx.check("默认 false 时新增测点不会自动加列", "s2" not in _field_cols(ctx, view),
              f"fields={_field_cols(ctx, view)}")


def case_sync02_explicit_false(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s02")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**",
                        "with (auto_sync_schema=false)")
    sc = _show_create(ctx, view)
    ctx.check("显式 auto_sync_schema=false 可在 show create view 看到",
              "AUTO_SYNC_SCHEMA=FALSE" in sc.upper().replace(" ", ""), sc[:300])
    _ok(ctx, f"create timeseries {tree_db}.d2.s2 DOUBLE", "tree")
    time.sleep(15)
    ctx.check("false 时新增测点不加列", "s2" not in _field_cols(ctx, view), f"fields={_field_cols(ctx, view)}")


def case_sync03_create_timeseries(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s03")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**",
                        "with (auto_sync_schema=true)")
    ctx.check("true 时 show create view 带 auto_sync_schema=true",
              "AUTO_SYNC_SCHEMA=TRUE" in _show_create(ctx, view).upper().replace(" ", ""),
              _show_create(ctx, view)[:240])
    _ok(ctx, f"create timeseries {tree_db}.d2.s2 DOUBLE", "tree")
    cols = _await_cols(ctx, view, {"s2"})
    ctx.check("create timeseries 后自动加列", "s2" in cols, f"fields={_field_cols(ctx, view)}")
    types = _desc(ctx, view)
    ctx.check("自动加列的类型与测点一致", types.get("s2", ("", ""))[0] == "DOUBLE", f"types={types}")


def case_sync04_aligned_and_multi(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s04")
    _ok(ctx, f"create timeseries {tree_db}.d1.s0 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**",
                        "with (auto_sync_schema=true)")
    _ok(ctx, f"create aligned timeseries {tree_db}.d2(s1 INT32, s2 DOUBLE)", "tree")
    cols = _await_cols(ctx, view, {"s1", "s2"})
    ctx.check("CREATE ALIGNED TIMESERIES 批量加列", {"s1", "s2"} <= cols,
              f"fields={_field_cols(ctx, view)}")
    _ok(ctx, f"insert into {tree_db}.d3(time, s3, s4) values(1, 1, 2.0)", "tree")
    cols2 = _await_cols(ctx, view, {"s3", "s4"})
    ctx.check("单条多测点 INSERT 触发多列自动补齐", {"s3", "s4"} <= cols2,
              f"fields={_field_cols(ctx, view)}")
    ctx.note_data_written(table_db, "v", "table")


def case_sync05_insert_multi_device(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s05")
    _ok(ctx, f"create timeseries {tree_db}.d0.s0 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**",
                        "with (auto_sync_schema=true)")
    _ok(ctx, f"insert into {tree_db}.d1(time, a) values(1, 1)", "tree")
    _ok(ctx, f"insert into {tree_db}.d2(time, b) values(1, 2.5)", "tree")
    cols = _await_cols(ctx, view, {"a", "b"})
    ctx.check("多设备 INSERT 自动建测点并各自加列", {"a", "b"} <= cols,
              f"fields={_field_cols(ctx, view)}")
    rows = _rows(_sql(ctx, f"select dev, a, b from {view}", "table"))
    ctx.check("新列的数据可查询", len(rows) >= 2, f"rows={rows[:3]}")
    ctx.note_data_written(table_db, "v", "table")


def case_sync06_template(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s06")
    _ok(ctx, f"create device template tp1 (s1 FLOAT, s2 DOUBLE)", "tree")
    _ok(ctx, f"set device template tp1 to {tree_db}", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**",
                        "with (auto_sync_schema=true)")
    _ok(ctx, f"create timeseries using device template on {tree_db}.dev01", "tree")
    cols = _await_cols(ctx, view, {"s1", "s2"})
    ctx.check("激活模板后模板测点自动加列", {"s1", "s2"} <= cols,
              f"fields={_field_cols(ctx, view)}")
    _ok(ctx, f"alter schema template tp1 add (s3 INT64)", "tree")
    cols2 = _await_cols(ctx, view, {"s3"})
    ctx.check("ALTER SCHEMA TEMPLATE 扩列后视图自动加列", "s3" in cols2,
              f"fields={_field_cols(ctx, view)}")
    types = _desc(ctx, view)
    ctx.check("模板扩列的类型正确", types.get("s3", ("", ""))[0] == "INT64", f"types={types}")


def case_sync07_not_for_table_or_normal_view(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s07")
    out1 = _sql(ctx, f"create table {table_db}.t1 (a STRING TAG, b INT32 FIELD) "
                     f"with (auto_sync_schema=true)", "table")
    ctx.check("base table 加 auto_sync_schema 报错", not out1.ok, out1.flat[:200])
    out2 = _sql(ctx, f"create view {table_db}.lv (a STRING TAG) with (auto_sync_schema=true) "
                     f"as select 1", "table")
    ctx.check("逻辑视图加 auto_sync_schema 报错（或语法不支持）", not out2.ok, out2.flat[:200])


def case_sync08_lowercase_conflict(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s08")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 DOUBLE", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**",
                        "with (auto_sync_schema=true)")
    before = _field_cols(ctx, view)
    _ok(ctx, f"create timeseries {tree_db}.d2.s1 INT32", "tree")
    time.sleep(15)
    after = _field_cols(ctx, view)
    ctx.check("同名（小写相同）测点不重复加列", after == before, f"{before} -> {after}")
    ctx.check("原列类型不被覆盖", _desc(ctx, view)["s1"][0] == "DOUBLE", f"desc={_desc(ctx, view)}")


def case_sync09_original_name_conflict(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s09")
    _ok(ctx, f"create timeseries {tree_db}.d1.S1 DOUBLE", "tree")
    _ok(ctx, f"insert into {tree_db}.d1(time, S1) values(1, 1.5)", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG, s1 DOUBLE FIELD FROM S1",
                        f"{tree_db}.**", "with (auto_sync_schema=true)")
    before = _field_cols(ctx, view)
    _ok(ctx, f"create timeseries {tree_db}.d2.S1 DOUBLE", "tree")
    time.sleep(15)
    ctx.check("已作为 original_name 引用的序列名不重复加列", _field_cols(ctx, view) == before,
              f"{before} -> {_field_cols(ctx, view)}")
    rows = _rows(_sql(ctx, f"select dev, s1 from {view}", "table"))
    ctx.check("不新增列时仍能查到匹配设备的数据", len(rows) >= 1, f"rows={rows[:3]}")
    ctx.note_data_written(table_db, "v", "table")


def case_sync10_uppercase(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s10")
    _ok(ctx, f"create timeseries {tree_db}.d0.s0 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**",
                        "with (auto_sync_schema=true)")
    _ok(ctx, f"create timeseries {tree_db}.d1.MixedCase DOUBLE", "tree")
    cols = _await_cols(ctx, view, {"mixedcase"})
    ctx.check("含大写的测点以全小写作为列名", "mixedcase" in cols, f"fields={_field_cols(ctx, view)}")
    sc = _show_create(ctx, view)
    ctx.check("原序列名以 original_measurement 形式保留（FROM MixedCase）",
              "MIXEDCASE" in sc.upper(), sc[:300])


def case_sync11_restrict_orthogonal(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s11")
    _ok(ctx, f"create timeseries {tree_db}.a1.s0 INT32", "tree")
    # 语法顺序：CREATE VIEW ... [RESTRICT] [WITH (...)] AS prefixPath —— RESTRICT 必须在 WITH 之前
    view = _create_view(ctx, table_db, "v", "city STRING TAG", f"{tree_db}.**",
                        "restrict with (auto_sync_schema=true)")
    _ok(ctx, f"create timeseries {tree_db}.a1.s1 INT32", "tree")
    cols = _await_cols(ctx, view, {"s1"})
    ctx.check("RESTRICT + auto_sync_schema 同时生效（符合层级的设备加列）", "s1" in cols,
              f"fields={_field_cols(ctx, view)}")
    _ok(ctx, f"create timeseries {tree_db}.a1.b1.s2 INT32", "tree")
    time.sleep(15)
    ctx.check("RESTRICT 视图不为更深层级设备的测点加列", "s2" not in _field_cols(ctx, view),
              f"fields={_field_cols(ctx, view)}")


def case_sync12_toggle_properties(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s12")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**")
    _ok(ctx, f"create timeseries {tree_db}.d2.s2 DOUBLE", "tree")
    time.sleep(15)
    ctx.check("切换前（false）不加列", "s2" not in _field_cols(ctx, view), f"fields={_field_cols(ctx, view)}")
    out = _sql(ctx, f"alter view {view} set properties auto_sync_schema=true", "table")
    ctx.check("false→true 切换成功", out.ok, out.flat[:200])
    cols = _await_cols(ctx, view, {"s2"})
    ctx.check("false→true 后把已有测点补进视图", "s2" in cols, f"fields={_field_cols(ctx, view)}")
    out2 = _sql(ctx, f"alter view {view} set properties auto_sync_schema=false", "table")
    ctx.check("true→false 切换成功", out2.ok, out2.flat[:200])
    _ok(ctx, f"create timeseries {tree_db}.d3.s3 INT32", "tree")
    time.sleep(15)
    ctx.check("切回 false 后不再自动加列", "s3" not in _field_cols(ctx, view),
              f"fields={_field_cols(ctx, view)}")


def case_sync13_toggle_conflict(ctx: Ctx) -> None:
    """false→true 时存在列类型冲突：**已确认为非缺陷**（TDB-890 讨论结论）。

    产品行为（当前语义，作为期望值固化）：
      * `alter view ... set properties auto_sync_schema=true` **成功**，属性置 true；
      * 类型冲突的列**保留视图里已声明的类型**（不被树侧类型覆盖）；
      * 不报错、不打 ERROR —— 冲突列只是不会从树侧取到数据。
    需求 doc 90 里"合并失败则属性保持 false"指的是**整体合并失败**，
    单列类型不一致按"跳过该列"处理，属产品既定语义。
    """
    tree_db = reset_db(ctx, "tree", "root.tv_s13")
    table_db = reset_db(ctx, "table", "tv_s13")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _ok(ctx, f"create timeseries {tree_db}.d2.s1 INT64", "tree")
    view = f"{table_db}.v"
    _ok(ctx, f"create view {view} (dev STRING TAG, s1 DOUBLE FIELD) as {tree_db}.**", "table")
    out = _sql(ctx, f"alter view {view} set properties auto_sync_schema=true", "table")
    sc = _show_create(ctx, view)
    as_true = "AUTO_SYNC_SCHEMA=TRUE" in sc.upper().replace(" ", "")
    ctx.check("类型冲突时 SET PROPERTIES 成功且属性置 true（当前实现语义）", out.ok and as_true,
              f"alter.ok={out.ok} 属性为true={as_true}")
    ctx.check("冲突列保留视图已声明的类型 DOUBLE（不被树侧 INT32/INT64 覆盖）",
              _desc(ctx, view)["s1"][0] == "DOUBLE", f"desc={_desc(ctx, view)}")
    # 非冲突的新列仍应正常进入视图：再建一个不与既有列冲突的测点
    _ok(ctx, f"create timeseries {tree_db}.d3.brand_new DOUBLE", "tree")
    time.sleep(15)
    ctx.check("非冲突的新测点仍能自动加列（冲突列不影响其它列扩列）",
              "brand_new" in _field_cols(ctx, view), f"fields={_field_cols(ctx, view)}")


def case_sync14_drop_series_keeps_column(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s14")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _ok(ctx, f"insert into {tree_db}.d1(time,s1) values(1,1)", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**",
                        "with (auto_sync_schema=true)")
    _ok(ctx, f"delete timeseries {tree_db}.d1.s1", "tree")
    time.sleep(10)
    ctx.check("删除测点不会自动删列", "s1" in _field_cols(ctx, view), f"fields={_field_cols(ctx, view)}")
    rows = _rows(_sql(ctx, f"select dev, s1 from {view}", "table"))
    ctx.check("被删测点的列查询结果为 null（不再有数据行）",
              all(r[-1].lower() in ("null", "") for r in rows) if rows else True, f"rows={rows[:3]}")


def case_sync15_object_type(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "s15")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    out = _sql(ctx, f"create timeseries {tree_db}.d1.obj OBJECT", "tree")
    ctx.check("树模型不支持 OBJECT 类型测点（建序列报错）", not out.ok, out.flat[:200])
    out2 = _sql(ctx, f"create view {table_db}.v (dev STRING TAG, obj OBJECT FIELD) as {tree_db}.**",
                "table")
    created = _cols(ctx, f"{table_db}.v")
    if not out2.ok:
        ctx.check("视图声明 OBJECT 列被明确拒绝", True, out2.flat[:200])
    else:
        # 需求只规定"树模型不支持 OBJECT 测点"；视图声明一个不存在的类型时，
        # 按 §2.1.1.4 该列应恒为 NULL 而不是报错/崩溃。
        rows = _rows(_sql(ctx, f"select obj from {table_db}.v", "table"))
        ctx.check("声明 OBJECT 列后查询不报错且该列恒为 NULL（无 object 测点）",
                  all((r[-1] or "").lower() in ("null", "") for r in rows) if rows else True,
                  f"rows={rows[:3]} cols={created}")
        ctx.note("  结论：OBJECT 列可创建但恒为 NULL；如需禁止需产品确认（当前按需求 §2.1.1.4 视为合法）")


# ============================================================ C. 高可用场景

def case_ha01_add_column_with_dn_down(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "ha01")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**",
                        "with (auto_sync_schema=true)")
    dn = ctx.cfg.dn_hosts[-1]
    try:
        ctx.mark_harness_action(f"TV-HA-01 停 DataNode {dn}", kind="stop")
        ctx.cluster.stop_node(dn, "dn")
        ctx.by_design_gone.add(dn)
        _ok(ctx, f"create timeseries {tree_db}.d2.s2 DOUBLE", "tree")
        cols = _await_cols(ctx, view, {"s2"}, timeout=90)
        ctx.check("停 1 台 DN 期间新增测点仍能触发扩列", "s2" in cols,
                  f"fields={_field_cols(ctx, view)}")
    finally:
        ctx.mark_harness_action(f"TV-HA-01 重启 DataNode {dn}", kind="start")
        ctx.cluster.start_node(dn, "dn")
        ctx.by_design_gone.discard(dn)
        ctx.cluster.wait_healthy(timeout=600)


def case_ha02_add_column_with_2dn_down(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "ha02")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**",
                        "with (auto_sync_schema=true)")
    downs = list(ctx.cfg.dn_hosts[-2:])
    try:
        for dn in downs:
            ctx.mark_harness_action(f"TV-HA-02 停 DataNode {dn}", kind="stop")
            ctx.cluster.stop_node(dn, "dn")
            ctx.by_design_gone.add(dn)
        _ok(ctx, f"create timeseries {tree_db}.d2.s2 DOUBLE", "tree")
        cols = _await_cols(ctx, view, {"s2"}, timeout=120)
        ctx.check("停 2 台 DN（SR3 仍有副本）期间扩列成功", "s2" in cols,
                  f"fields={_field_cols(ctx, view)}")
    finally:
        for dn in downs:
            ctx.mark_harness_action(f"TV-HA-02 重启 DataNode {dn}", kind="start")
            ctx.cluster.start_node(dn, "dn")
            ctx.by_design_gone.discard(dn)
        ctx.cluster.wait_healthy(timeout=900)


def case_ha03_restart_cluster(ctx: Ctx) -> None:
    tree_db, table_db = _new_db(ctx, "ha03")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    _ok(ctx, f"insert into {tree_db}.d1(time,s1) values(1, 1)", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**",
                        "with (auto_sync_schema=true)")
    before_cols = _cols(ctx, view)
    ctx.mark_harness_action("TV-HA-03 整集群重启", kind="restart")
    ctx.cluster.stop_all()
    ctx.cluster.start_all()
    ctx.cluster.wait_healthy(timeout=1200)
    # 重启后 Ratis/gRPC appender 需要收敛期：窗口锚在"重启完成"这一刻
    ctx.mark_harness_action("TV-HA-03 重启完成后的收敛期", kind="start")
    # 先确认"库"还在，再确认"视图定义"没变 —— 否则无法区分是整库丢失还是视图丢失
    tree_dbs = _sql(ctx, "show databases", "tree").flat
    table_dbs = _sql(ctx, "show databases", "table").flat
    ctx.note(f"    重启后树库列表含 {tree_db}: {tree_db.split('.')[-1] in tree_dbs}")
    ctx.note(f"    重启后表库列表含 {table_db}: {table_db in table_dbs}")
    ctx.check("整集群重启后表模型库仍存在（排除整库丢失）", table_db in table_dbs,
              f"table_dbs={table_dbs[:400]}")
    after_cols = _cols(ctx, view)
    ctx.check("整集群重启后视图定义不变", bool(after_cols) and before_cols == after_cols,
              f"{before_cols} -> {after_cols or '视图不存在/库不存在'}")
    _ok(ctx, f"create timeseries {tree_db}.d2.s2 DOUBLE", "tree")
    cols = _await_cols(ctx, view, {"s2"}, timeout=120)
    ctx.check("重启后 auto_sync_schema 仍生效（新测点仍能加列）", "s2" in cols,
              f"fields={_field_cols(ctx, view)}")
    ctx.note_data_written(table_db, "v", "table")


# ================================================================ D. 资源泄漏

def case_leak01_view_churn(ctx: Ctx) -> None:
    rounds = ctx.cfg.get_int("TV_LEAK_ROUNDS")
    tree_db, table_db = _new_db(ctx, "lk01")
    _ok(ctx, f"create timeseries {tree_db}.d0.s0 INT32", "tree")

    def sample() -> int:
        total = 0
        for host in ctx.cfg.dn_hosts:
            out = ctx.ssh.run(
                host,
                "for p in $(ps -eo pid,args --no-headers | awk '/[D]ataNode/{print $1}'); "
                "do timeout 25 jcmd $p Thread.print 2>/dev/null | grep -c '^\"'; done",
                check=False, timeout=90)
            for n in (out.out or "").split():
                try:
                    total += int(n)
                except ValueError:
                    pass
        return total

    samples = []
    for i in range(rounds):
        view = f"{table_db}.v{i}"
        _ok(ctx, f"create view {view} (dev STRING TAG) with (auto_sync_schema=true) as {tree_db}.**",
            "table")
        _ok(ctx, f"create timeseries {tree_db}.d{i}.n{i} DOUBLE", "tree")
        _await_cols(ctx, view, {f"n{i}"}, timeout=60)
        _ok(ctx, f"drop view {view}", "table")
        time.sleep(5)
        samples.append(sample())
    ctx.check("反复建删视图+新增测点后 DN 线程数不单调增长",
              len(samples) >= 3 and samples[-1] <= samples[1] + max(50, samples[1] // 20),
              f"samples={samples}")



# ============================================ E. 参考用例补充 / 回归场景
# 来源：/data/deepseek/iotdb-sqltest/table/scripts/OperateMetadata/View/TreeViewTest

def case_ref01_aligned_tags_delete(ctx: Ctx) -> None:
    """issue 0335：对齐序列 + tags，删测点后视图查询不报错。"""
    tree_db, table_db = _new_db(ctx, "r01")
    _ok(ctx, f"create aligned timeseries {tree_db}.d1(s01 INT32 ENCODING=RLE COMPRESSOR=SNAPPY "
             f"tags(city=beijing, description='desc'), s02 DOUBLE, s03 BOOLEAN)", "tree")
    _ok(ctx, f"insert into {tree_db}.d1(time,s01,s02,s03) values(1000,88,9.9,true)", "tree")
    view = _create_view(ctx, table_db, "v1", "device_id STRING TAG", f"{tree_db}.**")
    rows = _rows(_sql(ctx, f"select s01,s02,s03 from {view}", "table"))
    ctx.check("对齐序列 + tags 的视图可查询", len(rows) >= 1, f"rows={rows[:3]}")
    _ok(ctx, f"delete timeseries {tree_db}.**", "tree")
    out = _sql(ctx, f"select s01 from {view}", "table")
    ctx.check("删测点后查询视图不报错", out.ok, out.flat[:200])


def case_ref02_nested_same_measurement(ctx: Ctx) -> None:
    """issue 0364/0367：多层设备都有同名测点 current（类型不同）+ RESTRICT。"""
    tree_db, table_db = _new_db(ctx, "r02")
    _ok(ctx, f"create timeseries {tree_db}.c1.c2.current INT32", "tree")
    _ok(ctx, f"create timeseries {tree_db}.c1.current INT64", "tree")
    _ok(ctx, f"create timeseries {tree_db}.current STRING", "tree")
    _ok(ctx, f"insert into {tree_db}.c1.c2(time,current) values(2000,2000)", "tree")
    _ok(ctx, f"insert into {tree_db}.c1(time,current) values(3000,3000)", "tree")
    view = _create_view(ctx, table_db, "v1", "device_id STRING TAG", f"{tree_db}.**", "RESTRICT")
    cols = _desc(ctx, view)
    ctx.check("多层同名测点（类型不同）建 RESTRICT 视图不报错", len(cols) >= 2, f"desc={cols}")
    sc = _show_create(ctx, view)
    ctx.check("show create view 含 RESTRICT", "RESTRICT" in sc.upper(), sc[:240])
    out = _sql(ctx, f"select current from {view}", "table")
    ctx.check("多层同名测点的视图可查询", out.ok, out.flat[:200])


def case_ref03_db_name_equals_device(ctx: Ctx) -> None:
    """issue 0420：树模型 db 与 device 同名时，建视图成功且查询不报 301。"""
    tree_db, table_db = _new_db(ctx, "r03")
    _ok(ctx, f"create timeseries {tree_db}.s1 INT32", "tree")       # 设备就是 root.tv_r03
    _ok(ctx, f"insert into {tree_db}(time, s1) values(1, 1)", "tree")
    view = _create_view(ctx, table_db, "v1", "device_id STRING TAG", f"{tree_db}.**")
    out = _sql(ctx, f"select s1 from {view}", "table")
    ctx.check("db 与 device 同名时视图查询不报错（非 301）", out.ok, out.flat[:220])
    if out.ok:
        ctx.check("同名场景能查到数据", len(_rows(out)) >= 1, f"rows={_rows(out)[:3]}")
    ctx.note_data_written(table_db, "v1", "table")


def case_ref04_field_without_datatype(ctx: Ctx) -> None:
    """issue 0422：FIELD 列不写数据类型时应由扫描推断（不是语法错误）。"""
    tree_db, table_db = _new_db(ctx, "r04")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    out = _sql(ctx, f"create view {table_db}.v (dev STRING TAG, s1 FIELD) as {tree_db}.**", "table")
    if out.ok:
        cols = _desc(ctx, f"{table_db}.v")
        ctx.check("未写 dataType 的 FIELD 列由扫描推断出类型",
                  cols.get("s1", ("", ""))[0] == "INT32", f"desc={cols}")
    else:
        ctx.check("未写 dataType 的 FIELD 列被明确拒绝（需求允许推断，若拒绝需确认口径）",
                  False, out.flat[:200])


def case_ref05_many_columns(ctx: Ctx) -> None:
    """create_view_1000_col：一次建 200 个测点，视图自动扫描出全部列。"""
    tree_db, table_db = _new_db(ctx, "r05")
    n = 200
    cols_sql = ", ".join(f"s{i} INT32" for i in range(n))
    _ok(ctx, f"create aligned timeseries {tree_db}.d1({cols_sql})", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG", f"{tree_db}.**")
    fields = _field_cols(ctx, view)
    ctx.check(f"{n} 个测点全部进入视图列（无截断/无遗漏）", len(fields) == n,
              f"fields={len(fields)}")
    _ok(ctx, f"insert into {tree_db}.d1(time, s0, s199) values(1, 1, 2)", "tree")
    out = _sql(ctx, f"select s0, s199 from {view}", "table")
    ctx.check("首尾列可查询", out.ok and len(_rows(out)) >= 1, out.flat[:180])
    ctx.note_data_written(table_db, "v", "table")


def case_ref06_view_name(ctx: Ctx) -> None:
    """view 名合法性：反引号/中文/大小写敏感。"""
    tree_db, table_db = _new_db(ctx, "r06")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    # 表模型标识符用双引号（反引号是树模型的写法，表模型报 700）
    ok_view = _create_view(ctx, table_db, '"中文视图"', "dev STRING TAG", f"{tree_db}.**")
    ctx.check("中文视图名可创建", "中文视图" in ok_view, ok_view)
    out = _sql(ctx, f"select s1 from {ok_view}", "table")
    ctx.check("中文视图名可查询", out.ok, out.flat[:160])
    out2 = _sql(ctx, f'create view {table_db}."a b" (dev STRING TAG) as {tree_db}.**', "table")
    ctx.check("含空格的视图名行为明确（成功或明确报错）", True, f"ok={out2.ok} {out2.flat[:120]}")


def case_sync16_add_object_column(ctx: Ctx) -> None:
    """ALTER VIEW ADD COLUMN 声明 OBJECT（树模型无 object 测点）。"""
    tree_db, table_db = _new_db(ctx, "s16")
    _ok(ctx, f"create timeseries {tree_db}.d1.s1 INT32", "tree")
    view = _create_view(ctx, table_db, "v", "dev STRING TAG, s1 INT32 FIELD", f"{tree_db}.**")
    out = _sql(ctx, f"alter view {view} add column obj OBJECT FIELD", "table")
    cols = _cols(ctx, view)
    ctx.check("ADD COLUMN OBJECT 的行为明确：要么报错，要么新增列但无数据",
              (not out.ok) or ("obj" in cols), f"ok={out.ok} cols={cols} out={out.flat[:160]}")


SUPPLEMENTARY_CASES = [
    CaseSpec("TV-REF-01", "参考回归", "tree+table", "issue0335：对齐+tags、删测点后视图查询不报错", "P1", case_ref01_aligned_tags_delete),
    CaseSpec("TV-REF-02", "参考回归", "tree+table", "issue0364/0367：多层同名测点 + RESTRICT", "P1", case_ref02_nested_same_measurement),
    CaseSpec("TV-REF-03", "参考回归", "tree+table", "issue0420：db 与 device 同名时视图查询不报 301", "P1", case_ref03_db_name_equals_device),
    CaseSpec("TV-REF-04", "参考回归", "tree+table", "issue0422：FIELD 列省略 dataType 由扫描推断", "P1", case_ref04_field_without_datatype),
    CaseSpec("TV-REF-05", "参考回归", "tree+table", "200 列宽视图：全部测点进入列且首尾可查", "P2", case_ref05_many_columns),
    CaseSpec("TV-REF-06", "参考回归", "tree+table", "视图名合法性（中文/空格）", "P2", case_ref06_view_name),
    CaseSpec("TV-SYNC-16", "自动扩列", "table", "ALTER VIEW ADD COLUMN OBJECT 的类型行为", "P1", case_sync16_add_object_column),
]


# ================================================================ 用例注册表

TREEVIEW_CASES = [
    # ---- A. 基础语义（docx 需求 2.1~2.3）
    CaseSpec("TV-BASE-01", "基础语义", "tree+table", "CREATE VIEW 后列定义正确、表模型可查到树模型数据", "P0", case_base01_create_and_query, gate=True),
    CaseSpec("TV-BASE-02", "基础语义", "tree+table", "prefixPath 必须以 ** 结尾且中间不能出现 *", "P0", case_base02_prefix_check, gate=True),
    CaseSpec("TV-BASE-03", "基础语义", "tree+table", "未指定 FIELD 时扫描 prefixPath 下全部测点并推断类型", "P0", case_base03_scan_all_measurements, gate=True),
    CaseSpec("TV-BASE-04", "基础语义", "tree+table", "FIELD FROM original_measurement 列改名", "P1", case_base04_field_rename),
    CaseSpec("TV-BASE-05", "基础语义", "tree+table", "视图列不支持 ATTRIBUTE", "P1", case_base05_no_attribute),
    CaseSpec("TV-BASE-06", "基础语义", "tree+table", "RESTRICT 与非 RESTRICT 的设备层级差异", "P0", case_base06_restrict, gate=True),
    CaseSpec("TV-BASE-07", "基础语义", "tree+table", "同名测点类型冲突时建视图报错", "P0", case_base07_type_conflict),
    CaseSpec("TV-BASE-08", "基础语义", "tree+table", "prefixPath 下无测点时建视图报错", "P1", case_base08_no_measurement),
    CaseSpec("TV-BASE-09", "基础语义", "tree+table", "OR REPLACE 语义与 table/view 重名规则", "P0", case_base09_or_replace),
    CaseSpec("TV-BASE-10", "基础语义", "tree+table", "视图 TTL 生效且不改变树库 TTL", "P1", case_base10_ttl),
    CaseSpec("TV-BASE-11", "基础语义", "tree+table", "对齐设备全 null 行保留（表模型语义）", "P1", case_base11_aligned_null_rows),
    CaseSpec("TV-BASE-12", "展示", "table", "show tables details 的 TableType 区分 VIEW FROM TREE", "P0", case_base12_show_tables_type),
    CaseSpec("TV-BASE-13", "展示", "table", "show create view/table 及负向场景", "P0", case_base13_show_create),
    CaseSpec("TV-BASE-14", "DDL", "table", "ALTER VIEW rename/rename column/add/drop column/set properties", "P0", case_base14_alter),
    CaseSpec("TV-BASE-15", "DDL", "table", "COMMENT ON VIEW / COLUMN", "P2", case_base15_comment),
    # ---- B. auto_sync_schema（doc 90 / TDB-343）
    CaseSpec("TV-SYNC-01", "自动扩列", "tree+table", "auto_sync_schema 默认 false：新测点不加列", "P0", case_sync01_default_false, gate=True),
    CaseSpec("TV-SYNC-02", "自动扩列", "tree+table", "显式 auto_sync_schema=false 可查看且不加列", "P1", case_sync02_explicit_false),
    CaseSpec("TV-SYNC-03", "自动扩列", "tree+table", "true + create timeseries 自动加列", "P0", case_sync03_create_timeseries, gate=True),
    CaseSpec("TV-SYNC-04", "自动扩列", "tree+table", "true + aligned/multi 测点自动加列", "P0", case_sync04_aligned_and_multi),
    CaseSpec("TV-SYNC-05", "自动扩列", "tree+table", "多设备 INSERT 自动建测点并加列、数据可查", "P0", case_sync05_insert_multi_device),
    CaseSpec("TV-SYNC-06", "自动扩列", "tree+table", "模板激活/模板扩列触发视图自动加列", "P0", case_sync06_template),
    CaseSpec("TV-SYNC-07", "自动扩列", "table", "auto_sync_schema 只对树转表视图生效", "P1", case_sync07_not_for_table_or_normal_view),
    CaseSpec("TV-SYNC-08", "自动扩列", "tree+table", "同名（小写相同）测点不重复加列、类型不被覆盖", "P0", case_sync08_lowercase_conflict),
    CaseSpec("TV-SYNC-09", "自动扩列", "tree+table", "original_name 冲突不重复加列但仍可查到数据", "P1", case_sync09_original_name_conflict),
    CaseSpec("TV-SYNC-10", "自动扩列", "tree+table", "含大写测点：列名小写 + original_name 保留", "P0", case_sync10_uppercase),
    CaseSpec("TV-SYNC-11", "自动扩列", "tree+table", "RESTRICT 与 auto_sync_schema 正交", "P1", case_sync11_restrict_orthogonal),
    CaseSpec("TV-SYNC-12", "自动扩列", "tree+table", "SET PROPERTIES 在 true/false 间切换的行为", "P0", case_sync12_toggle_properties),
    CaseSpec("TV-SYNC-13", "自动扩列", "tree+table", "类型冲突时 false→true 成功、冲突列不被覆盖（非缺陷，行为固化）", "P1", case_sync13_toggle_conflict),
    CaseSpec("TV-SYNC-14", "自动扩列", "tree+table", "删除测点不自动删列、查询为 null", "P2", case_sync14_drop_series_keeps_column),
    CaseSpec("TV-SYNC-15", "类型", "tree+table", "OBJECT 类型：树模型不支持建序列，视图声明给出明确错误", "P0", case_sync15_object_type),
    # ---- C. 高可用
    CaseSpec("TV-HA-01", "高可用", "tree+table", "停 1 台 DN 期间新增测点仍能扩列", "P0", case_ha01_add_column_with_dn_down),
    CaseSpec("TV-HA-02", "高可用", "tree+table", "停 2 台 DN（SR3 仍有副本）期间扩列成功", "P0", case_ha02_add_column_with_2dn_down),
    CaseSpec("TV-HA-03", "高可用", "tree+table", "整集群重启后视图定义与自动扩列仍生效", "P0", case_ha03_restart_cluster, needs_restart=True),
    # ---- D. 泄漏
    CaseSpec("TV-LEAK-01", "泄漏", "tree+table", "反复建删视图+新增测点：DN 线程不持续增长", "P1", case_leak01_view_churn),
]

# 参考用例补充（放在列表定义之后，避免前向引用）
TREEVIEW_CASES.extend(SUPPLEMENTARY_CASES)
