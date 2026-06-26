#!/bin/bash
set -uo pipefail

cur_dir="$( cd "$( dirname "$0" )" && pwd )"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

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

cn_num=3
dn_num=4
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num + dn_num))
v_cluster_num_info="${cn_num}C${dn_num}D"
v_consensus="IoTConsensus"
ssl_str=""
run_timestamp=$(date +'%Y_%m_%d_%H_%M_%S')
run_artifact_dir="${cur_dir}/${SCRIPT_NAME%.*}_${run_timestamp}"
log_file="${run_artifact_dir}/set_conf_parallel.log"

bm_dir="${cur_dir}/../benchmark/bm_20260519_writeview_v20/balance2"
bm_runner="${cur_dir}/../benchmark/bm_20260519_writeview_v20/benchmark.sh"
bm_duration_hours="${1:-12}"
load_balance_target_ids_override="${2:-}"
pre_balance_wait_seconds=$((3 * 3600))
bm_duration_seconds=$((bm_duration_hours * 3600))
bm_duration_ms=$((bm_duration_seconds * 1000))
bm_guard_seconds=$((bm_duration_seconds + 1800))

if ! [[ "${bm_duration_hours}" =~ ^[0-9]+$ ]] || [ "${bm_duration_hours}" -lt 4 ]; then
    echo "bm_duration_hours must be an integer and >= 4, current: ${bm_duration_hours}"
    exit 1
fi

rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

expand_dn_ip=$(tail -1 "${nodeinfo_dir}/datanode_5d.txt" | sed 's/ //g')
expand_dn_id=""
migrate_elapsed_seconds=0
migrate_tree_elapsed_seconds=0
migrate_table_elapsed_seconds=0
extend_elapsed_seconds=0
extend_tree_elapsed_seconds=0
extend_table_elapsed_seconds=0
remove_elapsed_seconds=0
remove_tree_elapsed_seconds=0
remove_table_elapsed_seconds=0
tree_migrate_region_id=""
tree_migrate_from_dn_id=""
table_migrate_region_id=""
table_migrate_from_dn_id=""
tree_extend_region_id=""
tree_extend_from_dn_id=""
table_extend_region_id=""
table_extend_from_dn_id=""
fail_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."
bm_pids=()
data_region_count_max_diff=1
data_size_diff_pct_threshold=20
final_data_size_diff_pct_threshold=10

TREE_DB_PATH="root.test.g_0"
TABLE_DB_NAME="usr_sod0"
TABLE_NAMES=("tab1mb_0" "writable_view_0" "writable_view_10mb_0")

log() {
    local level=$1
    local msg=$2
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" | tee -a "${log_file}"
}

snapshot_ts() {
    date +'%Y_%m_%d_%H_%M_%S_%N'
}

archive_snapshot() {
    local src_file=$1
    local archive_base=$2
    cp -f "${src_file}" "${run_artifact_dir}/${archive_base}_$(snapshot_ts).out" 2>/dev/null || true
}

append_migrations_trace() {
    local stage=$1
    local dialect=$2
    local src_file=$3
    local trace_file="${run_artifact_dir}/${stage}_show_migrations_trace.out"
    {
        echo "===== $(date +'%Y-%m-%d %H:%M:%S') stage=${stage} dialect=${dialect} ====="
        cat "${src_file}"
        echo
    } >> "${trace_file}"
}

check_benchmark_assets() {
    if [ ! -x "${bm_runner}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}benchmark runner missing."
        log "ERROR" "benchmark runner not found: ${bm_runner}"
        return 1
    fi

    local conf
    for conf in \
        "${bm_dir}/conf_tree1/config.properties" \
        "${bm_dir}/conf_tree2/config.properties" \
        "${bm_dir}/conf_tab1/config.properties" \
        "${bm_dir}/conf_tab2/config.properties" \
        "${bm_dir}/conf_tab3/config.properties"; do
        if [ ! -f "${conf}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}benchmark config missing."
            log "ERROR" "benchmark config not found: ${conf}"
            return 1
        fi
    done
}

trim_file_crlf() {
    local file=$1
    sed -i 's/\r$//' "${file}" 2>/dev/null || true
}

check_cli_success() {
    local file=$1
    local desc=$2
    trim_file_crlf "${file}"
    if grep -Eq "Exception|ERROR|Error" "${file}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${desc} failed."
        log "ERROR" "${desc} failed"
        cat "${file}"
        return 1
    fi
    log "INFO" "${desc} success"
    return 0
}

normalize_query_result() {
    local src_file=$1
    local dst_file=$2
    sed '/^It costs /d' "${src_file}" > "${dst_file}"
}

show_migrations_is_empty() {
    local dialect=$1
    local stage=$2
    local out_file="${run_artifact_dir}/${stage}_${dialect}_migrations.out"
    if [ "${dialect}" = "tree" ]; then
        ${cli_dir}/sbin/start-cli.sh -u "${db_user_name}" ${ssl_str} -h "${query_ip}" -timeout 3600 -sql_dialect tree -e "show migrations;" > "${out_file}"
    else
        ${cli_dir}/sbin/start-cli.sh -u "${db_user_name}" ${ssl_str} -h "${query_ip}" -timeout 3600 -sql_dialect table -e "show migrations;" > "${out_file}"
    fi
    trim_file_crlf "${out_file}"
    append_migrations_trace "${stage}" "${dialect}" "${out_file}"
    if grep -Eq "Exception|ERROR|Error" "${out_file}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${dialect} show migrations failed."
        log "ERROR" "${dialect} show migrations failed"
        cat "${out_file}" >> "${log_file}"
        return 1
    fi
    if grep -Eq '^Empty set' "${out_file}"; then
        return 0
    fi
    return 2
}

show_regions_has_active_migration() {
    local stage=$1
    local out_file="${run_artifact_dir}/${stage}_table_regions.out"
    ${cli_dir}/sbin/start-cli.sh -u "${db_user_name}" ${ssl_str} -h "${query_ip}" -timeout 3600 -sql_dialect table -e "show regions;" > "${out_file}"
    trim_file_crlf "${out_file}"
    archive_snapshot "${out_file}" "${stage}_table_regions"
    if grep -Eq "Exception|ERROR|Error" "${out_file}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}table show regions failed."
        log "ERROR" "table show regions failed"
        cat "${out_file}" >> "${log_file}"
        return 1
    fi
    if grep -Eq "Adding|Removing" "${out_file}"; then
        return 0
    fi
    return 2
}

check_show_migrations_consistency() {
    local stage=$1
    local tree_done=$2
    local table_done=$3
    local region_rc=$4
    local inconsistent_dialects=""
    local marker_file="${run_artifact_dir}/${stage}_show_migrations_bug.flag"

    if [ "${region_rc}" -ne 0 ]; then
        return 0
    fi

    if [ "${tree_done}" -eq 1 ]; then
        inconsistent_dialects="tree"
    fi
    if [ "${table_done}" -eq 1 ]; then
        if [ -n "${inconsistent_dialects}" ]; then
            inconsistent_dialects="${inconsistent_dialects},table"
        else
            inconsistent_dialects="table"
        fi
    fi

    if [ -z "${inconsistent_dialects}" ]; then
        return 0
    fi

    if [ ! -f "${marker_file}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${stage} show regions still has Adding/Removing while show migrations returned Empty set for ${inconsistent_dialects}; suspect show migrations bug."
        log "ERROR" "${stage} show regions still has Adding/Removing while show migrations returned Empty set for ${inconsistent_dialects}; suspect show migrations bug"
        for file in \
            "${run_artifact_dir}/${stage}_tree_migrations.out" \
            "${run_artifact_dir}/${stage}_table_migrations.out" \
            "${run_artifact_dir}/${stage}_table_regions.out"; do
            if [ -f "${file}" ]; then
                cat "${file}" >> "${log_file}"
            fi
        done
        : > "${marker_file}"
    fi
    return 0
}

clean_env() {
    log "INFO" "Start cleaning cluster environment"
    sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1 || true
    sh -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1
    sh -x "${clean_env_dir}/reset_conf.sh" >> "${log_file}" 2>&1
    sh -x "${clean_env_dir}/clear_cache.sh" >> "${log_file}" 2>&1
}

configure_confignode() {
    local node_ip=$1
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="8G"/g' ${cn_db_dir}/conf/confignode-env.sh
sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="8G"/g' ${cn_db_dir}/conf/confignode-env.sh

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
batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
batch_set_sys_conf ".*migrate_thread_count=.*" "migrate_thread_count=10"
batch_set_sys_conf ".*region_migration_speed_limit_bytes_per_second=.*" "region_migration_speed_limit_bytes_per_second=251658240"
EOF
}

configure_datanode() {
    local node_ip=$1
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="32G"/g' ${db_dir}/conf/datanode-env.sh
sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${db_dir}/conf/datanode-env.sh

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
batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
batch_set_sys_conf ".*migrate_thread_count=.*" "migrate_thread_count=10"
batch_set_sys_conf ".*region_migration_speed_limit_bytes_per_second=.*" "region_migration_speed_limit_bytes_per_second=251658240"
EOF
}

configure_mixed_node() {
    local node_ip=$1
    configure_confignode "${node_ip}"
    configure_datanode "${node_ip}"
}

set_conf() {
    grep -v '^$' "${nodeinfo_dir}/confignode.txt" | sed 's/ //g' | sort -u > /tmp/cn_ips.tmp
    grep -v '^$' "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sort -u > /tmp/dn_ips.tmp

    local pids=()
    while read -r ip; do
        [ -z "${ip}" ] && continue
        if grep -q "^${ip}$" /tmp/dn_ips.tmp; then
            configure_mixed_node "${ip}" &
        else
            configure_confignode "${ip}" &
        fi
        pids+=($!)
    done < /tmp/cn_ips.tmp

    while read -r ip; do
        [ -z "${ip}" ] && continue
        if ! grep -q "^${ip}$" /tmp/cn_ips.tmp; then
            configure_datanode "${ip}" &
            pids+=($!)
        fi
    done < /tmp/dn_ips.tmp

    for pid in "${pids[@]}"; do
        if ! wait "${pid}"; then
            let fail_flag++
            log "ERROR" "configure pid ${pid} failed"
        fi
    done

    rm -f /tmp/cn_ips.tmp /tmp/dn_ips.tmp
}

start_db() {
    log "INFO" "Start ${v_cluster_num_info} cluster"
    clean_env
    set_conf
    if [ "${fail_flag}" -gt 0 ]; then
        log "ERROR" "Configuration failed"
        exit 1
    fi
    sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1
}

refresh_running_datanodes() {
    ${cli_dir}/sbin/start-cli.sh -u "${db_user_name}" ${ssl_str} -h "${query_ip}" -e "show datanodes;" > "${run_artifact_dir}/show_datanodes.out"
    trim_file_crlf "${run_artifact_dir}/show_datanodes.out"
    : > "${run_artifact_dir}/running_datanode_regions.txt"
    awk -F'|' '
    function trim(s) {
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
    }
    /^\|/ {
        node_id = trim($2)
        status = trim($3)
        rpc_address = trim($4)
        data_region_num = trim($6)
        schema_region_num = trim($7)
        if (node_id ~ /^[0-9]+$/ && status == "Running") {
            print node_id " " rpc_address
            print node_id " " rpc_address " " data_region_num " " schema_region_num > region_file
        }
    }' region_file="${run_artifact_dir}/running_datanode_regions.txt" "${run_artifact_dir}/show_datanodes.out" > "${run_artifact_dir}/running_datanodes.txt"
}

wait_for_datanode_running() {
    local dn_ip=$1
    local timeout_seconds=$2
    local begin_time
    begin_time=$(date +%s)
    while true; do
        refresh_running_datanodes
        if grep -q " ${dn_ip}$" "${run_artifact_dir}/running_datanodes.txt"; then
            return 0
        fi
        if [ $(( $(date +%s) - begin_time )) -gt "${timeout_seconds}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}expand dn ${dn_ip} not running."
            return 1
        fi
        sleep 5
    done
}

wait_for_datanode_stopped() {
    local dn_ip=$1
    local timeout_seconds=$2
    local begin_time
    begin_time=$(date +%s)
    while true; do
        local jps_count
        jps_count=$(ssh "${os_user_name}@${dn_ip}" "jps | grep DataNode | wc -l" 2>/dev/null || echo 1)
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
    ssh "${os_user_name}@${dn_ip}" "source /etc/profile; cd ${db_dir}; sudo ./sbin/stop-datanode.sh" >> "${log_file}" 2>&1
    wait_for_datanode_stopped "${dn_ip}" 300
}

start_one_datanode() {
    local dn_ip=$1
    ssh "${os_user_name}@${dn_ip}" "source /etc/profile; cd ${db_dir}; sudo ./sbin/start-datanode.sh -H ${db_dir}/dn_$(date +%s)_heapdump.hprof > /dev/null 2>&1 &" >> "${log_file}" 2>&1
    wait_for_datanode_running "${dn_ip}" 600
}

append_expand_node_if_needed() {
    if ! grep -qx "${expand_dn_ip}" "${nodeinfo_dir}/datanode.txt"; then
        echo "${expand_dn_ip}" >> "${nodeinfo_dir}/datanode.txt"
    fi
}

collect_regions() {
    local dialect=$1
    local stage=$2
    local out_file="${run_artifact_dir}/${stage}_${dialect}_regions.out"
    if [ "${dialect}" = "tree" ]; then
        ${cli_dir}/sbin/start-cli.sh -u "${db_user_name}" ${ssl_str} -h "${query_ip}" -timeout 3600 -e "show regions;" > "${out_file}"
    else
        ${cli_dir}/sbin/start-cli.sh -u "${db_user_name}" ${ssl_str} -h "${query_ip}" -timeout 3600 -sql_dialect table -e "show regions;" > "${out_file}"
    fi
    trim_file_crlf "${out_file}"
    archive_snapshot "${out_file}" "${stage}_${dialect}_regions"
}

check_region_balance_from_file() {
    local region_file=$1
    local stage=$2
    local dialect=$3
    local result_file="${run_artifact_dir}/${stage}_${dialect}_region_balance.out"
    awk -F'|' '
    function trim(s) {
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
    }
    FNR == NR {
        split(trim($1), parts, /[[:space:]]+/)
        dn_id = parts[1]
        if (dn_id ~ /^[0-9]+$/) {
            ids[dn_id] = 1
            leader[dn_id] = 0
            follower[dn_id] = 0
        }
        next
    }
    /^\|/ {
        type = trim($3)
        status = trim($4)
        dn = trim($8)
        role = trim($12)
        if (type == "DataRegion" && status == "Running" && dn in ids) {
            if (role == "Leader") {
                leader[dn]++
            } else if (role == "Follower") {
                follower[dn]++
            }
        }
    }
    END {
        first = 1
        matched = 0
        for (dn in ids) {
            if (first) {
                min_leader = max_leader = leader[dn]
                min_follower = max_follower = follower[dn]
                first = 0
            }
            if (leader[dn] < min_leader) min_leader = leader[dn]
            if (leader[dn] > max_leader) max_leader = leader[dn]
            if (follower[dn] < min_follower) min_follower = follower[dn]
            if (follower[dn] > max_follower) max_follower = follower[dn]
            matched += leader[dn] + follower[dn]
            printf("DataNodeId=%s leader=%d follower=%d\n", dn, leader[dn], follower[dn])
        }
        if (first) {
            print "NO_RUNNING_DATANODE"
            exit 1
        }
        if (matched == 0) {
            print "NO_DATA_REGION_PARSED"
            exit 1
        }
        printf("leader_diff=%d\n", max_leader - min_leader)
        printf("follower_diff=%d\n", max_follower - min_follower)
        if ((max_leader - min_leader) < 2 && (max_follower - min_follower) < 2) {
            print "BALANCED"
        } else {
            print "UNBALANCED"
            exit 1
        }
    }' "${run_artifact_dir}/running_datanodes.txt" "${region_file}" > "${result_file}"
    local rc=$?
    cat "${result_file}" >> "${log_file}"
    if [ "${rc}" -ne 0 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${stage} ${dialect} region balance failed."
        log "ERROR" "${stage} ${dialect} region balance failed"
        return 1
    fi
    log "INFO" "${stage} ${dialect} region balance passed"
    return 0
}

check_expand_datanode_region_distribution() {
    local stage=$1
    local result_file="${run_artifact_dir}/${stage}_expand_dn_region_distribution.out"
    refresh_running_datanodes
    awk -v target_id="${expand_dn_id}" '
    BEGIN {
        total_data_regions = 0
        running_dn_count = 0
        target_data_regions = -1
        target_schema_regions = -1
        target_ip = ""
    }
    {
        if ($1 !~ /^[0-9]+$/) {
            next
        }
        running_dn_count++
        total_data_regions += $3
        if ($1 == target_id) {
            target_ip = $2
            target_data_regions = $3
            target_schema_regions = $4
        }
    }
    END {
        if (running_dn_count == 0) {
            print "NO_RUNNING_DATANODE"
            exit 1
        }
        if (target_data_regions < 0) {
            print "EXPAND_DN_NOT_FOUND"
            exit 1
        }
        avg = total_data_regions / running_dn_count
        printf("expand_dn_id=%s ip=%s data_regions=%d schema_regions=%d total_data_regions=%d running_datanodes=%d avg_data_regions=%.2f\n",
            target_id, target_ip, target_data_regions, target_schema_regions, total_data_regions, running_dn_count, avg)
        if (target_data_regions < 1) {
            print "EXPAND_DN_NO_DATA_REGION"
            exit 1
        }
        if (total_data_regions >= running_dn_count * 2 && target_data_regions * running_dn_count * 2 < total_data_regions) {
            print "EXPAND_DN_DATA_REGION_TOO_FEW"
            exit 1
        }
        print "EXPAND_DN_REGION_CHECK_OK"
    }' "${run_artifact_dir}/running_datanode_regions.txt" > "${result_file}"
    local rc=$?
    cat "${result_file}" >> "${log_file}"
    if [ "${rc}" -ne 0 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${stage} expand dn data region distribution failed."
        log "ERROR" "${stage} expand dn data region distribution failed"
        return 1
    fi
    log "INFO" "${stage} expand dn data region distribution passed"
    return 0
}

check_region_balance() {
    local stage=$1
    local rc=0
    refresh_running_datanodes
    collect_regions tree "${stage}"
    collect_regions table "${stage}"
    check_region_balance_from_file "${run_artifact_dir}/${stage}_tree_regions.out" "${stage}" tree || rc=1
    check_region_balance_from_file "${run_artifact_dir}/${stage}_table_regions.out" "${stage}" table || rc=1
    return "${rc}"
}

create_benchmark_users() {
    ${cli_dir}/sbin/start-cli.sh -h "${query_ip}" -u root -e "CREATE USER santos 'TimechoDB@2021';" > "${run_artifact_dir}/create_santos.out"
    check_cli_success "${run_artifact_dir}/create_santos.out" "create user santos"
    ${cli_dir}/sbin/start-cli.sh -h "${query_ip}" -u root -e "GRANT ALL ON root.** TO USER santos;" > "${run_artifact_dir}/grant_santos.out"
    check_cli_success "${run_artifact_dir}/grant_santos.out" "grant santos"

    ${cli_dir}/sbin/start-cli.sh -h "${query_ip}" -u root -sql_dialect table -e "CREATE USER rainer 'TimechoDB@2021';" > "${run_artifact_dir}/create_rainer.out"
    check_cli_success "${run_artifact_dir}/create_rainer.out" "create user rainer"
    ${cli_dir}/sbin/start-cli.sh -h "${query_ip}" -u root -sql_dialect table -e "GRANT ALL TO USER rainer;" > "${run_artifact_dir}/grant_rainer.out"
    check_cli_success "${run_artifact_dir}/grant_rainer.out" "grant rainer"
}

prepare_benchmark_configs() {
    local start_time
    start_time=$(date +"%Y-%m-%dT%H:%M:%S%:z")
    local conf
    for conf in \
        "${bm_dir}/conf_tree1/config.properties" \
        "${bm_dir}/conf_tree2/config.properties" \
        "${bm_dir}/conf_tab1/config.properties" \
        "${bm_dir}/conf_tab2/config.properties" \
        "${bm_dir}/conf_tab3/config.properties"; do
        sed -i "s/^START_TIME=.*/START_TIME=${start_time}/g" "${conf}"
        sed -i "s/^TEST_MAX_TIME=.*/TEST_MAX_TIME=${bm_duration_ms}/g" "${conf}"
        sed -i "s/^LOOP=.*/LOOP=100000000/g" "${conf}"
    done
}

start_benchmark() {
    check_benchmark_assets || return 1
    prepare_benchmark_configs
    local bm_log_dir="${bm_dir}/${testdb}"
    mkdir -p "${bm_log_dir}"
    local now
    now=$(date +%Y%m%d_%H%M%S)

    timeout --preserve-status "${bm_guard_seconds}s" "${bm_runner}" -cf "${bm_dir}/conf_tree1" > "${bm_log_dir}/${now}_conf_tree1.out" 2>&1 &
    bm_pids+=($!)
    timeout --preserve-status "${bm_guard_seconds}s" "${bm_runner}" -cf "${bm_dir}/conf_tree2" > "${bm_log_dir}/${now}_conf_tree2.out" 2>&1 &
    bm_pids+=($!)
    timeout --preserve-status "${bm_guard_seconds}s" "${bm_runner}" -cf "${bm_dir}/conf_tab1" > "${bm_log_dir}/${now}_conf_tab1.out" 2>&1 &
    bm_pids+=($!)
    timeout --preserve-status "${bm_guard_seconds}s" "${bm_runner}" -cf "${bm_dir}/conf_tab2" > "${bm_log_dir}/${now}_conf_tab2.out" 2>&1 &
    bm_pids+=($!)
    timeout --preserve-status "${bm_guard_seconds}s" "${bm_runner}" -cf "${bm_dir}/conf_tab3" > "${bm_log_dir}/${now}_conf_tab3.out" 2>&1 &
    bm_pids+=($!)

    log "INFO" "Started 5 benchmark processes, duration=${bm_duration_hours}h"
}

expand_cluster() {
    log "INFO" "Expand cluster with ${expand_dn_ip}"
    configure_datanode "${expand_dn_ip}"
    ssh "${os_user_name}@${expand_dn_ip}" "source /etc/profile; cd ${db_dir}; sudo ./sbin/start-datanode.sh -H ${db_dir}/dn_$(date +%s)_heapdump.hprof > /dev/null 2>&1 &" >> "${log_file}" 2>&1
    wait_for_datanode_running "${expand_dn_ip}" 600 || return 1
    append_expand_node_if_needed
    refresh_running_datanodes
    expand_dn_id=$(awk -v target_ip="${expand_dn_ip}" '$2 == target_ip {print $1}' "${run_artifact_dir}/running_datanodes.txt")
    if [ -z "${expand_dn_id}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}expand dn id not found."
        log "ERROR" "Expand dn id not found"
        return 1
    fi
    log "INFO" "Expand dn id=${expand_dn_id}"
}

select_operation_regions_from_file() {
    local region_file=$1
    local expected_db=$2
    local dialect=$3
    local exclude_region_id=${4:-}
    local candidate_file="${run_artifact_dir}/${dialect}_region_candidates.out"
    awk -F'|' -v expected_db="${expected_db}" -v expand_target_id="${expand_dn_id}" -v exclude_region_id="${exclude_region_id}" '
    function trim(s) {
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
    }
    /^\|/ {
        region_id = trim($2)
        type = trim($3)
        status = trim($4)
        database = trim($5)
        dn_id = trim($8)
        role = trim($12)
        if (region_id ~ /^[0-9]+$/ &&
            type == "DataRegion" &&
            status == "Running" &&
            database == expected_db &&
            dn_id != expand_target_id &&
            role == "Leader" &&
            region_id != exclude_region_id &&
            !(region_id in seen)) {
            seen[region_id] = dn_id
            print region_id " " dn_id
        }
    }' "${region_file}" > "${candidate_file}"

    if [ "$(wc -l < "${candidate_file}")" -lt 2 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${dialect} user data regions are insufficient for migrate and extend."
        log "ERROR" "${dialect} user data regions are insufficient for migrate and extend"
        cat "${candidate_file}" >> "${log_file}" 2>&1 || true
        return 1
    fi

    local first_line second_line
    first_line=$(sed -n '1p' "${candidate_file}")
    second_line=$(sed -n '2p' "${candidate_file}")

    if [ "${dialect}" = "tree" ]; then
        read -r tree_migrate_region_id tree_migrate_from_dn_id <<< "${first_line}"
        read -r tree_extend_region_id tree_extend_from_dn_id <<< "${second_line}"
    else
        read -r table_migrate_region_id table_migrate_from_dn_id <<< "${first_line}"
        read -r table_extend_region_id table_extend_from_dn_id <<< "${second_line}"
    fi
    return 0
}

select_migrate_regions() {
    refresh_running_datanodes
    collect_regions tree "select_migrate_regions"
    collect_regions table "select_migrate_regions"
    select_operation_regions_from_file "${run_artifact_dir}/select_migrate_regions_tree_regions.out" "${TREE_DB_PATH}" tree || return 1
    select_operation_regions_from_file "${run_artifact_dir}/select_migrate_regions_table_regions.out" "${TABLE_DB_NAME}" table || return 1
    log "INFO" "Selected migrate regions: tree region=${tree_migrate_region_id} from dn=${tree_migrate_from_dn_id}, table region=${table_migrate_region_id} from dn=${table_migrate_from_dn_id}"
    return 0
}

select_extend_regions() {
    refresh_running_datanodes
    collect_regions tree "select_extend_regions"
    collect_regions table "select_extend_regions"
    select_operation_regions_from_file "${run_artifact_dir}/select_extend_regions_tree_regions.out" "${TREE_DB_PATH}" tree "${tree_migrate_region_id}" || return 1
    select_operation_regions_from_file "${run_artifact_dir}/select_extend_regions_table_regions.out" "${TABLE_DB_NAME}" table "${table_migrate_region_id}" || return 1
    log "INFO" "Selected extend regions: tree region=${tree_extend_region_id}, table region=${table_extend_region_id}"
    return 0
}

run_maintenance_sql() {
    local dialect=$1
    local sql=$2
    local out_file=$3
    local desc=$4
    ${cli_dir}/sbin/start-cli.sh -u root -h "${query_ip}" -timeout 3600 -sql_dialect "${dialect}" -e "${sql}" > "${out_file}"
    check_cli_success "${out_file}" "${desc}" || return 1
    return 0
}

wait_for_migrations_completion() {
    local stage=$1
    local prefix=$2
    local timeout_seconds=${3:-0}
    local begin_time
    local tree_done=0
    local table_done=0
    begin_time=$(date +%s)
    while true; do
        local elapsed_seconds
        local region_rc=2
        elapsed_seconds=$(( $(date +%s) - begin_time ))

        if [ "${tree_done}" -eq 0 ]; then
            show_migrations_is_empty tree "${stage}"
            local tree_rc=$?
            if [ "${tree_rc}" -eq 1 ]; then
                return 1
            fi
            if [ "${tree_rc}" -eq 0 ]; then
                tree_done=1
                eval "${prefix}_tree_elapsed_seconds=${elapsed_seconds}"
                log "INFO" "${stage} tree completed in ${elapsed_seconds}s"
            fi
        fi

        if [ "${table_done}" -eq 0 ]; then
            show_migrations_is_empty table "${stage}"
            local table_rc=$?
            if [ "${table_rc}" -eq 1 ]; then
                return 1
            fi
            if [ "${table_rc}" -eq 0 ]; then
                table_done=1
                eval "${prefix}_table_elapsed_seconds=${elapsed_seconds}"
                log "INFO" "${stage} table completed in ${elapsed_seconds}s"
            fi
        fi

        show_regions_has_active_migration "${stage}"
        region_rc=$?
        if [ "${region_rc}" -eq 1 ]; then
            return 1
        fi

        check_show_migrations_consistency "${stage}" "${tree_done}" "${table_done}" "${region_rc}" || return 1

        if [ "${tree_done}" -eq 1 ] && [ "${table_done}" -eq 1 ] && [ "${region_rc}" -eq 2 ]; then
            eval "${prefix}_elapsed_seconds=${elapsed_seconds}"
            return 0
        fi
        if [ "${timeout_seconds}" -gt 0 ] && [ "${elapsed_seconds}" -gt "${timeout_seconds}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}${stage} not completed."
            return 1
        fi
        sleep 10
    done
}

run_migrate_phase() {
    run_maintenance_sql tree "migrate region ${tree_migrate_region_id} from ${tree_migrate_from_dn_id} to ${expand_dn_id};" "${run_artifact_dir}/migrate_tree.out" "tree migrate region ${tree_migrate_region_id}" || return 1
    run_maintenance_sql table "migrate region ${table_migrate_region_id} from ${table_migrate_from_dn_id} to ${expand_dn_id};" "${run_artifact_dir}/migrate_table.out" "table migrate region ${table_migrate_region_id}" || return 1
    wait_for_migrations_completion "after_migrate" "migrate" 0 || return 1
    collect_regions tree "after_migrate"
    collect_regions table "after_migrate"
    return 0
}

run_extend_phase() {
    run_maintenance_sql tree "extend region ${tree_extend_region_id} to ${expand_dn_id};" "${run_artifact_dir}/extend_tree.out" "tree extend region ${tree_extend_region_id}" || return 1
    run_maintenance_sql table "extend region ${table_extend_region_id} to ${expand_dn_id};" "${run_artifact_dir}/extend_table.out" "table extend region ${table_extend_region_id}" || return 1
    wait_for_migrations_completion "after_extend" "extend" 0 || return 1
    collect_regions tree "after_extend"
    collect_regions table "after_extend"
    return 0
}

run_remove_phase() {
    run_maintenance_sql tree "remove region ${tree_extend_region_id} from ${expand_dn_id};" "${run_artifact_dir}/remove_tree.out" "tree remove region ${tree_extend_region_id}" || return 1
    run_maintenance_sql table "remove region ${table_extend_region_id} from ${expand_dn_id};" "${run_artifact_dir}/remove_table.out" "table remove region ${table_extend_region_id}" || return 1
    wait_for_migrations_completion "after_remove" "remove" 0 || return 1
    collect_regions tree "after_remove"
    collect_regions table "after_remove"
    return 0
}

collect_region_file_counts_on_dn() {
    local dn_ip=$1
    local region_id=$2
    local stage=$3
    local output_file="${run_artifact_dir}/${stage}_region_${region_id}_files_on_${dn_ip}.out"

    ssh "${os_user_name}@${dn_ip}" 'bash -s' > "${output_file}" 2>&1 <<EOF
conf_file="${db_dir}/conf/iotdb-system.properties"
region_id="${region_id}"
data_dirs=\$(awk -F '=' '/^[[:space:]]*dn_data_dirs[[:space:]]*=/{print \$2; exit}' "\${conf_file}" 2>/dev/null | tr -d '[:space:]')
if [[ -z "\${data_dirs}" ]]; then
  data_dirs="${db_dir}/data/datanode/data"
fi
printf 'DATA_DIRS=%s\n' "\${data_dirs}"
printf 'OBJECT_DIR=%s\n' "${db_dir}/data/datanode/data/object/\${region_id}"
IFS=',' read -r -a dir_arr <<< "\${data_dirs}"
tsfile_count=0
for one_dir in "\${dir_arr[@]}"
do
  [[ -z "\${one_dir}" ]] && continue
  if [[ -d "\${one_dir}" ]]; then
    found=\$(find "\${one_dir}" -type f \( -name '*.tsfile' -o -name '*.resource' -o -name '*.mods' \) | grep "/\${region_id}/" | wc -l)
    tsfile_count=\$((tsfile_count + found))
  fi
done
object_file_count=0
if [[ -d "${db_dir}/data/datanode/data/object/\${region_id}" ]]; then
  object_file_count=\$(find "${db_dir}/data/datanode/data/object/\${region_id}" -type f | wc -l)
fi
printf 'TSFILE_COUNT=%s\n' "\${tsfile_count}"
printf 'OBJECT_FILE_COUNT=%s\n' "\${object_file_count}"
EOF
}

check_table_region_object_exists_on_expand_dn() {
    local stage=$1
    local region_id=$2
    collect_region_file_counts_on_dn "${expand_dn_ip}" "${region_id}" "${stage}"
    local output_file="${run_artifact_dir}/${stage}_region_${region_id}_files_on_${expand_dn_ip}.out"
    if [[ $? -ne 0 ]]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${stage} failed to check table region ${region_id} files on expand dn."
        log "ERROR" "${stage} failed to check table region ${region_id} files on expand dn"
        return 1
    fi

    local object_file_count
    object_file_count=$(grep '^OBJECT_FILE_COUNT=' "${output_file}" | tail -1 | awk -F '=' '{print $2}' | tr -d '[:space:]')
    object_file_count=${object_file_count:-0}
    if [[ "${object_file_count}" == "0" ]]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${stage} table region ${region_id} has no object file on expand dn."
        log "ERROR" "${stage} table region ${region_id} has no object file on expand dn"
        return 1
    fi
    log "INFO" "${stage} table region ${region_id} object files exist on expand dn: count=${object_file_count}"
    return 0
}

check_table_region_data_cleaned_on_expand_dn() {
    local stage=$1
    local region_id=$2
    collect_region_file_counts_on_dn "${expand_dn_ip}" "${region_id}" "${stage}"
    local output_file="${run_artifact_dir}/${stage}_region_${region_id}_files_on_${expand_dn_ip}.out"
    if [[ $? -ne 0 ]]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${stage} failed to check cleanup for table region ${region_id} on expand dn."
        log "ERROR" "${stage} failed to check cleanup for table region ${region_id} on expand dn"
        return 1
    fi

    local tsfile_count object_file_count
    tsfile_count=$(grep '^TSFILE_COUNT=' "${output_file}" | tail -1 | awk -F '=' '{print $2}' | tr -d '[:space:]')
    object_file_count=$(grep '^OBJECT_FILE_COUNT=' "${output_file}" | tail -1 | awk -F '=' '{print $2}' | tr -d '[:space:]')
    tsfile_count=${tsfile_count:-0}
    object_file_count=${object_file_count:-0}

    if [[ "${tsfile_count}" != "0" || "${object_file_count}" != "0" ]]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${stage} table region ${region_id} files still exist on expand dn: tsfile=${tsfile_count}, object=${object_file_count}."
        log "ERROR" "${stage} table region ${region_id} files still exist on expand dn: tsfile=${tsfile_count}, object=${object_file_count}"
        return 1
    fi
    log "INFO" "${stage} table region ${region_id} files cleaned on expand dn"
    return 0
}

check_data_region_count_balance() {
    local stage=$1
    local result_file="${run_artifact_dir}/${stage}_data_region_count_balance.out"
    refresh_running_datanodes
    awk -v expected_max_diff="${data_region_count_max_diff}" '
    BEGIN {
        first = 1
    }
    {
        if ($1 !~ /^[0-9]+$/) {
            next
        }
        dn_id = $1
        dn_ip = $2
        data_region_num = $3 + 0
        printf("DataNodeId=%s ip=%s data_region_num=%d\n", dn_id, dn_ip, data_region_num)
        if (first) {
            min_regions = max_regions = data_region_num
            first = 0
        }
        if (data_region_num < min_regions) min_regions = data_region_num
        if (data_region_num > max_regions) max_regions = data_region_num
    }
    END {
        if (first) {
            print "NO_RUNNING_DATANODE"
            exit 1
        }
        diff = max_regions - min_regions
        printf("data_region_diff=%d\n", diff)
        if (diff <= expected_max_diff) {
            print "BALANCED"
        } else {
            print "UNBALANCED"
            exit 1
        }
    }' "${run_artifact_dir}/running_datanode_regions.txt" > "${result_file}"
    local rc=$?
    cat "${result_file}" >> "${log_file}"
    if [ "${rc}" -ne 0 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${stage} data region count not balanced."
        log "WARN" "${stage} data region count not balanced"
        return 1
    fi
    log "INFO" "${stage} data region count balanced"
    return 0
}

check_datanode_data_size_balance() {
    local stage=$1
    local threshold=${2:-${data_size_diff_pct_threshold}}
    local disk_dir="${run_artifact_dir}/disk_usage"
    local summary_file="${disk_dir}/${stage}_summary.out"
    mkdir -p "${disk_dir}"
    rm -f "${disk_dir}/${stage}_"*.out 2>/dev/null || true

    local pids=()
    while read -r dn_id dn_ip; do
        [ -z "${dn_ip}" ] && continue
        {
            local stat_time
            local size_kb
            stat_time=$(date +'%Y-%m-%d %H:%M:%S')
            size_kb=$(ssh -n -o ConnectTimeout=10 "${os_user_name}@${dn_ip}" "du -sk ${db_dir}/data/datanode 2>/dev/null | cut -f1" 2>/dev/null)
            if [[ $? -eq 0 && "${size_kb}" =~ ^[0-9]+$ ]]; then
                echo "${dn_id},${dn_ip},${stat_time},${size_kb}"
            else
                echo "${dn_id},${dn_ip},${stat_time},ERROR"
            fi
        } > "${disk_dir}/${stage}_${dn_ip}.out" &
        pids+=($!)
    done < "${run_artifact_dir}/running_datanodes.txt"

    local pid
    for pid in "${pids[@]}"; do
        wait "${pid}"
    done

    cat "${disk_dir}/${stage}_"*.out | sort -t ',' -k4,4n > "${summary_file}"

    local min_kb=-1
    local max_kb=-1
    local min_ip=""
    local max_ip=""
    local sum_kb=0
    local sample_count=0
    local collect_error=0
    while IFS=, read -r dn_id dn_ip stat_time size_kb; do
        if [[ "${size_kb}" =~ ^[0-9]+$ ]]; then
            sum_kb=$((sum_kb + size_kb))
            sample_count=$((sample_count + 1))
            if [ "${min_kb}" -lt 0 ] || [ "${size_kb}" -lt "${min_kb}" ]; then
                min_kb=${size_kb}
                min_ip=${dn_ip}
            fi
            if [ "${max_kb}" -lt 0 ] || [ "${size_kb}" -gt "${max_kb}" ]; then
                max_kb=${size_kb}
                max_ip=${dn_ip}
            fi
        else
            collect_error=1
            let fail_flag++
            v_warnMessage="${v_warnMessage}collect data size failed on ${dn_ip}."
            log "WARN" "collect data size failed on ${dn_ip}"
        fi
    done < "${summary_file}"

    if [ "${sample_count}" -le 0 ]; then
        if [ "${collect_error}" -eq 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}${stage} data size summary is empty."
            log "WARN" "${stage} data size summary is empty"
        fi
        return 1
    fi

    local avg_kb
    local diff_kb
    local diff_pct
    avg_kb=$((sum_kb / sample_count))
    diff_kb=$((max_kb - min_kb))
    diff_pct=$(awk -v diff_kb="${diff_kb}" -v avg_kb="${avg_kb}" 'BEGIN { if (avg_kb <= 0) { printf "0.00" } else { printf "%.2f", diff_kb * 100 / avg_kb } }')
    log "INFO" "${stage} data size summary: avg_kb=${avg_kb}, max_kb=${max_kb}, max_ip=${max_ip}, min_kb=${min_kb}, min_ip=${min_ip}, diff_kb=${diff_kb}, diff_pct=${diff_pct}%"
    v_warnMessage="${v_warnMessage}${stage} data size summary: avg_kb=${avg_kb}, max_kb=${max_kb}, max_ip=${max_ip}, min_kb=${min_kb}, min_ip=${min_ip}, diff_kb=${diff_kb}, diff_pct=${diff_pct}%."
    if awk -v diff_pct="${diff_pct}" -v threshold="${threshold}" 'BEGIN { exit !(diff_pct > threshold) }'; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${stage} data size not balanced."
        log "WARN" "${stage} data size not balanced: diff_pct=${diff_pct}% > ${threshold}%"
        return 1
    fi
    log "INFO" "${stage} data size balanced"
    return 0
}

wait_for_monitor_sync_completion() {
    local prometheus_url
    prometheus_url=$(grep '^monitor_url' "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
    local interval=5
    if [ -z "${prometheus_url}" ]; then
        log "WARN" "monitor_url is empty, skip sync lag check"
        return 0
    fi
    while true; do
        refresh_running_datanodes
        local regex=""
        local dn_ip
        while read -r _ dn_ip; do
            [ -z "${dn_ip}" ] && continue
            dn_ip=${dn_ip//./[.]}
            if [ -n "${regex}" ]; then
                regex="${regex}|"
            fi
            regex="${regex}${dn_ip}(:[0-9]+)?"
        done < "${run_artifact_dir}/running_datanodes.txt"
        local sync_values
        sync_values=$(curl -s -u admin:admin -G "${prometheus_url}/api/v1/query" --data-urlencode "query=sum by(instance) (iotdb_datanode_load_total_sync_lag{instance=~\"${regex}\"})" 2>/dev/null)
        if [ -z "${sync_values}" ]; then
            sleep "${interval}"
            continue
        fi
        local has_non_zero
        has_non_zero=$(printf '%s\n' "${sync_values}" | grep -Eo '"value":\[[^]]+\]' | grep -Evc ',"0"|"0\.[0-9]+"' || true)
        if [ "${has_non_zero}" -eq 0 ]; then
            log "INFO" "All sync lag are zero"
            return 0
        fi
        sleep "${interval}"
    done
}

wait_for_benchmark_finish() {
    local pid
    local bm_failed=0
    for pid in "${bm_pids[@]}"; do
        if ! wait "${pid}"; then
            bm_failed=1
            log "ERROR" "benchmark pid ${pid} failed"
        fi
    done
    if [ "${bm_failed}" -ne 0 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}benchmark failed."
    fi
}

build_count_expr() {
    local max_sensor=$1
    local result=""
    local i=0
    while [ "${i}" -lt "${max_sensor}" ]; do
        if [ -n "${result}" ]; then
            result="${result},"
        fi
        result="${result}count(s_${i})"
        i=$((i + 1))
    done
    echo "${result}"
}

run_consistency_query() {
    local host=$1
    local dialect=$2
    local sql=$3
    local out_file=$4
    if [ "${dialect}" = "tree" ]; then
        ${cli_dir}/sbin/start-cli.sh -u root -h "${host}" -timeout 36000 -sql_dialect tree -e "${sql}" > "${out_file}"
    else
        ${cli_dir}/sbin/start-cli.sh -u root -h "${host}" -timeout 36000 -sql_dialect table -e "${sql}" > "${out_file}"
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

check_data_consistency() {
    local count_expr
    count_expr=$(build_count_expr 12)
    local tree_sql="select ${count_expr} from ${TREE_DB_PATH}.** align by device;"
    local table_sql_1="use ${TABLE_DB_NAME}; select device_id,${count_expr} from ${TABLE_NAMES[0]} group by device_id order by device_id;"
    local table_sql_2="use ${TABLE_DB_NAME}; select device_id,${count_expr} from ${TABLE_NAMES[1]} group by device_id order by device_id;"
    local table_sql_3="use ${TABLE_DB_NAME}; select device_id,${count_expr} from ${TABLE_NAMES[2]} group by device_id order by device_id;"

    refresh_running_datanodes
    cp -f "${run_artifact_dir}/running_datanodes.txt" "${run_artifact_dir}/baseline_running_datanodes.txt"
    local baseline_ip=""
    while read -r dn_id dn_ip; do
        [ -z "${dn_ip}" ] && continue
        if [ -z "${baseline_ip}" ]; then
            baseline_ip="${dn_ip}"
            run_consistency_query "${dn_ip}" tree "${tree_sql}" "${run_artifact_dir}/baseline_tree.out"
            run_consistency_query "${dn_ip}" table "${table_sql_1}" "${run_artifact_dir}/baseline_table1.out"
            run_consistency_query "${dn_ip}" table "${table_sql_2}" "${run_artifact_dir}/baseline_table2.out"
            run_consistency_query "${dn_ip}" table "${table_sql_3}" "${run_artifact_dir}/baseline_table3.out"
        fi
    done < "${run_artifact_dir}/baseline_running_datanodes.txt"

    while read -r dn_id dn_ip; do
        [ -z "${dn_ip}" ] && continue
        local query_host=""
        while read -r other_dn_id other_dn_ip; do
            [ -z "${other_dn_ip}" ] && continue
            if [ "${other_dn_ip}" != "${dn_ip}" ]; then
                query_host="${other_dn_ip}"
                break
            fi
        done < "${run_artifact_dir}/baseline_running_datanodes.txt"

        if [ -z "${query_host}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}no alive query host for ${dn_ip}."
            continue
        fi

        log "INFO" "Stop ${dn_ip}, query from ${query_host} for consistency check"
        if ! stop_one_datanode "${dn_ip}"; then
            continue
        fi

        run_consistency_query "${query_host}" tree "${tree_sql}" "${run_artifact_dir}/${dn_ip}_tree.out"
        run_consistency_query "${query_host}" table "${table_sql_1}" "${run_artifact_dir}/${dn_ip}_table1.out"
        run_consistency_query "${query_host}" table "${table_sql_2}" "${run_artifact_dir}/${dn_ip}_table2.out"
        run_consistency_query "${query_host}" table "${table_sql_3}" "${run_artifact_dir}/${dn_ip}_table3.out"

        normalize_query_result "${run_artifact_dir}/baseline_tree.out" "${run_artifact_dir}/baseline_tree.normalized.out"
        normalize_query_result "${run_artifact_dir}/${dn_ip}_tree.out" "${run_artifact_dir}/${dn_ip}_tree.normalized.out"
        normalize_query_result "${run_artifact_dir}/baseline_table1.out" "${run_artifact_dir}/baseline_table1.normalized.out"
        normalize_query_result "${run_artifact_dir}/${dn_ip}_table1.out" "${run_artifact_dir}/${dn_ip}_table1.normalized.out"
        normalize_query_result "${run_artifact_dir}/baseline_table2.out" "${run_artifact_dir}/baseline_table2.normalized.out"
        normalize_query_result "${run_artifact_dir}/${dn_ip}_table2.out" "${run_artifact_dir}/${dn_ip}_table2.normalized.out"
        normalize_query_result "${run_artifact_dir}/baseline_table3.out" "${run_artifact_dir}/baseline_table3.normalized.out"
        normalize_query_result "${run_artifact_dir}/${dn_ip}_table3.out" "${run_artifact_dir}/${dn_ip}_table3.normalized.out"

        if ! diff -u "${run_artifact_dir}/baseline_tree.normalized.out" "${run_artifact_dir}/${dn_ip}_tree.normalized.out" >> "${log_file}" 2>&1; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}tree inconsistent on ${dn_ip}."
        fi
        if ! diff -u "${run_artifact_dir}/baseline_table1.normalized.out" "${run_artifact_dir}/${dn_ip}_table1.normalized.out" >> "${log_file}" 2>&1; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}table1 inconsistent on ${dn_ip}."
        fi
        if ! diff -u "${run_artifact_dir}/baseline_table2.normalized.out" "${run_artifact_dir}/${dn_ip}_table2.normalized.out" >> "${log_file}" 2>&1; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}table2 inconsistent on ${dn_ip}."
        fi
        if ! diff -u "${run_artifact_dir}/baseline_table3.normalized.out" "${run_artifact_dir}/${dn_ip}_table3.normalized.out" >> "${log_file}" 2>&1; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}table3 inconsistent on ${dn_ip}."
        fi

        log "INFO" "Restart ${dn_ip} after consistency check"
        start_one_datanode "${dn_ip}"
    done < "${run_artifact_dir}/baseline_running_datanodes.txt"
}

check_log() {
    exec 3<"${nodeinfo_dir}/confignode.txt"
    while read -r line <&3; do
        ssh "${os_user_name}@${line}" "gunzip ${db_dir}/logs/*confignode*all* >/dev/null 2>&1 || true"
        local v_npe
        local v_cn_err1
        local v_cn_err2
        v_npe=$(ssh "${os_user_name}@${line}" "grep NullPointer ${db_dir}/logs/*confignode*all*|wc -l")
        v_cn_err1=$(ssh "${os_user_name}@${line}" "grep BufferUnderflowException ${db_dir}/logs/*confignode*all*|wc -l")
        v_cn_err2=$(ssh "${os_user_name}@${line}" "grep 'but return HAS_MORE_STATE' ${db_dir}/logs/*confignode*all*|wc -l")
        if [ "${v_npe}" -gt 0 ] || [ $((v_cn_err1 + v_cn_err2)) -gt 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}confignode log error on ${line}."
        fi
    done

    exec 4<"${nodeinfo_dir}/datanode.txt"
    while read -r line <&4; do
        ssh "${os_user_name}@${line}" "gunzip ${db_dir}/logs/*datanode*all* >/dev/null 2>&1 || true"
        local v_npe
        local v_err
        local v_snapshot_loader_err
        local v_snapshot_state_machine_err
        local v_table_disk_usage_err
        local v_system_metrics_err
        v_npe=$(ssh "${os_user_name}@${line}" "grep NullPointer ${db_dir}/logs/*datanode*all*|wc -l")
        v_err=$(ssh "${os_user_name}@${line}" "grep -E 'CompactionTableSchemaNotMatchException|has overlapped data|which should be later than the last time|DataTypeInconsistentException|ArrayIndexOutOfBoundsException|StatisticsClassException|BufferUnderflowException|NegativeArraySizeException|is not in tsFileMetaData|The memory cost to be released is larger' ${db_dir}/logs/*datanode*all*|wc -l")
        v_snapshot_loader_err=$(ssh "${os_user_name}@${line}" "grep -E 'Exception occurs when loading snapshot for|Fail to load snapshot from ' ${db_dir}/logs/*datanode*all*|wc -l")
        v_snapshot_state_machine_err=0
        v_table_disk_usage_err=$(ssh "${os_user_name}@${line}" "grep -E 'Meet exception when remove TableDiskUsageIndex' ${db_dir}/logs/*datanode*all*|wc -l")
        v_system_metrics_err=$(ssh "${os_user_name}@${line}" "grep -E 'Failed to statistic the size of .* because|java\\.nio\\.file\\.NoSuchFileException: .*data/datanode/system' ${db_dir}/logs/*datanode*all*|wc -l")
        if [ "${v_npe}" -gt 0 ] || [ "${v_err}" -gt 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}datanode log error on ${line}."
        fi
        if [ "${v_snapshot_loader_err}" -gt 0 ] || [ "${v_snapshot_state_machine_err}" -gt 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}datanode snapshot load error on ${line}."
            {
                echo "===== datanode snapshot load error on ${line} ====="
                ssh "${os_user_name}@${line}" "grep -nE 'Exception occurs when loading snapshot for|Cannot find .*sequence/.*/.* or .*unsequence/.*/|Fail to load snapshot from ' ${db_dir}/logs/*datanode*all* || true"
                echo
            } >> "${log_file}"
        fi
        if [ "${v_table_disk_usage_err}" -gt 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}datanode TableDiskUsageIndex remove error on ${line}."
            {
                echo "===== datanode TableDiskUsageIndex remove error on ${line} ====="
                ssh "${os_user_name}@${line}" "grep -nE 'Meet exception when remove TableDiskUsageIndex|TableDiskUsageIndex\\.remove\\(|java\\.util\\.concurrent\\.TimeoutException|DataRegion\\.deleteFolder\\(|DeleteOldRegionPeerTask\\.deleteRegion\\(' ${db_dir}/logs/*datanode*all* || true"
                echo
            } >> "${log_file}"
        fi
        if [ "${v_system_metrics_err}" -gt 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}datanode SystemMetrics disk statistic error on ${line}."
            {
                echo "===== datanode SystemMetrics disk statistic error on ${line} ====="
                ssh "${os_user_name}@${line}" "grep -nE 'Failed to statistic the size of .* because|java\\.nio\\.file\\.NoSuchFileException: .*data/datanode/system|SystemMetrics\\.getSystemDiskAvailableSpace|sampleDiskLoad\\(' ${db_dir}/logs/*datanode*all* || true"
                echo
            } >> "${log_file}"
        fi
    done
}

stop_cluster() {
    sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1 || true
}

backup_logs() {
    local tc_name_pre
    local backup_time
    tc_name_pre=$(echo "${SCRIPT_NAME}" | awk -F '.' '{print $1}')
    backup_time=$(date +"%Y_%m_%d_%H_%M_%S")
    sh -x "${clean_env_dir}/backup_cluster_logs.sh" "${tc_name_pre}_${backup_time}" >> "${log_file}" 2>&1 || true
}

build_result_message() {
    local result_message
    result_message="${v_warnMessage}migrate total=${migrate_elapsed_seconds}s,tree=${migrate_tree_elapsed_seconds}s,table=${migrate_table_elapsed_seconds}s."
    result_message="${result_message}extend total=${extend_elapsed_seconds}s,tree=${extend_tree_elapsed_seconds}s,table=${extend_table_elapsed_seconds}s."
    result_message="${result_message}remove total=${remove_elapsed_seconds}s,tree=${remove_tree_elapsed_seconds}s,table=${remove_table_elapsed_seconds}s."
    echo "${result_message}"
}

write_result() {
    local elapsed
    local result_message
    local maintenance_elapsed
    elapsed=$1
    result_message=$(build_result_message)
    maintenance_elapsed=$((migrate_elapsed_seconds + extend_elapsed_seconds + remove_elapsed_seconds))
    if [ "${fail_flag}" -gt 0 ]; then
        echo "test fail"
        echo "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','FAIL',${elapsed},${maintenance_elapsed},${bm_duration_seconds},${v_warnNum},'${result_message}');"
    else
        echo "test pass"
        echo "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','PASS',${elapsed},${maintenance_elapsed},${bm_duration_seconds},${v_warnNum},'${result_message}');"
    fi
}

main() {
    mkdir -p "${run_artifact_dir}"
    : > "${log_file}"
    log "INFO" "Run artifacts directory: ${run_artifact_dir}"
    local test_begin_time
    test_begin_time=$(date +%s)

    start_db
    create_benchmark_users
    if ! start_benchmark; then
        stop_cluster
        backup_logs
        write_result $(( $(date +%s) - test_begin_time ))
        return 1
    fi

    log "INFO" "Sleep ${pre_balance_wait_seconds}s before expand and maintenance checks"
    sleep "${pre_balance_wait_seconds}"

    expand_cluster || {
        stop_cluster
        backup_logs
        write_result $(( $(date +%s) - test_begin_time ))
        return 1
    }

    select_migrate_regions || {
        stop_cluster
        backup_logs
        write_result $(( $(date +%s) - test_begin_time ))
        return 1
    }

    run_migrate_phase || {
        stop_cluster
        backup_logs
        write_result $(( $(date +%s) - test_begin_time ))
        return 1
    }
    check_table_region_object_exists_on_expand_dn "after_migrate" "${table_migrate_region_id}" || true

    select_extend_regions || {
        stop_cluster
        backup_logs
        write_result $(( $(date +%s) - test_begin_time ))
        return 1
    }

    run_extend_phase || {
        stop_cluster
        backup_logs
        write_result $(( $(date +%s) - test_begin_time ))
        return 1
    }
    check_table_region_object_exists_on_expand_dn "after_extend" "${table_extend_region_id}" || true

    run_remove_phase || {
        stop_cluster
        backup_logs
        write_result $(( $(date +%s) - test_begin_time ))
        return 1
    }
    check_table_region_data_cleaned_on_expand_dn "after_remove" "${table_extend_region_id}" || true

    wait_for_benchmark_finish
    wait_for_monitor_sync_completion
    check_data_consistency
    stop_cluster
    check_log
    backup_logs

    write_result $(( $(date +%s) - test_begin_time ))
}

main
