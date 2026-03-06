#!/bin/bash
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
conf_file="${cur_dir}/../conf/test.conf"
os_user_name=`cat ${conf_file}|grep ^os_user_name|awk -F '=' '{print $2}'`
exec 3<${cur_dir}/../conf/datanode.txt
while read d_node <&3
do
ssh ${os_user_name}@${d_node} "sh -c \"sync; echo 3 > /proc/sys/vm/drop_caches\"";
done

exec 4<${cur_dir}/../conf/confignode.txt
while read c_node <&4
do
ssh ${os_user_name}@${c_node} "sh -c \"sync; echo 3 > /proc/sys/vm/drop_caches\"";
done

# local
echo 3 >/proc/sys/vm/drop_caches
