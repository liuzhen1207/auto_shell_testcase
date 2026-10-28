#!/usr/bin/env bash
# TDB-344 LOAD TSFILE replica-set order regression.
# Run on qa-lz-80 under /data/iotdb/autotest.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONF="$ROOT/conf/test.conf"
NODE_CONF="$ROOT/conf"
BENCH="$ROOT/benchmark/bm_20260812_e158c2c_jdk17"
DATA="$ROOT/tdb344_data"
RESULTS="$SCRIPT_DIR/tdb344_results"

cfg() { awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$CONF"; }
OS_USER=$(cfg os_user_name)
DB_USER=$(cfg db_user_name)
PASSWORD=$(cfg root_pw)
DB_PARENT=$(cfg v_db_parent_dir)
CLIENT_PARENT=$(cfg v_shell_client_db_parent_dir)
TESTDB=$(cfg v_testdb)
COMMIT=$(cfg v_commit)
CLUSTER=$(cfg CLUSTER_NAME)
mapfile -t CN < <(awk 'NF && $1 !~ /^#/ {print $1}' "$NODE_CONF/confignode_3c.txt")
mapfile -t DN < <(awk 'NF && $1 !~ /^#/ {print $1}' "$NODE_CONF/datanode_3d.txt")
[[ ${#CN[@]} -eq 3 && ${#DN[@]} -eq 3 ]] || { echo 'need 3 CN and 3 DN' >&2; exit 2; }
QUERY=${DN[0]}
RUN_ID=$(date +%Y%m%d_%H%M%S)
OUT="$RESULTS/TDB344_${COMMIT}_${RUN_ID}.out"
LOGDIR="$RESULTS/TDB344_${COMMIT}_${RUN_ID}_logs"
BENCHRUN="$ROOT/benchmark/tdb344_${RUN_ID}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$OUT"; }
die() { log "FAIL: $*"; exit 1; }
sshx() {
  local host="$1" arg command=""
  shift
  for arg in "$@"; do printf -v arg '%q' "$arg"; command+="$arg "; done
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$OS_USER@$host" "$command"
}

dbdir() {
  sshx "$1" bash -s -- "$DB_PARENT" "$CLIENT_PARENT" "$TESTDB" <<'REMOTE'
set -e
for d in "$1/$3" "$2/$3" "$1/testdb/$3"; do
  if test -x "$d/sbin/start-datanode.sh" || test -x "$d/sbin/start-confignode.sh"; then echo "$d"; exit 0; fi
done
exit 1
REMOTE
}

setprop() {
  sshx "$1" bash -s -- "$2" "$1" "$QUERY" "$CLUSTER" <<'REMOTE'
set -e
d="$1"; ip="$2"; seed="$3"; cluster="$4"; f="$d/conf/iotdb-system.properties"
setp() { if grep -qE "^[[:space:]]*$1=" "$f"; then sed -i -E "s|^[[:space:]]*$1=.*|$1=$2|" "$f"; else echo "$1=$2" >> "$f"; fi; }
setp cluster_name "$cluster"; setp cn_seed_config_node "$seed:10710"; setp dn_seed_config_node "$seed:10710"
setp cn_internal_address "$ip"; setp cn_internal_port 10710; setp cn_consensus_port 10720
setp dn_rpc_address "$ip"; setp dn_rpc_port 6667; setp dn_internal_address "$ip"; setp dn_internal_port 10730
setp dn_mpp_data_exchange_port 10740; setp dn_schema_region_consensus_port 10750; setp dn_data_region_consensus_port 10760
setp schema_replication_factor 3; setp data_replication_factor 3
setp data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus
REMOTE
}

reset_cluster() {
  log "reset data/logs/conf for $TESTDB, version=$COMMIT"
  local h d
  for h in "${CN[@]}"; do
    d=$(dbdir "$h")
    sshx "$h" bash -s -- "$d" <<'REMOTE'
set -e
rm -rf "$1/data" "$1/logs" "$1/conf"; cp -a "$1/conf_orig" "$1/conf"; mkdir -p "$1/logs"
REMOTE
    setprop "$h" "$d"
  done
}

stop_cluster() {
  local h d
  for h in "${DN[@]}"; do
    d=$(dbdir "$h" 2>/dev/null || true); test -n "$d" || continue
    sshx "$h" bash -s -- "$d" <<'REMOTE' || true
"$1/sbin/stop-datanode.sh" -f >/dev/null 2>&1 || true; "$1/sbin/stop-confignode.sh" -f >/dev/null 2>&1 || true
pkill -f 'com\.timecho\.iotdb\.DataNode' >/dev/null 2>&1 || true; pkill -f 'com\.timecho\.iotdb\.service\.ConfigNode' >/dev/null 2>&1 || true
REMOTE
  done
  sleep 3
}

cli() {
  local sql="$1" user="$2" pass="$3" d
  d=$(dbdir "$QUERY")
  sshx "$QUERY" bash -s -- "$d" "$QUERY" "$user" "$pass" "$sql" <<'REMOTE'
"$1/sbin/start-cli.sh" -u "$3" -pw "$4" -h "$2" -e "$5"
REMOTE
}

start_cluster() {
  local h d
  for h in "${CN[@]}"; do
    d=$(dbdir "$h")
    sshx "$h" bash -s -- "$d" "$RUN_ID" <<'REMOTE'
set -e
nohup "$1/sbin/start-confignode.sh" -d > "$1/start_cn_$2.log" 2>&1 < /dev/null &
REMOTE
    sleep 2
  done
  for h in "${DN[@]}"; do
    d=$(dbdir "$h")
    sshx "$h" bash -s -- "$d" "$RUN_ID" <<'REMOTE'
set -e
nohup "$1/sbin/start-datanode.sh" -d > "$1/start_dn_$2.log" 2>&1 < /dev/null &
REMOTE
    sleep 2
  done
  local i n status; for i in $(seq 1 300); do
    status=$(cli 'show cluster;' root "$PASSWORD" 2>&1 || true)
    [[ -z "$status" || "$status" == *"Authentication failed"* ]] && status=$(cli 'show cluster;' root root 2>&1 || true)
    n=$(printf '%s\n' "$status" | grep -E 'ConfigNode|DataNode' | grep -E 'Running|ReadOnly' | wc -l)
    [[ "$n" -eq 6 ]] && { log 'cluster ready 6/6'; return 0; }
    sleep 1
  done
  printf '%s\n' "$status" >> "$OUT"
  return 1
}

bench_set() {
  local f="$1" k="$2" v="$3" tmp
  tmp="$f.tmp"
  awk -v key="$k" -v value="$v" '
    BEGIN { replaced = 0 }
    {
      if ($0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=") {
        if (!replaced) {
          print key "=" value
          replaced = 1
        }
        next
      }
      print
    }
    END {
      if (!replaced) print key "=" value
    }
  ' "$f" > "$tmp"
  mv "$tmp" "$f"
}
bench_conf() {
  local dialect="$1" dir="$2" f
  mkdir -p "$dir"; cp -a "$BENCH/conf/." "$dir/"; f="$dir/config.properties"
  bench_set "$f" DB_SWITCH IoTDB-200-SESSION_BY_TABLET; bench_set "$f" IoTDB_DIALECT_MODE "$dialect"
  bench_set "$f" HOST "$QUERY"; bench_set "$f" PORT 6667; bench_set "$f" USERNAME "$DB_USER"; bench_set "$f" PASSWORD "$PASSWORD"
  bench_set "$f" DB_NAME "tdb344_$dialect"; bench_set "$f" IS_DELETE_DATA false; bench_set "$f" LOOP 20; bench_set "$f" BENCHMARK_WORK_MODE testWithDefaultPath
  bench_set "$f" TEST_MAX_TIME 0; bench_set "$f" IS_RECORD_CURRENT_REALLY_TIME false; bench_set "$f" DEVICE_NUMBER 10; bench_set "$f" SENSOR_NUMBER 4
  bench_set "$f" SCHEMA_CLIENT_NUMBER 2; bench_set "$f" DATA_CLIENT_NUMBER 2; bench_set "$f" GROUP_NUMBER 1; bench_set "$f" OPERATION_PROPORTION 1:0:0:0:0:0:0:0:0:0:0:0:0
  bench_set "$f" BATCH_SIZE_PER_WRITE 100; bench_set "$f" DEVICE_NUM_PER_WRITE 1; bench_set "$f" CREATE_SCHEMA true; bench_set "$f" START_TIME 2026-01-01T00:00:00+08:00
  if [[ "$dialect" == table ]]; then
    bench_set "$f" TABLE_TIME_COLUMN time
    bench_set "$f" IoTDB_TABLE_WRITABLE_VIEW false
    bench_set "$f" IoTDB_TABLE_NAME_PREFIX table_
    bench_set "$f" IoTDB_TABLE_NUMBER 1
  fi
}

prepare_data() {
  mkdir -p "$RESULTS"; rm -rf "$DATA" "$BENCHRUN"; mkdir -p "$DATA" "$BENCHRUN"; : > "$OUT"; log "prepare-data using test.conf v_testdb=$TESTDB v_commit=$COMMIT"
  stop_cluster || true; reset_cluster; start_cluster || die 'startup failed'
  local dialect dir d
  for dialect in tree table; do dir="$BENCHRUN/$dialect"; bench_conf "$dialect" "$dir"; log "benchmark $dialect"; (cd "$BENCH" && ./bin/startup.sh -cf "$dir") >> "$OUT" 2>&1 || die "benchmark $dialect failed"; done
  cli 'flush;' "$DB_USER" "$PASSWORD" >> "$OUT" 2>&1 || die 'flush failed'
  stop_cluster || true
  d=$(dbdir "$QUERY")
  mkdir -p "$DATA/tree" "$DATA/table"
  scp -q -r "$OS_USER@$QUERY:$d/data/datanode/data/sequence/root.tdb344_tree.g_0/." "$DATA/tree/" || die 'tree tsfile collection failed'
  scp -q -r "$OS_USER@$QUERY:$d/data/datanode/data/sequence/tdb344_table_g_0/." "$DATA/table/" || die 'table tsfile collection failed'
  find "$DATA" -type f -name '*.tsfile' -print | tee -a "$OUT"; test -n "$(find "$DATA" -type f -name '*.tsfile' -print -quit)" || die 'no TsFile exported'; stop_cluster; copy_data; log "prepare-data complete: $DATA"
}

copy_data() {
  local h
  for h in "${DN[@]}"; do
    sshx "$h" bash -s -- "$DATA" <<'REMOTE'
set -e
rm -rf "$1"
mkdir -p "$1"
REMOTE
    scp -q -r "$DATA/." "$OS_USER@$h:$DATA/"
  done
}
backup_logs() {
  local h d
  mkdir -p "$LOGDIR"
  for h in "${CN[@]}" "${DN[@]}"; do
    d=$(dbdir "$h")
    sshx "$h" bash -s -- "$d" <<'REMOTE' > "$LOGDIR/$h.logs.tgz" || true
set -e
tar czf - -C "$1" logs
REMOTE
  done
}

run_test() {
  mkdir -p "$RESULTS"; : > "$OUT"; log "run using test.conf v_testdb=$TESTDB v_commit=$COMMIT"; test -d "$DATA" || die 'prepared data missing'; stop_cluster || true; reset_cluster; start_cluster || die 'startup failed'
  local file fails=0 count=0 output
  while IFS= read -r -d '' file; do
    count=$((count+1)); output="$OUT.$(basename "$file")"; log "LOAD TSFILE $file"
    if [[ "$file" == "$DATA/table/"* ]]; then
      load_sql="LOAD '$file' WITH ('database'='tdb344_table_g_0');"
    else
      load_sql="LOAD '$file';"
    fi
    cli "$load_sql" "$DB_USER" "$PASSWORD" > "$output" 2>&1 || fails=$((fails+1)); cat "$output" >> "$OUT"
  done < <(find "$DATA" -type f -name '*.tsfile' -print0 | sort -z)
  test "$count" -gt 0 || die 'no TsFile found'; cli 'show regions;' "$DB_USER" "$PASSWORD" >> "$OUT" 2>&1 || true; cli 'show cluster;' "$DB_USER" "$PASSWORD" >> "$OUT" 2>&1 || true; stop_cluster || true; backup_logs
  local errors; errors=$(grep -RInE 'RegionReplicaSetChangedException|LOAD_FILE_ERROR|Loading file|Failed to load' "$OUT" "$LOGDIR" 2>/dev/null || true); if [[ "$fails" -eq 0 && -z "$errors" ]]; then log "RESULT PASS files=$count failures=$fails"; else log "RESULT FAIL files=$count failures=$fails errors=${errors:-none}"; return 1; fi
}

case "${1:-run}" in
  prepare-data) prepare_data;;
  run) run_test;;
  -h|--help) echo "$0 [prepare-data|run]";;
  *) echo "$0 [prepare-data|run]" >&2; exit 2;;
esac
