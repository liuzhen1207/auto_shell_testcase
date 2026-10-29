#!/bin/bash
# ============================================================================
# 受控复现：`SET CONFIGURATION` 接受非法值 → 写进各节点 iotdb-system.properties
#           → DataNode 重启时 System.exit(-1) 起不来 → 手工改回合法值后恢复
#   证据链：① CLI 原始返回 ② 三节点 properties 行 ③ DN 启动异常原文 ④ 恢复过程
# 用法： bash repro_set_bad_value.sh > /tmp/repro_bad_value.out 2>&1
# ============================================================================
set -uo pipefail
V=v20121rc6_1010_7ae8713e
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
DBDIR=/data/iotdb/$V
H=192.168.99.77      # CLI 连接（CN+DN 同机）
DN=192.168.99.78     # 用来验证"重启失败"的 DataNode
run(){ $CLI -h $H -u root -pw 'TimechoDB@2021' -e "$1" 2>&1; }
prop(){ ssh -o BatchMode=yes root@$1 "grep -n '^compaction_priority=' $DBDIR/conf/iotdb-system.properties"; }

echo "########## 受控复现 $(date '+%F %T') ##########"
echo "### 0) 启动集群并确认 6/6"
cd /data/iotdb/autotest || exit 1
timeout 420 bash prepare_env/start_cluster_v20.sh >/tmp/repro_cluster.log 2>&1
echo "start_cluster rc=$?"
run 'show cluster;' | sed -n '2,12p'

echo
echo "### 1) 基线：三节点 compaction_priority 的当前值（合法）"
for h in 192.168.99.77 192.168.99.78 192.168.99.79; do printf '%s : ' "$h"; prop "$h"; done

echo
echo "### 2) SET CONFIGURATION 'compaction_priority'='BOGUS' —— 观察 CLI 返回"
run "SET CONFIGURATION 'compaction_priority'='BOGUS';"

echo
echo "### 3) 三个节点的 properties 是否被写坏"
for h in 192.168.99.77 192.168.99.78 192.168.99.79; do printf '%s : ' "$h"; prop "$h"; done

echo
echo "### 4) 停 $DN 后重新启动：DataNode 能起来吗？"
ssh -o BatchMode=yes root@$DN "$DBDIR/sbin/stop-datanode.sh -f >/dev/null 2>&1; pkill -f timecho.iotdb.DataNode >/dev/null 2>&1; sleep 5; echo '  已停 $DN'"
ssh -o BatchMode=yes root@$DN "nohup $DBDIR/sbin/start-datanode.sh -d >/tmp/repro_dn_start.log 2>&1 </dev/null &"
echo "  等待 80s ..."; sleep 80
echo "  --- show cluster（$DN 期望仍非 Running）---"
run 'show cluster;' | grep -E 'DataNode'
echo "  --- $DN 的日志：启动被拒的异常原文 ---"
ssh -o BatchMode=yes root@$DN "grep -nE 'No enum constant|Illegal Compaction Selector|NumberFormatException|Reject DataNode restart|MISC_LOG' $DBDIR/logs/log_datanode_all.log | tail -4 | cut -c1-300"
ssh -o BatchMode=yes root@$DN "grep -n 'No enum constant' $DBDIR/logs/log_datanode_all.log | tail -1 | cut -c1-300"

echo
echo "### 5) 修复：把该节点 properties 里的非法值改回合法值（节点离线时集群配置下发不到它）"
ssh -o BatchMode=yes root@$DN "sed -i 's/^compaction_priority=BOGUS/compaction_priority=INNER_CROSS/' $DBDIR/conf/iotdb-system.properties; printf '  修复后: '; grep -n '^compaction_priority=' $DBDIR/conf/iotdb-system.properties"
ssh -o BatchMode=yes root@$DN "nohup $DBDIR/sbin/start-datanode.sh -d >/tmp/repro_dn_start2.log 2>&1 </dev/null &"
echo "  等待 90s ..."; sleep 90
echo "  --- 修复后 show cluster ---"
run 'show cluster;' | grep -E 'DataNode'

echo
echo "### 6) 顺带确认：其余非法值（selector / 线程数）同样写进 properties"
run "SET CONFIGURATION 'inner_seq_selector'='bogus';"
run "SET CONFIGURATION 'compaction_thread_count'='abc';"
for h in 192.168.99.77 192.168.99.78 192.168.99.79; do
  printf '%s : ' "$h"
  ssh -o BatchMode=yes root@$h "grep -nE '^(inner_seq_selector|compaction_thread_count)=' $DBDIR/conf/iotdb-system.properties | tr '\n' ' '; echo"
done
echo "### 复现结束 $(date '+%F %T')"
