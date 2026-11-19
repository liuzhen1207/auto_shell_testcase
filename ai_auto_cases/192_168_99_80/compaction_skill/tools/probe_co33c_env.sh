#!/bin/bash
# 侦察：RC7 服务端 jar 中是否含 org.apache.tsfile 写文件 API、JDK 是否可用、
# 以及 START REPAIR DATA 语句在该版本是否可解析（只查文件，不动集群）
set -uo pipefail
VER=v20121rc7_1014_7c61428
D=/data/iotdb/testdb/$VER
echo "=== 1) 版本目录 / jar ==="
ls -d $D 2>/dev/null || echo "  !! 版本目录不存在"
ls $D/lib 2>/dev/null | grep -i -e tsfile -e iotdb | head -20
echo "=== 2) org.apache.tsfile 写 API 是否在 jar 里 ==="
for j in $D/lib/*.jar; do
  if unzip -l "$j" 2>/dev/null | grep -q 'org/apache/tsfile/write/writer/TsFileIOWriter.class'; then
    echo "  TsFileIOWriter -> $j"
  fi
  if unzip -l "$j" 2>/dev/null | grep -q 'org/apache/tsfile/write/chunk/ChunkWriterImpl.class'; then
    echo "  ChunkWriterImpl -> $j"
  fi
  if unzip -l "$j" 2>/dev/null | grep -q 'org/apache/tsfile/file/metadata/IDeviceID.class'; then
    echo "  IDeviceID        -> $j"
  fi
done
echo "=== 3) JDK ==="
which javac java 2>/dev/null
javac -version 2>&1 | head -2
java -version 2>&1 | head -2
echo "=== 4) 服务端自带 JDK（镜像里通常有） ==="
ls -d $D/jdk* $D/*/jdk* 2>/dev/null | head
find $D -maxdepth 3 -name javac -type f 2>/dev/null | head -3
echo "=== 5) START REPAIR DATA 语句在 SQL 语法里 ==="
CLI=/data/iotdb/testdb/$VER/sbin/start-cli.sh
ls -l $CLI 2>/dev/null || echo "  !! 无 CLI"
echo "=== 6) runner 进度 ==="
tail -n 5 /tmp/rc7_sets.log
grep -c '^\[.*CO-' /tmp/rc7_sets.log 2>/dev/null
