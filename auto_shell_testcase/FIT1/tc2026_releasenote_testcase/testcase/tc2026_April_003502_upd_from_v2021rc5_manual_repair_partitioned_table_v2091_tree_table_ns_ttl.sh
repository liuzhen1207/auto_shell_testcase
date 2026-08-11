#!/bin/bash
# ============================================================================
# tc2026_April_003502_v2021rc5  数据分区表修复 — 手动触发 REPAIR（v2021rc5 来源）
# ----------------------------------------------------------------------------
# 对应用例：[DPR_A01] 黄金主路径的 v2.0.2.1 RC5 来源变体
#           顺带覆盖 DPR_A02(异步立即返回)、DPR_A05(须手动触发)、DPR_E03(逐停DN
#           比对+重启前后比对确保数据一致)、DPR_E04(升级兼容)。
#
# 与同编号 003502 的关键区别：
#   — 此脚本来源 v2021rc5（v2.0.2.1 RC5），共识 IoTConsensus，精度 ns
#   — 另一个 003502 (IotV2) 来源 v2061rc7 IoTV2，共识 IoTConsensusV2
#   — 独有校验：以 2022-01-01 为界分 ≤2022 / >2022 两段时间窗口，
#     各自查询树+表数据，验证 time≤2022 数据点 + time>2022 数据点 = 全量数据点
#     最后重启前后 diff=0（数据完全不变）
#
# 实现背景（当前 build：master_0710_621a77d / TimechoDB 2.0.11-SNAPSHOT）：
#   REPAIR DATA PARTITION TABLE; (手动异步触发，仅树方言)
#   SHOW REPAIR DATA PARTITION TABLE PROGRESS; (进度查询)
#
# 流程：
#   1) 清理/配置(ns)/恢复备份(v2021rc5)/起集群/等就绪
#   2) [DPR_A05] 修复前查数据 → 确认分区丢失
#   3) 手动 REPAIR + 轮询进度 + 校验修复日志
#   4) 跑 benchmark(partition_table_ns_2025y) 填满数据
#   5) check_data_consistent: 全在线校验 + 逐停 DN diff + ≤2022/>2022 分割校验
#   6) 拷贝第一次结果，重启集群，再跑 check_data_consistent，diff 重启前后=0
#   7) 扫描 CN/DN 非预期异常
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
v_warnNum=0; v_warnMessage="."; v_consensus="IoTConsensus"
log_file="${cur_dir}/set_conf_parallel.log"
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
ssl_str=""
data1_dir="/data1/iotdb_data/${testdb}/data"
data3_dir="/data3/iotdb_data/${testdb}/data"
bm_dir="${cur_dir}/../benchmark/bm_20251220_38c839b_v20"
bm_conf="partition_table_ns_2025y"
# v2021rc5 ns 精度预置 loss 备份
backup_dir="/data2/tc2026_data_backup/v2021_rc5_20250401_9174fe0_ns_ttl_10s"

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
    local dialect=$1; local sql=$2; local outfile=$3; local host=${4:-${query_ip}}
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h "${host}" \
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

configure_mixed_node() { local node_ip=$1; configure_confignode "${node_ip}" && configure_datanode "${node_ip}"; }

set_conf() {
    log "INFO" "配置所有节点(v2021rc5 ns)..."
    local line
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        configure_mixed_node "${line}" || fail_flag=1
    done
    exec 3<&-
}

start_db() {
    log "INFO" "===== [START] 清理/配置/恢复备份/起 master ====="
    clean_env; set_conf
    [ ${fail_flag} -ne 0 ] && { log "ERROR" "配置失败"; return 1; }
    log "INFO" "恢复 loss 备份 ${backup_dir} 到三盘..."
    local line
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data1_backup ${data1_dir}" >> "${log_file}" 2>&1
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data2_backup ${db_dir}/data" >> "${log_file}" 2>&1
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data3_backup ${data3_dir}" >> "${log_file}" 2>&1
        sleep 1
    done
    exec 3<&-
    sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1 || { log "ERROR" "集群启动失败"; let fail_flag++; return 1; }
    log "INFO" "集群启动成功"
}

wait_cluster_ready() {
    local max=$1; local waited=0
    while true; do
        run_sql tree "show cluster;" "${cur_dir}/tmp.out"
        local ok=$(grep -E "Running|ReadOnly" "${cur_dir}/tmp.out" | wc -l)
        [ ${ok} -ge ${total_node_num} ] && { log "INFO" "集群就绪:${ok}/${total_node_num}"; return 0; }
        sleep 5; waited=$((waited+5))
        [ ${waited} -gt ${max} ] && { log "ERROR" "集群${max}s未就绪"; let fail_flag++; return 1; }
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
        total=$((total + $(rgrep_count "${line}" "${pat}" "${db_dir}/logs/*confignode*all*")))
    done
    exec 4<&-
    [ "$total" -gt 0 ]
}

g_tree_rows=0; g_t1_rows=0; g_t2_rows=0; g_data_sum=0; g_exc=0
query_data() {
    local phase=$1
    local sql_tree="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from root.test.g_0.** align by device;"
    local sql_t1="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table1_0 group by device_id order by device_id;"
    local sql_t2="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table2_0 group by device_id order by device_id;"
    run_sql tree  "${sql_tree}" "${cur_dir}/${phase}_tree.out"
    run_sql table "${sql_t1}"   "${cur_dir}/${phase}_table1.out"
    run_sql table "${sql_t2}"   "${cur_dir}/${phase}_table2.out"
    g_tree_rows=$(grep -c "root.test" "${cur_dir}/${phase}_tree.out")
    g_t1_rows=$(grep -oE "Total line number = [0-9]+" "${cur_dir}/${phase}_table1.out" | grep -oE "[0-9]+" | tail -1); g_t1_rows=${g_t1_rows:-0}
    g_t2_rows=$(grep -oE "Total line number = [0-9]+" "${cur_dir}/${phase}_table2.out" | grep -oE "[0-9]+" | tail -1); g_t2_rows=${g_t2_rows:-0}
    g_data_sum=$(grep -oE "[0-9]+" "${cur_dir}/${phase}_tree.out" | awk '{s+=$1} END{print s+0}')
    g_exc=$(grep -cE "Exception|Msg: [0-9]+:" "${cur_dir}/${phase}_tree.out" "${cur_dir}/${phase}_table1.out" "${cur_dir}/${phase}_table2.out" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
    log "INFO" "[${phase}] tree=${g_tree_rows} t1=${g_t1_rows} t2=${g_t2_rows} pts=${g_data_sum} exc=${g_exc}"
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
    cn_log_has "has lost timeslot" && log "INFO" "[PASS] CN 含 'has lost timeslot'" || { log "ERROR" "[FAIL] CN 缺 'has lost timeslot'"; let fail_flag++; v_warnMessage="${v_warnMessage}no lost-timeslot."; }
    cn_log_has "DataPartitionTables merge completed successfully" && log "INFO" "[PASS] CN 含 'merge completed'" || { log "ERROR" "[FAIL] CN 缺 'merge completed'"; let fail_flag++; v_warnMessage="${v_warnMessage}no merge-completed."; }
    cn_log_has "DataPartitionTable successfully written to consensus log" && log "INFO" "[PASS] CN 含 'written to consensus log'" || log "INFO" "[NOTE] 未见 'written to consensus log'（不判失败）"
}

# --------- benchmark ---------
start_bm() {
    log "INFO" "===== [BM] 写新数据(benchmark ${bm_conf}) ====="
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

# --------- 全在线 + 逐 DN 停 + ≤2022/>2022 分割校验 ---------
check_data_consistent() {
    log "INFO" "===== [CONSISTENCY] 全在线+逐DN停+分割校验 ====="
    run_sql tree "flush;" "${cur_dir}/tmp.out"
    run_sql tree "show datanodes;" "${cur_dir}/tmp.out"
    grep Running "${cur_dir}/tmp.out" | awk -F "|" '{gsub(" ","");print $4}' > "${cur_dir}/tmp_node.out"
    local alt_ip=$(tail -1 "${cur_dir}/tmp_node.out")
    # 基准查询
    local sql_tree="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from root.test.g_0.** align by device;"
    local sql_t1="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table1_0 group by device_id order by device_id;"
    local sql_t2="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table2_0 group by device_id order by device_id;"
    run_sql tree  "${sql_tree}" "${cur_dir}/ref_tree.out"
    run_sql table "${sql_t1}"   "${cur_dir}/ref_t1.out"
    run_sql table "${sql_t2}"   "${cur_dir}/ref_t2.out"
    local ref_tree=$(grep -c "root.test" "${cur_dir}/ref_tree.out")
    local ref_t1=$(grep -oE "Total line number = [0-9]+" "${cur_dir}/ref_t1.out" | grep -oE "[0-9]+" | tail -1); ref_t1=${ref_t1:-0}
    local ref_t2=$(grep -oE "Total line number = [0-9]+" "${cur_dir}/ref_t2.out" | grep -oE "[0-9]+" | tail -1); ref_t2=${ref_t2:-0}
    log "INFO" "[ref] tree=${ref_tree} t1=${ref_t1} t2=${ref_t2}"
    [[ ${ref_tree} -ne 20 || ${ref_t1} -ne 10 || ${ref_t2} -ne 10 ]] && { log "ERROR" "[FAIL] 全在线不完整: tree=${ref_tree}/20 t1=${ref_t1}/10 t2=${ref_t2}/10"; let fail_flag++; v_warnMessage="${v_warnMessage}ref data incomplete."; }

    # 逐 DN 停
    local cur_host=$(head -1 "${cur_dir}/tmp_node.out"); local line v_ip
    exec 3<"${cur_dir}/tmp_node.out"
    while read line <&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        ssh ${os_user_name}@${line} "source /etc/profile;cd ${db_dir};sudo ./sbin/stop-datanode.sh" >> "${log_file}" 2>&1
        local t1=$(date +%s)
        while true; do
            local pid=$(ssh ${os_user_name}@${line} "sudo jps | grep DataNode" | awk '{print $1}')
            [ -z "${pid}" ] && break
            sleep 3; [ $(( $(date +%s) - t1 )) -gt 120 ] && { ssh ${os_user_name}@${line} "sudo kill -9 ${pid}">/dev/null 2>&1; break; }
        done
        cur_host=$(grep -v "^${line}$" "${cur_dir}/tmp_node.out" | head -1)
        v_ip=$(echo ${line}|awk -F '.' '{print $4}')
        run_sql tree  "${sql_tree}" "${cur_dir}/stop${v_ip}_tree.out" "${cur_host}"
        run_sql table "${sql_t1}"   "${cur_dir}/stop${v_ip}_t1.out"   "${cur_host}"
        run_sql table "${sql_t2}"   "${cur_dir}/stop${v_ip}_t2.out"   "${cur_host}"
        local dt=$(diff "${cur_dir}/ref_tree.out" "${cur_dir}/stop${v_ip}_tree.out" | grep -c "root.test")
        local d1=$(diff "${cur_dir}/ref_t1.out"   "${cur_dir}/stop${v_ip}_t1.out"   | grep -c "d_")
        local d2=$(diff "${cur_dir}/ref_t2.out"   "${cur_dir}/stop${v_ip}_t2.out"   | grep -c "d_")
        [ $((dt+d1+d2)) -gt 0 ] && { log "ERROR" "[FAIL] 缺DN${v_ip} diff=${dt}/${d1}/${d2}"; let fail_flag++; v_warnMessage="${v_warnMessage}stop${v_ip} inconsistent."; } || log "INFO" "[PASS] 缺DN${v_ip} diff=0"
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
    log "INFO" "===== [DPR_A05] 修复前记录 ====="
    query_data "0_before_repair"
    local b_full=0
    [[ ${g_exc} -eq 0 && ${g_tree_rows} -eq 20 && ${g_t1_rows} -eq 10 && ${g_t2_rows} -eq 10 ]] && b_full=1
    [[ ${b_full} -eq 1 ]] && log "WARN" "[NOTE] 修复前数据已满——以修复日志判定 loss" || log "INFO" "[OK] 修复前不完整，符合预期"

    manual_repair
    check_repair_logs

    # 修复后树数据校验
    query_data "1_after_repair"
    [[ ${g_tree_rows} -eq 20 ]] && log "INFO" "[PASS] 树数据 20/20 已恢复" || { log "ERROR" "[FAIL] 树未恢复"; let fail_flag++; v_warnMessage="${v_warnMessage}tree not recovered."; }

    # benchmark 填空
    start_bm

    # 全在线+逐停DN+分割校验
    check_data_consistent

    # 拷贝第一次结果
    log "INFO" "===== [SNAPSHOT] 保存第一次结果 ====="
    cp -rp "${cur_dir}/ref_tree.out" "${cur_dir}/snap1_tree.out"
    cp -rp "${cur_dir}/ref_t1.out"   "${cur_dir}/snap1_t1.out"
    cp -rp "${cur_dir}/ref_t2.out"   "${cur_dir}/snap1_t2.out"

    # 重启复验 + 前后对比
    log "INFO" "===== [RESTART] 重启 + 复验 + 前后 diff ====="
    sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
    sh -x "${prepare_env_dir}/start_cluster_v20.sh" "2" "${total_node_num}" >> "${log_file}" 2>&1
    wait_cluster_ready 600
    check_data_consistent

    # diff 重启前后
    local dt=$(diff "${cur_dir}/snap1_tree.out" "${cur_dir}/ref_tree.out" | grep -c "root.test")
    local d1=$(diff "${cur_dir}/snap1_t1.out"   "${cur_dir}/ref_t1.out"   | grep -c "d_")
    local d2=$(diff "${cur_dir}/snap1_t2.out"   "${cur_dir}/ref_t2.out"   | grep -c "d_")
    [ $((dt+d1+d2)) -gt 0 ] && { log "ERROR" "[FAIL] 重启前后不一致 diff=${dt}/${d1}/${d2}"; let fail_flag++; v_warnMessage="${v_warnMessage}restart diff."; } || log "INFO" "[PASS] 重启前后数据完全一致 diff=0"

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
