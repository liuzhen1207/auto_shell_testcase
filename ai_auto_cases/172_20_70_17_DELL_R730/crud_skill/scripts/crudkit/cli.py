"""Command line entry point for the CRUD test skill.

    scripts/crud.sh --conf conf/cluster.ttl_rc4.conf <command>

Commands mirror the remove-cn/dn skill, minus everything that is specific to node
removal:

    selftest     offline checks (no cluster, no ssh)
    list-cases   print the case matrix
    doctor       verify ssh / paths / tarball / CLI before touching anything
    deploy       unpack the release tarball, configure and activate the cluster
    prepare      DESTRUCTIVE: stop, wipe, write the TTL knobs, restart
    props        show or set the TTL knobs in iotdb-common.properties
    load         start/stop the iot-benchmark load (optional)
    run          run selected cases
    matrix       run every case
    report       summarise a run directory into a markdown report
"""
from __future__ import annotations

import argparse
import datetime
import json
import shlex
import sys
import time
import traceback
from pathlib import Path

from . import crudcases
from .cluster import Cluster
from .config import ConfigError, Node, load_config, parse_nodes_file, write_nodes_file
from .deploy import Deployer, DeployError, consensus_class, resolve_license_code
from .remote import RemoteError, SqlClient, SshRunner
from .ttlapi import TtlApi
from .crudcases import Ctx
from .ttlprops import AUDIT_KEY, TTL_KEYS, TtlProps

SKILL_ROOT = Path(__file__).resolve().parents[2]
TTL_CONF_KEYS = {
    "ttl_check_interval": "TTL_CHECK_INTERVAL_MS",
    "max_expired_time": "TTL_MAX_EXPIRED_TIME_MS",
    "expired_data_ratio": "TTL_EXPIRED_DATA_RATIO",
    "default_ttl_in_ms": "TTL_DEFAULT_TTL_MS",
}
# The audit log is off by default (enable_audit_log=false) and the audit cases can only say
# anything once it is on: with it off, __audit simply does not exist.  Both keys are
# hot-reloadable, but they are written before start anyway so the whole run sees them.
AUDIT_CONF_KEYS = {
    "enable_audit_log": "AUDIT_ENABLE",
    "auditable_operation_type": "AUDIT_OPERATION_TYPES",
    "auditable_control_event_type": "AUDIT_CONTROL_EVENTS",
}


# ----------------------------------------------------------------- small helpers
def _new_run_id(prefix: str) -> str:
    return f"{datetime.datetime.now():%Y%m%d_%H%M%S}_{prefix}"


def build(cfg, run_id: str, quiet: bool = False):
    """Create the run directory plus the ssh/sql clients, and return a log callable."""
    run_dir = cfg.result_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    handle = (run_dir / "run.log").open("a", encoding="utf-8")

    def log(message: str) -> None:
        line = f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}  {message}"
        if not quiet:
            print(line, flush=True)
        handle.write(line + "\n")
        handle.flush()

    ssh = SshRunner(cfg, run_dir / "scratch")
    sql = SqlClient(cfg, ssh, run_dir / "scratch")
    return run_dir, log, ssh, sql


def ttl_updates(cfg) -> dict[str, str]:
    """TTL and audit knobs to write into iotdb-system.properties before the cluster starts."""
    updates: dict[str, str] = {}
    for prop, key in {**TTL_CONF_KEYS, **AUDIT_CONF_KEYS}.items():
        value = cfg.raw(key)
        if value:
            updates[prop] = value
    return updates


def wait_ttl_ready(api: TtlApi, log, timeout: int = 420) -> bool:
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        outcome = api.run("show all ttl", timeout=60)
        if outcome.ok:
            return True
        last = outcome.detail[:160]
        time.sleep(10)
    log(f"  cluster did not answer show all ttl within {timeout}s (last: {last})")
    return False


# ---------------------------------------------------------------------- commands
def cmd_selftest(args: argparse.Namespace) -> int:
    problems: list[str] = []
    seen: set[str] = set()
    for spec in crudcases.CASES:
        if spec.case_id in seen:
            problems.append(f"duplicate case_id {spec.case_id}")
        seen.add(spec.case_id)
        if not callable(spec.fn):
            problems.append(f"{spec.case_id}: not callable")
        if spec.priority not in {"P0", "P1", "P2"}:
            problems.append(f"{spec.case_id}: bad priority {spec.priority}")
        if not spec.area or not spec.title:
            problems.append(f"{spec.case_id}: missing area/title")
    example = SKILL_ROOT / "conf" / "cluster.ttl_rc4.conf"
    if example.is_file():
        try:
            cfg = load_config(str(example))
            if not cfg.get("DB_DIR"):
                problems.append("conf example has no DB_DIR")
            if not cfg.dn_hosts:
                problems.append("conf example has no DataNode hosts")
        except Exception as exc:  # noqa: BLE001
            problems.append(f"conf example does not parse: {exc}")
    else:
        problems.append(f"missing {example}")
    if problems:
        print("selftest FAILED")
        for item in problems:
            print(f"  - {item}")
        return 1
    by_area: dict[str, int] = {}
    for spec in crudcases.CASES:
        by_area[spec.area] = by_area.get(spec.area, 0) + 1
    print(f"selftest OK: {len(crudcases.CASES)} cases, unique ids, conf parses")
    print("  by area: " + ", ".join(f"{k}={v}" for k, v in sorted(by_area.items())))
    return 0


def cmd_list_cases(args: argparse.Namespace) -> int:
    for spec in crudcases.CASES:
        flag = " [restarts cluster]" if spec.needs_restart else ""
        print(f"{spec.priority}  {spec.case_id:<34} {spec.model:<6} {spec.area:<8} {spec.title}{flag}")
    print(f"-- {len(crudcases.CASES)} cases")
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    run_dir, log, ssh, sql = build(cfg, _new_run_id("doctor"), args.quiet)
    problems: list[str] = []
    log(f"skill      {SKILL_ROOT}")
    log(f"run dir    {run_dir}")
    log(f"hosts      CN={cfg.cn_hosts} DN={cfg.dn_hosts}")
    log(f"DB_DIR     {cfg.get('DB_DIR')}")
    log(f"tarball    {cfg.raw('DEPLOY_TARBALL') or '(none)'}")
    log(f"benchmark  {cfg.raw('BM_HOME') or '(none)'}")
    for host in cfg.all_hosts:
        ok = ssh.ping(host)
        log(f"  ssh {host:<16} {'ok' if ok else 'UNREACHABLE'}")
        if not ok:
            problems.append(f"ssh {host} unreachable")
            continue
        res = ssh.run(host, f"test -d {shlex.quote(cfg.get('DB_DIR'))} && echo yes || echo no",
                      timeout=60, check=False)
        present = "yes" in (res.out + res.err)
        log(f"      DB_DIR {'present' if present else 'MISSING'}")
        if not present:
            problems.append(f"{host}: DB_DIR {cfg.get('DB_DIR')} missing (run deploy first)")
    tarball = cfg.raw("DEPLOY_TARBALL")
    if tarball:
        local = Path(tarball)
        if local.is_file():
            log(f"  tarball present locally ({local.stat().st_size // (1024 * 1024)} MiB); "
                f"deploy uploads it to {cfg.get('DEPLOY_DIR')}")
        else:
            res = ssh.run(cfg.all_hosts[0], f"test -f {shlex.quote(tarball)} && echo yes || echo no",
                          timeout=60, check=False)
            if "yes" in (res.out + res.err):
                log("  tarball present on the hosts")
            else:
                problems.append(f"tarball neither local nor on {cfg.all_hosts[0]}: {tarball}")
    outcome = sql.sql(cfg.cli_host, "show all ttl", check=False, timeout=90)
    reachable = "|" in outcome or "error" not in outcome.lower()
    log(f"  CLI via {cfg.cli_host}: {'ok' if reachable else 'NO ANSWER'}")
    log("")
    if problems:
        log("doctor found problems:")
        for item in problems:
            log(f"  - {item}")
        return 1
    log("doctor: all preconditions satisfied")
    return 0


def cmd_deploy(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    run_dir, log, ssh, sql = build(cfg, _new_run_id("deploy"), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)
    deployer = Deployer(cfg, ssh, cluster, log)
    consensus = args.consensus or cfg.raw("DEPLOY_CONSENSUS")
    try:
        klass = consensus_class(consensus)
    except DeployError as exc:
        log(f"FAILED: {exc}")
        return 1
    log(f"deploying {cfg.raw('DEPLOY_TARBALL') or '(in-place reconfigure)'}")
    log(f"  {len(cfg.cn_hosts)} ConfigNode + {len(cfg.dn_hosts)} DataNode, consensus {klass}")
    if args.clean:
        cluster.stop_all()
    deployer.unpack(clean=args.clean)
    deployer.configure(data_rf=cfg.get_int("DATA_REPLICATION_FACTOR"),
                       schema_rf=cfg.get_int("SCHEMA_REPLICATION_FACTOR"), consensus=klass)
    code = ""
    if cfg.get_bool("DEPLOY_ACTIVATE"):
        code_file = cfg.raw("LICENSE_CODE_FILE")
        code = resolve_license_code(cfg.raw("LICENSE_CODE"),
                                    code_file=str(cfg.resolve(code_file)) if code_file else "")
    # TTL knobs are not hot-reloadable, so they are written before the first start.
    updates = ttl_updates(cfg)
    if updates:
        log(f"writing TTL knobs: {updates}")
        TtlProps(cfg, ssh, log).write(updates)
    if not deployer.start(activate_code=code):
        log("FAILED: cluster did not become healthy")
        return 1
    log("deploy complete")
    return 0


def cmd_prepare(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    run_dir, log, ssh, sql = build(cfg, _new_run_id("prepare"), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)
    cluster.discover_ports()
    log("stopping any running node")
    cluster.stop_all()
    log("wiping data and logs")
    cluster.wipe()
    log(f"writing configuration (data_rf={cfg.get_int('DATA_REPLICATION_FACTOR')}, "
        f"schema_rf={cfg.get_int('SCHEMA_REPLICATION_FACTOR')})")
    cluster.configure(data_rf=cfg.get_int("DATA_REPLICATION_FACTOR"),
                      schema_rf=cfg.get_int("SCHEMA_REPLICATION_FACTOR"))
    cluster.ensure_executable()
    updates = ttl_updates(cfg)
    if updates:
        log(f"writing TTL knobs: {updates}")
        TtlProps(cfg, ssh, log).write(updates)
    log("starting the cluster")
    if not cluster.start_all():
        log("FAILED: the cluster did not become healthy")
        return 1
    api = TtlApi(cfg, sql, ssh, log)
    if not wait_ttl_ready(api, log):
        log("FAILED: cluster up but TTL statements do not answer")
        return 1
    log("prepare complete")
    return 0


def cmd_props(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    run_dir, log, ssh, sql = build(cfg, _new_run_id("props"), args.quiet)
    props = TtlProps(cfg, ssh, log)
    if args.set:
        updates = {}
        for item in args.set:
            key, _, value = item.partition("=")
            updates[key.strip()] = value.strip()
        touched = props.write(updates)
        log(f"wrote {updates} on {len(touched)} host(s); restart for the non-hot keys to apply")
    for host in cfg.all_hosts:
        values = props.read(host)
        log(f"  {host:<16} " + " ".join(f"{k}={v}" for k, v in sorted(values.items())))
    return 0


def cmd_load(args: argparse.Namespace) -> int:
    from .benchmark import BenchmarkDriver

    cfg = load_config(args.conf)
    run_dir, log, ssh, sql = build(cfg, _new_run_id("load"), args.quiet)
    driver = BenchmarkDriver(cfg, sql, run_dir, log)
    workloads = cfg.workload_set()
    if args.action == "start":
        run = driver.prepare(workloads)
        driver.start(run)
        log(f"benchmark started: {[w.name for w in run.all_workloads()]}")
    else:
        log("stopping benchmark workloads")
        from .benchmark import kill_active_runs, kill_stale_workloads

        kill_active_runs(log)
        kill_stale_workloads(cfg.result_dir, log)
    return 0


def _run_matrix(args: argparse.Namespace, specs: list[crudcases.CaseSpec]) -> int:
    cfg = load_config(args.conf)
    run_dir, log, ssh, sql = build(cfg, args.run_id or _new_run_id(args.command), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)
    props = TtlProps(cfg, ssh, log)

    def factory(spec: crudcases.CaseSpec, case_dir: Path) -> Ctx:
        api = TtlApi(cfg, sql, ssh, log)
        ctx = Ctx(cfg=cfg, ssh=ssh, sql=sql, cluster=cluster, props=props, api=api, log=log,
                  run_dir=run_dir, case_dir=case_dir, case_id=spec.case_id)
        api.trace = ctx.trace
        return ctx

    log(f"running {len(specs)} case(s) in {run_dir}")
    try:
        results = crudcases.run_cases(specs, factory, run_dir, log)
    finally:
        # The OBJECT cases start the table workload themselves when no object data exists;
        # leaving it running would keep writing into the cluster after the matrix.
        crudcases.stop_object_loads(log)
    summary = {
        "run_dir": str(run_dir), "started": run_dir.name, "db_dir": cfg.get("DB_DIR"),
        "version": cfg.get("DB_VERSION"), "consensus": cfg.raw("DEPLOY_CONSENSUS"),
        "hosts": cfg.all_hosts, "cases": results,
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2),
                                          encoding="utf-8")
    counts: dict[str, int] = {}
    for record in results:
        counts[record["status"]] = counts.get(record["status"], 0) + 1
    with (run_dir / "summary.tsv").open("w", encoding="utf-8") as handle:
        handle.write("case_id\tstatus\tarea\tmodel\tpriority\tseconds\ttitle\n")
        for record in results:
            handle.write("\t".join(str(record[k]) for k in
                                   ("case_id", "status", "area", "model", "priority", "seconds",
                                    "title")) + "\n")
    log("")
    log("summary: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    for record in results:
        if record["status"] != crudcases.PASS:
            failed = [c["name"] for c in record["checks"] if not c["ok"]]
            log(f"  {record['status']:<5} {record['case_id']:<34} {record['skipped'] or failed}")
    cmd_report_for(run_dir, log)
    return 0 if counts.get(crudcases.FAIL, 0) == 0 else 1


def cmd_run(args: argparse.Namespace) -> int:
    wanted = list(args.case or [])
    specs = [s for s in crudcases.CASES if s.case_id in wanted]
    missing = [c for c in wanted if c not in crudcases.CASE_INDEX]
    if missing:
        print(f"unknown case id(s): {', '.join(missing)}")
        return 2
    if not specs:
        print("no case selected; use --case <id> (see list-cases)")
        return 2
    if args.skip_restart:
        specs = [s for s in specs if not s.needs_restart]
    args.command = "run"
    return _run_matrix(args, specs)


def cmd_matrix(args: argparse.Namespace) -> int:
    specs = list(crudcases.CASES)
    if args.area:
        specs = [s for s in specs if s.area in set(args.area)]
    if args.priority:
        specs = [s for s in specs if s.priority in set(args.priority)]
    args.command = "matrix"
    return _run_matrix(args, specs)


def cmd_report(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir).resolve()
    if not (run_dir / "summary.json").is_file():
        print(f"no summary.json in {run_dir}")
        return 1
    _report(run_dir, print)
    return 0


def cmd_report_for(run_dir: Path, log) -> None:
    _report(run_dir, log)


def _report(run_dir: Path, log) -> None:
    data = json.loads((run_dir / "summary.json").read_text(encoding="utf-8"))
    cases = data["cases"]
    counts: dict[str, int] = {}
    for record in cases:
        counts[record["status"]] = counts.get(record["status"], 0) + 1
    lines = [f"# CRUD 用例执行报告 — {run_dir.name}", "",
             f"- 数据库版本：{data.get('version')}（{data.get('db_dir')}）",
             f"- 共识协议：{data.get('consensus')}；主机：{', '.join(data.get('hosts', []))}",
             f"- 用例数：{len(cases)}；结果：" + "，".join(f"{k} {v}" for k, v in sorted(counts.items())),
             "", "| 用例 | 结果 | 领域 | 模型 | 优先级 | 耗时(s) | 说明 |", "|---|---|---|---|---|---|---|"]
    for record in cases:
        failed = [c["name"] for c in record["checks"] if not c["ok"]]
        note = record["skipped"] or ("；".join(failed) if failed else "全部断言通过")
        lines.append(f"| {record['case_id']} | {record['status']} | {record['area']} | "
                     f"{record['model']} | {record['priority']} | {record['seconds']} | {note} |")
    lines += ["", "## 断言明细", ""]
    for record in cases:
        lines.append(f"### {record['case_id']} — {record['title']} ({record['status']})")
        if record.get("error"):
            lines.append(f"- 异常：`{record['error']}`")
        for check in record["checks"]:
            mark = "✅" if check["ok"] else "❌"
            lines.append(f"- {mark} {check['name']}" + (f" — {check['detail']}" if check["detail"] else ""))
            if not check["ok"] and check.get("evidence"):
                lines.append(f"  - 证据：`{check['evidence'][:600]}`")
        lines.append("")
    (run_dir / "REPORT.md").write_text("\n".join(lines), encoding="utf-8")
    log(f"report written: {run_dir / 'REPORT.md'}")


# ------------------------------------------------------------------------ parser
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="crud.sh", description="IoTDB TTL test skill")
    parser.add_argument("--conf", default=str(SKILL_ROOT / "conf" / "cluster.ttl_rc4.conf"))
    parser.add_argument("--quiet", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("selftest").set_defaults(func=cmd_selftest)
    sub.add_parser("list-cases").set_defaults(func=cmd_list_cases)
    sub.add_parser("doctor").set_defaults(func=cmd_doctor)

    deploy = sub.add_parser("deploy")
    deploy.add_argument("--clean", action="store_true")
    deploy.add_argument("--consensus")
    deploy.set_defaults(func=cmd_deploy)

    sub.add_parser("prepare").set_defaults(func=cmd_prepare)

    props = sub.add_parser("props")
    props.add_argument("--set", action="append", metavar="KEY=VALUE")
    props.set_defaults(func=cmd_props)

    load = sub.add_parser("load")
    load.add_argument("action", choices=["start", "stop"])
    load.set_defaults(func=cmd_load)

    run = sub.add_parser("run")
    run.add_argument("--case", action="append")
    run.add_argument("--run-id")
    run.add_argument("--skip-restart", action="store_true")
    run.set_defaults(func=cmd_run)

    matrix = sub.add_parser("matrix")
    matrix.add_argument("--area", action="append")
    matrix.add_argument("--priority", action="append")
    matrix.add_argument("--run-id")
    matrix.set_defaults(func=cmd_matrix)

    report = sub.add_parser("report")
    report.add_argument("run_dir")
    report.set_defaults(func=cmd_report)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (ConfigError, RemoteError) as exc:
        print(f"FAILED: {exc}")
        return 1
    except KeyboardInterrupt:
        print("interrupted")
        return 130


if __name__ == "__main__":
    sys.exit(main())
