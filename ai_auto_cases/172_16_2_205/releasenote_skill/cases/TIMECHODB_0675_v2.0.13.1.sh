#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0675
#   【TIMECHODB-0675】 [2.0.7.1][用户连接数限制]1c1d 多用户配置，有几率实际连接数大于最大连接数
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤 启动1c1d dn_rpc_max_concurrent_client_num=14 执行sql  create user user01 'UserPassword@1245'; create user use
# ============================================================================
RN0675_SQL=(
"create user user01 'UserPassword@1245'"
"create user user02 'UserPassword@2355'"
"create user user03 'UserPassword@445'"
"ALTER USER user01 SET MIN_SESSION_PER_USER 2"
"ALTER USER user01 SET MAX_SESSION_PER_USER 3"
"ALTER USER user02 SET MIN_SESSION_PER_USER 2"
"ALTER USER user02 SET MAX_SESSION_PER_USER 2"
"ALTER USER user03 SET MIN_SESSION_PER_USER 3"
"ALTER USER user03 SET MAX_SESSION_PER_USER 4"
)

case_RN0675() {
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
  for st in "${RN0675_SQL[@]}"; do
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
"RN-0675|TIMECHODB-0675 自动抽取|功能|2.0.7.1][用户连接数限制]1c1d 多用户配置，有几率实际连接数大于最大连接数|case_RN0675"
)
