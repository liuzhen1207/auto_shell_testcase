#!/bin/bash
HA_CASE_ID=HA_P1_19
HA_CASE_NAME=single_dn_crash_rollback
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
wait_for_sync_lag_zero
# Concurrent identical column extensions create a real conflict after both requests have started;
# at least one Procedure must either serialize safely or enter rollback. The fault is injected only
# after a rollback marker for this table is observed.
phase_pattern="Rolled back pid=.*Column.*rollback_col.*already exist.*AddTableColumnProcedure"
prepare_cn_log_watchers "$phase_pattern" rollback_phase "$fault_dn" || true
run_sql_background table "$query_ip" "use $TABLE_DB; alter table base add column rollback_col int32 field" rollback_ddl_a
pid_a=$BACKGROUND_SQL_PID
run_sql_background table "${DN_IPS[2]}" "use $TABLE_DB; alter table base add column rollback_col int32 field" rollback_ddl_b
pid_b=$BACKGROUND_SQL_PID
crash_when_cn_log_matches "$phase_pattern" "$fault_dn" "$pid_b" rollback_phase 60 || true
wait "$pid_a" || true
wait "$pid_b" || true
recover_dn_and_sync "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; describe base details; insert into base(time,device,site,temp,status,payload,rollback_col) values($(date +%s%3N),'rollback','p1',42.5,'ok',to_object(false,0,X'2021'),19); select rollback_col from base where device='rollback'" rollback_final_state
formal_end
