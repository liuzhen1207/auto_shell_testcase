#!/bin/bash
# ============================================================================
# probe_co41_dupdata.sh —— 复现 CO-41 的"停副本后聚合变大"，并把**原始行**拉出来看是否重复
#
# 目的：回答问题"count 变大是因为查询返回了重复记录，还是因为读到了另一份文件状态？"
# 做法：造一张与 CO-41 同构的表（dev TAG / v INT64 / o OBJECT），flush + 等 syncLag 归零，
#       然后逐副本停机，每次都用**同一句原始查询**把行拉全量，比对：
#         - 行数、去重后的 (dev,time) 数、重复次数
#         - 与基线的差集（多出来的是哪些行）
#
# 用法（在 99.80 上，compaction_skill 目录）：
#   cd /data/iotdb/autotest/compaction_skill
#   nohup bash tools/probe_co41_dupdata.sh --consensus IoTConsensusV2 > /tmp/probe_co41.out 2>&1 &
# 只读性质：只在自己新建的库 dbp1 上写数据，结束会停集群（与用例行为一致）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
. "$HERE/../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "probe_co41_dup_${DATA_CONSENSUS}"

DB=dbp1
TB=t1
DEVS=3
ROWS=40

raw_dump(){ local h=$1 out=$2
  sqt_node "$h" "select dev, time, v from $DB.$TB order by time;" 2>/dev/null | strip_echo > "$out"
  grep -cE '^\|' "$out" 2>/dev/null | tr -dc '0-9'
}
row_count(){ local h=$1
  sqt_node "$h" "select count(o) from $DB.$TB;" 2>/dev/null | strip_echo | table_rows | tail -1 | tr -dc '0-9'
}
analyze(){ local tag=$1 f=$2
  python3 - "$tag" "$f" <<'PY'
import sys, re, collections
tag, f = sys.argv[1], sys.argv[2]
rows = []
for line in open(f, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("|") or line.startswith("|dev") or line.startswith("+") or line.startswith("|Time"):
        continue
    cells = [c.strip() for c in line.strip("|").split("|")]
    if len(cells) < 2: continue
    rows.append((cells[0], cells[1]))   # (dev, time)
cnt = collections.Counter(rows)
total = len(rows)
uniq = len(cnt)
dups = {k: v for k, v in cnt.items() if v > 1}
print("  %-28s rows=%-5d uniq(dev,time)=%-5d dup_keys=%d max_rep=%d" % (tag, total, uniq, len(dups), max(cnt.values()) if cnt else 0))
if dups:
    sample = list(dups.items())[:3]
    for (d, t), n in sample:
        print("        dup: dev=%s time=%s ×%d" % (d, t, n))
PY
}

log "--- 0) 集群准备（V2；三类合并全开，便于造出多文件形态）---"
EXTRA_CONF="enable_seq_space_compaction=true,enable_unseq_space_compaction=true,enable_cross_space_compaction=true,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=1000" cmp_cluster_prepare

log "--- 1) 造库/表/数据（$DEVS 设备 × $ROWS 行，OBJECT 列）---"
sqt "create database $DB;" >/dev/null 2>&1
sqt "create table $DB.$TB (dev STRING TAG, v INT64 FIELD, o OBJECT FIELD);" >/dev/null 2>&1
BASE=$(( ($(date +%s) - 600) * 1000 ))
for d in $(seq 1 "$DEVS"); do
  stmts=(); vals=""
  for k in $(seq 1 "$ROWS"); do
    vals="$vals('d$d',$(( BASE + k * 10 )),$k,to_object(true,0,X'62')),"
  done
  stmts+=("insert into $DB.$TB(dev,time,v,o) values ${vals%,};")
  sql_lines_table "${stmts[@]}" >/dev/null 2>&1
done
sq "flush;" >/dev/null 2>&1
cmp_wait_close "$DB" 1 120 >/dev/null || warn "  close 事件未达 1"
log "--- 2) 等 syncLag 归零（与用例同一门禁）---"
read -r n bad <<<"$(sync_lag_scan)"; log "  syncLag series=$n nonzero=$bad"
if [ "${n:-0}" -gt 0 ] && [ "${bad:-1}" -eq 0 ]; then pass "  syncLag 已归零（series=$n）"; else warn "  syncLag 未归零（series=$n nonzero=$bad）"; fi

ARTD="$ART/dumps"; mkdir -p "$ARTD"
log "--- 3) 基线（三副本全在线）：count + 原始行 ---"
declare -A BASE_DUMP=()
for h in "${DN[@]}"; do
  c=$(row_count "$h"); f="$ARTD/base_${h##*.}.txt"; n=$(raw_dump "$h" "$f")
  BASE_DUMP[$h]=$f
  log "  [$h] count(o)=${c:-?} 原始行数=${n:-?}"
done
analyze "基线(.77)" "$ARTD/base_${DN[0]##*.}.txt"
BASEF=$ARTD/base_${DN[0]##*.}.txt

log "--- 4) 逐个停副本，用同一句查询拉原始行 ---"
for h in "${DN[@]}"; do
  log "  ==== 停 $h ===="
  sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true" >/dev/null 2>&1
  wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "  停 $h 后集群仍显示 Running"
  for on in "${DN[@]}"; do
    [ "$on" = "$h" ] && continue
    c=$(row_count "$on"); f="$ARTD/stop_${h##*.}_via_${on##*.}.txt"; n=$(raw_dump "$on" "$f")
    log "  停 ${h##*.} 经 ${on##*.}：count(o)=${c:-?} 原始行数=${n:-?} (dump=$f)"
    analyze "  停${h##*.}经${on##*.}" "$f"
    # 与基线的差集：多出来/少了哪些 (dev,time)
    python3 - "$BASEF" "$f" <<'PY'
import sys, collections
def load(p):
    s = collections.Counter()
    for line in open(p, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("|") or line.startswith("|dev") or line.startswith("+") or line.startswith("|Time"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) >= 2: s[(cells[0], cells[1])] += 1
    return s
a, b = load(sys.argv[1]), load(sys.argv[2])
extra = b - a; missing = a - b
print("        与基线比：多出 %d 个键 / 少 %d 个键" % (len(extra), len(missing)))
for k, v in list(extra.items())[:3]:
    print("          + dev=%s time=%s ×%d" % (k[0], k[1], v))
for k, v in list(missing.items())[:3]:
    print("          - dev=%s time=%s ×%d" % (k[0], k[1], v))
PY
  done
  sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}_${h##*.}.log 2>&1 </dev/null &" >/dev/null 2>&1
  wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || warn "  $h 未恢复 Running"
done

log "--- 5) 收尾 ---"
post_checks "select count(o) from $DB.$TB;" table
cmp_case_finish "" table ""
