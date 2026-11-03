#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0708
#   【TIMECHODB-0708】 【2.0.6.4】并发写入+修改序列编码和压缩（开启合并）出现死锁问题
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：修改序列的压缩和编码不影响并发写入  复现步骤 步骤一：使用BM并发写入  config.properties 步骤二：持续执行修改序列的压缩和编码（大约10次内出现）  ALTER TIMESERIES root.te
# ============================================================================
RN0708_SQL=(
"ALTER TIMESERIES root.test.g_0.** SET ENCODING=PLAIN,COMPRESSION=SNAPPY"
"ALTER TIMESERIES root.test.g_0.** SET ENCODING=PLAIN,COMPRESSION=ZSTD"
"ALTER TIMESERIES root.test.g_0.** SET ENCODING=PLAIN,COMPRESSION=GZIP"
"ALTER TIMESERIES root.test.g_0.** SET ENCODING=PLAIN,COMPRESSION=LZMA2"
"ALTER TIMESERIES root.test.g_0.** SET ENCODING=PLAIN,COMPRESSION=LZ4"
"ALTER TIMESERIES root.test.g_0.** SET ENCODING=PLAIN,COMPRESSION=UNCOMPRESSED"
)

case_RN0708() {
  local st out unexpected=0
  for st in "${RN0708_SQL[@]}"; do
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
"TIMECHODB-0708 自动抽取|TIMECHODB-0708|功能|2.0.6.4】并发写入+修改序列编码和压缩（开启合并）出现死锁问题|case_RN0708"
)
