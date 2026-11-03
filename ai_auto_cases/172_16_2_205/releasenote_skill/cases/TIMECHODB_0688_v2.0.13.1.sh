#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0688
#   【TIMECHODB-0688】 【异步加载】异步加载带mods的tsfile，会忽略mods自动补全数据
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：不应该补全数据，效果应该和同步加载一致  复现步骤 在CLI中执行下面SQL进行异步加载，等待一会再执行查询  load '/data' with ('async'='true'); -- 等待一会再执行查询（文件由un
# ============================================================================
RN0688_SQL=(
"select * from root.test.g_0.**"
)

case_RN0688() {
  local st out unexpected=0
  for st in "${RN0688_SQL[@]}"; do
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
"TIMECHODB-0688 自动抽取|TIMECHODB-0688|功能|异步加载】异步加载带mods的tsfile，会忽略mods自动补全数据|case_RN0688"
)
