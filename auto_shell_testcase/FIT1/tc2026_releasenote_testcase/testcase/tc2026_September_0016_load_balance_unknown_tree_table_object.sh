#!/bin/bash
# 2026-09-16: Copy of tc2026_September_0016_load_balance_unknown_tree_table_object.sh.
# 1C4D, SchemaRegion=3, DataRegion=2, default protocols; tree has no OBJECT.
# At minute 10 stop a DN owning both workloads. Require SHOW CLUSTER Unknown
# AND successful process inspection proving DataNode has exited.
# Submit tree and table LOAD BALANCE while the DN is stopped; restore immediately
# after both requests, then wait for migrations and perform the original checks.
# LOAD BALANCE rejection is still a test failure. Original ReadOnly case unchanged.
set +x
set -uo pipefail
SCRIPT_NAME=$(basename "$0")
cur_dir=$(cd "$(dirname "$0")" && pwd)
base_dir=$(cd "$cur_dir/.." && pwd)
conf_file="$base_dir/conf/test.conf"
cfg() { sed -n "s/^$1=//p" "$conf_file" | head -1 | tr -d '\r'; }
os_user_name=$(cfg os_user_name)
testdb=$(cfg v_testdb)
db_parent_dir=$(cfg v_db_parent_dir)
db_dir="$db_parent_dir/$testdb"
db_user_name=$(cfg db_user_name); db_user_name=${db_user_name:-root}
db_password=$(cfg v20_root_pw)
[[ -n "$db_password" ]] || db_password=$(cfg root_pw)
if [[ -z "$db_password" ]]; then
  if grep -q '^passwd_param=.*TimechoDB' "$db_dir/sbin/start-cli.sh"; then
    db_password='TimechoDB@2021'
  else db_password=root; fi
fi
CSV_FILE=$(cfg CSV_FILE); CSV_FILE=${CSV_FILE:-test_result.csv}
case "$CSV_FILE" in
  /*) csv_path="$CSV_FILE";;
  *) csv_path="$cur_dir/$CSV_FILE";;
esac
v_consensus=${v_consensus:-IoTConsensus}
v_warnNum=0
run_id=$(date +%Y%m%d_%H%M%S)_$$
artifact_dir="$cur_dir/${testdb}/load_balance_unknown_${run_id}"
mkdir -p "$artifact_dir" || exit 1
log_file="$artifact_dir/test.log"
fail_flag=0
v_warnMessage=''
bm_pids=()
offline_ip=''
fault_id=''
fault_ip=''
cluster_touched=0
finished=0
test_begin=$(date +%s)
BM_SECONDS=1200
UNKNOWN_AT_SECONDS=600
MIGRATION_TIMEOUT=${LB_MIGRATION_TIMEOUT:-1800}
SYNC_TIMEOUT=${LB_SYNC_TIMEOUT:-1800}
bm_home="$base_dir/benchmark/bm_20260519_writeview_v20"
cn_ips=(); dn_ips=(); all_ips=()
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$log_file"; }
fail() { fail_flag=$((fail_flag+1)); v_warnMessage="${v_warnMessage}$*; "; log "FAIL: $*"; }
remote() { local host=$1; shift; timeout 90 ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 "$os_user_name@$host" "$@"; }
cli() {
  local host=$1 dialect=$2 sql=$3 out=$4 rc
  # Do not enable xtrace: CLI credentials must not appear in the output file.
  timeout 75 bash "$db_dir/sbin/start-cli.sh" -h "$host" -u "$db_user_name" -pw "$db_password" \
    -sql_dialect "$dialect" -timeout 60 -disableISO8601 -e "$sql" > "$out" 2>&1
  rc=$?
  ((rc==0)) && ! grep -Eiq 'Exception|Error[: ]|ErrorCan|not ready|INTERNAL_SERVER_ERROR|not logged in|statement.*fail' "$out"
}
sql_ok() {
  cli "$1" "$2" "$3" "$4" && grep -qi 'executed successfully' "$4" && return 0
  fail "$2 SQL failed: $3 (see $4)"; return 1
}

# Parse CLI tables by header, with complete-row-count validation. Missing/malformed
# output never becomes an empty successful result. Query canonicalization preserves
# values and duplicates; sorting removes only presentation row order differences.
cat > "$artifact_dir/parse.py" <<'PY'
import sys, re, json
from pathlib import Path
sys.excepthook=sys.__excepthook__  # avoid unrelated system apport/OpenSSL hook failures
def table(path):
    s=Path(path).read_text(errors='replace')
    if re.search(r'Exception|Error[: ]|not logged in',s,re.I):
        raise ValueError('CLI error: '+path)
    empty=bool(re.search(r'^\s*Empty set\.?\s*$',s,re.M))
    lines=[x.strip() for x in s.splitlines() if x.strip().startswith('|') and x.strip().endswith('|')]
    if not lines:
        if empty: return [], []
        raise ValueError('missing table: '+path)
    cells=[[v.strip() for v in x[1:-1].split('|')] for x in lines]
    header=cells[0]
    rows=[r for r in cells[1:] if r!=header]  # repeated page headers
    if any(len(r)!=len(header) for r in rows): raise ValueError('malformed rows: '+path)
    n=re.findall(r'Total line number\s*=\s*(\d+)',s)
    if empty:
        if rows or (n and int(n[-1])!=0):
            raise ValueError('inconsistent empty result: '+path)
        return header, []
    if not n or int(n[-1])!=len(rows): raise ValueError('missing/truncated row count: '+path)
    return header, rows
def records(path):
    h,r=table(path); return [dict(zip(h,x)) for x in r]
def workload_regions(tree_path, table_path):
    rows=[]
    for path,db in ((tree_path,'root.test.g_0'),(table_path,'usr_sod0')):
        scoped=[r for r in records(path) if r['Database']==db]
        if not scoped: raise ValueError('missing workload Regions for '+db+': '+path)
        rows.extend(scoped)
    return rows
mode=sys.argv[1]
if mode=='dn':
    rows=records(sys.argv[2]); expected=sys.argv[3].split(','); special=sys.argv[4]; state=sys.argv[5]
    assert len(rows)==4 and {r['RpcAddress'] for r in rows}==set(expected), 'wrong DN topology'
    assert all(r['Status']==(state if r['RpcAddress']==special else 'Running') for r in rows), 'DN state not ready'
elif mode=='cluster':
    rows=records(sys.argv[2]); cn=sys.argv[3]; dns=set(sys.argv[4].split(','))
    assert len(rows)==5 and all(r['Status']=='Running' for r in rows)
    assert {r['InternalAddress'] for r in rows if r['NodeType']=='ConfigNode'}=={cn}
    assert {r['InternalAddress'] for r in rows if r['NodeType']=='DataNode'}==dns
elif mode=='cluster_unknown':
    rows=records(sys.argv[2]); cn=sys.argv[3]; dns=set(sys.argv[4].split(',')); target=sys.argv[5]
    assert len(rows)==5 and target in dns, 'wrong cluster topology/target'
    cn_rows=[r for r in rows if r['NodeType']=='ConfigNode']
    dn_rows=[r for r in rows if r['NodeType']=='DataNode']
    assert len(cn_rows)==1 and cn_rows[0]['InternalAddress']==cn and cn_rows[0]['Status']=='Running', 'CN not Running'
    assert len(dn_rows)==4 and {r['InternalAddress'] for r in dn_rows}==dns, 'wrong DN topology'
    assert all(r['Status']==('Unknown' if r['InternalAddress']==target else 'Running') for r in dn_rows), 'target not Unknown or another DN not Running'
elif mode=='choose':
    nodes=records(sys.argv[2]); regions=workload_regions(sys.argv[3],sys.argv[4])
    for n in reversed(nodes):
        nid=n.get('NodeID',n.get('DataNodeId'))
        dbs={r['Database'] for r in regions if r['DataNodeId']==nid}
        if n['Status']=='Running' and {'root.test.g_0','usr_sod0'}<=dbs:
            print(nid,n['RpcAddress']); break
    else: raise ValueError('no DN owns both tree/table Regions')
elif mode=='empty':
    assert len(table(sys.argv[2])[1])==0, 'migrations still present'
elif mode=='regions':
    rows=workload_regions(sys.argv[2],sys.argv[3]); groups={}
    for r in rows:
        if r['Database'] in ('root.test.g_0','usr_sod0'):
            key=(r['Database'],r['RegionId'],r['Type']); groups.setdefault(key,[]).append(r)
    assert {k[0] for k in groups}=={'root.test.g_0','usr_sod0'}, 'missing workload Regions'
    for (_,_,typ),rs in groups.items():
        assert len({r['DataNodeId'] for r in rs})==(3 if typ=='SchemaRegion' else 2), 'wrong replica count'
        assert all(r['Status'] in ('Running','ReadOnly') for r in rs), 'transitional Region'
elif mode=='schema':
    tree=records(sys.argv[2]); tab=records(sys.argv[3])
    assert tree and not any('OBJECT' in r.values() for r in tree), 'tree schema empty or contains OBJECT'
    objs=[r.get('ColumnName',r.get('Column',r.get('column',''))) for r in tab if 'OBJECT' in r.values()]
    assert objs and all(re.fullmatch(r's_\d+',c) for c in objs), 'table OBJECT column not found'
    print(','.join(objs))
elif mode=='normalize':
    h,rows=table(sys.argv[2]); assert rows, 'empty query baseline/result'
    print(json.dumps(h,ensure_ascii=False))
    for r in sorted(rows): print(json.dumps(r,ensure_ascii=False))
elif mode=='positive':
    h,rows=table(sys.argv[2]); assert rows
    if len(sys.argv)>3 and sys.argv[3]=='table':
        expected=['device_id']+['count_s_'+str(i) for i in range(12)]
        assert h==expected, 'unexpected table COUNT columns: '+repr(h)
        counts=[int(v) for row in rows for v in row[1:]]
    else:
        counts=[int(v) for row in rows for k,v in zip(h,row) if 'count(' in k.lower()]
    assert counts and all(v>0 for v in counts), 'missing benchmark/OBJECT data'
PY
parse() { python3 "$artifact_dir/parse.py" "$@"; }

preflight() {
  local h
  [[ "$testdb" =~ ^[a-zA-Z0-9_.-]+$ && "$db_parent_dir" =~ ^/[a-zA-Z0-9_/-]+$ && "$os_user_name" =~ ^[a-zA-Z0-9_-]+$ ]] || { fail 'Unsafe/empty installation configuration'; return 1; }
  [[ "$testdb" != '.' && "$testdb" != '..' ]] || return 1
  for h in python3 timeout ssh curl; do command -v "$h" >/dev/null || { fail "Missing tool $h"; return 1; }; done
  while read -r h; do [[ -n "$h" ]] && cn_ips+=("$h"); done < <(tr -d ' \r' < "$base_dir/conf/confignode_1c.txt")
  while read -r h; do [[ -n "$h" ]] && dn_ips+=("$h"); done < <(tr -d ' \r' < "$base_dir/conf/datanode_4d.txt")
  [[ ${#cn_ips[@]} == 1 && ${#dn_ips[@]} == 4 && $(printf '%s\n' "${dn_ips[@]}" | sort -u | wc -l) == 4 ]] || { fail 'Expected exactly 1 CN and 4 distinct DN hosts'; return 1; }
  while read -r h; do all_ips+=("$h"); done < <(printf '%s\n' "${cn_ips[@]}" "${dn_ips[@]}" | sort -u)
  for h in "${all_ips[@]}"; do
    [[ "$h" =~ ^[0-9.]+$ ]] || { fail "Invalid IP $h"; return 1; }
    remote "$h" "test -d '$db_dir/conf_orig' && test -f '$db_dir/conf_orig/iotdb-system.properties' && test -f '$db_dir/sbin/start-datanode.sh' && test -f '$db_dir/sbin/start-confignode.sh' && command -v curl && command -v python3 && sudo -n true" > "$artifact_dir/preflight_$h.out" 2>&1 || { fail "Preflight failed on $h"; return 1; }
  done
  [[ -f "$bm_home/bin/startup.sh" && -f "$bm_home/weather_6h_diff/conf_tree/config.properties" && -f "$bm_home/weather_6h_diff/conf_tab1/config.properties" ]] || { fail 'Benchmark template missing'; return 1; }
  query_ip=${dn_ips[0]}
  dn_csv=$(IFS=,; echo "${dn_ips[*]}")
  printf '%s\n' "${cn_ips[@]}" > "$artifact_dir/confignode.txt"
  printf '%s\n' "${dn_ips[@]}" > "$artifact_dir/datanode.txt"
}
node_stop() {
  local h=$1 role=$2 started=$(date +%s) process
  [[ "$role" == datanode ]] && process=DataNode || process=ConfigNode
  remote "$h" "source /etc/profile; sudo bash '$db_dir/sbin/stop-$role.sh'" > "$artifact_dir/stop_${role}_${h}.out" 2>&1 || log "Stop command returned nonzero on $h; checking process"
  while (( $(date +%s)-started < 180 )); do
    if remote "$h" 'source /etc/profile; sudo jps -l' > "$artifact_dir/jps_${h}.out" 2>&1; then
      grep -Eq "[ .]${process}$" "$artifact_dir/jps_${h}.out" || return 0
    fi
    sleep 3
  done
  fail "Stop $role $h timed out; cleanup/next DN stop forbidden"; return 1
}
configure() {
  local h
  cluster_touched=1
  # Stop every service on the selected hosts, then verify before deleting data/logs.
  for h in "${all_ips[@]}"; do node_stop "$h" datanode || return 1; node_stop "$h" confignode || return 1; done
  for h in "${all_ips[@]}"; do
    timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=10 "$os_user_name@$h" sudo python3 - "$db_dir" "$testdb" "$h" "${cn_ips[0]}" <<'PY' > "$artifact_dir/config_$h.out" 2>&1
import pathlib,sys,shutil,re
db=pathlib.Path(sys.argv[1]); name,ip,cn=sys.argv[2:]
assert db.is_absolute() and db.name==name and db.parent!=pathlib.Path('/')
assert db.resolve()==db and (db/'conf_orig/iotdb-system.properties').is_file()
# conf_orig is the package baseline. Clear only explicit test-installation paths.
for p in (db/'data',db/'logs',pathlib.Path('/data1/iotdb_data')/name/'data',pathlib.Path('/data3/iotdb_data')/name/'data'):
    assert not p.is_symlink() and p.resolve()==p
    if p.exists(): shutil.rmtree(str(p))
conf=db/'conf'; assert not conf.is_symlink()
if conf.exists(): shutil.rmtree(str(conf))
shutil.copytree(str(db/'conf_orig'),str(conf))
settings=dict(cn_seed_config_node=cn+':10710',dn_seed_config_node=cn+':10710',cn_internal_address=ip,
 dn_internal_address=ip,dn_rpc_address=ip,schema_replication_factor='3',data_replication_factor='2',
 cn_metric_reporter_list='PROMETHEUS',cn_metric_prometheus_reporter_port='9081',
 dn_metric_reporter_list='PROMETHEUS',dn_metric_prometheus_reporter_port='9091',dn_metric_level='IMPORTANT',
 dn_data_dirs='data/datanode/data',dn_wal_dirs='data/datanode/wal',
 schema_region_group_extension_policy='CUSTOM',data_region_group_extension_policy='CUSTOM',
 default_schema_region_group_num_per_database='4',default_data_region_group_num_per_database='4')
p=conf/'iotdb-system.properties'; s=p.read_text()
# Use implementation defaults, never retain a protocol override from an earlier test.
s=re.sub(r'(?m)^\s*(config_node|schema_region|data_region)_consensus_protocol_class\s*=.*$', '', s)
for k,v in settings.items():
    s=re.sub(r'(?m)^\s*#?\s*'+re.escape(k)+r'\s*=.*$', '', s)
    s+='\n'+k+'='+v
p.write_text(s+'\n')
for role,heap,off in [('confignode','2G','1G'),('datanode','4G','2G')]:
    p=conf/(role+'-env.sh'); s=p.read_text()
    for k,v in [('ON_HEAP_MEMORY',heap),('OFF_HEAP_MEMORY',off)]:
        s=re.sub(r'(?m)^\s*#?\s*'+k+r'=.*$',k+'="'+v+'"',s)
    p.write_text(s)
for p in (db/'sbin').glob('*.sh'):
    p.chmod(p.stat().st_mode | 0o111)
print('Configured',db,ip,'SR=3 DR=2; consensus=package default')
PY
    [[ $? == 0 ]] || { fail "Clean/configure failed on $h"; return 1; }
  done
  cp "$artifact_dir/confignode.txt" "$base_dir/conf/confignode.txt"
  cp "$artifact_dir/datanode.txt" "$base_dir/conf/datanode.txt"
  timeout 600 bash "$base_dir/prepare_env/start_cluster_v20.sh" 1 5 > "$artifact_dir/start_cluster.out" 2>&1 || { fail 'Cluster start helper failed/timeout (see start_cluster.out)'; return 1; }
  cli "$query_ip" tree 'show cluster;' "$artifact_dir/cluster_started.out" && parse cluster "$artifact_dir/cluster_started.out" "${cn_ips[0]}" "$dn_csv" || { fail 'Expected 1C4D all Running after startup'; return 1; }
}
wait_nodes() {
  local special=${1:-none} state=${2:-Running} begin=$(date +%s)
  while (( $(date +%s)-begin < 300 )); do
    if cli "$query_ip" tree 'show datanodes;' "$artifact_dir/nodes_latest.out" && parse dn "$artifact_dir/nodes_latest.out" "$dn_csv" "$special" "$state" 2> "$artifact_dir/nodes_parse.err"; then return 0; fi
    sleep 5
  done
  fail "SHOW DATANODES did not reach $special=$state with other DNs Running"; return 1
}
start_benchmark() {
  local kind src dst
  sql_ok "$query_ip" tree 'CREATE DATABASE root.test.g_0;' "$artifact_dir/create_tree.out" || return 1
  sql_ok "$query_ip" table 'CREATE DATABASE usr_sod0;' "$artifact_dir/create_table.out" || return 1
  for kind in tree table; do
    src=conf_tree; [[ "$kind" == table ]] && src=conf_tab1
    dst="$artifact_dir/bm_$kind"
    cp -r "$bm_home/weather_6h_diff/$src" "$dst" || return 1
    # Private templates; no changes to shared benchmark files/users. 12 sensors,
    # 24 devices, ~2 rows/sec/client, 4 KiB OBJECT: intentionally modest data volume.
    python3 - "$dst/config.properties" "$kind" "$dn_csv" "$db_user_name" "$db_password" <<'PY'
import sys,re,datetime,pathlib
p=pathlib.Path(sys.argv[1]); kind,hosts,user,pw=sys.argv[2:]; s=p.read_text()
settings=dict(HOST=hosts,PORT='6667,6667,6667,6667',USERNAME=user,PASSWORD=pw,
 TEST_MAX_TIME='1200000',LOOP='100000000',CREATE_SCHEMA='true',IS_DELETE_DATA='false',
 DEVICE_NUMBER='24',SENSOR_NUMBER='12',DATA_CLIENT_NUMBER='2',SCHEMA_CLIENT_NUMBER='1',
 GROUP_NUMBER='1',IoTDB_TABLE_NUMBER='1',OBJECT_LENGTH='4096',BATCH_SIZE_PER_WRITE='1',
 DEVICE_NUM_PER_WRITE='1',INTERVAL_BETWEEN_WRITE_BATCH='500',OP_MIN_INTERVAL='500',
 OPERATION_PROPORTION='1:0:0:0:0:0:0:0:0:0:0:0:0',
 START_TIME=datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
 RESULT_PRINT_INTERVAL='60',OBJECT_QUERY_FULL_CONTENT='true')
settings['INSERT_DATATYPE_PROPORTION']='0:1:1:1:1:1:2:1:3:1:0' if kind=='tree' else '0:0:0:0:0:0:8:0:3:0:1'
for k,v in settings.items():
    s=re.sub(r'(?m)^'+re.escape(k)+r'=.*$', '', s); s+='\n'+k+'='+v
p.write_text(s+'\n')
PY
    [[ $? == 0 ]] || { fail "Cannot prepare $kind benchmark configuration"; return 1; }
    chmod 600 "$dst/config.properties"
  done
  bm_start=$(date +%s)
  for kind in tree table; do
    BENCHMARK_HOME="$bm_home" MAX_HEAP_SIZE=2G timeout -k 15 1320 bash "$bm_home/bin/startup.sh" -cf "$artifact_dir/bm_$kind" > "$artifact_dir/benchmark_$kind.out" 2>&1 &
    bm_pids+=("$!")
  done
  log "Tree (no OBJECT) and table (OBJECT) benchmarks launched for 20 minutes"
}
wait_minute_ten() {
  local p
  while (( $(date +%s)-bm_start < UNKNOWN_AT_SECONDS )); do
    for p in "${bm_pids[@]}"; do kill -0 "$p" 2>/dev/null || { fail 'Benchmark exited before minute 10'; return 1; }; done
    sleep 2
  done
  log "Reached minute 10: injecting Unknown by stopping one DN"
}
wait_migrations() {
  local label=$1 begin=$(date +%s) stable=0 good dialect last_log=0 reason
  local errors="$artifact_dir/${label}_wait.err"
  while (( $(date +%s)-begin < MIGRATION_TIMEOUT )); do
    good=1
    : > "$errors"
    for dialect in tree table; do
      if cli "$query_ip" "$dialect" 'show migrations;' "$artifact_dir/${label}_migrations_${dialect}.out"; then
        parse empty "$artifact_dir/${label}_migrations_${dialect}.out" 2>> "$errors" || good=0
      else
        printf '%s SHOW MIGRATIONS failed; see %s_migrations_%s.out\n' "$dialect" "$label" "$dialect" >> "$errors"
        good=0
      fi
      cli "$query_ip" "$dialect" 'show regions;' "$artifact_dir/${label}_regions_${dialect}.out" || {
        printf '%s SHOW REGIONS failed; see %s_regions_%s.out\n' "$dialect" "$label" "$dialect" >> "$errors"
        good=0
      }
    done
    if ((good)); then
      parse regions "$artifact_dir/${label}_regions_tree.out" "$artifact_dir/${label}_regions_table.out" 2>> "$errors" || good=0
    fi
    if ((good)); then stable=$((stable+1)); else stable=0; fi
    ((stable>=3)) && { log "$label: migrations empty and Region replicas stable for 3 polls"; return 0; }
    if ((!good && $(date +%s)-last_log >= 60)); then
      reason=$(tail -1 "$errors")
      log "$label: waiting: $reason (details: $errors)"
      last_log=$(date +%s)
    fi
    sleep 5
  done
  fail "$label: LOAD BALANCE migrations/Region states timeout after ${MIGRATION_TIMEOUT}s; see $errors"; return 1
}
wait_fault_stopped() {
  local begin=$(date +%s)
  while (( $(date +%s)-begin < 300 )); do
    if cli "$query_ip" tree 'show cluster;' "$artifact_dir/cluster_unknown_latest.out" &&
       parse cluster_unknown "$artifact_dir/cluster_unknown_latest.out" "${cn_ips[0]}" "$dn_csv" "$fault_ip" 2> "$artifact_dir/cluster_unknown_parse.err" &&
       remote "$fault_ip" 'source /etc/profile; sudo -n jps -l' > "$artifact_dir/fault_jps_latest.out" 2>&1; then
      if grep -Eq '^[0-9]+[[:space:]]+.*[.]Jps$' "$artifact_dir/fault_jps_latest.out" &&
         ! grep -Eq '[ .]DataNode$' "$artifact_dir/fault_jps_latest.out"; then
        log "Stop confirmed: DN $fault_ip Unknown in SHOW CLUSTER and DataNode process absent"
        return 0
      fi
    fi
    sleep 5
  done
  fail "Stop not confirmed for $fault_ip: require SHOW CLUSTER Unknown AND DataNode process exit; see cluster_unknown_latest.out/fault_jps_latest.out"
  return 1
}
load_balance_unknown() {
  local selected dialect alt
  cli "$query_ip" tree 'show datanodes;' "$artifact_dir/nodes_before_unknown.out" || { fail 'Cannot discover Unknown target'; return 1; }
  for dialect in tree table; do
    cli "$query_ip" "$dialect" 'show regions;' "$artifact_dir/regions_before_unknown_${dialect}.out" || { fail "Cannot discover $dialect Regions"; return 1; }
  done
  selected=$(parse choose "$artifact_dir/nodes_before_unknown.out" "$artifact_dir/regions_before_unknown_tree.out" "$artifact_dir/regions_before_unknown_table.out" 2> "$artifact_dir/choose_target.err") || { fail 'Unknown target selection failed'; return 1; }
  read -r fault_id fault_ip <<< "$selected"
  for alt in "${dn_ips[@]}"; do [[ "$alt" != "$fault_ip" ]] && { query_ip=$alt; break; }; done
  offline_ip=$fault_ip
  log "Stopping fault DN $fault_ip (NodeID=$fault_id)"
  node_stop "$fault_ip" datanode || return 1
  wait_fault_stopped || return 1
  cp "$artifact_dir/cluster_unknown_latest.out" "$artifact_dir/unknown_confirmed.out"
  for dialect in tree table; do
    wait_fault_stopped || return 1
    log "Submitting $dialect LOAD BALANCE with DN $fault_ip Unknown"
    if sql_ok "$query_ip" "$dialect" 'LOAD BALANCE;' "$artifact_dir/load_balance_${dialect}.out"; then
      log "$dialect LOAD BALANCE accepted; migration completion checked after fault DN recovery"
    else
      log "$dialect LOAD BALANCE failed; continue without a migration wait"
    fi
  done
  restore_fault || return 1
  wait_migrations after_fault_recovery
}
wait_benchmark() {
  local p kind
  for p in "${bm_pids[@]}"; do wait "$p" || fail "Benchmark process $p failed or exceeded 22-minute watchdog"; done
  bm_pids=()
  for kind in tree table; do
    grep -q 'Test elapsed' "$artifact_dir/benchmark_$kind.out" || fail "$kind benchmark has no completion summary"
    grep -Eiq 'OutOfMemoryError|NullPointerException|TProtocolException' "$artifact_dir/benchmark_$kind.out" && fail "$kind benchmark fatal error"
  done
  log 'Benchmark processes have exited; data is now stable for comparison'
}
restore_fault() {
  if [[ -n "$offline_ip" ]]; then
    node_restart "$offline_ip" || return 1
  fi
}
wait_sync() {
  local begin=$(date +%s) h good stable=0
  while (( $(date +%s)-begin < SYNC_TIMEOUT )); do
    good=1
    for h in "${dn_ips[@]}"; do
      # Missing metric samples, fetch errors, NaN/Inf are NOT zero lag.
      if ! remote "$h" 'curl -fsS --max-time 8 http://127.0.0.1:9091/metrics' > "$artifact_dir/metrics_$h.out" 2>&1; then good=0; continue; fi
      awk '/^iot_consensus(_v2)?\{.*type="syncLag"/ {n++; if ($NF !~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/ || $NF+0!=0) bad++} END {exit !(n>0 && bad==0)}' "$artifact_dir/metrics_$h.out" || good=0
    done
    if ((good)); then stable=$((stable+1)); else stable=0; fi
    ((stable>=3)) && { log 'All 4 DNs syncLag=0 for 3 consecutive polls'; return 0; }
    sleep 10
  done
  fail "syncLag unavailable/nonzero after ${SYNC_TIMEOUT}s"; return 1
}
query_snapshot() {
  local label=$1 kind sql out
  for kind in tree table; do
    if [[ "$kind" == tree ]]; then
      sql='select count(*) from root.test.g_0.** align by device;'
    else
      sql='select device_id,count(s_0) as count_s_0,count(s_1) as count_s_1,count(s_2) as count_s_2,count(s_3) as count_s_3,count(s_4) as count_s_4,count(s_5) as count_s_5,count(s_6) as count_s_6,count(s_7) as count_s_7,count(s_8) as count_s_8,count(s_9) as count_s_9,count(s_10) as count_s_10,count(s_11) as count_s_11 from usr_sod0.tab1mb_0 group by device_id order by device_id;'
    fi
    out="$artifact_dir/${label}_${kind}_counts.out"
    cli "$query_ip" "$kind" "$sql" "$out" && parse positive "$out" "$kind" && parse normalize "$out" > "$out.normalized" || { fail "$label $kind counts failed/empty"; return 1; }
    # Compare all result values too, not only counts (including OBJECT query values).
    # Fail explicitly if CLI output is truncated; never silently compare just a prefix.
    if [[ "$kind" == tree ]]; then sql='select * from root.test.g_0.** align by device;'
    else sql='select * from usr_sod0.tab1mb_0 order by device_id;'; fi
    out="$artifact_dir/${label}_${kind}_values.out"
    cli "$query_ip" "$kind" "$sql" "$out" && parse normalize "$out" > "$out.normalized" || { fail "$label $kind value query failed/empty/truncated"; return 1; }
  done
}
check_schema() {
  cli "$query_ip" tree 'show timeseries root.test.g_0.**;' "$artifact_dir/tree_schema.out" && \
    cli "$query_ip" table 'describe usr_sod0.tab1mb_0;' "$artifact_dir/table_schema.out" && \
    parse schema "$artifact_dir/tree_schema.out" "$artifact_dir/table_schema.out" > "$artifact_dir/object_columns.txt" || { fail 'Schema assertion: tree must have no OBJECT; table must contain OBJECT'; return 1; }
}
node_restart() {
  local h=$1
  # 2026-09-16: Follow tc2026_June_0050_remove_dn_obj_show_mig.sh: redirect
  # startup output to /dev/null, then verify Running via SHOW DATANODES.
  # The remote iotdb shell cannot create a redirect file in root-owned logs/.
  log "Restarting DN $h; waiting for all DNs Running"
  remote "$h" "source /etc/profile; cd '$db_dir' || exit 1; sudo -n true || exit 1; sudo -n bash ./sbin/start-datanode.sh -H '$db_dir/lb_${run_id}_${h}.hprof' > /dev/null 2>&1 < /dev/null &" || { fail "Restart command failed for $h"; return 1; }
  wait_nodes || { log "DN $h restart did not recover all DNs to Running; see nodes_latest.out and DN logs"; return 1; }
  offline_ip=''
  log "DN $h restarted; all DNs Running"
}
check_consistency() {
  local h alt kind part
  wait_nodes && wait_sync && check_schema && query_snapshot baseline || return 1
  for h in "${dn_ips[@]}"; do
    offline_ip=$h
    for alt in "${dn_ips[@]}"; do [[ "$alt" != "$h" ]] && { query_ip=$alt; break; }; done
    node_stop "$h" datanode || return 1
    if wait_nodes "$h" Unknown; then
      if query_snapshot "stop_$h"; then
        for kind in tree table; do for part in counts values; do
          diff -u "$artifact_dir/baseline_${kind}_${part}.out.normalized" "$artifact_dir/stop_${h}_${kind}_${part}.out.normalized" > "$artifact_dir/diff_${h}_${kind}_${part}.out" || fail "Replica data inconsistent: stopped=$h dialect=$kind comparison=$part"
        done; done
      fi
    fi
    node_restart "$h" || return 1
    wait_sync || return 1
  done
}
# 2026-09-16: Check only the requested exception patterns. Expected DN stop/
# recovery connection errors and read-only sync rejections are not test failures.
remote_log_count() {
  local node=$1 kind=$2 pattern=$3 mode=${4:-E}
  # Read plain and compressed all-logs without modifying the original files.
  # Do not use ssh -n: stdin carries the remote Python program.
  timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=10 "$os_user_name@$node" \
    "sudo -n python3 - '$db_dir/logs' '$kind' '$pattern' '$mode'" \
    2>> "$artifact_dir/log_check_${kind}_${node}.out" <<'PY'
import gzip, pathlib, re, sys
sys.excepthook = sys.__excepthook__
folder, kind, pattern, mode = sys.argv[1:]
files = sorted(p for p in pathlib.Path(folder).glob('*' + kind + '*all*') if p.is_file())
if not files:
    raise RuntimeError('No ' + kind + ' all-logs found in ' + folder)
match = (lambda line: pattern in line) if mode == 'F' else re.compile(pattern).search
count = 0
for path in files:
    opener = gzip.open if path.suffix == '.gz' else open
    with opener(path, 'rt', errors='replace') as stream:
        for number, line in enumerate(stream, 1):
            if match(line):
                count += 1
                print(str(path) + ':' + str(number) + ':' + line.rstrip(), file=sys.stderr)
print('PATTERN=' + pattern + ' COUNT=' + str(count), file=sys.stderr)
print(count)
PY
}
check_log_pattern() {
  local node=$1 kind=$2 severity=$3 label=$4 pattern=$5 mode=${6:-E} count role
  [[ "$kind" == confignode ]] && role=CN || role=DN
  if ! count=$(remote_log_count "$node" "$kind" "$pattern" "$mode"); then
    fail "$role $node log scan failed: $label (see log_check_${kind}_${node}.out)"
    return
  fi
  if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    fail "$role $node invalid log count: $label (see log_check_${kind}_${node}.out)"
    return
  fi
  log "$role $node $label: $count"
  if ((count > 0)); then
    if [[ "$severity" == FAIL ]]; then
      fail "$role $node $label: $count lines"
    else
      v_warnMessage+="$role $node $label: $count lines; "
      log "WARN $role $node $label: $count lines"
    fi
  fi
}
check_log() {
  local node pattern
  log "check ConfigNode/DataNode exception logs (specified patterns only)"
  while IFS= read -r node || [[ -n "$node" ]]; do
    node=${node//$'\r'/}
    [[ -z "$node" ]] && continue
    check_log_pattern "$node" confignode FAIL NullPointer 'NullPointer' F
    check_log_pattern "$node" confignode FAIL BufferUnderflow/HAS_MORE_STATE 'BufferUnderflowException|but return HAS_MORE_STATE'
  done < "${cur_dir}/../conf/confignode.txt"
  while IFS= read -r node || [[ -n "$node" ]]; do
    node=${node//$'\r'/}
    [[ -z "$node" ]] && continue
    check_log_pattern "$node" datanode FAIL NullPointer 'NullPointer' F
    check_log_pattern "$node" datanode WARN 'AutoResizingBuffer failed to allocate' 'AutoResizingBuffer failed to allocate' F
    check_log_pattern "$node" datanode FAIL 'MetadataLeaseFencedException ERROR' 'ERROR .*Failed to do the initialization for driver.*MetadataLeaseFencedException'
    check_log_pattern "$node" datanode FAIL 'Status 535/536 WARN/ERROR' ' (WARN|ERROR) .*Status code: (535|536)([, ]|$)'
    check_log_pattern "$node" datanode WARN 'bytesToReserve exceeds maxBytesPerFI' 'bytesToReserve should be in (0,maxBytesPerFI]' F
    pattern='CompactionTableSchemaNotMatchException|has overlapped data|which should be later than the last time|DataTypeInconsistentException|ArrayIndexOutOfBoundsException|IndexOutOfBoundsException|Alter timeseries .* data type from null to|StatisticsClassException|BufferUnderflowException|NegativeArraySizeException|is not in tsFileMetaData|The memory cost to be released is larger'
    check_log_pattern "$node" datanode FAIL "unexpected logs ($pattern)" "$pattern"
  done < "${cur_dir}/../conf/datanode.txt"
}

finish() {
  local p h status=PASS
  ((finished)) && return
  finished=1
  # Scope termination to this testcase's background timeout/benchmark processes only.
  for p in "${bm_pids[@]}"; do
    if kill -0 "$p" 2>/dev/null; then kill -TERM "$p" 2>/dev/null; wait "$p" 2>/dev/null; fail "Benchmark $p interrupted before completion"; fi
  done
  if ((cluster_touched)); then
    restore_fault
    check_log
  fi
  if ((fail_flag>0)); then
    status=FAIL
    for h in "${all_ips[@]}"; do
      timeout 300 ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$os_user_name@$h" "sudo tar -C '$db_dir' -czf - logs" > "$artifact_dir/node_${h}_logs.tar.gz" 2> "$artifact_dir/backup_$h.err" || fail "CN/DN log backup failed on $h"
    done
  fi
  log "RESULT=$status fail_flag=$fail_flag elapsed=$(($(date +%s)-test_begin))s"
  printf 'RESULT=%s\nfail_flag=%s\nv_warnMessage=%s\n' "$status" "$fail_flag" "$v_warnMessage" > "$artifact_dir/result.txt"
  # Keep the same CSV contract as the release-note testcases.  Write exactly once,
  # even when the main flow exits early; quote commas in diagnostics as CSV doubles.
  if [[ ! -s "$csv_path" ]] || ! head -1 "$csv_path" | grep -q '^Time,testTimechoDB,'; then
    printf 'Time,testTimechoDB,testConsensus,testCaseName,testResult,testElapsedTimeSeconds,warnNum,testOtherMessage,maxBMTestTimeSec,sumBMTestTimeSec\n' >> "$csv_path"
  fi
  csv_message=$(printf '%s' "$v_warnMessage" | sed 's/"/""/g; s/^[[:space:]]*//; s/[[:space:]]*$//')
  csv_elapsed=$(($(date +%s)-test_begin))
  printf '%s,%s,%s,%s,%s,%s,%s,"%s",,%s\n' "$(date '+%Y-%m-%dT%H:%M:%S.%3N%:z')" "$testdb" "$v_consensus" "$SCRIPT_NAME" "$status" "$csv_elapsed" "$v_warnNum" "$csv_message" "$(printf '%s' "$csv_elapsed")" >> "$csv_path"
  log "CSV result appended: $csv_path"
  log "Artifacts: $artifact_dir"
}
main() {
  preflight && configure && start_benchmark || return 1
  if wait_minute_ten; then load_balance_unknown; fi
  restore_fault || return 1
  wait_benchmark
  restore_fault || return 1
  wait_migrations after_benchmark || return 1
  check_consistency
}
trap 'fail "Interrupted by signal"; exit 130' INT TERM
trap finish EXIT
main
main_rc=$?
((main_rc==0)) || fail "Main flow could not finish (rc=$main_rc)"
finish
trap - EXIT
((fail_flag==0))
