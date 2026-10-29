# Where this skill comes from

The requirement behind this skill is
`MigrateRegionTest/testcase/remove_iotv1_testcase_list.txt` (56 entries,
`tc101`…`tc121` plus `tc1`…`tc30` for region migrate/extend/reconstruct).
That list is a pile of single-purpose shell scripts, each hard coding
`172.20.70.x` addresses, node ids and file paths, and each driving
`iot-benchmark` from the outside.

This skill keeps the *intent* of the remove-node subset and generalises it:

* no IP, node id, port or path is baked in — the inventory comes from
  `conf/nodes.conf` or from `SHOW CLUSTER`;
* the per-script "one scenario, one shell file" structure becomes one row of
  `cases/remove_cases.tsv`;
* the steps that every script repeats (start the load → wait → remove → wait
  for migrations → wait for syncLag → compare queries → scan logs) become the
  fixed stage pipeline in `scripts/rcdn/cases.py`.

All cases below assume a **2.x** database and the `iotdb-2.0` benchmark
package, which is what the original test-case list targets.  On a 1.x
database the table-model workloads cannot run, so those cases reduce to
their tree-model coverage; the matching `iotdb-1.3` package is required.

## Coverage map

| source case | what it does | this skill |
|-------------|--------------|------------|
| `tc101` | remove dn on an empty cluster | `dn_running_remove` (the load is always on; the empty variant adds nothing) |
| `tc102` | remove dn | `dn_running_remove` |
| `tc103` | remove several dn | `dn_multi_remove` |
| `tc104` | remove a dn id that does not exist | `dn_nonexistent_remove` |
| `tc105` | remove dn with `data_replication_factor=1` | `dn_running_remove_1rep` |
| `tc106`–`tc108` | rf=1 plus deleted rows / no flush | partially: `dn_running_remove_1rep` (deleted-row variants need a dedicated workload, see *Not covered*) |
| `tc109` | remove an Unknown dn | `dn_unknown_remove` |
| `tc110` | remove a Running dn | `dn_running_remove` |
| `tc111` | remove a ReadOnly dn | `dn_readonly_remove` |
| `tc112` | remove 3 Running dn | `dn_multi_remove` |
| `tc113` | remove a Running dn while another dn is ReadOnly | `dn_remove_other_readonly` |
| `tc114` | remove a Running dn while another replica is Unknown | `dn_remove_other_unknown` |
| `tc115` | same, other replica ReadOnly | `dn_remove_other_readonly` |
| `tc116` | two removes at the same time | `dn_concurrent_remove` |
| `tc117` | the replication-factor guard refuses the remove | `dn_remove_rf_limit` |
| `tc118` | `kill -9` the dn while removing it | `dn_remove_kill9_target` |
| `tc119` | remove a disk-full dn | covered by `dn_readonly_remove` — the disk-fill case was dropped |
| `tc120` | remove a normal dn while another dn is disk-full | `dn_remove_other_diskfull` |
| `tc121` | remove a disk-full dn (2 benchmark instances) | covered by `dn_readonly_remove` — the disk-fill case was dropped |
| `tc201` | remove a ConfigNode that does not exist | `cn_nonexistent_remove` |
| `tc2_*` | remove a ConfigNode follower | `cn_follower_remove` |
| `tc3_*` | remove a ConfigNode leader | `cn_leader_remove` |
| `tc13`, `tc15`, `tc19`, `tc25`, `tc28` | remove/extend while another node is restarted, killed or stopped | abnormal operations `restart_dn`, `remove_twice`, `restart_cn`, `stop_cn`, `kill9_cn` |
| `tc20` | remove from a non-existent dn id | `dn_nonexistent_remove` |
| `tc38` | `LOAD BALANCE` during the operation | `dn_remove_load_balance` |
| `tc1`, `tc4`–`tc12`, `tc14`, `tc16`–`tc18`, `tc21`–`tc37` | region-level `EXTEND REGION` / `MIGRATE REGION` / `RECONSTRUCT REGION` | **out of scope** — this skill only drives `REMOVE DATANODE` / `REMOVE CONFIGNODE` |

## Reverse index: every case in the matrix

The map above goes source → skill, and several rows cover a *family* of cases
(the abnormal-operation row in particular). To make sure no case can go missing,
here is the other direction — all 25 rows of `cases/remove_cases.tsv` and where
each one comes from:

| case | source |
|------|--------|
| `dn_running_remove` | `tc101`, `tc102`, `tc110` |
| `dn_unknown_remove` | `tc109` |
| `dn_readonly_remove` | `tc111`; also covers `tc119`, `tc121`, whose disk-fill case was dropped |
| `dn_running_remove_1rep` | `tc105`, partly `tc106`–`tc108` |
| `dn_nonexistent_remove` | `tc104`, `tc20` |
| `dn_multi_remove` | `tc103`, `tc112` |
| `dn_concurrent_remove` | `tc116` |
| `dn_remove_kill9_target` | `tc118` |
| `dn_remove_kill9_other` | abnormal-op row (kill another node) |
| `dn_remove_restart` | abnormal-op row (`restart_dn`) |
| `dn_remove_twice` | abnormal-op row (`remove_twice`) |
| `dn_remove_other_readonly` | `tc113`, `tc115` |
| `dn_remove_other_unknown` | `tc114` |
| `dn_remove_other_diskfull` | `tc120` |
| `dn_remove_rf_limit` | `tc117` |
| `dn_remove_load_balance` | `tc38` |
| `dn_added_dn_remove` | **no direct source** — added by this skill: remove a DataNode that was just *added*, to cover the grow-then-shrink path |
| `cn_follower_remove` | `tc2_*` |
| `cn_leader_remove` | `tc3_*` |
| `cn_stopped_remove` | abnormal-op row (`stop_cn`) |
| `cn_nonexistent_remove` | `tc201` |
| `cn_leader_remove_kill9_follower` | abnormal-op row (`kill9_cn`) |
| `cn_follower_remove_restart` | abnormal-op row (`restart_cn`) |
| `cn_remove_below_quorum` | **no direct source** — added by this skill to probe whether any ConfigNode-side replication-factor floor exists (see `FINDING-cn-quorum-loss.md`) |
| `cn_shrink_leader_first` | **no direct source** (companion to `cn_remove_below_quorum`) |

`dn_added_dn_remove` and `cn_remove_below_quorum` are the only cases with no
counterpart in the reference scripts. It holds the last DataNode of the inventory back from the cluster
start and joins it during the case, so it needs no host outside `nodes.conf`; on a
cluster whose every host is already a DataNode it reports SKIP rather than a
result — see the *Preconditions* section of `README.md`.

## What the reference scripts do that this skill reproduces

Verified against `testcase/tc300_RMDN_no1_remove_normal_dn_writable_view_obj.sh`
and `testcase/tc111_RMDN_no11_remove_readonly_dn.sh`:

| reference function | this skill |
|--------------------|------------|
| `wait_remove_migrations_finish` (polls `SHOW MIGRATIONS` in **tree and table** dialect until `Empty set`) | `Remover.wait_migrations_empty(dialects=["tree","table"])` |
| `wait_datanode_absent` (greps the ip out of `SHOW DATANODES` until it is gone) | `Remover.wait_dn_absent` |
| `check_removed_datanode_data_cleaned` (no `*.tsfile` / `*.resource` / `*.mods` for the migrated region ids, and an empty `data/datanode/data/object/<region_id>`; honours `dn_data_dirs`) | `Remover.check_removed_dn_data_cleaned` |
| `wait_for_monitor_sync_completion 120 360000` (`sum(iot_consensus{instance=~"^(ip1\|ip2…)$",name="ioTConsensusServerImpl",type="syncLag"}) by (instance)`, value `> 0.0001` resets the timer, V2 metric fallback) | `SyncLagWaiter` |
| `capture_consistency_baseline` then, per Running dn: stop it, re-query, diff, restart, re-wait for sync | `Verifier.consistency_check` |
| five query shapes: tree, table base, table writable view, table base + object, table view + object | `Verifier.build_queries` |
| `check_log` (`gunzip` then `grep NullPointer`, `BufferUnderflowException`, `but return HAS_MORE_STATE`, …) and `backup_logs` | `Verifier.check_logs` / `backup_logs` — but **read-only**: `zcat` instead of `gunzip -f`, so logs are never mutated |

## Deliberate differences

* **Object columns.** The reference resolves object columns and checks
  `length(read_object(col))`; this skill additionally tries
  `sha256(cast(read_object(col) as string))` and falls back to length-only when
  the cast is unsupported. Both the base table and the writable view are
  queried.
* **Log scanning is non-mutating.** `gunzip -f` rewrites the cluster's log
  directory; `zcat` does not, so a scan can run while the cluster is live.
* **Healing between stages.** After the remove drains, nodes that abnormal
  operations left down or disk-full are restored before the sync-lag and
  consistency gates. The reference scripts are single-scenario and rarely need
  this; a matrix does, otherwise one case's damage leaks into the next.
* **`diskfull` is simulated, not filled.** `DISK_FULL_SIMULATE=true` (default)
  raises the node's `disk_space_warning_threshold` above its real free ratio so
  the genuine disk-space guard marks it `ReadOnly`/`DISK_FULL`; nothing is
  written and the threshold is restored at teardown.
* **Dialect-aware object discovery.** Whether object columns exist at all is
  decided at run time from `describe <db>.<table> details`; nothing is assumed
  about the build under test.

## Not covered

* **Deleted-row / no-flush variants (`tc106`, `tc107`, `tc108`).** These need a
  workload that deletes rows and skips the flush before the remove. iot-benchmark
  does not do that out of the box, so a faithful port needs a small extra
  workload definition. The remaining rf=1 path is covered by
  `dn_running_remove_1rep`.
* **Region-level operations.** `EXTEND REGION`, `MIGRATE REGION`,
  `RECONSTRUCT REGION` (`tc1`–`tc37` minus the remove ones) are a different
  feature area. The consistency machinery here would transfer, but the case
  matrix does not drive them.
* **Multi-cluster / IoTV1→IoTV2 upgrade scenarios.** Out of scope.
