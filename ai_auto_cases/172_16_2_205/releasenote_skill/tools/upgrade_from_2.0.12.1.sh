#!/bin/bash
# ============================================================================
# 升级兼容验证：2.0.12.1 RC12 → 当前 RC2（原地升级，保留数据）
#
# 用法：
#   bash tools/upgrade_from_2.0.12.1.sh                 # 默认参数（见下）
#   RC12_PKG=/data2/iotdb/v20121rc12_1027_c05111d \
#   RC2_BUILD=v20131rc2_1110_83183d0 \
#   WORK=v20121rc12_up \
#   bash tools/upgrade_from_2.0.12.1.sh
#
# 参数（环境变量）：
#   RC12_PKG   旧版本已解包目录（含 lib/ sbin/ conf/），默认 /data2/iotdb/v20121rc12_1027_c05111d
#   RC2_BUILD  目标版本构建目录名（/data2/iotdb 下），默认 v20131rc2_1110_83183d0
#   WORK       升级用目录名（保持同名，原地换包），默认 v20121rc12_up
#   KEEP_CLUSTER=1  验证后保留升级目录集群；默认 0 = 验证完恢复到正式 RC2 集群
#
# 前置：集群当前可在任意版本运行，本脚本会停掉它。
# 注意：会清空 WORK 目录的数据（hard_reset），不影响其他构建目录。
# ============================================================================
set -u
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RC12_PKG=${RC12_PKG:-/data2/iotdb/v20121rc12_1027_c05111d}
RC2_BUILD=${RC2_BUILD:-v20131rc2_1110_83183d0}
WORK=${WORK:-v20121rc12_up}
KEEP_CLUSTER=${KEEP_CLUSTER:-0}
DST_BUILD=${DST_BUILD:-v20131rc2_1110_83183d0}

CN_LIST=${CN_LIST:-172.16.2.26 172.16.2.27 172.16.2.28}
DN_LIST=${DN_LIST:-172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6}
CN26=$(echo "$CN_LIST" | awk '{print $1}')
PW=${PW:-TimechoDB@2021}
RC2_PKG=/data2/iotdb/$RC2_BUILD/pkg/timechodb-2.0.13.1-bin
TS=$(date +%Y%m%d_%H%M%S)
LOG=/tmp/upgrade_${TS}.log
RES="$SKILL_DIR/results/upgrade_${TS}.md"
CLI=/data2/iotdb/$WORK/sbin/start-cli.sh

log() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }
Q() { timeout 40 $CLI -h 172.16.2.2 -p 6667 -u root -pw "$PW" -sql_dialect table -e "$1" 2>&1; }
T() { timeout 40 $CLI -h 172.16.2.2 -p 6667 -u root -pw "$PW" -sql_dialect tree  -e "$1" 2>&1; }

declare -A R=()
step() { R["$1"]="$2"; log "  [$2] $1"; }

wait_running() {  # $1 = 期望节点数（默认 8），$2 = 超时秒（默认 480）
  local want=${1:-8} t=${2:-480} i=0 n=0
  while [ $i -lt $((t / 8)) ]; do
    n=$(T "show cluster;" 2>/dev/null | grep -c Running)
    [ "$n" -ge "$want" ] && { echo "$n"; return 0; }
    sleep 8; i=$((i + 1))
  done
  echo "$n"; return 1
}

deploy_old() {
  log "部署 RC12 到 $WORK（清数据）"
  ssh -n -o StrictHostKeyChecking=no root@172.16.2.205 \
    "cd /data2/auto_test/treeview_suite && NEW=$WORK PKG_DIR=$RC12_PKG OLD_CN=/data/iotdb/$DST_BUILD OLD_DN=/data1/iotdb/$DST_BUILD setsid bash deploy_build.sh > /tmp/upgrade_deploy.log 2>&1 < /dev/null" 2>/dev/null
  local i
  for i in $(seq 1 40); do grep -q "deploy done" /tmp/upgrade_deploy.log 2>/dev/null && break; sleep 10; done
  # 客户端目录兜底（deploy 有时不复制 client 的 sbin/lib）
  if [ ! -x /data2/iotdb/$WORK/sbin/start-cli.sh ]; then
    mkdir -p /data2/iotdb/$WORK
    cp -a "$RC12_PKG"/lib "$RC12_PKG"/sbin "$RC12_PKG"/tools "$RC12_PKG"/conf /data2/iotdb/$WORK/ 2>/dev/null
  fi
  ( cd /data2/auto_test/treeview_suite && NEW=$WORK setsid bash hard_reset.sh > /tmp/upgrade_reset_old.log 2>&1 < /dev/null & )
  local n; n=$(wait_running 8 480)
  [ "$n" -ge 8 ]
}

create_old_data() {  # $1 = db
  local db=$1
  Q "CREATE DATABASE $db" >/dev/null 2>&1
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "insert into root.$db.dev01(time,s1) values(1000,1.5)" >/dev/null 2>&1
  Q "create view $db.v1(dev string tag) as root.$db.**" >/dev/null 2>&1
}

stop_all() {
  local ip
  for ip in $DN_LIST; do
    ssh -n -o StrictHostKeyChecking=no root@$ip "bash /data1/iotdb/$WORK/sbin/stop-datanode.sh >/dev/null 2>&1; pkill -9 -f 'com.timecho.iotdb.DataNode' 2>/dev/null; true" 2>/dev/null
  done
  for ip in $CN_LIST; do
    ssh -n -o StrictHostKeyChecking=no root@$ip "bash /data/iotdb/$WORK/sbin/stop-confignode.sh >/dev/null 2>&1; pkill -9 -f 'com.timecho.iotdb.ConfigNode' 2>/dev/null; true" 2>/dev/null
  done
  sleep 8
}

swap_in_rc2() {
  local ip
  # 注意：往远端传 tar 时不能用 ssh -n（stdin 会被置空）
  for ip in $CN_LIST; do
    tar -C "$RC2_PKG" -cf - lib sbin tools 2>/dev/null | ssh -o StrictHostKeyChecking=no root@$ip \
      "mkdir -p /data/iotdb/$WORK; rm -rf /data/iotdb/$WORK/{lib,sbin,tools}; tar -C /data/iotdb/$WORK -xf -" 2>/dev/null
    tar -C /data2/iotdb/$RC2_BUILD/activation -cf - . 2>/dev/null | ssh -o StrictHostKeyChecking=no root@$ip \
      "mkdir -p /data/iotdb/$WORK/activation; tar -C /data/iotdb/$WORK/activation -xf -" 2>/dev/null
  done
  for ip in $DN_LIST; do
    tar -C "$RC2_PKG" -cf - lib sbin tools 2>/dev/null | ssh -o StrictHostKeyChecking=no root@$ip \
      "mkdir -p /data1/iotdb/$WORK; rm -rf /data1/iotdb/$WORK/{lib,sbin,tools}; tar -C /data1/iotdb/$WORK -xf -" 2>/dev/null
    tar -C /data2/iotdb/$RC2_BUILD/activation -cf - . 2>/dev/null | ssh -o StrictHostKeyChecking=no root@$ip \
      "mkdir -p /data1/iotdb/$WORK/activation; tar -C /data1/iotdb/$WORK/activation -xf -" 2>/dev/null
  done
  rm -rf /data2/iotdb/$WORK/{lib,sbin}
  cp -a "$RC2_PKG"/lib "$RC2_PKG"/sbin /data2/iotdb/$WORK/ 2>/dev/null
}

start_upgraded() {
  local ip
  for ip in $CN_LIST; do
    ssh -n -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd /data/iotdb/$WORK; nohup /data/iotdb/$WORK/sbin/start-confignode.sh -H /data/iotdb/$WORK/cn.hprof > /data/iotdb/$WORK/start_cn.log 2>&1 &" 2>/dev/null
    sleep 4
  done
  sleep 20
  for ip in $DN_LIST; do
    ssh -n -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd /data1/iotdb/$WORK; nohup /data1/iotdb/$WORK/sbin/start-datanode.sh -H /data1/iotdb/$WORK/dn.hprof > /data1/iotdb/$WORK/start_dn.log 2>&1 &" 2>/dev/null
    sleep 3
  done
  wait_running 8 600
}

restore_formal() {
  log "恢复正式集群 $DST_BUILD"
  local ip
  for ip in $CN_LIST $DN_LIST; do
    ssh -n -o StrictHostKeyChecking=no root@$ip "pkill -9 -f 'com.timecho.iotdb' 2>/dev/null; true" 2>/dev/null
  done
  sleep 8
  ( cd /data2/auto_test/treeview_suite && NEW=$DST_BUILD setsid bash hard_reset.sh > /tmp/upgrade_restore.log 2>&1 < /dev/null & )
  local n; n=$(wait_running 8 600)
  log "  正式集群 Running=$n"
}

# ---------------------------------------------------------------------------
log "=== 升级验证开始：RC12($RC12_PKG) → RC2($RC2_BUILD) ==="

if deploy_old; then step "部署 RC12 并启动" PASS; else step "部署 RC12 并启动" FAIL; fi

DB=up_t2t_$(date +%H%M%S)
create_old_data "$DB"
if Q "desc $DB.v1" | grep -q 's1'; then step "旧版本建视图成功" PASS; else step "旧版本建视图成功" FAIL; fi

stop_all
swap_in_rc2
N=$(start_upgraded)
if [ "${N:-0}" -ge 8 ]; then step "升级后集群 8/8" PASS; else step "升级后集群 8/8" "FAIL(Running=$N)"; fi

VER=$(T "show cluster;" 2>/dev/null | grep DataNode | head -1 | grep -o '83183d0')
if [ -n "$VER" ]; then step "版本已切换为 83183d0" PASS; else step "版本已切换为 83183d0" FAIL; fi

if Q "desc $DB.v1" | grep -q 's1'; then step "旧视图升级后仍存在" PASS; else step "旧视图升级后仍存在" FAIL; fi

if Q "select s1 from $DB.v1" | grep -q '1.5'; then step "旧数据可读" PASS; else step "旧数据可读" FAIL; fi

T "create timeseries root.$DB.dev01.old_extra double" >/dev/null 2>&1
sleep 5
if [ "$(Q "desc $DB.v1" | grep -c old_extra)" = "0" ]; then
  step "旧视图默认不自动补列" PASS
else
  step "旧视图默认不自动补列" "FAIL(竟然补列了)"
fi

Q "create or replace view $DB.v1(dev string tag) with(auto_sync_schema = true) as root.$DB.**" >/dev/null 2>&1
T "create timeseries root.$DB.dev01.new_extra double" >/dev/null 2>&1
sleep 6
if [ "$(Q "desc $DB.v1" | grep -c new_extra)" -ge 1 ]; then
  step "OR REPLACE 开启属性后可补列" PASS
else
  step "OR REPLACE 开启属性后可补列" FAIL
fi

FAILN=0
for k in "${!R[@]}"; do case "${R[$k]}" in FAIL*) FAILN=$((FAILN + 1));; esac; done

{
  echo "# 升级验证结果 $TS"
  echo
  echo "| 步骤 | 结果 |"
  echo "| --- | --- |"
  for k in "${!R[@]}"; do echo "| $k | ${R[$k]} |"; done
  echo
  echo "- RC12: \`$RC12_PKG\`"
  echo "- RC2: \`$RC2_BUILD\`"
  echo "- 升级目录: \`$WORK\`（保留，含数据）"
  echo "- 日志: \`$LOG\`"
} > "$RES"

log "=== 结果：$(( ${#R[@]} - FAILN ))/${#R[@]} 通过；报告 $RES ==="

if [ "$KEEP_CLUSTER" != "1" ]; then restore_formal; fi
[ "$FAILN" -eq 0 ]
