#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0415
#   【TIMECHODB-0415】 [ 查询 ] 查询遇到 Not enough memory for sorting 产生的临时文件夹没有删除，期望清理干净
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：清理sortTemp 临时文件夹  复现步骤 步骤1：1C1D IoT  干净环境 步骤2：load tsfile load命令： ./tools/import-data.sh -ft tsfile -h 192.168
# ============================================================================
RN0415_SQL=(
"Set sql_dialect=table"
"create database db"
"create view AA5 (sensor_id STRING TAG, value float field) AS root.reactor.system1.techSystem1.DX.HYH_W3.AA5.**"
"select distinct min(v2.value) as min_c1 ,max(v1.value) as max_c2 from AA5 as v1 inner join AA5 as v2 using (time) where v1.sensor_id like '%_RRB2%'  and v2.value>2 and time<2024-11-22T09:45:43.000+08:00  limit 5 offset 0"
)

case_RN0415() {
  local st out unexpected=0
  for st in "${RN0415_SQL[@]}"; do
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
"TIMECHODB-0415 自动抽取|TIMECHODB-0415|功能|查询 ] 查询遇到 Not enough memory for sorting 产生的临时文件夹没有删除，期望清理干|case_RN0415"
)
