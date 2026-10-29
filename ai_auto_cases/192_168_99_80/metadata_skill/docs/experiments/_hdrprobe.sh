#!/bin/bash
# 确认：CLI 在结果超过一批时会不会重复打印表头
F=/tmp/show_ts.txt
echo "文件行数: $(wc -l < $F)"
echo "以 | 开头的行数: $(grep -cE '^\|' $F)"
echo "以 + 开头的分隔行数: $(grep -cE '^\+' $F)"
echo "第一列是 Timeseries 的行（表头）出现次数: $(grep -E '^\|' $F | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' | grep -cx 'Timeseries')"
echo "第 2 个表头出现在文件第几行: $(grep -nE '^\|[[:space:]]+Timeseries\|' $F | cut -d: -f1 | tr '\n' ' ')"
echo "分隔行出现在第几行: $(grep -nE '^\+' $F | cut -d: -f1 | tr '\n' ' ')"
