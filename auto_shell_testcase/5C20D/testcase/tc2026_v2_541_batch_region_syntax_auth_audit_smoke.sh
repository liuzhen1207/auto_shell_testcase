#!/bin/bash
set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
conf_file=${TEST_CONF_FILE:-${cur_dir}/../conf/test.conf}
evidence_dir=${EVIDENCE_DIR:-${cur_dir}/batch_region_smoke_evidence_$(date +%Y%m%d_%H%M%S)}
smoke_user=${SMOKE_USER:-region_smoke_user}
smoke_password=${SMOKE_PASSWORD:-RegionSmoke_2026}
invalid_region_a=2147483647
invalid_region_b=2147483646
invalid_dn_id=2147483647
fail_count=0
skip_count=0
audit_original_type=""
audit_config_changed=0

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
  local case_id=$1 result=$2 detail=$3
  printf '%s,%s,%s\n' "${case_id}" "${result}" "${detail//,/;}" | tee -a "${result_file}"
  [[ "${result}" == "FAIL" ]] && fail_count=$((fail_count+1))
  [[ "${result}" == "SKIP" ]] && skip_count=$((skip_count+1))
}

run_sql() {
  local dialect=$1 user=$2 password=$3 sql=$4 output=$5
  local dialect_args=()
  [[ "${dialect}" == "table" ]] && dialect_args=(-sql_dialect table)
  if [[ -n "${password}" ]]; then
    "${cli}" -h "${query_ip}" -u "${user}" -pw "${password}" "${dialect_args[@]}" -e "${sql}" > "${output}" 2>&1
  else
    "${cli}" -h "${query_ip}" -u "${user}" "${dialect_args[@]}" -e "${sql}" > "${output}" 2>&1
  fi
}

expect_rejected() {
  local case_id=$1 dialect=$2 sql=$3
  local output=${evidence_dir}/${case_id}.out
  run_sql "${dialect}" "${db_user_name}" "" "${sql}" "${output}"
  if grep -Eqi 'successfully submitted:[[:space:]]*[1-9][0-9]*|^[[:space:]]*success[[:space:]]*$' "${output}"; then
    record "${case_id}" FAIL "unexpected success: ${sql}"
  elif grep -Eqi 'Exception in thread|NullPointerException|Fail to connect to any config node' "${output}"; then
    record "${case_id}" FAIL "uncontrolled or misleading failure"
  else
    record "${case_id}" PASS "rejected cleanly"
  fi
}

normalize_cluster_state() {
  local prefix=$1
  run_sql table "${db_user_name}" "" "SHOW DATANODES;" "${evidence_dir}/${prefix}_show_datanodes.out"
  # Table 方言在未 USE database 时可能返回 Empty set；Region 拓扑统一用 Tree 方言查询。
  run_sql tree "${db_user_name}" "" "SHOW REGIONS;" "${evidence_dir}/${prefix}_show_regions.out"
  awk -F '|' '$0 !~ /^\+/ && NF>=5 {id=$2;s=$3;ip=$4;gsub(/ /,"",id);gsub(/ /,"",s);gsub(/ /,"",ip);if(id~/^[0-9]+$/)print id","s","ip}' \
    "${evidence_dir}/${prefix}_show_datanodes.out" | sort -t, -k1,1n > "${evidence_dir}/${prefix}_show_datanodes.normalized"
  awk -F '|' '$0 !~ /^\+/ && NF>=9 {r=$2;t=$3;s=$4;db=$5;d=$8;ip=$9;gsub(/ /,"",r);gsub(/ /,"",t);gsub(/ /,"",s);gsub(/ /,"",db);gsub(/ /,"",d);gsub(/ /,"",ip);if(r~/^[0-9]+$/)print r","t","s","db","d","ip}' \
    "${evidence_dir}/${prefix}_show_regions.out" | sort -t, -k1,1n -k5,5n > "${evidence_dir}/${prefix}_show_regions.normalized"
}

cleanup() {
  run_sql tree "${db_user_name}" "" "DROP USER ${smoke_user};" "${evidence_dir}/cleanup_drop_user.out" || true
  if [[ ${audit_config_changed} -eq 1 && -n "${audit_original_type}" ]]; then
    run_sql tree "${db_user_name}" "" \
      "SET CONFIGURATION 'auditable_operation_type'='${audit_original_type}';" \
      "${evidence_dir}/cleanup_restore_audit_type.out" || true
  fi
}
trap cleanup EXIT

if [[ ! -x "${cli}" || ! -f "${datanode_file}" ]]; then
  record PRECHECK FAIL "CLI or datanode file missing"
  exit 1
fi

normalize_cluster_state before

# 从真实拓扑中选择一个 Region、一个已持有该副本的 DN、一个未持有该副本的 DN。
# 用它们验证重复项和真实对象语义，但只执行必然被拒绝且不改变拓扑的组合。
valid_region_id=$(awk -F '|' '$0 !~ /^\+/ && NF>=9 {r=$2;db=$5;gsub(/ /,"",r);gsub(/ /,"",db);if(r~/^[0-9]+$/ && db!~/^root[.]__audit/){print r;exit}}' \
  "${evidence_dir}/before_show_regions.out")
valid_region_holder_dn=$(awk -F '|' -v rid="${valid_region_id}" '$0 !~ /^\+/ && NF>=9 {r=$2;d=$8;gsub(/ /,"",r);gsub(/ /,"",d);if(r==rid){print d;exit}}' \
  "${evidence_dir}/before_show_regions.out")
valid_region_non_holder_dn=$(awk -F '|' -v rid="${valid_region_id}" '
  FNR==NR && $0 !~ /^\+/ && NF>=9 {r=$2;d=$8;gsub(/ /,"",r);gsub(/ /,"",d);if(r==rid)holder[d]=1;next}
  FNR!=NR && $0 !~ /^\+/ && NF>=5 {d=$2;gsub(/ /,"",d);if(d~/^[0-9]+$/ && !(d in holder)){print d;exit}}' \
  "${evidence_dir}/before_show_regions.out" "${evidence_dir}/before_show_datanodes.out")
if [[ -z "${valid_region_id}" || -z "${valid_region_holder_dn}" || -z "${valid_region_non_holder_dn}" ]]; then
  record REAL_TOPOLOGY_SETUP FAIL "could not select real Region/holder/non-holder DataNode"
else
  record REAL_TOPOLOGY_SETUP PASS "region=${valid_region_id};holder_dn=${valid_region_holder_dn};non_holder_dn=${valid_region_non_holder_dn}"
fi

# 纯语法用例并不依赖真实拓扑；取样失败时仍使用不存在的 DN，保证 SQL 完整且无副作用。
syntax_holder_dn=${valid_region_holder_dn:-${invalid_dn_id}}
syntax_non_holder_dn=${valid_region_non_holder_dn:-${invalid_dn_id}}

# 短用例独立运行时临时追加 CONTROL；主用例新建集群时已直接配置 QUERY,CONTROL。
audit_original_type=$(ssh -n -o ConnectTimeout=10 "${os_user_name}@${query_ip}" \
  "awk -F= '/^auditable_operation_type=/{gsub(/ /,\"\",\$2);print \$2;exit}' '${db_dir}/conf/iotdb-system.properties'" 2>/dev/null)
audit_original_type=${audit_original_type:-QUERY}
if [[ ",${audit_original_type}," != *,CONTROL,* ]]; then
  run_sql tree "${db_user_name}" "" \
    "SET CONFIGURATION 'auditable_operation_type'='${audit_original_type},CONTROL';" \
    "${evidence_dir}/enable_control_audit.out"
  if grep -Eqi 'success|execute successfully' "${evidence_dir}/enable_control_audit.out"; then
    audit_config_changed=1
    record AUDIT_ENABLE PASS "temporarily changed auditable_operation_type=${audit_original_type},CONTROL"
    sleep 3
  else
    record AUDIT_ENABLE FAIL "failed to append CONTROL audit type"
  fi
else
  record AUDIT_ENABLE PASS "CONTROL already enabled"
fi

# Tree/table 两种方言的最小语法和语义拒绝用例。
# 除明确标注的真实对象重复操作外，其余使用不存在的 Region/DN；最终统一校验拓扑未改变。
expect_rejected TREE_EXTEND_EMPTY tree "EXTEND REGION TO ${invalid_dn_id};"
expect_rejected TREE_EXTEND_TRAILING_COMMA tree "EXTEND REGION ${invalid_region_a}, TO ${invalid_dn_id};"
expect_rejected TREE_REMOVE_EMPTY tree "REMOVE REGION FROM ${invalid_dn_id};"
expect_rejected TREE_REMOVE_NON_NUMERIC tree "REMOVE REGION abc,def FROM ${invalid_dn_id};"
expect_rejected TABLE_EXTEND_UNKNOWN_LIST table "EXTEND REGION ${invalid_region_a},${invalid_region_b} TO ${invalid_dn_id};"
expect_rejected TABLE_REMOVE_UNKNOWN_LIST table "REMOVE REGION ${invalid_region_a},${invalid_region_b} FROM ${invalid_dn_id};"
expect_rejected SEMANTIC_EXTEND_DUPLICATE tree "EXTEND REGION ${invalid_region_a},${invalid_region_a} TO ${invalid_dn_id};"
expect_rejected SEMANTIC_REMOVE_DUPLICATE tree "REMOVE REGION ${invalid_region_a},${invalid_region_a} FROM ${invalid_dn_id};"
expect_rejected SEMANTIC_EXTEND_OVERFLOW tree "EXTEND REGION 2147483648,2147483649 TO ${invalid_dn_id};"
expect_rejected SEMANTIC_REMOVE_NEGATIVE tree "REMOVE REGION -1,-2 FROM ${invalid_dn_id};"

# 真实对象 + 重复项：已有副本不能重复 EXTEND；没有副本不能重复 REMOVE。
if [[ -n "${valid_region_id}" && -n "${valid_region_holder_dn}" && -n "${valid_region_non_holder_dn}" ]]; then
  expect_rejected REAL_EXTEND_DUPLICATE_EXISTING tree \
    "EXTEND REGION ${valid_region_id},${valid_region_id} TO ${valid_region_holder_dn};"
  expect_rejected REAL_REMOVE_DUPLICATE_ABSENT table \
    "REMOVE REGION ${valid_region_id},${valid_region_id} FROM ${valid_region_non_holder_dn};"
fi

# 目标 DN 不是列表：重复 DN、多个 DN、空 DN 均应在语法层拒绝。
expect_rejected TREE_EXTEND_DUPLICATE_DN tree \
  "EXTEND REGION ${invalid_region_a},${invalid_region_b} TO ${syntax_holder_dn},${syntax_holder_dn};"
expect_rejected TREE_REMOVE_MULTI_DN tree \
  "REMOVE REGION ${invalid_region_a},${invalid_region_b} FROM ${syntax_holder_dn},${syntax_non_holder_dn};"
expect_rejected TABLE_EXTEND_EMPTY_DN table \
  "EXTEND REGION ${invalid_region_a},${invalid_region_b} TO;"
expect_rejected TABLE_REMOVE_EMPTY_DN table \
  "REMOVE REGION ${invalid_region_a},${invalid_region_b} FROM;"

# 非整数、NULL、字符串、浮点数、括号和列表空元素。
expect_rejected TREE_EXTEND_NULL tree "EXTEND REGION NULL,${invalid_region_a} TO ${syntax_holder_dn};"
expect_rejected TREE_REMOVE_NULL tree "REMOVE REGION ${invalid_region_a},NULL FROM ${syntax_holder_dn};"
expect_rejected TABLE_EXTEND_QUOTED_STRING table "EXTEND REGION '1','2' TO ${syntax_holder_dn};"
expect_rejected TABLE_REMOVE_QUOTED_STRING table "REMOVE REGION '1','2' FROM ${syntax_holder_dn};"
expect_rejected TREE_EXTEND_FLOAT tree "EXTEND REGION 1.0,2.0 TO ${syntax_holder_dn};"
expect_rejected TABLE_REMOVE_FLOAT table "REMOVE REGION 1.0,2.0 FROM ${syntax_holder_dn};"
expect_rejected TREE_EXTEND_DOUBLE_COMMA tree "EXTEND REGION ${invalid_region_a},,${invalid_region_b} TO ${syntax_holder_dn};"
expect_rejected TABLE_REMOVE_DOUBLE_COMMA table "REMOVE REGION ${invalid_region_a},,${invalid_region_b} FROM ${syntax_holder_dn};"
expect_rejected TREE_EXTEND_LEADING_COMMA tree "EXTEND REGION ,${invalid_region_a} TO ${syntax_holder_dn};"
expect_rejected TABLE_REMOVE_TRAILING_COMMA table "REMOVE REGION ${invalid_region_a}, FROM ${syntax_holder_dn};"
expect_rejected TREE_EXTEND_PARENTHESES tree "EXTEND REGION (${invalid_region_a},${invalid_region_b}) TO ${syntax_holder_dn};"
expect_rejected TABLE_REMOVE_PARENTHESES table "REMOVE REGION (${invalid_region_a},${invalid_region_b}) FROM ${syntax_holder_dn};"

run_sql tree "${db_user_name}" "" "DROP USER ${smoke_user};" "${evidence_dir}/preclean_user.out" || true
run_sql tree "${db_user_name}" "" "CREATE USER ${smoke_user} '${smoke_password}';" "${evidence_dir}/create_user.out"
if ! grep -qi 'success' "${evidence_dir}/create_user.out"; then
  record AUTH_SETUP FAIL "failed to create temporary user"
else
  denied_out=${evidence_dir}/AUTH_NO_SYSTEM.out
  run_sql tree "${smoke_user}" "${smoke_password}" "EXTEND REGION ${invalid_region_a},${invalid_region_b} TO ${invalid_dn_id};" "${denied_out}"
  if grep -Eqi 'permission|privilege|not have.*MAINTAIN|no permissions|602' "${denied_out}"; then
    record AUTH_NO_SYSTEM PASS "ordinary user rejected before semantic validation"
  else
    record AUTH_NO_SYSTEM FAIL "missing explicit SYSTEM permission rejection"
  fi

  run_sql tree "${db_user_name}" "" "GRANT SYSTEM ON root.** TO USER ${smoke_user};" "${evidence_dir}/grant_system.out"
  granted_out=${evidence_dir}/AUTH_WITH_SYSTEM.out
  run_sql tree "${smoke_user}" "${smoke_password}" "REMOVE REGION ${invalid_region_a},${invalid_region_b} FROM ${invalid_dn_id};" "${granted_out}"
  if grep -Eqi 'permission|privilege|not have.*MAINTAIN|no permissions|602' "${granted_out}"; then
    record AUTH_WITH_SYSTEM FAIL "SYSTEM user still rejected by authorization"
  elif grep -Eqi 'successfully submitted:[[:space:]]*[1-9][0-9]*|^[[:space:]]*success[[:space:]]*$' "${granted_out}"; then
    record AUTH_WITH_SYSTEM FAIL "unknown region list unexpectedly accepted"
  else
    record AUTH_WITH_SYSTEM PASS "authorization passed; semantic validation rejected request"
  fi

  run_sql tree "${db_user_name}" "" "REVOKE SYSTEM ON root.** FROM USER ${smoke_user};" "${evidence_dir}/revoke_system.out"
  revoked_out=${evidence_dir}/AUTH_AFTER_REVOKE.out
  run_sql table "${smoke_user}" "${smoke_password}" "EXTEND REGION ${invalid_region_a},${invalid_region_b} TO ${invalid_dn_id};" "${revoked_out}"
  if grep -Eqi 'permission|privilege|not have.*MAINTAIN|no permissions|602' "${revoked_out}"; then
    record AUTH_AFTER_REVOKE PASS "permission rejection restored in table dialect"
  else
    record AUTH_AFTER_REVOKE FAIL "REVOKE SYSTEM did not restore rejection"
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
  audit_out=${evidence_dir}/AUDIT_BATCH_REGION.out
  run_sql tree "${db_user_name}" "" \
    "SELECT * FROM root.__audit.log.** WHERE sql_string LIKE '%REGION ${invalid_region_a},${invalid_region_b}%' ORDER BY TIME DESC LIMIT 50 ALIGN BY DEVICE;" \
    "${audit_out}"
  if grep -Eq "EXTEND REGION ${invalid_region_a},${invalid_region_b}|REMOVE REGION ${invalid_region_a},${invalid_region_b}" "${audit_out}"; then
    record AUDIT_BATCH_REGION PASS "batch EXTEND/REMOVE REGION audit row found"
  else
    record AUDIT_BATCH_REGION FAIL "CONTROL audit enabled but batch Region audit row missing"
  fi
else
  record AUDIT_BATCH_REGION SKIP "runtime audit config does not include CONTROL"
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
