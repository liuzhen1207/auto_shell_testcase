#!/bin/bash
# 校时 + 重启 + 预检，之后可选继续跑收尾
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
LOG=$A/rc2_regression_logs/sec_clockfix2.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }

say "1) 停用例与集群"
pkill -f 'final_run.sh' 2>/dev/null || true
pkill -f 'run_all.sh --set' 2>/dev/null || true
pkill -f 'cases/.*/sec_' 2>/dev/null || true
sleep 2
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -TERM -f 'com.timecho.iotdb' || true; sleep 3; pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 8

say "2) 校时：三节点统一为 .80 当前时间"
NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo "  .80 基准: $NOW" | tee -a "$LOG"
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "date -s '$NOW' >/dev/null 2>&1; hwclock -w >/dev/null 2>&1 || true; date '+%F %T'" 2>/dev/null | sed "s/^/  .$h /" | tee -a "$LOG"
done

say "3) 起集群"
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 40); do
  n=$(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 20 "$CLI" -h 192.168.99.77 -u security_admin -pw 'TimechoDB@2021' 2>&1 | grep -ac 'security_admin')
  [ "${n:-0}" -ge 1 ] && { say "  登录可用（第 ${i} 轮）"; break; }
  sleep 10
done

say "4) 校时结果复核（三节点 + .80）"
date '+  .80 %F %T' | tee -a "$LOG"
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "date '+  .$h %F %T'" 2>/dev/null | tee -a "$LOG"; done

say "5) 继续收尾（SEC-09 sep → 切普通 → 普通全量）"
( cd "$A/sec_skill" && bash tools/final_run.sh ) >>"$LOG" 2>&1
say "  final2 完成"
grep -a 'RESULT ' "$LOG" | tail -12 | cut -c1-140 | tee -a "$LOG"
say "clockfix_final_done"
