#!/bin/bash
# 跑 query_schedule_skill 全部用例（按 cases.tsv 顺序）
#   环境变量：
#     QS_ONLY="QS-01 QS-06"   只跑指定用例
#     QS_SKIP_CLEAN=1         复用现有集群（快，但要求当前集群版本/配置正确）
#     V_TESTDB=...            指定被测版本目录
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

LIST="$ROOT/cases.tsv"
[ -f "$LIST" ] || { echo "缺少 cases.tsv"; exit 1; }

PASS=0; FAIL=0; SKIP=0
for id in $(grep -v '^#' "$LIST" | awk -F'\t' 'NF>2{print $1}'); do
  if [ -n "${QS_ONLY:-}" ] && ! echo " $QS_ONLY " | grep -q " $id "; then
    SKIP=$((SKIP+1)); continue
  fi
  script=$(grep -v '^#' "$LIST" | awk -F'\t' -v i="$id" '$1==i{print $3}' | head -1)
  [ -f "$script" ] || { echo "  [skip] $id 脚本不存在: $script"; SKIP=$((SKIP+1)); continue; }
  echo "==================== $id ($script) ===================="
  t0=$(date +%s)
  bash "$script" >/tmp/qs_run_${id}.log 2>&1
  rc=$?
  t1=$(date +%s)
  # 判据：日志里出现 RESULT PASS 才算通过（避免 rc=0 但断言失败）
  if grep -qE "RESULT PASS" /tmp/qs_run_${id}.log 2>/dev/null; then
    PASS=$((PASS+1)); echo "  ✅ $id PASS ($((t1-t0))s)"
  else
    FAIL=$((FAIL+1)); echo "  ❌ $id FAIL ($((t1-t0))s)，日志 /tmp/qs_run_${id}.log"
    grep -E "FAIL " /tmp/qs_run_${id}.log 2>/dev/null | head -3 | sed 's/^/      /'
  fi
done
echo
echo "==================== 汇总 ===================="
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
