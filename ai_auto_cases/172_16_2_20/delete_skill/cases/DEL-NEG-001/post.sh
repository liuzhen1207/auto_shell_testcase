#!/bin/bash
# DEL-NEG-001 权限负向：普通用户（仅 SELECT 权限）执行 DELETE 必须被拒绝且数据不变
# 由 run_round.sh 在用例 SQL 之后调用；环境变量 CLI / PW / ART 由执行器提供
set -u
CLI=${CLI:?}
PW=${PW:?}
ART=${ART:?}
U=del_neg_reader
UP='Del@2026password'
OUT=$ART/post.out
: > "$OUT"

echo "=== step1: 普通用户 $U 执行 DELETE（应被拒绝）===" >> "$OUT"
timeout 60 "$CLI" -h 172.16.2.19 -p 6667 -u "$U" -pw "$UP" \
  -e "SET SQL_DIALECT=TABLE; DELETE FROM del_rc10_neg001.t WHERE time = 1799600000000;" >> "$OUT" 2>&1
deny=$(grep -c 'Access Denied' "$OUT" || true)

echo "=== step2: 普通用户 $U 执行 SELECT（应有权限）===" >> "$OUT"
timeout 60 "$CLI" -h 172.16.2.19 -p 6667 -u "$U" -pw "$UP" \
  -e "SET SQL_DIALECT=TABLE; SELECT time,device_id,v FROM del_rc10_neg001.t ORDER BY time;" >> "$OUT" 2>&1

echo "=== step3: root 复核数据未被修改 ===" >> "$OUT"
timeout 60 "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" \
  -e "SET SQL_DIALECT=TABLE; SELECT time,device_id,v FROM del_rc10_neg001.t ORDER BY time;" >> "$OUT" 2>&1

data_rows=$(grep -c '^|19\|^|20[0-9][0-9]' "$OUT" || true)
echo "denied_matches=$deny data_rows=$data_rows" >> "$OUT"

if [ "${deny:-0}" -lt 1 ]; then
  echo "FAIL: DELETE 未被拒绝（未出现 Access Denied）" >> "$OUT"
  exit 1
fi
if [ "${data_rows:-0}" -ne 18 ]; then
  echo "FAIL: 数据行数异常（期望 18 = step2 的 9 行 + step3 的 9 行，实际 $data_rows）" >> "$OUT"
  exit 1
fi
echo "PASS: 权限拒绝生效且数据未被修改" >> "$OUT"
exit 0
