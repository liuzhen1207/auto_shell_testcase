#!/bin/bash
# One-command regression for the tree-view auto-sync-schema feature.
# usage:
#   run_regression.sh <build_dir> [protocol] [plm_item]
#   run_regression.sh master_1026_dc11a35 IoTConsensusV2 TDB-343
#   NEW=... PKG_ZIP=/path/to/bin.zip ./run_regression.sh <build_dir>    # deploy first if missing
set -u
B="${B:-$(cd "$(dirname "$0")/.." && pwd)}"
[ -f "$B/conf/env.conf" ] && . "$B/conf/env.conf"
build="${1:-}"
if [ -z "$build" ]; then
  echo "usage: run_regression.sh <build_dir> [protocol: IoTConsensus|IoTConsensusV2] [plm_item]"
  echo "env : NEW / PKG_ZIP (deploy when missing) / OLD_CN / OLD_DN"
  exit 2
fi
export NEW="$build"
[ -n "${2:-}" ] && export PROTO="org.apache.iotdb.consensus.iot.$2"
[ -n "${3:-}" ] && export PLM_ITEM="$3"
. $B/env.sh

STAMP=$(date +%Y%m%d_%H%M%S)
OUT=$B/results/REGRESSION_${NEW}_$(proto_short "$PROTO")_${STAMP}
mkdir -p "$OUT"
LOG=$OUT/regression.log
say() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

say "=========== regression start ==========="
say "build=$NEW  protocol=$PROTO  plm=$PLM_ITEM"
say "output=$OUT"

# 1) make sure the build is installed on the client and the nodes
need_deploy=0
for ip in $CN_LIST; do
  ssh -o StrictHostKeyChecking=no root@$ip "test -d /data/iotdb/$NEW/lib" || need_deploy=1
done
for ip in $DN_LIST; do
  ssh -o StrictHostKeyChecking=no root@$ip "test -d /data1/iotdb/$NEW/lib" || need_deploy=1
done
if [ "$need_deploy" = "1" ]; then
  if [ -n "${PKG_ZIP:-}" ] && [ -f "$PKG_ZIP" ]; then
    say "build not installed, deploying from $PKG_ZIP"
    bash $B/tools/deploy_build.sh > $OUT/deploy.log 2>&1 || { say "DEPLOY FAILED (see deploy.log)"; exit 3; }
    say "deploy done"
  else
    say "ABORT: build dir missing and PKG_ZIP not provided"
    exit 3
  fi
else
  say "build already installed on all nodes"
fi

# 2) switch the data-region consensus protocol (config only; data is wiped in step 3)
say "set data_region_consensus_protocol_class=$PROTO"
for ip in $CN_LIST; do
  ssh -o StrictHostKeyChecking=no root@$ip "sed -i 's#^data_region_consensus_protocol_class=.*#data_region_consensus_protocol_class=$PROTO#' /data/iotdb/$NEW/conf/iotdb-system.properties" 2>/dev/null
done
for ip in $DN_LIST; do
  ssh -o StrictHostKeyChecking=no root@$ip "sed -i 's#^data_region_consensus_protocol_class=.*#data_region_consensus_protocol_class=$PROTO#' /data1/iotdb/$NEW/conf/iotdb-system.properties" 2>/dev/null
done

# 3) clean cluster (wipe data/logs, ordered start) — protocol change requires it
say "hard reset"
bash $B/tools/hard_reset.sh > $OUT/reset.log 2>&1
if ! grep -q READY $OUT/reset.log; then
  say "ABORT: cluster did not become ready (see reset.log)"
  tail -5 $OUT/reset.log | tee -a "$LOG"
  exit 4
fi
say "cluster ready"

# 4) activation check
act=$($CLI -h $QUERY_HOST -p 6667 -u root -pw $PW -e "show cluster;" 2>/dev/null)
n_run=$(echo "$act" | grep -cE "Running")
n_act=$(echo "$act" | grep -c "ACTIVATED")
say "nodes running=$n_run activated=$n_act"
echo "$act" > $OUT/show_cluster.txt
if [ "$n_act" -lt 8 ]; then
  say "ABORT: cluster is not fully ACTIVATED — deployment identity/license problem"
  exit 5
fi

# 5) run the suite
say "run suite (49 cases)"
cd $B
bash $B/tools/suite.sh > $OUT/suite.log 2>&1
RUN=$(ls -td $B/results/run_* | head -1)
say "suite output dir: $RUN"
cp $RUN/results.tsv $OUT/results.tsv 2>/dev/null

# 6) classify
bash $B/tools/classify_run.sh "$RUN" > $OUT/classify.log 2>&1
cp $RUN/classified.tsv $OUT/classified.tsv 2>/dev/null

# 7) summary
tot=$(tail -n +2 $OUT/classified.tsv 2>/dev/null | wc -l)
pass=$(awk -F'\t' 'NR>1 && $4=="PASS"' $OUT/classified.tsv 2>/dev/null | wc -l)
ff=$(awk -F'\t' 'NR>1 && $4=="FAIL_FEATURE_LOG"' $OUT/classified.tsv 2>/dev/null | wc -l)
fa=$(awk -F'\t' 'NR>1 && $4=="FAIL_ASSERT"' $OUT/classified.tsv 2>/dev/null | wc -l)
fo=$(awk -F'\t' 'NR>1 && $4=="FAIL_OTHER_LOG"' $OUT/classified.tsv 2>/dev/null | wc -l)
dur=$(awk -F'\t' 'NR>1{s+=$7} END{print s+0}' $OUT/results.tsv 2>/dev/null)

# known-failing cases (already filed defects) do not fail the pipeline
KNOWN=$B/conf/known_failures.conf
known_ids=""
[ -f "$KNOWN" ] && known_ids=$(grep -vE '^\s*#|^\s*$' "$KNOWN" | cut -d'|' -f1 | tr '\n' ' ')

new_fail=0
known_fail=0
if [ -f "$OUT/classified.tsv" ]; then
  while IFS=$'\t' read -r id feat ctype verdict af ferr ha oth dur det; do
    [ "$id" = "id" ] && continue
    [ "$verdict" = "PASS" ] && continue
    if echo " $known_ids " | grep -q " $id "; then
      known_fail=$((known_fail + 1))
    else
      new_fail=$((new_fail + 1))
    fi
  done < "$OUT/classified.tsv"
fi

{
  echo "# 回归结果 $NEW / $(proto_short "$PROTO")"
  echo ""
  echo "- 时间：$STAMP"
  echo "- PLM 工作项：$PLM_ITEM"
  echo "- 用例数：$tot"
  echo "- PASS：$pass"
  echo "- FAIL（断言）：$fa"
  echo "- FAIL（功能路径日志缺陷）：$ff"
  echo "- FAIL（HA/环境噪声，需人工确认）：$fo"
  echo "- 已知缺陷导致的预期失败：$known_fail（清单见 known_failures.conf）"
  echo "- 新增失败（需处理）：$new_fail"
  echo "- 用例执行总耗时：${dur}s"
  echo ""
  echo "## 失败清单"
  echo ""
  awk -F'\t' -v k=" $known_ids " 'NR>1 && $4!="PASS"{printf "- %s | %s | af=%s feat=%s ha=%s other=%s%s\n", $1, $4, $5, $6, $7, $8, (index(k, " " $1 " ") ? "  [已知缺陷]" : "  [新增]")}' $OUT/classified.tsv 2>/dev/null
} > $OUT/summary.md

say "=========== regression done ==========="
cat $OUT/summary.md | tee -a "$LOG"

# 只有“新增失败”才让流水线失败；已知缺陷与日志噪声不阻断
[ "$new_fail" -gt 0 ] && exit 10
exit 0
