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

# unzip local 

if [ -f "${cli_dir}/sbin/start-cli.sh" ]; then
    echo "success"
else
unzip ${cli_dir}/*.zip -d ${cli_dir}/
mv ${cli_dir}/timechodb-*-bin/* ${cli_dir}/
cp -rp ${cli_dir}/conf ${cli_dir}/conf_orig

fi

cat ${nodeinfo_dir}/datanode_20d.txt|while read node
do
echo $node
scp -rp ${cli_dir}/ ${os_user_name}@${node}:${db_dir}
done

cat ${nodeinfo_dir}/confignode_5c.txt|while read c_node
do
echo $c_node
v_cn_ip_check=`grep ${c_node} ${nodeinfo_dir}/datanode_20d.txt|wc -l`
if [[ ${v_cn_ip_check} = 0 ]];then
echo "hello"
scp -rp ${cli_dir}/ ${os_user_name}@${c_node}:${cn_db_dir}
fi
done

