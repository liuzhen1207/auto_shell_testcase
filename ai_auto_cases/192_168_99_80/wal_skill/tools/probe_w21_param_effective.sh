#!/bin/bash
# ============================================================================
# probe_w21_param_effective.sh —— W-21 决定性探针：非法取值到底有没有"生效"
#
# 背景（RC10 源码实测）：
#   · 热加载 `loadWALHotModifiedProps`（IoTDBDescriptor.java:2185-2235）与启动加载
#     `loadWALProps`（:1828-1846）都只判 `> 0`：非法值**不会被 apply**，也**不打任何日志**；
#   · 但 `SET CONFIGURATION` 会把新值合并进 iotdb-system.properties 并**落盘**
#     （ConfigurationFileUtils.updateConfiguration:425-427）⇒ 文件里留下非法值。
#   ⇒ 所以"生效值==非法值"的说法需要用**运行时可观测行为**来判，而不是只看 show configuration。
#
# 判据（可观测、不依赖配置回显）：
#   A 相 默认阈值 31457280 + 固定写入量  ⇒ WAL 文件数 n_default、单文件最大字节 m_default
#   B 相 设成非法 -1（若真生效，轮转判据恒真 ⇒ 每次 append 都轮转）⇒ n_bad
#   C 相 设成合法 1048576（1MB，正对照：证明测量能区分阈值）        ⇒ n_1mb
#   判定：
#     · n_bad ≈ n_default 且远小于 n_1mb        ⇒ **非法值未生效**（只是被静默忽略 + 落盘）
#     · n_bad ≫ n_1mb（每次写入都换文件）        ⇒ **非法值真的生效了**（更严重的缺陷）
#   另外记录：SET 的响应文案、show configuration 读数、properties 落盘值、DN 日志有无告警。
#
# 【2026-10-23 修正 —— 本次误判的直接教训】
#   2026-10-22 18:25 那一轮跑在**集群已停**的时刻：三条 SET 全部返回
#   `Connection Error`，show/props 读数为空，三相 WAL 文件数都是 0；
#   而旧判据写的是 `[ B_N -ge $(( C_N * 3 )) ]`，`0 -ge 0` 成立 ⇒ 直接 fail
#   "非法阈值 -1 真的生效了"，是一条**纯粹的假阳性**。
#   现在加两道闸：
#     ① 前置：集群未就绪（show cluster 无 DataNode）直接 exit 2，不写结果、不给结论；
#     ② 判据有效性：A 相或 C 相拿不到 WAL 文件（或任一 SET 返回 Connection Error）⇒
#        **只 WARN 判"探针无效"**，绝不出"生效/未生效"的产品结论。
#
# 用法：bash tools/probe_w21_param_effective.sh [--consensus IoTConsensus|IoTConsensusV2]
# 前置：集群已就绪（本脚本不启停集群，收尾会停集群 —— 与其它用例一致）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
. "$SKILL/lib/common.sh"
. "$SKILL/lib/cmp.sh"
. "$SKILL/lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "probe_w21_${DATA_CONSENSUS}"

# ---------------------------------------------------------------------------
# 前置闸：集群必须真的在跑。探针不启停集群；集群停着跑出来的三相全是 0，
# 旧版本会把它误判成"非法值生效"（见文件头 2026-10-23 修正）。
# ---------------------------------------------------------------------------
_pre_cluster=$(sq 'show cluster;' 2>&1)
if ! printf '%s' "$_pre_cluster" | grep -qE 'DataNode'; then
  log "!! 前提不成立：集群未就绪（show cluster 里没有 DataNode 行）⇒ 探针无效，不产生任何产品结论"
  printf '%s\n' "$_pre_cluster" | head -5 | while IFS= read -r _l; do log "   $_l"; done
  log "   请先起集群（framework prepare_env/start_cluster_v20.sh 或 SKIP_LIFECYCLE 结构），再重跑本探针"
  exit 2
fi
log "前置检查：集群在线（show cluster 有 DataNode）"

DB=root.w21probe
DEVS=6
ROWS=400
BATCHES=3
KEY=wal_file_size_threshold_in_byte
DEF=31457280
SMALL=1048576

walcount(){ local h=$1; sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'; }
walmax(){ local h=$1; sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | sort -n | tail -1" 2>/dev/null | tr -dc '0-9'; }
walsum(){ local f=$1 h s=0 v; for h in "${DN[@]}"; do v=$($f "$h"); s=$((s + ${v:-0})); done; echo "$s"; }

write_batches(){ local b d k vals stmts=() base
  for b in $(seq 1 "$BATCHES"); do
    base=$(( ($(date +%s) - 3600) * 1000 + b * 100000 ))
    for ((d=1; d<=DEVS; d++)); do
      vals=""
      for ((k=0; k<ROWS; k++)); do vals="$vals($(( base + k * 10 )),$(( k + b ))),"; done
      stmts+=("insert into $DB.d$d(time,s1) values ${vals%,};")
    done
  done
  sql_lines_tree "${stmts[@]}" >"$ART/w21_write.log" 2>&1
  grep -qiE 'Exception' "$ART/w21_write.log" && warn "写入出现异常：$(grep -iE 'Exception' "$ART/w21_write.log" | head -2 | tr '\n' ' ')"
  return 0; }

# show configuration 读数（table 方言；wal_* 键在 system 配置里）
showcfg(){ local k=$1; sqt "show configuration;" 2>/dev/null | grep -E "^\| *$k *\|" | head -1 | awk -F'|' '{v=$3; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }
props(){ wal_props_get "${DN[0]}" "$1"; }

phase(){ local tag=$1 val=$2 resp sc pr n m
  log "===== [$tag] 请求 $KEY=$val ====="
  resp=$(sq "set configuration '$KEY'='$val';" 2>&1 | tr '\n' ' ')
  log "  SET 响应：$(printf '%s' "$resp" | cut -c1-220)"
  sleep 3
  sc=$(showcfg "$KEY"); pr=$(props "$KEY")
  log "  show configuration 读数=[$sc]  properties 落盘值=[$pr]"
  cmp_make_tree_db "$DB" "$DEVS" >/dev/null
  write_batches
  sleep 20
  n=$(walsum walcount); m=$(walsum walmax)
  log "  写入 ${DEVS}×${ROWS}×${BATCHES} 点后：本库 WAL 文件数=${n} 单文件最大=${m}B"
  PH_N=$n; PH_M=$m; PH_SC=$sc; PH_PR=$pr; PH_RESP=$resp
  # 清掉本库的 WAL（删库）以便下一相干净
  sq "drop database $DB;" >/dev/null 2>&1; sleep 5; }

log "=== W-21 探针开始：判据=运行时 WAL 轮转行为（不依赖配置回显）==="
log "  三元相：A=默认 $DEF / B=非法 -1 / C=合法 $SMALL（正对照）"

phase A_default "$DEF"
A_N=$PH_N; A_M=$PH_M; A_SC=$PH_SC; A_PR=$PH_PR; A_RESP=$PH_RESP
phase B_invalid "-1"
B_N=$PH_N; B_M=$PH_M; B_SC=$PH_SC; B_PR=$PH_PR; B_RESP=$PH_RESP
phase C_control "$SMALL"
C_N=$PH_N; C_M=$PH_M; C_SC=$PH_SC; C_PR=$PH_PR; C_RESP=$PH_RESP

log "--- DN 日志里有没有针对非法值的告警（$KEY=-1 前后）"
for h in "${DN[@]}"; do
  w=$(sshx "$h" "grep -acE 'negativ|invalid|illegal|out of range|should be positive' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
  log "  ${h##*.}: 相关告警行数=${w:-0}"
done

log "===== 结论判据 ====="
log "  A 默认阈值：文件数=$A_N 单文件最大=${A_M}B（show=[$A_SC] props=[$A_PR]）"
log "  B 非法 -1 ：文件数=$B_N 单文件最大=${B_M}B（show=[$B_SC] props=[$B_PR]）"
log "  C 1MB 对照：文件数=$C_N 单文件最大=${C_M}B（show=[$C_SC] props=[$C_PR]）"
log "  SET(-1) 响应原文：$(printf '%s' "$B_RESP" | cut -c1-200)"
if printf '%s' "$B_RESP" | grep -qiE 'restart|not support|invalid|illegal|out of range'; then
  pass "B 相 SET 有拒绝/重启提示 ⇒ 非法值被明确处理"
else
  warn "B 相 SET 无任何拒绝或重启提示（静默接受）"
fi
if [ "${B_PR:-}" = "-1" ]; then
  warn "非法值 -1 已落盘到 iotdb-system.properties（show=[$B_SC]）⇒ 配置文件与运行时可能不一致，属可观测性/健壮性问题"
fi

# ---------------------------------------------------------------------------
# 有效性闸 ②：没有 WAL 文件（或 SET 直接连不上）时，"文件数"不能作为判据。
# 必须先证明 C 相（1MB 正对照）确实产生了 WAL 文件，否则 0 vs 0 的比较毫无意义。
# ---------------------------------------------------------------------------
VALID=1
_invalid_reason=""
if printf '%s%s%s' "$A_RESP" "$B_RESP" "$C_RESP" | grep -qiE 'Connection Error|please check whether the network'; then
  VALID=0; _invalid_reason="SET 返回 Connection Error（集群不可用）"
elif [ "${C_N:-0}" -le 0 ]; then
  VALID=0; _invalid_reason="C 相（1MB 正对照）WAL 文件数=0，测量手段没有区分力"
elif [ "${A_N:-0}" -le 0 ]; then
  VALID=0; _invalid_reason="A 相（默认阈值）WAL 文件数=0，写入没有产生 WAL"
fi

if [ "$VALID" = "1" ]; then
  if [ "${B_N:-0}" -ge $(( C_N * 3 )) ]; then
    fail "B 相文件数($B_N) 远大于 1MB 对照($C_N) ⇒ 非法阈值 -1 **真的生效了**（每次写入都轮转），确认是缺陷"
  elif [ "${B_N:-0}" -le $(( A_N + 1 )) ]; then
    warn "B 相文件数($B_N) ≈ 默认相($A_N) ⇒ 非法值 **未生效**（被静默忽略，但已落盘）：需求口径是『回退默认值并给出明确文案』，当前是『静默忽略 + 落盘非法值』 ⇒ 文案缺失属实现偏差，需研发确认口径"
  else
    warn "B 相文件数($B_N) 介于默认($A_N)与 1MB 对照($C_N)之间，难以判定，需人工看图/日志"
  fi
else
  warn "探针无效（不计产品结论）：$_invalid_reason —— A=$A_N / B=$B_N / C=$C_N 个 WAL 文件；请确认集群在跑且写入确实产生 WAL 后重跑"
fi

log "  证据目录：$ART"
cmp_case_finish "" tree ""
