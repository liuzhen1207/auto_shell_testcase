#!/bin/bash
HA_CASE_ID=HA_P1_17
HA_CASE_NAME=single_dn_crash_pre_release
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
wait_for_sync_lag_zero
phase_pattern="Pre release info of table ${TABLE_DB}\\.base"
prepare_cn_log_watchers "$phase_pattern" pre_release_phase "$fault_dn" || true
run_sql_background table "$query_ip" "use $TABLE_DB; alter table base add column pre_release_col int32 field" pre_release_ddl
sql_pid=$BACKGROUND_SQL_PID
crash_when_cn_log_matches "$phase_pattern" "$fault_dn" "$sql_pid" pre_release_phase 60 || true
wait_and_check_background_sql pre_release_ddl "$sql_pid" || true
recover_dn_and_sync "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; describe base details; select count(pre_release_col) from base" pre_release_final_state
formal_end
