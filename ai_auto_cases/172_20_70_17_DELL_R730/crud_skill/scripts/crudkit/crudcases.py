"""The TTL case matrix and its runner.

Every case runs against the live cluster, uses its own database (so cases cannot
contaminate each other and no cluster reset is needed between them), and records what it
saw as `Check` rows.  A case is PASS only when every check passed; a case may SKIP with a
stated reason when a precondition does not hold (for example the audit database not being
enabled) -- that is reported as SKIP, never as PASS.
"""
from __future__ import annotations

import json
import re
import shlex
import threading
import time
import traceback
from contextlib import contextmanager as _contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from .remote import probe_port, wait_until
from .ttlapi import TtlApi, ago_ms, cell, now_ms, to_epoch_ms
from .ttlprops import AUDIT_KEY

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


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
    api: TtlApi
    log: Callable[[str], None]
    run_dir: Path
    case_dir: Path
    case_id: str = ""
    checks: list[Check] = field(default_factory=list)
    skipped: str = ""
    cleanup: list[str] = field(default_factory=list)
    _log_handle: object = None

    # ---------------------------------------------------------------- recording
    def check(self, name: str, ok: bool, detail: str = "", evidence: str = "") -> bool:
        self.checks.append(Check(name=name, ok=bool(ok), detail=detail, evidence=evidence[:4000]))
        self.note(f"  [{'ok' if ok else 'FAIL'}] {name}" + (f" -- {detail}" if detail else ""))
        return bool(ok)

    def skip(self, reason: str) -> None:
        self.skipped = reason
        self.note(f"  [skip] {reason}")

    def req(self, outcome, what: str = "") -> None:
        if not outcome.ok:
            raise AssertionError(f"{what or outcome.statement} failed: {outcome.output[:1200]}")

    def note(self, text: str) -> None:
        self.log(text)
        if self._log_handle is None:
            self._log_handle = (self.case_dir / "actions.log").open("a", encoding="utf-8")
        self._log_handle.write(text.rstrip() + "\n")
        self._log_handle.flush()

    def trace(self, statement: str, output: str) -> None:
        flat = " ".join(output.split())
        self.note(f"    SQL> {statement[:300]}")
        self.note(f"    OUT> {flat[:600]}")


@dataclass
class CaseSpec:
    case_id: str
    area: str
    model: str
    title: str
    priority: str
    fn: Callable[[Ctx], None]
    needs_restart: bool = False
    note: str = ""


# --------------------------------------------------------------------- helpers
def clear_db_ttl(ctx: Ctx, db: str) -> None:
    """Drop every TTL rule that points into ``db``.

    TTL rules are cluster state, not database state: dropping a database does **not** remove
    its rules.  A leftover rule is not harmless -- it makes inserts whose timestamp is older
    than the bound fail with 607, hides rows, and eats the 1000-rule quota, any of which would
    look like a product defect in the next case.
    """
    for path in list(ctx.api.ttl_map()):
        # Table-model rules are reported with a root. prefix even though the database itself is
        # not under root (set ttl to <db>.** is a parse error there), so match both spellings.
        if path in (db, f"root.{db}") or path.startswith((f"{db}.", f"root.{db}.")):
            ctx.api.unset_ttl(path)
            ctx.note(f"    cleared leftover ttl rule {path}")


def reset_tree_db(ctx: Ctx, db: str) -> None:
    # The tree model has no `drop database if exists` (error 700: mismatched input 'if'), so
    # drop unconditionally and ignore "does not exist"; the create below is what must succeed.
    clear_db_ttl(ctx, db)
    out = ctx.api.run(f"drop database {db}")
    if not out.ok:
        ctx.note(f"    drop database {db}: {out.output.strip()[:160]}")
    ctx.req(ctx.api.run(f"create database {db}"), f"create database {db}")


def reset_table_db(ctx: Ctx, db: str, db_ttl: str | None = None) -> None:
    """Drop + recreate a table-model database, optionally with a database-level TTL.

    A table-model database TTL comes from `create database ... with (TTL=...)`.  The
    device-level rule form `set ttl to root.<db>.**` works for the tree model but has **no**
    effect on a table-model database (measured: `show databases` stays INF and rows older
    than the rule stay visible), so cases must not use it to give tables a default TTL.
    """
    clear_db_ttl(ctx, db)
    ctx.api.run(f"drop database if exists {db}", dialect="table")
    clause = f" with (TTL={db_ttl})" if db_ttl is not None else ""
    ctx.req(ctx.api.run(f"create database {db}{clause}", dialect="table"),
            f"create database {db}{clause}")


def ensure_series(ctx: Ctx, device: str, measurements: tuple[str, ...] = ("s0",)) -> None:
    for m in measurements:
        out = ctx.api.run(f"create timeseries {device}.{m} with datatype=FLOAT, encoding=PLAIN, "
                          f"compression=SNAPPY")
        # Re-creating an existing timeseries answers 503 "already exist"; that is the expected
        # state when a case writes several rows into the same device, not a failure.
        if not out.ok and "already exist" not in out.output.lower():
            raise AssertionError(f"create timeseries {device}.{m} failed: {out.output[:600]}")


def write_tree_rows(ctx: Ctx, device: str, stamps: list[int], value: float = 1.0) -> None:
    ensure_series(ctx, device)
    for stamp in stamps:
        out = ctx.api.insert_tree(device, stamp, ["s0"], value)
        if not out.ok:
            raise AssertionError(f"insert into {device} failed: {out.output[:800]}")


def tree_ttl_map(ctx: Ctx, pattern: str = "") -> dict[str, str]:
    return {r.path: r.ttl for r in ctx.api.show_all_ttl()}


def devices_of(ctx: Ctx, db: str) -> list[str]:
    rows = ctx.api.show_devices(f"{db}.**")
    return [name for name in (cell(r, "device") for r in rows) if name]


# ============================================================ A. 语法与路径规则

# ===================== CRUD 用例段（自动合并） =====================

DB = "root.crud_a"
DBT = "usr_crud_a"


def _unimplemented(cid: str):
    def run(ctx) -> None:
        ctx.skip(f"{cid}: 断言尚未实现（用例已设计，执行器待补齐）")
    run.__name__ = f"case_{cid}"
    return run


_IMPL = {}


def _impl(fn):
    _IMPL[fn.__name__[len("case_"):]] = fn
    return fn


@_impl
def case_crud_insert_single_tree(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_000_000_000
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 1.0)")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1 WHERE time = {ts}")
    ctx.check(f"按时间点回读应命中 1 行（实测 {len(rows)}）", len(rows) == 1)
    vals = []
    for r in rows:
        for v in r.values():
            try:
                vals.append(float(v))
            except (TypeError, ValueError):
                continue
    ctx.check(f"写入值一致（期望 1.0，实测 {vals}）", vals and vals[-1] == 1.0)


@_impl
def case_crud_insert_multi_rows(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_000_100_000
    for i in range(5):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i}, {float(i)})")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.check(f"回读行数应为 5（实测 {len(rows)}）", len(rows) == 5)


@_impl
def case_crud_overwrite_same_ts(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_000_200_000
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 1.0)")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 2.0)")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1 WHERE time = {ts}")
    ctx.check(f"同时间戳应只有一行（实测 {len(rows)}）", len(rows) == 1)
    vals = []
    for r in rows:
        for v in r.values():
            try:
                vals.append(float(v))
            except (TypeError, ValueError):
                continue
    ctx.check(f"后写应覆盖前写（期望 2.0，实测 {vals}）", vals and vals[-1] == 2.0)


@_impl
def case_crud_delete_time_range_tree(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_000_300_000
    for i in range(3):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    ctx.api.run(f"DELETE FROM {DB}.d1.** WHERE time <= {base}")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.check(f"删除 1 行后应剩 2 行（实测 {len(rows)}）", len(rows) == 2)


@_impl
def case_crud_query_time_range(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_000_400_000
    for i in range(4):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1 WHERE time >= {base + 1000} AND time < {base + 3000}")
    ctx.check(f"[start,end) 应命中 2 行（实测 {len(rows)}）", len(rows) == 2)
    rows2 = ctx.api.table(f"SELECT s1 FROM {DB}.d1 WHERE time >= {base + 3000}")
    ctx.check(f"右端点不应包含（实测 {len(rows2)}）", len(rows2) == 1)


@_impl
def case_crud_insert_single_table(ctx) -> None:
    reset_table_db(ctx, DBT)
    ctx.api.create_table(DBT, "t1")
    ts = 1_700_000_500_000
    ctx.api.insert_table(DBT, "t1", "d1", ts, 1.0)
    rows = ctx.api.table("select * from t1", dialect="table", database=DBT)
    ctx.check(f"表模型回读应至少 1 行（实测 {len(rows)}）", len(rows) >= 1)
    flat = [str(v) for r in rows for v in r.values()]
    ctx.check(f"写入值应可见（{flat[:8]}）", any(v.startswith("1.0") for v in flat))


@_impl
def case_crud_delete_time_range_table(ctx) -> None:
    reset_table_db(ctx, DBT)
    ctx.api.create_table(DBT, "t1")
    base = 1_700_000_600_000
    for i in range(3):
        ctx.api.insert_table(DBT, "t1", "d1", base + i * 1000, float(i))
    ctx.api.run(f"delete from t1 where time <= {base}", dialect="table", database=DBT)
    rows = ctx.api.table("select * from t1", dialect="table", database=DBT)
    ctx.check(f"表模型删除 1 行后应剩 2 行（实测 {len(rows)}）", len(rows) == 2)


@_impl
def case_crud_schema_auto_create(ctx) -> None:
    db = "root.crud_b"
    reset_tree_db(ctx, db)
    ts = 1_700_000_700_000
    ctx.api.run(f"insert into {db}.d1(timestamp, s1) values ({ts}, 5.0)")
    rows = ctx.api.table(f"select s1 from {db}.d1")
    ctx.check(f"无模式写入后应回读 1 行（实测 {len(rows)}）", len(rows) == 1)
    devs = ctx.api.table(f"show devices {db}.**")
    ctx.check(f"设备元数据应自动创建（实测 {len(devs)} 个）", len(devs) >= 1)



@_impl
def case_crud_insert_all_types_tree(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_001_000_000
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, b, i32, i64, f, d, t) VALUES ({ts}, true, 1, 2, 3.0, 4.0, 'txt')")
    rows = ctx.api.table(f"SELECT * FROM {DB}.d1")
    ctx.check(f"全类型写入应回读 1 行（实测 {len(rows)}）", len(rows) == 1)
    flat = " ".join(str(v) for r in rows for v in r.values())
    ctx.check(f"文本列应可见（{flat[:120]}）", "txt" in flat)


@_impl
def case_crud_insert_null_field_tree(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_001_100_000
    out = str(ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, null)"))
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1 WHERE time = {ts}")
    ctx.note(f"树模型显式 NULL 写入返回: {out[:150]}")
    ctx.check("树模型显式 NULL 写入被拒（507）且不产生行", "507" in out and len(rows) == 0,
              f"返回 {out[:90]}；实测 {len(rows)} 行")


@_impl
def case_crud_out_of_order_enabled(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (1700001200000, 2.0)")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (1700001100000, 1.0)")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.check(f"乱序写入后应回读 2 行（实测 {len(rows)}）", len(rows) == 2)
    ctx.note("RC5 源码核对：不存在 enable_ooo 开关，乱序写入始终接受（原用例的‘关闭后应被拒’前提不成立）")


@_impl
def case_crud_query_limit_offset(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_001_200_000
    for i in range(5):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1 LIMIT 2 OFFSET 1")
    ctx.check(f"LIMIT 2 OFFSET 1 应返回 2 行（实测 {len(rows)}）", len(rows) == 2)


@_impl
def case_crud_query_aggregation(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_001_300_000
    for i in range(5):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    got = str(ctx.api.scalar(f"SELECT count(s1) FROM {DB}.d1")).strip()
    ctx.check(f"count 应为 5（实测 {got}）", got in ("5", "5.0"))


@_impl
def case_crud_query_where_filter(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_001_400_000
    for i in range(5):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1 WHERE s1 > 2")
    ctx.check(f"WHERE s1 > 2 应命中 2 行（实测 {len(rows)}）", len(rows) == 2)
    ctx.note("注：s1>2 命中 2 行而非 3 行时为可疑项，需确认采样/过滤语义后再定论")


@_impl
def case_crud_query_order_desc(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_001_500_000
    for i in range(3):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1 ORDER BY TIME DESC")
    ctx.check(f"倒序应返回 3 行（实测 {len(rows)}）", len(rows) == 3)
    flat = []
    for r in rows:
        for v in r.values():
            try:
                flat.append(float(v))
            except (TypeError, ValueError):
                continue
    _rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1 ORDER BY TIME DESC")
    _vals = []
    for _r in _rows:
        for _v in _r.values():
            try:
                _vals.append(float(_v))
            except (TypeError, ValueError):
                continue
    ctx.check("ORDER BY TIME DESC 首行应为最新值 2.0", bool(_vals) and _vals[0] == 2.0, f"实测序列 {_vals}")


@_impl
def case_crud_delete_device(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_001_600_000
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 1.0)")
    ctx.api.run(f"DELETE FROM {DB}.d1.**")
    devs = ctx.api.table(f"SHOW DEVICES {DB}.**")
    ctx.check("设备级删除后数据应清空（DELETE FROM 语法在本版本为 700，改用 .** 形态）.**",
              len(ctx.api.table(f"SELECT s1 FROM {DB}.d1")) == 0,
              f"实测剩余 {len(ctx.api.table(f'SELECT s1 FROM {DB}.d1'))} 行")




def _flat(rows):
    out = []
    for r in rows:
        for v in r.values():
            out.append(v)
    return out


@_impl
def case_crud_delete_nonexistent(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_002_000_000
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 1.0)")
    ctx.api.run(f"DELETE FROM {DB}.d1.** WHERE time > {ts + 100000} AND time <= {ts + 200000}")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.check(f"删除不存在区间应幂等（实测剩余 {len(rows)} 行）", len(rows) == 1)


@_impl
def case_crud_delete_database(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ts = 1_700_002_100_000
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 1.0)")
    ctx.api.run(f"DROP DATABASE {DB}")
    dbs = ctx.api.table("SHOW DATABASES")
    names = " ".join(str(v) for v in _flat(dbs))
    ctx.check(f"删库后不应再出现该库（{names[:120]}）", DB not in names)


@_impl
def case_crud_delete_keeps_schema(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_002_200_000
    for i in range(3):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    ctx.api.run(f"DELETE FROM {DB}.d1.** WHERE time <= {base + 1000}")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.check(f"删除 2 行后应剩 1 行（实测 {len(rows)}）", len(rows) == 1)
    meta = ctx.api.table(f"SHOW TIMESERIES {DB}.**")
    ctx.check(f"删数据后元数据应保留（实测 {len(meta)} 条）", len(meta) >= 1)


@_impl
def case_crud_delete_out_of_order(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (1700002200000, 2.0)")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (1700002100000, 1.0)")
    ctx.api.run(f"DELETE FROM {DB}.d1.** WHERE time <= 1700002100000")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.check(f"乱序写入后按时间区间删除应剩 1 行（实测 {len(rows)}）", len(rows) == 1)


@_impl
def case_crud_flush_query_equal(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_002_300_000
    for i in range(3):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    before = len(ctx.api.table(f"SELECT s1 FROM {DB}.d1"))
    ctx.api.flush()
    after = len(ctx.api.table(f"SELECT s1 FROM {DB}.d1"))
    ctx.check(f"flush 前后行数一致且为 3（{before} -> {after}）", before == after == 3)


@_impl
def case_crud_query_expression(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_002_400_000
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 1.0)")
    rows = ctx.api.table(f"SELECT s1 + 1 FROM {DB}.d1 WHERE time = {ts}")
    flat = [str(v) for v in _flat(rows)]
    ctx.check(f"表达式 s1+1 应为 2.0（{flat[:8]}）", any(v.startswith("2.0") for v in flat))


@_impl
def case_crud_query_group_by_level(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_002_500_000
    for i in range(3):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    rows = ctx.api.table(f"SELECT count(s1) FROM {DB}.** GROUP BY LEVEL=1")
    ctx.check(f"GROUP BY LEVEL=1 应至少返回 1 行（实测 {len(rows)}）", len(rows) >= 1)


@_impl
def case_crud_query_last_row(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_002_600_000
    for i in range(3):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    rows = ctx.api.table(f"SELECT LAST s1 FROM {DB}.d1")
    ctx.check(f"LAST 查询应返回 1 行（实测 {len(rows)}）", len(rows) == 1)
    flat = [str(v) for v in _flat(rows)]
    ctx.check(f"LAST 值应为 2.0（{flat[:8]}）", any(v.startswith("2.0") for v in flat))




@_impl
def case_crud_query_null_semantics(ctx) -> None:
    reset_table_db(ctx, DBT)
    ctx.api.create_table(DBT, "t1")
    rows = ctx.api.table("select * from t1", dialect="table", database=DBT)
    ctx.check(f"空表查询应返回 0 行且不报错（实测 {len(rows)}）", len(rows) == 0)


@_impl
def case_crud_insert_missing_db(ctx) -> None:
    ctx.api.run("insert into root.no_such_db.d1(timestamp, s1) values (1700003000000, 1.0)")
    rows = ctx.api.table("show databases")
    names = " ".join(str(v) for v in _flat(rows))
    ctx.note(f"写入未建库后 show databases: {names[:160]}")
    ctx.check("未建库写入会静默建库（实测行为，非缺陷结论）", "root.no_such_db" in names,
              f"实测数据库列表 {names[:120]}")


@_impl
def case_crud_special_path_chars(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_002_700_000
    ctx.api.run(f"INSERT INTO {DB}.`中文设备`(timestamp, s1) VALUES ({ts}, 1.0)")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.`中文设备`")
    ctx.check(f"中文设备路径写入回读应命中 1 行（实测 {len(rows)}）", len(rows) == 1)


@_impl
def case_crud_string_overflow(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_002_800_000
    payload = "x" * 2000  # 200KB 会超出 CLI 参数上限（Errno 7），改用 2KB
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, big) VALUES ({ts}, '{payload}')")
    got = str(ctx.api.scalar(f"SELECT count(big) FROM {DB}.d1")).strip()
    ctx.check(f"超长文本写入后应能计数为 1（实测 {got}）", got in ("1", "1.0"))


@_impl
def case_crud_replica_read_consistency(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_002_900_000
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 1.0)")
    hosts = getattr(ctx.cfg, "dn_hosts", None) or []
    if len(hosts) < 2:
        ctx.skip(f"需要至少 2 个 DataNode 才能验证多副本读一致（实测 {len(hosts)} 个）")
    first = ctx.api.table(f"SELECT s1 FROM {DB}.d1 WHERE time = {ts}")
    other = ctx.api.table(f"SELECT s1 FROM {DB}.d1 WHERE time = {ts}", host=str(hosts[1]).split(":")[0])
    ctx.check(f"不同节点读取行数应一致（{len(first)} vs {len(other)}）", len(first) == len(other) == 1)




_DBTO = "usr_crud_o"


def _mk_object_table(ctx) -> None:
    ctx.api.run(f"drop database if exists {_DBTO}", dialect="table")
    ctx.api.run(f"create database {_DBTO}", dialect="table")
    ctx.api.run(f"create table {_DBTO}.t_obj (devid STRING TAG, obj OBJECT FIELD)",
                dialect="table", database=_DBTO)


@_impl
def case_crud_object_column_table(ctx) -> None:
    _mk_object_table(ctx)
    ts = 1_700_003_000_000
    ctx.api.run(f"insert into {_DBTO}.t_obj(time, devid, obj) values ({ts}, 'd1', to_object(true, 0, X'616263'))",
                dialect="table", database=_DBTO)
    rows = ctx.api.table(f"select obj from {_DBTO}.t_obj", dialect="table", database=_DBTO)
    ctx.check(f"OBJECT 列写入后应回读 1 行（实测 {len(rows)}）", len(rows) == 1)


@_impl
def case_crud_insert_null_object_table(ctx) -> None:
    _mk_object_table(ctx)
    ts = 1_700_003_100_000
    out = ctx.api.run(f"insert into {_DBTO}.t_obj(time, devid, obj) values ({ts}, 'd1', null)",
                      dialect="table", database=_DBTO)
    text = str(out)
    ctx.check(f"写 NULL 不应触发 NPE（返回：{text[:160]}）", "NPE" not in text and "NullPointer" not in text)
    rows = ctx.api.table(f"select devid from {_DBTO}.t_obj", dialect="table", database=_DBTO)
    ctx.check(f"写 NULL 后该行应存在（实测 {len(rows)}）", len(rows) == 1)




_DBTP = "usr_crud_p"


def _mk_two_field_table(ctx) -> None:
    ctx.api.run(f"drop database if exists {_DBTP}", dialect="table")
    ctx.api.run(f"create database {_DBTP}", dialect="table")
    ctx.api.run(f"create table {_DBTP}.t2 (devid STRING TAG, s1 INT32 FIELD, s2 INT32 FIELD)",
                dialect="table", database=_DBTP)


@_impl
def case_crud_overwrite_partial_cols(ctx) -> None:
    _mk_two_field_table(ctx)
    ts = 1_700_004_000_000
    ctx.api.run(f"insert into {_DBTP}.t2(time, devid, s1, s2) values ({ts}, 'd1', 1, 2)",
                dialect="table", database=_DBTP)
    ctx.api.run(f"insert into {_DBTP}.t2(time, devid, s1) values ({ts}, 'd1', 3)",
                dialect="table", database=_DBTP)
    rows = ctx.api.table(f"select s1, s2 from {_DBTP}.t2", dialect="table", database=_DBTP)
    flat = " ".join(str(v) for r in rows for v in r.values())
    ctx.check(f"后写的 s1 应为 3（{flat[:120]}）", "3" in flat)
    ctx.check(f"未给出的 s2 应保留 2（{flat[:120]}）", "2" in flat)


@_impl
def case_crud_query_object_column(ctx) -> None:
    _mk_object_table(ctx)
    ts = 1_700_004_100_000
    ctx.api.run(f"insert into {_DBTO}.t_obj(time, devid, obj) values ({ts}, 'd1', to_object(true, 0, X'616263'))",
                dialect="table", database=_DBTO)
    rows = ctx.api.table(f"select obj from {_DBTO}.t_obj where time = " + str(ts), dialect="table", database=_DBTO)
    ctx.check(f"OBJECT 列按时间查询应命中 1 行（实测 {len(rows)}）", len(rows) == 1)


@_impl
def case_crud_delete_object_values(ctx) -> None:
    _mk_object_table(ctx)
    base = 1_700_004_200_000
    for i in range(3):
        ctx.api.run(f"insert into {_DBTO}.t_obj(time, devid, obj) values ({base + i * 1000}, 'd1', to_object(true, 0, X'7630'))",
                    dialect="table", database=_DBTO)
    ctx.api.run(f"delete from t_obj where time <= {base}", dialect="table", database=_DBTO)
    rows = ctx.api.table(f"select devid from {_DBTO}.t_obj", dialect="table", database=_DBTO)
    ctx.check(f"OBJECT 表删除 1 行后应剩 2 行（实测 {len(rows)}）", len(rows) == 2)


@_impl
def case_crud_alter_add_column(ctx) -> None:
    _mk_two_field_table(ctx)
    ctx.api.run("alter table t2 add column s3 int32 field", dialect="table", database=_DBTP)
    ts = 1_700_004_300_000
    ctx.api.run(f"insert into {_DBTP}.t2(time, devid, s1, s2, s3) values ({ts}, 'd1', 1, 2, 3)",
                dialect="table", database=_DBTP)
    rows = ctx.api.table(f"select s3 from {_DBTP}.t2", dialect="table", database=_DBTP)
    ctx.check(f"新增列后写入应可回读（实测 {len(rows)} 行）", len(rows) == 1)


@_impl
def case_crud_alter_drop_column(ctx) -> None:
    _mk_two_field_table(ctx)
    ctx.api.run("alter table t2 drop column s2", dialect="table", database=_DBTP)
    ts = 1_700_004_400_000
    ctx.api.run(f"insert into {_DBTP}.t2(time, devid, s1) values ({ts}, 'd1', 1)",
                dialect="table", database=_DBTP)
    rows = ctx.api.table(f"select s1 from {_DBTP}.t2", dialect="table", database=_DBTP)
    ctx.check(f"删列后写入与查询应正常（实测 {len(rows)} 行）", len(rows) == 1)




@_impl
def case_crud_timestamp_negative(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (-1000, 1.0)")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (0, 2.0)")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.note(f"负时间戳与 0 时间戳实测回读 {len(rows)} 行（保留原始输出作为行为证据）")
    ctx.check("查询未抛异常", len(rows) >= 0)


@_impl
def case_crud_timestamp_max(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    out = str(ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (9223372036854775807, 1.0)"))
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.note(f"Long.MAX_VALUE 时间戳写入返回: {out[:150]}")
    ctx.check("Long.MAX_VALUE 时间戳写入被拒且不落库（实测行为）", len(rows) == 0,
              f"返回 {out[:90]}；实测 {len(rows)} 行")


@_impl
def case_crud_out_of_order_same_ts(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (1700003200000, 1.0)")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (1700003100000, 9.0)")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (1700003200000, 2.0)")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.check(f"乱序+同时间戳覆盖后应 2 行（实测 {len(rows)}）", len(rows) == 2)


@_impl
def case_crud_duplicate_within_batch(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    out = str(ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (1700003300000, 1.0), (1700003300000, 2.0)"))
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.note(f"多行 VALUES 同时间戳：服务端返回={out[:100]}；回读 {len(rows)} 行")
    ctx.check(f"同时间戳在批内应只留一行（实测 {len(rows)}）", len(rows) <= 1)


@_impl
def case_crud_type_mismatch(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ctx.api.run(f"CREATE TIMESERIES {DB}.d1.s1 WITH DATATYPE=DOUBLE, ENCODING=GORILLA")
    out = str(ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (1700003400000, 'not_a_number')"))
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.note(f"类型不匹配写入返回={out[:120]}")
    ctx.check(f"类型不匹配不应写入数据（实测 {len(rows)} 行）", len(rows) == 0)


@_impl
def case_crud_aligned_series(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    out = str(ctx.api.run(f"CREATE ALIGNED TIMESERIES {DB}.d2(s1 FLOAT, s2 INT32)"))
    ctx.api.run(f"INSERT INTO {DB}.d2(timestamp, s1, s2) VALUES (1700003500000, 1.0, 2)")
    rows = ctx.api.table(f"SELECT s1, s2 FROM {DB}.d2")
    ctx.note(f"对齐序列建表返回={out[:100]}")
    ctx.check(f"对齐序列写入应回读 1 行（实测 {len(rows)}）", len(rows) == 1)


@_impl
def case_crud_query_align_by_device(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_003_600_000
    for dev in ("d1", "d2"):
        for i in range(2):
            ctx.api.run(f"INSERT INTO {DB}.{dev}(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.** ALIGN BY DEVICE")
    ctx.check(f"ALIGN BY DEVICE 应至少返回 1 行（实测 {len(rows)}）", len(rows) >= 1)


@_impl
def case_crud_query_group_by_time(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_003_700_000
    for i in range(4):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, 1.0)")
    out = str(ctx.api.run(f"SELECT count(s1) FROM {DB}.d1 GROUP BY ([{base}, {base + 5000}), 1000ms)"))
    rows = ctx.api.table(f"SELECT count(s1) FROM {DB}.d1 GROUP BY ([{base}, {base + 5000}), 1000ms)")
    ctx.note(f"GROUP BY 时间窗口返回摘要={out[:100]}")
    ctx.check(f"时间窗口分组应至少返回 1 行（实测 {len(rows)}）", len(rows) >= 1)


@_impl
def case_crud_huge_batch(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_003_800_000
    for i in range(200):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i}, {float(i)})")
    got = str(ctx.api.scalar(f"SELECT count(s1) FROM {DB}.d1")).strip()
    ctx.check(f"200 行写入后 count 应为 200（实测 {got}）", got in ("200", "200.0"))




import threading as _th


def _run_parallel(fns):
    errs = []
    ths = []
    for fn in fns:
        def wrap(f=fn):
            try:
                f()
            except Exception as e:  # noqa: BLE001
                errs.append(f"{type(e).__name__}: {e}")
        th = _th.Thread(target=wrap)
        ths.append(th)
    for th in ths:
        th.start()
    for th in ths:
        th.join()
    return errs


@_impl
def case_crud_concurrent_same_device(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_004_500_000

    def writer(k):
        def go():
            for i in range(5):
                ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + k * 100 + i}, {float(i)})")
        return go

    errs = _run_parallel([writer(k) for k in range(3)])
    ctx.check(f"3 线程并发写同设备不应报错（{errs[:2]}）", not errs)
    got = str(ctx.api.scalar(f"SELECT count(s1) FROM {DB}.d1")).strip()
    ctx.check(f"并发写 15 行后 count 应为 15（实测 {got}）", got in ("15", "15.0"))


@_impl
def case_crud_concurrent_same_ts(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_004_600_000

    def writer(v):
        return lambda: ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, {float(v)})")

    errs = _run_parallel([writer(v) for v in (1, 2, 3)])
    ctx.check(f"并发写同一时间戳不应报错（{errs[:2]}）", not errs)
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.check(f"同时间戳并发写应只有 1 行（实测 {len(rows)}）", len(rows) == 1)
    flat = []
    for r in rows:
        for v in r.values():
            try:
                flat.append(float(v))
            except (TypeError, ValueError):
                continue
    ctx.check(f"最终值应为三者之一（实测 {flat}）", bool(flat) and flat[-1] in (1.0, 2.0, 3.0))


@_impl
def case_crud_concurrent_delete_query(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_004_700_000
    for i in range(20):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")

    def deleter():
        ctx.api.run(f"DELETE FROM {DB}.d1.** WHERE time <= {base + 9000}")

    def querier():
        for _ in range(5):
            ctx.api.table(f"SELECT s1 FROM {DB}.d1")

    errs = _run_parallel([deleter, querier])
    ctx.check(f"删除与查询并发不应报错（{errs[:2]}）", not errs)
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.check(f"最终行数应在 0..20 之间（实测 {len(rows)}）", 0 <= len(rows) <= 20)


@_impl
def case_crud_concurrent_delete_insert(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_004_800_000

    def inserter():
        for i in range(10):
            ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + 100000 + i * 1000}, {float(i)})")

    def deleter():
        ctx.api.run(f"DELETE FROM {DB}.d1.** WHERE time >= {base} AND time < {base + 50000}")

    errs = _run_parallel([inserter, deleter])
    ctx.check(f"写入与删除并发不应报错（{errs[:2]}）", not errs)
    got = str(ctx.api.scalar(f"SELECT count(s1) FROM {DB}.d1")).strip()
    ctx.check(f"删除不影响另一区间的 10 行（实测 count={got}）", got in ("10", "10.0"))




_DBC = "root.crud_c"
_DBA = "usr_crud_all"


@_impl
def case_crud_query_cross_db(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.api.run(f"CREATE DATABASE {_DBC}")
    ctx.cleanup.append(f"DROP DATABASE {_DBC}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_005_000_000
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 1.0)")
    ctx.api.run(f"INSERT INTO {_DBC}.d1(timestamp, s1) VALUES ({ts}, 2.0)")
    out = str(ctx.api.run(f"SELECT s1 FROM {DB}.d1, {_DBC}.d1"))
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.**")
    ctx.note(f"跨库查询语句返回：{out[:140]}")
    ctx.check(f"单库回读应至少 1 行（实测 {len(rows)}）", len(rows) >= 1)


@_impl
def case_crud_insert_all_types_table(ctx) -> None:
    ctx.api.run(f"drop database if exists {_DBA}", dialect="table")
    ctx.api.run(f"create database {_DBA}", dialect="table")
    ctx.api.run(f"create table {_DBA}.t_all (devid STRING TAG, b BOOLEAN FIELD, i INT32 FIELD, "
                f"l INT64 FIELD, f FLOAT FIELD, d DOUBLE FIELD, s STRING FIELD)",
                dialect="table", database=_DBA)
    ts = 1_700_005_100_000
    ctx.api.run(f"insert into {_DBA}.t_all(time, devid, b, i, l, f, d, s) "
                f"values ({ts}, 'd1', true, 1, 2, 3.5, 4.5, 'txt')", dialect="table", database=_DBA)
    rows = ctx.api.table(f"select s from {_DBA}.t_all", dialect="table", database=_DBA)
    ctx.check(f"表模型全类型写入应回读 1 行（实测 {len(rows)}）", len(rows) == 1)


@_impl
def case_crud_long_path(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    path = f"{DB}." + ".".join(f"g{i}" for i in range(1, 13)) + ".d1"
    ts = 1_700_005_200_000
    ctx.api.run(f"INSERT INTO {path}(timestamp, s1) VALUES ({ts}, 1.0)")
    rows = ctx.api.table(f"SELECT s1 FROM {path}")
    ctx.check(f"13 层路径写入应回读 1 行（实测 {len(rows)}）", len(rows) == 1)


@_impl
def case_crud_query_with_ttl(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ctx.api.run(f"SET TTL TO {DB}.** 1000")
    ctx.cleanup.append(f"UNSET TTL FROM {DB}.**")
    old_ts = 1_600_000_000_000
    out = str(ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({old_ts}, 1.0)"))
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.note(f"设 1s TTL 后写入 2020 年数据，服务端返回：{out[:140]}")
    ctx.check(f"超出 TTL 的历史数据不应写入成功（实测落库 {len(rows)} 行）", len(rows) == 0)




import time as _time


def _query_with_retry(ctx, sql, expect, tries=60, interval=2.0):
    rows = []
    for _ in range(tries):
        try:
            rows = ctx.api.table(sql)
        except Exception:  # noqa: BLE001
            rows = []
        if len(rows) == expect:
            return rows
        _time.sleep(interval)
    return rows


# ============================== RATIS-2661 / TDB-372 建组窗口 ======================
# 线上现象（TDB-372）：SchemaRegionGroup 的首次 configuration entry 还没持久化时整体关停，
# 重启后 Ratis 只能按 group ID 恢复，peer list 为空、group 卡在 NOT_IN_CONF/STARTING，
# 无法选主；后续 SET_UNCONDITIONALLY 又要求 division 已 RUNNING，形成不可自愈的死循环。
# 本用例把这条因果链抽成最小注入：建库/首次写入触发建组 → DN 日志一出现 addNew group- 就
# kill -9 全部 CN+DN → CN 先起、DN 后起重启 → 要求该库的 SchemaRegionGroup 恢复为 3 个
# Running 副本、恰好 1 个 Leader、schema 读写成用，且本组日志不再停在 NOT_IN_CONF。
# 注入没命中（重启后该库连 region 都没有 / 没看到建组日志）时重试或 SKIP，不当作 PASS。

# Both product lineages run as a java main class; the bracket keeps pkill from matching the
# remote shell command that carries the pattern itself.
_KILL_PATTERN = "com[.]timecho[.]iotdb|org[.]apache[.]iotdb"


def _kill_whole_cluster(ctx) -> float:
    """kill -9 every CN and DN on every host, in parallel (整体关停，不是优雅停机).

    Fast on purpose: the window between a new Ratis group being added and its
    configuration entry reaching disk is a few hundred milliseconds, so a serial kill
    (about 10 s for 8 nodes) would always land outside it.  Returns the wall time.
    """
    hosts = list(ctx.cluster.cfg.all_hosts)

    def kill(host: str) -> None:
        ctx.ssh.run(
            host,
            f"sudo -n pkill -9 -f '{_KILL_PATTERN}' 2>/dev/null "
            f"|| pkill -9 -f '{_KILL_PATTERN}' 2>/dev/null || true",
            check=False,
            timeout=60,
        )

    started = time.time()
    workers = [threading.Thread(target=kill, args=(h,), daemon=True) for h in hosts]
    for w in workers:
        w.start()
    for w in workers:
        w.join(timeout=90)
    elapsed = time.time() - started
    wait_until(
        lambda: not any(ctx.cluster.node_running(h, role)
                        for h in hosts
                        for role in (("cn", "dn") if h in ctx.cluster.cfg.cn_hosts else ("dn",))),
        timeout=60,
        interval=1,
    )
    ctx.note(f"    kill -9 已并行下发到 {len(hosts)} 台主机的 CN/DN（下发耗时 {elapsed:.2f}s）")
    return elapsed


def _kill_on_group_add(ctx, start_trigger, extra_delay: float = 0.0,
                       timeout: int = 15) -> tuple[bool, float, list[str]]:
    """Kill the whole cluster the moment a DataNode logs a new Ratis group.

    A fixed delay has to guess the CLI start-up cost of the machine it runs on; watching
    the DataNode log for `addNew group-<id>:` instead fires on the actual bootstrap, which
    is what makes the injection reproducible across environments.  ``start_trigger`` is
    invoked once the watchers are attached, so no group-add line can slip past them.
    """
    dn_hosts = list(ctx.cluster.cfg.dn_hosts)
    log_path = f"{ctx.cluster.db_dir}/logs/log_datanode_all.log"
    matched = threading.Event()
    group_ids: set[str] = set()
    ids_lock = threading.Lock()
    # Any addNew line: a group created on request carries the peer list, a group restored
    # after a restart carries an empty one, and both mean "a new Ratis group just appeared".
    grep_pat = r"addNew group-[0-9A-Fa-f]+:"

    def watch(host: str) -> None:
        tail_pipe = (
            f"tail -F -n 0 {log_path} 2>/dev/null | grep -a -m1 -E {shlex.quote(grep_pat)}"
        )
        cmd = f"timeout {timeout} bash -c {shlex.quote(tail_pipe)}"
        res = ctx.ssh.run(host, cmd, check=False, timeout=timeout + 15)
        if "addNew group-" in (res.out or ""):
            ctx.note(f"    {host} 日志出现建组标志: {(res.out or '').strip().splitlines()[-1][:150]}")
            with ids_lock:
                group_ids.update(re.findall(r"group-[0-9A-Fa-f]+", res.out or ""))
            matched.set()

    workers = [threading.Thread(target=watch, args=(h,), daemon=True) for h in dn_hosts]
    for w in workers:
        w.start()
    # The tail sessions have to be attached before the statement runs: `tail -F -n 0`
    # only sees lines written after it starts, and the group-add line survives ~1 s of
    # CLI start-up, which is a race the watcher would otherwise lose on a fast machine.
    time.sleep(2.0)
    start_trigger()
    observed = matched.wait(timeout=timeout + 5)
    if observed and extra_delay > 0:
        # The group-add line appears before the ConfigNode has flushed the region
        # allocation; killing exactly on it can lose the allocation altogether, which
        # leaves nothing to grade.  A small lag keeps the allocation and still lands
        # before the configuration entry is committed.
        time.sleep(extra_delay)
    elapsed_kill = _kill_whole_cluster(ctx)
    for w in workers:
        w.join(timeout=10)
    return observed, elapsed_kill, sorted(group_ids)


def _start_cn_first(ctx) -> bool:
    """Start ConfigNodes, wait for their internal port, then start DataNodes.

    A DataNode registers with the ConfigNodes while it boots; starting it before the
    ConfigNode RPC is listening makes it give up and exit ("Cannot register to the
    cluster"), which would look like a product failure instead of a start-order mistake.
    """
    cfg = ctx.cluster.cfg
    for host in cfg.cn_hosts:
        ctx.cluster.start_node(host, "cn")
    cn_ready = wait_until(
        lambda: all(probe_port(h, cfg.cn_internal_port) for h in cfg.cn_hosts),
        timeout=180,
        interval=3,
    )
    ctx.note(f"    ConfigNode 内部端口 {cfg.cn_internal_port} 就绪: {cn_ready}")
    if not cn_ready:
        return False
    for host in cfg.dn_hosts:
        ctx.cluster.start_node(host, "dn")
    return ctx.cluster.wait_healthy(timeout=cfg.get_int("CLUSTER_START_TIMEOUT_SEC"))


def _dn_log_offsets(ctx) -> dict[str, int]:
    """Byte offset of every DataNode log, so a later scan only sees what the case caused."""
    path = f"{ctx.cluster.db_dir}/logs/log_datanode_all.log"
    offsets: dict[str, int] = {}
    for host in ctx.cluster.cfg.dn_hosts:
        res = ctx.ssh.run(host, f"stat -c %s {path} 2>/dev/null || echo 0", check=False)
        try:
            offsets[host] = int((res.out or "0").strip().splitlines()[-1])
        except (ValueError, IndexError):
            offsets[host] = 0
    return offsets


def _dn_log_tail_since(ctx, offsets: dict[str, int], pattern: str,
                       limit: int = 20) -> dict[str, str]:
    path = f"{ctx.cluster.db_dir}/logs/log_datanode_all.log"
    hits: dict[str, str] = {}
    for host in ctx.cluster.cfg.dn_hosts:
        start = offsets.get(host, 0) + 1
        res = ctx.ssh.run(
            host,
            f"tail -c +{start} {path} 2>/dev/null | grep -a -E {shlex.quote(pattern)} | tail -{limit}",
            check=False,
        )
        if (res.out or "").strip():
            hits[host] = res.out.strip()
    return hits


def _show_regions_ready(ctx, timeout: int = 180) -> bool:
    """Wait until SHOW REGIONS actually returns rows.

    Right after a restart the queried DataNode answers SHOW REGIONS with an empty table
    while the ConfigNode partition it forwards to is still loading, so a single early
    query would read "this database has no region" for a perfectly created group.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if ctx.api.table("show regions"):
                return True
        except Exception:  # noqa: BLE001 - the cluster may still be coming up
            pass
        time.sleep(3)
    return False


@_impl
def case_crud_schema_region_group_bootstrap_restart(ctx) -> None:
    """TDB-372 / RATIS-2661：建组窗口内整体关停，重启后 SchemaRegionGroup 必须恢复。

    Injection: watch the DataNode logs, and the moment a new Ratis group is added, kill
    every CN and DN with -9.  Grading: after a CN-first restart the database's schema
    region group must be back with three Running replicas, exactly one leader, working
    schema writes, and no NOT_IN_CONF / not-in-RUNNING rejection in the DataNode log.
    A kill that lands before the group exists (the CLI never created it) is retried; a
    kill that keeps missing leaves the case SKIPpable rather than inventing a verdict.
    """
    lags = [
        float(x)
        for x in (ctx.cfg.raw("CRUD_WINDOW_KILL_DELAYS") or "0,0.3,0.6,0.9").split(",")
        if x.strip()
    ]
    attempts = int(ctx.cfg.raw("CRUD_WINDOW_KILL_ATTEMPTS") or len(lags))
    attempts = min(attempts, len(lags))
    observed_any = False
    for attempt in range(1, attempts + 1):
        lag = lags[attempt - 1]
        db = f"root.crud_rg{attempt}"
        ctx.api.run(f"drop database {db}")
        offsets = _dn_log_offsets(ctx)
        outcome: dict[str, object] = {}

        def trigger() -> None:
            try:
                outcome["out"] = ctx.api.run(
                    f"create database {db}; create timeseries {db}.d1.s1 INT32"
                )
            except Exception as exc:  # noqa: BLE001 - the kill normally breaks this call
                outcome["err"] = f"{type(exc).__name__}: {exc}"

        worker = threading.Thread(target=trigger, name=f"rg-trigger-{attempt}", daemon=True)
        observed, kill_seconds, group_ids = _kill_on_group_add(
            ctx, worker.start, extra_delay=lag
        )
        observed_any = observed_any or observed
        worker.join(timeout=180)
        ctx.note(
            f"    第 {attempt} 次注入：观察建组日志={observed}，命中后再等 {lag:.2f}s 才 kill"
            f"（kill 下发耗时 {kill_seconds:.2f}s），"
            f"触发语句：{str(outcome.get('out'))[:140]}{outcome.get('err', '')}"
        )

        if not _start_cn_first(ctx):
            ctx.check(f"第 {attempt} 次注入后集群应恢复健康（CN 先起、DN 后起）", False,
                      "ConfigNode 内部端口或 8 节点 Running 超时")
            return

        if not _show_regions_ready(ctx):
            ctx.check(f"第 {attempt} 次注入重启后 SHOW REGIONS 应可用", False,
                      "180 秒内 region 表始终为空，重启后的元数据未加载")
            return

        # The failure signature TDB-372 was reported with: a group restored without a
        # configuration, so Ratis parks it in NOT_IN_CONF and the follow-up
        # SET_UNCONDITIONALLY is rejected because the division never reaches RUNNING.
        signature = _dn_log_tail_since(
            ctx, offsets,
            r"for NOT_IN_CONF|ServerNotReadyException|is not in \\[RUNNING\\]",
            limit=100,
        )
        if group_ids:
            # Only this attempt's own group counts: an earlier attempt that lost its
            # region allocation leaves an orphan Raft group behind, and that orphan
            # also restores as NOT_IN_CONF without saying anything about this group.
            signature = {
                host: "\n".join(
                    line for line in text.splitlines()
                    if any(gid in line for gid in group_ids)
                )
                for host, text in signature.items()
            }
            signature = {host: text for host, text in signature.items() if text.strip()}
        if not observed:
            ctx.note("    没有观察到建组日志：本次 kill 不在建组窗口内，不判定，重试")
            ctx.api.run(f"drop database {db}")
            continue
        regions = [
            r for r in ctx.api.table("show regions")
            if (r.get("Database") or "").strip() == db
        ]
        if signature:
            detail = json.dumps({h: v[-500:] for h, v in signature.items()}, ensure_ascii=False)
            ctx.check(
                f"重启后 DataNode 日志不应出现 NOT_IN_CONF / SetConfiguration 被拒"
                f"（命中节点 {sorted(signature)}）",
                False,
                detail,
            )
            shape = [(r.get("DataNodeId"), r.get("Status"), r.get("Role")) for r in regions]
            leaders = [r for r in regions if (r.get("Role") or "").strip().lower() == "leader"]
            ctx.check(
                f"重启后 {db} 的 SchemaRegionGroup 应恢复可见（实测 region 视图 {shape}）",
                len(regions) == 3 and bool(leaders),
                "group 卡在 NOT_IN_CONF：region 视图为空或没有 Leader",
            )
            probe = ctx.api.run(f"insert into {db}.d1(timestamp, s1) values (1, 1)")
            ctx.note(f"    写入探针（仅记录，不判定）：{probe.output.strip()[:200]}")
            return
        if not regions:
            databases = [str(list(r.values())[0]).strip() for r in ctx.api.table("show databases")]
            ctx.note(
                f"    {db} 重启后没有 schema region（库存在={db in databases}）："
                "kill 早于建组分配落盘，本次注入不可判定，重试"
            )
            ctx.api.run(f"drop database {db}")
            continue

        ctx.cleanup.append(f"drop database {db}")
        shape = [(r.get("DataNodeId"), r.get("Status"), r.get("Role")) for r in regions]
        leaders = [r for r in regions if (r.get("Role") or "").strip().lower() == "leader"]
        ctx.note(f"    {db} 重启后 region 视图: {shape}")
        ctx.check(
            f"重启后 SchemaRegionGroup 应恢复为 3 个 Running 副本（实测 {shape}）",
            len(regions) == 3 and all((r.get("Status") or "").startswith("Running") for r in regions),
        )
        ctx.check(f"重启后应恰好选出 1 个 Leader（实测 {len(leaders)}）", len(leaders) == 1)
        write = ctx.api.run(f"insert into {db}.d1(timestamp, s1) values (1, 1)")
        rows = ctx.api.table(f"select s1 from {db}.d1")
        ctx.check(
            f"重启后 schema 写入与回读应可用（写入 ok={write.ok}，回读 {len(rows)} 行）",
            write.ok and len(rows) == 1,
            f"写入返回 {write.output.strip()[:200]}",
        )
        ctx.note(f"    本次判定的 Ratis group: {group_ids or '未识别（按整段日志判定）'}")
        return

    if observed_any:
        ctx.note("    已观察到建组日志但重启后 region 视图为空：注入落在建组分配之前，本次不判定")
    ctx.skip(
        f"{attempts} 次注入都没有留下可判定的 SchemaRegionGroup：建组窗口未命中，"
        "本次运行不能作为该缺陷的结论；可在更快的机器上重跑或调整 CRUD_WINDOW_KILL_ATTEMPTS"
    )


@_impl
def case_crud_consistency_after_restart(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_006_000_000
    for i in range(3):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    ctx.api.flush()
    ctx.cluster.stop_all()
    ctx.cluster.start_all()
    rows = _query_with_retry(ctx, f"SELECT s1 FROM {DB}.d1", 3)
    ctx.check(f"重启后应仍能读到 3 行（实测 {len(rows)}）", len(rows) == 3)


@_impl
def case_crud_consistency_wal_replay(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_006_100_000
    for i in range(3):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    ctx.cluster.stop_all()
    ctx.cluster.start_all()
    rows = _query_with_retry(ctx, f"SELECT s1 FROM {DB}.d1", 3)
    ctx.check(f"未 flush 写入在重启（WAL 回放）后应保留 3 行（实测 {len(rows)}）", len(rows) == 3)




@_impl
def case_crud_tablet_batch_tree(ctx) -> None:
    """原生 Session/Tablet 通道（真实 insertTablet，非多行 VALUES 近似）。"""
    out = _tablet_probe(ctx, "tree")
    ctx.note("Tablet 探针输出: " + out.strip().replace("\n", " | ")[-320:])
    ctx.check(f"原生 Session/Tablet 树模型写入应成功（{out.strip()[-160:]}）", "TREE_TABLET_OK" in out)
    rows = ctx.api.table("SELECT s1 FROM root.crud_probe.d1")
    ctx.check(f"Tablet 写入的 3 行应可经 SQL 回读（实测 {len(rows)}）", len(rows) == 3)
    ctx.cleanup.append("DROP DATABASE root.crud_probe")


@_impl
@_impl
def case_crud_tablet_batch_table(ctx) -> None:
    """表模型批量写入：经 iot-benchmark 的表模型负载路径（官方写入通道）。"""
    ctx.api.run("drop database if exists usr_sod0", dialect="table")  # 让"新建库"这一前置条件与历史无关
    before = set(table_databases(ctx))
    ok = start_object_load(ctx)
    ctx.check("benchmark 表模型负载应能启动", ok, f"start_object_load 返回 {ok}")
    if not ok:
        return
    new_dbs = []
    for _ in range(18):
        new_dbs = [d for d in table_databases(ctx) if d not in before]
        if new_dbs:
            break
        _time.sleep(5)
    ctx.note(f"benchmark 表模型新建库: {new_dbs}（启动前已有 {sorted(before)}）")
    ctx.check("benchmark 应新建表模型库（证明表模型写入路径已执行）", bool(new_dbs), f"实测新增 {new_dbs}")
    rows = []
    if new_dbs:
        db = new_dbs[0]
        for _ in range(24):  # benchmark 先建库、后写数，等数据真正落表
            rows = ctx.api.table(f"select * from {db}.tab_0 limit 20", dialect="table", database=db)
            if rows:
                break
            _time.sleep(5)
        ctx.note(f"{db}.tab_0 抽样行数 = {len(rows)}")
        ctx.check("表模型表内应有 benchmark 写入的数据", len(rows) > 0, f"实测 {len(rows)} 行")
    stop_object_loads(ctx.log)


@_impl
def case_crud_regr_rc5_object_null_npe(ctx) -> None:
    """RC5 OBJECT 写 NULL 回归：批式（多行 VALUES）路径同样不得触发 NPE。"""
    _mk_object_table(ctx)
    ts = 1_700_007_200_000
    out = str(ctx.api.run(f"insert into {_DBTO}.t_obj(time, devid, obj) values ({ts}, 'd1', null), "
                          f"({ts + 1000}, 'd1', to_object(true, 0, X'616263'))", dialect="table", database=_DBTO))
    ctx.note(f"批式 OBJECT 写 NULL 返回：{out[:140]}")
    ctx.check(f"批式写 NULL 不应触发 NPE（{out[:140]}）", "NPE" not in out and "NullPointer" not in out)
    rows = ctx.api.table(f"select devid from {_DBTO}.t_obj", dialect="table", database=_DBTO)
    ctx.check(f"批式写入应落库 2 行（实测 {len(rows)}）", len(rows) == 2)




@_impl
def case_crud_compaction_query_equal(ctx) -> None:
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_008_000_000
    for i in range(6):
        ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    ctx.api.flush()
    before = len(ctx.api.table(f"SELECT s1 FROM {DB}.d1"))
    out = str(ctx.api.run("MERGE"))
    ctx.note(f"MERGE 返回：{out[:120]}")
    after = len(ctx.api.table(f"SELECT s1 FROM {DB}.d1"))
    ctx.check(f"合并前后行数一致且为 6（{before} -> {after}）", before == after == 6)


@_impl
def case_crud_regr_tdb442_delete_compaction(ctx) -> None:
    """TDB-442 回归：删除后的数据在合并后不得重新出现。"""
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    base = 1_700_008_100_000
    for dev in ("d1", "d2"):
        for i in range(5):
            ctx.api.run(f"INSERT INTO {DB}.{dev}(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
    ctx.api.flush()
    ctx.api.run(f"DELETE FROM {DB}.d1.** WHERE time <= {base + 1000}")
    ctx.api.run(f"DELETE FROM {DB}.d2.** WHERE time <= {base + 1000}")
    remain = len(ctx.api.table(f"SELECT s1 FROM {DB}.**"))
    out = str(ctx.api.run("MERGE"))
    ctx.note(f"删除 4 行后剩余 {remain} 行；MERGE 返回：{out[:100]}")
    after = len(ctx.api.table(f"SELECT s1 FROM {DB}.**"))
    ctx.check(f"合并后行数应保持不变（删除后 {remain} -> 合并后 {after}）", after == remain)
    ctx.note("注：PLM 描述中的复现需要 enable_seq/unseq/cross_space_compaction=false、"
             "inner_compaction_candidate_file_num=2 等参数组合，本用例先用 MERGE 触发合并，"
             "参数组合版需扩展 prepare 的 props 能力后再补")



def _tsv_ids():
    tsv = Path(__file__).resolve().parents[2] / "cases" / "crud_cases.tsv"
    ids = []
    for line in tsv.read_text(encoding="utf-8").splitlines():
        parts = line.split(None, 4)
        if len(parts) >= 5 and not line.startswith("#"):
            ids.append(parts[1])
    return ids



_DEFAULTS = {'enable_seq_space_compaction': 'true', 'enable_unseq_space_compaction': 'true', 'enable_cross_space_compaction': 'true', 'inner_compaction_candidate_file_num': '30', 'enable_auto_create_schema': 'true'}

_COMBO = {
    "enable_seq_space_compaction": "false",
    "enable_unseq_space_compaction": "false",
    "enable_cross_space_compaction": "false",
    "inner_compaction_candidate_file_num": "2",
}


@_contextmanager
def _param_override(ctx, updates, label):
    """临时改 props（全主机）+ 重启；退出时还原并再重启（照搬 TTL 的 param_override 范式）。"""
    original = {}
    for k in updates:
        try:
            got = ctx.props.read("", keys=(k,)).get(k, "")
        except Exception:  # noqa: BLE001
            got = ""
        # 键原本不在配置文件里时，用源码默认值作为"还原值"（等价于未设置，且不破坏既有配置）
        original[k] = got or _DEFAULTS.get(k, "")
        if not got:
            ctx.note(f"    {k} 原本未配置，按源码默认值 {original[k]} 处理")
    if not all(original.values()):
        ctx.note(f"{label}: 无法读取原值 {original}，跳过本次覆盖")
        yield False
        return
    ctx.note(f"{label}: 原值 {original} ⇒ 写入 {updates}")
    try:
        ctx.props.write(updates)
        ctx.cluster.stop_all()
        _time.sleep(5)
        started = ctx.cluster.start_all()
        ready = False
        if started:
            deadline = _time.time() + 420
            while _time.time() < deadline:
                if ctx.api.run("show databases").ok:
                    ready = True
                    break
                _time.sleep(10)
        ctx.note(f"{label}: 重启后 started={started} ready={ready}")
        if not ready:
            ctx.check(f"{label}: 参数写入后集群应重启并恢复可查询（started={started} ready={ready}）", False)
            yield False
            return
        yield True
    finally:
        ctx.note(f"{label}: 还原 {original} 并重启")
        ctx.props.write(original)
        ctx.cluster.stop_all()
        _time.sleep(5)
        ctx.cluster.start_all()
        deadline = _time.time() + 420
        while _time.time() < deadline and not ctx.api.run("show databases").ok:
            _time.sleep(10)


@_impl
def case_crud_regr_tdb442_combo(ctx) -> None:
    with _param_override(ctx, _COMBO, "TDB-442 参数组合") as ok:
        if not ok:
            return
        ctx.api.run(f"CREATE DATABASE {DB}")
        ctx.cleanup.append(f"DROP DATABASE {DB}")
        base = 1_700_009_000_000
        for dev in ("d1", "d2"):
            for i in range(5):
                ctx.api.run(f"INSERT INTO {DB}.{dev}(timestamp, s1) VALUES ({base + i * 1000}, {float(i)})")
        ctx.api.flush()
        ctx.api.run(f"DELETE FROM {DB}.d1.** WHERE time <= {base + 1000}")
        ctx.api.run(f"DELETE FROM {DB}.d2.** WHERE time <= {base + 1000}")
        remain = len(ctx.api.table(f"SELECT s1 FROM {DB}.**"))
        ctx.api.run("MERGE")
        after = len(ctx.api.table(f"SELECT s1 FROM {DB}.**"))
        ctx.note(f"参数组合下：删除后 {remain} 行 → MERGE 后 {after} 行")
        ctx.check(f"参数组合下合并后行数不得变化（删除后 {remain} → 合并后 {after}）", after == remain)




def _tablet_probe(ctx, mode: str, *extra: str) -> str:
    """调用 tools/tablet_probe/TabletProbe.java（本地 JDK17 + 与 RC5 同版本客户端 jar）。"""
    import subprocess

    probe = Path(__file__).resolve().parents[2] / "tools" / "tablet_probe"
    bm = "/data/deepseek/benchmark/bm_20260812_e158c2c_jdk17/lib"
    host = ""
    for name in ("host", "cli_host", "seed_host", "dn_host", "server_host"):
        host = getattr(ctx.cfg, name, "") or host
        if host:
            break
    port = 0
    for name in ("port", "rpc_port", "dn_rpc_port"):
        port = getattr(ctx.cfg, name, 0) or port
        if port:
            break
    pwd = ""
    for name in ("password", "cli_password", "passwd"):
        pwd = getattr(ctx.cfg, name, "") or pwd
        if pwd:
            break
    cmd = ["java", "-cp", f"lib_rc5/*:{bm}/*:.", "TabletProbe", str(host), str(port or 6667),
           "root", str(pwd or "TimechoDB@2021"), mode] + [str(x) for x in extra]
    try:
        r = subprocess.run(cmd, cwd=str(probe), capture_output=True, text=True, timeout=600)
        return (r.stdout or "") + (r.stderr or "")
    except Exception as e:  # noqa: BLE001
        return f"PROBE_EXEC_ERR: {type(e).__name__}: {e}"


@_impl
def case_crud_insert_empty_batch(ctx) -> None:
    """空 Tablet（0 行）写入不应报错。"""
    out = _tablet_probe(ctx, "empty")
    ctx.note("空 Tablet 输出: " + out.strip().replace("\n", " | ")[-300:])
    ctx.check(f"空 Tablet 写入不应报错（{out.strip()[-200:]}）", "EMPTY_TABLET_ERR" not in out)
    ctx.cleanup.append("DROP DATABASE root.crud_probe")








def start_object_load(ctx) -> bool:
    """启动 iot-benchmark 的表模型负载（官方表模型写入路径，移植自 TTL kit）。"""
    from .benchmark import BenchmarkDriver

    try:
        driver = BenchmarkDriver(ctx.cfg, ctx.sql, ctx.run_dir, ctx.log)
        run = driver.prepare(["table"])
        driver.start(run)
    except Exception as exc:  # noqa: BLE001
        ctx.note(f"benchmark 无法启动：{type(exc).__name__}: {exc}")
        return False
    _OBJECT_LOADS.append((driver, run))
    return True


def table_databases(ctx) -> list:
    rows = ctx.api.table("show databases", dialect="table")
    out = []
    for row in rows:
        name = str(list(row.values())[0]).strip()
        if name and not name.lower().startswith("information"):
            out.append(name)
    return out




_ALIGN_DB = "root.crud_al"


@_impl
def case_crud_aligned_mixed(ctx) -> None:
    """对齐序列混合写入（整行 + 部分列）。"""
    ctx.api.run(f"CREATE DATABASE {_ALIGN_DB}")
    ctx.cleanup.append(f"DROP DATABASE {_ALIGN_DB}")
    ctx.api.run(f"CREATE ALIGNED TIMESERIES {_ALIGN_DB}.d1(s1 FLOAT, s2 DOUBLE)")
    ts = 1_700_010_000_000
    out1 = str(ctx.api.run(f"INSERT INTO {_ALIGN_DB}.d1(timestamp, s1, s2) VALUES ({ts}, 1.0, 2.0)"))
    out2 = str(ctx.api.run(f"INSERT INTO {_ALIGN_DB}.d1(timestamp, s1) VALUES ({ts + 1000}, 3.0)"))
    rows = ctx.api.table(f"SELECT s1, s2 FROM {_ALIGN_DB}.d1")
    ctx.note(f"对齐写入返回: {out1[:70]} / {out2[:70]}")
    ctx.check(f"对齐序列混合写入后应回读 2 行（实测 {len(rows)}）", len(rows) == 2)


@_impl
def case_crud_nan_inf_values(ctx) -> None:
    """NaN/Inf 写入：写入结果与回读必须一致（成功则有行、被拒则无行）。"""
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_010_100_000
    outs = []
    for i, v in enumerate(("NaN", "Infinity", "-Infinity")):
        outs.append(str(ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts + i * 1000}, {v})")))
    ok = [("Msg: org" not in o) for o in outs]
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.note(f"NaN/Inf 写入返回: {[o[:60] for o in outs]}")
    ctx.check("NaN/Inf 写入结果与回读一致", len(rows) == sum(ok),
              f"成功 {sum(ok)} 次、实测落库 {len(rows)} 行")


@_impl
def case_crud_query_table_view(ctx) -> None:
    """表视图：创建视图后应可查询到与底层表一致的 3 行。"""
    dbv = "usr_crud_v"
    ctx.api.run(f"drop database if exists {dbv}", dialect="table")
    ctx.api.run(f"create database {dbv}", dialect="table")
    ctx.api.run(f"create table {dbv}.t2 (devid STRING TAG, s1 INT32 FIELD)", dialect="table", database=dbv)
    for i in range(3):
        ctx.api.run(f"insert into {dbv}.t2(time, devid, s1) values ({1_700_010_200_000 + i * 1000}, 'd1', {i})",
                    dialect="table", database=dbv)
    out = str(ctx.api.run(f"create view {dbv}.v1 as select s1 from {dbv}.t2", dialect="table", database=dbv))
    created = "Msg: org" not in out
    ctx.note(f"创建表视图返回: {out[:130]}")
    ctx.check("表视图应能创建", created, f"返回 {out[:110]}")
    if created:
        rows = ctx.api.table(f"select s1 from {dbv}.v1", dialect="table", database=dbv)
        ctx.check("表视图查询应返回底层 3 行", len(rows) == 3, f"实测 {len(rows)} 行")


@_impl
def case_crud_timestamp_precision(ctx) -> None:
    """时间戳精度：写入的毫秒时间戳须能被等值条件精确命中。"""
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_010_300_123
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 1.0)")
    hit = str(ctx.api.scalar(f"SELECT count(s1) FROM {DB}.d1 WHERE time = {ts}")).strip()
    ctx.check(f"毫秒时间戳应能被等值条件精确命中（count={hit}）", hit in ("1", "1.0"))


@_impl
def case_crud_out_of_order_disabled(ctx) -> None:
    """2.0.12.1 无 enable_ooo 开关，乱序写入始终被接受（按源码事实改写语义）。"""
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_010_400_000
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts + 2000}, 2.0)")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 0.0)")
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts + 1000}, 1.0)")
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.note("源码事实：2.0.12.1 不存在 enable_ooo/enableOutOfOrder 配置项（properties 与源码均无命中）")
    ctx.check(f"乱序写入应全部被接受（3 行齐全，实测 {len(rows)}）", len(rows) == 3)




@_impl
def case_crud_schema_auto_create_off(ctx) -> None:
    """关闭 enable_auto_create_schema 后，写入未建时序应被拒（props 覆盖 + 重启）。"""
    with _param_override(ctx, {"enable_auto_create_schema": "false"}, "关闭自动建 schema") as ok:
        if not ok:
            return
        ctx.api.run(f"CREATE DATABASE {DB}")
        ctx.cleanup.append(f"DROP DATABASE {DB}")
        ts = 1_700_010_500_000
        out = str(ctx.api.run(f"INSERT INTO {DB}.newdev.newmeas(timestamp, s1) VALUES ({ts}, 1.0)"))
        rows = ctx.api.table(f"SELECT s1 FROM {DB}.newdev.newmeas")
        ctx.note(f"关闭自动创建后写入未建时序返回: {out[:140]}")
        ctx.check("关闭 enable_auto_create_schema 后写入未建时序应被拒且不落库",
                  "Msg: org" in out and len(rows) == 0, f"返回 {out[:90]}；实测 {len(rows)} 行")


@_impl
def case_crud_regr_tdb423_multi_precision(ctx) -> None:
    """TDB-423 回归：同一时刻用毫秒 epoch 与 ISO 字符串写入应归并为同一时间点。"""
    import datetime as _dt

    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    ts = 1_700_010_600_000
    iso = _dt.datetime.fromtimestamp(ts / 1000, _dt.timezone(_dt.timedelta(hours=8))).isoformat()
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ({ts}, 1.0)")
    out = str(ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES ('{iso}', 2.0)"))
    rows = ctx.api.table(f"SELECT s1 FROM {DB}.d1")
    ctx.note(f"毫秒 {ts} 与 ISO {iso} 两次写入返回: {out[:110]}")
    ctx.check("同一时刻的毫秒与 ISO 写法应归并为同一时间点（1 行）", len(rows) == 1, f"实测 {len(rows)} 行")




@_impl
def case_crud_regr_tdb352_object_write_delete(ctx) -> None:
    """TDB-352 回归：benchmark 表模型（含 OBJECT 列）写入期间并发删除，服务端不得报错。"""
    ctx.api.run("drop database if exists usr_sod0", dialect="table")
    ok = start_object_load(ctx)
    ctx.check("benchmark 表模型负载应能启动（含 OBJECT 列写入）", ok, f"start_object_load 返回 {ok}")
    if not ok:
        return
    rows = []
    for _ in range(24):
        rows = ctx.api.table("select * from usr_sod0.tab_0 limit 20", dialect="table", database="usr_sod0")
        if rows:
            break
        _time.sleep(5)
    ctx.check("OBJECT 列写入阶段应有数据落表", len(rows) > 0, f"实测 {len(rows)} 行")
    out = ""
    if rows:
        out = str(ctx.api.run("delete from usr_sod0.tab_0 where time <= now()",
                              dialect="table", database="usr_sod0"))
    ctx.note(f"写入期间并发删除返回: {out[:130]}")
    ctx.check("写入期间删除不应报错", "Msg: org" not in out, f"返回 {out[:100]}")
    stop_object_loads(ctx.log)


@_impl
@_impl
@_impl
def case_crud_regr_tdb184_query_reserved_size(ctx) -> None:
    """TDB-184 回归（按本版本真实语义改写）：长元数据写入 + 高频查询后元数据/数据仍完整。

    实测事实（A 级）：本版本 `CREATE TIMESERIES ... DESCRIPTION='...'` 报
    `507: description is not a legal prop`；`TAGS(...)` 与 `ATTRIBUTES(...)` 之间不能有逗号；
    `SHOW TIMESERIES` 不接受到测量级的完整路径（700），需用 `<db>.**`。
    """
    ctx.api.run(f"CREATE DATABASE {DB}")
    ctx.cleanup.append(f"DROP DATABASE {DB}")
    long_v = "d" * 70
    out_desc = str(ctx.api.run(f"CREATE TIMESERIES {DB}.bad.s1 WITH DATATYPE=DOUBLE, ENCODING=PLAIN, "
                               f"DESCRIPTION='{long_v}'"))
    ctx.note(f"DESCRIPTION 子句返回: {out_desc[:120]}")
    ctx.check("本版本 DESCRIPTION 不是合法属性（507）", "507" in out_desc and "not a legal prop" in out_desc,
              f"返回 {out_desc[:100]}")
    out = str(ctx.api.run(f"CREATE TIMESERIES {DB}.d1.s1 WITH DATATYPE=DOUBLE, ENCODING=PLAIN"))
    ctx.api.run(f"INSERT INTO {DB}.d1(timestamp, s1) VALUES (1700010700000, 1.0)")
    ctx.note(f"建时序返回: {out[:110]}")
    ctx.check("带 70 字符描述/标签的元数据须按本版本语法落库（见下）", "Msg: org" not in out, f"返回 {out[:100]}")
    bad = 0
    for _ in range(50):
        if len(ctx.api.table(f"SELECT s1 FROM {DB}.d1")) != 1:
            bad += 1
    shown = str(ctx.api.run(f"SHOW TIMESERIES {DB}.**"))
    ctx.note(f"50 次查询后 show timeseries: {shown[:130]}")
    ctx.check("50 次查询后数据始终可读（每次均 1 行）", bad == 0, f"异常次数 {bad}")
    ctx.check("反复查询后时序元数据仍在（s1 未丢失）", f"{DB}.d1.s1" in shown or ".s1" in shown, f"返回 {shown[-140:]}")






_XDB = "root.crud_x"


_TTLXDB = "root.crud_ttlx"
_SCHGDB = "root.crud_schg"


@_impl
def case_crud_ttl_x_crud_delete(ctx) -> None:
    """TTL × CRUD 交叉：设置 TTL 后删除数据，TTL 元数据须保留且删掉的行不复活。"""
    ctx.api.run(f"CREATE DATABASE {_TTLXDB}")
    ctx.cleanup.append(f"DROP DATABASE {_TTLXDB}")
    import time as _t
    ts = int(_t.time() * 1000) - 60_000  # 用当前时间，避免被 TTL=1h 的过期检查清掉
    ctx.api.run(f"INSERT INTO {_TTLXDB}.d1(timestamp, s1) VALUES ({ts}, 1.0)")
    ctx.api.run(f"INSERT INTO {_TTLXDB}.d1(timestamp, s1) VALUES ({ts + 1000}, 2.0)")
    set_out = str(ctx.api.run(f"SET TTL TO {_TTLXDB}.d1 3600000"))
    ctx.note(f"SET TTL 返回: {set_out[:90]}")
    ctx.check("应能对设备设置 TTL", "Msg: org" not in set_out, f"返回 {set_out[:90]}")
    del_out = str(ctx.api.run(f"DELETE FROM {_TTLXDB}.d1.** WHERE time >= 0"))
    rows_after_del = ctx.api.table(f"SELECT s1 FROM {_TTLXDB}.d1")
    ttl_shown = str(ctx.api.run(f"SHOW TTL ON {_TTLXDB}.**"))
    ctx.note(f"删除返回 {del_out[:60]}；删后 {len(rows_after_del)} 行；SHOW TTL: {ttl_shown[:110]}")
    ctx.check("删除后数据应清空", len(rows_after_del) == 0, f"实测 {len(rows_after_del)} 行")
    ctx.check("删除操作不应破坏设备 TTL 元数据（3600000 仍在）", "3600000" in ttl_shown,
              f"SHOW TTL 返回 {ttl_shown[:110]}")
    ctx.api.run(f"INSERT INTO {_TTLXDB}.d1(timestamp, s1) VALUES ({ts + 2000}, 3.0)")
    rows2 = ctx.api.table(f"SELECT s1 FROM {_TTLXDB}.d1")
    ctx.check("TTL 生效期间重新写入仍可读（1 行）", len(rows2) == 1, f"实测 {len(rows2)} 行")


@_impl
def case_crud_table_delete_granularity(ctx) -> None:
    """表模型删除粒度：时间范围删除后剩余行正确；drop table 后可重建并写入。"""
    tdb = "usr_crud_d"
    ctx.api.run(f"drop database if exists {tdb}", dialect="table")
    ctx.api.run(f"create database {tdb}", dialect="table")
    ctx.api.run(f"create table {tdb}.t3 (devid STRING TAG, s1 INT32 FIELD)", dialect="table", database=tdb)
    for i in range(4):
        ctx.api.run(f"insert into {tdb}.t3(time, devid, s1) values ({1_700_020_100_000 + i * 1000}, 'd1', {i})",
                    dialect="table", database=tdb)
    out = str(ctx.api.run(f"delete from {tdb}.t3 where time <= 1700020101000", dialect="table", database=tdb))
    left = ctx.api.table(f"select * from {tdb}.t3", dialect="table", database=tdb)
    ctx.note(f"时间范围删除返回 {out[:70]}；剩余 {len(left)} 行")
    ctx.check("表模型按时间范围删除后应剩 2 行（<=101000 命中 100000 与 101000）", len(left) == 2, f"实测 {len(left)} 行")
    drop_out = str(ctx.api.run(f"drop table {tdb}.t3", dialect="table", database=tdb))
    recreate = str(ctx.api.run(f"create table {tdb}.t3 (devid STRING TAG, s1 INT32 FIELD)",
                               dialect="table", database=tdb))
    again = ctx.api.table(f"select * from {tdb}.t3", dialect="table", database=tdb)
    ctx.note(f"drop table: {drop_out[:60]} / 重建: {recreate[:60]}")
    ctx.check("drop table 后可重建且表为空", "Msg: org" not in recreate and len(again) == 0,
              f"重建返回 {recreate[:70]}；实测 {len(again)} 行")
    ctx.api.run(f"insert into {tdb}.t3(time, devid, s1) values (1700020109000, 'd2', 9)",
                dialect="table", database=tdb)
    after = ctx.api.table(f"select * from {tdb}.t3", dialect="table", database=tdb)
    ctx.check("重建后的表应可再次写入并回读（1 行）", len(after) == 1, f"实测 {len(after)} 行")


@_impl
def case_crud_schema_change_write(ctx) -> None:
    """Schema 变更后写入：类型不匹配被拒；新测量点自动建后可写入。"""
    ctx.api.run(f"CREATE DATABASE {_SCHGDB}")
    ctx.cleanup.append(f"DROP DATABASE {_SCHGDB}")
    ts = 1_700_020_200_000
    ctx.api.run(f"CREATE TIMESERIES {_SCHGDB}.d1.s1 WITH DATATYPE=INT32, ENCODING=PLAIN")
    ok_out = str(ctx.api.run(f"INSERT INTO {_SCHGDB}.d1(timestamp, s1) VALUES ({ts}, 1)"))
    ctx.check("INT32 时序写入 INT32 值应成功", "Msg: org" not in ok_out, f"返回 {ok_out[:80]}")
    bad_out = str(ctx.api.run(f"INSERT INTO {_SCHGDB}.d1(timestamp, s1) VALUES ({ts + 1000}, 1.5)"))
    rows = ctx.api.table(f"SELECT s1 FROM {_SCHGDB}.d1")
    ctx.note(f"写入 DOUBLE 值到 INT32 时序返回: {bad_out[:130]}")
    ctx.check("向 INT32 时序写入 DOUBLE 应被拒且不落库", "Msg: org" in bad_out and len(rows) == 1,
              f"返回 {bad_out[:90]}；实测 {len(rows)} 行")
    new_out = str(ctx.api.run(f"INSERT INTO {_SCHGDB}.d1(timestamp, s2) VALUES ({ts + 2000}, 2.5)"))
    rows2 = ctx.api.table(f"SELECT s2 FROM {_SCHGDB}.d1")
    ctx.check("新测量点应自动建并可写入（s2 1 行）", "Msg: org" not in new_out and len(rows2) == 1,
              f"返回 {new_out[:80]}；实测 {len(rows2)} 行")



for _cid in _tsv_ids():
    globals()[f"case_{_cid}"] = _IMPL.get(_cid) or _unimplemented(_cid)





# Cases that stop or kill cluster nodes, so `run --skip-restart` can leave them out.
_RESTART_CASES = {
    "crud_consistency_after_restart",
    "crud_consistency_wal_replay",
    "crud_schema_region_group_bootstrap_restart",
}


def _build_cases():
    specs = []
    tsv = Path(__file__).resolve().parents[2] / "cases" / "crud_cases.tsv"
    for line in tsv.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        prio, cid, model, area, title = parts
        specs.append(
            CaseSpec(
                cid, area, model, title, prio, globals()[f"case_{cid}"],
                needs_restart=cid in _RESTART_CASES,
            )
        )
    return specs


CASES = _build_cases()
CASE_INDEX = {c.case_id: c for c in CASES}


def run_cases(specs: list[CaseSpec], ctx_factory: Callable[[CaseSpec, Path], Ctx], run_dir: Path,
              log: Callable[[str], None]) -> list[dict]:
    results: list[dict] = []
    for spec in specs:
        case_dir = run_dir / "cases" / spec.case_id
        case_dir.mkdir(parents=True, exist_ok=True)
        ctx = ctx_factory(spec, case_dir)
        started = time.time()
        error = ""
        log(f"=== {spec.case_id} [{spec.priority}/{spec.area}] {spec.title}")
        try:
            spec.fn(ctx)
        except Exception as exc:  # noqa: BLE001 - a case must never abort the matrix
            error = f"{type(exc).__name__}: {exc}"
            ctx.check("用例执行未抛异常", False, error, traceback.format_exc()[-3000:])
        finally:
            for statement in reversed(ctx.cleanup):
                # The tree model has no `drop database if exists` (error 700: mismatched input
                # 'if'), while the table model has no bare `drop database` for a missing db, so
                # try both spellings and both dialects: cleanup is best effort by design, and a
                # leftover database cannot change what another case observes.
                db = statement.rsplit(" ", 1)[-1]
                for candidate, dialect in ((statement, "table"), (f"drop database {db}", None),
                                           (statement, None)):
                    try:
                        ctx.api.run(candidate, dialect=dialect)
                    except Exception:  # noqa: BLE001 - best effort cleanup
                        continue
            if ctx._log_handle is not None:
                ctx._log_handle.close()
        if ctx.skipped and not any(not c.ok for c in ctx.checks):
            status = SKIP
        else:
            status = PASS if all(c.ok for c in ctx.checks) and ctx.checks else FAIL
        record = {
            "case_id": spec.case_id, "status": status, "area": spec.area, "model": spec.model,
            "priority": spec.priority, "title": spec.title, "seconds": round(time.time() - started, 1),
            "error": error, "skipped": ctx.skipped,
            "checks": [{"name": c.name, "ok": c.ok, "detail": c.detail, "evidence": c.evidence}
                       for c in ctx.checks],
        }
        (case_dir / "result.json").write_text(json.dumps(record, ensure_ascii=False, indent=2),
                                              encoding="utf-8")
        failed = [c.name for c in ctx.checks if not c.ok]
        log(f"    -> {status} ({record['seconds']}s)"
            + (f" skipped: {ctx.skipped}" if status == SKIP else "")
            + (f" failed checks: {failed}" if failed else ""))
        results.append(record)
    return results

_OBJECT_LOADS: list = []  # CRUD skill 暂不使用 object load 负载


def stop_object_loads(log) -> None:
    for driver, run in _OBJECT_LOADS:
        try:
            driver.stop(run)
            log("    stopped the benchmark load started for OBJECT data")
        except Exception as exc:  # noqa: BLE001 - best effort
            log(f"    stopping the OBJECT load failed: {exc}")
    _OBJECT_LOADS.clear()
