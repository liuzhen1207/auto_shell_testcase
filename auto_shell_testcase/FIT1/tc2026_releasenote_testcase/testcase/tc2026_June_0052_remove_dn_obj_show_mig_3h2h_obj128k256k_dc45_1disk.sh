#!/bin/bash
set -uo pipefail

cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
cli_dir=${db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
cn_num=1
dn_num=4
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num+dn_num))
db_sys_admin=root
bm_conn_pw=TimechoDB@2021
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensus"
CSV_FILE=$(grep ^CSV_FILE "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
monitor_url=$(grep '^monitor_url=' "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')

log_file="${cur_dir}/set_conf_parallel.log"
data1_dir="/data1/iotdb_data/${testdb}/data"
data3_dir="/data3/iotdb_data/${testdb}/data"
ssl_str=""
backup_flag=0
backup_log_flag=0

bm_total_runtime_ms=$((4*3600*1000))
bm_trigger_sec=$((3*3600))
bm_delete_before_sec=$((2*3600))
internal_rpc_timeout_ms=360000
bm_start_epoch=0
bm_start_time_str=""
v_remove_dn_cost_sec=0
v_load_balance_cost_sec=0
v_removed_dn_ip=""
v_removed_dn_id=""
data_consistency_failed=0

rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

fail_flag=0
test_begin_sec=$(date +%s)

log() {
    local level=$1
    local msg=$2
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" >> "${log_file}"
    echo "[${timestamp}] [${level}] ${msg}"
}

parse_monitor_query_status() {
  local response_file=$1

  if command -v jq >/dev/null 2>&1; then
    jq -r '.status' "${response_file}" 2>/dev/null
    return $?
  fi

  awk '
    match($0, /"status"[[:space:]]*:[[:space:]]*"[^"]+"/) {
      status = substr($0, RSTART, RLENGTH)
      sub(/.*"status"[[:space:]]*:[[:space:]]*"/, "", status)
      sub(/".*/, "", status)
      print status
      found = 1
      exit 0
    }
    END { exit found ? 0 : 1 }
  ' "${response_file}"
}

count_non_zero_sync_lag() {
  local response_file=$1

  if command -v jq >/dev/null 2>&1; then
    jq -r '.data.result[] | .value[1]' "${response_file}" 2>/dev/null | awk '$1 > 0.0001 {c++} END {print c+0}'
    return $?
  fi

  awk '
    {
      line = $0
      while (match(line, /"value"[[:space:]]*:[[:space:]]*\[[^]]*\]/)) {
        item = substr(line, RSTART, RLENGTH)
        if (match(item, /"[-0-9.]+"/)) {
          value = substr(item, RSTART + 1, RLENGTH - 2) + 0
          if (value > 0.0001) {
            count++
          }
        }
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END { print count + 0 }
  ' "${response_file}"
}

extract_running_datanode_ips() {
  local show_datanodes_file=$1
  local output_file=$2

  awk -F '|' '
    /Running/ {
      for (i = 1; i <= NF; i++) {
        field = $i
        gsub(/^[ \t]+|[ \t]+$/, "", field)
        if (field ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
          print field
          break
        }
      }
    }
  ' "${show_datanodes_file}" | sort -u > "${output_file}"
}

capture_table_region_layout() {
  "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -sql_dialect table -timeout 3600 -e "show regions from usr_sod0;" > "${cur_dir}/show_regions_usr_sod0.out" 2>&1
}

clean_env() {
   log "INFO" "开始清理集群环境..."
   sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/reset_conf.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/clear_cache.sh" >> "${log_file}" 2>&1
   if [ $? -eq 0 ]; then
       log "INFO" "集群环境清理完成"
   else
       log "ERROR" "集群环境清理失败"
   fi
}

configure_confignode() {
    local node_ip=$1
    log "INFO" "开始配置ConfigNode: ${node_ip}"

    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="2G"/g' ${db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${db_dir}/conf/confignode-env.sh

        batch_set_sys_conf() {
            local search_str=\$1
            local content=\$2
            local file="${db_dir}/conf/iotdb-system.properties"
            if grep -q "\$search_str" "\$file"; then
                sed -i "s|\$search_str|\$content|g" "\$file"
            else
                echo "\$content" >> "\$file"
            fi
        }

        batch_set_sys_conf ".*cn_seed_config_node=.*" "cn_seed_config_node=${seed_cn_ip}"
        batch_set_sys_conf ".*cn_internal_address=.*" "cn_internal_address=${node_ip}"
        batch_set_sys_conf ".*cn_metric_reporter_list=.*" "cn_metric_reporter_list=PROMETHEUS"
        batch_set_sys_conf ".*cn_metric_prometheus_reporter_port=.*" "cn_metric_prometheus_reporter_port=9081"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=600000"
        batch_set_sys_conf ".*cn_connection_timeout_ms=.*" "cn_connection_timeout_ms=${internal_rpc_timeout_ms}"
EOF

    if [ $? -eq 0 ]; then
        log "INFO" "ConfigNode ${node_ip} 配置完成"
    else
        log "ERROR" "ConfigNode ${node_ip} 配置失败"
        return 1
    fi
}

configure_datanode() {
    local node_ip=$1
    local bad_disk_ip=""
    if [ -f "${nodeinfo_dir}/datanode_4d.txt" ]; then
        bad_disk_ip=$(tail -1 "${nodeinfo_dir}/datanode_4d.txt" | sed 's/ //g')
    fi
    log "INFO" "开始配置DataNode: ${node_ip} (坏盘节点: ${bad_disk_ip})"

    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="2G"/g' ${db_dir}/conf/datanode-env.sh

        batch_set_sys_conf() {
            local search_str=\$1
            local content=\$2
            local file="${db_dir}/conf/iotdb-system.properties"
            if grep -q "\$search_str" "\$file"; then
                sed -i "s|\$search_str|\$content|g" "\$file"
            else
                echo "\$content" >> "\$file"
            fi
        }

        batch_set_sys_conf ".*dn_seed_config_node=.*" "dn_seed_config_node=${seed_cn_ip}"
        batch_set_sys_conf ".*dn_internal_address=.*" "dn_internal_address=${node_ip}"
        batch_set_sys_conf ".*dn_rpc_address=.*" "dn_rpc_address=${node_ip}"
        batch_set_sys_conf ".*dn_metric_reporter_list=.*" "dn_metric_reporter_list=PROMETHEUS"
        batch_set_sys_conf ".*dn_metric_prometheus_reporter_port=.*" "dn_metric_prometheus_reporter_port=9091"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=600000"
        batch_set_sys_conf ".*dn_connection_timeout_ms=.*" "dn_connection_timeout_ms=${internal_rpc_timeout_ms}"
        batch_set_sys_conf ".*query_timeout_threshold=.*" "query_timeout_threshold=${internal_rpc_timeout_ms}"
EOF

    if [[ -n "${bad_disk_ip}" && "${node_ip}" == "${bad_disk_ip}" ]]; then
        ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
            file="${db_dir}/conf/iotdb-system.properties"
#            sed -i 's|.*dn_data_dirs=.*|dn_data_dirs=data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data|g' \$file
#            sed -i 's|.*dn_wal_dirs=.*|dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal|g' \$file
echo " dn_data_dir default 1disk."
EOF
    else
        ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${db_dir}/conf/datanode-env.sh

            file="${db_dir}/conf/iotdb-system.properties"
#            sed -i 's|.*dn_data_dirs=.*|dn_data_dirs=data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data,/data3/iotdb_data/${testdb}/data/datanode/data|g' \$file
#            sed -i 's|.*dn_wal_dirs=.*|dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal,/data3/iotdb_data/${testdb}/data/datanode/wal|g' \$file
echo " dn_data_dir default 1disk."
EOF
    fi

    if [ $? -eq 0 ]; then
        log "INFO" "DataNode ${node_ip} 配置完成"
    else
        log "ERROR" "DataNode ${node_ip} 配置失败"
        return 1
    fi
}

configure_mixed_node() {
    local node_ip=$1
    log "INFO" "开始配置混合节点（CN+DN）: ${node_ip}"
    configure_confignode "${node_ip}"
    if [ $? -eq 0 ]; then
        configure_datanode "${node_ip}"
    fi
    log "INFO" "混合节点 ${node_ip} 配置完成"
}

set_conf() {
    log "INFO" "开始并行配置所有节点（适配同IP场景）..."

    grep -v '^$' "${nodeinfo_dir}/confignode.txt" | sed 's/ //g' | sort -u > /tmp/cn_ips.tmp
    grep -v '^$' "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sort -u > /tmp/dn_ips.tmp

    cn_ips=()
    while read -r line; do
        if [[ -n "${line}" ]]; then
            cn_ips+=("${line}")
        fi
    done < /tmp/cn_ips.tmp

    dn_ips=()
    while read -r line; do
        if [[ -n "${line}" ]]; then
            dn_ips+=("${line}")
        fi
    done < /tmp/dn_ips.tmp

    mixed_ips=()
    for ip in "${cn_ips[@]}"; do
        if grep -q "^${ip}$" /tmp/dn_ips.tmp; then
            mixed_ips+=("${ip}")
        fi
    done

    only_cn_ips=()
    for ip in "${cn_ips[@]}"; do
        if ! grep -q "^${ip}$" /tmp/dn_ips.tmp; then
            only_cn_ips+=("${ip}")
        fi
    done

    only_dn_ips=()
    for ip in "${dn_ips[@]}"; do
        if ! grep -q "^${ip}$" /tmp/cn_ips.tmp; then
            only_dn_ips+=("${ip}")
        fi
    done

    pids=()

    log "INFO" "启动仅ConfigNode节点并行配置: ${only_cn_ips[*]}"
    for ip in "${only_cn_ips[@]}"; do
        configure_confignode "${ip}" &
        pids+=($!)
    done

    log "INFO" "启动仅DataNode节点并行配置: ${only_dn_ips[*]}"
    for ip in "${only_dn_ips[@]}"; do
        configure_datanode "${ip}" &
        pids+=($!)
    done

    log "INFO" "启动混合节点（CN+DN）并行配置: ${mixed_ips[*]}"
    for ip in "${mixed_ips[@]}"; do
        configure_mixed_node "${ip}" &
        pids+=($!)
    done

    log "INFO" "等待所有节点配置进程完成..."
    for pid in "${pids[@]}"; do
        if wait "${pid}"; then
            log "INFO" "进程PID ${pid} 执行成功"
        else
            log "ERROR" "进程PID ${pid} 执行失败"
        fi
    done

    rm -f /tmp/cn_ips.tmp /tmp/dn_ips.tmp

    if [ ${fail_flag} -eq 0 ]; then
        log "INFO" "所有节点配置完成！日志文件：${log_file}"
    else
        log "ERROR" "部分节点配置失败，请查看日志：${log_file}"
    fi
}

start_db() {
   log "INFO" "开始启动数据库集群..."

   clean_env

   if [ ${fail_flag} -eq 1 ]; then
       log "ERROR" "环境清理失败，终止启动流程"
       exit 1
   fi

   set_conf
   if [ ${fail_flag} -eq 1 ]; then
       log "ERROR" "节点配置失败，终止启动流程"
       exit 1
   fi

   sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1
   if [ $? -eq 0 ]; then
       log "INFO" "集群启动成功"
   else
       log "ERROR" "集群启动失败"
       let fail_flag++
       exit 1
   fi
}

run_cli_sql() {
  local host=$1
  local dialect=$2
  local sql=$3
  local outfile=$4
  local timeout_sec=${5:-3600}

  if [[ "${dialect}" = "table" ]]; then
    "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" ${ssl_str} -h "${host}" -sql_dialect table -timeout "${timeout_sec}" -e "${sql}" > "${outfile}" 2>&1
  else
    "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" ${ssl_str} -h "${host}" -timeout "${timeout_sec}" -e "${sql}" > "${outfile}" 2>&1
  fi
}

create_benchmark_users() {
  run_cli_sql "${query_ip}" tree "CREATE USER santos '${bm_conn_pw}';" "${cur_dir}/create_santos.out" 300
  run_cli_sql "${query_ip}" tree "GRANT READ_SCHEMA,WRITE_SCHEMA,READ_DATA,WRITE_DATA ON root.test.** TO USER santos;" "${cur_dir}/grant_santos_tree.out" 300
  run_cli_sql "${query_ip}" table "GRANT ALL TO USER santos;" "${cur_dir}/grant_santos.out" 300
  run_cli_sql "${query_ip}" tree "CREATE USER rainer '${bm_conn_pw}';" "${cur_dir}/create_rainer.out" 300
  run_cli_sql "${query_ip}" tree "GRANT READ_SCHEMA,WRITE_SCHEMA,READ_DATA,WRITE_DATA ON root.test.** TO USER rainer;" "${cur_dir}/grant_rainer_tree.out" 300
  run_cli_sql "${query_ip}" table "GRANT ALL TO USER rainer;" "${cur_dir}/grant_rainer.out" 300
}

benchmark_is_running() {
  jps | grep App | wc -l
}

start_bm() {
  create_benchmark_users

  bm_dir=${cur_dir}/../benchmark/bm_20260519_writeview_v20
  bm_conf=weather_3h2h_obj128k256k_dc45
  v_bm_test_time=${bm_total_runtime_ms}

  v_20_pass=$(grep ^passwd_param= "${db_dir}/sbin/start-cli.sh" | grep TimechoDB | wc -l)
  if [[ ${v_20_pass} -gt 0 ]]; then
      bm_root_pw="TimechoDB@2021"
  else
      bm_root_pw="root"
  fi

  bm_start_epoch=$(date +%s)
  bm_start_time_str=$(date +"%Y-%m-%dT%H:%M:%S%:z")
  sed -i 's/CREATE_SCHEMA=.*/CREATE_SCHEMA=true/g' ${bm_dir}/${bm_conf}/conf*/config.*
  sed -i "s/START_TIME=.*/START_TIME=${bm_start_time_str}/g" ${bm_dir}/${bm_conf}/conf*/config.*
  sed -i "s/^PASSWORD=.*/PASSWORD=${bm_root_pw}/g" ${bm_dir}/${bm_conf}/conf*/config.properties
  sed -i "s/^TEST_MAX_TIME=.*/TEST_MAX_TIME=${v_bm_test_time}/g" ${bm_dir}/${bm_conf}/conf*/config.properties
  bm_log_dir="${bm_dir}/${testdb}"
  if [ ! -d "${bm_log_dir}" ]; then
      mkdir -p "${bm_log_dir}"
  fi

  t=$(date +%Y_%m_%d_%H_%M_%S)
  nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf_tree >> ${bm_log_dir}/${t}_bm_tree.out &
  nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf_tab1 >> ${bm_log_dir}/${t}_bm_table.out &
  nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf_tab2 >> ${bm_log_dir}/${t}_bm_writable_view.out &
  log "INFO" "benchmark 已启动，开始时间 ${bm_start_time_str}"
}

wait_benchmark_until_3h() {
  while true; do
    local v_bm
    v_bm=$(benchmark_is_running)
    if [[ ${v_bm} -eq 0 ]]; then
      log "WARN" "benchmark 在 2 小时触发点前已退出"
      return 1
    fi

    local now
    now=$(date +%s)
    local elapsed
    elapsed=$((now-bm_start_epoch))
    if [[ ${elapsed} -ge ${bm_trigger_sec} ]]; then
      log "INFO" "benchmark 已运行 ${elapsed}s，达到 2 小时触发点"
      return 0
    fi
    sleep 60
  done
}

delete_first_2h_data() {
  local delete_cutoff_epoch=$((bm_start_epoch+bm_delete_before_sec))
  local delete_cutoff_ms=$((delete_cutoff_epoch*1000))

  log "INFO" "开始删除 benchmark 前 2 小时数据，截止时间戳 ${delete_cutoff_ms}"

  run_cli_sql "${query_ip}" tree "delete from root.test.g_0.** where time <= ${delete_cutoff_ms};" "${cur_dir}/delete_tree_2h.out" 360000
  if grep -Eq "Exception|error|ERROR" "${cur_dir}/delete_tree_2h.out"; then
    let fail_flag++
    v_warnMessage="${v_warnMessage}.delete tree first 2h data failed"
    log "ERROR" "删除树模型前 2 小时数据失败"
    cat "${cur_dir}/delete_tree_2h.out"
  fi

  run_cli_sql "${query_ip}" table "delete from usr_sod0.tab1mb_0 where time <= ${delete_cutoff_ms};" "${cur_dir}/delete_tab1_2h.out" 360000
  if grep -Eq "Exception|error|ERROR" "${cur_dir}/delete_tab1_2h.out"; then
    let fail_flag++
    v_warnMessage="${v_warnMessage}.delete table usr_sod0.tab1mb_0 first 2h data failed"
    log "ERROR" "删除表 usr_sod0.tab1mb_0 前 2 小时数据失败"
    cat "${cur_dir}/delete_tab1_2h.out"
  fi

  run_cli_sql "${query_ip}" table "delete from usr_sod0.writable_view_0 where time <= ${delete_cutoff_ms};" "${cur_dir}/delete_tab2_2h.out" 360000
  if grep -Eq "Exception|error|ERROR" "${cur_dir}/delete_tab2_2h.out"; then
    let fail_flag++
    v_warnMessage="${v_warnMessage}.delete table usr_sod0.writable_view_0 first 2h data failed"
    log "ERROR" "删除表 usr_sod0.writable_view_0 前 2 小时数据失败"
    cat "${cur_dir}/delete_tab2_2h.out"
  fi
}

remove_datanode_once() {
  local rm_dn_ip=$1
  log "INFO" "开始单次缩容 DataNode ${rm_dn_ip}"

  query_ip2=$(tail -1 "${nodeinfo_dir}/datanode.txt")
  v_removed_dn_id=$("${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -e "show datanodes;" | grep "${rm_dn_ip}" | awk -F '|' '{gsub(" ","");print $2}')
  if [[ -z "${v_removed_dn_id}" ]]; then
    let fail_flag++
    v_warnMessage="${v_warnMessage}.can not find datanode id for ${rm_dn_ip}"
    log "ERROR" "未找到 ${rm_dn_ip} 对应的 DataNode ID"
    return 1
  fi

  if [[ ${rm_dn_ip} = ${query_ip} ]]; then
     "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip2}" -sql_dialect table -e "set configuration region_migration_concurrency_limit='10';" > "${cur_dir}/tmp.out"
     v_exp_suc=$(grep successfully "${cur_dir}/tmp.out" | wc -l)
     if [[ ${v_exp_suc} -eq 0 ]]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}.set configuration region_migration_concurrency_limit='10' failed"
        cat "${cur_dir}/tmp.out"
     fi
     "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip2}" -e "remove datanode ${v_removed_dn_id};" >> "${cur_dir}/tmp.out" 2>&1
  else
     "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -e "remove datanode ${v_removed_dn_id};" > "${cur_dir}/tmp.out" 2>&1
  fi

  rm_t1=$(date +%s)
  while true; do
      v_rm_suc=$("${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -e "show datanodes;" | grep "${rm_dn_ip}" | wc -l)
      if [[ ${v_rm_suc} -gt 0 ]]; then
          "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -sql_dialect table -timeout 3600 -e "show migrations;" > "${cur_dir}/tmp.out"
          v_tab_mig_num=$(grep -E "SchemaRegion|DataRegion" "${cur_dir}/tmp.out" | wc -l)
          v_tab_emp_num=$(grep "Empty set" "${cur_dir}/tmp.out" | wc -l)

          "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -sql_dialect tree -timeout 3600 -e "show migrations;" > "${cur_dir}/tmp1.out"
          v_tree_mig_num=$(grep -E "SchemaRegion|DataRegion" "${cur_dir}/tmp1.out" | wc -l)
          v_tree_emp_num=$(grep "Empty set" "${cur_dir}/tmp1.out" | wc -l)
          v_emp_num=$((v_tab_emp_num+v_tree_emp_num))
          v_mig_num=$((v_tab_mig_num+v_tree_mig_num))
          if [[ ${v_mig_num} -eq 0 ]] && [[ ${v_emp_num} -lt 2 ]]; then
              let fail_flag++
              v_warnMessage="${v_warnMessage}.removing dn but show migrations is not expected"
          fi
          sleep 300
      else
          "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -sql_dialect table -timeout 3600 -e "show migrations;" > "${cur_dir}/tmp.out"
          v_tab_mig_num=$(grep -E "SchemaRegion|DataRegion" "${cur_dir}/tmp.out" | wc -l)
          v_tab_emp_num=$(grep "Empty set" "${cur_dir}/tmp.out" | wc -l)

          "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -sql_dialect tree -timeout 3600 -e "show migrations;" > "${cur_dir}/tmp1.out"
          v_tree_mig_num=$(grep -E "SchemaRegion|DataRegion" "${cur_dir}/tmp1.out" | wc -l)
          v_tree_emp_num=$(grep "Empty set" "${cur_dir}/tmp1.out" | wc -l)
          v_emp_num=$((v_tab_emp_num+v_tree_emp_num))
          v_mig_num=$((v_tab_mig_num+v_tree_mig_num))
          if [[ ${v_mig_num} -gt 0 ]] || [[ ${v_emp_num} -lt 2 ]]; then
              let fail_flag++
              v_warnMessage="${v_warnMessage}.remove dn success but show migrations is not expected"
          fi
          break
      fi
  done

  while true; do
      v_rm_dn_pid=$(ssh "${os_user_name}@${rm_dn_ip}" "sudo jps|grep -i datanode|wc -l")
      if [[ ${v_rm_dn_pid} -gt 0 ]]; then
          sleep 60
      else
          break
      fi
  done

  rm_t2=$(date +%s)
  v_remove_dn_cost_sec=$((rm_t2-rm_t1))
  v_removed_dn_ip=${rm_dn_ip}
  log "INFO" "缩容 ${rm_dn_ip} 完成，耗时 ${v_remove_dn_cost_sec}s"
}

add_removed_datanode_back() {
  local rm_dn_ip=$1
  local v_start_time
  v_start_time=$(date +%Y_%m_%d_%H_%M_%S)
  log "INFO" "开始将 ${rm_dn_ip} 加回集群"

  ssh "${os_user_name}@${rm_dn_ip}" "source /etc/profile;cd ${db_dir};sudo ./sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
  local add_t1
  add_t1=$(date +%s)

  while true; do
      v_start_suc=$("${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -e "show datanodes;" | grep "${rm_dn_ip}" | grep -i running | wc -l)
      if [[ ${v_start_suc} -gt 0 ]]; then
          break
      fi
      sleep 30
      local add_t2
      add_t2=$(date +%s)
      if [[ $((add_t2-add_t1)) -gt 1800 ]]; then
          let fail_flag++
          v_warnMessage="${v_warnMessage}.add removed dn ${rm_dn_ip} back timeout"
          log "ERROR" "加回 ${rm_dn_ip} 超时"
          return 1
      fi
  done
  log "INFO" "${rm_dn_ip} 已重新加入集群"
}

wait_load_balance_done() {
  local target_ip=$1

  while true; do
      "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -sql_dialect table -timeout 3600 -e "show migrations;" > "${cur_dir}/load_balance_migrations_table.out" 2>&1
      "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -sql_dialect tree -timeout 3600 -e "show migrations;" > "${cur_dir}/load_balance_migrations_tree.out" 2>&1
      "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -timeout 3600 -e "show regions;" > "${cur_dir}/load_balance_regions.out" 2>&1
      "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -timeout 3600 -e "show datanodes;" > "${cur_dir}/load_balance_datanodes.out" 2>&1

      local v_tab_emp_num
      local v_tree_emp_num
      v_tab_emp_num=$(grep -c "Empty set" "${cur_dir}/load_balance_migrations_table.out")
      v_tree_emp_num=$(grep -c "Empty set" "${cur_dir}/load_balance_migrations_tree.out")

      if [[ ${v_tab_emp_num} -gt 0 ]] && [[ ${v_tree_emp_num} -gt 0 ]]; then
          log "INFO" "LOAD BALANCE 迁移完成，show migrations 已为空，目标节点 ${target_ip}"
          return 0
      fi

      sleep 60
  done
}

run_load_balance_once() {
  local target_ip=$1
  log "INFO" "开始执行 LOAD BALANCE"

  "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -timeout 3600 -sql_dialect table -e "LOAD BALANCE;" > "${cur_dir}/load_balance.out" 2>&1
  if grep -Eq "Exception|error|ERROR|mismatched input|no viable alternative" "${cur_dir}/load_balance.out"; then
      let fail_flag++
      v_warnMessage="${v_warnMessage}.LOAD BALANCE failed"
      log "ERROR" "LOAD BALANCE 提交失败"
      cat "${cur_dir}/load_balance.out"
      return 1
  fi

  local lb_submit_t
  lb_submit_t=$(date +%s)
  log "INFO" "LOAD BALANCE 提交成功，开始监控 show migrations"

  if wait_load_balance_done "${target_ip}"; then
      local lb_t2
      lb_t2=$(date +%s)
      v_load_balance_cost_sec=$((lb_t2-lb_submit_t))
      log "INFO" "LOAD BALANCE 完成，耗时 ${v_load_balance_cost_sec}s"
  else
      let fail_flag++
      v_warnMessage="${v_warnMessage}.LOAD BALANCE timeout"
      log "ERROR" "LOAD BALANCE 等待完成超时"
      return 1
  fi
}

run_mid_benchmark_actions() {
  v_removed_dn_ip=$(tail -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
  if [[ -z "${v_removed_dn_ip}" ]]; then
      let fail_flag++
      v_warnMessage="${v_warnMessage}.can not find datanode for shrink action"
      return 1
  fi

  if ! wait_benchmark_until_3h; then
      return 1
  fi

  delete_first_2h_data
  sleep 5
  remove_datanode_once "${v_removed_dn_ip}" || return 1
  add_removed_datanode_back "${v_removed_dn_ip}" || return 1
  run_load_balance_once "${v_removed_dn_ip}" || return 1
}

wait_benchmark_finish() {
  while true; do
      v_bm=$(benchmark_is_running)
      if [[ ${v_bm} -eq 0 ]]; then
          log "INFO" "benchmark 已到期退出"
          return 0
      fi
      sleep 60
  done
}

wait_sync_done() {
  local max_wait_time=$1
  "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -e "flush;" > "${cur_dir}/tmp.out"
  "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -e "show datanodes;" > "${cur_dir}/tmp.out"
  extract_running_datanode_ips "${cur_dir}/tmp.out" "${cur_dir}/tmp1.out"
  mv "${cur_dir}/tmp1.out" "${cur_dir}/tmp.out"
  exec 3<"${cur_dir}/tmp.out"
  while read line<&3; do
    while true; do
      ssh "${os_user_name}@${line}" "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep db_table" > "${cur_dir}/tmp1.out"
      ssh "${os_user_name}@${line}" "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep root.test" > "${cur_dir}/tmp2.out"
      last_time_str1=$(tail -n 1 "${cur_dir}/tmp1.out" | awk -F',' '{print $1}')
      last_time_str2=$(tail -n 1 "${cur_dir}/tmp2.out" | awk -F',' '{print $1}')
      last_timestamp1=$(date -d "${last_time_str1}" +%s 2>/dev/null)
      last_timestamp2=$(date -d "${last_time_str2}" +%s 2>/dev/null)
      if [[ ${last_timestamp1:-0} -gt ${last_timestamp2:-0} ]]; then
        last_timestamp=${last_timestamp1}
      else
        last_timestamp=${last_timestamp2}
      fi
      current_timestamp=$(date +%s)
      time_diff=$((current_timestamp-last_timestamp))
      if [ ${time_diff} -gt ${max_wait_time} ]; then
          break
      else
          v_sleep=$((max_wait_time-time_diff+1))
          sleep "${v_sleep}"
      fi
    done
  done
}

wait_sync_lag_zero_legacy() {
  local timeout_sec=${1:-3600}
  local t1
  t1=$(date +%s)
  log "INFO" "开始等待 sync lag 为 0"

  while true; do
    "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -e "show datanodes;" > "${cur_dir}/sync_lag_dn.out"
    extract_running_datanode_ips "${cur_dir}/sync_lag_dn.out" "${cur_dir}/sync_lag_dn_ips.out"

    local all_zero=1
    local found_metric=0
    exec 4<"${cur_dir}/sync_lag_dn_ips.out"
    while read dn_ip<&4; do
      [ -z "${dn_ip}" ] && continue
      ssh "${os_user_name}@${dn_ip}" "if command -v curl >/dev/null 2>&1; then curl -s http://127.0.0.1:9091/metrics; elif command -v wget >/dev/null 2>&1; then wget -qO- http://127.0.0.1:9091/metrics; fi" 2>/dev/null | grep -Ei 'sync.*lag' | grep -v '^#' > "${cur_dir}/sync_lag_${dn_ip}.out"
      if [ -s "${cur_dir}/sync_lag_${dn_ip}.out" ]; then
        found_metric=1
        awk '{print $NF}' "${cur_dir}/sync_lag_${dn_ip}.out" > "${cur_dir}/sync_lag_${dn_ip}.val"
        if ! awk 'BEGIN{ok=1} {if (($1+0) != 0) ok=0} END{exit ok?0:1}' "${cur_dir}/sync_lag_${dn_ip}.val"; then
          all_zero=0
        fi
      fi
    done

    if [[ ${found_metric} -eq 1 && ${all_zero} -eq 1 ]]; then
      log "INFO" "sync lag 已为 0"
      return 0
    fi

    local t2
    t2=$(date +%s)
    if [[ $((t2-t1)) -gt ${timeout_sec} ]]; then
      let fail_flag++
      if [[ ${found_metric} -eq 0 ]]; then
        v_warnMessage="${v_warnMessage}.sync lag metric not found"
      else
        v_warnMessage="${v_warnMessage}.sync lag is not zero after benchmark"
      fi
      log "ERROR" "等待 sync lag 为 0 超时"
      return 1
    fi
    sleep 60
  done
}

check_dn_jps() {
   local v_dn_ip=$1
   local max_wait_time=$2
   local t1
   t1=$(date +%s)
   while true; do
      v_dn_str=$(ssh "${os_user_name}@${v_dn_ip}" "sudo jps|grep DataNode" 2>/dev/null)
      v_dn_pid=$(echo "${v_dn_str}" | awk '{print $1}')
      if [[ -n "${v_dn_pid}" ]]; then
         sleep 5
      else
         break
      fi

      t2=$(date +%s)
      t_elp=$((t2-t1))
      if [[ ${t_elp} -gt ${max_wait_time} ]]; then
         let fail_flag++
         echo "Stopping takes too long."
         ssh "${os_user_name}@${v_dn_ip}" "sudo kill -9 ${v_dn_pid}"
         break
      fi
   done
}

check_data_consistent() {
   wait_sync_done 180
   "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -e "show datanodes;" > "${cur_dir}/tmp.out"
   extract_running_datanode_ips "${cur_dir}/tmp.out" "${cur_dir}/tmp1.out"
   mv "${cur_dir}/tmp1.out" "${cur_dir}/tmp.out"
   sql1="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9),count(s_10),count(s_11) from root.test.g_0.** align by device;"
   sql2="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9),count(s_10),count(s_11) from usr_sod0.tab1mb_0 group by device_id order by device_id;"
   sql3="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9),count(s_10),count(s_11) from usr_sod0.writable_view_0 group by device_id order by device_id;"
   sql4="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9),count(s_10),count(s_11) from usr_sod0.writable_view_0_v group by device_id order by device_id;"

   while true; do
     "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -sql_dialect tree -timeout 36000 -e "${sql1}" > "${cur_dir}/q_all_online_tree.out"
     v_exception_num=$(grep Exception "${cur_dir}/q_all_online_tree.out" | wc -l)
     if [[ ${v_exception_num} -eq 0 ]]; then
       break
     fi
     sleep 1
   done

   while true; do
     "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -sql_dialect table -timeout 36000 -e "${sql2}" > "${cur_dir}/q_all_online_table2.out"
     "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -sql_dialect table -timeout 36000 -e "${sql3}" > "${cur_dir}/q_all_online_table3.out"
     "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -sql_dialect table -timeout 36000 -e "${sql4}" > "${cur_dir}/q_all_online_table4.out"
     v_exception_num2=$(grep Exception "${cur_dir}/q_all_online_table2.out" | wc -l)
     v_exception_num3=$(grep Exception "${cur_dir}/q_all_online_table3.out" | wc -l)
     v_exception_num4=$(grep Exception "${cur_dir}/q_all_online_table4.out" | wc -l)
     v_exception_num=$((v_exception_num2+v_exception_num3+v_exception_num4))
     if [[ ${v_exception_num} -eq 0 ]]; then
       break
     fi
     sleep 1
   done

   exec 3<"${cur_dir}/tmp.out"
   while read line<&3; do
      query_ip=$(head -1 "${cur_dir}/tmp.out")
      query_ip2=$(tail -1 "${cur_dir}/tmp.out")

      ssh "${os_user_name}@${line}" "source /etc/profile;cd ${db_dir};sudo ./sbin/stop-datanode.sh"
      check_dn_jps "${line}" 120
      if [[ ${query_ip} = ${line} ]]; then
         query_ip=${query_ip2}
      fi

      v_ip=$(echo "${line}" | awk -F '.' '{print $4}')
      while true; do
        "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -sql_dialect tree -timeout 36000 -e "${sql1}" > "${cur_dir}/q_stop_ip${v_ip}_tree.out"
        v_exception_num=$(grep Exception "${cur_dir}/q_stop_ip${v_ip}_tree.out" | wc -l)
        if [[ ${v_exception_num} -eq 0 ]]; then
          break
        fi
        sleep 1
      done

      while true; do
        "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -sql_dialect table -timeout 36000 -e "${sql2}" > "${cur_dir}/q_stop_ip${v_ip}_table2.out"
        "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -sql_dialect table -timeout 36000 -e "${sql3}" > "${cur_dir}/q_stop_ip${v_ip}_table3.out"
        "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${query_ip}" -sql_dialect table -timeout 36000 -e "${sql4}" > "${cur_dir}/q_stop_ip${v_ip}_table4.out"
        v_exception_num2=$(grep Exception "${cur_dir}/q_stop_ip${v_ip}_table2.out" | wc -l)
        v_exception_num3=$(grep Exception "${cur_dir}/q_stop_ip${v_ip}_table3.out" | wc -l)
        v_exception_num4=$(grep Exception "${cur_dir}/q_stop_ip${v_ip}_table4.out" | wc -l)
        v_exception_num=$((v_exception_num2+v_exception_num3+v_exception_num4))
        if [[ ${v_exception_num} -eq 0 ]]; then
          break
        fi
        sleep 1
      done

      v_diff_tree=$(diff "${cur_dir}/q_all_online_tree.out" "${cur_dir}/q_stop_ip${v_ip}_tree.out" | grep "root" | wc -l)
      v_diff_table2=$(diff "${cur_dir}/q_all_online_table2.out" "${cur_dir}/q_stop_ip${v_ip}_table2.out" | grep "d_" | wc -l)
      v_diff_table3=$(diff "${cur_dir}/q_all_online_table3.out" "${cur_dir}/q_stop_ip${v_ip}_table3.out" | grep "d_" | wc -l)
      v_diff_table4=$(diff "${cur_dir}/q_all_online_table4.out" "${cur_dir}/q_stop_ip${v_ip}_table4.out" | grep "d_" | wc -l)
      v_diff_total=$((v_diff_tree+v_diff_table2+v_diff_table3+v_diff_table4))
      if [[ ${v_diff_total} -gt 0 ]]; then
         let fail_flag++
         let backup_flag++
         data_consistency_failed=1
         diff "${cur_dir}/q_all_online_tree.out" "${cur_dir}/q_stop_ip${v_ip}_tree.out"
         diff "${cur_dir}/q_all_online_table2.out" "${cur_dir}/q_stop_ip${v_ip}_table2.out"
         diff "${cur_dir}/q_all_online_table3.out" "${cur_dir}/q_stop_ip${v_ip}_table3.out"
         diff "${cur_dir}/q_all_online_table4.out" "${cur_dir}/q_stop_ip${v_ip}_table4.out"
         v_warnMessage="${v_warnMessage}.replica data inconsistent on ${line}"
         echo "diff : ${v_diff_total}"
      fi

      v_start_time=$(date +%s)
      ssh "${os_user_name}@${line}" "source /etc/profile;cd ${db_dir};sudo ./sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
      while true; do
        v_start_ok=$("${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" -pw "${bm_conn_pw}" ${ssl_str} -h "${line}" -timeout 3600 -e "show datanodes;" | grep "${line}|" | grep Running | wc -l)
        if [[ ${v_start_ok} -gt 0 ]]; then
          break
        fi
        sleep 1
        v_cur_time=$(date +%s)
        v_elp_time=$((v_cur_time-v_start_time))
        if [[ ${v_elp_time} -gt 180 ]]; then
           let fail_flag++
           echo "restart ${line} failed."
           return 1
        fi
      done
   done

   if [[ ${data_consistency_failed} -gt 0 ]]; then
      log "ERROR" "检测到副本数据不一致，停止集群并检查日志"
      sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
      check_log
      return 1
   fi
}

check_log() {
  exec 3<"${nodeinfo_dir}/confignode.txt"
  while read line<&3; do
     ssh "${os_user_name}@${line}" "sudo gunzip -f ${db_dir}/logs/*confignode*all*.gz >/dev/null 2>&1 || true"
     v_npe=$(ssh "${os_user_name}@${line}" "grep NullPointer ${db_dir}/logs/*confignode*all*|wc -l")
     if [[ ${v_npe} -gt 0 ]]; then
         let fail_flag++
         let backup_log_flag++
         v_warnMessage="${v_warnMessage}CN ${line} NPE ${v_npe}."
         echo "CN ${line} NullPointer : ${v_npe}"
     fi
  done

  exec 3<"${nodeinfo_dir}/datanode.txt"
  while read line<&3; do
     ssh "${os_user_name}@${line}" "sudo gunzip -f ${db_dir}/logs/*datanode*all*.gz >/dev/null 2>&1 || true"
     v_npe=$(ssh "${os_user_name}@${line}" "grep NullPointer ${db_dir}/logs/*datanode*all*|wc -l")
     v_err=$(ssh "${os_user_name}@${line}" "grep CompactionTableSchemaNotMatchException ${db_dir}/logs/*datanode*all*|wc -l")
     v_err2=$(ssh "${os_user_name}@${line}" "grep \"has overlapped data\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err3=$(ssh "${os_user_name}@${line}" "grep \"which should be later than the last time\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err4=$(ssh "${os_user_name}@${line}" "grep \"Failed to statistic the size of\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err17=$(ssh "${os_user_name}@${line}" "grep \"DataTypeInconsistentException\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err5=$(ssh "${os_user_name}@${line}" "grep \"ArrayIndexOutOfBoundsException\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err6=$(ssh "${os_user_name}@${line}" "grep \"Alter timeseries .* data type from null to\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err7=$(ssh "${os_user_name}@${line}" "grep \"StatisticsClassException\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err8=$(ssh "${os_user_name}@${line}" "grep \"BufferUnderflowException\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err9=$(ssh "${os_user_name}@${line}" "grep \"NegativeArraySizeException\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err10=$(ssh "${os_user_name}@${line}" "grep \"is not in tsFileMetaData\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err11=$(ssh "${os_user_name}@${line}" "grep \"The memory cost to be released is larger\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err12=$(ssh "${os_user_name}@${line}" "grep \"tsfile error\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err13=$(ssh "${os_user_name}@${line}" "grep \"which has not released all memory\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err14=$(ssh "${os_user_name}@${line}" "grep \"Error while reading timeseries metadata\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err15=$(ssh "${os_user_name}@${line}" "grep \"OBJECT statistics does not support: last\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err16=$(ssh "${os_user_name}@${line}" "grep \"which has not released all memory\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err18=$(ssh "${os_user_name}@${line}" "grep INTERNAL_SERVER_ERROR ${db_dir}/logs/*datanode*all*|wc -l")
     v_err19=$(ssh "${os_user_name}@${line}" "grep \"Cannot create link from\" ${db_dir}/logs/*datanode*all*|wc -l")
     v_err_total=$((v_err+v_err2+v_err3+v_err4+v_err5+v_err6+v_err7+v_err8+v_err9+v_err10+v_err11+v_err12+v_err13+v_err14+v_err15+v_err16+v_err17+v_err18+v_err19))
     if [[ ${v_err_total} -gt 0 ]]; then
         let fail_flag++
         let backup_log_flag++
         v_warnMessage="${v_warnMessage}DN ${line} unexpected log ${v_err_total}."
         echo "DN ${line} unexpected log count : ${v_err_total}"
     fi
     if [[ ${v_npe} -gt 0 ]]; then
         let fail_flag++
         let backup_log_flag++
         v_warnMessage="${v_warnMessage}DN ${line} NPE ${v_npe}."
         echo "DN ${line} NPE count : ${v_npe}"
     fi

  done
}

wait_sync_lag_zero() {
  local max_wait_seconds=${1:-3600}
  local target_duration=${2:-120}
  local prometheus_user=admin
  local prometheus_pass=admin
  local sleep_interval=30
  local metric_name="iot_consensus"
  local server_name="ioTConsensusServerImpl"
  local wait_start_time
  local zero_start_time=0
  local expected_count=0
  local instance_regex=""
  local ip

  if [[ -z "${monitor_url}" ]]; then
    let fail_flag++
    v_warnMessage="${v_warnMessage}.monitor_url is empty in ${conf_file}"
    log "ERROR" "monitor_url 未配置，无法查询 sync lag"
    return 1
  fi

  if [[ "${v_consensus}" == "IoTConsensusV2" ]]; then
    metric_name="iot_consensus_v2"
    server_name="IoTConsensusV2ServerImpl"
  fi

  wait_start_time=$(date +%s)
  log "INFO" "开始通过 ${monitor_url} 等待 sync lag 为 0"

  "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${bm_conn_pw}" -h "${query_ip}" -e "show datanodes;" > "${cur_dir}/sync_lag_dn.out"
  extract_running_datanode_ips "${cur_dir}/sync_lag_dn.out" "${cur_dir}/sync_lag_dn_ips.out"

  while read -r ip
  do
    [[ -z "${ip}" ]] && continue
    expected_count=$((expected_count + 1))
    [[ -n "${instance_regex}" ]] && instance_regex="${instance_regex}|"
    instance_regex="${instance_regex}${ip//./[.]}(:[0-9]+)?"
  done < "${cur_dir}/sync_lag_dn_ips.out"

  if [[ ${expected_count} -eq 0 ]]; then
    let fail_flag++
    v_warnMessage="${v_warnMessage}.no running datanodes found while waiting sync lag"
    log "ERROR" "等待 sync lag 时未找到 Running 状态的 DataNode"
    return 1
  fi
  instance_regex="^(${instance_regex})$"

  while true
  do
    local now
    local query
    local response
    local response_file="${cur_dir}/sync_lag_response.json"
    local response_status=""
    local parse_rc=0
    local non_zero_num

    now=$(date +%s)
    if (( now - wait_start_time > max_wait_seconds )); then
      let fail_flag++
      v_warnMessage="${v_warnMessage}.sync lag did not become zero within ${max_wait_seconds}s"
      log "ERROR" "等待 sync lag 为 0 超时"
      return 1
    fi

    query="sum(${metric_name}{instance=~\"${instance_regex}\",name=\"${server_name}\",type=\"syncLag\"}) by (instance)"
    response=$(curl -s -u "${prometheus_user}:${prometheus_pass}" --get --data-urlencode "query=${query}" "${monitor_url}/api/v1/query")
    printf '%s\n' "${response}" > "${response_file}"

    response_status=$(parse_monitor_query_status "${response_file}")
    parse_rc=$?
    if [[ ${parse_rc} -ne 0 || "${response_status}" != "success" ]]; then
      zero_start_time=0
      sleep "${sleep_interval}"
      continue
    fi

    non_zero_num=$(count_non_zero_sync_lag "${response_file}")
    parse_rc=$?
    if [[ ${parse_rc} -ne 0 ]]; then
      zero_start_time=0
      sleep "${sleep_interval}"
      continue
    fi

    if [[ ${non_zero_num} -gt 0 ]]; then
      zero_start_time=0
    else
      if [[ ${zero_start_time} -eq 0 ]]; then
        zero_start_time=${now}
      fi
      if (( now - zero_start_time >= target_duration )); then
        log "INFO" "sync lag 已连续 ${target_duration}s 为 0"
        return 0
      fi
    fi
    sleep "${sleep_interval}"
  done
}

testcase1() {
  wait_sync_lag_zero 36000
  sleep 300
  capture_table_region_layout
  check_data_consistent
  if [[ ${data_consistency_failed} -eq 0 ]]; then
    check_log
  fi

  if [[ ${backup_flag} -gt 0 ]]; then
      v_backup_time=$(date +%s)
      sh -x "${clean_env_dir}/stop_cluster.sh" 2>&1
      sh -x "${clean_env_dir}/backup_cluster_logs.sh" "${v_backup_time}" 2>&1
#      sh -x "${clean_env_dir}/backup_cluster_logs_data.sh" "${v_backup_time}" 2>&1
  fi
      v_backup_time=$(date +%s)
      sh -x "${clean_env_dir}/stop_cluster.sh" 2>&1
      sh -x "${clean_env_dir}/backup_cluster_logs.sh" "${v_backup_time}" 2>&1
}

write_result() {
  test_time=$(date +"%Y-%m-%dT%H:%M:%S.%3N%:z")
  v_bm_sum_value=$(grep "Test elapsed" ${bm_log_dir}/${t}_bm*out | awk '{print $8}' | sort -n | awk '{sum+=$1} END {print sum}')
  v_bm_max_value=$(grep "Test elapsed" ${bm_log_dir}/${t}_bm*out | awk '{print $8}' | sort -n | tail -1)
  v_exist_flag=$(grep "Time,testTimechoDB" "${CSV_FILE}" | wc -l)
  if [[ ${v_exist_flag} -eq 0 ]]; then
      echo "Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage,maxBMTestTimeSec,sumBMTestTimeSec" > "${CSV_FILE}"
  fi
  if [[ ${fail_flag} -gt 0 ]]; then
      echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},FAIL,${v_elp_time},${v_warnNum},${v_warnMessage},${v_bm_max_value},${v_bm_sum_value}" >> "${CSV_FILE}"
      echo "testcase1 fail"
  else
      echo "testcase1 pass"
      echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},PASS,${v_elp_time},${v_warnNum},${v_warnMessage},${v_bm_max_value},${v_bm_sum_value}" >> "${CSV_FILE}"
  fi
}

echo "" > "${log_file}"
start_db
v_start_test_time=$(date +%s)
start_bm
run_mid_benchmark_actions
wait_benchmark_finish
testcase1
v_end_test_time=$(date +%s)
v_elp_time=$((v_end_test_time-v_start_test_time))
write_result
