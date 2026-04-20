#!/bin/bash
current_dir=$(pwd)
db_dir=/home/cluster/v2091rc5_0417_089c5437/
cli_dir=/home/cluster/v2091rc5_0417_089c5437/
user_name=root
db_ip=172.20.70.42
query_ip=${db_ip}
node_num=2
fail_flag=0
repeate_fail_flag=0
succ_flag=0
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
if [[ ${user_name} = root ]];then
ssh ${user_name}@${db_ip} "${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${user_name}@${db_ip} "${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
else
ssh ${user_name}@${db_ip} "sudo ${db_dir}/sbin/start-confignode.sh >/dev/null 2>&1 &"
sleep 3
ssh ${user_name}@${db_ip} "sudo ${db_dir}/sbin/start-datanode.sh >/dev/null 2>&1 &"
fi
# check status
while true
do
v_running_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "show cluster;"|grep Running|wc -l`
if [[ ${v_running_num} -lt ${node_num} ]];then
sleep 1
else
break
fi
done
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

# testcase1 connect server is down or ip is not right 
function testcase1()
{
   stop_dn_cn
   remove_data_logs
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} >${current_dir}/tmp.out  2>&1 
   check_res "Error: Connection Error, please check whether the network is available or the server has started." 1 "testcase1"
 # ip does not exist
   ${cli_dir}/sbin/start-cli.sh -h 172.20.70.214 >${current_dir}/tmp.out  2>&1 
   check_res "Error: Connection Error, please check whether the network is available or the server has started." 1 "repeate_testcase1"
}
# sql_dialect table
function testcase2()
{
   stop_dn_cn
   remove_data_logs
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table >${current_dir}/tmp.out  2>&1
   check_res "Error: Connection Error, please check whether the network is available or the server has started." 1 "testcase2"
 # ip does not exist
   ${cli_dir}/sbin/start-cli.sh -h 172.20.70.214 -sql_dialect table >${current_dir}/tmp.out  2>&1
   check_res "Error: Connection Error, please check whether the network is available or the server has started." 1 "repeate_testcase2"
}

# testcase3 start dn cn port is wrong 
function testcase3()
{
   stop_dn_cn
   remove_data_logs
   start_dn_cn
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -p 6677 >${current_dir}/tmp.out  2>&1
   check_res "Error: Connection Error, please check whether the network is available or the server has started." 1 "testcase3"
}
# testcase4 sql_dialect table start dn cn port is wrong
function testcase4()
{
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -p 6677 -sql_dialect table >${current_dir}/tmp.out  2>&1
   check_res "Error: Connection Error, please check whether the network is available or the server has started." 1 "testcase4"
}
# testcase5 pitt connect wrong port
function testcase5()
{
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "drop user pitt;" 
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "create user pitt 'TimechoDB@2021';" 
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -p 6677 -sql_dialect table >${current_dir}/tmp.out  2>&1
   check_res "Error: Connection Error, please check whether the network is available or the server has started." 1 "testcase5"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u pitt -p 6677 -sql_dialect tree >${current_dir}/tmp.out  2>&1
   check_res "Error: Connection Error, please check whether the network is available or the server has started." 1 "repeate_testcase5"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "drop user pitt;" 

}



testcase1
testcase2
testcase3
testcase4
testcase5
echo "SUCCESS TESTCASE ${succ_flag},FAILED TESTCASE ${fail_flag}"
echo "OTHER CHECK FAILED TESTCASE ${repeate_fail_flag}"
