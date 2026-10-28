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
# stop all dn  【第一步：并行停止所有节点】
exec 3<${cur_dir}/../conf/datanode_20d.txt
while read line <&3
do
    echo "正在停止节点：$line"
    # 后台执行停止命令，不等待
    ssh ${os_user_name}@${line} "source /etc/profile;${db_dir}/sbin/stop-datanode.sh" &
done
# 等待所有后台停止任务执行完
wait

echo "==== 所有节点停止命令已发送，开始统一检查进程是否关闭 ===="

# 【第二步：统一检查所有节点 DN 进程】
exec 3<${cur_dir}/../conf/datanode_20d.txt
while read line <&3
do
    t1=`date +%s`
    echo "检查节点：$line"

    while true
    do
        # 查询进程
        dn_pid_str=`ssh ${os_user_name}@${line} "source /etc/profile;jps|grep -i datanode"`
        dn_pid=`echo ${dn_pid_str}|awk '{print $1}'`

        if [[ -z "${dn_pid}" || "${dn_pid}" -lt 1 ]]; then
            echo "节点 $line：DN 已停止"
            break
        fi

        # 超时判断 3分钟 = 180秒
        t2=`date +%s`
        t=$((t2-t1))
        if [[ ${t} -gt 180 ]]; then
            echo "节点 $line：停止超时，强制 kill -9 ${dn_pid}"
            ssh ${os_user_name}@${line} "kill -9 ${dn_pid}"
            break
        fi

        sleep 2
    done
done

echo "==== 所有 DataNode 已确认关闭完成 ===="

exec 3<${cur_dir}/../conf/confignode_5c.txt
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
