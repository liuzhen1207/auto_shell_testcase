#!/bin/bash
# 对比三种故障注入方式下「树转表自动扩列」是否丢列：
#   1) kill -STOP（挂起，连接不断）        —— 已复现丢列
#   2) kill -9  后立刻建序列              —— 本次新增
#   3) kill -9  后等 20s（集群标记 Unknown）再建序列 —— 本次新增
#
# 用法： bash fault_compare.sh <build> <mode> <rounds>
#   mode: stop | kill9 | kill9wait
NEW=${1:-v20131rc2_1110_83183d0}
MODE=${2:-kill9}
ROUNDS=${3:-3}
TARGET=172.16.2.6           # 被注入的 DN
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
Q() { timeout 30 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "$1" 2>&1; }
T() { timeout 30 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree  -e "$1" 2>&1; }
CN26_LOGS=/data/iotdb/$NEW/logs
LOG=/tmp/fault_compare_${MODE}_$(date +%H%M%S).log

DN_PID() { ssh -n -o StrictHostKeyChecking=no root@$TARGET "pgrep -f 'com.timecho.iotdb.DataNode' | head -1" 2>/dev/null; }
DN_START() { ssh -n -o StrictHostKeyChecking=no root@$TARGET "source /etc/profile; cd /data1/iotdb/$NEW; nohup /data1/iotdb/$NEW/sbin/start-datanode.sh -H /data1/iotdb/$NEW/dn.hprof > /data1/iotdb/$NEW/start_dn.log 2>&1 &" 2>/dev/null; }
WAIT_RUN() { local i n; for i in $(seq 1 60); do n=$(T "show cluster;" 2>/dev/null | grep -c Running); [ "$n" -ge 8 ] && { echo "$n"; return 0; }; sleep 6; done; echo "$n"; return 1; }

echo "=== 模式=$MODE 轮次=$ROUNDS 目标DN=$TARGET 构建=$NEW ===" | tee -a "$LOG"
SUC=0; LOST=0
for r in $(seq 1 $ROUNDS); do
  D=fault_${MODE}_${r}_$(date +%H%M%S)
  Q "CREATE DATABASE $D" >/dev/null 2>&1
  T "create timeseries root.$D.dev01.s1 double" >/dev/null 2>&1
  Q "create view $D.v1(dev string tag) with(auto_sync_schema = true) as root.$D.**" >/dev/null 2>&1

  BEFORE=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.26 "wc -l < $CN26_LOGS/log_confignode_all.log" 2>/dev/null)

  PID=$(DN_PID)
  echo "[$(date +%T)] r$r: 注入 $MODE 到 DN6 pid=$PID" | tee -a "$LOG"
  case "$MODE" in
    stop)     ssh -n -o StrictHostKeyChecking=no root@$TARGET "kill -STOP $PID" 2>/dev/null; sleep 12 ;;
    kill9)    ssh -n -o StrictHostKeyChecking=no root@$TARGET "kill -9 $PID" 2>/dev/null; sleep 3 ;;
    kill9wait) ssh -n -o StrictHostKeyChecking=no root@$TARGET "kill -9 $PID" 2>/dev/null; sleep 20 ;;
    stopwait)  ssh -n -o StrictHostKeyChecking=no root@$TARGET "kill -STOP $PID" 2>/dev/null
               w=0
               ST=Running
               for k in $(seq 1 24); do
                 # 表格列: |NodeID|NodeType|Status|... -> $3=NodeType, $4=Status
                 ST=$(T "show cluster;" 2>/dev/null | grep "172.16.2.6" | awk -F"|" '{gsub(/ /,"",$4); print $4}')
                 w=$((w + 5))
                 if [ -n "$ST" ] && [ "$ST" != "Running" ]; then break; fi
                 sleep 5
               done
               echo "  等待 ${w}s 后 DN6 状态=$ST" | tee -a "$LOG" ;;
  esac

  # 故障期间建序列（失败则重试，最多 6 次）
  W=""
  for i in $(seq 1 6); do
    W=$(T "create timeseries root.$D.dev01.faulty double" | head -1)
    echo "$W" | grep -qi successfully && break
    sleep 8
  done
  echo "  写入返回：$(echo "$W" | cut -c1-90)" | tee -a "$LOG"

  # 恢复
  if [ "$MODE" = "stop" ] || [ "$MODE" = "stopwait" ]; then
    ssh -n -o StrictHostKeyChecking=no root@$TARGET "kill -CONT $PID" 2>/dev/null
  else
    DN_START
  fi
  N=$(WAIT_RUN)
  echo "  恢复后 Running=$N" | tee -a "$LOG"
  sleep 20

  CNT=$(Q "desc $D.v1" | grep -c 'faulty')
  [ "$CNT" -ge 1 ] && SUC=$((SUC+1)) || LOST=$((LOST+1))
  echo "  r$r 结果：列数=$CNT $([ "$CNT" -ge 1 ] && echo 成功 || echo '丢列')" | tee -a "$LOG"

  # CN 日志中窗口内 fence/RPC 超时统计
  FEN=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.26 "tail -n +$((BEFORE+1)) $CN26_LOGS/log_confignode_all.log 2>/dev/null | grep -cF 'is fenced'" 2>/dev/null)
  TMO=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.26 "tail -n +$((BEFORE+1)) $CN26_LOGS/log_confignode_all.log 2>/dev/null | grep -cF 'Timeout during UPDATE_TABLE'" 2>/dev/null)
  echo "  日志统计：'is fenced'=$FEN  'Timeout during UPDATE_TABLE'=$TMO" | tee -a "$LOG"

  Q "DROP DATABASE IF EXISTS $D" >/dev/null 2>&1
done
echo "=== 模式 $MODE 汇总：成功 $SUC / $ROUNDS，丢列 $LOST ===" | tee -a "$LOG"
echo "log=$LOG"
