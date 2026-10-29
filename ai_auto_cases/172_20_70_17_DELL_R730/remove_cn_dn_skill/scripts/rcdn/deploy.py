"""Deploy a TimechoDB / IoTDB cluster from a release tarball.

This module exists so the skill can be driven by the minimum a tester actually
has: a release tarball, the target hosts, an ssh user and password, and the path
to install into.  Everything else -- distributing the tarball, unpacking it, the
``first_start`` configuration, the seed-first start order and activation -- is
done here.

Ordering is not a detail.  ``schema_replication_factor``,
``data_replication_factor``, the seed endpoints and
``data_region_consensus_protocol_class`` are all ``effectiveMode: first_start``:
IoTDB refuses to change them after the first start, and a cluster booted with
the wrong values has to be wiped and redeployed.  So the configuration is written
before anything is started, and the seed ConfigNode is confirmed up before any
other node is launched.
"""

from __future__ import annotations

import re
import shlex
import time
from pathlib import Path

from .config import Config
from .remote import RemoteError, SshRunner

# Short names accepted from the tester, mapped to the class IoTDB wants in
# `data_region_consensus_protocol_class`.  `IoTV2` is accepted because that is
# what the protocol is commonly called in test requests.
CONSENSUS_PROTOCOLS: dict[str, str] = {
    "iotconsensus": "org.apache.iotdb.consensus.iot.IoTConsensus",
    "iotv2": "org.apache.iotdb.consensus.iot.IoTConsensusV2",
    "iotconsensusv2": "org.apache.iotdb.consensus.iot.IoTConsensusV2",
}

DEFAULT_CONSENSUS = "iotconsensus"

# The skill repository keeps exactly one ready-made trial code, in the activation
# reference of `timechodb-rn-verify`.  Reading it from there keeps a single
# source of truth for the code instead of copying a licence string around.
DEFAULT_LICENSE_CODE_FILE = (
    "/data/deepseek/ai-bug-verify/skills/timechodb-rn-verify/references/activation.md"
)
_TRIAL_CODE = re.compile(r"\b(0[0-9]-[A-Za-z0-9=+./-]{8,})")


def start_order(cn_hosts: list[str], dn_hosts: list[str], seed: str) -> list[tuple[str, str]]:
    """The (host, role) pairs to start *after* the seed ConfigNode is up.

    A host that runs both roles appears twice on purpose: co-location does not
    merge the two nodes, because each is started by its own script
    (`start-confignode.sh` / `start-datanode.sh`).  Skipping the DataNode of a
    co-located host leaves the cluster short of DataNodes -- with
    schema_replication_factor=3 the ConfigNode then floods its log with
    NotEnoughDataNodeException and never allocates a SchemaRegion.
    """
    plan = [(host, "cn") for host in cn_hosts if host != seed]
    plan += [(host, "dn") for host in dn_hosts]
    return plan


class DeployError(RuntimeError):
    """A deployment step could not be completed."""


def consensus_class(name: str) -> str:
    """Map a short protocol name to the class name IoTDB expects.

    Accepts the names a tester is likely to say -- ``IoTConsensus``, ``IoTV2``,
    ``IoTConsensusV2`` -- case- and separator-insensitively.  An unknown name is
    rejected rather than silently defaulted: deploying with the wrong consensus
    protocol and then reporting results is worse than not deploying at all.
    """
    key = re.sub(r"[\s_-]+", "", (name or "").strip().lower())
    if not key:
        key = DEFAULT_CONSENSUS
    if key not in CONSENSUS_PROTOCOLS:
        known = ", ".join(sorted(CONSENSUS_PROTOCOLS))
        raise DeployError(
            f"unknown consensus protocol {name!r}; known short names: {known}"
        )
    return CONSENSUS_PROTOCOLS[key]


def resolve_license_code(spec: str, *, code_file: str = "") -> str:
    """Return the activation code to submit.

    ``spec`` may be the code itself, a file containing it, or empty -- in which
    case ``code_file`` (default: the skill repository's activation reference) is
    read.  Only the code is extracted, so the caller can point at documentation
    without having to keep a second copy of the licence string.
    """
    candidate = (spec or "").strip()
    if candidate and _TRIAL_CODE.fullmatch(candidate):
        return candidate
    path = Path(candidate) if candidate else Path(code_file or DEFAULT_LICENSE_CODE_FILE)
    if not path.is_file():
        raise DeployError(
            f"no activation code: {path} does not exist.  Pass LICENSE_CODE, or "
            "point LICENSE_CODE_FILE at a file containing one."
        )
    text = path.read_text(encoding="utf-8", errors="replace")
    match = _TRIAL_CODE.search(text)
    if not match:
        raise DeployError(f"no activation code found in {path}")
    return match.group(1)


def tarball_command(remote_tarball: str, dest: str) -> str:
    """Command that unpacks ``remote_tarball`` into ``dest``.

    The archive's single top-level directory is what actually gets moved into
    place, so the caller does not have to know the internal directory name.
    """
    quoted = shlex.quote(remote_tarball)
    return f"""
set -e
rm -rf {shlex.quote(dest)}
mkdir -p {shlex.quote(dest)}
case {quoted} in
  *.zip) unzip -q {quoted} -d {shlex.quote(dest)} ;;
  *.tar.gz|*.tgz) tar -xzf {quoted} -C {shlex.quote(dest)} ;;
  *.tar) tar -xf {quoted} -C {shlex.quote(dest)} ;;
  *) echo "unsupported archive: {remote_tarball}" >&2; exit 2 ;;
esac
entries=$(ls -A {shlex.quote(dest)} | wc -l)
if [[ "$entries" -ne 1 ]]; then
  echo "expected exactly one top-level directory, found $entries" >&2
  exit 3
fi
exit 0
"""


class Deployer:
    """Bring up a cluster from a release tarball on a set of hosts."""

    def __init__(self, cfg: Config, ssh: SshRunner, cluster, log) -> None:
        self.cfg = cfg
        self.ssh = ssh
        self.cluster = cluster
        self.log = log

    # -- helpers -----------------------------------------------------------
    @property
    def hosts(self) -> list[str]:
        seen: list[str] = []
        for host in list(self.cfg.cn_hosts) + list(self.cfg.dn_hosts):
            if host not in seen:
                seen.append(host)
        return seen

    def _remote_tarball(self, host: str) -> str:
        """Where the tarball lives on ``host``, uploading it if necessary."""
        spec = self.cfg.get("DEPLOY_TARBALL")
        if not spec:
            raise DeployError("DEPLOY_TARBALL is not set; nothing to deploy from")
        local = Path(spec)
        remote = f"{self.cfg.get('DEPLOY_DIR')}/{local.name}"
        if not local.is_file():
            # Not a local file: assume the tester put it on the nodes already.
            probe = self.ssh.run(host, f"test -f {shlex.quote(spec)}", check=False)
            if probe.ok:
                return spec
            raise DeployError(
                f"{spec} is neither a local file nor present on {host}"
            )
        size_mb = local.stat().st_size // (1024 * 1024)
        already = self.ssh.run(
            host,
            f"test -f {shlex.quote(remote)} && "
            f"[[ $(stat -c %s {shlex.quote(remote)}) -eq {local.stat().st_size} ]]",
            check=False,
        )
        if already.ok:
            self.log(f"  {host}: tarball already present ({size_mb} MiB), not re-uploading")
            return remote
        self.log(f"  {host}: uploading {local.name} ({size_mb} MiB)")
        self.ssh.upload(local, host, remote)
        return remote

    # -- stages ------------------------------------------------------------
    def unpack(self, *, clean: bool = False) -> None:
        """Put the release in place at DB_DIR on every host."""
        deploy_dir = self.cfg.get("DEPLOY_DIR")
        db_dir = self.cfg.get("DB_DIR")
        for host in self.hosts:
            self.ssh.run(host, f"mkdir -p {shlex.quote(deploy_dir)}", check=False)
            tarball = self._remote_tarball(host)
            if clean:
                self.log(f"  {host}: removing any previous install at {db_dir}")
            staging = f"{deploy_dir}/.rcdn-unpack"
            res = self.ssh.run_script(host, tarball_command(tarball, staging), check=False)
            if res.rc != 0:
                raise DeployError(f"unpacking failed on {host}: {res.text.strip()[:400]}")
            # Move the archive's single top-level directory into DB_DIR, so DB_DIR
            # is authoritative and the internal name never has to be guessed.
            script = f"""
set -e
staging={shlex.quote(staging)}
inner=$(ls -A "$staging")
[[ -n "$inner" ]] || {{ echo "empty archive" >&2; exit 3; }}
if [[ -e {shlex.quote(db_dir)} ]]; then
  sudo -n rm -rf {shlex.quote(db_dir)} 2>/dev/null || rm -rf {shlex.quote(db_dir)}
fi
sudo -n mv "$staging/$inner" {shlex.quote(db_dir)} 2>/dev/null || mv "$staging/$inner" {shlex.quote(db_dir)}
rmdir "$staging" 2>/dev/null || true
cd {shlex.quote(db_dir)}
chmod +x sbin/*.sh 2>/dev/null || sudo -n chmod +x sbin/*.sh
exit 0
"""
            res = self.ssh.run_script(host, script, check=False)
            if res.rc != 0:
                raise DeployError(f"installing to {db_dir} failed on {host}: {res.text[:400]}")
            self.log(f"  {host}: unpacked into {db_dir}")

    def configure(self, *, data_rf: int, schema_rf: int, consensus: str) -> None:
        """Write the first_start configuration, before anything is started."""
        klass = consensus_class(consensus)
        self.log(f"  consensus: {consensus} -> {klass}")
        self.cluster.configure(data_rf=data_rf, schema_rf=schema_rf)
        # `data_region_consensus_protocol_class` is read by the ConfigNode, but
        # the property file is shared by a co-located CN+DN, so writing it on
        # every host keeps the file self-consistent everywhere.
        for host in self.hosts:
            self.cluster.apply_system_properties(
                host, {"data_region_consensus_protocol_class": klass}
            )

    def start(self, *, timeout: int | None = None, activate_code: str = "") -> bool:
        """Start the seed ConfigNode first, then everything else.

        Only one hard constraint exists: during the first bootstrap the seed
        ConfigNode must be up before any other node tries to join.  Everything
        after that can be started in any order.

        ``activate_code`` is submitted once every node has been started but
        *before* the health wait.  An unactivated enterprise cluster parks every
        DataNode in ``ReadOnly(UNACTIVATED)``, so waiting for health first would
        wait forever; activation needs a running ConfigNode, which is already up
        at that point.
        """
        timeout = timeout or self.cfg.get_int("CLUSTER_START_TIMEOUT_SEC")
        seed = self.cfg.seed_cn
        if seed not in self.hosts:
            raise DeployError(f"seed ConfigNode {seed} is not among the deployment hosts")

        self.cluster.ensure_license(seed)
        self.cluster.start_node(seed, "cn")
        self.log(f"  waiting for the seed ConfigNode {seed} to answer")
        if not self._wait_seed(seed, timeout=min(timeout, 600)):
            raise DeployError(f"seed ConfigNode {seed} did not come up")

        for host, role in start_order(self.cfg.cn_hosts, self.cfg.dn_hosts, seed):
            # A co-located host was already licensed with its ConfigNode.
            if role == "cn" or host not in self.cfg.cn_hosts:
                self.cluster.ensure_license(host)
            self.cluster.start_node(host, role)
        if activate_code:
            self.activate(activate_code)
        return self.cluster.wait_healthy(timeout=timeout)

    def _wait_seed(self, seed: str, *, timeout: int, interval: int = 5) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            res = self.ssh.run(
                seed,
                f"nc -z {shlex.quote(seed)} {self.cfg.cn_internal_port}",
                check=False,
                timeout=30,
            )
            if res.ok:
                return True
            time.sleep(interval)
        return False

    def activate(self, code: str) -> bool:
        """Submit the activation code once; that activates the whole cluster."""
        if not code:
            self.log("  activation skipped")
            return True
        self.log("  submitting activation code (the code itself is not logged)")
        out = self.cluster.sql.sql(
            self.cfg.cli_host, f"activate '{code}'", check=False
        )
        lowered = out.lower()
        failed = ("error" in lowered) or ("exception" in lowered)
        if failed:
            raise DeployError(f"activation failed: {out.strip()[:300]}")
        self.log("  activation accepted")
        return True

    def deployment_summary(self, consensus: str) -> list[str]:
        return [
            f"deploy: {len(self.cfg.cn_hosts)} ConfigNode + {len(self.cfg.dn_hosts)} DataNode",
            f"deploy: db_dir={self.cfg.get('DB_DIR')}",
            f"deploy: schema_replication_factor={self.cfg.get_int('SCHEMA_REPLICATION_FACTOR')} "
            f"data_replication_factor={self.cfg.get_int('DATA_REPLICATION_FACTOR')}",
            f"deploy: data_region_consensus_protocol_class={consensus_class(consensus)}",
        ]
