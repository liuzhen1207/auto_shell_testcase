#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0200
#   【TIMECHODB-0200】 【表模型V2.0.2.1-RC5】修改不存在的DB时，报305: String index out of range: -1
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：修改不存在的Database属性时，期望报该DB不存在  复现步骤 启动1C1D 进入CLI，执行如下SQL操作  --------------------- Starting IoTDB Cli -----------
# ============================================================================
RN0200_SQL=(
"alter database dba1 set properties TTL=3600000,SCHEMA_REGION_GROUP_NUM=2, DATA_REGION_GROUP_NUM=4"
)

case_RN0200() {
  local st out unexpected=0
  for st in "${RN0200_SQL[@]}"; do
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
"TIMECHODB-0200 自动抽取|TIMECHODB-0200|功能|表模型V2.0.2.1-RC5】修改不存在的DB时，报305: String index out of range:|case_RN0200"
)
