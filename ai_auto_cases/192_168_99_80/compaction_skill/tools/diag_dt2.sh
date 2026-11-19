#!/bin/bash
# 定点：为什么 DT 用例里"写成功但查不到数据"——打印每一步的**原始**输出
set -uo pipefail
cd /data/iotdb/autotest/compaction_skill || exit 1
. lib/common.sh; . lib/cmp.sh
cmp_load_env; cmp_parse_args
cmp_case_init "diag_dt2"
export EXTRA_CONF="$CMP_EXTRA_WRITE"
cmp_cluster_prepare
DB=root.dtd
BASE=$(( ($(date +%s%3N) - 3600000) ))
NOW=$(date +%s%3N)
echo "=== 1) 建库/建序列 ==="
echo "  create db : $(sq "create database $DB;" 2>&1 | tail -1)"
echo "  create ts : $(sq "create timeseries $DB.m1.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" 2>&1 | tail -1)"
echo "=== 2) 写入（过去时间戳 BASE+100/110）==="
echo "  写响应    : $(sq "insert into $DB.m1(time,s1) values ($(( BASE + 100 )),42),($(( BASE + 110 )),43);" 2>&1 | tail -1)"
echo "  flush     : $(sq "flush;" 2>&1 | tail -1)"
sleep 8
echo "=== 3) 查询原始输出 ==="
echo "  --- select s1 from $DB.m1.s1 order by time;"
sq "select s1 from $DB.m1.s1 order by time;" 2>&1 | head -8 | sed 's/^/    /'
echo "  --- select count(s1) from $DB.**;"
sq "select count(s1) from $DB.**;" 2>&1 | head -6 | sed 's/^/    /'
echo "  --- show timeseries $DB.m1.s1;"
sq "show timeseries $DB.m1.s1;" 2>&1 | head -6 | sed 's/^/    /'
echo "  --- row_sum count = $(row_sum "$(sq "select count(s1) from $DB.**;")")"
echo "  --- cmp_vals_series = [$(cmp_vals_series "$DB.m1.s1" 3)]"
echo "=== 4) 用"当前时间"时间戳再写一次（对比）==="
echo "  写响应    : $(sq "insert into $DB.m1(time,s1) values ($(( NOW + 1000 )),77);" 2>&1 | tail -1)"
sq "flush;" >/dev/null; sleep 8
sq "select s1 from $DB.m1.s1 order by time;" 2>&1 | head -8 | sed 's/^/    /'
echo "  --- 布局=$(cmp_lay "$DB")"
for h in "${DN[@]}"; do echo "  --- $h 上的文件: $(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | tr '\n' ' '")"; done
echo "### 结束 $(date '+%F %T')"
