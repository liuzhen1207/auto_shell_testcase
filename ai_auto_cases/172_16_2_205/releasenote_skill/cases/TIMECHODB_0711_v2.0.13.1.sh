#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0711】调用 java session.close() 后，DataNode 打印
#   ERROR 日志：TTransportException: java.net.SocketException: Connection reset
#   期望：客户端正常 close 时，DN 不应打 ERROR 级 Thrift 异常堆栈
#   验证版本：2.0.13.1 / ab6d3de
#   判据：连续 open/close 3 次后，DN 新增日志中不含 "TTransportException"/"Connection reset" 的 ERROR
# ============================================================================
RN0711_CLASSES=/data2/auto_test/releasenote_skill/cases/.jdbc_classes

case_RN113() {
  local cp out ip before after hits=0
  cp=$(ls /data2/iotdb/$NEW/lib/timechodb-server-*.jar 2>/dev/null | head -1):/data2/iotdb/$NEW/lib/common-dependency.jar
  mkdir -p "$RN0711_CLASSES"
  cp /tmp/RnJdbc.java "$RN0711_CLASSES/" 2>/dev/null
  ( cd "$RN0711_CLASSES" && javac -encoding UTF-8 -nowarn -cp "$cp" -d . RnJdbc.java 2>&1 | head -3 )
  [ -f "$RN0711_CLASSES/RnJdbc.class" ] || { fail "RnJdbc 编译失败"; return 1; }

  ip=172.16.2.2
  before=$(ssh -o StrictHostKeyChecking=no root@$ip "wc -l < /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null || echo 0" 2>/dev/null)
  before=${before:-0}

  out=$(java -cp "$cp:$RN0711_CLASSES" RnJdbc close 127.0.0.1 6667 root "$PW" 3 2>&1)
  echo "  客户端结果：$(echo "$out" | tail -1 | cut -c1-120)"
  assert_contains "$out" 'CLOSE_OK' "3 次 open/close 完成"

  sleep 3
  after=$(ssh -o StrictHostKeyChecking=no root@$ip "tail -n +$((before+1)) /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null | grep -cE 'TTransportException|Connection reset' || true" 2>/dev/null)
  hits=${after:-0}
  echo "  新增日志命中 TTransportException/Connection reset 行数：$hits"
  if [ "$hits" -eq 0 ]; then
    ok "DN 未打印 TTransportException/Connection reset"
  else
    fail "DN 仍打印 $hits 行 TTransportException/Connection reset"
  fi
}

CASES+=(
"RN-113|TIMECHODB-0711 日志规范|日志|session.close() 后 DN 不应打印 TTransportException/Connection reset 的 ERROR|case_RN113"
)
