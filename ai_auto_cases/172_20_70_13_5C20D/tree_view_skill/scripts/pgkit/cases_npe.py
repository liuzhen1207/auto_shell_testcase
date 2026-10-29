"""5C-NPE-01：IoTConsensusV2 下「pipe 进度表持有已销毁 region」导致的空指针回归用例。

背景（2026-10-21 在 master_1020_22f9710 上首次命中）
====================================================
* V2 用 Pipe 子系统把 TsFile 推给副本；`PipeTsFileEpochProgressIndexAndFlushManager`
  以 ``dataRegionId`` 为键维护"待关闭 TsFileProcessor"的进度表；
* ``drop database`` 后 DataRegion 已销毁，但进度表仍持有该 regionId 的条目；
* 下一轮 ``flushAllTimeoutTsFiles()`` 里
  ``StorageEngine.getDataRegion(new DataRegionId(regionId))`` 返回 null（源码
  ``StorageEngine.java:1014`` 就是 ``dataRegionMap.get(regionId)``），随后直接解引用：

  ``PipeTsFileEpochProgressIndexAndFlushManager.java:81`` → NullPointerException
  ``Cannot invoke "DataRegion.asyncCloseOneTsFileProcessor(TsFileResource)" because the
  return value of "StorageEngine.getDataRegion(DataRegionId)" is null``

* 该 NPE 被 ``PipeSubtask`` 一次重试掩盖（日志随后是 ``Successfully executed subtask ...
  after 1 retries``），因此表现为「线程/资源不回收」而不是写入失败。

用例口径
========
1. 只在 V2 上有意义：V1（IoTConsensus）不走 ``__consensus`` pipe，进度表恒空，命中必然为 0
   （这正好是对照组）。
2. 复现动作：反复「建库 → 写 N 个不同 slot → flush → 等一个 flush 间隔 → 删库」，然后
   **在最后一次删库之后再多等一个 flush 间隔**（触发点就是这一刻），最后扫 DN 日志。
3. 判定：
   * 命中 ≥1 次 ⇒ **FAIL**（缺陷仍在），并把每台 DN 的命中次数、首次时间、栈头写进 evidence；
   * 0 次且观测窗口足够（≥3 个 flush 间隔、≥8 轮）⇒ PASS（修复或不可复现）；
   * 0 次但窗口不足 ⇒ SKIP 并写明窗口（"没测到"不写成 PASS）。
"""
from __future__ import annotations

import re
import time

from .cases import CaseSpec, Ctx, reset_db
from .cases_leak import _cfg_int, _evidence, _write_slots

#: 命中特征：类名 / NullPointerException 描述里带 getDataRegion 的那一句
_PATTERNS = (
    r"PipeTsFileEpochProgressIndexAndFlushManager",
    r"getDataRegion\(org\.apache\.iotdb\.commons\.consensus\.DataRegionId\)\" is null",
)
_ANY = "|".join(_PATTERNS)


def _consensus_class(ctx: Ctx) -> str:
    """从 DN 的 conf 读实际生效的共识协议类（不依赖 conf 文件里怎么写的）。"""
    host = ctx.cfg.dn_hosts[0]
    res = ctx.ssh.run(
        host,
        f"grep -E '^data_region_consensus_protocol_class' "
        f"{ctx.cfg.get('DB_DIR')}/conf/iotdb-system.properties | tail -1",
        check=False, timeout=60)
    text = (res.out or "").strip()
    return text.split("=", 1)[1].strip() if "=" in text else ""


def _effective_flush_interval(ctx: Ctx) -> tuple[int, str]:
    """DN 日志里回读 ``pipeTsFileFlushIntervalSeconds is set to N``；读不到按默认 200s。"""
    host = ctx.cfg.dn_hosts[0]
    res = ctx.ssh.run(
        host,
        f"grep -a -oE 'pipeTsFileFlushIntervalSeconds is set to [0-9]+' "
        f"{ctx.cfg.get('DB_DIR')}/logs/log_datanode_all.log 2>/dev/null | tail -1",
        check=False, timeout=60)
    m = re.search(r"(\d+)", res.out or "")
    if m:
        return int(m.group(1)), "DN 日志回读 pipeTsFileFlushIntervalSeconds"
    return 200, "DN 日志未回读到该键 ⇒ 用产品默认 200s（3.33 分钟）"


def _scan_npe(ctx: Ctx, since: float, tag: str) -> dict[str, list[str]]:
    """逐台 DN 扫 NPE 命中行（只取 case 开始之后的日志）。"""
    since_text = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since))
    hits: dict[str, list[str]] = {}
    for host in ctx.cfg.dn_hosts:
        res = ctx.ssh.run(
            host,
            f"awk -v s='{since_text}' "
            f"'/^[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}/{{ts=substr($0,1,19)}} "
            f"ts>=s' {ctx.cfg.get('DB_DIR')}/logs/log_datanode_all.log 2>/dev/null "
            f"| grep -aE '{_ANY}' | head -8",
            check=False, timeout=180)
        lines = [l.strip() for l in (res.out or "").splitlines() if l.strip()]
        if lines:
            hits[host] = lines
    if hits:
        path = _evidence(ctx) / f"npe_hits_{tag}.txt"
        path.write_text(
            "\n".join(f"### {h}\n" + "\n".join(v) for h, v in hits.items()) + "\n",
            encoding="utf-8")
        ctx.note(f"  [{tag}] NPE 命中主机 {len(hits)}/{len(ctx.cfg.dn_hosts)}，"
                 f"明细={path}")
    return hits


def _loop(ctx: Ctx, deadline: float, interval: int, tag: str) -> tuple[int, float]:
    """反复建库→写 slot→flush→等→删库，直到截止时间或已命中 NPE。

    返回 ``(轮数, 最后一次删库的时刻)``。
    """
    rounds = 0
    last_drop = time.time()
    wait = max(5, min(30, interval))
    while time.time() < deadline:
        db = f"root.pg_npe_{tag}_{rounds}"
        ctx.cleanup.append(f"drop database {db}")
        ctx.api.drop_database(db)
        ctx.mark_harness_action(f"5C-NPE-01 建库 {db}", kind="create_db")
        ctx.req(ctx.api.create_database(db), f"create database {db}")
        _write_slots(ctx, db, _cfg_int(ctx, "NPE_SLOTS_PER_ROUND", 8), prefix=f"n{tag}{rounds}")
        ctx.api.flush()
        time.sleep(wait)
        ctx.mark_harness_action(f"5C-NPE-01 删库 {db}", kind="drop_db")
        ctx.api.drop_database(db)
        rounds += 1
        last_drop = time.time()
        # 删库后立刻探一次：命中即可提前结束，避免白等满窗口
        if rounds >= 3 and _scan_npe(ctx, ctx._case_started, tag):
            ctx.note(f"  第 {rounds} 轮后即命中，提前结束循环")
            break
        time.sleep(5)
    return rounds, last_drop


def case_5c_npe01_pipe_progress_npe(ctx: Ctx) -> None:
    """5C-NPE-01 V2：删库后 pipe 进度表仍持 regionId ⇒ flush 时空指针（回归用例）。"""
    klass = _consensus_class(ctx)
    interval, interval_src = _effective_flush_interval(ctx)
    is_v2 = "IoTConsensusV2" in klass
    ctx.note(f"  data_region_consensus_protocol_class={klass or '(读不到)'}")
    ctx.note(f"  TsFile flush 间隔={interval}s（{interval_src}）")
    # 观测窗口：至少 3 个 flush 间隔（覆盖"删库后还要再走一个间隔才触发"），
    # 且不少于 NPE_MIN_SECONDS；上限由 NPE_MAX_SECONDS 兜住。
    min_seconds = _cfg_int(ctx, "NPE_MIN_SECONDS", 420)
    max_seconds = _cfg_int(ctx, "NPE_MAX_SECONDS", 1800)
    window_target = max(min_seconds, 3 * interval + 60)
    window_target = min(window_target, max_seconds)
    ctx.note(f"  目标观测窗口={window_target}s（min={min_seconds}s, 3×interval+60, "
             f"上限={max_seconds}s）")

    started = time.time()
    deadline = started + window_target
    tag = "v2" if is_v2 else "v1"
    rounds, last_drop = _loop(ctx, deadline - interval - 30, interval, tag)
    # 关键等待：最后一次删库之后**再等一个 flush 间隔**，触发点就在这一刻
    tail = min(window_target, interval + 30)
    ctx.note(f"  {rounds} 轮后停止建删，最后删库在 "
             f"{time.strftime('%H:%M:%S', time.localtime(last_drop))}；再等 {tail}s 触发 flush")
    time.sleep(tail)
    elapsed = int(time.time() - started)
    hits = _scan_npe(ctx, started, tag)
    total = sum(len(v) for v in hits.values())

    ctx.check(f"运行期未出现 pipe 进度表空指针（{total} 次命中 / {len(hits)} 台 DN）",
              total == 0,
              f"协议={klass.rsplit('.', 1)[-1] or '?'}、轮数={rounds}、观测={elapsed}s、"
              f"flush 间隔={interval}s、命中主机={sorted(hits)}"
              + (f"；首条：{hits[sorted(hits)[0]][0][:400]}" if hits else ""),
              evidence=str(_evidence(ctx) / f"npe_hits_{tag}.txt") if hits else "")
    if total:
        return
    # 0 命中：只有窗口足够才判 PASS，否则 SKIP（"没测到"不等于"已修复"）
    enough = rounds >= _cfg_int(ctx, "NPE_MIN_ROUNDS", 8) and elapsed >= 3 * interval
    if enough:
        ctx.check(f"观测窗口足够（{rounds} 轮 / {elapsed}s ≥ 3×{interval}s），判定可复现性充分",
                  True, f"rounds={rounds} elapsed={elapsed}s")
    else:
        ctx.skip(f"未命中且窗口不足：rounds={rounds}（需 ≥8）、elapsed={elapsed}s"
                 f"（需 ≥{3 * interval}s）⇒ 不能据此判定已修复，请加大 NPE_MIN_SECONDS")


NPE_CASES = [
    CaseSpec("5C-NPE-01", "5C缺陷回归", "tree",
             "V2 删库后 pipe 进度表仍持 regionId ⇒ flush 空指针（PipeTsFileEpochProgressIndex…）",
             "P0", case_5c_npe01_pipe_progress_npe),
]
