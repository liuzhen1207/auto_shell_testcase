#!/bin/bash
# ============================================================================
# 自检（不需要集群）：SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh
#   检查 ① 全部脚本语法；② env.conf 必填项；③ 客户端 CLI 存在；
#        ④ 5 个 DN / 3 个 CN 的 SSH 连通性与免密 sudo；⑤ Prometheus 可达；
#        ⑥ 关键配置键在目标版本的模板里存在（防止版本漂移把用例测成"参数不存在"）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
ok=0; failed=0
chk(){ if eval "$2" >/dev/null 2>&1; then echo "  ok   $1"; ok=$((ok+1)); else echo "  FAIL $1"; failed=$((failed+1)); fi; }

echo "== ① 语法检查 =="
for f in "$SKILL"/lib/*.sh "$SKILL"/cases/common/*.sh "$SKILL"/cases/perf/*.sh "$SKILL"/tools/*.sh; do
  [ -f "$f" ] || continue
  chk "bash -n $(basename "$f")" "bash -n '$f'"
done

echo "== ② env.conf =="
. "$SKILL/conf/env.conf"
PERF_BM_DIR="${PERF_BM_DIR:-/data1/iotdb/testcase/MigrateRegionTest/benchmark/bm_20251017_b6be9bd}"
for k in CN_NODES DN_NODES SSH_USER V_TESTDB DB_PARENT_DIR SHELL_CLIENT_DIR SCHEMA_RF DATA_RF DATA_CONSENSUS; do
  chk "$k 非空" "[ -n \"\${$k:-}\" ]"
done
chk "SchemaRF=3" "[ '$SCHEMA_RF' = '3' ]"
chk "DataRF=2"   "[ '$DATA_RF' = '2' ]"
chk "DN 数量=5"  "[ $(wc -w <<<"$DN_NODES") -eq 5 ]"
chk "CN 数量=3"  "[ $(wc -w <<<"$CN_NODES") -eq 3 ]"

echo "== ③ 客户端 CLI =="
CLI="$SHELL_CLIENT_DIR/$V_TESTDB/sbin/start-cli.sh"
chk "CLI 存在: $CLI" "[ -x '$CLI' ]"
chk "DN 上 DB 目录存在: $DB_PARENT_DIR/$V_TESTDB" "ssh -n $SSH_OPTS '$SSH_USER@${DN_NODES%% *}' 'test -d $DB_PARENT_DIR/$V_TESTDB'"

if [ "${SELFTEST_NO_CLUSTER:-0}" = "1" ]; then
  echo "== ④⑤⑥ 已按 SELFTEST_NO_CLUSTER=1 跳过（集群/网络检查）=="
else
  echo "== ④ SSH + 免密 sudo =="
  for h in $CN_NODES $DN_NODES; do
    chk "ssh $h" "ssh -n $SSH_OPTS '$SSH_USER@$h' true"
    chk "sudo -n $h" "ssh -n $SSH_OPTS '$SSH_USER@$h' 'sudo -n true'"
  done
  echo "== ⑤ Prometheus =="
  chk "healthy $PROMETHEUS_URL" "curl -s -o /dev/null -m 5 '$PROMETHEUS_URL/-/healthy'"
  n=$(curl -s -m 10 -G "$PROMETHEUS_URL/api/v1/query" \
      --data-urlencode "query=count({__name__=~\"iot_consensus(_v2)?\",type=\"syncLag\",cluster=\"$PROMETHEUS_CLUSTER\"})" 2>/dev/null \
      | grep -oE '"[0-9]+"' | head -1 | tr -d '"')
  chk "syncLag series>0 (cluster=$PROMETHEUS_CLUSTER, 实测 ${n:-0})" "[ \${n:-0} -gt 0 ]"
  echo "== ⑦ 性能测试工具（iot-benchmark）=="
  chk "benchmark.sh 存在" "test -x '$PERF_BM_DIR/benchmark.sh'"
  chk "benchmark function.xml" "test -f '$PERF_BM_DIR/conf/function.xml'"
  chk "benchmark logback.xml" "test -f '$PERF_BM_DIR/conf/logback.xml'"
  chk "benchmark java 可用（远端）" "ssh -n $SSH_OPTS '$SSH_USER@${DN_NODES%% *}' 'command -v java'"
  echo "== ⑥ 版本模板里关键键存在 =="
  T="$DB_PARENT_DIR/$V_TESTDB/conf/iotdb-system.properties.template"
  for k in datanode_memory_proportion storage_engine_memory_proportion write_memory_proportion \
           flush_proportion reject_proportion wal_buffer_queue_proportion device_path_cache_proportion \
           buffered_arrays_memory_proportion wal_buffer_size_in_byte wal_memtable_snapshot_threshold_in_byte \
           max_wal_memtable_snapshot_num enable_timed_flush_seq_memtable seq_memtable_flush_interval_in_ms \
           data_region_consensus_protocol_class; do
    chk "模板含 $k" "ssh -n $SSH_OPTS '$SSH_USER@${CN_NODES%% *}' 'grep -qE \"^#? *$k *=\" $T'"
  done
fi

echo
echo "== 结果: ok=$ok failed=$failed =="
[ "$failed" -eq 0 ] || exit 1
