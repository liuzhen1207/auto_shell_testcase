#!/bin/bash
for i in 1 2 3; do
  echo "######## 第 $i 轮"
  bash /tmp/collect_defect_logs.sh v20131rc2_1110_83183d0 2>&1 | grep -E 'DB=|OUT=|LOST=|Failed to prove' | head -8
done
