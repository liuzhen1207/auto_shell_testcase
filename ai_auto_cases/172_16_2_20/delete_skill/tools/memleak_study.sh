#!/bin/bash
# memleak_study.sh <CASE> — 内存泄漏专项：多轮写删 + 每 N 轮强制 GC + 读 post-GC 堆稳态
# 与 163 轮矩阵分离：矩阵里的 memleak 用例只是"跑一遍"，本脚本才是泄漏判定
set -u
CASE=$1
BASE=/data2/iotdb/rc10_matrix
CLI=/data2/iotdb/v20121rc10_1021_c60ce63/timechodb-2.0.12.1-bin/sbin/start-cli.sh
CONF=/data2/auto_test/cluster_shell_3c5d_no3/tc2026_releasenote_testcase/conf/test.conf
PW=$(awk -F= '$1=="root_pw"{print substr($0,index($0,"=")+1)}' "$CONF")
DNS="19 21 22 23 24"
CYCLES=${CYCLES:-200}
DEVICES=${DEVICES:-100}
EVERY=${EVERY:-20}
ART=$BASE/studies/$CASE${RUN_TAG:+-$RUN_TAG}
CSV=$ART/post-gc-heap.csv
mkdir -p "$ART"
: > "$CSV"
JCMD=/usr/local/zulu17.44.15-ca-jdk17.0.8-linux_x64/bin/jcmd
S="ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8"
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$ART/study.log"; }

heap_kb(){ # $1=dn  -> post-GC used KB
  $S root@172.16.2."$1" "PID=\$(pgrep -f 'com[.]timecho[.]iotdb[.]DataNode' | head -1); $JCMD \$PID GC.run >/dev/null 2>&1; $JCMD \$PID GC.heap_info 2>/dev/null | sed -n 's/.*heap.*used \([0-9]*\)K.*/\1/p' | head -1" 2>/dev/null
}
rss_kb(){ $S root@172.16.2."$1" "ps -o rss= -p \$(pgrep -f 'com[.]timecho[.]iotdb[.]DataNode' | head -1)" 2>/dev/null | tr -d ' '; }

sample(){ # $1=cycle
  local c=$1 n h r
  for n in $DNS; do
    h=$(heap_kb "$n"); r=$(rss_kb "$n")
    echo "$c,$n,${h:-NA},${r:-NA}" >> "$CSV"
  done
}

case "$CASE" in
  DEL-MEMLEAK-TABLE-001|DEL-MEMLEAK-TABLE-002|DEL-MEMLEAK-TABLE-003) MODEL=table; DB=del_rc10_mls_table ;;
  DEL-MEMLEAK-TREE-001|DEL-MEMLEAK-TREE-002|DEL-MEMLEAK-TREE-003) MODEL=tree; DB=root.rc10mls_tree ;;
  *) echo "unsupported case $CASE"; exit 2 ;;
esac

setup(){
  { echo "SET SQL_DIALECT=$( [ "$MODEL" = tree ] && echo TREE || echo TABLE );"
    if [ "$MODEL" = table ]; then
      echo "CREATE DATABASE $DB;"
      echo "CREATE TABLE $DB.t (device_id STRING TAG, v INT32 FIELD);"
    else
      echo "CREATE DATABASE root.rc10mls_tree;"
      for i in $(seq 1 "$DEVICES"); do echo "CREATE TIMESERIES root.rc10mls_tree.d$i.s1 INT32;"; done
    fi
  } > "$ART/setup.sql"
  timeout 300 "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" < "$ART/setup.sql" > "$ART/setup.out" 2>&1
}

cycle_sql(){ # $1=cycle -> writes $ART/cycle.sql
  local c=$1 base i
  base=$((1800000000000 + c * 20000))
  { echo "SET SQL_DIALECT=$( [ "$MODEL" = tree ] && echo TREE || echo TABLE );"
    for i in $(seq 1 "$DEVICES"); do
      if [ "$MODEL" = table ]; then
        echo "INSERT INTO $DB.t(time,device_id,v) VALUES ($((base + i)),'d$i',$((c + i)));"
      else
        echo "INSERT INTO root.rc10mls_tree.d$i(time,s1) VALUES ($((base + i)),$((c + i)));"
      fi
    done
    case "$CASE" in
      DEL-MEMLEAK-TABLE-001) echo "DELETE FROM $DB.t WHERE time >= $((base + 1)) AND time <= $((base + DEVICES));" ;;
      DEL-MEMLEAK-TABLE-002) echo "DELETE FROM $DB.t;" ;;
      DEL-MEMLEAK-TABLE-003) echo "DROP TABLE $DB.t;"; echo "CREATE TABLE $DB.t (device_id STRING TAG, v INT32 FIELD);" ;;
      DEL-MEMLEAK-TREE-001) echo "DELETE FROM root.rc10mls_tree.** WHERE time >= $((base + 1)) AND time <= $((base + DEVICES));" ;;
      DEL-MEMLEAK-TREE-002) echo "DELETE FROM root.rc10mls_tree.** WHERE time <= $((base + DEVICES));" ;;
      DEL-MEMLEAK-TREE-003)
        for i in $(seq 1 "$DEVICES"); do echo "DELETE TIMESERIES root.rc10mls_tree.d$i.s1;"; done
        for i in $(seq 1 "$DEVICES"); do echo "CREATE TIMESERIES root.rc10mls_tree.d$i.s1 INT32;"; done ;;
    esac
    if [ $((c % 10)) -eq 0 ]; then echo "FLUSH;"; fi
  } > "$ART/cycle.sql"
}

log "STUDY START case=$CASE model=$MODEL cycles=$CYCLES devices=$DEVICES sample_every=$EVERY"
bash "$BASE/scripts/cluster_ctl.sh" reset > "$ART/reset.out" 2>&1 || { log "RESET FAILED"; exit 1; }
setup
sample 0
for c in $(seq 1 "$CYCLES"); do
  cycle_sql "$c"
  timeout 120 "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" < "$ART/cycle.sql" >> "$ART/cycles.out" 2>&1
  if [ $((c % EVERY)) -eq 0 ]; then sample "$c"; log "cycle $c sampled"; fi
done
sample "$CYCLES"

# 线性趋势：post-GC 堆 vs 周期
for n in $DNS; do
  awk -F, -v N="$n" '$2==N && $3!="NA"{n++; x[n]=$1; y[n]=$3}
    END{
      if(n<2){ printf "%s samples=%d insufficient\n", N, n; exit }
      sx=0; sy=0; sxx=0; sxy=0
      for(i=1;i<=n;i++){ sx+=x[i]; sy+=y[i]; sxx+=x[i]*x[i]; sxy+=x[i]*y[i] }
      d=n*sxx-sx*sx
      slope=(d==0)?0:(n*sxy-sx*sy)/d
      printf "%s samples=%d first=%dKB last=%dKB delta=%dKB slope=%.1fKB_per_cycle\n", N, n, y[1], y[n], y[n]-y[1], slope
    }' "$CSV"
done > "$ART/trend.txt"
cat "$ART/trend.txt" | tee -a "$ART/study.log"
log "STUDY END case=$CASE"
