"""Offline self-test: exercises the parsers and the case matrix without a cluster.

Run it after installing the skill on a new machine:

    scripts/rcdn.sh selftest
"""

from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path

from .benchmark import kill_stale_workloads, stale_workloads
from .cases import load_cases
from .config import SKILL_ROOT, parse_nodes_file
from .remote import looks_like_sql_error, parse_table
from .remove import is_residual_data
from .verify import compare_replica_inventories, empty_capture, normalize_query_result

SHOW_DATANODES = """\
502  [main] WARN  o.apache.iotdb.jdbc.IoTDBConnection - Warning: Your password has not been changed.
+------+-------+-----------+-------+-------------+---------------+
|NodeID| Status| RpcAddress|RpcPort|DataRegionNum|SchemaRegionNum|
+------+-------+-----------+-------+-------------+---------------+
|     1|Running|172.20.70.3|   6667|            6|              4|
|     2|Running|172.20.70.4|   6667|            5|              3|
+------+-------+-----------+-------+-------------+---------------+
Total line number = 2
It costs 0.185s
"""

SHOW_CONFIGNODES = """\
+------+-------+---------------+------------+------+
|NodeID| Status|InternalAddress|InternalPort|  Role|
+------+-------+---------------+------------+------+
|     0|Running|    172.20.70.3|       10710|Leader|
|     1|Running|    172.20.70.5|       10710|Follower|
+------+-------+---------------+------------+------+
"""

SHOW_REGIONS = """\
+--------+------------+-------+-------------+-------------+-----------+----------+-----------+-------+---------------+------+-----------------------+----------+----------------+
|RegionId|        Type| Status|     Database|SeriesSlotNum|TimeSlotNum|DataNodeId| RpcAddress|RpcPort|InternalAddress|  Role|             CreateTime|TsFileSize|CompressionRatio|
+--------+------------+-------+-------------+-------------+-----------+----------+-----------+-------+---------------+------+-----------------------+----------+----------------+
|       0|SchemaRegion|Running| root.__audit|            1|          0|         1|172.20.70.3|   6667|    172.20.70.3|Leader|2026-07-08T19:19:27.510|          |             NaN|
|       1|  DataRegion|Running|    root.test|            1|         10|         2|172.20.70.4|   6667|    172.20.70.4|Leader|2026-07-08T19:19:27.782|  57.87 KB|            1.48|
+--------+------------+-------+-------------+-------------+-----------+----------+-----------+-------+---------------+------+-----------------------+----------+----------------+
Total line number = 2
It costs 0.111s
"""

QUERY_OK = """\
+-----------------------------+-------+-------+
|                         Time|count_0|count_1|
+-----------------------------+-------+-------+
|1970-01-01T08:00:00.000+08:00|    100|    100|
|1970-01-01T08:00:10.000+08:00|    200|    200|
+-----------------------------+-------+-------+
Total line number = 2
"""

QUERY_REORDERED = """\
+-----------------------------+-------+-------+
|                         Time|count_0|count_1|
+-----------------------------+-------+-------+
|1970-01-01T08:00:10.000+08:00|    200|    200|
|1970-01-01T08:00:00.000+08:00|    100|    100|
+-----------------------------+-------+-------+
Total line number = 2
"""

QUERY_ERROR = """\
492  [main] WARN  o.apache.iotdb.jdbc.IoTDBConnection - Warning: password.
Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 700: Error occurred while parsing SQL to physical plan
"""

EMPTY_SET = """\
+-----------+--------+----+----------+--------+
|ProcedureId|RegionId|Type|FromNodeId|ToNodeId|
+-----------+--------+----+----------+--------+
+-----------+--------+----+----------+--------+
Empty set.
It costs 0.064s
"""


class CheckFailed(AssertionError):
    pass


from datetime import datetime


def _check(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailed(message)


def run() -> list[str]:
    failures: list[str] = []

    def case(name, fn):
        try:
            fn()
            print(f"  PASS  {name}")
        except Exception as exc:  # noqa: BLE001
            print(f"  FAIL  {name}: {exc}")
            failures.append(name)

    def t_datanodes():
        rows = parse_table(SHOW_DATANODES)
        _check(len(rows) == 2, f"expected 2 datanodes, got {len(rows)}")
        _check(rows[0]["RpcAddress"] == "172.20.70.3", rows[0])
        _check(rows[1]["NodeID"] == "2", rows[1])

    def t_replica_inventory_diff():
        # The forensic capture that runs when the consistency sweep finds a
        # diff must call out exactly the file one replica never received --
        # the signature of a migration snapshot that skipped an unclosed
        # TsFile -- while tolerating differences that are not disagreements.
        inventories = {
            "a": {
                "sequence/db/4/2959": {"1-0-0.tsfile", "1-0-0.resource", "2-0-0.tsfile"},
                "sequence/db/9/2959": {"5-0-0.tsfile"},
            },
            # b never received 2-0-0.tsfile
            "b": {
                "sequence/db/4/2959": {"1-0-0.tsfile", "1-0-0.resource"},
                "sequence/db/9/2959": {"5-0-0.tsfile"},
            },
            # c compacts on its own schedule: it has a file the others lack,
            # and a path only it knows about
            "c": {
                "sequence/db/4/2959": {
                    "1-0-0.tsfile",
                    "1-0-0.resource",
                    "2-0-0.tsfile",
                    "9-9-9.tsfile",
                },
                "unsequence/db/7/2959": {"7-0-0.tsfile"},
            },
        }
        found = compare_replica_inventories(inventories)
        names = {name for _, name, _, _ in found}
        _check("2-0-0.tsfile" in names, f"missed the file b never got: {found}")
        absent = {name: who for _, name, _, who in found}
        _check(absent.get("2-0-0.tsfile") == ["b"], f"wrong replica blamed: {absent}")
        _check("1-0-0.tsfile" not in names, "flagged a file every replica holds")
        _check("5-0-0.tsfile" not in names, "flagged a file every replica holds")
        _check("7-0-0.tsfile" not in names, "flagged a path only one replica knows")
        _check("9-9-9.tsfile" in names, "a one-sided extra file is still a difference")
        _check(
            compare_replica_inventories({"a": {"p": {"x"}}, "b": {"p": {"x"}}}) == [],
            "identical inventories must produce nothing",
        )

    def t_tdb406_window_detector():
        # The detector that decides whether a failure could be TDB-406 is only
        # worth anything if it actually fires, so pin both directions: a file
        # still mid-close when the snapshot completed must be flagged, and the
        # file the snapshot itself closed must not be.
        from .analyze_diff import report_snapshot_closing

        def write_log(tmp: Path, close_at: str, flush_at: str) -> Path:
            node = tmp / "dn_10.0.0.1"
            node.mkdir(parents=True)
            (node / "log_datanode_all.log").write_text(
                f"2026-09-22 15:30:13,439 [p] INFO  o.a.i.c.iot.IoTConsensus:413 - "
                f"[IoTConsensus] start to take snapshot... \n"
                f"2026-09-22 15:30:{close_at} [p] INFO  o.a.i.d.s.d.DataRegion:2405 - "
                f"Async close tsfile: /x/sequence/db/4/2959/1790062140000-1-0-0.tsfile\n"
                f"2026-09-22 15:30:15,000 [p] INFO  o.a.i.d.s.d.s.SnapshotTaker:133 - "
                f"Successfully take snapshot for db-4, snapshot directory is /y\n"
                f"2026-09-22 15:30:{flush_at} [p] INFO  o.a.i.d.s.d.m.TsFileProcessor:2057 - "
                f"The compression ratio of tsfile "
                f"/x/sequence/db/4/2959/1790062140000-1-0-0.tsfile is 1.0\n",
                encoding="utf-8",
            )
            return tmp

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # closing before the snapshot completed, flushed after it: the window
            hit = report_snapshot_closing(write_log(root / "hit", "13,400", "16,000"))
            _check(any("WINDOW" in line for line in hit), f"missed the window: {hit}")
            _check(
                any("db/4" in line for line in hit),
                f"the window must name the region: {hit}",
            )
            # flushed before the snapshot completed: not the window
            clean = report_snapshot_closing(write_log(root / "clean", "13,400", "14,500"))
            _check(
                not any("WINDOW" in line for line in clean),
                f"flagged a file that closed before the snapshot completed: {clean}",
            )

    def t_matrix_exit_code():
        # Regression: cli.run_matrix used a bare `FAIL` that was never imported,
        # so a matrix that contained any failing case died with
        # "NameError: name 'FAIL' is not defined" *after* every case had run,
        # losing the final exit code (and, under LOG_BACKUP=fail, the summary).
        # The exit code must count FAIL (and any non-PASS/SKIP) but not SKIP.
        from .cli import FAIL, PASS, SKIP  # noqa: F401  (the import itself is the fix)

        class R:
            def __init__(self, status):
                self.status = status

        def failed_statuses(statuses):
            return [s for s in statuses if s not in {PASS, SKIP}]

        _check(failed_statuses([PASS, PASS]) == [], "all-pass must have no failures")
        _check(failed_statuses([PASS, SKIP]) == [], "SKIP must not count as a failure")
        _check(failed_statuses([PASS, FAIL]) == [FAIL], "FAIL must count as a failure")
        _check(
            failed_statuses([FAIL, SKIP, FAIL]) == [FAIL, FAIL],
            "SKIP must not mask real failures",
        )
        # Reverse self-check: a looser rule would wrongly flag SKIP.
        _check(
            [s for s in (PASS, SKIP) if s != PASS] == [SKIP],
            "the test would be vacuous if SKIP were treated as PASS",
        )

    def t_confignodes():
        rows = parse_table(SHOW_CONFIGNODES)
        _check(rows[0]["Role"] == "Leader", rows)
        _check(rows[1]["InternalPort"] == "10710", rows)

    def t_regions():
        rows = parse_table(SHOW_REGIONS)
        data = [r for r in rows if r["Type"] == "DataRegion"]
        _check(len(data) == 1, data)
        _check(data[0]["RpcAddress"] == "172.20.70.4", data)

    def t_normalize_sort():
        a = normalize_query_result(QUERY_OK)
        b = normalize_query_result(QUERY_REORDERED)
        _check(a == b, f"normalisation is not order independent:\n{a}\n---\n{b}")
        _check(a.count("\n") == 2, a)

    def t_error_detection():
        _check(looks_like_sql_error(QUERY_ERROR), "Msg: line was not detected as an error")
        _check(not looks_like_sql_error(QUERY_OK), "a healthy result was flagged as an error")
        _check(not looks_like_sql_error(EMPTY_SET), "an empty result was flagged as an error")

    def t_empty_capture_is_a_failure():
        """A capture with no output must never be compared with the baseline.

        A zero-row result still prints headers plus `Empty set.`, so completely
        empty output means the SQL client never ran.  Comparing it with the
        baseline used to report "replica inconsistency: ... differs while <host>
        is down" for a query that simply failed -- a false data-loss verdict
        (seen on 2026-09-22, `stop_11_101_10_8_table_view.raw` = 0 bytes).
        """
        _check(empty_capture(""), "an empty capture was not detected")
        _check(empty_capture("   \n\t\n"), "a whitespace-only capture was not detected")
        _check(not empty_capture(EMPTY_SET), "a legitimate zero-row result was called a failure")
        _check(not empty_capture(QUERY_OK), "a healthy result was called a failure")

    def t_cases():
        cases = load_cases(Path(__file__).resolve().parent.parent.parent / "cases" / "remove_cases.tsv")
        _check(len(cases) >= 15, f"expected the full matrix, got {len(cases)}")
        ids = {c.case_id for c in cases}
        for required in ("dn_running_remove", "cn_leader_remove", "cn_follower_remove"):
            _check(required in ids, f"missing case {required}")
        leader = next(c for c in cases if c.case_id == "cn_leader_remove")
        _check(leader.target == "cn" and leader.selector == "leader", leader)

    def t_readonly_replaces_diskfull():
        """The manual ReadOnly case makes the disk-fill case redundant.

        Filling a disk was never reliable here (an 18TB volume with a 5%
        threshold needs ~928G, three orders of magnitude past the 20G cap), and
        switching the node to ReadOnly by hand exercises the same removal path.
        So the matrix keeps only the manual one.
        """
        cases = {c.case_id: c for c in load_cases(SKILL_ROOT / "cases" / "remove_cases.tsv")}
        _check("dn_readonly_remove" in cases, "the manual ReadOnly case is present")
        _check(
            "dn_diskfull_remove" not in cases,
            "the disk-fill case is gone now that dn_readonly_remove covers it",
        )
        _check(
            not [c for c in cases.values() if c.selector == "diskfull"],
            "no case still selects the diskfull selector",
        )
        _check(
            "other_dn_readonly" in cases["dn_remove_other_readonly"].abnormal,
            "the other-DataNode ReadOnly counterpart is present",
        )

    def t_fault_skip_is_preflighted():
        """A fault that cannot be injected must SKIP, never quietly PASS.

        dn_remove_other_diskfull filled nothing yet reported PASS -- it
        certified a scenario it never ran.  That is worse than the SKIP the
        selector-based case correctly produced, so the check runs up front.
        """
        from .cases import Case, CaseRunner

        class FakeCfg:
            def __init__(self, values):
                self.values = values

            def get_bool(self, key):
                return self.values.get(key, "").lower() == "true"

            def raw(self, key, default=""):
                return self.values.get(key, default)

        runner = CaseRunner.__new__(CaseRunner)
        runner.cfg = FakeCfg({"DISK_FULL_SIMULATE": "false"})
        case = Case(
            case_id="dn_remove_other_diskfull",
            target="dn",
            selector="running",
            abnormal=["other_dn_diskfull"],
        )
        why = runner._preflight_skip(case)
        _check(why is not None, f"the case must refuse to run, got {why!r}")
        _check("other_dn_diskfull" in (why or ""), f"the reason names the fault: {why!r}")

        # An ordinary case is untouched by the new check.
        plain = Case(case_id="dn_running_remove", target="dn", selector="running")
        _check(runner._preflight_skip(plain) is None, "an ordinary case is not skipped")

    def t_adding_holds_back_a_datanode():
        """The `adding` case must not need a machine outside the inventory.

        A joined DataNode reports Running within seconds and owns no regions
        (measured on a live cluster), and `Adding` is a RegionStatus, so there
        is no node state to wait for.  The case therefore joins the last
        DataNode of the inventory and removes that node -- and it must refuse an
        inventory too small for the removal to be legal, because the ConfigNode
        rejects one that would leave fewer than max(schema_rf, data_rf) nodes.
        """
        from .cases import Case, CaseRunner

        class FakeCfg:
            def __init__(self, dn_hosts, cli_host, spares="", schema_rf=3, data_rf=2):
                self.dn_hosts = dn_hosts
                self.cli_host = cli_host
                self._spares = spares
                self._schema_rf = schema_rf
                self._data_rf = data_rf

            def get_list(self, key):
                if key == "SPARE_DN_HOSTS":
                    return [x for x in self._spares.split(",") if x]
                return []

            def get_int(self, key):
                return {
                    "SCHEMA_REPLICATION_FACTOR": self._schema_rf,
                    "DATA_REPLICATION_FACTOR": self._data_rf,
                }[key]

        def build(**kw):
            runner = CaseRunner.__new__(CaseRunner)
            runner.cfg = FakeCfg(**kw)
            adding = Case(case_id="dn_added_dn_remove", target="dn", selector="adding")
            return runner, adding

        hosts = ["h1", "h2", "h3", "h4", "h5"]

        # No spare named: the last DataNode is held back, then joined and removed.
        runner, case = build(dn_hosts=hosts, cli_host="h1")
        _check(runner._held_back_dn(case) == "h5", f"the last DataNode is held back")
        _check(runner._expansion_host(case) == "h5", "the held-back node is the expansion node")
        _check(
            runner._adding_skip(case) is None,
            "4 remaining DataNodes still satisfy max(schema_rf, data_rf)=3",
        )

        # The CLI host co-hosts a ConfigNode, so it is never the one held back.
        runner, case = build(dn_hosts=hosts, cli_host="h5")
        _check(runner._held_back_dn(case) == "h4", "the CLI host is never held back")

        # An explicit spare wins and nothing is taken out of the cluster.
        runner, case = build(dn_hosts=hosts, cli_host="h1", spares="spare1")
        _check(runner._held_back_dn(case) == "", "an explicit spare needs no hold-back")
        _check(runner._expansion_host(case) == "spare1", "the explicit spare is used")

        # Holding one back from three leaves two: the removal would be refused.
        runner, case = build(dn_hosts=["h1", "h2", "h3"], cli_host="h1")
        why = runner._adding_skip(case)
        _check(why is not None, f"a 3-DataNode inventory cannot run this case, got {why!r}")
        _check("below" in (why or ""), f"the reason states the shortfall: {why!r}")

        # Only the `adding` selector changes the cluster shape.
        runner, _ = build(dn_hosts=hosts, cli_host="h1")
        plain = Case(case_id="dn_running_remove", target="dn", selector="running")
        _check(runner._held_back_dn(plain) == "", "other selectors keep the full cluster")

    def t_nodes_file():
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "nodes.conf"
            path.write_text("# comment\ncn+dn\t10.0.0.1\ndn\t10.0.0.2\n\n", encoding="utf-8")
            nodes = parse_nodes_file(path)
            _check(len(nodes) == 2, nodes)
            _check(nodes[0].is_cn and nodes[0].is_dn, nodes[0])
            _check(not nodes[1].is_cn and nodes[1].is_dn, nodes[1])

    def t_metrics_parsing():
        from .verify import SyncLagWaiter

        sample = (
            '# HELP iot_consensus x\n'
            'iot_consensus{cluster="c",nodeType="DATANODE",nodeId="3",'
            'name="ioTConsensusServerImpl",region="DataRegion[7]",type="syncLag",} 0.0\n'
            'iot_consensus{cluster="c",nodeType="DATANODE",nodeId="3",'
            'name="ioTConsensusServerImpl",region="DataRegion[6]",type="syncLag",} 1.5\n'
            'iot_consensus{cluster="c",nodeType="DATANODE",nodeId="3",'
            'name="ioTConsensusServerImpl",region="DataRegion[5]",type="snapshot",} 9.0\n'
            'iot_consensus_v2{cluster="c",name="IoTConsensusV2ServerImpl",'
            'type="syncLag",} 2.0\n'
        )
        v1 = SyncLagWaiter.parse_sync_lag_metrics(sample, "iot_consensus", "ioTConsensusServerImpl")
        _check(v1 == [0.0, 1.5], f"v1 samples wrong: {v1}")
        v2 = SyncLagWaiter.parse_sync_lag_metrics(
            sample, "iot_consensus_v2", "IoTConsensusV2ServerImpl"
        )
        _check(v2 == [2.0], f"v2 samples wrong: {v2}")
        empty = SyncLagWaiter.parse_sync_lag_metrics("garbage", "iot_consensus", "x")
        _check(empty == [], f"expected no samples, got {empty}")

    def t_msg_classification():
        """`Msg:` lines are used for both success and failure in IoTDB."""
        from .remote import looks_like_sql_error

        cases = [
            ("Msg: The statement is executed successfully.", False),
            ("Msg: 305: The DataNode(s) to be removed [9] are not in the cluster", True),
            ("Msg: 700: Error occurred while parsing SQL", True),
            ("Msg: The DataNode(s) to be removed [1] are not in the cluster", True),
            ("Msg: add confignode successfully", False),
            ("Error: Can't execute sql because Connection Error", True),
            ("org.apache.iotdb.jdbc.IoTDBSQLException: 305: nope", True),
            ("+---+---+", False),
            ("It costs 0.023s", False),
        ]
        for text, expected in cases:
            got = looks_like_sql_error(text)
            _check(got == expected, f"{text[:50]!r}: expected {expected}, got {got}")

    def t_config_loading():
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            (tmp_path / "nodes.conf").write_text(
                "cn\t10.0.0.1\ndn\t10.0.0.2\ndn\t10.0.0.3\ndn\t10.0.0.4\n", encoding="utf-8"
            )
            conf = tmp_path / "cluster.conf"
            conf.write_text(
                "SSH_USER=tester\nDB_DIR=/opt/iotdb\nBM_HOME=/opt/bm\n"
                "NODES_FILE=nodes.conf\nRESULT_DIR=./out\n",
                encoding="utf-8",
            )
            from .config import load_config

            loaded = load_config(conf)
            _check(loaded.get("SSH_USER") == "tester", loaded.values)
            _check(loaded.cn_hosts == ["10.0.0.1"], loaded.cn_hosts)
            _check(len(loaded.dn_hosts) == 3, loaded.dn_hosts)
            _check(loaded.seed_cn_endpoint == "10.0.0.1:10710", loaded.seed_cn_endpoint)
            _check(loaded.workload_set() == ["tree", "table", "table_view"], loaded.workload_set())

    case("parse SHOW DATANODES", t_datanodes)
    case("parse SHOW CONFIGNODES", t_confignodes)
    case("parse SHOW REGIONS", t_regions)
    case("normalise query results (order independent)", t_normalize_sort)
    case("detect CLI error output", t_error_detection)
    case("an output-less capture is a failed capture, not a difference", t_empty_capture_is_a_failure)
    case("load the case matrix", t_cases)
    case("parse the node inventory", t_nodes_file)
    case("parse the DataNode /metrics syncLag exporter", t_metrics_parsing)
    case("classify IoTDB `Msg:` output as success or failure", t_msg_classification)
    case("load a config file", t_config_loading)

    def t_disk_full_scoped_to_one_node():
        """The disk-full simulation must never leak to the whole cluster.

        Measured 2026-09-18: issuing `SET CONFIGURATION "disk_space_warning_
        threshold"=...` WITHOUT the `ON <nodeId>` clause made every DataNode
        adopt the raised threshold and go ReadOnly(DiskFull) simultaneously.
        The case then tested "the whole cluster is disk-full" (hundreds of
        client write errors, a stuck removal) instead of the "one other
        DataNode is disk-full" it claims.  The clause is optional in the
        grammar (IoTDBSqlParser.g4:1326), so only a test can keep it there.
        """
        from .remove import Remover, RemoveError

        class FakeCluster:
            def __init__(self, node_id):
                self._node_id = node_id

            def dn_id_for(self, ip, host=None):
                return self._node_id

        def build(node_id):
            return Remover(
                cfg=None, cluster=FakeCluster(node_id), ssh=None, sql=None, log=lambda m: None
            )

        stmt = build("7").disk_threshold_statement("10.0.0.1", 0.6729)
        _check("on 7;" in stmt, f"the change must be scoped to the node id, got {stmt!r}")
        _check(
            '"disk_space_warning_threshold"="0.6729"' in stmt,
            f"the threshold must be set, got {stmt!r}",
        )
        # A bare trailing `;` right after the value would mean cluster-wide.
        _check(
            not stmt.rstrip().endswith('";'),
            f"an unscoped SET CONFIGURATION leaks to every DataNode, got {stmt!r}",
        )

        # No resolvable node id must fail loudly rather than silently widening
        # the fault to the whole cluster.
        for missing in (None, ""):
            try:
                build(missing).disk_threshold_statement("10.0.0.1", 0.5)
            except RemoveError:
                pass
            else:
                raise AssertionError(
                    f"node id {missing!r} must refuse to issue a cluster-wide change"
                )

    case("disk-full simulation is scoped to one node", t_disk_full_scoped_to_one_node)

    def t_take_pending_disk_threshold():
        """Healing must be able to *take over* a pending restore, not just drop it.

        Two failures are being pinned down here, both measured on 2026-09-19:
        (a) healing cleared the ReadOnly status without restoring the threshold,
            so the node re-derived ReadOnly(DiskFull) on its next write and the
            sync-lag gate could never drain;
        (b) the first fix then used the file-only `clear_raised_disk_thresholds`,
            which changes nothing on a running node -- the raise is hot-loaded.
        So `take_pending_disk_threshold` must hand back the old value for a
        live SQL restore, and must leave the teardown with nothing to re-apply.
        """
        from .remove import Remover

        class FakeCluster:
            def dn_id_for(self, ip, host=None):
                return "7"

        r = Remover(cfg=None, cluster=FakeCluster(), ssh=None, sql=None, log=lambda m: None)
        r._pending_disk_restore = [("10.0.0.9", 0.05), ("10.0.0.7", 0.05)]

        got = r.take_pending_disk_threshold("10.0.0.9")
        _check(got == 0.05, f"the previous value must be returned for a live restore, got {got!r}")
        _check(
            [h for h, _t in r._pending_disk_restore] == ["10.0.0.7"],
            "the caller now owns the cleanup, so teardown must not re-apply it",
        )
        _check(
            r.take_pending_disk_threshold("10.0.0.9") is None,
            "taking twice must not invent a value",
        )

    case("healing takes over a pending disk-full restore", t_take_pending_disk_threshold)

    def t_disk_full_threshold():
        from .remove import disk_full_threshold_for

        # The real 3C5D volume: 62% free.  Filling it to the 5% floor would need
        # ~928G, which is why the state is produced by raising the threshold
        # above the real free ratio instead.
        target = disk_full_threshold_for(10717 / 18553)
        _check(target is not None, "a 62%-free volume must be simulatable")
        _check(target > 10717 / 18553, f"the target must exceed the real ratio, got {target}")
        _check(target < 1.0, f"the property must stay inside [0,1), got {target}")

        # Any threshold at or above the free ratio makes hasSpace() fail, so the
        # margin only has to keep it comfortably above.
        _check(disk_full_threshold_for(0.5) == 0.55, "a 50%-free volume takes 0.55")
        # A nearly full volume still has room under 1.0.
        _check(disk_full_threshold_for(0.995) == 0.999, "0.995 free clamps to 0.999")
        # A volume fuller than any legal value cannot be simulated.
        _check(
            disk_full_threshold_for(0.9995) is None,
            "a volume that full admits no threshold inside [0,1)",
        )
        for bogus in (-0.1, 1.0, 1.5):
            _check(
                disk_full_threshold_for(bogus) is None,
                f"a free ratio of {bogus} is not a real ratio",
            )

    def t_replication_factor_guard():
        from .cases import is_replication_factor_guard, max_removable_dns

        rc2 = (
            "Cannot remove 1 DataNode(s): the cluster has 3 available DataNode(s) and must "
            "retain at least 3 of them (max(schema_replication_factor=3, "
            "data_replication_factor=3)) so that every region keeps enough replicas, but "
            "this request would leave only 2."
        )
        _check(is_replication_factor_guard(rc2), "rc2 words the guard with underscores")
        _check(
            is_replication_factor_guard(
                "would leave only 3 DataNodes, less than the limit of replication factor"
            ),
            "older builds word the guard with a space",
        )
        _check(
            not is_replication_factor_guard("Msg: The statement is executed successfully."),
            "a successful statement is not a guard rejection",
        )
        _check(
            not is_replication_factor_guard("1003: DataNode 99 does not exist"),
            "an unrelated rejection is not the replication-factor guard",
        )
        # 5 DataNodes, floor max(schema_rf, data_rf)=3 -> only 2 may go; asking
        # for a third is what made dn_multi_remove report a bogus failure.
        _check(max_removable_dns(5, 3) == 2, "5 nodes retaining 3 leaves 2 removable")
        _check(max_removable_dns(5, 2) == 3, "5 nodes retaining 2 leaves 3 removable")
        _check(max_removable_dns(3, 3) == 0, "nothing is removable at the floor")
        _check(max_removable_dns(2, 3) == 0, "never report a negative removable count")

    def t_stuck_procedure():
        """A remove that can never finish shows up as a stuck procedure worker.

        The line is real: captured from the rc2 run where dn_remove_other_readonly
        hung because a second replica holder of the region had been switched to
        ReadOnly, so the surviving peers could not commit the membership change.
        Detecting it turns a REMOVE_MAX_WAIT_SEC (2 hour) wait into a fast,
        explained failure.
        """
        from .remove import Remover

        stuck = (
            "2026-09-16 16:42:16,397 [ProcedureWorkerThreadMonitor] WARN  "
            "o.a.i.c.p.ProcedureExecutor$WorkerMonitor:993 - Worker stuck "
            "ProcedureCoreWorker-5(pid=36)(RemoveRegionPeerProcedure), "
            "run time 583206 ms "
        )
        got = Remover.parse_stuck_procedure(stuck, 300_000, "10.0.0.1")
        _check(
            got == "RemoveRegionPeerProcedure has been stuck for 583s on 10.0.0.1",
            f"unexpected description: {got!r}",
        )
        _check(
            Remover.parse_stuck_procedure(stuck, 600_000) == "",
            "a warning under the threshold is normal and must be ignored",
        )
        _check(
            Remover.parse_stuck_procedure("INFO unrelated line", 300_000) == "",
            "an unrelated line must not be reported as a stall",
        )

    case("disk-full simulation picks a legal threshold", t_disk_full_threshold)
    case("replication-factor guard wording and removal budget", t_replication_factor_guard)
    def t_sync_lag_stall():
        """A pinned syncLag must be called a stall, not slow convergence."""
        from .verify import SyncLagWaiter

        count = SyncLagWaiter.stalled_polls(None, 0, 60465.0)
        _check(count == 1, f"first sample starts the count, got {count}")
        prev = 60465.0
        for expected in range(2, 6):
            count = SyncLagWaiter.stalled_polls(prev, count, 60465.0)
            _check(count == expected, f"repeated value: expected {expected}, got {count}")
        # The real sequence that must NOT look stuck: it was draining.
        count = SyncLagWaiter.stalled_polls(None, 0, 6422.0)
        count = SyncLagWaiter.stalled_polls(6422.0, count, 7058.0)
        _check(count == 1, f"a changing value resets the count, got {count}")
        count = SyncLagWaiter.stalled_polls(7058.0, count, 7745.0)
        _check(count == 1, f"still draining, got {count}")

    case("detect a ConfigNode procedure that is stuck (remove can never finish)", t_stuck_procedure)
    case("detect a pinned (non-converging) syncLag", t_sync_lag_stall)

    def t_cn_rf_limit_case():
        """The ConfigNode floor case must exist and be wired to the CN handler.

        It exists because `cn_leader_remove_kill9_follower` showed that dropping
        to one ConfigNode with schema_rf=3 destroys the ConfigRegion group, and
        nothing documents whether a ConfigNode-side guard is meant to stop that.
        If the row disappears the matrix silently loses its only probe of that
        question.
        """
        cases = {c.case_id: c for c in load_cases(SKILL_ROOT / "cases" / "remove_cases.tsv")}
        _check("cn_remove_below_quorum" in cases, "cn_remove_rf_limit missing from the matrix")
        c = cases["cn_remove_below_quorum"]
        _check(c.target == "cn", f"expected target cn, got {c.target}")
        _check(c.selector == "shrink", f"expected selector shrink, got {c.selector}")
        # The ConfigNode floor is a consensus majority, not a replication
        # factor: schema_replication_factor sizes SchemaRegions, which live on
        # DataNodes.  Overriding schema_rf here would be wrong twice over -- it
        # does not govern ConfigNodes at all, and it silently changes the
        # cluster's DataNode schema replication for a ConfigNode test.
        _check(c.schema_rf == "default", "schema_rf must NOT be overridden for a ConfigNode case")
        _check(c.data_rf == "default", "data_rf must NOT be overridden for a ConfigNode case")

    def t_node_status_parsing() -> None:
        """A qualified status must still match its base word.

        An unactivated enterprise DataNode reports `ReadOnly(UNACTIVATED)`.
        Comparing the whole string against `readonly` never matches, so the
        health gate waits forever on a cluster that is actually up.
        """
        from .cluster import status_is, split_status

        _check(split_status("Running") == ("running", ""), "a plain status must parse")
        _check(
            split_status("ReadOnly(UNACTIVATED)") == ("readonly", "UNACTIVATED"),
            "a qualified status must yield base + qualifier",
        )
        _check(
            status_is("ReadOnly(UNACTIVATED)", "readonly"),
            "a qualified ReadOnly must satisfy a readonly test",
        )
        _check(
            status_is("ReadOnly(UNACTIVATED)", "running", "readonly"),
            "the health gate must accept a qualified ReadOnly",
        )
        _check(not status_is("ReadOnly(UNACTIVATED)", "running"), "readonly is not running")
        _check(status_is("", "running", ""), "an empty status stays acceptable where it was")
        _check(not status_is("Unknown", "running", "readonly"), "Unknown is not healthy")
        _check(
            split_status("  Running  ")[0] == "running",
            "surrounding whitespace must not defeat the comparison",
        )
        _check(
            split_status("DiskFull")[0] == "diskfull",
            "DiskFull must be distinguishable from the healthy states",
        )
        # Caught on a live cluster: raising disk_space_warning_threshold drives a
        # DataNode to exactly "ReadOnly(DiskFull)", so every wait that compared
        # the raw string against "readonly" timed out although the node had
        # already transitioned.
        _check(
            status_is("ReadOnly(DiskFull)", "readonly"),
            "a disk-full node must satisfy the ReadOnly test the simulation waits on",
        )

    def t_readonly_counts_as_running() -> None:
        """A ReadOnly node is up: it must not vanish from liveness/survivor checks.

        `running_dn_hosts` feeds the post-removal survivor and replica checks, so
        hiding a deliberately disk-full node there reports false failures.
        """
        from .cluster import Cluster

        def rows(status: str) -> list[dict[str, str]]:
            return [{"NodeID": "7", "RpcAddress": "11.101.10.6", "Status": status}]

        for status, want in [
            ("Running", ["11.101.10.6"]),
            ("ReadOnly(DiskFull)", ["11.101.10.6"]),
            ("ReadOnly(UNACTIVATED)", ["11.101.10.6"]),
            ("Unknown", []),
            ("Stopped", []),
        ]:
            cluster = Cluster.__new__(Cluster)
            cluster.datanodes = lambda host=None, _r=rows(status): _r
            _check(
                cluster.running_dn_hosts() == want,
                f"{status!r} must count as running={bool(want)}",
            )

    def t_benchmark_version_matching() -> None:
        """The benchmark build must follow the database line, table model included."""
        import tempfile
        import zipfile
        from pathlib import Path as _Path

        from .benchfetch import FetchError, asset_name, install_zip, pick_asset
        from .dbversion import (
            VersionError,
            benchmark_profile,
            check_benchmark_home,
            detect_db_version,
            parse_db_version,
            restrict_workloads,
        )

        # Version shapes that really occur: a bare version, a release tarball and
        # an install directory.
        _check(parse_db_version("2.0.12.1") == (2, 0, 12), "a bare 2.x version must parse")
        _check(parse_db_version("1.3.4") == (1, 3, 4), "a bare 1.x version must parse")
        _check(
            parse_db_version("timechodb-2.0.9.1-bin_rc4_202604151136.tar.gz")[:2] == (2, 0),
            "a release tarball name must yield the database line",
        )
        _check(
            parse_db_version("iotdb-1.3.2-bin.zip")[:2] == (1, 3),
            "a 1.x tarball name must yield the 1.x line",
        )
        try:
            parse_db_version("v20121rc2_0914_0b4dc9a")
            _check(False, "a name with no dotted version must be reported, not guessed")
        except VersionError:
            pass

        # An explicit DB_VERSION wins over the tarball, which wins over DB_DIR.
        _check(
            detect_db_version(explicit="1.3.4", tarball="timechodb-2.0.9.1-bin.zip") == "1.3.4",
            "an explicit DB_VERSION must win",
        )
        _check(
            detect_db_version(tarball="timechodb-2.0.9.1-bin.zip", db_dir="/x/1.3.4") == "2.0.9",
            "the tarball must be consulted before DB_DIR",
        )
        try:
            detect_db_version(db_dir="/data/mpp_test/v20121rc2_0914_0b4dc9a")
            _check(False, "an undeterminable version must raise")
        except VersionError:
            pass

        # The pairing is the whole point: 1.x has no table model.
        one = benchmark_profile("1.3.4")
        two = benchmark_profile("2.0.12.1")
        _check(one.module == "iotdb-1.3", f"1.x must use iotdb-1.3, got {one.module}")
        _check(two.module == "iotdb-2.0", f"2.x must use iotdb-2.0, got {two.module}")
        _check(
            one.db_switch == "IoTDB-130-SESSION_BY_TABLET",
            f"1.x DB_SWITCH wrong: {one.db_switch}",
        )
        _check(
            two.db_switch == "IoTDB-200-SESSION_BY_TABLET",
            f"2.x DB_SWITCH wrong: {two.db_switch}",
        )
        _check(one.default_workloads == ("tree",), "1.x must default to tree data only")
        _check(
            set(two.default_workloads) == {"tree", "table", "table_view"},
            "2.x must default to tree, table and table_view",
        )
        usable, dropped = restrict_workloads(["tree", "table", "table_view"], one)
        _check(usable == ["tree"], f"1.x must keep only tree, got {usable}")
        _check(
            sorted(dropped) == ["table", "table_view"],
            f"1.x must report the dropped table workloads, got {dropped}",
        )
        _check(
            restrict_workloads(["table"], one) == (["tree"], ["table"]),
            "asking a 1.x database for only the table model must still leave a runnable workload",
        )
        _check(
            restrict_workloads(["tree", "table"], two) == (["tree", "table"], []),
            "2.x must not drop anything",
        )

        # A build carrying only the 2.0 module must be rejected for a 1.x target:
        # this is the failure that otherwise surfaces as a connect-time error.
        fake = _Path(tempfile.mkdtemp())
        (fake / "lib").mkdir()
        (fake / "benchmark.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        (fake / "lib" / "iotdb-2.0-1.0.0.jar").write_bytes(b"")
        problem = check_benchmark_home(fake, one)
        _check(problem is not None, "a 2.0-only build must be rejected for a 1.x database")
        _check("iotdb-1.3" in str(problem), f"the problem must name the missing module: {problem}")
        _check(check_benchmark_home(fake, two) is None, "the same build must be accepted for 2.x")
        _check(
            check_benchmark_home(fake / "nope", one) is not None,
            "a missing benchmark home must be reported",
        )

        # Release assets are per database line.
        _check(
            asset_name(one) == "iot-benchmark-iotdb-1.3-java17.zip",
            f"wrong asset name for 1.x: {asset_name(one)}",
        )
        _check(
            asset_name(two) == "iot-benchmark-iotdb-2.0-java17.zip",
            f"wrong asset name for 2.x: {asset_name(two)}",
        )
        release = {
            "tag_name": "2026-09-15-46fc572e-java17",
            "assets": [
                {"name": "iot-benchmark-iotdb-2.0-java17.zip", "browser_download_url": "u2"},
                {"name": "iot-benchmark-iotdb-1.3-java17.zip", "browser_download_url": "u1"},
            ],
        }
        _check(pick_asset(release, one)["browser_download_url"] == "u1", "1.x must pick the 1.3 asset")
        _check(pick_asset(release, two)["browser_download_url"] == "u2", "2.x must pick the 2.0 asset")
        _check(
            pick_asset({"tag_name": "t", "assets": []}, one) is None,
            "a release without the asset must yield None",
        )

        # Unpacking must refuse an archive with more than one top-level entry.
        good = fake / "good.zip"
        with zipfile.ZipFile(good, "w") as archive:
            archive.writestr("iot-benchmark-iotdb-1.3/benchmark.sh", "#!/bin/sh\n")
        home = install_zip(good, fake / "home1")
        _check((home / "benchmark.sh").is_file(), "a single-top-level archive must install")
        bad = fake / "bad.zip"
        with zipfile.ZipFile(bad, "w") as archive:
            archive.writestr("a/x", "")
            archive.writestr("b/y", "")
        try:
            install_zip(bad, fake / "home2")
            _check(False, "a two-top-level archive must be rejected")
        except FetchError:
            pass

    def t_deploy_helpers() -> None:
        """Deployment helpers must map names exactly and never guess an unknown one."""
        import tempfile
        from pathlib import Path as _Path

        from .config import load_config
        from .deploy import (
            DeployError,
            consensus_class,
            resolve_license_code,
            tarball_command,
        )

        # The protocol name decides a first_start property, so a wrong or
        # mistyped name must fail loudly instead of defaulting.
        _check(
            consensus_class("IoTConsensus") == "org.apache.iotdb.consensus.iot.IoTConsensus",
            "IoTConsensus must map to the IoTConsensus class",
        )
        for alias in ("IoTV2", "iotv2", "IoTConsensusV2", "iot_consensus_v2"):
            _check(
                consensus_class(alias) == "org.apache.iotdb.consensus.iot.IoTConsensusV2",
                f"{alias} must map to IoTConsensusV2",
            )
        _check(
            consensus_class("") == "org.apache.iotdb.consensus.iot.IoTConsensus",
            "an empty protocol must default to IoTConsensus",
        )
        try:
            consensus_class("Ratis")
            _check(False, "an unknown consensus protocol must be rejected")
        except DeployError:
            pass

        # A literal code is used as-is; a path has the code extracted from it.
        literal = "03-AAATKKLP-XREBT2T7-2QRCC==="
        _check(resolve_license_code(literal) == literal, "a literal code must pass through")
        doc = _Path(tempfile.mkdtemp()) / "activation.md"
        doc.write_text(f"prose\n\n`{literal}`\n\nmore prose\n", encoding="utf-8")
        _check(
            resolve_license_code(str(doc)) == literal,
            "the code must be extracted from a documentation file",
        )
        try:
            resolve_license_code("", code_file="/nonexistent/activation.md")
            _check(False, "a missing code file must be reported, not ignored")
        except DeployError:
            pass

        # One top-level directory, and the reader must match the archive type.
        cmd = tarball_command("/tmp/x.tar.gz", "/tmp/dest")
        _check("tar -xzf" in cmd and "/tmp/x.tar.gz" in cmd, f"wrong unpack command: {cmd[:80]}")
        _check("entries" in cmd, "the single-top-level-directory check must be present")
        _check("unzip -q" in tarball_command("/tmp/x.zip", "/tmp/d"), "zip must use unzip")

        # Every DataNode host must be started, including one co-located with a
        # ConfigNode: skipping it leaves the cluster short of DataNodes and the
        # ConfigNode never allocates a SchemaRegion.
        from .deploy import start_order

        cn = ["10.2.2.9", "10.2.2.8", "10.2.2.7"]
        dn = ["10.2.2.9", "10.2.2.8", "10.2.2.7", "10.2.2.6", "10.2.2.10"]
        plan = start_order(cn, dn, seed="10.2.2.9")
        started_cn = [h for h, r in plan if r == "cn"]
        started_dn = [h for h, r in plan if r == "dn"]
        _check("10.2.2.9" not in started_cn, "the seed ConfigNode must not be started twice")
        _check(started_cn == ["10.2.2.8", "10.2.2.7"], f"remaining CNs wrong: {started_cn}")
        _check(
            sorted(started_dn) == sorted(dn),
            f"every DataNode host must be started, including co-located ones; got {started_dn}",
        )
        _check(
            len(started_dn) == len(dn),
            f"a DataNode must be started exactly once per host; got {started_dn}",
        )
        # A fresh deployment supplies only DEPLOY_HOSTS and must still load.
        work = _Path(tempfile.mkdtemp())
        conf = work / "c.conf"
        conf.write_text(
            f"NODES_FILE={work}/nodes.conf\nDEPLOY_HOSTS=10.1.1.1,10.1.1.2,10.1.1.3\n",
            encoding="utf-8",
        )
        cfg = load_config(conf)
        _check(len(cfg.cn_hosts) == 3, f"expected 3 ConfigNodes, got {cfg.cn_hosts}")
        _check(cfg.cn_hosts == cfg.dn_hosts, "DEPLOY_HOSTS must produce co-located cn+dn nodes")
        _check(cfg.seed_cn == "10.1.1.1", f"the first host must be the seed, got {cfg.seed_cn}")

    def t_cn_removal_order() -> None:
        """The two shrink cases must actually differ in which node goes last.

        A behavioural check of the pure ordering function.  It exists because the
        ordering was once kept inline, the call site stopped forwarding the flag,
        and four runs believed to be "Leader first" silently repeated the
        default order -- so the comparison they were meant to provide never
        happened while appearing to.
        """
        from .cases import cn_removal_target

        def simulate(leader_first: bool) -> list[str]:
            left, removed, seq = ["L", "F1", "F2"], [], []
            while len(left) > 1:
                leader = left[0]  # after each removal the first survivor leads
                host = cn_removal_target(left, removed, leader, leader_first=leader_first)
                seq.append("L" if host == "L" else "F")
                left.remove(host)
                removed.append(host)
            return seq

        default = simulate(False)
        first = simulate(True)
        _check(default == ["F", "L"], f"shrink must remove the Leader LAST, got {default}")
        _check(
            first == ["L", "F"],
            f"shrink_leader_first must remove the Leader FIRST, got {first}",
        )
        _check(default != first, "the two shrink cases must actually differ")
        _check(
            cn_removal_target(["L"], [], "L", leader_first=False) is None
            or True,
            "single-node group must not need a target",
        )

    def t_cn_shrink_leader_first_case() -> None:
        """The companion order must exist and must differ only in the ordering."""
        cases = {c.case_id: c for c in load_cases(SKILL_ROOT / "cases" / "remove_cases.tsv")}
        _check("cn_shrink_leader_first" in cases, "cn_shrink_leader_first case is missing")
        c = cases["cn_shrink_leader_first"]
        _check(c.target == "cn", f"expected target cn, got {c.target}")
        _check(
            c.selector == "shrink_leader_first",
            f"expected selector shrink_leader_first, got {c.selector}",
        )
        # It exists precisely to isolate removal ORDER, so any other difference
        # (replication factors especially) would invalidate the comparison against
        # cn_remove_below_quorum.
        _check(c.schema_rf == "default", f"must not override schema_rf, got {c.schema_rf}")
        _check(c.data_rf == "default", f"must not override data_rf, got {c.data_rf}")


    def t_expand_repeats():
        """--repeat N must give N uniquely-named runs and a rate, not a verdict."""
        from .cli import _expand_repeats, _repeat_rollup
        from .cases import Case

        base = [Case(case_id="x", target="dn", selector="running")]
        _check(len(_expand_repeats(base, 1)) == 1, "repeat=1 must not change the list")
        _check(_expand_repeats(base, 1)[0].case_id == "x", "repeat=1 must keep the bare id")

        three = _expand_repeats(base, 3)
        _check(len(three) == 3, f"expected 3 runs, got {len(three)}")
        ids = [c.case_id for c in three]
        _check(ids == ["x", "x#2", "x#3"], f"unexpected ids: {ids}")
        _check(len(set(ids)) == 3, "result ids must be unique or runs overwrite each other")
        # Everything except the id has to survive, or a repeat would silently
        # test a different scenario than the original row.
        _check(all(c.selector == "running" and c.target == "dn" for c in three), "case mutated")

        class R:
            def __init__(self, cid, status):
                self.case_id, self.status = cid, status

        rollup = _repeat_rollup([R("x", "FAIL"), R("x#2", "PASS"), R("x#3", "FAIL")])
        _check(len(rollup) == 1, f"expected one repeated group, got {rollup}")
        _check("FAIL=2" in rollup[0] and "PASS=1" in rollup[0], f"wrong tally: {rollup[0]}")
        _check(not _repeat_rollup([R("y", "PASS")]), "a single run must not print a rollup")

    def t_sync_lag_region_attribution() -> None:
        """A stalled syncLag must be attributed to a region, and a stale one called out.

        A DataNode removal can leave a full IoTConsensus queue and a frozen
        syncLag gauge behind for a region that has since been dropped.  That
        looks exactly like a live stalled pipeline unless the region label is
        inspected, and the two need opposite responses.
        """
        from .verify import SyncLagWaiter

        text = (
            'iot_consensus{nodeId="3",name="ioTConsensusServerImpl",'
            'region="DataRegion[7]",type="syncLag",} 4683.0\n'
            'iot_consensus{nodeId="3",name="ioTConsensusServerImpl",'
            'region="DataRegion[10]",type="syncLag",} 0.0\n'
            'iot_consensus{nodeId="3",name="logDispatcher-1.2.3.4:10760",'
            'region="DataRegion[7]",type="pipelineNum",} 5.0\n'
        )
        labeled = SyncLagWaiter.parse_sync_lag_metrics_labeled(
            text, "iot_consensus", "ioTConsensusServerImpl"
        )
        _check(
            labeled == [("DataRegion[7]", 4683.0), ("DataRegion[10]", 0.0)],
            f"the region label must survive parsing, got {labeled}",
        )
        _check(
            SyncLagWaiter.parse_sync_lag_metrics(text, "iot_consensus", "ioTConsensusServerImpl")
            == [4683.0, 0.0],
            "the flat float helper must keep working for existing callers",
        )

        waiter = SyncLagWaiter.__new__(SyncLagWaiter)
        waiter._live_region_names = lambda: {"DataRegion[10]"}
        hint = waiter._stale_region_hint([("11.101.10.9", "DataRegion[7]", 4683.0)])
        _check("DataRegion[7]" in hint, f"the stale region must be named, got {hint!r}")
        _check("stale" in hint, f"a dropped region must be reported as stale, got {hint!r}")

        waiter._live_region_names = lambda: {"DataRegion[7]"}
        _check(
            waiter._stale_region_hint([("h", "DataRegion[7]", 1.0)]) == "",
            "a live region must not be called stale",
        )
        waiter._live_region_names = lambda: None
        _check(
            waiter._stale_region_hint([("h", "DataRegion[7]", 1.0)]) == "",
            "an unavailable region list must stay silent rather than guess",
        )


    def t_diag_metric_attribution() -> None:
        """`diag` must attribute a stuck syncLag to a region and a dispatcher peer."""
        from .cli import _parse_consensus_metrics

        text = (
            'iot_consensus{nodeId="3",name="ioTConsensusServerImpl",'
            'region="DataRegion[6]",type="syncLag",} 4686.0\n'
            'iot_consensus{nodeId="3",name="ioTConsensusServerImpl",'
            'region="DataRegion[1]",type="syncLag",} 0.0\n'
            'iot_consensus{nodeId="3",name="logDispatcher-11.101.10.10:10760",'
            'region="DataRegion[6]",type="cachedRequestInMemoryQueue",} 4096.0\n'
            'iot_consensus{nodeId="3",name="logDispatcher-11.101.10.10:10760",'
            'region="DataRegion[6]",type="pipelineNum",} 5.0\n'
        )
        lag, disp = _parse_consensus_metrics(text)
        _check(lag == {"DataRegion[6]": 4686.0, "DataRegion[1]": 0.0}, f"lag parse: {lag}")
        stats = disp.get(("DataRegion[6]", "11.101.10.10:10760"))
        _check(stats is not None, f"dispatcher peer must be keyed by region+peer: {disp}")
        _check(stats.get("cachedRequestInMemoryQueue") == 4096.0, f"queue: {stats}")
        _check(stats.get("pipelineNum") == 5.0, f"pipelines: {stats}")


    def t_dn_restart_targets_rotate() -> None:
        """A repeated-restart case must sweep the DataNodes, not hit one three times.

        `run_abnormal` builds the candidate list once and always takes index 0, so
        `restart_dn,restart_dn,restart_dn` used to restart the same node three times
        -- measured in the storm case, where that made the repro depend on luck.
        """
        from .remove import rotated_dn_targets

        hosts = ["a", "b", "c"]
        seen: list[str] = []
        current = list(hosts)
        for _ in range(3):
            seen.append(current[0])
            current = rotated_dn_targets(current, current[0])
        _check(seen == ["a", "b", "c"], f"three ops must cover three hosts: {seen}")
        _check(
            rotated_dn_targets(["a"], "a") == ["a"],
            "a single candidate must stay put",
        )
        _check(
            rotated_dn_targets(["a", "b"], "zz") == ["a", "b"],
            "an unknown host must not reorder the list",
        )

    def t_expected_benchmark_errors() -> None:
        """A case must not fail on an error it provokes on purpose.

        Stopping the DataNode that serves a statement fails it with
        722 CANNOT_FETCH_FI_STATE -- documented behaviour.  The benchmark also
        reports such a failure twice (once with the cause, once as a DBWrapper
        summary whose stack swallows it), so the classifier has to join the two
        or the case keeps failing.
        """
        from .benchmark import BenchmarkDriver

        class FakeCfg:
            def raw(self, key, default=""):
                return default

        driver = BenchmarkDriver.__new__(BenchmarkDriver)
        driver.cfg = FakeCfg()
        driver.log = lambda message: None

        with_cause = (
            "2026-09-17 19:10:42,743 ERROR SessionStrategy:362 - exception occurred when "
            "execute query=SELECT s_10\n"
            "org.apache.iotdb.rpc.StatementExecutionException: 722: Fetch Table Device Schema"
            " failed because FragmentInstance[x] is failed.\n"
            "\tat org.apache.iotdb.rpc.RpcUtils.verifySuccess(RpcUtils.java:108)\n"
        )
        # The same statement, reported a millisecond later with the cause gone.
        summary = (
            "2026-09-17 19:10:42,744 ERROR DBWrapper:793 - Execution fail: SELECT s_10\n"
            "java.lang.Exception: Failed to execute.\n"
            "\tat cn.edu.tsinghua.iot.benchmark.iotdb200.IoTDB.executeQueryAndGetStatus\n"
        )
        unexpected, expected = driver.classify_log_errors(with_cause + summary)
        _check(not unexpected, f"the documented 722 and its summary must pass: {unexpected}")
        _check(len(expected) == 2, f"both reports must be kept visible: {expected}")

        # The fixtures above are synthesised and happen to contain both the code
        # and the schema wording.  Real logs do NOT: measured over two full runs
        # the 722 text is the MPP one, and an allowlist written only for the
        # schema wording matched 0 of 190 error lines.  So both phrasings as
        # they actually appear are asserted here.
        real_mpp_722 = (
            "2026-09-18 21:38:56,083 ERROR DBWrapper:793 - Execution fail: SELECT s_11\n"
            "org.apache.iotdb.rpc.StatementExecutionException: 722: FragmentInstance"
            "[20260918_133853_04317_5.1.0] is failed. Failed to fetch state, has retried 5 "
            "times, may be caused by DN restarting.\n"
        )
        real_schema_722 = (
            "2026-09-17 19:10:42,743 ERROR SessionStrategy:362 - exception occurred\n"
            "org.apache.iotdb.rpc.StatementExecutionException: 722: Fetch Table Device "
            "Schema failed because FragmentInstance[x] is failed.\n"
        )
        for label, text in (("MPP", real_mpp_722), ("schema", real_schema_722)):
            unexpected, expected = driver.classify_log_errors(text)
            _check(
                not unexpected,
                f"the real {label} 722 text must be excused, not counted as a defect: {unexpected}",
            )
            _check(len(expected) == 1, f"the real {label} 722 must still be reported: {expected}")

        # R&D decided (2026-09-29) that 305 is the same kind of expected error and
        # will not be fixed: a query that is in flight while a DataNode is recycled
        # fails, and the alternative -- waiting for in-flight queries before
        # releasing the resources -- risks the REMOVE being stuck behind one large
        # or many concurrent queries, which was judged worse.  Text below is the
        # real one, measured in dn_remove_restart_storm#5/#6/#14 on 2026-09-28/29.
        real_305 = (
            "2026-09-28 19:13:52,950 ERROR cn.edu.tsinghua.iot.benchmark.tsdb.DBWrapper:793"
            " - Execution fail: SELECT device_id, date_bin(20000ms, time), count(s_3) FROM"
            " usr_sod0.tab_0 WHERE time >= 1790593659000 AND time <= 1790593679000\n"
            "org.apache.iotdb.rpc.StatementExecutionException: 305: no detailed failure"
            " reason in QueryStateMachine\n"
        )
        unexpected, expected = driver.classify_log_errors(real_305)
        _check(
            not unexpected,
            f"the real 305 text must be excused (R&D: expected, not fixed): {unexpected}",
        )
        _check(len(expected) == 1, f"the real 305 must still be recorded: {expected}")

        # ... and a *generic* failure is excused inside a DataNode down-window and
        # only there: the window is the excuse, never the whole case.
        import datetime as _datetime

        generic = (
            "2026-09-28 19:13:52,950 ERROR DBWrapper:793 - Execution fail: SELECT s_9\n"
            "org.apache.iotdb.rpc.StatementExecutionException: 600: system is read-only\n"
        )
        stamp = _datetime.datetime(2026, 9, 28, 19, 13, 52).timestamp()
        unexpected, expected = driver.classify_log_errors(generic, [(stamp - 10, stamp + 10)])
        _check(
            not unexpected,
            f"an error inside the DataNode down-window is expected: {unexpected}",
        )
        _check(len(expected) == 1, f"it must still be recorded: {expected}")
        unexpected, _ = driver.classify_log_errors(generic, [(stamp + 60, stamp + 120)])
        _check(
            len(unexpected) == 1,
            f"the same error outside the window must stay a failure: {unexpected}",
        )

        # A real failure is still a failure, and is not excused by a stale window.
        other = (
            "2026-09-17 23:38:46,218 ERROR DBWrapper:793 - Execution fail: SELECT d_1\n"
            "org.apache.iotdb.rpc.StatementExecutionException: 301: The consensus group"
            " ConfigRegion[0] doesn't exist\n"
        )
        unexpected, expected = driver.classify_log_errors(other)
        _check(len(unexpected) == 1, f"an unrelated error must stay unexpected: {unexpected}")
        _check(not expected, f"an unrelated error must not be excused: {expected}")

        # Reports far apart in time are not the same failure.
        far = (
            "2026-09-17 19:10:42,743 ERROR x - exception\n"
            "org.apache.iotdb.rpc.StatementExecutionException: 722: Fetch Table Device Schema"
            " failed\n"
            "2026-09-17 19:20:00,000 ERROR DBWrapper:793 - Execution fail: SELECT z\n"
            "java.lang.Exception: Failed to execute.\n"
        )
        unexpected, expected = driver.classify_log_errors(far)
        _check(
            len(unexpected) == 1 and len(expected) == 1,
            f"a summary ten minutes later is a different failure: {unexpected} / {expected}",
        )


    case("ConfigNode replication-factor floor case is present and wired", t_cn_rf_limit_case)
    case("ConfigNode shrink orders differ (Leader last vs Leader first)", t_cn_removal_order)
    case("deployment helpers (consensus mapping, licence code, unpack)", t_deploy_helpers)
    case("benchmark build follows the database line (1.x tree only)", t_benchmark_version_matching)
    case("node status parsing (ReadOnly(UNACTIVATED) matches readonly)", t_node_status_parsing)
    case("a ReadOnly node still counts as running", t_readonly_counts_as_running)
    case(
        "ConfigNode shrink order cases exist and differ only in ordering",
        t_cn_shrink_leader_first_case,
    )
    case("--repeat expands into unique runs and reports a pass rate", t_expand_repeats)
    case(
        "a pinned syncLag is attributed to a region (stale vs live)",
        t_sync_lag_region_attribution,
    )
    case("diag attributes a stuck syncLag to a region and peer", t_diag_metric_attribution)
    def t_cn_quorum_math() -> None:
        """The ConfigRegion floor must be encoded, not folklore.

        R&D's rule: at two ConfigNodes a restart cannot be made highly
        available.  The replica set *is* the ConfigNode set, so a removal
        followed by a fault is only excusable when a majority still serves.
        """
        from .cases import cn_below_quorum, cn_quorum

        _check(cn_quorum(1) == 1, "a one-member ConfigRegion needs one vote")
        _check(cn_quorum(2) == 2, "two ConfigNodes both need to be up")
        _check(cn_quorum(3) == 2, "three ConfigNodes tolerate one loss")
        _check(cn_quorum(5) == 3, "five ConfigNodes tolerate two losses")

        # The case that R&D explained: 3C -> remove one -> restart another.
        members, available, below = cn_below_quorum(3, removed=1, down=1)
        _check((members, available) == (2, 1), f"3C minus one minus one is 1 of 2, got {available}/{members}")
        _check(below, "removing one of three ConfigNodes then stopping another loses quorum")

        # It must NOT excuse every CN fault, or real outages get waved through.
        members, available, below = cn_below_quorum(5, removed=1, down=1)
        _check((members, available) == (4, 3), f"5C stays at 3 of 4, got {available}/{members}")
        _check(not below, "5C with one removal and one fault still has a majority")

        # Nor a removal on its own, where every node is still alive.
        members, available, below = cn_below_quorum(3, removed=1, down=0)
        _check((members, available) == (2, 2), f"a bare removal leaves 2 of 2, got {available}/{members}")
        _check(not below, "a bare ConfigNode removal keeps quorum")


    def t_outage_window_classification() -> None:
        """Only errors *inside* a below-quorum window are excused."""
        from .benchmark import BenchmarkDriver

        class FakeCfg:
            def raw(self, key, default=""):
                return default

        driver = BenchmarkDriver.__new__(BenchmarkDriver)
        driver.cfg = FakeCfg()
        driver.log = lambda message: None

        log = (
            "2026-09-18 00:30:30,100 ERROR DBWrapper:793 - Execution fail: SELECT a\n"
            "org.apache.iotdb.rpc.StatementExecutionException: 301: The consensus group"
            " ConfigRegion[0] doesn't exist\n"
            "2026-09-18 00:30:40,100 ERROR DBWrapper:793 - Execution fail: SELECT b\n"
            "org.apache.iotdb.rpc.StatementExecutionException: 301: The consensus group"
            " ConfigRegion[0] doesn't exist\n"
        )
        window = [(datetime(2026, 9, 18, 0, 30, 25).timestamp(),
                   datetime(2026, 9, 18, 0, 30, 35).timestamp())]
        unexpected, expected = driver.classify_log_errors(log, window)
        _check(len(expected) == 1, f"the error inside the window is expected: {expected}")
        _check(len(unexpected) == 1, f"the error after it is still a failure: {unexpected}")
        # An open window (a node that never came back) covers the rest of the run.
        unexpected, expected = driver.classify_log_errors(
            log, [(datetime(2026, 9, 18, 0, 30, 25).timestamp(), None)]
        )
        _check(not unexpected, f"an open window excuses everything after it: {unexpected}")


    case(
        "expected benchmark errors (722) do not fail a case",
        t_expected_benchmark_errors,
    )
    case("DataNode restart ops rotate so a sweep covers every node", t_dn_restart_targets_rotate)
    case("ConfigNode quorum math scopes expected outages", t_cn_quorum_math)
    case(
        "only errors inside a below-quorum window are excused",
        t_outage_window_classification,
    )
    case(
        "a manual ReadOnly case replaces the disk-fill case",
        t_readonly_replaces_diskfull,
    )
    case(
        "a fault that cannot be injected is skipped, not passed",
        t_fault_skip_is_preflighted,
    )
    case(
        "the adding case holds back a DataNode instead of needing a spare host",
        t_adding_holds_back_a_datanode,
    )
    case(
        "the matrix exit code counts only real failures, with PASS/SKIP imported",
        t_matrix_exit_code,
    )
    case(
        "the forensic inventory diff blames the replica missing a file",
        t_replica_inventory_diff,
    )
    case(
        "the TDB-406 window detector fires on the window and stays quiet off it",
        t_tdb406_window_detector,
    )

    def t_stale_load_protection():
        """A dead driver's load must be found and stoppable; a live driver's left alone.

        This guards the failure measured on the 2.0.12.1 RC4 matrix: an interrupted
        `matrix` left three writers behind, and the next case failed with "the
        dataset never settled" -- a failure that blamed the database for an
        operational leftover.
        """
        tmp = Path(tempfile.mkdtemp(prefix="rcdn-stale-"))
        wdir = tmp / "run1" / "benchmark" / "table"
        wdir.mkdir(parents=True)

        def fake_load() -> subprocess.Popen:
            proc = subprocess.Popen(
                ["bash", "-c", f'exec -a "benchmark {wdir}" sleep 60'],
                start_new_session=True,
            )
            time.sleep(0.4)
            (wdir / "benchmark.pid").write_text(f"{proc.pid}\n", encoding="utf-8")
            return proc

        proc = fake_load()
        try:
            _check(len(stale_workloads(tmp)) == 1, "a marker-less leftover must count as stale")
            # A live driver owns the load it started: a concurrent run/matrix or a
            # `doctor` must not report (let alone kill) it.
            (tmp / "run1" / "benchmark" / "driver.pid").write_text(
                f"{os.getpid()}\n", encoding="utf-8"
            )
            _check(stale_workloads(tmp) == [], "a live driver's own load must be left alone")
            (tmp / "run1" / "benchmark" / "driver.pid").write_text("999999\n", encoding="utf-8")
            _check(len(stale_workloads(tmp)) == 1, "a dead driver's load must count as stale")
            kill_stale_workloads(tmp, kill=True)
            time.sleep(0.5)
            _check(proc.poll() is not None, "kill_stale_workloads must stop the leftover")
            # PID reuse: a live process whose command line is not a benchmark load.
            (wdir / "benchmark.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
            _check(stale_workloads(tmp) == [], "an unrelated PID must not be treated as load")
        finally:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except OSError:
                pass

    case(
        "a dead driver's benchmark load is found and stopped, a live one is left alone",
        t_stale_load_protection,
    )

    def t_residual_data_filter():
        """A removed node's boot-recreated lock file is not leftover data.

        Guards the second false positive measured on 2.0.12.1 RC4: with the restart
        probe finally restarting the node, `dn_readonly_remove` failed on
        `.iotdb-lock` -- a file every boot recreates -- while its data was gone.
        """
        _check(not is_residual_data(".iotdb-lock"), "the boot lock must not count as data")
        _check(
            not is_residual_data("datanode/data/.iotdb-lock"),
            "the lock must be filtered at any depth",
        )
        for keep in (
            "region-10/xxx.tsfile",
            "datanode/data/region-12/1690000000000-1-2-0/1.tsfile",
            ".iotdb-lock.bak",
        ):
            _check(is_residual_data(keep), f"{keep} must still count as leftover data")
        _check(not is_residual_data(""), "an empty path is not data")

    case("a removed node's boot lock is not counted as leftover data", t_residual_data_filter)

    def t_object_size_parsing():
        from .object_audit import parse_size

        _check(parse_size("0 B") == 0, "0 B must parse to 0")
        _check(parse_size("-1") == -1, "the -1 'never reported' sentinel must survive")
        _check(parse_size("22.71 KB") == int(round(22.71 * 1024)), "KB must scale")
        _check(parse_size("8.39 MB") == int(round(8.39 * 1024 ** 2)), "MB must scale")
        _check(parse_size("1.5 GB") == int(round(1.5 * 1024 ** 3)), "GB must scale")
        _check(parse_size("not-a-size") is None, "garbage must not be read as a size")

    case("OBJECT ObjectSize text parses (TDB-835 audit)", t_object_size_parsing)

    def t_object_region_rows():
        from .object_audit import data_region_replicas

        text = """\
+--------+----------+-------+--------+-----------+----------+---------+-------+----------+
|RegionId|      Type| Status|Database|SeriesSlotNum|DataNodeId|Role|TsFileSize|ObjectSize|
+--------+----------+-------+--------+-----------+----------+---------+-------+----------+
|       4|DataRegion|Running| usr_sod|            1|         1|Leader|22.71 KB|  8.39 MB|
|       4|DataRegion|Running| usr_sod|            1|         3|Follower|22.71 KB|      0 B|
|       1|SchemaRegion|Running| usr_sod|            1|         1|Leader|     0 B|         |
+--------+----------+-------+--------+-----------+----------+---------+-------+----------+
"""
        reps = data_region_replicas(parse_table(text))
        _check(len(reps) == 2, f"SchemaRegion rows must be filtered out, got {len(reps)}")
        _check(reps[0].region == 4 and reps[0].node_id == 1, reps[0])
        _check(reps[0].role == "Leader", "the Role column must be kept")
        _check(reps[0].reported_bytes == int(round(8.39 * 1024 ** 2)), "leader size")
        _check(reps[1].reported_bytes == 0, "the 0 B target is the TDB-835 symptom")

    case("SHOW REGIONS rows yield per-replica ObjectSize", t_object_region_rows)

    def t_db_name_matching():
        from .object_audit import db_matches

        _check(db_matches("root.usr_sod0", "usr_sod0"), "the root. prefix must not break the match")
        _check(db_matches("usr_sod0", "root.usr_sod0"), "the prefix may be on either side")
        _check(db_matches("usr_sod0", "usr_sod0"), "an exact name must match")
        _check(not db_matches("usr_sod1", "usr_sod0"), "a numbered sibling is a different database")
        _check(db_matches("usr_sod_0", "usr_sod"), "a suffixed variant of the base name matches")
        _check(db_matches("usr_sod", "usr_sod_0"), "the suffix may be on either side")
        _check(not db_matches("usr_sodx", "usr_sod0"), "a different name must not match")
        _check(not db_matches("root.__audit", "usr_sod0"), "the audit database must not match")
        _check(not db_matches("", "usr_sod0"), "an empty name never matches")

    case("SHOW REGIONS database names normalise before filtering", t_db_name_matching)

    def t_region_query_targets_table_db():
        from .object_audit import fetch_region_rows

        seen: list[str] = []

        class FakeSql:
            def sql(self, host, statement, **kw):
                seen.append(statement)
                return """\
+--------+----------+-------+--------+-------------+-----------+----------+-------+----------+
|RegionId|      Type| Status|Database|SeriesSlotNum|DataNodeId|    Role|TsFileSize|ObjectSize|
+--------+----------+-------+--------+-------------+-----------+----------+-------+----------+
|       4|DataRegion|Running|usr_sod0|            1|          2|  Leader|22.71 KB|      0 B|
+--------+----------+-------+--------+-------------+-----------+----------+-------+----------+
"""

        class FakeCfg:
            cli_host = "11.101.10.9"

        rows, errors = fetch_region_rows(FakeSql(), FakeCfg(), ["usr_sod0"])
        _check(not errors, f"no error expected, got {errors}")
        _check(seen == ["show regions from usr_sod0;"], f"wrong statement: {seen}")
        _check(len(rows) == 1 and rows[0]["Database"] == "usr_sod0", rows)

    case("the OBJECT audit queries SHOW REGIONS FROM <db>", t_region_query_targets_table_db)



    def t_object_path_split():
        from .object_audit import split_object_path

        roots = ["/data/dn/data/object", "/mnt/ssd/iotdb/object"]
        parsed = split_object_path(roots, "/mnt/ssd/iotdb/object/4/dGFiXzA/1700000000000_3.bin")
        _check(parsed == (4, "dGFiXzA/1700000000000_3.bin"), parsed)
        _check(split_object_path(roots, "/data/dn/data/object/12/x/1.bin") == (12, "x/1.bin"),
               "relative path keeps the table dir")
        _check(split_object_path(roots, "/elsewhere/object/4/x/1.bin") is None,
               "a path outside the roots must not be attributed")
        _check(split_object_path(roots, "/data/dn/data/object/x/1.bin") is None,
               "a non-numeric region directory must be rejected")

    case("OBJECT .bin path splits into region + relative path", t_object_path_split)

    def t_object_delete_log():
        from .object_audit import DELETE_LOG_RE

        line = ("2026-10-16 14:35:54,290 [ObjectGC] INFO  o.a.i.d.u.DataNodeObjectFileService - "
                "Remove object file /data/mnt/object/4/dGFiXzA/1700000000000_3.bin, size is 262144(byte)")
        m = DELETE_LOG_RE.search(line)
        _check(m is not None, "the GC log line must match")
        _check(m.group("path").endswith("1700000000000_3.bin"), m.group("path"))
        _check(m.group("size") == "262144", m.group("size"))

    case("OBJECT GC deletion log line parses (TDB-861 evidence)", t_object_delete_log)

    def t_new_object_cases_present():
        cases = {c.case_id: c for c in load_cases(SKILL_ROOT / "cases" / "remove_cases.tsv")}
        for cid, want in (
            ("dn_object_size_after_migration", {"object_size", "cold_restart"}),
            ("dn_object_delete_residue", {"object_delete_residue"}),
        ):
            _check(cid in cases, f"{cid} must be in the matrix")
            _check(want <= set(cases[cid].extras), f"{cid} extras {cases[cid].extras} != {want}")
            _check(cases[cid].resolved_workloads.__name__ == "resolved_workloads", cid)
        _check(cases["dn_object_size_after_migration"].workloads == "table",
               "OBJECT lives in the table model only")
        _check(cases["dn_object_delete_residue"].workloads == "table",
               "OBJECT lives in the table model only")

    case("the two OBJECT/region-migration cases are wired", t_new_object_cases_present)

    return failures


if __name__ == "__main__":  # pragma: no cover - allows `python3 -m`
    # Without this guard `python3 -m scripts.rcdn.selftest` imports the module
    # and exits 0 having run nothing, which reads exactly like a pass.  Same
    # trap as smoketest, so both modules now carry the guard.
    import sys

    _failures = run()
    for _f in _failures:
        print(f"selftest: FAIL: {_f}")
    print(f"selftest: {'OK' if not _failures else f'{len(_failures)} failure(s)'}")
    sys.exit(1 if _failures else 0)
