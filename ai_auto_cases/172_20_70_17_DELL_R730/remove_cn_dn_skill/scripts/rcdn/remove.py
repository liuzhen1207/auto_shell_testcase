"""REMOVE DATANODE / REMOVE CONFIGNODE operations and abnormal injections."""

from __future__ import annotations

import re
import shlex
import time
from dataclasses import dataclass, field

from .cluster import ROLE_CN, ROLE_DN, Cluster, status_is
from .config import Config
from .remote import first_line, SqlClient, SshRunner, looks_like_sql_error, wait_until

def rotated_dn_targets(hosts: list[str], used: str) -> list[str]:
    """Return ``hosts`` with ``used`` moved to the back.

    `run_abnormal` picks ``running_dns[0]`` for every DataNode fault, and the list
    is built once, so a case with three ``restart_dn`` ops restarts the *same*
    node three times.  Rotating after each restart makes a repeated-restart case
    cover every DataNode once instead -- which is what the member-replacement
    repro needs, because the node that matters is whichever one received the
    migrated replica, and that is not known before the migration runs.
    """
    if used not in hosts:
        return list(hosts)
    return [h for h in hosts if h != used] + [used]


# Statements that must be rejected without breaking the cluster.
INVALID_REMOVE_STATEMENTS = (
    "remove datanode;",
    "remove datanode -1;",
    "remove datanode 999999;",
    "remove datanode abc;",
    "remove datanode 1.5;",
    "remove confignode;",
    "remove confignode -1;",
    "remove confignode 999999;",
    "remove confignode abc;",
)


@dataclass
class Target:
    """The node a case removes."""

    role: str
    host: str
    node_id: str
    selector: str
    extra: list[tuple[str, str]] = field(default_factory=list)  # additional (host, node_id) removals
    region_ids: list[str] = field(default_factory=list)        # regions hosted before the remove
    extra_regions: dict[str, list[str]] = field(default_factory=dict)  # same, per extra host
    expect_reject: bool = False                                # the statement must be rejected
    abnormal: list[str] = field(default_factory=list)          # faults the case injects; see cases.md


#: Files under a removed DataNode's data directory that are *not* data.  The
#: process lock is (re)created by every boot, so "it is still there after the
#: restart" says nothing about whether the removal deleted anything -- and because
#: it is guaranteed to be present after any restart, counting it turns the restart
#: probe into a permanent false positive.  On 2.0.12.1 RC4 `dn_readonly_remove` was
#: reported as `restarted and still holds 1 file(s) it no longer owns: .iotdb-lock`
#: for a node whose data was in fact gone.
IGNORED_RESIDUAL_NAMES = frozenset({".iotdb-lock"})


def is_residual_data(path: str) -> bool:
    """True when a file left behind by a removed DataNode counts as leftover data.

    Only the basename matters: the lock lives at the root of the data directory on
    some builds and one level down on others.
    """
    name = path.replace("\\", "/").rsplit("/", 1)[-1]
    return bool(name) and name not in IGNORED_RESIDUAL_NAMES


class RemoveError(RuntimeError):
    pass


def disk_full_threshold_for(free_ratio: float, margin: float = 0.05) -> float | None:
    """A ``disk_space_warning_threshold`` that makes this volume look full.

    A DataNode turns ReadOnly once its free-space *ratio* falls to or below
    ``disk_space_warning_threshold``, so raising the threshold above the real
    ratio drives the node to ReadOnly/DISK_FULL through exactly the same
    ``FolderManager.changeToReadOnlyIfDiskFull`` path that a genuinely full disk
    drives -- while writing nothing at all.  The property is hot-reloadable, and
    putting it back makes the node return to Running on its own.

    Returns ``None`` when the volume is already so full that no legal value
    could be picked (the property must stay inside ``[0, 1)``).
    """
    if not 0.0 <= free_ratio < 1.0:
        return None
    target = min(free_ratio + margin, 0.999)
    if target < free_ratio:
        return None
    return round(target, 4)


class Remover:
    def __init__(self, cfg: Config, cluster: Cluster, ssh: SshRunner, sql: SqlClient, log):
        self.cfg = cfg
        self.cluster = cluster
        self.ssh = ssh
        self.sql = sql
        self.log = log
        self.last_stall = ""
        # (host, threshold) pairs for simulated disk-full states not yet undone.
        self._pending_disk_restore: list[tuple[str, float]] = []

    # ------------------------------------------------------------------
    # Targets
    # ------------------------------------------------------------------
    def _region_weight(self, db_prefixes: list[str]) -> dict[str, int]:
        """Count DataRegions per DataNode RPC address."""
        weights: dict[str, int] = {}
        try:
            rows = self.sql.show_regions(self.cfg.cli_host)
        except Exception:
            rows = []
        for row in rows:
            if (row.get("Type") or "").strip() != "DataRegion":
                continue
            db = (row.get("Database") or "").strip()
            if db_prefixes and not any(db.startswith(p) for p in db_prefixes):
                continue
            ip = (row.get("RpcAddress") or "").strip()
            if ip:
                weights[ip] = weights.get(ip, 0) + 1
        return weights

    def pick_dn(self, selector: str, *, exclude: set[str] | None = None) -> str:
        exclude = set(exclude or ())
        exclude.add(self.cfg.cli_host)
        running = [h for h in self.cluster.running_dn_hosts() if h not in exclude]
        if not running:
            raise RemoveError("no Running DataNode available as a removal target")
        weights = self._region_weight([self.cfg.get("BM_TREE_DB"), self.cfg.get("BM_TABLE_DB")])
        ranked = sorted(running, key=lambda h: (-weights.get(h, 0), h))
        chosen = ranked[0]
        self.log(f"  removal target (selector={selector}): {chosen} regions={weights.get(chosen, 0)}")
        return chosen

    def pick_cn(self, selector: str, *, exclude: set[str] | None = None) -> str:
        exclude = set(exclude or ())
        running = [h for h in self.cluster.running_cn_hosts() if h not in exclude]
        leader = self.cluster.leader_cn_host()
        if selector == "leader":
            if not leader:
                raise RemoveError("no ConfigNode reports Role=Leader")
            return leader
        followers = [h for h in running if h != leader]
        if selector == "stopped":
            if not followers:
                raise RemoveError("no Follower ConfigNode available to stop")
            return followers[0]
        if not followers:
            raise RemoveError("no Follower ConfigNode available")
        return followers[0]

    # ------------------------------------------------------------------
    # Preconditions that shape the target's state
    # ------------------------------------------------------------------
    def make_dn_unknown(self, host: str) -> None:
        self.log(f"  stopping DataNode {host} so it becomes Unknown")
        self.cluster.stop_node(host, ROLE_DN)
        if not wait_until(
            lambda: not status_is(self.cluster.dn_status_for(host), "running"),
            timeout=180,
            interval=3,
        ):
            raise RemoveError(f"DataNode {host} did not leave the Running state")

    def make_dn_readonly(self, host: str) -> None:
        self.log(f"  switching DataNode {host} to ReadOnly")
        self.sql.sql(host, "set system to readonly on local;", check=False)
        if not wait_until(
            lambda: status_is(self.cluster.dn_status_for(host), "readonly"),
            timeout=300,
            interval=3,
        ):
            raise RemoveError(f"DataNode {host} did not become ReadOnly")

    def disk_usage(self, host: str) -> tuple[float, float] | None:
        """(free ratio, configured threshold) for the node's data volume.

        Both are readable while the node is stopped, so this doubles as the
        up-front feasibility check between cases.
        """
        db_dir = shlex.quote(self.cfg.get("DB_DIR"))
        res = self.ssh.run(
            host,
            f"df -BG --output=avail,size {db_dir} 2>/dev/null | tail -1; "
            f"grep -E '^disk_space_warning_threshold=' "
            f"{db_dir}/conf/iotdb-system.properties 2>/dev/null | head -1",
            check=False,
            timeout=60,
        )
        lines = [ln.strip() for ln in res.out.splitlines() if ln.strip()]
        if not lines:
            return None
        numbers = [ch for ch in lines[0].replace("G", "").split() if ch.isdigit()]
        if len(numbers) < 2:
            return None
        avail_gb, total_gb = int(numbers[0]), int(numbers[1])
        if total_gb <= 0:
            return None
        threshold = 0.05
        for line in lines[1:]:
            if line.startswith("disk_space_warning_threshold="):
                try:
                    threshold = float(line.split("=", 1)[1])
                except ValueError:
                    pass
        return avail_gb / total_gb, threshold

    def diskfull_can_simulate(self, host: str) -> tuple[bool, str]:
        """Can this node be driven to ReadOnly without touching the disk?

        Filling is hopeless on a multi-terabyte volume (a 5% floor on 18TB is
        ~928G), so the state is produced by raising the node's own
        `disk_space_warning_threshold` above its real free ratio instead.  That
        keeps the genuine disk-space code path -- `hasSpace()` fails for every
        folder, so `FolderManager.changeToReadOnlyIfDiskFull` marks the node
        ReadOnly with statusReason DISK_FULL -- while writing nothing at all.
        """
        usage = self.disk_usage(host)
        if usage is None:
            # Cannot tell; let the case try rather than skipping on a read hiccup.
            return True, ""
        ratio, threshold = usage
        if disk_full_threshold_for(ratio) is None:
            return False, (
                f"cannot simulate a full disk on {host}: the volume is already "
                f"{ratio * 100:.1f}% free, too full for any threshold in [0,1)"
            )
        return True, f"free {ratio * 100:.1f}%, threshold {threshold:g}"

    def disk_threshold_statement(self, host: str, target: float) -> str:
        """Scoped `SET CONFIGURATION` for the disk-space threshold of ONE node.

        The `ON <nodeId>` clause is mandatory here.  Per IoTDBSqlParser.g4:1326
        (`SET CONFIGURATION setConfigurationEntry+ (ON INTEGER_LITERAL)?`) the
        clause is optional, and omitting it applies the change CLUSTER-WIDE.
        Measured 2026-09-18: without it, every DataNode adopted the raised
        threshold and went `ReadOnly(DiskFull)` at once, so the case exercised
        "the whole cluster is disk-full" -- a different and far more severe
        scenario than the "one other DataNode is disk-full" it claims, and it
        produced ~350 client write errors that were an artefact of that leak.
        """
        node_id = self.cluster.dn_id_for(host)
        if not node_id:
            raise RemoveError(
                f"cannot resolve the node id of DataNode {host}; refusing to issue a "
                f"cluster-wide SET CONFIGURATION, which would mark every DataNode "
                f"disk-full instead of only this one"
            )
        return (
            f'set configuration "disk_space_warning_threshold"="{target}" '
            f"on {node_id};"
        )

    def make_dn_diskfull(self, host: str, *, timeout: int = 420) -> float:
        """Drive the node to ReadOnly through its own disk-space guard.

        Returns the threshold that was configured beforehand, so the caller can
        hand it to `restore_disk_threshold` and let the node come back to
        Running.  Nothing is written to the volume.
        """
        usage = self.disk_usage(host)
        if usage is None:
            raise RemoveError(f"cannot read the disk usage of DataNode {host}")
        ratio, previous = usage
        target = disk_full_threshold_for(ratio)
        if target is None:
            raise RemoveError(
                f"DataNode {host} is already {ratio * 100:.1f}% free; no threshold "
                f"inside [0,1) can mark it disk-full"
            )
        self.log(
            f"  simulating a full disk on {host} (free {ratio * 100:.1f}%): "
            f"disk_space_warning_threshold {previous:g} -> {target:g}, hot-reloaded, "
            f"nothing written"
        )
        self.sql.sql(
            host,
            self.disk_threshold_statement(host, target),
            check=False,
        )
        # The transition hangs off the allocation path, not a timer: the node
        # turns ReadOnly when a write tries to place a file and
        # `JVMCommonUtils.hasSpace` rejects every folder.  Under the benchmark's
        # write load that happens within seconds; on an idle cluster it never
        # happens at all, which is what the timeout message has to say.
        if not wait_until(
            lambda: status_is(self.cluster.dn_status_for(host), "readonly"),
            timeout=timeout,
            interval=5,
        ):
            self.restore_disk_threshold(host, previous)
            raise RemoveError(
                f"DataNode {host} did not turn ReadOnly within {timeout}s after its "
                f"disk_space_warning_threshold was raised to {target:g}. The "
                f"disk-full state is entered on a write attempt, so this node must "
                f"be receiving writes (a benchmark must be running against it)."
            )
        self._pending_disk_restore.append((host, previous))
        return previous

    def take_pending_disk_threshold(self, host: str) -> float | None:
        """Return and forget the threshold recorded for `host`, if any.

        Used by mid-case healing: it must undo the raise *live* (the running node
        hot-loaded the value, so editing the file would change nothing) and then
        own the file cleanup itself, so the teardown must not write the value
        back as an active line.
        """
        for i, (h, _t) in enumerate(self._pending_disk_restore):
            if h == host:
                _h, threshold = self._pending_disk_restore.pop(i)
                return threshold
        return None

    def restore_disk_threshold(self, host: str, threshold: float) -> None:
        """Put the threshold back so the node returns to Running on its own."""
        self.sql.sql(
            host,
            self.disk_threshold_statement(host, threshold),
            check=False,
        )
        if not wait_until(
            lambda: status_is(self.cluster.dn_status_for(host), "running"),
            timeout=180,
            interval=5,
        ):
            self.log(
                f"  note: DataNode {host} is not Running yet after restoring "
                f"disk_space_warning_threshold={threshold:g}"
            )

    def restore_pending_disk_state(self) -> None:
        """Best-effort undo of every simulated disk-full, for case teardown.

        A failure here is `WARNING`-logged, never fatal -- but it is NOT
        harmless, contrary to what this docstring used to claim.  The per-case
        cluster reset does **not** rewrite `iotdb-system.properties`; the raise
        is persisted and survives, so a failure here leaks into every later case
        until `clear_raised_disk_thresholds()` catches it at the next case start.
        That is exactly how eight consecutive cases were poisoned on 2026-09-18.
        """
        pending, self._pending_disk_restore = self._pending_disk_restore, []
        for host, threshold in pending:
            try:
                self.restore_disk_threshold(host, threshold)
            except Exception as exc:  # noqa: BLE001 - teardown must never mask the verdict
                # NOT a quiet `note`: this failure leaves a PERSISTED raise behind,
                # and it is most likely to happen exactly when the case has broken
                # the cluster's SQL path -- i.e. in the cases that most need it.
                # On 2026-09-18 this line was swallowed and eight later cases were
                # poisoned.  The next case's `clear_raised_disk_thresholds()` is the
                # backstop, but say it loudly here so the cause is obvious.
                self.log(
                    f"  WARNING: could not restore the disk threshold on {host}: {exc}; "
                    f"a raised disk_space_warning_threshold may persist on that node"
                )

    # ------------------------------------------------------------------
    # Submission
    # ------------------------------------------------------------------
    def remove_statement(self, role: str, node_id: str) -> str:
        what = "datanode" if role == ROLE_DN else "confignode"
        return f"remove {what} {node_id};"

    def submit(self, role: str, node_id: str, *, exec_host: str | None = None) -> str:
        host = exec_host or self.cfg.cli_host
        stmt = self.remove_statement(role, node_id)
        out = self.sql.sql(host, stmt, check=False)
        self.log(f"  submitted on {host}: {stmt}")
        if looks_like_sql_error(out):
            raise RemoveError(f"{stmt} was rejected:\n{out[-1500:]}")
        if "success" not in out.lower() and "submit" not in out.lower():
            self.log(f"  note: remove output did not contain 'success': {out.strip()[:300]}")
        return out

    def submit_tolerant(self, role: str, node_id: str, what: str) -> bool:
        """Submit a remove that may legitimately be rejected (duplicate request).

        Returns True when the cluster accepted it.
        """
        stmt = self.remove_statement(role, node_id)
        out = self.sql.sql(self.cfg.cli_host, stmt, check=False)
        if looks_like_sql_error(out):
            self.log(f"  {what} was rejected (acceptable): {out.strip().splitlines()[-1][:200]}")
            return False
        self.log(f"  {what} accepted: {stmt}")
        return True

    def submit_invalid_statements(self) -> list[str]:
        """Run malformed remove SQL and confirm each one is rejected."""
        problems: list[str] = []
        host = self.cfg.cli_host
        for stmt in INVALID_REMOVE_STATEMENTS:
            out = self.sql.sql(host, stmt, check=False)
            rejected = looks_like_sql_error(out) or "error" in out.lower()
            if not rejected:
                # Removing a well-formed but absent id is allowed to report an error too.
                problems.append(f"{stmt} was not rejected")
            self.log(f"  invalid SQL {stmt!r} -> {'rejected' if rejected else 'ACCEPTED (unexpected)'}")
        return problems

    # ------------------------------------------------------------------
    # Abnormal operations
    # ------------------------------------------------------------------
    def wait_cn_ready(
        self, host: str, query_host: str | None = None, timeout: int = 180
    ) -> float | None:
        """When ``host`` reports Running again, or None if it never does.

        Called after a ConfigNode restart: the availability window is only as
        long as the node is actually away, so an error *after* it is back is not
        excused by the restart.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                if status_is(self.cluster.cn_status_for(host, query_host), "running"):
                    return time.time()
            except Exception:
                pass
            time.sleep(5)
        return None

    def run_abnormal(
        self,
        ops: list[str],
        *,
        target: Target,
        delay: int = 5,
        outage: list[tuple[float, float | None]] | None = None,
        dn_outage: list[tuple[float, float | None]] | None = None,
    ) -> list[str]:
        """Inject abnormal operations while the remove procedure runs.

        ``outage`` collects the windows in which a ConfigNode was taken down, so
        the caller can tell an expected below-quorum outage apart from a real
        availability bug.  ``dn_outage`` does the same for a DataNode that is
        stopped or restarted: every statement served by it fails while it is
        down, and R&D's decision (2026-09-29) is to recycle the resources
        immediately instead of draining in-flight queries, so those failures are
        expected.  A window with no end means the node stayed down for the rest
        of the case.
        """
        problems: list[str] = []
        if not ops or ops == ["none"]:
            return problems

        if delay:
            time.sleep(delay)

        running_dns = [h for h in self.cluster.running_dn_hosts() if h != target.host]
        running_cns = [h for h in self.cluster.running_cn_hosts() if h != target.host]

        # Which DataNode the "other_dn*"/restart faults hit.  The historical behaviour is
        # running_dns[0]; ABNORMAL_DN_HOST deliberately targets the node that hosts the
        # regions being migrated, because whether the fault lands inside the
        # member-replacement window otherwise depends only on where the regions happen to
        # sit (measured: ~1 hit per 8-20 cases for the silent-row-loss repro).
        preferred = (self.cfg.get("ABNORMAL_DN_HOST") or "").strip()
        if preferred and preferred in running_dns:
            running_dns = [preferred] + [h for h in running_dns if h != preferred]
            self.log(f"  abnormal-op target pinned to {preferred} (ABNORMAL_DN_HOST)")
        rotate_dn = self.cfg.get_bool("ABNORMAL_DN_ROTATE")
        if rotate_dn and len(running_dns) > 1:
            self.log(
                f"  abnormal-op targets rotate over {len(running_dns)} DataNode(s) "
                "(ABNORMAL_DN_ROTATE)"
            )

        for op in ops:
            if op == "none":
                continue
            self.log(f"  abnormal op: {op}")
            try:
                if op == "kill9_target":
                    if target.role == ROLE_DN:
                        if dn_outage is not None:
                            # Killed outright: only the restart probe brings it
                            # back, after the workload has been drained.
                            dn_outage.append((time.time(), None))
                        self.cluster.kill_node(target.host, ROLE_DN)
                    else:
                        self.cluster.kill_node(target.host, ROLE_CN)
                elif op == "kill9_other_dn":
                    if running_dns:
                        if dn_outage is not None:
                            dn_outage.append((time.time(), None))
                        self.cluster.kill_node(running_dns[0], ROLE_DN)
                elif op == "restart_dn":
                    if running_dns:
                        host = running_dns[0]
                        started = time.time()
                        old_pids = self.dn_pids(host)
                        self.cluster.stop_node(host, ROLE_DN)
                        # A DataNode killed under load can spend minutes in its shutdown
                        # hooks (measured: 7 minutes on 11.101.10.7), and
                        # `sbin/start-datanode.sh` runs `check_running_process` and refuses
                        # to launch a second node for the same IOTDB_HOME -- so starting
                        # immediately is a silent no-op and the node stays down for the
                        # whole case ("did not come back to Running" for a restart that
                        # never happened: measured twice in 15 sweep cases).  Wait for the
                        # old process to exit, then require a NEW pid before judging it.
                        exit_timeout = self.cfg.get_int("CLUSTER_STOP_TIMEOUT_SEC")
                        if not wait_until(
                            lambda h=host: not self.dn_pids(h), timeout=exit_timeout, interval=5
                        ):
                            self.log(
                                f"  {host} still shutting down after {exit_timeout}s; the "
                                "restart below may be a no-op"
                            )
                        for attempt in (1, 2):
                            self.cluster.start_node(host, ROLE_DN)
                            fresh = wait_until(
                                lambda h=host, old=old_pids: bool(self.dn_pids(h) - old),
                                timeout=120,
                                interval=5,
                            )
                            if fresh:
                                break
                            if attempt == 1:
                                self.log(
                                    f"  {host}: start did not produce a new DataNode pid, retrying"
                                )
                        if dn_outage is not None:
                            ready = self.wait_dn_running(host, timeout=300)
                            dn_outage.append((started, time.time() if ready else None))
                            self.log(
                                "  DataNode restart window recorded "
                                f"({time.time() - started:.0f}s, "
                                f"{'back Running' if ready else 'still not Running'})"
                            )
                            if not ready:
                                # Measured twice in one 16-case sweep: a node restarted
                                # during the removal does not come back to Running, and the
                                # rest of the case is then spent waiting for a sync gate that
                                # can never drain (~1500 s instead of ~700 s).  Stop
                                # injecting further faults: a second broken node cannot
                                # teach us anything and only lengthens the run.
                                problems.append(
                                    f"{host} did not come back to Running after restart_dn; "
                                    "skipping the remaining abnormal operations"
                                )
                                break
                        if rotate_dn:
                            # Next op restarts a DIFFERENT node: a repeated-restart
                            # case then covers every node once, so the one holding
                            # the freshly migrated replica is restarted too.
                            running_dns = rotated_dn_targets(running_dns, host)
                elif op == "restart_cn":
                    if running_cns:
                        host = running_cns[0]
                        started = time.time()
                        self.cluster.stop_node(host, ROLE_CN)
                        self.cluster.start_node(host, ROLE_CN)
                        if outage is not None:
                            peers = [h for h in running_cns if h != host]
                            outage.append((started, self.wait_cn_ready(host, peers[0] if peers else None)))
                elif op == "kill9_cn":
                    if running_cns:
                        if outage is not None:
                            # Nothing brings it back inside the case, so the
                            # window stays open until the load is drained.
                            outage.append((time.time(), None))
                        self.cluster.kill_node(running_cns[0], ROLE_CN)
                elif op == "stop_cn":
                    if running_cns:
                        self.cluster.stop_node(running_cns[0], ROLE_CN)
                elif op == "other_dn_readonly":
                    # tc113: a different DataNode turns ReadOnly mid-procedure.
                    if running_dns:
                        self.make_dn_readonly(running_dns[0])
                elif op == "other_dn_stop":
                    # tc114: a different replica becomes Unknown mid-procedure.
                    if running_dns:
                        if dn_outage is not None:
                            # Stopped and left stopped for the rest of the case.
                            dn_outage.append((time.time(), None))
                        self.cluster.stop_node(running_dns[0], ROLE_DN)
                elif op == "other_dn_diskfull":
                    # tc120: a different DataNode is disk-full while this one is removed.
                    # A fault that cannot be injected must never pass silently: that
                    # yields a green case for a scenario that was never exercised.
                    if not self.cfg.get_bool("DISK_FULL_SIMULATE"):
                        problems.append(
                            "other_dn_diskfull fault not injected: DISK_FULL_SIMULATE=false"
                        )
                    elif not running_dns:
                        problems.append(
                            "other_dn_diskfull fault not injected: no other running DataNode"
                        )
                    else:
                        possible, why = self.diskfull_can_simulate(running_dns[0])
                        if not possible:
                            problems.append(
                                f"other_dn_diskfull fault not injected: {why}"
                            )
                        else:
                            self.make_dn_diskfull(running_dns[0])
                elif op == "concurrent_remove":
                    # A second, different DataNode removal submitted while the
                    # first procedure is still running: both may proceed, or
                    # the cluster may serialise them. Either is acceptable.
                    others = [h for h in self.cluster.running_dn_hosts() if h != target.host]
                    if target.role == ROLE_DN and others:
                        node_id = self.cluster.dn_id_for(others[0])
                        if node_id:
                            self.submit_tolerant(ROLE_DN, node_id, "concurrent remove")
                            target.extra.append((others[0], node_id))
                elif op == "remove_twice":
                    self.submit_tolerant(target.role, target.node_id, "repeated remove")
                elif op == "invalid_sql":
                    problems.extend(self.submit_invalid_statements())
                elif op == "delete_objects":
                    # Keep the OBJECT GC running while the region snapshot is
                    # taken: this op is what turns the TDB-861 race from a lucky
                    # coincidence into something the case actually exercises.
                    stmt = getattr(self, "object_delete_stmt", "") or ""
                    if not stmt:
                        problems.append("delete_objects: 没有可用的 DELETE 语句（表名未解析）")
                    else:
                        rounds = int(self.cfg.raw("OBJECT_DELETE_ROUNDS", "3") or 3)
                        interval = float(self.cfg.raw("OBJECT_DELETE_INTERVAL_SEC", "2") or 2)
                        for i in range(rounds):
                            out = self.sql.sql(
                                self.cfg.cli_host, stmt, dialect="table", check=False
                            )
                            self.log(
                                f"  delete_objects #{i + 1}: {first_line(out)[:120]}"
                            )
                            if i + 1 < rounds:
                                time.sleep(max(interval, 1.0))
                elif op == "load_balance":
                    out = self.sql.sql(self.cfg.cli_host, "load balance;", check=False)
                    if looks_like_sql_error(out):
                        self.log(f"  LOAD BALANCE reported: {out.strip()[:200]}")
                else:
                    problems.append(f"unknown abnormal op {op!r}")
            except Exception as exc:  # noqa: BLE001 - recorded, never fatal by itself
                problems.append(f"abnormal op {op} raised: {exc}")
        return problems

    # ------------------------------------------------------------------
    # Waiting for completion
    # ------------------------------------------------------------------
    def stuck_procedure(self, threshold_ms: int) -> str:
        """Describe a ConfigNode procedure worker stuck longer than threshold.

        The ConfigNode warns once every 30s::

            WARN ProcedureExecutor$WorkerMonitor - Worker stuck
            ProcedureCoreWorker-5(pid=36)(RemoveRegionPeerProcedure), run time 583206 ms

        A *transient* warning is normal, so only a run time past the threshold
        counts.  Blocking here is how a remove that can never finish shows up:
        when another replica holder of the region is ReadOnly, the remaining
        peers cannot commit the membership change, so the step never returns and
        the caller would otherwise wait out REMOVE_MAX_WAIT_SEC (2 hours by
        default) for a procedure that is not making progress.
        """
        db_dir = shlex.quote(self.cfg.get("DB_DIR"))
        res = self.ssh.run(
            self.cfg.cli_host,
            f"grep -a 'Worker stuck' {db_dir}/logs/log_confignode_all.log 2>/dev/null "
            f"| tail -1",
            check=False,
        )
        return self.parse_stuck_procedure((res.out or "").strip(), threshold_ms, self.cfg.cli_host)

    @staticmethod
    def parse_stuck_procedure(line: str, threshold_ms: int, host: str = "") -> str:
        """Pure half of :meth:`stuck_procedure`, so it can be unit tested."""
        if "Worker stuck" not in line:
            return ""
        match = re.search(r"run time (\d+) ms", line)
        if not match or int(match.group(1)) < threshold_ms:
            return ""
        name = re.search(r"\((\w+Procedure)\)", line)
        where = f" on {host}" if host else ""
        return (
            f"{name.group(1) if name else 'a procedure'} has been stuck for "
            f"{int(match.group(1)) // 1000}s{where}"
        )

    def wait_migrations_empty(
        self, *, timeout: int, stable_seconds: int, dialects: list[str | None] | None = None
    ) -> bool:
        """Wait until SHOW MIGRATIONS reports an empty set in every dialect.

        The reference testcases poll both the tree and the table dialect, so a
        migration that only one dialect can see still blocks completion.
        """
        dialects = dialects or [None]
        deadline = time.time() + timeout
        stable_since: float | None = None
        stall_ms = self.cfg.get_int("PROCEDURE_STALL_SEC") * 1000
        next_stall_check = time.time() + 60
        #: Set when the wait ended because the procedure is wedged rather than
        #: merely slow.  Callers must not go on to wait for the node to leave the
        #: cluster -- it never will, and that wait is another REMOVE_MAX_WAIT_SEC.
        self.last_stall = ""
        while True:
            if stall_ms > 0 and time.time() >= next_stall_check:
                next_stall_check = time.time() + 60
                stuck = self.stuck_procedure(stall_ms)
                if stuck:
                    self.log(f"  remove is not progressing: {stuck}")
                    self.last_stall = stuck
                    return False
            all_empty = True
            total = 0
            for dialect in dialects:
                try:
                    rows, empty = self.sql.show_migrations(self.cfg.cli_host, dialect=dialect)
                except Exception:
                    rows, empty = [], False
                total += len(rows)
                if not empty:
                    all_empty = False
            if all_empty:
                if stable_since is None:
                    stable_since = time.time()
                elif time.time() - stable_since >= stable_seconds:
                    return True
            else:
                if stable_since is not None:
                    self.log(f"  migrations re-appeared ({total} rows), continuing to wait")
                stable_since = None
            if time.time() > deadline:
                return False
            time.sleep(10)

    def _wait_absent(self, predicate, what: str, timeout: int) -> bool:
        """Wait for a node to leave the cluster, but not past a wedged procedure.

        A ConfigNode removal triggers no region migration, so the stall check
        inside :meth:`wait_migrations_empty` never sees it -- without this, a
        wedged `RemoveConfigNodeProcedure` would sit here for the full
        REMOVE_MAX_WAIT_SEC.  Reuses the same detection and records the reason
        in :attr:`last_stall` so callers can explain the failure.
        """
        deadline = time.time() + timeout
        stall_ms = self.cfg.get_int("PROCEDURE_STALL_SEC") * 1000
        next_stall_check = time.time() + 60
        while True:
            if predicate():
                return True
            if stall_ms > 0 and time.time() >= next_stall_check:
                next_stall_check = time.time() + 60
                stuck = self.stuck_procedure(stall_ms)
                if stuck:
                    self.log(f"  {what} will not leave the cluster: {stuck}")
                    self.last_stall = stuck
                    return False
            if time.time() > deadline:
                return False
            time.sleep(5)

    def wait_dn_absent(self, host: str, *, timeout: int) -> bool:
        return self._wait_absent(
            lambda: self.cluster.dn_id_for(host) is None, f"DataNode {host}", timeout
        )

    def wait_cn_absent(self, host: str, *, timeout: int) -> bool:
        return self._wait_absent(
            lambda: self.cluster.cn_id_for(host) is None, f"ConfigNode {host}", timeout
        )

    def wait_dn_status(self, host: str, expected: str, *, timeout: int) -> bool:
        return wait_until(
            lambda: status_is(self.cluster.dn_status_for(host), expected),
            timeout=timeout,
            interval=3,
        )

    def dn_pids(self, host: str) -> set[str]:
        """PIDs of the DataNode JVM on `host`.

        Identity, not liveness: a stopped DataNode's process can linger in its
        shutdown hooks for minutes, and `start-datanode.sh` refuses to launch a
        second node for the same IOTDB_HOME, so `restart_dn` must wait for the old
        pid to disappear and then require a *new* one.  Same reasoning as the
        restart probe's `_process_pids` in cases.py.
        """
        res = self.ssh.run(
            host,
            "sudo -n jps -l 2>/dev/null | grep -F DataNode || true",
            check=False,
            timeout=60,
        )
        pids: set[str] = set()
        for line in res.out.splitlines():
            parts = line.strip().split()
            if parts and parts[0].isdigit():
                pids.add(parts[0])
        return pids

    def wait_dn_running(self, host: str, *, timeout: int) -> bool:
        return self.wait_dn_status(host, "running", timeout=timeout)

    def wait_cn_running(self, host: str, *, timeout: int) -> bool:
        return wait_until(
            lambda: status_is(self.cluster.cn_status_for(host), "running"),
            timeout=timeout,
            interval=3,
        )

    # ------------------------------------------------------------------
    # Data cleanup verification (region files must be gone from the removed DN)
    # ------------------------------------------------------------------
    def check_removed_dn_data_cleaned(self, host: str, region_ids: list[str]) -> list[str]:
        if not region_ids:
            return []
        payload = "\n".join(region_ids)
        # The script prints one line per region:
        #   REGION=<id> FILES=<n> PATHS=<p1|p2|...>
        # The paths matter: the verdict is a single strict snapshot, but the data
        # directory is wiped by the *next* case's reset, so if the paths are not
        # captured here the evidence is gone before anyone can look at it.
        script = f"""
set -e
d={shlex.quote(self.cfg.get('DB_DIR'))}
conf="$d/conf/iotdb-system.properties"
data_dirs=$(grep -E '^[[:space:]]*dn_data_dirs[[:space:]]*=' "$conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')
[[ -z "$data_dirs" ]] && data_dirs="$d/data/datanode/data"
while read -r rid; do
  [[ -z "$rid" ]] && continue
  count=0
  paths=""
  IFS=',' read -r -a arr <<< "$data_dirs"
  for one in "${{arr[@]}}"; do
    [[ -z "$one" ]] && continue
    [[ -d "$one" ]] || continue
    matches=$(find "$one" -type f \\( -name '*.tsfile' -o -name '*.resource' -o -name '*.mods' \\) 2>/dev/null | grep "/$rid/" || true)
    if [[ -n "$matches" ]]; then
      n=$(printf '%s\\n' "$matches" | grep -c . || true)
      count=$((count+n))
      paths="$paths$(printf '%s|' "$matches")"
    fi
  done
  if [[ -d "$d/data/datanode/data/object/$rid" ]]; then
    matches=$(find "$d/data/datanode/data/object/$rid" -type f 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      n=$(printf '%s\\n' "$matches" | grep -c . || true)
      count=$((count+n))
      paths="$paths$(printf '%s|' "$matches")"
    fi
  fi
  printf 'REGION=%s FILES=%s PATHS=%s\\n' "$rid" "$count" "$paths"
done <<'RCDN_REGIONS'
{payload}
RCDN_REGIONS
exit 0
"""
        first = self._scan_removed_dn_data(host, script)
        problems: list[str] = []
        dirty: list[tuple[str, int, str]] = []
        for region, files, paths in first:
            if files:
                dirty.append((region, files, paths))
        if not dirty:
            return []

        # The verdict uses the strict snapshot above -- do NOT soften it.  But a
        # leftover may mean either "the deletion never happened" or "it is still
        # in flight"; a grace-period recheck tells the two apart, and that
        # distinction is the whole question when triaging this.  The recheck is
        # recorded as extra text inside the same problem, never as its own
        # problem, so it cannot change PASS/FAIL.
        grace = self.cfg.get_int("REMOVE_CLEANUP_RECHECK_SEC")
        time.sleep(grace)
        second = {r: (n, p) for r, n, p in self._scan_removed_dn_data(host, script)}
        for region, files, paths in dirty:
            later = second.get(region, (files, paths))
            detail = _brief_paths(paths)
            if later[0] == 0:
                tail = (
                    f"; gone after a {grace}s grace period, so the deletion was "
                    f"in flight rather than absent"
                )
            elif later[0] == files:
                tail = f"; still {later[0]} file(s) after {grace}s, unchanged"
            else:
                tail = (
                    f"; {later[0]} file(s) after {grace}s (was {files}), "
                    f"i.e. partially draining"
                )
            problems.append(
                f"removed DataNode {host} still holds {files} files of region "
                f"{region}{tail}. Files: {detail}"
            )
        return problems

    def removed_dn_residual_counts(self, host: str) -> tuple[int, int, int]:
        """``(dirs, files, KB)`` left under a removed DataNode's data directory.

        Numeric companion to :meth:`check_removed_dn_residual`, which renders
        prose for a problem message.  This one is meant for before/after
        comparisons -- e.g. around a restart -- where the counts themselves are
        the evidence, and it deliberately counts *everything* under
        ``data/datanode/data`` rather than only the regions a case tracked.
        Everything except :data:`IGNORED_RESIDUAL_NAMES`: see :func:`is_residual_data`.
        """
        ignored = " ".join(f"! -name {shlex.quote(n)}" for n in sorted(IGNORED_RESIDUAL_NAMES))
        script = f"""
d={shlex.quote(self.cfg.get('DB_DIR'))}
base="$d/data/datanode/data"
files=$(find "$base" -type f {ignored} 2>/dev/null | grep -c . || true)
dirs=$(find "$base" -mindepth 1 -maxdepth 3 -type d 2>/dev/null | grep -c . || true)
kb=$(du -sk "$base" 2>/dev/null | cut -f1 || true)
printf 'DIRS=%s FILES=%s KB=%s\\n' "${{dirs:-0}}" "${{files:-0}}" "${{kb:-0}}"
exit 0
"""
        res = self.ssh.run_script(host, script, check=False)
        m = re.search(r"DIRS=(\d+) FILES=(\d+) KB=(\d+)", res.out)
        if not m:
            return (0, 0, 0)
        return (int(m.group(1)), int(m.group(2)), int(m.group(3)))

    def removed_dn_residual_files(self, host: str) -> set[str]:
        """Relative paths of every file under a DataNode's data directory.

        Used to tell *stale* files from *new* ones around a restart: a node that
        boots up legitimately recreates its own empty directory structure, so
        "is anything there afterwards" is the wrong question.  What matters is
        whether a file that existed **before** the restart is still there
        **after** it -- see :meth:`check_removed_dn_residual` for the prose
        version.
        """
        script = f"""
d={shlex.quote(self.cfg.get('DB_DIR'))}
base="$d/data/datanode/data"
[[ -d "$base" ]] || exit 0
(cd "$base" && find . -type f 2>/dev/null | sed 's|^\\./||')
exit 0
"""
        res = self.ssh.run_script(host, script, check=False)
        return {line.strip() for line in res.out.splitlines() if is_residual_data(line.strip())}

    def check_removed_dn_residual(self, host: str) -> list[str]:
        """Any data at all left on a DataNode that was removed while Running.

        ``check_removed_dn_data_cleaned`` only inspects the DataRegions the case
        chose to track.  That silently under-reports: on a real run the removed
        node still held ~40 MB of object files for two *untracked* regions, and
        the case never mentioned them because it never looked.  A node removed
        while Running is supposed to end up with no data at all, so scan what is
        actually on disk instead of what the case expected to be there.
        """
        script = f"""
set -e
d={shlex.quote(self.cfg.get('DB_DIR'))}
base="$d/data/datanode/data"
for kind in sequence unsequence; do
  root="$base/$kind"
  [[ -d "$root" ]] || continue
  for db in "$root"/*/; do
    [[ -d "$db" ]] || continue
    for reg in "$db"*/; do
      [[ -d "$reg" ]] || continue
      n=$(find "$reg" -type f 2>/dev/null | grep -c . || true)
      [[ "$n" == "0" ]] && continue
      bytes=$(du -sk "$reg" 2>/dev/null | cut -f1)
      sample=$(find "$reg" -type f 2>/dev/null | head -2 | tr '\\n' '|')
      printf 'DATA=%s/%s FILES=%s KB=%s SAMPLE=%s\\n' \\
        "$kind" "$(basename "$(dirname "$reg")")/$(basename "$reg")" "$n" "$bytes" "$sample"
    done
  done
done
obj="$base/object"
if [[ -d "$obj" ]]; then
  for reg in "$obj"/*/; do
    [[ -d "$reg" ]] || continue
    n=$(find "$reg" -type f 2>/dev/null | grep -c . || true)
    [[ "$n" == "0" ]] && continue
    bytes=$(du -sk "$reg" 2>/dev/null | cut -f1)
    printf 'OBJ=region-%s FILES=%s KB=%s\\n' "$(basename "$reg")" "$n" "$bytes"
  done
fi
exit 0
"""
        res = self.ssh.run_script(host, script, check=False)
        problems: list[str] = []
        dirs = 0
        files = 0
        kb = 0
        detail: list[str] = []
        for line in res.out.splitlines():
            if not (line.startswith("DATA=") or line.startswith("OBJ=")):
                continue
            where = line.split("=", 1)[1].split()[0]
            try:
                n = int(line.split("FILES=")[1].split()[0])
                k = int(line.split("KB=")[1].split()[0]) if "KB=" in line else 0
            except (IndexError, ValueError):
                continue
            dirs += 1
            files += n
            kb += k
            sample = ""
            if "SAMPLE=" in line:
                sample = line.split("SAMPLE=", 1)[1].strip()
            if len(detail) < 4:
                detail.append(f"{where} ({n} files, {k} KB)")
        if dirs:
            problems.append(
                f"removed DataNode {host} still holds data in {dirs} directory/ies "
                f"({files} files, {kb} KB in total) that no longer belongs to it: "
                + "; ".join(detail)
            )
        return problems

    def _scan_removed_dn_data(
        self, host: str, script: str
    ) -> list[tuple[str, int, str]]:
        """One snapshot of the removed DataNode's region files."""
        res = self.ssh.run_script(host, script, check=False)
        rows: list[tuple[str, int, str]] = []
        for line in res.out.splitlines():
            if not line.startswith("REGION=") or "FILES=" not in line:
                continue
            region = line.split("=", 1)[1].split()[0]
            files_raw = line.split("FILES=")[1].split()[0]
            paths = ""
            if "PATHS=" in line:
                paths = line.split("PATHS=", 1)[1].strip()
            try:
                files = int(files_raw)
            except ValueError:
                files = 0
            rows.append((region, files, paths))
        return rows


def _brief_paths(paths: str, limit: int = 5) -> str:
    """Render the leftover file list for a problem message.

    Paths are pipe-separated (the shell side uses '|' precisely so that spaces
    in a path cannot split the record) and the whole list is capped, because a
    problem string is copied into summary.tsv and must stay one line.
    """
    items = [p for p in paths.split("|") if p.strip()]
    if not items:
        return "(names not captured)"
    shown = items[:limit]
    extra = len(items) - len(shown)
    text = ", ".join(shown)
    if extra > 0:
        text += f", ... (+{extra} more)"
    return text
