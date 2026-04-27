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
db_admin_name=="sys_admin"
db_sec_admin_name="security_admin"
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
dn_num=12
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
        batch_set_sys_conf ".*query_cost_stat_window=.*" "query_cost_stat_window=5"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=86400000"
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
        batch_set_sys_conf ".*query_cost_stat_window=.*" "query_cost_stat_window=5"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=86400000"


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
   if [ ${fail_flag} -eq 1 ]; then
       log "ERROR" "环境清理失败，终止启动流程"
#       exit 1
   fi

   # 配置节点
   set_conf
   if [ ${fail_flag} -eq 1 ]; then
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
   v_dn_total_err=$((v_err+v_err2+v_err3+v_err4+v_err5+v_err6+v_err7+v_err8+v_err9+v_err10))
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
local max_wait_time=$1
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
         ssh ${v_dn_ip}@${v_dn_ip} "kill -9 ${v_dn_pid}."
         break
      fi

done
}
# 监控 Total Sync Lag 直到所有 DataNode 连续 5 分钟为 0
wait_for_monitor_sync_completion() {
    # Prometheus服务器信息
    local PROMETHEUS_URL=$(grep ^monitor_url "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
    local PROMETHEUS_USER=admin
    local PROMETHEUS_PASS=admin

    # 连续时间（秒）- 120秒
    local TARGET_DURATION=120
    local current_duration=0
    local start_time=$(date +%s)

    # 关联数组：追踪每个DataNode上一次的sync lag状态（true=上一次>0，false=上一次=0）
    declare -A last_node_status

    echo "开始监控 Total Sync Lag，目标连续 ${TARGET_DURATION} 秒所有 DataNode 均为 0..."

    while true; do
        # 获取当前时间
        local current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        local all_zero=true  # 标记本次检测是否所有节点都为0
        local has_non_zero=false  # 标记本次是否有节点>0

        # 调用 Prometheus API 获取 Total Sync Lag（使用 URL 编码）
        local response=$(curl -s -u "$PROMETHEUS_USER:$PROMETHEUS_PASS" \
            "$PROMETHEUS_URL/api/v1/query?query=iot_consensus%7Bcluster%3D%22$CLUSTER_ID%22%2CnodeType%3D%22DATANODE%22%2Cname%3D%22ioTConsensusServerImpl%22%2Ctype%3D%22syncLag%22%7D")

        # 检查响应是否成功
        if [[ $(echo "$response" | jq -r '.status') != "success" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 错误: 无法从 Prometheus 获取数据"
            echo "响应: $response"
            sleep 1
            continue
        fi

        # 提取结果列表，避免重复解析jq
        local results=$(echo "$response" | jq -r '.data.result')
        local result_count=$(echo "$results" | jq -r 'length')

        if [[ $result_count -eq 0 ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 警告: 未找到 Total Sync Lag 指标数据"
            sleep 1
            continue
        fi

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 找到 $result_count 个 Total Sync Lag 指标"

        # 遍历每个DataNode的指标
        for ((i=0; i<result_count; i++)); do
            # 一次性提取当前节点的所有信息
            local instance=$(echo "$results" | jq -r ".[$i].metric.instance")
            local sync_lag=$(echo "$results" | jq -r ".[$i].value[1]")
            local cluster=$(echo "$results" | jq -r ".[$i].metric.cluster")
            local node_type=$(echo "$results" | jq -r ".[$i].metric.nodeType")

            echo "  实例 $instance: Total Sync Lag = $sync_lag (集群: $cluster, 类型: $node_type)"

            # 浮点数比较：判断当前sync lag是否>0（容忍微小精度误差）
            if (( $(echo "$sync_lag > 0.0001" | bc -l) )); then
                has_non_zero=true
                all_zero=false

                # 核心逻辑：只有上一次状态也是>0时，才累加fail_flag
                if [[ ${last_node_status[$instance]} == "true" ]]; then
                    ((fail_flag++))
                    ((sync_fail_flag++))
                    v_warnMessage="sync lag > 0: 实例 $instance 持续大于0，fail_flag 累加至 $fail_flag"
                    echo "  ⚠️  $v_warnMessage"
                else
                    # 首次检测到>0，仅更新状态，不累加
                    v_warnMessage="sync lag > 0: 实例 $instance 首次大于0，暂不累加fail_flag"
                    echo "  ⚠️  $v_warnMessage"
                fi

                # 更新当前节点的状态为>0
                last_node_status[$instance]="true"
            else
                # sync lag=0，更新状态为false，不累加
                last_node_status[$instance]="false"
            fi
        done

        # 重置计时逻辑：仅当本次有节点>0时，才重置连续为0的计时
        if $has_non_zero; then
            current_duration=0
            start_time=$(date +%s)
            echo "  ❌ 存在DataNode Sync Lag>0，重置连续为0计时"
        else
            # 所有节点都为0，累计连续时长
            current_duration=$((current_time - start_time))
            echo "✅ 所有 DataNode 的 Total Sync Lag 均为 0，已持续 ${current_duration} 秒"

            # 检查是否达到目标时长
            if [[ $current_duration -ge $TARGET_DURATION ]]; then
                echo "🎉 同步完成！所有 DataNode 的 Total Sync Lag 已连续 ${TARGET_DURATION} 秒均为 0"
                echo "最终 fail_flag: $fail_flag, sync_fail_flag: $sync_fail_flag"
                return 0
            fi
        fi

        # 间隔1秒检测一次
        sleep 1
    done
}
function create_user()
{
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  rainer 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  rainer"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  colder 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  colder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  winder 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  winder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  sunner 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  sunner"
# grant privelege
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "GRANT ALL ON DATABASE usr_sod0 TO USER rainer;">${cur_dir}/tmp.out
check_res success 1 "grant USER  rainer"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "GRANT ALL ON DATABASE usr_sod0 TO USER colder;">${cur_dir}/tmp.out
check_res success 1 "grant USER  colder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "GRANT ALL ON DATABASE tod_sod0 TO USER winder;">${cur_dir}/tmp.out
check_res success 1 "grant USER  winder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "GRANT ALL ON DATABASE tod_sod0 TO USER sunner;">${cur_dir}/tmp.out
check_res success 1 "grant USER  sunner"


}
function exec_jstack()
{
v_jstack_dir=${cur_dir}/${testdb}/jstack_result
mkdir -p ${v_jstack_dir}
datanode_file="${nodeinfo_dir}/datanode.txt"
confignode_file="${nodeinfo_dir}/confignode.txt"

# 时间戳（统一时间，避免每个文件时间不一样）
time=$(date +%Y%m%d_%H%M%S)

echo "==== 开始批量抓取 jstack，结果保存在当前目录 ===="

# ===================== 处理 ConfigNode =====================
if [ -f "$confignode_file" ]; then
    echo -e "\n>>>> 开始处理 ConfigNode 节点 <<<<"
    for ip in $(cat "$confignode_file" | grep -v '^$'); do
        outfile="${v_cluster_num_info}_cn_ip${ip}_${v_jstack_num}_${time}_jstack.out"
        echo "节点 $ip -> 输出到 $outfile"

        # 远程执行 jstack ConfigNode，输出直接到本地文件
        ssh root@"$ip" "jstack \$(pgrep -f 'ConfigNode')" 2>&1 > "${v_jstack_dir}/$outfile"
    done
fi

# ===================== 处理 DataNode =====================
if [ -f "$datanode_file" ]; then
    echo -e "\n>>>> 开始处理 DataNode 节点 <<<<"
    for ip in $(cat "$datanode_file" | grep -v '^$'); do
        outfile="${v_cluster_num_info}_dn_ip${ip}_${v_jstack_num}_${time}_jstack.out"
        echo "节点 $ip -> 输出到 $outfile"

        # 远程执行 jstack DataNode，输出直接到本地文件
        ssh root@"$ip" "jstack \$(pgrep -f 'DataNode')" 2>&1 > "${v_jstack_dir}/$outfile"
    done
fi

echo -e "\n==== 全部完成！所有 jstack 文件已保存在当前目录 ===="
	let v_jstack_num++
}
function start_bm()
{
v_bm_time=$(date +%Y%m%d_%H%M%S)
ssh root@${bm1_ip} "nohup ${bm_dir}/start_bm.sh ${testdb}_${v_cluster_num_info_20260423}_${v_bm_time} > /dev/null 2>&1 &"
ssh root@${bm2_ip} "nohup ${bm_dir}/start_bm.sh ${testdb}_${v_cluster_num_info_20260423}_${v_bm_time} > /dev/null 2>&1 &"
}
function check_bm()
{
while true
do
    echo "==== 开始检查 BM 进程 (App) 是否存在 ===="

    # 检查 BM1
    bm1_alive=$(ssh root@${bm1_ip} "pgrep -f 'App' | wc -l")
    # 检查 BM2
    bm2_alive=$(ssh root@${bm2_ip} "pgrep -f 'App' | wc -l")

    echo "BM1 进程数：$bm1_alive"
    echo "BM2 进程数：$bm2_alive"

    # 判断规则：任意一台 App 不存在 = 测试完成
    if [ $bm1_alive -eq 0 ] || [ $bm2_alive -eq 0 ]; then
        echo "[INFO] BM 测试已完成（进程 App 不存在）"
        return 0  # 0 = 完成
    else
        echo "[INFO] BM 仍在运行"
        sleep 300 
    fi
done
}
function testcase()
{
	create_user
	start_bm
	for i in {1..6}
	do
                sleep 3600	
		exec_jstack
	done
	check_bm
	wait_logs_sync_done
	wait_for_monitor_sync_completion
 #check cluster status
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show cluster;">${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out
check_res Running ${total_node_num} "show cluster expect ${total_node_num} Running but "
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show regions;">${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out
	# stop cluster
        sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
	check_log
	#backup logs
        v_tc_name_pre=`echo ${SCRIPT_NAME}|awk -F '.' '{print $1}'`
        v_backup_time=`date +"%Y_%m_%d_%H_%M_%S"`
sh -x ${clean_env_dir}/backup_cluster_logs.sh ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
sh -x ${clean_env_dir}/backup_cluster_cn_data ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
}
# start cluster 
echo "">${log_file}
start_db
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
   fail_flag=${sum_fail_flag}
   if [[ ${fail_flag} -gt 0 ]];then
#           ${cli_dir}/sbin/start-cli.sh -h ${v_result_iotdb_ip} -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','FAIL',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
           echo "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','FAIL',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
 
           echo "test fail"
   else
           echo "test pass"
#           ${cli_dir}/sbin/start-cli.sh -h ${v_result_iotdb_ip} -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','PASS',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
           echo "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','PASS',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
 

backup_log_flag=1
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
