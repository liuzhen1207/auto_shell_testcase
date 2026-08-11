#!/bin/bash
# ============================================================================
# tc2026_April_003501  数据分区表修复 —— 手动触发 REPAIR（树模型·黄金主路径）
# ----------------------------------------------------------------------------
# 对应用例：[DPR_A01] 构造分区丢失后修复成功（黄金主路径·树模型）
#           顺带覆盖 DPR_A02(异步立即返回)、DPR_A05(须手动触发)、DPR_E04(升级兼容)。
#
# 实现背景（当前 build：master_0710_621a77d / TimechoDB 2.0.11-SNAPSHOT）：
#   数据分区表修复由「手动执行 SQL」触发，且仅树模型方言有该语法入口：
#       REPAIR DATA PARTITION TABLE;                 (异步, 立即返回成功)
#       SHOW REPAIR DATA PARTITION TABLE PROGRESS;   (查询进度)
#   仅 SYSTEM 权限账号可执行。
#
# 前置「分区丢失但磁盘数据仍在」的构造方式（与原脚本一致：用预置备份，而非现场触发）：
#   备份 ${backup_dir} 是在含 bug 的旧版本(v2.0.6.1 RC7, ns 精度, 设备级 TTL)上
#   已经构造好 loss 的整套集群数据（data1/data2/data3 三盘），其中部分设备的分区表
#   条目被误删、但磁盘 TsFile 仍在。把它恢复进目标版本(master)的数据目录并起集群，
#   即等价于「从旧版本升级到本版本、且带着分区丢失」。
#   （注：现场用 v2061rc7 已无法复现该 bug——该 RC 对单设备 TTL 已修正，故必须用备份。）
#
# 流程：
#   1) 清理环境、配置 master 各节点(ns 精度)；                     [start_db]
#   2) 把 loss 备份恢复进 master 的三个数据盘目录；
#   3) 起 master 集群(start_cluster_v20)；
#   4) 【DPR_A05】起集群后先查数据：受损数据应仍缺失（本版本不会自动修复）；
#   5) 手动执行 REPAIR DATA PARTITION TABLE;(树方言)，轮询进度至完成；    [DPR_A02]
#   6) 校验：受损数据恢复(树 root.test.g_0.** 20 设备行；表 db_g_0.table1_0/2_0
#      各 10 行；无异常)，且明显多于修复前；CN 日志含修复关键行；        [DPR_A01]
#   7) 重启集群后再次校验一致；扫描 CN/DN 日志中的非预期异常。
#
# 说明：因直接起 master(start_cluster_v20)，集群运行在 ${db_dir}=/data2/master...，
#   故 CN/DN 日志均在 ${db_dir}/logs/（root 属主，需 sudo）。
#
# 兼容所有 Bash 版本（含 3.x）：不使用进程替换 / mapfile。
# ============================================================================
set -uo pipefail
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

# --------- 读取配置（去空格，兼容低版本） ---------
os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
cli_dir=${db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
CSV_FILE=$(grep ^CSV_FILE "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')

cn_num=3
dn_num=3
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num+dn_num))
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensus"
log_file="${cur_dir}/set_conf_parallel.log"
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
ssl_str=""
# 三盘数据目录（与 configure_datanode 的 dn_data_dirs 对应）
data1_dir="/data1/iotdb_data/${testdb}/data"
data3_dir="/data3/iotdb_data/${testdb}/data"
# 预置的「已构造 loss」备份（v2061rc7 / ns / 设备级 TTL 构造，三盘）
backup_dir=/data2/tc2026_data_backup/v2061_rc7_0915_802dd96_ns_ttl_60s

# 清理旧节点文件，复制新配置（3c/3d 均为 .2/.3/.4）
rm -rf "${nodeinfo_dir}/confignode.txt" "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt"   "${nodeinfo_dir}/datanode.txt"

seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

fail_flag=0
backup_log_flag=0
test_begin_sec=$(date +%s)
diag_run_id=$(date +%Y%m%d_%H%M%S)
diag_dir="${cur_dir}/diag_003501_${diag_run_id}"
mkdir -p "${diag_dir}"

# 校验期望值（受损数据「完全恢复」后的目标态，取自原脚本 check_data_consistent）
v_exp_tree_rows=20     # root.test.g_0.** align by device -> 20 个设备行
v_exp_table_rows=10    # db_g_0.table1_0/table2_0 group by device_id -> 各 10 行

# ===================== 工具函数 =====================
log() {
    local level=$1; local msg=$2
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" >> "${log_file}"
    echo "[${timestamp}] [${level}] ${msg}"
}

# 目标版本 CLI 执行
run_sql() {
    local dialect=$1; local sql=$2; local outfile=$3
    ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} \
        -sql_dialect ${dialect} -timeout 36000 -e "${sql}" > "${outfile}" 2>&1
}

# 环境清理
clean_env() {
   log "INFO" "开始清理集群环境..."
   sh -x "${clean_env_dir}/stop_cluster.sh"  >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/reset_conf.sh"    >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/clear_cache.sh"   >> "${log_file}" 2>&1
   log "INFO" "集群环境清理完成"
}

# 单个 ConfigNode 配置
configure_confignode() {
    local node_ip=$1
    log "INFO" "开始配置ConfigNode: ${node_ip}"
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="2G"/g' ${db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${db_dir}/conf/confignode-env.sh
        batch_set_sys_conf() {
            local search_str=\$1; local content=\$2
            local file="${db_dir}/conf/iotdb-system.properties"
            if grep -q "\$search_str" "\$file"; then sed -i "s|\$search_str|\$content|g" "\$file"; else echo "\$content" >> "\$file"; fi
        }
        batch_set_sys_conf ".*cn_seed_config_node=.*" "cn_seed_config_node=${seed_cn_ip}"
        batch_set_sys_conf ".*cn_internal_address=.*" "cn_internal_address=${node_ip}"
        batch_set_sys_conf ".*cn_metric_reporter_list=.*" "cn_metric_reporter_list=PROMETHEUS"
        batch_set_sys_conf ".*cn_metric_prometheus_reporter_port=.*" "cn_metric_prometheus_reporter_port=9081"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=5"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*timestamp_precision=.*" "timestamp_precision=ns"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
EOF
    if [ $? -eq 0 ]; then log "INFO" "ConfigNode ${node_ip} 配置完成"; else log "ERROR" "ConfigNode ${node_ip} 配置失败"; return 1; fi
}

# 单个 DataNode 配置（三盘 dn_data_dirs，与备份三盘对应）
configure_datanode() {
    local node_ip=$1
    log "INFO" "开始配置DataNode: ${node_ip}"
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${db_dir}/conf/datanode-env.sh
        batch_set_sys_conf() {
            local search_str=\$1; local content=\$2
            local file="${db_dir}/conf/iotdb-system.properties"
            if grep -q "\$search_str" "\$file"; then sed -i "s|\$search_str|\$content|g" "\$file"; else echo "\$content" >> "\$file"; fi
        }
        batch_set_sys_conf ".*dn_seed_config_node=.*" "dn_seed_config_node=${seed_cn_ip}"
        batch_set_sys_conf ".*dn_internal_address=.*" "dn_internal_address=${node_ip}"
        batch_set_sys_conf ".*dn_rpc_address=.*" "dn_rpc_address=${node_ip}"
        batch_set_sys_conf ".*dn_metric_reporter_list=.*" "dn_metric_reporter_list=PROMETHEUS"
        batch_set_sys_conf ".*dn_metric_prometheus_reporter_port=.*" "dn_metric_prometheus_reporter_port=9091"
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=5"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*timestamp_precision=.*" "timestamp_precision=ns"
        batch_set_sys_conf ".*ttl_check_interval=.*" "ttl_check_interval=10000"
        file="${db_dir}/conf/iotdb-system.properties"
        sed -i 's|.*dn_data_dirs=.*|dn_data_dirs=data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data,/data3/iotdb_data/${testdb}/data/datanode/data|g' \$file
        sed -i 's|.*dn_wal_dirs=.*|dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal,/data3/iotdb_data/${testdb}/data/datanode/wal|g' \$file
EOF
    if [ $? -eq 0 ]; then log "INFO" "DataNode ${node_ip} 配置完成"; else log "ERROR" "DataNode ${node_ip} 配置失败"; return 1; fi
}

configure_mixed_node() {
    local node_ip=$1
    log "INFO" "开始配置混合节点（CN+DN）: ${node_ip}"
    configure_confignode "${node_ip}" && configure_datanode "${node_ip}"
    log "INFO" "混合节点 ${node_ip} 配置完成"
}

# 顺序配置所有混合节点（.2/.3/.4）
set_conf() {
    log "INFO" "配置所有节点..."
    local line
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        configure_mixed_node "${line}" || fail_flag=1
    done
    exec 3<&-
}

# 起集群：清理 -> 配置 -> 恢复 loss 备份到三盘 -> 起 master
start_db() {
    log "INFO" "===== [START] 清理/配置/恢复备份/起 master ====="
    clean_env
    set_conf
    if [[ ${fail_flag} -ne 0 ]]; then log "ERROR" "节点配置失败，终止"; return 1; fi

    # 恢复「已构造 loss」的三盘备份到 master 数据目录
    log "INFO" "恢复 loss 备份 ${backup_dir} 到三盘..."
    local line
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line <&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        ssh ${os_user_name}@${line} "sudo mkdir -p /data1/iotdb_data/${testdb} /data3/iotdb_data/${testdb} ${db_dir}" >> "${log_file}" 2>&1
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data1_backup ${data1_dir}" >> "${log_file}" 2>&1
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data2_backup ${db_dir}/data" >> "${log_file}" 2>&1
        ssh ${os_user_name}@${line} "sudo cp -rp ${backup_dir}/data3_backup ${data3_dir}" >> "${log_file}" 2>&1
        sleep 1
    done
    exec 3<&-

    # 起 master 集群
    sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1
    if [ $? -ne 0 ]; then log "ERROR" "master 集群启动失败"; let fail_flag++; return 1; fi
    log "INFO" "master 集群启动成功"
}

# 等整集群就绪（show cluster 中 Running+ReadOnly 达到 total_node_num）
wait_cluster_ready() {
    local max=$1; local waited=0
    while true; do
        run_sql tree "show cluster;" "${cur_dir}/tmp.out"
        local ok=$(grep -E "Running|ReadOnly" "${cur_dir}/tmp.out" | wc -l)
        if [[ ${ok} -ge ${total_node_num} ]]; then log "INFO" "集群就绪：${ok}/${total_node_num}"; return 0; fi
        sleep 5; waited=$((waited+5))
        if [[ ${waited} -gt ${max} ]]; then log "ERROR" "集群 ${max}s 未全部就绪(${ok}/${total_node_num})"; let fail_flag++; return 1; fi
    done
}

# --------- 数据查询：把三条校验查询写到 ${phase}_*.out，回填全局计数 ---------
g_tree_rows=0; g_t1_rows=0; g_t2_rows=0; g_data_sum=0; g_data_sum_strict=0; g_exc=0
query_data() {
    local phase=$1
    local query_begin=$(date '+%Y-%m-%d %H:%M:%S.%N')
    local sql_tree="select count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from root.test.g_0.** align by device;"
    local sql_t1="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table1_0 group by device_id order by device_id;"
    local sql_t2="select device_id,count(s_0),count(s_1),count(s_2),count(s_3),count(s_4),count(s_5),count(s_6),count(s_7),count(s_8),count(s_9) from db_g_0.table2_0 group by device_id order by device_id;"
    run_sql tree  "${sql_tree}" "${cur_dir}/${phase}_tree.out"
    run_sql table "${sql_t1}"   "${cur_dir}/${phase}_table1.out"
    run_sql table "${sql_t2}"   "${cur_dir}/${phase}_table2.out"
    cp -p "${cur_dir}/${phase}_tree.out" "${cur_dir}/${phase}_table1.out" "${cur_dir}/${phase}_table2.out" "${diag_dir}/" 2>/dev/null || true
    g_tree_rows=$(grep -c "root.test" "${cur_dir}/${phase}_tree.out")
    g_t1_rows=$(grep -oE "Total line number = [0-9]+" "${cur_dir}/${phase}_table1.out" | grep -oE "[0-9]+" | tail -1); g_t1_rows=${g_t1_rows:-0}
    g_t2_rows=$(grep -oE "Total line number = [0-9]+" "${cur_dir}/${phase}_table2.out" | grep -oE "[0-9]+" | tail -1); g_t2_rows=${g_t2_rows:-0}
    # 数据总量（树查询所有 count 列求和）—— 用于「修复前 < 修复后」的恢复证据
    g_data_sum=$(grep -oE "[0-9]+" "${cur_dir}/${phase}_tree.out" | awk '{s+=$1} END{print s+0}')
    g_data_sum_strict=$(awk -F'|' '/root\.test/ {for (i=3; i<NF; i++) {v=$i; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); if (v ~ /^[0-9]+$/) s+=v}} END {print s+0}' "${cur_dir}/${phase}_tree.out")
    g_exc=$(grep -cE "Exception|Msg: [0-9]+:" "${cur_dir}/${phase}_tree.out" "${cur_dir}/${phase}_table1.out" "${cur_dir}/${phase}_table2.out" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
    log "INFO" "[${phase}] tree设备行=${g_tree_rows} table1行=${g_t1_rows} table2行=${g_t2_rows} 数据点合计=${g_data_sum} 异常=${g_exc}"
    log "INFO" "[DIAG:${phase}] query_begin=${query_begin} query_end=$(date '+%Y-%m-%d %H:%M:%S.%N') legacy_sum=${g_data_sum} strict_tree_count_sum=${g_data_sum_strict}"
}

capture_ttl_diag() {
    local phase=$1
    run_sql tree "SHOW ALL TTL;" "${diag_dir}/${phase}_show_all_ttl.out"
    log "INFO" "[DIAG:${phase}] TTL snapshot: ${diag_dir}/${phase}_show_all_ttl.out"
    sed -n '1,120p' "${diag_dir}/${phase}_show_all_ttl.out" 2>/dev/null || true
}

write_repair_diff() {
    local model before after
    for model in tree table1 table2; do
        before="${diag_dir}/0_before_repair_${model}.out"
        after="${diag_dir}/1_after_repair_${model}.out"
        grep -v '^It costs ' "${before}" > "${diag_dir}/0_before_repair_${model}.normalized.out" || true
        grep -v '^It costs ' "${after}" > "${diag_dir}/1_after_repair_${model}.normalized.out" || true
        diff -u "${diag_dir}/0_before_repair_${model}.normalized.out" "${diag_dir}/1_after_repair_${model}.normalized.out" > "${diag_dir}/before_after_${model}.diff" 2>&1 || true
        log "INFO" "[DIAG] before/after ${model} diff: ${diag_dir}/before_after_${model}.diff"
        sed -n '1,240p' "${diag_dir}/before_after_${model}.diff" 2>/dev/null || true
    done
}

# 在任一 CN 节点日志中 grep 指定串（master 目录, root 属主需 sudo；先 gunzip 滚动日志）
rgrep_count() {
    local node=$1; local pat=$2; local glob=$3
    local n=$(ssh ${os_user_name}@${node} "sudo grep -F \"${pat}\" ${glob} 2>/dev/null | wc -l" | tr -dc '0-9')
    echo "${n:-0}"
}
cn_log_count() {
    local pat=$1; local total=0; local line
    exec 4<"${nodeinfo_dir}/confignode.txt"
    while read line <&4; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*confignode*all* 2>/dev/null; true" >/dev/null 2>&1
        total=$((total + $(rgrep_count "${line}" "${pat}" "${db_dir}/logs/*confignode*all*")))
    done
    exec 4<&-
    echo "${total}"
}
cn_log_has() { [ "$(cn_log_count "$1")" -gt 0 ]; }

# ============================================================================
# 步骤 5：手动触发 REPAIR（异步立即返回, DPR_A02）+ 轮询进度
# ============================================================================
manual_repair() {
    log "INFO" "===== [REPAIR] 手动触发 REPAIR DATA PARTITION TABLE (树方言) ====="
    local t0=$(date +%s%3N 2>/dev/null || date +%s)
    run_sql tree "REPAIR DATA PARTITION TABLE;" "${cur_dir}/repair_trigger.out"
    local t1=$(date +%s%3N 2>/dev/null || date +%s)
    if grep -q "The statement is executed successfully." "${cur_dir}/repair_trigger.out"; then
        log "INFO" "[PASS] REPAIR 触发成功(立即返回)。近似耗时=$((t1-t0))"
    else
        log "ERROR" "[FAIL] REPAIR 触发未返回成功；输出如下："
        cat "${cur_dir}/repair_trigger.out"; let fail_flag++
        v_warnMessage="${v_warnMessage}REPAIR trigger not success."
    fi
    # 轮询：CN 日志出现 merge completed 视为异步修复完成
    local waited=0
    while true; do
        run_sql tree "SHOW REPAIR DATA PARTITION TABLE PROGRESS;" "${cur_dir}/repair_progress.out"
        if cn_log_has "DataPartitionTables merge completed successfully"; then
            log "INFO" "[PASS] CN 日志出现 merge completed，异步修复完成"; break
        fi
        if grep -qE "100\.0|100 *%" "${cur_dir}/repair_progress.out"; then
            log "INFO" "修复进度达 100%"; break
        fi
        sleep 5; waited=$((waited+5))
        if [[ ${waited} -gt 300 ]]; then
            log "WARN" "修复 300s 未显示完成，进度输出如下："; cat "${cur_dir}/repair_progress.out"
            v_warnMessage="${v_warnMessage}repair not completed in 300s."; break
        fi
    done
}

# 校验修复关键日志（取自 build jar 实测字符串，带 [DataPartitionIntegrity] 前缀）
check_repair_logs() {
    log "INFO" "===== [LOG] 校验 CN 修复关键日志 ====="
    if cn_log_has "has lost timeslot" ; then
        log "INFO" "[PASS] CN 日志含 '... has lost timeslot ... needs to be repaired'（loss 存在且被检出）"
    else
        log "ERROR" "[FAIL] CN 日志缺少 'has lost timeslot'——备份可能无 loss 或未被检出"
        let fail_flag++; v_warnMessage="${v_warnMessage}no lost-timeslot log."
    fi
    if cn_log_has "DataPartitionTables merge completed successfully" ; then
        log "INFO" "[PASS] CN 日志含 'DataPartitionTables merge completed successfully'"
    else
        log "ERROR" "[FAIL] CN 日志缺少 'DataPartitionTables merge completed successfully'"
        let fail_flag++; v_warnMessage="${v_warnMessage}no merge-completed log."
    fi
    if cn_log_has "DataPartitionTable successfully written to consensus log" ; then
        log "INFO" "[PASS] CN 日志含 'written to consensus log'"
    else
        log "INFO" "[NOTE] 未见 'written to consensus log'（视 build 而定，不判失败）"
    fi
}

# 校验「完全恢复态」：树 20 行、表各 10 行、无异常
verify_full() {
    local phase=$1
    query_data "${phase}"
    if [[ ${g_exc} -eq 0 && ${g_tree_rows} -eq ${v_exp_tree_rows} && ${g_t1_rows} -eq ${v_exp_table_rows} && ${g_t2_rows} -eq ${v_exp_table_rows} ]]; then
        log "INFO" "[PASS:${phase}] 数据完整：tree=${g_tree_rows}/${v_exp_tree_rows} table1=${g_t1_rows}/${v_exp_table_rows} table2=${g_t2_rows}/${v_exp_table_rows} 无异常"
    else
        log "ERROR" "[FAIL:${phase}] 数据不完整：tree=${g_tree_rows}(期望${v_exp_tree_rows}) table1=${g_t1_rows}(期望${v_exp_table_rows}) table2=${g_t2_rows}(期望${v_exp_table_rows}) 异常=${g_exc}"
        cat "${cur_dir}/${phase}_tree.out"
        let fail_flag++; v_warnMessage="${v_warnMessage}${phase} data incomplete(tree=${g_tree_rows},t1=${g_t1_rows},t2=${g_t2_rows},exc=${g_exc})."
    fi
}

# 通用异常日志扫描（master 目录 ${db_dir}/logs）
check_unexpected_logs() {
    log "INFO" "===== [LOG] 扫描非预期异常 ====="
    local line g
    exec 3<"${nodeinfo_dir}/confignode.txt"
    while read line<&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*confignode*all* 2>/dev/null; true" >/dev/null 2>&1
        g="${db_dir}/logs/*confignode*all*"
        local npe=$(rgrep_count "${line}" "NullPointerException" "${g}")
        local buf=$(rgrep_count "${line}" "BufferUnderflowException" "${g}")
        local cce=$(rgrep_count "${line}" "ClassCastException" "${g}")
        local total=$(( npe + buf + cce ))
        if [[ ${total} -gt 0 ]]; then
            log "ERROR" "CN ${line} 非预期异常合计=${total} (NPE=${npe},Buf=${buf},CCE=${cce})"
            let fail_flag++; let backup_log_flag++; v_warnMessage="${v_warnMessage}CN ${line} unexpected log ${total}."
        fi
    done
    exec 3<&-
    exec 3<"${nodeinfo_dir}/datanode.txt"
    while read line<&3; do
        line=$(echo "${line}"|sed 's/ //g'); [ -z "${line}" ] && continue
        ssh ${os_user_name}@${line} "sudo gunzip ${db_dir}/logs/*datanode*all* 2>/dev/null; true" >/dev/null 2>&1
        g="${db_dir}/logs/*datanode*all*"
        local npe=$(rgrep_count "${line}" "NullPointerException" "${g}")
        local aioobe=$(rgrep_count "${line}" "ArrayIndexOutOfBoundsException" "${g}")
        local dtie=$(rgrep_count "${line}" "DataTypeInconsistentException" "${g}")
        local nase=$(rgrep_count "${line}" "NegativeArraySizeException" "${g}")
        local cce=$(rgrep_count "${line}" "ClassCastException" "${g}")
        local buf=$(rgrep_count "${line}" "BufferUnderflowException" "${g}")
        local total=$(( npe + aioobe + dtie + nase + cce + buf ))
        if [[ ${total} -gt 0 ]]; then
            log "ERROR" "DN ${line} 非预期异常合计=${total} (NPE=${npe},AIOOBE=${aioobe},DTIE=${dtie},NASE=${nase},CCE=${cce},Buf=${buf})"
            let fail_flag++; let backup_log_flag++; v_warnMessage="${v_warnMessage}DN ${line} unexpected log ${total}."
        fi
    done
    exec 3<&-
}

# ============================================================================
# 主测试
# ============================================================================
force_a04_multi_dn_assignment() {
    [[ "${DPR_A04_FORCE_MULTI_DN:-0}" = "1" ]] || return 0
    local offline_dn next_query
    offline_dn=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
    next_query=$(sed -n '2p' "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
    [[ -n "${offline_dn}" && -n "${next_query}" ]] || {
        log "ERROR" "A04 无法选择临时下线 DN 或备用查询 DN"
        let fail_flag++
        return 1
    }
    log "INFO" "[A04] 临时停止 ${offline_dn}，使两个缺失分区分别由其余副本 DN 生成；query_ip=${next_query}"
    ssh ${os_user_name}@${offline_dn} "source /etc/profile; cd ${db_dir}; sudo ./sbin/stop-datanode.sh" >>"${log_file}" 2>&1
    local waited=0 alive=1
    while [[ ${waited} -lt 120 ]]; do
        alive=$(ssh ${os_user_name}@${offline_dn} "sudo jps -l | grep -c 'com.timecho.iotdb.DataNode\|org.apache.iotdb.db.service.DataNode'" | tr -dc '0-9')
        [[ ${alive:-0} -eq 0 ]] && break
        sleep 2; waited=$((waited+2))
    done
    if [[ ${alive:-0} -ne 0 ]]; then
        log "ERROR" "[A04] ${offline_dn} 在 120s 内未停止"
        let fail_flag++
        return 1
    fi
    query_ip=${next_query}
    A04_OFFLINE_DN=${offline_dn}
    return 0
}

restore_a04_offline_dn() {
    [[ "${DPR_A04_FORCE_MULTI_DN:-0}" = "1" && -n "${A04_OFFLINE_DN:-}" ]] || return 0
    local start_time waited=0 running=0
    start_time=$(date +%s)
    log "INFO" "[A04] 修复完成，重新启动临时下线的 DataNode ${A04_OFFLINE_DN}"
    ssh ${os_user_name}@${A04_OFFLINE_DN} "source /etc/profile; cd ${db_dir}; sudo ./sbin/start-datanode.sh -H ${db_dir}/dn_${start_time}_heapdump.hprof >/dev/null 2>&1 &" >>"${log_file}" 2>&1
    while [[ ${waited} -lt 300 ]]; do
        run_sql tree "show datanodes;" "${cur_dir}/a04_restore_dn.out"
        running=$(grep "${A04_OFFLINE_DN}|" "${cur_dir}/a04_restore_dn.out" | grep -c Running || true)
        [[ ${running} -gt 0 ]] && return 0
        sleep 5; waited=$((waited+5))
    done
    log "ERROR" "[A04] ${A04_OFFLINE_DN} 重启后 300s 内未恢复 Running"
    let fail_flag++
    return 1
}

testcase1() {
    wait_cluster_ready 600 || return

    # DPR_A05：修复前先记录数据态（受损数据应仍缺失/少于完整态；本版本不会自动修复）
    log "INFO" "===== [DPR_A05] 修复前记录数据（受损数据应仍缺失） ====="
    capture_ttl_diag "before_repair"
    query_data "0_before_repair"
    local before_sum=${g_data_sum_strict}
    local before_ok=0
    [[ ${g_exc} -eq 0 && ${g_tree_rows} -eq ${v_exp_tree_rows} && ${g_t1_rows} -eq ${v_exp_table_rows} && ${g_t2_rows} -eq ${v_exp_table_rows} ]] && before_ok=1
    if [[ ${before_ok} -eq 1 ]]; then
        log "INFO" "[DIAG] 修复前设备行数齐全；行数不能证明分区表或数据点完整，是否存在 loss 以 CN 修复日志为准"
    else
        log "INFO" "[OK] 修复前数据不完整(数据点=${before_sum})，符合「须手动修复」预期"
    fi

    # A04 专用构造：最低 ID DN 通常同时持有两个缺失分区的副本。临时停止它，
    # 让另外两个副本 DN 分别生成分区表，从而真实覆盖 multi-DN merge。
    force_a04_multi_dn_assignment || return

    # 手动 REPAIR
    manual_repair
    restore_a04_offline_dn || return

    # 修复后：完整态校验 + 恢复证据(修复后数据点 >= 修复前)
    verify_full "1_after_repair"
    capture_ttl_diag "after_repair"
    write_repair_diff
    if [[ ${g_data_sum_strict} -lt ${before_sum} ]]; then
        log "ERROR" "[FAIL] 修复后严格数据点(${g_data_sum_strict}) < 修复前(${before_sum})，异常"
        let fail_flag++; v_warnMessage="${v_warnMessage}after<before data."
    else
        log "INFO" "[OK] 修复后严格数据点 ${g_data_sum_strict} >= 修复前 ${before_sum}（未发现数据减少）"
    fi

    # 修复关键日志
    check_repair_logs

    # 步骤 7：重启集群后复验一致
    log "INFO" "===== [RESTART] 重启 master 集群后复验 ====="
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
if [[ ${fail_flag} -eq 0 ]]; then
    testcase1
else
    log "ERROR" "起集群失败，跳过测试"
fi

v_end_test_time=$(date +%s)
v_elp_time=$((v_end_test_time-test_begin_sec))

# ===================== 结果记录 =====================
test_time=$(date +"%Y-%m-%dT%H:%M:%S.%3N%:z")
v_exist_flag=$(grep -c "Time,testTimechoDB" "$CSV_FILE" 2>/dev/null)
if [[ "${v_exist_flag:-0}" -eq 0 ]]; then
   echo "Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage" > "$CSV_FILE"
fi
if [[ ${fail_flag} -gt 0 ]]; then
   echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},FAIL,${v_elp_time},${v_warnNum},${v_warnMessage}" >> "$CSV_FILE"
   echo "testcase FAIL : ${v_warnMessage}"
   v_backup_time=$(date +%s)
   v_backup_desc=$(echo ${SCRIPT_NAME} | awk -F '.' '{print $1}')
   sh ${clean_env_dir}/backup_cluster_logs.sh ${v_backup_time}_${v_backup_desc} 2>/dev/null || true
else
   echo "${test_time},${testdb},${v_consensus},${SCRIPT_NAME},PASS,${v_elp_time},${v_warnNum},${v_warnMessage}" >> "$CSV_FILE"
   echo "testcase PASS"
fi
