#!/bin/bash
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
query_ip=`head -1 ${cur_dir}/datanode.txt`
db_name=v2081_release_version
cli_dir=/data/liuzhen_test/3c3d_longtest/db/${db_name}
v_node_num=6
while true
do

    v_node_running_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "show cluster;"|grep Running|wc -l`
    if [[ ${v_node_running_num} = ${v_node_num} ]];then
	    echo "启动集群成功."
            ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "show cluster;"
            ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "show regions;"
            ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "show variables;"
    fi
done
