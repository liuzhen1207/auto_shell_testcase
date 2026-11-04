#!/bin/bash
# ============================================================================
# 三权分立模式切换（releasenote_skill 专用）
#   usage: mode.sh on|off|audit-on|audit-off|status
#   on  : 热加载开启（set configuration enable_separation_of_powers=true）
#   off : 写回 false 并重启集群（hard_reset），恢复到 normal 模式
# ============================================================================
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
for _p in "$BASE/conf/env.conf"; do [ -f "$_p" ] && . "$_p" && break; done
for _p in "$BASE/lib/lib_rn.sh"; do [ -f "$_p" ] && . "$_p" && break; done

CN_DIR=${CN_DIR:-/data/iotdb/$NEW}
DN_DIR=${DN_DIR:-/data1/iotdb/$NEW}

ACT="${1:-status}"
case "$ACT" in
  on)
    echo "[$(date +%T)] 开启三权分立（热加载）"
    T "set configuration 'enable_separation_of_powers'='true'" | head -2
    sleep 5
    T "show variables" 2>/dev/null | grep -i 'separation' | head -2
    ;;
  off)
    echo "[$(date +%T)] 关闭三权分立（写配置 + 重启）"
    for ip in $CN_LIST; do
      ssh -o StrictHostKeyChecking=no root@$ip "f=$CN_DIR/conf/iotdb-system.properties; touch \$f; sed -i '/^enable_separation_of_powers=/d' \$f; echo 'enable_separation_of_powers=false' >> \$f" 2>/dev/null
    done
    for ip in $DN_LIST; do
      ssh -o StrictHostKeyChecking=no root@$ip "f=$DN_DIR/conf/iotdb-system.properties; touch \$f; sed -i '/^enable_separation_of_powers=/d' \$f; echo 'enable_separation_of_powers=false' >> \$f" 2>/dev/null
    done
    ( cd /data2/auto_test/treeview_suite && NEW="$NEW" bash hard_reset.sh > /tmp/rn_mode_off.log 2>&1 )
    wait_running 480 >/dev/null 2>&1 || true
    echo "  恢复后 Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"
    ;;
  audit-on)
    echo "[$(date +%T)] 开启审计日志（需重启）"
    for ip in $CN_LIST; do
      ssh -o StrictHostKeyChecking=no root@$ip "f=$CN_DIR/conf/iotdb-system.properties; touch \$f; sed -i '/^enable_audit_log=/d' \$f; echo 'enable_audit_log=true' >> \$f" 2>/dev/null
    done
    for ip in $DN_LIST; do
      ssh -o StrictHostKeyChecking=no root@$ip "f=$DN_DIR/conf/iotdb-system.properties; touch \$f; sed -i '/^enable_audit_log=/d' \$f; echo 'enable_audit_log=true' >> \$f" 2>/dev/null
    done
    ( cd /data2/auto_test/treeview_suite && NEW="$NEW" bash hard_reset.sh > /tmp/rn_audit_on.log 2>&1 )
    wait_running 480 >/dev/null 2>&1 || true
    echo "  Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"
    ;;
  audit-off)
    echo "[$(date +%T)] 关闭审计日志（需重启）"
    for ip in $CN_LIST; do
      ssh -o StrictHostKeyChecking=no root@$ip "f=$CN_DIR/conf/iotdb-system.properties; touch \$f; sed -i '/^enable_audit_log=/d' \$f; echo 'enable_audit_log=false' >> \$f" 2>/dev/null
    done
    for ip in $DN_LIST; do
      ssh -o StrictHostKeyChecking=no root@$ip "f=$DN_DIR/conf/iotdb-system.properties; touch \$f; sed -i '/^enable_audit_log=/d' \$f; echo 'enable_audit_log=false' >> \$f" 2>/dev/null
    done
    ( cd /data2/auto_test/treeview_suite && NEW="$NEW" bash hard_reset.sh > /tmp/rn_audit_off.log 2>&1 )
    wait_running 480 >/dev/null 2>&1 || true
    echo "  Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"
    ;;
  status)
    T "show variables" 2>/dev/null | grep -i 'separation' | head -3
    ;;
  *)
    echo "usage: mode.sh on|off|audit-on|audit-off|status"; exit 2 ;;
esac
