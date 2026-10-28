#!/bin/bash
# Object TTL expiration must not leave IoTConsensus syncLag stuck above zero.
set -uo pipefail
cur_dir="$(cd "$(dirname "$0")" && pwd)"
conf_file="${cur_dir}/../conf/test.conf"
clean_dir="${cur_dir}/../clean_env"
prepare_dir="${cur_dir}/../prepare_env"
os_user_name=$(awk -F= '/^os_user_name=/{gsub(/ /,"",$2);print $2}' "$conf_file")
db_user_name=$(awk -F= '/^db_user_name=/{gsub(/ /,"",$2);print $2}' "$conf_file")
testdb=$(awk -F= '/^v_testdb=/{gsub(/ /,"",$2);print $2}' "$conf_file")
db_parent_dir=$(awk -F= '/^v_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "$conf_file")
cn_db_parent_dir=$(awk -F= '/^v_cn_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "$conf_file")
shell_client_db_parent_dir=$(awk -F= '/^v_shell_client_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "$conf_file")
cli_dir="${shell_client_db_parent_dir:-${db_parent_dir}}/${testdb}"
benchmark_home="${cur_dir}/../benchmark/bm_20260812_e158c2c_jdk17"
benchmark_template="${benchmark_home}/obj_ttl"
dn_num=3
cn_num=3
total_node_num=$((dn_num+cn_num))
cp -rfp ${cur_dir}/../conf/datanode_${dn_num}d.txt ${cur_dir}/../conf/datanode.txt
cp -rfp ${cur_dir}/../conf/confignode_${cn_num}c.txt ${cur_dir}/../conf/confignode.txt
query_ip=$(head -1 "${cur_dir}/../conf/datanode.txt" | tr -d ' ')
seed_cn_ip="$(head -1 "${cur_dir}/../conf/confignode.txt" | tr -d ' '):10710"
cluster_id=$(awk -F= '/^CLUSTER_NAME=/{gsub(/ /,"",$2);print $2}' "$conf_file")
prometheus_url=$(awk -F= '/^monitor_url=/{gsub(/ /,"",$2);print $2}' "$conf_file")
run_id="$(basename "$0" .sh)_$(date +%Y%m%d_%H%M%S)"
artifact_dir="${cur_dir}/${run_id}"; mkdir -p "$artifact_dir"
log_file="${artifact_dir}/run.log"; fail_flag=0
start_epoch=$(date +%s)
result_csv="${cur_dir}/test_result.csv"
sr_rep_num=3
dr_rep_num=3
result_written=0
v_warnMessage=""
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$log_file"; }
cli(){ "$cli_dir/sbin/start-cli.sh" -u "$db_user_name" -h "$query_ip" -timeout 3600 -sql_dialect tree -e "$1"; }
cli_table(){ "$cli_dir/sbin/start-cli.sh" -u "$db_user_name" -h "$query_ip" -timeout 3600 -sql_dialect table -e "$1"; }
remote_log_count(){
  local node=$1 role=$2 pattern=$3 mode=${4:-E}
  ssh "${os_user_name}@${node}" "find '${db_parent_dir}/${testdb}/logs' -maxdepth 1 -type f \( -name '*${role}*all*' -o -name 'log_${role}_error*' \) -print0 2>/dev/null | xargs -0 -r zgrep -h${mode} -- '${pattern}' 2>/dev/null | wc -l" 2>>"$log_file" || echo 0
}
check_log(){
  local node count total
  log "check ConfigNode/DataNode exception logs"
  while read -r node; do
    [[ -z "$node" ]] && continue
    count=$(remote_log_count "$node" confignode 'NullPointer' F); count=${count//[!0-9]/}; count=${count:-0}
    if (( count > 0 )); then fail_flag=$((fail_flag+1)); v_warnMessage+="CN ${node} NPE:${count}."; log "ERROR CN ${node} NullPointer: ${count}"; fi
    total=$(remote_log_count "$node" confignode 'BufferUnderflowException|but return HAS_MORE_STATE'); total=${total//[!0-9]/}; total=${total:-0}
    if (( total > 0 )); then fail_flag=$((fail_flag+1)); v_warnMessage+="CN ${node} BufferUnderflow/HAS_MORE_STATE:${total}."; log "ERROR CN ${node} BufferUnderflow/HAS_MORE_STATE: ${total}"; fi
  done < "${cur_dir}/../conf/confignode.txt"
  while read -r node; do
    [[ -z "$node" ]] && continue
    count=$(remote_log_count "$node" datanode 'NullPointer' F); count=${count//[!0-9]/}; count=${count:-0}
    if (( count > 0 )); then fail_flag=$((fail_flag+1)); v_warnMessage+="DN ${node} NPE:${count}."; log "ERROR DN ${node} NullPointer: ${count}"; fi
    count=$(remote_log_count "$node" datanode 'AutoResizingBuffer failed to allocate' F); count=${count//[!0-9]/}; count=${count:-0}
    if (( count > 0 )); then v_warnMessage+="DN ${node} AutoResizingBuffer failed:${count}."; log "WARN DN ${node} AutoResizingBuffer failed to allocate: ${count}"; fi
    count=$(remote_log_count "$node" datanode 'ERROR .*Failed to do the initialization for driver.*MetadataLeaseFencedException'); count=${count//[!0-9]/}; count=${count:-0}
    if (( count > 0 )); then fail_flag=$((fail_flag+1)); v_warnMessage+="DN ${node} MetadataLeaseFencedException ERROR:${count}."; log "ERROR DN ${node} MetadataLeaseFencedException bad level: ${count}"; fi
    count=$(remote_log_count "$node" datanode ' (WARN|ERROR) .*Status code: (535|536)([, ]|$)'); count=${count//[!0-9]/}; count=${count:-0}
    if (( count > 0 )); then fail_flag=$((fail_flag+1)); v_warnMessage+="DN ${node} Status 535/536 WARN/ERROR:${count}."; log "ERROR DN ${node} Status 535/536 bad level: ${count}"; fi
    count=$(remote_log_count "$node" datanode 'bytesToReserve should be in (0,maxBytesPerFI]' F); count=${count//[!0-9]/}; count=${count:-0}
    if (( count > 0 )); then v_warnMessage+="DN ${node} bytesToReserve exceeds maxBytesPerFI:${count}."; log "WARN DN ${node} bytesToReserve exceeds maxBytesPerFI: ${count}"; fi
    total=$(remote_log_count "$node" datanode 'CompactionTableSchemaNotMatchException|has overlapped data|which should be later than the last time|DataTypeInconsistentException|ArrayIndexOutOfBoundsException|IndexOutOfBoundsException|Alter timeseries .* data type from null to|StatisticsClassException|BufferUnderflowException|NegativeArraySizeException|is not in tsFileMetaData|The memory cost to be released is larger'); total=${total//[!0-9]/}; total=${total:-0}
    if (( total > 0 )); then fail_flag=$((fail_flag+1)); v_warnMessage+="DN ${node} unexpected log:${total}."; log "ERROR DN ${node} unexpected exceptions: ${total}"; fi
  done < "${cur_dir}/../conf/datanode.txt"
}
write_result(){
  [[ "$result_written" -eq 1 ]] && return
  result_written=1
  local elapsed=$(( $(date +%s) - start_epoch )) result="FAIL" message="${v_warnMessage:-}" bm_max="0" bm_sum="0"
  [[ "$fail_flag" -eq 0 ]] && result="PASS"
  [[ -f "$result_csv" ]] || echo 'Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage,maxBMTestTimeSec,sumBMTestTimeSec' >> "$result_csv"
  printf '%s,\x27%s\x27,\x27IoTConsensus\x27,\x27%s\x27,\x27%s\x27,%s,%s,\x27%s\x27,%s,%s\n' "$(date --iso-8601=seconds)" "$testdb" "$(basename "$0")" "$result" "$elapsed" "$fail_flag" "$message" "$bm_max" "$bm_sum" >> "$result_csv"
}
stop_and_backup(){
  check_log
  timeout --preserve-status 600 bash -x "$clean_dir/stop_cluster.sh" >>"$log_file" 2>&1 || fail_flag=1
  grep -nE 'ERROR|Exception|OutOfMemoryError|FATAL' "$log_file" >"$artifact_dir/log_errors.txt" || true
  bash -x "$clean_dir/backup_cluster_logs.sh" "$run_id" >>"$log_file" 2>&1 || fail_flag=1
  write_result
}
trap stop_and_backup EXIT

log "clean environment"
bash -x "$clean_dir/stop_cluster.sh" >>"$log_file" 2>&1 || true
bash -x "$clean_dir/clean_cluster.sh" >>"$log_file" 2>&1 || fail_flag=1
bash -x "$clean_dir/reset_conf.sh" >>"$log_file" 2>&1 || fail_flag=1
bash -x "$clean_dir/clear_cache.sh" >>"$log_file" 2>&1 || true
log "start cluster"
log "configure node IP addresses and seed ConfigNode"
for node in $(cat "${cur_dir}/../conf/confignode.txt" | tr -d ' '); do
  if ! ssh "${os_user_name}@${node}" "p=${cn_db_parent_dir}/${testdb}/conf/iotdb-system.properties; env=${cn_db_parent_dir}/${testdb}/conf/confignode-env.sh; batch_set_sys_conf(){ search_str=\$1; content=\$2; if grep -q \"\$search_str\" \"\$p\"; then sed -i \"s|\$search_str|\$content|g\" \"\$p\"; else echo \"\$content\" >> \"\$p\"; fi; }; set_mem(){ k=\$1; v=\$2; if grep -qE \"^#?\${k}=\" \"\$env\"; then sed -i \"s|^#*\${k}=.*|\${k}=\\\"\${v}\\\"|\" \"\$env\"; else echo \"\${k}=\\\"\${v}\\\"\" >> \"\$env\"; fi; }; batch_set_sys_conf \".*cn_internal_address=.*\" \"cn_internal_address=${node}\"; batch_set_sys_conf \".*cn_seed_config_node=.*\" \"cn_seed_config_node=${seed_cn_ip}\"; batch_set_sys_conf \".*cluster_name=.*\" \"cluster_name=${cluster_id}\"; batch_set_sys_conf \".*schema_replication_factor=.*\" \"schema_replication_factor=${sr_rep_num}\";batch_set_sys_conf \".*data_replication_factor=.*\" \"data_replication_factor=${dr_rep_num}\"; batch_set_sys_conf \".*cn_metric_reporter_list=.*\" \"cn_metric_reporter_list=PROMETHEUS\"; batch_set_sys_conf \".*cn_metric_prometheus_reporter_port=.*\" \"cn_metric_prometheus_reporter_port=9091\"; set_mem ON_HEAP_MEMORY 2G; set_mem OFF_HEAP_MEMORY 1G" >>"$log_file" 2>&1; then
    log "ERROR failed to configure ConfigNode ${node}"; exit 1
  fi
done
for node in $(cat "${cur_dir}/../conf/datanode.txt" | tr -d ' '); do
  if ! ssh "${os_user_name}@${node}" "p=${db_parent_dir}/${testdb}/conf/iotdb-system.properties; env=${db_parent_dir}/${testdb}/conf/datanode-env.sh; batch_set_sys_conf(){ search_str=\$1; content=\$2; if grep -q \"\$search_str\" \"\$p\"; then sed -i \"s|\$search_str|\$content|g\" \"\$p\"; else echo \"\$content\" >> \"\$p\"; fi; }; set_mem(){ k=\$1; v=\$2; if grep -qE \"^#?\${k}=\" \"\$env\"; then sed -i \"s|^#*\${k}=.*|\${k}=\\\"\${v}\\\"|\" \"\$env\"; else echo \"\${k}=\\\"\${v}\\\"\" >> \"\$env\"; fi; }; batch_set_sys_conf \".*dn_internal_address=.*\" \"dn_internal_address=${node}\"; batch_set_sys_conf \".*dn_rpc_address=.*\" \"dn_rpc_address=${node}\"; batch_set_sys_conf \".*dn_seed_config_node=.*\" \"dn_seed_config_node=${seed_cn_ip}\"; batch_set_sys_conf \".*cluster_name=.*\" \"cluster_name=${cluster_id}\";batch_set_sys_conf \".*schema_replication_factor=.*\" \"schema_replication_factor=${sr_rep_num}\";batch_set_sys_conf \".*data_replication_factor=.*\" \"data_replication_factor=${dr_rep_num}\"; batch_set_sys_conf \".*dn_metric_reporter_list=.*\" \"dn_metric_reporter_list=PROMETHEUS\"; batch_set_sys_conf \".*dn_metric_prometheus_reporter_port=.*\" \"dn_metric_prometheus_reporter_port=9092\"; batch_set_sys_conf \".*ttl_check_interval=.*\" \"ttl_check_interval=20000\"; set_mem ON_HEAP_MEMORY 24G; set_mem OFF_HEAP_MEMORY 2G" >>"$log_file" 2>&1; then
    log "ERROR failed to configure DataNode ${node}"; exit 1
  fi
done
log "install license and .env on every cluster node"
for node in $(cat "${cur_dir}/../conf/datanode.txt" "${cur_dir}/../conf/confignode.txt" | tr -d ' ' | sort -u); do
  if ! ssh "${os_user_name}@${node}" "test -f ${db_parent_dir}/license_2026/license && test -f ${db_parent_dir}/license_2026/.env && mkdir -p ${db_parent_dir}/${testdb}/activation && cp -pf ${db_parent_dir}/license_2026/license ${db_parent_dir}/${testdb}/activation/license && cp -pf ${db_parent_dir}/license_2026/.env ${db_parent_dir}/${testdb}/.env && test -f ${db_parent_dir}/${testdb}/activation/license && test -f ${db_parent_dir}/${testdb}/.env" >>"$log_file" 2>&1; then
    log "ERROR failed to install license files on ${node}"
    exit 1
  fi
done
if ! timeout --preserve-status "${CLUSTER_START_TIMEOUT_SECONDS:-600}s" bash -x "$prepare_dir/start_cluster_v20.sh" 1 ${total_node_num} >>"$log_file" 2>&1; then
  log "ERROR cluster startup failed or timed out"
  exit 1
fi

benchmark_db_name="ttl_sync_lag"
benchmark_group_name_prefix=$(awk -F= '/^GROUP_NAME_PREFIX=/{gsub(/ /,"",$2);print $2}' "$benchmark_template/config.properties")
benchmark_table_name_prefix=$(awk -F= '/^IoTDB_TABLE_NAME_PREFIX=/{gsub(/ /,"",$2);print $2}' "$benchmark_template/config.properties")
db="${benchmark_db_name}_${benchmark_group_name_prefix}0"
table="${benchmark_table_name_prefix}0"
benchmark_batch_size="${BATCH_SIZE_PER_WRITE:-10}"
cli_table "create database ${db};" >>"$log_file" 2>&1 || fail_flag=1
benchmark_conf="${artifact_dir}/obj_ttl"
cp -rp "$benchmark_template" "$benchmark_conf"
sed -i "s|^HOST=.*|HOST=${query_ip}|; s|^PORT=.*|PORT=6667|; s|^USERNAME=.*|USERNAME=${db_user_name}|; s|^PASSWORD=.*|PASSWORD=${root_pw:-TimechoDB@2021}|; s|^DB_NAME=.*|DB_NAME=${benchmark_db_name}|; s|^BATCH_SIZE_PER_WRITE=.*|BATCH_SIZE_PER_WRITE=${benchmark_batch_size}|" "$benchmark_conf/config.properties"
log "benchmark config: DB_NAME=${benchmark_db_name}, actual_database=${db}, table=${table}, BATCH_SIZE_PER_WRITE=${benchmark_batch_size}"
log "run benchmark: ${benchmark_home}/benchmark.sh -cf ${benchmark_conf}"
benchmark_log="${artifact_dir}/benchmark.log"
benchmark_timeout="${BENCHMARK_TIMEOUT_SECONDS:-900}"
nohup timeout --preserve-status "${benchmark_timeout}s" "$benchmark_home/benchmark.sh" -cf "$benchmark_conf" >"$benchmark_log" 2>&1 &
benchmark_pid=$!
log "benchmark started in background pid=${benchmark_pid}, log=${benchmark_log}"
for i in $(seq 1 60); do
  cli_table "flush;" >>"$log_file" 2>&1 || fail_flag=1
  sleep 3
done
cli_table "select count(*) from ${db}.${table};" >>"$log_file" 2>&1 || true
cli_table "alter database ${db} set PROPERTIES ttl=300000;" >>"$log_file" 2>&1 || fail_flag=1
cli_table "alter table ${db}.${table} set PROPERTIES ttl=300000;" >>"$log_file" 2>&1 || fail_flag=1
#if ! wait "$benchmark_pid"; then
#  log "ERROR benchmark failed or timed out (pid=${benchmark_pid})"
#  fail_flag=1
#else
#  log "benchmark finished successfully; full log retained at ${benchmark_log}"
#fi
#if [[ -f "$benchmark_log" ]]; then
#  {
#    echo "----- benchmark.log tail (last 64 KiB; full log: ${benchmark_log}) -----"
#    tail -c 65536 "$benchmark_log"
#    echo
#    echo "----- end benchmark.log tail -----"
#  } >>"$log_file" 2>&1 || true
#fi
log "pause license on all nodes to create replication backlog"
while read -r node; do
  [[ -z "$node" ]] && continue
  ssh -n "${os_user_name}@${node}" "if test -f ${db_parent_dir}/${testdb}/activation/license; then mv ${db_parent_dir}/${testdb}/activation/license ${db_parent_dir}/${testdb}/activation/license.sync_test; fi" >>"$log_file" 2>&1 || fail_flag=1
done < <(cat "${cur_dir}/../conf/datanode.txt" "${cur_dir}/../conf/confignode.txt" | tr -d ' ' | sort -u)
sleep "${TTL_WAIT_SECONDS:-700}"
while read -r node; do
  [[ -z "$node" ]] && continue
  ssh -n "${os_user_name}@${node}" "if test -f ${db_parent_dir}/${testdb}/activation/license.sync_test; then mv ${db_parent_dir}/${testdb}/activation/license.sync_test ${db_parent_dir}/${testdb}/activation/license; fi" >>"$log_file" 2>&1 || fail_flag=1
done < <(cat "${cur_dir}/../conf/datanode.txt" "${cur_dir}/../conf/confignode.txt" | tr -d ' ' | sort -u)

if [[ -z "$prometheus_url" ]]; then log "ERROR monitor_url is missing from test.conf"; fail_flag=1; else
  deadline=$(( $(date +%s) + ${SYNC_TIMEOUT_SECONDS:-600} )); stable=0
  while (( $(date +%s) < deadline )); do
    response=$(curl -fsS -G -u admin:admin --data-urlencode "query=iot_consensus{cluster=\"${cluster_id}\",nodeType=\"DATANODE\",type=\"syncLag\"}" "${prometheus_url}/api/v1/query" 2>>"$log_file" || true)
    nonzero=$(echo "$response" | jq '[.data.result[]?.value[1] | tonumber | select(. > 0.0001)] | length' 2>/dev/null || echo 99)
    count=$(echo "$response" | jq '.data.result | length' 2>/dev/null || echo 0)
    log "syncLag series=$count nonzero=$nonzero"
    if [[ "$count" -gt 0 && "$nonzero" -eq 0 ]]; then stable=$((stable+1)); else stable=0; fi
    [[ "$stable" -ge 3 ]] && break; sleep 10
  done
  [[ "$stable" -ge 3 ]] || { log "ERROR syncLag did not converge to zero"; fail_flag=1; }
fi
log "result fail_flag=$fail_flag"
jps|grep App|awk '{"kill -9 "$1}'|sh
exit "$fail_flag"
