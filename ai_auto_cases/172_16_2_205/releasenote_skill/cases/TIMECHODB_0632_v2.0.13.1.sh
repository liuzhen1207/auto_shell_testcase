#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0632
#   【TIMECHODB-0632】 [2.0.7.1][tree]select * from root.__audit.password_history._0有密码明文，显示格式与其他用户不同
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤  select * from root.__audit.password_history._0  2025-10-15 rc7 验证通过 image.png   研发侧 问题原因    解决方案    影响分析
# ============================================================================
RN0632_SQL=(
"select * from root.__audit.password_history._0"
)

case_RN0632() {
  local st out unexpected=0
  for st in "${RN0632_SQL[@]}"; do
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
"TIMECHODB-0632 自动抽取|TIMECHODB-0632|功能|2.0.7.1][tree]select * from root.__audit.password_history.|case_RN0632"
)
