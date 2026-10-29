#!/bin/bash
# 探测 TIMESTAMP 类型序列的建/写语句可用写法（DT-01 场景有效性前置）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "probe_timestamp_${DATA_CONSENSUS}"
DB=root.dtprobe
BASE=$(( ($(date +%s) - 3600) * 1000 ))
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare
sq "drop database $DB;" >/dev/null 2>&1
sq "create database $DB;" >/dev/null
echo "### 建库响应: $(sq "show databases;" 2>&1 | grep -c dtprobe)"

echo "--- A. 默认（不写 encoding/compression）---"
for d in a1 a2; do
  echo "A/$d: $(sq "create timeseries $DB.$d.s1 with datatype=TIMESTAMP;" 2>&1 | tr '\n' ' ' | cut -c1-160)"
done
echo "A/plain: $(sq "create timeseries $DB.a3.s1 with datatype=TIMESTAMP, encoding=PLAIN, compression=UNCOMPRESSED;" 2>&1 | tr '\n' ' ' | cut -c1-160)"
echo "A/rle:   $(sq "create timeseries $DB.a4.s1 with datatype=TIMESTAMP, encoding=RLE, compression=SNAPPY;" 2>&1 | tr '\n' ' ' | cut -c1-160)"
echo "A/ts2:   $(sq "create timeseries $DB.a5.s1 with datatype=TIMESTAMP, encoding=TS_2DIFF, compression=LZ4;" 2>&1 | tr '\n' ' ' | cut -c1-160)"

echo "--- B. 写入写法（对 a1 逐个试）---"
echo "B1 引号 ISO:       $(sq "insert into $DB.a1(time,s1) values ($(( BASE + 100 )),'2026-01-01T00:00:00');" 2>&1 | tr '\n' ' ' | cut -c1-140)"
echo "B2 无引号 ISO:     $(sq "insert into $DB.a1(time,s1) values ($(( BASE + 110 )),2026-01-01T00:00:01);" 2>&1 | tr '\n' ' ' | cut -c1-140)"
echo "B3 引号 空格格式:  $(sq "insert into $DB.a1(time,s1) values ($(( BASE + 120 )),'2026-01-01 00:00:02');" 2>&1 | tr '\n' ' ' | cut -c1-140)"
echo "B4 引号 epoch ms:  $(sq "insert into $DB.a1(time,s1) values ($(( BASE + 130 )),'$(( BASE + 1000 ))');" 2>&1 | tr '\n' ' ' | cut -c1-140)"
echo "B5 无引号 epoch:   $(sq "insert into $DB.a1(time,s1) values ($(( BASE + 140 )),$(( BASE + 2000 )));" 2>&1 | tr '\n' ' ' | cut -c1-140)"
echo "B6 cast:           $(sq "insert into $DB.a1(time,s1) values ($(( BASE + 150 )),CAST('2026-01-01T00:00:03' AS TIMESTAMP));" 2>&1 | tr '\n' ' ' | cut -c1-140)"

echo "--- C. a1 当前内容 ---"
sq "select s1 from $DB.a1 order by time;" 2>&1 | grep -E '^\|' | cut -c1-120
echo "--- C. a2（无数据）类型 ---"
sq "show timeseries $DB.a2.s1;" 2>&1 | grep -E '^\|' | cut -c1-160

echo "--- D. 设备名与类型关键字同名时能否建序列（DT-01 失败根因核查）---"
for kw in INT32 INT64 FLOAT DOUBLE BOOLEAN TEXT STRING BLOB DATE TIMESTAMP; do
  r=$(sq "create timeseries $DB.$kw.s1 with datatype=INT32;" 2>&1 | tr '\n' ' ' | cut -c1-110)
  printf 'D/%s: %s\n' "$kw" "$r"
done
echo "--- D2. 加前缀的设备名 ---"
for kw in INT32 TIMESTAMP BLOB; do
  r=$(sq "create timeseries $DB.t_$kw.s1 with datatype=INT32;" 2>&1 | tr '\n' ' ' | cut -c1-110)
  printf 'D2/t_%s: %s\n' "$kw" "$r"
done
echo "--- E. TIMESTAMP 序列严格类型：同一序列用引号/无引号交替写 ---"
sq "create timeseries $DB.e1.s1 with datatype=TIMESTAMP;" >/dev/null 2>&1
echo "E1 无引号: $(sq "insert into $DB.e1(time,s1) values ($(( BASE + 300 )),2026-02-01T00:00:00);" 2>&1 | tr '\n' ' ' | cut -c1-120)"
echo "E2 引号:   $(sq "insert into $DB.e1(time,s1) values ($(( BASE + 310 )),'2026-02-01T00:00:01');" 2>&1 | tr '\n' ' ' | cut -c1-120)"
sq "select s1 from $DB.e1 order by time;" 2>&1 | grep -E '^\|' | cut -c1-120

