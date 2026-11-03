#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0557
#   【TIMECHODB-0557】 [2.0.6.1][aggregate-processor]会处理已经删除的原始数据序列，预期不要处理
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤   create pipe test_disorder  with source('path'='root.sg.disorder.s0') with processor ('processor'='aggre
# ============================================================================
RN0557_SQL=(
"create pipe test_disorder  with source('path'='root.sg.disorder.s0') with processor ('processor'='aggregate-processor','output.database'='root.aggr.disorder','sliding.boundary-time'='0','sliding.interval-seconds'='60','operators'='peak') with sink('sink'='write-back-sink')"
"insert into root.sg.disorder(time,s0) values(1706670000,11)"
"insert into root.sg.disorder(time,s0) values(1706676000,12)"
"insert into root.sg.disorder(time,s0) values(1706674000,13)"
"insert into root.sg.disorder(time,s0) values(1706678000,14)"
"insert into root.sg.disorder(time,s0) values(1706680000,15)"
"insert into root.sg.disorder(time,s0) values(1706682000,17)"
"insert into root.sg.disorder(time,s0) values(1706684000,18)"
"select * from root.sg.disorder"
"select * from root.aggr.disorder.disorder.s0"
"insert into root.sg.disorder(time,s0) values(1706784000000,170),(1706784200000,172),(1706784400000,173)"
"drop timeseries root.aggr.disorder.**"
"drop timeseries root.sg.disorder.**"
"show devices"
"create pipe test_disorder  with source('path'='root.sg.disorder.s0') with processor ('processor'='aggregate-processor','output.database'='root.aggr.disorder2','sliding.boundary-time'='0','sliding.interval-seconds'='60','operators'='peak') with sink('sink'='write-back-sink')"
"insert into root.sg.delete(time,s0) values(1706670000,11)"
"insert into root.sg.delete(time,s0) values(1706676000,12)"
"insert into root.sg.delete(time,s0) values(1706674000,13)"
"insert into root.sg.delete(time,s0) values(1706678000,14)"
"insert into root.sg.delete(time,s0) values(1706680000,15)"
"insert into root.sg.delete(time,s0) values(1706682000,17)"
"insert into root.sg.delete(time,s0) values(1706684000,18)"
"delete from root.sg.delete.* where time=1706674000"
"insert into root.sg.delete (time,s0) values(1706784000000,170)"
"create pipe test_delete  with source('path'='root.sg.delete.s0') with processor ('processor'='aggregate-processor','output.database'='root.aggr.delete','sliding.boundary-time'='0','sliding.interval-seconds'='60','operators'='avg') with sink('sink'='write-back-sink')"
"select * from root.sg.delete"
"select * from root.aggr.delete.delete.s0"
)

case_RN0557() {
  local st out unexpected=0
  for st in "${RN0557_SQL[@]}"; do
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
"TIMECHODB-0557 自动抽取|TIMECHODB-0557|功能|2.0.6.1][aggregate-processor]会处理已经删除的原始数据序列，预期不要处理|case_RN0557"
)
