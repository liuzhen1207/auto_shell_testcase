#!/bin/bash
# ============================================================================
# W-03 `wal_mode` 的 restart-only 语义：
#       SET CONFIGURATION 返回文案（需重启）+ properties 已落盘
#         → 不重启时运行期**仍按旧值**
#         → 重启后新值生效（逐节点核对生效值）
#       两相各一次重启：ASYNC→SYNC、SYNC→ASYNC
#
# 【用例】W-03（集合 mode；树模型；库名 root.walro）
#
# 【覆盖需求】
#   · docs/req_sources/design_extract.md
#       §7.1-15（设计文档只标了 7 个"热加载"键，`wal_mode` **不在其中**，且文档未说"非热加载=必须重启"）
#       §7.2 参数清单（wal_mode 默认 ASYNC，未标热加载）；§8.2 TP-10/TP-11 的模式语义
#   · docs/req_sources/source_grounding.md（**判据与时序完全按它**）
#       §1.2/§1.4 `wal_mode`：模板 `iotdb-system.properties.template:1929-1930` 标注 `# effectiveMode: restart`；
#           装载点 IoTDBDescriptor.java:1829-1830；**热加载函数 loadWALHotModifiedProps（:2185-2275）不含 wal_mode**；
#           比较点 loadWALHotModifiedProps 的调用方 :2712 也不含它 ⇒ 只有重启才换模式。
#       §1.1 SET CONFIGURATION 的 restart 提示生成逻辑：ConfigurationFileUtils.java:102（EFFECTIVE_MODE_PREFIX）、
#           :665-672（解析 HOT_RELOAD / RESTART / FIRST_START …）、ConfigManager.java:1927-1932
#           （对 RESTART 键把键名加进 restartRequiredKeys，CLI 回显 "restart is required"）。
#           反例控制：`wal_min_effective_info_ratio` 模板标注 hot_reload（模板 :1987）⇒ 对它的 SET **不应**带该提示
#           （本用例用"原值重设"的方式做这个对照，零副作用）。
#       §5.4 SYNC/ASYNC 语义差异（写请求是否 waitForResult）—— 本用例只做"值是否切换"的判定，不做性能判定。
#
# 【判据】（双信号/多信号；每条注明证据来源）
#   每相都做（硬，除注明外）：
#     1) SET CONFIGURATION 返回文案含 `restart is required` 且点名 `wal_mode`
#        （来源：CLI 回显原文，helper wal_set / cmp_set_hot；每条 SET 的原文都打进 $OUT）
#     2) properties 已落盘新值（逐节点）——来源：<DB_DIR>/conf/iotdb-system.properties，helper wal_props_get
#     3) 不重启 ⇒ 运行期**仍是旧值**：逐节点 show configuration 的生效值 == 旧值
#        （来源：cmp_eff；若该构建未暴露 wal_mode 则降级 WARN，并以 PID 未变 + 落盘值 + 数据面三信号兜底）
#     4) 场景有效性：SET 之后各 DN 的 DataNode 进程 PID **必须未变**（证明确实没有重启）
#     5) 不重启下继续写入成功且行数正确（来源：CLI count）——证明旧模式仍工作
#     6) 重启后新值生效：逐节点 show configuration 生效值 == 新值（不可观测时降级 WARN）+ properties == 新值
#     7) 场景有效性：重启后各 DN 的 PID **必须变化**（证明重启确实发生）
#     8) 重启后数据不丢（硬，最终判据）：总行数 == 累计写入行数，且 count/sum 与 d1 全序列指纹与重启前一致
#     9) 重启后 WAL 目录仍有 .wal 文件（两种模式下 WAL 都应处于启用状态）
#   相 0 专有（一次）：
#    10) 反例控制：`SET CONFIGURATION 'wal_min_effective_info_ratio'='<原值>'` 的返回**不得**含 `restart is required`
#        （来源：模板 :1987 effectiveMode: hot_reload；证明重启提示是按 effectiveMode 逐键给出的，而不是所有 SET 都提示）
#
# 【注意事项】
#   ⚠ 本脚本**未在集群实跑**（harness 阶段；99.80 正在跑合并长回归，禁止任何启停集群动作）。只做了 `bash -n`。
#   ⚠ `wal_mode` 是 restart 参数 ⇒ 起始模式只能"写 conf + 起集群"；
#     起始相用 `EXTRA_CONF="..." cmp_cluster_prepare`（单条命令的前缀环境变量），末尾显式追加 wal_mode=ASYNC，
#     追加前用 walro_strip_keys 摘掉 WAL_EXTRA_DEFAULT 里的同名键——cluster_write_conf 逐键回读时把
#     "第一次出现的期望值"与"最后落盘的值"相比，同名键带不同值会产生**假 FAIL**（本项目踩过 34 个假 FAIL）。
#   ⚠ 不重启相**不做 clean**（否则数据面无法跨重启比对）；重启相用 cluster_stop → （必要时同值重写 conf）→ cluster_start。
#   ⚠ harness 侧缺口（本文件不改 lib/conf）：lib/common.sh 的 cluster_set_conf 引用 TTL 专用变量
#     TTL_CHECK_INTERVAL_MS / MAX_EXPIRED_TIME_MS / EXPIRED_DATA_RATIO，而 WAL 的 conf/env.conf 未定义它们；
#     `set -u` 下会让"写配置"这步直接终止用例 ⇒ 本文件在 cmp_cluster_prepare 之前给出安全默认值。
#
#   首轮实跑 watch list（最关键 5 条）：
#     ① SET CONFIGURATION 'wal_mode'='SYNC' 的实际返回文案（本用例断言含 `restart is required` 且点名 wal_mode）；
#        若文案不同（例如中文 locale 或措辞变化）会直接 FAIL —— 这正是首跑要标定的点。
#     ② `show configuration`（table 方言）是否暴露 wal_mode：不暴露时第 3)/6) 条降级 WARN，靠 properties + PID 兜底。
#     ③ SET 之后 properties 是否真的多了一行 wal_mode=SYNC（历史经验：SET 会把值写进 iotdb-system.properties）。
#     ④ 重启相前后 PID 是否真的变了（框架 stop/start 是否会"复用"未退干净的进程 ⇒ 会让第 4)/7) 条误判）。
#     ⑤ 框架的 start 脚本是否会把 conf 还原成 conf_orig（若还原，本用例会打印 WARN 并以**同值**重写，不改变语义）。
#
# 用法： bash cases/common/wal_mode_restart_only.sh [--consensus IoTConsensus|IoTConsensusV2]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"

# ---- harness 侧防御（见头注释；不改 lib/conf）--------------------------------
: "${TTL_CHECK_INTERVAL_MS:=60000}"
: "${MAX_EXPIRED_TIME_MS:=9223372036854775807}"
: "${EXPIRED_DATA_RATIO:=0.000001}"
export TTL_CHECK_INTERVAL_MS MAX_EXPIRED_TIME_MS EXPIRED_DATA_RATIO

cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_mode_restart_only_${DATA_CONSENSUS}"

DB=root.walro
DEVS=${WAL_DEVS:-6}
ROWS=${WAL_ROWS:-300}
WIN=${WAL_WIN_SEC:-120}
BATCH_NO=0
CUR_MODE=ASYNC
FP_ALL=""
HOT_CTL_DONE=0

# ---------------------------------------------------------------------------
# 局部 helper
# ---------------------------------------------------------------------------
# 从 WAL_EXTRA_DEFAULT 里摘掉指定键（本用例要自己给 wal_mode 定值）。
#   ⚠ 必须摘：`cluster_write_conf` 是"所有节点先写完、再逐键回读校验"，把 EXTRA_CONF 里**第一次**出现的
#     期望值与文件里**最后一个**值相比 ⇒ 同名键出现两次且值不同必然**假 FAIL**（本项目踩过 34 个假 FAIL）。
walro_strip_keys(){ local keys=" $1 " kv k out=""
  for kv in $(printf '%s' "$WAL_EXTRA_DEFAULT" | tr ',' ' '); do
    k="${kv%%=*}"
    case "$keys" in *" $k "*) continue ;; esac
    out="$out,$kv"
  done
  printf '%s' "${out#,}"; }

# DN 的 JVM pid：**必须**走 lib/wal_ext.sh 的 `wal_dn_pid`（扫 /proc/*/cmdline，只认 java 可执行
#   + cmdline 含 DataNode）。旧 pgrep 会拿到远端 `bash -c` 包装 shell ⇒ "SET 之后 PID 未变化/
#   重启后 PID 已变化"这两条场景有效性判据都会被包装 shell 的 pid 漂移污染。
walro_dn_pid(){ wal_dn_pid "$1"; }
walro_eff(){ wal_eff "$1" wal_mode | tr -d ' \r'; }
# 逐节点断言"运行期生效值 == want"；若该构建的 show configuration 不暴露 wal_mode 则整体降级 WARN
walro_eff_assert(){ local label=$1 want=$2 h e obs=0
  for h in "${DN[@]}"; do
    e=$(walro_eff "$h"); [ -n "$e" ] && obs=$(( obs + 1 ))
  done
  if [ "${obs:-0}" -eq 0 ]; then
    warn "$label：show configuration 未暴露 wal_mode ⇒ 运行期生效值不可观测，本项降级为 WARN（改用 properties 落盘值 + PID + 数据面三信号）"
    return 0
  fi
  for h in "${DN[@]}"; do
    e=$(walro_eff "$h")
    if [ -z "$e" ]; then warn "$label：$h 未暴露 wal_mode（该节点跳过）"; continue; fi
    assert_eq "$label $h（来源：show configuration，helper cmp_eff）" "$e" "$want"
  done; }
# 逐节点断言 properties 里的 wal_mode == want
walro_props_assert(){ local label=$1 want=$2 h pv
  for h in "${DN[@]}"; do
    pv=$(wal_props_get "$h" wal_mode)
    assert_eq "$label $h（来源：$DB_DIR/conf/iotdb-system.properties）" "${pv:-<无>}" "$want"
  done; }
# 该节点上"WAL 恢复链"文案出现次数（重启相的场景证据）
walro_recover_cnt(){ local h=$1 v
  v=$(sshx "$h" "grep -ahciE 'start recovering wal|successfully recover all wal nodes' $(wal_log_files) 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }

# ---------------------------------------------------------------------------
# 单相执行体：old → new（restart-only）
# ---------------------------------------------------------------------------
walro_phase(){ local new=$1 old=$2
  local resp resp2 h pv e cur i ok need rec wf got got2 fp1 fd1
  local -a pid0=()
  log "==================== 相：$old → $new（restart-only 语义） ===================="
  for h in "${DN[@]}"; do pid0+=("$(walro_dn_pid "$h")"); done
  log "  重启前 PID 基线：$(printf '%s ' "${pid0[@]:-}")"

  # (1) SET CONFIGURATION 的返回文案
  log "--- [$new] 1) SET CONFIGURATION 'wal_mode'='$new' ---"
  resp=$(wal_set wal_mode "$new")
  log "  返回原文（来源：CLI 回显，helper wal_set/cmp_set_hot；记录于 $OUT）：$(printf '%s' "$resp" | cut -c1-260)"
  assert_contains "[$new] SET 返回含 restart is required" "$resp" "restart is required"
  assert_contains "[$new] SET 文案点名 wal_mode" "$resp" "wal_mode"

  # (10) 反例控制（只做一次）：hot_reload 键的 SET 不应带 restart 提示
  if [ "${HOT_CTL_DONE:-0}" -eq 0 ]; then
    HOT_CTL_DONE=1
    resp2=$(wal_set wal_min_effective_info_ratio 0.1)
    log "  反例控制 SET 'wal_min_effective_info_ratio'='0.1'（原值重设）返回（来源：CLI 回显）：$(printf '%s' "$resp2" | cut -c1-260)"
    assert_not_contains "hot_reload 键（wal_min_effective_info_ratio）的 SET 不应要求重启" "$resp2" "restart is required"
  fi

  # (2) properties 已落盘
  log "--- [$new] 2) properties 是否已落盘新值 ---"
  walro_props_assert "[$new] 落盘核对" "$new"

  # (3) 不重启 ⇒ 运行期仍旧值
  log "--- [$new] 3) 不重启时运行期生效值必须仍是旧值 $old ---"
  for h in "${DN[@]}"; do log "  $h 生效值（来源：show configuration）：'$(walro_eff "$h")'"; done
  walro_eff_assert "[$new] 未重启时仍为旧值" "$old"

  # (4) 场景有效性：PID 未变（没重启）
  i=0; ok=1
  for h in "${DN[@]}"; do
    cur=$(walro_dn_pid "$h")
    if [ -n "$cur" ] && [ "$cur" = "${pid0[$i]:-}" ]; then :; else
      ok=0; fail "[$new] 场景无效：$h 的 DataNode PID 在 SET 之后发生变化（${pid0[$i]:-?} → ${cur:-<无>}；发生了非预期重启）"
    fi
    i=$(( i + 1 ))
  done
  [ "$ok" = "1" ] && pass "[$new] 场景成立：SET 之后各 DN PID 均未变化（确实没有重启）"

  # (5) 不重启下继续写入（旧模式仍工作）
  BATCH_NO=$(( BATCH_NO + 1 ))
  log "--- [$new] 5) 不重启下写入第 $BATCH_NO 批（证明旧模式仍可写）---"
  cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" "$BATCH_NO" || fail "[$new] 不重启相写入失败（场景无效）"
  got=$(row_sum "$(sq "select count(s1) from $DB.**;")")
  assert_eq "[$new] 写入行数（来源：CLI count($DB.**)）" "${got:-0}" "$(( DEVS * ROWS * BATCH_NO ))"

  # 【2026-10-23 修】基线必须包含刚写进去的这一批，否则第 (8) 步"重启前后一致"必然
  # 拿「旧批次的指纹」去比「新批次写完后重启的指纹」，无论产品对错都 FAIL。
  # 这就是 RC9/RC10、V1/V2 上稳定复现的 4 条「重启前后 count/sum / d1 全序列 不一致」的根因。
  FP_ALL=$(cmp_fp_tree "$DB")
  FP_D1=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")
  log "  [$new] 重启前基线指纹已刷新（含第 $BATCH_NO 批）：$FP_ALL"

  # (6)(7)(8)(9) 重启 → 新值生效 → 数据面
  log "--- [$new] 6) 重启（cluster_stop → cluster_start；不 clean，数据要跨重启比对）---"
  cluster_stop
  need=0
  for h in "${DN[@]}"; do pv=$(wal_props_get "$h" wal_mode); [ "$pv" = "$new" ] || need=1; done
  if [ "$need" = "1" ]; then
    warn "[$new] 重启前有节点的 properties 里 wal_mode 不是 $new（可能被框架启动脚本还原）⇒ 以同值重写后再起（不改变本用例语义）"
    EXTRA_CONF="$(walro_strip_keys 'wal_mode'),wal_mode=$new,$CMP_EXTRA_WRITE" cluster_write_conf
  fi
  cluster_start
  i=0; ok=1
  for h in "${DN[@]}"; do
    cur=$(walro_dn_pid "$h")
    rec=$(walro_recover_cnt "$h")
    log "  $h 重启后 PID=${cur:-<无>}；WAL 恢复链文案命中=$rec（来源：$(wal_log_files)）"
    if [ -n "$cur" ] && [ "$cur" != "${pid0[$i]:-}" ]; then :; else
      ok=0; fail "[$new] 场景无效：$h 的 DataNode PID 未变化（${pid0[$i]:-?} → ${cur:-<无>}；重启未发生）"
    fi
    [ "${rec:-0}" -ge 1 ] || warn "[$new] $h 未找到 WAL 恢复文案（来源：WALRecoverManager.java:75/144；只 WARN，数据面单独判定）"
    i=$(( i + 1 ))
  done
  [ "$ok" = "1" ] && pass "[$new] 场景成立：重启确实发生（各 DN PID 均已变化）"

  log "--- [$new] 7) 重启后新值是否生效（逐节点）---"
  walro_eff_assert "[$new] 重启后生效值" "$new"
  walro_props_assert "[$new] 重启后落盘值" "$new"

  log "--- [$new] 8) 重启后数据不丢（硬判据）---"
  wait_scalar_tree "select count(s1) from $DB.d1 order by time;" "$(( ROWS * BATCH_NO ))" "$WAL_REPLAY_WIN_SEC" "[$new] 重启后 $DB.d1 行数"
  got2=$(row_sum "$(sq "select count(s1) from $DB.**;")")
  assert_eq "[$new] 重启后总行数" "${got2:-0}" "$(( DEVS * ROWS * BATCH_NO ))"
  fp1=$(cmp_fp_tree "$DB")
  fd1=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")
  cmp_assert_same "[$new] 重启前后 count/sum" "$FP_ALL" "$fp1"
  cmp_assert_same "[$new] 重启前后 $DB.d1 全序列" "$FP_D1" "$fd1"
  FP_ALL=$fp1
  FP_D1=$fd1

  # (9) 重启后 WAL 仍在
  wf=$(wal_sum_over_dn wal_file_cnt)
  log "--- [$new] 9) 重启后 WAL 面：files=$wf bytes=$(wal_sum_over_dn wal_dir_bytes)B 逐副本=$(wal_per_node) ---"
  [ "${wf:-0}" -ge 1 ] && pass "[$new] 重启后 WAL 目录仍有 ${wf} 个 .wal（$new 下 WAL 应启用）" \
    || fail "[$new] 重启后 WAL 文件数=0（$new 不是 DISABLE，WAL 应处于启用状态）"

  CUR_MODE=$new
  return 0; }

# ===========================================================================
# 起始相：ASYNC（写 conf + 起集群；restart 参数不能热切）
# ===========================================================================
log "=== W-03 wal_mode restart-only：库 $DB；起始模式 ASYNC ==="
log "--- 起始相：EXTRA_CONF = (WAL_EXTRA_DEFAULT 去掉 wal_mode) + wal_mode=ASYNC + 关三类合并 ---"
EXTRA_CONF="$(walro_strip_keys 'wal_mode'),wal_mode=ASYNC,$CMP_EXTRA_WRITE" cmp_cluster_prepare
walro_props_assert "起始相落盘核对" "ASYNC"
walro_eff_assert "起始相运行期生效值" "ASYNC"

cmp_make_tree_db "$DB" "$DEVS"
BATCH_NO=1
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" "$BATCH_NO" || fail "起始相写入失败（场景无效）"
got=$(row_sum "$(sq "select count(s1) from $DB.**;")")
assert_eq "起始相写入行数（来源：CLI count($DB.**)）" "${got:-0}" "$(( DEVS * ROWS ))"
FP_ALL=$(cmp_fp_tree "$DB")
FP_D1=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")
log "  起始指纹：$FP_ALL"
wf=$(wal_sum_over_dn wal_file_cnt)
log "  起始相 WAL 面：files=$wf（来源：<dn_wal_dirs>/**/*.wal）"
[ "${wf:-0}" -ge 1 ] && pass "起始相：WAL 目录确有 ${wf} 个 .wal" || fail "起始相：WAL 文件数=0（场景无效）"
wal_metrics_dump "${DN[0]}"

# ===========================================================================
# 相 1：ASYNC → SYNC ；相 2：SYNC → ASYNC（两相各一次重启）
# ===========================================================================
walro_phase SYNC  ASYNC
walro_phase ASYNC SYNC

log "--- 判读 ---"
log "  相 1（ASYNC→SYNC）：SET 返回含 restart 提示 + properties 已落盘 SYNC + 不重启时生效值仍为 ASYNC"
log '                      + 重启后生效值变为 SYNC ⇒ 证明 wal_mode 是 restart-only，且「落盘 ≠ 生效」。'
log "  相 2（SYNC→ASYNC）：同一套判据反向再来一次 ⇒ 排除"单向偶然"。"
log "  反例控制：hot_reload 键（wal_min_effective_info_ratio）原值重设不带 restart 提示 ⇒ 提示是按 effectiveMode 逐键给的。"
log "  最终模式：$CUR_MODE；累计写入批数：$BATCH_NO"

# ===========================================================================
# 收尾三件套
# ===========================================================================
log "--- 收尾三件套 ---"
wal_install_err_pat
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance in ConsensusGroup|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader'
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
