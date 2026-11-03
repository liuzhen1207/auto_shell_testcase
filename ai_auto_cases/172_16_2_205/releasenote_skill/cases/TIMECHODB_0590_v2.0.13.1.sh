#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0590
#   【TIMECHODB-0590】 Load 在某些特殊情况下（aligned 类型不同，tableSchema 不同时）等，会忽略 mods 导入
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：能够成功忽略被 mod 删除的数据  复现步骤  --- 生成 mod insert into root.db.d1 (s1, s2) values (1, 2) flush delete timeseries root
# ============================================================================
RN0590_SQL=(
"insert into root.db.d1 (s1, s2) values (1, 2)"
"delete timeseries root.db.d1.s1"
"drop database root.**"
"create aligned timeseries root.db.d1 (s1 int32, s2 int32)"
"select * from root.db.**"
)

case_RN0590() {
  local st out unexpected=0
  for st in "${RN0590_SQL[@]}"; do
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
"TIMECHODB-0590 自动抽取|TIMECHODB-0590|功能|Load 在某些特殊情况下（aligned 类型不同，tableSchema 不同时）等，会忽略 mods 导入|case_RN0590"
)
