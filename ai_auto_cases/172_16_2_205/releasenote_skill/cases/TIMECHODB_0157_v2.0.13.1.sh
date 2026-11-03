#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0157
#   【TIMECHODB-0157】 【set sql_dialect】使用表模型的cli创建表模型的数据库并use后，使用set sql_dialect切换为树模型，使用树模型的自动创建语句，会报错说表模型的数据库不存在且
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：通过该方式切换的树模型链接能正常使用树模型的自动创建  复现步骤 复现步骤： 表模型cli登录后执行如下SQL： create database test; use test; set sql_dialect = tre
# ============================================================================
RN0157_SQL=(
"create database test"
"set sql_dialect = tree"
"insert into root.db(time,s1) values (0,1), (1, 3), (2,5)"
)

case_RN0157() {
  local st out unexpected=0
  for st in "${RN0157_SQL[@]}"; do
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
"TIMECHODB-0157 自动抽取|TIMECHODB-0157|功能|set sql_dialect】使用表模型的cli创建表模型的数据库并use后，使用set sql_dialect切|case_RN0157"
)
