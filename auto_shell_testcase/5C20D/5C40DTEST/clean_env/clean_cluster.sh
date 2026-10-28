#!/usr/bin/env bash

set -uo pipefail

MAX_PROCESS=20
run_stamp="$(date +%Y%m%d_%H%M%S)"
diag_dir="${TMPDIR:-/tmp}/clean_cluster_${run_stamp}_$$"
mkdir -p "${diag_dir}"
cur_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
conf_file="${cur_dir}/../conf/test.conf"

# 使用完整候选节点清单，而不是每次测试覆盖生成的 datanode.txt。
# 扩到 40D 时改为 datanode_40d.txt。
node_list_file="${cur_dir}/../conf/datanode_20d.txt"

get_conf_value() {
  local key="$1"
  awk -F '=' -v key="${key}" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "${conf_file}"
}

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "ERROR: config [${name}] is empty" >&2
    exit 1
  fi
}

load_nodes() {
  awk '
    {
      sub(/#.*/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if (length($0) > 0 && !seen[$0]++) print $0
    }
  ' "${node_list_file}"
}

do_clean() {
  local host="$1"
  local base_dir="$2"
  local node_log="${diag_dir}/${host//[^A-Za-z0-9_.-]/_}.log"
  local rc=0

  if [[ -z "${base_dir}" || "${base_dir}" == "/" ]]; then
    echo "ERROR: invalid base_dir [${base_dir}] for [${host}]" >&2
    return 1
  fi

  echo "===== 开始清理节点 ${host}：${base_dir}，诊断日志：${node_log} ====="
  {
    echo "host=${host} base_dir=${base_dir} start=$(date '+%F %T%z')"
  } >"${node_log}"
  if ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
    "${os_user_name}@${host}" \
    "base_dir='${base_dir}'
     for dir in \"\$base_dir/data\" \"\$base_dir/logs\"; do
       if [ -d \"\$dir\" ]; then
         rm -rf -- \"\$dir\" || exit 1
         echo removed: \"\$dir\"
       else
         echo skip: \"\$dir\" not exists
       fi
     done
     found_log=0
     for file in \"\$base_dir\"/start_*.log; do
       if [ -f \"\$file\" ]; then
         found_log=1
         rm -f -- \"\$file\" || exit 1
         echo removed: \"\$file\"
       fi
     done
     if [ \"\$found_log\" -eq 0 ]; then
       echo skip: \"\$base_dir/start_*.log\" not exists
     fi
     exit 0
    " >>"${node_log}" 2>&1; then
    echo "===== 完成清理节点 ${host}：${base_dir} ====="
    echo "status=success end=$(date '+%F %T%z')" >>"${node_log}"
    return 0
  else
    rc=$?
  fi

  echo "status=failed rc=${rc} end=$(date '+%F %T%z')" >>"${node_log}"
  echo "ERROR: 清理节点失败 ${host}：${base_dir} rc=${rc}，详见 ${node_log}" >&2
  sed 's/^/  | /' "${node_log}" >&2
  return 1
}

run_batch() {
  local base_dir="$1"
  load_nodes | xargs -r -I '{}' -P "${MAX_PROCESS}" bash -c '
    do_clean "$1" "$2"
  ' _ '{}' "${base_dir}"
}

main() {
  local dn_rc=0 cn_rc=0

  [[ -f "${conf_file}" ]] || {
    echo "ERROR: config file not found: ${conf_file}" >&2
    return 1
  }
  [[ -f "${node_list_file}" ]] || {
    echo "ERROR: node file not found: ${node_list_file}" >&2
    return 1
  }

  os_user_name="$(get_conf_value os_user_name)"
  testdb="$(get_conf_value v_testdb)"
  db_parent_dir="$(get_conf_value v_db_parent_dir)"
  cn_db_parent_dir="$(get_conf_value v_cn_db_parent_dir)"

  require_value os_user_name "${os_user_name}"
  require_value v_testdb "${testdb}"
  require_value v_db_parent_dir "${db_parent_dir}"
  require_value v_cn_db_parent_dir "${cn_db_parent_dir}"

  db_dir="${db_parent_dir}/${testdb}"
  cn_db_dir="${cn_db_parent_dir}/${testdb}"
  export os_user_name
  export diag_dir
  export -f do_clean

  run_batch "${db_dir}" || dn_rc=$?

  # CN/DN 同机；只有安装目录不同才需要第二次清理。
  if [[ "${cn_db_dir}" != "${db_dir}" ]]; then
    run_batch "${cn_db_dir}" || cn_rc=$?
  fi

  if ((dn_rc == 0 && cn_rc == 0)); then
    echo "all cleanup jobs finished successfully"
    return 0
  fi
  echo "all cleanup jobs finished, but some nodes failed (dn_rc=${dn_rc}, cn_rc=${cn_rc})" >&2
  echo "diagnostic logs: ${diag_dir}" >&2
  return 1
}

main "$@"
