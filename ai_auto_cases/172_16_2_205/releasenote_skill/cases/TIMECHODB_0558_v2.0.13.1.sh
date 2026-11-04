#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0558
#   【TIMECHODB-0558】 2.0.6.1 RC4 查询写回遇到空指针 Cannot invoke "com.google.common.util.concurrent.ListenableFuture.isDon
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：无空指针  复现步骤 步骤1：192.168.10.22 启动1C1D /data/db/v2061_rc4_0829_7c6ae29/logs 数据库配置参数  CN ENV ON_HEAP_MEMORY="2G" O
# ============================================================================
RN0558_SQL=(
"create table tt5(sensor_id string tag,value float field)"
"insert into tt5 select * from aa5"
"create table test(sensor_id string tag,value1 float field,value2 double field)"
"insert into test(time,value1,value2) select cast (now() as timestamp), min(v2.value) as min_c1 ,cast(max(v1.value) as double) as max_c2 from AA5 as v1 ,AA5 as v2, AA5 AS v3, AA5 as v4 where v1.sensor_id like '%_RRB2%' and  v2.time>1 and v3.value>2 and v4.time<2024-11-22T09:45:43.000+08:00  limit 5 offset 0"
)

case_RN0558() {
  local st out unexpected=0 RN_EXPECT_ERROR=0
  rn_run() {  # 方言自适配：先试首选方言，700/701 解析错误则换另一种方言重试
    local st=$1 o1 o2
    o1=$( Q "$st" )
    if echo "$o1" | grep -qE '700: |701: '; then
      o2=$( T "$st" )
      if ! echo "$o2" | grep -qE '700: |701: '; then echo "$o2"; return; fi
    fi
    echo "$o1"
  }
  for st in "${RN0558_SQL[@]}"; do
    out=$( rn_run "$st" )
    # 幂等：对象已存在视为可接受
    if echo "$out" | grep -qiE 'already exists|already been created'; then
      ok "已存在(幂等): $(echo "$st" | cut -c1-55)"; continue
    fi
    # 策略类错误：弱口令/无列/已存在，不算缺陷
    if echo "$out" | grep -qiE '820:|507:|501:'; then
      ok "策略/幂等类返回(可接受): $(echo "$st" | cut -c1-45)"; continue
    fi
    if echo "$out" | grep -qiE 'Exception|ERROR|internal error|NullPointerException'; then
      if [ "$RN_EXPECT_ERROR" = "1" ]; then
        ok "预期报错: $(echo "$st" | cut -c1-50)"
      else
        fail "$(echo "$st" | cut -c1-65) -> $(echo "$out" | head -1 | cut -c1-110)"
      fi
    else
      ok "$(echo "$st" | cut -c1-55)"
    fi
  done
}

CASES+=(
"RN-0558|TIMECHODB-0558 自动抽取|功能|2.0.6.1 RC4 查询写回遇到空指针 Cannot invoke "com.google.common.uti|case_RN0558"
)
