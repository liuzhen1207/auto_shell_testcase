#!/bin/bash
# 三权分立下"重启后"复核：确保 startup 路径（DataNode.java:147-157）也是严格 visitor
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
LOG=$A/rc2_regression_logs/sep_305_after_restart.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
cnt(){ local h n=0; for h in 77 78 79; do c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1); n=$(( n + ${c:-0} )); done; echo $n; }
q(){ printf 'set sql_dialect=tree;\n%s\n' "$2" | timeout 40 "$CLI" -h "$H" -u "$1" -pw "$3" 2>&1 | grep -aE 'Msg:|Error:' | tail -1 | cut -c1-190; }
cntnpe(){ ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "grep -ac 'Cannot read the array length' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }

say "1) 确认当前 sep，然后重启集群（保留配置）"
say "   root 803: $(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aoE '803' | head -1)"
b_npe=$(cntnpe); say "   重启前 NPE 计数=$b_npe"
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 10
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 45); do n=$(cnt); [ "${n:-0}" -ge 6 ] && { say "   进程就绪 n=$n"; break; }; sleep 10; done
sleep 25

say "2) 重启后仍是 sep？root: $(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aoE '803' | head -1)"
say "3) 重启后矩阵"
q security_admin "drop user s305b;" "$P" >/dev/null
say "   建用户: $(q security_admin "create user s305b 'Abcdefgh123!';" "$P")"
say "   3.1 security_admin 全局解锁: $(q security_admin "alter user s305b account unlock;" "$P")"
say "   3.2 普通用户 全局解锁      : $(q s305b "alter user s305b account unlock;" 'Abcdefgh123!')"
say "   3.3 普通用户 IP 级解锁     : $(q s305b "alter user s305b @ '192.168.99.80' account unlock;" 'Abcdefgh123!')"
say "   3.4 sys_admin 全局解锁     : $(q sys_admin "alter user s305b account unlock;" "$P")"

a_npe=$(cntnpe)
say "4) NPE 增量：$b_npe → $a_npe （+$((a_npe-b_npe))）"
[ "$a_npe" -eq "$b_npe" ] && say "   ✅ 重启（startup 路径）后也不产生 NPE/305" || say "   ❌ 出现新增 NPE"
say "5) 清理"
q security_admin "drop user s305b;" "$P" >/dev/null
say "done"
