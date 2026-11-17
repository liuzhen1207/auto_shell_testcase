#!/bin/bash
# 第二轮：制造足量写入 + 优雅停 ConfigNode 触发 Raft 日志落盘，再取证
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
TS=$(date '+%Y%m%d_%H%M%S')
OUT=$A/sec_skill/results/artifact_plainpw2_$TS
LOG=$A/rc2_regression_logs/repro_plainpw2.log
mkdir -p "$OUT"; : >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
cnt(){ local h n=0; for h in 77 78 79; do c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1); n=$(( n + ${c:-0} )); done; echo $n; }
sql(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | timeout 60 "$CLI" -h "$H" -u root -pw "$P" 2>&1 | grep -aE 'Msg:|Error:' | tail -1; }
grepall(){ local pw=$1; for h in 77 78 79; do
  echo "### node=$h pw=$pw" | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "grep -a -l -F -- '$pw' $D/data $D/logs $D/conf 2>/dev/null | head -10" 2>/dev/null | sed 's/^/   /' | tee -a "$LOG"
done; }

PW1="Pl4inBulk#$TS"
PW2="Pl4inBulkAlter@$TS"
U="sec_pwb_$TS"
printf '%s\n' "user=$U" "pw1=$PW1" "pw2=$PW2" > "$OUT/credentials.txt"

say "1) 前置：确认集群 Running"
say "   root 可登录: $(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -ac root)"

say "2) 造 20 个用户 + 1 个锁定/解锁（制造足量 Raft 写入）"
sql "drop user $U;" >/dev/null
say "   create(主): $(sql "create user $U '$PW1';")"
sql "alter user $U set password '$PW2';" >/dev/null
for i in $(seq 1 20); do
  sql "create user sec_b${i}_$TS 'BulkPw${i}@$TS';" >/dev/null
done
say "   已建 20 个批量用户"

say "3) 立即检索（可能仍在内存缓冲）"
grepall "$PW2"

say "4) 优雅停集群（TERM，让 Raft 刷盘）"
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -TERM -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 20
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 5
say "   已停（剩余进程=$(cnt)）"

say "5) 停机后检索共识日志（log_* / log_inprogress_* / snapshot*）"
grepall "$PW2"
grepall "$PW1"

say "6) 列出 CN 共识目录文件"
for h in 77 78 79; do
  echo "### node=$h" | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ls -l $D/data/confignode/consensus/*/current/ 2>/dev/null | head -15" 2>/dev/null | sed 's/^/   /' | tee -a "$LOG"
done

say "7) 抽取命中上下文"
for h in 77 78 79; do
  F=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "grep -a -l -F -- '$PW2' $D/data 2>/dev/null | head -1" 2>/dev/null)
  if [ -n "$F" ]; then
    say "  命中（.$h）: $F"
    ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
      O=\$(grep -a -b -o -F -- '$PW2' '$F' | head -1 | cut -d: -f1); echo \"  偏移=\$O\"
      S=\$((O>96 ? O-96 : 0))
      echo '  --- strings（前后各 96 字节内可打印内容）---'
      dd if='$F' bs=1 skip=\$S count=280 2>/dev/null | strings -n 4 | head -20
      echo '  --- hex ---'
      dd if='$F' bs=1 skip=\$S count=192 2>/dev/null | od -A d -t x1z | head -14" 2>/dev/null | tee "$OUT/match_$h.txt" | sed 's/^/  /' | tee -a "$LOG"
  else
    say "  未命中（.$h）"
  fi
done

say "8) 打包"
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    cd $D && tar czf - \$(grep -a -l -F -- '$PW1' data 2>/dev/null) \$(grep -a -l -F -- '$PW2' data 2>/dev/null) 2>/dev/null" > "$OUT/consensus_hit_$h.tgz" 2>/dev/null || true
  say "  consensus_hit_$h.tgz: $(du -h "$OUT/consensus_hit_$h.tgz" 2>/dev/null | cut -f1)"
done
tar czf "$OUT/bundle_plainpw2.tgz" -C "$OUT" . 2>/dev/null
say "  产物: $OUT"

say "9) 重启集群并清理测试用户"
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 45); do n=$(cnt); [ "${n:-0}" -ge 6 ] && { say "  就绪 n=$n"; break; }; sleep 10; done
sleep 25
for i in $(seq 1 20); do sql "drop user sec_b${i}_$TS;" >/dev/null; done
sql "drop user $U;" >/dev/null
say "done"
