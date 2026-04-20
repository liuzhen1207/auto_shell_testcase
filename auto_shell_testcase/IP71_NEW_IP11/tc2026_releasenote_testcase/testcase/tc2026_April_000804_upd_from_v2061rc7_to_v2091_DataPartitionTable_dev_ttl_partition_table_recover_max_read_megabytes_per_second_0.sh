#!/bin/bash
# tree table normal test
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
backup_dir=${db_parent_dir}/tc2026_data_backup/v2061_rc7_20250915_802dd96_dev_ttl
total_node_num=$((cn_num+dn_num))
log_file="${cur_dir}/set_conf_parallel.log"
ssl_str=""
backup_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensus"
backup_data_log_flag=0
# 清理旧节点文件，复制新配置
rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

# 读取种子节点IP（兼容低版本）
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

fail_flag=0
sync_fail_flag=0
test_begin_sec=$(date +%s)

max_concurrent=4     # 最大并发数，根据数据库性能调整（建议5-10）
tree_max_concurrent=4     # 最大并发数，根据数据库性能调整（建议5-10）
# 表模型固定配置
TABLE_DB_NAME="tabledb_g_0"
TABLE_NAME="table_0"

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
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=10"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=20"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_seq_space_compaction=.*" "enable_seq_space_compaction=true"
        batch_set_sys_conf ".*enable_unseq_space_compaction=.*" "enable_unseq_space_compaction=true"
        batch_set_sys_conf ".*enable_cross_space_compaction=.*" "enable_cross_space_compaction=true"
        batch_set_sys_conf ".*dn_thrift_max_frame_size=.*" "dn_thrift_max_frame_size=536870912"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        batch_set_sys_conf ".*partition_table_recover_max_read_megabytes_per_second=.*" "partition_table_recover_max_read_megabytes_per_second=0"


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
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="256G"/g' ${db_dir}/conf/datanode-env.sh
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
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=10"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=20"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_seq_space_compaction=.*" "enable_seq_space_compaction=true"
        batch_set_sys_conf ".*enable_unseq_space_compaction=.*" "enable_unseq_space_compaction=true"
        batch_set_sys_conf ".*enable_cross_space_compaction=.*" "enable_cross_space_compaction=true"
        batch_set_sys_conf ".*dn_thrift_max_frame_size=.*" "dn_thrift_max_frame_size=536870912"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        batch_set_sys_conf ".*partition_table_recover_max_read_megabytes_per_second=.*" "partition_table_recover_max_read_megabytes_per_second=0"


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
# copy data
exec 3<${nodeinfo_dir}/datanode.txt
while read line<&3
do
    # 后台并发执行（用子进程 &）
    (
        echo "【后台处理】节点 $line 开始检查目录并拷贝数据..."
        
        # 1. 检查目录是否存在
        if ssh ${os_user_name}@${line} test -d "${db_dir}"; then
            echo "【节点 $line】目录检查 ok."
        else
            ((fail_flag++))
            v_warnMessage="${v_warnMessage} ${db_dir} not exist on $line"
            echo "【错误】节点 $line：${db_dir} 不存在"
        fi

        # 2. 远程拷贝数据
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data ${db_dir}/"
        if [ $? -ne 0 ]; then
            ((fail_flag++))
            echo "【失败】节点 $line 拷贝数据失败，fail_flag=$fail_flag"
            v_warnMessage="${v_warnMessage} copy backup data failed on $line"
        fi

        echo "【完成】节点 $line 处理完毕"
    ) &  # 放入后台

    sleep 0.1  # 避免并发创建太快冲突
done

# 等待所有后台拷贝任务全部完成
echo -e "\n等待所有 DataNode 节点数据拷贝完成..."
wait

# 所有节点执行完成后，才会走到这里
echo -e "\n✅ 所有节点后台任务全部执行完毕！继续执行后续逻辑..."
exec 3<&-  # 关闭文件描述符

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
        check_file=$1
        check_str=$2
        check_num=$3
        v_desc=$4
        v_act_num=`grep "${check_str}" ${check_file}|wc -l`
        if [[ ${v_act_num} -eq ${check_num} ]];then
                echo "check result success."
        else
                let fail_flag++
                cat ${check_file}
                echo "check result fail."
		v_warnMessage="${v_warnMessage}${v_desc} failed."
        fi
}

function start_bm()
{
bm_dir=${cur_dir}/../benchmark/bm_20251220_38c839b_v20
bm_conf=ttl_partition_seq
#get root password
v_20_pass=`grep ^passwd_param= ${cli_dir}/sbin/start-cli.sh |grep TimechoDB|wc -l`
if [[ ${v_20_pass} -gt 0 ]];then
        bm_root_pw="TimechoDB@2021"
else

        bm_root_pw="root"
fi
#sed -i 's/CREATE_SCHEMA=.*/CREATE_SCHEMA=true/g' ${bm_dir}/${bm_conf}/conf*/config.*
#sed -i 's/START_TIME=.*/START_TIME=1970-01-01T08:00:00+08:00/g' ${bm_dir}/${bm_conf}/conf*/config.*
#sed -i "s/^PASSWORD=.*/PASSWORD=${bm_root_pw}/g" ${bm_dir}/${bm_conf}/conf*/config.properties
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
t=`date +%Y_%m_%d_%H_%M_%S`
bm_test_time=${t}
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf1 >> ${bm_log_dir}/${t}_bm1.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf2 >> ${bm_log_dir}/${t}_bm2.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf3 >> ${bm_log_dir}/${t}_bm3.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf4 >> ${bm_log_dir}/${t}_bm4.out &
wait
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf5 >> ${bm_log_dir}/${t}_bm5.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf6 >> ${bm_log_dir}/${t}_bm6.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf7 >> ${bm_log_dir}/${t}_bm7.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf8 >> ${bm_log_dir}/${t}_bm8.out &

wait

# check bm res
v_fail_oper_num=`grep throughput  -A 1 ${bm_log_dir}/${bm_test_time}_bm*.out |grep INGESTION|awk '{sum+=$4}END{print sum}'`
if [[ ${v_fail_oper_num} -gt 0 ]];then
let fail_flag++
v_warnMessage="${v_warnMessage}benchmark has failed."
fi
}
function check_res_eq()
{
        v_exp_msg=$1
        v_exp_num=$2
        v_act_num=$(grep ${v_exp_msg} ${cur_dir}/tmp.out|wc -l)
        if [[ ${v_act_num} = ${v_exp_num} ]];then
                echo "pass"
        else
                let fail_flag++
                v_warnMessage="${v_warnMessage}check_res ${v_exp_msg} exp num=${v_exp_num} failed."
                cat ${cur_dir}/tmp.out
        fi
}

function wait_sync_done()
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
   ssh ${os_user_name}@${line} "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep tabledb">${cur_dir}/tmp1.out
   ssh ${os_user_name}@${line} "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep root.treedb">${cur_dir}/tmp2.out
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
   v_dn_str=`ssh ${os_user_name}@${v_dn_ip} "source /etc/profile;sudo jps|grep DataNode"`
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
wait_for_sync_completion() {
    # Prometheus服务器信息
    local PROMETHEUS_URL=$(grep ^monitor_url "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
    local PROMETHEUS_USER=admin
    local PROMETHEUS_PASS=admin

    # 关联数组：追踪每个DataNode上一次的sync lag状态（true=上一次>0，false=上一次=0）
    declare -A last_node_status

    echo "开始监控 Total Sync Lag，直到所有 DataNode 的 Sync Lag 均为 0 为止..."

    while true; do
        # 标记本次检测是否所有节点都为0（核心退出条件）
        local all_zero=true
        # 标记本次是否有节点>0（用于状态追踪）
        local has_non_zero=false

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
                all_zero=false  # 只要有一个节点>0，就不满足退出条件

                # 核心逻辑：只有上一次状态也是>0时，才累加fail_flag
                if [[ ${last_node_status[$instance]} == "true" ]]; then
                    ((fail_flag++))
                    ((sync_fail_flag++))
                    v_warnMessage="${v_warnMessage}sync lag > 0: 实例 $instance 持续大于0，fail_flag 累加至 $fail_flag."
                    echo "  ⚠️  $v_warnMessage"
                else
                    # 首次检测到>0，仅更新状态，不累加
                    v_warnMessage="${v_warnMessage}sync lag > 0: 实例 $instance 首次大于0，暂不累加fail_flag."
                    echo "  ⚠️  $v_warnMessage"
                fi

                # 更新当前节点的状态为>0
                last_node_status[$instance]="true"
            else
                # sync lag=0，更新状态为false，不累加
                last_node_status[$instance]="false"
            fi
        done

        # 核心退出条件：本次检测所有节点Sync Lag均为0
        if $all_zero; then
            echo "🎉 同步完成！所有 DataNode 的 Total Sync Lag 均为 0"
            echo "最终 fail_flag: $fail_flag, sync_fail_flag: $sync_fail_flag"
            return 0
        fi

        # 存在节点>0，继续监控（间隔1秒检测一次）
        echo "  ❌ 仍有DataNode Sync Lag>0，1秒后继续检测..."
        sleep 1
    done
}
function check_data_consistent()
{
wait_sync_done 180
wait_for_sync_completion

   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">${cur_dir}/tmp.out
   cat ${cur_dir}/tmp.out |grep Running|awk -F "|" '{gsub(" ","");print $4}'>${cur_dir}/tmp1.out
   mv ${cur_dir}/tmp1.out ${cur_dir}/tmp_node.out
   sql1="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from root.test.g_0.** align by device;"
   sql2="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table1_0 group by device_id order by device_id;"
   sql3="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table2_0 group by device_id order by device_id;"
   sql4="count timeslotid where database=root.test.g_0;"
   sql5="count timepartition where database=root.test.g_0;"
   sql6="show timepartition where database=root.test.g_0;"
   sql7="show timeslotid where database=root.test.g_0;"
   sql8="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from root.test.g_0.** where time>=1970-01-09T09:00:03.000+08:00 and time<=2026-01-22T10:46:42.000+08:00 align by device;"
   sql9="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table1_0 where time>=1970-01-09T09:00:03.000+08:00 and time<=2026-01-22T10:46:42.000+08:00 group by device_id order by device_id;"
   sql10="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table2_0 where time>=1970-01-09T09:00:03.000+08:00 and time<=2026-01-22T10:46:42.000+08:00 group by device_id order by device_id;"
   # all online
   exception_num=0
   while true
   do
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql1}" >${cur_dir}/q_all_online_tree.out
   v_exception_num=`grep Exception ${cur_dir}/q_all_online_tree.out|wc -l`
   v_row_num=`grep root.test ${cur_dir}/q_all_online_tree.out|wc -l`
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
   if [[ ${v_row_num} != 100 ]];then
	   let fail_flag++
	   v_warnMessage="${v_warnMessage}tree all online query row num != 20."
   fi
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql4}" >${cur_dir}/tmp.out
   check_res_eq " 784|" 1
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql5}" >${cur_dir}/tmp.out
   check_res_eq " 784|" 1
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql6}" >${cur_dir}/tmp.out
   check_res_eq " 2925|" 1
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql7}" >${cur_dir}/tmp.out
   check_res_eq " 2925|" 1
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql8}" >${cur_dir}/q_all_online_tree_q8.out
   v_row_num=`grep root.test ${cur_dir}/q_all_online_tree_q8.out|wc -l`
   if [[ ${v_row_num} != 100 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}tree all online query sql8 row num != 20."
   fi

   exception_num=0
   while true
   do
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql2}" >${cur_dir}/q_all_online_table1.out
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql3}" >${cur_dir}/q_all_online_table2.out
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql9}" >${cur_dir}/q_all_online_table1_q9.out
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql10}" >${cur_dir}/q_all_online_table2_q10.out
   v_exception_num1=`grep Exception ${cur_dir}/q_all_online_table1.out|wc -l`
   v_exception_num2=`grep Exception ${cur_dir}/q_all_online_table2.out|wc -l`
   v_exception_num3=`grep Exception ${cur_dir}/q_all_online_table1_q9.out|wc -l`
   v_exception_num4=`grep Exception ${cur_dir}/q_all_online_table2_q10.out|wc -l`
   v_row_num1=`grep d_ ${cur_dir}/q_all_online_table1.out|wc -l`
   v_row_num2=`grep d_ ${cur_dir}/q_all_online_table2.out|wc -l`
   v_row_num3=`grep d_ ${cur_dir}/q_all_online_table1_q9.out|wc -l`
   v_row_num4=`grep d_ ${cur_dir}/q_all_online_table2_q10.out|wc -l`
   v_exception_num=$((v_exception_num1+v_exception_num2+v_exception_num3+v_exception_num4))
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
   if [[ ${v_row_num1} != 50 ]]|| [[ ${v_row_num2} != 50 ]] || [[ ${v_row_num3} != 50 ]] || [[ ${v_row_num4} != 50 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}table all online query row num != 20."
   fi
   # stop dn
   exec 3<${cur_dir}/tmp_node.out
   while read line<&3
   do
   query_ip=`head -1 ${cur_dir}/tmp_node.out`
   query_ip2=`tail -1 ${cur_dir}/tmp_node.out`

      # stop dn
      ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};sudo ./sbin/stop-datanode.sh"
      check_dn_jps ${line} 120
      if [[ ${query_ip} = ${line} ]];then
         query_ip=${query_ip2}
      fi
      v_ip=`echo ${line}|awk -F '.' '{print $4}'`
      exception_num=0
      while true
      do
      ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql1}" >${cur_dir}/q_stop_ip${v_ip}_tree.out
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
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql4}" >${cur_dir}/tmp.out
   check_res_eq " 784|" 1
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql5}" >${cur_dir}/tmp.out
   check_res_eq " 784|" 1
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql6}" >${cur_dir}/tmp.out
   check_res_eq " 2925|" 1
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql7}" >${cur_dir}/tmp.out
   check_res_eq " 2925|" 1
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql8}" >${cur_dir}/q_stop_ip${v_ip}_tree_q8.out
   v_row_num=`grep root.test ${cur_dir}/q_stop_ip${v_ip}_tree_q8.out|wc -l`
   if [[ ${v_row_num} != 100 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}tree stop_ip${v_ip} query sql8 row num != 20."
   fi

      exception_num=0
      while true
      do

      ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql2}" >${cur_dir}/q_stop_ip${v_ip}_table1.out
      ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql3}" >${cur_dir}/q_stop_ip${v_ip}_table2.out
      ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql9}" >${cur_dir}/q_stop_ip${v_ip}_table1_q9.out
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql10}" >${cur_dir}/q_stop_ip${v_ip}_table2_q10.out
   v_exception_num1=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table1.out|wc -l`
   v_exception_num2=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table2.out|wc -l`
   v_exception_num3=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table1_q9.out|wc -l`
   v_exception_num4=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table2_q10.out|wc -l`
   v_row_num1=`grep d_ ${cur_dir}/q_stop_ip${v_ip}_table1.out|wc -l`
   v_row_num2=`grep d_ ${cur_dir}/q_stop_ip${v_ip}_table2.out|wc -l`
   v_row_num3=`grep d_ ${cur_dir}/q_stop_ip${v_ip}_table1_q9.out|wc -l`
   v_row_num4=`grep d_ ${cur_dir}/q_stop_ip${v_ip}_table2_q10.out|wc -l`
   v_exception_num=$((v_exception_num1+v_exception_num2+v_exception_num3+v_exception_num4))

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

      v_diff_tree=`diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_stop_ip${v_ip}_tree.out|grep "root.test"|wc -l`
      v_diff_tree1=`diff ${cur_dir}/q_all_online_tree_q8.out ${cur_dir}/q_stop_ip${v_ip}_tree_q8.out|grep "root.test"|wc -l`
      v_diff_table1=`diff ${cur_dir}/q_all_online_table1.out ${cur_dir}/q_stop_ip${v_ip}_table1.out|egrep "d_"|wc -l`
      v_diff_table1_q9=`diff ${cur_dir}/q_all_online_table1_q9.out ${cur_dir}/q_stop_ip${v_ip}_table1_q9.out|egrep "d_"|wc -l`
      v_diff_table2=`diff ${cur_dir}/q_all_online_table2.out ${cur_dir}/q_stop_ip${v_ip}_table2.out|egrep "d_"|wc -l`
      v_diff_table2_q10=`diff ${cur_dir}/q_all_online_table2_q10.out ${cur_dir}/q_stop_ip${v_ip}_table2_q10.out|egrep "d_"|wc -l`
      v_diff_total=$((v_diff_tree+v_diff_table1+v_diff_table2+v_diff_tree1+v_diff_table1_q9+v_diff_table2_q10))
      if [[ ${v_diff_total} -gt 0 ]];then
         let fail_flag++
	 v_warnMessage="${v_warnMessage}.data inconsistent"
	 let backup_data_log_flag++
	 diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_stop_ip${v_ip}_tree.out
	 diff ${cur_dir}/q_all_online_table1.out ${cur_dir}/q_stop_ip${v_ip}_table1.out
	 diff ${cur_dir}/q_all_online_table2.out ${cur_dir}/q_stop_ip${v_ip}_table2.out
	 diff ${cur_dir}/q_all_online_tree_q8.out ${cur_dir}/q_stop_ip${v_ip}_tree_q8.out
	 diff ${cur_dir}/q_all_online_table1_q9.out ${cur_dir}/q_stop_ip${v_ip}_table1_q9.out
	 diff ${cur_dir}/q_all_online_table2_q10.out ${cur_dir}/q_stop_ip${v_ip}_table2_q10.out
         echo "diff : ${v_diff_total}"
      fi
      # restart
      v_start_time=`date +%s`
      ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};sudo ./sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
      while true
      do
      v_start_ok=`${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${line}  -timeout 3600 -e "show datanodes;"|grep "${line}|"|grep Running|wc -l`
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
	v_cn_exp_sum=0
exec 3<${nodeinfo_dir}/confignode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*confignode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err1=`ssh ${os_user_name}@${line} "grep BufferUnderflowException ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err2=`ssh ${os_user_name}@${line} "grep \"but return HAS_MORE_STATE\" ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err3=`ssh ${os_user_name}@${line} "grep \"ClassCastException\" ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_exp1=`ssh ${os_user_name}@${line} "grep \"Database db_g_0 has lost timeslot 0 in its data table partition\" ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err4=`ssh ${os_user_name}@${line} "grep \"ClientManagerException: java.lang.IllegalStateException: Pool not open\" ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err5=`ssh ${os_user_name}@${line} "grep \"Error waiting for roll back the REQUEST_PARTITION_TABLES state due to thread interruption\" ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_exp_sum=$((v_cn_exp_sum+v_cn_exp1))
   if [[ ${v_npe} -gt 0 ]];then
           let fail_flag++
#          let backup_log_flag++
           echo "CN ${line} NullPointer : ${v_npe}"
           v_warnMessage="${v_warnMessage}CN ${line} NullPointer: ${v_npe}."
   fi
   v_cn_err_total=$((v_cn_err1+v_cn_err2+v_cn_err3+v_cn_err4+v_cn_err5))

   if [[ ${v_cn_err_total} -gt 0 ]];then
           let fail_flag++
#           let backup_log_flag++
           echo "CN ${line} has error: ${v_cn_err_total}"
	   v_warnMessage="${v_warnMessage}CN ${line} unexpected log : ${v_cn_err_total}."
   fi
done
exec 3<${nodeinfo_dir}/datanode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*datanode*all*"
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
   v_err10=`ssh ${os_user_name}@${line} "grep \"ClassCastException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_dn_total_err=$((v_err+v_err2+v_err3+v_err4+v_err5+v_err6+v_err7+v_err8+v_err9+v_err10))

   if [[ ${v_npe} -gt 0 ]];then
           let fail_flag++
#	   let backup_log_flag++
	   v_warnMessage="${v_warnMessage}DN ${line} NullPointer: ${v_npe}."
           echo "DN ${line} NullPointer : ${v_npe}"
   fi
   if [[ ${v_dn_total_err} -gt 0 ]];then
	   let fail_flag++
#	   let backup_log_flag++
	   v_warnMessage="${v_warnMessage}DN ${line} unexpected log : ${v_dn_total_err}."
	   echo "DN ${line} has error: ${v_dn_total_err}"
   fi

done
if [[ ${v_cn_exp_sum} = 0 ]];then
	let fail_flag++
	v_warnMessage="${v_warnMessage}CN EXPECT :Database db_g_0 has lost timeslot 0 in its data table partition"
fi
}

function testcase1()
{
# check data
#before ttl check data
sleep 120
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show configuration;" > ${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out

check_data_consistent
#check log
#TTL SEC 1768953600 date -d"2000-01-22T08:00:01" +%s
ttl_time_point=948499201000
v_cur_sec=$(date +%s)
v_cur_ms=$((v_cur_sec*1000))
v_ttl_value=$((v_cur_ms-ttl_time_point))
# set ttl
for ((i=0; i<=49; i+=10))
do
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "set ttl to root.test.g_0.d1_${i} ${v_ttl_value};"
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "set ttl to root.test.g_0.d2_${i} ${v_ttl_value};"
done

${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "ALTER TABLE db_g_0.table1_0 set properties TTL=${v_ttl_value};"
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "ALTER TABLE db_g_0.table2_0 set properties TTL=${v_ttl_value};"
# sleep 
sleep 20
check_data_consistent
sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
sh -x "${prepare_env_dir}/start_cluster_v20.sh" "2" "${total_node_num}" >> "${log_file}" 2>&1
check_data_consistent
check_log

}
# start cluster
echo "">${log_file}
start_db
# start test time
v_start_test_time=`date +%s`
#start_bm
testcase1
v_end_test_time=`date +%s`
v_elp_time=$((v_end_test_time-v_start_test_time))
# record test result
function write_result()
{
   v_warnNum=${fail_flag}
   v_result_iotdb_ip=$(grep ^test_result_iotdb_ip "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
   v_bm_max_value=0

   v_bm_sum_value=0
   if [[ ${fail_flag} -gt 0 ]];then
           ${cli_dir}/sbin/start-cli.sh -h ${v_result_iotdb_ip} -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testFailMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','FAIL',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"

           echo "testcase1 fail"
   else
           echo "testcase1 pass"
           ${cli_dir}/sbin/start-cli.sh -h ${v_result_iotdb_ip} -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testFailMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','PASS',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
backup_log_flag=1
# remove bm logs
#        rm -rf ${bm_log_dir}/${bm_test_time}_pre_bm1.out
#        rm -rf ${bm_log_dir}/${bm_test_time}_pre_bm2.out
#        rm -rf ${bm_log_dir}/${bm_test_time}_tree_bm1.out
#        rm -rf ${bm_log_dir}/${bm_test_time}_tree_bm2.out
#        rm -rf ${bm_log_dir}/${bm_test_time}_view_bm1.out
#        rm -rf ${bm_log_dir}/${bm_test_time}_view_bm2.out
   fi

# backup logs?
if [[ ${backup_log_flag} -gt 0 ]];then
# stop cluster
v_tc_name_pre=`echo ${SCRIPT_NAME}|awk -F '.' '{print $1}'`
v_backup_time=`date +"%Y_%m_%d_%H_%M_%S"`
sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
sh -x ${clean_env_dir}/backup_cluster_logs.sh ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1

fi
}
write_result
