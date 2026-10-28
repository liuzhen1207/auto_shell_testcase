#!/bin/bash
# Sourced by ha_common.sh. Only defines functions; does not start or stop services.

ha_gate_cli(){
  local host=$1 dialect=$2 sql=$3 output=$4
  timeout -k 5 "${HA_GATE_CLI_TIMEOUT:-30}" "$cli_dir/sbin/start-cli.sh" \
    -u root -h "$host" -timeout "${HA_GATE_CLI_TIMEOUT:-30}" -sql_dialect "$dialect" -e "$sql" >"$output" 2>&1 || return 1
  [ -s "$output" ] && ! grep -Eqi 'Exception|(^|[^a-z])(error|failed)([^a-z]|$)' "$output"
}

ha_gate_setup(){
  local value candidate
  for value in "${HA_SYNC_STABLE_SECONDS:-120}" "${HA_SYNC_POLL_SECONDS:-5}" "${HA_GATE_CLI_TIMEOUT:-30}"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { record_fail 'SYNC_GATE_CONFIG invalid positive integer'; return 1; }
  done
  [ -n "${ha_sync_python:-}" ] && return 0
  for candidate in "${HA_PYTHON:-python3}" python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (2,7) else 1)' >/dev/null 2>&1; then
      ha_sync_python=$candidate
      return 0
    fi
  done
  record_fail 'SYNC_GATE_CONFIG Python 2.7+ or Python 3 required'
  return 1
}

ha_gate_sample(){
  local dir=$1 host=${2:-$query_ip} dialect id ip rc=0
  date -u +%FT%TZ >"$dir/collected_at"
  ha_gate_cli "$host" tree 'show datanodes' "$dir/nodes.raw" || return 1
  for dialect in tree table; do
    ha_gate_cli "$host" "$dialect" 'show migrations' "$dir/migrations_${dialect}.raw" || return 1
    grep -Eq '^Empty set[.]?$|^Total line number = 0[[:space:]]*$' "$dir/migrations_${dialect}.raw" || return 1
    if grep -Eq '^\|[[:space:]]*[0-9]+' "$dir/migrations_${dialect}.raw"; then return 1; fi
    ha_gate_cli "$host" "$dialect" 'show regions' "$dir/regions_${dialect}.raw" || return 1
  done
  "$ha_sync_python" "$ha_sync_support_dir/ha_sync_check.py" topology "$dir" \
    --ips "${DN_IPS[@]}" --dr "$dr_rep_num" --sr "$sr_rep_num" \
    --databases "$TREE_DB" "$TABLE_DB" >"$dir/topology_check.log" 2>&1 || return 1
  # Once fixed data comparisons begin, membership changes cannot silently replace the baseline.
  if [ -n "${ha_consistency_topology:-}" ]; then
    cmp -s "$ha_consistency_topology/topology.tsv" "$dir/topology.tsv" && \
      cmp -s "$ha_consistency_topology/nodes.tsv" "$dir/nodes.tsv" || return 1
  fi
  while read -r id ip; do
    curl -fsS --connect-timeout 3 --max-time 10 "http://${ip}:${dn_metric_port}/metrics" \
      >"$dir/metrics_${id}.prom" 2>"$dir/metrics_${id}.err" || rc=1
  done <"$dir/nodes.tsv"
  "$ha_sync_python" "$ha_sync_support_dir/ha_sync_check.py" metrics "$dir" \
    --cluster "$cluster_id" >"$dir/metrics_check.log" 2>&1 || rc=1
  return "$rc"
}

ha_wait_sync(){
  local timeout_seconds=${1:-$sync_lag_timeout_seconds} label=${2:-sync} host=${3:-$query_ip}
  local begin=$SECONDS stable_since=-1 previous='' sample=0 good now dir gate_dir
  if ! ha_gate_setup || ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || \
      [ "$timeout_seconds" -le "${HA_SYNC_STABLE_SECONDS:-120}" ]; then
    ha_sync_gate_failed=1
    record_fail 'SYNC_GATE_CONFIG timeout must exceed stability window'
    return 1
  fi
  mkdir -p "$artifact_dir/sync_gate" || { ha_sync_gate_failed=1; record_fail 'SYNC_GATE_ERROR cannot create evidence directory'; return 1; }
  gate_dir=$(mktemp -d "$artifact_dir/sync_gate/${label//[^a-zA-Z0-9_.-]/_}.XXXXXX") || {
    ha_sync_gate_failed=1; record_fail 'SYNC_GATE_ERROR cannot create gate directory'; return 1;
  }
  log INFO "SYNC_GATE $label: require complete topology and each directed replica link caught up for ${HA_SYNC_STABLE_SECONDS:-120}s; evidence=$gate_dir"
  while [ $((SECONDS-begin)) -lt "$timeout_seconds" ]; do
    sample=$((sample+1)); dir="$gate_dir/sample_$sample"
    mkdir -p "$dir" || { ha_sync_gate_failed=1; record_fail 'SYNC_GATE_ERROR cannot save sample'; return 1; }
    good=0
    if ha_gate_sample "$dir" "$host"; then good=1; fi
    now=$SECONDS
    [ $((now-begin)) -lt "$timeout_seconds" ] || break
    if [ "$good" -eq 1 ]; then
      if [ "$stable_since" -lt 0 ] || ! cmp -s "$previous/topology.tsv" "$dir/topology.tsv" || \
          ! cmp -s "$previous/nodes.tsv" "$dir/nodes.tsv"; then stable_since=$now; fi
      previous=$dir
      log INFO "SYNC_GATE $label healthy=$((now-stable_since))/${HA_SYNC_STABLE_SECONDS:-120}s elapsed=$((now-begin))s"
      if [ $((now-stable_since)) -ge "${HA_SYNC_STABLE_SECONDS:-120}" ]; then
        ha_sync_ready_dir=$dir
        printf '%s\n' "$dir" >"$gate_dir/ready_sample.txt"
        return 0
      fi
    else
      stable_since=-1; previous=''
      log INFO "SYNC_GATE $label not ready; stability reset; evidence=$dir"
    fi
    sleep "${HA_SYNC_POLL_SECONDS:-5}"
  done
  ha_sync_gate_failed=1
  record_fail "SYNC_GATE_TIMEOUT $label after ${timeout_seconds}s; skip further consistency faults; evidence=$gate_dir"
  return 1
}

ha_compare_fixed(){
  local host=$1 label=$2 model rc=0 prefix="$artifact_dir/$2"
  if ! capture_counts "$host" "$prefix"; then
    record_fail "QUERY_ERROR $label via $host"
    return 1
  fi
  for model in tree base writable tree_view tree_points; do
    if ! diff -u "${artifact_dir}/baseline_${model}.normalized" "${prefix}_${model}.normalized" >"${prefix}_${model}.diff"; then
      record_fail "DATA_MISMATCH $label model=$model via=$host after sync gate"
      rc=1
    fi
  done
  return "$rc"
}

ha_compare_all_entries(){
  local label=$1 host rc=0
  # These are query entry nodes, not a way to force reads from a local Region replica.
  for host in "${DN_IPS[@]}"; do
    ha_compare_fixed "$host" "${label}_${host}" || rc=1
  done
  return "$rc"
}

ha_consistency_rounds(){
  local ip peer current pass round_bad
  ha_consistency_topology=''
  [ "${ha_sync_gate_failed:-0}" -eq 0 ] || { log ERROR 'Skip consistency faults: earlier sync gate failed'; return 1; }
  wait_for_sync_lag_zero "$sync_lag_timeout_seconds" initial || return 1
  ha_consistency_topology=$ha_sync_ready_dir
  capture_counts "$query_ip" "${artifact_dir}/baseline" || { record_fail 'QUERY_ERROR baseline'; return 1; }
  for pass in 1 2; do
    ha_compare_all_entries "baseline_verify_$pass" || return 1
  done
  for ip in "${DN_IPS[@]}"; do
    # Refresh the topology and metrics just before injecting the next fault.
    local pre
    pre=$(mktemp -d "$artifact_dir/sync_gate/pre_${ip}.XXXXXX") || { record_fail 'SYNC_GATE_ERROR cannot save pre-stop sample'; return 1; }
    if ! ha_gate_sample "$pre"; then
      wait_for_sync_lag_zero "$sync_lag_timeout_seconds" "pre_${ip}" || return 1
      ha_compare_all_entries "pre_${ip}" || return 1
    fi
    peer=''; for current in "${DN_IPS[@]}"; do [ "$current" != "$ip" ] && peer=$current && break; done
    round_bad=0
    if stop_dn "$ip"; then
      ha_compare_fixed "$peer" "stop_${ip}" || round_bad=1
    else
      round_bad=1
    fi
    # Always restore the stopped node, including after a failed query or comparison.
    start_dn "$ip" || return 1
    wait_for_sync_lag_zero "$sync_lag_timeout_seconds" "recovered_${ip}" "$peer" || return 1
    ha_compare_all_entries "recovered_${ip}" || return 1
    # A real discrepancy is preserved; avoid additional faults changing its evidence.
    [ "$round_bad" -eq 0 ] || return 1
  done
}
