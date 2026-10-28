#!/bin/bash
# TDB-291 / V2.0.11.1
# With subscription_enabled=false, DataNode must not start Subscription Runtime Agent.
# The cluster lifecycle follows the remote August testcase layout as a reference.
set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
conf_file="${cur_dir}/../conf/test.conf"
clean_dir="${cur_dir}/../clean_env"
prepare_dir="${cur_dir}/../prepare_env"
read_conf() {
  local key=$1 default=${2:-} value
  value=$(awk -F= -v k="$key" '$1 == k {sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit}' "$conf_file")
  printf '%s' "${value:-$default}"
}
os_user_name="$(read_conf os_user_name root)"
db_user_name="$(read_conf db_user_name root)"
root_pw="$(read_conf root_pw TimechoDB@2021)"
testdb="${TESTDB:-$(read_conf v_testdb)}"
db_parent_dir="$(read_conf v_db_parent_dir /data/iotdb)"
cn_db_parent_dir="$(read_conf v_cn_db_parent_dir "$db_parent_dir")"
shell_client_db_parent_dir="$(read_conf v_shell_client_db_parent_dir "$db_parent_dir")"
cluster_id="$(read_conf CLUSTER_NAME timecho)"
prometheus_url="$(read_conf monitor_url)"
dn_num=3; cn_num=3; total_node_num=$((dn_num + cn_num)); sr_rep_num=3; dr_rep_num=3
cluster_start_timeout="${CLUSTER_START_TIMEOUT_SECONDS:-600}"
observe_seconds="${OBSERVE_SECONDS:-60}"
benchmark_home="${cur_dir}/../benchmark/bm_20260812_e158c2c_jdk17"
benchmark_template="${benchmark_home}/obj_ttl"
benchmark_duration="${BENCHMARK_DURATION_SECONDS:-300}"
benchmark_timeout="${BENCHMARK_TIMEOUT_SECONDS:-360}"
benchmark_db_name="${BENCHMARK_DB_NAME:-tdb419_show_system_info}"

# The shared lifecycle helpers consume generic lists, as in the remote August testcase.
cp -fp "${cur_dir}/../conf/datanode_${dn_num}d.txt" "${cur_dir}/../conf/datanode.txt"
cp -fp "${cur_dir}/../conf/confignode_${cn_num}c.txt" "${cur_dir}/../conf/confignode.txt"
cn_list="${cur_dir}/../conf/confignode.txt"; dn_list="${cur_dir}/../conf/datanode.txt"
query_ip="$(head -1 "$dn_list" | tr -d ' \r')"
seed_cn_ip="$(head -1 "$cn_list" | tr -d ' \r'):10710"
db_dir="${db_parent_dir}/${testdb}"; cli_dir="${shell_client_db_parent_dir}/${testdb}"
run_id="$(basename "$0" .sh)_$(date +%Y%m%d_%H%M%S)"
artifact_dir="${cur_dir}/${run_id}"; log_file="${artifact_dir}/run.log"; result_csv="${cur_dir}/test_result.csv"
mkdir -p "$artifact_dir"; : > "$log_file"
fail_flag=0; started_flag=0; result_written=0; runtime_agent_matches=0; v_warnMessage=""; start_epoch=$(date +%s)
log() { echo "[$(date '+%F %T')] $*" | tee -a "$log_file"; }
fail() { fail_flag=1; v_warnMessage+="$1 "; log "ERROR $1"; }
require_file() { [[ -f "$1" ]] || { fail "required file is missing: $1"; return 1; }; }
node_lines() { tr -d ' \r' < "$1" | awk 'NF'; }
remote() { local node=$1 command=$2; ssh -n -o BatchMode=yes -o ConnectTimeout=15 "${os_user_name}@${node}" "$command"; }

set_node_conf() {
  local node=$1 role=$2 internal_key seed_key rpc_key env_file heap offheap
  if [[ "$role" == cn ]]; then internal_key=cn_internal_address; seed_key=cn_seed_config_node; rpc_key=cn_internal_address; env_file=confignode-env.sh; heap=2G; offheap=1G
  else internal_key=dn_internal_address; seed_key=dn_seed_config_node; rpc_key=dn_rpc_address; env_file=datanode-env.sh; heap=24G; offheap=2G; fi
  local payload
  payload=$(cat <<EOF
set -e
p='$db_dir/conf/iotdb-system.properties'; env='$db_dir/conf/$env_file'
set_prop() { k=\$1; v=\$2; if grep -qE "^[#[:space:]]*\${k}[[:space:]]*=" "\$p"; then sed -i -E "s|^[#[:space:]]*\${k}[[:space:]]*=.*|\${k}=\${v}|" "\$p"; else printf '%s=%s\\n' "\${k}" "\${v}" >> "\$p"; fi; }
set_mem() { k=\$1; v=\$2; if grep -qE "^#?\${k}=" "\$env"; then sed -i -E "s|^#*\${k}=.*|\${k}=\"\${v}\"|" "\$env"; else printf '%s=\"%s\"\\n' "\${k}" "\${v}" >> "\$env"; fi; }
set_prop ${internal_key} ${node}; set_prop ${seed_key} ${seed_cn_ip}; set_prop ${rpc_key} ${node}; set_prop cn_metric_reporter_list PROMETHEUS
set_prop schema_replication_factor ${sr_rep_num}; set_prop data_replication_factor ${dr_rep_num}; set_prop subscription_enabled false; set_prop cluster_name ${cluster_id}
set_mem ON_HEAP_MEMORY ${heap}; set_mem OFF_HEAP_MEMORY ${offheap}
grep -qE '^subscription_enabled=false[[:space:]]*$' "\$p"; grep -qE '^schema_replication_factor=${sr_rep_num}[[:space:]]*$' "\$p"; grep -qE '^data_replication_factor=${dr_rep_num}[[:space:]]*$' "\$p"
EOF
)
  remote "$node" "$payload" >> "$log_file" 2>&1 || { fail "configuration verification failed on $node"; return 1; }
}
install_license() {
  local node=$1
  remote "$node" "set -e; test -f '$db_parent_dir/license_2026/license'; test -f '$db_parent_dir/license_2026/.env'; mkdir -p '$db_dir/activation'; cp -pf '$db_parent_dir/license_2026/license' '$db_dir/activation/license'; cp -pf '$db_parent_dir/license_2026/.env' '$db_dir/.env'; test -f '$db_dir/activation/license'; test -f '$db_dir/.env'" >> "$log_file" 2>&1 || { fail "license installation failed on $node"; return 1; }
}
cli_table() { "$cli_dir/sbin/start-cli.sh" -u "$db_user_name" -pw "$root_pw" -h "$query_ip" -timeout 3600 -sql_dialect table -e "$1"; }
wait_cluster_ready() {
  local deadline=$(( $(date +%s) + cluster_start_timeout )) output ready
  while (( $(date +%s) < deadline )); do
    output=$(cli_table 'show cluster;' 2>&1 || true); ready=$(printf '%s\n' "$output" | grep -Ec 'Running|ReadOnly' || true); log "cluster readiness=${ready}/${total_node_num}"
    if (( ready == total_node_num )); then printf '%s\n' "$output" > "${artifact_dir}/show_cluster.out"; return 0; fi
    printf '%s\n' "$output" > "${artifact_dir}/show_cluster.last.out"; sleep 5
  done
  fail "cluster did not become ready within ${cluster_start_timeout}s"; return 1
}
verify_datanodes() {
  local node
  while read -r node; do [[ -z "$node" ]] && continue; remote "$node" "jps -l 2>/dev/null | grep -Eq 'com\\.timecho\\.iotdb\\.DataNode|org\\.apache\\.iotdb\\..*DataNode'" || fail "DataNode process is not alive on $node"; done < "$dn_list"
}
collect_runtime_evidence() {
  local node evidence_file count
  : > "${artifact_dir}/subscription_runtime_agent_matches.log"
  while read -r node; do
    [[ -z "$node" ]] && continue; evidence_file="${artifact_dir}/datanode_${node}_subscription.log"
    # CN and DN share the same installation directory on 99.80. Restrict the
    # evidence to DataNode-named log files so CN SubscriptionMetaSyncer logs
    # cannot be mistaken for a DataNode Runtime Agent startup.
    remote "$node" "find '$db_dir/logs' -maxdepth 1 -type f \( -name '*datanode*all*' -o -name 'log_datanode_*' \) -print0 2>/dev/null | xargs -0 -r zgrep -hEi -- 'Subscription Runtime Agent|SubscriptionRuntimeAgent|subscription runtime state|runtime status|applyRuntimeStateForRegion|subscription.*started successfully' 2>/dev/null" > "$evidence_file" || true
    count=$(wc -l < "$evidence_file" | tr -d ' '); runtime_agent_matches=$((runtime_agent_matches + count))
    if (( count > 0 )); then { echo "===== node ${node} (${count} matches) ====="; cat "$evidence_file"; } >> "${artifact_dir}/subscription_runtime_agent_matches.log"; fi
  done < "$dn_list"
  if (( runtime_agent_matches > 0 )); then fail "Subscription Runtime Agent/runtime-state log detected with subscription_enabled=false (matches=${runtime_agent_matches})"; else log "PASS assertion: no Subscription Runtime Agent/runtime-state log detected"; fi
}
collect_node_log_errors() {
  local node role log_role node_dir output_file node_list
  log "check ConfigNode and DataNode error logs"
  while read -r role; do
    if [[ "$role" == cn ]]; then
      log_role=confignode; node_dir="${cn_db_parent_dir}/${testdb}"; node_list="$cn_list"
    else
      log_role=datanode; node_dir="$db_dir"; node_list="$dn_list"
    fi
    while read -r node; do
      [[ -z "$node" ]] && continue
      output_file="${artifact_dir}/${role}_${node}_errors.log"
      : > "$output_file"
      # Keep ConfigNode and DataNode files separate even when both roles use
      # the same installation directory on the test host.
      remote "$node" "find '$node_dir/logs' -maxdepth 1 -type f \( -name '*${log_role}*all*' -o -name 'log_${log_role}_*' \) -print0 2>/dev/null | xargs -0 -r zgrep -hEi -- '(^|[[:space:]])(ERROR|FATAL)[[:space:]]|OutOfMemoryError|Java heap space|GC overhead|unable to create native thread|Too many open files|RejectedExecutionException|TTransportException|Connection refused|Connection reset|SocketTimeoutException|NullPointerException|BufferUnderflowException|CompactionTableSchemaNotMatchException|NegativeArraySizeException|ArrayIndexOutOfBoundsException|IndexOutOfBoundsException|failed to start' 2>/dev/null | tail -200" > "$output_file" || true
      if [[ -s "$output_file" ]]; then
        fail "${role^^} error/exception logs detected on ${node}; see ${output_file}"
      else
        log "PASS ${role^^} log check: no ERROR/Exception/FATAL entries on ${node}"
      fi
    done < "$node_list"
  done <<< $'cn\ndn'
}
write_result() {
  [[ "$result_written" -eq 1 ]] && return; result_written=1; local elapsed=$(( $(date +%s) - start_epoch )) result=FAIL; [[ "$fail_flag" -eq 0 ]] && result=PASS
  [[ -f "$result_csv" ]] || echo 'Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage,maxBMTestTimeSec,sumBMTestTimeSec' >> "$result_csv"
  printf '%s,\x27%s\x27,\x27IoTConsensus\x27,\x27%s\x27,\x27%s\x27,%s,%s,\x27%s\x27,0,0\n' "$(date --iso-8601=seconds)" "$testdb" "$(basename "$0")" "$result" "$elapsed" "$fail_flag" "${v_warnMessage//\'/\'}" >> "$result_csv"
  echo "testcase TDB419_show_system_info_client_pool_oom ${result,,}"; log "RESULT result=${result} fail_flag=${fail_flag} runtime_agent_matches=${runtime_agent_matches} artifact=${artifact_dir}"
}
on_exit() {
  local rc=$?; trap - EXIT
  if (( started_flag == 1 )); then collect_runtime_evidence || true; collect_node_log_errors || true; timeout --preserve-status 600 bash -x "$clean_dir/stop_cluster.sh" >> "$log_file" 2>&1 || fail "cluster stop failed or timed out"; bash -x "$clean_dir/backup_cluster_logs.sh" "$run_id" >> "$log_file" 2>&1 || fail "cluster log backup failed"; fi
  if (( rc != 0 )); then fail_flag=1; v_warnMessage+="unexpected script exit status=$rc "; fi
  (( fail_flag != 0 )) && rc=1; write_result; exit "$rc"
}
trap on_exit EXIT

main() {
  require_file "$conf_file" || return 1; require_file "$cn_list" || return 1; require_file "$dn_list" || return 1
  require_file "$clean_dir/stop_cluster.sh" || return 1; require_file "$clean_dir/clean_cluster.sh" || return 1; require_file "$clean_dir/reset_conf.sh" || return 1; require_file "$prepare_dir/start_cluster_v20.sh" || return 1
  log "TDB-419 SHOW SYSTEM INFO testdb=${testdb} 3C3D SR=${sr_rep_num} DR=${dr_rep_num} subscription_enabled=false"; log "reference lifecycle: clean_env + prepare_env/start_cluster_v20.sh"
  timeout --preserve-status 600 bash -x "$clean_dir/stop_cluster.sh" >> "$log_file" 2>&1 || true; bash -x "$clean_dir/clean_cluster.sh" >> "$log_file" 2>&1 || fail "clean_cluster failed"; bash -x "$clean_dir/reset_conf.sh" >> "$log_file" 2>&1 || fail "reset_conf failed"; bash -x "$clean_dir/clear_cache.sh" >> "$log_file" 2>&1 || true; (( fail_flag != 0 )) && return 1
  while read -r node; do [[ -z "$node" ]] && continue; set_node_conf "$node" cn || true; install_license "$node" || true; done < "$cn_list"
  while read -r node; do [[ -z "$node" ]] && continue; set_node_conf "$node" dn || true; install_license "$node" || true; done < "$dn_list"; (( fail_flag != 0 )) && return 1
  started_flag=1; log "start 3C3D cluster with start_cluster_v20.sh"; if ! timeout --preserve-status "${cluster_start_timeout}s" bash -x "$prepare_dir/start_cluster_v20.sh" 1 "$total_node_num" >> "$log_file" 2>&1; then fail "cluster startup failed or timed out"; return 1; fi
  wait_cluster_ready || return 1; verify_datanodes
  require_file "${benchmark_home}/benchmark.sh" || return 1
  require_file "${benchmark_template}/config.properties" || return 1
  local benchmark_group_name_prefix benchmark_table_name_prefix benchmark_db benchmark_table benchmark_conf benchmark_log benchmark_pid
  benchmark_group_name_prefix=$(awk -F= '/^GROUP_NAME_PREFIX=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${benchmark_template}/config.properties")
  benchmark_table_name_prefix=$(awk -F= '/^IoTDB_TABLE_NAME_PREFIX=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${benchmark_template}/config.properties")
  benchmark_group_name_prefix="${benchmark_group_name_prefix:-g_}"
  benchmark_table_name_prefix="${benchmark_table_name_prefix:-table_}"
  benchmark_db="${benchmark_db_name}_${benchmark_group_name_prefix}0"
  benchmark_table="${benchmark_table_name_prefix}0"
  benchmark_conf="${artifact_dir}/obj_ttl"
  benchmark_log="${artifact_dir}/benchmark.log"
  log "create benchmark database ${benchmark_db} and write OBJECT data for ${benchmark_duration}s"
  cli_table "create database ${benchmark_db};" >> "$log_file" 2>&1 || fail "benchmark database creation failed: ${benchmark_db}"
  if ! cp -rp "$benchmark_template" "$benchmark_conf"; then fail "cannot copy OBJECT benchmark template"; return 1; fi
  # The template has current-time writes enabled. Use its fixed START_TIME so
  # this testcase remains reproducible across environments.
  sed -i -E \
    "s|^[#[:space:]]*HOST=.*|HOST=${query_ip}|; s|^[#[:space:]]*PORT=.*|PORT=6667|; s|^[#[:space:]]*USERNAME=.*|USERNAME=${db_user_name}|; s|^[#[:space:]]*PASSWORD=.*|PASSWORD=${root_pw}|; s|^[#[:space:]]*DB_NAME=.*|DB_NAME=${benchmark_db_name}|; s|^[#[:space:]]*IS_RECORD_CURRENT_REALLY_TIME=.*|IS_RECORD_CURRENT_REALLY_TIME=false|; s|^[#[:space:]]*LOOP=.*|LOOP=${benchmark_duration}|; s|^[#[:space:]]*DEVICE_NUMBER=.*|DEVICE_NUMBER=30|; s|^[#[:space:]]*SENSOR_NUMBER=.*|SENSOR_NUMBER=10|; s|^[#[:space:]]*SCHEMA_CLIENT_NUMBER=.*|SCHEMA_CLIENT_NUMBER=1|; s|^[#[:space:]]*DATA_CLIENT_NUMBER=.*|DATA_CLIENT_NUMBER=3|; s|^[#[:space:]]*BATCH_SIZE_PER_WRITE=.*|BATCH_SIZE_PER_WRITE=10|; s|^[#[:space:]]*DEVICE_NUM_PER_WRITE=.*|DEVICE_NUM_PER_WRITE=1|; s|^[#[:space:]]*OP_MIN_INTERVAL=.*|OP_MIN_INTERVAL=1000|" \
    "${benchmark_conf}/config.properties"
  grep -qE '^IS_RECORD_CURRENT_REALLY_TIME=false[[:space:]]*$' "${benchmark_conf}/config.properties" || {
    printf '%s\n' 'IS_RECORD_CURRENT_REALLY_TIME=false' >> "${benchmark_conf}/config.properties"
  }
  grep -qE '^OP_MIN_INTERVAL=' "${benchmark_conf}/config.properties" || printf '%s\n' 'OP_MIN_INTERVAL=1000' >> "${benchmark_conf}/config.properties"
  log "benchmark config: DB_NAME=${benchmark_db_name}, actual_database=${benchmark_db}, table=${benchmark_table}, OBJECT proportion enabled, fixed START_TIME"
  log "run benchmark: ${benchmark_home}/benchmark.sh -cf ${benchmark_conf}"
  timeout --preserve-status "${benchmark_timeout}s" "$benchmark_home/benchmark.sh" -cf "$benchmark_conf" > "$benchmark_log" 2>&1 &
  benchmark_pid=$!
  log "benchmark started pid=${benchmark_pid}; waiting for completion (timeout=${benchmark_timeout}s)"
  if ! wait "$benchmark_pid"; then
    fail "benchmark failed or timed out (pid=${benchmark_pid}); full log=${benchmark_log}"
  else
    log "benchmark finished successfully; full log retained at ${benchmark_log}"
  fi
  if [[ -f "$benchmark_log" ]]; then tail -c 65536 "$benchmark_log" > "${artifact_dir}/benchmark_tail.log" || true; fi
  cli_table "select count(*) from ${benchmark_db}.${benchmark_table};" >> "$log_file" 2>&1 || fail "benchmark row-count query failed"
  log "flush after OBJECT benchmark"
  if ! cli_table "flush;" >> "$log_file" 2>&1; then fail "flush failed after OBJECT benchmark"; fi
  log "observe DataNode logs for ${observe_seconds}s after flush"; sleep "$observe_seconds"
  stress_show_system_info
  check_tdb419_sync_lag
  check_tdb419_replicas
  return 0
}
check_tdb419_health() {
  local label=$1 node pid rss out
  local f="${artifact_dir}/health_${label}.log"
  : > "$f"
  while read -r node; do
    [[ -z "$node" ]] && continue
    pid=$(ssh -n -o BatchMode=yes -o ConnectTimeout=15 "${os_user_name}@${node}" "jps -l 2>/dev/null | grep com.timecho.iotdb.service.ConfigNode | head -1 | cut -d" " -f1" 2>/dev/null || true)
    rss=$(ssh -n -o BatchMode=yes -o ConnectTimeout=15 "${os_user_name}@${node}" "ps -o rss= -p ${pid:-0} 2>/dev/null | tr -d ' '" 2>/dev/null || true)
    printf '%s node=%s pid=%s rss_kb=%s\n' "$label" "$node" "${pid:-missing}" "${rss:-missing}" >> "$f"
    [[ -n "$pid" ]] || fail "ConfigNode process missing on $node during SHOW SYSTEM INFO stress"
  done < "$cn_list"
}
check_tdb419_heap_artifacts() {
  local node out
  while read -r node; do
    [[ -z "$node" ]] && continue
    out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=15 "${os_user_name}@${node}" "find '$db_dir' -maxdepth 1 -type f \\( -name '*heapdump*' -o -name 'hs_err_pid*' \\) -printf '%f %s bytes\\n' 2>/dev/null" 2>/dev/null || true)
    if [[ -n "$out" ]]; then printf '%s\n' "$out" >> "${artifact_dir}/heap_artifacts.log"; fail "heap dump or hs_err artifact detected on $node"; fi
  done < <(cat "$cn_list" "$dn_list" | awk 'NF&&!/^#/ {print $1}' | sort -u)
}

stress_show_system_info() {
  local d="$artifact_dir/show_system_info"; mkdir -p "$d"; local workers loops
  workers=$(printenv SHOW_INFO_WORKERS 2>/dev/null || echo 32); loops=$(printenv SHOW_INFO_LOOPS 2>/dev/null || echo 500)
  log "TDB-419 SHOW SYSTEM INFO workers=$workers loops=$loops"
  check_tdb419_health pre_stress
  worker() { local id="$1" i out; : > "$d/worker_$id.log"; for i in $(seq 1 "$loops"); do out=$(cli_table "show system info;" 2>&1) || { echo "CLI_FAILED iteration=$i" >> "$d/worker_$id.log"; return 1; }; echo "$out" | grep -Eiq 'OutOfMemoryError|Java heap space|GC overhead|Connection refused|Connection reset|Cannot connect|Unable to connect' && { echo "BAD_RESPONSE iteration=$i" >> "$d/worker_$id.log"; return 1; }; done; echo "completed loops=$loops" >> "$d/worker_$id.log"; }
  local pids=() w rc=0; for w in $(seq 1 "$workers"); do worker "$w" & pids+=("$!"); done; for w in ${pids[*]}; do wait "$w" || rc=1; done
  (( rc == 0 )) && log "TDB-419 SHOW SYSTEM INFO stress completed" || fail "TDB-419 SHOW SYSTEM INFO CLI failure; see $d"
  check_tdb419_health post_stress
  check_tdb419_heap_artifacts
}
check_tdb419_replicas() {
  local n out count expected=""
  while read -r n; do [ -z "$n" ] && continue; out=$(cli_table_host "$n" "select count(*) from $benchmark_db_name""_g_0.table_0;" 2>&1 || true); echo "===== $n =====" >> "$artifact_dir/replica_counts.log"; echo "$out" >> "$artifact_dir/replica_counts.log"; count=$(echo "$out" | grep -Eo '\|[0-9]+\|' | tail -1 | tr -cd '0-9'); [ -n "$count" ] || { fail "cannot read replica count from $n"; continue; }; [ -z "$expected" ] && expected="$count" || [ "$count" = "$expected" ] || fail "replica mismatch node=$n expected=$expected actual=$count"; done < "$dn_list"
}
cli_table_host() { "$cli_dir/sbin/start-cli.sh" -u "$db_user_name" -pw "$root_pw" -h "$1" -timeout 3600 -sql_dialect table -e "$2"; }

check_tdb419_sync_lag() {
  [ -n "$prometheus_url" ] || { log "WARN monitor_url missing; skip syncLag"; return; }
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { log "WARN curl/jq unavailable; skip syncLag"; return; }
  local end=$(( $(date +%s) + 600 )) response count nonzero stable=0
  while (( $(date +%s) < end )); do
    response=$(curl -fsS -G -u admin:admin --data-urlencode "query=iot_consensus{cluster=\"$cluster_id\",nodeType=\"DATANODE\",type=\"syncLag\"}" "$prometheus_url/api/v1/query" 2>>"$log_file" || true)
    count=$(printf '%s' "$response" | jq '.data.result | length' 2>/dev/null || echo 0)
    nonzero=$(printf '%s' "$response" | jq '[.data.result[]?.value[1] | tonumber | select(. > 0.0001)] | length' 2>/dev/null || echo 99)
    log "syncLag series=$count nonzero=$nonzero"
    if [[ "$count" -gt 0 && "$nonzero" -eq 0 ]]; then stable=$((stable+1)); else stable=0; fi
    (( stable >= 3 )) && { log "syncLag converged to zero"; return; }
    sleep 10
  done
  fail "syncLag did not converge to zero"
}

main "$@"
