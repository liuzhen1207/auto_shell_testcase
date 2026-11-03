#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0698】修改单个序列的编码和压缩存在语法错误
#   原始版本背景：1.3.6.1 上 ALTER TIMESERIES ... SET ENCODING/COMPRESSION 语法报错
#   2.0.13.1 实测：语法可被解析，但对"无 tag/attribute 的普通序列"返回
#                  507 TimeSeries does not have any tag/attribute（语义拒绝，非语法错误）
#   本用例判据（回归点 = 语法不再报错）：
#     ①ALTER 语句不再返回 700 语法/解析错误
#     ②返回要么成功，要么是 507 这类语义化错误
#     ③若成功，show timeseries 中编码/压缩应已变更
# ============================================================================
RN0698_DB=root.rn0698

case_RN104() {
  local out ts
  T "drop database $RN0698_DB" >/dev/null 2>&1
  T "create database $RN0698_DB" >/dev/null 2>&1
  out=$(T "create timeseries $RN0698_DB.d0.s0 with datatype=BOOLEAN,encoding=PLAIN,compression=UNCOMPRESSED")
  assert_ok "$out" "创建序列（PLAIN + UNCOMPRESSED）"

  out=$(T "alter timeseries $RN0698_DB.d0.s0 set encoding=RLE, compression=LZ4")
  echo "  ALTER 返回：$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-180)"

  if echo "$out" | grep -q '700'; then
    fail "ALTER 仍报 700 语法错误（本缺陷的回归点被打破）"
  else
    ok "ALTER 语句已被解析（不再报 700 语法错误）"
  fi

  if echo "$out" | grep -qi 'success'; then
    ok "ALTER 执行成功"
    ts=$(T "show timeseries $RN0698_DB.d0.s0")
    echo "  show timeseries：$(echo "$ts" | tail -3 | tr '\n' ' ' | cut -c1-160)"
    assert_contains "$ts" 'RLE' "编码已变为 RLE"
    assert_contains "$ts" 'LZ4' "压缩已变为 LZ4"
  elif echo "$out" | grep -q '507'; then
    ok "返回 507 语义化拒绝（2.x 对无 tag 序列不支持改编码，行为明确）"
  else
    fail "既未成功、也不是 507 语义化错误（实际 $(echo "$out" | head -1 | cut -c1-120)）"
  fi

  T "drop database $RN0698_DB" >/dev/null 2>&1
}

CASES+=(
"RN-104|TIMECHODB-0698 序列编码|功能|ALTER TIMESERIES 改 encoding/compression 不应报语法错误（成功或 507 语义拒绝）|case_RN104"
)
