#!/bin/bash
# 在 205 上手工编译并运行 4 个 TDB-453 单测（JUnit4 + Mockito）
set -u
B=/data2/iotdb/v20131rc1_1030_ab6d3de
W=/data2/auto_test/tdb453_tests
mkdir -p "$W/src" "$W/out"
cd "$W" || exit 1

CP="$B/lib/timechodb-server-2.0.13.1.jar:$B/lib/common-dependency.jar"
for j in "$W"/libs/*.jar; do [ -f "$j" ] && CP="$CP:$j"; done

echo "=== 编译 4 个测试 ==="
SRC="$W/src/org/apache/iotdb/db/storageengine/dataregion/tsfile/TsFileLockTest.java \
$W/src/org/apache/iotdb/db/storageengine/dataregion/read/control/FileReaderManagerConcurrencyTest.java \
$W/src/org/apache/iotdb/db/queryengine/execution/fragment/RegionQueryInitializationLockTest.java \
$W/src/org/apache/iotdb/db/queryengine/execution/fragment/FileReaderReferenceLifecycleTest.java"
javac -encoding UTF-8 -nowarn -cp "$CP" -d out $SRC 2>&1 | head -20
echo "编译产物: $(find out -name '*.class' | wc -l) 个"

echo
echo "=== 运行 ==="
JOPTS="--add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.util=ALL-UNNAMED --add-opens java.base/java.nio=ALL-UNNAMED --add-opens java.base/sun.nio.ch=ALL-UNNAMED -Djava.io.tmpdir=$W/tmp"
mkdir -p "$W/tmp"
for c in \
  org.apache.iotdb.db.storageengine.dataregion.tsfile.TsFileLockTest \
  org.apache.iotdb.db.storageengine.dataregion.read.control.FileReaderManagerConcurrencyTest \
  org.apache.iotdb.db.queryengine.execution.fragment.RegionQueryInitializationLockTest \
  org.apache.iotdb.db.queryengine.execution.fragment.FileReaderReferenceLifecycleTest ; do
  echo "---------- $c"
  java $JOPTS -cp "out:$CP" org.junit.runner.JUnitCore "$c" 2>&1 | tail -12
done
