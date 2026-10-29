#!/bin/bash
# ============================================================================
# W-13 压缩 / 未压缩 WAL 共存恢复（存储模块 WAL 专项 skill）
#   库名：root.walmix（WAL 约定：库名一律 root.wal*，不与其它 skill / 长回归互相干扰）
#
# 【一句话】未压缩态写入（**不 flush**）→ 打开 WAL 压缩继续写入（同一 WAL 目录里"老未压缩段 + 新压缩段"
#          共存）→ kill -9 模拟掉电 → 重启（此时进程是"压缩开启"的一方）→ **两批数据一条不少、逐副本一致**。
#
# 【为什么这条是"可构造、且应通过"】（2026-10-16 源码印证校正；docs/req_sources/source_grounding.md §4）
#   · 压缩粒度是**段级**（一次 sync 批次的 buffer 段）：段头 1 字节标 compressionType、4 字节 compressedSize、
#     压缩时再 4 字节 uncompressedSize；**<32KB 的段不压**（LogWriter.java:110-152，MIN_COMPRESSION_SIZE=32KB）。
#     ⇒ 同一个 .wal 文件里可以同时存在压缩段与未压缩段，读侧逐段读标志
#       （WALInputStream.java:487-504 getNextSegmentInfo；:336-348 未压缩段直读）。
#   · 文件级另有 WALFileVersion 的 magic：V3="V3-WAL" / V2="V2-WAL" / 兜底 V1="WAL"
#     （WALFileVersion.java:29-32,58-81）；恢复时对未压缩的"半截段"做截断容忍（WALInputStream.java:265-270）。
#   · 需求文档《WAL 压缩功能设计.md#需要确定的内容》只写了"WAL 内容中没有版本号这个标识 ⇒ 先尝试解压、
#     失败按未压缩读"的兜底策略，**没有**写"共存"。这一条由源码印证补齐。
#   ⇒ 因此本用例**不预先降级成 warn**：共存 + 恢复完整性是硬断言；失败就是真发现（保留逐副本证据）。
#
# 【判据】硬 = FAIL；软 = 只 warn
#   ① 场景有效性（硬）：相 A 写完后 WAL 目录必须有 .wal 文件（=0 ⇒ fail "场景无效"）；
#      相 A/B 的 `enable_wal_compression` **落盘值**必须分别是 false / true（否则开关根本没切过去）。
#   ② 数据面（硬，唯一功能判据）：kill -9 + 重启后 count/sum 与掉电前完全一致，且**逐副本**（经每个 DN 查）
#      都与理论值一致；写入行数必须 == 理论值（不足 ⇒ 场景无效 fail）。
#   ③ 恢复确实发生（硬）：重启后日志出现 WAL 恢复文案（`Successfully recover all wal nodes.`，
#      source_grounding §8.2）；完全没有 ⇒ fail（场景退化成"已刷盘"，恢复路径没被验到）。
#   ④ 共存证据（软）：相 A 的文件名在相 B 之后仍能在同一目录看到、同时有新文件名出现 ⇒ pass；
#      若已轮转/被消费掉 ⇒ warn（"共存"是过程证据，数据面才是判据）。
#   ⑤ 压缩体积方向（软）：只记录两相字节数，不判 FAIL（<32KB 的段本来就不压，压缩率依赖数据可压性）。
#
# 【watch list】首轮实跑时用这 5 条判断"场景真的成立"（判的是场景，不是产品）
#   1) `相 A：WAL 文件数 > 0`：若为 0，先分辨是"写入没进 WAL"还是"wal_dir_roots 没定位到目录"——
#      用例会把 wal_dir_roots / wal_ls / 指标 file_count 一起打出来。
#   2) `相 A/B 的开关生效值`：`show configuration` 里若没有 enable_wal_compression 键，只信 properties 落盘值并记 warn。
#   3) `相 A 与相 B 的 WAL 文件名集合`：出现"老名字仍在 + 新名字出现"即共存成立；只有一个名字说明
#      wal_file_size_threshold_in_byte（=$THRESH）没触发轮转（写量不足）⇒ 加大 WAL_DEVS / WAL_ROWS。
#   4) `kill -9 后重启的日志`：应能看到恢复文案；若毫无恢复动作，说明 memtable 在退出前已刷盘（场景强度下降，记 warn）。
#   5) `重启后逐副本 count/sum`：不一致即真缺陷 ⇒ 保留逐副本 + WAL 清单 + 魔数命中 + 指标证据（用例自动打印）。
#
# 用法： bash cases/common/wal_compress_mixed.sh [--consensus IoTConsensus|IoTConsensusV2]
#   ⚠ 骨架阶段**未实跑**（99.80 上正在跑长回归，禁止启停集群）；只保证 bash -n 与静态检查通过。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_compress_mixed_${DATA_CONSENSUS}"

# ---------------------------------------------------------------------------
# 0. 用例参数 + 环境兜底
# ---------------------------------------------------------------------------
DB=root.walmix
DEVS=${WAL_DEVS:-6}                       # 设备数
ROWS=${WAL_ROWS:-300}                     # 每设备每批点数
BATCHES=2                                 # 相 A（未压缩）1 批 + 相 B（压缩）1 批
THRESH=${WAL_ROTATE_THRESHOLD_SMALL:-1048576}   # 1MB：让 WAL 快速轮转，"共存"更容易看到两个文件
WIN=${WAL_WIN_SEC:-120}                   # 等 WAL 落盘 / 等证据的窗口
REPLAY_WIN=${WAL_REPLAY_WIN_SEC:-300}     # 重启后等重放/数据可见的窗口

# ⚠ env.conf 兜底：wal_skill 的 conf/env.conf 当前**没有**这三个 TTL 键，而 lib/common.sh 的
#   cluster_write_conf 在 `set -u` 下会引用它们 ⇒ 不兜底会在 cmp_cluster_prepare 里
#   "unbound variable" 直接退出（不改 lib/conf，只在用例里给默认值；换环境仍可被环境变量覆盖）。
export TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
export MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
export EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-0.000001}"
# 本用例自己会 kill -9 / 停起节点：这些"测试动作噪声"不该让日志扫描判 FAIL（与合并/TTL skill 同口径）
export CMP_LOG_BENIGN_EXTRA='Failed to CHANGE_REGION_LEADER|transferLeader|Execute FragmentInstance in ConsensusGroup'

# ⚠ EXTRA_CONF 里**不能出现重复键**：cluster_write_conf 会逐键核对落盘值，
#   同名键出现两次时它会拿"第一次的期望值"去比"最终落盘值" ⇒ 必然报"写入不匹配"。
#   所以这里显式拼一份"不含本用例要覆盖的键"的基础串（不要直接用 WAL_EXTRA_DEFAULT 全量）。
WAL_BASE_CONF="wal_mode=${WAL_MODE},wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES}"

# ---------------------------------------------------------------------------
# 1. 本地 helper（全部在用例内，**不改 lib/**）
# ---------------------------------------------------------------------------
# 生成一批写入语句文件。**结尾不写 flush**：本用例必须让数据留在 memtable 里、只靠 WAL 恢复。
#   值 = k+b（b 为批号）⇒ 理论 count/sum 可闭式计算，便于"写入行数不足 ⇒ 场景无效"的硬断言。
walx_gen(){ local db=$1 devs=$2 rows=$3 b=$4 tsbase=$5 out=$6 d k vals ts
  : >"$out"
  for ((d=1; d<=devs; d++)); do
    vals=""
    for ((k=0;k<rows;k++)); do
      ts=$(( tsbase + k * 10 ))
      vals="$vals($ts,$((k+b))),"
      if [ $(( (k+1) % 500 )) -eq 0 ]; then
        printf 'insert into %s.d%d(time,s1) values %s;\n' "$db" "$d" "${vals%,}" >>"$out"; vals=""
      fi
    done
    [ -n "$vals" ] && printf 'insert into %s.d%d(time,s1) values %s;\n' "$db" "$d" "${vals%,}" >>"$out"
  done; }
# 用一个 CLI 会话执行语句文件（每条语句起一个 CLI JVM 会把写入耗时完全掩盖；这里只起 1 个会话）
walx_run(){ local f=$1
  timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 <"$f" 2>&1; }
walx_write(){ local db=$1 devs=$2 rows=$3 b=$4 tsbase=$5 label=$6 f out
  f="$ART/stmt_b${b}.sql"; walx_gen "$db" "$devs" "$rows" "$b" "$tsbase" "$f"
  out=$(walx_run "$f"); printf '%s\n' "$out" >"$ART/write_b${b}.log"
  if printf '%s\n' "$out" | grep -qiE 'IoTDBSQLException|Exception|Msg: [0-9]{3}'; then
    fail "$label 写入报错（细节见 $ART/write_b${b}.log）"
    printf '%s\n' "$out" | grep -iE 'Exception|Msg:' | head -5 | sed 's/^/    | /' >>"$OUT"
  else
    pass "$label 写入完成（语句文件 $(wc -l <"$f" | tr -d ' ') 行）"
  fi; }
# .wal 文件名集合（`wal_ls` 输出是 `<size> <path>`；只取 .wal，排除 checkpoint）
walx_names(){ local h=$1; wal_ls "$h" | awk '{print $2}' | grep -E '\.wal$' | sed 's#.*/##' | grep -v '^$' | sort -u; }
# 魔数命中数（仅作"这确实是 WAL 文件"的证据）：源码给的是 V3="V3-WAL"/V2="V2-WAL"，
# 而 lib 的 wal_magic_cnt 找的是文档口径 'WAL-V2'（在 RC7 上可能恒 0）⇒ 这里两种都认。
walx_magic(){ local h=$1 v
  v=$(sshx "$h" "for f in \$(find $(wal_roots_arg "$h") -name '*.wal' 2>/dev/null); do grep -qaE 'V3-WAL|V2-WAL|WAL-V2' \"\$f\" && echo \"\$f\"; done | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 逐副本 count 串（`select count(s1) from db.**` 每个序列一列 ⇒ 用 row_sum 求和）
walx_pc(){ local db=$1 h out=""
  for h in "${DN[@]}"; do out="$out${h##*.}=$(row_sum "$(sq_node "$h" "select count(s1) from $db.**;")") "; done; echo "$out"; }
# 安全取整（指标值可能是浮点/科学计数，$(( )) 遇到非整数会报错）
walx_int(){ local v=${1:-0}; v=${v%%.*}; case "$v" in ''|*[!0-9-]*) v=0 ;; esac; echo "$v"; }
# 指标：按"标签子串"求和（比按前缀更鲁棒：直方图导出名可能是 `<name>_count` / `<name>_sum`）
walx_metric_tag(){ local h=$1 tag=$2 v
  v=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -F '$tag' | awk '{s+=\$NF} END{printf \"%d\", s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
walx_metric_tag_sum(){ local tag=$1 h s=0 v
  for h in "${DN[@]}"; do v=$(walx_metric_tag "$h" "$tag"); s=$(( s + $(walx_int "$v") )); done; echo "$s"; }
# 等跨 DN WAL 文件数 ≥ min（ASYNC 下 WAL 落盘有 fsync 延迟，写完立刻数可能是 0）；回显最终值
walx_wait_files(){ local min=$1 win=$2 n; local deadline=$(( $(date +%s) + win ))
  while (( $(date +%s) < deadline )); do
    n=$(wal_sum_over_dn wal_file_cnt)
    [ "${n:-0}" -ge "$min" ] && { echo "$n"; return 0; }
    sleep 3
  done
  echo "${n:-0}"; return 1; }
# 等全库 count 达到 want（多序列 count 不能用 lib 的 wait_scalar_tree：它只取第一列）
walx_wait_cnt(){ local want=$1 win=$2 got; local deadline=$(( $(date +%s) + win ))
  while (( $(date +%s) < deadline )); do
    got=$(row_sum "$(sq "select count(s1) from $DB.**;")")
    [ "${got:-0}" = "$want" ] && { echo "$got"; return 0; }
    sleep 5
  done
  echo "${got:-0}"; return 1; }
# 证据（失败时也要有）：逐副本文件数/字节/checkpoint/魔数/清单/指标
walx_evidence(){ local tag=$1 h line
  log "  ---- 证据[$tag]：逐副本（文件数/字节）= $(wal_per_node)"
  log "  ---- 证据[$tag]：WAL 根目录（${DN[0]}）= $(wal_dir_roots "${DN[0]}" | tr '\n' ' ')"
  for h in "${DN[@]}"; do
    log "  [$h] checkpoint=$(wal_ckpt_cnt "$h") 魔数命中=$(walx_magic "$h") 指标file_count=$(walx_int "$(wal_metric_file_cnt "$h")") 指标file_size=$(walx_int "$(wal_metric_file_bytes "$h")")"
    while IFS= read -r line; do [ -n "$line" ] && log "      $line"; done < <(wal_ls "$h" | head -6)
  done; }

# ---------------------------------------------------------------------------
# 2. 相 A：集群准备（压缩关闭 + 小文件阈值）+ 不 flush 写第 1 批
# ---------------------------------------------------------------------------
log "--- 相 A：集群准备（enable_wal_compression=false，wal_file_size_threshold_in_byte=$THRESH；写入期三类合并全关）---"
EXTRA_CONF="$CMP_EXTRA_WRITE,$WAL_BASE_CONF,wal_file_size_threshold_in_byte=$THRESH,enable_wal_compression=false" cmp_cluster_prepare
cmp_compaction_off

APP_A=$(wal_props_get "${DN[0]}" enable_wal_compression)
EFF_A=$(wal_eff "${DN[0]}" enable_wal_compression)
log "  相 A 压缩开关：properties='$APP_A' 运行期生效='$EFF_A'"
if [ "$APP_A" = "false" ]; then
  pass "相 A：enable_wal_compression 落盘为 false（未压缩态成立）"
else
  fail "场景无效：相 A 的 enable_wal_compression 落盘值='$APP_A'（期望 false）"
fi
[ -z "$EFF_A" ] && warn "  show configuration 里读不到 enable_wal_compression ⇒ 只以 properties 落盘值为准"
if [ -n "$EFF_A" ] && [ "$EFF_A" != "false" ]; then
  warn "  相 A 运行期生效值='$EFF_A'（与落盘 false 不一致，记为证据）"
fi

log "--- 相 A：建库 $DB（$DEVS 设备）+ 写第 1 批（不 flush：数据只在 WAL + memtable）---"
cmp_make_tree_db "$DB" "$DEVS"
TSBASE=$(( ($(date +%s) - 3600) * 1000 ))     # 固定基准：避免各节点时钟偏差影响时间分区
walx_write "$DB" "$DEVS" "$ROWS" 1 "$(( TSBASE + 1000000 ))" "相 A 未压缩写入"

N1=$(walx_wait_files 1 "$WIN"); RC1=$?
B1=$(wal_sum_over_dn wal_dir_bytes)
log "  相 A 之后：跨 DN WAL 文件数=$N1（等文件返回 $RC1）总字节=${B1}B"
if [ "${N1:-0}" -gt 0 ]; then
  pass "相 A：WAL 目录确有 .wal 文件（$N1 个，场景有效性成立）"
else
  fail "场景无效：相 A 写完后跨 DN WAL 文件数=0（数据没进 WAL，或 wal_dir_roots 没定位到目录）"
fi
A_NAMES=$(walx_names "${DN[0]}")
log "  相 A 文件名（${DN[0]}）：$(printf '%s' "$A_NAMES" | tr '\n' ' ')"
BADNAME=$(printf '%s\n' "$A_NAMES" | grep -vE '^_[0-9]+-[0-9]+-[01]\.wal$' | tr '\n' ' ')
if [ -z "$BADNAME" ]; then
  pass "  WAL 文件名全部匹配 _<versionId>-<startSearchIndex>-<0|1>.wal（WALFileUtils.java:65-83）"
else
  warn "  WAL 文件名有不符合源码格式的项：$BADNAME（只记录；本用例判据是数据面，不因此 FAIL）"
fi
walx_evidence "相 A"

# ---------------------------------------------------------------------------
# 3. 相 B：打开压缩（源码标 hot_reload）→ 继续写第 2 批 → 共存证据
# ---------------------------------------------------------------------------
log "--- 相 B：切换 enable_wal_compression=true（源码 hot_reload：IoTDBDescriptor.java:2779-2785）---"
RESP=$(wal_set enable_wal_compression true)
log "  SET 返回：$(printf '%s' "$RESP" | tr '\n' ' ' | cut -c1-200)"
sleep 5
APP_B=$(wal_props_get "${DN[0]}" enable_wal_compression)
EFF_B=$(wal_eff "${DN[0]}" enable_wal_compression)
log "  相 B 压缩开关：properties='$APP_B' 运行期生效='$EFF_B'"
if [ "$EFF_B" = "true" ]; then
  pass "相 B：压缩开关热加载生效（运行期 true）"
elif [ -z "$EFF_B" ]; then
  warn "  show configuration 读不到该键（properties='$APP_B'）：按【已落盘、运行期不可见】处理，后续以体积/恢复为证据"
  if [ "$APP_B" != "true" ]; then fail "场景无效：压缩开关既读不到运行期值，落盘值也不是 true（'$APP_B'）"; fi
else
  warn "压缩开关热加载未生效（运行期 '$EFF_B'）⇒ 回退全集群重启让配置生效（共存证据可能因此失效）"
  wal_restart_all
  sleep 5
  EFF_B=$(wal_eff "${DN[0]}" enable_wal_compression)
  if [ "$EFF_B" = "true" ]; then pass "重启后压缩开关生效（运行期 true）"; else warn "重启后 enable_wal_compression 生效值仍为 '$EFF_B'"; fi
fi

walx_write "$DB" "$DEVS" "$ROWS" 2 "$(( TSBASE + 2000000 ))" "相 B 压缩写入"
N2=$(walx_wait_files "$(( ${N1:-0} + 1 ))" "$WIN"); RC2=$?
B2=$(wal_sum_over_dn wal_dir_bytes)
B_NAMES=$(walx_names "${DN[0]}")
log "  相 B 之后：跨 DN WAL 文件数=$N2（相 A=$N1，等文件返回 $RC2）总字节=${B2}B（相 A=${B1}B）"
log "  相 B 文件名（${DN[0]}）：$(printf '%s' "$B_NAMES" | tr '\n' ' ')"
KEEP=$(comm -12 <(printf '%s\n' "$A_NAMES") <(printf '%s\n' "$B_NAMES") | tr '\n' ' ')
NEW=$(comm -13 <(printf '%s\n' "$A_NAMES") <(printf '%s\n' "$B_NAMES") | tr '\n' ' ')
if [ -n "$KEEP" ] && [ -n "$NEW" ]; then
  pass "共存成立：老（未压缩）文件仍在 [$KEEP]，同时出现新文件 [$NEW]"
else
  warn "未能拿到【老文件 + 新文件并存】的目录证据（老=[$KEEP] 新=[$NEW]）：按需求文档口径这只是过程证据缺失（文档未写共存），不判 FAIL；判据仍是数据面"
fi
log "  体积对照（只记录，不判 FAIL：<32KB 的段不压、两相在盘文件会被消费/轮转，不是同口径基线）"
walx_evidence "相 B"

# ---------------------------------------------------------------------------
# 4. 数据面基线 → kill -9 掉电 → 重启 → 校验（本用例的核心）
# ---------------------------------------------------------------------------
# 理论值：值 = k+b ⇒ 单设备单批 sum = rows*b + rows*(rows-1)/2
WANT_CNT=$(( DEVS * ROWS * BATCHES ))
S1=$(( ROWS * 1 + ROWS * (ROWS - 1) / 2 ))
S2=$(( ROWS * 2 + ROWS * (ROWS - 1) / 2 ))
WANT_SUM=$(( DEVS * (S1 + S2) ))
GOT_CNT=$(row_sum "$(sq "select count(s1) from $DB.**;")")
GOT_SUM=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
FP0=$(cmp_fp_tree "$DB")
PC0=$(walx_pc "$DB")
log "  掉电前：count=$GOT_CNT（理论 $WANT_CNT）sum=$GOT_SUM（理论 $WANT_SUM）指纹=$FP0"
log "  掉电前逐副本 count：$PC0"
if [ "${GOT_CNT:-0}" = "$WANT_CNT" ]; then
  pass "掉电前行数完整（$WANT_CNT，场景有效性成立）"
else
  fail "场景无效：掉电前行数=$GOT_CNT（理论 $WANT_CNT）—— 写入不足，恢复结论不可信"
fi
assert_eq "掉电前 sum 与理论值" "$GOT_SUM" "$WANT_SUM"
REC0=$(wal_log_sum 'Successfully recover all wal nodes')
walx_evidence "掉电前"

log "--- 掉电：kill -9 ${DN[0]}（不给 JVM 收尾机会 ⇒ WAL 是唯一凭据）---"
wal_kill9_dn "${DN[0]}" || warn "kill -9 ${DN[0]} 未确认退出（继续尝试重启）"
log "--- 重启 ${DN[0]}（此时进程 enable_wal_compression=true，必须能读老的未压缩 WAL 段）---"
wal_start_dn "${DN[0]}" || fail "DataNode ${DN[0]} 未在 ${DN_RECOVER_WAIT_SEC}s 内 Running"
wal_wait_replay "$DB" "$REPLAY_WIN"
REC1=$(wal_log_sum 'Successfully recover all wal nodes')
log "  `Successfully recover all wal nodes.` 累计：掉电前=$REC0 重启后=$REC1（增量 $(( REC1 - REC0 ))）"
if [ "$(( REC1 - REC0 ))" -gt 0 ]; then
  pass "重启确实走了 WAL 恢复路径（恢复完成文案 +1）"
else
  fail "重启后未见新增的 WAL 恢复完成文案 —— 场景可能退化成【已刷盘恢复】，恢复路径未被验到"
fi

REC_CNT=$(walx_wait_cnt "$WANT_CNT" "$REPLAY_WIN")
FP1=$(cmp_fp_tree "$DB"); PC1=$(walx_pc "$DB")
log "  重启后：count=$REC_CNT（理论 $WANT_CNT）指纹=$FP1"
log "  重启后逐副本 count：$PC1"
assert_eq "重启后全库行数" "$REC_CNT" "$WANT_CNT"
cmp_assert_same "W-13 掉电前后 count/sum 指纹" "$FP0" "$FP1"
cmp_assert_same "W-13 掉电前后逐副本 count" "$PC0" "$PC1"
# 逐副本单独判（不依赖"经 QDN"的口径）：每个 DN 都必须能给出完整数据
for h in "${DN[@]}"; do
  c=$(row_sum "$(sq_node "$h" "select count(s1) from $DB.**;")")
  s=$(row_sum "$(sq_node "$h" "select sum(s1) from $DB.**;")")
  if [ "${c:-0}" = "$WANT_CNT" ] && [ "${s:-0}" = "$WANT_SUM" ]; then
    pass "  $h 恢复后 count/sum 与理论值一致（$c / $s）"
  else
    fail "  $h 恢复后数据不一致：count=$c（理论 $WANT_CNT） sum=$s（理论 $WANT_SUM）"
    walx_evidence "$h 不一致"
  fi
done

# ---------------------------------------------------------------------------
# 5. 相 D：全集群优雅重启（配置里已是压缩开启）→ 三个副本都在新进程里恢复一次
# ---------------------------------------------------------------------------
LEFT=$(wal_sum_over_dn wal_file_cnt)
log "--- 相 D：全集群优雅重启（重启前跨 DN WAL 文件数=$LEFT：>0 说明还有老格式 WAL 要重放）---"
wal_restart_all
wait_cluster_ready || fail "全集群重启后未在 ${CLUSTER_READY_TIMEOUT}s 内就绪"
C2=$(walx_wait_cnt "$WANT_CNT" "$REPLAY_WIN")
FP2=$(cmp_fp_tree "$DB"); PC2=$(walx_pc "$DB")
log "  相 D 之后：count=$C2 指纹=$FP2 逐副本 count：$PC2"
assert_eq "全集群重启后全库行数" "$C2" "$WANT_CNT"
cmp_assert_same "W-13 全集群重启前后指纹" "$FP0" "$FP2"
cmp_assert_same "W-13 全集群重启前后逐副本 count" "$PC0" "$PC2"
walx_evidence "相 D"

# ---------------------------------------------------------------------------
# 6. 收尾三件套（一致性基准用全库 count；装上 WAL 专属异常正则 + WAL 正证据）
# ---------------------------------------------------------------------------
export WAL_EVIDENCE_DB="$DB"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
wal_install_err_pat
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
