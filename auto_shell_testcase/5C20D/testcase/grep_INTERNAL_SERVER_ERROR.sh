#!/bin/bash
cur_dir="$(cd "$(dirname "$0")" && pwd)"
conf_file="${cur_dir}/../conf/test.conf"

# 读取配置文件（增加空值校验+容错）
os_user_name=$(grep "^os_user_name=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
testdb=$(grep "^v_testdb=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
db_parent_dir=$(grep "^v_db_parent_dir=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
shell_client_db_parent_dir=$(grep "^v_shell_client_db_parent_dir=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
cn_db_parent_dir=$(grep "^v_cn_db_parent_dir=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")

# 校验配置项非空
if [[ -z "${os_user_name}" || -z "${testdb}" || -z "${db_parent_dir}" || -z "${cn_db_parent_dir}" ]]; then
    echo "[$(date +%F_%T)] ERROR: 配置文件${conf_file}关键项为空！" | tee -a "${log_file}"
    exit 1
fi

cli_dir="${shell_client_db_parent_dir}/${testdb}"
db_dir="${db_parent_dir}/${testdb}"
cn_db_dir="${cn_db_parent_dir}/${testdb}"
v_start_time=$(date +%s)
nodeinfo_dir="${cur_dir}/../conf"
fail_flag=0
exec 3<${nodeinfo_dir}/datanode_20d.txt
while read node<&3
do
v_node=`ssh ${os_user_name}@${node} "grep \"INTERNAL_SERVER_ERROR\" ${db_dir}/logs/*datanode*all*|wc -l"`
if [[ ${v_node} -gt 0 ]];then
	let fail_flag++
	echo "${node} \"INTERNAL_SERVER_ERROR\" : ${v_node}."
fi
done
echo "fail_flag:${fail_flag}"
