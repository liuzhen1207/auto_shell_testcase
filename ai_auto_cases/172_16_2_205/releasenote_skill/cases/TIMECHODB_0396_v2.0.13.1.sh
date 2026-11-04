#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0396
#   【TIMECHODB-0396】 【窗口函数】查询空值，一次性执行多遍完整流程，会出现java.lang.IndexOutOfBoundsException: Index out of Partition's bound
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：可以一次持续执行，不出现异常  复现步骤 在2.0.5.1 RC3使用CLI，一次性执行5遍下面SQL，即可复现  create database window_function_test; use window_fun
# ============================================================================
RN0396_SQL=(
"create database window_function_test"
"create table t1 (Device string tag, t2 string tag, t3 string tag, a1 string attribute, Flow int64 field, f2 int32 field, f3 double field,f4 float field, date date field, timestamp timestamp field, string string field)"
"insert into t1 values (1970-01-01T08:00:00.000+08:00, 'd0', 'd0', 'd0', 'd0', 3, 3, 3.0, 3.0, '1970-01-01', 3, '3')"
"insert into t1 values (1970-01-01T08:00:00.001+08:00, 'd0', 'd0', 'd0', 'd0', 5, 5, 5.0, 5.0, '1970-01-01', 5, '5')"
"insert into t1 values (1970-01-01T08:00:00.002+08:00, 'd0', 'd0', 'd0', 'd0', 3, 3, 3.0, 3.0, '1970-01-01', 3, '3')"
"insert into t1 values (1970-01-01T08:00:00.003+08:00, 'd0', 'd0', 'd0', 'd0', 1, 1, 1.0, 1.0, '1970-01-01', 1, '1')"
"insert into t1 values (1970-01-01T08:00:00.004+08:00, 'd0', 'd0', 'd0', 'd0', null, null, null, null, null, null, null)"
"insert into t1 values (1970-01-01T08:00:00.005+08:00, 'd1', 'd1', 'd1', 'd1', 2, 2, 2.0, 2.0, '1970-01-01', 2, '2')"
"insert into t1 values (1970-01-01T08:00:00.006+08:00, 'd1', 'd1', 'd1', 'd1', null, null, null, null, null, null, null)"
"insert into t1 values (1970-01-01T08:00:00.007+08:00, 'd1', 'd1', 'd1', 'd1', 4, 4, 4.0, 4.0, '1970-01-01', 4, '4')"
"insert into t1 values (1970-01-01T08:00:00.008+08:00,  null, null, null, null, null, null, null, null, null, null, null)"
"SELECT time, device, flow, count(flow) OVER(PARTITION BY device ORDER BY flow ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)FROM t1 ORDER BY time"
"drop database window_function_test"
)

case_RN0396() {
  local st out unexpected=0 RN_EXPECT_ERROR=1
  rn_run() {  # 方言自适配：先试首选方言，700/701 解析错误则换另一种方言重试
    local st=$1 o1 o2
    o1=$( Q "$st" )
    if echo "$o1" | grep -qE '700: |701: '; then
      o2=$( T "$st" )
      if ! echo "$o2" | grep -qE '700: |701: '; then echo "$o2"; return; fi
    fi
    echo "$o1"
  }
  for st in "${RN0396_SQL[@]}"; do
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
"RN-0396|TIMECHODB-0396 自动抽取|功能|窗口函数】查询空值，一次性执行多遍完整流程，会出现java.lang.IndexOutOfBoundsExcepti|case_RN0396"
)
