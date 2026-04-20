#!/bin/bash
current_dir=$(pwd)
db_dir=/home/cluster/v2091rc5_0417_089c5437/
cli_dir=/home/cluster/v2091rc5_0417_089c5437/
ssl_str="-usessl true -ts ${cli_dir}/.truststore -tpw TimechoDB"
user_name=root
db_ip=172.20.70.42
query_ip=${db_ip}
node_num=2
fail_flag=0
succ_flag=0
repeate_fail_flag=0
repeate_succ_flag=0

log_npe_flag=0
function stop_dn_cn()
{
if [[ ${user_name} = root ]];then

ssh ${user_name}@${db_ip} "${db_dir}/sbin/stop-datanode.sh"
sleep 3
ssh ${user_name}@${db_ip} "${db_dir}/sbin/stop-confignode.sh"
else
ssh ${user_name}@${db_ip} "sudo ${db_dir}/sbin/stop-datanode.sh"
sleep 3
ssh ${user_name}@${db_ip} "sudo ${db_dir}/sbin/stop-confignode.sh"
fi
# check jps
while true
do
if [[ ${user_name} = root ]];then
v_jps_node=`ssh ${user_name}@${db_ip} "jps|grep Node|wc -l"`
else
v_jps_node=`ssh ${user_name}@${db_ip} "sudo jps|grep Node|wc -l"`
fi
if [[ ${v_jps_node} -gt 0 ]];then
sleep 1
else
break
fi
done
}
function remove_data_logs()
{
if [[ -n "${db_dir}" ]]; then
	if [[ ${user_name} = root ]];then

	ssh ${user_name}@${db_ip} "rm -rf ${db_dir}/data"
	ssh ${user_name}@${db_ip} "rm -rf ${db_dir}/logs"
        ssh ${user_name}@${db_ip} "rm -rf ${db_dir}/conf"
	else
	ssh ${user_name}@${db_ip} "sudo rm -rf ${db_dir}/data"
	ssh ${user_name}@${db_ip} "sudo rm -rf ${db_dir}/logs"
        ssh ${user_name}@${db_ip} "sudo rm -rf ${db_dir}/conf"
	fi
fi
}
# function cp -rp conf
function copy_conf_from_backup()
{
ssh ${user_name}@${db_ip} "
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
ssh ${user_name}@${db_ip} "
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
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${user_name}@${db_ip} "${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
else
ssh ${user_name}@${db_ip} "sudo ${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${user_name}@${db_ip} "sudo ${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
fi
user_name=sys_admin

if [ -n "$special_user" ];then
user_name=${special_user}
fi
# check status
while true
do
#
v_running_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${user_name} ${ssl_str} -e "show cluster;"|grep Running|wc -l`
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

   ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties"

}

function start_dn_cn_close_separation()
{
special_user=$1
ssh ${user_name}@${db_ip} "
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
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${user_name}@${db_ip} "${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
else
ssh ${user_name}@${db_ip} "sudo ${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${user_name}@${db_ip} "sudo ${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
fi
user_name=root
if [ -n "$special_user" ];then
user_name=${special_user}
fi
# check status
while true
do
#
v_running_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${user_name} ${ssl_str} -e "show cluster;"|grep Running|wc -l`
if [[ ${v_running_num} -lt ${node_num} ]];then
sleep 1
else
break
fi
done
user_name=root
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
function check_npe()
{
   tc_num=$1
   v_npe_num=`ssh ${user_name}@${db_ip} "grep NullPointer ${db_dir}/logs/*all*|wc -l"`
   if [[ ${v_npe_num} -gt 0 ]];then
      let log_npe_flag++
      echo "${tc_num} NullPointer : ${v_npe_num}"
      # backup logs
      t=`date +%Y_%m_%d_%H_%M_%S`
      ssh ${user_name}@${db_ip} "cp -rp ${db_dir}/logs ${db_dir}/logs_npe_${t}_${tc_num}"
   fi
}

# testcase1 password_stale_warning_days=1 new user first login ,no tips
function testcase1()
{
   stop_dn_cn
   remove_data_logs
   copy_conf_from_backup
   v_param_exist=`ssh ${user_name}@${db_ip} "grep password_stale_warning_days= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   if [[ ${v_param_exist} = 0 ]];then
     ssh ${user_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
     ssh ${user_name}@${db_ip} "echo password_stale_warning_days=1 >> ${db_dir}/conf/iotdb-system.properties"
   else
     ssh ${user_name}@${db_ip} "sed -i 's/password_stale_warning_days=.*/password_stale_warning_days=1/g' ${db_dir}/conf/iotdb-system.properties" 
   fi
   start_dn_cn_open_separation 
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} ${ssl_str} -e "create user pitt 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
#   cat ${current_dir}/tmp.out 
   check_res "Your password has not been changed for over 1 days" 0 "testcase1"
   check_res "Empty set" 1 "repeate_testcase1"
}
# os time +2d
function testcase2_3_4_5()
{
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"+1 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"+1 day\""
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
#cat ${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 1 "testcase2"

# testcase 3,if do not change password ,repeate receive tips
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 1 "testcase3"
# testcase 4 ,alter password,no tips
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "alter user pitt set password 'TimechoDB@2022';" >${current_dir}/tmp.out
check_res "success" 1 "testcase4"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2022 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 0 "repeate_testcase2_3_4_5"

# drop user,create ,no warning
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"+1 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"+1 day\""
fi
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2022 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 1 "repeate_testcase2_3_4_5"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 1 "repeate_testcase2_3_4_5"
check_res "success" 1 "repeate_testcase2_3_4_5"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "create user pitt 'TimechoDB@2021';" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 1 "repeate_testcase2_3_4_5"
check_res "success" 1 "repeate_testcase2_3_4_5"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 0 "testcase5"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 1 "repeate_testcase5"
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"-2 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"-2 day\""
fi
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 0 "repeate_testcase2_3_4_5"
check_res "success" 1 "repeate_testcase2_3_4_5"

}
# os time +1d,has warning,set -1,restart,no warning
function testcase6()
{
   stop_dn_cn
   remove_data_logs
   copy_conf_from_backup
   v_param_exist=`ssh ${user_name}@${db_ip} "grep password_stale_warning_days= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   if [[ ${v_param_exist} = 0 ]];then
     ssh ${user_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
     ssh ${user_name}@${db_ip} "echo password_stale_warning_days=1 >> ${db_dir}/conf/iotdb-system.properties"
   else
     ssh ${user_name}@${db_ip} "sed -i 's/password_stale_warning_days=.*/password_stale_warning_days=1/g' ${db_dir}/conf/iotdb-system.properties"
   fi
   start_dn_cn_open_separation

# drop user,create user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "create user pitt 'TimechoDB@2021';" >${current_dir}/tmp.out
check_res "success" 1 "repeate_testcase6"
# os +1
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"+1 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"+1 day\""
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
cat ${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 1 "repeate_testcase6"
#check_res "Running" 2 "repeate_testcase6"
# change param
#v_param_exist=`ssh ${user_name}@${db_ip} "grep password_stale_warning_days= ${db_dir}/conf/iotdb-system.properties|wc -l"`
#   if [[ ${v_param_exist} = 0 ]];then
#     ssh ${user_name}@${db_ip} "echo password_stale_warning_days=-1 >> ${db_dir}/conf/iotdb-system.properties"
#   else
#     ssh ${user_name}@${db_ip} "sed -i 's/password_stale_warning_days=.*/password_stale_warning_days=-1/g' ${db_dir}/conf/iotdb-system.properties"
#   fi
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 -sql_dialect table  ${ssl_str} -e "set configuration password_stale_warning_days='-1';" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 1 "repeate_testcase6"
check_res "success" 1 "repeate_testcase6"
# restart_dn_cn
stop_dn_cn
start_dn_cn_open_separation
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 0 "testcase6"
#check_res "Running" 2 "repeate_testcase6"

# drop test user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 1 days" 0 "testcase6"
check_res "success" 1 "repeate_testcase6"

if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"-1 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"-1 day\""
fi

}

# os time+30d, default value test
function testcase7()
{
stop_dn_cn
remove_data_logs
copy_conf_from_backup
# change param
v_param_exist=`ssh ${user_name}@${db_ip} "grep password_stale_warning_days= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   if [[ ${v_param_exist} = 0 ]];then
     ssh ${user_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
     ssh ${user_name}@${db_ip} "echo password_stale_warning_days=30 >> ${db_dir}/conf/iotdb-system.properties"
   else
     ssh ${user_name}@${db_ip} "sed -i 's/password_stale_warning_days=.*/password_stale_warning_days=30/g' ${db_dir}/conf/iotdb-system.properties"
   fi
start_dn_cn_open_separation
# drop user,create user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "create user pitt 'TimechoDB@2021';" >${current_dir}/tmp.out
check_res "success" 1 "repeate_testcase7"
# os +30d
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"+30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"+30 day\""
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "testcase7"
check_res "Empty set" 1 "repeate_testcase7"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate_testcase7"

# drop test user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;" >${current_dir}/tmp.out
check_res "success" 1 "repeate_testcase7"

if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"-30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"-30 day\""
fi

}

# os time+1d,value = 0 
function testcase8()
{
stop_dn_cn
remove_data_logs
copy_conf_from_backup
# change param
v_param_exist=`ssh ${user_name}@${db_ip} "grep password_stale_warning_days= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   if [[ ${v_param_exist} = 0 ]];then
     ssh ${user_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
     ssh ${user_name}@${db_ip} "echo password_stale_warning_days=0 >> ${db_dir}/conf/iotdb-system.properties"
   else
     ssh ${user_name}@${db_ip} "sed -i 's/password_stale_warning_days=.*/password_stale_warning_days=0/g' ${db_dir}/conf/iotdb-system.properties"
   fi
start_dn_cn_open_separation
# drop user,create user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "create user pitt 'TimechoDB@2021';" >${current_dir}/tmp.out
check_res "success" 1 "repeate_testcase8"
# os +1d
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"+30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"+30 day\""
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over" 0 "testcase8"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over" 0 "repeate_testcase8"
check_res "Empty set" 1 "repeate_testcase8"

# drop test user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;" >${current_dir}/tmp.out
check_res "success" 1 "repeate_testcase8"
check_res "Your password has not been changed for over" 0 "repeate_testcase8"

if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"-30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"-30 day\""
fi

}

# os time+1d,alter user name
function testcase9()
{
stop_dn_cn
remove_data_logs
copy_conf_from_backup
# change param
v_param_exist=`ssh ${user_name}@${db_ip} "grep password_stale_warning_days= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   if [[ ${v_param_exist} = 0 ]];then
     ssh ${user_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
     ssh ${user_name}@${db_ip} "echo password_stale_warning_days=30 >> ${db_dir}/conf/iotdb-system.properties"
   else
     ssh ${user_name}@${db_ip} "sed -i 's/password_stale_warning_days=.*/password_stale_warning_days=30/g' ${db_dir}/conf/iotdb-system.properties"
   fi
start_dn_cn_open_separation
# drop user,create user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "create user pitt 'TimechoDB@2021';" >${current_dir}/tmp.out
check_res "success" 1 "repeate"
# os +1d
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"+30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"+30 day\""
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate"
check_res "Empty set" 1 "repeate_testcase9"
# alter user pitt rename to 
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "alter user pitt rename to santos;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u santos -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user santos;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "testcase9"
check_res "Empty set" 1 "repeate_testcase9"

# drop test user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;" >${current_dir}/tmp.out
check_res "success" 0 "repeate"
check_res "Your password has not been changed for over 30 days" 1 "repeate_testcase9"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user santos;" >${current_dir}/tmp.out
check_res "success" 1 "repeate"
check_res "Your password has not been changed for over 30 days" 1 "repeate_testcase9"


if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"-30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"-30 day\""
fi

}

# os time+1d,alter password the same as last time 
function testcase10()
{
stop_dn_cn
remove_data_logs
copy_conf_from_backup
**1. 从iotdb-system.properties中提取配置**
ssh "${user_name}@${db_ip}" "grep password_reuse_interval_days ${db_dir}/conf/iotdb-system.properties" > "${current_dir}/tmp.out"

#2. 检查文件是否为空（语法修正：[]两边加空格）**
if [ ! -s "${current_dir}/tmp.out" ]; then
    #3. 从template文件中提取配置**
    ssh "${user_name}@${db_ip}" "grep password_reuse_interval_days ${db_dir}/conf/iotdb-system.properties.template" > "${current_dir}/tmp.out"

    #4. 再次检查template结果（语法修正：[]两边加空格）**
    if [ ! -s "${current_dir}/tmp.out" ]; then
        #默认值-1，标记为成功（v_reuse_succ=1）**
        v_reuse_succ=1
    else
        #提取配置值（语法修正：用$()代替`，去掉变量转义）**
        v_reuse_value=$(cat "${current_dir}/tmp.out" | awk -F '=' '{print $2}')
        #条件判断（语法修正：[[两边加空格）**
        if [[ "${v_reuse_value}" -gt 0 ]]; then
            v_reuse_succ=0
        else
            v_reuse_succ=1
        fi
    fi
else
    #提取配置值（语法修正：用$()代替`，去掉变量转义）**
    v_reuse_value=$(cat "${current_dir}/tmp.out" | awk -F '=' '{print $2}')
    #条件判断（语法修正：[[两边加空格）**
    if [[ "${v_reuse_value}" -gt 0 ]]; then
        v_reuse_succ=0
    else
        v_reuse_succ=1
    fi
fi

# change param
v_param_exist=`ssh ${user_name}@${db_ip} "grep password_stale_warning_days= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   if [[ ${v_param_exist} = 0 ]];then
     ssh ${user_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
     ssh ${user_name}@${db_ip} "echo password_stale_warning_days=30 >> ${db_dir}/conf/iotdb-system.properties"
   else
     ssh ${user_name}@${db_ip} "sed -i 's/password_stale_warning_days=.*/password_stale_warning_days=30/g' ${db_dir}/conf/iotdb-system.properties"
   fi
start_dn_cn_open_separation
# drop user,create user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "create user pitt 'TimechoDB@2021';" >${current_dir}/tmp.out
check_res "success" 1 "repeate"
# os +1d
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"+30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"+30 day\""
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate_testcase10"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "alter user pitt  set  password 'TimechoDB@2021';" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate_testcase10"
check_res "success" ${v_reuse_succ} "repeate"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
if [[ ${v_reuse_succ} -gt 0 ]];then
check_res "Your password has not been changed for over 30 days" 0 "testcase10"
else
check_res "Your password has not been changed for over 30 days" 1 "testcase10"
fi

# drop test user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;" >${current_dir}/tmp.out
check_res "success" 1 "repeate_testcase10"

if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"-30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"-30 day\""
fi

}

# os time+1d,alter user password failed 
function testcase11()
{
stop_dn_cn
remove_data_logs
copy_conf_from_backup
# change param
v_param_exist=`ssh ${user_name}@${db_ip} "grep password_stale_warning_days= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   if [[ ${v_param_exist} = 0 ]];then
     ssh ${user_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
     ssh ${user_name}@${db_ip} "echo password_stale_warning_days=30 >> ${db_dir}/conf/iotdb-system.properties"
   else
     ssh ${user_name}@${db_ip} "sed -i 's/password_stale_warning_days=.*/password_stale_warning_days=30/g' ${db_dir}/conf/iotdb-system.properties"
   fi
start_dn_cn_open_separation
# drop user,create user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "create user pitt 'TimechoDB@2021';" >${current_dir}/tmp.out
check_res "success" 1 "repeate"
# os +1d
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"+30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"+30 day\""
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate_testcase11"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "alter user pitt set password '123';" >${current_dir}/tmp.out
check_res "The length of password must be greater than or equal to 12" 1 "repeate_testcase11"

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "testcase11"
check_res "Empty set" 1 "repeate_testcase11"

# drop test user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate_testcase11"
check_res "success" 1 "repeate"

if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"-30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"-30 day\""
fi

}
# upgrade data
function testcase12()
{
   stop_dn_cn
   remove_data_logs
copy_conf_from_backup
   cp -rp ${current_dir}/data ${db_dir}/
   start_dn_cn_open_separation root 
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root ${ssl_str} -e "list user;" >${current_dir}/tmp.out
   check_res "hr_tree" 1 "repeate"
   check_res "all_priv_tree_user" 1 "repeate"
   check_res "all_priv_table_user" 1 "repeate"
   check_res "hr_table" 1 "repeate"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -sql_dialect table ${ssl_str} -e "list user;" >${current_dir}/tmp.out
   check_res "hr_tree" 1 "repeate"
   check_res "all_priv_tree_user" 1 "repeate"
   check_res "all_priv_table_user" 1 "repeate"
   check_res "hr_table" 1 "repeate"
 
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u all_priv_tree_user ${ssl_str} -e "select s0,s1,s2,s3,s4,s5,s6,s7,s8,s9,s10,c0,c1,c2,c3 from root.db.** align by device;" |grep -v cost>${current_dir}/tmp.out
   cat ${current_dir}/tmp.out
   check_res "Total line number = 15" 1 "repeate"

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u all_priv_table_user -sql_dialect table ${ssl_str} -e "select time,device_id,id,name from test.t1;" |grep -v cost>${current_dir}/tmp.out
   cat ${current_dir}/tmp.out
   check_res "Total line number = 2" 1 "repeate"
  # os +30d
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"+30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"+30 day\""
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u all_priv_tree_user ${ssl_str} -e "select s0,s1,s2,s3,s4,s5,s6,s7,s8,s9,s10,c0,c1,c2,c3 from root.db.** align by device;" |grep -v cost>${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "testcase12"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u all_priv_table_user -sql_dialect table ${ssl_str} -e "select time,device_id,id,name from test.t1;" |grep -v cost>${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate_testcase12" 
check_npe "testcase12"
  # os +30d
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"-30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"-30 day\""
fi

}
# ns,os time+1d,alter user name
function testcase13()
{
stop_dn_cn
remove_data_logs
copy_conf_from_backup
# change param
v_param_exist=`ssh ${user_name}@${db_ip} "grep password_stale_warning_days= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   if [[ ${v_param_exist} = 0 ]];then
     ssh ${user_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
     ssh ${user_name}@${db_ip} "echo password_stale_warning_days=30 >> ${db_dir}/conf/iotdb-system.properties"
   else
     ssh ${user_name}@${db_ip} "sed -i 's/password_stale_warning_days=.*/password_stale_warning_days=30/g' ${db_dir}/conf/iotdb-system.properties"
   fi
v_param_exist=`ssh ${user_name}@${db_ip} "grep timestamp_precision= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   if [[ ${v_param_exist} = 0 ]];then
     ssh ${user_name}@${db_ip} "echo \"\" >> ${db_dir}/conf/iotdb-system.properties"
     ssh ${user_name}@${db_ip} "echo timestamp_precision=ns >> ${db_dir}/conf/iotdb-system.properties"
   else
     ssh ${user_name}@${db_ip} "sed -i 's/timestamp_precision=.*/timestamp_precision=ns/g' ${db_dir}/conf/iotdb-system.properties"
   fi

start_dn_cn_open_separation
# drop user,create user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;">${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 0 "testcase13"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "create user pitt 'TimechoDB@2021';" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 0 "repeate"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 0 "repeate"

# os +30d
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"+30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"+30 day\""
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "show cluster;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user pitt;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate"
check_res "Empty set" 1 "repeate"
# alter user pitt rename to
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "alter user pitt rename to santos;">${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate"
check_res "success" 1 "repeate"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u santos -pw TimechoDB@2021 ${ssl_str} -e "list privileges of user santos;" >${current_dir}/tmp.out
check_res "Your password has not been changed for over 30 days" 1 "repeate"
check_res "Empty set" 1 "repeate"

# drop test user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user pitt;" >${current_dir}/tmp.out
check_res "success" 0 "repeate"
check_res "Your password has not been changed for over 30 days" 1 "repeate"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -pw TimechoDB@2021 ${ssl_str} -e "drop user santos;" >${current_dir}/tmp.out
check_res "success" 1 "repeate"
check_res "Your password has not been changed for over 30 days" 1 "repeate"


if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "date -s \"-30 day\""
else
ssh ${user_name}@${db_ip} "sudo date -s \"-30 day\""
fi
# delete =ns
sed -i '/timestamp_precision=/d' ${db_dir}/conf/iotdb-system.properties
check_npe testcase13
}
#check conf_backup
ssh ${user_name}@${db_ip} "
  if [ ! -d '${db_dir}/conf_backup' ]; then
    echo 'conf_backup文件夹不存在,exit'
    exit 1
  fi
"

testcase1
testcase2_3_4_5
testcase6
testcase7
testcase8
testcase9 
testcase10
testcase11
testcase12
testcase13
echo "SUCCESS TESTCASE ${succ_flag},FAILED TESTCASE ${fail_flag}"
echo "NPE ${log_npe_flag},OTHER FAILED TESTCASE ${repeate_fail_flag},OTHER SUCCESS TESTCASE ${repeate_succ_flag}"
