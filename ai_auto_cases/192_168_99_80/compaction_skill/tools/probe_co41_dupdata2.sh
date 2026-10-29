#!/bin/bash
# ============================================================================
# probe_co41_dupdata2.sh —— 复现 CO-41 A 相（OBJECT + TTL 清理），停副本后把**原始行**拉出来：
#   ① 有没有重复的 (dev,time)？  ② 多出来的到底是"旧点复活（未清理副本）"还是"新点重复"？
#
# 依赖：compaction_skill/lib（集群生命周期、syncLag 门禁、CLI 封装）
# 用法（在 99.80 上）：
#   cd /data/iotdb/autotest/compaction_skill
#   V_TESTDB=v20121rc8_1016_ebaf9da BUILD_TAG=v20121rc8_1016_ebaf9da \
#     setsid nohup bash tools/probe_co41_dupdata2.sh --consensus IoTConsensusV2 > /tmp/probe_co41b.log 2>&1 &
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
. "$HERE/../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "probe_co41b_${DATA_CONSENSUS}"

DB=dbp2
TB=t1
ROWS=${P2_ROWS:-40}
OLD_MS=${P2_OLD_MS:-900000}
LIVE_MS=${P2_LIVE_MS:-10000}
WIN=${P2_WIN:-150}

nowms(){ date +%s%3N; }
qcount(){ local h=$1; sqt_node "$h" "select count(o) from $DB.$TB;" 2>/dev/null | strip_echo | table_rows | tail -1 | tr -dc '0-9'; }
qdump(){ local h=$1 f=$2
  sqt_node "$h" "select dev, time, v from $DB.$TB order by time;" 2>/dev/null | strip_echo > "$f"
  printf '%s' "$f"; }

# 分析：行数 / 重复键 / 与基线差集（并判定差集里是"旧点"还是"新点"）
p2_analyze(){ local tag=$1 base=$2 cur=$3 livebase=$4
  python3 - "$tag" "$base" "$cur" "$livebase" <<'PY'
import sys, collections
tag, basef, curf, live = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
def load(p):
    s = collections.Counter()
    for line in open(p, encoding="utf-8", errors="replace"):
        t = line.strip()
        if not t.startswith("|") or t.startswith("|dev") or t.startswith("+"): continue
        c = [x.strip() for x in t.strip("|").split("|")]
        if len(c) >= 3 and c[1].lstrip("-").isdigit():
            s[(c[0], int(c[1]))] += 1
    return s
a, b = (load(basef) if basef != "-" else collections.Counter()), load(curf)
cnt = b
dups = {k: v for k, v in cnt.items() if v > 1}
print("  %-30s rows=%-5d uniq=%-5d dup_keys=%-3d max_rep=%d" % (tag, sum(cnt.values()), len(cnt), len(dups), max(cnt.values()) if cnt else 0))
for (d, t), n in list(dups.items())[:3]:
    print("        dup: dev=%s time=%s ×%d" % (d, t, n))
if basef != "-":
    extra, missing = cnt - a, a - cnt
    old = [k for k in extra if k[1] < live]
    new = [k for k in extra if k[1] >= live]
    print("        与基线比：多出 %d 键（旧点 %d / 新点 %d）、少 %d 键" % (len(extra), len(old), len(new), len(missing)))
    for k in old[:2]: print("          + 旧点 dev=%s time=%s" % k)
    for k in new[:2]: print("          + 新点 dev=%s time=%s" % k)
    for k in list(missing)[:2]: print("          - dev=%s time=%s" % k)
PY
}

log "--- 0) 集群准备（V2；三类合并全开，让 settle 有机会删整文件）---"
EXTRA_CONF="enable_seq_space_compaction=true,enable_unseq_space_compaction=true,enable_cross_space_compaction=true,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=1000" cmp_cluster_prepare
log "  build=$V_TESTDB consensus=$DATA_CONSENSUS"

log "--- 1) 建表 + 造 CO-41 同构场景（d1 = 旧+新混排，d2 = 整文件旧点）---"
sqt "create database $DB;" >/dev/null 2>&1
sqt "create table $DB.$TB (dev STRING TAG, v INT64 FIELD, o OBJECT FIELD);" >/dev/null 2>&1
NOW=$(nowms); OLD_BASE=$(( NOW - OLD_MS )); LIVE_BASE=$(( NOW - LIVE_MS ))
mkvals(){ local dev=$1 base=$2 n=$3 v=""
  for k in $(seq 1 "$n"); do v="$v('$dev',$(( base + k * 10 )),$k,to_object(true,0,X'62')),"; done; printf '%s' "${v%,}"; }
sql_lines_table "insert into $DB.$TB(dev,time,v,o) values $(mkvals d1 "$OLD_BASE" "$ROWS");" >/dev/null 2>&1
sql_lines_table "insert into $DB.$TB(dev,time,v,o) values $(mkvals d1 "$LIVE_BASE" "$ROWS");" >/dev/null 2>&1
sq "flush;" >/dev/null 2>&1; sleep 5
sql_lines_table "insert into $DB.$TB(dev,time,v,o) values $(mkvals d2 "$OLD_BASE" "$ROWS");" >/dev/null 2>&1
sq "flush;" >/dev/null 2>&1
cmp_wait_close "$DB" 2 120 >/dev/null || warn "  close 事件未达 2"
R0=$(qcount "${DN[0]}"); log "  TTL 设置前 count(o)=$R0（期望 $(( ROWS * 3 ))）"

log "--- 2) 设动态 TTL（旧点必过期、新点存活），等 object 清理 + settle ---"
TTL=$(( $(nowms) - LIVE_BASE + (WIN + 180) * 1000 ))
out=$(sqt "alter table $DB.$TB set properties ttl=$TTL;"); log "  ALTER ttl=$TTL → $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
read -r sn sbad <<<"$(sync_lag_scan)"; log "  syncLag series=$sn nonzero=$sbad"
sleep "$WIN"
log "  TTL 窗口结束，count(o)=$(qcount "${DN[0]}")"

log "--- 3) TTL 复位 INF（旧行是否复活取决于各副本清理进度）---"
sqt "alter table $DB.$TB set properties ttl=9223372036854775807;" >/dev/null 2>&1
sleep 10
ARTD="$ART/dumps"; mkdir -p "$ARTD"
BASE_F=""
for h in "${DN[@]}"; do
  c=$(qcount "$h"); f=$(qdump "$h" "$ARTD/base_${h##*.}.txt")
  log "  基线: 经 ${h##*.} count(o)=${c:-?}（原始行文件 $f）"
  p2_analyze "基线(经${h##*.})" - "$f" "$LIVE_BASE"
  [ -z "$BASE_F" ] && BASE_F=$f
done

log "--- 4) 逐个停副本：同一句查询拉原始行，看重复 vs 旧点复活 ---"
for h in "${DN[@]}"; do
  log "  ==== 停 ${h##*.} ===="
  sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true" >/dev/null 2>&1
  wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "  停 ${h##*.} 后集群仍显示 Running"
  for on in "${DN[@]}"; do
    [ "$on" = "$h" ] && continue
    c=$(qcount "$on"); f=$(qdump "$on" "$ARTD/stop${h##*.}_via_${on##*.}.txt")
    log "  停 ${h##*.} 经 ${on##*.}：count(o)=${c:-?}"
    p2_analyze "停${h##*.}经${on##*.}" "$BASE_F" "$f" "$LIVE_BASE"
  done
  sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}_${h##*.}.log 2>&1 </dev/null &" >/dev/null 2>&1
  wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || warn "  ${h##*.} 未恢复 Running"
done

log "--- 5) 收尾 ---"
post_checks "select count(o) from $DB.$TB;" table
cmp_case_finish "" table ""
