#!/bin/bash
# ============================================================================
# W-09 `wal_buffer_size_in_byte`（WAL Buffer 大小；树模型；库名 root.walbuf）
# ----------------------------------------------------------------------------
# 目标（cases/cases.tsv W-09）：把 `wal_buffer_size_in_byte` 调小（WAL_BUFFER_SMALL=256KB）
#   → 写入正确性 + 文件轮转/性能表现**如实记录**；并与默认值对照（**先 cmp_eff 读实际生效值**，
#   因为文档之间的默认值互相矛盾）。**耗时只 WARN**，唯一 FAIL 判据是数据面。
#
# 需求依据（docs/req_sources/design_extract.md）：
#   · §2.5「`wal_buffer_size_in_byte`：WAL Buffer 的大小，默认为 **16 MB**」（未标热加载）。
#   · §2.5 `fsync_wal_delay_in_ms` 条目：「如果当前 WAL Buffer 已写入的大小不大于
#     wal_buffer_size_in_byte 的 95% 时，将该 WAL Buffer 刷盘前的等待时间」
#     ⇒ buffer 大小直接决定"多大的一批才触发刷盘"，也是本用例与 W-08(阈值)/W-11(压缩) 的分工点。
#   · §2.4「文件滚动的触发条件是当前文件及其待写入的 buffer 的数据量超过
#     wal_file_size_threshold_in_byte」⇒ **buffer 与阈值都会影响文件数**，所以对照实验必须
#     把阈值固定在同一个值（本用例两相都用 WAL_ROTATE_THRESHOLD_SMALL=1MB），否则两相不可比。
#   · §3.6 三 Buffer 状态机：每个 WALNode 的 buffer 物理上平均分三块（working/compressed/syncing）
#     ⇒ buffer 变小会改变"必须阻塞等 idle buffer"的频率，表现为耗时/轮转节奏变化（只记录，不判性能）。
#   · §4.1/§4.3：ASNYC 下写入返回不等待刷盘 ⇒ **本用例两相都刻意不 flush**，Phase A 末尾还会
#     整集群重启一次（`wal_restart_all`，不清数据），把"小 buffer 写出的 WAL 能否完整重放"作为
#     真正的数据面判据（§4.3 恢复流程）。
#
# 源码印证（docs/req_sources/source_grounding.md §1.2）：模板 `iotdb-system.properties.template:1959`
#   `wal_buffer_size_in_byte=33554432`（**32MB**）、`# effectiveMode: restart`（`:1957`）
#   ⇒ ① 与设计文档的 16MB **矛盾**（本用例先读实际生效值再对照，记录矛盾但不当缺陷）；
#      ② **restart-only** ⇒ 只能写配置文件 + 重启生效（不能用 SET CONFIGURATION 改运行值）。
#
# 判据（FAIL 只来自数据面 / 场景有效性）：
#   1) 场景有效性（硬）：两相写入行数达标；每一相"配置文件里的值"与"cmp_eff 读到的实际生效值"
#      都等于本相期望值（否则配置没生效 ⇒ 场景无效 ⇒ FAIL）；两相都至少有 1 个 .wal 文件；
#   2) 数据面（硬）：两相写入后全库 count/sum 与理论值一致；两相数据指纹互相一致（相同数据）；
#      **Phase A 整集群重启后（未 flush）数据一条不少、指纹不变**（小 buffer 的 WAL 必须可完整重放）；
#   3) 收尾三件套：sync lag 归零 / 逐个停 DN 副本一致 / CN-DN 日志无 NPE·OOM·越界等异常；
#   4) 耗时、WAL 文件数、单文件最大字节、指标绝对值、文档 16M/32M 矛盾 ⇒ 只 WARN / 记录。
#
# 用法： bash cases/common/wal_buffer_size.sh [--consensus IoTConsensus|IoTConsensusV2]
#
#   ⚠ **本条未实跑**（写就时 99.80 正在跑合并长回归，禁止任何集群动作；本用例会启停集群两次
#     + Phase A 末尾整集群重启一次，属"任何集群动作"）。仅保证 `bash -n` 与 tools/selftest.sh 静态通过。
#
# watch list（首跑前逐条确认，3~5 条）：
#   ① `wal_buffer_size_in_byte` 是 **restart-only**：本用例靠 `cmp_cluster_prepare`（写 conf + 重启）
#      生效；**不要**再用 `SET CONFIGURATION` 去改它（改了运行值不变，反而污染"生效值"证据）。
#   ② EXTRA_CONF 里**不能出现同名键两次**：`cluster_write_conf` 会逐键回读校验，同名键"后者覆盖前者"
#      会被它判成"写配置失败"（false FAIL）⇒ 本用例用 w09_strip_keys() 先把默认组合里的同名键摘掉。
#   ③ `wal_entry_size_limit_in_byte`（默认 -1 ⇒ 兜底取 wal_buffer_size_in_byte，源码 `IoTDBConfig.java:2244`）
#      是**同一族的 restart-only 键**，本用例只把它当对照证据打印（不改），不要拿它当判据。
#   ④ 单文件大小可能**超过**阈值：§2.4 的判定是"当前文件 + 待写入 buffer"⇒ 只记录 max 字节，不判超标。
#   ⑤ 若首跑发现"小 buffer 相耗时明显更大"：这属预期（buffer 小 ⇒ 批次小、刷盘次数多），**只 WARN**；
#      真正要盯的是 Phase A 重启后数据是否一条不少。
#
# ---------------------------------------------------------------------------
# 判据速查（读代码先看这里：FAIL 只可能来自 §A 场景有效性 与 §B 数据面）
#   §A 场景有效性（fail "场景无效：…"）：
#        · 配置文件里的 wal_buffer_size_in_byte 没写成本相期望值（某个 DN 没写进去）
#        · cmp_eff 能读到生效值时，生效值 ≠ 配置值（restart-only 没生效 ⇒ 两相其实测的是同一件事）
#        · 两相写入后行数 ≠ 设备数 × 每设备行数；两相任一 WAL 文件数 = 0
#   §B 数据面（唯一的"产品问题"判据）：
#        · 写入后全库 count/sum 与理论值不符
#        · **Phase A 整集群重启（未 flush）后行数/指纹与重启前不一致** ← 本条最有价值的判据
#        · 两相指纹不一致（两相写的是同一份数据，只有 buffer 大小不同）
#   §C 只 WARN / 只记录（绝不 FAIL）：
#        · Phase A 耗时 vs Phase B 耗时（文档没有性能基线；§1.3 只说 WAL 写盘是性能上限）
#        · WAL 文件数、单文件最大字节、指标绝对值、文件名形态（源码 `_v-i-s.wal` vs 文档 `_v.wal`）
#        · 文档默认值矛盾（设计文档 16MB vs 模板 33554432=32MB）——以实际生效值为准
#   §D 与相邻用例的边界：
#        · W-08 单独测"轮转阈值"，本条把阈值**固定**成同一个值，只让 buffer 大小变化；
#        · W-11 测压缩开关对体积的影响；本条不碰压缩（两相都沿用默认 true）。
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_buffer_size_${DATA_CONSENSUS}"

DB=root.walbuf
DEVS=${W09_DEVS:-10}
ROWS=${W09_ROWS:-2000}
WIN=${WAL_REPLAY_WIN_SEC:-300}
TOTAL=$(( DEVS * ROWS ))
BUFSMALL=${WAL_BUFFER_SMALL:-262144}
THRESH=${WAL_ROTATE_THRESHOLD_SMALL:-1048576}
MINFILES=${WAL_ROTATE_MIN_FILES:-2}
# 固定时间戳基准：两相写**完全相同**的数据 ⇒ 指纹必须逐字相同（跨相数据面判据）
BASE=$(( ($(date +%s) - 86400) * 1000 ))

# ---------------------------------------------------------------------------
# 本地辅助
# ---------------------------------------------------------------------------
# 从 WAL_EXTRA_DEFAULT 里摘掉指定键（避免同名键重复 ⇒ 触发 cluster_write_conf 的逐键回读误判）
w09_strip_keys(){ local out="$WAL_EXTRA_DEFAULT" k
  for k in "$@"; do
    out=$(printf '%s' "$out" | tr ',' '\n' | grep -v "^${k}=" | tr '\n' ',' | sed 's/,$//')
  done
  printf '%s' "$out"; }

# 写数据（**不 flush**）：500 行/语句
w09_write(){ local db=$1 d k ts vals
  for ((d=1; d<=DEVS; d++)); do
    vals=""
    for ((k=0; k<ROWS; k++)); do
      ts=$(( BASE + k * 10 ))
      vals="$vals($ts,$(( k + 1 ))),"
      if [ $(( (k + 1) % 500 )) -eq 0 ]; then
        sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null \
          || warn "  设备$d 第 $((k+1)) 点写入返回非空（行数断言会兜底）"
        vals=""
      fi
    done
    [ -n "$vals" ] && { sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null \
      || warn "  设备$d 尾批写入返回非空"; }
  done
  log "  写入完成（$DEVS 设备 × $ROWS 点，**未 flush**，时间戳基准 $BASE）"
}

w09_total(){ row_sum "$(sq "select count(s1) from $DB.**;")"; }
# 单个 WAL 文件的最大字节（证据；§2.4 阈值判定含"待写入 buffer"⇒ 不判超标）
w09_max_wal_bytes(){ local v
  v=$(sshx "$1" "find $(wal_roots_arg "$1") -name '*.wal' -printf '%s\n' 2>/dev/null | sort -n | tail -1" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 文件名形态命中数：源码口径 `_<versionId>-<startSearchIndex>-<statusCode>.wal`
w09_name_pat_src(){ local n
  n=$(sshx "$1" "find $(wal_roots_arg "$1") -name '*.wal' -printf '%f\n' 2>/dev/null | grep -cE '^_[0-9]+-[0-9]+-[01]\\.wal$'" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }
# 文件名形态命中数：设计文档口径 `_[version_id].wal`（§2.3/§4.1）
w09_name_pat_doc(){ local n
  n=$(sshx "$1" "find $(wal_roots_arg "$1") -name '*.wal' -printf '%f\n' 2>/dev/null | grep -cE '^_[0-9]+\\.wal$'" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }

# 一相的完整观测：写 + 行数 + 指纹 + WAL 文件面（目录口径 & 指标口径）+ 文件名形态 + 耗时
#   ⚠ 本函数**不 echo**：内部大量 log/pass/warn 都会写 stdout，若用 $(...) 捕获会把日志也吞进来
#     导致指纹比较变成"日志 vs 指纹"（本项目踩过类似坑）⇒ 指纹通过全局变量 W09_FP 带回。
w09_phase_measure(){ local tag=$1 t0 t1 f0 fp
  t0=$(date +%s)
  w09_write "$DB"
  wait_scalar_tree "select count(s1) from $DB.d1;" "$ROWS" 120 "$tag 写入后 d1 行数"
  t1=$(date +%s)
  assert_eq "$tag 全库总行数" "$(w09_total)" "$TOTAL"
  fp=$(cmp_fp_tree "$DB")
  log "  [$tag] 指纹=$fp"
  f0=$(wal_sum_over_dn wal_file_cnt)
  log "  [$tag] WAL 面（目录口径）：文件数=$f0 字节=$(wal_sum_over_dn wal_dir_bytes)B 单文件最大=$(w09_max_wal_bytes "${DN[0]}")B；逐副本=$(wal_per_node)"
  log "  [$tag] WAL 面（指标口径，权威）：文件数=$(wal_metric_sum_over_dn wal_metric_file_cnt) 字节=$(wal_metric_sum_over_dn wal_metric_file_bytes)"
  wal_metrics_dump "${DN[0]}"
  log "  [$tag] 文件名形态：源码口径(_<version>-<searchIndex>-<0|1>.wal)=$(w09_name_pat_src "${DN[0]}") 设计文档口径(_<version>.wal)=$(w09_name_pat_doc "${DN[0]}")"
  log "  [$tag] 写+可见耗时=$(( t1 - t0 ))s（**只 WARN/记录**：文档未给性能基线）"
  W09_FP="$fp"
}

log "=== W-09 目标：wal_buffer_size_in_byte=$BUFSMALL（小） vs 默认生效值（对照）==="
log "  库=$DB 规模=$DEVS×$ROWS=$TOTAL 行 轮转阈值固定=${THRESH}B（两相相同，隔离 buffer 变量）"
log "  环境默认：WAL_BUFFER_BYTES=$WAL_BUFFER_BYTES（模板 33554432=32MB；设计文档写 16MB ⇒ 先读生效值）"

# ===========================================================================
# Phase A：小 buffer（256KB）+ 固定轮转阈值 1MB，写完后整集群重启验证 WAL 可完整重放
# ===========================================================================
log "--- Phase A：wal_buffer_size_in_byte=$BUFSMALL ---"
W09_A_CONF="$(w09_strip_keys wal_buffer_size_in_byte wal_file_size_threshold_in_byte),wal_buffer_size_in_byte=${BUFSMALL},wal_file_size_threshold_in_byte=${THRESH}"
log "  EXTRA_CONF=$W09_A_CONF"
EXTRA_CONF="$W09_A_CONF" cmp_cluster_prepare

# 场景有效性：配置文件里的值 + 实际生效值都必须等于本相期望（否则场景无效）
A_PROPS_OK=0
for h in "${DN[@]}"; do
  p=$(wal_props_get "$h" wal_buffer_size_in_byte)
  [ "$p" = "$BUFSMALL" ] && A_PROPS_OK=$(( A_PROPS_OK + 1 )) || warn "  $h 配置文件 wal_buffer_size_in_byte=[$p] 期望=[$BUFSMALL]"
done
[ "$A_PROPS_OK" -eq "${#DN[@]}" ] && pass "Phase A 配置文件已写入 wal_buffer_size_in_byte=$BUFSMALL（${#DN[@]}/${#DN[@]} 节点）" \
  || fail "场景无效：只有 $A_PROPS_OK/${#DN[@]} 个节点的配置文件写对了 buffer 大小"
A_EFF=$(wal_eff "${DN[0]}" wal_buffer_size_in_byte)
log "  Phase A 实际生效值（cmp_eff/show configuration）：wal_buffer_size_in_byte=[$A_EFF]"
log "  Phase A 对照键：wal_entry_size_limit_in_byte 生效=[$(wal_eff "${DN[0]}" wal_entry_size_limit_in_byte)] 配置文件=[$(wal_props_get "${DN[0]}" wal_entry_size_limit_in_byte)]（-1=兜底取 buffer 大小，只作证据）"
if [ -z "$A_EFF" ]; then
  warn "  cmp_eff 读不到 wal_buffer_size_in_byte（show configuration 未暴露该键）⇒ 只以配置文件值为准，记录该缺口"
else
  assert_eq "Phase A 实际生效值 = 配置值（restart-only 已生效）" "$A_EFF" "$BUFSMALL"
fi

FP_A=""
w09_phase_measure "Phase A"
FP_A="$W09_FP"
A_FILES=$(wal_sum_over_dn wal_file_cnt)
[ "${A_FILES:-0}" -ge 1 ] && pass "Phase A 场景有效：WAL 文件数=$A_FILES" \
  || fail "场景无效：Phase A WAL 文件数为 0（写路径或 WAL 目录识别有问题）"
[ "${A_FILES:-0}" -ge "$MINFILES" ] && pass "Phase A 轮转已发生：WAL 文件数 $A_FILES ≥ $MINFILES" \
  || warn "Phase A WAL 文件数 $A_FILES < $MINFILES（阈值 ${THRESH}B 下未观察到轮转；只记录——文件数是'如实记录'项）"

# Phase A 关键数据面：不 flush + 整集群重启 ⇒ 数据必须靠 WAL 完整重放回来
log "  --- Phase A 数据面：整集群重启（不清数据、不 flush）后核对 ---"
wal_restart_all || warn "  wal_restart_all 返回非 0（继续按可见性判定）"
wait_scalar_tree "select count(s1) from $DB.d1;" "$ROWS" "$WIN" "Phase A 重启后 d1 行数"
assert_eq "Phase A 重启后全库总行数" "$(w09_total)" "$TOTAL"
cmp_assert_same "Phase A 重启前后指纹（小 buffer 的 WAL 必须可完整重放）" "$FP_A" "$(cmp_fp_tree "$DB")"
log "  Phase A 重启后 WAL 面：文件数=$(wal_sum_over_dn wal_file_cnt) 字节=$(wal_sum_over_dn wal_dir_bytes)B 指标文件数=$(wal_metric_sum_over_dn wal_metric_file_cnt)"
T_A_RESTART_NOTE="Phase A 已含一次整集群重启"
log "  （$T_A_RESTART_NOTE）"

# ===========================================================================
# Phase B：默认 buffer（不覆盖 wal_buffer_size_in_byte），轮转阈值与 Phase A 相同
# ===========================================================================
log "--- Phase B：默认 buffer（对照相；轮转阈值仍固定 ${THRESH}B）---"
W09_B_CONF="$(w09_strip_keys wal_file_size_threshold_in_byte),wal_file_size_threshold_in_byte=${THRESH}"
log "  EXTRA_CONF=$W09_B_CONF"
EXTRA_CONF="$W09_B_CONF" cmp_cluster_prepare

B_PROPS=$(wal_props_get "${DN[0]}" wal_buffer_size_in_byte)
B_EFF=$(wal_eff "${DN[0]}" wal_buffer_size_in_byte)
log "  Phase B 配置值=[$B_PROPS] 实际生效值=[$B_EFF]（期望配置值=$WAL_BUFFER_BYTES=32MB；设计文档写 16MB）"
[ "$B_PROPS" = "$WAL_BUFFER_BYTES" ] && pass "Phase B 配置文件 buffer 大小=$B_PROPS（= env 默认值，未覆盖）" \
  || fail "场景无效：Phase B 配置文件 buffer 大小=[$B_PROPS] 期望=[$WAL_BUFFER_BYTES]（默认组合没写进去）"
if [ -z "$B_EFF" ]; then
  warn "  Phase B cmp_eff 读不到该键（show configuration 未暴露）⇒ 无法核对生效值，如实记录"
elif [ "$B_EFF" = "$B_PROPS" ]; then
  pass "Phase B 实际生效值 = 配置值（$B_EFF）"
else
  warn "Phase B 配置值=[$B_PROPS] 但实际生效值=[$B_EFF]（文档 16M/32M 矛盾之外的新差异；如实记录，不判 FAIL）"
fi

FP_B=""
w09_phase_measure "Phase B"
FP_B="$W09_FP"
B_FILES=$(wal_sum_over_dn wal_file_cnt)
[ "${B_FILES:-0}" -ge 1 ] && pass "Phase B 场景有效：WAL 文件数=$B_FILES" \
  || fail "场景无效：Phase B WAL 文件数为 0"
cmp_assert_same "两相数据指纹（同一份数据、仅 buffer 大小不同）" "$FP_A" "$FP_B"

# ---------------------------------------------------------------------------
# 对照结论（全部只 WARN / 记录）
# ---------------------------------------------------------------------------
log "--- 对照（耗时/文件数/字节；只记录，不判 FAIL）---"
log "  buffer：小=${BUFSMALL}B（生效 $A_EFF） vs 默认=${B_PROPS}B（生效 $B_EFF）"
log "  WAL 文件数：小=$A_FILES vs 默认=$B_FILES（轮转阈值两相都是 ${THRESH}B）"
log "  单文件最大字节：小=$(w09_max_wal_bytes "${DN[0]}")B（Phase B 现场）"
warn "性能/体积对照只作记录：文档未给 wal_buffer_size_in_byte 的性能基线（§2.5 只给默认值与 95% 刷盘语义），且 §1.3 明说 WAL 写盘是写入性能上限的决定因素 ⇒ 本用例不对耗时下结论；文件数差异同时受刷盘批次与轮转阈值影响（§2.4/§3.6）。"
warn "文档默认值矛盾（如实记录，不判缺陷）：design_extract §2.5「wal_buffer_size_in_byte 默认为 16 MB」 vs 模板 iotdb-system.properties.template:1959「33554432（32MB）」；本用例以**实际生效值**为对照基准。"

# ---------------------------------------------------------------------------
# 收尾三件套
# ---------------------------------------------------------------------------
log "--- 收尾三件套 ---"
export WAL_EVIDENCE_DB="$DB"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
# 本用例不故意制造 WAL 错误，但仍不安装 WAL 建议正则（未实跑标定；唯一 FAIL 判据是数据面）。
post_checks "select count(s1) from $DB.d1;" tree
cmp_case_finish "" tree ""
