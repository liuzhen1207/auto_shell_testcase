#!/usr/bin/env bash

set -uo pipefail

MAX_PROCESS=20
cur_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
conf_file="${cur_dir}/../conf/test.conf"
# 使用完整候选节点清单，而不是本次测试的部分节点列表。
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

drop_cache_remote() {
  local node="$1"
  if ssh -o BatchMode=yes -o ConnectTimeout=10 \
    "${os_user_name}@${node}" 'sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"'; then
    echo "[INFO] 节点 ${node} 清缓存完成"
  else
    echo "[WARN] 节点 ${node} 清缓存失败，继续执行用例" >&2
  fi
  return 0
}

main() {
  [[ -f "${conf_file}" ]] || {
    echo "[WARN] 配置文件不存在，跳过清缓存：${conf_file}" >&2
    return 0
  }
  [[ -f "${node_list_file}" ]] || {
    echo "[WARN] 节点文件不存在，跳过清缓存：${node_list_file}" >&2
    return 0
  }

  os_user_name="$(get_conf_value os_user_name)"
  if [[ -z "${os_user_name}" ]]; then
    echo "[WARN] os_user_name 为空，跳过清缓存" >&2
    return 0
  fi

  export os_user_name
  export -f drop_cache_remote
  load_nodes | xargs -r -I '{}' -P "${MAX_PROCESS}" bash -c '
    drop_cache_remote "$1"
  ' _ '{}'

  # 清缓存失败只告警，不影响用例结果。
  return 0
}

main "$@"
