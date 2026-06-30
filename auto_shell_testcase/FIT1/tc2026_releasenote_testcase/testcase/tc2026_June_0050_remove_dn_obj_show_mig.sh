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
cn_num=1
dn_num=4
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num+dn_num))
db_sys_admin=root
bm_conn_pw=TimechoDB@2021
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensus"
CSV_FILE=$(grep ^CSV_FILE "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')

log_file="${cur_dir}/set_conf_parallel.log"
data1_dir="/data1/iotdb_data/${testdb}/data"
data3_dir="/data3/iotdb_data/${testdb}/data"
ssl_str=""
backup_flag=0
backup_log_flag=0
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
        }

        # 批量执行system.properties配置
        batch_set_sys_conf ".*cn_seed_config_node=.*" "cn_seed_config_node=${seed_cn_ip}"
        batch_set_sys_conf ".*cn_internal_address=.*" "cn_internal_address=${node_ip}"
        batch_set_sys_conf ".*cn_metric_reporter_list=.*" "cn_metric_reporter_list=PROMETHEUS"
        batch_set_sys_conf ".*cn_metric_prometheus_reporter_port=.*" "cn_metric_prometheus_reporter_port=9081"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=600000"

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
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=600000"

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
       let fail_flag++
       exit 1
   fi
}
run_cli_sql() {
  local host=$1
  local dialect=$2
  local sql=$3
  local outfile=$4
  local timeout_sec=${5:-3600}

  if [[ "${dialect}" = "table" ]]; then
    "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" ${ssl_str} -h "${host}" -sql_dialect table -timeout "${timeout_sec}" -e "${sql}" > "${outfile}" 2>&1
  else
    "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" ${ssl_str} -h "${host}" -timeout "${timeout_sec}" -e "${sql}" > "${outfile}" 2>&1
  fi
}

create_benchmark_users() {
  run_cli_sql "${query_ip}" table "CREATE DATABASE usr_sod0 WITH (ttl=10800000);" "${cur_dir}/create_database.out" 300
  run_cli_sql "${query_ip}" tree "CREATE USER santos '${bm_conn_pw}';" "${cur_dir}/create_santos.out" 300
  run_cli_sql "${query_ip}" tree "GRANT READ_SCHEMA,WRITE_SCHEMA,READ_DATA,WRITE_DATA ON root.test.** TO USER santos;" "${cur_dir}/grant_santos_tree.out" 300
  run_cli_sql "${query_ip}" table "GRANT ALL TO USER santos;" "${cur_dir}/grant_santos.out" 300
  run_cli_sql "${query_ip}" tree "CREATE USER rainer '${bm_conn_pw}';" "${cur_dir}/create_rainer.out" 300
  run_cli_sql "${query_ip}" tree "GRANT READ_SCHEMA,WRITE_SCHEMA,READ_DATA,WRITE_DATA ON root.test.** TO USER rainer;" "${cur_dir}/grant_rainer_tree.out" 300
  run_cli_sql "${query_ip}" table "GRANT ALL TO USER rainer;" "${cur_dir}/grant_rainer.out" 300
}

function start_bm()
{
create_benchmark_users

bm_dir=${cur_dir}/../benchmark/bm_20260519_writeview_v20
bm_conf=weather_6h_diff
#get root password
#test time 15h
v_bm_test_time=54000000
#v_bm_test_time=36000000
v_20_pass=`grep ^passwd_param= ${db_dir}/sbin/start-cli.sh |grep TimechoDB|wc -l`
if [[ ${v_20_pass} -gt 0 ]];then
        bm_root_pw="TimechoDB@2021"
else

        bm_root_pw="root"
fi
# set current time
 start_time_str=$(date +"%Y-%m-%dT%H:%M:%S%:z")
sed -i 's/CREATE_SCHEMA=.*/CREATE_SCHEMA=true/g' ${bm_dir}/${bm_conf}/conf*/config.*
sed -i "s/START_TIME=.*/START_TIME=${start_time_str}/g" ${bm_dir}/${bm_conf}/conf*/config.*
sed -i "s/^PASSWORD=.*/PASSWORD=${bm_root_pw}/g" ${bm_dir}/${bm_conf}/conf*/config.properties
sed -i "s/^TEST_MAX_TIME=.*/TEST_MAX_TIME=${v_bm_test_time}/g" ${bm_dir}/${bm_conf}/conf*/config.properties
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
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf_tree >> ${bm_log_dir}/${t}_bm_tree.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf_tab1 >> ${bm_log_dir}/${t}_bm_table.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf_tab2 >> ${bm_log_dir}/${t}_bm_writable_view.out &
}
function remove_datanode()
{
	# check benchmark
	v_bm=`jps|grep App|wc -l`
	if [[ ${v_bm} = 0 ]];then
		return 0
	fi
        rm_dn_ip=$1
	echo "remove datanode ${rm_dn_ip} at `date "+%Y-%m-%d %H:%M:%S"`"
	query_ip2=`tail -1 ${nodeinfo_dir}/datanode.txt`
        v_rm_datanode_id=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "show datanodes;"|grep ${rm_dn_ip}|awk -F '|' '{gsub(" ","");print $2}'`
        if [[ ${rm_dn_ip} = ${query_ip} ]];then
           ${cli_dir}/sbin/start-cli.sh -h ${query_ip2} -sql_dialect table -e "set configuration region_migration_concurrency_limit='10';">${cur_dir}/tmp.out
	   v_exp_suc=$(grep successfully ${cur_dir}/tmp.out|wc -l)
	   if [[ ${v_exp_suc} -gt 0 ]];then
		   echo "set configuration region_migration_concurrency_limit='10' successfully"
	   else
              let fail_flag++
              v_warnMessage="${v_warnMessage}.set configuration region_migration_concurrency_limit='10' failed"
	      cat ${cur_dir}/tmp.out
	   fi
           ${cli_dir}/sbin/start-cli.sh -h ${query_ip2} -e "remove datanode ${v_rm_datanode_id};"
        else
           ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "remove datanode ${v_rm_datanode_id};"
        fi
        rm_t1=`date +%s`
        while true
        do
                v_rm_suc=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "show datanodes;"|grep ${rm_dn_ip}|wc -l`
                if [[ ${v_rm_suc} -gt 0 ]];then
	                # show migrations exp Empty set
                        ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 3600 -e "show migrations;" > ${cur_dir}/tmp.out
                        cat ${cur_dir}/tmp.out
                        v_tab_mig_num=$(cat ${cur_dir}/tmp.out|egrep "SchemaRegion|DataRegion"|wc -l)
                        v_tab_emp_num=$(cat ${cur_dir}/tmp.out|grep "Empty set"|wc -l)
                        ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 3600 -e "show migrations;" > ${cur_dir}/tmp.out
                        cat ${cur_dir}/tmp.out
                        v_tree_mig_num=$(cat ${cur_dir}/tmp.out|egrep "SchemaRegion|DataRegion"|wc -l)
                        v_tree_emp_num=$(cat ${cur_dir}/tmp.out|grep "Empty set"|wc -l)
                        v_emp_num=$((v_tree_mig_num+v_tree_emp_num))
                        v_mig_num=$((v_tab_mig_num+v_tree_mig_num))
                        if [[ ${v_mig_num} = 0 ]] && [[ ${v_emp_num} -ge 2 ]];then
                                let fail_flag++
                                v_warnMessage="${v_warnMessage}.removing dn,but show migrations is not expeced."
				${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "show datanodes;"
                        fi

                        sleep 300 
                else
			# show migrations exp Empty set
                        ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 3600 -e "show migrations;" > ${cur_dir}/tmp.out
			cat ${cur_dir}/tmp.out
			v_tab_mig_num=$(cat ${cur_dir}/tmp.out|egrep "SchemaRegion|DataRegion"|wc -l)
			v_tab_emp_num=$(cat ${cur_dir}/tmp.out|grep "Empty set"|wc -l)
                        ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 3600 -e "show migrations;" > ${cur_dir}/tmp.out
                        cat ${cur_dir}/tmp.out
                        v_tree_mig_num=$(cat ${cur_dir}/tmp.out|egrep "SchemaRegion|DataRegion"|wc -l)
			v_tree_emp_num=$(cat ${cur_dir}/tmp.out|grep "Empty set"|wc -l)
			v_emp_num=$((v_tree_mig_num+v_tree_emp_num))
			v_mig_num=$((v_tab_mig_num+v_tree_mig_num))
			if [[ ${v_mig_num} -gt 0 ]] && [[ ${v_emp_num} -lt 2 ]];then
				let fail_flag++
				v_warnMessage="${v_warnMessage}.remove dn success,but show migrations is not expeced."
			fi

                        break 
                fi
        done
        while true
        do
                v_rm_dn_pid=`ssh ${os_user_name}@${rm_dn_ip} "sudo jps|grep -i datanode|wc -l"`
                if [[ ${v_rm_dn_pid} -gt 0 ]];then
                        sleep 60
                else
                        break
                fi
        done        
        rm_t2=`date +%s`
        rm_elp=$((rm_t2-rm_t1))
        echo "remove datanode ${rm_dn_ip} cost ${rm_elp} - 5 sec."
        # rm -rf its data
#        ssh ${u_name}@${rm_dn_ip} "sudo mv ${db_dir}/data/datanode ${db_dir}/data/datanode_${rm_t2}"

#        if [ -n "$data1_dir" ]; then
#           ssh ${u_name}@${rm_dn_ip} "sudo mv ${data1_dir}/data/datanode ${data1_dir}/data/datanode_${rm_t2}"
#        fi
#        if [ -n "$data3_dir" ]; then
#           ssh ${u_name}@${rm_dn_ip} "sudo mv ${data3_dir}/data_datanode ${data3_dir}/data/datanode_${rm_t2}"
#           ssh ${u_name}@${rm_dn_ip} "sudo mv ${data3_dir}/data/datanode ${data3_dir}/data/datanode_${rm_t2}"
#        fi
# start removed datanode
        v_start_time=`date "+%Y_%m_%d_%H_%M_%S"`
        ssh ${os_user_name}@${rm_dn_ip} "sudo ${db_dir}/sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}.hprof > /dev/null 2>&1 &"
        while true
        do
                v_start_suc=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "show datanodes;"|grep ${rm_dn_ip}|grep -i running|wc -l`
                if [[ ${v_start_suc} -gt 0 ]];then
                       break 
                else
                       sleep 30 
                fi
        done
        if [[ ${rm_dn_ip} = ${query_ip} ]];then
                check_show_regions_abnormal_metrics "${query_ip2}" "show_regions_after_remove_${rm_dn_ip}"
        else
                check_show_regions_abnormal_metrics "${query_ip}" "show_regions_after_remove_${rm_dn_ip}"
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
function check_show_regions_abnormal_metrics()
{
local check_host=$1
local check_tag=$2
local safe_tag=""
local output_file=""
local abnormal_file=""

   safe_tag=`echo "${check_tag}" | sed 's/[^0-9A-Za-z._-]/_/g'`
   output_file="${cur_dir}/${safe_tag}.out"
   abnormal_file="${cur_dir}/${safe_tag}_abnormal.out"

   ${cli_dir}/sbin/start-cli.sh -h ${check_host} -sql_dialect table -timeout 3600 -e "show regions;" > "${output_file}" 2>&1
   cat "${output_file}"

   v_regions_exception_num=`grep -E "Exception|Error:" "${output_file}"|wc -l`
   if [[ ${v_regions_exception_num} -gt 0 ]];then
      let fail_flag++
      v_warnMessage="${v_warnMessage}.show regions execute failed on ${check_host}."
      return 1
   fi

   awk -F '|' '
   function trim(str) {
      gsub(/^[ \t]+|[ \t]+$/, "", str)
      return str
   }
   /^\+/ {next}
   /^Total line number/ {next}
   /^It costs/ {next}
   /RegionId/ {next}
   NF < 15 {next}
   {
      region_type=trim($3)
      ts_file_size=trim($14)
      compression_ratio=trim($15)
      if (region_type == "DataRegion" && (ts_file_size ~ /^-/ || compression_ratio ~ /^-/)) {
         print $0
      }
   }' "${output_file}" > "${abnormal_file}"

   if [[ -s "${abnormal_file}" ]];then
      let fail_flag++
      v_warnMessage="${v_warnMessage}.show regions has negative DataRegion metrics on ${check_host}."
      echo "show regions abnormal rows on ${check_host}:"
      cat "${abnormal_file}"
   fi
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
# kill -9
         ssh ${v_dn_ip}@${v_dn_ip} "sudo kill -9 ${v_dn_pid}."
         break
      fi

done
}

function check_data_consistent()
{
wait_sync_done 180
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">${cur_dir}/tmp.out
   cat ${cur_dir}/tmp.out |grep Running|awk -F "|" '{gsub(" ","");print $4}'>${cur_dir}/tmp1.out
   mv ${cur_dir}/tmp1.out ${cur_dir}/tmp.out
   sql1="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9),count(s_10),count(s_11) from root.test.g_0.** align by device;"
   sql2="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9),count(s_10),count(s_11) from usr_sod0.tab1mb_0 group by device_id order by device_id;"
   sql3="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9),count(s_10),count(s_11) from usr_sod0.writable_view_0 group by device_id order by device_id;"
   sql4="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9),count(s_10),count(s_11) from usr_sod0.writable_view_0_v group by device_id order by device_id;"
   # all online
   while true
   do
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql1}" >${cur_dir}/q_all_online_tree.out
   v_exception_num=`grep Exception ${cur_dir}/q_all_online_tree.out|wc -l`
   if [[ ${v_exception_num} = 0 ]];then
	   break
   else
	   sleep 1
   fi
   done
   while true
   do
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql2}" >${cur_dir}/q_all_online_table2.out
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql3}" >${cur_dir}/q_all_online_table3.out
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql4}" >${cur_dir}/q_all_online_table4.out
   v_exception_num2=`grep Exception ${cur_dir}/q_all_online_table.out|wc -l`
   v_exception_num3=`grep Exception ${cur_dir}/q_all_online_table3.out|wc -l`
   v_exception_num4=`grep Exception ${cur_dir}/q_all_online_table4.out|wc -l`
   v_exception_num=$((v_exception_num2+v_exception_num3+v_exception_num4))
   if [[ ${v_exception_num} = 0 ]];then
           break
   else
           sleep 1
   fi
   done

   # stop dn
   exec 3<${cur_dir}/tmp.out
   while read line<&3
   do
   query_ip=`head -1 ${cur_dir}/tmp.out`
   query_ip2=`tail -1 ${cur_dir}/tmp.out`

      # stop dn
      ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};sudo ./sbin/stop-datanode.sh"
      check_dn_jps ${line} 120
      if [[ ${query_ip} = ${line} ]];then
         query_ip=${query_ip2}
      fi
      v_ip=`echo ${line}|awk -F '.' '{print $4}'`
      while true
      do
      ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql1}" >${cur_dir}/q_stop_ip${v_ip}_tree.out
      v_exception_num=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_tree.out|wc -l`
      if [[ ${v_exception_num} = 0 ]];then
           break
      else
           sleep 1
      fi
      done
      while true
      do

      ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql2}" >${cur_dir}/q_stop_ip${v_ip}_table2.out
      ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql3}" >${cur_dir}/q_stop_ip${v_ip}_table3.out
      ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql4}" >${cur_dir}/q_stop_ip${v_ip}_table4.out
      v_exception_num2=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table2.out|wc -l`
   v_exception_num3=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table3.out|wc -l`
   v_exception_num4=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table4.out|wc -l`
      v_exception_num=$((v_exception_num2+v_exception_num3+v_exception_num4))
      v_exception_num=`grep Exception ${cur_dir}/q_stop_ip${v_ip}_table.out|wc -l`
      if [[ ${v_exception_num} = 0 ]];then
           break
      else
           sleep 1
      fi
      done

      v_diff_tree=`diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_stop_ip${v_ip}_tree.out|grep "root"|wc -l`
      v_diff_table2=`diff ${cur_dir}/q_all_online_table2.out ${cur_dir}/q_stop_ip${v_ip}_table2.out|grep "d_"|wc -l`
      v_diff_table3=`diff ${cur_dir}/q_all_online_table3.out ${cur_dir}/q_stop_ip${v_ip}_table3.out|grep "d_"|wc -l`
      v_diff_table4=`diff ${cur_dir}/q_all_online_table4.out ${cur_dir}/q_stop_ip${v_ip}_table4.out|grep "d_"|wc -l`
      v_diff_total=$((v_diff_tree+v_diff_table2+v_diff_table3+v_diff_table4))
      if [[ ${v_diff_total} -gt 0 ]];then
#         let fail_flag++
	 let backup_flag++
	 diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_stop_ip${v_ip}_tree.out
	 diff ${cur_dir}/q_all_online_table2.out ${cur_dir}/q_stop_ip${v_ip}_table2.out
	 diff ${cur_dir}/q_all_online_table3.out ${cur_dir}/q_stop_ip${v_ip}_table3.out
	 diff ${cur_dir}/q_all_online_table4.out ${cur_dir}/q_stop_ip${v_ip}_table4.out
	 v_warnMessage="${v_warnMessage}.data inconsistent"
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
exec 3<${nodeinfo_dir}/confignode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*confignode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${db_dir}/logs/*confignode*all*|wc -l"`
   if [[ ${v_npe} -gt 0 ]];then
	   let fail_flag++
	   let backup_log_flag++
	   v_warnMessage="${v_warnMessage}CN NPE ${v_npe}."
	   echo "CN ${line} NullPointer : ${v_npe}"
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
   v_err4=`ssh ${os_user_name}@${line} "grep \"Failed to statistic the size of\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err17=`ssh ${os_user_name}@${line} "grep \"DataTypeInconsistentException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err5=`ssh ${os_user_name}@${line} "grep \"ArrayIndexOutOfBoundsException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err6=`ssh ${os_user_name}@${line} "grep \"Alter timeseries .* data type from null to\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err7=`ssh ${os_user_name}@${line} "grep \"StatisticsClassException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err8=`ssh ${os_user_name}@${line} "grep \"BufferUnderflowException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err9=`ssh ${os_user_name}@${line} "grep \"NegativeArraySizeException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err10=`ssh ${os_user_name}@${line} "grep \"is not in tsFileMetaData\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err11=`ssh ${os_user_name}@${line} "grep \"The memory cost to be released is larger\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err12=`ssh ${os_user_name}@${line} "grep \"tsfile error\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err13=`ssh ${os_user_name}@${line} "grep \"which has not released all memory\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err14=`ssh ${os_user_name}@${line} "grep \"Error while reading timeseries metadata\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err15=`ssh ${os_user_name}@${line} "grep \"OBJECT statistics does not support: last\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err16=`ssh ${os_user_name}@${line} "grep \"which has not released all memory\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err18=`ssh ${os_user_name}@${line} "grep INTERNAL_SERVER_ERROR ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err19=$(ssh "${os_user_name}@${line}" "grep \"Cannot create link from\" ${db_dir}/logs/*datanode*all*|wc -l")
   v_dn_total_err=$((v_err+v_err2+v_err3+v_err4+v_err5+v_err6+v_err7+v_err8+v_err9+v_err10+v_err11+v_err12+v_err13+v_err14+v_err15+v_err16+v_err17+v_err18+v_err19))

   if [[ ${v_npe} -gt 0 ]];then
           let fail_flag++
           let backup_log_flag++
           v_warnMessage="${v_warnMessage}DN NPE ${v_npe}."
           echo "DN ${line} NullPointer : ${v_npe}"
   fi

   if [[ ${v_dn_total_err} -gt 0 ]];then
           let fail_flag++
	   let backup_log_flag++
	   v_warnMessage="${v_warnMessage}DN unexpected log ${v_dn_total_err}."
           echo "DN ${line} unexpected log: ${v_dn_total_err}"
   fi

done


}

# testcase1
function exec_remove_datanode()
{
	# loop remove
tac ${nodeinfo_dir}/datanode.txt >${cur_dir}/remove_datanode.txt 
while true
do
        sleep 1h
	exec 3<${cur_dir}/remove_datanode.txt
	while read line<&3
	do
	remove_datanode ${line} 
	sleep 10m
	#check oom
        ssh "${os_user_name}@${line}" "ls ${db_dir}/*.hprof >/dev/null 2>&1"
	if [ $? -eq 0 ]; then
	    ((fail_flag++))
	    v_warnMessage="${v_warnMessage}DN OOM."
	    echo "检测到${line}的${db_dir}下有.hprof文件，fail_flag已更新为：${fail_flag}"
	fi
        # check benchmark
        v_bm=`jps|grep App|wc -l`
        if [[ ${v_bm} = 0 ]];then
               break 
        fi

        done
        # check benchmark
        v_bm=`jps|grep App|wc -l`
        if [[ ${v_bm} = 0 ]];then
               break 
        fi

done
}
function testcase1()
{
# check data
check_data_consistent
sleep 2h
check_data_consistent
sleep 1h
#check log
check_log
if [[ ${backup_flag} -gt 0 ]];then
	v_backup_time=`date +%s`
	sh -x ${clean_env_dir}/stop_cluster.sh 2>&1
    sh -x ${clean_env_dir}/backup_cluster_logs_data.sh ${v_backup_time} 2>&1
fi
if [[ ${backup_log_flag} -gt 0 ]];then
	v_backup_time=`date +%s`
	sh -x ${clean_env_dir}/stop_cluster.sh 2>&1
    sh -x ${clean_env_dir}/backup_cluster_logs.sh ${v_backup_time} 2>&1
fi
}
# start cluster 
echo "">${log_file}
start_db
v_start_test_time=`date +%s`
start_bm
exec_remove_datanode
testcase1
v_end_test_time=`date +%s`
v_elp_time=$((v_end_test_time-v_start_test_time))
# record test result
function write_result()
{
        test_time=$(date +"%Y-%m-%dT%H:%M:%S.%3N%:z")
	v_bm_sum_value=`grep "Test elapsed" ${bm_log_dir}/${t}_bm*out| awk '{print $8}' | sort -n | awk '{sum+=$1} END {print sum}'`
	v_bm_max_value=`grep "Test elapsed" ${bm_log_dir}/${t}_bm*out|awk '{print $8}'|sort -n|tail -1`
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

# remove bm logs
#        rm -rf ${bm_log_dir}/${t}_bm.out
   fi

}
write_result
