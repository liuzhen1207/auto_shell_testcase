"""Case matrix parsing and the end-to-end case runner."""

from __future__ import annotations

import json
import shlex
import shutil
import time
import traceback
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .benchmark import BenchmarkDriver, BenchmarkRun
from .cluster import ROLE_CN, ROLE_DN, Cluster, status_is
from .config import Config
from .remote import SqlClient, SshRunner, wait_until
from .remove import RemoveError, Remover, Target
from .verify import SyncLagWaiter, Verifier

PASS = "PASS"
FAIL = "FAIL"
SKIP = "SKIP"
PARTIAL = "PARTIAL"

COLUMNS = (
    "case_id",
    "target",
    "selector",
    "abnormal",
    "data_rf",
    "schema_rf",
    "workloads",
    "notes",
    # 9th column (optional): extra verification stages, comma separated.
    #   object_size           -- TDB-835 guard: per-replica ObjectSize vs physical .bin bytes
    #   object_delete_residue -- TDB-861 probe: new replica keeps already-deleted OBJECT files
    #   cold_restart          -- stop, drop TableObjectSizeFile_* (cache-less start), re-audit
    "extras",
)


@dataclass
class Case:
    case_id: str
    target: str
    selector: str
    abnormal: list[str] = field(default_factory=list)
    data_rf: str = "default"
    schema_rf: str = "default"
    workloads: str = "default"
    notes: str = ""
    extras: list[str] = field(default_factory=list)

    def resolved_workloads(self, cfg: Config) -> list[str]:
        return cfg.workload_set() if self.workloads == "default" else [w for w in self.workloads.split(",") if w]

    def resolved_data_rf(self, cfg: Config) -> int:
        return cfg.get_int("DATA_REPLICATION_FACTOR") if self.data_rf == "default" else int(self.data_rf)

    def resolved_schema_rf(self, cfg: Config) -> int:
        return (
            cfg.get_int("SCHEMA_REPLICATION_FACTOR")
            if self.schema_rf == "default"
            else int(self.schema_rf)
        )


def max_removable_dns(available: int, floor: int) -> int:
    """How many DataNodes may be removed while retaining ``floor`` of them."""
    return max(0, available - floor)


def cn_quorum(members: int) -> int:
    """Votes a ConfigRegion of ``members`` ConfigNodes needs to make progress.

    The ConfigRegion replica set *is* the ConfigNode set, so this is the cluster's
    own availability floor.  At three ConfigNodes a removal leaves two, and a
    two-member group needs *both* -- removing one and then stopping another takes
    the cluster below quorum, where an outage is the correct behaviour rather
    than a defect.
    """
    return members // 2 + 1


def cn_below_quorum(cn_total: int, *, removed: int, down: int) -> tuple[int, int, bool]:
    """(members, available, below_quorum) after ``removed`` removals and ``down`` faults."""
    members = max(cn_total - removed, 0)
    available = max(members - down, 0)
    if members <= 0:
        return members, available, False
    return members, available, available < cn_quorum(members)


def is_replication_factor_guard(text: str) -> bool:
    """True when ``text`` is the ConfigNode's replication-factor refusal.

    rc2 words it as ``... must retain at least 3 of them
    (max(schema_replication_factor=3, data_replication_factor=3)) ...`` — note
    the underscores, so matching only the older ``replication factor`` spelling
    reports a correct refusal as an unexpected rejection.
    """
    lower = text.lower()
    return any(
        marker in lower
        for marker in (
            "replication factor",
            "replication_factor",
            "must retain at least",
            "keep enough replicas",
            "rep num",
        )
    )


@dataclass
class CaseResult:
    case_id: str
    status: str
    problems: list[str] = field(default_factory=list)
    steps: list[str] = field(default_factory=list)
    elapsed_sec: float = 0.0
    artifacts: str = ""
    backup: str = ""
    workloads: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def cn_removal_target(
    left: list[str],
    removed: list[str],
    leader: str | None,
    *,
    leader_first: bool,
) -> str | None:
    """Which ConfigNode to remove next, as a pure function.

    The removal order is the entire variable that `shrink` and
    `shrink_leader_first` exist to isolate, so the decision is kept separate from
    the removal machinery and tested directly.  An earlier version buried it
    inline, the call site silently stopped forwarding the flag, and four runs
    that were believed to be "Leader first" actually repeated the default order.
    """
    if leader is None:
        return None
    if leader_first and not removed and leader in left:
        # Take the Leader out of the FIRST removal only -- not "always the
        # current Leader", which is a different scenario.
        return leader
    if not leader_first and len(left) == 2 and leader in left:
        # Leave the Leader in place until the group is down to two, so the
        # 2 -> 1 step is the one that removes it.
        return leader
    followers = [h for h in left if h != leader]
    return followers[0] if followers else leader


def load_cases(path: Path, only: list[str] | None = None) -> list[Case]:
    cases: list[Case] = []
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("\t")]
        if len(parts) < 4:
            raise ValueError(f"{path}:{lineno}: expected at least 4 tab separated columns")
        parts += [""] * (len(COLUMNS) - len(parts))
        case = Case(
            case_id=parts[0],
            target=parts[1].lower(),
            selector=parts[2].lower(),
            abnormal=[a for a in parts[3].split(",") if a] or ["none"],
            data_rf=parts[4] or "default",
            schema_rf=parts[5] or "default",
            workloads=parts[6] or "default",
            notes=parts[7],
            extras=[e for e in parts[8].split(",") if e] if len(parts) > 8 else [],
        )
        if only and case.case_id not in only:
            continue
        cases.append(case)
    if only:
        known = {c.case_id for c in cases}
        missing = [c for c in only if c not in known]
        if missing:
            raise ValueError(f"unknown case id(s): {', '.join(missing)}")
    return cases


class CaseRunner:
    def __init__(self, cfg: Config, ssh: SshRunner, sql: SqlClient, log, results_root: Path):
        self.cfg = cfg
        self.ssh = ssh
        self.sql = sql
        self.log = log
        self.results_root = results_root
        self.cluster = Cluster(cfg, ssh, sql, log)
        # Hosts this case deliberately takes down (its own removal target[s]).  They
        # must not be judged as "can never reach syncLag 0": they are down on purpose,
        # and treating them as permanently unsyncable raises a bogus sync-lag problem
        # AND makes the consistency sweep bail out before it can run.
        self._by_design_gone: set[str] = set()

    # ------------------------------------------------------------------
    def run(self, case: Case) -> CaseResult:
        started = time.time()
        self._by_design_gone = set()
        artifacts = self.results_root / "cases" / case.case_id
        if artifacts.exists():
            # Keep the previous verdict before wiping the directory.  Re-running
            # one case id is normal -- comparing two orderings of the same
            # scenario, or repeating a flaky case -- and silently destroying the
            # earlier evidence makes the comparison impossible after the fact.
            # (Learned the hard way: an A/B run of the ConfigNode shrink case
            # lost its first result this way, leaving only a log line.)
            previous = artifacts / "result.json"
            if previous.is_file():
                archive = self.results_root / "previous"
                archive.mkdir(parents=True, exist_ok=True)
                stamp = time.strftime("%Y%m%d_%H%M%S", time.localtime(previous.stat().st_mtime))
                shutil.copy2(previous, archive / f"{case.case_id}.{stamp}.json")
            shutil.rmtree(artifacts)
        artifacts.mkdir(parents=True, exist_ok=True)

        result = CaseResult(
            case_id=case.case_id,
            status=PASS,
            artifacts=str(artifacts),
            workloads=case.resolved_workloads(self.cfg),
        )
        verifier = Verifier(self.cfg, self.cluster, self.ssh, self.sql, self.log, artifacts)
        sync_waiter = SyncLagWaiter(
            self.cfg, self.cluster, self.log, health=self._unsyncable_nodes
        )
        bench: BenchmarkDriver | None = None
        run: BenchmarkRun | None = None
        benchmark_started: float | None = None
        # Windows in which fault injection deliberately took a ConfigNode down,
        # and the subset of those that really left the ConfigRegion without a
        # quorum (see `_exposed_outage`).  `dn_fault_outage` holds the same for a
        # DataNode that fault injection stopped or restarted (see
        # `_exposed_dn_outage`).
        fault_outage: list[tuple[float, float | None]] = []
        dn_fault_outage: list[tuple[float, float | None]] = []
        exposed_outage: list[tuple[float, float | None]] = []
        remover: Remover | None = None

        self.log(f"=== case {case.case_id}: {case.notes or ''}".rstrip())

        skip_reason = self._preflight_skip(case)
        if skip_reason:
            self.log(f"  SKIP: {skip_reason}")
            result.steps.append(skip_reason)
            result.status = SKIP
            return self._finish(result, started, artifacts, verifier)

        try:
            self._prepare_cluster(case, artifacts, result)
            self.log("-- stage: benchmark")
            bench, run, benchmark_started = self._start_benchmark(case, artifacts, result)

            self.log("-- stage: remove")
            remover = Remover(self.cfg, self.cluster, self.ssh, self.sql, self.log)
            if "object_delete_residue" in case.extras and not self.cfg.get_bool(
                "OBJECT_PROBE_MIGRATE"
            ):
                # Legacy injection, kept for builds whose DELETE path still writes
                # GC-journal records: hand the statement to the remover so the
                # abnormal op `delete_objects` keeps the GC busy during the
                # snapshot.  Default is off -- see `_object_audits`.
                remover.object_delete_stmt = self._object_delete_burst(run, result)
            # Exposed so `_heal_after_remove` can undo a leaked disk-full
            # threshold mid-case instead of waiting for teardown (which may
            # itself fail, and is too late for the sync-lag gate anyway).
            self._remover = remover
            if case.selector in {"shrink", "shrink_leader_first"}:
                # Its own loop: remove nodes one by one until only the
                # replication factor's worth remain, then probe the guard.  The
                # DataNode case asserts the documented refusal; the ConfigNode
                # case only records what it observes, because no ConfigNode-side
                # guard is documented (see `_remove_until_cn_rf_limit`).
                if case.target == "cn":
                    result.problems.extend(
                        self._remove_below_cn_quorum(
                            case,
                            remover,
                            result,
                            leader_first=case.selector == "shrink_leader_first",
                        )
                    )
                else:
                    result.problems.extend(
                        self._remove_until_rf_limit(case, run, remover, artifacts, result)
                    )
            elif case.selector == "skip":
                # Snapshot-race probes inject their own window (OBJECT churn +
                # `MIGRATE REGION`, see `_object_audits`); a whole-node removal
                # would only repeat the same snapshot logic behind an unrelated
                # leader-balancing race, which is what wedged this case before.
                self._wait_remove_moment(benchmark_started)
                result.steps.append(
                    "remove stage skipped by selector=skip: the TDB-861 window is armed "
                    "by the OBJECT churn + MIGRATE REGION probe"
                )
            else:
                target = self._resolve_target(case, run, remover, result, artifacts)
                if target is None:
                    # The case cannot be reproduced in this configuration.
                    result.status = SKIP
                    return self._finish(result, started, artifacts, verifier)
                self._wait_remove_moment(benchmark_started)
                if target.expect_reject:
                    # The node id does not exist: every remove statement must
                    # be rejected and the cluster must stay healthy.
                    ops = list(case.abnormal)
                    if "invalid_sql" not in ops:
                        ops.append("invalid_sql")
                    result.problems.extend(remover.run_abnormal(ops, target=target, delay=0))
                    result.problems.extend(
                        self._remove_and_wait(
                            remover, target, artifacts, result, expect_reject=True
                        )
                    )
                else:
                    remover.submit(target.role, target.node_id)
                    result.problems.extend(
                        remover.run_abnormal(
                            case.abnormal,
                            target=target,
                            delay=self.cfg.get_int("ABNORMAL_DELAY_SEC"),
                            outage=fault_outage,
                            dn_outage=dn_fault_outage,
                        )
                    )
                    exposed_outage = self._exposed_outage(target, fault_outage, result)
                    exposed_outage += self._exposed_dn_outage(target, dn_fault_outage, result)
                    result.problems.extend(
                        self._remove_and_wait(remover, target, artifacts, result)
                    )

            if "object_many" in case.extras and run is not None:
                from .object_audit import wait_object_file_count

                target_files = self.cfg.get_int("OBJECT_MANY_TARGET_FILES")
                got = wait_object_file_count(
                    self.cfg,
                    self.ssh,
                    target_files,
                    timeout=float(self.cfg.raw("OBJECT_MANY_TIMEOUT_SEC", "1800") or 1800),
                    log=self.log,
                )
                result.steps.append(f"海量 OBJECT 写入：{got} 个文件（目标 {target_files}）")
            if "object_big" in case.extras and run is not None:
                from .object_audit import wait_object_volume

                target = int(float(self.cfg.raw("OBJECT_BIG_TARGET_GIB", "4") or 4) * 2**30)
                reached = wait_object_volume(
                    self.cfg,
                    self.ssh,
                    target,
                    timeout=float(self.cfg.raw("OBJECT_BIG_WRITE_TIMEOUT_SEC", "2400") or 2400),
                    log=self.log,
                )
                result.steps.append(
                    f"大 OBJECT 写入：{'达到' if reached else '未达到'} {target / 2**30:.1f} GiB"
                )
            self.log("-- stage: drain load and sync")
            if run is not None:
                if self.cfg.get_bool("BM_WAIT_FINISH"):
                    self.log("  waiting for the benchmark to finish on its own")
                    result.problems.extend(
                        bench.wait_finish(
                            run, self.cfg.get_int("BM_MAX_RUNTIME_SEC"), exposed_outage
                        )
                    )
                result.problems.extend(
                    f"{k}: {v}" for k, v in bench.logs_have_errors(run, exposed_outage).items()
                )
                self.log("  stopping the load")
                bench.stop(run)

            self.log("-- stage: sync lag")
            if sync_waiter.available():
                sync_result = sync_waiter.wait()
                if not sync_result.ok:
                    result.problems.append(f"sync-lag gate: {sync_result.reason}")
                elif sync_result.reason:
                    # A non-empty reason with ok=True means the gate stopped early for a
                    # known-benign cause; keep the observation visible without failing.
                    result.steps.append(f"sync-lag gate: {sync_result.reason}")
            else:
                result.steps.append("sync-lag gate skipped (MONITOR_URL not configured)")

            if self.cfg.get_bool("CONSISTENCY_CHECK") and run is not None:
                self.log("-- stage: replica consistency")
                refresh = BenchmarkDriver(self.cfg, self.sql, artifacts, self.log)
                refresh.resolve_columns(run)
                result.problems.extend(
                    verifier.consistency_check(
                        run,
                        sync_waiter=sync_waiter,
                        data_rf=case.resolved_data_rf(self.cfg),
                    )
                )

            self._case_table_db = getattr(run, "table_db", "") if run is not None else ""
            if set(case.extras) & {"object_size", "object_delete_residue", "cold_restart"}:
                self.log("-- stage: object audits")
                result.problems.extend(
                    self._object_audits(case, artifacts, result, run=run)
                )
                evidence = getattr(self, "_object_evidence", {})
                missing = [k for k, v in evidence.items() if not v[0]]
                if missing:
                    # The scenario's precondition never materialised (no OBJECT
                    # file on any replica / no OBJECT-GC deletion record), so the
                    # defect window was never created: PASS would claim a verdict
                    # the run did not earn, FAIL would blame the product.
                    detail = "；".join(f"{k}: {evidence[k][1]}" for k in missing)
                    reason = (
                        "OBJECT 场景前置条件未成立 ⇒ 未能注入目标缺陷窗口，判 SKIP（"
                        + detail
                        + "）"
                    )
                    self.log(f"  SKIP: {reason}")
                    result.steps.append(reason)
                    for problem in result.problems:
                        # Keep them as steps: a SKIP whose evidence is missing is
                        # only useful if the report says *why* it was missing.
                        result.steps.append(f"审计说明：{problem}")
                    result.status = SKIP
                    result.problems.clear()

            self.log("-- stage: logs")
            # Anything logged from this instant on comes from our own shutdown, not from
            # the scenario under test: bound the scan above so shutdown noise (interrupted
            # pipe buffers, half-written stack frames) is not reported as a product defect.
            # Hits before the bound are still reported -- a time bound, not a whitelist.
            harness_stop_epoch = int(time.time())
            self.log(
                "  log scan bounded to <= "
                + time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(harness_stop_epoch))
                + " (harness shutdown window excluded)"
            )
            self.cluster.stop_all()
            if self.cfg.get_bool("LOG_SCAN"):
                since = int(started) if self.cfg.raw("LOG_SCAN_MODE") == "since" else None
                result.problems.extend(
                    # The stop second itself is part of the harness window: our shutdown hook
                    # starts within it, and undated stack frames inherit that second.
                    verifier.check_logs(since_epoch=since, until_epoch=harness_stop_epoch - 1)
                )

        except Exception as exc:  # noqa: BLE001 - a crashed case is a failed case
            result.problems.append(
                f"case aborted: {exc}{self._abort_note(case, locals(), exc)}"
            )
            result.steps.append(traceback.format_exc(limit=4))
            self.log(f"  case aborted: {exc}")
        finally:
            if bench is not None and run is not None:
                try:
                    bench.stop(run)
                except Exception:  # noqa: BLE001
                    pass
            # A simulated disk-full is undone here so the property never leaks
            # into the next case, even when this one aborted.
            if remover is not None:
                remover.restore_pending_disk_state()

        return self._finish(result, started, artifacts, verifier)

    # ------------------------------------------------------------------
    def _finish(self, result: CaseResult, started: float, artifacts: Path, verifier: Verifier) -> CaseResult:
        result.elapsed_sec = round(time.time() - started, 1)
        if result.status != SKIP:
            result.status = FAIL if result.problems else PASS
        # Query-failure evidence must be taken *now*: the next case's prepare
        # resets every node log (measured: logs reset at 21:08:40 while this
        # case's result.json was written at 21:08:49), so a PASS case's 305
        # lines -- including the reasonless `Status code: 305` family -- would
        # otherwise be unrecoverable.  Cheap grep, best effort, never fatal.
        kept = verifier.snapshot_query_failures(since_epoch=int(started))
        if kept:
            result.steps.append(
                f"query-failure snapshot: {kept} line(s) -> server_305_snapshot.txt"
            )
        (artifacts / "result.json").write_text(
            json.dumps(result.to_dict(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        # Migration-class cases lose their evidence to the next cluster reset, which
        # wipes <DB_DIR>/logs.  A failure therefore snapshots every node log as plain
        # text into results/<run>/node_logs/<host>/ before the harness moves on.
        node_mode = self.cfg.raw("NODE_LOG_BACKUP", "fail").strip().lower()
        if node_mode in {"fail", "always"} and (node_mode == "always" or result.status == FAIL):
            scope = self.cfg.raw("NODE_LOG_BACKUP_SCOPE", "migration").strip().lower()
            markers = ("remove", "migrate", "object", "drain", "scale")
            if scope == "all" or any(m in result.case_id for m in markers):
                dest = self.results_root / "node_logs"
                try:
                    stats = verifier.backup_node_logs(dest)
                    taken = dest.relative_to(self.results_root.parent)
                    result.steps.append(
                        f"node logs: {stats['hosts']} 个节点 / {stats['files']} 个文件 / "
                        f"{stats['bytes'] // 1024} KiB -> {taken}"
                    )
                    self.log(
                        f"  node logs saved: {stats['hosts']} hosts, {stats['files']} files, "
                        f"{stats['bytes'] // 1024} KiB -> {taken}"
                    )
                except Exception as exc:  # noqa: BLE001 - evidence capture must not fail the case
                    self.log(f"  node log backup failed: {exc}")
        mode = self.cfg.raw("LOG_BACKUP", "fail")
        want_backup = mode == "always" or (mode == "fail" and result.status == FAIL)
        if want_backup:
            tag = f"{result.case_id}_{time.strftime('%Y%m%d_%H%M%S')}"
            try:
                dest = verifier.backup_logs(tag, self.results_root / "log_backup")
                result.backup = str(dest)
            except Exception as exc:  # noqa: BLE001
                self.log(f"  log backup failed: {exc}")
        # Artifacts are kept even on PASS: they are cheap and are the evidence
        # for what the queries actually returned.
        self.log(f"=== {result.case_id}: {result.status} ({result.elapsed_sec}s)")
        for problem in result.problems[:20]:
            self.log(f"    - {problem}")
        return result

    # ------------------------------------------------------------------
    def _prepare_cluster(self, case: Case, artifacts: Path, result: CaseResult) -> None:
        data_rf = (
            self.cfg.get_int("DATA_REPLICATION_FACTOR") if case.data_rf == "default" else int(case.data_rf)
        )
        schema_rf = (
            self.cfg.get_int("SCHEMA_REPLICATION_FACTOR") if case.schema_rf == "default" else int(case.schema_rf)
        )
        self.log("-- stage: cluster")
        self.cluster.discover_ports()
        held_back = self._held_back_dns(case)
        # Self-heal a leaked disk-full simulation BEFORE the cluster starts, so
        # the node reads a sane threshold at boot.  A raise that was never
        # restored survives in iotdb-system.properties, and without this the
        # failure surfaces much later as an unrelated case complaining that its
        # benchmark objects were never created -- which is how one leak poisoned
        # eight consecutive cases on 2026-09-18.
        stale = self.cluster.clear_raised_disk_thresholds(
            list(self.cfg.dn_hosts) + list(self.cfg.cn_hosts)
        )
        if stale:
            self.log(
                f"  WARNING: cleared a leaked disk_space_warning_threshold on "
                f"{', '.join(stale)}; a previous case did not restore it"
            )
        if held_back:
            self.log(
                f"  holding back {', '.join(sorted(held_back))} from the cluster start; "
                f"this case joins it as the expansion node"
            )
        if self.cfg.get_bool("RESET_CLUSTER_PER_CASE"):
            self.log(f"  resetting cluster (data_rf={data_rf}, schema_rf={schema_rf})")
            self.cluster.stop_all()
            self.cluster.wipe()
            self.cluster.configure(data_rf=data_rf, schema_rf=schema_rf)
            if not self.cluster.start_all(exclude_dn=held_back):
                raise RuntimeError("cluster did not become healthy after reset")
            # A wipe deletes data/, and on 2.0.12.1 the *runtime* activation state lives under
            # data/ as well, while start_all() -> ensure_license() short-circuits because
            # activation/license survives the wipe.  Without re-submitting the code the fresh
            # cluster answers every schema write with "307: Schema write operations are not
            # allowed until this node is activated", which surfaces as "case aborted: benchmark
            # objects were not created within 900s" and makes *every* case fail (measured
            # 2026-10-05 on RC5, first case of the matrix).  Submitting is idempotent, so do it
            # here for the same reason cli.prepare does it.
            self._resubmit_activation()
        else:
            if not self.cluster.wait_healthy(
                timeout=self.cfg.get_int("CLUSTER_START_TIMEOUT_SEC"), exclude_dn=held_back
            ):
                raise RuntimeError("cluster is not healthy and RESET_CLUSTER_PER_CASE=false")
        result.steps.append(f"cluster ready: {self.cluster.status().summary()}")

    # ------------------------------------------------------------------
    def _resubmit_activation(self) -> None:
        """Re-submit the activation code after a wipe + start.

        Wipe keeps ``activation/`` but clears the runtime activation state, and
        ``ensure_license()`` returns early while ``activation/license`` exists, so nothing
        re-submits the code.  On such a cluster the first schema write fails with
        ``307: Schema write operations are not allowed until this node is activated``.
        The call is idempotent, so it is safe on every reset.
        """
        if getattr(self.cfg, "stub_run", False) or not self.cfg.get_bool("DEPLOY_ACTIVATE"):
            return
        from .deploy import resolve_license_code  # local import: deploy pulls in runner bits

        try:
            code = resolve_license_code(
                self.cfg.raw("LICENSE_CODE"), code_file=self.cfg.raw("LICENSE_CODE_FILE")
            )
        except Exception as exc:  # noqa: BLE001 - never fail a case over activation plumbing
            self.log(f"  WARNING: no activation code ({exc}); a wiped cluster may stay unactivated")
            return
        out = self.sql.sql(self.cfg.cli_host, f"activate '{code}'", check=False)
        lowered = out.lower()
        if "error" in lowered or "exception" in lowered:
            self.log(f"  WARNING: activation was rejected: {out.strip()[:200]}")
        else:
            self.log("  re-submitted the activation code after the wipe")

    def _start_benchmark(self, case: Case, artifacts: Path, result: CaseResult):
        names = case.resolved_workloads(self.cfg)
        bench = BenchmarkDriver(self.cfg, self.sql, artifacts, self.log)
        bench.create_users()
        run = bench.prepare(names)
        bench.start(run)
        started = time.time()
        bench.wait_objects_ready(run, timeout=900)
        bench.resolve_columns(run)
        (artifacts / "benchmark_layout.json").write_text(
            json.dumps(
                {
                    "stub": bool(getattr(self.cfg, "stub_run", False)),
                    "tree_db": run.tree_db,
                    "table_db": run.table_db,
                    "base_table": run.base_table,
                    "view_table": run.view_table,
                    "columns": run.columns,
                    "object_columns": run.object_columns,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        return bench, run, started

    # ------------------------------------------------------------------
    # ------------------------------------------------------------------
    # OBJECT / region-migration defect scenarios
    # ------------------------------------------------------------------
    def _object_delete_burst(
        self, run: BenchmarkRun | None, result: CaseResult
    ) -> str:
        """DELETE OBJECT rows right before the removal, so the GC runs under the snapshot.

        TDB-861 needs the OBJECT GC to be physically unlinking files while the
        migrating region's snapshot is being taken.  Issuing the DELETE burst at
        the last moment (and again with a short spacing) is what puts the two in
        the same window; waiting for the GC to finish first would remove the
        race the case exists for.
        """
        from .object_audit import deleted_object_paths
        from .remote import first_line, looks_like_sql_error, parse_table

        if run is None or not getattr(run, "table_db", "") or not getattr(run, "base_table", ""):
            result.steps.append("OBJECT 删除阶段跳过：表名未解析（benchmark 未起来）")
            return ""
        age_ms = int(self.cfg.raw("OBJECT_DELETE_AGE_MS", "10000") or 10000)
        rounds = int(self.cfg.raw("OBJECT_DELETE_ROUNDS", "3") or 3)
        interval = float(self.cfg.raw("OBJECT_DELETE_INTERVAL_SEC", "2") or 2)
        full_delete = f"delete from {run.table_db}.{run.base_table};"
        windowed = (
            f"delete from {run.table_db}.{run.base_table} "
            f"where {run.time_column} <= {int(time.time() * 1000) - age_ms}"
        )

        def rows_of(statement: str) -> str:
            out = self.sql.sql(self.cfg.cli_host, statement, dialect="table", check=False)
            for row in parse_table(out):
                for value in row.values():
                    digits = value.strip().replace(",", "")
                    if digits.isdigit():
                        return digits
            return first_line(out)[:80]

        count_stmt = f"select count(*) from {run.table_db}.{run.base_table}"
        before = rows_of(count_stmt)
        # A whole-table DELETE puts every region's OBJECT files in front of the GC;
        # a time-window DELETE silently matches nothing when the benchmark writes
        # with an offset clock, and then the case has no GC to race against.
        stmt = full_delete
        out = self.sql.sql(self.cfg.cli_host, full_delete, dialect="table", check=False)
        if looks_like_sql_error(out):
            self.log(f"  整表删除被拒绝，退回时间窗删除：{first_line(out)[:120]}")
            stmt = windowed
            out = self.sql.sql(self.cfg.cli_host, windowed, dialect="table", check=False)
        result.steps.append(f"OBJECT 删除 #1: {stmt} -> {first_line(out)[:140]}")
        self.log(f"  OBJECT 删除 #1: {first_line(out)[:140]}")
        for i in range(1, rounds):
            time.sleep(interval)
            out = self.sql.sql(self.cfg.cli_host, stmt, dialect="table", check=False)
            result.steps.append(f"OBJECT 删除 #{i + 1}: {stmt} -> {first_line(out)[:140]}")
            self.log(f"  OBJECT 删除 #{i + 1}: {first_line(out)[:140]}")
        after = rows_of(count_stmt)
        result.steps.append(f"OBJECT 删除前后行数：{before} -> {after}")
        self.log(f"  删除前后行数：{before} -> {after}")

        # Seal the memtables first: the OBJECT GC only reclaims files whose rows
        # are already in a sealed tsfile, so without a flush a DELETE just sits in
        # memory and the deletion log stays empty (measured 2026-10-24: 0 GC
        # records after a whole-table DELETE of 78 rows).
        flush_out = self.sql.sql(self.cfg.cli_host, "flush;", check=False)
        result.steps.append(f"OBJECT 删除后 flush：{first_line(flush_out)[:120]}")
        self.log(f"  OBJECT 删除后 flush：{first_line(flush_out)[:120]}")

        # Wait for the FIRST deletion record, not for the whole backlog.  In
        # 2.0.12.1 the OBJECT GC starts ~5 min after the DELETE (measured
        # 2026-10-25: records began at 10:24:47, seconds after a 300s wait had
        # given up) and then unlinks in a burst.  The removal has to be issued
        # while that burst is still running, otherwise the snapshot can never
        # see a file the leader is about to delete -- the TDB-861 race.
        want = int(self.cfg.raw("OBJECT_GC_MIN_RECORDS", "20") or 20)
        deadline = time.time() + float(self.cfg.raw("OBJECT_GC_PRIME_TIMEOUT_SEC", "660") or 660)
        seen = 0
        while time.time() < deadline:
            seen = 0
            for host in self.cfg.dn_hosts:
                seen += len(deleted_object_paths(self.cfg, self.ssh, host, None))
            if seen > 0:
                break
            time.sleep(5)
        result.steps.append(
            f"OBJECT GC 预热：等到 {seen} 条删除记录后立即进入 remove"
            f"（判定门槛 {want} 条；0 条说明 DELETE 后 11 分钟内 GC 未启动）"
        )
        self.log(
            f"  OBJECT GC 预热：累计 GC 记录 {seen} 条，首次触发即进入 remove（门槛 {want}）"
        )
        return stmt

    def _object_audits(
        self, case: Case, artifacts: Path, result: CaseResult, run=None
    ) -> list[str]:
        """TDB-835 / TDB-861 audits; returns the problems to append."""
        from .object_audit import (
            audit_deleted_object_residue,
            audit_object_size,
            cold_restart_without_size_cache,
            write_audit,
        )

        extras = set(case.extras)
        problems: list[str] = []
        hosts = list(self.cfg.dn_hosts)
        table_db = getattr(self, "_case_table_db", "") or ""
        databases = [table_db] if table_db else []
        self._object_evidence: dict[str, bool] = {}
        if extras & {"object_size", "cold_restart"}:
            audit = audit_object_size(
                self.cfg, self.ssh, self.sql, self.log, hosts=hosts, databases=databases
            )
            self._object_evidence["object_size"] = (
                audit.evidence,
                f"有实体 OBJECT 的副本 {sum(1 for r in audit.replicas if r.get('physical_bytes', 0) > 0)}"
                f"/{len(audit.replicas)}",
            )
            write_audit(artifacts, "object_size_audit", audit.to_dict())
            problems.extend(audit.problems)
            result.steps.append(
                f"OBJECT 大小审计：{len(audit.replicas)} 个副本，{len(audit.problems)} 个问题"
            )
            if "cold_restart" in extras:
                try:
                    cold_restart_without_size_cache(
                        self.cfg, self.cluster, self.ssh, self.log, artifacts
                    )
                except Exception as exc:  # noqa: BLE001
                    problems.append(f"冷启动（无表大小缓存）失败：{exc}")
                else:
                    after = audit_object_size(
                        self.cfg,
                        self.ssh,
                        self.sql,
                        self.log,
                        hosts=hosts,
                        label="冷启动后 ",
                        databases=databases,
                    )
                    prev = self._object_evidence.get("object_size", (False, ""))
                    self._object_evidence["object_size"] = (
                        prev[0] or after.evidence,
                        f"{prev[1]}；冷启动后有实体 OBJECT 的副本 "
                        f"{sum(1 for r in after.replicas if r.get('physical_bytes', 0) > 0)}"
                        f"/{len(after.replicas)}",
                    )
                    write_audit(artifacts, "object_size_audit_cold", after.to_dict())
                    problems.extend(after.problems)
                    result.steps.append(
                        f"冷启动后 OBJECT 大小审计：{len(after.replicas)} 个副本，"
                        f"{len(after.problems)} 个问题"
                    )
        if "object_single" in extras:
            from .object_audit import run_single_object_scenario
            from .object_audit import write_audit

            single = run_single_object_scenario(
                self.cfg,
                self.ssh,
                self.sql,
                self.log,
                db=self.cfg.raw("OBJECT_SINGLE_DB", "objsingle"),
                total_bytes=int(float(self.cfg.raw("OBJECT_SINGLE_GIB", "4") or 4) * 2**30),
                chunk_bytes=int(float(self.cfg.raw("OBJECT_SINGLE_CHUNK_MIB", "8") or 8) * 2**20),
                read_chunk_bytes=int(
                    float(self.cfg.raw("OBJECT_SINGLE_READ_CHUNK_MIB", "256") or 256) * 2**20
                ),
                migrate=str(self.cfg.raw("OBJECT_SINGLE_MIGRATE", "true")).lower() in {"1", "true", "yes"},
            )
            self._object_evidence["object_single"] = (single.evidence, single.detail)
            write_audit(
                artifacts,
                "object_single_4g",
                {"detail": single.detail, "stats": single.stats, "problems": single.problems},
            )
            problems.extend(single.problems)
            result.steps.append(single.detail)
        if "object_many" in extras:
            from .object_audit import run_many_object_residue_probe

            if run is None or not (run.table_db and run.base_table and run.object_columns):
                self._object_evidence["object_many"] = (False, "没有可用的 table 模型 OBJECT 表")
                result.steps.append("海量 OBJECT 文件残留校验：本次运行没有 table 模型 OBJECT 表")
            else:
                many = run_many_object_residue_probe(
                    self.cfg,
                    self.ssh,
                    self.sql,
                    self.log,
                    db=run.table_db,
                    table=run.base_table,
                    target_files=self.cfg.get_int("OBJECT_MANY_TARGET_FILES"),
                    wait_timeout=float(self.cfg.raw("OBJECT_MANY_TIMEOUT_SEC", "1800") or 1800),
                    delete_first=self.cfg.raw("OBJECT_MANY_MODE", "overwrite") == "delete",
                    settle_sec=10.0,
                    recheck_sec=float(self.cfg.raw("OBJECT_MANY_RECHECK_SEC", "120") or 0),
                )
                self._object_evidence["object_many"] = (many.evidence, many.detail)
                write_audit(
                    artifacts,
                    "object_many_residue",
                    {"detail": many.detail, "stats": many.stats, "problems": many.problems},
                )
                problems.extend(many.problems)
                result.steps.append(f"海量 OBJECT 文件残留校验：{many.detail}")
        if "object_big" in extras:
            from .object_audit import run_big_object_migration_probe

            if run is None or not (run.table_db and run.base_table and run.object_columns):
                self._object_evidence["object_big"] = (False, "没有可用的 table 模型 OBJECT 表")
                result.steps.append("大 OBJECT 迁移校验：本次运行没有 table 模型 OBJECT 表")
            else:
                target_gib = float(self.cfg.raw("OBJECT_BIG_TARGET_GIB", "4") or 4)
                big = run_big_object_migration_probe(
                    self.cfg,
                    self.ssh,
                    self.sql,
                    self.log,
                    db=run.table_db,
                    table=run.base_table,
                    target_bytes=int(target_gib * 2**30),
                    wait_timeout=float(self.cfg.raw("OBJECT_BIG_TIMEOUT_SEC", "1800") or 1800),
                    migrate=self.cfg.get_bool("OBJECT_BIG_MIGRATE"),
                    sample_rows=self.cfg.get_int("OBJECT_BIG_SAMPLE_ROWS"),
                )
                self._object_evidence["object_big"] = (big.evidence, big.detail)
                write_audit(
                    artifacts,
                    "object_big_migration",
                    {"detail": big.detail, "stats": big.stats, "problems": big.problems},
                )
                problems.extend(big.problems)
                result.steps.append(f"大 OBJECT 迁移校验：{big.detail}")
        if "object_delete_residue" in extras and self.cfg.get_bool("OBJECT_PROBE_MIGRATE"):
            from .object_audit import ensure_object_probe_table, run_object_snapshot_probe

            db = self.cfg.raw("OBJECT_PROBE_DB", "objprobe") or "objprobe"
            table = self.cfg.raw("OBJECT_PROBE_TABLE", "t") or "t"
            ready = ensure_object_probe_table(self.cfg, self.sql, self.log, db, table)
            if not ready:
                self._object_evidence["object_delete_residue"] = (
                    False,
                    f"无法准备探针表 {db}.{table}（建表或写入 OBJECT 底料失败）",
                )
                result.steps.append(f"OBJECT 残留探针：探针表 {db}.{table} 未就绪")
            else:
                probe = run_object_snapshot_probe(
                    self.cfg,
                    self.ssh,
                    self.sql,
                    self.log,
                    db=db,
                    table=table,
                    rows=self.cfg.get_int("OBJECT_CHURN_ROWS"),
                    interval=float(self.cfg.raw("OBJECT_CHURN_INTERVAL_SEC", "1.5") or 1.5),
                    migrate=True,
                    min_records=self.cfg.get_int("OBJECT_GC_MIN_RECORDS"),
                    migration_timeout=float(
                        self.cfg.raw("OBJECT_PROBE_TIMEOUT_SEC", "240") or 240
                    ),
                )
                self._object_evidence["object_delete_residue"] = (probe.evidence, probe.detail)
                write_audit(artifacts, "object_residue_probe", probe.to_dict())
                problems.extend(probe.audit.problems)
                result.steps.append(f"OBJECT 残留探针：{probe.detail}")
        elif "object_delete_residue" in extras:
            residue = audit_deleted_object_residue(
                self.cfg, self.ssh, self.sql, self.log, databases=databases
            )
            self._object_evidence["object_delete_residue"] = (
                residue.evidence,
                f"leader 侧 OBJECT-GC 删除记录 {residue.gc_records} 条"
                f"（门槛 {residue.min_records}，低于门槛说明迁移快照与 GC 没并发上），"
                f"副本 {len(residue.replicas)} 个，残留差异 {len(residue.residue)} 组",
            )
            write_audit(artifacts, "object_residue_audit", residue.to_dict())
            problems.extend(residue.problems)
            result.steps.append(
                f"OBJECT 删除残留审计：{len(residue.replicas)} 个副本，"
                f"{len(residue.residue)} 组差异，{len(residue.problems)} 个确认残留"
            )
        return problems

    def _preflight_skip(self, case: Case) -> str | None:
        """A reason this case cannot run here, decided before any expensive work.

        These are knowable from the config alone, but they used to be resolved
        during target selection -- i.e. only after a full cluster reset and the
        benchmark warm-up.  That burned ~6 minutes per skipped case to reach a
        conclusion that was available up front.
        """
        if case.selector == "adding":
            return self._adding_skip(case)
        # A ConfigNode case whose own fault injection takes the ConfigNode group below
        # quorum by construction can never be judged on this topology: the control plane
        # stops answering, so the harness's own `show confignodes` fails and the case
        # aborts.  That is a topology limitation, not a product result -- say so up front
        # with the arithmetic instead of reporting it as a product failure.
        # Only faults that keep a ConfigNode down for the whole membership change count
        # here.  `restart_cn` is transient -- the node comes back -- so it must NOT be
        # allowed to turn a runnable case into a SKIP.
        cn_faults = sum(1 for op in case.abnormal if op in {"kill9_cn", "stop_cn"})
        if case.target == "cn" and cn_faults:
            members, available, below = cn_below_quorum(
                len(self.cfg.cn_hosts), removed=1, down=cn_faults
            )
            if below:
                return (
                    f"the control plane would be below quorum by construction: removing the target "
                    f"plus {cn_faults} ConfigNode fault(s) leaves {available} of {members} member(s), "
                    "which cannot elect a leader, so no ConfigNode could answer the harness's own "
                    "queries; run this case on a >=5-ConfigNode topology"
                )
        # An abnormal operation needs the same up-front check as a selector: if
        # the fault cannot be injected, the case would otherwise run to
        # completion with nothing injected and report a PASS for a scenario it
        # never exercised.  `dn_remove_other_diskfull` did exactly that -- it
        # filled nothing (20G cannot cross a 928G threshold) and still passed,
        # which is worse than the SKIP the selector-based case correctly produced.
        if "other_dn_diskfull" in case.abnormal:
            return self._diskfull_skip("other_dn_diskfull")
        if case.selector != "diskfull":
            return None
        return self._diskfull_skip("diskfull selector")

    def _held_back_dn(self, case: Case) -> str:
        """The DataNode to leave out of this case's cluster start, or ``""``.

        Only the `adding` case needs one, and only when the operator did not
        name a spare host outside `nodes.conf`: the last DataNode in the
        inventory is held back and joined during the case instead.  That way a
        cluster whose hosts are all in use still gets a real expansion node.
        """
        if case.selector != "adding" or self.cfg.get_list("SPARE_DN_HOSTS"):
            return ""
        candidates = [h for h in self.cfg.dn_hosts if h != self.cfg.cli_host]
        return candidates[-1] if candidates else ""

    def _held_back_dns(self, case: Case) -> set[str]:
        host = self._held_back_dn(case)
        return {host} if host else set()

    def _expansion_host(self, case: Case) -> str:
        """The host that joins as the new DataNode for an `adding` case."""
        spare = self.cfg.get_list("SPARE_DN_HOSTS")
        return spare[0] if spare else self._held_back_dn(case)

    def _adding_skip(self, case: Case) -> str | None:
        """Whether this `adding` case has a spare host *and* a legal removal.

        The joined DataNode is an ordinary member, so the cluster must still be
        able to give one up: the ConfigNode refuses a removal that would leave
        fewer than ``max(schema_rf, data_rf)`` DataNodes (see
        `RemoveDataNodeHandler.checkRegionReplication`), so an inventory too
        small to hold one back has to say so instead of failing mid-case.
        """
        expansion = self._expansion_host(case)
        if not expansion:
            return "adding selector skipped: no DataNode host is available to join"
        minimum = max(
            self.cfg.get_int("SCHEMA_REPLICATION_FACTOR"),
            self.cfg.get_int("DATA_REPLICATION_FACTOR"),
        )
        # Counting the joined node and then removing one leaves exactly the
        # nodes that were started, so that is the number the guard sees.
        available = len(self.cfg.dn_hosts) - len(self._held_back_dns(case))
        if available < minimum:
            return (
                f"adding selector skipped: holding back {expansion} leaves {available} "
                f"DataNodes, below the {minimum} required by max(schema_rf, data_rf)"
            )
        return None

    def _dn_status_of(self, host: str) -> str:
        for row in self.cluster.datanodes():
            if Cluster.row_ip(row) == host:
                return (row.get("Status") or "").strip()
        return ""

    def _wait_dn_joined(self, host: str, *, timeout: int) -> bool:
        """Wait for a newly started DataNode to register and report Running.

        A joining DataNode goes `Unknown` -> `Running` in a few seconds and never
        reports any "Adding" state -- `Adding` is a `RegionStatus`, not a
        `NodeStatus` -- so registration is the whole observable transition.
        """
        return wait_until(
            lambda: status_is(self._dn_status_of(host), "running", "readonly"),
            timeout=timeout,
            interval=5,
        )

    def _diskfull_skip(self, label: str) -> str | None:
        """A reason the disk-full state cannot be produced on any DataNode.

        `df` and the node's conf are readable while the node is stopped, so this
        also works between cases when the cluster is down.
        """
        if not self.cfg.get_bool("DISK_FULL_SIMULATE"):
            return f"{label} skipped: DISK_FULL_SIMULATE=false"
        remover = Remover(self.cfg, self.cluster, self.ssh, self.sql, self.log)
        # Exposed so `_heal_after_remove` can undo a leaked disk-full
        # threshold mid-case instead of waiting for teardown (which may
        # itself fail, and is too late for the sync-lag gate anyway).
        self._remover = remover
        why = f"{label} skipped: no DataNode host to inspect"
        for host in self.cfg.dn_hosts:
            possible, reason = remover.diskfull_can_simulate(host)
            if possible:
                return None
            why = f"{label} skipped: {reason}"
        return why

    def _exposed_outage(
        self,
        target: Target,
        outage: list[tuple[float, float | None]],
        result: CaseResult,
    ) -> list[tuple[float, float | None]]:
        """The down-windows in which the ConfigRegion really lacked a quorum.

        A fault that still leaves a majority of ConfigNodes serving is no excuse
        for errors, so its window is dropped and those errors stay failures.  Only
        a genuine below-quorum window explains them -- for example removing one of
        three ConfigNodes and then stopping another, which leaves one vote where
        two are needed (confirmed by R&D: at two ConfigNodes a restart cannot be
        made highly available).
        """
        if not outage:
            return []
        if not self.cfg.get_bool("CN_BELOW_QUORUM_EXPECTED_OUTAGE"):
            return []
        if target.role != ROLE_CN:
            # A DataNode fault says nothing about ConfigNode quorum.
            return []
        members, available, below = cn_below_quorum(
            len(self.cfg.cn_hosts), removed=1, down=1
        )
        if not below:
            return []
        window = "open" if any(end is None for _, end in outage) else "bounded"
        result.steps.append(
            f"below ConfigNode quorum: {available} of {members} ConfigNode(s) available "
            f"({window} window), errors there are expected"
        )
        self.log(
            f"  below quorum: {available} of {members} ConfigNode(s) available; "
            "errors in this window are expected, not failures"
        )
        return outage

    def _exposed_dn_outage(
        self,
        target: Target,
        dn_outage: list[tuple[float, float | None]],
        result: CaseResult,
    ) -> list[tuple[float, float | None]]:
        """The down-windows of a DataNode that fault injection took down.

        Unlike the ConfigNode case there is no quorum arithmetic to do: while the
        node is stopped or restarting, every statement it was serving fails, and
        R&D's decision (2026-09-29) is to recycle the resources immediately
        instead of waiting for in-flight queries -- waiting risks the REMOVE
        being stuck behind one large or many concurrent queries.  So errors
        inside these windows are expected.  Only the window is excused, never the
        whole case, and the reading is still recorded on the result.
        """
        if not dn_outage:
            return []
        if not self.cfg.get_bool("DN_FAULT_EXPECTED_OUTAGE"):
            return []
        window = "open" if any(end is None for _, end in dn_outage) else "bounded"
        result.steps.append(
            f"DataNode {target.role} fault took {len(dn_outage)} node(s) down "
            f"({window} window); errors there are expected"
        )
        self.log(
            f"  DataNode down-window ({window}, {len(dn_outage)}): errors in it are "
            "expected, not failures"
        )
        return list(dn_outage)

    def _resolve_target(
        self,
        case: Case,
        run: BenchmarkRun,
        remover: Remover,
        result: CaseResult,
        artifacts: Path,
    ) -> Target | None:
        want = (self.cfg.get("BM_REMOVE_AFTER_SEC"))
        self.log(f"  remove target: role={case.target} selector={case.selector} (load warmup {want}s)")

        if case.target == ROLE_DN:
            if case.selector == "nonexistent":
                existing = [int(x) for x in (self.cluster.dn_id_for(h) or "0" for h in self.cfg.dn_hosts) if x.isdigit()]
                fake = (max(existing) if existing else 0) + 1000
                return Target(
                    ROLE_DN, "", str(fake), "nonexistent",
                    expect_reject=True, abnormal=list(case.abnormal),
                )
            if case.selector == "multi":
                # The ConfigNode refuses a removal that would leave fewer than
                # max(schema_rf, data_rf) DataNodes, so the requested count has
                # to fit the topology instead of being assumed.  A 5-node
                # cluster at rf=3 can only give up 2.
                count = self.cfg.get_int("MULTI_REMOVE_COUNT")
                floor = max(case.resolved_data_rf(self.cfg), case.resolved_schema_rf(self.cfg))
                available = len(self.cluster.running_dn_hosts())
                allowed = max_removable_dns(available, floor)
                if allowed < 1:
                    self.log(
                        f"  SKIP: {available} DataNode(s) with replication factor {floor} "
                        "leave nothing removable"
                    )
                    result.steps.append(
                        f"multi selector skipped: {available} DataNode(s), floor {floor}"
                    )
                    return None
                if count > allowed:
                    self.log(
                        f"  clamping multi-remove from {count} to {allowed} "
                        f"({available} DataNodes, must retain {floor})"
                    )
                    count = allowed
                picks: list[str] = []
                exclude: set[str] = set()
                for _ in range(count):
                    host = remover.pick_dn("running", exclude=exclude)
                    picks.append(host)
                    exclude.add(host)
                node_ids = [(h, self.cluster.dn_id_for(h) or "") for h in picks]
                primary_host, primary_id = node_ids[0]
                return Target(
                    ROLE_DN,
                    primary_host,
                    primary_id,
                    "multi",
                    extra=[(h, i) for h, i in node_ids[1:]],
                    extra_regions={h: self._regions_of(h, run) for h, _ in node_ids[1:]},
                    region_ids=self._regions_of(primary_host, run),
                    abnormal=list(case.abnormal),
                )
            # The `adding` target is the node that joins during this case, so the
            # generic pre-selection is both pointless and actively misleading:
            # it logged "removal target: <some other node>" while the removal
            # went to the joined node.
            host = "" if case.selector == "adding" else remover.pick_dn(case.selector)
            if case.selector == "unknown":
                remover.make_dn_unknown(host)
            elif case.selector == "readonly":
                remover.make_dn_readonly(host)
            elif case.selector == "diskfull":
                if not self.cfg.get_bool("DISK_FULL_SIMULATE"):
                    self.log("  SKIP: DISK_FULL_SIMULATE=false, refusing to touch the threshold")
                    result.steps.append("diskfull selector skipped: DISK_FULL_SIMULATE=false")
                    return None
                possible, why = remover.diskfull_can_simulate(host)
                if not possible:
                    self.log(f"  SKIP: {why}")
                    result.steps.append(f"diskfull selector skipped: {why}")
                    return None
                remover.make_dn_diskfull(host)
            elif case.selector == "adding":
                # Grow-then-shrink: join the held-back DataNode, then remove the
                # node that just joined.  There is no "Adding" node state to
                # wait on -- a joining DataNode reports Running within seconds
                # (`Adding` is a *RegionStatus*, set while a region gains a peer)
                # -- so registration is the whole observable transition, and the
                # old "wait for the spare to leave Running" gate could only ever
                # time out and then proceed with a misleading note.
                expansion = self._expansion_host(case)
                if not expansion:
                    result.steps.append("adding selector skipped: no host is available to join")
                    return None
                self.log(f"  joining DataNode {expansion} as a new cluster member")
                self.cluster.start_node(expansion, ROLE_DN)
                if not self._wait_dn_joined(
                    expansion, timeout=self.cfg.get_int("CLUSTER_START_TIMEOUT_SEC")
                ):
                    raise RemoveError(f"DataNode {expansion} never joined the cluster")
                host = expansion
                result.steps.append(
                    f"DataNode {expansion} joined; removing the just-added node (grow-then-shrink)"
                )
            node_id = self.cluster.dn_id_for(host)
            if not node_id:
                raise RemoveError(f"could not resolve DataNode id for {host}")
            if case.selector == "concurrent":
                # The second removal is issued by the `concurrent_remove`
                # abnormal operation while the first procedure is still live.
                if not [h for h in self.cluster.running_dn_hosts() if h != host]:
                    raise RemoveError("concurrent remove needs a second Running DataNode")
                if "concurrent_remove" not in case.abnormal:
                    case.abnormal.append("concurrent_remove")
            regions = self._regions_of(host, run)
            return Target(
                ROLE_DN, host, node_id, case.selector,
                region_ids=regions, abnormal=list(case.abnormal),
            )

        # ConfigNode
        if case.selector == "nonexistent":
            existing = [int(x) for x in (self.cluster.cn_id_for(h) or "0" for h in self.cfg.cn_hosts) if x.isdigit()]
            fake = (max(existing) if existing else 0) + 1000
            return Target(
                    ROLE_CN, "", str(fake), "nonexistent",
                    expect_reject=True, abnormal=list(case.abnormal),
                )
        host = remover.pick_cn(case.selector)
        if case.selector == "stopped":
            self.log(f"  stopping ConfigNode {host} before the remove")
            self.cluster.stop_node(host, ROLE_CN)
            time.sleep(3)
        node_id = self.cluster.cn_id_for(host)
        if not node_id:
            raise RemoveError(f"could not resolve ConfigNode id for {host}")
        return Target(ROLE_CN, host, node_id, case.selector, abnormal=list(case.abnormal))

    # ------------------------------------------------------------------
    def _regions_of(self, host: str, run: BenchmarkRun | None) -> list[str]:
        """Data region ids hosted by ``host`` for the benchmark databases."""
        databases: list[str] = []
        if run is not None:
            databases = [d for d in (run.tree_db, run.table_db) if d]
        try:
            rows = self.sql.show_regions(self.cfg.cli_host)
        except Exception:  # noqa: BLE001
            return []
        region_ids: list[str] = []
        for row in rows:
            if (row.get("Type") or "").strip() != "DataRegion":
                continue
            ip = (row.get("RpcAddress") or "").strip()
            db = (row.get("Database") or "").strip()
            rid = (row.get("RegionId") or "").strip()
            if ip != host or not rid:
                continue
            if databases and not any(db == d or db.startswith(d) for d in databases):
                continue
            region_ids.append(rid)
        self.log(f"  {host} hosts {len(region_ids)} benchmark DataRegion(s)")
        return region_ids

    # ------------------------------------------------------------------
    def _wait_remove_moment(self, benchmark_started: float | None) -> None:
        if benchmark_started is None:
            return
        target = benchmark_started + self.cfg.get_int("BM_REMOVE_AFTER_SEC")
        remaining = target - time.time()
        if remaining > 0:
            self.log(f"  letting the load warm up for {remaining:.0f}s")
            time.sleep(remaining)

    def _verify_removed_dn_restart(
        self,
        remover: Remover,
        host: str,
        result: CaseResult,
        *,
        refusal_is_expected: bool = False,
    ) -> list[str]:
        """Start a removed DataNode again and check what it does with its old files.

        Every DataNode removal is followed by this probe, because "the node is
        gone from the cluster" says nothing about what is still lying on its
        disk -- and a node that comes back while still holding data it no longer
        owns is the dangerous case (it can serve or resurrect stale replicas).

        Outcomes, from acceptable to not:

        * it starts and its leftovers are gone -> recorded as a step.  Either it
          cleaned them itself on boot, or it had already cleaned them before it
          stopped.
        * it refuses to start -> recorded as a step, with the counts, because the
          product documents this guard and tells the operator to delete the data
          dir by hand ("Please delete the useless 'data' dir and retry").
        * **it starts and still holds the data -> a problem.**  That is the case
          this probe exists to catch.

        Returns a list of problems; everything else is written to ``result.steps``
        so the outcome is visible in the report either way.
        """
        problems: list[str] = []
        before = remover.removed_dn_residual_counts(host)
        before_files = remover.removed_dn_residual_files(host)
        self.log(
            f"  restart probe: starting removed DataNode {host} again "
            f"(before: {before[0]} dirs / {before[1]} files / {before[2]} KB)"
        )
        # The removed node's JVM may still be shutting down: the removal marks it gone
        # as soon as its regions have migrated, while the process itself lingers for up
        # to a minute (shutdown hooks, compaction thread pools).  `start-datanode.sh`
        # refuses to launch a second node for the same IOTDB_HOME, so starting now would
        # be a silent no-op -- and the probe would then report "did not re-join the
        # cluster" for a node it never actually restarted.  That is what happened on
        # 2.0.12.1 RC4 / `dn_running_remove`: the target's log ended with its *old*
        # process's shutdown hook and contained no startup lines at all.  So wait for the
        # old PID to disappear, then require a *new* PID before judging the node.
        old_pids = self._process_pids(host, "DataNode")
        if old_pids:
            self.log(
                f"  restart probe: {host} is still shutting down "
                f"(pid {', '.join(sorted(old_pids))}); waiting for it to exit"
            )
            stop_timeout = self.cfg.get_int("CLUSTER_STOP_TIMEOUT_SEC")
            if not wait_until(
                lambda h=host: not self._process_pids(h, "DataNode"),
                timeout=stop_timeout,
                interval=5,
            ):
                self.log(
                    f"  restart probe: {host} did not exit within {stop_timeout}s; "
                    "the restart below may be a no-op"
                )
                old_pids = self._process_pids(host, "DataNode")
        started = False
        for attempt in (1, 2):
            self.cluster.start_node(host, ROLE_DN)
            started = wait_until(
                lambda h=host, old=old_pids: self._process_pids(h, "DataNode") - old,
                timeout=self.cfg.get_int("REMOVED_NODE_RESTART_PROBE_SEC"),
                interval=5,
            )
            if started:
                break
            if attempt == 1:
                # One retry: an IoTDB start can lose a race against the instance that is
                # still shutting down and exit before it binds its ports.
                time.sleep(5)
                old_pids = old_pids | self._process_pids(host, "DataNode")
        if started:
            # Give a booting node a chance to clean up before judging it: the
            # cleanup happens during startup, not instantly.
            settle = self.cfg.get_int("RESTART_CLEANUP_SETTLE_SEC")
            if settle > 0:
                self.log(f"  restart probe: {host} came up, waiting {settle}s to settle")
                time.sleep(settle)
        after = remover.removed_dn_residual_counts(host)
        if not started:
            result.steps.append(
                f"{host}: restart after removal was refused; old files are kept "
                f"({after[0]} dirs / {after[1]} files / {after[2]} KB) and the data "
                "dir needs manual deletion"
            )
            self.log(
                f"  {host} refused to start after being removed -- its data dir "
                "needs manual deletion"
            )
            # A refusal is only acceptable when the node never had a chance to
            # clean up -- i.e. the case killed it mid-removal.  Everywhere else the
            # removal ran to completion with the node alive, so its data should be
            # gone and nothing should be able to block a restart: refusing then
            # means the node can never be reused without manual intervention.
            if (not refusal_is_expected) or self.cfg.get_bool("REMOVED_NODE_RESTART_STRICT"):
                why = (
                    "although it had every chance to clean up, so it can never be "
                    "reused without deleting the data dir by hand"
                    if not refusal_is_expected
                    else "and strict mode rejects that even for a killed node"
                )
                problems.append(
                    f"removed DataNode {host} refused to start {why} "
                    f"({after[1]} files / {after[2]} KB left, unchanged from "
                    f"{before[1]} files)"
                )
            return problems
        # Only files that were already there *before* the restart and are still
        # there *after* it are leftovers: a node that boots recreates its own
        # (empty) directory structure, and counting that as stale data is how
        # this probe first produced a false positive.
        after_files = remover.removed_dn_residual_files(host)
        stale = before_files & after_files
        new_id = self.cluster.dn_id_for(host)
        if stale:
            sample = ", ".join(sorted(stale)[:3])
            extra = len(stale) - min(3, len(stale))
            if extra > 0:
                sample += f", ... (+{extra} more)"
            problems.append(
                f"removed DataNode {host} restarted and still holds {len(stale)} file(s) "
                f"it no longer owns (unchanged from before the restart): {sample}"
            )
        elif not new_id:
            problems.append(
                f"removed DataNode {host} restarted but did not re-join the cluster "
                f"(no DataNode id); it is running without being a member"
            )
        else:
            result.steps.append(
                f"{host}: restarted after removal and re-joined as DataNode {new_id} "
                f"with no leftover files ({before[1]} files before the restart, "
                f"{len(stale)} of them still present after)"
            )
            self.log(f"  {host} restarted and re-joined as DataNode {new_id}, no leftovers")
        if not new_id:
            # Nothing re-joined, so do not leave a stray process holding ports.
            self.cluster.stop_node(
                host, ROLE_DN, timeout=self.cfg.get_int("CLUSTER_STOP_TIMEOUT_SEC")
            )
        # When it *does* re-join it is a legitimate member again: leave it running,
        # because stopping it would leave the cluster listing a member that is
        # down, and the remaining gates would then trip over an "unknown" node.
        return problems

    def _abort_note(self, case: Case, scope: dict, exc: Exception) -> str:
        """Explain an abort that the case's own fault set makes unavoidable.

        With 3 ConfigNodes, "remove one + fault another" leaves one vote where two
        are needed, so no ConfigNode can answer a control-plane query at all.  The
        harness then cannot verify the procedure and aborts -- which reads like a
        database defect unless it is labelled.  On the 2.0.12.1 RC4 matrix this is
        exactly what happened to `cn_leader_remove_kill9_follower`: the abort was
        the topology's arithmetic, while the actual client errors were the expected
        "Fail to connect to any config node" of the open below-quorum window (a
        TDB-402 verdict needs `The consensus group ConfigRegion[0] doesn't exist`,
        measured as zero there).  On >=5 ConfigNodes the same case can produce a
        real verdict -- see CN_BELOW_QUORUM_EXPECTED_OUTAGE in SKILL.md.
        """
        try:
            target = scope.get("target")
            if target is None or target.role != ROLE_CN or "SQL failed" not in str(exc):
                return ""
            down = 1 if any(
                op in {"kill9_cn", "stop_cn", "restart_cn"} for op in case.abnormal
            ) else 0
            members, available, below = cn_below_quorum(
                len(self.cfg.cn_hosts), removed=1, down=down
            )
            if not below:
                return ""
            return (
                f" [the control plane was unreachable by construction: {available} of "
                f"{members} ConfigNode(s) left, so no ConfigNode could answer; re-run on a "
                f">=5-ConfigNode topology for a verdict on this case]"
            )
        except Exception:  # noqa: BLE001 - an explanation must never mask the abort
            return ""

    def _remove_and_wait(
        self,
        remover: Remover,
        target: Target,
        artifacts: Path,
        result: CaseResult,
        *,
        expect_reject: bool = False,
    ) -> list[str]:
        problems: list[str] = []
        timeout = self.cfg.get_int("REMOVE_MAX_WAIT_SEC")
        stable = self.cfg.get_int("MIGRATION_STABLE_SECONDS")
        dialects = self._migration_dialects(result)

        if not remover.wait_migrations_empty(
            timeout=timeout, stable_seconds=stable, dialects=dialects
        ):
            problems.append("SHOW MIGRATIONS did not become empty after the remove")
        if getattr(remover, "last_stall", ""):
            # The procedure is wedged, so the node will never leave the cluster.
            # Waiting for it would burn another REMOVE_MAX_WAIT_SEC; report it
            # and go straight to healing so the case ends with a real verdict.
            problems.append(f"remove procedure is wedged and will not finish: {remover.last_stall}")
            # ---- INSTRUMENTATION (test tool only; NOT product code) ----
            # Dump the failing shape BEFORE _heal_after_remove restarts anything: this is the
            # only moment when "region has no live replica" and "procedure wedged" differ.
            try:
                _h = remover.cfg.cli_host
                _ts = time.strftime("%H%M%S")
                for _nm, _stmt in (("regions", "show regions"), ("datanodes", "show datanodes"),
                                   ("confignodes", "show confignodes"), ("migrations", "show migrations")):
                    try:
                        _raw = remover.sql.sql(_h, _stmt, check=False)
                    except Exception as _exc:
                        _raw = f"ERROR: {_exc}"
                    (artifacts / f"wedge_{_nm}_{_ts}.raw").write_text(_raw, encoding="utf-8")
                    self.log(f"  [wedge forensics] {_nm} -> wedge_{_nm}_{_ts}.raw")
            except Exception as _exc:
                self.log(f"  [wedge forensics] failed: {_exc}")
            # ---- end instrumentation ----
            problems.extend(self._heal_after_remove(target))
            for problem in problems:
                self.log(f"  remove problem: {problem}")
            return problems

        if expect_reject:
            stmt = remover.remove_statement(target.role, target.node_id)
            out = remover.sql.sql(remover.cfg.cli_host, stmt, check=False)
            from .remote import looks_like_sql_error

            if not looks_like_sql_error(out):
                problems.append(f"{stmt} was accepted even though the node does not exist")
            return problems

        for host, node_id in target.extra:
            self.log(f"  follow-up remove: {target.role} {node_id} ({host})")
            try:
                remover.submit(target.role, node_id)
            except RemoveError as exc:
                problems.append(str(exc))
                continue
            if not remover.wait_migrations_empty(
                timeout=timeout, stable_seconds=stable, dialects=dialects
            ):
                problems.append(f"SHOW MIGRATIONS did not become empty after removing {host}")
                if getattr(remover, "last_stall", ""):
                    problems.append(f"remove procedure is wedged: {remover.last_stall}")
                    # ---- INSTRUMENTATION (test tool only; NOT product code) ----
                    # Dump the failing shape BEFORE _heal_after_remove restarts anything: this is the
                    # only moment when "region has no live replica" and "procedure wedged" differ.
                    try:
                        _h = remover.cfg.cli_host
                        _ts = time.strftime("%H%M%S")
                        for _nm, _stmt in (("regions", "show regions"), ("datanodes", "show datanodes"),
                                           ("confignodes", "show confignodes"), ("migrations", "show migrations")):
                            try:
                                _raw = remover.sql.sql(_h, _stmt, check=False)
                            except Exception as _exc:
                                _raw = f"ERROR: {_exc}"
                            (artifacts / f"wedge_{_nm}_{_ts}.raw").write_text(_raw, encoding="utf-8")
                            self.log(f"  [wedge forensics] {_nm} -> wedge_{_nm}_{_ts}.raw")
                    except Exception as _exc:
                        self.log(f"  [wedge forensics] failed: {_exc}")
                    # ---- end instrumentation ----
                    problems.extend(self._heal_after_remove(target))
                    for problem in problems:
                        self.log(f"  remove problem: {problem}")
                    return problems

        if target.role == ROLE_DN and target.host:
            removed = [(target.host, target.region_ids)]
            removed += [(h, target.extra_regions.get(h, [])) for h, _ in target.extra]
            self._by_design_gone = {h for h, _ in removed}
            for host, region_ids in removed:
                if not remover.wait_dn_absent(host, timeout=timeout):
                    if getattr(remover, "last_stall", ""):
                        problems.append(
                            f"remove procedure is wedged and will not finish: {remover.last_stall}"
                        )
                        problems.extend(self._heal_after_remove(target))
                        for problem in problems:
                            self.log(f"  remove problem: {problem}")
                        return problems
                    problems.append(f"DataNode {host} is still listed after the remove")
                    continue
                # Take the intent from the *case*, not from the process table.
                # A removed DataNode stops its own process either way, so the
                # process state cannot distinguish the two paths -- and it is not
                # a fault signal.  What differs is whether the node was *running*
                # when the removal reached it:
                #   selector=unknown -> removed while stopped, so it never ran the
                #     cleanup, keeps its files, and cannot be restarted (below).
                #   anything else    -> removed while Running: it cleans up and
                #     shuts itself down, and because the data is gone it can even
                #     start again later as a fresh node.
                if target.selector != "unknown":
                    if not self._process_running(host, "DataNode"):
                        self.log(
                            f"  {host} stopped its own process after the removal "
                            "(expected for a node removed while Running)"
                        )
                    # Deleting a removed DataNode's files is that DataNode's *own*
                    # action: migrations finish, it drops each local replica, then
                    # it stops.  No outside process can delete files on a dead
                    # node's disk, and a removed node is refused on restart, so
                    # once the node is gone nothing can ever finish the job.
                    #
                    # `kill9_target` SIGKILLs the very node being removed.  That
                    # removes the only actor that could clean up, which makes the
                    # outcome the same class as removing a node that was already
                    # Unknown -- where leftover files are the documented, expected
                    # behaviour ("Please delete the useless 'data' dir and retry").
                    # So do not assert cleanup here; measure the residue instead,
                    # and keep it visible in the report so a real change in
                    # behaviour or volume is still noticeable.
                    #
                    # `kill9_other_dn` is a different matter: the removed node is
                    # still alive and must clean up, so it keeps the strict check.
                    target_killed = "kill9_target" in target.abnormal
                    cleaned = remover.check_removed_dn_data_cleaned(host, region_ids)
                    # The tracked-region check only looks at the regions this case
                    # chose to follow, so it can miss real leftovers entirely; also
                    # sweep whatever is actually on disk.
                    residual = remover.check_removed_dn_residual(host)
                    if target_killed:
                        detail = "; ".join(cleaned + residual)
                        if detail:
                            result.steps.append(
                                f"{host}: data left behind after kill9_target "
                                f"(expected -- the node died before it could clean up, "
                                f"so its data dir needs manual deletion): {detail}"
                            )
                            self.log(
                                f"  {host} kept data because it was killed mid-removal "
                                "(expected: cleanup is the removed node's own action; "
                                "data dir requires manual deletion)"
                            )
                        else:
                            self.log(
                                f"  {host} had already finished cleaning up before the kill"
                            )
                    else:
                        problems.extend(cleaned)
                        problems.extend(residual)
                        if region_ids and not cleaned:
                            self.log(
                                f"  removed DataNode {host} dropped all {len(region_ids)} "
                                "tracked region file sets"
                            )
                    # Regression guard for every DataNode removal: start the node
                    # again and check that it is reusable.  A killed node could not
                    # clean up, so a refusal is expected there; anywhere else the
                    # removal finished with the node alive, so a refusal is a defect.
                    problems.extend(
                        self._verify_removed_dn_restart(
                            remover, host, result, refusal_is_expected=target_killed
                        )
                    )
                    continue
                # IoTDB refuses to ever start a removed DataNode and tells the
                # operator to delete the data directory by hand:
                #   "Reject DataNode restart. Because there are no
                #    corresponding DataNode(whose nodeId=N) in the cluster
                #    ... Please delete the useless 'data' dir and retry"
                # so its files are *expected* to stay.  Assert that
                # documented guard rather than auto-cleanup the product
                # never promises -- and do not wait out a start that is
                # designed to fail.
                self.log(
                    f"  {host} was removed while stopped; IoTDB refuses to restart a "
                    "removed DataNode, so its data dir needs manual deletion"
                )
                self.cluster.start_node(host, ROLE_DN)
                if wait_until(
                    lambda h=host: self._process_running(h, "DataNode"),
                    timeout=self.cfg.get_int("REMOVED_NODE_RESTART_PROBE_SEC"),
                    interval=5,
                ):
                    problems.append(
                        f"removed DataNode {host} started again although it is no longer "
                        "a cluster member; it may rejoin and serve stale data"
                    )
                else:
                    result.steps.append(
                        f"{host} removed while stopped: restart correctly rejected, "
                        "data dir requires manual deletion"
                    )
                continue
        if target.role == ROLE_CN and target.host:
            self._by_design_gone = {target.host} | {h for h, _ in target.extra}
            if not remover.wait_cn_absent(target.host, timeout=timeout):
                problems.append(f"ConfigNode {target.host} is still listed after the remove")

        # Abnormal operations may have left a *second* node down or its disk
        # full.  Heal those before the sync-lag and consistency gates, which
        # are only meaningful on an otherwise healthy cluster.
        problems.extend(self._heal_after_remove(target))

        for problem in problems:
            self.log(f"  remove problem: {problem}")
        return problems

    def _remove_until_rf_limit(
        self,
        case: Case,
        run: BenchmarkRun | None,
        remover: Remover,
        artifacts: Path,
        result: CaseResult,
    ) -> list[str]:
        """Remove DataNodes until only data_replication_factor are left.

        One further removal must then be rejected with the
        "limit of replication factor" guard (source case tc117).
        """
        from .remote import looks_like_sql_error

        problems: list[str] = []
        rf = (
            self.cfg.get_int("DATA_REPLICATION_FACTOR")
            if case.data_rf == "default"
            else int(case.data_rf)
        )
        timeout = self.cfg.get_int("REMOVE_MAX_WAIT_SEC")
        stable = self.cfg.get_int("MIGRATION_STABLE_SECONDS")
        dialects = self._migration_dialects(result)

        running = remover.cluster.running_dn_hosts()
        budget = len(running) - rf
        self.log(
            f"  rf_limit: {len(running)} DataNode(s) Running, rf={rf} -> removing {max(budget, 0)}"
        )
        if budget <= 0:
            result.steps.append(
                f"rf_limit: only {len(running)} DataNode(s) for rf={rf}, nothing to remove"
            )
            return problems

        removed: list[str] = []
        for index in range(budget):
            host = remover.pick_dn("running", exclude=set(removed))
            if not host:
                problems.append(f"rf_limit: ran out of Running DataNodes after {index} removal(s)")
                return problems
            node_id = remover.cluster.dn_id_for(host)
            if not node_id:
                problems.append(f"rf_limit: no DataNode id found for {host}")
                return problems
            regions = self._regions_of(host, run)
            self.log(f"  rf_limit: removing {index + 1}/{budget} -> {host} (id {node_id})")
            try:
                remover.submit(ROLE_DN, node_id)
            except RemoveError as exc:
                problems.append(str(exc))
                return problems
            if not remover.wait_migrations_empty(
                timeout=timeout, stable_seconds=stable, dialects=dialects
            ):
                problems.append(f"SHOW MIGRATIONS did not drain after removing {host}")
                if getattr(remover, "last_stall", ""):
                    problems.append(f"remove procedure is wedged: {remover.last_stall}")
                    # ---- INSTRUMENTATION (test tool only; NOT product code) ----
                    # Dump the failing shape BEFORE _heal_after_remove restarts anything: this is the
                    # only moment when "region has no live replica" and "procedure wedged" differ.
                    try:
                        _h = remover.cfg.cli_host
                        _ts = time.strftime("%H%M%S")
                        for _nm, _stmt in (("regions", "show regions"), ("datanodes", "show datanodes"),
                                           ("confignodes", "show confignodes"), ("migrations", "show migrations")):
                            try:
                                _raw = remover.sql.sql(_h, _stmt, check=False)
                            except Exception as _exc:
                                _raw = f"ERROR: {_exc}"
                            (artifacts / f"wedge_{_nm}_{_ts}.raw").write_text(_raw, encoding="utf-8")
                            self.log(f"  [wedge forensics] {_nm} -> wedge_{_nm}_{_ts}.raw")
                    except Exception as _exc:
                        self.log(f"  [wedge forensics] failed: {_exc}")
                    # ---- end instrumentation ----
                    return problems
            if not remover.wait_dn_absent(host, timeout=timeout):
                problems.append(f"DataNode {host} is still listed after the remove")
                return problems
            problems.extend(remover.check_removed_dn_data_cleaned(host, regions))
            removed.append(host)

        left = [h for h in remover.cluster.running_dn_hosts() if h not in removed]
        if not left:
            problems.append("rf_limit: no DataNode left to probe the replication-factor guard")
            return problems
        host = left[0]
        node_id = remover.cluster.dn_id_for(host)
        stmt = remover.remove_statement(ROLE_DN, node_id or "")
        out = remover.sql.sql(remover.cfg.cli_host, stmt, check=False)
        lower = out.lower()
        if not looks_like_sql_error(out):
            problems.append(
                f"{stmt} was accepted although only {rf} DataNode(s) would remain "
                f"(replication-factor guard missing): {out.strip()[:200]}"
            )
        elif not is_replication_factor_guard(out):
            problems.append(
                f"{stmt} was rejected, but not by the replication-factor guard: {out.strip()[:200]}"
            )
        else:
            self.log("  replication-factor guard rejected the extra removal as expected")
        return problems

    def _remove_below_cn_quorum(
        self,
        case: Case,
        remover: Remover,
        result: CaseResult,
        *,
        leader_first: bool = False,
    ) -> list[str]:
        """Shrink the ConfigNodes down to one and prove the cluster keeps serving.

        A single ConfigNode is a **valid** ConfigRegion -- a one-member group
        still holds a majority -- so removing two of three ConfigNodes is
        supposed to succeed and the cluster is supposed to keep answering
        queries.  What this case establishes is therefore *not* "is there a
        guard": it is "does the ConfigRegion survive being shrunk".

        On rc2 build `0b4dc9a` it does not.  After two of three ConfigNodes are
        gone, clients get::

            301: The consensus group ConfigRegion[0] doesn't exist

        The probe runs after **every** removal, so the report names the exact
        step that broke rather than only recording that something did.
        """
        problems: list[str] = []
        timeout = self.cfg.get_int("REMOVE_MAX_WAIT_SEC")

        start = len(remover.cluster.running_cn_hosts())
        self.log(f"  cn_quorum: {start} ConfigNode(s) Running; shrinking to one")
        if start < 2:
            result.steps.append(f"cn_quorum: only {start} ConfigNode(s), nothing to shrink")
            return problems

        removed: list[str] = []
        while True:
            left = [h for h in remover.cluster.running_cn_hosts() if h not in removed]
            if len(left) <= 1:
                break
            # Order matters, and it is the whole point of the case.
            #
            # `pick_cn` prefers Followers, so taking `followers[0]` every time
            # leaves the original Leader as the survivor -- and that case was
            # measured to work.  The demanding order is the other one: with two
            # ConfigNodes left, remove the **Leader**, so the sole survivor is a
            # former Follower that has to take over by itself.  That is the
            # order in which the cluster was observed to stop serving, so it is
            # the order this case must exercise.
            leader = self._cn_leader(remover)
            if leader is None:
                # Refuse to guess.  The removal ORDER is the whole variable these
                # cases exist to isolate, so quietly picking an arbitrary node
                # would run a different scenario than the case claims -- which is
                # exactly what happened once: a run labelled `leader_first`
                # actually removed a Follower, and its result was read as if the
                # Leader had gone first.
                problems.append(
                    "cn_quorum: no ConfigNode reports itself Leader, so the removal "
                    "order cannot be controlled; refusing to remove a node"
                )
                return problems
            followers = [h for h in left if h != leader]
            host = cn_removal_target(
                left, removed, leader, leader_first=leader_first
            )
            if not host:
                problems.append("cn_quorum: no ConfigNode left to remove")
                return problems
            node_id = remover.cluster.cn_id_for(host)
            if not node_id:
                problems.append(f"cn_quorum: no ConfigNode id found for {host}")
                return problems
            # State the premise in the case's own output.  Without this, a run
            # cannot be interpreted afterwards: the leader oracle and the raft
            # logs disagreed at least once, and a result was nearly read as being
            # about Leader removal when the node taken was a Follower.
            role = "Leader" if host == leader else "Follower"
            self.log(
                f"  cn_quorum: oracle reports Leader={leader}; removing {host} "
                f"as {role}, {len(left)} -> {len(left) - 1}"
            )
            result.steps.append(
                f"cn_quorum: oracle Leader={leader}; removed {host} (a {role}) "
                f"leaving {len(left) - 1}"
            )
            try:
                remover.submit(ROLE_CN, node_id)
            except RemoveError as exc:
                problems.append(
                    f"cn_quorum: removing {host} was rejected while {len(left)} ConfigNode(s) "
                    f"were still up: {exc}"
                )
                return problems
            if not remover.wait_cn_absent(host, timeout=timeout):
                problems.append(f"ConfigNode {host} is still listed after the remove")
                return problems
            removed.append(host)

            remaining = len(left) - 1
            probes = self._cn_probe_matrix(remover)
            broken = [f"{label} ({detail})" for label, ok, detail in probes if not ok]
            result.steps.append(
                f"cn_quorum: probe table with {remaining} ConfigNode(s) left after removing "
                f"{host}: "
                + "; ".join(f"{label}={'ok' if ok else 'FAILED'}" for label, ok, _ in probes)
            )
            ok = not broken
            detail = broken[0] if broken else ""
            if ok:
                result.steps.append(
                    f"cn_quorum: {remaining} ConfigNode(s) left after removing {host}; "
                    "every probed operation still works"
                )
            else:
                problems.append(
                    f"cn_quorum: after removing {host} ({remaining} ConfigNode(s) left) the "
                    f"cluster can no longer serve all operations: {len(broken)} of {len(probes)} "
                    f"probes failed, first: {detail} -- a one-member ConfigRegion is a "
                    "valid group, so shrinking to it must keep the cluster usable"
                )
                # Two very different faults produce this same client-side error,
                # and only the node's own view of the group tells them apart, so
                # capture it while the cluster is still in this state.
                result.steps.extend(self._cn_region_evidence(remover, remaining))
                return problems

        result.steps.append(
            f"cn_quorum: shrank {start} -> 1 ConfigNode(s) and the cluster served after every step"
        )
        return problems

    def _cn_leader(self, remover: Remover, *, tries: int = 15) -> str | None:
        """The current ConfigNode Leader, waiting out a fresh election.

        `leader_cn_host()` reads the Role column of `SHOW CONFIGNODES`, which is
        empty while the ConfigRegion is still electing -- typically right after
        the cluster is reset.  Both shrink cases depend on knowing who the Leader
        is, so this retries instead of returning None immediately.
        """
        for _ in range(tries):
            leader = remover.cluster.leader_cn_host()
            if leader:
                return leader
            time.sleep(2)
        return None

    # One statement per layer the ConfigNode sits in front of, so a failure
    # report says *which* operations died instead of just "queries failed".
    CN_PROBES: tuple[tuple[str, str], ...] = (
        ("show cluster", "cluster metadata read"),
        ("show confignodes", "ConfigNode list read"),
        ("show databases", "schema read (may be served from cache)"),
        ("create database root.rcdn_probe", "schema mutation (create database)"),
        # The tree dialect needs the datatype, and `insert` below succeeds
        # even before this, so the statement has to be valid or the probe
        # reports a syntax error as a cluster failure.
        ("create timeseries root.rcdn_probe.d1.s1 with datatype=int32, encoding=rle",
         "schema mutation (create timeseries)"),
        ("insert into root.rcdn_probe.d1(timestamp, s1) values(1, 1)", "write"),
        ("select s1 from root.rcdn_probe.d1", "read"),
    )

    def _cn_probe_matrix(self, remover: Remover) -> list[tuple[str, bool, str]]:
        """Run one statement per layer; return (label, ok, error) for each.

        A single `show databases` is not a health check -- it has been observed
        to succeed from a ConfigNode's cached state while every real query
        failed.  Running the whole ladder and reporting it per row is what turns
        "the cluster stopped working" into a precise list of what still works.
        """
        from .remote import looks_like_sql_error

        remover.sql.sql(remover.cfg.cli_host, "drop database root.rcdn_probe", check=False)
        rows: list[tuple[str, bool, str]] = []
        for stmt, label in self.CN_PROBES:
            res = remover.sql.sql(remover.cfg.cli_host, stmt, check=False)
            bad = (not res.strip()) or looks_like_sql_error(res)
            detail = ""
            if bad:
                detail = res.strip().splitlines()[-1][:200] if res.strip() else "no output"
            rows.append((label, not bad, detail))
            self.log(f"    probe [{label}] -> {'ok' if not bad else 'FAILED: ' + detail}")
        remover.sql.sql(remover.cfg.cli_host, "drop database root.rcdn_probe", check=False)
        return rows

    def _cn_region_evidence(self, remover: Remover, remaining: int) -> list[str]:
        """Record what the surviving ConfigNode(s) think the ConfigRegion is.

        The client only ever sees ``The consensus group ConfigRegion[0] doesn't
        exist``, which is consistent with two opposite faults:

        * the group was **never shrunk** -- the survivor is still one of three
          members, so it can never reach a majority and spends its time reaching
          for peers that are gone;
        * the group was **destroyed** -- membership is gone entirely.

        Reporting which one it is turns "the cluster stopped answering" into an
        actionable cause, so this greps the survivors' own logs and pairs it with
        the cluster's own node listing.
        """
        import shlex

        notes: list[str] = []
        listing = remover.sql.sql(remover.cfg.cli_host, "show confignodes", check=False)
        notes.append(
            "cn_quorum evidence -- cluster still lists: "
            + " ".join(listing.split())[:400]
        )

        survivors = remover.cluster.running_cn_hosts()
        notes.append(f"cn_quorum evidence -- {remaining} ConfigNode(s) actually Running: {survivors}")

        # High signal only: group membership, quorum complaints, election churn.
        pattern = (
            r"ConfigRegion|Not enough|quorum|majority|[Cc]annot elect|no leader|"
            r"[Ll]eader.*(lost|timeout)|removed peer"
        )
        script = f"""
d={shlex.quote(remover.cfg.get('DB_DIR'))}
cd "$d/logs" 2>/dev/null || exit 0
for f in $(ls *confignode*all*.log* 2>/dev/null || true); do
  [ -f "$f" ] || continue
  case "$f" in *.gz) rd=zcat ;; *) rd=cat ;; esac
  $rd "$f" | grep -E {shlex.quote(pattern)} | tail -n 6
done
"""
        for host in survivors:
            res = remover.ssh.run_script(host, script, check=False, timeout=180)
            for line in res.out.splitlines():
                if line.strip():
                    notes.append(f"cn_quorum evidence -- {host}: {line.strip()[:280]}")
        return notes

    def _migration_dialects(self, result: CaseResult) -> list[str | None]:
        """Poll SHOW MIGRATIONS in every dialect a workload uses."""
        workloads = result.workloads or self.cfg.workload_set()
        dialects: list[str | None] = ["tree"] if "tree" in workloads else []
        if "table" in workloads or "table_view" in workloads:
            dialects.append("table")
        return dialects or [None]

    def _process_running(self, host: str, needle: str) -> bool:
        """True when a java process whose command line contains `needle` is up."""
        return bool(self._process_pids(host, needle))

    def _process_pids(self, host: str, needle: str) -> set[str]:
        """PIDs of the java processes on `host` whose command line contains `needle`.

        The restart probe needs the *identity* of the process, not just "something is
        running": a removed DataNode's JVM can still be shutting down when the probe
        runs, and `sbin/start-datanode.sh` runs `check_running_process` and refuses to
        launch a second node for the same IOTDB_HOME, so the probe must wait for the old
        PID to disappear and then require a *new* one (see `_restart_removed_dn`).
        """
        res = self.ssh.run(
            host,
            f"sudo -n jps -l 2>/dev/null | grep -F {shlex.quote(needle)} || true",
            check=False,
            timeout=60,
        )
        pids: set[str] = set()
        for line in res.out.splitlines():
            parts = line.strip().split()
            if parts and parts[0].isdigit():
                pids.add(parts[0])
        return pids

    def _unsyncable_nodes(self) -> list[str]:
        """DataNodes that will never reach syncLag 0 in their current state.

        Called by the sync-lag gate so a node left ReadOnly by an abnormal
        operation fails the gate in seconds instead of after
        SYNC_MAX_WAIT_SEC.  Removed nodes are absent from the cluster, so they
        are not reported; anything still listed but not Running is.
        """
        bad: list[str] = []
        for host in self.cfg.dn_hosts:
            if host in self._by_design_gone:
                # Down because this case removed it -- that is the scenario, not a sync
                # failure.  Skipping it lets the gate (and the consistency sweep behind
                # it) actually run instead of bailing out.
                continue
            status = (self.cluster.dn_status_for(host) or "").lower()
            if status in {"", "running"}:
                continue
            bad.append(f"{host} is {status}")
        return bad

    def _heal_after_remove(self, target: Target) -> list[str]:
        """Start DataNodes that abnormal operations stopped and free filled disks."""
        problems: list[str] = []
        # Every host this case deliberately removed must stay down: restarting
        # one would silently rejoin it to the cluster and invalidate the case.
        gone = {target.host or ""} | {h for h, _ in target.extra}
        wanted = [h for h in self.cfg.dn_hosts if h not in gone]
        for host in wanted:
            status = self.cluster.dn_status_for(host) or ""
            if status_is(status, "running"):
                continue
            if status_is(status, "readonly"):
                # A node can be ReadOnly for two reasons and they need different
                # treatment:
                #   * `set system to readonly on local` -- a persisted *state*, so
                #     it needs the explicit `set system to running` below;
                #   * a raised `disk_space_warning_threshold` -- the ReadOnly is
                #     only a *consequence*, and clearing the status alone is
                #     useless: it is re-derived on the next write attempt.
                # Measured 2026-09-19: healing logged success, and the node was
                # still `ReadOnly(DiskFull)` 113 s later, which then failed the
                # sync-lag gate -- the case demanded syncLag drain while a node it
                # had deliberately made disk-full was still disk-full.
                # So undo the threshold FIRST, then clear the status.  Layer and
                # order both matter: the running node hot-loaded the raised value,
                # so this must go through SQL (`restore_disk_threshold`); the file
                # is tidied afterwards so the documented "an uncommented
                # `disk_space_warning_threshold` line means a leak" check stays
                # meaningful.
                remover = getattr(self, "_remover", None)
                if remover is not None:
                    previous = remover.take_pending_disk_threshold(host)
                    if previous is not None:
                        self.log(
                            f"  healing: {host} was disk-full; restoring "
                            f"disk_space_warning_threshold={previous:g} before clearing ReadOnly"
                        )
                        remover.restore_disk_threshold(host, previous)
                        self.cluster.clear_raised_disk_thresholds([host])
                # `set system to readonly on local` is a *persisted* state, so a
                # restart does not clear it: the node comes back ReadOnly and the
                # wait below would burn the whole CLUSTER_START_TIMEOUT_SEC and
                # then report a heal failure the heal itself caused.  NodeStatus
                # is {Unknown, Running, ReadOnly, Removing, DiskFull} and the SQL
                # keyword is case-insensitive, so `running` is the counterpart.
                self.log(f"  healing: {host} is readonly, setting it back to running")
                self.sql.sql(host, "set system to running on local;", check=False)
                if not wait_until(
                    lambda h=host: status_is(self.cluster.dn_status_for(h), "running"),
                    timeout=300,  # same allowance make_dn_readonly gives the way in
                    interval=3,
                ):
                    problems.append(f"DataNode {host} stayed ReadOnly after the case")
                continue
            self.log(f"  healing: {host} is {status or 'not listed'}, restarting it")
            self.cluster.start_node(host, ROLE_DN)
            if not wait_until(
                lambda h=host: status_is(self.cluster.dn_status_for(h), "running"),
                timeout=self.cfg.get_int("CLUSTER_START_TIMEOUT_SEC"),
                interval=5,
            ):
                problems.append(f"DataNode {host} did not come back to Running after the case")
        # `kill9_cn` / `stop_cn` can leave a ConfigNode dead, and this step used
        # to only ever look at DataNodes.  A missing CN degrades the sync and
        # consistency gates that run after it, so bring those back too.
        gone_cn = {target.host or ""} if target.role == ROLE_CN else set()
        for host in [h for h in self.cfg.cn_hosts if h not in gone_cn]:
            status = (self.cluster.cn_status_for(host) or "").lower()
            if status == "running":
                continue
            self.log(f"  healing: ConfigNode {host} is {status or 'not listed'}, restarting it")
            self.cluster.start_node(host, ROLE_CN)
            if not wait_until(
                lambda h=host: status_is(self.cluster.cn_status_for(h), "running"),
                timeout=self.cfg.get_int("CLUSTER_START_TIMEOUT_SEC"),
                interval=5,
            ):
                problems.append(f"ConfigNode {host} did not come back to Running after the case")
        for host in self.cfg.all_hosts:
            self.ssh.run(host, f"rm -f {self.cfg.get('DB_DIR')}/rcdn_fill_disk.tmp", check=False)
        return problems
