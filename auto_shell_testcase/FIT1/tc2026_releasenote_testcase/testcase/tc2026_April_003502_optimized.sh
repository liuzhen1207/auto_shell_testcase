#!/bin/bash
# ============================================================================
# IoTDB 测试脚本 - 优化版
# 功能：数据一致性检查、节点故障恢复、时间段查询校验
# ============================================================================
set -uo pipefail

# ==================== 全局变量 ====================
cur_dir="$( cd "$( dirname "$0" )" && pwd )"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

# 从配置文件读取
os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
cli_dir=${db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
cn_num=3
dn_num=3
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num+dn_num))
v_consensus="IoTConsensus"
CSV_FILE=$(grep ^CSV_FILE "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
log_file="${cur_dir}/set_conf_parallel.log"
data1_dir="/data1/iotdb_data/${testdb}/data"
data3_dir="/data3/iotdb_data/${testdb}/data"
ssl_str=""
bm_dir="${cur_dir}/../benchmark/bm_20251220_38c839b_v20"
backup_dir=/data2/tc2026_data_backup/v2021_rc5_20250401_9174fe0_ns_ttl_10s

# 状态变量
fail_flag=0
v_warnNum=0
v_warnMessage="."
backup_log_flag=0
backup_data_log_flag=0
test_begin_sec=$(date +%s)

# 清理并复制节点配置文件
rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

# 读取种子节点 IP
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

# ==================== 工具函数 ====================
# 日志输出（带时间戳）
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" >> "${log_file}"
    echo "[${timestamp}] [${level}] ${msg}"
}

# 清理环境
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

# 批量修改配置文件函数
batch_set_sys_conf() {
    local search_str=$1
    local content=$2
    local file=$3
    
    if grep -q "${search_str}" "${file}"; then
        sed -i "s|${search_str}|${content}|g" "${file}"
    else
        echo "${content}" >> "${file}"
    fi
}

# 配置 ConfigNode
configure_confignode() {
    local node_ip=$1
    log "INFO" "开始配置 ConfigNode: ${node_ip}"

    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
# 修改 env.sh
sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="2G"/g' ${db_dir}/conf/confignode-env.sh
sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${db_dir}/conf/confignode-env.sh

# 修改 system.properties
file="${db_dir}/conf/iotdb-system.properties"
batch_set_sys_conf() {
    local search_str=\$1
    local content=\$2
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
batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=5"
batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
batch_set_sys_conf ".*timestamp_precision=.*" "timestamp_precision=ns"
batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
EOF

    if [ $? -eq 0 ]; then
        log "INFO" "ConfigNode ${node_ip} 配置完成"
    else
        log "ERROR" "ConfigNode ${node_ip} 配置失败"
        return 1
    fi
}

# 配置 DataNode
configure_datanode() {
    local node_ip=$1
    local bad_disk_ip=""
    
    if [ -f "${nodeinfo_dir}/datanode_4d.txt" ]; then
        bad_disk_ip=$(tail -1 "${nodeinfo_dir}/datanode_4d.txt" | sed 's/ //g')
    fi
    
    log "INFO" "开始配置 DataNode: ${node_ip} (坏盘节点：${bad_disk_ip})"

    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${db_dir}/conf/datanode-env.sh
sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="2G"/g' ${db_dir}/conf/datanode-env.sh

file="${db_dir}/conf/iotdb-system.properties"
batch_set_sys_conf() {
    local search_str=\$1
    local content=\$2
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
batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=5"
batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
batch_set_sys_conf ".*timestamp_precision=.*" "timestamp_precision=ns"
batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
EOF

    # 处理坏盘节点
    if [[ -n "${bad_disk_ip}" && "${node_ip}" == "${bad_disk_ip}" ]]; then
        ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
file="${db_dir}/conf/iotdb-system.properties"
sed -i 's|.*dn_data_dirs=.*|dn_data_dirs=data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data|g' \$file
sed -i 's|.*dn_wal_dirs=.*|dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal|g' \$file
EOF
    else
        ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${db_dir}/conf/datanode-env.sh
sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${db_dir}/conf/datanode-env.sh
file="${db_dir}/conf/iotdb-system.properties"
sed -i 's|.*dn_data_dirs=.*|dn_data_dirs=data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data,/data3/iotdb_data/${testdb}/data/datanode/data|g' \$file
sed -i 's|.*dn_wal_dirs=.*|dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal,/data3/iotdb_data/${testdb}/data/datanode/wal|g' \$file
EOF
    fi

    if [ $? -eq 0 ]; then
        log "INFO" "DataNode ${node_ip} 配置完成"
    else
        log "ERROR" "DataNode ${node_ip} 配置失败"
        return 1
    fi
}

# 配置混合节点
configure_mixed_node() {
    local node_ip=$1
    log "INFO" "开始配置混合节点（CN+DN）: ${node_ip}"
    configure_confignode "${node_ip}"
    if [ $? -eq 0 ]; then
        configure_datanode "${node_ip}"
    fi
    log "INFO" "混合节点 ${node_ip} 配置完成"
}

# 并行配置所有节点
set_conf() {
    log "INFO" "开始并行配置所有节点..."

    # 生成临时 IP 文件
    grep -v '^$' "${nodeinfo_dir}/confignode.txt" | sed 's/ //g' | sort -u > /tmp/cn_ips.tmp
    grep -v '^$' "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sort -u > /tmp/dn_ips.tmp

    # 读取 IP 列表
    cn_ips=()
    while read -r line; do
        [[ -n "${line}" ]] && cn_ips+=("${line}")
    done < /tmp/cn_ips.tmp

    dn_ips=()
    while read -r line; do
        [[ -n "${line}" ]] && dn_ips+=("${line}")
    done < /tmp/dn_ips.tmp

    # 分类节点
    mixed_ips=()
    only_cn_ips=()
    only_dn_ips=()
    
    for ip in "${cn_ips[@]}"; do
        if grep -q "^${ip}$" /tmp/dn_ips.tmp; then
            mixed_ips+=("${ip}")
        else
            only_cn_ips+=("${ip}")
        fi
    done

    for ip in "${dn_ips[@]}"; do
        if ! grep -q "^${ip}$" /tmp/cn_ips.tmp; then
            only_dn_ips+=("${ip}")
        fi
    done

    # 并行配置
    pids=()
    log "INFO" "配置仅 CN 节点：${only_cn_ips[*]}"
    for ip in "${only_cn_ips[@]}"; do
        (configure_confignode "${ip}" || touch /tmp/conf_fail.flag) &
        pids+=($!)
    done

    log "INFO" "配置仅 DN 节点：${only_dn_ips[*]}"
    for ip in "${only_dn_ips[@]}"; do
        (configure_datanode "${ip}" || touch /tmp/conf_fail.flag) &
        pids+=($!)
    done

    log "INFO" "配置混合节点：${mixed_ips[*]}"
    for ip in "${mixed_ips[@]}"; do
        (configure_mixed_node "${ip}" || touch /tmp/conf_fail.flag) &
        pids+=($!)
    done

    # 等待完成
    log "INFO" "等待配置进程完成..."
    for pid in "${pids[@]}"; do
        wait "${pid}" || { log "ERROR" "进程 PID ${pid} 失败"; touch /tmp/conf_fail.flag; }
    done

    # 清理
    rm -f /tmp/cn_ips.tmp /tmp/dn_ips.tmp /tmp/conf_fail.flag

    if [ -f /tmp/conf_fail.flag ]; then
        fail_flag=1
        log "ERROR" "部分节点配置失败"
    else
        log "INFO" "所有节点配置完成"
    fi
}

# 启动数据库集群
start_db() {
    log "INFO" "开始启动数据库集群..."
    clean_env
    
    if [ ${fail_flag} -eq 1 ]; then
        log "ERROR" "环境清理失败"
    fi
    
    set_conf
    if [ ${fail_flag} -eq 1 ]; then
        log "ERROR" "节点配置失败"
        exit 1
    fi
    
    # 复制数据（所有 DataNode 节点）
    log "INFO" "复制备份数据到所有 DataNode 节点..."
    
    # 确保 datanode.txt 文件存在且不为空
    if [[ ! -f "${nodeinfo_dir}/datanode.txt" ]]; then
        log "ERROR" "datanode.txt 文件不存在：${nodeinfo_dir}/datanode.txt"
        fail_flag=1
        return 1
    fi
    
    # 统计节点数量
    local dn_count=$(grep -v '^$' "${nodeinfo_dir}/datanode.txt" | wc -l)
    log "INFO" "DataNode 节点数量：${dn_count}"
    
    # 逐个节点复制数据
    local dn_index=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # 跳过空行
        [[ -z "${line}" ]] && continue
        
        # 去除空格
        line=$(echo "${line}" | sed 's/ //g')
        
        let dn_index++
        log "INFO" "[${dn_index}/${dn_count}] 复制数据到节点：${line}"
        
        # 并行复制三个目录
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data1_backup ${data1_dir}" &
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data2_backup ${db_dir}/data" &
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data3_backup ${data3_dir}" &
        wait
        
        log "INFO" "[${dn_index}/${dn_count}] 节点 ${line} 数据复制完成"
    done < "${nodeinfo_dir}/datanode.txt"
    
    log "INFO" "所有 DataNode 节点数据复制完成，共 ${dn_index} 个节点"

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

# 检查结果（大于等于）
check_res() {
    local v_exp_msg=$1
    local v_exp_num=$2
    local v_act_num=$(grep ${v_exp_msg} ${cur_dir}/tmp.out | wc -l)
    
    if [[ ${v_act_num} -ge ${v_exp_num} ]]; then
        echo "pass"
    else
        let fail_flag++
        v_warnMessage="${v_warnMessage}check_res ${v_exp_msg} exp>=${v_exp_num} failed."
        cat ${cur_dir}/tmp.out
    fi
}

# 检查结果（等于）
check_res_eq() {
    local v_exp_msg=$1
    local v_exp_num=$2
    local v_act_num=$(grep ${v_exp_msg} ${cur_dir}/tmp.out | wc -l)
    
    if [[ ${v_act_num} = ${v_exp_num} ]]; then
        echo "pass"
    else
        let fail_flag++
        v_warnMessage="${v_warnMessage}check_res ${v_exp_msg} exp=${v_exp_num} failed."
        cat ${cur_dir}/tmp.out
    fi
}

# 启动 Benchmark
start_bm() {
    local bm_conf=partition_table_ns_2025y
    local bm_root_pw="root"
    
    if grep -q "^passwd_param=.*TimechoDB" ${db_dir}/sbin/start-cli.sh; then
        bm_root_pw="TimechoDB@2021"
    fi
    
    sed -i "s/^PASSWORD=.*/PASSWORD=${bm_root_pw}/g" ${bm_dir}/${bm_conf}/conf*/config.properties
    
    local bm_log_dir="${bm_dir}/${testdb}"
    mkdir -p "${bm_log_dir}"
    
    local t=$(date +%Y_%m_%d_%H_%M_%S)
    nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf5 >> ${bm_log_dir}/${t}_bm5.out &
    nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf6 >> ${bm_log_dir}/${t}_bm6.out &
    nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf7 >> ${bm_log_dir}/${t}_bm7.out &
    nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf8 >> ${bm_log_dir}/${t}_bm8.out &
    wait
    
    echo "${t}"  # 返回时间戳供后续使用
}

# 检查日志错误
check_log() {
    log "INFO" "开始检查 ConfigNode 日志..."
    while read line; do
        ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*confignode*all*" 2>/dev/null
        local v_npe=$(ssh ${os_user_name}@${line} "grep -c NullPointer ${db_dir}/logs/*confignode*all*" 2>/dev/null || echo 0)
        local v_cn_err1=$(ssh ${os_user_name}@${line} "grep -c BufferUnderflowException ${db_dir}/logs/*confignode*all*" 2>/dev/null || echo 0)
        local v_cn_err2=$(ssh ${os_user_name}@${line} "grep -c 'but return HAS_MORE_STATE' ${db_dir}/logs/*confignode*all*" 2>/dev/null || echo 0)
        
        if [[ ${v_npe} -gt 0 ]]; then
            let fail_flag++
            let backup_log_flag++
            echo "CN ${line} NullPointer : ${v_npe}"
            v_warnMessage="${v_warnMessage}CN NPE."
        fi
        
        if [[ $((v_cn_err1 + v_cn_err2)) -gt 0 ]]; then
            let fail_flag++
            let backup_log_flag++
            v_warnMessage="${v_warnMessage}CN HAS_MORE_STATE."
        fi
    done < "${nodeinfo_dir}/confignode.txt"

    log "INFO" "开始检查 DataNode 日志..."
    while read line; do
        ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*datanode*all*" 2>/dev/null
        
        local v_err_list=(
            $(ssh ${os_user_name}@${line} "grep -c NullPointer ${db_dir}/logs/*datanode*all*" 2>/dev/null || echo 0)
            $(ssh ${os_user_name}@${line} "grep -c CompactionTableSchemaNotMatchException ${db_dir}/logs/*datanode*all*" 2>/dev/null || echo 0)
            $(ssh ${os_user_name}@${line} "grep -c 'has overlapped data' ${db_dir}/logs/*datanode*all*" 2>/dev/null || echo 0)
            $(ssh ${os_user_name}@${line} "grep -c 'which should be later than the last time' ${db_dir}/logs/*datanode*all*" 2>/dev/null || echo 0)
            $(ssh ${os_user_name}@${line} "grep -c DataTypeInconsistentException ${db_dir}/logs/*datanode*all*" 2>/dev/null || echo 0)
            $(ssh ${os_user_name}@${line} "grep -c ArrayIndexOutOfBoundsException ${db_dir}/logs/*datanode*all*" 2>/dev/null || echo 0)
            $(ssh ${os_user_name}@${line} "grep -c StatisticsClassException ${db_dir}/logs/*datanode*all*" 2>/dev/null || echo 0)
            $(ssh ${os_user_name}@${line} "grep -c BufferUnderflowException ${db_dir}/logs/*datanode*all*" 2>/dev/null || echo 0)
            $(ssh ${os_user_name}@${line} "grep -c NegativeArraySizeException ${db_dir}/logs/*datanode*all*" 2>/dev/null || echo 0)
        )
        
        local v_dn_total_err=0
        for err in "${v_err_list[@]}"; do
            v_dn_total_err=$((v_dn_total_err + err))
        done

        if [[ ${v_err_list[0]} -gt 0 ]]; then
            let fail_flag++
            let backup_log_flag++
            echo "DN ${line} NullPointer : ${v_err_list[0]}"
            v_warnMessage="${v_warnMessage}DN NPE."
        fi
        
        if [[ ${v_dn_total_err} -gt 0 ]]; then
            let fail_flag++
            let backup_log_flag++
            v_warnMessage="${v_warnMessage}DN unexp log."
        fi
    done < "${nodeinfo_dir}/datanode.txt"
}

# 等待数据同步完成
wait_sync_done() {
    local max_wait_time=$1
    
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "flush;" > ${cur_dir}/tmp.out
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;" > ${cur_dir}/tmp.out
    cat ${cur_dir}/tmp.out | grep Running | awk -F "|" '{gsub(" ","");print $4}' > ${cur_dir}/tmp1.out
    mv ${cur_dir}/tmp1.out ${cur_dir}/tmp.out
    
    while read line; do
        while true; do
            ssh ${os_user_name}@${line} "grep 'create a new' ${db_dir}/logs/log_datanode_all.log | grep db_table" > ${cur_dir}/tmp1.out
            ssh ${os_user_name}@${line} "grep 'create a new' ${db_dir}/logs/log_datanode_all.log | grep root.test" > ${cur_dir}/tmp2.out
            
            local last_time_str1=$(tail -n 1 "${cur_dir}/tmp1.out" | awk -F',' '{print $1}')
            local last_time_str2=$(tail -n 1 "${cur_dir}/tmp2.out" | awk -F',' '{print $1}')
            local last_timestamp1=$(date -d "$last_time_str1" +%s 2>/dev/null || echo 0)
            local last_timestamp2=$(date -d "$last_time_str2" +%s 2>/dev/null || echo 0)
            
            local last_timestamp=${last_timestamp1}
            [[ ${last_timestamp2} -gt ${last_timestamp1} ]] && last_timestamp=${last_timestamp2}
            
            local current_timestamp=$(date +%s)
            local time_diff=$((current_timestamp - last_timestamp))
            
            if [ ${time_diff} -gt ${max_wait_time} ]; then
                echo "最后一条日志距离现在已超过 ${time_diff} 秒"
                break
            else
                sleep $((max_wait_time - time_diff + 1))
            fi
        done
    done < ${cur_dir}/tmp.out
}

# 检查 DataNode 进程
check_dn_jps() {
    local v_dn_ip=$1
    local max_wait_time=$2
    local t1=$(date +%s)
    
    while true; do
        local v_dn_pid=$(ssh ${os_user_name}@${v_dn_ip} "sudo jps 2>/dev/null | grep DataNode | awk '{print \$1}'")
        
        if [[ -z "${v_dn_pid}" || ${v_dn_pid} -eq 0 ]]; then
            break
        fi
        
        sleep 5
        local t2=$(date +%s)
        if [[ $((t2 - t1)) -gt ${max_wait_time} ]]; then
            let fail_flag++
            echo "Stopping takes too long."
            ssh ${os_user_name}@${v_dn_ip} "sudo kill -9 ${v_dn_pid}" 2>/dev/null
            break
        fi
    done
}

# ============================================================================
# 核心函数：执行 SQL 并检查异常（最多重试 10 次）
# ============================================================================
exec_sql_with_retry() {
    local sql="$1"
    local output_file="$2"
    local dialect="$3"
    local max_retry=10
    local retry_count=0
    
    while [[ ${retry_count} -lt ${max_retry} ]]; do
        ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} \
            -sql_dialect ${dialect} -timeout 36000 -e "${sql}" > "${output_file}" 2>&1
        
        if ! grep -q "Exception" "${output_file}"; then
            return 0
        fi
        
        echo "${output_file}"
        sleep 1
        let retry_count++
    done
    
    return 1
}

# ============================================================================
# 核心函数：校验时间段查询结果一致性
# 逻辑：分段查询结果之和 = 全量查询结果
# ============================================================================
check_time_partition_consistency() {
    local prefix="$1"
    local all_file="$2"
    local le_file="$3"
    local gt_file="$4"
    
    # 提取全量查询的总数
    local all_sum=$(grep -E "^[0-9]|root\.|d_" "${all_file}" | \
        awk -F "|" '{gsub(" ",""); for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) sum+=$i} END{print sum+0}')
    
    # 提取 <= 时间点的总数
    local le_sum=$(grep -E "^[0-9]|root\.|d_" "${le_file}" | \
        awk -F "|" '{gsub(" ",""); for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) sum+=$i} END{print sum+0}')
    
    # 提取 > 时间点的总数
    local gt_sum=$(grep -E "^[0-9]|root\.|d_" "${gt_file}" | \
        awk -F "|" '{gsub(" ",""); for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) sum+=$i} END{print sum+0}')
    
    local partition_sum=$((le_sum + gt_sum))
    
    log "INFO" "${prefix}: 全量=${all_sum}, <=时间点=${le_sum}, >时间点=${gt_sum}, 分段和=${partition_sum}"
    
    # 校验：le + gt = all
    if [[ ${all_sum} -ne ${partition_sum} ]]; then
        let fail_flag++
        let backup_data_log_flag++
        v_warnMessage="${v_warnMessage}${prefix} 时间段不一致：全量${all_sum} != 分段和${partition_sum}."
        echo "ERROR: ${prefix} 时间段查询结果不一致"
        diff "${all_file}" "${le_file}" | head -20
        diff "${all_file}" "${gt_file}" | head -20
        return 1
    fi
    
    # 校验：分段 <= 全量
    if [[ ${le_sum} -gt ${all_sum} ]] || [[ ${gt_sum} -gt ${all_sum} ]]; then
        let fail_flag++
        let backup_data_log_flag++
        v_warnMessage="${v_warnMessage}${prefix} 分段查询结果超过全量."
        echo "ERROR: ${prefix} 分段查询结果超过全量"
        return 1
    fi
    
    return 0
}

# ============================================================================
# 核心函数：数据一致性检查
# 流程：所有节点在线 → 时间段校验 → 逐个停节点 → 停整个集群
# ============================================================================
check_data_consistent() {
    log "INFO" "=========================================="
    log "INFO" "开始数据一致性检查"
    log "INFO" "=========================================="
    
    wait_sync_done 180
    
    # 获取 DataNodes 列表
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;" > ${cur_dir}/tmp.out
    cat ${cur_dir}/tmp.out | grep Running | awk -F "|" '{gsub(" ","");print $4}' > ${cur_dir}/tmp1.out
    mv ${cur_dir}/tmp1.out ${cur_dir}/tmp.out
    
    # ==================== SQL 定义 ====================
    # 全量查询
    local sql_all_tree="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from root.test.g_0.** align by device;"
    local sql_all_table1="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table1_0 group by device_id order by device_id;"
    local sql_all_table2="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table2_0 group by device_id order by device_id;"
    
    # <= 时间点查询
    local sql_le_tree="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from root.test.g_0.** where time<=2022-01-01T07:59:59.285507504+08:00 align by device;"
    local sql_le_table1="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table1_0 where time<=2022-01-01T07:59:59.285507504+08:00 group by device_id order by device_id;"
    local sql_le_table2="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table2_0 where time<=2022-01-01T07:59:59.285507504+08:00 group by device_id order by device_id;"
    
    # > 时间点查询
    local sql_gt_tree="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from root.test.g_0.** where time>2022-01-01T07:59:59.285507504+08:00 align by device;"
    local sql_gt_table1="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table1_0 where time>2022-01-01T07:59:59.285507504+08:00 group by device_id order by device_id;"
    local sql_gt_table2="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table2_0 where time>2022-01-01T07:59:59.285507504+08:00 group by device_id order by device_id;"
    
    # ==================== 阶段 1：所有节点在线 ====================
    log "INFO" "【阶段 1/4】所有节点在线查询"
    
    if exec_sql_with_retry "${sql_all_tree}" "${cur_dir}/q_all_online_tree.out" "tree"; then
        local v_exp_row=$(grep -c "root\.test" "${cur_dir}/q_all_online_tree.out")
        [[ ${v_exp_row} != 20 ]] && { let fail_flag++; v_warnMessage="${v_warnMessage}sql_all_tree rows error."; }
    else
        let fail_flag++
        v_warnMessage="${v_warnMessage}全量查询 tree 10 次失败."
    fi
    
    if exec_sql_with_retry "${sql_all_table1}" "${cur_dir}/q_all_online_table1.out" "table"; then
        local v_exp_row=$(grep -c "Total line number = 10" "${cur_dir}/q_all_online_table1.out")
        [[ ${v_exp_row} != 1 ]] && { let fail_flag++; v_warnMessage="${v_warnMessage}sql_all_table1 rows error."; }
    else
        let fail_flag++
        v_warnMessage="${v_warnMessage}全量查询 table1 10 次失败."
    fi
    
    if exec_sql_with_retry "${sql_all_table2}" "${cur_dir}/q_all_online_table2.out" "table"; then
        local v_exp_row=$(grep -c "Total line number = 10" "${cur_dir}/q_all_online_table2.out")
        [[ ${v_exp_row} != 1 ]] && { let fail_flag++; v_warnMessage="${v_warnMessage}sql_all_table2 rows error."; }
    else
        let fail_flag++
        v_warnMessage="${v_warnMessage}全量查询 table2 10 次失败."
    fi
    
    # ==================== 阶段 2：时间段查询 ====================
    log "INFO" "【阶段 2/4】时间段查询"
    
    exec_sql_with_retry "${sql_le_tree}" "${cur_dir}/q_le_tree.out" "tree"
    exec_sql_with_retry "${sql_le_table1}" "${cur_dir}/q_le_table1.out" "table"
    exec_sql_with_retry "${sql_le_table2}" "${cur_dir}/q_le_table2.out" "table"
    
    exec_sql_with_retry "${sql_gt_tree}" "${cur_dir}/q_gt_tree.out" "tree"
    exec_sql_with_retry "${sql_gt_table1}" "${cur_dir}/q_gt_table1.out" "table"
    exec_sql_with_retry "${sql_gt_table2}" "${cur_dir}/q_gt_table2.out" "table"
    
    # ==================== 阶段 3：时间段一致性校验 ====================
    log "INFO" "【阶段 3/4】时间段一致性校验"
    
    check_time_partition_consistency "tree" "${cur_dir}/q_all_online_tree.out" "${cur_dir}/q_le_tree.out" "${cur_dir}/q_gt_tree.out"
    check_time_partition_consistency "table1" "${cur_dir}/q_all_online_table1.out" "${cur_dir}/q_le_table1.out" "${cur_dir}/q_gt_table1.out"
    check_time_partition_consistency "table2" "${cur_dir}/q_all_online_table2.out" "${cur_dir}/q_le_table2.out" "${cur_dir}/q_gt_table2.out"
    
    # ==================== 阶段 4：逐个停节点 ====================
    log "INFO" "【阶段 4/4】逐个停止 DataNode 查询"
    
    local dn_list=()
    while read line; do
        dn_list+=("${line}")
    done < ${cur_dir}/tmp.out
    
    for line in "${dn_list[@]}"; do
        query_ip=$(head -1 ${cur_dir}/tmp.out)
        local query_ip2=$(tail -1 ${cur_dir}/tmp.out)
        
        log "INFO" "停止 DataNode: ${line}"
        ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};sudo ./sbin/stop-datanode.sh"
        check_dn_jps ${line} 120
        
        [[ ${query_ip} = ${line} ]] && query_ip=${query_ip2}
        
        local v_ip=$(echo ${line} | awk -F '.' '{print $4}')
        log "INFO" "--- 节点 ${v_ip} 已停止，执行查询 ---"
        
        exec_sql_with_retry "${sql_all_tree}" "${cur_dir}/q_stop_ip${v_ip}_tree.out" "tree"
        exec_sql_with_retry "${sql_all_table1}" "${cur_dir}/q_stop_ip${v_ip}_table1.out" "table"
        exec_sql_with_retry "${sql_all_table2}" "${cur_dir}/q_stop_ip${v_ip}_table2.out" "table"
        
        # 对比结果
        local v_diff_tree=$(diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_stop_ip${v_ip}_tree.out | grep -c "root" || echo 0)
        local v_diff_table1=$(diff ${cur_dir}/q_all_online_table1.out ${cur_dir}/q_stop_ip${v_ip}_table1.out | grep -c "d_" || echo 0)
        local v_diff_table2=$(diff ${cur_dir}/q_all_online_table2.out ${cur_dir}/q_stop_ip${v_ip}_table2.out | grep -c "d_" || echo 0)
        local v_diff_num=$((v_diff_tree + v_diff_table1 + v_diff_table2))
        
        if [[ ${v_diff_num} -gt 0 ]]; then
            let fail_flag++
            let backup_data_log_flag++
            v_warnMessage="${v_warnMessage}stop ${v_ip} 后数据不一致."
            echo "diff : ${v_diff_num}"
        fi
        
        # 重启节点
        log "INFO" "重启节点 ${line}"
        local v_start_time=$(date +%s)
        ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};sudo ./sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
        
        while true; do
            local v_start_ok=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${line} -timeout 3600 -e "show datanodes;" | grep -c "${line}|.*Running")
            [[ ${v_start_ok} -gt 0 ]] && break
            
            sleep 1
            if [[ $(($(date +%s) - v_start_time)) -gt 180 ]]; then
                let fail_flag++
                echo "restart ${line} failed."
                return 1
            fi
        done
        
        query_ip=$(head -1 ${cur_dir}/tmp.out)
    done
    
    # ==================== 阶段 5：停止整个集群 ====================
    log "INFO" "【额外阶段】停止整个集群查询"
    
    for line in "${dn_list[@]}"; do
        log "INFO" "停止 DataNode: ${line}"
        ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};sudo ./sbin/stop-datanode.sh"
        check_dn_jps ${line} 120
    done
    
    # 用剩余节点查询
    if [[ -n "${query_ip2}" ]]; then
        log "INFO" "用剩余节点执行查询"
        exec_sql_with_retry "${sql_all_tree}" "${cur_dir}/q_all_stop_tree.out" "tree"
        exec_sql_with_retry "${sql_all_table1}" "${cur_dir}/q_all_stop_table1.out" "table"
        exec_sql_with_retry "${sql_all_table2}" "${cur_dir}/q_all_stop_table2.out" "table"
        
        local v_diff_tree=$(diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_all_stop_tree.out | grep -c "root" || echo 0)
        local v_diff_table1=$(diff ${cur_dir}/q_all_online_table1.out ${cur_dir}/q_all_stop_table1.out | grep -c "d_" || echo 0)
        local v_diff_table2=$(diff ${cur_dir}/q_all_online_table2.out ${cur_dir}/q_all_stop_table2.out | grep -c "d_" || echo 0)
        local v_diff_num=$((v_diff_tree + v_diff_table1 + v_diff_table2))
        
        if [[ ${v_diff_num} -gt 0 ]]; then
            let fail_flag++
            let backup_data_log_flag++
            v_warnMessage="${v_warnMessage}停止整个集群后数据不一致."
            echo "diff : ${v_diff_num}"
        fi
    fi
    
    # 重启所有节点
    log "INFO" "重启所有 DataNode"
    for line in "${dn_list[@]}"; do
        local v_start_time=$(date +%s)
        ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};sudo ./sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
        
        while true; do
            local v_start_ok=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${line} -timeout 3600 -e "show datanodes;" | grep -c "${line}|.*Running")
            [[ ${v_start_ok} -gt 0 ]] && break
            
            sleep 1
            if [[ $(($(date +%s) - v_start_time)) -gt 180 ]]; then
                let fail_flag++
                echo "restart ${line} failed."
                return 1
            fi
        done
    done
    
    log "INFO" "=========================================="
    log "INFO" "数据一致性检查完成"
    log "INFO" "=========================================="
}

# ==================== 测试用例 ====================
function testcase1() {
    check_data_consistent
    
    log "INFO" "重启集群（阶段 2）..."
    sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
    sh -x "${prepare_env_dir}/start_cluster_v20.sh" "2" "${total_node_num}" >> "${log_file}" 2>&1
    
    if [ $? -eq 0 ]; then
        log "INFO" "集群启动成功"
    else
        log "ERROR" "集群启动失败"
        let fail_flag++
    fi
    
    check_data_consistent
    check_log
}

# ==================== 记录测试结果 ====================
function write_result() {
    local test_time=$(date +"%Y-%m-%dT%H:%M:%S.%3N%:z")
    local t=$1  # 从 start_bm 返回的时间戳
    
    local v_bm_max_value=$(grep "Test elapsed" ${bm_log_dir}/${t}_bm*out 2>/dev/null | awk '{print $8}' | sort -n | tail -1)
    local v_bm_sum_value=$(grep "Test elapsed" ${bm_log_dir}/${t}_bm*out 2>/dev/null | awk '{print $8}' | awk '{sum+=$1} END {print sum}')
    
    # 写入表头
    if ! grep -q "Time,testTimechoDB" $CSV_FILE 2>/dev/null; then
        echo "Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage,maxBMTestTimeSec,sumBMTestTimeSec" > "$CSV_FILE"
    fi
    
    if [[ ${fail_flag} -gt 0 ]]; then
        echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},FAIL,${v_elp_time},${v_warnNum},${v_warnMessage},${v_bm_max_value},${v_bm_sum_value}" >> "$CSV_FILE"
        echo "testcase1 FAIL"
        
        local v_backup_time=$(date +%s)
        local v_backup_desc=$(echo ${SCRIPT_NAME} | awk -F '.' '{print $1}')
        sh ${clean_env_dir}/backup_cluster_logs.sh ${v_backup_time}_${v_backup_desc}
    else
        echo "testcase1 PASS"
        echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},PASS,${v_elp_time},${v_warnNum},${v_warnMessage},${v_bm_max_value},${v_bm_sum_value}" >> "$CSV_FILE"
    fi
}

# ==================== 主流程 ====================
main() {
    echo "" > ${log_file}
    log "INFO" "=========================================="
    log "INFO" "测试脚本启动：${SCRIPT_NAME}"
    log "INFO" "=========================================="
    
    start_db
    
    v_start_test_time=$(date +%s)
    t=$(start_bm)
    log "INFO" "Benchmark 启动完成，时间戳：${t}"
    
    testcase1
    
    v_end_test_time=$(date +%s)
    v_elp_time=$((v_end_test_time - v_start_test_time))
    log "INFO" "测试完成，耗时：${v_elp_time} 秒"
    
    write_result "${t}"
    
    log "INFO" "=========================================="
    log "INFO" "全部流程完成"
    log "INFO" "=========================================="
}

# 执行主流程
main
