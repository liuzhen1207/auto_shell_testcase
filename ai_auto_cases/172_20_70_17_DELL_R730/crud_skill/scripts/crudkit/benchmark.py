"""Driving iot-benchmark-iotdb-2.0 as the read/write load generator.

The benchmark runs on the driver machine; ``BM_HOME`` must point at an
``iot-benchmark-iotdb-2.0`` install whose ``DB_SWITCH`` understands the target
IoTDB version.

Each workload gets its own generated config directory so that the tree and the
table dialect can run at the same time against one cluster:

===============  ==============  =========================================
workload         dialect         data types
===============  ==============  =========================================
``tree``         tree            10 (BOOLEAN..DATE)
``table``        table           11 (BOOLEAN..DATE + OBJECT)
``table_view``   table           11, written through a WRITABLE VIEW
===============  ==============  =========================================
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from .config import Config, SKILL_ROOT
from .remote import SqlClient, looks_like_sql_error, parse_table

# BOOLEAN:INT32:INT64:FLOAT:DOUBLE:TEXT:STRING:BLOB:TIMESTAMP:DATE:OBJECT
TREE_DATATYPE_PROPORTION = "1:1:1:1:1:1:1:1:1:1:0"        # 10 types
TABLE_DATATYPE_PROPORTION = "1:1:1:1:1:1:1:1:1:1:1"       # 11 types, +OBJECT
# Q3/Q5/Q10 compare a sensor against a constant; OBJECT columns cannot take
# part in those predicates, so the value-filter queries are switched off.
TABLE_SAFE_OPERATION_PROPORTION = "91:1:2:0:2:0:0:1:1:2:0:0:0"
BENCHMARK_ERROR_PATTERN = re.compile(
    r"Execution fail:|Failed to do |StatementExecutionException|WorkloadException|"
    r"There is not enough memory to execute current fragment instance|Connection error"
)
# Errors that a case provokes *on purpose* and which therefore must not fail it.
# Confirmed by the database R&D: stopping or restarting the DataNode that is
# serving a statement fails that statement with 722 CANNOT_FETCH_FI_STATE; the
# state of an in-flight fragment on a dying node cannot be fetched, so this is
# the documented behaviour rather than a regression.  It is still reported --
# expected is not the same as uninteresting -- and the allowlist is a config
# knob so a tighter run can remove it.
#
# 722 reaches the client with two different texts depending on which path hit
# it, and matching only one of them silently turns this allowlist into dead
# config (measured: 0 matches out of 190 real error lines).  The two are:
#   * "Fetch Table Device Schema failed because ..."   (DataNodeQueryMessages)
#   * "Failed to fetch state, has retried N times, may be caused by DN
#      restarting."                                    (FixedRateFragInsStateTracker, MPP)
# so the status code itself is matched too: it is the identity R&D confirmed,
# and it does not depend on the phrasing.
#
# 305 "no detailed failure reason in QueryStateMachine" is the same kind of
# expected error, and R&D (2026-09-29) decided it will NOT be fixed: while a
# DataNode is recycled, an in-flight fragment dispatched to the region that is
# being deleted fails, the query retries 3x2s and then reports 305.  Waiting for
# in-flight queries before recycling the resources is the alternative, and it
# risks the REMOVE being stuck behind one large or many concurrent queries --
# judged worse than the query failure.  So it is recorded, not counted.
DEFAULT_EXPECTED_BENCH_ERRORS = (
    "Fetch Table Device Schema failed"
    "|CANNOT_FETCH_FI_STATE"
    "|Failed to fetch state, has retried"
    "|722:"
    "|305:"
)

WORKLOAD_DIALECT = {"tree": "tree", "table": "table", "table_view": "table"}
LOG_RECORD_START = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}")
# The benchmark's own summary of a statement it could not run; the real
# cause is reported separately, at the same instant.
SUMMARY_ERROR_PATTERN = re.compile(r"Execution fail:|Failed to execute\.")
SUMMARY_CORRELATION_WINDOW_SEC = 5


@dataclass
class Workload:
    name: str
    dialect: str
    db_name: str
    directory: Path
    config: Path
    log: Path
    pid_file: Path
    pid: int | None = None
    started_at: float = 0.0
    finished: bool = False
    error: str = ""
    # Errors this case is expected to provoke (see DEFAULT_EXPECTED_BENCH_ERRORS).
    expected_errors: list[str] = field(default_factory=list)

    @property
    def running(self) -> bool:
        if self.pid is None:
            return False
        try:
            os.kill(self.pid, 0)
        except OSError:
            return False
        return True


@dataclass
class BenchmarkRun:
    work_root: Path
    workloads: dict[str, Workload] = field(default_factory=dict)
    # Resolved after the schemas exist.
    tree_db: str = ""
    table_db: str = ""
    base_table: str = ""
    view_table: str = ""
    columns: list[str] = field(default_factory=list)          # non-object columns of the base table
    object_columns: list[str] = field(default_factory=list)
    # The benchmark build decides what the time column is called (the older
    # builds used D_DATETIME, newer ones default to `time`), so read it from
    # the live schema rather than assuming.
    time_column: str = "time"
    device_column: str = "device_id"

    def all_workloads(self) -> list[Workload]:
        return list(self.workloads.values())


def _now_iso() -> str:
    """ISO-8601 with a colon in the UTC offset, e.g. 2026-09-15T17:46:36+08:00.

    ``%z`` yields ``+0800``, which some benchmark builds refuse to parse.
    """
    now = datetime.now().astimezone()
    offset = now.strftime("%z")
    if len(offset) == 5:
        offset = f"{offset[:3]}:{offset[3:]}"
    return now.strftime("%Y-%m-%dT%H:%M:%S") + offset


def set_config_value(path: Path, key: str, value: str) -> None:
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(rf"^\s*#?\s*{re.escape(key)}\s*=.*$", re.MULTILINE)
    replacement = f"{key}={value}"
    if pattern.search(text):
        text = pattern.sub(replacement, text, count=1)
    else:
        if not text.endswith("\n"):
            text += "\n"
        text += replacement + "\n"
    path.write_text(text, encoding="utf-8")


# ---------------------------------------------------------------------------
# Stale load protection
# ---------------------------------------------------------------------------
# ``start()`` puts every workload in its own session (``start_new_session``) so
# that a single ``killpg`` takes down the whole JVM tree.  The flip side: when the
# driver dies without reaching ``stop()`` -- SIGTERM from a shell, a crashed
# terminal, a killed parent -- the benchmark keeps writing to the cluster.  The
# next case then sees a dataset that never stops moving and the harness reports
# it as a consistency problem although the database is fine.
#
# Measured on the 2.0.12.1 RC4 matrix: an interrupted ``matrix`` left three
# writers behind, the following case burned 20 minutes and failed with
# "the dataset never settled after the removal", and the failure said nothing
# about the database.  Two guards prevent a repeat: the driver kills its own
# load from a signal handler, and every run refuses to start while an earlier
# run's load is still alive.  Leftovers are identifiable by path -- each workload
# writes its PID under the results root, and only a process whose command line
# names a benchmark directory below *this* results root is ever signalled, so a
# recycled PID or an unrelated process cannot be hit.

_ACTIVE_RUNS: list["BenchmarkRun"] = []


def register_active(run: "BenchmarkRun") -> None:
    """Remember a run that has live load, so a dying driver can still stop it."""
    if run not in _ACTIVE_RUNS:
        _ACTIVE_RUNS.append(run)


def unregister_active(run: "BenchmarkRun") -> None:
    if run in _ACTIVE_RUNS:
        _ACTIVE_RUNS.remove(run)


def kill_active_runs(log=None) -> int:
    """Kill the load started by this process; used by the signal handlers."""
    killed = 0
    for run in list(_ACTIVE_RUNS):
        for workload in run.all_workloads():
            if workload.pid is None:
                continue
            if _kill_group(workload.pid) and log:
                log(f"  killed in-flight benchmark '{workload.name}' pid={workload.pid}")
            killed += 1
    _ACTIVE_RUNS.clear()
    return killed


def _kill_group(pid: int) -> bool:
    """SIGKILL the workload's whole session (the JVM is a child of the wrapper)."""
    try:
        os.killpg(os.getpgid(pid), signal.SIGKILL)
        return True
    except OSError:
        try:
            os.kill(pid, signal.SIGKILL)
            return True
        except OSError:
            return False


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _cmdline(pid: int) -> str:
    try:
        return (
            Path(f"/proc/{pid}/cmdline")
            .read_bytes()
            .replace(b"\0", b" ")
            .decode("utf-8", "replace")
        )
    except OSError:
        return ""


def stale_workloads(results_root: Path) -> list[tuple[int, Path]]:
    """Live benchmark processes recorded under ``results_root`` by earlier runs."""
    found: list[tuple[int, Path]] = []
    if not results_root.is_dir():
        return found
    for pid_file in sorted(results_root.glob("**/benchmark/*/benchmark.pid")):
        try:
            pid = int(pid_file.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            continue
        if not _pid_alive(pid):
            continue
        # A live driver owns the load it started: only leftovers from dead drivers
        # count as stale (a marker missing entirely means an older run wrote it).
        try:
            driver = int((pid_file.parent.parent / "driver.pid").read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            driver = None
        if driver is not None and _pid_alive(driver):
            continue
        # Never signal a recycled PID: the command line must still name a
        # benchmark directory belonging to this results tree.
        cmdline = _cmdline(pid)
        if "benchmark" not in cmdline:
            continue
        if str(pid_file.parent) not in cmdline and str(results_root) not in cmdline:
            continue
        found.append((pid, pid_file))
    return found


def kill_stale_workloads(results_root: Path, log=None, kill: bool = True) -> list[tuple[int, Path]]:
    """Report -- and by default stop -- load left behind by earlier, dead runs.

    ``kill=False`` is what ``doctor`` uses: the precondition check must be able to
    report the leftovers without changing the machine.
    """
    stale = stale_workloads(results_root)
    for pid, pid_file in stale:
        try:
            where = pid_file.parent.relative_to(results_root)
        except ValueError:
            where = pid_file
        if kill:
            _kill_group(pid)
            if log:
                log(f"  stopped stale benchmark pid={pid} left by an earlier run ({where})")
        elif log:
            log(
                f"  stale load     : pid={pid} is still writing ({where}); "
                f"stop it with `kill -9 -{pid}` before running cases"
            )
    return stale


class BenchmarkDriver:
    """Generate benchmark configs, start/stop the load and resolve schemas."""

    def __init__(self, cfg: Config, sql: SqlClient, run_root: Path, log):
        self.cfg = cfg
        self.sql = sql
        self.log = log
        self.run_root = run_root
        self.bm_home = Path(cfg.get("BM_HOME")).expanduser()
        self.template = SKILL_ROOT / "templates" / "benchmark" / "config.template.properties"

    # ------------------------------------------------------------------
    # Config generation
    # ------------------------------------------------------------------
    def _base_config(self) -> str:
        candidate = self.bm_home / "conf" / "config.properties"
        if candidate.is_file():
            return candidate.read_text(encoding="utf-8")
        if self.template.is_file():
            return self.template.read_text(encoding="utf-8")
        raise FileNotFoundError(
            f"no benchmark config template: neither {candidate} nor {self.template} exists"
        )

    def _workload_overrides(self, name: str) -> dict[str, str]:
        cfg = self.cfg
        # Everything is set explicitly: the benchmark's own defaults change
        # between releases, and a case that silently picks up a different
        # default is not reproducible.  Values marked (ref) come from the
        # validated writeview configs shipped with the reference test suite.
        common = {
            # --- cluster / credentials -------------------------------------
            "HOST": ",".join(cfg.dn_hosts),
            "PORT": ",".join([str(cfg.dn_rpc_port)] * len(cfg.dn_hosts)),
            "PASSWORD": cfg.get("BM_USER_PASSWORD"),
            "BENCHMARK_WORK_MODE": "testWithDefaultPath",
            "IS_DELETE_DATA": "false",
            "IS_DOUBLE_WRITE": "false",
            "BENCHMARK_CLUSTER": "false",
            "USE_SSL": "false",
            "USE_MEASUREMENT": "true",          # ref
            "TEST_MAX_TIME": "0",               # ref
            # --- data volume (small on purpose) ----------------------------
            "LOOP": cfg.get("BM_LOOP"),
            "DEVICE_NUMBER": cfg.get("BM_DEVICE_NUMBER"),
            "SENSOR_NUMBER": cfg.get("BM_SENSOR_NUMBER"),
            "DEVICE_NUM_PER_WRITE": cfg.get("BM_DEVICE_NUM_PER_WRITE"),   # ref
            "BATCH_SIZE_PER_WRITE": cfg.get("BM_BATCH_SIZE_PER_WRITE"),
            "SCHEMA_CLIENT_NUMBER": cfg.get("BM_SCHEMA_CLIENT_NUMBER"),
            "DATA_CLIENT_NUMBER": cfg.get("BM_DATA_CLIENT_NUMBER"),
            "GROUP_NUMBER": cfg.get("BM_GROUP_NUMBER"),                   # ref
            # --- schema / naming ------------------------------------------
            "CREATE_SCHEMA": "true",
            "TEMPLATE": "false",
            "VECTOR": "false",
            "DEVICE_NAME_PREFIX": "d_",
            "SENSOR_NAME_PREFIX": "s_",         # ref
            "TAG_NUMBER": cfg.get("BM_TAG_NUMBER"),
            # --- timing ----------------------------------------------------
            "POINT_STEP": cfg.get("BM_POINT_STEP"),
            "OP_MIN_INTERVAL": "0",             # ref
            "INTERVAL_BETWEEN_WRITE_BATCH": cfg.get("BM_WRITE_INTERVAL_MS"),  # ref
            "STEP_SIZE": "0",                   # ref
            "QUERY_INTERVAL": cfg.get("BM_QUERY_INTERVAL"),                # ref
            # --- data generation -------------------------------------------
            "STRING_LENGTH": cfg.get("BM_STRING_LENGTH"),                  # ref
            "OBJECT_LENGTH": cfg.get("BM_OBJECT_LENGTH"),
            "OBJECT_QUERY_FULL_CONTENT": "false",                          # ref
            "DATA_SEED": cfg.get("BM_DATA_SEED"),                          # ref
            "LINE_RATIO": "1",                  # ref
            "SIN_RATIO": "0",                   # ref
            "SQUARE_RATIO": "0",                # ref
            "RANDOM_RATIO": "1",                # ref
            "CONSTANT_RATIO": "0",              # ref
            "IS_OUT_OF_ORDER": "false",
            "IS_RECORD_CURRENT_REALLY_TIME": cfg.get("BM_RECORD_CURRENT_TIME"),  # ref
            # --- queries ---------------------------------------------------
            "ENABLE_FIXED_QUERY": "false",      # ref
            "QUERY_SENSOR_NUM": "1",            # ref
            "QUERY_DEVICE_NUM": "1",            # ref
            "QUERY_LOWER_VALUE": "-5",
            # --- output ----------------------------------------------------
            "START_TIME": _now_iso(),
            "RESULT_PRINT_INTERVAL": "0",       # ref: print once, at the end
            "TEST_DATA_PERSISTENCE": "None",
        }
        if cfg.get_bool("BM_USE_DEDICATED_USERS"):
            user_key = "BM_TREE_USER" if name == "tree" else "BM_TABLE_USER"
            common["USERNAME"] = cfg.get(user_key)
        else:
            common["USERNAME"] = cfg.get("DB_USER")

        if name == "tree":
            common.update(
                {
                    "DB_SWITCH": cfg.bm_db_switch(),
                    "IoTDB_DIALECT_MODE": "tree",
                    "DB_NAME": cfg.get("BM_TREE_DB"),
                    "INSERT_DATATYPE_PROPORTION": TREE_DATATYPE_PROPORTION,
                    "OPERATION_PROPORTION": "91:1:1:1:1:0:1:1:1:1:1:0:0",
                    "GROUP_NAME_PREFIX": cfg.get("BM_TREE_GROUP_PREFIX"),
                }
            )
        else:
            common.update(
                {
                    "DB_SWITCH": cfg.bm_db_switch(),
                    "IoTDB_DIALECT_MODE": "table",
                    "IoTDB_TABLE_TIME_COLUMN": "D_DATETIME",
                    "IoTDB_TABLE_NUMBER": "1",
                    "DB_NAME": cfg.get("BM_TABLE_DB"),
                    "GROUP_NAME_PREFIX": cfg.get("BM_TABLE_GROUP_PREFIX"),
                    "INSERT_DATATYPE_PROPORTION": TABLE_DATATYPE_PROPORTION,
                    "OPERATION_PROPORTION": TABLE_SAFE_OPERATION_PROPORTION,
                    "IoTDB_TABLE_WRITABLE_VIEW": "true" if name == "table_view" else "false",
                    "IoTDB_TABLE_NAME_PREFIX": cfg.get(
                        "BM_TABLE_VIEW_PREFIX" if name == "table_view" else "BM_TABLE_PREFIX"
                    ),
                }
            )
        for pair in cfg.get_list("BM_EXTRA_CONFIG"):
            key, _, value = pair.partition("=")
            if key.strip():
                common[key.strip()] = value.strip()
        return common

    def prepare(self, workload_names: list[str]) -> BenchmarkRun:
        run = BenchmarkRun(work_root=self.run_root / "benchmark")
        run.work_root.mkdir(parents=True, exist_ok=True)
        for name in workload_names:
            wdir = run.work_root / name
            if wdir.exists():
                shutil.rmtree(wdir)
            wdir.mkdir(parents=True)
            # iot-benchmark reads its working directory as the conf dir and
            # needs the install's support files there (function.xml,
            # logback.xml, ...), not just config.properties.
            for support in sorted((self.bm_home / "conf").iterdir()):
                if support.is_file() and support.name != "config.properties":
                    shutil.copy2(support, wdir / support.name)
            config = wdir / "config.properties"
            config.write_text(self._base_config(), encoding="utf-8")
            for key, value in self._workload_overrides(name).items():
                set_config_value(config, key, value)
            run.workloads[name] = Workload(
                name=name,
                dialect=WORKLOAD_DIALECT[name],
                db_name=self.cfg.get("BM_TREE_DB") if name == "tree" else self.cfg.get("BM_TABLE_DB"),
                directory=wdir,
                config=config,
                log=wdir / "benchmark.out",
                pid_file=wdir / "benchmark.pid",
            )
            self.log(f"  workload {name}: {config}")
        return run

    # ------------------------------------------------------------------
    # Users
    # ------------------------------------------------------------------
    def create_users(self) -> None:
        if not self.cfg.get_bool("BM_USE_DEDICATED_USERS"):
            return
        pw = self.cfg.get("BM_USER_PASSWORD")
        host = self.cfg.cli_host
        tree_db = self.cfg.get("BM_TREE_DB")
        table = self.cfg.get("BM_TABLE_USER")
        tree = self.cfg.get("BM_TREE_USER")
        statements = [
            (None, f"CREATE USER {tree} '{pw}';"),
            (None, f"GRANT READ_SCHEMA,WRITE_SCHEMA,READ_DATA,WRITE_DATA ON root.{tree_db}.** TO USER {tree};"),
            (None, f"CREATE USER {table} '{pw}';"),
            ("table", f"GRANT ALL TO USER {table};"),
        ]
        for dialect, stmt in statements:
            out = self.sql.sql(host, stmt, dialect=dialect, check=False)
            if looks_like_sql_error(out) and not re.search(r"already exists", out, re.I):
                raise RuntimeError(f"failed to prepare benchmark user: {stmt}\n{out[-1500:]}")

    # ------------------------------------------------------------------
    # Start / stop
    # ------------------------------------------------------------------
    def start(self, run: BenchmarkRun) -> None:
        launcher = self.bm_home / "benchmark.sh"
        if not launcher.is_file():
            raise FileNotFoundError(f"{launcher} not found; check BM_HOME")
        # Marker read by the stale-load scan: while this driver PID is alive the
        # workloads below are its own load, so a concurrently running run/matrix
        # (or `doctor`) must leave them alone.
        (run.work_root / "driver.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
        for workload in run.all_workloads():
            fh = workload.log.open("wb")
            proc = subprocess.Popen(
                ["bash", str(launcher), "-cf", str(workload.directory)],
                cwd=str(self.bm_home),
                stdout=fh,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
            workload.pid = proc.pid
            workload.started_at = time.time()
            workload.pid_file.write_text(f"{proc.pid}\n", encoding="utf-8")
            self.log(f"  started benchmark '{workload.name}' pid={proc.pid} log={workload.log}")
        # From here the load can outlive this process; the signal handlers in
        # cli.main use this registration to stop it (see the stale-load section).
        register_active(run)

    def stop(self, run: BenchmarkRun) -> None:
        for workload in run.all_workloads():
            if workload.pid is None or not workload.running:
                continue
            _kill_group(workload.pid)
            self.log(f"  stopped benchmark '{workload.name}'")
        unregister_active(run)

    # ------------------------------------------------------------------
    # Readiness / completion
    # ------------------------------------------------------------------
    def _databases(self, dialect: str) -> list[str]:
        """List databases using the dialect that can see them.

        ``show databases`` is dialect scoped: the tree dialect lists
        ``root.<db>...`` paths while the table dialect lists ``<db>_<group>``.
        """
        raw = self.sql.sql(self.cfg.cli_host, "show databases;", dialect=dialect, check=False)
        names = [r.get("Database", "").strip() for r in parse_table(raw)]
        return [n for n in names if n]

    def _find_tree_db(self) -> str:
        want = self.cfg.get("BM_TREE_DB")
        for name in self._databases("tree"):
            if want in name.split("."):
                return name
        return ""

    def _find_table_db(self) -> str:
        want = self.cfg.get("BM_TABLE_DB")
        for name in self._databases("table"):
            if name == want or name.startswith(f"{want}_"):
                return name
        return ""

    def wait_objects_ready(self, run: BenchmarkRun, timeout: int = 900) -> None:
        wanted_tree = "tree" in run.workloads
        wanted_table = "table" in run.workloads
        wanted_view = "table_view" in run.workloads
        deadline = time.time() + timeout

        while True:
            if wanted_tree and not run.tree_db:
                run.tree_db = self._find_tree_db()
            if (wanted_table or wanted_view) and not run.table_db:
                run.table_db = self._find_table_db()
            if run.table_db and (wanted_table or wanted_view):
                details = self.sql.sql(
                    self.cfg.cli_host,
                    f"show tables details from {run.table_db};",
                    dialect="table",
                    check=False,
                )
                rows = parse_table(details)
                for row in rows:
                    kind = (row.get("TableType") or row.get("Type") or "").upper()
                    name = (row.get("TableName") or row.get("Name") or "").strip()
                    if not name or name.lower() == "tablename":
                        continue
                    if "WRITABLE" in kind and not run.view_table:
                        run.view_table = name
                    elif "BASE" in kind and not run.base_table:
                        run.base_table = name
                if not run.base_table:
                    names = [
                        r.get("TableName", "").strip()
                        for r in rows
                        if r.get("TableName") and r.get("TableName", "").strip().lower() != "tablename"
                    ]
                    if names:
                        run.base_table = names[0]
            ready = True
            if wanted_tree and not run.tree_db:
                ready = False
            if wanted_table and not run.base_table:
                ready = False
            if wanted_view and not run.view_table:
                ready = False
            if ready:
                self.log(
                    f"  benchmark objects ready: tree_db={run.tree_db or '-'} "
                    f"table_db={run.table_db or '-'} base={run.base_table or '-'} view={run.view_table or '-'}"
                )
                return
            if time.time() > deadline:
                raise TimeoutError(
                    f"benchmark objects were not created within {timeout}s "
                    f"(tree_db={run.tree_db or '-'}, table_db={run.table_db or '-'}, "
                    f"base={run.base_table or '-'}, view={run.view_table or '-'})"
                )
            time.sleep(10)

    def resolve_columns(self, run: BenchmarkRun) -> None:
        """Read the base table schema so queries can be generated without assumptions."""
        if not run.base_table:
            return
        raw = self.sql.sql(
            self.cfg.cli_host,
            f"describe {run.table_db}.{run.base_table} details;",
            dialect="table",
            check=False,
        )
        rows = parse_table(raw)
        if not rows:
            raw = self.sql.sql(
                self.cfg.cli_host,
                f"describe {run.table_db}.{run.base_table};",
                dialect="table",
                check=False,
            )
            rows = parse_table(raw)
        columns: list[str] = []
        objects: list[str] = []
        for row in rows:
            name = (row.get("ColumnName") or row.get("Field") or row.get("Name") or "").strip()
            ctype = (row.get("DataType") or row.get("Type") or "").strip().upper()
            category = (row.get("Category") or "").strip().upper()
            if not name or name.upper() in {"COLUMNNAME", "FIELD", "NAME"}:
                continue
            if category == "TIME":
                run.time_column = name
            elif category == "TAG" and run.device_column == "device_id":
                run.device_column = name
            if ctype == "OBJECT":
                objects.append(name)
            elif ctype:
                columns.append(name)
        run.columns = columns
        run.object_columns = objects
        self.log(f"  base table columns: {len(columns)} scalar, {len(objects)} object {objects}")

    def wait_finish(
        self, run: BenchmarkRun, max_runtime: int, outage: list[tuple[float, float | None]] | None = None
    ) -> list[str]:
        """Wait for every workload to finish; returns a list of problems."""
        problems: list[str] = []
        deadline = time.time() + max_runtime
        while True:
            pending = [w for w in run.all_workloads() if not w.finished]
            for workload in pending:
                text = workload.log.read_text(encoding="utf-8", errors="replace") if workload.log.is_file() else ""
                done = "Result Matrix" in text and "Test elapsed time" in text
                if done and not workload.running:
                    workload.finished = True
                    unexpected, expected = self.classify_log_errors(text, outage)
                    if expected:
                        workload.expected_errors = expected
                        for hit in expected[:3]:
                            self.log(
                                f"  {workload.name}: expected error, not a failure: {hit[:110]}"
                            )
                    if unexpected:
                        workload.error = (
                            f"benchmark log contains errors: {sorted(set(unexpected))[:5]}"
                        )
                        problems.append(f"{workload.name}: {workload.error}")
                    continue
                if not workload.running and not done:
                    workload.finished = True
                    workload.error = "benchmark exited without a Result Matrix"
                    problems.append(f"{workload.name}: {workload.error}")
            if all(w.finished for w in run.all_workloads()):
                return problems
            if time.time() > deadline:
                for workload in run.all_workloads():
                    if not workload.finished:
                        problems.append(f"{workload.name}: benchmark did not finish within {max_runtime}s")
                return problems
            time.sleep(15)

    def expected_error_re(self) -> re.Pattern[str] | None:
        raw = self.cfg.raw("EXPECTED_BENCH_ERRORS", DEFAULT_EXPECTED_BENCH_ERRORS).strip()
        if not raw:
            return None
        try:
            return re.compile(raw, re.IGNORECASE)
        except re.error as exc:  # a bad pattern must not disable error scanning
            self.log(f"  warning: EXPECTED_BENCH_ERRORS is not a valid regex ({exc}); ignoring")
            return None

    def _error_blocks(self, text: str) -> list[tuple[float | None, str, str]]:
        """Split the log into (timestamp, first line, whole block) error reports.

        A block runs from an error line to the next log record, because Java
        stack frames carry no timestamp of their own.
        """
        lines = text.splitlines()

        def parsed(match) -> float | None:
            if not match:
                return None
            try:
                return datetime.strptime(match.group(0), "%Y-%m-%d %H:%M:%S").timestamp()
            except ValueError:
                return None

        blocks: list[tuple[float | None, str, str]] = []
        last_ts: float | None = None
        i = 0
        while i < len(lines):
            # A block may begin on a stack frame, which carries no timestamp, so
            # inherit the time of the log record it belongs to.
            last_ts = parsed(LOG_RECORD_START.match(lines[i])) or last_ts
            if not BENCHMARK_ERROR_PATTERN.search(lines[i]):
                i += 1
                continue
            j = i + 1
            while j < len(lines) and not LOG_RECORD_START.match(lines[j]):
                j += 1
            blocks.append((last_ts, lines[i].strip()[:200], "\n".join(lines[i:j])))
            i = j
        return blocks

    def classify_log_errors(
        self, text: str, outage: list[tuple[float, float | None]] | None = None
    ) -> tuple[list[str], list[str]]:
        """Split benchmark error reports into (unexpected, expected).

        Attribution happens per log block, not per line: the benchmark reports
        the same failure twice -- once with the cause in the stack, and once as
        a DBWrapper "Execution fail:" summary whose stack is only
        "java.lang.Exception: Failed to execute." with the cause swallowed.  So a
        summary is credited to an expected cause reported at the same moment;
        otherwise it would keep failing a case that behaves as documented.
        """
        expected_re = self.expected_error_re()
        blocks = self._error_blocks(text)
        verdict = [
            bool(expected_re is not None and expected_re.search(blob))
            for _, _, blob in blocks
        ]
        # An error reported while the ConfigRegion is below quorum is expected:
        # the cluster cannot serve by construction.  See `cn_quorum_state`.
        if outage:
            for idx, ((ts, _, _), ok) in enumerate(zip(blocks, verdict)):
                if ok or ts is None:
                    continue
                for start, end in outage:
                    if ts >= start and (end is None or ts <= end):
                        verdict[idx] = True
                        break
        if expected_re is not None:
            expected_times = [
                ts for (ts, _, _), ok in zip(blocks, verdict) if ok and ts is not None
            ]
            for idx, ((ts, first, _), ok) in enumerate(zip(blocks, verdict)):
                if ok or ts is None or not SUMMARY_ERROR_PATTERN.search(first):
                    continue
                if any(abs(ts - other) <= SUMMARY_CORRELATION_WINDOW_SEC for other in expected_times):
                    verdict[idx] = True
        unexpected = [first for (_, first, _), ok in zip(blocks, verdict) if not ok]
        expected = [first for (_, first, _), ok in zip(blocks, verdict) if ok]
        return unexpected, expected

    def logs_have_errors(
        self, run: BenchmarkRun, outage: list[tuple[float, float | None]] | None = None
    ) -> dict[str, list[str]]:
        out: dict[str, list[str]] = {}
        for workload in run.all_workloads():
            if not workload.log.is_file():
                continue
            text = workload.log.read_text(encoding="utf-8", errors="replace")
            unexpected, expected = self.classify_log_errors(text, outage)
            if expected:
                workload.expected_errors = expected
                self.log(
                    f"  {workload.name}: {len(expected)} expected error line(s), not a failure"
                )
            if unexpected:
                out[workload.name] = sorted(set(unexpected))[:5]
        return out
