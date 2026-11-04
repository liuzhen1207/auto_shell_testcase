#!/bin/bash
# ============================================================================
# 来源缺陷单：PingCode V2-375（创建人：刘珍）
#   树模型每修改一次序列类型，CN Leader 产生一条 ERROR：
#   StateMachineProcedure pid=XX not set next state, but return HAS_MORE_STATE
#   期望：改类型过程不再刷该 ERROR
#   验证版本：2.0.13.1 / ab6d3de
# ============================================================================
RN375_DB=root.v2375
RN375_CN=172.16.2.26
RN375_LOG=/data/iotdb/$NEW/logs/log_confignode_all.log

case_RN130() {
  local before after hits i
  before=$(ssh -o StrictHostKeyChecking=no root@$RN375_CN "wc -l < $RN375_LOG 2>/dev/null || echo 0" 2>/dev/null)
  before=${before:-0}

  T "drop database $RN375_DB" >/dev/null 2>&1
  T "create database $RN375_DB" >/dev/null 2>&1
  for i in 1 2 3; do
    T "create timeseries $RN375_DB.d${i}.s int32" >/dev/null 2>&1
    T "insert into $RN375_DB.d${i}(time,s) values(1,1)" >/dev/null 2>&1
    local out
    out=$(T "alter timeseries $RN375_DB.d${i}.s set data type int64")
    echo "  第 $i 次改类型：$(echo "$out" | head -1 | cut -c1-110)"
    assert_ok "$out" "第 $i 次修改数据类型成功"
  done

  sleep 5
  after=$(ssh -o StrictHostKeyChecking=no root@$RN375_CN "tail -n +$((before+1)) $RN375_LOG 2>/dev/null | grep -c 'not set next state' || true" 2>/dev/null)
  hits=${after:-0}
  echo "  新增 'not set next state' ERROR 行数：$hits"
  if [ "$hits" -eq 0 ]; then
    ok "CN 未再打印 StateMachineProcedure ERROR"
  else
    fail "CN 仍打印 $hits 行 'not set next state' ERROR"
  fi

  T "drop database $RN375_DB" >/dev/null 2>&1
}

CASES+=(
"RN-130|V2-375 CN 日志|日志|修改序列类型不应在 CN 打印 StateMachineProcedure not set next state|case_RN130"
)
