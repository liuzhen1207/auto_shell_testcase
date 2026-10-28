#!/bin/bash
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
conf_file="${cur_dir}/../conf/test.conf"
os_user_name=`cat ${conf_file}|grep ^os_user_name|awk -F '=' '{print $2}'`
testdb=$(grep "^v_testdb=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
db_parent_dir=$(grep "^v_db_parent_dir=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
shell_client_db_parent_dir=$(grep "^v_shell_client_db_parent_dir=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
cn_db_parent_dir=$(grep "^v_cn_db_parent_dir=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
db_dir="${db_parent_dir}/${testdb}"

exec 3<${cur_dir}/../conf/datanode_20d.txt
while read d_node <&3
do
ssh ${os_user_name}@${d_node} "df -lh ${db_dir}/data";
done
