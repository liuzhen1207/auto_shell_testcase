#!/bin/bash
# ============================================================================
# sec_skill 运行入口
#   bash tools/run_all.sh [--set quick|all|password|config|audit|replica|auth|stale|cli|identity|lock|exempt|lockparam|authlog|length|complexity|username|enforce|reuse|expire]
#                         [--only SEC-01,SEC-05] [--mode auto|normal|sep]
#   结果：results/test_result.csv（build/mode/case/result/elapsed/failCount/...）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"

SET=all; ONLY=""; MODE=auto; CONSENSUS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --set) SET="$2"; shift 2 ;;
    --set=*) SET="${1#*=}"; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    --mode) MODE="$2"; shift 2 ;;
    --mode=*) MODE="${1#*=}"; shift ;;
    --consensus) CONSENSUS="$2"; shift 2 ;;
    *) shift ;;
  esac
done
export SEC_MODE="$MODE"

declare -A CASES=(
  ["SEC-01"]="cases/password/sec_password_length.sh|密码长度上下限"
  ["SEC-02"]="cases/password/sec_password_complexity.sh|复杂度四要素"
  ["SEC-03"]="cases/password/sec_password_username.sh|密码≠用户名"
  ["SEC-04"]="cases/password/sec_enforce_switch.sh|强密码开关语义"
  ["SEC-05"]="cases/password/sec_password_reuse.sh|历史口令重用"
  ["SEC-06"]="cases/password/sec_password_expire.sh|有效期+提示（时钟前移）"
  ["SEC-07"]="cases/config/sec_config_privilege.sh|默认值/热加载/权限"
  ["SEC-08"]="cases/audit/sec_audit_logs.sh|审计与日志"
  ["SEC-09"]="cases/replica/sec_replica_consistency.sh|SR3/DR3 一致性"
  ["SEC-10"]="cases/password/sec_password_stale_warning.sh|密码定期更改提示"
  ["SEC-11"]="cases/auth/sec_auth_cli_password.sh|客户端隐式密码输入"
  ["SEC-12"]="cases/auth/sec_auth_identity_basic.sh|身份鉴别基础"
  ["SEC-13"]="cases/auth/sec_auth_login_lock.sh|防爆破锁定+手动解锁"
  ["SEC-14"]="cases/auth/sec_auth_lock_exempt.sh|锁定豁免/自动解锁/DROP清锁"
  ["SEC-15"]="cases/auth/sec_auth_lock_params.sh|防爆破参数边界与权限"
  ["SEC-16"]="cases/audit/sec_auth_audit_logs.sh|鉴别/锁定审计日志"
)
ORDER=(SEC-01 SEC-02 SEC-03 SEC-04 SEC-05 SEC-06 SEC-07 SEC-08 SEC-09 SEC-10 SEC-11 SEC-12 SEC-13 SEC-14 SEC-15 SEC-16)

select_ids(){
  case "$SET" in
    quick) echo "SEC-01 SEC-02 SEC-03 SEC-07" ;;
    auth) echo "SEC-11 SEC-12 SEC-13 SEC-14 SEC-15 SEC-16" ;;
    stale) echo "SEC-10" ;;
    cli) echo "SEC-11" ;;
    identity) echo "SEC-12" ;;
    lock) echo "SEC-13" ;;
    exempt) echo "SEC-14" ;;
    lockparam) echo "SEC-15" ;;
    authlog) echo "SEC-16" ;;
    password) echo "SEC-01 SEC-02 SEC-03 SEC-04 SEC-05" ;;
    config) echo "SEC-04 SEC-07" ;;
    audit) echo "SEC-08" ;;
    replica) echo "SEC-09" ;;
    length) echo "SEC-01" ;;
    complexity) echo "SEC-02" ;;
    username) echo "SEC-03" ;;
    enforce) echo "SEC-04" ;;
    reuse) echo "SEC-05" ;;
    expire) echo "SEC-06" ;;
    all) echo "${ORDER[*]}" ;;
    *) echo "未知 --set: $SET" >&2; exit 2 ;;
  esac
}

IDS=$(select_ids) || exit 2
[ -n "$ONLY" ] && IDS=$(echo "$ONLY" | tr ',' ' ')

echo "=============================================================="
echo " sec_skill 强安全级别密码回归（build=$BUILD_TAG, mode=$MODE）"
echo " 用例: $IDS"
echo "=============================================================="

DETECTED=$SEC_MODE
TOTAL=0; FAILN=0
for id in $IDS; do
  entry="${CASES[$id]:-}"
  [ -z "$entry" ] && { echo "跳过未知用例 $id"; continue; }
  script="${entry%%|*}"; title="${entry##*|}"
  echo
  echo "----- $id $title（$script）-----"
  ( cd "$HERE/.." && bash "$script" --mode "$MODE" $([ -n "$CONSENSUS" ] && echo "--consensus $CONSENSUS") ) 2>&1
  rc=$?
  TOTAL=$((TOTAL+1))
  [ $rc -ne 0 ] && FAILN=$((FAILN+1))
done

echo
echo "===== 汇总（mode=$MODE）：执行 $TOTAL 条，非 0 退出 $FAILN 条 ====="
if [ -f "$HERE/../results/test_result.csv" ]; then
  echo "明细 CSV：$HERE/../results/test_result.csv"
  tail -n "$TOTAL" "$HERE/../results/test_result.csv" | awk -F, '{printf "  %-8s %-6s %-6s %s\n", $4, $5, $6"s", $3}'
fi
[ $FAILN -eq 0 ] && exit 0 || exit 1
