#!/bin/bash
SLOW_OF["RN-138"]="1"
# ============================================================================
# 来源缺陷单：PingCode V2-801（创建人：刘珍）
#   时间戳精度为 ns 时，写入几条数据，DataNode CommonDateTimeUtils 报
#   "Integer overflow" 警告
#   期望：ns 精度写入不产生 Integer overflow 告警
#   验证版本：2.0.13.1 / ab6d3de
#   说明：需临时把 timestamp_precision 改为 ns 并重启（慢用例组）
# ============================================================================
RN801_DB=root.v2801
RN801_LOG=/data1/iotdb/$NEW/logs/log_datanode_all.log

set_precision() {  # $1=ms|ns   —— CN 与 DN 都要设（CN 侧 SystemPropertiesUtils 读取）
  local p=$1 ip
  for ip in $CN_LIST; do
    ssh -n -o StrictHostKeyChecking=no root@$ip "f=/data/iotdb/$NEW/conf/iotdb-system.properties; touch \$f; sed -i '/^timestamp_precision=/d' \$f; echo 'timestamp_precision=$p' >> \$f" 2>/dev/null
  done
  for ip in $DN_LIST; do
    ssh -n -o StrictHostKeyChecking=no root@$ip "f=/data1/iotdb/$NEW/conf/iotdb-system.properties; touch \$f; sed -i '/^timestamp_precision=/d' \$f; echo 'timestamp_precision=$p' >> \$f" 2>/dev/null
  done
}

case_RN138() {
  local before after hits out
  echo "  切换 timestamp_precision=ns 并重启集群 ..."
  set_precision ns
  ( cd /data2/auto_test/treeview_suite && NEW="$NEW" bash hard_reset.sh > /tmp/rn801_reset.log 2>&1 )
  wait_running 420 >/dev/null 2>&1 || true
  echo "  重启后 Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"

  before=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.2 "wc -l < $RN801_LOG 2>/dev/null || echo 0" 2>/dev/null)
  before=${before:-0}

  T "drop database $RN801_DB" >/dev/null 2>&1
  assert_ok "$(T "create database $RN801_DB")" "建库"
  assert_ok "$(T "create timeseries $RN801_DB.d1.s1 int32")" "建序列"
  # ns 级时间戳（19 位）
  out=$(T "insert into $RN801_DB.d1(time,s1) values(1779933600000000000,1),(1779933600000000001,2),(1779933600000000002,3)")
  echo "  写入返回：$(echo "$out" | head -1 | cut -c1-140)"
  assert_ok "$out" "ns 时间戳写入"

  sleep 4
  after=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.2 "tail -n +$((before+1)) $RN801_LOG 2>/dev/null | grep -c 'Integer overflow' || true" 2>/dev/null)
  hits=${after:-0}
  echo "  新增 'Integer overflow' 行数：$hits"
  if [ "$hits" -eq 0 ]; then
    ok "ns 精度写入未产生 Integer overflow 告警"
  else
    fail "ns 精度写入仍产生 $hits 行 Integer overflow"
  fi

  echo "  恢复 timestamp_precision=ms 并重启 ..."
  set_precision ms
  ( cd /data2/auto_test/treeview_suite && NEW="$NEW" bash hard_reset.sh > /tmp/rn801_restore.log 2>&1 )
  wait_running 420 >/dev/null 2>&1 || true
  echo "  恢复后 Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"
}

CASES+=(
"RN-138|V2-801 ns 精度|日志|timestamp_precision=ns 写入不应产生 Integer overflow 告警|case_RN138"
)
