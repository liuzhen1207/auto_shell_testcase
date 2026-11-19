#!/bin/bash
# 只读探测：show configuration（表方言）里 compaction 相关键的可见性与取值
CLI=/data/iotdb/testdb/v20121rc6_1010_7ae8713e/sbin/start-cli.sh
H=192.168.99.77
KEYS=$(grep -o "CMP_KEYS='[^']*'" /data/iotdb/autotest/compaction_skill/lib/cmp.sh | head -1 | sed "s/CMP_KEYS='//;s/'$//")
for i in $(seq 1 24); do
  OUT=$($CLI -h $H -u root -pw 'TimechoDB@2021' -sql_dialect table -timeout 3600 -e 'show configuration;' 2>&1)
  N=$(printf '%s\n' "$OUT" | grep -c '|')
  if [ "${N:-0}" -gt 5 ]; then
    echo "=== 第 $i 次探测成功：$(printf '%s\n' "$OUT" | wc -l) 行，$(date '+%T') ==="
    echo "--- 与 compaction 相关的行 ---"
    printf '%s\n' "$OUT" | grep -iE 'compaction|cross_|inner_|chunk_|target_' || echo "(无)"
    echo "--- CMP_KEYS 中 show configuration 里没有的键 ---"
    for k in $KEYS; do printf '%s\n' "$OUT" | grep -q "| *$k *|" || echo "  缺: $k"; done
    exit 0
  fi
  sleep 15
done
echo "!! 探测超时：集群一直被用例停/启"
