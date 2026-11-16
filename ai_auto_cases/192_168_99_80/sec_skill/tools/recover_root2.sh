#!/bin/bash
# 关闭失败登录锁定（IP 级 + 用户级）→ 重启 → 验证 root 可登录 → 恢复默认
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
L=$A/rc2_regression_logs
LOG=$L/sec_recover2.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
setkey(){ local k=$1 v=$2 h
  for h in 77 78 79; do
    ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
      F=$D/conf/iotdb-system.properties
      sed -i \"/^$k=/d\" \$F; echo '$k=$v' >> \$F
    " 2>/dev/null
  done
}
running(){ $CLI -h 192.168.99.77 -u root -pw 'TimechoDB@2021' -e "show cluster;" 2>&1 | grep -c Running; }
restart(){
  local h i n
  for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -TERM -f 'com\.timecho\.iotdb' || true" >/dev/null 2>&1; done
  sleep 10
  ( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 & )
  for i in $(seq 1 40); do
    n=$(running); [ "${n:-0}" -ge 6 ] && { say "  集群就绪 Running=$n"; return 0; }
    sleep 10
  done
  say "  !! 集群未就绪 Running=${n:-0}"; return 1
}

say "1) 关闭失败登录锁定 + 保持安全默认"
setkey failed_login_attempts 0
setkey failed_login_attempts_per_user 0
setkey enforce_strong_password true
setkey password_expiration_days 0
setkey password_reuse_interval_days 0
say "  已写入"

say "2) 重启"
restart || exit 1

say "3) 验证 root 登录"
out=$($CLI -h 192.168.99.77 -u root -pw 'TimechoDB@2021' -e "show cluster;" 2>&1)
echo "$out" | grep -qE 'Running' && say "  root 登录成功（Running=$(echo "$out" | grep -c Running)）" || say "  仍失败: $(echo "$out" | head -2)"

say "4) 恢复锁定默认值（5 / 1000 / 10 分钟）"
setkey failed_login_attempts 5
setkey failed_login_attempts_per_user 1000
say "  已写回（需重启生效；本套件跑批前会再确认一次）"
echo "recover2_done=$(date '+%F %T')" | tee -a "$LOG"
