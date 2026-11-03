#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0433
#   【TIMECHODB-0433】 【树模型】BLOB数据类型，执行last查询，返回的结果集中，Value对应的值显示乱码
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：BLOB数据类型，执行last查询，返回的结果集中，Value对应的值显示正常  复现步骤 （1）开源版master分支，IoTDB启动1C1D （2）root用户进入CLI，执行SQL操作  create timese
# ============================================================================
RN0433_SQL=(
"create timeseries root.sg.d1.s1 with datatype=BLOB"
"insert into root.sg.d1(time,s1) values(now(),X'cafebabe')"
"select * from root.sg.d1"
"select last s1 from root.sg.d1"
"select last_value(s1) from root.sg.d1"
)

case_RN0433() {
  local st out unexpected=0
  for st in "${RN0433_SQL[@]}"; do
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
"TIMECHODB-0433 自动抽取|TIMECHODB-0433|功能|树模型】BLOB数据类型，执行last查询，返回的结果集中，Value对应的值显示乱码|case_RN0433"
)
