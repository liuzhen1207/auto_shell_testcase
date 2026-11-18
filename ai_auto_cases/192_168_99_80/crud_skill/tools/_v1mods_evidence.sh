#!/bin/bash
set -u
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
OUT=/data/iotdb/autotest/rc2_regression_logs/v1mods_evidence.txt
{
echo "== 重启后行数 =="
printf 'set sql_dialect=tree;\nselect count(s1) from root.moddup.d1;\nselect count(s1) from root.moddup.d2;\n' | timeout 60 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'count|^\[|^\|' | head -12

echo
echo "== .mods2 文件（.77）=="
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "find $D/data -path '*moddup*' -name '*.mods2' -printf '%p %s\n' 2>/dev/null"

echo
echo "== B 的 .mods2 十六进制（前 70 字节）=="
B=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "find $D/data -path '*moddup*' -name '*1794984002392*.mods2' | head -1" 2>/dev/null)
echo "file=$B"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "od -An -tx1 '$B' | head -6" 2>/dev/null

echo
echo "== 升级相关日志（.77）=="
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "grep -aiE 'upgradeMod|mods2|modif' $D/logs/log_datanode_all.log 2>/dev/null | tail -12 | cut -c1-200" 2>/dev/null
} | tee "$OUT"
