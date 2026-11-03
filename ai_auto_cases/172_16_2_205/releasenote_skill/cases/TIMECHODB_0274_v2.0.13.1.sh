#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0274
#   【TIMECHODB-0274】 【dbeaver】【树模型】【5群】Status code: 700, Query Statement: "xxxxxx". executeStatement failed becaus
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤 使用树模型cli写入1条数据  insert into root.wddd.`粤构`.plc001(time,`生命体征abc3`) values(now(),false) 在dbeaver查询即可。  研发侧
# ============================================================================
RN0274_SQL=(
"insert into root.wddd.\`粤构\`.plc001(time,\`生命体征abc3\`) values(now(),false)"
)

case_RN0274() {
  local st out unexpected=0
  for st in "${RN0274_SQL[@]}"; do
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
"TIMECHODB-0274 自动抽取|TIMECHODB-0274|功能|dbeaver】【树模型】【5群】Status code: 700, Query Statement: "xxxxx|case_RN0274"
)
