#!/bin/bash
# 阳性对照：SET CONFIGURATION 的键/值是否能在 CN 共识日志中 grep 到
set -u
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
TS=$(date '+%s')
KEY="password_stale_warning_days"
VAL="37"
LOG=/data/iotdb/autotest/rc2_regression_logs/positive_control.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
sql(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | timeout 40 "$CLI" -h "$H" -u root -pw "$P" 2>&1 | grep -aE 'Msg:|Error:' | tail -1; }

say "1) 写入一个可识别的配置值：$KEY=$VAL"
say "   $(sql "set configuration '$KEY'='$VAL';")"
sleep 3
say "2) 在 data 里搜 key / value"
for h in 77 78 79; do
  echo "### .$h" | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    echo -n '   key 命中: '; grep -a -l -F -- '$KEY' $D/data 2>/dev/null | head -4 | tr '\n' ' '; echo
    echo -n '   值命中(独立): '; grep -a -l -F -- '=$VAL' $D/data 2>/dev/null | head -4 | tr '\n' ' '; echo" 2>/dev/null | tee -a "$LOG"
done

say "3) 直接看 CN 共识日志开头 strings（看是否是 protobuf/加密）"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "strings -n 5 $D/data/confignode/consensus/*/current/log_0-* 2>/dev/null | head -25" 2>/dev/null | sed 's/^/   /' | tee -a "$LOG"

say "4) data/confignode 目录结构（找 author 元数据落点）"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "find $D/data/confignode -maxdepth 3 -type d 2>/dev/null | head -20" 2>/dev/null | sed 's/^/   /' | tee -a "$LOG"

say "5) 在 confignode/system 等目录里搜 用户名 与 明文"
U=$(ls -d /data/iotdb/autotest/sec_skill/results/artifact_plainpw2_* 2>/dev/null | tail -1)
UU=$(grep '^user=' "$U/credentials.txt" 2>/dev/null | cut -d= -f2)
PW=$(grep '^pw2=' "$U/credentials.txt" 2>/dev/null | cut -d= -f2)
say "   历史用户=$UU"
for h in 77 78 79; do
  echo "### .$h" | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    echo -n '   用户名: '; grep -a -l -F -- '$UU' $D/data 2>/dev/null | head -4 | tr '\n' ' '; echo
    echo -n '   明文  : '; grep -a -l -F -- '$PW' $D/data 2>/dev/null | head -4 | tr '\n' ' '; echo" 2>/dev/null | tee -a "$LOG"
done
say "done"
