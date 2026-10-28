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
dn_num=5
dr_rep_num=2
sr_rep_num=3
total_node_num=$((cn_num + dn_num))
v_cluster_num_info="${cn_num}C${dn_num}D"
v_consensus="IoTConsensus"
ssl_str=""

run_timestamp=$(date +'%Y_%m_%d_%H_%M_%S')
run_artifact_dir="${cur_dir}/${SCRIPT_NAME%.*}_${run_timestamp}"
log_file="${run_artifact_dir}/set_conf_parallel.log"

bm_base_dir="${cur_dir}/../benchmark/bm_20260519_writeview_v20"
bm_dir="${bm_base_dir}/show_mig"
bm_runner="${bm_base_dir}/benchmark.sh"
bm_tree_conf="${bm_dir}/conf_tree"
bm_table_conf="${bm_dir}/conf_table"
bm_guard_seconds=$((6 * 3600))
pre_operation_wait_seconds=60
operation_timeout_seconds=1800
cluster_ready_timeout_seconds=600
bm_test_max_time_ms=18000000
bm_loop=100000000
bm_pids=()
bm_start_epoch=0
bm_elapsed_seconds=0

rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

extend_elapsed_seconds=0
extend_tree_elapsed_seconds=0
extend_table_elapsed_seconds=0
remove_elapsed_seconds=0
remove_tree_elapsed_seconds=0
remove_table_elapsed_seconds=0

tree_region_id=""
tree_from_dn_id=""
tree_target_dn_id=""
tree_target_dn_ip=""

table_region_id=""
table_from_dn_id=""
table_target_dn_id=""
table_target_dn_ip=""

fail_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."

TREE_DB_PATH="root.test.g_0"
TABLE_DB_NAME="usr_sod0"
TABLE_NAME="writable_view_0"
benchmark_hosts=$(paste -sd, "${nodeinfo_dir}/datanode.txt")
benchmark_ports=$(awk 'BEGIN{ORS=""} {if (NR>1) printf ","; printf "6667"} END{print ""}' "${nodeinfo_dir}/datanode.txt")

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

trim_file_crlf() {
    local file=$1
    sed -i 's/\r$//' "${file}" 2>/dev/null || true
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

normalize_query_result() {
    local src_file=$1
    local dst_file=$2
    sed '/^It costs /d' "${src_file}" > "${dst_file}"
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
        "${bm_tree_conf}/config.properties" \
        "${bm_table_conf}/config.properties"; do
        if [ ! -f "${conf}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}benchmark config missing."
            log "ERROR" "benchmark config not found: ${conf}"
            return 1
        fi
    done
    return 0
}

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
batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=false"
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
batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
batch_set_sys_conf ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=false"
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

force_stop_target_processes() {
    log "INFO" "Force stop target ${testdb} processes if they still exist"
    local node_ip
    while read -r node_ip; do
        [ -z "${node_ip}" ] && continue
        ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
target="${testdb}"
pids=\$(ps -ef | grep "\${target}" | grep -E 'ConfigNode|DataNode' | grep -v grep | awk '{print \$2}')
if [ -n "\${pids}" ]; then
  kill -9 \${pids} || true
fi
EOF
    done < <(cat "${nodeinfo_dir}/confignode.txt" "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sort -u)
}

force_stop_local_benchmark_apps() {
    log "INFO" "Force stop local benchmark App processes if they still exist"
    local bm_pids
    bm_pids=$(jps | awk '/ App$/ {print $1}')
    if [ -n "${bm_pids}" ]; then
        kill -9 ${bm_pids} >> "${log_file}" 2>&1 || true
    fi
}

force_remove_target_data() {
    log "INFO" "Force remove target ${testdb} data and logs"
    local node_ip
    while read -r node_ip; do
        [ -z "${node_ip}" ] && continue
        ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" "rm -rf '${db_dir}/data' '${db_dir}/logs' '${cn_db_dir}/data' '${cn_db_dir}/logs'" >> "${log_file}" 2>&1 || true
    done < <(cat "${nodeinfo_dir}/confignode.txt" "${nodeinfo_dir}/datanode.txt" | sed 's/ //g' | sort -u)
}

wait_for_cluster_ready() {
    local begin_time
    local round=0
    begin_time=$(date +%s)
    while true; do
        local cn_ok=1
        local dn_ok=1
        local node_ip
        local missing_cn=""
        local missing_dn=""

        while read -r node_ip; do
            [ -z "${node_ip}" ] && continue
            if ! ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" "jps | grep -q ConfigNode"; then
                cn_ok=0
                if [ -n "${missing_cn}" ]; then
                    missing_cn="${missing_cn},"
                fi
                missing_cn="${missing_cn}${node_ip}"
            fi
        done < "${nodeinfo_dir}/confignode.txt"

        while read -r node_ip; do
            [ -z "${node_ip}" ] && continue
            if ! ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" "jps | grep -q DataNode"; then
                dn_ok=0
                if [ -n "${missing_dn}" ]; then
                    missing_dn="${missing_dn},"
                fi
                missing_dn="${missing_dn}${node_ip}"
            fi
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
            log "INFO" "Waiting cluster ready: missing_cn=${missing_cn:-none} missing_dn=${missing_dn:-none}"
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
    log "INFO" "Start ${v_cluster_num_info} cluster"
    clean_env
    set_conf
    if [ "${fail_flag}" -gt 0 ]; then
        log "ERROR" "Configuration failed"
        return 1
    fi
    timeout --preserve-status 120s sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1 || log "WARN" "start_cluster_v20.sh returned non-zero or timed out, continue waiting for actual cluster readiness"
    wait_for_cluster_ready
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
            v_warnMessage="${v_warnMessage}datanode ${dn_ip} not running."
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
    ssh "${os_user_name}@${dn_ip}" "source /etc/profile; cd ${db_dir}; ./sbin/stop-datanode.sh" >> "${log_file}" 2>&1
    wait_for_datanode_stopped "${dn_ip}" 300
}

start_one_datanode() {
    local dn_ip=$1
    ssh "${os_user_name}@${dn_ip}" "source /etc/profile; cd ${db_dir}; ./sbin/start-datanode.sh -H ${db_dir}/dn_$(date +%s)_heapdump.hprof > /dev/null 2>&1 &" >> "${log_file}" 2>&1
    wait_for_datanode_running "${dn_ip}" 600
}

collect_regions() {
    local dialect=$1
    local stage=$2
    local out_file="${run_artifact_dir}/${stage}_${dialect}_regions.out"
    if [ "${dialect}" = "tree" ]; then
        ${cli_dir}/sbin/start-cli.sh -u "${db_user_name}" ${ssl_str} -h "${query_ip}" -timeout 3600 -sql_dialect tree -e "show regions;" > "${out_file}"
    else
        ${cli_dir}/sbin/start-cli.sh -u "${db_user_name}" ${ssl_str} -h "${query_ip}" -timeout 3600 -sql_dialect table -e "show regions;" > "${out_file}"
    fi
    trim_file_crlf "${out_file}"
    archive_snapshot "${out_file}" "${stage}_${dialect}_regions"
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

show_region_has_active_state() {
    local dialect=$1
    local stage=$2
    local region_id=$3
    collect_regions "${dialect}" "${stage}"
    local out_file="${run_artifact_dir}/${stage}_${dialect}_regions.out"
    if grep -Eq "Exception|ERROR|Error" "${out_file}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${dialect} show regions failed."
        log "ERROR" "${dialect} show regions failed"
        cat "${out_file}" >> "${log_file}"
        return 1
    fi
    if awk -F'|' -v region_id="${region_id}" '
    function trim(s) {
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
    }
    /^\|/ {
        rid = trim($2)
        status = trim($4)
        if (rid == region_id && (status == "Adding" || status == "Removing")) {
            found = 1
        }
    }
    END {
        exit(found ? 0 : 1)
    }' "${out_file}"; then
        return 0
    fi
    return 2
}

record_show_migrations_bug_once() {
    local stage=$1
    local dialect=$2
    local region_id=$3
    local marker_file="${run_artifact_dir}/${stage}_${dialect}_${region_id}_show_migrations_bug.flag"
    if [ -f "${marker_file}" ]; then
        return 0
    fi
    let fail_flag++
    v_warnMessage="${v_warnMessage}${stage} ${dialect} region ${region_id} still has Adding/Removing while show migrations returned Empty set."
    log "ERROR" "${stage} ${dialect} region ${region_id} still has Adding/Removing while show migrations returned Empty set"
    for file in \
        "${run_artifact_dir}/${stage}_${dialect}_migrations.out" \
        "${run_artifact_dir}/${stage}_${dialect}_regions.out"; do
        if [ -f "${file}" ]; then
            cat "${file}" >> "${log_file}"
        fi
    done
    : > "${marker_file}"
}

wait_for_region_operation_completion() {
    local stage=$1
    local dialect=$2
    local region_id=$3
    local prefix=$4
    local timeout_seconds=${5:-${operation_timeout_seconds}}
    local begin_time
    begin_time=$(date +%s)
    while true; do
        local elapsed_seconds
        local mig_rc=2
        local region_rc=2
        elapsed_seconds=$(( $(date +%s) - begin_time ))

        show_migrations_is_empty "${dialect}" "${stage}"
        mig_rc=$?
        if [ "${mig_rc}" -eq 1 ]; then
            return 1
        fi

        show_region_has_active_state "${dialect}" "${stage}" "${region_id}"
        region_rc=$?
        if [ "${region_rc}" -eq 1 ]; then
            return 1
        fi

        if [ "${region_rc}" -eq 0 ] && [ "${mig_rc}" -eq 0 ]; then
            record_show_migrations_bug_once "${stage}" "${dialect}" "${region_id}"
        fi

        if [ "${region_rc}" -eq 2 ] && [ "${mig_rc}" -eq 0 ]; then
            eval "${prefix}=${elapsed_seconds}"
            log "INFO" "${stage} ${dialect} region ${region_id} completed in ${elapsed_seconds}s"
            return 0
        fi

        if [ "${timeout_seconds}" -gt 0 ] && [ "${elapsed_seconds}" -gt "${timeout_seconds}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}${stage} ${dialect} region ${region_id} not completed."
            log "ERROR" "${stage} ${dialect} region ${region_id} not completed within ${timeout_seconds}s"
            return 1
        fi
        sleep 10
    done
}

select_region_and_target_from_file() {
    local region_file=$1
    local expected_db=$2
    local dialect=$3
    local candidate_file="${run_artifact_dir}/${dialect}_region_candidates.out"

    awk -F'|' -v expected_db="${expected_db}" '
    function trim(s) {
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
    }
    FNR == NR {
        if ($1 ~ /^[0-9]+$/) {
            dn_ip[$1] = $2
        }
        next
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
            (dn_id in dn_ip)) {
            region_seen[region_id] = 1
            present[region_id SUBSEP dn_id] = 1
            if (!(region_id in any_dn)) {
                any_dn[region_id] = dn_id
            }
            if (role == "Leader" && !(region_id in leader_dn)) {
                leader_dn[region_id] = dn_id
            }
        }
    }
    END {
        for (region_id in region_seen) {
            target_dn = ""
            target_ip = ""
            for (dn in dn_ip) {
                if (!((region_id SUBSEP dn) in present)) {
                    target_dn = dn
                    target_ip = dn_ip[dn]
                    break
                }
            }
            if (target_dn != "") {
                src_dn = (region_id in leader_dn) ? leader_dn[region_id] : any_dn[region_id]
                printf("%s %s %s %s\n", region_id, src_dn, target_dn, target_ip)
            }
        }
    }' "${run_artifact_dir}/running_datanodes.txt" "${region_file}" | sort -n -k1,1 -k3,3 > "${candidate_file}"

    if [ ! -s "${candidate_file}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}${dialect} user data regions are insufficient for extend/remove."
        log "ERROR" "${dialect} user data regions are insufficient for extend/remove"
        return 1
    fi

    local first_line
    first_line=$(sed -n '1p' "${candidate_file}")
    if [ "${dialect}" = "tree" ]; then
        read -r tree_region_id tree_from_dn_id tree_target_dn_id tree_target_dn_ip <<< "${first_line}"
        log "INFO" "Selected tree region=${tree_region_id} from_dn=${tree_from_dn_id} target_dn=${tree_target_dn_id} target_ip=${tree_target_dn_ip}"
    else
        read -r table_region_id table_from_dn_id table_target_dn_id table_target_dn_ip <<< "${first_line}"
        log "INFO" "Selected table region=${table_region_id} from_dn=${table_from_dn_id} target_dn=${table_target_dn_id} target_ip=${table_target_dn_ip}"
    fi
    return 0
}

select_tree_region_and_target() {
    refresh_running_datanodes
    collect_regions tree "select_tree_region"
    select_region_and_target_from_file "${run_artifact_dir}/select_tree_region_tree_regions.out" "${TREE_DB_PATH}" tree
}

select_table_region_and_target() {
    refresh_running_datanodes
    collect_regions table "select_table_region"
    select_region_and_target_from_file "${run_artifact_dir}/select_table_region_table_regions.out" "${TABLE_DB_NAME}" table
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

run_tree_extend_phase() {
    local begin_time
    begin_time=$(date +%s)
    run_maintenance_sql tree "extend region ${tree_region_id} to ${tree_target_dn_id};" "${run_artifact_dir}/extend_tree.out" "tree extend region ${tree_region_id}" || return 1
    wait_for_region_operation_completion "after_extend_tree" tree "${tree_region_id}" "extend_tree_elapsed_seconds" "${operation_timeout_seconds}" || return 1
    extend_elapsed_seconds=$((extend_elapsed_seconds + $(date +%s) - begin_time))
    return 0
}

run_table_extend_phase() {
    local begin_time
    begin_time=$(date +%s)
    run_maintenance_sql table "extend region ${table_region_id} to ${table_target_dn_id};" "${run_artifact_dir}/extend_table.out" "table extend region ${table_region_id}" || return 1
    wait_for_region_operation_completion "after_extend_table" table "${table_region_id}" "extend_table_elapsed_seconds" "${operation_timeout_seconds}" || return 1
    extend_elapsed_seconds=$((extend_elapsed_seconds + $(date +%s) - begin_time))
    return 0
}

run_tree_remove_phase() {
    local begin_time
    begin_time=$(date +%s)
    run_maintenance_sql tree "remove region ${tree_region_id} from ${tree_target_dn_id};" "${run_artifact_dir}/remove_tree.out" "tree remove region ${tree_region_id}" || return 1
    wait_for_region_operation_completion "after_remove_tree" tree "${tree_region_id}" "remove_tree_elapsed_seconds" "${operation_timeout_seconds}" || return 1
    remove_elapsed_seconds=$((remove_elapsed_seconds + $(date +%s) - begin_time))
    return 0
}

run_table_remove_phase() {
    local begin_time
    begin_time=$(date +%s)
    run_maintenance_sql table "remove region ${table_region_id} from ${table_target_dn_id};" "${run_artifact_dir}/remove_table.out" "table remove region ${table_region_id}" || return 1
    wait_for_region_operation_completion "after_remove_table" table "${table_region_id}" "remove_table_elapsed_seconds" "${operation_timeout_seconds}" || return 1
    remove_elapsed_seconds=$((remove_elapsed_seconds + $(date +%s) - begin_time))
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

wait_for_table_region_object_exists_on_dn() {
    local stage=$1
    local dn_ip=$2
    local region_id=$3
    local timeout_seconds=${4:-120}
    local begin_time
    begin_time=$(date +%s)
    while true; do
        collect_region_file_counts_on_dn "${dn_ip}" "${region_id}" "${stage}"
        local output_file="${run_artifact_dir}/${stage}_region_${region_id}_files_on_${dn_ip}.out"
        if [ $? -ne 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}${stage} failed to check table region ${region_id} files on ${dn_ip}."
            log "ERROR" "${stage} failed to check table region ${region_id} files on ${dn_ip}"
            return 1
        fi
        local object_file_count
        object_file_count=$(grep '^OBJECT_FILE_COUNT=' "${output_file}" | tail -1 | awk -F '=' '{print $2}' | tr -d '[:space:]')
        object_file_count=${object_file_count:-0}
        if [ "${object_file_count}" != "0" ]; then
            log "INFO" "${stage} table region ${region_id} object files exist on ${dn_ip}: count=${object_file_count}"
            return 0
        fi
        if [ $(( $(date +%s) - begin_time )) -gt "${timeout_seconds}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}${stage} table region ${region_id} has no object file on ${dn_ip}."
            log "ERROR" "${stage} table region ${region_id} has no object file on ${dn_ip}"
            return 1
        fi
        sleep 5
    done
}

wait_for_tree_region_data_cleaned_on_dn() {
    local stage=$1
    local dn_ip=$2
    local region_id=$3
    local timeout_seconds=${4:-180}
    local begin_time
    begin_time=$(date +%s)
    while true; do
        collect_region_file_counts_on_dn "${dn_ip}" "${region_id}" "${stage}"
        local output_file="${run_artifact_dir}/${stage}_region_${region_id}_files_on_${dn_ip}.out"
        if [ $? -ne 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}${stage} failed to check cleanup for tree region ${region_id} on ${dn_ip}."
            log "ERROR" "${stage} failed to check cleanup for tree region ${region_id} on ${dn_ip}"
            return 1
        fi
        local tsfile_count
        tsfile_count=$(grep '^TSFILE_COUNT=' "${output_file}" | tail -1 | awk -F '=' '{print $2}' | tr -d '[:space:]')
        tsfile_count=${tsfile_count:-0}
        if [ "${tsfile_count}" = "0" ]; then
            log "INFO" "${stage} tree region ${region_id} files cleaned on ${dn_ip}"
            return 0
        fi
        if [ $(( $(date +%s) - begin_time )) -gt "${timeout_seconds}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}${stage} tree region ${region_id} files still exist on ${dn_ip}: tsfile=${tsfile_count}."
            log "ERROR" "${stage} tree region ${region_id} files still exist on ${dn_ip}: tsfile=${tsfile_count}"
            return 1
        fi
        sleep 5
    done
}

wait_for_table_region_data_cleaned_on_dn() {
    local stage=$1
    local dn_ip=$2
    local region_id=$3
    local timeout_seconds=${4:-180}
    local begin_time
    begin_time=$(date +%s)
    while true; do
        collect_region_file_counts_on_dn "${dn_ip}" "${region_id}" "${stage}"
        local output_file="${run_artifact_dir}/${stage}_region_${region_id}_files_on_${dn_ip}.out"
        if [ $? -ne 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}${stage} failed to check cleanup for table region ${region_id} on ${dn_ip}."
            log "ERROR" "${stage} failed to check cleanup for table region ${region_id} on ${dn_ip}"
            return 1
        fi
        local tsfile_count object_file_count
        tsfile_count=$(grep '^TSFILE_COUNT=' "${output_file}" | tail -1 | awk -F '=' '{print $2}' | tr -d '[:space:]')
        object_file_count=$(grep '^OBJECT_FILE_COUNT=' "${output_file}" | tail -1 | awk -F '=' '{print $2}' | tr -d '[:space:]')
        tsfile_count=${tsfile_count:-0}
        object_file_count=${object_file_count:-0}
        if [ "${tsfile_count}" = "0" ] && [ "${object_file_count}" = "0" ]; then
            log "INFO" "${stage} table region ${region_id} files cleaned on ${dn_ip}"
            return 0
        fi
        if [ $(( $(date +%s) - begin_time )) -gt "${timeout_seconds}" ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}${stage} table region ${region_id} files still exist on ${dn_ip}: tsfile=${tsfile_count}, object=${object_file_count}."
            log "ERROR" "${stage} table region ${region_id} files still exist on ${dn_ip}: tsfile=${tsfile_count}, object=${object_file_count}"
            return 1
        fi
        sleep 5
    done
}

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

prepare_benchmark_configs() {
    local start_time
    start_time=$(date +"%Y-%m-%dT%H:%M:%S%:z")
    local tree_conf="${bm_tree_conf}/config.properties"
    local table_conf="${bm_table_conf}/config.properties"

    set_benchmark_property() {
        local file=$1
        local key=$2
        local value=$3
        if grep -q "^${key}=" "${file}"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
        else
            echo "${key}=${value}" >> "${file}"
        fi
    }

    set_benchmark_property "${tree_conf}" HOST "${benchmark_hosts}"
    set_benchmark_property "${tree_conf}" PORT "${benchmark_ports}"
    set_benchmark_property "${tree_conf}" USERNAME "santos"
    set_benchmark_property "${tree_conf}" PASSWORD "TimechoDB@2021"
    set_benchmark_property "${tree_conf}" DB_NAME "test"
    set_benchmark_property "${tree_conf}" LOOP "${bm_loop}"
    set_benchmark_property "${tree_conf}" TEST_MAX_TIME "${bm_test_max_time_ms}"
    set_benchmark_property "${tree_conf}" IS_DELETE_DATA "false"
    set_benchmark_property "${tree_conf}" START_TIME "${start_time}"

    set_benchmark_property "${table_conf}" HOST "${benchmark_hosts}"
    set_benchmark_property "${table_conf}" PORT "${benchmark_ports}"
    set_benchmark_property "${table_conf}" USERNAME "rainer"
    set_benchmark_property "${table_conf}" PASSWORD "TimechoDB@2021"
    set_benchmark_property "${table_conf}" DB_NAME "usr"
    set_benchmark_property "${table_conf}" LOOP "${bm_loop}"
    set_benchmark_property "${table_conf}" TEST_MAX_TIME "${bm_test_max_time_ms}"
    set_benchmark_property "${table_conf}" IS_DELETE_DATA "false"
    set_benchmark_property "${table_conf}" START_TIME "${start_time}"

    {
        echo "=== ${tree_conf} ==="
        grep -E '^(HOST|PORT|USERNAME|DB_NAME|LOOP|TEST_MAX_TIME|START_TIME|IoTDB_DIALECT_MODE|IoTDB_TABLE_WRITABLE_VIEW|IoTDB_TABLE_NAME_PREFIX|GROUP_NAME_PREFIX|BATCH_SIZE_PER_WRITE|POINT_STEP|OPERATION_PROPORTION)=' "${tree_conf}" || true
        echo "=== ${table_conf} ==="
        grep -E '^(HOST|PORT|USERNAME|DB_NAME|LOOP|TEST_MAX_TIME|START_TIME|IoTDB_DIALECT_MODE|IoTDB_TABLE_WRITABLE_VIEW|IoTDB_TABLE_NAME_PREFIX|GROUP_NAME_PREFIX|BATCH_SIZE_PER_WRITE|POINT_STEP|OPERATION_PROPORTION)=' "${table_conf}" || true
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
    bm_start_epoch=$(date +%s)
    log "INFO" "Started 2 benchmark processes"
    return 0
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
    if [ "${bm_start_epoch}" -gt 0 ]; then
        bm_elapsed_seconds=$(( $(date +%s) - bm_start_epoch ))
    fi
    if [ "${bm_failed}" -ne 0 ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}benchmark failed."
    fi
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

check_online_query_consistency() {
    local count_expr
    count_expr=$(build_count_expr 12)
    local tree_sql="select ${count_expr} from ${TREE_DB_PATH}.** align by device;"
    local table_sql="use ${TABLE_DB_NAME}; select device_id,${count_expr} from ${TABLE_NAME} group by device_id order by device_id;"

    refresh_running_datanodes
    local baseline_ip
    baseline_ip=$(awk 'NR==1 {print $2}' "${run_artifact_dir}/running_datanodes.txt")
    if [ -z "${baseline_ip}" ]; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}no alive query host."
        return 1
    fi

    run_consistency_query "${baseline_ip}" tree "${tree_sql}" "${run_artifact_dir}/baseline_tree.out" || return 1
    run_consistency_query "${baseline_ip}" table "${table_sql}" "${run_artifact_dir}/baseline_table.out" || return 1
    normalize_query_result "${run_artifact_dir}/baseline_tree.out" "${run_artifact_dir}/baseline_tree.normalized.out"
    normalize_query_result "${run_artifact_dir}/baseline_table.out" "${run_artifact_dir}/baseline_table.normalized.out"

    while read -r dn_id dn_ip; do
        [ -z "${dn_ip}" ] && continue
        run_consistency_query "${dn_ip}" tree "${tree_sql}" "${run_artifact_dir}/${dn_ip}_online_tree.out" || continue
        run_consistency_query "${dn_ip}" table "${table_sql}" "${run_artifact_dir}/${dn_ip}_online_table.out" || continue
        normalize_query_result "${run_artifact_dir}/${dn_ip}_online_tree.out" "${run_artifact_dir}/${dn_ip}_online_tree.normalized.out"
        normalize_query_result "${run_artifact_dir}/${dn_ip}_online_table.out" "${run_artifact_dir}/${dn_ip}_online_table.normalized.out"
        if ! diff -u "${run_artifact_dir}/baseline_tree.normalized.out" "${run_artifact_dir}/${dn_ip}_online_tree.normalized.out" >> "${log_file}" 2>&1; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}tree all-online inconsistent on ${dn_ip}."
        fi
        if ! diff -u "${run_artifact_dir}/baseline_table.normalized.out" "${run_artifact_dir}/${dn_ip}_online_table.normalized.out" >> "${log_file}" 2>&1; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}table all-online inconsistent on ${dn_ip}."
        fi
    done < "${run_artifact_dir}/running_datanodes.txt"

    return 0
}

check_one_dn_down_query_consistency() {
    local count_expr
    count_expr=$(build_count_expr 12)
    local tree_sql="select ${count_expr} from ${TREE_DB_PATH}.** align by device;"
    local table_sql="use ${TABLE_DB_NAME}; select device_id,${count_expr} from ${TABLE_NAME} group by device_id order by device_id;"

    refresh_running_datanodes
    cp -f "${run_artifact_dir}/running_datanodes.txt" "${run_artifact_dir}/baseline_running_datanodes.txt"
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

        if ! run_consistency_query "${query_host}" tree "${tree_sql}" "${run_artifact_dir}/${dn_ip}_tree.out"; then
            log "INFO" "Restart ${dn_ip} after failed tree consistency query"
            start_one_datanode "${dn_ip}"
            continue
        fi
        if ! run_consistency_query "${query_host}" table "${table_sql}" "${run_artifact_dir}/${dn_ip}_table.out"; then
            log "INFO" "Restart ${dn_ip} after failed table consistency query"
            start_one_datanode "${dn_ip}"
            continue
        fi
        normalize_query_result "${run_artifact_dir}/${dn_ip}_tree.out" "${run_artifact_dir}/${dn_ip}_tree.normalized.out"
        normalize_query_result "${run_artifact_dir}/${dn_ip}_table.out" "${run_artifact_dir}/${dn_ip}_table.normalized.out"

        if ! diff -u "${run_artifact_dir}/baseline_tree.normalized.out" "${run_artifact_dir}/${dn_ip}_tree.normalized.out" >> "${log_file}" 2>&1; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}tree inconsistent on ${dn_ip}."
        fi
        if ! diff -u "${run_artifact_dir}/baseline_table.normalized.out" "${run_artifact_dir}/${dn_ip}_table.normalized.out" >> "${log_file}" 2>&1; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}table inconsistent on ${dn_ip}."
        fi

        log "INFO" "Restart ${dn_ip} after consistency check"
        start_one_datanode "${dn_ip}"
    done < "${run_artifact_dir}/baseline_running_datanodes.txt"
}

check_data_consistency() {
    check_online_query_consistency || true
    check_one_dn_down_query_consistency || true
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
        fi
        if [ "${v_table_disk_usage_err}" -gt 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}datanode TableDiskUsageIndex remove error on ${line}."
        fi
        if [ "${v_system_metrics_err}" -gt 0 ]; then
            let fail_flag++
            v_warnMessage="${v_warnMessage}datanode SystemMetrics disk statistic error on ${line}."
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
    result_message="${v_warnMessage}extend total=${extend_elapsed_seconds}s,tree=${extend_tree_elapsed_seconds}s,table=${extend_table_elapsed_seconds}s."
    result_message="${result_message}remove total=${remove_elapsed_seconds}s,tree=${remove_tree_elapsed_seconds}s,table=${remove_table_elapsed_seconds}s."
    result_message="${result_message}benchmark=${bm_elapsed_seconds}s."
    echo "${result_message}"
}

write_result() {
    local elapsed=$1
    local result_message
    local maintenance_elapsed
    result_message=$(build_result_message)
    maintenance_elapsed=$((extend_elapsed_seconds + remove_elapsed_seconds))
    if [ "${fail_flag}" -gt 0 ]; then
        echo "test fail"
        echo "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','FAIL',${elapsed},${bm_elapsed_seconds},${bm_elapsed_seconds},${v_warnNum},'${result_message}');"
    else
        echo "test pass"
        echo "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','PASS',${elapsed},${bm_elapsed_seconds},${bm_elapsed_seconds},${v_warnNum},'${result_message}');"
    fi
    log "INFO" "maintenance_elapsed=${maintenance_elapsed}s benchmark_elapsed=${bm_elapsed_seconds}s"
}

finalize_test() {
    local test_begin_time=$1
    stop_cluster
    check_log || true
    backup_logs
    write_result $(( $(date +%s) - test_begin_time ))
}

main() {
    mkdir -p "${run_artifact_dir}"
    : > "${log_file}"
    log "INFO" "Run artifacts directory: ${run_artifact_dir}"
    local test_begin_time
    test_begin_time=$(date +%s)

    start_db || {
        finalize_test "${test_begin_time}"
        return 1
    }

    create_benchmark_users || {
        finalize_test "${test_begin_time}"
        return 1
    }

    start_benchmark || {
        finalize_test "${test_begin_time}"
        return 1
    }

    log "INFO" "Sleep ${pre_operation_wait_seconds}s before extend/remove checks"
    sleep "${pre_operation_wait_seconds}"

    select_tree_region_and_target || {
        finalize_test "${test_begin_time}"
        return 1
    }

    run_tree_extend_phase || {
        finalize_test "${test_begin_time}"
        return 1
    }

    select_table_region_and_target || {
        finalize_test "${test_begin_time}"
        return 1
    }

    run_table_extend_phase || {
        finalize_test "${test_begin_time}"
        return 1
    }
    wait_for_table_region_object_exists_on_dn "after_extend_table_object" "${table_target_dn_ip}" "${table_region_id}" 120 || true

    run_tree_remove_phase || {
        finalize_test "${test_begin_time}"
        return 1
    }
    wait_for_tree_region_data_cleaned_on_dn "after_remove_tree_cleanup" "${tree_target_dn_ip}" "${tree_region_id}" 180 || true

    run_table_remove_phase || {
        finalize_test "${test_begin_time}"
        return 1
    }
    wait_for_table_region_data_cleaned_on_dn "after_remove_table_cleanup" "${table_target_dn_ip}" "${table_region_id}" 180 || true

    wait_for_benchmark_finish
    wait_for_monitor_sync_completion
    check_data_consistency

    finalize_test "${test_begin_time}"

    if [ "${fail_flag}" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
