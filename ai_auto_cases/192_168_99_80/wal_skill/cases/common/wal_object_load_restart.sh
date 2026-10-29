#!/bin/bash
# ============================================================================
# W-20 导入 OBJECT 数据后重启一致性（table / object）
#   目标（cases/cases.tsv W-20）：走 **LOAD/导入路径** 把带 OBJECT 的 TsFile 导进来 → `wal_restart_all`
#     完整重启 → 数据面（count / LENGTH / READ_OBJECT 内容）与元数据面（列集合/类型）一致。
#   判据（FAIL 只来自数据面 / 场景有效性）：
#     1) 场景有效性（硬）：`object_data` 下确实出现 `.bin` 文件（OBJ_NEW>0）；表建成；写入/导入的行可见；
#        完整重启后 6/6 节点 Running。
#     2) 数据面（硬）：重启后 count(o) 与 LENGTH(o) 与重启前一致；`READ_OBJECT(o)` 的渲染与重启前**完全一致**；
#        磁盘 `.bin` 的 md5 集合仍包含写入载荷的全部 md5（内容逐字节一致）。
#     3) 元数据面（硬）：重启后表仍在 `show tables`；`information_schema.columns`（不可用时回退 `desc`）
#        的「列名 + 类型」集合与重启前**完全一致**（OBJECT 列仍是 OBJECT）。
#     4) **不可构造就如实降级（硬约束，不是 FAIL）**：文档写明"导入导出一期在二期评审补充"
#        （`feature_extract.md#C.1`/`#C.4`：`导入（LOAD）：二期评审时继续补充`）⇒ 本用例按"探测 → 判定 →
#        降级"三段式：先探测 `LOAD` 语句在两种方言下是否可用、再尝试真的导入；**任何一步不可用就
#        `warn "场景不可构造（原因+证据）"` 并打印试过的命令与错误，不判 FAIL**；然后用"普通写入路径 +
#        完整重启"作为**替代场景**（明确标注），仍做数据/元数据一致性的硬断言。
#     5) 只 WARN：LOAD 的语义细节（一期未定义：是否必须可恢复、object 文件如何随 tsfile 迁移）；
#        重建表后 `information_schema` 的可用性；导入耗时。
#   源码/文档依据：
#     · `source_grounding.md §11`（OBJECT 的 WAL 只存引用；`ObjectNode.serializeToWAL` 只写路径+offset+长度）；
#     · LOAD 的真实语法来自源码：`IoTDBSqlParser.g4:1431-1453 loadFile : LOAD fileName ((…) | WITH (…))`；
#       object 目录参数键 `LoadTsFileConfigurator.OBJECT_FILE_PATHS_KEY = "object-file-path"`（:271），
#       校验要求是"已存在的目录"（:273-288）；缺省时搜索根 = `<tsfile 父目录>/<tsfile 去掉后缀>`（`LoadSingleTsFileNode.java:154-171`）；
#       导入侧按 `new File(objectFileSearchRoot, sourceRelativePath)` 逐个校验存在与长度（`TsFileSplitter.java:1089-1117`）；
#       `auto-create-schema` 默认 true、`tsfile-is-physical-path` 默认 false（`LoadTsFileConfigurator.java:197-268`）；
#       客户端导入工具就是这么拼 SQL 的：`AbstractImportData.java:126-143 buildLoadTsFileSql`。
#     · 去重（REQ_MATRIX §5）：OBJECT 的**删除与 GC**归 `crud_skill` CR-11/CR-12、**TTL 与实体回收**归
#       `compaction_skill` CO-41 ⇒ 本用例只用"导入 + 重启"这一面；`drop table` 只作"造空表以便真导入"的
#       **前置动作**，不对删除/GC/墓碑/回收做任何断言。
#   ⚠️ 本脚本**未在集群实跑**（harness 阶段）。首轮 watch list：
#     ① `LOAD` 在本构建的表方言下到底能不能执行：首轮看 ⑤ 的两条探测输出（`700 ... mismatched input` =
#        语句不支持；`file not found/does not exist` = 语句可用、路径不可用）。
#     ② staging 布局：`/tmp/walobjld_load/<t1>.tsfile` + `/tmp/walobjld_load/obj/…`（后者是**整棵 object 根目录**
#        的拷贝，因为 TsFile 里的引用是相对路径 ⇒ 必须保持相对层级）；若现场 object 根目录与 lib 探测的
#        候选不一致，`w20_obj_roots` 会打印命中的路径并回填。
#     ③ LOAD 可能**移动/消费**源文件（active-load 机制会把 tsfile 挪进 load 目录）⇒ 每轮导入前都会**重新 stage**。
#     ④ 真导入用"drop table → 重新 stage → LOAD"，因此表会被删掉再建：若第二次 LOAD 失败，用例会用普通写入
#        路径把 12 行补回来（替代场景），**不会**因为"表空了"报一堆假 FAIL。
#     ⑤ 完整重启用 `wal_restart_all`（stop+start，不清 data）：重启后要等 CN 激活 + DN 注册，窗口 600s。
#   用法：bash cases/common/wal_object_load_restart.sh [--consensus IoTConsensus|IoTConsensusV2]
#   时长大致：集群准备 ~4min + 写入/落盘 ~2min + 导入探测/导入 ~2min + 重启 ~4min + 收尾三件套 ~4min。
#     可调：W20_DEVS/W20_ROWS/W20_OBJ_BYTES/W20_STAGE_DIR/W20_DRAIN_WIN_SEC。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_object_load_restart_${DATA_CONSENSUS}"

# 环境兜底：conf/env.conf 没有这三个 TTL 键，而 lib/common.sh 的 cluster_set_conf 会引用它们（set -u 下会中断准备）
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"

DB=walobjld                                     # 表模型库名**不能**带 root. 前缀（700 mismatched input '.'）
T1=${W20_T1:-t1}
DEVS=${W20_DEVS:-3}
ROWS=${W20_ROWS:-4}
OBJ=${W20_OBJ_BYTES:-32}                         # 每个对象 32 字节
STAGE=${W20_STAGE_DIR:-/tmp/walobjld_load}       # 每个 DN 上的 staging 目录（tsfile + obj/）
DRAIN_WIN=${W20_DRAIN_WIN_SEC:-180}
BASE=$(( ($(date +%s) - 3600) * 1000 ))
TOTAL_ROWS=$(( DEVS * ROWS ))
UNIT="6162636465666768696a6b6c6d6e6f707172737475767778797a3031323334"   # "abcdefghijklmnopqrstuvwxyz01234" 的 hex
HEX_LEN=$(( OBJ * 2 ))

W20_EXTRA="wal_mode=${WAL_MODE},enable_wal_compression=${WAL_COMPRESSION},wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${WAL_FILE_THRESHOLD_BYTES},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES},${CMP_EXTRA_WRITE}"

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 载荷（每个 (dev,row) 一个确定性对象：首字节 = d*16+r，其余取 UNIT）----
hex_md5(){ local hex=$1 esc="" i
  for (( i=0; i<${#hex}; i+=2 )); do esc="$esc\\x${hex:i:2}"; done
  printf "$esc" | md5sum | awk '{print $1}'; }
w20_hex(){ local d=$1 r=$2 pfx
  pfx=$(printf '%02x' $(( d * 16 + r )))
  printf '%s%s' "$pfx" "${UNIT:0:$(( HEX_LEN - 2 ))}"; }

# ---- ② object 真实文件根目录 / 计数 / md5（与 W-19 同口径）----
w20_obj_roots(){ local h=$1 r
  r=$(wal_object_root "$h"); [ -n "${r:-}" ] && printf '%s\n' "$r"
  sshx "$h" "for p in $DB_DIR/data/datanode/data/object $DB_DIR/data/datanode/object_data $DB_DIR/data/object_data $DB_DIR/data/datanode/data/object_data; do [ -d \"\$p\" ] && echo \"\$p\"; done" 2>/dev/null | tr -d '\r' | sed '/^$/d' | sort -u; }
w20_obj_cnt(){ local h=$1 r v s=0
  for r in $(w20_obj_roots "$h"); do v=$(sshx "$h" "find $r -name '*.bin' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); s=$(( s + ${v:-0} )); done
  echo "${s:-0}"; }
w20_obj_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(w20_obj_cnt "$h") )); done; echo "${s:-0}"; }
w20_md5s(){ local h=$1 r
  for r in $(w20_obj_roots "$h"); do sshx "$h" "find $r -name '*.bin' -exec md5sum {} + 2>/dev/null | cut -c1-32" 2>/dev/null | tr -d '\r'; done | sed '/^$/d' | sort -u; }
w20_md5_all(){ local h; for h in "${DN[@]}"; do w20_md5s "$h"; done | sed '/^$/d' | sort -u; }
# 判定与采集分开：**先取一次集合**再在本地比对（每次比对都 ssh 一遍会把用例拖慢到几分钟）
w20_md5_in(){ printf '%s\n' "$1" | grep -qxF "$2"; }

# ---- ③ 表/数据读接口 ----
# 计数接口**必须把非数字字符滤掉**：表被删掉时查询会报错，scalar 会返回空/错误文本，
# 直接进算术展开会报 "operand expected"（本次刻意会删表，所以必须防）。
w20_rows(){ local w=$1 v; v=$(scalar "$(sqt "select count(o) from $DB.$T1 where $w;")"); printf '%s' "$(printf '%s' "${v:-}" | tr -dc '0-9')"; }
w20_len(){ local w=$1; scalar "$(sqt "select length(o) from $DB.$T1 where $w;")"; }
w20_blob(){ local w=$1; sqt "select read_object(o) from $DB.$T1 where $w;"; }
w20_rows_all(){ local w=0 d r n
  for (( d=1; d<=DEVS; d++ )); do for (( r=1; r<=ROWS; r++ )); do n=$(w20_rows "dev='d$d' and v=$r"); w=$(( w + ${n:-0} )); done; done
  echo "$w"; }
w20_fp(){ local d r out=""
  for (( d=1; d<=DEVS; d++ )); do
    for (( r=1; r<=ROWS; r++ )); do
      out="$out$(w20_len "dev='d$d' and v=$r")|$(w20_blob "dev='d$d' and v=$r" | grep -E '^\|' | tail -1 | tr -s ' ')"
    done
  done
  printf '%s' "$out" | md5sum | awk '{print $1}'; }
# information_schema 不可用时回退 desc；**函数内不要 log**（stdout 会被 $(...) 捕获进列集合，破坏前后比对）
w20_cols(){ local out
  out=$(sqt "select column_name, data_type from information_schema.columns where table_name='$T1' order by ordinal_position;")
  if printf '%s' "$out" | grep -qE 'Exception|ERROR'; then out=$(sqt "desc $DB.$T1;"); fi
  printf '%s\n' "$out" | grep -E '^\|' | grep -vE '^\|[-+ ]+\|$' | sed -E 's/[[:space:]]+/ /g' | sort; }
w20_ins(){ local d=$1 r=$2 ts=$3 hex=$4
  sqt "insert into $DB.$T1 (time, dev, v, o) values ($ts, 'd$d', $r, to_object(true, 0, X'$hex'));" 2>&1; }
w20_insert_all(){ local d r ts rc=0 out
  for (( d=1; d<=DEVS; d++ )); do
    for (( r=1; r<=ROWS; r++ )); do
      ts=$(( BASE + d * 1000 + r * 10 ))
      out=$(w20_ins "$d" "$r" "$ts" "$(w20_hex "$d" "$r")")
      printf '%s' "$out" | grep -qE 'Exception|ERROR' && { rc=1; log "    写入 d$d/v$r 报错：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"; }
    done
  done
  return $rc; }

# ---- ④ TsFile 定位 + staging ----
w20_tsfiles(){ local h=$1
  sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
w20_tsfile_one(){ local h=$1 f
  f=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-" 2>/dev/null | tr -d '\r')
  printf '%s' "${f:-}"; }
# 每个 DN 上：把本库最新 TsFile + 整棵 object 根目录拷到 staging；回显 "ok=<tsfile 名>" 或 "fail"
w20_stage(){ local h=$1 f base r
  f=$(w20_tsfile_one "$h")
  [ -n "${f:-}" ] || { printf 'fail=no-tsfile'; return 1; }
  base=$(basename "$f")
  sshx "$h" "rm -rf $STAGE; mkdir -p $STAGE/obj" >/dev/null 2>&1
  sshx "$h" "cp -a '$f' $STAGE/'$base'" >/dev/null 2>&1 || { printf 'fail=cp-tsfile'; return 1; }
  for r in $(w20_obj_roots "$h"); do sshx "$h" "cp -a '$r'/. $STAGE/obj/" >/dev/null 2>&1; done
  printf 'ok=%s' "$base"; return 0; }
w20_stage_all(){ local h out rc=0
  for h in "${DN[@]}"; do
    out=$(w20_stage "$h")
    log "    staging @ $h：$out"
    case "$out" in ok=*) ;; *) rc=1 ;; esac
  done
  return $rc; }
w20_stage_ls(){ local h=$1
  sshx "$h" "ls -1 $STAGE 2>/dev/null | head -5; echo ---; find $STAGE/obj -name '*.bin' 2>/dev/null | head -5" 2>/dev/null | tr -d '\r'; }

# ---- ⑤ LOAD 执行（两种方言都记下来；**用退出码判成功**，不要把 log 输出当返回值）----
w20_load_table(){ sqt "$1" 2>&1; }
w20_load_tree(){ sq "$1" 2>&1; }
w20_try_load(){ local sql=$1 out
  log "    尝试（table 方言）：$sql"
  out=$(w20_load_table "$sql"); log "      → $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  printf '%s' "$out" | grep -qE 'Exception|ERROR' || return 0
  log "    尝试（tree 方言）：$sql"
  out=$(w20_load_tree "$sql"); log "      → $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  printf '%s' "$out" | grep -qE 'Exception|ERROR' || return 0
  return 1; }

w20_evidence(){ local tag=$1 h
  log "=== 逐副本证据（$tag）==="
  log "  staging 内容（${DN[0]}）："; w20_stage_ls "${DN[0]}" | sed 's/^/      /' >>"$OUT" 2>&1
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(dn_state "$h") 进程：$(sshx "$h" "pgrep -af com.timecho.iotdb.DataNode | head -2" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-160)"
    log "  [$h] 本库 TsFile：$(w20_tsfiles "$h" | tr '\n' ' ' | cut -c1-300)"
    log "  [$h] object 根目录：$(w20_obj_roots "$h" | tr '\n' ' ') 文件数=$(w20_obj_cnt "$h")"
    log "  [$h] load 目录痕迹：$(sshx "$h" "find $DB_DIR/data/datanode/load -maxdepth 2 2>/dev/null | head -5" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-200)"
    log "  [$h] log_datanode_all.log 中 load 相关尾部："; sshx "$h" "grep -ahiE 'load|object' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -8" 2>/dev/null | tr -d '\r' | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] log_datanode_all.log 尾部 15 行："; sshx "$h" "tail -15 $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -d '\r' | sed 's/^/        /' >>"$OUT" 2>&1
  done
  log "  show cluster："; sq 'show cluster;' 2>&1 | sed 's/^/      /' >>"$OUT"
  log "=== 逐副本证据结束（$tag）==="; }

# ===========================================================================
# 主流程
# ===========================================================================
log "=== W-20 导入 OBJECT 后完整重启一致性：库=$DB 表=$T1（${DEVS} 设备 × ${ROWS} 行 = $TOTAL_ROWS 个 ${OBJ}B 对象）==="
log "  WAL 参数组合：$W20_EXTRA"

log "--- ① 集群准备（清集群 → 写 WAL 参数 → 启动；写入期关三类合并）---"
EXTRA_CONF="$W20_EXTRA" cmp_cluster_prepare
log "  合并参数生效值（抽查）：$(cmp_eff_all "${DN[0]}")"
log "  LOAD 相关配置：load_tsfile_source_path_check_enable=$(wal_props_get "${DN[0]}" load_tsfile_source_path_check_enable)（默认 false ⇒ 允许从任意目录导入）"
log "  restrict_object_limit=$(wal_props_get "${DN[0]}" restrict_object_limit)（读不到只记录）"
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done

log "--- ② 建库 + 建 OBJECT 表（dev TAG / v FIELD / o OBJECT FIELD）---"
out=$(sqt "create database $DB;"); log "  create database：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
out=$(sqt "create table $DB.$T1 (dev STRING TAG, v INT64 FIELD, o OBJECT FIELD);"); log "  create table：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
if sqt "show tables from $DB;" | grep -q "$T1"; then pass "  场景有效性：表 $DB.$T1 已建成"; else fail "  场景无效：表 $DB.$T1 未建成"; fi

log "--- ③ 写入 OBJECT（每个 (dev,row) 一个 32B 对象；**随后 flush 使 TsFile 落盘**，供导入使用）---"
O0=$(w20_obj_all)
if w20_insert_all; then pass "  写入完成（$TOTAL_ROWS 行 OBJECT）"; else fail "  写入报错（见上面的行内报错）"; fi
sqt "flush;" >/dev/null 2>&1
ensure_closed "$DB" 3 25 || warn "  有 DN 的 TsFile 未在窗口内落盘（导入前置条件可能不满足，下面会如实记录）"
R0=$(w20_rows_all)
wait_scalar_table "select count(o) from $DB.$T1;" "$TOTAL_ROWS" "$DRAIN_WIN" "写入后 OBJECT 行数（$TOTAL_ROWS）"
O1=$(w20_obj_all); OBJ_NEW=$(( O1 - O0 ))
if [ "${OBJ_NEW:-0}" -gt 0 ]; then pass "  场景有效性：object_data 下出现 .bin 文件 +$OBJ_NEW（全局 $O0 → $O1；期望 ≥ $TOTAL_ROWS）"
else fail "  场景无效：object_data 下没有 .bin 文件（根目录探测：$(for h in "${DN[@]}"; do printf '%s=[%s] ' "${h##*.}" "$(w20_obj_roots "$h" | tr '\n' ',')"; done)）"; fi
FP0=$(w20_fp); COLS0=$(w20_cols); MD5_EXP=0; MD5_SET0=$(w20_md5_all)
for (( d=1; d<=DEVS; d++ )); do for (( r=1; r<=ROWS; r++ )); do w20_md5_in "$MD5_SET0" "$(hex_md5 "$(w20_hex "$d" "$r")")" && MD5_EXP=$(( MD5_EXP + 1 )); done; done
log "  重启前指纹：行数=$R0 内容指纹(md5)=$FP0 磁盘 md5 命中=$MD5_EXP/$TOTAL_ROWS"
log "  重启前列集合（information_schema/desc）："; printf '%s\n' "$COLS0" | sed 's/^/      /' >>"$OUT"
log "  本库 TsFile：$(for h in "${DN[@]}"; do printf '%s=%s ' "${h##*.}" "$(w20_tsfiles "$h" | wc -l | tr -d ' ')"; done)"
assert_eq "  数据面：写入后 OBJECT 行数" "${R0:-0}" "$TOTAL_ROWS"

log "--- ④ 探测 1：LOAD 语句在本构建/本方言下是否可用（缺文件路径，只看错误类型）---"
P1="load '/tmp/walobjld_probe_missing.tsfile';"
o1=$(w20_load_table "$P1"); log "  table 方言 $P1 → $(printf '%s' "$o1" | tr '\n' ' ' | cut -c1-240)"
o2=$(w20_load_tree "$P1");  log "  tree  方言 $P1 → $(printf '%s' "$o2" | tr '\n' ' ' | cut -c1-240)"
LOAD_SUPPORTED=0
printf '%s' "$o1$o2" | grep -qiE 'mismatched input|extraneous input|syntax error|Unsupported|不支持' || LOAD_SUPPORTED=1
if [ "$LOAD_SUPPORTED" = 1 ]; then pass "  LOAD 语句可解析（不是语法错）⇒ 导入路径值得一试"
else warn "  LOAD 语句在本构建/本方言下不被解析（原始输出见上）⇒ 导入路径不可构造，下面仍会按三段式尝试并如实记录"; fi

log "--- ⑤ 探测 2 + 真导入：staging（tsfile + 整棵 object 根目录）→ LOAD → （若可用）drop table 后重新导入 ---"
if w20_stage_all; then
  pass "  场景构造：三个 DN 都完成了 staging（$STAGE）"
  STAGE_LS=$(w20_stage_ls "${DN[0]}"); log "  staging 内容（${DN[0]}）：$(printf '%s' "$STAGE_LS" | tr '\n' ' ' | cut -c1-300)"
  BASE_F=$(w20_stage "${DN[0]}" | sed 's/^ok=//')
  LOAD_SQL="load '$STAGE/$BASE_F' with ('object-file-path'='$STAGE/obj');"
  log "  导入语句（与客户端工具 AbstractImportData.buildLoadTsFileSql 同形）：$LOAD_SQL"
  if w20_try_load "$LOAD_SQL"; then
    pass "  LOAD 执行成功（导入路径可构造）"
    # 真导入：删表 → 重新 stage → 再 LOAD（auto-create-schema 默认 true）
    out=$(sqt "drop table $DB.$T1;"); log "  drop table（真导入的前置动作，**不对删除/GC 做任何断言**）：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
    wait_scalar_table "select count(o) from $DB.$T1;" "0" 60 "删表后行数应为 0" || true
    w20_stage_all || warn "  重新 stage 失败（源文件可能已被 LOAD 消费/移动）"
    if w20_try_load "$LOAD_SQL"; then
      R3=$(w20_rows_all); log "  真导入后可见行数=$R3（期望 $TOTAL_ROWS）"
      assert_eq "  导入路径（LOAD）后 OBJECT 行数" "${R3:-0}" "$TOTAL_ROWS"
      IMPORT_OK=1
    else
      warn "  场景不可构造：第二轮 LOAD（删表后真导入）未成功 ⇒ 按需求不判 FAIL；下面用普通写入路径补回数据作为**替代场景**"
      IMPORT_OK=0
    fi
  else
    warn "  场景不可构造：LOAD 未成功（试过的命令与错误见上面 ④/⑤ 两段：$LOAD_SQL）⇒ 按需求不判 FAIL；转入替代场景"
    IMPORT_OK=0
  fi
else
  warn "  场景不可构造：无法完成 staging（找不到本库 TsFile 或拷贝失败；证据见下）⇒ 按需求不判 FAIL；转入替代场景"
  w20_evidence "staging 失败"
  IMPORT_OK=0
fi

log "--- ⑥ 替代场景兜底：若导入路径不可构造或表已空，则用普通写入路径写回同一批数据（明确标注） ---"
if [ "${IMPORT_OK:-0}" != 1 ]; then
  RCUR=$(w20_rows_all 2>/dev/null)
  if [ "${RCUR:-0}" -lt "$TOTAL_ROWS" ]; then
    warn "  替代场景：导入路径不可构造（或表已被删空，当前行数=${RCUR:-0}）⇒ 用普通 INSERT 路径写回 $TOTAL_ROWS 行 OBJECT，再走完整重启一致性校验"
    if w20_insert_all; then pass "  替代场景写入完成（$TOTAL_ROWS 行 OBJECT）"; else fail "  替代场景写入报错"; fi
    wait_scalar_table "select count(o) from $DB.$T1;" "$TOTAL_ROWS" "$DRAIN_WIN" "替代场景写入后行数"
  else
    log "  当前行数=${RCUR}（无需补写）"
  fi
  FP0=$(w20_fp); COLS0=$(w20_cols); R0=$TOTAL_ROWS
  log "  替代场景的重启前指纹：行数=$R0 内容指纹=$FP0"
else
  FP0=$(w20_fp); COLS0=$(w20_cols); R0=$(w20_rows_all)
  log "  导入路径的重启前指纹：行数=$R0 内容指纹=$FP0"
fi
MD5_SET1=$(w20_md5_all); MD5_EXP=0
for (( d=1; d<=DEVS; d++ )); do for (( r=1; r<=ROWS; r++ )); do w20_md5_in "$MD5_SET1" "$(hex_md5 "$(w20_hex "$d" "$r")")" && MD5_EXP=$(( MD5_EXP + 1 )); done; done
log "  重启前（导入/替代写入后）磁盘 .bin 的 md5 命中：$MD5_EXP/$TOTAL_ROWS"

log "--- ⑦ 完整重启（wal_restart_all = cluster_stop + cluster_start，不清 data）---"
wal_restart_all

log "--- ⑧ 重启后：数据面（硬）+ 元数据面（硬）---"
wait_scalar_table "select count(o) from $DB.$T1;" "$TOTAL_ROWS" "$DRAIN_WIN" "重启后 OBJECT 行数（等恢复）"
TBLS1=$(sqt "show tables from $DB;")
printf '%s' "$TBLS1" | grep -q "$T1" && pass "  元数据面：重启后表 $DB.$T1 仍在" || fail "  元数据面：重启后表 $DB.$T1 不见了（输出：$(printf '%s' "$TBLS1" | tr '\n' ' ' | cut -c1-200)）"
R4=$(w20_rows_all); L4=$(w20_len "dev='d1' and v=1"); REND4=$(w20_blob "dev='d1' and v=1")
log "  重启后行数=$R4；d1/v1 的 LENGTH(o)=$L4；READ_OBJECT 渲染（前 160 字符）：$(printf '%s' "$REND4" | tr '\n' ' ' | cut -c1-160)"
assert_eq "  数据面：重启后 OBJECT 行数" "${R4:-0}" "${R0:-0}"
assert_eq "  数据面：重启后单个对象 LENGTH(o)" "${L4:-0}" "$OBJ"
FP1=$(w20_fp); COLS1=$(w20_cols)
if [ "$FP1" = "$FP0" ]; then pass "  数据面：全部 $TOTAL_ROWS 个对象的（LENGTH + READ_OBJECT 渲染）指纹与重启前完全一致（$FP1）"
else fail "  数据面：重启前后内容指纹不一致（前=$FP0 后=$FP1）——需人工核查"; fi
MD5_SET2=$(w20_md5_all); MD5_OK=0
for (( d=1; d<=DEVS; d++ )); do for (( r=1; r<=ROWS; r++ )); do w20_md5_in "$MD5_SET2" "$(hex_md5 "$(w20_hex "$d" "$r")")" && MD5_OK=$(( MD5_OK + 1 )); done; done
log "  重启后磁盘 .bin 的 md5 命中：$MD5_OK/$TOTAL_ROWS"
assert_eq "  数据面：重启后磁盘 .bin 与写入载荷 md5 一致的对象数" "$MD5_OK" "$TOTAL_ROWS"
if [ "$COLS1" = "$COLS0" ]; then pass "  元数据面：列集合（列名+类型）重启前后完全一致"; printf '%s\n' "$COLS1" | sed 's/^/      /' >>"$OUT"
else fail "  元数据面：列集合重启前后不一致（前=[$(printf '%s' "$COLS0" | tr '\n' ' ')] 后=[$(printf '%s' "$COLS1" | tr '\n' ' ')]）"; fi
if printf '%s' "$COLS1" | grep -qi 'OBJECT'; then pass "  元数据面：OBJECT 列仍标注为 OBJECT 类型"; else warn "  列集合里没看到 OBJECT 字样（information_schema/desc 的列名口径可能不同）⇒ 只记录"; fi
log "  重启后 object 实体文件数=$(w20_obj_all)（重启前 $O1）；WAL：$(wal_sum_over_dn wal_file_cnt)f/$(wal_sum_over_dn wal_dir_bytes)B"
if [ "${IMPORT_OK:-0}" = 1 ]; then pass "  场景判定：**导入（LOAD）路径已构造成功**，本用例在其上完成「完整重启一致性」验证"
else warn "  场景判定：导入（LOAD）路径**不可构造**（原因与试过的命令见 ④/⑤ 段）⇒ 本轮以「普通写入路径 + 完整重启」作替代场景；按需求不判 FAIL（一期文档：导入导出在二期评审补充）"; fi

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 打印逐副本证据（便于定责）---"
  w20_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据 + WAL 失败正则 + OBJECT/导入 失败类正则）---"
# 说明：本用例**故意**用"不存在的 tsfile 路径 + 可能失败的 LOAD"探测导入能力，这些错误会落进 DN 日志。
# 为避免"场景不可构造"被误判成产品 FAIL，把**本用例探测动作会产生**的导入类文案列为 benign；
# 功能判据仍由数据面（行数/LENGTH/READ_OBJECT 指纹/磁盘 md5）与元数据面（列集合）承担。
log "  日志面 benign 追加（本用例探测动作预期产生）：walobjld_probe_missing / Failed to load tsfile / LoadFileException / ObjectFileNotExist|Corrupted / Failed to execute statement LoadTsFile"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
wal_install_err_pat "$(wal_err_pat_extra)|ObjectFileNotExist|ObjectFileCorrupted|Failed to (read|load|recover|transfer) object file|Failed to load tsfile|Failed to execute statement LoadTsFile"
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|Connection reset by peer|Connection refused|Auto create or verify schema error|walobjld_probe_missing|Failed to load tsfile|LoadFileException|ObjectFileNotExist|ObjectFileCorrupted|Failed to execute statement LoadTsFile'
post_checks "select count(o) from $DB.$T1;" table
cmp_case_finish "" table ""
