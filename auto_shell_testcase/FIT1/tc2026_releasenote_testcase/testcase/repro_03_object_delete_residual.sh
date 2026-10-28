#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME=$(basename "$0")
source "${SCRIPT_DIR}/repro_common_standalone.sh"

repro_common_init "${SCRIPT_DIR}" "${SCRIPT_NAME}"

repro_db=${REPRO_DB_NAME:-repro_object_delete_$(date +%m%d%H%M%S)}
repro_table=tab1mb_0
table_db=""
log_file="${SCRIPT_DIR}/repro_03_object_delete_residual.log"

benchmark_home="${SCRIPT_DIR}/../benchmark/bm_20260519_writeview_v20"
benchmark_template=${REPRO_BM_TEMPLATE:-${benchmark_home}/weather_6h/conf_tab1}
benchmark_work_root="${SCRIPT_DIR}/bm_work_repro03_$(date +%s)"
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

benchmark_start_ms=0
delete_cutoff_ms=0
before_count_file="${SCRIPT_DIR}/repro03_before_delete_count_le_cutoff.out"
after_count_file="${SCRIPT_DIR}/repro03_after_delete_count_le_cutoff.out"

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

extract_cli_first_number() {
  local infile=$1
  awk -F '|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    $0 ~ /^\|/ {
      for (i = 2; i <= NF; i++) {
        v = trim($i)
        if (v ~ /^[0-9]+$/) {
          print v
          exit
        }
      }
    }
  ' "${infile}"
}

capture_delete_window_evidence() {
  local stage=$1
  local prefix="${SCRIPT_DIR}/repro03_${stage}"
  run_cli_sql "${query_ip}" table "select count(s_0) from ${table_db}.${repro_table} where time <= ${delete_cutoff_ms};" "${prefix}_count_le_cutoff.out" 3600
  run_cli_sql "${query_ip}" table "select device_id,count(s_0) from ${table_db}.${repro_table} where time <= ${delete_cutoff_ms} group by device_id order by device_id;" "${prefix}_detail_le_cutoff.out" 3600
  run_cli_sql "${query_ip}" table "select min(time),max(time) from ${table_db}.${repro_table};" "${prefix}_minmax_all.out" 3600
  run_cli_sql "${query_ip}" table "select max(time) from ${table_db}.${repro_table} where time <= ${delete_cutoff_ms};" "${prefix}_max_le_cutoff.out" 3600
  append_file_to_log "${stage} count_le_cutoff" "${prefix}_count_le_cutoff.out"
  append_file_to_log "${stage} detail_le_cutoff" "${prefix}_detail_le_cutoff.out"
  append_file_to_log "${stage} minmax_all" "${prefix}_minmax_all.out"
  append_file_to_log "${stage} max_le_cutoff" "${prefix}_max_le_cutoff.out"
}

main() {
  local before_count after_count

  : > "${log_file}"
  log "INFO" "start standalone repro 03 db=${repro_db}"
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
  run_cli_sql "${query_ip}" table "flush;" "${SCRIPT_DIR}/repro03_flush.out" 3600
  run_cli_sql "${query_ip}" table "show databases;" "${SCRIPT_DIR}/repro03_show_databases.out" 3600 || true
  run_cli_sql "${query_ip}" table "show tables from ${table_db};" "${SCRIPT_DIR}/repro03_show_tables.out" 3600 || true
  wait_table_rows "${table_db}" "${repro_table}" 100 600

  delete_cutoff_ms=$((benchmark_start_ms + delete_before_ms))
  log "INFO" "delete historical window <= ${delete_cutoff_ms}"
  capture_delete_window_evidence "before_delete"

  run_cli_sql "${query_ip}" table "delete from ${table_db}.${repro_table} where time <= ${delete_cutoff_ms};" "${SCRIPT_DIR}/repro03_delete.out" 3600
  run_cli_sql "${query_ip}" table "flush;" "${SCRIPT_DIR}/repro03_flush_after_delete.out" 3600
  capture_delete_window_evidence "after_delete"

  before_count=$(extract_cli_first_number "${before_count_file}")
  after_count=$(extract_cli_first_number "${after_count_file}")

  if [[ -z "${before_count}" || -z "${after_count}" ]]; then
    log "ERROR" "failed to parse delete-window counts"
    exit 1
  fi

  log "INFO" "before_delete_count=${before_count} after_delete_count=${after_count}"

  if [[ "${before_count}" -eq 0 ]]; then
    log "ERROR" "unexpected empty delete window before delete; reproduction is inconclusive"
    exit 1
  fi

  if [[ "${after_count}" -gt 0 ]]; then
    log "ERROR" "REPRODUCED: object delete residual remains visible after delete+flush"
    exit 0
  fi

  log "ERROR" "NOT REPRODUCED: object delete residual was not observed"
  exit 1
}

main "$@"
