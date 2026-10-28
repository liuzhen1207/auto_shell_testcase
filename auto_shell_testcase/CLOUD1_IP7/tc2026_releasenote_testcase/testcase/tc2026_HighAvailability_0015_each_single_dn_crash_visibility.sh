#!/bin/bash
HA_CASE_ID=HA_P0_15
HA_CASE_NAME=each_single_dn_crash_visibility
source "$(dirname "$0")/ha_common.sh"
source "$(dirname "$0")/ha_single_dn_common.sh"
formal_begin || { formal_end; exit 1; }
seed_all_models
flush_all
wait_for_sync_lag_zero
capture_counts "$query_ip" "${artifact_dir}/explicit_baseline" || record_fail "explicit baseline capture failed"
for ip in "${DN_IPS[@]}"; do
  crash_dn "$ip" || continue
  peer=""; for p in "${DN_IPS[@]}"; do [ "$p" != "$ip" ] && peer=$p && break; done
  if capture_counts "$peer" "${artifact_dir}/crash_${ip}"; then
    for model in tree base writable tree_view; do
      diff -u "${artifact_dir}/explicit_baseline_${model}.normalized" "${artifact_dir}/crash_${ip}_${model}.normalized" >"${artifact_dir}/crash_${ip}_${model}.diff" || record_fail "$model visibility changed when $ip crashed"
    done
  else record_fail "all-model query failed when $ip crashed"; fi
  recover_dn_and_sync "$ip"
done
formal_end
