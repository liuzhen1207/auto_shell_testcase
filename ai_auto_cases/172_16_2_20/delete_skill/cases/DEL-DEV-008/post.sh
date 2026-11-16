#!/bin/bash
# DEL-DEV-008 负向：DELETE DEVICES 目标表不存在，文档要求"The table for the device to delete must exist."
set -u
CLI=${CLI:?}; PW=${PW:?}; ART=${ART:?}
OUT=$ART/post.out; : > "$OUT"
timeout 60 "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" \
  -e "SET SQL_DIALECT=TABLE; DELETE DEVICES FROM del_dev_not_exist.t WHERE dev='dev01';" >> "$OUT" 2>&1
err=$(grep -ciE 'exception|error|not exist|不存在' "$OUT" || true)
echo "err_matches=$err" >> "$OUT"
[ "${err:-0}" -ge 1 ] || { echo "FAIL: 表不存在时 DELETE DEVICES 未报错" >> "$OUT"; exit 1; }
echo "PASS: 表不存在时按预期报错" >> "$OUT"