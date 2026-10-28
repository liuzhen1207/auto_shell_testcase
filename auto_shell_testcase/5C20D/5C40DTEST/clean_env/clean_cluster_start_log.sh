  #!/usr/bin/env bash
  set -uo pipefail

  MAX_PROCESS=20

  cur_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  conf_file="${cur_dir}/../conf/test.conf"
  dn_file="${cur_dir}/../conf/datanode_20d.txt"
  cn_file="${cur_dir}/../conf/confignode_5c.txt"

  get_conf_value() {
    local key="$1"
    awk -F '=' -v key="$key" '
      $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
        exit
      }
    ' "$conf_file"
  }

  require_value() {
    local name="$1"
    local value="$2"
    if [[ -z "$value" ]]; then
      echo "ERROR: config [$name] is empty" >&2
      exit 1
    fi
  }

  trim_line() {
    local s="$1"
    s="${s%%#*}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s\n' "$s"
  }

  do_clean() {
    local host="$1"
    local node_type="$2"
    local base_dir="$3"

    [[ -z "$host" ]] && return 0

    if [[ -z "$base_dir" || "$base_dir" == "/" ]]; then
      echo "ERROR: invalid base_dir [$base_dir] for [$node_type][$host]" >&2
      return 1
    fi

    echo "===== 开始处理 ${node_type} 节点：${host} ====="

    ssh \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 \
      -o ConnectionAttempts=1 \
      -o ServerAliveInterval=5 \
      -o ServerAliveCountMax=1 \
      "${os_user_name}@${host}" \
      "base_dir='${base_dir}';
       for dir in \"\$base_dir/start_*.log\"; do
         if [ -d \"\$dir\" ]; then
           rm -rf -- \"\$dir\"
           echo removed: \"\$dir\"
         else
           echo skip: \"\$dir\" not exists
         fi
       done"

    local rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "===== 完成处理 ${node_type} 节点：${host} ====="
    else
      echo "ERROR: 处理 ${node_type} 节点失败：${host}" >&2
    fi
    return "$rc"
  }

  run_batch() {
    local node_file="$1"
    local node_type="$2"
    local base_dir="$3"

    [[ -f "$node_file" ]] || {
      echo "ERROR: node file not found: $node_file" >&2
      return 1
    }

    awk '
      {
        sub(/#.*/, "", $0)
        gsub(/^[ \t]+|[ \t]+$/, "", $0)
        if (length($0) > 0) {
          print $0
        }
      }
    ' "$node_file" | xargs -r -I '{}' -P "$MAX_PROCESS" bash -c '
      do_clean "$1" "$2" "$3"
    ' _ '{}' "$node_type" "$base_dir"
  }

  os_user_name="$(get_conf_value os_user_name)"
  testdb="$(get_conf_value v_testdb)"
  db_parent_dir="$(get_conf_value v_db_parent_dir)"
  cn_db_parent_dir="$(get_conf_value v_cn_db_parent_dir)"

  require_value os_user_name "$os_user_name"
  require_value v_testdb "$testdb"
  require_value v_db_parent_dir "$db_parent_dir"
  require_value v_cn_db_parent_dir "$cn_db_parent_dir"

  db_dir="${db_parent_dir}/${testdb}"
  cn_db_dir="${cn_db_parent_dir}/${testdb}"

  export os_user_name
  export -f do_clean

  run_batch "$dn_file" "datanode" "$db_dir"
  dn_rc=$?

  run_batch "$cn_file" "confignode" "$cn_db_dir"
  cn_rc=$?

  if [[ $dn_rc -eq 0 && $cn_rc -eq 0 ]]; then
    echo "all cleanup jobs finished successfully"
    exit 0
  else
    echo "all cleanup jobs finished, but some nodes failed" >&2
    exit 1
  fi


