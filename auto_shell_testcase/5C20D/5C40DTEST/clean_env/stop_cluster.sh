#!/bin/bash

cur_dir="$(cd "$(dirname "$0")" && pwd)"
conf_file="${cur_dir}/../conf/test.conf"

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

os_user_name="$(get_conf_value os_user_name)"
testdb="$(get_conf_value v_testdb)"
db_parent_dir="$(get_conf_value v_db_parent_dir)"
cn_db_parent_dir="$(get_conf_value v_cn_db_parent_dir)"

db_dir="${db_parent_dir}/${testdb}"
cn_db_dir="${cn_db_parent_dir}/${testdb}"

# 后续扩容时只需要修改这一处，例如 datanode_40d.txt。
node_list_file="${cur_dir}/../conf/datanode_20d.txt"
benchmark_hosts_file="${cur_dir}/../benchmark/generated_benchmark/benchmark_hosts.conf"
stop_timeout=180

log() {
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"
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

load_benchmark_hosts() {
  awk '
    {
      sub(/#.*/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if (length($0) > 0 && !seen[$0]++) print $0
    }
  ' "${benchmark_hosts_file}"
}

remote_pids() {
  local node="$1"
  local process_name="$2"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${node}" \
    "source /etc/profile >/dev/null 2>&1
     pids=\$(jps -l 2>/dev/null | awk '\$2 ~ /(^|\\.)${process_name}\$/ {print \$1}')
     if [ -z \"\$pids\" ]; then
       pids=\$(ps -eo pid=,args= | awk '\$0 ~ /[j]ava/ && \$0 ~ /(^|[.])${process_name}([[:space:]]|$)/ {print \$1}')
     fi
     printf '%s\\n' \"\$pids\""
}

wait_and_force_stop() {
  local node="$1"
  local process_name="$2"
  local prefix="$3"
  local work_dir="$4"
  local start_time now elapsed pids pid stack_time i

  start_time="$(date +%s)"
  while true; do
    if ! pids="$(remote_pids "${node}" "${process_name}")"; then
      log WARN "节点 ${node} SSH/JPS 检查失败，无法确认 ${process_name} 是否停止"
      return 0
    fi

    if [[ -z "${pids}" ]]; then
      log INFO "节点 ${node}：${process_name} 已停止"
      return 0
    fi

    now="$(date +%s)"
    elapsed=$((now - start_time))
    if ((elapsed > stop_timeout)); then
      log WARN "节点 ${node}：${process_name} 停止超时，准备采集 jstack 并强制结束进程：${pids//$'\n'/ }"
      for pid in ${pids}; do
        for i in 1 2 3; do
          stack_time="$(date +%s)"
          ssh "${os_user_name}@${node}" \
            "source /etc/profile >/dev/null 2>&1; jstack -l ${pid} > '${work_dir}/${prefix}_${stack_time}_stopping_jstack_${i}.out' 2>&1" || true
          sleep 10
        done
      done
      ssh "${os_user_name}@${node}" "kill -9 ${pids//$'\n'/ }" || \
        log WARN "节点 ${node}：强制结束 ${process_name} 失败"
      sleep 2
      if pids="$(remote_pids "${node}" "${process_name}")" && [[ -n "${pids}" ]]; then
        log ERROR "节点 ${node}：强制结束后 ${process_name} 仍存在：${pids//$'\n'/ }"
        return 1
      fi
      return 0
    fi

    sleep 2
  done
}

stop_datanodes() {
  local node pid
  local -a stop_pids=()

  log INFO "开始并行发送 DataNode 停止命令"
  for node in "${nodes[@]}"; do
    log INFO "正在停止 DataNode：${node}"
    ssh "${os_user_name}@${node}" \
      "source /etc/profile >/dev/null 2>&1; '${db_dir}/sbin/stop-datanode.sh'" &
    stop_pids+=("$!")
  done

  for pid in "${stop_pids[@]}"; do
    if ! wait "${pid}"; then
      log WARN "某个 DataNode 停止命令执行失败，将继续通过进程检查处理"
    fi
  done

  for node in "${nodes[@]}"; do
    wait_and_force_stop "${node}" DataNode dn "${db_dir}"
  done
}

stop_confignodes() {
  local node cn_pids

  # CN 确定只会部署在 DataNode 列表中的节点，因此复用同一节点列表扫描。
  for node in "${nodes[@]}"; do
    if ! cn_pids="$(remote_pids "${node}" ConfigNode)"; then
      log WARN "节点 ${node} SSH/JPS 检查失败，跳过 ConfigNode 停止"
      continue
    fi
    [[ -z "${cn_pids}" ]] && continue

    log INFO "节点 ${node} 存在 ConfigNode，正在停止"
    if ! ssh "${os_user_name}@${node}" \
      "source /etc/profile >/dev/null 2>&1; '${cn_db_dir}/sbin/stop-confignode.sh'"; then
      log WARN "节点 ${node} 的 ConfigNode 停止命令执行失败，将继续通过进程检查处理"
    fi
    wait_and_force_stop "${node}" ConfigNode cn "${cn_db_dir}"
  done
}

stop_benchmark() {
  local host pid
  local -a benchmark_hosts=()
  local -a stop_pids=()

  if [[ ! -f "${benchmark_hosts_file}" ]]; then
    log WARN "Benchmark 主机列表不存在，跳过停止 Benchmark：${benchmark_hosts_file}"
    return 0
  fi

  mapfile -t benchmark_hosts < <(load_benchmark_hosts)
  if ((${#benchmark_hosts[@]} == 0)); then
    log WARN "Benchmark 主机列表为空，跳过停止 Benchmark：${benchmark_hosts_file}"
    return 0
  fi

  log INFO "开始并行停止 ${#benchmark_hosts[@]} 台主机上的所有 Benchmark 进程"
  for host in "${benchmark_hosts[@]}"; do
    (
      local benchmark_pids remaining_pids

      if ! benchmark_pids="$(ssh -o BatchMode=yes -o ConnectTimeout=10 \
        "${os_user_name}@${host}" \
        "source /etc/profile >/dev/null 2>&1; jps -l 2>/dev/null | awk '\$2 == \"cn.edu.tsinghua.iot.benchmark.App\" {print \$1}'")"; then
        log WARN "Benchmark 主机 ${host} SSH/JPS 检查失败"
        exit 0
      fi

      if [[ -z "${benchmark_pids}" ]]; then
        log INFO "Benchmark 主机 ${host} 上没有运行中的 Benchmark"
        exit 0
      fi

      log INFO "Benchmark 主机 ${host}：先发送 TERM，进程：${benchmark_pids//$'\n'/ }"
      ssh "${os_user_name}@${host}" "kill ${benchmark_pids//$'\n'/ }" || true
      sleep 5

      remaining_pids="$(ssh -o BatchMode=yes -o ConnectTimeout=10 \
        "${os_user_name}@${host}" \
        "source /etc/profile >/dev/null 2>&1; jps -l 2>/dev/null | awk '\$2 == \"cn.edu.tsinghua.iot.benchmark.App\" {print \$1}'")" || {
          log WARN "Benchmark 主机 ${host} 二次检查失败"
          exit 0
        }

      if [[ -n "${remaining_pids}" ]]; then
        log WARN "Benchmark 主机 ${host}：进程未退出，执行 kill -9：${remaining_pids//$'\n'/ }"
        ssh "${os_user_name}@${host}" "kill -9 ${remaining_pids//$'\n'/ }" || \
          log WARN "Benchmark 主机 ${host} 强制停止失败"
      else
        log INFO "Benchmark 主机 ${host} 上的 Benchmark 已停止"
      fi
    ) &
    stop_pids+=("$!")
  done

  for pid in "${stop_pids[@]}"; do
    wait "${pid}" || true
  done

  log INFO "Benchmark 停止流程完成"
}

main() {
  if [[ ! -f "${node_list_file}" ]]; then
    log ERROR "节点列表不存在：${node_list_file}"
    return 1
  fi
  if [[ -z "${os_user_name}" || -z "${testdb}" || -z "${db_parent_dir}" || -z "${cn_db_parent_dir}" ]]; then
    log ERROR "test.conf 中缺少必要配置"
    return 1
  fi

  mapfile -t nodes < <(load_nodes)
  if ((${#nodes[@]} == 0)); then
    log ERROR "节点列表为空：${node_list_file}"
    return 1
  fi

  stop_datanodes
  stop_confignodes
  stop_benchmark
  log INFO "集群停止流程完成"
}

main "$@"
