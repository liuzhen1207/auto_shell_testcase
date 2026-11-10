#!/bin/bash
# 日志回归门禁：标准负载 + DDL + 停/起一个 DN，然后扫描 CN/DN 日志中的已知缺陷特征。
# 前置：集群已启动；控制机可 ssh 节点。
set -u
CASE_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
cd "$CASE_DIR" || exit 1
TESTDB="${TESTDB:-v20131rc1_1030_ab6d3de}"
DB_ROOT="${DB_ROOT:-/data1/iotdb}"
CLI_ROOT="${CLI_ROOT:-/data2/iotdb}"
T="${TESTCASE_DIR:-/data2/auto_test/cluster_shell_3c5d_no2/tc2026_releasenote_testcase}"
BENCH="${BENCH_DIR:-$T/benchmark/bm_20260625_1f2d2e3_jdk17}"
SEED="${SEED:-172.16.2.11}"
DN_LIST="${DN_LIST:-172.16.2.11 172.16.2.12 172.16.2.13 172.16.2.14 172.16.2.15}"
CN_LIST="${CN_LIST:-172.16.2.8 172.16.2.9 172.16.2.10}"
CLI="$CLI_ROOT/$TESTDB/sbin/start-cli.sh"

TS=$(date '+%Y-%m-%d %H:%M:%S')
TAG=$(date +%Y%m%d_%H%M%S)
mkdir -p "$CASE_DIR/results"
RUNLOG="$CASE_DIR/results/pattern_${TESTDB}_${TAG}.log"
exec > >(tee -a "$RUNLOG") 2>&1

q() { "$CLI" -h "$SEED" -p 6667 -u root -pw 'TimechoDB@2021' "$@" 2>&1 | tail -2; }

echo "[$(date +%T)] start workload (RW 240s)"
cd "$BENCH" || exit 2
[ -d weather-rn-tdb122 ] || { echo "missing $BENCH/weather-rn-tdb122"; exit 2; }
nohup ./benchmark.sh -cf "$BENCH/weather-rn-tdb122/conf_rw" > "/tmp/pat_rw_$TAG.out" 2>&1 &
RW=$!
sleep 240

echo "[$(date +%T)] DDL workload"
q -sql_dialect tree -e 'create database root.patcheck;'
q -sql_dialect tree -e 'create timeseries root.patcheck.d1.s1 with datatype=INT64;'
q -sql_dialect tree -e 'alter timeseries root.patcheck.d1.s1 with datatype=INT32;'
q -sql_dialect table -e 'create database patcheck;'
q -sql_dialect table -e 'create table patcheck.base(device string tag, v int64 field);'
q -sql_dialect table -e 'alter table patcheck.base add column v2 int32 field;'
q -sql_dialect table -e 'create view patcheck.v1 as select device as dev, v from patcheck.base;'

echo "[$(date +%T)] stop/start DN 172.16.2.13"
ssh -o BatchMode=yes root@172.16.2.13 "source /etc/profile; cd $DB_ROOT/$TESTDB && ./sbin/stop-datanode.sh" >/dev/null 2>&1 || true
sleep 15
ssh -o BatchMode=yes root@172.16.2.13 "source /etc/profile; cd $DB_ROOT/$TESTDB && ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" 2>/dev/null
sleep 45
kill "$RW" 2>/dev/null || true
pkill -f 'org.apache.iotdb.benchmark' 2>/dev/null || true

echo "[$(date +%T)] scan since $TS"
fail=0
known=0
while IFS=$'\t' read -r id bug scope kind pattern; do
  [ -z "${id:-}" ] && continue
  total=0
  if [ "$scope" = "dn" ]; then HOSTS="$DN_LIST"; LOG="log_datanode_all.log"; else HOSTS="$CN_LIST"; LOG="log_confignode_all.log"; fi
  for ip in $HOSTS; do
    n=$(ssh -n -o BatchMode=yes root@"$ip" "awk -v ts='$TS' 'substr(\$0,1,19)>=ts' $DB_ROOT/$TESTDB/logs/$LOG 2>/dev/null | grep -aE '$pattern' | wc -l" 2>/dev/null)
    total=$((total + ${n:-0}))
  done
  if [ "$kind" = "known" ]; then
    known=$((known + 1))
    st="KNOWN_ISSUE_HIT"; [ "$total" -eq 0 ] && st="known_issue_absent"
  else
    if [ "$total" -gt 0 ]; then st="FAIL"; fail=$((fail + 1)); else st="PASS"; fi
  fi
  printf '%-10s %-8s %-18s hits=%s\n' "$id" "$bug" "$st" "$total"
done < "$CASE_DIR/checks.tsv"

echo "----------------------------------------"
echo "actives_failed=$fail known=$known（版本 $TESTDB，窗口起始 $TS）"
[ "$fail" -eq 0 ] && echo "PATTERN_SUITE: PASS" || echo "PATTERN_SUITE: FAIL"
