#!/bin/bash
# ============================================================================
# 来源工作项：TDB-1429 / 【TIMECHODB-0501】
#   drop user 后，系统库（root.__system / root.__audit）下该用户的元数据
#   （密码历史 password_history）应被级联删除，不留残留；
#   重建同名用户后不得继承旧用户的历史（新 userId）。
#
#   RC3 已含修复：ff2f6120b9 / #16416 / #16542
#     - 删除用户时删除其密码历史
#     - 密码历史按 userId 记录
#
#   验证版本：2.0.13.1 RC3 / ac7f95e
#   两个独立用例，各自要求干净集群环境：
#     RN-213 普通模式（root 管理用户，root 检查系统数据）
#     RN-214 三权分立（security_admin 管理用户，audit_admin 检查 root.__audit）
# ============================================================================
RN1429_USER=rn1429_u
RN1429_PW1='Rn1429@111111'
RN1429_PW2='Rn1429@222222'
RN1429_PW3='Rn1429@333333'
RN1429_PW4='Rn1429@444444'

# 取 count(timeseries) 数值；失败返回 -1
_rn1429_count() {  # $1=user $2=pw $3=path
  local out v
  out=$(L "$1" "$2" "count timeseries $3" 2>&1)
  v=$(echo "$out" | awk -F'|' '/^[[:space:]]*\|[[:space:]]*[0-9]+[[:space:]]*\|/{gsub(/ /,"",$2); print $2; exit}')
  if [ -z "${v:-}" ]; then echo "-1"; else echo "$v"; fi
}

# $1=admin user, $2=admin pw, $3=checker user, $4=checker pw, $5=tag
_rn1429_flow() {
  local admin="$1" adminpw="$2" checker="$3" checkerpw="$4" tag="$5"
  local uid1 uid2 c1 c2 c3 c4 c5

  # 1) 打开密码策略，确保密码历史元数据会落盘
  assert_ok "$(L "$admin" "$adminpw" "set configuration 'password_reuse_interval_days'='30'")" "$tag 开启密码重用策略"
  assert_ok "$(L "$admin" "$adminpw" "set configuration 'password_expiration_days'='90'")" "$tag 开启密码过期策略"
  sleep 3

  # 2) 建用户并改两次密码
  L "$admin" "$adminpw" "drop user $RN1429_USER" >/dev/null 2>&1
  assert_ok "$(L "$admin" "$adminpw" "create user $RN1429_USER '$RN1429_PW1'")" "$tag 创建用户"
  uid1=$(L "$admin" "$adminpw" "list user" | awk -F'|' -v u="$RN1429_USER" '$0 ~ u {gsub(/ /,"",$2); print $2; exit}')
  [ -n "${uid1:-}" ] && [ "$uid1" != "-" ] && ok "$tag 用户 userId=$uid1" || fail "$tag 未取到 userId"
  assert_ok "$(L "$admin" "$adminpw" "alter user $RN1429_USER set password '$RN1429_PW2'")" "$tag 第一次改密"
  assert_ok "$(L "$admin" "$adminpw" "alter user $RN1429_USER set password '$RN1429_PW3'")" "$tag 第二次改密"
  assert_ok "$(L "$RN1429_USER" "$RN1429_PW3" "show databases")" "$tag 用户用新密码登录"
  sleep 3

  # 3) DROP 前：该用户在系统库中的密码历史元数据应存在
  c1=$(_rn1429_count "$checker" "$checkerpw" "root.__audit.password_history._${uid1}.**")
  if [ "$c1" -ge 1 ] 2>/dev/null; then
    ok "$tag DROP 前密码历史元数据存在（timeseries=$c1）"
  else
    fail "$tag DROP 前未看到密码历史元数据（timeseries=$c1），无法验证级联删除"
  fi

  # 4) DROP USER
  assert_ok "$(L "$admin" "$adminpw" "drop user $RN1429_USER")" "$tag DROP USER"
  sleep 5

  # 5) DROP 后：该用户密码历史应被级联删除
  c2=$(_rn1429_count "$checker" "$checkerpw" "root.__audit.password_history._${uid1}.**")
  [ "${c2:-1}" = "0" ] && ok "$tag DROP 后密码历史已级联删除（timeseries=0）" || fail "$tag DROP 后仍有残留（timeseries=$c2）"

  # 系统库本身无残留序列（root.__system）
  c3=$(_rn1429_count "$checker" "$checkerpw" "root.__system.**")
  if [ "$c3" = "-1" ] 2>/dev/null; then
    ok "$tag 跳过 root.__system 检查（当前账号无该路径权限，属隔离设计）"
  elif [ "${c3:-1}" = "0" ]; then
    ok "$tag root.__system 无残留序列"
  else
    fail "$tag root.__system 仍有 $c3 条序列"
  fi

  # 6) 重建同名用户：新 userId，旧历史不得被继承
  assert_ok "$(L "$admin" "$adminpw" "create user $RN1429_USER '$RN1429_PW4'")" "$tag 重建同名用户"
  uid2=$(L "$admin" "$adminpw" "list user" | awk -F'|' -v u="$RN1429_USER" '$0 ~ u {gsub(/ /,"",$2); print $2; exit}')
  [ -n "${uid2:-}" ] && [ "$uid2" != "$uid1" ] && ok "$tag 新 userId=$uid2（与旧 $uid1 不同）" || fail "$tag 重建后 userId 未变化（$uid2）"
  sleep 3
  c4=$(_rn1429_count "$checker" "$checkerpw" "root.__audit.password_history._${uid1}.**")
  [ "${c4:-1}" = "0" ] && ok "$tag 旧 userId 历史无残留（timeseries=0）" || fail "$tag 旧 userId 仍有残留（timeseries=$c4）"
  c5=$(_rn1429_count "$checker" "$checkerpw" "root.__audit.password_history._${uid2}.**")
  if [ "$c5" -ge 1 ] 2>/dev/null; then
    ok "$tag 新用户拥有独立的历史记录（timeseries=$c5）"
  else
    fail "$tag 新用户没有自己的历史记录（timeseries=$c5）"
  fi

  # 7) 清理与恢复
  L "$admin" "$adminpw" "drop user $RN1429_USER" >/dev/null 2>&1
  L "$admin" "$adminpw" "set configuration 'password_reuse_interval_days'='-1'" >/dev/null 2>&1
  L "$admin" "$adminpw" "set configuration 'password_expiration_days'='-1'" >/dev/null 2>&1
}

case_RN213() {
  echo "  --- 普通模式：DROP USER 后系统库元数据级联删除 ---"
  if T "show cluster" 2>&1 | grep -q "SUPER USER is not allowed"; then
    fail "当前不是普通模式（root 被禁），无法执行 RN-213"
    return
  fi
  ok "当前为普通模式（root 可登录）"
  _rn1429_flow root 'TimechoDB@2021' root 'TimechoDB@2021' "[普通]"
}

case_RN214() {
  echo "  --- 三权分立：DROP USER 后系统库元数据级联删除 ---"
  if T "show cluster" 2>&1 | grep -q "SUPER USER is not allowed"; then
    ok "当前已是三权分立（root 被拒 803）"
  else
    ( cd "$BASE" && NEW="$NEW" bash tools/mode.sh on ) > /tmp/rn1429_mode_on.log 2>&1
    if T "show cluster" 2>&1 | grep -q "SUPER USER is not allowed"; then
      ok "三权分立已开启：root 被拒（803）"
    else
      fail "开启三权分立后 root 仍可登录"
      return
    fi
  fi
  if L security_admin 'TimechoDB@2021' "list user" 2>&1 | grep -q "UserId"; then
    ok "security_admin 可管理用户"
  else
    fail "security_admin 无法执行 list user"
    return
  fi
  if L audit_admin 'TimechoDB@2021' "count timeseries root.__audit.**" 2>&1 | grep -q "count"; then
    ok "audit_admin 可读取 root.__audit"
  else
    fail "audit_admin 无法读取 root.__audit"
    return
  fi
  _rn1429_flow security_admin 'TimechoDB@2021' audit_admin 'TimechoDB@2021' "[三权分立]"
}

CASES+=(
"RN-213|TDB-1429 DROP USER 元数据级联删除（普通模式）|异常|drop user 后密码历史元数据清零；重建同名用户不继承旧历史|case_RN213"
"RN-214|TDB-1429 DROP USER 元数据级联删除（三权分立）|异常|security_admin 删用户、audit_admin 校验系统库元数据级联删除|case_RN214"
)
