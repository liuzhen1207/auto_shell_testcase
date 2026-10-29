#!/bin/bash
V=/data/iotdb/v20121rc5_1003_aaf460d
J="$V/lib/timechodb-server-2.0.12.1.jar"
echo "=== 工具可用性 ==="
which unzip jar java javac
echo "=== 主 jar 里的 API 类 ==="
jar tf "$J" 2>/dev/null | grep -E 'org/apache/iotdb/(udf/api/(UDTF|UDF|UDAF)|trigger/api/(Trigger|TriggerAttributes))\.class|org/apache/tsfile/enums/TSDataType\.class|org/apache/tsfile/write/record/Tablet\.class|udf/api/(collector/PointCollector|access/Row|access/RowWindow|customizer/config/UDTFConfigurations|customizer/parameter/UDFParameters|customizer/strategy/RowByRowAccessStrategy)\.class' | sort
echo "=== 模板里的 udf/trigger 默认目录 ==="
grep -inE 'udf|trigger' "$V/conf/iotdb-system.properties.template" 2>/dev/null | head -20
echo "=== 当前 conf 里是否有这些键 ==="
grep -inE 'udf|trigger' "$V/conf/iotdb-system.properties" | head
echo "=== ext/udf 与 ext/trigger 现状 ==="
ls -la "$V/ext/udf" "$V/ext/trigger"
