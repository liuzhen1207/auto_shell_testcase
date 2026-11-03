#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0099
#   【TIMECHODB-0099】 DB与Table反复设置TTL后，导致插入数据查询不到，返回空列表
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：插入数据后，可以正常查询到  复现步骤 --（1）先创建一个1h ttl的db，然后手动创建一个TTL为inf的table1，往table1里写时间戳为1的数据等待一段时间,等CN上分区清理结束 create datab
# ============================================================================
RN0099_SQL=(
"create database dba1 with(TTL=3600000,TIME_PARTITION_INTERVAL=86400000, SCHEMA_REGION_GROUP_NUM=1, DATA_REGION_GROUP_NUM=2)"
"create table dba1.table1(ID TAG, int INT32 FIELD) with(TTL='INF')"
"insert into dba1.table1 values(1,'D1',1)"
"select * from dba1.table1"
"insert into dba1.table1 values(now(),'D1',1)"
)

case_RN0099() {
  local st out unexpected=0
  for st in "${RN0099_SQL[@]}"; do
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
"TIMECHODB-0099 自动抽取|TIMECHODB-0099|功能|DB与Table反复设置TTL后，导致插入数据查询不到，返回空列表|case_RN0099"
)
