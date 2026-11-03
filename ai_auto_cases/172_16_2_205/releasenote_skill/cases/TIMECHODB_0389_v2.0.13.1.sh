#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0389
#   【TIMECHODB-0389】 [ 查询优化项 ] 3个相同的表/视图 做LEFT JOIN  指定using(device_id,time) 预期没有sort 操作，实际报sort 内存不足：719: Not eno
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：没有sort  复现步骤 步骤1：在2.0.5.1 RC2 运行48小时（其他测试，生成的数据）/data1/iotdb/v2051_rc2_0607_58d685e_view_pipe_send Stop 集群，lib
# ============================================================================
RN0389_SQL=(
"SELECT count(t1.s_0) FROM v1_0 t1 LEFT JOIN v1_0 t2 USING(device_id, time) LEFT JOIN v1_0 t3 USING (device_id, time)"
)

case_RN0389() {
  local st out unexpected=0
  for st in "${RN0389_SQL[@]}"; do
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
"TIMECHODB-0389 自动抽取|TIMECHODB-0389|功能|查询优化项 ] 3个相同的表/视图 做LEFT JOIN  指定using(device_id,time) 预期没有|case_RN0389"
)
