"""Deploy a TimechoDB / IoTDB cluster from a release tarball.

Same shape as the sibling skills: the tester supplies a release tarball, the
target hosts, an ssh user and the install path, and this module distributes,
unpacks, writes the ``first_start`` configuration and starts the cluster in the
only order IoTDB allows (seed ConfigNode first).

``schema_replication_factor`` / ``data_replication_factor`` /
``data_region_consensus_protocol_class`` are ``effectiveMode: first_start``:
they cannot be changed after the first start, so they are written before
anything is started.
"""

from __future__ import annotations

import re
import shlex
import time
from pathlib import Path

from .config import Config
from .remote import RemoteError, SshRunner

CONSENSUS_PROTOCOLS: dict[str, str] = {
    "iotconsensus": "org.apache.iotdb.consensus.iot.IoTConsensus",
    "iotv2": "org.apache.iotdb.consensus.iot.IoTConsensusV2",
    "iotconsensusv2": "org.apache.iotdb.consensus.iot.IoTConsensusV2",
}

DEFAULT_CONSENSUS = "iotconsensus"

DEFAULT_LICENSE_CODE_FILE = (
    "/data/deepseek/ai-bug-verify/skills/timechodb-rn-verify/references/activation.md"
)
_TRIAL_CODE = re.compile(r"\b(0[0-9]-[A-Za-z0-9=+./-]{8,})")


def start_order(cn_hosts: list[str], dn_hosts: list[str], seed: str) -> list[tuple[str, str]]:
    """The (host, role) pairs to start *after* the seed ConfigNode is up."""
    plan = [(host, "cn") for host in cn_hosts if host != seed]
    plan += [(host, "dn") for host in dn_hosts]
    return plan


class DeployError(RuntimeError):
    """A deployment step could not be completed."""


def consensus_class(name: str) -> str:
    key = re.sub(r"[\s_-]+", "", (name or "").strip().lower())
    if "." in key:
        key = key.rsplit(".", 1)[-1]
    if not key:
        key = DEFAULT_CONSENSUS
    if key not in CONSENSUS_PROTOCOLS:
        known = ", ".join(sorted(CONSENSUS_PROTOCOLS))
        raise DeployError(f"unknown consensus protocol {name!r}; known short names: {known}")
    return CONSENSUS_PROTOCOLS[key]


def resolve_license_code(spec: str, *, code_file: str = "") -> str:
    candidate = (spec or "").strip()
    if candidate and _TRIAL_CODE.fullmatch(candidate):
        return candidate
    path = Path(candidate) if candidate else Path(code_file or DEFAULT_LICENSE_CODE_FILE)
    if not path.is_file():
        raise DeployError(
            f"no activation code: {path} does not exist.  Pass LICENSE_CODE, or "
            "point LICENSE_CODE_FILE at a file containing one."
        )
    match = _TRIAL_CODE.search(path.read_text(encoding="utf-8", errors="replace"))
    if not match:
        raise DeployError(f"no activation code found in {path}")
    return match.group(1)


def tarball_command(remote_tarball: str, dest: str) -> str:
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

    @property
    def hosts(self) -> list[str]:
        seen: list[str] = []
        for host in list(self.cfg.cn_hosts) + list(self.cfg.dn_hosts):
            if host not in seen:
                seen.append(host)
        return seen

    def _remote_tarball(self, host: str) -> str:
        spec = self.cfg.get("DEPLOY_TARBALL")
        if not spec:
            raise DeployError("DEPLOY_TARBALL is not set; nothing to deploy from")
        local = Path(spec)
        remote = f"{self.cfg.get('DEPLOY_DIR')}/{local.name}"
        if not local.is_file():
            probe = self.ssh.run(host, f"test -f {shlex.quote(spec)}", check=False)
            if probe.ok:
                return spec
            raise DeployError(f"{spec} is neither a local file nor present on {host}")
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

    def unpack(self, *, clean: bool = False) -> None:
        deploy_dir = self.cfg.get("DEPLOY_DIR")
        db_dir = self.cfg.get("DB_DIR")
        for host in self.hosts:
            self.ssh.run(host, f"mkdir -p {shlex.quote(deploy_dir)}", check=False)
            tarball = self._remote_tarball(host)
            if clean:
                self.log(f"  {host}: removing any previous install at {db_dir}")
            staging = f"{deploy_dir}/.cmp-unpack"
            res = self.ssh.run_script(host, tarball_command(tarball, staging), check=False)
            if res.rc != 0:
                raise DeployError(f"unpacking failed on {host}: {res.text.strip()[:400]}")
            extra_clean = " ".join(shlex.quote(d) for d in (self.cfg.data_dirs[1:]
                                               if getattr(self.cfg, "two_disk", False) else []))
            script = f"""
set -e
extra_clean="{extra_clean}"
staging={shlex.quote(staging)}
inner=$(ls -A "$staging")
[[ -n "$inner" ]] || {{ echo "empty archive" >&2; exit 3; }}
# 先停掉可能仍在运行的旧进程（否则端口被占，新集群起不来 —— 实测会导致
# "the cluster did not become healthy" 以及后续 307 Schema write 失败）
for stopper in stop-confignode.sh stop-datanode.sh; do
  if [[ -x {shlex.quote(db_dir)}/sbin/$stopper ]]; then
    (cd {shlex.quote(db_dir)} && export IOTDB_HOME={shlex.quote(db_dir)} IOTDB_CONF={shlex.quote(db_dir)}/conf && sudo -n -E ./sbin/$stopper >/dev/null 2>&1) || true
  fi
done
# 按 PID 精确杀（不要用 `pkill -f <dir>`：远端 shell 自己的命令行也含该串，
# 会把自己杀掉，导致清理静默失败、旧进程继续持有 <dir>/.iotdb-lock，
# 新 DataNode 于是报 "Conflict is detected in directory ..."，集群起不来）
for pid in $(ps -eo pid,args --no-headers | awk -v d={shlex.quote(db_dir)} '/[j]ava/ && index($0, d) {{print $1}}'); do
  kill -9 "$pid" 2>/dev/null || true
done
for _ in $(seq 1 40); do
  n=$(ps -eo args --no-headers | awk -v d={shlex.quote(db_dir)} '/[j]ava/ && index($0, d) {{c++}} END {{print c+0}}')
  [[ "$n" == "0" ]] && break
  sleep 2
done
n=$(ps -eo args --no-headers | awk -v d={shlex.quote(db_dir)} '/[j]ava/ && index($0, d) {{c++}} END {{print c+0}}')
if [[ "$n" != "0" ]]; then
  echo "ERROR: $n IoTDB java process(es) still hold {shlex.quote(db_dir)}; refusing to continue" >&2
  exit 4
fi
# 清掉可能残留的目录占用标记（FileLock 会随进程消失，但文件本身可能留着）
find {shlex.quote(db_dir)} -maxdepth 5 -name '.iotdb-lock' -delete 2>/dev/null || true
if [[ -e {shlex.quote(db_dir)} ]]; then
  sudo -n rm -rf {shlex.quote(db_dir)} 2>/dev/null || rm -rf {shlex.quote(db_dir)}
fi
for extra in $extra_clean; do
  [[ -n "$extra" ]] || continue
  if [[ -e "$extra" ]]; then
    sudo -n rm -rf "$extra" 2>/dev/null || rm -rf "$extra"
  fi
  mkdir -p "$extra"
done
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
        klass = consensus_class(consensus)
        self.log(f"  consensus: {consensus} -> {klass}")
        self.cluster.configure(data_rf=data_rf, schema_rf=schema_rf)
        for host in self.hosts:
            self.cluster.apply_system_properties(
                host, {"data_region_consensus_protocol_class": klass}
            )

    def start(self, *, timeout: int | None = None, activate_code: str = "") -> bool:
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
            if role == "cn" or host not in self.cfg.cn_hosts:
                self.cluster.ensure_license(host)
            self.cluster.start_node(host, role)
        # 顺序要点：未激活的集群 DataNode 注册不上，wait_healthy 永远等不到，
        # 所以必须"先激活、再等健康"。activate() 自带重试并容忍连接类错误。
        if activate_code:
            self.activate(activate_code)
        healthy = self.cluster.wait_healthy(timeout=timeout)
        if not healthy and activate_code:
            self.activate(activate_code)
            healthy = self.cluster.wait_healthy(timeout=timeout)
        return healthy

    def _wait_seed(self, seed: str, *, timeout: int, interval: int = 5) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            res = self.ssh.run(seed, f"nc -z {shlex.quote(seed)} {self.cfg.cn_internal_port}",
                               check=False, timeout=30)
            if res.ok:
                return True
            time.sleep(interval)
        return False

    def activate(self, code: str, *, tries: int = 24) -> bool:
        """提交激活码：等 CLI 能应答后重试，判据是 license 落盘。

        连接类错误（集群还在起）不算失败，只重试；只有重试耗尽才报错，
        且把原始回复一起带出来，便于区分"码不被接受"和"集群没起来"。
        """
        if not code:
            self.log("  activation skipped")
            return True
        self.log("  submitting activation code (the code itself is not logged)")
        last = ""
        for attempt in range(1, tries + 1):
            if self.cluster._license_on_disk(self.cfg.cli_host):
                self.log(f"  license active on disk (attempt {attempt})")
                return True
            out = self.cluster.sql.sql(
                self.cfg.cli_host, f"activate '{code}'", check=False, timeout=120)
            last = out or ""
            if self.cluster._license_on_disk(self.cfg.cli_host):
                self.log(f"  activation accepted (attempt {attempt})")
                return True
            lowered = last.lower()
            transient = ("connection error" in lowered or "network" in lowered
                         or "not available" in lowered or "refused" in lowered
                         or not last.strip())
            if not transient:
                raise DeployError(f"activation rejected: {last.strip()[:300]}")
            if attempt in (1, tries):
                self.log(f"  activation not yet possible (attempt {attempt}/{tries}); retrying")
            time.sleep(5)
        # 重试耗尽仍只是"连不上/还没起来"时不要致命：把原文打出来，交给上层再试/由用例判定。
        self.log(f"  WARN: activation not confirmed after {tries} attempts; last reply: "
                 f"{last.strip()[:200]}")
        return False
