#!/bin/bash
# DEL-NEG-005 负向：标识条件用 > ，文档"Only = supported in identifier condition"，应报错
set -u
CLI=${CLI:?}; PW=${PW:?}; ART=${ART:?}
OUT=$ART/post.out; : > "$OUT"
timeout 60 "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" \
  -e "SET SQL_DIALECT=TABLE; DELETE FROM del_neg005.t WHERE time < 1796490000001 AND dev > 'dev00';" >> "$OUT" 2>&1
err=$(grep -ciE 'exception|error|not support|不支持|invalid|Unsupported|expecting' "$OUT" || true)
echo "err_matches=$err" >> "$OUT"
[ "${err:-0}" -ge 1 ] || { echo "FAIL: 标识条件非 = 未被拒绝" >> "$OUT"; exit 1; }
echo "PASS: 标识条件非 = 被拒绝" >> "$OUT"