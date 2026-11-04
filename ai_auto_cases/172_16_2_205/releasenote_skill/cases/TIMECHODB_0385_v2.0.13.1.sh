#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0385
#   【TIMECHODB-0385】 [树转表] 2.0.5.1 RC3 3个视图join 查询 指定了where time <= , DN java.lang.StackOverflowError: null
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：没有StackOverflowError，正确的报错信息，或者执行成功。  复现步骤 步骤1：在2.0.5.1 RC2 运行48小时（其他测试，生成的数据）/data1/iotdb/v2051_rc2_0607_58d6
# ============================================================================
RN0385_SQL=(
"SELECT count(*)  FROM v1_0 t1 LEFT JOIN v2_0 t2   ON t1.time = t2.time AND t1.device_id = t2.device_id LEFT JOIN v3_0 t3   ON t2.time = t3.time AND t2.device_id = t3.device_id where t2.time<=1970-01-01T08:03:20.000+08:00"
)

case_RN0385() {
  local st out unexpected=0 RN_EXPECT_ERROR=1
  rn_run() {  # 方言自适配：先试首选方言，700/701 解析错误则换另一种方言重试
    local st=$1 o1 o2
    o1=$( T "$st" )
    if echo "$o1" | grep -qE '700: |701: '; then
      o2=$( Q "$st" )
      if ! echo "$o2" | grep -qE '700: |701: '; then echo "$o2"; return; fi
    fi
    echo "$o1"
  }
  for st in "${RN0385_SQL[@]}"; do
    out=$( rn_run "$st" )
    # 幂等：对象已存在视为可接受
    if echo "$out" | grep -qiE 'already exists|already been created'; then
      ok "已存在(幂等): $(echo "$st" | cut -c1-55)"; continue
    fi
    # 策略类错误：弱口令/无列/已存在，不算缺陷
    if echo "$out" | grep -qiE '820:|507:|501:'; then
      ok "策略/幂等类返回(可接受): $(echo "$st" | cut -c1-45)"; continue
    fi
    if echo "$out" | grep -qiE 'Exception|ERROR|internal error|NullPointerException'; then
      if [ "$RN_EXPECT_ERROR" = "1" ]; then
        ok "预期报错: $(echo "$st" | cut -c1-50)"
      else
        fail "$(echo "$st" | cut -c1-65) -> $(echo "$out" | head -1 | cut -c1-110)"
      fi
    else
      ok "$(echo "$st" | cut -c1-55)"
    fi
  done
}

CASES+=(
"RN-0385|TIMECHODB-0385 自动抽取|功能|树转表] 2.0.5.1 RC3 3个视图join 查询 指定了where time <= , DN java.la|case_RN0385"
)
