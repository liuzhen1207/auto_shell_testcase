#!/bin/bash
# db_dir need exist and is your expect.
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
conf_file="${cur_dir}/../conf/test.conf"
os_user_name=`cat ${conf_file}|grep ^os_user_name|awk -F '=' '{print $2}'`
testdb=`cat ${conf_file}|grep ^v_testdb|awk -F '=' '{print $2}'`
db_parent_dir=`cat ${conf_file}|grep ^v_db_parent_dir|awk -F '=' '{print $2}'`
shell_client_db_parent_dir=$(grep '^v_shell_client_db_parent_dir=' "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
if [ -z "${shell_client_db_parent_dir}" ]; then
  shell_client_db_parent_dir=${db_parent_dir}
fi
cli_dir=${shell_client_db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
query_host=`head -1 ${cur_dir}/../conf/datanode.txt`
v_start_time=`date +%s`
cur_start_cluster_time=$1
total_node_num=$2
function start_cluster()
{
if [ $# = 0 ];then
   cur_start_count=1
   total_node_num=6
else
   cur_start_count=$1
   total_node_num=$2
fi

exec 3<${cur_dir}/../conf/confignode.txt
while read line <&3
do
	v_ip=`echo ${line}|awk -F '.' '{print $4}'`

        ssh ${os_user_name}@${line} "source /etc/profile;sudo ${db_dir}/sbin/start-confignode.sh -H ${db_dir}/cn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
sleep 2
done

exec 4<${cur_dir}/../conf/datanode.txt
while read d_node <&4
do
        ssh ${os_user_name}@${d_node} "source /etc/profile;sudo ${db_dir}/sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &"
        sleep 2
done
# continue
while true
do
   v_running=`${cli_dir}/sbin/start-cli.sh -h ${query_host} -e "show cluster;"|grep Running |wc -l`
   v_readonly=`${cli_dir}/sbin/start-cli.sh -h ${query_host} -e "show cluster;"|grep ReadOnly |wc -l`
   v_ok_num=$((v_running+v_readonly))
   if [[ ${total_node_num} = ${v_ok_num} ]];then
      exit
   else
      sleep 1
   fi
done
}
start_cluster ${cur_start_cluster_time} ${total_node_num}
