"""Cluster topology, node lifecycle and configuration."""

from __future__ import annotations

import re
import shlex
import time
from dataclasses import dataclass, field
from pathlib import Path

from .config import Config, ConfigError, Node, write_nodes_file
from .remote import SqlClient, SshRunner, probe_port, wait_until

ROLE_CN = "cn"
ROLE_DN = "dn"

# System properties that must be set for a deterministic 3C5D test cluster.
BASE_CN_PROPS = {
    "cn_metric_reporter_list": "PROMETHEUS",
    "cn_metric_level": "IMPORTANT",
    "cn_metric_prometheus_reporter_port": "9091",
    "schema_region_group_extension_policy": "CUSTOM",
    "data_region_group_extension_policy": "CUSTOM",
    "default_schema_region_group_num_per_database": "1",
    "default_data_region_group_num_per_database": "5",
}
BASE_DN_PROPS = {
    "dn_metric_reporter_list": "PROMETHEUS",
    "dn_metric_level": "IMPORTANT",
    "dn_metric_prometheus_reporter_port": "9092",
    "schema_region_group_extension_policy": "CUSTOM",
    "data_region_group_extension_policy": "CUSTOM",
    "default_schema_region_group_num_per_database": "1",
    "default_data_region_group_num_per_database": "5",
    "datanode_memory_proportion": "1:5:1:1:1:1",
    # Keep auto repair compaction off: it can rewrite files while a remove is
    # migrating regions, which muddies the consistency comparison.
    "enable_auto_repair_compaction": "false",
}

_ACTIVE_PROP = re.compile(r"^\s*([A-Za-z0-9_.]+)\s*=\s*(.*?)\s*$")


def split_status(raw: str) -> tuple[str, str]:
    """Split an IoTDB node status into ``(base, qualifier)``.

    IoTDB qualifies some states -- an unactivated enterprise node reports
    ``ReadOnly(UNACTIVATED)``. Comparing the whole string against ``readonly``
    therefore never matches, which is how a perfectly healthy-but-unactivated
    cluster looks like one that never comes up.

    The qualifier is returned rather than thrown away: ``UNACTIVATED`` is real
    information (the licence has not been submitted), not noise.
    """
    text = (raw or "").strip()
    if text.endswith(")") and "(" in text:
        base, _, qualifier = text.partition("(")
        return base.strip().lower(), qualifier[:-1].strip()
    return text.lower(), ""


def status_is(raw: str, *wanted: str) -> bool:
    """Whether ``raw``'s base status is one of ``wanted`` (case-insensitive)."""
    return split_status(raw)[0] in {w.lower() for w in wanted}


@dataclass
class ClusterStatus:
    rows: list[dict[str, str]] = field(default_factory=list)

    def by_type(self, node_type: str) -> list[dict[str, str]]:
        return [r for r in self.rows if r.get("NodeType", "").lower() == node_type.lower()]

    @property
    def cn_rows(self) -> list[dict[str, str]]:
        return self.by_type("ConfigNode")

    @property
    def dn_rows(self) -> list[dict[str, str]]:
        return self.by_type("DataNode")

    def summary(self) -> str:
        return ", ".join(
            f"{r.get('NodeType')}#{r.get('NodeID')}@{r.get('InternalAddress')}={r.get('Status')}"
            for r in self.rows
        )


class Cluster:
    """Lifecycle and introspection for the IoTDB cluster under test."""

    def __init__(self, cfg: Config, ssh: SshRunner, sql: SqlClient, log):
        self.cfg = cfg
        self.ssh = ssh
        self.sql = sql
        self.log = log
        self.db_dir = cfg.get("DB_DIR")

    # ------------------------------------------------------------------
    # Topology
    # ------------------------------------------------------------------
    def discover_ports(self) -> None:
        """Read the real internal/RPC ports from a ConfigNode host."""
        script = f"""
set -e
f={shlex.quote(self.db_dir)}/conf/iotdb-system.properties
[[ -f "$f" ]] || exit 2
for k in cn_internal_port dn_internal_port dn_rpc_port; do
  v=$(grep -E "^[[:space:]]*$k[[:space:]]*=" "$f" | head -1 | cut -d= -f2- | tr -d '[:space:]')
  [[ -n "$v" ]] && printf '%s=%s\\n' "$k" "$v"
done
exit 0
"""
        host = self.cfg.cn_hosts[0]
        res = self.ssh.run_script(host, script, check=False)
        if res.rc != 0 or not res.out.strip():
            self.log(f"  port discovery on {host} returned nothing, keeping configured defaults")
            return
        for line in res.out.splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                mapped = {
                    "cn_internal_port": "CN_INTERNAL_PORT",
                    "dn_internal_port": "DN_INTERNAL_PORT",
                    "dn_rpc_port": "DN_RPC_PORT",
                }[key.strip()]
                if value.strip().isdigit():
                    self.cfg.values[mapped] = value.strip()
        self.log(
            f"  ports: cn_internal={self.cfg.cn_internal_port} "
            f"dn_internal={self.cfg.dn_internal_port} dn_rpc={self.cfg.dn_rpc_port}"
        )

    def discover_from_cluster(self, *, include_stopped: bool = False) -> list[Node]:
        """Derive the inventory from a live cluster (SHOW CLUSTER)."""
        host = self.cfg.cli_host
        rows = self.sql.show_cluster(host)
        if not rows:
            raise ConfigError(
                f"could not read the cluster topology from {host}; "
                "start the cluster or supply conf/nodes.conf by hand"
            )
        roles: dict[str, set[str]] = {}
        for row in rows:
            status = (row.get("Status") or "").strip()
            if not include_stopped and status.lower() not in {"running", "readonly"}:
                continue
            ip = (row.get("InternalAddress") or "").strip()
            ntype = (row.get("NodeType") or "").strip().lower()
            if not ip:
                continue
            role = ROLE_CN if ntype.startswith("config") else ROLE_DN
            roles.setdefault(ip, set()).add(role)
        nodes = [Node(host=h, roles=frozenset(sorted(r))) for h, r in roles.items()]
        nodes.sort(key=lambda n: (not n.is_cn, n.host))
        return nodes

    def discover_from_inventory(self, hosts: list[str]) -> list[Node]:
        """Probe each host and decide whether it runs a ConfigNode, DataNode or both.

        Detection is layered because a plain user usually cannot see the Java
        processes and because the shipped ``iotdb-system.properties`` leaves
        both ``cn_internal_address`` and ``dn_rpc_address`` uncommented on every
        host, so the file alone cannot tell the roles apart:

        1. ``sudo jps`` / ``jps`` process names
        2. the on-disk data directories (``data/confignode`` / ``data/datanode``)
        3. the log file names
        4. the listening internal ports
        5. the declared roles already present in NODES_FILE

        A host for which nothing can be detected keeps its declared role; if it
        has none, it is reported and skipped rather than guessed.
        """
        declared = {n.host: set(n.roles) for n in self.cfg.nodes}
        script = f"""
d={shlex.quote(self.db_dir)}
roles=""
add() {{ case ",$roles," in *",$1,"*) ;; *) roles="$roles,$1";; esac; }}

jpsout=$(sudo jps -l 2>/dev/null || jps -l 2>/dev/null || true)
echo "$jpsout" | grep -qi 'ConfigNode' && add cn
echo "$jpsout" | grep -qi 'DataNode' && add dn

if [[ ! -d "$d/data" && -z "$roles" ]]; then :; fi
[[ -d "$d/data/confignode" ]] && add cn
[[ -d "$d/data/datanode" ]] && add dn

ls "$d/logs" 2>/dev/null | grep -qi 'confignode' && add cn
ls "$d/logs" 2>/dev/null | grep -qi 'datanode' && add dn

if command -v ss >/dev/null 2>&1; then
  ss -lnt 2>/dev/null | grep -q ':10710' && add cn
  ss -lnt 2>/dev/null | grep -q ':10730' && add dn
fi

printf 'ROLES=%s\\n' "${{roles#,}}"
printf 'VERSION=%s\\n' "$(ls "$d/lib" 2>/dev/null | grep -oE 'timechodb-server-[0-9]+([.][0-9]+)+' | head -1)"
exit 0
"""
        nodes: list[Node] = []
        for host in hosts:
            if not probe_port(host, self.cfg.get_int("SSH_PORT"), timeout=3):
                raise ConfigError(f"host {host} is not reachable on the ssh port")
            res = self.ssh.run_script(host, script, check=False)
            roles: set[str] = set()
            version = ""
            for line in res.out.splitlines():
                if line.startswith("ROLES="):
                    roles = {r for r in line[6:].strip().split(",") if r in {ROLE_CN, ROLE_DN}}
                elif line.startswith("VERSION="):
                    version = line[8:].strip()
            source = "detected"
            if not roles:
                roles = set(declared.get(host, set()))
                source = "declared"
            if not roles:
                self.log(f"  {host}: no IoTDB role detected under {self.db_dir}, skipped")
                continue
            self.log(f"  {host:<16} {'+'.join(sorted(roles)):<6} ({source}{', ' + version if version else ''})")
            nodes.append(Node(host=host, roles=frozenset(roles)))
        if not nodes:
            raise ConfigError(
                "no IoTDB node could be identified. On a cluster that has never started, "
                "no local state exists to detect the roles: write conf/nodes.conf by hand "
                "(or copy conf/cluster.conf.example) using the documented '<role> <ip>' format."
            )
        nodes.sort(key=lambda n: (not n.is_cn, n.host))
        return nodes

    def save_inventory(self, nodes: list[Node]) -> Path:
        target = self.cfg.path_value("NODES_FILE")
        write_nodes_file(target, nodes)
        return target

    # ------------------------------------------------------------------
    # Remote file helpers
    # ------------------------------------------------------------------
    def read_system_properties(self, host: str) -> dict[str, str]:
        res = self.ssh.run(
            host,
            f"cat {shlex.quote(self.db_dir)}/conf/iotdb-system.properties 2>/dev/null || true",
            check=False,
        )
        props: dict[str, str] = {}
        for line in res.out.splitlines():
            m = _ACTIVE_PROP.match(line)
            if m:
                props[m.group(1)] = m.group(2)
        return props

    def clear_raised_disk_thresholds(self, hosts: list[str]) -> list[str]:
        """Comment out any ACTIVE ``disk_space_warning_threshold`` line.

        ``SET CONFIGURATION`` **persists to iotdb-system.properties** -- it is
        not merely a hot reload.  A case that raises the threshold and then dies
        before restoring it therefore leaves the node permanently believing its
        disk is full: it flips to ``ReadOnly(DiskFull)`` as soon as anything
        writes to it.  Measured 2026-09-18: one leaked raise poisoned eight
        consecutive cases, and the first visible symptom was an unrelated case
        reporting "benchmark objects were not created within 900s".

        The shipped default (0.05) applies when the key is absent, so commenting
        the line out *is* the restore.  Returns the hosts that had to be fixed,
        so a caller can say so out loud instead of healing in silence.
        """
        if not hosts:
            return []
        script = f"""
d={shlex.quote(self.db_dir)}
f="$d/conf/iotdb-system.properties"
[[ -f "$f" ]] || exit 0
if [[ -w "$f" ]]; then SUDO=""; else SUDO="sudo -n"; fi
if grep -qE '^[[:space:]]*disk_space_warning_threshold[[:space:]]*=' "$f"; then
  $SUDO sed -i -E 's|^[[:space:]]*disk_space_warning_threshold[[:space:]]*=.*|#disk_space_warning_threshold=0.05|' "$f"
  echo FIXED
fi
exit 0
"""
        fixed: list[str] = []
        for host in hosts:
            res = self.ssh.run_script(host, script, check=False)
            if "FIXED" in (res.out or ""):
                fixed.append(host)
        return fixed

    def apply_system_properties(self, host: str, updates: dict[str, str]) -> None:
        """Set (or append) keys in the remote ``iotdb-system.properties``."""
        payload = "\n".join(f"{k}\t{v}" for k, v in updates.items())
        script = f"""
set -e
d={shlex.quote(self.db_dir)}
f="$d/conf/iotdb-system.properties"
[[ -f "$f" ]] || {{ echo "MISSING $f" >&2; exit 2; }}
# The conf directory may be root owned; fall back to sudo -n.
if [[ -w "$f" ]]; then SUDO=""; else SUDO="sudo -n"; fi
while IFS=$'\\t' read -r k v; do
  [[ -z "$k" ]] && continue
  if grep -qE "^[[:space:]]*#?[[:space:]]*${{k}}[[:space:]]*=" "$f"; then
    $SUDO sed -i -E "s|^[[:space:]]*#?[[:space:]]*${{k}}[[:space:]]*=.*|${{k}}=${{v}}|" "$f"
  else
    printf '%s=%s\\n' "$k" "$v" | $SUDO tee -a "$f" > /dev/null
  fi
done <<'RCDN_PROPS'
{payload}
RCDN_PROPS
exit 0
"""
        res = self.ssh.run_script(host, script, check=False)
        if res.rc != 0:
            raise RuntimeError(f"failed to update iotdb-system.properties on {host}: {res.text}")

    def apply_env(self, host: str, role: str, heap: str, off_heap: str) -> None:
        """Set ON_HEAP_MEMORY / OFF_HEAP_MEMORY in the node's env file."""
        env_file = "confignode-env.sh" if role == ROLE_CN else "datanode-env.sh"
        script = f"""
set -e
f={shlex.quote(self.db_dir)}/{env_file}
[[ -f "$f" ]] || exit 0
if [[ -w "$f" ]]; then SUDO=""; else SUDO="sudo -n"; fi
set_kv() {{
  local key=$1 value=$2
  if grep -qE "^[[:space:]]*#?[[:space:]]*${{key}}=" "$f"; then
    $SUDO sed -i -E "s|^[[:space:]]*#?[[:space:]]*${{key}}=.*|${{key}}=\"${{value}}\"|" "$f"
  else
    printf '%s=\"%s\"\\n' "$key" "$value" | $SUDO tee -a "$f" > /dev/null
  fi
}}
set_kv ON_HEAP_MEMORY {shlex.quote(heap)}
set_kv OFF_HEAP_MEMORY {shlex.quote(off_heap)}
exit 0
"""
        res = self.ssh.run_script(host, script, check=False)
        if res.rc != 0:
            raise RuntimeError(f"failed to update {env_file} on {host}: {res.text}")

    # ------------------------------------------------------------------
    # Configuration
    # ------------------------------------------------------------------
    def ensure_executable(self) -> list[str]:
        """Restore exec bits on sbin/*.sh; unpacked tarballs often lose them."""
        fixed: list[str] = []
        db_dir = shlex.quote(self.cfg.get("DB_DIR"))
        for host in self.cfg.all_hosts:
            self.ssh.run(
                host,
                f"cd {db_dir} && chmod +x sbin/*.sh 2>/dev/null || sudo -n chmod +x sbin/*.sh",
                timeout=120,
                check=False,
            )
            fixed.append(host)
        return fixed

    def _base_props(self, base: dict) -> dict:
        """BASE_*_PROPS 去掉扩容策略/配额键（``PG_SKIP_ALL_KNOBS=true`` 时）。

        这两组基线键（``*_region_group_extension_policy=CUSTOM`` 与
        ``default_*_region_group_num_per_database``）是从 3C5D 包继承下来的**harness 口径**，
        不是产品必填项。要证明某个缺陷与「扩容策略/配额」无关，集群就必须只用发布包模板的
        默认值（不写任何策略键），因此这个开关下把它们一并去掉。
        """
        if (self.cfg.raw("PG_SKIP_ALL_KNOBS") or "").strip().lower() in ("1", "true", "yes"):
            return {k: v for k, v in base.items()
                    if "extension_policy" not in k
                    and "region_group_num_per_database" not in k}
        return base

    def configure(self, *, data_rf: int, schema_rf: int) -> None:
        seed = self.cfg.seed_cn_endpoint
        self.log(f"  seed config node: {seed}")
        for host in self.cfg.cn_hosts:
            self.apply_env(host, ROLE_CN, self.cfg.get("CN_HEAP"), self.cfg.get("CN_OFF_HEAP"))
            updates = self._base_props(BASE_CN_PROPS)
            updates.update(
                {
                    "cluster_name": self.cfg.raw("CLUSTER_NAME", "defaultCluster"),
                    "cn_seed_config_node": seed,
                    "cn_internal_address": host,
                    "cn_internal_port": str(self.cfg.cn_internal_port),
                    "schema_replication_factor": str(schema_rf),
                    "data_replication_factor": str(data_rf),
                }
            )
            self.apply_system_properties(host, updates)
        for host in self.cfg.dn_hosts:
            self.apply_env(host, ROLE_DN, self.cfg.get("DN_HEAP"), self.cfg.get("DN_OFF_HEAP"))
            updates = self._base_props(BASE_DN_PROPS)
            updates.update(
                {
                    "cluster_name": self.cfg.raw("CLUSTER_NAME", "defaultCluster"),
                    "dn_seed_config_node": seed,
                    "dn_internal_address": host,
                    "dn_internal_port": str(self.cfg.dn_internal_port),
                    "dn_rpc_address": host,
                    "dn_rpc_port": str(self.cfg.dn_rpc_port),
                    "schema_replication_factor": str(schema_rf),
                    "data_replication_factor": str(data_rf),
                }
            )
            self.apply_system_properties(host, updates)

    # ------------------------------------------------------------------
    # Node lifecycle
    # ------------------------------------------------------------------
    def node_pids(self, host: str, role: str) -> list[int]:
        """PIDs of the role's Java process on ``host``.

        IoTDB normally runs as root, so a plain ``jps`` run by an unprivileged
        user only sees itself; ``sudo -n jps`` is tried first.
        """
        # ``timeout 20``：``jps`` 会对每个 JVM 发 attach 请求，目标 JVM 正在退出
        # （stop-datanode 刚发出信号的窗口）时会卡在 attach 上不返回；实测这种卡顿
        # 让 25 节点的 stop_all 停在那一步数分钟。超时后按"没有该角色的进程"处理，
        # 后续的 ``stop_node`` 仍会用自己的等待判据确认。
        res = self.ssh.run(
            host,
            "timeout 20 sudo -n jps -l 2>/dev/null || timeout 20 jps -l 2>/dev/null || true",
            check=False, timeout=60,
        )
        needle = "config" if role == ROLE_CN else "datanode"
        pids: list[int] = []
        for line in res.out.splitlines():
            parts = line.split()
            if not parts:
                continue
            low = line.lower()
            if "jps" in low or "jdk.jcmd" in low:
                continue
            if needle in low:
                try:
                    pids.append(int(parts[0]))
                except ValueError:
                    continue
        return pids

    def node_running(self, host: str, role: str) -> bool:
        return bool(self.node_pids(host, role))

    def start_node(self, host: str, role: str) -> None:
        stamp = int(time.time())
        script_name = "start-confignode.sh" if role == ROLE_CN else "start-datanode.sh"
        heap_dump = f"{self.db_dir}/{'cn' if role == ROLE_CN else 'dn'}_{stamp}_heapdump.hprof"
        # 显式指定 JAVA_HOME/PATH：这些机器的非交互 ssh 环境里 java 可能缺失
        # （.6/.8/.9 完全没有），也可能指到过旧的 JDK（.10 指到 jdk-11，而
        # IoTDB 2.0.12 需要 Java 17 → 启动脚本只打印 "IoTDB requires Java 17 or later."
        # 就退出，DataNode 静默不启动）。用 conf 的 JAVA_HOME 统一覆盖。
        java_home = (self.cfg.raw("JAVA_HOME") or "").strip()
        java_env = ""
        if java_home:
            java_env = (f"export JAVA_HOME={shlex.quote(java_home)}; "
                        f'export PATH={shlex.quote(java_home)}/bin:"$PATH"; ')
        script = f"""
set -e
cd {shlex.quote(self.db_dir)}
{java_env}export IOTDB_HOME={shlex.quote(self.db_dir)} IOTDB_CONF={shlex.quote(self.db_dir)}/conf; nohup sudo -n -E ./sbin/{script_name} -H {shlex.quote(heap_dump)} > /dev/null 2>&1 &
exit 0
"""
        self.ssh.run_script(host, script, check=False)
        self.log(f"  started {role} on {host}")

    def stop_node(self, host: str, role: str, *, timeout: int | None = None) -> bool:
        timeout = timeout or self.cfg.get_int("CLUSTER_STOP_TIMEOUT_SEC")
        script_name = "stop-confignode.sh" if role == ROLE_CN else "stop-datanode.sh"
        self.ssh.run(
            host,
            f"cd {shlex.quote(self.db_dir)} && export IOTDB_HOME={shlex.quote(self.db_dir)} IOTDB_CONF={shlex.quote(self.db_dir)}/conf && sudo -n -E ./sbin/{script_name}",
            timeout=timeout,
            check=False,
        )
        return wait_until(
            lambda: not self.node_running(host, role),
            timeout=timeout,
            interval=2,
        )

    def kill_node(self, host: str, role: str) -> bool:
        """kill -9 every process of the role on ``host``."""
        script = f"""
pids=$(jps -l 2>/dev/null | grep -i {'config' if role == ROLE_CN else 'datanode'} | grep -v Jps | awk '{{print $1}}')
[[ -z "$pids" ]] && exit 0
for p in $pids; do sudo -n kill -9 "$p" 2>/dev/null || kill -9 "$p" 2>/dev/null || true; done
exit 0
"""
        self.ssh.run_script(host, script, check=False)
        return wait_until(lambda: not self.node_running(host, role), timeout=60, interval=2)

    def ensure_license(self, host: str) -> None:
        src = self.cfg.raw("LICENSE_SRC")
        if not src:
            return
        script = f"""
set -e
d={shlex.quote(self.db_dir)}
mkdir -p "$d/activation"
if [[ -f "$d/activation/license" ]]; then exit 0; fi
if [[ -f {shlex.quote(src)} ]]; then
  cp -fp {shlex.quote(src)} "$d/activation/license"
elif [[ -f "$d/../timecho_license_new" ]]; then
  cp -fp "$d/../timecho_license_new" "$d/activation/license"
  [[ -f "$d/../.env" ]] && cp -fp "$d/../.env" "$d/" || true
else
  echo "no license source found" >&2
  exit 3
fi
exit 0
"""
        self.ssh.run_script(host, script, check=False)

    # ------------------------------------------------------------------
    # Whole-cluster operations
    # ------------------------------------------------------------------
    def stop_all(self, *, clean: bool = False) -> None:
        for host in self.cfg.dn_hosts:
            if self.node_running(host, ROLE_DN):
                self.stop_node(host, ROLE_DN)
        for host in self.cfg.cn_hosts:
            if self.node_running(host, ROLE_CN):
                self.stop_node(host, ROLE_CN)
        # A DataNode co-located with a ConfigNode may still be alive.
        for host in self.cfg.cn_hosts:
            if self.node_running(host, ROLE_DN):
                self.stop_node(host, ROLE_DN)

    def wipe(self) -> None:
        """Remove data/ and logs/ and restore conf from conf_orig on every host."""
        for host in self.cfg.all_hosts:
            script = f"""
d={shlex.quote(self.db_dir)}
sudo -n rm -rf "$d/data" "$d/logs" 2>/dev/null || true
if [[ -d "$d/conf_orig" ]]; then
  sudo -n rm -rf "$d/conf"
  sudo -n cp -rp "$d/conf_orig" "$d/conf"
fi
sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
exit 0
"""
            self.ssh.run_script(host, script, check=False)

    def start_all(self, *, timeout: int | None = None, exclude_dn: set[str] | None = None) -> bool:
        """Start every node, optionally leaving some DataNodes down.

        `exclude_dn` holds hosts back so a case can join them later as the
        expansion node -- that is how the `adding` case gets a spare without a
        host outside `nodes.conf`.
        """
        timeout = timeout or self.cfg.get_int("CLUSTER_START_TIMEOUT_SEC")
        excluded = set(exclude_dn or ())
        for host in self.cfg.cn_hosts:
            self.ensure_license(host)
            self.start_node(host, ROLE_CN)
        # 先等 ConfigNode 侧可用（选主完成、`show cluster` 能答），再拉起 DataNode。
        # 否则新库/新集群上 DataNode 会在 "Cannot pull system configurations from
        # ConfigNode-leader after 200 retries" 之后直接退出（实测 V2 全新库：.113 在
        # 启动 2s 后就退出，整个 prepare 卡在等 25 节点）。
        seed_ok = wait_until(
            lambda: "|" in (self.sql.sql(self.cfg.cli_host, "show cluster", check=False,
                                         timeout=60) or ""),
            timeout=min(600, max(120, timeout // 3)), interval=5)
        self.log(f"  ConfigNode answering before DataNodes start: {seed_ok}")
        for host in self.cfg.dn_hosts:
            if host in excluded:
                continue
            if host not in self.cfg.cn_hosts:
                self.ensure_license(host)
            self.start_node(host, ROLE_DN)
        # 启动后立刻掉队的 DataNode 救一次：实测 20 台同时拉起时偶发
        #   ERROR DataNode:419 - Fail to start server
        #   StartupException: Reject DataNode restart. Because the nodeId of the
        #   current DataNode is -1.  1. Delete "data" dir and retry.
        # 成因是首次启动写了 system.properties 却还没落 data_node_id 就退出，
        # 下一次启动判成"重启"，读不到 node id ⇒ CN 直接拒绝。产品自己给的解法是
        # 删掉该节点的 system.properties（不是整个 data 目录，避免丢数据）。
        # 只对这一种"刚拉起来就没进程"的情况重试一次，不影响故障类用例。
        self._revive_dead_dn(excluded)
        # 没激活的集群永远不会 healthy（CN 侧 "License has been set/given up"
        # → PartitionManager "Extend region group failed" → DN 注册不上）。
        # 激活落盘后重启自动恢复，因此这一步通常只在全新部署时需要。
        self.activate_license()
        return self.wait_healthy(timeout=timeout, exclude_dn=excluded)

    def _revive_dead_dn(self, excluded: set[str]) -> None:
        """拉起后没有进程的 DataNode：删掉 system.properties 再启一次。"""
        dead = []
        for host in self.cfg.dn_hosts:
            if host in excluded:
                continue
            if not self.node_running(host, ROLE_DN):
                dead.append(host)
        if not dead:
            return
        self.log(f"  {len(dead)} DataNode(s) not running after start: {dead}; reviving once")
        for host in dead:
            self.ssh.run(
                host,
                f"rm -f {shlex.quote(self.db_dir)}/data/datanode/system/system.properties",
                check=False, timeout=60)
            self.start_node(host, ROLE_DN)
        wait_until(
            lambda: all(self.node_running(h, ROLE_DN) for h in dead),
            timeout=300, interval=3)

    def dn_uptime_seconds(self, host: str | None = None) -> float:
        """被查 DataNode 的 java 进程已运行秒数（拿不到返回 -1）。"""
        host = host or (self.cfg.dn_hosts or self.cfg.all_hosts)[0]
        res = self.ssh.run(
            host,
            "ps -eo etimes,args --no-headers | awk -v d=" + shlex.quote(self.db_dir)
            + " '/[j]ava/ && /DataNode/ && index($0,d){print $1; exit}'",
            check=False,
        )
        try:
            return float((res.out or "").strip().splitlines()[0])
        except (ValueError, IndexError):
            return -1.0

    def _license_on_disk(self, host: str) -> bool:
        res = self.ssh.run(
            host,
            f"test -s {shlex.quote(self.db_dir)}/activation/license && echo YES || echo NO",
            check=False,
        )
        return "YES" in res.out

    def activate_license(self, *, tries: int | None = None) -> bool:
        """用 `LICENSE_CODE` 激活集群（2.0.10.1+ 用内置 `03` 试用码）。

        `activate` 由 ConfigNode 的激活服务处理，同一张码只需一次即全集群生效；
        "激活落盘，重启自动恢复"，所以判据取 `<DB_DIR>/activation/license` 是否非空。
        """
        code = (self.cfg.raw("LICENSE_CODE") or "").strip()
        if not code:
            return True
        raw = (self.cfg.raw("LICENSE_ACTIVATE_TRIES") or "").strip()
        tries = tries or (int(raw) if raw.isdigit() else 18)
        target = self.cfg.cli_host
        for attempt in range(1, tries + 1):
            if self._license_on_disk(target):
                self.log(f"  license already active on {target}")
                return True
            out = self.sql.sql(target, f"activate '{code}';", check=False, timeout=120)
            if self._license_on_disk(target):
                self.log(f"  license activated via {target} (attempt {attempt})")
                return True
            if attempt in (1, tries):
                tail = (out or "").strip().splitlines()
                self.log(f"  activating license ... attempt {attempt}/{tries}"
                         + (f" last reply: {tail[-1][:110]}" if tail else " (no reply yet)"))
            time.sleep(5)
        self.log("  WARN: license activation not confirmed; "
                 "the cluster will report UNACTIVATED until a code is accepted")
        return False

    def dn_metrics_port(self) -> int:
        """Read the DataNode metrics exporter port from a node's conf.

        `METRICS_PORT` wins when set to a positive value; otherwise ask a
        DataNode, so the sync-lag gate follows whatever the cluster was
        actually deployed with instead of a hard-coded guess.
        """
        configured = self.cfg.get_int("METRICS_PORT")
        if configured > 0:
            return configured
        host = (self.cfg.dn_hosts or self.cfg.all_hosts)[0]
        key = "dn_metric_prometheus_reporter_port"
        res = self.ssh.run(
            host,
            f"grep -E '^[[:space:]]*{key}[[:space:]]*=' "
            f"{shlex.quote(self.db_dir)}/conf/iotdb-system.properties "
            f"2>/dev/null | tail -1",
            check=False,
        )
        _, _, value = res.out.strip().partition("=")
        try:
            return int(value.strip())
        except ValueError:
            return 9091

    def expected_node_count(self, *, exclude_dn: set[str] | None = None) -> int:
        excluded = set(exclude_dn or ())
        return len(self.cfg.cn_hosts) + len([h for h in self.cfg.dn_hosts if h not in excluded])

    def status(self) -> ClusterStatus:
        rows = self.sql.show_cluster(self.cfg.cli_host)
        return ClusterStatus(rows=rows)

    def wait_healthy(
        self, *, timeout: int, interval: int = 5, exclude_dn: set[str] | None = None
    ) -> bool:
        expected = self.expected_node_count(exclude_dn=exclude_dn)
        self.log(f"  waiting for {expected} nodes to report Running/ReadOnly (<= {timeout}s)")

        def ready() -> bool:
            try:
                rows = self.sql.show_cluster(self.cfg.cli_host)
            except Exception:
                return False
            # Base status only: `ReadOnly(UNACTIVATED)` is a ReadOnly node, and
            # an unactivated cluster is exactly the state this gate sees first.
            ok = [r for r in rows if status_is(r.get("Status"), "running", "readonly")]
            return len(ok) >= expected

        return wait_until(ready, timeout=timeout, interval=interval)

    # ------------------------------------------------------------------
    # Node lookups against SHOW DATANODES / SHOW CONFIGNODES
    # ------------------------------------------------------------------
    def datanodes(self, host: str | None = None) -> list[dict[str, str]]:
        return self.sql.show_datanodes(host or self.cfg.cli_host)

    def confignodes(self, host: str | None = None) -> list[dict[str, str]]:
        return self.sql.show_confignodes(host or self.cfg.cli_host)

    @staticmethod
    def row_ip(row: dict[str, str]) -> str:
        """Public alias of :meth:`_row_ip` for callers outside this module."""
        return Cluster._row_ip(row)

    @staticmethod
    def _row_ip(row: dict[str, str]) -> str:
        return (row.get("RpcAddress") or row.get("InternalAddress") or "").strip()

    def dn_id_for(self, ip: str, host: str | None = None) -> str | None:
        for row in self.datanodes(host):
            if self._row_ip(row) == ip:
                return (row.get("NodeID") or "").strip()
        return None

    def cn_id_for(self, ip: str, host: str | None = None) -> str | None:
        for row in self.confignodes(host):
            if (row.get("InternalAddress") or "").strip() == ip:
                return (row.get("NodeID") or "").strip()
        return None

    def running_dn_hosts(self, host: str | None = None) -> list[str]:
        out: list[str] = []
        for row in self.datanodes(host):
            # A ReadOnly node is still up and serving reads; only Unknown/Stopped
            # are gone.  Matching on the bare status would hide a disk-full or
            # unactivated node from every liveness and survivor check.
            if status_is(row.get("Status"), "running", "readonly"):
                ip = self._row_ip(row)
                if ip and ip not in out:
                    out.append(ip)
        return out

    def running_cn_hosts(self, host: str | None = None) -> list[str]:
        out: list[str] = []
        for row in self.confignodes(host):
            if status_is(row.get("Status"), "running", "readonly"):
                ip = (row.get("InternalAddress") or "").strip()
                if ip and ip not in out:
                    out.append(ip)
        return out

    def leader_cn_host(self, host: str | None = None) -> str | None:
        for row in self.confignodes(host):
            if (row.get("Role") or "").strip().lower() == "leader":
                return (row.get("InternalAddress") or "").strip()
        return None

    def dn_status_for(self, ip: str, host: str | None = None) -> str | None:
        for row in self.datanodes(host):
            if self._row_ip(row) == ip:
                return (row.get("Status") or "").strip()
        return None

    def cn_status_for(self, ip: str, host: str | None = None) -> str | None:
        for row in self.confignodes(host):
            if (row.get("InternalAddress") or "").strip() == ip:
                return (row.get("Status") or "").strip()
        return None
