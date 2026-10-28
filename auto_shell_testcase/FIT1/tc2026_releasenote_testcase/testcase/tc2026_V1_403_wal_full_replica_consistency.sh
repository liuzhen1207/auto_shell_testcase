#!/bin/bash
set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"
prepare_env_dir="${cur_dir}/../prepare_env"
os_user_name=$(awk -F= '/^os_user_name=/{gsub(/ /,"",$2);print $2}' "$conf_file")
db_user_name=$(awk -F= '/^db_user_name=/{gsub(/ /,"",$2);print $2}' "$conf_file")
testdb=$(awk -F= '/^v_testdb=/{gsub(/ /,"",$2);print $2}' "$conf_file")
db_parent_dir=$(awk -F= '/^v_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "$conf_file")
root_pw=$(awk -F= '/^root_pw=/{gsub(/ /,"",$2);print $2}' "$conf_file")
monitor_url=$(awk -F= '/^monitor_url=/{gsub(/ /,"",$2);print $2}' "$conf_file")
CSV_FILE=$(awk -F= '/^CSV_FILE=/{gsub(/ /,"",$2);print $2}' "$conf_file")
db_dir="${db_parent_dir}/${testdb}"
cn_file="${nodeinfo_dir}/confignode_3c.txt"
dn_file="${nodeinfo_dir}/datanode_3d.txt"
query_ip=$(head -1 "$dn_file" | tr -d ' ')
seed_cn_ip=$(head -1 "$cn_file" | tr -d ' '):10710
dn3_ip=$(sed -n '3p' "$dn_file" | tr -d ' ')

DB=root.v1_403
DEVICE=${DB}.d
expected_mode=${V1_403_EXPECTED_MODE:-auto}
if [[ "$expected_mode" == auto ]]; then
  [[ "$testdb" == *v1371* || "$testdb" == *rc2* ]] && expected_mode=before || expected_mode=after
fi
WAL_THRESHOLD=${V1_403_WAL_THRESHOLD:-1048576}
PRESSURE_ROWS=${V1_403_PRESSURE_ROWS:-200000}
SYNC_TIMEOUT=${V1_403_SYNC_TIMEOUT:-900}
run_id=$(date +%Y%m%d_%H%M%S)
artifact_dir="${cur_dir}/V1_403_${run_id}"
log_file="${artifact_dir}/test.log"
fail_flag=0
invalid_flag=0
result_written=0
v_consensus=IoTConsensus
v_warnNum=0
v_warnMessage="No Warn."
test_begin_sec=$(date +%s)
mkdir -p "$artifact_dir"

log() { local level=$1; shift; printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$*" | tee -a "$log_file"; }
fail() { fail_flag=$((fail_flag+1)); v_warnMessage="${v_warnMessage}.$*."; log ERROR "$*"; }
invalid() { invalid_flag=1; v_warnMessage="${v_warnMessage}.$*."; log ERROR "INVALID: $*"; }
write_result() {
  local ec=$1 result=PASS elapsed=$(( $(date +%s)-test_begin_sec )) header
  (( result_written == 0 )) || return 0; result_written=1
  if (( invalid_flag )); then result=INVALID; elif (( ec == 0 && fail_flag == 0 )); then result=PASS; else result=FAIL; fi
  [[ -n "$CSV_FILE" ]] || CSV_FILE=test_result.csv
  header='Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage,maxBMTestTimeSec,sumBMTestTimeSec'
  if [[ ! -f "$CSV_FILE" ]] || ! grep -q '^Time,testTimechoDB' "$CSV_FILE"; then
    printf '%s\n' "$header" > "$CSV_FILE"
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s,0,0\n' \
    "$(date +'%Y-%m-%dT%H:%M:%S.%3N%:z')" "$testdb" "$v_consensus" "$SCRIPT_NAME" \
    "$result" "$elapsed" "$v_warnNum" "$v_warnMessage" >> "$CSV_FILE"
  printf 'testcase result: %s\n' "$result"
  log INFO "RESULT ${result}; elapsed=${elapsed}s; artifacts=${artifact_dir}"
}
on_exit() { local ec=$?; trap - EXIT; collect_logs || true; write_result "$ec"; exit "$ec"; }
trap on_exit EXIT

cli() { local host=$1 sql=$2; "$db_dir/sbin/start-cli.sh" -h "$host" -u "$db_user_name" -pw "$root_pw" -timeout 600000 -e "$sql"; }
set_property() {
  local node=$1 key=$2 value=$3
  ssh -n "${os_user_name}@${node}" "sudo sed -i '/^[# ]*${key}=/d' '${db_dir}/conf/iotdb-system.properties'; echo '${key}=${value}' | sudo tee -a '${db_dir}/conf/iotdb-system.properties' >/dev/null"
}
remote_pid() { ssh -n "${os_user_name}@$1" "source /etc/profile; sudo jps -l | awk '/DataNode/{print \$1; exit}'"; }

validate_scope() {
  # Release test installs use names such as /data2/v20121rc8_... in addition to v1*.
  case "$db_dir" in /data2/v1*|/data2/v20*|/data2/iotdb-enterprise-*) ;; *) fail "Unsafe install directory: $db_dir"; return 1;; esac
  [[ -d "$db_dir" ]] || { fail "Missing install directory: $db_dir"; return 1; }
  [[ $(wc -l < "$dn_file") -eq 3 ]] || { fail 'Expected 3 DataNodes'; return 1; }
}
stop_and_clean() {
  cp -f "$cn_file" "$nodeinfo_dir/confignode.txt"; cp -f "$dn_file" "$nodeinfo_dir/datanode.txt"
  sh -x "$cur_dir/../clean_env/stop_cluster.sh" >> "$log_file" 2>&1 || true
  sh -x "$cur_dir/../clean_env/clean_cluster.sh" >> "$log_file" 2>&1 || return 1
  sh -x "$cur_dir/../clean_env/reset_conf.sh" >> "$log_file" 2>&1 || return 1
  [[ ! -x "$cur_dir/../clean_env/clear_cache.sh" ]] || sh -x "$cur_dir/../clean_env/clear_cache.sh" >> "$log_file" 2>&1
}
configure_cluster() {
  local node threshold
  while read -r node; do
    set_property "$node" cn_seed_config_node "$seed_cn_ip"
    set_property "$node" cn_internal_address "$node"
    set_property "$node" schema_replication_factor 3
    set_property "$node" data_replication_factor 3
    set_property "$node" data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus
    set_property "$node" dn_seed_config_node "$seed_cn_ip"
    set_property "$node" dn_internal_address "$node"
    set_property "$node" dn_rpc_address "$node"
    set_property "$node" dn_metric_reporter_list PROMETHEUS
    set_property "$node" dn_metric_prometheus_reporter_port 9091
    set_property "$node" wal_mode SYNC
    threshold=107374182400; [[ "$node" == "$dn3_ip" ]] && threshold=$WAL_THRESHOLD
    set_property "$node" wal_throttle_threshold_in_byte "$threshold"
  done < "$dn_file"
}
start_cluster() {
  timeout 360 sh -x "$prepare_env_dir/start_cluster_v13.sh" 1 6 >> "$log_file" 2>&1 || { fail 'Cluster start failed'; return 1; }
  for i in {1..60}; do [[ $(cli "$query_ip" 'show cluster' 2>/dev/null | grep -c Running || true) -ge 6 ]] && return 0; sleep 2; done
  fail 'Cluster did not reach 6 Running nodes'; return 1
}
wait_sync_zero() {
  local begin=$(date +%s) response values nonzero samples zero_since=0 now
  while true; do
    response=$(curl -s -u admin:admin --get --data-urlencode 'query=sum(iot_consensus{name="ioTConsensusServerImpl",type="syncLag"}) by (instance)' "$monitor_url/api/v1/query")
    echo "$response" > "$artifact_dir/sync_lag_latest.json"
    values=$(echo "$response" | grep -o '"value":\[[^]]*,"[^"]*"\]' | sed -E 's/.*,"([^"]*)".*/\1/' || true)
    samples=$(echo "$values" | awk 'NF{n++} END{print n+0}'); nonzero=$(echo "$values" | awk '$1+0>0.0001{n++} END{print n+0}'); now=$(date +%s)
    if (( samples >= 2 && nonzero == 0 )); then (( zero_since == 0 )) && zero_since=$now; (( now-zero_since >= 60 )) && return 0; else zero_since=0; fi
    (( now-begin > SYNC_TIMEOUT )) && { fail 'sync lag did not remain zero'; return 1; }; sleep 10
  done
}
find_dn3_leader_device() {
  local i out ip region regions
  cli "$query_ip" "create database ${DB}" >/dev/null 2>&1 || true
  # V1.3 creates schema/data regions lazily; materialize a series before
  # polling SHOW REGIONS, otherwise CREATE DATABASE alone yields Empty set.
  cli "$query_ip" "insert into ${DB}.d0(time,s) values(1,1)" >/dev/null 2>&1 || true
  regions="$artifact_dir/show_regions.out"
  # Database creation is asynchronous; cluster Running does not imply that
  # its schema/data regions are already visible to SHOW REGIONS.
  for j in {1..60}; do
    cli "$query_ip" 'show regions' > "$regions" 2>&1
    grep -q 'root.v1_403' "$regions" && break
    sleep 2
  done
  region=$(awk -F'|' -v dn="$dn3_ip" '$3 ~ /DataRegion/ && $5 ~ /root.v1_403/ && $9 ~ dn && $12 ~ /Leader/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$regions")
  [[ -n "$region" ]] || { invalid "show regions found no DN3 DataRegion leader"; return 1; }
  log INFO "show regions selected DN3 leader DataRegion: $region"
  for i in {0..199}; do
    cli "$query_ip" "insert into ${DB}.d${i}(time,s) values(1,1)" >/dev/null 2>&1 || continue
    out="$artifact_dir/explain_d${i}.out"
    cli "$query_ip" "explain analyze select s from ${DB}.d${i}" > "$out" 2>&1 || continue
    # EXPLAIN reports the DataNode that owns the fragment/leader.  Keep the
    # first usable device even when DN3 is not leader; the role-normalisation
    # step below will force a handover instead of declaring INVALID.
    if grep -q "DataRegion: ${region}" "$out"; then
      DEVICE=${DB}.d${i}
      ip=$(grep -oE 'IP: [0-9.]+:' "$out" | head -1 | sed -E 's/IP: ([0-9.]+):/\1/')
      log INFO "Selected device $DEVICE; EXPLAIN leader=$ip"
      return 0
    fi
  done
  invalid "Could not find a device with a parseable EXPLAIN leader"; return 1
}
fill_dn3_wal() {
  local begin=2 end i sql hit=0
  log INFO "Writing pressure data until DN3 reaches WAL threshold ${WAL_THRESHOLD}"
  while (( begin <= PRESSURE_ROWS )); do
    end=$((begin+499)); (( end>PRESSURE_ROWS )) && end=$PRESSURE_ROWS
    sql="insert into ${DEVICE}(time,s,payload) values"
    for ((i=begin;i<=end;i++)); do (( i>begin )) && sql+=','; sql+="(${i},${i},'$(printf '%0200d' 0)')"; done
    cli "$query_ip" "$sql" >> "$artifact_dir/pressure.out" 2>&1 || true
    if ssh -n "${os_user_name}@${dn3_ip}" "sudo grep -RqiE 'wal directory size has reached|WAL.*threshold' '${db_dir}/logs'"; then hit=1; break; fi
    begin=$((end+1))
  done
  if (( hit != 1 )); then
    invalid "DN3 did not reach WAL threshold after $PRESSURE_ROWS rows"
    return 1
  fi
  log INFO 'DN3 WAL throttle confirmed from server log'
}
verify_fixed_behavior() {
  local ts=900000001 local_out="$artifact_dir/local_insert.out" remote_out="$artifact_dir/remote_insert.out" remote_host
  cli "$dn3_ip" "insert into ${DEVICE}(time,s) values(${ts},403)" > "$local_out" 2>&1
  grep -qi 'executed successfully' "$local_out" || fail 'Local dispatch on WAL-throttled DN was not retried remotely'
  remote_host=$(awk -v n="$dn3_ip" '$0!=n{print;exit}' "$dn_file")
  cli "$remote_host" "insert into ${DEVICE}(time,s) values($((ts+1)),404)" > "$remote_out" 2>&1 || fail 'Remote coordinator write command failed'
  grep -qi 'executed successfully' "$remote_out" || fail 'Remote coordinator write did not succeed'
  wait_sync_zero || true
  query_verification "$query_ip" "$artifact_dir/immediate_verify.out"
  local value
  value=$(verification_value "$artifact_dir/immediate_verify.out.norm")
  if [[ "$expected_mode" == before ]]; then
    [[ "$value" != '|2|807.0|' && "$value" != '|2|807|' ]] || fail 'Pre-fix build unexpectedly preserved both rows; WAL retry path was not reproduced'
  else
    [[ "$value" == '|2|807.0|' || "$value" == '|2|807|' ]] || fail 'Post-fix build did not preserve both rows'
  fi
}
normalize_query() { grep '^|' "$1" | tr -d ' \r'; }
query_verification() {
  local host=$1 out=$2
  cli "$host" "select count(s),sum(s) from ${DEVICE} where time>=900000001" > "$out" 2>&1
  normalize_query "$out" > "$out.norm"
}
verification_value() {
  awk -F'|' '
    $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+([.][0-9]+)?$/ {
      print "|" $2 "|" $3 "|"
      exit
    }
  ' "$1"
}
verify_replicas() {
  local baseline="$artifact_dir/baseline.out" baseline_value node host suffix pid dump_file actual_value
  query_verification "$query_ip" "$baseline" || fail 'Baseline query failed'
  baseline_value=$(verification_value "$baseline.norm")
  [[ "$baseline_value" == '|2|807.0|' || "$baseline_value" == '|2|807|' ]] || fail 'Expected both retry rows (count=2,sum=807) after sync'
  while read -r node; do
    suffix=${node##*.}; ssh -n "${os_user_name}@${node}" "sudo ${db_dir}/sbin/stop-datanode.sh" >> "$log_file" 2>&1 || true; sleep 5
    host=$(awk -v n="$node" '$0!=n{print;exit}' "$dn_file")
    query_verification "$host" "$artifact_dir/stop_dn_${suffix}.out" || fail "Query failed with $node stopped"
    actual_value=$(verification_value "$artifact_dir/stop_dn_${suffix}.out.norm")
    printf 'baseline=%s actual=%s\n' "$baseline_value" "$actual_value" > "$artifact_dir/stop_dn_${suffix}.diff"
    [[ -n "$actual_value" ]] || fail "Could not parse replica verification result with $node stopped"
    [[ "$actual_value" == "$baseline_value" ]] || fail "Replica differs with $node stopped"
    dump_file="${db_dir}/dn_v1_403_${run_id}_${suffix}.dump"
    # start-datanode.sh runs in foreground when invoked through sudo; detach it
    # from SSH and retain an HPROF path for OOM diagnostics.
    ssh -n "${os_user_name}@${node}" "source /etc/profile; nohup sudo ${db_dir}/sbin/start-datanode.sh -H '${dump_file}' >/tmp/V1_403_start_${run_id}_${suffix}.log 2>&1 </dev/null &" >> "$log_file" 2>&1 || fail "Failed to launch restart for $node"
    for i in {1..60}; do pid=$(remote_pid "$node"); [[ -n "$pid" ]] && break; sleep 2; done
    wait_sync_zero || true
  done < "$dn_file"
}
collect_logs() {
  local node suffix
  while read -r node; do suffix=${node##*.}; ssh -n "${os_user_name}@${node}" "sudo tar -czf /tmp/V1_403_${run_id}_${suffix}.tgz -C '${db_dir}' logs 2>/dev/null"; scp -q "${os_user_name}@${node}:/tmp/V1_403_${run_id}_${suffix}.tgz" "$artifact_dir/" || true; done < "$dn_file"
}

main() {
  validate_scope || return 1
  stop_and_clean || { fail 'Framework cleanup failed'; return 1; }
  configure_cluster || { fail 'Cluster configuration failed'; return 1; }
  start_cluster || return 1
  cli "$query_ip" 'show version' | tee "$artifact_dir/version.out"
  find_dn3_leader_device || return 1
  fill_dn3_wal || return 1
  verify_fixed_behavior || return 1
  verify_replicas
  (( fail_flag == 0 ))
}
main
