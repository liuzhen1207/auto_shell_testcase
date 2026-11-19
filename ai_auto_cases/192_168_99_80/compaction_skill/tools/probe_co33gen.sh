#!/bin/bash
# 只验证"未排序 TsFile 生成器"能否编译并产出文件（不碰集群）
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
export V_TESTDB=v20121rc7_1014_7c61428
echo "=== 1) 编译 ==="
D=$(bash "$S/assets/unsorted/build_gen.sh") || { echo "编译失败"; exit 1; }
echo "  编译目录：$D"
ls -l "$D"
CP="/data/iotdb/testdb/$V_TESTDB/lib/timechodb-server-2.0.12.1.jar:/data/iotdb/testdb/$V_TESTDB/lib/common-dependency.jar:$D"
echo "=== 2) 本地生成一个文件 ==="
rm -rf /tmp/c33_selftest; mkdir -p /tmp/c33_selftest
java -cp "$CP" UnsortedTsFileGen root.c33selftest.d1 /tmp/c33_selftest "$(date +%s%3N)" 0 11
echo "=== 3) 产物 ==="
ls -l /tmp/c33_selftest/
F=$(ls /tmp/c33_selftest/*.tsfile 2>/dev/null | head -1)
echo "  文件=$F 大小=$(stat -c %s "$F" 2>/dev/null)"
echo "=== 4) 文件内容里是否有设备路径字符串 ==="
strings "$F" 2>/dev/null | grep -c 'root.c33selftest' || true
echo "=== 5) 再生成第二个（同目录，验证文件名不冲突）==="
java -cp "$CP" UnsortedTsFileGen root.c33selftest.d1 /tmp/c33_selftest "$(date +%s%3N)" 2 21
ls -1 /tmp/c33_selftest/
