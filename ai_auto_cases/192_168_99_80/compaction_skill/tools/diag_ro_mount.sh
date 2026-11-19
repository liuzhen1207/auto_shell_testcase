#!/bin/bash
# 诊断：/data 挂载拓扑 + 只读重挂载可行性（在指定节点上跑，只读操作）
set -uo pipefail
HOST=${1:-192.168.99.79}
echo "=== $HOST: /proc/self/mountinfo 里与 /data、sdb 相关的项 ==="
ssh -n "root@$HOST" "cat /proc/self/mountinfo | awk '{print \$5\" \"\$6\" \"\$9}' | grep -E '(/data|sdb)'"
echo "=== 子树挂载（findmnt -R /data）==="
ssh -n "root@$HOST" "findmnt -R /data -o TARGET,SOURCE,FSTYPE,OPTIONS"
echo "=== busy 原因探测 ==="
ssh -n "root@$HOST" "echo -n 'fuser -m /data (打开文件的进程数): '; fuser -m /data 2>/dev/null | wc -w"
ssh -n "root@$HOST" "echo '--- 直接 remount ro 重试 ---'; mount -o remount,ro /data 2>&1; findmnt -T /data -o TARGET,OPTIONS -n; mount -o remount,rw /data 2>&1; findmnt -T /data -o TARGET,OPTIONS -n"
echo "=== 自绑定挂载 + remount,ro,bind 可行性 ==="
ssh -n "root@$HOST" "D=/data/rotest_bind; mkdir -p \$D; mount --bind \$D \$D 2>&1; mount -o remount,ro,bind \$D 2>&1; echo -n 'bind 后 touch 探测: '; (touch \$D/probe 2>&1 || true) | head -1; echo -n 'bind 挂载项: '; findmnt -T \$D -o TARGET,OPTIONS -n; mount -o remount,rw,bind \$D 2>&1; umount -l \$D 2>&1; echo -n '恢复后 touch 探测: '; touch \$D/probe && echo OK && rm -f \$D/probe; rmdir \$D"
