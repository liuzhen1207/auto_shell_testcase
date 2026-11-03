#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0048
#   【TIMECHODB-0048】 write back sink这里面指定目标db为大写（NEWDB）时,会直接创建 NEWDB的database, 不能使用
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：
# ============================================================================
RN0048_SQL=(
"create pipe test with source ('forwarding-pipe-requests'='false', 'database-name'='db')"
"create pipe test2 with source ('forwarding-pipe-requests'='false', 'database-name'='db') with processor ('processor'='rename-database-processor', 'new-db-name'='NEWDB') with sink ('sink'='write-back-sink')"
"create database root.db"
"create table db.\"中文表名\"(time TIMESTAMP time,\"汉名列1\" float field,\"_收获_\" int32 field, \"名称\" string tag,\"单位\" string attribute,\"型号\" string field)"
"insert into db.\"中文表名\"(time,\"名称\",\"汉名列1\",\"_收获_\",\"单位\",\"型号\")values(2024-12-09,'苹果',3.2456,7896,'个','特级'),(2025-01-01,'电锯',876.567,3498,'把','32#')"
)

case_RN0048() {
  local st out unexpected=0
  for st in "${RN0048_SQL[@]}"; do
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
"TIMECHODB-0048 自动抽取|TIMECHODB-0048|功能|write back sink这里面指定目标db为大写（NEWDB）时,会直接创建 NEWDB的database, |case_RN0048"
)
