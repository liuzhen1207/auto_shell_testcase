#!/bin/bash
HA_CASE_ID=HA_P0_09
HA_CASE_NAME=partition_fence_table_select
source "$(dirname "$0")/ha_common.sh"

# Execute a command through an already authenticated interactive CLI and require it to return
# successfully. This is intentionally local to this copied case so existing cases/common behavior
# remain unchanged.
run_persistent_ok_local(){
  local name=$1 sql=$2 label=$3 timeout_seconds=${4:-30}
  local fd=${persistent_cli_fd[$name]} out=${persistent_cli_out[$name]}
  local start_size response="${artifact_dir}/${label}.out" deadline
  start_size=$(wc -c <"$out")
  printf '%s\n' "$sql" >&$fd
  deadline=$((SECONDS+timeout_seconds))
  while ((SECONDS<deadline)); do
    tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
    if grep -Eq '(TimechoDB|IoTDB)(:[^>]*)?>' "$response" 2>/dev/null; then
      if grep -Eqi 'Exception|ERROR|Error|failed|does not exist|unknown' "$response"; then
        record_fail "$label returned an error"
        cat "$response" | tee -a "$log_file"
        return 1
      fi
      log INFO "$label completed through pre-authenticated session"
      return 0
    fi
    sleep 1
  done
  tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
  record_fail "$label timed out"
  return 1
}

# The common helper recognizes only the prompt before a database is selected. In this case the
# session deliberately executes USE before isolation, so accept prompts such as TimechoDB:db_name>
# when judging the fenced SELECT response. Keep the override local to this case.
run_persistent_rejected(){
  local name=$1 sql=$2 label=$3 timeout_seconds=${4:-30}
  local fd=${persistent_cli_fd[$name]} out=${persistent_cli_out[$name]}
  local start_size response="${artifact_dir}/${label}.out" deadline
  start_size=$(wc -c <"$out")
  printf '%s\n' "$sql" >&$fd
  deadline=$((SECONDS+timeout_seconds))
  while ((SECONDS<deadline)); do
    tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
    if grep -Eq '(TimechoDB|IoTDB)(:[^>]*)?>' "$response" 2>/dev/null; then
      if grep -Eqi 'isolat|fenc|lease|cannot.*ConfigNode|unable.*ConfigNode|temporarily unavailable|Exception|ERROR|Error' "$response"; then
        log INFO "$label rejected promptly through pre-authenticated session"
        return 0
      fi
      record_fail "$label returned without fenced/isolated error"
      cat "$response" | tee -a "$log_file"
      return 1
    fi
    sleep 1
  done
  tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
  record_fail "$label timed out in pre-authenticated session instead of promptly returning fenced/isolated error"
  return 1
}

# Remove the DN-to-CN partition and immediately observe three independent recovery milestones:
# T1 = ConfigNode reports the DN Running; T2 = the DN query no longer returns lease-fenced 535;
# T3 = the renamed writable view can be queried successfully. The DN query reuses the Table session
# that authenticated and selected the database before isolation, so login, USE DATABASE and new
# connection establishment cannot affect the cache-recovery measurement. SHOW CLUSTER and the pure
# SELECT are launched together in each polling round so their timestamps are directly comparable.
heal_partition_and_observe_recovery(){
  local ip=$1 timeout_seconds=${HA_RECOVERY_OBSERVE_TIMEOUT:-120}
  local timeline="${artifact_dir}/recovery_timeline.tsv"
  local summary="${artifact_dir}/recovery_milestones.txt"
  local t0_ms now_ms elapsed_ms attempt=0 deadline
  local t1_ms="" t2_ms="" t3_ms="" show_pid show_rc query_rc query_deadline
  local show_out query_out dn_state lease_fenced query_success
  local query_fd=${persistent_cli_fd[fenced_table_session]}
  local query_session_out=${persistent_cli_out[fenced_table_session]} start_size

  ssh -n "$os_user@$ip" "iptables -D INPUT -j HA_META_IN 2>/dev/null || true; iptables -D OUTPUT -j HA_META_OUT 2>/dev/null || true; iptables -F HA_META_IN 2>/dev/null || true; iptables -F HA_META_OUT 2>/dev/null || true; iptables -X HA_META_IN 2>/dev/null || true; iptables -X HA_META_OUT 2>/dev/null || true" || {
    record_fail "failed to remove network partition rules on $ip"
    return 1
  }
  partitioned_dn=""
  t0_ms=$(date +%s%3N)
  deadline=$((SECONDS+timeout_seconds))
  printf 'attempt\telapsed_ms\tshow_cluster_rc\tdn_state\tpersistent_select_rc\tlease_535\tview_query_success\n' >"$timeline"
  log INFO "T0 network partition rules removed on $ip epoch_ms=$t0_ms; start pure SELECT recovery observation through pre-selected persistent session"

  while ((SECONDS<=deadline)); do
    attempt=$((attempt+1))
    show_out="${artifact_dir}/recovery_show_cluster_${attempt}.out"
    query_out="${artifact_dir}/recovery_dn_query_${attempt}.out"
    show_rc=0
    query_rc=124

    start_size=$(wc -c <"$query_session_out")
    timeout 10s "$cli_dir/sbin/start-cli.sh" -u root -h "$query_ip" -timeout 10 -sql_dialect tree -e "show cluster" >"$show_out" 2>&1 &
    show_pid=$!
    printf 'select count(*) from metadata_v2;\n' >&$query_fd
    query_deadline=$((SECONDS+10))
    while ((SECONDS<query_deadline)); do
      tail -c +$((start_size+1)) "$query_session_out" >"$query_out" 2>/dev/null || true
      if grep -Eq '(TimechoDB|IoTDB)(:[^>]*)?>' "$query_out" 2>/dev/null; then
        query_rc=0
        break
      fi
      sleep 0.1
    done
    if [ "$query_rc" -eq 124 ]; then
      tail -c +$((start_size+1)) "$query_session_out" >"$query_out" 2>/dev/null || true
    fi
    wait "$show_pid" || show_rc=$?

    now_ms=$(date +%s%3N)
    elapsed_ms=$((now_ms-t0_ms))
    dn_state=$(grep -F "$ip" "$show_out" 2>/dev/null | head -1 | tr '\t\r\n' '   ')
    lease_fenced=0
    query_success=0
    grep -Eq '535:.*Metadata lease is fenced|Metadata lease is fenced' "$query_out" 2>/dev/null && lease_fenced=1
    if [ "$query_rc" -eq 0 ] && [ "$lease_fenced" -eq 0 ] && ! grep -Eqi 'Exception|ERROR|Error|does not exist|unknown' "$query_out" && grep -Eqi 'count|Total line number' "$query_out"; then
      query_success=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$attempt" "$elapsed_ms" "$show_rc" "$dn_state" "$query_rc" "$lease_fenced" "$query_success" >>"$timeline"

    if [ -z "$t1_ms" ] && grep -F "$ip" "$show_out" 2>/dev/null | grep -q 'Running'; then
      t1_ms=$elapsed_ms
      log INFO "T1 DN $ip first observed Running by SHOW CLUSTER elapsed_ms=$t1_ms attempt=$attempt"
    fi
    if [ -z "$t2_ms" ] && [ "$query_rc" -ne 124 ] && [ -s "$query_out" ] && [ "$lease_fenced" -eq 0 ]; then
      t2_ms=$elapsed_ms
      log INFO "T2 DN $ip pure persistent SELECT first completed without metadata lease 535 elapsed_ms=$t2_ms attempt=$attempt rc=$query_rc"
    fi
    if [ -z "$t3_ms" ] && [ "$query_success" -eq 1 ]; then
      t3_ms=$elapsed_ms
      log INFO "T3 metadata_v2 pure persistent SELECT first succeeded on $ip elapsed_ms=$t3_ms attempt=$attempt"
    fi
    if [ -n "$t1_ms" ] && [ -n "$t2_ms" ] && [ -n "$t3_ms" ]; then
      break
    fi
    if [ "$query_rc" -eq 124 ]; then
      record_fail "persistent SELECT did not return a prompt within 10s during recovery observation; stop polling to avoid queuing statements"
      break
    fi
    sleep 1
  done

  {
    echo "T0_epoch_ms=$t0_ms"
    echo "T1_running_elapsed_ms=${t1_ms:-NOT_OBSERVED}"
    echo "T2_no_535_elapsed_ms=${t2_ms:-NOT_OBSERVED}"
    echo "T3_view_query_success_elapsed_ms=${t3_ms:-NOT_OBSERVED}"
    echo "timeline=$timeline"
  } >"$summary"
  cat "$summary" | tee -a "$log_file"

  [ -n "$t1_ms" ] || record_fail "T1 DN $ip was not observed Running within ${timeout_seconds}s"
  [ -n "$t2_ms" ] || record_fail "T2 pure persistent SELECT on $ip continued returning metadata lease 535 or did not respond within ${timeout_seconds}s"
  [ -n "$t3_ms" ] || record_fail "T3 pure persistent SELECT on metadata_v2 was not successful on $ip within ${timeout_seconds}s"
  [ -n "$t1_ms" ] && [ -n "$t2_ms" ] && [ -n "$t3_ms" ]
}

formal_begin || { formal_end; exit 1; }
seed_all_models
run_ok table "$query_ip" "use $TABLE_DB; create writable view metadata_v as select device as dev,temp from base with (schema_cascade=false)" prepare_metadata_view
start_persistent_cli fenced_table_session table "$fault_dn" || { formal_end; exit 1; }
start_persistent_cli fenced_tree_session tree "$fault_dn" || { formal_end; exit 1; }

# Select the database while ConfigNodes are reachable. The fenced assertion below then exercises
# only SELECT instead of being intercepted by USE DATABASE.
run_persistent_ok_local fenced_table_session "use $TABLE_DB;" pre_partition_table_use_database || { formal_end; exit 1; }

partition_dn "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; alter table base add column humidity double field; alter table base set properties ttl=604800000; alter view metadata_v rename to metadata_v2" normal_dn_metadata_change
run_persistent_rejected fenced_table_session "select * from base;" fenced_dn_table_select
run_persistent_rejected fenced_tree_session "select * from $TREE_DB.**;" fenced_dn_tree_query_control
heal_partition_and_observe_recovery "$fault_dn"
close_all_persistent_clis
run_ok table "$fault_dn" "use $TABLE_DB; describe base details; select count(*) from metadata_v2" recovered_dn_cache_reload
formal_end
