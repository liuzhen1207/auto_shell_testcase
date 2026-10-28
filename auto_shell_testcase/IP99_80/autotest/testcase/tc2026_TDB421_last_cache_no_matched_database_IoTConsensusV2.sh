#!/bin/bash
# ============================================================================
# tc2026 TDB-421 复现用例：LAST 查询污染设备 schema 缓存导致
#                    "No matched database. Please check the path ..."
#
# 场景（来自 TDB-421 工单）：
#   1) 设备所属数据库 / series partition slot 没有数据分区时，规划器返回含
#      NOT_ASSIGNED（regionId=null 的 TRegionReplicaSet 占位符）的列表，而不是空列表；
#   2) LAST 扫描节点没被裁剪，带着 NOT_ASSIGNED 进入执行计划，该 Fragment 被安排到本地
#      QueryExecutor，用 VirtualDataRegion 执行；
#   3) 初始化 LAST 算子时用虚拟 Region 的 root.__virtual 调 declareLastCache()，
#      设备 schema 缓存为空且允许更新 last cache 时，就把 root.__virtual 这个错误库名写了进去；
#   4) 之后命中被污染缓存的精确查询，SchemaTree 的 database 只剩 root.__virtual，
#      分析器 getBelongedDatabase(真实路径) 前缀匹配失败，抛
#      SemanticException: No matched database. Please check the path ...
#   5) 还需要两个条件：同一条 LAST 查询里至少有一个其他设备有数据分区；
#      污染与后续精确查询发生在同一个 DataNode 的缓存上。
#
# 前提：enable_last_cache=true；所有 SQL 用同一个直连 DataNode 的会话执行；
#       CLEAR CACHE 之后不要先做精确查询（会回填正确 database，掩盖问题）。
#
# 预期（修复后）：混合 LAST 查询只返回 root.repro_has_partition.d1.s1；
#                之后对 root.repro_no_partition.d1008 / d1009 的精确查询返回空集、不报错。
# 若出现 "No matched database. Please check the path <device>" 即缺陷复现，用例判 FAIL。
#
# 集群：3C3D，SchemaRegion 与 DataRegion 均 3 副本。
# 本文件与 ...IoTConsensusV2.sh 的唯一区别就是下面这一行 CONSENSUS_CLASS。
# ============================================================================
set -uo pipefail

CONSENSUS_CLASS="org.apache.iotdb.consensus.iot.IoTConsensusV2"

# ---------------------------------------------------------------------------
# 路径与配置
# ---------------------------------------------------------------------------
BASE=/data/iotdb/autotest
cur_dir=$(cd "$(dirname "$0")" && pwd)
CONF=$BASE/conf/test.conf
cfg(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$CONF"; }
os_user_name=$(cfg os_user_name); os_user_name=${os_user_name:-root}
db_user_name=$(cfg db_user_name); db_user_name=${db_user_name:-root}
root_pw=$(cfg root_pw); root_pw=${root_pw:-TimechoDB@2021}
testdb=$(cfg v_testdb)
db_parent=$(cfg v_db_parent_dir); db_parent=${db_parent:-/data/iotdb}
shell_parent=$(cfg v_shell_client_db_parent_dir); shell_parent=${shell_parent:-$db_parent}
cluster_id=$(cfg CLUSTER_NAME); cluster_id=${cluster_id:-timecho}
db_dir=$db_parent/$testdb
cli_dir=$shell_parent/$testdb
CLI=$cli_dir/sbin/start-cli.sh

# 框架约定：reset_conf.sh / backup_cluster_logs.sh 读的是不带后缀的节点清单
cp -rfp "$BASE/conf/confignode_3c.txt" "$BASE/conf/confignode.txt"
cp -rfp "$BASE/conf/datanode_3d.txt"   "$BASE/conf/datanode.txt"
mapfile -t CN < <(awk 'NF && !/^#/ {print $1}' "$BASE/conf/confignode_3c.txt")
mapfile -t DN < <(awk 'NF && !/^#/ {print $1}' "$BASE/conf/datanode_3d.txt")
Q=${DN[0]}                      # 所有复现 SQL 都直连这一个 DataNode

CASE=$(basename "$0" .sh)
RUN_ID=$(date +%Y%m%d_%H%M%S)
OUTDIR=$cur_dir/tdb421_no_matched_database_results
OUT=$OUTDIR/${CASE}_${RUN_ID}.out
ART=$OUTDIR/artifact_${RUN_ID}
mkdir -p "$OUTDIR" "$ART"; : > "$OUT"

# 复现用库与设备
DB_HAS=root.repro_has_partition          # 有数据分区
DB_NOP=root.repro_no_partition           # 没有数据分区
DEV_TREE=${DB_NOP}.d1008                 # 普通设备
DEV_ALIGNED=${DB_NOP}.d1009              # 对齐设备

# ---------------------------------------------------------------------------
# 可调参数
# ---------------------------------------------------------------------------
SYNC_TIMEOUT_SEC=${SYNC_TIMEOUT_SEC:-600}
SYNC_STABLE_CHECKS=${SYNC_STABLE_CHECKS:-3}
SESSION_TIMEOUT_SEC=${SESSION_TIMEOUT_SEC:-900}
DN_DOWN_WAIT_SEC=${DN_DOWN_WAIT_SEC:-180}
DN_RECOVER_WAIT_SEC=${DN_RECOVER_WAIT_SEC:-300}
LOG_BACKUP=${LOG_BACKUP:-1}

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
fail_flag=0
v_warnMessage=""
start_epoch=$(date +%s)

log(){  local m="[$(date '+%F %T')] $*"; printf '%s\n' "$m" >>"$OUT"; printf '%s\n' "$m"; }
note(){ v_warnMessage="${v_warnMessage}$*"; }
warn(){ note "$*"; log "WARN $*"; }
fail(){ fail_flag=$((fail_flag+1)); note "$*"; log "FAIL $*"; }

sshx(){ local h=$1; shift; ssh -n -o BatchMode=yes -o ConnectTimeout=15 "$os_user_name@$h" "$@"; }
cli(){ "$CLI" -h "$Q" -u "$db_user_name" -pw "$root_pw" -e "$1" 2>&1; }
cli_node(){ "$CLI" -h "$1" -u "$db_user_name" -pw "$root_pw" -e "$2" 2>&1; }
dn_state(){ cli "show cluster;" 2>/dev/null | awk -F'|' -v ip="$1" '{gsub(/[[:space:]]/,"",$3);gsub(/[[:space:]]/,"",$4);gsub(/[[:space:]]/,"",$5)} $3=="DataNode" && $5==ip {print $4; exit}'; }
wait_dn(){ local ip=$1 want=$2 deadline=$(( $(date +%s) + $3 )) st
  while (( $(date +%s) < deadline )); do
    st=$(dn_state "$ip")
    [[ $want == running    && $st == "Running" ]] && return 0
    [[ $want == notrunning && $st != "Running" ]] && return 0
    sleep 3
  done
  return 1
}
# 去掉 CLI 的提示回显行（形如 "TimechoDB> SELECT ...;"）与分隔线，只留结果
strip_echo(){ grep -vE '^[[:alnum:]_]*DB>[[:space:]]' | grep -vE '^[-+]+$'; }
# 归一化单条查询结果：报错 -> ERROR 标记；无数据 -> EMPTY；否则数据行
norm_q(){
  local txt=$1 rows
  if printf '%s\n' "$txt" | grep -qi 'No matched database'; then echo "ERROR:No matched database"; return; fi
  rows=$(printf '%s\n' "$txt" | grep -E '^\|' | grep -vE '^\|[-+ ]+\|$' | tail -n +2 | sed -E 's/[[:space:]]+/ /g')
  if [ -z "$rows" ]; then echo "EMPTY"; else printf '%s\n' "$rows"; fi
}

# 同一个直连 DataNode 的单个 CLI 会话里按顺序执行多条 SQL（管道喂入 stdin）
session(){
  local s
  for s in "$@"; do printf '%s\n' "$s"; done \
    | timeout "$SESSION_TIMEOUT_SEC" "$CLI" -h "$Q" -u "$db_user_name" -pw "$root_pw" -timeout 3600 2>&1
}

# ---------------------------------------------------------------------------
# 1) 写集群参数（IP / 3 副本 / 共识协议 / last cache）
# ---------------------------------------------------------------------------
set_conf(){
  local h=$1
  sshx "$h" "python3 - '$db_dir/conf/iotdb-system.properties' '$h' '${CN[0]}' '$CONSENSUS_CLASS' <<'PY'
import sys
f,ip,seed,cons=sys.argv[1:]
vals={
 'cn_seed_config_node':seed+':10710','dn_seed_config_node':seed+':10710',
 'cn_internal_address':ip,'cn_internal_port':'10710','cn_consensus_port':'10720',
 'dn_rpc_address':ip,'dn_rpc_port':'6667','dn_internal_address':ip,'dn_internal_port':'10730',
 'dn_mpp_data_exchange_port':'10740','dn_schema_region_consensus_port':'10750',
 'dn_data_region_consensus_port':'10760',
 'schema_replication_factor':'3','data_replication_factor':'3',
 'cluster_name':'timecho','data_region_consensus_protocol_class':cons,
 'cn_metric_reporter_list':'PROMETHEUS','dn_metric_reporter_list':'PROMETHEUS',
 'cn_metric_prometheus_reporter_port':'9091','dn_metric_prometheus_reporter_port':'9092',
 # 本用例前提：last cache 必须开启
 'enable_last_cache':'true'}
lines=open(f).read().splitlines(); out=[]
for line in lines:
 k=line.split('=',1)[0].strip() if '=' in line and not line.lstrip().startswith('#') else ''
 if k in vals: out.append(k+'='+vals.pop(k))
 else: out.append(line)
out += [k+'='+v for k,v in vals.items()]
open(f,'w').write('\n'.join(out)+'\n')
PY" || { fail "写配置失败: $h"; return 1; }
}

# ---------------------------------------------------------------------------
# 2) 复现步骤
# ---------------------------------------------------------------------------
SETUP_SQL=(
  "CREATE DATABASE $DB_HAS;"
  "CREATE DATABASE $DB_NOP;"
  "CREATE TIMESERIES ${DB_HAS}.d1.s1 WITH DATATYPE=INT32;"
  "CREATE TIMESERIES ${DEV_TREE}.s1 WITH DATATYPE=INT32;"
  "CREATE ALIGNED TIMESERIES ${DEV_ALIGNED}(s1 INT32);"
  "INSERT INTO ${DB_HAS}.d1(time, s1) VALUES (1, 10);"   # 只给第一个库造数据分区
  "FLUSH;"
)
LAST_SQL="SELECT LAST * FROM root.** ORDER BY TIMESERIES;"

show_session(){
  local name=$1 raw=$2 body=$3
  printf '%s\n' "$raw"  >"$ART/session_${name}.out"
  printf '%s\n' "$body" >"$ART/session_${name}_body.out"
  log "  [$name] 会话原始输出: $ART/session_${name}.out"
}

# 主场景：CLEAR CACHE -> 混合 LAST 查询 -> 精确查询（必须在同一会话、同一 DataNode）
run_last_round(){
  local name=$1 dev=$2 raw body hit last_rows
  log "=== [$name] CLEAR CACHE -> $LAST_SQL -> SELECT s1 FROM $dev; ==="
  raw=$(session "${SETUP_SQL[@]}" 'CLEAR CACHE;' "$LAST_SQL" "SELECT s1 FROM $dev;")
  body=$(printf '%s\n' "$raw" | strip_echo)
  show_session "$name" "$raw" "$body"
  # 只取数据行（以时间戳开头），避免把精确查询空结果表头里的序列名误判为 LAST 的返回行
  last_rows=$(printf '%s\n' "$body" | grep -E '^\|[0-9]{4}-[0-9]{2}-[0-9]{2}T')
  printf '%s\n' "$last_rows" >"$ART/session_${name}_lastrows.out"
  log "  [$name] 会话里的数据行: $(printf '%s' "$last_rows" | tr '\n' ' ')"

  hit=$(printf '%s\n' "$body" | grep -i 'No matched database' | head -1)
  if [ -n "$hit" ]; then
    fail "[$name] 复现 TDB-421：LAST 查询污染 schema 缓存后，精确查询 $dev 报错 -> $hit"
    return 1
  fi
  if [ -z "$last_rows" ]; then
    warn "[$name] 没有取到任何数据行，请查看 $ART/session_${name}.out"
  elif ! printf '%s\n' "$last_rows" | grep -q "${DB_HAS}.d1.s1"; then
    warn "[$name] 混合 LAST 查询结果里没有 ${DB_HAS}.d1.s1（预期应有，查询可能被跳过）"
  fi
  if printf '%s\n' "$last_rows" | grep -q "${DB_NOP}"; then
    fail "[$name] 混合 LAST 查询返回了没有数据分区的设备（预期只返回 ${DB_HAS}.d1.s1）"
  fi
  log "  [$name] 结果正确：未见 No matched database，LAST 未返回无数据分区设备"
}

# 对照组：CLEAR CACHE 之后直接精确查询（不做 LAST），应返回空集不报错
run_control_round(){
  local name=$1 dev=$2 raw body
  log "=== [$name 对照] CLEAR CACHE -> SELECT s1 FROM $dev; （不执行 LAST） ==="
  raw=$(session 'CLEAR CACHE;' "SELECT s1 FROM $dev;")
  body=$(printf '%s\n' "$raw" | strip_echo)
  show_session "$name" "$raw" "$body"
  if printf '%s\n' "$body" | grep -qi 'No matched database'; then
    fail "[$name] 未执行 LAST 查询却也报 No matched database，说明不是本场景（另有根因）"
  elif printf '%s\n' "$body" | grep -qi 'Empty set'; then
    log "  [$name] 对照通过：无 LAST 污染时精确查询返回空集"
  else
    warn "[$name] 对照组精确查询既没报错也不是空集，请查看 $ART/session_${name}.out"
  fi
}

run_repro(){
  log "=== TDB-421 复现开始（全部 SQL 直连 DataNode $Q） ==="
  log "  前提确认: enable_last_cache=$(sshx "$Q" "grep -E '^enable_last_cache=' $db_dir/conf/iotdb-system.properties | cut -d= -f2-" | tr -d '\r')"
  log "  库: $DB_HAS (有数据分区) / $DB_NOP (无数据分区, 设备 d1008 普通 / d1009 对齐)"
  log "  预期: 若 ${DB_NOP} 确实没有 DataRegion，且 LAST 计划里带着 Not Assigned 的 LastQueryScan，"
  log "        则本用例覆盖了 TDB-421 的触发路径（未修复版本会在下面的精确查询处报 No matched database）"
  run_last_round tdb421_tree "$DEV_TREE"      || true
  run_last_round tdb421_aligned "$DEV_ALIGNED" || true
  # 一致性校验放在 EXPLAIN 预检之前：EXPLAIN 会做一次分析、可能回填正确的 schema 缓存，
  # 先把被污染状态下各副本的差异取下来。
  consistency_check
  explain_precheck
  run_control_round tdb421_control "$DEV_TREE" || true
}

# 证据/前提：确认无数据分区设备确实以 "Partition: Not Assigned" 进入 LAST 计划，
# 以及该库确实没有 DataRegion（触发条件成立）。
explain_precheck(){
  local exp regions
  log "=== 触发前提核对 ==="
  exp=$(cli "EXPLAIN $LAST_SQL")
  printf '%s\n' "$exp" >"$ART/explain_last.out"
  if printf '%s\n' "$exp" | grep -q 'Not Assigned'; then
    log "  EXPLAIN: LAST 计划中存在 Partition: Not Assigned（TDB-421 触发前提成立），见 $ART/explain_last.out"
  else
    warn "EXPLAIN 里没有 Not Assigned，触发前提可能不成立（规划器可能已裁剪），结论需谨慎"
  fi
  if printf '%s\n' "$exp" | grep -q "${DB_NOP}"; then
    log "  EXPLAIN: 无数据分区设备已进入 LAST 计划（${DEV_TREE} / ${DEV_ALIGNED}）"
  else
    warn "EXPLAIN 里没有 ${DB_NOP} 的 LastQueryScan 节点"
  fi
  regions=$(cli 'SHOW REGIONS;' | awk -F'|' -v db="$DB_NOP" '$3 ~ /DataRegion/ && $5 ~ db {print}' | wc -l)
  if [ "${regions:-0}" -eq 0 ]; then
    log "  SHOW REGIONS: ${DB_NOP} 没有 DataRegion（无数据分区条件成立）"
  else
    warn "SHOW REGIONS: ${DB_NOP} 已存在 DataRegion，无数据分区条件不成立，可能无法触发本缺陷"
  fi
}

# ---------------------------------------------------------------------------
# 3) sync lag 归零（直接抓每个 DataNode 自己的 exporter）
# ---------------------------------------------------------------------------
DN_METRICS_PORT=${DN_METRICS_PORT:-9092}
sync_lag_scan(){   # 输出 "<series 总数> <非零条数>"；抓不到输出 "-1 -1"
  local h body n=0 bad=0 line v
  for h in "${DN[@]}"; do
    body=$(curl -s -m 8 "http://$h:$DN_METRICS_PORT/metrics" 2>/dev/null | grep 'type="syncLag"')
    if [ -z "$body" ]; then echo "-1 -1"; return 0; fi
    while IFS= read -r line; do
      v=${line##* }
      n=$((n+1))
      if awk -v x="$v" 'BEGIN{exit !(x+0>0.0001)}'; then bad=$((bad+1)); fi
    done <<<"$body"
  done
  echo "$n $bad"
}
check_sync_lag(){
  local deadline=$(( $(date +%s) + SYNC_TIMEOUT_SEC )) stable=0 n bad
  while (( $(date +%s) < deadline )); do
    read -r n bad <<<"$(sync_lag_scan)"
    log "  syncLag series=$n nonzero=$bad"
    if [ "${n:-0}" -gt 0 ] && [ "${bad:-1}" -eq 0 ]; then stable=$((stable+1)); else stable=0; fi
    [ "$stable" -ge "$SYNC_STABLE_CHECKS" ] && { log "sync lag 已归零（每个数据区域 series 均为 0）"; return 0; }
    sleep 10
  done
  fail "sync lag 在 ${SYNC_TIMEOUT_SEC}s 内未归零（series=$n nonzero=$bad）"
  return 1
}

# ---------------------------------------------------------------------------
# 4) 副本一致性：三个副本各自做一次精确查询，结果（含报错）必须一致；
#    再逐个停 DN，用剩下的副本查，仍必须与基准一致。
#    注意：被污染的 DataNode 会返回 ERROR，其它副本返回 EMPTY —— 这正是本缺陷
#          在副本间表现不一致的证据。
# ---------------------------------------------------------------------------
query_one(){   # $1=node  $2=device -> 归一化结果
  norm_q "$(cli_node "$1" "SELECT s1 FROM $2;")"
}
consistency_check(){
  local h on cur base_tree base_aligned
  log "=== 副本一致性校验（精确查询 d1008 / d1009） ==="
  base_tree=$(query_one "${DN[0]}" "$DEV_TREE")
  base_aligned=$(query_one "${DN[0]}" "$DEV_ALIGNED")
  log "  基准(经 ${DN[0]}): d1008=[$base_tree] d1009=[$base_aligned]"
  for h in "${DN[@]}"; do
    [[ $h == "${DN[0]}" ]] && continue
    cur=$(query_one "$h" "$DEV_TREE")
    [ "$cur" = "$base_tree" ] || fail "全部在线时副本结果不一致: $h d1008=[$cur] 基准=[$base_tree]"
    cur=$(query_one "$h" "$DEV_ALIGNED")
    [ "$cur" = "$base_aligned" ] || fail "全部在线时副本结果不一致: $h d1009=[$cur] 基准=[$base_aligned]"
  done
  for h in "${DN[@]}"; do
    log "  --- 停 DataNode $h ---"
    sshx "$h" "'$db_dir/sbin/stop-datanode.sh' -f >/dev/null 2>&1 || true; pkill -f 'com\\.timecho\\.iotdb\\.DataNode' >/dev/null 2>&1 || true" || true
    wait_dn "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "停 $h 后 ${DN_DOWN_WAIT_SEC}s 内集群仍显示 Running"
    for on in "${DN[@]}"; do
      [[ $on == "$h" ]] && continue
      cur=$(query_one "$on" "$DEV_TREE")
      [ "$cur" = "$base_tree" ] || fail "停 $h 后经 $on 查询 d1008 与基准不一致: [$cur] vs [$base_tree]"
      cur=$(query_one "$on" "$DEV_ALIGNED")
      [ "$cur" = "$base_aligned" ] || fail "停 $h 后经 $on 查询 d1009 与基准不一致: [$cur] vs [$base_aligned]"
    done
    sshx "$h" "nohup '$db_dir/sbin/start-datanode.sh' -d >'$db_dir/start_dn_${RUN_ID}.log' 2>&1 </dev/null &" || true
    wait_dn "$h" running "$DN_RECOVER_WAIT_SEC" || fail "DataNode $h 未恢复 Running"
  done
}

# ---------------------------------------------------------------------------
# 5) CN/DN 日志常见异常检查（含本缺陷特征 No matched database）
# ---------------------------------------------------------------------------
ERR_PAT='NullPointer|BufferUnderflowException|but return HAS_MORE_STATE|CompactionTableSchemaNotMatchException|has overlapped data|DataTypeInconsistentException|ArrayIndexOutOfBoundsException|StatisticsClassException|NegativeArraySizeException|is not in tsFileMetaData|The memory cost to be released is larger|Alter timeseries .* data type from null to|No matched database'
check_log(){
  log "=== 检查 CN/DN 日志常见异常 ==="
  local role h files n nodes
  for role in confignode datanode; do
    if [ "$role" = confignode ]; then mapfile -t nodes < <(printf '%s\n' "${CN[@]}"); else mapfile -t nodes < <(printf '%s\n' "${DN[@]}"); fi
    for h in "${nodes[@]}"; do
      files=$(sshx "$h" "ls $db_dir/logs/*${role}*all*.log $db_dir/logs/*${role}*error*.log 2>/dev/null" 2>/dev/null | tr '\n' ' ')
      [ -z "$files" ] && { log "  WARN $role $h 无日志文件"; continue; }
      n=$(sshx "$h" "grep -hcE '$ERR_PAT' $files 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
      if [ "${n:-0}" -gt 0 ]; then
        fail "$role $h 日志出现 $n 条常见异常（含 No matched database / NullPointer 等）"
        sshx "$h" "grep -nE '$ERR_PAT' $files 2>/dev/null | head -20 | cut -c1-220" >>"$OUT" 2>&1
      else
        log "  OK $role $h 无常见异常"
      fi
    done
  done
}

# ---------------------------------------------------------------------------
# 6) 失败时备份 CN/DN 日志
# ---------------------------------------------------------------------------
backup_logs(){
  [ "$LOG_BACKUP" -eq 1 ] || { log "LOG_BACKUP=0，跳过日志备份"; return 0; }
  local dst="$ART/logs" h
  mkdir -p "$dst"
  log "=== 备份 CN/DN 日志到 $dst ==="
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    if timeout 900 ssh -n -o BatchMode=yes -o ConnectTimeout=15 "$os_user_name@$h" "tar czf - -C '$db_dir' logs" >"$dst/$h.logs.tgz" 2>/dev/null; then
      log "  backup $h -> $dst/$h.logs.tgz ($(du -h "$dst/$h.logs.tgz" 2>/dev/null | cut -f1))"
    else
      log "  WARN backup $h 失败"
    fi
  done
}

# ---------------------------------------------------------------------------
# 7) 结果
# ---------------------------------------------------------------------------
write_result(){
  local r="FAIL" elapsed=$(( $(date +%s) - start_epoch )) csv msg
  [ "$fail_flag" -eq 0 ] && r="PASS"
  log "RESULT $r fail_flag=$fail_flag case=$CASE consensus=${CONSENSUS_CLASS##*.} elapsed=${elapsed}s"
  log "v_warnMessage=${v_warnMessage:-<empty>}"
  printf 'run_id=%s\ncase=%s\nconsensus=%s\nresult=%s\nfail_flag=%s\nelapsed_seconds=%s\nv_warnMessage=%s\n' \
    "$RUN_ID" "$CASE" "$CONSENSUS_CLASS" "$r" "$fail_flag" "$elapsed" "${v_warnMessage:-}" >"$OUTDIR/result_${CASE}_${RUN_ID}.txt"
  csv=$cur_dir/test_result.csv
  msg=$(printf '%s' "${v_warnMessage:-}" | tr ',' ';' | tr -d "'")
  [ -f "$csv" ] || echo 'Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage,maxBMTestTimeSec,sumBMTestTimeSec' >>"$csv"
  printf '%s,\x27%s\x27,\x27%s\x27,\x27%s\x27,\x27%s\x27,%s,%s,\x27%s\x27,%s,%s\n' \
    "$(date --iso-8601=seconds)" "$testdb" "${CONSENSUS_CLASS##*.}" "$CASE.sh" "$r" "$elapsed" "$fail_flag" "$msg" 0 0 >>"$csv"
  log "结果已追加到 $csv"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
log "=== $CASE 开始 run_id=$RUN_ID ==="
log "共识协议: $CONSENSUS_CLASS"
log "集群: CN=[${CN[*]}] DN=[${DN[*]}] 复现连接节点=$Q db_dir=$db_dir"

log "--- 1) 停止集群 / 清理 data+logs / 恢复 conf_orig（复用框架脚本） ---"
bash -x "$BASE/clean_env/stop_cluster.sh"  >>"$OUT" 2>&1 || warn "stop_cluster.sh 返回非 0"
bash -x "$BASE/clean_env/clean_cluster.sh" >>"$OUT" 2>&1 || warn "clean_cluster.sh 返回非 0"
bash -x "$BASE/clean_env/reset_conf.sh"    >>"$OUT" 2>&1 || warn "reset_conf.sh 返回非 0"

log "--- 2) 写集群参数（3 副本 + 共识协议 + enable_last_cache=true） ---"
for h in "${CN[@]}" "${DN[@]}"; do set_conf "$h"; done
for h in "${CN[@]}" "${DN[@]}"; do
  v=$(sshx "$h" "grep -E '^data_region_consensus_protocol_class=' $db_dir/conf/iotdb-system.properties | cut -d= -f2-" | tr -d '\r')
  [ "$v" = "$CONSENSUS_CLASS" ] || fail "$h 共识协议写入不匹配: '$v' != '$CONSENSUS_CLASS'"
  v=$(sshx "$h" "grep -E '^enable_last_cache=' $db_dir/conf/iotdb-system.properties | cut -d= -f2-" | tr -d '\r')
  [ "$v" = "true" ] || fail "$h enable_last_cache 未写成功: '$v'"
done
log "  参数确认: $(sshx "${CN[0]}" "grep -E '^(cluster_name|cn_seed_config_node|schema_replication_factor|data_replication_factor|data_region_consensus_protocol_class|enable_last_cache)=' $db_dir/conf/iotdb-system.properties" | tr '\n' ' ')"

log "--- 3) 启动集群（复用框架 start_cluster_v20.sh） ---"
if ! bash -x "$BASE/prepare_env/start_cluster_v20.sh" 1 6 >>"$OUT" 2>&1; then
  fail "集群启动失败"
else
  cli 'show cluster;' >>"$OUT" 2>&1
  log "  $(cli 'show cluster;' | grep -cE 'Running|ReadOnly') 个节点在线"
  if cli 'show cluster;' | grep -q 'UNACTIVATED'; then
    log "  检测到未激活，提交试用激活码"
    log "  $(cli "activate '03-AAATKKLP-XREBT2T7-2QRCC===';" | head -3 | tr '\n' ' ')"
  fi
fi

log "--- 4) TDB-421 复现（LAST cache 污染） ---"
run_repro

log "--- 5) sync lag 归零 ---"
check_sync_lag || true

log "--- 6) 日志检查 ---"
check_log

log "--- 7) 收尾：备份日志（失败时）并停止集群 ---"
if [ "$fail_flag" -gt 0 ]; then backup_logs; else log "用例通过，不备份日志"; fi
bash -x "$BASE/clean_env/stop_cluster.sh" >>"$OUT" 2>&1 || true

write_result
