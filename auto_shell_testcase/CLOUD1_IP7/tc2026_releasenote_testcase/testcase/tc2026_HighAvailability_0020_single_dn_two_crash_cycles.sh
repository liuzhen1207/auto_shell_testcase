#!/bin/bash
HA_CASE_ID=HA_P1_20
HA_CASE_NAME=single_dn_two_crash_cycles
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
for round in 1 2; do
  wait_for_sync_lag_zero
  crash_dn "$fault_dn"
  run_ok table "$query_ip" "use $TABLE_DB; alter table base add column cycle_${round} int32 field; alter view writable_v add column cycle_${round} as vcycle_${round}" cycle_${round}_ddl
  recover_dn_and_sync "$fault_dn"
  run_ok table "$query_ip" "use $TABLE_DB; select count(cycle_${round}) from base; select count(vcycle_${round}) from writable_v" cycle_${round}_recovery
done
formal_end
