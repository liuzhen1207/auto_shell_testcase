#!/bin/bash
# DEL-NEG-004 负向：DELETE FROM 带 measurement 条件，文档"No measurement condition allowed"，应报错且数据不变
set -u
CLI=${CLI:?}; PW=${PW:?}; ART=${ART:?}
OUT=$ART/post.out; : > "$OUT"
timeout 60 "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" \
  -e "SET SQL_DIALECT=TABLE; DELETE FROM del_neg004.t WHERE v <= 300 AND v > 0;" >> "$OUT" 2>&1
err=$(grep -ciE 'exception|error|not support|不支持|invalid|Unsupported' "$OUT" || true)
echo "err_matches=$err" >> "$OUT"
[ "${err:-0}" -ge 1 ] || { echo "FAIL: measurement 条件未被拒绝" >> "$OUT"; exit 1; }
echo "PASS: measurement 条件被拒绝" >> "$OUT"