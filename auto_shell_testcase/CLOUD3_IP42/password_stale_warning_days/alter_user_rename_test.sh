#!/bin/bash
current_dir=$(pwd)
db_dir=/home/cluster/v2091rc5_0417_089c5437/
cli_dir=/home/cluster/v2091rc5_0417_089c5437/
user_name=root
db_ip=172.20.70.42
query_ip=${db_ip}
node_num=2
fail_flag=0
succ_flag=0
log_npe_flag=0
repeate_fail_flag=0
repeate_succ_flag=0
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
	else
	ssh ${user_name}@${db_ip} "sudo rm -rf ${db_dir}/data"
	ssh ${user_name}@${db_ip} "sudo rm -rf ${db_dir}/logs"
	fi
fi
}
function start_dn_cn()
{
special_user=$1
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${user_name}@${db_ip} "${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
else
ssh ${user_name}@${db_ip} "sudo ${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${user_name}@${db_ip} "sudo ${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
fi
# check power
v_power=`ssh ${user_name}@${db_ip} "grep -E '^[[:space:]]*enable_separation_of_powers[[:space:]]*=[[:space:]]*true[[:space:]]*$' ${db_dir}/conf/iotdb-system.properties|wc -l"`
if [[ ${v_power} -gt 0 ]];then
user_name=sys_admin
else
user_name=root

fi
if [ -n "$special_user" ];then
user_name=${special_user}
fi
# check status
while true
do
#
v_running_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${user_name} -e "show cluster;"|grep Running|wc -l`
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
   exp_res_or=$4
   if [ -n "${exp_res_or}" ];then
      v_act_num=`cat ${current_dir}/tmp.out|grep "${exp_res_or}"|wc -l`
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
      return
   fi
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
   v_npe_num=`ssh ${user_name}@${db_ip} "grep NullPointer ${db_dir}/logs/*all*|wc -l"`
   if [[ ${v_npe_num} -gt 0 ]];then
      let log_npe_flag++
      echo "${tc_num} NullPointer : ${v_npe_num}"
      # backup logs
      t=`date +%Y_%m_%d_%H_%M_%S`
      ssh ${user_name}@${db_ip} "cp -rp ${db_dir}/logs ${db_dir}/logs_npe_${t}_${tc_num}"
   fi
}
# enable_separation_of_powers=false , root alter user root rename to security_admin, check userid 
function testcase1()
{
   stop_dn_cn
   remove_data_logs 
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
	   if [[ ${v_param_exist} = 0 ]];then
	     ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=false >> ${db_dir}/conf/iotdb-system.properties"
	   else
	     ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties" 
	   fi
   fi
   start_dn_cn
   # check uid
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "list user;" >${current_dir}/tmp.out
   get_userid "root" "expect"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "alter user root rename to security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "testcase1"
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "list user;" >${current_dir}/tmp.out
   get_userid "security_admin" "actual"
   check_uid "testcase1"
   check_npe "testcase1"
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "drop user santos;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase1"
    
}
# Use the environment from the previous test case, security_admin create user root,root rename self pitt
function testcase2()
{
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "create  user root 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -sql_dialect table -e "grant system to  user root ;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase2"
   ${cli_dir}/sbin/start-cli.sh -u root -h ${query_ip} -sql_dialect table -e "list user ;" >${current_dir}/tmp.out
   get_userid "root" "expect"
   ${cli_dir}/sbin/start-cli.sh -u root -h ${query_ip} -sql_dialect table -e "alter user root rename to pitt;" >${current_dir}/tmp.out
   check_res "success" 1 "testcase2"
   ${cli_dir}/sbin/start-cli.sh -u pitt -h ${query_ip} -sql_dialect table -e "list user ;" >${current_dir}/tmp.out
   get_userid "pitt" "actual"
   check_uid "testcase2"
   check_npe "testcase2"

}
# Use the environment from the previous test case, security_admin rename user who is  not exist 
function testcase3()
{
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "alter  user user_not_exist rename to this_user;" >${current_dir}/tmp.out
   check_res "IoTDBSQLException: 701: User user_not_exist not found" 1 "testcase3"
   check_npe "testcase3"

}

# Use the environment from the previous test case, security_admin create user javadi and virginia ,javadi rename virginia 
function testcase4()
{
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "create  user javadi 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "create  user virginia 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase4"
   ${cli_dir}/sbin/start-cli.sh -u javadi -h ${query_ip} -e "alter user virginia rename to santos;">${current_dir}/tmp.out 
   check_res "IoTDBSQLException: 803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase4"
# javadi has MANAGE_USER priv
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -sql_dialect table -e "grant MANAGE_USER to user javadi;">${current_dir}/tmp.out
   check_res "IoTDBSQLException: 701: Privilege type MANAGE_USER is deprecated, use SECURITY to instead it" 1 "repeate_testcase4"
   ${cli_dir}/sbin/start-cli.sh -u javadi -h ${query_ip} -sql_dialect table -e "alter user virginia rename to santos;">${current_dir}/tmp.out
   check_res "IoTDBSQLException: 803: Access Denied: No permissions for this operation, please add privilege SECURITY" 1 "testcase4"
#   get_userid "santos" "actual"
#   check_uid "testcase4"
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -sql_dialect table -e "revoke MANAGE_USER from user javadi;">${current_dir}/tmp.out
   check_res "IoTDBSQLException: 701: Privilege type MANAGE_USER is deprecated, use SECURITY to instead it" 1 "repeate_testcase4"
}
# Use the environment from the previous test case,  javadi has SECURITY, has priv rename virginia
function testcase5()
{
# javadi has SECURITY priv
   ${cli_dir}/sbin/start-cli.sh -u virginia -h ${query_ip} -sql_dialect table -e "list user;">${current_dir}/tmp.out
   get_userid "virginia" "expect"
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -sql_dialect table -e "grant SECURITY to user javadi;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase5"

   ${cli_dir}/sbin/start-cli.sh -u javadi -h ${query_ip} -sql_dialect table -e "alter user virginia rename to santos;">${current_dir}/tmp.out
   check_res "success" 1 "testcase5"
   ${cli_dir}/sbin/start-cli.sh -u santos -h ${query_ip} -sql_dialect table -e "list user;">${current_dir}/tmp.out
   get_userid "santos" "actual"
   check_uid "testcase5"
   check_npe "testcase5"

}

# Use the environment from the previous test case,  javadi has SECURITY, has not priv rename security_admin 
function testcase6()
{
# javadi has SECURITY priv
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -sql_dialect table -e "list user;">${current_dir}/tmp.out
   get_userid "security_admin" "expect"

   ${cli_dir}/sbin/start-cli.sh -u javadi -h ${query_ip} -sql_dialect table -e "alter user security_admin rename to root;">${current_dir}/tmp.out
   check_res "success" 0 "testcase6"
   echo "testcase6:"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -sql_dialect table -e "list user;">${current_dir}/tmp.out
   get_userid "security_admin" "actual"
   check_uid "testcase6"
   check_npe "testcase6"

}
# Use the environment from the previous test case,  security_admin rename self to root
function testcase7()
{
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -sql_dialect table -e "list user;">${current_dir}/tmp.out
   get_userid "security_admin" "expect"

   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -sql_dialect table -e "alter user security_admin rename to root;">${current_dir}/tmp.out
   check_res "success" 1 "testcase7"
   ${cli_dir}/sbin/start-cli.sh -u root -h ${query_ip} -sql_dialect table -e "list user;">${current_dir}/tmp.out
   get_userid "root" "actual"
   check_uid "testcase7"
   check_npe "testcase7"
}

# Use the environment from the previous test case,  root rename javadi to p00,root rename santos to pitt1234!pitt1234!pitt1234!pitt1234
function testcase8()
{
   ${cli_dir}/sbin/start-cli.sh -u javadi -h ${query_ip} -sql_dialect table -e "list user;">${current_dir}/tmp.out
   get_userid "javadi" "expect"

   ${cli_dir}/sbin/start-cli.sh -u root -h ${query_ip} -sql_dialect table -e "alter user javadi rename to p00;">${current_dir}/tmp.out
   check_res "success" 0 "testcase8"
   ${cli_dir}/sbin/start-cli.sh -u javadi -h ${query_ip} -sql_dialect table -e "list user;">${current_dir}/tmp.out
   get_userid "javadi" "actual"
   check_uid "testcase8"

   ${cli_dir}/sbin/start-cli.sh -u santos -h ${query_ip} -sql_dialect table -e "list user;">${current_dir}/tmp.out
   get_userid "santos" "expect"

   ${cli_dir}/sbin/start-cli.sh -u root -h ${query_ip} -sql_dialect table -e 'alter user santos rename to "pitt1234\!pitt1234\!pitt1234\!pitt1234";'>${current_dir}/tmp.out
   check_res "success" 0 "repeate_testcase8"
   ${cli_dir}/sbin/start-cli.sh -u santos -h ${query_ip} -sql_dialect table -e "list user;">${current_dir}/tmp.out
   get_userid "santos" "actual"
   check_uid "testcase8"
   check_npe "testcase8"
}
# Use the environment from the previous test case, rename username is already exist 
function testcase9()
{

   ${cli_dir}/sbin/start-cli.sh -u root -h ${query_ip} -sql_dialect table -e "drop user javadi;drop user p00;drop user santos;"
   ${cli_dir}/sbin/start-cli.sh -u root -h ${query_ip} -sql_dialect table -e 'drop user "pitt1234\!pitt1234\!pitt1234\!pitt1234";'
   ${cli_dir}/sbin/start-cli.sh -u root -h ${query_ip} -sql_dialect table -e "create user javadi 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase9"
   ${cli_dir}/sbin/start-cli.sh -u root -h ${query_ip} -sql_dialect table -e "create user santos 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase9"

   ${cli_dir}/sbin/start-cli.sh -u root -h ${query_ip} -sql_dialect table -e "alter user javadi rename to santos;">${current_dir}/tmp.out
   check_res "IoTDBSQLException: 805: Cannot rename user javadi to santos, because the target username is already existed" 1 "testcase9"
   ${cli_dir}/sbin/start-cli.sh -u root -h ${query_ip} -sql_dialect table -e "drop user javadi;drop user santos;"

   check_npe "testcase9"

}

# enable_separation_of_powers=true , security_admin alter user self rename to sec_manager, check userid
function testcase10()
{
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=true >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=true/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn
   # check uid
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "list user;" >${current_dir}/tmp.out
   get_userid "security_admin" "expect"
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "alter user security_admin rename to sec_manager;" >${current_dir}/tmp.out
   check_res "success" 1 "testcase10"
   ${cli_dir}/sbin/start-cli.sh -u sec_manager -h ${query_ip} -e "list user;" >${current_dir}/tmp.out
   get_userid "sec_manager" "actual"
   check_uid "testcase10"
   check_npe "testcase10"
   ${cli_dir}/sbin/start-cli.sh -u sec_manager -h ${query_ip} -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase10"
   ${cli_dir}/sbin/start-cli.sh -u sec_manager -h ${query_ip} -e "drop user santos;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase10"

}

# enable_separation_of_powers=true , sec_manager alter user pitt rename to santos, check priv 
function testcase11()
{
   ${cli_dir}/sbin/start-cli.sh -u sec_manager -h ${query_ip} -e "create user pitt 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase11"
   ${cli_dir}/sbin/start-cli.sh -u sec_manager -h ${query_ip} -e "alter user pitt rename to santos;" >${current_dir}/tmp.out
   check_res "success" 1 "testcase11"
# santos rename self
   ${cli_dir}/sbin/start-cli.sh -u sec_manager -h ${query_ip} -e "alter user santos rename to pitt;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase11"

   ${cli_dir}/sbin/start-cli.sh -u sys_admin -h ${query_ip} -sql_dialect table -e "grant system to  user pitt;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase11"
   ${cli_dir}/sbin/start-cli.sh -u pitt -h ${query_ip} -e "list privileges of user pitt;"|grep -v cost >${current_dir}/exp.out
   ${cli_dir}/sbin/start-cli.sh -u sec_manager -h ${query_ip} -e "alter user pitt rename to santos;" >${current_dir}/tmp.out
   check_res "803: No permission to update system admin" 1 "testcase11"
  ${cli_dir}/sbin/start-cli.sh -u sys_admin -h ${query_ip} -e "alter user pitt rename to santos;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase11"
  ${cli_dir}/sbin/start-cli.sh -u pitt -h ${query_ip} -e "alter user pitt rename to santos;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase11"

   ${cli_dir}/sbin/start-cli.sh -u santos -h ${query_ip} -e "list privileges of user santos;"|grep -v cost >${current_dir}/act.out
   v_diff=`diff ${current_dir}/exp.out ${current_dir}/act.out|wc -l`
   if [[ ${v_diff} -gt 0 ]];then
      echo "testcase11 failed."
      let repeate_fail_flag++
      echo "exp:"
      cat ${current_dir}/exp.out
      echo "act:"
      ${current_dir}/act.out
   fi
   check_npe "testcase11"

}

# enable_separation_of_powers=true , sys_admin alter user santos rename to pitt, check priv
function testcase12()
{
   ${cli_dir}/sbin/start-cli.sh -u santos -h ${query_ip} -e "list privileges of user santos;"|grep -v cost >${current_dir}/exp.out
   ${cli_dir}/sbin/start-cli.sh -u sys_admin -h ${query_ip} -e "alter user santos rename to pitt;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "testcase12"
   ${cli_dir}/sbin/start-cli.sh -u santos -h ${query_ip} -e "list privileges of user santos;"|grep -v cost >${current_dir}/act.out
   v_diff=`diff ${current_dir}/exp.out ${current_dir}/act.out|wc -l`
   if [[ ${v_diff} -gt 0 ]];then
      echo "testcase12 failed."
      let repeate_fail_flag++
      echo "exp:"
      cat ${current_dir}/exp.out
      echo "act:"
      ${current_dir}/act.out
   fi
   check_npe "testcase12"

}

# enable_separation_of_powers=true , santos rename self to pitt, check priv
function testcase13()
{
   ${cli_dir}/sbin/start-cli.sh -u santos -h ${query_ip} -e "list privileges of user santos;"|grep -v cost >${current_dir}/exp.out
   ${cli_dir}/sbin/start-cli.sh -u santos -h ${query_ip} -e "alter user santos rename to pitt;" >${current_dir}/tmp.out
   check_res "success" 1 "testcase13"
   ${cli_dir}/sbin/start-cli.sh -u pitt -h ${query_ip} -e "list privileges of user pitt;"|grep -v cost >${current_dir}/act.out
   v_diff=`diff ${current_dir}/exp.out ${current_dir}/act.out|wc -l`
   if [[ ${v_diff} -gt 0 ]];then
      echo "testcase13 failed."
      let repeate_fail_flag++
      echo "exp:"
      cat ${current_dir}/exp.out
      echo "act:"
      ${current_dir}/act.out
   fi
   check_npe "testcase13"

}

# enable_separation_of_powers=true , pitt rename self to virginia,but virginia is already exist
function testcase14()
{
   ${cli_dir}/sbin/start-cli.sh -u sec_manager -h ${query_ip} -e "create user virginia 'TimechoDB@2021';">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase14"
   ${cli_dir}/sbin/start-cli.sh -u pitt -h ${query_ip} -e "list privileges of user pitt;"|grep -v cost >${current_dir}/exp.out
   ${cli_dir}/sbin/start-cli.sh -u pitt -h ${query_ip} -e "alter user pitt rename to virginia;" >${current_dir}/tmp.out
   check_res "805: Cannot rename user pitt to virginia, because the target username is already existed" 1 "testcase14"
   ${cli_dir}/sbin/start-cli.sh -u pitt -h ${query_ip} -e "list privileges of user pitt;"|grep -v cost >${current_dir}/act.out
   v_diff=`diff ${current_dir}/exp.out ${current_dir}/act.out|wc -l`
   if [[ ${v_diff} -gt 0 ]];then
      echo "testcase14 failed."
      let repeate_fail_flag++
      echo "exp:"
      cat ${current_dir}/exp.out
      echo "act:"
      ${current_dir}/act.out
   fi
   check_npe "testcase14"

}

# enable_separation_of_powers=true , sec_manager rename self to security_admin
function testcase15()
{
   ${cli_dir}/sbin/start-cli.sh -u sec_manager -h ${query_ip} -e "list privileges of user sec_manager;"|grep -v cost >${current_dir}/exp.out
   ${cli_dir}/sbin/start-cli.sh -u sec_manager -h ${query_ip} -e "alter user sec_manager rename to security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "testcase15"
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "list privileges of user security_admin;"|grep -v cost >${current_dir}/act.out
   v_diff=`diff ${current_dir}/exp.out ${current_dir}/act.out|wc -l`
   if [[ ${v_diff} -gt 0 ]];then
      echo "testcase15 failed."
      let repeate_fail_flag++
      echo "exp:"
      cat ${current_dir}/exp.out
      echo "act:"
      ${current_dir}/act.out
   fi
   check_npe "testcase15"

}

# enable_separation_of_powers=true , security_admin rename self to virginia , virginia is already exist 
function testcase16()
{
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "list privileges of user security_admin;"|grep -v cost >${current_dir}/exp.out
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "alter user security_admin rename to virginia;" >${current_dir}/tmp.out
   check_res "805: Cannot rename user security_admin to virginia, because the target username is already existed" 1 "testcase16"
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -e "list privileges of user security_admin;"|grep -v cost >${current_dir}/act.out
   v_diff=`diff ${current_dir}/exp.out ${current_dir}/act.out|wc -l`
   if [[ ${v_diff} -gt 0 ]];then
      echo "testcase16 failed."
      let repeate_fail_flag++
      echo "exp:"
      cat ${current_dir}/exp.out
      echo "act:"
      ${current_dir}/act.out
   fi
   check_npe "testcase16"

}

# enable_separation_of_powers=true , virginia has security,rename security_admin to sec_manager expect failed 
function testcase17()
{
   ${cli_dir}/sbin/start-cli.sh -u security_admin -h ${query_ip} -sql_dialect table -e "grant security  to  user virginia;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase17"
   ${cli_dir}/sbin/start-cli.sh -u virginia -h ${query_ip} -e "alter user security_admin rename to virginia;" >${current_dir}/tmp.out
   check_res "803: No permission to update security admin" 1 "repeate_testcase17"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -u virginia -h ${query_ip} -e "alter user security_admin rename to sec_manager;" >${current_dir}/tmp.out
   check_res "803: No permission to update security admin" 1 "testcase17"
   check_npe "testcase17"

}

# enable_separation_of_powers=true , virginia has security,rename no_this_user to new_name 
function testcase18()
{
   ${cli_dir}/sbin/start-cli.sh -u virginia -h ${query_ip} -e "alter user no_this_user  rename to new_name;" >${current_dir}/tmp.out
   check_res "701: User no_this_user not found" 1 "testcase18"
   check_npe "testcase18"

}

# enable_separation_of_powers=true , virginia has security,new_name is illegal
function testcase19()
{
   ${cli_dir}/sbin/start-cli.sh -u virginia -h ${query_ip} -e "alter user pitt  rename to p00;" >${current_dir}/tmp.out
   cat ${current_dir}/tmp.out
   check_res "803: No permission to update system admin" 1 "testcase19"
   ${cli_dir}/sbin/start-cli.sh -u sys_admin -h ${query_ip} -sql_dialect table -e "revoke system from user pitt;">${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase19"
   ${cli_dir}/sbin/start-cli.sh -u virginia -h ${query_ip} -e "alter user pitt  rename to pitt12345pitt12345pitt12345pitt1234;" >${current_dir}/tmp.out
   cat ${current_dir}/tmp.out
   check_res "820: The length of name must be less than or equal to 32" 1 "repeate_testcase19"
   ${cli_dir}/sbin/start-cli.sh -u virginia -h ${query_ip} -e "alter user pitt  rename to p00;" >${current_dir}/tmp.out
   check_res "820: The length of name must be greater than or equal to 4" 1 "testcase19"
   check_npe "testcase19"

}

# enable_separation_of_powers=true , create user security_admin 
function testcase20()
{
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=true >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=true/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -e "alter user security_admin rename to sec_manager;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase20"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "create user security_admin 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "testcase20"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -sql_dialect table -e "grant security to  user security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase20"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -e "drop user sec_manager;" >${current_dir}/tmp.out
   check_res "803: Builtin user is not allowed to be dropped" 1 "repeate_testcase20"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: Access Denied: Cannot drop admin user or yourself" 1 "repeate_testcase20"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase20"

   cat ${current_dir}/tmp.out
   check_npe "testcase20"

}

# enable_separation_of_powers=false ,create user security_admin,drop security_admin 
function testcase21()
{
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=false >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -e "alter user root rename to sec_manager;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase21"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "create user root 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase21"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -sql_dialect table -e "grant security to  user root;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase21"

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -e "drop user sec_manager;" >${current_dir}/tmp.out
   check_res "803: Access Denied: Cannot drop admin user or yourself" 1 "testcase21" 
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -e "drop user root;" >${current_dir}/tmp.out
   check_res "803: Access Denied: Cannot drop admin user or yourself" 1 "repeate_testcase21" 
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "drop user root;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase21"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "alter user sec_manager rename to root;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase21"

   check_npe "testcase21"

}


# enable_separation_of_powers=false ,root rename other name to root 
function testcase22()
{
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=false >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -e "create user javadi 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase22"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -sql_dialect table -e "alter user javadi rename to root;" >${current_dir}/tmp.out
   check_res "805: Cannot rename user javadi to root, because the target username is already existed" 1 "testcase22"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -e "drop user javadi;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase22"
   check_npe "testcase22"

}

# enable_separation_of_powers=false , copy 2.0.6.1 RC8 data 
function testcase23()
{
   stop_dn_cn
   remove_data_logs
   cp -rp ${current_dir}/data ${db_dir}/
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=false >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -e "list user;" >${current_dir}/tmp.out
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -sql_dialect table -e "list user;" >${current_dir}/tmp.out
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u hr_tree -e "create user javadi 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase23"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u hr_table -sql_dialect table -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase23"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u all_priv_tree_user -e "select s0,s1,s2,s3,s4,s5,s6,s7,s8,s9,s10,c0,c1,c2,c3 from root.db.** align by device;" |grep -v cost>${current_dir}/exp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u hr_tree -e "alter user all_priv_tree_user rename to lily;"
   check_res "success" 1 "testcase23"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u lily -e "select s0,s1,s2,s3,s4,s5,s6,s7,s8,s9,s10,c0,c1,c2,c3 from root.db.** align by device;" |grep -v cost>${current_dir}/act.out
   v_diff=`diff ${current_dir}/exp.out ${current_dir}/act.out|wc -l`
   if [[ ${v_diff} -gt 0 ]];then
      echo "testcase23 failed."
      let repeate_fail_flag++
      cat ${current_dir}/exp.out
      cat ${current_dir}/act.out
   fi

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u all_priv_table_user -sql_dialect table -e "select time,device_id,id,name from test.t1;" |grep -v cost>${current_dir}/exp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u hr_table -sql_dialect table -e "alter user all_priv_table_user rename to lucy;"
   check_res "success" 1 "repeate_testcase23"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u lucy -sql_dialect table -e "select time,device_id,id,name from test.t1;" |grep -v cost>${current_dir}/act.out
   v_diff=`diff ${current_dir}/exp.out ${current_dir}/act.out|wc -l`
   if [[ ${v_diff} -gt 0 ]];then
      echo "testcase23 failed."
      let repeate_fail_flag++
      cat ${current_dir}/exp.out
      cat ${current_dir}/act.out
   fi

   check_npe "testcase23"

}

# enable_separation_of_powers=true , copy 2.0.6.1 RC8 data
function testcase24()
{
   stop_dn_cn
   remove_data_logs
   cp -rp ${current_dir}/data ${db_dir}/
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=true >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=true/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn root

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -e "list user;" >${current_dir}/tmp.out
   check_res "804: Authentication failed" 1 "repeate_testcase24"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -sql_dialect table -e "list user;" >${current_dir}/tmp.out
   check_res "804: Authentication failed" 1 "repeate_testcase24"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u hr_tree -e "create user javadi 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase24"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u hr_table -sql_dialect table -e "create user santos 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase24"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u all_priv_tree_user -e "select s0,s1,s2,s3,s4,s5,s6,s7,s8,s9,s10,c0,c1,c2,c3 from root.db.** align by device;" |grep -v cost>${current_dir}/exp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u hr_tree -e "alter user all_priv_tree_user rename to lily;"
   check_res "success" 1 "testcase24"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u lily -e "select s0,s1,s2,s3,s4,s5,s6,s7,s8,s9,s10,c0,c1,c2,c3 from root.db.** align by device;" |grep -v cost>${current_dir}/act.out
   v_diff=`diff ${current_dir}/exp.out ${current_dir}/act.out|wc -l`
   if [[ ${v_diff} -gt 0 ]];then
      echo "testcase24 failed."
      let repeate_fail_flag++
      cat ${current_dir}/exp.out
      cat ${current_dir}/act.out
   fi

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u all_priv_table_user -sql_dialect table -e "select time,device_id,id,name from test.t1;" |grep -v cost>${current_dir}/exp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u hr_table -sql_dialect table -e "alter user all_priv_table_user rename to lucy;"
   check_res "success" 1 "repeate_testcase24"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u lucy -sql_dialect table  -e "select time,device_id,id,name from test.t1;" |grep -v cost>${current_dir}/act.out
   v_diff=`diff ${current_dir}/exp.out ${current_dir}/act.out|wc -l`
   if [[ ${v_diff} -gt 0 ]];then
      echo "testcase24 failed."
      let repeate_fail_flag++
      cat ${current_dir}/exp.out
      cat ${current_dir}/act.out
   fi

   check_npe "testcase24"

}

function testcase25_issue0616()
{
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=false >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u user_is_not_exist -e "show cluster;"
   check_npe "testcase25_issue0616"

}

function testcase26_issue0619()
{
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=true>> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=true/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -sql_dialect table -e "grant security to user virginia;"
   check_npe "testcase26_issue0619"
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=false>> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -sql_dialect table -e "grant all to user virginia;"
   check_npe "testcase26_issue0619"

}

# enable_separation_of_powers=false ,create user security_admin,drop security_admin its has audit
function testcase27()
{
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=false >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -e "alter user root rename to sec_manager;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase27"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "create user root 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase27"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -sql_dialect table -e "grant audit to  user root;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase27"

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -e "drop user sec_manager;" >${current_dir}/tmp.out
   check_res "803: Builtin user is not allowed to be dropped" 1 "testcase27" "803: No permissions for this operation, please add privilege SECURITY"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "drop user root;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase27"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "alter user sec_manager rename to root;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase27"

   check_npe "testcase27"

}

# enable_separation_of_powers=false ,create user security_admin,drop security_admin its has system 
function testcase28()
{
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=false >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=false/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -e "alter user root rename to sec_manager;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase28"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "create user root 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase28"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -sql_dialect table -e "grant system to  user root;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase28"

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u root -e "drop user sec_manager;" >${current_dir}/tmp.out
   check_res "803: Builtin user is not allowed to be dropped" 1 "testcase28" "803: No permissions for this operation, please add privilege SECURITY"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "drop user root;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase28"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "alter user sec_manager rename to root;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase28"

   check_npe "testcase28"

}

# enable_separation_of_powers=true,create user security_admin,drop security_admin its has system
function testcase29()
{
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=true >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=true/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -e "alter user security_admin rename to sec_manager;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase29"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "create user security_admin 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase29"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sys_admin -sql_dialect table -e "grant system to  user security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase29"

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sys_admin -e "drop user sys_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "testcase29"
   cat ${current_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permission to drop system admin" 1 "repeate_testcase29"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sys_admin -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase29"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u audit_admin -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase29"

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase29"

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sys_admin -sql_dialect table -e "revoke system  from user security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase29"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u audit_admin -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase29"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sys_admin -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase29"

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase29"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase29"

   check_npe "testcase29"

}

# enable_separation_of_powers=true,create user security_admin,drop security_admin its has security 
function testcase30()
{
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=true >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=true/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -e "alter user security_admin rename to sec_manager;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase30"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "create user security_admin 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase30"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -sql_dialect table -e "grant security to  user security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase30"

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "drop user sec_manager;" >${current_dir}/tmp.out
   check_res "803: Access Denied: Cannot drop admin user or yourself" 1 "testcase30"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sys_admin -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase30"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u audit_admin -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase30"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase30"


   check_npe "testcase30"

}

# enable_separation_of_powers=true,create user security_admin,drop security_admin its has audit 
function testcase31()
{
   stop_dn_cn
   remove_data_logs
   v_param_exist=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers= ${db_dir}/conf/iotdb-system.properties|wc -l"`
   v_param_exist_support=`ssh ${user_name}@${db_ip} "grep enable_separation_of_powers ${db_dir}/conf/iotdb-system.properties.template|wc -l"`
   if [[ ${v_param_exist_support} -gt 0 ]];then
           if [[ ${v_param_exist} = 0 ]];then
             ssh ${user_name}@${db_ip} "echo enable_separation_of_powers=true >> ${db_dir}/conf/iotdb-system.properties"
           else
             ssh ${user_name}@${db_ip} "sed -i 's/enable_separation_of_powers=.*/enable_separation_of_powers=true/g' ${db_dir}/conf/iotdb-system.properties"
           fi
   fi
   start_dn_cn

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u security_admin -e "alter user security_admin rename to sec_manager;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase31"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "create user security_admin 'TimechoDB@2021';" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase31"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u audit_admin -sql_dialect table -e "grant audit to  user security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase31"

   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u audit_admin -e "drop user audit_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "testcase31"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sys_admin -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase31"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u audit_admin -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permissions for this operation, please add privilege SECURITY" 1 "repeate_testcase31"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "803: No permission to drop audit admin" 1 "repeate_testcase31"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u audit_admin -sql_dialect table -e "revoke audit from  user security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase31"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u sec_manager -e "drop user security_admin;" >${current_dir}/tmp.out
   check_res "success" 1 "repeate_testcase31"
   check_npe "testcase31"

}


#testcase1
#testcase2
#testcase3
#testcase4
#testcase5
#testcase6
#testcase7
#testcase8
#testcase9
testcase10
testcase11
#testcase12
#testcase13
#testcase14
#testcase15
#testcase16
#testcase17
#testcase18
#testcase19
#testcase20
#testcase21
#testcase22
#testcase23
#testcase24
#testcase25_issue0616
#testcase26_issue0619
#testcase27
#testcase28
#testcase29
#testcase30
#testcase31
echo "SUCCESS TESTCASE ${succ_flag},FAILED TESTCASE ${fail_flag}"
echo "NPE ${log_npe_flag},OTHER FAILED TESTCASE ${repeate_fail_flag},OTHER SUCC TESTCASE ${repeate_succ_flag}"
