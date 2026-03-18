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
dn_num=5
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num+dn_num))
log_file="${cur_dir}/set_conf_parallel.log"
ssl_str=""
backup_flag=0
backup_log_flag=0
max_concurrent=5
# 清理旧节点文件，复制新配置
rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

# 读取种子节点IP（兼容低版本）
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
table_name="test_g_0.table_0"       # 目标表名
desc_cmd="${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -sql_dialect table -h ${query_ip} -timeout 3600 -e \"desc ${table_name};\""

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
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="8G"/g' ${db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${db_dir}/conf/confignode-env.sh
 
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
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=10"

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
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=10"

EOF

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

function start_bm()
{
bm_dir=/data/mpp_test/benchmark/bm_20251220_38c839b_v20/
bm_conf=alter_type_10k_sensor
#60h
v_bm_test_time=216000000

#get root password
v_20_pass=`grep ^passwd_param= ${db_dir}/sbin/start-cli.sh |grep TimechoDB|wc -l`
if [[ ${v_20_pass} -gt 0 ]];then
	bm_root_pw="TimechoDB@2021"
else

	bm_root_pw="root"
fi
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

        # start bm
        start_time=`date "+%Y_%m_%d_%H_%M_%S"`
        nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf_tree1 >${bm_dir}/${testdb}/${start_time}_bm1.out &
        nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf_tree2 >${bm_dir}/${testdb}/${start_time}_bm2.out &
        nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf_table >${bm_dir}/${testdb}/${start_time}_bm3.out &

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
   ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*datanode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err=`ssh ${os_user_name}@${line} "grep CompactionTableSchemaNotMatchException ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err2=`ssh ${os_user_name}@${line} "grep \"has overlapped data\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err3=`ssh ${os_user_name}@${line} "grep \"which should be later than the last time\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err4=`ssh ${os_user_name}@${line} "grep \"DataTypeInconsistentException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err5=`ssh ${os_user_name}@${line} "grep \"ArrayIndexOutOfBoundsException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err6=`ssh ${os_user_name}@${line} "grep \"Alter timeseries .* data type from null to\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_dn_total_err=$((v_err+v_err2+v_err3+v_err4+v_err5+v_err6))
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
   ssh ${os_user_name}@${line} "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep test_g_0">${cur_dir}/tmp1.out
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
   v_dn_str=`ssh ${os_user_name}@${v_dn_ip} "sudo jps|grep DataNode"`
   v_dn_pid=`echo ${v_dn_str}|awk '{print $1}'`
   if [[ ${v_dn_pid} -gt 0 ]];then
      sleep 1
   else
      break
   fi
      t2=`date +%s`
      t_elp=$((t2-t1))
      if [[ ${t_elp} -gt ${max_wait_time} ]];then
         let fail_flag++
         echo "Stopping takes too long."
# kill -9
         ssh ${os_user_name}@${v_dn_ip} "sudo kill -9 ${v_dn_pid}."
         break
      fi

done
}

function check_data_consistent()
{
wait_sync_done 300
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">${cur_dir}/tmp.out
   cat ${cur_dir}/tmp.out |grep Running|awk -F "|" '{gsub(" ","");print $4}'>${cur_dir}/tmp1.out
   mv ${cur_dir}/tmp1.out ${cur_dir}/tmp.out
   sql1="select count(s_499) from root.test.g_0.** align by device;"
   sql2="select device_id,count(s_499) from test_g_0.table_0 group by device_id order by device_id;"
   # all online
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql1}" >${cur_dir}/q_all_online_tree.out
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql2}" >${cur_dir}/q_all_online_table.out
   v_exp1=`grep "root.test" ${cur_dir}/q_all_online_tree.out|wc -l`
   v_exp2=`grep "d_" ${cur_dir}/q_all_online_table.out|wc -l`
   if [[ ${v_exp1} != 1000 ]] || [[ ${v_exp2} != 1000 ]];then
   let fail_flag++
   echo "exp != 1000."
   fi
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
      ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect tree -timeout 36000 -e "${sql1}" >${cur_dir}/q_stop_ip${v_ip}_tree.out
      ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -timeout 36000 -e "${sql2}" >${cur_dir}/q_stop_ip${v_ip}_table.out

      v_diff_tree=`diff ${cur_dir}/q_all_online_tree.out ${cur_dir}/q_stop_ip${v_ip}_tree.out|grep "root.test"|wc -l`
      v_diff_table=`diff ${cur_dir}/q_all_online_table.out ${cur_dir}/q_stop_ip${v_ip}_table.out|grep "d_"|wc -l`
      if [[ ${v_diff_tree} -gt 0 ]];then
         let fail_flag++
         echo "tree diff : ${v_diff_tree}"
      fi
      if [[ ${v_diff_table} -gt 0 ]];then
         let fail_flag++
         echo "table diff : ${v_diff_table}"
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
      if [[ ${v_elp_time} -gt 120 ]];then
         let fail_flag++
         echo "restart ${line} failed."
         return
      fi
      done
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

function gen_alter_tree_type_sql()
{
   v_sensor_type=$1
   v_tree_db_name="root.test.g_0"
   v_dev_num=499
   echo "" >"${cur_dir}/tree_${v_sensor_type}_alter_type.sql"
   v_sensor_name_file="${cur_dir}/tree_${v_sensor_type}_sensor_name.txt"
   # 优化IO：用变量暂存内容
sql_content=""
while read -r v_tree_new_type; do
    [[ -z "${v_tree_new_type}" ]] && continue
    while read -r v_sensor_name; do
        [[ -z "${v_sensor_name}" ]] && continue
        for v_tree_dev_idx in $(seq 0 "${v_dev_num}"); do
            sql_content+="alter timeseries ${v_tree_db_name}.d1_${v_tree_dev_idx}.${v_sensor_name} set data type ${v_tree_new_type};\n"
            sql_content+="alter timeseries ${v_tree_db_name}.d2_${v_tree_dev_idx}.${v_sensor_name} set data type ${v_tree_new_type};\n"
        done
    done < "${v_sensor_name_file}"
done < "${cur_dir}/${v_sensor_type}.txt"
# 一次性写入文件
echo -e "${sql_content}" > "${cur_dir}/tree_${v_sensor_type}_alter_type.sql"
}
function exec_gen_tree_alter_type_sql_file()
{
    echo "[$(date +%F_%T)] 获取timeseries列表..." | tee -a ${log_file}
    show_cmd="${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -timeout 3600 -e \"show timeseries root.test.g_0.d1_0.**;\""
    ${show_cmd} | grep "root.test" > ${cur_dir}/show_ts.txt 2>&1

    if [ ! -s ${cur_dir}/show_ts.txt ]; then
        echo "[$(date +%F_%T)] ERROR: 获取timeseries列表失败或为空" | tee -a ${log_file}
        exit 1
    fi
    # gen 10 type sensor_name
    cat ${cur_dir}/show_ts.txt|grep BOOLEAN|awk -F '|' '{gsub(" ","");print $2}'|awk -F '.' '{print $5}' >${cur_dir}/tree_BOOLEAN_sensor_name.txt
    cat ${cur_dir}/show_ts.txt|grep INT32|awk -F '|' '{gsub(" ","");print $2}'|awk -F '.' '{print $5}' >${cur_dir}/tree_INT32_sensor_name.txt
    cat ${cur_dir}/show_ts.txt|grep INT64|awk -F '|' '{gsub(" ","");print $2}'|awk -F '.' '{print $5}' >${cur_dir}/tree_INT64_sensor_name.txt
    cat ${cur_dir}/show_ts.txt|grep FLOAT|awk -F '|' '{gsub(" ","");print $2}'|awk -F '.' '{print $5}' >${cur_dir}/tree_FLOAT_sensor_name.txt
    cat ${cur_dir}/show_ts.txt|grep TEXT|awk -F '|' '{gsub(" ","");print $2}'|awk -F '.' '{print $5}' >${cur_dir}/tree_TEXT_sensor_name.txt
    cat ${cur_dir}/show_ts.txt|grep DOUBLE|awk -F '|' '{gsub(" ","");print $2}'|awk -F '.' '{print $5}' >${cur_dir}/tree_DOUBLE_sensor_name.txt
    cat ${cur_dir}/show_ts.txt|grep STRING|awk -F '|' '{gsub(" ","");print $2}'|awk -F '.' '{print $5}' >${cur_dir}/tree_STRING_sensor_name.txt
    cat ${cur_dir}/show_ts.txt|grep BLOB|awk -F '|' '{gsub(" ","");print $2}'|awk -F '.' '{print $5}' >${cur_dir}/tree_BLOB_sensor_name.txt
    cat ${cur_dir}/show_ts.txt|grep TIMESTAMP|awk -F '|' '{gsub(" ","");print $2}'|awk -F '.' '{print $5}' >${cur_dir}/tree_TIMESTAMP_sensor_name.txt
    cat ${cur_dir}/show_ts.txt|grep DATE|awk -F '|' '{gsub(" ","");print $2}'|awk -F '.' '{print $5}' >${cur_dir}/tree_DATE_sensor_name.txt
    gen_alter_tree_type_sql BOOLEAN
    gen_alter_tree_type_sql INT32
    gen_alter_tree_type_sql INT64
    gen_alter_tree_type_sql FLOAT
    gen_alter_tree_type_sql TEXT
    gen_alter_tree_type_sql DOUBLE
    gen_alter_tree_type_sql STRING
    gen_alter_tree_type_sql BLOB
    gen_alter_tree_type_sql TIMESTAMP
    gen_alter_tree_type_sql DATE

}
alter_timeseries_type() {

   # exec alter timeseries type
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/tree_BOOLEAN_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/tree_INT32_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/tree_INT64_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/tree_FLOAT_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/tree_DOUBLE_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/tree_TEXT_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/tree_STRING_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/tree_BLOB_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/tree_TIMESTAMP_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/tree_DATE_alter_type.sql &
 

}

function gen_alter_table_type_sql()
{
   v_sensor_type=$1
   v_tab_name=$2
   echo "" >"${cur_dir}/table_${v_sensor_type}_alter_type.sql"
   exec 3<${cur_dir}/${v_sensor_type}.txt
   while read line<&3
   do
      sed "s/^/alter table ${v_tab_name} alter column /; s/$/ set data type ${line};/" "${cur_dir}/table_${v_sensor_type}_sensor_name.txt" >> "${cur_dir}/table_${v_sensor_type}_alter_type.sql"
   done
   # 4. 关键：关闭文件描述符3（核心修复点）
exec 3>&-

# 可选：验证文件描述符是否关闭（调试用）
if ! ls -l /proc/$$/fd/3 2>/dev/null; then
    echo "文件描述符3已成功关闭"
fi
}
function exec_gen_table_alter_type_sql_file()
{
    v_table_name="test_g_0.table_0"
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 36000 -e "desc ${v_table_name};" >${cur_dir}/table_desc.txt
    cat ${cur_dir}/table_desc.txt|grep FIELD|grep BOOLEAN|awk -F '|' '{gsub(" ","");print $2}' >${cur_dir}/table_BOOLEAN_sensor_name.txt
    cat ${cur_dir}/table_desc.txt|grep FIELD|grep INT32|awk -F '|' '{gsub(" ","");print $2}' >${cur_dir}/table_INT32_sensor_name.txt
    cat ${cur_dir}/table_desc.txt|grep FIELD|grep INT64|awk -F '|' '{gsub(" ","");print $2}' >${cur_dir}/table_INT64_sensor_name.txt
    cat ${cur_dir}/table_desc.txt|grep FIELD|grep FLOAT|awk -F '|' '{gsub(" ","");print $2}' >${cur_dir}/table_FLOAT_sensor_name.txt
    cat ${cur_dir}/table_desc.txt|grep FIELD|grep TEXT|awk -F '|' '{gsub(" ","");print $2}' >${cur_dir}/table_TEXT_sensor_name.txt
    cat ${cur_dir}/table_desc.txt|grep FIELD|grep DOUBLE|awk -F '|' '{gsub(" ","");print $2}' >${cur_dir}/table_DOUBLE_sensor_name.txt
    cat ${cur_dir}/table_desc.txt|grep FIELD|grep STRING|awk -F '|' '{gsub(" ","");print $2}' >${cur_dir}/table_STRING_sensor_name.txt
    cat ${cur_dir}/table_desc.txt|grep FIELD|grep BLOB|awk -F '|' '{gsub(" ","");print $2}' >${cur_dir}/table_BLOB_sensor_name.txt
    cat ${cur_dir}/table_desc.txt|grep FIELD|grep TIMESTAMP|awk -F '|' '{gsub(" ","");print $2}' >${cur_dir}/table_TIMESTAMP_sensor_name.txt
    cat ${cur_dir}/table_desc.txt|grep FIELD|grep DATE|awk -F '|' '{gsub(" ","");print $2}' >${cur_dir}/table_DATE_sensor_name.txt
    # gen alter type sql
    gen_alter_table_type_sql BOOLEAN ${v_table_name}
    gen_alter_table_type_sql INT32 ${v_table_name}
    gen_alter_table_type_sql INT64 ${v_table_name}
    gen_alter_table_type_sql FLOAT ${v_table_name}
    gen_alter_table_type_sql TEXT ${v_table_name}
    gen_alter_table_type_sql DOUBLE ${v_table_name}
    gen_alter_table_type_sql STRING ${v_table_name}
    gen_alter_table_type_sql BLOB ${v_table_name}
    gen_alter_table_type_sql TIMESTAMP ${v_table_name}
    gen_alter_table_type_sql DATE ${v_table_name}

}
# ====================== 主函数：生成SQL文件+批量执行 ======================
alter_table_field_type() {
    # exec sql
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/table_BOOLEAN_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/table_INT32_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/table_INT64_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/table_FLOAT_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/table_DOUBLE_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/table_TEXT_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/table_STRING_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/table_BLOB_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/table_TIMESTAMP_alter_type.sql &
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 360000 -e<${cur_dir}/alter_type_tree_table_sql/table_DATE_alter_type.sql &
}

function del_devices()
{
        local db_name="test_g_0"
        local tab_name="table_0"
        local max=999
        local del_dev_idx=0
	local v_loop_check_bm=0
        while true
        do
                for del_dev_idx in $(seq 0 $max)
                {
                    local v_max_time=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 36000 -e "use ${db_name};select time from ${tab_name} where device_id='d_${del_dev_idx}' order by time desc limit 1;"|grep "+08:00"|awk -F '|' '{print $2}'`
                    # delete
                    if [[ "${v_max_time}" != "" ]];then
                       ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 36000 -e "use ${db_name};delete devices from ${tab_name} where device_id='d_${del_dev_idx}'"
                    fi
		    let v_loop_check_bm++
		    if [[ ${v_loop_check_bm} -ge 100 ]];then
			    v_bm_num=`jps|grep App|wc -l`
			    if [[ ${v_bm_num} = 0 ]];then
				    break
			    fi
			    v_loop_check_bm=0
		    fi
                }
                v_bm_num=`jps|grep App|wc -l`
	       if [[ ${v_bm_num} = 0 ]];then
		       break
	       fi	       
        done
}
function del_table_data()
{
        local db_name="test_g_0"
        local tab_name="table_0"
        local max=999
        local i=0
	local v_loop_check_bm=0
        while true
        do
                for i in $(seq 0 $max)
                {
                    local v_max_time=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 3600 -e "use ${db_name};select time from ${tab_name} where device_id='d_${i}' order by time desc limit 1;"|grep "+08:00"|awk -F '|' '{print $2}'`
                    # delete
                    if [[ "${v_max_time}" != "" ]];then
                       ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -timeout 3600 -e "use ${db_name};delete from ${tab_name} where device_id='d_${i}' and time<=${v_max_time}"
                    fi
                    let v_loop_check_bm++
                    if [[ ${v_loop_check_bm} -ge 100 ]];then
                            v_bm_num=`jps|grep App|wc -l`
                            if [[ ${v_bm_num} = 0 ]];then
                                    break
                            fi
                            v_loop_check_bm=0
                    fi

                }
               v_bm_num=`jps|grep App|wc -l`
               if [[ ${v_bm_num} = 0 ]];then
                       break
               fi

        done
}
function del_tree_data()
{
        local db_name="root.test.g_0"
        local max=499
        local i=0
        while true
        do
                for i in $(seq 0 $max)
                {
                    local v_max_time=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 3600 -e "select s_0 from ${db_name}.d1_${i} order by time desc limit 1;"|grep "+08:00"|awk -F '|' '{print $2}'`
                    # delete
                    if [[ "${v_max_time}" != "" ]];then
                       ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 3600 -e "delete from ${db_name}.d1_${i}.* where time<=${v_max_time};"
                    fi
                    local v_max_time=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 3600 -e "select s_0 from ${db_name}.d2_${i} order by time desc limit 1;"|grep "+08:00"|awk -F '|' '{print $2}'`
                    # delete
                    if [[ "${v_max_time}" != "" ]];then
                       ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 3600 -e "delete from ${db_name}.d2_${i}.* where time<=${v_max_time};"
                    fi

#		    local v_max_time=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 3600 -e "select s_0 from ${db_name}.d2_${i} order by time desc limit 1;"|grep "+08:00"|awk -F '|' '{print $2}'`
#		    # delete
#		    if [[ "${v_max_time}" != "" ]];then
#			    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -timeout 3600 -e "delete timeseries ${db_name}.d2_${i}.* ;"
#		    fi
                    v_bm_num=`jps|grep App|wc -l`
                    if [[ ${v_bm_num} = 0 ]];then
                       break
                    fi

                }
        done
}

# testcase1
function testcase1()
{
	echo "testcase1 at `date "+%Y-%m-%d %H:%M:%S"`"
	check_data_consistent
	check_log
	if [[ ${backup_flag} -gt 0 ]];then
	v_backup_time=`date +%s`
    sh ${clean_env_dir}/backup_cluster_logs_data.sh ${v_backup_time}
fi
if [[ ${backup_log_flag} -gt 0 ]];then
	v_backup_time=`date +%s`
    sh ${clean_env_dir}/backup_cluster_logs.sh ${v_backup_time}
fi
   if [[ ${fail_flag} -gt 0 ]];then
	   echo "testcase1 fail"
   else
	   echo "testcase1 pass"

   fi

}
# start cluster 
start_db
start_bm
sleep 600
# 启动后台函数，并记录它们的PID（方便精准wait）
alter_timeseries_type &
pid1=$!  # 记录第一个后台进程的PID
sleep 10
alter_table_field_type &
pid2=$!  # 记录第二个后台进程的PID
del_devices &
pid3=$!
del_table_data &
pid4=$!
del_tree_data &
pid5=$!
# 精准等待这两个PID对应的进程完成（比裸wait更可控）
wait $pid1 $pid2 ${pid3} ${pid4} ${pid5}
echo "alter_tree_type 和 alter_table_type 已执行完成"

# 方案2：如果想等bm进程退出后再执行testcase1，用这个循环（二选一）
 while true
 do
 	v_bm=`jps|grep -i App|wc -l`
 	if [[ ${v_bm} -eq 0 ]];then  # 当App进程消失时，退出循环
 		break
 	fi
 	sleep 600  # 每60秒检查一次，避免高频查询
 done
sleep 1h
#kill -9 ${pid1} ${pid2} ${pid3} ${pid4} ${pid5}
sleep 10
# 现在能正常执行testcase1了
testcase1
