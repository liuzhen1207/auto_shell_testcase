#!/bin/bash
# 检查三节点磁盘水位 + 压缩相关配置 + 是否被 disk 门控挡住
V=v20121rc6_1010_7ae8713e
for h in 192.168.99.77 192.168.99.78 192.168.99.79; do
  echo "=== $h ==="
  ssh -o BatchMode=yes root@$h "df -h / /data 2>/dev/null | sed -n '1,4p'
    echo '--- data/logs 占用 ---'
    du -sh /data/iotdb/$V/data /data/iotdb/$V/logs 2>/dev/null
    echo '--- 压缩相关配置 ---'
    grep -E '^(disk_space_warning_threshold|compaction_schedule_interval_in_ms|inner_compaction_candidate_file_num|inner_compaction_total_file_num_threshold|max_level_gap_in_inner_compaction|inner_seq_selector|enable_seq_space_compaction)=' /data/iotdb/$V/conf/iotdb-system.properties
    echo '--- 最近的 isDiskHasSpace / 压缩调度日志 ---'
    grep -hE 'disk space|DiskSpace|isDiskHasSpace|not enough disk' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null | tail -3 | cut -c1-200"
done
