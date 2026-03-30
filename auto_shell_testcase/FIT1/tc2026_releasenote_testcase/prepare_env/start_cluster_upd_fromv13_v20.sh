#!/bin/bash
# db_dir need exist and is your expect.
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
conf_file="${cur_dir}/../conf/test.conf"
os_user_name=`cat ${conf_file}|grep ^os_user_name|awk -F '=' '{print $2}'`
testdb=`cat ${conf_file}|grep ^v_testdb|awk -F '=' '{print $2}'`
db_parent_dir=`cat ${conf_file}|grep ^v_db_parent_dir|awk -F '=' '{print $2}'`
cli_dir=${db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
query_host=`head -1 ${cur_dir}/../conf/datanode.txt`
license_dir=/ssd/license_20250619/
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
   if [[ "${line}" = "192.168.130.1" ]];then
           cp -rp ${cur_dir}/license/license_fit1/timecho_license_new ${db_dir}/activation/license
           cp -rp ${cur_dir}/license/license_fit1/.env ${db_dir}/
   fi
if ssh ${os_user_name}@${line} test -f ${db_dir}/activation/license; then
echo "license is exist."
else
   if ssh ${os_user_name}@${line} test -f ${license_dir}/license; then
      ssh ${os_user_name}@${line} "cp -rp ${license_dir}/license ${db_dir}/activation/license"
      ssh ${os_user_name}@${line} "sudo cp -rp ${license_dir}/.env ${db_dir}/"
   fi
fi

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
   v_running=`${cli_dir}/sbin/start-cli.sh -pw root -h ${query_host} -e "show cluster;"|grep Running |wc -l`
   v_readonly=`${cli_dir}/sbin/start-cli.sh -pw root -h ${query_host} -e "show cluster;"|grep ReadOnly |wc -l`
   v_ok_num=$((v_running+v_readonly))
   if [[ ${total_node_num} = ${v_ok_num} ]];then
	   ${cli_dir}/sbin/start-cli.sh -pw root -h ${query_host} -e "alter user root set password 'TimechoDB@2021'">${cur_dir}/tmp.out
	   v_suc=`grep success ${cur_dir}/tmp.out|wc -l`
	   if [[ ${v_suc} -gt 0 ]];then
              echo "pass"
	   fi

      exit
   else
      sleep 1
   fi
done
}
start_cluster ${cur_start_cluster_time} ${total_node_num}
