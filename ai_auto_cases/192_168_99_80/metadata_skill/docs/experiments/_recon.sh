#!/bin/bash
# UDF/Trigger 准备侦察（在集群节点上执行）
V=/data/iotdb/v20121rc5_1003_aaf460d
echo "=== 安装目录 ==="
ls "$V"
echo "=== jar 所在目录 ==="
find "$V" -maxdepth 3 -type d | grep -iE 'lib|ext|udf|trigger' | head -20
echo "=== jar 总数 ==="
find "$V" -name '*.jar' | wc -l
echo "=== jar 清单（前 30） ==="
find "$V" -name '*.jar' | sed "s|$V/||" | sort | head -30
echo "=== 配置里的 udf/trigger/lib 键 ==="
grep -inE 'udf|trigger|_lib' "$V/conf/iotdb-system.properties" | head -20
echo "=== 是否已有 udf/trigger 目录 ==="
ls -d "$V"/ext/* "$V"/udf_lib "$V"/trigger_lib 2>/dev/null
