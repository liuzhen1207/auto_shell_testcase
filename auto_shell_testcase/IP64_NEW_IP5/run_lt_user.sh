#!/bin/bash
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
u_name=liuzhen
os_user_name=${u_name}
db_name=v2081_release_version
res_file_name=${db_name}_get_result.out
db_dir=/data/liuzhen_test/${db_name}
cli_dir=/data/liuzhen_test/3c3d_longtest/db/${db_name}
bm_dir=/data/liuzhen_test/3c3d_longtest/bm_20251017_b6be9bd
test_time=604800000
query_ip=`head -1 ./datanode.txt`
cn_num=3
dn_num=3
dr_rep_num=3
sr_rep_num=3
total_node_num=$((cn_num+dn_num))
CLUSTER_ID=defaultCluster
v_consensus="IoTConsensus"
seed_cn_ip=$(head -1 "${cur_dir}/confignode.txt" | sed 's/ //g'):10710
log_file="${cur_dir}/set_conf_parallel.log"
echo "" > ${log_file}
fail_flag=0
v_warnMessage="No warn."
function stop_dn_rm_data()
{
	desc=$1
   jps|grep App|awk '{print "kill -9 "$1}'|sh
   sleep 3
   sh -x stop_dn_cn.sh ${desc} true 2>&1
   sh -x kill_pid.sh 2>&1
   sh -x clear_cache.sh 2>&1
   sh -x clear_cache.sh 2>&1
}
# 单个ConfigNode配置函数
configure_confignode() {
    local node_ip=$1
    log "INFO" "开始配置ConfigNode: ${node_ip}"

    # 整合所有ConfigNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="8G"/g' ${cn_db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="2G"/g' ${cn_db_dir}/conf/confignode-env.sh

        # 定义批量修改system.properties的函数
        batch_set_sys_conf() {
            local search_str=\$1
            local content=\$2
            local file="${cn_db_dir}/conf/iotdb-system.properties"
            if grep -q "\$search_str" "\$file"; then
                sed -i "s|\$search_str|\$content|g" "\$file"
            else
                echo "\$content" >> "\$file"
            fi
        }

        # 批量执行system.properties配置
        batch_set_sys_conf ".*cn_seed_config_node=.*" "cn_seed_config_node=${seed_cn_ip}"
        batch_set_sys_conf ".*cn_internal_address=.*" "cn_internal_address=${node_ip}"
        batch_set_sys_conf ".*cn_metric_reporter_list=.*" "cn_metric_reporter_list=PROMETHEUS"
        batch_set_sys_conf ".*cn_metric_prometheus_reporter_port=.*" "cn_metric_prometheus_reporter_port=9081"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=10"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=10"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*disk_space_warning_threshold=.*" "disk_space_warning_threshold=0.01"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"


EOF

    if [ $? -eq 0 ]; then
        log "INFO" "ConfigNode ${node_ip} 配置完成"
    else
        log "ERROR" "ConfigNode ${node_ip} 配置失败"
        return 1
    fi
}

# 单个DataNode配置函数
configure_datanode() {
    local node_ip=$1
    # 读取坏盘节点IP（兼容文件不存在）

    # 整合所有DataNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="192G"/g' ${db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="16G"/g' ${db_dir}/conf/datanode-env.sh

        # 定义批量修改函数
        batch_set_sys_conf() {
            local search_str=\$1
            local content=\$2
            local file="${db_dir}/conf/iotdb-system.properties"
            if grep -q "\$search_str" "\$file"; then
                sed -i "s|\$search_str|\$content|g" "\$file"
            else
                echo "\$content" >> "\$file"
            fi
        }

        # 通用DataNode配置
        batch_set_sys_conf ".*dn_seed_config_node=.*" "dn_seed_config_node=${seed_cn_ip}"
        batch_set_sys_conf ".*dn_internal_address=.*" "dn_internal_address=${node_ip}"
        batch_set_sys_conf ".*dn_rpc_address=.*" "dn_rpc_address=${node_ip}"
        batch_set_sys_conf ".*dn_metric_reporter_list=.*" "dn_metric_reporter_list=PROMETHEUS"
        batch_set_sys_conf ".*dn_metric_prometheus_reporter_port=.*" "dn_metric_prometheus_reporter_port=9091"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=5"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*disk_space_warning_threshold=.*" "disk_space_warning_threshold=0.01"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"

EOF

    if [ $? -eq 0 ]; then
        log "INFO" "DataNode ${node_ip} 配置完成"
    else
        log "ERROR" "DataNode ${node_ip} 配置失败"
        return 1
    fi
}
# 混合节点配置函数
configure_mixed_node() {
    local node_ip=$1
    log "INFO" "开始配置混合节点（CN+DN）: ${node_ip}"
    configure_confignode "${node_ip}"
    if [ $? -eq 0 ]; then
        configure_datanode "${node_ip}"
    fi
    log "INFO" "混合节点 ${node_ip} 配置完成"
}

# ===================== 主配置函数（完全兼容低版本Bash） =====================
set_conf() {
    log "INFO" "开始并行配置所有节点（适配同IP场景）..."

    # -------------------- 步骤1：用临时文件读取节点IP（替代进程替换） --------------------
    # 生成去重的CN IP临时文件
    grep -v '^$' "${cur_dir}/confignode.txt" | sed 's/ //g' | sort -u > /tmp/cn_ips.tmp
    # 生成去重的DN IP临时文件
    grep -v '^$' "${cur_dir}/datanode.txt" | sed 's/ //g' | sort -u > /tmp/dn_ips.tmp

    # 读取CN IP列表（低版本Bash兼容）
    cn_ips=()
    while read -r line; do
        if [[ -n "${line}" ]]; then
            cn_ips+=("${line}")
        fi
    done < /tmp/cn_ips.tmp

    # 读取DN IP列表（低版本Bash兼容）
    dn_ips=()
    while read -r line; do
        if [[ -n "${line}" ]]; then
            dn_ips+=("${line}")
        fi
    done < /tmp/dn_ips.tmp

    # -------------------- 步骤2：分类节点IP --------------------
    # 找出混合节点（交集）
    mixed_ips=()
    for ip in "${cn_ips[@]}"; do
        # 低版本Bash兼容的字符串包含判断
        if grep -q "^${ip}$" /tmp/dn_ips.tmp; then
            mixed_ips+=("${ip}")
        fi
    done

    # 找出仅CN的IP
    only_cn_ips=()
    for ip in "${cn_ips[@]}"; do
        if ! grep -q "^${ip}$" /tmp/dn_ips.tmp; then
            only_cn_ips+=("${ip}")
        fi
    done

    # 找出仅DN的IP
    only_dn_ips=()
    for ip in "${dn_ips[@]}"; do
        if ! grep -q "^${ip}$" /tmp/cn_ips.tmp; then
            only_dn_ips+=("${ip}")
        fi
    done

    # -------------------- 步骤3：并行配置节点 --------------------
    pids=()

    # 配置仅CN节点
    log "INFO" "启动仅ConfigNode节点并行配置: ${only_cn_ips[*]}"
    for ip in "${only_cn_ips[@]}"; do
        configure_confignode "${ip}" &
        pids+=($!)
    done

    # 配置仅DN节点
    log "INFO" "启动仅DataNode节点并行配置: ${only_dn_ips[*]}"
    for ip in "${only_dn_ips[@]}"; do
        configure_datanode "${ip}" &
        pids+=($!)
    done

# 配置混合节点（新增空值判断）
if [ ${#mixed_ips[@]} -gt 0 ]; then
    log "INFO" "启动混合节点（CN+DN）并行配置: ${mixed_ips[*]}"
    for ip in "${mixed_ips[@]}"; do
        configure_mixed_node "${ip}" &
        pids+=($!)
    done
else
    log "INFO" "未检测到混合节点（CN+DN），跳过混合节点配置"
fi

    # -------------------- 步骤4：等待所有进程完成 --------------------
    log "INFO" "等待所有节点配置进程完成..."
    for pid in "${pids[@]}"; do
        if wait "${pid}"; then
            log "INFO" "进程PID ${pid} 执行成功"
        else
            log "ERROR" "进程PID ${pid} 执行失败"
        fi
    done

    # 清理临时文件
    rm -f /tmp/cn_ips.tmp /tmp/dn_ips.tmp

    if [ ${fail_flag} -eq 0 ]; then
        log "INFO" "所有节点配置完成！日志文件：${log_file}"
    else
        log "ERROR" "部分节点配置失败，请查看日志：${log_file}"
    fi
}

function start_dn()
{
   sh -x start_cn.sh 2>&1
   sh -x start_dn.sh 2>&1
   sh -x show_cluster.sh 2>&1
   sleep 10 
}
function start_bm()
{
	sudo -s <<EOF
echo 3 >/proc/sys/vm/drop_caches
EOF

sudo -s <<EOF
echo 3 >/proc/sys/vm/drop_caches
EOF

v_time=`date +"%Y_%m_%d_%H_%M_%S"`
current_date=$(date +%Y-%m-%d)
next_7d_date=$(date -d "+7 days" +%Y-%m-%d)
bm_desc=$1
sed -i "s/TEST_MAX_TIME=.*/TEST_MAX_TIME=${test_time}/g" ${bm_dir}/lt_10type_user/*/config.properties
${bm_dir}/benchmark.sh -cf ${bm_dir}/lt_10type_user/conf1 > ${bm_dir}/${v_time}_${bm_desc}_1.out &
${bm_dir}/benchmark.sh -cf ${bm_dir}/lt_10type_user/conf3 > ${bm_dir}/${v_time}_${bm_desc}_2.out &
wait
# get seq tsfile count
exec 3<./datanode.txt
while read line <&3
do
v_seq_tree_num=`ssh ${u_name}@${line} "sudo find ${db_dir}/data -name *.tsfile|grep -v unseq|grep root.test|wc -l"`
v_seq_table_num=`ssh ${u_name}@${line} "sudo find ${db_dir}/data -name *.tsfile|grep -v unseq|grep test_g_0|wc -l"`
v_unseq_tree_num=`ssh ${u_name}@${line} "sudo find ${db_dir}/data -name *.tsfile|grep  unseq|grep root.test|wc -l"`
v_unseq_table_num=`ssh ${u_name}@${line} "sudo find ${db_dir}/data -name *.tsfile|grep  unseq|grep test_g_0|wc -l"`
v_tree_wal_num=`ssh ${u_name}@${line} "sudo find ${db_dir}/data -name *.wal|grep root.test.g_0|wc -l"`
v_table_wal_num=`ssh ${u_name}@${line} "sudo find ${db_dir}/data -name *.wal|grep test_g_0|wc -l"`
v_seq_unseq_tree_num=$((v_seq_tree_num+v_unseq_tree_num))
v_seq_unseq_table_num=$((v_seq_table_num+v_unseq_table_num))
v_wal_num=$((v_tree_wal_num+v_table_wal_num))
v_tsfile_num=$((v_seq_unseq_tree_num+v_seq_unseq_table_num))
echo "${line},tree_seq_tsfile_num,${v_seq_tree_num}"
echo "${line},tree_unseq_tsfile_num,${v_unseq_tree_num}"
echo "${line},table_seq_tsfile_num,${v_seq_table_num}"
echo "${line},table_unseq_tsfile_num,${v_unseq_table_num}"
echo "${line},tree_seq_unseq_tsfile_num,${v_seq_unseq_tree_num}"
echo "${line},table_seq_unseq_tsfile_num,${v_seq_unseq_table_num}"
echo "${line},tree_table_seq_unseq_tsfile_num,${v_tsfile_num}"
echo "${line},tree_wal_file_num,${v_tree_wal_num}"
echo "${line},table_wal_file_num,${v_table_wal_num}"
echo "${line},tree_table_wal_file_num,${v_wal_num}"

done

# get size
exec 3<./datanode.txt
while read line <&3
do
v_seq_tree_size_str=`ssh ${u_name}@${line} "sudo du --block-size=1G -s ${db_dir}/data/datanode/data/sequence/root.test.g_0"`
v_seq_tree_size=`echo ${v_seq_tree_size_str}|awk '{print $1}'`

v_unseq_tree_size_str=`ssh ${u_name}@${line} "sudo du --block-size=1G -s ${db_dir}/data/datanode/data/unsequence/root.test.g_0"`
v_unseq_tree_size=`echo ${v_unseq_tree_size_str}|awk '{print $1}'`

v_seq_table_size_str=`ssh ${u_name}@${line} "sudo du --block-size=1G -s ${db_dir}/data/datanode/data/sequence/test_g_0"`
v_seq_table_size=`echo ${v_seq_table_size_str}|awk '{print $1}'`

v_unseq_table_size_str=`ssh ${u_name}@${line} "sudo du --block-size=1G -s ${db_dir}/data/datanode/data/unsequence/test_g_0"`
v_unseq_table_size=`echo ${v_unseq_table_size_str}|awk '{print $1}'`

v_wal_size_str=`ssh ${u_name}@${line} "sudo du --block-size=1M -s ${db_dir}/data/datanode/wal"`
v_tree_table_wal_size=`echo ${v_wal_size_str}|awk '{print $1}'`


v_seq_unseq_tree_size=$((v_seq_tree_size+v_unseq_tree_size))
v_seq_unseq_table_size=$((v_seq_table_size+v_unseq_table_size))
v_tsfile_size=$((v_seq_unseq_tree_size+v_seq_unseq_table_size))
echo "${line},tree_seq_tsfile_size (:GB),${v_seq_tree_size}"
echo "${line},tree_unseq_tsfile_size (:GB),${v_unseq_tree_size}"
echo "${line},table_seq_tsfile_size (:GB),${v_seq_table_size}"
echo "${line},table_unseq_tsfile_size (:GB),${v_unseq_table_size}"
echo "${line},tree_seq_unseq_tsfile_size (:GB),${v_seq_unseq_tree_size}"
echo "${line},table_seq_unseq_tsfile_size (:GB),${v_seq_unseq_table_size}"
echo "${line},tree_table_seq_unseq_tsfile_size (:GB),${v_tsfile_size}"
echo "${line},tree_table_wal_size (:MB),${v_tree_table_wal_size}"
done
# get 0-0 tsfile count
exec 3<./datanode.txt
while read line <&3
do
   ssh ${u_name}@${line} "sudo gunzip ${db_dir}/logs/log-datanode-all*"
   v_num_tree=`ssh ${u_name}@${line} "grep \"create a new tsfile\" ${db_dir}/logs/*datanode*all*|grep root.test.g_0|wc -l"`
   v_num_table=`ssh ${u_name}@${line} "grep \"create a new tsfile\" ${db_dir}/logs/*datanode*all*|grep test_g_0|wc -l"`
   v_tree_table_num=$((v_num_tree+v_num_table))
   echo "${line},tree 0-0.tsfile,${v_num_tree}" 
   echo "${line},table 0-0.tsfile,${v_num_table}" 
   echo "${line},tree+table 0-0.tsfile,${v_tree_table_num}" 
done
# get bm result
bm1_str=`grep through -A 1 ${bm_dir}/${v_time}_${desc}_1.out|tail -1`
bm1_okPoint=`echo ${bm1_str}|awk '{print $3}'`
bm1_throughput=`echo ${bm1_str}|awk '{print $6}'`
bm2_str=`grep through -A 1 ${bm_dir}/${v_time}_${desc}_2.out|tail -1`
bm2_okPoint=`echo ${bm2_str}|awk '{print $3}'`
bm2_throughput=`echo ${bm2_str}|awk '{print $6}'`
bm_total_okPoint=$((bm1_okPoint+bm2_okPoint))
bm_total_throughput=$((bm1_throughput+bm2_throughput))
echo "bm1-okPoint,${bm1_okPoint}"
echo "bm2-okPoint,${bm2_okPoint}"
echo "bm total-okPoint,${bm_total_okPoint}"
echo "bm1-throughput,${bm1_throughput}"
echo "bm2-throughput,${bm2_throughput}"
echo "bm total-throughput,${bm_total_throughput}"
}

wait_for_sync_completion() {
	for i in {1..60}
	do
		${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -e "flush;"
		sleep 10
	done
    # Prometheus服务器信息
    local PROMETHEUS_URL=http://11.101.10.5:9090
    local PROMETHEUS_USER=admin
    local PROMETHEUS_PASS=admin

    # 关联数组：追踪每个DataNode上一次的sync lag状态（true=上一次>0，false=上一次=0）
    declare -A last_node_status

    echo "开始监控 Total Sync Lag，直到所有 DataNode 的 Sync Lag 均为 0 为止..."

    while true; do
        # 标记本次检测是否所有节点都为0（核心退出条件）
        local all_zero=true
        # 标记本次是否有节点>0（用于状态追踪）
        local has_non_zero=false

        # 调用 Prometheus API 获取 Total Sync Lag（使用 URL 编码）
        local response=$(curl -s -u "$PROMETHEUS_USER:$PROMETHEUS_PASS" \
            "$PROMETHEUS_URL/api/v1/query?query=iot_consensus%7Bcluster%3D%22$CLUSTER_ID%22%2CnodeType%3D%22DATANODE%22%2Cname%3D%22ioTConsensusServerImpl%22%2Ctype%3D%22syncLag%22%7D")

        # 检查响应是否成功
        if [[ $(echo "$response" | jq -r '.status') != "success" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 错误: 无法从 Prometheus 获取数据"
            echo "响应: $response"
            sleep 1
            continue
        fi

        # 提取结果列表，避免重复解析jq
        local results=$(echo "$response" | jq -r '.data.result')
        local result_count=$(echo "$results" | jq -r 'length')

        if [[ $result_count -eq 0 ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 警告: 未找到 Total Sync Lag 指标数据"
            sleep 1
            continue
        fi

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 找到 $result_count 个 Total Sync Lag 指标"

        # 遍历每个DataNode的指标
        for ((i=0; i<result_count; i++)); do
            # 一次性提取当前节点的所有信息
            local instance=$(echo "$results" | jq -r ".[$i].metric.instance")
            local sync_lag=$(echo "$results" | jq -r ".[$i].value[1]")
            local cluster=$(echo "$results" | jq -r ".[$i].metric.cluster")
            local node_type=$(echo "$results" | jq -r ".[$i].metric.nodeType")

            echo "  实例 $instance: Total Sync Lag = $sync_lag (集群: $cluster, 类型: $node_type)"

            # 浮点数比较：判断当前sync lag是否>0（容忍微小精度误差）
            if (( $(echo "$sync_lag > 0.0001" | bc -l) )); then
                has_non_zero=true
                all_zero=false  # 只要有一个节点>0，就不满足退出条件

                # 核心逻辑：只有上一次状态也是>0时，才累加fail_flag
                if [[ ${last_node_status[$instance]} == "true" ]]; then
                    ((fail_flag++))
                    ((sync_fail_flag++))
                    v_warnMessage="sync lag > 0: 实例 $instance 持续大于0，fail_flag 累加至 $fail_flag"
                    echo "  ⚠️  $v_warnMessage"
                else
                    # 首次检测到>0，仅更新状态，不累加
                    v_warnMessage="sync lag > 0: 实例 $instance 首次大于0，暂不累加fail_flag"
                    echo "  ⚠️  $v_warnMessage"
                fi

                # 更新当前节点的状态为>0
                last_node_status[$instance]="true"
            else
                # sync lag=0，更新状态为false，不累加
                last_node_status[$instance]="false"
            fi
        done

        # 核心退出条件：本次检测所有节点Sync Lag均为0
        if $all_zero; then
            echo "🎉 同步完成！所有 DataNode 的 Total Sync Lag 均为 0"
            echo "最终 fail_flag: $fail_flag, sync_fail_flag: $sync_fail_flag"
            return 0
        fi

        # 存在节点>0，继续监控（间隔1秒检测一次）
        echo "  ❌ 仍有DataNode Sync Lag>0，1秒后继续检测..."
        sleep 1
    done
}
function get_bm_test_time()
{
   v_bm_start_time=`grep "^${current_date}" ${bm_dir}/${v_time}_${bm_desc}_1.out|head -1|awk -F ',' '{print $1}'` 
   v_bm_end_time=`grep "^${next_7d_date}" ${bm_dir}/${v_time}_${bm_desc}_1.out|tail -1|awk -F ',' '{print $1}'`
   echo "benchmark 测试时间范围: ${v_bm_start_time} - ${v_bm_end_time}"
   v_bm_start_sec=`date -d"${v_bm_start_time}" +%s`
   v_bm_start_ms=$((v_bm_start_sec*1000))
   v_bm_end_sec=`date -d"${v_bm_end_time}" +%s`
   v_bm_end_ms=$((v_bm_end_sec*1000))
   v_monitor_perf="http://11.101.10.5:3000/d/ZRfEph04y/apache-iotdb-performance-overview-dashboard?orgId=1&from=${v_bm_start_ms}&to=${v_bm_end_ms}"
   v_monitor_datanode="http://11.101.10.5:3000/d/TbEVYRw7B/apache-iotdb-datanode-dashboard?orgId=1&from=${v_bm_start_ms}&to=${v_bm_end_ms}"
   v_monitor_system="http://11.101.10.5:3000/d/AXEPYc-Va/apache-iotdb-system-dashboard?orgId=1&from=${v_bm_start_ms}&to=${v_bm_end_ms}&var-cluster=defaultCluster&var-nodeType=DATANODE&var-instance=All"
   echo "performance 监控地址: ${v_monitor_perf}"
   echo "datanode 监控地址: ${v_monitor_datanode}"
   echo "system 监控地址: ${v_monitor_system}"
   v_bm1_failOperation=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_1.out -A 12|tail -12|awk '{sum+=$4}END{print sum}'`
   v_bm2_failOperation=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_2.out -A 12|tail -12|awk '{sum+=$4}END{print sum}'`
   if [[ ${v_bm1_failOperation} -gt 0 ]]||[[ ${v_bm2_failOperation} -gt 0 ]];then
	   echo "WARN: benchmark has failed. bm1_failOperation=${v_bm1_failOperation},bm2_failOperation=${v_bm2_failOperation}"
   fi
   v_bm1_through=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_1.out -A 1|tail -1|awk '{print $6}'`
   v_bm2_through=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_2.out -A 1|tail -1|awk '{print $6}'`
   v_bm_total_through=$((v_bm1_through+v_bm2_through))
   echo "benchmark throughput(point/s):"
   echo "${v_bm1_through}"
   echo "${v_bm2_through}"
   echo "${v_bm_total_through}"
   v_bm1_okpoint=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_1.out -A 1|tail -1|awk '{print $3}'`
   v_bm2_okpoint=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_2.out -A 1|tail -1|awk '{print $3}'`
   v_bm_total_okpoint=$((v_bm1_okpoint+v_bm2_okpoint))
   echo "benchmark okPoint:"
   echo "${v_bm1_okpoint}"
   echo "${v_bm2_okpoint}"
   echo "${v_bm_total_okpoint}"
   v_bm1_query_every_avg_ms=`grep Matrix ${bm_dir}/${v_time}_${bm_desc}_1.out -A 13|tail -13|grep -v "Operation"|grep -v INGESTION|grep -v "AGG_VALUE "|grep -v "GROUP_BY_DESC "|awk '{print $2}'`
   v_bm2_query_every_avg_ms=`grep Matrix ${bm_dir}/${v_time}_${bm_desc}_2.out -A 13|tail -13|grep -v "Operation"|grep -v INGESTION|grep -v "AGG_VALUE "|grep -v "GROUP_BY_DESC "|awk '{print $2}'`
   v_bm1_query_total_avg_ms=`grep Matrix ${bm_dir}/${v_time}_${bm_desc}_1.out -A 13|tail -13|grep -v "Operation"|grep -v INGESTION|grep -v "AGG_VALUE "|grep -v "GROUP_BY_DESC "|awk '{sum+=$2}END{print sum}'`
   v_bm2_query_total_avg_ms=`grep Matrix ${bm_dir}/${v_time}_${bm_desc}_2.out -A 13|tail -13|grep -v "Operation"|grep -v INGESTION|grep -v "AGG_VALUE "|grep -v "GROUP_BY_DESC "|awk '{sum+=$2}END{print sum}'`
   v_2bm_query_total_avg_ms=$((v_bm1_query_total_avg_ms+v_bm2_query_total_avg_ms))
   echo "benchmark query avg latency (:ms)"
   echo "${v_bm1_query_every_avg_ms}"
   echo "${v_bm1_query_total_avg_ms}"
   echo "---------"
   echo "${v_bm2_query_every_avg_ms}"
   echo "${v_bm2_query_total_avg_ms}"
   echo "---------"
   echo "${v_2bm_query_total_avg_ms}"
   v_bm1_first_okpoint=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_1.out -A 1|head -2|tail -1|awk '{print $3}'`
   v_bm1_last_okpoint=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_1.out -A 1|tail -1|awk '{print $3}'`
   v_bm2_first_okpoint=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_2.out -A 1|head -2|tail -1|awk '{print $3}'`
   v_bm2_last_okpoint=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_2.out -A 1|tail -1|awk '{print $3}'`
   v_bm1_last_pre_okpoint=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_1.out -A 1|grep INGESTION|tail -2|head -1|awk '{print $3}'`
   v_bm2_last_pre_okpoint=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_2.out -A 1|grep INGESTION|tail -2|head -1|awk '{print $3}'`
   if [[ ${v_bm1_last_pre_okpoint} = ${v_bm1_last_okpoint} ]];then
	   v_bm1_last_pre_okpoint=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_1.out -A 1|grep INGESTION|tail -3|head -1|awk '{print $3}'`
   fi
   if [[ ${v_bm2_last_pre_okpoint} = ${v_bm2_last_okpoint} ]];then
           v_bm2_last_pre_okpoint=`grep throughput ${bm_dir}/${v_time}_${bm_desc}_2.out -A 1|grep INGESTION|tail -3|head -1|awk '{print $3}'`
   fi
   v_last_diff_bm1_okpoint=$((v_bm1_last_okpoint-v_bm1_last_pre_okpoint)) 
   v_last_diff_bm2_okpoint=$((v_bm2_last_okpoint-v_bm2_last_pre_okpoint))
   v_last_diff_total=$((v_last_diff_bm1_okpoint+v_last_diff_bm2_okpoint))
   v_first_diff_total=$((v_bm1_first_okpoint+v_bm2_first_okpoint))
   # ========== 核心：用bc计算浮点数除法 ==========
# 1. 先判断除数是否为0，避免bc报错
if [[ $v_first_diff_total -eq 0 ]]; then
    div_result="0.0000"  # 除数为0时默认返回0
else
    # 2. 调用bc计算，scale=4表示保留4位小数（可按需调整）
    div_result=$(echo "scale=4; $v_last_diff_total / $v_first_diff_total" | bc -l)
fi
echo "最后6小时写入的总点数除以第1个6小时写入的总点数："
echo "${div_result}"

}
function check_log()
{
exec 3<${cur_dir}/confignode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "gunzip ${db_dir}/logs/*confignode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err1=`ssh ${os_user_name}@${line} "grep BufferUnderflowException ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err2=`ssh ${os_user_name}@${line} "grep \"but return HAS_MORE_STATE\" ${db_dir}/logs/*confignode*all*|wc -l"`
   if [[ ${v_npe} -gt 0 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}CN NPE."
           echo "CN ${line} NullPointer : ${v_npe}"
   fi
   v_cn_err_total=$((v_cn_err1+v_cn_err2))
   if [[ ${v_cn_err_total} -gt 0 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}CN HAS_MORE_STATE."
           echo "CN ${line} has error: ${v_npe}"
   fi
done
exec 3<${cur_dir}/datanode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "gunzip ${db_dir}/logs/*datanode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err=`ssh ${os_user_name}@${line} "grep CompactionTableSchemaNotMatchException ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err2=`ssh ${os_user_name}@${line} "grep \"has overlapped data\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err3=`ssh ${os_user_name}@${line} "grep \"which should be later than the last time\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err4=`ssh ${os_user_name}@${line} "grep \"DataTypeInconsistentException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err5=`ssh ${os_user_name}@${line} "grep \"ArrayIndexOutOfBoundsException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err6=`ssh ${os_user_name}@${line} "grep \"Alter timeseries .* data type from null to\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err7=`ssh ${os_user_name}@${line} "grep \"StatisticsClassException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err8=`ssh ${os_user_name}@${line} "grep \"BufferUnderflowException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err9=`ssh ${os_user_name}@${line} "grep \"NegativeArraySizeException\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_err10=`ssh ${os_user_name}@${line} "grep \"is not in tsFileMetaData\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_dn_total_err=$((v_err+v_err2+v_err3+v_err4+v_err5+v_err6+v_err7+v_err8+v_err9+v_err10))
   if [[ ${v_npe} -gt 0 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}DN NPE."
           echo "DN ${line} NullPointer : ${v_npe}"
   fi
   if [[ ${v_dn_total_err} -gt 0 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}DN unexpected log."
           echo "DN ${line} has error: ${v_dn_total_err}"
   fi

done


}

stop_dn_rm_data ${db_name} 
set_conf
start_dn
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "CREATE USER tree_user '1Qaz2wsx!123456';grant all ON root.** TO USER tree_user WITH GRANT OPTION;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "CREATE USER table_user '1Qaz2wsx!123456';GRANT ALL TO USER table_user;"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "list user;"
start_bm ${db_name} 
wait_for_sync_completion
sh -x check_tree_table_lt_user.sh ${db_name}_check_data "${v_time}_${bm_desc}_1.out" "${v_time}_${bm_desc}_2.out" 2>&1
get_bm_test_time
check_log
echo "fail flag:${fail_flag}"
