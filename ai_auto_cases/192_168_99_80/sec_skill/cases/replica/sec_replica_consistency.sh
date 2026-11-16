#!/bin/bash
# ============================================================================
# SEC-09 3C3D（SR=3 / DR=3）副本一致性：安全策略与用户元数据
#   1) 策略在三个 DN 上的生效值一致（enforce/expiry/reuse）
#   2) 经三个 DN 分别做弱密码校验，结果一致（都 820）
#   3) 用户元数据三 DN 指纹一致（新建/改密/删除后仍一致）
#   4) 强密码约束不因"连到不同副本"而不同（三 DN 逐条比对）
#   说明：不在此用例内停 DN —— 停 DN 的一致性校验由 ttl/treeview/crud 等 skill 覆盖，
#         本用例专注"安全策略/元数据在三个副本上的一致性"。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-09" "3C3D 副本一致性：策略与用户元数据（SR3/DR3）"

U="${SEC_USER_PREFIX}_rep"
PW='Abcdefgh123!'
sec_user_drop "$U"

sec_log "--- 1) 策略在三个 DN 上的生效值一致 ---"
base_e=$(sec_conf_get enforce_strong_password)
base_x=$(sec_conf_get password_expiration_days)
base_r=$(sec_conf_get password_reuse_interval_days)
assert_eq "enforce 基线" "$base_e" "true"
bad=0
for h in $DN_NODES; do
  out=$(sec_sql_via "$h" "$SEC_USER" "$SEC_PW" table "show configuration;")
  e=$(printf '%s' "$out" | grep -aE '^\|[[:space:]]*enforce_strong_password[[:space:]]*\|' | head -1 | awk -F'|' '{gsub(/ /,"",$3); print $3}')
  x=$(printf '%s' "$out" | grep -aE '^\|[[:space:]]*password_expiration_days[[:space:]]*\|' | head -1 | awk -F'|' '{gsub(/ /,"",$3); print $3}')
  r=$(printf '%s' "$out" | grep -aE '^\|[[:space:]]*password_reuse_interval_days[[:space:]]*\|' | head -1 | awk -F'|' '{gsub(/ /,"",$3); print $3}')
  if [ "$e" = "$base_e" ] && [ "$x" = "$base_x" ] && [ "$r" = "$base_r" ]; then
    pass "节点 $h 策略生效值与基线一致（$e/$x/$r）"
  else
    fail "节点 $h 策略不一致（$e/$x/$r vs $base_e/$base_x/$base_r）"; bad=$((bad+1))
  fi
done

sec_log "--- 2) 经三个 DN 分别做弱密码校验，结果应一致（都 820）---"
i=0
for h in $DN_NODES; do
  i=$((i+1))
  out=$(sec_sql_via "$h" "$SEC_USER" "$SEC_PW" tree "create user ${U}_w$i 'abcdefghijkl';")
  if printf '%s' "$out" | grep -q '820'; then
    pass "经 DN $h 建弱密码被拒（820）"
  else
    fail "经 DN $h 建弱密码未被拒：$(printf '%s' "$out" | grep -aE 'Error|Msg' | tail -1 | cut -c1-140)"
  fi
  sec_user_drop "${U}_w$i"
done

sec_log "--- 3) 建合法用户 → 三 DN 用户元数据指纹一致 ---"
m=$(sec_user_create "$U" "$PW"); assert_contains "合法用户创建成功" "$m" "successfully"
assert_eq "可登录" "$(sec_login_ok "$U" "$PW" && echo yes || echo no)" "yes"
f1=$(sec_replica_fingerprint "$(echo $DN_NODES | awk '{print $1}')")
f2=$(sec_replica_fingerprint "$(echo $DN_NODES | awk '{print $2}')")
f3=$(sec_replica_fingerprint "$(echo $DN_NODES | awk '{print $3}')")
assert_eq "DN1 与 DN2 指纹" "$f1" "$f2"
assert_eq "DN1 与 DN3 指纹" "$f1" "$f3"

sec_log "--- 4) 改密后三 DN 指纹仍一致 ---"
m=$(sec_user_alter "$U" 'Abcdefgh456@'); assert_contains "改密成功" "$m" "successfully"
f1b=$(sec_replica_fingerprint "$(echo $DN_NODES | awk '{print $1}')")
f2b=$(sec_replica_fingerprint "$(echo $DN_NODES | awk '{print $2}')")
assert_eq "改密后 DN1 与 DN2 指纹" "$f1b" "$f2b"
assert_eq "旧密码已失效" "$(sec_login_ok "$U" "$PW" && echo yes || echo no)" "no"
assert_eq "新密码可登录" "$(sec_login_ok "$U" 'Abcdefgh456@' && echo yes || echo no)" "yes"

sec_log "--- 5) 删除后三 DN 指纹一致 ---"
sec_user_drop "$U"
g1=$(sec_replica_fingerprint "$(echo $DN_NODES | awk '{print $1}')")
g2=$(sec_replica_fingerprint "$(echo $DN_NODES | awk '{print $2}')")
assert_eq "删除后 DN1 与 DN2 指纹" "$g1" "$g2"

sec_case_finish
