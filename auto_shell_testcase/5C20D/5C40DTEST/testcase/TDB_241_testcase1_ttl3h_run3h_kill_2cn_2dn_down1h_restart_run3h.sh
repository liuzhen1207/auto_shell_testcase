#!/bin/bash
set -uo pipefail
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
current_dir=${cur_dir}
SCRIPT_NAME=$(basename "$0")
RUN_ARTIFACT_DIR=""
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
cn_num=${CN_NUM:-5}
dn_num=${DN_NUM:-20}
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
   bash -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
   bash -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
   bash -x "${clean_env_dir}/reset_conf.sh" >> "${log_file}" 2>&1 || cleanup_failed=1

   # Cache dropping is optional and must never abort the test case.
   if ! bash -x "${clean_env_dir}/clear_cache.sh" >> "${log_file}" 2>&1; then
       local cache_warn="清理操作系统缓存失败（可能缺少sudo/root权限），已忽略并继续执行"
       v_warnMessage="${v_warnMessage}${cache_warn}."
       v_warnNum=$((v_warnNum + 1))
       log "WARN" "${cache_warn}；不增加fail_flag"
   fi
   if [ ${cleanup_failed} -eq 0 ]; then
       log "INFO" "集群环境清理完成"
   else
       log "ERROR" "集群环境清理失败"
       return 1
   fi
   return 0
}

# 单个ConfigNode配置函数
configure_confignode() {
    local node_ip=$1
    log "INFO" "开始配置ConfigNode: ${node_ip}"
    
    # 整合所有ConfigNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#\?ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="4G"/g' ${cn_db_dir}/conf/confignode-env.sh
        sed -i 's/#\?OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${cn_db_dir}/conf/confignode-env.sh
        
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
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=600000"
        batch_set_sys_conf ".*dn_thrift_max_frame_size=.*" "dn_thrift_max_frame_size=268435456"
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
        sed -i 's/#\?ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="48G"/g' ${db_dir}/conf/datanode-env.sh
        sed -i 's/#\?OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${db_dir}/conf/datanode-env.sh
        
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
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=600000"
        batch_set_sys_conf ".*dn_thrift_max_frame_size=.*" "dn_thrift_max_frame_size=268435456"


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
    if ! configure_confignode "${node_ip}"; then
        log "ERROR" "混合节点 ${node_ip} 的 ConfigNode 配置失败"
        return 1
    fi
    if ! configure_datanode "${node_ip}"; then
        log "ERROR" "混合节点 ${node_ip} 的 DataNode 配置失败"
        return 1
    fi
    log "INFO" "混合节点 ${node_ip} 配置完成"
    return 0
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
   if ! clean_env; then
       log "ERROR" "环境清理失败，终止启动流程"
       exit 1
   fi

   # 配置节点
   fail_flag=0
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
      local sync_wait_start_epoch="${1:-$(date +%s)}"
      local sync_wait_start_time="${2:-$(date '+%F %T')}"
      local PROMETHEUS_URL
      PROMETHEUS_URL=$(grep '^monitor_url' "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
      local PROMETHEUS_USER=admin
      local PROMETHEUS_PASS=admin
      local SLEEP_INTERVAL=60
      local dn_file="${nodeinfo_dir}/datanode.txt"
      local cluster_dn_file="${cur_dir}/cluster_running_datanodes.out"

      local zero_start_time=0
      local zero_confirm_count=0
      local required_zero_confirmations=3
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
              zero_confirm_count=0
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
              zero_confirm_count=0
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
              zero_confirm_count=0
              echo "[$(date '+%F %T')] 等待中: 指标缺失 ${#missing_nodes[@]}/${expected_count}，缺失节点: ${missing_nodes[*]}"
              sleep "${SLEEP_INTERVAL}"
              continue
          fi

          if $has_non_zero; then
              zero_start_time=0
              zero_confirm_count=0
              echo "[$(date '+%F %T')] 等待中: ${zero_count}/${expected_count} 个 DN syncLag=0，非零节点: ${non_zero_nodes[*]}，fail_flag=${fail_flag}，sync_fail_flag=${sync_fail_flag}"
          else
              if [[ "$zero_start_time" -eq 0 ]]; then
                  zero_start_time=$now
              fi

              local current_duration=$((now - zero_start_time))
              zero_confirm_count=$((zero_confirm_count + 1))
              echo "[$(date '+%F %T')] 正常: ${expected_count}/${expected_count} 个 DN syncLag=0，连续确认 ${zero_confirm_count}/${required_zero_confirmations}"
              if ((zero_confirm_count >= required_zero_confirmations)); then
                  local sync_wait_end_epoch sync_wait_end_time sync_wait_elapsed
                  sync_wait_end_epoch=$(date +%s)
                  sync_wait_end_time=$(date '+%F %T')
                  sync_wait_elapsed=$((sync_wait_end_epoch - sync_wait_start_epoch))
                  echo "[$(date '+%F %T')] 同步完成: ${dn_file} 中所有 DataNode 的 Total Sync Lag 已连续 ${required_zero_confirmations} 次为 0"
                  echo "BENCHMARK_EXIT_CONFIRMED=${sync_wait_start_time}"
                  echo "SYNC_LAG_ZERO_CONFIRMED=${sync_wait_end_time}"
                  echo "SYNC_LAG_WAIT_SECONDS=${sync_wait_elapsed}"
                  echo "最终 fail_flag=${fail_flag}, sync_fail_flag=${sync_fail_flag}"
                  return 0
              fi
          fi

          sleep "${SLEEP_INTERVAL}"
      done
  }

function create_user()
{
    local parameter_root="${cur_dir}/../benchmark/generated_benchmark/bm_parameter_value"
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "CREATE DATABASE usr_sod0 WITH (ttl=10800000);" > "${cur_dir}/tmp.out" 2>&1
    check_res success 1 "CREATE DATABASE usr_sod0 with ttl"
    local created=0
    for n in 1 2 3 4 5; do
        for role in write read1 read2; do
            local pf="${parameter_root}/no${n}/${role}.txt"
            local username password
            username=$(awk -F= '/^USERNAME=/{print $2; exit}' "${pf}" | tr -d '\r')
            password=$(awk -F= '/^PASSWORD=/{print $2; exit}' "${pf}" | tr -d '\r')
            if [[ -z "${username}" || -z "${password}" ]]; then
                log "ERROR" "参数文件缺少用户名或密码: ${pf}"
                return 1
            fi
            ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER ${username} '${password}';" > "${cur_dir}/tmp.out" 2>&1
            check_res success 1 "CREATE USER ${username}"
            ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "GRANT ALL TO USER ${username};" > "${cur_dir}/tmp.out" 2>&1
            check_res success 1 "GRANT ALL TO USER ${username}"
            ((created++))
        done
    done
    log "INFO" "已创建并授权 ${created} 个 Benchmark 用户"
}
function exec_jstack()
{
v_jstack_dir=${RUN_ARTIFACT_DIR}/jstack_result/${v_jstack_stage:-unlabeled}
mkdir -p ${v_jstack_dir}
datanode_file="${nodeinfo_dir}/datanode.txt"
confignode_file="${nodeinfo_dir}/confignode.txt"

dump_remote_process_debug() {
    local ip=$1
    local process_name=$2
    local outfile=$3

    if ! ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=2 \
        "${os_user_name}@${ip}" bash -s -- "${process_name}" > "${outfile}" 2>&1 <<'EOF'
process_name="$1"
pid=$(jps -l 2>/dev/null | awk -v name="${process_name}" '$2 ~ ("(^|\\.)" name "$") {print $1; exit}')
if [ -z "${pid}" ]; then
    pid=$(ps -eo pid=,args= | awk -v name="${process_name}" '$0 ~ /[j]ava/ && $0 ~ ("(^|[.])" name "([[:space:]]|$)") {print $1; exit}')
fi

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
process_java=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)
process_java_bin=$(dirname "${process_java}" 2>/dev/null || true)
current_java=$(command -v java 2>/dev/null || true)
current_java=$(readlink -f "${current_java}" 2>/dev/null || printf '%s' "${current_java}")
current_java_bin=$(dirname "${current_java}" 2>/dev/null || true)
jstack_bin=""
for candidate in "${process_java_bin}/jstack" "${JSTACK_JAVA_HOME:-}/bin/jstack" "${current_java_bin}/jstack" "${JAVA_HOME:-}/bin/jstack" "$(command -v jstack 2>/dev/null || true)"; do
    if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then jstack_bin="${candidate}"; break; fi
done
echo "process_java=${process_java:-unavailable}"
echo "jstack=${jstack_bin:-unavailable}"
if [ -n "${process_java}" ] && [ -x "${process_java}" ]; then "${process_java}" -version 2>&1 | head -n 1; fi
if [ -z "${jstack_bin}" ]; then echo "jstack executable not found"; exit 127; fi
thread_dump=$(timeout 60s "${jstack_bin}" "${pid}" 2>&1)
jstack_rc=$?
if [ "${jstack_rc}" -ne 0 ]; then
    echo "jstack failed or timed out, rc=${jstack_rc}"
fi
echo "ThreadCount: $(printf '%s\n' "${thread_dump}" | grep -c '^\"' || true)"
printf '%s\n' "${thread_dump}"
exit "${jstack_rc}"
EOF
    then
        {
            echo "SSH/JSTACK collection failed"
            echo "host=${ip} process=${process_name} user=${os_user_name}"
        } >> "${outfile}"
        log "WARN" "节点${ip} ${process_name} jstack采集失败，已跳过，不阻塞用例"
    fi
}

_exec_stage_jstack_legacy() {
    local stage="$1"
    v_jstack_stage="$stage"
    echo "JSTACK_STAGE=${stage} TIME=$(date '+%F %T')" | tee -a "${log_file}"
    exec_jstack
    local stage_dir="${cur_dir}/${testdb}/jstack_result/${stage}"
    mkdir -p "${stage_dir}"
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;" > "${stage_dir}/show_regions_table.out" 2>&1 || true
    awk -F'|' '
      NR==1 { for (i=1;i<=NF;i++) { h=$i; gsub(/[[:space:]]/,"",h); if (h ~ /RegionType|Type/) rt=i; if (h ~ /Role/) rs=i; if (h ~ /RpcAddress/) nd=i; if (h ~ /DataNodeId/) ni=i } next }
      NF>1 { line=$0; gsub(/[[:space:]]/,"",line); type=(rt?$(rt):line); role=(rs?$(rs):line); node=(nd?$(nd):(ni?$(ni):"unknown")); if (type ~ /DataRegion/) { if (role ~ /Leader/) dl[node]++; else if (role ~ /Follower/) df[node]++ } if (type ~ /SchemaRegion/) { if (role ~ /Leader/) sl[node]++; else if (role ~ /Follower/) sf[node]++ } }
      END { for (n in dl) print "node="n",data_leader="(dl[n]+0)",data_follower="(df[n]+0)",data_total="(dl[n]+df[n]+0); for (n in sl) print "node="n",schema_leader="(sl[n]+0)",schema_follower="(sf[n]+0)" }
    ' "${stage_dir}/show_regions_table.out" | sort > "${stage_dir}/region_leader_follower_summary.out"
    awk -F'data_total=' '/data_total=/ {v=$2+0; if (min=="" || v<min) min=v; if (v>max) max=v} END {if (min!="") print "data_total_min="min" data_total_max="max" diff="max-min; else print "data_total: unavailable"}' "${stage_dir}/region_leader_follower_summary.out" > "${stage_dir}/region_balance_conclusion.out"
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

# 全局阶段封装。exec_jstack 中保留的历史内嵌定义在首次调用前不可见。
exec_stage_jstack() {
    local stage="$1"
    v_jstack_stage="$stage"
    echo "JSTACK_STAGE=${stage} TIME=$(date '+%F %T')" | tee -a "${log_file}"
    exec_jstack
    local stage_dir="${cur_dir}/${testdb}/jstack_result/${stage}"
    mkdir -p "${stage_dir}"
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;" > "${stage_dir}/show_regions_table.out" 2>&1 || true
    awk -F'|' '
      NR==1 { for (i=1;i<=NF;i++) { h=$i; gsub(/[[:space:]]/,"",h); if (h ~ /RegionType|Type/) rt=i; if (h ~ /Role/) rs=i; if (h ~ /RpcAddress/) nd=i; if (h ~ /DataNodeId/) ni=i } next }
      NF>1 { line=$0; gsub(/[[:space:]]/,"",line); type=(rt?$(rt):line); role=(rs?$(rs):line); node=(nd?$(nd):(ni?$(ni):"unknown")); if (type ~ /DataRegion/) { if (role ~ /Leader/) dl[node]++; else if (role ~ /Follower/) df[node]++ } if (type ~ /SchemaRegion/) { if (role ~ /Leader/) sl[node]++; else if (role ~ /Follower/) sf[node]++ } }
      END { for (n in dl) print "node="n",data_leader="(dl[n]+0)",data_follower="(df[n]+0)",data_total="(dl[n]+df[n]+0); for (n in sl) print "node="n",schema_leader="(sl[n]+0)",schema_follower="(sf[n]+0) }
    ' "${stage_dir}/show_regions_table.out" | sort > "${stage_dir}/region_leader_follower_summary.out"
    awk -F'data_total=' '/data_total=/ {v=$2+0; if (min=="" || v<min) min=v; if (v>max) max=v} END {if (min!="") print "data_total_min="min" data_total_max="max" diff="max-min; else print "data_total: unavailable"}' "${stage_dir}/region_leader_follower_summary.out" > "${stage_dir}/region_balance_conclusion.out"
}

configure_benchmark_runtime() {
    local bm_hosts_file="${cur_dir}/../benchmark/generated_benchmark/benchmark_hosts.conf" dn_file="${nodeinfo_dir}/datanode.txt"
    local host_value port_value start_write start_query host role cfg start_time
    host_value=$(awk 'NF && $1 !~ /^#/ && !seen[$1]++ {printf "%s%s", sep, $1; sep=","}' "${dn_file}")
    port_value=$(awk 'NF && $1 !~ /^#/ && !seen[$1]++ {printf "%s6667", sep; sep=","}' "${dn_file}")
    [[ -n "${host_value}" ]] || { log "ERROR" "无法从 ${dn_file} 生成 Benchmark HOST"; return 1; }
    start_write=$(date '+%Y-%m-%dT%H:%M:%S+08:00')
    start_query=$(date -d '60 seconds ago' '+%Y-%m-%dT%H:%M:%S+08:00')
    log "INFO" "Benchmark HOST=${host_value} PORT=${port_value}"
    log "INFO" "Benchmark write START_TIME=${start_write} query START_TIME=${start_query}"
    while read -r host; do
        [[ -z "${host}" || "${host}" =~ ^# ]] && continue
        for role in write read1 read2; do
            cfg="${bm_dir}/${role}/config.properties"
            [[ "${role}" == write ]] && start_time="${start_write}" || start_time="${start_query}"
            if ! ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${host}" \
              "mkdir -p '${bm_dir}' '${bm_dir}/${testdb}'; sed -i '/^HOST=.*/d;/^PORT=.*/d;/^START_TIME=.*/d' '${cfg}'; printf '%s\\n' 'HOST=${host_value}' 'PORT=${port_value}' 'START_TIME=${start_time}' >> '${cfg}'"; then
                log "ERROR" "更新 ${host} ${role} Benchmark 运行参数失败"
                return 1
            fi
            log "INFO" "已更新 ${host} ${role} Benchmark 运行参数"
        done
    done < "${bm_hosts_file}"
}
function start_bm()
{
v_bm_time=$(date +%Y%m%d_%H%M%S)
arg="${testdb}_${v_cluster_num_info}_${v_bm_time}"
bm_hosts_file="${cur_dir}/../benchmark/generated_benchmark/benchmark_hosts.conf"
mapfile -t bm_hosts < <(grep -vE '^\s*(#|$)' "${bm_hosts_file}")
if ((${#bm_hosts[@]} < 5)); then
    log "ERROR" "Benchmark 主机数量不足：期望5，实际${#bm_hosts[@]}"
    return 1
fi
bm_start_epoch=$(date +%s)
echo "BM 开始时间: $(date '+%F %T')"
local bm_start_failed=0
for idx in 1 2 3 4 5; do
    host="${bm_hosts[$((idx-1))]}"
    for role in write read1 read2; do
        inst="${bm_dir}/${role}"
        out="${bm_dir}/${testdb}/${arg}_${role}.out"
        if ! ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${host}" \
          "source /etc/profile >/dev/null 2>&1
           command -v java >/dev/null 2>&1 || exit 20
           command -v setsid >/dev/null 2>&1 || exit 21
           mkdir -p '${bm_dir}/${testdb}' || exit 22
           cd '${bm_dir}' || exit 23
           setsid -f ./benchmark.sh -cf '${inst}' > '${out}' 2>&1 < /dev/null"; then
            log "ERROR" "BM启动命令失败 host=${host} role=${role}"
            bm_start_failed=1
            continue
        fi

        sleep 3
        bm_pid=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${host}" \
          "ps -eo pid=,args= | awk -v cfg='${inst}' '\$0 ~ /[c]n.edu.tsinghua.iot.benchmark.App/ && index(\$0,cfg) {print \$1; exit}'")
        if [[ -n "${bm_pid}" ]]; then
            log "INFO" "BM启动成功 host=${host} role=${role} pid=${bm_pid} out=${out}"
        else
            bm_error=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${host}" "tail -n 8 '${out}' 2>/dev/null" | tr '\n' ' ')
            log "ERROR" "BM启动后未检测到进程 host=${host} role=${role} out=${out} error=${bm_error}"
            v_warnMessage="${v_warnMessage}BM host=${host} role=${role}启动失败."
            v_warnNum=$((v_warnNum + 1))
            bm_start_failed=1
        fi
    done
done
if ((bm_start_failed != 0)); then
    log "ERROR" "至少一个 Benchmark 启动失败，终止本次用例，避免无负载空跑"
    return 1
fi
}
function check_bm()
{
    local bm_hosts_file="${cur_dir}/../benchmark/generated_benchmark/benchmark_hosts.conf"
    local host role status total_count alive_count check_failed

    if [[ ! -r "${bm_hosts_file}" ]]; then
        log "ERROR" "Benchmark 主机配置不可读: ${bm_hosts_file}"
        return 1
    fi

    mapfile -t bm_hosts < <(sed -e 's/#.*//' -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${bm_hosts_file}" | grep -v '^$')
    if ((${#bm_hosts[@]} == 0)); then
        log "ERROR" "Benchmark 主机配置为空: ${bm_hosts_file}"
        return 1
    fi

    total_count=$((${#bm_hosts[@]} * 3))
    while true; do
        echo "==== 检查 ${#bm_hosts[@]} 台主机上 ${total_count} 个 Benchmark 进程 ===="
        alive_count=0
        check_failed=0

        for host in "${bm_hosts[@]}"; do
            for role in write read1 read2; do
                status=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${host}" \
                  "alive_flag=0
                   ps -eo args= | awk -v cfg='${bm_dir}/${role}' '\$0 ~ /[c]n.edu.tsinghua.iot.benchmark.App/ && index(\$0,cfg) {found=1} END {exit !found}' && alive_flag=1
                   echo \"\$alive_flag\"" 2>/dev/null) || {
                    log "WARN" "BM 状态检查失败 host=${host} role=${role}"
                    check_failed=1
                    continue
                }

                if [[ "${status}" == "1" ]]; then
                    alive_count=$((alive_count + 1))
                fi
                echo "BM状态 host=${host} role=${role} alive=${status}"
            done
        done

        echo "[INFO] BM 进程: alive=${alive_count}/${total_count}"
        if ((check_failed == 0 && alive_count == 0)); then
            echo "[INFO] 所有 Benchmark 进程均已退出"
            return 0
        fi
        if ((check_failed != 0)); then
            echo "[WARN] 部分 Benchmark 主机状态未取到，5分钟后重试"
        else
            echo "[INFO] 仍有 Benchmark 进程运行，5分钟后重试"
        fi
        sleep 300
    done
}
check_benchmark_failures_before_kill() {
    local bm_hosts_file="${cur_dir}/../benchmark/generated_benchmark/benchmark_hosts.conf"
    local summary_file="${RUN_ARTIFACT_DIR}/benchmark_failures_before_kill.out"
    local host role out out_name failure_count role_name stats

    mkdir -p "${cur_dir}/${testdb}"
    : > "${summary_file}"
    echo "BENCHMARK_FAILURE_CHECK_TIME=$(date '+%F %T')" | tee -a "${summary_file}"

    while read -r host; do
        [[ -z "${host}" || "${host}" =~ ^# ]] && continue
        for role in write read1 read2; do
            out="${bm_dir}/${testdb}/${arg}_${role}.out"
            out_name="${arg}_${role}.out"
            [[ "${role}" == "write" ]] && role_name="写" || role_name="读"

            stats=$(ssh -o ConnectTimeout=10 "${os_user_name}@${host}" bash -s -- "${out}" <<'EOF'
out_file="$1"
if [[ ! -f "${out_file}" ]]; then
    echo "MISSING"
    exit 0
fi
awk '
  {
    line=tolower($0)
    if (line ~ /(error|exception|failed|failure)/) {
      if (line ~ /(failed|failure|fail)[^0-9]*0([^0-9]|$)/) next
      count++
    }
  }
  END {print count+0}
' "${out_file}"
EOF
)

            if [[ "${stats}" == "MISSING" ]]; then
                echo "IP=${host} OUT=${out_name} ROLE=${role_name} STATUS=missing" | tee -a "${summary_file}"
                v_warnMessage="${v_warnMessage}BM IP=${host} OUT=${out_name} ${role_name}日志不存在."
                v_warnNum=$((v_warnNum + 1))
                continue
            fi

            failure_count="${stats:-0}"
            if ! [[ "${failure_count}" =~ ^[0-9]+$ ]]; then
                failure_count=0
                echo "IP=${host} OUT=${out_name} ROLE=${role_name} STATUS=check_failed RAW=${stats}" | tee -a "${summary_file}"
                v_warnMessage="${v_warnMessage}BM IP=${host} OUT=${out_name} ${role_name}失败统计异常."
                v_warnNum=$((v_warnNum + 1))
            elif ((failure_count > 0)); then
                echo "IP=${host} OUT=${out_name} ROLE=${role_name} FAILURES=${failure_count}" | tee -a "${summary_file}"
                v_warnMessage="${v_warnMessage}BM IP=${host} OUT=${out_name} ${role_name}失败${failure_count}条."
                v_warnNum=$((v_warnNum + 1))
            else
                echo "IP=${host} OUT=${out_name} ROLE=${role_name} FAILURES=0" | tee -a "${summary_file}"
            fi
        done
    done < "${bm_hosts_file}"

    echo "BENCHMARK_FAILURE_CHECK_DONE=$(date '+%F %T') warnNum=${v_warnNum}" | tee -a "${summary_file}"
}

kill_all_benchmarks() {
    local bm_hosts_file="${cur_dir}/../benchmark/generated_benchmark/benchmark_hosts.conf" host role out
    local result_file="${RUN_ARTIFACT_DIR}/benchmark_kill_after_restart_3h.out"
    mkdir -p "${cur_dir}/${testdb}"
    : > "${result_file}"
    while read -r host; do
        [[ -z "${host}" || "${host}" =~ ^# ]] && continue
        for role in write read1 read2; do
            echo "=== ${host} ${role} $(date '+%F %T') ===" | tee -a "${result_file}"
            ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${host}" \
              "pids=\$(ps -eo pid=,args= | awk -v cfg='${bm_dir}/${role}' '\$0 ~ /[c]n.edu.tsinghua.iot.benchmark.App/ && index(\$0,cfg) {print \$1}'); for p in \${pids}; do kill -9 \"\${p}\" 2>/dev/null || true; done; sleep 1; ps -eo pid=,args= | awk -v cfg='${bm_dir}/${role}' '\$0 ~ /[c]n.edu.tsinghua.iot.benchmark.App/ && index(\$0,cfg)'" >> "${result_file}" 2>&1
        done
    done < "${bm_hosts_file}"
}

function start_cn_dn()
{
	v_start_ip1=$1
	v_start_ip2=$2
	sleep 3600
	echo "fault nodes have been down for 1 hour; collect pre-restart jstack and regions $(date '+%F %T')" | tee -a "${log_file}"
	exec_stage_jstack "fault_1h_before_restart"
	local restart_ip remaining
	for restart_ip in "${v_start_ip1}" "${v_start_ip2}"; do
		remaining=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${restart_ip}" \
		  "ps -eo pid=,args= | awk '\$0 ~ /[c]om\.timecho\.iotdb\.service\.ConfigNode/ || \$0 ~ /[c]om\.timecho\.iotdb\.DataNode/ {print}'") || {
			log "ERROR" "重启前无法检查节点 ${restart_ip} 的 CN/DN 进程，拒绝启动"
			fail_flag=$((fail_flag + 1))
			return 1
		}
		if [[ -n "${remaining}" ]]; then
			log "ERROR" "重启前节点 ${restart_ip} 仍有 CN/DN 进程，拒绝重复启动: ${remaining}"
			fail_flag=$((fail_flag + 1))
			return 1
		fi
	done
	local v_start_timestamp=$(date +'%Y_%m_%d_%H_%M_%S')
	local restart_begin_epoch=$(date +%s)
	local restart_begin_time=$(date '+%F %T')
	echo "CLUSTER_RESTART_BEGIN=${restart_begin_time} fault_nodes=${v_start_ip1},${v_start_ip2}" | tee -a "${log_file}"
	ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${v_start_ip1}" "source /etc/profile; nohup ${cn_db_dir}/sbin/start-confignode.sh -H ${cn_db_dir}/cn_${v_start_timestamp}_heapdump.hprof > ${cn_db_dir}/start_cn_${v_start_timestamp}.log 2>&1 &" || return 1
	sleep 1
	ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${v_start_ip2}" "source /etc/profile; nohup ${cn_db_dir}/sbin/start-confignode.sh -H ${cn_db_dir}/cn_${v_start_timestamp}_heapdump.hprof > ${cn_db_dir}/start_cn_${v_start_timestamp}.log 2>&1 &" || return 1
	sleep 1
	ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${v_start_ip1}" "source /etc/profile; nohup ${db_dir}/sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_timestamp}_heapdump.hprof > ${db_dir}/start_dn_${v_start_timestamp}.log 2>&1 &" || return 1
	sleep 1
	ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${v_start_ip2}" "source /etc/profile; nohup ${db_dir}/sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_timestamp}_heapdump.hprof > ${db_dir}/start_dn_${v_start_timestamp}.log 2>&1 &" || return 1
	while true
	do
		v_cur_node_num=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show cluster;"|grep Running|wc -l)
		if [[ ${v_cur_node_num} = ${total_node_num} ]];then
			local restart_end_epoch=$(date +%s)
			local restart_end_time=$(date '+%F %T')
			local restart_elapsed=$((restart_end_epoch-restart_begin_epoch))
			echo "CLUSTER_RESTART_RUNNING=${restart_end_time} elapsed_seconds=${restart_elapsed}" | tee -a "${log_file}"
			break
		else
			sleep 1
		fi
	done

	# 集群全部恢复 Running 后，再稳定运行 10 分钟采集阶段快照
	echo "cluster Running confirmed; wait 600 seconds before restart_10m snapshot" | tee -a "${log_file}"
	sleep 600
	echo "after restart 10m exec jstack $(date +'%Y-%m-%d %H:%M:%S')"
	exec_stage_jstack "restart_10m"
	echo "cluster Running confirmed; continue benchmark for 3 hours" | tee -a "${log_file}"
	sleep 10800
	exec_stage_jstack "after_restart_3h_before_benchmark_kill"
	check_benchmark_failures_before_kill
	kill_all_benchmarks

}

verify_fault_nodes() {
    local ip status_out verify_file
    verify_file="${RUN_ARTIFACT_DIR}/fault_node_verification.out"
    mkdir -p "${cur_dir}/${testdb}"
    : > "${verify_file}"
    local healthy_query_ip=""
    while read -r candidate_ip; do
        [[ -z "${candidate_ip}" || "${candidate_ip}" =~ ^# ]] && continue
        if [[ "${candidate_ip}" != "${v_shutdown_ip1}" && "${candidate_ip}" != "${v_shutdown_ip2}" ]]; then
            healthy_query_ip="${candidate_ip}"
            break
        fi
    done < "${nodeinfo_dir}/datanode.txt"
    if [[ -z "${healthy_query_ip}" ]]; then
        log "ERROR" "故障后没有可用的健康 DataNode 作为查询节点"
        let fail_flag++
        return 1
    fi
    query_ip="${healthy_query_ip}"
    echo "HEALTHY_QUERY_IP=${query_ip}" | tee -a "${verify_file}"
    for ip in "${v_shutdown_ip1}" "${v_shutdown_ip2}"; do
        echo "=== ${ip} process check $(date '+%F %T') ===" | tee -a "${verify_file}"
        if ! status_out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${ip}" \
          "ps -eo pid=,args= | awk '\$0 ~ /[c]om\.timecho\.iotdb\.service\.ConfigNode/ || \$0 ~ /[c]om\.timecho\.iotdb\.DataNode/ {print}'" 2>> "${verify_file}"); then
            log "ERROR" "无法检查故障节点 ${ip} 的 CN/DN 进程"
            fail_flag=$((fail_flag + 1))
            return 1
        fi
        if [[ -n "${status_out}" ]]; then
            echo "${status_out}" >> "${verify_file}"
            log "ERROR" "故障节点 ${ip} 仍有 CN/DN 进程"
            fail_flag=$((fail_flag + 1))
            return 1
        else
            echo "CN/DN processes exited: OK" | tee -a "${verify_file}"
        fi
    done
    local deadline=$((SECONDS+300))
    while (( SECONDS < deadline )); do
        ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show cluster;" > "${RUN_ARTIFACT_DIR}/fault_show_cluster.out" 2>&1 || true
        local all_unknown=1
        for ip in "${v_shutdown_ip1}" "${v_shutdown_ip2}"; do
            if ! grep -E "(^|[|[:space:]])${ip}([|[:space:]]|$)" "${RUN_ARTIFACT_DIR}/fault_show_cluster.out" | grep -q Unknown; then
                all_unknown=0
            fi
        done
        if (( all_unknown == 1 )); then
            echo "show cluster confirms both fault nodes Unknown" | tee -a "${verify_file}"
            cat "${RUN_ARTIFACT_DIR}/fault_show_cluster.out" >> "${verify_file}"
            return 0
        fi
        sleep 5
    done
    log "ERROR" "等待故障节点状态变为 Unknown 超时"
    cat "${RUN_ARTIFACT_DIR}/fault_show_cluster.out" >> "${verify_file}"
    let fail_flag++
    return 1
}
collect_stop_artifacts() {
    local stamp="$1" root="${cur_dir}/${testdb}/testcase1_logs_${1}" ip v4 dest
    mkdir -p "${root}"
    for ip in $(grep -vE '^\s*(#|$)' "${nodeinfo_dir}/confignode.txt"); do
        v4="${ip##*.}"; dest="${root}/cn_${v4}"; mkdir -p "${dest}"
        scp -q -o ConnectTimeout=10 "${os_user_name}@${ip}:${cn_db_dir}"/*stopping_jstack_*.out "${dest}/" 2>/dev/null || true
        scp -q -o ConnectTimeout=10 -r "${os_user_name}@${ip}:${cn_db_dir}/logs" "${dest}/" 2>/dev/null || true
    done
    for ip in $(grep -vE '^\s*(#|$)' "${nodeinfo_dir}/datanode.txt"); do
        v4="${ip##*.}"; dest="${root}/dn_${v4}"; mkdir -p "${dest}"
        scp -q -o ConnectTimeout=10 "${os_user_name}@${ip}:${db_dir}"/*stopping_jstack_*.out "${dest}/" 2>/dev/null || true
        scp -q -o ConnectTimeout=10 -r "${os_user_name}@${ip}:${db_dir}/logs" "${dest}/" 2>/dev/null || true
    done
    cp -p "${log_file}" "${root}/" 2>/dev/null || true
    cp -p "${cur_dir}/tmp.out" "${root}/" 2>/dev/null || true
    log "INFO" "停止阶段日志已归档到 ${root}"
}

function testcase()
{
	create_user || return 1
	configure_benchmark_runtime || return 1
	start_bm || return 1
	for i in {1..6}
	do

                sleep 3600	
		# The fourth-hour snapshot is collected by start_cn_dn immediately before restart.
		if [[ ${i} != 4 ]]; then
			exec_stage_jstack "fault_before_kill"
		fi
		if [[ ${i} = 3 ]];then
                ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show confignodes;"|grep Leader|awk -F '|' '{gsub(" ","");print $4}'>${cur_dir}/tmp.out
                ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show confignodes;"|grep Follower|head -1|awk -F '|' '{gsub(" ","");print $4}'>>${cur_dir}/tmp.out
		v_shutdown_ip1=$(head -1 ${cur_dir}/tmp.out)
		v_shutdown_ip2=$(tail -1 ${cur_dir}/tmp.out)
		local v_stop_timestamp=$(date +'%Y-%m-%d %H:%M:%S')
		echo "reboot ${v_shutdown_ip1} ${v_shutdown_ip2} at ${v_stop_timestamp}"
                for fault_ip in "${v_shutdown_ip1}" "${v_shutdown_ip2}"; do
                    if ! ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${fault_ip}" \
                      "pids=\$(ps -eo pid=,args= | awk '\$0 ~ /[c]om\.timecho\.iotdb\.service\.ConfigNode/ || \$0 ~ /[c]om\.timecho\.iotdb\.DataNode/ {print \$1}'); [ -n \"\$pids\" ] || exit 30; kill -9 \$pids"; then
                        log "ERROR" "故障节点 ${fault_ip} 的 CN/DN kill -9 执行失败或未找到目标进程"
                        fail_flag=$((fail_flag + 1))
                        return 1
                    fi
                done
	        sleep 10
	        verify_fault_nodes || return 1
		# Start the one-hour outage timer now; collect a delayed post-failure snapshot in parallel.
		start_cn_dn ${v_shutdown_ip1} ${v_shutdown_ip2} &
		sleep 300
		# Capture the post-failure state five minutes after both nodes become Unknown.
		exec_stage_jstack "fault_after_kill"
		fi
	done
	check_bm
	local sync_wait_start_epoch sync_wait_start_time
	sync_wait_start_epoch=$(date +%s)
	sync_wait_start_time=$(date '+%F %T')
	echo "BENCHMARK_EXIT_CONFIRMED=${sync_wait_start_time}"
	exec_stage_jstack "after_restart_3h_before_benchmark_kill"
	wait_logs_sync_done 120
	wait_for_monitor_sync_completion "${sync_wait_start_epoch}" "${sync_wait_start_time}"
 #check cluster status
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show cluster;">${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out
check_res Running ${total_node_num} "show cluster expect ${total_node_num} Running but "
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show regions;">${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;">${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out

	# stop cluster
	sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
	collect_stop_artifacts "$(date +%Y_%d_%m_%H_%M_%S)"
	check_log
	#backup logs
        v_tc_name_pre=`echo ${SCRIPT_NAME}|awk -F '.' '{print $1}'`
        v_backup_time=`date +"%Y_%m_%d_%H_%M_%S"`
sh -x ${clean_env_dir}/backup_cluster_logs.sh ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
sh -x ${clean_env_dir}/backup_cluster_cn_data ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
}
# start cluster 
RUN_ARTIFACT_DIR="${cur_dir}/${testdb}/${SCRIPT_NAME%.*}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${RUN_ARTIFACT_DIR}"
log_file="${RUN_ARTIFACT_DIR}/run.log"
echo "">${log_file}
#while true
#do
#       v_last_test=$(ps -ef | grep tc2026_5c20d_ttl_now_kill_LoadBalance.sh| grep -v grep | wc -l)
#       if [[ ${v_last_test} -gt 0 ]];then
#               sleep 300
#       else
#               echo "last test finish."
#               break
#       fi
#done
#sleep 300

start_db
exec_stage_jstack "before_benchmark"
# start test time
v_start_test_time=`date +%s`
testcase
v_end_test_time=`date +%s`
v_elp_time=$((v_end_test_time-v_start_test_time))
# record test result
backup_benchmark_logs() {
    local stamp="$1" root="${cur_dir}/${testdb}/testcase1_${1}/benchmark_logs" host ip4 role
    mkdir -p "${root}"
    while read -r host; do
        [[ -z "${host}" || "${host}" =~ ^# ]] && continue
        ip4="${host##*.}"
        mkdir -p "${root}/bm_${ip4}"
        for role in write read1 read2; do
            scp -q -o ConnectTimeout=10 "${os_user_name}@${host}:${bm_dir}/${testdb}/*_${role}.out" "${root}/bm_${ip4}/" 2>/dev/null || true
        done
    done < "${cur_dir}/../benchmark/generated_benchmark/benchmark_hosts.conf"
    log "INFO" "Benchmark 日志已备份到 ${root}"
}

analyze_benchmark_phases() {
    local out_dir="${cur_dir}/${testdb}/benchmark_phase_analysis"
    local raw="${out_dir}/raw_benchmark_reports.tsv" summary="${out_dir}/phase_summary.tsv" alerts="${out_dir}/phase_alerts.txt"
    mkdir -p "${out_dir}"; : > "${raw}"
    local host f
    while read -r host; do
        [[ -z "${host}" || "${host}" =~ ^# ]] && continue
        ssh "${os_user_name}@${host}" "find '${bm_dir}/${testdb}' -maxdepth 1 -type f -name '*.out' -print" 2>/dev/null | while read -r f; do
            ssh "${os_user_name}@${host}" "awk '\n/^Test elapsed time .*second/ {elapsed=\$NF; gsub(/[^0-9.]/,\"\",elapsed)}\n/^([A-Z_]+)[[:space:]]+[0-9.-]+[[:space:]]/ {if (elapsed != \"\" && \$1 != \"Operation\" && \$1 != \"Test\") print elapsed, \$1, \$2, \$10, \$12}' '${f}'" 2>/dev/null | awk -v h="${host}" -v file="$(basename "${f}")" '{print h"\t"file"\t"$0}' >> "${raw}"
        done
    done < "${cur_dir}/../benchmark/generated_benchmark/benchmark_hosts.conf"
    awk -F'\t' 'BEGIN{OFS="\t"; print "phase","host","file","operation","avg_ms","p99_ms","max_ms"}
      {e=$3+0; if(e<=10800)p="before_fault_3h"; else if(e<=14400)p="fault_1h"; else if(e<=15000)p="restart_running_10m"; else if(e<=25800)p="restart_running_3h"; else next; split($4,a," "); print p,$1,$2,a[2],a[3],a[4],a[5]}' "${raw}" > "${summary}"
    awk -F'\t' 'NR==1{next} {k=$1 FS $4; sum[k]+=$5; n[k]++} END{for(k in sum) print k"\tavg="sum[k]/n[k]}' "${summary}" | sort > "${out_dir}/phase_average.tsv"
    awk -F'\t' 'NR==1{next} $1=="before_fault_3h"{base[$4]+=$5;bn[$4]++} NR>1&&$1!="before_fault_3h"{cur[$1 FS $4]+=$5;cn[$1 FS $4]++} END{for(k in cur){split(k,a,FS); b=base[a[2]]/bn[a[2]]; v=cur[k]/cn[k]; if(b>0 && (v-b)/b>0.1 || b>0 && (v-b)/b<-0.1) print "ALERT\t"a[1]"\t"a[2]"\tbaseline="b"\tcurrent="v"\tchange_pct="(v-b)/b*100}}' "${summary}" > "${alerts}"
    log "INFO" "Benchmark 四阶段分析完成: ${out_dir}"
}

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
backup_benchmark_logs "$(date +%Y_%d_%m_%H_%M_%S)"
analyze_benchmark_phases
write_result
