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
echo "db_dir: ${db_dir}"
sleep 40m
ssh root@172.20.70.100 'source /etc/profile; nohup ${db_dir}/sbin/start-confignode.sh -H ${db_dir}/cn_restart_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &'
sleep 5
ssh root@172.20.70.101 'source /etc/profile; nohup ${db_dir}/sbin/start-confignode.sh -H ${db_dir}/cn_restart_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &'
sleep 5
ssh root@172.20.70.100 'source /etc/profile; nohup ${db_dir}/sbin/start-datanode.sh -g -H ${db_dir}/dn_restart_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &'
sleep 5
ssh root@172.20.70.101 'source /etc/profile; nohup ${db_dir}/sbin/start-datanode.sh -g -H ${db_dir}/dn_restart_${v_start_time}_heapdump.hprof > /dev/null 2>&1 &'
