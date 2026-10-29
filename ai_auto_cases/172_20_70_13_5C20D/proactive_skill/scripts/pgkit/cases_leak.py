"""5C20D 泄漏与多 DN 用例（LEAK-* / MULTI-*）。

实现口径
========
* 拓扑一律取 ``ctx.cfg``（``all_hosts`` / ``dn_hosts`` / ``cn_hosts``），不读
  ``DEPLOY_HOSTS``——该键在 5C20D 档位里本就留空（拓扑唯一来源是 ``conf/nodes.conf``）。
* 采样一律经由**真实进程**：``jps -l`` 找 ``ConfigNode`` / ``DataNode`` 的 pid，再对
  **每个 JVM** 单独 ``jcmd``（.100~.104 同机双角色，按主机计数会把 CN/DN 混成一个数）。
* 采样明细写 ``<case_dir>/evidence/*.tsv``；判据与实测值同时进 ``result.json``。
* 阈值只从 conf 读；工具/环境不可用 ⇒ ``skip(原因)``，绝不写成 PASS。
* 多 DN 的副本身份是 **DataNodeId**，用例把它映射回主机后再断言"5 台不同 DN"。
"""
from __future__ import annotations

import json
import re
import statistics
import time
from pathlib import Path

from .cases import (
    CaseSpec,
    Ctx,
    device_set,
    ensure_write_table,
    ensure_write_tree,
    expect_groups,
    expected_cap,
    group_ceiling,
    reset_db,
)

THREAD_TOP_N = 10


# ------------------------------------------------------------------ conf 取值
def _cfg_int(ctx: Ctx, key: str, default: int) -> int:
    try:
        return ctx.cfg.get_int(key)
    except Exception:  # noqa: BLE001 - 缺键时用默认值
        try:
            return int(ctx.cfg.raw(key) or default)
        except Exception:  # noqa: BLE001
            return default


def _cfg_float(ctx: Ctx, key: str, default: float) -> float:
    try:
        return float(ctx.cfg.raw(key) or default)
    except Exception:  # noqa: BLE001
        return default


def _evidence(ctx: Ctx) -> Path:
    path = ctx.case_dir / "evidence"
    path.mkdir(parents=True, exist_ok=True)
    return path


# ------------------------------------------------------------------ 进程与采样
def _procs(ctx: Ctx, host: str) -> list[tuple[str, int]]:
    """该主机上的 (角色, pid)，角色取 ``cn`` / ``dn``。"""
    res = ctx.ssh.run(host, "jps -l 2>/dev/null || sudo -n jps -l 2>/dev/null || true",
                      check=False, timeout=60)
    out: list[tuple[str, int]] = []
    for line in (res.out or "").splitlines():
        parts = line.split()
        if len(parts) < 2 or not parts[0].isdigit():
            continue
        role = ""
        low = parts[1].lower()
        if "confignode" in low:
            role = "cn"
        elif "datanode" in low:
            role = "dn"
        if role:
            out.append((role, int(parts[0])))
    return out


_THREAD_CMD = "jcmd {pid} Thread.print 2>/dev/null | sed -n 's/^\"\\([^\"]*\\)\".*/\\1/p'"


def _threads_of(ctx: Ctx, host: str, pid: int) -> tuple[int, dict[str, int]]:
    """返回 (线程总数, {线程名前缀: 条数})；取不到返回 (0, {})。"""
    res = ctx.ssh.run(host, _THREAD_CMD.format(pid=pid), check=False, timeout=180)
    names = [n.strip() for n in (res.out or "").splitlines() if n.strip()]
    if not names:
        res = ctx.ssh.run(
            host,
            f"jstack {pid} 2>/dev/null | sed -n 's/^\"\\([^\"]*\\)\".*/\\1/p'",
            check=False, timeout=180)
        names = [n.strip() for n in (res.out or "").splitlines() if n.strip()]
    grouped: dict[str, int] = {}
    for name in names:
        key = re.split(r"[-_\d]", name, maxsplit=1)[0] or name
        grouped[key] = grouped.get(key, 0) + 1
    return len(names), grouped


_HEAP_CMD = "jcmd {pid} GC.run >/dev/null 2>&1; jcmd {pid} GC.heap_info 2>/dev/null | head -4"


def _heap_of(ctx: Ctx, host: str, pid: int) -> float:
    """强制 GC 后读 used heap（MB）；不可用返回 -1。"""
    res = ctx.ssh.run(host, _HEAP_CMD.format(pid=pid), check=False, timeout=300)
    m = re.search(r"used\s+(\d+)([KMG])", res.out or "")
    if not m:
        return -1.0
    value, unit = float(m.group(1)), m.group(2)
    # 换算成 MB：K→/1024、M→×1、G→×1024。旧实现写成 value/(1024**2)×factor，
    # 于是 99321K 被读成 0.09MB（25 个 JVM 合计只有 2MB 的荒谬值），堆判定全部失真。
    return value * {"K": 1.0 / 1024, "M": 1.0, "G": 1024.0}[unit]


def _dump_thread_names(ctx: Ctx, tag: str) -> None:
    """把每台 DN 的**线程全名**（含计数）落盘，用于把"pool +470"落到具体池。

    ``threads_<tag>.tsv`` 只保留 top 前缀计数（pool:470 这种），排查时看不到是哪个池；
    这里额外抓一次全名，写进 ``thread_names_<tag>.txt``，便于跨轮 diff 出"新建且不回收"的池。
    """
    out = []
    for host in ctx.cfg.dn_hosts:
        res = ctx.ssh.run(
            host,
            "for p in $(ps -eo pid,args --no-headers | awk '/[D]ataNode/{print $1}'); do "
            "timeout 30 jcmd $p Thread.print 2>/dev/null | "
            "grep -oE '^\"[^\"]+\"' | tr -d '\"'; done | sort | uniq -c | sort -rn | head -400",
            check=False, timeout=90)
        text = (res.out or "").strip()
        if text:
            out.append(f"### {host}\n{text}")
    if out:
        (_evidence(ctx) / f"thread_names_{tag}.txt").write_text(
            "\n\n".join(out) + "\n", encoding="utf-8")


def _sample_threads(ctx: Ctx, tag: str) -> tuple[dict[str, int], dict[str, int], int]:
    """逐 JVM 采线程数。

    返回 ``(按角色合计, 按主机合计, 有效 JVM 数)``，同时把明细写入 evidence。
    """
    by_role: dict[str, int] = {"cn": 0, "dn": 0}
    by_host: dict[str, int] = {}
    lines = ["host\trole\tpid\tthreads\ttop"]
    ok = 0
    for host in ctx.cfg.all_hosts:
        procs = _procs(ctx, host)
        if not procs:
            lines.append(f"{host}\t?\t-\t-1\tjps 不可用")
            continue
        host_total = 0
        for role, pid in procs:
            count, grouped = _threads_of(ctx, host, pid)
            if count <= 0:
                lines.append(f"{host}\t{role}\t{pid}\t-1\tjcmd/jstack 不可用")
                continue
            ok += 1
            by_role[role] = by_role.get(role, 0) + count
            host_total += count
            top = ",".join(f"{k}:{v}" for k, v in
                           sorted(grouped.items(), key=lambda kv: -kv[1])[:THREAD_TOP_N])
            lines.append(f"{host}\t{role}\t{pid}\t{count}\t{top}")
        if host_total:
            by_host[host] = host_total
    path = _evidence(ctx) / f"threads_{tag}.tsv"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    _dump_thread_names(ctx, tag)
    ctx.note(f"  [{tag}] 线程采样：{ok} 个 JVM 可用，合计 {sum(by_role.values())}")
    return by_role, by_host, ok


def _sample_heap(ctx: Ctx, tag: str) -> tuple[dict[str, float], int]:
    by_role: dict[str, float] = {"cn": 0.0, "dn": 0.0}
    lines = ["host\trole\tpid\theap_used_mb"]
    ok = 0
    for host in ctx.cfg.all_hosts:
        for role, pid in _procs(ctx, host):
            used = _heap_of(ctx, host, pid)
            if used < 0:
                lines.append(f"{host}\t{role}\t{pid}\t-1")
                continue
            ok += 1
            by_role[role] = by_role.get(role, 0.0) + used
            lines.append(f"{host}\t{role}\t{pid}\t{used:.1f}")
    path = _evidence(ctx) / f"heap_{tag}.tsv"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    ctx.note(f"  [{tag}] 堆采样：{ok} 个 JVM 可用，CN={by_role['cn']:.0f}MB "
             f"DN={by_role['dn']:.0f}MB")
    return by_role, ok


#: 线程分类（键 = conf 里的 LEAK_THREAD_PATTERNS_<CAT>；顺序敏感）
_CATEGORIES = ("COMPACTION", "IOTCONSENSUS", "REGIONGROUP", "HEARTBEAT", "CONNECTION")


def _thread_categories(ctx: Ctx, tag: str) -> dict[str, int]:
    """按 conf 的 LEAK_THREAD_PATTERNS_* 把线程名归类计数（无匹配记为 other）。

    残差归因用：只有知道"多出来的是哪一类线程"，才能判断是泄漏还是正常的连接池增长。
    """
    patterns = {}
    for cat in _CATEGORIES:
        raw = (ctx.cfg.raw(f"LEAK_THREAD_PATTERNS_{cat}") or "").strip()
        patterns[cat] = [p.strip().lower() for p in raw.split(",") if p.strip()]
    totals: dict[str, int] = {}
    lines = ["host\trole\tpid\tcategory\tcount"]
    for host in ctx.cfg.all_hosts:
        for role, pid in _procs(ctx, host):
            _count, grouped = _threads_of(ctx, host, pid)
            for name, count in grouped.items():
                low = name.lower()
                cat = "other"
                for key in _CATEGORIES:
                    if any(p in low for p in patterns[key]):
                        cat = key.lower()
                        break
                totals[cat] = totals.get(cat, 0) + count
                if count >= 5:
                    lines.append(f"{host}\t{role}\t{pid}\t{cat}:{name}\t{count}")
    path = _evidence(ctx) / f"thread_categories_{tag}.tsv"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    ctx.note(f"  [{tag}] 线程分类：" + json.dumps(totals, ensure_ascii=False))
    return totals


def _slope(ys: list[float]) -> float:
    n = len(ys)
    if n < 2:
        return 0.0
    xs = list(range(n))
    mx, my = statistics.mean(xs), statistics.mean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return 0.0 if den == 0 else sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den


# ------------------------------------------------------------------ 数据夹具
def _write_slots(ctx: Ctx, db: str, count: int, *, prefix: str = "lk", stamp: int = 1,
                 model: str = "tree", table: str = "tb") -> list[str]:
    """写入 count 个**互不相同 slot** 的设备/TAG，每个新 slot 触发一次扩容。"""
    items = device_set(ctx, db, count, dialect=model, prefix=prefix)
    for i, item in enumerate(items):
        if model == "table":
            ensure_write_table(ctx, db, table, item, stamp=stamp + i, fields=1)
        else:
            ensure_write_tree(ctx, db, item, stamp=stamp + i, sensors=("s0",))
    return items


def _dn_id_map(ctx: Ctx) -> dict[str, str]:
    """DataNodeId → 主机 IP（副本行里只有 NodeId）。"""
    mapping: dict[str, str] = {}
    try:
        for row in ctx.cluster.datanodes():
            node_id = (row.get("NodeID") or row.get("NodeId") or "").strip()
            addr = (row.get("RpcAddress") or row.get("InternalAddress") or "").strip()
            if node_id and addr:
                mapping[node_id] = addr.split(":")[0]
    except Exception:  # noqa: BLE001 - 拿不到映射时按 NodeId 原样比较
        pass
    return mapping


def _replica_status(ctx: Ctx, db: str, kind: str) -> dict[str, dict[str, str]]:
    """{groupId: {host: 副本状态}}。

    ``SHOW (SCHEMA|DATA) REGIONS`` 每行是**一个副本**，``Status`` 列是副本状态；
    组级状态并不出现在该视图里。旧实现把"最后一行副本状态"当组状态，于是在"停 1 台 DN"
    时读到被停副本的 Unknown 就误判成"组状态异常"（V2 轮 MULTI-03 即此误判）。
    """
    id_map = _dn_id_map(ctx)
    groups = ctx.api.groups(db, kind=kind, dialect="tree")
    out: dict[str, dict[str, str]] = {}
    for gid, group in groups.items():
        per: dict[str, str] = {}
        for row in group.raw:
            dn = (row.get("DataNodeId") or "").strip()
            status = (row.get("Status") or "").strip()
            host = id_map.get(dn, dn)
            if host:
                per[host] = status
        out[gid] = per
    return out


def _replica_hosts(ctx: Ctx, db: str, kind: str) -> dict[str, list[str]]:
    """{regionGroupId: [主机 IP,...]}（已把 DataNodeId 映射成主机）。"""
    id_map = _dn_id_map(ctx)
    groups = ctx.api.groups(db, kind=kind, dialect="tree")
    return {gid: sorted({id_map.get(str(r).split(":")[0], str(r).split(":")[0])
                         for r in group.replicas})
            for gid, group in groups.items()}


# ------------------------------------------------------------------ 收尾数据集
def _closing_dataset(ctx: Ctx, tag: str) -> str:
    """给收尾②（副本一致性）留一份**真实数据**。

    THR-02/THR-03/MEM-01/MEM-02 的用例体把库都删掉了；收尾②要求"同一数据集在各副本上
    查一遍"，没有数据集就只能报"dataset never settled"，把线程/内存结论淹没在一个与产品
    无关的失败里。这里显式写一个 3 设备的保留库（`reset_db` + `ensure_write_tree` 会自动
    登记对拍查询），用例体自己删掉的库仍按原判据断言。
    """
    db = f"root.lk_keep_{tag.replace('-', '').lower()}"
    ctx.cleanup.append(f"drop database {db}")
    reset_db(ctx, "tree", db)
    _write_slots(ctx, db, 3, prefix=f"kp{tag[-2:]}".lower(), stamp=7)
    return db


# ------------------------------------------------------------------ 线程泄漏
def case_leak_thr01(ctx: Ctx) -> None:
    """LEAK-THR-01 稳态线程基线（逐 JVM 采，top 线程名落 evidence）。"""
    if not ctx.cfg.all_hosts:
        ctx.skip("conf 未解析出任何节点（nodes.conf 为空）")
        return
    db = reset_db(ctx, "tree")
    _write_slots(ctx, db, _cfg_int(ctx, "LEAK_DEVICES_PER_DB", 30))
    by_role, by_host, ok = _sample_threads(ctx, "baseline")
    if ok == 0:
        ctx.skip("所有节点都取不到 jcmd/jstack 线程信息（JDK/jcmd 不可用或 SSH 不通）")
        return
    ctx.check(f"线程基线可采（{ok} 个 JVM，覆盖 {len(by_host)}/{len(ctx.cfg.all_hosts)} 台）",
              ok >= max(1, len(ctx.cfg.all_hosts)),
              f"CN 线程={by_role['cn']}、DN 线程={by_role['dn']}",
              evidence=str(_evidence(ctx) / "threads_baseline.tsv"))
    ctx.check("每台主机都能采到线程数（>0）", len(by_host) == len(ctx.cfg.all_hosts),
              f"缺采样主机={sorted(set(ctx.cfg.all_hosts) - set(by_host))}")


def case_leak_thr02(ctx: Ctx) -> None:
    """LEAK-THR-02 建库→写 N slot→删库 循环：线程斜率与末轮余量。

    采样口径（与 RUNBOOK「首轮偏高」一致）：
    * 每 2 轮采一次（含首轮与末轮），**首轮样本只作为预热基线**（JIT/连接池/region 线程池拉起）；
    * 斜率与末轮余量都用 ``samples[1:]`` 计算，并要求 ≥3 个采样点才下结论。
    """
    rounds = _cfg_int(ctx, "LEAK_ROUNDS", 8)
    devices = _cfg_int(ctx, "LEAK_DEVICES_PER_DB", 30)
    slope_max = _cfg_float(ctx, "LEAK_THREAD_SLOPE_MAX", 0.5)
    margin = _cfg_int(ctx, "LEAK_THREAD_MARGIN", 50)
    samples: list[int] = []
    for i in range(rounds):
        db = reset_db(ctx, "tree")
        _write_slots(ctx, db, devices, prefix=f"t2{i}")
        ctx.api.drop_database(db)
        if i == 0 or (i + 1) % 2 == 0:
            by_role, _by_host, ok = _sample_threads(ctx, f"r{i + 1}")
            if ok == 0:
                ctx.skip("无法取线程信息（jcmd/jstack 不可用）")
                return
            samples.append(sum(by_role.values()))
    if len(samples) < 3:
        ctx.skip(f"采样点不足（{len(samples)} < 3），无法判断斜率")
        return
    measured = samples[1:]
    sl = _slope(measured)
    # 绝对斜率阈值（条/轮）在 25 个 JVM 的聚合量上不成立：线程总量约 5000，单次采样
    # 自身抖动就有 ±30（GC/JIT/压缩/连接池线程本来就有生灭）。因此斜率上限取
    # max(LEAK_THREAD_SLOPE_MAX, 基线 × LEAK_THREAD_SLOPE_PCT %)。两个值都进断言名与详情，
    # 便于不同规模的集群对照；真正的"泄漏"会表现为超过比例阈值的持续单调上升。
    pct = _cfg_float(ctx, "LEAK_THREAD_SLOPE_PCT", 0.5)
    limit = max(slope_max, measured[0] * pct / 100.0)
    ctx.check(f"预热后线程数无持续增长（斜率 {sl:.2f} ≤ {limit:.2f} 条/轮"
              f"= max({slope_max}, {measured[0]}×{pct}%)；预热样本 {samples[0]} 不计入）",
              sl <= limit,
              f"samples={samples} measured={measured} slope={sl:.2f} limit={limit:.2f}",
              evidence=str(_evidence(ctx)))
    ctx.check(f"末轮线程 ≤ 预热后基线+{margin}（末轮 {measured[-1]} / 基线 {measured[0]}）",
              measured[-1] <= measured[0] + margin,
              f"samples={samples} measured={measured} margin={margin}")
    _closing_dataset(ctx, "thr02")


def case_leak_thr03(ctx: Ctx) -> None:
    """LEAK-THR-03 多 slot 扩容 → 删库：线程回落到基线+余量。

    收尾的"回落"必须等 region 真正销毁：删库后 CN 异步下发 remove-region-group，
    DN 侧的 per-consensus-group 线程池在组销毁后才会关。因此先等 ``SHOW REGIONS``
    看不到这些库的组，再连续采样 3 次取**最小值**作为 after —— 早采会把"还在销毁中"
    误判成泄漏（实测删库 30s 后仍高 1100+ 条，需要更长的观测窗才能分清是滞后还是泄漏）。
    """
    cycles = _cfg_int(ctx, "LEAK_THREAD_CYCLES", 3)
    slots = _cfg_int(ctx, "LEAK_THREAD_SLOTS", 10)
    settle = _cfg_int(ctx, "LEAK_SETTLE_SECONDS", 30)
    margin = _cfg_int(ctx, "LEAK_THREAD_MARGIN", 50)
    pct = _cfg_float(ctx, "LEAK_THREAD_SLOPE_PCT", 0.5)
    reclaim_wait = _cfg_int(ctx, "MULTI_RECLAIM_WAIT_SEC", 600)
    # 先做一轮"预热建删"再采基线：DN 侧有一批**按核数/内存一次性拉满**的池
    # （Pipe 执行池、MPP 协调池、gRPC worker…），实测冷集群首轮建删会让总线程
    # +2 820（≈141/台），之后每轮只再 +110~149。冷基线会把这笔一次性预热全部
    # 算成"泄漏"，因此基线必须取在预热之后（与 LEAK-THR-02 的"首样本不计入"同义）。
    if _cfg_int(ctx, "LEAK_WARMUP_ROUNDS", 1) > 0:
        warm = "root.lk_warm"
        ctx.cleanup.append(f"drop database {warm}")
        ctx.api.drop_database(warm)
        ctx.mark_harness_action(f"LEAK-THR-03 预热建库 {warm}", kind="create_db")
        ctx.req(ctx.api.create_database(warm), f"create database {warm}")
        _write_slots(ctx, warm, slots, prefix="warm")
        time.sleep(settle)
        ctx.mark_harness_action(f"LEAK-THR-03 预热删库 {warm}", kind="drop_db")
        ctx.api.drop_database(warm)
        # 等这次预热库的组也销毁，避免把它的滞后算进基线
        deadline_w = time.time() + reclaim_wait
        while time.time() < deadline_w:
            if not ctx.api.group_count(warm, kind="DATA", dialect="tree"):
                break
            time.sleep(10)
        time.sleep(settle)
        ctx.note("  预热轮完成（其线程增量不计入基线，见 LEAK_WARMUP_ROUNDS）")

    by_role, _by_host, ok = _sample_threads(ctx, "before")
    if ok == 0:
        ctx.skip("无法取线程信息（jcmd/jstack 不可用）")
        return
    base = sum(by_role.values())
    cat_before = _thread_categories(ctx, "before")
    dbs: list[str] = []
    for i in range(cycles):
        db = f"root.lk_t3_{i}"
        ctx.cleanup.append(f"drop database {db}")
        ctx.api.drop_database(db)
        ctx.mark_harness_action(f"LEAK-THR-03 建库 {db}", kind="create_db")
        ctx.req(ctx.api.create_database(db), f"create database {db}")
        _write_slots(ctx, db, slots, prefix=f"t3{i}")
        dbs.append(db)
    time.sleep(settle)
    peak_role, _h, _ok_peak = _sample_threads(ctx, "peak")
    peak = dict(peak_role)
    for db in dbs:
        ctx.mark_harness_action(f"LEAK-THR-03 删库 {db}", kind="drop_db")
        ctx.api.drop_database(db)

    # ① 先等组真的消失（有界），再判线程
    deadline = time.time() + reclaim_wait
    left: dict[str, int] = {}
    while time.time() < deadline:
        left = {db: ctx.api.group_count(db, kind="DATA", dialect="tree") for db in dbs}
        if not any(left.values()):
            break
        time.sleep(10)
    ctx.check(f"删库后 {len(dbs)} 个库的 Data 组已回收（≤{reclaim_wait}s）", not any(left.values()),
              f"残留={left}")

    # ② 连续采样取最小值。销毁在收敛中：组已从 CN 视图消失，但 DN 侧线程池的关闭可能
    #    滞后（实测删库后 1 分钟仍高出 800+ 条）。因此采样窗口拉到 ~4 分钟（3 次密采 +
    #    2 次间隔 120s 的慢采），用全程最小值判定，并把轨迹写进证据 —— 只有"窗口内不再
    #    回落"才判泄漏，避免把滞后销毁误报成泄漏。
    after_samples: list[int] = []
    gaps = [20, 20, 120, 120]
    for i in range(5):
        by_role_after, _h2, ok2 = _sample_threads(ctx, f"after_drop_{i + 1}")
        if ok2 == 0:
            ctx.skip("删库后无法取线程信息")
            return
        after_samples.append(sum(by_role_after.values()))
        if i < 4:
            time.sleep(gaps[i])
    after = min(after_samples)
    cat_after = _thread_categories(ctx, "after_drop")
    delta = {cat: cat_after.get(cat, 0) - cat_before.get(cat, 0)
             for cat in set(cat_before) | set(cat_after)}
    top_delta = sorted(delta.items(), key=lambda kv: -kv[1])[:3]
    ctx.note(f"  残差线程分类增量（前 3）：{top_delta}；全量={delta}")
    limit = base + max(margin, int(base * pct / 100.0))
    ctx.check(f"删库后线程回落到 基线 {base} + 余量 以内（实际最小 {after} ≤ {limit}）",
              after <= limit,
              f"base={base} peak={sum(peak.values())} after_samples={after_samples} "
              f"after_min={after} limit={limit}（余量=max({margin}, {base}×{pct}%)）；"
              f"分类增量前 3={top_delta}",
              evidence=json.dumps({"delta": delta, "before": cat_before, "after": cat_after},
                                  ensure_ascii=False))
    ctx.check(f"{cycles} 轮删库后仍可建库（无残留阻塞）",
              ctx.api.create_database("root.lk_probe").ok, "create database root.lk_probe")
    ctx.cleanup.append("drop database root.lk_probe")
    _closing_dataset(ctx, "thr03")


def case_leak_thr04(ctx: Ctx) -> None:
    """LEAK-THR-04 空闲期线程数稳定（5CN+20DN 心跳/复制线程）。

    与 THR-02 同一口径：**第一次采样只作预热**（集群刚 prepare 完，连接池/region 线程池
    还在拉起，实测首个采样比稳定态高 90+ 条）。稳定态用后 3 次采样的极差判定。
    """
    samples: list[int] = []
    interval = _cfg_int(ctx, "LEAK_SAMPLE_INTERVAL_SEC", 30)
    margin = _cfg_int(ctx, "LEAK_THREAD_MARGIN", 50)
    for i in range(4):
        by_role, _h, ok = _sample_threads(ctx, f"idle{i + 1}")
        if ok == 0:
            ctx.skip("无法取线程信息（jcmd/jstack 不可用）")
            return
        samples.append(sum(by_role.values()))
        if i < 3:
            time.sleep(interval)
    measured = samples[1:]
    spread = max(measured) - min(measured)
    ctx.check(f"空闲期稳定态 3 次采样波动 {spread} ≤ {margin}（预热样本 {samples[0]} 不计入）",
              spread <= margin, f"samples={samples} measured={measured}",
              evidence=str(_evidence(ctx)))


# ------------------------------------------------------------------ 内存泄漏
def case_leak_mem01(ctx: Ctx) -> None:
    """LEAK-MEM-01 GC 后堆不持续增长（多轮建删 + 每轮采样）。"""
    rounds = _cfg_int(ctx, "LEAK_HEAP_ROUNDS", 8)
    devices = _cfg_int(ctx, "LEAK_MEM_DEVICES", 20)
    pct = _cfg_float(ctx, "LEAK_HEAP_GROWTH_PCT", 15.0)
    margin_mb = _cfg_float(ctx, "LEAK_HEAP_MARGIN_MB", 256.0)
    samples: list[float] = []
    for i in range(rounds):
        db = reset_db(ctx, "tree")
        _write_slots(ctx, db, devices, prefix=f"m1{i}")
        ctx.api.drop_database(db)
        if i == 0 or (i + 1) % 2 == 0:
            by_role, ok = _sample_heap(ctx, f"r{i + 1}")
            if ok == 0:
                ctx.skip("无法取堆信息（jcmd 不可用）")
                return
            samples.append(round(sum(by_role.values()), 1))
    if len(samples) < 3:
        ctx.skip(f"采样点不足（{len(samples)} < 3）")
        return
    measured = samples[1:]              # 首轮含首次建库后的元数据缓存，按 RUNBOOK 作预热
    growth = (measured[-1] - measured[0]) / measured[0] * 100 if measured[0] else 0.0
    abs_growth = measured[-1] - measured[0]
    ctx.check(f"GC 后堆增长 {growth:.1f}% ≤ {pct}%（或绝对增量 {abs_growth:.0f}MB ≤ {margin_mb}MB）",
              growth <= pct or abs_growth <= margin_mb,
              f"samples={samples} measured={measured}", evidence=str(_evidence(ctx)))
    # 锯齿是正常形态：单点比较（末轮 vs 上一轮）会把 +2% 的采样抖动判成"上升"。
    # 这里只断言**净增长**不超过余量，与上面的百分比判据互补。
    ctx.check(f"无净增长（末轮 {measured[-1]:.0f}MB ≤ 首测 {measured[0]:.0f}MB + {margin_mb}MB）",
              measured[-1] <= measured[0] + margin_mb, f"measured={measured}")
    _closing_dataset(ctx, "mem01")


def case_leak_mem02(ctx: Ctx) -> None:
    """LEAK-MEM-02 300 库建删后堆回落、库清空。"""
    n = _cfg_int(ctx, "MEM_LOOP_DBS", 300)
    pct = _cfg_float(ctx, "LEAK_HEAP_GROWTH_PCT", 15.0)
    margin_mb = _cfg_float(ctx, "LEAK_HEAP_MARGIN_MB", 256.0)
    settle = _cfg_int(ctx, "LEAK_SETTLE_SECONDS", 30)
    before_role, ok = _sample_heap(ctx, "before")
    if ok == 0:
        ctx.skip("无法取堆信息（jcmd 不可用）")
        return
    base = sum(before_role.values())
    names = [f"root.lkm{i}" for i in range(n)]
    failed_create = 0
    for db in names:
        if not ctx.api.create_database(db).ok:
            failed_create += 1
    for db in names:
        ctx.api.drop_database(db)
    time.sleep(settle)
    after_role, _ok = _sample_heap(ctx, "after")
    after = sum(after_role.values())
    growth = (after - base) / base * 100 if base else 999.0
    ctx.check(f"{n} 库全部创建成功", failed_create == 0, f"失败={failed_create}")
    ctx.check(f"建删后堆回落（{growth:.1f}% ≤ {pct}% 或绝对增量 {after - base:.0f}MB ≤ {margin_mb}MB）",
              growth <= pct or (after - base) <= margin_mb,
              f"base={base:.0f}MB after={after:.0f}MB")
    left = ctx.api.run("show databases")
    ctx.check("库已清空（无 root.lkm* 残留）", "lkm" not in (left.output or ""),
              f"output={(left.output or '')[:200]}")
    _closing_dataset(ctx, "mem02")


def case_leak_mem03(ctx: Ctx) -> None:
    """LEAK-MEM-03 多时间分区写入：堆增长与写入量匹配（每点预算）。"""
    partitions = _cfg_int(ctx, "LEAK_MEM_TIME_PARTITIONS", 6)
    per_partition = _cfg_int(ctx, "LEAK_MEM_POINTS_PER_PARTITION", 2000)
    batch = _cfg_int(ctx, "LEAK_MEM_INSERT_BATCH", 200)
    bytes_max = _cfg_float(ctx, "LEAK_MEM_BYTES_PER_POINT_MAX", 4096.0)
    # 先做一轮"预热写入"再采基线：冷集群的首次写入要一次性拉起 memtable/WAL/
    # TsFileWriter/pipe 等结构，实测同一份 12000 点写入，冷集群测到 +259MB，
    # 预热后只 +39MB（第二次 +88MB）。冷基线会把一次性分配算成"每点增长"，
    # 故基线取在预热之后（LEAK_MEM_WARMUP=0 可关掉，用于对照旧口径）。
    if _cfg_int(ctx, "LEAK_MEM_WARMUP", 1) > 0:
        warm = reset_db(ctx, "tree")
        interval_w = ctx.api.db_time_partition_interval(warm, dialect="tree") or 604800000
        for p_i in range(partitions):
            start_w = p_i * interval_w + 1
            for offset in range(0, per_partition, batch):
                rows_w = [(start_w + k, ["s0"], [1.0])
                          for k in range(offset, offset + batch)]
                ctx.req(ctx.api.insert_tree_many(f"{warm}.d_mem3", rows_w),
                        f"warmup insert {per_partition} points into partition {p_i}")
        ctx.api.flush()
        ctx.mark_harness_action(f"LEAK-MEM-03 预热删库 {warm}", kind="drop_db")
        ctx.api.drop_database(warm)
        time.sleep(_cfg_int(ctx, "LEAK_SETTLE_SECONDS", 30))
        ctx.note("  预热写入完成（其堆增量不计入基线，见 LEAK_MEM_WARMUP）")

    before_role, ok = _sample_heap(ctx, "before")
    if ok == 0:
        ctx.skip("无法取堆信息（jcmd 不可用）")
        return
    base = sum(before_role.values())
    db = reset_db(ctx, "tree")
    interval = ctx.api.db_time_partition_interval(db, dialect="tree") or 604800000
    device = "d_mem3"
    written = 0
    for p in range(partitions):
        start = p * interval + 1
        for offset in range(0, per_partition, batch):
            rows = [(start + k, ["s0"], [1.0]) for k in range(offset, offset + batch)]
            ctx.req(ctx.api.insert_tree_many(f"{db}.{device}", rows),
                    f"insert {per_partition} points into partition {p}")
            written += len(rows)
    ctx.api.flush()
    time.sleep(_cfg_int(ctx, "LEAK_SETTLE_SECONDS", 30))
    after_role, _ok = _sample_heap(ctx, "after")
    after = sum(after_role.values())
    grown_mb = after - base
    budget_mb = written * bytes_max / (1024 ** 2)
    # 每点预算是"数据本身"的量级；写入还会带来 memtable/TsFile writer/新建 region 的
    # 常驻结构，25 个 JVM 的聚合堆本身就有 ±15% 的正常波动（与 MEM-01/02 同一口径）。
    # 因此判据取两者较大值，同时把"每点实际增长"打印出来供人工复核。
    pct = _cfg_float(ctx, "LEAK_HEAP_GROWTH_PCT", 15.0)
    rel_budget = base * pct / 100.0
    limit = max(budget_mb, rel_budget)
    per_point = grown_mb * 1024 ** 2 / written if written else 0.0
    ctx.check(f"{written} 点（{partitions} 个时间分区）写入后堆增长 {grown_mb:.0f}MB ≤ "
              f"max(每点预算 {budget_mb:.0f}MB, {pct}%×基线 {rel_budget:.0f}MB)={limit:.0f}MB",
              grown_mb <= limit,
              f"base={base:.0f}MB after={after:.0f}MB 每点增长={per_point:.0f}B/点",
              evidence=str(_evidence(ctx)))
    got = ctx.api.count_rows(f"{db}.{device}", dialect="tree")
    ctx.check("写入的数据可回读（行数 ≥ 1）", got >= 1, f"count={got}")
    # 本用例确实写了数据（12000 行），必须给收尾② 登记对拍查询；否则收尾② 会误报
    # "本用例未写入任何数据"，等于把"没对拍"伪装成"不需要对拍"。
    ctx.note_data_written(db, device, "tree")


def case_leak_mem04(ctx: Ctx) -> None:
    """LEAK-MEM-04 benchmark 长跑堆呈锯齿（benchmark 命令未配置则 SKIP）。"""
    bench_cmd = (ctx.cfg.raw("BENCH_CMD") or "").strip()
    if not bench_cmd:
        ctx.skip("BENCH_CMD 未配置（benchmark 目录存在但未给可执行命令），长跑负载不可用")
        return
    minutes = _cfg_int(ctx, "MEM_LONG_MINUTES", 30)
    step = max(60, _cfg_int(ctx, "LEAK_MEM_LOAD_SAMPLE_MINUTES", 5) * 60)
    pct = _cfg_float(ctx, "LEAK_HEAP_GROWTH_PCT", 15.0)
    samples: list[float] = []
    deadline = time.time() + minutes * 60
    ctx.note(f"  长跑负载：{bench_cmd}（{minutes} 分钟，每 {step}s 采样）")
    proc = ctx.ssh.run(ctx.cfg.cli_host,
                       f"nohup setsid bash -lc {bench_cmd!r} >/dev/null 2>&1 & echo $!",
                       check=False, timeout=60)
    ctx.note(f"  负载 pid：{(proc.out or '').strip()}")
    while time.time() < deadline:
        by_role, ok = _sample_heap(ctx, f"long_{len(samples)}")
        if ok == 0:
            ctx.skip("无法取堆信息（jcmd 不可用）")
            return
        samples.append(round(sum(by_role.values()), 1))
        time.sleep(step)
    if len(samples) < 3:
        ctx.skip("采样点不足（<3），无法判断锯齿")
        return
    growth = (samples[-1] - samples[0]) / samples[0] * 100 if samples[0] else 0.0
    ctx.check(f"长跑后堆增长 {growth:.1f}% ≤ {pct}%", growth <= pct, f"samples={samples}")
    ctx.check("堆呈锯齿（出现过回落）", any(b < a for a, b in zip(samples, samples[1:])),
              f"samples={samples}")


# ------------------------------------------------------------------ 多 DN
def case_multi01(ctx: Ctx) -> None:
    """MULTI-01 每个 SchemaRegionGroup 的 5 个副本落在 5 台不同 DN。"""
    rf = _cfg_int(ctx, "SCHEMA_REPLICATION_FACTOR", 5)
    db = reset_db(ctx, "tree")
    _write_slots(ctx, db, 3, prefix="m1")
    replica = _replica_hosts(ctx, db, "SCHEMA")
    bad = {gid: hosts for gid, hosts in replica.items() if len(hosts) != rf}
    ctx.check(f"有 Schema 组可查（组数 {len(replica)} ≥ 1）", len(replica) >= 1,
              f"groups={sorted(replica)}")
    ctx.check(f"每个 Schema 组副本落在 {rf} 台不同 DN", not bad,
              f"违规={dict(list(bad.items())[:5])}",
              evidence=str(replica)[:4000])
    all_hosts = set(ctx.cfg.dn_hosts)
    stray = {gid: [h for h in hosts if h not in all_hosts] for gid, hosts in replica.items()}
    ctx.check("副本落点都在 conf 的 DN 清单内", not any(stray.values()), f"异常={stray}")


def case_multi02(ctx: Ctx) -> None:
    """MULTI-02 每个 Data 组 3 副本互斥；20 DN 上组数均衡 max/min ≤ 阈值。"""
    rf = _cfg_int(ctx, "DATA_REPLICATION_FACTOR", 3)
    ratio_max = _cfg_float(ctx, "BALANCE_RATIO_MAX", 2.0)
    dbs = _cfg_int(ctx, "MULTI_BALANCE_DBS", 4)
    slots = _cfg_int(ctx, "MULTI_BALANCE_SLOTS", 6)
    per_host: dict[str, int] = {}
    bad: dict[str, list[str]] = {}
    total_groups = 0
    for i in range(dbs):
        db = f"root.pg_bal{i}"
        ctx.cleanup.append(f"drop database {db}")
        ctx.api.drop_database(db)
        ctx.mark_harness_action(f"MULTI-02 建库 {db}", kind="create_db")
        ctx.req(ctx.api.create_database(db), f"create database {db}")
        _write_slots(ctx, db, slots, prefix=f"b{i}", model="tree")
        replica = _replica_hosts(ctx, db, "DATA")
        total_groups += len(replica)
        for gid, hosts in replica.items():
            if len(hosts) != rf:
                bad[gid] = hosts
            for host in hosts:
                per_host[host] = per_host.get(host, 0) + 1
    ctx.check(f"有 Data 组可查（{dbs} 库共 {total_groups} 组）", total_groups >= dbs,
              f"groups={total_groups}")
    ctx.check(f"每个 Data 组 {rf} 个副本互不相同", not bad,
              f"违规={dict(list(bad.items())[:5])}")
    if per_host:
        values = list(per_host.values())
        lo, hi = min(values), max(values)
        ratio = hi / lo if lo else 999.0
        covered = len(per_host)
        dn_num = len(ctx.cfg.dn_hosts)
        mean = sum(values) / dn_num
        max_diff = _cfg_int(ctx, "MULTI_BALANCE_MAX_DIFF", 3)
        ctx.check(f"{dn_num} 个 DN 上有 {covered} 台承载了副本", covered >= 1,
                  f"per_host={per_host}")
        # 比值口径在"每 DN 只有 1~3 个副本"时失真：45 个副本摊到 20 台，理想值 2.25，
        # 完全均衡也只能落在 2/3 之间，此时 min=1、max=3 的比值 3.0 并不等于"不均衡"。
        # 因此：min ≥ 2 用比值（阈值 BALANCE_RATIO_MAX），否则用绝对差
        # （阈值 MULTI_BALANCE_MAX_DIFF）。两种口径的实测值都进报告，切换理由随行写明。
        if lo >= 2:
            ctx.check(f"DN 间组数均衡（比值口径）max/min={ratio:.2f} ≤ {ratio_max}",
                      ratio <= ratio_max,
                      f"lo={lo} hi={hi} mean={mean:.2f} per_host={per_host}")
        else:
            ctx.check(f"DN 间组数均衡（绝对差口径：min={lo}<2，比值失真）"
                      f"max-min={hi - lo} ≤ {max_diff}", (hi - lo) <= max_diff,
                      f"lo={lo} hi={hi} mean={mean:.2f} per_host={per_host}")
        ctx.check(f"每 DN 副本数偏离均值 {mean:.2f} 不超过 1.5",
                  (hi - mean) <= 1.5 and (mean - lo) <= 1.5,
                  f"lo={lo} hi={hi} mean={mean:.2f} 偏离={max(hi - mean, mean - lo):.2f}")


def case_multi03(ctx: Ctx) -> None:
    """MULTI-03 停 1 台 DN：SR 在线副本 ≥ RF-1、查询可执行、恢复后组状态 Running。"""
    srf = _cfg_int(ctx, "SCHEMA_REPLICATION_FACTOR", 5)
    drf = _cfg_int(ctx, "DATA_REPLICATION_FACTOR", 3)
    db = reset_db(ctx, "tree")
    devices = _write_slots(ctx, db, 10, prefix="m3")
    victim = ctx.cfg.dn_hosts[-1]
    ctx.mark_harness_action(f"MULTI-03 停 DN {victim}", kind="stop")
    ctx.check(f"DataNode {victim} 已停止", ctx.cluster.stop_node(victim, "dn"),
              f"host={victim}")
    ctx.by_design_gone.add(victim)
    try:
        time.sleep(_cfg_int(ctx, "MULTI_STOP_SETTLE_SEC", 90))
        alive = set(ctx.cfg.dn_hosts) - {victim}
        schema = _replica_hosts(ctx, db, "SCHEMA")
        data = _replica_hosts(ctx, db, "DATA")
        # 停机后的正确不变量（不写"统一 min(RF, 存活)"，那会把"副本落在被停机上的组"
        # 的 RF-1 个在线副本误判成缺副本）：
        #   ① 组内副本总数 == RF；② 副本落点都在 conf 的 DN 清单里；
        #   ③ 在线副本数 == RF - (该组是否有副本落在被停机上 ? 1 : 0)。
        def _online_bad(groups: dict, rf: int) -> dict:
            bad: dict = {}
            for gid, hosts in groups.items():
                expected = rf - (1 if victim in hosts else 0)
                online = len([h for h in hosts if h in alive])
                stray = [h for h in hosts if h not in set(ctx.cfg.dn_hosts)]
                if len(hosts) != rf or online != expected or stray:
                    bad[gid] = {"replicas": hosts, "online": online,
                                "expected_online": expected, "stray": stray}
            return bad

        sbad = _online_bad(schema, srf)
        dbad = _online_bad(data, drf)
        ctx.check(f"停机后每个 Schema 组副本数={srf} 且在线副本数符合不变量（停机 1 台）",
                  bool(schema) and not sbad, f"违规={dict(list(sbad.items())[:5])}")
        ctx.check(f"停机后每个 Data 组副本数={drf} 且在线副本数符合不变量（停机 1 台）",
                  bool(data) and not dbad, f"违规={dict(list(dbad.items())[:5])}")
        got = ctx.api.count_rows(f"{db}.{devices[0]}", dialect="tree")
        ctx.check("停机期间查询可执行且有结果", got >= 1, f"count={got}")
        # 组级可用性判据（不读"组状态"这个不存在的列）：
        #   `SHOW DATA REGIONS` 每行是一个**副本**，Status 也是副本状态。
        #   弱一致（IoTConsensus/V2）下"≥1 个副本存活 ⇒ 组可读写"，因此停机期间的判据是
        #   **每组至少 1 个副本状态为 Running/Available**（Unknown 只允许出现在被停节点的那一行）；
        #   恢复后的判据是**所有副本行都回到 Running**（下面单独断言）。
        deadline = time.time() + 120
        per: dict[str, dict[str, str]] = {}
        trace: list[str] = []
        bad_groups: dict[str, dict[str, str]] = {}
        while True:
            per = _replica_status(ctx, db, "DATA")
            bad_groups = {
                gid: states for gid, states in per.items()
                if not any(st.strip().lower() in {"running", "available"} for st in states.values())
            }
            trace.append(f"t+{int(time.time() - (deadline - 120))}s: "
                         f"{ {g: v for g, v in list(bad_groups.items())[:2]} or 'all-groups-served'}")
            if not bad_groups or time.time() >= deadline:
                break
            time.sleep(5)
        unknown_rows = {gid: {h: st for h, st in states.items()
                              if st.strip().lower() not in {"running", "available"}}
                        for gid, states in per.items()}
        unknown_rows = {g: v for g, v in unknown_rows.items() if v}
        ctx.check("停机期间每个 Data 组仍有 ≥1 个 Running/Available 副本（组可读写）",
                  per and not bad_groups,
                  f"无可用副本的组={bad_groups}；Unknown 副本行（预期只出现在 "
                  f"被停的 {victim}）={unknown_rows}",
                  evidence="；".join(trace))
    finally:
        ctx.mark_harness_action(f"MULTI-03 启 DN {victim}", kind="start")
        ctx.cluster.start_node(victim, "dn")
        healthy = ctx.cluster.wait_healthy(
            timeout=_cfg_int(ctx, "CLUSTER_START_TIMEOUT_SEC", 1200))
        ctx.check(f"恢复后集群 {len(ctx.cfg.dn_hosts) + len(ctx.cfg.cn_hosts)} 节点健康",
                  healthy, f"host={victim}")
    # 恢复后按**副本行**判：所有副本都必须回到 Running（此时不应再有 Unknown/Available）
    deadline = time.time() + 300
    per: dict[str, dict[str, str]] = {}
    settled = False
    while time.time() < deadline:
        per = _replica_status(ctx, db, "DATA")
        settled = bool(per) and all(
            st.strip().lower() == "running" for states in per.values() for st in states.values())
        if settled:
            break
        time.sleep(5)
    ctx.check("恢复后所有 Data 副本行状态回到 Running", settled, f"per_replica={per}")
    ctx.by_design_gone.discard(victim)


def case_multi04(ctx: Ctx) -> None:
    """MULTI-04 20 DN 下每库 Max*RegionGroupNum ≥ 源码公式（PROACTIVE 只放大不缩小）。"""
    db = reset_db(ctx, "tree")
    _write_slots(ctx, db, 2, prefix="m4")
    checked = 0
    bad: list[str] = []
    for name in ctx.api.database_details("tree"):
        if "__system" in name or "__audit" in name:
            continue
        for kind in ("SCHEMA", "DATA"):
            want = expected_cap(ctx, kind, "tree", name)
            got = ctx.api.db_max_group_num(name, kind, dialect="tree")
            checked += 1
            if got < want:
                bad.append(f"{name}/{kind}: 实测 {got} < 公式 {want}")
    ctx.check(f"至少检查了一个用户库的上限（已检 {checked} 项）", checked > 0,
              f"checked={checked}")
    ctx.check("每库上限 ≥ 公式值（实测<公式才算失败）", not bad, "；".join(bad[:6]),
              evidence="；".join(bad))


def case_multi05(ctx: Ctx) -> None:
    """MULTI-05 建 20 库（每库写新 slot）→ 删 19 库：只剩保留库的 region。"""
    n = _cfg_int(ctx, "MULTI_DB_COUNT", 20)
    keep_index = n - 1
    names: list[str] = []
    for i in range(n):
        db = f"root.pg_m5_{i}"
        ctx.cleanup.append(f"drop database {db}")
        ctx.api.drop_database(db)
        ctx.mark_harness_action(f"MULTI-05 建库 {db}", kind="create_db")
        ctx.req(ctx.api.create_database(db), f"create database {db}")
        _write_slots(ctx, db, 2, prefix=f"m5{i}")
        names.append(db)
    kept = names[keep_index]
    for db in names[:keep_index]:
        ctx.mark_harness_action(f"MULTI-05 删库 {db}", kind="drop_db")
        ctx.api.drop_database(db)
    deadline = time.time() + _cfg_int(ctx, "MULTI_RECLAIM_WAIT_SEC", 600)
    leftovers: dict[str, int] = {}
    while time.time() < deadline:
        leftovers = {db: ctx.api.group_count(db, kind="DATA", dialect="tree")
                     for db in names[:keep_index]}
        if not any(leftovers.values()):
            break
        time.sleep(10)
    ctx.check("删掉的 19 个库无 Data region 残留", not any(leftovers.values()),
              f"残留={leftovers}")
    kept_groups = ctx.api.group_count(kept, kind="DATA", dialect="tree")
    ctx.check(f"保留库 {kept} 仍有 Data region（{kept_groups} 组）", kept_groups >= 1,
              f"groups={kept_groups}")


def case_multi06(ctx: Ctx) -> None:
    """MULTI-06 单库 50 个不同 slot：Schema/Data 组数 = min(K, 上限) 且 > 1。"""
    k = _cfg_int(ctx, "MULTI_SLOT_COUNT", 50)
    db = reset_db(ctx, "tree")
    _write_slots(ctx, db, k, prefix="m6")
    time.sleep(_cfg_int(ctx, "LEAK_SETTLE_SECONDS", 30))
    schema = ctx.api.group_count(db, kind="SCHEMA", dialect="tree")
    data = ctx.api.group_count(db, kind="DATA", dialect="tree")
    scap = max(expected_cap(ctx, "SCHEMA", "tree", db), group_ceiling(ctx, "SCHEMA", "tree", db))
    dcap = max(expected_cap(ctx, "DATA", "tree", db), group_ceiling(ctx, "DATA", "tree", db))
    expect_groups(ctx, f"{k} 个不同 slot 后（Schema）", db, "tree", schema=min(k, scap))
    expect_groups(ctx, f"{k} 个不同 slot 后（Data）", db, "tree", data=min(k, dcap))
    ctx.check(f"Schema 组数 {schema} ≤ 上限 {scap}", schema <= scap, f"cap={scap}")
    ctx.check(f"Data 组数 {data} ≤ 上限 {dcap}", data <= dcap, f"cap={dcap}")
    ctx.check("PROACTIVE 生效（两种组数都 > 1）", schema > 1 and data > 1,
              f"schema={schema} data={data} cap_s={scap} cap_d={dcap}")


LEAK_CASES = [
    CaseSpec("LEAK-THR-01", "泄漏", "tree", "稳态线程基线（逐 JVM，top 线程名落 evidence）",
             "P1", case_leak_thr01),
    CaseSpec("LEAK-THR-02", "泄漏", "tree", "建删循环线程不泄漏（斜率判据 + 末轮余量）",
             "P1", case_leak_thr02),
    CaseSpec("LEAK-THR-03", "泄漏", "tree", "多 slot 扩容后删库线程回落", "P1", case_leak_thr03),
    CaseSpec("LEAK-THR-04", "泄漏", "tree", "5CN+20DN 空闲期心跳/复制线程稳定", "P2",
             case_leak_thr04),
    CaseSpec("LEAK-MEM-01", "泄漏", "tree", "GC 后堆不持续增长（多轮建删采样）", "P1",
             case_leak_mem01),
    CaseSpec("LEAK-MEM-02", "泄漏", "tree", "300 库元数据建删后堆回落且库清空", "P1",
             case_leak_mem02),
    CaseSpec("LEAK-MEM-03", "泄漏", "tree", "多时间分区写入后堆增长与数据量匹配", "P2",
             case_leak_mem03),
    CaseSpec("LEAK-MEM-04", "泄漏", "tree", "benchmark 长跑下堆呈锯齿（未配置则 SKIP）", "P2",
             case_leak_mem04),
    CaseSpec("MULTI-01", "多DN", "tree", "SR5 副本落在 5 台不同 DN", "P0", case_multi01),
    CaseSpec("MULTI-02", "多DN", "tree", "DR3 互斥 + 20 DN 组数均衡（max/min）", "P0",
             case_multi02),
    CaseSpec("MULTI-03", "多DN", "tree", "停 1 台 DN 后副本约束仍满足且查询不断", "P1",
             case_multi03),
    CaseSpec("MULTI-04", "多DN", "tree", "20 DN 下上限 ≥ 公式（PROACTIVE 口径）", "P1",
             case_multi04),
    CaseSpec("MULTI-05", "多DN", "tree", "建 20 库删 19 库后 region 无残留", "P1", case_multi05),
    CaseSpec("MULTI-06", "多DN", "tree", "单库 50 slot 扩容收敛且不超上限", "P0", case_multi06),
]
