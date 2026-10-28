#!/bin/bash
HA_CASE_ID=HA_P0_03
HA_CASE_NAME=dn_down_drop_table_view
source "$(dirname "$0")/ha_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
run_ok table "$query_ip" "use $TABLE_DB; create table drop_base(device string tag,v int64 field); create writable view drop_v as select device as dev,v from drop_base with (schema_cascade=false)" prepare_drop_objects
stop_dn "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; drop view drop_v; drop table drop_base" drop_with_dn_down
start_dn "$fault_dn"
run_rejected table "$fault_dn" "use $TABLE_DB; select * from drop_base" dropped_table_absent_after_recovery
formal_end
