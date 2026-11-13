#!/bin/bash
# ============================================================================
# 三权分立模式切换（LBAC 套件专用）
#   on  : 用 root 热加载开启（仅能从未开启状态执行）
#   off : 写配置 false + 重启集群（三权分立下 SQL 无法关闭）
#   status : 查看 root / 三个管理员登录情况
# ============================================================================
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$BASE/conf/env.conf"

ACT="${1:-status}"
TREE_CLI() { timeout 60 $CLI -h "$HOST" -p 6667 -u "$1" -pw "$2" -sql_dialect tree -e "$3" 2>&1; }
TBL_CLI()  { timeout 60 $CLI -h "$HOST" -p 6667 -u "$1" -pw "$2" -sql_dialect table -e "$3" 2>&1; }

case "$ACT" in
  on)
    echo "[$(date +%T)] 开启三权分立（root 热加载）"
    TREE_CLI root "$PW" "set configuration 'enable_separation_of_powers'='true'" | head -2
    sleep 5
    echo -n "  root 登录: "; TBL_CLI root "$PW" "show cluster" | head -1
    for u in "$SYS_ADMIN" "$SEC_ADMIN" audit_admin; do
      echo -n "  $u: "; TBL_CLI "$u" "$ADMIN_PW" "show cluster" | head -1
    done
    ;;
  off)
    echo "[$(date +%T)] 关闭三权分立（写配置 + 重启集群）"
    for ip in $CN_LIST; do
      ssh -n -o StrictHostKeyChecking=no root@$ip "f=$CN_DIR/conf/iotdb-system.properties; touch \$f; sed -i '/^enable_separation_of_powers=/d' \$f; echo 'enable_separation_of_powers=false' >> \$f" 2>/dev/null
    done
    for ip in $DN_LIST; do
      ssh -n -o StrictHostKeyChecking=no root@$ip "f=$DN_DIR/conf/iotdb-system.properties; touch \$f; sed -i '/^enable_separation_of_powers=/d' \$f; echo 'enable_separation_of_powers=false' >> \$f" 2>/dev/null
    done
    # 停全部
    for ip in $CN_LIST $DN_LIST; do
      ssh -n -o StrictHostKeyChecking=no root@$ip "pkill -9 -f 'com.timecho.iotdb' 2>/dev/null; true" 2>/dev/null
    done
    sleep 8
    # 起 CN
    for ip in $CN_LIST; do
      ssh -n -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd $CN_DIR; nohup $CN_DIR/sbin/start-confignode.sh -H $CN_DIR/cn.hprof > $CN_DIR/start_cn.log 2>&1 &" 2>/dev/null
      sleep 5
    done
    sleep 20
    for ip in $DN_LIST; do
      ssh -n -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd $DN_DIR; nohup $DN_DIR/sbin/start-datanode.sh -H $DN_DIR/dn.hprof > $DN_DIR/start_dn.log 2>&1 &" 2>/dev/null
      sleep 3
    done
    n=0
    for i in $(seq 1 80); do
      n=$(TBL_CLI root "$PW" "show cluster" 2>/dev/null | grep -c Running)
      [ "$n" -ge 8 ] && break
      sleep 8
    done
    echo "  Running=$n"
    ;;
  status)
    echo -n "root: "; TBL_CLI root "$PW" "show cluster" | head -1
    for u in "$SYS_ADMIN" "$SEC_ADMIN" audit_admin; do
      echo -n "$u: "; TBL_CLI "$u" "$ADMIN_PW" "show cluster" | head -1
    done
    ;;
  *)
    echo "usage: mode_sep.sh on|off|status"; exit 2 ;;
esac
