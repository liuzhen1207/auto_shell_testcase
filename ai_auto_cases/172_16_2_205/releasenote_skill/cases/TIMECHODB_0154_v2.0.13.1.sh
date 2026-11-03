#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0154
#   【TIMECHODB-0154】 【表注释列】指定注释为‘’时，查询报错301: Ratis request failed Unknown/301: Cannot invoke "java.util.Iterator.h
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：预期可正常操作  复现步骤 step1：启动实例，登录cli step2：创建数据库 create database ln2;并试用 use ln2; step3：创建表（注释列为‘’） CREATE TABLE tab
# ============================================================================
RN0154_SQL=(
"CREATE TABLE table_name ( column1 int32 COMMENT '', column2 int32 ) COMMENT ''"
)

case_RN0154() {
  local st out unexpected=0
  for st in "${RN0154_SQL[@]}"; do
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
"TIMECHODB-0154 自动抽取|TIMECHODB-0154|功能|表注释列】指定注释为‘’时，查询报错301: Ratis request failed Unknown/301: C|case_RN0154"
)
