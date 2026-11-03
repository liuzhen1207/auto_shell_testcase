#!/bin/bash
# ============================================================================
# 常规回归链（34 条）：metadata(14) → ttl(15) → diskusage(5)
#   产出：rc13reg_<模块>.csv / rc13reg_<模块>.log / rc13reg.log / rc13reg.state
# ============================================================================
set -uo pipefail
R=/data/iotdb/autotest
V=v20131rc1_1030_ab6d3de
LOG=$R/rc13reg.log
STATE=$R/rc13reg.state
: >"$LOG"; : >"$STATE"
say(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

count(){ # $1=模块 $2=csv
  local p f
  p=$(awk -F, 'NR>1 && $0 ~ /,PASS,/' "$2" | wc -l)
  f=$(awk -F, 'NR>1 && $0 ~ /,FAIL,/' "$2" | wc -l)
  say "  [$1] PASS=$p FAIL=$f"
  echo "$1|PASS=$p|FAIL=$f|csv=$2" >>"$STATE"
}

run(){ local m=$1 set=$2 t0 t1 rc
  say "=== [$m] 开始 set=$set ==="
  t0=$(date +%s)
  ( cd "$R/$m" && V_TESTDB=$V BUILD_TAG=ab6d3de timeout 28800 bash tools/run_all.sh --set "$set" --consensus IoTConsensus ) >"$R/rc13reg_$m.log" 2>&1
  rc=$?
  t1=$(date +%s)
  cp -f "$R/$m/results/test_result.csv" "$R/rc13reg_$m.csv" 2>/dev/null
  say "=== [$m] 结束 rc=$rc 耗时=$(( (t1-t0)/60 ))min ==="
  count "$m" "$R/rc13reg_$m.csv"
}

say "########## 常规回归（metadata/ttl/diskusage）开始 ##########"
grep -E '^v_(testdb|commit)=' "$R/conf/test.conf" | tee -a "$LOG"
run metadata_skill all
run ttl_skill all
run diskusage_skill all
say "########## 常规回归完成 ##########"
cat "$STATE" | tee -a "$LOG"
