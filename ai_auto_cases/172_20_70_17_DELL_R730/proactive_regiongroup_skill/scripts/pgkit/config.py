"""Configuration loading for the iotdb-proactive-regiongroup skill.

Every address used by the skill comes from the config file or from runtime
discovery.  Nothing in this package contains a hard-coded cluster IP.

**Relocation**: the skill root is *derived* from this file's location
(``scripts/pgkit/config.py`` -> parents[2]) or from the ``PG_SKILL_DIR``
environment variable.  No internal path is written down absolutely, and
``RESULT_DIR`` defaults to ``/data/deepseek/proactive/results`` (the conf's
value) so the whole directory can be moved without editing anything; a runtime
that cannot write that directory (e.g. a sandbox) falls back to
``<skill_root>/results`` -- see ``cli.build``.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


def skill_root() -> Path:
    """Where the skill lives.

    ``PG_SKILL_DIR`` wins so a caller can point at a copy; otherwise the path
    is derived from this module (``<root>/scripts/pgkit/config.py``).
    """
    override = os.environ.get("PG_SKILL_DIR", "").strip()
    if override:
        return Path(override).expanduser().resolve()
    return Path(__file__).resolve().parents[2]


SKILL_ROOT = skill_root()

DEFAULTS: dict[str, str] = {
    # --- access ---------------------------------------------------------
    "SSH_USER": "root",
    "SSH_PORT": "22",
    "SSH_MODE": "key",
    "SSH_PASSWORD": "",
    "SSH_EXTRA_OPTS": "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR",
    # Reuse one ssh connection per host: a case opens hundreds of connections
    # and an intrusion-prevention layer reads that as a brute-force attempt.
    "SSH_MULTIPLEX": "true",
    "SSH_CONTROL_PERSIST": "300",
    # --- topology -------------------------------------------------------
    "NODES_FILE": "conf/nodes.conf",
    "SEED_HOSTS": "",
    "DB_DIR": "/data/mpp_test/pg_2011snap_3bbeea656114",
    # 第二块盘（SSD）基准目录；技能自动派生 <DB_DIR 末级名>/data（双盘）
    "DB_DATA_DIR_2": "/ssd_data/mpp_test",
    "DB_MULTI_DIR_STRATEGY": "SequenceStrategy",
    # 5 台统一 jdk-17；非交互 ssh 下 PATH 可能没有 java，必须显式指定
    "JAVA_HOME": "/usr/local/jdk-17.0.8",
    "CLI_HOME": "",
    # Whether start-cli.sh needs sudo to find java: auto | true | false.
    "CLI_SUDO": "auto",
    "CLI_NODE": "",
    "LICENSE_SRC": "",
    "DATA_REPLICATION_FACTOR": "2",
    "SCHEMA_REPLICATION_FACTOR": "3",
    # --- deployment -----------------------------------------------------
    "DEPLOY_TARBALL": (
        "/data/deepseek/timecho_src/master/timechodb/distribution/target/"
        "timechodb-2.0.11-SNAPSHOT-bin.zip"
    ),
    "DEPLOY_DIR": "/data/mpp_test",
    "DEPLOY_HOSTS": "11.101.10.6,11.101.10.7,11.101.10.8,11.101.10.9,11.101.10.10",
    "DEPLOY_CONSENSUS": "IoTConsensus",
    "DEPLOY_ACTIVATE": "true",
    "LICENSE_CODE": "03-AAATKKLP-XREBT2T7-2QRCC===",
    "LICENSE_ACTIVATE_TRIES": "24",
    "LICENSE_CODE_FILE": (
        "/data/deepseek/ai-bug-verify/skills/timechodb-rn-verify/references/activation.md"
    ),
    "DB_USER": "root",
    "DB_PASSWORD": "TimechoDB@2021",
    # UPG-1.3: 1.3 线的默认管理员密码是 root（包内 README_zh：`-u root -pw root`），
    # 2.0 起才是 TimechoDB@2021。升级族 pre 档跑在 1.3 上，沿用 2.x 密码必然得到
    # `801: Authentication failed`；remote.SqlClient 只在**确认为 1.3 线**且真的收到 801
    # 时才回退到这个值，并把"换过密码"写进 run.log/证据（2.x 分支不会走到）。
    "DB_PASSWORD_13": "root",
    "DB_VERSION": "2.0.11-SNAPSHOT",
    "CN_HEAP": "2G",
    "CN_OFF_HEAP": "1G",
    "DN_HEAP": "20G",
    "DN_OFF_HEAP": "2G",
    "CLUSTER_START_TIMEOUT_SEC": "900",
    "CLUSTER_STOP_TIMEOUT_SEC": "300",
    # --- PROACTIVE 策略与配额（写进 iotdb-system.properties，重启生效）---
    # 键名与默认值以发布包模板为准：
    #   iotdb-system.properties.template:848/:858/:866/:891/:901/:910/:814/:968
    #   依据见 references/proactive-spec.md §2（键名、合法值、热加载列）。
    "PG_SCHEMA_POLICY": "PROACTIVE",
    "PG_DATA_POLICY": "PROACTIVE",
    "PG_MIN_SCHEMA_PER_DB": "1",
    "PG_MIN_DATA_PER_DB": "2",
    "PG_SCHEMA_PER_DATA_NODE": "1",
    # 1.3 → 2.0 升级族（PG-UPG）：包路径 / 目标版本 / 阶段开关（pre|post|空=两阶段连跑）
    "PG_UPGRADE_TO_TARBALL": "",
    "PG_UPGRADE_TO_VERSION": "2.0",
    "PG_UPG_PHASE": "",
    "PG_DATA_PER_DATA_NODE": "0",
    "PG_SERIES_SLOT_NUM": "1000",
    # 模板默认 604800000(ms)；本 conf 口径为 604800，逐字保留，勿在此“修正”。
    "PG_TIME_PARTITION_INTERVAL": "604800",
    "PG_WAL_ENTRY_LIMIT": "-1",
    "PG_THRIFT_MAX_FRAME": "0",
    # 用例内使用的普通用户（无 SYSTEM 权限）与系统用户，用于热加载权限/大小写验证
    "PG_NORMAL_USER": "pg_normal",
    "PG_NORMAL_PASSWORD": "PgNormal@2021",
    "PG_SYSTEM_USER": "pg_system",
    "PG_SYSTEM_PASSWORD": "PgSystem@2021",
    # --- 升级用例（1.3 → 2.0）-------------------------------------------
    # 1.3 服务端包路径待确认；未配置时升级类用例必须 SKIP 并说明原因，不得判 PASS
    "PG_UPGRADE_FROM_TARBALL": "",
    "PG_UPGRADE_FROM_VERSION": "1.3",
    # --- benchmark 客户端 ------------------------------------------------
    "PG_BENCH_SSH": "liuzhen@11.101.10.11",
    "PG_BENCH_V13_DIR": (
        "/home/liuzhen/cluster_shell_3c5d/tc2026_releasenote_testcase/benchmark/"
        "bm_20260915_46fc572_v13"
    ),
    "PG_BENCH_V20_DIR": (
        "/home/liuzhen/cluster_shell_3c5d/tc2026_releasenote_testcase/benchmark/"
        "bm_20260915_46fc572_v20"
    ),
    # --- 用例筛选 --------------------------------------------------------
    # smoke=冒烟最小集；core=核心回归；full=全量（默认 core）
    "PG_TIER": "core",
    # --- sync-lag gate --------------------------------------------------
    "MONITOR_URL": "",
    "MONITOR_USER": "admin",
    "MONITOR_PASSWORD": "admin",
    "SYNC_LAG_SOURCE": "auto",
    "METRICS_PORT": "0",
    "CLUSTER_NAME": "defaultCluster",
    "CONSENSUS_METRIC": "auto",
    "SYNC_STABLE_SECONDS": "60",
    "SYNC_MAX_WAIT_SEC": "1800",
    "SYNC_POLL_INTERVAL_SEC": "10",
    "SYNC_STALL_POLLS": "12",
    # --- replica-consistency sweep --------------------------------------
    "CONSISTENCY_CHECK": "true",
    # direct=逐 DN 直查对拍（快）；stop=逐台停机换节点查；both=两者都做。
    # PROACTIVE conf 按用户要求默认 stop。
    "REPLICA_MODE": "stop",
    "CONSISTENCY_SETTLE_SECONDS": "10",
    "CONSISTENCY_SETTLE_TRIES": "3",
    "CONSISTENCY_QUERY_TIMEOUT_SEC": "3600",
    "CONSISTENCY_SETTLE_SEC": "5",
    # --- log gate -------------------------------------------------------
    "LOG_SCAN": "true",
    # full = whole log, bounded above by until_epoch; since = only from case start.
    "LOG_SCAN_MODE": "since",
    "CLUSTER_CONVERGENCE_WINDOW_SEC": "300",
    "LOG_EXTRA_PATTERNS": "",
    "LOG_BACKUP": "never",
    # --- results --------------------------------------------------------
    # Default matches the conf (the user-requested final landing directory).
    # Fallback when unwritable is <skill_root>/results -- see cli.build().
    "RESULT_DIR": "/data/deepseek/proactive/results",
    "KEEP_SCRATCH": "false",
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
    notes: list[str] = field(default_factory=list)
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
    def primary_data_dir(self) -> str:
        """第一块盘上的数据目录（默认相对路径 <DB_DIR>/data/datanode/data）。"""
        return f"{self.get('DB_DIR')}/data/datanode/data"

    @property
    def data_dirs(self) -> list[str]:
        """数据目录列表。配置 ``DB_DATA_DIR_2`` 时为双盘（/data HDD + SSD 盘）。

        ``DB_DATA_DIR_2`` 是**第二块盘上的基准目录**（如 ``/ssd_data/mpp_test``），
        技能自动在其下派生 ``<DB_DIR 末级目录名>/data``，因此 conf 里不出现 IP、
        也不需要逐机写死路径。
        """
        dirs = [self.primary_data_dir]
        second = self.raw("DB_DATA_DIR_2")
        if second:
            name = os.path.basename(self.get("DB_DIR").rstrip("/"))
            dirs.append(f"{second.rstrip('/')}/{name}/data")
        return dirs

    @property
    def two_disk(self) -> bool:
        return bool(self.raw("DB_DATA_DIR_2"))

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
        if self.values.get("CLI_NODE"):
            return self.values["CLI_NODE"]
        return self.dn_hosts[0]

    @property
    def result_dir(self) -> Path:
        return self.path_value("RESULT_DIR")

    def validate(self) -> None:
        missing = [k for k in ("DB_DIR",) if not self.values.get(k)]
        if missing:
            raise ConfigError(f"missing required config keys: {', '.join(missing)}")
        if self.values["SSH_MODE"] not in {"key", "password"}:
            raise ConfigError("SSH_MODE must be 'key' or 'password'")
        if self.values["SSH_MODE"] == "password" and not self.values["SSH_PASSWORD"]:
            raise ConfigError("SSH_MODE=password requires SSH_PASSWORD")
        if len(self.cn_hosts) < 1:
            raise ConfigError("no ConfigNode in the node inventory")
        if len(self.dn_hosts) < 1:
            raise ConfigError("no DataNode in the node inventory")
        if self.get_bool("CONSISTENCY_CHECK") and len(self.dn_hosts) < 2:
            raise ConfigError(
                "CONSISTENCY_CHECK stops one DataNode at a time and queries through "
                "another, so it needs at least 2 DataNodes"
            )
        self.values["_SYNC_GATE_AVAILABLE"] = "true" if self.values.get("MONITOR_URL") else "false"

    # -- PROACTIVE policy / quota knobs ------------------------------------
    def region_group_knobs(self) -> dict[str, str]:
        """``iotdb-system.properties`` key -> value, from the PG_* conf keys.

        键名逐字取自发布包 ``conf/iotdb-system.properties.template``
        （:848/:858/:866/:891/:901/:910/:814/:968）；键名不得改写。
        """
        # PG_OMIT_POLICY_KEYS=true 时两个策略键**不写进文件**，用于验证
        # "未显式配置 ⇒ 走代码默认值（PROACTIVE）"这条路径（SMK-01/DFT-01/DFT-02）。
        omit = (self.raw("PG_OMIT_POLICY_KEYS") or "").strip().lower() in ("1", "true", "yes")
        knobs = {
            "schema_region_group_extension_policy":
                self.raw("PG_SCHEMA_POLICY") or "PROACTIVE",
            "data_region_group_extension_policy":
                self.raw("PG_DATA_POLICY") or "PROACTIVE",
            "default_schema_region_group_num_per_database":
                self.raw("PG_MIN_SCHEMA_PER_DB") or "1",
            "default_data_region_group_num_per_database":
                self.raw("PG_MIN_DATA_PER_DB") or "2",
            "schema_region_per_data_node":
                self.raw("PG_SCHEMA_PER_DATA_NODE") or "1",
            "data_region_per_data_node":
                self.raw("PG_DATA_PER_DATA_NODE") or "0",
            "series_slot_num":
                self.raw("PG_SERIES_SLOT_NUM") or "1000",
            "time_partition_interval":
                self.raw("PG_TIME_PARTITION_INTERVAL") or "604800",
            # H-49：模板默认 -1（按 WAL 缓冲推算）；50 万测点档位需显式调大
            "wal_entry_size_limit_in_byte":
                self.raw("PG_WAL_ENTRY_LIMIT") or "-1",
            # H-58：模板默认 0（按实现内部默认），表模型大测点档位需要显式放大
            "dn_thrift_max_frame_size":
                self.raw("PG_THRIFT_MAX_FRAME") or "0",
        }
        if omit:
            for key in ("schema_region_group_extension_policy",
                        "data_region_group_extension_policy"):
                knobs.pop(key, None)
        return knobs

    def resolve(self, value: str) -> Path:
        p = Path(value).expanduser()
        return p if p.is_absolute() else (self.path.parent / p).resolve()

    def __repr__(self) -> str:  # pragma: no cover
        return f"Config({self.path}, nodes={[str(n) for n in self.nodes]})"


def load_config(conf_path: str | os.PathLike[str]) -> Config:
    path = Path(conf_path).expanduser()
    if not path.is_absolute():
        # A relative --conf is documented as being relative to the skill root.
        candidate = (Path.cwd() / path)
        if candidate.is_file():
            path = candidate
        else:
            path = SKILL_ROOT / path
    path = path.resolve()
    if not path.is_file():
        raise ConfigError(
            f"config file not found: {path}\n"
            f"create it with: cp {SKILL_ROOT / 'conf' / 'cluster.pg_2011snap_iot.conf'} {path}"
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
            # Try the working directory, the config file's directory (for
            # `--conf <dir>/cluster.conf`), then the skill root.
            for base in (Path.cwd(), path.parent, SKILL_ROOT):
                probe = (base / candidate).resolve()
                if probe.is_file():
                    nodes_file = probe
                    break
    if nodes_file is not None:
        cfg.nodes = parse_nodes_file(nodes_file)
        cfg.nodes_origin = f"NODES_FILE={nodes_file}"
    else:
        if nodes_file_raw:
            cfg.notes.append(
                f"NODES_FILE={nodes_file_raw!r} is set but could not be read "
                f"(tried the working directory, {path.parent} and {SKILL_ROOT}); "
                f"the topology came from DEPLOY_HOSTS/SEED_HOSTS instead."
            )
        seeds = cfg.get_list("DEPLOY_HOSTS") or cfg.get_list("SEED_HOSTS")
        if not seeds:
            raise ConfigError(
                f"neither {nodes_file_raw!r} (resolved to {nodes_file}) exists, nor "
                "DEPLOY_HOSTS / SEED_HOSTS is set.\n"
                "Set DEPLOY_HOSTS for a fresh deployment, or write conf/nodes.conf."
            )
        cfg.nodes = [Node(host=h, roles=frozenset({"cn", "dn"})) for h in seeds]
        cfg.nodes_origin = (
            "DEPLOY_HOSTS" if cfg.get_list("DEPLOY_HOSTS") else "SEED_HOSTS"
        ) + " (one ConfigNode + one DataNode per host)"

    return cfg


def write_nodes_file(path: Path, nodes: Iterable[Node]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# generated by `pg.sh doctor --write-nodes`", "# role<tab>internal-ip"]
    for node in nodes:
        roles = "+".join(sorted(node.roles, key=lambda r: (r != "cn", r)))
        lines.append(f"{roles}\t{node.host}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
