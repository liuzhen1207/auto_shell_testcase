Independent confirmation from a dual-cluster pipe setup — this patch addresses a real, reproducible case, and it is functionally safe.

**Environment where we hit it**

* `master_1026_dc11a35` (`2.0.11-SNAPSHOT`, BuildInfo `dc11a35`), enterprise TimechoDB
* Two separate clusters used as pipe sender / receiver, each **5 ConfigNode + 10 DataNode**,
  **SchemaRegion 5 replicas / DataRegion 3 replicas**, `IoTConsensus`
* Sender `172.20.70.100–109`, receiver `172.20.70.110–119`

**Reproduction**

```sql
-- sender (tree dialect)
create database root.pipe_p04;
create timeseries root.pipe_p04.d1.s1 INT32;
insert into root.pipe_p04.d1(time,s1) values(1, 10);
create pipe p_all_p04 with source ('inclusion'='all')
  with sink ('node-urls'='172.20.70.110:6667');
```

**Observed on the receiver DN** (`logs/log_datanode_all.log`):

```
2026-10-29 07:05:18,178 [Pipe-Receiver-75-172.20.70.103:38222$...]
  WARN o.a.i.d.q.p.e.c.e.ClusterConfigTaskExecutor:523
  - Failed to execute create database root.pipe_p04 in config node,
    status is TSStatus(code:501, message:root.pipe_p04 has already been created as database).
```

The WARN repeats once per duplicated snapshot delivery, while the receiver ends up in the correct state
(database created, view/data readable, pipe `RUNNING`, no `ExceptionMessage`).

**Why the patch is the right place**

`createSchemaSnapshotDatabaseIfNecessary()` is the only tree-database creation path for pipe schema snapshots that
did not set `enablePrintExceptionLog=false` — the sibling path at
`IoTDBDataNodeReceiver.java:1886` already sets it, which is why that one never produced the WARN.
So the inconsistency was local to this method, exactly as this PR changes.

**Note on behavior preservation (we checked)**

With `enablePrintExceptionLog=false`, `ClusterConfigTaskExecutor` maps `DATABASE_ALREADY_EXISTS` to a
**successful** `ConfigTaskResult` instead of throwing, so `executeStatementAndClassifyExceptions()` now returns
`SUCCESS` and the method returns early — the same end state as before, when the 501 was raised and then converted
back to `SUCCESS` by the `DATABASE_ALREADY_EXISTS` branch a few lines below. Genuine conflicts are untouched: they
still surface through the `DATABASE_CONFLICT` / `PIPE_RECEIVER_USER_CONFLICT_EXCEPTION` branch.

**Regression verification**

We have an automated case for this (`TV-PIPE-04`, dual-cluster pipe group; it asserts the receiver DN log contains
no unexpected `ERROR/WARN` within the case window). On a build that contains this patch it should flip from
FAIL → PASS; if the WARN still shows up, there is another creation path to look at. Happy to re-run it and report
the result once the patch is in a build.
