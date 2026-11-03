#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0053
#   【TIMECHODB-0053】 [table]3c3d,1个datanode down, 创建table失败
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：
# ============================================================================
RN0053_SQL=(
"create database db1"
"create table db1.out(name string tag,count int32 field,total int32 field)"
"insert into db1.out(time,name,count,total)values(-1,'device-1',12,456),(now(),'蜜蜂',876,6789)"
)

case_RN0053() {
  local st out unexpected=0
  for st in "${RN0053_SQL[@]}"; do
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
"TIMECHODB-0053 自动抽取|TIMECHODB-0053|功能|table]3c3d,1个datanode down, 创建table失败|case_RN0053"
)
