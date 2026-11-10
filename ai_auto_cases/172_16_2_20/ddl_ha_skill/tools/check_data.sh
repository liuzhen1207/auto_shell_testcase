#!/bin/bash
# check_data.sh <case_dir> <db>
# 校验：5 台 DN 上行数 / 按设备分组计数是否一致
set -u
. "$(dirname "$0")/lib.sh"

CASE_DIR=$1; DB=$2
OUT=$CASE_DIR/data-consistency.txt
: > "$OUT"
sig=$CASE_DIR/.data-sig
: > "$sig"

for n in $DNS; do
  cnt=$(qdn "$n" "SELECT count(*) FROM $DB.t;" 2>&1 | rows_only | head -n1)
  grp=$(qdn "$n" "SELECT dev, count(*) FROM $DB.t GROUP BY dev ORDER BY dev;" 2>&1 | rows_only | tr '\n' ';')
  echo "DN$n|count=$cnt|group=$grp" >> "$OUT"
  printf '%s\n' "count=$cnt|group=$grp" >> "$sig"
done

uniq_cnt=$(sort -u "$sig" | wc -l)
rm -f "$sig"
if [ "$uniq_cnt" -eq 1 ]; then echo "DATA_CONSISTENT=YES" >> "$OUT"; else echo "DATA_CONSISTENT=NO" >> "$OUT"; fi
