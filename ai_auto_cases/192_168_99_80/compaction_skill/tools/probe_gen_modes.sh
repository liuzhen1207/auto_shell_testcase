#!/bin/bash
# 验证生成器三种模式都能产出 TsFile（不碰集群）
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
export V_TESTDB=v20121rc7_1014_7c61428
CP="/data/iotdb/testdb/$V_TESTDB/lib/timechodb-server-2.0.12.1.jar:/data/iotdb/testdb/$V_TESTDB/lib/common-dependency.jar:$S/assets/unsorted/build"
bash "$S/assets/unsorted/build_gen.sh" >/dev/null 2>&1 || { echo "编译失败"; exit 1; }
for m in unsorted dup pages; do
  rm -rf /tmp/c33_m; mkdir -p /tmp/c33_m
  if java -cp "$CP" UnsortedTsFileGen root.c33m.d1 /tmp/c33_m "$(date +%s%3N)" 0 11 "$m" >/dev/null 2>&1; then
    f=$(ls /tmp/c33_m/*.tsfile 2>/dev/null | head -1)
    if [ -n "$f" ]; then echo "  mode=$m  OK  $(stat -c %s "$f") B  $(basename "$f")"; else echo "  mode=$m  !! 没有产出文件"; fi
  else
    echo "  mode=$m  !! java 执行失败"
  fi
done
