#!/bin/bash
HA_CASE_ID=HA_P1_22
HA_CASE_NAME=single_dn_writable_view_object
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
run_ok table "$query_ip" "use $TABLE_DB; create table object_source(device string tag,site string tag,payload object field,score int32 field); create writable view object_view as select device as dev,site as area,payload,score from object_source with (schema_cascade=false)" prepare_object_view
wait_for_sync_lag_zero
crash_dn "$fault_dn"
now=$(date +%s%3N)
run_ok table "$query_ip" "use $TABLE_DB; alter table object_source add column extra_obj object field; alter view object_view add column extra_obj as view_extra_obj; insert into object_view(time,dev,area,payload,score,view_extra_obj) values($now,'ov1','p1',to_object(true,0,X'2223'),22,to_object(false,0,X'2425')); select payload,view_extra_obj from object_view where dev='ov1'" object_view_change_while_crashed
recover_dn_and_sync "$fault_dn"
run_ok table "$query_ip" "use $TABLE_DB; select payload,extra_obj from object_source where device='ov1'; select payload,view_extra_obj from object_view where dev='ov1'; describe object_source details; describe object_view details" recovered_object_view_mapping
formal_end
