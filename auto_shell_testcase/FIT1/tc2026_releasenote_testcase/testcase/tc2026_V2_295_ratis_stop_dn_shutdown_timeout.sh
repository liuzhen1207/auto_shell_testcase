#!/bin/bash
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"

os_user_name="$(grep '^os_user_name' "${conf_file}" | awk -F= '{print $2}' | tr -d ' ')"
db_user_name="$(grep '^db_user_name' "${conf_file}" | awk -F= '{print $2}' | tr -d ' ')"
testdb="$(grep '^v_testdb' "${conf_file}" | awk -F= '{print $2}' | tr -d ' ')"
db_parent_dir="$(grep '^v_db_parent_dir' "${conf_file}" | awk -F= '{print $2}' | tr -d ' ')"
CSV_FILE="$(grep '^CSV_FILE' "${conf_file}" | awk -F= '{print $2}' | tr -d ' ')"

db_dir="${db_parent_dir}/${testdb}"
cli="${db_dir}/sbin/start-cli.sh"
log_file="${cur_dir}/${SCRIPT_NAME%.sh}_framework.log"
result_dir="${cur_dir}/${SCRIPT_NAME%.sh}_artifacts_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${result_dir}"

# Original V2-295 topology. Node IPs are selected by the shared framework files.
cn_num=3
dn_num=3
total_nodes=$((cn_num + dn_num))
cn_nodes="$(tr '\n' ' ' <"${nodeinfo_dir}/confignode_${cn_num}c.txt")"
dn_nodes="$(tr '\n' ' ' <"${nodeinfo_dir}/datanode_${dn_num}d.txt")"
seed_cn_ip="$(head -1 "${nodeinfo_dir}/confignode_${cn_num}c.txt" | tr -d ' '):10710"
query_ip="$(head -1 "${nodeinfo_dir}/datanode_${dn_num}d.txt" | tr -d ' ')"

# About four hours: 30m warmup + 9 * (5m stopped + 15m restarted) + final sync checks.
WARMUP_SECONDS="${V2_295_WARMUP_SECONDS:-1800}"
STOP_HOLD_SECONDS="${V2_295_STOP_HOLD_SECONDS:-300}"
RESTART_HOLD_SECONDS="${V2_295_RESTART_HOLD_SECONDS:-900}"
STOP_TIMEOUT_SECONDS="${V2_295_STOP_TIMEOUT_SECONDS:-900}"
START_TIMEOUT_SECONDS="${V2_295_START_TIMEOUT_SECONDS:-300}"
TEST_ROUNDS="${V2_295_TEST_ROUNDS:-3}"
POLL_SECONDS="${V2_295_POLL_SECONDS:-5}"
BM_TEST_TIME_MS="${V2_295_BM_TEST_TIME_MS:-18000000}"
SYNC_TIMEOUT_SECONDS="${V2_295_SYNC_TIMEOUT_SECONDS:-1800}"

bm_dir="/ssd/iotdb/auto_test_shell/tc2026_releasenote_testcase/benchmark/bm_20260625_1f2d2e3_jdk17"
bm_work_dir="${result_dir}/benchmark_conf"
bm_log_dir="${result_dir}/benchmark_logs"
mkdir -p "${bm_work_dir}" "${bm_log_dir}"

fail_flag=0
warn_num=0
warn_message="No Warn."
backup_done=0
test_start_epoch="$(date +%s)"

log() {
  local level="$1"
  shift
  echo "[$(date '+%F %T')] [${level}] $*" | tee -a "${log_file}"
}

mark_fail() {
  fail_flag=$((fail_flag + 1))
  warn_num=$((warn_num + 1))
  warn_message="${warn_message} $*"
  log ERROR "$*"
}

run_cli() {
  local host="$1"
  local sql="$2"
  local output="$3"
  "${cli}" -u "${db_user_name}" -h "${host}" -timeout 36000 -e "${sql}" >"${output}" 2>&1
}

run_cli_table() {
  local host="$1" sql="$2" output="$3"
  "${cli}" -u "${db_user_name}" -h "${host}" -sql_dialect table -timeout 36000 -e "${sql}" >"${output}" 2>&1
}

set_property() {
  local node="$1"
  local key="$2"
  local value="$3"
  ssh "${os_user_name}@${node}" "file='${db_dir}/conf/iotdb-system.properties'; if grep -qE '^[# ]*${key}=' \"\$file\"; then sudo sed -i -E 's|^[# ]*${key}=.*|${key}=${value}|' \"\$file\"; else echo '${key}=${value}' | sudo tee -a \"\$file\" >/dev/null; fi"
}

write_node_files() {
  cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
  cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"
}

stop_and_clean_cluster() {
  log INFO "Stop cluster and clean environment"
  write_node_files
  sh -x "${clean_env_dir}/stop_cluster.sh" >>"${log_file}" 2>&1 || true
  sh -x "${clean_env_dir}/clean_cluster.sh" >>"${log_file}" 2>&1 || mark_fail "clean_cluster.sh failed."
  sh -x "${clean_env_dir}/reset_conf.sh" >>"${log_file}" 2>&1 || mark_fail "reset_conf.sh failed."
  sh -x "${clean_env_dir}/clear_cache.sh" >>"${log_file}" 2>&1 || mark_fail "clear_cache.sh failed."
  write_node_files
}

configure_confignode() {
  local node="$1"
  log INFO "Configure ConfigNode ${node}"
  ssh "${os_user_name}@${node}" "sudo sed -i -E 's|^[# ]*ON_HEAP_MEMORY=.*|ON_HEAP_MEMORY=\"1G\"|; s|^[# ]*OFF_HEAP_MEMORY=.*|OFF_HEAP_MEMORY=\"1G\"|' '${db_dir}/conf/confignode-env.sh'" || mark_fail "Configure ConfigNode memory failed on ${node}."
  set_property "${node}" cn_seed_config_node "${seed_cn_ip}" || mark_fail "Set cn_seed_config_node failed on ${node}."
  set_property "${node}" cn_internal_address "${node}" || mark_fail "Set cn_internal_address failed on ${node}."
  set_property "${node}" cn_metric_reporter_list PROMETHEUS || mark_fail "Set CN metric reporter failed on ${node}."
  set_property "${node}" cn_metric_prometheus_reporter_port 9081 || mark_fail "Set CN metric port failed on ${node}."
  set_property "${node}" schema_replication_factor 3 || mark_fail "Set schema replication failed on ${node}."
  set_property "${node}" data_replication_factor 3 || mark_fail "Set data replication failed on ${node}."
  set_property "${node}" schema_region_group_extension_policy CUSTOM || mark_fail "Set schema region policy failed on ${node}."
  set_property "${node}" default_schema_region_group_num_per_database 10 || mark_fail "Set schema region count failed on ${node}."
  set_property "${node}" data_region_group_extension_policy CUSTOM || mark_fail "Set data region policy failed on ${node}."
  set_property "${node}" default_data_region_group_num_per_database 20 || mark_fail "Set data region count failed on ${node}."
  set_property "${node}" data_region_consensus_protocol_class org.apache.iotdb.consensus.ratis.RatisConsensus || mark_fail "Set Ratis consensus failed on ${node}."
}

configure_datanode() {
  local node="$1"
  local wal_dirs="data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal,/data3/iotdb_data/${testdb}/data/datanode/wal"
  if [[ "${node}" == "192.168.130.5" ]]; then
    wal_dirs="data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal"
  fi
  log INFO "Configure DataNode ${node}; wal_dirs=${wal_dirs}"
  ssh "${os_user_name}@${node}" "sudo sed -i -E 's|^[# ]*ON_HEAP_MEMORY=.*|ON_HEAP_MEMORY=\"24G\"|; s|^[# ]*OFF_HEAP_MEMORY=.*|OFF_HEAP_MEMORY=\"3G\"|' '${db_dir}/conf/datanode-env.sh'" || mark_fail "Configure DataNode memory failed on ${node}."
  set_property "${node}" dn_seed_config_node "${seed_cn_ip}" || mark_fail "Set dn_seed_config_node failed on ${node}."
  set_property "${node}" dn_internal_address "${node}" || mark_fail "Set dn_internal_address failed on ${node}."
  set_property "${node}" dn_rpc_address "${node}" || mark_fail "Set dn_rpc_address failed on ${node}."
  set_property "${node}" dn_metric_reporter_list PROMETHEUS || mark_fail "Set DN metric reporter failed on ${node}."
  set_property "${node}" dn_metric_prometheus_reporter_port 9091 || mark_fail "Set DN metric port failed on ${node}."
  set_property "${node}" schema_replication_factor 3 || mark_fail "Set schema replication failed on ${node}."
  set_property "${node}" data_replication_factor 3 || mark_fail "Set data replication failed on ${node}."
  set_property "${node}" schema_region_group_extension_policy CUSTOM || mark_fail "Set schema region policy failed on ${node}."
  set_property "${node}" default_schema_region_group_num_per_database 10 || mark_fail "Set schema region count failed on ${node}."
  set_property "${node}" data_region_group_extension_policy CUSTOM || mark_fail "Set data region policy failed on ${node}."
  set_property "${node}" default_data_region_group_num_per_database 20 || mark_fail "Set data region count failed on ${node}."
  set_property "${node}" data_region_consensus_protocol_class org.apache.iotdb.consensus.ratis.RatisConsensus || mark_fail "Set Ratis consensus failed on ${node}."
  set_property "${node}" iot_consensus_throttle_threshold_in_byte 536870912000 || mark_fail "Set throttle threshold failed on ${node}."
  set_property "${node}" dn_wal_dirs "${wal_dirs}" || mark_fail "Set WAL dirs failed on ${node}."
}

configure_cluster() {
  local node
  for node in ${cn_nodes}; do configure_confignode "${node}"; done
  for node in ${dn_nodes}; do configure_datanode "${node}"; done
}

wait_cluster_running() {
  local expected="$1"
  local timeout="$2"
  local start now running
  start="$(date +%s)"
  while true; do
    run_cli "${query_ip}" "show cluster" "${result_dir}/show_cluster.out" || true
    running="$(grep -i Running "${result_dir}/show_cluster.out" | wc -l)"
    if [[ "${running}" -eq "${expected}" ]]; then return 0; fi
    now="$(date +%s)"
    if [[ $((now - start)) -gt "${timeout}" ]]; then
      mark_fail "Cluster Running node count is ${running}, expected ${expected} within ${timeout}s."
      cat "${result_dir}/show_cluster.out" | tee -a "${log_file}"
      return 1
    fi
    sleep "${POLL_SECONDS}"
  done
}

start_cluster() {
  log INFO "Start 3C3D cluster"
  sh -x "${prepare_env_dir}/start_cluster_v20.sh" 1 "${total_nodes}" >>"${log_file}" 2>&1 || mark_fail "start_cluster_v20.sh failed."
  wait_cluster_running "${total_nodes}" "${START_TIMEOUT_SECONDS}" || return 1
  run_cli "${query_ip}" "show cluster" "${result_dir}/show_cluster_after_start.out" || true
  grep -q 'RatisConsensus' "${result_dir}/show_cluster_after_start.out" || log INFO "show cluster does not display consensus type; configuration is checked separately."
}

prepare_benchmark() {
  local password common
  cp -rp "${bm_dir}/conf" "${bm_work_dir}/tree"
  cp -rp "${bm_dir}/conf" "${bm_work_dir}/table"
  if grep -q '^passwd_param=.*TimechoDB' "${db_dir}/sbin/start-cli.sh"; then password='TimechoDB@2021'; else password='root'; fi
  common="HOST=192.168.130.2,192.168.130.3,192.168.130.5
PORT=6667,6667,6667
USERNAME=root
PASSWORD=${password}
IS_DELETE_DATA=false
LOOP=100000000
TEST_MAX_TIME=${BM_TEST_TIME_MS}
USE_MEASUREMENT=true
DEVICE_NUMBER=3000
SENSOR_NUMBER=20
SCHEMA_CLIENT_NUMBER=10
DATA_CLIENT_NUMBER=10
GROUP_NUMBER=1
POINT_STEP=1000
OP_MIN_INTERVAL=0
TIMESTAMP_PRECISION=ms
INSERT_DATATYPE_PROPORTION=1:1:1:1:1:1:1:1:1:1:0
RANDOM_RATIO=1
OPERATION_PROPORTION=91:1:1:1:1:0:1:1:1:1:1:0:0
BATCH_SIZE_PER_WRITE=1
DEVICE_NUM_PER_WRITE=1
CREATE_SCHEMA=true
START_TIME=2022-01-01T00:00:00+08:00
IS_OUT_OF_ORDER=false
IS_REGULAR_FREQUENCY=true
IS_RECENT_QUERY=true
QUERY_SENSOR_NUM=10
QUERY_DEVICE_NUM=1"
  printf '\n%s\nDB_SWITCH=IoTDB-200-SESSION_BY_TABLET\nIoTDB_DIALECT_MODE=tree\nDB_NAME=v2_295_tree\nGROUP_NAME_PREFIX=g_\nDEVICE_NAME_PREFIX=d_\nSENSOR_NAME_PREFIX=s_\n' "${common}" >>"${bm_work_dir}/tree/config.properties"
  printf '\n%s\nDB_SWITCH=IoTDB-200-SESSION_BY_TABLET\nIoTDB_DIALECT_MODE=table\nDB_NAME=v2_295_table\nIoTDB_TABLE_NAME_PREFIX=table_\nIoTDB_TABLE_NUMBER=10\nTAG_NUMBER=2\nTAG_KEY_PREFIX=tag_\nTAG_VALUE_PREFIX=value_\nTAG_VALUE_CARDINALITY=50,50\nDEVICE_NAME_PREFIX=d_\nSENSOR_NAME_PREFIX=s_\n' "${common}" >>"${bm_work_dir}/table/config.properties"
}

start_benchmark() {
  prepare_benchmark
  log INFO "Start JDK17 Tree and Table benchmark workloads"
  nohup "${bm_dir}/benchmark.sh" -cf "${bm_work_dir}/tree" >"${bm_log_dir}/tree.out" 2>&1 &
  bm_pid1=$!
  nohup "${bm_dir}/benchmark.sh" -cf "${bm_work_dir}/table" >"${bm_log_dir}/table.out" 2>&1 &
  bm_pid2=$!
  echo "${bm_pid1} ${bm_pid2}" >"${result_dir}/benchmark.pids"
  sleep 10
  kill -0 "${bm_pid1}" 2>/dev/null || mark_fail "Tree Benchmark failed to start."
  kill -0 "${bm_pid2}" 2>/dev/null || mark_fail "Table Benchmark failed to start."
}

benchmark_alive() {
  local pid alive=0
  for pid in $(cat "${result_dir}/benchmark.pids" 2>/dev/null); do
    if kill -0 "${pid}" 2>/dev/null; then alive=$((alive + 1)); fi
  done
  [[ "${alive}" -eq 2 ]]
}

count_crash_files() {
  local node="$1"
  ssh "${os_user_name}@${node}" "find /home/${os_user_name} '${db_dir}' -maxdepth 2 -type f \( -name 'hs_err_pid*.log' -o -name '*.hprof' \) 2>/dev/null | wc -l"
}

collect_thread_dump() {
  local node="$1"
  local pid="$2"
  local tag="$3"
  ssh "${os_user_name}@${node}" "sudo jstack -l '${pid}' > '${db_dir}/${tag}_jstack.log' 2>&1 || sudo jcmd '${pid}' Thread.print > '${db_dir}/${tag}_jstack.log' 2>&1 || true"
}

stop_datanode_with_timeout() {
  local node="$1"
  local round="$2"
  local start now elapsed pid before_crash after_crash stop_log
  before_crash="$(count_crash_files "${node}")"
  pid="$(ssh "${os_user_name}@${node}" "sudo jps | awk '/DataNode/{print \$1; exit}'")"
  if [[ -z "${pid}" ]]; then mark_fail "Round ${round}: no DataNode PID on ${node}."; return 1; fi
  stop_log="${db_dir}/v2_295_stop_round${round}_$(echo "${node}" | awk -F. '{print $4}').log"
  log INFO "Round ${round}: stop DataNode ${node}, PID=${pid}"
  ssh "${os_user_name}@${node}" "nohup sudo '${db_dir}/sbin/stop-datanode.sh' >'${stop_log}' 2>&1 </dev/null &" || mark_fail "Round ${round}: failed to invoke stop-datanode on ${node}."
  start="$(date +%s)"
  while ssh "${os_user_name}@${node}" "sudo jps | grep -q DataNode"; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "${elapsed}" -gt "${STOP_TIMEOUT_SECONDS}" ]]; then
      collect_thread_dump "${node}" "${pid}" "v2_295_round${round}_stop_timeout"
      mark_fail "Round ${round}: DataNode ${node} did not exit within ${STOP_TIMEOUT_SECONDS}s."
      ssh "${os_user_name}@${node}" "sudo kill -9 '${pid}'" || true
      break
    fi
    sleep "${POLL_SECONDS}"
  done
  now="$(date +%s)"
  elapsed=$((now - start))
  echo "round=${round},node=${node},stop_seconds=${elapsed}" | tee -a "${result_dir}/stop_durations.csv"
  ssh "${os_user_name}@${node}" "cat '${stop_log}'" >"${result_dir}/stop_round${round}_$(echo "${node}" | awk -F. '{print $4}').log" 2>&1 || true
  after_crash="$(count_crash_files "${node}")"
  if [[ "${after_crash}" -gt "${before_crash}" ]]; then mark_fail "Round ${round}: new hs_err/hprof file found on ${node}."; fi
  if grep -Eqi 'shutdown timeout|Failed to shutdown serverExecutor|Failed to shutdown executor|spent [0-9]+s to wait for closing all TsFiles' "${result_dir}/stop_round${round}_$(echo "${node}" | awk -F. '{print $4}').log"; then
    mark_fail "Round ${round}: shutdown timeout/wait warning found for ${node}."
  fi
  return 0
}

start_datanode_and_wait() {
  local node="$1"
  local round="$2"
  local start now
  log INFO "Round ${round}: restart DataNode ${node}"
  ssh "${os_user_name}@${node}" "cd '${db_dir}'; nohup sudo ./sbin/start-datanode.sh -H '${db_dir}/v2_295_round${round}.hprof' >/dev/null 2>&1 </dev/null &" || mark_fail "Round ${round}: failed to start DataNode ${node}."
  start="$(date +%s)"
  while true; do
    if ssh "${os_user_name}@${node}" "sudo jps | grep -q DataNode"; then break; fi
    now="$(date +%s)"
    if [[ $((now - start)) -gt "${START_TIMEOUT_SECONDS}" ]]; then mark_fail "Round ${round}: DataNode ${node} failed to restart."; return 1; fi
    sleep "${POLL_SECONDS}"
  done
  wait_cluster_running "${total_nodes}" "${START_TIMEOUT_SECONDS}" || return 1
}

choose_healthy_query_ip() {
  local excluded_node="$1"
  local candidate probe
  for candidate in ${dn_nodes}; do
    [[ "${candidate}" == "${excluded_node}" ]] && continue
    probe="${result_dir}/query_host_probe_$(echo "${candidate}" | awk -F. '{print $4}').out"
    if run_cli "${candidate}" "show cluster" "${probe}" && ! grep -Eqi 'Exception|Error:' "${probe}"; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

check_query_result() {
  local tag="$1"
  local query_host="${2:-${query_ip}}"
  local tree_output="${result_dir}/query_tree_${tag}.out"
  local table_output="${result_dir}/query_table_${tag}.out"
  run_cli "${query_host}" "show devices root.v2_295_tree.** limit 10" "${tree_output}" || mark_fail "Tree query failed at ${tag} via ${query_host}."
  run_cli_table "${query_host}" "use v2_295_table; show devices from table_0 limit 10" "${table_output}" || mark_fail "Table query failed at ${tag} via ${query_host}."
  if grep -Eqi 'Exception|Error:' "${tree_output}" || ! grep -q 'root.v2_295_tree' "${tree_output}"; then mark_fail "Tree query returned no valid data at ${tag}."; fi
  if grep -Eqi 'Exception|Error:' "${table_output}" || ! grep -q 'd_' "${table_output}"; then mark_fail "Table query returned no valid data at ${tag}."; fi
}

run_stop_restart_cycles() {
  local round node suffix active_query_ip
  log INFO "Warm up workload for ${WARMUP_SECONDS}s"
  sleep "${WARMUP_SECONDS}"
  check_query_result warmup
  round=1
  while [[ "${round}" -le "${TEST_ROUNDS}" ]]; do
    for node in ${dn_nodes}; do
      benchmark_alive || { mark_fail "Benchmark ended before round ${round}, node ${node}."; return; }
      stop_datanode_with_timeout "${node}" "${round}"
      suffix="$(echo "${node}" | awk -F. '{print $4}')"
      sleep "${STOP_HOLD_SECONDS}"
      active_query_ip="$(choose_healthy_query_ip "${node}")"
      if [[ -z "${active_query_ip}" ]]; then
        mark_fail "Round ${round}: no healthy query DataNode while ${node} is stopped."
      else
        log INFO "Round ${round}: query through healthy DataNode ${active_query_ip} while ${node} is stopped"
        check_query_result "round${round}_stop_${suffix}" "${active_query_ip}"
      fi
      start_datanode_and_wait "${node}" "${round}"
      sleep "${RESTART_HOLD_SECONDS}"
      check_query_result "round${round}_restart_${suffix}"
    done
    round=$((round + 1))
  done
}

normalize_cli_result() {
  grep '|' "$1" | sed 's/[[:space:]]//g'
}

wait_sync_and_check_replica_consistency() {
  local start now stable=0 node suffix tree_file table_file base_tree base_table
  log INFO "Stop benchmarks and wait for Tree/Table replicas to converge"
  stop_benchmark
  run_cli "${query_ip}" "flush" "${result_dir}/flush_tree.out" || mark_fail "Tree flush failed."
  run_cli_table "${query_ip}" "flush" "${result_dir}/flush_table.out" || mark_fail "Table flush failed."
  wait_cluster_running "${total_nodes}" "${START_TIMEOUT_SECONDS}" || return 1
  start="$(date +%s)"
  while true; do
    base_tree=""; base_table=""; stable=$((stable + 1))
    for node in ${dn_nodes}; do
      suffix="$(echo "${node}" | awk -F. '{print $4}')"
      tree_file="${result_dir}/consistent_tree_${suffix}.out"
      table_file="${result_dir}/consistent_table_${suffix}.out"
      run_cli "${node}" "select count(*) from root.v2_295_tree.**" "${tree_file}" || stable=0
      run_cli_table "${node}" "use v2_295_table; select count(*) from table_0" "${table_file}" || stable=0
      grep -Eqi 'Exception|Error:' "${tree_file}" "${table_file}" && stable=0
      if [[ -z "${base_tree}" ]]; then
        base_tree="${tree_file}"; base_table="${table_file}"
      else
        base_tree_normalized="${result_dir}/consistent_tree_base.normalized"
        tree_normalized="${result_dir}/consistent_tree_${suffix}.normalized"
        base_table_normalized="${result_dir}/consistent_table_base.normalized"
        table_normalized="${result_dir}/consistent_table_${suffix}.normalized"
        normalize_cli_result "${base_tree}" > "${base_tree_normalized}"
        normalize_cli_result "${tree_file}" > "${tree_normalized}"
        normalize_cli_result "${base_table}" > "${base_table_normalized}"
        normalize_cli_result "${table_file}" > "${table_normalized}"
        diff "${base_tree_normalized}" "${tree_normalized}" >/dev/null || stable=0
        diff "${base_table_normalized}" "${table_normalized}" >/dev/null || stable=0
      fi
    done
    if [[ "${stable}" -ge 3 ]]; then
      log INFO "Tree/Table replica query results are identical on all DataNodes for 3 consecutive checks"
      return 0
    fi
    now="$(date +%s)"
    if [[ $((now - start)) -gt "${SYNC_TIMEOUT_SECONDS}" ]]; then
      mark_fail "Tree/Table replicas did not converge within ${SYNC_TIMEOUT_SECONDS}s."
      return 1
    fi
    [[ "${stable}" -lt 0 ]] && stable=0
    sleep 30
  done
}

check_logs() {
  local node count pattern
  pattern='shutdown timeout in 1day|ThreadPoolExecutor shutdown timeout|Failed to shutdown serverExecutor|Failed to shutdown executor|spent [0-9]+s to wait for closing all TsFiles|NullPointerException|OutOfMemoryError|BufferUnderflowException|DataTypeInconsistentException|NegativeArraySizeException|has overlapped data|INTERNAL_SERVER_ERROR'
  for node in ${dn_nodes}; do
    ssh "${os_user_name}@${node}" "grep -Eh '${pattern}' '${db_dir}'/logs/*datanode*all* 2>/dev/null" >"${result_dir}/unexpected_shutdown_${node}.log" || true
    count="$(wc -l <"${result_dir}/unexpected_shutdown_${node}.log")"
    if [[ "${count}" -gt 0 ]]; then mark_fail "Unexpected DataNode log found on ${node}: ${count} lines."; fi
  done
  for node in ${cn_nodes}; do
    ssh "${os_user_name}@${node}" "grep -Eh '${pattern}' '${db_dir}'/logs/*confignode*all* 2>/dev/null" >"${result_dir}/unexpected_confignode_${node}.log" || true
    count="$(wc -l <"${result_dir}/unexpected_confignode_${node}.log")"
    if [[ "${count}" -gt 0 ]]; then mark_fail "Unexpected ConfigNode log found on ${node}: ${count} lines."; fi
  done
}

backup_logs() {
  if [[ "${backup_done}" -eq 1 ]]; then return; fi
  backup_done=1
  local stamp
  stamp="$(date +%s)_${SCRIPT_NAME%.sh}"
  log INFO "Backup cluster logs: ${stamp}"
  sh -x "${clean_env_dir}/backup_cluster_logs.sh" "${stamp}" >>"${log_file}" 2>&1 || log WARN "backup_cluster_logs.sh returned non-zero."
}

stop_benchmark() {
  local pid
  for pid in $(cat "${result_dir}/benchmark.pids" 2>/dev/null); do kill "${pid}" 2>/dev/null || true; done
  sleep 5
}

write_result() {
  local end elapsed test_time result bm_max bm_sum
  end="$(date +%s)"
  elapsed=$((end - test_start_epoch))
  test_time="$(date +'%Y-%m-%dT%H:%M:%S.%3N%:z')"
  result=PASS
  [[ "${fail_flag}" -gt 0 ]] && result=FAIL
  bm_max="$(grep -h 'Test elapsed' "${bm_log_dir}"/*.out 2>/dev/null | awk '{print $8}' | sort -n | tail -1)"
  bm_sum="$(grep -h 'Test elapsed' "${bm_log_dir}"/*.out 2>/dev/null | awk '{sum+=$8} END{print sum+0}')"
  if ! grep -q 'Time,testTimechoDB' "${CSV_FILE}" 2>/dev/null; then
    echo 'Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage,maxBMTestTimeSec,sumBMTestTimeSec' >"${CSV_FILE}"
  fi
  echo "${test_time},${testdb},RatisConsensus,${SCRIPT_NAME},${result},${elapsed},${warn_num},${warn_message},${bm_max:-0},${bm_sum:-0}" >>"${CSV_FILE}"
  if [[ "${result}" == PASS ]]; then echo 'testcase1 pass'; else echo 'testcase1 fail'; fi
}

finalize() {
  stop_benchmark
  backup_logs
}
trap finalize EXIT INT TERM

: >"${log_file}"
stop_and_clean_cluster
configure_cluster
if [[ "${fail_flag}" -eq 0 ]]; then start_cluster; fi
if [[ "${fail_flag}" -eq 0 ]]; then start_benchmark; fi
if [[ "${fail_flag}" -eq 0 ]]; then run_stop_restart_cycles; fi
if [[ "${fail_flag}" -eq 0 ]]; then wait_sync_and_check_replica_consistency; else stop_benchmark; fi
log INFO "Stop cluster before final log inspection"
sh -x "${clean_env_dir}/stop_cluster.sh" >>"${log_file}" 2>&1 || mark_fail "stop_cluster.sh failed before log inspection."
check_logs
backup_logs
write_result
