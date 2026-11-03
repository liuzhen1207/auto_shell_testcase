#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0280
#   【TIMECHODB-0280】 【TsFile 2.1.0】使用在Window编译下python tsfile的whl包，无法查询IoTDB的data目录中的TsFile数据
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：可以正常查询IoTDB中data目录的tsfile数据  复现步骤 以使用复现的TsFile或执行下面代码，生成如下图表结构，使用flush落盘后data目录的TsFile  1747704088443-1-0-0.ts
# ============================================================================
RN0280_SQL=(
"create database test"
"create table t1(tag1 STRING TAG, attr1 STRING ATTRIBUTE, s1 DOUBLE FIELD)"
"insert into t1(time, tag1, attr1, s1) values(0, 'tag1', 'attr1' ,1.1)"
"insert into t1(time, tag1, attr1, s1) values(1, null, null ,null)"
"insert into t1(time, tag1, attr1, s1) values(2, 'tag1', 'attr1' ,1.1)"
"insert into t1(time, tag1, attr1, s1) values(3, null, null ,null)"
"insert into t1(time, tag1, attr1, s1) values(4, 'tag1', 'attr1' ,1.1)"
"insert into t1(time, tag1, attr1, s1) values(5, null, null ,null)"
"insert into t1(time, tag1, attr1, s1) values(6, 'tag1', 'attr1' ,1.1)"
"insert into t1(time, tag1, attr1, s1) values(7, null, null ,null)"
"insert into t1(time, tag1, attr1, s1) values(8, 'tag1', 'attr1' ,1.1)"
"insert into t1(time, tag1, attr1, s1) values(9, null, null ,null)"
)

case_RN0280() {
  local st out unexpected=0
  for st in "${RN0280_SQL[@]}"; do
    out=$( Q "$st" )
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
"TIMECHODB-0280 自动抽取|TIMECHODB-0280|功能|TsFile 2.1.0】使用在Window编译下python tsfile的whl包，无法查询IoTDB的data|case_RN0280"
)
