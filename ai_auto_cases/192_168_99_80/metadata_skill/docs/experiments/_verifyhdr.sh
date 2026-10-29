#!/bin/bash
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env >/dev/null 2>&1
OUT=$(cat /tmp/show_ts.txt)
echo "table_rows 行数 : $(printf '%s\n' "$OUT" | table_rows | wc -l)"
echo "md_rows 行数    : $(md_rows "$OUT" | wc -l)"
echo "md_names 数量   : $(md_names "$OUT" | wc -l)"
echo "md_names 含表头 : $(md_names "$OUT" | grep -cx Timeseries)"
echo "md_names 首个   : $(md_names "$OUT" | head -1)"
