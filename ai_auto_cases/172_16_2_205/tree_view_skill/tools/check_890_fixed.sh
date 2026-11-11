#!/bin/bash
R=/data2/auto_test/treeview_suite/results/run_20261111_121100
echo "=== 全量日志中 552/305/ViewColumnAutoSyncTrigger 出现次数 ==="
echo -n "  552: "; grep -rh '552' "$R"/*_logdelta/new_*.txt 2>/dev/null | wc -l
echo -n "  305: "; grep -rh '305' "$R"/*_logdelta/new_*.txt 2>/dev/null | wc -l
echo -n "  ViewColumnAutoSyncTrigger: "; grep -rh 'ViewColumnAutoSyncTrigger' "$R"/*_logdelta/new_*.txt 2>/dev/null | wc -l
echo
echo "=== 列已存在相关文案 ==="
grep -rhi 'already exist\|Column check for table' "$R"/*_logdelta/new_*.txt 2>/dev/null | sed 's/^.*\]//' | cut -c1-140 | sort | uniq -c | head -5
echo
echo "=== 专门日志文件 log_datanode_view_column_auto_sync_error.log 最近内容 ==="
for ip in 172.16.2.2 172.16.2.6; do
  echo "--- DN $ip"
  ssh -n -o StrictHostKeyChecking=no root@$ip "tail -3 /data1/iotdb/v20131rc2_1110_83183d0/logs/log_datanode_view_column_auto_sync_error.log 2>/dev/null" 2>/dev/null
done
