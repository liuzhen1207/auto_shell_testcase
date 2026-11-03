#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0402
#   【TIMECHODB-0402】 [ 树转表 ] 查询视图失败（where不指定field列，指定time和tag）：ArrayIndexOutOfBoundsException
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：查询成功  复现步骤 步骤1：3C3DIoT 2副本 干净环境 步骤2：load tsfile load命令： tools/import-data.sh -ft tsfile -h 192.168.130.1 -p 66
# ============================================================================
RN0402_SQL=(
"Set sql_dialect=table"
"create database db"
"create view AA5 (sensor_id STRING TAG, value float field) AS root.reactor.system1.techSystem1.DX.HYH_W3.AA5.**"
"select count(*) as each_row from AA5 where sensor_id like '5G%KA' or sensor_id like '%5VVP712%A' and time=2024-11-21T08:00:03.000+08:00"
)

case_RN0402() {
  local st out unexpected=0
  for st in "${RN0402_SQL[@]}"; do
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
"TIMECHODB-0402 自动抽取|TIMECHODB-0402|功能|树转表 ] 查询视图失败（where不指定field列，指定time和tag）：ArrayIndexOutOfBou|case_RN0402"
)
