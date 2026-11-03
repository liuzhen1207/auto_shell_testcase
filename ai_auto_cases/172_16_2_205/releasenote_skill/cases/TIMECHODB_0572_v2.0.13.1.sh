#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0572
#   【TIMECHODB-0572】 清除DN上的缓存参数为on local时出现空指针异常报错
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：可以正常清除DN上的缓存参数  复现步骤 1.打开表模型IoTDB 2.使用create database database1创建数据库 3.use database1使用数据库 4.使用SQL语句： create ta
# ============================================================================
RN0572_SQL=(
"create table table1( time Timestamp time, temperature float field, status boolean field, humidity float field, plant_id string tag, device_id string tag )with(ttl=1360000000)"
)

case_RN0572() {
  local st out unexpected=0
  for st in "${RN0572_SQL[@]}"; do
    out=$( Q "$st" )
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
"TIMECHODB-0572 自动抽取|TIMECHODB-0572|功能|清除DN上的缓存参数为on local时出现空指针异常报错|case_RN0572"
)
