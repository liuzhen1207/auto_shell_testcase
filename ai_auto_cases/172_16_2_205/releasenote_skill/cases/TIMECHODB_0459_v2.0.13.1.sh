#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0459
#   【TIMECHODB-0459】 【表模型-权限】创建用户失败后，再次修改未创建成功的用户密码，报305内部服务异常
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：创建用户失败后，再次修改未创建成功的用户密码，应该报用户不存在  复现步骤 （1）开源版，master分支，commit f407b66f698ce62ae4fcaee9ef0324397687b885 （2）启动1C1
# ============================================================================
RN0459_SQL=(
"create user user01 'pass123456789'"
"grant manage_user to user user01 with grant option"
"create user test_user '1234'"
"alter user test_user set password 'pass123456789'"
)

case_RN0459() {
  local st out unexpected=0
  for st in "${RN0459_SQL[@]}"; do
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
"TIMECHODB-0459 自动抽取|TIMECHODB-0459|功能|表模型-权限】创建用户失败后，再次修改未创建成功的用户密码，报305内部服务异常|case_RN0459"
)
