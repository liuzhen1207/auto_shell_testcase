#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0120
#   【TIMECHODB-0120】 [tree]创建view，show timeseries 时会出现 非用户创建的序列
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：Show timeseries 没有多余的序列  复现步骤 http://172.20.70.33:13000/pipe/list?id=12235&test_case_id=430 应该还是和pipe相关，因为在发送端
# ============================================================================
RN0120_SQL=(
"create database root.db"
"create timeseries root.db.tc18_device.s01 with datatype=INT32"
"create timeseries root.db.tc18_device.s02 with datatype=INT32"
"CREATE VIEW root.db.tc18_device.status, root.db.tc18_device.sub.hardware AS SELECT s01,s02 FROM root.db.tc18_device"
"insert into root.db.tc18_device(time,s01,s02,status) values(1,1,1,2)"
"insert into root.db.tc18_device.sub(time,hardware) values(2,22)"
"show timeseries root.db.tc18_device.**"
)

case_RN0120() {
  local st out unexpected=0
  for st in "${RN0120_SQL[@]}"; do
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
"TIMECHODB-0120 自动抽取|TIMECHODB-0120|功能|tree]创建view，show timeseries 时会出现 非用户创建的序列|case_RN0120"
)
