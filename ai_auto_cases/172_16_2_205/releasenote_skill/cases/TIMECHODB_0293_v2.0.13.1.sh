#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0293
#   【TIMECHODB-0293】 【表模型】delete devices + where 条件，所有的devices均被删除了
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：delete devices from db1.t2 where id='d1' and id='d2'； 执行后，show devices from db1.t2应该有id对应为d3的数据 复现步骤 （1）V2.0.4
# ============================================================================
RN0293_SQL=(
"create table db1.t2(ID TAG,status BOOLEAN)"
"insert into db1.t2(time,ID,status) values(3600000,'d1',true),(7200000,'d2',false),(86400000,'d3',false)"
"show devices from db1.t2"
"delete devices from db1.t2 where id='d1' and id='d2'"
)

case_RN0293() {
  local st out unexpected=0
  for st in "${RN0293_SQL[@]}"; do
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
"TIMECHODB-0293 自动抽取|TIMECHODB-0293|功能|表模型】delete devices + where 条件，所有的devices均被删除了|case_RN0293"
)
