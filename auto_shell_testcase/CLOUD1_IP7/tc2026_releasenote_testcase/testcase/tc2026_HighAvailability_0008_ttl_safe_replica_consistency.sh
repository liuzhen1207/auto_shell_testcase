#!/bin/bash
HA_CASE_ID=HA_P0_05
HA_CASE_NAME=ttl_safe_replica_consistency
source "$(dirname "$0")/ha_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
log INFO "TTL=7d and current timestamps prevent TTL expiry from contaminating replica diffs"
assert_all_models "$query_ip"
formal_end
