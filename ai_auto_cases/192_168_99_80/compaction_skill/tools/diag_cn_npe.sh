#!/bin/bash
# 抓 ConfigNode 上 NPE 的完整堆栈（DT-07 视图改列类型时出现）
set -uo pipefail
V=/data/iotdb/v20121rc6_1010_7ae8713e
for h in 78 79; do
  echo "===== confignode .$h ====="
  ssh -o StrictHostKeyChecking=no root@192.168.99.$h "grep -n 'markAsGeneratedByRemoteConsensusLeader' $V/logs/log_confignode_all.log | head -2; echo '--- 第一处前后 30 行 ---'; awk '/Cannot invoke \"org.apache.iotdb.commons.request.IConsensusRequest.markAsGeneratedByRemoteConsensusLeader/{found=NR} found && NR>=found-6 && NR<=found+22{print NR\": \"\$0}' $V/logs/log_confignode_all.log | head -30 | cut -c1-200" 2>/dev/null
done
