#!/bin/bash
# ============================================================================
# W-19 OBJECT 写入的 WAL 恢复（table / object）
#   目标（cases/cases.tsv W-19）：表模型 OBJECT 列用 `to_object(isEOF,offset,content)` **分段写入**
#     （100 字节拆 40/40/20）→ **不 flush** → `kill -9` **全部 DataNode** → 重启 →
#     OBJECT 可读且**与写入前逐字节一致**；WAL 里只有"引用"，真实内容在
#     `${data_dir}/object_data/<dataRegionId>/${B32(table)}/…/${B32(field)}/<timestamp>.bin`
#     ⇒ 判据 = 引用能解析到文件、且文件内容与写入内容逐字节一致。
#   判据（FAIL 只来自数据面 / 场景有效性）：
#     1) 场景有效性（硬）：表建成（`show tables` 命中）；`object_data` 下确实出现 `.bin` 文件（+0 ⇒ 场景无效）；
#        kill -9 前 WAL 非空（本库 identifier 目录口径优先，回退整目录口径）；三个 DN **全部**真的被 kill -9
#        （进程消失）；重启后三个 DN 都回到 Running。
#     2) 数据面（硬，逐字节）：重启后 `count(o)=1`、`LENGTH(o)=100`、`READ_OBJECT(o)` 的渲染与 kill 前**完全一致**，
#        且（若能解析出 hex）**等于写入的 hex 串**；磁盘上 `.bin` 文件的 **md5 == 写入字节的 md5**
#        （100B 全量 / 16B 单段 / 40B 已写部分三种载荷都要命中）⇒ 这是"逐字节一致"的文件级证据。
#     3) 分段语义（硬，文档 §SQL 写入 三条注意事项）：未写完的 OBJECT 查询为 **null**（`count(o)=0`）；
#        `offset != 已写入大小` 的写入**必须报错**（文档明确"本次写入报错"）。
#     4) 只 WARN：报错**文案**（文档只给语义不给文案）；`Wal 中仅存储引用`的非线性量化（R-W107，
#        需要精确到字节的 WAL 增量，短窗口噪声大 ⇒ 只作方向性证据）；`${dataregionid}` 在 tsfile 里是
#        "无用值、每次替换"（附录结论）⇒ 路径**不校验** dataRegionId 精确值，只校验"存在数字目录 + Base32 目录 + .bin"。
#   源码/文档依据：
#     · `feature_extract.md#C.1`（Wal 中仅存储引用、`${data_dir}/object_data`、Base32/RFC4648 路径、
#       每点一个文件、分段三条注意事项、`restrict_object_limit=false` 时 Base32 编码）；
#     · `source_grounding.md §11`：`ObjectNode.serializeToWAL` **只写文件路径 + offset + 长度，不写内容本体**；
#       反序列化时 `TierManager.getAbsoluteObjectFilePath(...)` 懒加载真实文件，找不到就抛 `ObjectFileNotExist`；
#     · `req_sources/design_extract.md §8 TP-29/TP-30`、`REQ_MATRIX.md` R-W03/R-W53/R-W107/R-W108/R-W109/R-W110/R-W115。
#   ⚠️ 本脚本**未在集群实跑**（harness 阶段）。首轮 watch list：
#     ① `object_data` 根目录到底是哪一个：lib 的 `wal_object_root` 只探测 `data/datanode/object_data`、
#        `data/object_data`、`object_data` 三个候选，而 crud/compaction skill 现场看到的是
#        `data/datanode/data/object/<regionId>/…` ⇒ 本用例自带 `w19_obj_roots`（四个候选 + find 兜底），
#        首轮把命中路径打出来并回填。
#     ② CLI 里 BLOB 的渲染形态未知（`READ_OBJECT` 返回 BLOB）：判据写成"kill 前字符串 == 重启后字符串"
#        + "若能解析出 hex 则必须等于写入 hex" 两级；hex 解析不出来时只 WARN（不要据此判 FAIL）。
#     ③ 表模型库名用 `walobj`（**不能**带 root. 前缀：表方言会报 700 mismatched input '.'，
#        2026-10-28 已按实测改掉；本 skill 其它树模型用例仍沿用 root.wal*）。
#     ④ 分段写入必须**同一 (time, dev)**：三段 INSERT 用同一个时间戳与设备；若该版本把同主键多次写当作
#        多行（而非追加分片），`to_object` 的 offset 语义就退化 ⇒ 看 `w19_ins_seg` 的返回与 offset=80 的报错。
#     ⑤ kill -9 全部 DN 后拉起（与 W-04 同构）可能遇到"未激活窗口/注册被拒"⇒ 用例会打逐副本证据；
#        先判断是环境残留还是产品不允许。
#   用法：bash cases/common/wal_object_recovery.sh [--consensus IoTConsensus|IoTConsensusV2]
#   时长大致：集群准备 ~4min + 写入/校验 ~2min + 掉电/拉起 ~4min + 等重放 ~3min + 收尾三件套 ~4min。
#     可调：W19_FRAG_BYTES/W19_SMALL_BYTES/W19_START_WIN_SEC/W19_REPLAY_WIN_SEC/W19_EXTRA_WIN_SEC。
#
# 【RC8 首轮失败根因 + 修法（2026-10-18，用例侧 bug，判据一条没动）】
#   `line 207: FRAGB: unbound variable`（瞬时失败 0s，脚本在第一条 log 就退出）：
#   首行 log 里把 `${FRAG}B` 误写成 `$FRAGB=${FRAG}B` ⇒ `set -u` 下引用未定义变量 FRAGB 直接中断
#   （连集群准备都没进）。修法：改回 `${FRAG}B`（对象总字节数，取值仍来自 W19_FRAG_BYTES，默认 100）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_object_recovery_${DATA_CONSENSUS}"

# 环境兜底：conf/env.conf 没有这三个 TTL 键，而 lib/common.sh 的 cluster_set_conf 会引用它们（set -u 下会中断准备）
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"

DB=walobj                                       # 表模型库名**不能**带 root. 前缀（700 mismatched input '.'）
T1=${W19_T1:-t1}
FRAG=${W19_FRAG_BYTES:-100}                      # 分片写的对象总大小（字节）
SMALL=${W19_SMALL_BYTES:-16}                     # 单段写的小对象大小（字节）
PART=${W19_PART_BYTES:-40}                       # "未写完"的对象：只写前 40 字节（不 EOF）
START_WIN=${W19_START_WIN_SEC:-300}              # 拉起后等 DN 进程/状态
REPLAY_WIN=${W19_REPLAY_WIN_SEC:-300}            # 重启后等重放（数据可见）
EVID_WIN=${W19_EXTRA_WIN_SEC:-60}                # wal_wait_replay 的观测窗口（只作软证据）
BASE=$(( ($(date +%s) - 3600) * 1000 ))          # 时间戳基准（同一天，避免时间分区漂移）
TS_FRAG=$(( BASE + 10 )); TS_SMALL=$(( BASE + 20 )); TS_PART=$(( BASE + 30 )); TS_BAD=$(( BASE + 40 ))

# 载荷：确定性 ASCII ⇒ hex 可离线核算（100 字节 = "0123456789" 重复 10 次）
UNIT="30313233343536373839"                      # "0123456789" 的 hex
HEX_FRAG=""; for _i in 1 2 3 4 5 6 7 8 9 10; do HEX_FRAG="$HEX_FRAG$UNIT"; done
HEX_SMALL="00112233445566778899aabbccddeeff"     # 16 字节
SEG1=${HEX_FRAG:0:80}                            # 40 字节（offset 0，isEOF=false）
SEG2=${HEX_FRAG:80:80}                           # 40 字节（offset 40，isEOF=false）
SEG3=${HEX_FRAG:160:40}                          # 20 字节（offset 80，isEOF=true）
HEX_PART=${HEX_FRAG:0:80}                        # 未写完的 40 字节

W19_EXTRA="wal_mode=${WAL_MODE},enable_wal_compression=${WAL_COMPRESSION},wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${WAL_FILE_THRESHOLD_BYTES},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES},${CMP_EXTRA_WRITE}"

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 载荷 md5（本地核算，用于与磁盘 .bin 逐字节比对；printf 解释 \xNN）----
hex_md5(){ local hex=$1 esc="" i
  for (( i=0; i<${#hex}; i+=2 )); do esc="$esc\\x${hex:i:2}"; done
  printf "$esc" | md5sum | awk '{print $1}'; }
MD5_FRAG=$(hex_md5 "$HEX_FRAG")
MD5_SMALL=$(hex_md5 "$HEX_SMALL")
MD5_PART=$(hex_md5 "$HEX_PART")

# ---- ② object 真实文件根目录（lib 的 wal_object_root + 现场实测补充 + find 兜底）----
w19_obj_roots(){ local h=$1 r
  r=$(wal_object_root "$h"); [ -n "${r:-}" ] && printf '%s\n' "$r"
  sshx "$h" "for p in $DB_DIR/data/datanode/data/object $DB_DIR/data/datanode/object_data $DB_DIR/data/object_data $DB_DIR/data/datanode/data/object_data; do [ -d \"\$p\" ] && echo \"\$p\"; done" 2>/dev/null | tr -d '\r'
  if [ -z "$(wal_object_root "$h")" ] && [ -z "$(sshx "$h" "ls -d $DB_DIR/data/datanode/data/object 2>/dev/null" 2>/dev/null)" ]; then
    sshx "$h" "find $DB_DIR/data -maxdepth 4 -type d -name 'object*' 2>/dev/null | head -3" 2>/dev/null | tr -d '\r'
  fi }
w19_roots(){ w19_obj_roots "$1" | sed '/^$/d' | sort -u; }
w19_obj_cnt(){ local h=$1 r v s=0
  for r in $(w19_roots "$h"); do
    v=$(sshx "$h" "find $r -name '*.bin' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); s=$(( s + ${v:-0} ))
  done
  echo "${s:-0}"; }
w19_obj_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(w19_obj_cnt "$h") )); done; echo "${s:-0}"; }
# 全部 .bin 的 md5 集合（跨所有根目录；用于"内容逐字节一致"的文件级证据）
w19_md5s(){ local h=$1 r
  for r in $(w19_roots "$h"); do
    sshx "$h" "find $r -name '*.bin' -exec md5sum {} + 2>/dev/null | cut -c1-32" 2>/dev/null | tr -d '\r'
  done | sed '/^$/d' | sort -u; }
w19_md5_all(){ local h; for h in "${DN[@]}"; do w19_md5s "$h"; done | sed '/^$/d' | sort -u; }
# 判定与采集分开：**先取一次集合**再在本地比对（每次比对都 ssh 一遍会把用例拖慢到几分钟）
w19_md5_in(){ printf '%s\n' "$1" | grep -qxF "$2"; }
# 相对路径证据（Base32 层级校验用）
w19_rel_paths(){ local h=$1 r
  for r in $(w19_roots "$h"); do
    sshx "$h" "find $r -name '*.bin' -printf '%P\n' 2>/dev/null | head -10" 2>/dev/null | tr -d '\r'
  done | sed '/^$/d' | sort -u; }
w19_b32_hits(){ w19_rel_paths "$1" | grep -cE '(^|/)[A-Z2-7]{2,}=*(/|$)'; }

# ---- ③ 写/读 OBJECT ----
# 写一个分片：w19_ins_seg <dev> <ts> <isEOF true|false> <offset> <hex> <v>
w19_ins_seg(){ local dev=$1 ts=$2 eof=$3 off=$4 hex=$5 v=${6:-1}
  sqt "insert into $DB.$T1 (time, dev, v, o) values ($ts, '$dev', $v, to_object($eof, $off, X'$hex'));" 2>&1; }
w19_rows(){ local where=$1; scalar "$(sqt "select count(o) from $DB.$T1 where $where;")"; }
w19_len(){ local where=$1; scalar "$(sqt "select length(o) from $DB.$T1 where $where;")"; }
w19_obj_render(){ local where=$1; sqt "select o from $DB.$T1 where $where;"; }
w19_blob_render(){ local where=$1; sqt "select read_object(o) from $DB.$T1 where $where;"; }
w19_strip(){ printf '%s\n' "$1" | grep -vE '^[[:alnum:]_:]*DB>([[:space:]]|$)' | grep -vE '^[-+]+$' | grep -E '^\|' | tail -n +2; }
# hex 子串判定（把渲染里的非 hex 字符全部去掉再找期望串；找不到只 WARN，不据此判 FAIL）
w19_hex_in(){ local out=$1 want=$2 flat
  flat=$(printf '%s' "$out" | tr 'A-Z' 'a-z' | tr -cd '0-9a-f')
  case "$flat" in *"$want"*) return 0 ;; *) return 1 ;; esac; }
w19_plain(){ local s=$1; printf '%s' "$s" | tr '\n' ' ' | tr -s ' ' | cut -c1-200; }

# ---- ④ 掉电注入 / 拉起（与 W-04 同构：先全部点火，再等进程/状态）----
w19_kill_all(){ local h n=0 gone=0 pid pids=""
  log "--- 掉电注入：逐个 kill -9 **全部** DataNode（只杀 1 个只验证共识补齐，不是掉电语义）---"
  for h in "${DN[@]}"; do
    pid=$(wal_dn_pid "$h"); pids="$pids${h##*.}=${pid:-none} "
  done
  log "  kill 前各 DN 进程号：$pids"
  for h in "${DN[@]}"; do
    if wal_kill9_dn "$h"; then n=$(( n + 1 )); pass "  kill -9 成功：$h"; else fail "  kill -9 失败：$h"; fi
  done
  assert_eq "  场景有效性：被 kill -9 的 DN 个数（必须=全部副本）" "$n" "${#DN[@]}"
  for h in "${DN[@]}"; do
    if [ -z "$(wal_dn_pid "$h")" ]; then gone=$(( gone + 1 )); else fail "  $h 的 DataNode 进程仍在（kill -9 未生效）"; fi
  done
  assert_eq "  场景有效性：进程确实消失的 DN 个数（掉电语义成立）" "$gone" "${#DN[@]}"; }
w19_fire_dn(){ local h=$1
  log "  启动 DataNode @ $h"
  sshx "$h" "cd $DB_DIR && nohup ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" || warn "  启动 $h 失败"; }
w19_proc_up(){ [ -n "$(wal_dn_pid "$1")" ]; }
w19_dn_state_any(){ local want=$1 h out st
  for h in "${DN[@]}"; do
    out=$(sq_node "$h" 'show cluster;' 2>/dev/null)
    st=$(printf '%s\n' "$out" | awk -F'|' -v ip="$want" '{gsub(/[ \t]/,"",$3);gsub(/[ \t]/,"",$4);gsub(/[ \t]/,"",$5)} $3=="DataNode" && $5==ip {print $4; exit}')
    [ -n "${st:-}" ] && { printf '%s' "$st"; return 0; }
  done
  printf ''; return 1; }
w19_start_all(){ local h n dl
  log "--- 拉起全部 DataNode（先全部点火，再等进程/状态）---"
  for h in "${DN[@]}"; do w19_fire_dn "$h"; done
  dl=$(( $(date +%s) + START_WIN ))
  while (( $(date +%s) < dl )); do
    n=0; for h in "${DN[@]}"; do w19_proc_up "$h" && n=$(( n + 1 )); done
    log "  DataNode 进程数：$n/${#DN[@]}"
    [ "$n" -ge "${#DN[@]}" ] && { pass "  三个 DataNode 进程都已启动"; return 0; }
    sleep 5
  done
  fail "  有 DataNode 进程未在 ${START_WIN}s 内启动"; return 1; }
w19_wait_running(){ local h n dl st
  dl=$(( $(date +%s) + REPLAY_WIN ))
  while (( $(date +%s) < dl )); do
    n=0; for h in "${DN[@]}"; do st=$(w19_dn_state_any "$h"); [ "$st" = "Running" ] && n=$(( n + 1 )); done
    log "  重启后 DataNode Running 计数：$n/${#DN[@]}"
    [ "$n" -ge "${#DN[@]}" ] && { pass "  三个 DataNode 都已 Running（重启完成）"; return 0; }
    sleep 5
  done
  fail "  有 DataNode 未在 ${REPLAY_WIN}s 内回到 Running"; return 1; }

# ---- ⑤ WAL 面（本库 identifier 口径 + 整目录口径）----
w19_ident_dirs(){ sshx "$1" "find $(wal_roots_arg "$1") -mindepth 1 -maxdepth 2 -type d -name '$DB-*' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
w19_db_files(){ local v; v=$(sshx "$1" "find $(wal_roots_arg "$1") -path '*/$DB-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
w19_db_files_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(w19_db_files "$h") )); done; echo "$s"; }
w19_wal_report(){ local tag=$1
  log "  [WAL/$tag] 本库 WAL 文件数=$(w19_db_files_all)（逐副本：$(for h in "${DN[@]}"; do printf '%s=%s ' "${h##*.}" "$(w19_db_files "$h")"; done)）整目录=$(wal_sum_over_dn wal_file_cnt)f/$(wal_sum_over_dn wal_dir_bytes)B；指标 file_count=$(wal_metric_sum_over_dn wal_metric_file_cnt) file_size=$(wal_metric_sum_over_dn wal_metric_file_bytes)"; }

w19_evidence(){ local tag=$1 h
  log "=== 逐副本证据（$tag）==="
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(w19_dn_state_any "$h") 进程：$(sshx "$h" "pgrep -af com.timecho.iotdb.DataNode | head -2" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-160)"
    log "  [$h] object 根目录：$(w19_roots "$h" | tr '\n' ' ') 文件数=$(w19_obj_cnt "$h")"
    log "  [$h] object 相对路径（前 10）："; w19_rel_paths "$h" | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] object md5（前 10）："; w19_md5s "$h" | head -10 | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] WAL 清单（前 10）："; wal_ls "$h" | head -10 | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] log_datanode_all.log 尾部 20 行："; sshx "$h" "tail -20 $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -d '\r' | sed 's/^/        /' >>"$OUT" 2>&1
  done
  log "  show cluster："; sq 'show cluster;' 2>&1 | sed 's/^/      /' >>"$OUT"
  log "  OBJECT 查询回显（d_frag）：$(w19_plain "$(w19_blob_render "dev='d_frag'")")"
  log "=== 逐副本证据结束（$tag）==="; }

# ===========================================================================
# 主流程
# ===========================================================================
log "=== W-19 OBJECT 分片写入 + 全 DN 掉电恢复：库=$DB 表=$T1（对象 ${FRAG}B 分 40/40/20；小对象 ${SMALL}B；未写完 ${PART}B）==="
log "  期望载荷 md5：frag=$MD5_FRAG small=$MD5_SMALL part=$MD5_PART"
log "  WAL 参数组合：$W19_EXTRA"

log "--- ① 集群准备（清集群 → 写 WAL 参数 → 启动；写入期关三类合并；**全程不 flush**）---"
EXTRA_CONF="$W19_EXTRA" cmp_cluster_prepare
log "  合并参数生效值（抽查）：$(cmp_eff_all "${DN[0]}")"
log "  restrict_object_limit=$(wal_props_get "${DN[0]}" restrict_object_limit)（模板默认 false ⇒ Base32 编码路径；读不到只记录）"
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done

log "--- ② 建库 + 建 OBJECT 表（table 方言；表结构：dev TAG / v FIELD / o OBJECT FIELD）---"
out=$(sqt "create database $DB;")
log "  create database：$(w19_plain "$out")"
out=$(sqt "create table $DB.$T1 (dev STRING TAG, v INT64 FIELD, o OBJECT FIELD);")
log "  create table：$(w19_plain "$out")"
printf '%s' "$out" | grep -q 'successfully' || warn "  建表未返回 successfully（可能是已存在或语法差异）⇒ 继续用 show tables 复核"
TBLS=$(sqt "show tables from $DB;")
if printf '%s' "$TBLS" | grep -q "$T1"; then pass "  场景有效性：表 $DB.$T1 已建成"; else fail "  场景无效：表 $DB.$T1 未建成（原始输出：$(w19_plain "$TBLS")）"; fi
printf '%s\n' "$TBLS" | sed 's/^/      /' >>"$OUT"

log "--- ③ 分段写入 OBJECT（同一 (time,dev) 的三段：off 0/40/80，末段 isEOF=true；**不 flush**）---"
O0=$(w19_obj_all); log "  写入前 object 真实文件数=$O0（逐副本：$(for h in "${DN[@]}"; do printf '%s=%s ' "${h##*.}" "$(w19_obj_cnt "$h")"; done)）"
r=$(w19_ins_seg d_frag "$TS_FRAG" false 0 "$SEG1"); log "  d_frag 段1（off=0，isEOF=false）：$(w19_plain "$r")"
printf '%s' "$r" | grep -qE 'Exception|ERROR' && fail "  d_frag 段1 写入报错"
r=$(w19_ins_seg d_frag "$TS_FRAG" false 40 "$SEG2"); log "  d_frag 段2（off=40，isEOF=false）：$(w19_plain "$r")"
printf '%s' "$r" | grep -qE 'Exception|ERROR' && fail "  d_frag 段2 写入报错"
r=$(w19_ins_seg d_frag "$TS_FRAG" true 80 "$SEG3"); log "  d_frag 段3（off=80，isEOF=true）：$(w19_plain "$r")"
printf '%s' "$r" | grep -qE 'Exception|ERROR' && fail "  d_frag 段3 写入报错"
r=$(w19_ins_seg d_small "$TS_SMALL" true 0 "$HEX_SMALL"); log "  d_small 单段（off=0，isEOF=true，${SMALL}B）：$(w19_plain "$r")"
printf '%s' "$r" | grep -qE 'Exception|ERROR' && fail "  d_small 写入报错"
r=$(w19_ins_seg d_part "$TS_PART" false 0 "$HEX_PART"); log "  d_part 只写第一段（off=0，isEOF=false，${PART}B，**故意不写完**）：$(w19_plain "$r")"
printf '%s' "$r" | grep -qE 'Exception|ERROR' && fail "  d_part 首段写入报错"

log "--- ④ 分段语义（硬）：offset != 已写入大小 必须报错 ---"
r=$(w19_ins_seg d_bad "$TS_BAD" false 0 "$HEX_PART"); log "  d_bad 首段（off=0，isEOF=false）：$(w19_plain "$r")"
r=$(w19_ins_seg d_bad "$TS_BAD" false 80 "$SEG3")
log "  d_bad 越界偏移（已写 ${PART}B，却用 off=80）：$(w19_plain "$r")"
if printf '%s' "$r" | grep -qE 'Exception|ERROR|error'; then
  pass "  offset（80）≠ 已写入大小（${PART}）的写入如期报错"
  printf '%s' "$r" | grep -E 'Exception|ERROR|error' | head -3 | sed 's/^/      /' >>"$OUT"
else
  fail "  offset（80）≠ 已写入大小（${PART}）的写入**没有报错**（文档明确要求报错）：$(w19_plain "$r")"
fi

log "--- ⑤ 场景有效性：OBJECT 实体文件必须落盘 + WAL 必须非空（数据只在 MemTable+WAL 上）---"
O1=$(w19_obj_all); OBJ_NEW=$(( O1 - O0 ))
if [ "${OBJ_NEW:-0}" -gt 0 ]; then pass "  场景有效性：object_data 下出现 .bin 文件 +$OBJ_NEW（全局 $O0 → $O1）"
else fail "  场景无效：object_data 下没有新增 .bin 文件（人工核查 root 探测：$(for h in "${DN[@]}"; do printf '%s=[%s] ' "${h##*.}" "$(w19_roots "$h" | tr '\n' ',')"; done)）"; fi
B32H=$(w19_b32_hits "${DN[0]}")
log "  路径层级证据：Base32 形态命中的相对路径数=$B32H（样例：$(w19_rel_paths "${DN[0]}" | head -3 | tr '\n' ' ')）"
log "  lib helper 对照（只作证据：wal_object_root 只探测三个候选根、wal_object_cnt 只按该根计数）：root=[$(wal_object_root "${DN[0]}")] cnt=$(wal_object_cnt "${DN[0]}")；本用例多根口径=$(w19_obj_cnt "${DN[0]}")"
[ "${B32H:-0}" -gt 0 ] && pass "  路径含 Base32（A-Z 2-7）层级，与文档一致（dataRegionId 精确值不校验：tsfile 里是无用值）" \
  || warn "  未在相对路径里认出 Base32 层级（可能是层级/编码差异）⇒ 只记录，不判 FAIL（见 watch list ①）"
for h in "${DN[@]}"; do log "  [$h] 本库 WAL 目录：$(w19_ident_dirs "$h" | tr '\n' ' ')"; done
w19_wal_report "写入后（kill 前）"
DBF0=$(w19_db_files_all); ALLF0=$(wal_sum_over_dn wal_file_cnt)
if [ "${DBF0:-0}" -gt 0 ]; then pass "  场景有效性：本库 WAL 文件数=$DBF0（>0，数据确实只在 WAL+MemTable 上）"
elif [ "${ALLF0:-0}" -gt 0 ]; then warn "  本库 identifier 目录下未找到 WAL（回退整目录口径：$ALLF0 个）⇒ 场景仍成立，仅记录口径差异"
else fail "  场景无效：写入没有产生 WAL（本库=$DBF0，整目录=$ALLF0）——重放无从验证"; fi

log "--- ⑥ 记录 kill 前指纹（行数 / LENGTH / READ_OBJECT 渲染 / 实体文件 md5）---"
FRAG_ROWS0=$(w19_rows "dev='d_frag'"); FRAG_LEN0=$(w19_len "dev='d_frag'")
SMALL_ROWS0=$(w19_rows "dev='d_small'"); SMALL_LEN0=$(w19_len "dev='d_small'")
PART_ROWS0=$(w19_rows "dev='d_part'")
REND_FRAG0=$(w19_blob_render "dev='d_frag'"); REND_SMALL0=$(w19_blob_render "dev='d_small'")
OBJ_REND0=$(w19_obj_render "dev='d_frag'")
log "  d_frag：count(o)=$FRAG_ROWS0 LENGTH(o)=$FRAG_LEN0（期望 1 / $FRAG）；d_small：count(o)=$SMALL_ROWS0 LENGTH(o)=$SMALL_LEN0（期望 1 / $SMALL）"
log "  d_part（未写完）：count(o)=$PART_ROWS0（期望 0=null）"
log "  d_frag 的 OBJECT 列渲染：$(w19_plain "$OBJ_REND0")"
log "  d_frag 的 READ_OBJECT 渲染：$(w19_plain "$REND_FRAG0")"
printf '%s\n' "$REND_FRAG0" | sed 's/^/      /' >>"$OUT"
assert_eq "  数据面：d_frag 行数（count(o)，OBJECT 非空）" "${FRAG_ROWS0:-0}" "1"
assert_eq "  数据面：d_frag LENGTH(o)" "${FRAG_LEN0:-0}" "$FRAG"
assert_eq "  分段语义：未写完的 d_part 查询应为 null（count(o)=0）" "${PART_ROWS0:-0}" "0"
assert_eq "  数据面：d_small 行数" "${SMALL_ROWS0:-0}" "1"
assert_eq "  数据面：d_small LENGTH(o)" "${SMALL_LEN0:-0}" "$SMALL"
MD5_SET0=$(w19_md5_all)
log "  kill 前实体文件 md5 命中：frag=$(w19_md5_in "$MD5_SET0" "$MD5_FRAG" && echo yes || echo no) small=$(w19_md5_in "$MD5_SET0" "$MD5_SMALL" && echo yes || echo no) part=$(w19_md5_in "$MD5_SET0" "$MD5_PART" && echo yes || echo no)"

log "--- ⑦ 掉电注入：kill -9 全部 DataNode ---"
w19_kill_all

log "--- ⑧ 拉起 + 等全部 DN Running ---"
if w19_start_all; then w19_wait_running || w19_evidence "重启后 DN 未 Running"; else w19_evidence "DN 进程未启动"; fi
sq 'show cluster;' >>"$OUT" 2>&1

log "--- ⑨ 等 WAL 重放 + 等 OBJECT 可读（恢复完成无日志/指标信号 ⇒ 只能轮询查询）---"
wal_wait_replay "$DB" "$EVID_WIN"
wait_scalar_table "select count(o) from $DB.$T1 where dev='d_frag';" "1" "$REPLAY_WIN" "重启后 d_frag 可读（等重放）"

log "--- ⑩ 数据面硬断言：逐字节一致（渲染一致 + hex 一致 + 实体文件 md5 一致）---"
FRAG_ROWS1=$(w19_rows "dev='d_frag'"); FRAG_LEN1=$(w19_len "dev='d_frag'")
SMALL_ROWS1=$(w19_rows "dev='d_small'"); SMALL_LEN1=$(w19_len "dev='d_small'")
PART_ROWS1=$(w19_rows "dev='d_part'")
REND_FRAG1=$(w19_blob_render "dev='d_frag'"); REND_SMALL1=$(w19_blob_render "dev='d_small'")
log "  重启后 d_frag：count(o)=$FRAG_ROWS1 LENGTH(o)=$FRAG_LEN1；d_small：count(o)=$SMALL_ROWS1 LENGTH(o)=$SMALL_LEN1；d_part：count(o)=$PART_ROWS1"
log "  重启后 d_frag 的 READ_OBJECT 渲染：$(w19_plain "$REND_FRAG1")"
printf '%s\n' "$REND_FRAG1" | sed 's/^/      /' >>"$OUT"
assert_eq "  重启后 d_frag 行数" "${FRAG_ROWS1:-0}" "$FRAG_ROWS0"
assert_eq "  重启后 d_frag LENGTH(o)（字节数）" "${FRAG_LEN1:-0}" "$FRAG"
assert_eq "  重启后 d_small 行数" "${SMALL_ROWS1:-0}" "$SMALL_ROWS0"
assert_eq "  重启后 d_small LENGTH(o)" "${SMALL_LEN1:-0}" "$SMALL"
assert_eq "  重启后未写完的 d_part 仍为 null" "${PART_ROWS1:-0}" "0"
if [ "$(printf '%s' "$REND_FRAG1")" = "$(printf '%s' "$REND_FRAG0")" ]; then
  pass "  重启前后 READ_OBJECT 渲染完全一致（逐字节一致的客户端侧证据）"
else
  fail "  重启前后 READ_OBJECT 渲染不一致：kill 前=[$(w19_plain "$REND_FRAG0")] 重启后=[$(w19_plain "$REND_FRAG1")]"
fi
if w19_hex_in "$REND_FRAG1" "$HEX_FRAG"; then pass "  READ_OBJECT 内容与写入的 hex 串逐字节一致（${FRAG}B）"
else warn "  READ_OBJECT 渲染里解析不出期望 hex 串（CLI 的 BLOB 展示形态可能不同）⇒ 只 WARN；已用"渲染一致 + LENGTH + 磁盘 md5"三重证据判定"; fi
if w19_hex_in "$REND_SMALL1" "$HEX_SMALL"; then pass "  小对象 READ_OBJECT 内容与写入 hex 一致（${SMALL}B）"
else warn "  小对象渲染里解析不出期望 hex 串 ⇒ 只 WARN（同上口径）"; fi
MD5_SET1=$(w19_md5_all)
MD5_OK=0
for m in "$MD5_FRAG" "$MD5_SMALL" "$MD5_PART"; do w19_md5_in "$MD5_SET1" "$m" && MD5_OK=$(( MD5_OK + 1 )) || warn "  磁盘 .bin 里未找到期望 md5=$m（该载荷的实体文件缺失或内容不一致）"; done
assert_eq "  磁盘 .bin 与写入载荷 md5 一致的数量（frag/small/part 三种载荷，必须 3）" "$MD5_OK" "3"
O2=$(w19_obj_all)
if [ "${O2:-0}" -ge "${O1:-0}" ]; then pass "  重启后实体文件仍在（$O1 → $O2；object 内容不依赖 WAL 重放，WAL 只存引用）"
else warn "  重启后实体文件数下降（$O1 → $O2）——需人工核查是否有 TTL/GC 介入（本用例未设 TTL）"; fi
log "  【只 WARN 的方向性证据】WAL 中「仅存储引用」：对同一数据量，WAL 体积增量远小于对象体积差才算线性关系；"
log "    本用例写入的对象总量=${FRAG}+${SMALL}+${PART}B，WAL 增量见上面 [WAL/...] 行 —— 精确量化需按字节差分，短窗口噪声大 ⇒ 不作判据"

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 打印逐副本证据（便于定责）---"
  w19_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据 + WAL 失败正则 + OBJECT 文件缺失类正则）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
wal_install_err_pat "$(wal_err_pat_extra)|ObjectFileNotExist|Failed to (read|load|recover) object file|ObjectFileCorrupted"
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|Connection reset by peer|Connection refused'
post_checks "select count(o) from $DB.$T1;" table
cmp_case_finish "" table ""
