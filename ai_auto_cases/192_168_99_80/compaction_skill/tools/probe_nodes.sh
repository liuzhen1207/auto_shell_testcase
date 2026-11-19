#!/bin/bash
# 诊断：DN 启动失败的具体原因（loadProps 异常）+ 检查是否有空值行
for h in 192.168.99.77 192.168.99.78; do
  echo "=== $h ==="
  ssh -o BatchMode=yes root@$h 'L=/data/iotdb/v20121rc6_1010_7ae8713e/logs/log_datanode_all.log; grep -n "Exception\|Error\|invalid\|empty" $L 2>/dev/null | tail -8 | cut -c1-220; echo "--- 含 = 但值为空的行（compaction/相关）---"; grep -nE "^[a-z_]+=$" /data/iotdb/v20121rc6_1010_7ae8713e/conf/iotdb-system.properties | head -20; echo "--- compaction 相关键 ---"; grep -nE "^compaction|^sub_compaction|^target_compaction|^cross_|^inner_" /data/iotdb/v20121rc6_1010_7ae8713e/conf/iotdb-system.properties | head -20'
done
echo "=== 本机 conf_orig 对比（.77）==="
ssh -o BatchMode=yes root@192.168.99.77 'grep -cE "^[a-z_]+=$" /data/iotdb/v20121rc6_1010_7ae8713e/conf_orig/iotdb-system.properties'
