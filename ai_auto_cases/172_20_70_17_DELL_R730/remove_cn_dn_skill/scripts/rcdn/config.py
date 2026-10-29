"""Configuration loading for the iotdb-remove-cn-dn skill.

Every address used by the skill comes from the config file or from runtime
discovery.  Nothing in this package contains a hard-coded cluster IP.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

# config.py lives in <skill>/scripts/rcdn/, so the skill root is 3 levels up.
SKILL_ROOT = Path(__file__).resolve().parents[2]

DEFAULTS: dict[str, str] = {
    "SSH_USER": "cluster",
    "SSH_PORT": "22",
    "SSH_MODE": "key",
    "SSH_PASSWORD": "",
    "SSH_EXTRA_OPTS": "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR",
    # Reuse one ssh connection per host.  Without this a case opens hundreds of
    # connections and the full matrix tens of thousands from one IP, which host
    # intrusion prevention reads as a brute-force attempt and blocks.
    "SSH_MULTIPLEX": "true",
    "SSH_CONTROL_PERSIST": "300",
    # How long to wait before concluding that a removed DataNode's restart was
    # (correctly) refused.  IoTDB rejects it outright, so this is short.
    # Multi-disk OBJECT layout.  ``DN_DATA_DIRS`` is written verbatim as
    # ``dn_data_dirs`` (',' inside a tier, ';' between tiers); empty keeps the
    # build's default.  ``DN_EXTRA_DIRS`` lists the absolute data directories
    # outside DB_DIR that must be created before start and wiped with the rest --
    # without the wipe, region data/OBJECT files from a previous case survive and
    # poison the next one.
    "DN_DATA_DIRS": "",
    "DN_EXTRA_DIRS": "",
    # OBJECT delete burst used by the TDB-861 case: delete rows older than
    # ``OBJECT_DELETE_AGE_MS`` in ``OBJECT_DELETE_ROUNDS`` statements spaced
    # ``OBJECT_DELETE_INTERVAL_SEC`` apart, right before the removal is issued.
    "OBJECT_DELETE_AGE_MS": "30000",
    "OBJECT_DELETE_ROUNDS": "3",
    "OBJECT_DELETE_INTERVAL_SEC": "2",
    # How many OBJECT-GC deletion records prove the race window was real, and how
    # long to wait for them before the removal is issued.
    "OBJECT_GC_MIN_RECORDS": "20",
    "OBJECT_GC_PRIME_TIMEOUT_SEC": "150",
    # TDB-861 window injection (see `object_audit.run_object_snapshot_probe`).
    # On master 939750de80 a DELETE reclaims the payloads without writing a
    # `log_datanode_object_deletion.log` record, so the delete-burst injection
    # found 4-8 records and the case SKIPped.  Overwriting the same rows does
    # write the journal (~40 records per 100-row round), and a targeted
    # `MIGRATE REGION` takes the snapshot the defect needs.
    "OBJECT_PROBE_MIGRATE": "true",
    "OBJECT_PROBE_DB": "objprobe",
    "OBJECT_PROBE_TABLE": "t",
    "OBJECT_PROBE_TIMEOUT_SEC": "240",
    "OBJECT_CHURN_ROWS": "100",
    "OBJECT_CHURN_INTERVAL_SEC": "1.5",
    # Big-OBJECT scenario: many large points (segmented writes through the
    # benchmark) instead of one 4 GiB literal, then migrate every region.
    "OBJECT_BIG_TARGET_GIB": "4",
    "OBJECT_BIG_TIMEOUT_SEC": "1800",
    "OBJECT_BIG_MIGRATE": "true",
    "OBJECT_BIG_SAMPLE_ROWS": "10",
    # Many-small-files variant: the old snapshot copied the whole object dir, so
    # the race only lands when the copy itself takes long enough (1e5 files).
    "OBJECT_MANY_TARGET_FILES": "100000",
    "OBJECT_MANY_TIMEOUT_SEC": "1800",
    "OBJECT_MANY_MODE": "overwrite",
    # One OBJECT point of 4 GiB built from chunked to_object(isEOF, offset, X'..') inserts.
    "OBJECT_SINGLE_GIB": "4",
    "OBJECT_SINGLE_CHUNK_MIB": "8",
    # read-back chunk for read_object(o, offset, length): whole-file reads cap at 2 GiB
    "OBJECT_SINGLE_READ_CHUNK_MIB": "256",
    "OBJECT_SINGLE_DB": "objsingle",
    "OBJECT_SINGLE_MIGRATE": "true",
    "OBJECT_MANY_RECHECK_SEC": "180",
    "REMOVED_NODE_RESTART_PROBE_SEC": "90",
    # How long to let a removed DataNode settle after it comes back before
    # judging whether it cleaned up the files it left behind.
    "RESTART_CLEANUP_SETTLE_SEC": "60",
    # Override for the restart probe's refusal verdict.
    # By default the verdict follows the case: a node the case KILLED mid-removal
    # could not clean up, so the documented "Reject DataNode restart / please
    # delete the useless 'data' dir" guard is expected and only recorded; any
    # other removal finished with the node alive, so refusing to start is a
    # failure (the node can never be reused without manual intervention).
    # true: treat a refusal as a failure even for a killed node.
    "REMOVED_NODE_RESTART_STRICT": "false",
    # A remove whose procedure worker has been stuck this long is not going to
    # finish; report it instead of waiting out REMOVE_MAX_WAIT_SEC.  0 disables.
    "PROCEDURE_STALL_SEC": "300",
    # Consecutive syncLag polls that may report the same non-zero value before
    # the gate calls it a stall instead of slow convergence (10s each).  0
    # disables.
    "SYNC_STALL_POLLS": "12",
    "NODES_FILE": "conf/nodes.conf",
    "SEED_HOSTS": "",
    "DB_DIR": "",
    "CLI_HOME": "",
    # Whether start-cli.sh needs sudo to find java: auto | true | false.
    # `auto` probes the login user first and falls back to `sudo -n`.
    "CLI_SUDO": "auto",
    "CLI_NODE": "",
    "LICENSE_SRC": "",
    "DATA_REPLICATION_FACTOR": "2",
    "SCHEMA_REPLICATION_FACTOR": "3",
    # -- deployment (`rcdn deploy`) --------------------------------------
    # A release tarball: a local path (uploaded to the hosts) or a path that
    # already exists on every host.  Leave empty for an already-deployed
    # cluster, where `prepare` is enough.
    "DEPLOY_TARBALL": "",
    # Where to unpack; DB_DIR is the final install path and is authoritative,
    # so the archive's internal directory name never has to be guessed.
    "DEPLOY_DIR": "",
    # Comma-separated hosts for a fresh co-located deployment (one ConfigNode
    # and one DataNode per host, the usual 3C3D shape).  Ignored when
    # NODES_FILE already exists, which always wins.
    "DEPLOY_HOSTS": "",
    # data_region_consensus_protocol_class.  Accepts IoTConsensus (default),
    # IoTConsensusV2 or the shorthand IoTV2.
    "DEPLOY_CONSENSUS": "IoTConsensus",
    "DEPLOY_ACTIVATE": "true",
    # The activation code itself, or a file containing it.  When empty,
    # LICENSE_CODE_FILE is read -- by default the skill repository's activation
    # reference, which holds the built-in trial code.
    "LICENSE_CODE": "",
    "LICENSE_CODE_FILE": (
        "/data/deepseek/ai-bug-verify/skills/timechodb-rn-verify/references/activation.md"
    ),
    "DB_USER": "root",
    "DB_PASSWORD": "TimechoDB@2021",
    # Database version under test (e.g. 2.0.12.1 or 1.3.4).  It picks the
    # benchmark build and decides whether the table model is testable, so an
    # explicit value is always best; otherwise it is read from the release
    # tarball name or the DB_DIR name.
    "DB_VERSION": "",
    "BM_HOME": "",
    # Empty means "derive from DB_VERSION": the 2.x line uses
    # IoTDB-200-SESSION_BY_TABLET and the 1.x line IoTDB-130-SESSION_BY_TABLET.
    # Set it only to override that pairing deliberately.
    "BM_DB_SWITCH": "",
    "BM_USE_DEDICATED_USERS": "false",
    # For a remove test the load is meant to be *interrupted*: the point is to
    # have read/write traffic in flight while a node leaves.  Waiting for the
    # benchmark to reach its own Result Matrix would add hours and prove
    # nothing, so stop it once the remove and the sync drain are done.
    "BM_WAIT_FINISH": "false",
    "BM_TREE_DB": "test",
    "BM_TABLE_DB": "usr",
    "BM_TREE_USER": "rcdn_tree",
    "BM_TABLE_USER": "rcdn_table",
    "BM_USER_PASSWORD": "TimechoDB@2021",
    "BM_LOOP": "1000",
    "BM_DEVICE_NUMBER": "100",
    "BM_SENSOR_NUMBER": "12",
    "BM_DEVICE_NUM_PER_WRITE": "1",
    "BM_SCHEMA_CLIENT_NUMBER": "1",
    "BM_DATA_CLIENT_NUMBER": "10",
    "BM_BATCH_SIZE_PER_WRITE": "1",
    "BM_POINT_STEP": "1000",
    "BM_GROUP_NUMBER": "1",
    "BM_TAG_NUMBER": "0",
    "BM_TREE_GROUP_PREFIX": "g_",
    "BM_TABLE_GROUP_PREFIX": "sod",
    "BM_TABLE_PREFIX": "tab_",
    "BM_TABLE_VIEW_PREFIX": "wv_",
    "BM_WRITE_INTERVAL_MS": "200",
    "BM_QUERY_INTERVAL": "1000",
    "BM_STRING_LENGTH": "16",
    "BM_OBJECT_LENGTH": "4096",
    "BM_DATA_SEED": "666",
    "BM_RECORD_CURRENT_TIME": "true",
    "BM_EXTRA_CONFIG": "",
    "BM_REMOVE_AFTER_SEC": "120",
    # Abnormal-op injection knobs.  `restart_dn` used to always restart
    # `running_dns[0]` after a fixed 5 s, so whether the fault landed inside the
    # member-replacement window depended purely on where the regions happened to
    # sit -- the documented silent-row-loss repro is placement-luck at ~1 hit per
    # 8-20 cases.  Both knobs default to the old behaviour; a sweep over
    # (ABNORMAL_DN_HOST, ABNORMAL_DELAY_SEC, ABNORMAL_DN_ROTATE) targets the window
    # deliberately.  Rotate matters for the repeated-restart cases: without it every
    # `restart_dn` in one case restarts the SAME node (the list is fixed up front),
    # so a 3-restart "storm" is one node three times and the node that actually
    # received the migrated replica is never touched.  With it, each op restarts the
    # next node, so a sweep of N restarts covers N distinct DataNodes -- whichever
    # one holds the new replica gets restarted by construction.
    "ABNORMAL_DELAY_SEC": "5",
    "ABNORMAL_DN_HOST": "",
    "ABNORMAL_DN_ROTATE": "false",
    "BM_MAX_RUNTIME_SEC": "43200",
    "BM_WORKLOADS": "tree,table,table_view",
    # After a removal, the removed DataNode's region files must be gone.  The
    # verdict is a single strict snapshot; if it is not clean, the case waits
    # this long and scans once more so the report can tell "the deletion is
    # still in flight" from "the deletion never happened".  The recheck only
    # adds detail to the same problem, so it never changes PASS/FAIL.
    "REMOVE_CLEANUP_RECHECK_SEC": "30",
    "MONITOR_URL": "",
    "MONITOR_USER": "admin",
    "MONITOR_PASSWORD": "admin",
    # sync-lag source: auto (prometheus if MONITOR_URL else the nodes' own
    # /metrics), prometheus, or metrics
    "SYNC_LAG_SOURCE": "auto",
    # DataNode metrics exporter port, used when there is no Prometheus server.
    # 0 means "read it from the DataNode's own conf".
    "METRICS_PORT": "0",
    # Metrics reported under this cluster label; keep it stable so dashboards
    # and Prometheus queries can tell clusters apart.
    "CLUSTER_NAME": "defaultCluster",
    # syncLag must read 0 for this long before we believe it converged.  60s
    # with a 10s poll is 7 consecutive zero readings: enough to rule out a
    # transient dip, without making every consistency step cost minutes.
    "SYNC_STABLE_SECONDS": "60",
    "SYNC_MAX_WAIT_SEC": "3600",
    "SYNC_POLL_INTERVAL_SEC": "10",
    "CONSENSUS_METRIC": "auto",
    "MIGRATION_STABLE_SECONDS": "20",
    "REMOVE_MAX_WAIT_SEC": "7200",
    "CONSISTENCY_CHECK": "true",
    # The replica-consistency baseline is only trustworthy once the dataset
    # has stopped moving.  After a DataNode removal the visible data keeps
    # converging for a while even though SHOW MIGRATIONS is empty and
    # syncLag has reached zero, so the baseline is captured twice and only
    # accepted when both captures agree.
    "CONSISTENCY_SETTLE_SECONDS": "45",
    "CONSISTENCY_SETTLE_TRIES": "8",
    "CONSISTENCY_QUERY_TIMEOUT_SEC": "3600",
    "CONSISTENCY_SETTLE_SEC": "5",
    "LOG_SCAN": "true",
    # Errors a case provokes on purpose must not fail it.  Confirmed by R&D:
    # stopping/restarting the DataNode serving a statement fails it with 722
    # CANNOT_FETCH_FI_STATE, which is documented behaviour.  That code has two
    # possible texts, so the code itself is matched as well -- see
    # `DEFAULT_EXPECTED_BENCH_ERRORS` in benchmark.py for the two phrasings.
    # 305 "no detailed failure reason in QueryStateMachine" is the same shape of
    # expected error and R&D decided (2026-09-29) not to fix it: a query that is
    # in flight while a DataNode is recycled fails, and waiting for it before
    # releasing the resources risks the REMOVE being stuck behind a large query.
    # Set to "" to treat every benchmark error as a failure again.
    "EXPECTED_BENCH_ERRORS": (
        "Fetch Table Device Schema failed"
        "|CANNOT_FETCH_FI_STATE"
        "|Failed to fetch state, has retried"
        "|722:"
        "|305:"
    ),
    # A fault that leaves the ConfigRegion without a quorum makes an outage
    # correct behaviour, not a defect (R&D: at two ConfigNodes a restart
    # cannot be made highly available).  Set false to report those anyway.
    "CN_BELOW_QUORUM_EXPECTED_OUTAGE": "true",
    # A DataNode fault is not a ConfigNode quorum problem, but it is exposed the
    # same way: while the node is stopped/restarted any statement that was being
    # served by it fails, and R&D's decision above (recycle the resources
    # immediately instead of draining in-flight queries) makes that expected.
    # The window is recorded by `run_abnormal`, so only errors inside it are
    # excused.  False keeps the stricter reading (errors must match
    # EXPECTED_BENCH_ERRORS by text/code alone).
    "DN_FAULT_EXPECTED_OUTAGE": "true",
    "LOG_SCAN_MODE": "full",
    "LOG_EXTRA_PATTERNS": "",
    "RESULT_DIR": "./results",
    "LOG_BACKUP": "fail",
    # Plain-text copy of every node log into results/<run>/node_logs/<host>/ when a
    # migration-class case fails: the next cluster reset wipes <DB_DIR>/logs.
    "NODE_LOG_BACKUP": "fail",
    "NODE_LOG_BACKUP_SCOPE": "migration",
    "KEEP_SCRATCH": "false",
    "CN_HEAP": "2G",
    "CN_OFF_HEAP": "1G",
    "DN_HEAP": "20G",
    "DN_OFF_HEAP": "2G",
    "RESET_CLUSTER_PER_CASE": "true",
    "CLUSTER_START_TIMEOUT_SEC": "900",
    "CLUSTER_STOP_TIMEOUT_SEC": "300",
    "SPARE_DN_HOSTS": "",
    "MULTI_REMOVE_COUNT": "3",
    # Simulate a disk-full DataNode by raising its own disk_space_warning_threshold
    # above the real free ratio (hot-reloaded, nothing written). Set to false to
    # refuse to touch that property; the disk-full cases then SKIP.
    "DISK_FULL_SIMULATE": "true",
}

_TRUE = {"1", "true", "yes", "on"}
_FALSE = {"0", "false", "no", "off"}


class ConfigError(RuntimeError):
    """Raised when the configuration is missing or internally inconsistent."""


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def _as_bool(value: str) -> bool:
    low = value.strip().lower()
    if low in _TRUE:
        return True
    if low in _FALSE:
        return False
    raise ConfigError(f"expected a boolean, got {value!r}")


def _as_int(value: str, key: str) -> int:
    try:
        return int(str(value).strip())
    except ValueError as exc:
        raise ConfigError(f"{key} must be an integer, got {value!r}") from exc


@dataclass(frozen=True)
class Node:
    """One cluster host and the roles it runs."""

    host: str
    roles: frozenset[str]

    @property
    def is_cn(self) -> bool:
        return "cn" in self.roles

    @property
    def is_dn(self) -> bool:
        return "dn" in self.roles

    def __str__(self) -> str:  # pragma: no cover - display helper
        return f"{self.host}({'+'.join(sorted(self.roles))})"


def parse_nodes_file(path: Path) -> list[Node]:
    """Parse ``<role> <ip>`` lines (tab or whitespace separated)."""
    if not path.is_file():
        raise ConfigError(f"node inventory not found: {path}")

    nodes: list[Node] = []
    seen: dict[str, set[str]] = {}
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.replace("\t", " ").split()
        if len(parts) < 2:
            raise ConfigError(f"{path}:{lineno}: expected '<role> <ip>', got {raw!r}")
        role_token, host = parts[0].lower(), parts[1]
        roles = {r.strip() for r in role_token.replace("+", ",").split(",") if r.strip()}
        if not roles or not roles <= {"cn", "dn"}:
            raise ConfigError(f"{path}:{lineno}: role must be cn, dn or cn+dn, got {parts[0]!r}")
        seen.setdefault(host, set()).update(roles)

    for host, roles in seen.items():
        nodes.append(Node(host=host, roles=frozenset(roles)))
    if not nodes:
        raise ConfigError(f"node inventory {path} is empty")
    return nodes


@dataclass
class Config:
    path: Path
    values: dict[str, str] = field(default_factory=dict)
    nodes: list[Node] = field(default_factory=list)

    #: Set by the offline `smoketest` so that artifacts it writes can never be
    #: mistaken for the results of a real run.
    stub_run: bool = False

    #: Non-fatal problems worth telling the operator about, e.g. a NODES_FILE
    #: that is set but could not be read (the topology then silently came from
    #: DEPLOY_HOSTS, which is exactly the kind of thing that must not be quiet).
    notes: list[str] = field(default_factory=list)

    #: Where `nodes` came from, so a run can state the topology it actually
    #: used instead of leaving the operator to infer it from the inventory.
    nodes_origin: str = ""

    def nodes_source(self) -> str:
        return self.nodes_origin or "unset"

    # -- accessors ---------------------------------------------------------
    def raw(self, key: str, default: str = "") -> str:
        return self.values.get(key, default)

    def get(self, key: str) -> str:
        return self.values[key]

    def get_int(self, key: str) -> int:
        return _as_int(self.values[key], key)

    def get_bool(self, key: str) -> bool:
        return _as_bool(self.values[key])

    def get_list(self, key: str, sep: str = ",") -> list[str]:
        raw = self.values.get(key, "")
        return [item.strip() for item in raw.split(sep) if item.strip()]

    def path_value(self, key: str) -> Path:
        value = Path(self.values[key]).expanduser()
        if not value.is_absolute():
            value = (self.path.parent / value).resolve()
        return value

    # -- derived collections ----------------------------------------------
    @property
    def cn_hosts(self) -> list[str]:
        return [n.host for n in self.nodes if n.is_cn]

    @property
    def dn_hosts(self) -> list[str]:
        return [n.host for n in self.nodes if n.is_dn]

    @property
    def all_hosts(self) -> list[str]:
        return [n.host for n in self.nodes]

    @property
    def seed_cn(self) -> str:
        return self.cn_hosts[0]

    @property
    def seed_cn_endpoint(self) -> str:
        return f"{self.seed_cn}:{self.cn_internal_port}"

    @property
    def cn_internal_port(self) -> int:
        return self.get_int("CN_INTERNAL_PORT")

    @property
    def dn_internal_port(self) -> int:
        return self.get_int("DN_INTERNAL_PORT")

    @property
    def dn_rpc_port(self) -> int:
        return self.get_int("DN_RPC_PORT")

    @property
    def cli_host(self) -> str:
        """Host whose DataNode RPC endpoint the SQL client talks to."""
        if self.values.get("CLI_NODE"):
            return self.values["CLI_NODE"]
        return self.dn_hosts[0]

    @property
    def result_dir(self) -> Path:
        return self.path_value("RESULT_DIR")

    def validate(self, *, need_benchmark: bool = True) -> None:
        missing = [k for k in ("DB_DIR",) if not self.values.get(k)]
        if missing:
            raise ConfigError(f"missing required config keys: {', '.join(missing)}")
        if self.values["SSH_MODE"] not in {"key", "password"}:
            raise ConfigError("SSH_MODE must be 'key' or 'password'")
        if self.values["SSH_MODE"] == "password" and not self.values["SSH_PASSWORD"]:
            raise ConfigError("SSH_MODE=password requires SSH_PASSWORD")
        if need_benchmark and not self.values.get("BM_HOME"):
            raise ConfigError("BM_HOME is required (path to an iot-benchmark-iotdb-2.0 install)")
        if len(self.cn_hosts) < 1:
            raise ConfigError("no ConfigNode in the node inventory")
        if len(self.dn_hosts) < 1:
            raise ConfigError("no DataNode in the node inventory")
        if self.get_bool("CONSISTENCY_CHECK") and len(self.dn_hosts) < 3:
            raise ConfigError("CONSISTENCY_CHECK needs at least 3 DataNodes")
        if not self.values.get("MONITOR_URL"):
            self.values.setdefault("_SYNC_GATE_AVAILABLE", "false")
        else:
            self.values["_SYNC_GATE_AVAILABLE"] = "true"

    def db_version(self) -> str:
        """The database version under test, or "" when it cannot be told.

        Returning "" rather than raising keeps existing configurations working:
        an install directory like ``v20121rc2_0914_0b4dc9a`` carries no dotted
        version.  Callers that must know (the doctor check) treat "" as a
        problem; the workload set simply keeps the configured behaviour.
        """
        from .dbversion import VersionError, detect_db_version

        explicit = self.raw("DB_VERSION")
        try:
            return detect_db_version(
                explicit=explicit,
                tarball=self.raw("DEPLOY_TARBALL"),
                db_dir=self.raw("DB_DIR"),
            )
        except VersionError:
            return ""

    def benchmark_profile(self):
        """The benchmark build/workload profile for this database version."""
        from .dbversion import benchmark_profile

        version = self.db_version()
        return benchmark_profile(version) if version else None

    def bm_db_switch(self) -> str:
        """Which iot-benchmark database module to run against.

        The module bundles the client libraries for one database line, so it has
        to match the version under test.  An explicit BM_DB_SWITCH still wins,
        for the odd case where a build names its module differently.
        """
        explicit = self.raw("BM_DB_SWITCH")
        if explicit:
            return explicit
        profile = self.benchmark_profile()
        if profile is not None:
            return profile.db_switch
        return "IoTDB-200-SESSION_BY_TABLET"

    def benchmark_preflight(self) -> list[str]:
        """Problems that would make a benchmark run meaningless.

        Shared by `doctor` (which reports them) and `run`/`matrix` (which refuse
        to start): a benchmark built for the other database line cannot be
        detected from the outside -- it starts, connects, and fails in a way that
        looks like a cluster fault.  Returning problems rather than raising lets
        each caller choose between reporting and aborting.
        """
        from .dbversion import VersionError, check_benchmark_home, detect_db_version

        problems: list[str] = []
        try:
            version = detect_db_version(
                explicit=self.raw("DB_VERSION"),
                tarball=self.raw("DEPLOY_TARBALL"),
                db_dir=self.raw("DB_DIR"),
            )
        except VersionError as exc:
            return [str(exc)]
        profile = self.benchmark_profile()
        if profile is None or not self.raw("BM_HOME"):
            return problems
        bad = check_benchmark_home(Path(self.get("BM_HOME")).expanduser(), profile)
        if bad:
            problems.append(bad)
        return problems

    def workload_set(self) -> list[str]:
        allowed = {"tree", "table", "table_view"}
        wanted = self.get_list("BM_WORKLOADS")
        bad = [w for w in wanted if w not in allowed]
        if bad:
            raise ConfigError(f"BM_WORKLOADS has unknown entries: {bad}; allowed: {sorted(allowed)}")
        wanted = wanted or ["tree", "table"]
        # A 1.x database has no table model, so table workloads are dropped and
        # recorded rather than run against a dialect the server cannot serve.
        profile = self.benchmark_profile()
        if profile is None:
            return wanted
        from .dbversion import restrict_workloads

        usable, dropped = restrict_workloads(wanted, profile)
        if dropped:
            self.values["_BM_DROPPED_WORKLOADS"] = ",".join(dropped)
        return usable

    def resolve(self, value: str) -> Path:
        p = Path(value).expanduser()
        return p if p.is_absolute() else (self.path.parent / p).resolve()

    def __repr__(self) -> str:  # pragma: no cover
        return f"Config({self.path}, nodes={[str(n) for n in self.nodes]})"


def load_config(conf_path: str | os.PathLike[str]) -> Config:
    path = Path(conf_path).expanduser().resolve()
    if not path.is_file():
        raise ConfigError(
            f"config file not found: {path}\n"
            f"create it with: cp {SKILL_ROOT / 'conf' / 'cluster.conf.example'} {path}"
        )

    values = dict(DEFAULTS)
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.lower().startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise ConfigError(f"{path}:{lineno}: expected KEY=VALUE, got {raw!r}")
        key, _, value = line.partition("=")
        key = key.strip()
        if not key:
            raise ConfigError(f"{path}:{lineno}: empty key")
        values[key] = _unquote(value)

    # Ports are needed to build endpoints; discover them lazily but always
    # provide a sane default so Config.cn_internal_port never explodes.
    values.setdefault("CN_INTERNAL_PORT", "10710")
    values.setdefault("DN_INTERNAL_PORT", "10730")
    values.setdefault("DN_RPC_PORT", "6667")

    cfg = Config(path=path, values=values)

    nodes_file_raw = cfg.values.get("NODES_FILE", "").strip()
    nodes_file: Path | None = None
    if nodes_file_raw:
        candidate = Path(nodes_file_raw).expanduser()
        if candidate.is_absolute():
            if candidate.is_file():
                nodes_file = candidate
        else:
            # A relative NODES_FILE is documented as `conf/nodes.conf`, i.e.
            # relative to the directory `rcdn.sh` is run from (the skill root).
            # Resolving it against the *config file's* directory alone would
            # look for `conf/conf/nodes.conf` and silently fall through to
            # DEPLOY_HOSTS, so a hand-written topology would be ignored without
            # a word.  Try, in order: the working directory, the config file's
            # directory (for `--conf <dir>/cluster.conf`), then the skill root.
            for base in (Path.cwd(), path.parent, SKILL_ROOT):
                probe = (base / candidate).resolve()
                if probe.is_file():
                    nodes_file = probe
                    break
    if nodes_file is not None:
        cfg.nodes = parse_nodes_file(nodes_file)
        cfg.nodes_origin = f"NODES_FILE={nodes_file}"
    else:
        # Never fall back silently: the operator asked for a specific inventory.
        if nodes_file_raw:
            cfg.notes.append(
                f"NODES_FILE={nodes_file_raw!r} is set but could not be read "
                f"(tried the working directory, {path.parent} and {SKILL_ROOT}); "
                f"the topology came from DEPLOY_HOSTS/SEED_HOSTS instead."
            )
        # A fresh deployment has no cluster to discover from, so the topology
        # has to come from the config.  DEPLOY_HOSTS describes the usual shape
        # (one ConfigNode and one DataNode per host); SEED_HOSTS is the older
        # discovery-time equivalent and is still honoured.
        seeds = cfg.get_list("DEPLOY_HOSTS") or cfg.get_list("SEED_HOSTS")
        if not seeds:
            raise ConfigError(
                f"neither {nodes_file_raw!r} (resolved to {nodes_file}) exists, nor "
                "DEPLOY_HOSTS / SEED_HOSTS is set.\n"
                "Run `rcdn.sh discover` to generate the node inventory, or set "
                "DEPLOY_HOSTS for a fresh deployment."
            )
        cfg.nodes = [Node(host=h, roles=frozenset({"cn", "dn"})) for h in seeds]
        cfg.nodes_origin = (
            "DEPLOY_HOSTS" if cfg.get_list("DEPLOY_HOSTS") else "SEED_HOSTS"
        ) + " (one ConfigNode + one DataNode per host)"

    return cfg


def write_nodes_file(path: Path, nodes: Iterable[Node]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# generated by `rcdn.sh discover`", "# role<tab>internal-ip"]
    for node in nodes:
        roles = "+".join(sorted(node.roles, key=lambda r: (r != "cn", r)))
        lines.append(f"{roles}\t{node.host}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
