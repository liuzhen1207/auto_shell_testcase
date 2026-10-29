#!/bin/bash
# ============================================================================
# CR-13 Load 时 LastCache 四策略正确性（UPDATE / UPDATE_NO_BLOB / CLEAN_DEVICE / CLEAN_ALL）
#   覆盖需求点：R-53（现状是"加载时清空整个 LastCache"，频繁 Load 会让缓存近乎失效）、
#               R-54（改为部分更新，并需提供部分清除策略）、R-55（`last_cache_operation_on_load`
#                     四取值 + 默认 UPDATE_NO_BLOB）、R-56（`cache_last_values_for_load`）、
#               R-57（`cache_last_values_memory_budget_in_byte`）、R-61（`iterAllTimeseriesMetadata`
#                     接口——**不可观测**，见 §4-C2）、R-62（`TsFileLastReader` 接口——**不可观测**）、
#               R-63（`TsFileResource.lastValues` 预缓存）、R-64（用 lastValues 或 TsFileLastReader
#                     更新 LastCache）、R-65（UPDATE_NO_BLOB：Blob 序列**失效**而不是更新）、
#               R-66（CLEAN_DEVICE：按设备级时间索引清设备；否则回退）、R-67（CLEAN_ALL）、
#               R-68（三种策略下 Load 前后 Last 查询的正确性）、R-72（配置模板落地值 + restart 生效）
#   规格出处：crud_skill/docs/REQ_MATRIX.md §3 CR-13；§1 R-53..R-57/R-61..R-68/R-72 逐字原文；
#             §4-C1/C2/C3/C4/C5（不可观测/不可构造清单）。
#
# ---------------------------------------------------------------------------
# 【源码事实（本地源码树 D:\IDEA\timechodb_src\v20121\timechodb，git HEAD 67bb5ced2b；
#   RC7 是该 HEAD 的祖先，且 7c61428..HEAD 对 dataregion/modification 零改动）】
#   · 三键都在**启动时**读取：IoTDBDescriptor.java:3461-3475
#     `LastCacheLoadStrategy.valueOf(properties.getProperty("last_cache_operation_on_load","UPDATE"))`
#     ⇒ ① 取值非法会让 DataNode **起不来**（不是运行时回退 ⇒ 本用例**不构造**非法值相）；
#        ② `effectiveMode: restart`（模板 iotdb-system.properties.template:2894-2913 逐字：
#           `last_cache_operation_on_load=UPDATE_NO_BLOB` / `cache_last_values_for_load=true` /
#           `cache_last_values_memory_budget_in_byte=4194304`；`enable_last_cache=true` 在 :1353）。
#        ⚠️ **代码兜底默认是 UPDATE，而模板落地值是 UPDATE_NO_BLOB** ⇒ 本用例每一相都把三键
#           **显式写进 properties** 并逐节点校验生效值，绝不依赖默认值（`show configuration` 只列
#           properties 里出现过的键，见 compaction_skill/SKILL.md 第 101 行的实测）。
#   · 策略生效点：DataRegion.onTsFileLoaded（:5223-5256），**仅在 `enable_last_cache=true` 且
#     `!isFromConsensus` 时执行**：
#       UPDATE / UPDATE_NO_BLOB → updateLastCache(:5264)；CLEAN_ALL → TreeDeviceSchemaCacheManager.cleanUp()；
#       CLEAN_DEVICE → 时间索引为 ArrayDeviceTimeIndex 时**逐设备** invalidateLastCache，
#                      **否则走 `TreeDeviceSchemaCacheManager.invalidateDatabaseLastCache(databaseName)`**
#                      ⇒ 实现是"**按库失效**"，不是 R-66 逐字写的"回退到 CLEAN_ALL"（设计-实现偏差，
#                        记为 WARN + 证据；该分支无法用 SQL/配置稳定构造，见 §4-C3）。
#   · UPDATE 的两条路径（决定 UPDATE 与 UPDATE_NO_BLOB 的差别）：
#       `newTsFileResource.getLastValues() != null` ⇒ 用预缓存最新值更新（:5268-5287）；
#       `== null` ⇒ 构造 `TsFileLastReader(path, asyncIO=true, ignoreBlob=(策略==UPDATE_NO_BLOB))`（:4948-4964）
#       再流式更新。预缓存由 TsFileResourceUtils.updateTsFileResource(:445-520) 在
#       `cacheLastValuesForLoad=true` 时填充，**BLOB / OBJECT 序列被填成 `null` 值对**（:497-500），
#       而 DataRegion 调的 TableDeviceSchemaCache 4 参重载默认 `invalidateNull=false`
#       （TableDeviceSchemaCache.java:312-344）⇒ null 被**忽略**（既非更新也非失效）。
#       ⇒ 这正是 R-56"如果设置为真，即使是 UPDATE 策略也不会更新 Blob 类型的最新值"的落地形态，
#         也是本用例在**结果面**区分"更新 / 不更新"的构造依据。
#   · `TsFileLastReader` **不在 iotdb 源码树内**：真实位置是 TsFile 库的
#     `org.apache.tsfile.read.reader.TsFileLastReader`（DataRegion.java:201 import）——
#     矩阵 §4-C2 的"待查源码"在此更正。
#   · 官方用例已定位：`integration-test/src/test/java/org/apache/iotdb/db/it/IoTDBLoadLastCacheIT.java`
#     （矩阵 §3 CR-13 出处里"未在本地源码树定位到"更正）。它用 Java `ITsFileWriter`/`TsFileGenerator`
#     造 load 源文件、@Parameters **只跑 CLEAN_ALL/UPDATE/CLEAN_DEVICE 三策略**，断言"load 后 LAST 的
#     时间/值必须变成新数据"；**没有 UPDATE_NO_BLOB 相、也没有 cache_last_values_for_load 对照**。
#     本用例用**纯 SQL** 复刻同一语义（补 UPDATE_NO_BLOB 与 ccl 对照），并补 CLEAN_DEVICE 回退的源码级说明。
#
# ---------------------------------------------------------------------------
# 【场景构造（纯 SQL，不需要 Java 工具）—— 关键：让"缓存里的旧值"≠"load 后的真值"】
#   每相、每模型（表 + 树）各一组：
#     ① 写"基线"数据（时间戳更早、值 BASE_VAL；含目标设备 + 对照设备）→ flush → 等闭合（TsFile#1）；
#     ② 写"更新"数据（时间戳更晚、值 NEW_VAL；**只写目标设备**）→ flush → 等闭合（TsFile#2）；
#     ③ 把 TsFile#2 从 DN 数据目录拷到**各 DN 的同一 /tmp 路径**（load 必须从数据目录之外加载——
#        源码/官方 IT 均明确"数据目录内会被拒绝"），并做 sha256 三节点一致性校验；
#     ④ `DELETE ... WHERE time >= <更新段起点>` 让"更新"数据从**可见面**消失：TsFile#2 仍在原处，
#        其删除只记在它自己的 .mods2 里，而被加载的**副本**没有 .mods2 ⇒ 加载后可见
#        （与官方 IT"load 新数据后 LAST 必须变新"的语义一致）；
#     ⑤ 查一次 LAST（**把 LastCache 填成基线值**）+ 断言 load 前可见值就是基线；
#     ⑥ `load` 那个副本（表模型带 `with ('database-name'=...)`，键名见 LoadTsFileConfigurator.java:117-118；
#        官方 IT 同款写法）；
#     ⑦ 立即（不重启、不清缓存）查 LAST ⇒ R_post；再 `CLEAR CACHE` 后查 LAST ⇒ R_clear（真值）；
#     ⑧ 逐副本（三个 DN）各查一次 R_post 比较一致性。
#
#   **判据为什么能区分"更新 / 不更新 / 清理范围"**（§4-C5：命中率不可观测 ⇒ 用可证伪设计）：
#     · R_clear != R_pre（硬）：证明 load 真的让数据变新（否则场景未成立）；
#     · R_post == R_clear（硬）：策略把缓存维护到了与真值一致——这正是 R-53/R-54 要解决的问题；
#       R_post == R_pre（旧值）而 R_clear 是新值 ⇒ 缓存陈旧 ⇒ FAIL（附三份原始结果）；
#     · FAIL 时追加**归因硬证据**：把表/库改成 `need_last_cache=false` 后重查 LAST（关掉 Last 优化、
#       直接读文件）——若此时 == R_clear，则证明差异**来自 LastCache**；
#     · BLOB 序列单独判定：UPDATE_NO_BLOB 必须"不返回旧值"（R-65）、UPDATE+ccl=false 必须"返回新值"
#       （R-63/R-64 流式读路径）；UPDATE+ccl=true 时源码给 BLOB 填 null（R-56）⇒ 该相只判非 BLOB 序列；
#     · **"更新 vs 失效 vs 清理范围"在结果面本就不可区分**（无命中率观测面，§4-C5）⇒ 区分证据 =
#       逐节点生效配置值（硬判）+ BLOB 相行为（硬判）+ CR-14 的加载/查询耗时方向性（弱判据）。
#   ⚠️ **诚实边界**：本用例**没有**"缓存确实被使用"的正向观测面；只有当 R_post != R_clear 时，
#      用 need_last_cache=false 归因才能给出"缓存被使用且陈旧"的硬证据（W3）。
#
# ---------------------------------------------------------------------------
# 【判据（硬判 / WARN）】
#   硬判：S1 每相三键逐节点生效值 == 写入值；S2 R-72 模板静态校验（三键 + enable_last_cache）；
#         S3 三键 restart-only（SET 提示 restart is required 且生效值不变）；
#         S4 场景有效性：load 前可见值就是基线值（且不含更新值）、更新段 DELETE 后确实不可见；
#         S5 load 源文件必须是"本次新产出的那一个 TsFile"（文件列表差集恰 1）且三节点 sha256 一致；
#         S6 load 成功（无 507/1100 schema 类错误；数据面行数增加 == 更新段行数）；
#         S7 R_clear 必须含 NEW_VAL 且 != R_pre；三副本 R_post 完全一致；
#         S8 核心：R_post == R_clear（每策略 × 每模型）；UPDATE_NO_BLOB 的 BLOB 序列不得返回旧值；
#            UPDATE+ccl=false 的 BLOB 序列必须更新到真值；
#         S9 未包含在 load 文件里的对照设备，其可见 LAST 全程不变（CLEAN_DEVICE 的"范围"证据）；
#         S10 跨重启数据面不丢（每个后续相的 restart 之后复核前相的行数）；
#         S11 收尾三件套（post_checks）。
#   WARN：W1 CLEAN_DEVICE 的"无设备级时间索引 ⇒ 回退"分支不可稳定构造（§4-C3）⇒ 只写源码证据；
#         W2 UPDATE+ccl=true 时 BLOB/OBJECT 可能保留旧值（R-56 明说"不更新 Blob"）⇒ 只记录；
#         W3 "缓存是否真被使用"无正向观测面（§4-C5）⇒ 只在 FAIL 时归因；
#         W4 表/树方言的 BLOB 列或 BLOB 字面量不可用 ⇒ BLOB 相降级为"只跑非 BLOB 序列"并记录；
#         W5 `TsFileLastReader`/`iterAllTimeseriesMetadata` 的接口级断言需只读 Java agent（本任务禁止）⇒ 不可观测。
#
# 用法： bash cases/common/cr_load_lastcache.sh [--consensus IoTConsensus|IoTConsensusV2]
# 预估耗时：约 20~26 分钟（4 个策略相，其中 3 次三节点重启 + 每相 2 个模型的场景 + 收尾三件套）
#
# ★ harness 修复记录（RC8 首轮实跑暴露，全部是**用例侧**问题；共 29 条 FAIL 里 26 条出自下面 ①/②）：
#   ① **复制 load 源文件到各 DN 的那一步一直失败**：`ssh "$SSH_OPTS" …` 给 `$SSH_OPTS` 加了引号，
#      ssh 会把 `-o BatchMode=yes -o ConnectTimeout=15` 整串当成**一个** `-o` 参数 ⇒ 退出码 255，
#      而紧跟其后的 `2>/dev/null` 把报错吞了 ⇒ 各副本 sha256 全空、`load` 实际加载的是一个**空目录**
#      （于是"load 后行数未增加"）。现改为不加引号 + 判 ssh 退出码 + 逐文件校验 sha256（实测复现见
#      `cr14_stage` 同修）。
#   ② "基线批未产生**唯一**新 TsFile"：一个库可能跨多个 data region，一次 flush 每 region 各产 1 个
#      文件 ⇒ "恰好 1 个"在相 2/3/4 恒不成立。现改为"取全部新增文件"（load 支持整目录），并**只收
#      非空且 `.resource` 已落的文件**（空占位文件的 sha256 是 e3b0c442…，曾被当成源文件）。
#   ③ 树模型设备跨相位共用（`$DBR.$TAG`）⇒ 第 2 相起"更新段已删后行数 == ROWS"必然不成立（实测
#      8/12/16 vs 4），而"load 后 ≥ ROWS*2"又会因历史行**假通过**。现改为**本相基线**口径
#      （$T_BASE / $T_BASE+ROWS）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_load_lastcache_${DATA_CONSENSUS}"

# ---------------------------------------------------------------------------
# 规模与配置（顶部变量，可用环境变量覆盖）
# ---------------------------------------------------------------------------
DBT=${CR13_DBT:-cr13b}            # 表模型库
DBR=${CR13_DBR:-root.cr13}        # 树模型库（selftest 约定：树库名 root.cr*）
TAG=${CR13_TAG:-da}               # 目标设备/tag（会被 load 的新数据覆盖）
TAG2=${CR13_TAG2:-db}             # 对照设备/tag（只出现在基线批 ⇒ 不得被 load 影响）
ROWS=${CR13_ROWS:-4}              # 每设备每批点数
STEP_MS=${CR13_STEP_MS:-10}       # 点间隔（ms）
GAP_MS=${CR13_GAP_MS:-300000}     # 基线批与更新批的时间差（5 分钟；两批都在过去）
BASE_VAL=${CR13_BASE_VAL:-111111} # 基线值
NEW_VAL=${CR13_NEW_VAL:-999999}   # 更新值
BUDGET_BIG=${CR13_BUDGET_BIG:-4194304}   # 模板默认预算（4MB）
WAIT_FILE_SEC=${CR13_WAIT_FILE_SEC:-90}  # 等 TsFile 落盘/闭合的窗口
LOAD_SEC=${CR13_LOAD_SEC:-300}           # 等 load 生效的窗口
TPL_KEYS='last_cache_operation_on_load cache_last_values_for_load cache_last_values_memory_budget_in_byte'
# 全局返回值（**不要**用 $( ) 捕获会 log 的 helper：本 harness 的 log/pass/fail 都写 stdout）
CR13_NEWFILE=""; CR13_NEWFILES=""; CR13_SRCPATH=""; CR13_HAS_BLOB_T=1; CR13_TRIAGE=""

# ---------------------------------------------------------------------------
# helper
# ---------------------------------------------------------------------------
cr13_last(){ local dialect=$1 sql=$2
  if [ "$dialect" = table ]; then norm_result "$(sqt "$sql")"; else norm_result "$(sq "$sql")"; fi; }
cr13_last_node(){ local node=$1 dialect=$2 sql=$3
  if [ "$dialect" = table ]; then norm_result "$(sqt_node "$node" "$sql")"; else norm_result "$(sq_node "$node" "$sql")"; fi; }
cr13_clear_cache(){ sq "clear cache;" >/dev/null 2>&1; sqt "clear cache;" >/dev/null 2>&1; }
cr13_tbl_rows(){ local v; v=$(scalar "$(sqt "select count(*) from $1.$2;")"); printf '%s' "${v:-0}"; }
cr13_tree_rows(){ local v
  v=$(sq "select s1 from $DBR.$1 order by time;" 2>/dev/null | table_rows | wc -l | tr -dc '0-9'); printf '%s' "${v:-0}"; }
# 该节点上该库的 TsFile **全路径**（只要非空文件：flush 收尾会同时落下空的占位数，0 字节的不可能是 load 源）
cr13_tsfiles_node(){ sshx "$1" "find $DB_DIR/data/datanode/data -path '*/$2/*' -name '*.tsfile' -size +0 -printf '%p\n' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
cr13_new_files(){ printf '%s\n' "$2" | grep -vxF "$(printf '%s\n' "$1" | sed '/^$/d')" | sed '/^$/d'; }
# `.resource` 是否存在（= 该 TsFile 已 flush 收尾/可被 load）—— 用完整路径问
cr13_has_res(){ local n; n=$(sshx "$1" "test -f '$2.resource' && echo 1 || echo 0" 2>/dev/null | tr -dc '0-9'); printf '%s' "${n:-0}"; }
# 逐节点生效值校验（S1）
cr13_assert_eff(){ local key=$1 want=$2 h got ok=1
  for h in "${DN[@]}"; do
    got=$(cmp_eff "$h" "$key")
    [ "$got" = "$want" ] || { ok=0; log "    $h $key=$got（期望 $want）"; }
  done
  if [ "$ok" = 1 ]; then pass "  S1：三节点生效值 $key=$want"; else fail "  S1：$key 生效值不一致（期望 $want，见上）"; fi; }
# 重启到指定策略（**保留数据**：stop → 写 conf → start，不 clean）
cr13_restart(){ local st=$1 ccl=$2 bud=$3
  log "  --- 重启三节点到策略：last_cache_operation_on_load=$st cache_last_values_for_load=$ccl budget=$bud ---"
  EXTRA_CONF="enable_last_cache=true,last_cache_operation_on_load=$st,cache_last_values_for_load=$ccl,cache_last_values_memory_budget_in_byte=$bud,$CMP_EXTRA_WRITE"
  export EXTRA_CONF
  cluster_stop
  cluster_write_conf
  cluster_start || true
  cmp_compaction_off
  cr13_assert_eff last_cache_operation_on_load "$st"
  cr13_assert_eff cache_last_values_for_load "$ccl"
  cr13_assert_eff cache_last_values_memory_budget_in_byte "$bud"
  cr13_assert_eff enable_last_cache true; }
# 等某库新出现**非空且已有 .resource**的 TsFile（结果放全局 CR13_NEWFILES，空格分隔）；0=成功
#   ★ RC8 首轮两处口径错：
#     ① 要求"**恰好 1 个**"：一个库可能跨多个 data region（不同设备/序列槽），一次 flush 每 region
#        各产 1 个文件 ⇒ 相 2/3/4 的"新文件数=2"恒出现，于是"基线批未产生唯一新 TsFile ⇒ 本相跳过"
#        （表/树各 3 次）。现改为"**取全部**新增文件"（load 加载整个目录，多个文件同样合法）。
#     ② 把**0 字节的空壳/占位**当成了源文件（CR-14 实测出现过 `sha256(空文件)=e3b0c442…`）。
#        现在只收"非空 + .resource 已落"的文件（.resource 是 flush 收尾的落盘标记）。
cr13_wait_new_tsfile(){ local h=$1 db=$2 before=$3 win=$4 dl now f list
  CR13_NEWFILES=""; dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    sq "flush;" >/dev/null 2>&1; sqt "flush;" >/dev/null 2>&1
    sleep 4
    now=$(cr13_tsfiles_node "$h" "$db")
    list=""
    for f in $(cr13_new_files "$before" "$now"); do
      [ "$(cr13_has_res "$h" "$f")" -gt 0 ] && list="$list $f"
    done
    list=$(printf '%s' "$list" | sed 's/^ *//;s/ *$//')
    if [ -n "$list" ]; then
      log "    新 TsFile 数=$(printf '%s\n' "$list" | wc -l | tr -dc '0-9') 清单=$(for x in $list; do printf '%s ' "$(basename "$x")"; done)"
      CR13_NEWFILES="$list"; return 0
    fi
  done
  return 1; }
# 把 load 源文件（**可能是多个**）从 QDN 复制到所有 DN 的同一目录（含逐文件 sha256 校验）；结果放 CR13_SRCPATH
cr13_stage_load_src(){ local files=$1 dst=$2 f base tmp h sha_ref sha ok=1
  CR13_SRCPATH=""
  for f in $files; do
    base=$(basename "$f")
    tmp=$(mktemp /tmp/cr13_stage.XXXXXX)
    sshx "$QDN" "cat '$f'" > "$tmp" 2>/dev/null
    if [ ! -s "$tmp" ]; then fail "  S5：源文件取不到或为空：$f"; ok=0; rm -f "$tmp"; continue; fi
    sha_ref=$(sshx "$QDN" "sha256sum '$f' 2>/dev/null | cut -d' ' -f1" | tr -d '\r')
    for h in "${DN[@]}"; do
      sshx "$h" "mkdir -p '$dst' && rm -f '$dst/$base'"
      # ⚠️ 不要给 $SSH_OPTS 加引号！加引号后 ssh 把整串当成**一个** -o 参数 ⇒ 退出码 255、
      #    复制静默失败（上一行 2>/dev/null 把报错也吞了）⇒ 各副本 sha 全是空、"load 源文件未就绪"，
      #    后续 load 实际加载的是空目录（CR-13/CR-14 首轮共 15 条假 FAIL 全从这里来）。
      ssh $SSH_OPTS "$SSH_USER@$h" "cat > '$dst/$base'" < "$tmp" 2>/dev/null
      if [ $? -ne 0 ]; then fail "  S5：$h 上写入 load 源文件失败（$base，ssh 非 0）"; ok=0; fi
      sha=$(sshx "$h" "sha256sum '$dst/$base' 2>/dev/null | cut -d' ' -f1" | tr -d '\r')
      if [ -n "$sha_ref" ] && [ "$sha" = "$sha_ref" ]; then
        pass "  S5：$h 上 load 源文件 $base sha256 一致（$(printf '%s' "$sha" | cut -c1-16)…）"
      else
        fail "  S5：$h 上 load 源文件 $base sha256 不一致（ref=$sha_ref got=$sha）"
      fi
    done
    rm -f "$tmp"
  done
  [ "$ok" = 1 ] && CR13_SRCPATH="$dst/$base"
  return 0; }
# load（表模型优先 database-name，再退回 database/裸写法；树模型裸写法优先，再退回 sglevel=2）
cr13_load(){ local dialect=$1 db=$2 dir=$3 out
  case "$dialect" in
    table)
      out=$(sqt "load '$dir' with ('database-name'='$db');")
      printf '%s' "$out" | grep -qiE 'Exception|error|failed' && out=$(sqt "load '$dir' with ('database'='$db');")
      printf '%s' "$out" | grep -qiE 'Exception|error|failed' && out=$(sqt "load '$dir';") ;;
    *)
      out=$(sq "load '$dir';")
      printf '%s' "$out" | grep -qiE 'Exception|error|failed' && out=$(sq "load '$dir' sglevel=2;") ;;
  esac
  printf '%s' "$out"; }
# 归因探针（只在 S8 失败时调用）：关掉 need_last_cache 后重查 LAST；结果放 CR13_TRIAGE
cr13_triage_need_cache(){ local dialect=$1 db=$2 dev=$3 out
  CR13_TRIAGE="UNAVAILABLE"
  if [ "$dialect" = table ]; then out=$(sqt "alter table $db.$dev set properties need_last_cache=false;");
  else out=$(sq "alter database $db with need_last_cache=false;"); fi
  if printf '%s' "$out" | grep -qiE 'Exception|error'; then
    warn "  W3：$dialect 的 need_last_cache 不可改（$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)）⇒ 归因探针不可用"
    return 0
  fi
  cr13_clear_cache
  if [ "$dialect" = table ]; then CR13_TRIAGE=$(cr13_last table "select last(s1) from $db.$dev;")
  else CR13_TRIAGE=$(cr13_last tree "select last s1 from $db.$dev;"); fi
  return 0; }
# 表模型建表（含 BLOB 列，失败则退回非 BLOB）；返回 0=含 BLOB / 1=无 BLOB / 2=建表失败
cr13_mk_table(){ local tbl=$1 out
  sqt "create database $DBT;" >/dev/null 2>&1
  out=$(sqt "create table $DBT.$tbl (time TIMESTAMP TIME, dev STRING TAG, s1 INT64 FIELD, b BLOB FIELD);")
  if printf '%s' "$out" | grep -q 'successfully'; then pass "  建表 $DBT.$tbl（含 BLOB 列）"; return 0; fi
  out=$(sqt "create table $DBT.$tbl (time TIMESTAMP TIME, dev STRING TAG, s1 INT64 FIELD);")
  if printf '%s' "$out" | grep -q 'successfully'; then warn "  W4：不能建 BLOB 列 ⇒ 本相跳过 BLOB 判据"; return 1; fi
  fail "  场景无效：$DBT.$tbl 未建成：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; return 2; }
# 树模型建库/建序列（首相建，后续相只校验）；结果放 CR13_HAS_BLOB_T
cr13_mk_tree(){ local PH=$1 out d n
  CR13_HAS_BLOB_T=1
  if [ "$PH" = 1 ]; then sq "create database $DBR;" >/dev/null 2>&1; fi
  for d in "$TAG" "$TAG2"; do
    if [ "$PH" = 1 ]; then
      sq "create timeseries $DBR.$d.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null 2>&1
      out=$(sq "create timeseries $DBR.$d.b1 with datatype=BLOB, encoding=PLAIN, compression=SNAPPY;" 2>&1)
      printf '%s' "$out" | grep -qiE 'Exception|error' && { CR13_HAS_BLOB_T=0; warn "  W4：树模型 BLOB 序列不可建（$DBR.$d.b1）⇒ 本相跳过树 BLOB 判据"; }
    fi
  done
  n=$(sq "show timeseries $DBR.**;" 2>/dev/null | grep -c "$DBR")
  [ "${n:-0}" -ge 2 ] && pass "  树模型时序就绪：$DBR.** 共 $n 条（BLOB=$CR13_HAS_BLOB_T）" \
                      || fail "  场景无效：$DBR 时序未建成（$n 条）"
  return 0; }
# 写一批（表模型）：<tbl> <tag> <base_ms> <rows> <val> [hex]；返回 0=含 BLOB / 1=无 BLOB / 2=失败
cr13_w_tbl(){ local tbl=$1 tag=$2 base=$3 n=$4 val=$5 hex=${6:-} k kv="" out
  if [ -n "$hex" ]; then
    for ((k=1;k<=n;k++)); do kv="$kv($(( base + k * STEP_MS )),'$tag',$val,X'$hex'),"; done
    out=$(sqt "insert into $DBT.$tbl (time, dev, s1, b) values ${kv%,};")
    printf '%s' "$out" | grep -q 'successfully' && return 0
    warn "  W4：表模型 BLOB 字面量不可用 ⇒ 退回只写非 BLOB 列"
  fi
  kv=""
  for ((k=1;k<=n;k++)); do kv="$kv($(( base + k * STEP_MS )),'$tag',$val),"; done
  out=$(sqt "insert into $DBT.$tbl (time, dev, s1) values ${kv%,};")
  if printf '%s' "$out" | grep -q 'successfully'; then [ -n "$hex" ] && return 1 || return 0; fi
  fail "  写入失败（表 $DBT.$tbl tag=$tag）：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  return 2; }
# 写一批（树模型）：<dev> <base_ms> <rows> <val> [hex]
cr13_w_tree(){ local dev=$1 base=$2 n=$3 val=$4 hex=${5:-} k kv="" out
  if [ -n "$hex" ]; then
    for ((k=1;k<=n;k++)); do kv="$kv($(( base + k * STEP_MS )),$val,X'$hex'),"; done
    out=$(sq "insert into $DBR.$dev(time,s1,b1) values ${kv%,};")
    printf '%s' "$out" | grep -q 'successfully' && return 0
    warn "  W4：树模型 BLOB 字面量不可用 ⇒ 退回只写非 BLOB 列"
  fi
  kv=""
  for ((k=1;k<=n;k++)); do kv="$kv($(( base + k * STEP_MS )),$val),"; done
  out=$(sq "insert into $DBR.$dev(time,s1) values ${kv%,};")
  if printf '%s' "$out" | grep -q 'successfully'; then [ -n "$hex" ] && return 1 || return 0; fi
  fail "  写入失败（树 $DBR.$dev）：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  return 2; }

# ============================================================================
log "--- 集群准备（CR-13 相 1：UPDATE_NO_BLOB + ccl=true + 模板默认预算）---"
export TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
export MAX_EXPIRED_TIME_MS=9223372036854775807
export EXPIRED_DATA_RATIO=0.000001
EXTRA_CONF="enable_last_cache=true,last_cache_operation_on_load=UPDATE_NO_BLOB,cache_last_values_for_load=true,cache_last_values_memory_budget_in_byte=$BUDGET_BIG,$CMP_EXTRA_WRITE" cmp_cluster_prepare
cmp_compaction_off

log "--- S2（R-72）：配置模板落地值静态校验 ---"
for k in $TPL_KEYS enable_last_cache; do
  n=$(cmp_tpl_has "${DN[0]}" "$k")
  [ "${n:-0}" -ge 1 ] && pass "  S2：模板含 $k（$n 行）" || fail "  S2：模板缺 $k"
done
log "  模板原文：$(sshx "${DN[0]}" "grep -nE '^(enable_last_cache|last_cache_operation_on_load|cache_last_values_for_load|cache_last_values_memory_budget_in_byte)=' $DB_DIR/conf/iotdb-system.properties.template 2>/dev/null" | tr '\n' ' ' | cut -c1-400)"

log "--- S3：三键 restart-only ---"
RESP=$(cmp_set_hot last_cache_operation_on_load UPDATE)
log "  SET last_cache_operation_on_load=UPDATE → $(printf '%s' "$RESP" | tr '\n' ' ' | cut -c1-200)"
assert_contains "  S3：SET 提示 restart is required" "$RESP" "restart is required"
assert_eq "  S3：未重启前生效值不变（仍为 UPDATE_NO_BLOB）" "$(cmp_eff "${DN[0]}" last_cache_operation_on_load)" "UPDATE_NO_BLOB"
RESP2=$(cmp_set_hot last_cache_operation_on_load UPDATE_NO_BLOB)
log "  还原 SET last_cache_operation_on_load=UPDATE_NO_BLOB → $(printf '%s' "$RESP2" | tr '\n' ' ' | cut -c1-120)"

# ---------------------------------------------------------------------------
# 表模型单相：cr13_tbl_phase <PH> <ST> <CCL>
# ---------------------------------------------------------------------------
cr13_tbl_phase(){ local PH=$1 ST=$2 CCL=$3 TBL="t_p$PH" HAS_BLOB=1 rc NOW B_LO N_LO CUT
  local T1_BEFORE T1_AFTER N_AFTER PRE PRE2 POST POST2 CLEAR PB CB NB h pv bad=0
  log "  ---- 表模型（$ST / ccl=$CCL）----"
  cr13_mk_table "$TBL"; rc=$?
  [ "$rc" = 2 ] && return 1
  [ "$rc" = 1 ] && HAS_BLOB=0
  NOW=$(now_ms); B_LO=$(( NOW - 900000 )); N_LO=$(( B_LO + GAP_MS )); CUT=$(( N_LO - 1 ))
  T1_BEFORE=$(cr13_tsfiles_node "$QDN" "$DBT")
  cr13_w_tbl "$TBL" "$TAG"  "$B_LO" "$ROWS" "$BASE_VAL" 6162; [ $? = 1 ] && HAS_BLOB=0
  cr13_w_tbl "$TBL" "$TAG2" "$B_LO" "$ROWS" "$BASE_VAL" 6162; [ $? = 1 ] && HAS_BLOB=0
  sqt "flush;" >/dev/null
  if ! cr13_wait_new_tsfile "$QDN" "$DBT" "$T1_BEFORE" "$WAIT_FILE_SEC"; then
    fail "  场景无效 S5（相 $PH 表）：基线批未产出「非空且 .resource 已落」的 TsFile ⇒ 本相表模型跳过（flush 未完成或产物为空）"; return 1
  fi
  T1_BEFORE=$(cr13_tsfiles_node "$QDN" "$DBT")
  cr13_w_tbl "$TBL" "$TAG" "$N_LO" "$ROWS" "$NEW_VAL" 6364; [ $? = 1 ] && HAS_BLOB=0
  sqt "flush;" >/dev/null
  if ! cr13_wait_new_tsfile "$QDN" "$DBT" "$T1_BEFORE" "$WAIT_FILE_SEC"; then
    fail "  场景无效 S5（相 $PH 表）：更新批未产出「非空且 .resource 已落」的 TsFile ⇒ 本相表模型跳过（flush 未完成或产物为空）"; return 1
  fi
  log "  更新批 TsFile（$PH 表）：$CR13_NEWFILES"
  cr13_stage_load_src "$CR13_NEWFILES" "/tmp/cr13src_p${PH}_${RUN_ID}_table"
  [ -n "${CR13_SRCPATH:-}" ] || { fail "  场景无效 S5：load 源文件未能落到各 DN（相 $PH 表）"; return 1; }
  local OUTDEL; OUTDEL=$(sqt "delete from $DBT.$TBL where time >= $N_LO;")
  log "  DELETE 更新段响应：$(printf '%s' "$OUTDEL" | tr '\n' ' ' | cut -c1-120)"
  wait_scalar_table "select count(*) from $DBT.$TBL;" "$(( ROWS * 2 ))" 90 "  相 $PH 表：更新段已删（剩基线 $(( ROWS * 2 )) 行）"
  T1_AFTER=$(cr13_tbl_rows "$DBT" "$TBL")
  PRE=$(cr13_last table "select last(s1) from $DBT.$TBL;")
  PRE2=$(cr13_last table "select last(s1) from $DBT.$TBL where dev='$TAG2';")
  assert_contains "  相 $PH S4：load 前 LAST 是基线值" "$PRE" "$BASE_VAL"
  assert_not_contains "  相 $PH S4：load 前 LAST 不得含更新值" "$PRE" "$NEW_VAL"
  log "  相 $PH 表：R_pre=[$(printf '%s' "$PRE" | tr '\n' ' ')]"
  local OUTL; OUTL=$(cr13_load table "$DBT" "$(dirname "$CR13_SRCPATH")")
  log "  load 响应：$(printf '%s' "$OUTL" | tr '\n' ' ' | cut -c1-200)"
  printf '%s\n' "$OUTL" >>"$OUT"
  assert_not_contains "  相 $PH S6：load 不得报 507/1100 schema 类错误" "$OUTL" 'IoTDBSQLException: (507|1100)'
  local ok=0 i=0
  while [ "$i" -lt "$LOAD_SEC" ]; do
    N_AFTER=$(cr13_tbl_rows "$DBT" "$TBL")
    [ "${N_AFTER:-0}" -ge "$(( ROWS * 3 ))" ] && { ok=1; break; }
    sleep 5; i=$(( i + 5 ))
  done
  if [ "$ok" = 1 ]; then
    pass "  相 $PH S6：load 生效（行数 $T1_AFTER → $N_AFTER）"
  else
    fail "  相 $PH 场景未成立 S6：load 后行数未增加（$T1_AFTER → ${N_AFTER:-?}）⇒ 表模型结论跳过（load 语义/源文件需人工确认）"
    return 1
  fi
  POST=$(cr13_last table "select last(s1) from $DBT.$TBL;")
  cr13_clear_cache
  CLEAR=$(cr13_last table "select last(s1) from $DBT.$TBL;")
  log "  相 $PH 表：R_post=[$(printf '%s' "$POST" | tr '\n' ' ')] R_clear=[$(printf '%s' "$CLEAR" | tr '\n' ' ')]"
  assert_contains "  相 $PH S7：CLEAR CACHE 后 LAST 必须含更新值（load 真让数据变新）" "$CLEAR" "$NEW_VAL"
  if [ "$CLEAR" = "$PRE" ]; then fail "  相 $PH 场景未成立 S7：CLEAR CACHE 后仍等于 load 前的值 ⇒ load 未改变数据面"; fi
  assert_eq "  相 $PH S8（表 $ST）：load 后立即 LAST == CLEAR CACHE 后的真值" "$POST" "$CLEAR"
  if [ "$POST" != "$CLEAR" ]; then
    cr13_triage_need_cache table "$DBT" "$TBL"
    if [ "$CR13_TRIAGE" = "$CLEAR" ]; then
      fail "  相 $PH 归因证据：need_last_cache=false 后 LAST == R_clear ⇒ 差异**来自 LastCache 陈旧**（策略 $ST 未把缓存维护到真值）；R_post=[$POST]"
    else
      warn "  W3：need_last_cache=false 后仍 != R_clear（[$CR13_TRIAGE]）⇒ 归因不明，附三份原始结果人工核对"
    fi
    sqt "alter table $DBT.$TBL set properties need_last_cache=true;" >/dev/null 2>&1
  fi
  for h in "${DN[@]}"; do
    pv=$(cr13_last_node "$h" table "select last(s1) from $DBT.$TBL;")
    [ "$pv" = "$POST" ] || { bad=1; log "    $h R_post=[$(printf '%s' "$pv" | tr '\n' ' ')] != 基准"; }
  done
  [ "$bad" = 0 ] && pass "  相 $PH S7：三副本 load 后立即 LAST 完全一致" || fail "  相 $PH S7：三副本 load 后立即 LAST 不一致（见上）"
  POST2=$(cr13_last table "select last(s1) from $DBT.$TBL where dev='$TAG2';")
  assert_eq "  相 $PH S9：未包含在 load 文件里的对照设备可见值不变" "$POST2" "$PRE2"
  assert_contains "  相 $PH S9：对照设备仍是基线值" "$POST2" "$BASE_VAL"
  NB=$(scalar "$(sqt "select count(b) from $DBT.$TBL;")")
  if [ "${NB:-0}" -gt 0 ]; then
    PB=$(cr13_last table "select last(b) from $DBT.$TBL;")
    cr13_clear_cache
    CB=$(cr13_last table "select last(b) from $DBT.$TBL;")
    log "  相 $PH 表 BLOB：R_post(blob)=[$(printf '%s' "$PB" | tr '\n' ' ')] R_clear(blob)=[$(printf '%s' "$CB" | tr '\n' ' ')]"
    case "$ST" in
      UPDATE_NO_BLOB)
        if [ "$PB" = "$CB" ] && [ "$PB" != "$PRE" ]; then
          fail "  相 $PH S8（R-65）：UPDATE_NO_BLOB 下 BLOB 序列 R_post == R_clear 但两者都 != R_pre ⇒ 需人工核对（R_pre=[$PRE]）"
        elif [ "$PB" = "$CB" ]; then
          warn "  W：相 $PH BLOB 的 R_post 与 R_clear 相同（可能是 EMPTY/不可读）⇒ 记录：[$PB]"
        else
          pass "  相 $PH S8（R-65）：UPDATE_NO_BLOB 下 BLOB 序列未返回旧缓存值（R_post != R_clear）"
        fi ;;
      UPDATE)
        if [ "$CCL" = false ]; then
          assert_eq "  相 $PH S8（R-63/R-64）：UPDATE+ccl=false 的 BLOB 序列必须更新到真值" "$PB" "$CB"
        else
          warn "  W2：UPDATE+ccl=true 时 BLOB 的预缓存值是 null（R-56 明说"不更新 Blob"）⇒ 只记录：R_post=[$PB] R_clear=[$CB]"
        fi ;;
      *) log "  相 $PH：$ST 为清理型策略，BLOB 一并记录（R_post=[$PB] R_clear=[$CB]）" ;;
    esac
  else
    warn "  W4：相 $PH 表模型没有 BLOB 数据（count(b)=${NB:-0}）⇒ 跳过 BLOB 判据"
  fi
  return 0; }

# ---------------------------------------------------------------------------
# 树模型单相：cr13_tree_phase <PH> <ST> <CCL>
# ---------------------------------------------------------------------------
cr13_tree_phase(){ local PH=$1 ST=$2 CCL=$3 NOW B_LO N_LO TR_BEFORE T_BASE T_EXP TPRE TPOST TCLEAR ok j=0
  log "  ---- 树模型（$ST / ccl=$CCL）----"
  cr13_mk_tree "$PH"
  NOW=$(now_ms); B_LO=$(( NOW - 900000 )); N_LO=$(( B_LO + GAP_MS ))
  TR_BEFORE=$(cr13_tsfiles_node "$QDN" "$DBR")
  if [ "$CR13_HAS_BLOB_T" = 1 ]; then
    cr13_w_tree "$TAG"  "$B_LO" "$ROWS" "$BASE_VAL" 6162; [ $? = 1 ] && CR13_HAS_BLOB_T=0
    cr13_w_tree "$TAG2" "$B_LO" "$ROWS" "$BASE_VAL" 6162; [ $? = 1 ] && CR13_HAS_BLOB_T=0
  else
    cr13_w_tree "$TAG"  "$B_LO" "$ROWS" "$BASE_VAL"
    cr13_w_tree "$TAG2" "$B_LO" "$ROWS" "$BASE_VAL"
  fi
  sq "flush;" >/dev/null
  if ! cr13_wait_new_tsfile "$QDN" "$DBR" "$TR_BEFORE" "$WAIT_FILE_SEC"; then
    warn "  W：相 $PH 树模型未识别出基线批的 TsFile ⇒ 跳过树模型相"; return 1
  fi
  # ★ RC8 首轮：树模型的设备**跨相位共用**（`$DBR.$TAG`），第 2 相起设备上还留着前几相 load 回来的行
  #   ⇒ "更新段已删后行数 == $ROWS" 从第 2 相起必然不成立（实测 8/12/16 vs 4），
  #   而"load 后 >= ROWS*2"又会因为历史行而**假通过**。现改为**本相基线**口径：
  #   写基线批后记 $T_BASE，删更新段后要求回到 $T_BASE，load 后要求到 $T_BASE+ROWS。
  T_BASE=$(cr13_tree_rows "$TAG")
  log "  相 $PH 树：本相基线行数=$T_BASE（设备 $TAG 含历史相位累计；期望 ≥ $ROWS）"
  [ "${T_BASE:-0}" -ge "$ROWS" ] && pass "  相 $PH 树 S4：基线批写入后可见行数=$T_BASE（≥$ROWS）" \
    || { fail "  相 $PH 树场景未成立：基线批写入后行数=${T_BASE:-?}（<$ROWS）"; return 1; }
  TR_BEFORE=$(cr13_tsfiles_node "$QDN" "$DBR")
  if [ "$CR13_HAS_BLOB_T" = 1 ]; then cr13_w_tree "$TAG" "$N_LO" "$ROWS" "$NEW_VAL" 6364
  else cr13_w_tree "$TAG" "$N_LO" "$ROWS" "$NEW_VAL"; fi
  sq "flush;" >/dev/null
  if ! cr13_wait_new_tsfile "$QDN" "$DBR" "$TR_BEFORE" "$WAIT_FILE_SEC"; then
    warn "  W：相 $PH 树模型未识别出更新批的 TsFile ⇒ 跳过树模型相"; return 1
  fi
  cr13_stage_load_src "$CR13_NEWFILES" "/tmp/cr13src_p${PH}_${RUN_ID}_tree"
  [ -n "${CR13_SRCPATH:-}" ] || { fail "  场景无效 S5：树模型 load 源文件未能落到各 DN（相 $PH）"; return 1; }
  sq "delete from $DBR.$TAG.** where time >= $N_LO;" >/dev/null
  j=0
  while [ "$j" -lt 60 ]; do
    [ "$(cr13_tree_rows "$TAG")" = "$T_BASE" ] && break
    sleep 3; j=$(( j + 3 ))
  done
  assert_eq "  相 $PH 树 S4：更新段已删（$TAG 行数回到本相基线 $T_BASE）" "$(cr13_tree_rows "$TAG")" "$T_BASE"
  TPRE=$(cr13_last tree "select last s1 from $DBR.$TAG;")
  assert_contains "  相 $PH 树 S4：load 前 LAST 是基线值" "$TPRE" "$BASE_VAL"
  local OUTL2; OUTL2=$(cr13_load tree "$DBR" "$(dirname "$CR13_SRCPATH")")
  log "  相 $PH 树 load 响应：$(printf '%s' "$OUTL2" | tr '\n' ' ' | cut -c1-200)"
  T_EXP=$(( T_BASE + ROWS ))
  ok=0; j=0
  while [ "$j" -lt "$LOAD_SEC" ]; do
    [ "$(cr13_tree_rows "$TAG")" -ge "$T_EXP" ] && { ok=1; break; }
    sleep 5; j=$(( j + 5 ))
  done
  if [ "$ok" != 1 ]; then
    fail "  相 $PH 场景未成立 S6（树）：load 后行数未增加（$T_BASE → $(cr13_tree_rows "$TAG")，期望 >= $T_EXP）⇒ 跳过树模型结论"; return 1
  fi
  pass "  相 $PH S6（树）：load 生效（$TAG 行数 $T_BASE → $(cr13_tree_rows "$TAG")，期望 >= $T_EXP）"
  TPOST=$(cr13_last tree "select last s1 from $DBR.$TAG;")
  cr13_clear_cache
  TCLEAR=$(cr13_last tree "select last s1 from $DBR.$TAG;")
  log "  相 $PH 树：R_post=[$(printf '%s' "$TPOST" | tr '\n' ' ')] R_clear=[$(printf '%s' "$TCLEAR" | tr '\n' ' ')]"
  assert_contains "  相 $PH 树 S7：CLEAR CACHE 后含更新值" "$TCLEAR" "$NEW_VAL"
  assert_eq "  相 $PH 树 S8（$ST）：load 后立即 LAST == CLEAR CACHE 真值" "$TPOST" "$TCLEAR"
  assert_contains "  相 $PH 树 S9：对照设备仍是基线值" "$(cr13_last tree "select last s1 from $DBR.$TAG2;")" "$BASE_VAL"
  return 0; }

# ---------------------------------------------------------------------------
# 单相：cr13_phase <PH> <ST> <CCL> <BUDGET> [SKIP_RESTART]
# ---------------------------------------------------------------------------
cr13_phase(){ local PH=$1 ST=$2 CCL=$3 BUD=$4 SKIPR=${5:-0}
  log "============================================================"
  log "--- 相 $PH：策略=$ST ccl=$CCL budget=$BUD ---"
  if [ "$SKIPR" = 1 ]; then
    log "  （首相：集群准备阶段已按该组合启动，省掉一次重启）"
    EXTRA_CONF="enable_last_cache=true,last_cache_operation_on_load=$ST,cache_last_values_for_load=$CCL,cache_last_values_memory_budget_in_byte=$BUD,$CMP_EXTRA_WRITE"
    export EXTRA_CONF
    cr13_assert_eff last_cache_operation_on_load "$ST"
    cr13_assert_eff cache_last_values_for_load "$CCL"
    cr13_assert_eff cache_last_values_memory_budget_in_byte "$BUD"
    cr13_assert_eff enable_last_cache true
  else
    cr13_restart "$ST" "$CCL" "$BUD"
  fi
  if [ "$PH" -gt 1 ]; then   # S10：跨重启数据面不丢（前相的表行数仍应 >= ROWS*3）
    local R0; R0=$(cr13_tbl_rows "$DBT" "t_p1")
    [ "${R0:-0}" -ge "$(( ROWS * 3 ))" ] && pass "  S10：重启后相 1 的表 t_p1 行数保持（$R0）" \
      || fail "  S10：重启后相 1 的表 t_p1 行数异常（${R0:-?}，期望 >= $(( ROWS * 3 ))）"
  fi
  cr13_tbl_phase "$PH" "$ST" "$CCL"
  cr13_tree_phase "$PH" "$ST" "$CCL"
  return 0; }

cr13_phase 1 UPDATE_NO_BLOB true  "$BUDGET_BIG" 1
cr13_phase 2 UPDATE         false "$BUDGET_BIG"
cr13_phase 3 CLEAN_DEVICE   true  "$BUDGET_BIG"
cr13_phase 4 CLEAN_ALL      true  "$BUDGET_BIG"

log "--- 收尾三件套（基准用相 1 的表 t_p1）---"
post_checks "select s1 from $DBT.t_p1 order by time;" table
cmp_case_finish "" table ""
