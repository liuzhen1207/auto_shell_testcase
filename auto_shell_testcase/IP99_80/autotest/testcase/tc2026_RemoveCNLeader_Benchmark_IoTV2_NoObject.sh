#!/usr/bin/env bash
# Remove the ConfigNode leader under IoTConsensusV2 with concurrent tree/table benchmark.
# After benchmark completes, flush and wait for all three DN syncLag metrics to reach zero.
# Deploy/run from /data/iotdb/autotest/testcase on qa-lz-80.
set -Eeuo pipefail
fail_flag=0

BASE=$(cd "$(dirname "$0")/.." && pwd)
CONF=$BASE/conf/test.conf
OUTDIR=$(cd "$(dirname "$0")" && pwd)/remove_cn_leader_results
START_EPOCH=$(date +%s)
RUN_ID=$(date +%Y%m%d_%H%M%S); OUT=$OUTDIR/remove_cn_leader_iotv2_${RUN_ID}.out
cfg(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$CONF"; }
USER=$(cfg os_user_name); PW=$(cfg root_pw); DB=$(cfg v_testdb)
PARENT=$(cfg v_db_parent_dir); CLIENT=$(cfg v_shell_client_db_parent_dir); CLIENT=${CLIENT:-$PARENT}
mapfile -t CN < <(awk 'NF&&!/^#/ {print $1}' "$BASE/conf/confignode_3c.txt")
mapfile -t DN < <(awk 'NF&&!/^#/ {print $1}' "$BASE/conf/datanode_3d.txt")
Q=${DN[0]}; DB_DIR=$PARENT/$DB; CLI_DIR=$CLIENT/$DB
BM=$BASE/benchmark/bm_20260812_e158c2c_jdk17
BM_TEMPLATE=$BM/obj_ttl
mkdir -p "$OUTDIR"; : > "$OUT"
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$OUT"; }
sshx(){ local h=$1; shift; timeout 150 ssh -o BatchMode=yes -o ConnectTimeout=15 "$USER@$h" "$@"; }
cli(){ timeout --kill-after=3 "${2:-15}" bash "$CLI_DIR/sbin/start-cli.sh" -h "$Q" -u root -pw "$PW" -e "$1"; }

set_conf(){ local h=$1; sshx "$h" "python3 - '$DB_DIR/conf/iotdb-system.properties' '$h' '${CN[0]}' <<'PY'
import sys
f,ip,seed=sys.argv[1:]
vals={'cn_seed_config_node':seed+':10710','dn_seed_config_node':seed+':10710','cn_internal_address':ip,'cn_internal_port':'10710','cn_consensus_port':'10720','dn_rpc_address':ip,'dn_rpc_port':'6667','dn_internal_address':ip,'dn_internal_port':'10730','dn_mpp_data_exchange_port':'10740','dn_schema_region_consensus_port':'10750','dn_data_region_consensus_port':'10760','schema_replication_factor':'3','data_replication_factor':'3','cn_metric_reporter_list':'PROMETHEUS','data_region_consensus_protocol_class':'org.apache.iotdb.consensus.iot.IoTConsensusV2','dn_metric_reporter_list':'PROMETHEUS','dn_metric_level':'IMPORTANT','cn_metric_prometheus_reporter_port':'9091','dn_metric_prometheus_reporter_port':'9092'}
lines=open(f).read().splitlines(); out=[]
for line in lines:
 k=line.split('=',1)[0].strip() if '=' in line and not line.lstrip().startswith('#') else ''
 if k not in vals: out.append(line)
out += [k+'='+v for k,v in vals.items()]
open(f,'w').write('\\n'.join(out)+'\\n')
PY"; }

CLUSTER_TOUCHED=0
BM_SECONDS=${BM_SECONDS:-600}
REMOVE_AFTER_SECONDS=${REMOVE_AFTER_SECONDS:-300}
REMOVE_WAIT_SECONDS=${REMOVE_WAIT_SECONDS:-300}
BM_SCHEMA_TIMEOUT=${BM_SCHEMA_TIMEOUT:-60}
BM_FINISH_GRACE=${BM_FINISH_GRACE:-60}
SYNC_LAG_WAIT_SECONDS=${SYNC_LAG_WAIT_SECONDS:-300}
declare -A BENCH_PIDS=() BENCH_RC=()
mapfile -t HOSTS < <(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u)
fail(){ fail_flag=$((fail_flag + 1)); log "FAIL $*"; }

preflight() {
  local h
  command -v curl >/dev/null && command -v python3 >/dev/null || { fail 'syncLag check requires curl and python3'; return 1; }
  [[ "$SYNC_LAG_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { fail 'SYNC_LAG_WAIT_SECONDS must be a positive integer'; return 1; }
  [[ ${#CN[@]} -eq 3 && ${#DN[@]} -eq 3 ]] || { fail 'requires 3 CN and 3 DN'; return 1; }
  [[ "$DB_DIR" == /data/iotdb/* && "$DB" =~ ^[A-Za-z0-9_.-]+$ ]] || { fail 'invalid database path'; return 1; }
  [[ -r "$CLI_DIR/sbin/start-cli.sh" && -r "$BM/benchmark.sh" && -r "$BM_TEMPLATE/config.properties" ]] || { fail 'missing CLI or benchmark'; return 1; }
  for h in "${HOSTS[@]}"; do
    sshx "$h" "test -r '$DB_DIR/sbin/start-confignode.sh' && test -r '$DB_DIR/sbin/start-datanode.sh' && test -d '$DB_DIR/conf_orig' && test -s '$PARENT/license_2026/license' && test -s '$PARENT/license_2026/.env'" || {
      fail "preflight failed on $h: installation or license source missing"; return 1;
    }
  done
}

stop() {
  local h
  for h in "${HOSTS[@]}"; do
    sshx "$h" "timeout 60 bash '$DB_DIR/sbin/stop-datanode.sh' -f || true; timeout 60 bash '$DB_DIR/sbin/stop-confignode.sh' -f || true" >>"$OUT.stop" 2>&1 || {
      fail "cluster stop failed on $h; see $OUT.stop"; return 1;
    }
  done
}

reset() {
  local h
  for h in "${HOSTS[@]}"; do
    sshx "$h" "set -e; test -d '$DB_DIR/conf_orig'; rm -rf '$DB_DIR/data' '$DB_DIR/logs' '$DB_DIR/conf'; cp -a '$DB_DIR/conf_orig' '$DB_DIR/conf'; mkdir -p '$DB_DIR/logs'" || return 1
  done
}

cluster_ready() {
  awk -F'|' '
    /^\|/ {for(i=2;i<=NF;i++)gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i)}
    $2~/^[0-9]+$/ && ($3=="ConfigNode" || $3=="DataNode") {
      rows++; if($3=="ConfigNode")cn++; else dn++;
      if($4!="Running" || $9!="ACTIVATED")bad++
    }
    END {exit !(rows==6 && cn==3 && dn==3 && bad==0)}'
}

start() {
  local output deadline=$((SECONDS + 300)) helper="$BASE/prepare_env/start_cluster_v20.sh"
  [[ -r "$helper" ]] || { fail "missing cluster helper: $helper"; return 1; }
  log "starting cluster with $helper 1 6 (includes license/.env provisioning)"
  timeout 300 bash -x "$helper" 1 6 >>"$OUT.start_cluster" 2>&1 || {
    fail "start_cluster_v20.sh failed; see $OUT.start_cluster"
    return 1
  }
  while (( SECONDS < deadline )); do
    output=$(cli 'show cluster;' 2>&1 || true)
    printf '%s\n' "$output" >"$OUT.cluster.last"
    if printf '%s\n' "$output" | cluster_ready; then
      printf '%s\n' "$output" >>"$OUT"
      log '3C3D ready: all nodes Running and ACTIVATED; schema/data replication=3; data consensus=IoTConsensusV2'
      return 0
    fi
    sleep 2
  done
  fail "cluster not Running + ACTIVATED within 300s; see $OUT.cluster.last"
  for h in "${HOSTS[@]}"; do
    sshx "$h" "tail -60 '$DB_DIR/start_cn_${RUN_ID}.log' '$DB_DIR/start_dn_${RUN_ID}.log'" >>"$OUT" 2>&1 || true
  done
  return 1
}

prepare_bench() {
  local d=$1 dir
  dir="$BASE/benchmark/remove_cn_iotv2_${RUN_ID}_${d}"
  mkdir -p "$dir"
  cp -a "$BM_TEMPLATE/." "$dir/"
  python3 - "$dir/config.properties" "$d" "$Q" "$PW" "$RUN_ID" "$BM_SECONDS" <<'BM_PY'
from pathlib import Path
import os, sys
p,d,host,pw,run,seconds=sys.argv[1:]
values={'HOST':host,'PORT':'6667','USERNAME':'root','PASSWORD':pw,
        'TEST_MAX_TIME':str(int(seconds)*1000),'LOOP':'1000000000',
        'IoTDB_DIALECT_MODE':d,'DB_NAME':'remove_cn_iotv2_'+run+'_'+d,
        'DB_SWITCH':'IoTDB-200-SESSION_BY_TABLET',
        'OPERATION_PROPORTION':'1:1:0:0:0:0:0:0:0:0:0:0:0',
        'CREATE_SCHEMA':'true','INTERVAL_BETWEEN_WRITE_BATCH':'200',
        'INSERT_DATATYPE_PROPORTION':'0:1:1:1:1:1:0:0:0:0:0' if d=='tree' else '0:100:100:100:100:100:0:0:0:0:0'}
if d=='tree': values.update(DEVICE_NUMBER='1000',SENSOR_NUMBER='100')
path=Path(p); lines=[]
for line in path.read_text().splitlines():
    key=line.split('=',1)[0].strip()
    if not line.lstrip().startswith('#') and key in values: continue
    lines.append(line)
lines.extend(k+'='+v for k,v in values.items())
path.write_text('\n'.join(lines)+'\n')
BM_PY
}

start_bench() {
  local d=$1 dir hard_timeout=$((BM_SCHEMA_TIMEOUT + BM_SECONDS + BM_FINISH_GRACE))
  dir="$BASE/benchmark/remove_cn_iotv2_${RUN_ID}_${d}"
  # The whole child redirects its descriptors; no command substitution owns it.
  ( cd "$BM"; exec nohup timeout --signal=TERM --kill-after=10 "$hard_timeout" bash ./benchmark.sh -cf "$dir" ) >"$OUT.$d" 2>&1 </dev/null 9>&- &
  BENCH_PIDS[$d]=$!
  log "benchmark[$d] started pid=${BENCH_PIDS[$d]} config=$dir hard_timeout=${hard_timeout}s"
}

bench_alive(){ kill -0 "${BENCH_PIDS[$1]}" 2>/dev/null; }

wait_bench_ready() {
  local deadline=$((SECONDS + BM_SCHEMA_TIMEOUT)) d ready
  while (( SECONDS < deadline )); do
    ready=0
    for d in tree table; do
      if ! bench_alive "$d"; then fail "benchmark[$d] exited during initialization; see $OUT.$d"; return 1; fi
      if grep -qE 'Schema write operations are not allowed|Registering schema failed!' "$OUT.$d"; then
        fail "benchmark[$d] schema registration failed; see $OUT.$d"; return 1
      fi
      # The benchmark prints this success marker before the workload starts.
      # "workload is done" is a completion marker and would deadlock readiness.
      if grep -qE 'Registering schema successful!|Start Generating WorkLoad|The test is in progress' "$OUT.$d"; then ready=$((ready+1)); fi
    done
    if (( ready == 2 )); then log 'tree/table workloads are running concurrently'; return 0; fi
    sleep 1
  done
  fail "benchmark initialization exceeded ${BM_SCHEMA_TIMEOUT}s"
  return 1
}

check_bench_alive() {
  local d
  for d in tree table; do
    if ! bench_alive "$d"; then fail "benchmark[$d] exited before remove; see $OUT.$d"; return 1; fi
  done
}

stop_bench() {
  local d pid deadline=$((SECONDS+15)) alive
  for d in "${!BENCH_PIDS[@]}"; do
    pid=${BENCH_PIDS[$d]}
    [[ -n ${BENCH_RC[$d]:-} ]] || kill -TERM "$pid" 2>/dev/null || true
  done
  while (( SECONDS < deadline )); do
    alive=0
    for d in "${!BENCH_PIDS[@]}"; do
      if [[ -z ${BENCH_RC[$d]:-} ]] && bench_alive "$d"; then alive=1; fi
    done
    (( alive == 0 )) && break
    sleep 1
  done
  for d in "${!BENCH_PIDS[@]}"; do
    [[ -n ${BENCH_RC[$d]:-} ]] && continue
    pid=${BENCH_PIDS[$d]}
    if bench_alive "$d"; then kill -KILL -- "-$pid" 2>/dev/null || true; fi
    BENCH_RC[$d]=0
    wait "$pid" || BENCH_RC[$d]=$?
  done
}

wait_bench_complete() {
  local d rc deadline=$((WORKLOAD_START + BM_SECONDS + BM_FINISH_GRACE)) alive
  while (( SECONDS < deadline )); do
    alive=0
    for d in tree table; do if bench_alive "$d"; then alive=1; fi; done
    (( alive == 0 )) && break
    sleep 2
  done
  for d in tree table; do
    if bench_alive "$d"; then fail "benchmark[$d] exceeded test duration plus finish grace"; return 1; fi
    rc=0; wait "${BENCH_PIDS[$d]}" || rc=$?
    BENCH_RC[$d]=$rc
    if (( rc != 0 )); then fail "benchmark[$d] exit status=$rc"; fi
    if ! python3 - "$OUT.$d" "$BM_SECONDS" <<'RESULT_BM'
from pathlib import Path
import re,sys
lines=Path(sys.argv[1]).read_text(errors='replace').splitlines()
times=[float(m[1]) for l in lines if (m:=re.search(r'Test elapsed time[^:]*:\s*(\d+(?:\.\d+)?)',l))]
ops={}
for l in lines:
    m=re.match(r'^(INGESTION|PRECISE_POINT)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s',l)
    if m: ops[m[1]]=int(m[2])
print('benchmark validation: elapsed=%s successful_operations=%s' % (times[-1:] or 'missing',ops))
sys.exit(0 if times and times[-1]>=int(sys.argv[2])-1 and all(ops.get(k,0)>0 for k in ['INGESTION','PRECISE_POINT']) else 1)
RESULT_BM
    then fail "benchmark[$d] missing full-duration successful read/write summary"; fi
  done
}

# Query each DN directly so a missing/stale central Prometheus scrape cannot pass.
check_sync_lag_sample() {
  local node=$1 metrics=$2
  python3 - "$node" "$metrics" <<'SYNC_LAG_PY'
from decimal import Decimal, InvalidOperation
from pathlib import Path
import re
import sys

node, filename = sys.argv[1:]
samples = 0
nonzero = 0
invalid = 0
with Path(filename).open(encoding='utf-8', errors='replace') as stream:
    for line in stream:
        match = re.fullmatch(r'iot_consensus_v2\{(.*)\}(.*)', line.strip())
        if not match:
            continue
        labels = dict(re.findall(r'(\w+)="((?:[^"\\]|\\.)*)"', match[1]))
        if labels.get('name') != 'IoTConsensusV2ServerImpl' or labels.get('type') != 'syncLag':
            continue
        samples += 1
        print('SAMPLE node=%s %s' % (node, line.strip()))
        value_match = re.fullmatch(r'\s+(\S+)(?:\s+\d+)?\s*', match[2])
        if not value_match:
            invalid += 1
            continue
        try:
            value = Decimal(value_match[1])
            if not value.is_finite() or value < 0:
                invalid += 1
            elif value != 0:
                nonzero += 1
        except InvalidOperation:
            invalid += 1
print('SYNC_LAG_SAMPLE node=%s series=%d nonzero=%d invalid=%d' %
      (node, samples, nonzero, invalid))
sys.exit(0 if samples > 0 and nonzero == 0 and invalid == 0 else 1)
SYNC_LAG_PY
}

wait_for_sync_lag_zero() {
  local d node output remaining request_timeout delay
  local stable=0 zero_nodes begin=$SECONDS deadline metrics_dir
  # No producer may still be writing when the convergence window begins.
  for d in tree table; do
    if bench_alive "$d"; then
      fail "syncLag check requires benchmark[$d] to have stopped"
      return 1
    fi
  done
  log 'FLUSH before IoTConsensusV2 syncLag check (all tree/table databases)'
  if ! output=$(cli 'flush;' 60 2>&1); then
    printf '%s\n' "$output" >>"$OUT.sync_lag"
    fail "flush before syncLag check failed; see $OUT.sync_lag"
    return 1
  fi
  printf '%s\n' "$output" >>"$OUT.sync_lag"
  if ! grep -qi 'executed successfully' <<<"$output"; then
    fail "flush before syncLag check did not report success; see $OUT.sync_lag"
    return 1
  fi

  begin=$SECONDS
  deadline=$((begin + SYNC_LAG_WAIT_SECONDS))
  metrics_dir="$OUT.sync_lag_metrics"
  mkdir -p "$metrics_dir"
  log "CHECK IoTConsensusV2 syncLag: all 3 DN must have nonempty metrics and all values=0 for 2 consecutive checks; timeout=${SYNC_LAG_WAIT_SECONDS}s"
  while (( SECONDS < deadline )); do
    zero_nodes=0
    printf '\nCHECK elapsed=%ss\n' "$((SECONDS-begin))" >>"$OUT.sync_lag"
    for node in "${DN[@]}"; do
      remaining=$((deadline-SECONDS))
      (( remaining > 0 )) || break
      request_timeout=$((remaining < 10 ? remaining : 10))
      if curl --noproxy '*' -fsS --connect-timeout 3 --max-time "$request_timeout" \
          "http://$node:9092/metrics" -o "$metrics_dir/$node.metrics" 2>>"$OUT.sync_lag"; then
        if check_sync_lag_sample "$node" "$metrics_dir/$node.metrics" >>"$OUT.sync_lag" 2>&1; then
          zero_nodes=$((zero_nodes+1))
        fi
      else
        printf 'METRICS_UNAVAILABLE node=%s\n' "$node" >>"$OUT.sync_lag"
      fi
    done
    if (( zero_nodes == 3 )); then stable=$((stable+1)); else stable=0; fi
    log "SYNC_LAG_CHECK zero_dn=$zero_nodes/3 stable=$stable/2 elapsed=$((SECONDS-begin))s evidence=$OUT.sync_lag"
    if (( stable >= 2 && SECONDS <= deadline )); then
      log "PASS IoTConsensusV2 syncLag=0 on all 3 DN; elapsed=$((SECONDS-begin))s"
      return 0
    fi
    remaining=$((deadline-SECONDS))
    (( remaining > 0 )) || break
    delay=$((remaining < 5 ? remaining : 5))
    sleep "$delay"
  done
  fail "IoTConsensusV2 syncLag did not reach stable zero on all 3 DN within ${SYNC_LAG_WAIT_SECONDS}s (nonzero/invalid/missing/unreachable metrics); see $OUT.sync_lag"
  return 1
}

parse_cn() {
  awk -F'|' '/^\|/ {for(i=2;i<=NF;i++)gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i)}
    $2~/^[0-9]+$/ && ($6=="Leader" || $6=="Follower") {print $2,$3,$6}'
}

remove_leader() {
  local output rows target leaders result deadline remaining cnrows removed=0
  check_bench_alive || return 1
  output=$(cli 'show confignodes;' 2>&1) || { fail 'cannot identify CN leader'; return 1; }
  printf '%s\n' "$output" >>"$OUT"
  rows=$(printf '%s\n' "$output" | parse_cn)
  target=$(printf '%s\n' "$rows" | awk '$3=="Leader" && $2=="Running" {print $1}')
  leaders=$(printf '%s\n' "$rows" | awk '$3=="Leader" {n++} END{print n+0}')
  [[ "$target" =~ ^[0-9]+$ && "$leaders" -eq 1 ]] || { fail 'no unique running CN leader; remove skipped'; return 1; }
  log "remove ConfigNode leader id=$target workload_elapsed=$((SECONDS-WORKLOAD_START))s"
  deadline=$((SECONDS + REMOVE_WAIT_SECONDS))
  if ! result=$(cli "remove confignode $target;" 2>&1); then fail "remove SQL failed: $result"; return 1; fi
  printf '%s\n' "$result" | tee -a "$OUT"
  if ! grep -qi 'executed successfully' <<<"$result"; then fail 'remove SQL did not report success'; return 1; fi
  while (( SECONDS < deadline )); do
    remaining=$((deadline-SECONDS))
    output=$(cli 'show confignodes;' "$remaining" 2>&1 || true)
    printf '%s\n' "$output" >"$OUT.remove.last"
    cnrows=$(printf '%s\n' "$output" | parse_cn)
    if printf '%s\n' "$cnrows" | awk -v id="$target" 'NF{n++; if($1==id || $2!="Running")bad++; if($3=="Leader")leader++} END{exit !(n==2 && bad==0 && leader==1)}'; then removed=1; break; fi
    sleep 2
  done
  if (( removed == 0 )); then fail "remove leader timed out within ${REMOVE_WAIT_SECONDS}s"; return 1; fi
  log "remove CN $target succeeded; two Running CN remain"
}

backup() {
  local h dest="$OUTDIR/logs_$RUN_ID"
  mkdir -p "$dest"
  for h in "${HOSTS[@]}"; do
    if timeout 180 ssh -n -o BatchMode=yes -o ConnectTimeout=15 "$USER@$h" "tar czf - -C '$DB_DIR' logs" >"$dest/$h.logs.tgz"; then
      log "logs backed up: $dest/$h.logs.tgz"
    else fail "log backup failed on $h"; fi
  done
}

# Scan only logs; this function never starts or stops cluster nodes.
scan_device_entry_spill() {
  local node=$1 role=$2 keyword=$3
  timeout "${SCAN_TIMEOUT_SECONDS:-300}" ssh -o BatchMode=yes -o ConnectTimeout=15 \
    "$USER@$node" "python3 - '$DB_DIR/logs' '$role' '$keyword'" <<'SPILL_PY'
import gzip
import pathlib
import sys

directory, role, keyword = sys.argv[1:]
root = pathlib.Path(directory)
try:
    candidates = sorted(p for p in root.iterdir() if p.is_file() and role in p.name)
    # all logs already contain WARN/ERROR; avoid counting the error copy twice.
    files = [p for p in candidates if 'all' in p.name]
    if not files:
        files = [p for p in candidates if 'error' in p.name]
    if not files:
        raise FileNotFoundError('No %s all/error logs in %s' % (role, root))
    total = 0
    for path in files:
        opener = gzip.open if path.suffix == '.gz' else open
        with opener(path, 'rt', encoding='utf-8', errors='replace') as stream:
            for number, line in enumerate(stream, 1):
                if keyword in line:
                    total += 1
                    print('MATCH\t%s:%d:%s' % (path.name, number, line.rstrip()))
    print('COUNT\t%d\tFILES\t%d' % (total, len(files)))
except Exception as exc:
    print('SCAN_ERROR\t%s: %s' % (type(exc).__name__, exc), file=sys.stderr)
    sys.exit(2)
SPILL_PY
}

LOG_CHECK_DONE=0
check_log() {
  [[ "$LOG_CHECK_DONE" -eq 0 ]] || return 0
  LOG_CHECK_DONE=1
  local keyword='Failed to clean DeviceEntry spill directory for query'
  local role node evidence count rc total=0 scan_errors=0
  local -a nodes
  local evidence_dir="$OUTDIR/spill_check_${RUN_ID}"
  mkdir -p "$evidence_dir"
  log "CHECK CN/DN logs: $keyword"
  for role in confignode datanode; do
    if [[ "$role" == confignode ]]; then nodes=("${CN[@]}"); else nodes=("${DN[@]}"); fi
    for node in "${nodes[@]}"; do
      evidence="$evidence_dir/${role}_${node}.txt"
      rc=0
      scan_device_entry_spill "$node" "$role" "$keyword" >"$evidence" 2>&1 || rc=$?
      count=$(awk -F'\t' '$1=="COUNT" {print $2}' "$evidence")
      if (( rc != 0 )) || [[ ! "$count" =~ ^[0-9]+$ ]]; then
        fail_flag=$((fail_flag + 1))
        scan_errors=$((scan_errors + 1))
        log "FAIL $role $node: $keyword scan failed (rc=$rc); evidence=$evidence"
        continue
      fi
      total=$((total + count))
      if (( count > 0 )); then
        fail_flag=$((fail_flag + 1))
        log "FAIL $role $node: $keyword count=$count; evidence=$evidence"
      else
        log "PASS $role $node: $keyword count=0"
      fi
    done
  done
  log "LOG_CHECK_SUMMARY: $keyword total=$total scan_errors=$scan_errors fail_flag=$fail_flag"
  return 0
}

# Persist one result for each full test run, including an unexpected shell exit.
RESULT_WRITTEN=0
write_result() {
  local script_rc=${1:-0}
  [[ "$RESULT_WRITTEN" -eq 0 ]] || return 0
  local csv_path=${result_csv:-${RESULT_CSV:-$(dirname "$OUTDIR")/test_result.csv}}
  local end_epoch=${RESULT_END_EPOCH:-$(date +%s)}
  if python3 - "$csv_path" "$RUN_ID" "$DB" "$(basename "$0")" \
      "$fail_flag" "$script_rc" "$START_EPOCH" "$end_epoch" "$OUT" "$OUTDIR" <<'RESULT_PY'
import csv
import datetime
import fcntl
import os
from pathlib import Path
import re
import sys

csv_name, run_id, db, case, failures, rc, start, end, log_name, outdir = sys.argv[1:]
failures, rc, start, end = map(int, (failures, rc, start, end))
result = 'PASS' if failures == 0 and rc == 0 else 'FAIL'
elapsed = max(0, end - start)
header = ['Time', 'testTimechoDB', 'testConsensus', 'testCaseName', 'testResult',
          'testElapsedTimeSeconds', 'warnNum', 'testOtherMessage',
          'maxBMTestTimeSec', 'sumBMTestTimeSec']
messages = ['run_id=' + run_id, 'exit_status=' + str(rc)]
log_path = Path(log_name)
if log_path.exists():
    with log_path.open(encoding='utf-8', errors='replace') as stream:
        for line in stream:
            match = re.match(r'^\[[^\]]+\] ((?:FAIL|WARN|ERROR)\b.*)', line)
            if match and match[1] not in messages:
                messages.append(match[1])
durations = []
for dialect in ('tree', 'table'):
    duration = None
    path = Path(log_name + '.' + dialect)
    if path.exists():
        with path.open(encoding='utf-8', errors='replace') as stream:
            for line in stream:
                match = re.search(r'Test elapsed time[^:]*:\s*(\d+(?:\.\d+)?)', line)
                if match:
                    duration = int(float(match[1]))
    if duration is None:
        messages.append('benchmark-' + dialect + '-elapsed-unavailable')
    durations.append(duration or 0)
message = '; '.join(messages).replace(',', ';').replace("'", '').replace('\r', ' ').replace('\n', ' ')
quoted = lambda value: "'" + str(value).replace("'", '') + "'"
timestamp = datetime.datetime.fromtimestamp(end).astimezone().isoformat(timespec='seconds')
row = [timestamp, quoted(db), quoted('IoTConsensusV2'), quoted(case), quoted(result),
       elapsed, failures, quoted(message), max(durations), sum(durations)]
path = Path(csv_name)
path.parent.mkdir(parents=True, exist_ok=True)
with path.open('a+', encoding='utf-8', newline='') as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    stream.seek(0)
    rows = list(csv.reader(stream))
    if rows and rows[0] != header:
        raise ValueError('CSV header differs from the expected 10-column testcase format: ' + str(path))
    existing = [r for r in rows[1:] if len(r) == 10 and r[3].strip("'") == case
                and ('run_id=' + run_id) in r[7].strip("'").split('; ')]
    if existing:
        if len(existing) != 1 or existing[0] != list(map(str, row)):
            raise ValueError('Conflicting existing CSV result for run_id=' + run_id)
        action = 'already recorded'
    else:
        stream.seek(0, os.SEEK_END)
        writer = csv.writer(stream, lineterminator='\n')
        if not rows:
            writer.writerow(header)
        writer.writerow(row)
        stream.flush()
        os.fsync(stream.fileno())
        action = 'appended'
summary = Path(outdir) / ('result_' + run_id + '.txt')
summary.parent.mkdir(parents=True, exist_ok=True)
temporary = summary.with_name(summary.name + '.tmp.' + str(os.getpid()))
temporary.write_text('run_id=%s\nresult=%s\nfail_flag=%s\nexit_status=%s\nelapsed_seconds=%s\n'
                     'v_warnMessage=%s\nmaxBMTestTimeSec=%s\nsumBMTestTimeSec=%s\n'
                     % (run_id, result, failures, rc, elapsed, message, max(durations), sum(durations)),
                     encoding='utf-8')
os.replace(temporary, summary)
print('CSV_RESULT %s: %s run_id=%s result=%s fail_flag=%s elapsed=%ss' %
      (action, path, run_id, result, failures, elapsed))
RESULT_PY
  then
    RESULT_WRITTEN=1
    log "result recorded: $csv_path (run_id=$RUN_ID)"
    return 0
  else
    log "ERROR failed to write result: $csv_path (run_id=$RUN_ID)"
    return 1
  fi
}


# Read-only recheck, with output separate from the original test run.
if [[ "${1:-}" == --check-logs-only ]]; then
  check_log
  log "LOG_CHECK_RESULT fail_flag=$fail_flag"
  exit "$fail_flag"
elif (( $# > 0 )); then
  log "Unknown argument: $1; supported: --check-logs-only"
  exit 2
fi

check_logs_on_exit() {
  local rc=$?
  trap - EXIT TERM INT
  set +e
  stop_bench
  if (( rc != 0 && fail_flag == 0 )); then fail "unexpected script exit status=$rc"; fi
  if (( CLUSTER_TOUCHED == 1 )); then
    check_log
    stop
    backup
  fi
  if (( fail_flag != 0 && rc == 0 )); then rc=1; fi
  if (( rc == 0 )); then log 'RESULT PASS IoTConsensusV2 remove cn leader succeeded and syncLag=0'; else log "RESULT FAIL fail_flag=$fail_flag exit_status=$rc"; fi
  if ! write_result "$rc"; then rc=1; fi
  exit "$rc"
}

exec 9>"$OUTDIR/.remove_cn.lock"
flock -n 9 || { log 'FAIL another RemoveCN testcase is already running'; exit 1; }
trap check_logs_on_exit EXIT
trap 'fail "test interrupted by signal"; exit 130' INT TERM

preflight
log 'stop, clean data/logs, reset conf, configure IoTConsensusV2 3C3D3 and start with prepare_env/start_cluster_v20.sh'
CLUSTER_TOUCHED=1
stop
reset
for h in "${HOSTS[@]}"; do set_conf "$h"; done
start
prepare_bench tree
prepare_bench table
start_bench tree
start_bench table
wait_bench_ready
WORKLOAD_START=$SECONDS
REMOVE_AT=$((WORKLOAD_START + REMOVE_AFTER_SECONDS))
while (( SECONDS < REMOVE_AT )); do check_bench_alive; sleep 1; done
remove_leader || true
wait_bench_complete || stop_bench
wait_for_sync_lag_zero || true
cli 'show cluster;' >>"$OUT" 2>&1 || fail 'final show cluster failed'
exit "$fail_flag"
