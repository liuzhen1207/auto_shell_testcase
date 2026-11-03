#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0410
#   【TIMECHODB-0410】 大TEXT对象 + align by device + order by time 查询报内存不足
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：select s1 from root.db.** order by time align by device 能够查询成功  复现步骤 16C 32GB 机器，1C1D，修改如下配置参数：  data_region_g
# ============================================================================
RN0410_SQL=(
"select s1 from root.db.** order by time align by device"
)

case_RN0410() {
  local st out unexpected=0
  for st in "${RN0410_SQL[@]}"; do
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
"TIMECHODB-0410 自动抽取|TIMECHODB-0410|功能|大TEXT对象 + align by device + order by time 查询报内存不足|case_RN0410"
)
