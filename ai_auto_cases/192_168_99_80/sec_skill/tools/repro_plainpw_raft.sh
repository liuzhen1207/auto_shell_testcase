#!/bin/bash
# ============================================================================
# 干净环境复现：明文密码落入 ConfigNode 共识（Raft）日志
#   1) 清 data/logs + 恢复默认配置（普通模式）→ 起集群
#   2) 用唯一随机口令 create user / alter user
#   3) 在 CN/DN 的 data、logs、conf 以及 consensus 快照中搜索明文口令
#   4) 抽取命中处上下文（hexdump + strings），打包证据
# ============================================================================
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
TS=$(date '+%Y%m%d_%H%M%S')
OUT=$A/sec_skill/results/artifact_plainpw_$TS
LOG=$A/rc2_regression_logs/repro_plainpw.log
mkdir -p "$OUT"; : >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
cnt(){ local h n=0; for h in 77 78 79; do c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1); n=$(( n + ${c:-0} )); done; echo $n; }
sql(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | timeout 40 "$CLI" -h "$H" -u root -pw "$P" 2>&1 | grep -aE 'Msg:|Error:' | tail -1; }

U="sec_pw_$TS"
PW1="Pl4inCreate#$TS"
PW2="Pl4inAlter@$TS"
printf '%s\n' "user=$U" "pw1=$PW1" "pw2=$PW2" > "$OUT/credentials.txt"

say "1) 停集群 + 清 data/logs + 默认配置"
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
say "  已清库并写默认配置"

say "2) 起集群"
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 45); do n=$(cnt); [ "${n:-0}" -ge 6 ] && { say "  就绪 n=$n"; break; }; sleep 10; done
sleep 30
say "  root 登录: $(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -ac root)"

say "3) 造数据：create user（PW1）→ alter user（PW2）"
say "  create: $(sql "create user $U '$PW1';")"
sleep 3
say "  alter : $(sql "alter user $U set password '$PW2';")"
sleep 5

say "4) 在三个节点的 data/logs/conf 中搜索两个明文口令"
for h in 77 78 79; do
  for pw in "$PW1" "$PW2"; do
    echo "### node=$h pw=$pw" | tee -a "$LOG"
    ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
      grep -a -l -F -- '$pw' $D/data $D/logs $D/conf 2>/dev/null | head -20" 2>/dev/null | sed 's/^/   /' | tee -a "$LOG"
  done
done

say "5) CN 共识日志专项（log_* / log_inprogress_* / snapshot*）"
for h in 77 78 79; do
  echo "### node=$h consensus 目录" | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    ls -l $D/data/confignode/consensus/*/current/ 2>/dev/null | head -12" 2>/dev/null | sed 's/^/   /' | tee -a "$LOG"
done

say "6) 抽取命中上下文（strings + 十六进制）"
for h in 77 78 79; do
  F=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "grep -a -l -F -- '$PW2' $D/data 2>/dev/null | head -1" 2>/dev/null)
  [ -z "$F" ] && continue
  say "  命中文件（.$h）: $F"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    O=\$(grep -a -b -o -F -- '$PW2' '$F' | head -1 | cut -d: -f1)
    echo \"  偏移=\$O\"
    S=\$((O>64 ? O-64 : 0))
    echo '  --- 前 64 字节 + 口令 + 后 64 字节（可打印化）---'
    dd if='$F' bs=1 skip=\$S count=200 2>/dev/null | strings -n 3 | head -20
    echo '  --- 十六进制 ---'
    dd if='$F' bs=1 skip=\$S count=160 2>/dev/null | od -A d -t x1z | head -12" 2>/dev/null | tee -a "$OUT/match_$h.txt" | sed 's/^/  /' | tee -a "$LOG"
done

say "7) 打包证据（命中的共识日志文件 + 匹配片段 + 凭据清单）"
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    cd $D && tar czf - \$(grep -a -l -F -- '$PW1' data 2>/dev/null) \$(grep -a -l -F -- '$PW2' data 2>/dev/null) 2>/dev/null" > "$OUT/consensus_hit_$h.tgz" 2>/dev/null || true
  say "  consensus_hit_$h.tgz: $(du -h "$OUT/consensus_hit_$h.tgz" 2>/dev/null | cut -f1)"
done
tar czf "$OUT/bundle_plainpw.tgz" -C "$OUT" . 2>/dev/null
say "  产物目录: $OUT"

say "8) 清理测试用户"
sql "drop user $U;" >/dev/null
say "done"
