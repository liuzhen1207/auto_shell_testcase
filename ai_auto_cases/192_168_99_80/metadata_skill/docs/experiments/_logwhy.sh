#!/bin/bash
# 看 suite 里被 check_logs 命中的那条日志到底是什么
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env >/dev/null 2>&1
PAT="$COMMON_ERR_PAT|$MD_ERR_PAT"
echo "当前模式: $PAT"
echo "豁免模式: $BENIGN_PAT"
for h in "${DN[@]}"; do
  echo "=== $h ==="
  sshx "$h" "grep -hE '$PAT' $DB_DIR/logs/*datanode*all*.log $DB_DIR/logs/*datanode*error*.log 2>/dev/null | grep -vE '$BENIGN_PAT' | head -5 | cut -c1-260"
done
echo "=== 所有含 'MDSKILL' 的日志（用例故意抛的异常） ==="
for h in "${DN[@]}"; do
  sshx "$h" "grep -h 'MDSKILL' $DB_DIR/logs/*.log 2>/dev/null | head -3 | cut -c1-240"
done
