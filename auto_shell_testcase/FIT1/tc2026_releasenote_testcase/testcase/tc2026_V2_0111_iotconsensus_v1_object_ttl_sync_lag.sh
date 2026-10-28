#!/bin/bash
set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
conf_file="$cur_dir/../conf/test.conf"
prepare_env_dir="$cur_dir/../prepare_env"
clean_env_dir="$cur_dir/../clean_env"
nodeinfo_dir="$cur_dir/../conf"
os_user_name=$(awk -F= '/^os_user_name=/{gsub(/ /,"",$2);print $2}' "$conf_file")
db_user_name=$(awk -F= '/^db_user_name=/{gsub(/ /,"",$2);print $2}' "$conf_file")
testdb=$(awk -F= '/^v_testdb=/{gsub(/ /,"",$2);print $2}' "$conf_file")
db_parent_dir=$(awk -F= '/^v_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "$conf_file")
root_pw=$(awk -F= '/^root_pw=/{gsub(/ /,"",$2);print $2}' "$conf_file")
v20_root_pw=$(awk -F= '/^v20_root_pw=/{gsub(/ /,"",$2);print $2}' "$conf_file")
[[ -n "$v20_root_pw" ]] || v20_root_pw="$root_pw"
monitor_url=$(awk -F= '/^monitor_url=/{gsub(/ /,"",$2);print $2}' "$conf_file")
CSV_FILE=$(awk -F= '/^CSV_FILE=/{gsub(/ /,"",$2);print $2}' "$conf_file")
db_dir="$db_parent_dir/$testdb"; cn_file="$nodeinfo_dir/confignode_3c.txt"; dn_file="$nodeinfo_dir/datanode_3d.txt"
query_ip=$(head -1 "$dn_file" | tr -d ' '); dn3=$(sed -n '3p' "$dn_file" | tr -d ' ')
benchmark="/ssd/iotdb/auto_test_shell/tc2026_releasenote_testcase/benchmark/bm_20260812_e158c2c_jdk17/benchmark.sh"
benchmark_home=$(dirname "$benchmark")
DB=test_g_0; TTL_MS=${V2_0111_OBJECT_TTL_MS:-300000}; OUTAGE_SEC=${V2_0111_OUTAGE_SEC:-700}; SYNC_TIMEOUT=${V2_0111_SYNC_TIMEOUT:-0}; benchmark_pid=''; v_warnMessage=''; licenses_moved=0
run_id=$(date +%Y%m%d_%H%M%S); artifact_dir="$cur_dir/V2_0111_${run_id}"; log_file="$artifact_dir/test.log"; fail_flag=0; invalid_flag=0; begin=$(date +%s); mkdir -p "$artifact_dir"
test_conf_backup="$artifact_dir/test.conf.before"
cp "$conf_file" "$test_conf_backup"
log(){ printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}" | tee -a "$log_file"; }
fail(){ fail_flag=1; log ERROR "$*"; }; invalid(){ invalid_flag=1; log ERROR "INVALID: $*"; }
cli(){ "$db_dir/sbin/start-cli.sh" -h "$1" -u "$db_user_name" -pw "$root_pw" -sql_dialect table -timeout 600000 -e "$2"; }
table_cli(){
  local sql="$1"
  printf 'use %s;\n%s;\nexit;\n' "$DB" "$sql" |
    "$db_dir/sbin/start-cli.sh" -h "$query_ip" -u "$db_user_name" -pw "$root_pw" \
      -sql_dialect table -timeout 600000
}
restore_licenses(){
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    ssh -n "$os_user_name@$ip" "if test -f '$db_dir/license_bk' && ! test -f '$db_dir/activation/license'; then mv '$db_dir/license_bk' '$db_dir/activation/license'; fi" >>"$log_file" 2>&1 || true
  done < "$dn_file"
  licenses_moved=0
}
move_licenses(){
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    ssh -n "$os_user_name@$ip" "test -f '$db_dir/activation/license' && mv '$db_dir/activation/license' '$db_dir/license_bk'" >>"$log_file" 2>&1 || return 1
  done < "$dn_file"
  licenses_moved=1
}
finish(){ local ec=$? r=PASS; ((licenses_moved)) && restore_licenses; cp "$test_conf_backup" "$conf_file" 2>/dev/null || true; ((invalid_flag))&&r=INVALID||{ ((ec==0&&fail_flag==0))||r=FAIL; }; echo "$(date -Is),$testdb,IoTConsensus,$(basename "$0"),$r,$(( $(date +%s)-begin )),0,.,0,0" >> "${CSV_FILE:-test_result.csv}"; log INFO "RESULT $r artifacts=$artifact_dir"; exit "$ec"; }; trap finish EXIT
stop_clean(){
  cp -f "$cn_file" "$nodeinfo_dir/confignode.txt"
  cp -f "$dn_file" "$nodeinfo_dir/datanode.txt"
  sh -x "$clean_env_dir/stop_cluster.sh" >>"$log_file" 2>&1 || true
  sh -x "$clean_env_dir/clean_cluster.sh" >>"$log_file" 2>&1 || return 1
  sh -x "$clean_env_dir/reset_conf.sh" >>"$log_file" 2>&1 || return 1
  if [[ -x "$clean_env_dir/clear_cache.sh" ]]; then
    sh -x "$clean_env_dir/clear_cache.sh" >>"$log_file" 2>&1 || return 1
  fi
}
set_conf(){
  local seed="$(head -1 "$cn_file" | tr -d ' '):10710"
  local ip_file="$artifact_dir/node_ips"
  cat "$cn_file" "$dn_file" | sed '/^[[:space:]]*$/d' | sort -u > "$ip_file"
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    ssh -n "$os_user_name@$ip" "sed -i -E \\
      -e 's|^[# ]*cn_seed_config_node=.*|cn_seed_config_node=$seed|' \\
      -e 's|^[# ]*cn_internal_address=.*|cn_internal_address=$ip|' \\
      -e 's|^[# ]*dn_seed_config_node=.*|dn_seed_config_node=$seed|' \\
      -e 's|^[# ]*dn_internal_address=.*|dn_internal_address=$ip|' \\
      -e 's|^[# ]*dn_rpc_address=.*|dn_rpc_address=$ip|' \\
      -e 's|^[# ]*cn_metric_reporter_list=.*|cn_metric_reporter_list=PROMETHEUS|' \\
      -e 's|^[# ]*cn_metric_prometheus_reporter_port=.*|cn_metric_prometheus_reporter_port=9081|' \\
      -e 's|^[# ]*dn_metric_reporter_list=.*|dn_metric_reporter_list=PROMETHEUS|' \\
      -e 's|^[# ]*dn_metric_prometheus_reporter_port=.*|dn_metric_prometheus_reporter_port=9091|' \\
      -e 's|^[# ]*data_region_consensus_protocol_class=.*|data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.IoTConsensus|' \\
      -e 's|^[# ]*schema_replication_factor=.*|schema_replication_factor=3|' \\
      -e 's|^[# ]*data_replication_factor=.*|data_replication_factor=3|' \\
      -e 's|^[# ]*schema_region_group_extension_policy=.*|schema_region_group_extension_policy=CUSTOM|' \\
      -e 's|^[# ]*default_schema_region_group_num_per_database=.*|default_schema_region_group_num_per_database=10|' \\
      -e 's|^[# ]*data_region_group_extension_policy=.*|data_region_group_extension_policy=CUSTOM|' \\
      -e 's|^[# ]*default_data_region_group_num_per_database=.*|default_data_region_group_num_per_database=10|' \\
      -e 's|^[# ]*disk_space_warning_threshold=.*|disk_space_warning_threshold=0.01|' \\
      -e 's|^[# ]*enable_auto_repair_compaction=.*|enable_auto_repair_compaction=false|' \\
      -e 's|^[# ]*ttl_check_interval=.*|ttl_check_interval=20000|' \\
      '$db_dir'/conf/iotdb-system.properties" >>"$log_file" 2>&1 || return 1
  done < "$ip_file"
}
start(){
  if ! grep -q '^v20_root_pw=' "$conf_file"; then
    printf '\nv20_root_pw=%s\n' "$v20_root_pw" >> "$conf_file"
  fi
  timeout "${V2_0111_START_TIMEOUT:-900}" sh -x "$prepare_env_dir/start_cluster_v20.sh" 1 6 >>"$log_file" 2>&1 || return 1
}
wait_lag_zero(){ local start=$(date +%s) zero=0 now resp vals bad flush_no=0; while :; do flush_no=$((flush_no+1)); cli "$query_ip" 'flush' > "$artifact_dir/flush_sync_check_${flush_no}.out" 2>&1 || log WARN "FLUSH failed during syncLag check #${flush_no}"; resp=$(curl -s -u admin:admin --get --data-urlencode 'query=sum(iot_consensus{name="ioTConsensusServerImpl",type="syncLag"}) by (instance)' "$monitor_url/api/v1/query"); echo "$resp" > "$artifact_dir/sync_lag_${flush_no}.json"; vals=$(echo "$resp"|grep -o '"value":\[[^]]*,"[^"]*"\]'|sed -E 's/.*,"([^"]*)".*/\1/'||true); bad=$(echo "$vals"|awk '$1>0.0001{n++}END{print n+0}'); now=$(date +%s); if [[ -n "$vals" && "$bad" == 0 ]]; then ((zero==0))&&zero=$now; ((now-zero>=60))&&return 0; else zero=0; fi; if ((SYNC_TIMEOUT>0 && now-start>SYNC_TIMEOUT)); then v_warnMessage="Sync Lag did not return to zero within ${SYNC_TIMEOUT}s; values=${vals:-unavailable}"; return 1; fi; sleep 10; done; }
set_ttl_and_schema(){ cli "$query_ip" "create database $DB" >"$artifact_dir/create_database.out" 2>&1 || true; cli "$query_ip" "alter database $DB set PROPERTIES ttl=$TTL_MS" >"$artifact_dir/set_ttl_database.out" 2>&1 || fail 'set database TTL failed'; table_cli 'alter table table_0 set properties ttl=300000' >"$artifact_dir/set_ttl_table.out" 2>&1 || true; table_cli 'alter table table_0_v set properties ttl=300000' >"$artifact_dir/set_ttl_view.out" 2>&1 || true; }
prepare_benchmark_conf(){
  benchmark_conf="$artifact_dir/benchmark_conf"
  cp -a "$benchmark_home/conf" "$benchmark_conf"
  cat >> "$benchmark_conf/config.properties" <<EOF
DB_SWITCH=IoTDB-200-SESSION_BY_TABLET
IoTDB_DIALECT_MODE=table
TABLE_TIME_COLUMN=col_time
IoTDB_TABLE_WRITABLE_VIEW=true
HOST=$query_ip
PORT=6667
USERNAME=$db_user_name
PASSWORD=$root_pw
DB_NAME=test
IS_DELETE_DATA=true
LOOP=100000
TEST_MAX_TIME=720000
USE_MEASUREMENT=true
IS_RECORD_CURRENT_REALLY_TIME=true
OPERATION_PROPORTION=1:0:0:0:0:0:0:0:0:0:0:0:0
DEVICE_NUMBER=6000
SENSOR_NUMBER=100
GROUP_NAME_PREFIX=g_
IoTDB_TABLE_NAME_PREFIX=table_
DEVICE_NAME_PREFIX=d_
SENSOR_NAME_PREFIX=s_
SCHEMA_CLIENT_NUMBER=20
DATA_CLIENT_NUMBER=80
GROUP_NUMBER=1
IoTDB_TABLE_NUMBER=1
STRING_LENGTH=16
DOUBLE_LENGTH=2
OBJECT_LENGTH=2000
LINE_RATIO=0
SIN_RATIO=0
SQUARE_RATIO=0
RANDOM_RATIO=1
CONSTANT_RATIO=0
DATA_SEED=666
BATCH_SIZE_PER_WRITE=100
DEVICE_NUM_PER_WRITE=1
CREATE_SCHEMA=true
INSERT_DATATYPE_PROPORTION=0:1:1:1:1:1:0:0:0:0:1
START_TIME=2022-01-01T00:00:00+08:00
IS_OUT_OF_ORDER=false
RESULT_PRINT_INTERVAL=120
EOF
  cp "$benchmark_conf/config.properties" "$artifact_dir/benchmark_config.properties"
}
validate_table_database(){
  table_cli 'show tables' >"$artifact_dir/show_tables.out" 2>&1 || { invalid "table database query failed; see $artifact_dir/show_tables.out"; return 1; }
  if ! grep -Eq '^[[:space:]]*\|[[:space:]]*table_' "$artifact_dir/show_tables.out"; then
    invalid "no benchmark table found in $DB; see $artifact_dir/show_tables.out"
    return 1
  fi
  table_cli 'desc table_0' >"$artifact_dir/desc_table_0.out" 2>&1 || { invalid "table schema query failed; see $artifact_dir/desc_table_0.out"; return 1; }
  if ! grep -Eq '\|[[:space:]]*s_[0-9]+[[:space:]]*\|[[:space:]]*OBJECT[[:space:]]*\|' "$artifact_dir/desc_table_0.out"; then
    invalid "benchmark table has no OBJECT column; see $artifact_dir/desc_table_0.out"
    return 1
  fi
  log INFO "Database-side validation found benchmark table(s) and an OBJECT field in $DB"
}
validate_readonly_backlog(){
  local lag
  lag=$(grep -o '"value":\[[^]]*,"[^"]*"\]' "$artifact_dir/sync_lag_dn3_readonly.json" 2>/dev/null |
    sed -E 's/.*,"([^"]*)"\].*/\1/' | awk '$1>0.0001{n++}END{print n+0}')
  if [[ "${lag:-0}" == 0 ]]; then
    invalid "DN3 readonly phase produced no non-zero Sync Lag; TTL/Object missing-file scenario was not constructed; see $artifact_dir/sync_lag_dn3_readonly.json"
    return 1
  fi
  log INFO "Readonly phase produced non-zero Sync Lag on ${lag} instance(s)"
}
run_benchmark(){
  prepare_benchmark_conf; mkdir -p "$artifact_dir/benchmark"
  BENCHMARK_HOME="$benchmark_home" timeout "${V2_0111_BENCHMARK_TIMEOUT:-900}" "$benchmark" -cf "$benchmark_conf" >"$artifact_dir/benchmark/benchmark.out" 2>&1 &
  benchmark_pid=$!
}
collect_object_logs(){ while read -r n; do s=${n##*.}; ssh -n "$os_user_name@$n" "sudo grep -hE 'Object|object|TTL|delete|deletion|NoSuchFile|FileNotFound' '$db_dir'/logs/log_datanode_object_deletion* '$db_dir'/logs/log_datanode_all* 2>/dev/null" >"$artifact_dir/object_${s}.log" || true; done <"$dn_file"; grep -RniE 'Object|object|TTL|delete|NoSuchFile|FileNotFound|syncLag' "$artifact_dir" >"$artifact_dir/object_ttl_evidence.log" || true; }
backup_logs(){ while read -r n; do s=${n##*.}; ssh -n "$os_user_name@$n" "sudo tar -C '$db_dir' -czf - logs 2>/dev/null" >"$artifact_dir/node_${s}_logs.tar.gz" || true; done <"$dn_file"; }
legacy_main(){ true; }
main(){
  [[ -x "$benchmark" ]] || { invalid "benchmark missing: $benchmark"; return 1; }
  stop_clean || { fail 'cluster cleanup failed'; return 1; }
  set_conf || { fail 'cluster configuration failed'; return 1; }
  start || { fail 'cluster start failed'; return 1; }
  log INFO 'Starting benchmark while all three DataNodes are writable'
  run_benchmark
  for i in $(seq 1 60); do cli "$query_ip" flush >"$artifact_dir/flush_${i}.out" 2>&1 || true; sleep 3; done
  table_cli 'show tables' >"$artifact_dir/show_tables_before_ttl.out" 2>&1 || true
  table_cli 'select count(*) from table_0' >"$artifact_dir/count_table_0_before_ttl.out" 2>&1 || true
  table_cli 'select count(*) from table_0_v' >"$artifact_dir/count_table_0_v_before_ttl.out" 2>&1 || true
  set_ttl_and_schema; ((fail_flag==0)) || return 1
  cli "$query_ip" 'show cluster' >"$artifact_dir/show_cluster_before_outage.out" 2>&1 || true
  move_licenses || { fail 'failed to move licenses'; return 1; }
  log INFO "All DN licenses moved; waiting ${OUTAGE_SEC}s for pending Object files to expire"
  sleep "$OUTAGE_SEC"
  restore_licenses
  cli "$query_ip" 'show cluster' >"$artifact_dir/show_cluster_after_restore.out" 2>&1 || true
  wait "$benchmark_pid" 2>/dev/null || true
  validate_table_database || return 1
  table_cli 'select count(*) from table_0' >"$artifact_dir/count_table_0_after_restore.out" 2>&1 || true
  table_cli 'select count(*) from table_0_v' >"$artifact_dir/count_table_0_v_after_restore.out" 2>&1 || true
  log INFO 'Waiting for Sync Lag to reach zero without a deadline'
  collect_object_logs
  cli "$query_ip" flush >"$artifact_dir/flush.out" 2>&1 || true
  if wait_lag_zero; then log INFO 'Sync Lag returned to zero: PASS'; else fail_flag=$((fail_flag+1)); log ERROR "${v_warnMessage:-Sync Lag did not return to zero}"; fi
  collect_object_logs
  backup_logs
}
main
