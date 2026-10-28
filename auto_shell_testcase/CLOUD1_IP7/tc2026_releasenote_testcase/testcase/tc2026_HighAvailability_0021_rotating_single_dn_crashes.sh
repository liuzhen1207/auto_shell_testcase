#!/bin/bash
HA_CASE_ID=HA_P1_21
HA_CASE_NAME=rotating_single_dn_crashes
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
wait_for_sync_lag_zero
crash_dn "${DN_IPS[1]}"
run_ok table "$query_ip" "use $TABLE_DB; alter table base add column rotate_col int32 field" rotate_round_1_add
recover_dn_and_sync "${DN_IPS[1]}"
crash_dn "${DN_IPS[3]}"
run_ok table "$query_ip" "use $TABLE_DB; alter table base set properties ttl=86400000; alter table base set properties ttl='INF'" rotate_round_2_ttl
recover_dn_and_sync "${DN_IPS[3]}"
run_ok table "$query_ip" "use $TABLE_DB; create table rotate_drop(device string tag,v int32 field)" rotate_prepare_drop
wait_for_sync_lag_zero
crash_dn "${DN_IPS[4]}"
run_ok table "$query_ip" "use $TABLE_DB; drop table rotate_drop" rotate_round_3_drop
recover_dn_and_sync "${DN_IPS[4]}"
strict_absent table "$query_ip" "use $TABLE_DB; select * from rotate_drop" rotate_drop_absent
formal_end
