#!/bin/bash
# MB-14 IoTConsensusV2 协议下的内存缓冲区回归（V2 复跑门禁）
#   与 MB-03 同形（按比例刷盘 + 数据完整），但 data_region_consensus_protocol_class 切成
#   org.apache.iotdb.consensus.**iot**.IoTConsensusV2。
#   ⚠️ 注意：配置项必须写规范值 `...iot.IoTConsensusV2`。写成 `...pipe.IoTConsensusV2`
#   （jar 里确实存在该类）时 DataNode 仍会归一化并按 V2 启动，但 ConfigNode 判定 V2 region 时
#   不做归一化 ⇒ 不会创建 consensus pipe ⇒ follower 永远没有数据且无任何 ERROR。
#   详见 docs/DEFECT_F-10.md 与 lib/common.sh 的 mb_consensus_class 注释。
#   V2 关键差异（务必遵守）：batch 模式只复制**已 seal 的 TsFile**，未 seal 的 memtable 尾部
#   不会到 follower，也不计入 syncLag。因此收尾必须是 "flush → 等逐副本可见 → 等 syncLag 归零"
#   再取一致性基准（lib 的 cons_prep 已内置）。
#   判据：① 协议配置生效；② V2 专属 syncLag 指标（iot_consensus_v2）存在且能归零；
#         ③ 自动刷盘发生；④ 数据点数正确；⑤ 逐个停 DN 后副本一致性通过。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
DATA_CONSENSUS="IoTConsensusV2"
mb_parse_args "$@"
DATA_CONSENSUS="IoTConsensusV2"
mb_consensus_class
mb_case_init MB-14
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="${MB_MEM_PROPORTION:-1:2000:1:1:1:1}"
MB_FLUSH_PROPORTION="0.4"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION
DB=root.mb14
ROWS=${MB14_ROWS:-1200}
export EXTRA_CONF=""

log "  协议: $CONS_TAG ($CONSENSUS_CLASS)"
mb_cluster_prepare
for h in "${DN[@]}"; do
  got=$(sshx "$h" "grep -E '^data_region_consensus_protocol_class=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2-" | tr -d '\r')
  assert_eq "①$h 协议配置" "$got" "$CONSENSUS_CLASS"
done

mb_make_tree_db "$DB" 1 text
flush0=$(mb_flush_all)
log "--- 写入 ${ROWS} 点，等自动刷盘 ---"
ok=$(mb_bulk_text "$DB" d1 "$ROWS" 1); ok=${ok%% *}
assert_ge "写入语句成功数" "${ok:-0}" 1
if mb_wait_flush "$flush0" "$FLUSH_WAIT_SEC"; then pass "③自动刷盘发生"; else fail "③等 ${FLUSH_WAIT_SEC}s 未观察到自动刷盘"; fi

# V2 专属指标存在性（Prometheus 或直连）
n_v2=$(prom_series 'iot_consensus_v2{type="syncLag",cluster="'"$PROMETHEUS_CLUSTER"'",nodeType="DATANODE"}' 2>/dev/null | wc -l | tr -d ' ')
if [ "${n_v2:-0}" -eq 0 ]; then
  n_v2=0
  for h in "${DN[@]}"; do
    c=$(curl -s -m 8 "http://$h:$DN_METRIC_PORT/metrics" 2>/dev/null | grep -c 'iot_consensus_v2.*type="syncLag"')
    n_v2=$(( n_v2 + ${c:-0} ))
  done
fi
log "  iot_consensus_v2 syncLag series 数=$n_v2"
assert_ge "②V2 专属 syncLag 指标存在" "${n_v2:-0}" 1

sq 'flush;' >/dev/null 2>&1
sleep 5
assert_eq "④数据点数正确" "$(mb_count_all "$DB")" "$ROWS"

mb_case_finish "$(mb_data_sql "$DB" d1)" tree
