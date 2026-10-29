# Case matrix reference

`cases/remove_cases.tsv` — tab separated, `#` comments and blank lines ignored.
Every row is one end-to-end case: rebuild the cluster, start the load, act,
wait, verify.

| # | column | meaning |
|---|--------|---------|
| 1 | `case_id` | stable identifier; also the `results/<run>/cases/<case_id>/` directory and the `--case` argument |
| 2 | `target` | `dn` or `cn` |
| 3 | `selector` | which node of that kind is picked (below) |
| 4 | `abnormal` | comma separated operations injected *while the remove procedure runs* |
| 5 | `data_rf` | `default`, `1`, `2` or `3` — written into `data_replication_factor` by `prepare` |
| 6 | `schema_rf` | `default`, `1`, `2` or `3` |
| 7 | `workloads` | `default` (= `BM_WORKLOADS`) or an explicit subset such as `tree,table` |
| 8 | `notes` | free text, copied into the report |
| 9 | `extras` | optional, comma separated extra verification stages (blank = none) |

`extras` turns on the OBJECT / region-migration audits:

| extra | verification |
| --- | --- |
| `object_size` | `SHOW REGIONS FROM <table_db>` (relational dialect) per replica: `ObjectSize` must be non-negative, non-zero when the replica holds `.bin` files, equal to the physical bytes within `max(1 MiB, 10%)`, and equal across replicas |
| `cold_restart` | on top of `object_size`: stop the cluster, delete every `TableObjectSizeFile_*`, start it again, audit again -- a cache-less start is the TDB-835 shape |
| `object_delete_residue` | confirm residue: files a follower has and the leader has not, intersected with the leader's `log_datanode_object_deletion.log` removed paths (TDB-861). The window is armed deterministically: OBJECT overwrite churn on a probe table + a targeted `MIGRATE REGION` (case runs with `selector=skip`, i.e. no whole-node removal); `OBJECT_PROBE_MIGRATE=false` restores the legacy DELETE-burst injection |

`data_rf` / `schema_rf` / `workloads` are consumed by `prepare` and by the
benchmark driver, so a case that changes them implicitly means
`RESET_CLUSTER_PER_CASE=true`.

---

## Selectors

### DataNode

| selector | how the target is put into that state | expected to be removable |
|----------|--------------------------------------|--------------------------|
| `running` | nothing, it is Running | yes |
| `unknown` | `sbin/stop-datanode.sh` and wait until `SHOW DATANODES` no longer says Running | yes |
| `readonly` | `set system to readonly on local;` on the target, wait for `ReadOnly` | yes |
| `diskfull` | raise the node's own `disk_space_warning_threshold` above its real free ratio so `hasSpace()` fails for every folder and `FolderManager.changeToReadOnlyIfDiskFull` marks it `ReadOnly`/`DISK_FULL` — the genuine disk-space path, **nothing written to the volume**. Needs `DISK_FULL_SIMULATE=true` (default), otherwise the case is `SKIP`ped. **No shipped case selects this any more** — `dn_readonly_remove` covers the removal path; add a row back to use it | yes |
| `nonexistent` | pick no node at all; submit `REMOVE DATANODE <unknown id>` | no — every remove must be **rejected** and the cluster must stay healthy |
| `multi` | `MULTI_REMOVE_COUNT` (default 3) Running nodes are removed one after another, each fully drained before the next | yes |
| `concurrent` | two `REMOVE DATANODE` procedures are submitted back to back; the second is issued by the `concurrent_remove` operation | yes |
| `adding` | the last DataNode of the inventory is held back from the cluster start, then joined during the case and removed (grow-then-shrink). `SPARE_DN_HOSTS` overrides with a host outside `nodes.conf`; **`SKIP`ped when neither is possible, or when holding one back would leave fewer than max(schema_rf, data_rf) DataNodes** | yes |
| `rf_limit` | DataNodes are removed until only `data_replication_factor` remain; one further remove is then attempted | the last one must be **rejected** by the replication-factor guard |

### ConfigNode

| selector | how the target is chosen | expected to be removable |
|----------|--------------------------|--------------------------|
| `leader` | the row of `SHOW CONFIGNODES` whose `Role` is `Leader` | yes — a new Leader must be elected and the cluster must survive |
| `follower` | any Running `Follower` | yes |
| `stopped` | a ConfigNode that is **not** listed in `SHOW CONFIGNODES` at all (its process is down) | expected to fail or to be a no-op; the case fails if the cluster loses quorum |
| `nonexistent` | no node; submit `REMOVE CONFIGNODE <unknown id>` | no — must be **rejected** |
| `shrink` | ConfigNodes are removed one at a time down to a **single** node; a schema-mutation probe runs after **every** removal | the cluster must **keep serving** at each step — a one-member ConfigRegion is a valid group, so this is not expected to be refused. `rf_limit` (DataNode) and `shrink` (ConfigNode) are deliberately different names because they test different things |
| `shrink_leader_first` | Same shrink to a single ConfigNode, but the Leader is removed **first** (while three still exist) and a Follower last | companion to `shrink`: `shrink` removes the Leader last, so running both isolates whether the observed outage comes from removing the Leader at size 2 or simply from reaching a single-member ConfigRegion |

`stopped` is resolved from the inventory minus `SHOW CONFIGNODES`, so the
ConfigNode must have been stopped before the case (an abnormal operation or a
previous step does it). When no such node exists the case is `SKIP`ped.

---

## Abnormal operations

Injected `BM_REMOVE_AFTER_SEC` after the load starts, immediately after the
remove statement is issued. Several may be comma separated; they run in order.

| op | effect | source case |
|----|--------|-------------|
| `none` | nothing | — |
| `kill9_target` | `kill -9` the node being removed. Because cleanup is that node's own action, this makes leftover files **expected** — see "Result semantics" | tc118 |
| `kill9_other_dn` | `kill -9` a *different* Running DataNode | tc114 |
| `restart_dn` | stop + start a different DataNode | tc13 |
| `restart_cn` | stop + start a different ConfigNode | tc19 |
| `kill9_cn` | `kill -9` a different ConfigNode | tc28 |
| `stop_cn` | graceful stop of a different ConfigNode | tc25 |
| `concurrent_remove` | submit a second `REMOVE DATANODE` for another node while the first runs; a rejection is acceptable | tc116 |
| `remove_twice` | re-submit the same remove; a rejection is acceptable | tc15 |
| `invalid_sql` | submit malformed / illegal remove statements and require all of them to be rejected | tc104, tc20 |
| `load_balance` | issue `LOAD BALANCE` mid-procedure | tc38 |
| `other_dn_readonly` | `set system to readonly on local` on a different DataNode | tc113 |
| `other_dn_stop` | graceful stop of a different DataNode (it becomes Unknown) | tc114/tc115 |
| `other_dn_diskfull` | drive a different DataNode to `ReadOnly`/`DISK_FULL` by raising its disk threshold; needs `DISK_FULL_SIMULATE=true` | tc120 |

**Healing.** When the remove procedure has drained, the runner restarts any
DataNode that an abnormal operation left down and deletes every
`rcdn_fill_disk.tmp`. The sync-lag and consistency gates run only after that,
so an abnormal operation cannot masquerade as a consistency failure. The
*removed* node is of course not restarted.

---

## Adding cases

Append a row; the id must be unique. Examples:

```
# remove a ReadOnly DataNode while the workload writes with rf=1
dn_readonly_1rep	dn	readonly	none	1	default	tree	ReadOnly node with no replica left anywhere
# ConfigNode leader remove with a ConfigNode killed at the same time
cn_leader_kill_cn	cn	leader	kill9_cn	2	3	tree,table
```

`workloads` names must be a subset of `tree,table,table_view`.  On a **1.x**
database the table model does not exist, so `table` and `table_view` are dropped
and the run uses `tree` alone; `doctor` prints the effective set (see
`BM_WORKLOADS`). `run --case <id>` for one case, `matrix --limit N` to stop
early, `matrix --case <id>` to restrict a full run.

`delete_objects` re-issues the case's whole-table `DELETE` (falling back to a
time window if the whole-table form is rejected) while the removal runs, so the
OBJECT GC keeps unlinking files while the region snapshot is taken.

Unknown selectors, unknown abnormal operations and non-integer replication
factors are rejected while the file is being loaded, so a typo fails fast
instead of misbehaving mid-run.

---

## Result semantics

| status | meaning |
|--------|---------|
| `PASS` | every stage was clean: procedure drained in both dialects, the node disappeared, its region files were deleted, syncLag stayed at 0, every stopped-node query matched the all-online baseline, and the log scan found nothing |

> **Exception: deleting a removed DataNode's files is that DataNode's own job.**
> The cleanup runs *on the node being removed*, between migration and its own
> shutdown (`DeleteOldRegionPeerTask` → `StorageEngine.deleteDataRegion`, or the
> ConfigNode's `STOP_AND_CLEAR_DATA_NODE` → `DataNode.stop()`). A process that is
> no longer running cannot do it, and nothing else can delete files on a dead
> node's disk — a removed node is also refused on restart, so no later startup
> ever finishes the job. Leaving the files is therefore only a defect when the
> removed node was **alive and healthy** for the whole procedure:
>
> * `selector=unknown` (removed while stopped) — files are **expected** to stay;
>   the case asserts the documented guard ("Please delete the useless 'data' dir
>   and retry") instead, and never waits out a start designed to fail.
> * `abnormal=kill9_target` — the case SIGKILLs the very node being removed, so it
>   cannot finish; residue is **expected** and is recorded in `steps` as an
>   observation rather than reported as a problem.
> * `abnormal=kill9_other_dn` — the removed node stays alive, so the strict
>   assertion applies: leftover files are a genuine FAIL.
>
> Do not "fix" this by asserting cleanup in the killed-target case: measured on
> 2.0.12.1, a `kill -9` 7 s after the remove lands **after** the node has finished
> the deletions it had started (both SchemaRegion deletions carry an explicit
> `Succeed to deleteRegion`) and **before** the first DataRegion deletion is even
> submitted — so nothing is left half-done, and the case would be asserting a
> guarantee the product never makes.
>
> **Every DataNode removal is followed by a restart probe**, because "the node
> left the cluster" says nothing about what is still on its disk, and the
> dangerous case is a node that comes back still holding data it no longer owns.
> The probe starts the removed node again, waits `RESTART_CLEANUP_SETTLE_SEC`,
> measures `data/datanode/data` before and after, records whether the node
> re-joined and under which id, then stops it so the remaining gates run on the
> expected topology. What it compares is **files present before the restart and
> still present after it** — a booting node recreates its own empty directory
> structure, and counting that as stale data is a false positive the probe hit
> once. The verdict follows the case:
>
> * a node the case **killed** had no chance to clean up, so the documented
>   refusal (`Reject DataNode restart ... please delete the useless 'data' dir`)
>   is expected and only recorded;
> * any **other** removal finished with the node alive, so refusing to start, or
>   still holding pre-restart files, is a **problem**.
>
> Both branches were measured on 2.0.12.1: a clean removal leaves **0 files** and
> the node **re-joins under a new node id**; the killed one keeps ~40 MB and is
> refused. `REMOVED_NODE_RESTART_STRICT=true` forces even the killed case to
> fail. When the node re-joins the probe leaves it running, so the cluster does
> not end up listing a member that is down. `selector=unknown` keeps its own probe
> and asserts the documented guard.
| `FAIL` | at least one check failed; `problems` lists them and the CN/DN logs were backed up when `LOG_BACKUP=fail`; migration-class failures also leave plain-text logs in `results/<run>/node_logs/<host>/` (`NODE_LOG_BACKUP`) |
| `SKIP` | the case could not be reproduced in this configuration (no spare host, `DISK_FULL_SIMULATE=false`, no stopped ConfigNode, …) — a `SKIP` is **not** a pass; read `steps` for why. A fault that cannot be injected is always a `SKIP`, never a `PASS` |

Every case writes `cases/<case_id>/result.json` with `problems`, `steps`,
`elapsed_sec` and the artifact directory. Normalised query snapshots are kept
next to it as `*.norm`, so a diff can be inspected by hand.

## Artifacts written when the consistency sweep finds a diff

Besides the `<name>.raw` / `<name>.norm` captures, a diff triggers a forensic
snapshot of the replica file layout, because the query-level diff cannot explain
itself:

| file | content |
|---|---|
| `forensic_diff_<host>_show_regions.txt` | raw `show regions` at that moment |
| `forensic_diff_<host>_files.tsv` | every DataNode's TsFile/`.resource` inventory (`host`, `path`, `file`), read from the filesystem so it also works while a node's process is stopped |
| `forensic_diff_<host>_missing_files.txt` | the cross-comparison: files present on some replicas of a path but absent on others, plus each node's verdict for the disagreeing query |
| `forensic_diff_<host>_<query>_via_<node>.raw` | the disagreeing query re-run through each node still up, so the short view is named directly |

Read `..._missing_files.txt` first. A `.tsfile` that is absent on exactly one
replica while its peers hold it is the signature of a migration snapshot that
silently skipped an unclosed TsFile: the rows in it never reach that replica, and
the follow-on sync-log channel starts at the snapshot point, so they are never
re-sent either — which is why such a replica reads back fewer rows while
`syncLag` still sits at 0. Differences that go **both** ways are ordinary
independent compaction, not evidence of anything.

### dn_object_single_4g（extras=`object_single`，默认参与全量回归，约 24 分钟）

单点 4 GiB OBJECT：用 `to_object(isEOF, offset, X'<8 MiB>')` 对同一 `(device, time)` 连续写 512 段，
然后 `MIGRATE REGION` 迁移该 region，校验：

- `length(o)` 必须等于 4 294 967 296；
- 用 `read_object(o, offset, length)` 分段读回（每段 256 MiB，16 段），逐段校验 `length()` 与 `sha256()`
  ——整文件 `read_object(o)` 超过 2 GiB 才会报 701，分段读不受限；
- 每个副本的 `.bin` 用 `sha256sum` 计算，彼此一致且与写入图案一致（本机实测
  `4bfa1b1094583395a8fe5bbd8417bf9c24186440dcd3f4297d7207dfd289372b`）；
- 迁移后新副本的 `.bin` 大小与 sha256 不变。

实测（RC11 `ea4f835`）：写入 279.5 s（14.7 MiB/s，8 MiB/段 × 512 段），迁移 103 s，
读回 16/16 段一致（迁移前后各一遍），用例 PASS。
配置：`conf/cluster.rc11_singleobj.conf`；写入器：`scripts/java/SingleObjectWriter.java`。
