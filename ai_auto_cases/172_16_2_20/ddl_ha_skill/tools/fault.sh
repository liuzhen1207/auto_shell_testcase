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
start_cn_all() {
  # 3 个 CN 同时拉起（已有 Raft 数据时必须并行，否则拿不到 quorum）
  local i ok t cnt
  for i in 16 17 18; do
    ssh $SSHO root@"$(ip_of "$i")" "setsid bash $NEW/sbin/start-confignode.sh -d >/tmp/ddlha_start_cn$i.log 2>&1 </dev/null &" 2>/dev/null
  done
  sleep 30
  for i in 16 17 18; do
    ok=$(ssh $SSHO root@"$(ip_of "$i")" "grep -cE 'has successfully (re)?started and joined the cluster' $NEW/logs/log_confignode_all.log 2>/dev/null" 2>/dev/null)
    if [ "${ok:-0}" -lt 1 ]; then
      ssh $SSHO root@"$(ip_of "$i")" "setsid bash $NEW/sbin/start-confignode.sh -d >/tmp/ddlha_start_cn$i.log 2>&1 </dev/null &" 2>/dev/null
    fi
  done
  t=0
  while [ $t -lt 300 ]; do
    cnt=$(bash "$CLI" -h "$(ip_of 19)" -p 6667 -u root -pw "$PW" -e "show cluster" 2>/dev/null | grep -c '|Running|')
    [ "${cnt:-0}" -ge 8 ] && return 0
    sleep 5; t=$((t+5))
  done
  return 1
}

kill_cn() {
  ssh $SSHO root@"$(ip_of "$1")" "pkill -9 -f 'com[.]timecho[.]iotdb'" 2>/dev/null
}

case "${1:-}" in
  apply)
    case "$2" in
      dn_kill)        kill_dn "$3" ;;
      dn_partition)   partition_dn "$3" ;;
      cn_leader_kill) kill_cn_leader ;;
      dr_both_down)   for d in $3; do kill_dn "$d"; done ;;
      sr_all_down)    for d in $3; do kill_dn "$d"; done ;;
      cn_quorum_down)   kill_cn 17; kill_cn 18 ;;
      cn_all_down)      kill_cn 16; kill_cn 17; kill_cn 18 ;;
      *) echo "unknown fault $2" >&2; exit 2 ;;
    esac ;;
  heal)
    case "$2" in
      dn_partition) heal_partition "$3" ;;
      dn_kill)      start_dn "$3" ;;
      dr_both_down) for d in $3; do start_dn "$d"; done ;;
      sr_all_down)  for d in $3; do start_dn "$d"; done ;;
      cn_quorum_down) start_cn 17; start_cn 18 ;;
      cn_all_down)    start_cn_all ;;
      cn_leader_kill) start_cn "$(cat /tmp/ddlha_cn_leader 2>/dev/null || echo 16)" ;;
      full_restart) : ;;
      *) : ;;
    esac ;;
  *) echo "usage: fault.sh apply|heal <type> <target>" >&2; exit 2 ;;
esac
