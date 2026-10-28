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
query_ip="$(head -1 "${nodeinfo_dir}/datanode_5d.txt" | tr -d '[:space:]')"
restart_ip="${RESTART_IP:-${query_ip}}"
ts_num="${TS_NUM:-1000000}"
initial_warmup="${INITIAL_WARMUP_SECONDS:-3600}"
restart_interval="${RESTART_INTERVAL_SECONDS:-180}"
wait_timeout="${WAIT_TIMEOUT_SECONDS:-900}"
run_id="$(date +%Y_%m_%d_%H_%M_%S)"
result_dir="${bm_dir}/${testdb}/${run_id}_issue0359"
log_file="${result_dir}/testcase.log"
pid_file="${result_dir}/benchmark.pids"
fail_flag=0
oom_baseline=0

mkdir -p "${result_dir}"
: > "${pid_file}"

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
    "find '${db_dir}' -type f \( -name '*heapdump*.hprof' -o -name 'java_pid*.hprof' \) -size +0c 2>/dev/null | wc -l; grep -RilE 'OutOfMemoryError|Dumping heap' '${db_dir}/logs' 2>/dev/null | wc -l" |
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

log INFO "Preparing clean 3C5D cluster for ${testdb}"
bash "${cur_dir}/only_start3c5d_setconf.sh" >> "${log_file}" 2>&1 || die "Cluster preparation failed"
wait_for_status Running || die "Cluster did not become Running within ${wait_timeout}s"
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
  log INFO "Cycle ${cycle}: benchmark App process is running; stopping DataNode ${restart_ip}"
  ssh -o ConnectTimeout=10 "${os_user_name}@${restart_ip}" "${db_dir}/sbin/stop-datanode.sh" >> "${log_file}" 2>&1 || die "stop-datanode failed in cycle ${cycle}"
  wait_for_process_exit || die "DataNode process did not exit in cycle ${cycle}"
  wait_for_status Unknown || die "DataNode did not become Unknown in cycle ${cycle}"

  check_oom
  heapdump="${db_dir}/dn_$(date +%Y_%m_%d_%H_%M_%S)_heapdump.hprof"
  log INFO "Cycle ${cycle}: starting DataNode ${restart_ip}"
  ssh -o ConnectTimeout=10 "${os_user_name}@${restart_ip}" "source /etc/profile; '${db_dir}/sbin/start-datanode.sh' -H '${heapdump}' > /dev/null 2>&1" >> "${log_file}" 2>&1 || die "start-datanode failed in cycle ${cycle}"
  wait_for_status Running || die "DataNode did not return to Running in cycle ${cycle}"
  sleep "${restart_interval}"
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
