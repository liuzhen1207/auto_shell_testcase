#!/bin/bash
# ============================================================================
# W-22 参数热加载语义：逐个 SET 19 个 WAL 键 → 记录返回文案（哪些 `restart is required`）
#      → 与源码 **restart-only 清单**核对 → 不重启值不变 / 重启后生效 → 非 SYSTEM 用户 SET 必须被拒
#
# 【用例】W-22（集合 param；树模型；库名 root.walhot）
#
# 【覆盖需求】
#   · cases/cases.tsv W-22：逐个 `SET CONFIGURATION` 19 个 WAL 键；restart-only = `wal_mode`、
#     `max_wal_nodes_num`、`wal_buffer_size_in_byte`、`wal_entry_size_limit_in_byte`、
#     `wal_file_list_cache_enabled`、`wal_cache_shrink_clear_enabled`、`dn_wal_dirs`、
#     `wal_buffer_queue_proportion`；其余 hot_reload；不重启时运行期值不变、重启后生效；
#     非 SYSTEM 用户 SET 必须被拒；**不要**用 `iot_consensus_cache_window_time_in_ms`（全仓无消费者）
#     与 `wal_cache_shrink_clear_enabled`（不在模板、SET 会被丢弃）构造**场景差异**（探测其 SET 返回文案是允许的）。
#   · docs/req_sources/source_grounding.md（**判据完全按它**）：
#       §1.2 19 项清单（17 个 WAL 主键 + `iot_consensus_throttle_threshold_in_byte`（已废弃别名）
#            + `iot_consensus_cache_window_time_in_ms`）；§1.4 模板 `# effectiveMode:` 逐键原文。
#       §1.1 `SET CONFIGURATION` 的 restart 提示生成：ConfigurationFileUtils.java:102（EFFECTIVE_MODE_PREFIX）、
#            :665-672（解析 HOT_RELOAD / RESTART / FIRST_START）、:384-390（模板里不存在的键被丢弃）、
#            ConfigManager.java:1927-1932（**只对本次请求里的 RESTART 键**加 restartRequiredKeys）。
#       §1.5 `wal_cache_shrink_clear_enabled` 不在模板 ⇒ SET 被丢弃；`iot_consensus_cache_window_time_in_ms`
#            全仓无消费者 ⇒ 不构造行为差异（本用例只探测它的 SET 文案 + 还原）。
#       §1.3 `iot_consensus_throttle_threshold_in_byte` 是废弃别名（读到即打 WARN 并优先采用）
#            ⇒ 本用例只探测文案、**不写进 conf 组合**（避免制造无谓 WARN 污染收尾日志扫描）。
#       §1.2-8/§12-A.8：`wal_cache_shrink_clear_enabled` 只能"改文件 + 重启"生效（SET 无效）。
#   · docs/DECISIONS.md §3.1（源码印证后的 restart-only 清单）、§5（配置修改需系统管理员权限 ⇒
#     非 SYSTEM 用户 SET 必须被拒；无权限时应"明确拒绝"，不搞静默）。
#
# 【判据（FAIL 只来自：restart-only 文案错、hot 键被误判为 restart-only、hot 键不生效、
#         被丢弃键竟然生效、非 SYSTEM 用户改配置成功、重启后没生效、数据面不一致、场景无效）】
#   相 0（基线）：合法组合起来 + 建库写数 + 逐键记录"原值"（运行期值优先，其次落盘值，最后文档默认）。
#   相 1（探测，19 键逐个 SET，**不重启**）：
#     1) 场景有效性（硬）：探测到的键数 == 19（与 §1.2 清单一致）
#     2) restart-only（模板内有 7 键）：返回文案必须含 `restart is required` **且点名该键**；且不重启时运行期值仍为原值
#     3) hot_reload（其余 10 键）：返回文案**不得**含 `restart is required`；且不重启时运行期值即为新值
#     4) `wal_cache_shrink_clear_enabled`（不在模板）：SET 后 properties 值**不得变化**（被丢弃，§1.5/§12-A.8）；
#        若它反倒给了 restart 提示 ⇒ WARN 记录（与"不在模板"的源码事实矛盾）
#     5) `iot_consensus_throttle_threshold_in_byte`（废弃别名）：只记录返回文案（可能被丢弃）
#     6) `dn_wal_dirs`：只用"当前值"做 SET 探测（返回文案必须是 restart 提示）；落地/多目录行为由 W-24 覆盖
#     7) 每个探测过的键都**还原原值**（并记录还原后的运行期值）
#   相 1.5（权限，硬）：建非 SYSTEM 用户 → 正向前置（能登录并查询）→ 该用户 SET 必须"未生效"
#        （报权限错 ⇒ PASS；未报错也没生效 ⇒ PASS + WARN 观察项；**生效了 ⇒ FAIL**，并立刻还原）
#   相 2（restart-only「重启后生效」，硬）：把 7 个 restart 键写进 conf（`wal_cache_shrink_clear_enabled`
#        的 SET 会被丢弃 ⇒ 必须直接写文件）→ 停 → 起（**不 clean**）→ 逐键运行期值 == 新值 + 落盘 == 新值
#        + 重启确实发生（PID 变化）+ 数据面指纹不变 + WAL 目录仍有 .wal
#   相 3（还原，硬）：把 18 键写回原值 → 停 → 起 → 逐键运行期值回到原值 + 数据面指纹不变 + 能继续写入
#   收尾三件套：sync lag / 逐 DN 停机副本一致 / 日志扫描（本用例不装 WAL 建议正则）
#
# 【注意事项】
#   ⚠ 本脚本**未在集群实跑**（harness 阶段；99.80 正在跑合并长回归，禁止任何启停集群动作）。只做了 `bash -n`。
#   ⚠ 相 2/3 用 `cluster_write_conf` 直接写 conf（**不是** SET）：因为 `wal_cache_shrink_clear_enabled`
#     不在模板、SET 会被丢弃，只有"改文件 + 重启"能生效；这样 7 个 restart 键可以**一次重启**验证完。
#   ⚠ 同名键不能出现两次（cluster_write_conf 逐键回读会判假 FAIL）⇒ w22_strip_from 先把要覆盖的键摘掉。
#   ⚠ 相 1 的 SET 会**真的写进 properties**（历史经验），所以每个键探测后立刻还原；
#     相 2/3 又用 W22_ORIG 全量重写一遍，保证 conf 内容与运行期值确定。
#   ⚠ harness 缺口（本文件不改 lib/conf）：lib/common.sh 的 cluster_set_conf 引用 TTL 专用变量
#     TTL_CHECK_INTERVAL_MS / MAX_EXPIRED_TIME_MS / EXPIRED_DATA_RATIO，而 WAL 的 conf/env.conf 未定义它们；
#     `set -u` 下会让"写配置"整步终止 ⇒ 本文件在 cmp_cluster_prepare 之前给出安全默认值。
#
#   首轮实跑 watch list（最关键 4 条）：
#     ① **权限相是最可能误判的一条**：源码里 `SET CONFIGURATION` 的鉴权取决于模板里该键有没有
#        `# Privilege:` 标注（CRUD skill 实测：无标注 ⇒ neededPrivileges 为空 ⇒ 直接放行）。
#        本用例的判法是"是否**生效**"：报权限错 ⇒ PASS；没报错也没生效 ⇒ PASS+WARN；
#        **生效了** ⇒ FAIL。首轮请把非管理员 SET 的原始回显与落盘值一起看。
#     ② `show configuration`（table 方言）是否暴露这 19 个键：不暴露的键其"不重启值不变 / 重启后生效"
#        降级 WARN（靠 properties + 重启行为兜底）；首轮把打印出来的逐键值看一遍。
#     ③ `wal_min_effective_info_ratio` / `wal_throttle_threshold_in_byte` 等 hot 键 SET 后是否**立即**生效
#        （模板标 hot_reload；若实测要重启才是真发现，会直接 FAIL）。
#     ④ `wal_cache_shrink_clear_enabled`（不在模板）的 SET 返回文案：预期"被丢弃"（properties 不变）。
#        若返回 restart 提示，说明该键其实在模板里（与 source_grounding §1.5 不符）⇒ 只 WARN + 记录。
#
# 用法： bash cases/common/wal_param_hotload.sh [--consensus IoTConsensus|IoTConsensusV2]
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
cmp_case_init "wal_param_hotload_${DATA_CONSENSUS}"

DB=root.walhot
DEVS=${WAL_DEVS:-4}
ROWS=${WAL_ROWS:-200}
TOTAL=$(( ${#CN[@]} + ${#DN[@]} ))
W22_USER=${W22_USER:-walhotu}
W22_PW=${W22_PW:-WalHotPw@2021}

# ---------------------------------------------------------------------------
# 19 个 WAL 键（§1.2 全清单）与探测值；探测值都取"不同但无害"的合法值
# ---------------------------------------------------------------------------
ALL_KS=(wal_mode max_wal_nodes_num wal_async_mode_fsync_delay_in_ms wal_sync_mode_fsync_delay_in_ms \
        wal_buffer_size_in_byte wal_entry_size_limit_in_byte wal_file_list_cache_enabled \
        wal_cache_shrink_clear_enabled wal_file_size_threshold_in_byte wal_min_effective_info_ratio \
        wal_memtable_snapshot_threshold_in_byte max_wal_memtable_snapshot_num delete_wal_files_period_in_ms \
        wal_throttle_threshold_in_byte iot_consensus_throttle_threshold_in_byte \
        iot_consensus_cache_window_time_in_ms enable_wal_compression dn_wal_dirs wal_buffer_queue_proportion)
ALL_VS=(SYNC 2 800 5 16777216 1048576 false \
        false 20971520 0.2 \
        4194304 2 30000 \
        107374182400 107374182400 \
        20000 false dn_wal_dirs 0.05)
# 源码 restart-only 清单（§1.2/§1.4；模板内有 7 个 + 不在模板的 wal_cache_shrink_clear_enabled）
RESTART_INTPL="wal_mode max_wal_nodes_num wal_buffer_size_in_byte wal_entry_size_limit_in_byte wal_file_list_cache_enabled dn_wal_dirs wal_buffer_queue_proportion"
RESTART_NOTPL="wal_cache_shrink_clear_enabled"
DEPRECATED_KEY="iot_consensus_throttle_threshold_in_byte"
# 原值组合（18 键；不含 dn_wal_dirs 之外的"不确定项"？—— dn_wal_dirs 用默认值，废弃别名键不写，
# 以免触发 §1.3 的废弃 WARN 污染收尾日志扫描）
W22_ORIG="wal_mode=ASYNC,max_wal_nodes_num=0,wal_async_mode_fsync_delay_in_ms=1000,wal_sync_mode_fsync_delay_in_ms=3,wal_buffer_size_in_byte=33554432,wal_entry_size_limit_in_byte=-1,wal_file_list_cache_enabled=true,wal_cache_shrink_clear_enabled=true,wal_file_size_threshold_in_byte=31457280,wal_min_effective_info_ratio=0.1,wal_memtable_snapshot_threshold_in_byte=8388608,max_wal_memtable_snapshot_num=1,delete_wal_files_period_in_ms=20000,wal_throttle_threshold_in_byte=214748364800,iot_consensus_cache_window_time_in_ms=-1,enable_wal_compression=true,dn_wal_dirs=data/datanode/wal,wal_buffer_queue_proportion=0.1"
# 相 2 的 7 个 restart-only 新值
NEW_KEYS="wal_mode max_wal_nodes_num wal_buffer_size_in_byte wal_entry_size_limit_in_byte wal_file_list_cache_enabled wal_cache_shrink_clear_enabled wal_buffer_queue_proportion"
NEW_KV="wal_mode=SYNC,max_wal_nodes_num=2,wal_buffer_size_in_byte=16777216,wal_entry_size_limit_in_byte=1048576,wal_file_list_cache_enabled=false,wal_cache_shrink_clear_enabled=false,wal_buffer_queue_proportion=0.05"

# ---------------------------------------------------------------------------
# 局部 helper
# ---------------------------------------------------------------------------
w22_strip_from(){ local csv=$1 keys=" $2 " kv k out=""
  for kv in $(printf '%s' "$csv" | tr ',' ' '); do
    k="${kv%%=*}"
    case "$keys" in *" $k "*) continue ;; esac
    out="$out,$kv"
  done
  printf '%s' "${out#,}"; }
w22_orig_val(){ printf '%s' "$W22_ORIG" | tr ',' '\n' | grep -F "$1=" | head -1 | cut -d= -f2-; }
w22_eff(){ wal_eff "$1" "$2" | tr -d ' \r'; }
w22_props(){ wal_props_get "$1" "$2" | tr -d ' \r'; }
w22_running(){ cmp_running_cnt | tr -dc '0-9'; }
# DN 的 JVM pid：**必须**走 lib/wal_ext.sh 的 `wal_dn_pid`（扫 /proc/*/cmdline，只认 java 可执行
#   + cmdline 含 DataNode）。旧 pgrep 会拿到远端 `bash -c` 包装 shell ⇒ "重启前后 PID 已变化"
#   这条场景有效性判据会因包装 shell 的 pid 每次都不同而**恒成立**（假通过）。
w22_dn_pid(){ wal_dn_pid "$1"; }
w22_sql_as(){ timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$1" -pw "$2" -timeout 3600 -e "$3" 2>&1; }
# 逐键"重启后生效"核对：eff 可观测 ⇒ 硬断言（第 4 参 alt = 该键的**文档化等价取值**，
# 例如 wal_entry_size_limit_in_byte ≤0 时 getter 会兜底成 wal_buffer_size，见 source_grounding §1.3）；
# 不可观测 ⇒ WARN（靠 properties 兜底）
w22_key_assert(){ local label=$1 k=$2 want=$3 alt=${4:-} h e obs=0
  for h in "${DN[@]}"; do
    e=$(w22_eff "$h" "$k")
    [ -n "$e" ] && obs=$(( obs + 1 ))
    assert_eq "  $label 落盘核对 $h：$k（来源：$DB_DIR/conf/iotdb-system.properties）" "$(w22_props "$h" "$k")" "$want"
  done
  if [ "${obs:-0}" -eq 0 ]; then
    warn "  $label：$k 的运行期生效值不可观测（show configuration 未暴露）⇒ 本项降级 WARN（落盘值 + 数据面兜底）"
    return 0
  fi
  for h in "${DN[@]}"; do
    e=$(w22_eff "$h" "$k")
    [ -n "$e" ] || { warn "  $label：$h 未暴露 $k（该节点跳过）"; continue; }
    if [ -n "$alt" ] && [ "$e" = "$alt" ]; then
      pass "  $label 运行期值 $h：$k=$e（等于该键文档化的等价取值 '$alt'，源码 IoTDBConfig getter 兜底）"
    else
      assert_eq "  $label 运行期值 $h：$k（来源：show configuration，helper cmp_eff）" "$e" "$want"
    fi
  done; }
w22_fp(){ cmp_fp_tree "$DB"; }
w22_fpd(){ cmp_fingerprint tree "select s1 from $DB.d1 order by time"; }
w22_wal_ok(){ local tag=$1 wf
  wf=$(wal_sum_over_dn wal_file_cnt)
  log "  [$tag] WAL 面：files=$wf bytes=$(wal_sum_over_dn wal_dir_bytes)B 逐副本=$(wal_per_node)"
  [ "${wf:-0}" -ge 1 ] && pass "  [$tag] WAL 目录确有 .wal" || fail "  [$tag] WAL 文件数=0（wal_mode 不是 DISABLE，场景无效）"; }

# ---------------------------------------------------------------------------
# 相 1：单个键的 SET 探测（记录文案 → 分类判定 → 还原）
# ---------------------------------------------------------------------------
w22_probe_one(){ local k=$1 v=$2 old=$3 resp resp2 hint=0 named=0 pv0 pv1 e0 e1 e2
  log "--- 探测 $k：'$old' → '$v'（SET CONFIGURATION，不重启）---"
  pv0=$(w22_props "${DN[0]}" "$k"); e0=$(w22_eff "${DN[0]}" "$k")
  resp=$(wal_set "$k" "$v")
  log "  返回原文（来源：CLI 回显；helper wal_set/cmp_set_hot）：$(printf '%s' "$resp" | cut -c1-300)"
  printf '%s' "$resp" | grep -qE 'restart is required' && hint=1
  printf '%s' "$resp" | grep -qF -- "$k" && named=1

  if [ "$k" = "$RESTART_NOTPL" ]; then
    # 不在模板 ⇒ SET 应被 filterInvalidConfigItems 丢弃
    if [ "$hint" = "1" ]; then
      warn "  [$k] 不在模板却返回了 restart 提示 ⇒ 与 source_grounding §1.5「不在模板、SET 被丢弃」矛盾（记录，不判 FAIL）"
    else
      pass "  [$k] SET 未给 restart 提示（与该键不在模板的源码事实一致）"
    fi
    if [ "$(printf '%s' "$resp" | grep -icE 'ignor|not support|invalid|丢弃')" -ge 1 ]; then
      pass "  [$k] 返回文案显式提到被忽略/不支持：$(printf '%s' "$resp" | cut -c1-160)"
    fi
    pv1=$(w22_props "${DN[0]}" "$k")
    assert_eq "  [$k] 被 SET 丢弃：properties 值不得变化（§1.5 / §12-A.8）" "${pv1:-<无>}" "${pv0:-<无>}"
    return 0
  fi
  if [ "$k" = "$DEPRECATED_KEY" ]; then
    # 废弃别名（§1.3）：只记录 SET 文案；不写进 conf 组合，探测后把可能落盘的行删掉（避免制造无谓 WARN）
    if [ "$hint" = "1" ]; then warn "  [$k] 废弃别名键的 SET 返回了 restart 提示（记录）"
    else pass "  [$k] 废弃别名键的 SET 未给 restart 提示（记录；该键不在模板，SET 可能被丢弃）"; fi
    log "  [$k] 落盘值 '${pv0:-<无>}' → '$(w22_props "${DN[0]}" "$k")'；运行期 '${e0:-<不可观测>}' → '$(w22_eff "${DN[0]}" "$k")'"
    for h in "${DN[@]}"; do
      sshx "$h" "sed -i '/^${DEPRECATED_KEY}=/d' $DB_DIR/conf/iotdb-system.properties" >/dev/null 2>&1 \
        || warn "  [$k] 清理 $h 上可能落盘的废弃键行失败（只记录）"
    done
    return 0
  fi

  if printf ' %s ' "$RESTART_INTPL" | grep -q " $k "; then
    # ① restart-only（模板内 7 键）
    assert_contains "  [$k][restart-only] SET 必须提示需要重启（模板 # effectiveMode: restart）" "$resp" "restart is required"
    assert_contains "  [$k][restart-only] restart 提示必须点名 $k（ConfigManager.java:1927-1932）" "$resp" "$k"
    e1=$(w22_eff "${DN[0]}" "$k")
    if [ -n "$e1" ]; then
      assert_eq "  [$k][restart-only] 不重启时运行期值仍为原值（落盘≠生效）" "$e1" "$old"
    else
      warn "  [$k][restart-only] 运行期值不可观测 ⇒ 本项降级 WARN（靠落盘值 + 相 2 重启后生效兜底）"
    fi
    log "  [$k][restart-only] 落盘值：'${pv0:-<无>}' → '$(w22_props "${DN[0]}" "$k")'（SET 是否写入文件如实记录）"
    resp2=$(wal_set "$k" "$old")
    log "  还原 $k='$old' 返回：$(printf '%s' "$resp2" | cut -c1-200)"
    e2=$(w22_eff "${DN[0]}" "$k")
    if [ -n "$e2" ] && [ "$e2" != "$old" ]; then
      warn "  还原后运行期值='$e2' != '$old'（restart-only 键不应被 SET 改运行期值，记录）"
    fi
    return 0
  fi

  # ② hot_reload（其余键）
  assert_not_contains "  [$k][hot_reload] SET 不得要求重启（模板 # effectiveMode: hot_reload）" "$resp" "restart is required"
  e1=$(w22_eff "${DN[0]}" "$k")
  if [ -n "$e1" ]; then
    assert_eq "  [$k][hot_reload] 不重启即生效：运行期值 == 新值" "$e1" "$v"
  else
    warn "  [$k][hot_reload] 运行期值不可观测 ⇒ 「不重启即生效」降级 WARN（首轮 watch 项②）"
  fi
  resp2=$(wal_set "$k" "$old")
  log "  还原 $k='$old' 返回：$(printf '%s' "$resp2" | cut -c1-200)"
  e2=$(w22_eff "${DN[0]}" "$k")
  if [ -n "$e2" ]; then
    assert_eq "  [$k][hot_reload] 还原后运行期值回到原值" "$e2" "$old"
  else
    warn "  [$k][hot_reload] 还原后运行期值不可观测（记录）"
  fi
  return 0; }

# ---------------------------------------------------------------------------
# 相 1.5：权限（非 SYSTEM 用户 SET 必须不被接受）
# ---------------------------------------------------------------------------
w22_perm_phase(){ local K V out out2 code pv0 pv1 e0 e1
  K=wal_async_mode_fsync_delay_in_ms; V=1500
  log "--- 相 1.5) 权限：非 SYSTEM 用户 SET CONFIGURATION 必须被拒（DECISIONS §5）---"
  out=$(sq "create user $W22_USER '$W22_PW';" 2>&1)
  if ! sq "list user;" 2>&1 | grep -qF "$W22_USER"; then
    out2=$(sq "create user $W22_USER identified by '$W22_PW';" 2>&1)
    if ! sq "list user;" 2>&1 | grep -qF "$W22_USER"; then
      warn "  权限相场景未构造：普通用户创建失败（两种写法均未成功）⇒ 跳过并如实记录：$(printf '%s' "$out2" | tr '\n' ' ' | cut -c1-200)"
      return 0
    fi
  fi
  pass "  权限相场景成立：LIST USER 里可见普通用户 $W22_USER（create 返回：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)）"
  out=$(w22_sql_as "$W22_USER" "$W22_PW" "show databases;")
  if printf '%s' "$out" | grep -qiE 'Exception|error'; then
    warn "  权限相场景未构造：非管理员用户无法登录/查询 ⇒ 无法区分「权限不足」与「登录失败」，跳过（原始输出：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)）"
    return 0
  fi
  pass "  权限相正向前置：非管理员用户可正常登录并执行查询（权限模型确实在生效）"

  pv0=$(w22_props "${DN[0]}" "$K"); e0=$(w22_eff "${DN[0]}" "$K")
  out=$(w22_sql_as "$W22_USER" "$W22_PW" "set configuration '$K'='$V';")
  log "  非 SYSTEM 用户 SET '$K'='$V' 原始输出：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-240)"
  code=$(printf '%s' "$out" | grep -oE 'IoTDBSQLException: [0-9]+' | head -1 | grep -oE '[0-9]+$')
  pv1=$(w22_props "${DN[0]}" "$K"); e1=$(w22_eff "${DN[0]}" "$K")
  log "  落盘值：'${pv0:-<无>}' → '${pv1:-<无>}'；运行期值：'${e0:-<不可观测>}' → '${e1:-<不可观测>}'（实测错误码=${code:-未取到}）"
  if [ -n "$code" ] || printf '%s' "$out" | grep -qiE 'privilege|permission|not authorized|No permission'; then
    pass "  权限相：非 SYSTEM 用户被明确拒绝（错误码=${code:-无}，文案见上）"
  elif [ -z "${pv0:-}" ] && [ -z "${e0:-}" ]; then
    warn "  权限相无法判定：$K 既没有落盘值、运行期值也不可观测 ⇒ 只记录原始输出，不判 PASS/FAIL"
  elif [ "$pv1" = "$pv0" ] && [ "$e1" = "$e0" ]; then
    pass "  权限相：非 SYSTEM 用户 SET 未生效（落盘值与运行期值均未变化）"
    warn "  R-59 观察：非 SYSTEM 用户 SET 既未报权限错、也未生效 ⇒ 是否应显式报无权限，需研发确认（源码依据：该键在模板里无 '# Privilege:' 标注 ⇒ neededPrivileges 为空）"
  else
    fail "  权限要求未满足：非 SYSTEM 用户 $W22_USER 改动了 $K（落盘 '${pv0:-<无>}'→'${pv1:-<无>}'，运行期 '${e0:-?}'→'${e1:-?}'）"
    wal_set "$K" "$pv0" >/dev/null 2>&1 || warn "  还原 $K 失败，请人工检查"
  fi
  sq "drop user $W22_USER;" >/dev/null 2>&1 || warn "  （收尾）DROP USER $W22_USER 未成功（只记录）"
  return 0; }

# ===========================================================================
# 相 0：集群准备 + 基线（记录 19 键原值）
# ===========================================================================
log "=== W-22 参数热加载语义：库 $DB；键数=${#ALL_KS[@]}（期望 19）；consensus=${CONSENSUS_CLASS##*.} ==="
assert_eq "  源码清单条数：§1.2 共 19 项（键表长度）" "${#ALL_KS[@]}" "19"
assert_eq "  源码 restart-only 清单条数（模板内 7 + 不在模板 1）" "$(printf '%s' "$RESTART_INTPL" | wc -w | tr -d ' ')" "7"

log "--- 相 0) 集群准备：W22_ORIG（18 键原值）+ 关三类合并 ---"
EXTRA_CONF="$W22_ORIG,$CMP_EXTRA_WRITE" cmp_cluster_prepare
cmp_make_tree_db "$DB" "$DEVS"
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 1 || fail "  相 0 写入失败（场景无效）"
FP0=$(w22_fp); FPD0=$(w22_fpd)
log "  相 0 指纹（count/sum）：$FP0"
w22_wal_ok "相 0"
N0=$(w22_running)
assert_eq "  相 0：合法组合下集群就绪（Running/ReadOnly 行数）" "${N0:-0}" "$TOTAL"

OLD_VS=()
for i in $(seq 0 18); do
  k="${ALL_KS[$i]}"
  v=$(w22_eff "${DN[0]}" "$k")
  [ -n "$v" ] || v=$(w22_props "${DN[0]}" "$k")
  [ -n "$v" ] || v=$(w22_orig_val "$k")
  if [ "$k" = "dn_wal_dirs" ] && [ -z "$v" ]; then v="data/datanode/wal"; fi
  OLD_VS[$i]="$v"
  log "  原值基线：$k='${v:-<空>}'（运行期值优先，其次落盘值，最后文档默认）"
done

# ===========================================================================
# 相 1：逐个 SET 探测 19 键
# ===========================================================================
log "--- 相 1) 逐个 SET CONFIGURATION 探测 19 个 WAL 键（不重启）---"
for i in $(seq 0 18); do
  k="${ALL_KS[$i]}"; v="${ALL_VS[$i]}"; old="${OLD_VS[$i]}"
  if [ "$k" = "dn_wal_dirs" ]; then
    # 只用"当前值"探测文案（落地/多目录行为由 W-24 覆盖；避免把 WAL 目录真的切走）
    v="$old"
    log "--- 探测 $k：用当前值 '$v' 探测 SET 返回文案（不改变目录；行为见 W-24）---"
  fi
  w22_probe_one "$k" "$v" "$old"
done

# ===========================================================================
# 相 1.5：权限
# ===========================================================================
w22_perm_phase

# ===========================================================================
# 相 2：restart-only 键「重启后生效」
# ===========================================================================
log "--- 相 2) restart-only 7 键「重启后生效」：写 conf（$NEW_KV）→ 停 → 起（不 clean）---"
P2_EXTRA="$(w22_strip_from "$W22_ORIG" "$NEW_KEYS"),$NEW_KV,$CMP_EXTRA_WRITE"
declare -a PID0=()
for h in "${DN[@]}"; do PID0+=("$(w22_dn_pid "$h")"); done
log "  重启前 DN PID 基线：$(printf '%s ' "${PID0[@]:-}")"
cluster_stop
EXTRA_CONF="$P2_EXTRA" cluster_write_conf
cluster_start
N2=$(w22_running)
assert_eq "  相 2：写完 restart-only 新值后集群必须起来" "${N2:-0}" "$TOTAL"
for i in $(seq 0 $((${#DN[@]} - 1))); do
  cur=$(w22_dn_pid "${DN[$i]}")
  if [ -n "$cur" ] && [ "$cur" != "${PID0[$i]:-}" ]; then
    pass "  相 2 场景有效性：${DN[$i]} 的 DN PID 已变化（重启确实发生）"
  else
    fail "  相 2 场景无效：${DN[$i]} 的 DN PID 未变化（${PID0[$i]:-?} → ${cur:-<无>}；重启未发生）"
  fi
done
w22_key_assert "相 2" wal_mode SYNC
w22_key_assert "相 2" max_wal_nodes_num 2
w22_key_assert "相 2" wal_buffer_size_in_byte 16777216
w22_key_assert "相 2" wal_entry_size_limit_in_byte 1048576
w22_key_assert "相 2" wal_file_list_cache_enabled false
w22_key_assert "相 2" wal_cache_shrink_clear_enabled false
w22_key_assert "相 2" wal_buffer_queue_proportion 0.05
cmp_assert_same "  相 2 重启前后 count/sum（数据面硬判据）" "$FP0" "$(w22_fp)"
cmp_assert_same "  相 2 重启前后 $DB.d1 全序列" "$FPD0" "$(w22_fpd)"
w22_wal_ok "相 2"
wal_metrics_dump "${DN[0]}"

# ===========================================================================
# 相 3：还原原值 + 重启 + 能继续写
# ===========================================================================
log "--- 相 3) 还原 18 键原值 → 停 → 起（不 clean）→ 逐键回到原值 + 数据面完好 ---"
cluster_stop
EXTRA_CONF="$W22_ORIG,$CMP_EXTRA_WRITE" cluster_write_conf
cluster_start
N3=$(w22_running)
assert_eq "  相 3：还原后集群必须起来" "${N3:-0}" "$TOTAL"
w22_key_assert "相 3" wal_mode ASYNC
w22_key_assert "相 3" max_wal_nodes_num 0
w22_key_assert "相 3" wal_buffer_size_in_byte 33554432
w22_key_assert "相 3" wal_entry_size_limit_in_byte -1 33554432
w22_key_assert "相 3" wal_file_list_cache_enabled true
w22_key_assert "相 3" wal_cache_shrink_clear_enabled true
w22_key_assert "相 3" wal_buffer_queue_proportion 0.1
w22_key_assert "相 3" wal_min_effective_info_ratio 0.1
w22_key_assert "相 3" wal_file_size_threshold_in_byte 31457280
w22_key_assert "相 3" enable_wal_compression true
w22_key_assert "相 3" delete_wal_files_period_in_ms 20000
cmp_assert_same "  相 3 重启前后 count/sum（数据面硬判据）" "$FP0" "$(w22_fp)"
cmp_assert_same "  相 3 重启前后 $DB.d1 全序列" "$FPD0" "$(w22_fpd)"
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 2 || fail "  相 3 还原后写入失败（场景无效）"
GOT=$(row_sum "$(sq "select count(s1) from $DB.**;")")
assert_eq "  相 3 还原后继续写入行数（2 批）" "${GOT:-0}" "$(( DEVS * ROWS * 2 ))"
w22_wal_ok "相 3"

log "--- 判读 ---"
log "  restart-only（应为 8 个）：$RESTART_INTPL $RESTART_NOTPL"
log "  其中的模板内 7 键：SET 返回文案含 restart 提示 + 点名该键 + 不重启运行期值不变 + 重启后生效（相 2）。"
log "  $RESTART_NOTPL：不在模板 ⇒ SET 被丢弃（properties 不变），只能写文件+重启生效（相 2 已验证）。"
log "  其余 hot_reload 键：SET 不得带 restart 提示，且不重启即生效（运行期值即刻变为新值）。"
log "  $DEPRECATED_KEY 是废弃别名（§1.3）：只探测文案、不写进 conf 组合，避免无谓 WARN 污染收尾扫描。"
log "  iot_consensus_cache_window_time_in_ms 全仓无消费者（§1.5）⇒ 只探测 SET 文案，**不构造行为差异**。"

# ===========================================================================
# 收尾三件套（本用例不装 WAL 建议正则：SET/重启期会有 WAL 相关行）
# ===========================================================================
log "--- 收尾三件套 ---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance in ConsensusGroup|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader|Connection refused|Connection reset by peer|is deprecated|Threshold params'
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
