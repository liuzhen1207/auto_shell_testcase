#!/bin/bash
set -uo pipefail

# V1-520: aligned WAL recovery must not materialize null arrays for untouched columns.
# Set v_testdb/v_db_parent_dir in ../conf/test.conf, then run this script without arguments.

cur_dir="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"
prepare_env_dir="${cur_dir}/../prepare_env"
os_user_name=$(awk -F= '/^os_user_name=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
db_user_name=$(awk -F= '/^db_user_name=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
testdb=$(awk -F= '/^v_testdb=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
db_parent_dir=$(awk -F= '/^v_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
root_pw=$(awk -F= '/^root_pw=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
monitor_url=$(awk -F= '/^monitor_url=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
CSV_FILE=$(awk -F= '/^CSV_FILE=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
db_dir="${db_parent_dir}/${testdb}"
cli_dir="${db_dir}"
cn_file="${nodeinfo_dir}/confignode_3c.txt"
dn_file="${nodeinfo_dir}/datanode_3d.txt"
query_ip=$(head -n 1 "${dn_file}" | tr -d ' ')
seed_cn_ip=$(head -n 1 "${cn_file}" | tr -d ' '):10710

ROW_COUNT=${V1_520_ROW_COUNT:-600000}
COLUMN_COUNT=${V1_520_COLUMN_COUNT:-1024}
BATCH_ROWS=${V1_520_BATCH_ROWS:-500}
RESTART_TIMEOUT=${V1_520_RESTART_TIMEOUT:-300}
SYNC_TIMEOUT=${V1_520_SYNC_TIMEOUT:-900}
EXPECTED_REPLICA_COUNT=2
DB_NAME=root.v1_520
DEVICE=${DB_NAME}.d
run_id="$(date +%Y%m%d_%H%M%S)"
artifact_dir="${cur_dir}/V1_520_${run_id}"
log_file="${artifact_dir}/test.log"
fail_flag=0
v_warnNum=0
v_warnMessage="."
result_written=0
test_begin_sec=$(date +%s)

mkdir -p "${artifact_dir}"

log() {
  local level=$1
  shift
  printf '[%s] [%s] %s\n' "$(date '+%F %T')" "${level}" "$*" | tee -a "${log_file}"
}

fail() {
  fail_flag=$((fail_flag + 1))
  v_warnMessage="${v_warnMessage}$*."
  log ERROR "$*"
}

write_result() {
  local exit_code=$1
  local test_time elapsed result
  (( result_written == 0 )) || return 0
  result_written=1
  [[ -n "${CSV_FILE}" ]] || CSV_FILE=test_result.csv
  test_time=$(date +"%Y-%m-%dT%H:%M:%S.%3N%:z")
  elapsed=$(( $(date +%s) - test_begin_sec ))
  result=PASS
  if (( exit_code != 0 || fail_flag > 0 )); then
    result=FAIL
  fi
  if [[ ! -f "${CSV_FILE}" ]] || ! grep -q "Time,testTimechoDB" "${CSV_FILE}"; then
    echo "Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage,maxBMTestTimeSec,sumBMTestTimeSec" >>"${CSV_FILE}"
  fi
  echo "${test_time},${testdb},IoTConsensus,${SCRIPT_NAME},${result},${elapsed},${v_warnNum},${v_warnMessage},0,0" >>"${CSV_FILE}"
  log INFO "Result written to ${CSV_FILE}: ${result}, elapsed=${elapsed}s"
}

on_exit() {
  local exit_code=$?
  trap - EXIT
  write_result "${exit_code}"
  exit "${exit_code}"
}

trap on_exit EXIT

validate_scope() {
  case "${db_dir}" in
    /data2/v1*|/data2/iotdb-enterprise-*|/data2/v2*|/data2/V2*) ;;
    *)
      log ERROR "Refusing destructive cleanup outside an explicit V1 installation: ${db_dir}"
      exit 2
      ;;
  esac
  [[ -d "${db_dir}" ]] || { log ERROR "Missing install directory: ${db_dir}"; exit 2; }
  for node in 192.168.130.2 192.168.130.3 192.168.130.4; do
    grep -qx "${node}" "${cn_file}" || { log ERROR "CN list is not the expected 3C3D topology"; exit 2; }
    grep -qx "${node}" "${dn_file}" || { log ERROR "DN list is not the expected 3C3D topology"; exit 2; }
  done
}

remote_jps_pid() {
  local node=$1
  local process_name=$2
  ssh -n "${os_user_name}@${node}" "source /etc/profile; sudo jps -l | awk '/${process_name}/ {print \$1}'"
}

stop_process() {
  local node=$1
  local process_name=$2
  local stop_script=$3
  ssh -n "${os_user_name}@${node}" "source /etc/profile; sudo ${db_dir}/sbin/${stop_script}" >>"${log_file}" 2>&1 || true
  local start now pid
  start=$(date +%s)
  while true; do
    pid=$(remote_jps_pid "${node}" "${process_name}" | head -n 1)
    [[ -z "${pid}" ]] && return 0
    now=$(date +%s)
    if (( now - start > 120 )); then
      ssh -n "${os_user_name}@${node}" "sudo kill -9 ${pid}" >>"${log_file}" 2>&1 || true
      return 0
    fi
    sleep 2
  done
}

stop_cluster() {
  log INFO "Stopping cluster through framework clean_env/stop_cluster.sh"
  cp -f "${cn_file}" "${nodeinfo_dir}/confignode.txt"
  cp -f "${dn_file}" "${nodeinfo_dir}/datanode.txt"
  sh -x "${cur_dir}/../clean_env/stop_cluster.sh" >>"${log_file}" 2>&1
}

clean_cluster_data() {
  log INFO "Cleaning cluster through framework clean_cluster/reset_conf/clear_cache"
  sh -x "${cur_dir}/../clean_env/clean_cluster.sh" >>"${log_file}" 2>&1
  sh -x "${cur_dir}/../clean_env/reset_conf.sh" >>"${log_file}" 2>&1
  if [[ -x "${cur_dir}/../clean_env/clear_cache.sh" ]]; then
    sh -x "${cur_dir}/../clean_env/clear_cache.sh" >>"${log_file}" 2>&1
  fi
}

set_property() {
  local node=$1
  local key=$2
  local value=$3
  ssh -n "${os_user_name}@${node}" "sudo sed -i '/^[# ]*${key}=/d' '${db_dir}/conf/iotdb-system.properties'; echo '${key}=${value}' | sudo tee -a '${db_dir}/conf/iotdb-system.properties' >/dev/null"
}

configure_cluster() {
  log INFO "Restoring conf_orig and configuring 3C3D IoTConsensus"
  while read -r node; do
    ssh -n "${os_user_name}@${node}" "if [ -d '${db_dir}/conf_orig' ]; then sudo rm -rf '${db_dir}/conf'; sudo cp -a '${db_dir}/conf_orig' '${db_dir}/conf'; fi" >>"${log_file}" 2>&1
    set_property "${node}" cn_seed_config_node "${seed_cn_ip}"
    set_property "${node}" cn_internal_address "${node}"
    set_property "${node}" schema_replication_factor 3
    set_property "${node}" data_replication_factor "${EXPECTED_REPLICA_COUNT}"
    set_property "${node}" data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus
    set_property "${node}" dn_seed_config_node "${seed_cn_ip}"
    set_property "${node}" dn_internal_address "${node}"
    set_property "${node}" dn_rpc_address "${node}"
    set_property "${node}" dn_metric_reporter_list PROMETHEUS
    set_property "${node}" dn_metric_prometheus_reporter_port 9091
    set_property "${node}" wal_mode SYNC
    set_property "${node}" enable_mem_control true
    set_property "${node}" enable_seq_space_compaction false
    set_property "${node}" enable_unseq_space_compaction false
    set_property "${node}" enable_cross_space_compaction false
    ssh -n "${os_user_name}@${node}" "sudo sed -i -E 's/^#?[[:space:]]*ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY=\"4G\"/' '${db_dir}/conf/datanode-env.sh'" >>"${log_file}" 2>&1 || true
  done <"${cn_file}"
}

start_cluster() {
  log INFO "Starting 3C3D through prepare_env/start_cluster_v13.sh"
  cp -f "${cn_file}" "${nodeinfo_dir}/confignode.txt"
  cp -f "${dn_file}" "${nodeinfo_dir}/datanode.txt"
  if ! timeout 360 sh -x "${prepare_env_dir}/start_cluster_v13.sh" 1 6 >>"${log_file}" 2>&1; then
    fail "Framework start_cluster_v13.sh failed or exceeded 360s"
    collect_startup_diagnostics
    return 1
  fi
  wait_cluster_nodes 6 60 || {
    fail "Framework returned but cluster did not report 6 Running nodes"
    collect_startup_diagnostics
    return 1
  }
}

collect_startup_diagnostics() {
  local node suffix
  while read -r node; do
    suffix=${node##*.}
    ssh -n "${os_user_name}@${node}" "source /etc/profile; sudo jps -l; sudo tail -100 '${db_dir}/logs/log_confignode_all.log' 2>/dev/null; sudo tail -100 '${db_dir}/logs/log_datanode_all.log' 2>/dev/null" \
      >"${artifact_dir}/startup_${suffix}.log" 2>&1 || true
  done <"${cn_file}"
}

cli() {
  local host=$1
  local sql=$2
  "${cli_dir}/sbin/start-cli.sh" -h "${host}" -u "${db_user_name}" -pw "${root_pw}" -timeout 600000 -e "${sql}"
}

wait_cluster_nodes() {
  local expected=$1
  local timeout=$2
  local begin now count
  begin=$(date +%s)
  while true; do
    count=$(cli "${query_ip}" "show cluster" 2>/dev/null | grep -c Running || true)
    (( count >= expected )) && return 0
    now=$(date +%s)
    (( now - begin > timeout )) && return 1
    sleep 2
  done
}

record_build() {
  local out="${artifact_dir}/show_version.out"
  cli "${query_ip}" "show version" >"${out}" 2>&1 || true
  cat "${out}" | tee -a "${log_file}"
  log INFO "Deployment under test is read from test.conf: ${db_dir}"
}

generate_schema_sql() {
  local sql="CREATE ALIGNED TIMESERIES ${DEVICE}("
  local i
  for ((i=0; i<COLUMN_COUNT; i++)); do
    (( i > 0 )) && sql+=","
    sql+="s${i} INT64 ENCODING=RLE"
  done
  sql+=")"
  printf '%s' "${sql}"
}

write_sparse_rows() {
  local begin=1
  local end i sql
  log INFO "Writing ${ROW_COUNT} aligned rows containing only s0, batch=${BATCH_ROWS}"
  while (( begin <= ROW_COUNT )); do
    end=$((begin + BATCH_ROWS - 1))
    (( end > ROW_COUNT )) && end=${ROW_COUNT}
    sql="INSERT INTO ${DEVICE}(time,s0) ALIGNED VALUES"
    for ((i=begin; i<=end; i++)); do
      (( i > begin )) && sql+=","
      sql+="(${i},${i})"
    done
    cli "${query_ip}" "${sql}" >>"${artifact_dir}/write_sparse.out" 2>&1 || { fail "Sparse batch ${begin}-${end} failed"; return 1; }
    (( begin % 10000 == 1 )) && log INFO "Sparse rows written through ${end}"
    begin=$((end + 1))
  done
}

write_wide_row() {
  local measurements="time"
  local values="$((ROW_COUNT + 1))"
  local i
  for ((i=0; i<COLUMN_COUNT; i++)); do
    measurements+=",s${i}"
    values+=",$((ROW_COUNT + 1 + i))"
  done
  log INFO "Writing one aligned row containing ${COLUMN_COUNT} columns"
  cli "${query_ip}" "INSERT INTO ${DEVICE}(${measurements}) ALIGNED VALUES(${values})" >"${artifact_dir}/write_wide.out" 2>&1 || fail "Wide-row write failed"
}

find_region_dn() {
  local out="${artifact_dir}/show_regions_before_restart.out"
  cli "${query_ip}" "show regions" >"${out}" 2>&1
  awk -F'|' -v db="${DB_NAME}" '
    $0 ~ db && $0 ~ /DataRegion/ && $0 ~ /Leader/ {
      for (i=1; i<=NF; i++) {
        gsub(/ /, "", $i)
        if ($i ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) { print $i; exit }
      }
    }
  ' "${out}"
}

kill_datanode_for_wal_recovery() {
  local node=$1
  local pid
  pid=$(remote_jps_pid "${node}" DataNode | head -n 1)
  [[ -n "${pid}" ]] || { fail "No DataNode PID found on ${node}"; return 1; }
  log INFO "Killing DataNode ${node} PID ${pid} to force WAL recovery"
  ssh -n "${os_user_name}@${node}" "sudo kill -9 ${pid}"
  sleep 3
}

start_one_dn_and_measure() {
  local node=$1
  local begin now elapsed running=0
  begin=$(date +%s)
  ssh -n "${os_user_name}@${node}" "source /etc/profile; sudo ${db_dir}/sbin/start-datanode.sh -H ${db_dir}/dn_v1_520_${run_id}.hprof >/dev/null 2>&1 &"
  while true; do
    if cli "${query_ip}" "show datanodes" 2>/dev/null | grep "${node}" | grep -q Running; then
      running=1
      break
    fi
    now=$(date +%s)
    if (( now - begin > RESTART_TIMEOUT )); then break; fi
    ssh -n "${os_user_name}@${node}" "ps -o pid,etime,%cpu,%mem,rss,vsz,nlwp,cmd -p \$(sudo jps -l | awk '/DataNode/{print \$1; exit}')" >>"${artifact_dir}/restart_${node}.samples" 2>&1 || true
    sleep 5
  done
  elapsed=$(( $(date +%s) - begin ))
  printf 'node=%s restart_seconds=%s running=%s\n' "${node}" "${elapsed}" "${running}" | tee "${artifact_dir}/restart_result.out" | tee -a "${log_file}"
  (( running == 1 )) || fail "DataNode restart exceeded ${RESTART_TIMEOUT}s"
  (( running == 1 ))
}

wait_sync_zero() {
  local begin now response values nonzero samples zero_since=0
  begin=$(date +%s)
  while true; do
    response=$(curl -s -u admin:admin --get --data-urlencode 'query=sum(iot_consensus{name="ioTConsensusServerImpl",type="syncLag"}) by (instance)' "${monitor_url}/api/v1/query")
    printf '%s\n' "${response}" >"${artifact_dir}/sync_lag_latest.json"
    values=$(printf '%s' "${response}" | grep -o '"value":\[[^]]*,"[^"]*"\]' | sed -E 's/.*,"([^"]*)".*/\1/' || true)
    samples=$(printf '%s\n' "${values}" | awk 'NF{n++} END{print n+0}')
    nonzero=$(printf '%s\n' "${values}" | awk '$1+0 > 0.0001{n++} END{print n+0}')
    now=$(date +%s)
    if (( samples >= EXPECTED_REPLICA_COUNT && nonzero == 0 )); then
      (( zero_since == 0 )) && zero_since=${now}
      (( now - zero_since >= 60 )) && { log INFO "syncLag remained zero for 60s"; return 0; }
    else
      zero_since=0
    fi
    (( now - begin > SYNC_TIMEOUT )) && { fail "syncLag did not become zero within ${SYNC_TIMEOUT}s"; return 1; }
    sleep 10
  done
}

normalize_query() {
  grep '^|' "$1" | tr -d ' \r'
}

query_counts() {
  local host=$1
  local out=$2
  cli "${host}" "select count(s0),count(s1),count(s$((COLUMN_COUNT-1))) from ${DEVICE}" >"${out}" 2>&1
  normalize_query "${out}" >"${out}.norm"
}

choose_query_host() {
  local stopped=$1
  while read -r node; do [[ "${node}" != "${stopped}" ]] && { echo "${node}"; return; }; done <"${dn_file}"
}

verify_replica_consistency() {
  local baseline="${artifact_dir}/baseline_all_online.out"
  local node host suffix pid
  query_counts "${query_ip}" "${baseline}" || fail "Baseline query failed"
  log INFO "Baseline: $(cat "${baseline}.norm")"
  while read -r node; do
    suffix=${node##*.}
    pid=$(remote_jps_pid "${node}" DataNode | head -n 1)
    log INFO "Stopping DN ${node} for replica query comparison"
    ssh -n "${os_user_name}@${node}" "sudo ${db_dir}/sbin/stop-datanode.sh" >>"${log_file}" 2>&1 || true
    sleep 3
    pid=$(remote_jps_pid "${node}" DataNode | head -n 1)
    [[ -n "${pid}" ]] && ssh -n "${os_user_name}@${node}" "sudo kill -9 ${pid}" || true
    host=$(choose_query_host "${node}")
    query_counts "${host}" "${artifact_dir}/stop_dn_${suffix}.out" || fail "Query failed with ${node} stopped"
    if ! diff -u "${baseline}.norm" "${artifact_dir}/stop_dn_${suffix}.out.norm" >"${artifact_dir}/stop_dn_${suffix}.diff"; then
      fail "Replica result differs when ${node} is stopped"
    fi
    start_one_dn_and_measure "${node}" || { fail "Could not restart ${node} during replica checks"; return 1; }
    wait_sync_zero || return 1
  done <"${dn_file}"
}

check_logs() {
  local node suffix count
  while read -r node; do
    suffix=${node##*.}
    ssh -n "${os_user_name}@${node}" "sudo grep -hEi 'OutOfMemoryError|Java heap space|WAL.*(recover|replay).*(fail|error)|NegativeArraySizeException|GC overhead limit|Exception during recovery' ${db_dir}/logs/log_datanode_all.log* 2>/dev/null" >"${artifact_dir}/dn_${suffix}_errors.log" || true
    count=$(wc -l <"${artifact_dir}/dn_${suffix}_errors.log")
    if (( count > 0 )); then
      fail "DN ${node} contains ${count} fatal WAL/memory log lines"
    fi
  done <"${dn_file}"
}

main() {
  validate_scope
  stop_cluster
  clean_cluster_data
  configure_cluster
  start_cluster || exit 1
  record_build
  log INFO "Worst-case pre-fix null-array expansion is approximately $((ROW_COUNT * (COLUMN_COUNT - 1) * 8 / 1024 / 1024)) MiB for ${ROW_COUNT} rows and ${COLUMN_COUNT} INT64 columns"

  cli "${query_ip}" "CREATE DATABASE ${DB_NAME}" >"${artifact_dir}/create_database.out" 2>&1 || fail "Create database failed"
  cli "${query_ip}" "$(generate_schema_sql)" >"${artifact_dir}/create_schema.out" 2>&1 || fail "Create aligned schema failed"
  write_sparse_rows || exit 1
  write_wide_row

  local recovery_dn
  recovery_dn=$(find_region_dn)
  [[ -n "${recovery_dn}" ]] || { fail "Could not identify DataRegion leader"; exit 1; }
  kill_datanode_for_wal_recovery "${recovery_dn}" || exit 1
  if ! start_one_dn_and_measure "${recovery_dn}"; then
    check_logs
    exit 1
  fi

  wait_sync_zero || true
  verify_replica_consistency || true
  check_logs

  if (( fail_flag == 0 )); then
    log INFO "TEST PASS: WAL recovered, replicas synchronized, and returned identical results"
    exit 0
  fi
  log ERROR "TEST FAIL: fail_flag=${fail_flag}"
  exit 1
}

main "$@"
