#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0536
#   【TIMECHODB-0536】 【位操作函数】对于null值处理和trino不一致，部分函数之间也不一致
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：需要确认对各种情况null值的处理方式  复现步骤 以bit_count函数为例 IoTDB  create table table1(t1 STRING TAG, a1 STRING ATTRIBUTE, s1 TEX
# ============================================================================
RN0536_SQL=(
"create table table1(t1 STRING TAG, a1 STRING ATTRIBUTE, s1 TEXT FIELD, s2 INT32 FIELD, s3 INT64 FIELD, s4 FLOAT FIELD, s5 DOUBLE FIELD, s6 BOOLEAN FIELD, s7 DATE FIELD, s8 TIMESTAMP FIELD, s9 STRING FIELD, s10 BLOB FIELD)"
"insert into table1(time, t1, a1, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10) values(1, 't1', 'a1', 's1', null, null, 1.1, 1.1, null, '2020-02-29', 1970-01-01 08:00:00.005, '2025-02-01 08:01:59.123456789', null)"
"insert into table1(time, t1, a1, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10) values(2, null, 'a2', 's2', null, null, 2.2, null, false, null, 1970-01-01 08:00:00.015, '2025-02-02 08:02:59.123456789', null)"
"insert into table1(time, t1, a1, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10) values(3, 't3', null, 's3', null, null, null, 3.3, true, '2025-02-03', null, '2025-02-03 08:03:59.123456789', null)"
"insert into table1(time, t1, a1, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10) values(4, 't4', 'a4', null, null, null, 4.4, 4.4, true, '2025-02-04', 1970-01-01 08:00:00.035, null, null)"
"insert into table1(time, t1, a1, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10) values(5, 't5', 'a5', 's5', null, null, 5.5, 5.5, true, '2021-02-28', 1970-01-01 08:00:00.045, '2025-02-05 08:05:59.123456789', null)"
"select bit_count(null, 8) from table1"
"select s2, bit_count(s2, 8) from table1 order by time"
"CREATE TABLE IF NOT EXISTS table1 (s1 INT, s2 BIGINT)"
"INSERT INTO table1 (s1, s2) VALUES(NULL, NULL),(NULL, NULL),(NULL, NULL),(NULL, NULL),(NULL, NULL)"
"select s1, bit_count(s1, 8) from table1"
)

case_RN0536() {
  local st out unexpected=0
  for st in "${RN0536_SQL[@]}"; do
    out=$( Q "$st" )
    # 幂等：对象已存在视为可接受
    if echo "$out" | grep -qiE 'already exists|already been created'; then
      ok "已存在(幂等): $(echo "$st" | cut -c1-55)"; continue
    fi
    if echo "$out" | grep -qiE 'Exception|ERROR|internal error|NullPointerException'; then
      unexpected=$((unexpected+1))
      fail "$(echo "$st" | cut -c1-65) -> $(echo "$out" | head -1 | cut -c1-110)"
    else
      ok "$(echo "$st" | cut -c1-55)"
    fi
  done
}

CASES+=(
"TIMECHODB-0536 自动抽取|TIMECHODB-0536|功能|位操作函数】对于null值处理和trino不一致，部分函数之间也不一致|case_RN0536"
)
