#!/bin/bash
# ============================================================================
# 干净环境复现：非授权 UNLOCK 返回 305 INTERNAL_SERVER_ERROR（含完整堆栈取证）
#   1) 清 data/logs，conf 置默认（普通模式）
#   2) 起集群
#   3) 建普通用户，用该用户执行 ALTER USER ... ACCOUNT UNLOCK（两种写法）
#   4) 抓 CN/DN 堆栈、打包日志
# ============================================================================
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
TS=$(date '+%Y%m%d_%H%M%S')
OUT=$A/sec_skill/results/artifact_305_$TS
LOG=$A/rc2_regression_logs/repro_305.log
mkdir -p "$OUT"; : >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
cnt(){ local h n=0; for h in 77 78 79; do c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1); n=$(( n + ${c:-0} )); done; echo $n; }
sql(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | timeout 40 "$CLI" -h "$H" -u root -pw "$P" 2>&1; }
sqlas(){ printf 'set sql_dialect=tree;\n%s\n' "$3" | timeout 40 "$CLI" -h "$H" -u "$1" -pw "$2" 2>&1; }

say "1) 停集群并清 data/logs（干净环境）"
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 10
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    rm -rf $D/data $D/logs; mkdir -p $D/logs
    F=$D/conf/iotdb-system.properties
    for kv in 'enable_separation_of_powers=false' 'failed_login_attempts=5' 'failed_login_attempts_per_user=1000' 'password_lock_time_minutes=10' 'password_stale_warning_days=30' 'enforce_strong_password=true' 'password_expiration_days=0' 'password_reuse_interval_days=-1'; do
      k=\${kv%%=*}; sed -i \"/^\$k=/d\" \$F; echo \"\$kv\" >> \$F
    done" 2>/dev/null
done
say "  已清 data 并写默认配置"

say "2) 起集群"
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 45); do n=$(cnt); [ "${n:-0}" -ge 6 ] && { say "  就绪 n=$n"; break; }; sleep 10; done
sleep 30
say "  root 登录: $(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -acE 'root')"

say "3) 建普通用户 sec_uo 并复现"
sql "drop user sec_uo;" >/dev/null
say "  create: $(sql "create user sec_uo 'Abcdefgh123!';" | grep -aE 'Msg|Error' | tail -1 | cut -c1-90)"

say "  --- 3a) 普通用户对自己执行 UNLOCK（裸用户名）---"
r1=$(sqlas sec_uo 'Abcdefgh123!' "alter user sec_uo account unlock;")
printf '%s\n' "$r1" > "$OUT/cli_3a_self_unlock.txt"
printf '%s\n' "$r1" | grep -aE 'Msg:|Error:' | tail -2 | cut -c1-400 | tee -a "$LOG"

say "  --- 3b) 普通用户对 root 执行 UNLOCK ---"
r2=$(sqlas sec_uo 'Abcdefgh123!' "alter user root account unlock;")
printf '%s\n' "$r2" > "$OUT/cli_3b_unlock_root.txt"
printf '%s\n' "$r2" | grep -aE 'Msg:|Error:' | tail -2 | cut -c1-400 | tee -a "$LOG"

say "  --- 3c) 普通用户带 IP 形式 ---"
r3=$(sqlas sec_uo 'Abcdefgh123!' "alter user sec_uo @ '192.168.99.80' account unlock;")
printf '%s\n' "$r3" > "$OUT/cli_3c_unlock_ip.txt"
printf '%s\n' "$r3" | grep -aE 'Msg:|Error:' | tail -2 | cut -c1-400 | tee -a "$LOG"

say "4) 抓 CN/DN 堆栈（关键字：Cannot read the array length / INTERNAL_SERVER_ERROR / ACCOUNT_UNLOCK）"
for h in 77 78 79; do
  for f in log_datanode_all.log log_confignode_all.log; do
    ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
      { echo '### node=$h file=$f'; grep -nE 'Cannot read the array length|INTERNAL_SERVER_ERROR|ACCOUNT_UNLOCK|unlockAccountAndInvalidateCache' $D/logs/$f 2>/dev/null | tail -30; }" 2>/dev/null | tee -a "$LOG" | sed 's/^/  /'
  done
done

say "5) 抽取完整堆栈（前后各 60 行）"
for h in 77 78 79; do
  for f in log_datanode_all.log log_confignode_all.log; do
    ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
      L=\$(grep -anE 'Cannot read the array length' $D/logs/$f 2>/dev/null | tail -1 | cut -d: -f1)
      if [ -n \"\$L\" ]; then
        S=\$((L>80 ? L-80 : 1)); E=\$((L+80))
        echo \"### node=$h file=$f line=\$L\"
        sed -n \"\${S},\${E}p\" $D/logs/$f
      fi" 2>/dev/null > "$OUT/stack_${h}_${f}.txt"
    [ -s "$OUT/stack_${h}_${f}.txt" ] && say "  已抽取 $OUT/stack_${h}_${f}.txt（$(wc -l < "$OUT/stack_${h}_${f}.txt") 行）"
  done
done

say "6) 打包三节点日志"
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "cd $D/logs 2>/dev/null && tar czf - log_confignode_all.log log_datanode_all.log 2>/dev/null" > "$OUT/logs_$h.tgz" 2>/dev/null || true
  say "  logs_$h.tgz: $(du -h "$OUT/logs_$h.tgz" 2>/dev/null | cut -f1)"
done
tar czf "$OUT/bundle_305.tgz" -C "$OUT" . 2>/dev/null
say "  产物目录: $OUT（打包 $OUT/bundle_305.tgz）"
say "done"
