#!/bin/bash
# failed_login_attempts=5
# failed_login_attempts_per_user=5
# password_lock_time_minutes=10
# failed_login_attempts_per_user = failed_login_attempts
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
db_admin_name=${db_user_name}
db_sec_admin_name=${db_user_name}
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
shell_client_db_parent_dir=$(grep "^v_shell_client_db_parent_dir=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
cli_dir=${shell_client_db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
cn_db_parent_dir=`cat ${conf_file}|grep ^v_cn_db_parent_dir|awk -F '=' '{print $2}'`
cn_db_dir=${cn_db_parent_dir}/${testdb}
remote_cli_os_user=$(grep "^remote_cli_os_user=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
remote_cli_ip=$(grep "^remote_cli_ip=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
this_shell_ip=$(grep "^this_shell_ip=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
CLUSTER_ID=$(grep ^CLUSTER_NAME "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
cn_num=3
dn_num=3
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num+dn_num))
node_num=${total_node_num}
log_file="${cur_dir}/set_conf_parallel.log"
ssl_str=""
backup_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensus"
v_sec_super_user="security_admin"
v_sys_super_user="sys_admin"
v_last_cn_sum_err_log=0
v_last_dn_sum_err_log=0
v_current_cn_sum_err_log=0
v_current_dn_sum_err_log=0

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
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="2G"/g' ${cn_db_dir}/conf/confignode-env.sh
        
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
        batch_set_sys_conf ".*cn_metric_prometheus_reporter_port=.*" "cn_metric_prometheus_reporter_port=9081"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=false"
        batch_set_sys_conf ".*enable_separation_of_powers=.*" "enable_separation_of_powers=false"
        batch_set_sys_conf ".*failed_login_attempts=.*" "failed_login_attempts=5"
        batch_set_sys_conf ".*failed_login_attempts_per_user=.*" "failed_login_attempts_per_user=5"
        batch_set_sys_conf ".*password_lock_time_minutes=.*" "password_lock_time_minutes=10"
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
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="2G"/g' ${db_dir}/conf/datanode-env.sh
        
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
        batch_set_sys_conf ".*dn_metric_prometheus_reporter_port=.*" "dn_metric_prometheus_reporter_port=9091"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=false"
        batch_set_sys_conf ".*enable_separation_of_powers=.*" "enable_separation_of_powers=false"
        batch_set_sys_conf ".*failed_login_attempts=.*" "failed_login_attempts=5"
        batch_set_sys_conf ".*failed_login_attempts_per_user=.*" "failed_login_attempts_per_user=5"
        batch_set_sys_conf ".*password_lock_time_minutes=.*" "password_lock_time_minutes=10"


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
# 读取种子节点IP（兼容低版本）
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

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
   fi
}

function check_log()
{
v_current_cn_sum_err_log=0
v_current_dn_sum_err_log=0
v_desc_msg=$1
exec 3<${nodeinfo_dir}/confignode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "gunzip ${db_dir}/logs/*confignode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err1=`ssh ${os_user_name}@${line} "grep BufferUnderflowException ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err2=`ssh ${os_user_name}@${line} "grep \"but return HAS_MORE_STATE\" ${db_dir}/logs/*confignode*all*|wc -l"`
   if [[ ${v_npe} -gt 0 ]];then
	   let fail_flag++
	   let backup_log_flag++
           v_warnMessage="${v_warnMessage}CN NPE."
	   echo "CN ${line} NullPointer : ${v_npe}"
   fi
   v_cn_err_total=$((v_cn_err1+v_cn_err2))
   if [[ ${v_cn_err_total} -gt 0 ]];then
           let fail_flag++
           let backup_log_flag++
           v_warnMessage="${v_warnMessage}CN HAS_MORE_STATE."
           echo "CN ${line} has error: ${v_npe}"
   fi
   v_current_cn_sum_err_log=$((v_npe+v_cn_err1+v_cn_err2))
done
if [[ ${v_current_cn_sum_err_log} -gt ${v_last_cn_sum_err_log} ]];then
let fail_flag++
v_warnMessage="${v_warnMessage}${v_desc_msg} CN HAVE NEW ERROR LOG."
v_last_cn_sum_err_log=$((v_last_cn_sum_err_log+v_current_cn_sum_err_log))
fi

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
#           let fail_flag++
#	   let backup_log_flag++
#           v_warnMessage="${v_warnMessage}DN NPE."
           echo "DN ${line} NullPointer : ${v_npe}"
   fi
   if [[ ${v_dn_total_err} -gt 0 ]];then
#	   let fail_flag++
#	   let backup_log_flag++
#           v_warnMessage="${v_warnMessage}DN unexp log."
	   echo "DN ${line} has error: ${v_dn_total_err}"
   fi
   v_current_dn_sum_err_log=$((v_npe+v_dn_total_err))
done

if [[ ${v_current_dn_sum_err_log} -gt ${v_last_dn_sum_err_log} ]];then
let fail_flag++
v_warnMessage="${v_warnMessage}${v_desc_msg} DN HAVE NEW ERROR LOG."
v_last_dn_sum_err_log=$((v_last_dn_sum_err_log+v_current_dn_sum_err_log))
fi

}
# failed_login_attempts=5
# failed_login_attempts_per_user=5
# password_lock_time_minutes=10
# failed_login_attempts_per_user = failed_login_attempts ; global equal per ip

function testcase1()
{
   # create javadi
   fail_flag=0
   db_ip=${query_ip}
   # create javadi
   test_user=javadi
   other_user=santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_admin_name} -h ${query_ip} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "create user ${test_user}"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_admin_name} -h ${query_ip} -e "create user ${other_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "create user ${other_user}"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "grant system to user ${test_user}"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user ${other_user};">${current_dir}/tmp.out
   check_res "success" 1 "grant system to user ${other_user}"

   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "${test_user} input 5 times wrong password"
   # dn ip right password right password login failed
   echo "">${current_dir}/tmp.out
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  -e \"show cluster;\"">>${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "${test_user} at dbip login failed because locked"

  # right pass remote cli ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..4}
   do
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  -e \"show cluster;\"">>${current_dir}/tmp.out
   done
   check_res "822: Account is blocked due to consecutive failed logins" 4 "${test_user} at remote client login failed because locked"
   cat ${current_dir}/tmp.out
   echo "">${current_dir}/tmp.out
# unlock user ip
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree -e "alter user ${test_user} @ '${this_shell_ip}' account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "alter user ${test_user} @ ${this_shell_ip} account unlock"
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB -e "show cluster;">>${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "${test_user} still login failed because global locked"
# unlock user
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree -e "alter user ${test_user} account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "alter user ${test_user} account unlock"
   # this_ip right password,success
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "${test_user} at client login succ because unlock global"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "${test_user} at db ip login succ because unlock global"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "${test_user} at remote client login succ because unlock global"
 
# drop user
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "revoke system from user ${test_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "revoke system from user ${test_user}"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "revoke system from user ${other_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "revoke system from user ${other_user}"

   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_admin_name} -h ${query_ip} -e "drop user ${test_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "drop user ${test_user}"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_admin_name} -h ${query_ip} -e "drop user ${other_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "drop user ${other_user}"
 ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect tree -e "show datanodes;"|grep Running|awk -F '|' '{print $4}' >${current_dir}/tmp.out
for i in $(seq 1 $dn_num); do
v_ip=$(sed -n "${i}p" ${current_dir}/tmp.out)
${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${v_ip} -sql_dialect tree -e "show datanodes;"
  echo $i
done
   check_log "testcase1"
   if [[ ${fail_flag} -gt 0 ]];then
      let sum_fail_flag++
      v_warnMessage="${v_warnMessage}testcase1 failed."
   fi


}

# start cluster 
echo "">${log_file}
start_db
# start test time
v_start_test_time=`date +%s`
testcase1
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
           ${cli_dir}/sbin/start-cli.sh -h ${v_result_iotdb_ip} -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','FAIL',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
 
           echo "test fail"
   else
           echo "test pass"
           ${cli_dir}/sbin/start-cli.sh -h ${v_result_iotdb_ip} -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','PASS',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
 

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
