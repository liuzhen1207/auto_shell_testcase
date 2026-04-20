#!/bin/bash
current_dir=$(pwd)
db_dir=/home/cluster/v2091rc5_0417_089c5437/
cli_dir=/data/iotdb/v2091rc5_0417_089c5437/
# db_ip os name os_name
os_name=root
db_admin_name=sys_admin
db_sec_name=security_admin
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

function start_dn_cn_open_separation()
{
special_user=$1
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
if [[ ${os_name} = root ]];then
ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
else
ssh ${os_name}@${db_ip} "sudo ${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${os_name}@${db_ip} "sudo ${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
fi
db_admin_name=sys_admin

if [ -n "$special_user" ];then
db_admin_name=${special_user}
fi
# check status
while true
do
#
v_running_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${db_admin_name} -e "show cluster;"|grep Running|wc -l`
if [[ ${v_running_num} -lt ${node_num} ]];then
sleep 1
else
break
fi
done
user_name=root
}
function close_separation()
{

   ssh ${os_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties"

}

function start_dn_cn_close_separation()
{
special_user=$1
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
close_separation
if [[ ${os_name} = root ]];then
ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${os_name}@${db_ip} "${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
else
ssh ${os_name}@${db_ip} "sudo ${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${os_name}@${db_ip} "sudo ${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
fi
db_admin_name=root
if [ -n "$special_user" ];then
db_admin_name=${special_user}
fi
# check status
while true
do
#
v_running_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${db_admin_name} -e "show cluster;"|grep Running|wc -l`
if [[ ${v_running_num} -lt ${node_num} ]];then
sleep 1
else
break
fi
done
user_name=root
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
v_running_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${db_admin_name} -e "show cluster;"|grep Running|wc -l`
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
# idle_session_timeout_in_minutes=-1 
   v_param1=$1

   v_param_exist=`ssh ${os_name}@${db_ip} "grep idle_session_timeout_in_minutes= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${os_name}@${db_ip} "grep idle_session_timeout_in_minutes ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${os_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
             ssh ${os_name}@${db_ip} "echo idle_session_timeout_in_minutes=${v_param1} >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${os_name}@${db_ip} "sed -i 's/idle_session_timeout_in_minutes=.*/idle_session_timeout_in_minutes=${v_param1}/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi

}
function unset_params()
{
# idle_session_timeout_in_minutes=-1 

# delete params 
ssh ${os_name}@${db_ip} "sed -i '/idle_session_timeout_in_minutes/d' ${db_dir}/conf/iotdb-system.properties"

}
function gen_sql()
{
#v_sql=$1
echo "">${current_dir}/exec_sql.sql
echo "drop database db;">${current_dir}/exec_sql.sql
echo "create database db;">>${current_dir}/exec_sql.sql
echo "use db;">>${current_dir}/exec_sql.sql
echo "create table t(device_id string tag,id int32);">>${current_dir}/exec_sql.sql
for i in {1..10000}
do 
echo "insert into t(time,device_id,id) values(now(),'d1',1);" >>${current_dir}/exec_sql.sql
done
for i in {1..10000}
do
echo "delete from t;" >>${current_dir}/exec_sql.sql
done

}
function active_session()
{
   t_u_name=$1
   echo "" >${current_dir}/exec_sql.out

   ${cli_dir}/sbin/start-cli.sh -u ${t_u_name} -h ${query_ip} -timeout 36000 -sql_dialect table -e <${current_dir}/exec_sql.sql >${current_dir}/exec_sql.out 2>&1 &
}
# enable_separation_of_powers=true ,root, enable_black_list=true,add this ip to blacklist 
function testcase1()
{
   stop_dn_cn
   remove_data_logs
   copy_conf_from_backup
   set_params -1
#blacklist unset
   ssh ${os_name}@${db_ip} "sed -i '/^black_ip_list=/d' ${db_dir}/conf/iotdb-system.properties"   
   v_param_exist=`ssh ${os_name}@${db_ip} "grep enable_black_list= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${os_name}@${db_ip} "grep enable_black_list ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${os_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
             ssh ${os_name}@${db_ip} "echo enable_black_list=true>> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${os_name}@${db_ip} "sed -i 's/enable_black_list=.*/enable_black_list=true/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi

   start_dn_cn_open_separation 
# create user santos 
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"

   active_session santos
   while true
   do
       v_find_sql=`grep "drop database db" ${current_dir}/exec_sql.out|wc -l`
       if [[ ${v_find_sql} -gt 0 ]];then
          break
       fi
   done 
# root at this ip  put this ip to blacklist 
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "show cluster;set configuration black_ip_list='${this_shell_ip}';show cluster;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"
   check_res "803: Access Denied: No permissions for this operation, please add privilege SYSTEM" 1 "repeate_testcase1"
   sleep 3
   check_res "802: Log in failed. Either you are not authorized or the session has timed out" 1 "testcase1"
   v_log_fail_num=`grep "802: Log in failed. Either you are not authorized or the session has timed out" ${current_dir}/exec_sql.out|wc -l`
   if [[ ${v_log_fail_num} -gt 0 ]];then
      let repeate_succ_flag++
   else
      let repeate_fail_flag++
   fi
#blacklist unset
#   ssh ${os_name}@${db_ip} "sed -i '/^black_ip_list=/d' ${db_dir}/conf/iotdb-system.properties"
#   ssh ${os_name}@${db_ip} "sed -i '/^enable_black_list=/d' ${db_dir}/conf/iotdb-system.properties"
   check_npe "testcase1"
}
# enable_separation_of_powers=true ,root, enable_white_list=true,remove this ip from whilelist
function testcase2()
{
   stop_dn_cn
   remove_data_logs
   copy_conf_from_backup
   set_params -1
#whitelist unset
   ssh ${os_name}@${db_ip} "sed -i '/white_ip_list=/d' ${db_dir}/conf/iotdb-system.properties"
   ssh ${os_name}@${db_ip} "sed -i '/enable_black_list=/d' ${db_dir}/conf/iotdb-system.properties"
   v_param_exist=`ssh ${os_name}@${db_ip} "grep enable_white_list= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${os_name}@${db_ip} "grep enable_white_list ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${os_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
             ssh ${os_name}@${db_ip} "echo enable_white_list=true>> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${os_name}@${db_ip} "sed -i 's/.*enable_white_list=.*/enable_white_list=true/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
# set white list
   v_param_exist=`ssh ${os_name}@${db_ip} "grep white_ip_list= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${os_name}@${db_ip} "grep white_ip_list ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${os_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
             ssh ${os_name}@${db_ip} "echo white_ip_list='${this_shell_ip},${remote_cli_ip}'>> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${os_name}@${db_ip} "sed -i \"s/.*white_ip_list=.*/white_ip_list='${this_shell_ip},${remote_cli_ip}'/g\" ${db_dir}/conf/iotdb-system.properties"
           fi
   fi

   start_dn_cn_open_separation 
# create user santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"

   active_session santos
   while true
   do
       v_find_sql=`grep "drop database db" ${current_dir}/exec_sql.out|wc -l`
       if [[ ${v_find_sql} -gt 0 ]];then
          break
       fi
   done
# root at this ip  put this ip to blacklist
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "show cluster;set configuration white_ip_list='${remote_cli_ip}';show cluster;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"
   sleep 3
   check_res "802: Log in failed. Either you are not authorized or the session has timed out" 1 "testcase2"
   v_log_fail_num=`grep "802: Log in failed. Either you are not authorized or the session has timed out" ${current_dir}/exec_sql.out|wc -l`
   if [[ ${v_log_fail_num} -gt 0 ]];then
      let repeate_succ_flag++
   else
      let repeate_fail_flag++
   fi
#blacklist unset
#   ssh ${os_name}@${db_ip} "sed -i '/^white_ip_list=/d' ${db_dir}/conf/iotdb-system.properties"
#   ssh ${os_name}@${db_ip} "sed -i '/^#white_ip_list=/d' ${db_dir}/conf/iotdb-system.properties"
#   ssh ${os_name}@${db_ip} "sed -i '/^enable_white_list=/d' ${db_dir}/conf/iotdb-system.properties"
   check_npe "testcase2"
}
# enable_separation_of_powers=true ,root, enable_white_list=true,and then enable_white_list=false
function testcase3()
{
   stop_dn_cn
   remove_data_logs
   copy_conf_from_backup
   set_params -1
#whitelist unset
   ssh ${os_name}@${db_ip} "sed -i '/^white_ip_list=/d' ${db_dir}/conf/iotdb-system.properties"
   ssh ${os_name}@${db_ip} "sed -i '/^#white_ip_list=/d' ${db_dir}/conf/iotdb-system.properties"
   ssh ${os_name}@${db_ip} "sed -i '/white_ip_list=/d' ${db_dir}/conf/iotdb-system.properties"
   v_param_exist=`ssh ${os_name}@${db_ip} "grep enable_white_list= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${os_name}@${db_ip} "grep enable_white_list ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${os_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
             ssh ${os_name}@${db_ip} "echo enable_white_list=true>> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${os_name}@${db_ip} "sed -i 's/enable_white_list=.*/enable_white_list=true/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
# set white list
   v_param_exist=`ssh ${os_name}@${db_ip} "grep white_ip_list= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${os_name}@${db_ip} "grep white_ip_list ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${os_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
             ssh ${os_name}@${db_ip} "echo white_ip_list='${this_shell_ip},${remote_cli_ip}'>> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${os_name}@${db_ip} "sed -i \"s/white_ip_list=.*/white_ip_list='${this_shell_ip},${remote_cli_ip}'/g\" ${db_dir}/conf/iotdb-system.properties"
           fi
   fi

   start_dn_cn_open_separation 
# create user santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase3"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase3"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase3"

   active_session santos
   while true
   do
       v_find_sql=`grep "drop database db" ${current_dir}/exec_sql.out|wc -l`
       if [[ ${v_find_sql} -gt 0 ]];then
          break
       fi
   done
# root at this ip  put this ip to blacklist
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "show cluster;set CONFIGURATION enable_white_list='false';show cluster;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase3"
   sleep 3
   check_res "802: Log in failed. Either you are not authorized or the session has timed out" 0 "testcase3"
   v_log_fail_num=`grep "802: Log in failed. Either you are not authorized or the session has timed out" ${current_dir}/exec_sql.out|wc -l`
   if [[ ${v_log_fail_num} -gt 0 ]];then
      let repeate_fail_flag++
   else
      let repeate_succ_flag++
   fi
#blacklist unset
#   ssh ${os_name}@${db_ip} "sed -i '/^white_ip_list=/d' ${db_dir}/conf/iotdb-system.properties"
#   ssh ${os_name}@${db_ip} "sed -i '/^#white_ip_list=/d' ${db_dir}/conf/iotdb-system.properties"
#   ssh ${os_name}@${db_ip} "sed -i '/^enable_white_list=/d' ${db_dir}/conf/iotdb-system.properties"
   check_npe "testcase3"
}
# enable_separation_of_powers=true ,drop user
function testcase4()
{
   stop_dn_cn
   remove_data_logs
   copy_conf_from_backup
   set_params -1
   start_dn_cn_open_separation 
# create user santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"

   active_session santos
   while true
   do
       v_find_sql=`grep "drop database db" ${current_dir}/exec_sql.out|wc -l`
       if [[ ${v_find_sql} -gt 0 ]];then
          break
       fi
   done
# root at this ip  put this ip to blacklist
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "revoke system from user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "revoke all on any from user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"

   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "drop user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   sleep 3
   v_log_fail_num=`grep "802: Log in failed. Either you are not authorized or the session has timed out" ${current_dir}/exec_sql.out|wc -l`
   if [[ ${v_log_fail_num} -gt 0 ]];then
      let succ_flag++
   else
      let fail_flag++
   fi
   check_npe "testcase4"
}
# enable_separation_of_powers=true ,alter user password
function testcase5()
{
   stop_dn_cn
   remove_data_logs
   copy_conf_from_backup
   set_params -1
   start_dn_cn_open_separation 
# create user santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"

   active_session santos
   while true
   do
       v_find_sql=`grep "drop database db" ${current_dir}/exec_sql.out|wc -l`
       if [[ ${v_find_sql} -gt 0 ]];then
          break
       fi
   done
# root at this ip  put this ip to blacklist
   ${cli_dir}/sbin/start-cli.sh -u santos -h ${query_ip} -sql_dialect table -e "alter user santos set password 'TimechoDB@2022';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"
   sleep 3
   v_log_fail_num=`grep "802: Log in failed. Either you are not authorized or the session has timed out" ${current_dir}/exec_sql.out|wc -l`
   if [[ ${v_log_fail_num} -gt 0 ]];then
      let succ_flag++
   else
      let fail_flag++
   fi
   # root set self password
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "show cluster;alter user root set password 'TimechoDB@2022';show cluster;">${current_dir}/tmp.out
   check_res "803: Access Denied: No permissions for this operation, please add privilege SYSTEM" 2 "repeate_testcase5"
   check_res "803: No permission to update original super user" 1 "repeate_testcase5"
   check_npe "testcase5"
}
# enable_separation_of_powers=true ,idle_session_timeout_in_minutes=0
function testcase6()
{
   stop_dn_cn
   remove_data_logs
   copy_conf_from_backup
   set_params 0
   start_dn_cn_open_separation 
# create user santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase6"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase6"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase6"

# santos cli 
    # 核心逻辑：通过管道向 CLI 输入命令，延迟在管道中处理
{
  # 等待 CLI 启动并连接（约1-2秒，根据实际情况调整）
  echo "show cluster;"
  # 脚本层延迟1分钟
  sleep 65 
  # 延迟后输入目标命令
  echo "show cluster;"
  # 输入退出命令
  echo "exit"
} |${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -u santos > ${current_dir}/tmp.out 2>&1
check_res "802: Log in failed. Either you are not authorized or the session has timed out" 1 "testcase6"
   check_npe "testcase6"
}
# enable_separation_of_powers=true ,idle_session_timeout_in_minutes=1
function testcase7()
{
   stop_dn_cn
   remove_data_logs
  copy_conf_from_backup
   set_params 0
   start_dn_cn_open_separation 
# create user santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase7"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase7"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase7"

# santos cli
    # 核心逻辑：通过管道向 CLI 输入命令，延迟在管道中处理
{
  # 等待 CLI 启动并连接（约1-2秒，根据实际情况调整）
  echo "show cluster;"
  # 脚本层延迟1分钟
  sleep 66
  # 延迟后输入目标命令
  echo "show cluster;"
  # 输入退出命令
  echo "exit"
} |${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -u santos > ${current_dir}/tmp.out 2>&1
check_res "802: Log in failed. Either you are not authorized or the session has timed out" 1 "testcase7"
   check_npe "testcase7"
}
# enable_separation_of_powers=true ,idle_session_timeout_in_minutes=-1
function testcase8()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup

   set_params -1 
   start_dn_cn_open_separation 
# create user santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase8"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase8"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase8"

# santos cli
    # 核心逻辑：通过管道向 CLI 输入命令，延迟在管道中处理
{
  # 等待 CLI 启动并连接（约1-2秒，根据实际情况调整）
  echo "show cluster;"
  # 脚本层延迟1分钟
  sleep 121
  # 延迟后输入目标命令
  echo "show cluster;"
  # 输入退出命令
  echo "exit"
} |${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -u santos > ${current_dir}/tmp.out 2>&1
check_res "802: Log in failed. Either you are not authorized or the session has timed out" 0 "testcase8"
   check_npe "testcase8"
}
# enable_separation_of_powers=true,idle_session_timeout_in_minutes=2
function testcase9()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 2
   start_dn_cn_open_separation 
# create user santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase9"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase9"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase9"

# santos cli
    # 核心逻辑：通过管道向 CLI 输入命令，延迟在管道中处理
{
  # 等待 CLI 启动并连接（约1-2秒，根据实际情况调整）
  echo "show cluster;"
  # 脚本层延迟1分钟
  sleep 61
  # 延迟后输入目标命令
  echo "show cluster;"
  sleep 121
  echo "show cluster;"
  # 输入退出命令
  echo "exit"
} |${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -u santos > ${current_dir}/tmp.out 2>&1
check_res "802: Log in failed. Either you are not authorized or the session has timed out" 1 "testcase9"
   check_npe "testcase9"
}
# enable_separation_of_powers=true ,idle_session_timeout_in_minutes=-1 ,hot load idle_session_timeout_in_minutes=1
function testcase10()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params -1
   start_dn_cn_open_separation 
# create user santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase10"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase10"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase10"
# admin hot load
${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "set CONFIGURATION idle_session_timeout_in_minutes='1';">${current_dir}/tmp.out
check_res "success" 1 "repeate_testcase10"
# santos cli
    # 核心逻辑：通过管道向 CLI 输入命令，延迟在管道中处理
{
  # 等待 CLI 启动并连接（约1-2秒，根据实际情况调整）
  echo "show cluster;"
  # 脚本层延迟1分钟
  sleep 66
  # 延迟后输入目标命令
  echo "show cluster;"
  # 输入退出命令
  echo "exit"
} |${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -u santos > ${current_dir}/tmp.out 2>&1
check_res "802: Log in failed. Either you are not authorized or the session has timed out" 1 "testcase10"
   check_npe "testcase10"
}
# enable_separation_of_powers=true ,idle_session_timeout_in_minutes=1 ,hot load idle_session_timeout_in_minutes=-1
function testcase11()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   set_params 1
   start_dn_cn_open_separation 
# create user santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase11"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase11"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase11"
# admin hot load
${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "set CONFIGURATION idle_session_timeout_in_minutes='-1';">${current_dir}/tmp.out
check_res "success" 1 "repeate_testcase11"
# santos cli
    # 核心逻辑：通过管道向 CLI 输入命令，延迟在管道中处理
{
  # 等待 CLI 启动并连接（约1-2秒，根据实际情况调整）
  echo "show cluster;"
  # 脚本层延迟1分钟
  sleep 66
  # 延迟后输入目标命令
  echo "show cluster;"
  # 输入退出命令
  echo "exit"
} |${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -u santos > ${current_dir}/tmp.out 2>&1
check_res "802: Log in failed. Either you are not authorized or the session has timed out" 0 "testcase11"
   check_npe "testcase11"
}
# ns
function testcase12()
{
stop_dn_cn
remove_data_logs
copy_conf_from_backup
# change param
v_param_exist=`ssh ${os_name}@${db_ip} "grep timestamp_precision= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   if [[ ${v_param_exist} = 0 ]];then
     ssh ${os_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
     ssh ${os_name}@${db_ip} "echo timestamp_precision=ns >> ${db_dir}/conf/iotdb-system.properties"
   else
     ssh ${os_name}@${db_ip} "sed -i 's/timestamp_precision=.*/timestamp_precision=ns/g' ${db_dir}/conf/iotdb-system.properties"
   fi
   set_params 1
   start_dn_cn_open_separation

# create user santos
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase12"
   ${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "grant system to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase12"
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table -e "grant all on any to user santos;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase12"
# admin hot load
${cli_dir}/sbin/start-cli.sh -u ${db_admin_name} -h ${query_ip} -sql_dialect table -e "set CONFIGURATION idle_session_timeout_in_minutes='-1';">${current_dir}/tmp.out
check_res "success" 1 "repeate_testcase12"
# santos cli
    # 核心逻辑：通过管道向 CLI 输入命令，延迟在管道中处理
{
  # 等待 CLI 启动并连接（约1-2秒，根据实际情况调整）
  echo "show cluster;"
  # 脚本层延迟1分钟
  sleep 66
  # 延迟后输入目标命令
  echo "show cluster;"
  # 输入退出命令
  echo "exit"
} |${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -u santos > ${current_dir}/tmp.out 2>&1
check_res "802: Log in failed. Either you are not authorized or the session has timed out" 0 "testcase12"
check_npe "testcase12"

}

#check conf_backup
ssh ${os_name}@${db_ip} "
  if [ ! -d '${db_dir}/conf_backup' ]; then
    echo 'conf_backup文件夹不存在,exit'
    exit 1
  fi
"

gen_sql
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

echo "SUCCESS TESTCASE ${succ_flag},FAILED TESTCASE ${fail_flag}"
echo "NPE ${log_npe_flag},OTHER FAILED TESTCASE ${repeate_fail_flag},OTHER SUCCESS TESTCASE ${repeate_succ_flag}"
