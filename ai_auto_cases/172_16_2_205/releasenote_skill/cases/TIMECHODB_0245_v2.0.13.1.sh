#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0245
#   【TIMECHODB-0245】 【表模型】普通用户拥有INSERT权限，通过export-schema.sh导出元数据异常
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：普通用户拥有该表或所属DB以及ANY范围的任意权限，通过export-schema.sh导出元数据正常  复现步骤 启动1C1D root进入CLI  create user user01 'pass1234' gran
# ============================================================================
RN0245_SQL=(
"create user user01 'pass1234'"
"grant insert on any to user user01"
"list privileges of user user01"
"show databases"
"show tables from test_db"
"desc test_db.t1"
)

case_RN0245() {
  local st out unexpected=0
  for st in "${RN0245_SQL[@]}"; do
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
"TIMECHODB-0245 自动抽取|TIMECHODB-0245|功能|表模型】普通用户拥有INSERT权限，通过export-schema.sh导出元数据异常|case_RN0245"
)
