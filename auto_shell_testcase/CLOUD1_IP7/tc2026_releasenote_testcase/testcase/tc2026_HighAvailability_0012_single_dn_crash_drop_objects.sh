#!/bin/bash
HA_CASE_ID=HA_P0_12
HA_CASE_NAME=single_dn_crash_drop_objects
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
run_ok table "$query_ip" "create database ${TABLE_DB}_drop; use ${TABLE_DB}_drop; create table drop_base(device string tag,v int64 field); create writable view drop_v as select device as dev,v from drop_base with (schema_cascade=false)" prepare_drop_objects
wait_for_sync_lag_zero
crash_dn "$fault_dn"
run_ok table "$query_ip" "use ${TABLE_DB}_drop; drop view drop_v; drop table drop_base; drop database ${TABLE_DB}_drop" drop_objects_while_dn_crashed
recover_dn_and_sync "$fault_dn"
strict_absent table "$query_ip" "use ${TABLE_DB}_drop; select * from drop_base" dropped_objects_absent
formal_end
