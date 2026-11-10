#!/bin/bash
# 已自动化用例一键回归（QA-LZ-001 / QA-LZ-002）
set -u
cd "$(dirname "$0")" || exit 1
TESTDB="${TESTDB:-v20131rc1_1030_ab6d3de}"
RESULT_DIR="results"
mkdir -p "$RESULT_DIR"
TS=$(date +%Y%m%d_%H%M%S)
LOG="$RESULT_DIR/raw_${TESTDB}_${TS}.log"

echo "[$(date +%T)] QA-LZ-001 (V2-754)"
TESTDB="$TESTDB" bash ./run_qa_lz_001.sh > "$LOG" 2>&1
rc1=$?
echo "rc_001=$rc1"; tail -6 "$LOG"

echo "[$(date +%T)] 日志门禁 23 项"; bash ./run_pattern_suite.sh > "$RESULT_DIR/pattern_${TS}.log" 2>&1; rcp=$?; echo "rc_pattern=$rcp"
echo "[$(date +%T)] QA-LZ-002 (V2-861 / RN-TDB-122)"
echo "复用 ReleaseNote-测试/cases/TDB-122-stop-dn-query-error/run.sh（单独执行）"

echo "----------------------------------------"
echo "QA-LZ-001 rc=$rc1"
if [ "$rc1" -eq 0 ] && [ "${rcp:-1}" -eq 0 ]; then echo "SUITE: PASS（002 单独跑 RN-TDB-122）"; exit 0; else echo "SUITE: FAIL"; exit 1; fi
