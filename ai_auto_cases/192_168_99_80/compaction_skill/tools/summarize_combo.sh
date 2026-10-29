#!/bin/bash
# 汇总 CO-15 / CO-16 的关键结论行（避免在 ssh 一行命令里跟引号搏斗）
S=/data/iotdb/autotest/compaction_skill
for id in CO-15 CO-16; do
  F=$(ls -t $S/results/${id}_*.out 2>/dev/null | head -1)
  [ -n "$F" ] || continue
  echo "===== $id : $(basename "$F") ====="
  grep -a 'RESULT' "$F" | tail -1
  grep -a '组合 seq=' "$F" | sed 's/^\[[^]]*\] *//'
  grep -a '优先级 INNER_CROSS\|优先级 CROSS_INNER\|优先级 BALANCE' "$F" | grep -a 'PASS\|FAIL\|WARN' | sed 's/^\[[^]]*\] *//'
  grep -a '优先级语义' "$F" | sed 's/^\[[^]]*\] *//'
  grep -a '极端值' "$F" | sed 's/^\[[^]]*\] *//'
  grep -a 'inner_seq\|inner_unseq\|cross_performer\|chunk' "$F" | grep -a 'PASS\|FAIL\|生效值' | sed 's/^\[[^]]*\] *//'
  grep -a '非法值\|已写回\|已恢复\|残留' "$F" | sed 's/^\[[^]]*\] *//'
  echo
done
