"""Post-remove verification: sync-lag drain, replica consistency, log scan, backup."""

from __future__ import annotations

import json
import re
import shlex
import time
from dataclasses import dataclass, field
from pathlib import Path

from .cluster import ROLE_CN, ROLE_DN, Cluster, status_is
from .config import Config
from .remote import (
    SqlClient,
    SshRunner,
    http_get_json,
    http_get_text,
    looks_like_sql_error,
    parse_table,
    wait_until,
)

# Unexpected conditions that always indicate a bug, taken from the reference
# suite (MigrateRegionTest/testcase/tc300_*.sh, check_log()).
DEFAULT_LOG_PATTERNS = (
    r"NullPointer",
    r"BufferUnderflowException",
    r"but return HAS_MORE_STATE",
    r"CompactionTableSchemaNotMatchException",
    r"has overlapped data",
    r"which should be later than the last time",
    r"DataTypeInconsistentException",
    r"ArrayIndexOutOfBoundsException",
    r"Alter timeseries .* data type from null to",
    r"StatisticsClassException",
    r"NegativeArraySizeException",
    r"is not in tsFileMetaData",
    r"The memory cost to be released is larger",
    r"tsfile error",
    r"which has not released all memory",
    r"Error while reading timeseries metadata",
    r"IndexOutOfBoundsException",
    r"ConcurrentModificationException",
    r"InternalServerErrorException",
    r"the region .* is not in the cluster",
)

# Signatures of the *query-failure* family seen while a DataNode leaves the
# cluster.  They are deliberately kept apart from ``DEFAULT_LOG_PATTERNS``:
# that tuple feeds ``check_logs()``, whose hits become case *problems*, while
# these lines are expected during a removal and must be recorded, not judged.
#
# Why a snapshot is needed at all: the harness resets every node's log at the
# next case's ``prepare`` (measured: reset 21:08:40, previous ``result.json``
# 21:08:49), so any scan started after a case ends -- including a PASS case's
# post-hoc sweep -- returns zero and the evidence is gone.  ``LOG_BACKUP=always``
# keeps whole logs, but a cheap in-run grep is enough for the 305 family.
QUERY_FAILURE_PATTERNS = (
    r"Status code: 305",
    r"no detailed failure reason in QueryStateMachine",
    r"INTERNAL_SERVER_ERROR\(305\)",
    r"fetchMissingDeviceSchemaForQuery",
    r"TableDeviceSchemaFetcher",
    r"Fail to fetch device schema",
    r"can't connect to node",
    r"can't execute request on node",
    r"\[ReachMaxRetryCount\]",
    r"retry count is",
    r"system is read-only",
    r"dispatch write failed",
    r"Interrupted when dispatching",
)

HEADER_CELLS = {
    "time",
    "d_datetime",
    "device_id",
    "device",
    "database",
    "tablename",
    "count",
    "regionid",
}


def empty_capture(raw: str) -> bool:
    """True when the SQL client produced no output at all.

    A query that merely has no matching rows still prints a header block and
    (on the IoTDB CLI) ``Empty set.`` -- see the ``EMPTY_SET`` fixture in the
    self-test.  A completely empty capture therefore means the client never
    ran (connection refused, timeout, node still starting).  Such a capture
    must be reported as a failed capture: comparing it with the baseline
    manufactures a replica inconsistency that does not exist, which is exactly
    what happened with a `remove dn` + restart run on 2026-09-22 (an empty
    `stop_..._table_view.raw` was reported as "replica inconsistency while
    11.101.10.8 is down").
    """
    return not raw.strip()


def normalize_query_result(text: str) -> str:
    """Canonical, order-independent form of an IoTDB CLI result."""
    rows = parse_table(text)
    lines: list[str] = []
    for row in rows:
        values = [v.strip() for v in row.values()]
        if not values or values[0].lower() in HEADER_CELLS:
            continue
        rendered = "|".join("" if v.lower() == "null" else v for v in values)
        if rendered.strip("|"):
            lines.append(rendered)
    lines.sort()
    return "\n".join(lines) + ("\n" if lines else "")


def compare_replica_inventories(
    inventories: dict[str, dict[str, set[str]]],
) -> list[tuple[str, str, list[str], list[str]]]:
    """Find files that some replica of a path holds and others do not.

    Returns ``(path, file, holders, absent)`` for every file that is missing
    from at least one replica **of a path that more than one replica knows
    about**.  Two restrictions keep this honest:

    * a path known to a single replica is that replica's own compaction
      state, not a disagreement, so it is skipped;
    * a file present everywhere is skipped, and so is a file present nowhere.

    A file that is present on some replicas and absent on others is the
    signature to look for: it is what a snapshot that silently skipped an
    unclosed TsFile leaves behind.  Note that independent compaction can also
    produce these, in both directions, so the result is evidence to read
    rather than a verdict.
    """
    holders: dict[tuple[str, str], set[str]] = {}
    for host, inv in inventories.items():
        for path, names in inv.items():
            for name in names:
                holders.setdefault((path, name), set()).add(host)

    known_by: dict[str, set[str]] = {}
    for (path, _), hosts in holders.items():
        known_by.setdefault(path, set()).update(hosts)

    out: list[tuple[str, str, list[str], list[str]]] = []
    for (path, name), hosts in sorted(holders.items()):
        expected = known_by[path]
        if len(expected) < 2 or hosts == expected:
            continue
        out.append((path, name, sorted(hosts), sorted(expected - hosts)))
    return out


@dataclass
class SyncLagResult:
    ok: bool
    reason: str = ""
    samples: list[dict[str, float]] = field(default_factory=list)


class SyncLagWaiter:
    """Poll Prometheus until every Running DataNode reports syncLag ~ 0."""

    METRIC_CANDIDATES = (
        ("iot_consensus", "ioTConsensusServerImpl"),
        ("iot_consensus_v2", "IoTConsensusV2ServerImpl"),
    )

    def __init__(self, cfg: Config, cluster: Cluster, log, health=None):
        self.cfg = cfg
        self.cluster = cluster
        self.log = log
        # Optional callable returning the hosts that cannot possibly catch up
        # (a DataNode left ReadOnly or dead).  Without it the gate waits out
        # SYNC_MAX_WAIT_SEC - an hour by default - for a lag that can never
        # drain, because a ReadOnly node stops advancing its sync position.
        self.health = health
        self.url = cfg.raw("MONITOR_URL").rstrip("/")
        self.mode = cfg.raw("SYNC_LAG_SOURCE", "auto").strip().lower()
        # 0 (the default) means "ask the DataNode what port it exports on".
        self.metrics_port = cluster.dn_metrics_port()

    def _use_prometheus(self) -> bool:
        if self.mode == "prometheus":
            return True
        if self.mode == "metrics":
            return False
        return bool(self.url)

    def available(self) -> bool:
        if self.mode == "metrics":
            return self.metrics_port > 0
        return bool(self.url) or (self.mode == "auto" and self.metrics_port > 0)


    # -- source 1: Prometheus ------------------------------------------
    def _query_prometheus(self, metric: str, server: str, regex: str) -> list[float]:
        expr = (
            f'sum({metric}{{instance=~"{regex}",name="{server}",type="syncLag"}}) by (instance)'
        )
        import urllib.parse

        url = f"{self.url}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
        payload = http_get_json(
            url, user=self.cfg.get("MONITOR_USER"), password=self.cfg.get("MONITOR_PASSWORD")
        )
        if payload.get("status") != "success":
            raise RuntimeError(f"prometheus query failed: {payload.get('error')}")
        values: list[float] = []
        for series in payload.get("data", {}).get("result", []):
            raw = series.get("value", [None, "0"])[1]
            try:
                values.append(float(raw))
            except (TypeError, ValueError):
                continue
        return values

    @staticmethod
    def stalled_polls(prev_value: float | None, prev_count: int, worst: float) -> int:
        """How many polls in a row have reported this same non-zero value.

        A lag that holds still is not converging; only a *changing* value means
        the node is still making progress.  Pure so the counting can be tested
        without a cluster.
        """
        if prev_value is not None and worst == prev_value:
            return prev_count + 1
        return 1

    # -- source 2: each DataNode's own /metrics exporter ---------------
    @staticmethod
    def parse_sync_lag_metrics_labeled(
        text: str, metric: str, server: str
    ) -> list[tuple[str, float]]:
        """Like parse_sync_lag_metrics but keeps each sample's region label.

        The aggregate `worst` alone cannot tell a live stalled pipeline apart
        from a stale gauge left behind by a removed replica, and those need
        opposite responses.  Carrying the region makes the verdict actionable.
        """
        out: list[tuple[str, float]] = []
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, _, rest = line.partition("{")
            if name.strip() != metric:
                continue
            labels, _, tail = rest.rpartition("}")
            if not tail.strip():
                continue
            if f'name="{server}"' not in labels or 'type="syncLag"' not in labels:
                continue
            raw = tail.strip().split()[0] if tail.strip() else ""
            try:
                value = float(raw)
            except ValueError:
                continue
            found = re.search(r'region="([^"]+)"', labels)
            out.append((found.group(1) if found else "?", value))
        return out

    @staticmethod
    def parse_sync_lag_metrics(text: str, metric: str, server: str) -> list[float]:
        return [
            value
            for _, value in SyncLagWaiter.parse_sync_lag_metrics_labeled(text, metric, server)
        ]

    def _query_metrics_labeled(self, host: str, metric: str, server: str) -> list[tuple[str, float]]:
        url = f"http://{host}:{self.metrics_port}/metrics"
        text = http_get_text(url, timeout=20)
        return self.parse_sync_lag_metrics_labeled(text, metric, server)

    def _query_metrics(self, host: str, metric: str, server: str) -> list[float]:
        url = f"http://{host}:{self.metrics_port}/metrics"
        text = http_get_text(url, timeout=20)
        return self.parse_sync_lag_metrics(text, metric, server)

    def _query(self, host: str, metric: str, server: str, regex: str) -> list[float]:
        if self._use_prometheus():
            return self._query_prometheus(metric, server, regex)
        return self._query_metrics(host, metric, server)


    def _live_region_names(self) -> set[str] | None:
        """Region names from `show regions`, e.g. {"DataRegion[7]"}; None if unavailable."""
        try:
            out = self.cluster.sql.sql(self.cfg.cli_host, "show regions", check=False)
        except Exception:  # noqa: BLE001 - a hint must never break the gate
            return None
        names: set[str] = set()
        for line in out.splitlines():
            fields = [x.strip() for x in line.split("|") if x.strip()]
            if len(fields) > 2 and fields[1] in {"DataRegion", "SchemaRegion"}:
                names.add(f"{fields[1]}[{fields[0]}]")
        return names or None

    def _stale_region_hint(self, top: list[tuple[str, str, float]]) -> str:
        """Say so when the pinned regions no longer exist.

        A DataNode removal can leave a full IoTConsensus request queue and a
        frozen syncLag gauge behind for a region that has already been dropped,
        which is a stale metric rather than a live stalled pipeline.  Without
        this hint the two look identical and the wrong one gets investigated.
        """
        regions = {r for _, r, _ in top if r and r != "?"}
        if not regions:
            return ""
        live = self._live_region_names()
        if live is None:
            return ""
        missing = sorted(r for r in regions if r not in live)
        if not missing:
            return ""
        return (
            f" -- {', '.join(missing)} no longer appears in `show regions`, so this is a stale "
            "per-region metric left behind by a removed replica, not a live stalled pipeline"
        )

    def wait(self) -> SyncLagResult:
        if not self.available():
            return SyncLagResult(
                ok=False,
                reason=(
                    "neither MONITOR_URL nor METRICS_PORT is configured; sync-lag gate skipped"
                ),
            )

        stable = self.cfg.get_int("SYNC_STABLE_SECONDS")
        max_wait = self.cfg.get_int("SYNC_MAX_WAIT_SEC")
        poll = self.cfg.get_int("SYNC_POLL_INTERVAL_SEC")
        metric_pref = self.cfg.raw("CONSENSUS_METRIC", "auto")
        if metric_pref in {"iot_consensus", "iot_consensus_v2"}:
            candidates = [c for c in self.METRIC_CANDIDATES if c[0] == metric_pref]
        else:
            candidates = list(self.METRIC_CANDIDATES)

        deadline = time.time() + max_wait
        zero_since: float | None = None
        active: tuple[str, str] | None = None
        last_samples: list[float] = []
        # A lag that never moves is a stall, not slow convergence -- waiting only
        # burns the rest of SYNC_MAX_WAIT_SEC.  Seen for real: a ReadOnly node
        # pinned "worst=60465.0" across every poll for minutes on end.
        stall_polls = self.cfg.get_int("SYNC_STALL_POLLS")
        frozen_value: float | None = None
        frozen_count = 0

        next_health_check = 0.0
        while True:
            running = self.cluster.running_dn_hosts()
            if not running:
                return SyncLagResult(ok=False, reason="no Running DataNode to read syncLag from")

            # Fail fast on a node that is not Running: it is excluded from the
            # syncLag series above, so waiting for the gate to reach 0 would
            # just burn the full timeout on a condition that cannot clear.
            if self.health and time.time() >= next_health_check:
                next_health_check = time.time() + 30
                bad = self.health()
                if bad:
                    return SyncLagResult(
                        ok=False,
                        reason="syncLag cannot drain: "
                        + "; ".join(bad)
                        + " (waiting further would only time out)",
                    )
            regex = "^(" + "|".join(ip.replace(".", "[.]") + "(:[0-9]+)?" for ip in running) + ")$"

            values: list[float] = []
            labeled: list[tuple[str, str, float]] = []
            errors: list[str] = []
            for metric, server in (([active] if active else candidates)):
                try:
                    if self._use_prometheus():
                        values = self._query_prometheus(metric, server, regex)
                    else:
                        # One sample set per node, summed locally.
                        for host in running:
                            pairs = self._query_metrics_labeled(host, metric, server)
                            labeled.extend((host, region, value) for region, value in pairs)
                            values.extend(value for _, value in pairs)
                    if values:
                        active = (metric, server)
                        break
                except Exception as exc:  # noqa: BLE001
                    errors.append(f"{metric}: {exc}")
            last_samples = values

            if not values:
                zero_since = None
                self.log(f"  sync lag: no series yet ({'; '.join(errors[:1]) or 'empty result'})")
            else:
                worst = max(values)
                self.log(f"  sync lag: instances={len(values)} worst={worst}")

                if stall_polls > 0 and worst > 1e-4:
                    frozen_count = self.stalled_polls(frozen_value, frozen_count, worst)
                    frozen_value = worst
                    if frozen_count >= stall_polls:
                        top = sorted(labeled, key=lambda x: x[2], reverse=True)[:3]
                        where = ", ".join(f"{r} on {h}={v:.0f}" for h, r, v in top) or "unknown"
                        stale = self._stale_region_hint(top)
                        if stale:
                            # Removing a DispatcherThread does not unbind its meters
                            # (confirmed upstream), so a region that no longer exists keeps
                            # exporting its last gauge.  Nothing is replicating badly, so
                            # this must not fail the case -- record it and stop waiting.
                            note = (
                                f"syncLag pinned at {worst} for {where}{stale}; not a "
                                "data-correctness failure, so the gate stopped waiting"
                            )
                            self.log(f"  sync lag: {note}")
                            return SyncLagResult(ok=True, reason=note)
                        return SyncLagResult(
                            ok=False,
                            reason=(
                                f"syncLag is pinned at {worst} across {frozen_count} polls "
                                f"(~{frozen_count * poll}s); worst: {where}"
                                + "; it is not converging, so waiting out the remaining "
                                f"{max_wait}s cannot help"
                            ),
                        )
                else:
                    frozen_value, frozen_count = None, 0

                if worst > 1e-4:
                    zero_since = None
                elif zero_since is None:
                    zero_since = time.time()
                elif time.time() - zero_since >= stable:
                    return SyncLagResult(ok=True, samples=[{"value": v} for v in values])

            if time.time() > deadline:
                return SyncLagResult(
                    ok=False,
                    reason=f"syncLag did not stay at 0 for {stable}s within {max_wait}s "
                    f"(last samples: {last_samples[:8]})",
                )
            time.sleep(poll)


class Verifier:
    """Replica consistency, log scanning and log backup."""

    def __init__(
        self,
        cfg: Config,
        cluster: Cluster,
        ssh: SshRunner,
        sql: SqlClient,
        log,
        artifacts: Path,
    ):
        self.cfg = cfg
        self.cluster = cluster
        self.ssh = ssh
        self.sql = sql
        self.log = log
        self.artifacts = artifacts
        self.artifacts.mkdir(parents=True, exist_ok=True)
        self.problems: list[str] = []
        # The all-online baseline, kept so the forensic capture can say which
        # node's view of a disagreeing query is the short one.
        self._baseline: dict[str, str] = {}

    def _baseline_for(self, name: str) -> str | None:
        return self._baseline.get(name)

    # ------------------------------------------------------------------
    # Query construction
    # ------------------------------------------------------------------
    def build_queries(self, run) -> dict[str, dict[str, str]]:
        import re as _re

        sensor_n = self.cfg.get_int("BM_SENSOR_NUMBER")
        scalar = [c for c in run.columns if c not in run.object_columns]
        if not scalar:
            scalar = [f"s_{i}" for i in range(sensor_n)]
        queries: dict[str, dict[str, str]] = {}

        if run.tree_db:
            # The tree model has no d_datetime/device_id columns: those are
            # table-model fields discovered by describe-ing the base table, and
            # `count(device_id)` is not valid tree SQL.  Use the measurement
            # names only, and do not re-prefix `root.` (tree_db already starts
            # with it).
            tree_cols = [c for c in scalar if _re.fullmatch(r"s_\d+", c)]
            if not tree_cols:
                tree_cols = [f"s_{i}" for i in range(sensor_n)]
            counts = ",".join(f"count({c})" for c in tree_cols)
            queries["tree"] = {
                "dialect": "tree",
                "sql": f"select {counts} from {run.tree_db}.** align by device;",
            }
        table_cols = [c for c in scalar if c != run.device_column]
        if run.table_db and run.base_table:
            counts = ",".join(f"count({c})" for c in table_cols)
            queries["table"] = {
                "dialect": "table",
                "sql": (
                    f"select {run.device_column},{counts} from {run.table_db}.{run.base_table} "
                    f"group by {run.device_column} order by {run.device_column};"
                ),
            }
        if run.table_db and run.view_table:
            counts = ",".join(f"count({c})" for c in table_cols)
            queries["table_view"] = {
                "dialect": "table",
                "sql": (
                    f"select {run.device_column},{counts} from {run.table_db}.{run.view_table} "
                    f"group by {run.device_column} order by {run.device_column};"
                ),
            }
        for label, table in (("object", run.base_table), ("object_view", run.view_table)):
            if not run.table_db or not table or not run.object_columns:
                continue
            col = run.object_columns[0]
            tcol, dcol = run.time_column, run.device_column
            queries[label] = {
                "dialect": "table",
                "sql": (
                    f"select {tcol},{dcol},length(read_object({col})),"
                    f"sha256(cast(read_object({col}) as string)) "
                    f"from {run.table_db}.{table} order by {tcol},{dcol} limit 50;"
                ),
                "fallback_sql": (
                    f"select {tcol},{dcol},length(read_object({col})) "
                    f"from {run.table_db}.{table} order by {tcol},{dcol} limit 50;"
                ),
            }
        return queries

    # ------------------------------------------------------------------
    # Forensic capture of per-replica file inventories
    # ------------------------------------------------------------------
    def tsfile_inventory(self, host: str) -> dict[str, set[str]]:
        """Map ``<kind>/<db>/<region>/2959`` -> file names on one DataNode.

        Reads the filesystem, not the product's view, so it works on a node
        whose process is stopped -- which is exactly the state during the
        sweep.  Region identity lives in the directory path, so the inventory
        keys are directly comparable across replicas.
        """
        script = f"""
d={shlex.quote(self.cfg.get('DB_DIR'))}
base="$d/data/datanode/data"
[[ -d "$base" ]] || exit 0
cd "$base" || exit 0
find sequence unsequence object -type f 2>/dev/null | sort
exit 0
"""
        res = self.ssh.run_script(host, script, check=False)
        out: dict[str, set[str]] = {}
        for line in res.out.splitlines():
            line = line.strip()
            if not line or "/" not in line:
                continue
            key, _, name = line.rpartition("/")
            out.setdefault(key, set()).add(name)
        return out

    def forensic_replica_files(
        self,
        label: str,
        *,
        diff_query: tuple[str, dict[str, str]] | None = None,
        running: list[str] | None = None,
        down: str | None = None,
    ) -> Path:
        """Freeze every replica's file inventory the moment a diff is found.

        A query-level diff says *that* two replicas disagree.  It cannot say
        *why*, and the interesting why -- a TsFile that one replica never
        received -- is visible in one place only: the file lists.  This dumps
        them, plus `show regions`, and cross-compares them so a file that is
        absent on one replica while its peers hold it is called out.

        It also re-runs the query that disagreed through **every** DataNode that
        is still up, so the artifact says which node's view is the short one
        rather than leaving that to be inferred from the sweep order.

        Purely forensic: it is written next to the other artifacts and never
        asserted on.  Replicas legitimately hold different file sets because
        each one compacts on its own schedule, so a difference is evidence to
        read, not a verdict.
        """
        self.log(f"  capturing per-replica file inventories -> forensic_{label}_*")
        regions = self.sql.sql(self.cfg.cli_host, "show regions", check=False)
        (self.artifacts / f"forensic_{label}_show_regions.txt").write_text(
            regions, encoding="utf-8"
        )

        # Read the DataNode list from `show datanodes`, the same source
        # ClusterStatus itself is built from.  It must include nodes whose
        # process is stopped, because their filesystem is still readable and
        # that is exactly when the inventory is worth taking.
        dn_table = parse_table(
            self.sql.sql(self.cfg.cli_host, "show datanodes", check=False)
        )
        hosts = sorted({r.get("RpcAddress", "").split(":")[0] for r in dn_table})
        hosts = [h for h in hosts if h]
        inventories: dict[str, dict[str, set[str]]] = {}
        rows: list[str] = []
        for host in hosts:
            inv = self.tsfile_inventory(host)
            inventories[host] = inv
            for key in sorted(inv):
                for name in sorted(inv[key]):
                    rows.append(f"{host}\t{key}\t{name}")
        (self.artifacts / f"forensic_{label}_files.tsv").write_text(
            "host\tpath\tfile\n" + "\n".join(rows) + ("\n" if rows else ""),
            encoding="utf-8",
        )

        # Compare TsFiles and their .resource sidecars.  Those are the files
        # whose omission loses rows silently, and they are stable once written.
        # Object (.bin) files are written continuously and reclaimed by the
        # object-deletion service on its own schedule, so a per-file comparison
        # of them is mostly noise; their count is reported separately instead.
        data_inventories = {
            host: {
                path: {n for n in names if n.endswith(".tsfile") or n.endswith(".resource")}
                for path, names in inv.items()
            }
            for host, inv in inventories.items()
        }
        diffs = compare_replica_inventories(data_inventories)
        missing = [
            f"{path}\n"
            f"    {name}\n"
            f"      present on: {', '.join(holders)}\n"
            f"      MISSING on: {', '.join(absent)}"
            for path, name, holders, absent in diffs
        ]
        object_diffs = len(compare_replica_inventories(
            {
                host: {
                    path: {n for n in names if n.endswith(".bin")}
                    for path, names in inv.items()
                }
                for host, inv in inventories.items()
            }
        ))
        text = [
            f"per-replica file inventory captured when a diff was found ({label})",
            f"DataNodes: {', '.join(hosts)}",
            "",
            "TsFile/.resource files present on some replicas of a path but not on others.",
            "A missing .tsfile here is the signature of a snapshot that omitted",
            "it, which is what makes a replica read back fewer rows than its",
            "peers even though syncLag is 0.  Differences in both directions are",
            "normal after independent compactions; a file that only ever goes",
            "*missing* relative to the other replicas is the interesting one.",
            "",
        ]
        text.extend(missing or ["none: every shared path holds the same TsFiles on every replica"])
        text.append("")
        text.append(
            f"object (.bin) files differing across replicas: {object_diffs} "
            "(expected to be non-zero: they are written continuously and reclaimed "
            "asynchronously, so this is a magnitude, not a finding)"
        )
        if diff_query is not None:
            name, spec = diff_query
            text.append("")
            text.append(f"the query that disagreed ('{name}'), re-run through each node still up:")
            for h in running or []:
                if h == down:
                    continue
                timeout = self.cfg.get_int("CONSISTENCY_QUERY_TIMEOUT_SEC")
                raw = self.sql.sql(
                    h,
                    spec["sql"],
                    dialect=spec.get("dialect"),
                    timeout=timeout,
                    check=False,
                )
                if looks_like_sql_error(raw) and spec.get("fallback_sql"):
                    raw = self.sql.sql(
                        h,
                        spec["fallback_sql"],
                        dialect=spec.get("dialect"),
                        timeout=timeout,
                        check=False,
                    )
                (self.artifacts / f"forensic_{label}_{name}_via_{h.replace('.', '_')}.raw").write_text(
                    raw, encoding="utf-8"
                )
                if looks_like_sql_error(raw):
                    verdict = "the query FAILED on this node (not a data disagreement)"
                elif normalize_query_result(raw) == self._baseline_for(name):
                    verdict = "same as the all-online baseline"
                else:
                    verdict = "DIFFERENT from the all-online baseline"
                text.append(f"  via {h}: {verdict}")

        out = self.artifacts / f"forensic_{label}_missing_files.txt"
        out.write_text("\n".join(text) + "\n", encoding="utf-8")
        if missing:
            self.log(
                f"  forensic: {len(missing)} file(s) present on some replicas but not others "
                f"-- see {out.name}"
            )
        else:
            self.log("  forensic: every shared path holds the same files on every replica")
        return out

    def _capture(self, host: str, name: str, spec: dict[str, str]) -> str | None:
        sql = spec["sql"]
        timeout = self.cfg.get_int("CONSISTENCY_QUERY_TIMEOUT_SEC")
        raw = self.sql.sql(host, sql, dialect=spec.get("dialect"), timeout=timeout, check=False)
        if not raw.strip():
            # A capture that came back completely empty means the client never
            # ran (connection reset, node in restart).  It is worth one retry
            # before it is reported: measured 2026-10-24, the baseline capture on
            # 11.101.10.9 came back empty once and succeeded on the next attempt
            # seconds later, and the single miss failed an otherwise clean case.
            self.log(f"  {name}: empty capture on {host}, retrying once")
            time.sleep(5)
            raw = self.sql.sql(
                host, sql, dialect=spec.get("dialect"), timeout=timeout, check=False
            )
        if looks_like_sql_error(raw) and spec.get("fallback_sql"):
            raw = self.sql.sql(
                host, spec["fallback_sql"], dialect=spec.get("dialect"), timeout=timeout, check=False
            )
        (self.artifacts / f"{name}.raw").write_text(raw, encoding="utf-8")
        if looks_like_sql_error(raw):
            self.problems.append(f"{name}: query failed on {host}")
            self.log(f"  {name}: query failed on {host}")
            return None
        if empty_capture(raw):
            self.problems.append(
                f"{name}: query produced no output on {host} (failed capture, not a "
                "replica difference)"
            )
            self.log(f"  {name}: EMPTY capture on {host} -- failed capture, not a difference")
            return None
        normalized = normalize_query_result(raw)
        (self.artifacts / f"{name}.norm").write_text(normalized, encoding="utf-8")
        return normalized

    # ------------------------------------------------------------------
    # Consistency sweep
    # ------------------------------------------------------------------
    def consistency_check(
        self,
        run,
        *,
        sync_waiter: SyncLagWaiter | None = None,
        data_rf: int = 0,
    ) -> list[str]:
        queries = self.build_queries(run)
        if not queries:
            self.problems.append("no query could be built for the consistency check")
            return self.problems

        running = self.cluster.running_dn_hosts()
        if len(running) < 2:
            self.problems.append(f"only {len(running)} Running DataNode(s); cannot stop one and still query")
            return self.problems

        if sync_waiter is not None and sync_waiter.available():
            result = sync_waiter.wait()
            if not result.ok:
                self.problems.append(f"sync-lag gate before baseline: {result.reason}")
                return self.problems

        # Only a settled dataset may be used as the reference.  After a DataNode
        # removal the visible data keeps converging for minutes even though SHOW
        # MIGRATIONS is empty and syncLag is zero -- a restarted node was seen
        # catching up a backlog of ~2000 long after both gates passed.  Comparing
        # a moving baseline against later captures manufactures replica
        # inconsistencies that do not exist, so the baseline is captured twice
        # and accepted only when the two agree.
        settle_seconds = self.cfg.get_int("CONSISTENCY_SETTLE_SECONDS")
        settle_tries = max(1, self.cfg.get_int("CONSISTENCY_SETTLE_TRIES"))
        self.log(
            f"  waiting for the dataset to settle "
            f"(two captures {settle_seconds}s apart must agree, <= {settle_tries} tries)"
        )
        baseline: dict[str, str] = {}
        settled = False
        for attempt in range(1, settle_tries + 1):
            first: dict[str, str] = {}
            for name, spec in queries.items():
                value = self._capture(self.cfg.cli_host, f"settle{attempt}_a_{name}", spec)
                if value is not None:
                    first[name] = value
            time.sleep(settle_seconds)
            second: dict[str, str] = {}
            for name, spec in queries.items():
                value = self._capture(self.cfg.cli_host, f"baseline_{name}", spec)
                if value is not None:
                    second[name] = value
            if first and first == second:
                baseline = second
                self._baseline = dict(second)
                settled = True
                if attempt > 1:
                    self.log(f"  dataset settled after {attempt} attempt(s)")
                break
            moving = sorted(k for k in first if first.get(k) != second.get(k))
            self.log(
                f"  dataset still moving (attempt {attempt}/{settle_tries}; "
                f"differs: {','.join(moving) or 'n/a'}); waiting"
            )

        if not settled:
            (self.artifacts / "consistency_never_settled.txt").write_text(
                f"the dataset was still changing after {settle_tries} attempts of "
                f"{settle_seconds}s; the sweep is skipped rather than reporting a "
                "moving dataset as a replica inconsistency\n",
                encoding="utf-8",
            )
            self.problems.append(
                "the dataset never settled after the removal, so the replica-consistency "
                "sweep was skipped instead of being reported as an inconsistency"
            )
            self.log("  refusing to sweep: a moving dataset is not a replica inconsistency")
            return self.problems
        self.log("  capturing the all-online baseline")

        if data_rf and data_rf < 2:
            # With a single replica there is no other copy to read: stopping any
            # node that owns a region necessarily makes that region unreadable.
            # The all-online baseline above is still meaningful, the sweep is not.
            (self.artifacts / "consistency_sweep_skipped.txt").write_text(
                f"stop-one-node sweep skipped: data_replication_factor={data_rf} "
                "leaves no second copy to query\n",
                encoding="utf-8",
            )
            self.log(
                f"  sweep skipped: data_replication_factor={data_rf} has no second replica to read"
            )
            return self.problems

        checked = 0
        forensic_done: set[str] = set()
        for host in running:
            query_host = self._alternate_query_host(host, running)
            if query_host is None:
                self.problems.append(f"no alternate query host left after stopping {host}")
                continue
            self.log(f"  consistency sweep: stopping DataNode {host} (querying through {query_host})")
            # The hard requirement is that the process actually goes away, and
            # stop_node already confirms that.  Whether the ConfigNode's view
            # has caught up depends on when the heartbeat expires, which is a
            # product-internal timer: waiting on it too strictly turns a slow
            # expiry into a bogus failure, so it is bounded and advisory.
            if not self.cluster.stop_node(host, ROLE_DN):
                self.problems.append(f"DataNode {host} did not stop")
                self.cluster.start_node(host, ROLE_DN)
                continue
            if not wait_until(
                lambda h=host: (self.cluster.dn_status_for(h) or "").lower() != "running",
                timeout=self.cfg.get_int("CLUSTER_STOP_TIMEOUT_SEC"),
                interval=3,
            ):
                self.log(
                    f"  note: {host} still reads Running after its process stopped "
                    "(heartbeat has not expired yet); continuing"
                )
            time.sleep(self.cfg.get_int("CONSISTENCY_SETTLE_SEC"))

            for name, spec in queries.items():
                if name not in baseline:
                    continue
                value = self._capture(query_host, f"stop_{host.replace('.', '_')}_{name}", spec)
                if value is None:
                    continue
                if value != baseline[name]:
                    self.problems.append(
                        f"replica inconsistency: '{name}' result differs while {host} is down"
                    )
                    self.log(f"  DIFF in '{name}' while {host} is down")
                    # Freeze the replica file lists while the cluster is still
                    # in the failing shape: this is the only moment when the
                    # cause (a file one replica never got) is still readable.
                    if host not in forensic_done:
                        forensic_done.add(host)
                        try:
                            self.forensic_replica_files(
                                f"diff_{host.replace('.', '_')}",
                                diff_query=(name, spec),
                                running=running,
                                down=host,
                            )
                        except Exception as exc:  # never let forensics fail a case
                            self.log(f"  forensic capture failed (ignored): {exc}")
            checked += 1

            self.cluster.start_node(host, ROLE_DN)
            if not wait_until(
                lambda h=host: status_is(self.cluster.dn_status_for(h), "running"),
                timeout=300,
                interval=3,
            ):
                self.problems.append(f"failed to restart {host}")
                continue
            if sync_waiter is not None and sync_waiter.available():
                result = sync_waiter.wait()
                if not result.ok:
                    self.problems.append(f"sync-lag gate after restarting {host}: {result.reason}")

        if checked == 0:
            self.problems.append("consistency sweep did not check any DataNode")
        return self.problems

    def _alternate_query_host(self, stop_host: str, running: list[str]) -> str | None:
        for host in running:
            if host != stop_host:
                return host
        return None

    # ------------------------------------------------------------------
    # Region bookkeeping (used to prove the removed DN dropped its data)
    # ------------------------------------------------------------------
    def regions_on_host(self, host: str, databases: list[str]) -> list[str]:
        region_ids: list[str] = []
        try:
            rows = self.sql.show_regions(self.cfg.cli_host)
        except Exception:
            return region_ids
        for row in rows:
            ip = (row.get("RpcAddress") or "").strip()
            db = (row.get("Database") or "").strip()
            rid = (row.get("RegionId") or "").strip()
            if ip == host and rid and (not databases or any(db.startswith(d) for d in databases)):
                region_ids.append(rid)
        return region_ids

    # ------------------------------------------------------------------
    # Log scanning
    # ------------------------------------------------------------------
    def _scan_script(
        self, role: str, patterns: list[str], since_epoch: int | None, until_epoch: int | None = None
    ) -> str:
        """Grep this host's logs without mutating them.

        Rotated ``*.gz`` files are read through ``zcat``; nothing is
        decompressed in place, so the scan is safe to run on a live cluster.
        """
        glob = "*confignode*all*.log*" if role == ROLE_CN else "*datanode*all*.log*"
        combined = "|".join(patterns)
        awk_filter = "cat"
        if since_epoch or until_epoch:
            # ``last`` carries the timestamp of the most recent dated line, so an undated
            # continuation line (a stack frame such as ``Caused by: ...``) is attributed to
            # the line above it instead of escaping the window.
            lower = (
                time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since_epoch - 5))
                if since_epoch
                else "0000-00-00 00:00:00"
            )
            upper = (
                time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(until_epoch))
                if until_epoch
                else "9999-12-31 23:59:59"
            )
            awk_prog = (
                "{ if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) "
                "last=substr($0,1,19); if (last >= t && last <= u) print }"
            )
            awk_filter = (
                f"awk -v t={shlex.quote(lower)} -v u={shlex.quote(upper)} {shlex.quote(awk_prog)}"
            )
        return f"""
d={shlex.quote(self.cfg.get('DB_DIR'))}
cd "$d/logs" 2>/dev/null || exit 0
files=$(ls {glob} 2>/dev/null || true)
[[ -z "$files" ]] && exit 0
for f in $files; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.gz) reader=zcat ;;
    *)    reader=cat ;;
  esac
  $reader "$f" 2>/dev/null | {awk_filter} | grep -E {shlex.quote(combined)} 2>/dev/null \\
    | sed "s|^|$f:|" | head -n 50
done | head -n 400
exit 0
"""

    def scan_logs(
        self,
        *,
        since_epoch: int | None = None,
        until_epoch: int | None = None,
        patterns: list[str] | None = None,
    ) -> dict[str, list[str]]:
        # ``patterns`` overrides the corruption-oriented default so callers can
        # look for a specific family (see ``snapshot_query_failures``).
        if patterns is None:
            patterns = list(DEFAULT_LOG_PATTERNS)
        else:
            patterns = list(patterns)
        extra = self.cfg.raw("LOG_EXTRA_PATTERNS")
        if extra:
            patterns += [p.strip() for p in extra.split(",") if p.strip()]
        combined = re.compile("|".join(f"(?:{p})" for p in patterns))

        findings: dict[str, list[str]] = {}
        targets = [(ROLE_CN, h) for h in self.cfg.cn_hosts] + [(ROLE_DN, h) for h in self.cfg.dn_hosts]
        seen: set[tuple[str, str]] = set()
        for role, host in targets:
            if (role, host) in seen:
                continue
            seen.add((role, host))
            res = self.ssh.run_script(
                host,
                self._scan_script(
                    role,
                    patterns,
                    since_epoch if self.cfg.raw("LOG_SCAN_MODE") == "since" else None,
                    until_epoch,
                ),
                check=False,
                timeout=900,
            )
            hits: list[str] = []
            for line in res.out.splitlines():
                if not line.strip():
                    continue
                m = combined.search(line)
                if m:
                    hits.append(f"{role}@{host}: {line.strip()[:400]}")
            if hits:
                findings[f"{role}@{host}"] = hits
        return findings

    def snapshot_query_failures(self, *, since_epoch: int | None = None) -> int:
        """Record the query-failure family found in the *live* node logs.

        Runs while the case is still finishing, i.e. before the next case's
        ``prepare`` resets the logs, so even a PASS case keeps its 305 evidence
        in ``<case>/server_305_snapshot.txt``.  Returns the number of lines kept;
        never raises (evidence collection must not turn a good case into a fail).
        """
        try:
            findings = self.scan_logs(since_epoch=since_epoch, patterns=QUERY_FAILURE_PATTERNS)
            lines = [line for hits in findings.values() for line in hits]
            if not lines:
                return 0
            self.artifacts.mkdir(parents=True, exist_ok=True)
            (self.artifacts / "server_305_snapshot.txt").write_text(
                "\n".join(lines) + "\n", encoding="utf-8"
            )
            return len(lines)
        except Exception:  # noqa: BLE001 - best effort only
            return 0

    def check_logs(
        self, *, since_epoch: int | None = None, until_epoch: int | None = None
    ) -> list[str]:
        findings = self.scan_logs(since_epoch=since_epoch, until_epoch=until_epoch)
        problems: list[str] = []
        for key, hits in findings.items():
            problems.append(
                f"unexpected log lines on {key}: at least {len(hits)} hit(s), first: {hits[0][:220]}"
            )
        if findings:
            (self.artifacts / "log_findings.txt").write_text(
                "\n".join(line for hits in findings.values() for line in hits) + "\n",
                encoding="utf-8",
            )
        return problems

    # ------------------------------------------------------------------
    # Log backup
    # ------------------------------------------------------------------
    def backup_node_logs(self, dest_root: Path, *, include_cn: bool = True) -> dict:
        """Copy every node log as plain text into ``dest_root`` (one directory per host).

        The tar backup (``backup_logs``) is for archiving; this one exists because a
        migration failure must be greppable after the next cluster reset wipes
        ``<DB_DIR>/logs``.  Best effort: an unreachable node is recorded, not fatal.
        """
        dest_root.mkdir(parents=True, exist_ok=True)
        db_dir = self.cfg.get("DB_DIR")
        hosts: list[tuple[str, str]] = []
        seen: set[str] = set()
        for role, group in ((ROLE_DN, self.cfg.dn_hosts), (ROLE_CN, self.cfg.cn_hosts)):
            if role == ROLE_CN and not include_cn:
                continue
            for host in group:
                if host in seen:
                    continue  # CN and DN are often co-located: one logs dir per host
                seen.add(host)
                hosts.append((role, host))
        meta = [f"time={time.strftime('%Y-%m-%d %H:%M:%S')}", f"db_dir={db_dir}",
                f"hosts={','.join(h for _, h in hosts)}"]
        stats = {"hosts": 0, "files": 0, "bytes": 0, "missing": []}
        for role, host in hosts:
            host_dir = dest_root / f"{role}_{host.replace('.', '_')}"
            listing = self.ssh.run_script(
                host, f"ls -1 {db_dir}/logs/*.log 2>/dev/null", check=False, timeout=120
            ).out
            paths = [p for p in listing.split() if p.endswith(".log")]
            if not paths:
                stats["missing"].append(f"{role}_{host}")
                meta.append(f"{role}_{host}: no log files")
                continue
            host_dir.mkdir(parents=True, exist_ok=True)
            stats["hosts"] += 1
            for path in paths:
                name = path.rsplit("/", 1)[-1]
                out = self.ssh.run_script(host, f"cat {path}", check=False, timeout=900).out
                (host_dir / name).write_text(out, encoding="utf-8", errors="replace")
                stats["files"] += 1
                stats["bytes"] += len(out.encode("utf-8", errors="replace"))
        (dest_root / "meta.txt").write_text("\n".join(meta) + "\n", encoding="utf-8")
        return stats

    def backup_logs(self, tag: str, dest_root: Path) -> Path:
        dest = dest_root / tag
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "meta.txt").write_text(
            f"tag={tag}\ntime={time.strftime('%Y-%m-%d %H:%M:%S')}\ndb_dir={self.cfg.get('DB_DIR')}\n"
            f"confignodes={','.join(self.cfg.cn_hosts)}\ndatanodes={','.join(self.cfg.dn_hosts)}\n",
            encoding="utf-8",
        )
        for role, host in [(ROLE_CN, h) for h in self.cfg.cn_hosts] + [(ROLE_DN, h) for h in self.cfg.dn_hosts]:
            target = dest / f"{role}_{host.replace('.', '_')}.tar.gz"
            try:
                ok = self.ssh.stream_tar(
                    host,
                    f"{self.cfg.get('DB_DIR')}/logs",
                    target,
                    prefix=f"{role}_{host}",
                )
                if ok:
                    self.log(f"  backed up logs: {target.name} ({target.stat().st_size // 1024} KiB)")
                else:
                    self.log(f"  no logs directory on {host}, skipped")
            except Exception as exc:  # noqa: BLE001
                self.log(f"  log backup failed for {host}: {exc}")
        return dest
        # A completion marker for the freeze watcher: it waits for this before SIGTERM,
        # because "the directory is non-empty" is true as soon as meta.txt is written, so a
        # freeze mid-tar looked like a finished backup (measured: an empty backup dir that
        # cost the row-level trace of a real replica diff).
        (dest / "DONE").write_text(str(len(list(dest.glob("*.tar.gz")))) + " archive(s)\n", encoding="utf-8")
        return dest
