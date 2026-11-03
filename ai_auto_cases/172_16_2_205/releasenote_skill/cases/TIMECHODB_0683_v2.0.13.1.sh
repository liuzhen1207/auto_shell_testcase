#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0683】表模型 date_bin 执行时间过滤查询时报 301 异常
#   根因：过滤条件 time >= 2 and time < 1 匹配不到任何时间范围，
#         getTimeRanges 返回空 List，用 Long.MAX/MIN 构造 TimeRange 抛异常
#   修复：initQueryDataSource 时若 queryDataSource 为空则提前返回空结果
#   验证版本：2.0.13.1 / ab6d3de
#   判据：①空时间区间查询返回 0 行、不报 301 ②正常 date_bin 分组查询结果正确
# ============================================================================
RN0683_DB=rn0683_db

case_RN103() {
  local out
  Q "DROP DATABASE IF EXISTS $RN0683_DB" >/dev/null 2>&1
  out=$(Q "CREATE DATABASE $RN0683_DB"); assert_ok "$out" "建库"

  out=$(Q "CREATE TABLE $RN0683_DB.table_1(region_id STRING TAG, device_id STRING TAG, model_id STRING ATTRIBUTE, boolean BOOLEAN FIELD, text TEXT FIELD, string STRING FIELD, date DATE FIELD, timestamp TIMESTAMP FIELD, blob BLOB FIELD, int32 INT32 FIELD, int64 INT64 FIELD, float FLOAT FIELD, double DOUBLE FIELD)")
  assert_ok "$out" "建表（含 ATTRIBUTE / BLOB / TEXT 等）"

  out=$(Q "INSERT INTO $RN0683_DB.table_1(time, region_id, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double) VALUES (1,'001','d1','V1',false,'text1','string1','2020-01-10',1704874210000,X'11F8d7',1,1000,1.1,111.11)")
  assert_ok "$out" "写入第 1 行（十列全量）"

  out=$(Q "INSERT INTO $RN0683_DB.table_1(time, region_id, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double) VALUES (2,'002','d2','V2',true,'text2','string2','2020-02-20',1706698230000,X'3b',2,453,11.1,102.2)")
  assert_ok "$out" "写入第 2 行"

  out=$(Q "INSERT INTO $RN0683_DB.table_1(time, timestamp) VALUES (-132340800000,-132340800000),(1000,1719754343000),(1704874210000,1727276981000)")
  assert_ok "$out" "写入负时间戳/边界行"

  # 1) 空时间区间：修复前报 301，修复后返回空结果
  out=$(Q "SELECT date_bin(5ms, time) AS t, region_id, int32, int64, avg(float) AS avg_value FROM $RN0683_DB.table_1 WHERE time >= 2 AND time < 1 GROUP BY 1,2,3,4")
  echo "  空区间查询：$(echo "$out" | head -3 | tr '\n' ' ' | cut -c1-200)"
  if echo "$out" | grep -q '301'; then
    fail "空时间区间仍报 301"
  else
    ok "空时间区间未报 301"
  fi
  if echo "$out" | grep -qiE 'error|exception'; then
    fail "空时间区间应返回空结果而不是报错（实际 $(echo "$out" | head -1 | cut -c1-120)）"
  else
    ok "空时间区间返回空结果"
  fi

  # 2) 对照：有数据的时间区间应正常返回
  out=$(Q "SELECT date_bin(5ms, time) AS t, region_id, device_id, int32 FROM $RN0683_DB.table_1 WHERE time >= 1 AND time <= 2 ORDER BY device_id")
  if echo "$out" | grep -q 'd1' && echo "$out" | grep -q 'd2'; then
    ok "对照：date_bin 正常区间返回 d1/d2 两行"
  else
    fail "对照：正常区间查询结果异常（$(echo "$out" | tr '\n' ' ' | cut -c1-160)）"
  fi

  Q "DROP DATABASE IF EXISTS $RN0683_DB" >/dev/null 2>&1
}

CASES+=(
"RN-103|TIMECHODB-0683 date_bin|功能|空时间区间（time>=2 and time<1）查询不应报 301，应返回空结果|case_RN103"
)
