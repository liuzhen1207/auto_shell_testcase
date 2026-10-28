#!/bin/bash
node1="192.168.130.2"
node2="192.168.130.3"
node3="192.168.130.4"
cluster_dir="/data2"
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
cur_cluster="v2082rc3_0212_1606693"
u_name="iotdb"
license_dir=/ssd/license_20250619/
function get_confignode_pid()
{
	log_time=`date "+%Y-%m-%d %H:%M:%S"`
	node=$1
	for i in {1..5}
	do
	   res_pid=`ssh ${u_name}@${node} "source /etc/profile;sudo jps|grep -i confignode"`
	   pid=`echo ${res_pid}|awk '{print $1}'`
	   if [[ ${pid} != "" ]];then
		echo "${log_time} ${node} ConfigNode ${pid}."
		break
  	   else
		sleep 2

	   fi
        done
}

exec 3<./confignode.txt
while read line <&3
do
   if [[ "${line}" = "192.168.130.1" ]];then	
	   cp -rp ${cur_dir}/license_ip1/timecho_license_new ${cluster_dir}/${cur_cluster}/activation/license
	   cp -rp ${cur_dir}/license_ip1/.env ${cluster_dir}/${cur_cluster}/
   fi
if ssh ${u_name}@${line} test -f ${cluster_dir}/${cur_cluster}/activation/license; then
echo "license is exist."
else
   if ssh ${u_name}@${line} test -f ${license_dir}/license; then
      ssh ${u_name}@${line} "cp -rp ${license_dir}/license ${cluster_dir}/${cur_cluster}/activation/license"
      ssh ${u_name}@${line} "sudo cp -rp ${license_dir}/.env ${cluster_dir}/${cur_cluster}/"
   fi
fi

	ssh ${u_name}@${line} "source /etc/profile;sudo ${cluster_dir}/${cur_cluster}/sbin/start-confignode.sh > /dev/null 2>&1 &"
sleep 2
done

exec 3<./confignode.txt
while read line <&3
do
	get_confignode_pid ${line}
done
