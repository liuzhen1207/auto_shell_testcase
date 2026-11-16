#!/bin/bash
# ============================================================================
# 三权分立模式切换（sec_skill 专用）
#   on  : root 热加载开启（仅能从"未开启"状态执行）
#   off : 写配置 false + 重启集群（开启后 root 无法登录，只能改配置重启）
#   status : 打印三种登录结果 + 三个安全配置值
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"

ACT="${1:-status}"
sql_as(){ printf 'set sql_dialect=%s;\n%s\n' "$3" "$4" | timeout 60 "$CLI" -h "$PRIMARY" -u "$1" -pw "$2" 2>&1; }

case "$ACT" in
  on)
    echo "[$(date +%T)] 开启三权分立（root 热加载 set configuration）"
    sql_as root "$ROOT_PW" tree "set configuration 'enable_separation_of_powers'='true';" | grep -aE 'Msg|Error' | head -2
    sleep 8
    echo -n "  root 登录: "; sql_as root "$ROOT_PW" table "show cluster;" | grep -aE 'Error|Running' | head -1
    for u in "$SYS_ADMIN" "$SEC_ADMIN" "$AUDIT_ADMIN"; do
      echo -n "  $u: "; sql_as "$u" "$ADMIN_PW" table "show cluster;" | grep -aE 'Error|Running' | head -1
    done
    ;;
  off)
    echo "[$(date +%T)] 关闭三权分立（写配置 false + 重启）"
    for h in $ALL_NODES; do
      sshx "$h" "F=$DB_DIR/conf/iotdb-system.properties; touch \$F; sed -i '/^enable_separation_of_powers=/d' \$F; echo 'enable_separation_of_powers=false' >> \$F"
    done
    sec_stop_cluster
    sec_start_cluster
    echo -n "  root 登录: "; sql_as root "$ROOT_PW" table "show cluster;" | grep -aE 'Error|Running' | head -1
    ;;
  status)
    echo "== 模式探测 =="
    out=$(sql_as root "$ROOT_PW" tree "show cluster;")
    if printf '%s' "$out" | grep -q '803'; then echo "  当前：三权分立（sep）— root 被禁"; else echo "  当前：普通模式（normal）"; fi
    for u in root "$SYS_ADMIN" "$SEC_ADMIN" "$AUDIT_ADMIN"; do
      pw="$ROOT_PW"; [ "$u" != "root" ] && pw="$ADMIN_PW"
      r=$(sql_as "$u" "$pw" table "show cluster;" | grep -aE 'Error|Running' | head -1 | cut -c1-90)
      echo "  $u: $r"
    done
    echo "== 安全配置 =="
    sec_bind_users
    for k in enforce_strong_password password_expiration_days password_reuse_interval_days; do
      echo "  $k = $(sec_conf_get $k)"
    done
    ;;
  *) echo "用法: bash tools/mode_sep.sh on|off|status" >&2; exit 2 ;;
esac
