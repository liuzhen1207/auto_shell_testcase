#!/bin/bash
# TIMECHODB-0359: concurrent tree writes/table-view reads while DN1 is restarted.

set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
suite_dir="$(cd "${cur_dir}/.." && pwd)"
conf_file="${suite_dir}/conf/test.conf"
nodeinfo_dir="${suite_dir}/conf"
cluster_root="$(cd "${suite_dir}/.." && pwd)"

get_conf() {
  awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); gsub(/[[:space:]]/, ""); print; exit}' "${conf_file}"
}

os_user_name="$(get_conf os_user_name)"
testdb="$(get_conf v_testdb)"
db_parent_dir="$(get_conf v_db_parent_dir)"
cli_parent_dir="$(get_conf v_shell_client_db_parent_dir)"
cli_dir="${cli_parent_dir}/${testdb}"
db_dir="${db_parent_dir}/${testdb}"
bm_dir="${BM_DIR:-/data2/benchmark/bm_20251017_b6be9bd_ssl}"
bm_conf="${BM_CONF:-tree_temp_view}"
restart_ip="${RESTART_IP:-$(head -1 "${nodeinfo_dir}/datanode_5d.txt" | tr -d '[:space:]')}"
query_ip="${QUERY_IP:-$(awk -v restart_ip="${restart_ip}" '
  {gsub(/[[:space:]]/, "")}
  length($0) && $0 != restart_ip {print; exit}
' "${nodeinfo_dir}/datanode_5d.txt")}"
[ -n "${query_ip}" ] || {
  echo "No query DataNode different from restart DataNode ${restart_ip} was found" >&2
  exit 1
}
ts_num="${TS_NUM:-1000000}"
initial_warmup="${INITIAL_WARMUP_SECONDS:-3600}"
restart_interval="${RESTART_INTERVAL_SECONDS:-180}"
wait_timeout="${WAIT_TIMEOUT_SECONDS:-900}"
diagnostic_interval="${DIAGNOSTIC_INTERVAL_SECONDS:-60}"
run_id="$(date +%Y_%m_%d_%H_%M_%S)"
result_dir="${bm_dir}/${testdb}/${run_id}_issue0359"
log_file="${result_dir}/testcase.log"
pid_file="${result_dir}/benchmark.pids"
fail_flag=0
oom_baseline=0

mkdir -p "${result_dir}"
: > "${pid_file}"

cleanup_benchmarks() {
  local pid
  [ -f "${pid_file}" ] || return 0
  while read -r pid; do
    [ -n "${pid}" ] || continue
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
    fi
  done < "${pid_file}"
}

trap cleanup_benchmarks EXIT

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "${log_file}"
}

die() {
  log ERROR "$1"
  echo "testcase TIMECHODB-0359 fail"
  exit 1
}

cli_tree() {
  "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -e "$1"
}

cli_table() {
  "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -sql_dialect table -e "$1"
}

cluster_status_count() {
  local expected="$1"
  cli_table "show cluster;" 2>/dev/null |
    awk -F'|' -v ip="${restart_ip}" -v state="${expected}" '
      index($0, ip) && tolower($0) ~ tolower(state) {count++} END {print count+0}'
}

wait_for_status() {
  local expected="$1"
  local begin
  begin=$(date +%s)
  while [ $(( $(date +%s) - begin )) -lt "${wait_timeout}" ]; do
    if [ "$(cluster_status_count "${expected}")" -ge 1 ]; then
      return 0
    fi
    sleep 10
  done
  return 1
}

wait_for_process_exit() {
  local begin
  begin=$(date +%s)
  while [ $(( $(date +%s) - begin )) -lt "${wait_timeout}" ]; do
    if [ "$(ssh -o ConnectTimeout=10 "${os_user_name}@${restart_ip}" "jps 2>/dev/null | awk '\$2 == \"DataNode\" {count++} END {print count+0}'")" -eq 0 ]; then
      return 0
    fi
    sleep 10
  done
  return 1
}

datanode_pid() {
  ssh -o ConnectTimeout=10 "${os_user_name}@${restart_ip}" \
    "jps -l 2>/dev/null | awk '\$2 == \"com.timecho.iotdb.DataNode\" || \$2 == \"org.apache.iotdb.db.service.DataNode\" || \$2 == \"DataNode\" {print \$1; exit}'" 2>/dev/null
}

capture_jvm_snapshot() {
  local cycle="$1"
  local pid
  pid=$(datanode_pid)
  [ -n "${pid}" ] || return 1

  ssh -o ConnectTimeout=10 "${os_user_name}@${restart_ip}" \
    "echo '=== snapshot $(date '+%Y-%m-%d %H:%M:%S') cycle ${cycle} pid ${pid} ==='; timeout 20 jstat -gcutil '${pid}' 1000 3" \
    >> "${result_dir}/jstat_history.log" 2>&1 || true

  ssh -o ConnectTimeout=10 "${os_user_name}@${restart_ip}" \
    "echo '=== latest jstack $(date '+%Y-%m-%d %H:%M:%S') cycle ${cycle} pid ${pid} ==='; timeout 30 jstack -l '${pid}'" \
    > "${result_dir}/latest_jstack.log.tmp" 2>&1 &&
    mv "${result_dir}/latest_jstack.log.tmp" "${result_dir}/latest_jstack.log" ||
    rm -f "${result_dir}/latest_jstack.log.tmp"
}

collect_failure_diagnostics() {
  local reason="$1"
  local cycle="$2"
  local stamp safe_reason diagnostic_file
  stamp=$(date +%Y_%m_%d_%H_%M_%S)
  safe_reason=$(echo "${reason}" | tr -cs '[:alnum:]_.-' '_')
  diagnostic_file="${result_dir}/diagnostic_${stamp}_cycle_${cycle}_${safe_reason}.log"

  log INFO "Collecting failure diagnostics: ${diagnostic_file}"
  ssh -o ConnectTimeout=10 "${os_user_name}@${restart_ip}" bash -s -- "${db_dir}" "${reason}" "${cycle}" > "${diagnostic_file}" 2>&1 <<'REMOTE' || true
db_dir="$1"
reason="$2"
cycle="$3"
pid=$(jps -l 2>/dev/null | awk '$2 == "com.timecho.iotdb.DataNode" || $2 == "org.apache.iotdb.db.service.DataNode" || $2 == "DataNode" {print $1; exit}')

echo "reason=${reason}"
echo "cycle=${cycle}"
date
echo "DataNode_pid=${pid:-NONE}"
echo "=== uptime/free/df ==="
uptime
free -h
df -h "${db_dir}" /
echo "=== process summary ==="
ps -eo pid,ppid,stat,etime,%cpu,%mem,rss,vsz,args | grep -E 'DataNode|java|PID' | grep -v grep
if [ -n "${pid}" ]; then
  echo "=== jstat ==="
  timeout 20 jstat -gcutil "${pid}" 1000 5 || true
  echo "=== jstack ==="
  timeout 40 jstack -l "${pid}" || true
  echo "=== jcmd native memory ==="
  timeout 20 jcmd "${pid}" VM.native_memory summary || true
fi
echo "=== recent DataNode logs ==="
tail -300 "${db_dir}/logs/log_datanode_all.log" 2>/dev/null || true
tail -200 "${db_dir}/logs/log_datanode_error.log" 2>/dev/null || true
echo "=== JVM/dump files ==="
find "${db_dir}" -maxdepth 3 -type f \( -name '*.hprof' -o -name 'hs_err_pid*.log' -o -name 'replay_pid*.log' \) -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' 2>/dev/null | sort | tail -50
echo "=== kernel OOM/crash evidence ==="
dmesg -T 2>/dev/null | grep -iE 'out of memory|oom|killed process|segfault' | tail -100 || true
REMOTE
}

monitor_restart_interval() {
  local cycle="$1"
  local elapsed=0
  local pid
  while [ "${elapsed}" -lt "${restart_interval}" ]; do
    sleep 10
    elapsed=$((elapsed + 10))
    pid=$(datanode_pid)
    if [ -z "${pid}" ]; then
      collect_failure_diagnostics "datanode_exited_during_restart_interval" "${cycle}"
      return 1
    fi
    if [ $((elapsed % diagnostic_interval)) -eq 0 ]; then
      capture_jvm_snapshot "${cycle}" || true
    fi
  done
}

start_benchmark() {
  local conf="$1"
  local output="$2"
  nohup "${bm_dir}/benchmark.sh" -cf "${bm_dir}/${bm_conf}/${conf}" > "${result_dir}/${output}" 2>&1 &
  echo "$!" >> "${pid_file}"
}

benchmark_app_count() {
  jps 2>/dev/null | awk '$2 == "App" {count++} END {print count+0}'
}

benchmarks_alive() {
  [ "$(benchmark_app_count)" -gt 0 ]
}

count_oom_evidence() {
  ssh -o ConnectTimeout=10 "${os_user_name}@${restart_ip}" \
    "find '${db_dir}' -type f \( -name '*heapdump*.hprof' -o -name 'java_pid*.hprof' -o -name 'hs_err_pid*.log' \) -size +0c 2>/dev/null | wc -l; grep -RilE 'OutOfMemoryError|Dumping heap|fatal error has been detected' '${db_dir}/logs' 2>/dev/null | wc -l" |
    awk '{sum += $1} END {print sum+0}'
}

check_oom() {
  local oom_count
  oom_count=$(count_oom_evidence)
  if [ "${oom_count}" -gt "${oom_baseline}" ]; then
    log ERROR "New OOM evidence found on ${restart_ip}: baseline=${oom_baseline}, current=${oom_count}"
    fail_flag=$((fail_flag + 1))
  fi
}

configure_datanode_compression_and_gc() {
  local node_ip
  while read -r node_ip; do
    [ -n "${node_ip}" ] || continue
    log INFO "Configuring DataNode ${node_ip}: lz4_use_jni=false, Parallel GC"
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s -- "${db_dir}" <<'REMOTE' || return 1
db_dir="$1"
system_conf="${db_dir}/conf/iotdb-system.properties"
env_conf="${db_dir}/conf/datanode-env.sh"

if grep -Eq '^[[:space:]#]*lz4_use_jni=' "${system_conf}"; then
  sed -i -E 's|^[[:space:]#]*lz4_use_jni=.*|lz4_use_jni=false|' "${system_conf}"
else
  echo 'lz4_use_jni=false' >> "${system_conf}"
fi

sed -i -E '/IOTDB_JMX_OPTS=.*-XX:\+Use(G1|Serial|Parallel|ParallelOld|Z|Shenandoah|Epsilon)GC/d' "${env_conf}"
sed -i '/IOTDB_JMX_OPTS=.*-XX:+UseAdaptiveSizePolicy/a IOTDB_JMX_OPTS="$IOTDB_JMX_OPTS -XX:+UseParallelGC"' "${env_conf}"

grep -q '^lz4_use_jni=false$' "${system_conf}"
grep -q 'IOTDB_JMX_OPTS=.*-XX:+UseParallelGC' "${env_conf}"
REMOTE
  done < "${nodeinfo_dir}/datanode.txt"
}

log INFO "Preparing clean 3C5D cluster for ${testdb}"
log INFO "Using DataNode ${query_ip} for status queries; restart target is ${restart_ip}"
bash "${cur_dir}/only_start3c5d_setconf.sh" >> "${log_file}" 2>&1 || die "Cluster preparation failed"
wait_for_status Running || die "Cluster did not become Running within ${wait_timeout}s"

configure_datanode_compression_and_gc || die "Failed to configure DataNode compression or GC"
log INFO "Restarting cluster to apply DataNode compression and GC settings"
bash "${suite_dir}/clean_env/stop_cluster.sh" >> "${log_file}" 2>&1 || die "Cluster stop failed after DataNode configuration"
bash "${suite_dir}/prepare_env/start_cluster_v20.sh" 1 8 >> "${log_file}" 2>&1 || die "Cluster restart failed after DataNode configuration"
wait_for_status Running || die "Cluster did not become Running after applying DataNode settings"

oom_baseline=$(count_oom_evidence)
log INFO "OOM evidence baseline on ${restart_ip}: ${oom_baseline}"

log INFO "Creating benchmark users"
cli_tree "CREATE USER test1_user 'TimechoDB@2021'; GRANT ALL ON root.** TO USER test1_user;" >> "${log_file}" 2>&1 || true
cli_tree "CREATE USER test2_user 'TimechoDB@2021'; GRANT ALL ON root.** TO USER test2_user;" >> "${log_file}" 2>&1 || true
cli_table "CREATE USER view_user 'TimechoDB@2021'; GRANT ALL TO USER view_user;" >> "${log_file}" 2>&1 || true

log INFO "Creating one million tree-model timeseries"
"${bm_dir}/benchmark.sh" -cf "${bm_dir}/${bm_conf}/conf1_root_pre" > "${result_dir}/pre_bm1.out" 2>&1 || die "conf1 preload failed"
"${bm_dir}/benchmark.sh" -cf "${bm_dir}/${bm_conf}/conf2_root_pre" > "${result_dir}/pre_bm2.out" 2>&1 || die "conf2 preload failed"
start_benchmark conf1 tree_bm1.out
start_benchmark conf2 tree_bm2.out

begin=$(date +%s)
while [ $(( $(date +%s) - begin )) -lt "${wait_timeout}" ]; do
  current_ts=$(cli_tree "count timeseries root.**;" 2>/dev/null | awk -F'|' '/\|/ {gsub(/ /, "", $2); if ($2 ~ /^[0-9]+$/) value=$2} END {print value+0}')
  [ "${current_ts}" -ge "${ts_num}" ] && break
  benchmarks_alive || die "Tree benchmark exited before timeseries creation completed"
  sleep 10
done
[ "${current_ts:-0}" -ge "${ts_num}" ] || die "Expected ${ts_num} timeseries, got ${current_ts:-0}"

log INFO "Creating table views and starting concurrent view queries"
cli_table "create database test_g_0; use test_g_0; create view v1_0 (device_id STRING TAG) as root.test1.g_0.**;" >> "${log_file}" 2>&1 || die "v1_0 creation failed"
cli_table "use test_g_0; create view v2_0 (device_id STRING TAG) as root.test2.g_0.**;" >> "${log_file}" 2>&1 || die "v2_0 creation failed"
start_benchmark view1 view_bm1.out
start_benchmark view2 view_bm2.out

log INFO "Warmup for ${initial_warmup}s"
sleep "${initial_warmup}"

cycle=1
while benchmarks_alive; do
  current_dn_pid=$(datanode_pid)
  if [ -z "${current_dn_pid}" ]; then
    collect_failure_diagnostics "datanode_exited_before_stop" "${cycle}"
    die "DataNode exited unexpectedly before stop in cycle ${cycle}"
  fi

  log INFO "Cycle ${cycle}: benchmark App process is running; stopping DataNode ${restart_ip}"
  if ! ssh -o ConnectTimeout=10 "${os_user_name}@${restart_ip}" "${db_dir}/sbin/stop-datanode.sh" >> "${log_file}" 2>&1; then
    current_dn_pid=$(datanode_pid)
    if [ -z "${current_dn_pid}" ]; then
      collect_failure_diagnostics "datanode_exited_before_stop_signal" "${cycle}"
      die "DataNode exited unexpectedly before stop could signal it in cycle ${cycle}"
    fi
    collect_failure_diagnostics "stop_datanode_command_failed" "${cycle}"
    die "stop-datanode failed while DataNode PID ${current_dn_pid} was still alive in cycle ${cycle}"
  fi
  if ! wait_for_process_exit; then
    collect_failure_diagnostics "datanode_stop_timeout" "${cycle}"
    die "DataNode process did not exit in cycle ${cycle}"
  fi
  wait_for_status Unknown || die "DataNode did not become Unknown in cycle ${cycle}"

  check_oom
  heapdump="${db_dir}/dn_$(date +%Y_%m_%d_%H_%M_%S)_heapdump.hprof"
  error_file="${db_dir}/hs_err_pid%p_cycle_${cycle}.log"
  start_output="${db_dir}/logs/issue0359_start_cycle_${cycle}.out"
  log INFO "Cycle ${cycle}: starting DataNode ${restart_ip}"
  ssh -o ConnectTimeout=10 "${os_user_name}@${restart_ip}" "source /etc/profile; '${db_dir}/sbin/start-datanode.sh' -d -H '${heapdump}' -E '${error_file}' > '${start_output}' 2>&1" >> "${log_file}" 2>&1 || die "start-datanode failed in cycle ${cycle}"
  if ! wait_for_status Running; then
    collect_failure_diagnostics "datanode_start_running_timeout" "${cycle}"
    die "DataNode did not return to Running in cycle ${cycle}"
  fi
  capture_jvm_snapshot "${cycle}" || true
  monitor_restart_interval "${cycle}" || die "DataNode exited during ${restart_interval}s restart interval in cycle ${cycle}"
  cycle=$((cycle + 1))
done

check_oom
if [ "${fail_flag}" -gt 0 ]; then
  echo "testcase TIMECHODB-0359 fail"
  exit 1
fi

log INFO "Benchmark App processes exited; completed $((cycle - 1)) restart cycles without OOM"
echo "testcase TIMECHODB-0359 pass"
exit 0
