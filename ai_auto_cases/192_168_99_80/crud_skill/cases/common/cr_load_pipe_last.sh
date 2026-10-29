#!/bin/bash
# ============================================================================
# CR-14 Load × Pipe + Last：配置 restart-only 语义 + 性能与内存预算（树模型）
#        —— 存储模块 CRUD 专项 skill
#
# 覆盖需求点（逐字原文见 docs/REQ_MATRIX.md §1）：
#   R-58 「使用 UPDATE 或者 UPDATE_NO_BLOB 策略会一定程度增加文件加载的耗时，但是会降低加载以后
#         进行最新值查询的耗时。使用 CLEAN_DEVICE 或者 CLEAN_ALL 策略不会影响文件加载耗时，
#         但是会增加加载以后进行最新值查询的耗时。」
#   R-59 「上述配置仅允许系统管理员修改。」
#   R-60 「默认场景使用 UPDATE_NO_BLOB 策略；」「确认需要查询 BLOB 类型的最新值时，更换为 UPDATE 策略；」
#        「……使用 CLEAN_DEVICE 策略；」「上述策略均失效，或者设备数过多导致 CLEAN_DEVICE 策略也会
#         导致系统受影响时，使用 CLEAN_ALL 策略（即回退到原有策略）。」
#   R-69 「在三种策略下，同时进行 Load 和 Last 查询的读写性能」「写入线程 A 不断生成包含固定时间序列的
#         TsFile，并将其加载到 IoTDB 中，每个文件的数据时间戳递增，直至加载完 n 个文件。十个查询线程
#         B1-B10 不断随机查询由线程 A 产生的一条时间序列的最新值……并在此过程中记录查询的平均延迟。」
#   R-70 「在三种策略下，使用 Pipe 进行数据同步的读写性能」（需要独立接收端 —— 见下"不可构造"）
#   R-71 文档 1C1D 实测数值表（**不作绝对断言**，见下）
#   R-55/R-56/R-57（三键取值与语义，与 CR-13 互为补充：CR-13 管"结果正确性"，CR-14 管
#         "restart-only 语义 + 性能方向 + 内存预算"）
#   规格出处：docs/REQ_MATRIX.md §3 CR-14 与 §4-C1/C4/B5；docs/DECISIONS.md（口径：耗时只 WARN）。
#
# ---------------------------------------------------------------------------
# 【源码事实（本地源码树 D:\IDEA\timechodb_src\v20121\timechodb，git HEAD 67bb5ced2b，rc/2.0.12.1）】
#   · 三键在 **DataNode 启动时**读取一次：IoTDBDescriptor.java:3461-3475
#       `LastCacheLoadStrategy.valueOf(properties.getProperty("last_cache_operation_on_load", UPDATE))`
#       / `cache_last_values_for_load` / `cache_last_values_memory_budget_in_byte`
#     ⇒ **restart-only**（模板 iotdb-system.properties.template:2894-2913 三处均标 `# effectiveMode: restart`）。
#     ⚠ `SET CONFIGURATION` 会把新值写进 iotdb-system.properties，但**运行期取值不变**（这正是本用例 S3 的双证）。
#   · 策略生效点：DataRegion.onTsFileLoaded（DataRegion.java:5223-5261），条件
#     `isLastCacheEnable() && !isFromConsensus`；UPDATE/UPDATE_NO_BLOB → updateLastCache(:5264-5309)；
#     CLEAN_ALL → TreeDeviceSchemaCacheManager.cleanUp()；CLEAN_DEVICE → 有 ArrayDeviceTimeIndex 时逐设备
#     invalidateLastCache，**否则按库失效**（`invalidateDatabaseLastCache`）。
#   · **Pipe 接收端与 SQL load 共用同一条收尾路径**（本节是"单集群可构造部分"的依据，不是等价替代）：
#     PipeTsFileInsertionEvent（pipe/event/common/tsfile/PipeTsFileInsertionEvent.java:273 带
#     `resource.isGeneratedByPipe()`）→ LoadTsFileStatement.setGeneratedByPipe()（LoadTsFileStatement.java:365）
#     → LoadTsFileScheduler / `LoadTsFileManager.loadAll(uuid, isGeneratedByPipe, …)`（LoadTsFileManager.java:444-456）
#     → DataRegion 同一条 load 主流程（:4854-5048，带 `isGeneratedByPipe` 分支）→ onTsFileLoaded（:5048）。
#   · 官方性能用例：integration-test/.../db/it/IoTDBLoadLastCacheIT.java —— `@Parameters` 只跑
#     CLEAN_ALL/UPDATE/CLEAN_DEVICE 三策略；`testTableLoadPerformance`（:523）被 `@Ignore("Performance")`
#     标注，参数为 100 device × 100 measurement × 100 point × 100000 file、10 查询线程 @100qps。
#     本用例按**形态**缩小复刻（R-69），不追其规模。
#
# ---------------------------------------------------------------------------
# 【本环境可构造性 —— 如实标注，不编造】
#   ✅ 可构造（硬判 / 弱判）：
#     ① **restart-only 语义**（本用例硬判核心）：`SET CONFIGURATION` 返回
#        "…but restart is required for the following parameters to take effect: …"、
#        **不重启时三节点运行期生效值不变**、**重启后生效值 == 新值**；且 properties 文件里确实已被改写
#        （配置层已改 + 运行期未变 = restart-only 的双证）。
#     ② R-69 的"频繁 Load + 并发 Last 查询"：单集群内**完全可构造**——按官方 IT 形态缩小为
#        `FILES` 个时间戳递增的 TsFile 循环 load，同时另起一个 CLI 会话连续查 LAST（$QN 次/会话，
#        取**会话内平均耗时**，含 CLI 会话开销摊销）。断言：load 全部完成 + 查询**确实命中过数据**（命中 >0）。
#     ③ R-58 的耗时**方向性**：UPDATE_NO_BLOB 相 vs CLEAN_DEVICE 相（同为 ccl=true/同预算）比较
#        "单文件 load 耗时"与"Last 查询平均耗时"——**只 WARN 不 FAIL**（原文只说"一定程度增加"，
#        且本环境后台有长回归任务，量化门槛无依据；与 CR-02 的 R-05 口径一致）。
#     ④ R-57 内存预算：极小预算（$BUDGET_SMALL B）相与默认预算（$BUDGET_BIG B）相
#        **Last 结果必须逐字节一致**、值必须正确、**无 OOM**；"预算真会被触发"只证明**构造侧**
#        （新建 $BUDGET_DEVS 个设备，其最新值总量 ≫ 预算）。
#     ⑤ R-59 权限：非 SYSTEM 用户执行 `SET CONFIGURATION` ⇒ 断言**不得**收到"设置成功"（被拒），
#        实测返回码记录在案；SYSTEM 用户 ⇒ 成功且提示需重启。若连普通用户都建不出来 ⇒ 只 WARN。
#   ❌ 不可构造（只写注释 + 运行期 `warn`，**绝不判 FAIL、不编造 DDL**）：
#     ⑥ **R-70 / R-71 的 Pipe 对端**：需要**两个独立集群实例**（官方实验是 192.168.130.15/16 各 1C1D）
#        做全量同步，并让接收端持续做 Last 查询；本环境是单一 3C3D。且"同集群 A 库→B 库"**不能**等价
#        复现跨实例同步（接收端分区规则差异/重组路径无法构造）。⇒ 本用例只做 `SHOW PIPES` 能力探测 +
#        记录，Pipe 专属判据一律 WARN（依据 §4-B5 与 §3 CR-14 判据⑤）。
#     ⑦ R-71 的**绝对数值**（52.50ms / 120.54ms / 15824725 点/秒 等）来自文档的 1C1D 环境
#        （§4-C1）⇒ 不做绝对断言，只把本环境数值写入 results/ 供跨版本比较。
#     ⑧ R-57 的"**确实走了流式回退路径**"不可观测（§4-C4：RC7 无该分支的可观测日志）
#        ⇒ 只做语义等价 + 无 OOM，路径本身只 WARN 记录。
#
# 判据（硬判）：
#   S1 每相三键 + enable_last_cache 的**逐节点生效值** == 写入值
#   S2 配置模板含三键 + enable_last_cache（R-55..R-57 的落地，交叉印证 R-72）
#   S3 restart-only：SET 提示 restart is required、properties 已被改写、**未重启时运行期值不变**；
#      重启后三节点生效值 == 新值（"改配置不重启无效" + "重启后生效"两侧都拿到）
#   S4 场景有效性：load 前 LAST 是基线值且不含更新值；load 源文件是三节点 sha256 一致的本相唯一新 TsFile；
#      load 后可见行数增加；load 无 507/1100/LoadFileException
#   S5 数据面（每相）：load 后立即 LAST == `CLEAR CACHE` 后的真值（策略不同不得改变结果）；
#      三副本 load 后立即 LAST 完全一致；未包含在 load 文件里的对照设备可见值不变
#   S6 频繁 Load：load 次数 == $FILES；并发 Last 查询命中行数 > 0（否则"查询延迟"无意义）
#   S7 内存预算：构造侧最新值总量 > 小预算（否则场景未成立）；小预算相与大预算相的 bd* LAST 逐字节一致；
#      抽样设备 LAST 值正确；日志无 OOM
#   S8 权限：非 SYSTEM 用户 SET 不得成功；SYSTEM 用户 SET 成功且提示 restart
#   S9 收尾三件套（sync lag 归零 → 逐个停 1 DN 比副本一致 → CN/DN 日志扫异常）
# 判据（WARN，绝不 FAIL）：R-58 的耗时方向性、R-70/R-71 的 Pipe 相（不可构造）、
#      R-57 的内部流式回退路径（不可观测）。
#
# 用法： bash cases/common/cr_load_pipe_last.sh [--consensus IoTConsensus|IoTConsensusV2]
# 预估耗时：约 30~40 分钟（5 个相位，其中 4 次三节点重启 + 每相 load 场景 + 每相频繁 Load 段 + 收尾三件套）
#
# ★ harness 修复记录（RC8 首轮实跑暴露，全部是**用例侧**问题；共 113 条 FAIL 里 110 条出自 ①/②）：
#   ① **`cr14_stage` 复制 load 源文件一直失败**：`ssh "$SSH_OPTS" …` 给 `$SSH_OPTS` 加了引号 ⇒ ssh 把
#      `-o BatchMode=yes -o ConnectTimeout=15` 整串当成一个 `-o` 参数、退出码 255，而 `2>/dev/null`
#      把报错吞掉 ⇒ 15 条 `load 源文件 sha256 不一致（got=）`，`load` 实际加载空目录 ⇒ 5×
#      「load 后可见行未增加」+ 5×「CLEAR CACHE 后不是更新值」+ 5×「仍等于 load 前的值」。
#      现改为不加引号 + 判 ssh 退出码 + 逐文件 sha256。
#   ② "**恰好 1 个**新 TsFile"：一次 flush 可能跨多个 data region 各产 1 个文件 ⇒ 频繁 Load 段
#      `实际=5 期望=6`。现改为"取全部新增文件"（load 支持整目录），并只收"非空 + `.resource` 已落"
#      的文件（0 字节空占位的 sha256 是 e3b0c442…，曾被当成源文件）。
#   ③ S7 探针 `select count(s1) from $DBR.bd1.**` 首轮读到空值（`实际=[?]`，多半是 `Empty set.`）
#      ⇒ 改成短轮询 + 打印原始输出，轮询不到再退回"原始查询数行"口径。
#
#   ⚠️ 本任务只做 `bash -n` + **离线纯桩干跑**（`bash tools/stub_offline/run.sh`），**未在集群实跑**
#      （99.80 正在跑 IoTConsensusV2 长回归 B 段）。纯桩结果（2026-10-16）：
#        · STUB_MODE=ok            → RESULT PASS fail_flag=0（0 条 FAIL；Pipe/性能类 8 条 WARN 不计入）
#        · STUB_MODE=hotapply      → FAIL 18（全是"S3：…未重启但…运行期生效值已变成…"）
#        · STUB_MODE=norestart     → FAIL 12（全是"S1：…生效值不一致"，即重启后不生效）
#        · STUB_MODE=ok STUB_STALE=1 → FAIL 8（全是"S5：load 后立即 LAST == CLEAR CACHE 真值"）
#      ⇒ 两侧 restart-only 断言、数据面断言、Pipe 只 WARN 都已验证会真的触发（不是摆设）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/crud_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_load_pipe_last_${DATA_CONSENSUS}"

# ---------------------------------------------------------------------------
# 规模与配置（顶部变量，可用环境变量覆盖）
# ---------------------------------------------------------------------------
DBR=${CR14_DBR:-root.cr14}                 # 树模型库（selftest 约定：库名一律 root.cr*）
# 设备命名：每个相位用自己的目标设备 d<PH>t 与对照设备 d<PH>c（基线批会让行数累加，
#   共用设备会让"删除更新段后可见行回到基线"这条场景有效性断言失效 ⇒ 必须每相一套）。
ROWS=${CR14_ROWS:-4}                       # 每设备每批点数
STEP_MS=${CR14_STEP_MS:-10}                # 点间隔（ms）
GAP_MS=${CR14_GAP_MS:-300000}              # 基线批与更新批的时间差（5 分钟；两批都在过去）
BASE_VAL=${CR14_BASE_VAL:-111111}          # 基线值
NEW_VAL=${CR14_NEW_VAL:-999999}            # 更新值
FILES=${CR14_FILES:-6}                     # 频繁 Load 段 load 的 TsFile 个数（R-69 的"n 个文件"缩小版）
QN=${CR14_QN:-10}                          # 并发查询会话里查 LAST 的次数（每次会话摊销 CLI 开销）
BUDGET_DEVS=${CR14_BUDGET_DEVS:-128}       # 内存预算相的设备数（最新值总量要明显超过小预算）
BUDGET_DEVS_VAL_BASE=${CR14_BUDGET_VAL_BASE:-7000}  # 这些设备的值 = 基数 + 设备序号
BUDGET_DEVS_BYTES_PER_DEV=${CR14_BUDGET_BYTES_PER_DEV:-24}  # 每设备最新值的大致字节（8B 时间戳 + 8B 值 + 测点名等）
BUDGET_SMALL=${CR14_BUDGET_SMALL:-1024}    # 小预算（1KB）
BUDGET_BIG=${CR14_BUDGET_BIG:-4194304}     # 模板默认预算（4MB）
WAIT_FILE_SEC=${CR14_WAIT_FILE_SEC:-90}    # 等 TsFile 落盘/闭合的窗口
LOAD_SEC=${CR14_LOAD_SEC:-240}             # 等 load 生效的窗口
PIPE_PEER=${CR14_PIPE_PEER:-}              # 独立 Pipe 接收端（本环境为空 ⇒ R-70/R-71 记"不可构造"）
USER_NONSYS=${CR14_USER:-cr14u}            # R-59 权限相用的普通用户
USER_NONSYS_PW=${CR14_PW:-Cr14Pw2021}      # 普通用户口令
ST1=UPDATE_NO_BLOB                         # 相 1/2/4/5 的策略（模板默认，R-60）
PERF_CSV="$OUTDIR/cr14_perf.csv"
# 全局返回值（**不要**用 $( ) 捕获会 log/pass/fail 的 helper：本 harness 的日志全写 stdout）
CR14_NEWFILE=""; CR14_NEWFILES=""; CR14_SRCPATH=""; CR14_QAVG=""; CR14_HITS=""
CR14_LOAD_MS=0; CR14_LOAD_MS2=0
CR14_BUD_FP_SMALL=""
declare -A CR14_PH_LOAD_MS=() CR14_PH_QMS=() CR14_PH_STRAT=() CR14_PH_BUD=()

# ---------------------------------------------------------------------------
# helper（只返回数据、**不**调用 log/pass/fail，便于 $( ) 捕获）
# ---------------------------------------------------------------------------
cr14_last(){ norm_result "$(sq "$1")"; }
cr14_last_node(){ norm_result "$(sq_node "$1" "$2")"; }
cr14_clear_cache(){ sq "clear cache;" >/dev/null 2>&1; }
cr14_rows(){ local v; v=$(sq "select s1 from $DBR.$1 order by time;" 2>/dev/null | data_rows | wc -l | tr -dc '0-9'); printf '%s' "${v:-0}"; }
# 该节点上该库的 TsFile **全路径**（只要非空文件：flush 收尾会同时落空占位，0 字节的不可能是 load 源）
cr14_tsfiles(){ sshx "$1" "find $DB_DIR/data/datanode/data -path '*/$2/*' -name '*.tsfile' -size +0 -printf '%p\n' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
cr14_new_files(){ printf '%s\n' "$2" | grep -vxF "$(printf '%s\n' "$1" | sed '/^$/d')" | sed '/^$/d'; }
cr14_has_res(){ local n; n=$(sshx "$1" "test -f '$2.resource' && echo 1 || echo 0" 2>/dev/null | tr -dc '0-9'); printf '%s' "${n:-0}"; }
cr14_sha(){ sshx "$1" "sha256sum '$2' 2>/dev/null | cut -d' ' -f1" 2>/dev/null | tr -d '\r'; }
# properties 文件里是否有 `key=value` 这一行（证明 SET 已改配置层）
cr14_conf_line(){ local n; n=$(sshx "$1" "grep -cE '^$2=$3\$' $DB_DIR/conf/iotdb-system.properties 2>/dev/null" 2>/dev/null | tr -dc '0-9'); printf '%s' "${n:-0}"; }
# 非 SYSTEM 用户执行 SQL（权限相用；lib 里的 sq/sqt 固定用 DB_USER）
cr14_sql_as(){ timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$1" -pw "$2" -timeout 3600 -e "$3" 2>&1; }
# 写一批（树模型，单设备）：<dev> <base_ms> <rows> <val>
cr14_write(){ local dev=$1 base=$2 n=$3 val=$4 k vals=""
  for ((k=1;k<=n;k++)); do vals="$vals($(( base + k * STEP_MS )),$val),"; done
  sq "insert into $DBR.$dev(time,s1) values ${vals%,};" 2>&1; }
# load：裸写法优先，失败再试 sglevel=2（树模型）
cr14_load(){ local out
  out=$(sq "load '$1';")
  printf '%s' "$out" | grep -qiE 'Exception|error|failed' && out=$(sq "load '$1' sglevel=2;")
  printf '%s' "$out"; }

# ---------------------------------------------------------------------------
# helper（会 log/pass/fail：必须**直接调用**，不要用 $( ) 捕获）
# ---------------------------------------------------------------------------
# 逐节点生效值校验（场景有效性硬断言 S1）
cr14_assert_eff(){ local key=$1 want=$2 h got ok=1
  for h in "${DN[@]}"; do
    got=$(cmp_eff "$h" "$key")
    [ "$got" = "$want" ] || { ok=0; log "    $h $key=$got（期望 $want）"; }
  done
  if [ "$ok" = 1 ]; then pass "  S1：三节点生效值 $key=$want"; else fail "  S1：$key 生效值不一致（期望 $want，见上）"; fi; }
# 等某库新出现**非空且已有 .resource**的 TsFile（结果放全局 CR14_NEWFILES，空格分隔）；0=成功
#   ★ RC8 首轮两处口径错（与 CR-13 同源）：
#     ① 要求"**恰好 1 个**"：一个库可能跨多个 data region，一次 flush 每 region 各产 1 个文件 ⇒
#        S6 的频繁 Load 段落里 5 个相位都少 load 了文件（`频繁 Load 全部完成: 实际=5 期望=6`）。
#     ② 会把 **0 字节空占位**当源文件（实测出现过 `ref=e3b0c442…` = 空文件 sha256）⇒ 现在只收
#        "非空 + .resource 已落"的文件，并把清单整体交给 `cr14_stage` 复制。
cr14_wait_new_tsfile(){ local h=$1 db=$2 before=$3 win=$4 dl now f list
  CR14_NEWFILES=""; dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    sq "flush;" >/dev/null 2>&1
    sleep 2
    now=$(cr14_tsfiles "$h" "$db")
    list=""
    for f in $(cr14_new_files "$before" "$now"); do
      [ "$(cr14_has_res "$h" "$f")" -gt 0 ] && list="$list $f"
    done
    list=$(printf '%s' "$list" | sed 's/^ *//;s/ *$//')
    if [ -n "$list" ]; then
      log "    新 TsFile 数=$(printf '%s\n' "$list" | wc -l | tr -dc '0-9') 清单=$(for x in $list; do printf '%s ' "$(basename "$x")"; done)"
      CR14_NEWFILES="$list"; return 0
    fi
  done
  return 1; }
# 把 load 源文件（**可能是多个**）从 QDN 精确复制到所有 DN 的同一绝对路径（含 sha256 校验）；结果放 CR14_SRCPATH
cr14_stage(){ local files=$1 dst=$2 f base tmp h sha_ref sha ok=1
  CR14_SRCPATH=""
  for f in $files; do
    base=$(basename "$f")
    tmp=$(mktemp /tmp/cr14_stage.XXXXXX)
    sshx "$QDN" "cat '$f'" > "$tmp" 2>/dev/null
    if [ ! -s "$tmp" ]; then fail "  S4：源文件取不到或为空：$f"; ok=0; rm -f "$tmp"; continue; fi
    sha_ref=$(cr14_sha "$QDN" "$f")
    for h in "${DN[@]}"; do
      sshx "$h" "mkdir -p '$dst' && rm -f '$dst/$base'"
      # ⚠️ 不要给 $SSH_OPTS 加引号！加引号后 ssh 把整串当成**一个** -o 参数 ⇒ 退出码 255、
      #    复制静默失败（`2>/dev/null` 还把报错吞了）⇒ 15 条 `load 源文件 sha256 不一致（got=）`，
      #    以及后续"load 后可见行未增加 / CLEAR CACHE 后不是更新值"等连带 FAIL。
      ssh $SSH_OPTS "$SSH_USER@$h" "cat > '$dst/$base'" < "$tmp" 2>/dev/null
      if [ $? -ne 0 ]; then fail "  S4：$h 上写入 load 源文件失败（$base，ssh 非 0）"; ok=0; fi
      sha=$(cr14_sha "$h" "$dst/$base")
      if [ -n "$sha_ref" ] && [ "$sha" = "$sha_ref" ]; then
        pass "  S4：$h 上 load 源文件 $base sha256 一致（$(printf '%s' "$sha" | cut -c1-16)…）"
      else
        fail "  S4：$h 上 load 源文件 $base sha256 不一致（ref=$sha_ref got=$sha）⇒ 源文件未就绪"
      fi
    done
    rm -f "$tmp"
  done
  [ "$ok" = 1 ] && CR14_SRCPATH="$dst/$base"
  return 0; }
# 等某设备可见行数达到期望（DELETE / load 都走共识 ⇒ 必须轮询）
cr14_wait_rows(){ local dev=$1 want=$2 win=$3 label=$4 got dl
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(cr14_rows "$dev"); [ "$got" = "$want" ] && { pass "$label: $got"; return 0; }
    sleep 3
  done
  fail "$label: 实际=[${got:-?}] 期望=[$want]（等 ${win}s 仍未达成）"; return 1; }
# 重启到指定组合（**保留数据**：stop → 写 conf → start，不 clean），并逐节点校验生效值
cr14_restart(){ local st=$1 ccl=$2 bud=$3
  log "  --- 重启三节点到组合：last_cache_operation_on_load=$st cache_last_values_for_load=$ccl budget=$bud ---"
  EXTRA_CONF="enable_last_cache=true,last_cache_operation_on_load=$st,cache_last_values_for_load=$ccl,cache_last_values_memory_budget_in_byte=$bud,$CMP_EXTRA_WRITE"
  export EXTRA_CONF
  cluster_stop
  cluster_write_conf
  cluster_start || true
  cmp_compaction_off
  cr14_assert_eff last_cache_operation_on_load "$st"
  cr14_assert_eff cache_last_values_for_load "$ccl"
  cr14_assert_eff cache_last_values_memory_budget_in_byte "$bud"
  cr14_assert_eff enable_last_cache true; }
# S3：restart-only 语义（**改配置不重启无效** + **重启后生效**），三键各验一遍
cr14_switch_semantics(){ local prev_st=$1 prev_ccl=$2 prev_bud=$3 st=$4 ccl=$5 bud=$6 spec k rest v pv resp n h got
  log "  --- S3：三键 restart-only 语义（SET 不重启无效 → 重启后生效）---"
  for spec in "last_cache_operation_on_load=${st}=${prev_st}" \
              "cache_last_values_for_load=${ccl}=${prev_ccl}" \
              "cache_last_values_memory_budget_in_byte=${bud}=${prev_bud}"; do
    k=${spec%%=*}; rest=${spec#*=}; v=${rest%%=*}; pv=${rest#*=}
    resp=$(cmp_set_hot "$k" "$v")
    log "    SET $k=$v → $(printf '%s' "$resp" | tr '\n' ' ' | cut -c1-160)"
    assert_contains "  S3：SET $k 提示 restart is required（restart-only 键）" "$resp" "restart is required"
    n=$(cr14_conf_line "${DN[0]}" "$k" "$v")
    [ "${n:-0}" -ge 1 ] && pass "  S3：SET 已把 $k=$v 写进 iotdb-system.properties（${n} 行：配置层已改）" \
      || fail "  S3：SET 未把 $k=$v 写进 properties ⇒ 无法证明 restart-only（配置层未改）"
    for h in "${DN[@]}"; do
      got=$(cmp_eff "$h" "$k")
      [ "$got" = "$pv" ] && pass "  S3：$h 未重启时 $k 运行期生效值仍为 $pv（改配置不重启无效）" \
        || fail "  S3：$h 未重启但 $k 运行期生效值已变成 $got（期望仍为 $pv ⇒ 与 restart-only 语义不符）"
    done
  done
  cr14_restart "$st" "$ccl" "$bud"; }          # 重启后逐节点生效值 == 新值（cr14_restart 内部逐节点硬断言）

# 相内单集群 load 场景（S4/S5）：基线批 + 更新批 → 暂存更新 TsFile → 删更新段 → load → 比较 POST/CLEAR
#   ⚠ 每个相位用**自己的设备**（d<PH>t = 目标 / d<PH>c = 对照）：基线批会让设备行数累加，
#     若所有相位共用同一设备，"删除更新段后可见行回到基线 ROWS" 这条场景有效性断言就不成立（会误判）。
cr14_load_scenario(){ local PH=$1 TD="d${PH}t" CD="d${PH}c" NOW B_LO N_LO before PRE PRE2 POST CLEAR OUTL ok n i h pv bad=0 t0 t1 nts
  log "  ---- 单集群 load 场景（相 $PH，目标设备 $TD / 对照设备 $CD）----"
  sq "create timeseries $DBR.$TD.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null 2>&1
  sq "create timeseries $DBR.$CD.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null 2>&1
  nts=$(sq "show timeseries $DBR.$TD.s1;" 2>/dev/null | grep -c "$TD")
  [ "${nts:-0}" -ge 1 ] && pass "  S4（相 $PH）：目标设备就绪（$DBR.$TD）" || fail "  S4（相 $PH）场景未成立：目标设备 $DBR.$TD 未建成"
  NOW=$(now_ms); B_LO=$(( NOW - 900000 )); N_LO=$(( B_LO + GAP_MS ))
  before=$(cr14_tsfiles "$QDN" "$DBR")
  cr14_write "$TD" "$B_LO" "$ROWS" "$BASE_VAL" >/dev/null 2>&1
  cr14_write "$CD" "$B_LO" "$ROWS" "$BASE_VAL" >/dev/null 2>&1
  sq "flush;" >/dev/null 2>&1
  if ! cr14_wait_new_tsfile "$QDN" "$DBR" "$before" "$WAIT_FILE_SEC"; then
    fail "  S4（相 $PH）：基线批未产出「非空且 .resource 已落」的 TsFile ⇒ 本相跳过（场景未成立）"; return 1
  fi
  before=$(cr14_tsfiles "$QDN" "$DBR")
  cr14_write "$TD" "$N_LO" "$ROWS" "$NEW_VAL" >/dev/null 2>&1
  sq "flush;" >/dev/null 2>&1
  if ! cr14_wait_new_tsfile "$QDN" "$DBR" "$before" "$WAIT_FILE_SEC"; then
    fail "  S4（相 $PH）：更新批未产出「非空且 .resource 已落」的 TsFile ⇒ 本相跳过（场景未成立）"; return 1
  fi
  cr14_stage "$CR14_NEWFILES" "/tmp/cr14src_p${PH}_${RUN_ID}"
  if [ -z "${CR14_SRCPATH:-}" ]; then fail "  S4（相 $PH）：load 源路径为空 ⇒ 本相跳过"; return 1; fi
  sq "delete from $DBR.$TD.** where time >= $N_LO;" >/dev/null 2>&1
  cr14_wait_rows "$TD" "$ROWS" "$LOAD_SEC" "  S4（相 $PH）：更新段已删（可见行回到基线 $ROWS）" || true
  PRE=$(cr14_last "select last s1 from $DBR.$TD;")
  PRE2=$(cr14_last "select last s1 from $DBR.$CD;")
  assert_contains "  S4（相 $PH）：load 前 LAST 是基线值" "$PRE" "$BASE_VAL"
  assert_not_contains "  S4（相 $PH）：load 前 LAST 不得含更新值" "$PRE" "$NEW_VAL"
  log "  相 $PH：R_pre=[$(printf '%s' "$PRE" | tr '\n' ' ')]"
  t0=$(now_ms)
  OUTL=$(cr14_load "$(dirname "$CR14_SRCPATH")")
  t1=$(now_ms)
  CR14_LOAD_MS=$(( t1 - t0 ))
  printf '%s\n' "$OUTL" >>"$OUT"
  assert_not_contains "  S4（相 $PH）：load 不得报 schema/load 类错误" "$OUTL" 'IoTDBSQLException: (507|1100)|LoadFileException'
  ok=0; i=0
  while [ "$i" -lt "$LOAD_SEC" ]; do
    n=$(cr14_rows "$TD")
    [ "${n:-0}" -ge "$(( ROWS * 2 ))" ] && { ok=1; break; }
    sleep 3; i=$(( i + 3 ))
  done
  if [ "$ok" = 1 ]; then
    pass "  S4（相 $PH）：load 生效（$TD 可见行 $ROWS → $n；单文件 load 耗时 ${CR14_LOAD_MS}ms）"
  else
    fail "  S4（相 $PH）场景未成立：load 后可见行未增加（${n:-?}，期望 >= $(( ROWS * 2 ))）"
  fi
  POST=$(cr14_last "select last s1 from $DBR.$TD;")
  cr14_clear_cache
  CLEAR=$(cr14_last "select last s1 from $DBR.$TD;")
  log "  相 $PH：R_post=[$(printf '%s' "$POST" | tr '\n' ' ')] R_clear=[$(printf '%s' "$CLEAR" | tr '\n' ' ')]"
  assert_contains "  S5（相 $PH）：CLEAR CACHE 后的真值必须是更新值（load 真的改了数据面）" "$CLEAR" "$NEW_VAL"
  [ "$CLEAR" = "$PRE" ] && fail "  S5（相 $PH）场景未成立：CLEAR CACHE 后仍等于 load 前的值 ⇒ load 未改变数据面"
  assert_eq "  S5（相 $PH）：load 后立即 LAST == CLEAR CACHE 真值（缓存被维护到真值）" "$POST" "$CLEAR"
  for h in "${DN[@]}"; do
    pv=$(cr14_last_node "$h" "select last s1 from $DBR.$TD;")
    [ "$pv" = "$POST" ] || { bad=1; log "    $h R_post=[$(printf '%s' "$pv" | tr '\n' ' ')] != 基准"; }
  done
  [ "$bad" = 0 ] && pass "  S5（相 $PH）：三副本 load 后立即 LAST 完全一致" || fail "  S5（相 $PH）：三副本 load 后立即 LAST 不一致（见上）"
  assert_eq "  S5（相 $PH）：未包含在 load 文件里的对照设备可见值不变" "$(cr14_last "select last s1 from $DBR.$CD;")" "$PRE2"
  return 0; }
# 会话内 K 次 LAST 查询的平均耗时（ms）：<设备> <次数>；命中行数放全局 CR14_HITS
cr14_query_avg(){ local dev=$1 n=$2 i stmts=() t0 t1 out
  [ "${n:-0}" -gt 0 ] || n=1                      # 防 0 除（CR14_QN 传 0 时）
  for ((i=0;i<n;i++)); do stmts+=("select last s1 from $DBR.$dev;"); done
  t0=$(now_ms)
  out=$(sql_lines_tree "${stmts[@]}")
  t1=$(now_ms)
  CR14_HITS=$(printf '%s' "$out" | grep -cE '^\|')
  printf '%s' "$(( (t1 - t0) / n ))"
}
# S6：频繁 Load × 并发 Last 查询（R-53 的前提 / R-69 的形态缩小复刻）
cr14_freqload(){ local PH=$1 TD="d${PH}t" i before f lr nf=0 t0 t1
  log "  ---- S6：频繁 Load × 并发 Last 查询（相 $PH，设备 $TD）----"
  local qf="$OUTDIR/cr14_q_${PH}_${RUN_ID}.txt"
  rm -f "$qf"
  ( cr14_query_avg "$TD" "$QN" >"$qf"; printf 'hits=%s\n' "${CR14_HITS:-0}" >>"$qf" ) &
  local qpid=$!
  t0=$(now_ms)
  for ((i=1;i<=FILES;i++)); do
    before=$(cr14_tsfiles "$QDN" "$DBR")
    cr14_write "$TD" "$(( $(now_ms) + i * 100000 ))" "$ROWS" "$(( NEW_VAL + i ))" >/dev/null 2>&1
    sq "flush;" >/dev/null 2>&1
    if cr14_wait_new_tsfile "$QDN" "$DBR" "$before" "$WAIT_FILE_SEC"; then
      cr14_stage "$CR14_NEWFILES" "/tmp/cr14freq_${PH}_${i}_${RUN_ID}" >/dev/null 2>&1
      lr=$(cr14_load "$(dirname "$CR14_SRCPATH")")
      printf '%s\n' "$lr" >>"$OUT"
      printf '%s' "$lr" | grep -qiE 'Exception|error|failed' \
        && warn "  S6（相 $PH）：第 $i 次 load 返回错误（记录）：$(printf '%s' "$lr" | tr '\n' ' ' | cut -c1-140)"
      nf=$(( nf + 1 ))
    else
      warn "  S6（相 $PH）：第 $i 个频繁 Load 文件未产出（记录）"
    fi
  done
  t1=$(now_ms)
  wait "$qpid" 2>/dev/null || true
  CR14_QAVG=$(head -1 "$qf" 2>/dev/null | tr -dc '0-9')
  CR14_HITS=$(grep -o 'hits=[0-9]*' "$qf" 2>/dev/null | head -1 | cut -d= -f2)
  CR14_LOAD_MS2=$(( t1 - t0 ))
  log "  相 $PH：频繁 Load 文件数=$nf/$FILES 总耗时=${CR14_LOAD_MS2}ms；会话内 Last 查询平均耗时=${CR14_QAVG:-?}ms（$QN 次/会话，含 CLI 会话开销摊销）命中行=${CR14_HITS:-?}"
  assert_eq "  S6（相 $PH）：频繁 Load 全部完成（load 次数 == $FILES）" "$nf" "$FILES"
  if [ "${CR14_HITS:-0}" -gt 0 ]; then
    pass "  S6（相 $PH）：并发 Last 查询确实查到了数据（命中行 ${CR14_HITS} > 0）"
  else
    fail "  S6（相 $PH）场景未成立：并发 Last 查询一行都没查到 ⇒ 查询延迟无意义"
  fi
  if [ "${CR14_QAVG:-0}" -gt 0 ]; then pass "  S6（相 $PH）：查询延迟已记录（${CR14_QAVG}ms/次）"
  else warn "  S6（相 $PH）：查询延迟读数为 0（记录）"; fi
  return 0; }
# 性能记录（写 results/ 供跨版本比较；**不做绝对断言**，R-71 §4-C1）
cr14_perf_record(){ local PH=$1 ST=$2 CCL=$3 BUD=$4
  [ -f "$PERF_CSV" ] || echo 'Time,build,consensus,phase,strategy,cache_last_values_for_load,budget,load_ms_per_file,first_load_ms,query_avg_ms,queries_per_session,load_files' >>"$PERF_CSV"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date --iso-8601=seconds)" "$BUILD_TAG" "${DATA_CONSENSUS}" "P$PH" "$ST" "$CCL" "$BUD" \
    "${CR14_PH_LOAD_MS[$PH]:-0}" "${CR14_LOAD_MS:-0}" "${CR14_PH_QMS[$PH]:-0}" "$QN" "$FILES" >>"$PERF_CSV"
  CR14_PH_STRAT[$PH]="$ST"; CR14_PH_BUD[$PH]="$BUD"
  log "  已记录性能到 $PERF_CSV：相 $PH 策略=$ST ccl=$CCL budget=$BUD 单文件 load=${CR14_PH_LOAD_MS[$PH]:-0}ms 查询均值=${CR14_PH_QMS[$PH]:-0}ms"; }
# 单相：cr14_phase <PH> <ST> <CCL> <BUD> <PREV_ST> <PREV_CCL> <PREV_BUD> <FIRST>
cr14_phase(){ local PH=$1 ST=$2 CCL=$3 BUD=$4 PREV_ST=$5 PREV_CCL=$6 PREV_BUD=$7 FIRST=${8:-0}
  log "============================================================"
  if [ "$FIRST" = 1 ]; then
    log "--- 相 $PH：策略=$ST ccl=$CCL budget=$BUD（集群准备阶段已按该组合启动，省一次重启）---"
    cr14_assert_eff last_cache_operation_on_load "$ST"
    cr14_assert_eff cache_last_values_for_load "$CCL"
    cr14_assert_eff cache_last_values_memory_budget_in_byte "$BUD"
    cr14_assert_eff enable_last_cache true
  else
    log "--- 相 $PH：策略=$ST ccl=$CCL budget=$BUD ---"
    cr14_switch_semantics "$PREV_ST" "$PREV_CCL" "$PREV_BUD" "$ST" "$CCL" "$BUD"
  fi
  cr14_load_scenario "$PH"
  cr14_freqload "$PH"
  if [ "${FILES:-0}" -gt 0 ]; then CR14_PH_LOAD_MS[$PH]=$(( ${CR14_LOAD_MS2:-0} / FILES ))
  else CR14_PH_LOAD_MS[$PH]=0; fi
  CR14_PH_QMS[$PH]=${CR14_QAVG:-0}
  cr14_perf_record "$PH" "$ST" "$CCL" "$BUD"
  return 0; }
# S7 构造：预算相设备（最新值总量必须明显超过小预算）
cr14_budget_construct(){ local i need n
  log "  ---- S7：内存预算相构造（$BUDGET_DEVS 个设备，每个 1 个最新值）----"
  for ((i=1;i<=BUDGET_DEVS;i++)); do
    sq "create timeseries $DBR.bd$i.s1 with datatype=INT64;" >/dev/null 2>&1
    sq "insert into $DBR.bd$i(time,s1) values ($(( $(now_ms) - 60000 + i )),$(( BUDGET_DEVS_VAL_BASE + i )));" >/dev/null 2>&1
  done
  sq "flush;" >/dev/null 2>&1
  # ⚠ row_sum 是"取实参"的函数（不是从 stdin 读）⇒ 必须写成 row_sum "$(...)"
  #   RC8 首轮这里读到空值（`实际=[?]`）：`select count(s1) from $DBR.bd1.**` 返回 `Empty set.` 时
  #   table_rows 为空 ⇒ row_sum 回显空串。这里改成**短轮询**等它可见，并把原始输出打出来作证据。
  local i2 raw="" n=""
  i2=0
  while [ "$i2" -lt 60 ]; do
    raw=$(sq "select count(s1) from $DBR.bd1.**;" 2>/dev/null)
    n=$(row_sum "$raw")
    [ -n "$n" ] && break
    sleep 3; i2=$(( i2 + 3 ))
  done
  if [ -z "$n" ]; then
    log "  S7 探针原始输出：$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-200)"
    n=$(cr14_rows bd1)   # 退路：用原始查询数行（不依赖聚合/table_rows）
  fi
  assert_eq "  S7：预算相探针设备写入成功（bd1 行数）" "${n:-?}" "1"
  need=$(( BUDGET_DEVS * BUDGET_DEVS_BYTES_PER_DEV ))
  if [ "${need:-0}" -gt "${BUDGET_SMALL:-0}" ]; then
    pass "  S7：构造侧预算触发证明：$BUDGET_DEVS 设备 × 约 ${BUDGET_DEVS_BYTES_PER_DEV}B = ${need}B > 小预算 ${BUDGET_SMALL}B（最新值总量确实超过预算）"
  else
    fail "  S7 场景未成立：最新值总量估计 ${need}B 未超过预算 ${BUDGET_SMALL}B ⇒ 该相只是默认路径的重复"
  fi
  warn "  S7：\"确实走了流式回退路径\"**不可观测**（矩阵 §4-C4：RC7 无该分支可观测日志）⇒ 只做语义等价 + 无 OOM 判据"; }
# 预算相指纹：只取不被后续相位改动的设备（bd*）的 LAST，避免相位间行数变化干扰
cr14_budget_fp(){ local i out=""
  for i in 1 2 "$(( BUDGET_DEVS / 2 ))" "$BUDGET_DEVS"; do
    out="$out|bd$i=$(cr14_last "select last s1 from $DBR.bd$i;")"
  done
  printf '%s' "$out"; }
cr14_budget_values_check(){ local i v want bad=0
  for i in 1 2 "$(( BUDGET_DEVS / 2 ))" "$BUDGET_DEVS"; do
    v=$(cr14_last "select last s1 from $DBR.bd$i;"); want=$(( BUDGET_DEVS_VAL_BASE + i ))
    if printf '%s' "$v" | grep -q "$want"; then :; else bad=$(( bad + 1 )); log "    bd$i LAST=[$(printf '%s' "$v" | tr '\n' ' ')] 期望含 $want"; fi
  done
  [ "$bad" = 0 ] && pass "  S7：bd* 的 LAST 值全部正确（抽样 4 个设备）" || fail "  S7：bd* 的 LAST 值不正确（$bad 个，见上）"; }
# S7 对照：小预算相 vs 默认预算相（同一批设备，逐字节比较）
cr14_budget_compare(){ local fp_big cnt
  fp_big=$(cr14_budget_fp)
  log "  ---- S7：两相 Last 结果对照（小预算 ${BUDGET_SMALL}B / 默认 ${BUDGET_BIG}B）----"
  log "  小预算指纹=[$CR14_BUD_FP_SMALL]"
  log "  大预算指纹=[$fp_big]"
  assert_eq "  S7：预算只影响实现路径、不影响 Last 结果（两相逐字节一致）" "$fp_big" "$CR14_BUD_FP_SMALL"
  cr14_budget_values_check
  cnt=$(crud_log_sum 'OutOfMemoryError|Java heap space|GC overhead limit exceeded')
  assert_eq "  S7：小预算相日志无 OOM" "${cnt:-0}" "0"; }
# R-58 耗时方向性（**只 WARN**）
cr14_perf_direction(){ local ul uq cl cq
  ul=${CR14_PH_LOAD_MS[1]:-0}; uq=${CR14_PH_QMS[1]:-0}
  cl=${CR14_PH_LOAD_MS[3]:-0}; cq=${CR14_PH_QMS[3]:-0}
  log "--- R-58/R-69 性能方向性（相1 UPDATE_NO_BLOB vs 相3 CLEAN_DEVICE；**耗时只 WARN，不判 FAIL**）---"
  log "  相1(UPDATE_NO_BLOB)：load=${ul}ms/文件 查询=${uq}ms；相3(CLEAN_DEVICE)：load=${cl}ms/文件 查询=${cq}ms"
  if [ "${ul:-0}" -ge "${cl:-0}" ]; then
    pass "  R-58 方向①：UPDATE* 的加载耗时 >= CLEAN_*（${ul} >= ${cl}）"
  else
    warn "  R-58 方向①不达预期：UPDATE* 加载耗时（${ul}ms）< CLEAN_*（${cl}ms）—— 原文只说\"一定程度增加\"、无阈值，且本环境后台有长回归 ⇒ 只 WARN"
  fi
  if [ "${uq:-0}" -le "${cq:-0}" ]; then
    pass "  R-58 方向②：UPDATE* 的 Last 查询耗时 <= CLEAN_*（${uq} <= ${cq}）"
  else
    warn "  R-58 方向②不达预期：UPDATE* 查询耗时（${uq}ms）> CLEAN_*（${cq}ms）—— CLI 会话开销摊销 + 后台负载噪声 ⇒ 只 WARN"
  fi
  warn "  R-71 绝对数值（文档 1C1D：52.50ms / 120.54ms / 15824725 点每秒 等）来自另一套环境 ⇒ 本用例**不做绝对断言**，只把本环境数值写进 $PERF_CSV（矩阵 §4-C1）"; }
# R-59 权限相
cr14_perm_phase(){ local out out2 code
  log "--- S8（R-59）：仅系统管理员可修改这三键 ---"
  out=$(sq "create user $USER_NONSYS '$USER_NONSYS_PW';" 2>&1)
  if printf '%s' "$out" | grep -qiE 'Exception|error'; then
    out2=$(sq "create user $USER_NONSYS identified by '$USER_NONSYS_PW';" 2>&1)
    if printf '%s' "$out2" | grep -qiE 'Exception|error'; then
      warn "  S8 场景未构造：无法创建普通用户（两种写法均失败）⇒ 权限相跳过并如实记录：$(printf '%s' "$out2" | tr '\n' ' ' | cut -c1-160)"
      return 0
    fi
    out="$out2"
  fi
  pass "  S8：普通用户 $USER_NONSYS 创建成功"
  out=$(cr14_sql_as "$USER_NONSYS" "$USER_NONSYS_PW" "set configuration 'last_cache_operation_on_load'='UPDATE';")
  code=$(printf '%s' "$out" | grep -oE '[0-9]{3}:' | head -1 | tr -d ':')
  log "  S8：非 SYSTEM 用户 SET CONFIGURATION 原始输出：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)（实测码=${code:-未取到}）"
  assert_not_contains "  S8：非 SYSTEM 用户不得收到\"设置成功\"（R-59 只允许系统管理员）" "$out" 'set successfully'
  assert_contains "  S8：非 SYSTEM 用户被明确拒绝（错误码/权限提示；实际码见上，待研发确认口径）" "$out" 'IoTDBSQLException|Exception|permission|Permission|privilege|803|701'
  out2=$(sq "set configuration 'last_cache_operation_on_load'='UPDATE';" 2>&1)
  log "  S8：SYSTEM 用户 SET CONFIGURATION → $(printf '%s' "$out2" | tr '\n' ' ' | cut -c1-200)"
  assert_contains "  S8：SYSTEM 用户 SET 成功并提示 restart is required" "$out2" 'restart is required'
  sq "set configuration 'last_cache_operation_on_load'='$ST1';" >/dev/null 2>&1
  return 0; }
# R-70/R-71：Pipe 对端不可构造（只 WARN，不判 FAIL，不编造 Pipe DDL）
cr14_pipe_phase(){ local pipes
  log "--- R-70/R-71：Pipe × Last（本环境**不可构造**，如实记录）---"
  pipes=$(sq 'show pipes;' 2>&1 | strip_echo | tail -3)
  log "  SHOW PIPES → $(printf '%s' "$pipes" | tr '\n' ' ' | cut -c1-200)"
  if [ -n "${PIPE_PEER:-}" ]; then
    warn "  PIPE_PEER='$PIPE_PEER' 已提供，但本用例**不内置跨集群 Pipe DDL**（语法未在本集群验证过，硬凑会造出\"用例侧语法错误\"式的假 FAIL）⇒ 记「不可构造」"
  else
    warn "  Pipe 对端未提供（PIPE_PEER 为空）⇒ 记「不可构造」"
  fi
  warn "  R-70/R-71 需要**两个独立集群实例**（官方实验为 192.168.130.15/16 各 1C1D）做全量同步、并在接收端持续做 Last 查询；本环境是单一 3C3D，且\"同集群 A 库→B 库\"不能等价复现接收端的分区规则差异/重组路径（矩阵 §4-B5）⇒ 本相只做能力探测 + 记录，**不判 FAIL**"
  warn "  可构造的**相关**证据（不等价于 Pipe）：Pipe 接收端与 SQL load 共用 DataRegion.onTsFileLoaded 收尾逻辑（源码见头注释）⇒ 本用例的 load 相已覆盖该收尾；Pipe 专属的事件传输/分区重组部分不可构造"; }

# ============================================================================
# 集群准备（相 1 组合：UPDATE_NO_BLOB + ccl=true + 模板默认预算）
# ============================================================================
log "--- 集群准备（相 1：$ST1 / ccl=true / 预算 $BUDGET_BIG；写入期三类合并全关）---"
export TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
export MAX_EXPIRED_TIME_MS=9223372036854775807
export EXPIRED_DATA_RATIO=0.000001
# CRUD 专属日志判据（lib/common.sh 的可覆盖钩子；不设置时行为与合并 skill 完全一致）
export CRUD_EVIDENCE_DB="$DBR"
export CMP_POSITIVE_EVIDENCE_FN=crud_positive_evidence
crud_install_err_pat
EXTRA_CONF="enable_last_cache=true,last_cache_operation_on_load=$ST1,cache_last_values_for_load=true,cache_last_values_memory_budget_in_byte=$BUDGET_BIG,$CMP_EXTRA_WRITE"
export EXTRA_CONF
cmp_cluster_prepare
cmp_compaction_off

log "--- S2（R-55..R-57 / R-72）：三键 + enable_last_cache 在配置模板中存在 ---"
for k in last_cache_operation_on_load cache_last_values_for_load cache_last_values_memory_budget_in_byte; do
  n=$(cmp_tpl_has "${DN[0]}" "$k")
  [ "${n:-0}" -ge 1 ] && pass "  S2：模板含 $k（$n 行）" || fail "  S2：模板缺 $k"
done
c=$(cmp_tpl_has "${DN[0]}" enable_last_cache)
[ "${c:-0}" -ge 1 ] && pass "  S2：模板含 enable_last_cache（$c 行）" || fail "  S2：模板缺 enable_last_cache"
log "  模板原文：$(sshx "${DN[0]}" "grep -nE '^(enable_last_cache|last_cache_operation_on_load|cache_last_values_for_load|cache_last_values_memory_budget_in_byte)=' $DB_DIR/conf/iotdb-system.properties.template 2>/dev/null" | tr '\n' ' ' | cut -c1-400)"

# ============================================================================
# 5 个相位
#   相1 UPDATE_NO_BLOB / ccl=true  / BIG    ← R-58 的 UPDATE* 侧基线
#   相2 UPDATE_NO_BLOB / ccl=false / BIG    ← R-56 的 cache_last_values_for_load 对照（同策略同预算）
#   相3 CLEAN_DEVICE   / ccl=true  / BIG    ← R-58 的 CLEAN_* 侧
#   相4 UPDATE_NO_BLOB / ccl=true  / SMALL  ← R-57 小预算相（+ 预算构造）
#   相5 UPDATE_NO_BLOB / ccl=true  / BIG    ← R-57 对照相（与相 1 同组合 ⇒ 结果逐字节比较）
#   CLEAN_ALL 的**结果正确性**由 CR-13 覆盖（R-66/R-67），本用例只取一个 CLEAN_* 代表做耗时方向性。
# ============================================================================
cr14_phase 1 "$ST1" true  "$BUDGET_BIG"   "$ST1"         true  "$BUDGET_BIG"   1
cr14_phase 2 "$ST1" false "$BUDGET_BIG"   "$ST1"         true  "$BUDGET_BIG"
cr14_phase 3 CLEAN_DEVICE true "$BUDGET_BIG" "$ST1"       false "$BUDGET_BIG"
cr14_phase 4 "$ST1" true  "$BUDGET_SMALL" CLEAN_DEVICE   true  "$BUDGET_BIG"
cr14_budget_construct
CR14_BUD_FP_SMALL=$(cr14_budget_fp)
cr14_budget_values_check
cr14_phase 5 "$ST1" true  "$BUDGET_BIG"   "$ST1"         true  "$BUDGET_SMALL"
cr14_budget_compare
cr14_perf_direction
cr14_perm_phase
cr14_pipe_phase

log "--- 收尾三件套（一致性基准用相 5 的目标设备 d5t）---"
post_checks "select s1 from $DBR.d5t order by time;" tree
cmp_case_finish "" tree ""
