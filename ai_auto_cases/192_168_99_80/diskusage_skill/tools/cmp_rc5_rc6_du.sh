#!/bin/bash
# TDB-629：RC5 与 RC6 的 jar 中磁盘占用相关类的字节码对比（预期：基类 DiskUsageStatisticUtil 不同）
J5=/data/iotdb/testdb/v20121rc5_1003_aaf460d/lib/timechodb-server-2.0.12.1.jar
J6=/data/iotdb/testdb/v20121rc6_1010_7ae8713e/lib/timechodb-server-2.0.12.1.jar
PAT='(DiskUsageStatisticUtil|TreeDiskUsageStatisticUtil|TableDiskUsageStatisticUtil|ShowDiskUsageOperator)(\$[0-9]+)?\.class'
grab(){ unzip -v "$1" | grep -E "$PAT" | awk '{print $7, $8}' | sort -k2; }
grab "$J5" > /tmp/d5.txt; grab "$J6" > /tmp/d6.txt
echo "=== RC5 相关类（CRC32 类名）==="; cat /tmp/d5.txt
echo "=== RC6 相关类（CRC32 类名）==="; cat /tmp/d6.txt
echo "=== 逐条目 diff ==="
if diff /tmp/d5.txt /tmp/d6.txt > /tmp/ddiff.txt; then
  echo "（无差异 —— 与预期不符，需重新核对修复是否在 RC6）"
else
  echo "差异如下（< 仅 RC5 / > 仅 RC6）："; cat /tmp/ddiff.txt
fi
echo
echo "=== 基类常量池里的方法引用（修复前用 readLock/readUnlock，修复后改为 FileReaderManager 引用计数）==="
for v in v20121rc5_1003_aaf460d v20121rc6_1010_7ae8713e; do
  J=/data/iotdb/testdb/$v/lib/timechodb-server-2.0.12.1.jar
  echo "--- $v ---"
  unzip -p "$J" 'org/apache/iotdb/db/storageengine/dataregion/utils/DiskUsageStatisticUtil.class' > /tmp/dutil.class
  echo -n "  class md5: "; md5sum /tmp/dutil.class | awk '{print $1}'
  for m in readLock readUnlock increaseFileReaderReference decreaseFileReaderReference; do
    echo -n "  常量池 $m 次数: "; grep -ao "$m" /tmp/dutil.class | wc -l
  done
done
echo
echo "=== 运行 jar 一致性（节点上跑的确实是 RC6 这份）==="
for h in 192.168.99.77 192.168.99.78 192.168.99.79; do
  echo -n "  $h: "; ssh -n root@$h "md5sum /data/iotdb/v20121rc6_1010_7ae8713e/lib/timechodb-server-2.0.12.1.jar | awk '{print \$1}'"
done
