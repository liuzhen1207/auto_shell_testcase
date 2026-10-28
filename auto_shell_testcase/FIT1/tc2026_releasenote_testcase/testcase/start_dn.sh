#!/bin/bash
cluster_dir="/data2"
cur_cluster="v2082rc3_0212_1606693"
u_name="iotdb"
t1=`date +"%Y_%m_%d_%H_%M_%S"`
function get_datanode_pid()
{
	node=$1
	log_time=`date "+%Y-%m-%d %H:%M:%S"`
	for i in {1..5}
	do
	   res_pid=`ssh ${u_name}@${node} "source /etc/profile;sudo jps|grep -i datanode"`
	   pid=`echo ${res_pid}|awk '{print $1}'`
	   if [[ ${pid} != "" ]];then
		echo "${log_time} ${node} DataNode ${pid}." >> ./log/pid_info.txt
		break
  	   else
		sleep 2

	   fi
        done
}
exec 3<./datanode.txt
while read line <&3
do
   ssh ${u_name}@${line} "source /etc/profile;sudo ${cluster_dir}/${cur_cluster}/sbin/start-datanode.sh -H ${cluster_dir}/${cur_cluster}/${t1}_dn_heapdump.hprof  > /dev/null 2>&1 &"
   sleep 1
done
exec 3<./datanode.txt
while read line <&3
do
        get_datanode_pid ${line}
done

