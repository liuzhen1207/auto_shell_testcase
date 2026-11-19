#!/bin/bash
# 只读诊断：DT-01 里 root.dtb.m1.s1 到底有没有数据 / 类型是什么
set -uo pipefail
cd /data/iotdb/autotest/compaction_skill || exit 1
. lib/common.sh; . lib/cmp.sh
cmp_load_env
for p in root.dtb.m1.s1 root.dtb.m2.s1 root.dtb.INT32.s1 root.dtb.m15.s1; do
  echo "== $p"
  echo -n "  show timeseries: "
  sq "show timeseries $p;" 2>&1 | grep -E '^\|' | tail -2 | tr '\n' ' ' | cut -c1-160; echo
  echo -n "  select: "
  sq "select s1 from $p order by time;" 2>&1 | grep -vE '^\+|Total line|It costs' | tail -4 | tr '\n' ' ' | cut -c1-200; echo
  echo -n "  行数(匹配 ^|[0-9]{4}-): "
  sq "select s1 from $p order by time;" 2>&1 | grep -cE '^\|[0-9]{4}-'
done
echo "== 该库所有序列"
sq "show timeseries root.dtb.**;" 2>&1 | grep -E '^\|' | head -8 | cut -c1-140
