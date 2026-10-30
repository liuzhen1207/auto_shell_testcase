"""TTL-specific operations on top of the vendored rcdn infrastructure.

Everything in here is about *observing and driving* TTL: the SQL surface
(set/unset/show), the property knob that controls the background TTL check,
data preparation with explicit timestamps (so expiry is deterministic instead of
waiting on wall-clock time), and the audit-log query.

Design notes that matter for trustworthy results:

* TTL expiry is decided against ``now - ttl`` per device, so a row written with an
  explicitly old timestamp is already expired the moment the TTL is set.  Every
  expiry case therefore writes its own old/new rows instead of sleeping.
* ``insert`` in both models is done over the normal CLI so what we test is exactly
  what a user would do.
* Error detection never trusts a return code alone: the CLI prints
  ``Msg: ...`` for both success and failure, so the text is inspected.
"""
from __future__ import annotations

import re
import time
import datetime
from dataclasses import dataclass, field

from .remote import SqlClient, SshRunner, looks_like_sql_error, parse_table

TREE_DIALECT = None
TABLE_DIALECT = "table"
# Name of the id column this skill creates in table-model databases.  It cannot be `id`:
# that word is part of the table grammar itself (identifier columnCategory=(ID|ATTRIBUTE)),
# and `create table t (id string id, ...)` is rejected by the parser.
TABLE_ID_COLUMN = "devid"

_CODE_RE = re.compile(r"(?:error code|code|IoTDBSQLException)[ :=]+(\d+)", re.I)
_MSG_RE = re.compile(r"^\s*Msg:\s*(.*)$", re.M)
_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}")


def to_epoch_ms(text: str) -> int | None:
    """Epoch milliseconds from a CLI Time cell.

    The CLI renders timestamps as ISO-8601 local time (``2026-10-01T07:51:10.685+08:00``)
    rather than as raw milliseconds, so comparing a rendered value against the integer that
    was inserted only works after conversion.  Plain integer text is passed through.
    """
    text = (text or "").strip()
    if not text:
        return None
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    if not _ISO_RE.match(text):
        return None
    try:
        stamp = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=datetime.timezone.utc)
    return int(stamp.timestamp() * 1000)


def normalized_key(name: str) -> str:
    """``TTL(ms)`` / ``ttl_ms`` / ``TTL`` all collapse to ``ttlms`` / ``ttl``."""
    return re.sub(r"[^a-z0-9]", "", (name or "").lower())


def cell(row: dict[str, str], *wanted: str) -> str:
    """Value of the first column matching one of ``wanted``, ignoring punctuation.

    Column headers differ between statements and releases -- ``show devices`` prints
    ``TTL(ms)`` while a table statement prints ``TTL``, and casing is not stable -- so
    looking a column up by its literal spelling silently yields an empty string, which
    then looks exactly like "the feature did not work".
    """
    table = {normalized_key(k): v for k, v in row.items()}
    for name in wanted:
        key = normalized_key(name)
        if key in table:
            return str(table[key]).strip()
    for name in wanted:
        key = normalized_key(name)
        for candidate, value in table.items():
            if key and candidate.startswith(key):
                return str(value).strip()
    return ""


@dataclass
class SqlOutcome:
    """Result of one statement: the text plus a best-effort success verdict."""

    statement: str
    output: str
    ok: bool
    detail: str = ""

    @property
    def error_code(self) -> int | None:
        hit = _CODE_RE.search(self.output)
        return int(hit.group(1)) if hit else None


@dataclass
class TtlRow:
    path: str
    ttl: str  # raw cell, so INF / multiple / null all survive

    @property
    def is_inf(self) -> bool:
        return self.ttl.strip().upper() in {"INF", "INFINITE"}


class TtlApi:
    def __init__(self, cfg, sql: SqlClient, ssh: SshRunner, log, trace=None) -> None:
        self.cfg = cfg
        self.sql = sql
        self.ssh = ssh
        self.log = log
        self.trace = trace

    # ------------------------------------------------------------------ raw SQL
    def run(self, statement: str, *, host: str | None = None, dialect: str | None = TREE_DIALECT,
            timeout: int = 300, database: str = "") -> SqlOutcome:
        """Execute one statement and classify the outcome from the text.

        The CLI takes a single ``-e`` string, so a table-model statement is preceded by
        ``use <db>;`` (table names are additionally qualified by the callers).
        """
        target = host or self.cfg.cli_host
        stmt = f"use {database}; {statement}" if database else statement
        text = self.sql.sql(target, stmt, dialect=dialect, timeout=timeout, check=False)
        failed = looks_like_sql_error(text)
        msg = ""
        hit = _MSG_RE.search(text)
        if hit:
            msg = hit.group(1).strip()
        if not failed and msg and re.search(r"(fail|error|invalid|not support|cannot|exceed|unable)",
                                            msg, re.I):
            failed = True
        if self.trace is not None:
            self.trace(statement, text)
        return SqlOutcome(statement=statement, output=text, ok=not failed, detail=msg)

    def table(self, statement: str, *, host: str | None = None, dialect: str | None = TREE_DIALECT,
              database: str = "", timeout: int = 300) -> list[dict[str, str]]:
        stmt = f"use {database}; {statement}" if database else statement
        text = self.sql.sql(host or self.cfg.cli_host, stmt, dialect=dialect, timeout=timeout,
                            check=False)
        if self.trace is not None:
            self.trace(statement, text)
        return parse_table(text)

    def must(self, statement: str, *, host: str | None = None, dialect: str | None = TREE_DIALECT,
             database: str = "", timeout: int = 300) -> SqlOutcome:
        outcome = self.run(statement, host=host, dialect=dialect, database=database, timeout=timeout)
        if not outcome.ok:
            raise AssertionError(f"statement failed: {statement}\n{outcome.output[:2000]}")
        return outcome

    def scalar(self, statement: str, *, host: str | None = None, dialect: str | None = TREE_DIALECT,
               database: str = "") -> str:
        rows = self.table(statement, host=host, dialect=dialect, database=database)
        if not rows:
            return ""
        first = rows[0]
        return str(list(first.values())[0]).strip()

    # ------------------------------------------------------------- TTL SQL verbs
    def set_ttl(self, path: str, ttl: str | int, **kw) -> SqlOutcome:
        return self.run(f"set ttl to {path} {ttl}", **kw)

    def unset_ttl(self, path: str, *, legacy: bool = False, **kw) -> SqlOutcome:
        verb = "unset ttl to" if legacy else "unset ttl from"
        return self.run(f"{verb} {path}", **kw)

    def batch(self, statements: list[str], *, chunk: int = 250, dialect: str | None = None,
              database: str = "", timeout: int = 900) -> str:
        """Run many statements in a few CLI invocations.

        Every ``start-cli.sh`` call boots a JVM (~0.5s), so the 1000-rule case would otherwise
        spend twenty minutes starting clients instead of exercising TTL.  A batch is
        fire-and-hose: the caller must confirm the effect with a query, which is also the more
        trustworthy evidence (the limit case counts ``show all ttl`` rather than trusting the
        per-statement echo).
        """
        prefix = f"use {database};\n" if database else ""
        outputs: list[str] = []
        for start in range(0, len(statements), chunk):
            group = statements[start:start + chunk]
            body = prefix + "\n".join(s.rstrip(";") + ";" for s in group)
            out = self.sql.sql(self.cfg.cli_host, body, dialect=dialect, timeout=timeout,
                               check=False)
            if self.trace is not None:
                self.trace(f"<batch {start + 1}-{start + len(group)} of {len(statements)}>", out)
            outputs.append(out)
        return "\n".join(outputs)

    def show_all_ttl(self, **kw) -> list[TtlRow]:
        # `show all ttl` prints Device|TTL(ms); the path column is called "Device", not "path".
        return [TtlRow(path=cell(r, "device", "path"), ttl=cell(r, "ttl"))
                for r in self.table("show all ttl", **kw)]

    def show_ttl_on(self, pattern: str, **kw) -> list[TtlRow]:
        return [TtlRow(path=cell(r, "device", "path"), ttl=cell(r, "ttl"))
                for r in self.table(f"show ttl on {pattern}", **kw)]

    def ttl_map(self, **kw) -> dict[str, str]:
        return {row.path: row.ttl for row in self.show_all_ttl(**kw)}

    def show_devices(self, pattern: str = "", **kw) -> list[dict[str, str]]:
        statement = f"show devices {pattern}".strip()
        return self.table(statement, **kw)

    def device_ttl(self, device: str, **kw) -> str:
        for row in self.show_devices(**kw):
            if cell(row, "device") == device:
                return cell(row, "ttl")
        return ""

    def show_tables(self, database: str = "", *, details: bool = False, **kw) -> list[dict[str, str]]:
        statement = "show tables" + (" details" if details else "")
        if database:
            statement += f" from {database}"
        return self.table(statement, dialect=TABLE_DIALECT, **kw)

    def table_ttl(self, database: str, table: str, **kw) -> str:
        for row in self.show_tables(database, **kw):
            if cell(row, "TableName") == table:
                return cell(row, "ttl")
        return ""

    # ------------------------------------------------------------------ data prep
    def create_tree_database(self, database: str, **kw) -> SqlOutcome:
        return self.run(f"create database {database}", **kw)

    def create_timeseries(self, device: str, measurements: list[str], **kw) -> SqlOutcome:
        cols = ", ".join(f"{device}.{m} with datatype=FLOAT, encoding=PLAIN, compression=SNAPPY"
                         for m in measurements)
        return self.run(f"create timeseries {cols}", **kw)

    def insert_tree(self, device: str, stamp_ms: int, measurements: list[str],
                    value: float = 1.0, **kw) -> SqlOutcome:
        cols = ", ".join(["time", *measurements])
        vals = ", ".join([str(stamp_ms), *[f"{value}" for _ in measurements]])
        return self.run(f"insert into {device}({cols}) values({vals})", **kw)

    def create_table(self, database: str, table: str, ttl: str | None = None, **kw) -> SqlOutcome:
        # Two table-model spellings that differ from the design document on this build:
        #   * the column category must be TAG or ATTRIBUTE -- `devid string id` is rejected
        #     (700: mismatched input 'id'), even though the doc grammar lists ID;
        #   * the id column cannot be called `id`, because that word is the category keyword.
        props = f" with (TTL={ttl})" if ttl is not None else ""
        return self.run(f"create table if not exists {table} ({TABLE_ID_COLUMN} string tag, s0 float)"
                        f"{props}", dialect=TABLE_DIALECT, database=database, **kw)

    def insert_table(self, database: str, table: str, row_id: str, stamp_ms: int,
                     value: float = 1.0, **kw) -> SqlOutcome:
        """Insert one row, trying the column orders a table-model release may expect."""
        attempts = (
            f"insert into {table}(time, {TABLE_ID_COLUMN}, s0) values({stamp_ms}, '{row_id}', {value})",
            f"insert into {table}({TABLE_ID_COLUMN}, time, s0) values('{row_id}', {stamp_ms}, {value})",
            f"insert into {table}(time, s0) values({stamp_ms}, {value})",
        )
        last: SqlOutcome | None = None
        for statement in attempts:
            outcome = self.run(statement, dialect=TABLE_DIALECT, database=database, **kw)
            if outcome.ok:
                if last is not None:
                    self.log(f"    insert form accepted: {statement}")
                return outcome
            last = outcome
        return last if last is not None else self.run(attempts[0], dialect=TABLE_DIALECT,
                                                      database=database, **kw)

    def flush(self, **kw) -> SqlOutcome:
        return self.run("flush", **kw)

    def count(self, statement: str, **kw) -> int:
        raw = self.scalar(statement, **kw)
        try:
            return int(float(raw))
        except ValueError:
            return -1

    def tree_row_count(self, device: str, **kw) -> int:
        return self.count(f"select count(s0) from {device}", **kw)

    def tree_visible_stamps(self, device: str, **kw) -> list[int]:
        # `select time from ...` is rejected (error 701: the time column is always returned
        # implicitly), so select a value column and convert the leading Time column, which the
        # CLI renders as ISO-8601 local time rather than as epoch milliseconds.
        rows = self.table(f"select * from {device} order by time", **kw)
        out: list[int] = []
        for row in rows:
            stamp = to_epoch_ms(cell(row, "time") or str(list(row.values())[0]))
            if stamp is not None:
                out.append(stamp)
        return out

    def table_row_count(self, database: str, table: str, **kw) -> int:
        """Visible rows of a table, whatever its columns are called.

        The cases create `s0`, but the benchmark's tables use `s_0..s_10`, so a hardcoded
        column name answers 616 "Column 's0' cannot be resolved" -- which looks like a TTL
        problem when it is only a query problem.
        """
        for statement in (f"select count(*) from {table}", f"select count(s0) from {table}"):
            value = self.count(statement, dialect=TABLE_DIALECT, database=database, **kw)
            if value >= 0:
                return value
        for row in self.table(f"desc {table}", dialect=TABLE_DIALECT, database=database, **kw):
            name = cell(row, "ColumnName")
            if name and name.lower() != "time":
                value = self.count(f"select count({name}) from {table}", dialect=TABLE_DIALECT,
                                   database=database, **kw)
                if value >= 0:
                    return value
        return -1

    # -------------------------------------------------------------------- audit
    def audit_log_rows(self, where: str = "audit_event_type LIKE '%TTL%'", **kw) -> list[dict[str, str]]:
        """Rows mentioning TTL.

        Two frictions with the design document's example query:
          * the event it introduces is FAILED_TTL_DELETION, which does not start with TTL, so
            `LIKE 'TTL%'` cannot match it -- the wide pattern is the default here;
          * `select ... from __audit.audit_log` does not even parse (700: no viable
            alternative at the table name, quoting does not help); the audit tables are only
            reachable after `use __audit`, so the statement carries that prefix.

        **Do not count rows with this method.** `select *` is truncated by the CLI at 1000 rows
        (measured: the table held 175131 rows and this method returned 1000 of them), so a
        before/after row count answers a different question than the one being asked. Use
        `audit_event_count()` / `audit_rows_since()` instead.
        """
        return self.table(f"use __audit; select * from audit_log where {where}",
                          dialect=TABLE_DIALECT, **kw)

    def audit_event_count(self, *, event_type: str = "", like: str = "",
                          since_ms: int | None = None, **kw) -> int:
        """Server-side COUNT over the audit table (never truncated client side)."""
        clauses: list[str] = []
        if event_type:
            clauses.append(f"audit_event_type = '{event_type}'")
        if like:
            clauses.append(f"audit_event_type LIKE '{like}'")
        if since_ms is not None:
            clauses.append(f"time > {int(since_ms)}")
        where = " and ".join(clauses) if clauses else "1=1"
        return self.count(f"use __audit; select count(*) from audit_log where {where}",
                          dialect=TABLE_DIALECT, **kw)

    def audit_rows_since(self, since_ms: int, where: str = "1=1", **kw) -> list[dict[str, str]]:
        """Rows written after ``since_ms`` (small result set, safe to print as evidence)."""
        return self.audit_log_rows(f"time > {int(since_ms)} and ({where})", **kw)

    def audit_ttl_event_counts(self, **kw) -> dict[str, int]:
        """How many rows each documented query pattern returns (doc-vs-implementation check)."""
        out: dict[str, int] = {}
        for pattern in ("TTL%", "%TTL%"):
            rows = self.audit_log_rows(f"audit_event_type LIKE '{pattern}'", **kw)
            out[pattern] = len(rows)
        return out

    def audit_log_available(self, **kw) -> tuple[bool, str]:
        text = self.sql.sql(self.cfg.cli_host,
                            "use __audit; select count(*) from __audit.audit_log",
                            dialect=TABLE_DIALECT, timeout=120, check=False)
        if looks_like_sql_error(text):
            return False, text.strip()[:400]
        rows = parse_table(text)
        return True, (str(list(rows[0].values())[0]) if rows else "?")


def now_ms() -> int:
    return int(time.time() * 1000)


def ago_ms(seconds: float) -> int:
    return now_ms() - int(seconds * 1000)
