#!/bin/bash
# ============================================================================
# tc2026_April_003502  数据分区表修复 — 手动触发 REPAIR（IoTV2 共识·ns 精度）
# ----------------------------------------------------------------------------
# 对应用例：[DPR_A01] 黄金主路径的 IoTConsensusV2 共识协议变体
#           顺带覆盖 DPR_A02(异步立即返回)、DPR_A05(须手动触发)、DPR_E03(修复
#           后写新数据+逐停DN校验, 验证修复不影响在线业务)、DPR_E04(升级兼容)。
#
# 与 003501/003801 的关键区别：
#   consensus = IoTConsensusV2（Ratis-based），区别于 IoTConsensus（IotConsensus）
#   003501: IoTConsensus + ns + v2061rc7 备份
#   003801: IoTConsensus + ms + v1365 备份
#   003502(本脚本): IoTConsensusV2 + ns + v2061rc7 IoTV2 备份
#
# 实现背景（当前 build：master_0710_621a77d / TimechoDB 2.0.11-SNAPSHOT）：
#   数据分区表修复由「手动执行 SQL」触发（仅树方言有此语法入口）：
#       REPAIR DATA PARTITION TABLE;                 (异步, 立即返回成功)
#       SHOW REPAIR DATA PARTITION TABLE PROGRESS;   (查询进度)
#
# 前置「分区丢失」由预置备份构造：
#   备份 ${backup_dir} 是在 v2.0.6.1 RC7（ns 精度、IoTV2 共识、设备级 TTL）
#   上预先构造好 loss 后保存的三盘集群数据。恢复到 master 数据目录后直接起集群，
#   等价于"从 v2.0.6.1 RC7 IoTV2 升级到本版本、且带着分区丢失"。
#
# 流程：
#   1) 清理/配置 master(IoTV2 共识, ns 精度)/恢复备份/起集群；            [start_db]
#   2) 【DPR_A05】修复前先查数据：分区丢失未自行修复；
#   3) 手动 REPAIR DATA PARTITION TABLE;，轮询进度，校验修复日志；
#   4) 修复后写入新数据(benchmark partition_table_ns)；                  [DPR_E03]
#   5) 全在线校验 + 逐停 DN 比对 diff=0；                               [DPR_A01]
#   6) 重启后复验；扫描 CN/DN 非预期异常。
#
# 兼容所有 Bash 版本（含 3.x）。
# ============================================================================
set -uo pipefail
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
cli_dir=${db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
CSV_FILE=$(grep ^CSV_FILE "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')

cn_num=3; dn_num=3; dr_rep_num=2; sr_rep_num=3
total_node_num=$((cn_num+dn_num))
v_warnNum=0; v_warnMessage="."; v_consensus="IoTConsensusV2"
log_file="${cur_dir}/set_conf_parallel.log"
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
ssl_str=""
data1_dir="/data1/iotdb_data/${testdb}/data"
data1_dir_parent="/data1/iotdb_data/${testdb}/"
data3_dir="/data3/iotdb_data/${testdb}/data"
data3_dir_parent="/data3/iotdb_data/${testdb}/"
bm_dir="${cur_dir}/../benchmark/bm_20251220_38c839b_v20"
bm_conf="partition_table_ns"
# 预置 loss 备份（v2061rc7 / ns 精度 / IoTV2 共识 / 设备级 TTL 构造, 三盘）
backup_dir="/data2/tc2026_data_backup/v2061_rc7_0915_802dd96_ns_ttl_iotv2"

rm -rf "${nodeinfo_dir}/confignode.txt" "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt"   "${nodeinfo_dir}/datanode.txt"

seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

fail_flag=0; backup_log_flag=0; test_begin_sec=$(date +%s)

# ===================== 工具函数 =====================
log() {
    local level=$1; local msg=$2
    local ts=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${ts}] [${level}] ${msg}" >> "${log_file}"
    echo "[${ts}] [${level}] ${msg}"
}
run_sql() {
    local dialect=$1; local sql=$2; local outfile=$3
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} \
        -sql_dialect ${dialect} -timeout 36000 -e "${sql}" > "${outfile}" 2>&1
}

clean_env() {
   log "INFO" "清理集群环境..."
   sh -x "${clean_env_dir}/stop_cluster.sh"  >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/reset_conf.sh"    >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/clear_cache.sh"   >> "${log_file}" 2>&1
   log "INFO" "集群环境清理完成"
}

configure_confignode() {
    local node_ip=$1
    log "INFO" "配置ConfigNode: ${node_ip}"
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="2G"/g' ${db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${db_dir}/conf/confignode-env.sh
        batch_set() { local s=\$1; local c=\$2; local f="${db_dir}/conf/iotdb-system.properties"
            if grep -q "\$s" "\$f"; then sed -i "s|\$s|\$c|g" "\$f"; else echo "\$c" >> "\$f"; fi; }
        batch_set ".*cn_seed_config_node=.*" "cn_seed_config_node=${seed_cn_ip}"
        batch_set ".*cn_internal_address=.*" "cn_internal_address=${node_ip}"
        batch_set ".*cn_metric_reporter_list=.*" "cn_metric_reporter_list=PROMETHEUS"
        batch_set ".*cn_metric_prometheus_reporter_port=.*" "cn_metric_prometheus_reporter_port=9081"
        batch_set ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=2"
        batch_set ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=2"
        batch_set ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        batch_set ".*timestamp_precision=.*" "timestamp_precision=ns"
        batch_set ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
EOF
    [ $? -eq 0 ] && log "INFO" "ConfigNode ${node_ip} 配置完成" || { log "ERROR" "CN ${node_ip} 失败"; return 1; }
}

configure_datanode() {
    local node_ip=$1
    log "INFO" "配置DataNode: ${node_ip}"
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${db_dir}/conf/datanode-env.sh
        batch_set() { local s=\$1; local c=\$2; local f="${db_dir}/conf/iotdb-system.properties"
            if grep -q "\$s" "\$f"; then sed -i "s|\$s|\$c|g" "\$f"; else echo "\$c" >> "\$f"; fi; }
        batch_set ".*dn_seed_config_node=.*" "dn_seed_config_node=${seed_cn_ip}"
        batch_set ".*dn_internal_address=.*" "dn_internal_address=${node_ip}"
        batch_set ".*dn_rpc_address=.*" "dn_rpc_address=${node_ip}"
        batch_set ".*dn_metric_reporter_list=.*" "dn_metric_reporter_list=PROMETHEUS"
        batch_set ".*dn_metric_prometheus_reporter_port=.*" "dn_metric_prometheus_reporter_port=9091"
        batch_set ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=2"
        batch_set ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=2"
        batch_set ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        batch_set ".*timestamp_precision=.*" "timestamp_precision=ns"
        batch_set ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        f="${db_dir}/conf/iotdb-system.properties"
        sed -i 's|.*dn_data_dirs=.*|dn_data_dirs=data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data,/data3/iotdb_data/${testdb}/data/datanode/data|g' \$f
        sed -i 's|.*dn_wal_dirs=.*|dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal,/data3/iotdb_data/${testdb}/data/datanode/wal|g' \$f
EOF
    [ $? -eq 0 ] && log "INFO" "DataNode ${node_ip} 配置完成" || { log "ERROR" "DN ${node_ip} 失败"; return 1; }
}

configure_mixed_node() {
    local node_ip=$1
    configure_confignode "${node_ip}" && configure_datanode "${node_ip}"
}

set_conf() {
    log "INFO" "配置所有节点(IoTConsensusV2)..."
    local line
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        configure_mixed_node "${line}" || fail_flag=1
    done
    exec 3<&-
}

start_db() {
    log "INFO" "===== [START] 清理/配置(IoTV2)/恢复备份/起 master ====="
    clean_env; set_conf
    [ ${fail_flag} -ne 0 ] && { log "ERROR" "配置失败"; return 1; }
    log "INFO" "恢复 loss 备份 ${backup_dir} 到三盘..."
    local line
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        ssh ${os_user_name}@${line} "test -d ${data1_dir_parent} || sudo mkdir ${data1_dir_parent}" >> "${log_file}" 2>&1
        ssh ${os_user_name}@${line} "test -d ${data3_dir_parent} || sudo mkdir ${data3_dir_parent}" >> "${log_file}" 2>&1
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data1_backup ${data1_dir}" >> "${log_file}" 2>&1 || { let fail_flag++; v_warnMessage="${v_warnMessage}copy data1 failed."; }
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data2_backup ${db_dir}/data" >> "${log_file}" 2>&1 || { let fail_flag++; v_warnMessage="${v_warnMessage}copy data2 failed."; }
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data3_backup ${data3_dir}" >> "${log_file}" 2>&1 || { let fail_flag++; v_warnMessage="${v_warnMessage}copy data3 failed."; }
        sleep 1
    done
    exec 3<&-
    sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1 || { log "ERROR" "master 集群启动失败"; let fail_flag++; return 1; }
    log "INFO" "master 集群启动成功"
}

wait_cluster_ready() {
    local max=$1; local waited=0
    while true; do
        run_sql tree "show cluster;" "${cur_dir}/tmp.out"
        local ok=$(grep -E "Running|ReadOnly" "${cur_dir}/tmp.out" | wc -l)
        [ ${ok} -ge ${total_node_num} ] && { log "INFO" "集群就绪:${ok}/${total_node_num}"; return 0; }
        sleep 5; waited=$((waited+5))
        [ ${waited} -gt ${max} ] && { log "ERROR" "集群${max}s未就绪(${ok}/${total_node_num})"; let fail_flag++; return 1; }
    done
}

rgrep_count() {
    local n=$(ssh ${os_user_name}@$1 "sudo grep -F \"$2\" $3 2>/dev/null | wc -l" | tr -dc '0-9')
    echo "${n:-0}"
}
cn_log_has() {
    local pat=$1 line hit total=0
    exec 4<"${nodeinfo_dir}/confignode.txt"
    while read line <&4; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*confignode*all* 2>/dev/null; true" >/dev/null 2>&1
        hit=$(rgrep_count "${line}" "${pat}" "${db_dir}/logs/*confignode*all*")
        total=$((total + hit))
    done
    exec 4<&-
    [ "$total" -gt 0 ]
}

g_tree_rows=0; g_t1_rows=0; g_t2_rows=0; g_exc=0; g_data_sum=0
query_data() {
    local phase=$1; local host=${2:-${query_ip}}
    local sql_tree="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from root.test.g_0.** align by device;"
    local sql_t1="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table1_0 group by device_id order by device_id;"
    local sql_t2="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table2_0 group by device_id order by device_id;"
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${host} -sql_dialect tree  -timeout 36000 -e "${sql_tree}" > "${cur_dir}/${phase}_tree.out" 2>&1
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${host} -sql_dialect table -timeout 36000 -e "${sql_t1}"   > "${cur_dir}/${phase}_table1.out" 2>&1
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${host} -sql_dialect table -timeout 36000 -e "${sql_t2}"   > "${cur_dir}/${phase}_table2.out" 2>&1
    g_tree_rows=$(grep -c "root.test" "${cur_dir}/${phase}_tree.out")
    g_t1_rows=$(grep -oE "Total line number = [0-9]+" "${cur_dir}/${phase}_table1.out" | grep -oE "[0-9]+" | tail -1); g_t1_rows=${g_t1_rows:-0}
    g_t2_rows=$(grep -oE "Total line number = [0-9]+" "${cur_dir}/${phase}_table2.out" | grep -oE "[0-9]+" | tail -1); g_t2_rows=${g_t2_rows:-0}
    g_data_sum=$(grep -oE "[0-9]+" "${cur_dir}/${phase}_tree.out" | awk '{s+=$1} END{print s+0}')
    g_exc=$(grep -cE "Exception|Msg: [0-9]+:" "${cur_dir}/${phase}_tree.out" "${cur_dir}/${phase}_table1.out" "${cur_dir}/${phase}_table2.out" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
    log "INFO" "[${phase}@${host}] tree行=${g_tree_rows} t1行=${g_t1_rows} t2行=${g_t2_rows} 数据点=${g_data_sum} 异常=${g_exc}"
}

verify_full() {
    local phase=$1
    query_data "${phase}" "${query_ip}"
    if [[ ${g_exc} -eq 0 && ${g_tree_rows} -eq 20 && ${g_t1_rows} -eq 10 && ${g_t2_rows} -eq 10 ]]; then
        log "INFO" "[PASS:${phase}] 全在线完整:tree=${g_tree_rows}/20 table1=${g_t1_rows}/10 table2=${g_t2_rows}/10"
    else
        log "ERROR" "[FAIL:${phase}] 全在线不完整:tree=${g_tree_rows}/20 table1=${g_t1_rows}/10 table2=${g_t2_rows}/10 异常=${g_exc}"
        cat "${cur_dir}/${phase}_tree.out"
        let fail_flag++; v_warnMessage="${v_warnMessage}${phase} data incomplete."
    fi
}

# ============================================================================
# 修复操作
# ============================================================================
manual_repair() {
    log "INFO" "===== [REPAIR] 手动触发 REPAIR DATA PARTITION TABLE (树方言) ====="
    local t0=$(date +%s%3N 2>/dev/null || date +%s)
    run_sql tree "REPAIR DATA PARTITION TABLE;" "${cur_dir}/repair_trigger.out"
    local t1=$(date +%s%3N 2>/dev/null || date +%s)
    if grep -q "The statement is executed successfully." "${cur_dir}/repair_trigger.out"; then
        log "INFO" "[PASS] REPAIR 触发成功(立即返回)。耗时=$((t1-t0))"
    else
        log "ERROR" "[FAIL] REPAIR 触发失败"; cat "${cur_dir}/repair_trigger.out"; let fail_flag++
        v_warnMessage="${v_warnMessage}REPAIR trigger failed."
    fi
    local waited=0
    while true; do
        run_sql tree "SHOW REPAIR DATA PARTITION TABLE PROGRESS;" "${cur_dir}/repair_progress.out"
        if cn_log_has "DataPartitionTables merge completed successfully"; then
            log "INFO" "[PASS] merge completed，修复完成"; break
        fi
        grep -qE "100\.0|100 *%" "${cur_dir}/repair_progress.out" && { log "INFO" "进度 100%"; break; }
        sleep 5; waited=$((waited+5))
        [ ${waited} -gt 300 ] && { log "WARN" "修复 300s 未完成"; cat "${cur_dir}/repair_progress.out"; break; }
    done
}

check_repair_logs() {
    log "INFO" "===== [LOG] 校验 CN 修复关键日志 ====="
    cn_log_has "has lost timeslot" && log "INFO" "[PASS] CN 含 'has lost timeslot' (loss 已检出)" || { log "ERROR" "[FAIL] CN 缺 'has lost timeslot'"; let fail_flag++; v_warnMessage="${v_warnMessage}no lost-timeslot."; }
    cn_log_has "DataPartitionTables merge completed successfully" && log "INFO" "[PASS] CN 含 'DataPartitionTables merge completed'" || { log "ERROR" "[FAIL] CN 缺 'merge completed'"; let fail_flag++; v_warnMessage="${v_warnMessage}no merge-completed."; }
    cn_log_has "DataPartitionTable successfully written to consensus log" && log "INFO" "[PASS] CN 含 'written to consensus log'" || log "INFO" "[NOTE] 未见 'written to consensus log'（不判失败）"
}

# --------- benchmark ---------
start_bm() {
    log "INFO" "===== [BM] 写新数据(benchmark ${bm_conf})以验证修复不影响后续写入 ====="
    local bm_log_dir="${bm_dir}/${testdb}"
    [ ! -d "${bm_log_dir}" ] && mkdir -p "${bm_log_dir}"
    sed -i "s/^PASSWORD=.*/PASSWORD=TimechoDB@2021/g" ${bm_dir}/${bm_conf}/conf*/config.properties
    local t=$(date +%Y_%m_%d_%H_%M_%S)
    nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf5 >> ${bm_log_dir}/${t}_bm5.out &
    nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf6 >> ${bm_log_dir}/${t}_bm6.out &
    nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf7 >> ${bm_log_dir}/${t}_bm7.out &
    nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf8 >> ${bm_log_dir}/${t}_bm8.out &
    wait
    log "INFO" "benchmark 写入完成"
}

# --------- 停一个 DN 的数据一致性校验 ---------
check_data_consistent() {
    log "INFO" "===== [CONSISTENCY] 全在线基准 + 逐 DN 停一个比对 ====="
    run_sql tree "flush;" "${cur_dir}/tmp.out"
    query_data "ref_all_online" "${query_ip}"
    local line v_ip
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};sudo ./sbin/stop-datanode.sh" >> "${log_file}" 2>&1
        local t1=$(date +%s)
        while true; do
            local pid=$(ssh ${os_user_name}@${line} "sudo jps | grep DataNode" | awk '{print $1}')
            [ -z "${pid}" ] && break
            sleep 3; [ $(( $(date +%s) - t1 )) -gt 120 ] && { log "WARN" "DN ${line} 停不下来, kill -9"; ssh ${os_user_name}@${line} "sudo kill -9 ${pid}">/dev/null 2>&1; break; }
        done
        v_ip=$(echo ${line}|awk -F '.' '{print $4}')
        # 从存活 DN 找查询入口（排除被停的）
        local cur_host=""
        exec 4<"${nodeinfo_dir}/datanode.txt"
        local candidate
        while read candidate <&4; do
            candidate=$(echo "${candidate}"|sed 's/ //g'); [ -z "${candidate}" ] && continue
            [ "${candidate}" = "${line}" ] && continue
            local alive=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${candidate} -timeout 60 -e "show datanodes;" 2>/dev/null | grep "${candidate}|" | grep -c Running)
            [ "${alive:-0}" -ge 1 ] && { cur_host="${candidate}"; exec 4<&-; break; }
        done
        exec 4<&-
        [ -z "${cur_host}" ] && { log "ERROR" "停 ${line} 后无可用 DN 查询入口"; let fail_flag++; continue; }
        query_data "stop${v_ip}" "${cur_host}"
        local diff_tree=$(diff "${cur_dir}/ref_all_online_tree.out" "${cur_dir}/stop${v_ip}_tree.out" | grep -c "root.test")
        local diff_t1=$(diff "${cur_dir}/ref_all_online_table1.out" "${cur_dir}/stop${v_ip}_table1.out" | grep -c "d_")
        local diff_t2=$(diff "${cur_dir}/ref_all_online_table2.out" "${cur_dir}/stop${v_ip}_table2.out" | grep -c "d_")
        local diff_total=$((diff_tree + diff_t1 + diff_t2))
        if [[ ${diff_total} -gt 0 ]]; then
            log "ERROR" "[FAIL] 缺 DN ${v_ip} 时数据不一致 diff=${diff_total}"
            diff "${cur_dir}/ref_all_online_tree.out" "${cur_dir}/stop${v_ip}_tree.out"
            let fail_flag++; v_warnMessage="${v_warnMessage} data inconsistent stop${v_ip}."
        else
            log "INFO" "[PASS] 缺 DN ${v_ip} 时数据一致 diff=0"
        fi
        local ts=$(date +%s)
        ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};sudo ./sbin/start-datanode.sh -H ${db_dir}/dn_${ts}_heapdump.hprof > /dev/null 2>&1 &" >> "${log_file}" 2>&1
        while true; do
            local ok=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${line} -timeout 3600 -e "show datanodes;" 2>/dev/null | grep "${line}|" | grep -c Running)
            [ "${ok:-0}" -ge 1 ] && break
            sleep 2; [ $(( $(date +%s) - ts )) -gt 180 ] && { log "ERROR" "DN ${line} 重启超时"; let fail_flag++; break; }
        done
    done
    exec 3<&-
}

# --------- 异常日志扫描 ---------
check_unexpected_logs() {
    log "INFO" "===== [LOG] 扫描非预期异常 ====="
    local line g
    exec 3<"${nodeinfo_dir}/confignode.txt"
    while read line <&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*confignode*all* 2>/dev/null; true" >/dev/null 2>&1
        g="${db_dir}/logs/*confignode*all*"
        local npe=$(rgrep_count "${line}" "NullPointerException" "${g}")
        local buf=$(rgrep_count "${line}" "BufferUnderflowException" "${g}")
        local cce=$(rgrep_count "${line}" "ClassCastException" "${g}")
        [ $(( npe + buf + cce )) -gt 0 ] && { log "ERROR" "CN ${line}: NPE=${npe} Buf=${buf} CCE=${cce}"; let fail_flag++; let backup_log_flag++; v_warnMessage="${v_warnMessage}CN ${line} unexp."; }
    done
    exec 3<&-
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*datanode*all* 2>/dev/null; true" >/dev/null 2>&1
        g="${db_dir}/logs/*datanode*all*"
        local npe=$(rgrep_count "${line}" "NullPointerException" "${g}")
        local aioobe=$(rgrep_count "${line}" "ArrayIndexOutOfBoundsException" "${g}")
        local dtie=$(rgrep_count "${line}" "DataTypeInconsistentException" "${g}")
        local nase=$(rgrep_count "${line}" "NegativeArraySizeException" "${g}")
        local cce=$(rgrep_count "${line}" "ClassCastException" "${g}")
        local buf=$(rgrep_count "${line}" "BufferUnderflowException" "${g}")
        [ $(( npe + aioobe + dtie + nase + cce + buf )) -gt 0 ] && { log "ERROR" "DN ${line}: NPE=${npe} AIOOBE=${aioobe} DTIE=${dtie} NASE=${nase} CCE=${cce} Buf=${buf}"; let fail_flag++; let backup_log_flag++; v_warnMessage="${v_warnMessage}DN ${line} unexp."; }
    done
    exec 3<&-
}

# ============================================================================
# 主测试
# ============================================================================
testcase1() {
    wait_cluster_ready 600 || return

    # DPR_A05: 修复前数据应受损
    log "INFO" "===== [DPR_A05] 修复前记录(数据应仍缺失) ====="
    query_data "0_before_repair"
    local b_sum=${g_data_sum}; local b_full=0
    [[ ${g_exc} -eq 0 && ${g_tree_rows} -eq 20 && ${g_t1_rows} -eq 10 && ${g_t2_rows} -eq 10 ]] && b_full=1
    if [[ ${b_full} -eq 1 ]]; then
        log "WARN" "[NOTE] 修复前数据已完整——以修复日志判定是否有 loss"
        v_warnMessage="${v_warnMessage} data already full before repair."
    else
        log "INFO" "[OK] 修复前数据不完整(数据点=${b_sum})，符合预期"
    fi

    # 手动 REPAIR
    manual_repair
    check_repair_logs

    # 修复后数据态：只校验树模型（表模型可能需 benchmark 填空）
    query_data "1_after_repair"
    if [[ ${g_tree_rows} -ne 20 ]]; then
        log "ERROR" "[FAIL] 修复后树数据未恢复:tree=${g_tree_rows}/20"
        let fail_flag++; v_warnMessage="${v_warnMessage}tree not recovered after repair."
    else
        log "INFO" "[PASS] 树模型数据 20/20 已恢复"
    fi

    # DPR_E03: 修复后写新数据（benchmark），验证修复不影响后续写入
    start_bm

    # 数据一致性：全在线基准 + 逐 DN 停一个比对 diff=0
    check_data_consistent

    # 重启复验
    log "INFO" "===== [RESTART] 重启后复验 ====="
    sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
    sh -x "${prepare_env_dir}/start_cluster_v20.sh" "2" "${total_node_num}" >> "${log_file}" 2>&1
    wait_cluster_ready 600
    verify_full "2_after_restart"
    check_unexpected_logs
}

# ============================================================================
# 主流程
# ============================================================================
echo "" > "${log_file}"
start_db
[ ${fail_flag} -eq 0 ] && testcase1 || log "ERROR" "起集群失败，跳过测试"

v_end_test_time=$(date +%s)
v_elp_time=$((v_end_test_time-test_begin_sec))

test_time=$(date +"%Y-%m-%dT%H:%M:%S.%3N%:z")
v_exist_flag=$(grep -c "Time,testTimechoDB" "$CSV_FILE" 2>/dev/null)
[ "${v_exist_flag:-0}" -eq 0 ] && echo "Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage" > "$CSV_FILE"
if [[ ${fail_flag} -gt 0 ]]; then
   echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},FAIL,${v_elp_time},${v_warnNum},${v_warnMessage}" >> "$CSV_FILE"
   echo "testcase FAIL : ${v_warnMessage}"
   v_backup_time=$(date +%s); v_backup_desc=$(echo ${SCRIPT_NAME} | awk -F '.' '{print $1}')
   sh ${clean_env_dir}/backup_cluster_logs.sh ${v_backup_time}_${v_backup_desc} 2>/dev/null || true
else
   echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},PASS,${v_elp_time},${v_warnNum},${v_warnMessage}" >> "$CSV_FILE"
   echo "testcase PASS"
fi
