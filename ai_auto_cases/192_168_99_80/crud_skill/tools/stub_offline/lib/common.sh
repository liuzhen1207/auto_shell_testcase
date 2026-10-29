#!/bin/bash
# ============================================================================
# 【纯桩 lib/common.sh】—— 只给 CR-14 的**离线干跑**用，**绝不连接任何集群**
#   实现 CR-14 用到的 lib 接口：
#     · 日志/断言（与真 lib 同语义：fail 计入 fail_flag 并写 v_warnMessage）
#     · SQL：转给 bin/fakecli.sh（假 CLI，见该文件）
#     · ssh/sshx：把命令在**本地"节点目录"**上执行（把假 DB_DIR 路径改写成节点目录）
#     · 集群生命周期：stop/clean/write_conf/start 只改桩状态（**不碰真集群**）
#     · 收尾三件套：check_sync_lag / consistency_check / check_logs（后者**逐字复刻**真 lib
#       含新钩子 CMP_ERR_PAT_CUSTOM / CMP_POSITIVE_EVIDENCE_FN 的语义）
#   行为开关：
#     STUB_MODE=ok        正常产品行为：SET 只改配置层，重启才生效（restart-only）
#               hotapply  SET 立即改运行期生效值（模拟"改配置不重启就生效"的坏行为）
#               norestart 重启不应用配置（模拟"重启后不生效"的坏行为）
#     STUB_STALE=1        load 后不更新 LastCache（模拟缓存陈旧）
# ============================================================================
STUB_ROOT="${STUB_ROOT:-/tmp/cr14_stub}"
STUB_NODES="$STUB_ROOT/nodes"
STUB_STATE="$STUB_ROOT/state"
STUB_MODE="${STUB_MODE:-ok}"
STUB_STALE="${STUB_STALE:-0}"
export STUB_ROOT STUB_NODES STUB_STATE STUB_MODE STUB_STALE
FAKE_DB_DIR="/data/iotdb/stub"          # 假 DB_DIR（sshx 会把它改写成节点目录）
mkdir -p "$STUB_STATE/batches" "$STUB_ROOT/results" "$STUB_ROOT/bin"
for n in 192.168.99.77 192.168.99.78 192.168.99.79; do
  mkdir -p "$STUB_NODES/$n/logs" "$STUB_NODES/$n/conf" "$STUB_NODES/$n/data/datanode/data/sequence"
  {
    printf '%s\n' 'last_cache_operation_on_load=UPDATE_NO_BLOB' 'cache_last_values_for_load=true' \
      'cache_last_values_memory_budget_in_byte=4194304' 'enable_last_cache=true'
  } > "$STUB_NODES/$n/conf/iotdb-system.properties"
  {
    printf '%s\n' \
      '2026-10-16 10:00:00,000 [main] INFO  o.a.i.d.s.StorageEngine - Storage engine is ready' \
      '2026-10-16 10:00:01,000 [pool-1] INFO  o.a.i.d.s.d.DataRegion - [Deletion] Deletion root.cr14.d1.** is written into 1 mod files' \
      '2026-10-16 10:00:02,000 [pool-2] INFO  o.a.i.d.d.l.LoadTsFileManager - Successfully auto load tsfile stub-1-1-0.tsfile (isGeneratedByPipe = false)'
  } > "$STUB_NODES/$n/logs/log_datanode_all.log"
done
# 运行期生效配置：**只有"重启"才会更新它** —— restart-only 语义的桩实现
printf '%s\n' 'last_cache_operation_on_load=UPDATE_NO_BLOB' 'cache_last_values_for_load=true' \
  'cache_last_values_memory_budget_in_byte=4194304' 'enable_last_cache=true' > "$STUB_STATE/runtime.properties"
: > "$STUB_STATE/rows.tsv"; : > "$STUB_STATE/cache.tsv"; : > "$STUB_STATE/pending.tsv"; : > "$STUB_STATE/loads.txt"
echo 0 > "$STUB_STATE/flush_counter"

# ---------------------------------------------------------------------------
# 环境加载
# ---------------------------------------------------------------------------
cmp_load_env(){
  local env_file="${1:-$STUB_ROOT/conf/env.conf}"
  [ -f "$env_file" ] && . "$env_file"
  DB_DIR="$FAKE_DB_DIR"
  CN_DB_DIR="$FAKE_DB_DIR"
  CLI_DIR="$STUB_ROOT/bin"
  CLI="$STUB_ROOT/bin/fakecli.sh"
  chmod +x "$CLI" 2>/dev/null || true
  read -ra CN <<<"$CN_NODES"
  read -ra DN <<<"$DN_NODES"
  QDN="${DN[0]}"
  CONSENSUS_CLASS="org.apache.iotdb.consensus.iot.IoTConsensus"
  export DB_DIR CN_DB_DIR CLI_DIR CLI QDN CONSENSUS_CLASS
}
cmp_parse_args(){ while [ $# -gt 0 ]; do case "$1" in --consensus) DATA_CONSENSUS="$2"; shift 2 ;; *) shift ;; esac; done; }
cmp_case_init(){
  CASE="$1"
  RUN_ID="$(date +%Y%m%d_%H%M%S)"
  OUTDIR="$STUB_ROOT/results"
  OUT="$OUTDIR/${CASE}_${RUN_ID}.out"
  ART="$OUTDIR/artifact_${CASE}_${RUN_ID}"
  mkdir -p "$OUTDIR" "$ART" "$ART/logs"
  : >"$OUT"
  fail_flag=0
  v_warnMessage=""
  start_epoch=$(date +%s)
  log "=== $CASE 开始 run_id=$RUN_ID（纯桩 STUB_MODE=$STUB_MODE STUB_STALE=$STUB_STALE）==="
}

# ---------------------------------------------------------------------------
# 日志 / 断言（与真 lib 同语义）
# ---------------------------------------------------------------------------
log(){  local m="[$(date '+%F %T')] $*"; printf '%s\n' "$m" >>"$OUT"; printf '%s\n' "$m"; }
note(){ v_warnMessage="${v_warnMessage}$*"; }
warn(){ note "$*"; log "WARN $*"; }
fail(){ fail_flag=$((fail_flag+1)); note "$*"; log "FAIL $*"; }
pass(){ log "PASS $*"; }
assert_contains(){ if printf '%s\n' "$2" | grep -qE "$3"; then pass "$1: 命中 /$3/"; else fail "$1: 未命中 /$3/"; fi; }
assert_not_contains(){ if printf '%s\n' "$2" | grep -qE "$3"; then fail "$1: 不应出现 /$3/"; else pass "$1: 未出现 /$3/"; fi; }
assert_eq(){ if [ "$2" = "$3" ]; then pass "$1: = $3"; else fail "$1: 实际=[$2] 期望=[$3]"; fi; }

# ---------------------------------------------------------------------------
# ssh / SQL
# ---------------------------------------------------------------------------
sshx(){ local h=$1; shift; local cmd="$*"
  bash -c "$(printf '%s' "$cmd" | sed "s#$FAKE_DB_DIR#$STUB_NODES/$h#g")"; }
ssh(){ local _opts=$1 target=$2; shift 2; local h="${target#*@}"; local cmd="$*"
  bash -c "$(printf '%s' "$cmd" | sed "s#$FAKE_DB_DIR#$STUB_NODES/$h#g")"; }
strip_echo(){ grep -vE '^[[:alnum:]_:]*DB>([[:space:]]|$)' | grep -vE '^[-+]+$'; }
data_rows(){ grep -E '^\|[0-9]{4}-[0-9]{2}-[0-9]{2}T'; }
table_rows(){ grep -E '^\|' | grep -vE '^\|[-+ ]+\|$' | tail -n +2; }
sq(){        timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 -e "$1" 2>&1; }
sq_node(){   timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$1"   -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 -e "$2" 2>&1; }
sqt(){       timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 3600 -e "$1" 2>&1; }
sqt_node(){  timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$1"   -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 3600 -e "$2" 2>&1; }
session_tree(){  timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 2>&1; }
session_table(){ session_tree; }
sql_lines_tree(){  printf '%s\n' "$@" | session_tree; }
sql_lines_table(){ printf '%s\n' "$@" | session_table; }
rows_of(){ printf '%s\n' "$1" | table_rows | sed -E 's/[[:space:]]+/ /g'; }
now_ms(){ date +%s%3N; }
scalar(){ printf '%s\n' "$1" | table_rows | head -1 | awk -F'|' '{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }
row_sum(){ printf '%s\n' "$1" | table_rows | head -1 | awk -F'|' '{s=0; for(i=2;i<NF;i++){v=$i; gsub(/[^0-9-]/,"",v); if(v!="")s+=v} print s}'; }
sum_over(){ local f=$1 s=0 h; for h in "${DN[@]}"; do s=$((s + $($f "$h"))); done; echo "${s:-0}"; }
norm_result(){ local txt=$1 r
  if printf '%s\n' "$txt" | grep -qiE 'IoTDBSQLException|Exception'; then
    printf '%s\n' "$txt" | grep -oiE 'Exception[^|]*' | head -1 | sed 's/^/ERROR:/'; return
  fi
  r=$(printf '%s\n' "$txt" | table_rows | sed -E 's/[[:space:]]+/ /g')
  if [ -z "$r" ]; then echo EMPTY; else printf '%s\n' "$r"; fi; }
query_result(){ local out; if [ "$2" = "table" ]; then out=$(sqt_node "$1" "$3"); else out=$(sq_node "$1" "$3"); fi; norm_result "$out"; }

# ---------------------------------------------------------------------------
# 集群生命周期（桩：只改状态，不启停任何东西）
# ---------------------------------------------------------------------------
stub_seed_logs(){ local n
  for n in 192.168.99.77 192.168.99.78 192.168.99.79; do
    mkdir -p "$STUB_NODES/$n/logs"
    {
      printf '%s\n' \
        '2026-10-16 10:00:00,000 [main] INFO  o.a.i.d.s.StorageEngine - Storage engine is ready' \
        '2026-10-16 10:00:01,000 [pool-1] INFO  o.a.i.d.s.d.DataRegion - [Deletion] Deletion root.cr14.d1.** is written into 1 mod files' \
        '2026-10-16 10:00:02,000 [pool-2] INFO  o.a.i.d.d.l.LoadTsFileManager - Successfully auto load tsfile stub-1-1-0.tsfile (isGeneratedByPipe = false)'
    } > "$STUB_NODES/$n/logs/log_datanode_all.log"
  done }
cluster_stop(){ log "--- 纯桩：停止集群（无副作用）---"; }
cluster_clean(){ log "--- 纯桩：清理 data/logs（只清桩目录）---"
  for n in $(ls "$STUB_NODES"); do rm -rf "$STUB_NODES/$n/data" "$STUB_NODES/$n/logs"; mkdir -p "$STUB_NODES/$n/data/datanode/data/sequence" "$STUB_NODES/$n/logs"; done
  stub_seed_logs
  : > "$STUB_STATE/rows.tsv"; : > "$STUB_STATE/cache.tsv"; : > "$STUB_STATE/pending.tsv"; }
apply_runtime_conf(){ local kv k v
  for kv in $(printf '%s' "${EXTRA_CONF:-}" | tr ',' ' '); do
    k="${kv%%=*}"; v="${kv#*=}"; [ -n "$k" ] || continue
    if grep -q "^${k}=" "$STUB_STATE/runtime.properties" 2>/dev/null; then
      sed -i -E "s#^${k}=.*#${k}=${v}#" "$STUB_STATE/runtime.properties"
    else
      printf '%s=%s\n' "$k" "$v" >> "$STUB_STATE/runtime.properties"
    fi
  done; }
cluster_write_conf(){ local h kv k v
  log "--- 纯桩：写配置 EXTRA_CONF=${EXTRA_CONF:-} ---"
  for kv in $(printf '%s' "${EXTRA_CONF:-}" | tr ',' ' '); do
    k="${kv%%=*}"; v="${kv#*=}"; [ -n "$k" ] || continue
    for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
      sed -i -E "/^${k}=/d" "$STUB_NODES/$h/conf/iotdb-system.properties"
      printf '%s=%s\n' "$k" "$v" >> "$STUB_NODES/$h/conf/iotdb-system.properties"
    done
  done
  if [ "$STUB_MODE" = norestart ]; then
    log "  [纯桩] STUB_MODE=norestart：本次重启**不应用**配置（运行期生效值保持旧值）"
  else
    apply_runtime_conf
  fi; }
cluster_start(){ log "--- 纯桩：启动集群（无副作用）---"; }
wait_cluster_ready(){ log "  纯桩：集群就绪 6/6"; return 0; }
cmp_cluster_prepare(){ log "--- 纯桩：集群准备（stop → clean → 写配置 → start）---"; cluster_stop; cluster_clean; cluster_write_conf; cluster_start; }

# ---------------------------------------------------------------------------
# 收尾三件套（check_logs 逐字复刻真 lib 的钩子语义）
# ---------------------------------------------------------------------------
check_sync_lag(){ log "--- 纯桩：sync lag（跳过）---"; pass "sync lag 已归零（桩）"; }
consistency_check(){ local sql=$1 dialect=${2:-tree} h base cur
  log "=== 纯桩：副本一致性校验（${dialect}）: $sql ==="
  base=$(query_result "${DN[0]}" "$dialect" "$sql")
  for h in "${DN[@]}"; do
    [ "$h" = "${DN[0]}" ] && continue
    cur=$(query_result "$h" "$dialect" "$sql")
    [ "$cur" = "$base" ] && pass "纯桩：$h 与基准一致" || fail "纯桩：$h 与基准不一致"
  done; }
check_logs(){
  local extra=${1:-} benpat="${BENIGN_PAT:-__none__}" pat h files n nodes benign evfn
  [ -n "${CMP_LOG_BENIGN_EXTRA:-}" ] && benpat="$benpat|$CMP_LOG_BENIGN_EXTRA"
  pat="$COMMON_ERR_PAT|$CMP_ERR_PAT${CMP_ERR_PAT_CUSTOM:+|$CMP_ERR_PAT_CUSTOM}${extra:+|$extra}"
  log "=== 纯桩：CN/DN 异常日志分析 ==="
  log "  纯桩：本次异常正则 = $pat"
  for role in confignode datanode; do
    if [ "$role" = confignode ]; then nodes=("${CN[@]}"); else nodes=("${DN[@]}"); fi
    for h in "${nodes[@]}"; do
      files=$(sshx "$h" "ls $DB_DIR/logs/*${role}*all*.log 2>/dev/null" 2>/dev/null | tr '\n' ' ')
      [ -z "$files" ] && { warn "$role $h 无日志文件"; continue; }
      benign=$(sshx "$h" "grep -hcE '$benpat' $files 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
      n=$(sshx "$h" "grep -hE '$pat' $files 2>/dev/null | grep -vcE '$benpat'" 2>/dev/null | tr -dc '0-9')
      if [ "${n:-0}" -gt 0 ]; then fail "$role $h 日志出现 $n 条异常"
      else pass "$role $h 日志无异常（已忽略 ${benign:-0} 条已知正常 INFO）"; fi
    done
  done
  evfn="${CMP_POSITIVE_EVIDENCE_FN:-}"
  if [ -n "$evfn" ]; then
    if declare -F "$evfn" >/dev/null 2>&1; then "$evfn"
    else warn "  CMP_POSITIVE_EVIDENCE_FN=$evfn 未定义 ⇒ 回退到默认（合并任务累计）正证据"; evfn=""; fi
  fi
  if [ -z "$evfn" ]; then
    local started finished
    started=$(sum_over cmp_start_cnt_all); finished=$(sum_over cmp_finish_cnt_all)
    log "  合并任务累计（全部 DN、全部库）：starts=${started:-0} finishes=${finished:-0}"
  fi; }
post_checks(){ local sql=$1 dialect=${2:-tree}
  log "--- 收尾检查 1/3：sync lag 归零 ---"; check_sync_lag || true
  if [ -n "$sql" ]; then log "--- 收尾检查 2/3：副本一致性 ---"; consistency_check "$sql" "$dialect"; fi
  log "--- 收尾检查 3/3：CN/DN 日志异常分析 ---"; check_logs; }
backup_logs(){ log "纯桩：跳过日志备份"; }
write_result(){ local r="FAIL" elapsed=$(( $(date +%s) - start_epoch ))
  [ "$fail_flag" -eq 0 ] && r="PASS"
  log "RESULT $r fail_flag=$fail_flag case=$CASE consensus=${CONSENSUS_CLASS##*.} build=$BUILD_TAG elapsed=${elapsed}s"
  log "v_warnMessage=${v_warnMessage:-<empty>}"; }
cmp_case_finish(){ local sql=$3 dialect=${2:-tree}
  if [ -n "$sql" ]; then consistency_check "$sql" "$dialect" || true; fi
  if [ "$fail_flag" -gt 0 ]; then backup_logs; fi
  cluster_stop; write_result; }
