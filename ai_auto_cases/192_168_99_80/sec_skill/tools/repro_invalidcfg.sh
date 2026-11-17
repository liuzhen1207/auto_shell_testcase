#!/bin/bash
# 非法/边界配置的日志留痕实测：failed_login_attempts=-5 / password_lock_time_minutes=0 / failed_login_attempts=abc
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
TS=$(date '+%Y%m%d_%H%M%S')
OUT=$A/sec_skill/results/artifact_invalidcfg_$TS
LOG=$A/rc2_regression_logs/repro_invalidcfg.log
mkdir -p "$OUT"; : >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
cnt(){ local h n=0; for h in 77 78 79; do c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1); n=$(( n + ${c:-0} )); done; echo $n; }
setconf(){ local k=$1 v=$2; for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "F=$D/conf/iotdb-system.properties; sed -i '/^$k=/d' \$F; echo '$k=$v' >> \$F" 2>/dev/null
done; }
restart(){
  for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
  sleep 10
  START=$(date '+%Y-%m-%d %H:%M:%S')
  ( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
  for i in $(seq 1 45); do n=$(cnt); [ "${n:-0}" -ge 6 ] && break; sleep 10; done
  sleep 25
  echo "$START"
}
probe(){ local tag=$1
  echo "### $tag" | tee -a "$LOG"
  printf 'set sql_dialect=table;\nshow configuration;\n' | timeout 30 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'failed_login|lock_time_minutes' | cut -c1-130 | sed 's/^/  show: /' | tee -a "$LOG"
  for h in 77 78 79; do
    echo "  --- .$h DN 锁定相关日志 ---" | tee -a "$LOG"
    ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
      grep -aE 'login attempts disabled|Login lock manager initialized|Invalid lock time|auto-enabled with default 1000' $D/logs/log_datanode_all.log 2>/dev/null | tail -6 | cut -c1-200" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG"
    echo "  --- .$h 启动窗口 ERROR/WARN（排除已知噪声）---" | tee -a "$LOG"
    ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
      grep -aE ' (ERROR|WARN) ' $D/logs/log_datanode_all.log 2>/dev/null | grep -avE 'MemoryManager:285|ConfigExecution:223|GrpcLogAppender|License will expire|Reporting ConfigNode shutdown' | tail -5 | cut -c1-200" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG"
  done
}

say "== 场景 A：failed_login_attempts=-5（需求称'不合理'，模板称'≤0=禁用'）=="
setconf failed_login_attempts -5
START=$(restart)
say "  A 重启窗口起点: $START"
probe "A: failed_login_attempts=-5"

say "== 场景 B：password_lock_time_minutes=0（<1，源码有 WARN 回退 10）=="
setconf password_lock_time_minutes 0
START=$(restart)
say "  B 重启窗口起点: $START"
probe "B: password_lock_time_minutes=0"

say "== 场景 C：failed_login_attempts=abc（真正的非法值/非数字）=="
setconf failed_login_attempts abc
START=$(restart)
say "  C 重启窗口起点: $START"
say "  进程数=$(cnt)"
printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'Error|root' | head -1 | cut -c1-140 | sed 's/^/  root 登录: /' | tee -a "$LOG"
for h in 77 78 79; do
  echo "  --- .$h 启动异常（NumberFormat/IllegalArgument/Exception）---" | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    grep -aE 'NumberFormat|IllegalArgument|Exception|Invalid' $D/logs/log_datanode_all.log 2>/dev/null | tail -5 | cut -c1-220" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG"
done

say "== 恢复默认值并重启 =="
setconf failed_login_attempts 5
setconf failed_login_attempts_per_user 1000
setconf password_lock_time_minutes 10
setconf password_stale_warning_days 30
START=$(restart)
say "  恢复后 进程数=$(cnt)"
probe "恢复默认"

tar czf "$OUT/bundle.tgz" -C "$OUT" . 2>/dev/null
say "  产物: $OUT"
say "done"
