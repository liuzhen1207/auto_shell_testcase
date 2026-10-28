#!/bin/bash
# V2-588 / TIMECHODB-1058
# Variant: DataNode lz4_use_jni=false and Parallel GC.
# 3C21D long-running scenario: two write workloads + one delete loop + one region migration loop.

set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
CASE_ID="V2-588"
conf_dir="${cur_dir}/../conf"
conf_file="${conf_dir}/test.conf"
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"

cn_num=3
dn_num=21
total_node_num=$((cn_num + dn_num))
schema_replication_factor="${SCHEMA_REPLICATION_FACTOR:-3}"
data_replication_factor="${DATA_REPLICATION_FACTOR:-2}"
schema_region_group_num="${SCHEMA_REGION_GROUP_NUM:-21}"
data_region_group_num="${SCHEMA_REGION_GROUP_NUM:-42}"
MIGRATION_ROUNDS="${MIGRATION_ROUNDS:-100}"
WARMUP_SEC="${WARMUP_SEC:-600}"
DELETE_DEVICE_NUM="${DELETE_DEVICE_NUM:-30000}"
TEST_TIMEOUT_HOURS="${TEST_TIMEOUT_HOURS:-72}"
DN_HEAP_MEMORY="${DN_HEAP_MEMORY:-24G}"
BM_DIR="${BM_DIR:-/data2/benchmark/bm_20240320_76af1a40}"
BM_CONF1="${BM_CONF1:-${BM_DIR}/conf_retry/conf1}"
BM_CONF2="${BM_CONF2:-${BM_DIR}/conf_retry/conf2}"

os_user_name=$(awk -F= '/^os_user_name=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
testdb=$(awk -F= '/^v_testdb=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
db_parent_dir=$(awk -F= '/^v_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
cn_db_parent_dir=$(awk -F= '/^v_cn_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
shell_client_db_parent_dir=$(awk -F= '/^v_shell_client_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
case "$-" in *x*) xtrace_was_enabled=1; set +x ;; *) xtrace_was_enabled=0 ;; esac
root_pw=$(awk -F= '/^root_pw=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
[ "${xtrace_was_enabled}" -eq 1 ] && set -x

db_dir="${db_parent_dir}/${testdb}"
cn_db_dir="${cn_db_parent_dir}/${testdb}"
cli_dir="${shell_client_db_parent_dir}/${testdb}"
case_tag="${testdb}_$(date +%Y%m%d_%H%M%S)_V2_588_lz4_nojni_parallelgc"
case_log="${cur_dir}/${case_tag}.log"
cluster_info_log="${cur_dir}/${case_tag}_cluster_info.log"
bm1_log="${cur_dir}/${case_tag}_tablet.out"
bm2_log="${cur_dir}/${case_tag}_records.out"
delete_log="${cur_dir}/${case_tag}_delete.out"
bm_runtime_dir="/tmp/${case_tag}_bm_conf"
case_start_epoch=$(date +%s)

fail_flag=0
bm1_pid=""
bm2_pid=""
delete_pid=""
watchdog_pid=""

log() {
  local level=$1
  shift
  echo "[$(date '+%F %T')] [${level}] $*" | tee -a "${case_log}"
}

run_cli() {
  local restore_xtrace=0
  case "$-" in *x*) restore_xtrace=1; set +x ;; esac
  "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -u root -pw "${root_pw}" "$@" </dev/null
  local rc=$?
  [ "${restore_xtrace}" -eq 1 ] && set -x
  return "${rc}"
}

cleanup_local_jobs() {
  [ -n "${watchdog_pid}" ] && kill "${watchdog_pid}" 2>/dev/null || true
  [ -n "${delete_pid}" ] && kill "${delete_pid}" 2>/dev/null || true
  [ -n "${bm1_pid}" ] && kill "${bm1_pid}" 2>/dev/null || true
  [ -n "${bm2_pid}" ] && kill "${bm2_pid}" 2>/dev/null || true
  wait ${delete_pid:-} ${bm1_pid:-} ${bm2_pid:-} 2>/dev/null || true
  case "${bm_runtime_dir}" in /tmp/*_V2_588_lz4_nojni_parallelgc_bm_conf) rm -rf "${bm_runtime_dir}" ;; esac
}
trap cleanup_local_jobs EXIT
trap 'exit 130' INT TERM

require_file() {
  [ -f "$1" ] || { log ERROR "Missing required file: $1"; exit 2; }
}

set_property() {
  local node_ip=$1
  local file=$2
  local key=$3
  local value=$4
  ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" \
    "f='${file}'; if grep -qE '^[# ]*${key}=' \"\$f\"; then sed -i -E 's|^[# ]*${key}=.*|${key}=${value}|' \"\$f\"; else echo '${key}=${value}' >> \"\$f\"; fi"
}

prepare_node_files() {
  require_file "${conf_dir}/confignode_3c.txt"
  require_file "${conf_dir}/datanode_21d.txt"
  cp -f "${conf_dir}/confignode_3c.txt" "${conf_dir}/confignode.txt"
  cp -f "${conf_dir}/datanode_21d.txt" "${conf_dir}/datanode.txt"
  query_ip=$(head -1 "${conf_dir}/datanode.txt" | tr -d '[:space:]')

  local actual_cn actual_dn
  actual_cn=$(grep -cvE '^[[:space:]]*(#|$)' "${conf_dir}/confignode.txt")
  actual_dn=$(grep -cvE '^[[:space:]]*(#|$)' "${conf_dir}/datanode.txt")
  if [ "${actual_cn}" -ne "${cn_num}" ] || [ "${actual_dn}" -ne "${dn_num}" ]; then
    log ERROR "Node list mismatch: expected ${cn_num}C${dn_num}D, got ${actual_cn}C${actual_dn}D"
    exit 2
  fi
  log INFO "Active topology: ${actual_cn}C${actual_dn}D, query_ip=${query_ip}"
}

ensure_version_deployed() {
  local package_zip node_ip remote_zip remote_extract target_dir node_type node_file
  package_zip=$(find "${cli_dir}" -maxdepth 1 -type f -name '*.zip' | head -1)
  [ -n "${package_zip}" ] && [ -f "${package_zip}" ] || {
    log ERROR "No release zip found under ${cli_dir}"
    return 1
  }

  for node_type in cn dn; do
    if [ "${node_type}" = "cn" ]; then
      target_dir="${cn_db_dir}"
      node_file="${conf_dir}/confignode.txt"
    else
      target_dir="${db_dir}"
      node_file="${conf_dir}/datanode.txt"
    fi

    while read -r node_ip; do
      node_ip=$(echo "${node_ip}" | tr -d '[:space:]')
      [ -z "${node_ip}" ] && continue
      if ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" \
        "test -f '${target_dir}/conf/iotdb-system.properties'"; then
        continue
      fi

      remote_zip="/tmp/${CASE_ID}_${testdb}.zip"
      remote_extract="/tmp/${CASE_ID}_${testdb}_extract"
      log INFO "Deploy ${testdb} to ${node_type} node ${node_ip}"
      scp -q "${package_zip}" "${os_user_name}@${node_ip}:${remote_zip}" || return 1
      ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" \
        "rm -rf '${remote_extract}' && mkdir -p '${remote_extract}' '${target_dir}' && (cd '${remote_extract}' && jar xf '${remote_zip}') && package_root=\$(find '${remote_extract}' -mindepth 1 -maxdepth 1 -type d | head -1) && [ -n \"\${package_root}\" ] && cp -rp \"\${package_root}/.\" '${target_dir}/' && chmod +x '${target_dir}'/sbin/*.sh && rm -rf '${target_dir}/conf_orig' && cp -rp '${target_dir}/conf' '${target_dir}/conf_orig' && rm -rf '${remote_extract}' '${remote_zip}'" || return 1
    done < "${node_file}"
  done
}

clean_cluster() {
  log INFO "Stop and clean the 3C21D cluster"
  sh -x "${clean_env_dir}/stop_cluster_3c21d.sh" >> "${case_log}" 2>&1 || true
  sh -x "${clean_env_dir}/clean_cluster_3c21d.sh" >> "${case_log}" 2>&1 || return 1
  sh -x "${clean_env_dir}/reset_conf.sh" >> "${case_log}" 2>&1 || return 1
}

configure_cluster() {
  local seed_cn_ip
  seed_cn_ip="$(head -1 "${conf_dir}/confignode.txt" | tr -d '[:space:]'):10710"
  log INFO "Configure ${cn_num} ConfigNodes and ${dn_num} DataNodes, seed=${seed_cn_ip}"

  while read -r node_ip; do
    node_ip=$(echo "${node_ip}" | tr -d '[:space:]')
    [ -z "${node_ip}" ] && continue
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" cn_seed_config_node "${seed_cn_ip}" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" cn_internal_address "${node_ip}" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" schema_replication_factor "${schema_replication_factor}" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" data_replication_factor "${data_replication_factor}" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" cn_metric_reporter_list "PROMETHEUS" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" schema_region_group_extension_policy CUSTOM || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" data_region_group_extension_policy CUSTOM || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" default_schema_region_group_num_per_database "${schema_region_group_num}" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" default_data_region_group_num_per_database "${data_region_group_num}" || return 1
  done < "${conf_dir}/confignode.txt"

  while read -r node_ip; do
    node_ip=$(echo "${node_ip}" | tr -d '[:space:]')
    [ -z "${node_ip}" ] && continue
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" dn_seed_config_node "${seed_cn_ip}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" dn_internal_address "${node_ip}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" dn_rpc_address "${node_ip}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" dn_metric_reporter_list "PROMETHEUS" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" schema_replication_factor "${schema_replication_factor}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" data_replication_factor "${data_replication_factor}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" schema_region_group_extension_policy CUSTOM || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" data_region_group_extension_policy CUSTOM || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" default_schema_region_group_num_per_database "${schema_region_group_num}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" default_data_region_group_num_per_database "${data_region_group_num}" || return 1

    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" lz4_use_jni false || return 1
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" \
      "sed -i -E 's|^[# ]*ON_HEAP_MEMORY=.*|ON_HEAP_MEMORY=\"${DN_HEAP_MEMORY}\"|; /IOTDB_JMX_OPTS=.*-XX:\\+UseParallelGC/d; /IOTDB_JMX_OPTS=.*-XX:\\+UseAdaptiveSizePolicy/a IOTDB_JMX_OPTS=\"\\\$IOTDB_JMX_OPTS -XX:+UseParallelGC\"' '${db_dir}/conf/datanode-env.sh'" || return 1
  done < "${conf_dir}/datanode.txt"
}

start_cluster() {
  log INFO "Start 3C21D cluster; expected ready nodes=${total_node_num}"
  sh -x "${prepare_env_dir}/start_cluster_v20.sh" 1 "${total_node_num}" >> "${case_log}" 2>&1
}

start_workloads() {
  local host_list port_list runtime_conf waited host_count port_count
  require_file "${BM_DIR}/benchmark.sh"
  require_file "${BM_CONF1}/config.properties"
  require_file "${BM_CONF2}/config.properties"
  rm -rf "${bm_runtime_dir}"
  mkdir -p "${bm_runtime_dir}/conf1" "${bm_runtime_dir}/conf2"
  chmod 700 "${bm_runtime_dir}"
  cp -rp "${BM_CONF1}/." "${bm_runtime_dir}/conf1/"
  cp -rp "${BM_CONF2}/." "${bm_runtime_dir}/conf2/"
  host_list=$(awk 'BEGIN{first=1} !/^[[:space:]]*(#|$)/ {gsub(/[[:space:]]/, ""); if (!first) printf ","; printf "%s", $0; first=0} END{print ""}' "${conf_dir}/datanode.txt")
  port_list=$(awk 'BEGIN{first=1} !/^[[:space:]]*(#|$)/ {if (!first) printf ","; printf "6667"; first=0} END{print ""}' "${conf_dir}/datanode.txt")
  host_count=$(printf '%s' "${host_list}" | awk -F, '{print NF}')
  port_count=$(printf '%s' "${port_list}" | awk -F, '{print NF}')
  if [ "${host_count}" -ne "${dn_num}" ] || [ "${port_count}" -ne "${dn_num}" ]; then
    log ERROR "Invalid Benchmark endpoints: hosts=${host_count}, ports=${port_count}, expected=${dn_num}"
    return 1
  fi
  log INFO "Benchmark endpoints validated: ${host_count} hosts"
  for runtime_conf in "${bm_runtime_dir}/conf1/config.properties" "${bm_runtime_dir}/conf2/config.properties"; do
    sed -i -E "s|^[# ]*HOST=.*|HOST=${host_list}|" "${runtime_conf}"
    sed -i -E "s|^[# ]*PORT=.*|PORT=${port_list}|" "${runtime_conf}"
    sed -i -E 's|^[# ]*USERNAME=.*|USERNAME=root|' "${runtime_conf}"
    sed -i -E "s|^[# ]*PASSWORD=.*|PASSWORD=${root_pw}|" "${runtime_conf}"
    chmod 600 "${runtime_conf}"
  done
  log INFO "Start two original write workloads using protected runtime config copies"
  "${BM_DIR}/benchmark.sh" -cf "${bm_runtime_dir}/conf1" > "${bm1_log}" 2>&1 &
  bm1_pid=$!
  sleep 1
  "${BM_DIR}/benchmark.sh" -cf "${bm_runtime_dir}/conf2" > "${bm2_log}" 2>&1 &
  bm2_pid=$!
  log INFO "Benchmark PIDs: tablet=${bm1_pid}, records=${bm2_pid}; warmup=${WARMUP_SEC}s"
  waited=0
  while [ "${waited}" -lt "${WARMUP_SEC}" ]; do
    sleep 10
    waited=$((waited + 10))
    kill -0 "${bm1_pid}" 2>/dev/null && kill -0 "${bm2_pid}" 2>/dev/null || {
      log ERROR "Benchmark exited during warmup at ${waited}s"
      return 1
    }
    check_benchmark_logs || return 1
  done
  log INFO "Benchmark warmup completed without write errors"
}

check_benchmark_logs() {
  local pattern='Insert batch failed|Fail to reconnect|ConnectionException|OutOfMemoryError|Java heap space|GC overhead limit'
  local errors=0
  errors=$(awk -v pattern="${pattern}" '$0 ~ pattern {n++} END{print n+0}' "${bm1_log}" "${bm2_log}" 2>/dev/null)
  case "${errors}" in ''|*[!0-9]*) errors=0 ;; esac
  if [ "${errors}" -gt 0 ]; then
    log ERROR "Benchmark logs contain ${errors} write/connection/OOM errors"
    grep -hE "${pattern}" "${bm1_log}" "${bm2_log}" 2>/dev/null | tail -20 | tee -a "${case_log}"
    return 1
  fi
  return 0
}

delete_data_loop() {
  local i count half_count delete_time
  while true; do
    i=0
    while [ "${i}" -lt "${DELETE_DEVICE_NUM}" ]; do
      for prefix in d1 d2; do
        count=$(run_cli -timeout 3600 \
          -e "select count(s_0) from root.test.g_0.${prefix}_${i};" 2>/dev/null \
          | awk -F'|' '/\|[[:space:]]*[0-9]+[[:space:]]*\|/{gsub(/ /,"",$2); print $2; exit}')
        case "${count}" in ''|*[!0-9]*) continue ;; esac
        [ "${count}" -le 1 ] && continue
        half_count=$((count / 2))
        delete_time=$(run_cli -timeout 3600 \
          -e "select s_0 from root.test.g_0.${prefix}_${i} offset ${half_count} limit 1;" 2>/dev/null \
          | awk -F'|' '/T.*:/{gsub(/^ +| +$/,"",$2); print $2; exit}')
        [ -n "${delete_time}" ] && run_cli -timeout 3600 \
          -e "delete from root.test.g_0.${prefix}_${i}.** where time <= ${delete_time};" >> "${delete_log}" 2>&1
      done
      i=$((i + 1))
    done
  done
}

refresh_node_ids() {
  run_cli -e "show datanodes;" \
    | awk -F'|' '/Running/{gsub(/ /,"",$2); if ($2 ~ /^[0-9]+$/) print $2}' > "${cur_dir}/V2_588_all_dn_id.txt"
  [ "$(wc -l < "${cur_dir}/V2_588_all_dn_id.txt")" -eq "${dn_num}" ]
}

region_rows() {
  local region_type=$1
  run_cli -e "show ${region_type} regions;" 2>/dev/null
}

migrate_one_region() {
  local region_type=$1
  local region_id=$2
  local rows replica_file from_id to_id candidate now last_health_check
  rows=$(region_rows "${region_type}") || return 1
  replica_file="${cur_dir}/V2_588_region_${region_id}_replicas.txt"
  echo "${rows}" | awk -F'|' -v id="${region_id}" '$2 ~ id {gsub(/ /,"",$2); gsub(/ /,"",$8); if ($2==id) print $8}' > "${replica_file}"
  from_id=$(head -1 "${replica_file}")
  [ -n "${from_id}" ] || return 1
  to_id=""
  while read -r candidate; do
    if ! grep -qx "${candidate}" "${replica_file}"; then to_id="${candidate}"; break; fi
  done < "${cur_dir}/V2_588_all_dn_id.txt"
  [ -n "${to_id}" ] || return 1

  log INFO "MIGRATE ${region_type} REGION ${region_id} FROM ${from_id} TO ${to_id}"
  run_cli \
    -e "MIGRATE REGION ${region_id} FROM ${from_id} TO ${to_id};" >> "${cluster_info_log}" 2>&1 || return 1
  last_health_check=0
  while true; do
    rows=$(region_rows "${region_type}") || true
    if echo "${rows}" | awk -F'|' -v id="${region_id}" -v from="${from_id}" -v to="${to_id}" \
      '$2 ~ id {
         gsub(/ /,"",$2); gsub(/ /,"",$4); gsub(/ /,"",$8);
         if ($2==id && $8==to && $4=="Running") target_running=1;
         if ($2==id && $8==from) source_exists=1
       }
       END{exit !(target_running && !source_exists)}'; then
      log INFO "Migration completed: ${region_type} region=${region_id}, removed=${from_id}, added=${to_id}"
      return 0
    fi
    now=$(date +%s)
    if [ $((now - last_health_check)) -ge 60 ]; then
      check_cluster_and_oom || return 1
      last_health_check=${now}
    fi
    sleep 10
  done
}

migrate_all_regions() {
  local region_type=$1
  local id_file="${cur_dir}/V2_588_${region_type}_region_ids.txt"
  region_rows "${region_type}" | awk -F'|' '/root.test/{gsub(/ /,"",$2); if ($2 ~ /^[0-9]+$/) print $2}' | sort -n -u > "${id_file}"
  [ -s "${id_file}" ] || { log WARN "No ${region_type} region found for root.test yet"; return 0; }
  while read -r region_id; do
    migrate_one_region "${region_type}" "${region_id}" || {
      log ERROR "Migration failed: type=${region_type}, region=${region_id}"
      return 1
    }
  done < "${id_file}"
}

check_cluster_and_oom() {
  local status running node_ip evidence oom_detected=0
  while read -r node_ip; do
    node_ip=$(echo "${node_ip}" | tr -d '[:space:]')
    [ -z "${node_ip}" ] && continue
    evidence=$(ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" \
      "grep -R -l -E 'OutOfMemoryError|Java heap space|GC overhead limit' '${db_dir}/logs' 2>/dev/null | sed 's|^|OOM_LOG |'; find '${db_dir}' -maxdepth 1 -type f -name '*.hprof' -newermt '@${case_start_epoch}' -printf 'HEAP_DUMP %p size=%s mtime=%TY-%Tm-%TdT%TH:%TM:%TS\\n' 2>/dev/null" || true)
    if [ -n "${evidence}" ]; then
      oom_detected=1
      while IFS= read -r line; do
        log ERROR "Detected DataNode OOM evidence: node=${node_ip} ${line}"
      done <<< "${evidence}"
    fi
  done < "${conf_dir}/datanode.txt"

  status=$(run_cli -e "show cluster;" 2>/dev/null || true)
  running=$(echo "${status}" | awk -F'|' '/ConfigNode|DataNode/ && /Running|ReadOnly/{n++} END{print n+0}')
  echo "${status}" >> "${cluster_info_log}"
  if [ "${oom_detected}" -ne 0 ]; then
    return 1
  fi
  if [ "${running}" -ne "${total_node_num}" ]; then
    log ERROR "Cluster is not healthy: ready=${running}/${total_node_num}"
    return 1
  fi
  return 0
}

run_test() {
  local round=1
  start_workloads || { log ERROR "Benchmark failed during startup"; return 1; }
  delete_data_loop &
  delete_pid=$!
  log INFO "Delete loop PID=${delete_pid}"

  (
    sleep $((TEST_TIMEOUT_HOURS * 3600))
    log ERROR "Test watchdog reached ${TEST_TIMEOUT_HOURS} hours"
    kill -TERM $$
  ) &
  watchdog_pid=$!

  while [ "${round}" -le "${MIGRATION_ROUNDS}" ]; do
    log INFO "Migration round ${round}/${MIGRATION_ROUNDS}"
    refresh_node_ids || { log ERROR "Expected ${dn_num} running DataNode IDs"; return 1; }
    migrate_all_regions schema || return 1
    migrate_all_regions data || return 1
    check_cluster_and_oom || return 1
    check_benchmark_logs || return 1
    kill -0 "${bm1_pid}" 2>/dev/null && kill -0 "${bm2_pid}" 2>/dev/null || {
      log ERROR "One of the Benchmark writers exited unexpectedly"
      return 1
    }
    round=$((round + 1))
  done
  return 0
}

main() {
  : > "${case_log}"
  require_file "${conf_file}"
  require_file "${clean_env_dir}/clean_cluster_3c21d.sh"
  require_file "${prepare_env_dir}/start_cluster_v20.sh"
  [ -n "${os_user_name}" ] && [ -n "${testdb}" ] && [ -n "${db_dir}" ] && [ -n "${cli_dir}" ] && [ -n "${root_pw}" ] || {
    log ERROR "Required value missing in ${conf_file}"
    exit 2
  }

  log INFO "${CASE_ID} begins: testdb=${testdb}, topology=${cn_num}C${dn_num}D, dn_heap=${DN_HEAP_MEMORY}, schema_region_groups=${schema_region_group_num}, rounds=${MIGRATION_ROUNDS}"
  prepare_node_files
  clean_cluster || { log ERROR "3C21D cleanup/reset failed"; exit 3; }
  ensure_version_deployed || { log ERROR "3C21D version deployment failed"; exit 4; }
  configure_cluster || { log ERROR "3C21D configuration failed"; exit 4; }
  start_cluster || { log ERROR "3C21D startup failed"; exit 5; }

  if run_test; then
    log INFO "RESULT case=${CASE_ID} status=PASS rounds=${MIGRATION_ROUNDS} topology=${cn_num}C${dn_num}D"
    echo "${SCRIPT_NAME} pass."
    exit 0
  fi
  fail_flag=1
  check_cluster_and_oom || true
  log ERROR "RESULT case=${CASE_ID} status=FAIL topology=${cn_num}C${dn_num}D"
  echo "${SCRIPT_NAME} fail."
  exit "${fail_flag}"
}

main "$@"
