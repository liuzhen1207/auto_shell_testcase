#!/bin/bash
HA_CASE_ID=HA_P1_18
HA_CASE_NAME=single_dn_crash_commit_release
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
wait_for_sync_lag_zero
phase_pattern="Commit release info of table ${TABLE_DB}\\.base"
prepare_cn_log_watchers "$phase_pattern" commit_release_phase "$fault_dn" || true
run_sql_background table "$query_ip" "use $TABLE_DB; alter table base add column commit_release_col int32 field" commit_release_ddl
sql_pid=$BACKGROUND_SQL_PID
crash_when_cn_log_matches "$phase_pattern" "$fault_dn" "$sql_pid" commit_release_phase 60 || true
wait_and_check_background_sql commit_release_ddl "$sql_pid" || true
recover_dn_and_sync "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; describe base details; insert into base(time,device,site,temp,status,payload,commit_release_col) values($(date +%s%3N),'commit','p1',41.5,'ok',to_object(true,0,X'1819'),18); select commit_release_col from base where device='commit'" commit_release_final_state
formal_end
