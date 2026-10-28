#!/bin/bash
# V2-540 / TIMECHODB-0313
# 3C21D: load data, stop/start the whole cluster repeatedly, and verify that
# ConfigNode can elect a leader and all DataNodes can rejoin after every restart.

set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
CASE_ID="V2-540"
conf_dir="${cur_dir}/../conf"
conf_file="${conf_dir}/test.conf"
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"

cn_num=3
dn_num=21
total_node_num=$((cn_num + dn_num))
RESTART_ROUNDS="${RESTART_ROUNDS:-20}"
BM_RUN_TIME_MS="${BM_RUN_TIME_MS:-172800000}"
# Empty means derive the hang guard from TEST_MAX_TIME in both Benchmark configs.
# It may still be overridden explicitly for troubleshooting.
BM_TIMEOUT_SEC="${BM_TIMEOUT_SEC:-}"
READY_TIMEOUT_SEC="${READY_TIMEOUT_SEC:-600}"
SYNC_TIMEOUT_SEC="${SYNC_TIMEOUT_SEC:-3600}"
SYNC_CHECK_INTERVAL_SEC="${SYNC_CHECK_INTERVAL_SEC:-30}"
SYNC_STABLE_CHECKS="${SYNC_STABLE_CHECKS:-3}"
STOP_SETTLE_SEC="${STOP_SETTLE_SEC:-10}"
ROUND_INTERVAL_SEC="${ROUND_INTERVAL_SEC:-10}"
CN_HEAP_MEMORY="${CN_HEAP_MEMORY:-8G}"
CN_OFF_HEAP_MEMORY="${CN_OFF_HEAP_MEMORY:-4G}"
DN_HEAP_MEMORY="${DN_HEAP_MEMORY:-24G}"
DN_OFF_HEAP_MEMORY="${DN_OFF_HEAP_MEMORY:-4G}"
BM_DIR="${BM_DIR:-/data2/benchmark/bm_20250423_a3a8cb6}"
BM_CONF1="${BM_CONF1:-${BM_DIR}/conf_retry/conf1}"
BM_CONF2="${BM_CONF2:-${BM_DIR}/conf_retry/conf2}"
BACKUP_LOG_ON_FAILURE="${BACKUP_LOG_ON_FAILURE:-1}"

read_conf() { awk -F= -v k="$1" '$1==k {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "${conf_file}"; }
os_user_name="$(read_conf os_user_name)"
testdb="$(read_conf v_testdb)"
db_parent_dir="$(read_conf v_db_parent_dir)"
cn_db_parent_dir="$(read_conf v_cn_db_parent_dir)"
shell_client_db_parent_dir="$(read_conf v_shell_client_db_parent_dir)"
root_pw="$(read_conf root_pw)"
CLUSTER_ID="$(read_conf CLUSTER_NAME)"
result_iotdb_ip="$(read_conf test_result_iotdb_ip)"

db_dir="${db_parent_dir}/${testdb}"
cn_db_dir="${cn_db_parent_dir}/${testdb}"
cli_dir="${shell_client_db_parent_dir}/${testdb}"
query_ip=""
case_tag="${testdb}_$(date +%Y%m%d_%H%M%S)_V2_540"
case_log="${cur_dir}/${case_tag}.log"
cluster_log="${cur_dir}/${case_tag}_cluster_info.log"
bm1_log="${cur_dir}/${case_tag}_tablet.out"
bm2_log="${cur_dir}/${case_tag}_records.out"
scan_log="${cur_dir}/${case_tag}_log_scan.out"
bm_runtime_dir="/tmp/${case_tag}_bm_conf"
test_start_epoch="$(date +%s)"
fail_flag=0
warn_num=0
warn_message=""
bm1_pid=""
bm2_pid=""
baseline_timeseries_count=""
baseline_region_replica_count=""
bm_error_seen=0

log() {
  local level=$1
  shift
  echo "[$(date '+%F %T')] [${level}] $*" | tee -a "${case_log}"
}

require_file() {
  [ -f "$1" ] || { log ERROR "Missing required file: $1"; return 1; }
}

run_cli_host() {
  local host=$1
  shift
  local restore_xtrace=0
  case "$-" in *x*) restore_xtrace=1; set +x ;; esac
  "${cli_dir}/sbin/start-cli.sh" -h "${host}" -u root -pw "${root_pw}" "$@" </dev/null
  local rc=$?
  [ "${restore_xtrace}" -eq 1 ] && set -x
  return "${rc}"
}

run_cli() { run_cli_host "${query_ip}" "$@"; }

cleanup_jobs() {
  [ -n "${bm1_pid}" ] && kill "${bm1_pid}" 2>/dev/null || true
  [ -n "${bm2_pid}" ] && kill "${bm2_pid}" 2>/dev/null || true
  wait ${bm1_pid:-} ${bm2_pid:-} 2>/dev/null || true
  case "${bm_runtime_dir}" in /tmp/*_V2_540_bm_conf) rm -rf "${bm_runtime_dir}" ;; esac
}
trap cleanup_jobs EXIT INT TERM

set_property() {
  local ip=$1 file=$2 key=$3 value=$4
  ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
    "f='${file}'; if grep -qE '^[# ]*${key}=' \"\$f\"; then sed -i -E 's|^[# ]*${key}=.*|${key}=${value}|' \"\$f\"; else echo '${key}=${value}' >> \"\$f\"; fi"
}

set_env_memory() {
  local ip=$1 file=$2 heap=$3 off_heap=$4
  ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
    "sed -i -E 's|^[# ]*ON_HEAP_MEMORY=.*|ON_HEAP_MEMORY=\"${heap}\"|; s|^[# ]*OFF_HEAP_MEMORY=.*|OFF_HEAP_MEMORY=\"${off_heap}\"|' '${file}'"
}

prepare_topology() {
  require_file "${conf_file}" || return 1
  require_file "${conf_dir}/confignode_3c.txt" || return 1
  require_file "${conf_dir}/datanode_21d.txt" || return 1
  cp -f "${conf_dir}/confignode_3c.txt" "${conf_dir}/confignode.txt"
  cp -f "${conf_dir}/datanode_21d.txt" "${conf_dir}/datanode.txt"
  local actual_cn actual_dn unique_dn
  actual_cn=$(grep -cvE '^[[:space:]]*(#|$)' "${conf_dir}/confignode.txt")
  actual_dn=$(grep -cvE '^[[:space:]]*(#|$)' "${conf_dir}/datanode.txt")
  unique_dn=$(awk '!/^[[:space:]]*(#|$)/{gsub(/[[:space:]]/,""); print}' "${conf_dir}/datanode.txt" | sort -u | wc -l)
  if [ "${actual_cn}" -ne "${cn_num}" ] || [ "${actual_dn}" -ne "${dn_num}" ] || [ "${unique_dn}" -ne "${dn_num}" ]; then
    log ERROR "Topology mismatch: expected 3C21D, got CN=${actual_cn}, DN=${actual_dn}, uniqueDN=${unique_dn}"
    return 1
  fi
  query_ip=$(grep -vE '^[[:space:]]*(#|$)' "${conf_dir}/datanode.txt" | head -1 | tr -d '[:space:]')
  log INFO "Topology prepared: 3C21D, query_ip=${query_ip}"
}

clean_environment() {
  log INFO "Stop and clean the existing 3C21D cluster"
  sh -x "${clean_env_dir}/stop_cluster_3c21d.sh" >>"${case_log}" 2>&1 || true
  sh -x "${clean_env_dir}/clean_cluster_3c21d.sh" >>"${case_log}" 2>&1 || return 1
  sh -x "${clean_env_dir}/reset_conf.sh" >>"${case_log}" 2>&1 || return 1
}

configure_cluster() {
  local seed ip
  seed="$(head -1 "${conf_dir}/confignode.txt" | tr -d '[:space:]'):10710"
  log INFO "Apply V2-540 configuration, seed=${seed}"
  while read -r ip; do
    ip=$(echo "${ip}" | tr -d '[:space:]'); [ -z "${ip}" ] && continue
    set_property "${ip}" "${cn_db_dir}/conf/iotdb-system.properties" cn_seed_config_node "${seed}" || return 1
    set_property "${ip}" "${cn_db_dir}/conf/iotdb-system.properties" cn_internal_address "${ip}" || return 1
    for kv in \
      'schema_replication_factor 3' 'data_replication_factor 2' \
      'schema_region_group_extension_policy CUSTOM' 'default_schema_region_group_num_per_database 21' \
      'data_region_group_extension_policy CUSTOM' 'default_data_region_group_num_per_database 42' \
      'wal_mode ASYNC' 'data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensusV2' \
      'enable_auto_repair_compaction false' 'cn_metric_reporter_list PROMETHEUS' \
      'cn_metric_prometheus_reporter_port 9081'; do
      set -- ${kv}; set_property "${ip}" "${cn_db_dir}/conf/iotdb-system.properties" "$1" "$2" || return 1
    done
    set_env_memory "${ip}" "${cn_db_dir}/conf/confignode-env.sh" "${CN_HEAP_MEMORY}" "${CN_OFF_HEAP_MEMORY}" || return 1
  done < "${conf_dir}/confignode.txt"

  while read -r ip; do
    ip=$(echo "${ip}" | tr -d '[:space:]'); [ -z "${ip}" ] && continue
    set_property "${ip}" "${db_dir}/conf/iotdb-system.properties" dn_seed_config_node "${seed}" || return 1
    set_property "${ip}" "${db_dir}/conf/iotdb-system.properties" dn_internal_address "${ip}" || return 1
    set_property "${ip}" "${db_dir}/conf/iotdb-system.properties" dn_rpc_address "${ip}" || return 1
    for kv in \
      'schema_replication_factor 3' 'data_replication_factor 2' \
      'schema_region_group_extension_policy CUSTOM' 'default_schema_region_group_num_per_database 21' \
      'data_region_group_extension_policy CUSTOM' 'default_data_region_group_num_per_database 42' \
      'wal_mode ASYNC' 'data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensusV2' \
      'enable_auto_repair_compaction false' 'dn_metric_reporter_list PROMETHEUS' \
      'dn_metric_prometheus_reporter_port 9091'; do
      set -- ${kv}; set_property "${ip}" "${db_dir}/conf/iotdb-system.properties" "$1" "$2" || return 1
    done
    set_env_memory "${ip}" "${db_dir}/conf/datanode-env.sh" "${DN_HEAP_MEMORY}" "${DN_OFF_HEAP_MEMORY}" || return 1
  done < "${conf_dir}/datanode.txt"
}

start_cluster() {
  sh -x "${prepare_env_dir}/start_cluster_v20.sh" 1 "${total_node_num}" >>"${case_log}" 2>&1
}

find_live_cli() {
  local ip
  while read -r ip; do
    ip=$(echo "${ip}" | tr -d '[:space:]'); [ -z "${ip}" ] && continue
    if run_cli_host "${ip}" -e 'show cluster;' >/dev/null 2>&1; then query_ip="${ip}"; return 0; fi
  done < "${conf_dir}/datanode.txt"
  return 1
}

wait_cluster_ready() {
  local round=$1 begin now status running leader_count
  begin=$(date +%s)
  while true; do
    if find_live_cli; then
      status=$(run_cli -e 'show cluster;' 2>/dev/null || true)
      running=$(echo "${status}" | awk -F'|' '/ConfigNode|DataNode/ && /Running/{n++} END{print n+0}')
      echo "===== round=${round} $(date '+%F %T') query=${query_ip} running=${running}/${total_node_num} =====" >>"${cluster_log}"
      echo "${status}" >>"${cluster_log}"
      leader_count=$(run_cli -e 'show confignodes;' 2>/dev/null | awk -F'|' 'tolower($0) ~ /leader/{n++} END{print n+0}')
      if [ "${running}" -eq "${total_node_num}" ] && [ "${leader_count}" -ge 1 ]; then
        log INFO "Round ${round}: cluster ready, nodes=${running}/${total_node_num}, ConfigNode leader=${leader_count}, query=${query_ip}"
        return 0
      fi
    fi
    now=$(date +%s)
    if [ $((now - begin)) -ge "${READY_TIMEOUT_SEC}" ]; then
      log ERROR "Round ${round}: cluster failed to recover or elect ConfigNode leader in ${READY_TIMEOUT_SEC}s"
      return 1
    fi
    sleep 10
  done
}

start_load() {
  local hosts ports conf waited errors bm1_rc bm2_rc max_time_ms config_max_ms
  require_file "${BM_DIR}/benchmark.sh" || return 1
  require_file "${BM_CONF1}/config.properties" || return 1
  require_file "${BM_CONF2}/config.properties" || return 1
  rm -rf "${bm_runtime_dir}"; mkdir -p "${bm_runtime_dir}/conf1" "${bm_runtime_dir}/conf2"
  cp -rp "${BM_CONF1}/." "${bm_runtime_dir}/conf1/"
  cp -rp "${BM_CONF2}/." "${bm_runtime_dir}/conf2/"
  hosts=$(awk 'BEGIN{f=1}!/^[[:space:]]*(#|$)/{gsub(/[[:space:]]/,"");if(!f)printf ",";printf "%s",$0;f=0}END{print ""}' "${conf_dir}/datanode.txt")
  ports=$(awk 'BEGIN{f=1}!/^[[:space:]]*(#|$)/{if(!f)printf ",";printf "6667";f=0}END{print ""}' "${conf_dir}/datanode.txt")
  for conf in "${bm_runtime_dir}/conf1/config.properties" "${bm_runtime_dir}/conf2/config.properties"; do
    sed -i -E "s|^[# ]*HOST=.*|HOST=${hosts}|;s|^[# ]*PORT=.*|PORT=${ports}|;s|^[# ]*USERNAME=.*|USERNAME=root|;s|^[# ]*PASSWORD=.*|PASSWORD=${root_pw}|" "${conf}"
    if grep -qE '^[# ]*TEST_MAX_TIME=' "${conf}"; then
      sed -i -E "s|^[# ]*TEST_MAX_TIME=.*|TEST_MAX_TIME=${BM_RUN_TIME_MS}|" "${conf}"
    else
      echo "TEST_MAX_TIME=${BM_RUN_TIME_MS}" >>"${conf}"
    fi
  done
  if [ -z "${BM_TIMEOUT_SEC}" ]; then
    max_time_ms=0
    for conf in "${bm_runtime_dir}/conf1/config.properties" "${bm_runtime_dir}/conf2/config.properties"; do
      config_max_ms=$(awk -F= '/^[[:space:]]*TEST_MAX_TIME[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "${conf}")
      case "${config_max_ms}" in ''|*[!0-9]*) config_max_ms=0 ;; esac
      [ "${config_max_ms}" -le "${max_time_ms}" ] || max_time_ms="${config_max_ms}"
    done
    if [ "${max_time_ms}" -gt 0 ]; then
      BM_TIMEOUT_SEC=$((max_time_ms / 1000 + 600))
    else
      BM_TIMEOUT_SEC=604800
      log WARN "TEST_MAX_TIME is absent/zero; use fallback Benchmark guard=${BM_TIMEOUT_SEC}s"
    fi
  fi
  "${BM_DIR}/benchmark.sh" -cf "${bm_runtime_dir}/conf1" >"${bm1_log}" 2>&1 & bm1_pid=$!
  "${BM_DIR}/benchmark.sh" -cf "${bm_runtime_dir}/conf2" >"${bm2_log}" 2>&1 & bm2_pid=$!
  log INFO "Dual Benchmark workloads started for $((BM_RUN_TIME_MS / 3600000))h: ${bm1_pid}, ${bm2_pid}; wait for natural completion (guard=${BM_TIMEOUT_SEC}s)"
  waited=0
  while kill -0 "${bm1_pid}" 2>/dev/null || kill -0 "${bm2_pid}" 2>/dev/null; do
    sleep 10; waited=$((waited + 10))
    fatal_errors=$(awk '/OutOfMemoryError|Java heap space/{n++}END{print n+0}' "${bm1_log}" "${bm2_log}" 2>/dev/null)
    [ "${fatal_errors:-0}" -eq 0 ] || { log ERROR "Benchmark contains ${fatal_errors} fatal JVM OOM errors"; return 1; }
    errors=$(awk '/Insert batch failed|Fail to reconnect|ConnectionException/{n++}END{print n+0}' "${bm1_log}" "${bm2_log}" 2>/dev/null)
    if [ "${errors:-0}" -gt "${bm_error_seen}" ]; then
      bm_error_seen=${errors}
      warn_num=$((warn_num + 1))
      warn_message="${warn_message} Benchmark recoverable write/connection errors=${errors};"
      log WARN "Benchmark has ${errors} write/connection errors so far; continue endurance run and defer judgment until process completion"
    fi
    if [ "${waited}" -ge "${BM_TIMEOUT_SEC}" ]; then
      log ERROR "Benchmark did not finish within ${BM_TIMEOUT_SEC}s"
      return 1
    fi
    [ $((waited % 600)) -ne 0 ] || log INFO "Benchmark is still running: elapsed=${waited}s"
  done
  wait "${bm1_pid}"; bm1_rc=$?
  wait "${bm2_pid}"; bm2_rc=$?
  bm1_pid=""; bm2_pid=""
  if [ "${bm1_rc}" -ne 0 ] || [ "${bm2_rc}" -ne 0 ]; then
    log ERROR "Benchmark exited abnormally: tablet_rc=${bm1_rc}, records_rc=${bm2_rc}"
    return 1
  fi
  if [ "${bm_error_seen}" -gt 0 ]; then
    log WARN "Benchmark completed with ${bm_error_seen} write/connection error records; continue restart verification"
  fi
  if ! grep -q 'Test elapsed' "${bm1_log}" || ! grep -q 'Test elapsed' "${bm2_log}"; then
    log ERROR "Benchmark exited without completion summary"
    return 1
  fi
  run_cli -timeout 3600 -e 'flush;' >>"${case_log}" 2>&1 || return 1
  log INFO "Both Benchmark workloads completed naturally and data was flushed"
}

get_timeseries_count() {
  local host=$1
  run_cli_host "${host}" -e 'count timeseries root.**;' 2>/dev/null \
    | awk -F'|' '/^[[:space:]]*\|[[:space:]]*[0-9]+[[:space:]]*\|[[:space:]]*$/{gsub(/[[:space:]|]/,"",$0); print $0; exit}'
}

wait_replica_sync() {
  local phase=$1 begin now regions non_running stable=0 output
  begin=$(date +%s)
  while true; do
    output=$(run_cli -e 'show regions;' 2>/dev/null || true)
    regions=$(echo "${output}" | awk -F'|' '/SchemaRegion|DataRegion/{n++} END{print n+0}')
    non_running=$(echo "${output}" | awk -F'|' '/SchemaRegion|DataRegion/ && $0 !~ /Running/{n++} END{print n+0}')
    if [ "${regions}" -gt 0 ] && [ "${non_running}" -eq 0 ]; then
      stable=$((stable + 1))
      log INFO "${phase}: all ${regions} region replicas Running, stable=${stable}/${SYNC_STABLE_CHECKS}"
      if [ "${stable}" -ge "${SYNC_STABLE_CHECKS}" ]; then
        return 0
      fi
    else
      stable=0
      log INFO "${phase}: wait replica synchronization, replicas=${regions}, non_running=${non_running}"
    fi
    now=$(date +%s)
    if [ $((now - begin)) -ge "${SYNC_TIMEOUT_SEC}" ]; then
      log ERROR "${phase}: region replicas did not become stably Running within ${SYNC_TIMEOUT_SEC}s"
      echo "${output}" >>"${cluster_log}"
      return 1
    fi
    sleep "${SYNC_CHECK_INTERVAL_SEC}"
  done
}

capture_replica_baseline() {
  baseline_timeseries_count=$(get_timeseries_count "${query_ip}")
  baseline_region_replica_count=$(run_cli -e 'show regions;' 2>/dev/null | awk -F'|' '/SchemaRegion|DataRegion/{n++} END{print n+0}')
  case "${baseline_timeseries_count}" in ''|*[!0-9]*) log ERROR "Unable to obtain baseline timeseries count"; return 1 ;; esac
  [ "${baseline_region_replica_count}" -gt 0 ] || { log ERROR "Unable to obtain baseline region replica count"; return 1; }
  log INFO "Replica baseline: timeseries=${baseline_timeseries_count}, region_replicas=${baseline_region_replica_count}"
}

verify_replica_consistency() {
  local ip current_count current_regions
  current_regions=$(run_cli -e 'show regions;' 2>/dev/null | awk -F'|' '/SchemaRegion|DataRegion/{n++} END{print n+0}')
  if [ "${current_regions}" -ne "${baseline_region_replica_count}" ]; then
    log ERROR "Region replica count changed: baseline=${baseline_region_replica_count}, current=${current_regions}"
    return 1
  fi
  while read -r ip; do
    ip=$(echo "${ip}" | tr -d '[:space:]'); [ -z "${ip}" ] && continue
    current_count=$(get_timeseries_count "${ip}")
    if [ "${current_count}" != "${baseline_timeseries_count}" ]; then
      log ERROR "Replica/data consistency check failed via DN ${ip}: baseline=${baseline_timeseries_count}, current=${current_count:-EMPTY}"
      return 1
    fi
    log INFO "DN ${ip} metadata/data view consistent: timeseries=${current_count}"
  done < "${conf_dir}/datanode.txt"
  log INFO "All ${dn_num} DataNodes returned the same timeseries count and region replica count is unchanged"
}

prepare_canary() {
  run_cli -e 'create database root.v2_540;' >>"${case_log}" 2>&1 || true
  run_cli -e 'insert into root.v2_540.restart_check(time,s_round,s_value) values(1,0,0);' >>"${case_log}" 2>&1 || return 1
  run_cli -e 'select s_value from root.v2_540.restart_check where time=1;' | grep -qE '\|[[:space:]]*0[[:space:]]*\|' || return 1
}

verify_after_restart() {
  local round=$1 ts=$((round + 1))
  run_cli -e "insert into root.v2_540.restart_check(time,s_round,s_value) values(${ts},${round},${round});" >>"${case_log}" 2>&1 || return 1
  run_cli -e "select s_value from root.v2_540.restart_check where time=${ts};" | grep -qE "\|[[:space:]]*${round}[[:space:]]*\|" || return 1
  run_cli -e 'select count(s_value) from root.v2_540.restart_check;' | grep -qE "\|[[:space:]]*$((round + 1))[[:space:]]*\|" || return 1
}

run_restart_rounds() {
  local round
  round=1
  while [ "${round}" -le "${RESTART_ROUNDS}" ]; do
    log INFO "Restart round ${round}/${RESTART_ROUNDS}: stop the whole 3C21D cluster"
    sh -x "${clean_env_dir}/stop_cluster_3c21d.sh" >>"${case_log}" 2>&1 || true
    sleep "${STOP_SETTLE_SEC}"
    log INFO "Restart round ${round}/${RESTART_ROUNDS}: start the whole cluster"
    start_cluster || { log ERROR "Round ${round}: start_cluster_v20.sh failed"; return 1; }
    wait_cluster_ready "${round}" || return 1
    verify_after_restart "${round}" || { log ERROR "Round ${round}: post-restart read/write verification failed"; return 1; }
    log INFO "Restart round ${round}/${RESTART_ROUNDS} PASS"
    sleep "${ROUND_INTERVAL_SEC}"
    round=$((round + 1))
  done
}

scan_logs() {
  local ip hits=0 leader_hits=0
  : >"${scan_log}"
  while read -r ip; do
    ip=$(echo "${ip}" | tr -d '[:space:]'); [ -z "${ip}" ] && continue
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
      "grep -R -nE 'OutOfMemoryError|Java heap space|GC overhead limit|hs_err_pid|ConfigNode.*failed to start|FATAL' '${cn_db_dir}/logs' 2>/dev/null" \
      | sed "s|^|CN ${ip} |" >>"${scan_log}" || true
  done < "${conf_dir}/confignode.txt"
  while read -r ip; do
    ip=$(echo "${ip}" | tr -d '[:space:]'); [ -z "${ip}" ] && continue
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
      "grep -R -nE 'OutOfMemoryError|Java heap space|GC overhead limit|hs_err_pid|DataNode.*failed to start|FATAL' '${db_dir}/logs' 2>/dev/null" \
      | sed "s|^|DN ${ip} |" >>"${scan_log}" || true
  done < "${conf_dir}/datanode.txt"
  hits=$(wc -l <"${scan_log}")
  if [ "${hits}" -gt 0 ]; then
    log ERROR "Found ${hits} fatal/OOM log records; see ${scan_log}"
    return 1
  fi
  while read -r ip; do
    ip=$(echo "${ip}" | tr -d '[:space:]'); [ -z "${ip}" ] && continue
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
      "grep -R -nEi 'Cannot elect.*leader|failed to elect.*leader|no available.*leader|leader.*not.*found' '${cn_db_dir}/logs' 2>/dev/null" \
      | sed "s|^|LEADER_WARN CN ${ip} |" >>"${scan_log}" || true
  done < "${conf_dir}/confignode.txt"
  leader_hits=$(grep -c '^LEADER_WARN ' "${scan_log}" 2>/dev/null || true)
  if [ "${leader_hits}" -gt 0 ]; then
    warn_num=$((warn_num + leader_hits))
    warn_message="${warn_message} transient/persistent leader-related log records=${leader_hits};"
    log WARN "Found ${leader_hits} leader-related log records for review; cluster recovery result is determined by the 10 round readiness checks"
  fi
  log INFO "Fatal/OOM log scan passed; full scan output=${scan_log}"
}

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

write_result() {
  local end elapsed result other max_bm sum_bm sql
  end=$(date +%s); elapsed=$((end - test_start_epoch))
  [ "${fail_flag}" -gt 0 ] && result=FAIL || result=PASS
  max_bm=$(grep -h 'Test elapsed' "${bm1_log}" "${bm2_log}" 2>/dev/null | awk '{print $8}' | sort -n | tail -1)
  sum_bm=$(grep -h 'Test elapsed' "${bm1_log}" "${bm2_log}" 2>/dev/null | awk '{s+=$8}END{print s+0}')
  case "${max_bm}" in ''|*[!0-9.]*) max_bm=0 ;; esac
  case "${sum_bm}" in ''|*[!0-9.]*) sum_bm=0 ;; esac
  other=$(sql_escape "V2-540 3C21D full restart ${RESTART_ROUNDS} rounds; ${warn_message}")
  sql="insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage) values(now(),'$(sql_escape "${testdb}")','$(sql_escape "${SCRIPT_NAME}")','IoTV2','${result}',${elapsed},${max_bm},${sum_bm},${warn_num},'${other}');"
  if [ -n "${result_iotdb_ip}" ]; then
    "${cli_dir}/sbin/start-cli.sh" -h "${result_iotdb_ip}" -u root -pw "${root_pw}" -e "${sql}" </dev/null >>"${case_log}" 2>&1 \
      || log WARN "Failed to write result database"
  fi
  echo "RESULT fail_flag=${fail_flag} result=${result} elapsed=${elapsed}s rounds=${RESTART_ROUNDS}" | tee -a "${case_log}"
  echo "testcase1 $(echo "${result}" | tr 'A-Z' 'a-z')"
}

main() {
  prepare_topology || return 1
  clean_environment || { log ERROR "Environment cleanup failed"; return 1; }
  configure_cluster || { log ERROR "Cluster configuration failed"; return 1; }
  start_cluster || { log ERROR "Initial cluster startup failed"; return 1; }
  wait_cluster_ready 0 || return 1
  start_load || return 1
  wait_replica_sync "after benchmark" || return 1
  capture_replica_baseline || return 1
  prepare_canary || { log ERROR "Initial canary read/write failed"; return 1; }
  run_restart_rounds || return 1
  wait_replica_sync "after ${RESTART_ROUNDS} restarts" || return 1
  verify_replica_consistency || return 1
  scan_logs || return 1
  log INFO "V2-540 verification passed: all ${RESTART_ROUNDS} full-cluster restarts recovered"
}

if ! main; then
  fail_flag=$((fail_flag + 1))
  log ERROR "V2-540 verification failed"
  if [ "${BACKUP_LOG_ON_FAILURE}" -gt 0 ] && [ -x "${clean_env_dir}/backup_cluster_logs.sh" ]; then
    sh -x "${clean_env_dir}/backup_cluster_logs.sh" "${case_tag}" >>"${case_log}" 2>&1 || true
  fi
fi
write_result
exit "${fail_flag}"
