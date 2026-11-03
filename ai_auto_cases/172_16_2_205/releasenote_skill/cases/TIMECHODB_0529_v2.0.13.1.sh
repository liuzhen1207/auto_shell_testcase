#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0529
#   【TIMECHODB-0529】 【v2.0.6.1】MATCH_RECOGNIZE DEFINE不支持字符串过滤
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：预期可以查询  复现步骤   create database test_db; use test_db;  create table orders(customer_id TAG,region ATTRIBUTE,ord
# ============================================================================
RN0529_SQL=(
"create database test_db"
"create table orders(customer_id TAG,region ATTRIBUTE,order_date DATE,product TEXT,status BOOLEAN,number INT64,totalprice DOUBLE)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748736000000, '100', 'beijing', '2025-06-01', 'table', true, 100, 55000.5)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748736600000, '100', 'beijing', '2025-06-01', 'table', true, 255, 13200.3)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748737200000, '100', 'beijing', '2025-06-01', 'table', true, 888, 12400)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748737800000, '100', 'beijing', '2025-06-01', 'table', true, 55, 9998.3)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748739600000, '100', 'beijing', '2025-06-01', 'table', true, 666, 9998.3)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748822400000, '101', 'shanghai', '2025-06-02', 'door', false, 608, 12350.5)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748826000000, '101', 'shanghai', '2025-06-02', 'door', true, 1000, 667849.9)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748831400000, '101', 'shanghai', '2025-06-02', 'door', true, 360, 33920.5)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748835000000, '101', 'shanghai', '2025-06-02', 'door', true, 150, 33920.5)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748923200000, '100', 'beijing', '2025-06-03', 'table', true, 150, 11230.4)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748923300000, '101', 'beijing', '2025-06-04', 'table', true, 50, 55000.00)"
"insert into orders(time, customer_id, region, order_date, product, status, number, totalprice) values(1748924300000, '102', 'beijing', '2025-06-05', 'table', true, 50, 65000.00)"
"SELECT m.match, m.count_total FROM orders"
"COUNT(totalprice) AS count_total"
)

case_RN0529() {
  local st out unexpected=0
  for st in "${RN0529_SQL[@]}"; do
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
"TIMECHODB-0529 自动抽取|TIMECHODB-0529|功能|v2.0.6.1】MATCH_RECOGNIZE DEFINE不支持字符串过滤|case_RN0529"
)
