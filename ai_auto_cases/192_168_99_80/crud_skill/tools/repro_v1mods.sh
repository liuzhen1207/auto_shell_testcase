#!/bin/bash
# 最小复现（对齐 CR-09 注入方式）：
#   TsFile A: 有 .resource、无 .mods2 → 注入 V1 文本 .mods（删 d2）
#   TsFile B: 已有 .mods2（SQL 删 d1 产生）
# 重启后检查：A 是否升级出 .mods2；B 的 .mods2 是否被改动；d2 是否真的被删
set -u
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
A=/data/iotdb/autotest
LOG=$A/rc2_regression_logs/v1mods_repro.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
sql(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | timeout 60 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'Msg:|Error:|count' | tail -2 | tr '\n' ' ' | cut -c1-160; }
cnt(){ local h n=0; for h in 77 78 79; do c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1); n=$(( n + ${c:-0} )); done; echo $n; }
files(){ ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "find $D/data/datanode/data -path '*moddup*' -name '*.tsfile' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -3 | awk '{print \$2}'" 2>/dev/null; }
size(){ ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "for f in $1 $1.mods $1.mods2; do [ -e \"\$f\" ] && printf '%s %s %s\n' \"\$(basename \$f)\" \"\$(stat -c %s \$f)\" \"\$(md5sum \$f|cut -c1-32)\"; done" 2>/dev/null; }

say "1) 重建库"
sql "drop database root.moddup" >/dev/null 2>&1
sql "create database root.moddup" | sed 's/^/   /' | tee -a "$LOG"
say "2) 写 d2 → flush（得到 TsFile A）"
for i in 1 2 3 4 5; do printf 'set sql_dialect=tree;\ninsert into root.moddup.d2(time,s1) values(%d,%d);\n' $((1700000000000+i*1000)) $((200+i)) | timeout 60 "$CLI" -h $H -u root -pw "$P" >/dev/null 2>&1; done
sql "flush" >/dev/null
sleep 5
say "3) 写 d1 → flush（得到 TsFile B）"
for i in 1 2 3 4 5; do printf 'set sql_dialect=tree;\ninsert into root.moddup.d1(time,s1) values(%d,%d);\n' $((1700000000000+i*1000)) $i | timeout 60 "$CLI" -h $H -u root -pw "$P" >/dev/null 2>&1; done
sql "flush" >/dev/null
sleep 5
say "   d2 行数=$(sql 'select count(s1) from root.moddup.d2')"
say "   d1 行数=$(sql 'select count(s1) from root.moddup.d1')"

FILES=$(files)
TA=$(echo "$FILES" | head -1)
TB=$(echo "$FILES" | tail -1)
say "   TsFile A=$TA"
say "   TsFile B=$TB"

say "4) SQL 删除 d1（在 B 上生成 .mods2）"
sql "delete from root.moddup.d1.** where time <= 1800000000000" | sed 's/^/   /' | tee -a "$LOG"
sql "flush" >/dev/null
sleep 6

say "5) 注入 V1 .mods 到 A（删 d2 全区间）"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "printf 'DELETION,root.moddup.d2.s1,0,1600000000000,1900000000000\n' > '$TA.mods'" 2>/dev/null
say "   注入完成: $(size "$TA" | tr '\n' ';')"

say "6) 重启前"
say "   A: $(size "$TA" | tr '\n' ';')"
say "   B: $(size "$TB" | tr '\n' ';')"
say "   d2 行数=$(sql 'select count(s1) from root.moddup.d2')"

say "7) 重启（不清数据）"
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 12
( cd $A && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 40); do n=$(cnt); [ "${n:-0}" -ge 6 ] && { say "   就绪 n=$n"; break; }; sleep 10; done
sleep 30

say "8) 重启后"
say "   A: $(size "$TA" | tr '\n' ';')"
say "   B: $(size "$TB" | tr '\n' ';')"
say "   d2 行数=$(sql 'select count(s1) from root.moddup.d2')（期望 0：V1 删除应生效）"
say "   全库 .mods2: $(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "find $D/data -path '*moddup*' -name '*.mods2' | wc -l" 2>/dev/null)"
say "done"
