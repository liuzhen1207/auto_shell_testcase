#!/bin/bash
# =============================================================================
# CAM_P0_06  RECONSTRUCT 重建在移除旧副本前被 CANCEL ALL MIGRATIONS 取消
#            + 重建目标端 snapshot 残留校验（树 / 普通表 / 可写视图三路，串行两批）
# -----------------------------------------------------------------------------
# 需求: V2.0.11.1 负载均衡 - CANCEL ALL MIGRATIONS 语句。
# 环境: 3C5D，SchemaRegion 副本=3，DataRegion 副本=2，IoTConsensus。
# 负载: 3 个 benchmark 并发写入(均边写边查)，写入时间为真实当前系统时间，
#       START_TIME=测试开始时间:
#   1) 树     root.test.g_0          (无 object)
#   2) 可写视图 usr_sod0.writable_view_0 (含 OBJECT 列; object 每点 1 文件, 仅此路写 object 以控体量)
#   3) 普通表  usr_nrm0.normal_table_0  (无 object)
# 手动环境无 KillPoint，故用 region_migration_speed_limit_bytes_per_second=1MB/s
# 拉长底层 MIGRATE 的 add-peer snapshot 传输窗口。
# RECONSTRUCT 先移除 tgt 上的旧副本，再在同一 tgt 上新增副本。
# 删除旧副本前收到 CANCEL 应中止重建并保留旧副本；旧副本已删除后收到 CANCEL，
# 为保证副本完整性必须忽略取消并完成 add-peer。add-peer 可能向 tgt 传输 snapshot，
# 因此无论取消生效或放行，最终都检查 tgt 无 snapshot_<regionId>_<uuid> 残留。
# 本用例对 3 个 DataRegion 执行 RECONSTRUCT，串行两批：批1 tree 单 region；
# 批2 普通表+可写视图双 region，一条 CANCEL 同时向两条顶层任务发信号。
# RECONSTRUCT 语法: `reconstruct region <regionId> on <tgt>`，tgt 为当前持有者之一。
#
# 断言(对应 Excel CAM_P0_06 预期结果):
#   1) CANCEL ALL MIGRATIONS 立即返回 "The statement is executed successfully."(非阻塞)
#   2) show migrations RECONSTRUCT 行消失、最终 Empty set
#   3) 副本集合==baseline，tgt 状态为 Running；删除前取消时旧副本被保留
#   4) tgt 无 snapshot_<regionId>_<uuid> 残留
#   5) ConfigNode 日志出现取消信号；命中安全点时出现 RECONSTRUCT 取消回滚标记
#   6) 副本数据一致性: 逐个 stop 1 非-tgt DN 与基准对比(DR=2, 移 1 仍有 1 在线)
#   然后检查日志(NPE/异常/快照错误)、备份日志。
#
# 参考脚本: tc2026_CancelAllMigrations_0002_extend_add_phase_cancel_tree_table_object_writeview.sh
#           (本脚本由其 fork, 把 EXTEND 换成 REMOVE;
#            region 选择(选持有者)/检测窗口(看到 REMOVE 即 CANCEL)/回滚验证(tgt 须保留副本)/
#           snapshot 校验(子 MIGRATE 目标)均做 REMOVE 适配)
# ==============================================================================
set -uo pipefail

cur_dir="$( cd "$( dirname "$0" )" && pwd )"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

# --------------------------- 读取全局配置 -----------------------------------
os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
shell_client_db_parent_dir=$(grep "^v_shell_client_db_parent_dir=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
cli_dir=${shell_client_db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
cn_db_parent_dir=$(grep ^v_cn_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}')
cn_db_dir=${cn_db_parent_dir}/${testdb}

clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
CLUSTER_ID=$(grep ^CLUSTER_NAME "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')

# --------------------------- 集群规格 ---------------------------------------
cn_num=3
dn_num=5
dr_rep_num=2            # DataRegion 副本数 = 2
sr_rep_num=3            # SchemaRegion 副本数 = 3
total_node_num=$((cn_num + dn_num))
v_cluster_num_info="${cn_num}C${dn_num}D"
v_consensus="IoTConsensus"
ssl_str=""

# 迁移限速: 1MB/s，拉长新增副本窗口以便 CANCEL 命中(默认 48MB/s 太快)
region_migration_speed_limit=1048576
migrate_thread_count=10
# DataNode Prometheus 指标端口(用于直连各 DN 抓取 syncLag 判断副本同步归零)。
# 中心 Prometheus(172.16.2.25) 不采集本集群 ClusterID2，故直连各 DN :dn_metric_port/metrics。
dn_metric_port=9092

# Thrift 最大帧大小: 调到 256MB。默认 0(不限)在大 region 迁移/大 object 写入时可能触发帧过大错误;
# 显式设 256MB 与 tc0003 参考一致(CN/DN 均设 dn_thrift_max_frame_size)。
thrift_max_frame_size=268435456

# --------------------------- 运行产物目录 -----------------------------------
run_timestamp=$(date +'%Y_%m_%d_%H_%M_%S')
run_artifact_dir="${cur_dir}/${SCRIPT_NAME%.*}_${run_timestamp}"
log_file="${run_artifact_dir}/set_conf_parallel.log"

# --------------------------- benchmark ------------------------------------
bm_base_dir="${cur_dir}/../benchmark/bm_20260625_1f2d2e3_jdk17"
bm_dir="${bm_base_dir}/conf_cancel"
bm_runner="${bm_base_dir}/benchmark.sh"
bm_tree_conf="${bm_dir}/conf_tree"              # 1) 树(root.test.g_0, 无 object)
bm_table_conf="${bm_dir}/conf_table"            # 2) 可写视图表(usr_sod0.writable_view_0, 含 object)
bm_table_plain_conf="${bm_dir}/conf_table_plain"  # 3) 普通表(usr_nrm0.normal_table_0, 无 object)
bm_guard_seconds=$((2 * 3600))          # benchmark 进程硬看门狗
bm_write_seconds=1200                    # benchmark 写入约 20 分钟(养大 Region)
bm_test_max_time_ms=$((bm_write_seconds * 1000))
bm_loop=100000000
# tree 每设备传感器列数: 默认 12 时压缩后单 tree region 仅 ~23MB。
# 120 列时单 region ~100MB, 但迁移走了 IoTConsensus 日志复制快路径(0 次 transmitSnapshot)、~1s 完成,
# region_migration_speed_limit 只对 snapshot 传输生效 -> 限速没起作用。
# 再 x10 到 1200 列: 单 region 涨到 ~1GB 量级, 数据量远超 consensus 日志可追赶范围,
# 迫使新副本走 snapshot 传输(受 1MB/s 限速)-> add-peer 阶段持续数分钟, 取消窗口稳定。
# (INSERT_DATATYPE_PROPORTION 是比例, 自动按列数缩放, 无需改; 末位=0 仍无 object。)
tree_sensor_number=1200
bm_pids=()
bm_start_epoch=0
bm_elapsed_seconds=0

cluster_ready_timeout_seconds=600
# 迁移进入 add 阶段的等待/超时
add_phase_wait_timeout=600
cancel_converge_timeout=1800
snapshot_cleanup_timeout=900
snapshot_cleanup_check_interval=10
snapshot_cleanup_no_progress_timeout=180

# --------------------------- 节点清单 ---------------------------------------
rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

benchmark_hosts=$(paste -sd, "${nodeinfo_dir}/datanode.txt")
benchmark_ports=$(awk 'BEGIN{ORS=""} {if (NR>1) printf ","; printf "6667"} END{print ""}' "${nodeinfo_dir}/datanode.txt")

# --------------------------- 业务对象命名(与 benchmark 配置一致) -------------
# tree  : DB_NAME=test, GROUP_NAME_PREFIX=g_ -> root.test.g_0(无 object)
# 可写视图: DB_NAME=usr, GROUP_NAME_PREFIX=sod -> usr_sod0; TABLE_NAME_PREFIX=writable_view_
#          -> 可写视图表 usr_sod0.writable_view_0(含 object 列)
# 普通表 : DB_NAME=usr, GROUP_NAME_PREFIX=nrm -> usr_nrm0; TABLE_NAME_PREFIX=normal_table_
#          -> 普通表 usr_nrm0.normal_table_0(无 object)
TREE_DB_PATH="root.test.g_0"
TABLE_DB_NAME="usr_sod0"
TABLE_NAME="writable_view_0"
TABLE2_DB_NAME="usr_nrm0"
TABLE2_NAME="normal_table_0"


# --------------------------- REMOVE 上下文(3 slot, 串行两批) -------------------
# REMOVE 底层将 tgt 上的 region migrate 到其他 DN(dn_new), 同 MIGRATE 的 add-peer。
# 沿用 mig_* 变量名以降风险, 新增 migrate_dest_dn_id/ip 追踪子 MIGRATE 目标。
# slot 0=tree, 1=table_plain, 2=table_view。tgt = 当前持有该 region 的节点。
mig_count=3
mig_slot_name=("tree" "table_plain" "table_view")
mig_slot_dialect=("tree" "table" "table")
mig_slot_db=("${TREE_DB_PATH}" "${TABLE2_DB_NAME}" "${TABLE_DB_NAME}")
mig_region_id=("" "" "")
mig_src_dn_id=("" "" "")    # REMOVE 不传 src, 保留结构兼容
mig_src_dn_ip=("" "" "")
mig_tgt_dn_id=("" "" "")    # tgt = 当前持有者(移除目标, 与 MIGRATE/EXTEND 的"不持有"相反)
mig_tgt_dn_ip=("" "" "")
mig_baseline_dn_ids=("" "" "")
mig_cmd_pid=("" "" "")
mig_cancel_phase=("" "" "")
mig_used_targets=""          # REMOVE 中不用于去重, 仅保留结构兼容
# snapshot 接收端；RECONSTRUCT 固定为重建目标 tgt。
migrate_dest_dn_id=("" "" "")
migrate_dest_dn_ip=("" "" "")
cancel_elapsed_seconds=0
cancel_converge_seconds=0
cancel_batch_timings=""
cancel_batch_timings=""

# 测试开始时间(ISO-8601 带时区，如 2026-07-08T16:10:00+08:00)，main 启动时捕获一次，
# 作为 benchmark 的 START_TIME(=测试开始时间)。写入时间仍由 IS_RECORD_CURRENT_REALLY_TIME=true
# 决定为真实当前系统时间。
test_start_iso=""

# --------------------------- 统计 -------------------------------------------
fail_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."

# =============================================================================
# 工具函数
# =============================================================================
log() {
    local level=$1
    local msg=$2
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" | tee -a "${log_file}"
}

snapshot_ts() { date +'%Y_%m_%d_%H_%M_%S_%N'; }

archive_snapshot() {
    local src_file=$1
    local archive_base=$2
    cp -f "${src_file}" "${run_artifact_dir}/${archive_base}_$(snapshot_ts).out" 2>/dev/null || true
}

trim_file_crlf() {
    local file=$1
    sed -i 's/\r$//' "${file}" 2>/dev/null || true
}

normalize_query_result() {
    # 去掉每次都会变化的耗时行，便于跨节点 diff
    local src_file=$1
    local dst_file=$2
    sed '/^It costs /d' "${src_file}" > "${dst_file}"
}

check_cli_success() {
    local file=$1
    local desc=$2
    trim_file_crlf "${file}"
    if grep -Eq "Exception|ERROR|Error" "${file}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${desc} failed."
        log "ERROR" "${desc} failed"
        cat "${file}" >> "${log_file}"
        return 1
    fi
    log "INFO" "${desc} success"
    return 0
}

cli_tree() { ${cli_dir}/sbin/start-cli.sh -u root ${ssl_str} -h "${1}" -timeout 3600 -sql_dialect tree -e "${2}"; }
cli_table() { ${cli_dir}/sbin/start-cli.sh -u root ${ssl_str} -h "${1}" -timeout 3600 -sql_dialect table -e "${2}"; }

# =============================================================================
# 集群清理 / 配置 / 启动
# =============================================================================
clean_env() {
    log "INFO" "Start cleaning cluster environment"
    force_stop_local_benchmark_apps
    force_stop_target_processes
    sh -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1
    sh -x "${clean_env_dir}/reset_conf.sh" >> "${log_file}" 2>&1
    sh -x "${clean_env_dir}/clear_cache.sh" >> "${log_file}" 2>&1
    force_remove_target_data
}

configure_confignode() {
    local node_ip=$1
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="4G"/g' ${cn_db_dir}/conf/confignode-env.sh
sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="2G"/g' ${cn_db_dir}/conf/confignode-env.sh

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

batch_set_sys_conf ".*cn_seed_config_node=.*" "cn_seed_config_node=${seed_cn_ip}"
batch_set_sys_conf ".*cn_internal_address=.*" "cn_internal_address=${node_ip}"
batch_set_sys_conf ".*cn_metric_reporter_list=.*" "cn_metric_reporter_list=PROMETHEUS"
batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=true"
batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
batch_set_sys_conf ".*migrate_thread_count=.*" "migrate_thread_count=${migrate_thread_count}"
batch_set_sys_conf ".*region_migration_speed_limit_bytes_per_second=.*" "region_migration_speed_limit_bytes_per_second=${region_migration_speed_limit}"
batch_set_sys_conf ".*dn_thrift_max_frame_size=.*" "dn_thrift_max_frame_size=${thrift_max_frame_size}"
EOF
}

configure_datanode() {
    local node_ip=$1
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${db_dir}/conf/datanode-env.sh
sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="2G"/g' ${db_dir}/conf/datanode-env.sh

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

batch_set_sys_conf ".*dn_seed_config_node=.*" "dn_seed_config_node=${seed_cn_ip}"
batch_set_sys_conf ".*dn_internal_address=.*" "dn_internal_address=${node_ip}"
batch_set_sys_conf ".*dn_rpc_address=.*" "dn_rpc_address=${node_ip}"
batch_set_sys_conf ".*dn_metric_reporter_list=.*" "dn_metric_reporter_list=PROMETHEUS"
batch_set_sys_conf ".*dn_metric_prometheus_reporter_port=.*" "dn_metric_prometheus_reporter_port=${dn_metric_port}"
batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=true"
batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
batch_set_sys_conf ".*migrate_thread_count=.*" "migrate_thread_count=${migrate_thread_count}"
batch_set_sys_conf ".*region_migration_speed_limit_bytes_per_second=.*" "region_migration_speed_limit_bytes_per_second=${region_migration_speed_limit}"
batch_set_sys_conf ".*dn_thrift_max_frame_size=.*" "dn_thrift_max_frame_size=${thrift_max_frame_size}"
EOF
}

configure_mixed_node() {
    local node_ip=$1
    configure_confignode "${node_ip}"
    configure_datanode "${node_ip}"
}

set_conf() {
    grep -v '^$' "${nodeinfo_dir}/confignode.txt" | sed 's/ //g' | sort -u > /tmp/cam_cn_ips.tmp
    grep -v '^$' "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sort -u > /tmp/cam_dn_ips.tmp

    local pids=()
    while read -r ip; do
        [ -z "${ip}" ] && continue
        if grep -q "^${ip}$" /tmp/cam_dn_ips.tmp; then
            configure_mixed_node "${ip}" &
        else
            configure_confignode "${ip}" &
        fi
        pids+=($!)
    done < /tmp/cam_cn_ips.tmp

    while read -r ip; do
        [ -z "${ip}" ] && continue
        if ! grep -q "^${ip}$" /tmp/cam_cn_ips.tmp; then
            configure_datanode "${ip}" &
            pids+=($!)
        fi
    done < /tmp/cam_dn_ips.tmp

    for pid in "${pids[@]}"; do
        if ! wait "${pid}"; then
            let fail_flag++
            log "ERROR" "configure pid ${pid} failed"
        fi
    done
    rm -f /tmp/cam_cn_ips.tmp /tmp/cam_dn_ips.tmp
}

force_stop_target_processes() {
    log "INFO" "Force stop target ${testdb} processes if they still exist"
    local node_ip
    # 用临时文件而非进程替换 <(...): 本脚本经 run_all_testcase.sh 以 `sh -x` 运行,
    # 此机 /bin/sh=bash 但以 sh 名启动即 POSIX 模式, 会禁用进程替换 <(...)(数组/[[ 仍可用)。
    local all_ips_file="${run_artifact_dir}/_all_node_ips_stop.tmp"
    cat "${nodeinfo_dir}/confignode.txt" "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sort -u > "${all_ips_file}"
    while read -r node_ip; do
        [ -z "${node_ip}" ] && continue
        ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
target="${testdb}"
pids=\$(ps -ef | grep "\${target}" | grep -E 'ConfigNode|DataNode' | grep -v grep | awk '{print \$2}')
if [ -n "\${pids}" ]; then
  kill -9 \${pids} || true
fi
EOF
    done < "${all_ips_file}"
    rm -f "${all_ips_file}"
}

force_stop_local_benchmark_apps() {
    log "INFO" "Force stop local benchmark App processes if they still exist"
    local apps
    apps=$(jps | awk '/ App$/ {print $1}')
    if [ -n "${apps}" ]; then
        kill -9 ${apps} >> "${log_file}" 2>&1 || true
    fi
}

force_remove_target_data() {
    log "INFO" "Force remove target ${testdb} data and logs"
    local node_ip
    # 同上: 用临时文件替代进程替换 <(...), 以兼容 sh(bash POSIX 模式) 运行。
    local all_ips_file="${run_artifact_dir}/_all_node_ips_rm.tmp"
    cat "${nodeinfo_dir}/confignode.txt" "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sort -u > "${all_ips_file}"
    while read -r node_ip; do
        [ -z "${node_ip}" ] && continue
        ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" "rm -rf '${db_dir}/data' '${db_dir}/logs' '${cn_db_dir}/data' '${cn_db_dir}/logs'" >> "${log_file}" 2>&1 || true
    done < "${all_ips_file}"
    rm -f "${all_ips_file}"
}

refresh_running_datanodes() {
    ${cli_dir}/sbin/start-cli.sh -u "${db_user_name}" ${ssl_str} -h "${query_ip}" -e "show datanodes;" > "${run_artifact_dir}/show_datanodes.out"
    trim_file_crlf "${run_artifact_dir}/show_datanodes.out"
    awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^\|/ {
        node_id = trim($2); status = trim($3); rpc_address = trim($4)
        if (node_id ~ /^[0-9]+$/ && status == "Running") {
            print node_id " " rpc_address
        }
    }' "${run_artifact_dir}/show_datanodes.out" > "${run_artifact_dir}/running_datanodes.txt"
}

wait_for_cluster_ready() {
    local begin_time round=0
    begin_time=$(date +%s)
    while true; do
        local cn_ok=1 dn_ok=1 node_ip
        while read -r node_ip; do
            [ -z "${node_ip}" ] && continue
            ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" "jps | grep -q ConfigNode" || cn_ok=0
        done < "${nodeinfo_dir}/confignode.txt"
        while read -r node_ip; do
            [ -z "${node_ip}" ] && continue
            ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" "jps | grep -q DataNode" || dn_ok=0
        done < "${nodeinfo_dir}/datanode.txt"

        if [ "${cn_ok}" -eq 1 ] && [ "${dn_ok}" -eq 1 ]; then
            refresh_running_datanodes || true
            if [ -f "${run_artifact_dir}/running_datanodes.txt" ] && [ "$(wc -l < "${run_artifact_dir}/running_datanodes.txt")" -eq "${dn_num}" ]; then
                log "INFO" "Cluster is ready with ${dn_num} running datanodes"
                return 0
            fi
        fi
        round=$((round + 1))
        if [ $((round % 6)) -eq 0 ]; then
            log "INFO" "Waiting cluster ready ..."
        fi
        if [ $(( $(date +%s) - begin_time )) -gt "${cluster_ready_timeout_seconds}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}cluster not ready after startup."
            log "ERROR" "Cluster not ready after ${cluster_ready_timeout_seconds}s"
            return 1
        fi
        sleep 5
    done
}

start_db() {
    log "INFO" "Start ${v_cluster_num_info} cluster (SR=${sr_rep_num}, DR=${dr_rep_num}, speed_limit=${region_migration_speed_limit}B/s)"
    clean_env
    set_conf
    if [ "${fail_flag}" -gt 0 ]; then
        log "ERROR" "Configuration failed"
        return 1
    fi
    timeout --preserve-status 120s sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1 \
        || log "WARN" "start_cluster_v20.sh returned non-zero or timed out, continue waiting for actual cluster readiness"
    wait_for_cluster_ready
}

# =============================================================================
# DataNode 停/启
# =============================================================================
wait_for_datanode_running() {
    local dn_ip=$1 timeout_seconds=$2 begin_time
    begin_time=$(date +%s)
    while true; do
        refresh_running_datanodes
        if grep -q " ${dn_ip}$" "${run_artifact_dir}/running_datanodes.txt"; then
            return 0
        fi
        if [ $(( $(date +%s) - begin_time )) -gt "${timeout_seconds}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}datanode ${dn_ip} not running."
            return 1
        fi
        sleep 5
    done
}

wait_for_datanode_stopped() {
    local dn_ip=$1 timeout_seconds=$2 begin_time jps_count
    begin_time=$(date +%s)
    while true; do
        jps_count=$(ssh -n "${os_user_name}@${dn_ip}" "jps | grep DataNode | wc -l" 2>/dev/null || echo 1)
        refresh_running_datanodes
        if [ "${jps_count}" -eq 0 ] && ! grep -q " ${dn_ip}$" "${run_artifact_dir}/running_datanodes.txt"; then
            return 0
        fi
        if [ $(( $(date +%s) - begin_time )) -gt "${timeout_seconds}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}stop dn ${dn_ip} timeout."
            return 1
        fi
        sleep 5
    done
}

stop_one_datanode() {
    local dn_ip=$1
    ssh -n "${os_user_name}@${dn_ip}" "source /etc/profile; cd ${db_dir}; ./sbin/stop-datanode.sh" >> "${log_file}" 2>&1
    wait_for_datanode_stopped "${dn_ip}" 300
}

start_one_datanode() {
    local dn_ip=$1
    ssh -n "${os_user_name}@${dn_ip}" "source /etc/profile; cd ${db_dir}; ./sbin/start-datanode.sh -H ${db_dir}/dn_$(date +%s)_heapdump.hprof > /dev/null 2>&1 &" >> "${log_file}" 2>&1
    wait_for_datanode_running "${dn_ip}" 600
}

# =============================================================================
# show regions / show migrations 采集
# =============================================================================
collect_regions() {
    local dialect=$1 stage=$2
    local out_file="${run_artifact_dir}/${stage}_${dialect}_regions.out"
    if [ "${dialect}" = "tree" ]; then
        cli_tree "${query_ip}" "show regions;" > "${out_file}"
    else
        cli_table "${query_ip}" "show regions;" > "${out_file}"
    fi
    trim_file_crlf "${out_file}"
    archive_snapshot "${out_file}" "${stage}_${dialect}_regions"
}

collect_migrations() {
    local dialect=$1 stage=$2
    local out_file="${run_artifact_dir}/${stage}_${dialect}_migrations.out"
    if [ "${dialect}" = "tree" ]; then
        cli_tree "${query_ip}" "show migrations;" > "${out_file}"
    else
        cli_table "${query_ip}" "show migrations;" > "${out_file}"
    fi
    trim_file_crlf "${out_file}"
    {
        echo "===== $(date +'%Y-%m-%d %H:%M:%S') stage=${stage} dialect=${dialect} show migrations ====="
        cat "${out_file}"
        echo
    } >> "${run_artifact_dir}/show_migrations_trace.out"
    echo "${out_file}"
}

# =============================================================================
# 为某个 slot 选择一个较大的用户 DataRegion + 一个不持有它、且未被其它 slot 占用的目标 DN
#   slot: 0=tree, 1=table_plain, 2=table_view
# =============================================================================

# =============================================================================
# 为 REMOVE 选择一个较大的 DataRegion + 从持有者中选一个作为移除目标 tgt。
#   与 MIGRATE/EXTEND 相反: tgt 必须是当前持有该 region 的节点。
#   slot: 0=tree, 1=table_plain, 2=table_view
# =============================================================================
select_region_for_reconstruct() {
    local slot=$1
    local dialect="${mig_slot_dialect[$slot]}"
    local expected_db="${mig_slot_db[$slot]}"
    local name="${mig_slot_name[$slot]}"
    refresh_running_datanodes
    collect_regions "${dialect}" "select_region_${name}"
    local region_file="${run_artifact_dir}/select_region_${name}_${dialect}_regions.out"
    if grep -Eq "Exception|ERROR|Error" "${region_file}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${name} show regions failed before remove."
        return 1
    fi

    local candidate_file="${run_artifact_dir}/select_region_${name}_candidates.out"
    awk -F'|' -v expected_db="${expected_db}" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    FNR == NR {
        line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line == "") next
        nf = split(line, a, /[ \t]+/)
        if (nf >= 2 && a[1] ~ /^[0-9]+$/) dn_ip[a[1]] = a[2]
        next
    }
    /^\|/ {
        region_id = trim($2); type = trim($3); status = trim($4); database = trim($5)
        time_slot = trim($7); dn_id = trim($8)
        if (region_id ~ /^[0-9]+$/ && type == "DataRegion" && status == "Running" &&
            database == expected_db && (dn_id in dn_ip)) {
            seen[region_id] = 1
            if (time_slot ~ /^[0-9]+$/ && time_slot+0 > size[region_id]+0) size[region_id] = time_slot+0
            if (members[region_id] == "") members[region_id] = dn_id
            else members[region_id] = members[region_id] " " dn_id
        }
    }
    END {
        for (region_id in seen) {
            target_dn=""; target_ip=""
            split(members[region_id], mem, /[ ]+/)
            n_mem = 0; for (k in mem) n_mem++
            if (n_mem < 2) continue
            target_dn = mem[1]; target_ip = dn_ip[target_dn]
            printf("%d %s %s %s [%s]\n", size[region_id], region_id, target_dn, target_ip, members[region_id])
        }
    }' "${run_artifact_dir}/running_datanodes.txt" "${region_file}" | sort -nr -k1,1 > "${candidate_file}"

    if [ ! -s "${candidate_file}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${name} no removable ${expected_db} DataRegion found (need >=2 holders, DR=${dr_rep_num})."
        log "ERROR" "${name} no removable ${expected_db} DataRegion found"
        return 1
    fi

    local first_line size_col rid tgt tgt_ip base
    first_line=$(sed -n '1p' "${candidate_file}")
    size_col=$(echo "${first_line}" | awk '{print $1}')
    rid=$(echo "${first_line}" | awk '{print $2}')
    tgt=$(echo "${first_line}" | awk '{print $3}')
    tgt_ip=$(echo "${first_line}" | awk '{print $4}')
    base=$(awk -F'|' -v rid="${rid}" '
        function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
        /^\|/ { if (trim($2)==rid) printf(" %s", trim($8)) }' "${region_file}" | sed 's/^ //' | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ *$//')

    mig_region_id[$slot]="${rid}"
    mig_tgt_dn_id[$slot]="${tgt}"
    mig_tgt_dn_ip[$slot]="${tgt_ip}"
    mig_baseline_dn_ids[$slot]="${base}"

    log "INFO" "Selected [${name}] region=${rid} (timeSlot~${size_col}) remove_target_dn=${tgt}(${tgt_ip}) baseline_members=[${base}]"
    return 0
}

# =============================================================================

# =============================================================================
# 判断 RECONSTRUCT 行是否出现在 show migrations 中。
#   只要顶层行存在即返回，尽早发送 CANCEL 以争取命中移除旧副本前的安全点。
#   返回: 0=行存在,可立即 CANCEL; 2=出错; 3=行不存在(继续等)
# =============================================================================
reconstruct_in_cancellable_state() {
    local slot=$1
    local dialect="${mig_slot_dialect[$slot]}"
    local rid="${mig_region_id[$slot]}"
    local mig_file
    mig_file=$(collect_migrations "${dialect}" "wait_reconstruct_${mig_slot_name[$slot]}")
    if grep -Eq "Exception|ERROR|Error" "${mig_file}"; then
        return 2
    fi
    if awk -F'|' -v rid="${rid}" '
        function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
        /^\|/ { for(i=1;i<=NF;i++) if(trim($i)==rid && $0 ~ /RECONSTRUCT/) hit=1 }
        END{ exit(hit?0:1) }' "${mig_file}"; then
        return 0
    fi
    return 3
}

# =============================================================================
# 等待 REMOVE 行出现在 show migrations -> 立即 CANCEL。
# slot_seen + slot_done: seen=row曾出现, done=slot已结束(不再轮询), 避免抓窗失败后死循环刷屏。
# =============================================================================
wait_reconstruct_in_cancellable_state() {
    local slots="$*" want=$#
    local begin_time i rc ready
    begin_time=$(date +%s)
    local slot_ready=("0" "0" "0")
    local slot_seen=("0" "0" "0")
    local slot_done=("0" "0" "0")
    while true; do
        ready=0; local done_count=0
        for i in ${slots}; do
            [ -z "${mig_region_id[$i]}" ] && continue
            if [ "${slot_done[$i]}" = "1" ]; then done_count=$((done_count+1)); continue; fi
            if [ "${slot_ready[$i]}" = "1" ]; then ready=$((ready+1)); continue; fi
            reconstruct_in_cancellable_state "${i}"
            rc=$?
            case "${rc}" in
                0) slot_ready[$i]=1; ready=$((ready+1)); slot_seen[$i]=1
                   log "INFO" "[${mig_slot_name[$i]}] RECONSTRUCT row appeared for region ${mig_region_id[$i]} -> ready to CANCEL";;
                2) let fail_flag++; v_warnMessage="${v_warnMessage}[${mig_slot_name[$i]}] show migrations failed while waiting RECONSTRUCT."; slot_done[$i]=1;;
                3) if [ "${slot_seen[$i]}" = "1" ]; then
                       let fail_flag++
                       v_warnMessage="${v_warnMessage}[${mig_slot_name[$i]}] RECONSTRUCT for region ${mig_region_id[$i]} completed before CANCEL (too fast)."
                       log "ERROR" "[${mig_slot_name[$i]}] RECONSTRUCT for region ${mig_region_id[$i]} finished before CANCEL"
                       slot_done[$i]=1
                   fi
                   ;;
                *) : ;;
            esac
        done

        if [ "${ready}" -eq 0 ] && [ "${done_count}" -eq "${want}" ]; then
            log "ERROR" "All ${want} RECONSTRUCT slot(s) completed before caught (too fast)"
            return 1
        fi
        if [ "${ready}" -eq "${want}" ]; then
            log "INFO" "All RECONSTRUCT slot(s) [${slots}] appeared in show migrations -> CANCEL now"
            return 0
        fi
        if [ $(( $(date +%s) - begin_time )) -gt "${add_phase_wait_timeout}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}RECONSTRUCT did not appear in show migrations within ${add_phase_wait_timeout}s."
            log "ERROR" "RECONSTRUCT did not appear in show migrations in ${add_phase_wait_timeout}s"
            return 1
        fi
        sleep 0.5
    done
}

# =============================================================================
# 发现 REMOVE 底层触发的子 MIGRATE 目标(用于后续 snapshot 残留校验)。
# 扫描 show migrations 中同 regionId 的 MIGRATE 行, 取 ToNodeId 填入 migrate_dest_dn_id/ip。
# 若未出现 -> 留空, snapshot 校验跳过(不判失败)。
# =============================================================================
discover_child_migrate_target() {
    local slot=$1
    local rid="${mig_region_id[$slot]}"
    local mf
    mf=$(collect_migrations "${mig_slot_dialect[$slot]}" "child_migrate_${mig_slot_name[$slot]}")
    migrate_dest_dn_id[$slot]=""
    migrate_dest_dn_ip[$slot]=""
    local dest_dn
    dest_dn=$(awk -F'|' -v rid="${rid}" '
        function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
        /^\|/ {
            hasrid=0
            for (k=1;k<=NF;k++) if (trim($k)==rid) hasrid=1
            if (!hasrid) next
            op=trim($3); to_n=trim($5)
            if (op=="MIGRATE" && to_n ~ /^[0-9]+$/) print to_n
        }' "${mf}" | head -1)
    if [ -n "${dest_dn}" ]; then
        migrate_dest_dn_id[$slot]="${dest_dn}"
        local dest_ip
        dest_ip=$(awk -v id="${dest_dn}" '$1==id{print $2; exit}' "${run_artifact_dir}/running_datanodes.txt" 2>/dev/null || echo "")
        migrate_dest_dn_ip[$slot]="${dest_ip}"
        log "INFO" "[${mig_slot_name[$slot]}] discovered child MIGRATE dest dn=${dest_dn}(${dest_ip}) for region ${rid} -> snapshot check enabled"
    else
        log "INFO" "[${mig_slot_name[$slot]}] no child MIGRATE row for region ${rid} (not started / too fast / SchemaRegion) -> skip snapshot check"
    fi
}

# =============================================================================
# 断言 RECONSTRUCT 行的 OperationType=RECONSTRUCT、FromNodeId=ToNodeId=tgt
# =============================================================================
assert_reconstruct_fields() {
    local slots="$*" i
    for i in ${slots}; do
        [ -z "${mig_region_id[$i]}" ] && continue
        local mf
        mf=$(collect_migrations "${mig_slot_dialect[$i]}" "assert_reconstruct_${mig_slot_name[$i]}")
        if grep -Eq "Exception|ERROR|Error" "${mf}"; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}[${mig_slot_name[$i]}] show migrations failed while asserting RECONSTRUCT fields."
            continue
        fi
        if awk -F'|' -v rid="${mig_region_id[$i]}" -v tgt="${mig_tgt_dn_id[$i]}" '
            function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
            /^\|/ {
                hasrid=0; tgt_count=0
                for (k=1;k<=NF;k++) { if (trim($k)==rid) hasrid=1; if (trim($k)==tgt) tgt_count++ }
                if (hasrid && $0 ~ /RECONSTRUCT/ && tgt_count>=2) ok=1
            }
            END { exit(ok?0:1) }' "${mf}"; then
            log "INFO" "[${mig_slot_name[$i]}] confirmed RECONSTRUCT FromNodeId=ToNodeId=${mig_tgt_dn_id[$i]} for region ${mig_region_id[$i]}"
        else
            let fail_flag++
            v_warnMessage="${v_warnMessage}[${mig_slot_name[$i]}] region ${mig_region_id[$i]} RECONSTRUCT row does not have FromNodeId=ToNodeId=${mig_tgt_dn_id[$i]}."
            log "ERROR" "[${mig_slot_name[$i]}] expected RECONSTRUCT FromNodeId=ToNodeId=${mig_tgt_dn_id[$i]}"
        fi
    done
}

# =============================================================================
# 触发 RECONSTRUCT -> 看到顶层行立即 CANCEL -> 收敛 -> 结果与 snapshot 校验
# 用法: run_reconstruct_then_cancel <label> <slot...>
#   RECONSTRUCT 语法: `reconstruct region <regionId> on <tgt>`
# =============================================================================
run_reconstruct_then_cancel() {
    local label="$1"; shift
    local slots="$*"
    local i
    # 1) 后台并发触发 RECONSTRUCT
    for i in ${slots}; do
        [ -z "${mig_region_id[$i]}" ] && continue
        local mig_out="${run_artifact_dir}/migrate_cmd_${mig_slot_name[$i]}.out"
        log "INFO" "Trigger[${label}/${mig_slot_name[$i]}]: reconstruct region ${mig_region_id[$i]} on ${mig_tgt_dn_id[$i]} (dialect=${mig_slot_dialect[$i]})"
        ( ${cli_dir}/sbin/start-cli.sh -u root ${ssl_str} -h "${query_ip}" -timeout 36000 -sql_dialect "${mig_slot_dialect[$i]}" \
            -e "reconstruct region ${mig_region_id[$i]} on ${mig_tgt_dn_id[$i]};" > "${mig_out}" 2>&1 ) &
        mig_cmd_pid[$i]=$!
    done

    # 2) 等待 RECONSTRUCT 行出现在 show migrations(看到即 CANCEL)
    if ! wait_reconstruct_in_cancellable_state ${slots}; then
        for i in ${slots}; do [ -n "${mig_cmd_pid[$i]}" ] && wait "${mig_cmd_pid[$i]}" 2>/dev/null || true; done
        return 1
    fi

    # 2.5) 断言顶层字段；RECONSTRUCT 的 snapshot 接收端就是 tgt
    assert_reconstruct_fields ${slots}
    for i in ${slots}; do
        [ -z "${mig_region_id[$i]}" ] && continue
        migrate_dest_dn_id[$i]="${mig_tgt_dn_id[$i]}"
        migrate_dest_dn_ip[$i]="${mig_tgt_dn_ip[$i]}"
    done

    # 3) 只执行一次 CANCEL ALL MIGRATIONS
    local cancel_out="${run_artifact_dir}/cancel_all_migrations_${label}.out"
    local t0 t1 batch_return batch_converge
    t0=$(date +%s%3N 2>/dev/null || date +%s000)
    cli_tree "${query_ip}" "CANCEL ALL MIGRATIONS;" > "${cancel_out}" 2>&1
    t1=$(date +%s%3N 2>/dev/null || date +%s000)
    batch_return=$(( (t1 - t0) / 1000 ))
    cancel_elapsed_seconds=${batch_return}
    trim_file_crlf "${cancel_out}"
    log "INFO" "[${label}] CANCEL ALL MIGRATIONS returned in ${batch_return}s (ms=$((t1-t0)))"
    cat "${cancel_out}" >> "${log_file}"

    if ! grep -q "The statement is executed successfully." "${cancel_out}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}[${label}] CANCEL ALL MIGRATIONS did not return success msg."
        log "ERROR" "[${label}] CANCEL ALL MIGRATIONS did not return the expected success message"
    fi
    if [ "$((t1-t0))" -gt 10000 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}[${label}] CANCEL ALL MIGRATIONS not responsive (>${batch_return}s)."
    fi

    # 4) 收敛
    if ! wait_all_cancel_converged "${label}" ${slots}; then
        for i in ${slots}; do [ -n "${mig_cmd_pid[$i]}" ] && wait "${mig_cmd_pid[$i]}" 2>/dev/null || true; done
        cancel_batch_timings="${cancel_batch_timings}${label}:return=${batch_return}s,converge=NA."
        return 1
    fi
    batch_converge=${cancel_converge_seconds}
    for i in ${slots}; do [ -n "${mig_cmd_pid[$i]}" ] && wait "${mig_cmd_pid[$i]}" 2>/dev/null || true; done

    # 5) 校验成员集合、Running 状态和 tgt snapshot 清理
    for i in ${slots}; do
        [ -z "${mig_region_id[$i]}" ] && continue
        verify_reconstruct_result "${i}"
    done

    cancel_batch_timings="${cancel_batch_timings}${label}:return=${batch_return}s,converge=${batch_converge}s."
    return 0
}
# 判定本批取消完成: show migrations 全空 且本批各 region 均无 Adding/Removing
# 用法: wait_all_cancel_converged <label> <slot...>
wait_all_cancel_converged() {
    local label="$1"; shift
    local slots="$*"
    local begin_time
    begin_time=$(date +%s)
    while true; do
        local elapsed
        elapsed=$(( $(date +%s) - begin_time ))
        # 用树方言取 show migrations(全局同源,树/表都能看到全部迁移)
        local mig_file
        mig_file=$(collect_migrations "tree" "after_cancel_${label}")
        if grep -Eq "Exception|ERROR|Error" "${mig_file}"; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}[${label}] show migrations failed after cancel."
            return 1
        fi
        local mig_empty=0
        grep -Eq '^Empty set' "${mig_file}" && mig_empty=1

        # 本批各 region 是否都没有 Adding/Removing(分别查各自方言的 show regions)
        local any_active=0 i
        for i in ${slots}; do
            [ -z "${mig_region_id[$i]}" ] && continue
            collect_regions "${mig_slot_dialect[$i]}" "after_cancel_${label}_${mig_slot_name[$i]}"
            local reg_file="${run_artifact_dir}/after_cancel_${label}_${mig_slot_name[$i]}_${mig_slot_dialect[$i]}_regions.out"
            if awk -F'|' -v rid="${mig_region_id[$i]}" '
                function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
                /^\|/ { if (trim($2)==rid && (trim($4)=="Adding"||trim($4)=="Removing")) busy=1 }
                END{ exit(busy?0:1) }' "${reg_file}"; then
                any_active=1
            fi
        done

        if [ "${mig_empty}" -eq 1 ] && [ "${any_active}" -eq 0 ]; then
            cancel_converge_seconds=${elapsed}
            log "INFO" "[${label}] cancels converged in ${elapsed}s: show migrations empty & no Adding/Removing for regions [${slots}]"
            return 0
        fi

        if [ "${elapsed}" -gt "${cancel_converge_timeout}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}[${label}] cancel not converged within ${cancel_converge_timeout}s (mig_empty=${mig_empty},any_active=${any_active})."
            log "ERROR" "[${label}] cancel not converged within ${cancel_converge_timeout}s"
            return 1
        fi
        sleep 5
    done
}

# 校验某个 slot 回滚: 目标节点 tgt 不保留新副本 & 源副本集合==迁移前 & 无 Adding/Removing 残留

# 校验 REMOVE 回滚: tgt 副本被保留 + 状态 Running + 副本集合==baseline。
# 与 MIGRATE/EXTEND 相反: tgt 必须在成员中, 否则失败。
verify_reconstruct_result() {
    local slot=$1
    local name="${mig_slot_name[$slot]}" dialect="${mig_slot_dialect[$slot]}"
    local rid="${mig_region_id[$slot]}" tgt="${mig_tgt_dn_id[$slot]}" base="${mig_baseline_dn_ids[$slot]}"
    refresh_running_datanodes
    collect_regions "${dialect}" "verify_rollback_${name}"
    local reg_file="${run_artifact_dir}/verify_rollback_${name}_${dialect}_regions.out"

    local now_members
    now_members=$(awk -F'|' -v rid="${rid}" '
        function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
        /^\|/ { if (trim($2)==rid) print trim($8) }' "${reg_file}" | sort -n | tr '\n' ' ' | sed 's/ *$//')

    log "INFO" "[${name}] region ${rid} members after cancel = [${now_members}]; baseline = [${base}]"

    # 两种合法时序最终都必须恢复完整副本集合：
    # A) 删除旧副本前取消生效，旧副本保留；B) 删除后取消被忽略，新副本重建完成。
    if [ "${now_members}" != "${base}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}[${name}] RECONSTRUCT result replica set changed (now=[${now_members}] vs baseline=[${base}])."
        log "ERROR" "[${name}] RECONSTRUCT result replica set differs from baseline"
    fi
    if ! echo " ${now_members} " | grep -q " ${tgt} "; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}[${name}] RECONSTRUCT target ${tgt} is absent after cancel convergence."
        log "ERROR" "[${name}] RECONSTRUCT target ${tgt} is absent after convergence"
    fi
    if ! awk -F'|' -v rid="${rid}" -v tgt="${tgt}" '
        function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
        /^\|/ { if (trim($2)==rid && trim($8)==tgt && trim($4)=="Running") running=1 }
        END{ exit(running?0:1) }' "${reg_file}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}[${name}] region ${rid} on reconstruct target ${tgt} is not Running."
        log "ERROR" "[${name}] region ${rid} on target ${tgt} is not Running"
    fi

    # 通用: 无 Adding/Removing 残留
    if awk -F'|' -v rid="${rid}" '
        function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
        /^\|/ { if (trim($2)==rid && (trim($4)=="Adding"||trim($4)=="Removing")) busy=1 }
        END{ exit(busy?0:1) }' "${reg_file}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}[${name}] region ${rid} still has Adding/Removing after cancel converged."
    fi

    verify_receiver_snapshot_deleted "${slot}"
}

# =============================================================================
# REMOVE 成功完成(分支B)后检查 tgt 上该 region 数据是否被清理。
# REMOVE 成功后 tgt 的 data_dirs 下不应再有该 region 的目录。
# =============================================================================
verify_remove_data_cleaned() {
    local slot=$1
    local name="${mig_slot_name[$slot]}" rid="${mig_region_id[$slot]}"
    local tgt="${mig_tgt_dn_id[$slot]}" tgt_ip="${mig_tgt_dn_ip[$slot]}"

    if [ -z "${tgt_ip}" ] || [ -z "${rid}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}[${name}] missing tgt ip or region id for data-cleanup check."
        return 1
    fi

    local leftover_file="${run_artifact_dir}/remove_data_leftover_${name}_dn${tgt}_r${rid}.out"
    # 精确匹配 region 数据目录: 目录名恰好是 rid(如 "9") 或路径含 DataRegion-9 / dataregion-9。
    # 避免 `-name "*9*"` 这种模糊匹配把时间戳/UUID/日志备份名里的数字 9 当成假阳性。
    ssh -n "${os_user_name}@${tgt_ip}" "timeout 30 bash -c '
        if [ ! -d \"${db_dir}\" ]; then exit 0; fi
        find \"${db_dir}\" -xdev -type d \\( -name \"${rid}\" -o -path \"*DataRegion-${rid}\" -o -path \"*dataregion-${rid}\" -o -path \"*DataRegion-${rid}/*\" -o -path \"*dataregion-${rid}/*\" \\) -print 2>/dev/null
    '" > "${leftover_file}" 2>/dev/null

    if [ -s "${leftover_file}" ]; then
        log "WARN" "[${name}] tgt ${tgt}(${tgt_ip}) still has data dirs for removed region ${rid} (may still be cleaning up):"
        cat "${leftover_file}" >> "${log_file}"
        # 等待 60s 后再查一次(清理是异步的)
        sleep 60
        ssh -n "${os_user_name}@${tgt_ip}" "timeout 30 bash -c '
            if [ ! -d \"${db_dir}\" ]; then exit 0; fi
            find \"${db_dir}\" -xdev -type d \\( -name \"${rid}\" -o -path \"*DataRegion-${rid}\" -o -path \"*dataregion-${rid}\" -o -path \"*DataRegion-${rid}/*\" -o -path \"*dataregion-${rid}/*\" \\) -print 2>/dev/null | wc -l
        '" > "${leftover_file}.retry" 2>/dev/null
        local retry_count
        retry_count=$(cat "${leftover_file}.retry" 2>/dev/null | tr -d ' ')
        if [ -n "${retry_count}" ] && [ "${retry_count}" -gt 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}[${name}] tgt ${tgt} data cleanup FAILED: ${retry_count} dirs still remain for removed region ${rid}."
            log "ERROR" "[${name}] tgt ${tgt}(${tgt_ip}) still has ${retry_count} data dirs for removed region ${rid} after 60s wait"
        else
            log "INFO" "[${name}] tgt ${tgt}(${tgt_ip}) data for removed region ${rid} cleaned up (0 dirs after retry)"
        fi
    else
        log "INFO" "[${name}] tgt ${tgt}(${tgt_ip}) data for removed region ${rid} is already cleaned up"
    fi
}


# 校验取消后接收端 snapshot 已清理。
# REMOVE: snapshot 校验目标为子 MIGRATE 的接收端(migrate_dest_dn), 非 REMOVE 的移除目标(mig_tgt_dn)。
# 若子 MIGRATE 未出现(migrate_dest_dn_id 空), 跳过 snapshot 校验(不判失败)。
verify_receiver_snapshot_deleted() {
    local slot=$1
    local name="${mig_slot_name[$slot]}" rid="${mig_region_id[$slot]}"
    local tgt="${mig_tgt_dn_id[$slot]}" tgt_ip="${mig_tgt_dn_ip[$slot]}"
    # 如果发现了子 MIGRATE 目标, 用它覆盖 snapshot 校验目标; 否则跳过。
    if [ -n "${migrate_dest_dn_id[$slot]}" ]; then
        tgt="${migrate_dest_dn_id[$slot]}"
        tgt_ip="${migrate_dest_dn_ip[$slot]}"
    else
        log "INFO" "[${name}] no child MIGRATE dest for region ${rid} -> skipping receiver snapshot check"
        return 0
    fi
    local snapshot_file="${run_artifact_dir}/receiver_snapshot_leftover_${name}_dn${tgt}_r${rid}.out"

    if [ -z "${tgt_ip}" ] || [ -z "${rid}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}[${name}] missing target ip or region id for receiver snapshot check."
        log "ERROR" "[${name}] missing target ip or region id for receiver snapshot check"
        return 1
    fi

    local begin_time elapsed rc last_signature="" signature="" last_progress_time
    begin_time=$(date +%s)
    last_progress_time=${begin_time}
    while true; do
        : > "${snapshot_file}"
        ssh -n "${os_user_name}@${tgt_ip}" "timeout 120 bash -c '
            if [ ! -d \"${db_dir}\" ]; then
                exit 0
            fi
            match_file=\$(mktemp /tmp/cam_snapshot_match.XXXXXX)
            find \"${db_dir}\" -xdev \
                \\( -iname \"*snapshot*\" -o -path \"*/snapshot/*\" -o -path \"*/snapshot\" \\) \
                -print 2>/dev/null | awk -v rid=\"${rid}\" '\\''
                function match_region(path, a, i, n) {
                    n=split(path, a, \"/\")
                    for (i=1; i<=n; i++) {
                        if (a[i] == rid || a[i] == \"DataRegion-\" rid || a[i] == \"dataregion-\" rid ||
                            a[i] ~ (\"^\" rid \"[_-]\") || a[i] ~ (\"[_-]\" rid \"$\") ||
                            a[i] ~ (\"^DataRegion[_-]\" rid \"$\") || a[i] ~ (\"^dataregion[_-]\" rid \"$\"))
                            return 1
                    }
                    return 0
                }
                match_region(\$0) { print; hit=1 }
                END { exit(hit ? 1 : 0) }
            '\\'' > \"\${match_file}\"
            if [ ! -s \"\${match_file}\" ]; then
                rm -f \"\${match_file}\"
                exit 0
            fi
            total_size=0
            max_mtime=0
            while IFS= read -r p; do
                [ -e \"\${p}\" ] || continue
                s=\$(du -sb \"\${p}\" 2>/dev/null | awk '\\''{print \$1}'\\'')
                m=\$(stat -c %Y \"\${p}\" 2>/dev/null || echo 0)
                total_size=\$((total_size + \${s:-0}))
                [ \"\${m:-0}\" -gt \"\${max_mtime}\" ] && max_mtime=\${m}
            done < \"\${match_file}\"
            count=\$(wc -l < \"\${match_file}\")
            echo \"__SNAPSHOT_STAT__ count=\${count} size=\${total_size} max_mtime=\${max_mtime}\"
            cat \"\${match_file}\"
            rm -f \"\${match_file}\"
        '" > "${snapshot_file}" 2>>"${log_file}"
        rc=$?
        elapsed=$(( $(date +%s) - begin_time ))

        if [ "${rc}" -eq 124 ]; then
            log "WARN" "[${name}] receiver snapshot scan timed out once on target dn ${tgt}(${tgt_ip}), elapsed=${elapsed}s"
        elif [ ! -s "${snapshot_file}" ]; then
            log "INFO" "[${name}] receiver target dn ${tgt}(${tgt_ip}) has no snapshot leftover for region ${rid} after cancel"
            return 0
        else
            signature=$(grep '^__SNAPSHOT_STAT__' "${snapshot_file}" | tail -1)
            if [ -n "${signature}" ] && [ "${signature}" != "${last_signature}" ]; then
                last_signature="${signature}"
                last_progress_time=$(date +%s)
                log "INFO" "[${name}] receiver snapshot cleanup is progressing on target dn ${tgt}(${tgt_ip}) for region ${rid}: ${signature}, elapsed=${elapsed}s"
            else
                local no_progress_elapsed
                no_progress_elapsed=$(( $(date +%s) - last_progress_time ))
                log "INFO" "[${name}] receiver snapshot leftover is not changing yet on target dn ${tgt}(${tgt_ip}) for region ${rid}: ${signature}, no_progress=${no_progress_elapsed}s, elapsed=${elapsed}s"
                if [ "${no_progress_elapsed}" -gt "${snapshot_cleanup_no_progress_timeout}" ]; then
                    let fail_flag++
                    v_warnMessage="${v_warnMessage}[${name}] receiver target dn ${tgt} snapshot leftover for region ${rid} made no cleanup progress within ${snapshot_cleanup_no_progress_timeout}s."
                    log "ERROR" "[${name}] receiver target dn ${tgt}(${tgt_ip}) snapshot leftover for region ${rid} made no cleanup progress within ${snapshot_cleanup_no_progress_timeout}s"
                    cat "${snapshot_file}" >> "${log_file}"
                    return 1
                fi
            fi
        fi

        if [ "${elapsed}" -gt "${snapshot_cleanup_timeout}" ]; then
            break
        fi
        sleep "${snapshot_cleanup_check_interval}"
    done

    if [ "${rc}" -eq 124 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}[${name}] receiver snapshot cleanup check timed out on target dn ${tgt}."
        log "ERROR" "[${name}] receiver snapshot cleanup check timed out on target dn ${tgt}(${tgt_ip}) after ${snapshot_cleanup_timeout}s"
        return 1
    fi

    if [ -s "${snapshot_file}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}[${name}] receiver target dn ${tgt} has snapshot leftover for region ${rid} after cancel cleanup timeout."
        log "ERROR" "[${name}] receiver target dn ${tgt}(${tgt_ip}) has snapshot leftover for region ${rid} after waiting ${snapshot_cleanup_timeout}s"
        cat "${snapshot_file}" >> "${log_file}"
        return 1
    fi
}

# 断言5: ConfigNode 日志出现 cancel 相关标记
check_cancel_logs() {
    local hit_total=0 node_ip
    while read -r node_ip; do
        [ -z "${node_ip}" ] && continue
        ssh -n "${os_user_name}@${node_ip}" "gunzip ${cn_db_dir}/logs/*confignode*all* >/dev/null 2>&1 || true"
        local h
        h=$(ssh -n "${os_user_name}@${node_ip}" "grep -E 'CancelMigrations|cancel signal sent|cancelled at state|Successfully signalled .* migration|ReconstructRegion' ${cn_db_dir}/logs/*confignode*all* 2>/dev/null | wc -l")
        h=${h:-0}
        log "INFO" "ConfigNode ${node_ip} cancel-related log lines: ${h}"
        hit_total=$((hit_total + h))
        # 存证
        ssh -n "${os_user_name}@${node_ip}" "grep -E 'CancelMigrations|cancel signal sent|cancelled at state|Successfully signalled .* migration|ReconstructRegion|RemoveRegionPeer|AddRegionPeer' ${cn_db_dir}/logs/*confignode*all* 2>/dev/null" \
            >> "${run_artifact_dir}/confignode_cancel_log_${node_ip}.out" 2>/dev/null || true
    done < "${nodeinfo_dir}/confignode.txt"

    if [ "${hit_total}" -le 0 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}no cancel-related marker found in any ConfigNode log."
        log "ERROR" "no cancel-related marker found in ConfigNode logs"
    fi
}

# =============================================================================
# benchmark: 树(无object) + 表(可写视图+object) + 写当前时间, 运行约 20 分钟
# =============================================================================
create_benchmark_users() {
    ${cli_dir}/sbin/start-cli.sh -h "${query_ip}" -u root -e "CREATE USER santos 'TimechoDB@2021';" > "${run_artifact_dir}/create_santos.out"
    if grep -q "already exists" "${run_artifact_dir}/create_santos.out"; then
        log "INFO" "user santos already exists"
    else
        check_cli_success "${run_artifact_dir}/create_santos.out" "create user santos" || return 1
    fi
    ${cli_dir}/sbin/start-cli.sh -h "${query_ip}" -u root -e "GRANT ALL ON root.** TO USER santos;" > "${run_artifact_dir}/grant_santos.out"
    check_cli_success "${run_artifact_dir}/grant_santos.out" "grant santos" || return 1

    ${cli_dir}/sbin/start-cli.sh -h "${query_ip}" -u root -sql_dialect table -e "CREATE USER rainer 'TimechoDB@2021';" > "${run_artifact_dir}/create_rainer.out"
    if grep -q "already exists" "${run_artifact_dir}/create_rainer.out"; then
        log "INFO" "user rainer already exists"
    else
        check_cli_success "${run_artifact_dir}/create_rainer.out" "create user rainer" || return 1
    fi
    ${cli_dir}/sbin/start-cli.sh -h "${query_ip}" -u root -sql_dialect table -e "GRANT ALL TO USER rainer;" > "${run_artifact_dir}/grant_rainer.out"
    check_cli_success "${run_artifact_dir}/grant_rainer.out" "grant rainer" || return 1
}

check_benchmark_assets() {
    if [ ! -x "${bm_runner}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}benchmark runner missing."
        log "ERROR" "benchmark runner not found: ${bm_runner}"
        return 1
    fi
    local conf
    for conf in "${bm_tree_conf}/config.properties" "${bm_table_conf}/config.properties" "${bm_table_plain_conf}/config.properties"; do
        if [ ! -f "${conf}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}benchmark config missing."
            log "ERROR" "benchmark config not found: ${conf}"
            return 1
        fi
    done
    return 0
}

# 断言 benchmark 含查询: OPERATION_PROPORTION 第1位是写(INGESTION)，其余为各类查询;
# 只要存在任一非零的查询位(第2位起)，即认为 benchmark 有查询负载。
assert_benchmark_has_query() {
    local file=$1 desc=$2
    local prop
    prop=$(grep -E '^OPERATION_PROPORTION=' "${file}" | tail -1 | awk -F '=' '{print $2}' | tr -d '[:space:]')
    if [ -z "${prop}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${desc} OPERATION_PROPORTION missing (no query)."
        log "ERROR" "${desc} OPERATION_PROPORTION missing"
        return 1
    fi
    # 去掉第1位(写)后，剩余是否有非零查询位
    local query_part
    query_part=$(echo "${prop}" | cut -d: -f2-)
    if echo "${query_part}" | grep -Eq '(^|:)[1-9][0-9]*(:|$)'; then
        log "INFO" "${desc} benchmark has query: OPERATION_PROPORTION=${prop}"
        return 0
    fi
    let fail_flag++
    v_warnMessage="${v_warnMessage}${desc} OPERATION_PROPORTION has no query field (write-only): ${prop}."
    log "ERROR" "${desc} OPERATION_PROPORTION has no query field: ${prop}"
    return 1
}

prepare_benchmark_configs() {
    # START_TIME = 测试开始时间(main 捕获的 test_start_iso)，格式 ISO-8601 带时区。
    # 若未捕获(异常路径)则退回当前时间。
    local start_time="${test_start_iso}"
    if [ -z "${start_time}" ]; then
        start_time=$(date +"%Y-%m-%dT%H:%M:%S%:z")
    fi
    local tree_conf="${bm_tree_conf}/config.properties"
    local table_conf="${bm_table_conf}/config.properties"
    local table_plain_conf="${bm_table_plain_conf}/config.properties"

    set_bm() {
        local file=$1 key=$2 value=$3
        if grep -q "^${key}=" "${file}"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
        else
            echo "${key}=${value}" >> "${file}"
        fi
    }

    # tree: root.test.g_0, 无 object(proportion 末位=0);
    #       写入时间=真实当前系统时间(IS_RECORD_CURRENT_REALLY_TIME=true); START_TIME=测试开始时间;
    #       OPERATION_PROPORTION 保持种子配置(写多查少，含查询)，此处不覆盖。
    set_bm "${tree_conf}" HOST "${benchmark_hosts}"
    set_bm "${tree_conf}" PORT "${benchmark_ports}"
    set_bm "${tree_conf}" USERNAME "santos"
    set_bm "${tree_conf}" PASSWORD "TimechoDB@2021"
    set_bm "${tree_conf}" DB_NAME "test"
    set_bm "${tree_conf}" SENSOR_NUMBER "${tree_sensor_number}"
    set_bm "${tree_conf}" SCHEMA_CLIENT_NUMBER "10"
    set_bm "${tree_conf}" LOOP "${bm_loop}"
    set_bm "${tree_conf}" TEST_MAX_TIME "${bm_test_max_time_ms}"
    set_bm "${tree_conf}" IS_DELETE_DATA "false"
    set_bm "${tree_conf}" IS_RECORD_CURRENT_REALLY_TIME "true"
    set_bm "${tree_conf}" START_TIME "${start_time}"

    # table: 可写视图 usr_sod0.writable_view_0, 含 object(proportion 末位=1), object 每点 1 文件 -> 控制体量;
    #        写入时间=真实当前系统时间; START_TIME=测试开始时间; OPERATION_PROPORTION 保持种子配置(含查询)。
    set_bm "${table_conf}" HOST "${benchmark_hosts}"
    set_bm "${table_conf}" PORT "${benchmark_ports}"
    set_bm "${table_conf}" USERNAME "rainer"
    set_bm "${table_conf}" PASSWORD "TimechoDB@2021"
    set_bm "${table_conf}" DB_NAME "usr"
    set_bm "${table_conf}" LOOP "${bm_loop}"
    set_bm "${table_conf}" TEST_MAX_TIME "${bm_test_max_time_ms}"
    set_bm "${table_conf}" IS_DELETE_DATA "false"
    set_bm "${table_conf}" IS_RECORD_CURRENT_REALLY_TIME "true"
    set_bm "${table_conf}" IoTDB_TABLE_WRITABLE_VIEW "true"
    set_bm "${table_conf}" START_TIME "${start_time}"

    # 普通表(非视图): usr_nrm0.normal_table_0, 无 object(proportion 末位=0, 静态配置已设);
    #        写入时间=真实当前系统时间; START_TIME=测试开始时间; OPERATION_PROPORTION 保持种子配置(含查询)。
    set_bm "${table_plain_conf}" HOST "${benchmark_hosts}"
    set_bm "${table_plain_conf}" PORT "${benchmark_ports}"
    set_bm "${table_plain_conf}" USERNAME "rainer"
    set_bm "${table_plain_conf}" PASSWORD "TimechoDB@2021"
    set_bm "${table_plain_conf}" DB_NAME "usr"
    set_bm "${table_plain_conf}" LOOP "${bm_loop}"
    set_bm "${table_plain_conf}" TEST_MAX_TIME "${bm_test_max_time_ms}"
    set_bm "${table_plain_conf}" IS_DELETE_DATA "false"
    set_bm "${table_plain_conf}" IS_RECORD_CURRENT_REALLY_TIME "true"
    set_bm "${table_plain_conf}" IoTDB_TABLE_WRITABLE_VIEW "false"
    set_bm "${table_plain_conf}" START_TIME "${start_time}"

    log "INFO" "benchmark START_TIME set to test start time: ${start_time}"
    # 确认三个 benchmark 均含查询负载
    assert_benchmark_has_query "${tree_conf}" "tree" || true
    assert_benchmark_has_query "${table_conf}" "table(writable_view)" || true
    assert_benchmark_has_query "${table_plain_conf}" "table(plain)" || true

    {
        echo "=== ${tree_conf} (key params) ==="
        grep -E '^(HOST|PORT|USERNAME|DB_NAME|LOOP|TEST_MAX_TIME|START_TIME|IS_RECORD_CURRENT_REALLY_TIME|IoTDB_DIALECT_MODE|GROUP_NAME_PREFIX|GROUP_NUMBER|INSERT_DATATYPE_PROPORTION|OBJECT_LENGTH|OPERATION_PROPORTION|QUERY_SENSOR_NUM|QUERY_DEVICE_NUM|QUERY_INTERVAL)=' "${tree_conf}" || true
        echo "=== ${table_conf} (key params) ==="
        grep -E '^(HOST|PORT|USERNAME|DB_NAME|LOOP|TEST_MAX_TIME|START_TIME|IS_RECORD_CURRENT_REALLY_TIME|IoTDB_DIALECT_MODE|IoTDB_TABLE_WRITABLE_VIEW|IoTDB_TABLE_NAME_PREFIX|GROUP_NAME_PREFIX|INSERT_DATATYPE_PROPORTION|OBJECT_LENGTH|OPERATION_PROPORTION|QUERY_SENSOR_NUM|QUERY_DEVICE_NUM|QUERY_INTERVAL)=' "${table_conf}" || true
        echo "=== ${table_plain_conf} (key params) ==="
        grep -E '^(HOST|PORT|USERNAME|DB_NAME|LOOP|TEST_MAX_TIME|START_TIME|IS_RECORD_CURRENT_REALLY_TIME|IoTDB_DIALECT_MODE|IoTDB_TABLE_WRITABLE_VIEW|IoTDB_TABLE_NAME_PREFIX|GROUP_NAME_PREFIX|INSERT_DATATYPE_PROPORTION|OBJECT_LENGTH|OPERATION_PROPORTION|QUERY_SENSOR_NUM|QUERY_DEVICE_NUM|QUERY_INTERVAL)=' "${table_plain_conf}" || true
    } >> "${log_file}"
}

start_benchmark() {
    check_benchmark_assets || return 1
    prepare_benchmark_configs
    local bm_log_dir="${bm_base_dir}/${testdb}"
    mkdir -p "${bm_log_dir}"
    local now
    now=$(date +%Y%m%d_%H%M%S)
    timeout --preserve-status "${bm_guard_seconds}s" "${bm_runner}" -cf "${bm_tree_conf}" > "${bm_log_dir}/${now}_conf_tree.out" 2>&1 &
    bm_pids+=($!)
    timeout --preserve-status "${bm_guard_seconds}s" "${bm_runner}" -cf "${bm_table_conf}" > "${bm_log_dir}/${now}_conf_table.out" 2>&1 &
    bm_pids+=($!)
    timeout --preserve-status "${bm_guard_seconds}s" "${bm_runner}" -cf "${bm_table_plain_conf}" > "${bm_log_dir}/${now}_conf_table_plain.out" 2>&1 &
    bm_pids+=($!)
    bm_start_epoch=$(date +%s)
    log "INFO" "Started 3 benchmark processes (tree no-object + writable-view+object + plain-table no-object), target write ~${bm_write_seconds}s"

    # 早期健康检查: 20s 内进程不应全部退出，并记录存活个数(期望 3)
    sleep 20
    local alive
    alive=$(jps | awk '/ App$/ {print $1}' | wc -l)
    log "INFO" "benchmark App alive after 20s = ${alive} (expected 3)"
    if [ "${alive}" -le 0 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}benchmark processes exited early."
        log "ERROR" "benchmark processes exited early"
        return 1
    fi
    if [ "${alive}" -lt 3 ]; then
        v_warnMessage="${v_warnMessage}only ${alive}/3 benchmark processes alive after 20s."
        log "WARN" "only ${alive}/3 benchmark processes alive after 20s"
    fi
    return 0
}

wait_for_benchmark_finish() {
    local pid bm_failed=0
    for pid in "${bm_pids[@]}"; do
        if ! wait "${pid}"; then
            bm_failed=1
            log "ERROR" "benchmark pid ${pid} failed"
        fi
    done
    if [ "${bm_start_epoch}" -gt 0 ]; then
        bm_elapsed_seconds=$(( $(date +%s) - bm_start_epoch ))
    fi
    if [ "${bm_failed}" -ne 0 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}benchmark failed."
    fi
}

stop_benchmark_now() {
    # 取消验证完成后不必等满 20min，主动停 benchmark 收尾
    local apps
    apps=$(jps | awk '/ App$/ {print $1}')
    if [ -n "${apps}" ]; then
        kill -9 ${apps} >> "${log_file}" 2>&1 || true
        log "INFO" "benchmark App processes stopped"
    fi
    if [ "${bm_start_epoch}" -gt 0 ]; then
        bm_elapsed_seconds=$(( $(date +%s) - bm_start_epoch ))
    fi
    ${cli_dir}/sbin/start-cli.sh -h "${query_ip}" -u root -sql_dialect tree -e "flush;" >> "${log_file}" 2>&1 || true
    ${cli_dir}/sbin/start-cli.sh -h "${query_ip}" -u root -sql_dialect table -e "flush;" >> "${log_file}" 2>&1 || true
}

# =============================================================================
# 副本数据一致性: 所有节点在线基准 -> 逐个 stop 1 个 DN 与基准对比
# =============================================================================
build_count_expr() {
    local max_sensor=$1 result="" i=0
    while [ "${i}" -lt "${max_sensor}" ]; do
        [ -n "${result}" ] && result="${result},"
        result="${result}count(s_${i})"
        i=$((i + 1))
    done
    echo "${result}"
}

run_consistency_query() {
    local host=$1 dialect=$2 sql=$3 out_file=$4
    if [ "${dialect}" = "tree" ]; then
        cli_tree "${host}" "${sql}" > "${out_file}"
    else
        cli_table "${host}" "${sql}" > "${out_file}"
    fi
    trim_file_crlf "${out_file}"
    if grep -Eq "Exception|ERROR|Error" "${out_file}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}query on ${host} failed."
        cat "${out_file}" >> "${log_file}"
        return 1
    fi
    return 0
}

# 等待 IoTConsensus 副本同步延迟(syncLag)归零后再做一致性校验。
# 原因: benchmark 停写 + flush 后, DataRegion 副本(rep=2)之间仍可能有异步复制延迟;
#       若此时抓基准并停 1 个 DN, 存活副本可能尚未追平 -> 误报副本不一致。
# 实现: 中心 Prometheus(172.16.2.25) 不采集本集群 ClusterID2, 故直连各运行中 DN 的
#       :dn_metric_port/metrics 抓取 iot_consensus{type="syncLag"} 值, 等到所有 DN 全为 0
#       且连续稳定 N 次。注意: curl 不读 stdin, while read < file 循环安全。
wait_for_sync_lag_zero() {
    local timeout_seconds=${1:-600}
    local stable_needed=2
    local stable=0
    local begin_time
    begin_time=$(date +%s)
    log "INFO" "Waiting IoTConsensus syncLag to reach zero on all DataNodes (port ${dn_metric_port})"
    while true; do
        refresh_running_datanodes
        local total_nonzero=0 unreachable=0 checked=0 dn_id dn_ip body nz
        while read -r dn_id dn_ip; do
            [ -z "${dn_ip}" ] && continue
            checked=$((checked + 1))
            body=$(curl -s -m 10 "http://${dn_ip}:${dn_metric_port}/metrics" 2>/dev/null)
            if [ -z "${body}" ]; then
                unreachable=$((unreachable + 1))
                continue
            fi
            # 统计该 DN 上 syncLag 非零(>1e-6)的序列数
            nz=$(printf '%s\n' "${body}" | awk '/type="syncLag"/ { v=$NF+0; if (v>0.000001) c++ } END { print c+0 }')
            total_nonzero=$((total_nonzero + nz))
        done < "${run_artifact_dir}/running_datanodes.txt"

        local elapsed
        elapsed=$(( $(date +%s) - begin_time ))
        if [ "${checked}" -gt 0 ] && [ "${total_nonzero}" -eq 0 ] && [ "${unreachable}" -eq 0 ]; then
            stable=$((stable + 1))
            log "INFO" "syncLag all zero (${stable}/${stable_needed}) across ${checked} DN, elapsed=${elapsed}s"
            if [ "${stable}" -ge "${stable_needed}" ]; then
                log "INFO" "syncLag converged to zero, safe to run consistency check"
                return 0
            fi
        else
            stable=0
            log "INFO" "waiting syncLag: nonzero_series=${total_nonzero}, unreachable_dn=${unreachable}/${checked}, elapsed=${elapsed}s"
        fi

        if [ "${elapsed}" -gt "${timeout_seconds}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}syncLag not zero within ${timeout_seconds}s (nonzero=${total_nonzero},unreachable=${unreachable})."
            log "ERROR" "syncLag did not converge within ${timeout_seconds}s; consistency result may be unreliable"
            return 1
        fi
        sleep 5
    done
}

check_data_consistency() {
    local count_expr
    count_expr=$(build_count_expr 12)
    local tree_sql="select ${count_expr} from ${TREE_DB_PATH}.** align by device;"
    local table_sql="use ${TABLE_DB_NAME}; select device_id,${count_expr} from ${TABLE_NAME} group by device_id order by device_id;"
    # 普通表(第3个 benchmark): usr_nrm0.normal_table_0
    local table2_sql="use ${TABLE2_DB_NAME}; select device_id,${count_expr} from ${TABLE2_NAME} group by device_id order by device_id;"

    # 一致性校验前: 先等副本同步延迟归零(benchmark 已停写+flush), 否则会误报不一致
    wait_for_sync_lag_zero 600 || true

    refresh_running_datanodes
    cp -f "${run_artifact_dir}/running_datanodes.txt" "${run_artifact_dir}/baseline_running_datanodes.txt"

    # 基准: 所有节点在线时的查询结果(树 + 可写视图 + 普通表)
    local baseline_ip
    baseline_ip=$(awk 'NR==1 {print $2}' "${run_artifact_dir}/baseline_running_datanodes.txt")
    if [ -z "${baseline_ip}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}no alive query host for baseline."
        return 1
    fi
    run_consistency_query "${baseline_ip}" tree "${tree_sql}" "${run_artifact_dir}/baseline_tree.out" || return 1
    run_consistency_query "${baseline_ip}" table "${table_sql}" "${run_artifact_dir}/baseline_table.out" || return 1
    run_consistency_query "${baseline_ip}" table "${table2_sql}" "${run_artifact_dir}/baseline_table2.out" || return 1
    normalize_query_result "${run_artifact_dir}/baseline_tree.out" "${run_artifact_dir}/baseline_tree.normalized.out"
    normalize_query_result "${run_artifact_dir}/baseline_table.out" "${run_artifact_dir}/baseline_table.normalized.out"
    normalize_query_result "${run_artifact_dir}/baseline_table2.out" "${run_artifact_dir}/baseline_table2.normalized.out"
    log "INFO" "Consistency baseline captured from ${baseline_ip} (tree + writable-view + plain-table)"

    # 先把基准 DN 列表整体读入数组，再用 for 遍历。
    # 关键: 循环体内会调用 ssh(stop/start/wait DataNode)，若用 `while read < 文件` 边读边 stop，
    # 循环里的 ssh 会吞掉该文件描述符上剩余的行，导致"逐个 stop 1 个 DN"只覆盖第 1 个节点。
    # 用数组遍历(循环体不再从同一 fd read) + 各 ssh 加 -n(不读 stdin) 双保险，确保 5 个 DN 全覆盖。
    local dn_entries=()
    while read -r dn_id dn_ip; do
        [ -z "${dn_ip}" ] && continue
        dn_entries+=("${dn_id} ${dn_ip}")
    done < "${run_artifact_dir}/baseline_running_datanodes.txt"

    if [ "${#dn_entries[@]}" -eq 0 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}baseline datanode list is empty for consistency check."
        return 1
    fi
    log "INFO" "Consistency check will iterate ${#dn_entries[@]} DataNodes: ${dn_entries[*]}"

    # 逐个 stop 1 个 DN，从其它在线节点查询，与基准 diff
    local entry dn_id dn_ip
    for entry in "${dn_entries[@]}"; do
        dn_id=$(echo "${entry}" | awk '{print $1}')
        dn_ip=$(echo "${entry}" | awk '{print $2}')
        [ -z "${dn_ip}" ] && continue

        # 从数组里挑一个不同于当前被停节点的查询主机
        local query_host="" other_entry other_ip
        for other_entry in "${dn_entries[@]}"; do
            other_ip=$(echo "${other_entry}" | awk '{print $2}')
            [ -z "${other_ip}" ] && continue
            if [ "${other_ip}" != "${dn_ip}" ]; then query_host="${other_ip}"; break; fi
        done
        if [ -z "${query_host}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}no alive query host after stopping ${dn_ip}."
            continue
        fi

        log "INFO" "Stop DN ${dn_ip}, query from ${query_host} and diff vs baseline"
        if ! stop_one_datanode "${dn_ip}"; then
            start_one_datanode "${dn_ip}"
            continue
        fi

        if ! run_consistency_query "${query_host}" tree "${tree_sql}" "${run_artifact_dir}/stop_${dn_ip}_tree.out"; then
            start_one_datanode "${dn_ip}"; continue
        fi
        if ! run_consistency_query "${query_host}" table "${table_sql}" "${run_artifact_dir}/stop_${dn_ip}_table.out"; then
            start_one_datanode "${dn_ip}"; continue
        fi
        if ! run_consistency_query "${query_host}" table "${table2_sql}" "${run_artifact_dir}/stop_${dn_ip}_table2.out"; then
            start_one_datanode "${dn_ip}"; continue
        fi
        normalize_query_result "${run_artifact_dir}/stop_${dn_ip}_tree.out" "${run_artifact_dir}/stop_${dn_ip}_tree.normalized.out"
        normalize_query_result "${run_artifact_dir}/stop_${dn_ip}_table.out" "${run_artifact_dir}/stop_${dn_ip}_table.normalized.out"
        normalize_query_result "${run_artifact_dir}/stop_${dn_ip}_table2.out" "${run_artifact_dir}/stop_${dn_ip}_table2.normalized.out"

        if ! diff -u "${run_artifact_dir}/baseline_tree.normalized.out" "${run_artifact_dir}/stop_${dn_ip}_tree.normalized.out" >> "${log_file}" 2>&1; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}tree replica inconsistent when ${dn_ip} down."
            log "ERROR" "tree replica inconsistent when ${dn_ip} down"
        fi
        if ! diff -u "${run_artifact_dir}/baseline_table.normalized.out" "${run_artifact_dir}/stop_${dn_ip}_table.normalized.out" >> "${log_file}" 2>&1; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}writable-view replica inconsistent when ${dn_ip} down."
            log "ERROR" "writable-view replica inconsistent when ${dn_ip} down"
        fi
        if ! diff -u "${run_artifact_dir}/baseline_table2.normalized.out" "${run_artifact_dir}/stop_${dn_ip}_table2.normalized.out" >> "${log_file}" 2>&1; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}plain-table replica inconsistent when ${dn_ip} down."
            log "ERROR" "plain-table replica inconsistent when ${dn_ip} down"
        fi

        log "INFO" "Restart DN ${dn_ip} after consistency check"
        start_one_datanode "${dn_ip}"
    done
}

# =============================================================================
# 日志检查 / 备份
# =============================================================================
check_log() {
    exec 3<"${nodeinfo_dir}/confignode.txt"
    while read -r line <&3; do
        ssh -n "${os_user_name}@${line}" "gunzip ${cn_db_dir}/logs/*confignode*all* >/dev/null 2>&1 || true"
        local v_npe v_cn_err1 v_cn_err2 v_cn_memrel
        v_npe=$(ssh -n "${os_user_name}@${line}" "grep NullPointer ${cn_db_dir}/logs/*confignode*all*|wc -l")
        v_cn_err1=$(ssh -n "${os_user_name}@${line}" "grep BufferUnderflowException ${cn_db_dir}/logs/*confignode*all*|wc -l")
        v_cn_err2=$(ssh -n "${os_user_name}@${line}" "grep 'but return HAS_MORE_STATE' ${cn_db_dir}/logs/*confignode*all*|wc -l")
        v_cn_err3=$(ssh -n "${os_user_name}@${line}" "grep 'code:525, message:Failed to create database. The max_data_region_group_num can only be set when data_region_group_extension_policy is CUSTOM' ${cn_db_dir}/logs/*confignode*all*|wc -l")
        if [ "${v_npe}" -gt 0 ] || [ $((v_cn_err1 + v_cn_err2+v_cn_err3)) -gt 0 ]; then
            let fail_flag++
            let backup_log_flag++
            v_warnMessage="${v_warnMessage}confignode log error on ${line}."
            log "ERROR" "confignode log error on ${line} (NPE=${v_npe})"
        fi
        # 已知无害噪声(不判 FAIL): AutoResizingBuffer 记账过度释放 warn(源自 #17911 RPC 缓冲内存控制;
        # AtomicLongMemoryBlock.release 已兜底夹 0, 不影响功能)。只累计 v_warnNum 并留证。
        v_cn_memrel=$(ssh -n "${os_user_name}@${line}" "grep 'The memory cost to be released is larger' ${cn_db_dir}/logs/*confignode*all*|wc -l")
        if [ "${v_cn_memrel}" -gt 0 ]; then
            v_warnNum=$((v_warnNum + v_cn_memrel))
            v_warnMessage="${v_warnMessage}confignode ${line} AutoResizingBuffer over-release warn x${v_cn_memrel}(known-noise,#17911)."
            log "WARN" "confignode ${line} AutoResizingBuffer over-release warn x${v_cn_memrel} (known-noise, not fail)"
        fi
    done

    exec 4<"${nodeinfo_dir}/datanode.txt"
    while read -r line <&4; do
        ssh -n "${os_user_name}@${line}" "gunzip ${db_dir}/logs/*datanode*all* >/dev/null 2>&1 || true"
        local v_npe v_err v_snapshot_err
        v_npe=$(ssh -n "${os_user_name}@${line}" "grep NullPointer ${db_dir}/logs/*datanode*all*|wc -l")
        v_err=$(ssh -n "${os_user_name}@${line}" "grep -E 'CompactionTableSchemaNotMatchException|has overlapped data|which should be later than the last time|DataTypeInconsistentException|ArrayIndexOutOfBoundsException|StatisticsClassException|BufferUnderflowException|NegativeArraySizeException|is not in tsFileMetaData' ${db_dir}/logs/*datanode*all*|wc -l")
        v_snapshot_err=$(ssh -n "${os_user_name}@${line}" "grep -E 'Exception occurs when loading snapshot for|Fail to load snapshot from ' ${db_dir}/logs/*datanode*all*|wc -l")
        if [ "${v_npe}" -gt 0 ] || [ "${v_err}" -gt 0 ]; then
            let fail_flag++
            let backup_log_flag++
            v_warnMessage="${v_warnMessage}datanode log error on ${line}."
            log "ERROR" "datanode log error on ${line} (NPE=${v_npe}, err=${v_err})"
        fi
        if [ "${v_snapshot_err}" -gt 0 ]; then
            let fail_flag++
            let backup_log_flag++
            v_warnMessage="${v_warnMessage}datanode snapshot load error on ${line}."
        fi
        # 已知无害噪声(不判 FAIL, 同 CN): AutoResizingBuffer 记账过度释放 warn。只累计 v_warnNum。
        local v_dn_memrel
        v_dn_memrel=$(ssh -n "${os_user_name}@${line}" "grep 'The memory cost to be released is larger' ${db_dir}/logs/*datanode*all*|wc -l")
        if [ "${v_dn_memrel}" -gt 0 ]; then
            v_warnNum=$((v_warnNum + v_dn_memrel))
            v_warnMessage="${v_warnMessage}datanode ${line} AutoResizingBuffer over-release warn x${v_dn_memrel}(known-noise,#17911)."
            log "WARN" "datanode ${line} AutoResizingBuffer over-release warn x${v_dn_memrel} (known-noise, not fail)"
        fi
    done
}

stop_cluster() { sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1 || true; }

backup_logs() {
    local tc_name_pre backup_time
    tc_name_pre=$(echo "${SCRIPT_NAME}" | awk -F '.' '{print $1}')
    backup_time=$(date +"%Y_%m_%d_%H_%M_%S")
    sh -x "${clean_env_dir}/backup_cluster_logs.sh" "${tc_name_pre}_${backup_time}" >> "${log_file}" 2>&1 || true
}

# =============================================================================
# 结果落库
# =============================================================================
build_result_message() {
    local m="${v_warnMessage}"
    # 分批 CANCEL 计时(批1=tree, 批2=table_plain+table_view)
    m="${m}${cancel_batch_timings}"
    local i
    for i in $(seq 0 $((mig_count-1))); do
        [ -z "${mig_region_id[$i]}" ] && continue
        m="${m}mig[${mig_slot_name[$i]}]=r${mig_region_id[$i]}(${mig_src_dn_id[$i]}->${mig_tgt_dn_id[$i]})."
    done
    m="${m}benchmark=${bm_elapsed_seconds}s."
    echo "${m}"
}

write_result() {
    local elapsed=$1
    local v_result_iotdb_ip result_message
    v_result_iotdb_ip=$(grep ^test_result_iotdb_ip "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
    result_message=$(build_result_message)
    if [ "${fail_flag}" -gt 0 ]; then
        echo "testcase CAM_P0_06 fail"
        ${cli_dir}/sbin/start-cli.sh -h "${v_result_iotdb_ip}" -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','FAIL',${elapsed},${bm_elapsed_seconds},${bm_elapsed_seconds},${v_warnNum},'${result_message}');" >> "${log_file}" 2>&1 || true
    else
        echo "testcase CAM_P0_06 pass"
        ${cli_dir}/sbin/start-cli.sh -h "${v_result_iotdb_ip}" -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','PASS',${elapsed},${bm_elapsed_seconds},${bm_elapsed_seconds},${v_warnNum},'${result_message}');" >> "${log_file}" 2>&1 || true
    fi
    log "INFO" "RESULT fail_flag=${fail_flag} msg=${result_message}"
}

finalize_test() {
    local test_begin_time=$1
    stop_benchmark_now
    stop_cluster
    check_log || true
    backup_logs
    write_result $(( $(date +%s) - test_begin_time ))
}

# =============================================================================
# 主流程
# =============================================================================
expect_success() {
    local dialect=$1 sql=$2 name=$3
    local out="${run_artifact_dir}/${name}.out"
    ${cli_dir}/sbin/start-cli.sh -u root -h "${query_ip}" -sql_dialect "${dialect}" -e "${sql}" > "${out}" 2>&1
    trim_file_crlf "${out}"
    grep -q "The statement is executed successfully." "${out}" || { let fail_flag++; v_warnMessage="${v_warnMessage}${name} should succeed."; }
}

expect_parse_error() {
    local dialect=$1 sql=$2 name=$3
    local out="${run_artifact_dir}/${name}.out"
    ${cli_dir}/sbin/start-cli.sh -u root -h "${query_ip}" -sql_dialect "${dialect}" -e "${sql}" > "${out}" 2>&1 || true
    trim_file_crlf "${out}"
    if ! grep -Eqi 'parse|syntax|mismatched input|extraneous input|no viable alternative|error|exception' "${out}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${name} did not return a parse error."
        log "ERROR" "Invalid SQL was unexpectedly accepted: ${sql}"
    fi
}

main() {
    mkdir -p "${run_artifact_dir}"
    : > "${log_file}"
    local test_begin_time
    test_begin_time=$(date +%s)
    log "INFO" "Case: CAM_P0_06 syntax and dialect coverage"
    start_db || { finalize_test "${test_begin_time}"; return 1; }

    expect_success tree "cancel all migrations;" valid_tree_lower
    expect_success tree "CaNcEl AlL MiGrAtIoNs;" valid_tree_mixed
    expect_success table "CANCEL ALL MIGRATIONS;" valid_table
    expect_parse_error tree "CANCEL ALL MIGRATIONS 1;" invalid_tree_argument
    expect_parse_error tree "CANCEL MIGRATIONS;" invalid_tree_missing_all
    expect_parse_error tree "CANCEL ALL MIGRATION;" invalid_tree_singular
    expect_parse_error tree "CANCEL ALL MIGRATIONS ON 1;" invalid_tree_filter
    expect_parse_error table "CANCEL ALL MIGRATIONS 1;" invalid_table_argument
    expect_parse_error table "CANCEL MIGRATIONS;" invalid_table_missing_all
    expect_parse_error table "CANCEL ALL MIGRATION;" invalid_table_singular
    expect_parse_error table "CANCEL ALL MIGRATIONS ON 1;" invalid_table_filter

    collect_migrations tree syntax_after > /dev/null
    grep -Eq '^Empty set' "${run_artifact_dir}/syntax_after_tree_migrations.out" || { let fail_flag++; v_warnMessage="${v_warnMessage}syntax checks caused migration side effects."; }
    finalize_test "${test_begin_time}"
    [ "${fail_flag}" -eq 0 ]
}

main "$@"
