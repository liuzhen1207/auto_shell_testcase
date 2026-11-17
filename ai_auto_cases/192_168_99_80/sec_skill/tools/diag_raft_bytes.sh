#!/bin/bash
set -u
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
echo "== A) 共识日志文件魔数/压缩迹象（.77）=="
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "
  for f in \$(ls $D/data/confignode/consensus/*/current/log_0-* 2>/dev/null); do
    echo \"  file=\$(basename \$f) size=\$(stat -c%s \$f)\"
    od -A d -t x1z \"\$f\" | head -6 | sed 's/^/    /'
    echo -n '  strings(>=4): '; strings -n 4 \"\$f\" | wc -l
  done" 2>/dev/null

echo
echo "== B) 共识/日志压缩相关配置 =="
printf 'set sql_dialect=table;\nshow configuration;\n' | timeout 30 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aiE 'compress|consensus|ratis' | cut -c1-150 | head -20

echo
echo "== C) 用户 profile 目录里是否有 sec_big / 批量用户 =="
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "ls $D/data/confignode/system/users/ 2>/dev/null | wc -l; ls -l $D/data/confignode/system/users/ 2>/dev/null | tail -5" 2>/dev/null

echo
echo "== D) 直接搜 data/confignode/system/users 里的 root 与 sec_big（阳性对照）=="
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "
  echo -n '  root 命中文件数: '; grep -a -l -F -- 'root' $D/data/confignode/system/users/ 2>/dev/null | wc -l
  echo -n '  sec_ 前缀命中: '; grep -a -l -F -- 'sec_' $D/data/confignode/system/users/ 2>/dev/null | wc -l
  F=\$(grep -a -l -F -- 'sec_' $D/data/confignode/system/users/ 2>/dev/null | head -1); echo \"  sample=\$F\"
  [ -n \"\$F\" ] && od -A d -t x1z \"\$F\" | head -8" 2>/dev/null
