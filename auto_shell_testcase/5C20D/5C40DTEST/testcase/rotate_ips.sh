#!/bin/bash

# IP 文件路径
IP_FILE="../conf/datanode_20d.txt"

# 读取 IP 到数组
ips=($(cat $IP_FILE))
total=${#ips[@]}

# 生成 15 个轮换字符串
for ((i=0; i<15; i++)); do
    line=""
    # 从 i 开始，循环到末尾，再循环到 i-1
    for ((j=0; j<total; j++)); do
        idx=$(( (i + j) % total ))
        line+="${ips[$idx]},"
    done
    # 去掉最后一个逗号
    line=${line%,}
    echo "第 $((i+1)) 个字符串: $line"
done
