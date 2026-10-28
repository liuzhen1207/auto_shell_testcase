#!/bin/bash
set -uo pipefail

cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
shell_client_db_parent_dir=$(grep "^v_shell_client_db_parent_dir=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
cli_dir=${shell_client_db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
CLUSTER_ID=$(grep ^CLUSTER_NAME "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')

seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode_12d.txt" | sed 's/ //g')

init_dn_file="${nodeinfo_dir}/datanode_12d.txt"
target_dn_file="${nodeinfo_dir}/datanode_20d.txt"
working_dn_file="${nodeinfo_dir}/datanode.txt"

tmp_init_file="${cur_dir}/expand_init_dn.tmp"
tmp_target_file="${cur_dir}/expand_target_dn.tmp"
tmp_new_file="${cur_dir}/expand_new_dn.tmp"
tmp_show_dn_file="${cur_dir}/expand_show_datanodes.tmp"

dr_rep_num=3
sr_rep_num=5
v_consensus="IoTConsensus"
ssl_str=""

log() {
    local level=$1
    local msg=$2
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}"
}

cleanup_tmp() {
    rm -f "${tmp_init_file}" "${tmp_target_file}" "${tmp_new_file}" "${tmp_show_dn_file}"
}

configure_datanode() {
    local node_ip=$1

    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="48G"/g' ${db_dir}/conf/datanode-env.sh
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
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=true"
        batch_set_sys_conf ".*auditable_query_event_type=.*" "auditable_query_event_type=SLOW_OPERATION"
        batch_set_sys_conf ".*auditable_operation_type=.*" "auditable_operation_type=QUERY"
        batch_set_sys_conf ".*query_cost_stat_window=.*" "query_cost_stat_window=5"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
        batch_set_sys_conf ".*region_migration_concurrency_limit=.*" "region_migration_concurrency_limit=3"
EOF
}

start_new_datanode() {
    local node_ip=$1
    local start_time
    start_time=$(date +%s)

    # Prevent ssh from consuming the while-loop stdin, otherwise only the first
    # node in tmp_new_file is started and the remaining lines are skipped.
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" \
        "source /etc/profile; cd ${db_dir}; nohup ./sbin/start-datanode.sh -H ${db_dir}/dn_${start_time}_heapdump.hprof > /dev/null 2>&1 &"
}

wait_datanode_running() {
    local node_ip=$1
    local timeout_sec=${2:-600}
    local begin_time
    begin_time=$(date +%s)

    while true
    do
        ${cli_dir}/sbin/start-cli.sh -u "${db_user_name}" ${ssl_str} -h "${query_ip}" -e "show datanodes;" > "${tmp_show_dn_file}"
        local running_count
        running_count=$(grep "${node_ip}|" "${tmp_show_dn_file}" | grep -i Running | wc -l)
        if [[ ${running_count} -ge 1 ]]; then
            log "INFO" "新增 DataNode ${node_ip} 已变为 Running"
            break
        fi

        local now_time
        now_time=$(date +%s)
        if [[ $((now_time-begin_time)) -gt ${timeout_sec} ]]; then
            log "ERROR" "等待新增 DataNode ${node_ip} Running 超时"
            return 1
        fi
        sleep 10
    done
}

prepare_new_dn_list() {
    grep -v '^$' "${init_dn_file}" | sed 's/ //g' > "${tmp_init_file}"
    grep -v '^$' "${target_dn_file}" | sed 's/ //g' > "${tmp_target_file}"
    grep -vxF -f "${tmp_init_file}" "${tmp_target_file}" > "${tmp_new_file}" || true

    local new_dn_count
    new_dn_count=$(grep -c '.' "${tmp_new_file}" 2>/dev/null || true)
    if [[ ${new_dn_count} -ne 8 ]]; then
        log "ERROR" "期望扩容 8 个 DN，实际识别到 ${new_dn_count} 个，新增节点列表如下："
        cat "${tmp_new_file}" 2>/dev/null || true
        return 1
    fi
}

configure_new_datanodes() {
    local pids=()
    while read -r node_ip
    do
        [[ -z "${node_ip}" ]] && continue
        log "INFO" "开始配置新增 DataNode: ${node_ip}"
        configure_datanode "${node_ip}" &
        pids+=($!)
    done < "${tmp_new_file}"

    local failed=0
    for pid in "${pids[@]}"
    do
        if ! wait "${pid}"; then
            failed=1
        fi
    done

    if [[ ${failed} -ne 0 ]]; then
        log "ERROR" "新增 DataNode 配置失败"
        return 1
    fi
}

start_new_datanodes() {
    while read -r node_ip
    do
        [[ -z "${node_ip}" ]] && continue
        log "INFO" "开始启动新增 DataNode: ${node_ip}"
        if ! start_new_datanode "${node_ip}"; then
            log "ERROR" "新增 DataNode ${node_ip} 启动命令执行失败"
            return 1
        fi
    done < "${tmp_new_file}"
}

check_all_20_datanodes_running() {
    ${cli_dir}/sbin/start-cli.sh -u "${db_user_name}" ${ssl_str} -h "${query_ip}" -e "show datanodes;" > "${tmp_show_dn_file}"

    local total_running
    total_running=$(grep Running "${tmp_show_dn_file}" | wc -l)
    if [[ ${total_running} -lt 20 ]]; then
        log "ERROR" "当前 Running DataNode 数量不足 20，实际为 ${total_running}"
        cat "${tmp_show_dn_file}"
        return 1
    fi

    while read -r node_ip
    do
        [[ -z "${node_ip}" ]] && continue
        local running_count
        running_count=$(grep "${node_ip}|" "${tmp_show_dn_file}" | grep -i Running | wc -l)
        if [[ ${running_count} -lt 1 ]]; then
            log "ERROR" "新增 DataNode ${node_ip} 不是 Running"
            cat "${tmp_show_dn_file}"
            return 1
        fi
    done < "${tmp_target_file}"
}

main() {
    cleanup_tmp
    prepare_new_dn_list || return 1

    log "INFO" "识别到新增 8 个 DN，开始将工作 datanode.txt 切换到 20D 清单"
    cp -rp "${target_dn_file}" "${working_dn_file}"

    configure_new_datanodes || return 1
    start_new_datanodes || return 1

    while read -r node_ip
    do
        [[ -z "${node_ip}" ]] && continue
        wait_datanode_running "${node_ip}" 600 || return 1
    done < "${tmp_new_file}"

    check_all_20_datanodes_running || return 1
    log "INFO" "12D -> 20D 扩容完成，新增 8 个 DataNode 全部 Running"
}

main "$@"
rc=$?
cleanup_tmp
exit ${rc}
