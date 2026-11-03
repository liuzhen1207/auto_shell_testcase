#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0559
#   【TIMECHODB-0559】 [2.0.6.1][aggregate-processor]效率不高，长时间处理大量聚合，会影响写入
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤 iotdb-29：启动iotdb  create pipe test_operator_all with source ('path'='root.test.g_0.**') with processor ('
# ============================================================================
RN0559_SQL=(
"create pipe test_operator_all with source ('path'='root.test.g_0.**') with processor ('processor'='aggregate-processor','output.database'='root.aggr.op.all','sliding.boundary-time'='0','sliding.interval-second s'='120','operators'='avg,peak,rms,var,skew,kurt,ff,cf,pf,ce') with sink('sink'='write-back-sink')"
"select last s_0 from root.test.g_0.d_0"
"select last avg from root.aggr.op.all.g_0.d_0.s_0"
"select count(s_0) from root.test.g_0.d_0"
"select count(avg) from root.aggr.op.all.g_0.d_0.s_0"
"select min_time(s_1),max_time(s_1) from root.test.g_0.d_0"
"select min_time(avg),max_time(avg) from root.aggr.op.all.g_0.d_0.s_0"
)

case_RN0559() {
  local st out unexpected=0
  for st in "${RN0559_SQL[@]}"; do
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
"TIMECHODB-0559 自动抽取|TIMECHODB-0559|功能|2.0.6.1][aggregate-processor]效率不高，长时间处理大量聚合，会影响写入|case_RN0559"
)
