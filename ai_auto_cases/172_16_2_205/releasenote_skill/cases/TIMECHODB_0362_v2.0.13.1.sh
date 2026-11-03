#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0362
#   【TIMECHODB-0362】 【ainode】外置模型无法导入
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤 下载模型文件，可在此https://nas.timecho.com:5001/sharing/yOMR2iow9 启动iotdb+ainode 执行命令，导入模型  create model dlinear_e
# ============================================================================
RN0362_SQL=(
"create model dlinear_example using uri \"file:///data/atmos/zk_test/AINode/models/dlinear\""
"create model timer using uri \"file:///data/atmos/zk_test/AINode/models/timer\""
)

case_RN0362() {
  local st out unexpected=0
  for st in "${RN0362_SQL[@]}"; do
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
"TIMECHODB-0362 自动抽取|TIMECHODB-0362|功能|ainode】外置模型无法导入|case_RN0362"
)
