#!/bin/bash
# 判定实验：create user 后立刻在全部 CN 共识 group 里搜 用户名 / 明文口令 / SHA256(口令)
set -u
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
TS=$(date '+%s')
U="sec_det_$TS"
PW="Detect#Pw$TS"
SHA=$(printf '%s' "$PW" | sha256sum | cut -d' ' -f1)
LOG=/data/iotdb/autotest/rc2_regression_logs/detect_plainpw.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
sql(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | timeout 40 "$CLI" -h "$H" -u root -pw "$P" 2>&1 | grep -aE 'Msg:|Error:' | tail -1; }

say "0) 凭据：user=$U pw=$PW sha256=$SHA"
say "1) 全部 CN 共识 group 目录"
for h in 77 78 79; do
  echo "### .$h" | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ls -d $D/data/confignode/consensus/*/ 2>/dev/null; for g in $D/data/confignode/consensus/*/; do echo -n \"   \$g : \"; ls -l \$g/current/ 2>/dev/null | grep -E 'log_|log_inprogress' | awk '{print \$5, \$9}' | tr '\n' ' '; echo; done" 2>/dev/null | sed 's/^/  /' | tee -a "$LOG"
done

say "2) create user"
say "   $(sql "create user $U '$PW';")"
sleep 3

say "3) 立刻搜索：用户名 / 明文 / SHA256（全部 group，data 全目录）"
for h in 77 78 79; do
  echo "### .$h" | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    echo -n '   用户名: '; grep -a -l -F -- '$U' $D/data 2>/dev/null | head -3 | tr '\n' ' '; echo
    echo -n '   明文  : '; grep -a -l -F -- '$PW' $D/data 2>/dev/null | head -3 | tr '\n' ' '; echo
    echo -n '   SHA256: '; grep -a -l -F -- '$SHA' $D/data 2>/dev/null | head -3 | tr '\n' ' '; echo" 2>/dev/null | tee -a "$LOG"
done

say "4) 若仅命中用户名，dump 其附近 strings（看计划是否含哈希/密文）"
for h in 77 78 79; do
  F=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "grep -a -l -F -- '$U' $D/data 2>/dev/null | head -1" 2>/dev/null)
  [ -z "$F" ] && continue
  say "  命中文件（.$h）: $F"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    O=\$(grep -a -b -o -F -- '$U' '$F' | head -1 | cut -d: -f1); echo \"  偏移=\$O\"
    S=\$((O>128 ? O-128 : 0))
    echo '  --- strings ---'
    dd if='$F' bs=1 skip=\$S count=512 2>/dev/null | strings -n 4 | head -25
    echo '  --- hex ---'
    dd if='$F' bs=1 skip=\$S count=256 2>/dev/null | od -A d -t x1z | head -18" 2>/dev/null | tee "/data/iotdb/autotest/sec_skill/results/detect_$h.txt" | sed 's/^/  /' | tee -a "$LOG"
done

say "5) 追加：再建 100 个用户制造 flush，重复搜索"
for i in $(seq 1 100); do sql "create user sec_fl_${i}_$TS 'FlushPw${i}#$TS';" >/dev/null; done
sleep 5
for h in 77 78 79; do
  echo -n "  .$h 明文(Detect) 命中: " | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "grep -a -l -F -- '$PW' $D/data 2>/dev/null | head -3 | tr '\n' ' '; echo" 2>/dev/null | tee -a "$LOG"
done

say "6) 清理"
for i in $(seq 1 100); do sql "drop user sec_fl_${i}_$TS;" >/dev/null; done
sql "drop user $U;" >/dev/null
say "done"
