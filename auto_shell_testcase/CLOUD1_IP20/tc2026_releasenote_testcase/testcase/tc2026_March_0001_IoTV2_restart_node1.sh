#!/bin/bash
#【TIMECHODB-0328】https://timechor.feishu.cn/docx/Sdpodv1u0o7YHlxmTn0cu1PZndz
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
shell_client_db_parent_dir=$(grep "^v_shell_client_db_parent_dir=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
cli_dir=${shell_client_db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
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
v_warnMessage="No Warn."
v_consensus="IoTConsensusV2"
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
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="4G"/g' ${db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="2G"/g' ${db_dir}/conf/confignode-env.sh
        
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
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=5"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
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
function start_bm()
{
bm_dir=${cur_dir}/../benchmark/bm_20251017_b6be9bd_ssl
bm_conf=tree_temp_view
ts_num=1000000
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
# create user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "CREATE USER test1_user 'TimechoDB@2021';grant all ON root.** TO USER test1_user;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "CREATE USER test2_user 'TimechoDB@2021';grant all ON root.** TO USER test2_user;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "CREATE USER view_user 'TimechoDB@2021';grant all TO USER view_user;"

bm_test_time=`date +%Y_%m_%d_%H_%M_%S`
${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf1_root_pre > ${bm_log_dir}/${bm_test_time}_pre_bm1.out
${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf2_root_pre > ${bm_log_dir}/${bm_test_time}_pre_bm2.out
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf1 > ${bm_log_dir}/${bm_test_time}_tree_bm1.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf2 > ${bm_log_dir}/${bm_test_time}_tree_bm2.out &
while true
do
        v_ts_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "count timeseries root.**;"|grep "| "|awk -F '|' '{gsub(" ","");print $2}'`
        if [[ ${v_ts_num} -ge ${ts_num} ]];then
                break
        else
                sleep 10
        fi
done
# create view
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "create database test_g_0;use test_g_0;create view v1_0 (device_id STRING TAG) as root.test1.g_0.**;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "use test_g_0;create view v2_0 (device_id STRING TAG) as root.test2.g_0.**;"

# start bm table view
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/view1 > ${bm_log_dir}/${bm_test_time}_view_bm1.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/view2 > ${bm_log_dir}/${bm_test_time}_view_bm2.out &

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
   ssh ${os_user_name}@${line} "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep root.test">${cur_dir}/tmp1.out
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

function check_data_consistent()
{
wait_sync_done 180
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "use db_g_0 ;create or replace view table_0(device_id string tag) as root.test.g_0.**;"
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">${cur_dir}/tmp.out
   cat ${cur_dir}/tmp.out |grep Running|awk -F "|" '{gsub(" ","");print $4}'>${cur_dir}/tmp1.out
   mv ${cur_dir}/tmp1.out ${cur_dir}/tmp.out
   sql1="select count(s_0),count(s_1000),count(s_2000),count(s_3000),count(s_4000),count(s_5000),count(s_6000),count(s_7000),count(s_8000),count(s_9999) from root.test1.g_0.** align by device;"
   sql2="select count(s_0),count(s_1000),count(s_2000),count(s_3000),count(s_4000),count(s_5000),count(s_6000),count(s_7000),count(s_8000),count(s_9999) from root.test2.g_0.** align by device;"
   exception_num=0
   # all online
   while true
   do
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql1}" >${cur_dir}/q_all_online_tree.out
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
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql2}" >${cur_dir}/q_all_online_table.out
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
   exception_num=0
      while true
      do

      ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql2}" >${cur_dir}/q_stop_ip${v_ip}_table.out
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
      v_diff_table=`diff ${cur_dir}/q_all_online_table.out ${cur_dir}/q_stop_ip${v_ip}_table.out|grep "root"|wc -l`
      v_diff_total=$((v_diff_tree+v_diff_table))
      if [[ ${v_diff_total} -gt 0 ]];then
         let fail_flag++
         v_warnMessage="data inconsistent."
         diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_stop_ip${v_ip}_tree.out
         diff ${cur_dir}/q_all_online_table.out ${cur_dir}/q_stop_ip${v_ip}_table.out
         echo "diff : ${v_diff_total}"
      fi
      # restart
      v_start_time=`date +%s`
      ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};./sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
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
   ssh ${os_user_name}@${line} "gunzip ${db_dir}/logs/*confignode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err1=`ssh ${os_user_name}@${line} "grep BufferUnderflowException ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err2=`ssh ${os_user_name}@${line} "grep \"but return HAS_MORE_STATE\" ${db_dir}/logs/*confignode*all*|wc -l"`
   if [[ ${v_npe} -gt 0 ]];then
	   let fail_flag++
	   let backup_log_flag++
	   echo "CN ${line} NullPointer : ${v_npe}"
   fi
   v_cn_err_total=$((v_cn_err1+v_cn_err2))
   if [[ ${v_cn_err_total} -gt 0 ]];then
           let fail_flag++
           let backup_log_flag++
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
           echo "DN ${line} NullPointer : ${v_npe}"
   fi
   if [[ ${v_dn_total_err} -gt 0 ]];then
	   let fail_flag++
	    let backup_flag++
	   echo "DN ${line} has error: ${v_dn_total_err}"
   fi

done


}

# 生成类型映射文件（只执行一次，移到函数外）
generate_type_files() {
    echo "[$(date +%F_%T)] 生成类型映射文件..." | tee -a ${log_file}
    # 生成 INT32.txt
    echo -e "INT64\nFLOAT\nDOUBLE\nTIMESTAMP\nSTRING\nTEXT" > ${cur_dir}/INT32.txt
    # 生成 INT64.txt
    echo -e "TIMESTAMP\nDOUBLE\nSTRING\nTEXT" > ${cur_dir}/INT64.txt
    # 生成 FLOAT.txt
    echo -e "DOUBLE\nSTRING\nTEXT" > ${cur_dir}/FLOAT.txt
    # 生成 DOUBLE.txt
    echo -e "STRING\nTEXT" > ${cur_dir}/DOUBLE.txt
    # 生成 BOOLEAN.txt
    echo -e "STRING\nTEXT" > ${cur_dir}/BOOLEAN.txt
    # 生成 TEXT.txt
    echo -e "BLOB\nSTRING" > ${cur_dir}/TEXT.txt
    # 生成 STRING.txt
    echo -e "TEXT\nBLOB" > ${cur_dir}/STRING.txt
    # 生成 BLOB.txt
    echo -e "STRING\nTEXT" > ${cur_dir}/BLOB.txt
    # 生成 DATE.txt
    echo -e "STRING\nTEXT" > ${cur_dir}/DATE.txt
    # 生成 TIMESTAMP.txt
    echo -e "INT64\nDOUBLE\nSTRING\nTEXT" > ${cur_dir}/TIMESTAMP.txt
}

# 单个timeseries类型修改函数（无文件描述符共享）
exec_alter_type() {
    local v_ts_name_orig=$1
    local v_ts_type_orig=$2
    local type_file="${cur_dir}/${v_ts_type_orig}.txt"

    # 检查类型文件是否存在
    if [ ! -f ${type_file} ]; then
        echo "[$(date +%F_%T)] ERROR: 类型文件${type_file}不存在，跳过${v_ts_name_orig}" | tee -a ${log_file}
        return 1
    fi

    # 逐行读取目标类型（使用本地文件描述符，避免冲突）
    while read -r v_dest_type; do
        # 跳过空行
        [ -z "${v_dest_type}" ] && continue

        echo "[$(date +%F_%T)] 开始修改: ${v_ts_name_orig} -> ${v_dest_type}" | tee -a ${log_file}
        # 执行alter命令，捕获输出和退出码
        alter_cmd="${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -timeout 3600 -e \"alter timeseries ${v_ts_name_orig} set data type ${v_dest_type};\""
        ${alter_cmd} >> ${log_file} 2>&1
        local exit_code=$?

        if [ ${exit_code} -eq 0 ]; then
            echo "[$(date +%F_%T)] SUCCESS: ${v_ts_name_orig} 修改为${v_dest_type}成功" | tee -a ${log_file}
        else
            echo "[$(date +%F_%T)] FAIL: ${v_ts_name_orig} 修改为${v_dest_type}失败（退出码：${exit_code}）" | tee -a ${log_file}
        fi
    done < ${type_file}  # 直接重定向文件，不用exec，避免文件描述符冲突
}

# 主函数：批量修改timeseries类型（限制并发）
alter_timeseries_type() {
    # 1. 生成类型映射文件
    generate_type_files

    # 2. 获取timeseries列表
    echo "[$(date +%F_%T)] 获取timeseries列表..." | tee -a ${log_file}
    show_cmd="${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -timeout 3600 -e \"show timeseries root.test.**;\""
    ${show_cmd} | grep "root.test" > ${cur_dir}/show_ts.txt 2>&1

    if [ ! -s ${cur_dir}/show_ts.txt ]; then
        echo "[$(date +%F_%T)] ERROR: 获取timeseries列表失败或为空" | tee -a ${log_file}
        exit 1
    fi

    # 3. 逐行处理，限制并发
    echo "[$(date +%F_%T)] 开始批量修改（最大并发：${max_concurrent}）..." | tee -a ${log_file}
    while read -r ts_line; do
        # 跳过空行
        [ -z "${ts_line}" ] && continue

        # 解析timeseries名称和原始类型
        v_ts_name=$(echo ${ts_line} | awk -F '|' '{gsub(/ /,""); print $2}')  # 去除空格
        v_ts_orig_type=$(echo ${ts_line} | awk -F '|' '{gsub(/ /,""); print $5}')  # 去除空格

        # 跳过解析失败的行
        if [ -z "${v_ts_name}" ] || [ -z "${v_ts_orig_type}" ]; then
            echo "[$(date +%F_%T)] WARN: 解析行失败：${ts_line}" | tee -a ${log_file}
            continue
        fi

        # 限制并发：等待当前并发数低于max_concurrent
        while [ $(jobs -p | wc -l) -ge ${max_concurrent} ]; do
            sleep 1
        done

        # 后台执行，但不共享文件描述符
        exec_alter_type "${v_ts_name}" "${v_ts_orig_type}" &
    done < ${cur_dir}/show_ts.txt

    # 等待所有后台进程执行完毕
    wait
    echo "[$(date +%F_%T)] 所有timeseries类型修改任务执行完毕，日志文件：${log_file}" | tee -a ${log_file}
}

function restart_node1()
{
sleep 600 
readonly_ip=`head -1 ${nodeinfo_dir}/datanode.txt`
while true
do
ssh ${os_user_name}@${readonly_ip} "${db_dir}/sbin/stop-datanode.sh"
while true
do
        v_jps=`ssh ${os_user_name}@${readonly_ip} "jps|grep DataNode|wc -l"`
        if [[ ${v_jps} = 0 ]];then
           break
        else
           sleep 10
        fi
done
sleep 60
restart_time=`date +%Y_%m_%d_%H_%M_%S`
ssh ${os_user_name}@${readonly_ip} "source /etc/profile;${db_dir}/sbin/start-datanode.sh -H ${db_dir}/${restart_time}_heapdump.hprof > /dev/null 2>&1 &"
sleep 10
while true
do
   v_ok=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "show cluster;"|grep "${readonly_ip}|"|grep -i Running|wc -l`
   if [[ ${v_ok} = 1 ]];then
      break
   else
      sleep 10
   fi
done
sleep 180
#check client connections
check_client_connections
v_bm=`jps|grep App|wc -l`
if [[ ${v_bm} = 0 ]];then
   break
   return 0 # This command won’t be executed.
fi
done

}
# ====================== 核心函数 ======================
# 函数：查询单个节点的进程线程数
check_client_connections() {
# Prometheus服务器信息
PROMETHEUS_URL=$(grep ^monitor_url "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
PROMETHEUS_USER=admin
PROMETHEUS_PASS=admin

# 调用Prometheus API获取当前值（只获取DataNode的ClientRPC连接）
response=$(curl -s -u "$PROMETHEUS_USER:$PROMETHEUS_PASS" "$PROMETHEUS_URL/api/v1/query?query=thrift_connections%7Bcluster%3D%22$CLUSTER_ID%22%2Cname%3D%22ClientRPC%22%2CnodeType%3D%22DATANODE%22%7D")

# 检查响应是否成功
if [[ $(echo "$response" | jq -r '.status') != "success" ]]; then
  echo "Error: Failed to get data from Prometheus"
  echo "Response: $response"
  exit 1
fi

# 解析JSON并提取数据
echo "===== DataNode Client Connections (Cluster: $CLUSTER_ID) ====="

# 获取结果数量
result_count=$(echo "$response" | jq -r '.data.result | length')

# 遍历每个结果
for ((i=0; i<result_count; i++)); do
  instance=$(echo "$response" | jq -r ".data.result[$i].metric.instance")
  connections=$(echo "$response" | jq -r ".data.result[$i].value[1]")
  echo "Instance: $instance, Connections: $connections"

  # 判断连接数是否大于50
  if [[ $connections -gt 50 ]]; then
    fail_flag=$((fail_flag + 1))
    echo "  WARNING: Connections exceed 50!"
  fi
done

# 统计总连接数
total_connections=$(echo "$response" | jq -r '.data.result[] | .value[1]' | awk '{sum+=$1} END {print sum}')
echo "Total Client Connections: $total_connections"
echo "Fail Flag: $fail_flag"

}

function testcase1()
{
# check data
check_data_consistent
#check log
check_log
if [[ ${backup_flag} -gt 0 ]];then
	v_backup_time=`date +%s`
    sh ${clean_env_dir}/backup_cluster_logs_data.sh ${v_backup_time} 
fi
if [[ ${backup_log_flag} -gt 0 ]];then
	v_backup_time=`date +%s`
    sh ${clean_env_dir}/backup_cluster_logs.sh ${v_backup_time} 
fi
}
# start cluster 
echo "">${log_file}
start_db
# start test time
v_start_test_time=`date +%s`
start_bm
#alter_timeseries_type
restart_node1 # loop restart node1
testcase1
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
        rm -rf ${bm_log_dir}/${bm_test_time}_pre_bm1.out
        rm -rf ${bm_log_dir}/${bm_test_time}_pre_bm2.out
        rm -rf ${bm_log_dir}/${bm_test_time}_tree_bm1.out
        rm -rf ${bm_log_dir}/${bm_test_time}_tree_bm2.out
        rm -rf ${bm_log_dir}/${bm_test_time}_view_bm1.out
        rm -rf ${bm_log_dir}/${bm_test_time}_view_bm2.out
   fi

}
write_result
