#!/bin/bash
set -uo pipefail
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
current_dir=${cur_dir}
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

# 读取配置文件（去空格，兼容低版本）
os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
os_name=${os_user_name}
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
shell_client_db_parent_dir=$(grep "^v_shell_client_db_parent_dir=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
cli_dir=${shell_client_db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
cn_db_parent_dir=`cat ${conf_file}|grep ^v_cn_db_parent_dir|awk -F '=' '{print $2}'`
cn_db_dir=${cn_db_parent_dir}/${testdb}
remote_cli_os_user=$(grep "^remote_cli_os_user=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
remote_cli_ip=$(grep "^remote_cli_ip=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
bm1_ip=$(grep "^bm1_ip=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
bm2_ip=$(grep "^bm2_ip=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
bm_dir=$(grep "^bm_dir=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
this_shell_ip=$(grep "^this_shell_ip=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
CLUSTER_ID=$(grep ^CLUSTER_NAME "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
cn_num=5
dn_num=20
v_cluster_num_info="${cn_num}C${dn_num}D"
dr_rep_num=3
sr_rep_num=5
total_node_num=$((cn_num+dn_num))
node_num=${total_node_num}
log_file="${cur_dir}/set_conf_parallel.log"
removed_data_record="${cur_dir}/removed_data_dir.txt"
rm -f "${removed_data_record}"
ssl_str=""
backup_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensus"
v_sec_super_user="root"
v_sys_super_user="root"
v_remove_cn_id=-1
v_remove_dn_id=-1
v_shutdown_ip1=""
cancel_after_remove_sec=60
cancel_wait_timeout_sec=43200
cancel_wait_poll_sec=30
cancel_cmd_timeout_sec=10
snapshot_cleanup_timeout_sec=900
snapshot_cleanup_poll_sec=10
snapshot_cleanup_stale_sec=180
v_cancel_submit_ts=0
v_cancel_actual_elapsed_sec=-1
v_cancel_all_drained_elapsed_sec=0
v_cancel_migration_count_before=0
v_cancelable_migration_count_before=0
v_cancel_target_region_count=0
v_cancel_target_removing_count=0
v_cancel_all_target_regions_removing=0
v_cancelable_procedure_ids_file="${cur_dir}/cancelable_procedure_ids.out"
v_receiver_file="${cur_dir}/cancel_receiver_regions.out"
ha_drop_db="ha_drop_db"
ha_keep_db="ha_keep_sod0"
ha_bm_prefix=""
ha_bm_runtime_dir=""
ha_benchmark_started=0
ha_fault_ips_file="${cur_dir}/ha_fault_ips.out"
ha_killed_ips_file="${cur_dir}/ha_killed_ips.out"
ha_query_ip=""
ha_drop_timeout_sec=180
ha_cleanup_timeout_sec=600
# 清理旧节点文件，复制新配置
rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

# 读取种子节点IP（兼容低版本）
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
query_ip2=$(tail -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
ha_query_ip="${query_ip}"
v_new_cn_ip=$(sed -n "7p" "${nodeinfo_dir}/datanode.txt")
v_new_cn_leader_ip=${query_ip}
fail_flag=0
sum_fail_flag=0
sync_fail_flag=0

# ===================== 工具函数 =====================
# 日志输出函数（带时间戳）
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" >> "${log_file}"
    echo "[${timestamp}] [${level}] ${msg}"
}

# 清理环境函数
clean_env() {
   log "INFO" "开始清理集群环境..."
   local cleanup_failed=0
   sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
   sh -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
   sh -x "${clean_env_dir}/reset_conf.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
   sh -x "${clean_env_dir}/clear_cache.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
   if [ ${cleanup_failed} -eq 0 ]; then
       log "INFO" "集群环境清理完成"
   else
       let fail_flag++
       log "ERROR" "集群环境清理失败"
   fi
}

# 单个ConfigNode配置函数
configure_confignode() {
    local node_ip=$1
    log "INFO" "开始配置ConfigNode: ${node_ip}"
    
    # 整合所有ConfigNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="4G"/g' ${cn_db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${cn_db_dir}/conf/confignode-env.sh
        
        # 定义批量修改system.properties的函数
        batch_set_sys_conf() {
            local search_str=\$1
            local content=\$2
            local file="${cn_db_dir}/conf/iotdb-system.properties"
            if grep -q "\$search_str" "\$file"; then
                sed -i "s|\$search_str|\$content|g" "\$file"
            else
                echo "\$content" >> "\$file"
            fi
        }

        # 批量执行system.properties配置
        batch_set_sys_conf ".*cn_seed_config_node=.*" "cn_seed_config_node=${seed_cn_ip}"
        batch_set_sys_conf ".*cn_internal_address=.*" "cn_internal_address=${node_ip}"
        batch_set_sys_conf ".*cn_metric_reporter_list=.*" "cn_metric_reporter_list=PROMETHEUS"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=true"
        batch_set_sys_conf ".*auditable_query_event_type=.*" "auditable_query_event_type=SLOW_OPERATION"
        batch_set_sys_conf ".*auditable_operation_type=.*" "auditable_operation_type=QUERY"
        batch_set_sys_conf ".*query_cost_stat_window=.*" "query_cost_stat_window=5"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
        batch_set_sys_conf ".*region_migration_speed_limit_bytes_per_second=.*" "region_migration_speed_limit_bytes_per_second=150994944"
EOF

    if [ $? -eq 0 ]; then
        log "INFO" "ConfigNode ${node_ip} 配置完成"
    else
        log "ERROR" "ConfigNode ${node_ip} 配置失败"
        return 1
    fi
}

# 单个DataNode配置函数
configure_datanode() {
    local node_ip=$1
    # 读取坏盘节点IP（兼容文件不存在）

    # 整合所有DataNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="48G"/g' ${db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${db_dir}/conf/datanode-env.sh
        
        # 定义批量修改函数
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

        # 通用DataNode配置
        batch_set_sys_conf ".*dn_seed_config_node=.*" "dn_seed_config_node=${seed_cn_ip}"
        batch_set_sys_conf ".*dn_internal_address=.*" "dn_internal_address=${node_ip}"
        batch_set_sys_conf ".*dn_rpc_address=.*" "dn_rpc_address=${node_ip}"
        batch_set_sys_conf ".*dn_metric_reporter_list=.*" "dn_metric_reporter_list=PROMETHEUS"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=true"
        batch_set_sys_conf ".*auditable_query_event_type=.*" "auditable_query_event_type=SLOW_OPERATION"
        batch_set_sys_conf ".*auditable_operation_type=.*" "auditable_operation_type=QUERY"
        batch_set_sys_conf ".*query_cost_stat_window=.*" "query_cost_stat_window=5"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
        batch_set_sys_conf ".*region_migration_speed_limit_bytes_per_second=.*" "region_migration_speed_limit_bytes_per_second=150994944"


EOF

    if [ $? -eq 0 ]; then
        log "INFO" "DataNode ${node_ip} 配置完成"
    else
        log "ERROR" "DataNode ${node_ip} 配置失败"
        return 1
    fi
}

# 混合节点配置函数
configure_mixed_node() {
    local node_ip=$1
    log "INFO" "开始配置混合节点（CN+DN）: ${node_ip}"
    configure_confignode "${node_ip}"
    if [ $? -eq 0 ]; then
        configure_datanode "${node_ip}"
    fi
    log "INFO" "混合节点 ${node_ip} 配置完成"
}

# ===================== 主配置函数（完全兼容低版本Bash） =====================
set_conf() {
    log "INFO" "开始并行配置所有节点（适配同IP场景）..."

    # -------------------- 步骤1：用临时文件读取节点IP（替代进程替换） --------------------
    # 生成去重的CN IP临时文件
    grep -v '^$' "${nodeinfo_dir}/confignode.txt" | sed 's/ //g' | sort -u > /tmp/cn_ips.tmp
    # 生成去重的DN IP临时文件
    grep -v '^$' "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sort -u > /tmp/dn_ips.tmp

    # 读取CN IP列表（低版本Bash兼容）
    cn_ips=()
    while read -r line; do
        if [[ -n "${line}" ]]; then
            cn_ips+=("${line}")
        fi
    done < /tmp/cn_ips.tmp

    # 读取DN IP列表（低版本Bash兼容）
    dn_ips=()
    while read -r line; do
        if [[ -n "${line}" ]]; then
            dn_ips+=("${line}")
        fi
    done < /tmp/dn_ips.tmp

    # -------------------- 步骤2：分类节点IP --------------------
    # 找出混合节点（交集）
    mixed_ips=()
    for ip in "${cn_ips[@]}"; do
        # 低版本Bash兼容的字符串包含判断
        if grep -q "^${ip}$" /tmp/dn_ips.tmp; then
            mixed_ips+=("${ip}")
        fi
    done

    # 找出仅CN的IP
    only_cn_ips=()
    for ip in "${cn_ips[@]}"; do
        if ! grep -q "^${ip}$" /tmp/dn_ips.tmp; then
            only_cn_ips+=("${ip}")
        fi
    done

    # 找出仅DN的IP
    only_dn_ips=()
    for ip in "${dn_ips[@]}"; do
        if ! grep -q "^${ip}$" /tmp/cn_ips.tmp; then
            only_dn_ips+=("${ip}")
        fi
    done

    # -------------------- 步骤3：并行配置节点 --------------------
    pids=()

    # 配置仅CN节点
    log "INFO" "启动仅ConfigNode节点并行配置: ${only_cn_ips[*]}"
    for ip in "${only_cn_ips[@]}"; do
        configure_confignode "${ip}" &
        pids+=($!)
    done

    # 配置仅DN节点
    log "INFO" "启动仅DataNode节点并行配置: ${only_dn_ips[*]}"
    for ip in "${only_dn_ips[@]}"; do
        configure_datanode "${ip}" &
        pids+=($!)
    done

# 配置混合节点（新增空值判断）
if [ ${#mixed_ips[@]} -gt 0 ]; then
    log "INFO" "启动混合节点（CN+DN）并行配置: ${mixed_ips[*]}"
    for ip in "${mixed_ips[@]}"; do
        configure_mixed_node "${ip}" &
        pids+=($!)
    done
else
    log "INFO" "未检测到混合节点（CN+DN），跳过混合节点配置"
fi

    # -------------------- 步骤4：等待所有进程完成 --------------------
    log "INFO" "等待所有节点配置进程完成..."
    for pid in "${pids[@]}"; do
        if wait "${pid}"; then
            log "INFO" "进程PID ${pid} 执行成功"
        else
            let fail_flag++
            log "ERROR" "进程PID ${pid} 执行失败"
        fi
    done

    # 清理临时文件
    rm -f /tmp/cn_ips.tmp /tmp/dn_ips.tmp

    if [ ${fail_flag} -eq 0 ]; then
        log "INFO" "所有节点配置完成！日志文件：${log_file}"
    else
        log "ERROR" "部分节点配置失败，请查看日志：${log_file}"
    fi
}

# 启动数据库集群函数
start_db() {
   log "INFO" "开始启动数据库集群..."
   # 清理环境
clean_env
   if [ ${fail_flag} -gt 0 ]; then
       log "ERROR" "环境清理失败，终止启动流程"
#       exit 1
   fi

   # 配置节点
   set_conf
   if [ ${fail_flag} -gt 0 ]; then
       log "ERROR" "节点配置失败，终止启动流程"
       exit 1
   fi
   
   # 启动集群
   sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1
   if [ $? -eq 0 ]; then
       log "INFO" "集群启动成功"
   else
       log "ERROR" "集群启动失败"
       let fail_flag++
       exit 1
   fi
}
function check_res()
{
   exp_res=$1
   exp_num=$2
   tc_desc=$3
   v_act_num=`cat ${cur_dir}/tmp.out|grep "${exp_res}"|wc -l`
   if [[ ${v_act_num} = ${exp_num} ]];then
      echo "${tc_desc} PASS."
   else
      echo "${tc_desc} FAIL."
      let fail_flag++
      v_warnMessage="${v_warnMessage}${tc_desc} failed."

      cat ${cur_dir}/tmp.out
      echo "${v_warnMessage}"
      exit -1
   fi
}
function check_log()
{
exec 3<${nodeinfo_dir}/confignode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "gunzip ${db_dir}/logs/*confignode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err1=`ssh ${os_user_name}@${line} "grep BufferUnderflowException ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err2=`ssh ${os_user_name}@${line} "grep \"but return HAS_MORE_STATE\" ${db_dir}/logs/*confignode*all*|wc -l"`
   if [[ ${v_npe} -gt 0 ]];then
	   let fail_flag++
           v_warnMessage="${v_warnMessage}CN NPE."
	   echo "CN ${line} NullPointer : ${v_npe}"
   fi
   v_cn_err_total=$((v_cn_err1+v_cn_err2))
   if [[ ${v_cn_err_total} -gt 0 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}CN HAS_MORE_STATE."
           echo "CN ${line} has error: ${v_npe}"
   fi
done

exec 3<${nodeinfo_dir}/datanode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "gunzip ${db_dir}/logs/*datanode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err=`ssh ${os_user_name}@${line} "grep CompactionTableSchemaNotMatchException ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err2=`ssh ${os_user_name}@${line} "grep \"has overlapped data\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err3=`ssh ${os_user_name}@${line} "grep \"which should be later than the last time\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err4=`ssh ${os_user_name}@${line} "grep \"DataTypeInconsistentException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err5=`ssh ${os_user_name}@${line} "grep -E \"ArrayIndexOutOfBoundsException|IndexOutOfBoundsException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err6=`ssh ${os_user_name}@${line} "grep \"Alter timeseries .* data type from null to\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err7=`ssh ${os_user_name}@${line} "grep \"StatisticsClassException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err8=`ssh ${os_user_name}@${line} "grep \"BufferUnderflowException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err9=`ssh ${os_user_name}@${line} "grep \"NegativeArraySizeException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err10=`ssh ${os_user_name}@${line} "grep \"is not in tsFileMetaData\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err11=`ssh ${os_user_name}@${line} "grep \"The memory cost to be released is larger\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_dn_total_err=$((v_err+v_err2+v_err3+v_err4+v_err5+v_err6+v_err7+v_err8+v_err9+v_err10+v_err11))
   if [[ ${v_npe} -gt 0 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}DN NPE."
           echo "DN ${line} NullPointer : ${v_npe}"
   fi
   if [[ ${v_dn_total_err} -gt 0 ]];then
	   let fail_flag++
           v_warnMessage="${v_warnMessage}DN unexp log."
	   echo "DN ${line} has error: ${v_dn_total_err}"
   fi
done

}
function wait_logs_sync_done()
{
local max_wait_time=${1:-120}
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "flush;">${cur_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">${cur_dir}/tmp.out
   cat ${cur_dir}/tmp.out |grep Running|awk -F "|" '{gsub(" ","");print $4}'>${cur_dir}/tmp1.out
   mv ${cur_dir}/tmp1.out ${cur_dir}/tmp.out
   exec 3<${cur_dir}/tmp.out
   while read line<&3
   do
   while true
   do
   ssh ${os_user_name}@${line} "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep usr_sod">${cur_dir}/tmp1.out
   ssh ${os_user_name}@${line} "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep tod_sod">${cur_dir}/tmp2.out
   last_time_str1=$(tail -n 1 "${cur_dir}/tmp1.out" | awk -F',' '{print $1}')
   last_time_str2=$(tail -n 1 "${cur_dir}/tmp2.out" | awk -F',' '{print $1}')
   last_timestamp1=$(date -d "$last_time_str1" +%s 2>/dev/null)
   last_timestamp2=$(date -d "$last_time_str2" +%s 2>/dev/null)
   if [[ ${last_timestamp1} -gt ${last_timestamp2} ]];then
      last_timestamp=${last_timestamp1}
   else
      last_timestamp=${last_timestamp2}

   fi
current_timestamp=$(date +%s)

# 计算时间差（秒）
time_diff=$((current_timestamp - last_timestamp))
# 判断是否超过1分钟（120秒）
if [ $time_diff -gt ${max_wait_time} ]; then
    echo "最后一条日志距离现在已超过（${time_diff}秒）"
    break
else
    v_sleep=$((max_wait_time-time_diff+1))
    sleep ${v_sleep}
#    echo "最后一条日志距离现在（${time_diff}秒）"
fi
   done
   done

}
function check_dn_jps()
{
   local v_dn_ip=$1
   local max_wait_time=$2
local t1=`date +%s`
while true
do
   v_dn_str=`ssh ${os_user_name}@${v_dn_ip} "jps|grep DataNode"`
   v_dn_pid=`echo ${v_dn_str}|awk '{print $1}'`
   if [[ ${v_dn_pid} -gt 0 ]];then
      sleep 5
   else
      break
   fi
      t2=`date +%s`
      t_elp=$((t2-t1))
      if [[ ${t_elp} -gt ${max_wait_time} ]];then
         let fail_flag++
         v_warnMessage="${v_warnMessage}Stopping takes too long."
# kill -9
         ssh ${os_user_name}@${v_dn_ip} "kill -9 ${v_dn_pid}"
         break
      fi

done
t1=`date +%s`
while true
do
   v_dn_str=`ssh ${os_user_name}@${v_dn_ip} "jps|grep ConfigNode"`
   v_dn_pid=`echo ${v_dn_str}|awk '{print $1}'`
   if [[ ${v_dn_pid} -gt 0 ]];then
      sleep 5
   else
      break
   fi
      t2=`date +%s`
      t_elp=$((t2-t1))
      if [[ ${t_elp} -gt ${max_wait_time} ]];then
         let fail_flag++
         v_warnMessage="${v_warnMessage}Stopping takes too long."
# kill -9
         ssh ${os_user_name}@${v_dn_ip} "kill -9 ${v_dn_pid}"
         break
      fi

done


}
#  - 只检查 ${nodeinfo_dir}/datanode.txt 与当前集群 Running DN 的交集
#  - 缺失指标不退出，只持续等待
#  - syncLag > 0 持续存在时保留现场，不进入下个用例
#  - 缺失/恢复、非 0/恢复 0 只在状态变化时打印一次
#  - 轮询间隔改为 5 秒

  wait_for_monitor_sync_completion() {
      local PROMETHEUS_URL
      PROMETHEUS_URL=$(grep '^monitor_url' "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
      local PROMETHEUS_USER=admin
      local PROMETHEUS_PASS=admin
      local TARGET_DURATION=300
      local SLEEP_INTERVAL=5
      local dn_file="${nodeinfo_dir}/datanode.txt"
      local cluster_dn_file="${cur_dir}/cluster_running_datanodes.out"

      local zero_start_time=0
      local last_target_list_key=""
      declare -A seen_nodes
      declare -A last_node_status
      declare -A missing_warned

      if [[ ! -f "$dn_file" ]]; then
          echo "错误: 找不到 $dn_file"
          return 1
      fi

      while true; do
          local now
          now=$(date +%s)

          ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">"${cur_dir}/tmp.out"
          grep Running "${cur_dir}/tmp.out" | awk -F "|" '{gsub(" ","");print $4}' | sed '/^$/d' | sort -u > "${cluster_dn_file}"

          local dn_list=()
          declare -A target_nodes=()
          while read -r dn_ip; do
              [[ -z "$dn_ip" ]] && continue
              [[ "$dn_ip" =~ ^# ]] && continue
              if grep -qx "$dn_ip" "${cluster_dn_file}"; then
                  dn_list+=("$dn_ip")
                  target_nodes["$dn_ip"]=1
              fi
          done < "$dn_file"

          local expected_count=${#dn_list[@]}
          if [[ "$expected_count" -eq 0 ]]; then
              zero_start_time=0
              echo "[$(date '+%F %T')] 等待中: show datanodes 未解析到当前集群 Running DN，跳过非集群节点后无可检查目标"
              sleep "${SLEEP_INTERVAL}"
              continue
          fi

          local target_list_key="${dn_list[*]}"
          if [[ "$target_list_key" != "$last_target_list_key" ]]; then
              echo "[$(date '+%F %T')] 开始监控 Total Sync Lag，仅检查当前集群中的 ${expected_count} 个 DataNode: ${target_list_key}"
              last_target_list_key="$target_list_key"
          fi

          local instance_regex=""
          local ip
          for ip in "${dn_list[@]}"; do
              local promql_safe_ip=${ip//./[.]}
              [[ -n "$instance_regex" ]] && instance_regex="${instance_regex}|"
              instance_regex="${instance_regex}${promql_safe_ip}(:[0-9]+)?"
          done
          instance_regex="^(${instance_regex})$"

          local query
          query="sum(iot_consensus{instance=~\"${instance_regex}\",name=\"ioTConsensusServerImpl\",type=\"syncLag\"}) by (instance)"

          local response
          response=$(curl -s -u "${PROMETHEUS_USER}:${PROMETHEUS_PASS}" --get \
              --data-urlencode "query=${query}" \
              "${PROMETHEUS_URL}/api/v1/query")

          if [[ $(echo "$response" | jq -r '.status') != "success" ]]; then
              echo "[$(date '+%F %T')] 错误: 无法从 Prometheus 获取数据"
              echo "响应: $response"
              zero_start_time=0
              sleep "${SLEEP_INTERVAL}"
              continue
          fi

          seen_nodes=()
          local matched_count=0
          local zero_count=0
          local has_non_zero=false
          local non_zero_nodes=()
          local missing_nodes=()

          while IFS='|' read -r instance sync_lag; do
              [[ -z "$instance" ]] && continue

              local instance_host="${instance%%:*}"
              [[ -z "${target_nodes[$instance_host]}" ]] && continue

              seen_nodes["$instance_host"]=1
              ((matched_count++))

              if [[ ${missing_warned[$instance_host]:-false} == "true" ]]; then
                  echo "[$(date '+%F %T')] INFO: 节点 ${instance_host} 的 syncLag 指标已恢复"
                  missing_warned["$instance_host"]="false"
              fi

              if awk "BEGIN {exit !($sync_lag > 0.0001)}"; then
                  has_non_zero=true
                  non_zero_nodes+=("${instance_host}=${sync_lag}")

                  if [[ ${last_node_status[$instance_host]:-false} != "true" ]]; then
                      echo "[$(date '+%F %T')] WARN: 节点 ${instance_host} 首次检测到 syncLag=${sync_lag}"
                  fi

                  last_node_status["$instance_host"]="true"
              else
                  if [[ ${last_node_status[$instance_host]:-false} == "true" ]]; then
                      echo "[$(date '+%F %T')] INFO: 节点 ${instance_host} 的 syncLag 已恢复为 0"
                  fi
                  last_node_status["$instance_host"]="false"
                  ((zero_count++))
              fi
          done < <(
              echo "$response" | jq -r '.data.result[] | "\(.metric.instance)|\(.value[1])"'
          )

          for ip in "${dn_list[@]}"; do
              if [[ -z "${seen_nodes[$ip]:-}" ]]; then
                  missing_nodes+=("$ip")
                  if [[ ${missing_warned[$ip]:-false} != "true" ]]; then
                      echo "[$(date '+%F %T')] WARN: 节点 ${ip} 未查到 syncLag 指标"
                      missing_warned["$ip"]="true"
                  fi
              fi
          done

          if [[ ${#missing_nodes[@]} -gt 0 ]]; then
              zero_start_time=0
              echo "[$(date '+%F %T')] 等待中: 指标缺失 ${#missing_nodes[@]}/${expected_count}，缺失节点: ${missing_nodes[*]}"
              sleep "${SLEEP_INTERVAL}"
              continue
          fi

          if $has_non_zero; then
              zero_start_time=0
              echo "[$(date '+%F %T')] 等待中: ${zero_count}/${expected_count} 个 DN syncLag=0，非零节点: ${non_zero_nodes[*]}，fail_flag=${fail_flag}，sync_fail_flag=${sync_fail_flag}"
          else
              if [[ "$zero_start_time" -eq 0 ]]; then
                  zero_start_time=$now
              fi

              local current_duration=$((now - zero_start_time))
              echo "[$(date '+%F %T')] 正常: ${expected_count}/${expected_count} 个 DN syncLag=0，已持续 ${current_duration}/${TARGET_DURATION} 秒"

              if [[ "$current_duration" -ge "$TARGET_DURATION" ]]; then
                  echo "[$(date '+%F %T')] 同步完成: ${dn_file} 中所有 DataNode 的 Total Sync Lag 已连续 ${TARGET_DURATION} 秒为 0"
                  echo "最终 fail_flag=${fail_flag}, sync_fail_flag=${sync_fail_flag}"
                  return 0
              fi
          fi

          sleep "${SLEEP_INTERVAL}"
      done
  }

function create_user()
{
	# database ttl 3 hours
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "CREATE DATABASE usr_sod0 WITH (ttl=10800000);">${cur_dir}/tmp.out
check_res success 1 "CREATE DATABASE with ttl "
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "CREATE DATABASE tod_sod0 WITH (ttl=10800000);">${cur_dir}/tmp.out
check_res success 1 "CREATE DATABASE with ttl "

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  rainer 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  rainer"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  colder 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  colder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  winder 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  winder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  sunner 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  sunner"
# grant privelege
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "GRANT ALL TO USER rainer;">${cur_dir}/tmp.out
check_res success 1 "grant USER  rainer"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "GRANT ALL TO USER colder;">${cur_dir}/tmp.out
check_res success 1 "grant USER  colder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "GRANT ALL TO USER winder;">${cur_dir}/tmp.out
check_res success 1 "grant USER  winder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "GRANT ALL TO USER sunner;">${cur_dir}/tmp.out
check_res success 1 "grant USER  sunner"


}
function start_bm()
{
v_bm_time=$(date +%Y%m%d_%H%M%S)
arg="${testdb}_${v_cluster_num_info}_${v_bm_time}"

echo "==== 后台启动 BM 进程 ===="

start_bm_remote() {
    local host=$1
    local launcher_log="${bm_dir}/${arg}_launcher.log"

    ssh root@${host} "cd '${bm_dir}' || exit 1
nohup bash ./start_bm_now.sh '${arg}' > '${launcher_log}' 2>&1 < /dev/null &
sleep 1
pgrep -af \"start_bm_now.sh ${arg}\" >/dev/null"
}

if ! start_bm_remote "${bm1_ip}"; then
    echo "[ERROR] BM launcher 启动失败: ${bm1_ip}"
    let fail_flag++
    return 1
fi

if ! start_bm_remote "${bm2_ip}"; then
    echo "[ERROR] BM launcher 启动失败: ${bm2_ip}"
    let fail_flag++
    return 1
fi

echo "BM 已提交后台启动，启动日志位于 ${bm_dir}/${arg}_launcher.log"
}
function check_bm()
{
while true
do
    echo "==== 开始检查 BM benchmark 输出结果是否已完成 ===="

    bm1_status=$(ssh root@${bm1_ip} "
launcher_alive=0
bm1_alive=0
bm2_alive=0
bm1_done=0
bm2_done=0

bm1_out=\"${bm_dir}/${arg}_bm1.out\"
bm2_out=\"${bm_dir}/${arg}_bm2.out\"

pgrep -af \"start_bm_now.sh ${arg}\" >/dev/null && launcher_alive=1

if [ -f \"${bm_dir}/${arg}_bm1.pid\" ] && kill -0 \$(cat \"${bm_dir}/${arg}_bm1.pid\") 2>/dev/null; then
    bm1_alive=1
fi

if [ -f \"${bm_dir}/${arg}_bm2.pid\" ] && kill -0 \$(cat \"${bm_dir}/${arg}_bm2.pid\") 2>/dev/null; then
    bm2_alive=1
fi

if [ -f \"\$bm1_out\" ] \
   && grep -q \"Test elapsed time (not include schema creation):\" \"\$bm1_out\" \
   && grep -q \"Result Matrix\" \"\$bm1_out\"; then
    bm1_done=1
fi

if [ -f \"\$bm2_out\" ] \
   && grep -q \"Test elapsed time (not include schema creation):\" \"\$bm2_out\" \
   && grep -q \"Result Matrix\" \"\$bm2_out\"; then
    bm2_done=1
fi

echo \"\$bm1_done,\$bm2_done|\$launcher_alive,\$bm1_alive,\$bm2_alive\"
")

    bm2_status=$(ssh root@${bm2_ip} "
launcher_alive=0
bm1_alive=0
bm2_alive=0
bm1_done=0
bm2_done=0

bm1_out=\"${bm_dir}/${arg}_bm1.out\"
bm2_out=\"${bm_dir}/${arg}_bm2.out\"

pgrep -af \"start_bm_now.sh ${arg}\" >/dev/null && launcher_alive=1

if [ -f \"${bm_dir}/${arg}_bm1.pid\" ] && kill -0 \$(cat \"${bm_dir}/${arg}_bm1.pid\") 2>/dev/null; then
    bm1_alive=1
fi

if [ -f \"${bm_dir}/${arg}_bm2.pid\" ] && kill -0 \$(cat \"${bm_dir}/${arg}_bm2.pid\") 2>/dev/null; then
    bm2_alive=1
fi

if [ -f \"\$bm1_out\" ] \
   && grep -q \"Test elapsed time (not include schema creation):\" \"\$bm1_out\" \
   && grep -q \"Result Matrix\" \"\$bm1_out\"; then
    bm1_done=1
fi

if [ -f \"\$bm2_out\" ] \
   && grep -q \"Test elapsed time (not include schema creation):\" \"\$bm2_out\" \
   && grep -q \"Result Matrix\" \"\$bm2_out\"; then
    bm2_done=1
fi

echo \"\$bm1_done,\$bm2_done|\$launcher_alive,\$bm1_alive,\$bm2_alive\"
")

    echo "BM1 主机状态: $bm1_status"
    echo "BM2 主机状态: $bm2_status"

    bm1_done_info=${bm1_status%%|*}
    bm2_done_info=${bm2_status%%|*}

    if [[ "$bm1_done_info" == "1,1" && "$bm2_done_info" == "1,1" ]]; then
        echo "[INFO] BM 测试已完成（bm1.out 和 bm2.out 都已输出结果）"
        return 0
    else
        echo "[INFO] BM 结果尚未全部输出完成"
        sleep 300 
    fi
done
}
function kill_dn_cn() {
    v_kill_ip=$1

    # 校验IP是否传入
    if [[ -z "${v_kill_ip}" ]]; then
        echo "ERROR: 未传入IP"
        return 1
    fi

    echo "===== 开始杀死 ${v_kill_ip} 上的 ConfigNode 和 DataNode ====="

    # 1. 先查看进程
    ssh ${os_user_name}@${v_kill_ip} "pgrep -f 'ConfigNode|DataNode'"

    # 2. 强制杀死进程
    ssh ${os_user_name}@${v_kill_ip} "pkill -9 -f 'ConfigNode|DataNode'"
    check_dn_jps ${v_kill_ip} 180
    # 3. 等待进程消失（循环检查）
    while true; do
        v_kill_node_num=$(ssh ${os_user_name}@${v_kill_ip} "ps aux | grep -E 'ConfigNode|DataNode' | grep -v grep | wc -l")
        if [[ ${v_kill_node_num} -gt 0 ]]; then
            echo "等待进程退出，剩余：${v_kill_node_num} 个，5秒后重试..."
            sleep 5
        else
            echo "✅ 进程 kill -9 success."
            break
        fi
    done

    # 4. 检查集群状态（等待节点变成 unknown）
    echo "===== 检查集群状态 ====="
    while true; do
        if [[ ${v_kill_ip} = ${query_ip} ]]; then
            v_kill_node_num=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip2} -e "show cluster;" | grep "${v_kill_ip}|" | grep -i unknown | wc -l)
        else
            v_kill_node_num=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show cluster;" | grep "${v_kill_ip}|" | grep -i unknown | wc -l)
        fi

        # 原逻辑是 =2 代表两个节点都 unknown
        if [[ ${v_kill_node_num} -ge 2 ]]; then
            echo "✅ 集群状态检查成功，节点已下线"
            break
        else
            echo "集群状态未就绪，当前 unknown 节点数：${v_kill_node_num}，5秒后重试..."
            sleep 5
        fi
    done

    echo "===== ${v_kill_ip} 节点杀死完成 ====="
    # set v_new_cn_leader_ip
    if [[ ${v_kill_ip} = ${query_ip} ]]; then
	    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip2} -e "show confignodes;"|grep Leader|awk -F '|' '{gsub(" ","");print $4}'>${cur_dir}/tmp.out
            v_new_cn_leader_ip=$(head -1 ${cur_dir}/tmp.out)

    else
            ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show confignodes;"|grep Leader|awk -F '|' '{gsub(" ","");print $4}'>${cur_dir}/tmp.out
            v_new_cn_leader_ip=$(head -1 ${cur_dir}/tmp.out)
 
    fi
    echo "v_new_cn_leader_ip : ${v_new_cn_leader_ip} "
}
function add_new_cn_remove_bad_cn()
{
	# set ${v_new_cn_ip} 's cn_seed_config_node=127.0.0.1:10710 : ${v_new_cn_leader_ip}
	ssh ${os_user_name}@${v_new_cn_ip} "sed -i 's/cn_seed_config_node=.*/cn_seed_config_node=${v_new_cn_leader_ip}:10710/g' ${cn_db_dir}/conf/iotdb-system.properties"
	ssh ${os_user_name}@${v_new_cn_ip} "sed -i 's/cn_internal_address=.*/cn_internal_address=${v_new_cn_ip}/g' ${cn_db_dir}/conf/iotdb-system.properties"
	# start new cn
        # 拼接并执行启动命令
	v_start_time=$(date +%s)
        start_cn_cmd="source /etc/profile; nohup ${cn_db_dir}/sbin/start-confignode.sh -H ${cn_db_dir}/cn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
        echo "节点${v_new_cn_ip} 执行启动命令：ssh ${os_user_name}@${v_new_cn_ip} '${start_cn_cmd}'"

        ssh_exit_code=0
        ssh -o ConnectTimeout=10 "${os_user_name}@${v_new_cn_ip}" "${start_cn_cmd}" || ssh_exit_code=$?

        if [[ ${ssh_exit_code} -eq 0 ]]; then
            echo "节点${v_new_cn_ip} ConfigNode启动命令执行成功（退出码：${ssh_exit_code}）"
            sleep 2
        else
            echo "ERROR 节点${v_new_cn_ip} ConfigNode启动命令执行失败（退出码：${ssh_exit_code}）"
        fi
	    #  检查集群状态（等待节点变成 unknown）
    echo "===== 检查集群状态 ====="
    while true; do
            v_new_cn_num=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -e "show confignodes;" | grep "${v_new_cn_ip}|" | grep -i Running| wc -l)

        if [[ ${v_new_cn_num} -ge 1 ]]; then
            echo "✅  集群状态检查成功，节点已上线"
	    echo "${v_new_cn_ip}" >> ${nodeinfo_dir}/confignode.txt 
	    remove_cn_bad
            break
        else
            echo "CN状态未就绪，当前 Running 节点数：${v_new_cn_num}，5秒后重试..."
            sleep 5
        fi
    done

    echo "===== ${v_new_cn_num} 节点online success ====="


}
function remove_cn_bad()
{
    if [[ ${v_remove_cn_id} -ge 0 ]];then
         ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -e "remove confignode  ${v_remove_cn_id};" >${cur_dir}/tmp.out
	 v_exp_succ=$(cat ${cur_dir}/tmp.out |grep success|wc -l)
	 if [[ ${v_exp_succ} -gt 0 ]];then
		 # check cn
		 while true
		 do
                        v_new_cn_num=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -e "show confignodes;" | grep "${v_shutdown_ip1}|" |wc -l)

			if [[ ${v_new_cn_num} -ge 1 ]]; then
			    echo "CN ${v_new_cn_num} is not removed，5秒后重试..."
			    sleep 10 
			else
			    echo "CN ${v_new_cn_num} is removed successfully."
			    break 
			fi
 
		 done
	 else
		 let fail_flag++
		 v_warnMessage="${v_warnMessage}remove confignode  ${v_remove_cn_id} failed."
	 fi
    else
	 let fail_flag++
	 v_warnMessage="${v_warnMessage}remove confignode  ${v_remove_cn_id} invalid."

    fi
}
function capture_cancel_receivers()
{
local out="${cur_dir}/show_regions_before_cancel.out"
local migration_out="${cur_dir}/show_migrations_before_cancel.out"
local target_regions_out="${cur_dir}/target_regions_before_cancel.out"
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -sql_dialect table -e "show migrations;" > "${migration_out}"
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -sql_dialect table -e "show regions;" > "${out}"
v_cancel_migration_count_before=$(grep -E '^\|[[:space:]]*[0-9]+' "${migration_out}" | wc -l)
# CHECK_REMOVE_REGION_PEER 阶段会忽略 CANCEL 并继续完成 Remove，不计入真实取消目标。
awk -F '|' '
/^\|/ {
 procedure_id=$2;current_state=$8
 gsub(/^[ \t]+|[ \t]+$/, "", procedure_id);gsub(/^[ \t]+|[ \t]+$/, "", current_state)
 if (procedure_id ~ /^[0-9]+$/ && current_state != "CHECK_REMOVE_REGION_PEER") print procedure_id
}' "${migration_out}" | sort -u > "${v_cancelable_procedure_ids_file}"
v_cancelable_migration_count_before=$(wc -l < "${v_cancelable_procedure_ids_file}" | tr -d ' ')
awk -F '|' '/Adding/ {rid=$2;ip=$9;gsub(/^[ \t]+|[ \t]+$/,"",rid);gsub(/^[ \t]+|[ \t]+$/,"",ip);if(rid~/^[0-9]+$/&&ip~/^[0-9]+\./)print ip"|"rid}' "${out}" | sort -u > "${v_receiver_file}"
grep -F "${v_shutdown_ip1}" "${out}" | grep -E '^\|' > "${target_regions_out}"
v_cancel_target_region_count=$(wc -l < "${target_regions_out}" | tr -d ' ')
v_cancel_target_removing_count=$(grep -c 'Removing' "${target_regions_out}" || true)
v_cancel_all_target_regions_removing=0
if [[ ${v_cancel_target_region_count} -gt 0 && ${v_cancel_target_removing_count} -eq ${v_cancel_target_region_count} ]];then
 v_cancel_all_target_regions_removing=1
fi
log "INFO" "CANCEL 前 migration_rows=${v_cancel_migration_count_before}, 可取消=${v_cancelable_migration_count_before}, CHECK_REMOVE 继续执行=$((v_cancel_migration_count_before-v_cancelable_migration_count_before)), 故障节点 Region=${v_cancel_target_region_count}, Removing=${v_cancel_target_removing_count}, all_removing=${v_cancel_all_target_regions_removing}, Adding 接收端记录数=$(wc -l < "${v_receiver_file}" | tr -d ' ')"
}

function execute_cancel_all_migrations()
{
local out="${cur_dir}/cancel_all_migrations.out" begin=$(date +%s)
v_cancel_submit_ts=${begin}
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -sql_dialect table -e "CANCEL ALL MIGRATIONS;" > "${out}"
local cost=$(( $(date +%s)-begin ))
if ! grep -qi success "${out}"; then let fail_flag++;v_warnMessage="${v_warnMessage}CANCEL ALL MIGRATIONS failed.";return 1;fi
if [[ ${cost} -gt ${cancel_cmd_timeout_sec} ]];then let fail_flag++;v_warnMessage="${v_warnMessage}CANCEL took ${cost}s, expected <=${cancel_cmd_timeout_sec}s.";fi
log "INFO" "CANCEL ALL MIGRATIONS accepted in ${cost}s"
}

function wait_cancel_rollback_done()
{
local timeout=${1:-43200} poll=${2:-30} begin m r mc rc
if [[ ${v_cancel_submit_ts} -gt 0 ]];then begin=${v_cancel_submit_ts};else begin=$(date +%s);fi
m="${cur_dir}/show_migrations_after_cancel.out";r="${cur_dir}/show_regions_after_cancel.out"
local current_ids="${cur_dir}/current_migration_procedure_ids.out"
local remaining_ids="${cur_dir}/remaining_cancelable_procedure_ids.out"
while true;do
 ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -sql_dialect table -e "show migrations;" > "${m}"
 ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -sql_dialect table -e "show regions;" > "${r}"
 mc=$(grep -E '^\|[[:space:]]*[0-9]+' "${m}"|wc -l);rc=$(grep -E 'Adding|Removing' "${r}"|wc -l)
 awk -F '|' '/^\|/ {id=$2;gsub(/^[ \t]+|[ \t]+$/, "", id);if(id~/^[0-9]+$/)print id}' "${m}" | sort -u > "${current_ids}"
 comm -12 "${v_cancelable_procedure_ids_file}" "${current_ids}" > "${remaining_ids}"
 local remaining_count
 remaining_count=$(wc -l < "${remaining_ids}" | tr -d ' ')
 if [[ ${v_cancel_actual_elapsed_sec} -lt 0 && ${remaining_count} -eq 0 ]];then
  v_cancel_actual_elapsed_sec=$(( $(date +%s)-begin ))
  v_warnMessage="${v_warnMessage}CANCEL actual elapsed ${v_cancel_actual_elapsed_sec}s (cancelled=${v_cancelable_migration_count_before}, continued_remove=$((v_cancel_migration_count_before-v_cancelable_migration_count_before)))."
  log "INFO" "CANCEL 真实完成: ${v_cancelable_migration_count_before} 个可取消 migration 已全部消失，elapsed=${v_cancel_actual_elapsed_sec}s；$((v_cancel_migration_count_before-v_cancelable_migration_count_before)) 个 CHECK_REMOVE 任务继续执行"
 fi
 log "INFO" "等待 migration 排空: migration_rows=${mc}, remaining_cancelable=${remaining_count}, adding_or_removing=${rc}"
 if [[ ${mc} -eq 0 && ${rc} -eq 0 ]];then
  v_cancel_all_drained_elapsed_sec=$(( $(date +%s)-begin ))
  v_warnMessage="${v_warnMessage}all migrations drained elapsed ${v_cancel_all_drained_elapsed_sec}s."
  log "INFO" "全部 migration 已排空，elapsed=${v_cancel_all_drained_elapsed_sec}s";return 0
 fi
 if [[ $(( $(date +%s)-begin )) -gt ${timeout} ]];then let fail_flag++;v_warnMessage="${v_warnMessage}CANCEL rollback timeout(migrations=${mc}, transient=${rc}).";return 1;fi
 if [[ ${v_cancel_actual_elapsed_sec} -lt 0 ]];then sleep 1;else sleep ${poll};fi
done
}

function check_cancelled_remove_retained()
{
local datanodes_out="${cur_dir}/show_datanodes_after_cancel.out"
local regions_out="${cur_dir}/show_regions_after_cancel.out"
local node_count region_count
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -e "show datanodes;" > "${datanodes_out}"
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -sql_dialect table -e "show regions;" > "${regions_out}"
node_count=$(grep -F "${v_shutdown_ip1}|" "${datanodes_out}" | wc -l)
region_count=$(grep -F "${v_shutdown_ip1}" "${regions_out}" | grep -E '^\|' | wc -l)
if [[ ${node_count} -lt 1 ]];then
 if [[ ${v_cancel_all_target_regions_removing} -eq 1 ]];then
  log "INFO" "CANCEL 时故障节点的 ${v_cancel_target_region_count} 个 Region 全部处于 Removing，允许忽略取消并完成首次 REMOVE"
  return 0
 else
  let fail_flag++
  v_warnMessage="${v_warnMessage}CANCEL REMOVE failed: DataNode ${v_remove_dn_id}(${v_shutdown_ip1}) was removed although not all regions were Removing at cancel."
  log "ERROR" "CANCEL 时故障节点 Region 并非全部 Removing，但首次 REMOVE 仍完成，不符合取消预期"
  return 1
 fi
fi
if [[ ${region_count} -lt 1 ]];then
 let fail_flag++
 v_warnMessage="${v_warnMessage}CANCEL REMOVE failed: retained DataNode ${v_remove_dn_id}(${v_shutdown_ip1}) has no region."
 log "ERROR" "CANCEL 收敛后原 DataNode 上已无 Region，不符合取消预期"
 return 1
fi
log "INFO" "CANCEL REMOVE 符合预期：DataNode ${v_remove_dn_id}(${v_shutdown_ip1}) 仍在集群且保留 ${region_count} 个 Region"
return 0
}

function wait_remove_datanode_done()
{
local timeout=${1:-43200} poll=${2:-30} begin=$(date +%s)
local datanodes_out="${cur_dir}/show_datanodes_after_retry_remove.out"
local migrations_out="${cur_dir}/show_migrations_after_retry_remove.out"
local regions_out="${cur_dir}/show_regions_after_retry_remove.out"
local node_count migration_count transient_count elapsed
while true;do
 ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -e "show datanodes;" > "${datanodes_out}"
 ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -sql_dialect table -e "show migrations;" > "${migrations_out}"
 ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -sql_dialect table -e "show regions;" > "${regions_out}"
 node_count=$(grep -F "${v_shutdown_ip1}|" "${datanodes_out}" | wc -l)
 migration_count=$(grep -E '^\|[[:space:]]*[0-9]+' "${migrations_out}" | wc -l)
 transient_count=$(grep -E 'Adding|Removing' "${regions_out}" | wc -l)
 elapsed=$(( $(date +%s)-begin ))
 log "INFO" "等待第二次 REMOVE 完成: node_rows=${node_count}, migration_rows=${migration_count}, adding_or_removing=${transient_count}, elapsed=${elapsed}s"
 if [[ ${node_count} -eq 0 && ${migration_count} -eq 0 && ${transient_count} -eq 0 ]];then
  log "INFO" "第二次 REMOVE DATANODE 成功，elapsed=${elapsed}s"
  return 0
 fi
 if [[ ${elapsed} -gt ${timeout} ]];then
  let fail_flag++
  v_warnMessage="${v_warnMessage}retry REMOVE DATANODE timeout(node_rows=${node_count}, migrations=${migration_count}, transient=${transient_count})."
  return 1
 fi
 sleep ${poll}
done
}

function verify_receiver_snapshots_cleaned()
{
local targets="${cur_dir}/snapshot_check_targets.out" detail="${cur_dir}/snapshot_residue_detail.out"
local begin last progress total now ip rid found cnt bad
begin=$(date +%s)
last=-1
progress=${begin}
if [[ -s "${v_receiver_file}" ]];then cut -d'|' -f1 "${v_receiver_file}"|sort -u > "${targets}";else sed 's/ //g;/^$/d' "${nodeinfo_dir}/datanode.txt" > "${targets}";fi
while true;do
 total=0;bad="";: > "${detail}"
 while IFS= read -r ip;do
  [[ -z "${ip}" ]]&&continue
  found=""
  if [[ -s "${v_receiver_file}" ]];then
   while IFS= read -r rid;do
    found="${found}$(ssh -n -o ConnectTimeout=15 ${os_user_name}@${ip} "find ${db_dir}/data/datanode/data -type d -name 'snapshot_${rid}_*' 2>/dev/null" || echo __SSH_ERROR__)"$'\n'
   done < <(awk -F'|' -v ip="${ip}" '$1==ip{print $2}' "${v_receiver_file}")
  else
   found=$(ssh -n -o ConnectTimeout=15 ${os_user_name}@${ip} "find ${db_dir}/data/datanode/data -type d -name 'snapshot_*' 2>/dev/null" || echo __SSH_ERROR__)
  fi
  if grep -q __SSH_ERROR__ <<< "${found}";then let fail_flag++;v_warnMessage="${v_warnMessage}snapshot check ssh failed on ${ip}.";continue;fi
  cnt=$(printf '%s\n' "${found}"|sed '/^$/d'|wc -l)
  if [[ ${cnt} -gt 0 ]];then total=$((total+cnt));bad="${bad} ${ip}=${cnt}";printf '==== %s ====\n%s\n' "${ip}" "${found}" >> "${detail}";fi
 done < "${targets}"
 if [[ ${total} -eq 0 ]];then log "INFO" "sync lag 归零后接收端 snapshot 已清理";return 0;fi
 now=$(date +%s);if [[ ${last} -lt 0 || ${total} -lt ${last} ]];then last=${total};progress=${now};fi
 if [[ $((now-progress)) -gt ${snapshot_cleanup_stale_sec} || $((now-begin)) -gt ${snapshot_cleanup_timeout_sec} ]];then
  let fail_flag++;v_warnMessage="${v_warnMessage}receiver snapshot residue after syncLag=0:${bad}; see ${detail}.";cat "${detail}" >> "${log_file}";return 1
 fi
 sleep ${snapshot_cleanup_poll_sec}
done
}

function remove_dn_bad_restart()
{
    if [[ ${v_remove_dn_id} -ge 0 ]];then
         ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -e "remove datanode ${v_remove_dn_id};" >${cur_dir}/tmp.out
         v_exp_succ=$(cat ${cur_dir}/tmp.out |grep success|wc -l)
         if [[ ${v_exp_succ} -gt 0 ]];then
                 log "INFO" "REMOVE DATANODE 已提交，等待 ${cancel_after_remove_sec}s 后执行 CANCEL ALL MIGRATIONS"
                 sleep ${cancel_after_remove_sec}
                 capture_cancel_receivers
                 execute_cancel_all_migrations || log "ERROR" "CANCEL ALL MIGRATIONS 执行失败，已累计 fail_flag，继续等待首次 REMOVE procedure 收敛"
                 wait_cancel_rollback_done ${cancel_wait_timeout_sec} ${cancel_wait_poll_sec} || return 1

                 check_cancelled_remove_retained || true
                 v_new_cn_num=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -e "show datanodes;" | grep -F "${v_shutdown_ip1}|" | wc -l)
                 if [[ ${v_new_cn_num} -ge 1 ]];then
                    log "INFO" "首次 REMOVE procedure 已完成，开始第二次 REMOVE DATANODE"
                    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_new_cn_ip} -e "remove datanode ${v_remove_dn_id};" >${cur_dir}/retry_remove_datanode.out
                    if ! grep -qi success ${cur_dir}/retry_remove_datanode.out;then
                       let fail_flag++
                       v_warnMessage="${v_warnMessage}retry remove datanode ${v_remove_dn_id} submit failed."
                       log "ERROR" "第二次 REMOVE DATANODE 提交失败"
                       return 1
                    fi
                    wait_remove_datanode_done ${cancel_wait_timeout_sec} ${cancel_wait_poll_sec} || return 1
                 else
                    if [[ ${v_cancel_all_target_regions_removing} -eq 1 ]];then
                       log "INFO" "首次 REMOVE 已在全 Region Removing 的合法放行分支完成，无需再次 REMOVE"
                    else
                       log "ERROR" "首次 REMOVE 已直接完成且不属于全 Region Removing 合法分支，已累计 fail_flag"
                    fi
                 fi
                 ssh ${os_user_name}@${v_shutdown_ip1} "du -sh ${db_dir}/data"
                 ssh ${os_user_name}@${v_shutdown_ip1} "du -sh ${db_dir}/data/datanode"
                 ssh ${os_user_name}@${v_shutdown_ip1} "du -sh ${db_dir}/data/confignode"
                 v_removed_dir="${db_dir}/data_removed_$(date +%Y%m%d_%H%M%S)"
                 if ssh ${os_user_name}@${v_shutdown_ip1} "mv ${db_dir}/data ${v_removed_dir}"; then
                    echo "${v_shutdown_ip1}|${v_removed_dir}" > "${removed_data_record}"
                 else
                    let fail_flag++
                    v_warnMessage="${v_warnMessage}retry REMOVE completed but failed to move old DN data."
                 fi
			 sleep 10
			 restart_dn_bad
         else
                 let fail_flag++
                 v_warnMessage="${v_warnMessage}remove datanode  ${v_remove_cn_id} failed."
         fi
    else
         let fail_flag++
         v_warnMessage="${v_warnMessage}remove datanode  ${v_remove_cn_id} invalid."

    fi
}
function restart_dn_bad()
{
        # set ${v_new_cn_ip} 's dn_seed_config_node=127.0.0.1:10710 : ${v_new_cn_leader_ip}
        ssh ${os_user_name}@${v_shutdown_ip1} "sed -i 's/dn_seed_config_node=.*/dn_seed_config_node=${v_new_cn_leader_ip}:10710/g' ${db_dir}/conf/iotdb-system.properties"
        sleep 1
        # start new dn
        # 拼接并执行启动命令
        v_start_time=$(date +%s)
        start_cn_cmd="source /etc/profile; nohup ${cn_db_dir}/sbin/start-datanode.sh -g -H ${db_dir}/dn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
        echo "节点${v_shutdown_ip1} 执行启动命令：ssh ${os_user_name}@${v_shutdown_ip1} '${start_cn_cmd}'"

        ssh_exit_code=0
        ssh -o ConnectTimeout=10 "${os_user_name}@${v_shutdown_ip1}" "${start_cn_cmd}" || ssh_exit_code=$?

        if [[ ${ssh_exit_code} -eq 0 ]]; then
            echo "节点${v_shutdown_ip1} DataNode启动命令执行成功（退出码：${ssh_exit_code}）"
            sleep 2
        else
            echo "ERROR 节点${v_shutdown_ip1} DataNode启动命令执行失败（退出码：${ssh_exit_code}）"
        fi
            #  检查集群状态（等待节点变成 unknown）
    echo "===== 检查集群状态 ====="
    while true; do
            v_new_cn_num=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_shutdown_ip1} -e "show datanodes;" | grep "${v_shutdown_ip1}|" | grep -i Running| wc -l)

        if [[ ${v_new_cn_num} -ge 1 ]]; then
            echo "✅   集群状态检查成功，节点已上线"
	    # execute rebalance
	    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_shutdown_ip1} -sql_dialect table -e "LOAD BALANCE;">${cur_dir}/tmp.out
	    v_exp_succ=$(cat ${cur_dir}/tmp.out |grep success|wc -l)
	    if [[ ${v_exp_succ} -gt 0 ]];then
		    echo "LOAD BALANCE SUCCESS."
		    while true
		    do
			    sleep 600
			    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${v_shutdown_ip1} -sql_dialect table -e "show regions;">${cur_dir}/tmp.out
			    v_add_num=$(grep Adding ${cur_dir}/tmp.out|wc -l)
			    v_remove_num=$(grep Removing ${cur_dir}/tmp.out|wc -l)
			    v_rm_num=$((v_add_num+v_remove_num))
			    if [[ ${v_rm_num} -gt 0 ]];then
				    sleep 600
				    echo "Adding ${v_add_num},Removing ${v_remove_num}."
			    else
				    echo "no Adding ,no Removing."
				    break
			    fi

		    done
	    else
		    let fail_flag++
		    v_warnMessage="${v_warnMessage}LOAD BALANCE failed."
		    break
	    fi
            break
        else
            echo "DN状态未就绪，当前 Running 节点数：${v_new_cn_num}，5秒后重试..."
            sleep 10 
        fi
    done

    echo "===== ${v_new_cn_num} 节点online success ====="

}
function only_exec_remove_balance()
{
	sleep 3600
	add_new_cn_remove_bad_cn
	remove_dn_bad_restart
}
ha_fail() {
    local message=$1
    fail_flag=$((fail_flag + 1))
    v_warnMessage="${v_warnMessage}${message}."
    log "ERROR" "${message}"
}

ha_cli() {
    local host=$1 sql=$2 out=$3
    "${cli_dir}/sbin/start-cli.sh" -u "${db_user_name}" ${ssl_str} -h "${host}" \
        -sql_dialect table -e "${sql}" > "${out}" 2>&1
}

ha_expect_success() {
    local host=$1 sql=$2 out=$3 desc=$4
    if ha_cli "${host}" "${sql}" "${out}" && grep -qi "success" "${out}"; then
        log "INFO" "${desc}: PASS"
        return 0
    fi
    cat "${out}"
    ha_fail "${desc}"
    return 1
}

ha_prepare_databases() {
    ha_expect_success "${query_ip}" "CREATE DATABASE ${ha_keep_db};" "${cur_dir}/ha_create_keep.out" "create keep database" || return 1
    ha_expect_success "${query_ip}" "CREATE DATABASE ${ha_drop_db};" "${cur_dir}/ha_create_drop.out" "create drop database" || return 1
    ha_expect_success "${query_ip}" "USE ${ha_drop_db}; CREATE TABLE ha_table(device STRING TAG, s1 INT64 FIELD);" "${cur_dir}/ha_create_table.out" "create target table" || return 1
    ha_expect_success "${query_ip}" "USE ${ha_drop_db}; INSERT INTO ha_table(time,device,s1) VALUES(now(),'d1',1);" "${cur_dir}/ha_insert.out" "insert target data" || return 1

    # Benchmark 副本使用 rainer/colder，原配置和原目录不做任何修改。
    "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -u "${v_sec_super_user}" -e "CREATE USER rainer 'TimechoDB@2021';" > "${cur_dir}/ha_user_rainer.out" 2>&1 || true
    "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -u "${v_sec_super_user}" -e "CREATE USER colder 'TimechoDB@2021';" > "${cur_dir}/ha_user_colder.out" 2>&1 || true
    ha_expect_success "${query_ip}" "GRANT ALL TO USER rainer;" "${cur_dir}/ha_grant_rainer.out" "grant rainer" || return 1
    ha_expect_success "${query_ip}" "GRANT ALL TO USER colder;" "${cur_dir}/ha_grant_colder.out" "grant colder" || return 1
}

ha_prepare_and_start_benchmark() {
    ha_bm_prefix="${testdb}_5C20D_drop_database_2dn_$(date +%Y%m%d_%H%M%S)"
    ha_bm_runtime_dir="${bm_dir}/${ha_bm_prefix}_config_copy"
    local host conf role
    for host in "${bm1_ip}" "${bm2_ip}"; do
        if [[ "${host}" = "${bm1_ip}" ]]; then conf=conf_rw; role=bm1; else conf=conf_rr; role=bm2; fi
        ssh root@"${host}" "set -e
mkdir -p '${ha_bm_runtime_dir}'
rm -rf '${ha_bm_runtime_dir}/${conf}'
cp -a '${bm_dir}/weather_now/${conf}' '${ha_bm_runtime_dir}/${conf}'
# weather_now 会为 DB_NAME 自动追加 _sod0，因此 ha_keep 对应保活库 ha_keep_sod0。
sed -i 's/^DB_NAME=.*/DB_NAME=ha_keep/' '${ha_bm_runtime_dir}/${conf}/config.properties'
sed -i 's/^TEST_MAX_TIME=.*/TEST_MAX_TIME=3600000/' '${ha_bm_runtime_dir}/${conf}/config.properties'
sed -i 's/^START_TIME=.*/START_TIME=$(date +%Y-%m-%dT%H:%M:%S%:z)/' '${ha_bm_runtime_dir}/${conf}/config.properties'
nohup '${bm_dir}/benchmark.sh' -cf '${ha_bm_runtime_dir}/${conf}/' > '${ha_bm_runtime_dir}/${role}.out' 2>&1 < /dev/null &
echo \$! > '${ha_bm_runtime_dir}/${role}.pid'
sleep 2
kill -0 \$(cat '${ha_bm_runtime_dir}/${role}.pid')"
        if [[ $? -ne 0 ]]; then ha_fail "start benchmark ${role} on ${host}"; return 1; fi
    done
    ha_benchmark_started=1
    log "INFO" "Benchmark 已使用独立配置副本启动: ${ha_bm_runtime_dir}"
}

ha_check_benchmark_alive() {
    local host role check_failed=0 attempt state ssh_rc out_file pid_file
    if [[ ${ha_benchmark_started} -ne 1 ]]; then
        ha_fail "benchmark was not started"
        return 1
    fi
    for host in "${bm1_ip}" "${bm2_ip}"; do
        if [[ "${host}" = "${bm1_ip}" ]]; then role=bm1; else role=bm2; fi
        out_file="${ha_bm_runtime_dir}/${role}.out"
        pid_file="${ha_bm_runtime_dir}/${role}.pid"
        state="UNKNOWN"
        # Benchmark 退出与结果矩阵落盘之间存在短暂窗口；SSH/文件检查均允许重试。
        for attempt in 1 2 3 4 5 6; do
            state=$(ssh root@"${host}" "
if test -s '${pid_file}' && kill -0 \$(cat '${pid_file}') 2>/dev/null; then
    echo LIVE
elif ! test -s '${out_file}'; then
    echo NO_OUTPUT
elif grep -q 'All dataClients finished' '${out_file}' && grep -q 'Test elapsed time' '${out_file}' && grep -q 'Result Matrix' '${out_file}'; then
    if awk '/^(INGESTION|PRECISE_POINT|TIME_RANGE|VALUE_RANGE|AGG_RANGE|AGG_VALUE|AGG_RANGE_VALUE|GROUP_BY|LATEST_POINT|RANGE_QUERY_DESC|VALUE_RANGE_QUERY_DESC|GROUP_BY_DESC|SET_OPERATION)[[:space:]]/ && NF == 6 {rows++; if (\$4 != 0 || \$5 != 0) bad=1} END {exit !(rows > 0 && !bad)}' '${out_file}'; then
        echo COMPLETE_ZERO_FAILURE
    else
        echo COMPLETE_WITH_FAILURE
    fi
else
    echo RESULT_INCOMPLETE
fi" 2>/dev/null)
            ssh_rc=$?
            if [[ ${ssh_rc} -ne 0 ]]; then
                state="SSH_ERROR"
            else
                state=$(printf '%s\n' "${state}" | tail -1 | tr -d '\r')
            fi
            case "${state}" in
                LIVE)
                    break
                    ;;
                COMPLETE_ZERO_FAILURE)
                    log "INFO" "benchmark ${role} completed normally with zero failures on ${host}"
                    break
                    ;;
                COMPLETE_WITH_FAILURE)
                    break
                    ;;
                *)
                    [[ ${attempt} -lt 6 ]] && sleep 5
                    ;;
            esac
        done
        case "${state}" in
            LIVE|COMPLETE_ZERO_FAILURE)
                ;;
            COMPLETE_WITH_FAILURE)
                ssh root@"${host}" "tail -100 '${out_file}'" || true
                ha_fail "benchmark ${role} completed with failed operations on ${host}"
                check_failed=1
                ;;
            SSH_ERROR)
                ha_fail "benchmark ${role} status check failed after 6 SSH attempts on ${host}"
                check_failed=1
                ;;
            *)
                ssh root@"${host}" "tail -100 '${out_file}'" || true
                ha_fail "benchmark ${role} is not alive and result is incomplete(state=${state}) on ${host}"
                check_failed=1
                ;;
        esac
    done
    return ${check_failed}
}

ha_stop_benchmark() {
    local host role
    [[ ${ha_benchmark_started} -eq 1 ]] || return 0
    for host in "${bm1_ip}" "${bm2_ip}"; do
        if [[ "${host}" = "${bm1_ip}" ]]; then role=bm1; else role=bm2; fi
        ssh root@"${host}" "if test -s '${ha_bm_runtime_dir}/${role}.pid'; then kill \$(cat '${ha_bm_runtime_dir}/${role}.pid') 2>/dev/null || true; fi" || true
    done
}

ha_wait_target_regions() {
    local begin=$(date +%s) out="${cur_dir}/ha_regions_before_drop.out" rows
    while true; do
        ha_cli "${query_ip}" "SHOW REGIONS;" "${out}" || true
        rows=$(awk -F'|' -v db="${ha_drop_db}" '/^\|/ {v=$5;gsub(/ /,"",v);if(v==db)n++} END{print n+0}' "${out}")
        if [[ ${rows} -ge $((sr_rep_num + dr_rep_num)) ]]; then log "INFO" "target database region replicas ready: ${rows}"; return 0; fi
        if [[ $(( $(date +%s) - begin )) -gt 300 ]]; then ha_fail "target database region replicas not ready(rows=${rows})"; return 1; fi
        sleep 5
    done
}

ha_select_fault_dns() {
    local regions="${cur_dir}/ha_regions_before_drop.out"
    local candidates="${cur_dir}/ha_fault_candidates.out" ip1 ip2 valid_pair=0
    : > "${ha_fault_ips_file}"
    awk -F'|' -v db="${ha_drop_db}" '/^\|/ {d=$5;ip=$9;gsub(/ /,"",d);gsub(/ /,"",ip);if(d==db&&ip!="")print ip}' "${regions}" | sort -u > "${candidates}.all"
    : > "${candidates}"
    while read -r ip1; do
        [[ -z "${ip1}" ]] && continue
        if ! grep -Fxq "${ip1}" "${nodeinfo_dir}/confignode.txt"; then echo "${ip1}" >> "${candidates}"; fi
    done < "${candidates}.all"

    # 两个候选 DN 都必须承载目标库 Region，同一 SchemaRegion 最多故障 2/5；
    # 且必须共同承载同一 DataRegion，将其 3 个副本中的 2 个停掉，只保留 1/3 存活。
    while read -r ip1; do
        while read -r ip2; do
            [[ -z "${ip1}" || -z "${ip2}" || "${ip1}" = "${ip2}" ]] && continue
            if awk -F'|' -v db="${ha_drop_db}" -v a="${ip1}" -v b="${ip2}" '
                /^\|/ {rid=$2;t=$3;d=$5;ip=$9;gsub(/ /,"",rid);gsub(/ /,"",t);gsub(/ /,"",d);gsub(/ /,"",ip);
                         if(d==db&&(ip==a||ip==b)){down[rid]++;type[rid]=t}}
                END {has_data_2_of_3=0;
                     for(rid in down){if(type[rid]=="SchemaRegion"&&down[rid]>2)exit 1;
                                      if(type[rid]=="DataRegion"&&down[rid]>2)exit 1;
                                      if(type[rid]=="DataRegion"&&down[rid]==2)has_data_2_of_3=1}
                     exit !has_data_2_of_3}' "${regions}"; then
                printf '%s\n%s\n' "${ip1}" "${ip2}" > "${ha_fault_ips_file}"
                valid_pair=1
                break 2
            fi
        done < "${candidates}"
    done < "${candidates}"
    if [[ ${valid_pair} -ne 1 || $(wc -l < "${ha_fault_ips_file}") -ne 2 ]]; then
        ha_fail "cannot select two target DataNodes for SchemaRegion <=2/5 and the same DataRegion=2/3 down"
        return 1
    fi
    ha_query_ip="${query_ip}"
    log "INFO" "selected fault DNs=$(tr '\n' ',' < "${ha_fault_ips_file}") with SchemaRegion <=2/5 and the same DataRegion=2/3 down (1/3 alive)"
}

ha_capture_region_dirs() {
    local ip suffix rid captured regions="${cur_dir}/ha_regions_before_drop.out"
    while read -r ip; do
        [[ -z "${ip}" ]] && continue
        suffix=${ip##*.}
        awk -F'|' -v db="${ha_drop_db}" -v target_ip="${ip}" '/^\|/ {d=$5;a=$9;id=$2;gsub(/ /,"",d);gsub(/ /,"",a);gsub(/ /,"",id);if(d==db&&a==target_ip)print id}' "${regions}" | sort -u > "${cur_dir}/ha_fault_region_ids_${suffix}.out"
        ssh -n root@"${ip}" "find '${db_dir}/data/datanode' -type d 2>/dev/null" > "${cur_dir}/ha_all_dirs_before_${suffix}.out" || return 1
        : > "${cur_dir}/ha_region_dirs_before_${suffix}.out"
        while read -r rid; do
            [[ -z "${rid}" ]] && continue
            grep -E "/(schema|data)/.*(/|_)${rid}(/|_|$)" "${cur_dir}/ha_all_dirs_before_${suffix}.out" >> "${cur_dir}/ha_region_dirs_before_${suffix}.out" || true
        done < "${cur_dir}/ha_fault_region_ids_${suffix}.out"
        sort -u -o "${cur_dir}/ha_region_dirs_before_${suffix}.out" "${cur_dir}/ha_region_dirs_before_${suffix}.out"
        captured=$(wc -l < "${cur_dir}/ha_region_dirs_before_${suffix}.out")
        log "INFO" "captured ${captured} target region directories on ${ip}"
        if [[ ${captured} -eq 0 ]]; then ha_fail "no target region directory captured on ${ip}"; return 1; fi
    done < "${ha_fault_ips_file}"
}

ha_kill_datanodes() {
    local ip killed_count
    : > "${ha_killed_ips_file}"
    while read -r ip; do
        [[ -z "${ip}" ]] && continue
        ssh -n root@"${ip}" "pids=\$(jps -l | awk '\$2 == \"com.timecho.iotdb.DataNode\" || \$2 == \"org.apache.iotdb.db.service.DataNode\" || \$2 == \"DataNode\" {print \$1}'); if test -z \"\$pids\"; then echo 'DataNode PID not found' >&2; exit 1; fi; echo \"kill DataNode pid(s): \$pids\"; kill -9 \$pids" || {
            ha_fail "kill DataNode on ${ip} failed"
            return 1
        }
        echo "${ip}" >> "${ha_killed_ips_file}"
    done < "${ha_fault_ips_file}"
    killed_count=$(wc -l < "${ha_killed_ips_file}" | tr -d ' ')
    if [[ ${killed_count} -ne 2 ]]; then
        ha_fail "fault injection stopped ${killed_count} DataNodes, expected 2"
        return 1
    fi
    local begin=$(date +%s) out="${cur_dir}/ha_show_datanodes_unknown.out"
    while true; do
        ha_cli "${ha_query_ip}" "SHOW DATANODES;" "${out}" || true
        local unknown_count=0
        while read -r ip; do grep -F "${ip}" "${out}" | grep -qi Unknown && unknown_count=$((unknown_count + 1)); done < "${ha_fault_ips_file}"
        if [[ ${unknown_count} -eq 2 ]]; then log "INFO" "both fault DataNodes are Unknown"; return 0; fi
        if [[ $(( $(date +%s)-begin )) -gt 120 ]]; then ha_fail "two fault DataNodes did not both become Unknown(count=${unknown_count})"; return 1; fi
        sleep 3
    done
}

ha_drop_database_and_verify() {
    local out="${cur_dir}/ha_drop_database.out" begin=$(date +%s) cost
    ha_cli "${ha_query_ip}" "DROP DATABASE ${ha_drop_db};" "${out}"
    cost=$(( $(date +%s)-begin ))
    if ! grep -qi success "${out}"; then cat "${out}"; ha_fail "DROP DATABASE failed with two DNs down"; return 1; fi
    if [[ ${cost} -gt ${ha_drop_timeout_sec} ]]; then ha_fail "DROP DATABASE cost ${cost}s > ${ha_drop_timeout_sec}s"; fi
    log "INFO" "DROP DATABASE succeeded in ${cost}s"

    local ip dbout regout healthy_checked=0
    while read -r ip; do
        [[ -z "${ip}" ]] && continue
        grep -Fxq "${ip}" "${ha_fault_ips_file}" && continue
        ha_cli "${ip}" "SHOW DATABASES;" "${cur_dir}/ha_databases_${ip##*.}.out" || { ha_fail "SHOW DATABASES failed on ${ip}"; continue; }
        dbout="${cur_dir}/ha_databases_${ip##*.}.out"
        if grep -Eq "(^|\|)[[:space:]]*${ha_drop_db}[[:space:]]*(\||$)" "${dbout}"; then ha_fail "dropped database still visible on ${ip}"; fi
        healthy_checked=$((healthy_checked + 1))
        [[ ${healthy_checked} -ge 3 ]] && break
    done < "${nodeinfo_dir}/datanode.txt"
    if [[ ${healthy_checked} -lt 3 ]]; then ha_fail "fewer than 3 healthy DNs verified"; fi

    regout="${cur_dir}/ha_regions_after_drop.out"
    ha_cli "${ha_query_ip}" "SHOW REGIONS;" "${regout}" || ha_fail "SHOW REGIONS after drop failed"
    if awk -F'|' -v db="${ha_drop_db}" '/^\|/ {d=$5;gsub(/ /,"",d);if(d==db)found=1} END{exit !found}' "${regout}"; then
        ha_fail "target database regions still visible after DROP"
    fi
}

ha_restart_fault_dns_and_verify() {
    local ip suffix begin out="${cur_dir}/ha_show_datanodes_recovered.out" recovered
    while read -r ip; do
        [[ -z "${ip}" ]] && continue
        ssh -n root@"${ip}" "source /etc/profile; nohup '${db_dir}/sbin/start-datanode.sh' -g -H '${db_dir}/ha_drop_db_heapdump.hprof' > /dev/null 2>&1 &"
    done < "${ha_killed_ips_file}"
    begin=$(date +%s)
    while true; do
        ha_cli "${ha_query_ip}" "SHOW DATANODES;" "${out}" || true
        recovered=0
        while read -r ip; do grep -F "${ip}" "${out}" | grep -qi Running && recovered=$((recovered + 1)); done < "${ha_killed_ips_file}"
        if [[ ${recovered} -eq $(wc -l < "${ha_killed_ips_file}") ]]; then break; fi
        if [[ $(( $(date +%s)-begin )) -gt 300 ]]; then ha_fail "fault DataNodes did not all recover(count=${recovered})"; return 1; fi
        sleep 5
    done
    while read -r ip; do
        [[ -z "${ip}" ]] && continue
        suffix=${ip##*.}
        ha_cli "${ip}" "SHOW DATABASES;" "${cur_dir}/ha_databases_recovered_dn_${suffix}.out" || ha_fail "SHOW DATABASES failed on recovered DN ${ip}"
        if grep -Eq "(^|\|)[[:space:]]*${ha_drop_db}[[:space:]]*(\||$)" "${cur_dir}/ha_databases_recovered_dn_${suffix}.out"; then ha_fail "dropped database visible on recovered DN ${ip}"; fi
    done < "${ha_killed_ips_file}"

    begin=$(date +%s)
    while true; do
        local residue=0 path
        while read -r ip; do
            [[ -z "${ip}" ]] && continue
            suffix=${ip##*.}
            while IFS= read -r path; do [[ -n "${path}" ]] && ssh -n root@"${ip}" "test -e '${path}'" && residue=$((residue + 1)); done < "${cur_dir}/ha_region_dirs_before_${suffix}.out"
        done < "${ha_killed_ips_file}"
        if [[ ${residue} -eq 0 ]]; then log "INFO" "all captured target region directories removed on both recovered DNs"; break; fi
        if [[ $(( $(date +%s)-begin )) -gt ${ha_cleanup_timeout_sec} ]]; then ha_fail "${residue} target region directories remain on two recovered DNs"; break; fi
        sleep 10
    done
}

ha_final_checks() {
    ha_check_benchmark_alive
    ha_cli "${ha_query_ip}" "SHOW DATABASES;" "${cur_dir}/ha_databases_final.out" || ha_fail "final SHOW DATABASES failed"
    if ! grep -Eq "(^|\|)[[:space:]]*${ha_keep_db}[[:space:]]*(\||$)" "${cur_dir}/ha_databases_final.out"; then ha_fail "benchmark keep database is missing"; fi
    ha_cli "${ha_query_ip}" "SHOW CLUSTER;" "${cur_dir}/ha_cluster_final.out" || ha_fail "final SHOW CLUSTER failed"
    local running
    running=$(grep -c Running "${cur_dir}/ha_cluster_final.out" || true)
    if [[ ${running} -ne ${total_node_num} ]]; then ha_fail "final Running nodes=${running}, expected=${total_node_num}"; fi
}

function testcase()
{
    local prerequisites_ok=1
    ha_prepare_databases || prerequisites_ok=0
    if [[ ${prerequisites_ok} -eq 1 ]]; then
        ha_prepare_and_start_benchmark || prerequisites_ok=0
    fi
    if [[ ${prerequisites_ok} -eq 1 ]]; then
        sleep 60
        ha_check_benchmark_alive || prerequisites_ok=0
    fi
    if [[ ${prerequisites_ok} -eq 1 ]]; then
        ha_wait_target_regions || prerequisites_ok=0
    fi
    if [[ ${prerequisites_ok} -eq 1 ]]; then
        ha_select_fault_dns || prerequisites_ok=0
    fi
    if [[ ${prerequisites_ok} -eq 1 ]]; then
        if ha_capture_region_dirs && ha_kill_datanodes; then
            ha_drop_database_and_verify || true
            # DataNode 已被杀死后，无论 DROP 校验是否成功都必须恢复两个节点。
            ha_restart_fault_dns_and_verify || true
        elif [[ -s "${ha_killed_ips_file}" ]]; then
            # 部分故障注入成功时也必须恢复已停止的节点。
            ha_restart_fault_dns_and_verify || true
        fi
    fi
    if [[ ${ha_benchmark_started} -eq 1 ]]; then
        ha_final_checks
    fi
    ha_stop_benchmark
    check_log
    v_tc_name_pre=$(echo "${SCRIPT_NAME}" | awk -F '.' '{print $1}')
    v_backup_time=$(date +"%Y_%m_%d_%H_%M_%S")
    sh -x "${clean_env_dir}/backup_cluster_logs.sh" "${v_tc_name_pre}_${v_backup_time}" >> "${log_file}" 2>&1
}
function cleanup_removed_data_after_pass()
{
   if [[ ! -f "${removed_data_record}" ]];then
      echo "no removed data record found, skip cleanup."
      return 0
   fi

   v_removed_ip=$(awk -F '|' 'NR==1 {print $1}' "${removed_data_record}")
   v_removed_dir=$(awk -F '|' 'NR==1 {print $2}' "${removed_data_record}")

   if [[ -z "${v_removed_ip}" || -z "${v_removed_dir}" ]];then
      echo "removed data record invalid: $(cat "${removed_data_record}")"
      return 0
   fi

   if [[ "${v_removed_dir}" != ${db_dir}/data_removed_* ]];then
      echo "skip cleanup for unexpected dir: ${v_removed_dir}"
      return 0
   fi

   echo "stop cluster before cleanup removed data: ${v_removed_dir}"
   sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
   if [[ $? -ne 0 ]];then
      log "ERROR" "stop_cluster.sh failed, skip deleting ${v_removed_dir}"
      return 0
   fi

   if ssh ${os_user_name}@${v_removed_ip} "rm -rf ${v_removed_dir}"; then
      echo "cleanup removed data success: ${v_removed_dir}"
      rm -f "${removed_data_record}"
   else
      log "ERROR" "cleanup removed data failed: ${v_removed_ip} ${v_removed_dir}"
   fi
}

# start cluster 
echo "">${log_file}
#while true
#do
#	v_last_test=$(ps -ef | grep tc2026_5c20d_ttl_now_shutdown.sh | grep -v grep | wc -l)
#	if [[ ${v_last_test} -gt 0 ]];then
#		sleep 1200
#	else
#		echo "last test finish."
#		break
#	fi
#done
#sleep 600
start_db
# start test time
v_start_test_time=`date +%s`
testcase
v_end_test_time=`date +%s`
v_elp_time=$((v_end_test_time-v_start_test_time))
# record test result
function write_result()
{
   v_result_iotdb_ip=$(grep ^test_result_iotdb_ip "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
   v_bm_max_value=0

   v_bm_sum_value=0
   sum_fail_flag=${fail_flag}
   v_warnMessage_sql=$(printf '%s' "${v_warnMessage}" | tr -d '
' | tr '
' ' ' | sed "s/'/''/g")
   if [[ ${fail_flag} -gt 0 ]];then
           v_result_value="FAIL"
           echo "test fail"
   else
           v_result_value="PASS"
           echo "test pass"

backup_log_flag=1
   fi

   v_result_sql="insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','${v_result_value}',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage_sql}');"
   echo "${v_result_sql}"
   ${cli_dir}/sbin/start-cli.sh -h "${v_result_iotdb_ip}" -e "${v_result_sql}" >> "${log_file}" 2>&1
   if [[ $? -ne 0 ]];then
           log "ERROR" "write testcase result to ${v_result_iotdb_ip} failed"
   fi

# backup logs?
#if [[ ${backup_log_flag} -gt 0 ]];then
## stop cluster
#v_tc_name_pre=`echo ${SCRIPT_NAME}|awk -F '.' '{print $1}'`
#v_backup_time=`date +"%Y_%m_%d_%H_%M_%S"`
##sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
#sh -x ${clean_env_dir}/backup_cluster_logs.sh ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
#
#fi

   if [[ "${v_result_value}" = "PASS" ]];then
           cleanup_removed_data_after_pass
   fi
}
write_result
