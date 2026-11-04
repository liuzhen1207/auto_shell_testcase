#!/bin/bash
# ============================================================================
# 来源缺陷单：PingCode V2-345（创建人：刘珍）
#   查询 SQL 语法错误（offset X limit Y 写法非法）导致 DataNode OOM
#   （根因：SQL Parser ErrorHandler 在 ATN 遍历时死循环，最终 heap dump 8.3GB）
#   期望：语法错误应快速返回明确报错，不得卡死/OOM
#   验证版本：2.0.13.1 / ab6d3de
# ============================================================================
case_RN129() {
  local out t0 t1 ms
  # 构造非法 offset/limit 语法（缺少空格与数字组合），触发 parser 错误路径
  t0=$(date +%s%N)
  out=$(T "select time from root.v2345.d1 offset 1 limit 2 offset 3 limit")
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  echo "  返回(${ms}ms)：$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-170)"

  if [ "$ms" -gt 20000 ]; then
    fail "解析耗时 ${ms}ms，疑似 parser 卡死"
  else
    ok "解析快速返回（${ms}ms < 20s）"
  fi
  if echo "$out" | grep -qiE '700|parse|syntax|解析'; then
    ok "返回语法错误提示"
  else
    fail "未返回语法错误（$(echo "$out" | head -1 | cut -c1-120)）"
  fi

  # DN 仍在正常运行（未 OOM）
  if wait_running 60 >/dev/null 2>&1; then
    ok "集群仍 8/8（未 OOM/掉节点）"
  else
    fail "集群节点异常（疑似 OOM）"
  fi
}

CASES+=(
"RN-129|V2-345 解析健壮性|可靠性|非法 offset/limit 语法应快速报错，不得 OOM/卡死|case_RN129"
)
