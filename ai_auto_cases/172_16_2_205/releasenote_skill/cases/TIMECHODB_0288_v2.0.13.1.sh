#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0288
#   【TIMECHODB-0288】 【表模型V2.0.4.1-RC1】APPROX_COUNT_DISTINCT指定标准误差最小值时，执行查询结果报异常
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：聚合函数APPROX_COUNT_DISTINCT指定标准误差最小值时，查询结果集显示正确  复现步骤 （1）启动1C1D （2）进入CLI，执行SQL操作  -- 准备数据 --1. 创建数据库 create data
# ============================================================================
RN0288_SQL=(
"create database test_db"
"show database"
"create table table_1"
"show tables"
"desc table_1"
"insert into table_1( time, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double ) values(1, 'd1', 'V1', false, 'text1', 'string1', '2020-01-10', 100000, X'11F8d7', 0, 1000, 1.1, 111.11)"
"insert into table_1( time, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double ) values(2, 'd2', 'V2', true, 'text2', 'string2', '2020-02-20', 16839200, X'3b', 111, 453, 11.1, 102.2)"
"insert into table_1( time, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double ) values(3, 'd3', 'V3', true, 'text2', 'string2', '2021-12-20', 116839200000, X'6728', 1, 123, 5.2, 333.3)"
"insert into table_1( time, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double ) values(4, 'd4', 'V4', false, 'text3', 'string3', '2022-06-11', 86700000, X'4b98', 2, 239, null, 666.66)"
"insert into table_1( time, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double ) values(5, 'd5', 'V3', false, 'text4', 'string2', '2023-12-15', 1378230000000, X'34', 10, 653, -1.1, 1111.2)"
"insert into table_1( time, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double ) values(6, 'd6', 'V2', true, 'text3', 'string3', null, 1378230000000, X'00010000', 1, 653, 0.1, 1221.2)"
"insert into table_1( time, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double ) values(7, 'd5', 'V3', true, 'text4', 'string4', '2023-12-15', 1378230000000, X'FFD8FFE0', 2, null, 555.5, 1111.2)"
"insert into table_1( time, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double ) values(8, 'd3', 'V5', true, 'text2', 'string5', null, 1378230000000, X'34', 2, 653, 13.13, null)"
"insert into table_1( time, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double ) values(9, 'd3', 'V6', true, 'text4', null, '2023-12-15', null, X'49460001', 10, null, 2.1, 155.5)"
"insert into table_1( time, device_id, model_id, boolean, text, string, date, timestamp, blob, int32, int64, float, double ) values(10, 'd4', 'V2', false, 'text5', 'string3', '2024-01-15', 18392378000, null, 1, null, -11.1, 11.2)"
)

case_RN0288() {
  local st out unexpected=0
  for st in "${RN0288_SQL[@]}"; do
    out=$( T "$st" )
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
"TIMECHODB-0288 自动抽取|TIMECHODB-0288|功能|表模型V2.0.4.1-RC1】APPROX_COUNT_DISTINCT指定标准误差最小值时，执行查询结果报异常|case_RN0288"
)
