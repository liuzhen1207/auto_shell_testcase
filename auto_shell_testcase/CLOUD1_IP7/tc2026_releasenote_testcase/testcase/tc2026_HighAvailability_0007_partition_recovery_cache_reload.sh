#!/bin/bash
HA_CASE_ID=HA_P1_03
HA_CASE_NAME=partition_recovery_cache_reload
source "$(dirname "$0")/ha_common.sh"

run_persistent_ok_selected_db(){
  local name=$1 sql=$2 label=$3 timeout_seconds=${4:-30}
  local fd=${persistent_cli_fd[$name]} out=${persistent_cli_out[$name]} start_size response="${artifact_dir}/${label}.out" deadline
  start_size=$(wc -c <"$out"); printf '%s\n' "$sql" >&$fd; deadline=$((SECONDS+timeout_seconds))
  while ((SECONDS<deadline)); do
    tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
    if grep -Eq '(TimechoDB|IoTDB)(:[^>]*)?>' "$response" 2>/dev/null; then
      if grep -Eqi 'Exception|ERROR|Error|failed|does not exist|unknown' "$response"; then record_fail "$label returned an error"; cat "$response" | tee -a "$log_file"; return 1; fi
      log INFO "$label completed through pre-authenticated session"; return 0
    fi
    sleep 1
  done
  record_fail "$label timed out"; return 1
}

run_persistent_lease535_selected_db(){
  local name=$1 sql=$2 label=$3 timeout_seconds=${4:-30}
  local fd=${persistent_cli_fd[$name]} out=${persistent_cli_out[$name]} start_size response="${artifact_dir}/${label}.out" deadline
  start_size=$(wc -c <"$out"); printf '%s\n' "$sql" >&$fd; deadline=$((SECONDS+timeout_seconds))
  while ((SECONDS<deadline)); do
    tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
    if grep -Eq '(TimechoDB|IoTDB)(:[^>]*)?>' "$response" 2>/dev/null; then
      if grep -Eqi '535:.*Metadata lease is fenced|Metadata lease is fenced' "$response"; then log INFO "$label rejected promptly with metadata lease 535"; return 0; fi
      record_fail "$label returned without metadata lease 535"; cat "$response" | tee -a "$log_file"; return 1
    fi
    sleep 1
  done
  record_fail "$label timed out instead of promptly returning metadata lease 535"; return 1
}

wait_peer_observes_fault_dn_unknown(){
  local round=$1 timeout_seconds=${2:-120}
  local begin=$(date +%s) attempt=0 out final_out="${artifact_dir}/pre_ddl_show_cluster_round_${round}.out"
  while [ $(( $(date +%s)-begin )) -lt "$timeout_seconds" ]; do
    attempt=$((attempt+1)); out="${artifact_dir}/pre_ddl_show_cluster_round_${round}_attempt_${attempt}.out"
    tree "$query_ip" "show cluster" >"$out" 2>&1 || true
    sed -i 's/\r$//' "$out"
    if awk -F'|' -v target="$fault_dn" '
      function t(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
      /^\|/{status=t($4);ip=t($5);if(ip==target && status=="Unknown")found=1}
      END{exit !found}' "$out"; then
      cp -f "$out" "$final_out"
      log INFO "pre-DDL round ${round}: peer $query_ip observes $fault_dn Unknown attempt=$attempt elapsed=$(( $(date +%s)-begin ))s"
      return 0
    fi
    sleep 1
  done
  record_fail "pre-DDL round ${round}: peer did not observe $fault_dn Unknown within ${timeout_seconds}s"
  return 1
}

establish_pre_ddl_fence_evidence(){
  local round=$1
  wait_peer_observes_fault_dn_unknown "$round" || return 1
  run_persistent_lease535_selected_db fenced_table_session "select count(*) from base;" "pre_ddl_fenced_select_round_${round}" 30 || return 1
  log INFO "pre-DDL round ${round}: Unknown and local 535 both confirmed; wait additional 30s for CN contact-tracker margin"
  sleep 30
  date '+ddl_ready_at=%F %T' >"${artifact_dir}/pre_ddl_fence_ready_round_${round}.out"
  log INFO "pre-DDL round ${round}: strict fence evidence complete"
}

wait_persistent_cache_query(){
  local name=$1 sql=$2 label=$3 timeout_seconds=${4:-120}
  local fd=${persistent_cli_fd[$name]} out=${persistent_cli_out[$name]} overall_deadline=$((SECONDS+timeout_seconds))
  local attempt=0 start_size response prompt_deadline query_done
  while ((SECONDS<overall_deadline)); do
    attempt=$((attempt+1)); response="${artifact_dir}/${label}_attempt_${attempt}.out"; start_size=$(wc -c <"$out")
    printf '%s\n' "$sql" >&$fd; prompt_deadline=$((SECONDS+10)); query_done=0
    while ((SECONDS<prompt_deadline)); do
      tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
      if grep -Eq '(TimechoDB|IoTDB)(:[^>]*)?>' "$response" 2>/dev/null; then query_done=1; break; fi
      sleep 0.1
    done
    if [ "$query_done" -eq 0 ]; then record_fail "$label did not return a prompt within 10s; stop retrying to avoid queued SQL"; return 1; fi
    if ! grep -Eqi 'Exception|ERROR|Error|does not exist|unknown' "$response" && grep -Eqi 'count|Total line number' "$response"; then
      log INFO "$label cache-managed query succeeded attempt=$attempt elapsed_after_heal_check=$((timeout_seconds-(overall_deadline-SECONDS)))s"
      cp -f "$response" "${artifact_dir}/${label}.out"
      return 0
    fi
    sleep 1
  done
  record_fail "$label did not become queryable within ${timeout_seconds}s"
  return 1
}

formal_begin || { formal_end; exit 1; }
seed_all_models
start_persistent_cli fenced_table_session table "$fault_dn" || { formal_end; exit 1; }
run_persistent_ok_selected_db fenced_table_session "use $TABLE_DB;" pre_partition_table_use_database || { formal_end; exit 1; }
for round in 1 2; do
  partition_dn "$fault_dn"
  if ! establish_pre_ddl_fence_evidence "$round"; then
    heal_partition "$fault_dn"
    log WARN "skip round ${round} DDL because strict pre-DDL fence evidence was not established"
    break
  fi
  metadata_change_ok=1
  run_ok table "$query_ip" "use $TABLE_DB; alter table base add column c${round} int32 field; alter view writable_v add column c${round} as vc${round}" metadata_change_round_${round} || metadata_change_ok=0
  run_persistent_lease535_selected_db fenced_table_session "select count(*) from base;" fenced_base_select_round_${round}
  heal_partition "$fault_dn"
  if [ "$metadata_change_ok" -eq 0 ]; then
    log WARN "skip round ${round} recovery checks because metadata change failed; c${round}/vc${round} were not created"
    break
  fi
  round_cache_ok=1
  wait_persistent_cache_query fenced_table_session "select count(c${round}) from base;" recovered_base_cache_round_${round} || round_cache_ok=0
  if [ "$round_cache_ok" -eq 1 ]; then wait_persistent_cache_query fenced_table_session "select count(vc${round}) from writable_v;" recovered_view_cache_round_${round} || round_cache_ok=0; fi
  if [ "$round_cache_ok" -eq 0 ]; then log WARN "stop repeated partition rounds because cache recovery verification failed in round ${round}"; break; fi
  run_ok table "$fault_dn" "use $TABLE_DB; describe base details; describe writable_v details" cache_reload_round_${round} || break
done
close_all_persistent_clis
formal_end
