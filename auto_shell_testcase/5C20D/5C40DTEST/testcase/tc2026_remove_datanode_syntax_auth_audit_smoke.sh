#!/bin/bash
set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
conf_file=${TEST_CONF_FILE:-${cur_dir}/../conf/test.conf}
evidence_dir=${EVIDENCE_DIR:-${cur_dir}/remove_datanode_smoke_evidence_$(date +%Y%m%d_%H%M%S)}
smoke_user=${SMOKE_USER:-rmdn_smoke_user}
smoke_password=${SMOKE_PASSWORD:-RmdnSmoke_2026}
invalid_dn_id=2147483647
fail_count=0
skip_count=0

mkdir -p "${evidence_dir}"
result_file=${evidence_dir}/results.csv
printf 'case_id,result,detail\n' > "${result_file}"

read_conf() {
  local key=$1
  awk -F '=' -v key="${key}" '$1 == key {gsub(/ /, "", $2); print $2; exit}' "${conf_file}"
}

db_user_name=$(read_conf db_user_name)
db_parent_dir=$(read_conf v_db_parent_dir)
shell_client_db_parent_dir=$(read_conf v_shell_client_db_parent_dir)
testdb=$(read_conf v_testdb)
os_user_name=$(read_conf os_user_name)
cli_dir=${shell_client_db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
datanode_file=${cur_dir}/../conf/datanode.txt
query_ip=$(head -1 "${datanode_file}" | sed 's/ //g')
cli=${cli_dir}/sbin/start-cli.sh

record() {
  local case_id=$1
  local result=$2
  local detail=$3
  printf '%s,%s,%s\n' "${case_id}" "${result}" "${detail//,/;}" | tee -a "${result_file}"
  [[ "${result}" == "FAIL" ]] && fail_count=$((fail_count+1))
  [[ "${result}" == "SKIP" ]] && skip_count=$((skip_count+1))
}

run_sql() {
  local user=$1
  local password=$2
  local sql=$3
  local output=$4
  if [[ -n "${password}" ]]; then
    "${cli}" -h "${query_ip}" -u "${user}" -pw "${password}" -e "${sql}" > "${output}" 2>&1
  else
    "${cli}" -h "${query_ip}" -u "${user}" -e "${sql}" > "${output}" 2>&1
  fi
}

expect_rejected() {
  local case_id=$1
  local sql=$2
  local output=${evidence_dir}/${case_id}.out
  run_sql "${db_user_name}" "" "${sql}" "${output}"
  if grep -qi 'success' "${output}"; then
    record "${case_id}" FAIL "unexpected success: ${sql}"
  else
    record "${case_id}" PASS "rejected without cluster mutation"
  fi
}

normalize_cluster_state() {
  local prefix=$1
  run_sql "${db_user_name}" "" "SHOW DATANODES;" "${evidence_dir}/${prefix}_show_datanodes.out"
  run_sql "${db_user_name}" "" "SHOW REGIONS;" "${evidence_dir}/${prefix}_show_regions.out"
  sed '/^[[:space:]]*$/d' "${evidence_dir}/${prefix}_show_datanodes.out" > "${evidence_dir}/${prefix}_show_datanodes.normalized"
  sed '/^[[:space:]]*$/d' "${evidence_dir}/${prefix}_show_regions.out" > "${evidence_dir}/${prefix}_show_regions.normalized"
}

cleanup() {
  run_sql "${db_user_name}" "" "DROP USER ${smoke_user};" "${evidence_dir}/cleanup_drop_user.out" || true
}
trap cleanup EXIT

if [[ ! -x "${cli}" || ! -f "${datanode_file}" ]]; then
  record PRECHECK FAIL "CLI or datanode file missing"
  exit 1
fi

normalize_cluster_state before

expect_rejected SYNTAX_EMPTY "REMOVE DATANODE;"
expect_rejected SYNTAX_NON_NUMERIC "REMOVE DATANODE abc;"
expect_rejected SYNTAX_TRAILING_COMMA "REMOVE DATANODE ${invalid_dn_id},;"
expect_rejected SEMANTIC_UNKNOWN_SINGLE "REMOVE DATANODE ${invalid_dn_id};"
expect_rejected SEMANTIC_UNKNOWN_MULTI "REMOVE DATANODE ${invalid_dn_id},2147483646;"
expect_rejected SEMANTIC_DUPLICATE_UNKNOWN "REMOVE DATANODE ${invalid_dn_id},${invalid_dn_id};"

run_sql "${db_user_name}" "" "DROP USER ${smoke_user};" "${evidence_dir}/preclean_user.out" || true
run_sql "${db_user_name}" "" "CREATE USER ${smoke_user} '${smoke_password}';" "${evidence_dir}/create_user.out"
if ! grep -qi 'success' "${evidence_dir}/create_user.out"; then
  record AUTH_SETUP FAIL "failed to create temporary user"
else
  denied_out=${evidence_dir}/AUTH_NO_MAINTAIN.out
  run_sql "${smoke_user}" "${smoke_password}" "REMOVE DATANODE ${invalid_dn_id};" "${denied_out}"
  if grep -Eqi 'permission|privilege|not have.*MAINTAIN|no permissions|602' "${denied_out}"; then
    record AUTH_NO_MAINTAIN PASS "ordinary user rejected"
  else
    record AUTH_NO_MAINTAIN FAIL "missing explicit permission rejection"
  fi

  run_sql "${db_user_name}" "" "GRANT MAINTAIN TO USER ${smoke_user};" "${evidence_dir}/grant_maintain.out"
  granted_out=${evidence_dir}/AUTH_WITH_MAINTAIN.out
  run_sql "${smoke_user}" "${smoke_password}" "REMOVE DATANODE ${invalid_dn_id};" "${granted_out}"
  if grep -Eqi 'permission|privilege|not have.*MAINTAIN|no permissions|602' "${granted_out}"; then
    record AUTH_WITH_MAINTAIN FAIL "MAINTAIN user still rejected by authorization"
  elif grep -qi 'success' "${granted_out}"; then
    record AUTH_WITH_MAINTAIN FAIL "unknown DataNode unexpectedly accepted"
  elif grep -Eqi 'not in the cluster|not existed|does not exist|input format is incorrect' "${granted_out}"; then
    record AUTH_WITH_MAINTAIN PASS "authorization passed; semantic unknown-node check rejected request"
  else
    record AUTH_WITH_MAINTAIN FAIL "unexpected response after MAINTAIN grant"
  fi

  run_sql "${db_user_name}" "" "REVOKE MAINTAIN FROM USER ${smoke_user};" "${evidence_dir}/revoke_maintain.out"
  revoked_out=${evidence_dir}/AUTH_AFTER_REVOKE.out
  run_sql "${smoke_user}" "${smoke_password}" "REMOVE DATANODE ${invalid_dn_id};" "${revoked_out}"
  if grep -Eqi 'permission|privilege|not have.*MAINTAIN|no permissions|602' "${revoked_out}"; then
    record AUTH_AFTER_REVOKE PASS "permission rejection restored"
  else
    record AUTH_AFTER_REVOKE FAIL "REVOKE MAINTAIN did not restore rejection"
  fi
fi

audit_config_file=${evidence_dir}/audit_config.out
: > "${audit_config_file}"
while read -r dn_ip
do
  [[ -z "${dn_ip}" ]] && continue
  ssh -n -o ConnectTimeout=10 "${os_user_name}@${dn_ip}" \
    "grep -E '^(enable_audit_log|auditable_operation_type|auditable_control_event_type|auditable_operation_level|auditable_operation_result)=' '${db_dir}/conf/iotdb-system.properties'" \
    >> "${audit_config_file}" 2>&1 || true
done < "${datanode_file}"

if grep -Eq '^enable_audit_log=true$' "${audit_config_file}" && grep -Eq '^auditable_operation_type=.*CONTROL' "${audit_config_file}"; then
  sleep 5
  audit_out=${evidence_dir}/AUDIT_REMOVE_DATANODE.out
  run_sql "${db_user_name}" "" \
    "SELECT * FROM root.__audit.log.** WHERE sql_string LIKE '%REMOVE DATANODE ${invalid_dn_id}%' ORDER BY TIME DESC LIMIT 20 ALIGN BY DEVICE;" \
    "${audit_out}"
  if grep -q "REMOVE DATANODE ${invalid_dn_id}" "${audit_out}"; then
    record AUDIT_REMOVE_DATANODE PASS "REMOVE DATANODE audit row found"
  else
    record AUDIT_REMOVE_DATANODE FAIL "CONTROL audit enabled but REMOVE DATANODE row missing"
  fi
else
  record AUDIT_REMOVE_DATANODE SKIP "runtime audit config does not include CONTROL; operation is not audited by config"
fi

normalize_cluster_state after
if cmp -s "${evidence_dir}/before_show_datanodes.normalized" "${evidence_dir}/after_show_datanodes.normalized" && \
   cmp -s "${evidence_dir}/before_show_regions.normalized" "${evidence_dir}/after_show_regions.normalized"; then
  record STATE_UNCHANGED PASS "SHOW DATANODES and SHOW REGIONS unchanged"
else
  record STATE_UNCHANGED FAIL "cluster metadata changed during rejection-only smoke tests"
  diff -u "${evidence_dir}/before_show_datanodes.normalized" "${evidence_dir}/after_show_datanodes.normalized" > "${evidence_dir}/show_datanodes.diff" || true
  diff -u "${evidence_dir}/before_show_regions.normalized" "${evidence_dir}/after_show_regions.normalized" > "${evidence_dir}/show_regions.diff" || true
fi

printf 'fail_count=%d,skip_count=%d,evidence=%s\n' "${fail_count}" "${skip_count}" "${evidence_dir}"
[[ ${fail_count} -eq 0 ]]
