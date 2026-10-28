#!/bin/bash
cluster_dir="/data2"
cur_cluster="v2082rc3_0212_1606693"
u_name="iotdb"
clean_data_logs="$2"
desc=$1
data1_dir="/data1/iotdb_data/v2082rc3_0212_1606693/data"
data2_dir="/data3/iotdb_data/v2082rc3_0212_1606693/data"
if [[ "$#" = "0" ]];then
   echo " Input desc param,rm -rf data logs: true or false?."
   exit 0
fi

exec 3<./datanode.txt
while read line <&3
do
   ssh ${u_name}@${line} "source /etc/profile;sudo ${cluster_dir}/${cur_cluster}/sbin/stop-datanode.sh"
done
sleep 5 

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
#                   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/data"
#		   if ssh ${u_name}@${node} test -d ${data1_dir}; then 
#			   echo "path exist."
#                      ssh ${u_name}@${node} "sudo rm -rf ${data1_dir}"
#		   fi
#                   if ssh ${u_name}@${node} test -d ${data2_dir}; then 
#                      ssh ${u_name}@${node} "sudo rm -rf ${data2_dir}"
#		   fi
                           ssh ${u_name}@${node} "sudo mv ${cluster_dir}/${cur_cluster}/data ${cluster_dir}/${cur_cluster}/data_${desc}"
                           ssh ${u_name}@${node} "sudo mv ${data1_dir} ${data1_dir}_${desc}"
                           ssh ${u_name}@${node} "sudo mv ${data2_dir} ${data2_dir}_${desc}"

                   ssh ${u_name}@${node} "sudo mv ${cluster_dir}/${cur_cluster}/logs ${cluster_dir}/${cur_cluster}/logs_${desc}"
#                  ssh ${u_name}@${node} "mv ${cluster_dir}/${cur_cluster}/logs ${cluster_dir}/${cur_cluster}/logs_${desc}"
#                   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/logs"
                      echo "true"
                   else
#			   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/logs"
#			   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/logs_*"
#         		   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/data/"
                           t1=`date +%s`
         		   ssh ${u_name}@${node} "sudo cp -rl ${cluster_dir}/${cur_cluster}/data/ ${cluster_dir}/${cur_cluster}/data_hardlink_from_data_${t1}"
#         		   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/data*/"
#			   ssh ${u_name}@${node} "sudo rm -rf ${data1_dir}/"
			   ssh ${u_name}@${node} "sudo cp -rl ${data1_dir}/ ${data1_dir}_hardlink_from_data_${t1}/"
#	   ssh ${u_name}@${node} "sudo rm -rf ${data2_dir}/"
	   ssh ${u_name}@${node} "sudo cp -rl ${data2_dir}/ ${data2_dir}_hardlink_from_data_${t1}/"
#                   ssh ${u_name}@${node} "sudo mv ${cluster_dir}/${cur_cluster}/data ${cluster_dir}/${cur_cluster}/data_${desc}"
#                   ssh ${u_name}@${node} "sudo mv ${data1_dir} ${data1_dir}_${desc}"
#                   ssh ${u_name}@${node} "sudo mv ${data2_dir} ${data2_dir}_${desc}"
#                    ssh ${u_name}@${node} "sudo mv ${cluster_dir}/${cur_cluster}/logs ${cluster_dir}/${cur_cluster}/logs_${desc}"
#                   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/logs"
#                   ssh ${u_name}@${node} "sudo rm -rf ${cluster_dir}/${cur_cluster}/activation/license"
#                   ssh ${u_name}@${node} "sudo cp -rp ${cluster_dir}/${cur_cluster}/conf ${cluster_dir}/${cur_cluster}/conf_${desc}"
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
sleep 1

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
exec 3<./confignode.txt
while read line <&3
do
	v_same_ip_dn=`grep "${line}$" ./datanode.txt|wc -l`
	if [[ ${v_same_ip_dn} = 0 ]];then
           backup_data ${line} &
        fi
done
wait

