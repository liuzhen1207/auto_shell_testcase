#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0727
#   【TIMECHODB-0727】 1.3.6.1 TierManager 可能返回错误的 tier 导致合并生成的文件直接进入最高层级
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：文件不会触发合并操作  复现步骤 在conf/iotdb-system.properties中添加上述参数 使用如下sql，多执行几遍  insert into root.g1.d1(s1) values(123);fl
# ============================================================================
RN0727_SQL=(
"insert into root.g1.d1(s1) values(123)"
)

case_RN0727() {
  local st out unexpected=0
  for st in "${RN0727_SQL[@]}"; do
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
"TIMECHODB-0727 自动抽取|TIMECHODB-0727|功能|1.3.6.1 TierManager 可能返回错误的 tier 导致合并生成的文件直接进入最高层级|case_RN0727"
)
