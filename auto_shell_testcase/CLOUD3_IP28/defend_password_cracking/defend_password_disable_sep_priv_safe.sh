#!/bin/bash
current_dir=$(pwd)
db_dir=/home/cluster/v2091rc5_0417_089c5437/
cli_dir=/data/iotdb/v2091rc5_0417_089c5437/
ssl_str="-usessl true -ts ${cli_dir}/.truststore -tpw TimechoDB"
# db_ip os name os_name
os_name=root
db_admin_name=root
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
function stop_dn_cn()
{
if [[ ${os_name} = root ]];then

ssh ${os_name}@${db_ip} "${db_dir}/sbin/stop-datanode.sh"
sleep 3
ssh ${os_name}@${db_ip} "${db_dir}/sbin/stop-confignode.sh"
else
ssh ${os_name}@${db_ip} "sudo ${db_dir}/sbin/stop-datanode.sh"
sleep 3
ssh ${os_name}@${db_ip} "sudo ${db_dir}/sbin/stop-confignode.sh"
fi
# check jps
check_num=0
while true
do
if [[ ${os_name} = root ]];then
v_jps_node=`ssh ${os_name}@${db_ip} "jps|grep Node|wc -l"`
else
v_jps_node=`ssh ${os_name}@${db_ip} "sudo jps|grep Node|wc -l"`
fi
if [[ ${v_jps_node} -gt 0 ]];then
sleep 1
else
break
fi
done
let check_num++
if [[ ${check_num} -gt 10 ]];then
	if [[ ${os_name} = root ]];then
	ssh ${os_name}@${db_ip} "jps | grep Node | awk '{print \$1}' | xargs -r kill -9"
	else
	ssh ${os_name}@${db_ip} "sudo jps | grep Node | awk '{print \$1}' | xargs -r sudo kill -9"
	fi
fi
}
function remove_data_logs()
{
if [[ -n "${db_dir}" ]]; then
        if [[ ${os_name} = root ]];then

        ssh ${os_name}@${db_ip} "rm -rf ${db_dir}/data"
        ssh ${os_name}@${db_ip} "rm -rf ${db_dir}/logs"
        ssh ${os_name}@${db_ip} "rm -rf ${db_dir}/conf"
        else
        ssh ${os_name}@${db_ip} "sudo rm -rf ${db_dir}/data"
        ssh ${os_name}@${db_ip} "sudo rm -rf ${db_dir}/logs"
        ssh ${os_name}@${db_ip} "sudo rm -rf ${db_dir}/conf"
        fi
fi
}
# function cp -rp conf
function copy_conf_from_backup()
{
ssh ${os_name}@${db_ip} "
  if [ ! -d '${db_dir}/conf' ]; then
    echo 'conf文件夹不存在，开始复制conf_backup...'
    # 检查conf_backup是否存在，避免复制失败
    if [ -d '${db_dir}/conf_backup' ]; then
      cp -r '${db_dir}/conf_backup' '${db_dir}/conf'
      echo '复制完成：${db_dir}/conf_backup -> ${db_dir}/conf'
    else
      echo '错误：${db_dir}/conf_backup不存在，无法复制'
      exit 1
    fi
  else
    echo 'conf文件夹已存在，无需操作'
  fi
"
}

function start_dn_cn()
{
# delete sed -i '/password_stale_warning_days/d' a.txt
ssh ${os_name}@${db_ip} "sed -i '/password_stale_warning_days/d' ${db_dir}/conf/iotdb-system.properties"
# close enable_separation_of_powers  
   v_param_exist=`ssh ${os_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${os_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${os_name}@${db_ip} "echo enable_separation_of_powers=false >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${os_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi

# check power
v_power=`ssh ${os_name}@${db_ip} "grep -E '^[[:space:]]*enable_separation_of_powers[[:space:]]*=[[:space:]]*true[[:space:]]*$' ${db_dir}/conf/iotdb-system.properties|wc -l"`
if [[ ${v_power} -gt 0 ]];then
db_admin_name=sys_admin
else
db_admin_name=root
fi
#start dn cn
if [[ ${os_name} = root ]];then
ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
else
ssh ${os_name}@${db_ip} "sudo ${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${os_name}@${db_ip} "sudo ${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
fi

# check status
while true
do
#
v_running_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${db_admin_name} ${ssl_str} -e "show cluster;"|grep Running|wc -l`
if [[ ${v_running_num} -lt ${node_num} ]];then
sleep 1
else
break
fi
done
db_admin_name=root
}

function start_dn_cn_exp_error()
{
exp_log=$1

# delete sed -i '/password_stale_warning_days/d' a.txt
ssh ${os_name}@${db_ip} "sed -i '/password_stale_warning_days/d' ${db_dir}/conf/iotdb-system.properties"
# close enable_separation_of_powers
   v_param_exist=`ssh ${os_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${os_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${os_name}@${db_ip} "echo enable_separation_of_powers=false >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${os_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi

# check power
v_power=`ssh ${os_name}@${db_ip} "grep -E '^[[:space:]]*enable_separation_of_powers[[:space:]]*=[[:space:]]*true[[:space:]]*$' ${db_dir}/conf/iotdb-system.properties|wc -l"`
if [[ ${v_power} -gt 0 ]];then
db_admin_name=sys_admin
else
db_admin_name=root
fi
#start dn cn
if [[ ${os_name} = root ]];then
ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
else
ssh ${os_name}@${db_ip} "sudo ${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${os_name}@${db_ip} "sudo ${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
fi
sleep 3
# check status
# check status
while true
do
#
v_running_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${db_admin_name} ${ssl_str} -e "show cluster;"|grep Running|wc -l`
if [[ ${v_running_num} -lt ${node_num} ]];then
sleep 1
else
break
fi
done

#check log
v_exp_num=`ssh ${os_name}@${db_ip} "grep \"${exp_log}\" ${db_dir}/logs/log_datanode_all.log|wc -l"`
if [[ ${v_exp_num} -gt 0 ]];then
let succ_flag++
else
let fail_flag++
echo "${exp_log} not found"
fi
db_admin_name=root
}


function check_res()
{
   exp_res=$1
   exp_num=$2
   tc_num=$3
   v_act_num=`cat ${current_dir}/tmp.out|grep "${exp_res}"|wc -l`
   if [[ ${v_act_num} = ${exp_num} ]];then
      echo "${tc_num} PASS."
      if [[ ! ${tc_num} =~ ^repeate ]];then
         let succ_flag++
      else
         let repeate_succ_flag++

      fi
   else
      echo "${tc_num} FAIL."
      if [[ ! ${tc_num} =~ ^repeate ]];then
         let fail_flag++
      else
         let repeate_fail_flag++
      fi
      cat ${current_dir}/tmp.out
   fi
}
function get_userid()
{
   uname=$1
   desc=$2
   if [[ ${desc} = expect ]];then
      v_exp_uid=` cat ${current_dir}/tmp.out |grep ${uname}|awk -F '|' '{gsub(" ","");print $2}'`
   else
      v_actual_uid=` cat ${current_dir}/tmp.out |grep ${uname}|awk -F '|' '{gsub(" ","");print $2}'`

   fi
}
function check_uid()
{
   tc_num=$1
   if [[ -z "$v_exp_uid" ]]; then
    echo "${tc_num} expect user id is null ${v_exp_uid}"
   fi
   if [[ -z "$v_actual_uid" ]]; then
    echo "${tc_num} actual user id is null ${v_exp_uid}"
   fi

   if [[ ${v_exp_uid} != ${v_actual_uid} ]];then
      let repeate_fail_flag++
      echo "${tc_num} uid is not equal."
   fi
}
function check_npe()
{
   tc_num=$1
   v_npe_num=`ssh ${os_name}@${db_ip} "grep NullPointer ${db_dir}/logs/*all*|wc -l"`
   if [[ ${v_npe_num} -gt 0 ]];then
      let log_npe_flag++
      echo "${tc_num} NullPointer : ${v_npe_num}"
      # backup logs
      t=`date +%Y_%m_%d_%H_%M_%S`
      ssh ${os_name}@${db_ip} "cp -rp ${db_dir}/logs ${db_dir}/logs_npe_${t}_${tc_num}"
   fi
}
function set_params()
{
# failed_login_attempts=5
# failed_login_attempts_per_user=1000
# password_lock_time_minutes=10
   v_param1=$1
   v_param2=$2
   v_param3=$3

   v_param_exist=`ssh ${os_name}@${db_ip} "grep failed_login_attempts= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${os_name}@${db_ip} "grep failed_login_attempts ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${os_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
             ssh ${os_name}@${db_ip} "echo failed_login_attempts=${v_param1} >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${os_name}@${db_ip} "sed -i 's/failed_login_attempts=.*/failed_login_attempts=${v_param1}/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   v_param_exist=`ssh ${os_name}@${db_ip} "grep failed_login_attempts_per_user= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${os_name}@${db_ip} "grep failed_login_attempts_per_user ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${os_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
             ssh ${os_name}@${db_ip} "echo failed_login_attempts_per_user=${v_param2} >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${os_name}@${db_ip} "sed -i 's/failed_login_attempts_per_user=.*/failed_login_attempts_per_user=${v_param2}/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi

   v_param_exist=`ssh ${os_name}@${db_ip} "grep password_lock_time_minutes= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${os_name}@${db_ip} "grep password_lock_time_minutes ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${os_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
             ssh ${os_name}@${db_ip} "echo password_lock_time_minutes=${v_param3} >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${os_name}@${db_ip} "sed -i 's/password_lock_time_minutes=.*/password_lock_time_minutes=${v_param3}/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi

}
function unset_params()
{
# failed_login_attempts=5
# failed_login_attempts_per_user=1000
# password_lock_time_minutes=10

# delete params 
ssh ${os_name}@${db_ip} "sed -i '/failed_login_attempts/d' ${db_dir}/conf/iotdb-system.properties"
ssh ${os_name}@${db_ip} "sed -i '/failed_login_attempts_per_user/d' ${db_dir}/conf/iotdb-system.properties"
ssh ${os_name}@${db_ip} "sed -i '/password_lock_time_minutes/d' ${db_dir}/conf/iotdb-system.properties"


}

# enable_separation_of_powers=false , root create user javadi , javadi@client_ip28 Input the wrong password five times  
function testcase1()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   unset_params
   start_dn_cn
   # create javadi
   test_user=javadi
   other_user=santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${other_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${other_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"

   echo "">${current_dir}/tmp.out 
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase1"
#   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
# update log
   check_res "822: Account is blocked due to consecutive failed logins" 1 "testcase1"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
# update log
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase1"
   cat ${current_dir}/tmp.out
# other user is not lock
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase1"
# drop locked user
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "drop user ${test_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "drop user ${other_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"

   check_npe "testcase1"
}
# enable_separation_of_powers=false , root create user javadi , failed_login_attempts_per_user test 
function testcase2()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 5 7 2 
   start_dn_cn
   # create javadi
   test_user=javadi
   other_user=santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${other_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${other_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"

   echo "">${current_dir}/tmp.out
   for i in {1..6}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase2"
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase2"
   # javadi@ip13 wrong password
   for i in {7..8}
   do
      ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
      check_res "Authentication failed" 1 "repeate_testcase2"
   done

#   javadi@ip13 right password ,login failed
  ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
# update log
   check_res "822: Account is blocked due to consecutive failed logins" 1 "testcase2"

  ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
# update log
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase2"

# ip28 javadi login failed
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
# update log
   check_res "822: Account is blocked due to consecutive failed logins" 1 "testcase2"
# db_ip javadi login failed
  ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
# update log
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase2"
# other user is not locked
# ip28
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase2"
# db_ip
  ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
  check_res "Running" ${node_num} "repeate_testcase2"
# remove client ip ip13
  ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
  check_res "Running" ${node_num} "repeate_testcase2"

# drop locked user
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "drop user ${test_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "drop user ${other_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"
   check_npe "testcase2"
}

# enable_separation_of_powers=false , root create user javadi , lock time test
function testcase3()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 5 7 2
   start_dn_cn
   # create javadi
   test_user=javadi
   other_user=santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase3"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${other_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase3"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase3"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${other_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase3"

   echo "">${current_dir}/tmp.out
   for i in {1..6}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase3"
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase3"
   # javadi@ip13 wrong password
   for i in {7..8}
   do
      ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
      check_res "Authentication failed" 1 "repeate_testcase3"
   done

#   javadi@ip13 right password ,login failed
  ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
# update log
   check_res "822: Account is blocked due to consecutive failed logins" 1 "testcase3"

  ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
# update log
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase3"

# ip28 javadi login failed
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
# update log
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase3"
# db_ip javadi login failed
  ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
# update log
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase3"
# other user is not locked
# ip28
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase3"
# db_ip
  ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
  check_res "Running" ${node_num} "repeate_testcase3"
# remove client ip ip13
  ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
  check_res "Running" ${node_num} "repeate_testcase3"
# wait lock time login success
sleep 121

#   javadi@ip13 right password ,login failed
  ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "testcase3"

  ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "testcase3"

# ip28 javadi login failed
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
  check_res "Running" ${node_num} "repeate_testcase3"
# db_ip javadi login failed
  ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
  check_res "Running" ${node_num} "repeate_testcase3"

   echo "">${current_dir}/tmp.out
   for i in {1..6}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase3"
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase3"
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase3"
   sleep 121
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase3"

# drop locked user
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "drop user ${test_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase3"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "drop user ${other_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase3"
   check_npe "testcase3"
}
# enable_separation_of_powers=false , root create user javadi , unlock user@ip
function testcase4()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   unset_params
   start_dn_cn
   # create javadi
   test_user=javadi
   other_user=santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${other_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${other_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"

   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase4"
   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase4"
# unlock user@ip
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree ${ssl_str} -e "alter user ${test_user} @ '${this_shell_ip}' account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "testcase4"
   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase4"
# unlock santos@ip
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree ${ssl_str} -e "alter user ${other_user} @ '${this_shell_ip}' account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase4"
   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase4"
   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase4"
# unlock user@ip
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect table ${ssl_str} -e "alter user ${test_user} @ '${this_shell_ip}' account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase4"
# unlock santos@ip
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect table ${ssl_str} -e "alter user ${other_user} @ '${this_shell_ip}' account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase4"
# drop locked user
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "drop user ${test_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "drop user ${other_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"

   check_npe "testcase4"

}
# enable_separation_of_powers=false , root create user javadi , unlock user
function testcase5()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 5 7 10
   start_dn_cn
   # create javadi
   test_user=javadi
   other_user=santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${other_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${other_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"

   echo "">${current_dir}/tmp.out
   for i in {1..4}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 4 "repeate_testcase5"
   echo "">${current_dir}/tmp.out
   for i in {1..3}
   do
      ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw wrongpassword ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out

   done
   check_res "Authentication failed" 3 "repeate_testcase5"

   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase5"
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase5"
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase5"

# unlock user
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree ${ssl_str} -e "alter user ${test_user} account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "testcase5"
   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"
# unlock santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree ${ssl_str} -e "alter user ${other_user} account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"
   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"

   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${other_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"

   echo "">${current_dir}/tmp.out
   for i in {1..4}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 4 "repeate_testcase5"
   echo "">${current_dir}/tmp.out
   for i in {1..3}
   do
      ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw wrongpassword ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out

   done
   check_res "Authentication failed" 3 "repeate_testcase5"

   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase5"
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase5"
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase5"

# unlock user
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect table ${ssl_str} -e "alter user ${test_user} account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"
   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"
# unlock santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect table ${ssl_str} -e "alter user ${other_user} account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"
   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"

   # right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${other_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase5"

# drop user
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "drop user ${test_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "drop user ${other_user} ;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"

   check_npe "testcase5"

}
# enable_separation_of_powers=false ,exempt user 
function testcase6()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 5 7 10
   start_dn_cn

   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase6"
   echo "">${current_dir}/tmp.out
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase6"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${db_admin_name} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "testcase6"
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase6"
# root unlock himself
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${db_admin_name} -pw TimechoDB@2021 -h ${query_ip} -sql_dialect tree ${ssl_str} -e \"alter user ${db_admin_name} @ '${this_shell_ip}' account unlock;\"">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase6"
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase6"

   check_npe "testcase6"

}
# enable_separation_of_powers=false ,failed_login_attempts=-1 ,failed_login_attempts_per_user=10（默认值1000）,password_lock_time_minutes=1 ,用户被锁，等待自动解锁
function testcase7()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params -1 10 1
   start_dn_cn

   # create javadi
   test_user=javadi
   other_user=santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase7"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${other_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase7"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase7"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${other_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase7"


   echo "">${current_dir}/tmp.out
   for i in {1..10}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 10 "repeate_testcase7"
   echo "">${current_dir}/tmp.out
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase7"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase7"
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase7"

# other user failed 5 ,is not locked
   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase7"
   echo "">${current_dir}/tmp.out
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase7"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${other_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase7"
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase7"
   sleep 60

# this client ip right password,audo unlocked
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "testcase7"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase7"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase7"

   check_npe "testcase7"

}
# enable_separation_of_powers=false ,failed_login_attempts=-1 ,failed_login_attempts_per_user=10（默认值1000）,password_lock_time_minutes=1 ,用户在2个客户端，总次数被锁，用户被锁，等待自动解锁
function testcase8()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params -1 10 1
   start_dn_cn

   # create javadi
   test_user=javadi
   other_user=santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase8"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${other_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase8"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase8"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${other_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase8"


   echo "">${current_dir}/tmp.out
   for i in {1..9}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 9 "repeate_testcase8"
   echo "">${current_dir}/tmp.out
   for i in {10..10}
   do
      ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw wrongpassword -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
      check_res "Authentication failed" 1 "repeate_testcase8"
   done
   echo "">${current_dir}/tmp.out
   for i in {11..11}
   do
      ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw wrongpassword -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
      check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase8"
   done
   echo "">${current_dir}/tmp.out


# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase8"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase8"
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase8"

# other user failed 5 ,is not locked
   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase8"
   echo "">${current_dir}/tmp.out
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase8"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${other_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase8"
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase8"
   sleep 60

# this client ip right password,audo unlocked
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "testcase8"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase8"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase8"

   check_npe "testcase8"

}
# enable_separation_of_powers=false ,failed_login_attempts=0 ,failed_login_attempts_per_user=1（默认值1000）,password_lock_time_minutes=1 ,用户IP被锁，等待自动解锁
function testcase9()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 0 10 1
   start_dn_cn

   # create javadi
   test_user=javadi
   other_user=santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase9"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${other_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase9"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase9"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${other_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase9"


   echo "">${current_dir}/tmp.out
   for i in {1..10}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 10 "repeate_testcase9"
   echo "">${current_dir}/tmp.out
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase9"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase9"
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase9"

# other user failed 5 ,is not locked
   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase9"
   echo "">${current_dir}/tmp.out
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase9"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${other_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase9"
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase9"
   sleep 60

# this client ip right password,audo unlocked
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "testcase9"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase9"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase9"

   check_npe "testcase9"

}

# enable_separation_of_powers=false ,failed_login_attempts=-1 ,failed_login_attempts_per_user=10（默认值1000）,password_lock_time_minutes=10 ,用户被锁，解锁user IP 无效,unlock 用户锁有效
function testcase10()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params -1 10 10
   start_dn_cn

   # create javadi
   test_user=javadi
   other_user=santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase10"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${other_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase10"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase10"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${other_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase10"


   echo "">${current_dir}/tmp.out
   for i in {1..10}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 10 "repeate_testcase10"
   echo "">${current_dir}/tmp.out
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase10"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase10"
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase10"

# other user failed 5 ,is not locked
   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase10"
   echo "">${current_dir}/tmp.out
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase10"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${other_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase10"
# this client ip right password
   ${cli_dir}/sbin/start-cli.sh -u ${other_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase10"
# unlock user IP
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "alter user ${test_user} @ '${this_shell_ip}' account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "testcase10"

# this client ip right password,still in locking
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "testcase10"
# unlock user 
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "alter user ${test_user} account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase10"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase10"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase10"
# this ip
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase10"


   check_npe "testcase10"

}
# enable_separation_of_powers=false ,failed_login_attempts=-1 ,failed_login_attempts_per_user=10（默认值1000）,password_lock_time_minutes=10 ,用户未被锁 ，login success failed times is clear
function testcase11()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params -1 10 10
   start_dn_cn

   # create javadi
   test_user=javadi
   other_user=santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase11"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${other_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase11"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase11"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${other_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase11"


   echo "">${current_dir}/tmp.out
   for i in {1..9}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 9 "repeate_testcase11"
   echo "">${current_dir}/tmp.out
# other client ip right password,success
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase11"

   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase11"


   # this_ip right password,success
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "testcase11"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase11"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase11"

   check_npe "testcase11"

}
# enable_separation_of_powers=false ,failed_login_attempts=5 ,failed_login_attempts_per_user=-1（默认值1000）,password_lock_time_minutes=10 ,start datanode has error and reset 1000 
function testcase12()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 5 -1 10
   start_dn_cn_exp_error "User-level attempts auto-enabled with default 1000 because IP-level is enabled"
   test_user=javadi
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase12"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase12"

   # this ip failed 4 
   echo "">${current_dir}/tmp.out
   for i in {1..4}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 4 "repeate_testcase12"
   # dn ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..4}
   do
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw wrongpassword -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 4 "repeate_testcase12"

  # remote cli ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..4}
   do
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw wrongpassword -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 4 "repeate_testcase12"
   echo "">${current_dir}/tmp.out
  # is not locked
   # this_ip right password,success
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase12"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase12"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase12"
   check_npe "testcase12"

}

# enable_separation_of_powers=false ,failed_login_attempts=5 ,failed_login_attempts_per_user=0（默认值1000）,password_lock_time_minutes=10 ,start datanode has error
function testcase13()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 5 0 10
   start_dn_cn_exp_error "User-level attempts auto-enabled with default 1000 because IP-level is enabled"
   test_user=javadi
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase13"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase13"

   # this ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..4}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 4 "repeate_testcase13"
   # dn ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..4}
   do
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw wrongpassword -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 4 "repeate_testcase13"

  # remote cli ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..4}
   do
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw wrongpassword -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 4 "repeate_testcase13"
   echo "">${current_dir}/tmp.out
  # is not locked
   # this_ip right password,success
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase13"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase13"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase13"
   check_npe "testcase13"

}

# enable_separation_of_powers=false ,failed_login_attempts=-1 ,failed_login_attempts_per_user=-1（默认值1000）,password_lock_time_minutes=10 ,never lock
function testcase14()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params -1 -1 10
   start_dn_cn
   test_user=javadi
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase14"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase14"

   # this ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..10}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 10 "repeate_testcase14"
   # dn ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..10}
   do
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw wrongpassword -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 10 "repeate_testcase14"

  # remote cli ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..10}
   do
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw wrongpassword -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 10 "repeate_testcase14"
   echo "">${current_dir}/tmp.out
  # is not locked
   # this_ip right password,success
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "testcase14"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase14"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase14"
   check_npe "testcase14"

}
# enable_separation_of_powers=false ,failed_login_attempts=5 ,failed_login_attempts_per_user=1（默认值1000）,password_lock_time_minutes=10 , user < user_ip
function testcase15()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 5 1 10
   start_dn_cn
   test_user=javadi
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase15"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase15"

   # this ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..1}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 1 "repeate_testcase15"
   # dn ip right password failed 2 
   echo "">${current_dir}/tmp.out
   for i in {1..2}
   do
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out
   done
   check_res "822: Account is blocked due to consecutive failed logins" 2 "testcase15"

  # right pass remote cli ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..4}
   do
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out
   done
   check_res "822: Account is blocked due to consecutive failed logins" 4 "repeate_testcase15"
   echo "">${current_dir}/tmp.out
# unlock user ip
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree ${ssl_str} -e "alter user ${test_user} @ '${this_shell_ip}' account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase15"
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase15"
# unlock user
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree ${ssl_str} -e "alter user ${test_user} account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase15"
   # this_ip right password,success
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase15"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase15"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase15"

   check_npe "testcase15"

}

# enable_separation_of_powers=false ,failed_login_attempts=5 ,failed_login_attempts_per_user=5（默认值1000）,password_lock_time_minutes=10 , user = user_ip
function testcase16()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 5 5 10
   start_dn_cn
   test_user=javadi
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase16"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase16"

   # this ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase16"
   # dn ip right password right password login failed
   echo "">${current_dir}/tmp.out
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "testcase16"

  # right pass remote cli ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..4}
   do
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">>${current_dir}/tmp.out
   done
   check_res "822: Account is blocked due to consecutive failed logins" 4 "repeate_testcase16"
   echo "">${current_dir}/tmp.out
# unlock user ip
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree ${ssl_str} -e "alter user ${test_user} @ '${this_shell_ip}' account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase16"
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase16"
# unlock user
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree ${ssl_str} -e "alter user ${test_user} account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase16"
   # this_ip right password,success
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase16"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase16"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase16"

   check_npe "testcase16"

}

# enable_separation_of_powers=false ,failed_login_attempts=5 ,failed_login_attempts_per_user=1000（默认值1000）,password_lock_time_minutes=-1 
function testcase17()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 5 1000 -1
   start_dn_cn
   test_user=javadi
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase17"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase17"

   # this ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase17"
   sleep 65
# user ip lock   
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "testcase17"
   # dn ip right password right password login success 
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase17" 

  # right pass remote cli ip failed 4
   echo "">${current_dir}/tmp.out
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase17" 
   echo "">${current_dir}/tmp.out
  
# unlock user ip
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree ${ssl_str} -e "alter user ${test_user} @ '${this_shell_ip}' account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase17"
   # this_ip right password,success
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase17"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase17"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase17"

   check_npe "testcase17"

}

# enable_separation_of_powers=false ,failed_login_attempts=5 ,failed_login_attempts_per_user=1000（默认值1000）,password_lock_time_minutes=0
function testcase18()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 5 1000 0
   start_dn_cn
   test_user=javadi
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase18"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase18"

   # this ip failed 4
   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase18"
   sleep 65
# user ip lock
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "testcase18"
   # dn ip right password right password login success
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase18"

  # right pass remote cli ip failed 4
   echo "">${current_dir}/tmp.out
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase18"
   echo "">${current_dir}/tmp.out

# unlock user ip
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -pw TimechoDB@2021 -sql_dialect tree ${ssl_str} -e "alter user ${test_user} @ '${this_shell_ip}' account unlock;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase18"
   # this_ip right password,success
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase18"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase18"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase18"

   check_npe "testcase18"

}

# enable_separation_of_powers=false ,ns 时间戳 failed_login_attempts=5 ,failed_login_attempts_per_user=5（默认值1000）,password_lock_time_minutes=1
function testcase19()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 5 5 1
   # set ns
   ssh ${os_name}@${db_ip} "echo timestamp_precision=ns >> ${db_dir}/conf/iotdb-system.properties" 
   start_dn_cn
   test_user=javadi
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} ${ssl_str} -e "create user ${test_user} 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase19"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e "grant system to user ${test_user};">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase19"

   # this ip failed 5 
   echo "">${current_dir}/tmp.out
   for i in {1..5}
   do
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB ${ssl_str} -e "show cluster;">>${current_dir}/tmp.out
   done
   check_res "Authentication failed" 5 "repeate_testcase19"
   sleep 5
# user  lock
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "testcase19"
   # dn ip right password right password login success
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "822: Account is blocked due to consecutive failed logins" 1 "repeate_testcase19"

  sleep 60
   # this_ip right password,success
   ${cli_dir}/sbin/start-cli.sh -u ${test_user} -h ${query_ip} -pw TimechoDB@2021 ${ssl_str} -e "show cluster;">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase19"

   # db_ip right password
   ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase19"
# remote client ip right password
   ssh ${remote_cli_os_user}@${remote_cli_ip} "${cli_dir}/sbin/start-cli.sh -u ${test_user} -pw TimechoDB@2021 -h ${query_ip}  ${ssl_str} -e \"show cluster;\"">${current_dir}/tmp.out
   check_res "Running" ${node_num} "repeate_testcase19"
   # set ms
   ssh ${os_name}@${db_ip} "sed -i 's/timestamp_precision=.*/timestamp_precision=ms/g'  ${db_dir}/conf/iotdb-system.properties"
   # delete param
   ssh ${os_name}@${db_ip} "sed -i '/timestamp_precision/d' ${db_dir}/conf/iotdb-system.properties"
   check_npe "testcase19"

}

#check conf_backup
ssh ${os_name}@${db_ip} "
  if [ ! -d '${db_dir}/conf_backup' ]; then
    echo 'conf_backup文件夹不存在,exit'
    exit 1
  fi
"

testcase1
testcase2
testcase3
testcase4
testcase5
testcase6
testcase7
testcase8
testcase9
testcase10
testcase11
testcase12
testcase13
testcase14
testcase15
testcase16
testcase17
testcase18
testcase19
echo "SUCCESS TESTCASE ${succ_flag},FAILED TESTCASE ${fail_flag}"
echo "NPE ${log_npe_flag},OTHER FAILED TESTCASE ${repeate_fail_flag},OTHER SUCC TESTCASE ${repeate_succ_flag}"
