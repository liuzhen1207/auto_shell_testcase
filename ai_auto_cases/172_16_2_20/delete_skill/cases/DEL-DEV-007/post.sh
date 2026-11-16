#!/bin/bash
# DEL-DEV-007 负向：DELETE DEVICES 带时间条件，文档明确"time condition is not supported"，应报错且数据不变
set -u
CLI=${CLI:?}; PW=${PW:?}; ART=${ART:?}
OUT=$ART/post.out; : > "$OUT"
timeout 60 "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" \
  -e "SET SQL_DIALECT=TABLE; DELETE DEVICES FROM del_dev007.t WHERE time <= 1796460000000;" >> "$OUT" 2>&1
err=$(grep -ciE 'exception|error|不支持|not support|invalid' "$OUT" || true)
timeout 60 "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" \
  -e "SET SQL_DIALECT=TABLE; SELECT count(*) FROM del_dev007.t;" >> "$OUT" 2>&1
echo "err_matches=$err" >> "$OUT"
[ "${err:-0}" -ge 1 ] || { echo "FAIL: 带时间条件的 DELETE DEVICES 未被拒绝" >> "$OUT"; exit 1; }
grep -qE '^\|[[:space:]]*2[[:space:]]*\|' "$OUT" || { echo "FAIL: 数据行数异常（应为 2）" >> "$OUT"; exit 1; }
echo "PASS: 带时间条件被拒绝且数据未变" >> "$OUT"