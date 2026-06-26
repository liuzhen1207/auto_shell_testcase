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
root_pw=$(grep "^root_pw=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
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
ssl_str=""
backup_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensus"
v_sec_super_user="root"
v_sys_super_user="root"
v_jstack_num=0
arg=""
enable_start_db=1
enable_start_bm=1
skip_stop_cluster=${SKIP_STOP_CLUSTER:-0}
backup_pipe_expected_running=2
backup_pipe_check_interval=10
backup_pipe_create_timeout=600
backup_pipe_finish_timeout=0
backup_progress_sample_interval=30
time_partition_interval_ms=3600000
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
backup_target_host="172.20.70.119"
backup_target_user="root"
backup_target_pw="Iotdb@2026"
backup_target_port=22
backup_remote_root="/data/iotdb/object_backup/${SCRIPT_NAME%.*}_$(date +%Y%m%d_%H%M%S)"
restore_stage_root="/data/iotdb/object_backup/${SCRIPT_NAME%.*}"
restore_host="172.20.70.119"
verify_root="${cur_dir}/backup_verify"
usr_backup_host="172.20.70.106"
tod_backup_host="172.20.70.107"
java_home_remote="/usr/local/jdk-17.0.12"
db_cli_pw_arg=""
usr_window_start_ms=""
usr_window_end_ms=""
usr_window_start_iso=""
usr_window_end_iso=""
tod_window_start_ms=""
tod_window_end_ms=""
tod_window_start_iso=""
tod_window_end_iso=""
verify_dir=""
usr_object_sample_stream=""
usr_object_sample_sql=""
tod_object_sample_stream=""
tod_object_sample_sql=""

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
   v_err5=`ssh ${os_user_name}@${line} "grep \"ArrayIndexOutOfBoundsException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err6=`ssh ${os_user_name}@${line} "grep \"Alter timeseries .* data type from null to\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err7=`ssh ${os_user_name}@${line} "grep \"StatisticsClassException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err8=`ssh ${os_user_name}@${line} "grep \"BufferUnderflowException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err9=`ssh ${os_user_name}@${line} "grep \"NegativeArraySizeException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err10=`ssh ${os_user_name}@${line} "grep \"is not in tsFileMetaData\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err11=`ssh ${os_user_name}@${line} "grep \"The memory cost to be released is larger\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err12=`ssh ${os_user_name}@${line} "grep \"tsfile error\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err13=`ssh ${os_user_name}@${line} "grep \"which has not released all memory\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err14=`ssh ${os_user_name}@${line} "grep \"Error while reading timeseries metadata\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err15=`ssh ${os_user_name}@${line} "grep \"OBJECT statistics does not support: last\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err16=`ssh ${os_user_name}@${line} "grep \"which has not released all memory\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_dn_total_err=$((v_err+v_err2+v_err3+v_err4+v_err5+v_err6+v_err7+v_err8+v_err9+v_err10+v_err11+v_err12+v_err13+v_err14+v_err15+v_err16))

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
         echo "Stopping takes too long."
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
	# database no 
#${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "CREATE DATABASE usr_sod0 WITH (ttl=10800000);">${cur_dir}/tmp.out
#check_res success 1 "CREATE DATABASE with ttl "
#${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "CREATE DATABASE tod_sod0 WITH (ttl=10800000);">${cur_dir}/tmp.out
#check_res success 1 "CREATE DATABASE with ttl "

	create_user_if_needed() {
	    local user_name=$1
	    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER ${user_name} 'TimechoDB@2021';">${cur_dir}/tmp.out
	    if grep -q "User ${user_name} already exists" "${cur_dir}/tmp.out"; then
	        log "INFO" "用户 ${user_name} 已存在，跳过创建"
	        return 0
	    fi
	    check_res success 1 "CREATE USER ${user_name}"
	}

	create_user_if_needed "rainer"
	create_user_if_needed "colder"
	create_user_if_needed "winder"
	create_user_if_needed "sunner"
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

echo "==== 后台启动 BM 进程 ===="
log "INFO" "BM 启动请求时间: $(date +'%Y-%m-%d %H:%M:%S')，arg=${arg}"

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
}
function query_running_pipe_count()
{
    local pipe_out="${cur_dir}/show_pipes.out"
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${db_cli_pw_arg} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show pipes;">"${pipe_out}" 2>&1 || return 1
    tr -d '\r' < "${pipe_out}" | awk -F'|' '
        {
            state=$4
            gsub(/[[:space:]]/, "", state)
            if (toupper(state) == "RUNNING") {
                count++
            }
        }
        END {
            print count + 0
        }'
}
function log_pipe_progress_snapshot()
{
    tr -d '\r' < "${cur_dir}/show_pipes.out" | awk -F'|' '
        NR <= 2 || $0 ~ /^\+/ || /Total line number/ || /It costs/ {next}
        {
            id=$2
            state=$4
            remaining=$8
            eta=$9
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", state)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", remaining)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", eta)
            if (id != "") {
                print id "," state "," remaining "," eta
            }
        }' | while IFS=, read -r pipe_id pipe_state pipe_remaining pipe_eta
    do
        log "INFO" "Pipe详情: ${pipe_id} state=${pipe_state} remaining=${pipe_remaining} eta=${pipe_eta}"
    done
}
function query_remote_backup_top_file_count()
{
    ssh -o StrictHostKeyChecking=no ${backup_target_user}@${backup_target_host} "
usr_count=\$(find '${backup_remote_root}/usr_sod0' -maxdepth 1 -type f 2>/dev/null | wc -l)
tod_count=\$(find '${backup_remote_root}/tod_sod0' -maxdepth 1 -type f 2>/dev/null | wc -l)
echo \"\${usr_count},\${tod_count}\"
" 2>/dev/null
}
function wait_backup_pipes_running()
{
    local usr_pid=$1
    local tod_pid=$2
    local start_ts
    start_ts=$(date +%s)
    while true
    do
        local running_pipe_count
        if ! running_pipe_count=$(query_running_pipe_count); then
            log "WARN" "执行 show pipes 失败，${backup_pipe_check_interval} 秒后重试"
        else
            log "INFO" "当前 show pipes Running 数量: ${running_pipe_count}"
            log_pipe_progress_snapshot
            if [[ ${running_pipe_count} -eq ${backup_pipe_expected_running} ]]; then
                log "INFO" "备份任务创建成功：show pipes 为 Running ${backup_pipe_expected_running} 条"
                return 0
            fi
        fi

        if ! kill -0 ${usr_pid} 2>/dev/null && ! kill -0 ${tod_pid} 2>/dev/null; then
            log "ERROR" "备份进程已退出，但 show pipes 未达到 Running ${backup_pipe_expected_running} 条"
            [[ -f "${cur_dir}/show_pipes.out" ]] && cat "${cur_dir}/show_pipes.out"
            return 1
        fi

        local now_ts
        now_ts=$(date +%s)
        if [[ $((now_ts - start_ts)) -ge ${backup_pipe_create_timeout} ]]; then
            log "ERROR" "等待备份任务创建超时：show pipes 未达到 Running ${backup_pipe_expected_running} 条"
            [[ -f "${cur_dir}/show_pipes.out" ]] && cat "${cur_dir}/show_pipes.out"
            return 1
        fi
        sleep ${backup_pipe_check_interval}
    done
}
function wait_backup_pipes_finished()
{
    local start_ts
    local last_progress_check_ts=0
    start_ts=$(date +%s)
    while true
    do
        local running_pipe_count
        if ! running_pipe_count=$(query_running_pipe_count); then
            log "WARN" "执行 show pipes 失败，${backup_pipe_check_interval} 秒后重试"
        else
            log "INFO" "当前 show pipes Running 数量: ${running_pipe_count}"
            log_pipe_progress_snapshot
            if [[ ${running_pipe_count} -eq 0 ]]; then
                log "INFO" "备份任务执行完成：show pipes 已无 Running 条目"
                return 0
            fi
        fi

        local now_ts
        now_ts=$(date +%s)
        if [[ ${running_pipe_count:-0} -gt 0 && $((now_ts - last_progress_check_ts)) -ge ${backup_progress_sample_interval} ]]; then
            local top_file_stats
            if top_file_stats=$(query_remote_backup_top_file_count); then
                local usr_top_files=${top_file_stats%%,*}
                local tod_top_files=${top_file_stats##*,}
                log "INFO" "远端备份顶层 tsfile 数量: usr_sod0=${usr_top_files}, tod_sod0=${tod_top_files}"
            else
                log "WARN" "检查远端备份目录顶层 tsfile 数量失败"
            fi
            last_progress_check_ts=${now_ts}
        fi
        if [[ ${backup_pipe_finish_timeout} -gt 0 && $((now_ts - start_ts)) -ge ${backup_pipe_finish_timeout} ]]; then
            log "ERROR" "等待备份任务执行完成超时：show pipes 仍存在 Running 条目"
            [[ -f "${cur_dir}/show_pipes.out" ]] && cat "${cur_dir}/show_pipes.out"
            return 1
        fi
        sleep ${backup_pipe_check_interval}
    done
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

pgrep -af \"start_bm_now_no_limit.sh ${arg}\" >/dev/null && launcher_alive=1

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

pgrep -af \"start_bm_now_no_limit.sh ${arg}\" >/dev/null && launcher_alive=1

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
function run_table_sql()
{
    local db_name=$1
    local sql_text=$2
    local out_file=$3
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${db_cli_pw_arg} ${ssl_str} -h ${query_ip} -sql_dialect table -e "use ${db_name}; ${sql_text}">${out_file} 2>&1
    return $?
}
function normalize_query_output()
{
    local in_file=$1
    local out_file=$2
    sed '/^It costs /d' "${in_file}" > "${out_file}"
}
function query_output_has_rows()
{
    local in_file=$1
    ! grep -Eq '^[[:space:]]*Empty set\.[[:space:]]*$' "${in_file}"
}
function query_output_is_empty()
{
    local in_file=$1
    grep -Eq '^[[:space:]]*Empty set\.[[:space:]]*$' "${in_file}"
}
function extract_first_device_id()
{
    local in_file=$1
    awk -F'|' '
    /^[[:space:]]*\|/ {
        field=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", field)
        if (field != "" && field != "device_id") {
            print field
            exit
        }
    }' "${in_file}"
}
function build_group_count_sql()
{
    local table_name=$1
    local window_start_ms=$2
    local window_end_ms=$3
    echo "select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9),count(s_10),count(s_11),count(s_12) from ${table_name} where time >= ${window_start_ms} and time <= ${window_end_ms} group by device_id order by device_id;"
}
function build_object_sample_sql()
{
    local table_name=$1
    local window_start_ms=$2
    local window_end_ms=$3
    local device_id=$4
    echo "select time,device_id,read_object(s_12) from ${table_name} where time >= ${window_start_ms} and time <= ${window_end_ms} and device_id='${device_id}' order by time limit 1;"
}
function capture_object_sample_baseline()
{
    local db_name=$1
    local window_start_ms=$2
    local window_end_ms=$3
    local db_tag=$4

    local idx=0
    while [[ ${idx} -lt 50 ]]
    do
        local device_sql="select device_id from stream_${idx} where time >= ${window_start_ms} and time <= ${window_end_ms} order by device_id,time limit 1;"
        local device_raw_file="${verify_dir}/baseline/${db_tag}_stream_${idx}_object_device.raw"
        local device_out_file="${verify_dir}/baseline/${db_tag}_stream_${idx}_object_device.out"
        local device_id_file="${verify_dir}/baseline/${db_tag}_stream_${idx}_object_device.txt"
        local object_sql=""
        local object_raw_file="${verify_dir}/baseline/${db_tag}_stream_${idx}_object.raw"
        local object_out_file="${verify_dir}/baseline/${db_tag}_stream_${idx}_object.out"
        local device_id=""

        run_table_sql "${db_name}" "${device_sql}" "${device_raw_file}" || return 1
        normalize_query_output "${device_raw_file}" "${device_out_file}"
        if ! query_output_has_rows "${device_out_file}"; then
            log "ERROR" "${db_name}.stream_${idx} 在当前时间窗口内未找到可用于对象校验的设备"
            return 1
        fi

        device_id=$(extract_first_device_id "${device_out_file}")
        if [[ -z "${device_id}" ]]; then
            log "ERROR" "${db_name}.stream_${idx} 无法从查询结果中解析对象校验设备"
            return 1
        fi
        printf '%s\n' "${device_id}" > "${device_id_file}"

        object_sql=$(build_object_sample_sql "stream_${idx}" "${window_start_ms}" "${window_end_ms}" "${device_id}")
        run_table_sql "${db_name}" "${object_sql}" "${object_raw_file}" || return 1
        normalize_query_output "${object_raw_file}" "${object_out_file}"
        if ! query_output_has_rows "${object_out_file}"; then
            log "ERROR" "${db_name}.stream_${idx} 设备 ${device_id} 对象校验结果为空"
            return 1
        fi

        log "INFO" "${db_name}.stream_${idx} 对象校验设备: ${device_id}"
        idx=$((idx + 1))
    done

    return 0
}
function verify_object_sample_after_restore()
{
    local db_name=$1
    local window_start_ms=$2
    local window_end_ms=$3
    local db_tag=$4

    local idx=0
    while [[ ${idx} -lt 50 ]]
    do
        local device_id_file="${verify_dir}/baseline/${db_tag}_stream_${idx}_object_device.txt"
        local device_id=""
        local object_sql=""

        if [[ ! -f "${device_id_file}" ]]; then
            log "ERROR" "缺少对象校验设备记录文件: ${device_id_file}"
            return 1
        fi

        device_id=$(tr -d '\r' < "${device_id_file}")
        if [[ -z "${device_id}" ]]; then
            log "ERROR" "对象校验设备记录为空: ${device_id_file}"
            return 1
        fi

        object_sql=$(build_object_sample_sql "stream_${idx}" "${window_start_ms}" "${window_end_ms}" "${device_id}")
        run_table_sql "${db_name}" "${object_sql}" "${verify_dir}/post_restore/${db_tag}_stream_${idx}_object.raw" || return 1
        normalize_query_output "${verify_dir}/post_restore/${db_tag}_stream_${idx}_object.raw" "${verify_dir}/post_restore/${db_tag}_stream_${idx}_object.out"
        diff -u "${verify_dir}/baseline/${db_tag}_stream_${idx}_object.out" "${verify_dir}/post_restore/${db_tag}_stream_${idx}_object.out" > "${verify_dir}/post_restore/${db_tag}_stream_${idx}_object.diff" || return 1
        idx=$((idx + 1))
    done

    return 0
}
function ms_to_iso()
{
    local ms=$1
    local sec=$((ms / 1000))
    local milli=$((ms % 1000))
    printf "%s.%03d+08:00" "$(TZ=Asia/Shanghai date -d "@${sec}" +"%Y-%m-%dT%H:%M:%S")" "${milli}"
}
function align_to_partition_start_ms()
{
    local input_ms=$1
    echo $(((input_ms / time_partition_interval_ms) * time_partition_interval_ms))
}
function query_min_time_ms()
{
    local db_name=$1
    local table_name=$2
    local out_file="${cur_dir}/min_time_${db_name}_${table_name}.out"
    run_table_sql "${db_name}" "select min(time) from ${table_name};" "${out_file}" || return 1
    local iso_time
    iso_time=$(awk -F'|' '/T[0-9]{2}:/ {gsub(/ /,"",$2); print $2; exit}' "${out_file}")
    if [[ -z "${iso_time}" ]]; then
        return 1
    fi
    date -d "${iso_time}" +%s%3N
}
function wait_backup_window_ready()
{
    local max_wait_seconds=14400
    local start_wait
    start_wait=$(date +%s)
    while true
    do
        usr_min_ms=$(query_min_time_ms "usr_sod0" "stream_0")
        usr_rc=$?
        tod_min_ms=$(query_min_time_ms "tod_sod0" "stream_0")
        tod_rc=$?
        if [[ ${usr_rc} -eq 0 && ${tod_rc} -eq 0 ]]; then
            usr_window_start_ms=$(align_to_partition_start_ms "${usr_min_ms}")
            usr_window_end_ms=$((usr_window_start_ms + time_partition_interval_ms - 1))
            usr_window_start_iso=$(ms_to_iso "${usr_window_start_ms}")
            usr_window_end_iso=$(ms_to_iso "${usr_window_end_ms}")
            tod_window_start_ms=$(align_to_partition_start_ms "${tod_min_ms}")
            tod_window_end_ms=$((tod_window_start_ms + time_partition_interval_ms - 1))
            tod_window_start_iso=$(ms_to_iso "${tod_window_start_ms}")
            tod_window_end_iso=$(ms_to_iso "${tod_window_end_ms}")
            log "INFO" "usr_sod0 min(time): $(ms_to_iso "${usr_min_ms}") (${usr_min_ms})"
            log "INFO" "tod_sod0 min(time): $(ms_to_iso "${tod_min_ms}") (${tod_min_ms})"
            log "INFO" "usr_sod0 首个时间分区窗口: ${usr_window_start_iso} ~ ${usr_window_end_iso}"
            log "INFO" "tod_sod0 首个时间分区窗口: ${tod_window_start_iso} ~ ${tod_window_end_iso}"
            break
        fi
        now_wait=$(date +%s)
        if [[ $((now_wait - start_wait)) -gt ${max_wait_seconds} ]]; then
            log "ERROR" "等待 benchmark 首条数据超时"
            let fail_flag++
            return 1
        fi
        sleep 30
    done

    local ready_ms_usr=$((usr_window_start_ms + 3 * time_partition_interval_ms))
    local ready_ms_tod=$((tod_window_start_ms + 3 * time_partition_interval_ms))
    local ready_ms=${ready_ms_usr}
    if [[ ${ready_ms_tod} -gt ${ready_ms} ]]; then
        ready_ms=${ready_ms_tod}
    fi
    log "INFO" "备份计划触发时间: $(ms_to_iso "${ready_ms}") (${ready_ms})"

    while true
    do
        local now_ms
        now_ms=$(date +%s%3N)
        if [[ ${now_ms} -ge ${ready_ms} ]]; then
            break
        fi
        local remain_seconds=$(((ready_ms - now_ms) / 1000))
        if [[ ${remain_seconds} -le 0 ]]; then
            break
        fi
        log "INFO" "距离第 3 个时间分区结束还剩 ${remain_seconds} 秒，继续等待写入"
        if [[ ${remain_seconds} -gt 300 ]]; then
            sleep 300
        else
            sleep 30
        fi
    done
}
function capture_backup_baseline()
{
    verify_dir="${verify_root}/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "${verify_dir}/baseline" "${verify_dir}/post_delete" "${verify_dir}/post_restore"
    log "INFO" "开始导出前基线查询，时间: $(date +'%Y-%m-%d %H:%M:%S')，结果目录: ${verify_dir}/baseline"

    local idx=0
    while [[ ${idx} -lt 50 ]]
    do
        run_table_sql "usr_sod0" "$(build_group_count_sql "stream_${idx}" "${usr_window_start_ms}" "${usr_window_end_ms}")" "${verify_dir}/baseline/usr_sod0_stream_${idx}_count.raw" || return 1
        normalize_query_output "${verify_dir}/baseline/usr_sod0_stream_${idx}_count.raw" "${verify_dir}/baseline/usr_sod0_stream_${idx}_count.out"
        run_table_sql "tod_sod0" "$(build_group_count_sql "stream_${idx}" "${tod_window_start_ms}" "${tod_window_end_ms}")" "${verify_dir}/baseline/tod_sod0_stream_${idx}_count.raw" || return 1
        normalize_query_output "${verify_dir}/baseline/tod_sod0_stream_${idx}_count.raw" "${verify_dir}/baseline/tod_sod0_stream_${idx}_count.out"
        idx=$((idx + 1))
    done

    capture_object_sample_baseline "usr_sod0" "${usr_window_start_ms}" "${usr_window_end_ms}" "usr_sod0" || return 1
    capture_object_sample_baseline "tod_sod0" "${tod_window_start_ms}" "${tod_window_end_ms}" "tod_sod0" || return 1

    log "INFO" "导出前基线结果已保存到 ${verify_dir}/baseline"
}
function execute_object_backup()
{
    log "INFO" "开始执行对象数据备份，时间: $(date +'%Y-%m-%d %H:%M:%S')，远端目录: ${backup_target_user}@${backup_target_host}:${backup_remote_root}"
    ssh -o StrictHostKeyChecking=no ${backup_target_user}@${backup_target_host} "rm -rf ${backup_remote_root} && mkdir -p ${backup_remote_root}/usr_sod0 ${backup_remote_root}/tod_sod0" >> "${log_file}" 2>&1 || return 1

    ${db_dir}/tools/tsfile-backup.sh \
      --host "${usr_backup_host}" \
      --user root \
      --pw "${root_pw}" \
      --sql_dialect=table \
      --database=usr_sod0 \
      --target="${backup_remote_root}/usr_sod0/" \
      --target_host="${backup_target_host}" \
      --target_host_user="${backup_target_user}" \
      --target_host_pw="${backup_target_pw}" \
      --target_host_port="${backup_target_port}" \
      --start_time "${usr_window_start_iso}" \
      --end_time "${usr_window_end_iso}" \
      --plugin_jar "${db_dir}/pipe_plugin/tsfile-remote-sink-2.0.8-SNAPSHOT-jar-with-dependencies.jar" >> "${log_file}" 2>&1 &
    local usr_backup_pid=$!

    ${db_dir}/tools/tsfile-backup.sh \
      --host "${tod_backup_host}" \
      --user root \
      --pw "${root_pw}" \
      --sql_dialect=table \
      --database=tod_sod0 \
      --target="${backup_remote_root}/tod_sod0/" \
      --target_host="${backup_target_host}" \
      --target_host_user="${backup_target_user}" \
      --target_host_pw="${backup_target_pw}" \
      --target_host_port="${backup_target_port}" \
      --start_time "${tod_window_start_iso}" \
      --end_time "${tod_window_end_iso}" \
      --plugin_jar "${db_dir}/pipe_plugin/tsfile-remote-sink-2.0.8-SNAPSHOT-jar-with-dependencies.jar" >> "${log_file}" 2>&1 &
    local tod_backup_pid=$!

    log "INFO" "对象数据导出已启动，60 秒后尝试抓取一次备份期间 jstack"
    wait_backup_pipes_running ${usr_backup_pid} ${tod_backup_pid} || return 1
    sleep 60
    if kill -0 ${usr_backup_pid} 2>/dev/null || kill -0 ${tod_backup_pid} 2>/dev/null; then
        exec_jstack
    else
        log "INFO" "备份任务在 60 秒内已结束，跳过备份期间 jstack"
    fi

    local backup_failed=0
    wait ${usr_backup_pid} || backup_failed=1
    wait ${tod_backup_pid} || backup_failed=1
    if [[ ${backup_failed} -ne 0 ]]; then
        return 1
    fi
    wait_backup_pipes_finished || return 1

    exec_jstack

    log "INFO" "对象数据导出完成，时间: $(date +'%Y-%m-%d %H:%M:%S')，远端目录 ${backup_target_user}@${backup_target_host}:${backup_remote_root}"
}
function delete_first_hour_data()
{
    log "INFO" "开始删除首个时间分区数据，时间: $(date +'%Y-%m-%d %H:%M:%S')"
    local idx=0
    while [[ ${idx} -lt 50 ]]
    do
        run_table_sql "usr_sod0" "delete from stream_${idx} where time >= ${usr_window_start_ms} and time <= ${usr_window_end_ms};" "${verify_dir}/post_delete/usr_sod0_stream_${idx}_delete.raw" || return 1
        run_table_sql "tod_sod0" "delete from stream_${idx} where time >= ${tod_window_start_ms} and time <= ${tod_window_end_ms};" "${verify_dir}/post_delete/tod_sod0_stream_${idx}_delete.raw" || return 1
        idx=$((idx + 1))
    done

    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "flush;">>${log_file} 2>&1
    sleep 10

    idx=0
    while [[ ${idx} -lt 50 ]]
    do
        run_table_sql "usr_sod0" "$(build_group_count_sql "stream_${idx}" "${usr_window_start_ms}" "${usr_window_end_ms}")" "${verify_dir}/post_delete/usr_sod0_stream_${idx}_count.raw" || return 1
        normalize_query_output "${verify_dir}/post_delete/usr_sod0_stream_${idx}_count.raw" "${verify_dir}/post_delete/usr_sod0_stream_${idx}_count.out"
        query_output_is_empty "${verify_dir}/post_delete/usr_sod0_stream_${idx}_count.out" || return 1

        run_table_sql "tod_sod0" "$(build_group_count_sql "stream_${idx}" "${tod_window_start_ms}" "${tod_window_end_ms}")" "${verify_dir}/post_delete/tod_sod0_stream_${idx}_count.raw" || return 1
        normalize_query_output "${verify_dir}/post_delete/tod_sod0_stream_${idx}_count.raw" "${verify_dir}/post_delete/tod_sod0_stream_${idx}_count.out"
        query_output_is_empty "${verify_dir}/post_delete/tod_sod0_stream_${idx}_count.out" || return 1
        idx=$((idx + 1))
    done

    log "INFO" "首个时间分区数据删除完成，时间: $(date +'%Y-%m-%d %H:%M:%S')，50 张表按 device_id 分组校验均为空"
}
function import_backup_data()
{
    log "INFO" "开始导入备份数据，时间: $(date +'%Y-%m-%d %H:%M:%S')，目标主机: ${restore_host}"
    if [[ "${backup_target_host}" != "${restore_host}" ]]; then
        log "ERROR" "当前脚本仅支持在备份机与导入机相同的场景下原地导入，backup_target_host=${backup_target_host}, restore_host=${restore_host}"
        return 1
    fi
    log "INFO" "使用备份目录原地导入，不复制、不删除原备份数据，源目录: ${backup_remote_root}"

    ssh ${os_user_name}@${restore_host} "export JAVA_HOME=${java_home_remote}; ${db_dir}/tools/import-data.sh -h 172.20.70.119 -p 6667 -u ${db_user_name} -pw ${root_pw} -sql_dialect table -db usr_sod0 -ft tsfile -s ${backup_remote_root}/usr_sod0 -os none -of none -tn 16" >> "${log_file}" 2>&1 &
    local usr_import_pid=$!
    ssh ${os_user_name}@${restore_host} "export JAVA_HOME=${java_home_remote}; ${db_dir}/tools/import-data.sh -h 172.20.70.119 -p 6667 -u ${db_user_name} -pw ${root_pw} -sql_dialect table -db tod_sod0 -ft tsfile -s ${backup_remote_root}/tod_sod0 -os none -of none -tn 16" >> "${log_file}" 2>&1 &
    local tod_import_pid=$!

    log "INFO" "对象数据导入已启动，60 秒后尝试抓取一次导入期间 jstack"
    sleep 60
    if kill -0 ${usr_import_pid} 2>/dev/null || kill -0 ${tod_import_pid} 2>/dev/null; then
        exec_jstack
    else
        log "INFO" "导入任务在 60 秒内已结束，跳过导入期间 jstack"
    fi

    local import_failed=0
    wait ${usr_import_pid} || import_failed=1
    wait ${tod_import_pid} || import_failed=1
    if [[ ${import_failed} -ne 0 ]]; then
        return 1
    fi

    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "flush;">>${log_file} 2>&1
    sleep 10
    exec_jstack
    log "INFO" "备份数据已在 ${restore_host} 本机导入完成，时间: $(date +'%Y-%m-%d %H:%M:%S')"
}
function verify_imported_data()
{
    log "INFO" "开始导入后数据校验，时间: $(date +'%Y-%m-%d %H:%M:%S')"
    local idx=0
    while [[ ${idx} -lt 50 ]]
    do
        run_table_sql "usr_sod0" "$(build_group_count_sql "stream_${idx}" "${usr_window_start_ms}" "${usr_window_end_ms}")" "${verify_dir}/post_restore/usr_sod0_stream_${idx}_count.raw" || return 1
        normalize_query_output "${verify_dir}/post_restore/usr_sod0_stream_${idx}_count.raw" "${verify_dir}/post_restore/usr_sod0_stream_${idx}_count.out"
        diff -u "${verify_dir}/baseline/usr_sod0_stream_${idx}_count.out" "${verify_dir}/post_restore/usr_sod0_stream_${idx}_count.out" > "${verify_dir}/post_restore/usr_sod0_stream_${idx}_count.diff" || return 1

        run_table_sql "tod_sod0" "$(build_group_count_sql "stream_${idx}" "${tod_window_start_ms}" "${tod_window_end_ms}")" "${verify_dir}/post_restore/tod_sod0_stream_${idx}_count.raw" || return 1
        normalize_query_output "${verify_dir}/post_restore/tod_sod0_stream_${idx}_count.raw" "${verify_dir}/post_restore/tod_sod0_stream_${idx}_count.out"
        diff -u "${verify_dir}/baseline/tod_sod0_stream_${idx}_count.out" "${verify_dir}/post_restore/tod_sod0_stream_${idx}_count.out" > "${verify_dir}/post_restore/tod_sod0_stream_${idx}_count.diff" || return 1
        idx=$((idx + 1))
    done

    verify_object_sample_after_restore "usr_sod0" "${usr_window_start_ms}" "${usr_window_end_ms}" "usr_sod0" || return 1
    verify_object_sample_after_restore "tod_sod0" "${tod_window_start_ms}" "${tod_window_end_ms}" "tod_sod0" || return 1

    log "INFO" "导入后 count 与对象内容均和导出前一致，时间: $(date +'%Y-%m-%d %H:%M:%S')"
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
function testcase()
{
	local scenario_failed=0
	create_user || scenario_failed=1
	if [[ ${enable_start_bm} -gt 0 ]]; then
		start_bm || scenario_failed=1
	else
		log "INFO" "ENABLE_START_BM=${enable_start_bm}，跳过启动 BM，使用现有集群数据调试"
	fi
	wait_backup_window_ready || scenario_failed=1
	exec_jstack
	if [[ ${scenario_failed} -eq 0 ]]; then
	    capture_backup_baseline || scenario_failed=1
	fi
	if [[ ${scenario_failed} -eq 0 ]]; then
	    execute_object_backup || scenario_failed=1
	fi
	if [[ ${scenario_failed} -eq 0 ]]; then
	    delete_first_hour_data || scenario_failed=1
	fi
	if [[ ${scenario_failed} -eq 0 ]]; then
	    import_backup_data || scenario_failed=1
	fi
	if [[ ${scenario_failed} -eq 0 ]]; then
	    verify_imported_data || scenario_failed=1
	fi
	if [[ ${scenario_failed} -ne 0 ]]; then
	    let fail_flag++
	    v_warnMessage="${v_warnMessage}backup_restore_verify failed."
	    log "ERROR" "备份恢复场景失败，请检查 ${verify_dir} 和 ${log_file}"
	fi

	log "INFO" "导出、导入、校验流程结束，开始停止 BM 写入进程"
	stop_bm
	wait_logs_sync_done 120
	wait_for_monitor_sync_completion
 #check cluster status
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show cluster;">${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out
check_res Running ${total_node_num} "show cluster expect ${total_node_num} Running but "
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show regions;">${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;">${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out

		# stop cluster
	        if [[ ${skip_stop_cluster} -gt 0 ]]; then
	            log "INFO" "SKIP_STOP_CLUSTER=${skip_stop_cluster}，调试模式跳过停止集群"
	        else
	            sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
	        fi
	check_log
	#backup logs
        v_tc_name_pre=`echo ${SCRIPT_NAME}|awk -F '.' '{print $1}'`
        v_backup_time=`date +"%Y_%m_%d_%H_%M_%S"`
sh -x ${clean_env_dir}/backup_cluster_logs.sh ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
sh -x ${clean_env_dir}/backup_cluster_cn_data ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
}
# start cluster 
echo "">${log_file}
if [[ -n "${root_pw}" ]]; then
    db_cli_pw_arg="-pw ${root_pw}"
fi
if [[ ${enable_start_db} -gt 0 ]]; then
    start_db
else
    log "INFO" "ENABLE_START_DB=${enable_start_db}，跳过启动集群，直接使用当前集群"
fi
exec_jstack
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
if [[ ${backup_log_flag} -gt 0 ]];then
# stop cluster
v_tc_name_pre=`echo ${SCRIPT_NAME}|awk -F '.' '{print $1}'`
v_backup_time=`date +"%Y_%m_%d_%H_%M_%S"`
#sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
sh -x ${clean_env_dir}/backup_cluster_logs.sh ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1

fi

}
write_result
