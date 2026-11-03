#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0551
#   【TIMECHODB-0551】 [2.0.6.1][aggregate-processor]视图不能被aggregate-processor捕获处理
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤  create database root.view; create database root.db; -- 非对齐 原始序列 create timeseries root.db.0800200A8C6D.x
# ============================================================================
RN0551_SQL=(
"create database root.view"
"create database root.db"
"create timeseries root.db.0800200A8C6D.xvjeifg with datatype=INT32"
"create timeseries root.db.0800200A8C6D.abcdef with datatype=float"
"insert into root.db.0800200A8C6D(time,xvjeifg,abcdef)values (1,1,5.4)"
"insert into root.db.0800200A8C6D(time,xvjeifg,abcdef)values (11,true,5.4)"
"insert into root.db.0800200A8C6D(time,xvjeifg,abcdef)values (2,2,3.9)"
"create view root.view.nonAligned_device(c1,c2,c3) as select xvjeifg,abcdef,xvjeifg+abcdef from root.db.0800200A8C6D"
"insert into root.view.nonAligned_device(time,c1,c2)values (3,22,23.9)"
"insert into root.view.nonAligned_device(time,c1,c2)values (12,'22',23.9)"
"insert into root.view.nonAligned_device(time,c1,c2)values (4,null,23.9)"
"insert into root.view.nonAligned_device(time,c1,c2)values (5,55,null)"
"insert into root.view.nonAligned_device(time,c3)values (6,109)"
"alter view root.view.nonAligned_device.c1 upsert tags(tag1=v1) attributes(attr1=v1)"
"alter view root.view.nonAligned_device.c3 upsert tags(tag1=v1,tag2=newV2,tag3=v3) attributes(attr3=v3, attr4=v4)"
"create pipe test_type_nonAligned  with source('path'='root.db.0800200A8C6D.**') with processor ('processor'='aggregate-processor','output.database'='root.aggr.non_aligned','sliding.boundary-time'='0','operators'='peak') with sink('sink'='write-back-sink')"
"create pipe test_type_view  with source('path'='root.view.nonAligned_device.**') with processor ('processor'='aggregate-processor','output.database'='root.aggr_view','sliding.boundary-time'='0','operators'='peak') with sink('sink'='write-back-sink')"
"insert into root.db.0800200A8C6D(time,xvjeifg,abcdef)values (now(),332,553.9)"
"show devices"
)

case_RN0551() {
  local st out unexpected=0
  for st in "${RN0551_SQL[@]}"; do
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
"TIMECHODB-0551 自动抽取|TIMECHODB-0551|功能|2.0.6.1][aggregate-processor]视图不能被aggregate-processor捕获处理|case_RN0551"
)
