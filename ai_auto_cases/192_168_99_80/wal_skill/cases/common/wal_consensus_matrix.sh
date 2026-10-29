#!/bin/bash
# ============================================================================
# W-26 双协议对照：同一 WAL 场景（写入 → **不 flush** → kill -9 全部 DN → 重启 → 数据完整 + 压缩开关对照）
#      在 IoTConsensus 与 IoTConsensusV2 下各跑一遍，逐项对照并**如实记录差异**
#
# 【用例】W-26（集合 ha；树模型；库名 root.walproto）
#
# 【覆盖需求】
#   · cases/cases.tsv W-26：同一场景在两个共识协议下各跑一遍（相位间用
#     `DATA_CONSENSUS=IoTConsensusV2 cmp_cluster_prepare` 切换）；逐项对照并如实记录差异；
#     **V2 单副本不落盘是已知现象**，不作为 FAIL 依据；V2 相**不要**设 DISABLE。
#   · docs/req_sources/source_grounding.md：
#       §2 DISABLE 的拒绝条件只在 `IoTConsensus` 或（`IoTConsensusV2` 且 `iot_consensus_v2_mode=stream`）
#          时成立，且只在 `isFirstStart()` 生效；V2 默认 `batch` ⇒ 本用例两相都用 ASYNC（**不碰 DISABLE**）。
#       §3.2 IoTConsensus / IoTConsensusV2 都用 `FirstCreateStrategy`，WALNode 目录 = `<db>-<regionId>`
#          ⇒ "本库 WAL 文件数"可作**库级**隔离口径（跨协议可比）。
#       §4.1/§4.2 压缩是 LZ4、单元="一次 sync 批次的 buffer 段"、**段 < 32KB 不压**、每段头 1 字节
#          标 compressionType ⇒ 压缩对照必须用"大语句"（单批体积 >> 32KB），否则两边都是未压缩。
#       §5.4 SYNC/ASYNC 的差异；§6.2/WALNode.java:671-676 最后一个 WAL 文件始终保留（"文件数≥1"可作证据）。
#       §8.2 恢复链 INFO 文案；§9 权威指标 `file_count{name="wal"}` / `file_size{name="wal"}`。
#       §10.2 默认日志级别 info ⇒ "#10 删除过期 WAL 条数"等 DEBUG 文案**不得**当判据。
#   · docs/DECISIONS.md §2（**V2 下"单副本不落盘"导致的副本间不对称只 WARN**、压缩率只 WARN、
#     耗时只 WARN）、§4.5（IoTConsensusV2 在三份文档里完全未提及 ⇒ 双协议对照**只作差异记录**，
#     不作文档符合性判定）。
#
# 【判据（硬/软分明）】
#   每相（V1 / V2）都做：
#     1) 配置面（硬）：`data_region_consensus_protocol_class` 的**落盘值 == 本相协议**
#        （properties 逐节点核对；`show configuration` 可读时作交叉验证）；`wal_mode` 明确不是 DISABLE
#     2) 场景有效性（硬）：写入后可见 count/sum == 离线核算（DEVS×ROWS×批数）；WAL 目录里**本库**的
#        `.wal` ≥1（库级口径优先，回退整目录口径）；**全部 DN 真的被 kill -9**（进程消失）；
#        重启后全部 DN 回到 Running
#     3) 数据面（硬，唯一能判 FAIL 的）：kill 前落指纹（总 count/sum + `$DB.d1` 全序列 md5），
#        重启恢复后逐项相等 —— **SQL 层数据缺失才 FAIL**（这与"某副本不落盘"不是一回事）
#     4) 压缩开关对照（过程证据；**压缩率只 WARN**）：`enable_wal_compression` 关/开各写一批（都不 flush），
#        记录 WAL 字节增量与 `wal_buffer{name="wal_compress_cost"}`；开关为 hot_reload（SET 不应要求重启）
#   两相对照（差异逐项记录）：
#     5) 记录并对照：写入耗时 / kill→Running 恢复耗时 / 本库 WAL 文件数与字节 / 指标口径文件数 /
#        压缩字节增量与压缩率 / 逐副本 WAL 分布；**逐副本不对称（含 V2 单副本不落盘）只 WARN**
#     6) 收尾：sync lag（**指标存在才判**；V2 口径可能不同，缺失则 WARN 跳过并说明）→ 逐 DN 停机副本一致
#        → CN/DN 日志扫描（停/重启噪声与预期内的 WAL 失败文案已列 benign）
#
# 【注意事项】
#   ⚠ 本脚本**未在集群实跑**（harness 阶段；99.80 正在跑合并长回归，禁止任何启停集群动作）。只做了 `bash -n`。
#   ⚠ 协议切换：`cmp_cluster_prepare` 写 conf 用的是**全局** `CONSENSUS_CLASS`（cmp_load_env 时按初始
#     DATA_CONSENSUS 算好）⇒ 换相时必须**同时**改 `DATA_CONSENSUS` 与 `CONSENSUS_CLASS` 再调用，
#     只改一个会导致"以为跑了 V2、实际起的是 V1"（本用例在每相开头显式设置，并在相内硬核对落盘值）。
#   ⚠ `SKIP_LIFECYCLE=1` 会复用已运行集群、跳过写 conf ⇒ 会让双协议切换静默失效；本用例开头检测到就置 0 并 WARN。
#   ⚠ 恢复相**绝不 flush / 绝不 ensure_closed**（否则数据提前落盘，"WAL 重放"失去意义）；写入只用查询确认可见。
#   ⚠ harness 缺口（本文件不改 lib/conf）：lib/common.sh 的 cluster_set_conf 引用 TTL 专用变量
#     TTL_CHECK_INTERVAL_MS / MAX_EXPIRED_TIME_MS / EXPIRED_DATA_RATIO，而 WAL 的 conf/env.conf 未定义它们；
#     `set -u` 下会让"写配置"整步终止 ⇒ 本文件在 cmp_cluster_prepare 之前给出安全默认值。
#
#   首轮实跑 watch list（最关键 4 条）：
#     ① **V2 相能否起来**：IoTConsensusV2 在 3C3D 下的启动/激活路径与 V1 不同（元数据 skill 踩过
#        "未激活窗口注册被拒"）⇒ 相内会硬核对落盘协议 + 集群 Running 计数，起不来先看逐副本证据。
#     ② **kill -9 全部 DN 后能否重新拉起**（两相都做）：CN 仍在运行，DN 重新加入要过注册/选主；
#        失败时本用例打印逐副本 WAL 清单 + 日志尾部。
#     ③ **V2 的"单副本不落盘"到底长什么样**：逐副本本库 WAL 文件数/字节会被打印；某副本为 0 只 WARN
#        （DECISIONS §2），但 SQL 层 count/sum/md5 缺失会 FAIL（那是真的数据丢失，两码事）。
#     ④ 压缩增量：单批（DEVS×ROWS，默认 6×2000）是否 > 32KB 阈值量级（§4.2 §"段 < 32KB 不压"）；
#        若两相压缩增量接近，先看打印的字节数再决定是否把 W26_ROWS 调大，**不要**直接判产品问题。
#
# 用法： bash cases/common/wal_consensus_matrix.sh
#   可调：W26_DEVS / W26_ROWS / W26_WIN_SEC（等恢复）/ W26_STABLE_SEC（压缩增量稳定窗口）
#
# 【RC8 首轮失败根因 + 修法（2026-10-18，用例侧 bug，判据一条没动）】
#   `line 130/133: h: unbound variable`（每个副本每处各报一次）：`w26_db_files()` / `w26_db_bytes()`
#   写成 `local h v`（只声明、没接参数）⇒ bash 里 `local x` 是"已声明未赋值"，`set -u` 下 `$h` 仍报
#   unbound，且即使不报错也会 ssh 到空主机名 ⇒ 本库 WAL 文件数/字节数恒 0（过程证据全废）。
#   修法：`local h=$1 v`。**只修取值**，WAL/数据面/一致性判据与阈值均未改。
#   ⚠ 同一轮还有两项**不属于**本次修复范围，留给对应负责人：
#     ① `FAIL [V1] 写入后可见 sum: 实际=10×期望`（期望值总和公式，另一处修改负责）；
#     ② `FAIL kill -9 失败 / DN 进程仍在` —— 走的是 lib/wal_ext.sh 的 `wal_kill9_dn`（lib 侧，未改）。
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
cmp_case_init "wal_consensus_matrix_${DATA_CONSENSUS}"

# SKIP_LIFECYCLE 会让双协议切换静默失效（跳过写 conf）⇒ 双协议用例必须自己起集群
if [ "${SKIP_LIFECYCLE:-0}" = "1" ]; then
  warn "SKIP_LIFECYCLE=1 与双协议切换冲突（复用集群会跳过写 conf，导致相内协议不生效）⇒ 本用例强制 SKIP_LIFECYCLE=0"
  SKIP_LIFECYCLE=0
fi

DB=root.walproto
DEVS=${W26_DEVS:-6}
ROWS=${W26_ROWS:-2000}
WIN=${W26_WIN_SEC:-${WAL_REPLAY_WIN_SEC:-300}}
START_WIN=${W26_START_WIN_SEC:-300}
STABLE=${W26_STABLE_SEC:-20}
TOTAL=$(( ${#CN[@]} + ${#DN[@]} ))
BASE_TS=$(( ($(date +%s) - 3600) * 1000 ))
W26_BOFF=0
BATCHES=0
RATIO_MIN=${WAL_COMPRESS_RATIO_MIN:-1.2}

# 两相各自的记录（用于最后逐项对照）
V1_SEC=0; V1_REC=0; V1_FILES=0; V1_BYTES=0; V1_MFILES=0; V1_DU=0; V1_DC=0; V1_PER=""
V2_SEC=0; V2_REC=0; V2_FILES=0; V2_BYTES=0; V2_MFILES=0; V2_DU=0; V2_DC=0; V2_PER=""

# ---------------------------------------------------------------------------
# 局部 helper
# ---------------------------------------------------------------------------
w26_strip_keys(){ local keys=" $1 " kv k out=""
  for kv in $(printf '%s' "$WAL_EXTRA_DEFAULT" | tr ',' ' '); do
    k="${kv%%=*}"
    case "$keys" in *" $k "*) continue ;; esac
    out="$out,$kv"
  done
  printf '%s' "${out#,}"; }
# 写入参数：两相完全相同（库名/规模/值/时间戳公式一致 ⇒ 可比）
W26_EXTRA="$(w26_strip_keys 'wal_mode'),wal_mode=ASYNC,enable_wal_compression=${WAL_COMPRESSION},wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${WAL_FILE_THRESHOLD_BYTES},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES},${CMP_EXTRA_WRITE}"

w26_dn_pid(){ wal_dn_pid "$1"; }
w26_proc_up(){ [ -n "$(w26_dn_pid "$1")" ]; }
w26_running(){ cmp_running_cnt | tr -dc '0-9'; }
w26_exp_count(){ echo $(( DEVS * ROWS * BATCHES )); }
w26_exp_sum(){ local b s=0
  for (( b=1; b<=BATCHES; b++ )); do s=$(( s + ROWS * (ROWS - 1) / 2 + ROWS * b )); done
  echo $(( DEVS * s )); }
w26_rows(){ row_sum "$(sq "select count(s1) from $DB.**;")"; }
w26_sum(){ row_sum "$(sq "select sum(s1) from $DB.**;")"; }
w26_d1_md5(){ sq "select s1 from $DB.d1 order by time;" | data_rows | md5sum | cut -c1-12; }
# 本库 identifier 目录口径（IoTConsensus(V2)：identifier = <database>-<regionId>）
w26_db_files(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w26_db_bytes(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w26_sum_over(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $($f "$h") )); done; echo "$s"; }
w26_per_node(){ local f=$1 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$($f "$h") "; done; echo "$out"; }
# 写入一批（**不 flush**；每个设备一条大 INSERT，走 stdin 避免超长命令行）
w26_write_nf(){ local d k vals ts start out
  W26_BOFF=$(( W26_BOFF + 1 ))
  start=$(( BASE_TS + W26_BOFF * 1000000 ))
  for (( d=1; d<=DEVS; d++ )); do
    vals=""
    for (( k=0; k<ROWS; k++ )); do
      ts=$(( start + k * 10 ))
      vals="$vals($ts,$(( k + W26_BOFF ))),"
    done
    out=$(printf '%s\n' "insert into $DB.d$d(time,s1) values ${vals%,};" | session_tree 2>&1)
    if printf '%s' "$out" | grep -qiE 'Exception|error'; then
      log "  写入失败（d$d）：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-220)"
      return 1
    fi
  done
  BATCHES=$(( BATCHES + 1 ))
  return 0; }
# kill -9 全部 DN（掉电语义；只杀 1 个只验证共识补齐）
w26_kill_all(){ local h n=0 gone=0
  log "--- 掉电注入：kill -9 **全部** DataNode ---"
  for h in "${DN[@]}"; do
    if wal_kill9_dn "$h"; then n=$(( n + 1 )); pass "  kill -9 成功：$h"; else fail "  kill -9 失败：$h"; fi
  done
  assert_eq "  场景有效性：被 kill -9 的 DN 个数（=全部副本）" "$n" "${#DN[@]}"
  for h in "${DN[@]}"; do
    if [ -z "$(w26_dn_pid "$h")" ]; then gone=$(( gone + 1 )); else fail "  $h 的 DataNode 进程仍在（kill -9 未生效）"; fi
  done
  assert_eq "  场景有效性：进程确实消失的 DN 个数（掉电语义成立）" "$gone" "${#DN[@]}"; }
# 用"任一在线 DN"查状态（DN[0] 没起来时 dn_state 会误判）
w26_dn_state_any(){ local want=$1 h out st
  for h in "${DN[@]}"; do
    out=$(sq_node "$h" 'show cluster;' 2>/dev/null)
    st=$(printf '%s\n' "$out" | awk -F'|' -v ip="$want" '{gsub(/[ \t]/,"",$3);gsub(/[ \t]/,"",$4);gsub(/[ \t]/,"",$5)} $3=="DataNode" && $5==ip {print $4; exit}')
    [ -n "${st:-}" ] && { printf '%s' "$st"; return 0; }
  done
  printf ''; return 1; }
w26_start_all(){ local h n=0 dl
  log "--- 拉起全部 DataNode（先全部点火，再等进程/状态）---"
  for h in "${DN[@]}"; do
    sshx "$h" "cd $DB_DIR && nohup ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" || warn "  启动 $h 返回非 0"
  done
  dl=$(( $(date +%s) + START_WIN ))
  while (( $(date +%s) < dl )); do
    n=0; for h in "${DN[@]}"; do w26_proc_up "$h" && n=$(( n + 1 )); done
    log "  DataNode 进程数：$n/${#DN[@]}"
    [ "$n" -ge "${#DN[@]}" ] && break
    sleep 5
  done
  assert_eq "  重启后 DataNode 进程数" "${n:-0}" "${#DN[@]}"
  dl=$(( $(date +%s) + START_WIN ))
  local nn=0 st
  while (( $(date +%s) < dl )); do
    nn=0
    for h in "${DN[@]}"; do st=$(w26_dn_state_any "$h"); [ "$st" = "Running" ] && nn=$(( nn + 1 )); done
    log "  重启后 DataNode Running 计数：$nn/${#DN[@]}"
    [ "$nn" -ge "${#DN[@]}" ] && { pass "  全部 DataNode 已回到 Running"; return 0; }
    sleep 5
  done
  fail "  有 DataNode 未在 ${START_WIN}s 内回到 Running"; return 1; }
w26_evidence(){ local tag=$1 h
  log "=== 逐副本证据（$tag）==="
  for h in "${DN[@]}"; do
    log "  [$h] 进程：$(sshx "$h" "pgrep -af com.timecho.iotdb.DataNode | head -1" 2>/dev/null | tr -d '\r' | cut -c1-160)"
    log "  [$h] WAL 根=[$(wal_dir_roots "$h" | tr '\n' ' ')]；本库文件=$(w26_db_files "$h") 字节=$(w26_db_bytes "$h")"
    wal_ls "$h" | sed 's/^/        /' >>"$OUT" 2>&1
    sshx "$h" "tail -12 $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | sed 's/^/        /' >>"$OUT" 2>&1
  done
  sq 'show cluster;' 2>&1 | sed 's/^/      /' >>"$OUT"; }
# 压缩开关对照（hot_reload；关/开各写一批，都不 flush）
w26_compress_pair(){ local tag=$1 b0 b1 b2 du dc resp
  log "--- 压缩对照（$tag）：关 → 写一批 → 开 → 写一批（都不 flush；段 < 32KB 不压，见 §4.2）---"
  b0=$(wal_metric_sum_over_dn wal_metric_file_bytes)
  resp=$(wal_set enable_wal_compression false)
  log "  SET enable_wal_compression=false 返回：$(printf '%s' "$resp" | cut -c1-200)"
  assert_not_contains "  压缩开关是 hot_reload（模板 :2028），SET 不应要求重启" "$resp" "restart is required"
  w26_write_nf || fail "  压缩对照：关闭压缩相写入失败（场景无效）"
  assert_eq "  压缩对照（关）：可见 count" "$(w26_rows)" "$(w26_exp_count)"
  sleep "$STABLE"
  b1=$(wal_metric_sum_over_dn wal_metric_file_bytes)
  resp=$(wal_set enable_wal_compression true)
  log "  SET enable_wal_compression=true 返回：$(printf '%s' "$resp" | cut -c1-200)"
  w26_write_nf || fail "  压缩对照：开启压缩相写入失败（场景无效）"
  assert_eq "  压缩对照（开）：可见 count" "$(w26_rows)" "$(w26_exp_count)"
  sleep "$STABLE"
  b2=$(wal_metric_sum_over_dn wal_metric_file_bytes)
  du=$(( b1 - b0 )); dc=$(( b2 - b1 ))
  log "  WAL 字节（指标 file_size{name=wal}）：写前=$b0 未压缩后=$b1 压缩后=$b2 ⇒ 未压缩增量=${du}B 压缩增量=${dc}B"
  log "  本库 WAL 目录：文件=$(w26_sum_over w26_db_files) 字节=$(w26_sum_over w26_db_bytes)B 逐副本=$(w26_per_node w26_db_files)"
  if [ "${du:-0}" -gt 0 ] && [ "${dc:-0}" -gt 0 ]; then
    local r
    r=$(awk -v a="$du" -v b="$dc" 'BEGIN{ if (b<=0) {print "n/a"} else {printf "%.2f", a/b} }')
    log "  压缩率（未压缩增量 / 压缩增量）=$r（文档经验值约 3；**只作证据，压缩率一律只 WARN**）"
    awk -v x="${r:-0}" -v y="$RATIO_MIN" 'BEGIN{exit !(x+0 < y+0)}' \
      && warn "  压缩增量收益低于 ${RATIO_MIN}（实测 $r）⇒ 只 WARN：单批体积可能低于 32KB 阈值或数据不可压（可把 W26_ROWS 调大重跑）" \
      || pass "  压缩后 WAL 增量明显小于未压缩（实测 $r ≥ ${RATIO_MIN}）"
  else
    warn "  压缩增量存在 0/负值（未压缩=${du}B 压缩=${dc}B）⇒ 可能被清理线程删除旧 WAL 干扰；只记录，不判 FAIL"
  fi
  W26_DU=$du; W26_DC=$dc; }

# ---------------------------------------------------------------------------
# 单相执行体
# ---------------------------------------------------------------------------
w26_phase(){ local c=$1 tag=$2 cc n t0 t1 fp_pre fp_post c_pre s_pre md5_pre
  log "==================== 相 [$tag]：DATA_CONSENSUS=$c ===================="
  # 协议切换：DATA_CONSENSUS 与 CONSENSUS_CLASS 必须**同时**改（cluster_write_conf 用后者）
  DATA_CONSENSUS="$c"; cc="$(ttl_consensus_class "$c")"; CONSENSUS_CLASS="$cc"
  export DATA_CONSENSUS CONSENSUS_CLASS
  log "  本相协议类=$CONSENSUS_CLASS（写入 conf 的 data_region_consensus_protocol_class）"
  case "${WAL_MODE:-ASYNC}" in
    DISABLE) fail "  场景无效：WAL_MODE 被配成关闭 WAL 的取值（本用例两相都必须是 ASYNC/SYNC）" ;;
    *) pass "  本相 wal_mode=${WAL_MODE}（未关闭 WAL；V2 相同样不设关闭取值）" ;;
  esac
  t0=$(date +%s)
  EXTRA_CONF="$W26_EXTRA" cmp_cluster_prepare
  n=$(w26_running)
  assert_eq "  [$tag] 集群就绪（Running/ReadOnly 行数）" "${n:-0}" "$TOTAL"
  local h pv
  for h in "${DN[@]}"; do
    pv=$(wal_props_get "$h" data_region_consensus_protocol_class)
    assert_eq "  [$tag] 落盘协议核对 $h（来源：$DB_DIR/conf/iotdb-system.properties）" "${pv:-<无>}" "$CONSENSUS_CLASS"
  done
  log "  [$tag] 运行期协议（show configuration）= '$(wal_eff "${DN[0]}" data_region_consensus_protocol_class)'"

  log "--- [$tag] 造库 + 写入第 1 批（**不 flush**：数据只在 MemTable + WAL 上）---"
  cmp_make_tree_db "$DB" "$DEVS"
  BATCHES=0; W26_BOFF=0
  t0=$(date +%s)
  w26_write_nf || fail "  [$tag] 写入失败（场景无效）"
  t1=$(date +%s)
  log "  [$tag] 写入耗时 $(( t1 - t0 ))s（耗时只作证据，不作门禁）"
  assert_eq "  [$tag] 写入后可见 count（离线核算 DEVS×ROWS）" "$(w26_rows)" "$(w26_exp_count)"
  assert_eq "  [$tag] 写入后可见 sum（离线核算）" "$(w26_sum)" "$(w26_exp_sum)"
  fp_pre=$(cmp_fp_tree "$DB"); md5_pre=$(w26_d1_md5)
  c_pre=$(w26_rows); s_pre=$(w26_sum)
  log "  [$tag] kill 前指纹：$fp_pre d1_md5=$md5_pre"
  local dfiles dbytes
  dfiles=$(w26_sum_over w26_db_files); dbytes=$(w26_sum_over w26_db_bytes)
  log "  [$tag] WAL 面：本库 files=$dfiles bytes=${dbytes}B（逐副本=$(w26_per_node w26_db_files)）；整目录 files=$(wal_sum_over_dn wal_file_cnt) 指标 files=$(wal_metric_sum_over_dn wal_metric_file_cnt)"
  if [ "${dfiles:-0}" -ge 1 ]; then
    pass "  [$tag] 场景有效：本库 WAL 文件数=$dfiles（数据确实只在 WAL+MemTable 上）"
  elif [ "$(wal_sum_over_dn wal_file_cnt)" -ge 1 ]; then
    warn "  [$tag] 本库 identifier 目录下未找到 WAL（整目录口径非空）⇒ 场景仍成立，库级隔离口径不可用（记录）"
  else
    fail "  [$tag] 场景无效：没有产生 WAL（本库=$dfiles、整目录=$(wal_sum_over_dn wal_file_cnt)）"
  fi

  log "--- [$tag] 掉电 + 拉起 + 等恢复（恢复完成无日志信号，只能轮询查询）---"
  t0=$(date +%s)
  w26_kill_all
  if w26_start_all; then :; else w26_evidence "$tag DN 未 Running"; fi
  wal_wait_replay "$DB" 30
  local dl got
  dl=$(( $(date +%s) + WIN ))
  got=0
  while (( $(date +%s) < dl )); do
    got=$(w26_rows)
    log "  [$tag] 等重放可见：count=${got:-?}（目标 ${c_pre:-?}）"
    [ "${got:-0}" = "${c_pre:-0}" ] && break
    sleep 5
  done
  t1=$(date +%s)
  local rec
  rec=$(( t1 - t0 ))
  log "  [$tag] kill→数据可见的恢复耗时 ${rec}s（只作对照证据）"
  log "--- [$tag] 数据面硬判据：恢复后 count/sum/d1 指纹必须与 kill 前一致 ---"
  fp_post=$(cmp_fp_tree "$DB")
  assert_eq "  [$tag] 恢复后 count（缺失=Fail 数据丢失）" "$(w26_rows)" "${c_pre:-0}"
  assert_eq "  [$tag] 恢复后 sum" "$(w26_sum)" "${s_pre:-0}"
  cmp_assert_same "  [$tag] 恢复后 count/sum 指纹" "$fp_pre" "$fp_post"
  assert_eq "  [$tag] 恢复后 $DB.d1 全序列 md5" "$(w26_d1_md5)" "$md5_pre"
  [ "$fail_flag" -eq 0 ] || w26_evidence "$tag 有失败项"
  dfiles=$(w26_sum_over w26_db_files); dbytes=$(w26_sum_over w26_db_bytes)
  log "  [$tag] 恢复后 WAL 面：本库 files=$dfiles bytes=${dbytes}B（逐副本=$(w26_per_node w26_db_files)）"
  local asym
  asym=$(w26_per_node w26_db_files | tr ' ' '\n' | sed '/^$/d' | awk -F= '{print $2}' | sort -u | wc -l | tr -d ' ')
  [ "${asym:-0}" -le 1 ] && pass "  [$tag] 逐副本本库 WAL 文件数一致（$asym 种取值）" \
    || warn "  [$tag] 逐副本 WAL 文件数不一致（$(w26_per_node w26_db_files)）⇒ **只 WARN**：V2 下「单副本不落盘」是已知现象（DECISIONS §2），SQL 层数据完整才是判据"
  log "  [$tag] WAL 恢复链文案行数=$(wal_log_sum 'Start recovering wal|Successfully recover all wal nodes')（弱证据，仅证明恢复子系统在动）"

  log "--- [$tag] 压缩开关对照 ---"
  w26_compress_pair "$tag"

  # 记录本相数据，供两相逐项对照
  if [ "$tag" = "V1" ]; then
    V1_REC=$rec; V1_FILES=$dfiles; V1_BYTES=$dbytes; V1_DU=$W26_DU; V1_DC=$W26_DC
    V1_MFILES=$(wal_metric_sum_over_dn wal_metric_file_cnt); V1_PER=$(w26_per_node w26_db_files)
  else
    V2_REC=$rec; V2_FILES=$dfiles; V2_BYTES=$dbytes; V2_DU=$W26_DU; V2_DC=$W26_DC
    V2_MFILES=$(wal_metric_sum_over_dn wal_metric_file_cnt); V2_PER=$(w26_per_node w26_db_files)
  fi
  wal_metrics_dump "${DN[0]}"
  return 0; }

# ===========================================================================
# 两相：IoTConsensus → IoTConsensusV2
# ===========================================================================
log "=== W-26 双协议对照：库 $DB；${DEVS} 设备 × ${ROWS} 点/批（单批体积需 > 32KB 才能看出压缩，见 §4.2）==="
log "  写入参数（两相完全相同）：$W26_EXTRA"
w26_phase "IoTConsensus" "V1"
w26_phase "IoTConsensusV2" "V2"

log "--- 逐项对照（差异如实记录；耗时/压缩率/逐副本不对称一律只 WARN）---"
log "  项                        V1(IoTConsensus)   V2(IoTConsensusV2)"
log "  kill→数据可见恢复耗时(s)  ${V1_REC}            ${V2_REC}"
log "  恢复后本库 WAL 文件数     ${V1_FILES}          ${V2_FILES}"
log "  恢复后本库 WAL 字节       ${V1_BYTES}          ${V2_BYTES}"
log "  指标口径 WAL 文件数       ${V1_MFILES}         ${V2_MFILES}"
log "  未压缩增量字节            ${V1_DU}             ${V2_DU}"
log "  压缩增量字节              ${V1_DC}             ${V2_DC}"
log "  逐副本本库 WAL 文件数     ${V1_PER}"
log "                            ${V2_PER}"
log "  判读：两相的**硬判据**（场景有效性 + kill -9 后 SQL 层数据完整）都必须成立；"
log "        逐副本不对称 / 恢复耗时 / 压缩率差异只作差异记录（DECISIONS §2/§4.5：V2 在三份文档中未提及，"
log "        「单副本不落盘」是已知现象，不作 FAIL 依据；压缩率与耗时只 WARN）。"

# ===========================================================================
# 收尾：sync lag（指标存在才判）→ 副本一致性 → 日志扫描
# ===========================================================================
log "--- 收尾 1/3：sync lag（先探测指标是否存在：V2 口径可能不同，缺失则 WARN 跳过）---"
SLS=0
for h in "${DN[@]}"; do
  SLS=$(( SLS + $(curl -s -m 8 "http://$h:$DN_METRIC_PORT/metrics" 2>/dev/null | grep -c 'type="syncLag"') ))
done
log "  syncLag 指标序列数=$SLS"
if [ "${SLS:-0}" -gt 0 ]; then
  check_sync_lag || true
else
  warn "  syncLag 指标在当前共识下缺失（序列数=0；V2 口径可能不同）⇒ 跳过 sync lag 检查，用副本一致性 + 日志扫描兜底"
fi
log "--- 收尾 2/3：副本一致性（逐个停 DN 比对）---"
consistency_check "select count(s1) from $DB.d1 order by time;" tree
log "--- 收尾 3/3：CN/DN 日志异常分析 ---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance in ConsensusGroup|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader|Connection refused|Connection reset by peer|Failed to recover from WAL|Fail to read WALEntry'
check_logs
cmp_case_finish "" tree ""
