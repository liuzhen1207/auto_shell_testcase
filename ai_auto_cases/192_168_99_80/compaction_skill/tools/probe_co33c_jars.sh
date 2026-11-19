#!/bin/bash
set -uo pipefail
V=/data/iotdb/testdb/v20121rc7_1014_7c61428
echo "=== lib/*.jar ==="
ls -l $V/lib/*.jar 2>/dev/null | head -40
echo "=== lib/bootstrap ==="
ls -l $V/lib/bootstrap 2>/dev/null | head -20
echo "=== all jars under V (depth<=4) ==="
find $V -maxdepth 4 -name '*.jar' 2>/dev/null | head -40
echo "=== search TsFileIOWriter / ChunkWriterImpl / IDeviceID in all jars ==="
for j in $(find $V -maxdepth 4 -name '*.jar' 2>/dev/null); do
  lst=$(unzip -l "$j" 2>/dev/null)
  case "$lst" in
    *org/apache/tsfile/write/writer/TsFileIOWriter.class*) echo "  TsFileIOWriter -> $j";;
  esac
  case "$lst" in
    *org/apache/tsfile/write/chunk/ChunkWriterImpl.class*) echo "  ChunkWriterImpl -> $j";;
  esac
  case "$lst" in
    *org/apache/tsfile/file/metadata/IDeviceID.class*)     echo "  IDeviceID       -> $j";;
  esac
  case "$lst" in
    *org/apache/tsfile/write/schema/MeasurementSchema.class*) echo "  MeasurementSchema -> $j";;
  esac
done
echo "=== 节点上的版本目录（.77）==="
ssh -n -o StrictHostKeyChecking=no root@192.168.99.77 "ls -d /data/iotdb/$V 2>/dev/null; ls /data/iotdb/$V/lib 2>/dev/null | head -5" 2>&1 | head -10
