#!/bin/bash
cur_dir="$(cd "$(dirname "$0")" && pwd)"
conf_file="${cur_dir}/../conf/benchmark_ip_list.txt"

jps|grep App|awk '{print "kill -9 "$1}'|sh

exec 3<${cur_dir}/../conf/benchmark_ip_list.txt
while read line<&3
do
# 强制 kill 两台机器的 App 进程
echo "正在 kill BM1: $bm1_ip 上的 App 进程..."
ssh root@${line} "pkill -9 -f App" 2>/dev/null
done
exec 3<${cur_dir}/../conf/benchmark_ip_list.txt
while read line<&3
do
	ssh root@${line} "jps"
done
