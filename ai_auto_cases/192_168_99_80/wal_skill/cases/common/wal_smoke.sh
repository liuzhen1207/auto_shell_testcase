#!/bin/bash
# ============================================================================
# W-00 冒烟（骨架门禁）：写多批 → 记 WAL 目录基线 → flush → WAL 目录确有文件
#                       → 读数/指纹一致 → 收尾三件套
#
# 【用例】W-00（集合 smoke；树模型；库名 root.walsmoke）
#
# 【覆盖需求】
#   · docs/req_sources/design_extract.md §2（WALNode / 文件组织）、§4（持久化与恢复）、
#     §6（可观测信号：文档**未给**日志关键字与指标名）、§8.1 TP-01~TP-03 / TP-09。
#   · docs/req_sources/source_grounding.md（源码印证，**本用例以它为准**）：
#       §3.1 根目录键只有 `dn_wal_dirs`（默认 data/datanode/wal；`wal_dir`/`wal_dirs` 键**不存在**，
#            模板注释里的 wal_dirs 属注释口误）—— CommonDescriptor.java:124-128、模板 :293
#       §3.2 WALNode 子目录 = `<walDir>/<identifier>`，IoTConsensus(V2) 下 identifier = `<database>-<regionId>`
#            —— AbstractNodeAllocationStrategy.java:72-73、DataRegion.java:806-812
#       §3.4 文件名 = `_<versionId>-<startSearchIndex>-<statusCode>.wal`，statusCode ∈ {0,1}
#            —— WALFileUtils.java:65-83、WALFileStatus.java:26-31
#       §9/§12-36 权威指标 `file_count{name="wal"}` / `file_size{name="wal"}` —— WalFileMetrics.java:35-48
#       §10.8 默认 logback `<root level="info">` ⇒ 大量 WAL 结论文案是 DEBUG 不落盘，
#             所以本用例的过程证据只用**目录面 + 指标面**，绝不用日志文案当功能判据。
#
# 【判据】（双信号/多信号；每条注明证据来源）
#   1) 场景有效性（硬）：写入行数 = WAL_DEVS×WAL_ROWS×(WAL_BATCHES+1)；不足 ⇒ fail「场景无效」。
#      来源：CLI `select count(s1) from root.walsmoke.**`（helper row_sum；原始输出在 $OUT）
#   2) 场景有效性（硬）：写入后 WAL 目录确有 `.wal` 文件、总字节 > 0。
#      来源：各 DN 的 `<dn_wal_dirs>/**/*.wal`（helper wal_file_cnt / wal_dir_bytes / wal_ls）
#   3) 多信号（硬）：① 文件数 ≥1；② 全部文件名匹配 `^_[0-9]+-[0-9]+-[01]\.wal$`；
#      ③ ≥1 个文件命中 magic `V3-WAL|V2-WAL`；④ WALNode 子目录 ≥1 且存在 `<db>-<regionId>` 形态目录。
#      （魔数依据 WALFileVersion.java:29-32 —— 注意是 `V3-WAL`/`V2-WAL`，**不是**设计文档写的 "WAL-V2"，
#        所以本用例不能用 lib 里的 wal_magic_cnt（它按 WAL-V2 匹配，在本构建上恒为 0），
#        改用本文件内的 walsmoke_magic_cnt。）
#   4) 指标面交叉验证（软，只 WARN）：`file_count{name="wal"}` > 0。指标门禁归 W-23，这里缺失只记录。
#   5) flush 前后 count/sum 与 root.walsmoke.d1 全序列指纹**完全一致**（硬）。
#      来源：cmp_fp_tree（CLI count/sum）与 cmp_fingerprint（d1 全序列归一化结果）
#   6) 收尾三件套：sync lag 归零 / 逐个停 DN 副本一致 / CN-DN 日志无异常。
#
# 【注意事项】
#   ⚠ 本脚本**未在集群实跑**（harness 阶段；99.80 正在跑合并长回归，禁止任何启停集群动作）。
#     只做了 `bash -n` 语法检查 + 静态核对（见交付说明）。
#   ⚠ 写配置一律 `EXTRA_CONF="..." cmp_cluster_prepare`（**单条命令的前缀环境变量**，不能先赋值再另起命令用）。
#     本用例显式追加 `wal_mode=ASYNC`（即使环境把 WAL_MODE 设成 DISABLE 也不会走到负向场景；DISABLE 见 W-02），
#     但追加前必须用 walsmoke_strip_keys 把 WAL_EXTRA_DEFAULT 里的同名键摘掉：cluster_write_conf 会
#     逐键回读校验、并把"第一次出现的期望值"与"最后落盘的值"相比，同名键带不同值会产生**假 FAIL**。
#   ⚠ harness 侧缺口（本文件**不改** lib/conf）：lib/common.sh 的 cluster_set_conf 引用了 TTL 专用变量
#     TTL_CHECK_INTERVAL_MS / MAX_EXPIRED_TIME_MS / EXPIRED_DATA_RATIO，而 wal_skill 的 conf/env.conf 未定义它们；
#     `set -u` 下这三个引用会让"写配置"这一步直接终止整个用例 ⇒ 本文件在 cmp_cluster_prepare 之前给出安全默认值。
#
#   首轮实跑 watch list（最关键 5 条）：
#     ① 真实 WAL 根目录与目录结构（本用例会把 `<walDir>` 与两层目录树打印出来）：观测面找错会让
#        "文件数=0"变成假 FAIL，真因是路径不对而不是 WAL 没写。预期根目录 = `<DB_DIR>/data/datanode/wal`，
#        子目录名 = `<db>-<regionId>`（如 root.walsmoke-3）。
#     ② 文件名是否**全部**匹配 `^_[0-9]+-[0-9]+-[01]\.wal$`；若出现 `.wal.enc` 后缀需确认是否开了 TSFile 加密
#        （WAL 加密跟随 TSFile `encrypt_type`，无独立开关）。
#     ③ 魔数：源码说 V2/V3 才写头 magic（`V3-WAL`），若一个都没命中，需现场确认真实格式后再决定是否保留本断言。
#     ④ `flush;` 之后活动 WAL 文件是否仍在：`delete_wal_files_period_in_ms` 默认 20s，只应删 status=0 的旧文件，
#        活动文件应保留；若长期为 0，说明观测口径或清理语义与预期不符。
#     ⑤ 指标端口是否真暴露 `file_count{name="wal"}`（DN_METRIC_PORT=9092）；缺失只 WARN。
#
# 用法： bash cases/common/wal_smoke.sh [--consensus IoTConsensus|IoTConsensusV2] [--framework 0|1]
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
cmp_case_init "wal_smoke_${DATA_CONSENSUS}"

DB=root.walsmoke
DEVS=${WAL_DEVS:-6}
ROWS=${WAL_ROWS:-300}
BATCHES=${WAL_BATCHES:-3}
WIN=${WAL_WIN_SEC:-120}
CLOSE_WIN=${WAL_CLOSE_WIN_SEC:-60}
EXPECT=$(( DEVS * ROWS * (BATCHES + 1) ))

# ---------------------------------------------------------------------------
# 本文件局部 helper（只补 wal_ext.sh 没有的口径；不重复实现已有 helper）
# ---------------------------------------------------------------------------
# 从 WAL_EXTRA_DEFAULT 里摘掉指定键（本用例要自己给这些键定值）。
#   ⚠ 必须摘：`cluster_write_conf` 是"所有节点先写完、再逐键回读校验"，它把 EXTRA_CONF 里**第一次**出现的
#     期望值与文件里**最后一个**值相比 ⇒ 同名键出现两次且值不同必然产生**假 FAIL**（本项目踩过 34 个假 FAIL）。
#   ⚠ 注意不能先把 EXTRA_CONF 赋值成变量再在另一条命令里用，必须写成 `EXTRA_CONF="$(fn ...)" cmd` 的前缀形式。
walsmoke_strip_keys(){ local keys=" $1 " kv k out=""
  for kv in $(printf '%s' "$WAL_EXTRA_DEFAULT" | tr ',' ' '); do
    k="${kv%%=*}"
    case "$keys" in *" $k "*) continue ;; esac
    out="$out,$kv"
  done
  printf '%s' "${out#,}"; }

# 写一批**不 flush**的树模型数据：cmp_write_tree_batch 末尾自带 flush，
# 无法用来构造"WAL 里确实有未刷盘 entry"的场景，故这里加一个无 flush 变体。
walsmoke_write_unflushed(){ local db=$1 devs=$2 rows=$3 b=${4:-1} d k vals ts start
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

# 轮询等 WAL 文件数达标（WAL 是异步刷盘的，写完立刻数可能还没落盘）
walsmoke_wait_files(){ local want=$1 win=$2 n=0
  local dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    n=$(wal_sum_over_dn wal_file_cnt)
    [ "${n:-0}" -ge "$want" ] && { echo "$n"; return 0; }
    sleep 3
  done
  echo "${n:-0}"; return 1; }

# 真实 WAL 文件名清单（来源：<dn_wal_dirs>/<identifier>/ 下的 *.wal）
walsmoke_names(){ local h=$1
  sshx "$h" "find $(wal_roots_arg "$h") -name '*.wal' -printf '%f\n' 2>/dev/null" 2>/dev/null | tr -d '\r'; }
# 不符合 `_<versionId>-<startSearchIndex>-<statusCode>.wal` 的文件数（0 = 全部合规）
walsmoke_bad_names(){ local h=$1
  walsmoke_names "$h" | grep -cvE '^_[0-9]+-[0-9]+-[01]\.wal(\.enc)?$'; }
# 命中 magic `V3-WAL|V2-WAL` 的文件数（WALFileVersion.java:29-32）
walsmoke_magic_cnt(){ local h=$1 v
  v=$(sshx "$h" "c=0; for f in \$(find $(wal_roots_arg "$h") -name '*.wal' 2>/dev/null); do grep -aqE 'V[23]-WAL' \"\$f\" && c=\$((c+1)); done; echo \$c" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 名为 `<db>-<regionId>` 的 WALNode 子目录数（IoTConsensus(V2) 的 identifier 形态）
walsmoke_region_dirs(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -cE '^$db-[0-9]+\$'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 目录树（现场标定用：根目录 + 最多两层）
walsmoke_tree(){ local h=$1
  sshx "$h" "find $(wal_roots_arg "$h") -maxdepth 2 2>/dev/null | head -20" 2>/dev/null | tr -d '\r'; }
# 某个日志文案在**该节点**上的出现次数（逐节点断言用；文件清单见 wal_log_files）
walsmoke_log_cnt(){ local h=$1 pat=$2 v
  v=$(sshx "$h" "grep -ahc '$pat' $(wal_log_files) 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }

log "=== W-00 冒烟：库 $DB；$DEVS 设备 × $ROWS 点 × $((BATCHES+1)) 批（末批不 flush） ==="
log "  规模来源：conf/env.conf 的 WAL_DEVS/WAL_ROWS/WAL_BATCHES（可用环境变量覆盖）；期望总行数=$EXPECT"

# ---------------------------------------------------------------------------
# 1) 集群准备（wal_mode 固定 ASYNC；写入期关三类合并，避免合并改写文件干扰观测）
# ---------------------------------------------------------------------------
log "--- 1) 集群准备：EXTRA_CONF = (WAL_EXTRA_DEFAULT 去掉 wal_mode) + wal_mode=ASYNC + 关三类合并 ---"
EXTRA_CONF="$(walsmoke_strip_keys 'wal_mode'),wal_mode=ASYNC,$CMP_EXTRA_WRITE" cmp_cluster_prepare

eff=$(wal_eff "${DN[0]}" wal_mode)
log "  运行期生效值（来源：${DN[0]} 的 show configuration，helper wal_eff）：wal_mode='${eff:-<未暴露>}'"
for h in "${DN[@]}"; do
  pv=$(wal_props_get "$h" wal_mode)
  log "  配置落盘值（来源：$h:$DB_DIR/conf/iotdb-system.properties，helper wal_props_get）：wal_mode='${pv:-<无>}'"
done
for h in "${DN[@]}"; do
  log "  WAL 根目录（来源：$h 的 conf 键 dn_wal_dirs + 常见路径探测，helper wal_dir_roots）：$(wal_dir_roots "$h" | tr '\n' ' ')"
done

# ---------------------------------------------------------------------------
# 2) 写入前基线
# ---------------------------------------------------------------------------
log "--- 2) 写入前 WAL 基线（集群刚被 clean ⇒ 期望 0 文件；非 0 只记录不判失败）---"
b_files=$(wal_sum_over_dn wal_file_cnt)
b_bytes=$(wal_sum_over_dn wal_dir_bytes)
log "  基线：files=$b_files bytes=${b_bytes}B；逐副本（来源：<dn_wal_dirs>/**/*.wal 的 find 计数）：$(wal_per_node)"

# ---------------------------------------------------------------------------
# 3) 造数据（多批 + 1 批不 flush）
# ---------------------------------------------------------------------------
log "--- 3) 造数据：$BATCHES 批带 flush + 1 批不 flush（后者保证 WAL 里有未刷盘 entry）---"
cmp_make_tree_db "$DB" "$DEVS"
for b in $(seq 1 "$BATCHES"); do
  cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" "$b" || fail "第 $b 批写入失败（场景无效）"
done
walsmoke_write_unflushed "$DB" "$DEVS" "$ROWS" "$((BATCHES+1))" || fail "未 flush 批次写入失败（场景无效）"

got=$(row_sum "$(sq "select count(s1) from $DB.**;")")
log "  写入行数：${got:-0} / 期望 $EXPECT（来源：CLI 'select count(s1) from $DB.**'，原始输出在 $OUT；helper row_sum）"
assert_eq "写入行数（场景有效性）" "${got:-0}" "$EXPECT"

# ---------------------------------------------------------------------------
# 4) WAL 目录基线（写入后 / flush 前）—— 场景有效性的硬断言
# ---------------------------------------------------------------------------
log "--- 4) WAL 目录基线（写入后、flush 前）---"
walsmoke_wait_files 1 "$WIN" >/dev/null
wf0=$(wal_sum_over_dn wal_file_cnt)
wb0=$(wal_sum_over_dn wal_dir_bytes)
wm0=0
wn0=$(wal_sum_over_dn wal_node_dirs)
wbad=0
wreg=0
for h in "${DN[@]}"; do
  wm0=$(( wm0 + $(walsmoke_magic_cnt "$h") ))
  wbad=$(( wbad + $(walsmoke_bad_names "$h") ))
  wreg=$(( wreg + $(walsmoke_region_dirs "$h" "$DB") ))
done
log "  flush 前：files=$wf0 bytes=${wb0}B magic(V3-WAL|V2-WAL)命中=$wm0 WALNode子目录=$wn0 其中<$DB-region>形态=$wreg 命名不合规=$wbad"
log "  逐副本（来源：wal_per_node = 各 DN 的 find 计数/字节求和）：$(wal_per_node)"
log "  文件清单（来源：wal_ls，${DN[0]}）：$(wal_ls "${DN[0]}" | tr '\n' ' ' | cut -c1-320)"
log "  目录树（来源：${DN[0]} 的 find <dn_wal_dirs> -maxdepth 2）：$(walsmoke_tree "${DN[0]}" | tr '\n' ' ' | cut -c1-320)"

[ "${wf0:-0}" -ge 1 ] && pass "场景成立：写入后 WAL 目录有 ${wf0} 个 .wal 文件（来源：<dn_wal_dirs>/**/*.wal）" \
  || fail "场景无效：写入后 WAL 文件数=0（来源：<dn_wal_dirs>/**/*.wal；先核对上面打印的真实根目录与目录树）"
[ "${wb0:-0}" -gt 0 ] && pass "场景成立：WAL 总字节=${wb0}B > 0" \
  || fail "场景无效：WAL 总字节=0（文件存在但为空 ⇒ 观测口径或写入路径异常）"
[ "${wbad:-0}" -eq 0 ] && pass "文件名全部匹配 _<versionId>-<startSearchIndex>-<statusCode>.wal（来源：WALFileUtils.java:65-83）" \
  || fail "有 ${wbad} 个 .wal 文件名不合规（期望正则 ^_[0-9]+-[0-9]+-[01]\\.wal$；来源：WALFileUtils.java:65-83）"
[ "${wm0:-0}" -ge 1 ] && pass "魔数命中：${wm0} 个文件含 V3-WAL|V2-WAL（来源：WALFileVersion.java:29-32）" \
  || fail "没有任何 .wal 命中魔数 V3-WAL|V2-WAL（若本构建确为 V1 格式请现场标定后调整本断言）"
[ "${wn0:-0}" -ge 1 ] && pass "WALNode 子目录数=${wn0}（来源：<dn_wal_dirs> 下的一级子目录）" \
  || fail "场景无效：WALNode 子目录数=0（WAL 文件应位于 <dn_wal_dirs>/<identifier>/ 下）"
[ "${wreg:-0}" -ge 1 ] && pass "存在 <$DB-regionId> 形态的 WALNode 目录 ${wreg} 个（来源：DataRegion.java:806-812）" \
  || warn "未见到 <$DB-regionId> 形态的 WALNode 目录（只 WARN：identifier 命名与源码推断不符时需现场标定）"

mc=$(wal_metric_sum_over_dn wal_metric_file_cnt)
mb=$(wal_metric_sum_over_dn wal_metric_file_bytes)
log "  指标口径（来源：各 DN http://<dn>:$DN_METRIC_PORT/metrics 的 file_count{name=\"wal\"} / file_size{name=\"wal\"}）：files=$mc bytes=$mb"
[ "${mc:-0}" -gt 0 ] && pass "指标交叉验证：file_count{name=wal}=$mc（目录口径 ${wf0}）" \
  || warn "指标 file_count{name=wal} 为 0 或缺失（只 WARN：指标门禁归 W-23；目录口径已单独判定）"
wal_metrics_dump "${DN[0]}"

fp0=$(cmp_fp_tree "$DB")
fd0=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")
log "  flush 前 count/sum：$fp0（来源：CLI + helper cmp_fp_tree）"
log "  flush 前 $DB.d1 全序列指纹行数：$(printf '%s' "$fd0" | grep -c .)（来源：cmp_fingerprint）"

# ---------------------------------------------------------------------------
# 5) flush + 等落盘
# ---------------------------------------------------------------------------
log "--- 5) flush 并等各副本 Async close（ensure_closed；失败只 WARN）---"
sq "flush;" >/dev/null
if ensure_closed "$DB" 3 "$CLOSE_WIN"; then
  log "  各副本均已出现新的 Async close 事件（来源：$DB_DIR/logs/log_datanode_all.log 的 'Async close tsfile: ...'）"
else
  warn "有副本的 TsFile 未在 ${CLOSE_WIN}s 内出现 Async close 事件（只影响'已落盘'这一过程证据，不影响本用例判据）"
fi

wf1=$(wal_sum_over_dn wal_file_cnt)
wb1=$(wal_sum_over_dn wal_dir_bytes)
log "  flush 后：files=$wf1 bytes=${wb1}B；逐副本=$(wal_per_node)"
[ "${wf1:-0}" -ge 1 ] && pass "flush 后 WAL 目录仍有 ${wf1} 个 .wal（活动文件不应消失）" \
  || fail "flush 后 WAL 文件数=0（活动 WAL 文件不应被清理；来源：WALNode.canDeleteFile 只删 status=0 的旧文件）"

got2=$(row_sum "$(sq "select count(s1) from $DB.**;")")
assert_eq "flush 后行数（不允许变化）" "${got2:-0}" "$EXPECT"

# ---------------------------------------------------------------------------
# 6) 读数/指纹一致（硬判据：flush 不得改变任何读数）
# ---------------------------------------------------------------------------
log "--- 6) 读数/指纹一致性 ---"
fp1=$(cmp_fp_tree "$DB")
fd1=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")
log "  flush 后 count/sum：$fp1"
cmp_assert_same "flush 前后 count/sum（cmp_fp_tree）" "$fp0" "$fp1"
cmp_assert_same "flush 前后 $DB.d1 全序列（cmp_fingerprint）" "$fd0" "$fd1"
cmp_assert_same "flush 前后行数（CLI count）" "${got:-0}" "${got2:-0}"

for h in "${DN[@]}"; do
  log "  $h WAL 日志尾部（来源：$(wal_log_files)）：$(wal_log_tail "$h" 5 | tr '\n' ' ' | cut -c1-240)"
done

# ---------------------------------------------------------------------------
# 7) 收尾三件套（装 WAL 专属异常正则 + WAL 正证据钩子）
# ---------------------------------------------------------------------------
log "--- 7) 收尾三件套 ---"
wal_install_err_pat
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
# 停/重启节点引发的一致性噪声属**测试动作噪声**（其它 skill 实测），不计入本用例的异常判定
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance in ConsensusGroup|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader'
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
