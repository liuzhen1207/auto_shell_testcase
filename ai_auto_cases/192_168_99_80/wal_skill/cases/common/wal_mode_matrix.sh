#!/bin/bash
# ============================================================================
# W-01 wal_mode 模式矩阵：ASYNC 与 SYNC 两相各自「写入正确性 + WAL 目录确有文件 + 重启后数据不丢」
#                          并对两相的耗时/文件数/字节数做对照（**耗时只 WARN**）
#
# 【用例】W-01（集合 mode；树模型；库名 root.walmode（ASYNC 相）/ root.walmode_sync（SYNC 相））
#
# 【覆盖需求】
#   · docs/req_sources/design_extract.md
#       §4.1 wal_mode 与 fsync 时机：SYNC=同步提交（写返回即已刷盘）、ASYNC=异步提交（不等刷盘即返回）、
#            DISABLE=关闭 WAL（**本环境 IoTConsensus 下不被允许**，见 W-02）
#       §4.3 重启恢复流程（WAL Node 粒度恢复）；§4.4 文档未给"恢复完成"信号
#       §8.2 TP-10（SYNC 写返回即刷盘）/ TP-11（ASYNC 不等刷盘）
#   · docs/req_sources/source_grounding.md
#       §1.2/§1.4 `wal_mode` 是 **restart**（模板 `# effectiveMode: restart`）⇒ 两相必须"写 conf + 起集群"
#            —— IoTDBDescriptor.loadWALHotModifiedProps 不含 wal_mode（:2185-2275）
#       §5.4 SYNC/ASYNC 的差异：攒批等待时长（wal_async_mode_fsync_delay_in_ms=1000 /
#            wal_sync_mode_fsync_delay_in_ms=3，均 hot_reload）+ 写请求是否 waitForResult
#       §3.4 文件名正则 `_<versionId>-<startSearchIndex>-<statusCode>.wal`（WALFileUtils.java:65-83）
#       §4.1 magic = `V3-WAL`/`V2-WAL`（WALFileVersion.java:29-32；**不是** "WAL-V2"）
#       §8.2 恢复文案：`Start recovering wal.`(WALRecoverManager.java:75) /
#            `Successfully recover all wal nodes.`(:144) —— INFO，默认级别会落盘
#       §9 权威指标 `file_count{name="wal"}` / `file_size{name="wal"}`（WalFileMetrics.java:35-48）
#   · feature_extract.md B（WAL 队列内存）：本用例只借用"写请求是否阻塞等 fsync"这一语义差异，
#     不做队列内存判据（那是 W-18）。
#
# 【判据】（双信号/多信号；每条注明证据来源）
#   每相都做（硬）：
#     1) 配置生效：逐节点 properties 的 wal_mode == 本相模式（来源：<DB_DIR>/conf/iotdb-system.properties）
#        且 show configuration 可读时其生效值也必须一致（不可读只 WARN，见"notes"）
#     2) 场景有效性：写入行数 = WAL_DEVS×WAL_ROWS×(WAL_BATCHES+1)（来源：CLI count；不足 ⇒ fail「场景无效」）
#     3) 场景有效性：WAL 目录确有 `.wal` 文件、字节>0、文件名全部合规（来源：<dn_wal_dirs>/**/*.wal）
#        并以 `file_count{name="wal"}` 指标交叉验证（指标缺失只 WARN）
#     4) 重启确实发生（场景有效性，硬）：重启后各 DN 的 DataNode 进程 PID 与重启前不同
#     5) WAL 恢复链（硬）：重启后各 DN 日志出现 `Start recovering wal.` 或 `Successfully recover all wal nodes.`
#        （来源：<DB_DIR>/logs/log_datanode_all.log + log_datanode_wal.log）
#     6) 重启后数据不丢（硬，最终判据）：count/sum 与重启前完全一致 + d1 全序列指纹一致 + 行数一致
#        ⚠ 只断言**优雅重启**（stop→start）不丢数据；掉电（kill -9）场景见 W-04。
#   两相对照（**耗时只 WARN**）：
#     7) 记录并对照 写入耗时 / WAL 文件数 / WAL 总字节（来源：本用例内 date +%s 差值；两相各自的 find 计数）
#     8) SYNC 耗时 > ASYNC 耗时的 2 倍 ⇒ **只 WARN**（SYNC 语义就是等 fsync，性能不作为门禁；
#        且单机噪声大、写入量小，本阈值只是提示）
#
# 【注意事项】
#   ⚠ 本脚本**未在集群实跑**（harness 阶段；99.80 正在跑合并长回归，禁止任何启停集群动作）。只做了 `bash -n`。
#   ⚠ 写配置一律 `EXTRA_CONF="..." cmp_cluster_prepare`（**单条命令的前缀环境变量**），
#     两相各自显式追加 `wal_mode=ASYNC` / `wal_mode=SYNC`；追加前用 walmode_strip_keys 摘掉
#     WAL_EXTRA_DEFAULT 里的同名键——cluster_write_conf 逐键回读时把"第一次出现的期望值"与"最后落盘的值"
#     相比，同名键带不同值会产生**假 FAIL**（本项目踩过 34 个假 FAIL）。
#     wal_mode 是 restart 参数 ⇒ 只能通过"写 conf + 起集群"切换，不能用 SET CONFIGURATION（见 W-03）。
#   ⚠ harness 侧缺口（本文件不改 lib/conf）：lib/common.sh 的 cluster_set_conf 引用 TTL 专用变量
#     TTL_CHECK_INTERVAL_MS / MAX_EXPIRED_TIME_MS / EXPIRED_DATA_RATIO，而 WAL 的 conf/env.conf 未定义它们；
#     `set -u` 下会让"写配置"这步直接终止用例 ⇒ 本文件在 cmp_cluster_prepare 之前给出安全默认值。
#
#   首轮实跑 watch list（最关键 5 条）：
#     ① 两相的 `wal_mode` 是否真的写进去了：cluster_write_conf 会逐键回读校验，但要盯打印出的
#        properties 值（写错模式会让两相对照失去意义）。
#     ② `show configuration`（table 方言）是否暴露 wal_mode：不暴露时第 1 条判据降级为 WARN + PID 证据。
#     ③ 重启后各 DN 是否真的打了恢复文案（`Start recovering wal.` / `Successfully recover all wal nodes.`）；
#        若一个都没有 ⇒ 首跑要确认日志文件名/级别，而不是直接当产品问题。
#     ④ SYNC 与 ASYNC 的写入耗时差：本用例写入量小（默认 6×300×4），差值可能被 CLI 启动开销淹没 ⇒ 只 WARN 是对的。
#     ⑤ 优雅重启后 WAL 目录是否仍有活动文件（`delete_wal_files_period_in_ms`=20s 只删 status=0 的旧文件）。
#
# 用法： bash cases/common/wal_mode_matrix.sh [--consensus IoTConsensus|IoTConsensusV2]
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
cmp_case_init "wal_mode_matrix_${DATA_CONSENSUS}"

DB_A=root.walmode
DB_B=root.walmode_sync
DEVS=${WAL_DEVS:-6}
ROWS=${WAL_ROWS:-300}
BATCHES=${WAL_BATCHES:-3}
WIN=${WAL_WIN_SEC:-120}
EXPECT=$(( DEVS * ROWS * (BATCHES + 1) ))
A_SEC=0; A_FILES=0; A_BYTES=0; A_METRIC=0
S_SEC=0; S_FILES=0; S_BYTES=0; S_METRIC=0

# ---------------------------------------------------------------------------
# 局部 helper（只补 wal_ext.sh 没有的口径）
# ---------------------------------------------------------------------------
# 从 WAL_EXTRA_DEFAULT 里摘掉指定键（本用例要自己给 wal_mode 定值）。
#   ⚠ 必须摘：`cluster_write_conf` 是"所有节点先写完、再逐键回读校验"，把 EXTRA_CONF 里**第一次**出现的
#     期望值与文件里**最后一个**值相比 ⇒ 同名键出现两次且值不同必然**假 FAIL**（本项目踩过 34 个假 FAIL）。
walmode_strip_keys(){ local keys=" $1 " kv k out=""
  for kv in $(printf '%s' "$WAL_EXTRA_DEFAULT" | tr ',' ' '); do
    k="${kv%%=*}"
    case "$keys" in *" $k "*) continue ;; esac
    out="$out,$kv"
  done
  printf '%s' "${out#,}"; }

walmode_write_unflushed(){ local db=$1 devs=$2 rows=$3 b=${4:-1} d k vals ts start
  start=$(( ($(date +%s) - 3600) * 1000 + b * 1000000 ))
  for ((d=1; d<=devs; d++)); do
    vals=""
    for ((k=0; k<rows; k++)); do
      ts=$(( start + k * 10 ))
      vals="$vals($ts,$((k+b))),"
      if [ $(( (k+1) % 500 )) -eq 0 ]; then
        sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null || return 1
        vals=""
      fi
    done
    [ -n "$vals" ] && { sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null || return 1; }
  done; return 0; }

walmode_names(){ local h=$1
  sshx "$h" "find $(wal_roots_arg "$h") -name '*.wal' -printf '%f\n' 2>/dev/null" 2>/dev/null | tr -d '\r'; }
walmode_bad_names(){ local h=$1
  walmode_names "$h" | grep -cvE '^_[0-9]+-[0-9]+-[01]\.wal(\.enc)?$'; }
walmode_magic_cnt(){ local h=$1 v
  v=$(sshx "$h" "c=0; for f in \$(find $(wal_roots_arg "$h") -name '*.wal' 2>/dev/null); do grep -aqE 'V[23]-WAL' \"\$f\" && c=\$((c+1)); done; echo \$c" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
walmode_wait_files(){ local want=$1 win=$2 n=0
  local dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    n=$(wal_sum_over_dn wal_file_cnt)
    [ "${n:-0}" -ge "$want" ] && { echo "$n"; return 0; }
    sleep 3
  done
  echo "${n:-0}"; return 1; }
# DN 的 JVM pid：**必须**走 lib/wal_ext.sh 的 `wal_dn_pid`（扫 /proc/*/cmdline，只认 java 可执行
#   + cmdline 含 DataNode）。旧 pgrep 会拿到远端 `bash -c` 包装 shell ⇒ "重启前后 PID 是否变化"
#   这一场景有效性判据会随包装 shell 的 pid 漂移（假"重启发生"/假"未变化"）。
walmode_dn_pid(){ wal_dn_pid "$1"; }
# 该节点上"WAL 恢复链"文案的出现次数（逐节点断言用）
walmode_recover_cnt(){ local h=$1 v
  v=$(sshx "$h" "grep -ahciE 'start recovering wal|successfully recover all wal nodes' $(wal_log_files) 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }

# ---------------------------------------------------------------------------
# 单相执行体：写模式 + 起集群 + 写入 + WAL 面 + 重启 + 数据面
#   结果通过全局变量回传（log 会写 stdout，所以不用 echo 返回值）
# ---------------------------------------------------------------------------
walmode_phase(){ local mode=$1 db=$2
  local t0 t1 sec wf wb wm wbad mcnt got e pv rec cur i
  local -a pid0=()
  log "==================== 相 $mode（库 $db） ===================="
  log "--- 集群准备：EXTRA_CONF = (WAL_EXTRA_DEFAULT 去掉 wal_mode) + wal_mode=$mode + 关三类合并 ---"
  EXTRA_CONF="$(walmode_strip_keys 'wal_mode'),wal_mode=$mode,$CMP_EXTRA_WRITE" cmp_cluster_prepare

  # (1) 配置生效（场景有效性：写错模式则两相对照无意义）
  for h in "${DN[@]}"; do
    pv=$(wal_props_get "$h" wal_mode)
    assert_eq "配置落盘核对 $h（来源：$DB_DIR/conf/iotdb-system.properties）" "${pv:-<无>}" "$mode"
  done
  for h in "${DN[@]}"; do
    e=$(wal_eff "$h" wal_mode)
    if [ -n "$e" ]; then
      assert_eq "运行期生效值 $h（来源：show configuration，helper wal_eff）" "$e" "$mode"
    else
      warn "$h 的 show configuration 未暴露 wal_mode ⇒ 本相运行期生效值不可观测（只 WARN；配置落盘值已单独断言）"
    fi
  done

  # (2)(3) 写入 + WAL 面
  cmp_make_tree_db "$db" "$DEVS"
  t0=$(date +%s)
  for i in $(seq 1 "$BATCHES"); do
    cmp_write_tree_batch "$db" "$DEVS" "$ROWS" "$i" || fail "$mode 相：第 $i 批写入失败（场景无效）"
  done
  walmode_write_unflushed "$db" "$DEVS" "$ROWS" "$((BATCHES+1))" || fail "$mode 相：未 flush 批次写入失败（场景无效）"
  t1=$(date +%s)
  sec=$(( t1 - t0 ))
  got=$(row_sum "$(sq "select count(s1) from $db.**;")")
  log "  [$mode] 写入耗时=${sec}s（来源：本用例内 date +%s 差值；含 CLI 启动开销，**只作对照不作门禁**）"
  log "  [$mode] 写入行数=${got:-0} / 期望 $EXPECT（来源：CLI 'select count(s1) from $db.**'，原始输出在 $OUT）"
  assert_eq "[$mode] 写入行数（场景有效性）" "${got:-0}" "$EXPECT"

  walmode_wait_files 1 "$WIN" >/dev/null
  wf=$(wal_sum_over_dn wal_file_cnt)
  wb=$(wal_sum_over_dn wal_dir_bytes)
  wm=0; wbad=0
  for h in "${DN[@]}"; do wm=$(( wm + $(walmode_magic_cnt "$h") )); wbad=$(( wbad + $(walmode_bad_names "$h") )); done
  mcnt=$(wal_metric_sum_over_dn wal_metric_file_cnt)
  log "  [$mode] WAL 面：files=$wf bytes=${wb}B magic=$wm 命名不合规=$wbad 指标file_count=$mcnt（来源：<dn_wal_dirs>/**/*.wal + http://<dn>:$DN_METRIC_PORT/metrics）"
  log "  [$mode] 文件清单（来源：wal_ls，${DN[0]}）：$(wal_ls "${DN[0]}" | tr '\n' ' ' | cut -c1-260)"
  [ "${wf:-0}" -ge 1 ] && pass "[$mode] 场景成立：WAL 目录有 ${wf} 个 .wal（来源：<dn_wal_dirs>）" \
    || fail "[$mode] 场景无效：写入后 WAL 文件数=0（来源：<dn_wal_dirs>/**/*.wal）"
  [ "${wb:-0}" -gt 0 ] && pass "[$mode] 场景成立：WAL 总字节=${wb}B > 0" \
    || fail "[$mode] 场景无效：WAL 总字节=0"
  [ "${wbad:-0}" -eq 0 ] && pass "[$mode] 文件名全部合规（来源：WALFileUtils.java:65-83）" \
    || fail "[$mode] 有 ${wbad} 个 .wal 文件名不合规（期望 ^_[0-9]+-[0-9]+-[01]\\.wal$）"
  [ "${mcnt:-0}" -gt 0 ] && pass "[$mode] 指标交叉验证 file_count{name=wal}=$mcnt" \
    || warn "[$mode] 指标 file_count{name=wal} 为 0/缺失（只 WARN，指标门禁归 W-23）"

  fp0=$(cmp_fp_tree "$db")
  fd0=$(cmp_fingerprint tree "select s1 from $db.d1 order by time")
  for h in "${DN[@]}"; do pid0+=("$(walmode_dn_pid "$h")"); done
  log "  [$mode] 重启前：count/sum=$fp0（cmp_fp_tree）；PID=$(printf '%s ' "${pid0[@]:-}")"

  # (4)(5)(6) 优雅重启 → WAL 恢复链 → 数据面
  log "--- [$mode] 优雅重启（cluster_stop → cluster_start；不做 clean，conf 里仍是 $mode）---"
  wal_restart_all
  wal_wait_replay "$db" 60 >/dev/null 2>&1 || true
  for h in "${DN[@]}"; do
    rec=$(walmode_recover_cnt "$h")
    log "  [$mode] $h 恢复链文案命中=$rec（来源：$(wal_log_files)）"
    [ "${rec:-0}" -ge 1 ] && pass "[$mode] $h 出现 WAL 恢复文案（来源：WALRecoverManager.java:75/144）" \
      || fail "[$mode] $h 未出现 'Start recovering wal.' 或 'Successfully recover all wal nodes.'（来源：$(wal_log_files)）"
  done
  i=0
  for h in "${DN[@]}"; do
    cur=$(walmode_dn_pid "$h")
    if [ -n "$cur" ] && [ "$cur" != "${pid0[$i]:-}" ]; then
      pass "[$mode] 重启确实发生：$h PID ${pid0[$i]:-?} → $cur"
    else
      fail "[$mode] 场景无效：$h 的 DataNode PID 未变化（PID=${cur:-<无>}；重启未发生）"
    fi
    i=$(( i + 1 ))
  done

  wait_scalar_tree "select count(s1) from $db.d1 order by time;" "$(( ROWS * (BATCHES + 1) ))" "$WAL_REPLAY_WIN_SEC" "[$mode] 重启后 $db.d1 行数"
  # 重启后模式核对（防止"框架把 conf 还原"导致本相实际跑的是另一种模式 ⇒ 两相对照失去意义）
  for h in "${DN[@]}"; do
    e=$(wal_eff "$h" wal_mode)
    pv=$(wal_props_get "$h" wal_mode)
    log "  [$mode] $h 重启后：show configuration='${e:-<未暴露>}' / properties='${pv:-<无>}'"
    if [ -n "$e" ]; then
      assert_eq "[$mode] 重启后生效值 $h（来源：cmp_eff）" "$e" "$mode"
    else
      warn "[$mode] $h 未暴露 wal_mode ⇒ 重启后生效值不可观测（只 WARN）"
    fi
  done
  got2=$(row_sum "$(sq "select count(s1) from $db.**;")")
  assert_eq "[$mode] 重启后总行数（不丢数据，硬判据）" "${got2:-0}" "$EXPECT"
  fp1=$(cmp_fp_tree "$db")
  fd1=$(cmp_fingerprint tree "select s1 from $db.d1 order by time")
  cmp_assert_same "[$mode] 重启前后 count/sum（cmp_fp_tree）" "$fp0" "$fp1"
  cmp_assert_same "[$mode] 重启前后 $db.d1 全序列（cmp_fingerprint）" "$fd0" "$fd1"

  wf1=$(wal_sum_over_dn wal_file_cnt)
  log "  [$mode] 重启后 WAL 面：files=$wf1 bytes=$(wal_sum_over_dn wal_dir_bytes)B 逐副本=$(wal_per_node)"
  [ "${wf1:-0}" -ge 1 ] && pass "[$mode] 重启后 WAL 目录仍有文件（WAL 仍启用）" \
    || fail "[$mode] 重启后 WAL 文件数=0（$mode 下 WAL 应处于启用状态）"
  wal_metrics_dump "${DN[0]}"

  # 回传本相读数
  P_SEC=$sec; P_FILES=$wf; P_BYTES=$wb; P_METRIC=$mcnt; return 0; }

# ---------------------------------------------------------------------------
# A 相：ASYNC
# ---------------------------------------------------------------------------
walmode_phase ASYNC "$DB_A"
A_SEC=$P_SEC; A_FILES=$P_FILES; A_BYTES=$P_BYTES; A_METRIC=$P_METRIC
log "  A 相（ASYNC）读数：耗时=${A_SEC}s files=$A_FILES bytes=${A_BYTES}B 指标=$A_METRIC"

# ---------------------------------------------------------------------------
# B 相：SYNC
# ---------------------------------------------------------------------------
walmode_phase SYNC "$DB_B"
S_SEC=$P_SEC; S_FILES=$P_FILES; S_BYTES=$P_BYTES; S_METRIC=$P_METRIC
log "  B 相（SYNC）读数：耗时=${S_SEC}s files=$S_FILES bytes=${S_BYTES}B 指标=$S_METRIC"

# ---------------------------------------------------------------------------
# 两相对照（耗时只 WARN）
# ---------------------------------------------------------------------------
log "--- 两相对照（来源：本用例内 date +%s 差值 / 各 DN 的 find 计数 / 指标 file_count{name=wal}）---"
log "  写入耗时：ASYNC=${A_SEC}s，SYNC=${S_SEC}s"
log "  WAL 文件数：ASYNC=$A_FILES，SYNC=$S_FILES（指标口径：ASYNC=$A_METRIC，SYNC=$S_METRIC）"
log "  WAL 总字节：ASYNC=${A_BYTES}B，SYNC=${S_BYTES}B"
log "  两相配置差异（来源：conf/env.conf）：wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS}ms vs wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS}ms"
if [ "${A_SEC:-0}" -gt 0 ]; then
  if [ "${S_SEC:-0}" -gt $(( A_SEC * 2 )) ]; then
    warn "SYNC 写入耗时 ${S_SEC}s > 2×ASYNC ${A_SEC}s（**只 WARN**：SYNC 语义本就是等 fsync，性能不作门禁；写入量小、CLI 开销占比高）"
  else
    pass "SYNC/ASYNC 写入耗时为 ${S_SEC}s/${A_SEC}s（未出现 2 倍以上劣化；耗时类只 WARN）"
  fi
else
  warn "ASYNC 相耗时读数为 0s（时间戳精度/极快返回）⇒ 跳过耗时对照，只记录读数"
fi
[ "${A_FILES:-0}" -ge 1 ] && [ "${S_FILES:-0}" -ge 1 ] \
  && pass "两相 WAL 目录均有文件（ASYNC=$A_FILES，SYNC=$S_FILES）" \
  || fail "有相位的 WAL 文件数为 0（ASYNC=$A_FILES，SYNC=$S_FILES）——场景无效"
[ "${A_BYTES:-0}" -gt 0 ] && [ "${S_BYTES:-0}" -gt 0 ] \
  && pass "两相 WAL 总字节均 > 0（ASYNC=${A_BYTES}B，SYNC=${S_BYTES}B）" \
  || fail "有相位的 WAL 总字节为 0"

# ---------------------------------------------------------------------------
# 收尾三件套
# ---------------------------------------------------------------------------
log "--- 收尾三件套 ---"
wal_install_err_pat
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB_B"
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance in ConsensusGroup|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader'
post_checks "select count(s1) from $DB_B.d1 order by time;" tree
cmp_case_finish "" tree ""
