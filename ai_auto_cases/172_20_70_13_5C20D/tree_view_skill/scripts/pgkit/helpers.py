"""Compaction machinery shared by the cases.

**移植说明**：本模块由 iotdb-compaction 技能机械移植而来，内容仍是 compaction
测试机制（TsFile 计数、合并日志采样、开关热切换、jstack）。PROACTIVE 骨架的
``cases.py`` 注册表为空，因此本模块当前**不被任何路径调用**；保留是为了对照与
后续替换（PROACTIVE 用例集的观测/采样辅助待实现）。

Everything the gate needs, as reusable helpers rather than inline shell:

* per-DataNode **TsFile counts per space** by listing the node's data dirs over ssh;
* **compaction progress** parsed from each DataNode's ``log_datanode_all.log``;
* **hot toggling** of the compaction switches between gate phases;
* **jstack** capture (FAIL only) counting threads parked in
  ``TsFileResource.writeLock``, plus the compaction log tail.

Log strings are taken verbatim from RC6
``iotdb-core/datanode/src/main/i18n/en/org/apache/iotdb/db/i18n/StorageEngineMessages.java``:

* :1032 ``"{}-{} [Compaction] {} InnerSpaceCompaction task starts with {} files, ..."``
* :1037 ``"{}-{} [Compaction] {} InnerSpaceCompaction task finishes successfully, ..."``
* :1053 ``"{}-{} [Compaction] SettleCompaction task starts with {} fully_dirty files ..."``
* :742  ``"[TTL] {}-{} Totally select {} all-outdated files and {} partial-outdated files."``

The ``{}-{}`` prefix is ``storageGroupName-dataRegionId`` (see
``InnerSpaceCompactionTask.java:242-243``), so a database name can be used as a
line filter.
"""

from __future__ import annotations

import json
import re
import shlex
import time
from pathlib import Path

#: live DataNode log name; the glob also matches rotated ``.log.gz`` files.
DN_LOG_NAME = "log_datanode_all.log"
DN_LOG_GLOB = "*datanode*all*.log*"

COMPACTION_START = "InnerSpaceCompaction task starts with"
COMPACTION_FINISH = "InnerSpaceCompaction task finishes successfully"
CROSS_START = "CrossSpaceCompaction task starts with"
CROSS_FINISH = "CrossSpaceCompaction task finishes successfully"
SETTLE_START = "SettleCompaction task starts with"
TTL_SELECT = "Totally select"

#: A thread is judged "blocked on the compaction write lock" when its stack
#: block holds both markers.  RC6 line: TsFileResource.java:860 (the RC6
#: verification report's jstack frames read :862 from the shipped class).
WRITE_LOCK_FRAME = "TsFileResource.writeLock"
WAIT_MARKER = "Object.wait"
COMPACTION_THREAD_MARKER = "IoTDB-Compaction-Worker"


# --------------------------------------------------------------------------- logs
def _counts_script(db_dir: str, db_filter: str = "") -> str:
    """Bash that counts each compaction marker across live + rotated DN logs."""
    db = shlex.quote(db_filter)
    return f"""
d={shlex.quote(db_dir)}
cd "$d/logs" 2>/dev/null || exit 0
count() {{
  pat="$1"; total=0
  for f in $(ls {DN_LOG_GLOB} 2>/dev/null || true); do
    [[ -f "$f" ]] || continue
    case "$f" in *.gz) reader=zcat ;; *) reader=cat ;; esac
    if [[ -n {db} ]]; then
      n=$($reader "$f" 2>/dev/null | grep -F "$pat" | grep -F {db} | wc -l)
    else
      n=$($reader "$f" 2>/dev/null | grep -F "$pat" | wc -l)
    fi
    total=$((total + n))
  done
  echo "$total"
}}
printf 'starts=%s\\n' "$(count {shlex.quote(COMPACTION_START)})"
printf 'finishes=%s\\n' "$(count {shlex.quote(COMPACTION_FINISH)})"
printf 'cross_starts=%s\\n' "$(count {shlex.quote(CROSS_START)})"
printf 'cross_finishes=%s\\n' "$(count {shlex.quote(CROSS_FINISH)})"
printf 'settle_starts=%s\\n' "$(count {shlex.quote(SETTLE_START)})"
printf 'ttl_selects=%s\\n' "$(count {shlex.quote(TTL_SELECT)})"
exit 0
"""


def compaction_counts(ssh, host: str, db_dir: str, db_filter: str = "") -> dict[str, int]:
    """Marker counts from one DataNode's logs; zeros when no log exists yet."""
    res = ssh.run_script(host, _counts_script(db_dir, db_filter), check=False, timeout=600)
    out: dict[str, int] = {}
    for line in (res.out or "").splitlines():
        if "=" in line:
            key, _, value = line.strip().partition("=")
            try:
                out[key] = int(value)
            except ValueError:
                continue
    for key in ("starts", "finishes", "cross_starts", "cross_finishes",
                "settle_starts", "ttl_selects"):
        out.setdefault(key, 0)
    return out


def compaction_totals(cfg, ssh, db_filter: str = "") -> tuple[dict[str, dict[str, int]], int, int]:
    """Per-host counts plus cluster totals of ``(finishes, starts)``."""
    per_host: dict[str, dict[str, int]] = {}
    finishes = starts = 0
    for host in cfg.dn_hosts:
        counts = compaction_counts(ssh, host, cfg.get("DB_DIR"), db_filter)
        per_host[host] = counts
        finishes += counts["finishes"]
        starts += counts["starts"]
    return per_host, finishes, starts


# ------------------------------------------------------------------------- TsFiles
def _tsfile_script(dirs: list[str]) -> str:
    pairs = " ".join(shlex.quote(d) for d in dirs)
    return f"""
for d in {pairs}; do
  [[ -d "$d" ]] || {{ printf 'MISSING\t%s\n' "$d"; continue; }}
  for space in sequence unsequence; do
    printf '%s/%s\t%s\n' "$d" "$space" "$(find "$d/$space" -type f -name '*.tsfile' 2>/dev/null | wc -l)"
  done
  printf '%s/object\t%s\n' "$d" "$(find "$d/object" -type f -name '*.bin' 2>/dev/null | wc -l)"
done
exit 0
"""


def tsfile_counts(ssh, host: str, dirs) -> dict:
    """``{sequence, unsequence, object, total, per_dir}`` for one DataNode.

    ``dirs`` 可以是单个路径或路径列表（双盘时为 2 个）；``per_dir`` 记录**每个盘**
    的 TsFile 数，用于证明数据真的分布在两块盘上。
    """
    if isinstance(dirs, str):
        dirs = [dirs]
    res = ssh.run_script(host, _tsfile_script(list(dirs)), check=False, timeout=300)
    out = {"sequence": 0, "unsequence": 0, "object": 0}
    per_dir: dict[str, dict[str, int]] = {d: {"sequence": 0, "unsequence": 0, "object": 0, "missing": 0}
                                          for d in dirs}
    for line in (res.out or "").splitlines():
        key, _, value = line.strip().partition("\t")
        if key == "MISSING":
            if value in per_dir:
                per_dir[value]["missing"] = 1
            continue
        path, _, space = key.rpartition("/")
        try:
            count = int(value)
        except ValueError:
            continue
        if space in out:
            out[space] += count
        if path in per_dir and space in per_dir[path]:
            per_dir[path][space] = count
    out["total"] = out["sequence"] + out["unsequence"]
    out["per_dir"] = per_dir
    return out


def all_tsfile_counts(cfg, ssh) -> dict[str, dict]:
    dirs = cfg.data_dirs if getattr(cfg, "two_disk", False) else [cfg.primary_data_dir]
    return {host: tsfile_counts(ssh, host, dirs) for host in cfg.dn_hosts}


def tsfile_total(counts: dict[str, dict[str, int]]) -> int:
    return sum(c["total"] for c in counts.values())


def write_tsfile_counts_tsv(case_dir: Path, counts: dict[str, dict[str, int]],
                            tag: str) -> Path:
    """Append one labelled block to ``evidence/tsfile_counts.tsv``."""
    evidence = case_dir / "evidence"
    evidence.mkdir(parents=True, exist_ok=True)
    path = case_dir / "tsfile_counts.tsv"
    lines = [f"# {tag}\t{time.strftime('%Y-%m-%d %H:%M:%S')}",
             "host\tsequence\tunsequence\tobject\ttotal"]
    for host, c in sorted(counts.items()):
        lines.append(f"{host}\t{c['sequence']}\t{c['unsequence']}\t{c['object']}\t{c['total']}")
    lines.append(f"TOTAL\t\t\t\t{tsfile_total(counts)}")
    per_dir_rows = []
    for host, c in sorted(counts.items()):
        for d, v in (c.get("per_dir") or {}).items():
            per_dir_rows.append(f"{host}\t{d}\t{v['sequence']}\t{v['unsequence']}\t{v['object']}\t"
                                f"{'MISSING' if v.get('missing') else 'ok'}")
    if per_dir_rows:
        lines.append("")
        lines.append("# per-dir (两块盘各自的 TsFile 数)")
        lines.append("host\tdir\tsequence\tunsequence\tobject\tstate")
        lines.extend(per_dir_rows)
    with path.open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    (evidence / path.name).write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
    return path


# ------------------------------------------------------------------- toggling
def compaction_on_values(cfg) -> dict[str, str]:
    """compaction 三开关的"开启值"——**遗留**：PROACTIVE 骨架没有对应 conf 键。

    ``cfg.compaction_knobs()`` 已随 config.py 的 PROACTIVE 化改名为
    ``cfg.region_group_knobs()``；PROACTIVE 的开关是
    ``schema_region_group_extension_policy`` / ``data_region_group_extension_policy``，
    没有 ``enable_*_space_compaction`` 三键，所以这里返回空字典。

    本函数及其下的 compaction 采样/jstack/日志机制是从 compaction 技能机械移植过来的
    **遗留机制**（当前用例注册表为空，不会被调用），待 PROACTIVE 用例集实现时替换。
    """
    knobs = cfg.region_group_knobs()
    return {k: knobs[k] for k in knobs if k.startswith("enable_")}


def set_compaction_enabled(ctx, enabled: bool) -> dict:
    """Turn the three compaction switches on or off, hot, and prove it landed.

    ``enable_seq_space_compaction`` / ``enable_unseq_space_compaction`` /
    ``enable_cross_space_compaction`` are ``effectiveMode: hot_reload`` in RC6
    (template :1741/:1746/:1751; hot readers at IoTDBDescriptor :2159/:2165/:2171),
    so the toggle is done with ``SET CONFIGURATION "key"="value"`` -- which both
    persists to ``iotdb-system.properties`` and calls ``loadHotModifiedProps``
    (ClusterConfigTaskExecutor.java:1626 -> StorageEngine.java:845).  No restart
    is needed; the conf file is written first anyway so a restart would agree.
    """
    on = compaction_on_values(ctx.cfg)
    target = (
        {k: "true" for k in on} if enabled
        else {k: "false" for k in on}
    )
    ctx.note(f"    compaction {'ON' if enabled else 'OFF'}: {target}")
    if hasattr(ctx, "mark_harness_action"):
        # 开关热加载会重建压缩线程池（CompactionWorker:67 线程中断）并重复注册
        # consensus 内存块；记录窗口，收尾③ 只在这个窗口内归因这些 WARN。
        ctx.mark_harness_action(f"compaction switches → {'ON' if enabled else 'OFF'}", pad=300)
    touched = ctx.props.write(target)
    entries = " ".join(f'"{k}"="{v}"' for k, v in target.items())
    outcome = ctx.api.run(f"set configuration {entries}")
    # Read back what the file says on every DataNode: SET CONFIGURATION persists,
    # so a mismatch means the call did not reach that node.
    readback = {host: ctx.props.read(host, keys=tuple(target)) for host in ctx.cfg.dn_hosts}
    mismatched = [h for h, values in readback.items()
                  if any(values.get(k) != v for k, v in target.items())]
    return {
        "ok": outcome.ok and not mismatched and len(touched) == len(ctx.cfg.dn_hosts),
        "touched": touched,
        "readback": readback,
        "mismatched": mismatched,
        "sql_ok": outcome.ok,
        "sql_output": outcome.output.strip()[:400],
    }


def physical_tsfile_bytes(cfg, ssh, db: str) -> int:
    """Total on-disk bytes of TsFiles whose path contains ``/<db>/``.

    Used by the statistics-correctness case to prove the reported SizeInBytes is
    bounded by the real physical size (the report measured 3636B reported vs
    5058B physical for one database).
    """
    total = 0
    for host in cfg.dn_hosts:
        script = f"""
total=0
for base in {shlex.quote(" ").join([]) if False else " ".join(shlex.quote(d) for d in (cfg.data_dirs if getattr(cfg, "two_disk", False) else [cfg.primary_data_dir]))}; do
  [[ -d "$base" ]] || continue
  n=$(find "$base" -type f -name '*.tsfile' -path '*{db}*' -printf '%s\\n' 2>/dev/null | awk '{{s+=$1}} END {{print s+0}}')
  total=$((total + n))
done
printf '%s\\n' "$total"
exit 0
"""
        res = ssh.run_script(host, script, check=False, timeout=300)
        for line in (res.out or "").splitlines():
            try:
                total += int(line.strip() or 0)
            except ValueError:
                continue
    return total


def set_knobs(ctx, updates: dict[str, str]) -> dict:
    """Set arbitrary compaction knobs hot, writing the file first.

    Only ``HOT_RELOAD_KEYS`` take effect without a restart; a caller that needs
    ``compaction_schedule_interval_in_ms`` must restart, which this skill does
    only in ``prepare``/``deploy`` (the schedule is never toggled at runtime).
    """
    ctx.note(f"    set knobs {updates}")
    touched = ctx.props.write(updates)
    entries = " ".join(f'"{k}"="{v}"' for k, v in updates.items())
    outcome = ctx.api.run(f"set configuration {entries}")
    readback = {host: ctx.props.read(host, keys=tuple(updates)) for host in ctx.cfg.dn_hosts}
    mismatched = [h for h, values in readback.items()
                  if any(values.get(k) != v for k, v in updates.items())]
    return {"ok": outcome.ok and not mismatched, "touched": touched,
            "readback": readback, "mismatched": mismatched,
            "sql_ok": outcome.ok, "sql_output": outcome.output.strip()[:400]}


# ------------------------------------------------------------------- sampling
def sample_progress(ctx, db_filter: str, seconds: int, interval: int,
                    baseline: dict | None = None) -> dict:
    """Sample finish counts + TsFile totals for ``seconds``.

    Returns ``{"samples": [...], "finish_end", "finish_delta", "tsfile_end",
    "tsfile_delta", "worst"}``.  Never raises: a failed sample becomes a row
    with an error string so the evidence file still shows what happened.
    """
    samples: list[dict] = []
    deadline = time.time() + max(1, seconds)
    first_finish = baseline["finishes"] if baseline else None
    first_tsfile = baseline["tsfile_total"] if baseline else None
    last: dict = {"finishes": first_finish, "tsfile_total": first_tsfile}
    while True:
        try:
            per_host, finishes, _starts = compaction_totals(ctx.cfg, ctx.ssh, db_filter)
            counts = all_tsfile_counts(ctx.cfg, ctx.ssh)
            total = tsfile_total(counts)
            last = {"finishes": finishes, "tsfile_total": total}
            samples.append({
                "at": time.strftime("%H:%M:%S"),
                "finishes": finishes,
                "tsfile_total": total,
                "per_host_finishes": {h: c["finishes"] for h, c in per_host.items()},
                "per_host_tsfiles": {h: c["total"] for h, c in counts.items()},
            })
            ctx.note(f"    采样 finish={finishes} tsfile={total} "
                     f"(逐节点 tsfile=" +
                     " ".join(f"{h.split('.')[-1]}={c['total']}" for h, c in counts.items()) + ")")
        except Exception as exc:  # noqa: BLE001 - a sample must never abort the gate
            samples.append({"at": time.strftime("%H:%M:%S"), "error": str(exc)})
            ctx.note(f"    采样失败: {exc}")
        if time.time() >= deadline:
            break
        time.sleep(max(1, interval))

    finish_end = last.get("finishes")
    tsfile_end = last.get("tsfile_total")
    return {
        "samples": samples,
        "finish_baseline": first_finish,
        "finish_end": finish_end,
        "finish_delta": (finish_end - first_finish)
        if finish_end is not None and first_finish is not None else None,
        "tsfile_baseline": first_tsfile,
        "tsfile_end": tsfile_end,
        "tsfile_delta": (tsfile_end - first_tsfile)
        if tsfile_end is not None and first_tsfile is not None else None,
        "worst": max((s.get("finishes", 0) or 0) for s in samples) if samples else None,
    }


# --------------------------------------------------------------- jstack (FAIL only)
def parse_blocked_threads(jstack_text: str) -> tuple[int, list[str]]:
    """Count thread blocks holding both the writeLock frame and a wait.

    A jstack thread block starts at a ``"name" ...`` line and runs to the next
    blank line, so frames are attributed to the thread that owns them.  Rows
    that mention the compaction worker name are returned as evidence verbatim.
    """
    blocked = 0
    evidence: list[str] = []
    block: list[str] = []

    def flush() -> None:
        nonlocal blocked
        if not block:
            return
        text = "\n".join(block)
        if WRITE_LOCK_FRAME in text and WAIT_MARKER in text:
            blocked += 1
            header = block[0].strip()
            frame = next((ln.strip() for ln in block if WRITE_LOCK_FRAME in ln), "")
            evidence.append(f"{header}\n    {frame}")
        block.clear()

    for line in jstack_text.splitlines():
        if line.strip():
            block.append(line)
        else:
            flush()
    flush()
    return blocked, evidence


def jstack_capture(ctx, label: str) -> dict:
    """Dump every DataNode's JVM stacks and count writeLock-blocked threads.

    FAIL-only evidence: writes ``jstack_<host>.txt`` for each node and a
    ``jstack_summary.txt`` that states the total and shows the matching stacks.
    """
    db_dir = ctx.cfg.get("DB_DIR")
    per_host: dict[str, int] = {}
    failures: dict[str, str] = {}
    blocks: list[str] = []
    for host in ctx.cfg.dn_hosts:
        script = f"""
pid=$(sudo -n jps -l 2>/dev/null | grep -i datanode | grep -v Jps | awk '{{print $1}}' | head -1)
[[ -z "$pid" ]] && pid=$(jps -l 2>/dev/null | grep -i datanode | grep -v Jps | awk '{{print $1}}' | head -1)
[[ -z "$pid" ]] && {{ echo "NO_DATANODE_PID" ; exit 0; }}
(sudo -n jstack "$pid" 2>/dev/null || jstack "$pid" 2>/dev/null) || true
exit 0
"""
        res = ctx.ssh.run_script(host, script, check=False, timeout=180)
        text = res.out or ""
        (ctx.case_dir / f"jstack_{host.replace('.', '_')}.txt").write_text(text, encoding="utf-8")
        if "NO_DATANODE_PID" in text and WRITE_LOCK_FRAME not in text:
            failures[host] = "no DataNode JVM found for jstack"
            per_host[host] = 0
            continue
        blocked, rows = parse_blocked_threads(text)
        per_host[host] = blocked
        for row in rows:
            blocks.append(f"--- {host} ---\n{row}")
    total = sum(per_host.values())
    summary = [
        f"jstack writeLock-blocked compaction threads ({label})",
        f"total={total}",
        "per host: " + ", ".join(f"{h}={n}" for h, n in per_host.items()),
    ]
    if failures:
        summary.append("capture problems: " + "; ".join(f"{h}: {v}" for h, v in failures.items()))
    summary.append("")
    summary.append("\n\n".join(blocks) if blocks
                   else "no thread held TsFileResource.writeLock in Object.wait()")
    (ctx.case_dir / "jstack_summary.txt").write_text("\n".join(summary) + "\n", encoding="utf-8")
    return {"total": total, "per_host": per_host, "failures": failures,
            "path": str(ctx.case_dir / "jstack_summary.txt")}


def compaction_tail(ctx, lines: int = 200) -> Path:
    """Tail each DataNode's compaction log into ``compaction_tail.log``."""
    path = ctx.case_dir / "compaction_tail.log"
    db_dir = ctx.cfg.get("DB_DIR")
    chunks: list[str] = []
    for host in ctx.cfg.dn_hosts:
        script = f"""
d={shlex.quote(db_dir)}
f="$d/logs/{DN_LOG_NAME}"
[[ -f "$f" ]] || {{ echo "(no {DN_LOG_NAME} on {host})"; exit 0; }}
grep -E 'Compaction|\\[TTL\\]' "$f" | tail -n {int(lines)}
exit 0
"""
        res = ctx.ssh.run_script(host, script, check=False, timeout=180)
        chunks.append(f"===== {host} =====")
        chunks.append(res.out.rstrip() or "(no compaction lines)")
    path.write_text("\n".join(chunks) + "\n", encoding="utf-8")
    (ctx.case_dir / "evidence" / "compaction_tail.log").write_text(
        path.read_text(encoding="utf-8"), encoding="utf-8")
    return path


# ------------------------------------------------------------------- small utils
def num(value: str) -> float:
    """Parse an IoTDB numeric cell.

    The table model prints aggregates as double (``1698.0``), and the report's
    §4.4 trap 3 is explicit: use awk ``+0`` semantics, never "strip non-digits"
    (which turns 1698.0 into 16980).  Handles thousands separators and blanks.
    """
    text = (value or "").strip().replace(",", "")
    if not text or text.upper() in {"NULL", "NONE"}:
        return 0.0
    match = re.search(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?", text)
    return float(match.group(0)) if match else 0.0


def write_json(path: Path, payload: dict) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path
