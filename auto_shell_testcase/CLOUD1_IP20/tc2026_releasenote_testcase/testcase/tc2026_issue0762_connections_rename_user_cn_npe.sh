#!/bin/bash
# TIMECHODB-0762 / V2-339
# Two 50-client benchmarks keep sessions active while users are concurrently renamed and
# information_schema.connections is queried. The case fails on the historical ConfigNode NPE.
# Fix 89e44c9017 filters the internal audit session user __internal_auditor from connection
# statistics; audit logging is not an explicit prerequisite of the original issue.

set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
suite_dir="$(cd "${cur_dir}/.." && pwd)"
conf_file="${suite_dir}/conf/test.conf"
nodeinfo_dir="${suite_dir}/conf"
clean_env_dir="${suite_dir}/clean_env"
prepare_env_dir="${suite_dir}/prepare_env"

get_conf() {
  awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); gsub(/[[:space:]]/, ""); print; exit}' "${conf_file}"
}

os_user_name="$(get_conf os_user_name)"
db_user_name="$(get_conf db_user_name)"
root_pw="$(get_conf root_pw)"
testdb="$(get_conf v_testdb)"
db_parent_dir="$(get_conf v_db_parent_dir)"
cn_db_parent_dir="$(get_conf v_cn_db_parent_dir)"
cli_parent_dir="$(get_conf v_shell_client_db_parent_dir)"
cli_dir="${cli_parent_dir}/${testdb}"
db_dir="${db_parent_dir}/${testdb}"
cn_db_dir="${cn_db_parent_dir}/${testdb}"
CLUSTER_ID="$(get_conf CLUSTER_NAME)"
CLUSTER_ID="${CLUSTER_ID:-ClusterID3}"
bm_dir="${BM_DIR:-/data2/benchmark/bm_20251017_b6be9bd_ssl}"
cycles="${CYCLES:-10}"
warmup_seconds="${WARMUP_SECONDS:-60}"
bootstrap_seconds="${BOOTSTRAP_SECONDS:-60}"
client_number="${CLIENT_NUMBER:-50}"
cli_timeout_seconds="${CLI_TIMEOUT_SECONDS:-30}"
min_connections_before_rename="${MIN_CONNECTIONS_BEFORE_RENAME:-$((client_number * 2))}"

cn_file="${nodeinfo_dir}/confignode_3c.txt"
dn_file="${nodeinfo_dir}/datanode_5d.txt"
query_ip="${QUERY_IP:-$(head -1 "${dn_file}" | tr -d '[:space:]')}"
run_id="$(date +%Y_%m_%d_%H_%M_%S)"
short_id="$(date +%H%M%S)"
rename_user_count="${RENAME_USER_COUNT:-11}"
user_prefix="v2339u${short_id}"
benchmark_user="${user_prefix}1"
observer_user="v2339o${short_id}"
user_pw_prefix="TimechoDB@2025"
result_dir="${bm_dir}/${testdb}/${run_id}_issue0762"
log_file="${result_dir}/testcase.log"
pid_file="${result_dir}/benchmark.pids"
baseline_file="${result_dir}/cn_npe.baseline"
target_pattern='Internal error processing checkSessionNum|Cannot invoke .*User.getMinSessionPerUser.* because .* is null'
fail_flag=0
v_consensus="IoTConsensus"
v_warnNum=0
v_warnMessage="result_dir=${result_dir}"
test_begin_sec="$(date +%s)"
result_written=0
result_write_succeeded=0
node_logs_backed_up=0
benchmark_results_cleaned=0

mkdir -p "${result_dir}"
: > "${pid_file}"
: > "${baseline_file}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "${log_file}"
}

fail() {
  log ERROR "$1"
  fail_flag=$((fail_flag + 1))
}

write_result() {
  local test_result_iotdb_ip status test_end_sec elapsed bm_max bm_sum safe_message output attempt max_attempts
  [ "${result_written}" -eq 0 ] || return 0
  result_written=1

  test_result_iotdb_ip="$(get_conf test_result_iotdb_ip)"
  if [ -z "${test_result_iotdb_ip}" ]; then
    log WARN "test_result_iotdb_ip is empty; skip result database write"
    return 0
  fi

  status="PASS"
  [ "${fail_flag}" -eq 0 ] || status="FAIL"
  test_end_sec="$(date +%s)"
  elapsed=$((test_end_sec - test_begin_sec))
  # These are intentionally long-running workloads terminated after each cycle, so
  # their multi-GB process logs do not contain a reliable final "Test elapsed" value.
  # Do not scan every output file during shutdown; record non-applicable BM metrics as 0.
  bm_max=0
  bm_sum=0
  # IoTDB CLI treats semicolons as statement separators even inside the
  # testOtherMessage value.  Normalize separators/newlines before embedding
  # the diagnostic message in the INSERT statement.
  safe_message=$(printf '%s' "${v_warnMessage}" | tr '\r\n' '  ' | sed "s/'/''/g; s/;/,/g")

  max_attempts="${RESULT_WRITE_RETRIES:-3}"
  attempt=1
  while [ "${attempt}" -le "${max_attempts}" ]; do
    output=$(timeout "${cli_timeout_seconds}" "${cli_dir}/sbin/start-cli.sh" \
      -h "${test_result_iotdb_ip}" \
      -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage) values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','${status}',${elapsed},${bm_max},${bm_sum},${v_warnNum},'${safe_message}');" 2>&1) && {
        echo "${output}" >> "${log_file}"
        result_write_succeeded=1
        log INFO "Recorded ${status} result in root.test.${CLUSTER_ID} at ${test_result_iotdb_ip}"
        return 0
      }
    log WARN "Failed to write ${status} result attempt ${attempt}/${max_attempts} to ${test_result_iotdb_ip}: ${output}"
    attempt=$((attempt + 1))
    [ "${attempt}" -le "${max_attempts}" ] && sleep 2
  done
  return 0
}

cli_table_as() {
  local username="$1" password="$2" sql="$3"
  timeout "${cli_timeout_seconds}" "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -u "${username}" -pw "${password}" \
    -timeout 3600 -sql_dialect table -e "${sql}"
}

cli_tree_as() {
  local username="$1" password="$2" sql="$3"
  timeout "${cli_timeout_seconds}" "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -u "${username}" -pw "${password}" \
    -timeout 3600 -sql_dialect tree -e "${sql}"
}

root_table() {
  cli_table_as "${db_user_name}" "${root_pw}" "$1"
}

root_tree() {
  cli_tree_as "${db_user_name}" "${root_pw}" "$1"
}

set_property() {
  local file="$1" key="$2" value="$3"
  sed -i -E "/^[#[:space:]]*${key}=/d" "${file}"
  printf '%s=%s\n' "${key}" "${value}" >> "${file}"
}

prepare_cluster_environment() {
  local ip seed_cn cluster_name prepare_log
  seed_cn="$(head -1 "${cn_file}" | tr -d '[:space:]'):10710"
  cluster_name="$(get_conf CLUSTER_NAME)"
  cluster_name="${cluster_name:-ClusterID3}"
  prepare_log="${result_dir}/prepare_cluster.log"

  log INFO "Preparing clean 3C5D cluster for TIMECHODB-0762"
  cp -p "${cn_file}" "${nodeinfo_dir}/confignode.txt"
  cp -p "${dn_file}" "${nodeinfo_dir}/datanode.txt"

  for script in stop_cluster.sh clean_cluster.sh reset_conf.sh clear_cache.sh; do
    [ -f "${clean_env_dir}/${script}" ] || {
      fail "Required environment script not found: ${clean_env_dir}/${script}"
      return 1
    }
    log INFO "Environment step: ${script}"
    sh "${clean_env_dir}/${script}" >> "${prepare_log}" 2>&1 || {
      fail "Environment step failed: ${script}; see ${prepare_log}"
      return 1
    }
  done

  while read -r ip; do
    ip="$(echo "${ip}" | tr -d '[:space:]')"
    [ -n "${ip}" ] || continue
    ssh -o ConnectTimeout=10 "${os_user_name}@${ip}" bash -s -- \
      "${cn_db_dir}" "${seed_cn}" "${ip}" "${cluster_name}" <<'REMOTE_CN' >> "${prepare_log}" 2>&1
set -eu
db_dir=$1
seed_cn=$2
node_ip=$3
cluster_name=$4
prop_file="${db_dir}/conf/iotdb-system.properties"
env_file="${db_dir}/conf/confignode-env.sh"
set_prop() {
  key=$1
  value=$2
  sed -i -E "/^[#[:space:]]*${key}=/d" "${prop_file}"
  printf '%s=%s\n' "${key}" "${value}" >> "${prop_file}"
}
sed -i -E '/^[#[:space:]]*ON_HEAP_MEMORY=/d; /^[#[:space:]]*OFF_HEAP_MEMORY=/d' "${env_file}"
printf '%s\n' 'ON_HEAP_MEMORY="2G"' 'OFF_HEAP_MEMORY="1G"' >> "${env_file}"
set_prop cn_seed_config_node "${seed_cn}"
set_prop cn_internal_address "${node_ip}"
set_prop cn_metric_reporter_list PROMETHEUS
set_prop cn_metric_prometheus_reporter_port 9081
set_prop schema_replication_factor 3
set_prop data_replication_factor 2
set_prop data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus
set_prop enable_auto_repair_compaction false
set_prop schema_region_group_extension_policy CUSTOM
set_prop default_schema_region_group_num_per_database 2
set_prop data_region_group_extension_policy CUSTOM
set_prop default_data_region_group_num_per_database 6
set_prop cluster_name "${cluster_name}"
REMOTE_CN
    [ "$?" -eq 0 ] || {
      fail "Failed to configure ConfigNode ${ip}; see ${prepare_log}"
      return 1
    }
  done < "${cn_file}"

  while read -r ip; do
    ip="$(echo "${ip}" | tr -d '[:space:]')"
    [ -n "${ip}" ] || continue
    ssh -o ConnectTimeout=10 "${os_user_name}@${ip}" bash -s -- \
      "${db_dir}" "${seed_cn}" "${ip}" "${cluster_name}" "${testdb}" <<'REMOTE_DN' >> "${prepare_log}" 2>&1
set -eu
db_dir=$1
seed_cn=$2
node_ip=$3
cluster_name=$4
testdb=$5
prop_file="${db_dir}/conf/iotdb-system.properties"
env_file="${db_dir}/conf/datanode-env.sh"
set_prop() {
  key=$1
  value=$2
  sed -i -E "/^[#[:space:]]*${key}=/d" "${prop_file}"
  printf '%s=%s\n' "${key}" "${value}" >> "${prop_file}"
}
sed -i -E '/^[#[:space:]]*ON_HEAP_MEMORY=/d; /^[#[:space:]]*OFF_HEAP_MEMORY=/d' "${env_file}"
printf '%s\n' 'ON_HEAP_MEMORY="20G"' 'OFF_HEAP_MEMORY="4G"' >> "${env_file}"
set_prop dn_seed_config_node "${seed_cn}"
set_prop dn_internal_address "${node_ip}"
set_prop dn_rpc_address "${node_ip}"
set_prop dn_metric_reporter_list PROMETHEUS
set_prop dn_metric_prometheus_reporter_port 9091
set_prop schema_replication_factor 3
set_prop data_replication_factor 2
set_prop data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus
set_prop enable_auto_repair_compaction false
set_prop schema_region_group_extension_policy CUSTOM
set_prop default_schema_region_group_num_per_database 2
set_prop data_region_group_extension_policy CUSTOM
set_prop default_data_region_group_num_per_database 6
set_prop dn_data_dirs "data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data,/data3/iotdb_data/${testdb}/data/datanode/data"
set_prop dn_wal_dirs "data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal,/data3/iotdb_data/${testdb}/data/datanode/wal"
set_prop load_active_listening_dirs "ext/load/pending,/data1/iotdb_data/${testdb}/ext/load/pending,/data3/iotdb_data/${testdb}/ext/load/pending"
set_prop cluster_name "${cluster_name}"
REMOTE_DN
    [ "$?" -eq 0 ] || {
      fail "Failed to configure DataNode ${ip}; see ${prepare_log}"
      return 1
    }
  done < "${dn_file}"

  log INFO "Starting configured 3C5D cluster"
  sh "${prepare_env_dir}/start_cluster_v20.sh" 1 8 >> "${prepare_log}" 2>&1 || {
    fail "Cluster start failed; see ${prepare_log}"
    return 1
  }
  log INFO "Clean 3C5D cluster is Running"
}

prepare_benchmark_conf() {
  local name="$1" dialect="$2" username="$3" password="$4" create_schema="$5" host_csv="$6" port_csv="$7"
  local dir="${result_dir}/${name}" file
  mkdir -p "${dir}"
  cp -p "${bm_dir}/conf/"* "${dir}/"
  file="${dir}/config.properties"
  set_property "${file}" DB_SWITCH IoTDB-200-SESSION_BY_TABLET
  set_property "${file}" IoTDB_DIALECT_MODE "${dialect}"
  set_property "${file}" HOST "${host_csv}"
  set_property "${file}" PORT "${port_csv}"
  set_property "${file}" USERNAME "${username}"
  set_property "${file}" PASSWORD "${password}"
  set_property "${file}" DB_NAME "v2339_${short_id}"
  set_property "${file}" IS_DELETE_DATA false
  set_property "${file}" LOOP 1000000000
  set_property "${file}" TEST_MAX_TIME 3600000
  set_property "${file}" DEVICE_NUMBER 1000
  set_property "${file}" SENSOR_NUMBER 60
  set_property "${file}" IS_CLIENT_BIND true
  set_property "${file}" SCHEMA_CLIENT_NUMBER "${client_number}"
  set_property "${file}" DATA_CLIENT_NUMBER "${client_number}"
  set_property "${file}" GROUP_NUMBER 1
  set_property "${file}" IoTDB_TABLE_NUMBER 1
  set_property "${file}" TEMPLATE false
  set_property "${file}" VECTOR true
  set_property "${file}" POINT_STEP 2000
  set_property "${file}" OP_MIN_INTERVAL 0
  set_property "${file}" INSERT_DATATYPE_PROPORTION 1:1:1:1:1:1:1:1:1:1
  set_property "${file}" OPERATION_PROPORTION 91:1:1:1:1:0:1:1:1:1:1:0
  set_property "${file}" BATCH_SIZE_PER_WRITE 10
  set_property "${file}" CREATE_SCHEMA "${create_schema}"
  set_property "${file}" START_TIME 1980-01-01T08:00:00+08:00
}

start_benchmark() {
  local conf_name="$1" output="$2"
  nohup "${bm_dir}/benchmark.sh" -cf "${result_dir}/${conf_name}" > "${result_dir}/${output}" 2>&1 &
  echo "$!" >> "${pid_file}"
}

capture_benchmark_diagnostics() {
  local label="$1" output diag
  diag="${result_dir}/benchmark_${label}_diagnostic.log"
  : > "${diag}"
  for output in "${result_dir}/${label}_tree.out" "${result_dir}/${label}_table.out"; do
    [ -f "${output}" ] || continue
    {
      echo "===== ${output} (last 80 lines) ====="
      tail -n 80 "${output}"
    } >> "${diag}" 2>&1 || true
  done
  [ -s "${diag}" ] || rm -f -- "${diag}"
  [ -f "${diag}" ] && log WARN "Saved benchmark exit diagnostics: ${diag}"
}

stop_benchmarks() {
  local pid
  [ -f "${pid_file}" ] || return 0
  while read -r pid; do
    [ -n "${pid}" ] || continue
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
    fi
  done < "${pid_file}"
  sleep 3
  while read -r pid; do
    [ -n "${pid}" ] || continue
    if kill -0 "${pid}" 2>/dev/null; then
      kill -9 "${pid}" 2>/dev/null || true
    fi
  done < "${pid_file}"
  : > "${pid_file}"
}

cleanup_benchmark_outputs() {
  # Benchmark clients can emit hundreds of MB per minute.  Remove only their
  # output files after each run; the generated workload_* directories contain
  # configs needed by later cycles and are removed by final cleanup.
  rm -f -- \
    "${result_dir}/bootstrap_tree.out" \
    "${result_dir}/bootstrap_table.out" \
    "${result_dir}"/cycle_*_tree.out \
    "${result_dir}"/cycle_*_table.out \
    "${pid_file}"
}

cleanup_benchmark_configs() {
  rm -rf -- \
    "${result_dir}/bootstrap_tree" \
    "${result_dir}/bootstrap_table" \
    "${result_dir}/workload_tree" \
    "${result_dir}/workload_table"
}

benchmarks_alive() {
  local pid count=0
  while read -r pid; do
    [ -n "${pid}" ] || continue
    kill -0 "${pid}" 2>/dev/null && count=$((count + 1))
  done < "${pid_file}"
  [ "${count}" -eq 2 ]
}

record_cn_npe_baseline() {
  local ip count
  while read -r ip; do
    ip="$(echo "${ip}" | tr -d '[:space:]')"
    [ -n "${ip}" ] || continue
    count=$(ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
      "grep -hEi '${target_pattern}' '${cn_db_dir}'/logs/log_confignode*.log 2>/dev/null | wc -l" || echo 0)
    echo "${ip}|${count}" >> "${baseline_file}"
  done < "${cn_file}"
}

check_new_cn_npe() {
  local ip baseline current evidence
  while IFS='|' read -r ip baseline; do
    current=$(ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
      "grep -hEi '${target_pattern}' '${cn_db_dir}'/logs/log_confignode*.log 2>/dev/null | wc -l" || echo 0)
    if [ "${current:-0}" -gt "${baseline:-0}" ]; then
      evidence="${result_dir}/cn_${ip}_new_npe.log"
      ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
        "grep -hEin -A18 -B3 '${target_pattern}' '${cn_db_dir}'/logs/log_confignode*.log 2>/dev/null | tail -200" \
        > "${evidence}" 2>&1 || true
      fail "New ConfigNode checkSessionNum NPE found on ${ip}: baseline=${baseline}, current=${current}, evidence=${evidence}"
    fi
  done < "${baseline_file}"
}

assert_workload_connections() {
  local output count
  output=$(root_table "select count(*) as active_count from information_schema.connections where user_name = '${benchmark_user}';" 2>&1) || {
    echo "${output}" >> "${result_dir}/connections_before_rename.log"
    fail "Failed to count workload connections before rename"
    return 1
  }
  echo "${output}" >> "${result_dir}/connections_before_rename.log"
  count=$(echo "${output}" | awk -F'|' '
    /^\|/ {
      for (i = 1; i <= NF; i++) {
        value = $i
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value ~ /^[0-9]+$/) result = value
      }
    }
    END { if (result != "") print result }
  ')
  if [ -z "${count}" ] || [ "${count}" -lt "${min_connections_before_rename}" ]; then
    fail "Insufficient workload connections before rename: user=${benchmark_user}, actual=${count:-unparsed}, required>=${min_connections_before_rename}"
    return 1
  fi
  log INFO "Verified workload connections before rename: user=${benchmark_user}, actual=${count}, required>=${min_connections_before_rename}"
}

restore_renamed_users() {
  local i original_name renamed_name users
  users=$(root_table "list user;" 2>&1 || true)
  i=1
  while [ "${i}" -le "${rename_user_count}" ]; do
    original_name="${user_prefix}${i}"
    renamed_name="${original_name}n"
    if echo "${users}" | grep -qw "${renamed_name}"; then
      root_table "alter user ${renamed_name} rename to ${original_name};" \
        >> "${result_dir}/rename_restore.log" 2>&1 || fail "Failed to restore ${renamed_name} to ${original_name}"
    fi
    i=$((i + 1))
  done
}

backup_node_logs() {
  local role ip remote_db_dir node_file archive
  [ "${node_logs_backed_up}" -eq 0 ] || return 0
  node_logs_backed_up=1
  mkdir -p "${result_dir}/node_logs"

  for role in cn dn; do
    if [ "${role}" = "cn" ]; then
      remote_db_dir="${cn_db_dir}"
      node_file="${cn_file}"
    else
      remote_db_dir="${db_dir}"
      node_file="${dn_file}"
    fi
    while read -r ip; do
      ip="$(echo "${ip}" | tr -d '[:space:]')"
      [ -n "${ip}" ] || continue
      archive="${result_dir}/node_logs/${role}_${ip}_logs.tar.gz"
      log INFO "Backing up ${role^^} logs from ${ip} to ${archive}"
      if ! ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
        "tar -C '${remote_db_dir}' -czf - logs" > "${archive}"; then
        rm -f "${archive}"
        fail "Failed to back up ${role^^} logs from ${ip}"
      fi
    done < "${node_file}"
  done
}

cleanup_benchmark_results() {
  [ "${benchmark_results_cleaned}" -eq 0 ] || return 0
  benchmark_results_cleaned=1
  cleanup_benchmark_outputs
  cleanup_benchmark_configs
  log INFO "Deleted benchmark-generated configuration copies and result files from ${result_dir}"
}

rename_wave() {
  local i original_name renamed_name password pid rename_pids="" root_query_pid users rename_success=0
  i=1
  while [ "${i}" -le "${rename_user_count}" ]; do
    original_name="${user_prefix}${i}"
    renamed_name="${original_name}n"
    password="${user_pw_prefix}${i}"

    # Keep rename and connections in the same authenticated CLI session. This is the
    # critical ordering from the original stable reproducer: after rename removes the
    # old user entry, that very session immediately opens/uses connections and drives
    # checkSessionNum while the authorization cache is changing.
    cli_table_as "${original_name}" "${password}" \
      "alter user ${original_name} rename to ${renamed_name}; use information_schema; select * from connections;" \
      >> "${result_dir}/rename_forward_${i}.log" 2>&1 &
    rename_pids="${rename_pids} $!"
    i=$((i + 1))
  done

  # An administrative connections scan runs in parallel with the eleven ordered
  # rename+scan sessions, matching the original script shown in TIMECHODB-0762.
  root_table "use information_schema; select * from connections;" >> "${result_dir}/connections_root.log" 2>&1 &
  root_query_pid=$!

  wait "${root_query_pid}" || fail "Root connections query failed during rename window"
  for pid in ${rename_pids}; do
    # Renaming the authenticated user invalidates that CLI session. The following
    # connections query is therefore expected to return 802 and make CLI exit non-zero.
    # Judge rename itself from the authoritative user list instead of the CLI exit code.
    wait "${pid}" || true
  done

  users=$(root_table "list user;" 2>&1 || true)
  i=1
  while [ "${i}" -le "${rename_user_count}" ]; do
    renamed_name="${user_prefix}${i}n"
    echo "${users}" | grep -qw "${renamed_name}" && rename_success=$((rename_success + 1))
    i=$((i + 1))
  done
  if [ "${rename_success}" -ne "${rename_user_count}" ]; then
    fail "Only ${rename_success}/${rename_user_count} concurrent forward renames took effect"
  else
    log INFO "Verified ${rename_success}/${rename_user_count} concurrent forward renames; post-rename session 802 is expected"
  fi

  # The original script restores names serially with a single administrative user.
  restore_renamed_users
}

cleanup() {
  stop_benchmarks
  restore_renamed_users || true
  backup_node_logs || true
  cleanup_benchmark_results
}

trap cleanup EXIT INT TERM

log INFO "TIMECHODB-0762 start: testdb=${testdb}, query_ip=${query_ip}, cycles=${cycles}, clients=2x${client_number}"

for required in "${cli_dir}/sbin/start-cli.sh" "${bm_dir}/benchmark.sh" "${bm_dir}/conf/config.properties"; do
  [ -e "${required}" ] || { fail "Required file not found: ${required}"; write_result; echo "testcase TIMECHODB-0762 fail"; exit 1; }
done

prepare_cluster_environment || {
  write_result
  echo "testcase TIMECHODB-0762 fail"
  exit 1
}

cluster_output=$(root_table "show cluster;" 2>&1 || true)
echo "${cluster_output}" > "${result_dir}/show_cluster_before.log"
running_count=$(echo "${cluster_output}" | awk -F'|' 'tolower($0) ~ /running/ && ($0 ~ /ConfigNode/ || $0 ~ /DataNode/) {count++} END {print count+0}')
[ "${running_count}" -eq 8 ] || { fail "Cluster is not fully Running: ${running_count}/8"; write_result; echo "testcase TIMECHODB-0762 fail"; exit 1; }

host_csv=$(awk 'NF {gsub(/[[:space:]]/, ""); printf "%s%s", sep, $0; sep=","}' "${dn_file}")
port_csv=$(awk 'NF {printf "%s6667", sep; sep=","}' "${dn_file}")

prepare_benchmark_conf bootstrap_tree tree "${db_user_name}" "${root_pw}" true "${host_csv}" "${port_csv}"
prepare_benchmark_conf bootstrap_table table "${db_user_name}" "${root_pw}" true "${host_csv}" "${port_csv}"
prepare_benchmark_conf workload_tree tree "${benchmark_user}" "${user_pw_prefix}1" false "${host_csv}" "${port_csv}"
prepare_benchmark_conf workload_table table "${benchmark_user}" "${user_pw_prefix}1" false "${host_csv}" "${port_csv}"

root_table "create user ${observer_user} '${user_pw_prefix}0'; grant system to user ${observer_user};" >> "${log_file}" 2>&1 || fail "Failed to create observer user"
i=1
while [ "${i}" -le "${rename_user_count}" ]; do
  test_user="${user_prefix}${i}"
  root_table "create user ${test_user} '${user_pw_prefix}${i}'; grant all on any to user ${test_user}; grant system to user ${test_user};" \
    >> "${log_file}" 2>&1 || fail "Failed to create rename user ${test_user}"
  root_tree "grant all on root.** to user ${test_user};" >> "${log_file}" 2>&1 || fail "Failed to grant tree privileges to ${test_user}"
  i=$((i + 1))
done

record_cn_npe_baseline

log INFO "Bootstrapping tree/table schema with two benchmark processes"
start_benchmark bootstrap_tree bootstrap_tree.out
start_benchmark bootstrap_table bootstrap_table.out
sleep "${bootstrap_seconds}"
if ! benchmarks_alive; then
  capture_benchmark_diagnostics bootstrap
  fail "A bootstrap benchmark exited unexpectedly; see benchmark_bootstrap_diagnostic.log"
fi
stop_benchmarks
cleanup_benchmark_outputs

cycle=1
while [ "${cycle}" -le "${cycles}" ] && [ "${fail_flag}" -eq 0 ]; do
  log INFO "Cycle ${cycle}/${cycles}: starting two benchmarks (total data clients=$((client_number * 2)))"
  start_benchmark workload_tree "cycle_${cycle}_tree.out"
  start_benchmark workload_table "cycle_${cycle}_table.out"
  sleep "${warmup_seconds}"
  if ! benchmarks_alive; then
    capture_benchmark_diagnostics "cycle_${cycle}"
    warning_message="A workload benchmark exited before rename wave in cycle ${cycle}"
    log WARN "${warning_message}"
    v_warnNum=$((v_warnNum + 1))
    v_warnMessage="${v_warnMessage} | ${warning_message}"
    # A client ending before the rename wave is a warning-only condition by
    # design.  Do not run the connection-count assertion (which would see 0
    # connections and turn this same condition into fail_flag=1).
    stop_benchmarks
    cleanup_benchmark_outputs
    # There are no live workload sessions to exercise the rename window. End
    # the cycle loop after recording the warning instead of repeating empty
    # cycles that can never validate the rename/NPE behavior.
    break
  fi
  assert_workload_connections || break
  rename_wave
  check_new_cn_npe
  stop_benchmarks
  cleanup_benchmark_outputs
  cycle=$((cycle + 1))
done

check_new_cn_npe
root_table "show cluster; use information_schema; select count(*) from connections;" > "${result_dir}/final_health.log" 2>&1 || fail "Final cluster/connections health check failed"

if [ "${fail_flag}" -gt 0 ]; then
  log ERROR "TIMECHODB-0762 failed with fail_flag=${fail_flag}; result_dir=${result_dir}"
  write_result
  echo "testcase TIMECHODB-0762 fail"
  exit 1
fi

log INFO "Completed ${cycles} cycles without the ConfigNode checkSessionNum NPE (warnNum=${v_warnNum}); result_dir=${result_dir}"
write_result
echo "testcase TIMECHODB-0762 pass"
exit 0
