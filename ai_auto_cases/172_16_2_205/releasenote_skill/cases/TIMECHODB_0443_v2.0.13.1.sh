#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0443
#   【TIMECHODB-0443】 【树模型SQL】同一表达式在case when子句中与子句外，其对应结果不一致
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：同一表达式在case when子句中与子句外，其对应结果显示一致，数值且显示正确 复现步骤 （1）V2.0.5.1版本的IoTDB，启动1C1D （2）root用户进入CLI，执行SQL操作   [root@xzh-93
# ============================================================================
RN0443_SQL=(
"show cluster"
"create timeseries root.tpms.MP_TJ_WSM_010.FluxFlow datatype=INT64 encoding=TS_2DIFF"
"insert into root.tpms.MP_TJ_WSM_010(time,FluxFlow) values(2025-06-26 10:50:20,40),(2025-06-26 10:50:22,50)"
)

case_RN0443() {
  local st out unexpected=0
  for st in "${RN0443_SQL[@]}"; do
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
"TIMECHODB-0443 自动抽取|TIMECHODB-0443|功能|树模型SQL】同一表达式在case when子句中与子句外，其对应结果不一致|case_RN0443"
)
