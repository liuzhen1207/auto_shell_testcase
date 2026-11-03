#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0704
#   【TIMECHODB-0704】 【2.0.6.4】修改序列编码和压缩，IF PERMITTED语句实现存在问题，对不存在的序列使用会报错 Invalidate schemaEngine cache failed
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：使用IF PERMITTED语句，修改对于不存在的序列应该报错Timeseries [XXX] does not exist or is represented by device template  复现步骤  -- 
# ============================================================================
RN0704_SQL=(
"create user IoTDBUser '!@#\$!dfdfzvd343'"
"alter timeSeries IF PERMITTED root.vechile.** set encoding=PLAIN, compressor=LZMA2"
)

case_RN0704() {
  local st out unexpected=0
  for st in "${RN0704_SQL[@]}"; do
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
"TIMECHODB-0704 自动抽取|TIMECHODB-0704|功能|2.0.6.4】修改序列编码和压缩，IF PERMITTED语句实现存在问题，对不存在的序列使用会报错 Invali|case_RN0704"
)
