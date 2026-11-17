#!/bin/bash
# 大写入 + 全目录检索（含 sm/ 快照），判断明文口令是否可能落盘
set -u
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
TS=$(date '+%s')
U="sec_big_$TS"
PW="BigDetect#Pw$TS"
LOG=/data/iotdb/autotest/rc2_regression_logs/big_plainpw.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
sql(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | timeout 60 "$CLI" -h "$H" -u root -pw "$P" 2>&1 | grep -aE 'Msg:|Error:' | tail -1; }

say "0) 凭据：$U / $PW"
say "1) CN 日志文件是否可读（strings 计数 + 头部魔数）"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "
  for f in $D/data/confignode/consensus/*/current/log_0-* $D/data/confignode/consensus/*/current/log_327-328; do
    [ -f \"\$f\" ] || continue
    echo \"  file=\$(basename \$f) size=\$(stat -c%s \$f) strings=$(strings -n 4 \"\$f\" 2>/dev/null | wc -l)\"
    od -A d -t x1z \"\$f\" 2>/dev/null | head -3 | sed 's/^/    /'
  done" 2>/dev/null | tee -a "$LOG"

say "2) 建 1 个目标用户 + 300 个批量用户（制造大日志）"
sql "drop user $U;" >/dev/null
say "   target create: $(sql "create user $U '$PW';")"
sql "alter user $U set password '${PW}Alt';" >/dev/null
for i in $(seq 1 300); do sql "create user sb_${i}_$TS 'Bulk#Pw${i}_$TS';" >/dev/null; done
say "   批量建完"
sleep 8

say "3) 全目录检索（data 全部，含 sm/current）"
for h in 77 78 79; do
  echo "### .$h" | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    echo -n '   target 明文: '; grep -a -l -F -- '$PW' $D/data 2>/dev/null | head -5 | tr '\n' ' '; echo
    echo -n '   target 用户名: '; grep -a -l -F -- '$U' $D/data 2>/dev/null | head -5 | tr '\n' ' '; echo
    echo -n '   批量用户名(样本): '; grep -a -l -F -- 'sb_1_'$TS $D/data 2>/dev/null | head -3 | tr '\n' ' '; echo" 2>/dev/null | tee -a "$LOG"
done

say "4) 日志文件现状（是否增长/是否新增 log 段）"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "ls -l $D/data/confignode/consensus/*/current/ 2>/dev/null | head -10; echo '--- sm ---'; ls -l $D/data/confignode/consensus/*/sm/ 2>/dev/null | head -6" 2>/dev/null | sed 's/^/  /' | tee -a "$LOG"

say "5) 若仍不命中：在 sm/ 快照里找用户名（确认状态机快照内容形态）"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "
  for f in $D/data/confignode/consensus/*/sm/*; do [ -f \"\$f\" ] || continue; echo -n \"  \$(basename \$f): \"; strings -n 4 \"\$f\" 2>/dev/null | grep -c . ; done" 2>/dev/null | tee -a "$LOG"

say "6) 清理（300 个用户）"
for i in $(seq 1 300); do sql "drop user sb_${i}_$TS;" >/dev/null; done
sql "drop user $U;" >/dev/null
say "done"
