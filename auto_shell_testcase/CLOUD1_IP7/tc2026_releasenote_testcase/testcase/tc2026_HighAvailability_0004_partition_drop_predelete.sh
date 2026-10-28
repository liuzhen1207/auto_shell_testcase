#!/bin/bash
HA_CASE_ID=HA_P0_04
HA_CASE_NAME=partition_drop_predelete
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

wait_persistent_cache_query(){
  local name=$1 sql=$2 label=$3 timeout_seconds=${4:-120}
  local fd=${persistent_cli_fd[$name]} out=${persistent_cli_out[$name]} overall_deadline=$((SECONDS+timeout_seconds)) attempt=0 start_size response prompt_deadline query_done
  while ((SECONDS<overall_deadline)); do
    attempt=$((attempt+1)); response="${artifact_dir}/${label}_attempt_${attempt}.out"; start_size=$(wc -c <"$out"); printf '%s\n' "$sql" >&$fd; prompt_deadline=$((SECONDS+10)); query_done=0
    while ((SECONDS<prompt_deadline)); do tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true; if grep -Eq '(TimechoDB|IoTDB)(:[^>]*)?>' "$response" 2>/dev/null; then query_done=1; break; fi; sleep 0.1; done
    if [ "$query_done" -eq 0 ]; then record_fail "$label did not return a prompt within 10s"; return 1; fi
    if ! grep -Eqi 'Exception|ERROR|Error|does not exist|unknown' "$response" && grep -Eqi 'count|Total line number' "$response"; then cp -f "$response" "${artifact_dir}/${label}.out"; log INFO "$label succeeded attempt=$attempt"; return 0; fi
    sleep 1
  done
  record_fail "$label did not become queryable within ${timeout_seconds}s"; return 1
}

run_persistent_expected_missing_table(){
  local name=$1 sql=$2 label=$3 timeout_seconds=${4:-30}
  local fd=${persistent_cli_fd[$name]} out=${persistent_cli_out[$name]} start_size response="${artifact_dir}/${label}.out" deadline
  start_size=$(wc -c <"$out"); printf '%s\n' "$sql" >&$fd; deadline=$((SECONDS+timeout_seconds))
  while ((SECONDS<deadline)); do
    tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
    if grep -Eq '(TimechoDB|IoTDB)(:[^>]*)?>' "$response" 2>/dev/null; then
      if grep -Eqi '535:.*Metadata lease is fenced|Metadata lease is fenced' "$response"; then record_fail "$label still returned metadata lease 535 after cache recovery"; return 1; fi
      if grep -Eqi 'table.*(does not exist|not exist|unknown)|unknown table' "$response"; then log INFO "$label confirmed dropped table is absent after cache recovery"; return 0; fi
      record_fail "$label did not return an explicit missing-table error"; cat "$response" | tee -a "$log_file"; return 1
    fi
    sleep 1
  done
  record_fail "$label timed out"; return 1
}

formal_begin || { formal_end; exit 1; }
seed_all_models
run_ok table "$query_ip" "use $TABLE_DB; create table drop_base(device string tag,v int64 field); create writable view drop_v as select device as dev,v from drop_base with (schema_cascade=false)" prepare_drop_objects
start_persistent_cli fenced_table_session table "$fault_dn" || { formal_end; exit 1; }
run_persistent_ok_selected_db fenced_table_session "use $TABLE_DB;" pre_partition_table_use_database || { formal_end; exit 1; }
partition_dn "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; drop view drop_v; drop table drop_base" drop_during_partition
run_persistent_lease535_selected_db fenced_table_session "insert into drop_base(time,device,v) values(1,'d1',1);" fenced_dn_stale_table_insert
heal_partition "$fault_dn"
recovery_cache_ok=1
wait_persistent_cache_query fenced_table_session "select count(*) from base;" recovered_lease_and_base_cache || recovery_cache_ok=0
if [ "$recovery_cache_ok" -eq 1 ]; then run_persistent_expected_missing_table fenced_table_session "select * from drop_base;" recovered_dropped_table_absent; else log WARN "skip dropped-table assertion because cache-managed polling did not recover"; fi
close_all_persistent_clis
run_ok table "$query_ip" "use $TABLE_DB; show tables details" capture_predelete_state
formal_end
