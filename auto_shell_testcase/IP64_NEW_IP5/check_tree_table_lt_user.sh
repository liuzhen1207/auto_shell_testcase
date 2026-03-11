#!/bin/bash
#sleep 6h
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
test_db=v2081_release_version
db_dir="/data/liuzhen_test/3c3d_longtest/db/${test_db}"
node_db_dir="/data/liuzhen_test/${test_db}"
node1=`head -1 ./datanode.txt`
res_dir=$1
bm_log1=$2
bm_log2=$3
bm1_res_file="/data/liuzhen_test/3c3d_longtest/bm_20251017_b6be9bd/${bm_log1}"
bm2_res_file="/data/liuzhen_test/3c3d_longtest/bm_20251017_b6be9bd/${bm_log2}"
u_name="liuzhen"
q_node_array=("11.101.10.2" "11.101.10.3" "11.101.10.4")
i=0
if [ $# -eq 3 ];
then
echo "$1"
else
echo "Please input res dir."
exit 
fi
# exec flush
exec 3<./datanode.txt
while read line <&3
do
   ${db_dir}/sbin/start-cli.sh -h ${line} -e "flush"
done
# check res dir
if [ ! -d "${cur_dir}/${res_dir}" ];then
mkdir -p "${cur_dir}/${res_dir}" 
else
echo "${cur_dir}/${res_dir} path already exist"
fi

function check_error_log()
{
exec 3<./datanode.txt
while read line <&3
do
   ssh ${u_name}@${line} "source /etc/profile;sudo gunzip ${node_db_dir}/logs/log-datanode-all*"
   v_error=`ssh ${u_name}@${line} "grep ERROR ${node_db_dir}/logs/*datanode*all*|wc -l"`
   if [[ ${v_error} -gt 0 ]];then
	   echo "${line} DN have ERROR logs." >> ${cur_dir}/${res_dir}/check_res.out
   fi

done
}
check_error_log
# check query sql is successful.
function check_query_res()
{
	res_file=$1
	v_sql=$2
	while true
	do
		v_res_ok=`grep "Msg:" ${res_file} |wc -l`
		if [[ ${v_res_ok} = 0 ]];then
			break
		else
			cat ${res_file} >> ${cur_dir}/${res_dir}/q_error_msg.out
			echo "${v_sql}"|sh
		fi
        done

}

# query system
v_sql_exec="${db_dir}/sbin/start-cli.sh -h ${node1} -timeout 36000  -e 'show cluster;' >${cur_dir}/${res_dir}/q_cluster.out"
echo "${v_sql_exec}"|sh
check_query_res "${cur_dir}/${res_dir}/q_cluster.out" "${v_sql_exec}"
v_sql_exec="${db_dir}/sbin/start-cli.sh -h ${node1} -timeout 36000  -e 'show regions;' >${cur_dir}/${res_dir}/q_tree_regions.out"
echo "${v_sql_exec}"|sh
${db_dir}/sbin/start-cli.sh -h ${node1} -timeout 36000 -sql_dialect table -e 'show regions;' >${cur_dir}/${res_dir}/q_table_regions.out
check_query_res "${cur_dir}/${res_dir}/q_regions.out" "${v_sql_exec}"
${db_dir}/sbin/start-cli.sh -h ${node1} -timeout 36000  -e 'count timepartition where database=root.test.g_0;' >${cur_dir}/${res_dir}/q_count_timepartition.out
v_sql_exec="${db_dir}/sbin/start-cli.sh -h ${node1} -timeout 36000  -e 'select sum(value) from root.__system.** align by device;' >${cur_dir}/${res_dir}/q_system.out"
echo "${v_sql_exec}"|sh
check_query_res "${cur_dir}/${res_dir}/q_system.out" "${v_sql_exec}"

v_sql_exec="${db_dir}/sbin/start-cli.sh -h ${node1} -timeout 360000  -e 'select count(s_0) from root.test.g_0.** align by device;' >${cur_dir}/${res_dir}/q_all_online_tree.out"
echo "${v_sql_exec}"|sh
check_query_res "${cur_dir}/${res_dir}/q_all_online.out" "${v_sql_exec}"

${db_dir}/sbin/start-cli.sh -h ${node1} -timeout 360000  -sql_dialect table -e 'select device_id,count(s_0) from test_g_0.table_0 group by device_id order by device_id;' >${cur_dir}/${res_dir}/q_all_online_table.out

exec 3<./datanode.txt
while read line <&3
do
   ssh ${u_name}@${line} "source /etc/profile;sudo ${node_db_dir}/sbin/stop-datanode.sh"
   q_node="${q_node_array[$i]}"
   while true
   do
	   sleep 1
      v_running=`${db_dir}/sbin/start-cli.sh -h ${q_node} -timeout 3600  -e "show cluster;" |grep ${line} |grep DataNode|grep Running|wc -l`
      v_jps=`ssh ${u_name}@${line} "source /etc/profile;sudo jps|grep DataNode|wc -l"`
      if [[ ${v_running} = 1 ]];then
	      sleep 2
      else
	      if [[ ${v_jps} = 0 ]];then
	         break
              else
		 sleep 2
              fi
      fi
   done
   v_sql_exec="${db_dir}/sbin/start-cli.sh -h ${q_node}  -timeout 360000  -e 'select count(s_0) from root.test.g_0.** align by device;' >${cur_dir}/${res_dir}/q_stop_node${i}_tree.out"
   echo "${v_sql_exec}"|sh
   check_query_res "${cur_dir}/${res_dir}/q_stop_node${i}.out" "${v_sql_exec}"
${db_dir}/sbin/start-cli.sh -h ${q_node}  -timeout 360000  -sql_dialect table -e 'select device_id,count(s_0) from test_g_0.table_0 group by device_id order by device_id;' >${cur_dir}/${res_dir}/q_stop_node${i}_table.out
#   echo "stop_node,${line};q_node,${q_node}"
   ssh ${u_name}@${line} "source /etc/profile;sudo ${node_db_dir}/sbin/start-datanode.sh > /dev/null 2>&1 &"
   while true
   do
           sleep 5
      v_running=`${db_dir}/sbin/start-cli.sh -h ${q_node} -timeout 360000  -e "show cluster;" |grep ${line} |grep DataNode|grep Running|wc -l`
      if [[ ${v_running} = 1 ]];then
              break 
      else
              sleep 5 
      fi
   done

   let i++
done

function check_res()
{
	r_sys_res_1=$(cat ${cur_dir}/${res_dir}/q_system.out |grep root|grep "DATANODE.\`3\`"|awk -F '|' '{sum+=$3}END{print sum}')
	r_sys_res_2=$(cat ${cur_dir}/${res_dir}/q_system.out |grep root|grep "DATANODE.\`4\`"|awk -F '|' '{sum+=$3}END{print sum}')
	r_sys_res_3=$(cat ${cur_dir}/${res_dir}/q_system.out |grep root|grep "DATANODE.\`5\`"|awk -F '|' '{sum+=$3}END{print sum}')
   bm1_okpoint=`grep okPoint -A 1 ${bm1_res_file} |grep INGESTION|tail -1|awk '{print $3}'`
   bm2_okpoint=`grep okPoint -A 1 ${bm2_res_file} |grep INGESTION|tail -1|awk '{print $3}'`
   bm_okpoint=$((bm1_okpoint+bm2_okpoint))
   db_res_all_online_tree=`cat ${cur_dir}/${res_dir}/q_all_online_tree.out|grep root|awk -F '|' '{sum+=$3*600}END{print sum}'`
   db_res_all_online_table=`cat ${cur_dir}/${res_dir}/q_all_online_table.out|grep d_|awk -F '|' '{sum+=$3*600}END{print sum}'`
   db_res_stop_node0_tree=`cat ${cur_dir}/${res_dir}/q_stop_node0_tree.out|grep root|awk -F '|' '{sum+=$3*600}END{print sum}'`
   db_res_stop_node1_tree=`cat ${cur_dir}/${res_dir}/q_stop_node1_tree.out|grep root|awk -F '|' '{sum+=$3*600}END{print sum}'`
   db_res_stop_node2_tree=`cat ${cur_dir}/${res_dir}/q_stop_node2_tree.out|grep root|awk -F '|' '{sum+=$3*600}END{print sum}'`
   db_res_stop_node0_table=`cat ${cur_dir}/${res_dir}/q_stop_node0_table.out|grep d_|awk -F '|' '{sum+=$3*600}END{print sum}'`
   db_res_stop_node1_table=`cat ${cur_dir}/${res_dir}/q_stop_node1_table.out|grep d_|awk -F '|' '{sum+=$3*600}END{print sum}'`
   db_res_stop_node2_table=`cat ${cur_dir}/${res_dir}/q_stop_node2_table.out|grep d_|awk -F '|' '{sum+=$3*600}END{print sum}'`
   query_tree_table_total=$((db_res_all_online_tree+db_res_all_online_table))

   # ===================== 4. 检查各节点tree值是否与在线状态一致 =====================
check_result="success"
error_msg=""
for node in 0 1 2; do
    if [ "${db_res_all_online_tree}" -ne "${db_res_stop_node[$node]_tree}" ]; then
        check_result="fail"
        error_msg+="节点${node}的tree值不一致：在线值=${db_res_all_online_tree}，停止值=${db_res_stop_node[$node]_tree}\n"
    fi
done
for node in 0 1 2; do
    if [ "${db_res_all_online_table}" -ne "${db_res_stop_node[$node]_table}" ]; then
        check_result="fail"
        error_msg+="节点${node}的table值不一致：在线值=${db_res_all_online_table}，停止值=${db_res_stop_node[$node]_table}\n"
    fi
done

# 输出检查结果
if [ "$check_result" = "fail" ]; then
    echo -e "check result fail.\n错误详情：$error_msg" >&2
    exit 1  # 退出码非0，标识失败
else
    echo "check result success."
    exit 0
fi

   echo -e "system node1 point num:${r_sys_res_1},\nsystem node2 point num:${r_sys_res_2},\nsystem node3 point num:${r_sys_res_3},\nbenchmark ok point num:${bm_okpoint},\niotdb all online tree + table:${query_tree_table_total}\niotdb 3node online query point number - tree:${db_res_all_online_tree},\niotdb stop node1 query point number - tree:${db_res_stop_node0_tree},\niotdb stop node2 query point number - tree:${db_res_stop_node1_tree},\niotdb stop node3 query point number - tree:${db_res_stop_node2_tree} \n iotdb 3node online query point number - table:${db_res_all_online_table},\niotdb stop node1 query point number - table:${db_res_stop_node0_table},\niotdb stop node2 query point number - table:${db_res_stop_node1_table},\niotdb stop node3 query point number - table:${db_res_stop_node2_table} \n" > ${cur_dir}/${res_dir}/check_res.out
}
check_res
