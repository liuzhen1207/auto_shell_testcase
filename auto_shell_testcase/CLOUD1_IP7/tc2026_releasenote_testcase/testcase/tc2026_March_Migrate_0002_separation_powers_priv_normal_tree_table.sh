#!/bin/bash
# tree table migrate privilege test;enable_separation_of_powers=true 
set -uo pipefail
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

# 读取配置文件（去空格，兼容低版本）
os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
shell_client_db_parent_dir=$(grep "^v_shell_client_db_parent_dir=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
cli_dir=${shell_client_db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
cn_db_parent_dir=`cat ${conf_file}|grep ^v_cn_db_parent_dir|awk -F '=' '{print $2}'`
cn_db_dir=${cn_db_parent_dir}/${testdb}

clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
CLUSTER_ID=$(grep ^CLUSTER_NAME "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
cn_num=3
dn_num=5
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num+dn_num))
log_file="${cur_dir}/set_conf_parallel.log"
ssl_str=""
backup_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensus"
v_mig_user_name="migrate_user"
v_sec_super_user="security_admin"
v_sys_super_user="sys_admin"
# 清理旧节点文件，复制新配置
rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

# 读取种子节点IP（兼容低版本）
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
mig_from_ip=$(sed -n "2p" "${nodeinfo_dir}/datanode.txt")

fail_flag=0
sync_fail_flag=0
# if > 0 exit test 
prepare_fail_flag=0

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
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=5"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=true"
        batch_set_sys_conf ".*enable_separation_of_powers=.*" "enable_separation_of_powers=true"
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
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=5"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=true"
        batch_set_sys_conf ".*enable_separation_of_powers=.*" "enable_separation_of_powers=true"


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
   sh -x "${prepare_env_dir}/start_cluster_v20_power.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1
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
      cat ${cur_dir}/tmp.out
   fi
}
function create_user()
{
# create user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER tree_user 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res "successfully" 1 "CREATE USER tree_user"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "grant all ON root.** TO USER tree_user;">${cur_dir}/tmp.out
check_res "successfully" 1 "grant all ON root.** TO USER tree_user"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -sql_dialect table -e "CREATE USER table_user 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res "successfully" 1 "CREATE USER table_user"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user}  -sql_dialect table -e "grant all ON any TO USER table_user;">${cur_dir}/tmp.out
check_res "successfully" 1 "grant all ON any TO USER table_user"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user}  -sql_dialect table -e "CREATE USER ${v_mig_user_name} 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res "successfully" 1 "CREATE USER ${v_mig_user_name}"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "grant system TO USER ${v_mig_user_name};">${cur_dir}/tmp.out
check_res "successfully" 1 "grant system TO USER ${v_mig_user_name}"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi

}
function start_bm()
{
bm_dir=${cur_dir}/../benchmark/bm_20251017_b6be9bd_ssl
bm_conf=tree_table_100w
ts_num=500000
#get root password
#v_bm_test_time=54000000
#v_bm_test_time=36000000
v_20_pass=`grep ^passwd_param= ${cli_dir}/sbin/start-cli.sh |grep TimechoDB|wc -l`
if [[ ${v_20_pass} -gt 0 ]];then
        bm_root_pw="TimechoDB@2021"
else

        bm_root_pw="root"
fi
#sed -i 's/CREATE_SCHEMA=.*/CREATE_SCHEMA=true/g' ${bm_dir}/${bm_conf}/conf*/config.*
#sed -i 's/START_TIME=.*/START_TIME=1970-01-01T08:00:00+08:00/g' ${bm_dir}/${bm_conf}/conf*/config.*
sed -i "s/^PASSWORD=.*/PASSWORD=${bm_root_pw}/g" ${bm_dir}/${bm_conf}/conf*/config.properties
#sed -i "s/^TEST_MAX_TIME=.*/TEST_MAX_TIME=${v_bm_test_time}/g" ${bm_dir}/${bm_conf}/conf*/config.properties
bm_log_dir="${bm_dir}/${testdb}"
# 核心逻辑：判断目录是否不存在，不存在则创建
if [ ! -d "${bm_log_dir}" ]; then
    # -p 参数：递归创建父目录（比如bm_dir不存在也会自动创建），且避免重复创建报错
    mkdir -p "${bm_log_dir}"
    echo "目录 ${bm_log_dir} 不存在，已创建"
else
    echo "目录 ${bm_log_dir} 已存在，无需创建"
fi

bm_test_time=`date +%Y_%m_%d_%H_%M_%S`
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf1 > ${bm_log_dir}/${bm_test_time}_tree_bm1.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf2 > ${bm_log_dir}/${bm_test_time}_tree_bm2.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf3 > ${bm_log_dir}/${bm_test_time}_table_bm3.out &
while true
do
        v_ts_num=`${cli_dir}/sbin/start-cli.sh -u tree_user -h ${query_ip} -e "count timeseries root.**;"|grep "| "|awk -F '|' '{gsub(" ","");print $2}'`
        if [[ ${v_ts_num} -ge ${ts_num} ]];then
                break
        else
                sleep 10
        fi
done
sleep 60
}
function wait_sync_done()
{
local max_wait_time=$1
   ${cli_dir}/sbin/start-cli.sh -u ${v_sys_super_user} ${ssl_str} -h ${query_ip} -e "flush;">${cur_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -u ${v_sys_super_user} ${ssl_str} -h ${query_ip} -e "show datanodes;">${cur_dir}/tmp.out
   cat ${cur_dir}/tmp.out |grep Running|awk -F "|" '{gsub(" ","");print $4}'>${cur_dir}/tmp1.out
   mv ${cur_dir}/tmp1.out ${cur_dir}/tmp.out
   exec 3<${cur_dir}/tmp.out
   while read line<&3
   do
   while true
   do
   ssh ${os_user_name}@${line} "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep db_table">${cur_dir}/tmp1.out
   ssh ${os_user_name}@${line} "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep root.test">${cur_dir}/tmp2.out
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
wait_for_sync_completion() {
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

function check_data_consistent()
{
wait_sync_done 180
wait_for_sync_completion
   ${cli_dir}/sbin/start-cli.sh -u ${v_sys_super_user} ${ssl_str} -h ${query_ip} -e "show datanodes;">${cur_dir}/tmp.out
   cat ${cur_dir}/tmp.out |grep Running|awk -F "|" '{gsub(" ","");print $4}'>${cur_dir}/tmp1.out
   mv ${cur_dir}/tmp1.out ${cur_dir}/tmp.out
   sql1="select count(s_0),count(s_1000),count(s_2000),count(s_3000),count(s_4000),count(s_5000),count(s_6000),count(s_7000),count(s_8000),count(s_9999) from root.testdb.g_0.** align by device;"
   sql2="select device_id,count(s_0),count(s_1000),count(s_2000),count(s_3000),count(s_4000),count(s_5000),count(s_6000),count(s_7000),count(s_8000),count(s_9999) from tabledb_g_0.table_0 group by device_id order by device_id;"
   exception_num=0
   # all online
   while true
   do
   ${cli_dir}/sbin/start-cli.sh -u tree_user ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql1}" >${cur_dir}/q_all_online_tree.out
   v_exception_num=`grep Exception ${cur_dir}/q_all_online_tree.out|wc -l`
   if [[ ${v_exception_num} = 0 ]];then
	   break
   else
           let exception_num++
	   sleep 1
   fi
   if [[ ${exception_num} -ge 10 ]];then
      let fail_flag++
      break
   fi
   done
   exception_num=0
   while true
   do
   ${cli_dir}/sbin/start-cli.sh -u table_user ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql2}" >${cur_dir}/q_all_online_table.out
   v_exception_num=`grep Exception ${cur_dir}/q_all_online_table.out|wc -l`
   if [[ ${v_exception_num} = 0 ]];then
           break
   else
           let exception_num++
           sleep 1
   fi
   if [[ ${exception_num} -ge 10 ]];then
      let fail_flag++
      break
   fi

   done

   # stop dn
   exec 3<${cur_dir}/tmp.out
   while read line<&3
   do
   query_ip=`head -1 ${cur_dir}/tmp.out`
   query_ip2=`tail -1 ${cur_dir}/tmp.out`

      # stop dn
      ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};./sbin/stop-datanode.sh"
      check_dn_jps ${line} 120
      if [[ ${query_ip} = ${line} ]];then
         query_ip=${query_ip2}
      fi
      v_ip=`echo ${line}|awk -F '.' '{print $4}'`
      exception_num=0
      while true
      do
      ${cli_dir}/sbin/start-cli.sh -u tree_user ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql1}" >${cur_dir}/q_stop_ip${v_ip}_tree.out
      v_exception_num=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_tree.out|wc -l`
      if [[ ${v_exception_num} = 0 ]];then
           break
      else
           let exception_num++
           sleep 1
      fi
   if [[ ${exception_num} -ge 10 ]];then
      let fail_flag++
      break
   fi

      done
   exception_num=0
      while true
      do

      ${cli_dir}/sbin/start-cli.sh -u table_user ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql2}" >${cur_dir}/q_stop_ip${v_ip}_table.out
      v_exception_num=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table.out|wc -l`
      if [[ ${v_exception_num} = 0 ]];then
           break
      else
           let exception_num++
           sleep 1
      fi
   if [[ ${exception_num} -ge 10 ]];then
      let fail_flag++
      break
   fi

      done

      v_diff_tree=`diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_stop_ip${v_ip}_tree.out|grep "root"|wc -l`
      v_diff_table=`diff ${cur_dir}/q_all_online_table.out ${cur_dir}/q_stop_ip${v_ip}_table.out|grep "d_"|wc -l`
      v_diff_total=$((v_diff_tree+v_diff_table))
      if [[ ${v_diff_total} -gt 0 ]];then
         let fail_flag++
         diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_stop_ip${v_ip}_tree.out|grep "root"
         diff ${cur_dir}/q_all_online_table.out ${cur_dir}/q_stop_ip${v_ip}_table.out|grep "d_"
         v_warnMessage="Failed to check replica data consistency."
         echo "diff : ${v_diff_total}"
      fi
      # restart
      v_start_time=`date +%s`
      ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};./sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
      while true
      do
      v_start_ok=`${cli_dir}/sbin/start-cli.sh -u ${v_sys_super_user} ${ssl_str} -h ${line}  -timeout 3600 -e "show datanodes;"|grep "${line}|"|grep Running|wc -l`
      if [[ ${v_start_ok} -gt 0 ]];then
         break
      else
         sleep 1
      fi
      v_cur_time=`date +%s`
      v_elp_time=$((v_cur_time-v_start_time))
      if [[ ${v_elp_time} -gt 180 ]];then
         let fail_flag++
         echo "restart ${line} failed."
         return
      fi
      done
   done
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
	   let backup_log_flag++
           v_warnMessage="${v_warnMessage}DN NPE."
           echo "DN ${line} NullPointer : ${v_npe}"
   fi
   if [[ ${v_dn_total_err} -gt 0 ]];then
	   let fail_flag++
	   let backup_log_flag++
           v_warnMessage="${v_warnMessage}DN unexp log."
	   echo "DN ${line} has error: ${v_dn_total_err}"
   fi

done


}
# 检查目标DataNode是否已经包含指定的Region
function is_region_on_target_dn() {
    local region_id=$1
    local target_dn_id=$2
    local dialect=$3
    
    # 获取目标DataNode上已有的Region列表
    local target_regions=$(${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_mig_user_name} -sql_dialect "$dialect" -e "show regions;" | \
        grep "Region|"|awk -F '|' '{gsub(" ",""); print $2","$8}'|grep ",${target_dn_id}"| \
        awk -F ',' '{gsub(" ", "", $2); print $1}' | tr '\n' ' ')
    # 检查目标Region是否存在于目标DataNode上
    for existing_region in $target_regions; do
        if [[ "$existing_region" == "$region_id" ]]; then
            return 0  # 区域已存在，返回真
        fi
    done
    return 1  # 区域不存在，返回假
}

function migrate_region()
{
   local v_mig_id=$1
   local v_mig_from_dn_id=$2
   local v_mig_to_dn_id=$3
   local v_dialect=$4
   
   # 检查目标DataNode是否已经包含要迁移的Region
   if is_region_on_target_dn "$v_mig_id" "$v_mig_to_dn_id" "$v_dialect"; then
       echo "⚠️  Region ${v_mig_id} 已经存在于目标DataNode ${v_mig_to_dn_id} 上，跳过迁移"
       return 0
   fi
   
   # exec migrate
   echo "执行迁移: migrate region ${v_mig_id} from ${v_mig_from_dn_id} to ${v_mig_to_dn_id} (dialect: ${v_dialect})"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -u ${v_mig_user_name}  -sql_dialect ${v_dialect} -e "migrate region ${v_mig_id} from ${v_mig_from_dn_id} to ${v_mig_to_dn_id};" > ${cur_dir}/tmp.out
   check_res "successfully" 1 "migrate region ${v_mig_id} from ${v_mig_from_dn_id} to ${v_mig_to_dn_id}"
   if [[ ${fail_flag} = 0 ]];then
        # 初始化连续v_mig_status_num=0的计数器
        local count_zero_status=0
        # 定义连续3次为退出阈值
        local MAX_ZERO_COUNT=3

        while true
        do
            # 获取迁移状态数量（Adding/Removing的region数）
            v_mig_status_num=$(${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -u ${v_mig_user_name} -sql_dialect ${v_dialect}  -e "show regions;" | egrep "Adding|Removing" | wc -l)

            ## 连续3次v_mig_status_num=0
            # 重置/累加计数器
            if [[ ${v_mig_status_num} -eq 0 ]]; then
                count_zero_status=$((count_zero_status + 1))
                echo "当前v_mig_status_num=0，连续计数：${count_zero_status}/${MAX_ZERO_COUNT}"
            else
                count_zero_status=0  # 非0则重置计数器
                echo "当前v_mig_status_num=${v_mig_status_num}，重置连续0计数"
            fi

            # 检查是否达到连续3次0
            if [[ ${count_zero_status} -ge ${MAX_ZERO_COUNT} ]]; then
                echo "满足条件：连续${MAX_ZERO_COUNT}次v_mig_status_num=0，迁移完成"
                break
            fi

            # 未满足条件，休眠60秒后继续循环
            sleep 60
        done
   fi
}

# 动态解析所有DataNode信息，并过滤掉源节点（修复IP字符串子集匹配问题）
function get_all_target_datanodes() {
    # 执行show datanodes并保存完整输出
    local datanodes_output=$(${cli_dir}/sbin/start-cli.sh -u ${v_mig_user_name} -h ${query_ip} -sql_dialect tree -e "show datanodes;")
    if [[ -z "$datanodes_output" ]]; then
        echo "❌ 执行 show datanodes 失败，输出为空" >&2
        return 1
    fi

    # 第一步：解析表头，找到RpcAddress和NodeID列的位置
    local header_line=$(echo "$datanodes_output" | grep -m1 "NodeID")
    if [[ -z "$header_line" ]]; then
        echo "❌ 未找到 show datanodes 表头，无法解析列位置" >&2
        return 1
    fi

    local -a headers=()
    IFS='|' read -ra headers <<< "$(echo "$header_line" | tr -d ' ')"
    
    local rpc_addr_col=-1
    local node_id_col=-1
    for i in "${!headers[@]}"; do
        if [[ "${headers[$i]}" == "RpcAddress" ]]; then
            rpc_addr_col=$i
        elif [[ "${headers[$i]}" == "NodeID" ]]; then
            node_id_col=$i
        fi
    done

    if [[ $rpc_addr_col -eq -1 || $node_id_col -eq -1 ]]; then
        echo "❌ 未找到 RpcAddress 或 NodeID 列，表头：${header_line}" >&2
        return 1
    fi

    # 第二步：解析数据行，过滤源节点，输出有效节点
    echo "$datanodes_output" | \
        grep -v "NodeID" | grep -v "Total line number" | grep -v "It costs" | \
        while IFS='|' read -ra cols; do
            # 修复：确保变量正确绑定
            if [[ ${#cols[@]} -gt $rpc_addr_col && ${#cols[@]} -gt $node_id_col ]]; then
                local rpc_address=$(echo "${cols[$rpc_addr_col]}" | tr -d ' ' | xargs)
                local node_id=$(echo "${cols[$node_id_col]}" | tr -d ' ' | xargs)
                
                # 跳过源节点 + 过滤空值
                if [[ -n "$rpc_address" && -n "$node_id" && ! "$rpc_address" =~ ^${mig_from_ip}$ ]]; then
                    echo "$node_id $rpc_address"
                fi
            fi
        done
}
# 统计目标节点上的Region数量，选择最少的节点
function get_least_loaded_dn() {
    local dialect=$1
    local region_id=$2  # 新增参数：要迁移的Region ID
    
    # 初始化所有目标节点的计数为0
    declare -A dn_count
    
    # 修复：用临时文件替代进程替换，兼容所有Shell
    local tmp_dn_list="${cur_dir}/tmp_dn_list_$$.txt"
    get_all_target_datanodes > "$tmp_dn_list"
    
    # 读取目标节点列表，初始化计数
    while IFS=' ' read -r dn_id _; do
        if [[ -n "$dn_id" ]]; then
            # 检查此DataNode是否已经包含该Region
            if ! is_region_on_target_dn "$region_id" "$dn_id" "$dialect"; then
                dn_count[$dn_id]=0
            fi
        fi
    done < "$tmp_dn_list"
    rm -f "$tmp_dn_list"

    # 检查是否有可用的目标节点
    if [[ ${#dn_count[@]} -eq 0 ]]; then
        echo "❌ 错误：未找到任何可用的目标 DataNode，无法进行迁移" >&2
        return 1
    fi

    # 统计每个节点上的Region数量
    local tmp_region_list="${cur_dir}/tmp_region_list_$$.txt"
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_mig_user_name} -sql_dialect "$dialect" -e "show regions;" | \
        grep -v "Total line number" | grep -v "It costs" | \
        awk -F '|' '{gsub(" ", "", $7); print $7}' > "$tmp_region_list"
    
    while IFS= read -r dn_id; do
        # 核心修复：只统计已初始化的dn_id，避免空值或不存在的dn_id导致数组下标错误
        if [[ -n "$dn_id" && -n "${dn_count[$dn_id]+isset}" ]]; then
            dn_count[$dn_id]=$(( ${dn_count[$dn_id]} + 1 ))
        fi
    done < "$tmp_region_list"
    rm -f "$tmp_region_list"

    # 找到数量最少的节点
    local min_count=999999
    local target_dn=""
    for dn_id in "${!dn_count[@]}"; do
        if [[ ${dn_count[$dn_id]} -lt $min_count ]]; then
            min_count=${dn_count[$dn_id]}
            target_dn=$dn_id
        fi
    done

    # 最终检查：确保返回了有效的DN ID
    if [[ -z "$target_dn" ]]; then
        echo "❌ 错误：无法确定负载最少的目标 DataNode" >&2
        return 1
    fi

    echo "$target_dn"
}

# 从可用的目标DataNode中查找一个不包含指定Region的节点
function find_available_target_dn() {
    local dialect=$1
    local region_id=$2
    
    # 获取所有目标DataNode列表
    local tmp_dn_list="${cur_dir}/tmp_dn_list_$$.txt"
    get_all_target_datanodes > "$tmp_dn_list"
    
    # 遍历所有目标节点，找到第一个不包含该Region的节点
    while IFS=' ' read -r dn_id _; do
        if [[ -n "$dn_id" ]]; then
            # 检查此DataNode是否已经包含该Region
            if ! is_region_on_target_dn "$region_id" "$dn_id" "$dialect"; then
                rm -f "$tmp_dn_list"
                echo "$dn_id"
                return 0
            fi
        fi
    done < "$tmp_dn_list"
    
    rm -f "$tmp_dn_list"
    # 如果没有找到合适的节点，则返回错误
    echo "❌ 错误：找不到可用的目标DataNode，所有节点都已包含Region ${region_id}" >&2
    return 1
}
# 同步优化get_source_dn_id函数（避免IP子集匹配）
function get_source_dn_id() {
    # 执行show datanodes并保存完整输出
    local datanodes_output=$(${cli_dir}/sbin/start-cli.sh -u ${v_mig_user_name} -h ${query_ip} -sql_dialect tree -e "show datanodes;")
    if [[ -z "$datanodes_output" ]]; then
        echo "❌ 执行 show datanodes 失败，输出为空" >&2
        return 1
    fi

    # ========== 第一步：解析表头，找到RpcAddress和NodeID列的位置 ==========
    local header_line=$(echo "$datanodes_output" | grep -m1 "NodeID")  # 提取表头行
    if [[ -z "$header_line" ]]; then
        echo "❌ 未找到 show datanodes 表头，无法解析列位置" >&2
        return 1
    fi

    # 拆分表头为数组，忽略空格，获取列名
    local -a headers=()
    IFS='|' read -ra headers <<< "$(echo "$header_line" | tr -d ' ')"
    
    # 查找RpcAddress和NodeID列的索引（从0开始）
    local rpc_addr_col=-1
    local node_id_col=-1
    for i in "${!headers[@]}"; do
        if [[ "${headers[$i]}" == "RpcAddress" ]]; then
            rpc_addr_col=$i
        elif [[ "${headers[$i]}" == "NodeID" ]]; then
            node_id_col=$i
        fi
    done

    # 检查列索引是否有效
    if [[ $rpc_addr_col -eq -1 || $node_id_col -eq -1 ]]; then
        echo "❌ 未找到 RpcAddress 或 NodeID 列，表头：${header_line}" >&2
        return 1
    fi

    # ========== 第二步：解析数据行，精准匹配目标IP ==========
    echo "$datanodes_output" | \
        grep -v "NodeID" | grep -v "Total line number" | grep -v "It costs" | \
        while IFS='|' read -ra cols; do
            # 修复：确保变量正确绑定
            if [[ ${#cols[@]} -gt $rpc_addr_col && ${#cols[@]} -gt $node_id_col ]]; then
                # 清理每一列的空格（关键）
                local rpc_address=$(echo "${cols[$rpc_addr_col]}" | tr -d ' ' | xargs)
                local node_id=$(echo "${cols[$node_id_col]}" | tr -d ' ' | xargs)
                
                # 精准匹配目标IP，避免子集问题
                if [[ "$rpc_address" =~ ^${mig_from_ip}$ ]]; then
                    echo "$node_id"
                    break  # 找到后立即退出，避免多输出
                fi
            fi
        done
}
# 主执行函数：迁移指定dialect下的所有Region
function migrate_all_regions_for_dialect() {
    local dialect=$1
    local from_dn_id=$(get_source_dn_id)
    if [[ -z "$from_dn_id" ]]; then
        echo "❌ 错误：无法获取源节点 DataNode ID，跳过 ${dialect} 模型迁移"
        return 1
    fi

    echo "=== 开始迁移 dialect=${dialect} 下，从节点 ${mig_from_ip} (DN: ${from_dn_id}) 的所有Region ==="
    local region_list_file="${cur_dir}/v_${dialect}_mig_id_list.txt"
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_mig_user_name} -sql_dialect "$dialect" -e "show regions;" | \
        grep "${mig_from_ip}|" | grep -v "Total line number" | grep -v "It costs" | \
        awk -F '|' '{gsub(" ", "", $2); print $2}' > "$region_list_file"
    
    if [[ ! -s "$region_list_file" ]]; then
        echo "⚠️  在 ${dialect} 模型下，未找到需要从 ${mig_from_ip} 迁移的Region"
        return 0
    fi

    while IFS= read -r v_mig_id; do
        if [[ -n "$v_mig_id" ]]; then
            # 每次迁移前，查找可用的目标DataNode（不包含该Region的节点）
            local to_dn_id=$(find_available_target_dn "$dialect" "$v_mig_id")
            
            # 核心修复：检查to_dn_id是否有效，无效则终止迁移
            if [[ -z "$to_dn_id" ]]; then
                echo "❌ 迁移 Region ${v_mig_id} 失败：无法获取有效的目标 DataNode ID，终止当前模型迁移"
                return 1
            fi

            echo "将迁移 Region ${v_mig_id} 从 DN ${from_dn_id} 到 DN ${to_dn_id} (dialect: ${dialect})"
            migrate_region "$v_mig_id" "$from_dn_id" "$to_dn_id" "$dialect"
            
            # 检查迁移是否失败
            if [[ ${fail_flag} -ne 0 ]]; then
                echo "❌ 迁移 Region ${v_mig_id} 失败，终止当前模型迁移"
                return 1
            fi
        fi
    done < "$region_list_file"
    
    echo "=== 完成 dialect=${dialect} 下的所有Region迁移 ==="
    return 0
}
# 主入口：迁移树模型和表模型的所有Region
function exec_migrate_region()
{
    echo "开始清空节点 ${mig_from_ip} 上的所有Region..."
    # 先迁移树模型（tree）
    migrate_all_regions_for_dialect "tree"
    # 再迁移表模型（table）
    migrate_all_regions_for_dialect "table"
    echo "✅ 所有迁移任务执行完毕！"
}
# 同步优化缩容函数中的节点检查逻辑（核心修复点）
function remove_datanode() {
    local from_dn_id=$(get_source_dn_id)
    if [[ -z "$from_dn_id" ]]; then
        echo "❌ 未找到 ${mig_from_ip} 对应的DataNode ID，缩容失败"
        return 1
    fi

    echo "=== 开始缩容节点 ${mig_from_ip} (DN ID: ${from_dn_id}) ==="
    # 执行remove datanode命令
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_mig_user_name} -sql_dialect tree -e "remove datanode ${from_dn_id};" > ${cur_dir}/remove_dn.out
    check_res "successfully" 1 "remove datanode ${from_dn_id}"

    if [[ ${fail_flag} -ne 0 ]]; then
        echo "❌ 执行remove datanode命令失败，终止缩容流程"
        return 1
    fi

    # 等待缩容完成：循环检查show datanodes中是否还有该节点（修复IP子集匹配）
    local wait_seconds=0
    local max_wait_seconds=1800  # 最大等待时间：30分钟
    local check_interval=30      # 检查间隔：30秒
    while true; do
        # 核心修复：用awk精准提取RpcAddress列，再用^$匹配整行IP，避免子集问题
        local dn_exists=$(${cli_dir}/sbin/start-cli.sh -u ${v_sys_super_user} -h ${query_ip} -sql_dialect tree -e "show datanodes;" | \
            grep -v "NodeID" | grep -v "Total line number" | grep -v "It costs" | \
            awk -F '|' '{gsub(" ", "", $4); print $4}' | grep -c "^${mig_from_ip}$")
        
        if [[ ${dn_exists} -eq 0 ]]; then
            echo "✅ 缩容完成：${mig_from_ip} 已从DataNode列表中移除"
            break
        fi

        # 检查是否超时
        if [[ ${wait_seconds} -ge ${max_wait_seconds} ]]; then
            echo "❌ 缩容超时：等待${max_wait_seconds}秒后，${mig_from_ip} 仍未从DataNode列表中移除"
            return 1
        fi

        echo "⏳ 等待缩容完成：已等待${wait_seconds}秒，${mig_from_ip} 仍在DataNode列表中（剩余等待时间：$((max_wait_seconds - wait_seconds))秒）"
        sleep ${check_interval}
        wait_seconds=$((wait_seconds + check_interval))
    done
}
function wait_benchmark()
{
    while true
    do
        v_bm_num=`jps|grep App|wc -l`
        if [[ ${v_bm_num} -gt 0 ]];then
            sleep 120
        else
            ${cli_dir}/sbin/start-cli.sh -u ${v_sys_super_user} -h ${query_ip} -sql_dialect tree -e "flush;"
            ${cli_dir}/sbin/start-cli.sh -u ${v_sys_super_user} -h ${query_ip} -sql_dialect table -e "flush;"
            break
            return 0
        fi
    done
}
function testcase1()
{
# 执行迁移
exec_migrate_region
remove_datanode
# wait benchmark
wait_benchmark
# check data
check_data_consistent
#check log
check_log
}
# start cluster 
echo "">${log_file}
start_db
# start test time
v_start_test_time=`date +%s`
create_user
if [[ ${prepare_fail_flag} = 0 ]];then
start_bm
testcase1
fi
v_end_test_time=`date +%s`
v_elp_time=$((v_end_test_time-v_start_test_time))
# record test result
function write_result()
{
   v_result_iotdb_ip=$(grep ^test_result_iotdb_ip "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
   v_bm_max_value=`grep "Test elapsed" ${bm_log_dir}/${bm_test_time}*out|awk '{print $8}'|sort -n|tail -1`

   v_bm_sum_value=`grep "Test elapsed" ${bm_log_dir}/${bm_test_time}*out | awk '{print $8}' | sort -n | awk '{sum+=$1} END {print sum}'`
   if [[ ${fail_flag} -gt 0 ]];then
           ${cli_dir}/sbin/start-cli.sh -h ${v_result_iotdb_ip} -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','FAIL',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
 
           echo "testcase1 fail"
   else
           echo "testcase1 pass"
           ${cli_dir}/sbin/start-cli.sh -h ${v_result_iotdb_ip} -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','PASS',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
 
# remove bm logs
#        rm -rf ${bm_log_dir}/${bm_test_time}_pre_bm1.out
#        rm -rf ${bm_log_dir}/${bm_test_time}_pre_bm2.out
#        rm -rf ${bm_log_dir}/${bm_test_time}_tree_bm1.out
#        rm -rf ${bm_log_dir}/${bm_test_time}_tree_bm2.out
#        rm -rf ${bm_log_dir}/${bm_test_time}_view_bm1.out
#        rm -rf ${bm_log_dir}/${bm_test_time}_view_bm2.out
   fi

# backup logs?
#if [[ ${backup_log_flag} -gt 0 ]];then
## stop cluster
#v_tc_name_pre=`echo ${SCRIPT_NAME}|awk -F '.' '{print $1}'`
#v_backup_time=`date +"%Y_%m_%d_%H_%M_%S"`
#sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
#sh -x ${clean_env_dir}/backup_cluster_logs.sh ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
#
#fi 
}
write_result
