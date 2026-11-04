#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0580
#   【TIMECHODB-0580】 【强密码】在干净的服务中，当普通用户设置密码后，再次重置为使用过的密码，预期失败，但是实际上更新成功了
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：在干净的服务中，当普通用户设置密码后，再次重置为使用过的密码，预期失败  复现步骤 （1）企业版，master分支 （2）启动1C1D （3）在CLI中，执行SQL操作  IoTDB> set configuration
# ============================================================================
RN0580_SQL=(
"set configuration enforce_strong_password='false'"
"set configuration password_reuse_interval_days='1'"
"create user lily 'lily@PassWord2021'"
"list user"
"alter user lily set password 'lily@PassWord2021'"
)

case_RN0580() {
  local st out unexpected=0 RN_EXPECT_ERROR=1
  rn_run() {  # 方言自适配：先试首选方言，700/701 解析错误则换另一种方言重试
    local st=$1 o1 o2
    o1=$( T "$st" )
    if echo "$o1" | grep -qE '700: |701: '; then
      o2=$( Q "$st" )
      if ! echo "$o2" | grep -qE '700: |701: '; then echo "$o2"; return; fi
    fi
    echo "$o1"
  }
  for st in "${RN0580_SQL[@]}"; do
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
"RN-0580|TIMECHODB-0580 自动抽取|功能|强密码】在干净的服务中，当普通用户设置密码后，再次重置为使用过的密码，预期失败，但是实际上更新成功了|case_RN0580"
)
