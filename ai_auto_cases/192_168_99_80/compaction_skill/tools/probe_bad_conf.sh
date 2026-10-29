#!/bin/bash
# 看看到底哪 4 行匹配了"非法值"模式
V=v20121rc6_1010_7ae8713e
for h in 192.168.99.77 192.168.99.78 192.168.99.79; do
  echo "=== $h ==="
  ssh -o BatchMode=yes root@$h "P=/data/iotdb/$V/conf/iotdb-system.properties
    echo '--- 匹配 =(BOGUS|bogus|abc|-5)\$ 的行 ---'
    grep -nE '=(BOGUS|bogus|abc|-5)\$' \$P
    echo '--- 被探针的键当前值 ---'
    grep -nE '^(compaction_priority|inner_seq_selector|compaction_thread_count|inner_compaction_candidate_file_num)=' \$P"
done
