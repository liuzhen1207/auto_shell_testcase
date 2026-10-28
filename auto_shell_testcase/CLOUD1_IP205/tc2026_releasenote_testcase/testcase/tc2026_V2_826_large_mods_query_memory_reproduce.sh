#!/bin/bash
# 兼容所有Bash版本（包括3.x），移除进程替换、mapfile等高级特性
set -uo pipefail
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
SCRIPT_NAME=$(basename "$0")
CASE_ID="V2-826"
TARGET_VERSION="v2092_0514_release"
MODS_TARGET_MB="${MODS_TARGET_MB:-512}"
QUERY_TIMEOUT_SEC="${QUERY_TIMEOUT_SEC:-180}"
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

# 读取配置文件（去空格，兼容低版本）
os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
case "$-" in
    *x*) xtrace_was_enabled=1; set +x ;;
    *)   xtrace_was_enabled=0 ;;
esac
root_pw=$(grep ^root_pw "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
[ "${xtrace_was_enabled}" -eq 1 ] && set -x
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
cn_db_parent_dir=$(grep ^v_cn_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
shell_client_db_parent_dir=$(grep ^v_shell_client_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')

if [ -z "${os_user_name}" ] || [ -z "${root_pw}" ] || [ -z "${testdb}" ] || [ -z "${db_parent_dir}" ] || [ -z "${cn_db_parent_dir}" ] || [ -z "${shell_client_db_parent_dir}" ]; then
    echo "ERROR: required setting missing in ${conf_file}" >&2
    exit 2
fi
cli_dir=${shell_client_db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
cn_db_dir=${cn_db_parent_dir}/${testdb}
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
cn_num=3
dn_num=5
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num+dn_num))
log_file="${cur_dir}/set_conf_parallel.log"
data1_dir="/data1/iotdb_data/${testdb}/data"
data3_dir="/data3/iotdb_data/${testdb}/data"

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
   if [ $? -eq 0 ]; then
       log "INFO" "集群环境清理完成"
   else
       log "ERROR" "集群环境清理失败"
       fail_flag=1
   fi
}

# Deploy the configured build when the controller/node only has the release zip.
ensure_version_deployed() {
   local package_zip
   package_zip=$(find "${cli_dir}" -maxdepth 1 -type f -name '*.zip' | head -1)
   if [ ! -f "${cli_dir}/conf/iotdb-system.properties" ]; then
       [ -n "${package_zip}" ] || { log "ERROR" "No release zip under ${cli_dir}"; return 1; }
       log "INFO" "Extract CLI build ${testdb} on controller"
       local extract_dir="/tmp/${CASE_ID}_controller_extract_$$"
       rm -rf "${extract_dir}" && mkdir -p "${extract_dir}" || return 1
       unzip -q "${package_zip}" -d "${extract_dir}" || return 1
       local package_root=$(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d | head -1)
       cp -rp "${package_root}/." "${cli_dir}/" || return 1
       cp -rp "${cli_dir}/conf" "${cli_dir}/conf_orig" || return 1
       rm -rf "${extract_dir}"
   fi
   package_zip=$(find "${cli_dir}" -maxdepth 1 -type f -name '*.zip' | head -1)

   while read -r node_ip; do
       [ -z "${node_ip}" ] && continue
       if ! ssh -n "${os_user_name}@${node_ip}" "test -f '${db_dir}/conf/iotdb-system.properties'"; then
           log "INFO" "Deploy ${testdb} to DataNode ${node_ip}"
           scp "${package_zip}" "${os_user_name}@${node_ip}:/tmp/${CASE_ID}_release.zip" || return 1
           ssh -n "${os_user_name}@${node_ip}" "rm -rf '/tmp/${CASE_ID}_extract' && mkdir -p '/tmp/${CASE_ID}_extract' '${db_dir}' && (cd '/tmp/${CASE_ID}_extract' && jar xf '/tmp/${CASE_ID}_release.zip') && cp -rp /tmp/${CASE_ID}_extract/*/. '${db_dir}/' && chmod +x '${db_dir}'/sbin/*.sh && cp -rp '${db_dir}/conf' '${db_dir}/conf_orig' && rm -rf '/tmp/${CASE_ID}_extract' '/tmp/${CASE_ID}_release.zip'" || return 1
       fi
   done < "${nodeinfo_dir}/datanode.txt"

   while read -r node_ip; do
       [ -z "${node_ip}" ] && continue
       if ! ssh -n "${os_user_name}@${node_ip}" "test -f '${cn_db_dir}/conf/iotdb-system.properties'"; then
           log "INFO" "Deploy ${testdb} to ConfigNode ${node_ip}"
           scp "${package_zip}" "${os_user_name}@${node_ip}:/tmp/${CASE_ID}_release.zip" || return 1
           ssh -n "${os_user_name}@${node_ip}" "rm -rf '/tmp/${CASE_ID}_extract' && mkdir -p '/tmp/${CASE_ID}_extract' '${cn_db_dir}' && (cd '/tmp/${CASE_ID}_extract' && jar xf '/tmp/${CASE_ID}_release.zip') && cp -rp /tmp/${CASE_ID}_extract/*/. '${cn_db_dir}/' && chmod +x '${cn_db_dir}'/sbin/*.sh && cp -rp '${cn_db_dir}/conf' '${cn_db_dir}/conf_orig' && rm -rf '/tmp/${CASE_ID}_extract' '/tmp/${CASE_ID}_release.zip'" || return 1
       fi
   done < "${nodeinfo_dir}/confignode.txt"
}

# 单个ConfigNode配置函数
configure_confignode() {
    local node_ip=$1
    log "INFO" "开始配置ConfigNode: ${node_ip}"
    
    # 整合所有ConfigNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="2G"/g' ${cn_db_dir}/conf/confignode-env.sh
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
        batch_set_sys_conf ".*cn_metric_level=.*" "cn_metric_level=IMPORTANT"
        batch_set_sys_conf ".*cn_metric_prometheus_reporter_port=.*" "cn_metric_prometheus_reporter_port=9081"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=3"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=2"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=1"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=1"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
EOF

    if [ $? -eq 0 ]; then
        log "INFO" "ConfigNode ${node_ip} 配置完成"
    else
        log "ERROR" "ConfigNode ${node_ip} 配置失败"
        fail_flag=1
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
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="4G"/g' ${db_dir}/conf/datanode-env.sh
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
        batch_set_sys_conf ".*dn_metric_level=.*" "dn_metric_level=IMPORTANT"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=3"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=2"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=1"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=1"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        batch_set_sys_conf ".*enable_seq_space_compaction=.*" "enable_seq_space_compaction=false"
        batch_set_sys_conf ".*enable_unseq_space_compaction=.*" "enable_unseq_space_compaction=false"
        batch_set_sys_conf ".*enable_cross_space_compaction=.*" "enable_cross_space_compaction=false"
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
            file="${db_dir}/conf/iotdb-system.properties"
            sed -i 's|.*dn_data_dirs=.*|dn_data_dirs=data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data,/data3/iotdb_data/${testdb}/data/datanode/data|g' \$file
            sed -i 's|.*dn_wal_dirs=.*|dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal,/data3/iotdb_data/${testdb}/data/datanode/wal|g' \$file
EOF
    fi

    if [ $? -eq 0 ]; then
        log "INFO" "DataNode ${node_ip} 配置完成"
    else
        log "ERROR" "DataNode ${node_ip} 配置失败"
        fail_flag=1
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
    > "${log_file}"
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
    log "INFO" "启动混合节点（CN+DN）并行配置: ${mixed_ips[*]-}"
    for ip in ${mixed_ips[*]-}; do
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
            fail_flag=1
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
       exit 1
   fi

   ensure_version_deployed
   if [ $? -ne 0 ]; then
       log "ERROR" "版本部署失败，终止启动流程"
       exit 1
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
       fail_flag=1
       exit 1
   fi
}

# testcase1 delete 1 row in memtable
function testcase1()
{
	fail_flag=0
#create table
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "create database IF NOT EXISTS db1;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "DROP TABLE IF EXISTS db1.t_object;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "create table db1.t_object(device_id string tag,color string tag,age string tag,department string tag ,file_type string field,file_content object field);"
v_sql_ins_100="INSERT INTO db1.t_object(time, device_id, color, age, department, file_type, file_content) VALUES
('2026-01-15T17:00:12.+08:00', 'd1', 'red', '18', 'dev', 'image', to_object(true,0,X'5f8a7b9c4d2e8f1a')),
('2026-01-15T17:00:12.001+08:00', 'd2', 'blue', '19', 'test', 'movie', to_object(true,0,X'7e9b8c0d3f4a5b6c')),
('2026-01-15T17:00:12.002+08:00', 'd3', 'green', '20', 'product', 'json', to_object(true,0,X'8a7b6c5d4e3f2a1b')),
('2026-01-15T17:00:12.003+08:00', 'd4', 'yellow', '21', 'ops', 'txt', to_object(true,0,X'9b8c7d6e5f4a3b2c')),
('2026-01-15T17:00:12.004+08:00', 'd5', 'black', '22', 'dev', 'image', to_object(true,0,X'0c9d8e7f6a5b4c3d')),
('2026-01-15T17:00:12.005+08:00', 'd6', 'white', '23', 'test', 'movie', to_object(true,0,X'1d0e9f8a7b6c5d4e')),
('2026-01-15T17:00:12.006+08:00', 'd7', 'purple', '24', 'product', 'json', to_object(true,0,X'2e1f0a9b8c7d6e5f')),
('2026-01-15T17:00:12.007+08:00', 'd8', 'orange', '25', 'ops', 'txt', to_object(true,0,X'3f2a1b0c9d8e7f6a')),
('2026-01-15T17:00:12.008+08:00', 'd9', 'pink', '26', 'dev', 'image', to_object(true,0,X'4a3b2c1d0e9f8a7b')),
('2026-01-15T17:00:12.009+08:00', 'd10', 'gray', '27', 'test', 'movie', to_object(true,0,X'5b4c3d2e1f0a9b8c')),
('2026-01-15T17:00:12.010+08:00', 'd1', 'red', '28', 'product', 'json', to_object(true,0,X'5f8a7b9c4d2e8f1a')),
('2026-01-15T17:00:12.011+08:00', 'd2', 'blue', '29', 'ops', 'txt', to_object(true,0,X'7e9b8c0d3f4a5b6c')),
('2026-01-15T17:00:12.012+08:00', 'd3', 'green', '30', 'dev', 'image', to_object(true,0,X'8a7b6c5d4e3f2a1b')),
('2026-01-15T17:00:12.013+08:00', 'd4', 'yellow', '18', 'test', 'movie', to_object(true,0,X'9b8c7d6e5f4a3b2c')),
('2026-01-15T17:00:12.014+08:00', 'd5', 'black', '19', 'product', 'json', to_object(true,0,X'0c9d8e7f6a5b4c3d')),
('2026-01-15T17:00:12.015+08:00', 'd6', 'white', '20', 'ops', 'txt', to_object(true,0,X'1d0e9f8a7b6c5d4e')),
('2026-01-15T17:00:12.016+08:00', 'd7', 'purple', '21', 'dev', 'image', to_object(true,0,X'2e1f0a9b8c7d6e5f')),
('2026-01-15T17:00:12.017+08:00', 'd8', 'orange', '22', 'test', 'movie', to_object(true,0,X'3f2a1b0c9d8e7f6a')),
('2026-01-15T17:00:12.018+08:00', 'd9', 'pink', '23', 'product', 'json', to_object(true,0,X'4a3b2c1d0e9f8a7b')),
('2026-01-15T17:00:12.019+08:00', 'd10', 'gray', '24', 'ops', 'txt', to_object(true,0,X'5b4c3d2e1f0a9b8c')),
('2026-01-15T17:00:12.020+08:00', 'd1', 'red', '25', 'dev', 'image', to_object(true,0,X'5f8a7b9c4d2e8f1a')),
('2026-01-15T17:00:12.021+08:00', 'd2', 'blue', '26', 'test', 'movie', to_object(true,0,X'7e9b8c0d3f4a5b6c')),
('2026-01-15T17:00:12.022+08:00', 'd3', 'green', '27', 'product', 'json', to_object(true,0,X'8a7b6c5d4e3f2a1b')),
('2026-01-15T17:00:12.023+08:00', 'd4', 'yellow', '28', 'ops', 'txt', to_object(true,0,X'9b8c7d6e5f4a3b2c')),
('2026-01-15T17:00:12.024+08:00', 'd5', 'black', '29', 'dev', 'image', to_object(true,0,X'0c9d8e7f6a5b4c3d')),
('2026-01-15T17:00:12.025+08:00', 'd6', 'white', '30', 'test', 'movie', to_object(true,0,X'1d0e9f8a7b6c5d4e')),
('2026-01-15T17:00:12.026+08:00', 'd7', 'purple', '18', 'product', 'json', to_object(true,0,X'2e1f0a9b8c7d6e5f')),
('2026-01-15T17:00:12.027+08:00', 'd8', 'orange', '19', 'ops', 'txt', to_object(true,0,X'3f2a1b0c9d8e7f6a')),
('2026-01-15T17:00:12.028+08:00', 'd9', 'pink', '20', 'dev', 'image', to_object(true,0,X'4a3b2c1d0e9f8a7b')),
('2026-01-15T17:00:12.029+08:00', 'd10', 'gray', '21', 'test', 'movie', to_object(true,0,X'5b4c3d2e1f0a9b8c')),
('2026-01-15T17:00:12.030+08:00', 'd1', 'red', '22', 'product', 'json', to_object(true,0,X'5f8a7b9c4d2e8f1a')),
('2026-01-15T17:00:12.031+08:00', 'd2', 'blue', '23', 'ops', 'txt', to_object(true,0,X'7e9b8c0d3f4a5b6c')),
('2026-01-15T17:00:12.032+08:00', 'd3', 'green', '24', 'dev', 'image', to_object(true,0,X'8a7b6c5d4e3f2a1b')),
('2026-01-15T17:00:12.033+08:00', 'd4', 'yellow', '25', 'test', 'movie', to_object(true,0,X'9b8c7d6e5f4a3b2c')),
('2026-01-15T17:00:12.034+08:00', 'd5', 'black', '26', 'product', 'json', to_object(true,0,X'0c9d8e7f6a5b4c3d')),
('2026-01-15T17:00:12.035+08:00', 'd6', 'white', '27', 'ops', 'txt', to_object(true,0,X'1d0e9f8a7b6c5d4e')),
('2026-01-15T17:00:12.036+08:00', 'd7', 'purple', '28', 'dev', 'image', to_object(true,0,X'2e1f0a9b8c7d6e5f')),
('2026-01-15T17:00:12.037+08:00', 'd8', 'orange', '29', 'test', 'movie', to_object(true,0,X'3f2a1b0c9d8e7f6a')),
('2026-01-15T17:00:12.038+08:00', 'd9', 'pink', '30', 'product', 'json', to_object(true,0,X'4a3b2c1d0e9f8a7b')),
('2026-01-15T17:00:12.039+08:00', 'd10', 'gray', '18', 'ops', 'txt', to_object(true,0,X'5b4c3d2e1f0a9b8c')),
('2026-01-15T17:00:12.040+08:00', 'd1', 'red', '19', 'dev', 'image', to_object(true,0,X'5f8a7b9c4d2e8f1a')),
('2026-01-15T17:00:12.041+08:00', 'd2', 'blue', '20', 'test', 'movie', to_object(true,0,X'7e9b8c0d3f4a5b6c')),
('2026-01-15T17:00:12.042+08:00', 'd3', 'green', '21', 'product', 'json', to_object(true,0,X'8a7b6c5d4e3f2a1b')),
('2026-01-15T17:00:12.043+08:00', 'd4', 'yellow', '22', 'ops', 'txt', to_object(true,0,X'9b8c7d6e5f4a3b2c')),
('2026-01-15T17:00:12.044+08:00', 'd5', 'black', '23', 'dev', 'image', to_object(true,0,X'0c9d8e7f6a5b4c3d')),
('2026-01-15T17:00:12.045+08:00', 'd6', 'white', '24', 'test', 'movie', to_object(true,0,X'1d0e9f8a7b6c5d4e')),
('2026-01-15T17:00:12.046+08:00', 'd7', 'purple', '25', 'product', 'json', to_object(true,0,X'2e1f0a9b8c7d6e5f')),
('2026-01-15T17:00:12.047+08:00', 'd8', 'orange', '26', 'ops', 'txt', to_object(true,0,X'3f2a1b0c9d8e7f6a')),
('2026-01-15T17:00:12.048+08:00', 'd9', 'pink', '27', 'dev', 'image', to_object(true,0,X'4a3b2c1d0e9f8a7b')),
('2026-01-15T17:00:12.049+08:00', 'd10', 'gray', '28', 'test', 'movie', to_object(true,0,X'5b4c3d2e1f0a9b8c')),
('2026-01-15T17:00:12.050+08:00', 'd1', 'red', '29', 'product', 'json', to_object(true,0,X'5f8a7b9c4d2e8f1a')),
('2026-01-15T17:00:12.051+08:00', 'd2', 'blue', '30', 'ops', 'txt', to_object(true,0,X'7e9b8c0d3f4a5b6c')),
('2026-01-15T17:00:12.052+08:00', 'd3', 'green', '18', 'dev', 'image', to_object(true,0,X'8a7b6c5d4e3f2a1b')),
('2026-01-15T17:00:12.053+08:00', 'd4', 'yellow', '19', 'test', 'movie', to_object(true,0,X'9b8c7d6e5f4a3b2c')),
('2026-01-15T17:00:12.054+08:00', 'd5', 'black', '20', 'product', 'json', to_object(true,0,X'0c9d8e7f6a5b4c3d')),
('2026-01-15T17:00:12.055+08:00', 'd6', 'white', '21', 'ops', 'txt', to_object(true,0,X'1d0e9f8a7b6c5d4e')),
('2026-01-15T17:00:12.056+08:00', 'd7', 'purple', '22', 'dev', 'image', to_object(true,0,X'2e1f0a9b8c7d6e5f')),
('2026-01-15T17:00:12.057+08:00', 'd8', 'orange', '23', 'test', 'movie', to_object(true,0,X'3f2a1b0c9d8e7f6a')),
('2026-01-15T17:00:12.058+08:00', 'd9', 'pink', '24', 'product', 'json', to_object(true,0,X'4a3b2c1d0e9f8a7b')),
('2026-01-15T17:00:12.059+08:00', 'd10', 'gray', '25', 'ops', 'txt', to_object(true,0,X'5b4c3d2e1f0a9b8c')),
('2026-01-15T17:00:12.060+08:00', 'd1', 'red', '26', 'dev', 'image', to_object(true,0,X'5f8a7b9c4d2e8f1a')),
('2026-01-15T17:00:12.061+08:00', 'd2', 'blue', '27', 'test', 'movie', to_object(true,0,X'7e9b8c0d3f4a5b6c')),
('2026-01-15T17:00:12.062+08:00', 'd3', 'green', '28', 'product', 'json', to_object(true,0,X'8a7b6c5d4e3f2a1b')),
('2026-01-15T17:00:12.063+08:00', 'd4', 'yellow', '29', 'ops', 'txt', to_object(true,0,X'9b8c7d6e5f4a3b2c')),
('2026-01-15T17:00:12.064+08:00', 'd5', 'black', '30', 'dev', 'image', to_object(true,0,X'0c9d8e7f6a5b4c3d')),
('2026-01-15T17:00:12.065+08:00', 'd6', 'white', '18', 'test', 'movie', to_object(true,0,X'1d0e9f8a7b6c5d4e')),
('2026-01-15T17:00:12.066+08:00', 'd7', 'purple', '19', 'product', 'json', to_object(true,0,X'2e1f0a9b8c7d6e5f')),
('2026-01-15T17:00:12.067+08:00', 'd8', 'orange', '20', 'ops', 'txt', to_object(true,0,X'3f2a1b0c9d8e7f6a')),
('2026-01-15T17:00:12.068+08:00', 'd9', 'pink', '21', 'dev', 'image', to_object(true,0,X'4a3b2c1d0e9f8a7b')),
('2026-01-15T17:00:12.069+08:00', 'd10', 'gray', '22', 'test', 'movie', to_object(true,0,X'5b4c3d2e1f0a9b8c')),
('2026-01-15T17:00:12.070+08:00', 'd1', 'red', '23', 'product', 'json', to_object(true,0,X'5f8a7b9c4d2e8f1a')),
('2026-01-15T17:00:12.071+08:00', 'd2', 'blue', '24', 'ops', 'txt', to_object(true,0,X'7e9b8c0d3f4a5b6c')),
('2026-01-15T17:00:12.072+08:00', 'd3', 'green', '25', 'dev', 'image', to_object(true,0,X'8a7b6c5d4e3f2a1b')),
('2026-01-15T17:00:12.073+08:00', 'd4', 'yellow', '26', 'test', 'movie', to_object(true,0,X'9b8c7d6e5f4a3b2c')),
('2026-01-15T17:00:12.074+08:00', 'd5', 'black', '27', 'product', 'json', to_object(true,0,X'0c9d8e7f6a5b4c3d')),
('2026-01-15T17:00:12.075+08:00', 'd6', 'white', '28', 'ops', 'txt', to_object(true,0,X'1d0e9f8a7b6c5d4e')),
('2026-01-15T17:00:12.076+08:00', 'd7', 'purple', '29', 'dev', 'image', to_object(true,0,X'2e1f0a9b8c7d6e5f')),
('2026-01-15T17:00:12.077+08:00', 'd8', 'orange', '30', 'test', 'movie', to_object(true,0,X'3f2a1b0c9d8e7f6a')),
('2026-01-15T17:00:12.078+08:00', 'd9', 'pink', '18', 'product', 'json', to_object(true,0,X'4a3b2c1d0e9f8a7b')),
('2026-01-15T17:00:12.079+08:00', 'd10', 'gray', '19', 'ops', 'txt', to_object(true,0,X'5b4c3d2e1f0a9b8c')),
('2026-01-15T17:00:12.080+08:00', 'd1', 'red', '20', 'dev', 'image', to_object(true,0,X'5f8a7b9c4d2e8f1a')),
('2026-01-15T17:00:12.081+08:00', 'd2', 'blue', '21', 'test', 'movie', to_object(true,0,X'7e9b8c0d3f4a5b6c')),
('2026-01-15T17:00:12.082+08:00', 'd3', 'green', '22', 'product', 'json', to_object(true,0,X'8a7b6c5d4e3f2a1b')),
('2026-01-15T17:00:12.083+08:00', 'd4', 'yellow', '23', 'ops', 'txt', to_object(true,0,X'9b8c7d6e5f4a3b2c')),
('2026-01-15T17:00:12.084+08:00', 'd5', 'black', '24', 'dev', 'image', to_object(true,0,X'0c9d8e7f6a5b4c3d')),
('2026-01-15T17:00:12.085+08:00', 'd6', 'white', '25', 'test', 'movie', to_object(true,0,X'1d0e9f8a7b6c5d4e')),
('2026-01-15T17:00:12.086+08:00', 'd7', 'purple', '26', 'product', 'json', to_object(true,0,X'2e1f0a9b8c7d6e5f')),
('2026-01-15T17:00:12.087+08:00', 'd8', 'orange', '27', 'ops', 'txt', to_object(true,0,X'3f2a1b0c9d8e7f6a')),
('2026-01-15T17:00:12.088+08:00', 'd9', 'pink', '28', 'dev', 'image', to_object(true,0,X'4a3b2c1d0e9f8a7b')),
('2026-01-15T17:00:12.089+08:00', 'd10', 'gray', '29', 'test', 'movie', to_object(true,0,X'5b4c3d2e1f0a9b8c')),
('2026-01-15T17:00:12.090+08:00', 'd1', 'red', '30', 'product', 'json', to_object(true,0,X'5f8a7b9c4d2e8f1a')),
('2026-01-15T17:00:12.091+08:00', 'd2', 'blue', '18', 'ops', 'txt', to_object(true,0,X'7e9b8c0d3f4a5b6c')),
('2026-01-15T17:00:12.092+08:00', 'd3', 'green', '19', 'dev', 'image', to_object(true,0,X'8a7b6c5d4e3f2a1b')),
('2026-01-15T17:00:12.093+08:00', 'd4', 'yellow', '20', 'test', 'movie', to_object(true,0,X'9b8c7d6e5f4a3b2c')),
('2026-01-15T17:00:12.094+08:00', 'd5', 'black', '21', 'product', 'json', to_object(true,0,X'0c9d8e7f6a5b4c3d')),
('2026-01-15T17:00:12.095+08:00', 'd6', 'white', '22', 'ops', 'txt', to_object(true,0,X'1d0e9f8a7b6c5d4e')),
('2026-01-15T17:00:12.096+08:00', 'd7', 'purple', '23', 'dev', 'image', to_object(true,0,X'2e1f0a9b8c7d6e5f')),
('2026-01-15T17:00:12.097+08:00', 'd8', 'orange', '24', 'test', 'movie', to_object(true,0,X'3f2a1b0c9d8e7f6a')),
('2026-01-15T17:00:12.098+08:00', 'd9', 'pink', '25', 'product', 'json', to_object(true,0,X'4a3b2c1d0e9f8a7b')),
('2026-01-15T17:00:12.099+08:00', 'd10', 'gray', '26', 'ops', 'txt', to_object(true,0,X'5b4c3d2e1f0a9b8c'));
"
echo "${v_sql_ins_100}"
#${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e <${cur_dir}/${SQL_FILE}
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "${v_sql_ins_100}"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "select * from db1.t_object offset 49 limit1;" >${cur_dir}/tmp.out
v_exp_err=`cat ${cur_dir}/tmp.out|grep "IoTDBSQLException: 700"|wc -l`
if [[ ${v_exp_err} = 0 ]];then
let fail_flag++
echo "testcase1 fail."
fi
v_del_time_value=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "select * from db1.t_object offset 49 limit 1;" |grep "+08:00"|awk -F "|" '{print $2}'`
echo "v_del_time_value=${v_del_time_value}"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "delete from db1.t_object where time=${v_del_time_value};" 
#get bin_tmp count
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "flush;"
sleep 2
bef_ttl_obj_total_count=0
exec 3<${nodeinfo_dir}/datanode.txt
while read line<&3
do
   v_data2_obj_count=`ssh ${os_user_name}@${line} "find  ${db_dir}/data/datanode/data/object -type f -name \"*.bin\" |wc  -l"`
   v_data1_obj_count=`ssh ${os_user_name}@${line} "find  ${data1_dir}/datanode/data/object -type f -name \"*.bin\" |wc  -l"`
   v_data3_obj_count=`ssh ${os_user_name}@${line} "find  ${data3_dir}/datanode/data/object -type f -name \"*.bin\" |wc  -l"`
   bef_ttl_obj_total_count=$((bef_ttl_obj_total_count+v_data2_obj_count+v_data1_obj_count+v_data3_obj_count))
done
exp_obj_num=$((dr_rep_num*99))
if [[ ${bef_ttl_obj_total_count} != ${exp_obj_num} ]];then
        echo "bef_ttl_obj_total_count ${bef_ttl_obj_total_count} != ${exp_obj_num}"
	let fail_flag++
fi
# set ttl
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "flush;alter table db1.t_object set properties ttl=600000;"
for i in {1..10}
do
	aft_ttl_obj_total_count=0
	exec 3<${nodeinfo_dir}/datanode.txt
	while read line<&3
	do
	   v_data2_obj_count=`ssh ${os_user_name}@${line} "find -name ${db_dir}/data/datanode/data/object -name *.bin |wc  -l"`
	   v_data1_obj_count=`ssh ${os_user_name}@${line} "find -name ${data1_dir}/datanode/data/object -name *.bin |wc  -l"`
	   v_data3_obj_count=`ssh ${os_user_name}@${line} "find -name ${data3_dir}/datanode/data/object -name *.bin |wc  -l"`
	   aft_ttl_obj_total_count=$((aft_ttl_obj_total_count+v_data2_obj_count+v_data1_obj_count+v_data3_obj_count))
	done
	if [[ ${aft_ttl_obj_total_count} -gt 0 ]];then
		echo "The TTL isn't working."
		sleep 60
	else
		echo "The TTL is working."
		break
	fi
done
if [[ ${aft_ttl_obj_total_count} -gt 0 ]];then
	echo "The TTL isn't working."
	let fail_flag++
fi
# 最终状态输出
if [ ${fail_flag} -eq 0 ]; then
    echo "${SCRIPT_NAME} testcase1 pass." 
else
    echo "${SCRIPT_NAME} testcase1 fail." 
fi

}

# V2-826: reproduce large mods2 query memory exhaustion on the pre-fix build.
testcase_v2_826() {
  local case_log="${cur_dir}/${CASE_ID}_$(date +%Y%m%d_%H%M%S).log"
  local sql_out="${cur_dir}/${CASE_ID}_query.out"
  local target_bytes=$((MODS_TARGET_MB * 1024 * 1024))
  local generator_source="${cur_dir}/V2826ModGenerator.java"
  # The caller already redirects the full trace (for example, to 1.out).
  # Do not use Bash process substitution here: this script is commonly run by `sh`.
  : > "${case_log}"
  log "INFO" "${CASE_ID} reproduction begins: version=${testdb}, target=${TARGET_VERSION}"
  if [ "${testdb}" != "${TARGET_VERSION}" ]; then
    log "ERROR" "conf/test.conf v_testdb=${testdb}, expected ${TARGET_VERSION}"
    return 2
  fi

  log "INFO" "Create one TsFile and one valid mods2 entry"
  set +x
  "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -u root -pw "${root_pw}" -e "DROP DATABASE IF EXISTS root.v2826; CREATE DATABASE root.v2826; CREATE TIMESERIES root.v2826.d1.s1 WITH DATATYPE=INT64, ENCODING=RLE; INSERT INTO root.v2826.d1(time,s1) VALUES(1,1); INSERT INTO root.v2826.d1(time,s1) VALUES(100,100); FLUSH; DELETE FROM root.v2826.d1.s1 WHERE time <= 50;"
  local prepare_rc=$?
  [ "${xtrace_was_enabled}" -eq 1 ] && set -x
  if [ ${prepare_rc} -ne 0 ]; then
    log "ERROR" "Failed to prepare base TsFile/mods2"
    return 3
  fi

  log "INFO" "Stop cluster before modifying mods2 files"
  sh -x "${clean_env_dir}/stop_cluster.sh" >> "${case_log}" 2>&1 || return 4

  if [ ! -f "${generator_source}" ]; then
    log "ERROR" "Missing valid mods2 generator: ${generator_source}"
    return 5
  fi

  local mods_count=0
  while read -r node_ip; do
    [ -z "${node_ip}" ] && continue
    log "INFO" "Expand valid mods2 records on DataNode ${node_ip} to ${MODS_TARGET_MB} MiB"
    scp "${generator_source}" "${os_user_name}@${node_ip}:/tmp/V2826ModGenerator.java" || return 5
    ssh "${os_user_name}@${node_ip}" "DB_DIR='${db_dir}' TARGET_BYTES='${target_bytes}' sh -s" <<'SH'
set -e
classpath="${DB_DIR}/lib/*"
work_dir=/tmp/v2826_mod_generator
rm -rf "${work_dir}"
mkdir -p "${work_dir}"
cp /tmp/V2826ModGenerator.java "${work_dir}/"
javac -cp "${classpath}" -d "${work_dir}" "${work_dir}/V2826ModGenerator.java"
found_file=$(find "${DB_DIR}/data/datanode/data" \
  "/data1/iotdb_data/$(basename "${DB_DIR}")/data/datanode/data" \
  "/data3/iotdb_data/$(basename "${DB_DIR}")/data/datanode/data" \
  -type f -name '*.mods2' -size +0c -print -quit 2>/dev/null || true)
if [ -z "${found_file}" ]; then
  echo "SKIP: no non-empty mods2 found on this DataNode"
  exit 10
fi
find "${DB_DIR}/data/datanode/data" \
  "/data1/iotdb_data/$(basename "${DB_DIR}")/data/datanode/data" \
  "/data3/iotdb_data/$(basename "${DB_DIR}")/data/datanode/data" \
  -type f -name '*.mods2' -size +0c -print 2>/dev/null | while IFS= read -r mods_file; do
  java -cp "${work_dir}:${classpath}" V2826ModGenerator "${mods_file}" "${TARGET_BYTES}"
done
rm -rf "${work_dir}" /tmp/V2826ModGenerator.java
SH
    local expand_rc=$?
    if [ ${expand_rc} -eq 10 ]; then
      log "INFO" "No non-empty mods2 on ${node_ip}; skip this DataNode"
      continue
    fi
    if [ ${expand_rc} -ne 0 ]; then
      log "ERROR" "Failed to expand mods2 on ${node_ip}"
      return 5
    fi
    mods_count=$((mods_count + 1))
  done < "${nodeinfo_dir}/datanode.txt"

  if [ ${mods_count} -eq 0 ]; then
    log "ERROR" "No non-empty mods2 found on any DataNode"
    return 5
  fi

  log "INFO" "Restart cluster with the expanded mods2 files"
  sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${case_log}" 2>&1 || return 6

  log "INFO" "Execute affected query, timeout=${QUERY_TIMEOUT_SEC}s"
  local begin_ts=$(date +%s)
  set +x
  timeout "${QUERY_TIMEOUT_SEC}" "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -u root -pw "${root_pw}" -e "SELECT s1 FROM root.v2826.d1 WHERE time >= 0 AND time <= 200;" > "${sql_out}" 2>&1
  local query_rc=$?
  [ "${xtrace_was_enabled}" -eq 1 ] && set -x
  local elapsed=$(( $(date +%s) - begin_ts ))
  cat "${sql_out}"

  log "INFO" "Collect DataNode liveness and OOM/GC evidence"
  local dead_nodes=0
  local oom_hits=0
  while read -r node_ip; do
    [ -z "${node_ip}" ] && continue
    ssh "${os_user_name}@${node_ip}" "pgrep -af 'IoTDBDataNode|DataNode' || true; grep -R -E 'OutOfMemoryError|Java heap space|GC overhead limit|Full GC' '${db_dir}/logs' 2>/dev/null | tail -30 || true" | tee -a "${case_log}"
    ssh "${os_user_name}@${node_ip}" "pgrep -f 'IoTDBDataNode|DataNode' >/dev/null" || dead_nodes=$((dead_nodes + 1))
    local hits=$(ssh "${os_user_name}@${node_ip}" "grep -R -E 'OutOfMemoryError|Java heap space|GC overhead limit' '${db_dir}/logs' 2>/dev/null | wc -l")
    oom_hits=$((oom_hits + hits))
  done < "${nodeinfo_dir}/datanode.txt"

  echo "RESULT case=${CASE_ID} version=${testdb} mods_target_mb=${MODS_TARGET_MB} query_rc=${query_rc} elapsed_sec=${elapsed} dead_nodes=${dead_nodes} oom_hits=${oom_hits}"
  if [ ${query_rc} -eq 124 ] || [ ${dead_nodes} -gt 0 ] || [ ${oom_hits} -gt 0 ]; then
    echo "${SCRIPT_NAME} testcase V2-826 REPRODUCED."
    return 0
  fi
  echo "${SCRIPT_NAME} testcase V2-826 NOT_REPRODUCED; inspect ${case_log} and increase MODS_TARGET_MB if necessary."
  return 1
}

# Independent execution order: stop/clean/reset -> configure -> start -> reproduce.
start_db
testcase_v2_826
exit $?
