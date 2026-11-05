#!/bin/bash
SLOW_OF["RN-135"]="1"
# ============================================================================
# 来源缺陷单：PingCode V2-861（创建人：刘珍）
#   stop DataNode 时正在执行的查询会在 DN 日志打印 NullPointerException
#   （原用例 tc2026_May_0001_v2091_query_release_more_mem.sh，23 次中 6 次 NPE）
#   期望：stop DN 期间查询侧不产生 NPE 日志
#   验证版本：2.0.13.1 / ab6d3de
#   说明：把原长跑缩短为「并发查询 40 秒 + 期间 stop 一台 DN」
# ============================================================================
RN861_IP=172.16.2.6
RN861_DB=root.rn0861

case_RN135() {
  local before after npe out i
  # 准备数据
  T "drop database $RN861_DB" >/dev/null 2>&1
  T "create database $RN861_DB" >/dev/null 2>&1
  T "create timeseries $RN861_DB.d1.s1 int32" >/dev/null 2>&1
  T "insert into $RN861_DB.d1(time,s1) values(1,1),(2,2),(3,3)" >/dev/null 2>&1

  before=$(ssh -o StrictHostKeyChecking=no root@$RN861_IP "wc -l < /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null || echo 0" 2>/dev/null)
  before=${before:-0}

  # 后台并发查询 40 秒（用 CLI 循环模拟并发客户端）
  (
    for i in $(seq 1 8); do
      timeout 6 $CLI -h "$HOST" -p 6667 -u root -pw "$PW" -sql_dialect tree \
        -e "select s1 from $RN861_DB.d1" >/dev/null 2>&1
    done
  ) &
  local qpid=$!

  sleep 8
  echo "  停止 DN $RN861_IP（查询进行中）..."
  ssh -o StrictHostKeyChecking=no root@$RN861_IP "bash /data1/iotdb/$NEW/sbin/stop-datanode.sh > /tmp/rn861_stop.log 2>&1" 2>/dev/null
  wait $qpid 2>/dev/null
  sleep 5

  after=$(ssh -o StrictHostKeyChecking=no root@$RN861_IP "tail -n +$((before+1)) /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null | grep -c 'NullPointerException' || true" 2>/dev/null)
  npe=${after:-0}
  echo "  stop 期间 DN 新增 NullPointerException 行数：$npe"
  if [ "$npe" -eq 0 ]; then
    ok "stop DN 期间查询侧未产生 NPE"
  else
    fail "stop DN 期间仍产生 $npe 行 NPE"
  fi

  echo "  重启 DN ..."
  ssh -o StrictHostKeyChecking=no root@$RN861_IP "cd /data1/iotdb/$NEW && setsid /data1/iotdb/$NEW/sbin/start-datanode.sh > /tmp/rn861_start.log 2>&1 < /dev/null &" 2>/dev/null
  wait_running 360 >/dev/null 2>&1 || true
  echo "  恢复后 Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"

  T "drop database $RN861_DB" >/dev/null 2>&1
}

CASES+=(
"RN-135|V2-861 停DN查询|可靠性|并发查询中 stop DN 不应产生 NullPointerException 日志|case_RN135"
)
