#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME=$(basename "$0")
source "${SCRIPT_DIR}/repro_common_standalone.sh"

repro_common_init "${SCRIPT_DIR}" "${SCRIPT_NAME}"

repro_db=${REPRO_DB_NAME:-repro_delete_mods_$(date +%m%d%H%M%S)}
repro_table=tab1mb_0
table_db=""
log_file="${SCRIPT_DIR}/repro_02_shared_storage_delete_mods.log"

benchmark_home="${SCRIPT_DIR}/../benchmark/bm_20260519_writeview_v20"
benchmark_template=${REPRO_BM_TEMPLATE:-${benchmark_home}/weather_6h/conf_tab1}
benchmark_work_root="${SCRIPT_DIR}/bm_work_repro02_$(date +%s)"
benchmark_conf_dir="${benchmark_work_root}/conf_tab1"
benchmark_out="${benchmark_work_root}/benchmark.out"
benchmark_pid_file="${benchmark_work_root}/benchmark.pid"

benchmark_test_ms=${REPRO_BM_TEST_MS:-240000}
benchmark_loop=${REPRO_BM_LOOP:-3000000}
benchmark_batch_size=${REPRO_BM_BATCH_SIZE:-32}
benchmark_device_num_per_write=${REPRO_BM_DEVICE_NUM_PER_WRITE:-1}
benchmark_device_number=${REPRO_BM_DEVICE_NUMBER:-40}
benchmark_data_client_number=${REPRO_BM_DATA_CLIENT_NUMBER:-4}
benchmark_object_length=${REPRO_BM_OBJECT_LENGTH:-1048576}
benchmark_flush_interval_sec=${REPRO_BM_FLUSH_INTERVAL_SEC:-20}
benchmark_wait_timeout_sec=${REPRO_BM_WAIT_TIMEOUT_SEC:-900}

delete_before_ms=${REPRO_DELETE_BEFORE_MS:-90000}
migration_bps=${REPRO_MIGRATION_BPS:-4194304}
migration_concurrency=${REPRO_MIGRATION_CONCURRENCY:-1}
stability_interval_sec=${REPRO_STABILITY_INTERVAL_SEC:-30}
stability_rounds=${REPRO_STABILITY_ROUNDS:-3}
stability_timeout_sec=${REPRO_STABILITY_TIMEOUT_SEC:-1800}

baseline_deleted_raw="${SCRIPT_DIR}/repro02_baseline_deleted.out"
baseline_deleted_norm="${SCRIPT_DIR}/repro02_baseline_deleted.norm"
baseline_total_raw="${SCRIPT_DIR}/repro02_baseline_total.out"
baseline_total_norm="${SCRIPT_DIR}/repro02_baseline_total.norm"
benchmark_start_ms=0
delete_cutoff_ms=0
current_stopped_ip=""

get_benchmark_config_value() {
  local key=$1
  awk -F '=' -v key="${key}" '
    $1 == key {
      sub(/^[[:space:]]+/, "", $2)
      sub(/[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "${benchmark_conf_dir}/config.properties"
}

resolve_table_db() {
  local db_name group_prefix
  db_name=$(get_benchmark_config_value "DB_NAME")
  group_prefix=$(get_benchmark_config_value "GROUP_NAME_PREFIX")
  if [[ -z "${db_name}" || -z "${group_prefix}" ]]; then
    log "ERROR" "failed to resolve table db from ${benchmark_conf_dir}/config.properties"
    return 1
  fi
  printf '%s_%s0\n' "${db_name}" "${group_prefix}"
}

append_file_to_log() {
  local label=$1
  local infile=$2
  {
    echo "===== ${label} ====="
    cat "${infile}"
  } >> "${log_file}"
}

estimate_object_frame_bytes() {
  awk -v batch="${benchmark_batch_size}" -v devices="${benchmark_device_num_per_write}" -v object_len="${benchmark_object_length}" '
    BEGIN {
      printf "%.0f\n", batch * devices * object_len
    }
  '
}

capture_delete_window_evidence() {
  local stage=$1
  local prefix="${SCRIPT_DIR}/repro02_${stage}"
  run_cli_sql "${query_ip}" table "select count(s_0) from ${table_db}.${repro_table} where time <= ${delete_cutoff_ms};" "${prefix}_count_le_cutoff.out" 3600
  run_cli_sql "${query_ip}" table "select min(time),max(time) from ${table_db}.${repro_table};" "${prefix}_minmax_all.out" 3600
  run_cli_sql "${query_ip}" table "select max(time) from ${table_db}.${repro_table} where time <= ${delete_cutoff_ms};" "${prefix}_max_le_cutoff.out" 3600
  append_file_to_log "${stage} count_le_cutoff" "${prefix}_count_le_cutoff.out"
  append_file_to_log "${stage} minmax_all" "${prefix}_minmax_all.out"
  append_file_to_log "${stage} max_le_cutoff" "${prefix}_max_le_cutoff.out"
}

cleanup() {
  set +e
  restore_migration_knobs
  if [[ -n "${current_stopped_ip}" ]]; then
    wait_datanode_running "${current_stopped_ip}" 30 >/dev/null 2>&1 || start_datanode_and_wait "${current_stopped_ip}" "repro02_cleanup_stop" >/dev/null 2>&1
  fi
  wait_datanode_running "${target_ip}" 30 >/dev/null 2>&1 || start_datanode_and_wait "${target_ip}" "repro02_cleanup_target" >/dev/null 2>&1
}

trap cleanup EXIT

capture_baseline() {
  local deleted_sql total_sql
  deleted_sql="select device_id,count(s_0) from ${table_db}.${repro_table} where time <= ${delete_cutoff_ms} group by device_id order by device_id;"
  total_sql="select device_id,count(s_0) from ${table_db}.${repro_table} group by device_id order by device_id;"
  run_cli_sql "${query_ip}" table "${deleted_sql}" "${baseline_deleted_raw}" 3600
  run_cli_sql "${query_ip}" table "${total_sql}" "${baseline_total_raw}" 3600
  normalize_cli_output "${baseline_deleted_raw}" "${baseline_deleted_norm}"
  normalize_cli_output "${baseline_total_raw}" "${baseline_total_norm}"
}

main() {
  : > "${log_file}"
  log "INFO" "start standalone repro 02 db=${repro_db}"
  start_db

  if [[ ! -d "${benchmark_template}" ]]; then
    log "ERROR" "benchmark template not found: ${benchmark_template}"
    exit 1
  fi

  benchmark_start_ms=$(( $(date +%s) * 1000 ))
  prepare_benchmark_conf_dir \
    "${benchmark_template}" \
    "${benchmark_conf_dir}" \
    "${repro_db}" \
    "${benchmark_test_ms}" \
    "${benchmark_loop}" \
    "${benchmark_batch_size}" \
    "${benchmark_device_num_per_write}" \
    "${benchmark_device_number}" \
    "${benchmark_data_client_number}" \
    "$(date +"%Y-%m-%dT%H:%M:%S%:z")"
  set_config_value "${benchmark_conf_dir}/config.properties" "OBJECT_LENGTH" "${benchmark_object_length}"

  table_db=$(resolve_table_db)
  if [[ -z "${table_db}" ]]; then
    exit 1
  fi
  log "INFO" "resolved table db=${table_db} table=${repro_table} from benchmark config"
  log "INFO" "benchmark object_length=${benchmark_object_length} batch_size=${benchmark_batch_size} device_num_per_write=${benchmark_device_num_per_write} estimated_object_payload_bytes=$(estimate_object_frame_bytes)"

  log "INFO" "run benchmark copy ${benchmark_conf_dir}"
  start_benchmark_job "${benchmark_home}" "${benchmark_conf_dir}" "${benchmark_out}" "${benchmark_pid_file}"
  wait_benchmark_with_periodic_flush "${benchmark_pid_file}" table "${benchmark_flush_interval_sec}" "${benchmark_wait_timeout_sec}"
  run_cli_sql "${query_ip}" table "flush;" "${SCRIPT_DIR}/repro02_flush.out" 3600
  run_cli_sql "${query_ip}" table "show databases;" "${SCRIPT_DIR}/repro02_show_databases.out" 3600 || true
  run_cli_sql "${query_ip}" table "show tables from ${table_db};" "${SCRIPT_DIR}/repro02_show_tables.out" 3600 || true
  wait_table_rows "${table_db}" "${repro_table}" 100 600

  delete_cutoff_ms=$((benchmark_start_ms + delete_before_ms))
  log "INFO" "delete historical window <= ${delete_cutoff_ms}"
  capture_delete_window_evidence "before_delete"
  run_cli_sql "${query_ip}" table "delete from ${table_db}.${repro_table} where time <= ${delete_cutoff_ms};" "${SCRIPT_DIR}/repro02_delete.out" 3600
  run_cli_sql "${query_ip}" table "flush;" "${SCRIPT_DIR}/repro02_flush_after_delete.out" 3600
  capture_delete_window_evidence "after_delete"

  capture_regions "${table_db}" "${SCRIPT_DIR}/repro02_regions_before.out"
  tracked_region_id=$(get_first_data_region_id "${SCRIPT_DIR}/repro02_regions_before.out")
  if [[ -z "${tracked_region_id}" ]]; then
    log "ERROR" "failed to resolve DataRegion for ${table_db}"
    exit 1
  fi
  log "INFO" "tracked region id=${tracked_region_id}"

  remove_datanode_and_wait "${target_ip}"
  start_datanode_and_wait "${target_ip}" "repro02"
  set_migration_knobs "${migration_bps}" "${migration_concurrency}"
  run_cli_sql "${query_ip}" table "load balance;" "${SCRIPT_DIR}/repro02_load_balance.out" 3600
  wait_show_migrations_empty "after_load_balance" 7200
  wait_target_region_stable "${table_db}" "${tracked_region_id}" "${target_ip}" "${stability_interval_sec}" "${stability_rounds}" "${stability_timeout_sec}"

  capture_baseline

  mismatch_found=0
  while read -r stop_ip; do
    [[ -z "${stop_ip}" ]] && continue
    if [[ "${stop_ip}" = "${query_ip}" ]]; then
      query_ip=$(pick_query_host "${stop_ip}")
      log "INFO" "switch query host to ${query_ip} before stopping ${stop_ip}"
    fi
    current_stopped_ip="${stop_ip}"
    stop_datanode_and_wait "${stop_ip}"
    query_host=$(pick_query_host "${stop_ip}")
    stop_deleted_raw="${SCRIPT_DIR}/repro02_stop_${stop_ip//./_}_deleted.out"
    stop_deleted_norm="${SCRIPT_DIR}/repro02_stop_${stop_ip//./_}_deleted.norm"
    stop_total_raw="${SCRIPT_DIR}/repro02_stop_${stop_ip//./_}_total.out"
    stop_total_norm="${SCRIPT_DIR}/repro02_stop_${stop_ip//./_}_total.norm"

    run_cli_sql "${query_host}" table "select device_id,count(s_0) from ${table_db}.${repro_table} where time <= ${delete_cutoff_ms} group by device_id order by device_id;" "${stop_deleted_raw}" 3600
    run_cli_sql "${query_host}" table "select device_id,count(s_0) from ${table_db}.${repro_table} group by device_id order by device_id;" "${stop_total_raw}" 3600
    normalize_cli_output "${stop_deleted_raw}" "${stop_deleted_norm}"
    normalize_cli_output "${stop_total_raw}" "${stop_total_norm}"

    if ! diff -q "${baseline_deleted_norm}" "${stop_deleted_norm}" >/dev/null 2>&1; then
      log "ERROR" "REPRODUCED: delete-window query differs when ${stop_ip} is down"
      diff "${baseline_deleted_norm}" "${stop_deleted_norm}" >> "${log_file}" || true
      mismatch_found=1
    fi

    if ! diff -q "${baseline_total_norm}" "${stop_total_norm}" >/dev/null 2>&1; then
      log "ERROR" "total-count query also differs when ${stop_ip} is down"
      diff "${baseline_total_norm}" "${stop_total_norm}" >> "${log_file}" || true
    fi

    start_datanode_and_wait "${stop_ip}" "repro02_restart"
    current_stopped_ip=""
  done < "${nodeinfo_dir}/datanode.txt"

  if [[ ${mismatch_found} -eq 1 ]]; then
    exit 0
  fi

  log "ERROR" "NOT REPRODUCED: no delete-window inconsistency was observed after the migration"
  exit 1
}

main "$@"
