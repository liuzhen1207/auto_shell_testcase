#!/bin/bash
HA_CASE_ID=HA_P0_01
HA_CASE_NAME=dn_down_create_alter
source "$(dirname "$0")/ha_common.sh"
log INFO "DN down: create/alter table, writable view and TTL"
formal_begin || { formal_end; exit 1; }
seed_all_models
stop_dn "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; create table created_while_dn_down(device string tag,v int64 field); create writable view created_view_while_dn_down as select device as dev,v from created_while_dn_down with (schema_cascade=false); alter table base add column humidity int32 field; alter table base alter column humidity set data type int64; alter table base set properties ttl=604800000; alter view writable_v add column status as state" create_alter_metadata_with_dn_down
start_dn "$fault_dn"
run_ok table "$fault_dn" "use $TABLE_DB; describe created_while_dn_down details; describe created_view_while_dn_down details; describe base details; describe writable_v details" recovered_dn_metadata
assert_all_models "$fault_dn"
formal_end
