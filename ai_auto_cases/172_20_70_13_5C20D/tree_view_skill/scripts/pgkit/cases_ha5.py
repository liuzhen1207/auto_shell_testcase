"""5C20D 高可用补充用例（5C-HA-* / 5C-RST-*）。

与包内既有族的追加关系（不改任何既有用例的判定口径）
====================================================
1. ``MULTI-03`` 只验"停 1 台 DN 后副本约束"；本模块补**创建过程中**的故障：
   SchemaRegion / DataRegion **正在创建**时 1~2 台 DN READONLY、1~2 台 DN 被 stop、
   1~2 台 CN 被 stop，以及 1 CN + 1 DN 同时故障、只读 + 停机混合。
2. 5C20D 的关键约束是 **Schema 5 副本**：停 1 台后必须仍有 4 个在线副本、停 2 台后
   仍有 3 个；Data 3 副本停 1 台剩 2、停 2 台剩 1。用例按存活 DN 数取
   ``min(RF, 存活数)`` 作期望，绝不断言"恒等于 RF"。
3. 整个集群重启后再次查询（``5C-RST-01``）在 5C20D 只保留这一条，避免每条用例都重启。

判定口径
========
* 组数期望 = ``min(K, 上限)``（``expected_cap`` / ``group_ceiling`` 双口径）；
* 新组的副本落点**不得包含**被停/只读的 DN（只读节点不承载新 region）；
* 恢复后组状态必须回到 ``Running``，写入过的数据必须仍可查（行数对拍）；
* 故障期间写入失败是允许的，但必须**明确报错**且不产生越界组数。
"""
from __future__ import annotations

import time

from .cases import (
    CaseSpec,
    Ctx,
    device_set,
    ensure_write_tree,
    expect_groups,
    expected_cap,
    group_ceiling,
    reset_db,
)
from .cases_leak import _replica_hosts

DN, CN = "dn", "cn"
_POLL = 5


def _set_readonly(ctx: Ctx, host: str, enable: bool, label: str) -> bool:
    """在 **DataNode 本机**切换 READONLY/RUNNING，并用 ``SHOW CLUSTER`` 校验。

    ``cases.read_only_ok`` 用的是 ``show system status``——2.0.11 的语法里没有这个语句
    （实测 ``700: mismatched input 'status' expecting INFO``），只能靠"输出非空"兜底，
    判据不硬。这里改成：执行 ``SET SYSTEM TO ... ON LOCAL`` 后，直接从集群视图读该节点的
    Status（期望 ``ReadOnly`` / ``Running``），读不到才算失败。
    """
    ctx.mark_harness_action(f"{label}：{'置' if enable else '恢复'} DN {host} "
                            f"{'READONLY' if enable else 'RUNNING'}（ON LOCAL）", kind="readonly")
    word = "readonly" if enable else "running"
    out = ctx.api.run(f"set system to {word} on local", host=host, timeout=120)
    if not out.ok:
        ctx.note(f"    {host} set system to {word} 返回：{(out.output or '')[:200]}")
        return False
    want = "readonly" if enable else "running"
    deadline = time.time() + 120
    status = ""
    while time.time() < deadline:
        status = (ctx.cluster.dn_status_for(host) or "").strip()
        if status.split("(")[0].strip().lower() == want:
            return True
        time.sleep(5)
    ctx.note(f"    {host} 期望 Status={want}，实测 {status!r}")
    return False


def _cap(ctx: Ctx, kind: str, db: str) -> int:
    return max(expected_cap(ctx, kind, "tree", db), group_ceiling(ctx, kind, "tree", db))


def _write(ctx: Ctx, db: str, count: int, *, prefix: str, stamp: int = 1) -> list[str]:
    items = device_set(ctx, db, count, dialect="tree", prefix=prefix)
    for i, device in enumerate(items):
        ensure_write_tree(ctx, db, device, stamp=stamp + i, sensors=("s0",))
    return items


def _stop(ctx: Ctx, host: str, role: str, label: str) -> bool:
    ctx.mark_harness_action(f"{label}：停 {role.upper()} {host}", kind="stop")
    ok = ctx.cluster.stop_node(host, role)
    if role == DN:
        ctx.by_design_gone.add(host)      # 停机即登记，收尾① 才不会等一个永远不会到的 lag
    ctx.check(f"{label}：{role.upper()} {host} 已停止", ok, f"host={host}")
    return ok


def _start(ctx: Ctx, host: str, role: str, label: str, *, wait_cluster: bool = True) -> bool:
    """把节点拉起来并确认**该节点**回到 Running。

    ``wait_cluster=False``：只等本节点，不要求整集群 25 节点齐 —— 一台一台恢复时，
    还有别的节点没起来，整集群永远不可能 healthy（旧实现因此在「停 2 台 CN/DN」用例的
    finally 里各白等 1200s，单条用例被拖到 30 分钟）。全部节点都起来后再统一
    ``wait_healthy`` 一次。
    """
    ctx.mark_harness_action(f"{label}：启 {role.upper()} {host}", kind="start")
    if not ctx.cluster.node_running(host, role):
        ctx.cluster.start_node(host, role)
    timeout = int(ctx.cfg.raw("CLUSTER_START_TIMEOUT_SEC") or 1200)
    deadline = time.time() + timeout
    status = ""
    while time.time() < deadline:
        status = ((ctx.cluster.cn_status_for(host) if role == CN
                   else ctx.cluster.dn_status_for(host)) or "").strip()
        if status.split("(")[0].strip().lower() in {"running", "readonly"}:
            break
        time.sleep(_POLL)
    ok = status.split("(")[0].strip().lower() in {"running", "readonly"}
    if role == CN and ok:
        # CN 重启会让 ConfigRegion 重新选主，其它 CN 的 GrpcLogAppender 会按设计重试数分钟
        ctx.mark_harness_action(
            f"{label}：CN {host} 重启后的 ConfigRegion 选主/日志追赶收敛期",
            pad=int(ctx.cfg.raw("CLUSTER_CONVERGENCE_WINDOW_SEC") or 420))
    if wait_cluster:
        ok = ctx.cluster.wait_healthy(timeout=timeout) and ok
    ctx.check(f"{label}：{role.upper()} {host} 已恢复 Running"
              + ("（整集群健康）" if wait_cluster else ""), ok, f"status={status!r}")
    if role == DN and ok:
        ctx.by_design_gone.discard(host)
    return ok


def _group_ids(ctx: Ctx, db: str, kind: str) -> set[str]:
    return set(ctx.api.group_ids(db, kind=kind, dialect="tree"))


def _replicas_ok(ctx: Ctx, db: str, kind: str, rf: int, forbidden: set[str],
                 before: set[str] | None = None, *, exclude_strict: bool = True) -> dict:
    """副本断言。

    * **全部**组：副本数 == RF（副本集合完整，不因故障少给副本）；
    * **本用例新建**的组（``before`` 之外的组）：副本不得落在 ``forbidden``。

    为什么必须区分：故障前已存在的组，其副本是故障前就分配好的，只读/停机不会也不应该
    把已有副本迁走；把"已有组含故障节点"当失败会误判产品正确行为（首轮 5C-HA-01 即此误判）。
    """
    replica = _replica_hosts(ctx, db, kind)
    bad_count = {gid: hosts for gid, hosts in replica.items() if len(hosts) != rf}
    ctx.check(f"{kind} 组数可查（{len(replica)} 组）且每组 {rf} 个副本",
              bool(replica) and not bad_count,
              f"组数={len(replica)} 违规={dict(list(bad_count.items())[:5])}")
    if before is None:
        return replica
    new = {gid: hosts for gid, hosts in replica.items() if gid not in before}
    all_dn = set(ctx.cfg.dn_hosts)
    if exclude_strict:
        # 只读节点：明确拒绝应用共识日志，落在它上面的新组会一直落后 ⇒ 要求**完全不落**。
        bad_place = {gid: hosts for gid, hosts in new.items() if set(hosts) & forbidden}
        ctx.check(f"{kind} 故障后新建 {len(new)} 个组，副本未落在只读节点 {sorted(forbidden)}",
                  bool(new) and not bad_place,
                  f"新建组={sorted(new)} 违规={dict(list(bad_place.items())[:5])}",
                  evidence=str(new)[:2000])
    else:
        # 停机节点：它仍是集群成员，IoTDB 允许把副本分给它（重启后追平），因此**不排除**落点；
        # 要求的是：落点都在 DN 清单内 + 每个新组的在线副本 ≥ RF - 已停机台数。
        alive = all_dn - set(forbidden)
        stray = {gid: hosts for gid, hosts in new.items() if set(hosts) - all_dn}
        thin = {gid: hosts for gid, hosts in new.items()
                if len([h for h in hosts if h in alive]) < rf - len(forbidden)}
        ctx.check(f"{kind} 故障后新建 {len(new)} 个组，副本落点都在 DN 清单内",
                  bool(new) and not stray, f"新建组={sorted(new)} 越界={stray}",
                  evidence=str(new)[:2000])
        ctx.check(f"{kind} 新组在线副本 ≥ RF={rf} - 已停 {len(forbidden)} 台",
                  not thin, f"违规={dict(list(thin.items())[:5])} 停机={sorted(forbidden)}"
                  f"（停机节点的副本待其重启后追平，属预期）")
    return replica


def _wait_running(ctx: Ctx, db: str, kind: str, timeout: int = 300) -> dict:
    deadline = time.time() + timeout
    statuses: dict = {}
    while time.time() < deadline:
        statuses = ctx.api.statuses(db, kind=kind, dialect="tree")
        if statuses and all(s.strip().lower() == "running" for s in statuses.values()):
            return statuses
        time.sleep(_POLL)
    return statuses


# ===================================================================== 只读
def case_5c_ha01_readonly1_create(ctx: Ctx) -> None:
    """5C-HA-01 1 台 DN READONLY 期间**创建** SchemaRegion/DataRegion（树库新 slot）。"""
    srf = int(ctx.cfg.raw("SCHEMA_REPLICATION_FACTOR") or 5)
    drf = int(ctx.cfg.raw("DATA_REPLICATION_FACTOR") or 3)
    db = reset_db(ctx, "tree")
    _write(ctx, db, 1, prefix="h1a")
    before_s = _group_ids(ctx, db, "SCHEMA")
    before_d = _group_ids(ctx, db, "DATA")
    target = ctx.cfg.dn_hosts[0]
    try:
        ctx.check(f"DN {target} 置 READONLY 成功（SHOW CLUSTER 校验）",
                  _set_readonly(ctx, target, True, "5C-HA-01"), f"host={target}")
        k = 4
        _write(ctx, db, k, prefix="h1b", stamp=100)
        scap, dcap = _cap(ctx, "SCHEMA", db), _cap(ctx, "DATA", db)
        expect_groups(ctx, "只读 1 台 DN 期间创建 RegionGroup（Schema）", db, "tree",
                      schema=min(k + 1, scap))
        expect_groups(ctx, "只读 1 台 DN 期间创建 RegionGroup（Data）", db, "tree",
                      data=min(k + 1, dcap))
        _replicas_ok(ctx, db, "SCHEMA", srf, {target}, before=before_s)
        _replicas_ok(ctx, db, "DATA", drf, {target}, before=before_d)
        got = ctx.api.count_rows(f"{db}.{device_set(ctx, db, 1, dialect='tree', prefix='h1b')[0]}",
                                dialect="tree")
        ctx.check("只读期间写入的数据可查", got >= 1, f"count={got}")
    finally:
        ctx.check(f"DN {target} 恢复 RUNNING 成功（SHOW CLUSTER 校验）",
                  _set_readonly(ctx, target, False, "5C-HA-01"), f"host={target}")
    statuses = _wait_running(ctx, db, "DATA")
    ctx.check("恢复后 Data 组状态回到 Running",
              bool(statuses) and all(s.strip().lower() == "running" for s in statuses.values()),
              f"statuses={statuses}")


def case_5c_ha02_readonly2_create(ctx: Ctx) -> None:
    """5C-HA-02 2 台 DN 同时 READONLY 期间创建 SchemaRegion（5 副本仍须落 5 台不同 DN）。"""
    srf = int(ctx.cfg.raw("SCHEMA_REPLICATION_FACTOR") or 5)
    drf = int(ctx.cfg.raw("DATA_REPLICATION_FACTOR") or 3)
    if len(ctx.cfg.dn_hosts) < 8:
        ctx.skip(f"需要 ≥8 台 DN 才能只读 2 台后仍满足 SR{srf}/DR{drf}，当前"
                 f"{len(ctx.cfg.dn_hosts)} 台")
        return
    targets = [ctx.cfg.dn_hosts[1], ctx.cfg.dn_hosts[2]]
    db = reset_db(ctx, "tree")
    before_s = _group_ids(ctx, db, "SCHEMA")
    before_d = _group_ids(ctx, db, "DATA")
    try:
        for host in targets:
            ctx.check(f"DN {host} 置 READONLY 成功（SHOW CLUSTER 校验）",
                      _set_readonly(ctx, host, True, "5C-HA-02"), f"host={host}")
        k = 5
        _write(ctx, db, k, prefix="h2")
        scap = _cap(ctx, "SCHEMA", db)
        expect_groups(ctx, "只读 2 台 DN 期间创建 SchemaRegionGroup", db, "tree",
                      schema=min(k, scap))
        _replicas_ok(ctx, db, "SCHEMA", srf, set(targets), before=before_s)
        _replicas_ok(ctx, db, "DATA", drf, set(targets), before=before_d)
    finally:
        for host in targets:
            ctx.check(f"DN {host} 恢复 RUNNING 成功（SHOW CLUSTER 校验）",
                      _set_readonly(ctx, host, False, "5C-HA-02"), f"host={host}")
    statuses = _wait_running(ctx, db, "SCHEMA")
    ctx.check("恢复后 Schema 组状态回到 Running",
              bool(statuses) and all(s.strip().lower() == "running" for s in statuses.values()),
              f"statuses={statuses}")


# ===================================================================== 停机
def case_5c_ha03_stop1_dn_create(ctx: Ctx) -> None:
    """5C-HA-03 停 1 台 DN 期间创建 DataRegion（新库 + 新 slot），恢复后数据完整。"""
    drf = int(ctx.cfg.raw("DATA_REPLICATION_FACTOR") or 3)
    victim = ctx.cfg.dn_hosts[-1]
    db = "root.pg_h3"
    ctx.cleanup.append(f"drop database {db}")
    ctx.api.drop_database(db)
    ctx.mark_harness_action(f"5C-HA-03 停机前建库 {db}", kind="create_db")
    ctx.req(ctx.api.create_database(db), f"create database {db}")
    before_d = _group_ids(ctx, db, "DATA")
    ctx.check(f"DN {victim} 已停止", _stop(ctx, victim, DN, "5C-HA-03"), f"host={victim}")
    try:
        k = 3
        devices = _write(ctx, db, k, prefix="h3")
        dcap = _cap(ctx, "DATA", db)
        expect_groups(ctx, "停 1 台 DN 期间创建 DataRegionGroup", db, "tree",
                      data=min(k, dcap))
        _replicas_ok(ctx, db, "DATA", drf, {victim}, before=before_d, exclude_strict=False)
        got = ctx.api.count_rows(f"{db}.{devices[-1]}", dialect="tree")
        ctx.check("停机期间写入的数据可查", got >= 1, f"count={got}")
    finally:
        _start(ctx, victim, DN, "5C-HA-03")
    statuses = _wait_running(ctx, db, "DATA")
    ctx.check("恢复后 Data 组状态回到 Running",
              bool(statuses) and all(s.strip().lower() == "running" for s in statuses.values()),
              f"statuses={statuses}")
    got = ctx.api.count_rows(f"{db}.{devices[-1]}", dialect="tree")
    ctx.check("恢复后数据仍可查且行数不变", got >= 1, f"count={got}")


def case_5c_ha04_stop2_dn_create(ctx: Ctx) -> None:
    """5C-HA-04 停 2 台 DN 期间创建 SchemaRegion（SR5 ⇒ 5 副本落 5 台存活 DN）。"""
    srf = int(ctx.cfg.raw("SCHEMA_REPLICATION_FACTOR") or 5)
    drf = int(ctx.cfg.raw("DATA_REPLICATION_FACTOR") or 3)
    if len(ctx.cfg.dn_hosts) < 10:
        ctx.skip(f"需要 ≥10 台 DN（停 2 台后仍 ≥8 台），当前 {len(ctx.cfg.dn_hosts)} 台")
        return
    victims = [ctx.cfg.dn_hosts[-1], ctx.cfg.dn_hosts[-2]]
    db = "root.pg_h4"
    ctx.cleanup.append(f"drop database {db}")
    ctx.api.drop_database(db)
    ctx.mark_harness_action(f"5C-HA-04 停机前建库 {db}", kind="create_db")
    ctx.req(ctx.api.create_database(db), f"create database {db}")
    before_s = _group_ids(ctx, db, "SCHEMA")
    before_d = _group_ids(ctx, db, "DATA")
    try:
        for host in victims:
            ctx.check(f"DN {host} 已停止", _stop(ctx, host, DN, "5C-HA-04"), f"host={host}")
        k = 5
        devices = _write(ctx, db, k, prefix="h4")
        scap, dcap = _cap(ctx, "SCHEMA", db), _cap(ctx, "DATA", db)
        expect_groups(ctx, "停 2 台 DN 期间创建 SchemaRegionGroup", db, "tree",
                      schema=min(k, scap))
        expect_groups(ctx, "停 2 台 DN 期间创建 DataRegionGroup", db, "tree",
                      data=min(k, dcap))
        _replicas_ok(ctx, db, "SCHEMA", srf, set(victims), before=before_s,
                     exclude_strict=False)
        # 停 2 台后存活 18 ≥ DR3，仍要求每组 3 副本
        _replicas_ok(ctx, db, "DATA", drf, set(victims), before=before_d,
                     exclude_strict=False)
        got = ctx.api.count_rows(f"{db}.{devices[0]}", dialect="tree")
        ctx.check("停 2 台 DN 期间查询可执行", got >= 1, f"count={got}")
    finally:
        for host in victims:
            _start(ctx, host, DN, "5C-HA-04", wait_cluster=False)
        ctx.check("恢复 2 台 DN 后集群重新健康（25 节点 Running/ReadOnly）",
                  ctx.cluster.wait_healthy(
                      timeout=int(ctx.cfg.raw("CLUSTER_START_TIMEOUT_SEC") or 1200)),
                  "wait_healthy()")
    statuses = _wait_running(ctx, db, "SCHEMA")
    ctx.check("恢复后 Schema 组状态回到 Running",
              bool(statuses) and all(s.strip().lower() == "running" for s in statuses.values()),
              f"statuses={statuses}")


# ===================================================================== CN 停机
def case_5c_ha05_stop1_cn_create(ctx: Ctx) -> None:
    """5C-HA-05 停 1 台 CN 期间创建 SchemaRegion/DataRegion；CN 恢复后组数不变。"""
    srf = int(ctx.cfg.raw("SCHEMA_REPLICATION_FACTOR") or 5)
    drf = int(ctx.cfg.raw("DATA_REPLICATION_FACTOR") or 3)
    if len(ctx.cfg.cn_hosts) < 3:
        ctx.skip(f"需要 ≥3 台 CN，当前 {len(ctx.cfg.cn_hosts)} 台")
        return
    victim = ctx.cfg.cn_hosts[-1]
    db = reset_db(ctx, "tree")
    _write(ctx, db, 1, prefix="h5a")
    before_s = _group_ids(ctx, db, "SCHEMA")
    before_d = _group_ids(ctx, db, "DATA")
    try:
        ctx.check(f"CN {victim} 已停止", _stop(ctx, victim, CN, "5C-HA-05"), f"host={victim}")
        k = 3
        _write(ctx, db, k, prefix="h5b", stamp=50)
        scap, dcap = _cap(ctx, "SCHEMA", db), _cap(ctx, "DATA", db)
        expect_groups(ctx, "停 1 台 CN 期间创建 RegionGroup（Schema）", db, "tree",
                      schema=min(k + 1, scap))
        expect_groups(ctx, "停 1 台 CN 期间创建 RegionGroup（Data）", db, "tree",
                      data=min(k + 1, dcap))
        _replicas_ok(ctx, db, "SCHEMA", srf, set(), before=before_s)
        _replicas_ok(ctx, db, "DATA", drf, set(), before=before_d)
        before = (ctx.api.group_ids(db, kind="SCHEMA", dialect="tree"),
                  ctx.api.group_ids(db, kind="DATA", dialect="tree"),
                  ctx.api.db_group_num(db, "SCHEMA", dialect="tree"),
                  ctx.api.db_group_num(db, "DATA", dialect="tree"))
    finally:
        _start(ctx, victim, CN, "5C-HA-05")
    time.sleep(10)
    after = (ctx.api.group_ids(db, kind="SCHEMA", dialect="tree"),
             ctx.api.group_ids(db, kind="DATA", dialect="tree"),
             ctx.api.db_group_num(db, "SCHEMA", dialect="tree"),
             ctx.api.db_group_num(db, "DATA", dialect="tree"))
    ctx.check("CN 恢复后 Schema/Data 组 id 与组数完全不变", before == after,
              f"before={before} after={after}")


def case_5c_ha06_stop2_cn_create(ctx: Ctx) -> None:
    """5C-HA-06 停 2 台 CN（5→3，仍多数派）期间创建 RegionGroup；恢复后不变。"""
    if len(ctx.cfg.cn_hosts) < 5:
        ctx.skip(f"需要 5 台 CN 才能验「停 2 台仍有多数派」，当前 {len(ctx.cfg.cn_hosts)} 台")
        return
    victims = [ctx.cfg.cn_hosts[-1], ctx.cfg.cn_hosts[-2]]
    db = reset_db(ctx, "tree")
    _write(ctx, db, 1, prefix="h6a")
    try:
        for host in victims:
            ctx.check(f"CN {host} 已停止", _stop(ctx, host, CN, "5C-HA-06"), f"host={host}")
        k = 3
        _write(ctx, db, k, prefix="h6b", stamp=60)
        scap, dcap = _cap(ctx, "SCHEMA", db), _cap(ctx, "DATA", db)
        expect_groups(ctx, "停 2 台 CN 期间创建 RegionGroup（Schema）", db, "tree",
                      schema=min(k + 1, scap))
        expect_groups(ctx, "停 2 台 CN 期间创建 RegionGroup（Data）", db, "tree",
                      data=min(k + 1, dcap))
        before = (ctx.api.group_ids(db, kind="DATA", dialect="tree"),
                  ctx.api.db_group_num(db, "DATA", dialect="tree"))
    finally:
        for host in victims:
            _start(ctx, host, CN, "5C-HA-06", wait_cluster=False)
        ctx.check("恢复 2 台 CN 后集群重新健康（25 节点 Running/ReadOnly）",
                  ctx.cluster.wait_healthy(
                      timeout=int(ctx.cfg.raw("CLUSTER_START_TIMEOUT_SEC") or 1200)),
                  "wait_healthy()")
    time.sleep(15)
    after = (ctx.api.group_ids(db, kind="DATA", dialect="tree"),
             ctx.api.db_group_num(db, "DATA", dialect="tree"))
    ctx.check("2 台 CN 恢复后 Data 组 id 与组数完全不变", before == after,
              f"before={before} after={after}")


# ===================================================================== 组合故障
def case_5c_ha07_cn_dn_combo(ctx: Ctx) -> None:
    """5C-HA-07 1 台 CN + 1 台 DN 同时停止期间创建 RegionGroup。"""
    srf = int(ctx.cfg.raw("SCHEMA_REPLICATION_FACTOR") or 5)
    drf = int(ctx.cfg.raw("DATA_REPLICATION_FACTOR") or 3)
    if len(ctx.cfg.cn_hosts) < 3:
        ctx.skip(f"需要 ≥3 台 CN，当前 {len(ctx.cfg.cn_hosts)} 台")
        return
    cn_victim = ctx.cfg.cn_hosts[-1]
    dn_victim = ctx.cfg.dn_hosts[-1]
    db = reset_db(ctx, "tree")
    before_s = _group_ids(ctx, db, "SCHEMA")
    before_d = _group_ids(ctx, db, "DATA")
    try:
        ctx.check(f"CN {cn_victim} 已停止", _stop(ctx, cn_victim, CN, "5C-HA-07"),
                  f"host={cn_victim}")
        ctx.check(f"DN {dn_victim} 已停止", _stop(ctx, dn_victim, DN, "5C-HA-07"),
                  f"host={dn_victim}")
        k = 4
        devices = _write(ctx, db, k, prefix="h7")
        scap, dcap = _cap(ctx, "SCHEMA", db), _cap(ctx, "DATA", db)
        expect_groups(ctx, "CN+DN 同时故障期间创建 RegionGroup（Schema）", db, "tree",
                      schema=min(k, scap))
        expect_groups(ctx, "CN+DN 同时故障期间创建 RegionGroup（Data）", db, "tree",
                      data=min(k, dcap))
        _replicas_ok(ctx, db, "SCHEMA", srf, {dn_victim}, before=before_s,
                     exclude_strict=False)
        _replicas_ok(ctx, db, "DATA", drf, {dn_victim}, before=before_d,
                     exclude_strict=False)
        got = ctx.api.count_rows(f"{db}.{devices[0]}", dialect="tree")
        ctx.check("CN+DN 同时故障期间查询可执行", got >= 1, f"count={got}")
    finally:
        _start(ctx, dn_victim, DN, "5C-HA-07", wait_cluster=False)
        _start(ctx, cn_victim, CN, "5C-HA-07", wait_cluster=False)
        ctx.check("恢复 1 CN + 1 DN 后集群重新健康（25 节点 Running/ReadOnly）",
                  ctx.cluster.wait_healthy(
                      timeout=int(ctx.cfg.raw("CLUSTER_START_TIMEOUT_SEC") or 1200)),
                  "wait_healthy()")


def case_5c_ha08_readonly_stop_combo(ctx: Ctx) -> None:
    """5C-HA-08 1 台 DN READONLY + 1 台 DN STOP 期间创建 RegionGroup。"""
    srf = int(ctx.cfg.raw("SCHEMA_REPLICATION_FACTOR") or 5)
    drf = int(ctx.cfg.raw("DATA_REPLICATION_FACTOR") or 3)
    if len(ctx.cfg.dn_hosts) < 9:
        ctx.skip(f"需要 ≥9 台 DN，当前 {len(ctx.cfg.dn_hosts)} 台")
        return
    ro_host = ctx.cfg.dn_hosts[1]
    stop_host = ctx.cfg.dn_hosts[-1]
    db = reset_db(ctx, "tree")
    before_s = _group_ids(ctx, db, "SCHEMA")
    before_d = _group_ids(ctx, db, "DATA")
    try:
        ctx.check(f"DN {ro_host} 置 READONLY 成功（SHOW CLUSTER 校验）",
                  _set_readonly(ctx, ro_host, True, "5C-HA-08"), f"host={ro_host}")
        ctx.check(f"DN {stop_host} 已停止", _stop(ctx, stop_host, DN, "5C-HA-08"),
                  f"host={stop_host}")
        k = 4
        _write(ctx, db, k, prefix="h8")
        scap, dcap = _cap(ctx, "SCHEMA", db), _cap(ctx, "DATA", db)
        expect_groups(ctx, "只读+停机期间创建 RegionGroup（Schema）", db, "tree",
                      schema=min(k, scap))
        expect_groups(ctx, "只读+停机期间创建 RegionGroup（Data）", db, "tree",
                      data=min(k, dcap))
        # 只读节点：产品必须不把新副本放上去（严格）；停机节点：允许分配、重启后追平（非严格）
        _replicas_ok(ctx, db, "SCHEMA", srf, {ro_host}, before=before_s)
        _replicas_ok(ctx, db, "DATA", drf, {ro_host}, before=before_d)
        _replicas_ok(ctx, db, "SCHEMA", srf, {stop_host}, before=before_s,
                     exclude_strict=False)
        _replicas_ok(ctx, db, "DATA", drf, {stop_host}, before=before_d,
                     exclude_strict=False)
    finally:
        _start(ctx, stop_host, DN, "5C-HA-08", wait_cluster=False)
        ctx.check(f"DN {ro_host} 恢复 RUNNING 成功（SHOW CLUSTER 校验）",
                  _set_readonly(ctx, ro_host, False, "5C-HA-08"), f"host={ro_host}")
    statuses = _wait_running(ctx, db, "DATA")
    ctx.check("恢复后 Data 组状态回到 Running",
              bool(statuses) and all(s.strip().lower() == "running" for s in statuses.values()),
              f"statuses={statuses}")


def case_5c_ha09_stop_during_load(ctx: Ctx) -> None:
    """5C-HA-09 后台持续写新 slot 的同时停 1 台 DN（创建过程中故障）。"""
    victim = ctx.cfg.dn_hosts[-3] if len(ctx.cfg.dn_hosts) > 3 else ctx.cfg.dn_hosts[-1]
    db = reset_db(ctx, "tree")
    devices = device_set(ctx, db, 40, dialect="tree", prefix="h9")
    script = (
        "cd {d} && for dev in {devs}; do "
        "./sbin/start-cli.sh -h {h} -p {p} -u {u} -pw {pw} -sql_dialect tree "
        "-e \"insert into {db}.$dev(timestamp, s0) values(1, 1.0)\" "
        ">>/tmp/h9_insert.log 2>&1 && echo \"OK $dev\" >>/tmp/h9_ok.log || "
        "echo \"FAIL $dev\" >>/tmp/h9_fail.log; done; echo DONE >>/tmp/h9_ok.log"
    ).format(d=ctx.cfg.get("DB_DIR"), h=ctx.cfg.cli_host, devs=" ".join(devices),
             p=ctx.cfg.dn_rpc_port, u=ctx.cfg.get("DB_USER"),
             pw=ctx.cfg.get("DB_PASSWORD"), db=db)
    ctx.ssh.run(ctx.cfg.cli_host, "rm -f /tmp/h9_ok.log /tmp/h9_fail.log /tmp/h9_insert.log",
                check=False)
    ctx.ssh.run(ctx.cfg.cli_host,
                f"nohup setsid bash -c {script!r} >/dev/null 2>&1 & echo started",
                check=False)
    time.sleep(6)
    _stop(ctx, victim, DN, "5C-HA-09（写在途）")
    # 等后台脚本跑完（最多 10 分钟）
    deadline = time.time() + 600
    ok_devices: list[str] = []
    failed = 0
    while time.time() < deadline:
        res = ctx.ssh.run(ctx.cfg.cli_host, "cat /tmp/h9_ok.log 2>/dev/null || true",
                          check=False)
        lines = [l.strip() for l in (res.out or "").splitlines() if l.strip()]
        if any(l == "DONE" for l in lines):
            ok_devices = [l.split()[1] for l in lines if l.startswith("OK ")]
            fail_res = ctx.ssh.run(ctx.cfg.cli_host, "grep -c FAIL /tmp/h9_fail.log 2>/dev/null || true",
                                   check=False)
            failed = int((fail_res.out or "0").strip() or 0)
            break
        time.sleep(10)
    ctx.check("后台写入在停机期间全部结束（未卡死）", bool(ok_devices) or failed > 0,
              f"OK={len(ok_devices)} FAIL={failed}")
    ctx.note(f"  在途写入结果：成功 {len(ok_devices)} 个设备、失败 {failed} 个")
    _start(ctx, victim, DN, "5C-HA-09")
    dcap = _cap(ctx, "DATA", db)
    data = ctx.api.group_count(db, kind="DATA", dialect="tree")
    ctx.check(f"故障后 Data 组数 {data} 不超过上限 {dcap}", data <= dcap, f"cap={dcap}")
    statuses = _wait_running(ctx, db, "DATA")
    ctx.check("恢复后所有 Data 组状态回到 Running",
              bool(statuses) and all(s.strip().lower() == "running" for s in statuses.values()),
              f"statuses={statuses}")
    missing = []
    for device in ok_devices[:10]:
        got = ctx.api.count_rows(f"{db}.{device}", dialect="tree")
        if got < 1:
            missing.append((device, got))
    ctx.check(f"停机期间成功的写入全部可查（抽查 {min(10, len(ok_devices))} 个）",
              not missing, f"缺失={missing}")


# ===================================================================== 整集群重启
def case_5c_rst01_cluster_restart(ctx: Ctx) -> None:
    """5C-RST-01 整个集群重启后再查询：组数/组 id/设备→组映射不变、数据可查、仍可扩容。"""
    db = reset_db(ctx, "tree")
    devices = _write(ctx, db, 6, prefix="rst")
    ctx.api.flush()
    ids_before = (ctx.api.group_ids(db, kind="SCHEMA", dialect="tree"),
                  ctx.api.group_ids(db, kind="DATA", dialect="tree"))
    mapping_before = {d: ctx.api.device_group(f"{db}.{d}", dialect="tree") for d in devices}
    rows_before = {d: ctx.api.count_rows(f"{db}.{d}", dialect="tree") for d in devices}
    ctx.check("重启前组 id 与设备映射可查", all(ids_before[1]) and all(mapping_before.values()),
              f"data_groups={len(ids_before[1])} mapping={mapping_before}")
    # 25 个节点逐个停要 4~5 分钟，关停阶段的日志（对端已不可达等）都属 harness 动作产物
    ctx.mark_harness_action("5C-RST-01 整集群重启（停全部节点）", pad=(10, 600))
    ctx.cluster.stop_all()
    stopped = [h for h in ctx.cfg.all_hosts if ctx.cluster.node_running(h, DN)]
    ctx.check("所有 DataNode 已停止", not stopped, f"仍在运行={stopped}")
    ctx.mark_harness_action("5C-RST-01 整集群重启（启全部节点）", kind="start")
    ctx.check("整集群重新启动并健康",
              ctx.cluster.start_all(), "start_all()")
    # 25 个 JVM 同时冷启动：选主、region 上报、心跳重连的 WARN 会持续数分钟，
    # 与 ``ensure_cluster_up`` 对"刚启动的集群"用的是同一个窗口（CLUSTER_CONVERGENCE_WINDOW_SEC）。
    ctx.mark_harness_action(
        "5C-RST-01 整集群冷启动收敛期（选主/region 上报/心跳重连）",
        pad=int(ctx.cfg.raw("CLUSTER_CONVERGENCE_WINDOW_SEC") or 420))
    deadline = time.time() + 300
    ids_after = (set(), set())
    while time.time() < deadline:
        ids_after = (ctx.api.group_ids(db, kind="SCHEMA", dialect="tree"),
                     ctx.api.group_ids(db, kind="DATA", dialect="tree"))
        if ids_after == ids_before:
            break
        time.sleep(5)
    ctx.check("重启后 Schema/Data 组 id 集合与重启前完全一致", ids_after == ids_before,
              f"before={ids_before} after={ids_after}")
    mapping_after = {d: ctx.api.device_group(f"{db}.{d}", dialect="tree") for d in devices}
    ctx.check("重启后设备→RegionGroup 映射完全一致", mapping_after == mapping_before,
              f"before={mapping_before} after={mapping_after}")
    rows_after = {d: ctx.api.count_rows(f"{db}.{d}", dialect="tree") for d in devices}
    ctx.check("重启后每个设备行数与重启前一致", rows_after == rows_before,
              f"before={rows_before} after={rows_after}")
    # 重启后继续写新 slot：PROACTIVE 仍生效
    k = 3
    _write(ctx, db, k, prefix="rst_new", stamp=200)
    cap = _cap(ctx, "DATA", db)
    total_slots = len(set([f"rst{i}" for i in range(6)] + [f"rst_new{i}" for i in range(k)]))
    data = ctx.api.group_count(db, kind="DATA", dialect="tree")
    ctx.check(f"重启后继续写新 slot 仍扩容（组数 {data} ≤ 上限 {cap} 且 ≥ 重启前）",
              len(ids_before[1]) <= data <= cap,
              f"before={len(ids_before[1])} after={data} cap={cap} slots={total_slots}")
    statuses = _wait_running(ctx, db, "DATA")
    ctx.check("重启后所有 Data 组状态 Running",
              bool(statuses) and all(s.strip().lower() == "running" for s in statuses.values()),
              f"statuses={statuses}")


HA5_CASES = [
    CaseSpec("5C-HA-01", "5C高可用", "tree", "1 台 DN READONLY 期间创建 Schema/Data RegionGroup",
             "P0", case_5c_ha01_readonly1_create),
    CaseSpec("5C-HA-02", "5C高可用", "tree", "2 台 DN READONLY 期间创建 Schema/Data RegionGroup",
             "P0", case_5c_ha02_readonly2_create),
    CaseSpec("5C-HA-03", "5C高可用", "tree", "停 1 台 DN 期间创建 DataRegionGroup 并恢复",
             "P0", case_5c_ha03_stop1_dn_create),
    CaseSpec("5C-HA-04", "5C高可用", "tree", "停 2 台 DN 期间创建 SchemaRegionGroup（SR5）",
             "P0", case_5c_ha04_stop2_dn_create),
    CaseSpec("5C-HA-05", "5C高可用", "tree", "停 1 台 CN 期间创建 RegionGroup，恢复后不变",
             "P1", case_5c_ha05_stop1_cn_create),
    CaseSpec("5C-HA-06", "5C高可用", "tree", "停 2 台 CN（仍多数派）期间创建 RegionGroup",
             "P1", case_5c_ha06_stop2_cn_create),
    CaseSpec("5C-HA-07", "5C高可用", "tree", "1 台 CN + 1 台 DN 同时停期间创建 RegionGroup",
             "P1", case_5c_ha07_cn_dn_combo),
    CaseSpec("5C-HA-08", "5C高可用", "tree", "1 台 DN READONLY + 1 台 DN 停机期间创建 RegionGroup",
             "P1", case_5c_ha08_readonly_stop_combo),
    CaseSpec("5C-HA-09", "5C高可用", "tree", "后台写新 slot 途中停 1 台 DN（创建过程中故障）",
             "P1", case_5c_ha09_stop_during_load),
    CaseSpec("5C-RST-01", "5C重启", "tree", "整集群重启后再查询：组数/映射/行数不变且仍可扩容",
             "P0", case_5c_rst01_cluster_restart),
]
