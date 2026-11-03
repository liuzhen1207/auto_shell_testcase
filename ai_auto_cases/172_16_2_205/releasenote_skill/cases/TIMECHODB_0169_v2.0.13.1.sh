#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0169
#   【TIMECHODB-0169】 【对象存储 + export-tsfle】导出文件失败
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤 配置iotdb #--------------------------- dn_data_dirs=data/datanode/data;OBJECT_STORAGE tier_ttl_in_ms=60000;
# ============================================================================
RN0169_SQL=(
"insert into root.g1.d1(s1) values(1)"
)

case_RN0169() {
  local st out unexpected=0
  for st in "${RN0169_SQL[@]}"; do
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
"TIMECHODB-0169 自动抽取|TIMECHODB-0169|功能|对象存储 + export-tsfle】导出文件失败|case_RN0169"
)
