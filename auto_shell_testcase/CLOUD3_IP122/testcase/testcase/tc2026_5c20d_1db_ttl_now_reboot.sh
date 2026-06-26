#!/bin/bash
set -uo pipefail
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
current_dir=${cur_dir}
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
verify_conf_file="${cur_dir}/../conf/tc2026_5c20d_1db_ttl_now_reboot_verify.conf"
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
ssl_str=""
backup_flag=0
backup_log_flag=0
v_warnNum=0
v_warnMessage="."
v_consensus="IoTConsensus"
v_sec_super_user="root"
v_sys_super_user="root"
v_jstack_num=0
# 清理旧节点文件，复制新配置
rm -rf "${nodeinfo_dir}/confignode.txt"
rm -rf "${nodeinfo_dir}/datanode.txt"
cp -rp "${nodeinfo_dir}/confignode_${cn_num}c.txt" "${nodeinfo_dir}/confignode.txt"
cp -rp "${nodeinfo_dir}/datanode_${dn_num}d.txt" "${nodeinfo_dir}/datanode.txt"

# 读取种子节点IP（兼容低版本）
seed_cn_ip=$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710
query_ip=$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
query_ip2=$(tail -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')
benchmark_ip_list_file="${nodeinfo_dir}/benchmark_ip_list.txt"
bm_conf="weather_6h"
v_testtime=""
benchmark_result_dir="${current_dir}/${testdb}/benchmark_result"
benchmark_result_summary_file=""
benchmark_start_time=""

fail_flag=0
sum_fail_flag=0
sync_fail_flag=0
monitor_stage_dir="${current_dir}/${testdb}/monitor_stage"

mkdir -p "${monitor_stage_dir}"
rm -f "${monitor_stage_dir}"/*

# ===================== 工具函数 =====================
# 日志输出函数（带时间戳）
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" >> "${log_file}"
    echo "[${timestamp}] [${level}] ${msg}"
}

get_verify_conf_value() {
   local key=$1
   local default_value=$2
   local value=""
   local line=""

   if [[ -f "${verify_conf_file}" ]]; then
      line=$(grep -E "^${key}=" "${verify_conf_file}" | head -n 1)
      if [[ -n "${line}" ]]; then
         value="${line#*=}"
         value=$(printf "%s" "${value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      fi
   fi

   if [[ -n "${value}" ]]; then
      echo "${value}"
   else
      echo "${default_value}"
   fi
}

write_stage_marker() {
   local marker_name=$1
   local marker_value=$2
   printf "%s\n" "${marker_value}" > "${monitor_stage_dir}/${marker_name}"
}

read_stage_marker() {
   local marker_name=$1
   if [[ -f "${monitor_stage_dir}/${marker_name}" ]]; then
      cat "${monitor_stage_dir}/${marker_name}"
   fi
}

wait_for_stage_marker() {
   local marker_name=$1
   local max_wait_seconds=${2:-120}
   local start_ts=$(date +%s)

   while true
   do
      if [[ -s "${monitor_stage_dir}/${marker_name}" ]]; then
         return 0
      fi

      if [[ $(( $(date +%s) - start_ts )) -ge ${max_wait_seconds} ]]; then
         return 1
      fi
      sleep 5
   done
}

render_promql_template() {
   local template=$1
   local cluster_name=$2
   local node_type=$3
   local database_name=$4
   local rendered="${template}"

   rendered="${rendered//__CLUSTER__/${cluster_name}}"
   rendered="${rendered//__NODE_TYPE__/${node_type}}"
   rendered="${rendered//__DATABASE__/${database_name}}"

   printf "%s\n" "${rendered}"
}

prometheus_query_range_mean() {
   local query=$1
   local start_ts=$2
   local end_ts=$3
   local step_seconds=$4
   local monitor_url monitor_user monitor_password response

   if [[ -z "${query}" || -z "${start_ts}" || -z "${end_ts}" || ${end_ts} -le ${start_ts} ]]; then
      return 1
   fi

   monitor_url=$(get_verify_conf_value "monitor_url" "")
   if [[ -z "${monitor_url}" ]]; then
      monitor_url=$(grep '^monitor_url' "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
   fi
   monitor_user=$(get_verify_conf_value "monitor_user" "admin")
   monitor_password=$(get_verify_conf_value "monitor_password" "admin")

   response=$(curl -s -u "${monitor_user}:${monitor_password}" --get \
      --data-urlencode "query=${query}" \
      --data-urlencode "start=${start_ts}" \
      --data-urlencode "end=${end_ts}" \
      --data-urlencode "step=${step_seconds}" \
      "${monitor_url}/api/v1/query_range")

   if [[ $(echo "${response}" | jq -r '.status // empty') != "success" ]]; then
      return 1
   fi

   echo "${response}" | jq -r '.data.result[]?.values[]?[1]' | awk '
      NF {
         sum += $1
         cnt++
      }
      END {
         if (cnt > 0) {
            printf "%.6f\n", sum / cnt
         } else {
            exit 1
         }
      }'
}

calc_delta_percent() {
   local baseline_value=$1
   local current_value=$2

   awk -v base="${baseline_value}" -v cur="${current_value}" '
      BEGIN {
         if (base == 0) {
            if (cur == 0) {
               printf "0.00"
            } else {
               printf "INF"
            }
         } else {
            printf "%.2f", ((cur - base) / base) * 100
         }
      }'
}

judge_metric_with_baseline() {
   local baseline_value=$1
   local current_value=$2
   local allowed_delta_percent=$3

   awk -v base="${baseline_value}" -v cur="${current_value}" -v threshold="${allowed_delta_percent}" '
      BEGIN {
         if (base == 0) {
            if (cur == 0) {
               print "PASS"
            } else {
               print "FAIL"
            }
            exit
         }
         delta = ((cur - base) / base) * 100
         if (delta < 0) {
            delta = -delta
         }
         if (delta <= threshold) {
            print "PASS"
         } else {
            print "FAIL"
         }
      }'
}

capture_region_balance_snapshot() {
   local stage_name=$1
   local raw_file="${monitor_stage_dir}/${stage_name}_regions_raw.out"
   local summary_file="${monitor_stage_dir}/${stage_name}_regions_summary.out"

   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;" > "${raw_file}" 2>&1
   if [[ $? -ne 0 ]]; then
      echo "SUMMARY|status=FAILED|reason=show_regions_command_failed" > "${summary_file}"
      return 1
   fi

   awk -F '|' '
      function trim(s) {
         gsub(/^[ \t]+|[ \t]+$/, "", s)
         return s
      }
      function get_idx(name,   i) {
         for (i = 1; i <= header_count; i++) {
            if (headers[i] == name) {
               return i + 1
            }
         }
         return -1
      }
      /\|/ {
         valid = 0
         for (i = 2; i < NF; i++) {
            cell = trim($i)
            if (cell != "" && cell !~ /^[-+]+$/) {
               valid = 1
               break
            }
         }
         if (!valid) {
            next
         }

         if (!header_ready) {
            delete headers
            header_count = 0
            for (i = 2; i < NF; i++) {
               cell = trim($i)
               if (cell == "") {
                  continue
               }
               header_count++
               headers[header_count] = cell
            }
            type_idx = get_idx("Type")
            data_node_id_idx = get_idx("DataNodeId")
            internal_address_idx = get_idx("InternalAddress")
            role_type_idx = get_idx("RoleType")
            if (type_idx > 0 && data_node_id_idx > 0 && role_type_idx > 0) {
               header_ready = 1
            }
            next
         }

         if (type_idx <= 0 || data_node_id_idx <= 0 || role_type_idx <= 0) {
            next
         }

         region_type = trim($(type_idx))
         data_node_id = trim($(data_node_id_idx))
         internal_address = internal_address_idx > 0 ? trim($(internal_address_idx)) : ""
         role_type = trim($(role_type_idx))
         if (region_type != "DataRegion" || data_node_id !~ /^[0-9]+$/) {
            next
         }
         node_key = data_node_id
         if (internal_address != "") {
            node_key = data_node_id "@" internal_address
         }
         if (role_type == "Leader") {
            leader[node_key]++
         } else if (role_type == "Follower") {
            follower[node_key]++
         } else {
            next
         }
         nodes[node_key] = 1
      }
      END {
         first = 1
         for (node in nodes) {
            l = leader[node] + 0
            f = follower[node] + 0
            print "NODE|" node "|leader=" l "|follower=" f
            if (first || l < leader_min) {
               leader_min = l
            }
            if (first || l > leader_max) {
               leader_max = l
            }
            if (first || f < follower_min) {
               follower_min = f
            }
            if (first || f > follower_max) {
               follower_max = f
            }
            first = 0
         }
         if (first) {
            print "SUMMARY|status=EMPTY"
            exit 1
         }
         print "SUMMARY|status=OK|leader_min=" leader_min "|leader_max=" leader_max "|leader_diff=" (leader_max - leader_min) "|follower_min=" follower_min "|follower_max=" follower_max "|follower_diff=" (follower_max - follower_min)
      }' "${raw_file}" > "${summary_file}"
}

report_metric_stage_result() {
   local stage_label=$1
   local metric_name=$2
   local display_unit=$3
   local promql_template=$4
   local baseline_start_ts=$5
   local baseline_end_ts=$6
   local stage_start_ts=$7
   local stage_end_ts=$8
   local value_scale=$9
   local allowed_delta_percent=${10}
   local prom_cluster prom_node_type prom_database prom_step_seconds promql
   local baseline_value stage_value delta_percent judge_result

   if [[ -z "${promql_template}" ]]; then
      log "INFO" "[${stage_label}] ${metric_name}: N/A (未配置 PromQL)"
      return 0
   fi

   prom_cluster=$(get_verify_conf_value "prom_cluster" "weather")
   prom_node_type=$(get_verify_conf_value "prom_node_type" "DATANODE")
   prom_database=$(get_verify_conf_value "prom_database" "usr_sod0")
   prom_step_seconds=$(get_verify_conf_value "prom_query_step_seconds" "60")
   promql=$(render_promql_template "${promql_template}" "${prom_cluster}" "${prom_node_type}" "${prom_database}")

   baseline_value=$(prometheus_query_range_mean "${promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${prom_step_seconds}")
   stage_value=$(prometheus_query_range_mean "${promql}" "${stage_start_ts}" "${stage_end_ts}" "${prom_step_seconds}")

   if [[ -z "${baseline_value}" || -z "${stage_value}" ]]; then
      log "WARN" "[${stage_label}] ${metric_name}: N/A (Prometheus 返回为空)"
      return 1
   fi

   delta_percent=$(calc_delta_percent "${baseline_value}" "${stage_value}")
   judge_result=$(judge_metric_with_baseline "${baseline_value}" "${stage_value}" "${allowed_delta_percent}")

   log "INFO" "[${stage_label}] ${metric_name}: baseline=$(awk -v v=\"${baseline_value}\" -v s=\"${value_scale}\" 'BEGIN {printf \"%.2f\", v * s}')${display_unit}, current=$(awk -v v=\"${stage_value}\" -v s=\"${value_scale}\" 'BEGIN {printf \"%.2f\", v * s}')${display_unit}, delta=${delta_percent}%, threshold=${allowed_delta_percent}%, result=${judge_result}"
   if [[ "${judge_result}" != "PASS" ]]; then
      let fail_flag++
   fi
}

report_region_stage_result() {
   local stage_label=$1
   local summary_file="${monitor_stage_dir}/${stage_label}_regions_summary.out"
   local region_max_diff expected_max_diff summary_line leader_diff follower_diff status
   local node_details

   expected_max_diff=$(get_verify_conf_value "region_max_diff" "1")
   if [[ ! -f "${summary_file}" ]]; then
      log "WARN" "[${stage_label}] Region Balance: N/A (未生成快照)"
      return 1
   fi

   summary_line=$(grep '^SUMMARY|' "${summary_file}" | tail -n 1)
   status=$(echo "${summary_line}" | awk -F '|' '{for(i=1;i<=NF;i++){if($i ~ /^status=/){split($i,a,"="); print a[2]}}}')
   leader_diff=$(echo "${summary_line}" | awk -F '|' '{for(i=1;i<=NF;i++){if($i ~ /^leader_diff=/){split($i,a,"="); print a[2]}}}')
   follower_diff=$(echo "${summary_line}" | awk -F '|' '{for(i=1;i<=NF;i++){if($i ~ /^follower_diff=/){split($i,a,"="); print a[2]}}}')

   if [[ "${status}" != "OK" ]]; then
      log "WARN" "[${stage_label}] Region Balance: N/A (${summary_line})"
      return 1
   fi

   node_details=$(grep '^NODE|' "${summary_file}" | sed 's/^NODE|//;s/|leader=/ leader=/;s/|follower=/ follower=/' | paste -sd ';' -)
   if [[ -n "${node_details}" ]]; then
      log "INFO" "[${stage_label}] Region Detail: ${node_details}"
   fi
   log "INFO" "[${stage_label}] Region Balance: leader_diff=${leader_diff}, follower_diff=${follower_diff}, threshold=${expected_max_diff}"
   if [[ ${leader_diff:-999999} -gt ${expected_max_diff} || ${follower_diff:-999999} -gt ${expected_max_diff} ]]; then
      let fail_flag++
      log "WARN" "[${stage_label}] Region Balance: FAIL"
   else
      log "INFO" "[${stage_label}] Region Balance: PASS"
   fi
}

generate_stage_monitor_report() {
   local baseline_start_ts baseline_end_ts stage1_start_ts stage1_end_ts stage2_start_ts stage2_end_ts stage3_start_ts stage3_end_ts
   local allowed_delta_percent
   local cpu_promql disk_promql memory_promql network_promql
   local stage1_desc stage2_desc stage3_desc

   baseline_start_ts=$(read_stage_marker "benchmark_start_ts")
   baseline_end_ts=$(read_stage_marker "fault_start_ts")
   stage1_start_ts=$(read_stage_marker "fault_start_ts")
   stage1_end_ts=$(read_stage_marker "restart_start_ts")
   stage2_start_ts=$(read_stage_marker "restart_start_ts")
   stage2_end_ts=$(read_stage_marker "sync_complete_ts")
   stage3_start_ts=$(read_stage_marker "sync_complete_ts")
   stage3_end_ts=$(read_stage_marker "benchmark_end_ts")

   if [[ -z "${baseline_start_ts}" || -z "${baseline_end_ts}" || -z "${stage1_end_ts}" || -z "${stage2_end_ts}" || -z "${stage3_end_ts}" ]]; then
      log "WARN" "自动监控结果生成失败：阶段时间戳不完整"
      return 1
   fi

   if [[ ${stage3_end_ts} -le ${stage3_start_ts} ]]; then
      log "WARN" "自动监控结果生成失败：阶段3时间区间无效，sync_complete_ts=${stage3_start_ts}, benchmark_end_ts=${stage3_end_ts}"
      return 1
   fi

   allowed_delta_percent=$(get_verify_conf_value "metric_allowed_delta_percent" "20")
   stage1_desc=$(get_verify_conf_value "stage1_desc" "宕机1小时期间")
   stage2_desc=$(get_verify_conf_value "stage2_desc" "重启恢复期间（从开始start DN到sync lag大体完成）")
   stage3_desc=$(get_verify_conf_value "stage3_desc" "重启恢复完成后（从sync lag大体完成到benchmark完成）")
   cpu_promql=$(get_verify_conf_value "cpu_promql" "")
   disk_promql=$(get_verify_conf_value "disk_promql" "")
   memory_promql=$(get_verify_conf_value "memory_promql" "")
   network_promql=$(get_verify_conf_value "network_promql" "")

   log "INFO" "==================== 自动监控结果 ===================="
   log "INFO" "基线区间: $(date -d "@${baseline_start_ts}" '+%F %T') ~ $(date -d "@${baseline_end_ts}" '+%F %T')"
   log "INFO" "阶段1(${stage1_desc})区间: $(date -d "@${stage1_start_ts}" '+%F %T') ~ $(date -d "@${stage1_end_ts}" '+%F %T')"
   log "INFO" "阶段2(${stage2_desc})区间: $(date -d "@${stage2_start_ts}" '+%F %T') ~ $(date -d "@${stage2_end_ts}" '+%F %T')"
   log "INFO" "阶段3(${stage3_desc})区间: $(date -d "@${stage3_start_ts}" '+%F %T') ~ $(date -d "@${stage3_end_ts}" '+%F %T')"

   report_benchmark_stage_result "stage1" "write_latency" "写入延迟" " ms" "bmw" "INGESTION" "latency" "${baseline_start_ts}" "${baseline_end_ts}" "${stage1_start_ts}" "${stage1_end_ts}" "${allowed_delta_percent}"
   report_benchmark_stage_result "stage1" "query_latency" "查询延迟" " ms" "bmr1,bmr2" "TIME_RANGE" "latency" "${baseline_start_ts}" "${baseline_end_ts}" "${stage1_start_ts}" "${stage1_end_ts}" "${allowed_delta_percent}"
   report_metric_stage_result "stage1" "CPU" "%" "${cpu_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage1_start_ts}" "${stage1_end_ts}" "100" "${allowed_delta_percent}"
   report_metric_stage_result "stage1" "磁盘利用率" "%" "${disk_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage1_start_ts}" "${stage1_end_ts}" "100" "${allowed_delta_percent}"
   report_metric_stage_result "stage1" "内存占用" " GB" "${memory_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage1_start_ts}" "${stage1_end_ts}" "1" "${allowed_delta_percent}"
   report_metric_stage_result "stage1" "网络吞吐" " MB/s" "${network_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage1_start_ts}" "${stage1_end_ts}" "1" "${allowed_delta_percent}"
   report_region_stage_result "stage1"

   report_benchmark_stage_result "stage2" "write_latency" "写入延迟" " ms" "bmw" "INGESTION" "latency" "${baseline_start_ts}" "${baseline_end_ts}" "${stage2_start_ts}" "${stage2_end_ts}" "${allowed_delta_percent}"
   report_benchmark_stage_result "stage2" "query_latency" "查询延迟" " ms" "bmr1,bmr2" "TIME_RANGE" "latency" "${baseline_start_ts}" "${baseline_end_ts}" "${stage2_start_ts}" "${stage2_end_ts}" "${allowed_delta_percent}"
   report_metric_stage_result "stage2" "CPU" "%" "${cpu_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage2_start_ts}" "${stage2_end_ts}" "100" "${allowed_delta_percent}"
   report_metric_stage_result "stage2" "磁盘利用率" "%" "${disk_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage2_start_ts}" "${stage2_end_ts}" "100" "${allowed_delta_percent}"
   report_metric_stage_result "stage2" "内存占用" " GB" "${memory_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage2_start_ts}" "${stage2_end_ts}" "1" "${allowed_delta_percent}"
   report_metric_stage_result "stage2" "网络吞吐" " MB/s" "${network_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage2_start_ts}" "${stage2_end_ts}" "1" "${allowed_delta_percent}"
   report_region_stage_result "stage2"

   report_benchmark_stage_result "stage3" "write_latency" "写入延迟" " ms" "bmw" "INGESTION" "latency" "${baseline_start_ts}" "${baseline_end_ts}" "${stage3_start_ts}" "${stage3_end_ts}" "${allowed_delta_percent}"
   report_benchmark_stage_result "stage3" "query_latency" "查询延迟" " ms" "bmr1,bmr2" "TIME_RANGE" "latency" "${baseline_start_ts}" "${baseline_end_ts}" "${stage3_start_ts}" "${stage3_end_ts}" "${allowed_delta_percent}"
   report_metric_stage_result "stage3" "CPU" "%" "${cpu_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage3_start_ts}" "${stage3_end_ts}" "100" "${allowed_delta_percent}"
   report_metric_stage_result "stage3" "磁盘利用率" "%" "${disk_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage3_start_ts}" "${stage3_end_ts}" "100" "${allowed_delta_percent}"
   report_metric_stage_result "stage3" "内存占用" " GB" "${memory_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage3_start_ts}" "${stage3_end_ts}" "1" "${allowed_delta_percent}"
   report_metric_stage_result "stage3" "网络吞吐" " MB/s" "${network_promql}" "${baseline_start_ts}" "${baseline_end_ts}" "${stage3_start_ts}" "${stage3_end_ts}" "1" "${allowed_delta_percent}"
   report_region_stage_result "stage3"
   log "INFO" "======================================================"
}

print_verification_expectations() {
   local monitor_url
   local monitor_user
   local monitor_password
   local performance_panel_url
   local performance_panel_desc
   local metric_baseline_desc
   local metric_allowed_delta_percent
   local write_latency_panel_url
   local write_latency_metric_desc
   local query_latency_panel_url
   local query_latency_metric_desc
   local benchmark_result_interval_seconds
   local cpu_panel_url
   local cpu_metric_desc
   local disk_busy_panel_url
   local disk_busy_metric_desc
   local network_panel_url
   local network_metric_desc
   local memory_panel_url
   local memory_metric_desc
   local region_check_source
   local region_check_filter
   local region_compare_mode
   local region_max_diff
   local sync_lag_poll_seconds
   local sync_lag_stable_seconds
   local sync_lag_recovery_ratio
   local sync_lag_total_margin
   local sync_lag_per_dn_margin
   local sync_lag_near_zero_total_threshold
   local sync_lag_near_zero_per_dn_threshold
   local sync_lag_stable_total_fluctuation
   local sync_lag_stable_per_dn_fluctuation

   monitor_url=$(get_verify_conf_value "monitor_url" "")
   monitor_user=$(get_verify_conf_value "monitor_user" "admin")
   monitor_password=$(get_verify_conf_value "monitor_password" "admin")
   performance_panel_url=$(get_verify_conf_value "performance_panel_url" "")
   performance_panel_desc=$(get_verify_conf_value "performance_panel_desc" "")
   metric_baseline_desc=$(get_verify_conf_value "metric_baseline_desc" "故障前一段时间的平均值")
   metric_allowed_delta_percent=$(get_verify_conf_value "metric_allowed_delta_percent" "20")
   write_latency_panel_url=$(get_verify_conf_value "write_latency_panel_url" "")
   write_latency_metric_desc=$(get_verify_conf_value "write_latency_metric_desc" "")
   query_latency_panel_url=$(get_verify_conf_value "query_latency_panel_url" "")
   query_latency_metric_desc=$(get_verify_conf_value "query_latency_metric_desc" "")
   benchmark_result_interval_seconds=$(get_verify_conf_value "benchmark_result_interval_seconds" "60")
   cpu_panel_url=$(get_verify_conf_value "cpu_panel_url" "")
   cpu_metric_desc=$(get_verify_conf_value "cpu_metric_desc" "")
   disk_busy_panel_url=$(get_verify_conf_value "disk_busy_panel_url" "")
   disk_busy_metric_desc=$(get_verify_conf_value "disk_busy_metric_desc" "")
   network_panel_url=$(get_verify_conf_value "network_panel_url" "")
   network_metric_desc=$(get_verify_conf_value "network_metric_desc" "")
   memory_panel_url=$(get_verify_conf_value "memory_panel_url" "")
   memory_metric_desc=$(get_verify_conf_value "memory_metric_desc" "")
   region_check_source=$(get_verify_conf_value "region_check_source" "show regions")
   region_check_filter=$(get_verify_conf_value "region_check_filter" "DataRegion")
   region_compare_mode=$(get_verify_conf_value "region_compare_mode" "inter_dn")
   region_max_diff=$(get_verify_conf_value "region_max_diff" "1")
   sync_lag_poll_seconds=$(get_verify_conf_value "sync_lag_poll_seconds" "5")
   sync_lag_stable_seconds=$(get_verify_conf_value "sync_lag_stable_seconds" "300")
   sync_lag_recovery_ratio=$(get_verify_conf_value "sync_lag_recovery_ratio" "0.8")
   sync_lag_total_margin=$(get_verify_conf_value "sync_lag_total_margin" "10")
   sync_lag_per_dn_margin=$(get_verify_conf_value "sync_lag_per_dn_margin" "2")
   sync_lag_near_zero_total_threshold=$(get_verify_conf_value "sync_lag_near_zero_total_threshold" "10")
   sync_lag_near_zero_per_dn_threshold=$(get_verify_conf_value "sync_lag_near_zero_per_dn_threshold" "2")
   sync_lag_stable_total_fluctuation=$(get_verify_conf_value "sync_lag_stable_total_fluctuation" "5")
   sync_lag_stable_per_dn_fluctuation=$(get_verify_conf_value "sync_lag_stable_per_dn_fluctuation" "1")

   log "INFO" "==================== 验证方式（预期结果）===================="
   log "INFO" "Prometheus: url=${monitor_url}, user=${monitor_user}, password=${monitor_password}"
    log "INFO" "benchmark 周期结果输出间隔: ${benchmark_result_interval_seconds} 秒"
   log "INFO" "性能面板: ${performance_panel_url}"
   log "INFO" "性能面板说明: ${performance_panel_desc}"
   log "INFO" "性能指标基线: ${metric_baseline_desc}, 允许波动: ${metric_allowed_delta_percent}%"
   log "INFO" "sync lag 自动判定: 先记录故障前基线，再判断是否回收了 ${sync_lag_recovery_ratio} 的额外 lag；poll=${sync_lag_poll_seconds}s, stable=${sync_lag_stable_seconds}s, margin(total<=${sync_lag_total_margin}, perDn<=${sync_lag_per_dn_margin}), fluctuation(total<=${sync_lag_stable_total_fluctuation}, perDn<=${sync_lag_stable_per_dn_fluctuation})"
   log "INFO" "阶段1：宕机1小时期间（这里用kill -9 CN / DN pid模拟宕机）"
   log "INFO" "1. 写入延迟：${write_latency_metric_desc}"
   log "INFO" "   来源: ${write_latency_panel_url}"
   log "INFO" "   基线: ${metric_baseline_desc}, 允许波动: ${metric_allowed_delta_percent}%"
   log "INFO" "2. 查询延迟：${query_latency_metric_desc}"
   log "INFO" "   来源: ${query_latency_panel_url}"
   log "INFO" "   基线: ${metric_baseline_desc}, 允许波动: ${metric_allowed_delta_percent}%"
   log "INFO" "3. CPU负载：${cpu_metric_desc}"
   log "INFO" "   面板: ${cpu_panel_url}"
   log "INFO" "4. 磁盘繁忙程度：${disk_busy_metric_desc}"
   log "INFO" "   面板: ${disk_busy_panel_url}"
   log "INFO" "5. 网络吞吐：${network_metric_desc}"
   log "INFO" "   面板/来源: ${network_panel_url}"
   log "INFO" "6. 内存占用：${memory_metric_desc}"
   log "INFO" "   面板: ${memory_panel_url}"
   log "INFO" "7. 每个节点的region数量：按 ${region_check_source} 仅统计 ${region_check_filter}, ${region_compare_mode} 最大差值 ${region_max_diff}"
   log "INFO" "阶段2：重启恢复期间（从开始start DN，到因重启导致的 sync lag 大体完成）"
   log "INFO" "1. 写入延迟：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "2. 查询延迟：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "3. CPU负载：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "4. 磁盘繁忙程度：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "5. 网络吞吐：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "6. 内存占用：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "7. 每个节点的region数量：按 ${region_check_source} 仅统计 ${region_check_filter}, ${region_compare_mode} 最大差值 ${region_max_diff}"
   log "INFO" "阶段3：重启恢复完成后（从 sync lag 大体完成，到 benchmark 完成）"
   log "INFO" "1. 写入延迟：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "2. 查询延迟：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "3. CPU负载：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "4. 磁盘繁忙程度：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "5. 网络吞吐：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "6. 内存占用：与故障前平均值对比，允许波动 ${metric_allowed_delta_percent}%"
   log "INFO" "7. 每个节点的region数量：按 ${region_check_source} 仅统计 ${region_check_filter}, ${region_compare_mode} 最大差值 ${region_max_diff}"
   log "INFO" "============================================================"
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

# 单个ConfigNode配置函数
configure_confignode() {
    local node_ip=$1
    log "INFO" "开始配置ConfigNode: ${node_ip}"
    
    # 整合所有ConfigNode修改命令，一次SSH执行
    ssh -o ConnectTimeout=10 "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
        # 修改env.sh配置
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="4G"/g' ${cn_db_dir}/conf/confignode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${cn_db_dir}/conf/confignode-env.sh
        
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
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=true"
        batch_set_sys_conf ".*auditable_query_event_type=.*" "auditable_query_event_type=SLOW_OPERATION"
        batch_set_sys_conf ".*auditable_operation_type=.*" "auditable_operation_type=QUERY"
        batch_set_sys_conf ".*query_cost_stat_window=.*" "query_cost_stat_window=5"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
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
        sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="48G"/g' ${db_dir}/conf/datanode-env.sh
        sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${db_dir}/conf/datanode-env.sh
        
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
        batch_set_sys_conf ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
        batch_set_sys_conf ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
        batch_set_sys_conf ".*cluster_name=.*" "cluster_name=${CLUSTER_ID}"
        batch_set_sys_conf ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.${v_consensus}"
        batch_set_sys_conf ".*enable_audit_log=.*" "enable_audit_log=true"
        batch_set_sys_conf ".*auditable_query_event_type=.*" "auditable_query_event_type=SLOW_OPERATION"
        batch_set_sys_conf ".*auditable_operation_type=.*" "auditable_operation_type=QUERY"
        batch_set_sys_conf ".*query_cost_stat_window=.*" "query_cost_stat_window=5"
        batch_set_sys_conf ".*time_partition_interval=.*" "time_partition_interval=3600000"
        batch_set_sys_conf ".*dn_thrift_max_frame_size=.*" "dn_thrift_max_frame_size=268435456"


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
            let fail_flag++
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
   if [ ${fail_flag} -gt 0 ]; then
       log "ERROR" "环境清理失败，终止启动流程"
#       exit 1
   fi

   # 配置节点
   set_conf
   if [ ${fail_flag} -gt 0 ]; then
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
      v_warnMessage="${v_warnMessage}${tc_desc} failed."

      cat ${cur_dir}/tmp.out
      echo "${v_warnMessage}"
      exit -1
   fi
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
   v_err11=`ssh ${os_user_name}@${line} "grep \"The memory cost to be released is larger\" ${db_dir}/logs/*datanode*all*|wc -l"`
   v_dn_total_err=$((v_err+v_err2+v_err3+v_err4+v_err5+v_err6+v_err7+v_err8+v_err9+v_err10+v_err11))
   if [[ ${v_npe} -gt 0 ]];then
           let fail_flag++
           v_warnMessage="${v_warnMessage}DN NPE."
           echo "DN ${line} NullPointer : ${v_npe}"
   fi
   if [[ ${v_dn_total_err} -gt 0 ]];then
	   let fail_flag++
           v_warnMessage="${v_warnMessage}DN unexp log."
	   echo "DN ${line} has error: ${v_dn_total_err}"
   fi
done

}
function wait_logs_sync_done()
{
local max_wait_time=${1:-120}
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "flush;">${cur_dir}/tmp.out
   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">${cur_dir}/tmp.out
   cat ${cur_dir}/tmp.out |grep Running|awk -F "|" '{gsub(" ","");print $4}'>${cur_dir}/tmp1.out
   mv ${cur_dir}/tmp1.out ${cur_dir}/tmp.out
   exec 3<${cur_dir}/tmp.out
   while read line<&3
   do
   while true
   do
   ssh ${os_user_name}@${line} "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep usr_sod">${cur_dir}/tmp1.out
   ssh ${os_user_name}@${line} "grep \"create a new\" ${db_dir}/logs/log_datanode_all.log|grep tod_sod">${cur_dir}/tmp2.out
   last_time_str1=$(tail -n 1 "${cur_dir}/tmp1.out" | awk -F',' '{print $1}')
   last_time_str2=$(tail -n 1 "${cur_dir}/tmp2.out" | awk -F',' '{print $1}')
   last_timestamp1=$(date -d "$last_time_str1" +%s 2>/dev/null)
   last_timestamp2=$(date -d "$last_time_str2" +%s 2>/dev/null)
   if [[ ${last_timestamp1} -gt ${last_timestamp2} ]];then
      last_timestamp=${last_timestamp1}
   else
      last_timestamp=${last_timestamp2}

   fi
current_timestamp=$(date +%s)

# 计算时间差（秒）
time_diff=$((current_timestamp - last_timestamp))
# 判断是否超过1分钟（120秒）
if [ $time_diff -gt ${max_wait_time} ]; then
    echo "最后一条日志距离现在已超过（${time_diff}秒）"
    break
else
    v_sleep=$((max_wait_time-time_diff+1))
    sleep ${v_sleep}
#    echo "最后一条日志距离现在（${time_diff}秒）"
fi
   done
   done

}
function check_dn_jps()
{
   local v_dn_ip=$1
   local max_wait_time=$2
local t1=`date +%s`
while true
do
   v_dn_str=`ssh ${os_user_name}@${v_dn_ip} "jps|grep DataNode"`
   v_dn_pid=`echo ${v_dn_str}|awk '{print $1}'`
   if [[ ${v_dn_pid} -gt 0 ]];then
      sleep 5
   else
      break
   fi
      t2=`date +%s`
      t_elp=$((t2-t1))
      if [[ ${t_elp} -gt ${max_wait_time} ]];then
         let fail_flag++
         echo "Stopping takes too long."
# kill -9
         ssh ${os_user_name}@${v_dn_ip} "kill -9 ${v_dn_pid}"
         break
      fi

done
}

function kill_cn_dn_jps()
{
   local v_shutdown_ip=$1
   local v_cn_str=`ssh ${os_user_name}@${v_shutdown_ip} "jps|grep ConfigNode"`
   local v_cn_pid=`echo ${v_cn_str}|awk '{print $1}'`
   local v_dn_str=`ssh ${os_user_name}@${v_shutdown_ip} "jps|grep DataNode"`
   local v_dn_pid=`echo ${v_dn_str}|awk '{print $1}'`

   echo "kill -9 CN/DN on ${v_shutdown_ip}: CN=${v_cn_pid}, DN=${v_dn_pid}"
   if [[ -n "${v_cn_pid}" ]]; then
      ssh ${os_user_name}@${v_shutdown_ip} "kill -9 ${v_cn_pid}"
   fi
   if [[ -n "${v_dn_pid}" ]]; then
      ssh ${os_user_name}@${v_shutdown_ip} "kill -9 ${v_dn_pid}"
   fi
}

get_current_sync_lag_summary() {
   local PROMETHEUS_URL
   local PROMETHEUS_USER
   local PROMETHEUS_PASS
   local dn_file="${nodeinfo_dir}/datanode.txt"
   local cluster_dn_file="${cur_dir}/cluster_running_datanodes.out"
   local response
   local instance_regex=""
   local ip
   local dn_list=()
   declare -A target_nodes=()

   PROMETHEUS_URL=$(get_verify_conf_value "monitor_url" "")
   if [[ -z "${PROMETHEUS_URL}" ]]; then
      PROMETHEUS_URL=$(grep '^monitor_url' "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
   fi
   PROMETHEUS_USER=$(get_verify_conf_value "monitor_user" "admin")
   PROMETHEUS_PASS=$(get_verify_conf_value "monitor_password" "admin")

   if [[ ! -f "${dn_file}" ]]; then
      return 1
   fi

   ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">"${cur_dir}/tmp.out" 2>/dev/null
   grep Running "${cur_dir}/tmp.out" | awk -F "|" '{gsub(" ","");print $4}' | sed '/^$/d' | sort -u > "${cluster_dn_file}"

   while read -r ip
   do
      [[ -z "${ip}" ]] && continue
      [[ "${ip}" =~ ^# ]] && continue
      if grep -qx "${ip}" "${cluster_dn_file}"; then
         dn_list+=("${ip}")
         target_nodes["${ip}"]=1
      fi
   done < "${dn_file}"

   if [[ ${#dn_list[@]} -eq 0 ]]; then
      return 1
   fi

   for ip in "${dn_list[@]}"
   do
      local promql_safe_ip=${ip//./[.]}
      [[ -n "${instance_regex}" ]] && instance_regex="${instance_regex}|"
      instance_regex="${instance_regex}${promql_safe_ip}(:[0-9]+)?"
   done
   instance_regex="^(${instance_regex})$"

   response=$(curl -s -u "${PROMETHEUS_USER}:${PROMETHEUS_PASS}" --get \
      --data-urlencode "query=sum(iot_consensus{instance=~\"${instance_regex}\",name=\"ioTConsensusServerImpl\",type=\"syncLag\"}) by (instance)" \
      "${PROMETHEUS_URL}/api/v1/query")

   if [[ $(echo "$response" | jq -r '.status') != "success" ]]; then
      return 1
   fi

   echo "$response" | jq -r '.data.result[] | "\(.metric.instance)|\(.value[1])"' | awk -F '|' '
      NF >= 2 {
         host = $1
         sub(/:.*/, "", host)
         value = $2 + 0
         sum += value
         cnt++
         if (cnt == 1 || value > maxv) {
            maxv = value
         }
      }
      END {
         if (cnt > 0) {
            printf "%.6f|%.6f|%d\n", sum, maxv, cnt
         } else {
            exit 1
         }
      }'
}

#  - 只检查 ${nodeinfo_dir}/datanode.txt 与当前集群 Running DN 的交集
#  - 缺失指标不退出，只持续等待
#  - syncLag > 0 持续存在时保留现场，不进入下个用例
#  - 缺失/恢复、非 0/恢复 0 只在状态变化时打印一次
#  - 轮询间隔改为 5 秒

  wait_for_monitor_sync_completion() {
      local PROMETHEUS_URL
      PROMETHEUS_URL=$(get_verify_conf_value "monitor_url" "")
      if [[ -z "${PROMETHEUS_URL}" ]]; then
          PROMETHEUS_URL=$(grep '^monitor_url' "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
      fi
      local PROMETHEUS_USER
      local PROMETHEUS_PASS
      local TARGET_DURATION
      local SLEEP_INTERVAL
      local RECOVERY_RATIO_THRESHOLD
      local BASELINE_TOTAL_MARGIN
      local BASELINE_PER_DN_MARGIN
      local STABLE_TOTAL_FLUCTUATION
      local STABLE_PER_DN_FLUCTUATION
      local BASELINE_TOTAL_LAG
      local BASELINE_MAX_LAG
      local dn_file="${nodeinfo_dir}/datanode.txt"
      local cluster_dn_file="${cur_dir}/cluster_running_datanodes.out"

      local stable_window_start_time=0
      local last_target_list_key=""
      local peak_total_lag=0
      local peak_max_lag=0
      local -a stable_sample_ts=()
      local -a stable_sample_total=()
      local -a stable_sample_max=()
      declare -A seen_nodes
      declare -A last_node_status
      declare -A missing_warned

      PROMETHEUS_USER=$(get_verify_conf_value "monitor_user" "admin")
      PROMETHEUS_PASS=$(get_verify_conf_value "monitor_password" "admin")
      TARGET_DURATION=$(get_verify_conf_value "sync_lag_stable_seconds" "300")
      SLEEP_INTERVAL=$(get_verify_conf_value "sync_lag_poll_seconds" "5")
      RECOVERY_RATIO_THRESHOLD=$(get_verify_conf_value "sync_lag_recovery_ratio" "0.8")
      BASELINE_TOTAL_MARGIN=$(get_verify_conf_value "sync_lag_total_margin" "$(get_verify_conf_value "sync_lag_near_zero_total_threshold" "10")")
      BASELINE_PER_DN_MARGIN=$(get_verify_conf_value "sync_lag_per_dn_margin" "$(get_verify_conf_value "sync_lag_near_zero_per_dn_threshold" "2")")
      STABLE_TOTAL_FLUCTUATION=$(get_verify_conf_value "sync_lag_stable_total_fluctuation" "5")
      STABLE_PER_DN_FLUCTUATION=$(get_verify_conf_value "sync_lag_stable_per_dn_fluctuation" "1")
      BASELINE_TOTAL_LAG=$(read_stage_marker "pre_fault_sync_lag_total")
      BASELINE_MAX_LAG=$(read_stage_marker "pre_fault_sync_lag_max")
      [[ -z "${BASELINE_TOTAL_LAG}" ]] && BASELINE_TOTAL_LAG=0
      [[ -z "${BASELINE_MAX_LAG}" ]] && BASELINE_MAX_LAG=0

      if [[ ! -f "$dn_file" ]]; then
          echo "错误: 找不到 $dn_file"
          return 1
      fi

      while true; do
          local now
          now=$(date +%s)

          ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show datanodes;">"${cur_dir}/tmp.out"
          grep Running "${cur_dir}/tmp.out" | awk -F "|" '{gsub(" ","");print $4}' | sed '/^$/d' | sort -u > "${cluster_dn_file}"

          local dn_list=()
          declare -A target_nodes=()
          while read -r dn_ip; do
              [[ -z "$dn_ip" ]] && continue
              [[ "$dn_ip" =~ ^# ]] && continue
              if grep -qx "$dn_ip" "${cluster_dn_file}"; then
                  dn_list+=("$dn_ip")
                  target_nodes["$dn_ip"]=1
              fi
          done < "$dn_file"

          local expected_count=${#dn_list[@]}
          if [[ "$expected_count" -eq 0 ]]; then
              stable_window_start_time=0
              stable_sample_ts=()
              stable_sample_total=()
              stable_sample_max=()
              echo "[$(date '+%F %T')] 等待中: show datanodes 未解析到当前集群 Running DN，跳过非集群节点后无可检查目标"
              sleep "${SLEEP_INTERVAL}"
              continue
          fi

          local target_list_key="${dn_list[*]}"
          if [[ "$target_list_key" != "$last_target_list_key" ]]; then
              echo "[$(date '+%F %T')] 开始监控 Total Sync Lag，仅检查当前集群中的 ${expected_count} 个 DataNode: ${target_list_key}"
              last_target_list_key="$target_list_key"
          fi

          local instance_regex=""
          local ip
          for ip in "${dn_list[@]}"; do
              local promql_safe_ip=${ip//./[.]}
              [[ -n "$instance_regex" ]] && instance_regex="${instance_regex}|"
              instance_regex="${instance_regex}${promql_safe_ip}(:[0-9]+)?"
          done
          instance_regex="^(${instance_regex})$"

          local query
          query="sum(iot_consensus{instance=~\"${instance_regex}\",name=\"ioTConsensusServerImpl\",type=\"syncLag\"}) by (instance)"

          local response
          response=$(curl -s -u "${PROMETHEUS_USER}:${PROMETHEUS_PASS}" --get \
              --data-urlencode "query=${query}" \
              "${PROMETHEUS_URL}/api/v1/query")

          if [[ $(echo "$response" | jq -r '.status') != "success" ]]; then
              echo "[$(date '+%F %T')] 错误: 无法从 Prometheus 获取数据"
              echo "响应: $response"
              stable_window_start_time=0
              stable_sample_ts=()
              stable_sample_total=()
              stable_sample_max=()
              sleep "${SLEEP_INTERVAL}"
              continue
          fi

          seen_nodes=()
          local matched_count=0
          local total_lag=0
          local max_lag=0
          local non_zero_nodes=()
          local missing_nodes=()

          while IFS='|' read -r instance sync_lag; do
              [[ -z "$instance" ]] && continue

              local instance_host="${instance%%:*}"
              [[ -z "${target_nodes[$instance_host]}" ]] && continue

              seen_nodes["$instance_host"]=1
              ((matched_count++))

              if [[ ${missing_warned[$instance_host]:-false} == "true" ]]; then
                  echo "[$(date '+%F %T')] INFO: 节点 ${instance_host} 的 syncLag 指标已恢复"
                  missing_warned["$instance_host"]="false"
              fi

              total_lag=$(awk -v total="${total_lag}" -v value="${sync_lag}" 'BEGIN {printf "%.6f", total + value}')
              max_lag=$(awk -v current_max="${max_lag}" -v value="${sync_lag}" 'BEGIN {if (value > current_max) printf "%.6f", value; else printf "%.6f", current_max}')
              if awk "BEGIN {exit !($sync_lag > 0.0001)}"; then
                  non_zero_nodes+=("${instance_host}=${sync_lag}")

                  if [[ ${last_node_status[$instance_host]:-false} != "true" ]]; then
                      echo "[$(date '+%F %T')] WARN: 节点 ${instance_host} 首次检测到 syncLag=${sync_lag}"
                  fi

                  last_node_status["$instance_host"]="true"
              else
                  if [[ ${last_node_status[$instance_host]:-false} == "true" ]]; then
                      echo "[$(date '+%F %T')] INFO: 节点 ${instance_host} 的 syncLag 已恢复为 0"
                  fi
                  last_node_status["$instance_host"]="false"
              fi
          done < <(
              echo "$response" | jq -r '.data.result[] | "\(.metric.instance)|\(.value[1])"'
          )

          for ip in "${dn_list[@]}"; do
              if [[ -z "${seen_nodes[$ip]:-}" ]]; then
                  missing_nodes+=("$ip")
                  if [[ ${missing_warned[$ip]:-false} != "true" ]]; then
                      echo "[$(date '+%F %T')] WARN: 节点 ${ip} 未查到 syncLag 指标"
                      missing_warned["$ip"]="true"
                  fi
              fi
          done

          if [[ ${#missing_nodes[@]} -gt 0 ]]; then
              stable_window_start_time=0
              stable_sample_ts=()
              stable_sample_total=()
              stable_sample_max=()
              echo "[$(date '+%F %T')] 等待中: 指标缺失 ${#missing_nodes[@]}/${expected_count}，缺失节点: ${missing_nodes[*]}"
              sleep "${SLEEP_INTERVAL}"
              continue
          fi

          peak_total_lag=$(awk -v peak="${peak_total_lag}" -v current="${total_lag}" 'BEGIN {if (current > peak) printf "%.6f", current; else printf "%.6f", peak}')
          peak_max_lag=$(awk -v peak="${peak_max_lag}" -v current="${max_lag}" 'BEGIN {if (current > peak) printf "%.6f", current; else printf "%.6f", peak}')

          local recovered_flag=0
          local allowed_total_lag
          local allowed_max_lag
          local total_recovery_ratio
          local max_recovery_ratio

          allowed_total_lag=$(awk -v base="${BASELINE_TOTAL_LAG}" -v peak="${peak_total_lag}" -v ratio="${RECOVERY_RATIO_THRESHOLD}" -v margin="${BASELINE_TOTAL_MARGIN}" '
              BEGIN {
                  extra = peak - base
                  residual = extra * (1 - ratio)
                  if (residual < margin) residual = margin
                  printf "%.6f", base + residual
              }')
          allowed_max_lag=$(awk -v base="${BASELINE_MAX_LAG}" -v peak="${peak_max_lag}" -v ratio="${RECOVERY_RATIO_THRESHOLD}" -v margin="${BASELINE_PER_DN_MARGIN}" '
              BEGIN {
                  extra = peak - base
                  residual = extra * (1 - ratio)
                  if (residual < margin) residual = margin
                  printf "%.6f", base + residual
              }')
          total_recovery_ratio=$(awk -v base="${BASELINE_TOTAL_LAG}" -v peak="${peak_total_lag}" -v current="${total_lag}" '
              BEGIN {
                  if (peak <= base) {
                      printf "1.000000"
                  } else {
                      printf "%.6f", (peak - current) / (peak - base)
                  }
              }')
          max_recovery_ratio=$(awk -v base="${BASELINE_MAX_LAG}" -v peak="${peak_max_lag}" -v current="${max_lag}" '
              BEGIN {
                  if (peak <= base) {
                      printf "1.000000"
                  } else {
                      printf "%.6f", (peak - current) / (peak - base)
                  }
              }')

          if awk -v total="${total_lag}" -v total_th="${allowed_total_lag}" -v maxv="${max_lag}" -v max_th="${allowed_max_lag}" 'BEGIN {exit !((total <= total_th) && (maxv <= max_th))}'; then
              recovered_flag=1
          fi

          if [[ ${recovered_flag} -eq 1 ]]; then
              stable_sample_ts+=("${now}")
              stable_sample_total+=("${total_lag}")
              stable_sample_max+=("${max_lag}")

              while [[ ${#stable_sample_ts[@]} -gt 0 && $(( now - stable_sample_ts[0] )) -gt ${TARGET_DURATION} ]]; do
                  stable_sample_ts=("${stable_sample_ts[@]:1}")
                  stable_sample_total=("${stable_sample_total[@]:1}")
                  stable_sample_max=("${stable_sample_max[@]:1}")
              done

              if [[ ${#stable_sample_ts[@]} -eq 0 ]]; then
                  continue
              fi

              stable_window_start_time=${stable_sample_ts[0]}
              local current_duration=$((now - stable_window_start_time))
              local total_fluctuation
              local max_fluctuation
              local window_total_min="${stable_sample_total[0]}"
              local window_total_max="${stable_sample_total[0]}"
              local window_max_min="${stable_sample_max[0]}"
              local window_max_max="${stable_sample_max[0]}"
              local idx

              for idx in "${!stable_sample_total[@]}"; do
                  if awk -v cur="${stable_sample_total[$idx]}" -v minv="${window_total_min}" 'BEGIN {exit !(cur < minv)}'; then
                      window_total_min="${stable_sample_total[$idx]}"
                  fi
                  if awk -v cur="${stable_sample_total[$idx]}" -v maxv="${window_total_max}" 'BEGIN {exit !(cur > maxv)}'; then
                      window_total_max="${stable_sample_total[$idx]}"
                  fi
                  if awk -v cur="${stable_sample_max[$idx]}" -v minv="${window_max_min}" 'BEGIN {exit !(cur < minv)}'; then
                      window_max_min="${stable_sample_max[$idx]}"
                  fi
                  if awk -v cur="${stable_sample_max[$idx]}" -v maxv="${window_max_max}" 'BEGIN {exit !(cur > maxv)}'; then
                      window_max_max="${stable_sample_max[$idx]}"
                  fi
              done

              total_fluctuation=$(awk -v maxv="${window_total_max}" -v minv="${window_total_min}" 'BEGIN {printf "%.6f", maxv - minv}')
              max_fluctuation=$(awk -v maxv="${window_max_max}" -v minv="${window_max_min}" 'BEGIN {printf "%.6f", maxv - minv}')

              if awk -v total_diff="${total_fluctuation}" -v total_th="${STABLE_TOTAL_FLUCTUATION}" -v max_diff="${max_fluctuation}" -v max_th="${STABLE_PER_DN_FLUCTUATION}" 'BEGIN {exit !((total_diff <= total_th) && (max_diff <= max_th))}'; then
                  echo "[$(date '+%F %T')] 接近完成: totalSyncLag=${total_lag}, maxSyncLag=${max_lag}, baselineTotal=${BASELINE_TOTAL_LAG}, baselineMax=${BASELINE_MAX_LAG}, peakTotal=${peak_total_lag}, peakMax=${peak_max_lag}, totalRecovery=${total_recovery_ratio}, maxRecovery=${max_recovery_ratio}, 稳定时长 ${current_duration}/${TARGET_DURATION} 秒"
                  if [[ "${current_duration}" -ge "${TARGET_DURATION}" ]]; then
                      echo "[$(date '+%F %T')] 同步完成: syncLag 已明显下降并形成稳定平台，totalSyncLag=${total_lag}, maxSyncLag=${max_lag}, totalRecovery=${total_recovery_ratio}, maxRecovery=${max_recovery_ratio}"
                      echo "最终 fail_flag=${fail_flag}, sync_fail_flag=${sync_fail_flag}"
                      return 0
                  fi
              else
                  echo "[$(date '+%F %T')] 已明显下降但仍波动: totalSyncLag=${total_lag}, maxSyncLag=${max_lag}, totalRecovery=${total_recovery_ratio}, maxRecovery=${max_recovery_ratio}, totalFluctuation=${total_fluctuation}, maxFluctuation=${max_fluctuation}"
              fi
          else
              stable_window_start_time=0
              stable_sample_ts=()
              stable_sample_total=()
              stable_sample_max=()
              echo "[$(date '+%F %T')] 等待中: totalSyncLag=${total_lag}, maxSyncLag=${max_lag}, baselineTotal=${BASELINE_TOTAL_LAG}, baselineMax=${BASELINE_MAX_LAG}, peakTotal=${peak_total_lag}, peakMax=${peak_max_lag}, totalRecovery=${total_recovery_ratio}, maxRecovery=${max_recovery_ratio}, allowedTotal<=${allowed_total_lag}, allowedPerDn<=${allowed_max_lag}, 非零节点: ${non_zero_nodes[*]}"
          fi

          sleep "${SLEEP_INTERVAL}"
      done
  }

function create_user()
{
	# database ttl 3 hours
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "CREATE DATABASE usr_sod0 WITH (ttl=10800000);">${cur_dir}/tmp.out
check_res success 1 "CREATE DATABASE with ttl "
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "CREATE DATABASE tod_sod0 WITH (ttl=10800000);">${cur_dir}/tmp.out
check_res success 1 "CREATE DATABASE with ttl "

${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  rainer 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  rainer"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  colder 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  colder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  winder 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  winder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sec_super_user} -e "CREATE USER  sunner 'TimechoDB@2021';">${cur_dir}/tmp.out
check_res success 1 "CREATE USER  sunner"
# grant privelege
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "GRANT ALL TO USER rainer;">${cur_dir}/tmp.out
check_res success 1 "grant USER  rainer"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "GRANT ALL TO USER colder;">${cur_dir}/tmp.out
check_res success 1 "grant USER  colder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "GRANT ALL TO USER winder;">${cur_dir}/tmp.out
check_res success 1 "grant USER  winder"
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -u ${v_sys_super_user} -sql_dialect table -e "GRANT ALL TO USER sunner;">${cur_dir}/tmp.out
check_res success 1 "grant USER  sunner"


}
function exec_jstack()
{
v_jstack_dir=${cur_dir}/${testdb}/jstack_result
mkdir -p ${v_jstack_dir}
datanode_file="${nodeinfo_dir}/datanode.txt"
confignode_file="${nodeinfo_dir}/confignode.txt"

dump_remote_process_debug() {
    local ip=$1
    local process_name=$2
    local outfile=$3

    ssh root@"${ip}" bash -s -- "${process_name}" > "${outfile}" 2>&1 <<'EOF'
process_name="$1"
pid=$(pgrep -f "${process_name}" | head -n1)

echo "==== ${process_name} Debug Info ===="
if [ -z "${pid}" ]; then
    echo "${process_name} pid not found"
    exit 0
fi

echo "pid: ${pid}"
echo "---- Established Peers ----"
peer_summary=$(ss -tunp state established 2>/dev/null \
    | awk -v pid="${pid}" '$0 ~ ("pid=" pid ",") {print $5}' \
    | rev | cut -d":" -f2- | rev \
    | grep -v -E '^(127\.|::1|\[::1\]|localhost)$' \
    | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
    | uniq -c)

if [ -n "${peer_summary}" ]; then
    echo "${peer_summary}"
else
    echo "no non-local established peers"
fi

echo
echo "---- Jstack ----"
jstack "${pid}"
EOF
}

time=$(date +%Y%m%d_%H%M%S)

echo "==== 开始批量抓取 jstack，结果保存在当前目录 ===="

# ===================== 处理 ConfigNode =====================
if [ -f "$confignode_file" ]; then
    echo -e "\n>>>> 开始处理 ConfigNode 节点 <<<<"
    for ip in $(cat "$confignode_file" | grep -v '^$'); do
	    v_ip=$(echo ${ip}|awk -F '.' '{print $4}')
        outfile="${v_cluster_num_info}_cn_ip${v_ip}_${v_jstack_num}_${time}_jstack.out"
        echo "节点 $ip -> 输出到 $outfile"

        dump_remote_process_debug "$ip" "ConfigNode" "${v_jstack_dir}/$outfile"
    done
fi

# ===================== 处理 DataNode =====================
if [ -f "$datanode_file" ]; then
    echo -e "\n>>>> 开始处理 DataNode 节点 <<<<"
    for ip in $(cat "$datanode_file" | grep -v '^$'); do
	    v_ip=$(echo ${ip}|awk -F '.' '{print $4}')
        outfile="${v_cluster_num_info}_dn_ip${v_ip}_${v_jstack_num}_${time}_jstack.out"
        echo "节点 $ip -> 输出到 $outfile"

        dump_remote_process_debug "$ip" "DataNode" "${v_jstack_dir}/$outfile"
    done
fi

echo -e "\n==== 全部完成！所有 jstack 文件已保存在当前目录 ===="
let v_jstack_num++
}
load_benchmark_ips() {
    bm_ips=()

    if [[ ! -f "${benchmark_ip_list_file}" ]]; then
        log "ERROR" "benchmark ip 列表不存在: ${benchmark_ip_list_file}"
        let fail_flag++
        return 1
    fi

    while read -r line
    do
        line=$(echo "${line}" | sed 's/[[:space:]]//g')
        if [[ -z "${line}" ]]; then
            continue
        fi
        case "${line}" in
            \#*) continue
                ;;
        esac
        bm_ips+=("${line}")
    done < "${benchmark_ip_list_file}"

    if [[ ${#bm_ips[@]} -eq 0 ]]; then
        log "ERROR" "benchmark ip 列表为空: ${benchmark_ip_list_file}"
        let fail_flag++
        return 1
    fi

    return 0
}

resolve_benchmark_ssh_user() {
    local host=$1

    if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@"${host}" "true" >/dev/null 2>&1; then
        echo "root"
        return 0
    fi

    if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@"${host}" "true" >/dev/null 2>&1; then
        echo "ubuntu"
        return 0
    fi

    return 1
}

run_benchmark_ssh() {
    local host=$1
    local remote_cmd=$2
    local ssh_user

    ssh_user=$(resolve_benchmark_ssh_user "${host}") || return 1
    ssh -o StrictHostKeyChecking=no "${ssh_user}@${host}" "${remote_cmd}"
}

start_benchmark_on_host() {
    local host=$1
    local conf_name=$2
    local log_suffix=$3
    local benchmark_result_interval_seconds

    benchmark_result_interval_seconds=$(get_verify_conf_value "benchmark_result_interval_seconds" "60")

    run_benchmark_ssh "${host}" "
source /etc/profile >/dev/null 2>&1 || true
mkdir -p '${bm_dir}/${testdb}' || exit 1
if [ ! -d '${bm_dir}/${bm_conf}/${conf_name}' ]; then
    echo 'missing benchmark conf: ${bm_dir}/${bm_conf}/${conf_name}' >&2
    exit 2
fi
conf_file='${bm_dir}/${bm_conf}/${conf_name}/config.properties'
if [ ! -f \"\$conf_file\" ]; then
    echo 'missing benchmark config.properties: '"\${conf_file}" >&2
    exit 4
fi
if grep -q '^START_TIME=' \"\$conf_file\"; then
    sed -i 's|^START_TIME=.*|START_TIME=${benchmark_start_time}|' \"\$conf_file\" || exit 5
else
    printf 'START_TIME=%s\n' '${benchmark_start_time}' >> \"\$conf_file\" || exit 5
fi
if grep -q '^RESULT_PRINT_INTERVAL=' \"\$conf_file\"; then
    sed -i 's|^RESULT_PRINT_INTERVAL=.*|RESULT_PRINT_INTERVAL=${benchmark_result_interval_seconds}|' \"\$conf_file\" || exit 6
else
    printf 'RESULT_PRINT_INTERVAL=%s\n' '${benchmark_result_interval_seconds}' >> \"\$conf_file\" || exit 6
fi
cd '${bm_dir}' || exit 1
nohup ./benchmark.sh -cf '${bm_dir}/${bm_conf}/${conf_name}' > '${bm_dir}/${testdb}/${v_testtime}_${log_suffix}.out' 2>&1 < /dev/null &
for i in 1 2 3 4 5 6 7 8 9 10
do
    if ps -ef | grep '[c]n.edu.tsinghua.iot.benchmark.App' | grep -F -- '${bm_dir}/${bm_conf}/${conf_name}' >/dev/null; then
        exit 0
    fi
    sleep 2
done
exit 3
"
}

get_benchmark_app_count() {
    local host=$1

    run_benchmark_ssh "${host}" "
ps -ef | grep '[c]n.edu.tsinghua.iot.benchmark.App' | grep -F -- '${bm_dir}/${bm_conf}/' | wc -l
"
}

check_benchmark_output_remote() {
    local host=$1
    local log_suffix=$2
    local bm_file="${bm_dir}/${testdb}/${v_testtime}_${log_suffix}.out"

    run_benchmark_ssh "${host}" "
bm_file='${bm_file}'

if [ ! -f \"\$bm_file\" ]; then
    echo 'STATUS=MISSING'
elif grep -q 'Test elapsed time (not include schema creation):' \"\$bm_file\" && grep -q 'Result Matrix' \"\$bm_file\"; then
    matrix_status=\$(awk '
        /Result Matrix/ {
            in_matrix=1
            header_seen=0
            row_count=0
            fail_count=0
            failed_rows=\"\"
            next
        }
        in_matrix && /^Operation[[:space:]]+okOperation[[:space:]]+okPoint[[:space:]]+failOperation[[:space:]]+failPoint/ {
            header_seen=1
            next
        }
        in_matrix && header_seen && /^-+$/ {
            last_row_count=row_count
            last_fail_count=fail_count
            last_failed_rows=failed_rows
            in_matrix=0
            next
        }
        in_matrix && header_seen && NF >= 5 {
            row_count++
            if ((\$4 + 0) > 0) {
                fail_count += (\$4 + 0)
                failed_rows = failed_rows \$0 ORS
            }
        }
        END {
            if (last_row_count == 0) {
                exit 2
            }
            if (last_fail_count > 0) {
                print \"FAILED\"
                printf \"%s\", last_failed_rows
            } else {
                print \"OK\"
            }
        }
    ' \"\$bm_file\")
    awk_rc=\$?
    if [ \${awk_rc} -eq 2 ]; then
        echo 'STATUS=INCOMPLETE'
        tail -n 20 \"\$bm_file\" 2>/dev/null
    elif [ \${awk_rc} -ne 0 ]; then
        echo 'STATUS=INCOMPLETE'
        tail -n 20 \"\$bm_file\" 2>/dev/null
    elif [ \"\$(echo \"\$matrix_status\" | head -n 1)\" = 'FAILED' ]; then
        echo 'STATUS=FAILED'
        echo \"\$matrix_status\" | tail -n +2
    else
        echo 'STATUS=OK'
    fi
else
    echo 'STATUS=INCOMPLETE'
    tail -n 20 \"\$bm_file\" 2>/dev/null
fi
"
}

extract_benchmark_last_result_remote() {
    local host=$1
    local log_suffix=$2
    local bm_file="${bm_dir}/${testdb}/${v_testtime}_${log_suffix}.out"

    run_benchmark_ssh "${host}" "
bm_file='${bm_file}'

if [ ! -f \"\$bm_file\" ]; then
    exit 2
fi

awk '
    /Result Matrix/ {
        capture=1
        saw_latency=0
        block=\$0 ORS
        next
    }
    capture {
        block = block \$0 ORS
        if (\$0 ~ /Latency \\(ms\\) Matrix/) {
            saw_latency=1
        } else if (saw_latency && \$0 ~ /^-+$/) {
            last_block = block
            capture=0
        }
    }
    END {
        if (length(last_block) > 0) {
            printf \"%s\", last_block
            exit 0
        }
        if (capture && length(block) > 0) {
            printf \"%s\", block
            exit 1
        }
        exit 3
    }
' \"\$bm_file\"
"
}

save_benchmark_last_result_local() {
    local host=$1
    local log_suffix=$2
    local host_safe
    local result_file
    local result_content
    local extract_rc

    mkdir -p "${benchmark_result_dir}"
    if [[ -z "${benchmark_result_summary_file}" ]]; then
        benchmark_result_summary_file="${benchmark_result_dir}/${v_testtime}_all_last_results.out"
    fi

    host_safe=$(echo "${host}" | tr '.:' '__')
    result_file="${benchmark_result_dir}/${v_testtime}_${host_safe}_${log_suffix}_last_result.out"

    result_content=$(extract_benchmark_last_result_remote "${host}" "${log_suffix}")
    extract_rc=$?

    if [[ ${extract_rc} -ne 0 && ${extract_rc} -ne 1 ]]; then
        log "ERROR" "提取 benchmark 最后一次结果失败: ${host} ${bm_dir}/${testdb}/${v_testtime}_${log_suffix}.out"
        return 1
    fi

    printf "%s\n" "${result_content}" > "${result_file}"
    {
        echo "===== host=${host} log=${log_suffix} source=${bm_dir}/${testdb}/${v_testtime}_${log_suffix}.out ====="
        cat "${result_file}"
        echo
    } >> "${benchmark_result_summary_file}"

    echo "==== benchmark last result: host=${host} log=${log_suffix} ===="
    cat "${result_file}"

    if [[ ${extract_rc} -eq 1 ]]; then
        log "WARN" "benchmark 最后一次结果未完整抓取，仅保存从最后一个 Result Matrix 到日志结尾: ${result_file}"
    else
        log "INFO" "benchmark 最后一次结果已保存到本机: ${result_file}"
    fi

    return 0
}

extract_benchmark_window_metric_remote() {
    local host=$1
    local log_suffix=$2
    local target_operation=$3
    local value_kind=$4
    local start_ts=$5
    local end_ts=$6
    local bm_file="${bm_dir}/${testdb}/${v_testtime}_${log_suffix}.out"

    run_benchmark_ssh "${host}" "
bm_file='${bm_file}'

if [ ! -f \"\$bm_file\" ]; then
    exit 0
fi

awk -v start_ts='${start_ts}' -v end_ts='${end_ts}' -v target_op='${target_operation}' -v value_kind='${value_kind}' '
    function to_epoch(ts, arr) {
        split(ts, arr, /[-: ,]/)
        return mktime(arr[1] \" \" arr[2] \" \" arr[3] \" \" arr[4] \" \" arr[5] \" \" arr[6])
    }
    function flush_block() {
        if (block_ts < start_ts || block_ts > end_ts) {
            return
        }
        if (value_kind == \"throughput\" && throughput_value != \"\") {
            print block_ts \"|\" throughput_value
        } else if (value_kind == \"latency\" && latency_value != \"\") {
            print block_ts \"|\" latency_value
        }
    }
    /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} INFO .*The test is in progress\\. The current test result is:/ {
        block_ts = to_epoch(substr(\$0, 1, 19))
        in_result = 0
        in_latency = 0
        result_header_seen = 0
        latency_header_seen = 0
        throughput_value = \"\"
        latency_value = \"\"
        next
    }
    /Result Matrix/ {
        in_result = 1
        result_header_seen = 0
        next
    }
    in_result && /^Operation[[:space:]]+okOperation[[:space:]]+okPoint[[:space:]]+failOperation[[:space:]]+failPoint/ {
        result_header_seen = 1
        next
    }
    in_result && result_header_seen && /^-+$/ {
        in_result = 0
        next
    }
    in_result && result_header_seen && \$1 == target_op {
        throughput_value = \$(NF) + 0
        next
    }
    /Latency \\(ms\\) Matrix/ {
        in_latency = 1
        latency_header_seen = 0
        next
    }
    in_latency && /^Operation[[:space:]]+AVG[[:space:]]+MIN/ {
        latency_header_seen = 1
        next
    }
    in_latency && latency_header_seen && /^-+$/ {
        flush_block()
        in_latency = 0
        latency_header_seen = 0
        throughput_value = \"\"
        latency_value = \"\"
        next
    }
    in_latency && latency_header_seen && \$1 == target_op {
        latency_value = \$2 + 0
        next
    }
' \"\$bm_file\"
"
}

benchmark_window_metric_stats() {
    local log_suffix_csv=$1
    local target_operation=$2
    local value_kind=$3
    local start_ts=$4
    local end_ts=$5
    local sample_file=$6
    local host
    local log_suffix
    local sample_ts
    local sample_value
    local suffix_arr=()

    load_benchmark_ips || return 1
    IFS=',' read -r -a suffix_arr <<< "${log_suffix_csv}"
    : > "${sample_file}"

    for host in "${bm_ips[@]}"
    do
        for log_suffix in "${suffix_arr[@]}"
        do
            while IFS='|' read -r sample_ts sample_value
            do
                if [[ -z "${sample_ts}" || -z "${sample_value}" ]]; then
                    continue
                fi
                printf "%s|%s|%s|%s\n" "${host}" "${log_suffix}" "${sample_ts}" "${sample_value}" >> "${sample_file}"
            done < <(extract_benchmark_window_metric_remote "${host}" "${log_suffix}" "${target_operation}" "${value_kind}" "${start_ts}" "${end_ts}")
        done
    done

    awk -F '|' '
        NF >= 4 {
            sum += $4
            cnt++
        }
        END {
            if (cnt > 0) {
                printf "%.6f|%d\n", sum / cnt, cnt
            } else {
                exit 1
            }
        }' "${sample_file}"
}

report_benchmark_stage_result() {
    local stage_label=$1
    local metric_key=$2
    local metric_name=$3
    local display_unit=$4
    local log_suffix_csv=$5
    local target_operation=$6
    local value_kind=$7
    local baseline_start_ts=$8
    local baseline_end_ts=$9
    local stage_start_ts=${10}
    local stage_end_ts=${11}
    local allowed_delta_percent=${12}
    local baseline_sample_file="${monitor_stage_dir}/${stage_label}_${metric_key}_baseline_samples.out"
    local stage_sample_file="${monitor_stage_dir}/${stage_label}_${metric_key}_stage_samples.out"
    local baseline_stats
    local stage_stats
    local baseline_value
    local stage_value
    local baseline_count
    local stage_count
    local delta_percent
    local judge_result

    baseline_stats=$(benchmark_window_metric_stats "${log_suffix_csv}" "${target_operation}" "${value_kind}" "${baseline_start_ts}" "${baseline_end_ts}" "${baseline_sample_file}")
    stage_stats=$(benchmark_window_metric_stats "${log_suffix_csv}" "${target_operation}" "${value_kind}" "${stage_start_ts}" "${stage_end_ts}" "${stage_sample_file}")

    if [[ -z "${baseline_stats}" || -z "${stage_stats}" ]]; then
        log "WARN" "[${stage_label}] ${metric_name}: N/A (benchmark 周期结果为空)"
        return 1
    fi

    baseline_value=${baseline_stats%%|*}
    baseline_count=${baseline_stats##*|}
    stage_value=${stage_stats%%|*}
    stage_count=${stage_stats##*|}
    delta_percent=$(calc_delta_percent "${baseline_value}" "${stage_value}")
    judge_result=$(judge_metric_with_baseline "${baseline_value}" "${stage_value}" "${allowed_delta_percent}")

    log "INFO" "[${stage_label}] ${metric_name}: baseline=${baseline_value}${display_unit}, current=${stage_value}${display_unit}, baseline_samples=${baseline_count}, current_samples=${stage_count}, delta=${delta_percent}%, threshold=${allowed_delta_percent}%, result=${judge_result}"
    log "INFO" "[${stage_label}] ${metric_name} sample files: baseline=${baseline_sample_file}, current=${stage_sample_file}"
    if [[ "${judge_result}" != "PASS" ]]; then
        let fail_flag++
    fi
}

function start_bm()
{
    local v_bm_time
    load_benchmark_ips || return 1

    if [[ -z "${benchmark_start_time}" ]]; then
        log "ERROR" "benchmark_start_time 为空，未检测到测试开始时间"
        let fail_flag++
        return 1
    fi

    v_bm_time=$(date +%Y%m%d_%H%M%S)
    v_testtime="${testdb}_${v_cluster_num_info}_${v_bm_time}"
    arg="${v_testtime}"

    log "INFO" "开始启动 benchmark，bm_conf=${bm_conf}，benchmark_ip=${bm_ips[*]}，统一 START_TIME=${benchmark_start_time}"

    for host in "${bm_ips[@]}"
    do
        if start_benchmark_on_host "${host}" "conf_w" "bmw"; then
            log "INFO" "写 benchmark 已启动: ${host} -> ${bm_dir}/${testdb}/${v_testtime}_bmw.out"
        else
            log "ERROR" "写 benchmark 启动失败: ${host}"
            let fail_flag++
            return 1
        fi
    done

    log "INFO" "全部写 benchmark 已启动，等待 60 秒后启动只读 benchmark"
    sleep 60

    for host in "${bm_ips[@]}"
    do
        if start_benchmark_on_host "${host}" "conf_r1" "bmr1"; then
            log "INFO" "只读 benchmark-1 已启动: ${host} -> ${bm_dir}/${testdb}/${v_testtime}_bmr1.out"
        else
            log "ERROR" "只读 benchmark-1 启动失败: ${host}"
            let fail_flag++
            return 1
        fi

        if start_benchmark_on_host "${host}" "conf_r2" "bmr2"; then
            log "INFO" "只读 benchmark-2 已启动: ${host} -> ${bm_dir}/${testdb}/${v_testtime}_bmr2.out"
        else
            log "ERROR" "只读 benchmark-2 启动失败: ${host}"
            let fail_flag++
            return 1
        fi
    done

    log "INFO" "15 个 benchmark 已提交完成，统一 v_testtime=${v_testtime}"
}
function check_bm()
{
    local alive_total
    local host
    local host_alive
    local bm_status_output
    local status_line
    local bm_check_failed=0
    local log_suffix

    load_benchmark_ips || return 1

    if [[ -z "${v_testtime}" ]]; then
        log "ERROR" "v_testtime 为空，未检测到已启动的 benchmark 任务"
        let fail_flag++
        return 1
    fi

    mkdir -p "${benchmark_result_dir}"
    benchmark_result_summary_file="${benchmark_result_dir}/${v_testtime}_all_last_results.out"
    : > "${benchmark_result_summary_file}"

    while true
    do
        alive_total=0
        log "INFO" "开始检查 benchmark ip 上的 App 进程"

        for host in "${bm_ips[@]}"
        do
            host_alive=$(get_benchmark_app_count "${host}")
            if [ $? -ne 0 ]; then
                log "ERROR" "检查 benchmark App 进程失败: ${host}"
                let fail_flag++
                return 1
            fi
            host_alive=$(echo "${host_alive}" | tail -n 1 | tr -d '[:space:]')
            if [[ -z "${host_alive}" ]]; then
                host_alive=0
            fi
            alive_total=$((alive_total + host_alive))
            log "INFO" "benchmark host ${host} App 进程数: ${host_alive}"
        done

        if [[ ${alive_total} -eq 0 ]]; then
            log "INFO" "benchmark App 进程已全部结束，开始检查输出日志"
            break
        fi

        log "INFO" "benchmark 仍在运行，总 App 进程数: ${alive_total}"
        sleep 300
    done

    for host in "${bm_ips[@]}"
    do
        for log_suffix in bmw bmr1 bmr2
        do
            bm_status_output=$(check_benchmark_output_remote "${host}" "${log_suffix}")
            if [ $? -ne 0 ]; then
                log "ERROR" "检查 benchmark 日志失败: ${host} ${log_suffix}"
                let fail_flag++
                return 1
            fi

            status_line=$(echo "${bm_status_output}" | head -n 1)
            if [[ "${status_line}" = "STATUS=OK" || "${status_line}" = "STATUS=FAILED" ]]; then
                if ! save_benchmark_last_result_local "${host}" "${log_suffix}"; then
                    let v_warnNum++
                    v_warnMessage="${v_warnMessage}benchmark ${host} ${log_suffix} last result export failed."
                fi
            fi
            case "${status_line}" in
                STATUS=OK)
                    log "INFO" "benchmark 日志检查通过: ${host} ${bm_dir}/${testdb}/${v_testtime}_${log_suffix}.out"
                    ;;
                STATUS=FAILED)
                    log "ERROR" "benchmark 日志中存在失败操作: ${host} ${bm_dir}/${testdb}/${v_testtime}_${log_suffix}.out"
                    echo "${bm_status_output}" | tail -n +2
                    v_warnMessage="${v_warnMessage}benchmark ${host} ${log_suffix} has failed operations."
                    let fail_flag++
                    bm_check_failed=1
                    ;;
                STATUS=MISSING)
                    log "ERROR" "benchmark 输出日志不存在: ${host} ${bm_dir}/${testdb}/${v_testtime}_${log_suffix}.out"
                    v_warnMessage="${v_warnMessage}benchmark ${host} ${log_suffix} output missing."
                    let fail_flag++
                    bm_check_failed=1
                    ;;
                *)
                    log "ERROR" "benchmark 输出日志未正常结束: ${host} ${bm_dir}/${testdb}/${v_testtime}_${log_suffix}.out"
                    echo "${bm_status_output}" | tail -n +2
                    v_warnMessage="${v_warnMessage}benchmark ${host} ${log_suffix} output incomplete."
                    let fail_flag++
                    bm_check_failed=1
                    ;;
            esac
        done
    done

    if [[ ${bm_check_failed} -gt 0 ]]; then
        return 1
    fi

    log "INFO" "15 个 benchmark 已全部执行完成，且最后一次 Result Matrix 未发现失败操作"
    log "INFO" "benchmark 最后一次结果汇总文件: ${benchmark_result_summary_file}"
    return 0
}
function start_cn_dn()
{
	v_start_ip1=$1
	v_start_ip2=$2
	sleep 3600
	local v_restart_start_ts=$(date +%s)
	local v_start_timestamp=$(date +'%Y_%m_%d_%H_%M_%S')
	write_stage_marker "restart_start_ts" "${v_restart_start_ts}"
	capture_region_balance_snapshot "stage1"
	echo "restart ${v_shutdown_ip1} ${v_shutdown_ip2} at ${v_stop_timestamp}"
	ssh ${os_user_name}@${v_start_ip1} "source /etc/profile; nohup ${cn_db_dir}/sbin/start-confignode.sh -H ${cn_db_dir}/cn_${v_start_timestamp}_heapdump.hprof > /dev/null 2>&1 &"
	sleep 5
	ssh ${os_user_name}@${v_start_ip2} "source /etc/profile; nohup ${cn_db_dir}/sbin/start-confignode.sh -H ${cn_db_dir}/cn_${v_start_timestamp}_heapdump.hprof > /dev/null 2>&1 &"
	sleep 5
	ssh ${os_user_name}@${v_start_ip1} "source /etc/profile; nohup ${db_dir}/sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_timestamp}_heapdump.hprof > /dev/null 2>&1 &"
	sleep 5
	ssh ${os_user_name}@${v_start_ip2} "source /etc/profile; nohup ${db_dir}/sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_timestamp}_heapdump.hprof > /dev/null 2>&1 &"
	sleep 3
	while true
	do
		v_cur_node_num=$(${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show cluster;"|grep Running|wc -l)
		if [[ ${v_cur_node_num} = ${total_node_num} ]];then
			echo "restart successfully."
			write_stage_marker "restart_ready_ts" "$(date +%s)"
			break
		else
			sleep 3
		fi
	done

        # exec jstack
	echo "after restart exec jstack $(date +'%Y-%m-%d %H:%M:%S')"
	exec_jstack

}
function testcase()
{
	create_user
	start_bm
	print_verification_expectations
	for i in {1..6}
	do

                sleep 3600	
		exec_jstack
		if [[ ${i} = 3 ]];then
                log "INFO" "进入阶段1：宕机模拟，准备 kill -9 CN / DN pid"
                ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show confignodes;"|grep Leader|awk -F '|' '{gsub(" ","");print $4}'>${cur_dir}/tmp.out
                ${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show confignodes;"|grep Follower|head -1|awk -F '|' '{gsub(" ","");print $4}'>>${cur_dir}/tmp.out
		v_shutdown_ip1=$(head -1 ${cur_dir}/tmp.out)
		v_shutdown_ip2=$(tail -1 ${cur_dir}/tmp.out)
		local v_stop_timestamp=$(date +'%Y-%m-%d %H:%M:%S')
		local sync_lag_summary
		sync_lag_summary=$(get_current_sync_lag_summary)
		if [[ -n "${sync_lag_summary}" ]]; then
			write_stage_marker "pre_fault_sync_lag_total" "${sync_lag_summary%%|*}"
			local sync_lag_rest=${sync_lag_summary#*|}
			write_stage_marker "pre_fault_sync_lag_max" "${sync_lag_rest%%|*}"
			log "INFO" "故障前 sync lag 基线: total=${sync_lag_summary%%|*}, max=${sync_lag_rest%%|*}"
		else
			log "WARN" "故障前 sync lag 基线获取失败，将退化为相对 0 判断"
		fi
		write_stage_marker "fault_start_ts" "$(date +%s)"
		echo "kill -9 CN/DN PID on ${v_shutdown_ip1} ${v_shutdown_ip2} at ${v_stop_timestamp}"
                kill_cn_dn_jps ${v_shutdown_ip1}
                kill_cn_dn_jps ${v_shutdown_ip2}
	        sleep 10
	        exec_jstack
                log "INFO" "进入阶段2：重启恢复期间，开始拉起 CN / DN"
		start_cn_dn ${v_shutdown_ip1} ${v_shutdown_ip2} &
		fi
	done
	log "INFO" "进入阶段2：等待因重启导致的 sync lag 大体完成"
	wait_for_monitor_sync_completion
	write_stage_marker "sync_complete_ts" "$(date +%s)"
	capture_region_balance_snapshot "stage2"
	log "INFO" "进入阶段3：sync lag 已大体完成，继续观察直到 benchmark 完成"
	check_bm
	write_stage_marker "benchmark_end_ts" "$(date +%s)"
	capture_region_balance_snapshot "stage3"
	wait_logs_sync_done 120
	generate_stage_monitor_report
 #check cluster status
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show cluster;">${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out
check_res Running ${total_node_num} "show cluster expect ${total_node_num} Running but "
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -e "show regions;">${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out
${cli_dir}/sbin/start-cli.sh -u ${db_user_name} ${ssl_str} -h ${query_ip} -sql_dialect table -e "show regions;">${cur_dir}/tmp.out
cat ${cur_dir}/tmp.out

	# stop cluster
        sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
	check_log
	#backup logs
        v_tc_name_pre=`echo ${SCRIPT_NAME}|awk -F '.' '{print $1}'`
        v_backup_time=`date +"%Y_%m_%d_%H_%M_%S"`
sh -x ${clean_env_dir}/backup_cluster_logs.sh ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
sh -x ${clean_env_dir}/backup_cluster_cn_data ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1
}
# start cluster 
echo "">${log_file}
#while true
#do
#       v_last_test=$(ps -ef | grep tc2026_5c20d_ttl_now_kill_LoadBalance.sh| grep -v grep | wc -l)
#       if [[ ${v_last_test} -gt 0 ]];then
#               sleep 300
#       else
#               echo "last test finish."
#               break
#       fi
#done
#sleep 300

start_db
exec_jstack
# start test time
v_start_test_time=`date +%s`
write_stage_marker "benchmark_start_ts" "${v_start_test_time}"
benchmark_start_time=$(date -d "@${v_start_test_time}" '+%Y-%m-%dT%H:%M:%S%:z')
testcase
v_end_test_time=`date +%s`
v_elp_time=$((v_end_test_time-v_start_test_time))
# record test result
function write_result()
{
   v_result_iotdb_ip=$(grep ^test_result_iotdb_ip "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
   v_bm_max_value=0

   v_bm_sum_value=0
   sum_fail_flag=${fail_flag}
   if [[ ${fail_flag} -gt 0 ]];then
#           ${cli_dir}/sbin/start-cli.sh -h ${v_result_iotdb_ip} -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','FAIL',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
           echo "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','FAIL',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
 
           echo "test fail"
   else
           echo "test pass"
#           ${cli_dir}/sbin/start-cli.sh -h ${v_result_iotdb_ip} -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','PASS',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
           echo "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage)values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','PASS',${v_elp_time},${v_bm_max_value},${v_bm_sum_value},${v_warnNum},'${v_warnMessage}');"
 

backup_log_flag=1
   fi

# backup logs?
if [[ ${backup_log_flag} -gt 0 ]];then
# stop cluster
v_tc_name_pre=`echo ${SCRIPT_NAME}|awk -F '.' '{print $1}'`
v_backup_time=`date +"%Y_%m_%d_%H_%M_%S"`
#sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1
sh -x ${clean_env_dir}/backup_cluster_logs.sh ${v_tc_name_pre}_${v_backup_time}>> "${log_file}" 2>&1

fi

}
write_result
