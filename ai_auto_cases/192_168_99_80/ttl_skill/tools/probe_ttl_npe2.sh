#!/bin/bash
# ============================================================================
# probe_ttl_npe2.sh —— TTL 外写入在 IoTConsensusV2 下的 NPE 复现（最小化 + 对照）
#   A) 多行插入，全部在 TTL 内                     ⇒ 期望成功
#   B) 多行插入，1 行 TTL 内 + 1 行 TTL 外         ⇒ 期望 607（关键）
#   C) 单行插入，TTL 外                            ⇒ 期望 607（对照：单行走 InsertRowNode 分支）
#   每步记录客户端响应 + 三节点 NPE 增量；结束打包 CN/DN 日志
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "probe_ttl_npe_${DATA_CONSENSUS}"

DB=probe_npe
TBL=t1
WS=$ART/probe_ws
mkdir -p "$WS"
tq(){ sql_lines_table "use $DB;" "$@"; }

npe_cnt(){ local h=$1
  sshx "$h" "grep -ac 'getDevice2MeasurementsMapFromInsertRowsNode' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
npe_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(npe_cnt "$h") )); done; echo "$s"; }
resp1(){ printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-220; }

log "=== 0) 集群准备（${DATA_CONSENSUS}）==="
ttl_cluster_prepare || { log "集群准备失败"; exit 2; }

log "=== 1) 建库/建表（表 TTL=1000ms）==="
tq "create database $DB;" >/dev/null 2>&1
tq "create table $TBL (time TIMESTAMP TIME, dev STRING TAG, s1 INT32 FIELD) with (ttl='1000');" >/dev/null 2>&1
log "  show tables: $(tq "show tables from $DB;" 2>&1 | tr '\n' ' ' | cut -c1-120)"

N0=$(npe_sum); log "  基线 NPE 计数（三节点合计）=${N0:-0}"

log "=== A) 多行插入，全部 TTL 内（对照，期望成功）==="
ra=$(tq "insert into $TBL (time,dev,s1) values (now(),'d1',1),(now(),'d2',2);" 2>&1)
log "  响应: $(resp1 "$ra")"
NA=$(npe_sum); log "  NPE 计数: ${N0:-0} -> ${NA:-0}"

log "=== B) 多行插入，1 行 TTL 内 + 1 行 TTL 外（关键，期望 607）==="
rb=$(tq "insert into $TBL (time,dev,s1) values (now(),'d3',3),(now()-10000,'d4',4);" 2>&1)
log "  响应: $(resp1 "$rb")"
NB=$(npe_sum); log "  NPE 计数: ${NA:-0} -> ${NB:-0}"
printf '%s\n' "$rb" >"$WS/B_response.txt"

log "=== C) 单行插入，TTL 外（对照：走 InsertRowNode 分支，期望 607）==="
rc=$(tq "insert into $TBL (time,dev,s1) values (now()-10000,'d5',5);" 2>&1)
log "  响应: $(resp1 "$rc")"
NC=$(npe_sum); log "  NPE 计数: ${NB:-0} -> ${NC:-0}"

log "=== D) 判读 ==="
grep -q '607' <<<"$rb" && log "  B 相命中 607（符合预期）" || log "  B 相**未**返回 607"
[ "${NB:-0}" -gt "${NA:-0}" ] && log "  B 相触发 NPE 增量 +$(( NB - NA ))" || log "  B 相未产生 NPE"
[ "${NC:-0}" -gt "${NB:-0}" ] && log "  C 相（单行）也触发 NPE 增量 +$(( NC - NB ))" || log "  C 相（单行）未触发 NPE"

log "=== E) 抓 B 相相关日志（栈 + 上下文）==="
for h in "${DN[@]}"; do
  log "  --- [$h] ---"
  sshx "$h" "f=$DB_DIR/logs/log_datanode_all.log; n=\$(grep -an 'getDevice2MeasurementsMapFromInsertRowsNode' \$f | head -1 | cut -d: -f1); [ -n \"\$n\" ] && sed -n \"\$((n-3)),\$((n+9))p\" \$f | cut -c1-200" 2>/dev/null | sed 's/^/    /' | head -14
done

log "=== F) 打包三节点 CN/DN 日志 ==="
TAR="$ART/probe_ttl_npe_logs_$(date +%Y%m%d_%H%M%S).tar.gz"
for h in "${HOSTS[@]}"; do
  sshx "$h" "cd $DB_DIR/logs && tar -czf /tmp/probe_npe.${h##*.}.tgz log_*.log 2>/dev/null" >/dev/null 2>&1
  scp -q root@"$h":/tmp/probe_npe."${h##*.}".tgz "$WS/" 2>/dev/null || true
done
tar -czf "$TAR" -C "$WS" . 2>/dev/null
log "  日志包：$TAR（$(stat -c %s "$TAR" 2>/dev/null)B）"
log "=== 结束 ==="
ttl_case_finish "" tree "$TAR"
