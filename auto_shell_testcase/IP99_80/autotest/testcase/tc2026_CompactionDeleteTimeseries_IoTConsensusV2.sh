#!/bin/bash
# ============================================================================
# tc2026 compaction / DELETE TIMESERIES 旧数据"复活"复现用例
#
# 场景：3C3D（SchemaRegion 与 DataRegion 均 3 副本）
#   1) 停止集群 → 删除 data/logs/conf → conf_orig 复制为 conf → 写入集群参数
#   2) 启动前写死压缩相关参数：
#        enable_seq_space_compaction=false
#        enable_unseq_space_compaction=false
#        enable_cross_space_compaction=false
#        inner_compaction_candidate_file_num=2
#        compaction_schedule_interval_in_ms=1000
#   3) 启动集群并复现 SQL（DELETE TIMESERIES 后重新建序列并写入）
#   4) 开启 enable_seq_space_compaction，等待 inner compaction 确实完成后再查询
#      预期：只有 (2,2) 一行；若出现两行 (1,1)、(2,2) 即为缺陷复现
#   5) 等待 sync lag 归 0；校验副本数据一致性（全部副本在线做基准，逐个停 DN 对比）
#   6) 检查 CN/DN 日志常见异常；用例失败时备份 CN/DN 日志
#
# 注意：device 必须是两级 root.repro（不能写成 root.repro.d1），否则不触发该缺陷。
#
# 本文件与 IoTConsensusV2 版本的唯一区别就是下面这一行 CONSENSUS_CLASS。
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
root_pw=$(cfg root_pw); root_pw=${root_pw:-TimechoDB@2021}
testdb=$(cfg v_testdb)
db_parent=$(cfg v_db_parent_dir); db_parent=${db_parent:-/data/iotdb}
shell_parent=$(cfg v_shell_client_db_parent_dir); shell_parent=${shell_parent:-$db_parent}
monitor_url=$(cfg monitor_url)
cluster_id=$(cfg CLUSTER_NAME); cluster_id=${cluster_id:-timecho}
db_dir=$db_parent/$testdb
cli_dir=$shell_parent/$testdb
CLI=$cli_dir/sbin/start-cli.sh

# 框架约定：reset_conf.sh / backup_cluster_logs.sh 读的是不带后缀的节点清单
cp -rfp "$BASE/conf/confignode_3c.txt" "$BASE/conf/confignode.txt"
cp -rfp "$BASE/conf/datanode_3d.txt"   "$BASE/conf/datanode.txt"
mapfile -t CN < <(awk 'NF && !/^#/ {print $1}' "$BASE/conf/confignode_3c.txt")
mapfile -t DN < <(awk 'NF && !/^#/ {print $1}' "$BASE/conf/datanode_3d.txt")
Q=${DN[0]}

CASE=$(basename "$0" .sh)
RUN_ID=$(date +%Y%m%d_%H%M%S)
OUTDIR=$cur_dir/compaction_delete_repro_results
OUT=$OUTDIR/${CASE}_${RUN_ID}.out
ART=$OUTDIR/artifact_${RUN_ID}
mkdir -p "$OUTDIR" "$ART"; : > "$OUT"

# ---------------------------------------------------------------------------
# 可调参数
# ---------------------------------------------------------------------------
COMPACTION_WAIT_SEC=${COMPACTION_WAIT_SEC:-240}     # 等 inner compaction 完成的秒数
COMPACTION_POLL_SEC=${COMPACTION_POLL_SEC:-5}
SYNC_TIMEOUT_SEC=${SYNC_TIMEOUT_SEC:-600}           # sync lag 归零等待
SYNC_STABLE_CHECKS=${SYNC_STABLE_CHECKS:-3}
DN_DOWN_WAIT_SEC=${DN_DOWN_WAIT_SEC:-180}
DN_RECOVER_WAIT_SEC=${DN_RECOVER_WAIT_SEC:-300}
LOG_BACKUP=${LOG_BACKUP:-1}                         # 失败时备份 CN/DN 日志

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
cli(){ "$CLI" -h "$Q" -u root -pw "$root_pw" -e "$1" 2>&1; }
cli_node(){ "$CLI" -h "$1" -u root -pw "$root_pw" -e "$2" 2>&1; }
# CLI 表格：只保留数据行（去掉表头与分隔线），用于跨副本比对
norm_rows(){ grep -E '^\|' | grep -vE '^\|[-+ ]+\|$' | tail -n +2 | sed -E 's/[[:space:]]+/ /g'; }
# 复现库在某个节点 sequence 空间的 TsFile 数
seq_files(){ local v; v=$(sshx "$1" "find $db_dir/data/datanode/data/sequence/root.repro -name '*.tsfile' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
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

# ---------------------------------------------------------------------------
# 1) 写集群参数（IP / 3 副本 / 共识协议 / 启动前压缩参数）
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
 # 启动前必须写死的压缩参数
 'enable_seq_space_compaction':'false',
 'enable_unseq_space_compaction':'false',
 'enable_cross_space_compaction':'false',
 'inner_compaction_candidate_file_num':'2',
 'compaction_schedule_interval_in_ms':'1000'}
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
# 2) inner compaction 完成判据（与共识协议无关，两种协议都适用）
#    权威信号 = DataNode 压缩日志里出现该 device 的
#      "Sequence InnerSpaceCompaction task finishes successfully"
#    判据 = 开启压缩后至少多出 1 条成功记录，且连续两次轮询不再增加（压缩已停止），
#           同时各副本该 device 的 seq TsFile 数都不超过 1（没有多文件堆积）。
# ---------------------------------------------------------------------------
COMPACTION_LOG=log_datanode_compaction.log
SEQ_PAT='root\.repro-.*Sequence InnerSpaceCompaction task finishes successfully'
compaction_fin(){   # 单个 DN 上 root.repro 的 seq inner compaction 成功条数
  local v
  v=$(sshx "$1" "grep -c '$SEQ_PAT' $db_dir/logs/$COMPACTION_LOG 2>/dev/null" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"
}
compaction_fin_total(){ local s=0 h; for h in "${DN[@]}"; do s=$((s+$(compaction_fin "$h"))); done; echo "$s"; }
files_ok(){ local c; for c in ${1//:/ }; do [ "${c:-0}" -le 1 ] || return 1; done; return 0; }
dump_compaction_log(){   # 把各 DN 上 root.repro 的压缩记录留证
  local h
  : >"$ART/compaction.log"
  for h in "${DN[@]}"; do
    { echo "===== DataNode $h ($(compaction_fin "$h") 次成功) ====="
      sshx "$h" "grep -E 'root\.repro' $db_dir/logs/$COMPACTION_LOG 2>/dev/null" 2>/dev/null; } >>"$ART/compaction.log"
  done
  log "  压缩日志已保存: $ART/compaction.log"
}
wait_compaction(){
  local deadline=$(( $(date +%s) + COMPACTION_WAIT_SEC )) prev_fin="" cur fin stable=0 counts h c
  local base=${COMPACTION_BASE:-0}
  while (( $(date +%s) < deadline )); do
    cur=""; counts=""
    for h in "${DN[@]}"; do
      cur="$cur$(seq_files "$h"):"
      c=$(compaction_fin "$h"); counts="$counts ${h##*.}=$c"
    done
    fin=$(( $(compaction_fin_total) - base ))
    log "  compaction poll: seqFiles(${DN[*]})=$cur 各副本合并成功次数[${counts} ] 新增=$fin"
    if [ "$fin" -ge 1 ] && [ "$fin" = "$prev_fin" ] && files_ok "$cur"; then
      stable=$((stable+1))
      if [ "$stable" -ge 2 ]; then
        log "inner compaction 确认完成（新增 $fin 次 root.repro seq 合并，各副本 seq TsFile<=1 且稳定）"
        dump_compaction_log
        return 0
      fi
    else
      stable=0
    fi
    prev_fin="$fin"
    sleep "$COMPACTION_POLL_SEC"
  done
  dump_compaction_log
  warn "等 inner compaction 完成超时(${COMPACTION_WAIT_SEC}s)，新增完成合并任务数=$fin seqFiles=$cur"
  return 1
}

# ---------------------------------------------------------------------------
# 3) 复现步骤
# ---------------------------------------------------------------------------
run_repro(){
  local q_pre q_post rows n
  log "=== 复现 SQL 开始（device 必须两级：root.repro） ==="
  local stmts=(
    "CREATE DATABASE root.repro;"
    "CREATE TIMESERIES root.repro.s1 WITH DATATYPE=INT64;"
    "INSERT INTO root.repro(time, s1) VALUES (1, 1);"
    "FLUSH;"
    "DELETE TIMESERIES root.repro.s1;"
    "CREATE TIMESERIES root.repro.s1 WITH DATATYPE=INT64;"
    "INSERT INTO root.repro(time, s1) VALUES (2, 2);"
    "FLUSH;"
  )
  local i=0 out
  for s in "${stmts[@]}"; do
    i=$((i+1))
    out=$(cli "$s")
    log "  SQL[$i] $s"
    printf '%s\n' "$out" | sed -E 's/^/    /' | head -12 >>"$OUT"
    printf '%s\n' "$out" | head -3 | while IFS= read -r l; do log "    $l"; done
    case "$s" in
      "FLUSH;")
        for h in "${DN[@]}"; do log "    seqFiles[$h]=$(seq_files "$h")"; done ;;
      "DELETE TIMESERIES root.repro.s1;")
        log "    DELETE 之后（应为空）: $(cli 'SELECT s1 FROM root.repro;' | norm_rows | tr '\n' ' ')" ;;
    esac
  done

  q_pre=$(cli 'SELECT s1 FROM root.repro;' | norm_rows)
  n=$(printf '%s\n' "$q_pre" | grep -c '[0-9]')
  log "  开启压缩之前: rows=$n -> $(printf '%s' "$q_pre" | tr '\n' ' ')"

  # 基线必须在 SET CONFIGURATION 之前采集：三个节点时钟最大相差约 20s，
  # 压缩日志自带的时间戳不可信，只能以"开启前已存在的成功合并记录数"为基准。
  COMPACTION_BASE=$(compaction_fin_total)
  log "=== 开启 enable_seq_space_compaction = true ==="
  log "  开启前 root.repro seq 合并成功次数基线=$COMPACTION_BASE"
  log "  SET CONFIGURATION 返回: $(cli "SET CONFIGURATION 'enable_seq_space_compaction'='true';" | head -2 | tr '\n' ' ')"
  wait_compaction || true

  q_post=$(cli 'SELECT s1 FROM root.repro;' | norm_rows)
  n=$(printf '%s\n' "$q_post" | grep -c '[0-9]')
  log "  合并完成之后: rows=$n -> $(printf '%s' "$q_post" | tr '\n' ' ')"
  printf '%s\n' "$q_post" >>"$ART/post_compaction_query.txt"

  # ---- 判定 ----
  if printf '%s\n' "$q_pre" | grep -q '08:00:00\.001'; then
    fail "开启压缩前旧数据已复活: $(printf '%s' "$q_pre" | tr '\n' ' ')"
  fi
  if [ "${n:-0}" -ne 1 ]; then
    fail "inner compaction 完成后 SELECT s1 FROM root.repro 返回 ${n} 行（预期 1 行 (2,2)）: $(printf '%s' "$q_post" | tr '\n' ' ')"
  elif printf '%s\n' "$q_post" | grep -q '08:00:00\.001'; then
    fail "inner compaction 完成后被 DELETE 的旧数据 (1,1) 重新可见: $(printf '%s' "$q_post" | tr '\n' ' ')"
  else
    log "  结果正确：只有 (2,2) 一行，未复现缺陷"
  fi
}

# ---------------------------------------------------------------------------
# 4) sync lag 归零
#    直接抓每个 DataNode 自带 exporter 的 iot_consensus{type="syncLag"}：
#    每个数据区域一条 series，要求三副本上全部 series 都为 0（连续 SYNC_STABLE_CHECKS 次）。
#    这样不依赖 Prometheus 是否抓取到该指标。
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
# 5) 副本数据一致性：全部副本在线取基准，逐个停 DN 对比
# ---------------------------------------------------------------------------
consistency_check(){
  local h on cur base_file="$ART/baseline.txt"
  log "=== 副本数据一致性校验 ==="
  cli 'SELECT s1 FROM root.repro;' | norm_rows >"$base_file"
  log "  基准(经 ${DN[0]} 查询): $(tr '\n' ' ' <"$base_file")"
  for h in "${DN[@]}"; do
    [[ $h == "${DN[0]}" ]] && continue
    cur=$(cli_node "$h" 'SELECT s1 FROM root.repro;' | norm_rows)
    if [ "$cur" != "$(cat "$base_file")" ]; then
      fail "全部在线时副本结果不一致: ${h} -> $(printf '%s' "$cur" | tr '\n' ' ')"
    else
      log "  OK 全部在线: $h 与基准一致"
    fi
  done
  for h in "${DN[@]}"; do
    log "  --- 停 DataNode $h ---"
    sshx "$h" "'$db_dir/sbin/stop-datanode.sh' -f >/dev/null 2>&1 || true; pkill -f 'com\\.timecho\\.iotdb\\.DataNode' >/dev/null 2>&1 || true" || true
    wait_dn "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "停 $h 后 ${DN_DOWN_WAIT_SEC}s 内集群仍显示 Running"
    for on in "${DN[@]}"; do
      [[ $on == "$h" ]] && continue
      cur=$(cli_node "$on" 'SELECT s1 FROM root.repro;' | norm_rows)
      if [ "$cur" != "$(cat "$base_file")" ]; then
        fail "停 $h 后经 $on 查询与基准不一致: $(printf '%s' "$cur" | tr '\n' ' ')"
      else
        log "  OK 停 $h 时经 $on 查询与基准一致"
      fi
    done
    sshx "$h" "nohup '$db_dir/sbin/start-datanode.sh' -d >'$db_dir/start_dn_${RUN_ID}.log' 2>&1 </dev/null &" || true
    wait_dn "$h" running "$DN_RECOVER_WAIT_SEC" || { fail "DataNode $h 未恢复 Running"; }
  done
}

# ---------------------------------------------------------------------------
# 6) CN/DN 日志常见异常检查
# ---------------------------------------------------------------------------
check_log(){
  log "=== 检查 CN/DN 日志常见异常 ==="
  local role h files pat n
  for role in confignode datanode; do
    if [ "$role" = confignode ]; then mapfile -t nodes < <(printf '%s\n' "${CN[@]}"); else mapfile -t nodes < <(printf '%s\n' "${DN[@]}"); fi
    for h in "${nodes[@]}"; do
      files=$(sshx "$h" "ls $db_dir/logs/*${role}*all*.log $db_dir/logs/*${role}*error*.log 2>/dev/null" 2>/dev/null | tr '\n' ' ')
      [ -z "$files" ] && { log "  WARN $role $h 无日志文件"; continue; }
      n=$(sshx "$h" "grep -hcE 'NullPointer|BufferUnderflowException|but return HAS_MORE_STATE|CompactionTableSchemaNotMatchException|has overlapped data|DataTypeInconsistentException|ArrayIndexOutOfBoundsException|StatisticsClassException|NegativeArraySizeException|is not in tsFileMetaData|The memory cost to be released is larger|Alter timeseries .* data type from null to' $files 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
      if [ "${n:-0}" -gt 0 ]; then
        fail "$role $h 日志出现 $n 条常见异常（NullPointer/BufferUnderflow/HAS_MORE_STATE/compaction 类等）"
        sshx "$h" "grep -nE 'NullPointer|BufferUnderflowException|but return HAS_MORE_STATE|CompactionTableSchemaNotMatchException|has overlapped data|DataTypeInconsistentException|ArrayIndexOutOfBoundsException|StatisticsClassException|NegativeArraySizeException|is not in tsFileMetaData|The memory cost to be released is larger|Alter timeseries .* data type from null to' $files 2>/dev/null | head -20 | cut -c1-220" >>"$OUT" 2>&1
      else
        log "  OK $role $h 无常见异常"
      fi
    done
  done
}

# ---------------------------------------------------------------------------
# 7) 备份 CN/DN 日志（用例失败时）
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
# 8) 结果
# ---------------------------------------------------------------------------
write_result(){
  local r="FAIL" elapsed=$(( $(date +%s) - start_epoch ))
  [ "$fail_flag" -eq 0 ] && r="PASS"
  log "RESULT $r fail_flag=$fail_flag case=$CASE consensus=${CONSENSUS_CLASS##*.} elapsed=${elapsed}s"
  log "v_warnMessage=${v_warnMessage:-<empty>}"
  printf 'run_id=%s\ncase=%s\nconsensus=%s\nresult=%s\nfail_flag=%s\nelapsed_seconds=%s\nv_warnMessage=%s\n' \
    "$RUN_ID" "$CASE" "$CONSENSUS_CLASS" "$r" "$fail_flag" "$elapsed" "${v_warnMessage:-}" >"$OUTDIR/result_${CASE}_${RUN_ID}.txt"
  # 汇总结果文件（与框架其它用例同格式）
  local csv=$cur_dir/test_result.csv msg
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
log "集群: CN=[${CN[*]}] DN=[${DN[*]}] db_dir=$db_dir"

log "--- 1) 停止集群 / 清理 data+logs / 恢复 conf_orig（复用框架脚本） ---"
bash -x "$BASE/clean_env/stop_cluster.sh"  >>"$OUT" 2>&1 || warn "stop_cluster.sh 返回非 0"
bash -x "$BASE/clean_env/clean_cluster.sh" >>"$OUT" 2>&1 || warn "clean_cluster.sh 返回非 0"
bash -x "$BASE/clean_env/reset_conf.sh"    >>"$OUT" 2>&1 || warn "reset_conf.sh 返回非 0"

log "--- 2) 写集群参数（3 副本 + 共识协议 + 压缩参数） ---"
for h in "${CN[@]}" "${DN[@]}"; do set_conf "$h"; done
for h in "${CN[@]}" "${DN[@]}"; do
  v=$(sshx "$h" "grep -E '^data_region_consensus_protocol_class=' $db_dir/conf/iotdb-system.properties | cut -d= -f2-" | tr -d '\r')
  [ "$v" = "$CONSENSUS_CLASS" ] || fail "$h 共识协议写入不匹配: '$v' != '$CONSENSUS_CLASS'"
done
log "  参数确认: $(sshx "${CN[0]}" "grep -E '^(cluster_name|cn_seed_config_node|schema_replication_factor|data_replication_factor|data_region_consensus_protocol_class|enable_seq_space_compaction|enable_unseq_space_compaction|enable_cross_space_compaction|inner_compaction_candidate_file_num|compaction_schedule_interval_in_ms)=' $db_dir/conf/iotdb-system.properties" | tr '\n' ' ')"

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

log "--- 4) 复现 DELETE TIMESERIES + compaction ---"
run_repro

log "--- 5) sync lag 归零 ---"
check_sync_lag || true

log "--- 6) 副本数据一致性 ---"
consistency_check

log "--- 7) 日志检查 ---"
check_log

log "--- 8) 收尾：备份日志（失败时）并停止集群 ---"
if [ "$fail_flag" -gt 0 ]; then backup_logs; else log "用例通过，不备份日志"; fi
bash -x "$BASE/clean_env/stop_cluster.sh" >>"$OUT" 2>&1 || true

write_result
exit "$fail_flag"
