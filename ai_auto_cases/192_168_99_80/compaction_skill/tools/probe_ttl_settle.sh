#!/bin/bash
# 诊断 CO-13 为什么没有 settle：看 [TTL] 选择日志 + TsFile 清单 + 过期时间判据
V=v20121rc6_1010_7ae8713e
for h in 192.168.99.77 192.168.99.78 192.168.99.79; do
  echo "=== $h ==="
  ssh -o BatchMode=yes root@$h "grep -h '\[TTL\]' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null | tail -6 | cut -c1-230
    echo '--- Settle 相关 ---'
    grep -h 'Settle' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null | tail -4 | cut -c1-200
    echo '--- TsFile 清单（root.cottl）---'
    find /data/iotdb/$V/data/datanode/data -path '*root.cottl*' -name '*.tsfile' 2>/dev/null | head -8
    echo '--- 配置生效值 ---'
    grep -E '^(enable_seq_space_compaction|ttl_check_interval|expired_data_ratio|max_expired_time)=' /data/iotdb/$V/conf/iotdb-system.properties"
done
