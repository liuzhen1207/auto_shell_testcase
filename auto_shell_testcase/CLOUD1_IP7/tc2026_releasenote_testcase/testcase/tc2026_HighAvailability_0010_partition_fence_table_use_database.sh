#!/bin/bash
HA_CASE_ID=HA_P0_10
HA_CASE_NAME=partition_fence_table_use_database
source "$(dirname "$0")/ha_common.sh"

# USE DATABASE does not read a cache governed by the metadata lease framework. When every
# ConfigNode is unreachable through DROP rules, waiting for the ConfigNode RPC is expected and
# must not be reported as a lease-fence failure. Conversely, a lease 535 response would mean USE
# was unexpectedly coupled to the cache fence path.
observe_persistent_use_database_cn_wait(){
  local name=$1 sql=$2 label=$3 observation_seconds=${4:-5}
  local fd=${persistent_cli_fd[$name]} out=${persistent_cli_out[$name]}
  local start_size response="${artifact_dir}/${label}.out" deadline
  start_size=$(wc -c <"$out")
  printf '%s\n' "$sql" >&$fd
  deadline=$((SECONDS+observation_seconds))
  while ((SECONDS<deadline)); do
    tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
    if grep -Eq '(TimechoDB|IoTDB)(:[^>]*)?>' "$response" 2>/dev/null; then
      if grep -Eqi '535:.*Metadata lease is fenced|Metadata lease is fenced' "$response"; then
        record_fail "$label unexpectedly returned metadata lease 535"
        cat "$response" | tee -a "$log_file"
        return 1
      fi
      if grep -Eqi 'cannot.*ConfigNode|unable.*ConfigNode|connect.*ConfigNode|unavailable|Exception|ERROR|Error' "$response"; then
        log INFO "$label returned a ConfigNode connectivity error as allowed for a non-lease-managed operation"
        return 0
      fi
      record_fail "$label unexpectedly succeeded while all ConfigNodes were isolated"
      cat "$response" | tee -a "$log_file"
      return 1
    fi
    sleep 1
  done
  tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
  log INFO "$label remained pending for ${observation_seconds}s as expected: USE DATABASE waits on unreachable ConfigNode RPC and is not governed by metadata lease cache fencing"
  return 0
}

run_persistent_ok_selected_db(){
  local name=$1 sql=$2 label=$3 timeout_seconds=${4:-30}
  local fd=${persistent_cli_fd[$name]} out=${persistent_cli_out[$name]} start_size response="${artifact_dir}/${label}.out" deadline
  start_size=$(wc -c <"$out"); printf '%s\n' "$sql" >&$fd; deadline=$((SECONDS+timeout_seconds))
  while ((SECONDS<deadline)); do tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true; if grep -Eq '(TimechoDB|IoTDB)(:[^>]*)?>' "$response" 2>/dev/null; then if grep -Eqi 'Exception|ERROR|Error|failed|does not exist|unknown' "$response"; then record_fail "$label returned an error"; return 1; fi; log INFO "$label completed"; return 0; fi; sleep 1; done
  record_fail "$label timed out"; return 1
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

formal_begin || { formal_end; exit 1; }
seed_all_models
run_ok table "$query_ip" "use $TABLE_DB; create writable view metadata_v as select device as dev,temp from base with (schema_cascade=false)" prepare_metadata_view

# Authenticate before isolation, but deliberately do not select a database. This isolates the
# behavior of USE DATABASE after the metadata lease has fenced the DataNode.
start_persistent_cli fenced_table_session table "$fault_dn" || { formal_end; exit 1; }
start_persistent_cli recovery_table_session table "$fault_dn" || { formal_end; exit 1; }
run_persistent_ok_selected_db recovery_table_session "use $TABLE_DB;" pre_partition_recovery_session_use_database || { formal_end; exit 1; }
start_persistent_cli fenced_tree_session tree "$fault_dn" || { formal_end; exit 1; }
partition_dn "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; alter table base add column humidity double field; alter table base set properties ttl=604800000; alter view metadata_v rename to metadata_v2" normal_dn_metadata_change
observe_persistent_use_database_cn_wait fenced_table_session "use $TABLE_DB;" use_database_expected_cn_wait_not_lease_fence
run_persistent_rejected fenced_tree_session "select * from $TREE_DB.**;" fenced_dn_tree_query_control
heal_partition "$fault_dn"
recovery_cache_ok=1
wait_persistent_cache_query recovery_table_session "select count(*) from metadata_v2;" recovered_metadata_view_cache || recovery_cache_ok=0
close_all_persistent_clis
if [ "$recovery_cache_ok" -eq 1 ]; then run_ok table "$fault_dn" "use $TABLE_DB; describe base details; select count(*) from metadata_v2" recovered_dn_cache_reload; else log WARN "skip final recovery query because cache-managed polling did not recover"; fi
formal_end
