#!/bin/bash
HA_CASE_ID=HA_P0_11
HA_CASE_NAME=single_dn_crash_repeated_alter
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
wait_for_sync_lag_zero
crash_dn "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; alter table base add column c1 int32 field; alter view writable_v add column c1 as vc1; alter table base add column c2 int64 field; alter view writable_v add column c2 as vc2; insert into base(time,device,site,temp,status,payload,c1,c2) values($(date +%s%3N),'crash','p0',30.5,'ok',to_object(true,0,X'11'),11,22)" repeated_alter_while_dn_crashed
recover_dn_and_sync "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; select c1,c2 from base where device='crash'; select vc1,vc2 from writable_v where dev='crash'" recovered_repeated_columns
formal_end
