#!/bin/bash
# ============================================================================
# TP-05 缺陷门禁（TDB-611）：tier_ttl_in_ms 的个数与 dn_data_dirs 层数不一致时，
#   DataNode 的 WARN 文案必须提示**真正生效**的键名 tier_ttl_in_ms，
#   不得提示已移除的旧键 default_ttl_in_ms。
#
#   判据（三条，全过才算 PASS）：
#     1) 场景有效：重启后 DN 启动日志里出现 tier 校验 WARN（`should have the same tiers number`）；
#     2) 该 WARN **不含** `default_ttl_in_ms`（旧键：安装包 conf/ 与代码里都不存在）；
#     3) 该 WARN **含** `tier_ttl_in_ms`（修复后的期望文案）。
#   另加一条静态校验：
#     4) `<安装目录>/conf/iotdb-system.properties.template` 里有 tier_ttl_in_ms、没有 default_ttl_in_ms。
#
#   做法：正常起集群 → 停 → 在 DN 节点的 conf 里写入 `tier_ttl_in_ms=1000;2000`
#   （2 个值 vs 默认 1 层 dn_data_dirs）→ 启 → 抓 WARN → 还原 conf → 再次起停。
#
# 用法： bash ttl_tier_warn_key.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_tier_warn_key_${DATA_CONSENSUS}"

NODE=${DN[0]}
CONF=$DB_DIR/conf/iotdb-system.properties
BAK=$CONF.bak_tierwarn
TPL=$DB_DIR/conf/iotdb-system.properties.template
OLDKEY=default_ttl_in_ms
NEWKEY=tier_ttl_in_ms

log "--- 集群准备 ---"
ttl_cluster_prepare

log "--- 在 $NODE 写入不匹配的 $NEWKEY（2 个值 vs 默认 1 层 dn_data_dirs）---"
cluster_stop
sshx "$NODE" "cp -p $CONF $BAK && sed -i '/^$NEWKEY=/d' $CONF && printf '\n# added by ttl_tier_warn_key case\n$NEWKEY=1000;2000\n' >> $CONF && grep -nE '^$NEWKEY=' $CONF"
T0=$(date '+%Y-%m-%d %H:%M:%S')
log "  重启起点 T0=$T0"
cluster_start

log "--- 抓取重启后的 tier 校验 WARN（只看 T0 之后的行）---"
WARN=$(sshx "$NODE" "grep -hE 'should have the same tiers number' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | awk -v t0="$T0" 'substr($0,1,19) >= t0' | tail -3)
if [ -n "$WARN" ]; then
  printf '%s\n' "$WARN" | while IFS= read -r line; do log "  WARN>> $(printf '%s' "$line" | cut -c1-200)"; done
else
  log "  （T0 之后没有抓到该 WARN）"
fi

log "--- 判定（TDB-611 门禁）---"
if [ -z "$WARN" ]; then
  fail "场景无效：重启后 $NODE 的日志里没有「should have the same tiers number」告警（无法判定文案）"
else
  if printf '%s' "$WARN" | grep -qF "$OLDKEY"; then
    fail "命中 TDB-611：告警文案写的是已移除的旧键 $OLDKEY（用户按提示配置该键不会生效、告警也不会消失）"
  else
    pass "告警文案未出现旧键 $OLDKEY"
  fi
  if printf '%s' "$WARN" | grep -qF "$NEWKEY"; then
    pass "告警文案提示了真正生效的键 $NEWKEY"
  else
    fail "告警文案没有提示真正生效的键 $NEWKEY"
  fi
fi

log "--- 静态校验：配置模板里的键名 ---"
tpl_new=$(sshx "$NODE" "grep -cE '^$NEWKEY=' $TPL 2>/dev/null" 2>/dev/null | tr -dc '0-9')
tpl_old=$(sshx "$NODE" "grep -cF '$OLDKEY' $TPL 2>/dev/null" 2>/dev/null | tr -dc '0-9')
tpl_old=${tpl_old:-0}
log "  模板 $TPL：$NEWKEY 行数=$tpl_new，$OLDKEY 出现次数=$tpl_old"
[ "${tpl_new:-0}" -ge 1 ] && pass "模板里有 $NEWKEY（真键）" || fail "模板里没有 $NEWKEY"
[ "$tpl_old" -eq 0 ] && pass "模板里没有旧键 $OLDKEY" || fail "模板里仍出现旧键 $OLDKEY（$tpl_old 次）"

log "--- 还原 conf 并重启（保持环境干净）---"
sshx "$NODE" "mv -f $BAK $CONF && (grep -nE '^($NEWKEY|dn_data_dirs)=' $CONF || echo '  (已还原：两键均未显式设置)')"
cluster_stop
cluster_start

log "--- 收尾三件套（本用例不建业务数据，只做 sync lag + 日志扫描，跳过副本一致性查询）---"
post_checks "" tree
ttl_case_finish "" tree ""
