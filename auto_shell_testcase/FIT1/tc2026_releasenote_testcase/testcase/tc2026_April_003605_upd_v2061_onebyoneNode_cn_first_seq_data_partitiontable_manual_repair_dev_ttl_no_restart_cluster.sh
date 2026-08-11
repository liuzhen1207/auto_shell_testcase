#!/bin/bash
#from db version 是固定的2.0.6.1 RC7
#target db version 是本次测试版本
# 兼容所有Bash版本（包括3.x），移除进程替换、mapfile等高级特性
set -uo pipefail
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
upd_from_conf_file="${cur_dir}/../conf/test_upd_from_version.conf"
nodeinfo_dir="${cur_dir}/../conf"

# 读取配置文件（去空格，兼容低版本）
os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
upd_from_testdb=$(grep ^v_testdb "${upd_from_conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
cli_dir=${db_parent_dir}/${testdb}
upd_cli_dir=${db_parent_dir}/${upd_from_testdb}
db_dir=${db_parent_dir}/${testdb}
upd_from_cn_db_dir=`cat ${upd_from_conf_file}|grep ^v_cn_db_dir|awk -F '=' '{print $2}'`
upd_from_db_dir=${db_parent_dir}/${upd_from_testdb}
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
cn_num=3
dn_num=3
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num+dn_num))
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensus"
CSV_FILE=$(grep ^CSV_FILE "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
log_file="${cur_dir}/set_conf_parallel.log"
data1_dir="/data1/iotdb_data/${testdb}/data"
data1_upd_from_dir="/data1/iotdb_data/${upd_from_testdb}/data"
data3_dir="/data3/iotdb_data/${testdb}/data"
data3_upd_from_dir="/data3/iotdb_data/${upd_from_testdb}/data"
ssl_str=""
backup_log_flag=0
backup_data_log_flag=0
bm_dir="${cur_dir}/../benchmark/bm_20251220_38c839b_v20"
#backup_dir=/data2/tc2026_data_backup/v2061_rc7_0915_802dd96_ms_dev_ttl_iot
# 清理旧节点文件，复制新配置
rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

# 读取种子节点IP（兼容低版本）
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

fail_flag=0
test_begin_sec=$(date +%s)

max_concurrent=7     # 最大并发数，根据数据库性能调整（建议5-10）


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
   sh -x "${clean_env_dir}/stop_cluster_upd_from_version.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/clean_cluster_upd_from_version.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/reset_conf.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/reset_conf_upd_from_version.sh" >> "${log_file}" 2>&1
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
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="2G"/g' ${db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${db_dir}/conf/confignode-env.sh
        
        # 定义批量修改system.properties的函数
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
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=2"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=2"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        batch_set_sys_conf ".*timestamp_precision=.*" "timestamp_precision=ms"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"

EOF

    # 整合所有ConfigNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="2G"/g' ${upd_from_db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${upd_from_db_dir}/conf/confignode-env.sh

        # 定义批量修改system.properties的函数
        batch_set_sys_conf() {
            local search_str=\$1
            local content=\$2
            local file="${upd_from_db_dir}/conf/iotdb-system.properties"
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
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=2"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=2"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        batch_set_sys_conf ".*timestamp_precision=.*" "timestamp_precision=ms"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"

EOF
    # 整合所有ConfigNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="2G"/g' ${upd_from_cn_db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${upd_from_cn_db_dir}/conf/confignode-env.sh

        # 定义批量修改system.properties的函数
        batch_set_sys_conf() {
            local search_str=\$1
            local content=\$2
            local file="${upd_from_cn_db_dir}/conf/iotdb-system.properties"
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
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=2"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=2"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        batch_set_sys_conf ".*timestamp_precision=.*" "timestamp_precision=ms"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"

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
    local bad_disk_ip=""
    if [ -f "${nodeinfo_dir}/datanode_4d.txt" ]; then
        bad_disk_ip=$(tail -1 "${nodeinfo_dir}/datanode_4d.txt" | sed 's/ //g')
    fi
    log "INFO" "开始配置DataNode: ${node_ip} (坏盘节点: ${bad_disk_ip})"

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
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=2"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=2"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        batch_set_sys_conf ".*timestamp_precision=.*" "timestamp_precision=ms"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"


EOF

    # 整合所有DataNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${upd_from_db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="2G"/g' ${upd_from_db_dir}/conf/datanode-env.sh

        # 定义批量修改函数
        batch_set_sys_conf() {
            local search_str=\$1
            local content=\$2
            local file="${upd_from_db_dir}/conf/iotdb-system.properties"
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
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=2"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=2"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        batch_set_sys_conf ".*timestamp_precision=.*" "timestamp_precision=ms"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"


EOF

    # 处理坏盘节点目录配置
    if [[ -n "${bad_disk_ip}" && "${node_ip}" == "${bad_disk_ip}" ]]; then
        ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
            file="${db_dir}/conf/iotdb-system.properties"
            sed -i 's|.*dn_data_dirs=.*|dn_data_dirs=data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data|g' \$file
            sed -i 's|.*dn_wal_dirs=.*|dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal|g' \$file
EOF
    else
        ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${db_dir}/conf/datanode-env.sh

            file="${db_dir}/conf/iotdb-system.properties"
            sed -i 's|.*dn_data_dirs=.*|dn_data_dirs=data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data,/data3/iotdb_data/${testdb}/data/datanode/data|g' \$file
            sed -i 's|.*dn_wal_dirs=.*|dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal,/data3/iotdb_data/${testdb}/data/datanode/wal|g' \$file
EOF
    fi

        # 处理坏盘节点目录配置
    if [[ -n "${bad_disk_ip}" && "${node_ip}" == "${bad_disk_ip}" ]]; then
        ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
            file="${db_dir}/conf/iotdb-system.properties"
            sed -i 's|.*dn_data_dirs=.*|dn_data_dirs=data/datanode/data,/data1/iotdb_data/${upd_from_testdb}/data/datanode/data|g' \$file
            sed -i 's|.*dn_wal_dirs=.*|dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${upd_from_testdb}/data/datanode/wal|g' \$file
EOF
    else
        ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${upd_from_db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${upd_from_db_dir}/conf/datanode-env.sh

            file="${upd_from_db_dir}/conf/iotdb-system.properties"
            sed -i 's|.*dn_data_dirs=.*|dn_data_dirs=data/datanode/data,/data1/iotdb_data/${upd_from_testdb}/data/datanode/data,/data3/iotdb_data/${upd_from_testdb}/data/datanode/data|g' \$file
            sed -i 's|.*dn_wal_dirs=.*|dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${upd_from_testdb}/data/datanode/wal,/data3/iotdb_data/${upd_from_testdb}/data/datanode/wal|g' \$file
EOF
    fi


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

    # 配置混合节点
    log "INFO" "启动混合节点（CN+DN）并行配置: ${mixed_ips[*]}"
    for ip in "${mixed_ips[@]}"; do
        configure_mixed_node "${ip}" &
        pids+=($!)
    done

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

# Restore the real upgrade-source binaries before each run.
# If lib_orig/sbin_orig do not exist, this is the first run and current directories are retained.
function restore_upgrade_source_binaries()
{
    local line
    local restore_failed=0

    log "INFO" "Restore DataNode upgrade-source lib/sbin before starting the old-version cluster"
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3
    do
        ssh ${os_user_name}@${line} "
            set -e
            if test -d ${upd_from_db_dir}/lib_orig && test -d ${upd_from_db_dir}/sbin_orig; then
                sudo rm -rf ${upd_from_db_dir}/lib ${upd_from_db_dir}/sbin
                sudo cp -rp ${upd_from_db_dir}/lib_orig ${upd_from_db_dir}/lib
                sudo cp -rp ${upd_from_db_dir}/sbin_orig ${upd_from_db_dir}/sbin
            elif test -d ${upd_from_db_dir}/lib_orig || test -d ${upd_from_db_dir}/sbin_orig; then
                echo 'DataNode lib_orig/sbin_orig is incomplete'
                exit 1
            fi
            test -d ${upd_from_db_dir}/lib
            test -x ${upd_from_db_dir}/sbin/start-datanode.sh
        " || {
            log "ERROR" "Failed to restore/validate DataNode upgrade-source binaries on ${line}"
            restore_failed=1
        }
    done
    exec 3<&-

    log "INFO" "Restore ConfigNode upgrade-source lib/sbin before starting the old-version cluster"
    exec 3<"${nodeinfo_dir}/confignode.txt"
    while read line <&3
    do
        ssh ${os_user_name}@${line} "
            set -e
            if test -d ${upd_from_cn_db_dir}/lib_orig && test -d ${upd_from_cn_db_dir}/sbin_orig; then
                sudo rm -rf ${upd_from_cn_db_dir}/lib ${upd_from_cn_db_dir}/sbin
                sudo cp -rp ${upd_from_cn_db_dir}/lib_orig ${upd_from_cn_db_dir}/lib
                sudo cp -rp ${upd_from_cn_db_dir}/sbin_orig ${upd_from_cn_db_dir}/sbin
            elif test -d ${upd_from_cn_db_dir}/lib_orig || test -d ${upd_from_cn_db_dir}/sbin_orig; then
                echo 'ConfigNode lib_orig/sbin_orig is incomplete'
                exit 1
            fi
            test -d ${upd_from_cn_db_dir}/lib
            test -x ${upd_from_cn_db_dir}/sbin/start-confignode.sh
        " || {
            log "ERROR" "Failed to restore/validate ConfigNode upgrade-source binaries on ${line}"
            restore_failed=1
        }
    done
    exec 3<&-

    if [[ ${restore_failed} -ne 0 ]]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}restore upgrade-source lib/sbin failed."
        return 1
    fi
    log "INFO" "Upgrade-source CN/DN lib/sbin restoration and validation completed"
}

# 启动数据库集群函数
start_db() {
   log "INFO" "开始启动数据库集群..."
clean_env
   if [ ${fail_flag} -eq 1 ]; then
       log "ERROR" "环境清理失败，终止启动流程"
#       exit 1
   fi

   restore_upgrade_source_binaries || exit 1

   # 配置节点
   set_conf
   if [ ${fail_flag} -eq 1 ]; then
       log "ERROR" "节点配置失败，终止启动流程"
       exit 1
   fi
  
     # copy data
# exec 3<${nodeinfo_dir}/datanode.txt
# while read line<&3
# do
#         ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data1_backup ${data1_dir}"
#         ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data2_backup ${db_dir}/data"
#         ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data3_backup ${data3_dir}"
#         sleep 1
# done


   # 启动集群
   sh -x "${prepare_env_dir}/start_cluster_v20_upd_from_db.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1
   if [ $? -eq 0 ]; then
       log "INFO" "集群启动成功"
   else
       log "ERROR" "集群启动失败"
       let fail_flag++
       exit 1
   fi
}
function start_bm_part1()
{
bm_conf=ttl_partition_seq_upd
#get root password
#test time 15h
#v_bm_test_time=54000000
#v_bm_test_time=36000000
v_20_pass=`grep ^passwd_param= ${upd_cli_dir}/sbin/start-cli.sh |grep TimechoDB|wc -l`
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
t=`date +%Y_%m_%d_%H_%M_%S`
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf1 >> ${bm_log_dir}/${t}_bm1.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf2 >> ${bm_log_dir}/${t}_bm2.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf3 >> ${bm_log_dir}/${t}_bm3.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf4 >> ${bm_log_dir}/${t}_bm4.out &

wait
}
function start_bm_part2()
{
bm_conf=ttl_partition_seq_upd
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf5 >> ${bm_log_dir}/${t}_bm5.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf6 >> ${bm_log_dir}/${t}_bm6.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf7 >> ${bm_log_dir}/${t}_bm7.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf8 >> ${bm_log_dir}/${t}_bm8.out &
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
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "flush;">${cur_dir}/tmp.out
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">${cur_dir}/tmp.out
   cat ${cur_dir}/tmp.out |grep Running|awk -F "|" '{gsub(" ","");print $4}'>${cur_dir}/tmp1.out
   mv ${cur_dir}/tmp1.out ${cur_dir}/tmp.out
   exec 3<${cur_dir}/tmp.out
   while read line<&3
   do
   while true
   do
   ssh ${os_user_name}@${line} "grep \"create a new\" ${upd_from_db_dir}/logs/log_datanode_all.log|grep db_table">${cur_dir}/tmp1.out
   ssh ${os_user_name}@${line} "grep \"create a new\" ${upd_from_db_dir}/logs/log_datanode_all.log|grep root.test">${cur_dir}/tmp2.out
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
# Wait until every running DataNode reports all IoTConsensus syncLag metrics as 0.
function wait_iot_consensus_sync_lag_zero()
{
   local max_wait_time=${1:-300}
   local poll_interval=2
   local start_time=$(date +%s)
   local metrics_port=9091
   local running_nodes
   local node
   local metrics
   local metric_count
   local nonzero_count
   local all_zero

   while true
   do
      running_nodes=$(${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;" 2>/dev/null | grep Running | awk -F '|' '{gsub(" ","",$4); print $4}')
      all_zero=1
      if [[ -z "${running_nodes}" ]]; then
         all_zero=0
         log "WARN" "No running DataNode found while waiting for IoTConsensus sync lag"
      fi
      for node in ${running_nodes}
      do
         metrics=$(ssh ${os_user_name}@${node} "curl -s --max-time 5 http://127.0.0.1:${metrics_port}/metrics" 2>/dev/null | awk '/^iot_consensus(_v2)?[{].*type="syncLag"/')
         metric_count=$(echo "${metrics}" | awk 'NF {count++} END {print count+0}')
         nonzero_count=$(echo "${metrics}" | awk 'NF && ($NF + 0 != 0) {count++} END {print count+0}')
         if [[ ${metric_count} -eq 0 ]]; then
            all_zero=0
            log "WARN" "DataNode ${node}: syncLag metric is unavailable"
         elif [[ ${nonzero_count} -gt 0 ]]; then
            all_zero=0
            log "INFO" "DataNode ${node}: ${nonzero_count}/${metric_count} syncLag metrics are non-zero"
         fi
      done
      if [[ ${all_zero} -eq 1 ]]; then
         log "INFO" "All running DataNodes have IoTConsensus syncLag=0"
         return 0
      fi
      if [[ $(($(date +%s)-start_time)) -ge ${max_wait_time} ]]; then
         let fail_flag++
         v_warnMessage="${v_warnMessage}iotconsensus sync lag timeout."
         log "ERROR" "Waiting for IoTConsensus syncLag=0 timed out after ${max_wait_time}s"
         return 1
      fi
      sleep ${poll_interval}
   done
}

function check_dn_jps()
{
   local v_dn_ip=$1
   local max_wait_time=$2
local t1=`date +%s`
while true
do
   v_dn_str=`ssh ${os_user_name}@${v_dn_ip} "sudo jps|grep DataNode"`
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
         for v_jstack_num in {1..3}
         do
             v_jstack_time=`date "+%Y_%m_%d_%H_%M_%S"`
             ssh ${os_user_name}@${v_dn_ip} "sudo jstack -l ${v_dn_pid} >${upd_from_db_dir}/dn_${v_jstack_num}_${v_jstack_time}.out"
             sleep 10
         done

# kill -9
         ssh ${os_user_name}@${v_dn_ip} "sudo kill -9 ${v_dn_pid}."
         break
      fi

done
}

function check_cn_jps()
{
   local v_dn_ip=$1
   local max_wait_time=$2
local t1=`date +%s`
while true
do
   v_dn_str=`ssh ${os_user_name}@${v_dn_ip} "sudo jps|grep ConfigNode"`
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
	          let fail_flag++
         v_warnMessage="${v_warnMessage}stop confignode ${v_dn_ip} takes too long."
         echo "Stopping takes too long."
          for v_jstack_num in {1..3}
         do
             v_jstack_time=`date "+%Y_%m_%d_%H_%M_%S"`
             ssh ${os_user_name}@${v_dn_ip} "sudo jstack -l ${v_dn_pid} >${upd_from_cn_db_dir}/cn_${v_jstack_num}_${v_jstack_time}.out"
             sleep 10
         done

# kill -9
         ssh ${os_user_name}@${v_dn_ip} "sudo kill -9 ${v_dn_pid}."
         break
      fi

done
}

function upgrade_confignode()
{
	${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show confignodes;">${cur_dir}/tmp.out
        cat ${cur_dir}/tmp.out|grep Follower|awk -F '|' '{gsub(" ","");print $4}'>${cur_dir}/upd_confignode.out
        cat ${cur_dir}/tmp.out|grep Leader|awk -F '|' '{gsub(" ","");print $4}'>>${cur_dir}/upd_confignode.out

exec 3<${cur_dir}/upd_confignode.out
while read line<&3
do
	      ssh ${os_user_name}@${line} "source /etc/profile;cd ${upd_from_cn_db_dir};sudo ./sbin/stop-confignode.sh"
              check_cn_jps ${line} 180
# mv lib
if ssh ${os_user_name}@${line} test -d ${upd_from_cn_db_dir}/lib_orig; then
echo "has been copy."
else
ssh ${os_user_name}@${line} "sudo mv ${upd_from_cn_db_dir}/lib ${upd_from_cn_db_dir}/lib_orig"

fi

if ssh ${os_user_name}@${line} test -d ${upd_from_cn_db_dir}/sbin_orig; then
echo "has been copy."
else
ssh ${os_user_name}@${line} "sudo mv ${upd_from_cn_db_dir}/sbin ${upd_from_cn_db_dir}/sbin_orig"

fi

# copy
if ssh ${os_user_name}@${line} test -d ${upd_from_cn_db_dir}/lib; then
ssh ${os_user_name}@${line} "sudo rm -rf ${upd_from_cn_db_dir}/lib"
ssh ${os_user_name}@${line} "sudo cp -rp ${db_dir}/lib ${upd_from_cn_db_dir}/"
else
ssh ${os_user_name}@${line} "sudo cp -rp ${db_dir}/lib ${upd_from_cn_db_dir}/"

fi

if ssh ${os_user_name}@${line} test -d ${upd_from_cn_db_dir}/sbin; then
ssh ${os_user_name}@${line} "sudo rm -rf ${upd_from_cn_db_dir}/sbin"
ssh ${os_user_name}@${line} "sudo cp -rp ${db_dir}/sbin ${upd_from_cn_db_dir}/"
else
ssh ${os_user_name}@${line} "sudo cp -rp ${db_dir}/sbin ${upd_from_cn_db_dir}/"
fi
sleep 1
      v_start_time=`date +%s`
# start new node 
      v_after_upd_start_time=`date +%s`
      ssh ${os_user_name}@${line} "source /etc/profile;cd ${upd_from_cn_db_dir};sudo ./sbin/start-confignode.sh -H ${upd_from_cn_db_dir}/cn_${v_after_upd_start_time}_heapdump.hprof > /dev/null 2>&1 &"
      sleep 5
      while true
      do
      v_start_ok=`${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${line}  -timeout 3600 -e "show confignodes;"|grep "${line}|"|grep Running|wc -l`
      if [[ ${v_start_ok} = 1 ]];then
         break
      else
         sleep 3 
      fi
      v_cur_time=`date +%s`
      v_elp_time=$((v_cur_time-v_start_time))
      if [[ ${v_elp_time} -gt 180 ]];then
         let fail_flag++
         echo "upgrade cn ${line} failed."
	 v_warnMessage="${v_warnMessage}upgrade cn ${line} failed."
         return
      fi
      done


done
}


function upgrade_datanode()
{
exec 3<${nodeinfo_dir}/datanode.txt
while read line<&3
do
              # Snapshot old-version NPEs before replacing this DataNode's lib/sbin.
              # Final log validation only fails on NPEs added by the upgraded version.
              ssh ${os_user_name}@${line} "sudo gunzip ${upd_from_db_dir}/logs/*datanode*all* >/dev/null 2>&1 || true"
              v_dn_npe_baseline=`ssh ${os_user_name}@${line} "grep NullPointer ${upd_from_db_dir}/logs/*datanode*all* 2>/dev/null|wc -l"`
              echo "${v_dn_npe_baseline}" > "${cur_dir}/dn_${line}_npe_before_upgrade.count"
              log "INFO" "DN ${line} old-version NullPointer baseline: ${v_dn_npe_baseline}"
              ssh ${os_user_name}@${line} "source /etc/profile;cd ${upd_from_db_dir};sudo ./sbin/stop-datanode.sh"
              check_dn_jps ${line} 180
# mv lib
if ssh ${os_user_name}@${line} test -d ${upd_from_db_dir}/lib_orig; then
echo "has been copy."
else
ssh ${os_user_name}@${line} "sudo mv ${upd_from_db_dir}/lib ${upd_from_db_dir}/lib_orig"

fi

if ssh ${os_user_name}@${line} test -d ${upd_from_db_dir}/sbin_orig; then
echo "has been copy."
else
ssh ${os_user_name}@${line} "sudo mv ${upd_from_db_dir}/sbin ${upd_from_db_dir}/sbin_orig"

fi

# copy
if ssh ${os_user_name}@${line} test -d ${upd_from_db_dir}/lib; then
ssh ${os_user_name}@${line} "sudo rm -rf ${upd_from_db_dir}/lib"
ssh ${os_user_name}@${line} "sudo cp -rp ${db_dir}/lib ${upd_from_db_dir}/"
else
ssh ${os_user_name}@${line} "sudo cp -rp ${db_dir}/lib ${upd_from_db_dir}/"

fi

if ssh ${os_user_name}@${line} test -d ${upd_from_db_dir}/sbin; then
ssh ${os_user_name}@${line} "sudo rm -rf ${upd_from_db_dir}/sbin"
ssh ${os_user_name}@${line} "sudo cp -rp ${db_dir}/sbin ${upd_from_db_dir}/"
else
ssh ${os_user_name}@${line} "sudo cp -rp ${db_dir}/sbin ${upd_from_db_dir}/"

fi
sleep 1
      v_start_time=`date +%s`
# start new node 
      v_after_upd_start_time=`date +%s`
      ssh ${os_user_name}@${line} "source /etc/profile;cd ${upd_from_db_dir};sudo ./sbin/start-datanode.sh -H ${upd_from_db_dir}/dn_${v_after_upd_start_time}_heapdump.hprof > /dev/null 2>&1 &"
      sleep 5 
      while true
      do
      v_start_ok=`${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${line}  -timeout 3600 -e "show datanodes;"|grep "${line}|"|grep Running|wc -l`
      if [[ ${v_start_ok} = 1 ]];then
         break
      else
         sleep 1
      fi
      v_cur_time=`date +%s`
      v_elp_time=$((v_cur_time-v_start_time))
      if [[ ${v_elp_time} -gt 180 ]];then
         let fail_flag++
         echo "upgrade dn ${line} failed."
	 v_warnMessage="${v_warnMessage}upgrade dn ${line} failed."
         return
      fi
      done


done
}
function degrade_datanode()
{
exec 3<${nodeinfo_dir}/datanode.txt
while read line<&3
do
# rm -rf lib
if ssh ${os_user_name}@${line} test -d ${upd_from_db_dir}/lib; then
ssh ${os_user_name}@${line} "sudo rm -rf ${upd_from_db_dir}/lib"

fi

# rm -rf sbin
if ssh ${os_user_name}@${line} test -d ${upd_from_db_dir}/sbin; then
ssh ${os_user_name}@${line} "sudo rm -rf ${upd_from_db_dir}/sbin"
fi
#copy sbin
if ssh ${os_user_name}@${line} test -d ${upd_from_db_dir}/sbin_orig; then
ssh ${os_user_name}@${line} "sudo cp -rp ${upd_from_db_dir}/sbin_orig ${upd_from_db_dir}/sbin"

fi

# copy lib
if ssh ${os_user_name}@${line} test -d ${upd_from_db_dir}/lib_orig; then
ssh ${os_user_name}@${line} "sudo cp -rp ${upd_from_db_dir}/lib_orig ${upd_from_db_dir}/lib"
fi
done
}
function degrade_confignode()
{
exec 3<${cur_dir}/upd_confignode.out
while read line<&3
do
# rm -rf lib
if ssh ${os_user_name}@${line} test -d ${upd_from_cn_db_dir}/lib; then
ssh ${os_user_name}@${line} "sudo rm -rf ${upd_from_cn_db_dir}/lib"

fi

# rm -rf sbin
if ssh ${os_user_name}@${line} test -d ${upd_from_cn_db_dir}/sbin; then
ssh ${os_user_name}@${line} "sudo rm -rf ${upd_from_cn_db_dir}/sbin"
fi
#copy sbin
if ssh ${os_user_name}@${line} test -d ${upd_from_cn_db_dir}/sbin_orig; then
ssh ${os_user_name}@${line} "sudo cp -rp ${upd_from_cn_db_dir}/sbin_orig ${upd_from_db_dir}/sbin"

fi

# copy lib
if ssh ${os_user_name}@${line} test -d ${upd_from_cn_db_dir}/lib_orig; then
ssh ${os_user_name}@${line} "sudo cp -rp ${upd_from_cn_db_dir}/lib_orig ${upd_from_cn_db_dir}/lib"
fi
done
}

function check_data_consistent()
{
wait_sync_done 180
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">${cur_dir}/tmp.out
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
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql1}" >${cur_dir}/q_all_online_tree.out
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
   if [[ ${v_row_num} != 20 ]];then
	   let fail_flag++
	   v_warnMessage="${v_warnMessage}tree all online query row num != 20."
   fi
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql4}" 
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql4}" >${cur_dir}/tmp.out
   check_res_eq " 4|" 1 
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql5}" >${cur_dir}/tmp.out
   check_res_eq " 4|" 1 
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql6}" >${cur_dir}/tmp.out
   check_res_eq "1970-01" 2 
   check_res_eq " 2925|" 1
   check_res_eq " 2926|" 1
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql7}" >${cur_dir}/tmp.out
   check_res_eq "1970-01" 2 
   check_res_eq " 2925|" 1
   check_res_eq " 2926|" 1
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql8}" >${cur_dir}/q_all_online_tree_q8.out 
   v_row_num=`grep root.test ${cur_dir}/q_all_online_tree_q8.out|wc -l`
   if [[ ${v_row_num} != 20 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}tree all online query sql8 row num != 20."
   fi

   exception_num=0
   while true
   do
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql2}" >${cur_dir}/q_all_online_table1.out
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql3}" >${cur_dir}/q_all_online_table2.out
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql9}" >${cur_dir}/q_all_online_table1_q9.out
   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql10}" >${cur_dir}/q_all_online_table2_q10.out
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
   if [[ ${v_row_num1} != 10 ]]|| [[ ${v_row_num2} != 10 ]] || [[ ${v_row_num3} != 10 ]] || [[ ${v_row_num4} != 10 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}table all online query row num != 20."
   fi    
   # stop dn
#   exec 3<${cur_dir}/tmp_node.out
#   while read line<&3
#   do
#   query_ip=`head -1 ${cur_dir}/tmp_node.out`
#   query_ip2=`tail -1 ${cur_dir}/tmp_node.out`
#
#      # stop dn
#      ssh ${os_user_name}@${line} "source /etc/profile;cd ${upd_from_db_dir};sudo ./sbin/stop-datanode.sh"
#      check_dn_jps ${line} 120
#      if [[ ${query_ip} = ${line} ]];then
#         query_ip=${query_ip2}
#      fi
#      v_ip=`echo ${line}|awk -F '.' '{print $4}'`
#      exception_num=0
#      while true
#      do
#      ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql1}" >${cur_dir}/q_stop_ip${v_ip}_tree.out
#      v_exception_num=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_tree.out|wc -l`
#      if [[ ${v_exception_num} = 0 ]];then
#           break
#      else
#	      let exception_num++
#           sleep 1
#      fi
#      if [[ ${exception_num} -ge 10 ]];then
#	      let fail_flag++
#	      break
#      fi
#      done
#   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql4}"
#   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql4}" >${cur_dir}/tmp.out
#   check_res_eq " 4|" 1
#   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql5}" >${cur_dir}/tmp.out
#   check_res_eq " 4|" 1
#   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql6}" >${cur_dir}/tmp.out
#   check_res_eq "1970-01" 2 
#   check_res_eq " 2925|" 1
#   check_res_eq " 2926|" 1
#   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql7}" >${cur_dir}/tmp.out
#   check_res_eq "1970-01" 2 
#   check_res_eq " 2925|" 1
#   check_res_eq " 2926|" 1
#   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql8}" >${cur_dir}/q_stop_ip${v_ip}_tree_q8.out
#   v_row_num=`grep root.test ${cur_dir}/q_stop_ip${v_ip}_tree_q8.out|wc -l`
#   if [[ ${v_row_num} != 20 ]];then
#           let fail_flag++
#           v_warnMessage="${v_warnMessage}tree stop_ip${v_ip} query sql8 row num != 20."
#   fi
#
#      exception_num=0
#      while true
#      do
#
#      ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql2}" >${cur_dir}/q_stop_ip${v_ip}_table1.out
#      ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql3}" >${cur_dir}/q_stop_ip${v_ip}_table2.out
#      ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql9}" >${cur_dir}/q_stop_ip${v_ip}_table1_q9.out
#   ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql10}" >${cur_dir}/q_stop_ip${v_ip}_table2_q10.out
#   v_exception_num1=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table1.out|wc -l`
#   v_exception_num2=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table2.out|wc -l`
#   v_exception_num3=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table1_q9.out|wc -l`
#   v_exception_num4=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table2_q10.out|wc -l`
#   v_row_num1=`grep d_ ${cur_dir}/q_stop_ip${v_ip}_table1.out|wc -l`
#   v_row_num2=`grep d_ ${cur_dir}/q_stop_ip${v_ip}_table2.out|wc -l`
#   v_row_num3=`grep d_ ${cur_dir}/q_stop_ip${v_ip}_table1_q9.out|wc -l`
#   v_row_num4=`grep d_ ${cur_dir}/q_stop_ip${v_ip}_table2_q10.out|wc -l`
#   v_exception_num=$((v_exception_num1+v_exception_num2+v_exception_num3+v_exception_num4))
#
#      v_exception_num=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table.out|wc -l`
#      if [[ ${v_exception_num} = 0 ]];then
#           break
#      else
#	      let exception_num++
#           sleep 1
#      fi
#      if [[ ${exception_num} -ge 10 ]];then
#	      let fail_flag++
#	      break
#      fi
#      done
#
#      v_diff_tree=`diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_stop_ip${v_ip}_tree.out|grep "root.test"|wc -l`
#      v_diff_tree1=`diff ${cur_dir}/q_all_online_tree_q8.out ${cur_dir}/q_stop_ip${v_ip}_tree_q8.out|grep "root.test"|wc -l`
#      v_diff_table1=`diff ${cur_dir}/q_all_online_table1.out ${cur_dir}/q_stop_ip${v_ip}_table1.out|egrep "d_"|wc -l`
#      v_diff_table1_q9=`diff ${cur_dir}/q_all_online_table1_q9.out ${cur_dir}/q_stop_ip${v_ip}_table1_q9.out|egrep "d_"|wc -l`
#      v_diff_table2=`diff ${cur_dir}/q_all_online_table2.out ${cur_dir}/q_stop_ip${v_ip}_table2.out|egrep "d_"|wc -l`
#      v_diff_table2_q10=`diff ${cur_dir}/q_all_online_table2_q10.out ${cur_dir}/q_stop_ip${v_ip}_table2_q10.out|egrep "d_"|wc -l`
#      v_diff_total=$((v_diff_tree+v_diff_table1+v_diff_table2+v_diff_tree1+v_diff_table1_q9+v_diff_table2_q10))
#      if [[ ${v_diff_total} -gt 0 ]];then
#         let fail_flag++
#	 v_warnMessage="${v_warnMessage}.data inconsistent"
#	 let backup_data_log_flag++
#	 diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_stop_ip${v_ip}_tree.out
#	 diff ${cur_dir}/q_all_online_table1.out ${cur_dir}/q_stop_ip${v_ip}_table1.out
#	 diff ${cur_dir}/q_all_online_table2.out ${cur_dir}/q_stop_ip${v_ip}_table2.out
#	 diff ${cur_dir}/q_all_online_tree_q8.out ${cur_dir}/q_stop_ip${v_ip}_tree_q8.out
#	 diff ${cur_dir}/q_all_online_table1_q9.out ${cur_dir}/q_stop_ip${v_ip}_table1_q9.out
#	 diff ${cur_dir}/q_all_online_table2_q10.out ${cur_dir}/q_stop_ip${v_ip}_table2_q10.out
#         echo "diff : ${v_diff_total}"
#      fi
#      # restart
#      v_start_time=`date +%s`
#      ssh ${os_user_name}@${line} "source /etc/profile;cd ${upd_from_db_dir};sudo ./sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
#      while true
#      do
#      v_start_ok=`${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${line}  -timeout 3600 -e "show datanodes;"|grep "${line}|"|grep Running|wc -l`
#      if [[ ${v_start_ok} -gt 0 ]];then
#         break
#      else
#         sleep 1
#      fi
#      v_cur_time=`date +%s`
#      v_elp_time=$((v_cur_time-v_start_time))
#      if [[ ${v_elp_time} -gt 180 ]];then
#         let fail_flag++
#         echo "restart ${line} failed."
#         return
#      fi
#      done
#   done
}

function check_log()
{
exec 3<${nodeinfo_dir}/confignode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "sudo gunzip ${upd_from_cn_db_dir}/logs/*confignode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${upd_from_cn_db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err1=`ssh ${os_user_name}@${line} "grep BufferUnderflowException ${upd_from_cn_db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err2=`ssh ${os_user_name}@${line} "grep \"but return HAS_MORE_STATE\" ${upd_from_cn_db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err3=`ssh ${os_user_name}@${line} "grep \"ClassCastException\" ${upd_from_cn_db_dir}/logs/*confignode*all*|wc -l"`
   if [[ ${v_npe} -gt 0 ]];then
	   let fail_flag++
	   let backup_log_flag++
	   echo "CN ${line} NullPointer : ${v_npe}"
	   v_warnMessage="${v_warnMessage}CN ${line} NullPointer: ${v_npe}."
   fi
   v_cn_err_total=$((v_cn_err1+v_cn_err2+v_cn_err3))
   if [[ ${v_cn_err_total} -gt 0 ]];then
           let fail_flag++
           let backup_log_flag++
           echo "CN ${line} has error: ${v_cn_err_total}"
	   v_warnMessage="${v_warnMessage}CN ${line} unexpected log : ${v_cn_err_total}."
   fi
done
exec 3<${nodeinfo_dir}/datanode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "sudo gunzip ${upd_from_db_dir}/logs/*datanode*all*"
   v_npe_total=`ssh ${os_user_name}@${line} "grep NullPointer ${upd_from_db_dir}/logs/*datanode*all* 2>/dev/null|wc -l"`
   v_npe_baseline=0
   if [[ -f "${cur_dir}/dn_${line}_npe_before_upgrade.count" ]]; then
      v_npe_baseline=`cat "${cur_dir}/dn_${line}_npe_before_upgrade.count"`
   fi
   v_npe=$((v_npe_total-v_npe_baseline))
   if [[ ${v_npe} -lt 0 ]]; then
      v_npe=0
   fi
   echo "DN ${line} NullPointer total=${v_npe_total}, old-version baseline=${v_npe_baseline}, upgraded-version new=${v_npe}"
   v_err=`ssh ${os_user_name}@${line} "grep CompactionTableSchemaNotMatchException ${upd_from_db_dir}/logs/*datanode*all*|wc -l"`
   v_err2=`ssh ${os_user_name}@${line} "grep \"has overlapped data\" ${upd_from_db_dir}/logs/*datanode*all*|wc -l"`
   v_err3=`ssh ${os_user_name}@${line} "grep \"which should be later than the last time\" ${upd_from_db_dir}/logs/*datanode*all*|wc -l"`
   v_err4=`ssh ${os_user_name}@${line} "grep \"DataTypeInconsistentException\" ${upd_from_db_dir}/logs/*datanode*all*|wc -l"`
   v_err5=`ssh ${os_user_name}@${line} "grep \"ArrayIndexOutOfBoundsException\" ${upd_from_db_dir}/logs/*datanode*all*|wc -l"`
   v_err6=`ssh ${os_user_name}@${line} "grep \"Alter timeseries .* data type from null to\" ${upd_from_db_dir}/logs/*datanode*all*|wc -l"`
   v_err7=`ssh ${os_user_name}@${line} "grep \"StatisticsClassException\" ${upd_from_db_dir}/logs/*datanode*all*|wc -l"`
   v_err8=`ssh ${os_user_name}@${line} "grep \"BufferUnderflowException\" ${upd_from_db_dir}/logs/*datanode*all*|wc -l"`
   v_err9=`ssh ${os_user_name}@${line} "grep \"NegativeArraySizeException\" ${upd_from_db_dir}/logs/*datanode*all*|wc -l"`
   v_err10=`ssh ${os_user_name}@${line} "grep \"ClassCastException\" ${upd_from_db_dir}/logs/*datanode*all*|wc -l"`
   v_dn_total_err=$((v_err+v_err2+v_err3+v_err4+v_err5+v_err6+v_err7+v_err8+v_err9+v_err10))

   if [[ ${v_npe} -gt 0 ]];then
           let fail_flag++
	   let backup_log_flag++
 	   v_warnMessage="${v_warnMessage}DN ${line} upgraded-version new NullPointer: ${v_npe}."
           echo "DN ${line} upgraded-version new NullPointer : ${v_npe}"
   fi
   if [[ ${v_dn_total_err} -gt 0 ]];then
	   let fail_flag++
	   let backup_log_flag++
	   v_warnMessage="${v_warnMessage}DN ${line} unexpected log : ${v_dn_total_err}."
	   echo "DN ${line} has error: ${v_dn_total_err}"
   fi

done


}

# Manual data partition table repair (auto-repair has been removed).
function trigger_manual_partition_repair()
{
    local repair_cli_dir="${upd_cli_dir:-${cli_dir}}"
    local repair_out="${cur_dir}/manual_repair_trigger.out"
    log "INFO" "Trigger REPAIR DATA PARTITION TABLE manually"
    ${repair_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "REPAIR DATA PARTITION TABLE;" > "${repair_out}" 2>&1
    if grep -q "The statement is executed successfully" "${repair_out}"; then
        log "INFO" "REPAIR DATA PARTITION TABLE returned successfully"
    else
        log "ERROR" "REPAIR DATA PARTITION TABLE failed"
        cat "${repair_out}"
        let fail_flag++
        v_warnMessage="${v_warnMessage}manual repair trigger failed."
        return 1
    fi
}

function wait_manual_partition_repair()
{
    local repair_cli_dir="${upd_cli_dir:-${cli_dir}}"
    local progress_out="${cur_dir}/manual_repair_progress.out"
    local waited=0
    sleep 1
    while [[ ${waited} -lt 600 ]]
    do
        ${repair_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "SHOW REPAIR DATA PARTITION TABLE PROGRESS;" > "${progress_out}" 2>&1
        if grep -q "IDLE" "${progress_out}"; then
            log "INFO" "Manual partition repair finished (IDLE)"
            return 0
        fi
        sleep 2
        waited=$((waited+2))
    done
    log "ERROR" "Manual partition repair did not finish within 600 seconds"
    cat "${progress_out}"
    let fail_flag++
    v_warnMessage="${v_warnMessage}manual repair timeout."
    return 1
}

function manual_partition_repair()
{
    trigger_manual_partition_repair || return 1
    wait_manual_partition_repair
}

function check_partition_still_missing_before_repair()
{
    local count_out="${cur_dir}/v2_791_before_repair_count.out"
    local show_out="${cur_dir}/v2_791_before_repair_show.out"
    local count_is_four=0 full_markers=0

    ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} \
        -sql_dialect tree -timeout 36000 \
        -e "count timepartition where database=root.test.g_0;" >"${count_out}" 2>&1
    ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} \
        -sql_dialect tree -timeout 36000 \
        -e "show timepartition where database=root.test.g_0;" >"${show_out}" 2>&1

    grep -Eq '\|[[:space:]]*4[[:space:]]*\|' "${count_out}" && count_is_four=1
    if [[ `grep -c "1970-01" "${show_out}"` -eq 2 ]] \
        && grep -q " 2925|" "${show_out}" \
        && grep -q " 2926|" "${show_out}"; then
        full_markers=1
    fi

    if [[ ${count_is_four} -eq 1 && ${full_markers} -eq 1 ]]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}lost time partition was already visible before manual repair."
        log "ERROR" "V2-791 precondition failed: lost time partition was automatically restored before REPAIR"
        cat "${count_out}"
        cat "${show_out}"
        return 1
    fi

    log "INFO" "V2-791 precondition passed: lost time partition is still missing after rolling upgrade and 300s wait"
    cat "${count_out}"
    cat "${show_out}"
}

# Save the first all-online query result as the fixed baseline for restart checks.
function save_online_baseline()
{
    cp -f "${cur_dir}/q_all_online_tree.out" "${cur_dir}/baseline_all_online_tree.out"
    cp -f "${cur_dir}/q_all_online_table1.out" "${cur_dir}/baseline_all_online_table1.out"
    cp -f "${cur_dir}/q_all_online_table2.out" "${cur_dir}/baseline_all_online_table2.out"
    log "INFO" "Saved all-online tree/table1/table2 query results as restart baseline"
}

function record_restart_mismatch()
{
    local round=$1
    local model=$2
    let fail_flag++
    v_warnMessage="${v_warnMessage}restart round ${round} ${model} data inconsistent."
    log "ERROR" "Restart round ${round}: ${model} query result differs from baseline"
}

# Compare data rows only. CLI timing and table-border lines are intentionally ignored.
function compare_online_with_baseline()
{
    local round=$1
    local tree_out="${cur_dir}/restart_${round}_all_online_tree.out"
    local table1_out="${cur_dir}/restart_${round}_all_online_table1.out"
    local table2_out="${cur_dir}/restart_${round}_all_online_table2.out"

    local tree_sql="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from root.test.g_0.** align by device;"
    local table1_sql="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table1_0 group by device_id order by device_id;"
    local table2_sql="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table2_0 group by device_id order by device_id;"

    ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${tree_sql}" > "${tree_out}" 2>&1
    ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${table1_sql}" > "${table1_out}" 2>&1
    ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${table2_sql}" > "${table2_out}" 2>&1

    grep 'root.test' "${cur_dir}/baseline_all_online_tree.out" > "${cur_dir}/baseline_tree.data"
    grep 'root.test' "${tree_out}" > "${cur_dir}/restart_${round}_tree.data"
    if ! diff -u "${cur_dir}/baseline_tree.data" "${cur_dir}/restart_${round}_tree.data"; then
        record_restart_mismatch "${round}" "tree"
    fi

    grep 'd_' "${cur_dir}/baseline_all_online_table1.out" > "${cur_dir}/baseline_table1.data"
    grep 'd_' "${table1_out}" > "${cur_dir}/restart_${round}_table1.data"
    if ! diff -u "${cur_dir}/baseline_table1.data" "${cur_dir}/restart_${round}_table1.data"; then
        record_restart_mismatch "${round}" "table1_0"
    fi

    grep 'd_' "${cur_dir}/baseline_all_online_table2.out" > "${cur_dir}/baseline_table2.data"
    grep 'd_' "${table2_out}" > "${cur_dir}/restart_${round}_table2.data"
    if ! diff -u "${cur_dir}/baseline_table2.data" "${cur_dir}/restart_${round}_table2.data"; then
        record_restart_mismatch "${round}" "table2_0"
    fi
}

# Restart the upgraded cluster using the in-place upgrade directories.
# Stop order: all DNs -> CN followers -> CN leader.
# Start order: all CNs -> all DNs.
function restart_upgraded_cluster()
{
    local round=$1
    local line
    local start_time
    local elapsed
    local running_num
    local cn_running_num
    local cn_order_file="${cur_dir}/restart_${round}_confignode_order.out"

    log "INFO" "Restart round ${round}: collect CN follower/leader order"
    ${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show confignodes;" > "${cur_dir}/restart_${round}_confignodes.out"
    grep Follower "${cur_dir}/restart_${round}_confignodes.out" | awk -F '|' '{gsub(" ","");print $4}' > "${cn_order_file}"
    grep Leader "${cur_dir}/restart_${round}_confignodes.out" | awk -F '|' '{gsub(" ","");print $4}' >> "${cn_order_file}"

    log "INFO" "Restart round ${round}: stop all DataNodes from ${upd_from_db_dir}"
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3
    do
        ssh ${os_user_name}@${line} "source /etc/profile;cd ${upd_from_db_dir};sudo ./sbin/stop-datanode.sh"
        check_dn_jps ${line} 180
    done
    exec 3<&-

    log "INFO" "Restart round ${round}: stop ConfigNode followers, then leader, from ${upd_from_cn_db_dir}"
    exec 3<"${cn_order_file}"
    while read line <&3
    do
        ssh ${os_user_name}@${line} "source /etc/profile;cd ${upd_from_cn_db_dir};sudo ./sbin/stop-confignode.sh"
        check_cn_jps ${line} 180
    done
    exec 3<&-

    log "INFO" "Restart round ${round}: start all ConfigNodes from ${upd_from_cn_db_dir}"
    exec 3<"${nodeinfo_dir}/confignode.txt"
    while read line <&3
    do
        ssh ${os_user_name}@${line} "source /etc/profile;cd ${upd_from_cn_db_dir};sudo ./sbin/start-confignode.sh -H ${upd_from_cn_db_dir}/cn_restart_${round}_$(date +%s)_heapdump.hprof > /dev/null 2>&1 &"
    done
    exec 3<&-

    start_time=$(date +%s)
    while true
    do
        running_num=0
        exec 3<"${nodeinfo_dir}/confignode.txt"
        while read line <&3
        do
            if ssh ${os_user_name}@${line} "sudo jps | grep -q '[[:space:]]ConfigNode$'"; then
                running_num=$((running_num+1))
            fi
        done
        exec 3<&-
        if [[ ${running_num} -eq ${cn_num} ]]; then
            break
        fi
        sleep 2
        elapsed=$(($(date +%s)-start_time))
        if [[ ${elapsed} -gt 180 ]]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}restart round ${round} ConfigNodes start timeout."
            log "ERROR" "Restart round ${round}: ConfigNodes did not all become Running within 180 seconds"
            return 1
        fi
    done

    log "INFO" "Restart round ${round}: start all DataNodes from ${upd_from_db_dir}"
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3
    do
        ssh ${os_user_name}@${line} "source /etc/profile;cd ${upd_from_db_dir};sudo ./sbin/start-datanode.sh -H ${upd_from_db_dir}/dn_restart_${round}_$(date +%s)_heapdump.hprof > /dev/null 2>&1 &"
    done
    exec 3<&-

    start_time=$(date +%s)
    while true
    do
        running_num=$(${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -timeout 3600 -e "show datanodes;" 2>/dev/null | grep Running | wc -l)
        cn_running_num=$(${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -timeout 3600 -e "show confignodes;" 2>/dev/null | grep Running | wc -l)
        if [[ ${running_num} -eq ${dn_num} && ${cn_running_num} -eq ${cn_num} ]]; then
            break
        fi
        sleep 2
        elapsed=$(($(date +%s)-start_time))
        if [[ ${elapsed} -gt 180 ]]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}restart round ${round} cluster start timeout."
            log "ERROR" "Restart round ${round}: cluster did not become fully Running within 180 seconds (CN=${cn_running_num}/${cn_num}, DN=${running_num}/${dn_num})"
            return 1
        fi
    done

    wait_sync_done 180
    wait_iot_consensus_sync_lag_zero 300 || return 1
    log "INFO" "Restart round ${round}: all CNs and DNs are Running"
}

function backup_upgraded_cluster_logs()
{
    local backup_time=$(date +%Y%m%d%H%M%S)
    local testcase_name=${SCRIPT_NAME%.sh}
    local backup_desc="${testcase_name}_${backup_time}"
    local line

    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3
    do
        ssh ${os_user_name}@${line} "if test -d ${upd_from_db_dir}/logs; then sudo cp -rp ${upd_from_db_dir}/logs ${upd_from_db_dir}/logs_${backup_desc}; fi"
    done
    exec 3<&-

    exec 3<"${nodeinfo_dir}/confignode.txt"
    while read line <&3
    do
        ssh ${os_user_name}@${line} "if test -d ${upd_from_cn_db_dir}/logs; then sudo cp -rp ${upd_from_cn_db_dir}/logs ${upd_from_cn_db_dir}/logs_${backup_desc}; fi"
    done
    exec 3<&-
    log "INFO" "Backed up upgraded CN/DN logs with suffix ${backup_desc}"
}
function testcase1()
{
# check data
#before ttl check data
start_bm_part1
#TTL SEC 1768953600 date -d"2000-01-22T08:00:01" +%s
ttl_time_point=948499201000
v_cur_sec=$(date +%s)
v_cur_ms=$((v_cur_sec*1000))
v_ttl_value=$((v_cur_ms-ttl_time_point))

## set ttl

${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show databases;">${cur_dir}/bef_ttl_show.out
${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show databases;" >>${cur_dir}/bef_ttl_show.out
${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "use db_g_0;show tables;" >>${cur_dir}/bef_ttl_show.out
${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -e "select * from root.test.g_0.d1_0  limit 10;" >>${cur_dir}/bef_ttl_show.out
${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -e "select * from root.test.g_0.d1_4  limit 10;" >>${cur_dir}/bef_ttl_show.out
${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "set ttl to root.test.g_0.d1_4 ${v_ttl_value};"
${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "set ttl to root.test.g_0.d2_4 ${v_ttl_value};"
${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "ALTER TABLE db_g_0.table1_0 set properties TTL=${v_ttl_value};"
${upd_cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "ALTER TABLE db_g_0.table2_0 set properties TTL=${v_ttl_value};"
start_bm_part2
upgrade_confignode
upgrade_datanode
wait
sleep 300
# V2-791: rolling upgrade must not make the lost time partition visible by
# itself. Explicitly retain this negative evidence before manual REPAIR.
check_partition_still_missing_before_repair
# All nodes now run the SQL-capable version; trigger repair explicitly.
manual_partition_repair
wait_iot_consensus_sync_lag_zero 300 || return 1
check_data_consistent
save_online_baseline

if restart_upgraded_cluster 1; then
    compare_online_with_baseline 1
else
    log "ERROR" "Restart round 1 failed; skip round 2 and finish with log backup"
    check_log
    backup_upgraded_cluster_logs
    return 1
fi

if restart_upgraded_cluster 2; then
    compare_online_with_baseline 2
else
    log "ERROR" "Restart round 2 failed; finish with log backup"
    check_log
    backup_upgraded_cluster_logs
    return 1
fi
#check log
#TTL SEC 1768953600 date -d"2000-01-22T08:00:01" +%s
#ttl_time_point=948499201000
#v_cur_sec=$(date +%s)
#v_cur_ms=$((v_cur_sec*1000))
#v_ttl_value=$((v_cur_ms-ttl_time_point))
## set ttl
#${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "set ttl to root.test.g_0.d1_4 ${v_ttl_value};"
#${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "set ttl to root.test.g_0.d2_4 ${v_ttl_value};"
#${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "ALTER TABLE db_g_0.table1_0 set properties TTL=${v_ttl_value};"
#${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "ALTER TABLE db_g_0.table2_0 set properties TTL=${v_ttl_value};"
# sleep 
#sleep 20
#check_data_consistent
#sh -x "${clean_env_dir}/stop_cluster_upd_from_version.sh" >> "${log_file}" 2>&1
#sh -x "${prepare_env_dir}/start_cluster_v20_upd_from_db.sh" "2" "${total_node_num}" >> "${log_file}" 2>&1
#sleep 180
#check_data_consistent
check_log
backup_upgraded_cluster_logs
#v_backup_desc=`echo ${SCRIPT_NAME} |awk -F '.' '{print $1}'`
#v_backup_time=`date "+%Y_%m_%d_%H_%M_%S"`
#if [[ ${backup_data_log_flag} -gt 0 ]];then
#   sh ${clean_env_dir}/backup_cluster_logs_data.sh ${v_backup_time}_${v_backup_desc}
#   backup_log_flag=0  
#fi
#if [[ ${backup_log_flag} -gt 0 ]];then
#	v_backup_time=`date +%s`
#    sh ${clean_env_dir}/backup_cluster_logs.sh ${v_backup_time}_${v_backup_desc} 
#fi
#   if [[ ${fail_flag} -gt 0 ]];then
#	   echo "testcase1 fail"
#   else
#	   echo "testcase1 pass"
#
#   fi
}
# start cluster 
echo "">${log_file}
start_db
v_start_test_time=`date +%s`
testcase1
v_end_test_time=`date +%s`
v_elp_time=$((v_end_test_time-v_start_test_time))

# record test result
function write_result()
{
        test_time=$(date +"%Y-%m-%dT%H:%M:%S.%3N%:z")
   v_bm_max_value=`grep "Test elapsed" ${bm_log_dir}/${t}_bm*out|awk '{print $8}'|sort -n|tail -1`

   v_bm_sum_value=`grep "Test elapsed" ${bm_log_dir}/${t}_bm*out| awk '{print $8}' | sort -n | awk '{sum+=$1} END {print sum}'`
   # 写入表头
   v_exist_flag=`grep Time,testTimechoDB $CSV_FILE|wc -l`
   if [[ ${v_exist_flag} -gt 0 ]];then
           echo "head is exist."
   else
   echo "Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage,maxBMTestTimeSec,sumBMTestTimeSec" > "$CSV_FILE"
   fi
   if [[ ${fail_flag} -gt 0 ]];then
#           echo "${test_time},'${testdb}','${v_consensus}','${SCRIPT_NAME}','FAIL',${v_elp_time},${v_warnNum},'${v_warnMessage}',${v_bm_max_value},${v_bm_sum_value}">>"$CSV_FILE"
           echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},FAIL,${v_elp_time},${v_warnNum},${v_warnMessage},${v_bm_max_value},${v_bm_sum_value}">>"$CSV_FILE"

           echo "testcase1 fail"
   else
           echo "testcase1 pass"
#           echo "${test_time},'${testdb}','${v_consensus}','${SCRIPT_NAME}','PASS',${v_elp_time},${v_warnNum},'${v_warnMessage}',${v_bm_max_value},${v_bm_sum_value}">>"$CSV_FILE"
           echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},PASS,${v_elp_time},${v_warnNum},${v_warnMessage},${v_bm_max_value},${v_bm_sum_value}">>"$CSV_FILE"
   fi

}
write_result
