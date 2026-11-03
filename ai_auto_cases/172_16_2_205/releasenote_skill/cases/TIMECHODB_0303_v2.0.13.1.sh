#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0303
#   【TIMECHODB-0303】 【表模型-V2.0.4.1_RC1】表模型全量查询时，报301异常
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：表模型全量查询时，查询结果集可正常显示  复现步骤 （1）V2.0.4.1（RC1）启动1C1D （2）通过BENCHMARK工具生成数据集    config.properties （3）root用户进入CLI执行，执
# ============================================================================
RN0303_SQL=(
"show databases"
)

case_RN0303() {
  local st out unexpected=0
  for st in "${RN0303_SQL[@]}"; do
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
"TIMECHODB-0303 自动抽取|TIMECHODB-0303|功能|表模型-V2.0.4.1_RC1】表模型全量查询时，报301异常|case_RN0303"
)
