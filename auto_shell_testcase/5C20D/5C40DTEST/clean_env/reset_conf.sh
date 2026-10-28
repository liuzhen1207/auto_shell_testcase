#!/usr/bin/env bash

set -uo pipefail

MAX_PROCESS=20
cur_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
conf_file="${cur_dir}/../conf/test.conf"
# 使用完整候选节点清单，覆盖本次未启动但可能残留环境的节点。
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

load_nodes() {
  awk '
    {
      sub(/#.*/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if (length($0) > 0 && !seen[$0]++) print $0
    }
  ' "${node_list_file}"
}

restore_conf() {
  local host="$1"
  local base_dir="$2"

  if [[ -z "${base_dir}" || "${base_dir}" == "/" ]]; then
    echo "ERROR: invalid base_dir [${base_dir}] for [${host}]" >&2
    return 1
  fi

  ssh -o BatchMode=yes -o ConnectTimeout=10 \
    "${os_user_name}@${host}" \
    "base_dir='${base_dir}'
     conf_dir=\"\$base_dir/conf\"
     orig_dir=\"\$base_dir/conf_orig\"
     tmp_dir=\"\$base_dir/conf.restore_tmp.\$\$\"
     if [ ! -d \"\$orig_dir\" ]; then
       echo skip: \"\$orig_dir\" not exists
       exit 0
     fi
     rm -rf -- \"\$tmp_dir\" || exit 1
     cp -rp -- \"\$orig_dir\" \"\$tmp_dir\" || exit 1
     rm -rf -- \"\$conf_dir\" || exit 1
     mv -- \"\$tmp_dir\" \"\$conf_dir\" || exit 1
     echo restored: \"\$conf_dir\"
    "
}

run_batch() {
  local base_dir="$1"
  load_nodes | xargs -r -I '{}' -P "${MAX_PROCESS}" bash -c '
    restore_conf "$1" "$2"
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

  if [[ -z "${os_user_name}" || -z "${testdb}" || -z "${db_parent_dir}" || -z "${cn_db_parent_dir}" ]]; then
    echo "ERROR: test.conf 中缺少必要配置" >&2
    return 1
  fi

  db_dir="${db_parent_dir}/${testdb}"
  cn_db_dir="${cn_db_parent_dir}/${testdb}"
  export os_user_name
  export -f restore_conf

  run_batch "${db_dir}" || dn_rc=$?

  # CN/DN 同机；不同安装目录时再恢复 CN 目录，相同则避免重复操作。
  if [[ "${cn_db_dir}" != "${db_dir}" ]]; then
    run_batch "${cn_db_dir}" || cn_rc=$?
  fi

  if ((dn_rc == 0 && cn_rc == 0)); then
    echo "all configuration directories restored successfully"
    return 0
  fi
  echo "some configuration directories failed to restore" >&2
  return 1
}

main "$@"
