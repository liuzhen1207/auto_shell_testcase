#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0600
#   【TIMECHODB-0600】 insertMultiTablets时，部分设备的自动创建，不应该影响无需自动创建的设备的写入（这些设备的对齐属性与真实的对齐属性不一致）
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：能够写入成功  复现步骤  IoTDB> create aligned timeseries root.a.b (c int32, d int32)  session: insertTablets Tablet1: de
# ============================================================================
RN0600_SQL=(
"create aligned timeseries root.a.b (c int32, d int32)"
)

case_RN0600() {
  local st out unexpected=0
  for st in "${RN0600_SQL[@]}"; do
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
"TIMECHODB-0600 自动抽取|TIMECHODB-0600|功能|insertMultiTablets时，部分设备的自动创建，不应该影响无需自动创建的设备的写入（这些设备的对齐属性与|case_RN0600"
)
