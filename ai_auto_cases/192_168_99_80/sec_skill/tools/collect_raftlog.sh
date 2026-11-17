#!/bin/bash
# 造一个已知口令的用户，然后把 CN 共识日志 + 用户 profile 打包，供本地 Python 分析
set -u
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
TS=$(date '+%Y%m%d_%H%M%S')
U="sec_rl_$TS"
PW="RaftLog#Pw$TS"
OUT=/data/iotdb/autotest/sec_skill/artifacts
mkdir -p "$OUT"
LOG=/data/iotdb/autotest/rc2_regression_logs/repro_raftlocal.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
sql(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | timeout 40 "$CLI" -h "$H" -u root -pw "$P" 2>&1 | grep -aE 'Msg:|Error:' | tail -1; }

say "0) 工具检查：strings / grep 是否存在"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "command -v strings || echo 'no-strings'; command -v grep || echo 'no-grep'" 2>/dev/null | sed 's/^/  /' | tee -a "$LOG"

say "1) 建用户：$U / $PW"
sql "drop user $U;" >/dev/null
say "   create: $(sql "create user $U '$PW';")"
sql "alter user $U set password '${PW}Alt';" >/dev/null
sleep 5

say "2) 打包三节点 CN 共识目录 + system/users + 相关日志"
TAR=$OUT/raftlog_$TS.tgz
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "cd $D && tar czf - data/confignode/consensus data/confignode/system/users logs/log_confignode_all.log 2>/dev/null" > "$OUT/node_$h.tgz" 2>/dev/null
  say "  node_$h.tgz: $(du -h "$OUT/node_$h.tgz" 2>/dev/null | cut -f1)"
done
tar czf "$TAR" -C "$OUT" node_77.tgz node_78.tgz node_79.tgz 2>/dev/null
printf '%s\n' "user=$U" "pw1=$PW" "pw2=${PW}Alt" "sha256_pw1=$(printf '%s' "$PW" | sha256sum | cut -d' ' -f1)" "sha256_pw2=$(printf '%s' "${PW}Alt" | sha256sum | cut -d' ' -f1)" > "$OUT/cred_$TS.txt"
say "  打包完成: $TAR"
say "  凭据: $OUT/cred_$TS.txt"
cat "$OUT/cred_$TS.txt" | sed 's/^/  /' | tee -a "$LOG"

say "3) 远程快速自检（用 grep -c 而不是 strings）"
for h in 77 78 79; do
  echo -n "  .$h 明文命中文件数: " | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "grep -a -l -F -- '$PW' $D/data 2>/dev/null | wc -l" 2>/dev/null | tee -a "$LOG"
done

say "4) 保留用户（先不删），便于本地分析后复现"
say "user=$U pw=$PW (保留，分析完再删)"
say "done"
