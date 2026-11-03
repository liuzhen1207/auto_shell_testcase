#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0124
#   【TIMECHODB-0124】 【OPC DA】 Cannot invoke "org.apache.tsfile.utils.Binary.toString()" because "column[rowIndex]"
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：不报错。 复现步骤 以下所有操作都在windows10操作系统下进行。 以上为常规步骤 打开“OPC Server Simulator”， 空白处右键->“Add row”，修改name为“root.g1.d1.s1”，
# ============================================================================
RN0124_SQL=(
"create pipe opc ('sink'='opc-da-sink', 'opcda.clsid'='CAE8D0E1-117B-11D5-924B-11C0F023E91C')，不报错"
"insert into root.g1.d1(time,s1,s2) values(now(),\"s1-1\",\"s2-1\")，报错如下，且opc-client的数据不会更新"
"insert into root.g1.d1(time,s1,s2) values(now(),\"s1-2\",\"s2-2\")，不再报错，且数据更新"
"insert into root.g1.d1(time,s1,s2) values(now(),\"s1-1\",\"s2-1\")"
"create pipe opc ('sink'='opc-da-sink', 'opcda.clsid'='CAE8D0E1-117B-11D5-924B-11C0F023E91C')，报错，且数据不同步"
"insert into root.g1.d1(time,s1,s2) values(now(),\"s1-2\",\"s2-2\")，数据开始同步，不报错"
)

case_RN0124() {
  local st out unexpected=0
  for st in "${RN0124_SQL[@]}"; do
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
"TIMECHODB-0124 自动抽取|TIMECHODB-0124|功能|OPC DA】 Cannot invoke "org.apache.tsfile.utils.Binary.toSt|case_RN0124"
)
