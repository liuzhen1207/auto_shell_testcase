#!/bin/bash
# 诊断：查当前集群状态 + .79 的 DataNode 进程/状态 + 最近的 compaction 相关 ERROR
set -uo pipefail
cd /data/iotdb/autotest/compaction_skill || exit 1
. lib/common.sh
. lib/cmp.sh
cmp_load_env >/dev/null 2>&1
echo "=== show cluster ==="
sq "show cluster;" 2>&1 | grep -E 'ConfigNode|DataNode'
echo "=== .79 DataNode 进程 ==="
ssh -n root@192.168.99.79 "pgrep -af 'com.timecho.iotdb.DataNode' | head -2; echo -n 'listening 10730: '; (ss -lntp 2>/dev/null | grep -c 10730)"
echo "=== .79 最近的 DN 启动/注册日志 ==="
ssh -n root@192.168.99.79 "grep -aE 'DataNode is started|Successfully registered|ReadOnly|Stopping DataNode|System.exit' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -8" | cut -c1-200
echo "=== .79 最近的 start_dn 日志 ==="
ssh -n root@192.168.99.79 "ls -t $DB_DIR/start_dn_*.log 2>/dev/null | head -1 | xargs tail -12" 2>/dev/null | cut -c1-200
