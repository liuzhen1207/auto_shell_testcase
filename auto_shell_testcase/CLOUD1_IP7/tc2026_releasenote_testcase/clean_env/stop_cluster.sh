#!/bin/bash
# db_dir need exist and is your expect.
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
conf_file="${cur_dir}/../conf/test.conf"
os_user_name=`cat ${conf_file}|grep ^os_user_name|awk -F '=' '{print $2}'`
testdb=`cat ${conf_file}|grep ^v_testdb|awk -F '=' '{print $2}'`
db_parent_dir=`cat ${conf_file}|grep ^v_db_parent_dir|awk -F '=' '{print $2}'`
cn_db_parent_dir=`cat ${conf_file}|grep ^v_cn_db_parent_dir|awk -F '=' '{print $2}'`
cli_dir=${db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
cn_db_dir=${cn_db_parent_dir}/${testdb}

function stop_cluster()
{
# stop all dn
exec 3<${cur_dir}/../conf/datanode.txt
while read line <&3
do
        ssh ${os_user_name}@${line} "source /etc/profile;${db_dir}/sbin/stop-datanode.sh"
        t1=`date +%s`
        while true
        do
          dn_pid_str=`ssh ${os_user_name}@${line} "source /etc/profile;jps|grep -i datanode"`
          dn_pid=`echo ${dn_pid_str}|awk '{print $1}'`
          if [[ "${dn_pid}" -gt 0 ]];then
             sleep 2
          else
             break
          fi
          t2=`date +%s`
          t=$((t2-t1))
          if [[ ${t} -gt 180 ]];then
             ssh ${os_user_name}@${line} "source /etc/profile;kill -9 ${dn_pid}"
          fi
        done
done
exec 3<${cur_dir}/../conf/confignode.txt
while read line <&3
do

        ssh ${os_user_name}@${line} "source /etc/profile;${cn_db_dir}/sbin/stop-confignode.sh"
        t1=`date +%s`
        while true
        do
          cn_pid_str=`ssh ${os_user_name}@${line} "source /etc/profile;jps|grep -i confignode"`
          cn_pid=`echo ${cn_pid_str}|awk '{print $1}'`
          if [[ "${cn_pid}" -gt 0 ]];then
             sleep 2
          else
             break
          fi
          t2=`date +%s`
          t=$((t2-t1))
          if [[ ${t} -gt 180 ]];then
             ssh ${os_user_name}@${line} "source /etc/profile;kill -9 ${cn_pid}"
          fi
        done
done

#stop local bm
jps|grep App|awk '{print "kill -9 "$1}'|sh
sleep 1
}
stop_cluster
