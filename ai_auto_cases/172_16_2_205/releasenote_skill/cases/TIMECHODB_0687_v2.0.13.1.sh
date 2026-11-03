#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0687】创建对齐序列后，使用写入创建，查询结果为空，
#   日志报 ClassCastException（WritableMemChunkGroup → AlignedWritableMemChunkGroup）
#   根因：device 对齐属性与已存在序列不一致时，写入自动建设备未对齐，读时强转失败
#   修复：SchemaRegion 返回对齐属性不一致，写入侧改为对齐属性后写入
#   验证版本：2.0.13.1 / ab6d3de
#   判据：①写入成功不报 ClassCastException ②select 能查出刚写入的数据
# ============================================================================
RN0687_DB=root.rn0687

case_RN106() {
  local out
  T "drop database $RN0687_DB" >/dev/null 2>&1
  T "create database $RN0687_DB" >/dev/null 2>&1

  out=$(T "create aligned timeseries $RN0687_DB.b (d int64)")
  assert_ok "$out" "创建对齐序列 root.rn0687.b(d)"

  # 关键：用未定义过的 c 测量点触发"写入自动建设备"，且路径与对齐序列同 device
  out=$(T "insert into $RN0687_DB.b(time,c) values(-1,1)")
  echo "  写入返回：$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-160)"
  if echo "$out" | grep -qi 'ClassCastException'; then
    fail "写入触发 ClassCastException（缺陷未修复）"
  else
    ok "写入未触发 ClassCastException"
  fi

  out=$(T "select c from $RN0687_DB.b")
  echo "  查询结果：$(echo "$out" | tr '\n' ' ' | cut -c1-200)"
  if echo "$out" | grep -qi 'ClassCastException'; then
    fail "查询触发 ClassCastException（缺陷未修复）"
  else
    ok "查询未触发 ClassCastException"
  fi
  if echo "$out" | grep -qE '\|[[:space:]]*1(\.[0-9]+)?[[:space:]]*\|'; then
    ok "能查出写入的 c=1"
  else
    fail "查询结果为空或缺少写入值（实际 $(echo "$out" | tr '\n' ' ' | cut -c1-150)）"
  fi

  T "drop database $RN0687_DB" >/dev/null 2>&1
}

CASES+=(
"RN-106|TIMECHODB-0687 对齐序列|功能|对齐序列 device 用写入创建后查询不应 ClassCastException 且能查出数据|case_RN106"
)
