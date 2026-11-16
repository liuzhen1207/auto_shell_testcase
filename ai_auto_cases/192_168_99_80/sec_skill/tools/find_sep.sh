#!/bin/bash
set -u
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
echo "== 安装目录里所有含该键的文件 =="
grep -rln 'enable_separation_of_powers' "$D" 2>/dev/null | head -10
echo
echo "== conf 目录内容 =="
ls -l "$D/conf" 2>/dev/null | head -10
echo
echo "== 各文件中的值 =="
grep -rn 'enable_separation_of_powers' "$D"/conf/*.properties "$D"/conf/*.template 2>/dev/null | head -10
echo
echo "== ConfigNode 数据里的可疑位置 =="
ls -d "$D"/data/confignode/* 2>/dev/null | head -8
find "$D/data/confignode" -maxdepth 3 -name "*.properties" -o -maxdepth 3 -name "*.conf" 2>/dev/null | head -6
