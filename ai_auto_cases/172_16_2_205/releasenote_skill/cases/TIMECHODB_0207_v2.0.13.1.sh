#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0207
#   【TIMECHODB-0207】 【树模型SQL】普通用户仅有WRITE_DATA权限，select into目标序列的所属数据库不存在时，对应的Check信息中状态码301需优化
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：普通用户仅有write_data权限，执行select into，目标序列不存在时，校验的状态码应该是803 复现步骤 启动1C1D root用户创建元数据，插入数据，创建用户  [root@xzh-93 timecho
# ============================================================================
RN0207_SQL=(
"create database root.sg"
"create aligned timeseries root.sg.d1(s1 float encoding=rle, s2 int64 encoding=rle)"
"insert into root.sg.d1(time,s1,s2) values(1,1,1),(2,2,2),(3,3,3)"
"CREATE USER user01 'pass1234'"
"GRANT WRITE_DATA ON root.** TO USER user01"
"list privileges of user user01"
"select s1,s2 into root.sg1.d1(s1,s2) from root.sg.d1"
)

case_RN0207() {
  local st out unexpected=0 RN_EXPECT_ERROR=0
  rn_run() {  # 方言自适配：先试首选方言，700/701 解析错误则换另一种方言重试
    local st=$1 o1 o2
    o1=$( T "$st" )
    if echo "$o1" | grep -qE '700: |701: '; then
      o2=$( Q "$st" )
      if ! echo "$o2" | grep -qE '700: |701: '; then echo "$o2"; return; fi
    fi
    echo "$o1"
  }
  for st in "${RN0207_SQL[@]}"; do
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
"RN-0207|TIMECHODB-0207 自动抽取|功能|树模型SQL】普通用户仅有WRITE_DATA权限，select into目标序列的所属数据库不存在时，对应的Che|case_RN0207"
)
