#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0556
#   【TIMECHODB-0556】 [2.0.6.1][aggregate-processor]output.database最好有校验，当指定非法值时，错误日志不明确，需评审
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤  create pipe test_aggr with source ('path'='root.sg.**') with processor ('processor'='aggregate-processor
# ============================================================================
RN0556_SQL=(
"create pipe test_aggr with source ('path'='root.sg.**') with processor ('processor'='aggregate-processor','output.database'='root.aggr.sg.','sliding.boundary-time'='0','sliding.interval-seconds'='60','operators'='peak') with sink('sink'='write-back-sink')"
"insert into root.sg.disorder(time,s0) values(1706670000,11)"
"insert into root.sg.disorder(time,s0) values(1706676000,12)"
"insert into root.sg.disorder(time,s0) values(1706674000,13)"
"insert into root.sg.disorder(time,s0) values(1706678000,14)"
"insert into root.sg.disorder(time,s0) values(1706680000,15)"
"insert into root.sg.disorder(time,s0) values(1706682000,17)"
"insert into root.sg.disorder(time,s0) values(1706684000,18)"
"insert into root.sg.disorder(time,s0) values(1706784000000,170),(1706784200000,172),(1706784400000,173)"
)

case_RN0556() {
  local st out unexpected=0 RN_EXPECT_ERROR=0
  rn_run() {  # 方言自适配：先试首选方言，700/701 解析错误则换另一种方言重试
    local st=$1 o1 o2
    o1=$( T "$st" )
    if echo "$o1" | grep -qE '700: |701: '; then
      o2=$( Q "$st" )
      if ! echo "$o2" | grep -qE '700: |701: '; then echo "$o2"; return; fi
    fi
    echo "$o1"
  }
  for st in "${RN0556_SQL[@]}"; do
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
"RN-0556|TIMECHODB-0556 自动抽取|功能|2.0.6.1][aggregate-processor]output.database最好有校验，当指定非法值时，|case_RN0556"
)
