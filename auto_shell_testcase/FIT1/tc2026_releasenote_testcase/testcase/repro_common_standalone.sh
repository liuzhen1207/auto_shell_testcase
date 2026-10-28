#!/bin/bash

repro_common_init() {
  cur_dir=$1
  SCRIPT_NAME=$2
  conf_file="${cur_dir}/../conf/test.conf"
  nodeinfo_dir="${cur_dir}/../conf"
  clean_env_dir="${cur_dir}/../clean_env"
  prepare_env_dir="${cur_dir}/../prepare_env"

  os_user_name=$(grep '^os_user_name' "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
  testdb=$(grep '^v_testdb' "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
  db_parent_dir=$(grep '^v_db_parent_dir' "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
  cli_dir="${db_parent_dir}/${testdb}"
  db_dir="${db_parent_dir}/${testdb}"

  db_sys_admin=root
  db_sys_pw=TimechoDB@2021
  cn_num=1
  dn_num=4
  dr_rep_num=2
  sr_rep_num=3
  total_node_num=$((cn_num + dn_num))
  internal_rpc_timeout_ms=360000
  migration_default_bps=50331648
  migration_default_concurrency=0
}

log() {
  local level=$1
  local msg=$2
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${log_file}"
}

set_config_value() {
  local config_file=$1
  local key=$2
  local value=$3

  if grep -q "^${key}=" "${config_file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|g" "${config_file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${config_file}"
  fi
}

init_node_files() {
  cp -f "${nodeinfo_dir}/confignode_1c.txt" "${nodeinfo_dir}/confignode.txt"
  cp -f "${nodeinfo_dir}/datanode_4d.txt" "${nodeinfo_dir}/datanode.txt"
  seed_cn_ip="$(head -1 "${nodeinfo_dir}/confignode.txt" | sed 's/ //g'):10710"
  query_ip="$(head -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')"
  target_ip="$(tail -1 "${nodeinfo_dir}/datanode.txt" | sed 's/ //g')"
}

run_cli_sql() {
  local host=$1
  local dialect=$2
  local sql=$3
  local outfile=$4
  local timeout_sec=${5:-3600}

  if [[ "${dialect}" = "table" ]]; then
    "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${db_sys_pw}" -h "${host}" -sql_dialect table -timeout "${timeout_sec}" -e "${sql}" > "${outfile}" 2>&1
  else
    "${cli_dir}/sbin/start-cli.sh" -u "${db_sys_admin}" -pw "${db_sys_pw}" -h "${host}" -timeout "${timeout_sec}" -e "${sql}" > "${outfile}" 2>&1
  fi
}

refresh_show_datanodes() {
  local host
  while read -r host; do
    [[ -z "${host}" ]] && continue
    if run_cli_sql "${host}" table "show datanodes;" "${cur_dir}/show_datanodes.out" 3600; then
      if ! grep -Eq "Exception|ERROR|error" "${cur_dir}/show_datanodes.out"; then
        return 0
      fi
    fi
  done < "${nodeinfo_dir}/datanode.txt"
  return 1
}

extract_running_datanodes() {
  awk -F '|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    $0 ~ /Running/ {
      ip = trim($4)
      if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
        print ip
      }
    }
  ' "${cur_dir}/show_datanodes.out"
}

get_datanode_id_by_ip() {
  local dn_ip=$1
  refresh_show_datanodes
  awk -F '|' -v dn_ip="${dn_ip}" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    $0 ~ /^\|/ {
      ip = trim($4)
      if (ip == dn_ip) {
        print trim($2)
        exit
      }
    }
  ' "${cur_dir}/show_datanodes.out"
}

wait_running_datanode_count() {
  local expected_count=$1
  local timeout_sec=${2:-1800}
  local start_ts
  start_ts=$(date +%s)
  while true; do
    refresh_show_datanodes
    if [[ $(extract_running_datanodes | wc -l) -eq ${expected_count} ]]; then
      return 0
    fi
    if (( $(date +%s) - start_ts > timeout_sec )); then
      return 1
    fi
    sleep 10
  done
}

wait_datanode_running() {
  local dn_ip=$1
  local timeout_sec=${2:-1800}
  local start_ts
  start_ts=$(date +%s)
  while true; do
    refresh_show_datanodes
    if grep "${dn_ip}" "${cur_dir}/show_datanodes.out" | grep -qi Running; then
      return 0
    fi
    if (( $(date +%s) - start_ts > timeout_sec )); then
      return 1
    fi
    sleep 10
  done
}

wait_datanode_absent() {
  local dn_ip=$1
  local timeout_sec=${2:-1800}
  local start_ts
  start_ts=$(date +%s)
  while true; do
    refresh_show_datanodes
    if ! grep -q "${dn_ip}" "${cur_dir}/show_datanodes.out"; then
      return 0
    fi
    if (( $(date +%s) - start_ts > timeout_sec )); then
      return 1
    fi
    sleep 10
  done
}

wait_jps_gone() {
  local dn_ip=$1
  local timeout_sec=${2:-300}
  local start_ts
  start_ts=$(date +%s)
  while true; do
    if ssh "${os_user_name}@${dn_ip}" "jps | grep -i DataNode | wc -l" | tr -d '[:space:]' | grep -q '^0$'; then
      return 0
    fi
    if (( $(date +%s) - start_ts > timeout_sec )); then
      return 1
    fi
    sleep 5
  done
}

set_sys_conf_remote() {
  local node_ip=$1
  local search_str=$2
  local content=$3

  ssh "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
file="${db_dir}/conf/iotdb-system.properties"
if grep -q "${search_str}" "\${file}"; then
  sed -i "s|${search_str}|${content}|g" "\${file}"
else
  echo "${content}" >> "\${file}"
fi
EOF
}

configure_confignode() {
  local node_ip=$1
  log "INFO" "configure confignode ${node_ip}"
  ssh "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="2G"/g' ${db_dir}/conf/confignode-env.sh
sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="1G"/g' ${db_dir}/conf/confignode-env.sh
EOF
  set_sys_conf_remote "${node_ip}" ".*cn_seed_config_node=.*" "cn_seed_config_node=${seed_cn_ip}"
  set_sys_conf_remote "${node_ip}" ".*cn_internal_address=.*" "cn_internal_address=${node_ip}"
  set_sys_conf_remote "${node_ip}" ".*cn_metric_reporter_list=.*" "cn_metric_reporter_list=PROMETHEUS"
  set_sys_conf_remote "${node_ip}" ".*cn_metric_prometheus_reporter_port=.*" "cn_metric_prometheus_reporter_port=9081"
  set_sys_conf_remote "${node_ip}" ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
  set_sys_conf_remote "${node_ip}" ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
  set_sys_conf_remote "${node_ip}" ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
  set_sys_conf_remote "${node_ip}" ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.IoTConsensus"
  set_sys_conf_remote "${node_ip}" ".*time_partition_interval=.*" "time_partition_interval=3600000"
  set_sys_conf_remote "${node_ip}" ".*ttl_check_interval=.*" "ttl_check_interval=600000"
  set_sys_conf_remote "${node_ip}" ".*cn_connection_timeout_ms=.*" "cn_connection_timeout_ms=${internal_rpc_timeout_ms}"
}

configure_datanode() {
  local node_ip=$1
  local bad_disk_ip
  bad_disk_ip=$(tail -1 "${nodeinfo_dir}/datanode_4d.txt" | sed 's/ //g')
  log "INFO" "configure datanode ${node_ip}"
  ssh "${os_user_name}@${node_ip}" bash -s <<EOF >> "${log_file}" 2>&1
sed -i 's/#ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY="20G"/g' ${db_dir}/conf/datanode-env.sh
sed -i 's/#OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY="4G"/g' ${db_dir}/conf/datanode-env.sh
EOF
  set_sys_conf_remote "${node_ip}" ".*dn_seed_config_node=.*" "dn_seed_config_node=${seed_cn_ip}"
  set_sys_conf_remote "${node_ip}" ".*dn_internal_address=.*" "dn_internal_address=${node_ip}"
  set_sys_conf_remote "${node_ip}" ".*dn_rpc_address=.*" "dn_rpc_address=${node_ip}"
  set_sys_conf_remote "${node_ip}" ".*dn_metric_reporter_list=.*" "dn_metric_reporter_list=PROMETHEUS"
  set_sys_conf_remote "${node_ip}" ".*dn_metric_prometheus_reporter_port=.*" "dn_metric_prometheus_reporter_port=9091"
  set_sys_conf_remote "${node_ip}" ".*schema_replication_factor=.*" "schema_replication_factor=${sr_rep_num}"
  set_sys_conf_remote "${node_ip}" ".*data_replication_factor=.*" "data_replication_factor=${dr_rep_num}"
  set_sys_conf_remote "${node_ip}" ".*enable_auto_repair_compaction=.*" "enable_auto_repair_compaction=false"
  set_sys_conf_remote "${node_ip}" ".*data_region_consensus_protocol_class=.*" "data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.IoTConsensus"
  set_sys_conf_remote "${node_ip}" ".*time_partition_interval=.*" "time_partition_interval=3600000"
  set_sys_conf_remote "${node_ip}" ".*ttl_check_interval=.*" "ttl_check_interval=600000"
  set_sys_conf_remote "${node_ip}" ".*dn_connection_timeout_ms=.*" "dn_connection_timeout_ms=${internal_rpc_timeout_ms}"
  set_sys_conf_remote "${node_ip}" ".*query_timeout_threshold=.*" "query_timeout_threshold=${internal_rpc_timeout_ms}"

  if [[ "${node_ip}" = "${bad_disk_ip}" ]]; then
    set_sys_conf_remote "${node_ip}" ".*dn_data_dirs=.*" "dn_data_dirs=data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data"
    set_sys_conf_remote "${node_ip}" ".*dn_wal_dirs=.*" "dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal"
  else
    set_sys_conf_remote "${node_ip}" ".*dn_data_dirs=.*" "dn_data_dirs=data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data,/data3/iotdb_data/${testdb}/data/datanode/data"
    set_sys_conf_remote "${node_ip}" ".*dn_wal_dirs=.*" "dn_wal_dirs=data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal,/data3/iotdb_data/${testdb}/data/datanode/wal"
  fi
}

set_conf() {
  local line
  while read -r line; do
    [[ -n "${line}" ]] && configure_confignode "${line}"
  done < "${nodeinfo_dir}/confignode.txt"

  while read -r line; do
    [[ -n "${line}" ]] && configure_datanode "${line}"
  done < "${nodeinfo_dir}/datanode.txt"
}

clean_env() {
  log "INFO" "clean env"
  sh -x "${clean_env_dir}/stop_cluster.sh" >> "${log_file}" 2>&1 || true
  sh -x "${clean_env_dir}/clean_cluster.sh" >> "${log_file}" 2>&1
  sh -x "${clean_env_dir}/reset_conf.sh" >> "${log_file}" 2>&1
  if [[ -x "${clean_env_dir}/clear_cache.sh" ]]; then
    sh -x "${clean_env_dir}/clear_cache.sh" >> "${log_file}" 2>&1 || true
  fi
}

start_db() {
  init_node_files
  clean_env
  set_conf
  log "INFO" "start cluster"
  sh -x "${prepare_env_dir}/start_cluster_v20.sh" "1" "${total_node_num}" >> "${log_file}" 2>&1
  wait_running_datanode_count "${dn_num}" 1800
}

join_running_hosts_csv() {
  refresh_show_datanodes
  extract_running_datanodes | paste -sd, -
}

join_running_ports_csv() {
  local count
  count=$(refresh_show_datanodes; extract_running_datanodes | wc -l)
  awk -v n="${count}" 'BEGIN { for (i = 1; i <= n; i++) { printf("%s6667", i == 1 ? "" : ",") } }'
}

prepare_benchmark_conf_dir() {
  local template_dir=$1
  local conf_dir=$2
  local db_name=$3
  local bm_test_ms=$4
  local bm_loop=$5
  local bm_batch_size=$6
  local bm_device_num_per_write=$7
  local bm_device_number=$8
  local bm_data_client_number=$9
  local start_time_str=${10}
  local host_csv port_csv

  rm -rf "${conf_dir}"
  mkdir -p "$(dirname "${conf_dir}")"
  cp -rp "${template_dir}" "${conf_dir}"

  host_csv=$(join_running_hosts_csv)
  port_csv=$(join_running_ports_csv)

  set_config_value "${conf_dir}/config.properties" "HOST" "${host_csv}"
  set_config_value "${conf_dir}/config.properties" "PORT" "${port_csv}"
  set_config_value "${conf_dir}/config.properties" "USERNAME" "${db_sys_admin}"
  set_config_value "${conf_dir}/config.properties" "PASSWORD" "${db_sys_pw}"
  set_config_value "${conf_dir}/config.properties" "DB_NAME" "${db_name}"
  set_config_value "${conf_dir}/config.properties" "TEST_MAX_TIME" "${bm_test_ms}"
  set_config_value "${conf_dir}/config.properties" "LOOP" "${bm_loop}"
  set_config_value "${conf_dir}/config.properties" "BATCH_SIZE_PER_WRITE" "${bm_batch_size}"
  set_config_value "${conf_dir}/config.properties" "DEVICE_NUM_PER_WRITE" "${bm_device_num_per_write}"
  set_config_value "${conf_dir}/config.properties" "DEVICE_NUMBER" "${bm_device_number}"
  set_config_value "${conf_dir}/config.properties" "DATA_CLIENT_NUMBER" "${bm_data_client_number}"
  set_config_value "${conf_dir}/config.properties" "GROUP_NUMBER" "1"
  set_config_value "${conf_dir}/config.properties" "IoTDB_TABLE_NUMBER" "1"
  set_config_value "${conf_dir}/config.properties" "CREATE_SCHEMA" "true"
  set_config_value "${conf_dir}/config.properties" "IS_DELETE_DATA" "false"
  set_config_value "${conf_dir}/config.properties" "OPERATION_PROPORTION" "100:0:0:0:0:0:0:0:0:0:0:0:0"
  set_config_value "${conf_dir}/config.properties" "START_TIME" "${start_time_str}"
}

start_benchmark_job() {
  local benchmark_home=$1
  local conf_dir=$2
  local out_file=$3
  local pid_file=$4

  nohup sh -x "${benchmark_home}/benchmark.sh" -cf "${conf_dir}" > "${out_file}" 2>&1 &
  echo $! > "${pid_file}"
}

wait_benchmark_with_periodic_flush() {
  local pid_file=$1
  local dialect=$2
  local flush_interval_sec=$3
  local max_wait_sec=$4
  local start_ts pid

  pid=$(tr -d '[:space:]' < "${pid_file}")
  start_ts=$(date +%s)
  while kill -0 "${pid}" >/dev/null 2>&1; do
    if (( $(date +%s) - start_ts > max_wait_sec )); then
      kill "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" >/dev/null 2>&1 || true
      return 1
    fi
    sleep "${flush_interval_sec}"
    run_cli_sql "${query_ip}" "${dialect}" "flush;" "${cur_dir}/benchmark_flush.out" 3600 || true
  done
  wait "${pid}"
}

wait_table_rows() {
  local db_name=$1
  local table_name=$2
  local min_count=$3
  local timeout_sec=${4:-900}
  local start_ts value
  start_ts=$(date +%s)
  while true; do
    run_cli_sql "${query_ip}" table "select count(s_0) from ${db_name}.${table_name};" "${cur_dir}/table_count.out" 3600 || true
    value=$(awk -F '|' '
      function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
      $0 ~ /^\|/ {
        for (i = NF; i >= 2; i--) {
          v = trim($i)
          if (v ~ /^[0-9]+$/) {
            print v
            exit
          }
        }
      }
    ' "${cur_dir}/table_count.out")
    if [[ -n "${value}" && ${value} -ge ${min_count} ]]; then
      return 0
    fi
    if (( $(date +%s) - start_ts > timeout_sec )); then
      return 1
    fi
    sleep 5
  done
}

wait_show_migrations_empty() {
  local stage=$1
  local timeout_sec=${2:-7200}
  local start_ts
  start_ts=$(date +%s)
  while true; do
    run_cli_sql "${query_ip}" table "show migrations;" "${cur_dir}/show_migrations.out" 3600
    if grep -q "Empty set" "${cur_dir}/show_migrations.out"; then
      log "INFO" "show migrations empty at ${stage}"
      return 0
    fi
    if (( $(date +%s) - start_ts > timeout_sec )); then
      return 1
    fi
    sleep 20
  done
}

remove_datanode_and_wait() {
  local dn_ip=$1
  local dn_id
  dn_id=$(get_datanode_id_by_ip "${dn_ip}")
  if [[ -z "${dn_id}" ]]; then
    return 1
  fi
  run_cli_sql "${query_ip}" table "remove datanode ${dn_id};" "${cur_dir}/remove_datanode.out" 3600
  wait_datanode_absent "${dn_ip}" 3600
  wait_show_migrations_empty "after_remove" 7200
  wait_jps_gone "${dn_ip}" 900 || true
}

start_datanode_and_wait() {
  local dn_ip=$1
  local tag=$2
  local start_ts
  start_ts=$(date +%s)
  ssh "${os_user_name}@${dn_ip}" "source /etc/profile; cd ${db_dir}; sudo ./sbin/start-datanode.sh -H ${db_dir}/dn_${tag}_${start_ts}.hprof > /dev/null 2>&1 &"
  wait_datanode_running "${dn_ip}" 1800
}

stop_datanode_and_wait() {
  local dn_ip=$1
  ssh "${os_user_name}@${dn_ip}" "source /etc/profile; cd ${db_dir}; sudo ./sbin/stop-datanode.sh" >> "${log_file}" 2>&1
  wait_jps_gone "${dn_ip}" 300
}

set_migration_knobs() {
  local bps=$1
  local concurrency=$2
  run_cli_sql "${query_ip}" table "set configuration region_migration_speed_limit_bytes_per_second='${bps}';" "${cur_dir}/set_mig_speed.out" 3600
  run_cli_sql "${query_ip}" table "set configuration region_migration_concurrency_limit='${concurrency}';" "${cur_dir}/set_mig_concurrency.out" 3600
}

restore_migration_knobs() {
  run_cli_sql "${query_ip}" table "set configuration region_migration_speed_limit_bytes_per_second='${migration_default_bps}';" "${cur_dir}/restore_mig_speed.out" 3600 || true
  run_cli_sql "${query_ip}" table "set configuration region_migration_concurrency_limit='${migration_default_concurrency}';" "${cur_dir}/restore_mig_concurrency.out" 3600 || true
}

capture_regions() {
  local db_name=$1
  local outfile=$2
  run_cli_sql "${query_ip}" table "show regions from ${db_name};" "${outfile}" 3600
}

get_first_data_region_id() {
  local infile=$1
  awk -F '|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    $0 ~ /^\|/ {
      region_id = trim($2)
      region_type = trim($3)
      if (region_id != "RegionId" && region_type == "DataRegion") {
        print region_id
        exit
      }
    }
  ' "${infile}"
}

region_has_target() {
  local infile=$1
  local region_id=$2
  local dn_ip=$3
  awk -F '|' -v region_id="${region_id}" -v dn_ip="${dn_ip}" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    $0 ~ /^\|/ {
      id = trim($2)
      region_type = trim($3)
      ip = trim($11)
      if (id == region_id && region_type == "DataRegion" && ip == dn_ip) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "${infile}"
}

wait_target_receives_region() {
  local db_name=$1
  local region_id=$2
  local dn_ip=$3
  local timeout_sec=${4:-3600}
  local start_ts
  start_ts=$(date +%s)
  while true; do
    capture_regions "${db_name}" "${cur_dir}/regions_wait_target.out"
    if region_has_target "${cur_dir}/regions_wait_target.out" "${region_id}" "${dn_ip}"; then
      return 0
    fi
    if (( $(date +%s) - start_ts > timeout_sec )); then
      return 1
    fi
    sleep 20
  done
}

region_size_pair_mb() {
  local infile=$1
  local region_id=$2
  local dn_ip=$3
  awk -F '|' -v region_id="${region_id}" -v dn_ip="${dn_ip}" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function size_to_mb(s,   a, v, u) {
      s = trim(s)
      if (s == "") return 0
      split(s, a, " ")
      v = a[1] + 0
      u = toupper(a[2])
      if (u == "KB") return v / 1024
      if (u == "MB") return v
      if (u == "GB") return v * 1024
      if (u == "TB") return v * 1024 * 1024
      return 0
    }
    $0 ~ /^\|/ {
      id = trim($2)
      region_type = trim($3)
      ip = trim($11)
      size_mb = size_to_mb($14)
      if (id == region_id && region_type == "DataRegion") {
        if (size_mb > max_mb) {
          max_mb = size_mb
        }
        if (ip == dn_ip) {
          target_mb = size_mb
        }
      }
    }
    END { printf "%.2f %.2f\n", target_mb + 0, max_mb + 0 }
  ' "${infile}"
}

wait_target_region_stable() {
  local db_name=$1
  local region_id=$2
  local dn_ip=$3
  local interval_sec=$4
  local stable_rounds=$5
  local timeout_sec=$6
  local stable_count=0
  local last_target_mb=-1
  local start_ts size_pair target_mb max_mb delta_mb change_mb

  start_ts=$(date +%s)
  while true; do
    capture_regions "${db_name}" "${cur_dir}/regions_stable.out"
    size_pair=$(region_size_pair_mb "${cur_dir}/regions_stable.out" "${region_id}" "${dn_ip}")
    target_mb=$(echo "${size_pair}" | awk '{print $1}')
    max_mb=$(echo "${size_pair}" | awk '{print $2}')
    delta_mb=$(awk -v max="${max_mb}" -v target="${target_mb}" 'BEGIN { printf "%.2f\n", max - target }')
    if awk -v target="${target_mb}" 'BEGIN { exit !(target > 0) }'; then
      if awk -v last="${last_target_mb}" 'BEGIN { exit !(last >= 0) }'; then
        change_mb=$(awk -v cur="${target_mb}" -v last="${last_target_mb}" 'BEGIN { d = cur - last; if (d < 0) d = -d; printf "%.2f\n", d }')
        if awk -v d="${change_mb}" 'BEGIN { exit !(d <= 1.00) }'; then
          stable_count=$((stable_count + 1))
        else
          stable_count=0
        fi
      fi
      last_target_mb=${target_mb}
      log "INFO" "region=${region_id} target_size_mb=${target_mb} max_peer_size_mb=${max_mb} delta_mb=${delta_mb} stable_count=${stable_count}"
      if [[ ${stable_count} -ge ${stable_rounds} ]]; then
        return 0
      fi
    fi
    if (( $(date +%s) - start_ts > timeout_sec )); then
      return 1
    fi
    sleep "${interval_sec}"
  done
}

normalize_cli_output() {
  local infile=$1
  local outfile=$2
  grep -v 'It costs' "${infile}" | sed '/^[[:space:]]*$/d' > "${outfile}"
}

pick_query_host() {
  local stop_ip=$1
  while read -r ip; do
    if [[ -n "${ip}" && "${ip}" != "${stop_ip}" ]]; then
      echo "${ip}"
      return 0
    fi
  done < "${nodeinfo_dir}/datanode.txt"
  return 1
}
