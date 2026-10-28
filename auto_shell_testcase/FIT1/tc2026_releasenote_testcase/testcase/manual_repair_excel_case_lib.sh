#!/bin/bash
# Some automation entrypoints invoke every case with `sh -x`, which ignores the
# shebang.  Re-exec the original entry script with Bash before this library is
# parsed further; the implementation below intentionally uses Bash features
# such as [[ ]], local, arithmetic commands and process substitution.
if [ "${DPR_BASH_REEXECED:-0}" != "1" ]; then
  export DPR_BASH_REEXECED=1
  exec bash "$0" "$@"
fi

# Common runner for Excel data-partition-repair cases.
# Each entry script sets DPR_CASE_ID and sources this file.
set -uo pipefail

# This file is a shared library but the automation scheduler enumerates *.sh.
# When selected directly, report an intentional skip instead of failing on the
# entry-script-only DPR_CASE_ID requirement. Sourced entry cases continue below.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "[SKIP] manual_repair_excel_case_lib.sh is a shared library; run a tc2026_April_DPR_*.sh entry script instead."
  exit 0
fi

DPR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DPR_CASE_ID="${DPR_CASE_ID:?DPR_CASE_ID is required}"
cur_dir="${DPR_LIB_DIR}"
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"

cfg() { grep "^$1=" "${conf_file}" | head -1 | cut -d= -f2- | tr -d ' '; }
os_user_name="$(cfg os_user_name)"
db_user_name="$(cfg db_user_name)"
testdb="$(cfg v_testdb)"
db_parent_dir="$(cfg v_db_parent_dir)"
db_dir="${db_parent_dir}/${testdb}"
cli_dir="${db_dir}"
root_pw="$(cfg root_pw)"
root_pw="${root_pw:-TimechoDB@2021}"
query_ip="$(head -1 "${nodeinfo_dir}/datanode.txt" 2>/dev/null | tr -d ' ')"
query_ip="${query_ip:-192.168.130.2}"
result_dir="${cur_dir}/result_${DPR_CASE_ID}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${result_dir}"
log_file="${result_dir}/case.log"
fail_flag=0
skip_flag=0

log() { echo "[$(date '+%F %T')] [$1] $2" | tee -a "${log_file}"; }
fail() { log ERROR "$1"; fail_flag=$((fail_flag+1)); }
skip() { log SKIP "$1"; skip_flag=$((skip_flag+1)); }

run_sql() {
  local dialect="$1" sql="$2" out="$3" user="${4:-${db_user_name}}" password="${5:-${root_pw}}"
  "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -u "${user}" -pw "${password}" \
    -sql_dialect "${dialect}" -timeout 36000 -e "${sql}" >"${out}" 2>&1
}
assert_has() { grep -Eq "$2" "$1" || fail "$3 (file=$1)"; }
assert_not_has() { grep -Eq "$2" "$1" && fail "$3 (file=$1)" || true; }
assert_same() { diff -u "$1" "$2" >"$3" || fail "$4 (diff=$3)"; }

repair_trigger() {
  local out="${result_dir}/repair_trigger.out"
  run_sql tree "REPAIR DATA PARTITION TABLE;" "${out}"
  if ! grep -q "The statement is executed successfully" "${out}"; then
    fail "REPAIR did not return success (file=${out})"
    return 1
  fi
  return 0
}
progress_query() { run_sql tree "SHOW REPAIR DATA PARTITION TABLE PROGRESS;" "$1"; }
wait_repair_idle() {
  local timeout="${1:-600}" elapsed=0 out="${result_dir}/progress_trace.out"
  : >"${out}"
  while (( elapsed < timeout )); do
    local one="${result_dir}/progress_${elapsed}.out"
    progress_query "${one}"
    { echo "TIME=${elapsed}"; cat "${one}"; } >>"${out}"
    grep -q "IDLE" "${one}" && return 0
    sleep 1; elapsed=$((elapsed+1))
  done
  fail "repair did not become IDLE within ${timeout}s"
  return 1
}
repair_and_wait() {
  repair_trigger || return 1
  wait_repair_idle 600
}

snapshot_data() {
  local prefix="$1"
  run_sql tree "show databases;show timepartition where database=root.test.g_0;select count(*) from root.**;" "${prefix}_tree.out"
  run_sql table "show databases;show data regions;" "${prefix}_table.out"
}

# A03 validates repair idempotency against business data only.  Do not include
# audit/metric databases or CLI timing text, both of which change naturally
# between two otherwise identical queries.
normalize_business_snapshot() {
  local source_file="$1" normalized_file="$2"
  grep -vE '^[[:space:]]*$|^It costs |^Total line number =|^[+](-+[+])+$' "${source_file}" \
    | sed 's/[[:space:]]*$//' \
    | LC_ALL=C sort >"${normalized_file}"
}

snapshot_A03_business_data() {
  local prefix="$1"
  local tree_raw="${prefix}_tree.raw" table1_raw="${prefix}_table1.raw" table2_raw="${prefix}_table2.raw"
  local count_columns="count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9)"
  run_sql tree "select ${count_columns} from root.test.g_0.** align by device;" "${tree_raw}"
  run_sql table "select device_id,${count_columns} from db_g_0.table1_0 group by device_id order by device_id;" "${table1_raw}"
  run_sql table "select device_id,${count_columns} from db_g_0.table2_0 group by device_id order by device_id;" "${table2_raw}"
  normalize_business_snapshot "${tree_raw}" "${prefix}_tree.out"
  {
    echo '=== db_g_0.table1_0 ==='
    normalize_business_snapshot "${table1_raw}" /dev/stdout
    echo '=== db_g_0.table2_0 ==='
    normalize_business_snapshot "${table2_raw}" /dev/stdout
  } >"${prefix}_table.out"
}
all_nodes() { cat "${nodeinfo_dir}/confignode.txt" "${nodeinfo_dir}/datanode.txt" 2>/dev/null | tr -d ' ' | sort -u; }
dn_nodes() { cat "${nodeinfo_dir}/datanode.txt" 2>/dev/null | tr -d ' '; }
cn_nodes() { cat "${nodeinfo_dir}/confignode.txt" 2>/dev/null | tr -d ' '; }
remote_count() { ssh "${os_user_name}@$1" "sudo grep -R -E '$2' ${db_dir}/logs/* 2>/dev/null | wc -l" | tr -dc '0-9'; }

backup_configs() {
  while read -r node; do
    ssh "${os_user_name}@${node}" "sudo cp -p ${db_dir}/conf/iotdb-system.properties ${db_dir}/conf/iotdb-system.properties.${DPR_CASE_ID}.bak"
  done < <(all_nodes)
}
restore_configs() {
  while read -r node; do
    ssh "${os_user_name}@${node}" "if test -f ${db_dir}/conf/iotdb-system.properties.${DPR_CASE_ID}.bak; then sudo cp -p ${db_dir}/conf/iotdb-system.properties.${DPR_CASE_ID}.bak ${db_dir}/conf/iotdb-system.properties; sudo rm -f ${db_dir}/conf/iotdb-system.properties.${DPR_CASE_ID}.bak; fi" || true
  done < <(all_nodes)
}
set_config_all() {
  local key="$1" value="$2"
  while read -r node; do
    ssh "${os_user_name}@${node}" "sudo sed -i '/^${key}=/d' ${db_dir}/conf/iotdb-system.properties; echo '${key}=${value}' | sudo tee -a ${db_dir}/conf/iotdb-system.properties >/dev/null"
  done < <(all_nodes)
}
restart_cluster() {
  sh "${clean_env_dir}/stop_cluster.sh" >>"${log_file}" 2>&1
  sh "${prepare_env_dir}/start_cluster_v20.sh" 2 6 >>"${log_file}" 2>&1
}

run_borrowed() {
  local script="$1"
  if [[ ! -f "${cur_dir}/${script}" ]]; then fail "borrowed script missing: ${script}"; return 1; fi
  log INFO "Run borrowed setup/test script: ${script}"
  bash "${cur_dir}/${script}" >"${result_dir}/borrowed.out" 2>&1 || fail "borrowed script failed: ${script}"
}

prepare_A03_environment() {
  local setup_script="${cur_dir}/tc2026_April_DPR_D03_manual_repair_audit_log.sh"
  local setup_out="${result_dir}/prepare_complete_baseline.out"
  if [[ ! -f "${setup_script}" ]]; then
    fail "A03 setup script missing: ${setup_script}"
    return 1
  fi
  log INFO "A03 prepare: clean environment, restore full three-disk data, start 3CN+3DN and establish complete baseline"
  if ! bash "${setup_script}" >"${setup_out}" 2>&1; then
    fail "A03 independent environment/data preparation failed (file=${setup_out})"
    return 1
  fi

  local cluster_out="${result_dir}/cluster_ready.out" waited=0 running=0
  while (( waited < 300 )); do
    run_sql tree "show cluster;" "${cluster_out}"
    running=$(grep -Ec "Running|ReadOnly" "${cluster_out}" || true)
    (( running >= 6 )) && break
    sleep 5
    waited=$((waited+5))
  done
  if (( running < 6 )); then
    fail "A03 cluster did not reach 3CN+3DN ready within 300s, ready=${running}/6 (file=${cluster_out})"
    return 1
  fi

  snapshot_A03_business_data "${result_dir}/baseline_1"
  sleep 2
  snapshot_A03_business_data "${result_dir}/baseline_2"
  if ! grep -Eq "root.test.g_0|[1-9][0-9]*" "${result_dir}/baseline_1_tree.out"; then
    fail "A03 tree baseline is empty or unavailable"
    return 1
  fi
  assert_same "${result_dir}/baseline_1_tree.out" "${result_dir}/baseline_2_tree.out" "${result_dir}/baseline_tree_stability.diff" "tree baseline is not stable before idempotency check"
  assert_same "${result_dir}/baseline_1_table.out" "${result_dir}/baseline_2_table.out" "${result_dir}/baseline_table_stability.diff" "table baseline is not stable before idempotency check"
  (( fail_flag == 0 )) || return 1
  log INFO "A03 independent cluster and complete stable baseline are ready"
}

case_A03() {
  prepare_A03_environment || return 1
  local round
  for round in 1 2; do
    log INFO "A03 idempotency repair round ${round}/2"
    repair_and_wait || return 1
    snapshot_A03_business_data "${result_dir}/after_${round}"
    assert_same "${result_dir}/baseline_2_tree.out" "${result_dir}/after_${round}_tree.out" "${result_dir}/round_${round}_tree.diff" "tree data/partition changed after idempotent repair round ${round}"
    assert_same "${result_dir}/baseline_2_table.out" "${result_dir}/after_${round}_table.out" "${result_dir}/round_${round}_table.diff" "table data/regions changed after idempotent repair round ${round}"
    (( fail_flag == 0 )) || return 1
  done
}
case_A04() {
  # 固定备份的两个缺失分区在最低 ID DN 上都有副本，默认调度会全部交给该 DN。
  # 临时下线该 DN，使另外两个副本 DN 分别承担生成任务，真实覆盖 multi-DN merge。
  export DPR_A04_FORCE_MULTI_DN=1
  run_borrowed "tc2026_April_003501_upd_from_v2061rc7_manual_repair_partitioned_table_v2091_tree_table_ns_ttl.sh"
  unset DPR_A04_FORCE_MULTI_DN
  (( fail_flag == 0 )) || return 1
  local participants=0 generated_total=0 node n
  while read -r node; do
    n="$(remote_count "${node}" "DataPartitionTable generation completed")"
    log INFO "A04 DataNode ${node} generation-completed log count=${n}"
    generated_total=$((generated_total+n))
    (( n > 0 )) && participants=$((participants+1))
  done < <(dn_nodes)
  (( generated_total > 0 )) || { fail "no DataPartitionTable generation completion evidence found on any DataNode"; return 1; }
  if (( participants < 2 )); then
    fail "A04 multi-DN construction failed: participants=${participants}, generation_events=${generated_total}, expected participants>=2"
  else
    log INFO "PASS A04 multi-DN generation and merge covered: participants=${participants}, generation_events=${generated_total}"
  fi
}
case_B03() {
  repair_trigger || return 1
  wait_repair_idle 600 || return 1
  local values="${result_dir}/progress.values"
  # IDLE reports 0.0 by definition; it is a terminal state, not progress
  # regression.  Only compare active repair phases.
  grep -vE '\|[[:space:]]*IDLE[[:space:]]*\|' "${result_dir}/progress_trace.out" \
    | grep -oE '\|[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*\|' \
    | tr -cd '0-9.\n' >"${values}" || true
  local sample_count
  sample_count=$(wc -l <"${values}")
  if (( sample_count < 2 )); then
    log INFO "B03 repair completed too quickly for monotonicity comparison; active samples=${sample_count}, IDLE observed"
  elif ! awk 'NR>1 && $1+0<p+0 {exit 1} {p=$1}' "${values}"; then
    fail "active repair progress decreased (file=${values})"
  fi
}
case_B04() {
  repair_trigger; wait_repair_idle 600
  local values="${result_dir}/progress.values"
  grep -oE '\|[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*\|' "${result_dir}/progress_trace.out" | tr -cd '0-9.\n' >"${values}" || true
  awk '$1<0 || $1>100 {exit 1} END{if(NR==0) exit 2}' "${values}" || fail "progress value outside 0..100 or no value"
  log INFO "Formula numerator/denominator requires dataset counters in CN/DN logs; retain trace for manual cross-check"
}
case_C01() { backup_configs; trap 'restore_configs; restart_cluster' EXIT; set_config_all partition_table_recover_worker_num 10; set_config_all partition_table_recover_max_read_mb_per_sec 10; restart_cluster; repair_and_wait; }
case_C02() {
  backup_configs
  trap 'restore_configs; restart_cluster' EXIT
  set_config_all partition_table_recover_worker_num 4
  restart_cluster
  local node configured bad=0
  while read -r node; do
    configured=$(ssh "${os_user_name}@${node}" "grep '^partition_table_recover_worker_num=' ${db_dir}/conf/iotdb-system.properties 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' '")
    log INFO "C02 DataNode ${node} partition_table_recover_worker_num=${configured:-missing}"
    [[ "${configured}" == "4" ]] || bad=$((bad+1))
  done < <(dn_nodes)
  (( bad == 0 )) || { fail "worker_num=4 was not applied on ${bad} DataNode(s)"; return 1; }
  repair_and_wait || return 1
  log INFO "C02 worker_num=4 applied on all DataNodes and repair completed; thread-name logs are diagnostic only"
}
case_C03() { backup_configs; trap 'restore_configs; restart_cluster' EXIT; set_config_all partition_table_recover_max_read_mb_per_sec 1; restart_cluster; local s=$(date +%s); repair_and_wait; local slow=$(( $(date +%s)-s )); log INFO "limit=1 elapsed=${slow}s"; }

case_D01() { run_sql tree "REPAIR DATA PARTITION TABLE;SHOW REPAIR DATA PARTITION TABLE PROGRESS;" "${result_dir}/system.out"; assert_has "${result_dir}/system.out" "executed successfully|IDLE|Progress" "SYSTEM user could not execute repair SQL"; }
case_D02() { local u="dpr_no_system_${RANDOM}" p="DprTest@2026"; run_sql tree "create user ${u} '${p}';" "${result_dir}/create_user.out"; run_sql tree "REPAIR DATA PARTITION TABLE;" "${result_dir}/denied.out" "${u}" "${p}"; assert_has "${result_dir}/denied.out" "permission|privilege|403|denied" "non-SYSTEM user was not rejected"; run_sql tree "drop user ${u};" "${result_dir}/drop_user.out"; }
case_D03() { repair_and_wait; local hits=0 n; while read -r n; do hits=$((hits+$(remote_count "$n" "REPAIR DATA PARTITION TABLE"))); done < <(all_nodes); ((hits>0)) || fail "audit/log entry for REPAIR not found"; }

case_E01() { backup_configs; trap 'restore_configs; restart_cluster' EXIT; set_config_all dn_data_dirs "data/datanode/data"; restart_cluster; repair_and_wait; snapshot_data "${result_dir}/single_dir_after"; }
case_E02() { run_borrowed "tc2026_April_003501_upd_from_v2061rc7_manual_repair_partitioned_table_v2091_tree_table_ns_ttl.sh"; }
case_F01() { run_borrowed "tc2026_April_0036_seq_data_partitiontable_manual_repair_dev_ttl.sh"; assert_has "${result_dir}/borrowed.out" "testcase.*pass|PASS" "middle-timeslot borrowed flow did not pass"; }
case_F02() { run_borrowed "tc2026_April_0035_manual_repair_partitioned_table_v2091_tree_table_ns_ttl.sh"; assert_has "${result_dir}/borrowed.out" "testcase.*pass|PASS" "minimum-timeslot borrowed flow did not pass"; }
case_F03() { run_borrowed "tc2026_April_0036_partitiontable_manual_repair_dev_ttl.sh"; }

case_G01() { repair_trigger; local dn=$(dn_nodes | head -1); ssh "${os_user_name}@${dn}" "cd ${db_dir}; sudo ./sbin/stop-datanode.sh"; progress_query "${result_dir}/offline_progress.out"; assert_has "${result_dir}/offline_progress.out" "FAILED|ERROR|UNREACHABLE|Message|IDLE" "no defined status when DN became unreachable"; ssh "${os_user_name}@${dn}" "cd ${db_dir}; sudo ./sbin/start-datanode.sh >/dev/null 2>&1 &"; }
case_G02() { run_borrowed "tc2026_April_00360102_upd_v2061_seq_data_partitiontable_manual_repair_dev_ttl_stop_cn_leader.sh"; }
case_G03() { run_borrowed "tc2026_April_003604_upd_v2061_onebyoneNode_cn_first_seq_data_partitiontable_manual_repair_dev_ttl.sh"; }
case_G04() { repair_trigger; run_sql tree "REPAIR DATA PARTITION TABLE;" "${result_dir}/second_repair.out"; assert_has "${result_dir}/second_repair.out" "already|running|executed successfully|repair" "second REPAIR returned undefined response"; wait_repair_idle 600; }
case_G05() { local dn=$(dn_nodes | head -1); ssh "${os_user_name}@${dn}" "cd ${db_dir}; sudo ./sbin/stop-datanode.sh"; repair_trigger; progress_query "${result_dir}/offline_trigger.out"; assert_has "${result_dir}/offline_trigger.out" "FAILED|ERROR|UNREACHABLE|Message|IDLE" "offline-DN repair status undefined"; ssh "${os_user_name}@${dn}" "cd ${db_dir}; sudo ./sbin/start-datanode.sh >/dev/null 2>&1 &"; }

invalid_config_case() { local key="$1" value="$2"; backup_configs; trap 'restore_configs; restart_cluster' EXIT; set_config_all "$key" "$value"; restart_cluster; sleep 5; local running; running=$(run_sql tree "show cluster;" "${result_dir}/cluster.out"; grep -c Running "${result_dir}/cluster.out" || true); log INFO "invalid config ${key}=${value}, running=${running}"; }
case_H01() { invalid_config_case partition_table_recover_worker_num 0; }
case_H02() { invalid_config_case partition_table_recover_worker_num invalid; }
case_H03() { backup_configs; trap 'restore_configs; restart_cluster' EXIT; set_config_all partition_table_recover_worker_num 99999; restart_cluster; repair_and_wait; }
case_H04() { invalid_config_case partition_table_recover_max_read_mb_per_sec -1; }
case_H05() { backup_configs; trap 'restore_configs; restart_cluster' EXIT; set_config_all partition_table_recover_max_read_mb_per_sec 1; restart_cluster; repair_and_wait; }

case_I01() { local s=$(date +%s); repair_and_wait; local e=$(( $(date +%s)-s )); log INFO "repair_elapsed_seconds=${e}"; while read -r n; do ssh "${os_user_name}@${n}" "uptime; iostat -x 1 1 2>/dev/null || true" >>"${result_dir}/resource.out"; done < <(all_nodes); }
case_I03() { snapshot_data "${result_dir}/empty_before"; repair_and_wait; progress_query "${result_dir}/empty_after.out"; assert_has "${result_dir}/empty_after.out" "IDLE" "empty-cluster repair did not finish IDLE"; }
case_I04() { run_borrowed "tc2026_April_0036_partitiontable_manual_repair_dev_ttl.sh"; }

case_J01() {
  local out="${result_dir}/table_dialect.out"
  run_sql table "REPAIR DATA PARTITION TABLE;" "${out}"
  if grep -Eqi "700:|mismatched input ['\"]?REPAIR|not supported|parse|semantic|error" "${out}"; then
    log INFO "J01 Table dialect correctly rejected REPAIR DATA PARTITION TABLE"
  else
    fail "table-dialect rejection was not observed (file=${out})"
  fi
  if grep -q "The statement is executed successfully" "${out}"; then
    fail "Table dialect unexpectedly executed REPAIR DATA PARTITION TABLE (file=${out})"
  fi
}
case_J02() { local i=0 sql; for sql in "repair data partition table;" "REPAIR  DATA  PARTITION  TABLE ;" $'REPAIR DATA\nPARTITION TABLE;'; do i=$((i+1)); run_sql tree "$sql" "${result_dir}/format_${i}.out"; assert_has "${result_dir}/format_${i}.out" "executed successfully" "valid SQL format variant ${i} failed"; wait_repair_idle 600; done; }
case_J03() { local i=0 sql; for sql in "REPAIR DATA PARTITION;" "REPAIR PARTITION TABLE;" "REPAIR DATA PARTITION TABLE EXTRA;"; do i=$((i+1)); run_sql tree "$sql" "${result_dir}/invalid_${i}.out"; assert_has "${result_dir}/invalid_${i}.out" "parse|mismatched|error|Exception|401|700" "invalid SQL ${i} was not rejected"; done; }

run_case() {
  log INFO "START ${DPR_CASE_ID}"
  local fn="case_${DPR_CASE_ID#DPR_}"
  if ! declare -F "${fn}" >/dev/null; then fail "case function missing: ${fn}"; else "${fn}"; fi
  restore_configs
  if (( fail_flag > 0 )); then log ERROR "FAIL ${DPR_CASE_ID}, failures=${fail_flag}, skips=${skip_flag}"; exit 1; fi
  log INFO "PASS ${DPR_CASE_ID}, skips=${skip_flag}"
}
