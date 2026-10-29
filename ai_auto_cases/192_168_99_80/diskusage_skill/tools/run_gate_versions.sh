#!/bin/bash
# ============================================================================
# TDB-629 双版本门禁：先在"修复前版本"复现，再在"修复后版本"验证（RC6）
#   用法： bash tools/run_gate_versions.sh [修复前版本] [修复前commit] [修复后版本] [修复后commit]
#   默认：  v20121rc5_1003_aaf460d aaf460d  v20121rc6_1010_7ae8713e 7ae8713e
#   做的事：切框架 conf/test.conf 到目标版本 → 跑 DU-01/DU-02 → 存输出 → 最后还原 test.conf
#   注意：每条用例自己会 清集群 + 写配置 + 启动，所以这里只切版本。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
PRE_VER=${1:-v20121rc5_1003_aaf460d}
PRE_COMMIT=${2:-aaf460d}
POST_VER=${3:-v20121rc6_1010_7ae8713e}
POST_COMMIT=${4:-7ae8713e}
FRAMEWORK_DIR=${FRAMEWORK_DIR:-/data/iotdb/autotest}
CONF=$FRAMEWORK_DIR/conf/test.conf
STAMP=$(date +%Y%m%d_%H%M%S)
BAK=$CONF.bak_tdb629_$STAMP
OUT=$SKILL/results/gate_tdb629_$STAMP
mkdir -p "$OUT"

cp -p "$CONF" "$BAK"
restore(){ echo "--- 还原 test.conf 到 $BAK ---"; cp -p "$BAK" "$CONF"; grep -E '^v_(testdb|commit)=' "$CONF"; }
trap restore EXIT

switch_ver(){
  sed -i "s/^v_testdb=.*/v_testdb=$1/; s/^v_commit=.*/v_commit=$2/" "$CONF"
  echo "--- 版本切到 $1 ($2) ---"; grep -E '^v_(testdb|commit)=' "$CONF"
}

run_case(){ local ver=$1 id=$2 script=$3
  echo "########## [$id @ $ver] $(date '+%F %T') ##########"
  ( cd "$SKILL" && V_TESTDB="$ver" BUILD_TAG="$ver" bash "$script" >"$OUT/${id}_${ver}.out" 2>&1 )
  echo "  rc=$? 输出=$OUT/${id}_${ver}.out"
  grep -aE '^\[[^]]*\] (PASS|FAIL|RESULT) ' "$OUT/${id}_${ver}.out" | tail -12 | sed 's/^/    /'
}

echo "=============================================================="
echo " 修复前版本（期望复现 TDB-629）：$PRE_VER ($PRE_COMMIT)"
echo "=============================================================="
switch_ver "$PRE_VER" "$PRE_COMMIT"
run_case "$PRE_VER" DU-01-tree cases/tree/du_tree_merge_after_stats.sh
run_case "$PRE_VER" DU-02-table cases/table/du_table_merge_after_stats.sh

echo "=============================================================="
echo " 修复后版本（期望已修复）：$POST_VER ($POST_COMMIT)"
echo "=============================================================="
switch_ver "$POST_VER" "$POST_COMMIT"
run_case "$POST_VER" DU-01-tree cases/tree/du_tree_merge_after_stats.sh
run_case "$POST_VER" DU-02-table cases/table/du_table_merge_after_stats.sh

echo "=== 双版本门禁运行结束 $(date '+%F %T')；输出目录 $OUT ==="
