#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0259
#   【TIMECHODB-0259】 【spark-iotdb-table-connector】使用spark-sql写iotdb时，类型转换错误
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤 启动iotdb，注册元数据  create database timecho; use timecho; create table t1(t1 tag,a1 attribute,s1 int32, s2 int
# ============================================================================
RN0259_SQL=(
"create database timecho"
"create table t1(t1 tag,a1 attribute,s1 int32, s2 int64,s3 double,s4 float,s5 text,s6 boolean ,s7 string, s8 date, s9 timestamp,s10 blob)"
"CREATE TEMPORARY VIEW spark_iotdb1 USING org.apache.iotdb.spark.table.db.IoTDBTableProvider OPTIONS(\"iotdb.database\"=\"timecho\",\"iotdb.table\"=\"t1\",\"iotdb.username\"=\"root\",\"iotdb.password\"=\"root\",\"iotdb.urls\"=\"172.20.31.16:6667\")"
"INSERT INTO spark_iotdb1 VALUES (1745460332784,\"device_view\",\"view\",1,23123,3.38913821,2.5,\"null\",true,\"null\",null,1745460332784,null)"
)

case_RN0259() {
  local st out unexpected=0
  for st in "${RN0259_SQL[@]}"; do
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
"TIMECHODB-0259 自动抽取|TIMECHODB-0259|功能|spark-iotdb-table-connector】使用spark-sql写iotdb时，类型转换错误|case_RN0259"
)
