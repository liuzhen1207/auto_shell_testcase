#!/bin/bash
set -u
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
PW1='RaftLog#Pw20261117_105111'
PW2='RaftLog#Pw20261117_105111Alt'
U='sec_rl_20261117_105111'

echo "== 1) 正确的远程检索：grep -ra（递归）=="
for h in 77 78 79; do
  echo "### .$h"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    echo -n '  pw1(CREATE) 命中: '; grep -ra -l -F -- '$PW1' $D/data 2>/dev/null | head -3 | tr '\n' ' '; echo
    echo -n '  pw2(ALTER)  命中: '; grep -ra -l -F -- '$PW2' $D/data 2>/dev/null | head -3 | tr '\n' ' '; echo" 2>/dev/null
done

echo
echo "== 2) 对比：错误的写法（grep -l 不带 -r）=="
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "grep -a -l -F -- '$PW1' $D/data 2>&1 | head -2" 2>/dev/null | sed 's/^/  /'

echo
echo "== 3) 命中文件的字节偏移（od 抽样）=="
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "
  F=\$(grep -ra -l -F -- '$PW1' $D/data 2>/dev/null | head -1); echo \"  file=\$F\"
  O=\$(grep -a -b -o -F -- '$PW1' \"\$F\" | head -1 | cut -d: -f1); echo \"  offset=\$O\"
  S=\$((O>48 ? O-48 : 0)); dd if=\"\$F\" bs=1 skip=\$S count=150 2>/dev/null | od -A d -t x1z | head -10" 2>/dev/null

echo
echo "== 4) 清理测试用户 =="
printf 'set sql_dialect=tree;\ndrop user %s;\n' "$U" | timeout 40 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'Msg|Error' | tail -1
echo "done"
