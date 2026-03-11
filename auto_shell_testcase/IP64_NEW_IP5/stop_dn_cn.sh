#!/bin/bash
cluster_dir="/data/liuzhen_test"
cur_cluster="v2081_release_version"
u_name="liuzhen"
clean_data_logs="$2"
desc=$1

if [[ "$#" = "0" ]];then
   echo " Input desc param,rm -rf data logs: true or false?."
   exit 0
fi

exec 3<./datanode.txt
while read line <&3
do
   ssh ${u_name}@${line} "source /etc/profile;sudo ${cluster_dir}/${cur_cluster}/sbin/stop-datanode.sh" &
done
sleep 10

function get_datanode_pid()
{
        log_time=`date "+%Y-%m-%d %H:%M:%S"`
	node=$1
	v_name=$2
	for i in {1..5}
	do
	   pid=`ssh ${u_name}@${node} "source /etc/profile;sudo jps|grep -i ${v_name}"`
	   sleep 2
           var_pid=`echo "${pid}"|awk '{print $1}'`
           ssh ${u_name}@${node} "source /etc/profile;sudo kill -9 ${var_pid}"

	   if [[ ${pid} != "" ]];then
		echo "${log_time} ${node} stop DataNode ${pid} failed." >> ./log/stop_pid_failed.txt
  	   else
		echo "${log_time} ${node} stop DataNode ${pid} successfully." >> ./log/stop_pid_successfully.txt
	        break	

	   fi
        done
}
function backup_data()
{
        node=$1
                if [[ "${clean_data_logs}x" = "truex" ]];then
#		   ssh ${u_name}@${node} "sudo cp -rp ${cluster_dir}/${cur_cluster}/data/datanode/system/compression_ratio/Compress-* ${cluster_dir}/${cur_cluster}/"
#		   ssh ${u_name}@${node} "sudo cp -rp ${cluster_dir}/${cur_cluster}/conf ${cluster_dir}/${cur_cluster}/conf_${desc}"
                   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/data"
                   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/data*"
#                   ssh ${u_name}@${node} "sudo mv ${cluster_dir}/${cur_cluster}/data ${cluster_dir}/${cur_cluster}/data_${desc} "
#                   ssh ${u_name}@${node} "sudo mv ${cluster_dir}/${cur_cluster}/logs ${cluster_dir}/${cur_cluster}/logs_${desc}"
#                  ssh ${u_name}@${node} "sudo mv ${cluster_dir}/${cur_cluster}/logs ${cluster_dir}/${cur_cluster}/logs_${desc}"
#                  ssh ${u_name}@${node} "sudo mv ${cluster_dir}/${cur_cluster}/conf ${cluster_dir}/${cur_cluster}/conf_${desc}"
                   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/logs"
#                   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/conf"
#                   ssh ${u_name}@${node} "cp -rp ${cluster_dir}/${cur_cluster}/conf_backup ${cluster_dir}/${cur_cluster}/conf"
                    echo "nothing"
                else
                   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/data"
                   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/data*"

#                   ssh ${u_name}@${node} "sudo mv ${cluster_dir}/${cur_cluster}/data ${cluster_dir}/${cur_cluster}/data_${desc}"
#                   ssh ${u_name}@${node} "sudo cp -rp  ${cluster_dir}/${cur_cluster}/data ${cluster_dir}/${cur_cluster}/data_${desc}"
#                   ssh ${u_name}@${node} "sudo mv ${cluster_dir}/${cur_cluster}/logs ${cluster_dir}/${cur_cluster}/logs_${desc}"
#                   ssh ${u_name}@${node} "sudo mv ${cluster_dir}/${cur_cluster}/conf ${cluster_dir}/${cur_cluster}/conf_${desc}"
                   echo "do nothing"
                fi

}

exec 3<./datanode.txt
while read line <&3
do
get_datanode_pid ${line} "datanode" &
done
wait

exec 3<./confignode.txt
while read line <&3
do
   ssh ${u_name}@${line} "source /etc/profile;sudo ${cluster_dir}/${cur_cluster}/sbin/stop-confignode.sh"
done
sleep 10

exec 3<./confignode.txt
while read line <&3
do
get_datanode_pid ${line} "confignode" &
done
wait


exec 3<./datanode.txt
while read line <&3
do
backup_data ${line} &
done
wait
