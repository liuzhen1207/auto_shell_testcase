#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0612
#   【TIMECHODB-0612】 修复存储引擎对于某个表结构正在修改的 table，刷盘后文件中的 tableSchema 还是以最开始的 table schema 为准的 bug
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：文件内的 tableSchema 应该以该 table 最新的写入为准。  复现步骤 使用 rc/2.0.6.1 ，生成TsFile内数据 tag 列和 table 不对齐：（使用TsFile脚本查看内部结构，需要替换脚
# ============================================================================
RN0612_SQL=(
"create database test with (data_region_group_num=1)"
"create table test (a tag, b attribute, c int32)"
"insert into test(a, b, c) values('a', 'b', 1)"
"alter table test add column d tag"
"insert into test(a, b, c, d) values('a', 'b', 1, 'd')"
)

case_RN0612() {
  local st out unexpected=0
  for st in "${RN0612_SQL[@]}"; do
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
"TIMECHODB-0612 自动抽取|TIMECHODB-0612|功能|修复存储引擎对于某个表结构正在修改的 table，刷盘后文件中的 tableSchema 还是以最开始的 table|case_RN0612"
)
