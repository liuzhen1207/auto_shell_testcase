#!/bin/bash
HA_CASE_ID=HA_P1_01
HA_CASE_NAME=dn_down_ttl_device_database
source "$(dirname "$0")/ha_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models || { formal_end; exit 1; }
wait_for_sync_lag_zero "$sync_lag_timeout_seconds" seed_before_fault || { formal_end; exit 1; }
run_ok table "$query_ip" "create database ${TABLE_DB}_drop; use ${TABLE_DB}_drop; create table t(device string tag,v int64 field); insert into t(time,device,v) values($(date +%s%3N),'d1',1)" prepare_database
stop_dn "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; alter table base set properties ttl=86400000; alter table base set properties ttl='INF'; delete devices from base where device='d1'; drop database ${TABLE_DB}_drop" ttl_delete_device_drop_database
start_dn "$fault_dn" || { formal_end; exit 1; }
wait_for_sync_lag_zero "$sync_lag_timeout_seconds" main_recovered || { formal_end; exit 1; }
run_ok table "$fault_dn" "use $TABLE_DB; show tables details; select count(*) from base where device='d1'" recovered_metadata
formal_end
