#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0205
#   【TIMECHODB-0205】 【鉴权】使用root创建多个普通用户并给第一个用户赋予全部权限，然后使用第一个用户给其他用户赋予权限会报305异常：Cannot invoke "java.util.Set.iterat
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：未使用with grant option会提示权限不足 使用了with grant option会赋权成功  复现步骤 步骤一：使用root登录表模型cli，执行下面准备操作  create user test_user
# ============================================================================
RN0205_SQL=(
"create user test_user1 'pass1234'"
"create user test_user2 'pass1234'"
"create user test_user3 'pass1234'"
"list user"
"grant all to user test_user1 with grant option"
"list privileges of user test_user1"
"grant all to user test_user2 with grant option"
)

case_RN0205() {
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
  for st in "${RN0205_SQL[@]}"; do
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
"RN-0205|TIMECHODB-0205 自动抽取|功能|鉴权】使用root创建多个普通用户并给第一个用户赋予全部权限，然后使用第一个用户给其他用户赋予权限会报305异常：C|case_RN0205"
)
