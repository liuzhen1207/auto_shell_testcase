#!/bin/bash
# 最小复现：树模型"建序列→写→flush→查询"到底能不能查到（校验 DT-01 的行数判据）
set -uo pipefail
cd /data/iotdb/autotest/compaction_skill || exit 1
. lib/common.sh; . lib/cmp.sh
cmp_load_env
DB=root.dtmin
BASE=$(( ($(date +%s%3N) - 3600000) ))
sq "create database $DB;" >/dev/null
echo "建序列: $(sq "create timeseries $DB.m1.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" 2>&1 | tail -1)"
echo "写入: $(sq "insert into $DB.m1(time,s1) values ($(( BASE + 100 )),42),($(( BASE + 110 )),43);" 2>&1 | tail -1)"
echo "阻塞 flush: $(sq "flush;" 2>&1 | tail -1)"
sleep 8
echo "--- 查询原始输出（select s1 from $DB.m1.s1 order by time;）---"
sq "select s1 from $DB.m1.s1 order by time;" 2>&1 | head -8 | cat -A | cut -c1-120
echo "--- 行数（^\\|[0-9]{4}-）: $(sq "select s1 from $DB.m1.s1 order by time;" 2>&1 | grep -cE '^\|[0-9]{4}-')"
echo "--- 用 row_sum/count 判据: $(row_sum "$(sq "select count(s1) from $DB.**;")")"
echo "--- data_rows 判据: $(sq "select s1 from $DB.m1.s1 order by time;" 2>&1 | data_rows | wc -l)"
echo "--- show timeseries: $(sq "show timeseries $DB.m1.s1;" 2>&1 | grep -cE '^\|root')"
