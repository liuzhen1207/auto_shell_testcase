#!/bin/bash
# tree table migrate privilege test 
set -uo pipefail
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

# 读取配置文件（去空格，兼容低版本）
os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
shell_client_db_parent_dir=$(grep "^v_shell_client_db_parent_dir=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
cli_dir=${shell_client_db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
cn_db_parent_dir=`cat ${conf_file}|grep ^v_cn_db_parent_dir|awk -F '=' '{print $2}'`
cn_db_dir=${cn_db_parent_dir}/${testdb}

clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
CLUSTER_ID=$(grep ^CLUSTER_NAME "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
cn_num=3
dn_num=5
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num+dn_num))
log_file="${cur_dir}/set_conf_parallel.log"
ssl_str=""
backup_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."
v_audit_log_count=0
v_audit_log_max_bytes=0
v_audit_log_avg_bytes=0
v_audit_log_summary="audit_log_count=0,max_bytes=0,avg_bytes=0,threshold_bytes=1048576"
v_consensus="IoTConsensus"
v_mig_user_name="migrate_user"
# Use the same benchmark configuration for writes, gate targets and count queries.
bm_dir=${cur_dir}/../benchmark/bm_20251017_b6be9bd_ssl
bm_conf=tree_table_100w
# 清理旧节点文件，复制新配置
rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

# 读取种子节点IP（兼容低版本）
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
mig_from_ip=$(sed -n "2p" "${nodeinfo_dir}/datanode.txt")

fail_flag=0
sync_fail_flag=0
result_writeback_fail=0
# if > 0 exit test 
prepare_fail_flag=0

# ===================== 工具函数 =====================
# 日志输出函数（带时间戳）
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" >> "${log_file}"
    echo "[${timestamp}] [${level}] ${msg}"
}

# Share the exact HA-0005 gate; fail before cluster setup if dependencies are absent.
artifact_dir="${cur_dir}/MM-0001_$(date +%Y_%m_%d_%H_%M_%S)_$$"
mkdir -p "$artifact_dir" || exit 1
cluster_id=$CLUSTER_ID
dn_metric_port=9091
HA_SYNC_STABLE_SECONDS=${MM_SYNC_STABLE_SECONDS:-120}
HA_SYNC_POLL_SECONDS=${MM_SYNC_POLL_SECONDS:-5}
HA_GATE_CLI_TIMEOUT=${MM_SYNC_CLI_TIMEOUT:-30}
sync_lag_timeout_seconds=${MM_SYNC_LAG_TIMEOUT:-600}
ha_sync_support_dir=${HA_SYNC_SUPPORT_DIR:-$cur_dir}
mm_check="$cur_dir/mm0001_check.py"
if [ ! -f "$ha_sync_support_dir/ha_sync_gate.sh" ] && [ -f "$cur_dir/high_available/ha_sync_gate.sh" ]; then
    ha_sync_support_dir="$cur_dir/high_available"
fi
record_fail() {
    fail_flag=$((fail_flag+1))
    v_warnMessage="$v_warnMessage $1."
    log ERROR "$1"
}
for mm_dep in "$ha_sync_support_dir/ha_sync_gate.sh" "$ha_sync_support_dir/ha_sync_check.py" "$mm_check"; do
    [ -s "$mm_dep" ] || { record_fail "SYNC_GATE_CONFIG missing $mm_dep"; exit 1; }
done
source "$ha_sync_support_dir/ha_sync_gate.sh" || exit 1
ha_gate_setup || exit 1
ha_sync_gate_failed=0
ha_consistency_topology=''
mm_stopped_dn=''
v_audit_log_summary="audit_status=NOT_RUN"
export PYTHONPATH="$ha_sync_support_dir${PYTHONPATH:+:$PYTHONPATH}"

# MM-0001 ADAPTER FUNCTIONS BEGIN
mm_cli() {
    local host=$1 dialect=$2 sql=$3 output=$4 seconds=${5:-${MM_QUERY_TIMEOUT:-3600}}
    timeout -k 5 "$seconds" "$cli_dir/sbin/start-cli.sh" -u "$db_user_name" ${ssl_str} \
      -h "$host" -timeout "$seconds" -sql_dialect "$dialect" -e "$sql" >"$output" 2>&1 || return 1
    [ -s "$output" ] && ! grep -Eqi 'Exception|(^|[^a-z])(error|failed)([^a-z]|$)' "$output"
}
wait_for_sync_lag_zero() {
    if ! ha_wait_sync "$@"; then sync_fail_flag=1; return 1; fi
    return 0
}
mm_prepare_benchmark() {
    if ! "$ha_sync_python" "$mm_check" benchmark "$bm_dir/$bm_conf" \
        >"$artifact_dir/benchmark_targets.tsv" 2>"$artifact_dir/benchmark_targets.err"; then
        record_fail "BENCHMARK_CONFIG_ERROR see $artifact_dir/benchmark_targets.err"; return 1
    fi
    IFS=$'\t' read -r MM_TREE_PATH TABLE_DB MM_TABLE_NAME <"$artifact_dir/benchmark_targets.tsv" || return 1
    log INFO "BENCHMARK_TARGETS config=$bm_dir/$bm_conf tree=$MM_TREE_PATH table=$TABLE_DB.$MM_TABLE_NAME"
}
mm_prepare_membership() {
    # Freeze the expected four nodes from configuration, excluding only the
    # intentionally removed source. An unexpected absent node must not disappear
    # from the gate's expectations.
    local ip removed=0
    DN_IPS=()
    while IFS= read -r ip; do
        ip=${ip//[[:space:]]/}
        [ -n "$ip" ] || continue
        if [ "$ip" = "$mig_from_ip" ]; then removed=$((removed+1)); else DN_IPS+=("$ip"); fi
    done <"$nodeinfo_dir/datanode.txt"
    if [ "$removed" -ne 1 ] || [ "${#DN_IPS[@]}" -ne $((dn_num-1)) ]; then
        record_fail 'SYNC_GATE_CONFIG invalid post-removal membership'; return 1
    fi
    query_ip=${DN_IPS[0]}
    mm_cli "$query_ip" tree 'show regions' "$artifact_dir/resolve_tree_database.raw" 60 ||
        { record_fail 'QUERY_ERROR resolve tree database'; return 1; }
    TREE_DB=$("$ha_sync_python" "$mm_check" database "$artifact_dir/resolve_tree_database.raw" "$MM_TREE_PATH" \
        2>"$artifact_dir/resolve_tree_database.err") ||
        { record_fail 'SYNC_GATE_CONFIG cannot resolve benchmark database'; return 1; }
    log INFO "SYNC_GATE expected DN=${DN_IPS[*]} databases=$TREE_DB,$TABLE_DB port=$dn_metric_port"
}
mm_capture_counts() {
    local host=$1 prefix=$2 model sql rc=0
    for model in tree table; do
        if [ "$model" = tree ]; then
            sql="select count(s_0),count(s_1000),count(s_2000),count(s_3000),count(s_4000),count(s_5000),count(s_6000),count(s_7000),count(s_8000),count(s_9999) from ${MM_TREE_PATH}.** align by device"
        else
            sql="select device_id,count(s_0),count(s_1000),count(s_2000),count(s_3000),count(s_4000),count(s_5000),count(s_6000),count(s_7000),count(s_8000),count(s_9999) from ${TABLE_DB}.${MM_TABLE_NAME} group by device_id order by device_id"
        fi
        printf '%s\n' "$sql" >"${prefix}_$model.sql" || return 1
        if ! mm_cli "$host" "$model" "$sql" "${prefix}_$model.raw"; then rc=1; continue; fi
        "$ha_sync_python" "$mm_check" counts "${prefix}_$model.raw" "$model" \
          >"${prefix}_$model.normalized" 2>"${prefix}_$model.parse.err" || rc=1
    done
    return "$rc"
}
mm_compare_fixed() {
    local host=$1 label=$2 model rc=0
    mm_capture_counts "$host" "$artifact_dir/$label" ||
        { record_fail "QUERY_ERROR $label via=$host"; return 1; }
    for model in tree table; do
        if ! diff -u "$artifact_dir/baseline_$model.normalized" "$artifact_dir/${label}_$model.normalized" \
          >"$artifact_dir/${label}_$model.diff"; then
            record_fail "DATA_MISMATCH $label model=$model via=$host"; rc=1
        fi
    done
    return "$rc"
}
mm_compare_entries() {
    local label=$1 ip rc=0
    # An entry node is not a forced local-replica read.
    for ip in "${DN_IPS[@]}"; do mm_compare_fixed "$ip" "${label}_$ip" || rc=1; done
    return "$rc"
}
mm_stop_dn() {
    local ip=$1 begin=$SECONDS state
    mm_stopped_dn=$ip
    timeout -k 5 150 ssh -n -o ConnectTimeout=10 "$os_user_name@$ip" \
      "source /etc/profile; cd '$db_dir'; ./sbin/stop-datanode.sh" \
      >"$artifact_dir/stop_$ip.log" 2>&1 ||
        { record_fail "STOP_ERROR $ip"; return 1; }
    while [ $((SECONDS-begin)) -lt 180 ]; do
        state=$(timeout -k 5 20 ssh -n -o ConnectTimeout=10 "$os_user_name@$ip" \
          "source /etc/profile; jps" 2>>"$artifact_dir/stop_$ip.log") || {
            record_fail "STOP_CHECK_ERROR $ip"; return 1;
        }
        # An unreachable SSH host is never treated as proof of process exit.
        if ! printf '%s\n' "$state" | grep -q DataNode; then return 0; fi
        sleep 3
    done
    record_fail "STOP_TIMEOUT $ip"; return 1
}
mm_start_dn() {
    local ip=$1
    timeout -k 5 90 ssh -n -o ConnectTimeout=10 "$os_user_name@$ip" \
      "source /etc/profile; cd '$db_dir'; ./sbin/start-datanode.sh -d >/dev/null 2>&1 </dev/null" \
      >"$artifact_dir/start_$ip.log" 2>&1 ||
        { record_fail "START_ERROR $ip"; return 1; }
    # The subsequent common gate, not the launch acknowledgement, proves recovery.
    mm_stopped_dn=''
}
# MM-0001 ADAPTER FUNCTIONS END

# 清理环境函数
clean_env() {
   log "INFO" "开始清理集群环境..."
   sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/reset_conf.sh" >> "${log_file}" 2>&1
   sh -x "${clean_env_dir}/clear_cache.sh" >> "${log_file}" 2>&1
   if [ $? -eq 0 ]; then
       log "INFO" "集群环境清理完成"
   else
       log "ERROR" "集群环境清理失败"
   fi
}

# 单个ConfigNode配置函数
configure_confignode() {
    local node_ip=$1
    log "INFO" "开始配置ConfigNode: ${node_ip}"
    
    # 整合所有ConfigNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="4G"/g' ${cn_db_dir}/conf/confignode-env.sh
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
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=5"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=true"
        batch_set_sys_conf ".*enable_separation_of_powers=.*" "enable_separation_of_powers=false"

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
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="2G"/g' ${db_dir}/conf/datanode-env.sh
        
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
        batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
        batch_set_sys_conf ".*schema_region_group_extension_policy=.*" "schema_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*data_region_group_extension_policy=.*" "data_region_group_extension_policy=CUSTOM"
        batch_set_sys_conf ".*default_schema_region_group_num_per_database=.*" "default_schema_region_group_num_per_database=5"
        batch_set_sys_conf ".*default_data_region_group_num_per_database=.*" "default_data_region_group_num_per_database=5"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=true"
        batch_set_sys_conf ".*enable_separation_of_powers=.*" "enable_separation_of_powers=false"


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
    grep -v '^$' "${nodeinfo_dir}/confignode.txt" | sed 's/ //g' | sort -u > /tmp/cn_ips.tmp
    # 生成去重的DN IP临时文件
    grep -v '^$' "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sort -u > /tmp/dn_ips.tmp

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

# 启动数据库集群函数
start_db() {
   log "INFO" "开始启动数据库集群..."
   # 清理环境
clean_env
   if [ ${fail_flag} -eq 1 ]; then
       log "ERROR" "环境清理失败，终止启动流程"
#       exit 1
   fi
# 读取种子节点IP（兼容低版本）
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

   # 配置节点
   set_conf
   if [ ${fail_flag} -eq 1 ]; then
       log "ERROR" "节点配置失败，终止启动流程"
       exit 1
   fi
   
   # 启动集群
   sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1
   if [ $? -eq 0 ]; then
       log "INFO" "集群启动成功"
   else
       log "ERROR" "集群启动失败"
       let fail_flag++
       exit 1
   fi
}
function check_res()
{
   exp_res=$1
   exp_num=$2
   tc_desc=$3
   v_act_num=`cat ${cur_dir}/tmp.out|grep "${exp_res}"|wc -l`
   if [[ ${v_act_num} = ${exp_num} ]];then
      echo "${tc_desc} PASS."
   else
      echo "${tc_desc} FAIL."
      let fail_flag++
      cat ${cur_dir}/tmp.out
   fi
}
function create_user()
{
# create user
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "CREATE USER tree_user 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res "successfully" 1 "CREATE USER tree_user"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "grant all ON root.** TO USER tree_user;">${cur_dir}/tmp.out
check_res "successfully" 1 "grant all ON root.** TO USER tree_user"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "CREATE USER table_user 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res "successfully" 1 "CREATE USER table_user"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "grant all ON any TO USER table_user;">${cur_dir}/tmp.out
check_res "successfully" 1 "grant all ON any TO USER table_user"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -sql_dialect table -e "CREATE USER ${v_mig_user_name} 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res "successfully" 1 "CREATE USER ${v_mig_user_name}"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "grant system TO USER ${v_mig_user_name};">${cur_dir}/tmp.out
check_res "successfully" 1 "grant system TO USER ${v_mig_user_name}"
if [[ ${fail_flag} -gt 0 ]];then
   let prepare_fail_flag++
   return 1
fi

}
function start_bm()
{
ts_num=500000
#get root password
#v_bm_test_time=54000000
#v_bm_test_time=36000000
v_20_pass=`grep ^passwd_param= ${cli_dir}/sbin/start-cli.sh |grep TimechoDB|wc -l`
if [[ ${v_20_pass} -gt 0 ]];then
        bm_root_pw="TimechoDB@2021"
else

        bm_root_pw="root"
fi
#sed -i 's/CREATE_SCHEMA=.*/CREATE_SCHEMA=true/g' ${bm_dir}/${bm_conf}/conf*/config.*
#sed -i 's/START_TIME=.*/START_TIME=1970-01-01T08:00:00+08:00/g' ${bm_dir}/${bm_conf}/conf*/config.*
sed -i "s/^PASSWORD=.*/PASSWORD=${bm_root_pw}/g" ${bm_dir}/${bm_conf}/conf*/config.properties
#sed -i "s/^TEST_MAX_TIME=.*/TEST_MAX_TIME=${v_bm_test_time}/g" ${bm_dir}/${bm_conf}/conf*/config.properties
bm_log_dir="${bm_dir}/${testdb}"
# 核心逻辑：判断目录是否不存在，不存在则创建
if [ ! -d "${bm_log_dir}" ]; then
    # -p 参数：递归创建父目录（比如bm_dir不存在也会自动创建），且避免重复创建报错
    mkdir -p "${bm_log_dir}"
    echo "目录 ${bm_log_dir} 不存在，已创建"
else
    echo "目录 ${bm_log_dir} 已存在，无需创建"
fi

bm_test_time=`date +%Y_%m_%d_%H_%M_%S`
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf1 > ${bm_log_dir}/${bm_test_time}_tree_bm1.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf2 > ${bm_log_dir}/${bm_test_time}_tree_bm2.out &
nohup ${bm_dir}/benchmark.sh -cf ${bm_dir}/${bm_conf}/conf3 > ${bm_log_dir}/${bm_test_time}_table_bm3.out &
while true
do
        v_ts_num=`${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "count timeseries root.**;"|grep "| "|awk -F '|' '{gsub(" ","");print $2}'`
        if [[ ${v_ts_num} -ge ${ts_num} ]];then
                break
        else
                sleep 10
        fi
done
sleep 60
}
function check_data_consistent()
{
    local ip peer pass round_bad
    mm_prepare_membership || return 1
    ha_consistency_topology=''
    wait_for_sync_lag_zero "$sync_lag_timeout_seconds" initial || return 1
    ha_consistency_topology=$ha_sync_ready_dir
    mm_capture_counts "$query_ip" "$artifact_dir/baseline" ||
        { record_fail 'QUERY_ERROR baseline'; return 1; }
    for pass in 1 2; do mm_compare_entries "baseline_verify_$pass" || return 1; done
    for ip in "${DN_IPS[@]}"; do
        wait_for_sync_lag_zero "$sync_lag_timeout_seconds" "pre_stop_$ip" || return 1
        mm_compare_entries "pre_stop_$ip" || return 1
        peer=''
        for peer in "${DN_IPS[@]}"; do [ "$peer" != "$ip" ] && break; done
        round_bad=0
        if mm_stop_dn "$ip"; then
            mm_compare_fixed "$peer" "stop_$ip" || round_bad=1
        else
            round_bad=1
        fi
        # Restore even after a failed stop command/query/data assertion.
        mm_start_dn "$ip" || return 1
        wait_for_sync_lag_zero "$sync_lag_timeout_seconds" "post_recovery_$ip" "$peer" || return 1
        mm_compare_entries "post_recovery_$ip" || return 1
        [ "$round_bad" -eq 0 ] || return 1
    done
    log INFO 'MM-0001 consistency rounds complete'
}

function check_audit_log_size()
{
    local threshold=${TDB8_AUDIT_MAX_BYTES:-1048576}
    local raw="$artifact_dir/audit_log_size.raw" parsed="$artifact_dir/audit_log_size.parsed"
    local count size maximum devices average
    v_audit_log_summary="audit_status=UNKNOWN"
    if ! [[ "$threshold" =~ ^[1-9][0-9]*$ ]]; then
        record_fail 'AUDIT_CONFIG_ERROR invalid threshold'; return 1
    fi
    if ! mm_cli "$query_ip" tree \
      "select count(length(log)),sum(length(log)),max_value(length(log)) from root.__audit.log.** where time >= $((v_start_test_time*1000)) align by device" "$raw" 120; then
        v_audit_log_summary='audit_status=QUERY_ERROR'
        record_fail 'AUDIT_QUERY_ERROR'; return 1
    fi
    if ! "$ha_sync_python" "$mm_check" audit "$raw" >"$parsed" 2>"$artifact_dir/audit_log_size.parse.err"; then
        v_audit_log_summary='audit_status=PARSE_ERROR'
        record_fail 'AUDIT_QUERY_PARSE_ERROR'; return 1
    fi
    read -r count size maximum devices average <"$parsed"
    v_audit_log_count=$count
    v_audit_log_max_bytes=$maximum
    v_audit_log_avg_bytes=$average
    v_audit_log_summary="audit_log_count=$count,max_bytes=$maximum,avg_bytes=$average,threshold_bytes=$threshold"
    log INFO "TDB-8 audit size: $v_audit_log_summary raw=$raw"
    if [ "$count" = 0 ]; then record_fail 'audit_records_missing'; return 1; fi
    if [ "$maximum" -gt "$threshold" ]; then record_fail 'audit_log_record_oversized'; return 1; fi
    return 0
}

function check_log()
{
exec 3<${nodeinfo_dir}/confignode.txt
while read line<&3
do
   ssh ${os_user_name}@${line} "gunzip ${db_dir}/logs/*confignode*all*"
   v_npe=`ssh ${os_user_name}@${line} "grep NullPointer ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err1=`ssh ${os_user_name}@${line} "grep BufferUnderflowException ${db_dir}/logs/*confignode*all*|wc -l"`
   v_cn_err2=`ssh ${os_user_name}@${line} "grep \"but return HAS_MORE_STATE\" ${db_dir}/logs/*confignode*all*|wc -l"`
   if [[ ${v_npe} -gt 0 ]];then
	   let fail_flag++
	   let backup_log_flag++
           v_warnMessage="${v_warnMessage}CN NPE."
	   echo "CN ${line} NullPointer : ${v_npe}"
   fi
   v_cn_err_total=$((v_cn_err1+v_cn_err2))
   if [[ ${v_cn_err_total} -gt 0 ]];then
           let fail_flag++
           let backup_log_flag++
           v_warnMessage="${v_warnMessage}CN HAS_MORE_STATE."
           echo "CN ${line} has error: ${v_npe}"
   fi
done
exec 3<${nodeinfo_dir}/datanode.txt
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
	   let backup_log_flag++
           v_warnMessage="${v_warnMessage}DN NPE."
           echo "DN ${line} NullPointer : ${v_npe}"
   fi
   if [[ ${v_dn_total_err} -gt 0 ]];then
	   let fail_flag++
	   let backup_log_flag++
           v_warnMessage="${v_warnMessage}DN unexp log."
	   echo "DN ${line} has error: ${v_dn_total_err}"
   fi

done


}
# 检查目标DataNode是否已经包含指定的Region
function is_region_on_target_dn() {
    local region_id=$1
    local target_dn_id=$2
    local dialect=$3
    
    # 获取目标DataNode上已有的Region列表
    local target_regions=$(${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_mig_user_name} -sql_dialect "$dialect" -e "show regions;" | \
        grep "Region|"|awk -F '|' '{gsub(" ",""); print $2","$8}'|grep ",${target_dn_id}"| \
        awk -F ',' '{gsub(" ", "", $2); print $1}' | tr '\n' ' ')
    # 检查目标Region是否存在于目标DataNode上
    for existing_region in $target_regions; do
        if [[ "$existing_region" == "$region_id" ]]; then
            return 0  # 区域已存在，返回真
        fi
    done
    return 1  # 区域不存在，返回假
}

function migrate_region()
{
   local v_mig_id=$1
   local v_mig_from_dn_id=$2
   local v_mig_to_dn_id=$3
   local v_dialect=$4
   
   # 检查目标DataNode是否已经包含要迁移的Region
   if is_region_on_target_dn "$v_mig_id" "$v_mig_to_dn_id" "$v_dialect"; then
       echo "⚠️  Region ${v_mig_id} 已经存在于目标DataNode ${v_mig_to_dn_id} 上，跳过迁移"
       return 0
   fi
   
   # exec migrate
   echo "执行迁移: migrate region ${v_mig_id} from ${v_mig_from_dn_id} to ${v_mig_to_dn_id} (dialect: ${v_dialect})"
   ${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -u ${v_mig_user_name}  -sql_dialect ${v_dialect} -e "migrate region ${v_mig_id} from ${v_mig_from_dn_id} to ${v_mig_to_dn_id};" > ${cur_dir}/tmp.out
   check_res "successfully" 1 "migrate region ${v_mig_id} from ${v_mig_from_dn_id} to ${v_mig_to_dn_id}"
   if [[ ${fail_flag} = 0 ]];then
        # 初始化连续v_mig_status_num=0的计数器
        local count_zero_status=0
        # 定义连续3次为退出阈值
        local MAX_ZERO_COUNT=3

        while true
        do
            # 获取迁移状态数量（Adding/Removing的region数）
            v_mig_status_num=$(${cli_dir}/sbin/start-cli.sh -h ${query_ip}  -u ${v_mig_user_name} -sql_dialect ${v_dialect}  -e "show regions;" | egrep "Adding|Removing" | wc -l)

            ## 连续3次v_mig_status_num=0
            # 重置/累加计数器
            if [[ ${v_mig_status_num} -eq 0 ]]; then
                count_zero_status=$((count_zero_status + 1))
                echo "当前v_mig_status_num=0，连续计数：${count_zero_status}/${MAX_ZERO_COUNT}"
            else
                count_zero_status=0  # 非0则重置计数器
                echo "当前v_mig_status_num=${v_mig_status_num}，重置连续0计数"
            fi

            # 检查是否达到连续3次0
            if [[ ${count_zero_status} -ge ${MAX_ZERO_COUNT} ]]; then
                echo "满足条件：连续${MAX_ZERO_COUNT}次v_mig_status_num=0，迁移完成"
                break
            fi

            # 未满足条件，休眠60秒后继续循环
            sleep 60
        done
   fi
}

# 动态解析所有DataNode信息，并过滤掉源节点（修复IP字符串子集匹配问题）
function get_all_target_datanodes() {
    # 执行show datanodes并保存完整输出
    local datanodes_output=$(${cli_dir}/sbin/start-cli.sh -u ${v_mig_user_name} -h ${query_ip} -sql_dialect tree -e "show datanodes;")
    if [[ -z "$datanodes_output" ]]; then
        echo "❌ 执行 show datanodes 失败，输出为空" >&2
        return 1
    fi

    # 第一步：解析表头，找到RpcAddress和NodeID列的位置
    local header_line=$(echo "$datanodes_output" | grep -m1 "NodeID")
    if [[ -z "$header_line" ]]; then
        echo "❌ 未找到 show datanodes 表头，无法解析列位置" >&2
        return 1
    fi

    local -a headers=()
    IFS='|' read -ra headers <<< "$(echo "$header_line" | tr -d ' ')"
    
    local rpc_addr_col=-1
    local node_id_col=-1
    for i in "${!headers[@]}"; do
        if [[ "${headers[$i]}" == "RpcAddress" ]]; then
            rpc_addr_col=$i
        elif [[ "${headers[$i]}" == "NodeID" ]]; then
            node_id_col=$i
        fi
    done

    if [[ $rpc_addr_col -eq -1 || $node_id_col -eq -1 ]]; then
        echo "❌ 未找到 RpcAddress 或 NodeID 列，表头：${header_line}" >&2
        return 1
    fi

    # 第二步：解析数据行，过滤源节点，输出有效节点
    echo "$datanodes_output" | \
        grep -v "NodeID" | grep -v "Total line number" | grep -v "It costs" | \
        while IFS='|' read -ra cols; do
            # 修复：确保变量正确绑定
            if [[ ${#cols[@]} -gt $rpc_addr_col && ${#cols[@]} -gt $node_id_col ]]; then
                local rpc_address=$(echo "${cols[$rpc_addr_col]}" | tr -d ' ' | xargs)
                local node_id=$(echo "${cols[$node_id_col]}" | tr -d ' ' | xargs)
                
                # 跳过源节点 + 过滤空值
                if [[ -n "$rpc_address" && -n "$node_id" && ! "$rpc_address" =~ ^${mig_from_ip}$ ]]; then
                    echo "$node_id $rpc_address"
                fi
            fi
        done
}
# 统计目标节点上的Region数量，选择最少的节点
function get_least_loaded_dn() {
    local dialect=$1
    local region_id=$2  # 新增参数：要迁移的Region ID
    
    # 初始化所有目标节点的计数为0
    declare -A dn_count
    
    # 修复：用临时文件替代进程替换，兼容所有Shell
    local tmp_dn_list="${cur_dir}/tmp_dn_list_$$.txt"
    get_all_target_datanodes > "$tmp_dn_list"
    
    # 读取目标节点列表，初始化计数
    while IFS=' ' read -r dn_id _; do
        if [[ -n "$dn_id" ]]; then
            # 检查此DataNode是否已经包含该Region
            if ! is_region_on_target_dn "$region_id" "$dn_id" "$dialect"; then
                dn_count[$dn_id]=0
            fi
        fi
    done < "$tmp_dn_list"
    rm -f "$tmp_dn_list"

    # 检查是否有可用的目标节点
    if [[ ${#dn_count[@]} -eq 0 ]]; then
        echo "❌ 错误：未找到任何可用的目标 DataNode，无法进行迁移" >&2
        return 1
    fi

    # 统计每个节点上的Region数量
    local tmp_region_list="${cur_dir}/tmp_region_list_$$.txt"
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_mig_user_name} -sql_dialect "$dialect" -e "show regions;" | \
        grep -v "Total line number" | grep -v "It costs" | \
        awk -F '|' '{gsub(" ", "", $7); print $7}' > "$tmp_region_list"
    
    while IFS= read -r dn_id; do
        # 核心修复：只统计已初始化的dn_id，避免空值或不存在的dn_id导致数组下标错误
        if [[ -n "$dn_id" && -n "${dn_count[$dn_id]+isset}" ]]; then
            dn_count[$dn_id]=$(( ${dn_count[$dn_id]} + 1 ))
        fi
    done < "$tmp_region_list"
    rm -f "$tmp_region_list"

    # 找到数量最少的节点
    local min_count=999999
    local target_dn=""
    for dn_id in "${!dn_count[@]}"; do
        if [[ ${dn_count[$dn_id]} -lt $min_count ]]; then
            min_count=${dn_count[$dn_id]}
            target_dn=$dn_id
        fi
    done

    # 最终检查：确保返回了有效的DN ID
    if [[ -z "$target_dn" ]]; then
        echo "❌ 错误：无法确定负载最少的目标 DataNode" >&2
        return 1
    fi

    echo "$target_dn"
}

# 从可用的目标DataNode中查找一个不包含指定Region的节点
function find_available_target_dn() {
    local dialect=$1
    local region_id=$2
    
    # 获取所有目标DataNode列表
    local tmp_dn_list="${cur_dir}/tmp_dn_list_$$.txt"
    get_all_target_datanodes > "$tmp_dn_list"
    
    # 遍历所有目标节点，找到第一个不包含该Region的节点
    while IFS=' ' read -r dn_id _; do
        if [[ -n "$dn_id" ]]; then
            # 检查此DataNode是否已经包含该Region
            if ! is_region_on_target_dn "$region_id" "$dn_id" "$dialect"; then
                rm -f "$tmp_dn_list"
                echo "$dn_id"
                return 0
            fi
        fi
    done < "$tmp_dn_list"
    
    rm -f "$tmp_dn_list"
    # 如果没有找到合适的节点，则返回错误
    echo "❌ 错误：找不到可用的目标DataNode，所有节点都已包含Region ${region_id}" >&2
    return 1
}
# 同步优化get_source_dn_id函数（避免IP子集匹配）
function get_source_dn_id() {
    # 执行show datanodes并保存完整输出
    local datanodes_output=$(${cli_dir}/sbin/start-cli.sh -u ${v_mig_user_name} -h ${query_ip} -sql_dialect tree -e "show datanodes;")
    if [[ -z "$datanodes_output" ]]; then
        echo "❌ 执行 show datanodes 失败，输出为空" >&2
        return 1
    fi

    # ========== 第一步：解析表头，找到RpcAddress和NodeID列的位置 ==========
    local header_line=$(echo "$datanodes_output" | grep -m1 "NodeID")  # 提取表头行
    if [[ -z "$header_line" ]]; then
        echo "❌ 未找到 show datanodes 表头，无法解析列位置" >&2
        return 1
    fi

    # 拆分表头为数组，忽略空格，获取列名
    local -a headers=()
    IFS='|' read -ra headers <<< "$(echo "$header_line" | tr -d ' ')"
    
    # 查找RpcAddress和NodeID列的索引（从0开始）
    local rpc_addr_col=-1
    local node_id_col=-1
    for i in "${!headers[@]}"; do
        if [[ "${headers[$i]}" == "RpcAddress" ]]; then
            rpc_addr_col=$i
        elif [[ "${headers[$i]}" == "NodeID" ]]; then
            node_id_col=$i
        fi
    done

    # 检查列索引是否有效
    if [[ $rpc_addr_col -eq -1 || $node_id_col -eq -1 ]]; then
        echo "❌ 未找到 RpcAddress 或 NodeID 列，表头：${header_line}" >&2
        return 1
    fi

    # ========== 第二步：解析数据行，精准匹配目标IP ==========
    echo "$datanodes_output" | \
        grep -v "NodeID" | grep -v "Total line number" | grep -v "It costs" | \
        while IFS='|' read -ra cols; do
            # 修复：确保变量正确绑定
            if [[ ${#cols[@]} -gt $rpc_addr_col && ${#cols[@]} -gt $node_id_col ]]; then
                # 清理每一列的空格（关键）
                local rpc_address=$(echo "${cols[$rpc_addr_col]}" | tr -d ' ' | xargs)
                local node_id=$(echo "${cols[$node_id_col]}" | tr -d ' ' | xargs)
                
                # 精准匹配目标IP，避免子集问题
                if [[ "$rpc_address" =~ ^${mig_from_ip}$ ]]; then
                    echo "$node_id"
                    break  # 找到后立即退出，避免多输出
                fi
            fi
        done
}
# 主执行函数：迁移指定dialect下的所有Region
function migrate_all_regions_for_dialect() {
    local dialect=$1
    local from_dn_id=$(get_source_dn_id)
    if [[ -z "$from_dn_id" ]]; then
        echo "❌ 错误：无法获取源节点 DataNode ID，跳过 ${dialect} 模型迁移"
        return 1
    fi

    echo "=== 开始迁移 dialect=${dialect} 下，从节点 ${mig_from_ip} (DN: ${from_dn_id}) 的所有Region ==="
    local region_list_file="${cur_dir}/v_${dialect}_mig_id_list.txt"
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_mig_user_name} -sql_dialect "$dialect" -e "show regions;" | \
        grep "${mig_from_ip}|" | grep -v "Total line number" | grep -v "It costs" | \
        awk -F '|' '{gsub(" ", "", $2); print $2}' > "$region_list_file"
    
    if [[ ! -s "$region_list_file" ]]; then
        echo "⚠️  在 ${dialect} 模型下，未找到需要从 ${mig_from_ip} 迁移的Region"
        return 0
    fi

    while IFS= read -r v_mig_id; do
        if [[ -n "$v_mig_id" ]]; then
            # 每次迁移前，查找可用的目标DataNode（不包含该Region的节点）
            local to_dn_id=$(find_available_target_dn "$dialect" "$v_mig_id")
            
            # 核心修复：检查to_dn_id是否有效，无效则终止迁移
            if [[ -z "$to_dn_id" ]]; then
                echo "❌ 迁移 Region ${v_mig_id} 失败：无法获取有效的目标 DataNode ID，终止当前模型迁移"
                return 1
            fi

            echo "将迁移 Region ${v_mig_id} 从 DN ${from_dn_id} 到 DN ${to_dn_id} (dialect: ${dialect})"
            migrate_region "$v_mig_id" "$from_dn_id" "$to_dn_id" "$dialect"
            
            # 检查迁移是否失败
            if [[ ${fail_flag} -ne 0 ]]; then
                echo "❌ 迁移 Region ${v_mig_id} 失败，终止当前模型迁移"
                return 1
            fi
        fi
    done < "$region_list_file"
    
    echo "=== 完成 dialect=${dialect} 下的所有Region迁移 ==="
    return 0
}
# 主入口：迁移树模型和表模型的所有Region
function exec_migrate_region()
{
    echo "开始清空节点 ${mig_from_ip} 上的所有Region..."
    # 先迁移树模型（tree）
    migrate_all_regions_for_dialect "tree"
    # 再迁移表模型（table）
    migrate_all_regions_for_dialect "table"
    echo "✅ 所有迁移任务执行完毕！"
}
# 同步优化缩容函数中的节点检查逻辑（核心修复点）
function remove_datanode() {
    local from_dn_id=$(get_source_dn_id)
    if [[ -z "$from_dn_id" ]]; then
        echo "❌ 未找到 ${mig_from_ip} 对应的DataNode ID，缩容失败"
        return 1
    fi

    echo "=== 开始缩容节点 ${mig_from_ip} (DN ID: ${from_dn_id}) ==="
    # 执行remove datanode命令
    ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_mig_user_name} -sql_dialect tree -e "remove datanode ${from_dn_id};" > ${cur_dir}/remove_dn.out
    check_res "successfully" 1 "remove datanode ${from_dn_id}"

    if [[ ${fail_flag} -ne 0 ]]; then
        echo "❌ 执行remove datanode命令失败，终止缩容流程"
        return 1
    fi

    # 等待缩容完成：循环检查show datanodes中是否还有该节点（修复IP子集匹配）
    local wait_seconds=0
    local max_wait_seconds=1800  # 最大等待时间：30分钟
    local check_interval=30      # 检查间隔：30秒
    while true; do
        # 核心修复：用awk精准提取RpcAddress列，再用^$匹配整行IP，避免子集问题
        local dn_exists=$(${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "show datanodes;" | \
            grep -v "NodeID" | grep -v "Total line number" | grep -v "It costs" | \
            awk -F '|' '{gsub(" ", "", $4); print $4}' | grep -c "^${mig_from_ip}$")
        
        if [[ ${dn_exists} -eq 0 ]]; then
            echo "✅ 缩容完成：${mig_from_ip} 已从DataNode列表中移除"
            break
        fi

        # 检查是否超时
        if [[ ${wait_seconds} -ge ${max_wait_seconds} ]]; then
            echo "❌ 缩容超时：等待${max_wait_seconds}秒后，${mig_from_ip} 仍未从DataNode列表中移除"
            return 1
        fi

        echo "⏳ 等待缩容完成：已等待${wait_seconds}秒，${mig_from_ip} 仍在DataNode列表中（剩余等待时间：$((max_wait_seconds - wait_seconds))秒）"
        sleep ${check_interval}
        wait_seconds=$((wait_seconds + check_interval))
    done
}
function wait_benchmark()
{
    while true
    do
        v_bm_num=`jps|grep App|wc -l`
        if [[ ${v_bm_num} -gt 0 ]];then
            sleep 120
        else
            ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect tree -e "flush;"
            ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -sql_dialect table -e "flush;"
            break
            return 0
        fi
    done
}
function testcase1()
{
# 执行迁移
exec_migrate_region
remove_datanode
# wait benchmark
wait_benchmark
# check data
check_data_consistent
# capture bounded audit evidence before write_result stops the cluster
check_audit_log_size
#check log
check_log
}
# Validate naming before any cluster cleanup/start or benchmark workload.
mm_prepare_benchmark || exit 1
# start cluster 
echo "">${log_file}
start_db
# start test time
v_start_test_time=`date +%s`
create_user
if [[ ${prepare_fail_flag} = 0 ]];then
start_bm
testcase1
fi
v_end_test_time=`date +%s`
v_elp_time=$((v_end_test_time-v_start_test_time))
# record test result
function sql_escape_result()
{
    printf '%s' "$1" | tr '\r\n;' '  ,' | sed "s/'/''/g"
}
function write_result()
{
    local result result_message message_value escaped_message escaped_script escaped_db escaped_consensus
    local out="$artifact_dir/write_result.out" verify_out="$artifact_dir/write_result_verify.out"
    local stamp sql writeback_ok=0
    v_result_iotdb_ip=$(grep ^test_result_iotdb_ip "$conf_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    v_bm_max_value=0
    v_bm_sum_value=0
    if [ -n "${bm_log_dir:-}" ] && [ -n "${bm_test_time:-}" ]; then
        v_bm_max_value=$(grep "Test elapsed" "$bm_log_dir/$bm_test_time"*out 2>/dev/null | awk '{print $8}' | sort -n | tail -1)
        v_bm_sum_value=$(grep "Test elapsed" "$bm_log_dir/$bm_test_time"*out 2>/dev/null | awk '{sum+=$8} END{print sum+0}')
    fi
    [[ "$v_bm_max_value" =~ ^[0-9]+([.][0-9]+)?$ ]] || v_bm_max_value=0
    [[ "$v_bm_sum_value" =~ ^[0-9]+([.][0-9]+)?$ ]] || v_bm_sum_value=0
    if [ "$fail_flag" -gt 0 ]; then result=FAIL; else result=PASS; fi
    result_message="$v_warnMessage;$v_audit_log_summary;artifacts=$artifact_dir"
    printf '%s\n' "$result_message" >"$artifact_dir/result_message.original.txt"
    message_value=$(printf '%s' "$result_message" | tr '\r\n;' '  ,')
    escaped_message=$(sql_escape_result "$result_message")
    escaped_script=$(sql_escape_result "$SCRIPT_NAME")
    escaped_db=$(sql_escape_result "$testdb")
    escaped_consensus=$(sql_escape_result "$v_consensus")
    stamp=$(date +%s%3N)
    sql="insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values($stamp,'$escaped_db','$escaped_script','$escaped_consensus','$result',$v_elp_time,$v_bm_max_value,$v_bm_sum_value,$v_warnNum,'$escaped_message')"
    printf '%s\n' "$sql" >"$artifact_dir/write_result.sql"
    if [ -n "$v_result_iotdb_ip" ] && mm_cli "$v_result_iotdb_ip" tree "$sql" "$out" 60; then
        if mm_cli "$v_result_iotdb_ip" tree \
          "select testResult,testCaseName,testOtherMessage from root.test.$CLUSTER_ID where time=$stamp" "$verify_out" 60 &&
          "$ha_sync_python" "$mm_check" verify "$verify_out" "$SCRIPT_NAME" "$result" "$message_value" \
             >"$artifact_dir/write_result_verify.status" 2>&1; then
            writeback_ok=1
        fi
    fi
    if [ "$writeback_ok" -eq 1 ]; then
        result_writeback_fail=0
        log INFO "RESULT_WRITEBACK_VERIFIED time=$stamp result=$result"
    else
        result_writeback_fail=1
        log WARN 'RESULT_WRITEBACK_FAILED; preserve original testcase result in artifacts'
    fi
    printf 'result=%s\nfail_flag=%s\nwriteback_failed=%s\nartifacts=%s\n' \
      "$result" "$fail_flag" "$result_writeback_fail" "$artifact_dir" >"$artifact_dir/result.status"
    echo "testcase1 ${result,,}"
    log INFO "RESULT fail_flag=${fail_flag} msg=${message_value:-.}"
    backup_log_flag=1
    v_tc_name_pre=${SCRIPT_NAME%.sh}
    v_backup_time=$(date +%Y_%m_%d_%H_%M_%S)
    sh -x "$clean_env_dir/stop_cluster.sh" >>"$log_file" 2>&1
    sh -x "$clean_env_dir/backup_cluster_logs.sh" "${v_tc_name_pre}_$v_backup_time" >>"$log_file" 2>&1
}

write_result
