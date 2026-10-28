#!/bin/bash
set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
conf_file=${TEST_CONF_FILE:-${cur_dir}/../conf/test.conf}
evidence_dir=${EVIDENCE_DIR:-${cur_dir}/extend_region_unknown_dn_evidence_$(date +%Y%m%d_%H%M%S)}
unknown_timeout=${UNKNOWN_TIMEOUT_SECONDS:-180}
running_timeout=${RUNNING_TIMEOUT_SECONDS:-300}
process_stop_timeout=${PROCESS_STOP_TIMEOUT_SECONDS:-120}
restart_attempts=${RESTART_ATTEMPTS:-3}
fail_count=0
target_dn_id=""
target_dn_ip=""
target_stopped=0

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
query_ip=$(head -1 "${datanode_file}" 2>/dev/null | sed 's/ //g')
cli=${cli_dir}/sbin/start-cli.sh

record() {
  local case_id=$1 result=$2 detail=$3
  printf '%s,%s,%s\n' "${case_id}" "${result}" "${detail//,/;}" | tee -a "${result_file}"
  [[ "${result}" == "FAIL" ]] && fail_count=$((fail_count+1))
}

run_sql() {
  local dialect=$1 sql=$2 output=$3
  local dialect_args=()
  [[ "${dialect}" == "table" ]] && dialect_args=(-sql_dialect table)
  "${cli}" -h "${query_ip}" -u "${db_user_name}" "${dialect_args[@]}" -e "${sql}" > "${output}" 2>&1
}

show_datanodes() {
  run_sql table "SHOW DATANODES;" "$1"
}

wait_dn_status() {
  local expected=$1 timeout=$2 prefix=$3
  local begin now output
  begin=$(date +%s)
  while true; do
    output=${evidence_dir}/${prefix}_$(date +%s).out
    show_datanodes "${output}" || true
    if awk -F '|' -v id="${target_dn_id}" -v expected="${expected}" '
      $0 !~ /^\+/ && NF>=5 {
        dn=$2; status=$3; gsub(/ /,"",dn); gsub(/ /,"",status)
        if (dn==id && tolower(status)==tolower(expected)) found=1
      }
      END {exit !found}' "${output}"; then
      cp "${output}" "${evidence_dir}/show_datanodes_${expected}.out"
      return 0
    fi
    now=$(date +%s)
    [[ $((now-begin)) -ge ${timeout} ]] && return 1
    sleep 5
  done
}

start_target_dn() {
  local heapdump=${db_dir}/v2_541_unknown_dn_heapdump.hprof
  ssh -n -o ConnectTimeout=10 "${os_user_name}@${target_dn_ip}" \
    "source /etc/profile; nohup '${db_dir}/sbin/start-datanode.sh' -g -H '${heapdump}' > '${db_dir}/v2_541_unknown_dn_restart.out' 2>&1 < /dev/null &" \
    > "${evidence_dir}/start_target_dn.out" 2>&1
}

wait_target_dn_process_stopped() {
  local timeout=$1 begin now
  begin=$(date +%s)
  while true; do
    if ! ssh -n -o ConnectTimeout=10 "${os_user_name}@${target_dn_ip}" \
      "source /etc/profile; ! jps -l 2>/dev/null | grep -Eq '(^|[.])DataNode$|com[.]timecho[.]iotdb[.]DataNode'"; then
      now=$(date +%s)
      [[ $((now-begin)) -ge ${timeout} ]] && return 1
      sleep 3
      continue
    fi
    return 0
  done
}

cleanup() {
  if [[ ${target_stopped} -eq 1 && -n "${target_dn_ip}" ]]; then
    local attempt
    if ! wait_target_dn_process_stopped "${process_stop_timeout}"; then
      record CLEANUP_RESTART_DN FAIL "old DN process did not exit before restart"
      return
    fi
    for ((attempt=1; attempt<=restart_attempts; attempt++)); do
      if start_target_dn && wait_dn_status Running "${running_timeout}" "cleanup_running_attempt_${attempt}"; then
        target_stopped=0
        record CLEANUP_RESTART_DN PASS "DN ${target_dn_id}/${target_dn_ip} recovered to Running on attempt ${attempt}"
        return
      fi
      wait_target_dn_process_stopped "${process_stop_timeout}" || true
    done
    record CLEANUP_RESTART_DN FAIL "DN ${target_dn_id}/${target_dn_ip} did not recover after ${restart_attempts} attempts"
  fi
}
trap cleanup EXIT

if [[ ! -f "${conf_file}" || ! -f "${datanode_file}" || ! -x "${cli}" || -z "${query_ip}" ]]; then
  record PRECHECK FAIL "test.conf, datanode.txt, query IP or CLI missing"
  exit 1
fi

show_datanodes "${evidence_dir}/before_show_datanodes.out"
# Table 方言在未 USE database 时可能返回 Empty set；Region 拓扑统一用 Tree 方言查询。
run_sql tree "SHOW REGIONS;" "${evidence_dir}/before_show_regions.out"

# 遍历所有非查询入口的 Running DN，选择同时存在未持有 SchemaRegion/DataRegion 的节点。
# 不能直接使用第一个 Running DN：它可能恰好持有当前所有候选 Region，造成前置检查假失败。
read -r target_dn_id target_dn_ip schema_region data_region < <(awk -F '|' -v query_ip="${query_ip}" '
  FNR==NR {
    if ($0 !~ /^\+/ && NF>=9) {
      rid=$2; type=$3; db=$5; dn=$8
      gsub(/ /,"",rid); gsub(/ /,"",type); gsub(/ /,"",db); gsub(/ /,"",dn)
      if (rid~/^[0-9]+$/ && db!~/^root[.]__audit/) {
        key=rid SUBSEP type
        regions[key]=1
        held[dn SUBSEP key]=1
      }
    }
    next
  }
  $0 !~ /^\+/ && NF>=5 {
    id=$2; status=$3; ip=$4
    gsub(/ /,"",id); gsub(/ /,"",status); gsub(/ /,"",ip)
    if (id!~/^[0-9]+$/ || tolower(status)!="running" || ip==query_ip) next
    schema=""; data=""
    for (key in regions) {
      split(key,a,SUBSEP)
      if (!((id SUBSEP key) in held) && tolower(a[2])~/schema/ && schema=="") schema=a[1]
      if (!((id SUBSEP key) in held) && tolower(a[2])~/data/ && data=="") data=a[1]
    }
    if (schema!="" && data!="") {print id,ip,schema,data; exit}
  }' "${evidence_dir}/before_show_regions.out" "${evidence_dir}/before_show_datanodes.out")

if [[ -z "${target_dn_id}" || -z "${target_dn_ip}" || -z "${schema_region}" || -z "${data_region}" ]]; then
  record PRECHECK FAIL "no non-query Running DN has both an unheld SchemaRegion and DataRegion"
  exit 1
fi
record PRECHECK PASS "target_dn=${target_dn_id}/${target_dn_ip};regions=${schema_region}/${data_region}"

ssh -n -o ConnectTimeout=10 "${os_user_name}@${target_dn_ip}" \
  "source /etc/profile; '${db_dir}/sbin/stop-datanode.sh'" \
  > "${evidence_dir}/stop_target_dn.out" 2>&1
if [[ $? -ne 0 ]]; then
  record STOP_TARGET_DN FAIL "failed to stop DN ${target_dn_id}/${target_dn_ip}"
  exit 1
fi
target_stopped=1

if ! wait_dn_status Unknown "${unknown_timeout}" wait_unknown; then
  record WAIT_DN_UNKNOWN FAIL "DN ${target_dn_id}/${target_dn_ip} did not become Unknown"
  exit 1
fi
record WAIT_DN_UNKNOWN PASS "DN ${target_dn_id}/${target_dn_ip} became Unknown"

extend_sql="EXTEND REGION ${schema_region},${data_region} TO ${target_dn_id};"
extend_out=${evidence_dir}/extend_region_to_unknown_dn.out
run_sql tree "${extend_sql}" "${extend_out}" || true
if grep -Eqi 'successfully submitted:[[:space:]]*[1-9][0-9]*|statement is executed successfully|^[[:space:]]*success[[:space:]]*$' "${extend_out}"; then
  record EXTEND_TO_UNKNOWN_DN FAIL "unexpectedly accepted: ${extend_sql}"
elif grep -Eqi 'Exception in thread|NullPointerException|Fail to connect to any config node' "${extend_out}"; then
  record EXTEND_TO_UNKNOWN_DN FAIL "uncontrolled or misleading failure"
else
  record EXTEND_TO_UNKNOWN_DN PASS "batch EXTEND was rejected while target DN was Unknown"
fi

run_sql tree "SHOW REGIONS;" "${evidence_dir}/after_extend_show_regions.out"
if awk -F '|' -v dn="${target_dn_id}" -v sr="${schema_region}" -v dr="${data_region}" '
  $0 !~ /^\+/ && NF>=9 {
    rid=$2; node=$8; gsub(/ /,"",rid); gsub(/ /,"",node)
    if (node==dn && (rid==sr || rid==dr)) found=1
  }
  END {exit found ? 0 : 1}' "${evidence_dir}/after_extend_show_regions.out"; then
  record NO_REGION_ADDED FAIL "target Unknown DN gained one of the requested Region replicas"
else
  record NO_REGION_ADDED PASS "target Unknown DN gained no requested Region replica"
fi

cleanup
trap - EXIT
printf 'fail_count=%d,evidence=%s\n' "${fail_count}" "${evidence_dir}"
[[ ${fail_count} -eq 0 ]]
