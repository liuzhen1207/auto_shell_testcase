#!/bin/bash
# fault.sh — 故障注入与恢复
# 用法：fault.sh apply <type> <target_dn>   |   fault.sh heal <type> <target_dn>
set -u
. "$(dirname "$0")/lib.sh"

SSHO="-n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8"

kill_dn() {
  ssh $SSHO root@"$(ip_of "$1")" "pkill -9 -f 'com[.]timecho[.]iotdb[.]DataNode'" 2>/dev/null
}

partition_dn() { # 阻断与 3 台 CN 的 10710 端口（保留 SSH）
  local n=$1 cn
  for cn in $CNS; do
    ssh $SSHO root@"$(ip_of "$n")" "
      iptables -C OUTPUT -d $(ip_of "$cn") -p tcp --dport 10710 -j DROP 2>/dev/null || \
        iptables -I OUTPUT -d $(ip_of "$cn") -p tcp --dport 10710 -j DROP
      iptables -C INPUT -s $(ip_of "$cn") -p tcp --sport 10710 -j DROP 2>/dev/null || \
        iptables -I INPUT -s $(ip_of "$cn") -p tcp --sport 10710 -j DROP
    " 2>/dev/null
  done
}

heal_partition() {
  local n=$1 cn
  for cn in $CNS; do
    ssh $SSHO root@"$(ip_of "$n")" "
      while iptables -C OUTPUT -d $(ip_of "$cn") -p tcp --dport 10710 -j DROP 2>/dev/null; do
        iptables -D OUTPUT -d $(ip_of "$cn") -p tcp --dport 10710 -j DROP; done
      while iptables -C INPUT -s $(ip_of "$cn") -p tcp --sport 10710 -j DROP 2>/dev/null; do
        iptables -D INPUT -s $(ip_of "$cn") -p tcp --sport 10710 -j DROP; done
    " 2>/dev/null
  done
}

kill_cn_leader() { # 杀掉当前 CN leader（show cluster 中 Role=Leader 的 ConfigNode）
  local leader
  leader=$(bash "$CLI" -h "$(ip_of 19)" -p 6667 -u root -pw "$PW" -e "show confignodes" 2>/dev/null \
    | awk -F'|' '$6 ~ /Leader/ {gsub(/ /,"",$3); print $3}' | head -n1)
  [ -z "$leader" ] && leader="16"
  kill_cn "$leader"
  echo "$leader" > /tmp/ddlha_cn_leader
}


start_dn() {
  ssh $SSHO root@"$(ip_of "$1")" "setsid bash $NEW/sbin/start-datanode.sh -d >/tmp/ddlha_start_dn$1.log 2>&1 </dev/null &" 2>/dev/null
}

start_cn() {
  ssh $SSHO root@"$(ip_of "$1")" "setsid bash $NEW/sbin/start-confignode.sh -d >/tmp/ddlha_start_cn$1.log 2>&1 </dev/null &" 2>/dev/null
}
kill_cn() {
  ssh $SSHO root@"$(ip_of "$1")" "pkill -9 -f 'com[.]timecho[.]iotdb'" 2>/dev/null
}

# ---- hardened restart helpers (override earlier definitions) ----
wait_dn_gone() { # 等到 DataNode 进程完全退出，释放 data 目录锁
  local n=$1 t
  for t in $(seq 1 30); do
    ssh $SSHO root@"$(ip_of "$n")" "pgrep -f 'com[.]timecho[.]iotdb[.]DataNode' >/dev/null" 2>/dev/null || return 0
    sleep 2
  done
  return 0
}

start_dn() {
  local n=$1 i ok
  for i in 1 2 3; do
    wait_dn_gone "$n"
    ssh $SSHO root@"$(ip_of "$n")" "rm -f $NEW/logs/log_datanode_all.log; setsid bash $NEW/sbin/start-datanode.sh -d >/tmp/ddlha_start_dn$n.log 2>&1 </dev/null &" 2>/dev/null
    sleep 25
    ok=$(ssh $SSHO root@"$(ip_of "$n")" "grep -c 'DataNode is set up successfully' $NEW/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null)
    [ "${ok:-0}" -ge 1 ] && return 0
    if ssh $SSHO root@"$(ip_of "$n")" "grep -qE 'Conflict is detected|Fail to start server' $NEW/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null; then
      ssh $SSHO root@"$(ip_of "$n")" "pkill -9 -f 'com[.]timecho[.]iotdb[.]DataNode'" 2>/dev/null
      sleep 25
    fi
  done
  return 1
}

wait_cn_gone() {
  local n=$1 t
  for t in $(seq 1 30); do
    ssh $SSHO root@"$(ip_of "$n")" "pgrep -f 'com[.]timecho[.]iotdb[.]ConfigNode' >/dev/null" 2>/dev/null || return 0
    sleep 2
  done
  return 0
}

start_cn() {
  local n=$1 i ok
  for i in 1 2 3; do
    wait_cn_gone "$n"
    ssh $SSHO root@"$(ip_of "$n")" "rm -f $NEW/logs/log_confignode_all.log; setsid bash $NEW/sbin/start-confignode.sh -d >/tmp/ddlha_start_cn$n.log 2>&1 </dev/null &" 2>/dev/null
    sleep 25
    ok=$(ssh $SSHO root@"$(ip_of "$n")" "grep -cE 'has successfully (re)?started and joined the cluster' $NEW/logs/log_confignode_all.log 2>/dev/null" 2>/dev/null)
    [ "${ok:-0}" -ge 1 ] && return 0
    if ssh $SSHO root@"$(ip_of "$n")" "grep -qE 'Conflict is detected|Fail to start server' $NEW/logs/log_confignode_all.log 2>/dev/null" 2>/dev/null; then
      ssh $SSHO root@"$(ip_of "$n")" "pkill -9 -f 'com[.]timecho[.]iotdb[.]ConfigNode'" 2>/dev/null
      sleep 25
    fi
  done
  return 1
}

case "${1:-}" in
  apply)
    case "$2" in
      dn_kill)        kill_dn "$3" ;;
      dn_partition)   partition_dn "$3" ;;
      cn_leader_kill) kill_cn_leader ;;
      dr_both_down)   for d in $3; do kill_dn "$d"; done ;;
      *) echo "unknown fault $2" >&2; exit 2 ;;
    esac ;;
  heal)
    case "$2" in
      dn_partition) heal_partition "$3" ;;
      dn_kill)      start_dn "$3" ;;
      dr_both_down) for d in $3; do start_dn "$d"; done ;;
      cn_leader_kill) start_cn "$(cat /tmp/ddlha_cn_leader 2>/dev/null || echo 16)" ;;
      full_restart) : ;;
      *) : ;;
    esac ;;
  *) echo "usage: fault.sh apply|heal <type> <target>" >&2; exit 2 ;;
esac
