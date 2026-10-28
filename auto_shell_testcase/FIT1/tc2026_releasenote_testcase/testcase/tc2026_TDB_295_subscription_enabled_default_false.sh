#!/bin/bash
set -uo pipefail
cur_dir="$(cd "$(dirname "$0")" && pwd)"; SCRIPT_NAME=$(basename "$0")
conf_file="$cur_dir/../conf/test.conf"; nodeinfo_dir="$cur_dir/../conf"; clean_env_dir="$cur_dir/../clean_env"; prepare_env_dir="$cur_dir/../prepare_env"
get_conf(){ grep "^$1=" "$conf_file"|awk -F= '{print $2}'|sed 's/[[:space:]]//g'; }
os_user_name=$(get_conf os_user_name); testdb=$(get_conf v_testdb); db_parent_dir=$(get_conf v_db_parent_dir); CSV_FILE=$(get_conf CSV_FILE)
db_dir="$db_parent_dir/$testdb"; cli_dir="$db_dir"; db_sys_admin=root; bm_conn_pw=TimechoDB@2021; v_consensus=IoTConsensus; fail_flag=0; v_warnNum=0; v_warnMessage="."
log_file="$cur_dir/${SCRIPT_NAME}.log"; test_time=$(date +%Y-%m-%d-%H:%M:%S); start_sec=$(date +%s); backup_dir="$cur_dir/backup_TDB-295_$test_time"; mkdir -p "$backup_dir"
log(){ echo "[$(date '+%F %T')] [$1] $2"|tee -a "$log_file"; }; check(){ if [ "$1" -ne 0 ]; then log ERROR "$2"; fail_flag=$((fail_flag+1)); else log INFO "$2"; fi; }
rm -f "$nodeinfo_dir/confignode.txt" "$nodeinfo_dir/datanode.txt"; cp "$nodeinfo_dir/confignode_3c.txt" "$nodeinfo_dir/confignode.txt"; cp "$nodeinfo_dir/datanode_3d.txt" "$nodeinfo_dir/datanode.txt"
seed_cn_ip=$(head -1 "$nodeinfo_dir/confignode.txt"|tr -d ' '):10710; query_ip=$(head -1 "$nodeinfo_dir/datanode.txt"|tr -d ' ')
log INFO 'clean cluster'; sh -x "$clean_env_dir/stop_cluster.sh" >>"$log_file" 2>&1 || true; sh -x "$clean_env_dir/clean_cluster.sh" >>"$log_file" 2>&1; check $? 'clean cluster'; sh -x "$clean_env_dir/reset_conf.sh" >>"$log_file" 2>&1; check $? 'reset conf'; sh -x "$clean_env_dir/clear_cache.sh" >>"$log_file" 2>&1 || true
for ip in $(awk '{print $1}' "$nodeinfo_dir/datanode.txt" "$nodeinfo_dir/confignode.txt"|sort -u); do ssh "$os_user_name@$ip" "f='$db_dir/conf/iotdb-system.properties'; setv(){ grep -q \"^\$1=\" \"\$f\" && sed -i \"s|^\$1=.*|\$1=\$2|\" \"\$f\" || echo \"\$1=\$2\" >>\"\$f\"; }; setv cn_seed_config_node $seed_cn_ip; setv cn_internal_address $ip; setv dn_seed_config_node $seed_cn_ip; setv dn_internal_address $ip; setv dn_rpc_address $ip; setv data_replication_factor 3; setv schema_replication_factor 3; setv data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus; setv schema_region_consensus_protocol_class org.apache.iotdb.consensus.ratis.RatisConsensus; sed -i '/^subscription_enabled[[:space:]]*=/d' \"\$f\"" >>"$log_file" 2>&1; check $? "configure $ip"; done
grep -Eq '^subscription_enabled=false[[:space:]]*$' "$db_dir/conf/iotdb-system.properties.template"; check $? 'template explicitly contains subscription_enabled=false'
sh -x "$prepare_env_dir/start_cluster_v20.sh" 1 6 >>"$log_file" 2>&1; start_rc=$?; check $start_rc 'start 3C3D cluster'; if [ $start_rc -ne 0 ]; then result=ENV_FAIL; elapsed=$(( $(date +%s)-start_sec )); [ -f "$CSV_FILE" ] || echo 'Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage' >"$CSV_FILE"; echo "$test_time,$testdb,$v_consensus,$SCRIPT_NAME,$result,$elapsed,$v_warnNum,cluster_start_failed" >>"$CSV_FILE"; exit 1; fi; sleep 20
run_sql(){
  local dialect="$1" output="$2" sql="$3"
  "$cli_dir/sbin/start-cli.sh" -u root -pw "$bm_conn_pw" -h "$query_ip" -sql_dialect "$dialect" -e "$sql" >"$output" 2>&1
}

# Exercise the tree and table dialects independently.  A tree-model database
# cannot be addressed through the table dialect (and vice versa).
run_sql tree "$backup_dir/tree_create.out" 'create database root.tdb295;'; check $? 'create tree database'
run_sql tree "$backup_dir/tree_schema.out" 'create timeseries root.tdb295.d.s with datatype=INT32,encoding=PLAIN;'; check $? 'create tree timeseries'
run_sql tree "$backup_dir/tree_insert.out" 'insert into root.tdb295.d(time,s) values(1,1);insert into root.tdb295.d(time,s) values(2,2);insert into root.tdb295.d(time,s) values(3,3);'; check $? 'write tree data'

run_sql table "$backup_dir/table_create.out" 'create database tdb295_table;'; check $? 'create table database'
run_sql table "$backup_dir/table_schema.out" 'create table tdb295_table.sensor_data (time TIMESTAMP TIME, device_id STRING TAG, temperature INT32 FIELD);'; check $? 'create table schema'
run_sql table "$backup_dir/table_insert.out" "insert into tdb295_table.sensor_data(time,device_id,temperature) values(1000,'d1',10);insert into tdb295_table.sensor_data(time,device_id,temperature) values(2000,'d1',20);insert into tdb295_table.sensor_data(time,device_id,temperature) values(3000,'d2',30);"; check $? 'write table data'

run_sql tree "$backup_dir/tree_flush.out" 'flush;'; check $? 'flush tree data'
run_sql table "$backup_dir/table_flush.out" 'flush;'; check $? 'flush table data'

run_sql tree "$backup_dir/tree_query.out" 'select * from root.tdb295.d;'
grep -qE '\|[[:space:]]+1\|' "$backup_dir/tree_query.out" && grep -qE '\|[[:space:]]+2\|' "$backup_dir/tree_query.out" && grep -qE '\|[[:space:]]+3\|' "$backup_dir/tree_query.out"
check $? 'query tree data after flush'
run_sql table "$backup_dir/table_query.out" 'select * from tdb295_table.sensor_data;'; grep -qE 'd1|d2' "$backup_dir/table_query.out"; check $? 'query table data after flush'
for ip in $(awk '{print $1}' "$nodeinfo_dir/datanode.txt"); do ssh "$os_user_name@$ip" "if grep -Eq '^subscription_enabled[[:space:]]*=' '$db_dir/conf/iotdb-system.properties'; then grep -Eq '^subscription_enabled=false[[:space:]]*$' '$db_dir/conf/iotdb-system.properties'; fi"; check $? "default false on $ip"; scp -q "$os_user_name@$ip:$db_dir/conf/iotdb-system.properties" "$backup_dir/$ip.properties" || true; done
elapsed=$(( $(date +%s)-start_sec )); [ -f "$CSV_FILE" ] || echo 'Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage' >"$CSV_FILE"; result=PASS; [ "$fail_flag" -gt 0 ] && result=FAIL; echo "$test_time,$testdb,$v_consensus,$SCRIPT_NAME,$result,$elapsed,$v_warnNum,$v_warnMessage" >>"$CSV_FILE"; cp "$log_file" "$backup_dir/"; log INFO "RESULT=$result fail_flag=$fail_flag CSV=$CSV_FILE backup=$backup_dir"; [ "$fail_flag" -eq 0 ]
