#!/bin/bash
# Scope note:
# - P0 requirement assertions in this case are Table-model TTL SET/UNSET and DELETE DEVICE while
#   one DataNode is down.
# - Tree-model SET/UNSET TTL is retained only as a P2 compatibility observation. The current
#   requirement/technical design explicitly lists Table TTL, not Tree TTL. A documented
#   "507: Update dataNode ttl cache failed" from the Tree statements is recorded as WARN evidence
#   and MUST NOT increase fail_flag or affect the requirement pass rate.
HA_CASE_ID=HA_P0_13
HA_CASE_NAME=single_dn_crash_ttl_device
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"

observe_tree_ttl_with_single_dn_down(){
  local out="${artifact_dir}/tree_ttl_p2_compatibility_observation.out" rc=0
  timeout 30s "$cli_dir/sbin/start-cli.sh" -u root -h "$query_ip" -timeout 20 -sql_dialect tree \
    -e "set ttl to $TREE_DB.** 86400000; unset ttl to $TREE_DB.**" >"$out" 2>&1 || rc=$?
  if [ "$rc" -eq 124 ]; then
    record_fail "P2 Tree TTL compatibility observation timed out"
    return 1
  fi
  if grep -Eqi '507:.*Update dataNode ttl cache failed|Update dataNode ttl cache failed' "$out"; then
    warn_count=$((warn_count+1))
    log WARN "P2 observation only: Tree SET/UNSET TTL returned documented 507 with one DN down; excluded from requirement pass rate"
    return 0
  fi
  if [ "$rc" -eq 0 ] && ! grep -Eqi 'Exception|ERROR|Error' "$out"; then
    log INFO "P2 observation: Tree SET/UNSET TTL also succeeded with one DN down"
    return 0
  fi
  record_fail "P2 Tree TTL compatibility observation returned an unexpected result"
  tail -30 "$out" | tee -a "$log_file"
  return 1
}

formal_begin || { formal_end; exit 1; }
seed_all_models
wait_for_sync_lag_zero
crash_dn "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; alter table base set properties ttl=86400000; alter table base set properties ttl='INF'; delete devices from base where device='d1'" table_ttl_delete_device
observe_tree_ttl_with_single_dn_down
recover_dn_and_sync "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; show tables details; select count(*) from base where device='d1'; select count(*) from base where device='d2'" recovered_ttl_device_state
formal_end
