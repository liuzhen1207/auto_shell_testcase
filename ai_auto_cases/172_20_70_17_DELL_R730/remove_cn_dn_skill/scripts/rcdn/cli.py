"""Command line interface for the iotdb-remove-cn-dn skill."""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import sys
import time
from dataclasses import replace
from pathlib import Path

from .cases import FAIL, PASS, SKIP, Case, CaseRunner, load_cases
from .cluster import Cluster
from .benchfetch import (
    FetchError,
    asset_name,
    default_home,
    describe_release,
    download,
    fetch_releases,
    install_zip,
    pick_asset,
)
from .dbversion import VersionError, benchmark_profile, check_benchmark_home
from .deploy import Deployer, DeployError, consensus_class, resolve_license_code
from .config import SKILL_ROOT, Config, ConfigError, load_config
from .remote import SqlClient, SshRunner, http_get_text
from .verify import Verifier

DEFAULT_CASES = SKILL_ROOT / "cases" / "remove_cases.tsv"


class Logger:
    def __init__(self, quiet: bool = False, logfile: Path | None = None):
        self.quiet = quiet
        self.logfile = logfile
        if logfile:
            logfile.parent.mkdir(parents=True, exist_ok=True)

    def __call__(self, message: str = "") -> None:
        line = f"{time.strftime('%H:%M:%S')} {message}"
        if not self.quiet:
            print(line, flush=True)
        if self.logfile:
            with self.logfile.open("a", encoding="utf-8") as fh:
                fh.write(line + "\n")


def _build(cfg: Config, run_id: str, quiet: bool):
    results_root = cfg.result_dir / run_id
    results_root.mkdir(parents=True, exist_ok=True)
    log = Logger(quiet=quiet, logfile=results_root / "run.log")
    ssh = SshRunner(cfg, results_root / "scratch")
    sql = SqlClient(cfg, ssh, results_root / "scratch")
    return results_root, log, ssh, sql


def _new_run_id(prefix: str = "run") -> str:
    return f"{prefix}_{time.strftime('%Y%m%d_%H%M%S')}"


def _stop_stale_load(cfg: Config, log, kill: bool = True) -> list[str]:
    """Deal with benchmark load left behind by an earlier, dead run.

    A leftover writer keeps the dataset moving after the load is stopped, which
    the case then reports as "the dataset never settled" -- a failure that says
    nothing about the database and costs a full case.  ``doctor`` reports without
    touching the machine (``kill=False``); ``run``/``matrix`` stop it before the
    first case.  Details in the stale-load section of benchmark.py.
    """
    from .benchmark import kill_stale_workloads

    stale = kill_stale_workloads(cfg.result_dir, log, kill=kill)
    return [
        f"stale benchmark pid={pid} from an earlier run is still writing to the cluster"
        for pid, _ in stale
    ]


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def cmd_doctor(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    results_root, log, ssh, sql = _build(cfg, _new_run_id("doctor"), args.quiet)
    problems: list[str] = []
    cluster = Cluster(cfg, ssh, sql, log)

    log(f"config          : {cfg.path}")
    log(f"ssh user/mode   : {cfg.get('SSH_USER')} / {cfg.get('SSH_MODE')}")
    log(f"db dir          : {cfg.get('DB_DIR')}")
    log(f"nodes           : {', '.join(str(n) for n in cfg.nodes)}")
    log(f"nodes source    : {cfg.nodes_source()}")

    # A NODES_FILE that is set but unreadable changes the whole topology, so it
    # must be loud rather than a silent fall back to DEPLOY_HOSTS.
    for note in cfg.notes:
        log(f"WARNING         : {note}")
        problems.append(note)

    for host in cfg.all_hosts:
        ok = ssh.ping(host)
        log(f"  ssh {host:<16} {'OK' if ok else 'UNREACHABLE'}")
        if not ok:
            problems.append(f"cannot ssh into {host}")
            continue
        res = ssh.run(host, f"test -d {cfg.get('DB_DIR')} && echo present", check=False)
        if "present" not in res.out:
            problems.append(f"{cfg.get('DB_DIR')} is missing on {host}")
            log(f"    {cfg.get('DB_DIR')} MISSING")
            continue
        res2 = ssh.run(
            host,
            f"test -f {cfg.get('DB_DIR')}/conf/iotdb-system.properties && echo conf-ok",
            check=False,
        )
        log(f"    conf: {'OK' if 'conf-ok' in res2.out else 'MISSING'}")
        sudo = ssh.run(host, "sudo -n true 2>/dev/null && echo sudo-ok", check=False, timeout=30)
        if "sudo-ok" in sudo.out:
            log("    sudo: passwordless OK")
        else:
            problems.append(f"{host}: passwordless sudo is required to start/stop and wipe IoTDB")
            log("    sudo: NOT passwordless")

    try:
        log(f"sql client      : {sql.check_available()}")
    except ConfigError as exc:
        problems.append(str(exc))
        log(f"sql client      : ERROR {exc}")

    if cfg.raw("BM_HOME"):
        bm = Path(cfg.get("BM_HOME")).expanduser()
        log(f"benchmark home  : {bm} {'OK' if (bm / 'benchmark.sh').is_file() else 'MISSING benchmark.sh'}")
        if not (bm / "benchmark.sh").is_file():
            problems.append(f"BM_HOME {bm} does not contain benchmark.sh")
    else:
        log("benchmark home  : not configured")

    # The benchmark module must match the database line: a build carrying only
    # `iotdb-2.0` starts happily against a 1.x database and then fails at
    # connect time, which reads like a cluster fault.  The judgement itself lives
    # in Config.benchmark_preflight so that doctor, run and matrix cannot drift
    # apart; this block only adds the detail worth showing.
    version = cfg.db_version()
    profile = cfg.benchmark_profile()
    if not version:
        log("database version: UNKNOWN")
    else:
        log(f"database version: {version} ({profile.line})")
        log(f"benchmark module: {profile.module} via {cfg.bm_db_switch()}")
        log(f"workloads       : {','.join(cfg.workload_set())}")
        dropped = cfg.raw("_BM_DROPPED_WORKLOADS")
        if dropped:
            log(f"                  (dropped, no table model in {profile.line}: {dropped})")
    for problem in cfg.benchmark_preflight():
        log(f"benchmark match : PROBLEM -- {problem}")
        problems.append(problem)
    if version and cfg.raw("BM_HOME") and not cfg.benchmark_preflight():
        log("benchmark match : OK")

    _report_sync_lag_source(cfg, cluster, log, problems)

    # Report (do not kill: doctor changes nothing) load left over from a dead run.
    problems.extend(_stop_stale_load(cfg, log, kill=False))

    log("")
    if problems:
        log(f"doctor: {len(problems)} problem(s)")
        for problem in problems:
            log(f"  - {problem}")
        return 2
    log("doctor: all preconditions look satisfied")
    return 0


def _report_sync_lag_source(cfg: Config, cluster: Cluster, log, problems: list[str]) -> None:
    """Confirm that syncLag can actually be read, from either source."""
    from .verify import SyncLagWaiter

    source = cfg.raw("SYNC_LAG_SOURCE", "auto").lower()
    url = cfg.raw("MONITOR_URL")
    try:
        port = cluster.dn_metrics_port()
    except Exception as exc:  # noqa: BLE001
        problems.append(f"cannot determine the DataNode metrics port: {exc}")
        log("sync lag        : could not resolve the DataNode metrics port")
        return

    if source != "prometheus" and (source == "metrics" or not url):
        if port <= 0:
            problems.append("METRICS_PORT is not set and MONITOR_URL is empty: no sync-lag source")
            log("sync lag        : NO SOURCE -> the gate would be skipped")
            return
        try:
            running = cluster.running_dn_hosts()
        except Exception as exc:  # noqa: BLE001 - cluster may simply be down
            first = " ".join(str(exc).split())
            problems.append(f"cannot list DataNodes (is the cluster running?): {first}")
            log(f"sync lag        : DataNode /metrics :{port} -> cluster unreachable")
            return
        if not running:
            log(f"sync lag        : DataNode /metrics :{port} selected, but no DataNode is Running")
            return
        waiter = SyncLagWaiter(cfg, cluster, lambda m: None)
        host = running[0]
        try:
            samples = waiter._query_metrics(host, *waiter.METRIC_CANDIDATES[0])
        except Exception as exc:  # noqa: BLE001
            problems.append(
                f"cannot read syncLag from http://{host}:{port}/metrics ({exc}); "
                "set MONITOR_URL or the correct METRICS_PORT"
            )
            log(f"sync lag        : DataNode /metrics :{port} UNREADABLE")
            return
        log(
            f"sync lag        : DataNode /metrics :{port} OK "
            f"({len(running)} node(s), {len(samples)} series on {host})"
        )
        return

    if not url:
        log("sync lag        : not configured -> the gate will be skipped (cases become PARTIAL)")
        return
    try:
        import urllib.parse

        from .remote import http_get_json

        probe = url + "/api/v1/query?" + urllib.parse.urlencode({"query": "up"})
        payload = http_get_json(
            probe, user=cfg.get("MONITOR_USER"), password=cfg.get("MONITOR_PASSWORD"), timeout=15
        )
        if payload.get("status") != "success":
            problems.append(f"Prometheus at {url} answered with an error: {payload.get('error')}")
            log(f"sync lag        : Prometheus {url} ERROR")
        else:
            log(f"sync lag        : Prometheus {url} OK")
    except Exception as exc:  # noqa: BLE001
        problems.append(f"cannot reach Prometheus at {url}: {exc}")
        log(f"sync lag        : Prometheus {url} UNREACHABLE")


def cmd_discover(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    results_root, log, ssh, sql = _build(cfg, _new_run_id("discover"), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)

    if args.from_cluster:
        log("discovering the topology from the live cluster")
        nodes = cluster.discover_from_cluster(include_stopped=args.include_stopped)
    else:
        hosts = cfg.get_list("SEED_HOSTS")
        if not hosts:
            hosts = cfg.all_hosts
        log(f"probing {len(hosts)} host(s) for an IoTDB installation")
        nodes = cluster.discover_from_inventory(hosts)

    for node in nodes:
        log(f"  {node.host:<16} {'+'.join(sorted(node.roles))}")
    target = cluster.save_inventory(nodes)
    log(f"inventory written to {target}")
    cluster.discover_ports()
    return 0


def cmd_prepare(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    results_root, log, ssh, sql = _build(cfg, _new_run_id("prepare"), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)
    cluster.discover_ports()
    log("stopping any running node")
    cluster.stop_all()
    log("wiping data and logs")
    cluster.wipe()
    data_rf = int(args.data_rf) if args.data_rf else cfg.get_int("DATA_REPLICATION_FACTOR")
    schema_rf = int(args.schema_rf) if args.schema_rf else cfg.get_int("SCHEMA_REPLICATION_FACTOR")
    log(f"writing configuration (data_rf={data_rf}, schema_rf={schema_rf})")
    cluster.configure(data_rf=data_rf, schema_rf=schema_rf)
    # Installations unpacked from a tarball frequently lose their exec bits;
    # repairing here keeps every later case from tripping over "command not found".
    cluster.ensure_executable()
    log("starting the cluster")
    if not cluster.start_all():
        log("FAILED: the cluster did not become healthy")
        return 1
    # A wipe deletes data/, and on some builds the activation state lives under
    # data/ too.  `start_all()` does call `ensure_license()`, but that helper
    # short-circuits as soon as activation/license exists -- and wipe() keeps
    # activation/ -- so nothing re-submits the code and the cluster returns
    # logging "Load license fail. / This license is not allowed to activate this
    # ConfigNode".  Measured on 2.0.12.1: the wipe alone turned a healthy 3C5D
    # into an unactivated one, after which REMOVE CONFIGNODE never completed and
    # timed out at 600 s.  Re-submitting the code is idempotent, so do it always.
    if cfg.get_bool("DEPLOY_ACTIVATE") and not args.no_activate:
        try:
            code = resolve_license_code(
                cfg.raw("LICENSE_CODE"), code_file=cfg.raw("LICENSE_CODE_FILE")
            )
        except DeployError as exc:
            log(f"WARNING: no activation code ({exc}); a wiped cluster may stay unactivated")
        else:
            log("re-submitting the activation code; a wipe can clear the activation state")
            out = cluster.sql.sql(cfg.cli_host, f"activate '{code}'", check=False)
            lowered = out.lower()
            if "error" in lowered or "exception" in lowered:
                log(f"WARNING: activation was rejected: {out.strip()[:300]}")
            else:
                log("activation accepted")
    log(f"cluster is healthy: {cluster.status().summary()}")
    return 0


def cmd_deploy(args: argparse.Namespace) -> int:
    """Build the cluster from a release tarball, then activate it."""
    cfg = load_config(args.conf)
    results_root, log, ssh, sql = _build(cfg, _new_run_id("deploy"), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)
    deployer = Deployer(cfg, ssh, cluster, log)

    if not cfg.get("DEPLOY_DIR"):
        log("FAILED: DEPLOY_DIR is not set (the directory to unpack the tarball into)")
        return 1
    if not cfg.get("DB_DIR"):
        log("FAILED: DB_DIR is not set (the final install path)")
        return 1

    # Validate the protocol name before touching any host: deploying with the
    # wrong consensus and only then discovering it wastes a whole deployment.
    consensus = args.consensus or cfg.raw("DEPLOY_CONSENSUS")
    try:
        klass = consensus_class(consensus)
    except DeployError as exc:
        log(f"FAILED: {exc}")
        return 1
    log(f"deploying from {cfg.raw('DEPLOY_TARBALL') or '(no tarball: in-place reconfigure)'}")
    log(f"  {len(cfg.cn_hosts)} ConfigNode + {len(cfg.dn_hosts)} DataNode")
    log(f"  DB_DIR={cfg.get('DB_DIR')}")
    log(f"  consensus {consensus} -> {klass}")

    if args.clean:
        log("stopping and wiping any previous instance")
        cluster.stop_all(clean=True)

    if cfg.raw("DEPLOY_TARBALL") or args.clean:
        log("unpacking the release")
        deployer.unpack(clean=args.clean)

    data_rf = args.data_rf or cfg.get_int("DATA_REPLICATION_FACTOR")
    schema_rf = args.schema_rf or cfg.get_int("SCHEMA_REPLICATION_FACTOR")
    log(f"writing first_start configuration (data_rf={data_rf}, schema_rf={schema_rf})")
    try:
        deployer.configure(data_rf=data_rf, schema_rf=schema_rf, consensus=consensus)
    except DeployError as exc:
        log(f"FAILED: {exc}")
        return 1

    if args.no_start:
        log("stopping here (--no-start); configuration is written but nothing was started")
        return 0

    # Resolve the activation code before touching any host: failing here costs
    # nothing, failing after a long start costs the whole deployment.  The code
    # is submitted during start(), before the health wait.
    code = ""
    if cfg.get_bool("DEPLOY_ACTIVATE") and not args.no_activate:
        try:
            code = resolve_license_code(
                cfg.raw("LICENSE_CODE"), code_file=cfg.raw("LICENSE_CODE_FILE")
            )
        except DeployError as exc:
            log(f"FAILED: {exc}")
            return 1
    else:
        log("activation disabled; an unactivated cluster stays ReadOnly")

    log("starting the cluster (seed ConfigNode first), then activating")
    try:
        healthy = deployer.start(activate_code=code)
    except DeployError as exc:
        log(f"FAILED: {exc}")
        return 1
    if not healthy:
        log("FAILED: the cluster did not become healthy")
        return 1
    log(f"cluster is healthy: {cluster.status().summary()}")

    for line in deployer.deployment_summary(consensus):
        log(f"  {line}")
    log("deploy done; `rcdn matrix` can run the remove cases on this cluster")
    return 0


def cmd_benchmark(args: argparse.Namespace) -> int:
    """Show, download or install the benchmark build that matches the version."""
    cfg = load_config(args.conf)
    results_root, log, ssh, sql = _build(cfg, _new_run_id("benchmark"), args.quiet)

    version = args.version or cfg.db_version()
    if not version:
        log(
            "FAILED: cannot tell which database version to match; pass --version "
            "(e.g. --version 1.3.4) or set DB_VERSION"
        )
        return 1
    try:
        profile = benchmark_profile(version)
    except VersionError as exc:
        log(f"FAILED: {exc}")
        return 1
    java_tag = args.java or "java17"
    log(f"database {version} ({profile.line}) needs the {profile.module} module")
    log(f"  asset    : {asset_name(profile, java_tag=java_tag)}")
    log(f"  DB_SWITCH: {cfg.bm_db_switch()}")
    log(f"  workloads: {','.join(cfg.workload_set())}")

    try:
        release = fetch_releases(tag=args.tag)
    except FetchError as exc:
        log(f"FAILED: {exc}")
        return 1
    log(f"  release  : {describe_release(release)}")

    asset = pick_asset(release, profile, java_tag=java_tag)
    if asset is None:
        names = ", ".join(a.get("name", "?") for a in (release.get("assets") or []))
        log(
            f"FAILED: release {release.get('tag_name')} has no "
            f"{asset_name(profile, java_tag=java_tag)}; it carries: {names}"
        )
        return 1
    size_mib = int(asset.get("size") or 0) // (1024 * 1024)
    log(f"  download : {asset['name']} ({size_mib} MiB)")

    if not args.install:
        log("(dry run; pass --install to download and unpack it)")
        return 0

    cache = Path(args.cache).expanduser() if args.cache else cfg.result_dir / "_benchmark_cache"
    try:
        log(f"downloading to {cache}")
        zip_path = download(
            asset["browser_download_url"],
            cache / asset["name"],
            expected_size=int(asset.get("size") or 0),
        )
    except FetchError as exc:
        log(f"FAILED: {exc}")
        return 1

    home = (
        Path(args.home).expanduser()
        if args.home
        else (Path(cfg.get("BM_HOME")).expanduser() if cfg.raw("BM_HOME") else default_home(cache, release, java_tag=java_tag))
    )
    try:
        install_zip(zip_path, home)
    except FetchError as exc:
        log(f"FAILED: {exc}")
        return 1
    log(f"installed into {home}")

    problem = check_benchmark_home(home, profile)
    if problem:
        log(f"FAILED: {problem}")
        return 1
    log("verified: benchmark.sh present and the required module is in lib/")
    log(f"point the config at it:  BM_HOME={home}")
    return 0


def cmd_teardown(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    results_root, log, ssh, sql = _build(cfg, _new_run_id("teardown"), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)
    log("stopping the cluster")
    cluster.stop_all()
    log("cleaning up scratch files")
    for host in cfg.all_hosts:
        ssh.run(host, f"rm -f {cfg.get('DB_DIR')}/rcdn_fill_disk.tmp", check=False)
    if args.wipe:
        log("wiping data and logs")
        cluster.wipe()
    log("done")
    return 0


# region="DataRegion[7]", name="logDispatcher-<ip>:<port>" or "ioTConsensusServerImpl"
_METRIC_LINE = re.compile(r"^iot_consensus\{(?P<labels>[^}]*)\}\s+(?P<value>[-0-9.eE+]+)\s*$")


def _parse_consensus_metrics(text: str) -> tuple[dict[str, float], dict[tuple[str, str], dict[str, float]]]:
    """Return (syncLag per region, per-(region, dispatcher-peer) stats).

    Attribution matters here: an aggregate `max(syncLag)` cannot distinguish a
    live stalled pipeline from state left behind by a removed replica, and those
    need opposite responses.
    """
    lag: dict[str, float] = {}
    disp: dict[tuple[str, str], dict[str, float]] = {}
    for line in text.splitlines():
        m = _METRIC_LINE.match(line.strip())
        if not m:
            continue
        labels = m.group("labels")
        try:
            value = float(m.group("value"))
        except ValueError:
            continue
        region = re.search(r'region="([^"]+)"', labels)
        name = re.search(r'name="([^"]+)"', labels)
        kind = re.search(r'type="([^"]+)"', labels)
        if not region or not name or not kind:
            continue
        if name.group(1) == "ioTConsensusServerImpl" and kind.group(1) == "syncLag":
            lag[region.group(1)] = value
        elif name.group(1).startswith("logDispatcher-"):
            peer = name.group(1)[len("logDispatcher-"):]
            disp.setdefault((region.group(1), peer), {})[kind.group(1)] = value
    return lag, disp


def cmd_diag(args: argparse.Namespace) -> int:
    """Explain a syncLag that will not converge.

    A DataNode removal can leave dispatcher state behind for a peer that no
    longer exists, which freezes syncLag forever without any live pipeline.
    This prints, per node: which regions lag, who their dispatchers talk to,
    whether those peers still exist, and whether any driver thread is left.
    """
    cfg = load_config(args.conf)
    _results_root, log, ssh, sql = _build(cfg, args.run_id or _new_run_id("diag"), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)
    cluster.discover_ports()
    log(f"cluster: {cluster.status().summary()}")

    known_dns = {ip for ip in (Cluster.row_ip(r) for r in cluster.datanodes()) if ip}
    running = cluster.running_dn_hosts()
    live_regions: set[str] = set()
    for line in sql.sql(cfg.cli_host, "show regions", check=False).splitlines():
        fields = [x.strip() for x in line.split("|") if x.strip()]
        if len(fields) > 2 and fields[1] in {"DataRegion", "SchemaRegion"}:
            live_regions.add(f"{fields[1]}[{fields[0]}]")
    log(f"  live DataNodes: {', '.join(sorted(known_dns)) or '-'}")
    if not live_regions:
        log("  warning: `show regions` returned no regions; attribution will be limited")

    port = cluster.dn_metrics_port()
    lagging = 0
    for host in running:
        try:
            text = http_get_text(f"http://{host}:{port}/metrics", timeout=20)
        except Exception as exc:  # noqa: BLE001
            log(f"  {host}: metrics unavailable ({exc})")
            continue
        lag, disp = _parse_consensus_metrics(text)
        hot = {r: v for r, v in lag.items() if v > 1e-4}
        if not hot:
            log(f"  {host}: syncLag 0 on all {len(lag)} region(s)")
            continue
        lagging += len(hot)
        for region, value in sorted(hot.items(), key=lambda kv: -kv[1]):
            exists = region in live_regions if live_regions else None
            log(f"  {host}: {region} syncLag={value:.0f}"
                + ("" if exists is None else (" [region exists]" if exists else " [REGION NO LONGER EXISTS]")))
            for (reg, peer), stats in sorted(disp.items()):
                if reg != region:
                    continue
                gone = peer.split(":")[0] not in known_dns
                queue = stats.get("cachedRequestInMemoryQueue")
                pipes = stats.get("pipelineNum")
                log(f"      -> {peer}"
                    + (f" pipelNum={pipes:.0f}" if pipes is not None else "")
                    + (f" queue={queue:.0f}" if queue is not None else "")
                    + ("  <<< peer is NOT a live DataNode" if gone else ""))
        pid = ssh.run(
            host,
            "w=$(ps -eo pid,args= | grep '[s]tart-datanode.sh' | awk '{print $1}' | head -1); "
            "pgrep -P $w 2>/dev/null | head -1",
            check=False,
        ).out.strip().splitlines()
        pid = pid[-1].strip() if pid else ""
        if pid.isdigit():
            names = ssh.run(
                host,
                f"for t in /proc/{pid}/task/*; do cat $t/comm 2>/dev/null; done",
                check=False,
            ).out
            threads = [n for n in names.splitlines() if n.strip()]
            # jstack is usually absent from these images and fails silently; /proc
            # reads the real thread names with no extra tooling.
            drivers = [n for n in threads if "LogDispatcher" in n]
            log(f"      live threads={len(threads)}, LogDispatcher threads={len(drivers)}"
                + ("" if drivers else "  <<< nothing can drain that queue"))

    if not lagging:
        log("no region reports a non-zero syncLag; nothing to explain")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    results_root, log, ssh, sql = _build(cfg, args.run_id or _new_run_id("verify"), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)
    cluster.discover_ports()
    log(f"cluster: {cluster.status().summary()}")

    run = _load_layout(args.layout, cfg)
    verifier = Verifier(cfg, cluster, ssh, sql, log, results_root / "verify")
    problems: list[str] = []
    if run is not None:
        # The sweep stops real DataNodes one at a time; say so before doing it.
        targets = cluster.running_dn_hosts()
        log(
            f"consistency sweep: {run.tree_db or '-'} / {run.table_db or '-'}; "
            f"will stop and restart each of {len(targets)} DataNode(s) in turn: "
            + ", ".join(targets)
        )
        problems.extend(verifier.consistency_check(run))
    else:
        log("no benchmark layout available; skipping the consistency sweep")

    if cfg.get_bool("LOG_SCAN"):
        problems.extend(verifier.check_logs())
    if problems:
        log(f"verify: {len(problems)} problem(s)")
        for problem in problems:
            log(f"  - {problem}")
        if cfg.raw("LOG_BACKUP") in {"fail", "always"}:
            verifier.backup_logs(f"verify_{time.strftime('%Y%m%d_%H%M%S')}", results_root / "log_backup")
        return 1
    log("verify: clean")
    return 0


def _load_layout(path: str | None, cfg: Config):
    """Rebuild a BenchmarkRun from a previously written benchmark_layout.json."""
    candidates: list[Path] = []
    if path:
        candidates.append(Path(path))
    else:
        cases_dir = cfg.result_dir
        if cases_dir.exists():
            candidates += sorted(cases_dir.glob("*/cases/*/benchmark_layout.json"))
    if not candidates:
        return None
    chosen = candidates[-1]
    data = json.loads(chosen.read_text(encoding="utf-8"))
    if data.get("stub"):
        # Written by `smoketest` against a stubbed cluster: acting on it would
        # query/stop real nodes using fake database names.
        raise SystemExit(
            f"refusing to use {chosen}: it was produced by `smoketest` against a "
            "stubbed cluster and does not describe real data.\n"
            "Point --layout at a real run, or omit it to skip the sweep."
        )
    from .benchmark import BenchmarkRun

    run = BenchmarkRun(work_root=Path("."))
    run.tree_db = data.get("tree_db", "")
    run.table_db = data.get("table_db", "")
    run.base_table = data.get("base_table", "")
    run.view_table = data.get("view_table", "")
    run.columns = data.get("columns", [])
    run.object_columns = data.get("object_columns", [])
    return run


def cmd_smoketest(args: argparse.Namespace) -> int:
    from .smoketest import main as smoke_main

    return smoke_main(args.conf, args.cases)


def cmd_list_cases(args: argparse.Namespace) -> int:
    cases = load_cases(Path(args.cases), only=args.case or None)
    log = Logger(quiet=args.quiet)
    log(f"{len(cases)} case(s) in {args.cases}")
    log("")
    log(f"{'case_id':<34} {'target':<7} {'selector':<11} {'data_rf':<8} {'schema_rf':<10} abnormal")
    log("-" * 118)
    for case in cases:
        log(
            f"{case.case_id:<34} {case.target:<7} {case.selector:<11} "
            f"{case.data_rf:<8} {case.schema_rf:<10} {','.join(case.abnormal)}"
        )
    log("")
    for case in cases:
        if case.notes:
            log(f"{case.case_id:<34} {case.notes}")
    return 0


def cmd_analyze_diff(args: argparse.Namespace) -> int:
    """Explain a finished case's replica inconsistency, entirely offline."""
    from .analyze_diff import main as analyze

    return analyze(["analyze_diff", args.run_dir, args.case])


def cmd_selftest(args: argparse.Namespace) -> int:
    from .selftest import run

    failures = run()
    if failures:
        print(f"\nselftest: {len(failures)} failure(s): {', '.join(failures)}")
        return 1
    print("\nselftest: OK")
    return 0


def _expand_repeats(cases: list[Case], repeat: int) -> list[Case]:
    """Expand each case into ``repeat`` runs under unique result ids.

    A single run cannot tell a solid pass from a flaky one.  Two cases in this
    matrix only wedge when the removed DataNode's region placement happens to
    include a non-participating replica, so they PASS and FAIL on different
    runs; the only way to say anything useful about them is to run them N times
    and report a *rate* instead of a verdict.
    """
    if repeat <= 1:
        return cases
    expanded: list[Case] = []
    for case in cases:
        for rep in range(1, repeat + 1):
            # Rep 1 keeps the bare id so a single run stays comparable with
            # every earlier result directory.
            expanded.append(case if rep == 1 else replace(case, case_id=f"{case.case_id}#{rep}"))
    return expanded


def _repeat_rollup(results: list) -> list[str]:
    """One line per repeated case: how many runs passed, failed, skipped."""
    groups: dict[str, list[str]] = {}
    for r in results:
        groups.setdefault(r.case_id.split("#", 1)[0], []).append(r.status)
    lines: list[str] = []
    for base, statuses in groups.items():
        if len(statuses) < 2:
            continue
        tally = "  ".join(
            f"{s}={statuses.count(s)}" for s in ("PASS", "FAIL", "SKIP") if statuses.count(s)
        )
        lines.append(f"  {base}: {tally}   ({len(statuses)} runs)")
    return lines


def cmd_run(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    cfg.validate(need_benchmark=True)
    results_root, log, ssh, sql = _build(cfg, args.run_id or _new_run_id("run"), args.quiet)
    # Refuse to start on a mismatched benchmark: it would run for hours against
    # the wrong client libraries and fail as though the cluster were broken.
    blocking = cfg.benchmark_preflight()
    if blocking:
        log("refusing to start:")
        for problem in blocking:
            log(f"  - {problem}")
        log("fix it with `benchmark --install`, or set DB_VERSION / BM_HOME")
        return 1
    # Nothing else may write to the cluster while a case measures it, so stop the
    # load an earlier, interrupted run left behind (see benchmark.py, stale load).
    _stop_stale_load(cfg, log)
    profile = cfg.benchmark_profile()
    log(
        f"benchmark: {profile.module} via {cfg.bm_db_switch()} "
        f"(database {cfg.db_version()}, workloads {','.join(cfg.workload_set())})"
    )
    # Record *which* benchmark build produced this run.  The benchmark can be
    # installed from the newest release of its line, so two runs months apart can
    # legitimately use different builds; without this line the artifacts cannot
    # say which one, and a mid-regression change of BM_HOME would be invisible.
    log(f"benchmark build: {cfg.raw('BM_HOME') or '(BM_HOME not set)'}")
    runner = CaseRunner(cfg, ssh, sql, log, results_root)
    cases = load_cases(Path(args.cases), only=args.case or None)
    cases = _expand_repeats(cases, args.repeat)
    log(f"running {len(cases)} case run(s) from {args.cases}")
    results = []
    for index, case in enumerate(cases, 1):
        log(f"--- case {index}/{len(cases)}: {case.case_id}")
        results.append(runner.run(case))
        latest = results[-1]
        # A replica inconsistency is the whole point of this harness, and the next case's
        # `prepare` wipes both the data and the DataNode logs.  Stop here instead, leaving
        # the hit case's cluster exactly as it is so the per-replica row inventory can be
        # read straight off the live nodes.  Measured: without this, the freeze watcher
        # arrived 4 s after the next prepare had already reset the cluster, and the one
        # hit whose direction was unknown stayed unknown.
        if any("replica inconsistency" in p for p in latest.problems) and cfg.raw(
            "ABORT_ON_REPLICA_DIFF", "true"
        ).strip().lower() not in {"false", "no", "0"}:
            log("")
            log(f"* replica inconsistency in {latest.case_id}: stopping the run BEFORE the next")
            log("  case's prepare resets the cluster; data and DataNode logs are left in place")
            log(f"  cluster: {','.join(cfg.dn_hosts)}  db_dir={cfg.get('DB_DIR')}")
            log(f"  row inventory now: python3 -m rcdn.probe_frozen <run_dir> {latest.case_id}")
            break
        # Persist after every case, as `matrix` does.  A long `run` can be cut
        # short by something outside the tool (on the 3C5D rc2 pass the driver
        # IP was banned 12 cases in), and without this the whole run leaves no
        # summary at all even though every earlier case did finish.
        _write_summary(results, results_root)
    _write_summary(results, results_root)
    return 0 if all(r.status in {"PASS", "SKIP"} for r in results) else 1


def cmd_matrix(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    cfg.validate(need_benchmark=True)
    results_root, log, ssh, sql = _build(cfg, args.run_id or _new_run_id("matrix"), args.quiet)
    # Refuse to start on a mismatched benchmark: it would run for hours against
    # the wrong client libraries and fail as though the cluster were broken.
    blocking = cfg.benchmark_preflight()
    if blocking:
        log("refusing to start:")
        for problem in blocking:
            log(f"  - {problem}")
        log("fix it with `benchmark --install`, or set DB_VERSION / BM_HOME")
        return 1
    # Nothing else may write to the cluster while a case measures it, so stop the
    # load an earlier, interrupted run left behind (see benchmark.py, stale load).
    _stop_stale_load(cfg, log)
    profile = cfg.benchmark_profile()
    log(
        f"benchmark: {profile.module} via {cfg.bm_db_switch()} "
        f"(database {cfg.db_version()}, workloads {','.join(cfg.workload_set())})"
    )
    # Record *which* benchmark build produced this run.  The benchmark can be
    # installed from the newest release of its line, so two runs months apart can
    # legitimately use different builds; without this line the artifacts cannot
    # say which one, and a mid-regression change of BM_HOME would be invisible.
    log(f"benchmark build: {cfg.raw('BM_HOME') or '(BM_HOME not set)'}")
    runner = CaseRunner(cfg, ssh, sql, log, results_root)
    cases = load_cases(Path(args.cases), only=args.case or None)
    if args.limit:
        cases = cases[: args.limit]
    cases = _expand_repeats(cases, args.repeat)
    log(f"running {len(cases)} case run(s) from {args.cases}")
    results = []
    for index, case in enumerate(cases, 1):
        log(f"--- case {index}/{len(cases)}: {case.case_id}")
        results.append(runner.run(case))
        _write_summary(results, results_root)
    _write_summary(results, results_root)
    failed = [r for r in results if r.status not in {PASS, SKIP}]
    return 0 if not failed else 1


def _write_summary(results, results_root: Path) -> None:
    tsv = results_root / "summary.tsv"
    with tsv.open("w", encoding="utf-8") as fh:
        fh.write("case_id\tstatus\telapsed_sec\tproblems\tbackup\n")
        for r in results:
            fh.write(
                f"{r.case_id}\t{r.status}\t{r.elapsed_sec}\t"
                f"{' | '.join(r.problems)[:600]}\t{r.backup}\n"
            )
    (results_root / "summary.json").write_text(
        json.dumps([r.to_dict() for r in results], indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print("")
    print(f"summary: {results_root / 'summary.tsv'}")
    for r in results:
        print(f"  {r.status:<8} {r.case_id}  ({r.elapsed_sec}s){'  ' + r.backup if r.backup else ''}")
    rollup = _repeat_rollup(results)
    if rollup:
        print("")
        print("repeated cases (pass rate):")
        for line in rollup:
            print(line)


# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    """Build the parser.  Global options are handled by split_global_options."""
    # --conf/--quiet/--run-id are accepted both before and after the
    # subcommand so that `rcdn doctor --conf x` and `rcdn --conf x doctor`
    # both work.
    parser = argparse.ArgumentParser(
        prog="rcdn",
        description="IoTDB remove-ConfigNode/DataNode concurrency and consistency test driver",
    )
    parser.add_argument(
        "--conf", default=str(SKILL_ROOT / "conf" / "cluster.conf"), help="path to cluster.conf"
    )
    parser.add_argument("--quiet", action="store_true", help="suppress progress output")
    parser.add_argument("--run-id", default=None, help="result directory name under RESULT_DIR")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("doctor", help="check ssh, paths and prerequisites without changing anything")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("discover", help="build conf/nodes.conf")
    p.add_argument("--from-cluster", action="store_true", help="read the topology from a running cluster")
    p.add_argument("--from-inventory", action="store_true", help="probe the hosts listed in SEED_HOSTS")
    p.add_argument("--include-stopped", action="store_true", help="also record nodes that are not Running")
    p.set_defaults(func=cmd_discover)

    p = sub.add_parser("prepare", help="stop, wipe and start the cluster (destroys all data)")
    p.add_argument("--data-rf", default=None)
    p.add_argument("--schema-rf", default=None)
    p.add_argument("--no-activate", action="store_true",
                   help="skip re-submitting the activation code after the restart")
    p.set_defaults(func=cmd_prepare)

    p = sub.add_parser("run", help="run one or more named cases")
    p.add_argument("--case", action="append", help="case id (repeatable)")
    p.add_argument("--cases", default=str(DEFAULT_CASES), help="case matrix file")
    p.add_argument("--repeat", type=int, default=1,
                   help="run each case N times (ids become <case>#2..#N); use it to turn a flaky case into a pass rate")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("matrix", help="run the whole case matrix")
    p.add_argument("--case", action="append", help="restrict to these case ids (repeatable)")
    p.add_argument("--cases", default=str(DEFAULT_CASES), help="case matrix file")
    p.add_argument("--limit", type=int, default=0, help="run at most N cases")
    p.add_argument("--repeat", type=int, default=1,
                   help="run each case N times (ids become <case>#2..#N); use it to turn a flaky case into a pass rate")
    p.set_defaults(func=cmd_matrix)

    p = sub.add_parser(
        "diag",
        help="explain a syncLag that will not converge (per-region attribution)",
    )
    p.add_argument("--conf", default="master.conf", help="config file (default: master.conf)")
    p.add_argument("--run-id", default=None, help="run id used for scratch/log naming")
    p.add_argument("--quiet", action="store_true", help="only print warnings and errors")
    p.set_defaults(func=cmd_diag)

    p = sub.add_parser("verify", help="re-run the consistency sweep and the log scan on a running cluster")
    p.add_argument("--layout", default=None, help="path to a benchmark_layout.json from a previous run")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("list-cases", help="print the case matrix")
    p.add_argument("--case", action="append", help="restrict to these case ids (repeatable)")
    p.add_argument("--cases", default=str(DEFAULT_CASES), help="case matrix file")
    p.set_defaults(func=cmd_list_cases)

    p = sub.add_parser(
        "smoketest",
        help="run every case end-to-end against a stubbed cluster (contacts nothing)",
    )
    p.add_argument("--cases", default=str(DEFAULT_CASES), help="case matrix file")
    p.set_defaults(func=cmd_smoketest)

    p = sub.add_parser("selftest", help="run the offline parser/case-matrix self-test")
    p.set_defaults(func=cmd_selftest)

    p = sub.add_parser(
        "analyze-diff",
        help="explain a finished case's replica inconsistency from its artifacts (offline)",
    )
    p.add_argument("--run-dir", required=True, help="a results/run_<ts> directory")
    p.add_argument("--case", required=True, help="the case id to analyze")
    p.set_defaults(func=cmd_analyze_diff)

    p = sub.add_parser("benchmark", help="show, download or install the matching benchmark build")
    p.add_argument("--version", help="database version to match (default: DB_VERSION)")
    p.add_argument("--tag", help="a specific iot-benchmark release tag (default: the latest)")
    p.add_argument("--java", default="java17", help="release java tag (default: java17)")
    p.add_argument("--install", action="store_true", help="download and unpack, not just report")
    p.add_argument("--home", help="where to install (default: BM_HOME, else a cache path)")
    p.add_argument("--cache", help="where to keep the downloaded zip")
    p.set_defaults(func=cmd_benchmark)

    p = sub.add_parser("deploy", help="build the cluster from a release tarball and activate it")
    p.add_argument("--consensus", help="IoTConsensus (default), IoTConsensusV2 or IoTV2")
    p.add_argument("--data-rf", help="data_replication_factor (default: DATA_REPLICATION_FACTOR)")
    p.add_argument("--schema-rf", help="schema_replication_factor (default: SCHEMA_REPLICATION_FACTOR)")
    p.add_argument("--clean", action="store_true", help="stop and wipe any previous install first")
    p.add_argument("--no-start", action="store_true", help="unpack and configure only")
    p.add_argument("--no-activate", action="store_true", help="skip license activation")
    p.set_defaults(func=cmd_deploy)

    p = sub.add_parser("teardown", help="stop the cluster and remove scratch files")
    p.add_argument("--wipe", action="store_true", help="also delete data/ and logs/")
    p.set_defaults(func=cmd_teardown)

    return parser


GLOBAL_OPTIONS = {
    "--conf": "conf",
    "--run-id": "run_id",
    "--quiet": "quiet",
}


def split_global_options(argv: list[str]) -> tuple[list[str], dict[str, object]]:
    """Pull --conf/--quiet/--run-id out of ``argv`` wherever they appear.

    argparse cannot do this cleanly: a ``--conf`` given *before* the subcommand
    is overwritten by the subparser's own default, so the global flags are
    extracted first and re-applied to the resulting namespace.
    """
    rest: list[str] = []
    found: dict[str, object] = {}
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--quiet":
            found["quiet"] = True
            index += 1
            continue
        name, sep, inline = arg.partition("=")
        if name in GLOBAL_OPTIONS and name != "--quiet":
            if sep:
                found[GLOBAL_OPTIONS[name]] = inline
                index += 1
                continue
            if index + 1 >= len(argv):
                raise SystemExit(f"rcdn: {name} requires a value")
            found[GLOBAL_OPTIONS[name]] = argv[index + 1]
            index += 2
            continue
        rest.append(arg)
        index += 1
    return rest, found


def _install_signal_handlers() -> None:
    """Stop in-flight benchmark load when this driver is killed.

    The load runs in its own session, so it survives the driver; without this a
    ``kill`` on the driver leaves writers behind and the next case reports
    "the dataset never settled" although the database is fine.
    """
    from .benchmark import kill_active_runs

    def handler(signum, _frame):
        killed = kill_active_runs(log=lambda msg: print(msg, file=sys.stderr))
        print(f"received signal {signum}: stopped {killed} in-flight benchmark(s)", file=sys.stderr)
        sys.stdout.flush()
        sys.stderr.flush()
        # Leave immediately: the case's own cleanup talks to a cluster and can take
        # minutes, while the point of the handler is to leave nothing running.
        os._exit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, handler)
        except (ValueError, OSError):  # not the main thread, or unsupported
            pass


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    _install_signal_handlers()
    argv, globals_found = split_global_options(list(argv))
    parser = build_parser()
    args = parser.parse_args(argv)
    for key, value in globals_found.items():
        setattr(args, key, value)
    try:
        return args.func(args)
    except ConfigError as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        from .benchmark import kill_active_runs

        kill_active_runs(log=lambda msg: print(msg, file=sys.stderr))
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
