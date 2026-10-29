"""Offline end-to-end smoke test.

Runs the *entire* case pipeline — cluster preparation, benchmark generation,
remove, abnormal operations, procedure wait, sync-lag gate, consistency sweep,
log scan, reporting — against a stubbed cluster.  Nothing is started, stopped,
wiped or queried: every method that would touch a real node is replaced before
the runner is constructed.

Use it after editing `conf/cluster.conf`, `cases/remove_cases.tsv` or the code,
to prove the plumbing works before pointing the real thing at a cluster::

    scripts/rcdn.sh --conf conf/cluster.conf smoketest
"""

from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

from .cases import CaseRunner, load_cases
from .config import Config, ConfigError, SKILL_ROOT, load_config
from .remote import Result, SshRunner, SqlClient, parse_table, wait_until

# Statements whose rejection the runner has to notice.  Everything else is
# answered with an empty result set.
_REJECT_MARKERS = ("remove datanode 999", "remove confignode 999", "remove datanode 999999")


class _Stubs:
    """Context manager that replaces every cluster-touching method with a stub."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        # The restart probe sleeps out a real settle window so a booting node has
        # time to clean up.  Under stubs there is nothing to wait for and every
        # case would pay the full delay, so collapse it to zero here.
        self.cfg.values["RESTART_CLEANUP_SETTLE_SEC"] = "0"
        self.saved: list[tuple[object, str, object]] = []

    def _patch(self, owner: object, name: str, value: object) -> None:
        self.saved.append((owner, name, getattr(owner, name)))
        setattr(owner, name, value)

    def __enter__(self) -> "_Stubs":
        from . import benchmark as BM
        from . import cluster as CL
        from . import remove as RM
        from . import verify as V

        # Derive the fake inventory from the loaded config, not a hard-coded
        # list: the runner cross-checks hosts against `cfg.dn_hosts` (that is how
        # the `adding` case decides which node to hold back), so a stub that
        # invented its own addresses would just wait forever on a host that
        # never appears in `SHOW DATANODES`.
        dn_hosts = list(self.cfg.dn_hosts)
        cn_hosts = list(self.cfg.cn_hosts)
        dn_ids = {host: str(i + 1) for i, host in enumerate(dn_hosts)}
        cn_ids = {host: str(i) for i, host in enumerate(cn_hosts)}
        # A fake "joining" DataNode so the `adding` selector exercises its path.
        # It reports `Running`: a joined DataNode has no `Adding` node status
        # (`Adding` belongs to RegionStatus), it is Running within seconds.
        spares = self.cfg.get_list("SPARE_DN_HOSTS")
        adding = [
            {"NodeID": str(len(dn_ids) + i + 1), "Status": "Running", "RpcAddress": ip}
            for i, ip in enumerate(spares)
        ]

        # ---- transport -------------------------------------------------
        def fake_run(self, host, cmd, check=True, timeout=None, stdin=None):
            return Result(0, "", "", host, cmd)

        def fake_script(self, host, script, timeout=None, check=True):
            return Result(0, "", "", host, "<script>")

        # ---- SQL -------------------------------------------------------
        def fake_sql(self, host, statement, dialect=None, timeout=None, check=True):
            low = statement.lower()
            if any(marker in low.replace(";", "") for marker in _REJECT_MARKERS):
                return (
                    "Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 305: "
                    "The DataNode(s) to be removed [999999] are not in the cluster"
                )
            if "show databases" in low:
                if dialect == "table":
                    return "\n".join(
                        [
                            "+---------+",
                            "| Database|",
                            "+---------+",
                            "|  usr_sod|",
                            "+---------+",
                        ]
                    )
                return "\n".join(
                    ["+----------------+", "|        Database|", "+----------------+",
                     "|root.test.g_0   |", "+----------------+"]
                )
            return "Empty set."

        def fake_migrations(self, host=None, dialect=None):
            return [], True

        # ---- cluster lifecycle ----------------------------------------
        self._patch(CL.Cluster, "discover_ports", lambda self: None)
        self._patch(CL.Cluster, "stop_all", lambda self, clean=False: None)
        self._patch(CL.Cluster, "wipe", lambda self: None)
        self._patch(CL.Cluster, "configure", lambda self, **kw: None)
        self._patch(CL.Cluster, "start_all", lambda self, timeout=None, exclude_dn=None: True)
        self._patch(CL.Cluster, "start_node", lambda self, h, r: None)
        self._patch(CL.Cluster, "stop_node", lambda self, h, r, timeout=None: True)
        self._patch(CL.Cluster, "kill_node", lambda self, h, r: True)
        self._patch(CL.Cluster, "ensure_license", lambda self, h: None)
        self._patch(CL.Cluster, "running_dn_hosts", lambda self, host=None: list(dn_hosts))
        self._patch(CL.Cluster, "running_cn_hosts", lambda self, host=None: list(cn_hosts))
        self._patch(CL.Cluster, "dn_id_for", lambda self, ip, host=None: dn_ids.get(ip))
        self._patch(CL.Cluster, "cn_id_for", lambda self, ip, host=None: cn_ids.get(ip))
        self._patch(CL.Cluster, "dn_status_for", lambda self, ip, host=None: "Running")
        self._patch(CL.Cluster, "cn_status_for", lambda self, ip, host=None: "Running")
        self._patch(CL.Cluster, "leader_cn_host", lambda self, host=None: cn_hosts[0])
        self._patch(CL.Cluster, "status", lambda self: CL.ClusterStatus(rows=[]))
        self._patch(
            CL.ClusterStatus,
            "summary",
            lambda self: "3 ConfigNode + 5 DataNode Running (stub)",
        )
        self._patch(
            CL.Cluster,
            "datanodes",
            lambda self, host=None: [
                {"NodeID": dn_ids[ip], "Status": "Running", "RpcAddress": ip} for ip in dn_hosts
            ]
            + [dict(row) for row in adding],
        )
        self._patch(
            CL.Cluster,
            "confignodes",
            lambda self, host=None: [
                {
                    "NodeID": cn_ids[ip],
                    "Status": "Running",
                    "InternalAddress": ip,
                    "Role": "Leader" if ip == cn_hosts[0] else "Follower",
                }
                for ip in cn_hosts
            ],
        )

        # ---- benchmark -------------------------------------------------
        self._patch(BM.BenchmarkDriver, "create_users", lambda self: None)
        self._patch(BM.BenchmarkDriver, "start", lambda self, run: None)
        self._patch(BM.BenchmarkDriver, "stop", lambda self, run: None)
        self._patch(BM.BenchmarkDriver, "wait_finish", lambda self, run, mx, outage=None: [])
        self._patch(BM.BenchmarkDriver, "logs_have_errors", lambda self, run, outage=None: {})

        def fake_prepare(self, names):
            work = self.run_root / "benchmark"
            run = BM.BenchmarkRun(work_root=work)
            for name in names:
                directory = work / name
                directory.mkdir(parents=True, exist_ok=True)
                run.workloads[name] = BM.Workload(
                    name=name,
                    dialect=BM.WORKLOAD_DIALECT[name],
                    db_name="stub",
                    directory=directory,
                    config=directory / "config.properties",
                    log=directory / "benchmark.out",
                    pid_file=directory / "pid",
                )
            return run

        def fake_ready(self, run, timeout=900):
            run.tree_db = "root.test.g_0"
            run.table_db = "usr_sod"
            run.base_table = "tab_0"
            run.view_table = "wv_0"

        def fake_columns(self, run):
            run.columns = [f"s_{i}" for i in range(11)]
            run.object_columns = ["s_11"]

        self._patch(BM.BenchmarkDriver, "prepare", fake_prepare)
        self._patch(BM.BenchmarkDriver, "wait_objects_ready", fake_ready)
        self._patch(BM.BenchmarkDriver, "resolve_columns", fake_columns)

        # ---- remove ----------------------------------------------------
        self._patch(RM.Remover, "make_dn_unknown", lambda self, h: None)
        self._patch(RM.Remover, "make_dn_readonly", lambda self, h: None)
        self._patch(RM.Remover, "make_dn_diskfull", lambda self, h, timeout=420: 0.05)
        self._patch(RM.Remover, "restore_disk_threshold", lambda self, h, t: None)
        self._patch(RM.Remover, "restore_pending_disk_state", lambda self: None)
        # These reach for the cluster, so they must be stubbed too or the
        # offline smoketest would sit in a real ssh connection.
        self._patch(
            RM.Remover,
            "diskfull_can_simulate",
            lambda self, h: (False, "stub: disk full cannot be simulated"),
        )
        self._patch(CaseRunner, "_process_running", lambda self, h, needle: True)
        self._patch(RM.Remover, "submit", lambda self, r, i, exec_host=None: "stub")
        self._patch(RM.Remover, "submit_tolerant", lambda self, r, i, w: True)
        self._patch(RM.Remover, "submit_invalid_statements", lambda self: [])
        self._patch(
            RM.Remover,
            "wait_migrations_empty",
            lambda self, timeout, stable_seconds, dialects=None: True,
        )
        self._patch(RM.Remover, "wait_dn_absent", lambda self, h, timeout: True)
        self._patch(RM.Remover, "wait_cn_absent", lambda self, h, timeout: True)
        self._patch(RM.Remover, "check_removed_dn_data_cleaned", lambda self, h, ids: [])
        self._patch(RM.Remover, "check_removed_dn_residual", lambda self, h: [])
        self._patch(RM.Remover, "removed_dn_residual_counts", lambda self, h: (0, 0, 0))
        self._patch(RM.Remover, "removed_dn_residual_files", lambda self, h: set())

        # ---- verification ----------------------------------------------
        self._patch(V.SyncLagWaiter, "available", lambda self: False)
        self._patch(
            V.Verifier,
            "consistency_check",
            lambda self, run, sync_waiter=None, data_rf=0: [],
        )
        self._patch(V.Verifier, "check_logs", lambda self, since_epoch=None: [])
        self._patch(V.Verifier, "backup_logs", lambda self, tag, dest: str(dest))

        # ---- transport last, so nothing above can slip past -------------
        self._patch(SshRunner, "run", fake_run)
        self._patch(SshRunner, "run_script", fake_script)
        self._patch(SshRunner, "ping", lambda self, host: True)
        self._patch(SshRunner, "stream_tar", lambda self, host, glob, dest: dest)
        self._patch(SqlClient, "sql", fake_sql)
        self._patch(SqlClient, "show_migrations", fake_migrations)
        self._patch(SqlClient, "check_available", lambda self: "stub")
        return self

    def __exit__(self, *exc) -> None:
        for owner, name, value in reversed(self.saved):
            setattr(owner, name, value)


def run(conf: str | None = None, cases_file: str | None = None, work_root: Path | None = None) -> list[str]:
    """Run every case with a stubbed cluster.  Returns the ids that aborted."""
    path = Path(conf) if conf else SKILL_ROOT / "conf" / "cluster.conf"
    cfg = load_config(path)
    # Never let a stub run take minutes: zero out the wall-clock waits.
    cfg.values["BM_REMOVE_AFTER_SEC"] = "0"
    cfg.values["CONSISTENCY_SETTLE_SEC"] = "0"
    cfg.values["SYNC_STABLE_SECONDS"] = "1"
    cfg.values["MIGRATION_STABLE_SECONDS"] = "0"
    # Exercise the opt-in paths too, so a typo in them is caught here.
    cfg.values["DISK_FULL_SIMULATE"] = "true"
    # Deliberately leave SPARE_DN_HOSTS empty: the `adding` case must get its
    # expansion node by holding back the last DataNode of the inventory, which
    # is the path everyone without a spare machine takes.  The explicit-spare
    # variant is covered by the selftests.

    cases_path = Path(cases_file) if cases_file else SKILL_ROOT / "cases" / "remove_cases.tsv"
    cases = load_cases(cases_path)

    # Deliberately NOT under RESULT_DIR: a stubbed run must never leave behind
    # artifacts that a later real `run`/`verify` could pick up.
    root = work_root or Path(tempfile.mkdtemp(prefix="rcdn-smoketest-"))
    if work_root is not None and root.exists():
        shutil.rmtree(root)

    messages: list[str] = []
    log = lambda m="": messages.append(str(m))  # noqa: E731
    aborted: list[str] = []

    cfg.stub_run = True
    with _Stubs(cfg):
        ssh = SshRunner(cfg, root / "scratch")
        sql = SqlClient(cfg, ssh, root / "scratch")
        runner = CaseRunner(cfg, ssh, sql, log, root)
        print(f"smoketest: {len(cases)} case(s), stubbed cluster, results in {root}")
        for case in cases:
            result = runner.run(case)
            crash = [p for p in result.problems if "aborted" in p]
            if crash:
                aborted.append(case.case_id)
            if crash:
                note = "UNHANDLED: " + crash[0][:100]
            elif result.status == "FAIL" and case.case_id in EXPECTED_FAIL_UNDER_STUBS:
                note = "expected under stubs (negative assertion)"
            elif result.status == "SKIP":
                note = "SKIPPED: " + (result.steps[-1][:90] if result.steps else "no reason given")
            else:
                note = result.status
            print(f"  {case.case_id:<34} {result.status:<7} {note}")
    return aborted


# Cases whose *negative* assertions (a remove that must be refused) cannot be
# satisfied by a stub that answers every query with an empty set.
EXPECTED_FAIL_UNDER_STUBS = {
    "dn_nonexistent_remove",
    "cn_nonexistent_remove",
    "dn_remove_rf_limit",
}


def main(conf: str | None = None, cases_file: str | None = None) -> int:
    aborted = run(conf, cases_file)
    print("")
    if aborted:
        print(f"smoketest: {len(aborted)} case(s) raised an unhandled error:")
        for case_id in aborted:
            print(f"  - {case_id}")
        return 1
    print(
        "smoketest: no unhandled error in any case; nothing was contacted.\n"
        f"           {len(EXPECTED_FAIL_UNDER_STUBS)} case(s) report FAIL on purpose "
        "(their assertion needs a real rejection):"
    )
    for case_id in sorted(EXPECTED_FAIL_UNDER_STUBS):
        print(f"             - {case_id}")
    return 0


if __name__ == "__main__":  # pragma: no cover - allows `python3 -m`
    import sys

    _rc = run()
    sys.exit(_rc if isinstance(_rc, int) else 0)
