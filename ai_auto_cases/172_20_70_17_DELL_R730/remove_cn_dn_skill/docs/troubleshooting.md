# Troubleshooting

Start with the read-only commands; they never change the cluster.

```bash
scripts/rcdn.sh selftest                       # parsers, case matrix, config loading
scripts/rcdn.sh --conf conf/cluster.conf doctor
```

`doctor` exits `2` and lists every problem it found. Below, the message you get
and what it means.

---

## Preconditions

**`host X is not reachable on the ssh port` / `cannot ssh into X`**
No SSH from the driver. Check `SSH_USER`, `SSH_PORT`, and that
`conf/nodes.conf` really lists the current cluster. With `SSH_MODE=password`
the driver needs `sshpass`, or OpenSSH 8.4+ for the `SSH_ASKPASS` fallback;
`ssh -v` shows which path was taken. Verify by hand:
`ssh -o BatchMode=yes $SSH_USER@host true`.

**`X: passwordless sudo is required to start/stop and wipe IoTDB`**
`sudo -n true` failed on that host. The skill needs `NOPASSWD` for the start
and stop scripts, `jps` and `rm -rf`. Fix `/etc/sudoers.d/` on the cluster
hosts — the skill deliberately uses `sudo -n` so it fails immediately instead
of consuming the rest of the remote script as a password.

**`CLI_HOME=... does not contain sbin/start-cli.sh on this machine`**
`CLI_HOME` must point at an IoTDB install on the **driver** machine. Leave it
empty to use each node's own `$DB_DIR/sbin/start-cli.sh` over ssh (recommended).

**`/data/.../conf/iotdb-system.properties` MISSING**
`DB_DIR` is wrong on that host, or the install is elsewhere. `doctor` prints
the directory it checked.

**`BM_HOME ... does not contain benchmark.sh`**
`BM_HOME` must be the iot-benchmark root **on this machine** and must contain
`benchmark.sh` and `conf/config.properties`.

**`benchmark objects were not created within Ns`**
The load started but the schemas never appeared. Almost always a benchmark
config problem rather than a cluster problem — read
`results/<run>/benchmark/<workload>/`:

* `IoTDB_DIALECT_MODE` unsupported → upgrade iot-benchmark;
* `OBJECT` missing from the datatype proportion → cannot run the 11-type table
  workload;
* wrong `HOST`/`PORT` → the benchmark is talking to another cluster;
* check `results/<run>/benchmark/<workload>/*.log` for connection errors.

The runner discovers the real database and table names from `SHOW DATABASES`
and `SHOW TABLES DETAILS`, so a mismatch between `BM_TREE_DB`/`BM_TABLE_DB` and
the names iot-benchmark actually creates shows up here.

---

## SQL

**Every statement returns something and the CLI still exits 0**
Known behaviour: `start-cli.sh -e` exits 0 even on error. The skill never
trusts the exit code; `looks_like_sql_error` looks for `Msg:`, `Exception`,
`Error`, `StatementExecutionException`. If you add statements of your own,
route them through the same helper.

**`Unknown database usr_sod0`**
`SHOW DATABASES` is dialect scoped. The tree dialect lists `root.<db>...`; the
table dialect lists `<db>_<group>`. The skill queries both. If the benchmark has
not created the database yet you are simply too early.

**`SHOW MIGRATIONS did not become empty after the remove`**
A procedure is stuck. Inspect it before assuming a bug:

```
show migrations;
show regions;
show datanodes;
```

A migration that keeps reappearing generally means a destination DataNode is
down, ReadOnly or out of disk. If an abnormal operation stopped a node, the
runner restarts it during the healing step; if it still will not drain, the
cluster genuinely cannot finish the procedure.

---

## Benchmark built for the other database line

**Symptom.** The run starts, the cluster looks healthy, and then every benchmark
client fails at connect time -- typically an unknown dialect, a missing class, or
a session error. Nothing in the cluster logs explains it.

**Cause.** iot-benchmark publishes one package per database line and they are not
interchangeable:

| database | package | client jars inside |
|---|---|---|
| 2.x | `iot-benchmark-iotdb-2.0-java17.zip` | `iotdb-session-2.0.x` |
| 1.x | `iot-benchmark-iotdb-1.3-java17.zip` | `iotdb-session-1.3.x` |

A 2.0 build installed against a 1.x database passes every structural check --
`benchmark.sh` is there, `lib/` is full of jars -- and only fails once it tries to
use them. Conversely a 2.0-only build has no `iotdb-1.3` module at all, so a 1.x
run cannot work no matter how it is configured.

**Check.**

```bash
scripts/rcdn.sh --conf conf/cluster.conf doctor          # reports the mismatch
ls $BM_HOME/lib | grep iotdb-session                     # which line is installed
```

`doctor`, `run` and `matrix` all refuse to proceed on a mismatch; `run`/`matrix`
exit non-zero before touching the cluster.

**Fix.** Install the matching package, then re-run:

```bash
scripts/rcdn.sh --conf conf/cluster.conf benchmark --install
```

This reads the version from `DB_VERSION`, or from `DEPLOY_TARBALL` / `DB_DIR`.
If the version cannot be determined (an install directory like
`v20121rc2_0914_0b4dc9a` has no dotted version), the skill says so instead of
guessing -- set `DB_VERSION` explicitly.

## Sync lag

**`the sync-lag gate will be skipped (MONITOR_URL not configured)`**
Set `MONITOR_URL`. Without it a case can only claim "consistency passed", not
"replication converged" — mark such a result as partial when you report it.

**`syncLag did not stay at 0 for 120s within 3600s (last samples: [...])`**
Either the cluster is genuinely behind, or the expression is reading the wrong
series. Check by hand:

```
curl -s -u admin:admin --get --data-urlencode \
  'query=sum(iot_consensus{name="ioTConsensusServerImpl",type="syncLag"}) by (instance)' \
  http://<monitor>:9090/api/v1/query
```

The `instance` label is `<ip>:<port>`; the skill anchors the regex on the
Running DataNode IPs of *this* cluster, so a second cluster in the same
Prometheus is not picked up. If your build uses IoTConsensusV2 set
`CONSENSUS_METRIC=iot_consensus_v2`; `auto` tries V1 then V2.

**`no Running DataNode to read syncLag from`**
All DataNodes are down. That is a cluster problem, not a monitoring problem.

**`syncLag cannot drain: <host> is readonly (waiting further would only time out)`**
The gate gave up in seconds instead of burning `SYNC_MAX_WAIT_SEC` (an hour by
default). A ReadOnly DataNode stops advancing its sync position, so its lag
never returns to 0 and waiting cannot possibly help — the gate now checks
`_unsyncable_nodes()` every 30 s and fails fast with the real reason. Fix the
node (see *ReadOnly is persistent* under Lifecycle) and re-run the case.

**A frozen `worst=` value repeated across polls**
Treat a lag that never changes as a stall, not as slow convergence. Example
from the rc2 run:

```
sync lag: instances=18 worst=60465.0
sync lag: instances=18 worst=60465.0
```

60465 is a stale *timestamp difference*, not a backlog: the node had been
ReadOnly for 16 hours of wall-clock-equivalent, so the figure was pinned. Note
also `instances=18` rather than 24 — the ReadOnly node contributes no syncing
series, which is the first hint that the problem is a node state, not lag.

---

## Replica consistency

**`replica inconsistency: '<name>' result differs while <ip> is down`**
A real finding. Reproduce it before filing:

1. the raw and normalised snapshots are in
   `results/<run>/cases/<case>/` — the all-online baseline is `baseline_*.norm`,
   the degraded one is `stop_<ip>_*.norm`;
2. `diff` them to see which device or column moved;
3. re-run just that case: `run --case <id>`.

Before believing it, rule out the benign causes: the workload still writing
(normalised counts should be identical because both snapshots are taken with
the same statement — but if the load was still *deleting* rows the counts can
legitimately differ; the runner stops the benchmark before the sweep for this
reason), and `CONSISTENCY_SETTLE_SEC` being too small for the cluster to notice
the node went down.

**`only N Running DataNode(s); cannot stop one and still query`**
Fewer than two DataNodes were left Running, so the "stop one, compare against
the all-online baseline" method has nothing to compare. Expected for
`dn_multi_remove` / `rf_limit` when they finish at `rf=1`.

**`DataNode <ip> did not stop`**
`stop-datanode.sh` ran but the process was still alive when the stop timeout
expired. The sweep abandons that node and restarts it. Genuinely different from
the case below: here the process really is still up.

**`note: <ip> still reads Running after its process stopped (heartbeat has not
expired yet)`**
Not a failure, and deliberately only a note. The sweep's hard requirement is
that the process goes away (`stop_node` confirms that); whether `SHOW DATANODES`
has caught up depends on when the ConfigNode's heartbeat for that node expires,
which is a product-internal timer. Measured on 3C5D rc2: four nodes flipped
within ~30 s, one co-located CN+DN took >180 s. Treating that lag as a failure
produces false alarms, so the wait is bounded and advisory.

**`stop-one-node sweep skipped: data_replication_factor=N leaves no second copy
to query`**
The case ran with `data_rf=1` (e.g. `dn_running_remove_1rep`). With a single
replica there is no other copy: stopping whichever node owns a region
necessarily makes that region unreadable, so the stop-and-compare sweep cannot
say anything. The all-online baseline is still captured and compared, and a
`consistency_sweep_skipped.txt` marker is written into the case artifacts.

**`SKIP: ... cannot simulate a full disk on <host>: the volume is already NN% free ...`**
The `diskfull` selector / `other_dn_diskfull` op needs the DataNode to turn
ReadOnly, which happens when the free-space *ratio* drops to or below
`disk_space_warning_threshold`. The skill produces that state by raising the
node's threshold above its real free ratio (see *Simulating a full disk* below),
which needs a legal value left in `[0, 1)`. If the volume is already fuller than
`0.999` there is no such value and the case is not reproducible at all — the
skill says so with the measured percentage rather than reporting a failure for a
state it never reached.

To actually reproduce it, make the volume small enough to fill (a loop device
mounted for the DataNode's data dirs), or lower
`disk_space_warning_threshold` on the node so the cap crosses it.

---

## Logs

**`unexpected log lines on <host> (<role>): at least N hit(s), first: ...`**
The scan matched a known-bad pattern. `LOG_SCAN_MODE=full` scans the whole log
(correct after `prepare` wipes it); `since` only looks at lines newer than the
case start. The matched line is quoted in the problem so you can judge it.
Add project-specific patterns with `LOG_EXTRA_PATTERNS` (ERE, `|` separated).

**A rotated log cannot be matched**
Logs are read with `zcat` for `*.gz` and `cat` otherwise, so nothing needs to
be decompressed first — and nothing is modified. The `since` filter needs a
`YYYY-MM-DD HH:MM:SS` prefix on the line; a log format without one falls back
to matching everything.

**Where is the log backup?**
`results/<run>/log_backup/<case>_<timestamp>/<host>_<role>.tar.gz`, and the
path is recorded in `summary.tsv`. `LOG_BACKUP=fail` (default) backs up only
failing cases, `always` backs up every case, `never` disables it.

**Where are the migration-failure logs?**
`results/<run>/node_logs/<role>_<host>/log_datanode_all.log` (plain text, one
directory per node, plus `meta.txt`). `NODE_LOG_BACKUP=fail` (default) copies
them when a **migration-class** case fails — case ids containing `remove`,
`migrate`, `object`, `drain` or `scale`; `NODE_LOG_BACKUP_SCOPE=all` widens it
to every failing case. This exists because the next case's `prepare` resets
`<DB_DIR>/logs`: without it, the `SnapshotTaker` stack that explains a failed
`MIGRATE REGION` is gone before anyone can look (measured 2026-10-29 on RC11).

---

## Lifecycle

**ReadOnly is persistent — a restart does NOT clear it**
`set system to readonly on local;` writes a state that the DataNode reloads on
start-up, so restarting a ReadOnly node brings it back ReadOnly. Heal it with
the counterpart statement instead:

```sql
set system to running on local;
```

The status values come from `org.apache.iotdb.commons.cluster.NodeStatus`, which
is exactly `{Unknown, Running, ReadOnly, Removing, DiskFull}`, and the SQL
keyword is case-insensitive (the running system accepts lowercase `readonly`).
Verify against a build by dumping the enum out of the server jar:

```bash
unzip -p $DB_DIR/lib/timechodb-server-*.jar \
  org/apache/iotdb/commons/cluster/NodeStatus.class | strings | \
  grep -E '^[A-Z][A-Za-z_]{2,12}$'
```

Getting this wrong is expensive and *self-inflicted*: the heal restarted the
node, waited out `CLUSTER_START_TIMEOUT_SEC` (900 s) and then reported
`DataNode <host> did not come back to Running after the case` — a failure the
heal itself caused. The node was then left ReadOnly, which in turn stalled the
sync-lag gate (see *Sync lag*). If a case reports that message, check whether
the node is ReadOnly before blaming the DataNode.

**Removing a data directory by hand is part of decommissioning a *down* node**
A DataNode removed while it is Running deletes its own region files. A DataNode
removed while it is **stopped** does not, and cannot be made to: IoTDB refuses
to start it again and says so in its own log —

```
StartupException: Reject DataNode restart. Because there are no corresponding
DataNode(whose nodeId=7) in the cluster. Possible solutions are as follows:
  1. Maybe you've already removed the current DataNode(whose nodeId=7).
     Please delete the useless 'data' dir and retry start.
```

So `dn_unknown_remove` asserts the *guard* (the restart must be refused within
`REMOVED_NODE_RESTART_PROBE_SEC`), not auto-cleanup the product never promises.
Operationally: before reusing that host, wipe its `data/` directory — its
regions are still on disk and nothing will reclaim them. Asserting cleanup here
is a mistake; waiting for the refused start is also a mistake, and cost 15
minutes per run until it was understood.

**`remove is not progressing: <X>Procedure has been stuck for Ns on <host>`**
The remove can never finish, so the wait was cut short instead of running out
`REMOVE_MAX_WAIT_SEC` (2 hours). The ConfigNode logs the underlying condition
once every 30 s:

```
WARN ProcedureExecutor$WorkerMonitor:993 - Worker stuck
ProcedureCoreWorker-5(pid=36)(RemoveRegionPeerProcedure), run time 583206 ms
```

The known cause is a **lost quorum on a region membership change**: the region's
replicas include the node being removed *and* a node that is ReadOnly, so the
surviving holders cannot commit the change. Check where the region lives —

```bash
grep -a "DataRegion, id:<N>)" $DB_DIR/logs/log_confignode_all.log | tail -2
# DataRegion, id:6): [3, 6, 7] -> [7, 6, 3]
```

— and whether one of the surviving nodes is ReadOnly. It is **intermittent**:
it needs the ReadOnly node to be a surviving replica holder of a region being
moved, so a re-run after a cluster reset may pass. Clear the ReadOnly state
(`set system to running on local;`) and try again; `PROCEDURE_STALL_SEC=0`
disables the check if you would rather wait it out.

**`the cluster did not become healthy`**
`prepare` started the nodes but `SHOW CLUSTER` does not list 3 CN + 5 DN as
Running. Check, in order: the license (`LICENSE_SRC`), `iotdb-system.properties`
(`cn_seed_config_node`, `cn_internal_address`, `dn_rpc_address`), the heap sizes
in `confignode-env.sh` / `datanode-env.sh`, and `$DB_DIR/logs/*.log` on the node
that did not come up. Raise `CLUSTER_START_TIMEOUT_SEC` for slow disks.

**`discover --from-cluster` fails with "could not read the cluster topology"**
The cluster is not running, so no ConfigNode answered. Use
`discover --from-inventory`, or write `conf/nodes.conf` by hand.

**`discover --from-inventory` reports `no IoTDB role detected`**
On a cluster that has never started there is no local state to detect: no
`data/confignode`, no `data/datanode`, no logs, no listening ports, and the
shipped `iotdb-system.properties` has both `cn_internal_address` and
`dn_rpc_address` uncommented on every host, so the file alone cannot tell the
roles apart. Write `conf/nodes.conf` by hand — `conf/cluster.conf.example`
documents the format.

**`prepare` / `matrix` deleted my data**
Yes, by design: they stop every node, `rm -rf data/ logs/`, rewrite
`iotdb-system.properties` and restart. Only ever point them at a disposable
test cluster.

---

## Diagnosing a crash in the driver

**`case aborted: ...`**
The Python exception is recorded in `problems` and the traceback in `steps` of
`cases/<case_id>/result.json`. The cluster is left as it was; run
`teardown` or `prepare` to get back to a known state.

**Remote command hangs**
Every remote call has a timeout; `SSH_TIMEOUT`-style hangs come from a process
that will not die. `stop_node` escalates to `kill -9` after
`CLUSTER_STOP_TIMEOUT_SEC`. If a node still will not die, `kill_node host role`
does it directly (used by `kill9_*` operations).

**`removed DataNode <host> started again although it is no longer a cluster member`**
Only ever raised for a target removed with `selector=unknown` (it was stopped on
purpose). IoTDB is supposed to refuse that restart outright, so a success here is
a real finding: the node may rejoin and serve data it no longer owns. The check
keys off the *case selector*, not off the process table — inferring "it was
stopped when removed" from `_process_running` was tried and produced a false
alarm on a happily-Running target the moment one `jps` call hiccuped
(`dn_remove_other_diskfull`), so if you extend this logic, take the intent from
the case. A Running target whose process has vanished is reported separately.

**Statement timeouts on huge queries**
Raise `CONSISTENCY_QUERY_TIMEOUT_SEC` (the CLI `-timeout` value) — a
`select count(...) from root.**.align by device` over many devices with a node
down can take a long time to fail over.

**`case aborted: failed to update ... : ssh: connect to host <ip> port 22:
Connection refused` — and every case after that aborts in seconds**
The driver's IP has been banned by the cluster hosts' brute-force protection.
This is a *driver* problem, not a cluster fault, and it is worth recognising
because the symptom looks like the cluster dying.

It happened on the 3C5D rc2 run: after ~12 cases (about 3.5 h) all five hosts
began refusing port 22 to the driver, while the nodes themselves kept running.
It lifted by itself ~10 minutes later (the usual default bantime).

Tell a ban from a dead sshd before touching anything:

```bash
# from the driver: refused?
ssh -o ConnectTimeout=6 user@<cluster-ip> 'echo up'      # -> Connection refused
# is anything else on that host still listening?  (a ban is usually port-22 only)
timeout 4 bash -c 'echo > /dev/tcp/<cluster-ip>/10710'   # -> OPEN means the box is fine
# and from a *third* host that is not banned:
ssh user@<other-host> 'timeout 4 bash -c "echo > /dev/tcp/<cluster-ip>/22" && echo OPEN'
```

If a third host sees port 22 OPEN, sshd is fine and it is an IP ban. **Do not
route around it with a ProxyJump** — that defeats a security control; get the
driver IP unbanned instead (on the host: `fail2ban-client set sshd unbanip
<driver-ip>`, or add it to the jail's `ignoreip`).

The cause is connection *volume*: `SshRunner` used to start a fresh `ssh` for
every command, and one case issues hundreds of them (sync-lag polling every
10 s, node-status polling every 3 s, migration waits). The fix is on by default
— one multiplexed connection per host:

```
SSH_MULTIPLEX=true          # ControlMaster=auto + ControlPath + ControlPersist
SSH_CONTROL_PERSIST=300     # seconds an idle master stays open
```

Measured against a real host: first command 0.36 s (full handshake), the next
twelve averaged **12 ms** each, using exactly **one** TCP connection. If a site
forbids multiplexing, set `SSH_MULTIPLEX=false`, but then expect a long matrix
to look like a brute-force attempt and plan for the ban.

## A pinned syncLag: stale region metric or a live stalled pipeline?

`syncLag` is scraped per region from each DataNode's `/metrics`
(`iot_consensus{...,region="DataRegion[N]",type="syncLag"}`).  The gate fails
when the maximum stops moving, because a real backlog changes as replication
progresses.

That symptom has **two causes that need opposite responses**:

1. **A live stalled pipeline** — the region still exists and its replicas are
   up, but replication has stopped.  This is a product defect worth reporting.
2. **A stale gauge from a removed replica** (confirmed upstream root cause: `DispatcherThread` removal does not unbind its metrics) — a DataNode removal can leave a
   `logDispatcher` to the removed peer (with a full
   `cachedRequestInMemoryQueue`, observed at its 4096 cap) and a frozen
   `syncLag` behind for a region that has already been dropped.  Nothing is
   stuck: the region is simply gone.  All *live* regions report `syncLag = 0`.

Run `rcdn diag --conf <conf>` for the whole picture in one shot: it prints, per
node, the lagging regions, each dispatcher's peer, whether that peer is still a
live DataNode, the queue depth, and how many driver threads remain.

The gate also prints the worst region(s) and checks them against
`show regions`, so its message distinguishes the two.  When investigating by
hand:

```bash
curl -s http://<dn>:9092/metrics | grep 'type="syncLag"'
curl -s http://<dn>:9092/metrics | grep cachedRequestInMemoryQueue
show regions      # does the pinned region still exist?
```

Never conclude "replication is broken" from the aggregate maximum alone: break
it down by region and confirm the region still exists first.  Reporting a stale
gauge as a data-synchronisation defect sends the wrong team after the wrong
bug.

### Two traps that produced wrong conclusions

Both of these cost real time on a genuine defect; check them before trusting a
diagnosis.

1. **Never pair `starts`/`exits` counts to detect a leaked dispatcher.** In a
   healthy running cluster every (region, peer) pair legitimately keeps exactly
   one dispatcher open, so `start=2 exit=1` is *normal* and also true for peers
   that are alive.  Counting makes the leak invisible.  Instead look at what
   happened **after** the removal event: if a dispatcher targeting the removed
   peer never logs an `exits`, it was never closed.
2. **`jstack` is usually absent from these images.** It fails with
   `command not found`, and because the failure is piped into `grep -c` the
   result is a silent `0` that reads as "no threads" -- the opposite of the
   truth.  Use the JDK-free equivalent, and keep the total thread count next to
   it so a zero is meaningful:

   ```bash
   for t in /proc/<java_pid>/task/*; do cat $t/comm; done | grep -c LogDispatcher
   ```

   Find the DataNode java pid via its wrapper, since `pgrep -f` on the main
   class often matches nothing:

   ```bash
   w=$(ps -eo pid,args= | grep '[s]tart-datanode.sh' | awk '{print $1}' | head -1)
   pgrep -P "$w"
   ```

### Known issue: dispatcher metrics are not unbound on removal

R&D confirmed this is a small upstream defect: when a `DispatcherThread` is
removed, its monitoring meters are **not unbound**, so the per-region gauges
(`syncLag`, `cachedRequestInMemoryQueue`, `pipelineNum`) keep being exported
with their **last observed values**.

Consequences to keep in mind when reading results:

* `syncLag` for such a region never reaches 0 -- a convergence gate will hang
  or a dashboard stays red until the process restarts.
* Values like a full `cachedRequestInMemoryQueue=4096` are **stale readings, not
  retained memory**; there is no leak and no data risk. The thread itself is
  gone (confirm with the `/proc` thread sweep above).
* Treat it as a **test-harness/environment consideration**, not a data-correctness
  failure: do not fail a case solely on a pinned `syncLag` without checking
  whether the region still exists.

### Expected benchmark errors: 722 CANNOT_FETCH_FI_STATE

Stopping or restarting the DataNode that is *serving* a statement fails that
statement with `722 CANNOT_FETCH_FI_STATE`.  R&D confirmed this is documented
behaviour: the state of an in-flight fragment on a dying node cannot be
fetched, and retrying the same instance cannot help.

That code reaches the client with **two different texts**, depending on which
path raised it, and they are not interchangeable:

| path | text |
|---|---|
| schema fetch (`DataNodeQueryMessages`) | `Fetch Table Device Schema failed because ...` |
| MPP fragment state (`FixedRateFragInsStateTracker:185`) | `Failed to fetch state, has retried N times, may be caused by DN restarting.` |

A 2026-09 measurement caught the trap: an allowlist written only for the first
text matched **0 of 190** real error lines, so it silently excused nothing and
cases kept failing on a behaviour R&D had already accepted.  The default
therefore also matches the status code (`722:`), which is phrasing-independent.
`selftest` asserts both real texts.

So a case must not fail because of it.  `EXPECTED_BENCH_ERRORS` lists errors
that are reported but excluded from the verdict; set it to empty to treat every
benchmark error as a failure again.  Note this is a **global** allowlist -- it
does not know which case is running -- so the report should still list where
the 722s occurred rather than letting the exclusion hide them.

Do **not** report this as a defect, and do not propose adding 722 to the
retryable set.  R&D explained the contract: a query is never retried
transparently, because the client may already have consumed part of the result
set (100 rows fetched cannot resume at row 101), so every query failure is
raised to the business layer, which decides whether to re-run.  The mechanism
matches that contract -- retryability is a per-code decision the *server* makes
by setting the status `needRetry` flag (`ErrorHandlingUtils:88` ->
`StatusUtil.needRetry`), which the client merely obeys
(`IoTDBStatement.callWithRetryAndReconnect`); 722 is in neither `NEED_RETRY` nor
`UNKNOWN_ERRORS`, so the flag stays unset.  `SYNC_CONNECTION_ERROR` and
`PLAN_FAILED_NETWORK_PARTITION` *are* retryable -- the difference is deliberate.

Two details make the filter non-trivial, and both are covered by a selftest:

* The benchmark reports one failure **twice** -- once with the cause in the
  stack, once as a `DBWrapper:793 - Execution fail:` summary whose stack is only
  `java.lang.Exception: Failed to execute.` and swallows the cause.  Reports are
  therefore classified per log block, and a summary is credited to an expected
  cause reported within `SUMMARY_CORRELATION_WINDOW_SEC` (5 s).
* A block can start on a stack frame, which carries no timestamp, so it
  inherits the time of the log record it belongs to.

### Stopping a DataNode: what to expect in the first seconds

Stopping a DataNode does **not** make the cluster treat it as down immediately.
`ConfigManager` only marks it Unknown once the failure detector fires --
`ConfigManager:615 - The DataNode-<id> will be shutdown soon, mark it as Unknown`.
With the defaults (1 s heartbeat, Phi accrual detector) this took ~7.7 s in one
measured run: the process was stopped at 19:10:38, statements failed with 722 at
19:10:42, and the node was marked Unknown at 19:10:45.

So statements issued in that window are routed to a node the cluster still
believes is healthy, and they fail.  That is the failure-detection window, not a
routing bug -- do not report it as one, and do not expect replica failover to
have kicked in that early.  If a case needs a statement to succeed, let the node
be marked Unknown (or removed) first.

### Triaging from DataNode logs: the `Query Statement:` prefix is a fixed label

`ErrorHandlingUtils.onQueryException` formats its log line as

    Status code: %s, Query Statement: %s failed because %s

so the literal text `Query Statement:` says nothing about the statement type --
whatever was passed as `operation` is printed after it.  A table-model
`insertTablet` that fails while fetching the device schema is reported through
this same handler (`ClientRPCServiceImpl:2945` passes
`OperationType.INSERT_TABLET.getName()`, i.e. `insertTablet`), producing

    Status code: 722, Query Statement: insertTablet failed because
    Fetch Table Device Schema failed because FragmentInstance[...] is failed

Do not read that prefix as "this was a query": read the text after it.  Note
also that the sibling handler `onIoTDBException` uses a *different* template
(`[%s] Exception occurred: %s failed. %s`), which `ClientRPCServiceImpl` picks
for `IoTDBException` and `onQueryException` for any other exception -- so the
same logical failure can appear under either wording depending on the exception
type.

### ConfigNode quorum: what a fault combination is allowed to expect

The ConfigRegion replica set *is* the ConfigNode set, so the cluster's own
availability floor is `members // 2 + 1`:

| ConfigNodes | after removing one | quorum | a further fault leaves |
|---|---|---|---|
| 3 | 2 | 2 | 1 of 2 -- **below quorum, outage expected** |
| 5 | 4 | 3 | 3 of 4 -- still quorate, errors stay failures |

R&D confirmed the consequence: *at two ConfigNodes a restart cannot be made
highly available*, so removing one of three and then restarting or killing
another **must** fail, and those errors are not defects.  That is why the
matrix's `cn_follower_remove_restart` (3C: remove a follower, then restart
another) cannot test availability as written -- and why `CN_BELOW_QUORUM_EXPECTED_OUTAGE`
(default true) only excuses errors *inside* the measured down-window.

Do not over-apply this.  A bare removal with every node still alive keeps
quorum, and so does a 1-member ConfigRegion (quorum 1).  Verified against one
run, a ~5 s window of `301: The consensus group ConfigRegion[0] doesn't exist`
appears on **every** ConfigNode removal with **all** ConfigNodes alive -- that
one is a genuine finding, not an expected outage, and it is exactly what R&D's
own first hypothesis ("the partition-table retry logic") points at.

To test the remove-plus-fault combination for real, run the ConfigNode cases on
**at least five ConfigNodes**: 5C -> remove one -> 4C, where a further fault
still leaves a majority.

### Simulating a full disk without writing to the volume

A DataNode goes `ReadOnly` with `statusReason=DISK_FULL` through:

```
JVMCommonUtils.hasSpace(dir)      ->  getDiskFreeRatio(dir) > disk_space_warning_threshold
        all folders fail          ->  DiskSpaceInsufficientException
        ->  FolderManager.changeToReadOnlyIfDiskFull()
        ->  setNodeStatus(ReadOnly) + setStatusReason(DISK_FULL)
```

Because the test is a **ratio**, a multi-terabyte volume is hopeless to fill (a
5% floor on 18.5T is ~928G).  Raising the node's own
`disk_space_warning_threshold` above its real free ratio instead makes
`hasSpace()` fail for every folder, so the node takes the **identical** path to
`ReadOnly`/`DISK_FULL` with **zero bytes written**.

```
# free/total == 62%, so any threshold above 0.62 works (must stay inside [0,1))
# The `ON <nodeId>` clause is MANDATORY -- see the warning below.
set configuration "disk_space_warning_threshold"="0.67" on 7;
# ... the node goes ReadOnly(DiskFull) on its next *write attempt*
set configuration "disk_space_warning_threshold"="0.05" on 7;   # it returns to Running
```

> **Always scope the change with `ON <nodeId>`.**  The clause is *optional* in the
> grammar (`IoTDBSqlParser.g4:1326`:
> `SET CONFIGURATION setConfigurationEntry+ (ON INTEGER_LITERAL)?`), and omitting
> it applies the change **cluster-wide**.  Measured 2026-09-18 on a live 3C5D
> cluster: an unscoped raise made **all five DataNodes** adopt the threshold and
> go `ReadOnly(DiskFull)` together, so the case exercised "the whole cluster is
> disk-full" instead of "one other DataNode is disk-full" -- a far more severe
> scenario -- and produced ~350 client write errors that were purely an artefact
> of the leak.  `Remover.disk_threshold_statement()` enforces the clause and
> refuses to issue the statement at all when the node id cannot be resolved.

Notes that cost time to learn (all verified on a live 3C5D cluster):

* **The transition needs a write, not a timer.** `changeToReadOnlyIfDiskFull`
  hangs off the *allocation* path: the node turns ReadOnly when a write tries to
  place a file and `hasSpace()` rejects every folder. Measured: with a writer
  running, all four DataNodes flipped after **5 inserts**; on an idle cluster the
  same threshold change leaves the node `Running` forever. So a disk-full fault
  only makes sense while a benchmark is writing — the shipped cases always are.
* **Do not expect the periodic disk sampler to do it.** `sampleDiskLoad` in
  `DataNodeInternalRPCServiceImpl` does compare a free ratio against
  `disk_space_warning_threshold`, but the ratio comes from the *system-wide*
  `SYS_DISK_AVAILABLE_SPACE`/`SYS_DISK_TOTAL_SPACE` metrics — a different source
  from the per-directory `JVMCommonUtils.getDiskFreeRatio(DB_DIR)` the write path
  uses. Raising the threshold does not necessarily move that sampler at all.
* **The status string is `ReadOnly(DiskFull)`**, not `ReadOnly`. Any wait that
  compares the raw string against `readonly` times out although the node already
  transitioned — use `status_is(...)` / `split_status(...)`, which strip the
  `(qualifier)`. This bit the `diskfull` selector the first time it ran live.
* The property is **hot-reloadable** -- `IoTDBDescriptor.loadHotModifiedProps`
  refreshes the static copy in `JVMCommonUtils` that the guard reads, so no
  restart is needed.  `ConfigManager.checkConfigNodeGlobalConfig` also mentions
  the property, but that is a ConfigNode *registration* check, not a ban on
  changing it at runtime.
* `set configuration` **persists** to the node's `conf/iotdb-system.properties`
  (appending or rewriting the line), so **a raise that is never undone outlives
  the case, the process and the cluster reset.**
* **A leaked raise is not self-correcting, and it hides well.**  This was learned
  the hard way on 2026-09-18.  The sequence was:

  1. An unscoped raise set the threshold on **every** DataNode.
  2. The case then drove the cluster into the very state it was testing, so its
     SQL connection was gone.
  3. The restore therefore **failed** --
     `note: could not restore the disk threshold on ...: SQL failed: show datanodes;
     Error: Can't execute sql because Connection Error` --
     and that failure was downgraded to a `note` on the strength of a docstring
     claim that "the per-case cluster reset rewrites `iotdb-system.properties`
     anyway".  **It does not.**
  4. One leaked raise left all five DataNodes with `disk_space_warning_threshold=
     0.6729`, every node flipped to `ReadOnly(DiskFull)` on the next write, and
     **eight consecutive cases were poisoned without a single warning**.  The
     first visible symptom was an unrelated case reporting
     `benchmark objects were not created within 900s` -- nothing in that message
     points at a disk threshold.

  The lesson is not "remember to restore": the restore *was* called.  It is that
  **a cleanup step that can fail must be verified, not assumed** -- especially
  when the case's own success condition is what broke it.

  Two guards now exist, and both are load-bearing:
  1. `Remover.restore_pending_disk_state()` is invoked at case teardown.
  2. `Cluster.clear_raised_disk_thresholds()` runs at **case start, before the
     cluster boots**, commenting out any active `disk_space_warning_threshold`
     line and logging a loud `WARNING: cleared a leaked ...` when it does.
     Commenting the line out *is* the restore, because the shipped default
     (`0.05`) applies when the key is absent.

  **When any case reports an unexplained setup failure, check this first:**
  ```
  grep -RE '^disk_space_warning_threshold' <DB_DIR>/conf/iotdb-system.properties
  ```
  Any *uncommented* line there means a previous case leaked a disk-full fault.
* Treat any other **persisted** `set configuration` in this skill the same way:
  undo it explicitly and verify, and never rely on the case reset to clean it.
* This is not the same scenario as `set system to readonly on local`: that sets
  ReadOnly directly and skips the disk guard, whereas the threshold route
  produces `statusReason=DISK_FULL`, which the ConfigNode treats specially
  (see `ConfigManager`'s `NodeStatus.DISK_FULL` checks).

## WAL recovery on a graceful restart: `Broken wal file …, size 6`

Measured on V2.0.12.1, 3C5D, `data_replication_factor=2`, five consecutive
**graceful** `stop-datanode.sh` / `start-datanode.sh -f` cycles under
iot-benchmark load.  **Every one of the five DataNodes** logged this on the way
back up:

```
WARN o.a.i.d.s.d.w.b.WALBuffer:858 - Fail to read memTable ids from the wal file
 0 of wal node lb_table_lb_table_0-28: Broken wal file …/_0-0-0.wal, size 6
```

Counts across the five DataNodes were 9 / 7 / 10 / 16 / 16.  **`size 6` is the
whole story**: the file holds nothing but the 6-byte `V3-WAL` head magic, which
is a legal state for a WAL file that was just created or already truncated.  The
reader disagrees:

```java
// WALMetaData.readFromWALFile:354
if (channel.size() < WALFileVersion.V2.getVersionBytes().length
    || !isValidMagicString(channel)) {
  throw new BrokenWALFileException(logFile);              // :357
}
long position = channel.size() - Integer.BYTES - version.getVersionBytes().length;
IOUtils.readFully(channel, metadataSizeBuf, position);     // 6 - 4 - 6 = -4
…
} catch (IllegalArgumentException e) {
  throw new BrokenWALFileException(logFile);               // :388
}
```

`6 - 4 - 6 = -4`, so the negative-position read raises
`IllegalArgumentException`, which is re-labelled `BrokenWALFileException`.
`WALBuffer.getMemTableIds` catches it, logs this WARN and **returns an empty
set**.  That is not a neutral answer: callers use those memTable ids to decide
whether a WAL file is still referenced, so "no memTables" is exactly the input
that lets a live WAL file be deleted.

**The 6-byte file is the writer's own output, not a damaged file.**  The source
says so directly — `WALWriter.endFile()` refuses to append anything to a file that
holds only the head magic:

```java
// WALWriter.endFile()
if (logFile.length() == version.getVersionBytes().length) {  // V3 -> exactly 6
  super.close();                                             // no tail magic, no metadata
  return;
}
```

A WAL node that is opened and rolled without ever receiving an entry therefore
ends up as a legitimate 6-byte file.  An inventory of a healthy cluster after five
restart cycles makes the scale plain: **84 of 100 `.wal` files were exactly 6
bytes** (17/16/17/17/17 across the five DataNodes), and **0** were shorter than 6
bytes.  So this WARN fires on the majority of WAL files a healthy node owns.

Note that `WALRepairWriter` does *not* agree with `WALMetaData` about these files:
it compares head magic to tail magic, and for a 6-byte file those are the same
bytes, so it declares the file **complete** and leaves it alone.  Only
`WALMetaData.readFromWALFile` calls it broken.

**This is a code bug, and it is a wrong constant.**  Four components touch the same
6-byte file and three of them accept it; the one that complains has the wrong
minimum size.  A complete WAL file is `[head magic][entries][END_MARKER][metadata]
[metadataSize:4][tail magic]`, so the smallest *complete* file already exceeds
`magicLen + Integer.BYTES`.  `WALInputStream` reads exactly that format, in the same
package, and guards correctly:

```java
// WALInputStream.getEndOffset():86  -- correct
if (channel.size() < WALFileVersion.V2.getVersionBytes().length + Integer.BYTES) {  // 6 + 4 = 10
  endOffset = channel.size();     // header-only file: zero entries, no exception
  return;
}

// WALMetaData.readFromWALFile:352  -- missing the + Integer.BYTES
if (channel.size() < WALFileVersion.V2.getVersionBytes().length                    // 6, should be 10
    || !isValidMagicString(channel)) {
  throw new BrokenWALFileException(logFile);
}
```

Because the guard passes a 6-byte file, the very next line computes
`position = 6 - 4 - 6 = -4` and the negative-position read becomes the "broken"
verdict.  The decisive point is that **aligning `WALMetaData` with `WALInputStream`
would lose nothing**: the reader that actually replays entries has *already* decided
that such a file has zero entries, so the exception protects no data — it only
manufactures a misleading WARN.

Severity, stated honestly: the *return value* is right either way, since a header-only
file genuinely references no memTable, so this bug alone causes **no data loss**.  What
it does cause is that `Broken wal file …` fires on the majority of healthy WAL files
and therefore stops meaning anything — and it makes the audit key
`WAL_metadata_read_failed` useless as a harness signal, which is how it was found
here.  The correct discriminator is the head magic, not the size.

**A separate, more dangerous path sits next to it** — do not merge the two.
`WALBuffer.getMemTableIds` funnels *every* `BrokenWALFileException` (and every
`IOException`) into `Collections.emptySet()`:

```java
} catch (BrokenWALFileException e) { logger.warn(…54B0056E…, e.getMessage()); }
  catch (IOException e)            { logger.warn(…D5287E27…, e); … }
return Collections.emptySet();
```

and the only caller reads an empty set as "references no active or pinned memTable",
which is one of the conditions `canDeleteFile` checks.  So a **genuinely corrupt,
non-empty** WAL file — one that still holds unpersisted data — returns the same empty
set as a legitimately empty one and can become eligible for deletion.  The `null`
return is handled conservatively; the empty return is not.  This is a code-path
observation, **not** a demonstrated deletion: `canDeleteFile` also requires
`fileArrIdx < fileIndexAfterFilterSafelyDeleteIndex` (or `CONTAINS_NONE_SEARCH_INDEX`)
and `versionId < subscriptionRetainedMinVersionId`.  It was not reproduced, and should
be reported as a risk to confirm, separate from the `size 6` false positive.

How to inventory WAL files on a node (cheap, and the only way to tell a real
anomaly from this false positive):

```bash
W=<db>/data/datanode/wal
find "$W" -name '*.wal' | wc -l                                  # total
find "$W" -name '*.wal' -size -6c | wc -l                        # shorter than a v3 magic
find "$W" -name '*.wal' -size -7c -size +5c | wc -l              # exactly the 6-byte case
for f in $(find "$W" -name '*.wal' -size +5c); do                # missing head magic
  m=$(head -c 6 "$f"); [ "$m" = V3-WAL ] || [ "$m" = V2-WAL ] || echo "NOMAGIC $f"
done
```

* Do not read this WARN as failing hardware — it fires on **every** restart of an
  otherwise healthy node, for every WAL node that happens to hold an empty file.
* It is **not** the `Unknown WALEntry type` failure: that one comes from
  `WALEntry.deserialize` and was **not** reproduced in this phase (0 occurrences
  over 5 DataNode cycles).  Both are WAL-file parsing defects, but they are
  different code paths and must be reported separately — do not merge them into
  one claim.
* Count it with the message, not the level:
  `grep -c WAL_metadata_read_failed <evidence>/log-checks/dn-*.audit.unexpected.log`.

## Table-model replica data differs when one DataNode is offline

Same run, same phase — the consistency sweep, and equivalently the tc2026
harness's `verify_replicas`: capture the all-online baseline, then stop each
DataNode in turn and re-run the identical queries through a survivor.

| DataNode stopped | tree | table |
|---|---|---|
| `.6` | matches | matches |
| `.7` | matches | **differs** |
| `.8` | matches | **differs** |
| `.9` | matches | **differs** |
| `.10` | matches | **differs** |

The tree model matched 5/5; the table model differed 4/5 — with
`data_replication_factor=2`, so every region still had a second copy online.  A
difference here means a read served from the surviving replica returned fewer or
different rows than the all-online baseline.  That is a correctness problem, not
a tolerance: with rf=2 and one of five DataNodes down, no query should notice.
Keep both artifacts and treat it as a real finding:

* the result sets themselves (`tree`/`table` × baseline/offline);
* the region inventory at that moment — comparing the *same* region on a
  different DataNode is the useful diff, so a row-level diff beats a row count.

Rule out two innocent causes first, both cheap: `SHOW REGIONS` per model right
after the stop (a region that never had two copies is a placement problem, not a
consistency one), and the sync-lag gate (a DataNode still catching up when the
baseline was captured makes the *baseline* wrong).

## Wiping `data/` can leave the cluster unactivated

`wipe()` deletes `data/` and `logs/` but keeps `activation/`.  On a build whose
runtime activation state lives under `data/`, the node comes back with:

```
ERROR com.timecho.ar:469 - Load license fail.
  org.apache.iotdb.commons.exception.LicenseException:
  This license is not allowed to activate this ConfigNode.
```

and only the seed ConfigNode ends up `ACTIVATED`; the others stay `ACTIVATED(W)`
or never rejoin.  The symptom surfaces much later and looks unrelated:
`REMOVE CONFIGNODE` is submitted, the procedure logs `Remove peer` /
`Delete peer` / `Stop and clear ConfigNode`, and then the node **stays in
`SHOW CLUSTER`** until the 600 s timeout.

`ensure_license()` cannot save you — it exits immediately when
`activation/license` already exists, and the wipe did not remove it.  So the
code must be re-submitted after every wipe; that is what `prepare` now does, and
`--no-activate` suppresses it.  Verify with `SHOW CLUSTER`: every ConfigNode must
read `ACTIVATED`, never `ACTIVATED(W)`.

A `01-…` code is machine-bound and seems to cover only a limited node set.  The
repository's `03-AAATKKLP-XREBT2T7-2QRCC===` trial code is not machine-bound and
activates every node, so when activation fails after a wipe, retry with the `03`
code before concluding the licence is bad.

## Running the `tc2026` release-note harness

`/data/iotdb/tc2026_releasenote_testcase/` ships a second, independent harness
(the `tc2026_*` shell scripts).  Three of its checks can stop a run before the
interesting phase, and none of them is a product defect:

* **The `remove cn` completion check cannot cope with a co-located ConfigNode and
  DataNode.**  `cn_topology_matches` counts a row as "the target is still there"
  with `if($a==target||$id==target_id)present++` — no type filter — so on a 3C5D
  cluster (ConfigNode and DataNode sharing `.7`/`.8`/`.9`) the *DataNode* on the
  removed ConfigNode's address keeps `present` at 1 for ever, and the removal
  times out at 600 s even though the ConfigNode left `SHOW CLUSTER` within
  seconds.  Scope the counter to the type:
  `if($t=="ConfigNode"&&($a==target||$id==target_id))present++`.  Confirm the
  removal really happened from the trail it writes
  (`remove-cn-<ip>-cluster.tsv.history`): the ConfigNode row disappears while the
  same address remains as a DataNode.
* **`sh -x` on a Debian/Ubuntu host.**  `clean_env/*.sh` use `function name()`
  and `[[ ]]`, so `sh -x` aborts with `Syntax error: "(" unexpected` under dash.
  Invoke them with `bash -x`.
* **`ensure_version_deployed` and `run_cli` run locally**, not on the remote
  hosts: the harness expects to run where a database deployment (a "shell
  client") and a benchmark build already exist.  A client-only unpack of the
  release zip under the harness's own directory satisfies it.

Two environment traps, both hit while doing this:

* **A burst of SSH connections gets the host banned.**  `configure_cluster` makes
  on the order of a hundred rapid connections; the network then answered
  `Connection reset` / `Connection refused` for three of five hosts while `sshd`
  was demonstrably still listening.  Route through one reachable host and
  multiplex — this is what let the run finish:
  `-o ProxyJump=root@<reachable-host>` together with
  `-o ControlMaster=auto -o ControlPath=<socket> -o ControlPersist=600`.
* **The harness must be able to see the cluster's JVMs.**  It reads process state
  to decide whether a node is up, so it has to run as the user that owns the
  processes; a non-root login reported "down" for nodes that were running.
  (`jps` also prints nothing until `/etc/profile` has been sourced, so a bare
  `jps -l` is not evidence either way.)

## `Unknown WALEntry type INSERT_ROW_PLAN`: the precondition, and why memory pressure does not create it

> **Resolved in part 3 (below).**  The precondition is a first byte of `0x00`, which is a
> *legal* enum code (`INSERT_ROW_PLAN`) that no build ever wrote; it means the file was
> **zeroed by storage damage**, not left behind by an old version.  Part 3 has the
> deterministic 3/3 reproduction.  Parts 1-2 are the ruled-out hypotheses.

Searched for, not found, on V2.0.12.1 running the tc2026 harness: **0 occurrences
across two full 3C5D runs**, five graceful `stop`/`start` cycles each, under
iot-benchmark load.  The matching negative is in the file inventory: **0 of 100
`.wal` files lacked the head magic**, and 0 were shorter than 6 bytes.  Treat the
precondition below as the thing to test for, rather than treating the workload as
the thing that produces it.

### The precondition is a WAL file with no V2/V3 head magic

`WALFileVersion.getVersion` recognises only the head magics `"V3-WAL"` and
`"V2-WAL"`, and falls back to **V1 for anything else** — and V1 has no head magic by
design ("head magic string starts to exist since V2").  `WALInputStream` then
positions the reader accordingly:

```java
if (version == V1) {
  // There is no head magic string in V1 version
  channel.position(0);                       // byte 0 is read as an entry type
} else {
  channel.position(version.getVersionBytes().length);
}
```

So on a header-less file **byte 0 is interpreted as a `WALEntryType` code**.  A
`0x00` there resolves through `WALEntryType.valueOf` to the **deprecated
`INSERT_ROW_PLAN`**, which `WALEntry.deserialize` does not handle, so it lands in
`default:` and throws `UNKNOWN_WAL_ENTRY_TYPE_WITH_VALUE`.  Keeping the 1.x codes in
the enum is what turns a stream misalignment into a confident, wrong type name —
`valueOf`'s own validity check still passes.  (Pure random bytes instead give
`Invalid WALEntryType code` — a *different* message, and a useful signal.)

### Why the file stays broken forever

`WALRepairWriter.repair` cannot fix this state; it locks it in:

```java
WALFileVersion version = WALFileVersion.getVersion(logFile);   // header-less -> V1
if (version.getVersionString().equals(readTailMagic(version))) return;
else truncateSize = metaData.getTruncateOffSet();              // read failed -> 0
channel.truncate(truncateSize);                                // wipes the file
try (WALWriter walWriter = new WALWriter(logFile, version)) {   // constructed with V1!
  walWriter.updateMetaData(metaData);
}
```

`LogWriter`'s constructor writes the head magic **only for V2/V3**, so rewriting with
V1 emits a header-less file whose first byte is metadata — typically `0x00`.  The
next recovery reads it as V1 again and reports the same error.  Measured over three
repair cycles: it re-triggers every time.

### Normal operation never produces the precondition

All three `new WALWriter(...)` sites were checked: both in `AbstractWALBuffer` (the
initial open at `:75` and the roll at `:129` via `new WALWriter(nextLogFile)`) use
the **single-argument** constructor, which defaults to **V3** and therefore always
writes the magic.  The only V1-writing path is `WALRepairWriter`, which needs a
header-less input to get there in the first place.  So the first header-less file has
to come from outside the normal write path — a 1.x-era WAL file in a reused or
in-place-upgraded `wal/` directory, an interrupted `FileChannel.open(CREATE)` before
the magic write, or a write failure at that moment.  All are one-off entry events,
which fits the failure being permanent and self-repeating once it starts.

A full disk, tempting as it is, is **not** one of them: both routes were measured and
closed — see *a full WAL volume does not produce it* below.

### The repair path destroys the evidence it would need

Worth knowing before spending effort chasing a live site: `readLastFileInfoAndRepairIt`
only ever repairs **the last WAL file of each WAL node**, and it repairs it by
`truncate(0)` followed by a rewrite.  So for that file the original bytes — the only
thing that identifies *how* it lost its magic — are erased by the product itself, on
the very first recovery.  Measured: 201 → 25 bytes and 8191 → 25 bytes.  A poisoned
file that is *not* the last one is left alone and does keep its bytes, but there is no
guarantee which case a given incident is, so the entry event can be unrecoverable even
while the machine is still standing.

Practical consequence for a test run: if you want to attribute a future
`Unknown WALEntry`, capture the WAL inventory **before** the DataNode restarts, not
after.  A per-WAL-node dump of size plus the first bytes is enough:

```bash
W=<db>/data/datanode/wal
for f in $(find "$W" -name '*.wal'); do
  printf '%s %s ' "$(stat -c%s "$f")" "$f"
  head -c 6 "$f" | od -An -c | tr -s ' '
done > wal-inventory-before-restart.txt
```

Run it immediately before every `stop-datanode.sh` and again after the node is back: a
file whose size changed and which now starts with `\0` is the one the repair rewrote.

### Constraining DataNode memory to a 32G box: it is not enough

Because the incident environment was a 32G machine running a 24G DataNode heap while
the test hosts had 377G, the ceiling was emulated with a cgroup v2 limit:

```bash
# on each DataNode host, as root
mkdir -p /sys/fs/cgroup/rcdn32g
echo 34359738368 > /sys/fs/cgroup/rcdn32g/memory.max     # 32 GiB
echo 0           > /sys/fs/cgroup/rcdn32g/memory.swap.max
echo <datanode-jvm-pid> > /sys/fs/cgroup/rcdn32g/cgroup.procs
```

The harness already writes `ON_HEAP_MEMORY="${DN_HEAP_MEMORY:-24G}"` into
`conf/datanode-env.sh`, so the 24G heap needs no change.  Pitfalls, all hit while
doing this:

* **The cgroup must be re-applied after every restart.**  The harness starts and stops
  DataNodes itself, so a poll loop that re-homes any JVM matching
  `com.timecho.iotdb.DataNode` is needed; a one-shot move is silently lost at the
  first `start-datanode.sh`.
* **Never `pkill -f <your-own-script>`.**  The pattern matches the killer's own
  command line, so the loop kills itself and enforcement stops with no error.  Kill
  by PID.
* **`pgrep -f <pattern>` matches the ssh remote shell too**, so process counts come
  back inflated; do not read the count as "N DataNodes".  This also bites
  **wait loops**, which is the expensive form: a loop such as
  `for k in ...; do pgrep -f 'com.timecho.iotdb' >/dev/null || break; sleep 2; done`
  matches *its own* command line, so it never breaks early and always burns the
  full timeout — measured at 120 s per host, long enough that a five-host wait
  hit the executor cap and was killed half way.  Use the bracket trick so the
  pattern cannot match itself:
  `pgrep -f '[c]om.timecho.iotdb.DataNode'`.  The same applies to
  `ps -ef | grep 'com.timecho.iotdb'`, which reports the grep itself.
* **`memory.peak` does not exist on every kernel** — read `memory.current` and track
  it yourself, and take the OOM counter from `memory.events` (`oom_kill`), which *is*
  `key value` formatted while `memory.current` is a bare number.
* **`AlwaysPreTouch` decides whether the move is safe.**  Here it is commented out in
  `datanode-env.sh`, so moving a freshly started JVM into a smaller cgroup does not
  immediately OOM.  Verify before assuming.

The result was a clean negative, and the reason matters more than the outcome: the
JVM's peak usage was **7.9 GB against the 32 GB ceiling**, with `oom_kill=0` over 2685
samples.  A 24G heap does not mean 24G resident — this workload never touched it.
**Do not report "OOM did not reproduce it" as evidence about the defect**: no memory
pressure was ever applied.  Either drive real allocation (raise the benchmark's data
volume, or add a consumer inside the same cgroup) or state plainly that the pressure
path was not exercised.

Independently, an OOM kill is a weak explanation for this particular defect: the
header-less file only appears if the kill lands inside the
`FileChannel.open(CREATE)` → `write(magic)` window, which is microseconds wide,
whereas a kill can land anywhere.  Prefer the one-off entry events listed above.

## `Unknown WALEntry type INSERT_ROW_PLAN`, part 2: a full WAL volume does **not** produce it

The obvious environmental story is "the volume filled, the 6-byte head magic could not be
written, a 0-byte `.wal` was left behind".  Every link is real in isolation; the chain is
still **not reachable**.  Measured on a live 2.0.12.1 DataNode whose `wal/` was moved onto a
4 MB tmpfs.

**The mechanism is real.**  `LogWriter`'s constructor is

```java
this.logChannel = FileChannel.open(logFile.toPath(), CREATE, WRITE, APPEND);
if ((!logFile.exists() || logFile.length() == 0) && (version == V2 || version == V3)) {
  this.logChannel.write(ByteBuffer.wrap(version.getVersionBytes()));
}
```

On a full tmpfs the `open` **succeeds** (an empty file costs no data page) while the write
fails, leaving a 0-byte `.wal`.  Confirmed directly:

```
after fill: tmpfs 4096 4096 0 100%
CREATE = OK
WRITE6 = FAILED
java OPEN = OK, len(before)=0
java WRITE = FAILED: java.io.IOException: No space left on device
final size=0
```

**And the repair turns it straight into the poison.**  Driving the production
`WALRepairWriter` over short files, the same read-then-repair sequence
`readLastFileInfoAndRepairIt` performs:

| input | before | after | first byte |
|---|---|---|---|
| 0 bytes | 0 | **25** | **`00`** |
| 1 byte `00` | 1 | 25 | `00` |
| 5 bytes `00` | 5 | 25 | `00` |
| 6 bytes `V3-WAL` | 6 | **6** (untouched) | `56` |
| 6 bytes `00` | 6 | 25 | `00` |

A 0-byte file becomes a 25-byte file with **no head magic and first byte `0x00`** — read
back as V1 from offset 0, i.e. `INSERT_ROW_PLAN`.  Note `READ entries=0 err=none`: the
**first** start after the damage is silent, and the error only appears on the **next** one.

**Then both routes to that 0-byte file were closed by measurement.**

1. **Full volume at startup.**  The node dies before it touches WAL at all:

   ```
   ERROR o.a.i.db.service.DataNode:412 - Fail to start server
   org.apache.iotdb.commons.exception.StartupException: No space left on device
       at org.apache.iotdb.db.service.DataNode.pullAndCheckSystemConfigurations(DataNode.java:537)
   ```

   `strace -f -y` finds the exact syscall, and it is not a WAL file:

   ```
   openat(".../wal/.iotdb-lock", O_RDWR|O_CREAT, 0666) = 24
   write(24</data/.../wal/.iotdb-lock>, "1719370", 7) = -1 ENOSPC (No space left on device)
   ```

   `DirectoryChecker.registerDirectory` truncates the lock and then writes the pid, and the
   lock is **0 bytes while the node is stopped** (it is truncated on the way down), so there
   is no page to release and the write fails.  The identical writes against
   `data/.iotdb-lock` and `system/.iotdb-lock` succeed — only the WAL one sits on the full
   volume.  Startup never reaches `new WALWriter(...)`.

2. **Volume filling while the node runs.**  The node flips to **read-only** and stops
   creating WAL files.  With the tmpfs pinned at 0 free for 4.5 minutes under continuous
   write load: **0 zero-byte `.wal`, 0 new WAL files**, and

   ```
   ERROR o.a.i.c.i.s.IoTConsensusRPCServiceProcessor:97 - fail to sync logEntries because system is read-only
   ```

   The per-region WAL file also simply grows instead of rolling — measured to ~1 MB with no
   roll — so the roll threshold is far above a volume this small and a roll was never
   imminent anyway.

**Do not build a repro on a full disk.**  The two remaining plausible producers of a
header-less, `0x00`-leading WAL file are: a `kill -9` / power loss landing inside the
microsecond `open(CREATE)` → `write(magic)` window (the disk-full guard cannot help there),
and a WAL file left by a **pre-magic build** (1.x), whose byte 0 is legitimately `0x00`
(`INSERT_ROW_PLAN`) and which carries no head magic to find — under the 1.x
`_<version>-<searchIndex>-<status>.wal` naming that 2.x happily picks up.

### Cleaning up a tmpfs experiment: the order matters

`mv <mountpoint>.orig <mountpoint>` while the tmpfs is **still mounted** is a cross-device
copy *into* the full filesystem.  It fails partway with ENOSPC, and the half-copied files
inside the tmpfs include **0-byte ones** — indistinguishable from the artefact you were
hunting.  Stop the node **first**, then unmount, then remove the mount point, then move the
backup back:

```bash
bash sbin/stop-datanode.sh
umount  "$W"                      # the node was holding it busy
findmnt -n "$W" && echo "still mounted -- do not proceed"
rm -rf  "$W"
mv      "$W.orig" "$W"            # same filesystem now: a rename, no ENOSPC
```

Assert the filesystem type before writing anything:

```bash
[ "$(findmnt -n -o FSTYPE "$W")" = "tmpfs" ] || { echo "refusing: not a tmpfs"; exit 1; }
```

An unbounded `dd` is the other way this goes wrong: `dd of="$W/../.fill"` writes to the
**parent** volume (19 T here) and had to be killed after ~400 GB.  Bound the filler with a
`count` derived from `df -k --output=avail` on the verified mount point.

## `Unknown WALEntry type INSERT_ROW_PLAN`, part 3: what actually produces it, and a 3/3 reproduction

Parts 1 and 2 ruled out natural recovery, memory pressure and a full disk.  This part closes
the question: **no shipped build ever wrote the offending byte.**  The file was *damaged*, and
the reproduction below is deterministic.

### The enum is the landmine

`WALEntryType` keeps three codes that **no writer emits** and that `WALEntry.deserialize` has
**no case** for:

```java
@Deprecated INSERT_ROW_PLAN((byte) 0),
@Deprecated INSERT_TABLET_PLAN((byte) 1),
@Deprecated DELETE_PLAN((byte) 2),
@Deprecated OLD_MEMORY_TABLE_SNAPSHOT((byte) 3),   // has a case: createFromOldMemTableSnapshot
        INSERT_ROW_NODE((byte) 4),  ...  INSERT_ROWS_NODE((byte) 8), ...
        MEMORY_TABLE_SNAPSHOT((byte) 10),           // 2.x's own snapshot moved to 10
        ... CLOSE_SIGNAL(Byte.MIN_VALUE), ... WAL_FILE_INFO_END_MARKER(-126);
```

`valueOf(0)` **succeeds** — `0x00` is a legal code — so the reader gets past the type lookup
and dies later, in `deserialize`'s `default:`:

```
WARN o.a.i.d.s.d.w.i.WALReader:91 - Fail to read WALEntry from wal file .../_N-0-1.wal
java.lang.RuntimeException: Unknown WALEntry type INSERT_ROW_PLAN
	at ...wal.buffer.WALEntry.deserialize(WALEntry.java:145)
	at ...wal.io.WALReader.hasNext(WALReader.java:75)
	at ...wal.recover.WALNodeRecoverTask.readLastFileInfoAndRepairIt(WALNodeRecoverTask.java:173)
	at ...wal.recover.WALNodeRecoverTask.run(WALNodeRecoverTask.java:87)
```

That is why the message names a type nobody uses: an **invalid** first byte gives the honest
`Invalid WALEntryType code: N` instead.  `0x00` is the one damage pattern that is *silently
legal*.

### No version ever wrote code 0 — checked, not assumed

Dump any build's enum with a three-line reflection program (`EnumDump.java` in
`wal_repro/probes/`), or just look for the plan class that would produce it:

| build | `InsertRowPlan` class | modern `WALEntryType` | writes code 0? |
|---|---|---|---|
| 0.13.0 / 0.13.4 | **yes** (`db.qp.physical.crud`) | no — old `db.writelog` format, different dir | n/a |
| 1.0.0 / 1.1.0 | no | yes (`db.wal.buffer`) | **no** |
| 1.2.2 | no | yes | **no** |
| 1.3.0.3 … 1.3.7 | no | yes | **no** |
| 2.0.12.1 | no | yes | **no** |

`grep -rn 'INSERT_ROW_PLAN' --include=*.java` over the whole 2.0.12.1 tree returns **one**
hit: the enum declaration itself.  The `InsertRowPlan` that code 0 stood for was removed when
the `*_NODE` plan refactor landed in **1.2.0**, and 0.13.x — the last line that had it — wrote
the **old `writelog`** files instead.  The two never coexisted.

**Consequence: a leftover WAL file from an old version is NOT the explanation.**  Every 1.x
file reads cleanly in 2.x — code 3 is handled as `OLD_MEMORY_TABLE_SNAPSHOT`, 4/5/6/8 map
one-to-one, and `0x82` is the end marker in both.  A 1.3.2.2 file parses as ordinary
`INSERT_TABLET_NODE` entries; a 1.3.1.4 file that is 20 bytes of end-marker parses as zero
entries.  So stop hunting for a version upgrade.

### The reproduction (3/3)

> **No version upgrade is involved — do not go looking for one.**  This was reproduced on
> `v20121rc2_0914_0b4dc9a`, a cluster **deployed fresh from the 2.0.12.1 tarball that has never
> run any 1.x build**.  The only input is a plain `dd if=/dev/zero` file.  The 1.x → 2.x upgrade
> route was investigated separately and **falsified** ("No version ever wrote code 0", above) —
> so an old version is neither necessary nor sufficient.  What the file's *provenance* is does
> not matter at all; only the byte value `0x00` does.

Plant a **zero-filled** file as the region's **last** WAL file and restart:

```bash
stop-datanode.sh
V=$(( $(ls "$W/$REG" | sed -n 's/^_\([0-9]\+\)-.*/\1/p' | sort -n | tail -1) + 100 ))
dd if=/dev/zero of="$W/$REG/_$V-0-1.wal" bs=1024 count=1
start-datanode.sh      # -> the stack above
```

Measured **3 consecutive rounds, 3 hits**, each with the identical five stack frames.  Script:
`wal_repro/exp_zerofill2.sh`.

This is also why the repro is cheap: **4 shell lines on any 2.x cluster**, no old version to
install, no activation code for a pre-2.0.10.1 build, nothing to upgrade.

Four traps, all of them cost a round here:

* **The version number decides everything.**  Only the highest-numbered file in a region is
  read; `readLastFileInfoAndRepairIt` is per-region and the rest are replayed then deleted.  A
  newcomer numbered *below* the current maximum is deleted **silently** — no log line at all.
  Always compute the maximum and plant above it, as above.
* **The error is one-shot.**  After the failure the poisoned file is removed and a fresh
  6-byte `_<n+1>-0-1.wal` appears, so the *next* restart is clean.  Seeing it once in a log is
  expected; it is not a permanent poison.
* **A 0-byte file does NOT trigger it.**  `WALInputStream` hits EOF, throws nothing, and the
  recovery path that would repair it is only reached when reading *threw*.  Verified live.
* **An invalid first byte does NOT give this message.**  A 3-byte `56 33 2d` (a truncated
  `V3-` magic) produced the same stack shape with `Invalid WALEntryType code: 86`, and the file
  was replaced, not repaired.  Only `0x00` yields `INSERT_ROW_PLAN`.

### If a customer reports this: capture the file **before** anything restarts

The affected file does not survive its own recovery — the error fires and then the file is
**consumed** (measured: the region directory ends up with only `_0.checkpoint` and a fresh
6-byte `_1-0-1.wal`).  So the evidence has a shelf life of one restart.  Ask for the archive
**first**, and make the order explicit, because "restart to see if it comes back" destroys it:

```bash
W=<DB_DIR>/data/datanode/wal/<region>          # the directory named in the WARN
cp -a "$W" /tmp/wal-region.orig                # whole directory, not just the one file
sha256sum /tmp/wal-region.orig/*               # hash before anyone touches it
head -c 8 /tmp/wal-region.orig/_*-0-1.wal | od -An -tx1    # expect 00 33 2d 57 41 4c …
```

A first byte of `00` (instead of `56 33`, i.e. `V3`) is the same case.  Archive the **whole
region directory**: `readLastFileInfoAndRepairIt` only ever touches the highest-version file,
so the lower-numbered siblings are what let you reconstruct the state.  If the file is already
gone, scan the other nodes with the loop above — one of them may not have restarted yet.

### Where such a file comes from

IoTDB does not pre-allocate WAL files — `LogWriter` opens `CREATE|WRITE|APPEND` and writes the
magic, and the whole `wal` io/buffer package contains no `setLength`, `SPARSE` or extension
`truncate`.  So a file that has **length but zero content** is made *outside* the process: the
classic delayed-allocation / write-back-cache loss where the metadata (size) survives a crash
but the data blocks do not.  Treat it as storage damage, and check the storage layer — not the
database version — when a customer reports this.

**Reproduction status: deterministic, 3/3, with the incident's exact stack — and it needs no
version upgrade.**  What remains unobserved is only the *external* event that zeroes the file,
and that is outside IoTDB.  If someone reports this symptom, do **not** ask which version they
upgraded from; ask whether the last WAL file of the region is zero-filled, and check the storage
layer.

### The exact mechanism, and why closed and unclosed files behave differently

Two places in the reader use **different sources of truth** for the same file:

| code | reads | decides |
|---|---|---|
| `WALFileVersion.getVersion(channel)` | **head magic only** | which offset entries start at |
| `WALInputStream.getEndOffset()` | **tail magic** | whether the file is complete, where entries end |

`getVersion()` recognises only `V3-WAL` / `V2-WAL` and otherwise **falls back to V1**, and the V1
branch then does `channel.position(0)`.  So once the head is damaged, the read start moves from
the correct **offset 6** back to **offset 0**, and the 6 head-magic bytes get consumed as data.

Worked numbers for the two shapes, both verified against live logs:

**A — unclosed** (last file after `kill -9`; tail is `ff…`, no tail magic), size 108921:

```
head = 00 33 2d 57 41 4c      tail(3B) = ff ff ff
getVersion() -> V1
tail-3B != b"WAL"  -> treated as broken, endOffset = size = 108921
channel.position(0); 0 < 108921 -> reads byte at offset 0 = 0x00
WALEntryType.valueOf(0) = INSERT_ROW_PLAN -> default: throws
```

**B — closed** (normal roll; tail is a valid `V3-WAL`), size 1546918:

```
head = 00 33 2d 57 41 4c      tail(3B) = WAL
getVersion() -> V1
tail-3B == b"WAL"  -> misjudged as "complete"
metadataSize read at size-7 = 0x2656332d = 643183405   (misaligned; should be size-10)
endOffset = 1546918 - 3 - 4 - 643183405 = -641636494   -> negative
hasNext(): position(0) >= endOffset(-641636494) -> true
=> loop body never runs -> hasNext() returns false -> SILENT, zero entries, no exception
```

Live log for B matched exactly: `WALNodeRecoverTask:128 - Successfully recover`, **no
`WALReader` warning at all**, and the file was deleted 20 s later by the WAL-delete thread with
`WALBuffer:858 - Broken wal file …, size 1546918`.  Counts before and after were identical, so no
loss was observed — but "reads nothing and says nothing" is the dangerous part.

So the symptom depends on **whether the tail carries the magic**:

| | unclosed | closed |
|---|---|---|
| recovery log | `WALReader:91` WARN | **nothing** |
| message | `Unknown WALEntry type INSERT_ROW_PLAN` | none |
| file | deleted | deleted |

To reproduce the customer's line you need shape **A**.  Do not hand over a closed file and claim
it reproduces the report — it produces a different (silent) outcome.

Also note the error names a type that is **not an entry at all**: the `0x00` is the first byte of
the damaged `V3-WAL` head magic.  Do not let the message pull you toward old-version compatibility.

### Trap: `stop-datanode.sh` returning does not mean the process has exited

This cost a full verification round.  `stop-datanode.sh` returns as soon as the port disappears,
but the process is still finishing (flushing, closing WAL).  Starting immediately makes the
launcher see the exiting process and refuse:

```
 Found running IoTDB node (PID=2411171).
 Can not run duplicated IoTDB node!
 Exit...
```

The DataNode then **never starts**, the recovery never reads your planted file, and you conclude
"did not reproduce" while the file sits there untouched — until the WAL-delete thread removes it
as a stale broken file.  Wait on the **process**, not the port:

```bash
bash sbin/stop-datanode.sh
for k in $(seq 1 120); do pgrep -f 'com.timecho.iotdb.DataNode' >/dev/null || break; sleep 2; done
if pgrep -f 'com.timecho.iotdb.DataNode' >/dev/null; then pkill -9 -f 'com.timecho.iotdb.DataNode'; sleep 5; fi
```

Self-check before/after every round, or the round is void:

```bash
pgrep -cf 'com.timecho.iotdb.DataNode'   # before planting: must be 0
ss -lnt | grep -c ':6667'                # after starting: must be 1
ls -la "$W/$REG"/_*.wal                  # planted file must be the highest version
```

A tell-tale sign that a round was void: the version you compute for the next plant is based on
the previous round's leftover (planted `_101`, next round computes `_201`).


## 每条用例的 wipe 之后必须重新提交激活码（2026-10-05 实测，2.0.12.1 RC5）

`run` / `matrix` 的每条用例都会 `stop -> wipe -> configure -> start_all()`。wipe 会删掉 `data/`，
而 2.0.12.1 的**运行时激活态**就在 `data/` 下；同时 `start_all() -> ensure_license()` 因为
`activation/license` 仍然存在而提前返回，于是没有任何地方重新提交激活码。结果：集群起来了、
节点显示 Running，但第一次 schema 写入就报

    307: Schema write operations are not allowed until this node is activated

表现为客户端侧 `Registering schema failed!`，用例在 900 s 后以
`case aborted: benchmark objects were not created within 900s` 失败 —— 看起来像集群故障，实际是激活问题。
`cli.prepare` 早就有这个补救（见其注释），但 per-case 重置路径漏了它。

修复：`cases.py` 在 `start_all()` 成功后调用 `_resubmit_activation()`（与 `cli.prepare` 同一做法，
`activate` 幂等；`DEPLOY_ACTIVATE=false` 或 stub 模式会跳过）。验证：修复后同一用例输出
`re-submitted the activation code after the wipe` 紧接着 `benchmark objects ready: ...`，
三个 workload 的 `benchmark.out` 里 307 计数为 0。
