"""Command line entry point for the iotdb-proactive-regiongroup skill.

    scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf <command>

Commands mirror the sibling skills:

    selftest     offline checks (no cluster, no ssh)
    list-cases   print the case matrix
    doctor       verify ssh / paths / tarball / CLI before touching anything
    deploy       unpack the release tarball, configure and activate the cluster
    prepare      DESTRUCTIVE: stop, wipe, write the PROACTIVE knobs, restart
    upgrade      1.3 -> 2.0 in-place upgrade (PG_UPG_PHASE=pre|post|empty)
    props        show or set the PROACTIVE knobs in iotdb-system.properties
    run          run selected cases (`--case X --case Y`)
    matrix       run every case
    report       summarise a run directory into a Chinese markdown report
    teardown     stop every node
"""
from __future__ import annotations

import argparse
import datetime
import json
import shlex
import sys
import time
from pathlib import Path

from . import cases as pgcases
from .cases import Ctx
from .cluster import ROLE_DN, Cluster, status_is
from .config import ConfigError, load_config
from .deploy import Deployer, DeployError, consensus_class, resolve_license_code
from .pgapi import PgApi
from .pgprops import CmpProps
from .remote import RemoteError, SshRunner, SqlClient
from .verify import CompactionVerifier, SyncLagWaiter

SKILL_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONF = SKILL_ROOT / "conf" / "cluster.pg_2011snap_iot.conf"


def _new_run_id(prefix: str) -> str:
    return f"{datetime.datetime.now():%Y%m%d_%H%M%S}_{prefix}"


def _prepare_run_dir(cfg, run_id: str) -> tuple[Path, str]:
    """Create the run directory, falling back inside the skill if it is unwritable.

    ``RESULT_DIR`` 默认落在 ``/data/deepseek/proactive/results``（用户要求的最终目录）。
    运行环境（例如沙箱）不允许写它时，不改 conf、静默失败更不允许：退回
    ``<技能根>/results/<run_id>`` 并把原因明确报出来，保证 selftest/doctor 等
    路径在受限环境里仍能运行。
    """
    preferred = cfg.result_dir / run_id
    try:
        preferred.mkdir(parents=True, exist_ok=True)
        return preferred, ""
    except OSError as exc:
        fallback = SKILL_ROOT / "results" / run_id
        fallback.mkdir(parents=True, exist_ok=True)
        return fallback, (
            f"RESULT_DIR 目录 {preferred.parent} 不可写（{exc.strerror or exc}）；"
            f"本轮结果退回 {fallback.parent}")


def build(cfg, run_id: str, quiet: bool = False):
    """Create the run directory plus the ssh/sql clients, and return a log callable.

    The run directory is created here, at run time -- never at import time and
    never from a hard-coded absolute path.
    """
    run_dir, dir_note = _prepare_run_dir(cfg, run_id)
    # 协议指纹：**开局即写**，供报告按协议归类轮次（不依赖 run 结束才生成的 REPORT.md，
    # 否则跨协议合并报告可能把 IoTConsensusV2 轮标成 iot）。
    try:
        fingerprint = {
            "run_id": run_id,
            "conf": str(cfg.path) if getattr(cfg, "path", None) else "",
            "consensus": cfg.raw("DEPLOY_CONSENSUS") or cfg.raw("CONSENSUS_METRIC") or "",
            "schema_replication_factor": cfg.raw("SCHEMA_REPLICATION_FACTOR") or "",
            "data_replication_factor": cfg.raw("DATA_REPLICATION_FACTOR") or "",
            "started_at": f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}",
        }
        (run_dir / "CONSENSUS.json").write_text(
            json.dumps(fingerprint, ensure_ascii=False, indent=2), encoding="utf-8")
    except Exception:  # noqa: BLE001 - 指纹失败不能拦住用例执行
        pass
    handle = (run_dir / "run.log").open("a", encoding="utf-8")

    def log(message: str) -> None:
        line = f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}  {message}"
        if not quiet:
            print(line, flush=True)
        handle.write(line + "\n")
        handle.flush()

    if dir_note:
        log(f"WARN: {dir_note}")

    ssh = SshRunner(cfg, run_dir / "scratch")
    sql = SqlClient(cfg, ssh, run_dir / "scratch")
    return run_dir, log, ssh, sql


def prop_updates(cfg) -> dict[str, str]:
    """Everything written into ``iotdb-system.properties`` before start.

    PROACTIVE 策略/配额（8 键）来自 conf 的 PG_* 键，键名逐字取自发布包模板
    （``iotdb-system.properties.template:848/:858/:866/:891/:901/:910/:814/:968``，
    见 references/proactive-spec.md §2）。conf 说明这些键「重启生效」，
    故只在 deploy/prepare 落盘，运行中不热切换。
    """
    updates = cfg.region_group_knobs()
    # 双盘数据目录：RC6 仅在 RatisConsensus 下禁止跨盘
    # (IoTDBStartCheck.java:210-215 -- MISC_EXCEPTION_CONFIGURING_THE_DATA_DIRECTORIES_AS_CROSS_DISK_...);
    # IoTConsensus / IoTConsensusV2 允许 dn_data_dirs 指向多块盘。
    # 共识协议同样是 first_start 生效：`deploy` 会写这一键，`prepare` 之前漏写，
    # 于是 conf 里改成 IoTConsensusV2 后集群仍跑默认 IoTConsensus（V2 轮实际测的是 V1）。
    consensus = (cfg.raw("DEPLOY_CONSENSUS") or "").strip()
    if consensus:
        updates["data_region_consensus_protocol_class"] = consensus_class(consensus)
    # 可选：把 V2 pipe 的 TsFile flush 间隔调小，让「region 已销毁但 pipe 进度表仍有条目」
    # 这条路径在几分钟内就能触发（默认 200s，实测要跑 30 分钟才命中 2~3 次）。
    # 留空 = 不写该键、用产品默认值；写了是否生效由 DN 日志的
    # `pipeTsFileFlushIntervalSeconds is set to N` 回读确认（见 cases_npe）。
    flush_interval = (cfg.raw("PG_PIPE_TS_FILE_FLUSH_INTERVAL") or "").strip()
    if flush_interval:
        # 键名逐字取 PipeDescriptor.java:134-139：`pipe_tsfile_flush_interval_seconds`
        # （ts 与 file 之间没有下划线）；写错键不报错、只是不生效，会白等默认 200s。
        updates["pipe_tsfile_flush_interval_seconds"] = flush_interval
    if cfg.two_disk:
        updates["dn_data_dirs"] = ",".join(cfg.data_dirs)
        strategy = cfg.raw("DB_MULTI_DIR_STRATEGY")
        if strategy:
            updates["dn_multi_dir_strategy"] = strategy
    return updates


def write_props(cfg, cluster, updates: dict[str, str], log) -> list[str]:
    """把 updates 落盘到每台节点的 ``iotdb-system.properties``（deploy/prepare 共用）。

    PROACTIVE 的 ``pgprops.CmpProps`` 是待实现占位（调用即 NotImplementedError），
    而 deploy/prepare 是必须可用的路径，因此这里复用**已实现**的
    ``Cluster.apply_system_properties``，不触碰占位模块。
    """
    touched: list[str] = []
    for host in cfg.all_hosts:
        cluster.apply_system_properties(host, updates)
        touched.append(host)
    log(f"wrote PROACTIVE knobs on {len(touched)} host(s): {sorted(updates)}")
    return touched


def _health(cfg, cluster, gone: set):
    """DataNodes that will never reach syncLag 0 in their current state.

    Mirrors the remove-cn/dn skill's ``_unsyncable_nodes``: a node the case
    removed on purpose is skipped, so the sync gate actually runs instead of
    waiting out SYNC_MAX_WAIT_SEC for a lag that cannot drain.  Removed nodes
    are absent from the cluster anyway; anything still listed but not Running is
    reported.
    """
    def check() -> list[str]:
        bad: list[str] = []
        for host in cfg.dn_hosts:
            if host in gone:
                continue
            status = cluster.dn_status_for(host)
            if status is None or status.lower() in {"", "running", "readonly"}:
                continue
            bad.append(f"{host} is {status}")
        return bad

    return check


def ctx_factory(cfg, ssh, sql, cluster, props, log, run_dir):
    # H-23：``extra_windows`` 必须是**整个 run 共享的一份**。停/起 DataNode 的收敛余波会越界
    # 落进**下一个**用例的收尾③ 扫描窗口；旧实现每个用例都 new 一个 verifier（窗口列表
    # 各自独立），于是"跨用例尾窗"是死代码，下一例照样误判出 ERROR/WARN。
    # 这里在 factory 闭包里建一次、注入给每个 verifier；verify.py 的
    # ``register_sweep_windows`` 会把一小时前的旧窗口剪掉，故不会无界增长。
    shared_windows: list = []

    def factory(spec, case_dir: Path) -> Ctx:
        api = PgApi(cfg, sql, ssh, log)
        artifacts = case_dir / "evidence"
        verifier = CompactionVerifier(cfg, cluster, ssh, sql, log, artifacts,
                                      shared_windows=shared_windows)
        gone: set = set()
        sync = SyncLagWaiter(cfg, cluster, log, health=_health(cfg, cluster, gone))
        ctx = Ctx(cfg=cfg, ssh=ssh, sql=sql, cluster=cluster, props=props, api=api,
                  verifier=verifier, sync_waiter=sync, log=log, run_dir=run_dir,
                  case_dir=case_dir, case_id=spec.case_id, by_design_gone=gone)
        api.trace = ctx.trace
        return ctx

    return factory


def wait_ready(cfg, sql, log, timeout: int = 420) -> bool:
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        out = sql.sql(cfg.cli_host, "show cluster", check=False, timeout=60)
        if "|" in out and "error" not in out.lower():
            return True
        last = " ".join(out.split())[:160]
        time.sleep(10)
    log(f"  cluster did not answer show cluster within {timeout}s (last: {last})")
    return False


# ---------------------------------------------------------------------- commands
def cmd_selftest(args: argparse.Namespace) -> int:
    from . import selftest

    return selftest.run()


def cmd_list_cases(args: argparse.Namespace) -> int:
    for spec in pgcases.CASES:
        flag = " [gate]" if spec.gate else ""
        print(f"{spec.priority}  {spec.case_id:<12} {spec.model:<10} {spec.area:<12} "
              f"{spec.title}{flag}")
    if not pgcases.CASES:
        print("用例注册表为空：PROACTIVE 用例集尚未实现 —— 期望值与族清单见 "
              "references/case-catalog.md 与 references/proactive-spec.md")
    print(f"-- {len(pgcases.CASES)} cases")
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    cfg.validate()
    run_dir, log, ssh, sql = build(cfg, _new_run_id("doctor"), args.quiet)
    problems: list[str] = []
    log(f"skill      {SKILL_ROOT}")
    log(f"run dir    {run_dir}")
    log(f"hosts      CN={cfg.cn_hosts} DN={cfg.dn_hosts}")
    log(f"DB_DIR     {cfg.get('DB_DIR')}")
    log(f"tarball    {cfg.raw('DEPLOY_TARBALL') or '(none)'}")
    log(f"consensus  {cfg.raw('DEPLOY_CONSENSUS')}")
    log(f"扩容参数   {cfg.region_group_knobs()}")
    for note in cfg.notes:
        log(f"  note: {note}")
    for host in cfg.all_hosts:
        reachable = ssh.ping(host)
        log(f"  ssh {host:<16} {'ok' if reachable else 'UNREACHABLE'}")
        if not reachable:
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
    out = sql.sql(cfg.cli_host, "show cluster", check=False, timeout=90)
    log(f"  CLI via {cfg.cli_host}: {'ok' if '|' in out else 'NO ANSWER'}")
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
    cfg.validate()
    run_dir, log, ssh, sql = build(cfg, _new_run_id("deploy"), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)
    deployer = Deployer(cfg, ssh, cluster, log)
    consensus = args.consensus or cfg.raw("DEPLOY_CONSENSUS")
    try:
        consensus_class(consensus)
    except DeployError as exc:
        log(f"FAILED: {exc}")
        return 1
    log(f"deploying {cfg.raw('DEPLOY_TARBALL') or '(in-place reconfigure)'}")
    log(f"  {len(cfg.cn_hosts)} ConfigNode + {len(cfg.dn_hosts)} DataNode, consensus {consensus}")
    if args.clean:
        cluster.stop_all()
    deployer.unpack(clean=args.clean)
    deployer.configure(data_rf=cfg.get_int("DATA_REPLICATION_FACTOR"),
                       schema_rf=cfg.get_int("SCHEMA_REPLICATION_FACTOR"), consensus=consensus)
    code = ""
    if cfg.get_bool("DEPLOY_ACTIVATE"):
        code_file = cfg.raw("LICENSE_CODE_FILE")
        code = resolve_license_code(cfg.raw("LICENSE_CODE"),
                                    code_file=str(cfg.resolve(code_file)) if code_file else "")
    updates = prop_updates(cfg)
    log(f"writing PROACTIVE knobs: {updates}")
    write_props(cfg, cluster, updates, log)
    if not deployer.start(activate_code=code):
        log("FAILED: cluster did not become healthy")
        return 1
    log("deploy complete")
    return 0


def cmd_prepare(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    cfg.validate()
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
    updates = prop_updates(cfg)
    log(f"writing PROACTIVE knobs: {updates}")
    write_props(cfg, cluster, updates, log)
    log("starting the cluster")
    if not cluster.start_all():
        log("FAILED: the cluster did not become healthy")
        return 1
    if not wait_ready(cfg, sql, log):
        log("FAILED: cluster up but SQL does not answer")
        return 1
    log("prepare complete")
    return 0


def cmd_upgrade(args: argparse.Namespace) -> int:
    """1.3 → 2.0 就地升级（阶段由 conf 的 PG_UPG_PHASE 控制，见 pgkit.upgrade）。"""
    from . import upgrade as pgupgrade

    cfg = load_config(args.conf)
    cfg.validate()
    run_dir, log, ssh, sql = build(cfg, _new_run_id("upgrade"), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)
    deployer = Deployer(cfg, ssh, cluster, log)
    try:
        ok = pgupgrade.run_upgrade(cfg, cluster, deployer, ssh, sql, log, run_dir)
    except DeployError as exc:
        log(f"FAILED: {exc}")
        return 1
    return 0 if ok else 1


def cmd_props(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    run_dir, log, ssh, sql = build(cfg, _new_run_id("props"), args.quiet)
    props = CmpProps(cfg, ssh, log)
    if args.set:
        updates = {}
        for item in args.set:
            key, _, value = item.partition("=")
            updates[key.strip()] = value.strip()
        touched = props.write(updates, hosts=cfg.all_hosts)
        log(f"wrote {updates} on {len(touched)} host(s); restart for restart-only keys")
    for host in cfg.all_hosts:
        values = props.read(host, keys=tuple(prop_updates(cfg)))
        log(f"  {host:<16} " + " ".join(f"{k}={v}" for k, v in sorted(values.items())))
    return 0


def cmd_teardown(args: argparse.Namespace) -> int:
    cfg = load_config(args.conf)
    run_dir, log, ssh, sql = build(cfg, _new_run_id("teardown"), args.quiet)
    Cluster(cfg, ssh, sql, log).stop_all()
    log("teardown complete")
    return 0


def _run_matrix(args: argparse.Namespace, specs: list[pgcases.CaseSpec]) -> int:
    cfg = load_config(args.conf)
    cfg.validate()
    run_dir, log, ssh, sql = build(cfg, args.run_id or _new_run_id(args.command), args.quiet)
    cluster = Cluster(cfg, ssh, sql, log)
    props = CmpProps(cfg, ssh, log)

    log(f"running {len(specs)} case(s) in {run_dir}")
    factory = ctx_factory(cfg, ssh, sql, cluster, props, log, run_dir)
    try:
        results = pgcases.run_cases(specs, factory, run_dir, log)
    finally:
        pass
    summary = {
        "run_dir": str(run_dir), "started": run_dir.name, "db_dir": cfg.get("DB_DIR"),
        "version": cfg.get("DB_VERSION"), "consensus": cfg.raw("DEPLOY_CONSENSUS"),
        "hosts": cfg.all_hosts, "region_group_knobs": cfg.region_group_knobs(),
        "cases": results,
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
        if record["status"] != pgcases.PASS:
            failed = [c["name"] for c in record["checks"] if not c["ok"]]
            log(f"  {record['status']:<5} {record['case_id']:<12} {record['skipped'] or failed}")
    _report(run_dir, log)
    return 0 if counts.get(pgcases.FAIL, 0) == 0 else 1


def cmd_run(args: argparse.Namespace) -> int:
    wanted = list(args.case or [])
    if not pgcases.CASES:
        print("用例注册表为空：PROACTIVE 用例集尚未实现，暂无可运行用例 —— 期望值与族清单见 "
              "references/case-catalog.md 与 references/proactive-spec.md")
        return 0
    missing = [c for c in wanted if c not in pgcases.CASE_INDEX]
    if missing:
        print(f"未知用例 id：{', '.join(missing)}（用 list-cases 查看已登记用例）")
        return 2
    specs = [s for s in pgcases.CASES if s.case_id in wanted]
    if not specs:
        print("未选择任何用例：请用 --case <id>（见 list-cases）")
        return 2
    args.command = "run"
    return _run_matrix(args, specs)


def cmd_matrix(args: argparse.Namespace) -> int:
    specs = list(pgcases.CASES)
    # 分层（tier）：smoke = 各族 gate 用例；core = P0+P1（默认）；full = 全部。
    # 分层只决定**跑多少条**，不改变任何断言口径（同一条用例在任何分层下判定一致）。
    tier = (getattr(args, "tier", None) or load_config(args.conf).raw("PG_TIER")
            or "core").strip().lower()
    if tier == "smoke":
        specs = [s for s in specs if s.gate]
    elif tier == "core":
        specs = [s for s in specs if s.priority in {"P0", "P1"}]
    elif tier != "full":
        print(f"未知分层 PG_TIER={tier}（可选 smoke/core/full）")
        return 2
    print(f"tier={tier}：选中 {len(specs)} 条用例")
    if args.area:
        specs = [s for s in specs if s.area in set(args.area)]
    if args.priority:
        specs = [s for s in specs if s.priority in set(args.priority)]
    if not specs:
        # 空注册表（或筛选后为空）：不建结果目录、不 ssh、不抛异常。
        print("用例注册表为空（或筛选后无匹配）：PROACTIVE 用例集尚未实现，本轮不启动、"
              "不写结果目录 —— 见 references/case-catalog.md")
        return 0
    args.command = "matrix"
    return _run_matrix(args, specs)


def cmd_catalog(args: argparse.Namespace) -> int:
    """输出中文用例目录（按领域分组，含优先级/模型/gate 标记）。"""
    import collections

    out: list[str] = []
    grouped: dict[str, list] = collections.OrderedDict()
    for spec in pgcases.CASES:
        grouped.setdefault(spec.area, []).append(spec)
    knobs = load_config(args.conf).region_group_knobs()
    out.append("# RegionGroup 积极扩容（PROACTIVE）用例目录")
    out.append("")
    out.append(f"- 用例总数：**{len(pgcases.CASES)}**")
    out.append(f"- 族模块：{', '.join(pgcases.FAMILIES) or '（仅核心用例）'}")
    out.append("- 扩容参数（本轮 conf 写入值）：" + "，".join(f"`{k}={v}`" for k, v in knobs.items()))
    out.append("")
    for area, specs in grouped.items():
        out.append(f"## {area}（{len(specs)} 条）")
        out.append("")
        out.append("| 用例 | 优先级 | 模型 | 标题 | 标记 |")
        out.append("|---|---|---|---|---|")
        for spec in specs:
            marks = []
            if spec.gate:
                marks.append("smoke")
            if spec.needs_restart:
                marks.append("需重启")
            out.append(f"| {spec.case_id} | {spec.priority} | {spec.model} | {spec.title} | "
                       f"{'、'.join(marks) or '—'} |")
        out.append("")
    text = "\n".join(out)
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"已写出 {args.out}（{len(pgcases.CASES)} 条用例）")
    else:
        print(text)
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir).resolve()
    if not (run_dir / "summary.json").is_file():
        print(f"目录里没有 summary.json：{run_dir}")
        return 1
    _report(run_dir, print)
    return 0


def _report(run_dir: Path, log) -> None:
    data = json.loads((run_dir / "summary.json").read_text(encoding="utf-8"))
    cases = data["cases"]
    counts: dict[str, int] = {}
    for record in cases:
        counts[record["status"]] = counts.get(record["status"], 0) + 1
    lines = [f"# RegionGroup 积极扩容（PROACTIVE）用例执行报告 — {run_dir.name}", "",
             f"- 数据库版本：{data.get('version')}（{data.get('db_dir')}）",
             f"- 共识协议：{data.get('consensus')}；主机：{', '.join(data.get('hosts', []))}",
             f"- 扩容参数：{data.get('region_group_knobs')}",
             f"- 用例数：{len(cases)}；结果：" + "，".join(f"{k} {v}" for k, v in sorted(counts.items())),
             "", "| 用例 | 结果 | 领域 | 模型 | 优先级 | 耗时(s) | 说明 |", "|---|---|---|---|---|---|---|"]
    for record in cases:
        failed = [c["name"] for c in record["checks"] if not c["ok"]]
        note = record["skipped"] or ("；".join(failed) if failed else "全部断言通过")
        lines.append(f"| {record['case_id']} | {record['status']} | {record['area']} | "
                     f"{record['model']} | {record['priority']} | {record['seconds']} | {note} |")
    lines += ["", "## 断言明细", "",
              "> 收尾三件套（sync lag 归零 / 副本一致性 / ERROR-WARN 日志扫描）作为每个用例的"
              "普通断言计入判定：任一条不过，该用例不可能 PASS。", ""]
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
    parser = argparse.ArgumentParser(
        prog="pg.sh",
        description="IoTDB/TimechoDB RegionGroup 积极扩容（PROACTIVE）测试技能")
    parser.add_argument("--conf", default=str(DEFAULT_CONF))
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

    sub.add_parser("upgrade").set_defaults(func=cmd_upgrade)

    props = sub.add_parser("props")
    props.add_argument("--set", action="append", metavar="KEY=VALUE")
    props.set_defaults(func=cmd_props)

    sub.add_parser("teardown").set_defaults(func=cmd_teardown)

    run = sub.add_parser("run")
    run.add_argument("--case", action="append")
    run.add_argument("--run-id")
    run.set_defaults(func=cmd_run)

    matrix = sub.add_parser("matrix")
    matrix.add_argument("--area", action="append")
    matrix.add_argument("--priority", action="append")
    matrix.add_argument("--tier", choices=["smoke", "core", "full"])
    catalog = sub.add_parser("catalog")
    catalog.add_argument("--out")
    catalog.set_defaults(func=cmd_catalog)
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
    except NotImplementedError as exc:
        # 占位模块（pgops/pgprops 或未实现的用例集）被调用时给出中文提示而不是栈：
        # selftest/doctor/deploy/prepare/teardown 路径不会走到这里。
        print(f"未实现：{exc}")
        return 2
    except (ConfigError, RemoteError) as exc:
        print(f"FAILED: {exc}")
        return 1
    except KeyboardInterrupt:
        print("interrupted")
        return 130


if __name__ == "__main__":
    sys.exit(main())
