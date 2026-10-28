#!/bin/bash
# Formal common framework for 2.0.11.1 metadata high-availability cases.
# Each numbered case owns a clean 3C5D lifecycle and never reuses a cluster.
set -uo pipefail

HA_CASE_ID=${HA_CASE_ID:-HA_UNKNOWN}
HA_CASE_NAME=${HA_CASE_NAME:-unknown}
cur_dir="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME=$(basename "$0")
conf_file="${cur_dir}/../conf/test.conf"
nodeinfo_dir="${cur_dir}/../conf"
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"

conf_value(){ awk -F= -v key="$1" '$1 ~ "^[[:space:]]*" key "[[:space:]]*$" {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf_file"; }
testdb=$(conf_value v_testdb)
cli_parent=$(conf_value v_shell_client_db_parent_dir)
db_parent=$(conf_value v_db_parent_dir)
cn_db_parent=$(conf_value v_cn_db_parent_dir)
os_user=$(conf_value os_user_name)
cluster_id=$(conf_value CLUSTER_NAME)
result_iotdb_ip=$(conf_value test_result_iotdb_ip)
cli_dir="${cli_parent}/${testdb}"
db_dir="${db_parent}/${testdb}"
cn_db_dir="${cn_db_parent}/${testdb}"

cn_num=3
dn_num=5
total_node_num=8
sr_rep_num=3
dr_rep_num=2
dn_metric_port=9092
thrift_max_frame_size=268435456
metadata_lease_fence_ms=20000
cluster_ready_timeout_seconds=${HA_CLUSTER_READY_TIMEOUT:-600}
sync_lag_timeout_seconds=${HA_SYNC_LAG_TIMEOUT:-600}

run_ts=$(date +%Y_%m_%d_%H_%M_%S)
artifact_dir="${cur_dir}/${HA_CASE_ID}_${HA_CASE_NAME}_${run_ts}"
log_file="${artifact_dir}/case.log"
mkdir -p "$artifact_dir"
: > "$log_file"

fail_flag=0
warn_count=0
warn_message="."
partitioned_dn=""
formal_started=0
formal_finalized=0
models_seeded=0
test_begin_epoch=$(date +%s)
declare -A persistent_cli_pid=()
declare -A persistent_cli_fd=()
declare -A persistent_cli_fifo=()
declare -A persistent_cli_out=()

CN_IPS=()
while IFS= read -r node_ip; do
  node_ip=${node_ip//[[:space:]]/}
  [ -z "$node_ip" ] || CN_IPS+=("$node_ip")
done < "${nodeinfo_dir}/confignode_3c.txt"
DN_IPS=()
while IFS= read -r node_ip; do
  node_ip=${node_ip//[[:space:]]/}
  [ -z "$node_ip" ] || DN_IPS+=("$node_ip")
done < "${nodeinfo_dir}/datanode_5d.txt"
query_ip=${DN_IPS[0]}
fault_dn=${DN_IPS[1]}
seed_cn_ip="${CN_IPS[0]}:10710"

unique_suffix=$(date +%H%M%S)
TABLE_DB="ha_${HA_CASE_ID,,}_${unique_suffix}"
TREE_DB="root.ha_${HA_CASE_ID,,}_${unique_suffix}"

log(){ echo "[$(date '+%F %T')] [$1] $2" | tee -a "$log_file"; }
record_fail(){ fail_flag=$((fail_flag+1)); warn_message="${warn_message}$1."; log ERROR "$1"; }
tree(){ "$cli_dir/sbin/start-cli.sh" -u root -h "$1" -timeout 3600 -sql_dialect tree -e "$2"; }
table(){ "$cli_dir/sbin/start-cli.sh" -u root -h "$1" -timeout 3600 -sql_dialect table -e "$2"; }

run_ok(){
  local dialect=$1 host=$2 sql=$3 label=$4 out="${artifact_dir}/${4}.out"
  if "$dialect" "$host" "$sql" >"$out" 2>&1 && ! grep -Eqi 'Exception|ERROR|Error' "$out"; then
    log INFO "$label success"
  else
    record_fail "$label failed"
    tail -30 "$out" | tee -a "$log_file"
    return 1
  fi
}

run_rejected(){
  local dialect=$1 host=$2 sql=$3 label=$4 out="${artifact_dir}/${4}.out" rc=0
  timeout 30s "$cli_dir/sbin/start-cli.sh" -u root -h "$host" -timeout 20 -sql_dialect "$dialect" -e "$sql" >"$out" 2>&1 || rc=$?
  if [ "$rc" -eq 124 ]; then
    record_fail "$label timed out instead of promptly returning fenced/isolated error"
    return 1
  fi
  if grep -Eqi 'isolat|fenc|lease|cannot.*ConfigNode|unable.*ConfigNode|temporarily unavailable|does not exist|unknown|Exception|ERROR|Error' "$out"; then
    log INFO "$label rejected as expected"
  else
    record_fail "$label was not rejected"
    cat "$out" | tee -a "$log_file"
    return 1
  fi
}

# A one-shot CLI opened after the network partition blocks in getUser before the SQL reaches the
# fenced DataNode. Keep an authenticated interactive CLI open before partitioning so lease tests
# exercise the actual statement path instead of the login path.
start_persistent_cli(){
  local name=$1 dialect=$2 host=$3
  local fifo="${artifact_dir}/${name}.stdin" out="${artifact_dir}/${name}.session.out" fd pid deadline
  rm -f "$fifo"
  mkfifo "$fifo" || { record_fail "create persistent CLI fifo $name failed"; return 1; }
  exec {fd}<>"$fifo"
  "$cli_dir/sbin/start-cli.sh" -u root -h "$host" -timeout 3600 -sql_dialect "$dialect" <&$fd >"$out" 2>&1 &
  pid=$!
  persistent_cli_pid[$name]=$pid
  persistent_cli_fd[$name]=$fd
  persistent_cli_fifo[$name]=$fifo
  persistent_cli_out[$name]=$out
  # The interactive prompt has no newline and may stay buffered when stdout is redirected.
  # Send a harmless command and use its newline-terminated result as the readiness handshake.
  sleep 1
  printf 'show version;\n' >&$fd
  deadline=$((SECONDS+60))
  while ((SECONDS<deadline)); do
    if grep -Eqi 'Version|Build' "$out" 2>/dev/null && grep -q 'Successfully login' "$out" 2>/dev/null; then
      log INFO "persistent $dialect CLI $name authenticated on $host"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then record_fail "persistent CLI $name exited before login"; tail -30 "$out" | tee -a "$log_file"; return 1; fi
    sleep 1
  done
  record_fail "persistent CLI $name login timeout"
  return 1
}

run_persistent_rejected(){
  local name=$1 sql=$2 label=$3 timeout_seconds=${4:-30}
  local fd=${persistent_cli_fd[$name]} out=${persistent_cli_out[$name]}
  local start_size response="${artifact_dir}/${label}.out" deadline
  start_size=$(wc -c <"$out")
  printf '%s\n' "$sql" >&$fd
  deadline=$((SECONDS+timeout_seconds))
  while ((SECONDS<deadline)); do
    tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
    if grep -Eq '(TimechoDB|IoTDB)>' "$response" 2>/dev/null; then
      if grep -Eqi 'isolat|fenc|lease|cannot.*ConfigNode|unable.*ConfigNode|temporarily unavailable|Exception|ERROR|Error' "$response"; then
        log INFO "$label rejected promptly through pre-authenticated session"
        return 0
      fi
      record_fail "$label returned without fenced/isolated error"
      cat "$response" | tee -a "$log_file"
      return 1
    fi
    sleep 1
  done
  tail -c +$((start_size+1)) "$out" >"$response" 2>/dev/null || true
  record_fail "$label timed out in pre-authenticated session instead of promptly returning fenced/isolated error"
  return 1
}

close_persistent_cli(){
  local name=$1 fd=${persistent_cli_fd[$1]:-} pid=${persistent_cli_pid[$1]:-} fifo=${persistent_cli_fifo[$1]:-}
  if [ -n "$fd" ]; then printf 'quit\n' >&$fd 2>/dev/null || true; fi
  if [ -n "$pid" ]; then
    local deadline=$((SECONDS+5)); while kill -0 "$pid" 2>/dev/null && ((SECONDS<deadline)); do sleep 1; done
    kill "$pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$fd" ]; then exec {fd}>&-; fi
  [ -z "$fifo" ] || rm -f "$fifo"
  unset 'persistent_cli_pid[$name]' 'persistent_cli_fd[$name]' 'persistent_cli_fifo[$name]' 'persistent_cli_out[$name]'
}

close_all_persistent_clis(){
  local name names=()
  set +u
  names=("${!persistent_cli_pid[@]}")
  for name in "${names[@]}"; do close_persistent_cli "$name"; done
  set -u
}

heal_partition(){
  local ip=${1:-$partitioned_dn}
  [ -z "$ip" ] && return 0
  ssh -n "$os_user@$ip" "iptables -D INPUT -j HA_META_IN 2>/dev/null || true; iptables -D OUTPUT -j HA_META_OUT 2>/dev/null || true; iptables -F HA_META_IN 2>/dev/null || true; iptables -F HA_META_OUT 2>/dev/null || true; iptables -X HA_META_IN 2>/dev/null || true; iptables -X HA_META_OUT 2>/dev/null || true" >/dev/null 2>&1 || true
  partitioned_dn=""
  sleep 12
  log INFO "network partition healed on $ip"
}

cleanup_stale_partitions(){
  local ip
  for ip in "${DN_IPS[@]}"; do
    ssh -n -o ConnectTimeout=10 "$os_user@$ip" "iptables -D INPUT -j HA_META_IN 2>/dev/null || true; iptables -D OUTPUT -j HA_META_OUT 2>/dev/null || true; iptables -F HA_META_IN 2>/dev/null || true; iptables -F HA_META_OUT 2>/dev/null || true; iptables -X HA_META_IN 2>/dev/null || true; iptables -X HA_META_OUT 2>/dev/null || true" >/dev/null 2>&1 || true
  done
}

partition_dn(){
  local ip=$1 cn
  ssh -n "$os_user@$ip" "iptables -N HA_META_IN 2>/dev/null || true; iptables -N HA_META_OUT 2>/dev/null || true; iptables -F HA_META_IN; iptables -F HA_META_OUT; iptables -C INPUT -j HA_META_IN 2>/dev/null || iptables -I INPUT 1 -j HA_META_IN; iptables -C OUTPUT -j HA_META_OUT 2>/dev/null || iptables -I OUTPUT 1 -j HA_META_OUT"
  for cn in "${CN_IPS[@]}"; do
    ssh -n "$os_user@$ip" "iptables -A HA_META_IN -s $cn -j DROP; iptables -A HA_META_OUT -d $cn -j DROP"
  done
  partitioned_dn=$ip
  log INFO "partitioned $ip from ConfigNodes; wait for metadata lease fence"
  sleep "${HA_FENCE_WAIT_SECONDS:-28}"
}

force_stop_target_processes(){
  local ip
  log INFO "force stop target ${testdb} ConfigNode/DataNode processes"
  for ip in $(printf '%s\n' "${CN_IPS[@]}" "${DN_IPS[@]}" | sort -u); do
    ssh -n -o ConnectTimeout=10 "$os_user@$ip" "pids=\$(ps -ef | grep '${testdb}' | grep -E 'ConfigNode|DataNode' | grep -v grep | awk '{print \$2}'); [ -z \"\$pids\" ] || kill -9 \$pids" >>"$log_file" 2>&1 || true
  done
}

force_remove_target_data(){
  local ip
  log INFO "remove only target ${testdb} data/log directories"
  for ip in $(printf '%s\n' "${CN_IPS[@]}" "${DN_IPS[@]}" | sort -u); do
    ssh -n -o ConnectTimeout=10 "$os_user@$ip" "rm -rf '${db_dir}/data' '${db_dir}/logs' '${cn_db_dir}/data' '${cn_db_dir}/logs'" >>"$log_file" 2>&1 || true
  done
}

set_remote_property(){
  local ip=$1 file=$2 key=$3 value=$4
  ssh -n -o ConnectTimeout=10 "$os_user@$ip" "if grep -qE '^[#[:space:]]*${key}=' '$file'; then sed -i -E 's|^[#[:space:]]*${key}=.*|${key}=${value}|' '$file'; else echo '${key}=${value}' >> '$file'; fi" >>"$log_file" 2>&1
}

configure_nodes(){
  local ip
  log INFO "configure formal 3C5D cluster, SR=3 DR=2 IoTConsensus lease=${metadata_lease_fence_ms}ms"
  for ip in "${CN_IPS[@]}"; do
    set_remote_property "$ip" "${cn_db_dir}/conf/iotdb-system.properties" cn_seed_config_node "$seed_cn_ip" || return 1
    set_remote_property "$ip" "${cn_db_dir}/conf/iotdb-system.properties" cn_internal_address "$ip" || return 1
    set_remote_property "$ip" "${cn_db_dir}/conf/iotdb-system.properties" cn_metric_reporter_list PROMETHEUS || return 1
    set_remote_property "$ip" "${cn_db_dir}/conf/iotdb-system.properties" schema_replication_factor "$sr_rep_num" || return 1
    set_remote_property "$ip" "${cn_db_dir}/conf/iotdb-system.properties" data_replication_factor "$dr_rep_num" || return 1
    set_remote_property "$ip" "${cn_db_dir}/conf/iotdb-system.properties" cluster_name "$cluster_id" || return 1
    set_remote_property "$ip" "${cn_db_dir}/conf/iotdb-system.properties" data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus || return 1
    set_remote_property "$ip" "${cn_db_dir}/conf/iotdb-system.properties" time_partition_interval 3600000 || return 1
    set_remote_property "$ip" "${cn_db_dir}/conf/iotdb-system.properties" dn_thrift_max_frame_size "$thrift_max_frame_size" || return 1
    set_remote_property "$ip" "${cn_db_dir}/conf/iotdb-system.properties" enable_auto_repair_compaction false || return 1
    set_remote_property "$ip" "${cn_db_dir}/conf/iotdb-system.properties" enable_audit_log true || return 1
  done
  for ip in "${DN_IPS[@]}"; do
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" dn_seed_config_node "$seed_cn_ip" || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" dn_internal_address "$ip" || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" dn_rpc_address "$ip" || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" dn_metric_reporter_list PROMETHEUS || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" dn_metric_prometheus_reporter_port "$dn_metric_port" || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" schema_replication_factor "$sr_rep_num" || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" data_replication_factor "$dr_rep_num" || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" cluster_name "$cluster_id" || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" time_partition_interval 3600000 || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" dn_thrift_max_frame_size "$thrift_max_frame_size" || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" metadata_lease_fence_ms "$metadata_lease_fence_ms" || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" enable_auto_repair_compaction false || return 1
    set_remote_property "$ip" "${db_dir}/conf/iotdb-system.properties" enable_audit_log true || return 1
  done
}

refresh_running_datanodes(){
  local out="${artifact_dir}/show_datanodes.out"
  tree "$query_ip" 'show datanodes' >"$out" 2>&1 || return 1
  sed -i 's/\r$//' "$out"
  awk -F'|' 'function t(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s} /^\|/{id=t($2);st=t($3);ip=t($4);if(id~/^[0-9]+$/&&st=="Running")print id" "ip}' "$out" >"${artifact_dir}/running_datanodes.txt"
}

wait_for_cluster_ready(){
  local begin=$(date +%s) ip cn_ok dn_ok
  while true; do
    cn_ok=1; dn_ok=1
    for ip in "${CN_IPS[@]}"; do ssh -n -o ConnectTimeout=10 "$os_user@$ip" "jps | grep -q ConfigNode" >/dev/null 2>&1 || cn_ok=0; done
    for ip in "${DN_IPS[@]}"; do ssh -n -o ConnectTimeout=10 "$os_user@$ip" "jps | grep -q DataNode" >/dev/null 2>&1 || dn_ok=0; done
    if [ "$cn_ok" -eq 1 ] && [ "$dn_ok" -eq 1 ] && refresh_running_datanodes && [ "$(wc -l < "${artifact_dir}/running_datanodes.txt")" -eq "$dn_num" ]; then
      log INFO "fresh cluster ready with 3 ConfigNodes and 5 DataNodes"
      return 0
    fi
    if [ $(( $(date +%s)-begin )) -gt "$cluster_ready_timeout_seconds" ]; then record_fail "fresh 3C5D cluster did not become ready"; return 1; fi
    sleep 5
  done
}

formal_begin(){
  log INFO "formal independent case begin; artifacts=$artifact_dir"
  cp -f "${nodeinfo_dir}/confignode_3c.txt" "${nodeinfo_dir}/confignode.txt"
  cp -f "${nodeinfo_dir}/datanode_5d.txt" "${nodeinfo_dir}/datanode.txt"
  cleanup_stale_partitions
  force_stop_target_processes
  sh -x "${clean_env_dir}/clean_cluster.sh" >>"$log_file" 2>&1 || true
  sh -x "${clean_env_dir}/reset_conf.sh" >>"$log_file" 2>&1 || true
  sh -x "${clean_env_dir}/clear_cache.sh" >>"$log_file" 2>&1 || true
  force_remove_target_data
  configure_nodes || { record_fail "node configuration failed"; return 1; }
  timeout --preserve-status 150s sh -x "${prepare_env_dir}/start_cluster_v20.sh" 1 "$total_node_num" >>"$log_file" 2>&1 || log WARN "start script returned non-zero/timed out; continue readiness check"
  wait_for_cluster_ready || return 1
  formal_started=1
}

wait_dn_running(){
  local ip=$1 begin=$(date +%s)
  while [ $(( $(date +%s)-begin )) -le 600 ]; do refresh_running_datanodes >/dev/null 2>&1 && grep -q " $ip$" "${artifact_dir}/running_datanodes.txt" && return 0; sleep 5; done
  return 1
}

stop_dn(){
  local ip=$1 begin=$(date +%s)
  ssh -n "$os_user@$ip" "source /etc/profile; cd '${db_dir}'; ./sbin/stop-datanode.sh" >>"$log_file" 2>&1 || true
  while [ $(( $(date +%s)-begin )) -le 300 ]; do
    if ! ssh -n "$os_user@$ip" "jps | grep -q DataNode" >/dev/null 2>&1; then log INFO "DataNode $ip stopped"; return 0; fi
    sleep 3
  done
  record_fail "DataNode $ip stop timeout"; return 1
}

start_dn(){
  local ip=$1
  ssh -n "$os_user@$ip" "source /etc/profile; cd '${db_dir}'; ./sbin/start-datanode.sh -d >/dev/null 2>&1 </dev/null" >>"$log_file" 2>&1 || true
  if wait_dn_running "$ip"; then log INFO "DataNode $ip recovered"; else record_fail "DataNode $ip did not recover"; return 1; fi
}

seed_all_models(){
  local now old
  now=$(date +%s%3N); old=$((now-60000))
  run_ok tree "$query_ip" "create database $TREE_DB; create aligned timeseries $TREE_DB.aligned_d(s1 INT64,s2 DOUBLE); create timeseries $TREE_DB.non_aligned_d.s1 INT64; create timeseries $TREE_DB.non_aligned_d.s2 DOUBLE; insert into $TREE_DB.aligned_d(time,s1,s2) aligned values($old,11,1.1); insert into $TREE_DB.non_aligned_d(time,s1,s2) values($old,22,2.2); set ttl to $TREE_DB.** 604800000" seed_tree || return 1
  run_ok table "$query_ip" "create database $TABLE_DB; use $TABLE_DB; create table base(device string tag,site string tag,temp double field,status string field,payload object field) with (ttl=604800000); insert into base(time,device,site,temp,status,payload) values($old,'d1','north',21.5,'ok',to_object(true,0,X'0102')); create writable view writable_v as select device as dev,site as area,temp,payload from base with (ttl=604800000,schema_cascade=false); insert into writable_v(time,dev,area,temp,payload) values($now,'d2','south',22.5,to_object(false,0,X'0304'))" seed_table_object_view || return 1
  run_ok table "$query_ip" "use $TABLE_DB; create view tree_v(device TAG,s1 INT64 FIELD,s2 DOUBLE FIELD) as $TREE_DB.**" seed_tree_to_table || return 1
  models_seeded=1
}

flush_all(){ tree "$query_ip" 'flush' >>"$log_file" 2>&1 || record_fail "tree flush failed"; table "$query_ip" 'flush' >>"$log_file" 2>&1 || record_fail "table flush failed"; }

# Keep the helper location independent of the numbered case entry point.
ha_sync_support_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ha_sync_support_dir/ha_sync_gate.sh" || { record_fail 'missing HA sync gate helper'; exit 1; }

wait_for_sync_lag_zero(){ ha_wait_sync "$@"; }

# Preserve values and duplicate rows; remove only CLI formatting and row order.
normalize_output(){
  awk -F'|' '
    function trim(s){gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s}
    /^\|/ {
      if(!header++){next}
      row=""; for(i=2;i<NF;i++) row=row "|" trim($i)
      print row "|"; n++
    }
    /^Total line number = / {expected=$0; sub(/^Total line number = /,"",expected); footer++; expected+=0}
    /^Empty set[.]?\r?$/ {empty=1}
    END{if(!((footer==1 && n==expected) || (empty && !n))) exit 1}
  ' "$1" | LC_ALL=C sort
}

capture_counts(){
  local host=$1 prefix=$2 rc=0
  ha_gate_cli "$host" tree "select count(s1),count(s2) from $TREE_DB.** align by device" "${prefix}_tree.raw" || rc=1
  ha_gate_cli "$host" table "use $TABLE_DB; select device,count(temp),count(payload) from base group by device order by device" "${prefix}_base.raw" || rc=1
  ha_gate_cli "$host" table "use $TABLE_DB; select dev,count(temp),count(payload) from writable_v group by dev order by dev" "${prefix}_writable.raw" || rc=1
  ha_gate_cli "$host" table "use $TABLE_DB; select device,count(s1),count(s2) from tree_v group by device order by device" "${prefix}_tree_view.raw" || rc=1
  ha_gate_cli "$host" tree "select s1,s2 from $TREE_DB.** align by device" "${prefix}_tree_points.raw" || rc=1
  local model
  for model in tree base writable tree_view tree_points; do
    if grep -Eqi 'Exception|ERROR|Error' "${prefix}_${model}.raw"; then rc=1; fi
    normalize_output "${prefix}_${model}.raw" >"${prefix}_${model}.normalized" || rc=1
  done
  return "$rc"
}

assert_all_models(){ capture_counts "$1" "${artifact_dir}/assert_all" || record_fail "all-model query verification failed on $1"; }

assert_replica_consistency_without_ttl_noise(){ ha_consistency_rounds; }

ensure_all_dns_running(){ local ip; for ip in "${DN_IPS[@]}"; do wait_dn_running "$ip" || start_dn "$ip" || true; done; }

scan_logs(){
  local ip role path out count known
  # Do not match the expected stack-frame method name failIfMetadataLeaseFenced.
  local fatal='NullPointer|BufferUnderflowException|DataTypeInconsistentException|ArrayIndexOutOfBoundsException|NegativeArraySizeException|CompactionTableSchemaNotMatchException|Exception occurs when loading snapshot for|Fail to load snapshot from|metadata.*lease.*(failed|failure|error)|cache.*reload.*(failed|failure|error)|ClusterCachePropagator.*(stuck|failed|failure|error)|PULL_OR_INIT_FAILED'
  : >"${artifact_dir}/log_scan.out"
  for role in cn dn; do
    if [ "$role" = cn ]; then path="${cn_db_dir}/logs"; current=("${CN_IPS[@]}"); else path="${db_dir}/logs"; current=("${DN_IPS[@]}"); fi
    for ip in "${current[@]}"; do
      out="${artifact_dir}/log_scan_${role}_${ip}.out"
      ssh -n "$os_user@$ip" "zgrep -hEi '$fatal' '${path}'/* 2>/dev/null || true" >"$out" 2>/dev/null || true
      count=$(wc -l <"$out"); cat "$out" >>"${artifact_dir}/log_scan.out"
      [ "$count" -eq 0 ] || record_fail "$role log fatal patterns on $ip count=$count"
      known=$(ssh -n "$os_user@$ip" "zgrep -h 'The memory cost to be released is larger' '${path}'/* 2>/dev/null | wc -l" 2>/dev/null || echo 0)
      if [ "${known:-0}" -gt 0 ]; then warn_count=$((warn_count+known)); log WARN "$role $ip AutoResizingBuffer known noise x$known (not fail)"; fi
    done
  done
}

stop_cluster(){ sh -x "${clean_env_dir}/stop_cluster.sh" >>"$log_file" 2>&1 || true; }
backup_logs(){ local name="tc2026_HighAvailability_${HA_CASE_ID}_${HA_CASE_NAME}_$(date +%Y_%m_%d_%H_%M_%S)"; sh -x "${clean_env_dir}/backup_cluster_logs.sh" "$name" >>"$log_file" 2>&1 || { record_fail "backup cluster logs failed"; return 1; }; log INFO "cluster logs backed up as $name"; }

# start-cli -e splits input at semicolons before the SQL string literal reaches the server, so a
# semicolon inside testOtherMessage still breaks one INSERT into multiple statements. Normalize
# message-only separators/newlines here, then escape SQL quotes. This helper is only used for text
# values written to the test-result database; it must not be used to rewrite executable SQL.
sql_escape(){
  printf '%s' "$1" | tr '\r\n;' '  ,' | sed "s/'/''/g"
}

write_result_to_database(){
  local elapsed=$1 result result_message escaped_message escaped_script out
  if [ "$fail_flag" -gt 0 ]; then result=FAIL; else result=PASS; fi
  result_message="${warn_message}case_id=${HA_CASE_ID}.artifacts=${artifact_dir}."
  escaped_message=$(sql_escape "$result_message")
  escaped_script=$(sql_escape "$SCRIPT_NAME")
  out="${artifact_dir}/write_test_result.out"
  if "$cli_dir/sbin/start-cli.sh" -u root -h "$result_iotdb_ip" -timeout 60 -sql_dialect tree \
      -e "insert into root.test.${cluster_id}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage) values(now(),'${testdb}','${escaped_script}','IoTConsensus','${result}',${elapsed},0,0,${warn_count},'${escaped_message}')" \
      >"$out" 2>&1 && ! grep -Eqi 'Exception|ERROR|Error' "$out"; then
    log INFO "test result written to root.test.${cluster_id} on ${result_iotdb_ip}: ${result}"
    return 0
  fi
  log WARN "failed to write test result database; testcase result itself is unchanged"
  tail -30 "$out" | tee -a "$log_file"
  return 1
}

formal_end(){
  local elapsed
  [ "$formal_finalized" -eq 0 ] || return "$fail_flag"
  formal_finalized=1
  if declare -F stop_cn_log_watchers >/dev/null; then stop_cn_log_watchers; fi
  close_all_persistent_clis
  heal_partition "$partitioned_dn"
  if [ "$formal_started" -eq 1 ]; then
    ensure_all_dns_running
    if [ "$models_seeded" -eq 1 ]; then
      flush_all
      assert_replica_consistency_without_ttl_noise || true
      ensure_all_dns_running
    else record_fail "common model seeding did not complete; skip consistency check"; fi
    stop_cluster
    scan_logs
    backup_logs || true
  else
    stop_cluster
  fi
  elapsed=$(( $(date +%s)-test_begin_epoch ))
  write_result_to_database "$elapsed" || true
  if [ "$fail_flag" -eq 0 ]; then echo "testcase $HA_CASE_ID pass" | tee -a "$log_file"; else echo "testcase $HA_CASE_ID fail" | tee -a "$log_file"; fi
  log INFO "RESULT fail_flag=$fail_flag warn_count=$warn_count elapsed=${elapsed}s msg=$warn_message artifacts=$artifact_dir"
  return "$fail_flag"
}

abnormal_exit(){
  local rc=$?
  close_all_persistent_clis
  heal_partition "$partitioned_dn"
  if [ "$formal_finalized" -eq 0 ]; then [ "$rc" -eq 0 ] || record_fail "abnormal exit rc=$rc"; formal_end || true; fi
}
trap abnormal_exit EXIT INT TERM
