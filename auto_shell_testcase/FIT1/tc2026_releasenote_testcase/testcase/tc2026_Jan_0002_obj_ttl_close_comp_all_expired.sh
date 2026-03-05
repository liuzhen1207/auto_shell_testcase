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
v_warnMessage="No Warn."
v_consensus="IoTConsensus"
CSV_FILE=$(grep ^CSV_FILE "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
fail_flag_total=0
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
        batch_set_sys_conf ".*cn_metric_level=.*" "cn_metric_level=IMPORTANT"
        batch_set_sys_conf ".*cn_metric_prometheus_reporter_port=.*" "cn_metric_prometheus_reporter_port=9081"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=3"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=2"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=1"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=1"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
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
      let fail_flag_total++
      cat ${cur_dir}/tmp.out
   fi
}

function testcase1()
{
#create table
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "create database IF NOT EXISTS db1;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "DROP TABLE IF EXISTS db1.t_object;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "create table db1.t_object(device_id string tag,color string tag,age string tag,department string tag ,file_type string field,file_content object field);">${cur_dir}/tmp.out
check_res success 1 "create object table"
if [[ ${fail_flag} -gt 0 ]];then
return 1
fi

# 生成IoTDB格式的100条插入SQL，file_content使用to_object函数
BASE_TIME=$(date -d '-2 hours' +'%Y-%m-%dT%H:%M:%S.')
TIME_ZONE="+08:00"
SQL_FILE="insert_100_records_to_object.sql"

# 初始化SQL
echo "">${cur_dir}/${SQL_FILE}
echo "INSERT INTO db1.t_object(time, device_id, color, age, department, file_type, file_content) VALUES" >> ${cur_dir}/${SQL_FILE}

# 字段值列表
DEVICES=("d1" "d2" "d3" "d4" "d5" "d6" "d7" "d8" "d9" "d10")
COLORS=("red" "blue" "green" "yellow" "black" "white" "purple" "orange" "pink" "gray")
AGES=("18" "19" "20" "21" "22" "23" "24" "25" "26" "27" "28" "29" "30")
DEPARTMENTS=("dev" "test" "product" "ops")
FILE_TYPES=("image" "movie" "json" "txt")
CONTENTS=("5f8a7b9c4d2e8f1a" "7e9b8c0d3f4a5b6c" "8a7b6c5d4e3f2a1b" "9b8c7d6e5f4a3b2c" "0c9d8e7f6a5b4c3d"
          "1d0e9f8a7b6c5d4e" "2e1f0a9b8c7d6e5f" "3f2a1b0c9d8e7f6a" "4a3b2c1d0e9f8a7b" "5b4c3d2e1f0a9b8c")

# 生成100条记录
for i in $(seq 0 99); do
    MICROSEC=$(printf "%06d" ${i})
    TIMESTAMP="${BASE_TIME}${MICROSEC}${TIME_ZONE}"
    DEVICE=${DEVICES[$((i % 10))]}
    COLOR=${COLORS[$((i % 10))]}
    AGE=${AGES[$((i % 13))]}
    DEPT=${DEPARTMENTS[$((i % 4))]}
    FILE_TYPE=${FILE_TYPES[$((i % 4))]}
    CONTENT=${CONTENTS[$((i % 10))]}
    
    # 拼接to_object格式
    if [ ${i} -eq 99 ]; then
        echo "('${TIMESTAMP}', '${DEVICE}', '${COLOR}', '${AGE}', '${DEPT}', '${FILE_TYPE}', to_object(true,0,X'${CONTENT}'));" >> ${SQL_FILE}
    else
        echo "('${TIMESTAMP}', '${DEVICE}', '${COLOR}', '${AGE}', '${DEPT}', '${FILE_TYPE}', to_object(true,0,X'${CONTENT}'))," >> ${SQL_FILE}
    fi
done

# 执行SQL
echo "生成完成：${SQL_FILE}"
v_sql_ins_100=`cat ${cur_dir}/${SQL_FILE}`
echo "${v_sql_ins_100}"
#${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e <${cur_dir}/${SQL_FILE}
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "${v_sql_ins_100}"
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
exp_obj_num=$((dr_rep_num*100))
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
# testcase2 drop table repeate testcase1
function testcase2()
{
   testcase1
   testcase1
}
# start cluster 
start_db
v_start_test_time=`date +%s`
testcase1
testcase2
v_end_test_time=`date +%s`
v_elp_time=$((v_end_test_time-v_start_test_time))
fail_flag=$((fail_flag_total+fail_flag))
# record test result
function write_result()
{
        test_time=$(date +"%Y-%m-%dT%H:%M:%S.%3N%:z")
   # 写入表头
   v_exist_flag=`grep Time,testTimechoDB $CSV_FILE|wc -l`
   if [[ ${v_exist_flag} -gt 0 ]];then
           echo "head is exist."
   else
   echo "Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage,maxBMTestTimeSec,sumBMTestTimeSec" > "$CSV_FILE"
   fi
   if [[ ${fail_flag} -gt 0 ]];then
#           echo "${test_time},'${testdb}','${v_consensus}','${SCRIPT_NAME}','FAIL',${v_elp_time},${v_warnNum},'${v_warnMessage}',${v_bm_max_value},${v_bm_sum_value}">>"$CSV_FILE"
           echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},FAIL,${v_elp_time},${v_warnNum},${v_warnMessage},null,null">>"$CSV_FILE"

           echo "testcase1 fail"
   else
           echo "testcase1 pass"
#           echo "${test_time},'${testdb}','${v_consensus}','${SCRIPT_NAME}','PASS',${v_elp_time},${v_warnNum},'${v_warnMessage}',${v_bm_max_value},${v_bm_sum_value}">>"$CSV_FILE"
           echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},PASS,${v_elp_time},${v_warnNum},${v_warnMessage},null,null">>"$CSV_FILE"

# remove bm logs
#        rm -rf ${bm_log_dir}/${t}_bm.out
   fi

}
write_result
