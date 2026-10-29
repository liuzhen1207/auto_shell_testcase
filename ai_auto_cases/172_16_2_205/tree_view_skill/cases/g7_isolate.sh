# Group 7: deterministic DataNode isolation (metadata lease fenced) during view auto-sync.
# The product exposes no KillPoint on this path; the deterministic hook is the metadata lease:
# CN heartbeats stop -> T_fence (metadata_lease_fence_ms, default 20000ms) expires -> the DN self-fences
# (MetadataLeaseManager.failIfMetadataLeaseFenced). We reproduce it by partitioning one DN from all CNs.

VPN_UNBLOCK() {
  local ip=$1 cn
  for cn in 172.16.2.26 172.16.2.27 172.16.2.28; do
    ssh -o StrictHostKeyChecking=no root@$ip "while iptables -D INPUT -s $cn -j DROP 2>/dev/null; do :; done; while iptables -D OUTPUT -d $cn -j DROP 2>/dev/null; do :; done; true" 2>/dev/null
  done
}

case_TV060() {
  local o target="" i n leader_ip
  # defensive: clear any leftover partition rules on all DNs
  local d
  for d in 172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6; do VPN_UNBLOCK "$d"; done

  wait_running 300 || { fail "集群未恢复到 8 节点，无法开始隔离用例"; return; }

  T "DROP DATABASE root.tv060" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv060" >/dev/null 2>&1
  T "CREATE DATABASE root.tv060" >/dev/null; Q "CREATE DATABASE tv060" >/dev/null
  T "CREATE TIMESERIES root.tv060.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv060.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv060.**" >/dev/null
  sleep 6
  assert_col tv060 v s1 INT32 "初始列 s1"

  # pick the SchemaRegion leader of the target database as the isolated DN (retry a few times).
  # NOTE: "show regions" is dialect sensitive: tree-model databases are only listed in tree dialect.
  local QT
  QT() { $CLI -h 172.16.2.2 -p 6667 -u root -pw ${PW:-TimechoDB@2021} -sql_dialect tree -e "$1" 2>&1; }
  for i in 1 2 3; do
    leader_ip=$(QT "show regions;" 2>/dev/null | awk -F'|' '$3 ~ /SchemaRegion/ && $5 ~ /root.tv060/ && $12 ~ /Leader/ {gsub(/ /,"",$9); print $9}' | head -1)
    [ -n "$leader_ip" ] && break
    sleep 5
  done
  if [ -z "$leader_ip" ]; then
    fail "无法识别 root.tv060 的 SchemaRegion leader，用例未执行隔离"
    return
  fi
  target=$leader_ip
  echo "  isolate DataNode: $target (root.tv060 SchemaRegion leader)"

  echo "  block $target <-> CN"
  local cn
  for cn in 172.16.2.26 172.16.2.27 172.16.2.28; do
    ssh -o StrictHostKeyChecking=no root@$target "iptables -I INPUT -s $cn -j DROP; iptables -I OUTPUT -d $cn -j DROP" 2>/dev/null
  done
  echo "  wait for lease to expire (T_fence 20s + margin)"
  sleep 32

  local logf=/data1/iotdb/$NEW/logs/log_datanode_all.log
  local fenced_lines
  fenced_lines=$(ssh -o StrictHostKeyChecking=no root@$target "grep -c 'Metadata lease is fenced' $logf 2>/dev/null" 2>/dev/null)
  echo "  'Metadata lease is fenced' lines before write: ${fenced_lines:-0}"

  # while fenced, creating a measurement must fail (fail-closed), and must not add the column
  o=$(Tn $target "CREATE TIMESERIES root.tv060.d2.s2 INT64" 2>&1)
  echo "  create while isolated -> $(echo "$o" | head -2 | tr '\n' ' ' | cut -c1-200)"
  if echo "$o" | grep -qi "metadata lease is fenced"; then
    echo "  expected: creation rejected by fenced metadata lease"
  elif echo "$o" | grep -qE "Msg: org.apache.iotdb.jdbc|Exception|Error"; then
    echo "  expected: creation failed while isolated (non-success)"
  else
    fail "DN 隔离期间创建序列未失败"
  fi
  sleep 5
  assert_no_col tv060 v s2 "隔离期间不应补列"

  # evidence: fencing must be visible in the DN log
  fenced_lines=$(ssh -o StrictHostKeyChecking=no root@$target "grep -c 'Metadata lease is fenced' $logf 2>/dev/null" 2>/dev/null)
  echo "  'Metadata lease is fenced' lines after write: ${fenced_lines:-0}"
  [ "${fenced_lines:-0}" = "0" ] && fail "隔离期间未在 DN 日志看到租约失效证据"

  # evidence: the stack of the rejected session (Thrift logs undeclared runtime exceptions this way)
  echo "  --- openSession rejection stack (first 30 lines) ---"
  ssh -o StrictHostKeyChecking=no root@$target "grep -A45 -m1 'Internal error processing openSession' $logf 2>/dev/null" 2>/dev/null | head -30

  # heal: remove the partition, wait for lease recovery
  echo "  heal partition"
  VPN_UNBLOCK $target
  for i in $(seq 1 40); do
    n=$(Q "show cluster;" 2>/dev/null | grep -c "Running")
    [ "$n" -ge 8 ] && break
    sleep 5
  done
  sleep 15

  # retry: the same creation must now succeed and the column must be added
  o=$(Tn $target "CREATE TIMESERIES root.tv060.d2.s2 INT64" 2>&1)
  assert_ok "$o" "恢复后重试创建序列"
  for i in $(seq 1 20); do
    view_cols tv060 v | grep -q "^s2:" && break
    sleep 3
  done
  assert_col tv060 v s2 INT64 "恢复后应补列 s2"

  # the fenced-while-adding-view-columns line is the feature-side evidence; record it when present
  o=$(ssh -o StrictHostKeyChecking=no root@$target "grep -c 'metadata lease is fenced while adding view columns' $logf 2>/dev/null" 2>/dev/null)
  echo "  fenced-while-adding-view-columns lines: ${o:-0}"
  VPN_UNBLOCK $target
}

CASES+=(
"TV-060|高可用|可靠性|DN 隔离（元数据租约失效）时创建序列失败，恢复后重试补列|case_TV060||0"
)
