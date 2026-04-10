#!/bin/bash
# 兼容所有Bash版本（包括3.x），移除进程替换、mapfile等高级特性
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
cli_dir=${db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
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
data3_dir="/data3/iotdb_data/${testdb}/data"
ssl_str=""
bm_dir="${cur_dir}/../benchmark/bm_20251220_38c839b_v20"
backup_log_flag=0
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
        } # ✅ 这里补上 }，语法 100% 正确

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
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=5"
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
    fail_flag_local=0

    # 配置仅CN节点
    log "INFO" "启动仅ConfigNode节点并行配置: ${only_cn_ips[*]}"
    for ip in "${only_cn_ips[@]}"; do
        (configure_confignode "${ip}" || touch /tmp/conf_fail.flag) &
        pids+=($!)
    done

    # 配置仅DN节点
    log "INFO" "启动仅DataNode节点并行配置: ${only_dn_ips[*]}"
    for ip in "${only_dn_ips[@]}"; do
        (configure_datanode "${ip}" || touch /tmp/conf_fail.flag) &
        pids+=($!)
    done

    # 配置混合节点
    log "INFO" "启动混合节点（CN+DN）并行配置: ${mixed_ips[*]}"
    for ip in "${mixed_ips[@]}"; do
        (configure_mixed_node "${ip}" || touch /tmp/conf_fail.flag) &
        pids+=($!)
    done

    # -------------------- 步骤4：等待所有进程完成 --------------------
    log "INFO" "等待所有节点配置进程完成..."
    for pid in "${pids[@]}"; do
        if wait "${pid}"; then
            log "INFO" "进程PID ${pid} 执行成功"
        else
            log "ERROR" "进程PID ${pid} 执行失败"
            fail_flag_local=1
        fi
    done

    # 检查是否有配置失败
    if [ -f /tmp/conf_fail.flag ]; then
        fail_flag_local=1
        rm -f /tmp/conf_fail.flag
    fi

    # 清理临时文件
    rm -f /tmp/cn_ips.tmp /tmp/dn_ips.tmp

    # 同步全局fail_flag
    if [ ${fail_flag_local} -eq 1 ]; then
        fail_flag=1
        log "ERROR" "部分节点配置失败，请查看日志：${log_file}"
    else
        log "INFO" "所有节点配置完成！日志文件：${log_file}"
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
function start_bm()
{
bm_conf=explain
#get root password
#test time 15h
#v_bm_test_time=54000000
#v_bm_test_time=36000000
v_20_pass=`grep ^passwd_param= ${db_dir}/sbin/start-cli.sh |grep TimechoDB|wc -l`
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
sleep 30
wait
}
function check_res()
{
        v_exp_msg=$1
        v_exp_num=$2
        v_act_num=$(grep ${v_exp_msg} ${cur_dir}/tmp.out|wc -l)
        if [[ ${v_act_num} -ge ${v_exp_num} ]];then
                echo "pass"
        else
                let fail_flag++
                v_warnMessage="${v_warnMessage}check_res ${v_exp_msg} exp num>=${v_exp_num} failed."
                cat ${cur_dir}/tmp.out
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

function check_log()
{
exec 3<${nodeinfo_dir}/confignode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*confignode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err1=`ssh ${os_user_name}@${line} "grep BufferUnderflowException ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err2=`ssh ${os_user_name}@${line} "grep \"but return HAS_MORE_STATE\" ${db_dir}/logs/*confignode*all*|wc -l"`
   if [[ ${v_npe} -gt 0 ]];then
	   let fail_flag++
	   let backup_log_flag++
	   echo "CN ${line} NullPointer : ${v_npe}"
	   v_warnMessage="${v_warnMessage}CN NPE." 
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
   v_err10=`ssh ${os_user_name}@${line} "grep \"RuntimeException: data type not matched\" ${db_dir}/logs/*datanode*all*|wc -l"`
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

function testcase1()
{

	${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d1_6 WHERE time>90000 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d2_6 WHERE time>90000 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d1_6 WHERE time>90000 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d2_6 WHERE time>90000 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d1_6 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d2_6 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d1_6 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d2_6 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d1_6;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d2_6 ;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d1_6 ;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d2_6 ;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.* ;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE SELECT * FROM root.test.g_0.* ;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"


${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT * FROM db_g_0.table_0 where device_id='d1_6' and time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE SELECT * FROM db_g_0.table_0 where device_id='d1_6' and time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT * FROM db_g_0.table_0 where device_id='d_6' and time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE SELECT * FROM db_g_0.table_0 where device_id='d_6' and time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"


${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT * FROM db_g_0.table_0 where time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE SELECT * FROM db_g_0.table_0 where time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd1_%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE  SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd1_%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd_%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE  SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd_%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE  SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

	${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "flush;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "flush;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d1_6 WHERE time>90000 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d2_6 WHERE time>90000 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d1_6 WHERE time>90000 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d2_6 WHERE time>90000 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d1_6 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d2_6 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d1_6 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d2_6 align by device;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d1_6;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE  SELECT * FROM root.test.g_0.d2_6 ;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d1_6 ;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.d2_6 ;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE VERBOSE  SELECT * FROM root.test.g_0.* ;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "EXPLAIN ANALYZE SELECT * FROM root.test.g_0.* ;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"


${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT * FROM db_g_0.table_0 where device_id='d1_6' and time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE SELECT * FROM db_g_0.table_0 where device_id='d1_6' and time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT * FROM db_g_0.table_0 where device_id='d_6' and time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE SELECT * FROM db_g_0.table_0 where device_id='d_6' and time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"


${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT * FROM db_g_0.table_0 where time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE SELECT * FROM db_g_0.table_0 where time>90000 order by time,device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd1_%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE  SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd1_%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd_%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE  SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd_%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"

check_res_eq "rowScanFilteredRows:" 0 "rowScanFilteredRows expect = 0"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "EXPLAIN ANALYZE VERBOSE  SELECT device_id, COUNT(*) FROM db_g_0.table_0 where device_id like 'd%'  group by device_id order by device_id;">${cur_dir}/tmp.out
v_isink_node_num=$(grep IdentitySinkNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "DownStreamPlanNodeId:" ${v_isink_node_num} "DownStreamPlanNodeId expect = ${v_isink_node_num}"
v_exchangenode_num=$(grep ExchangeNode ${cur_dir}/tmp.out|wc -l)
check_res_eq "size_in_bytes:" ${v_exchangenode_num} "size_in_bytes expect = ${v_exchangenode_num}"
v_query_statistics_num=$(grep "Query Statistics" ${cur_dir}/tmp.out|wc -l)
check_res_eq "timeSeriesIndexFilteredRows:" ${v_query_statistics_num} "timeSeriesIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "chunkIndexFilteredRows:" ${v_query_statistics_num} "chunkIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "pageIndexFilteredRows:" ${v_query_statistics_num} "pageIndexFilteredRows expect = ${v_query_statistics_num}"
check_res_eq "rowScanFilteredRows:" ${v_query_statistics_num} "rowScanFilteredRows expect = ${v_query_statistics_num}"
check_log
}
# start cluster 
echo "">${log_file}
start_db
v_start_test_time=`date +%s`
start_bm
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
	   v_backup_time=`date +%s`
	   v_backup_desc=`echo ${SCRIPT_NAME} |awk -F '.' '{print $1}'`
	   sh ${clean_env_dir}/backup_cluster_logs.sh ${v_backup_time}_${v_backup_desc}
   else
           echo "testcase1 pass"
#           echo "${test_time},'${testdb}','${v_consensus}','${SCRIPT_NAME}','PASS',${v_elp_time},${v_warnNum},'${v_warnMessage}',${v_bm_max_value},${v_bm_sum_value}">>"$CSV_FILE"
           echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},PASS,${v_elp_time},${v_warnNum},${v_warnMessage},${v_bm_max_value},${v_bm_sum_value}">>"$CSV_FILE"

# remove bm logs
#        rm -rf ${bm_log_dir}/${t}_bm.out
   fi

}
write_result
