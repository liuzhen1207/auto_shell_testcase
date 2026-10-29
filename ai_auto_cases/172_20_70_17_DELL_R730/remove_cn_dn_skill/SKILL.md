---
name: iotdb-remove-cn-dn
description: "Deploy a TimechoDB/IoTDB release from a tarball onto given hosts (ssh user/password, install path), activate the licence, configure schema/data replication factors plus the data-region consensus protocol (IoTConsensus or IoTConsensusV2/IoTV2), and fetch the iot-benchmark build that matches the database line (2.x: tree+table+table_view with iotdb-2.0; 1.x: tree only with iotdb-1.3), then test node removal on a ConfigNode/DataNode cluster under concurrent iot-benchmark read/write load: REMOVE DATANODE for Running, Unknown, ReadOnly, disk-full, nonexistent and concurrent targets, REMOVE CONFIGNODE for Leader, Follower and stopped targets, abnormal operations mid-procedure, then wait for procedures and syncLag to drain and verify replica consistency by stopping one node at a time against the all-online baseline. Use for node decommissioning, region migration and replica-consistency testing."
whenToUse: "When asked to deploy TimechoDB/IoTDB from a release tarball, activate its licence, or test IoTDB remove datanode / remove confignode, node decommissioning under load, procedure completion, sync-lag drain, or replica-consistency after node removal on a ConfigNode/DataNode cluster."
metadata:
  version: "1.0.0"
  category: "iotdb-cluster-testing"
---

# IoTDB remove ConfigNode / DataNode concurrency & consistency test

Drives a **ConfigNode/DataNode IoTDB cluster** through REMOVE procedures while
`iot-benchmark` keeps writing and reading, then proves the cluster is still
correct: every procedure finished, sync lag drained to zero, and query results
are identical to the all-online baseline even with one node stopped.

The skill is **IP independent**. No address is hard coded: the node inventory is
either declared in `conf/nodes.conf` or discovered at run time from
`SHOW CLUSTER` / by probing the hosts.

## Run it

```bash
cd <skill-dir>
cp conf/cluster.conf.example conf/cluster.conf   # then edit it
scripts/rcdn.sh selftest                          # offline parser check, no cluster needed
scripts/rcdn.sh --conf conf/cluster.conf smoketest # every case end-to-end, stubbed
scripts/rcdn.sh --conf conf/cluster.conf doctor   # verify every precondition
scripts/rcdn.sh --conf conf/cluster.conf list-cases
scripts/rcdn.sh --conf conf/cluster.conf discover --from-cluster   # or --from-inventory
scripts/rcdn.sh --conf conf/cluster.conf deploy   # build the cluster from a tarball + activate
scripts/rcdn.sh --conf conf/cluster.conf benchmark --install  # fetch the matching benchmark build
scripts/rcdn.sh --conf conf/cluster.conf prepare  # DESTRUCTIVE: wipe + restart the cluster
scripts/rcdn.sh --conf conf/cluster.conf matrix   # run every case
scripts/rcdn.sh --conf conf/cluster.conf run --case dn_running_remove --case cn_leader_remove
scripts/rcdn.sh --conf conf/cluster.conf verify   # re-check a running cluster, no removal
scripts/rcdn.sh --conf conf/cluster.conf diag     # explain a syncLag that will not drain
# Expected outages: the ConfigRegion replica set IS the ConfigNode set, so its floor is
# members//2+1.  Removing one of three ConfigNodes and then stopping another leaves
# 1 vote where 2 are needed; R&D confirmed that is expected, not a defect.  The harness
# records the down-window and excuses only errors inside it (CN_BELOW_QUORUM_EXPECTED_OUTAGE).
# To test remove-plus-fault for real, use >=5 ConfigNodes.
#
# Expected errors: a case that stops/restarts the DataNode serving a statement will
# provoke 722 CANNOT_FETCH_FI_STATE.  R&D confirmed this is documented behaviour, so
# EXPECTED_BENCH_ERRORS (default in config.py) keeps it recorded but out of the
# pass/fail decision.  Set it empty for strict mode.
# NOTE: 722 arrives with TWO different texts -- "Fetch Table Device Schema failed
# because ..." and the MPP one, "Failed to fetch state, has retried N times, may be
# caused by DN restarting."  An allowlist matching only the first silently excuses
# nothing (measured: 0 matches out of 190 real error lines), so the default matches
# the status code too.  A selftest asserts both texts as they really appear.
# 305 "no detailed failure reason in QueryStateMachine" is the same kind of expected
# error and R&D decided (2026-09-29) NOT to fix it: recycling the node's resources
# without draining the queries it is still serving fails those queries, and waiting
# risks the REMOVE being stuck behind a large query.  It is whitelisted by code like
# 722, and DN_FAULT_EXPECTED_OUTAGE (default true) additionally excuses any error
# inside a recorded DataNode down-window.  See "A 305 ... expected, whitelisted".
  # diag prints, per node: lagging regions, each dispatcher's peer, whether that peer is
  # still a live DataNode, the queue depth, and the remaining driver-thread count
scripts/rcdn.sh --conf conf/cluster.conf teardown --wipe
```

Always run `doctor` first: it checks SSH, passwordless sudo, `DB_DIR`, the SQL
client, `BM_HOME` and `MONITOR_URL` without changing anything. Read
`README.md` for the full prerequisite list before the first real run.

## From a bare tarball to a finished run

The skill can build the cluster itself, so the minimum you need to supply is a
release tarball, the hosts, an ssh user and password, and the install path:

| you supply | config key |
|---|---|
| TimechoDB release tarball | `DEPLOY_TARBALL` (a local path -- it is uploaded -- or a path already on every host) |
| how to log in | `SSH_USER`, `SSH_PASSWORD`, `SSH_MODE=password` |
| the hosts | `DEPLOY_HOSTS=ip1,ip2,ip3` (one ConfigNode + one DataNode each, i.e. 3C3D) |
| where to install | `DEPLOY_DIR` (unpack target) and `DB_DIR` (final install path) |

> **`DEPLOY_HOSTS` always produces one ConfigNode *and* one DataNode per host.**
> It does not read `NODES_FILE` for the layout, so five hosts give **5C5D**, not
> 3C5D.  To deploy a different shape -- e.g. 3 ConfigNodes on three of five hosts
> with all five running a DataNode -- write `conf/nodes.conf` yourself, with one
> `cn<TAB>ip` / `dn<TAB>ip` row per role, and set `NODES_FILE` to it.  The loader
> resolves a relative `NODES_FILE` against the working directory first, then the
> config file's directory, then the skill root, and `doctor` prints
> `nodes source` so you can see which inventory actually won.  Get this wrong and
> the ConfigNode cases test a differently sized ConfigRegion than you intended --
> in particular `cn_remove_below_quorum` and `cn_shrink_leader_first` shrink
> *from whatever it finds* down to a single ConfigNode, so the number of removals
> (and therefore how long the case takes) follows the deployed topology.

```bash
scripts/rcdn.sh --conf conf/cluster.conf deploy --clean
scripts/rcdn.sh --conf conf/cluster.conf doctor
scripts/rcdn.sh --conf conf/cluster.conf matrix
```

`deploy` uploads the tarball to every host (skipping hosts that already have a
file of the same size), unpacks it, moves the archive's single top-level
directory into `DB_DIR`, writes the configuration, starts the **seed ConfigNode
first** and only then the rest, waits for every node to report Running, and
submits the activation code. `--no-start` stops after writing the configuration;
`--no-activate` skips activation; `--clean` stops and wipes a previous install.

### Replication factor and consensus protocol

The defaults are `schema_replication_factor=3`, `data_replication_factor=2` and
`data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.IoTConsensus`.

To test the V2 protocol, pass either spelling -- they mean the same thing:

```bash
scripts/rcdn.sh --conf conf/cluster.conf deploy --consensus IoTConsensusV2
scripts/rcdn.sh --conf conf/cluster.conf deploy --consensus IoTV2   # same
```

`IoTV2` maps to `org.apache.iotdb.consensus.iot.IoTConsensusV2`. An unrecognised
name **aborts the deployment** instead of quietly falling back to the default.

> **These are `effectiveMode: first_start`.** `schema_replication_factor`,
> `data_replication_factor`, the seed endpoints and the consensus protocol class
> cannot be changed after the first start -- IoTDB refuses, and the only fix is to
> wipe `data/` and redeploy. That is why `deploy` writes the whole configuration
> before it starts anything, and why `--consensus` is validated before a single
> host is touched.

### Activation

Activation uses the trial code kept in the skill repository at
`/data/deepseek/ai-bug-verify` (`skills/timechodb-rn-verify/references/activation.md`),
read at deploy time through `LICENSE_CODE_FILE` so the code is not duplicated
here. Override with `LICENSE_CODE` (the code itself, or a path to a file
containing it). One `activate` on any ConfigNode activates the whole cluster.

> **A restart keeps the activation; a *wipe* may not.** `wipe()` removes `data/`
> and keeps `activation/`, and on some builds the runtime activation state lives
> under `data/`. Measured on 2.0.12.1: after a wipe, only the seed ConfigNode came
> back `ACTIVATED` while the others logged `Load license fail. / This license is
> not allowed to activate this ConfigNode`, and a later `REMOVE CONFIGNODE` then
> never completed (600 s timeout).  `ensure_license()` does **not** cover this — it
> returns early once `activation/license` exists.  So `prepare` re-submits the
> code after every restart (`--no-activate` suppresses it), and any post-restart
> check should confirm every ConfigNode reads `ACTIVATED`, never
> `ACTIVATED(W)`.  See `references/troubleshooting.md`.

Mechanism, version rules and troubleshooting live in the `timechodb` /
`timechodb-rn-verify` skills; this skill only submits the code.

## The benchmark build must match the database version

iot-benchmark publishes one package per database line and they are not
interchangeable -- each bundles the client libraries for its own line
(`iotdb-session-1.3.7.jar` versus `iotdb-session-2.0.11-...jar`). The wrong one
installs cleanly, passes every structural check, and then fails at connect time
in a way that reads like a cluster fault. So the pairing is derived and checked
rather than left to the operator:

| database | benchmark package | `DB_SWITCH` | workloads |
|---|---|---|---|
| 2.x | `iot-benchmark-iotdb-2.0-java17.zip` | `IoTDB-200-SESSION_BY_TABLET` | tree, table, table_view |
| 1.x | `iot-benchmark-iotdb-1.3-java17.zip` | `IoTDB-130-SESSION_BY_TABLET` | **tree only** |

The table model only exists from 2.0, so a 1.x target drops the table workloads
and records what it dropped; `doctor` prints the resulting workload set.

`DB_VERSION` is the input. Set it explicitly, or let it be inferred from
`DEPLOY_TARBALL` (which names the build exactly) or `DB_DIR`. An install
directory like `v20121rc2_0914_0b4dc9a` carries no dotted version, and that is
reported as a problem instead of being guessed at.

```bash
# see which package this version needs
scripts/rcdn.sh --conf conf/cluster.conf benchmark --version 1.3.4
# download and install it (cached; re-runs need no network)
scripts/rcdn.sh --conf conf/cluster.conf benchmark --install
scripts/rcdn.sh --conf conf/cluster.conf benchmark --install --tag 2026-08-12-e158c2c9-java17
```

Packages come from <https://github.com/thulab/iot-benchmark/releases>, and each
release carries both lines, so one tag serves a 1.x and a 2.x run. To build from
source instead, see the `iot-benchmark` skill in `/data/deepseek/ai-bug-verify`
(it owns the maven build and its cache), then point `BM_HOME` at the result.

A previously downloaded package is reused by size **before** any connection is
attempted, so a host with no route to GitHub can still run from a package it
already has.

**`--install` without `--tag` tracks the newest release of that line.** That is
convenient, but it means the benchmark build is not reproducible by default: two
`--install` runs months apart can unpack different builds. `run` and `matrix`
never touch the network -- they use `BM_HOME` as given -- so a regression is
internally consistent, but **pin `--tag` (or an explicit `BM_HOME`) when the
numbers have to be comparable across weeks**. Every run now logs
`benchmark build: <BM_HOME>` so the artifacts can say which build produced them.

## What one case does

1. **cluster** – stop, wipe `data/`+`logs/`, write `iotdb-system.properties`
   (seed node, internal addresses, replication factors), start, wait healthy.
2. **benchmark** – generate one config per workload, start them, wait for the
   schemas to exist, resolve the real table/column names from the catalog.
3. **warm up** – let the load run `BM_REMOVE_AFTER_SEC` seconds.
4. **remove** – put the target into the state the case asks for
   (Running / Unknown / ReadOnly / disk-full / Adding), then issue
   `REMOVE DATANODE <id>` or `REMOVE CONFIGNODE <id>`.
5. **abnormal** – inject the case's abnormal operations while the procedure runs
   (`kill -9`, restart, a second concurrent remove, repeated remove, malformed
   remove SQL, `LOAD BALANCE`).
6. **procedure** – poll `SHOW MIGRATIONS` until it stays empty for
   `MIGRATION_STABLE_SECONDS`, and until the node disappears from
   `SHOW DATANODES` / `SHOW CONFIGNODES`.
6b. **restart probe** – every DataNode removal ends by starting that node again
   and asking whether it is reusable, i.e. whether the data it should have
   deleted is gone. What counts is **files that were already there before the
   restart and are still there after it** (a booting node legitimately recreates
   its own empty directory structure). The verdict follows the case:
   a node the case **killed** mid-removal had no chance to clean up, so the
   documented refusal is expected and only recorded; any **other** removal ran to
   completion with the node alive, so refusing to start, or still holding
   pre-restart files, is a failure. When the node does re-join, the probe leaves
   it running -- it is a legitimate member again, and stopping it would leave the
   cluster listing a member that is down, which trips the later `syncLag` gate
   with "is unknown". It waits `RESTART_CLEANUP_SETTLE_SEC` first, and records
   the id it re-joined under. Nodes removed while already stopped
   (`selector=unknown`) keep their own probe, which asserts the documented guard.
   See "Removing a DataNode does not necessarily delete its files" below.
   **Before starting the node, the probe waits for the removed node's own JVM to
   exit, and afterwards requires a *new* PID.** Both are necessary: the removal
   marks the node gone as soon as its regions have migrated, while the process
   lingers (shutdown hooks, compaction pools) for up to a minute, and
   `sbin/start-datanode.sh` runs `check_running_process` and refuses to launch a
   second node for the same `IOTDB_HOME`. Starting too early is therefore a silent
   no-op that the old PID happily satisfies -- the probe then reports "restarted
   but did not re-join the cluster" for a node it never restarted. Seen on 2.0.12.1
   RC4 (`dn_running_remove`): the target's log ended with its *old* process's
   shutdown hook and held no startup lines at all.

6c. **forensic replica file capture** – the moment the consistency sweep finds a
   diff, snapshot every DataNode's TsFile inventory (plus `show regions`) into
   `forensic_diff_<host>_files.tsv`, and cross-compare them into
   `forensic_diff_<host>_missing_files.txt`. A query-level diff only says *that*
   replicas disagree; the file lists are the context for reading it. Purely
   forensic and never asserted on, because replicas legitimately hold different
   file sets -- see the caveat below before drawing any conclusion from them. It runs
   inside a `try` so a capture failure can never turn a case red. The same
   capture **re-runs the disagreeing query through every DataNode that is still
   up** and records, per node, whether its view matches the all-online baseline.

   **What the inventory can and cannot decide.** It answers coarse questions
   ("does this replica have any data for that region at all"). It **cannot**
   prove a file was omitted: every replica flushes independently and names each
   TsFile after *its own* flush timestamp and version, so two healthy replicas
   holding the same rows produce differently-named files as a matter of course.
   A live capture produced 46 "differences" that were all exactly that -- same
   second, same region, different version suffix. `.resource` is binary, so it
   cannot be compared either. Do not read the inventory as a verdict.
   Without that, "which replica is short?" can only be inferred from *which node
   was stopped when the diff appeared* — an inference that does not converge
   when more than two replicas are involved, and that produced a wrong reading
   once already. With it, one run names the node.

7. **sync lag** – poll `syncLag` for every *Running* DataNode of *this* cluster
   until all values are 0 for `SYNC_STABLE_SECONDS`. Prometheus is **not**
   required: `SYNC_LAG_SOURCE=metrics` (the default when `MONITOR_URL` is
   unset) scrapes each DataNode's own `http://<dn>:<METRICS_PORT>/metrics` for
   the `iot_consensus{...,type="syncLag"}` series and sums the regions per
   node, which is what `sum(...) by (instance)` would have given you.
8. **consistency** – capture the all-online baseline for tree, table, writable
   view and OBJECT queries; then, for **each** DataNode, stop it, wait for the
   cluster to notice, re-run the same queries through a different host, restart
   it, and diff against the baseline.
9. **logs** – stop the cluster, scan every CN/DN log for known-bad conditions.
10. **verdict** – PASS only if every step above was clean. On FAIL the CN/DN
    logs are tarred into `results/<run>/log_backup/<case>_<timestamp>/`.

### Interrupting a run: no writer may outlive the driver

Each workload runs in its own session, so a single `killpg` stops the whole JVM
tree — but that also means the load survives the driver. If the driver dies
without running its cleanup (SIGTERM, a killed terminal, a supervisor restart),
the benchmark keeps writing to the cluster, and the next case then sees a dataset
that never stops moving. The harness reports that as "the dataset never settled
after the removal" and skips the replica sweep: a full case (~20 minutes) is lost,
and the message blames the database for an operational leftover. Measured on the
2.0.12.1 RC4 matrix, where exactly that happened.

Two guards, both automatic:

* the driver installs SIGTERM/SIGHUP handlers that stop the load it started, and
  `Ctrl-C` does the same before exiting 130;
* `run`/`matrix` stop any load left behind by an **earlier, dead** driver before
  the first case. PID files live under `RESULT_DIR`, and a leftover is only
  signalled when its command line still names a benchmark directory inside that
  tree, so a recycled PID or an unrelated process can never be hit. A **live**
  driver records itself in `<case>/benchmark/driver.pid`, so a concurrent run or a
  `doctor` leaves its load alone; `doctor` only reports leftovers and never kills.

After a `kill -9` on the driver (no handler can run), check before the next run:
`ps -eo pid,cmd | grep -c '[b]enchmark.App'` must be 0, or the next case will fail
with the misleading "dataset never settled".

## Workloads and data types

Three benchmark workloads run at the same time against one cluster -- but only
on a 2.x database. The table model arrives in 2.0, so a 1.x target runs `tree`
alone and the other two are dropped (the chosen benchmark package enforces this
too; see "The benchmark build must match the database version"):

| workload     | `IoTDB_DIALECT_MODE` | `INSERT_DATATYPE_PROPORTION` | data types |
|--------------|----------------------|------------------------------|------------|
| `tree`       | tree                 | `1:1:1:1:1:1:1:1:1:1:0`       | 10         |
| `table`      | table                | `1:1:1:1:1:1:1:1:1:1:1`       | 11 (10 + `OBJECT`) |
| `table_view` | table                | `1:1:1:1:1:1:1:1:1:1:1`       | 11 through a `WRITABLE VIEW` |

> On 1.x the `tree` workload uses the tree dialect and the 10 tree data types
> only. `IoTDB_DIALECT_MODE=table` and the `OBJECT` type do not exist there.

Order of `INSERT_DATATYPE_PROPORTION` is
`BOOLEAN:INT32:INT64:FLOAT:DOUBLE:TEXT:STRING:BLOB:TIMESTAMP:DATE:OBJECT`.
Data volume is deliberately small (`BM_DEVICE_NUMBER`, `BM_SENSOR_NUMBER`,
`BM_LOOP`); this skill tests correctness, not throughput. Because `OBJECT`
columns cannot appear in constant comparison predicates, the table workloads
use the value-filter-free `OPERATION_PROPORTION=91:1:2:0:2:0:0:1:1:2:0:0:0`.

## Case matrix

`cases/remove_cases.tsv`, tab separated:
`case_id  target(cn|dn)  selector  abnormal,ops  data_rf  schema_rf  workloads  notes`.

DataNode selectors: `running`, `unknown`, `readonly`,
`nonexistent`, `multi`, `concurrent`, `adding`, `rf_limit`.
ConfigNode selectors: `leader`, `follower`, `stopped`, `nonexistent`.
(`rf_limit` removes DataNodes until only `data_replication_factor` remain and
requires the next removal to be refused; `adding` holds the last DataNode back
from the cluster start, joins it, then removes that just-added node.)
A `diskfull` selector still exists in the code but no shipped case uses it: the
ReadOnly state it reached is now reached directly by `dn_readonly_remove`, and
the selector's own mechanism was rewritten to raise the node's disk threshold
rather than fill the volume (see Rules below).

Abnormal ops: `none`, `kill9_target`, `kill9_other_dn`, `restart_dn`,
`restart_cn`, `kill9_cn`, `stop_cn`, `concurrent_remove`, `remove_twice`,
`invalid_sql`, `load_balance`, `delete_objects`. See `references/cases.md`.
`delete_objects` keeps issuing the case's `DELETE` while the removal runs, which
is what puts the OBJECT GC in the same window as the region snapshot (TDB-861).

An optional ninth column, `extras` (comma separated), turns on the OBJECT /
region-migration audits that the shipped matrix uses for the two known defects:

| extra | what it does |
| --- | --- |
| `object_size` | per replica, `ObjectSize` from `SHOW REGIONS FROM <db>` (relational dialect; the tree-dialect `SHOW REGIONS` does not list table databases at all) must be non-negative and match the physical `.bin` bytes on `<data dir>/object/<region>/**` within `max(1 MiB, 10%)`, and agree across replicas |
| `cold_restart` | stop the cluster, delete every `TableObjectSizeFile_*` (a cache-less start), start it again, re-run the size audit -- the TDB-835 shape |
| `object_delete_residue` | files a follower replica holds but the leader does not, intersected with the leader's `log_datanode_object_deletion.log` paths, are a confirmed residue (TDB-861). The window is armed by OBJECT **overwrite churn** + a targeted `MIGRATE REGION` (see `references/known-defects.md`; `scripts/object_probe.py` runs the same probe standalone) |

Both audits gate their verdict on evidence: `object_size` SKIPs unless some
replica actually holds `.bin` files, and `object_delete_residue` SKIPs unless the
leaders actually logged OBJECT deletions. An audit that inspected nothing can
never PASS. Multi-disk OBJECT layouts are covered by `DN_DATA_DIRS` (written to
`dn_data_dirs`) plus `DN_EXTRA_DIRS` (created before start and wiped with the
rest, so a previous case's objects cannot leak into the next).

Run a subset with `run --case <id>` (repeatable). `matrix --limit N` stops
early. `--repeat N` runs each selected case N times, naming the extra runs
`<case>#2` … `<case>#N` and printing a pass rate at the end — use it for the
cases that are known to be flaky, because a single run cannot tell a solid
pass from a lucky one. Add cases by appending rows — the ids are free-form but must be unique.

## Reading the result

`results/<run>/summary.tsv` and `summary.json` hold one row per case;
`results/<run>/cases/<case_id>/result.json` holds the problems and artifacts.
Exit code is `0` only when no case FAILed.

* `PASS` – procedure drained, sync lag reached 0, all consistency sweeps
  matched, logs clean. With `--repeat N` a PASS applies to one *run*; read
  the printed rate (`dn_remove_other_unknown: FAIL=2  PASS=3   (5 runs)`)
  before calling a flaky case fixed or broken.
* `FAIL` – at least one check failed; the log backup path is in `summary.tsv`.
* `SKIP` – the case refused to run (for example `other_dn_diskfull` when the
  fill cannot cross the threshold, or `adding` on an inventory too small to hold
  one back). A SKIP
  is not a pass: read `steps` in `result.json` for the reason.
  **A fault that cannot be injected is always a SKIP, never a PASS** – otherwise
  the case certifies a scenario it never exercised. That check runs up front, so
  it costs ~0.1 s instead of a full benchmark run.

## Confirming "data silently not delivered" from the logs

When a replica is missing data but every health signal looks fine, the decisive
evidence is usually in the **leader's** datanode log, not in the data directory.
Two greps settle it:

```bash
grep -oE 'Successfully build sync log channel to Peer\{groupId=DataRegion\[[0-9]+\][^}]*\}[^ ]* [^ ]* with initialSyncIndex [0-9]+' log_datanode_all.log
grep -E 'Can not send Batch\{startIndex=' log_datanode_all.log
```

* **Do not read `initialSyncIndex N` as the index the channel resumes from.**
  It is only the value *passed in*, and that value is
  `IoTConsensusServerImpl.getMinSyncIndex()` (`IoTConsensusServerImpl.java:997-999`:
  the comment says "use searchIndex" but the code passes `getMinSyncIndex()` --
  comment and code disagree). It becomes the index **only when no progress file
  is found**; otherwise `IndexController.restore()` overrides it. A before/after
  jump therefore shows the *fallback* moved, not that a range was skipped.
* **The real per-channel progress is a file whose name is the index**:
  `consensus/data_region/<dbId>_<regionId>/<peerNodeId>-<index>`, zero bytes,
  beside `writer.meta`. `IndexController.restore()` keeps it when present
  (`currentIndex = lastFlushedIndex`) and **silently falls back to the passed-in
  `initialIndex` when it is gone** -- which jumps the channel forward past
  anything not yet delivered. `LogDispatcherThread.cleanup()` (called from
  `removeLogDispatcherThread`) deletes those files via
  `controller.cleanupVersionFiles()`, and a graceful `stop()` force-persists the
  contiguous acked index (`processStopped()` -> `SyncStatus.free()` ->
  `update(0, true)`). `IndexController.persist()` carries a comment already
  conceding the file may be **deleted during the DataNode removing stage**
  ("...may be deleted before all the async operations returns. We needn't add
  some sync operation here because it won't infect the correctness").
* `Can not send Batch{startIndex=...}` are batches that could not be sent while
  the peer was inactive. They live in that dispatcher thread's in-memory pending
  queue, and nothing logs them being retried or replayed. Note that the
  `log dispatcher to Peer... removed and cleanup` lines report removal of the
  **departing** peer's channel -- check the endpoint before blaming the channel
  you care about. The queue for the *surviving* peer dies with the **process**,
  not with a dispatcher removal.
* The migration itself does **not** wait: `Succeed to addPeer ...` is logged as
  soon as the snapshot is transmitted, seconds before the follower has caught up.

So the candidate failure shape is: `remove dn` -> region migration -> the new
replica is still catching up -> the node is restarted -> the surviving peer's
progress file is missing, so the rebuilt channel starts from `getMinSyncIndex()`
instead of the persisted index -> that replica is permanently short, while region
counts and `syncLag` stay healthy. **A small, non-self-healing diff is the
signature.**

**RESOLVED (measured 2026-09-23, `dn_remove_restart`, watching the files every
0.5 s): the progress file wins.** The channel resumes from it and re-sends the
whole undelivered range, so a restart does **not** skip the gap. The logged
`initialSyncIndex` is only the fallback and is *overridden* whenever the file
exists -- measured on DataNode `.9`, region 4 -> `.8`:

| evidence | value |
|---|---|
| progress file on disk before the restart | `1_4/2-15` -> **15** |
| `initialSyncIndex` printed after the restart | **246** |
| batch actually attempted after the restart | `Can not send Batch{startIndex=**16**, endIndex=246}` |

`startIndex=16` is the file's `15 + 1`. A second, independent tell: when a restart
rebuilds several channels of one region, the **first** logs the fallback while
**later** channels log `min` over the threads already added -- that second channel
printed **15**, which can only come from the first channel's restored
`currentIndex`. Two directions, same conclusion.

**So never infer a skipped range from a rising `initialSyncIndex`** -- that value is
*expected* to be high (it is another channel's position, or the leader's own
`searchIndex`). Reading it as "data skipped" is a mistake that was actually made
here and had to be retracted; do not repeat it.

**Check the capture itself before calling any difference a data difference.**
A diff verdict is only as good as the two results being compared. Three "occurrences"
of a reported replica inconsistency were re-read on 2026-09-23 and the classification
changed: one was the base table (`table`, device `d_38`: 134 vs 135), one was
`table_view`, and **one was a false positive** whose capture file was **0 bytes** --
the query had simply failed (the same 305 class as below), and comparing an empty
result with a 100-row baseline reports "replica inconsistency" for a query that
returned nothing. Two further lessons from that re-read:

* the direction of the difference matters, and it was not consistent: one run's
  baseline had **one row more** (101 vs 100), another's had **one row less**
  (134 vs 135), and one device flipped 134 <-> 135 across captures. "A replica is
  short" is therefore not the only reading -- a **duplicate row** on the migrated-to
  replica fits the "one row more" case just as well. Do not write "permanently short"
  unless a post-run re-capture proves the value does not come back.
* `verify.py` now refuses to compare output-less captures: `empty_capture()`
  (a zero-row result still prints a header and `Empty set.`, so no output at all
  means the client never ran) records
  "query produced no output ... (failed capture, not a replica difference)"
  and skips the query. Covered by the self-test case
  "an output-less capture is a failed capture, not a difference".

**Know the write granularity before interpreting any row difference.**
`config.py` pins `BM_DEVICE_NUM_PER_WRITE=1`, `BM_BATCH_SIZE_PER_WRITE=1` and
`BM_POINT_STEP=1000` (and the 2.x profile uses `IoTDB-200-SESSION_BY_TABLET`), so
**one write is a single-row tablet for a single device** -- one timestamp, all
sensors. Verified in the benchmark bytecode: `SyntheticDataWorkLoad.getOneBatch()`
reads `BATCH_SIZE_PER_WRITE` and builds a single-device `Batch` when
`DEVICE_NUM_PER_WRITE == 1`; `SessionStrategy.insertOneBatch` -> `insertOneBatchByTablet`
-> `genTablet` -> `createTablet(target, sensors, ..., batch.getRecords().size(),
Config.getDEVICE_NUM_PER_WRITE())` -> `insertTablet`. Consequences:

* a one-row difference is **exactly one write request**, not a fragment of a batch;
  all counted columns move together, so the whole row is present or absent;
* per-device row counts legitimately differ (133-138 across devices here) because
  each device is written at its own pace -- never judge by a total;
* `POINT_STEP=1000` makes the differing row identifiable to the millisecond: diff
  `select time from usr_sod0.tab_0 where device_id='...'` between replicas and feed
  that timestamp to the WAL comparison. A count-level diff is a weak symptom; a
  `(device, time)` diff is the one to ask R&D about.

**Never compare row counts across models.** `table` and `table_view` are separate
benchmark processes writing through different tables (the view profile writes through
a writable view), and at the same instant their counts differ on most devices
(e.g. `d_0`: `table` 138 vs `table_view` 135 of 100 devices). Only same-model,
same-SQL comparisons across cluster shapes are meaningful.

**"A replica one row apart while `syncLag=0`": the failure paths are measurable, and
they were all empty.** On the 2026-09-23 instrumented run (DEBUG on `DispatchLogHandler`,
`IoTConsensusRPCServiceProcessor`, `IoTConsensusServerImpl` and `IndexController`; the
injected loggers survive the run's cluster reset) one occurrence reproduced -- `table`,
device `d_54`, 135 all-up vs 134 with `11.101.10.6` down -- and nothing that can *lose* an
entry had fired:

| candidate path | site | measured |
| --- | --- | --- |
| sender drops a batch on `TApplicationException` (`completeBatch`, never re-sent) | `DispatchLogHandler:145-151`, WARN | 0 (`Skip retrying this Batch`) |
| sender completes a batch whose substatuses are unsuccessful but not retryable | `DispatchLogHandler:95-109`, DEBUG only | 0 (`complete but contains unsuccessful status`) |
| receiver stops waiting for a missing batch and jumps `nextSyncIndex` past it | `IoTConsensusServerImpl:1609-1620`, INFO | 21 events, **all `target=-1`** (fresh baseline), none skipping a real range |
| channel (re)build resumes past what the receiver already has | `buildSyncLogChannel` | 24 resumed builds, 0 gaps |

Plus 0 non-success per-entry apply statuses, and **no hole in any of the 27 receiver
streams** (93,051 batches, checked per `(receiver, region, sender)`). So the row never
entered the failure paths at all: the only boundary that emits no entry, and therefore
leaves no error behind, is channel creation, where the snapshot's *content* index has to
agree with the resume index.

**Do not report `firstApplied = initialSyncIndex + 1` as an off-by-one loss.**
`initialSyncIndex` means "the last index the peer is known to have" and the sender resumes
at `+1`. For a newly created replica it is `getMinSyncIndex()`
(`IoTConsensusServerImpl:1247`) -- the minimum ack across the *other* peers, falling back
to this node's search index -- while the snapshot the new replica loads was taken at an
index of its own, and the two are never logged together. Whether they agree is therefore
unobservable today; measure it with timestamp lists instead of inferring a loss from `+1`.

**Localise the row with per-device timestamps, never with counts.**
`scripts/rcdn/sentinel_times.py <run-dir>` watches `cases/*/*.norm` and, for every capture
stage, stores each device's full timestamp list under `sentinel/<stage>__<model>.times`.
One write is one row (`BATCH_SIZE_PER_WRITE=1`), so the set difference names the exact
`(device, time)` **and its direction**: present only in the all-up baseline means the
survivor lost it; present only in a stop capture means the stopped node has an extra row
(duplicate, or snapshot/stream overlap). Run it alongside a repro -- the next case resets
the cluster and the answer is gone within minutes.

**Operational notes for this kind of probe:**

* `IndexController`'s DEBUG lines land in **`logs/log_datanode_debug.log`**, not in
  `log_datanode_all.log` -- grepping the all-log makes a working DEBUG config look
  dead (that mistake was made here, and the 28k DEBUG lines were there all along).
  A logger added to `conf/logback-datanode.xml` **does** survive the run's cluster
  reset.
* Kill a background watcher by **PID file**, never `pkill -f <script>`: the ssh
  command line itself contains the script path, so the pattern matches the shell
  running it and the session kills itself. The `[v]erwatch` bracket trick does not
  help when the same command line also contains the real `/tmp/verwatch.sh`.

**Two known issues sit in this same code area; they are NOT one root cause.**
`LogDispatcher.getMinSyncIndex()` takes the *minimum* `currentSyncIndex` over the
threads still in `threads`, and `syncLag = getSearchIndex() - getMinSyncIndex()`:

* **TDB-403** -- on abnormal exit or an early return, `removeLogDispatcherThread()`
  leaves a dead thread in the list with a frozen index, so `min` is pinned low and
  `syncLag` sits at a non-zero constant forever. **Metrics and resources only; the
  data is fine** (its own record says replicas were byte-identical). The tell is
  that the region has **already disappeared from `show regions`** while its
  per-region `syncLag` is still reported -- resolve the reported DataRegion id
  against `show regions` before believing a pin. (A pinned `syncLag` on a region
  that *is* still listed is a different, genuinely stalled pipeline.) It reproduces
  live: `syncLag pinned at 231.0 for DataRegion[4] on 11.101.10.9` while region 4
  was gone from `show regions`.
* **the unresolved replica shortfall** -- an earlier write-up claimed `min` was used
  as the rebuilt channel's start index and was therefore too **high**, skipping the
  gap. **That is refuted** (above): `min` applies only when the progress file is
  missing, and it is high for benign reasons.

`syncLag` returning to 0 still does **not** mean replicas agree -- it is derived
from the very bookkeeping under discussion. Never use it as the consistency gate on
its own; compare per-replica query results (`analyze-diff`). Fixing TDB-403
(unregister in `finally`, ignore stopped threads) does **not** fix data loss and
would make it look healthier.

**A negative result worth keeping:** per-region `consensus/data_region/<db>_<id>/writer.meta`
holds `{version, lastIndex, timestamp}` (20 bytes, big-endian) and can be sampled
per node. But a replica that was loaded from a snapshot legitimately starts at a
low index, so **cross-replica index comparison proves nothing**; and a region's
index stops advancing simply because the write load has stopped. Sample twice
before drawing any conclusion -- that two-sample test is itself the check for
"is the cluster still writing?" (0 advances in all regions = load finished).

## Locating a replica inconsistency after the fact: `analyze-diff`

A finished case carries everything needed to explain its own failure, so do not
re-derive it by hand from logs -- that is how a wrong cause gets written down.
`analyze-diff` reads a run directory offline (no cluster, no ssh) and prints, in
order:

1. **the direction** of the disagreement -- baseline vs every stopped-node
   capture, per differing key, with how many columns went up and how many down.
   The direction alone never says which replica is wrong, and it is *not* stable
   between failures (the same case has shown the baseline higher once and lower
   the next time), so never report it as "replica X is missing data";
2. **which node's view is short**, from the forensic per-node re-run;
3. **files some replicas hold and others do not**, computed from the captured
   per-replica inventories;
4. **the migration map** -- per node, which regions it transmitted as a snapshot
   source and which it received as a target, plus its restart markers; this is
   what turns "some replica is short" into "region 6 was mid-migration from A to
   B when A was restarted";
5. **the TDB-406 window** -- whether any TsFile entered closing before a snapshot
   started and finished flushing after it completed (see the note above on why a
   file the *snapshot itself* closes is not this case).

```bash
scripts/rcdn.sh analyze-diff --run-dir rc3_run/results/run_<ts> --case dn_remove_restart
```

Point 6 is the one that decides the attribution. "A .tsfile one replica lacks"
is the shallow signature of BOTH a snapshot that omitted it (TDB-406) and a
replica that never received the writes made after its snapshot landed. The
TsFile name starts with the millisecond timestamp of its first write, and the
logs carry each region's snapshot completion time, so `analyze-diff` compares
them and says which one it is: a missing file created **after** its region's
snapshot was never a member of that snapshot, so the replica is missing
post-snapshot writes; a missing file created **before** it could be a member
that `createSnapshot` skipped. Do not skip this step -- the file inventory alone
looks identical in both cases.

Point 4 is the one that pays: cross-reading the migration map against which
query disagreed and which model it belongs to narrows the candidates to the
regions that actually moved.

## Proving a defect with a patched build, and naming the exact `(device, time)`

Two capabilities that turn "a count differs" into "this row, on this replica, at this time".

### Testing a patched build (diagnostic or fix)

`run`/`matrix` **never re-unpack `DEPLOY_TARBALL`**: the per-case "resetting cluster" is an in-place
`stop -> wipe -> configure -> start`, and `unpack()` has exactly one caller, `cmd_deploy`. Consequences,
both measured: a jar you swap on the hosts survives every later case, and a `DEPLOY_TARBALL` pointing at
a patched zip is **silently ignored by `run`** (after a run reset the deployed jar still held the
release's bytes).

    # 1. build the patched deployment package (replace only the changed class files)
    # 2. deploy it -- this is the step that actually unpacks
    rcdn.sh --conf conf/cluster.patched.conf deploy --clean
    # 3. verify by CONTENT, on every host
    ssh <host> sha256sum <DB_DIR>/lib/timechodb-server-<ver>.jar
    # 4. run the case against the patched deployment
    rcdn.sh --conf conf/cluster.patched.conf run --case dn_remove_restart --repeat 3

**Never verify by mtime.** The jar inside a release package carries a fixed timestamp
(`2023-11-08 22:14:22` for 2.0.12.1), so an unpacked jar and a stale one look identical; compare the
sha256. To prove the patch is really in the artifact, read a class out of the jar on the host:

    python3 -c "import zipfile;z=zipfile.ZipFile('<DB_DIR>/lib/timechodb-server-<ver>.jar');\
    d=z.read('org/apache/iotdb/consensus/iot/IoTConsensusServerImpl.class');\
    print(b'<your new literal>' in d)"

Note that `deploy` also re-unpacks `conf/`, so any logback level you injected there is reverted by it.

### Compiling one module without Maven

`thrift`/`protoc` are typically absent, but the release ships a **fat jar**
(`lib/timechodb-server-<ver>.jar` + `lib/common-dependency.jar`) holding every dependency and the
generated sources, so a single module compiles straight against it:

    find <module>/src/main/java -name '*.java' > sources.txt      # main/java only
    javac -nowarn -proc:none -encoding UTF-8 \
      -cp lib/timechodb-server-<ver>.jar:lib/common-dependency.jar -d classes @sources.txt

Two traps: `src/main/i18n/{en,zh}` define the **same** classes (the build picks one locale, and the fat
jar already has them) and `src/test` needs JUnit. Then replace only the changed `*.class` entries inside
a **copy** of the fat jar, and assert `major == 61` (JDK 17) for both the original and the compiled class.

### Naming the exact `(device, time)` -- live, and after the fact

Counts cannot tell loss from duplication, and the next case wipes the data. Two tools:

* `sentinel_times.py <run-dir>` -- watches `cases/*/*.norm` and stores each stage's **whole**
  `select device_id, time ... order by time` inventory. One SQL per stage, so a stage never straddles the
  moment a node is stopped. File names carry the **case** (`<case>__<stage>__<model>.times`): every case
  sweeps the same `stop_*` stages, and a stage-only name silently reuses case 1's inventory (that cost
  the exact timestamps of a real diff once).
* `diff_stage_times.py <run-dir>` -- compares each stop stage against that case's all-online baseline and
  prints `MISSING on the surviving replica: d_xx @ <stamp>` (the survivor lost it) or
  `EXTRA on the stopped replica: ...` (duplicate/overlap). The two directions are different defects, so
  never report a bare count difference.

When a diff was found but the sentinel missed that stage, the site can still be recovered: the data
survives the end of a `run` (the case reset is in-place and `teardown` only stops). Bring the cluster
back **without wiping** and re-capture:

    python3 - <<'PY'
    import rcdn.cli as cli
    from rcdn.cluster import Cluster
    cfg = cli.load_config("<conf>")
    _, log, ssh, sql = cli._build(cfg, "recover", False)   # cli._build also builds the Logger
    c = Cluster(cfg, ssh, sql, log); c.discover_ports()
    c.start_all()                                          # start only -- never prepare/wipe
    PY

then `cluster.stop_node(host, "dn")` and query through a CN in both states. Measured this way:
`wv_0_v / d_80 @ 2026-09-23T15:16:25.301+08:00`, present only on the restarted node's replica and
absent from its peer, 7 s after `remove datanode` was submitted.

`rcdn.remote` helpers return a `Result` object (`rc/out/err/host/cmd`), not a string -- read `.out`.

---

## Operational traps (measured, not guessed)

Each of these produced a **false conclusion** before it was caught. Read them
before interpreting any observation.


### A test suite that runs nothing and exits 0 reads exactly like a pass (FIXED)

`smoketest.py` and `selftest.py` used to define their entry point as a plain
function with no `if __name__ == "__main__"` guard. Running either as a module
therefore only imported it: exit status 0, **no output at all**, and a green
light for a suite that never executed. That is how a "selftest passes" claim and
a "smoketest passes" claim both got written into a report before anyone noticed
the runs took ~0 s. Neither suite had ever run.

Both modules now carry the guard, so `python3 -m` works and prints the per-case
table. Verify any suite actually executed before trusting its exit code — an
empty output with status 0 is the signature of this trap, not a pass:

```bash
python3 -m scripts.rcdn.selftest                        # offline, ~1 s, prints PASS lines
scripts/rcdn.sh --conf conf/cluster.conf smoketest      # offline, ~50 s, prints a per-case table
```

Anything that reports success **without printing anything** has not run.

If a check produces no output, that is not a pass — it is an unrun check.

### Removing a DataNode does not necessarily delete its files

Deleting a removed DataNode's data is that DataNode's **own** action: migrations
finish, it drops each local replica, then it stops. Nothing outside the process
can delete files on a dead node's disk, and a removed node is refused on restart,
so once the process is gone no later startup finishes the job. Leftovers are
therefore only a defect when the removed node was **alive and healthy for the
whole procedure**:

* `selector=unknown` — removed while stopped, so files are *expected* to stay.
* `abnormal=kill9_target` — the case SIGKILLs the very node being removed, so it
  cannot finish. Residue is *expected* and is recorded in `steps`.
* `abnormal=kill9_other_dn` — the removed node stays alive, so leftovers are a
  real FAIL.

Measured on 2.0.12.1: the `kill -9` lands *after* the node has finished the
deletions it had started (both SchemaRegion deletions carry `Succeed to
deleteRegion`) and *before* the first DataRegion deletion is submitted — so
nothing is left half-done, and a case asserting cleanup here would be asserting a
guarantee the product never makes. Do not "fix" it back.

The restart probe (step 6b) exists so that "the files stayed" is never silently
accepted -- but the *right* question is whether the removal cleaned up, not
whether a restart happens to succeed, because the two are linked by design:

| removal | data after it | restart |
|---|---|---|
| Running, nothing injected (`dn_running_remove`) | **0 files** | **starts, re-joins under a NEW node id** |
| killed mid-removal (`dn_remove_kill9_target`) | ~40 MB kept | **refused** |

Both measured on 2.0.12.1. The refusal is the product's documented guard:

```
ERROR DataNode:412 - Fail to start server
  StartupException: Reject DataNode restart. Because there are no corresponding
  DataNode(whose nodeId=N) in the cluster.
    1. Maybe you've already removed the current DataNode(whose nodeId=N).
       Please delete the useless 'data' dir and retry start.
```

The ConfigNode rejects the restart in `ClusterNodeStartUtils.confirmNodeRestart`
(the nodeId is no longer in `getRegisteredDataNodes()`), so the DataNode throws
before it ever reaches `DataNode.makeRegionsCorrect()` -- the startup self-clean
that would have deleted the invalid regions. So a killed node's leftovers need
manual deletion, and until then it cannot re-join under any identity. That is a
deliberate safety trade-off, **not** a defect: `kill9_target` therefore records
the refusal and passes, while a removal that had every chance to clean up still
fails if it cannot restart.

### `SET CONFIGURATION` persists but does **not** take effect

It only rewrites `conf/iotdb-system.properties`. To actually apply it you must
follow with a reload **on that node**:

```sql
SET CONFIGURATION "dn_metric_level"="ALL" ON 5;   -- writes the file only
LOAD CONFIGURATION ON LOCAL;                       -- applies it (on the node you are connected to)
```

Two syntax traps, both hit in practice:
* the key **must be double-quoted** — `dn_metric_level='ALL'` fails with
  `700: ... mismatched input 'dn_metric_level' expecting STRING_LITERAL`;
* `metric_level` has no `DEBUG` — that value fails with
  `301: No enum constant ... MetricLevel.DEBUG`.

This is the documented, deterministic way to drive
`MetricService.restartService()` (`ClusterConfigTaskExecutor.java:1626` →
`IoTDBDescriptor.loadHotModifiedProps()` → `reloadMetricProperties()` →
`reloadService(RESTART_METRIC)`).

### Counting metrics: `grep -c` returning 0 is **not** a failure

`grep -c` exits non-zero when the count is 0. A helper that maps a non-zero exit
to "endpoint unreachable" will report `-1` for a *healthy but empty* result and
send you chasing a dead node. Always append `; true`, and separately verify the
endpoint with `curl -o /dev/null -w '%{http_code}'`.

### `ps -ef | grep org.apache.iotdb` can report 0 while the node is **running**

The launched command line does not reliably contain that string. Do not conclude
"the cluster is down" from it — check the listening ports
(`ss -lnt | grep -E ':(10710|10730|6667|9091|9092)'`) or the metrics HTTP code.
A wrong "cluster is down" reading invalidated a metrics measurement during
development.

### Known product defect: a hot config reload permanently destroys `client_manager_*`

`ClientManagerMetrics.unbindFrom()` ends with `poolMap.clear()` (line 219) while
`bindTo()` then iterates the now-empty map — and the `ClientPoolFactory`
singletons never re-register, so `registerClientManager` is never called again.
Two distinct symptoms follow; **do not conflate them, they differ by an order of
magnitude in severity**:

**(B) Silent, permanent metric loss on a LIVE process — the real defect.**
Measured **9/9** with zero stops involved: trigger `restartService()` on a
running DataNode and a whole batch of metric families is **unregistered** —
roughly **391 series across 14 names**, reproduced identically in two full
snapshots (2670→2297 and 2729→2293). The biggest casualty is **not**
`client_manager`:

| family | series lost |
|---|---|
| `thread_pool_active_thread_count` / `core_size` / `done_task_count` / `largest_pool_size` / `waiting_task_count` | **61 each = 305** |
| `client_manager` | 64 |
| `file_global_*`, `file_level_*`, `object_file_global_*` | 18 |
| `pipe_schema_linked_queue_size`, one ratis counter | 4 |

Nothing recovers without a process restart (`client_manager` verified 0→64;
still 0 minutes later, series count frozen). **These are unregistered, not
zero-valued** — a gauge whose value is 0 still emits a line, so a vanished
series means `metricService.remove()` ran. No log line, no error: completely
silent, so any alert on those gauges just stops firing. Only the triggered node
is affected.

`unbindFrom` is **not** an exit-only path: it has three call sites, two of them
at runtime (`restartService()`, reachable from `LOAD CONFIGURATION` or JMX via
`MetricServiceMBean`; and `removeMetricSet()`); only `stopService()` is the
shutdown one. Trigger it with:

```sql
SET CONFIGURATION "dn_metric_level"="ALL" ON <dnId>;   -- must differ from the current value
LOAD CONFIGURATION ON LOCAL;                            -- -> restartService() -> unbindFrom()
```

> **Set the value to something *different*.** An unchanged value does not fire
> `RESTART_METRIC` at all — a whole measurement round can silently become a null
> experiment this way (a node that boots with `ALL` and is then told `ALL` does
> nothing). Read `dn_metric_level` out of `conf/iotdb-system.properties` first,
> or assert `restart successfully` incremented before trusting the round.

Source-level scope: `unbindFrom` implementations that clear their own registry
exist in **5** metric sets — `ClientManagerMetrics:160` and `ThreadPoolMetrics:157`
are **confirmed** (bindTo iterates the just-cleared map);
`ProcedureMetrics:68`, `RatisMetricSet:110` and `MigrationMetrics:57` have the
same shape but were **not verified** to lose metrics. (`RatisMetricSet` calls
`manager.clear()` on what looks like the *global* `MetricRegistries` — worth a
look in its own right.)

**(A) A scrape in flight during that unbind throws NPE — mostly a shutdown artifact.**
`scrape()` iterates the *live* `ConcurrentHashMap` returned by `getAllMetrics()`;
a weakly-consistent iterator can hand out an entry that was just removed, and
`IoTDBAutoGauge.getValue()` then dereferences `poolMap.get(poolName)`, which
`unbindFrom` already cleared. All three known occurrences sit in a **stop**
window, and a clean decision run on the live hot-reload path hit it **0/9** —
the window needs scheduling jitter to open, and only shutdown load provides
enough of it. So the NPE really is mostly a shutdown-window phenomenon; the
place it bites is an ERROR line plus one failed scrape, not the metrics
themselves.

**Read this before designing a repro.** The gauges exist only between pool
registration and the *first* unbind, so **each DataNode process gives exactly one
chance**. A storm of `restartService()` calls is useless for (A): the first one
destroys the very gauges the NPE needs, and calls 2..N cannot possibly hit
(verify: `curl .../metrics | grep -c '^client_manager'` stays 0 afterwards). To
reproduce (A) on the shutdown path:

```
1. start the DataNode (pools register, gauges arm)  -> client_manager should be 64
2. run N concurrent `curl http://127.0.0.1:9092/metrics` loops    (N ~= 24)
3. gracefully stop the DataNode (./sbin/stop-datanode.sh)  <- the first unbind
4. grep log_datanode_all.log for ClientManagerMetrics.lambda
5. restart the DataNode to re-arm, repeat
```

Measured: hits within 2-4 rounds, reproducible across runs. Note that on
V2.0.12.1 the scrape runs on the reactor HTTP thread
(`PrometheusReporter.java:108`); master additionally had an internal 5-second
snapshot thread, which is why it fired there with no external pull at all.
Search for `ClientManagerMetrics.lambda` — the two versions word the log
completely differently (master: `PrometheusReporter failed to update metrics
snapshot`; V2.0.12.1: reactor's `Error starting response`).

Do not leave a leaked `dn_metric_level=` / `dn_metric_async_collect_period=` line
in `iotdb-system.properties` (same leak hazard as `disk_space_warning_threshold`
above).

### A `run`/`matrix` invoked while you are also poking the cluster proves nothing

Ad-hoc `SET CONFIGURATION` / `LOAD CONFIGURATION` traffic aimed at a node that a
case is about to stop or restart **contaminates that case's verdict** (observed:
`failed to restart <ip>`, `<ip> is unknown`, then query failures). If you run a
side-car experiment, disclose it and exclude the affected case rather than
reporting the FAIL as a product defect.

### Killing a run externally leaves its benchmark writers alive (measured)

The three workload writers are local `java` processes started by the `rcdn` run. Killing the run
(`kill -9 <pid>`, or even its process group) does **not** reliably take them with it: after a run was
killed at 15:59, three of its writers kept appending until their own workload horizon expired ~40 min
later. The symptom is unmistakable: the next case's consistency stage loops with

    dataset still moving (attempt N/8; differs: table,table_view,tree); waiting

while the per-stage row counts keep **growing** (measured 35k -> 46k rows for a case that normally ends
near 13.5k). Nothing is wrong with the product -- the dataset really is moving. After any external kill,
before starting another case:

    ps -eo pid,ppid,etime,cmd | grep '[j]ava'      # expect: empty
    pkill -9 -f 'iot-benchmark'                    # if not

`rcdn teardown` stops them properly; only an external kill leaves orphans.

Related shell trap, measured **three** times in one session: `pkill -f <pattern>` fires on any process whose
command line matches, and that includes the shell running the `pkill` itself whenever the pattern appears
**anywhere** in the same command line -- not just in the `pkill` argument. A heredoc whose body mentions
`rcdn.correlate_snapshot_stream` was enough to kill the enclosing shell before the heredoc was even written.
The bracket trick only helps for the `pkill` argument itself. Prefer resolving pids without a self-match:

    for pid in $(ps -eo pid,cmd | awk '/[r]cdn\.sh/ && !/awk/ {print $1}'); do kill -9 "$pid"; done

### The receiver side cannot judge a gap by itself -- correlate by snapshotId (measured)

The natural receiver-side check ("first index of the incoming stream > local applied index + 1") is misleading on
its own: the receiver's `searchIndex` is only what **its own WAL reader** restored, and after a snapshot load it is
typically `0` while the snapshot actually covers thousands of entries. Measured in one case: 30 channel baselines,
6 with `first > local + 1`, and 4 of those followed a snapshot load by only 21-483 ms. All 6 were false alarms --
the snapshot covered them.

Correlate the three sides by the snapshot uuid instead (both `takeSnapshot` on the sender and `loadSnapshot` on the
receiver carry the same `snapshot_<region>_<uuid>`):

    PYTHONPATH=scripts python3 -m rcdn.correlate_snapshot_stream conf/cluster.diagnostic.conf

Per migration the verdict is `firstStreamIndex <= snapshotIndex + 1` -> no hole (the remainder is idempotent
overlap), `>` -> a **permanent** hole of `first - snapshotIndex - 1` entries that no other detector can see.
Measured 2026-09-23: 4 migrations, 0 holes, 0 undecidable.

The verdict logic itself has a synthetic regression fixture (1 hole + 1 overlap) so that a "0 holes" reading can be
told apart from a broken detector:

    PYTHONPATH=scripts python3 -m rcdn.correlate_snapshot_stream --raw scripts/rcdn/testdata
    # expect: 确认空洞 1 / 无空洞 1

Instrumentation recipe, all inside `IoTConsensusServerImpl`:

* sender -- `takeSnapshot()` logs `searchIndexAtSnapshot` plus `pendingResume` (record the handed-out index in
  `buildSyncLogChannel()`), and `buildSyncLogChannel()` logs `initialSyncIndex`. Note the ordering: the channel is
  built **before** the snapshot, so `searchIndexAtLastSnapshot` is still `-1` at that moment; the snapshot line must
  carry the resume index itself.
* receiver -- in `SyncLogCacheQueue.cacheAndInsertLatestNode`, guard **every** statement that advances
  `nextSyncIndex`. There are three (the two `end+1` assignments and the `Math.max(...)` timeout jump), and the
  timeout jump is the one that can silently skip a range. `nextSyncIndex == -1` -> INFO `receive baseline`
  (first streamed index, local `searchIndex`, ms since the last snapshot load); `first > nextSyncIndex` -> WARN
  `RECEIVE GAP`. Use INFO/WARN, not DEBUG: a DEBUG-only probe is invisible under the release logback config.

### A restarted DataNode is a silent no-op while the old JVM is still shutting down (measured)

`ABNORMAL_DN_ROTATE` sweeps a restart over every other DataNode, which is what the member-replacement repro
needs -- but `restart_dn` used to stop the node and start it again immediately.  Under load the stopped JVM
spends **minutes** in its shutdown hooks (measured 15:15:52 -> 15:22:39 on `11.101.10.7`, one sweep case),
and `sbin/start-datanode.sh` runs `check_running_process` and refuses to launch a second node for the same
`IOTDB_HOME`, so the start is a **silent no-op**: the node stays down for the whole case and the verdict is
"DataNode X did not come back to Running after the case" + `syncLag cannot drain: X is unknown` -- for a
restart that never happened.  Measured twice in 15 sweep cases (`#12`, `#15`), each costing ~1500 s because
the sync gate then waits out its timeout.

`restart_dn` now does what the restart probe already did: record the old pids, stop, **wait for them to
disappear** (`CLUSTER_STOP_TIMEOUT_SEC`), start, require a **new** pid, retry the start once, and only then
wait for `Running`.  Without that guard the README's "Restart a DataNode under load" family of cases can
report a fault it never injected.

### The receiver matches batches by index alone -- a re-created region log silently mixes epochs

`SyncLogCacheQueue.cacheAndInsertLatestNode` accepts a batch only when
`request.getStartSyncIndex() == nextSyncIndex` (IoTConsensusServerImpl:1582).  There is **no leader term, no log
epoch and no lower bound**, and the timeout branch (1618) can only push `nextSyncIndex` forward.  So when a
DataRegion's consensus log is **re-created** during `REMOVE DATANODE` / a leader change (the new log restarts at
index 1) while a follower still holds `nextSyncIndex` from the old log, the follower treats "joining the new log
mid-stream" as a normal resume and **never applies `[logStart, first)`**.

Measured on the one live replica-loss case (`run_20260923_143231` / `dn_remove_restart#3`; table db `usr_sod0` =
DataRegion[6]; diff reported as `'table_view' result differs while 11.101.10.6 is down`):

    .8  <- .10     : 6001..7317   15:16:00 -> 15:16:20   (removal submitted)
    .10 <- .8      :    1..282    15:16:20 -> 15:16:25
    .6  <- .8      :   25..282    15:16:27               <-- 1..24 never delivered to .6
    .6  -> .8/.10  :    1..3      15:16:35               <-- new log, index 1 again
    lost row 2026-09-23T15:16:25.301 sits inside the missing 1..24

Everything stays silent: syncLag reports 0; the receiver-side GAP guard fires only on `start > nextSyncIndex`
(here `start == nextSyncIndex`); the snapshot correlation has nothing to correlate (no snapshot involved).  This
is why "0 holes over N streams" was not the whole story.

Map the database to its DataRegions first (`InsertionCrossSpaceCompaction [<db>-<region>]` in the DN logs), then:

    PYTHONPATH=scripts python3 -m rcdn.channel_resume_audit <run-dir> [<run-dir> ...]

It rebuilds the per-region channel matrix and flags "first accepted index > the region's log start".  Two caveats
learned the hard way: a 1-entry difference is usually the index-0 / snapshot boundary, and a follower that
**joins an already-advanced log** legitimately starts high -- cross-check `snapshot loaded` (or
`correlate_snapshot_stream`) before calling it a hole.  Across ~20 instrumented cases the leader never resumed
mid-log (467 `build channel` events, `initialSyncIndex == minSyncIndex` every time): this shape needs the
log-rebuild / leader-change condition, not merely a rebuild.

**Conf trap**: `conf/*.conf` values must be bare -- an inline comment becomes part of the value
(`BM_REMOVE_AFTER_SEC=45  # shorter` -> `int('45  # shorter')` -> every case aborts with a bogus FAIL).  Put the
comment on its own line.

**Aggressive timing profile** (more samples per hour, same detection power): keep the whole node sweep and squeeze
only the waiting -- `BM_REMOVE_AFTER_SEC=45`, `SYNC_STABLE_SECONDS=12`, `SYNC_POLL_INTERVAL_SEC=5`,
`SYNC_STALL_POLLS=4`, `CONSISTENCY_SETTLE_SECONDS=15`, `RESTART_CLEANUP_SETTLE_SEC=15` measured **10.7 min/case
vs 19.7**.  The big win is `SYNC_STALL_POLLS`: after a removal a dead region's gauge is pinned (e.g.
`DataRegion[6] ... 4296`) and the old default burned 12 polls (~150s) **twice per case**; 4 identical samples
still detect a genuinely frozen gauge, because a converging one changes value and resets the counter.

### Freeze the scene before the harness resets it (or the evidence is gone)

`rcdn run` resets the cluster (stop -> wipe -> configure -> start) **before every case**, so a difference found in
case N is destroyed the moment case N+1 starts. Two tools in `scripts/rcdn/` close that gap:

    # 1. watch the run and stop it the moment a replica difference appears
    PYTHONPATH=scripts python3 -m rcdn.freeze_on_diff <run_pid> <results_dir> [--conf conf/cluster.diagnostic.conf]
    # 2. (or afterwards, while the cluster is still frozen) collect the on-disk evidence
    PYTHONPATH=scripts python3 -m rcdn.collect_freeze_evidence conf/cluster.diagnostic.conf --out DIR --device d_80

`freeze_on_diff` writes `FROZEN.json` plus a copy of the case directory, and with `--conf` it runs the collector
automatically. Validated against a synthetic case (detection, stopping the run, copying the case).

**Never kill a process group here.** `os.killpg(os.getpgid(target), SIGTERM)` looks right and is dangerous: a
background run started from a non-interactive shell shares that shell's process group, so the killpg takes out the
caller too -- it killed this tool's own test harness (measured). Kill the target **process tree** instead
(`/proc/<pid>/task/<pid>/children`, children first). The same reasoning applies to `pkill -f` (see above).

**The WAL cannot tell you whether a replica applied a row.** Every memtable flush checkpoints and truncates the
WAL, so `wal/<db>-<region>/_0-0-1.wal` is a 6-byte header (`V3-WAL`) even while a heavy load is running (measured).
For "did this replica ever apply `(device, time)`", compare TsFiles and query each replica in turn (the sentinel
technique) -- not the WAL.

**Where durable per-replica progress lives**: `consensus/data_region/<db>_<region>/<nodeId>-<appliedIndex>` on each
node; the marker name carries the index, so a frozen scene shows every replica's own applied position and its
record of its peers with no log parsing. On one frozen scene the two replicas of `1_4` disagreed
(`.6` recorded `3=8529`, `.8` recorded `7=0`) -- read these first when a difference appears.

### Confirmed: **silent row loss inside a peer-replacement window** (measured 2026-09-24)

This is the one case where the loss was reproduced on the *instrumented* build, so the row-level loss and the
index-level logs are both available.  Frozen evidence: `results/frozen/FROZEN_dn_remove_restart#15/`.

* Verdict: `replica inconsistency: 'table' result differs while 11.101.10.9 is down` and the same for `table_view`.
* Size: **9 rows inside one <800 ms window** (19:14:38.127–19:14:38.906) on the table DB `usr_sod0`
  (`tab_0` / `wv_0_v`); affected table regions **DataRegion[4] / [6] / [7]**.

**Read the frozen captures to learn *who* is short.**  The per-device counts per shutdown stage say it directly:

| device | baseline | `.9` down | `.8` down | `.7` down | `.6` down | `.10` down |
|---|---|---|---|---|---|---|
| `d_27`/`d_35`/`d_8` | 60 | **59** | **59** | **59** | 60 | 60 |
| `d_89` | 60 | **59**\* | **59**\* | **59**\* | 60 | 60 |

The row disappears **only when the node that LEADS that region is stopped** -- i.e. the row lives on the leader
and the other replica never applied it.  (Derive which node leads which table region from the `build channel`
targets and the `apply map … source=` values; `show regions` lists **tree** regions only, so it will not answer
this for a table DB.)

**Markers to grep in that window** (all present in the confirmed case):

```
Initialized fresh writer meta for group DataRegion[6], recoveredLocalSeq=0        # new replica: WAL restarts at 1
build channel: region=DataRegion[6], target=..., initialSyncIndex=24, minSyncIndex=24
snapshot taken: region=DataRegion[6], ..., searchIndexAtSnapshot=33, minSyncIndex=24
snapshot loaded: region=DataRegion[6], snapshotId=snapshot_6_22af0136..., localSearchIndex=0
receive baseline: region=DataRegion[6], source=6, incoming=[25, 25]               # overlap, NOT a hole
receive baseline: region=DataRegion[6], source=7, incoming=[1, 1], localSearchIndex=234   # two epochs collide
Succeed to deletePeer DataRegion[6] from consensus group
```

**Do not trust the silence.**  In that same window `RECEIVE GAP` was **0**, the sender's index chain was
continuous, and `syncLag` was **0 the whole time**.  Index-level detectors cannot see this loss -- only a
row-level `(device, time)` comparison can (that is why `sentinel_times.py` exists).  The receiver accepts a
batch when `startSyncIndex == nextSyncIndex` and its timeout branch only moves `nextSyncIndex` forward; neither
branch knows the batch came from a different epoch of the region's log, so entries the leader applied during the
replacement are skipped without a single warning.

### A 305 "no detailed failure reason in QueryStateMachine" -- expected, whitelisted, NOT a defect

**R&D decision (2026-09-29): this will not be fixed.**  Recycling a DataNode's resources without first
draining the queries that are still being served by it makes an in-flight statement fail; the alternative
-- wait for every in-flight query before reclaiming -- risks `REMOVE DATANODE` being stuck behind one large
query or many concurrent ones, which was judged worse.  So the harness now treats it as expected:

* `305:` is in `EXPECTED_BENCH_ERRORS` / `DEFAULT_EXPECTED_BENCH_ERRORS` (matched by status code, like 722),
  so a 305-only FAIL no longer fails a case; the lines are still recorded on the result.
* `DN_FAULT_EXPECTED_OUTAGE` (default true) additionally excuses **any** benchmark error whose timestamp falls
  inside a DataNode down-window recorded by `run_abnormal` (`restart_dn`, `kill9_other_dn`, `kill9_target` on a
  DataNode, `other_dn_stop`).  The window is the excuse, never the whole case, and it is asserted in the
  selftest both ways (inside excused, outside still a failure).
* Set `EXPECTED_BENCH_ERRORS=""` (or `DN_FAULT_EXPECTED_OUTAGE=false`) for a strict run that reports them again.

**It is still not data loss.**  A 305-only FAIL is a query failure, not a replica difference: read that case's
per-stage captures (or the sentinel) before saying anything about rows.  The two stacked product defects below
are why the *reason* is unreadable -- they are still worth fixing as diagnosability, even though the failure
itself is accepted.

**Symptom** (client side), on a query *or* a write:

    StatementExecutionException: 305: no detailed failure reason in QueryStateMachine
    Status code: 305, Query Statement: insertTablet failed because no detailed failure reason in QueryStateMachine

**Frequency**: 6 of 73 `dn_remove_restart` cases (~8%) across tree/table/table_view -- it is **not** model
specific, and it is **not** replica inconsistency.  Also measured on the instrumented build: the storm variant
produced it in `dn_remove_restart_storm#2/#6/#9/#14` (2026-09-28/29) alongside real replica diffs in other cases.

**Two stacked defects** (both confirmed in RC3 source + logs):

1. **The reason is thrown away.**  `QueryExecution.retry()` (MAX_RETRY_COUNT=3, RETRY_INTERVAL_IN_MS=2000)
   calls the **no-arg** `stateMachine.transitionToFailed()` once retries are exhausted, and every retry
   already ran `transitionToQueued()`, which sets `failureException`/`failureStatus` back to null.  So
   `getFailureMessage()` can only return the placeholder.  The retry warning itself
   (`QueryExecution:262`) also prints `getFailureMessage()`, i.e. the placeholder -- **the DN log hides the
   failure code too**.
2. **The trigger**: during the removal window a FragmentInstance is still dispatched to the DataNode whose
   region was just deleted.  `FragmentInstanceDispatcherImpl.dispatchRemoteFailed()` logs the real cause and
   wraps it as **306 DISPATCH_ERROR** (retryable per `ClusterScheduler.needRetry`), the query retries 3x2s,
   the migration lasts longer than 6 s, retries exhaust, defect 1 fires.

**The real reason is printed ~2 ms BEFORE the placeholder -- in the dispatcher log, not the query log**:

    WARN FragmentInstanceDispatcherImpl:495 - Execute FragmentInstance failed:
         The consensus group SchemaRegion[3] doesn't exist
    WARN FragmentInstanceDispatcherImpl:618 - can't execute request on node
         TEndPoint(ip:<removed DataNode>, port:10730) in second try, error msg is ...ConsensusGroupNotExistException
    WARN QueryExecution:262 - error when executing query. no detailed failure reason in QueryStateMachine
    WARN AsyncPlanNodeSender:146 - dispatch write failed. status: TSStatus(code:600, ...), code: SYSTEM_READ_ONLY(600)
    INFO QueryExecution:276 - [Retry] retry count is: 1                     # exactly 2.002 s later

**How to diagnose a hit automatically**: `scripts/rcdn/watch_305.py <run-dir>` polls for the symptom and
writes `<run-dir>/305_reports/<case>.md` with the dispatcher targets, the `can't connect to node` counts,
`[ReachMaxRetryCount]`/`[Retry] retry count is` anchors and **every WARN/ERROR within +/-60 s of them**
(the real cause is in that window).  Grep for `FragmentInstanceDispatcherImpl:495|618`, `QueryExecution:262`
and `SchemaRegion[N] doesn't exist` when doing it by hand.

**Suggested fixes to quote to R&D** -- *diagnosability only; the failure itself is accepted (see above)*: keep
the last failure (`transitionToFailed(lastFailureStatus)`), log `getFailureStatus()` in the retry warning,
refresh routing instead of retrying a dispatch to a deleted region, and align the retry budget with the
migration window (exponential backoff for `SYSTEM_READ_ONLY`/`WRITE_PROCESS_REJECT`).  Note
`QueryStateMachineTest:80` currently asserts the placeholder text, i.e. it freezes the defect.  Present these as
"this is why the log cannot tell you what failed", not as a request to change the recycling behaviour.

## Rules

* `prepare`, `matrix` and `run` are **destructive**: they stop the cluster,
  delete `DB_DIR/data` and `DB_DIR/logs` on every node and rewrite
  `iotdb-system.properties`. Never point them at a cluster you care about.
* `run`/`matrix` call `stop_all()` before scanning logs, so the cluster is left
  **stopped** when the last case ends.  The next `prepare` brings it back.
* `doctor`, `discover`, `verify`, `list-cases`, `selftest` and `smoketest` are
  read-only and safe; `smoketest` contacts nothing at all.
* `diskfull` never writes to the volume. It raises the node's own
  `disk_space_warning_threshold` above the real free ratio (`DISK_FULL_SIMULATE`,
  default true; set false and the disk-full cases SKIP). `hasSpace()` then fails
  for every folder and the node takes the identical
  `FolderManager.changeToReadOnlyIfDiskFull` path, reporting `ReadOnly(DiskFull)`.
  The property is hot-reloadable, and the harness restores it at case teardown
  so the node returns to Running. `dn_remove_other_diskfull` is the matrix's
  user of this; the `diskfull` selector is implemented and ready if the case is
  added back.
  **Two safety rules, both learned from a live incident (2026-09-18):**
  (a) the `ON <nodeId>` clause is **mandatory** — it is optional in the grammar
  (`IoTDBSqlParser.g4:1326`) and omitting it applies the raise **cluster-wide**,
  which silently turns the case into "the whole cluster is disk-full";
  (b) `set configuration` **persists** to `conf/iotdb-system.properties`, and the
  teardown restore can itself fail (most likely precisely when the case has
  broken the cluster's SQL path). A leaked raise is therefore not self-correcting:
  one leak left five DataNodes disk-full and poisoned eight consecutive cases
  with no warning. The harness now enforces (a) and re-checks the property at
  **case start** (`clear_raised_disk_thresholds`, which logs a loud `WARNING`).
  If a case ever fails in setup for no obvious reason, check
  `grep -E '^disk_space_warning_threshold' <DB_DIR>/conf/iotdb-system.properties`
  first — an uncommented line there is a leaked fault.
  **The state is entered on a write attempt, not on a timer** — measured on a
  live 3C5D cluster, a node flips ~8 s after the threshold change while a writer
  is running, and never flips on an idle cluster. So this fault is only
  meaningful under load, which is exactly how the cases run. Compare status with
  `status_is()`, never against the raw string: the qualifier is real.
* The sync-lag gate needs *a* data source, not Prometheus specifically. With
  neither `MONITOR_URL` nor the DataNode metrics port reachable, the gate is
  skipped and the run is only as strong as the consistency sweep — say so when
  reporting results. Check `doctor` to see which source was selected, and state
  it alongside any PASS.
* Report the cluster version (`SHOW VERSION`) and the git commit of the build
  under test with any result — a remove bug is version specific.

### Known product defect (PLM TDB-1169): remove-DN region migration can permanently lose writes

Region migration during `REMOVE DATANODE` can drop writes: after the snapshot is sent, the to-be-removed
node may still accept writes; if the target went ReadOnly (sync rejected with `code:600 ... read-only`),
those writes never reach the new replica and die with the removed node — replica data inconsistency.
R&D confirmed it as a bug (fix direction: make the region read-only on the to-be-removed node when the
snapshot send starts; later add a DN API for region-granularity status).

- PLM: https://plm.infra.timecho.com/iterations?productId=1&itemId=1169
- RN doc: https://plm.infra.timecho.com/docs/917
- Identification, timeline and the evidence to collect: `references/known-defects.md`
| `dn_object_single_4g` | `object_single` | writes ONE 4 GiB OBJECT point in 8 MiB `to_object(isEOF, offset, X'..')` chunks (512 statements), migrates the region and verifies the value with ranged `read_object(o, offset, length)` chunk reads (256 MiB each, `length()` + `sha256()` compared per chunk before and after the migration) plus the `.bin` size on every replica. Conf: `conf/cluster.rc11_singleobj.conf` |
| `dn_object_manyfiles_residue` | `object_many` | writes ~1e5 small OBJECT files (1 KiB, `BM_POINT_STEP=0` overwrites), migrates every region and checks follower-only residue (TDB-861 with many files). Conf: `conf/cluster.rc11_manyobj.conf` |
| `dn_object_big_migrate` | `object_big` | writes ~4 GiB of OBJECT payloads in segments (benchmark `BM_OBJECT_LENGTH`), migrates every data region, then requires byte-identical `sha256(read_object(..))` samples, matching replica `.bin` totals and no follower-only residue. Conf: `conf/cluster.rc11_bigobj.conf` |

