#!/bin/bash
# 诊断：DT-08 只读恢复后，落后副本(.79)的合并为什么没有再跑
set -uo pipefail
H=192.168.99.79
L=/data/iotdb/v20121rc6_1010_7ae8713e/logs/log_datanode_compaction.log
echo "=== $H: root.dtro 的 compaction 日志（最后 25 行）==="
ssh -n "root@$H" "grep -a 'root.dtro' $L | tail -25" | cut -c1-215
echo
echo "=== .79 上 root.dtro 的 TsFile（当前）==="
ssh -n "root@$H" "find /data/iotdb/v20121rc6_1010_7ae8713e/data/datanode/data -path '*/root.dtro/*' -name '*.tsfile' -printf '%p %s\n'" | sed 's#.*/data/datanode/data/##'
echo
echo "=== .79 上该库目录里的非 tsfile 残留（target/tmp/compaction.log）==="
ssh -n "root@$H" "find /data/iotdb/v20121rc6_1010_7ae8713e/data/datanode/data -path '*/root.dtro/*' ! -name '*.tsfile' -printf '%p\n' | head -20" | sed 's#.*/data/datanode/data/##'
echo
echo "=== .79: 只读窗口之后的 ERROR/WARN（compaction/settle 相关）==="
ssh -n "root@$H" "grep -aE '21:3[0-9]:' /data/iotdb/v20121rc6_1010_7ae8713e/logs/log_datanode_all.log | grep -aiE 'compaction|settle|readonly|read-only' | tail -25" | cut -c1-215
echo
echo "=== .79: 恢复后是否重新注册/调度（StorageEngine/CompactionScheduleTaskManager 关键行）==="
ssh -n "root@$H" "grep -aE '21:3[0-9]:' /data/iotdb/v20121rc6_1010_7ae8713e/logs/log_datanode_all.log | grep -aE 'CompactionScheduleTaskManager|registerDataRegion|Set system mode|is not allowed|forbidden|denied' | tail -20" | cut -c1-215
