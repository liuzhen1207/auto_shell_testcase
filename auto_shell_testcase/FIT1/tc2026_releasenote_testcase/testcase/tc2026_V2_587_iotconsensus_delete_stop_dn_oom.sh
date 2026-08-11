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

cn_num=3
dn_num=3
total_nodes=6
cn_file="${nodeinfo_dir}/confignode_3c.txt"
dn_file="${nodeinfo_dir}/datanode_3d.txt"
cn_nodes="$(tr '\n' ' ' <"${cn_file}")"
dn_nodes="$(tr '\n' ' ' <"${dn_file}")"
seed_cn_ip="$(head -1 "${cn_file}" | tr -d ' '):10710"
query_ip="$(head -1 "${dn_file}" | tr -d ' ')"

# Default schedule reproduces V2-587 in about seven hours.
DELETE_DELAY_SECONDS="${V2_587_DELETE_DELAY_SECONDS:-600}"
FIRST_STOP_DELAY_SECONDS="${V2_587_FIRST_STOP_DELAY_SECONDS:-3600}"
DN_OFFLINE_SECONDS="${V2_587_DN_OFFLINE_SECONDS:-3600}"
DN_ONLINE_SECONDS="${V2_587_DN_ONLINE_SECONDS:-3600}"
START_TIMEOUT_SECONDS="${V2_587_START_TIMEOUT_SECONDS:-600}"
STOP_TIMEOUT_SECONDS="${V2_587_STOP_TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${V2_587_POLL_SECONDS:-5}"
MONITOR_SECONDS="${V2_587_MONITOR_SECONDS:-60}"
BM_TEST_TIME_MS="${V2_587_BM_TEST_TIME_MS:-25200000}"
CLI_SERVER_TIMEOUT="${V2_587_CLI_SERVER_TIMEOUT:-36000}"
CLI_OS_TIMEOUT_SECONDS="${V2_587_CLI_OS_TIMEOUT_SECONDS:-300}"

bm_dir="/ssd/iotdb/auto_test_shell/tc2026_releasenote_testcase/benchmark/bm_20260625_1f2d2e3_jdk17"
# 使用启动本用例的当前 shell 中实际生效的 Java，禁止再硬编码旧 Zulu 17.0.8。
# 用户通过 `sh -x script.sh` 启动时，command -v java 会继承该终端的 PATH。
java_cmd=$(command -v java 2>/dev/null || true)
java_bin=""
jdk17_home=""
if [[ -n "${java_cmd}" ]]; then
  java_bin=$(readlink -f "${java_cmd}" 2>/dev/null || echo "${java_cmd}")
  jdk17_home=$(cd "$(dirname "${java_bin}")/.." 2>/dev/null && pwd || true)
fi
stamp="$(date +%Y%m%d_%H%M%S)"
result_dir="${cur_dir}/${SCRIPT_NAME%.sh}_artifacts_${stamp}"
bm_conf_dir="${result_dir}/benchmark_conf"
bm_log_dir="${result_dir}/benchmark_logs"
log_file="${result_dir}/framework.log"
mkdir -p "${bm_conf_dir}" "${bm_log_dir}"

fail_flag=0
warn_num=0
warn_message="."
backup_done=0
cluster_started=0
test_start_epoch="$(date +%s)"
bm_pid1=""
bm_pid2=""
delete_pid=""

log() { local level="$1"; shift; echo "[$(date '+%F %T')] [${level}] $*" | tee -a "${log_file}"; }
mark_fail() { fail_flag=$((fail_flag+1)); warn_num=$((warn_num+1)); warn_message="${warn_message}$*;"; log ERROR "$*"; }

run_table() {
  local host="$1" sql="$2" out="$3"
  timeout --signal=TERM --kill-after=10s "${CLI_OS_TIMEOUT_SECONDS}s" \
    "${cli}" -u "${db_user_name}" -h "${host}" -sql_dialect table \
    -timeout "${CLI_SERVER_TIMEOUT}" -e "${sql}" >"${out}" 2>&1
}
run_tree() {
  local host="$1" sql="$2" out="$3"
  "${cli}" -u "${db_user_name}" -h "${host}" -timeout 36000 -e "${sql}" >"${out}" 2>&1
}
run_table_on_available_dn() {
  local sql="$1" out="$2" result_type="$3" preferred_host="${4:-}" host round rc attempt_out hosts
  hosts="${dn_nodes}"
  [[ -n "${preferred_host}" ]] && hosts="${preferred_host} ${dn_nodes}"
  : >"${out}"
  for round in 1 2 3; do
    local tried_hosts=" "
    for host in ${hosts}; do
      [[ "${tried_hosts}" == *" ${host} "* ]] && continue
      tried_hosts="${tried_hosts}${host} "
      ssh "${os_user_name}@${host}" "sudo jps | grep -q DataNode" 2>/dev/null || continue
      attempt_out="${out}.attempt_${round}_${host##*.}"
      run_table "${host}" "${sql}" "${attempt_out}"
      rc=$?
      cat "${attempt_out}" >"${out}"
      if (( rc == 0 )) && ! grep -Eqi 'SQLException|Exception|Error:|Msg: [0-9]+:|Socket is closed|Fail to reconnect' "${out}"; then
        if [[ "${result_type}" == query ]] && grep -q 'Total line number' "${out}"; then
          rm -f "${attempt_out}"
          return 0
        fi
        if [[ "${result_type}" == update ]] && grep -q 'executed successfully' "${out}"; then
          rm -f "${attempt_out}"
          return 0
        fi
      fi
      {
        echo "host=${host},round=${round},rc=${rc}"
        cat "${attempt_out}"
      } >>"${out}.attempts"
      rm -f "${attempt_out}"
    done
    sleep 1
  done
  return 1
}
set_property() {
  local node="$1" key="$2" value="$3"
  ssh "${os_user_name}@${node}" "f='${db_dir}/conf/iotdb-system.properties'; if grep -qE '^[# ]*${key}=' \"\$f\"; then sudo sed -i -E 's|^[# ]*${key}=.*|${key}=${value}|' \"\$f\"; else echo '${key}=${value}' | sudo tee -a \"\$f\" >/dev/null; fi"
}
write_node_files() {
  cp -p "${cn_file}" "${nodeinfo_dir}/confignode.txt"
  cp -p "${dn_file}" "${nodeinfo_dir}/datanode.txt"
}

clean_cluster() {
  log INFO "Stop cluster and clean environment"
  write_node_files
  sh -x "${clean_env_dir}/stop_cluster.sh" >>"${log_file}" 2>&1 || true
  sh -x "${clean_env_dir}/clean_cluster.sh" >>"${log_file}" 2>&1 || mark_fail "clean_cluster.sh failed"
  sh -x "${clean_env_dir}/reset_conf.sh" >>"${log_file}" 2>&1 || mark_fail "reset_conf.sh failed"
  sh -x "${clean_env_dir}/clear_cache.sh" >>"${log_file}" 2>&1 || mark_fail "clear_cache.sh failed"
  write_node_files
}

configure_cn() {
  local node="$1"
  ssh "${os_user_name}@${node}" "sudo sed -i -E 's|^[# ]*ON_HEAP_MEMORY=.*|ON_HEAP_MEMORY=\"2G\"|;s|^[# ]*OFF_HEAP_MEMORY=.*|OFF_HEAP_MEMORY=\"1G\"|' '${db_dir}/conf/confignode-env.sh'" || mark_fail "CN memory config failed: ${node}"
  set_property "${node}" cn_seed_config_node "${seed_cn_ip}"
  set_property "${node}" cn_internal_address "${node}"
  set_property "${node}" schema_replication_factor 3
  set_property "${node}" data_replication_factor 2
  set_property "${node}" schema_region_group_extension_policy CUSTOM
  set_property "${node}" data_region_group_extension_policy CUSTOM
  set_property "${node}" default_schema_region_group_num_per_database 10
  set_property "${node}" default_data_region_group_num_per_database 20
  set_property "${node}" data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus
}
configure_dn() {
  local node="$1"
  local data_dirs="data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data,/data3/iotdb_data/${testdb}/data/datanode/data"
  local wal_dirs="data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal,/data3/iotdb_data/${testdb}/data/datanode/wal"
  ssh "${os_user_name}@${node}" "sudo sed -i -E 's|^[# ]*ON_HEAP_MEMORY=.*|ON_HEAP_MEMORY=\"23G\"|;s|^[# ]*OFF_HEAP_MEMORY=.*|OFF_HEAP_MEMORY=\"2G\"|' '${db_dir}/conf/datanode-env.sh'" || mark_fail "DN memory config failed: ${node}"
  ssh "${os_user_name}@${node}" "f='${db_dir}/conf/datanode-env.sh'; sudo sed -i '/# V2_587_PARALLEL_GC_BEGIN/,/# V2_587_PARALLEL_GC_END/d' \"\$f\"; printf '%s\n' '# V2_587_PARALLEL_GC_BEGIN' 'IOTDB_JMX_OPTS=\"\$IOTDB_JMX_OPTS -XX:+UseParallelGC\"' '# V2_587_PARALLEL_GC_END' | sudo tee -a \"\$f\" >/dev/null" || mark_fail "Set ParallelGC failed: ${node}"
  set_property "${node}" dn_seed_config_node "${seed_cn_ip}"
  set_property "${node}" dn_internal_address "${node}"
  set_property "${node}" dn_rpc_address "${node}"
  set_property "${node}" schema_replication_factor 3
  set_property "${node}" data_replication_factor 2
  set_property "${node}" schema_region_group_extension_policy CUSTOM
  set_property "${node}" data_region_group_extension_policy CUSTOM
  set_property "${node}" default_schema_region_group_num_per_database 10
  set_property "${node}" default_data_region_group_num_per_database 20
  set_property "${node}" data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus
  set_property "${node}" wal_throttle_threshold_in_byte 536870912000
  set_property "${node}" enable_auto_repair_compaction false
  set_property "${node}" lz4_use_jni false
  set_property "${node}" dn_data_dirs "${data_dirs}"
  set_property "${node}" dn_wal_dirs "${wal_dirs}"
}

assert_dn_parallel_gc() {
  local node="$1" pid out
  pid="$(ssh "${os_user_name}@${node}" "sudo jps | awk '/DataNode/{print \$1; exit}'")"
  out="${result_dir}/vm_flags_dn_${node##*.}_$(date +%s).out"
  [[ -n "${pid}" ]] || { mark_fail "No DataNode PID for ParallelGC check on ${node}"; return 1; }
  ssh "${os_user_name}@${node}" "sudo jcmd '${pid}' VM.flags" >"${out}" 2>&1 || { mark_fail "jcmd VM.flags failed on ${node}"; return 1; }
  grep -q 'UseParallelGC' "${out}" || { mark_fail "UseParallelGC is not active on ${node}"; return 1; }
  log INFO "Verified -XX:+UseParallelGC on DataNode ${node}, PID=${pid}"
}
configure_cluster() {
  local n
  for n in ${cn_nodes}; do configure_cn "${n}"; done
  for n in ${dn_nodes}; do configure_dn "${n}"; done
}

wait_running_count() {
  local expected="$1" timeout="$2" start now count
  start="$(date +%s)"
  while true; do
    run_tree "${query_ip}" "show cluster" "${result_dir}/show_cluster.out" || true
    count="$(grep -c 'Running' "${result_dir}/show_cluster.out" || true)"
    [[ "${count}" -eq "${expected}" ]] && return 0
    now="$(date +%s)"
    if (( now-start > timeout )); then mark_fail "Running nodes=${count}, expected=${expected}"; return 1; fi
    sleep "${POLL_SECONDS}"
  done
}
start_cluster() {
  log INFO "Start clean 3C3D IoTConsensus cluster"
  sh -x "${prepare_env_dir}/start_cluster_v20.sh" 1 "${total_nodes}" >>"${log_file}" 2>&1 || mark_fail "start_cluster_v20.sh failed"
  cluster_started=1
  wait_running_count 6 "${START_TIMEOUT_SECONDS}"
  local node
  for node in ${dn_nodes}; do assert_dn_parallel_gc "${node}"; done
}

prepare_bm_one() {
  local name="$1" devices="$2" sensors="$3" batch="$4" hosts="$5"
  local dir="${bm_conf_dir}/${name}" password=root
  grep -q '^passwd_param=.*TimechoDB' "${db_dir}/sbin/start-cli.sh" 2>/dev/null && password='TimechoDB@2021'
  cp -rp "${bm_dir}/conf" "${dir}"
  cat >>"${dir}/config.properties" <<EOF
DB_SWITCH=IoTDB-200-SESSION_BY_TABLET
IoTDB_DIALECT_MODE=table
HOST=${hosts}
PORT=6667,6667,6667
USERNAME=root
PASSWORD=${password}
DB_NAME=${name}
IS_DELETE_DATA=false
LOOP=100000000
TEST_MAX_TIME=${BM_TEST_TIME_MS}
USE_MEASUREMENT=true
DEVICE_NUMBER=${devices}
SENSOR_NUMBER=${sensors}
IoTDB_TABLE_NAME_PREFIX=t1_
IoTDB_TABLE_NUMBER=1
DEVICE_NAME_PREFIX=d_
SENSOR_NAME_PREFIX=s_
SCHEMA_CLIENT_NUMBER=20
DATA_CLIENT_NUMBER=20
POINT_STEP=1000
RANDOM_RATIO=1
OPERATION_PROPORTION=80:1:1:1:1:0:1:1:12:1:1:0
BATCH_SIZE_PER_WRITE=${batch}
DEVICE_NUM_PER_WRITE=1
CREATE_SCHEMA=true
START_TIME=1970-01-01T08:00:00+08:00
IS_OUT_OF_ORDER=true
IS_REGULAR_FREQUENCY=true
VECTOR=true
EOF
}
start_benchmarks() {
  if [[ -z "${java_bin}" || ! -x "${java_bin}" ]]; then
    mark_fail "Java executable not found from current PATH"
    return 1
  fi
  local java_version
  java_version=$("${java_bin}" -version 2>&1 | head -1)
  if ! echo "${java_version}" | grep -Eq 'version "17([.]|"|$)|openjdk version "17([.]|"|$)'; then
    mark_fail "Benchmark requires JDK 17, current java=${java_bin}, version=${java_version}"
    return 1
  fi
  log INFO "Benchmark Java: ${java_bin}; ${java_version}"
  "${jdk17_home}/bin/java" -version >>"${log_file}" 2>&1
  prepare_bm_one db1 1000 1000 20 "192.168.130.2,192.168.130.3,192.168.130.4"
  prepare_bm_one db2 100 10000 2 "192.168.130.3,192.168.130.4,192.168.130.2"
  nohup env JAVA_HOME="${jdk17_home}" PATH="${jdk17_home}/bin:${PATH}" "${bm_dir}/benchmark.sh" -cf "${bm_conf_dir}/db1" >"${bm_log_dir}/db1.out" 2>&1 & bm_pid1=$!
  nohup env JAVA_HOME="${jdk17_home}" PATH="${jdk17_home}/bin:${PATH}" "${bm_dir}/benchmark.sh" -cf "${bm_conf_dir}/db2" >"${bm_log_dir}/db2.out" 2>&1 & bm_pid2=$!
  echo "${bm_pid1} ${bm_pid2}" >"${result_dir}/benchmark.pids"
  sleep 10
  kill -0 "${bm_pid1}" 2>/dev/null || mark_fail "db1 benchmark failed to start"
  kill -0 "${bm_pid2}" 2>/dev/null || mark_fail "db2 benchmark failed to start"
  local exe1 exe2
  exe1="$(readlink -f "/proc/${bm_pid1}/exe" 2>/dev/null || true)"
  exe2="$(readlink -f "/proc/${bm_pid2}/exe" 2>/dev/null || true)"
  log INFO "Benchmark Java executables: db1=${exe1}, db2=${exe2}"
  [[ "${exe1}" == "${java_bin}" ]] || mark_fail "db1 Benchmark Java mismatch: actual=${exe1}, expected=${java_bin}"
  [[ "${exe2}" == "${java_bin}" ]] || mark_fail "db2 Benchmark Java mismatch: actual=${exe2}, expected=${java_bin}"
}
benchmarks_alive() { kill -0 "${bm_pid1}" 2>/dev/null && kill -0 "${bm_pid2}" 2>/dev/null; }
stop_benchmarks() {
  local p
  for p in "${bm_pid1}" "${bm_pid2}"; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done
}

delete_database_devices() {
  local db="$1" max="$2" i max_time out ok=0 query_failed=0 delete_failed=0
  out="${result_dir}/delete_${db}.out"
  : >"${out}"
  for i in $(seq 0 "${max}"); do
    if ! run_table_on_available_dn "use ${db}_g_0; select time from t1_0 where device_id='d_${i}' order by time desc limit 1" "${result_dir}/delete_max_${db}.tmp" query; then
      query_failed=$((query_failed+1))
      echo "device=d_${i},stage=query_max_time,failed_on_all_running_dns" >>"${out}"
      continue
    fi
    max_time="$(grep '+08:00' "${result_dir}/delete_max_${db}.tmp" | awk -F'|' 'NF>2{gsub(/ /,"",$2);print $2;exit}')"
    [[ -z "${max_time}" ]] && continue
    if run_table_on_available_dn "use ${db}_g_0; delete from t1_0 where device_id='d_${i}' and time<=${max_time}" "${result_dir}/delete_one_${db}.tmp" update; then
      ok=$((ok+1))
    else
      delete_failed=$((delete_failed+1))
      echo "device=d_${i},stage=delete,failed_on_all_running_dns" >>"${out}"
      cat "${result_dir}/delete_one_${db}.tmp" >>"${out}"
    fi
  done
  echo "database=${db},successful_devices=${ok},query_failed=${query_failed},delete_failed=${delete_failed},expected=$((max+1))" | tee -a "${out}"
  local expected_min=90
  [[ "${db}" == db1 ]] && expected_min=900
  (( ok >= expected_min )) || mark_fail "Too few successful DELETE operations for ${db}: ${ok}, expected at least ${expected_min}"
}
start_deletion_after_delay() {
  (
    sleep "${DELETE_DELAY_SECONDS}"
    log INFO "Start DELETE workloads after ${DELETE_DELAY_SECONDS}s"
    delete_database_devices db1 999 &
    p1=$!
    delete_database_devices db2 99 &
    p2=$!
    wait "${p1}" "${p2}"
  ) &
  delete_pid=$!
}

crash_file_count() {
  local node="$1"
  ssh "${os_user_name}@${node}" "sudo find '${db_dir}' /home/${os_user_name} -maxdepth 3 -type f \( -name '*.hprof' -o -name 'hs_err_pid*.log' \) 2>/dev/null | wc -l"
}
record_crash_baseline() {
  local n suffix
  for n in ${dn_nodes}; do suffix="${n##*.}"; crash_file_count "${n}" >"${result_dir}/crash_before_${suffix}.txt"; done
}
assert_no_new_crash_files() {
  local n suffix before after
  for n in ${dn_nodes}; do
    suffix="${n##*.}"; before="$(cat "${result_dir}/crash_before_${suffix}.txt")"; after="$(crash_file_count "${n}")"
    echo "node=${n},before=${before},after=${after}" >>"${result_dir}/crash_file_counts.txt"
    (( after == before )) || mark_fail "New hprof/hs_err file found on ${n}: before=${before}, after=${after}"
  done
}
choose_query_host() {
  local excluded="$1" n
  for n in ${dn_nodes}; do [[ "${n}" != "${excluded}" ]] && { echo "${n}"; return; }; done
}
check_business_queries() {
  local tag="$1" host="$2" db out
  for db in db1 db2; do
    out="${result_dir}/query_${tag}_${db}.out"
    # Keep the availability check close to the original reproducer. The original script
    # queried one device's latest timestamp before DELETE; a full-table count(*) adds a
    # large aggregation workload that is unrelated to V2-587 and may run for hours.
    if ! run_table_on_available_dn \
      "use ${db}_g_0; select time from t1_0 where device_id='d_0' order by time desc limit 1" \
      "${out}" query "${host}"; then
      mark_fail "${db} lightweight query failed on all running DataNodes at ${tag}"
      continue
    fi
    grep -q '+08:00' "${out}" || mark_fail "${db} lightweight query returned no timestamp at ${tag}"
  done
}

stop_dn() {
  local node="$1" start now
  log INFO "Stop DataNode ${node}"
  ssh "${os_user_name}@${node}" "sudo '${db_dir}/sbin/stop-datanode.sh'" >>"${log_file}" 2>&1 || true
  start="$(date +%s)"
  while ssh "${os_user_name}@${node}" "sudo jps | grep -q DataNode"; do
    now="$(date +%s)"
    if (( now-start > STOP_TIMEOUT_SECONDS )); then mark_fail "DataNode ${node} did not stop"; return 1; fi
    sleep "${POLL_SECONDS}"
  done
  run_tree "$(choose_query_host "${node}")" "show datanodes" "${result_dir}/stopped_${node##*.}.out" || true
  grep "${node}" "${result_dir}/stopped_${node##*.}.out" | grep -q 'Unknown' || mark_fail "${node} is not Unknown after stop"
}
start_dn() {
  local node="$1" start now
  log INFO "Start DataNode ${node}"
  ssh "${os_user_name}@${node}" "cd '${db_dir}'; nohup sudo ./sbin/start-datanode.sh -H '${db_dir}/v2_587_${stamp}_${node##*.}.hprof' >/dev/null 2>&1 </dev/null &"
  start="$(date +%s)"
  while ! ssh "${os_user_name}@${node}" "sudo jps | grep -q DataNode"; do
    now="$(date +%s)"
    if (( now-start > START_TIMEOUT_SECONDS )); then mark_fail "DataNode ${node} failed to start"; return 1; fi
    sleep "${POLL_SECONDS}"
  done
  wait_running_count 6 "${START_TIMEOUT_SECONDS}"
  assert_dn_parallel_gc "${node}"
}
hold_and_monitor() {
  local seconds="$1" stopped_node="${2:-}" elapsed=0 node
  while (( elapsed < seconds )); do
    benchmarks_alive || { mark_fail "Benchmark process exited during workload hold"; return 1; }
    for node in ${dn_nodes}; do
      [[ "${node}" == "${stopped_node}" ]] && continue
      ssh "${os_user_name}@${node}" "sudo jps | grep -q DataNode" || { mark_fail "DataNode ${node} exited unexpectedly"; return 1; }
    done
    sleep "${MONITOR_SECONDS}"
    elapsed=$((elapsed+MONITOR_SECONDS))
  done
}
run_dn_rotation() {
  local node host
  log INFO "Initial online period ${FIRST_STOP_DELAY_SECONDS}s"
  hold_and_monitor "${FIRST_STOP_DELAY_SECONDS}" || return
  for node in ${dn_nodes}; do
    benchmarks_alive || { mark_fail "Benchmark exited before stopping ${node}"; return; }
    stop_dn "${node}" || return
    host="$(choose_query_host "${node}")"
    check_business_queries "offline_${node##*.}" "${host}"
    log INFO "Keep ${node} offline for ${DN_OFFLINE_SECONDS}s"
    hold_and_monitor "${DN_OFFLINE_SECONDS}" "${node}" || return
    ssh "${os_user_name}@${node}" "sudo jps | grep -q DataNode" && mark_fail "DataNode ${node} unexpectedly restarted"
    start_dn "${node}" || return
    check_business_queries "restart_${node##*.}" "${query_ip}"
    if [[ "${node}" != "$(echo "${dn_nodes}" | awk '{print $NF}')" ]]; then
      log INFO "Keep all nodes online for ${DN_ONLINE_SECONDS}s"
      hold_and_monitor "${DN_ONLINE_SECONDS}" || return
    fi
  done
}

wait_delete_and_stop_load() {
  [[ -n "${delete_pid}" ]] && wait "${delete_pid}" || true
  stop_benchmarks
  run_table_on_available_dn "flush" "${result_dir}/flush.out" update "${query_ip}" || mark_fail "Final flush failed on all running DataNodes"
  wait_running_count 6 "${START_TIMEOUT_SECONDS}"
  check_business_queries final "${query_ip}"
}
check_logs() {
  local node kind count
  local pattern='OutOfMemoryError|Java heap space|GC overhead limit exceeded|Killed process.*DataNode|NullPointerException|BufferUnderflowException|NegativeArraySizeException|DataTypeInconsistentException|INTERNAL_SERVER_ERROR'
  for node in ${dn_nodes}; do
    ssh "${os_user_name}@${node}" "sudo grep -Eh '${pattern}' '${db_dir}'/logs/*datanode*all* 2>/dev/null" >"${result_dir}/unexpected_dn_${node##*.}.log" || true
    count="$(wc -l <"${result_dir}/unexpected_dn_${node##*.}.log")"
    (( count == 0 )) || mark_fail "Unexpected/OOM DataNode log on ${node}: ${count} lines"
  done
  for node in ${cn_nodes}; do
    ssh "${os_user_name}@${node}" "sudo grep -Eh '${pattern}' '${db_dir}'/logs/*confignode*all* 2>/dev/null" >"${result_dir}/unexpected_cn_${node##*.}.log" || true
    count="$(wc -l <"${result_dir}/unexpected_cn_${node##*.}.log")"
    (( count == 0 )) || mark_fail "Unexpected ConfigNode log on ${node}: ${count} lines"
  done
}
backup_logs() {
  (( backup_done == 1 )) && return
  backup_done=1
  sh -x "${clean_env_dir}/backup_cluster_logs.sh" "$(date +%s)_${SCRIPT_NAME%.sh}" >>"${log_file}" 2>&1 || log WARN "backup_cluster_logs.sh failed"
}
write_result() {
  local end elapsed result test_time
  end="$(date +%s)"; elapsed=$((end-test_start_epoch)); result=PASS; (( fail_flag > 0 )) && result=FAIL
  test_time="$(date +'%Y-%m-%dT%H:%M:%S.%3N%:z')"
  if ! grep -q 'Time,testTimechoDB' "${CSV_FILE}" 2>/dev/null; then
    echo 'Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage' >"${CSV_FILE}"
  fi
  echo "${test_time},${testdb},IoTConsensus,${SCRIPT_NAME},${result},${elapsed},${warn_num},${warn_message}" >>"${CSV_FILE}"
  echo "testcase ${result}"
}
finalize() { stop_benchmarks; [[ -n "${delete_pid}" ]] && kill "${delete_pid}" 2>/dev/null || true; backup_logs; }
trap finalize EXIT INT TERM

: >"${log_file}"
clean_cluster
configure_cluster
if (( fail_flag == 0 )); then start_cluster; fi
if (( fail_flag == 0 )); then record_crash_baseline; start_benchmarks; start_deletion_after_delay; fi
if (( fail_flag == 0 )); then run_dn_rotation; fi
if (( cluster_started == 1 )); then wait_delete_and_stop_load; assert_no_new_crash_files; fi
log INFO "Stop cluster before final log inspection"
if (( cluster_started == 1 )); then sh -x "${clean_env_dir}/stop_cluster.sh" >>"${log_file}" 2>&1 || mark_fail "Final stop_cluster.sh failed"; fi
check_logs
backup_logs
write_result
