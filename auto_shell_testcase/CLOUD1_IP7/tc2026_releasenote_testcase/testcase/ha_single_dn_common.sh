#!/bin/bash
# Helpers for single-DataNode crash cases. Source ha_common.sh first.

crash_dn(){
  local ip=$1 begin=$(date +%s)
  ssh -n -o ControlMaster=auto -o ControlPersist=600 -o ControlPath="/tmp/ha_${testdb}_%h_%p" "$os_user@$ip" "pids=\$(ps -ef | grep '${testdb}' | grep DataNode | grep -v grep | awk '{print \$2}'); [ -n \"\$pids\" ] && kill -9 \$pids" >>"$log_file" 2>&1 || true
  while [ $(( $(date +%s)-begin )) -le 60 ]; do
    if ! ssh -n -o ControlMaster=auto -o ControlPersist=600 -o ControlPath="/tmp/ha_${testdb}_%h_%p" "$os_user@$ip" "ps -ef | grep '${testdb}' | grep DataNode | grep -v grep >/dev/null" 2>/dev/null; then
      log INFO "DataNode $ip crashed by SIGKILL"
      return 0
    fi
    sleep 1
  done
  record_fail "DataNode $ip crash injection did not stop the target process"
  return 1
}

recover_dn_and_sync(){
  local ip=$1
  start_dn "$ip" || return 1
  wait_for_sync_lag_zero "$sync_lag_timeout_seconds"
}

strict_absent(){
  local dialect=$1 host=$2 sql=$3 label=$4 out="${artifact_dir}/${4}.out" rc=0
  timeout 30s "$cli_dir/sbin/start-cli.sh" -u root -h "$host" -timeout 20 -sql_dialect "$dialect" -e "$sql" >"$out" 2>&1 || rc=$?
  if [ "$rc" -eq 124 ]; then record_fail "$label timed out"; return 1; fi
  if grep -Eqi 'does not exist|not exist|unknown (table|view|database)|cannot be resolved' "$out" && ! grep -Eqi '535:|Metadata lease is fenced' "$out"; then
    log INFO "$label confirmed object absent"
    return 0
  fi
  record_fail "$label did not return a strict object-absent error"
  cat "$out" | tee -a "$log_file"
  return 1
}

assert_expected_text(){
  local file=$1 pattern=$2 label=$3
  if grep -Eqi "$pattern" "$file"; then log INFO "$label verified"; else record_fail "$label missing expected result"; fi
}

run_sql_background(){
  local dialect=$1 host=$2 sql=$3 label=$4
  "$dialect" "$host" "$sql" >"${artifact_dir}/${label}.out" 2>&1 &
  BACKGROUND_SQL_PID=$!
}

wait_and_check_background_sql(){
  local label=$1 pid=${2:-$BACKGROUND_SQL_PID} rc=0
  wait "$pid" || rc=$?
  if [ "$rc" -eq 0 ] && ! grep -Eqi 'Exception|ERROR|Error' "${artifact_dir}/${label}.out"; then
    log INFO "$label success"
    return 0
  fi
  record_fail "$label failed"
  tail -30 "${artifact_dir}/${label}.out" | tee -a "$log_file"
  return 1
}

# Best-effort black-box phase trigger. A case fails explicitly if the requested phase was not
# observed before the SQL completed; this prevents an un-injected run from being reported PASS.
HA_CN_WATCH_PIDS=()
HA_CN_WATCH_LABEL=
HA_CN_WATCH_TARGET=
HA_CN_WATCH_PATTERN=
HA_SSH_CONTROL_PATH="/tmp/ha_${testdb}_%h_%p"

kill_watcher_tree(){
  local parent=$1 child
  for child in $(ps -o pid= --ppid "$parent" 2>/dev/null); do kill_watcher_tree "$child"; done
  kill "$parent" 2>/dev/null || true
}

stop_cn_log_watchers(){
  local pid
  for pid in "${HA_CN_WATCH_PIDS[@]:-}"; do kill_watcher_tree "$pid"; done
  for pid in "${HA_CN_WATCH_PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
  local watch_cn
  for watch_cn in "${CN_IPS[@]}"; do
    ssh -n -o ConnectTimeout=5 "$os_user@$watch_cn" "pids=\$(ps -eo pid,args | grep '[t]ail -n0 -F ${cn_db_dir}/logs/log_confignode_all.log' | awk '{print \$1}'); [ -z \"\$pids\" ] || kill \$pids" >/dev/null 2>&1 || true
  done
  HA_CN_WATCH_PIDS=()
  HA_CN_WATCH_LABEL=
}

prepare_cn_log_watchers(){
  local pattern=$1 label=$2 ip=$3 cn remote_cmd ready_deadline ready_count cn_index
  stop_cn_log_watchers
  HA_CN_WATCH_LABEL=$label
  HA_CN_WATCH_TARGET=$ip
  HA_CN_WATCH_PATTERN=$pattern
  rm -f "${artifact_dir}/${label}.matched" "${artifact_dir}/${label}.triggered" "${artifact_dir}/${label}.watch.lock" "${artifact_dir}/${label}_ready_"*.out
  # Warm a multiplexed SSH channel to the fault target before the phase starts.
  ssh -n -o ControlMaster=auto -o ControlPersist=600 -o ControlPath="$HA_SSH_CONTROL_PATH" "$os_user@$ip" true >/dev/null 2>&1 || {
    record_fail "$label could not preconnect to fault DataNode $ip"
    return 1
  }
  for cn in "${CN_IPS[@]}"; do
    : >"${artifact_dir}/${label}_${cn}.out"
    remote_cmd="printf '__HA_WATCH_READY__\n'; tail -n0 -F '${cn_db_dir}/logs/log_confignode_all.log' | grep --line-buffered -m1 -E '$pattern'"
    (
      timeout 3600s ssh -n -o ControlMaster=auto -o ControlPersist=600 -o ControlPath="$HA_SSH_CONTROL_PATH" "$os_user@$cn" "$remote_cmd" 2>/dev/null |
      while IFS= read -r line; do
        if [ "$line" = '__HA_WATCH_READY__' ]; then
          touch "${artifact_dir}/${label}_ready_${cn}.out"
          continue
        fi
        if mkdir "${artifact_dir}/${label}.watch.lock" 2>/dev/null; then
          printf '%s\n%s\n' "$cn" "$line" >"${artifact_dir}/${label}.matched"
          ssh -n -o ControlMaster=auto -o ControlPersist=600 -o ControlPath="$HA_SSH_CONTROL_PATH" "$os_user@$ip" "pids=\$(ps -ef | grep '${testdb}' | grep DataNode | grep -v grep | awk '{print \$2}'); [ -n \"\$pids\" ] && kill -9 \$pids" >/dev/null 2>&1
          echo $? >"${artifact_dir}/${label}.triggered"
          break
        fi
      done
    ) &
    HA_CN_WATCH_PIDS+=("$!")
  done
  ready_deadline=$((SECONDS+15))
  while ((SECONDS<ready_deadline)); do
    ready_count=0
    for cn in "${CN_IPS[@]}"; do
      [ -f "${artifact_dir}/${label}_ready_${cn}.out" ] && ready_count=$((ready_count+1))
    done
    [ "$ready_count" -eq "${#CN_IPS[@]}" ] && { log INFO "$label CN log streams armed before SQL"; return 0; }
    sleep 0.05
  done
  stop_cn_log_watchers
  record_fail "$label could not arm all ConfigNode log streams"
  return 1
}

crash_when_cn_log_matches(){
  local pattern=$1 ip=$2 sql_pid=$3 label=$4 timeout_seconds=${5:-60}
  local begin=$(date +%s) matched_cn
  if [ "$HA_CN_WATCH_LABEL" != "$label" ] || [ "$HA_CN_WATCH_TARGET" != "$ip" ] || [ "$HA_CN_WATCH_PATTERN" != "$pattern" ]; then
    prepare_cn_log_watchers "$pattern" "$label" "$ip" || return 1
  fi
  while kill -0 "$sql_pid" 2>/dev/null && [ $(( $(date +%s)-begin )) -lt "$timeout_seconds" ] && [ ! -f "${artifact_dir}/${label}.triggered" ]; do
    sleep 0.005
  done
  # Give the watcher time to finish the pre-authenticated SIGKILL command.
  local grace_deadline=$((SECONDS+2))
  while [ ! -f "${artifact_dir}/${label}.triggered" ] && [ $SECONDS -lt "$grace_deadline" ]; do sleep 0.01; done
  if [ -s "${artifact_dir}/${label}.matched" ] && [ -f "${artifact_dir}/${label}.triggered" ]; then
    matched_cn=$(head -1 "${artifact_dir}/${label}.matched")
    log INFO "$label observed on ConfigNode $matched_cn; preconnected SIGKILL sent to $ip"
    stop_cn_log_watchers
    crash_dn "$ip"
    return 0
  fi
  stop_cn_log_watchers
  record_fail "$label was not observed before SQL completion or timeout; fault was not injected"
  return 1
}
