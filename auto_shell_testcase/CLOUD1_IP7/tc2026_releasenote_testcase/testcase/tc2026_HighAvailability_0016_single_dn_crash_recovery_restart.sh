#!/bin/bash
HA_CASE_ID=HA_P0_16
HA_CASE_NAME=single_dn_crash_recovery_restart
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
wait_for_sync_lag_zero
crash_dn "$fault_dn"
now=$(date +%s%3N)
run_ok table "$query_ip" "use $TABLE_DB; alter table base add column recovered_col int32 field; insert into base(time,device,site,temp,status,payload,recovered_col) values($now,'recover','p0',33.5,'ok',to_object(true,0,X'1617'),16)" ddl_data_during_crash
run_ok tree "$query_ip" "insert into $TREE_DB.non_aligned_d(time,s1,s2) values($now,303,30.3)" tree_data_during_crash
recover_dn_and_sync "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; select recovered_col from base where device='recover'" first_recovery_check
stop_dn "$fault_dn"
start_dn "$fault_dn"
wait_for_sync_lag_zero
run_ok table "$query_ip" "use $TABLE_DB; select recovered_col from base where device='recover'" second_restart_check
formal_end
