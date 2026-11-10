#!/bin/bash
# run_case.sh <CASE_ID> —— 单用例：重置集群 → setup → 注入故障 → 执行 DDL → 恢复 → 一致性校验 → 判定
set -u
. "$(dirname "$0")/../tools/lib.sh"

CASE=$1
CDIR=$SKILL/cases/$CASE
[ -d "$CDIR" ] || { echo "no case $CASE"; exit 2; }
. "$CDIR/spec.env"

A=$ART/$CASE
rm -rf "$A"; mkdir -p "$A"
T0=$(date +%s)
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$A/round.log"; }
CTL=/data2/iotdb/rc10_matrix/scripts/cluster_ctl.sh

# 任何退出路径都先恢复故障，避免把分区/宕机状态留给下一轮
heal_fault() {
  case "${FAULT:-none}" in
    dn_partition)   bash "$SKILL/tools/fault.sh" heal dn_partition "${TARGET:-21}" >> "${A}/fault.txt" 2>&1 || true ;;
    dn_kill)        bash "$SKILL/tools/fault.sh" heal dn_kill "${TARGET:-21}" >> "${A}/fault.txt" 2>&1 || true ;;
    dr_both_down)   bash "$SKILL/tools/fault.sh" heal dr_both_down "${TARGET:-21}" >> "${A}/fault.txt" 2>&1 || true ;;
    cn_leader_kill) bash "$SKILL/tools/fault.sh" heal cn_leader_kill "" >> "${A}/fault.txt" 2>&1 || true ;;
  esac
}

record() { # $1 verdict  $2 note
  heal_fault
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$CASE" "$GROUP" "$1" "$(( $(date +%s) - T0 ))" "$2" "${TARGET:-auto}" >> "$ART/results.tsv"
  log "ROUND END $1 duration=$(( $(date +%s) - T0 ))s $2 target=${TARGET:-auto}"
  exit 0
}

trap 'heal_fault' EXIT

log "ROUND START case=$CASE group=$GROUP op=$OP fault=$FAULT expect=$EXPECT"

# ---------- 1) 统一 IoTConsensus 并重置集群 ----------
for n in $DNS; do
  ssh -n -o BatchMode=yes root@"$(ip_of "$n")" "sed -i '/^data_region_consensus_protocol_class=/d' $NEW/conf/iotdb-system.properties; echo 'data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.IoTConsensus' >> $NEW/conf/iotdb-system.properties" 2>/dev/null
done
# 环境自清理：杀所有版本残留进程 + 清掉本 skill 的 iptables 规则（防止上一轮污染）
for n in $DNS $CNS; do
  ssh -n -o BatchMode=yes root@"$(ip_of "$n")" "pkill -9 -f 'com[.]timecho[.]iotdb' 2>/dev/null
    for cn in 16 17 18; do
      while iptables -D OUTPUT -d 172.16.2.\$cn -p tcp --dport 10710 -j DROP 2>/dev/null; do :; done
      while iptables -D INPUT -s 172.16.2.\$cn -p tcp --sport 10710 -j DROP 2>/dev/null; do :; done
    done" 2>/dev/null
done
sleep 5
bash "$CTL" reset > "$A/reset.out" 2>&1
wait_cluster 8 240 || record FAIL_RESET "cluster not ready"

# ---------- 2) setup ----------
qdn 19 "$(sed -n '2,$p' "$CDIR/setup.sql")" > "$A/setup.out" 2>&1
sleep 2

# ---------- 3) 解析故障目标 ----------
TARGET=""
case "$FAULT_TARGET" in
  auto_meta_replica|auto) TARGET=$(schema_replica_dns "$DB" | head -n1) ;;
  auto_dr_replicas)       TARGET=$(data_replica_dns "$DB" | tr '\n' ' ' | sed 's/ $//') ;;
  *)                      TARGET=$FAULT_TARGET ;;
esac
[ -z "${TARGET:-}" ] && TARGET=21
echo "FAULT=$FAULT TARGET=$TARGET" > "$A/fault.txt"

SQL_DN=19
[ "$EXPECT" = "fail_expected" ] && [ "$SQL_TARGET" = "partitioned_dn" ] && SQL_DN=$TARGET

# ---------- 4) 注故障 ----------
case "$FAULT" in
  dn_kill|dn_partition|dr_both_down)
    bash "$SKILL/tools/fault.sh" apply "$FAULT" "$TARGET" >> "$A/fault.txt" 2>&1
    [ "$FAULT" = "dn_partition" ] && sleep 25
    [ "$FAULT" = "dn_kill" ] && sleep 8 ;;
esac

# ---------- 5) 执行 DDL ----------
if [ "$FAULT" = "cn_leader_kill" ]; then
  ( sleep 2; bash "$SKILL/tools/fault.sh" apply cn_leader_kill >> "$A/fault.txt" 2>&1 ) &
fi
if [ "$OP" = "add_column_twice" ]; then
  qdn "$SQL_DN" "$(sed -n '2,$p' "$CDIR/sql.sql" | head -n1)" > "$A/sql.out" 2>&1 &
  p1=$!
  qdn "$SQL_DN" "$(sed -n '2,$p' "$CDIR/sql.sql" | tail -n1)" > "$A/sql2.out" 2>&1 &
  p2=$!
  wait $p1 $p2
  cat "$A/sql2.out" >> "$A/sql.out"
else
  qdn "$SQL_DN" "$(sed -n '2,$p' "$CDIR/sql.sql")" > "$A/sql.out" 2>&1
fi

OK_CNT=$(grep -c 'executed successfully' "$A/sql.out" 2>/dev/null || true)
ERR_LINE=$(grep -oiE '(IoTDBSQLException|Exception)[^\n]{0,140}' "$A/sql.out" | head -n1)
SQL_FAIL=0
if [ "${OK_CNT:-0}" -eq 0 ] || [ -n "$ERR_LINE" ]; then SQL_FAIL=1; fi
echo "SQL_OK_STMT=$OK_CNT SQL_FAIL=$SQL_FAIL ERR=${ERR_LINE:-none}" >> "$A/fault.txt"

if [ "$EXPECT" = "success" ] && [ "$SQL_FAIL" -eq 1 ]; then
  record FAIL_SQL "sql_err=${ERR_LINE:-unknown}"
fi
if [ "$EXPECT" = "fail_expected" ] && [ "$SQL_FAIL" -eq 0 ]; then
  record FAIL_NO_ERROR "expected failure but DDL succeeded"
fi
if [ "$EXPECT" = "fail_expected" ] && [ "$SQL_TARGET" = "partitioned_dn" ]; then
  if ! grep -qiE '隔离|isolat|无法连接|cannot connect|Failed to connect|config node|lease|fence|not available' "$A/sql.out"; then
    record FAIL_ERROR_KIND "err not isolation-like: ${ERR_LINE:-unknown}"
  fi
fi

# ---------- 6) 恢复故障 ----------
case "$FAULT" in
  dn_partition)   bash "$SKILL/tools/fault.sh" heal dn_partition "$TARGET" >> "$A/fault.txt" 2>&1 ;;
  dn_kill)        bash "$SKILL/tools/fault.sh" heal dn_kill "$TARGET" >> "$A/fault.txt" 2>&1 ;;
  dr_both_down)   bash "$SKILL/tools/fault.sh" heal dr_both_down "$TARGET" >> "$A/fault.txt" 2>&1 ;;
  cn_leader_kill) bash "$SKILL/tools/fault.sh" heal cn_leader_kill "" >> "$A/fault.txt" 2>&1 ;;
  full_restart)
    bash "$CTL" stop >> "$A/reset.out" 2>&1 || true
    bash "$CTL" start >> "$A/reset.out" 2>&1 || true ;;
esac
if ! wait_cluster 8 300; then log "WARN cluster not 8/8 after heal ($(cluster_running_cnt)/8)"; fi
sleep 10

# ---------- 7) 一致性校验 ----------
bash "$SKILL/tools/check_meta.sh" "$A" "$DB" "$EXPECT_OBJECT" "$EXPECT_VALUE" >> "$A/verify.log" 2>&1
bash "$SKILL/tools/check_data.sh" "$A" "$DB" >> "$A/verify.log" 2>&1
bash "$SKILL/tools/log_scan.sh" "$A" "$DNS $CNS" >> "$A/verify.log" 2>&1

META=$(grep -oE 'META_CONSISTENT=[A-Z]+' "$A/meta-consistency.txt" 2>/dev/null | cut -d= -f2)
EXOK=$(grep -oE 'EXPECT_OK=[A-Z]+' "$A/meta-consistency.txt" 2>/dev/null | cut -d= -f2)
DATA=$(grep -oE 'DATA_CONSISTENT=[A-Z]+' "$A/data-consistency.txt" 2>/dev/null | cut -d= -f2)
LOGS=$(grep -oE 'LOG_SCAN=[A-Z]+' "$A/log-scan.txt" 2>/dev/null | cut -d= -f2)
NOTE="meta=$META,data=$DATA,exp=$EXOK,log=$LOGS"

VERDICT=PASS
[ "$META" != "YES" ] && VERDICT=FAIL_META
[ "$DATA" = "NO" ] && VERDICT=FAIL_DATA
[ "$EXPECT" = "success" ] && [ "$EXOK" = "NO" ] && VERDICT=FAIL_EXPECT
[ "$LOGS" = "SUSPECT" ] && [ "$VERDICT" = "PASS" ] && VERDICT=FAIL_LOG

record "$VERDICT" "$NOTE"
