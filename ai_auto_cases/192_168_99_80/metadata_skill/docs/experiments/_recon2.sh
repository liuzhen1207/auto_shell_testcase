#!/bin/bash
V=/data/iotdb/v20121rc5_1003_aaf460d
echo "=== lib/ 内容（jar 名）==="
ls "$V/lib" | sort
echo "=== ext/ 内容 ==="
ls -R "$V/ext" 2>/dev/null | head -20
echo "=== 配置里的 udf/trigger/lib 键 ==="
grep -inE 'udf|trigger|_lib' "$V/conf/iotdb-system.properties" | head -20
echo "=== 服务端主 jar 里是否含 API 类 ==="
for j in "$V"/lib/*.jar; do
  if unzip -l "$j" 2>/dev/null | grep -q 'org/apache/iotdb/udf/api/UDTF.class'; then echo "UDTF in $j"; fi
  if unzip -l "$j" 2>/dev/null | grep -q 'org/apache/iotdb/trigger/api/Trigger.class'; then echo "Trigger in $j"; fi
  if unzip -l "$j" 2>/dev/null | grep -q 'org/apache/tsfile/enums/TSDataType.class'; then echo "TSDataType in $j"; fi
done
