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
initial_dn_num=12
target_dn_num=20
dn_num=${initial_dn_num}
v_cluster_num_info="${cn_num}C${target_dn_num}D"
dr_rep_num=3
sr_rep_num=5
initial_total_node_num=$((cn_num+initial_dn_num))
total_node_num=$((cn_num+target_dn_num))
node_num=${initial_total_node_num}
log_file="${cur_dir}/set_conf_parallel.log"
ssl_str=""
backup_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensusV2"
v_sec_super_user="root"
v_sys_super_user="root"
v_jstack_num=0
expand_helper="${cur_dir}/tc2026_v2_541_expand_12d_to_20d.sh"
batch_region_smoke_helper="${cur_dir}/tc2026_v2_541_batch_region_syntax_auth_audit_smoke.sh"
# 清理旧节点文件，复制新配置
rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

# 读取种子节点IP（兼容低版本）
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
query_ip2=$(tail -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
fail_flag=0
sum_fail_flag=0
sync_fail_flag=0
pre_expand_min_runtime_sec=9000
expand_window_min_sec_to_next_partition=300
expand_window_max_sec_to_next_partition=1500
expand_window_poll_sec=30
wait_new_region_after_expand_timeout_sec=3600
wait_new_region_after_expand_poll_sec=30
post_load_balance_runtime_sec=7200
v_load_balance_submit_ts=0
v_load_balance_elapsed_sec=0
v_bm_start_ts=0
region_migration_speed_limit_bytes_per_second=150994944
remove_datanodes_timeout_sec=43200
remove_datanodes_poll_sec=30
new_dn_target_file="${cur_dir}/remove_8dn_targets.out"
new_dn_before_data_file="${cur_dir}/remove_8dn_data_before.out"
new_dn_after_data_file="${cur_dir}/remove_8dn_data_after.out"
remove_pair_file="${cur_dir}/remove_2dn_current_targets.out"
removed_dn_file="${cur_dir}/remove_8dn_completed_targets.out"
remove_pair_region_snapshot="${cur_dir}/remove_2dn_select_show_regions.out"
batch_region_plan_file="${cur_dir}/batch_region_plan.out"
batch_region_timeout_sec=7200
batch_region_poll_sec=10
# 每个新 DN 一次批量操作的 Region 数量。默认 8，可通过环境变量覆盖。
batch_region_count_per_dn=${BATCH_REGION_COUNT_PER_DN:-8}
remove_8dn_submitted=0
consistency_unknown_timeout_sec=${CONSISTENCY_UNKNOWN_TIMEOUT_SECONDS:-180}
consistency_running_timeout_sec=${CONSISTENCY_RUNNING_TIMEOUT_SECONDS:-300}

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
        # Region/DN 运维语句属于 CONTROL 审计，保留 QUERY 并追加 CONTROL。
        batch_set_sys_conf ".*auditable_operation_type=.*" "auditable_operation_type=QUERY,CONTROL"
        batch_set_sys_conf ".*auditable_control_event_type=.*" "auditable_control_event_type=OBJECT_AUTHENTICATION"
        batch_set_sys_conf ".*auditable_operation_level=.*" "auditable_operation_level=GLOBAL"
        batch_set_sys_conf ".*auditable_operation_result=.*" "auditable_operation_result=SUCCESS,FAIL"
        batch_set_sys_conf ".*query_cost_stat_window=.*" "query_cost_stat_window=5"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
        batch_set_sys_conf ".*region_migration_speed_limit_bytes_per_second=.*" "region_migration_speed_limit_bytes_per_second=${region_migration_speed_limit_bytes_per_second}"
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
        # Region/DN 运维语句属于 CONTROL 审计，保留 QUERY 并追加 CONTROL。
        batch_set_sys_conf ".*auditable_operation_type=.*" "auditable_operation_type=QUERY,CONTROL"
        batch_set_sys_conf ".*auditable_control_event_type=.*" "auditable_control_event_type=OBJECT_AUTHENTICATION"
        batch_set_sys_conf ".*auditable_operation_level=.*" "auditable_operation_level=GLOBAL"
        batch_set_sys_conf ".*auditable_operation_result=.*" "auditable_operation_result=SUCCESS,FAIL"
        batch_set_sys_conf ".*query_cost_stat_window=.*" "query_cost_stat_window=5"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
        batch_set_sys_conf ".*region_migration_speed_limit_bytes_per_second=.*" "region_migration_speed_limit_bytes_per_second=${region_migration_speed_limit_bytes_per_second}"


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
   sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${initial_total_node_num}" >> "${log_file}" 2>&1
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
          query="iot_consensus_v2{cluster=\"${CLUSTER_ID}\",nodeType=\"DATANODE\",name=\"IoTConsensusV2ServerImpl\",type=\"syncLag\"}"

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

capture_consistency_aggregate_result() {
    local host=$1 output=$2
    local db table_out raw_out sql table first
    : > "${output}"
    for db in usr_sod0 tod_sod0; do
        table_out="${cur_dir}/consistency_tables_${db}_${host}.out"
        raw_out="${cur_dir}/consistency_aggregate_${db}_${host}.out"
        ${cli_dir}/sbin/start-cli.sh -h "${host}" -u "${db_user_name}" ${ssl_str} -sql_dialect table \
            -e "USE ${db}; SHOW TABLES;" > "${table_out}" 2>&1 || return 1
        sql="USE ${db}; "
        first=1
        while read -r table; do
            [[ -z "${table}" ]] && continue
            if [[ ${first} -eq 0 ]]; then sql="${sql} UNION ALL "; fi
            sql="${sql}SELECT '${table}' AS table_name,COUNT(*) AS row_count,MIN(time) AS min_time,MAX(time) AS max_time,COUNT(s_0) AS s0_count,COUNT(s_8) AS s8_count,COUNT(s_12) AS s12_count FROM ${table}"
            first=0
        done < <(awk -F '|' '$0 !~ /^\+/ {t=$2; gsub(/ /,"",t); if(t~/^[A-Za-z_][A-Za-z0-9_]*$/ && t!="TableName") print t}' "${table_out}" | sort)
        [[ ${first} -eq 0 ]] || return 1
        sql="${sql};"
        ${cli_dir}/sbin/start-cli.sh -h "${host}" -u "${db_user_name}" ${ssl_str} -sql_dialect table \
            -e "${sql}" > "${raw_out}" 2>&1 || return 1
        awk -F '|' -v db="${db}" '$0 !~ /^\+/ && NF>=8 {
          table=$2; gsub(/^[ \t]+|[ \t]+$/, "", table)
          if (table !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || table=="table_name") next
          line=db "|" table
          for(i=3;i<=8;i++){v=$i;gsub(/^[ \t]+|[ \t]+$/, "", v);line=line "|" v}
          print line
        }' "${raw_out}" >> "${output}"
    done
    sort -o "${output}" "${output}"
    [[ $(wc -l < "${output}") -gt 0 ]]
}

wait_consistency_dn_status() {
    local target_ip=$1 expected=$2 query_host=$3 timeout=$4
    local begin out
    begin=$(date +%s)
    out="${cur_dir}/consistency_wait_${target_ip##*.}_${expected}.out"
    while true; do
        ${cli_dir}/sbin/start-cli.sh -h "${query_host}" -u "${db_user_name}" ${ssl_str} -sql_dialect table \
            -e "SHOW DATANODES;" > "${out}" 2>&1 || true
        if awk -F '|' -v ip="${target_ip}" -v expected="${expected}" '$0 !~ /^\+/ {
          status=$3;addr=$4;gsub(/ /,"",status);gsub(/ /,"",addr)
          if(addr==ip && tolower(status)==tolower(expected)) found=1
        } END {exit !found}' "${out}"; then return 0; fi
        [[ $(( $(date +%s)-begin )) -ge ${timeout} ]] && return 1
        sleep 5
    done
}

wait_consistency_dn_process_stopped() {
    local target_ip=$1 timeout=$2 begin
    begin=$(date +%s)
    while true; do
        if ssh -n -o ConnectTimeout=10 "${os_user_name}@${target_ip}" \
          "source /etc/profile; ! jps -l 2>/dev/null | grep -Eq '(^|[.])DataNode$|com[.]timecho[.]iotdb[.]DataNode'"; then return 0; fi
        [[ $(( $(date +%s)-begin )) -ge ${timeout} ]] && return 1
        sleep 3
    done
}

verify_aggregate_consistency_with_single_dn_stop() {
    local baseline="${cur_dir}/consistency_aggregate_baseline.out"
    local dn_out="${cur_dir}/consistency_running_datanodes.out"
    local dn_list="${cur_dir}/consistency_running_dn_ips.list"
    local target_ip query_host actual mismatch_count=0 restart_failed=0

    ${cli_dir}/sbin/start-cli.sh -h "${query_ip}" -u "${db_user_name}" ${ssl_str} -sql_dialect table \
        -e "SHOW DATANODES;" > "${dn_out}" 2>&1 || return 1
    awk -F '|' '$0 !~ /^\+/ {status=$3;ip=$4;gsub(/ /,"",status);gsub(/ /,"",ip);if(status=="Running"&&ip~/^[0-9]+[.]/)print ip}' "${dn_out}" | sort -u > "${dn_list}"
    if ! capture_consistency_aggregate_result "${query_ip}" "${baseline}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}failed to capture online aggregate consistency baseline."
        return 1
    fi
    log "INFO" "所有节点在线聚合查询基准已保存: ${baseline}, rows=$(wc -l < "${baseline}")"

    while read -r target_ip; do
        [[ -z "${target_ip}" ]] && continue
        query_host=$(awk -v target="${target_ip}" '$0!=target {print; exit}' "${dn_list}")
        if [[ -z "${query_host}" ]]; then
            let fail_flag++; v_warnMessage="${v_warnMessage}no query host available while stopping ${target_ip}."; continue
        fi
        log "INFO" "副本一致性检查: 停止单个 DN ${target_ip}，通过 ${query_host} 执行聚合查询"
        ssh -n -o ConnectTimeout=10 "${os_user_name}@${target_ip}" \
            "source /etc/profile; '${db_dir}/sbin/stop-datanode.sh'" > "${cur_dir}/consistency_stop_${target_ip##*.}.out" 2>&1 || true
        if ! wait_consistency_dn_process_stopped "${target_ip}" "${consistency_unknown_timeout_sec}" || \
           ! wait_consistency_dn_status "${target_ip}" Unknown "${query_host}" "${consistency_unknown_timeout_sec}"; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}single-DN consistency fault injection failed on ${target_ip}."
        else
            actual="${cur_dir}/consistency_aggregate_stop_${target_ip##*.}.out"
            if ! capture_consistency_aggregate_result "${query_host}" "${actual}"; then
                let fail_flag++
                v_warnMessage="${v_warnMessage}aggregate query failed with DN ${target_ip} stopped."
            elif ! cmp -s "${baseline}" "${actual}"; then
                mismatch_count=$((mismatch_count+1))
                let fail_flag++
                v_warnMessage="${v_warnMessage}aggregate data mismatch with DN ${target_ip} stopped."
                diff -u "${baseline}" "${actual}" > "${cur_dir}/consistency_diff_stop_${target_ip##*.}.out" || true
                log "ERROR" "停止 DN ${target_ip} 后聚合结果与基准不一致"
            else
                log "INFO" "停止 DN ${target_ip} 后聚合结果与在线基准一致"
            fi
        fi

        wait_consistency_dn_process_stopped "${target_ip}" "${consistency_unknown_timeout_sec}" || true
        ssh -n -o ConnectTimeout=10 "${os_user_name}@${target_ip}" \
            "source /etc/profile; nohup '${db_dir}/sbin/start-datanode.sh' -g -H '${db_dir}/consistency_${target_ip##*.}_heapdump.hprof' > '${db_dir}/consistency_${target_ip##*.}_restart.out' 2>&1 < /dev/null &" \
            > "${cur_dir}/consistency_start_${target_ip##*.}.out" 2>&1 || true
        if ! wait_consistency_dn_status "${target_ip}" Running "${query_host}" "${consistency_running_timeout_sec}"; then
            restart_failed=$((restart_failed+1))
            let fail_flag++
            v_warnMessage="${v_warnMessage}DN ${target_ip} did not recover after consistency check."
        fi
    done < "${dn_list}"

    log "INFO" "逐个停止单 DN 聚合一致性校验完成: mismatch=${mismatch_count}, restart_failed=${restart_failed}"
    [[ ${mismatch_count} -eq 0 && ${restart_failed} -eq 0 ]]
}

function create_user()
{
	# 一致性校验需要冻结后的完整数据集，数据库不设置 TTL。
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "CREATE DATABASE usr_sod0;">${cur_dir}/tmp.out
check_res success 1 "CREATE DATABASE usr_sod0 without ttl "
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "CREATE DATABASE tod_sod0;">${cur_dir}/tmp.out
check_res success 1 "CREATE DATABASE tod_sod0 without ttl "

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
function exec_jstack()
{
v_jstack_dir=${cur_dir}/${testdb}/jstack_result
mkdir -p ${v_jstack_dir}
datanode_file="${nodeinfo_dir}/datanode.txt"
confignode_file="${nodeinfo_dir}/confignode.txt"

dump_remote_process_debug() {
    local ip=$1
    local process_name=$2
    local outfile=$3

    ssh root@"${ip}" bash -s -- "${process_name}" > "${outfile}" 2>&1 <<'EOF'
process_name="$1"
pid=$(pgrep -f "${process_name}" | head -n1)

echo "==== ${process_name} Debug Info ===="
if [ -z "${pid}" ]; then
    echo "${process_name} pid not found"
    exit 0
fi

echo "pid: ${pid}"
echo "---- Established Peers ----"
peer_summary=$(ss -tunp state established 2>/dev/null \
    | awk -v pid="${pid}" '$0 ~ ("pid=" pid ",") {print $5}' \
    | rev | cut -d":" -f2- | rev \
    | grep -v -E '^(127\.|::1|\[::1\]|localhost)$' \
    | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
    | uniq -c)

if [ -n "${peer_summary}" ]; then
    echo "${peer_summary}"
else
    echo "no non-local established peers"
fi

echo
echo "---- Jstack ----"
jstack "${pid}"
EOF
}

time=$(date +%Y%m%d_%H%M%S)

echo "==== 开始批量抓取 jstack，结果保存在当前目录 ===="

# ===================== 处理 ConfigNode =====================
if [ -f "$confignode_file" ]; then
    echo -e "\n>>>> 开始处理 ConfigNode 节点 <<<<"
    for ip in $(cat "$confignode_file" | grep -v '^$'); do
	    v_ip=$(echo ${ip}|awk -F '.' '{print $4}')
        outfile="${v_cluster_num_info}_cn_ip${v_ip}_${v_jstack_num}_${time}_jstack.out"
        echo "节点 $ip -> 输出到 $outfile"

        dump_remote_process_debug "$ip" "ConfigNode" "${v_jstack_dir}/$outfile"
    done
fi

# ===================== 处理 DataNode =====================
if [ -f "$datanode_file" ]; then
    echo -e "\n>>>> 开始处理 DataNode 节点 <<<<"
    for ip in $(cat "$datanode_file" | grep -v '^$'); do
	    v_ip=$(echo ${ip}|awk -F '.' '{print $4}')
        outfile="${v_cluster_num_info}_dn_ip${v_ip}_${v_jstack_num}_${time}_jstack.out"
        echo "节点 $ip -> 输出到 $outfile"

        dump_remote_process_debug "$ip" "DataNode" "${v_jstack_dir}/$outfile"
    done
fi

echo -e "\n==== 全部完成！所有 jstack 文件已保存在当前目录 ===="
let v_jstack_num++
}
function start_bm()
{
v_bm_time=$(date +%Y%m%d_%H%M%S)
arg="${testdb}_${v_cluster_num_info}_${v_bm_time}"
v_bm_start_ts=$(date +%s)

echo "==== 后台启动 BM 进程 ===="

start_bm_remote() {
    local host=$1
    local launcher_log="${bm_dir}/${arg}_launcher.log"

    ssh root@${host} "cd '${bm_dir}' || exit 1
nohup bash ./start_bm_now_no_limit.sh '${arg}' > '${launcher_log}' 2>&1 < /dev/null &
sleep 1
pgrep -af \"start_bm_now_no_limit.sh ${arg}\" >/dev/null"
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
log "INFO" "BM 启动时间已记录: bm_start_ts=${v_bm_start_ts}，扩容将按整点窗口动态触发"
}
function wait_for_expand_window()
{
local min_runtime_sec=${1:-9000}
local min_sec_to_next_partition=${2:-300}
local max_sec_to_next_partition=${3:-1500}
local poll_sec=${4:-30}

if [[ ${v_bm_start_ts} -le 0 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}BM start ts not initialized."
   return 1
fi

while true
do
   local now
   local elapsed_sec
   local sec_to_next_partition
   local sleep_sec

   now=$(date +%s)
   elapsed_sec=$((now-v_bm_start_ts))
   sec_to_next_partition=$((3600-(now%3600)))

   if [[ ${elapsed_sec} -lt ${min_runtime_sec} ]];then
      sleep_sec=${poll_sec}
      if [[ $((min_runtime_sec-elapsed_sec)) -lt ${sleep_sec} ]];then
         sleep_sec=$((min_runtime_sec-elapsed_sec))
      fi
      if [[ ${sleep_sec} -le 0 ]];then
         sleep_sec=1
      fi
      log "INFO" "等待扩容最小时长: benchmark_elapsed=${elapsed_sec}s, min_runtime=${min_runtime_sec}s, sec_to_next_time_partition_boundary=${sec_to_next_partition}s"
      sleep ${sleep_sec}
      continue
   fi

   if [[ ${sec_to_next_partition} -ge ${min_sec_to_next_partition} && ${sec_to_next_partition} -le ${max_sec_to_next_partition} ]];then
      log "INFO" "命中扩容窗口: benchmark_elapsed=${elapsed_sec}s, sec_to_next_time_partition_boundary=${sec_to_next_partition}s, expand_window=[${min_sec_to_next_partition},${max_sec_to_next_partition}]s"
      break
   fi

   log "INFO" "等待扩容窗口: benchmark_elapsed=${elapsed_sec}s, sec_to_next_time_partition_boundary=${sec_to_next_partition}s, expand_window=[${min_sec_to_next_partition},${max_sec_to_next_partition}]s"
   sleep ${poll_sec}
done
}
function record_table_regions()
{
local tag=$1
local snapshot_dir=${cur_dir}/${testdb}/region_snapshots
local snapshot_time
snapshot_time=$(date +%Y%m%d_%H%M%S)
mkdir -p "${snapshot_dir}"

${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;">"${snapshot_dir}/${snapshot_time}_${tag}_table_show_regions.out"
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show regions;">"${snapshot_dir}/${snapshot_time}_${tag}_tree_show_regions.out"
summarize_data_region_leaders_by_dn \
   "${snapshot_dir}/${snapshot_time}_${tag}_table_show_regions.out" \
   "${snapshot_dir}/${snapshot_time}_${tag}_data_region_dn_summary.out"
log "INFO" "show regions 快照已保存: ${snapshot_dir}/${snapshot_time}_${tag}_table_show_regions.out"
}
function summarize_data_region_leaders_by_dn()
{
local region_out=$1
local summary_file=$2

awk -F '|' '
function trim(s) {
   gsub(/^[ \t]+|[ \t]+$/, "", s)
   return s
}
/^\+/ {next}
NF < 12 {next}
{
   region_id = trim($2)
   region_type = trim($3)
   data_node_id = trim($8)
   client_rpc_ip = trim($9)
   role_type = trim($12)

   if (region_id == "" || region_id == "RegionId" || region_type != "DataRegion" || data_node_id == "") {
      next
   }

   if (!(data_node_id in seen)) {
      seen[data_node_id] = 1
      order[++order_num] = data_node_id
      dn_ip[data_node_id] = client_rpc_ip
   }

   total_region_count[data_node_id]++
   if (role_type == "Leader") {
      leader_count[data_node_id]++
   }
   if (role_type == "Follower") {
      follower_count[data_node_id]++
   }
}
END {
   print "DataNodeId,ClientRpcIp,LeaderCount,FollowerCount,TotalDataRegionCount"
   for (i = 1; i <= order_num; i++) {
      data_node_id = order[i]
      print data_node_id "," dn_ip[data_node_id] "," (leader_count[data_node_id] + 0) "," (follower_count[data_node_id] + 0) "," (total_region_count[data_node_id] + 0)
   }
}' "${region_out}" > "${summary_file}"

log "INFO" "每个 DN 的 DataRegion Leader/Follower/总数统计已保存: ${summary_file}"
while IFS=, read -r data_node_id client_rpc_ip leader_count follower_count total_region_count
do
   [[ "${data_node_id}" == "DataNodeId" ]] && continue
   log "INFO" "DN ${data_node_id} (${client_rpc_ip}): leader_count=${leader_count}, follower_count=${follower_count}, total_data_regions=${total_region_count}"
done < "${summary_file}"
}
function run_expand_to_20d()
{
log "INFO" "开始执行 12D -> 20D 扩容"
bash "${expand_helper}" >> "${log_file}" 2>&1
if [[ $? -ne 0 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}expand to 20D failed."
   return 1
fi
query_ip2=$(tail -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
}
function set_region_migration_speed_limit()
{
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "set configuration region_migration_speed_limit_bytes_per_second='${region_migration_speed_limit_bytes_per_second}';">${cur_dir}/tmp.out
local v_exp_succ
v_exp_succ=$(grep -i success ${cur_dir}/tmp.out|wc -l)
if [[ ${v_exp_succ} -lt 1 ]];then
   if grep -qi "ignored config items" "${cur_dir}/tmp.out"; then
      log "WARN" "region_migration_speed_limit_bytes_per_second 当前版本不可热加载，忽略该设置并继续执行 LOAD BALANCE"
      cat ${cur_dir}/tmp.out
      return 0
   fi
   let fail_flag++
   v_warnMessage="${v_warnMessage}set configuration region_migration_speed_limit_bytes_per_second failed."
   cat ${cur_dir}/tmp.out
   return 1
fi
log "INFO" "已热加载 region_migration_speed_limit_bytes_per_second=${region_migration_speed_limit_bytes_per_second}"
}
function execute_load_balance()
{
v_load_balance_submit_ts=$(date +%s)
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "LOAD BALANCE;">${cur_dir}/tmp.out
local v_exp_succ
v_exp_succ=$(grep -i success ${cur_dir}/tmp.out|wc -l)
if [[ ${v_exp_succ} -lt 1 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}LOAD BALANCE failed."
   cat ${cur_dir}/tmp.out
   return 1
fi
log "INFO" "LOAD BALANCE 已提交成功"
}
function wait_for_new_datanode_data_regions()
{
local timeout_sec=${1:-3600}
local poll_sec=${2:-30}
local region_out=${cur_dir}/wait_new_datanode_regions.out
local new_dn_ip_file=${cur_dir}/new_expand_datanode_ips.out
local expected_new_dn_num=$((target_dn_num-initial_dn_num))
local wait_begin_time
wait_begin_time=$(date +%s)

tail -n ${expected_new_dn_num} "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sed '/^$/d' | sort -u > "${new_dn_ip_file}"

while true
do
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;">"${region_out}"

   local new_dn_region_stat
   local new_dn_replica_count
   local new_dn_region_count
   new_dn_region_stat=$(awk -F '|' '
FNR==NR {
   gsub(/ /, "", $0)
   if ($0 != "") {
      new_dn_ip[$0] = 1
   }
   next
}
/^\+/ {next}
NF < 8 {next}
{
   region_id = $2
   region_type = $3
   rpc_ip = $9
   gsub(/^[ \t]+|[ \t]+$/, "", region_id)
   gsub(/^[ \t]+|[ \t]+$/, "", region_type)
   gsub(/^[ \t]+|[ \t]+$/, "", rpc_ip)
   if (region_type == "DataRegion" && (rpc_ip in new_dn_ip)) {
      replica_count++
      region_seen[region_id] = 1
   }
}
END {
   for (region_id in region_seen) {
      region_count++
   }
   printf "%d,%d\n", replica_count+0, region_count+0
}' "${new_dn_ip_file}" "${region_out}")
   new_dn_replica_count=$(echo "${new_dn_region_stat}" | awk -F ',' '{print $1}')
   new_dn_region_count=$(echo "${new_dn_region_stat}" | awk -F ',' '{print $2}')

   log "INFO" "等待新扩容 DN 上出现 DataRegion: replica_count=${new_dn_replica_count}, region_count=${new_dn_region_count}"
   if [[ ${new_dn_replica_count} -gt 0 ]];then
      log "INFO" "新扩容 DN 上已经出现 DataRegion，继续执行 LOAD BALANCE"
      break
   fi

   local wait_now_time
   wait_now_time=$(date +%s)
   if [[ $((wait_now_time-wait_begin_time)) -gt ${timeout_sec} ]];then
      let fail_flag++
      v_warnMessage="${v_warnMessage}wait new datanode DataRegion timeout after $((wait_now_time-wait_begin_time))s."
      return 1
   fi
   sleep ${poll_sec}
done
}
function stop_bm()
{
if [[ -z "${arg:-}" ]]; then
   log "INFO" "未启动 BM 或未设置 arg，跳过停止 BM"
   return 0
fi

for host in "${bm1_ip}" "${bm2_ip}"
do
   ssh root@${host} "
for pidfile in ${bm_dir}/${arg}_bm1.pid ${bm_dir}/${arg}_bm2.pid
do
    if [ -f \"\${pidfile}\" ]; then
        kill \$(cat \"\${pidfile}\") 2>/dev/null || true
    fi
done
pgrep -af \"start_bm_now_no_limit.sh ${arg}\" | awk '{print \$1}' | xargs -r kill 2>/dev/null || true
" >> "${log_file}" 2>&1 || true
done
log "INFO" "BM 写入进程已停止"
# check bm if error
for host in "${bm1_ip}" "${bm2_ip}"
do
	v_bm_error_num=$(ssh root@${host} "grep ERROR ${bm_dir}/${arg}_bm*out|wc -l")
	if [[ ${v_bm_error_num} -gt 0 ]];then
		let fail_flag++
                v_warnMessage="${v_warnMessage}${host} benchmark has ${v_bm_error_num} errors."
	fi
done
}
function count_cli_table_rows()
{
local input_file=$1
local header_name=$2
awk -F '|' -v header_name="${header_name}" '
/^\+/ {next}
NF < 3 {next}
{
   first_col=$2
   gsub(/^[ \t]+|[ \t]+$/, "", first_col)
   if (first_col == "" || first_col == header_name) {
      next
   }
   row_count++
}
END {
   print row_count+0
}' "${input_file}"
}
function wait_load_balance_done()
{
local timeout_sec=${1:-43200}
local poll_sec=${2:-30}
local wait_begin_time
if [[ ${v_load_balance_submit_ts} -gt 0 ]];then
   wait_begin_time=${v_load_balance_submit_ts}
else
   wait_begin_time=$(date +%s)
fi
local migration_out=${cur_dir}/show_migrations.out
local region_out=${cur_dir}/show_regions_table_load_balance.out

while true
do
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show migrations;">"${migration_out}"
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;">"${region_out}"

   local migration_row_count
   local adding_removing_count
   migration_row_count=$(count_cli_table_rows "${migration_out}" "ProcedureId")
   adding_removing_count=$(grep -E "Adding|Removing" "${region_out}" | wc -l)

   log "INFO" "等待 LOAD BALANCE 完成: migration_rows=${migration_row_count}, adding_or_removing=${adding_removing_count}"
   if [[ ${migration_row_count} -eq 0 && ${adding_removing_count} -eq 0 ]];then
      local wait_end_time
      wait_end_time=$(date +%s)
      v_load_balance_elapsed_sec=$((wait_end_time-wait_begin_time))
      v_warnMessage="${v_warnMessage}LOAD BALANCE elapsed ${v_load_balance_elapsed_sec}s."
      log "INFO" "LOAD BALANCE 已完成: show migrations 为空，show regions 无 Adding/Removing，elapsed=${v_load_balance_elapsed_sec}s"
      break
   fi

   local wait_now_time
   wait_now_time=$(date +%s)
   if [[ $((wait_now_time-wait_begin_time)) -gt ${timeout_sec} ]];then
      v_load_balance_elapsed_sec=$((wait_now_time-wait_begin_time))
      let fail_flag++
      v_warnMessage="${v_warnMessage}wait LOAD BALANCE done timeout after ${v_load_balance_elapsed_sec}s."
      return 1
   fi
   sleep ${poll_sec}
done
}
function prepare_remove_8dn_targets()
{
local expected_new_dn_num=$((target_dn_num-initial_dn_num))
local new_dn_ip_file=${cur_dir}/new_expand_datanode_ips.out
local show_dn_out=${cur_dir}/show_datanodes_before_remove_8dn.out

tail -n ${expected_new_dn_num} "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sed '/^$/d' | sort -u > "${new_dn_ip_file}"
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">"${show_dn_out}"
awk -F '|' '
FNR==NR { gsub(/ /, "", $0); if ($0 != "") target_ip[$0]=1; next }
/^\+/ { next }
NF >= 5 {
  id=$2; status=$3; ip=$4
  gsub(/^[ \t]+|[ \t]+$/, "", id)
  gsub(/^[ \t]+|[ \t]+$/, "", status)
  gsub(/^[ \t]+|[ \t]+$/, "", ip)
  if ((ip in target_ip) && id ~ /^[0-9]+$/) print id "," ip "," status
}' "${new_dn_ip_file}" "${show_dn_out}" | sort -t ',' -k2,2V > "${new_dn_target_file}"

local target_count
local running_count
local expected_ip_count
target_count=$(wc -l < "${new_dn_target_file}")
running_count=$(awk -F ',' '$3=="Running" {n++} END {print n+0}' "${new_dn_target_file}")
expected_ip_count=$(awk -F ',' '$2 ~ /^172[.]20[.]70[.](11[2-9])$/ {n++} END {print n+0}' "${new_dn_target_file}")
cat "${new_dn_target_file}"
if [[ ${target_count} -ne ${expected_new_dn_num} || ${running_count} -ne ${expected_new_dn_num} || ${expected_ip_count} -ne ${expected_new_dn_num} ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}remove target mapping invalid: target_count=${target_count}, running_count=${running_count}, expected_112_119_count=${expected_ip_count}."
   log "ERROR" "无法安全确定 172.20.70.112-119 对应的 8 个新扩容 DN，拒绝执行 REMOVE DATANODE"
   return 1
fi
log "INFO" "已锁定 8 个新扩容 DN（DataNodeId,IP,Status）: $(tr '\n' ';' < "${new_dn_target_file}")"
}
function collect_remove_target_data()
{
local output_file=$1
local phase=$2
: > "${output_file}"
local collect_error=0
while IFS=, read -r dn_id dn_ip dn_status
do
   [[ -z "${dn_id}" ]] && continue
   local stat
   stat=$(ssh -n -o ConnectTimeout=10 "${os_user_name}@${dn_ip}" "D=${db_dir}/data/datanode/data; size_kb=\$(du -sk \"\$D\" 2>/dev/null | awk '{print \$1}'); files=\$(find \"\$D\" -type f 2>/dev/null | wc -l); tsfiles=\$(find \"\$D\" -type f -name '*.tsfile' 2>/dev/null | wc -l); object_files=\$(find \"\$D/object\" -type f 2>/dev/null | wc -l); printf '%s,%s,%s,%s' \"\${size_kb:-0}\" \"\$files\" \"\$tsfiles\" \"\$object_files\"" 2>/dev/null)
   if [[ $? -ne 0 || ! "${stat}" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]];then
      stat="ERROR,ERROR,ERROR,ERROR"
      collect_error=$((collect_error+1))
      let fail_flag++
      v_warnMessage="${v_warnMessage}collect ${phase} data failed on DN ${dn_id} ${dn_ip}."
   fi
   echo "${dn_id},${dn_ip},${stat}" >> "${output_file}"
done < "${new_dn_target_file}"
log "INFO" "缩容目标 DN 数据统计(${phase})，列为 id,ip,size_kb,file_count,tsfile_count,object_file_count: $(tr '\n' ';' < "${output_file}")"
[[ ${collect_error} -eq 0 ]]
}
function select_non_conflicting_remove_pair()
{
local batch_no=$1
local remaining_file=${cur_dir}/remove_8dn_remaining_targets.out
local region_snapshot=${cur_dir}/remove_2dn_batch_${batch_no}_select_show_regions.out
local pair_ids
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;">"${region_snapshot}" || return 1
awk -F ',' 'FILENAME==ARGV[1] {done[$1]=1; next} !($1 in done)' "${removed_dn_file}" "${new_dn_target_file}" > "${remaining_file}"
: > "${remove_pair_file}"
pair_ids=$(awk -F '[|,]' '
function trim(s) {gsub(/^[ \t]+|[ \t]+$/, "", s); return s}
FNR==NR {
   if ($0 !~ /^\+/ && NF >= 8) {
      region_id=trim($2); dn_id=trim($8)
      if (region_id ~ /^[0-9]+$/ && dn_id ~ /^[0-9]+$/) regions[dn_id SUBSEP region_id]=1
   }
   next
}
{id[++n]=$1}
END {
   for (i=1; i<=n; i++) for (j=i+1; j<=n; j++) {
      conflict=0
      for (key in regions) {
         split(key, a, SUBSEP)
         if (a[1]==id[i] && ((id[j] SUBSEP a[2]) in regions)) {conflict=1; break}
      }
      if (!conflict) {print id[i] "," id[j]; exit}
   }
}' "${region_snapshot}" "${remaining_file}")
if [[ -z "${pair_ids}" ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}batch ${batch_no}: no two remaining DNs have disjoint RegionIDs."
   log "ERROR" "第 ${batch_no}/4 批找不到 RegionID 无交集的两个 DN，拒绝提交 REMOVE DATANODE"
   return 1
fi
awk -F ',' -v ids="${pair_ids}" 'BEGIN {split(ids,a,","); wanted[a[1]]=1; wanted[a[2]]=1} $1 in wanted' "${remaining_file}" > "${remove_pair_file}"
if [[ $(wc -l < "${remove_pair_file}") -ne 2 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}batch ${batch_no}: selected pair mapping invalid (${pair_ids})."
   return 1
fi
log "INFO" "第 ${batch_no}/4 批已选择 RegionID 无交集的 DN: $(tr '\n' ';' < "${remove_pair_file}")"
log "INFO" "选择证据已保存: ${region_snapshot}；两个 DN 不存在相同 RegionID"
}
function execute_remove_2dn()
{
local batch_no=$1
local remove_ids
local remove_out=${cur_dir}/remove_2dn_batch_${batch_no}_submit.out
remove_ids=$(cut -d ',' -f1 "${remove_pair_file}" | paste -sd, -)
if [[ $(awk -F ',' '{print NF}' <<< "${remove_ids}") -ne 2 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}batch ${batch_no}: remove pair invalid (${remove_ids})."
   return 1
fi
log "INFO" "第 ${batch_no}/4 批执行: REMOVE DATANODE ${remove_ids}"
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "REMOVE DATANODE ${remove_ids};">"${remove_out}"
cat "${remove_out}"
if ! grep -qi "success" "${remove_out}";then
   let fail_flag++
   v_warnMessage="${v_warnMessage}batch ${batch_no}: REMOVE DATANODE ${remove_ids} failed."
   log "ERROR" "第 ${batch_no}/4 批 REMOVE DATANODE 提交失败: $(tr '\n' ' ' < "${remove_out}")"
   return 1
fi
log "INFO" "第 ${batch_no}/4 批 REMOVE DATANODE ${remove_ids} 提交成功"
}
function wait_remove_2dn_done()
{
local batch_no=$1
local begin_ts
begin_ts=$(date +%s)
local show_dn_out=${cur_dir}/show_datanodes_wait_remove_8dn.out
local show_region_out=${cur_dir}/show_regions_wait_remove_8dn.out
local show_migration_out=${cur_dir}/show_migrations_wait_remove_8dn.out
while true
do
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">"${show_dn_out}"
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;">"${show_region_out}"
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show migrations;">"${show_migration_out}"
   local remaining_dn=0
   local remaining_region=0
   local migration_rows
   while IFS=, read -r dn_id dn_ip dn_status
   do
      grep -Eq "\|[[:space:]]*${dn_id}[[:space:]]*\|.*\|[[:space:]]*${dn_ip}[[:space:]]*\|" "${show_dn_out}" && remaining_dn=$((remaining_dn+1))
      awk -F '|' -v target_id="${dn_id}" '{id=$8; gsub(/^[ \t]+|[ \t]+$/, "", id); if (id==target_id) found=1} END {exit(found ? 0 : 1)}' "${show_region_out}" && remaining_region=$((remaining_region+1))
   done < "${remove_pair_file}"
   migration_rows=$(count_cli_table_rows "${show_migration_out}" "ProcedureId")
   log "INFO" "等待第 ${batch_no}/4 批 2DN 缩容完成: remaining_datanodes=${remaining_dn}, remaining_region_refs=${remaining_region}, migration_rows=${migration_rows}"
   if [[ ${remaining_dn} -eq 0 && ${remaining_region} -eq 0 && ${migration_rows} -eq 0 ]];then
      break
   fi
   if [[ $(( $(date +%s)-begin_ts )) -gt ${remove_datanodes_timeout_sec} ]];then
      let fail_flag++
      v_warnMessage="${v_warnMessage}batch ${batch_no}: wait remove 2DN timeout."
      return 1
   fi
   sleep ${remove_datanodes_poll_sec}
done

local initial_dn_ip_file=${cur_dir}/initial_12dn_ips.out
head -n ${initial_dn_num} "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sed '/^$/d' | sort -u > "${initial_dn_ip_file}"
local running_initial_count
running_initial_count=$(awk -F '|' 'FNR==NR {gsub(/ /,"",$0); if ($0!="") initial[$0]=1; next} $0 !~ /^\+/ {status=$3; ip=$4; gsub(/ /,"",status); gsub(/ /,"",ip); if (status=="Running" && (ip in initial)) n++} END {print n+0}' "${initial_dn_ip_file}" "${show_dn_out}")
if [[ ${running_initial_count} -ne ${initial_dn_num} ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}initial Running DN count after remove is ${running_initial_count}."
   return 1
fi
cat "${remove_pair_file}" >> "${removed_dn_file}"
log "INFO" "第 ${batch_no}/4 批 2DN 缩容完成，初始 12 个 DN 仍为 Running；累计完成 $(wc -l < "${removed_dn_file}")/8"
}
function verify_remove_8dn_final_state()
{
local show_cluster_out=${cur_dir}/show_cluster_after_remove_8dn.out
local show_dn_out=${cur_dir}/show_datanodes_after_remove_8dn.out
local show_region_out=${cur_dir}/show_regions_after_remove_8dn.out
local evidence_out=${cur_dir}/remove_8dn_assertions.out
local expected_running_total=$((cn_num+initial_dn_num))
local running_total
local running_dn_count
local assertion_fail=0

${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show cluster;">"${show_cluster_out}" || assertion_fail=$((assertion_fail+1))
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">"${show_dn_out}" || assertion_fail=$((assertion_fail+1))
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;">"${show_region_out}" || assertion_fail=$((assertion_fail+1))
: > "${evidence_out}"

running_total=$(grep -c 'Running' "${show_cluster_out}" || true)
running_dn_count=$(awk -F '|' '$0 !~ /^\+/ {status=$3; gsub(/ /,"",status); if (status=="Running") n++} END {print n+0}' "${show_dn_out}")
if [[ ${running_total} -eq ${expected_running_total} && ${running_dn_count} -eq ${initial_dn_num} ]];then
   echo "PASS,cluster,SHOW CLUSTER Running=${running_total},SHOW DATANODES Running=${running_dn_count}" >> "${evidence_out}"
else
   echo "FAIL,cluster,SHOW CLUSTER Running=${running_total} expected=${expected_running_total},SHOW DATANODES Running=${running_dn_count} expected=${initial_dn_num}" >> "${evidence_out}"
   assertion_fail=$((assertion_fail+1))
fi

while read -r initial_dn_ip
do
   [[ -z "${initial_dn_ip}" ]] && continue
   if awk -F '|' -v target_ip="${initial_dn_ip}" '$0 !~ /^\+/ {status=$3; ip=$4; gsub(/ /,"",status); gsub(/ /,"",ip); if (ip==target_ip && status=="Running") found=1} END {exit(found ? 0 : 1)}' "${show_dn_out}";then
      echo "PASS,initial_DN_IP=${initial_dn_ip},status=Running" >> "${evidence_out}"
   else
      echo "FAIL,initial_DN_IP=${initial_dn_ip},status_not_Running_or_missing" >> "${evidence_out}"
      assertion_fail=$((assertion_fail+1))
   fi
done < <(head -n ${initial_dn_num} "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sed '/^$/d')

while IFS=, read -r dn_id dn_ip dn_status
do
   local metadata_absent=PASS
   local region_absent=PASS
   if awk -F '|' -v target_id="${dn_id}" '$0 !~ /^\+/ {id=$2; gsub(/^[ \t]+|[ \t]+$/, "", id); if (id==target_id) found=1} END {exit(found ? 0 : 1)}' "${show_dn_out}";then
      metadata_absent=FAIL
      assertion_fail=$((assertion_fail+1))
   fi
   if awk -F '|' -v target_id="${dn_id}" '$0 !~ /^\+/ {id=$8; gsub(/^[ \t]+|[ \t]+$/, "", id); if (id==target_id) found=1} END {exit(found ? 0 : 1)}' "${show_region_out}";then
      region_absent=FAIL
      assertion_fail=$((assertion_fail+1))
   fi
   echo "${metadata_absent},DN=${dn_id},IP=${dn_ip},metadata_absent" >> "${evidence_out}"
   echo "${region_absent},DN=${dn_id},IP=${dn_ip},show_regions_replica_absent" >> "${evidence_out}"
done < "${new_dn_target_file}"

cat "${evidence_out}"
cp "${show_cluster_out}" "${cur_dir}/show_cluster_5c12d_final_evidence.out"
if [[ ${assertion_fail} -gt 0 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}final 5C12D/removed metadata/region assertion failed (${assertion_fail} checks)."
   return 1
fi
log "INFO" "最终集群及逐节点元数据/Region 断言全部通过，证据: ${evidence_out}"
}
function verify_benchmark_healthy_before_stop()
{
local bad_count=0
local host
for host in "${bm1_ip}" "${bm2_ip}"
do
   if ! ssh root@${host} "pgrep -af '[s]tart_bm_now_no_limit.sh ${arg}' >/dev/null && ! grep -h ERROR ${bm_dir}/${arg}_bm*out 2>/dev/null | grep -q .";then
      bad_count=$((bad_count+1))
      log "ERROR" "缩容完成时 benchmark 异常或进程已退出: ${host}"
   else
      log "INFO" "缩容完成时 benchmark 仍在运行且未发现 ERROR: ${host}"
   fi
done
if [[ ${bad_count} -gt 0 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}${bad_count} benchmark hosts unhealthy after remove."
   return 1
fi
}
function verify_removed_dn_data_cleared()
{
collect_remove_target_data "${new_dn_after_data_file}" "after_remove"
local bad_count=0
local comparison_file=${cur_dir}/remove_8dn_data_before_after_evidence.out
: > "${comparison_file}"
while IFS=, read -r dn_id dn_ip size_kb file_count tsfile_count object_file_count
do
   local before_stat
   before_stat=$(awk -F ',' -v target_id="${dn_id}" '$1==target_id {print "size_kb=" $3 ",file_count=" $4 ",tsfile_count=" $5 ",object_file_count=" $6}' "${new_dn_before_data_file}")
   if [[ "${file_count}" != "0" || "${tsfile_count}" != "0" || "${object_file_count}" != "0" ]];then
      bad_count=$((bad_count+1))
      log "ERROR" "被移除 DN ${dn_id} ${dn_ip} 数据未清空: size_kb=${size_kb}, files=${file_count}, tsfiles=${tsfile_count}, object_files=${object_file_count}"
      echo "FAIL,DN=${dn_id},IP=${dn_ip},before:${before_stat},after:size_kb=${size_kb},file_count=${file_count},tsfile_count=${tsfile_count},object_file_count=${object_file_count}" >> "${comparison_file}"
   else
      log "INFO" "被移除 DN ${dn_id} ${dn_ip} 数据已清空: files=0, tsfiles=0, object_files=0"
      echo "PASS,DN=${dn_id},IP=${dn_ip},before:${before_stat},after:size_kb=${size_kb},file_count=0,tsfile_count=0,object_file_count=0" >> "${comparison_file}"
   fi
done < "${new_dn_after_data_file}"
cat "${comparison_file}"
if [[ ${bad_count} -gt 0 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}${bad_count} removed DataNodes still contain data files."
   return 1
fi
log "INFO" "8 个缩容 DN 的 REMOVE 前后数据目录证据: ${comparison_file}"
v_warnMessage="${v_warnMessage}REMOVE DATANODE 8 nodes succeeded; removed DN data files all cleared."
}
function check_region_balance()
{
local region_out=${cur_dir}/check_balance_show_regions.out
local dn_out=${cur_dir}/check_balance_show_datanodes.out
local running_dn_file=${cur_dir}/running_dn_id_ip.out
local balance_dir=${cur_dir}/${testdb}/balance_check
local summary_file=${balance_dir}/data_region_balance_summary.out
mkdir -p "${balance_dir}"

${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;">"${region_out}"
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">"${dn_out}"
grep Running "${dn_out}" | awk -F "|" '{gsub(" ","");print $2","$4}' > "${running_dn_file}"

awk -F '|' '
function trim(s) {
   gsub(/^[ \t]+|[ \t]+$/, "", s)
   return s
}
FNR==NR {
   gsub(/ /, "", $0)
   if ($0 == "") {
      next
   }
   split($0, a, ",")
   dn_order[++dn_num] = a[1]
   dn_ip[a[1]] = a[2]
   next
}
/^\+/ {next}
NF < 8 {next}
{
   region_type = trim($3)
   data_node_id = trim($8)
   role_type = trim($12)
   if (region_type == "DataRegion" && data_node_id != "") {
      total_count[data_node_id]++
      if (role_type == "Leader") {
         leader_count[data_node_id]++
      } else if (role_type == "Follower") {
         follower_count[data_node_id]++
      }
   }
}
END {
   print "DataNodeId,ClientRpcIp,LeaderCount,FollowerCount,TotalDataRegionCount"
   for (i = 1; i <= dn_num; i++) {
      data_node_id = dn_order[i]
      print data_node_id "," dn_ip[data_node_id] "," (leader_count[data_node_id] + 0) "," (follower_count[data_node_id] + 0) "," (total_count[data_node_id] + 0)
   }
}' "${running_dn_file}" "${region_out}" > "${summary_file}"

local min_total=-1
local max_total=-1
local min_leader=-1
local max_leader=-1
local min_follower=-1
local max_follower=-1
while IFS=, read -r dn_id dn_ip leader_count follower_count total_count
do
   [[ -z "${dn_id}" || "${dn_id}" == "DataNodeId" ]] && continue
   if [[ ${min_total} -lt 0 || ${total_count} -lt ${min_total} ]];then
      min_total=${total_count}
   fi
   if [[ ${max_total} -lt 0 || ${total_count} -gt ${max_total} ]];then
      max_total=${total_count}
   fi
   if [[ ${min_leader} -lt 0 || ${leader_count} -lt ${min_leader} ]];then
      min_leader=${leader_count}
   fi
   if [[ ${max_leader} -lt 0 || ${leader_count} -gt ${max_leader} ]];then
      max_leader=${leader_count}
   fi
   if [[ ${min_follower} -lt 0 || ${follower_count} -lt ${min_follower} ]];then
      min_follower=${follower_count}
   fi
   if [[ ${max_follower} -lt 0 || ${follower_count} -gt ${max_follower} ]];then
      max_follower=${follower_count}
   fi
done < "${summary_file}"

local diff_total=$((max_total-min_total))
local diff_leader=$((max_leader-min_leader))
local diff_follower=$((max_follower-min_follower))
log "INFO" "DataRegion 聚合分布检查结果已保存: ${summary_file}, total(max=${max_total},min=${min_total},diff=${diff_total}), leader(max=${max_leader},min=${min_leader},diff=${diff_leader}), follower(max=${max_follower},min=${min_follower},diff=${diff_follower})"
if [[ ${diff_total} -gt 1 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}DataRegion total count not balanced."
fi
if [[ ${diff_leader} -gt 1 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}DataRegion leader count not balanced."
fi
if [[ ${diff_follower} -gt 1 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}DataRegion follower count not balanced."
fi
}
function collect_dn_disk_usage()
{
local phase_tag=${1:-current}
local node_limit=${2:-0}
local disk_dir=${cur_dir}/${testdb}/disk_usage
local disk_ts
disk_ts=$(date +%Y%m%d_%H%M%S)
local summary_file=${disk_dir}/${disk_ts}_${phase_tag}_datanode_disk_usage.out
mkdir -p "${disk_dir}"

local pids=()
local disk_usage_node_file=${nodeinfo_dir}/datanode.txt
local disk_usage_target_file=${disk_dir}/targets_${disk_ts}_${phase_tag}.list
if [[ ${node_limit} -gt 0 ]];then
   head -n ${node_limit} "${disk_usage_node_file}" | sed 's/ //g' | sed '/^$/d' > "${disk_usage_target_file}"
else
   sed 's/ //g' "${disk_usage_node_file}" | sed '/^$/d' > "${disk_usage_target_file}"
fi

while read -r node_ip
do
   [[ -z "${node_ip}" ]] && continue
   {
      local stat_time
      stat_time=$(date +'%Y-%m-%d %H:%M:%S')
      local size_kb
      size_kb=$(ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" "du -sk ${db_dir}/data/datanode 2>/dev/null | cut -f1" 2>/dev/null)
      if [[ $? -eq 0 && "${size_kb}" =~ ^[0-9]+$ ]];then
         echo "${node_ip},${stat_time},${size_kb}"
      else
         echo "${node_ip},${stat_time},ERROR"
      fi
   } > "${disk_dir}/${disk_ts}_${phase_tag}_sample_${node_ip}.out" &
   pids+=($!)
done < "${disk_usage_target_file}"

for pid in "${pids[@]}"
do
   wait "${pid}"
done

cat "${disk_dir}/${disk_ts}_${phase_tag}_sample_"*.out | sort -t ',' -k3,3n > "${summary_file}"

local min_kb=-1
local max_kb=-1
local min_ip=""
local max_ip=""
local sum_kb=0
local sample_count=0
while IFS=, read -r node_ip stat_time size_kb
do
   if [[ "${size_kb}" =~ ^[0-9]+$ ]];then
      sum_kb=$((sum_kb+size_kb))
      sample_count=$((sample_count+1))
      if [[ ${min_kb} -lt 0 || ${size_kb} -lt ${min_kb} ]];then
         min_kb=${size_kb}
         min_ip=${node_ip}
      fi
      if [[ ${max_kb} -lt 0 || ${size_kb} -gt ${max_kb} ]];then
         max_kb=${size_kb}
         max_ip=${node_ip}
      fi
   else
      let fail_flag++
      v_warnMessage="${v_warnMessage}collect disk usage failed on ${node_ip}."
   fi
done < "${summary_file}"

if [[ ${sample_count} -gt 0 ]];then
   local avg_kb
   local diff_kb
   local diff_pct
   avg_kb=$((sum_kb/sample_count))
   diff_kb=$((max_kb-min_kb))
   diff_pct=$(awk -v diff_kb="${diff_kb}" -v avg_kb="${avg_kb}" 'BEGIN { if (avg_kb <= 0) { printf "0.00" } else { printf "%.2f", diff_kb * 100 / avg_kb } }')
   log "INFO" "${sample_count} 个存量 DN 磁盘占用统计已保存(${phase_tag}): ${summary_file}, avg_kb=${avg_kb}, max_kb=${max_kb}, max_ip=${max_ip}, min_kb=${min_kb}, min_ip=${min_ip}, diff_kb=${diff_kb}, diff_pct=${diff_pct}%"
   v_warnMessage="${v_warnMessage}DN data size summary(${phase_tag}): avg_kb=${avg_kb}, max_kb=${max_kb}, max_ip=${max_ip}, min_kb=${min_kb}, min_ip=${min_ip}, diff_kb=${diff_kb}, diff_pct=${diff_pct}%."
else
   log "WARN" "存量 DN 磁盘占用统计为空(${phase_tag}): ${summary_file}"
   v_warnMessage="${v_warnMessage}DN data size summary(${phase_tag}) is empty."
fi
}
function prepare_batch_region_plan()
{
local show_region_out=${cur_dir}/show_regions_before_batch_extend.out
local candidate_file=${cur_dir}/batch_region_candidates.out

${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "SHOW REGIONS;">"${show_region_out}" || return 1
awk -F '|' '
/^\+/ {next}
NF >= 8 {
  id=$2; type=$3; status=$4; database=$5
  gsub(/^[ \t]+|[ \t]+$/, "", id)
  gsub(/^[ \t]+|[ \t]+$/, "", type)
  gsub(/^[ \t]+|[ \t]+$/, "", status)
  gsub(/^[ \t]+|[ \t]+$/, "", database)
  if (id ~ /^[0-9]+$/ && status == "Running" && database !~ /^root[.]__audit/ && !(id in seen)) {
    seen[id]=1
    print id "," type "," database
  }
}' "${show_region_out}" > "${candidate_file}"

local schema_ids
local data_ids
schema_ids=$(awk -F ',' '$2=="SchemaRegion" {print $1}' "${candidate_file}" | paste -sd, -)
data_ids=$(awk -F ',' '$2=="DataRegion" {print $1}' "${candidate_file}" | paste -sd, -)
if [[ -z "${schema_ids}" || -z "${data_ids}" ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}no SchemaRegion/DataRegion candidate for batch EXTEND."
   log "ERROR" "批量 EXTEND 需要至少一个非审计 SchemaRegion 和一个 DataRegion"
   return 1
fi

: > "${batch_region_plan_file}"
local index=0
local schema_count
local data_count
schema_count=$(awk -F ',' '$2=="SchemaRegion" {n++} END {print n+0}' "${candidate_file}")
data_count=$(awk -F ',' '$2=="DataRegion" {n++} END {print n+0}' "${candidate_file}")
if [[ ! "${batch_region_count_per_dn}" =~ ^[0-9]+$ || ${batch_region_count_per_dn} -lt 2 ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}BATCH_REGION_COUNT_PER_DN must be an integer >= 2."
   log "ERROR" "BATCH_REGION_COUNT_PER_DN=${batch_region_count_per_dn} 非法，至少需要 2"
   return 1
fi
local target_count=$((target_dn_num-initial_dn_num))
local schema_used_count=${schema_count}
[[ ${schema_used_count} -gt ${target_count} ]] && schema_used_count=${target_count}
local required_data_count=$((target_count*batch_region_count_per_dn-schema_used_count))
if [[ ${data_count} -lt ${required_data_count} ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}not enough unique DataRegion candidates for batch EXTEND."
   log "ERROR" "批量 EXTEND 需要 ${required_data_count} 个唯一 DataRegion，当前只有 ${data_count} 个"
   return 1
fi
local data_cursor=1
while IFS=, read -r dn_id dn_ip dn_status
do
   [[ -z "${dn_id}" ]] && continue
   local region_ids
   local data_offset
   local data_needed=${batch_region_count_per_dn}
   region_ids=""
   # 每个 SchemaRegion 只提交一次，避免前一轮 AddRegionPeerProcedure 未完成时被后续 DN 并发复用。
   if [[ ${index} -lt ${schema_used_count} ]];then
      local schema_region
      schema_region=$(awk -F ',' -v n=$((index+1)) '$2=="SchemaRegion" {i++; if(i==n){print $1; exit}}' "${candidate_file}")
      region_ids=${schema_region}
      data_needed=$((batch_region_count_per_dn-1))
   fi
   for ((data_offset=0; data_offset<data_needed; data_offset++))
   do
      local data_region
      data_region=$(awk -F ',' -v n=${data_cursor} '$2=="DataRegion" {i++; if(i==n){print $1; exit}}' "${candidate_file}")
      if [[ -n "${region_ids}" ]];then
         region_ids=${region_ids},${data_region}
      else
         region_ids=${data_region}
      fi
      data_cursor=$((data_cursor+1))
   done
   # RegionId 列表本身包含逗号，因此计划文件使用 | 分隔字段。
   echo "${dn_id}|${dn_ip}|${region_ids}" >> "${batch_region_plan_file}"
   index=$((index+1))
done < "${new_dn_target_file}"

if [[ $(wc -l < "${batch_region_plan_file}") -ne $((target_dn_num-initial_dn_num)) ]];then
   let fail_flag++
   v_warnMessage="${v_warnMessage}batch region plan target count invalid."
   return 1
fi
log "INFO" "批量 Region 计划（全局唯一，DataNodeId|IP|RegionIds, count_per_dn=${batch_region_count_per_dn}）: $(tr '\n' ';' < "${batch_region_plan_file}")"
}

function wait_batch_region_state()
{
local expected_state=$1
local begin_ts
begin_ts=$(date +%s)
local region_out=${cur_dir}/show_regions_wait_batch_${expected_state}.out
local migration_out=${cur_dir}/show_migrations_wait_batch_${expected_state}.out

while true
do
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "SHOW REGIONS;">"${region_out}"
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "SHOW MIGRATIONS;">"${migration_out}"
   local mismatch=0
   local checked=0
   while IFS='|' read -r dn_id dn_ip region_ids
   do
      local region_id
      for region_id in ${region_ids//,/ }
      do
         checked=$((checked+1))
         if awk -F '|' -v rid="${region_id}" -v did="${dn_id}" '
           $0 !~ /^\+/ {r=$2; s=$4; d=$8; gsub(/ /,"",r); gsub(/ /,"",s); gsub(/ /,"",d); if(r==rid && d==did && s=="Running") found=1}
           END {exit(found ? 0 : 1)}' "${region_out}";then
            [[ "${expected_state}" == "present" ]] || mismatch=$((mismatch+1))
         else
            [[ "${expected_state}" == "absent" ]] || mismatch=$((mismatch+1))
         fi
      done
   done < "${batch_region_plan_file}"
   local migration_rows
   migration_rows=$(count_cli_table_rows "${migration_out}" "ProcedureId")
   log "INFO" "等待批量 Region 状态=${expected_state}: checked=${checked}, mismatch=${mismatch}, migration_rows=${migration_rows}"
   if [[ ${mismatch} -eq 0 && ${migration_rows} -eq 0 ]];then
      cp "${region_out}" "${cur_dir}/show_regions_batch_${expected_state}_evidence.out"
      return 0
   fi
   if [[ $(( $(date +%s)-begin_ts )) -gt ${batch_region_timeout_sec} ]];then
      let fail_flag++
      v_warnMessage="${v_warnMessage}wait batch region ${expected_state} timeout."
      return 1
   fi
   sleep ${batch_region_poll_sec}
done
}

function execute_batch_extend_regions()
{
local evidence=${cur_dir}/batch_extend_region_submit.out
: > "${evidence}"
while IFS='|' read -r dn_id dn_ip region_ids
do
   local sql="EXTEND REGION ${region_ids} TO ${dn_id};"
   local out=${cur_dir}/batch_extend_region_dn_${dn_id}.out
   log "INFO" "执行 ${sql}"
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "${sql}">"${out}" 2>&1
   local submit_rc=$?
   cat "${out}" | tee -a "${evidence}"
   # 不同版本 CLI 的成功输出有两种格式：批量提交统计，或通用 executed successfully。
   # 这里只判断提交是否被明确接受，最终是否生效由 wait_batch_region_state 校验实际拓扑。
   if [[ ${submit_rc} -ne 0 ]] || \
      grep -Eqi 'Exception|ERROR|failed to execute|failed to submit:[[:space:]]*[1-9][0-9]*' "${out}" || \
      ! grep -Eqi 'successfully submitted:[[:space:]]*[1-9][0-9]*|statement is executed successfully|^[[:space:]]*success[[:space:]]*$' "${out}";then
      let fail_flag++
      v_warnMessage="${v_warnMessage}batch EXTEND failed on DN ${dn_id}."
      return 1
   fi
done < "${batch_region_plan_file}"
wait_batch_region_state present
}

function execute_batch_remove_regions()
{
local evidence=${cur_dir}/batch_remove_region_submit.out
: > "${evidence}"
while IFS='|' read -r dn_id dn_ip region_ids
do
   local sql="REMOVE REGION ${region_ids} FROM ${dn_id};"
   local out=${cur_dir}/batch_remove_region_dn_${dn_id}.out
   log "INFO" "执行 ${sql}"
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "${sql}">"${out}" 2>&1
   local submit_rc=$?
   cat "${out}" | tee -a "${evidence}"
   if [[ ${submit_rc} -ne 0 ]] || \
      grep -Eqi 'Exception|ERROR|failed to execute|failed to submit:[[:space:]]*[1-9][0-9]*' "${out}" || \
      ! grep -Eqi 'successfully submitted:[[:space:]]*[1-9][0-9]*|statement is executed successfully|^[[:space:]]*success[[:space:]]*$' "${out}";then
      let fail_flag++
      v_warnMessage="${v_warnMessage}batch REMOVE REGION failed on DN ${dn_id}."
      return 1
   fi
done < "${batch_region_plan_file}"
wait_batch_region_state absent
}

function verify_expand_targets_empty_before_remove_datanode()
{
local region_out=${cur_dir}/show_regions_before_remove_empty_8dn.out
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "SHOW REGIONS;">"${region_out}" || return 1
local refs=0
while IFS=, read -r dn_id dn_ip dn_status
do
   if awk -F '|' -v did="${dn_id}" '$0 !~ /^\+/ {d=$8; gsub(/ /,"",d); if(d==did) found=1} END {exit(found ? 0 : 1)}' "${region_out}";then
      refs=$((refs+1))
      log "INFO" "扩容 DN ${dn_id} ${dn_ip} 仍有非计划 Region，将交由 REMOVE DATANODE 迁移"
   else
      log "INFO" "扩容 DN ${dn_id} ${dn_ip} 已为空 Region"
   fi
done < "${new_dn_target_file}"
if [[ ${refs} -gt 0 ]];then
   v_warnMessage="${v_warnMessage}${refs} expanded DNs contain dynamic regions before REMOVE DATANODE; migration is expected."
fi
cp "${region_out}" "${cur_dir}/show_regions_empty_8dn_evidence.out"
return 0
}

function testcase()
{
	create_user
	start_bm
	wait_for_expand_window \
	   ${pre_expand_min_runtime_sec} \
	   ${expand_window_min_sec_to_next_partition} \
	   ${expand_window_max_sec_to_next_partition} \
	   ${expand_window_poll_sec} || return 1
	# benchmark 已持续写入并生成业务 Region 后，再执行依赖真实 Region 拓扑的 smoke。
	if [[ ! -x "${batch_region_smoke_helper}" ]];then
	   chmod +x "${batch_region_smoke_helper}" 2>/dev/null || true
	fi
	log "INFO" "执行 V2-541 批量 Region 语法/语义/权限/审计短用例"
	EVIDENCE_DIR="${cur_dir}/${testdb}/batch_region_smoke_evidence" TEST_CONF_FILE="${conf_file}" \
	   bash "${batch_region_smoke_helper}" || {
	      let fail_flag++
	      v_warnMessage="${v_warnMessage}batch region syntax/auth/audit smoke failed."
	      return 1
	   }
	record_table_regions "before_expand_after_dynamic_window_write"
	run_expand_to_20d || return 1

	${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show cluster;">${cur_dir}/tmp.out
	cat ${cur_dir}/tmp.out
	check_res Running ${total_node_num} "show cluster expect ${total_node_num} Running after expand but "
	exec_jstack
	prepare_remove_8dn_targets || return 1
	record_table_regions "after_expand_before_batch_extend"
	prepare_batch_region_plan || return 1
	execute_batch_extend_regions || return 1
	record_table_regions "after_batch_extend"
	execute_batch_remove_regions || return 1
	record_table_regions "after_batch_remove_region"
	verify_expand_targets_empty_before_remove_datanode || return 1
	collect_remove_target_data "${new_dn_before_data_file}" "before_remove" || return 1
	: > "${removed_dn_file}"
	local remove_batch_no
	for remove_batch_no in 1 2 3 4
	do
		select_non_conflicting_remove_pair "${remove_batch_no}" || return 1
		execute_remove_2dn "${remove_batch_no}" || return 1
		wait_remove_2dn_done "${remove_batch_no}" || return 1
	done
	if [[ $(wc -l < "${removed_dn_file}") -ne $((target_dn_num-initial_dn_num)) ]];then
		let fail_flag++
		v_warnMessage="${v_warnMessage}only $(wc -l < "${removed_dn_file}") of 8 expanded DNs were removed."
		return 1
	fi
	local remove_assertion_failed=0
	verify_remove_8dn_final_state || remove_assertion_failed=1
	verify_removed_dn_data_cleared || remove_assertion_failed=1
	[[ ${remove_assertion_failed} -eq 0 ]] || return 1
	verify_benchmark_healthy_before_stop || return 1
	stop_bm
	log "INFO" "开始检查 sync lag 并等待同步完成"
	wait_for_monitor_sync_completion || return 1
	local consistency_failed=0
	verify_aggregate_consistency_with_single_dn_stop || consistency_failed=1
	log "INFO" "单 DN 轮停校验结束，等待所有已恢复 DN 的 sync lag 再次归零"
	wait_for_monitor_sync_completion || return 1
	[[ ${consistency_failed} -eq 0 ]] || return 1
	record_table_regions "after_remove_8dn"

		# stop cluster
	sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1 || return 1
	# 8 个被缩容 DN 已由 verify_removed_dn_data_cleared 单独取证；此处仅统计仍在集群中的初始 12 个 DN。
	collect_dn_disk_usage "after_stop_cluster_remaining_12dn" "${initial_dn_num}"
		check_log
		#backup logs
	        v_tc_name_pre=`echo ${SCRIPT_NAME}|awk -F '.' '{print $1}'`
	        v_backup_time=`date +"%Y_%m_%d_%H_%M_%S"`
sh -x ${clean_env_dir}/backup_cluster_logs.sh ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
#sh -x ${clean_env_dir}/backup_cluster_cn_data ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
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
   v_warnMessage_sql=$(printf '%s' "${v_warnMessage}" | tr -d '' | tr '
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

}
write_result
