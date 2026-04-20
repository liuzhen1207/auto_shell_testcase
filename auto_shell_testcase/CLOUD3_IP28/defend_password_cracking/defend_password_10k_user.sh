#!/bin/bash
current_dir=$(pwd)
db_dir=/home/cluster/v2091rc5_0417_089c5437/
cli_dir=/data/iotdb/v2091rc5_0417_089c5437/
#ssl_str="-usessl true -ts ${cli_dir}/.truststore -tpw TimechoDB"
ssl_str=""
# db_ip os name os_name
os_name=root
db_admin_name=root
db_sec_name1=security_admin
db_sec_name=root
remote_cli_os_user=cluster
remote_cli_ip=172.20.70.13
db_ip=172.20.70.42
this_shell_ip=172.20.70.28
query_ip=${db_ip}
node_num=2
fail_flag=0
succ_flag=0
log_npe_flag=0
repeate_fail_flag=0
repeate_succ_flag=0
license_parent_dir="/home/cluster/license_2026"
license_dir="${license_parent_dir}/license"
env_dir="${license_parent_dir}/.env"
seed_cn_ip=${db_ip}
v_consensus="IoTConsensus"
# 单个ConfigNode配置函数
configure_confignode() {
    local node_ip=${db_ip}

    # 整合所有ConfigNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_name}@${node_ip}" bash -s <<EOF >> "${current_dir}/tmp.out" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="2G"/g' ${db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${db_dir}/conf/confignode-env.sh
        
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
        batch_set_sys_conf ".*cn_seed_config_node=.*" "cn_seed_config_node=${seed_cn_ip}:10710"
        batch_set_sys_conf ".*cn_internal_address=.*" "cn_internal_address=${node_ip}"
        batch_set_sys_conf ".*enable_separation_of_powers=.*" "enable_separation_of_powers=false"
#        batch_set_sys_conf ".*timestamp_precision=.*" "timestamp_precision=ns"

EOF

    if [ $? -eq 0 ]; then
        echo "INFO" "DataNode ${node_ip} 配置完成"
    else
        echo "ERROR" "DataNode ${node_ip} 配置失败"
        return 1
    fi
}

# 单个DataNode配置函数
configure_datanode() {
    local node_ip=${db_ip}

    # 整合所有DataNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_name}@${node_ip}" bash -s <<EOF >> "${current_dir}/tmp.out" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="8G"/g' ${db_dir}/conf/datanode-env.sh
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
        batch_set_sys_conf ".*dn_seed_config_node=.*" "dn_seed_config_node=${seed_cn_ip}:10710"
        batch_set_sys_conf ".*dn_internal_address=.*" "dn_internal_address=${node_ip}"
        batch_set_sys_conf ".*dn_rpc_address=.*" "dn_rpc_address=${node_ip}"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_separation_of_powers=.*" "enable_separation_of_powers=false"
#        batch_set_sys_conf ".*timestamp_precision=.*" "timestamp_precision=ns"

EOF

    if [ $? -eq 0 ]; then
        log "INFO" "DataNode ${node_ip} 配置完成"
    else
        log "ERROR" "DataNode ${node_ip} 配置失败"
        return 1
    fi
}
set_conf() {
configure_confignode
configure_datanode
}

function restart_cluster()
{
# stop cluster
ssh ${os_name}@${db_ip} "${db_dir}/sbin/stop-datanode.sh"
sleep 5
ssh ${os_name}@${db_ip} "${db_dir}/sbin/stop-confignode.sh"
sleep 5
while true
do
v_node_jps_num=$(ssh ${os_name}@${db_ip} "jps|grep Node|wc -l")
if [[ ${v_node_jps_num} -gt 0 ]];then
sleep 5
else
echo "stop cluster ok."
ssh ${os_name}@${db_ip} "rm -rf ${db_dir}/data"
ssh ${os_name}@${db_ip} "rm -rf ${db_dir}/logs"
ssh ${os_name}@${db_ip} "rm -rf ${db_dir}/conf"
ssh ${os_name}@${db_ip} "cp -rp ${db_dir}/conf_orig ${db_dir}/conf"
set_conf
break
fi
done
ssh ${os_name}@${db_ip} "echo 3 >/proc/sys/vm/drop_caches"

# start cluster
if ssh ${os_name}@${db_ip} test -d ${license_dir}; then
  ssh ${os_name}@${db_ip} "rm -rf ${db_dir}/activation/license"
  ssh ${os_name}@${db_ip} "rm -rf ${db_dir}/.env"
  ssh ${os_name}@${db_ip} "cp -rp ${license_dir} ${db_dir}/activation/"
  ssh ${os_name}@${db_ip} "cp -rp ${env_dir} ${db_dir}/.env"
fi
v_start_time=$(date "+%Y_%m_%d_%H_%M_%S")
ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-confignode.sh -H ${db_dir}/cn_${v_start_time}.hprof > /dev/null 2>&1 &"
sleep 5
ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}.hprof > /dev/null 2>&1 &"
sleep 5
while true
do
v_running_num=$(${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${db_admin_name} -e "show cluster;"|grep "${db_ip}|"|grep Running|wc -l)
if [[ ${v_running_num} = 2 ]];then
echo "start cluster ok."
break
else
sleep 5
fi
done
}
function close_power_security_create_10k_user()
{
#>./create_10k_user.sql
#for i in {1..10000}
#do
#echo "create user lily_${i} 'TimechoDB@2021';">>./create_10k_user.sql
#done
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name1} -h ${query_ip} -sql_dialect table ${ssl_str} -e <./create_10k_user.sql
}
function create_10k_user()
{
#>./create_10k_user.sql
#for i in {1..10000}
#do
#echo "create user lily_${i} 'TimechoDB@2021';">>./create_10k_user.sql
#done
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e <./create_10k_user.sql
}

function close_power_security_create_10k_user()
{
#>./create_10k_user.sql
#for i in {1..10000}
#do
#echo "create user lily_${i} 'TimechoDB@2021';">>./create_10k_user.sql
#done
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e <./create_10k_user.sql
}

function drop_10k_user()
{
>./drop_10k_user.sql
for i in {1..10000}
do
echo "drop user lily_${i} ;">>./drop_10k_user.sql
done
${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e <./drop_10k_user.sql
}
# 并发数设置（同时处理10个用户）
CONCURRENT=10

# 总用户数
TOTAL_USERS=10000

# 并行处理函数
login_failed() {
  # 使用循环控制并发组，每组处理CONCURRENT个用户
  for ((group=0; group<TOTAL_USERS; group+=CONCURRENT)); do
    # 每组内启动CONCURRENT个进程并行执行
    for ((i=0; i<CONCURRENT; i++)); do
      # 计算当前用户编号（避免越界）
      user_num=$((group + i + 1))
      if ((user_num > TOTAL_USERS)); then
        break  # 超过总用户数则退出当前组循环
      fi
      
      # 并行执行登录命令（& 表示后台运行）
      (
        echo "Processing user lily_${user_num}"
        # 两次密码错误尝试
        ${cli_dir}/sbin/start-cli.sh -u lily_${user_num} -pw wrongpassword -h ${query_ip} -sql_dialect table ${ssl_str} -e "list privileges of user lily_${user_num};"
        ${cli_dir}/sbin/start-cli.sh -u lily_${user_num} -pw wrongpassword -h ${query_ip} -sql_dialect table ${ssl_str} -e "list privileges of user lily_${user_num};"
        # 一次正确密码尝试
        ${cli_dir}/sbin/start-cli.sh -u lily_${user_num} -pw TimechoDB@2021 -h ${query_ip} -sql_dialect table ${ssl_str} -e "list privileges of user lily_${user_num};"
      ) &
    done
    # 等待当前组的所有并发进程完成，再进入下一组
    wait
    echo "Completed group $((group/CONCURRENT + 1)) (users $((group + 1)) to $((group + CONCURRENT > TOTAL_USERS ? TOTAL_USERS : group + CONCURRENT)))"
  done
}
function check_npe()
{
   v_npe_num=`ssh ${os_name}@${db_ip} "grep NullPointer ${db_dir}/logs/*all*|wc -l"`
   v_err_num=`ssh ${os_name}@${db_ip} "grep \"meet error while logging in\" ${db_dir}/logs/*confignode*error*|wc -l"`
   if [[ ${v_npe_num} -gt 0 ]] || [[ ${v_err_num} -gt 0 ]];then
      let fail_flag++
      echo "${tc_num} NullPointer : ${v_npe_num}"
      echo "meet error while logging in: ${v_err_num}"
      echo "https://pingcode.timecho.com/pjm/projects/V2/xE9Rtxmq/EkOyn9_E bug is still exist."
   fi
v_test_file=$(basename "$0")
v_test_file_name=$(echo ${v_test_file}|awk -F '.' '{print $1}')
v_backup_time=`date +"%Y_%m_%d_%H_%M_%S"`
ssh ${os_name}@${db_ip} "cp -rp ${db_dir}/logs ${db_dir}/logs_${v_test_file_name}_${v_backup_time}"
}

restart_cluster
close_power_security_create_10k_user
loop=0
while true
do
create_10k_user
# 执行函数
login_failed
drop_10k_user
let loop++
echo "TEST ${loop}th check log:"
check_npe
done

