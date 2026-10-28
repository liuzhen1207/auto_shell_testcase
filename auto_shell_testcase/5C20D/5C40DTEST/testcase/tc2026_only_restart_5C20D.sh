#!/bin/bash
set -uo pipefail
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
current_dir=${cur_dir}
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"

# 读取配置文件（去空格，兼容低版本）
os_user_name=$(grep ^os_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
os_name=${os_user_name}
db_user_name=$(grep ^db_user_name "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
testdb=$(grep ^v_testdb "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
db_parent_dir=$(grep ^v_db_parent_dir "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
shell_client_db_parent_dir=$(grep "^v_shell_client_db_parent_dir=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
cli_dir=${shell_client_db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}
cn_db_parent_dir=`cat ${conf_file}|grep ^v_cn_db_parent_dir|awk -F '=' '{print $2}'`
cn_db_dir=${cn_db_parent_dir}/${testdb}
remote_cli_os_user=$(grep "^remote_cli_os_user=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
remote_cli_ip=$(grep "^remote_cli_ip=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
bm1_ip=$(grep "^bm1_ip=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
bm2_ip=$(grep "^bm2_ip=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
bm_dir=$(grep "^bm_dir=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
this_shell_ip=$(grep "^this_shell_ip=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
root_pw=$(grep "^root_pw=" "${conf_file}" | awk -F '=' '{gsub(/ /,""); print $2}')
benchmark_ip_list_file="${nodeinfo_dir}/benchmark_ip_list.txt"
bm_conf="weather_6h_diff"
bm_ips=()
backup_db_name="usr_sod0"
backup_table_names=()
declare -A backup_table_time_columns=()
declare -A backup_table_count_exprs=()
declare -A backup_table_object_columns=()
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"
CLUSTER_ID=$(grep ^CLUSTER_NAME "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
cn_num=5
dn_num=20
v_cluster_num_info="${cn_num}C${dn_num}D"
dr_rep_num=3
sr_rep_num=5
total_node_num=$((cn_num+dn_num))
node_num=${total_node_num}
log_file="${cur_dir}/set_conf_parallel.log"
bk_log_file="${cur_dir}/${testdb}/backup_import_tsfile.log"
mkdir -p "${cur_dir}/${testdb}/"
ssl_str=""
backup_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensus"
v_sec_super_user="root"
v_sys_super_user="root"
v_jstack_num=0
arg=""
v_testtime=""
benchmark_start_time=""
enable_start_db=1
enable_start_bm=1
skip_stop_cluster=${SKIP_STOP_CLUSTER:-0}
run_mode=${RUN_MODE:-restart_loop}
restart_loop_rounds=${RESTART_LOOP_ROUNDS:-0}
restart_wait_timeout_sec=${RESTART_WAIT_TIMEOUT_SEC:-1800}
restart_wait_interval_sec=${RESTART_WAIT_INTERVAL_SEC:-10}
restart_stop_wait_sec=${RESTART_STOP_WAIT_SEC:-10}
restart_round_sleep_sec=${RESTART_ROUND_SLEEP_SEC:-0}
restart_expect_running_nodes=${RESTART_EXPECT_RUNNING_NODES:-25}
backup_pipe_expected_running=1
backup_pipe_check_interval=10
backup_pipe_create_timeout=600
backup_pipe_finish_timeout=0
backup_progress_sample_interval=30
time_partition_interval_ms=3600000
backup_window_sample_size=10
# 清理旧节点文件，复制新配置
rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

# 读取种子节点IP（兼容低版本）
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
query_ip2=$(tail -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')

fail_flag=0
sum_fail_flag=0
sync_fail_flag=0
backup_target_host="172.20.70.119"
backup_target_user="root"
backup_target_pw="Iotdb@2026"
backup_target_port=22
backup_remote_root="/data1/iotdb/object_backup/${SCRIPT_NAME%.*}_$(date +%Y%m%d_%H%M%S)"
restore_stage_root="/data1/iotdb/object_backup/${SCRIPT_NAME%.*}"
restore_host="172.20.70.119"
verify_root="${cur_dir}/backup_verify"
usr_backup_host="172.20.70.106"
tod_backup_host="172.20.70.107"
java_home_remote="/usr/local/jdk-17.0.12"
db_cli_pw_arg=""
cli_query_timeout_sec=3600
query_tmp_dir="/tmp/${SCRIPT_NAME%.*}_query_tmp"
mkdir -p "${query_tmp_dir}"
usr_window_start_ms=""
usr_window_end_ms=""
usr_window_start_iso=""
usr_window_end_iso=""
tod_window_start_ms=""
tod_window_end_ms=""
tod_window_start_iso=""
tod_window_end_iso=""
verify_dir=""
usr_object_sample_stream=""
usr_object_sample_sql=""
tod_object_sample_stream=""
tod_object_sample_sql=""

if ! command -v java >/dev/null 2>&1 && [[ -x "${java_home_remote}/bin/java" ]]; then
    export JAVA_HOME="${java_home_remote}"
    export PATH="${JAVA_HOME}/bin:${PATH}"
fi

# ===================== 工具函数 =====================
# 日志输出函数（带时间戳）
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" >> "${log_file}"
    echo "[${timestamp}] [${level}] ${msg}"
}

log_backup_import() {
    local level=$1
    local msg=$2
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" >> "${bk_log_file}"
    echo "[${timestamp}] [${level}] ${msg}"
}

append_warn_message_once() {
    local msg=$1
    [[ -z "${msg}" ]] && return 0
    case "${v_warnMessage}" in
        *"${msg}"*) return 0 ;;
    esac
    v_warnMessage="${v_warnMessage}${msg}"
}

extract_delete_error_summary() {
    local out_file=$1
    local summary=""
    if [[ -f "${out_file}" ]]; then
        summary=$(grep -E "IoTDBSQLException|Exception|ERROR|does not exist|not a tag column|Fail to connect|All replicas" "${out_file}" | grep -v "The statement is executed successfully" | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [[ -z "${summary}" ]]; then
            summary=$(tail -n 1 "${out_file}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        fi
    fi
    echo "${summary}"
}

# 清理环境函数
clean_env() {
   log "INFO" "开始清理集群环境..."
   local cleanup_failed=0
   sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
   sh -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
   sh -x "${clean_env_dir}/reset_conf.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
   sh -x "${clean_env_dir}/clear_cache.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
   if [ ${cleanup_failed} -eq 0 ]; then
       log "INFO" "集群环境清理完成"
   else
       let fail_flag++
       log "ERROR" "集群环境清理失败"
   fi
}

for  i in {1..20}
do
	sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
	wait
	sh -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
	wait
	sh -x "${clean_env_dir}/clear_cache.sh" >> "${log_file}" 2>&1 || cleanup_failed=1
	wait
        sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1
	sleep 2 
       while true
       do
	       v_running_num=$(${cli_dir}/sbin/start-cli.sh -h ${query_ip} -timeout 3600 -e "show cluster;"|grep Running|wc -l)
               if [[ ${total_node_num} = ${v_running_num} ]];then
		       echo "LOOP ${i} successfully."
		       ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -timeout 3600 -e "show cluster;"
		       break
	       else
		       sleep 2 
	       fi
       done	       
done
