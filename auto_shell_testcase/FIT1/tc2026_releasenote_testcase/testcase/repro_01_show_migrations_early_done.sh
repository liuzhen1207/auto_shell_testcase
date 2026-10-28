#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME=$(basename "$0")
source "${SCRIPT_DIR}/repro_common_standalone.sh"

repro_common_init "${SCRIPT_DIR}" "${SCRIPT_NAME}"

repro_db=${REPRO_DB_NAME:-repro_show_mig_$(date +%m%d%H%M%S)}
repro_table=tab1mb_0
log_file="${SCRIPT_DIR}/repro_01_show_migrations_early_done.log"
evidence_file="${SCRIPT_DIR}/repro_01_show_migrations_early_done.evidence.txt"
observation_csv="${SCRIPT_DIR}/repro_01_show_migrations_early_done.observations.csv"
timeline_file="${SCRIPT_DIR}/repro_01_show_migrations_early_done.timeline.txt"

benchmark_home="${SCRIPT_DIR}/../benchmark/bm_20260519_writeview_v20"
benchmark_template="${benchmark_home}/weather_6h/conf_tab1"
benchmark_work_root="${SCRIPT_DIR}/bm_work_repro01_$(date +%s)"
benchmark_conf_dir="${benchmark_work_root}/conf_tab1"
benchmark_out="${benchmark_work_root}/benchmark.out"
benchmark_pid_file="${benchmark_work_root}/benchmark.pid"

benchmark_test_ms=${REPRO_BM_TEST_MS:-180000}
benchmark_loop=${REPRO_BM_LOOP:-2000000}
benchmark_batch_size=${REPRO_BM_BATCH_SIZE:-50}
benchmark_device_num_per_write=${REPRO_BM_DEVICE_NUM_PER_WRITE:-2}
benchmark_device_number=${REPRO_BM_DEVICE_NUMBER:-40}
benchmark_data_client_number=${REPRO_BM_DATA_CLIENT_NUMBER:-4}
benchmark_flush_interval_sec=${REPRO_BM_FLUSH_INTERVAL_SEC:-20}
benchmark_wait_timeout_sec=${REPRO_BM_WAIT_TIMEOUT_SEC:-600}

migration_bps=${REPRO_MIGRATION_BPS:-65536}
migration_concurrency=${REPRO_MIGRATION_CONCURRENCY:-1}
observe_loops=${REPRO_OBSERVE_LOOPS:-10}
observe_interval_sec=${REPRO_OBSERVE_INTERVAL_SEC:-60}
lag_threshold_mb=${REPRO_LAG_THRESHOLD_MB:-8}
growth_threshold_mb=${REPRO_GROWTH_THRESHOLD_MB:-2}
show_migrations_empty_epoch=0
load_balance_submit_epoch=0
first_target_mb_after_empty=0
last_target_mb_after_empty=0
max_peer_mb_after_empty=0
max_growth_after_empty=0
max_delta_after_empty=0
region_appeared_on_target_epoch=0
snapshot_start_epoch=0
snapshot_success_epoch=0
addpeer_start_epoch=0
addpeer_success_epoch=0
empty_before_snapshot_success=0
empty_before_addpeer_success=0

write_evidence_header() {
  {
    echo "repro_script=${SCRIPT_NAME}"
    echo "repro_db=${repro_db}"
    echo "tracked_region_id=${tracked_region_id:-unknown}"
    echo "target_ip=${target_ip}"
    echo "migration_bps=${migration_bps}"
    echo "migration_concurrency=${migration_concurrency}"
    echo "lag_threshold_mb=${lag_threshold_mb}"
    echo "growth_threshold_mb=${growth_threshold_mb}"
    echo
    echo "timeline"
    echo "load_balance_submit_epoch=${load_balance_submit_epoch}"
    echo "show_migrations_empty_epoch=${show_migrations_empty_epoch}"
    echo "region_appeared_on_target_epoch=${region_appeared_on_target_epoch}"
    echo
    echo "observations_csv=${observation_csv}"
    echo "timeline_file=${timeline_file}"
    echo
  } > "${evidence_file}"
}

append_evidence_line() {
  echo "$1" >> "${evidence_file}"
}

record_observation() {
  local step=$1
  local target_mb=$2
  local max_mb=$3
  local delta_mb=$4
  local ts_epoch ts_str
  ts_epoch=$(date +%s)
  ts_str=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s,%s,%s,%.2f,%.2f,%.2f\n' "${step}" "${ts_epoch}" "${ts_str}" "${target_mb}" "${max_mb}" "${delta_mb}" >> "${observation_csv}"
}

extract_epoch_from_log_ts() {
  local ts=$1
  date -d "${ts}" +%s 2>/dev/null || echo 0
}

collect_timeline_events() {
  local region_token snapshot_token ip remote_cmd raw_line event_type ts
  region_token="DataRegion[${tracked_region_id}]"
  snapshot_token="snapshot_${tracked_region_id}_"
  : > "${timeline_file}"

  while read -r ip; do
    [[ -z "${ip}" ]] && continue
    remote_cmd=$(cat <<EOF
for f in ${db_dir}/logs/*datanode*all* ${db_dir}/logs/*datanode*warn* ${db_dir}/logs/*datanode*error*; do
  [ -f "\$f" ] || continue
  grep -H -n -F "${region_token}" "\$f" 2>/dev/null | grep -E "Start to addPeer|Succeed to addPeer" || true
  grep -H -n -E "Start to transmit snapshots|successfully transmit all snapshots from dir .*${snapshot_token}" "\$f" 2>/dev/null || true
done
EOF
)
    while IFS= read -r raw_line; do
      [[ -z "${raw_line}" ]] && continue
      ts=$(echo "${raw_line}" | sed -n 's/.*\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*/\1/p' | head -1)
      [[ -z "${ts}" ]] && continue
      event_type=""
      if [[ "${raw_line}" == *"Start to addPeer"* ]]; then
        event_type="addpeer_start"
      elif [[ "${raw_line}" == *"Succeed to addPeer"* ]]; then
        event_type="addpeer_success"
      elif [[ "${raw_line}" == *"Start to transmit snapshots"* ]]; then
        event_type="snapshot_start"
      elif [[ "${raw_line}" == *"successfully transmit all snapshots from dir"* ]]; then
        event_type="snapshot_success"
      fi
      [[ -z "${event_type}" ]] && continue
      printf '%s|%s|%s|%s\n' "${event_type}" "${ip}" "${ts}" "${raw_line}" >> "${timeline_file}"
    done < <(ssh "${os_user_name}@${ip}" "${remote_cmd}" 2>/dev/null)
  done < "${nodeinfo_dir}/datanode.txt"
}

pick_event_epoch_after() {
  local event_type=$1
  local mode=$2
  local picked_epoch=0 picked_ts="" line cur_ts cur_epoch
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" != "${event_type}"* ]]; then
      continue
    fi
    cur_ts=$(echo "${line}" | awk -F '|' '{print $3}')
    cur_epoch=$(extract_epoch_from_log_ts "${cur_ts}")
    if (( cur_epoch < load_balance_submit_epoch )); then
      continue
    fi
    if [[ "${mode}" = "first" ]]; then
      if (( picked_epoch == 0 || cur_epoch < picked_epoch )); then
        picked_epoch=${cur_epoch}
        picked_ts=${cur_ts}
      fi
    else
      if (( cur_epoch > picked_epoch )); then
        picked_epoch=${cur_epoch}
        picked_ts=${cur_ts}
      fi
    fi
  done < "${timeline_file}"
  echo "${picked_epoch}|${picked_ts}"
}

cleanup() {
  set +e
  restore_migration_knobs
  wait_datanode_running "${target_ip}" 30 >/dev/null 2>&1 || start_datanode_and_wait "${target_ip}" "repro01_cleanup" >/dev/null 2>&1
}

trap cleanup EXIT

main() {
  : > "${log_file}"
  : > "${observation_csv}"
  echo "step,epoch,timestamp,target_size_mb,max_peer_size_mb,delta_mb" > "${observation_csv}"
  log "INFO" "start standalone repro 01 db=${repro_db}"
  start_db

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

  log "INFO" "run benchmark copy ${benchmark_conf_dir}"
  start_benchmark_job "${benchmark_home}" "${benchmark_conf_dir}" "${benchmark_out}" "${benchmark_pid_file}"
  wait_benchmark_with_periodic_flush "${benchmark_pid_file}" table "${benchmark_flush_interval_sec}" "${benchmark_wait_timeout_sec}"
  run_cli_sql "${query_ip}" table "flush;" "${SCRIPT_DIR}/repro01_flush.out" 3600
  wait_table_rows "${repro_db}" "${repro_table}" 100 600

  capture_regions "${repro_db}" "${SCRIPT_DIR}/repro01_regions_before.out"
  tracked_region_id=$(get_first_data_region_id "${SCRIPT_DIR}/repro01_regions_before.out")
  if [[ -z "${tracked_region_id}" ]]; then
    log "ERROR" "failed to resolve DataRegion for ${repro_db}"
    exit 1
  fi
  log "INFO" "tracked region id=${tracked_region_id}"

  remove_datanode_and_wait "${target_ip}"
  start_datanode_and_wait "${target_ip}" "repro01"
  set_migration_knobs "${migration_bps}" "${migration_concurrency}"
  load_balance_submit_epoch=$(date +%s)
  run_cli_sql "${query_ip}" table "load balance;" "${SCRIPT_DIR}/repro01_load_balance.out" 3600
  wait_show_migrations_empty "after_load_balance" 7200
  show_migrations_empty_epoch=$(date +%s)
  wait_target_receives_region "${repro_db}" "${tracked_region_id}" "${target_ip}" 7200
  region_appeared_on_target_epoch=$(date +%s)
  write_evidence_header

  last_target_mb=-1
  growth_seen=0
  lag_seen=0
  loop_idx=0
  while (( loop_idx < observe_loops )); do
    loop_idx=$((loop_idx + 1))
    capture_regions "${repro_db}" "${SCRIPT_DIR}/repro01_regions_after.out"
    size_pair=$(region_size_pair_mb "${SCRIPT_DIR}/repro01_regions_after.out" "${tracked_region_id}" "${target_ip}")
    target_mb=$(echo "${size_pair}" | awk '{print $1}')
    max_mb=$(echo "${size_pair}" | awk '{print $2}')
    delta_mb=$(awk -v max="${max_mb}" -v target="${target_mb}" 'BEGIN { printf "%.2f\n", max - target }')
    record_observation "${loop_idx}" "${target_mb}" "${max_mb}" "${delta_mb}"
    if (( loop_idx == 1 )); then
      first_target_mb_after_empty=${target_mb}
      max_peer_mb_after_empty=${max_mb}
    fi
    last_target_mb_after_empty=${target_mb}
    if awk -v cur="${max_mb}" -v old="${max_peer_mb_after_empty}" 'BEGIN { exit !(cur > old) }'; then
      max_peer_mb_after_empty=${max_mb}
    fi
    if awk -v cur="${delta_mb}" -v old="${max_delta_after_empty}" 'BEGIN { exit !(cur > old) }'; then
      max_delta_after_empty=${delta_mb}
    fi
    if awk -v d="${delta_mb}" -v t="${lag_threshold_mb}" 'BEGIN { exit !(d > t) }'; then
      lag_seen=1
    fi
    if awk -v last="${last_target_mb}" 'BEGIN { exit !(last >= 0) }'; then
      growth_mb=$(awk -v cur="${target_mb}" -v last="${last_target_mb}" 'BEGIN { printf "%.2f\n", cur - last }')
      if awk -v cur="${growth_mb}" -v old="${max_growth_after_empty}" 'BEGIN { exit !(cur > old) }'; then
        max_growth_after_empty=${growth_mb}
      fi
      if awk -v g="${growth_mb}" -v t="${growth_threshold_mb}" 'BEGIN { exit !(g > t) }'; then
        growth_seen=1
      fi
    fi
    last_target_mb=${target_mb}
    log "INFO" "observe=${loop_idx} region=${tracked_region_id} target_size_mb=${target_mb} max_peer_size_mb=${max_mb} delta_mb=${delta_mb}"
    if (( loop_idx < observe_loops )); then
      sleep "${observe_interval_sec}"
    fi
  done

  collect_timeline_events
  snapshot_start_info=$(pick_event_epoch_after "snapshot_start" "first")
  snapshot_success_info=$(pick_event_epoch_after "snapshot_success" "last")
  addpeer_start_info=$(pick_event_epoch_after "addpeer_start" "first")
  addpeer_success_info=$(pick_event_epoch_after "addpeer_success" "last")
  snapshot_start_epoch=$(echo "${snapshot_start_info}" | awk -F '|' '{print $1}')
  snapshot_success_epoch=$(echo "${snapshot_success_info}" | awk -F '|' '{print $1}')
  addpeer_start_epoch=$(echo "${addpeer_start_info}" | awk -F '|' '{print $1}')
  addpeer_success_epoch=$(echo "${addpeer_success_info}" | awk -F '|' '{print $1}')
  if (( snapshot_success_epoch > 0 && show_migrations_empty_epoch < snapshot_success_epoch )); then
    empty_before_snapshot_success=1
  fi
  if (( addpeer_success_epoch > 0 && show_migrations_empty_epoch < addpeer_success_epoch )); then
    empty_before_addpeer_success=1
  fi

  if [[ ${empty_before_snapshot_success} -eq 1 || ${empty_before_addpeer_success} -eq 1 ]]; then
    append_evidence_line "summary"
    append_evidence_line "show_migrations_became_empty_at=$(date -d "@${show_migrations_empty_epoch}" '+%Y-%m-%d %H:%M:%S')"
    append_evidence_line "target_region_first_seen_on_target_at=$(date -d "@${region_appeared_on_target_epoch}" '+%Y-%m-%d %H:%M:%S')"
    append_evidence_line "snapshot_start_at=$(if (( snapshot_start_epoch > 0 )); then date -d "@${snapshot_start_epoch}" '+%Y-%m-%d %H:%M:%S'; else echo unknown; fi)"
    append_evidence_line "snapshot_success_at=$(if (( snapshot_success_epoch > 0 )); then date -d "@${snapshot_success_epoch}" '+%Y-%m-%d %H:%M:%S'; else echo unknown; fi)"
    append_evidence_line "addpeer_start_at=$(if (( addpeer_start_epoch > 0 )); then date -d "@${addpeer_start_epoch}" '+%Y-%m-%d %H:%M:%S'; else echo unknown; fi)"
    append_evidence_line "addpeer_success_at=$(if (( addpeer_success_epoch > 0 )); then date -d "@${addpeer_success_epoch}" '+%Y-%m-%d %H:%M:%S'; else echo unknown; fi)"
    append_evidence_line "show_migrations_empty_before_snapshot_success=${empty_before_snapshot_success}"
    append_evidence_line "show_migrations_empty_before_addpeer_success=${empty_before_addpeer_success}"
    append_evidence_line "target_size_first_mb_after_empty=${first_target_mb_after_empty}"
    append_evidence_line "target_size_last_mb_after_empty=${last_target_mb_after_empty}"
    append_evidence_line "target_size_growth_mb_after_empty=$(awk -v first="${first_target_mb_after_empty}" -v last="${last_target_mb_after_empty}" 'BEGIN { printf "%.2f\n", last - first }')"
    append_evidence_line "max_peer_size_mb_after_empty=${max_peer_mb_after_empty}"
    append_evidence_line "max_delta_mb_after_empty=${max_delta_after_empty}"
    append_evidence_line "max_single_step_growth_mb_after_empty=${max_growth_after_empty}"
    append_evidence_line
    append_evidence_line "bug_statement=SHOW MIGRATIONS returned Empty set before the region migration log timeline reached snapshot success and/or addPeer success for the tracked DataRegion."
    append_evidence_line "why_this_is_bug=If snapshot transmission or addPeer success is still in progress, the migration should still be visible to SHOW MIGRATIONS instead of already being reported as complete."
    log "INFO" "BUG EVIDENCE: show migrations empty at $(date -d "@${show_migrations_empty_epoch}" '+%Y-%m-%d %H:%M:%S'), snapshot_success_epoch=${snapshot_success_epoch}, addpeer_success_epoch=${addpeer_success_epoch}; report=${evidence_file}"
    log "INFO" "REPRODUCED: show migrations became empty before snapshot/addPeer completion was logged"
    exit 0
  fi

  append_evidence_line "summary"
  append_evidence_line "show_migrations_became_empty_at=$(date -d "@${show_migrations_empty_epoch}" '+%Y-%m-%d %H:%M:%S')"
  append_evidence_line "snapshot_success_at=$(if (( snapshot_success_epoch > 0 )); then date -d "@${snapshot_success_epoch}" '+%Y-%m-%d %H:%M:%S'; else echo unknown; fi)"
  append_evidence_line "addpeer_success_at=$(if (( addpeer_success_epoch > 0 )); then date -d "@${addpeer_success_epoch}" '+%Y-%m-%d %H:%M:%S'; else echo unknown; fi)"
  append_evidence_line "show_migrations_empty_before_snapshot_success=${empty_before_snapshot_success}"
  append_evidence_line "show_migrations_empty_before_addpeer_success=${empty_before_addpeer_success}"
  append_evidence_line "supplemental_size_growth_seen=${growth_seen}"
  append_evidence_line "supplemental_size_lag_seen=${lag_seen}"
  append_evidence_line "not_reproduced_reason=No direct timeline proof that SHOW MIGRATIONS became empty before snapshot success or addPeer success in the current run."
  log "ERROR" "NOT REPRODUCED: no direct timeline proof that show migrations became empty before snapshot/addPeer completion"
  exit 1
}

main "$@"
