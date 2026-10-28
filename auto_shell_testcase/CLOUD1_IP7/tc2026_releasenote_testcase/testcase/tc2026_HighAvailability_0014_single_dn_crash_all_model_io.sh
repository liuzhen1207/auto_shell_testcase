#!/bin/bash
HA_CASE_ID=HA_P0_14
HA_CASE_NAME=single_dn_crash_all_model_io
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
wait_for_sync_lag_zero
crash_dn "$fault_dn"
now=$(date +%s%3N)
run_ok tree "$query_ip" "insert into $TREE_DB.aligned_d(time,s1,s2) aligned values($now,101,10.1); insert into $TREE_DB.non_aligned_d(time,s1,s2) values($now,202,20.2)" tree_io_while_dn_crashed
run_ok table "$query_ip" "use $TABLE_DB; insert into base(time,device,site,temp,status,payload) values($now,'io_base','p0',31.5,'ok',to_object(true,0,X'1213')); insert into writable_v(time,dev,area,temp,payload) values($((now+1)),'io_view','p0',32.5,to_object(false,0,X'1415')); select count(*) from base; select count(*) from writable_v; select count(*) from tree_v" table_view_io_while_dn_crashed
recover_dn_and_sync "$fault_dn"
assert_all_models "$query_ip"
formal_end
