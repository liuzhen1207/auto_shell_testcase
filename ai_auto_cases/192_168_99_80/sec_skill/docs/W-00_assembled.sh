#!/usr/bin/env bash
# ===== PLM 自动装配（timecho-plm-shell-testcase-import）=====
# 源用例：192_168_99_80/wal_skill/W-00
# 源文件：cases\common\wal_smoke.sh sha256=049fe5eba05e21055e14c1e8c952457280c4a798e813c0a28d96db1c91da6f83
# 生成时间：2026-11-19T15:03:45+08:00
# 评估结论：ADAPT
# 注意事项：脚本（含其调用的 lib 函数）依赖 ssh 操作多节点（方案 B 已允许；PLM 分发节点私钥）; 脚本自行启停/清理/重启集群（方案 B 已允许；PLM 只按退出码判定并回收实例）; 脚本使用 -pw 参数（2026-11-12 起 PLM 执行器脚本允许保存，装配保留原文）; 脚本依赖 DN_LIST/CN_LIST 多节点遍历（方案 B 已允许；按拓扑选择模板）; cases.tsv 标注需要自行启停/重启集群（方案 B 已允许）; 用例拓扑 3C3D（方案 B 已允许；按拓扑匹配 PVE SHELL 模板）
# 说明：本文件由 PLM 导入 skill 生成；请改源仓库后重新生成，不要直接手改这里。
set -u
BASE="$(cd "$(dirname "$0")" && pwd)"
HERE="$BASE"
CLI="${PLM_CLI:-${PLM_DB_HOME:-}/sbin/start-cli.sh}"
HOST="${PLM_DB_IP:-127.0.0.1}"
SQL_HOST="${PLM_DB_IP:-127.0.0.1}"
PORT="${PLM_DB_PORT:-6667}"
DB_USER="${PLM_DB_USER:-root}"
PW="${PLM_DB_PASSWORD:-}"
NEW="${PLM_DB_VERSION:-}"
DB_DIR="${PLM_DB_HOME:-}"
LOG_DIR="${PLM_DB_LOG_DIR:-${PLM_DB_HOME:-}/logs}"
DN_LIST="${PLM_CLUSTER_DN_NODES:-${PLM_DB_NODES:-${PLM_DB_IP:-127.0.0.1}}}"
CN_LIST="${PLM_CLUSTER_CN_NODES:-${PLM_DB_NODES:-${PLM_DB_IP:-127.0.0.1}}}"
BASE_DIR="${PLM_DB_HOME:-}"
RESULT_ROOT="${PLM_WORKSPACE:-/tmp}/results"
# ===== 外挂 BM（2026-11-17）：PLM 注入子板路径 $PLM_BM_HOME 与 BM 机器连接信息 =====
# BM 母版/子板与渲染后的 conf/config.properties 都在 BM 机器上，脚本用 bm_remote 通过 SSH 调用。
if [ -n "${PLM_BM_HOME:-}" ]; then
  BM_HOME="$PLM_BM_HOME"
  PERF_BM_DIR="$PLM_BM_HOME"
else
  PERF_BM_DIR="${PERF_BM_DIR:-${PLM_TOOLS_DIR:-/opt/plm-tools}/iot-benchmark}"
  BM_HOME="${BM_HOME:-$PERF_BM_DIR}"
fi
export PERF_BM_DIR BM_HOME
BM_SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15"
if [ -n "${PLM_BM_PORT:-}" ]; then BM_SSH_OPTS="-p $PLM_BM_PORT $BM_SSH_OPTS"; fi
if [ -n "${PLM_BM_SSH_KEY:-}" ]; then BM_SSH_OPTS="$BM_SSH_OPTS -i $PLM_BM_SSH_KEY"; fi
bm_remote() {
  if [ -n "${PLM_BM_HOST:-}" ]; then
    if [ -n "${PLM_BM_SSH_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
      sshpass -p "$PLM_BM_SSH_PASSWORD" ssh $BM_SSH_OPTS "$PLM_BM_SSH_USER@$PLM_BM_HOST" "$@"
    else
      ssh $BM_SSH_OPTS "$PLM_BM_SSH_USER@$PLM_BM_HOST" "$@"
    fi
  else
    bash -lc "$*"
  fi
}
export BM_SSH_OPTS
# ===== 方案 B：历史 skill 包环境变量映射（2026-11-12）=====
# 各包 conf/env.conf 以 ${VAR:-原环境默认值} 定义路径/节点/用户；这里先按 PLM 实际值导出，
# 随后内联的 env.conf 不会覆盖已设置的值。安装目录形如 /opt/timecho/<version>。
PLM_DB_HOME_DIR="${PLM_DB_HOME:-}"
PLM_PARENT_DIR="$(dirname "$PLM_DB_HOME_DIR")"
PLM_VERSION_DIR="$(basename "$PLM_DB_HOME_DIR")"
DB_PARENT_DIR="$PLM_PARENT_DIR"
CN_DB_PARENT_DIR="$PLM_PARENT_DIR"
SHELL_CLIENT_DIR="$PLM_PARENT_DIR"
V_TESTDB="$PLM_VERSION_DIR"
NEW="$PLM_VERSION_DIR"
BUILD_TAG="$PLM_VERSION_DIR"
DB_DIR="$PLM_DB_HOME_DIR"
CN_DB_DIR="$PLM_DB_HOME_DIR"
CLIENT_DIR="$PLM_DB_HOME_DIR"
CLI_DIR="$PLM_DB_HOME_DIR"
QUERY_HOST="$HOST"
CN_NODES="$CN_LIST"
DN_NODES="$DN_LIST"
CLUSTER_NODES="$DN_LIST"
SSH_USER="${PLM_SSH_USER:-root}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no}"
ROOT_PW="${PLM_DB_PASSWORD:-}"
FRAMEWORK_DIR="${PLM_WORKSPACE:-/tmp}"
FRAMEWORK_CN_LIST="$FRAMEWORK_DIR/conf/confignode_3c.txt"
FRAMEWORK_DN_LIST="$FRAMEWORK_DIR/conf/datanode_5d.txt"
# 历史框架的 prepare_env/clean_env 不在 PLM 工作区提供；置 0 让各包走自己的 ssh 启停兜底。
USE_FRAMEWORK=0
export DB_PARENT_DIR CN_DB_PARENT_DIR SHELL_CLIENT_DIR V_TESTDB NEW BUILD_TAG DB_DIR CN_DB_DIR   CLIENT_DIR CLI_DIR QUERY_HOST CN_NODES DN_NODES CLUSTER_NODES SSH_USER SSH_OPTS ROOT_PW   FRAMEWORK_DIR FRAMEWORK_CN_LIST FRAMEWORK_DN_LIST USE_FRAMEWORK
CASE_FAILS=0
CASE_MSGS=""
fail_flag=0


# ===== inlined conf/env.conf（PLM 已覆盖路径/节点/用户/口令）=====
# ============================================================================
# 存储模块 WAL（写前日志）专项测试 skill —— 环境配置
#   这是 **WAL 专项** skill（不是合并/TTL/元数据/CRUD 专项）；入口 tools/run_all.sh。
#   **换环境只改本文件**（或用同名环境变量覆盖，例如 `V_TESTDB=… bash tools/run_all.sh`）。
#   3C3D / 三副本；data region 协议由 DATA_CONSENSUS 指定（默认 IoTConsensus）。
#   合并/集群/副本/超时变量全部保留：WAL 用例常需"写入期关合并 → flush → 观察 WAL"，
#   且收尾三件套（sync lag / 副本一致性 / 日志扫描）与其它 skill 一致，便于互相对照。
#   需求依据：`docs/req_sources/`（飞书需求/设计文档抽取）+ `docs/req_sources/source_grounding.md`（源码印证）
# ============================================================================

# ---------- 集群访问 ----------
CLUSTER_NODES="${CLUSTER_NODES:-192.168.99.77 192.168.99.78 192.168.99.79}"
CN_NODES="${CN_NODES:-$CLUSTER_NODES}"
DN_NODES="${DN_NODES:-$CLUSTER_NODES}"
SSH_USER="${SSH_USER:-root}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=15}"

# ---------- 版本与安装路径 ----------
DB_PARENT_DIR="${DB_PARENT_DIR:-/data/iotdb}"
CN_DB_PARENT_DIR="${CN_DB_PARENT_DIR:-$DB_PARENT_DIR}"
SHELL_CLIENT_DIR="${SHELL_CLIENT_DIR:-/data/iotdb/testdb}"
V_TESTDB="${V_TESTDB:-v20121rc7_1014_7c61428}"
BUILD_TAG="${BUILD_TAG:-$V_TESTDB}"

# ---------- 账号 ----------
DB_USER="${DB_USER:-root}"
ROOT_PW="${ROOT_PW:-TimechoDB@2021}"
CLUSTER_NAME="${CLUSTER_NAME:-timecho}"

# ---------- 副本与共识协议（data region 协议可指定）----------
SCHEMA_RF="${SCHEMA_RF:-3}"
DATA_RF="${DATA_RF:-3}"
# IoTConsensus（默认） | IoTConsensusV2
DATA_CONSENSUS="${DATA_CONSENSUS:-IoTConsensus}"

# ---------- WAL 核心参数（默认值取自《V1.1.0.1 写前日志-需求分析》功能定义表）----------
#   ⚠ wal_mode=DISABLE 在 IoTConsensus / IoTConsensusV2 流模式下**不被允许**（DN 启动直接失败），
#     因此 WAL_MODE 默认只取 ASYNC / SYNC；DISABLE 只用于负向用例 W-02。
WAL_MODE="${WAL_MODE:-ASYNC}"                                    # DISABLE|ASYNC|SYNC（默认 ASYNC）
WAL_ASYNC_FSYNC_MS="${WAL_ASYNC_FSYNC_MS:-1000}"                 # wal_async_mode_fsync_delay_in_ms
WAL_SYNC_FSYNC_MS="${WAL_SYNC_FSYNC_MS:-3}"                      # wal_sync_mode_fsync_delay_in_ms
WAL_BUFFER_BYTES="${WAL_BUFFER_BYTES:-33554432}"                 # wal_buffer_size_in_byte（32M）
WAL_FILE_THRESHOLD_BYTES="${WAL_FILE_THRESHOLD_BYTES:-31457280}" # wal_file_size_threshold_in_byte（30M）
WAL_MIN_EFF_RATIO="${WAL_MIN_EFF_RATIO:-0.1}"                    # wal_min_effective_info_ratio
WAL_SNAPSHOT_THRESHOLD_BYTES="${WAL_SNAPSHOT_THRESHOLD_BYTES:-8388608}" # wal_memtable_snapshot_threshold_in_byte（8MB）
WAL_MAX_SNAPSHOT_NUM="${WAL_MAX_SNAPSHOT_NUM:-1}"                # max_wal_memtable_snapshot_num
WAL_DELETE_PERIOD_MS="${WAL_DELETE_PERIOD_MS:-20000}"            # delete_wal_files_period_in_ms
WAL_THROTTLE_BYTES="${WAL_THROTTLE_BYTES:-214748364800}"         # wal_throttle_threshold_in_byte（200G）
WAL_COMPRESSION="${WAL_COMPRESSION:-true}"                       # enable_wal_compression
WAL_MAX_NODES="${WAL_MAX_NODES:-0}"                              # max_wal_nodes_num（0=系统自行决定）

# 把上面默认值拼成一份可写进 DN 配置的组合（用例按需追加覆盖项）
WAL_EXTRA_DEFAULT="${WAL_EXTRA_DEFAULT:-wal_mode=${WAL_MODE},enable_wal_compression=${WAL_COMPRESSION},wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${WAL_FILE_THRESHOLD_BYTES},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES}}"

# ---------- TTL 参数（**WAL 用例不用 TTL**，但 lib/common.sh 会写这三个键）----------
#   为什么 WAL skill 也要定义它们：`lib/common.sh:405-440` 的 `cluster_set_conf()` 在
#   **未加引号的 heredoc** 里引用这三个变量（`set_prop ttl_check_interval $TTL_CHECK_INTERVAL_MS` …），
#   `set -u` 下变量未定义 ⇒ `TTL_CHECK_INTERVAL_MS: unbound variable` ⇒ ssh 写配置退出非 0 ⇒
#   `FAIL 写配置失败: <ip>`（RC8 首轮 W-06/W-07/W-08/W-09/W-10 全部 ~26s 瞬时失败即此因；
#   另有 22 条用例各自在脚本里用 `: "${TTL_CHECK_INTERVAL_MS:=…}"` 打了补丁，值还不一致）。
#   这里给出**唯一权威默认值**（与 compaction_skill 的 conf/env.conf 对齐）。
#   WAL 用例不测 TTL ⇒ 取**中性值**：检查周期 2h（几乎不跑）、永不过期（Long.MAX）、
#   比例 1.0（不触发按比例清理）⇒ 不会有 TTL/Settle 合并混进观测
#   （settle 重写会删掉 WAL 文件、改变 TsFile 文件面，污染 WAL 用例判据）。
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"        # ttl_check_interval（毫秒，2h）
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"  # max_expired_time（Long.MAX_VALUE）
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"                  # expired_data_ratio（1.0 = 不按比例清理）

# ---------- 合并参数（WAL 用例用：写入期关合并，避免合并把 WAL 变无效而干扰观测）----------
CMP_CANDIDATE_NUM="${CMP_CANDIDATE_NUM:-2}"          # inner_compaction_candidate_file_num
CMP_INTERVAL_MS="${CMP_INTERVAL_MS:-1000}"           # compaction_schedule_interval_in_ms
CMP_EXTRA_CONF="${CMP_EXTRA_CONF:-enable_seq_space_compaction=true,enable_unseq_space_compaction=true,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}}"
CMP_EXTRA_CROSS="${CMP_EXTRA_CROSS:-enable_seq_space_compaction=true,enable_unseq_space_compaction=true,enable_cross_space_compaction=true,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}}"
CMP_EXTRA_WRITE="${CMP_EXTRA_WRITE:-enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}}"

# ---------- 用例规模与窗口 ----------
WAL_DEVS="${WAL_DEVS:-6}"              # 设备数
WAL_ROWS="${WAL_ROWS:-300}"            # 每设备每批点数
WAL_BATCHES="${WAL_BATCHES:-3}"        # 冒烟写几批
WAL_WIN_SEC="${WAL_WIN_SEC:-120}"      # 通用观察窗口（秒）
WAL_CLOSE_WIN_SEC="${WAL_CLOSE_WIN_SEC:-60}"   # 等 TsFile 落盘（Async close）的窗口

# ---------- 恢复类用例（W-04~W-07 / W-12 / W-19）----------
WAL_KILL_WAIT_SEC="${WAL_KILL_WAIT_SEC:-60}"   # kill -9 前的写入稳定等待
WAL_REPLAY_WIN_SEC="${WAL_REPLAY_WIN_SEC:-300}" # 重启后等 WAL 重放完成/数据可见的窗口
WAL_KILL_MODE="${WAL_KILL_MODE:-9}"            # 9=kill -9（模拟掉电）；15=kill（优雅停）

# ---------- 文件面用例（W-08~W-10）----------
WAL_ROTATE_THRESHOLD_SMALL="${WAL_ROTATE_THRESHOLD_SMALL:-1048576}"  # 1MB：让 WAL 快速轮转
WAL_BUFFER_SMALL="${WAL_BUFFER_SMALL:-262144}"                       # 256KB：切分 buffer
WAL_ROTATE_MIN_FILES="${WAL_ROTATE_MIN_FILES:-2}"                    # 至少应看到几个 WAL 文件（场景有效性）

# ---------- 压缩用例（W-11~W-13）----------
#   文档《软件测试文档》给的经验值：压缩率约 3（Wal size 对比），写性能影响不大、查询略降。
#   ⇒ 断言只做"压缩后总字节 ≤ 未压缩 × 阈值"，且默认宽松（压缩率依赖数据可压性，不能当产品门禁）。
WAL_COMPRESS_RATIO_MIN="${WAL_COMPRESS_RATIO_MIN:-1.2}"   # 压缩后至少应缩小到这个倍数（低于此只 WARN）
WAL_COMPRESS_DEVS="${WAL_COMPRESS_DEVS:-10}"
WAL_COMPRESS_ROWS="${WAL_COMPRESS_ROWS:-2000}"
WAL_COMPRESS_BATCHES="${WAL_COMPRESS_BATCHES:-4}"

# ---------- 清理 / 快照（W-14~W-16）----------
WAL_CLEAN_PERIOD_SMALL_MS="${WAL_CLEAN_PERIOD_SMALL_MS:-2000}"  # 2s：加快无效 WAL 清理
WAL_CLEAN_WIN_SEC="${WAL_CLEAN_WIN_SEC:-180}"                   # 等清理发生的窗口

# ---------- 内存 / 阻写（W-17~W-18）----------
WAL_THROTTLE_SMALL="${WAL_THROTTLE_SMALL:-10485760}"  # 10MB：让阻写更容易触发
WAL_PRESSURE_DEVS="${WAL_PRESSURE_DEVS:-20}"
WAL_PRESSURE_ROWS="${WAL_PRESSURE_ROWS:-20000}"
WAL_PRESSURE_WIN_SEC="${WAL_PRESSURE_WIN_SEC:-300}"
WAL_HEAP_WARN_RATIO="${WAL_HEAP_WARN_RATIO:-0.9}"     # DN 堆使用率超过该比例只 WARN（不判 FAIL）

# ---------- 端口 ----------
DN_RPC_PORT="${DN_RPC_PORT:-6667}"
CN_INTERNAL_PORT="${CN_INTERNAL_PORT:-10710}"
CN_CONSENSUS_PORT="${CN_CONSENSUS_PORT:-10720}"
DN_INTERNAL_PORT="${DN_INTERNAL_PORT:-10730}"
DN_MPP_PORT="${DN_MPP_PORT:-10740}"
DN_SCHEMA_CONSENSUS_PORT="${DN_SCHEMA_CONSENSUS_PORT:-10750}"
DN_DATA_CONSENSUS_PORT="${DN_DATA_CONSENSUS_PORT:-10760}"
CN_METRIC_PORT="${CN_METRIC_PORT:-9091}"
DN_METRIC_PORT="${DN_METRIC_PORT:-9092}"

# ---------- Prometheus（可选指标源；留空则直连各 DN 的 /metrics）----------
# 本环境（99.80）已就绪：Prometheus 0.0.0.0:9090，scrape_interval=10s，
# 已抓取 3×DN(:9092) + 3×CN(:9091)，标签含 cluster / nodeType / instance / region。
# 用法（lib 内部）：curl -s -G "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=<promql>"
#   带账号时再加 -u "$PROMETHEUS_USER:$PROMETHEUS_PASS"（本环境无需认证）。
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
PROMETHEUS_USER="${PROMETHEUS_USER:-}"
PROMETHEUS_PASS="${PROMETHEUS_PASS:-}"
PROMETHEUS_CLUSTER="${PROMETHEUS_CLUSTER:-${CLUSTER_NAME:-timecho}}"
PROM_SCRAPE_INTERVAL="${PROM_SCRAPE_INTERVAL:-10}"
PROMETHEUS_TIMEOUT="${PROMETHEUS_TIMEOUT:-20}"
# syncLag 等指标类判据的数据源：auto（Prometheus 有数据就用）/ prom（只用 Prometheus）/ direct（只直连）
SYNC_LAG_SOURCE="${SYNC_LAG_SOURCE:-auto}"

# ---------- 集群生命周期 ----------
USE_FRAMEWORK="${USE_FRAMEWORK:-1}"
FRAMEWORK_DIR="${FRAMEWORK_DIR:-/data/iotdb/autotest}"
FRAMEWORK_CN_LIST="${FRAMEWORK_CN_LIST:-$FRAMEWORK_DIR/conf/confignode_3c.txt}"
FRAMEWORK_DN_LIST="${FRAMEWORK_DN_LIST:-$FRAMEWORK_DIR/conf/datanode_3d.txt}"

# ---------- 超时（秒） ----------
CLUSTER_READY_TIMEOUT="${CLUSTER_READY_TIMEOUT:-600}"
SYNC_TIMEOUT_SEC="${SYNC_TIMEOUT_SEC:-600}"
SYNC_STABLE_CHECKS="${SYNC_STABLE_CHECKS:-3}"
CLEANUP_WAIT_SEC="${CLEANUP_WAIT_SEC:-180}"
DN_DOWN_WAIT_SEC="${DN_DOWN_WAIT_SEC:-180}"
DN_RECOVER_WAIT_SEC="${DN_RECOVER_WAIT_SEC:-300}"
SQL_TIMEOUT_SEC="${SQL_TIMEOUT_SEC:-600}"

# ---------- 结果与产物 ----------
LOG_BACKUP="${LOG_BACKUP:-1}"

# ===== PLM 注入覆盖（append，优先级最高）=====
if [ -n "${PLM_DB_HOME:-}" ]; then
  _plm_parent="$(dirname "$PLM_DB_HOME")"
  _plm_ver="$(basename "$PLM_DB_HOME")"
  DB_PARENT_DIR="${PLM_PARENT_DIR:-$_plm_parent}"
  CN_DB_PARENT_DIR="$DB_PARENT_DIR"
  SHELL_CLIENT_DIR="${PLM_PARENT_DIR:-$_plm_parent}"
  V_TESTDB="${PLM_DB_VERSION:-$_plm_ver}"
  BUILD_TAG="$V_TESTDB"
  ROOT_PW="${PLM_DB_PASSWORD:-$ROOT_PW}"
  [ -n "${PLM_CLUSTER_CN_NODES:-}" ] && { CN_NODES="$PLM_CLUSTER_CN_NODES"; CLUSTER_NODES="$PLM_CLUSTER_CN_NODES"; }
  [ -n "${PLM_CLUSTER_DN_NODES:-}" ] && { DN_NODES="$PLM_CLUSTER_DN_NODES"; CLUSTER_NODES="$PLM_CLUSTER_DN_NODES"; }
  [ -n "${PLM_SSH_USER:-}" ] && SSH_USER="$PLM_SSH_USER"
  [ -n "${PLM_DB_IP:-}" ] && { PRIMARY="$PLM_DB_IP"; HOST="$PLM_DB_IP"; }
fi

# ===== inlined lib: cmp.sh =====
# ============================================================================
# 合并（compaction）专项 skill —— 专用 helper（在 lib/common.sh 之上）
#   ① 造数据（树/表模型，可按批次控制时间戳 → 造 seq / unseq 文件）
#   ② TsFile 观测（seq/unseq 文件数、字节数、文件清单、最大文件）
#   ③ 合并观测（starts/finishes/类型、等合并、写放大、卡死线程 jstack）
#   ④ 合并参数（模板键、实际生效值、热改）
#   ⑤ REMOVE DATANODE / CONFIGNODE（节点 id 解析、移除、集群节点查询）
# ============================================================================

# ---------------------------------------------------------------------------
# ① 造数据
# ---------------------------------------------------------------------------
# 树模型建库 + 建设备时序：cmp_make_tree_db <db> <devs> [类型] [编码]
cmp_make_tree_db(){ local db=$1 devs=$2 dtype=${3:-int64} enc=${4:-} d
  sq "create database $db;" >/dev/null
  for ((d=1; d<=devs; d++)); do
    if [ -n "$enc" ]; then sq "create timeseries $db.d$d.s1 with datatype=$dtype encoding=$enc;" >/dev/null
    else sq "create timeseries $db.d$d.s1 with datatype=$dtype;" >/dev/null; fi
  done; }
# 任意一条建时序语句（多类型/多编码用例用）
cmp_add_series(){ sq "create timeseries $1;" >/dev/null; }
# 写一批树模型数据：cmp_write_tree_batch <db> <devs> <rows> <batch_no> [时间戳基准ms] [是否降序]
#   时间戳基准决定数据落在哪个时间分区；batch_no 让各批不同（默认递增 → seq）
#   传 base 且用 --desc 可以让本批时间戳整体早于上一批 → 落到 unseq 文件
cmp_write_tree_batch(){ local db=$1 devs=$2 rows=$3 b=${4:-1} base=${5:-} desc=${6:-no}
  local start
  if [ -n "$base" ]; then start=$base; else start=$(( ($(date +%s) - 3600) * 1000 + b * 1000000 )); fi
  local d i
  for ((d=1; d<=devs; d++)); do
    local vals="" k off ts
    for ((k=0;k<rows;k++)); do
      off=$k; [ "$desc" = yes ] && off=$(( rows-1-k ))
      ts=$(( start + off * 10 ))
      vals="$vals($ts,$((k+b))),"
      # 500 行/语句
      if [ $(( (k+1) % 500 )) -eq 0 ]; then sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null || return 1; vals=""; fi
    done
    [ -n "$vals" ] && { sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null || return 1; }
  done
  sq "flush;" >/dev/null; }
# 表模型建库 + 两张表（t1/t2）：cmp_make_table_db <db>
cmp_make_table_db(){ local db=$1 t1=${2:-t1} t2=${3:-t2} out
  sql_lines_table "create database $db;" >/dev/null
  out=$(sqt "create table $db.$t1 (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD);")
  printf '%s' "$out" | grep -q 'successfully' || warn "建表 $db.$t1 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  if [ -n "$t2" ]; then
    out=$(sqt "create table $db.$t2 (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD);")
    printf '%s' "$out" | grep -q 'successfully' || warn "建表 $db.$t2 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  fi
  local tbls; tbls=$(sqt "show tables from $db;")
  printf '%s' "$tbls" | grep -q "$t1" && pass "建表成功：$db.$t1" || fail "场景无效：$db.$t1 未建成"
  [ -n "$t2" ] && { printf '%s' "$tbls" | grep -q "$t2" && pass "建表成功：$db.$t2" || fail "场景无效：$db.$t2 未建成"; }
}
# 写一批表模型数据：cmp_write_table_batch <db> <table> <devs> <rows> <batch_no> [base] [desc]
cmp_write_table_batch(){ local db=$1 tb=$2 devs=$3 rows=$4 b=${5:-1} base=${6:-} desc=${7:-no}
  local start
  if [ -n "$base" ]; then start=$base; else start=$(( ($(date +%s) - 3600) * 1000 + b * 1000000 )); fi
  local d k vals="" off ts
  for ((d=1; d<=devs; d++)); do
    vals=""
    for ((k=0;k<rows;k++)); do
      off=$k; [ "$desc" = yes ] && off=$(( rows-1-k ))
      ts=$(( start + off * 10 ))
      vals="$vals($ts,'d$d',$((k+b))),"
      if [ $(( (k+1) % 500 )) -eq 0 ]; then sqt "insert into $db.$tb (time, dev, v) values ${vals%,};" >/dev/null || return 1; vals=""; fi
    done
    [ -n "$vals" ] && { sqt "insert into $db.$tb (time, dev, v) values ${vals%,};" >/dev/null || return 1; }
  done
  sqt "flush;" >/dev/null; }

# ---------------------------------------------------------------------------
# ② TsFile 观测（数据目录：data/datanode/data/{sequence,unsequence}/<db>/<partition>/<region>/）
# ---------------------------------------------------------------------------
cmp_tsfile_cnt_dir(){ local h=$1 db=$2 kind=$3 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data/$kind -path '*/$db/*' -name '*.tsfile' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
cmp_seq_cnt(){ cmp_tsfile_cnt_dir "$1" "$2" sequence; }
cmp_unseq_cnt(){ cmp_tsfile_cnt_dir "$1" "$2" unsequence; }
cmp_sum_over_dn(){ local f=$1 db=$2 h s=0; for h in "${DN[@]}"; do s=$((s + $($f "$h" "$db"))); done; echo "$s"; }
cmp_seq_sum(){ cmp_sum_over_dn cmp_seq_cnt "$1"; }
cmp_unseq_sum(){ cmp_sum_over_dn cmp_unseq_cnt "$1"; }
# ⚠️ cmp_all_sum = **seq + unseq** 之和。它可以用来判"合并推进 / 文件数**下降**"，
#   **不要**用它判"归零（== 0）"：V2 下 follower 收到的复制文件全部落在 **unsequence**
#   （DataRegion.java:4984 setSeq(false) / :5009 loadTsFileToUnSequence）⇒
#   seq 已归零而 unseq 还有残留时 all_sum 永远不会是 0。
#   CO-41 C 相 `FAIL C 相 TsFile 数未归零（2，各副本 77=0 78=0 79=0）` 就是
#   "判据用 all_sum、回显用 seq_cnt" 造成自相矛盾（2026-10-17 定性）。
#   ⇒ **"归零"一律用 cmp_seq_sum**（或逐副本 cmp_seq_cnt）；all_sum 只用于"下降/变更"类判据。
cmp_all_sum(){ echo $(( $(cmp_seq_sum "$1") + $(cmp_unseq_sum "$1") )); }
# 单副本该库 TsFile 总数（seq + unseq）—— 逐副本"文件数不增加"类判据用
cmp_all_cnt_node(){ echo $(( $(cmp_seq_cnt "$1" "$2") + $(cmp_unseq_cnt "$1" "$2") )); }
cmp_per_node(){ local f=$1 db=$2 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$($f "$h" "$db") "; done; echo "$out"; }
# 该库 TsFile 的物理字节数（seq / unseq 合计）
cmp_bytes(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
cmp_bytes_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_bytes "$h" "$db"))); done; echo "$s"; }
# 该库 TsFile 名字（证据）
cmp_tsfile_list(){ local h=$1 db=$2; sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%p\n' 2>/dev/null | sed 's#.*/##' | sort"; }
# 该库最大 TsFile 字节数（验证 target_compaction_file_size 效果时用）
cmp_max_tsfile_bytes(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%s\n' 2>/dev/null | sort -n | tail -1" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
cmp_max_tsfile_bytes_sum(){ local db=$1 h m=0 v; for h in "${DN[@]}"; do v=$(cmp_max_tsfile_bytes "$h" "$db"); [ "${v:-0}" -gt "$m" ] && m=$v; done; echo "$m"; }

# ---------------------------------------------------------------------------
# ③ 合并观测
# ---------------------------------------------------------------------------
# 合并日志文件列表。**必须用函数而不是变量**：写成单引号变量时 `$DB_DIR` 不会被展开，
# 插进 ssh 命令后远端再展开（远端没有 DB_DIR）⇒ 匹配恒为 0（本项目踩过）。
cmp_log_files(){ echo "$DB_DIR/logs/log_datanode_compaction.log $DB_DIR/logs/log_datanode_all.log"; }
# 全部 DN 上所有库的 starts / finishes（check_logs 的正证据用）
cmp_start_cnt_all(){ local h s=0; for h in "${DN[@]}"; do s=$((s + $(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hcF 'Compaction task starts'" 2>/dev/null | tr -dc '0-9'))); done; echo "$s"; }
cmp_finish_cnt_all(){ local h s=0; for h in "${DN[@]}"; do s=$((s + $(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hcF 'Compaction task finishes successfully'" 2>/dev/null | tr -dc '0-9'))); done; echo "$s"; }
# 某库的 inner / cross 完成行数（单调递增）
cmp_cnt_db(){ local h=$1 db=$2 pat=$3 v
  v=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 某库的 inner / cross 完成行数（单调递增）
cmp_cnt_db(){ local h=$1 db=$2 pat=$3 v
  v=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
cmp_inner_finish(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'InnerSpaceCompaction task finishes successfully'))); done; echo "$s"; }
cmp_inner_start(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'InnerSpaceCompaction task starts with'))); done; echo "$s"; }
# ⚠️ cross 的 pattern **必须**带 `[Compaction] ` 前缀（与同文件 cmp_task_nums / cmp_task_cnt /
#   cmp_cross_unseq_nums 的 cross 分支口径一致）。日志里两条"完成行"分别是
#     `… [Compaction] CrossSpaceCompaction task finishes successfully`
#     `… [Compaction] InsertionCrossSpaceCompaction task finishes successfully`
#   子串口径（不带前缀）会把 **Insertion（把 unseq 文件直接搬进 seq 空间）** 那条一起数进来。
#   IoTConsensusV2 下 follower 收到的 TsFile 全在 unseq 空间（IoTConsensusV2Receiver.java:734 →
#   DataRegion.java:4984 setSeq(false)/:5009），Insertion 任务频繁出现 ⇒ CO-04 的负向相
#   （窗口内不应出现跨空间合并完成）会被误判成"min_cross_compaction_unseq_file_level 门控失效"。
#   注：cmp_inner_finish / cmp_inner_start **故意不加**前缀——它们就是要合计
#   `[Compaction] Sequence|Unsequence InnerSpaceCompaction …` 两种段名（加前缀反而不匹配）。
cmp_cross_finish(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" '[Compaction] CrossSpaceCompaction task finishes successfully'))); done; echo "$s"; }
# 按"顺序空间 / 乱序空间"分开数（组合矩阵用例要用：开关矩阵要能区分是哪一类 inner 合并跑了）
# 日志形如：`root.db-3 [Compaction] Sequence InnerSpaceCompaction task finishes successfully`
# 口径审查（2026-10-16，整族 helper 一次过）：这四个是**精确段名**（Sequence/Unsequence 互不为子串，
#   也不被 SettleCompaction/InsertionCrossSpaceCompaction 命中）⇒ 不需要前缀；
#   只有"以 CrossSpace 开头的段名"会被 `InsertionCrossSpace…` 子串命中 ⇒ 已在上面收紧。
cmp_seq_inner_finish(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'Sequence InnerSpaceCompaction task finishes successfully'))); done; echo "$s"; }
cmp_unseq_inner_finish(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'Unsequence InnerSpaceCompaction task finishes successfully'))); done; echo "$s"; }
cmp_seq_inner_start(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'Sequence InnerSpaceCompaction task starts with'))); done; echo "$s"; }
cmp_unseq_inner_start(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'Unsequence InnerSpaceCompaction task starts with'))); done; echo "$s"; }
cmp_log_tail(){ local h=$1 db=$2
  sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hE '(root\.)?$db-[0-9]+ \[Compaction\]' | tail -5" 2>/dev/null; }
# ---------------------------------------------------------------------------
# DataNode 的**真实** JVM pid（远端解析 /proc/<pid>/exe）
#   坑（P0 级，2026-10-20 由 WAL 侧实测确认）：`pgrep -f com.timecho.iotdb.DataNode` 会匹配到
#   **这条检查命令自己的 `bash -c` 包装 shell**（它的命令行里就含该字符串）⇒ 取到的 pid 是 shell
#   而不是 DataNode JVM ⇒ `jstack` 打空 ⇒ `cmp_stuck_sum` 恒 0 ⇒ "无合并线程卡死"变成**假 PASS**
#   （CO-01…CO-11、DT-04、CO-15/39/41 等用例的"卡死线程=0"都靠这条）。
# 做法（照 WAL 侧已验证的 `wal_dn_pid`）：扫远端 `/proc/*/cmdline`，只认**可执行文件是 java**
#   （`${c%% *}` 以 java 结尾）且命令行含 `DataNode` 的进程 ⇒ bash/sh/grep/pgrep/启动脚本天然被排除；
#   找不到就回显空串（调用方按"不可观测"处理，不要当成 0）。
cmp_dn_pid(){ sshx "$1" 'for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null) || continue
    x=${c%% *}
    case "$x" in *java) ;; *) continue ;; esac
    case "$c" in *DataNode*) echo "${p#/proc/}"; break ;; esac
  done' 2>/dev/null | tr -d '\r' | head -1; }
# 卡在 TsFileResource.writeLock 的线程数（合并卡死类问题的直接证据）
#   回显 **-1 = 不可观测**（拿不到 DataNode 的 JVM pid，或 jstack 里没有线程头）。
#   调用方必须把 -1 当 WARN，**不允许**当成 0（否则"无卡死线程"是假 PASS）。
cmp_stuck_cnt(){ local h=$1 pid d n
  pid=$(cmp_dn_pid "$h")
  [ -n "${pid:-}" ] || { echo -1; return; }
  d=$(sshx "$h" "jstack $pid 2>/dev/null" 2>/dev/null)
  n=$(printf '%s\n' "$d" | grep -c '^"'); n=${n:-0}
  [ "$n" -ge 1 ] || { echo -1; return; }
  printf '%s\n' "$d" | grep -c 'TsFileResource.writeLock' | tr -dc '0-9'; }
# 全部 DN 求和；任一节点不可观测(-1) ⇒ 回显 -1（调用方打 WARN，不判 PASS）
cmp_stuck_sum(){ local h v s=0
  for h in "${DN[@]}"; do v=$(cmp_stuck_cnt "$h"); v=${v:--1}
    [ "$v" = "-1" ] && { echo -1; return; }
    s=$(( s + v ))
  done; echo "$s"; }
# 统一断言"无合并线程卡死"：0 ⇒ PASS；-1 ⇒ WARN（不可观测，**不判 PASS**）；>0 ⇒ FAIL。
# 用例里不要再写 `[ "$(cmp_stuck_sum)" -eq 0 ] && pass ...`（那会把 -1 也算成 0）。
cmp_assert_no_stuck(){ local label=${1:-无合并线程卡死} v
  v=$(cmp_stuck_sum); v=${v:--1}
  case "$v" in
    0)  pass "  $label（TsFileResource.writeLock 线程数=0）" ;;
    -1) warn "  $label：**不可观测**（取不到 DataNode 的 JVM pid 或 jstack 无线程头）⇒ 本项不判 PASS，仅记录（Pgrep 自匹配曾被当 0 = 假 PASS）" ;;
    *)  fail "  $label：有 $v 个线程卡在 TsFileResource.writeLock" ;;
  esac; }
# 等合并推进：<db> <finish 基线> <tsfile 基线> <窗口秒>；0=推进 / 1=超时
cmp_wait_merge(){ local db=$1 fin0=$2 ts0=$3 win=$4 f t first_ts=""
  local deadline=$(( $(date +%s) + win ))
  while (( $(date +%s) < deadline )); do
    sleep 5
    f=$(cmp_inner_finish "$db"); t=$(cmp_all_sum "$db")
    [ -z "$first_ts" ] && first_ts=$t
    log "    等合并: finishes=$f(基线$fin0) tsfile=$t(基线$ts0 首次$first_ts)"
    if [ "$f" -gt "$fin0" ] && { [ "$t" -lt "$ts0" ] || [ "$t" -lt "$first_ts" ]; }; then
      echo "finishes:$f tsfile:$t"; return 0; fi
  done
  echo "finishes:${f:-0} tsfile:${t:-0}"; return 1; }
# 等 unseq 文件数降到 want 以下（cross space compaction 的判据）
cmp_wait_unseq(){ local db=$1 want=$2 win=$3 u
  local deadline=$(( $(date +%s) + win ))
  while (( $(date +%s) < deadline )); do
    sleep 5; u=$(cmp_unseq_sum "$db")
    log "    等 unseq：unseq=$u（目标 <=$want）"
    [ "${u:-0}" -le "$want" ] && { echo "$u"; return 0; }
  done
  echo "${u:-0}"; return 1; }
# 数据指纹：某 SQL 的归一化结果（用于"合并前后数据完全一致"的断言）
cmp_fingerprint(){ local dialect=$1 sql=$2
  if [ "$dialect" = table ]; then norm_result "$(sqt "$sql")"; else norm_result "$(sq "$sql")"; fi; }
# 树模型指纹：count 与 sum **分开查**——`select count(s1), sum(s1), min(s1), max(s1) from db.**`
# 在通配路径上会报 `701: Raw data and aggregation hybrid query is not supported`（实测踩到）。
cmp_fp_tree(){ local db=$1 c s
  c=$(row_sum "$(sq "select count(s1) from $db.**;")")
  s=$(row_sum "$(sq "select sum(s1) from $db.**;")")
  echo "count=$c sum=$s"; }
# 单序列/单设备的树模型指纹
cmp_fp_tree_dev(){ local path=$1 c s
  c=$(row_sum "$(sq "select count(s1) from $path.**;")")
  s=$(row_sum "$(sq "select sum(s1) from $path.**;")")
  echo "count=$c sum=$s"; }
# 表模型指纹
cmp_fp_table(){ local tbl=$1 c s
  c=$(sqt "select count(v) from $tbl;" | table_rows | head -1 | awk -F'|' '{print ($2+0)}')
  s=$(sqt "select sum(v) from $tbl;" | table_rows | head -1 | awk -F'|' '{print ($2+0)}')
  echo "count=$c sum=$s"; }
# 写入阶段关掉三类合并（保证"写完再开合并"可复现；顺带避免合并在写入期间就把文件并掉）
cmp_compaction_off(){ local k
  for k in enable_seq_space_compaction enable_unseq_space_compaction enable_cross_space_compaction; do
    cmp_set_hot "$k" false >/dev/null 2>&1 || true
  done
  log "  已热关三类合并：seq=$(cmp_eff "${DN[0]}" enable_seq_space_compaction) unseq=$(cmp_eff "${DN[0]}" enable_unseq_space_compaction) cross=$(cmp_eff "${DN[0]}" enable_cross_space_compaction)"
}
# 写入后打开需要的合并类型：cmp_compaction_on [seq] [unseq] [cross]
cmp_compaction_on(){ local seq=${1:-true} unseq=${2:-true} cross=${3:-false}
  cmp_set_hot enable_seq_space_compaction "$seq" >/dev/null 2>&1 || true
  cmp_set_hot enable_unseq_space_compaction "$unseq" >/dev/null 2>&1 || true
  cmp_set_hot enable_cross_space_compaction "$cross" >/dev/null 2>&1 || true
  log "  已热开合并：seq=$(cmp_eff "${DN[0]}" enable_seq_space_compaction) unseq=$(cmp_eff "${DN[0]}" enable_unseq_space_compaction) cross=$(cmp_eff "${DN[0]}" enable_cross_space_compaction)"
}
# 指定节点上执行并归一化（REMOVE 场景：经剩余节点校验）
cmp_fingerprint_on(){ local node=$1 dialect=$2 sql=$3
  if [ "$dialect" = table ]; then norm_result "$(sqt_node "$node" "$sql")"; else norm_result "$(sq_node "$node" "$sql")"; fi; }
# 经一组节点查询并断言都与基准一致
cmp_assert_nodes_same(){ local label=$1 base=$2 dialect=$3 sql=$4 nodes_str=$5 h cur
  local nodes=(); read -ra nodes <<<"$nodes_str"
  for h in "${nodes[@]}"; do
    cur=$(cmp_fingerprint_on "$h" "$dialect" "$sql")
    [ "$cur" = "$base" ] && pass "$label：经 $h 与基准一致" \
      || fail "$label：经 $h 与基准不一致 [$(printf '%s' "$cur" | tr '\n' ' ' | cut -c1-160)] vs [$(printf '%s' "$base" | tr '\n' ' ' | cut -c1-160)]"
  done; }
cmp_assert_same(){ local label=$1 a=$2 b=$3
  if [ "$a" = "$b" ]; then pass "$label：与合并前完全一致"; else
    fail "$label：与合并前不一致"; printf '  合并前: %s\n  合并后: %s\n' "$(printf '%s' "$a" | tr '\n' ' ' | cut -c1-300)" "$(printf '%s' "$b" | tr '\n' ' ' | cut -c1-300)" >>"$OUT"
  fi; }

# ---------------------------------------------------------------------------
# ④ 合并参数（模板 / 生效值 / 热改）
# ---------------------------------------------------------------------------
CMP_KEYS='enable_seq_space_compaction enable_unseq_space_compaction enable_cross_space_compaction enable_auto_repair_compaction cross_selector cross_performer inner_seq_selector inner_seq_performer inner_unseq_selector inner_unseq_performer compaction_priority candidate_compaction_task_queue_size target_compaction_file_size inner_compaction_total_file_size_threshold inner_compaction_total_file_num_threshold max_level_gap_in_inner_compaction chunk_size_lower_bound_in_compaction chunk_point_num_lower_bound_in_compaction inner_compaction_candidate_file_num max_cross_compaction_candidate_file_num max_cross_compaction_candidate_file_size min_cross_compaction_unseq_file_level compaction_thread_count compaction_max_aligned_series_num_in_one_batch compaction_schedule_interval_in_ms compaction_write_throughput_mb_per_sec compaction_read_throughput_mb_per_sec compaction_read_operation_per_sec sub_compaction_thread_count inner_compaction_task_selection_disk_redundancy inner_compaction_task_selection_mods_file_threshold compaction_schedule_thread_num target_chunk_point_num target_chunk_size chunk_metadata_size_proportion'
# 安装包配置模板里的键（静态检查）
cmp_tpl_has(){ local h=$1 k=$2 n; n=$(sshx "$h" "grep -cE '^$k=' $DB_DIR/conf/iotdb-system.properties.template 2>/dev/null" 2>/dev/null | tr -dc '0-9'); echo "${n:-0}"; }
# 某键实际生效值（表方言 show configuration 第 3 列 = 当前值）
cmp_eff(){ local h=$1 k=$2 out; out=$(sqt_node "$h" 'show configuration;' 2>/dev/null)
  printf '%s\n' "$out" | awk -F'|' -v k="$k" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3)} $2==k{print $3; exit}'; }
cmp_eff_all(){ local h=$1 k out=""; out=$(sqt_node "$h" 'show configuration;' 2>/dev/null)
  for k in $CMP_KEYS; do printf '%s=%s ' "$k" "$(printf '%s\n' "$out" | awk -F'|' -v k="$k" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3)} $2==k{print $3; exit}')"; done; echo; }
# 热改并返回 CLI 的原始响应（用于判断是否需要重启）
cmp_set_hot(){ sq "set configuration '$1'='$2';" 2>&1 | tr '\n' ' '; }
# 判定某个键是否是热加载：回显响应，hot→yes / 需要重启→no
cmp_is_hot_key(){ local resp; resp=$(cmp_set_hot "$1" "$2"); log "    SET $1=$2 → $(printf '%s' "$resp" | cut -c1-160)"
  printf '%s' "$resp" | grep -qiE 'restart is required' && echo no || echo yes; }

# ---------------------------------------------------------------------------
# ⑤ REMOVE DATANODE / CONFIGNODE
# ---------------------------------------------------------------------------
# show cluster 解析（列序：$1='' $2=NodeID $3=NodeType $4=Status $5=InternalAddress ...）
# cmp_node_ids <DataNode|ConfigNode> → "<ip>=<id> ..."
cmp_node_ids(){ local kind=$1
  sq 'show cluster;' 2>/dev/null | awk -F'|' -v k="$kind" '{gsub(/[ \t]/,"",$3);gsub(/[ \t]/,"",$5)} $3==k{printf "%s=%s ", $5, $2}'; echo; }
cmp_node_id_of(){ local kind=$1 ip=$2
  sq 'show cluster;' 2>/dev/null | awk -F'|' -v k="$kind" -v ip="$ip" '{gsub(/[ \t]/,"",$3);gsub(/[ \t]/,"",$5)} $3==k && $5==ip{print $2; exit}'; }
cmp_running_cnt(){ sq 'show cluster;' 2>/dev/null | grep -cE 'Running|ReadOnly'; }
cmp_remove_dn(){ local id=$1; sq "remove datanode $id;"; }
cmp_remove_cn(){ local id=$1; sq "remove confignode $id;"; }
# 等某个节点（任意类型）从 show cluster 里消失
cmp_wait_node_gone(){ local kind=$1 ip=$2 win=${3:-240} st
  local deadline=$(( $(date +%s) + win ))
  while (( $(date +%s) < deadline )); do
    st=$(sq 'show cluster;' 2>/dev/null | awk -F'|' -v k="$kind" -v ip="$ip" '{gsub(/[ \t]/,"",$3);gsub(/[ \t]/,"",$5)} $3==k && $5==ip{print "yes"; exit}')
    [ -z "$st" ] && return 0
    sleep 5
  done
  return 1; }
cmp_node_cnt(){ local kind=$1; sq 'show cluster;' 2>/dev/null | awk -F'|' -v k="$kind" '{gsub(/[ \t]/,"",$3)} $3==k{c++} END{print c+0}'; }

# ---------------------------------------------------------------------------
# ⑥ 性能基准
# ---------------------------------------------------------------------------
# 单个 CLI 会话里批量写入（性能用例必须用这个：`sq` 每次都会新起一个 CLI/JVM，
# 逐条调用时写入耗时被进程启动开销主导，测出来的是 CLI 而不是存储引擎）。
# 用法： cmp_bulk_tree_session <db> <devs> <rows> <batch_no> [base] [batch_size]
cmp_bulk_tree_session(){ local db=$1 devs=$2 rows=$3 b=${4:-1} base=${5:-} bs=${6:-500}
  local start stmts=() d k vals=""
  if [ -n "$base" ]; then start=$base; else start=$(( ($(date +%s) - 3600) * 1000 + b * 100000000 )); fi
  for ((d=1; d<=devs; d++)); do
    vals=""
    for ((k=0;k<rows;k++)); do
      vals="$vals($(( start + k * 10 )),$((k+b))),"
      if [ $(( (k+1) % bs )) -eq 0 ]; then stmts+=("insert into $db.d$d(time,s1) values ${vals%,};"); vals=""; fi
    done
    [ -n "$vals" ] && stmts+=("insert into $db.d$d(time,s1) values ${vals%,};")
  done
  stmts+=("flush;")
  sql_lines_tree "${stmts[@]}" >/dev/null
  # 校验写入（用一次 count 查询，避免"写了但没进去"）
  local want=$(( devs * rows )) got
  got=$(row_sum "$(sq "select count(s1) from $db.d1.**;")")
  echo "$got"; }
# 子集节点上的 sync lag 检查（REMOVE DATANODE 之后集群只剩 2 个 DN）
check_sync_lag_on(){ local nodes_str=$1 h line n bad v
  local nodes=(); read -ra nodes <<<"$nodes_str"
  local deadline=$(( $(date +%s) + SYNC_TIMEOUT_SEC )) stable=0
  while (( $(date +%s) < deadline )); do
    n=0; bad=0
    for h in "${nodes[@]}"; do
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        v=${line##* }; n=$((n+1))
        awk -v x="$v" 'BEGIN{exit !(x+0>0.0001)}' && bad=$((bad+1))
      done < <(curl -s -m 8 "http://$h:$DN_METRIC_PORT/metrics" 2>/dev/null | grep 'type="syncLag"')
    done
    log "  syncLag(子集) series=$n nonzero=$bad"
    if [ "${n:-0}" -gt 0 ] && [ "${bad:-1}" -eq 0 ]; then stable=$((stable+1)); else stable=0; fi
    [ "$stable" -ge "$SYNC_STABLE_CHECKS" ] && { pass "sync lag 已归零（子集节点，series=$n）"; return 0; }
    sleep 10
  done
  fail "子集节点 sync lag 未在 ${SYNC_TIMEOUT_SEC}s 内归零 (series=$n nonzero=$bad)"; return 1; }
# 指定节点子集的 CN/DN 日志异常扫描（REMOVE 场景用：被移除节点自身的日志噪声不计入）
cmp_check_logs_on(){ local nodes_str=$1 role h files n
  local nodes=(); read -ra nodes <<<"$nodes_str"
  log "=== CN/DN 异常日志分析（子集：$nodes_str）==="
  for role in confignode datanode; do
    for h in "${nodes[@]}"; do
      files=$(sshx "$h" "ls $DB_DIR/logs/*${role}*all*.log $DB_DIR/logs/*${role}*error*.log 2>/dev/null" 2>/dev/null | tr '\n' ' ')
      [ -z "$files" ] && { warn "$role $h 无日志文件"; continue; }
      n=$(sshx "$h" "grep -hE '$COMMON_ERR_PAT|$CMP_ERR_PAT' $files 2>/dev/null | grep -vcE '$BENIGN_PAT'" 2>/dev/null | tr -dc '0-9')
      if [ "${n:-0}" -gt 0 ]; then
        fail "$role $h 日志出现 $n 条异常"
        sshx "$h" "grep -nE '$COMMON_ERR_PAT|$CMP_ERR_PAT' $files 2>/dev/null | grep -vE '$BENIGN_PAT' | head -10 | cut -c1-240" >>"$OUT" 2>&1
      else
        pass "$role $h 日志无异常"
      fi
    done
  done; }
# 性能基准记录
# 用法：cmp_perf_record <case> <points> <in_files> <in_bytes> <out_files> <out_bytes> <seconds>
cmp_perf_record(){ local case=$1 pts=$2 inf=$3 inb=$4 outf=$5 outb=$6 secs=$7 csv="$OUTDIR/perf_baseline.csv" prev ratio
  [ -f "$csv" ] || echo 'Time,build,consensus,case,points,in_files,in_bytes,out_files,out_bytes,merge_seconds,points_per_sec,write_amp' >>"$csv"
  prev=$(grep -F ",$case," "$csv" 2>/dev/null | grep -F ",$BUILD_TAG," | tail -1 | awk -F, '{print $10}')
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date --iso-8601=seconds)" "$BUILD_TAG" "${CONSENSUS_CLASS##*.}" "$case" \
    "$pts" "$inf" "$inb" "$outf" "$outb" "$secs" \
    "$(awk -v p="$pts" -v s="$secs" 'BEGIN{printf "%.1f", (s>0? p/s : 0)}')" \
    "$(awk -v a="$inb" -v b="$outb" 'BEGIN{printf "%.2f", (a>0? b/a : 0)}')" >>"$csv"
  log "  性能已记录到 $csv：points=$pts in=${inb}B($inf 文件) out=${outb}B($outf 文件) 合并耗时=${secs}s"
  if [ -n "${prev:-}" ]; then
    ratio=$(awk -v a="$secs" -v b="$prev" 'BEGIN{printf "%.2f", (b>0? a/b : 0)}')
    log "  与同构建历史基线（${prev}s）比：本次 ${secs}s，比值 $ratio"
    awk -v r="$ratio" -v lim="$CO_PERF_WARN_RATIO" 'BEGIN{exit !(r+0 > lim+0)}' && warn "合并耗时是历史基线的 ${ratio} 倍（阈值 ${CO_PERF_WARN_RATIO}）"
  fi; }

# ---------------------------------------------------------------------------
# 基础场景构件（CO-18 起共用；CO-17 内有一份等价的局部实现，为保持"已验证脚本不动"未合并）
#   设计要点（CO-17 的血泪教训，见 SKILL.md §4）：
#     ① 单设备 ⇒ 每个副本只落 1 个 data region，文件数可控；
#     ② 批次时间戳严格递增 ⇒ 落 sequence/；要 unseq 就写"在 seq 水位区间内且更早"的批次；
#     ③ 每批写完必须等各副本 **close 事件**达标再写下一批（`flush;` 返回后 TsFile 仍可追加）；
#     ④ 判据一律用"各副本布局是否一致"（`cmp_lay_uni`）而不是聚合计数。
# ---------------------------------------------------------------------------
# 各副本 TsFile 层级计数（L0..L3），形如 "77:1/0/0/0 78:1/0/0/0 79:1/0/0/0 "
cmp_lay(){ local h spec=""
  for h in "${DN[@]}"; do
    spec="$spec${h##*.}:$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$1/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | awk -F- '{c[\$3]++} END{printf \"%d/%d/%d/%d\", c[0]+0, c[1]+0, c[2]+0, c[3]+0}'" 2>/dev/null) "
  done; printf '%s' "$spec"; }
# 各副本布局去重串（一致时只有一个值，形如 "1/0/0/0 "）
cmp_lay_uni(){ printf '%s\n' "$1" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' '; }

# ---------------------------------------------------------------------------
# 判据集（judge set）口径 —— **V1 = 全部副本 / V2 = region leader**
#   依据（2026-10-17 定性，逐条证据见 _scratch/RC8_V2_DIVERGENCE_TRIAGE.md §② 与 §3.4/§3.5/§3.6/§3.8）：
#     · V2 的 follower **不 flush 自己的 memtable**：共识管道收到的 TsFile 一律按 LOAD 路径落
#       **unsequence**（DataRegion.java:4984 `setSeq(false)` / :5009 `loadTsFileToUnSequence`），
#       只有 region leader 会 flush 自己的 memtable ⇒ **只有 leader 持有 sequence 文件**。
#     · 因此"三副本同布局 / 各副本文件数相等 / 三副本都出 L1..L3"在 V2 下**结构性不成立**
#       （设计差异，非产品缺陷）；CO-15/CO-39/CO-41/CO-38/DT-08 的旧判据全部栽在这一点上。
#     · 判据集按副本角色**动态**确定（不依赖固定 IP、不会为空）：
#         V1 → 全部副本（与改动前的口径**完全一致，一处不放松**）；
#         V2 → 本相 leader：① 优先"该库有 `Async close tsfile` 事件"的副本（= flush 过自己的 memtable），
#              ② 退到"持有该库 sequence 文件"的副本，③ 都还没有（刚建库/刚写入未落盘）⇒ 退回全部副本。
#     · 非判据副本（follower）的差异**只 WARN + 打印逐副本布局**作证据，不判 FAIL；
#       **硬判据一处不放松**：判据集侧的 finishes 增量、数据指纹/行数、收尾三件套（sync lag /
#       副本一致性 / 日志扫描）仍按原口径判定。
# ---------------------------------------------------------------------------
cmp_is_v2(){ case "${DATA_CONSENSUS:-}${CONSENSUS_CLASS:-}" in *IoTConsensusV2*) echo 1 ;; *) echo 0 ;; esac; }
# 单副本的 TsFile 层级计数（L0/L1/L2/L3），形如 "1/1/0/0"
cmp_lay_of(){ sshx "$1" "find $DB_DIR/data/datanode/data -path '*/$2/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | awk -F- '{c[\$3]++} END{printf \"%d/%d/%d/%d\", c[0]+0, c[1]+0, c[2]+0, c[3]+0}'" 2>/dev/null; }
# 判据集节点（空格分隔）
cmp_judge_nodes(){ local db=$1 h out=""
  [ "$(cmp_is_v2)" = 0 ] && { printf '%s' "${DN[*]}"; return; }
  for h in "${DN[@]}"; do [ "$(ttl_close_cnt "$h" "$db")" -gt 0 ] && out="$out $h"; done
  if [ -z "$out" ]; then for h in "${DN[@]}"; do [ "$(cmp_seq_cnt "$h" "$db")" -gt 0 ] && out="$out $h"; done; fi
  [ -z "$out" ] && out=" ${DN[*]}"
  printf '%s' "${out# }"; }
# 探一次判据集布局（结果放全局，避免一个判据里重复 ssh）：
#   CMPJ_JUDGE 判据集节点；CMPJ_JUDGE_SPEC 判据集逐副本布局；CMPJ_JUDGE_UNI 判据集去重布局
#   CMPJ_OTHER_SPEC / CMPJ_OTHER_UNI 非判据副本（V2 follower）的布局，仅作证据
CMPJ_JUDGE=""; CMPJ_JUDGE_SPEC=""; CMPJ_JUDGE_UNI=""; CMPJ_OTHER_SPEC=""; CMPJ_OTHER_UNI=""
cmp_lay_probe(){ local db=$1 h lay judge
  judge=$(cmp_judge_nodes "$db")
  CMPJ_JUDGE="$judge"; CMPJ_JUDGE_SPEC=""; CMPJ_OTHER_SPEC=""
  for h in $judge; do lay=$(cmp_lay_of "$h" "$db"); CMPJ_JUDGE_SPEC="$CMPJ_JUDGE_SPEC${h##*.}:$lay "; done
  for h in "${DN[@]}"; do case " $judge " in *" $h "*) continue ;; esac
    CMPJ_OTHER_SPEC="$CMPJ_OTHER_SPEC${h##*.}:$(cmp_lay_of "$h" "$db") "; done
  CMPJ_JUDGE_UNI=$(printf '%s\n' "$CMPJ_JUDGE_SPEC" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' ')
  CMPJ_OTHER_UNI=$(printf '%s\n' "$CMPJ_OTHER_SPEC" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' '); }
# 判据：判据集布局是否全 == want（用返回码；同时刷新 CMPJ_* 证据变量）
cmp_lay_ok(){ local db=$1 want=$2; cmp_lay_probe "$db"; [ "$CMPJ_JUDGE_UNI" = "$want " ]; }
# 是否**至少一台**副本的布局 == want（V2 的"场景是否存在"类前置用；V1 下等价于全部副本都达到）
cmp_any_lay(){ local db=$1 want=$2 h; for h in "${DN[@]}"; do [ "$(cmp_lay_of "$h" "$db")" = "$want" ] && return 0; done; return 1; }
# follower 证据：非判据副本布局与 want 不同 ⇒ 只 WARN + 打印逐副本布局（V2 设计差异，不判 FAIL）
cmp_warn_followers(){ local tag=$1 want=$2
  [ -n "${CMPJ_OTHER_SPEC:-}" ] || return 0
  [ "${CMPJ_OTHER_UNI:-}" = "$want " ] && return 0
  warn "  $tag：非判据副本布局 ${CMPJ_OTHER_SPEC% } 与判据集（${CMPJ_JUDGE_SPEC:-未探测}）不同 —— V2 follower 的 TsFile 落 unsequence（DataRegion.java:4984/5009，设计差异、非缺陷），判据只看 leader"
  return 0; }
# 统一布局判据入口：cmp_check_lay <tag> <db> <want>
#   判据集达标 ⇒ PASS（并对 follower 差异 WARN）；不达标 ⇒ FAIL 并附**逐副本**布局。返回 0/1。
cmp_check_lay(){ local tag=$1 db=$2 want=$3
  if cmp_lay_ok "$db" "$want"; then
    pass "  $tag（判据集 ${CMPJ_JUDGE_SPEC% } = $want）"
    cmp_warn_followers "$tag" "$want"
    return 0
  fi
  fail "  $tag 未成立：判据集 ${CMPJ_JUDGE_SPEC:-（空）} 未达 $want（各副本 $(cmp_lay "$db")）"
  return 1; }
# 场景有效性类布局前置：判据集达标 ⇒ PASS；仅"至少一台"达标 ⇒ PASS + WARN（V2 follower 差异是常态）；
# 一台都不达标 ⇒ FAIL（**不放松**：场景必须真的存在于某个副本上）。返回 0=场景成立 / 1=不成立。
cmp_scene_lay(){ local tag=$1 db=$2 want=$3
  if cmp_lay_ok "$db" "$want"; then
    pass "  $tag（判据集 ${CMPJ_JUDGE_SPEC% } = $want）"
    cmp_warn_followers "$tag" "$want"
    return 0
  fi
  if cmp_any_lay "$db" "$want"; then
    warn "  $tag：判据集 ${CMPJ_JUDGE_SPEC:-（空）} 未达 $want，但**至少一台**副本达到（各副本 $(cmp_lay "$db")）⇒ 场景成立（V1=全部副本 / V2=leader 口径；V2 follower 不 flush memtable、文件落 unsequence，属设计差异）"
    return 0
  fi
  fail "  $tag 未成立：判据集 ${CMPJ_JUDGE_SPEC:-（空）} 与全部副本都未达到 $want（各副本 $(cmp_lay "$db")）"
  return 1; }
# 判据集上的 level-0 文件数统计（cmp_scene_lay 的数值版本，CO-38 之类的"L0 是否够数"前置用）
cmp_judge_l0_stat(){ local db=$1 how=$2 h out="" n
  for h in $(cmp_judge_nodes "$db"); do n=$(cmp_lay_of "$h" "$db"); n=${n%%/*}; out="$out ${n:-0}"; done
  out=$(printf '%s\n' $out | sed '/^$/d' | sort -n)
  [ -z "$out" ] && { echo 0; return; }
  if [ "$how" = max ]; then printf '%s\n' "$out" | tail -1; else printf '%s\n' "$out" | head -1; fi; }
# 判据集的 seq/unseq 计数去重串（等待用，形如 "1/2 "）
cmp_su_judge_uni(){ local db=$1 h spec=""
  for h in $(cmp_judge_nodes "$db"); do spec="$spec${h##*.}:$(cmp_seq_cnt "$h" "$db")/$(cmp_unseq_cnt "$h" "$db") "; done
  printf '%s\n' "$spec" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' '; }
# 各副本 seq/unseq 文件数，形如 "77:1/3 78:1/3 "
cmp_su(){ local h spec=""
  for h in "${DN[@]}"; do spec="$spec${h##*.}:$(cmp_seq_cnt "$h" "$1")/$(cmp_unseq_cnt "$h" "$1") "; done
  printf '%s' "$spec"; }
# ---------------------------------------------------------------------------
# 等待窗口口径（协议感知）—— 判据集见上（V1=全部副本 / V2=leader）
#   P2 依据（CO-39 实测）：V2 下 follower 整轮不 `Async close`、也不 flush 自己的 memtable
#   ⇒ 旧的"三副本全部达标才放行"会每次都白等满窗口（23 次 × ~106s ≈ +2400s，748s → 3458s）。
#   · 放行条件①（严格）：**判据集**每台都达标（V1 下等价于"全部副本都达标"，与旧口径一致）；
#   · 放行条件②（quorum，**仅 V2**）：已有 ≥ CMP_CLOSE_QUORUM 台判据集副本达标，
#     且已等 ≥ CMP_CLOSE_MIN_WAIT_SEC 秒（这两个变量在 conf/env.conf 里已有说明，V1 不启用）；
#   · close 等待窗口上限 CMP_WAIT_CLOSE_WIN（默认 30s；callers 传更大的值也会被压到该上限）。
#     一个副本都没达标 ⇒ 仍等满窗口并 WARN"场景未成立"（不静默放过）。
# ---------------------------------------------------------------------------
CMP_WAIT_CLOSE_WIN=${CMP_WAIT_CLOSE_WIN:-30}
CMP_CLOSE_QUORUM=${CMP_CLOSE_QUORUM:-1}
CMP_CLOSE_MIN_WAIT_SEC=${CMP_CLOSE_MIN_WAIT_SEC:-10}
# 等判据集副本"该库 close 事件数" >= min；0=达成 1=超时。回显 "循环次数|strict|quorum|timeout|<逐副本实测>"
cmp_wait_close(){ local db=$1 min=$2 t=${3:-$CMP_WAIT_CLOSE_WIN} dl h n ok got spec judge t0 i=0
  t=${t:-$CMP_WAIT_CLOSE_WIN}; [ "$t" -gt "$CMP_WAIT_CLOSE_WIN" ] && t=$CMP_WAIT_CLOSE_WIN
  t0=$(date +%s); dl=$(( t0 + t ))
  while (( $(date +%s) < dl )); do
    i=$(( i + 1 )); ok=1; got=0; spec=""; judge=$(cmp_judge_nodes "$db")
    for h in $judge; do n=$(ttl_close_cnt "$h" "$db"); n=${n:-0}; spec="$spec${h##*.}:$n "
      if [ "$n" -ge "$min" ]; then got=$(( got + 1 )); else ok=0; fi; done
    [ "$ok" = 1 ] && { echo "$i|strict|$spec"; return 0; }
    if [ "$(cmp_is_v2)" = 1 ] && [ "$got" -ge "$CMP_CLOSE_QUORUM" ] && [ $(( $(date +%s) - t0 )) -ge "$CMP_CLOSE_MIN_WAIT_SEC" ]; then
      echo "$i|quorum|$spec"; return 0
    fi
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done
  echo "$i|timeout|$spec"; return 1; }
# 等**判据集**的层级布局统一 == want（如 1/1/0/0）；0=达成 1=超时（回显循环次数）
cmp_wait_lay(){ local db=$1 want=$2 t=${3:-150} dl i=0
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    i=$(( i + 1 ))
    cmp_lay_ok "$db" "$want" && { echo "$i"; return 0; }
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done
  echo "$i"; return 1; }
# 等**至少一台**副本的布局 == want（V2 的"场景是否存在"类前置；CO-39 段 1 用）
cmp_wait_any_lay(){ local db=$1 want=$2 t=${3:-150} dl i=0
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    i=$(( i + 1 ))
    cmp_any_lay "$db" "$want" && { echo "$i"; return 0; }
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done
  echo "$i"; return 1; }
# 等**判据集**的 seq/unseq 计数统一 == want（如 1/3）；0=达成 1=超时
cmp_wait_su(){ local db=$1 want=$2 t=${3:-150} dl i=0
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    i=$(( i + 1 ))
    [ "$(cmp_su_judge_uni "$db")" = "$want " ] && { echo "$i"; return 0; }
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done
  echo "$i"; return 1; }
# 建库 + 单设备 d1 的 INT64 序列（单 region 场景）
cmp_mkdb1(){ local db=$1
  sq "create database $db;" >/dev/null
  sq "create timeseries $db.d1.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null; }
# 写一批（单设备 d1；rows 行；时间戳 base+k*10 递增）+ 等 close + 等布局达到 want
cmp_batch1(){ local db=$1 b=$2 base=$3 want=$4 rows=${5:-200} k vals=""
  for ((k=1;k<=rows;k++)); do vals="$vals($(( base + k*10 )),$((k+b))),"; done
  sq "insert into $db.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  cmp_wait_close "$db" "$b" 90 >/dev/null || warn "    批$b：close 事件未达 $b（$(ttl_close_snapshot "$db")）"
  if cmp_wait_lay "$db" "$want" 120 >/dev/null; then log "    批$b 就绪：布局=$(cmp_lay "$db")"
  else warn "    批$b 未达预期布局 $want（实际 $(cmp_lay "$db")）"; fi
  sleep 3; }
# inner/cross 任务的"单任务文件数"分布（inner 用 `N files`，cross 见 cmp_cross_unseq_nums）
cmp_task_nums(){ local db=$1 kind=$2 h pat
  case "$kind" in
    cross) pat='[Compaction] CrossSpaceCompaction task starts with' ;;
    *)     pat='InnerSpaceCompaction task starts with' ;;
  esac
  for h in "${DN[@]}"; do
    sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -E '(^|[- ])(root\.)?$db-[0-9]+' | sed -E 's/.*starts with ([0-9]+) files.*/\1/'" 2>/dev/null
  done | grep -E '^[0-9]+$' | sort -n | uniq -c | awk '{printf "%s×%s ", $2, $1}'; echo; }
# cross 任务"每任务 unseq 数"分布（日志格式：`[Compaction] CrossSpaceCompaction task starts with N seq files and M unsequence files`）
cmp_cross_unseq_nums(){ local db=$1 h
  for h in "${DN[@]}"; do
    sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '[Compaction] CrossSpaceCompaction task starts with' | grep -E '(^|[- ])(root\.)?$db-[0-9]+' | sed -E 's/.*and ([0-9]+) unsequence files.*/\1/'" 2>/dev/null
  done | grep -E '^[0-9]+$' | sort -n | uniq -c | awk '{printf "%s×%s ", $2, $1}'; echo; }
cmp_task_cnt(){ local db=$1 kind=$2 h pat n s=0
  case "$kind" in
    cross) pat='[Compaction] CrossSpaceCompaction task starts with' ;;
    *)     pat='InnerSpaceCompaction task starts with' ;;
  esac
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done; echo "${s:-0}"; }
cmp_task_max(){ printf '%s\n' "$1" | awk '{for(i=1;i<=NF;i++){split($i,a,"×"); if(a[1]+0>m) m=a[1]+0}} END{print m+0}'; }
# 某库的删除标记文件数
#   ⚠️ 2.0.12.1 默认后缀是 **`.mods2`**（`ModificationFile.java:64` `FILE_SUFFIX = ".mods2"`），
#      `.mods` 是旧版 v1 的（`ModificationFileV1.java:56`）。只按 `*.mods` 数会**恒为 0**（RC8 实测踩到）。
#      合并过程中的临时文件 `*.compaction.mods2`（`ModificationFile.java:65`）不算"真删除标记"，排除掉。
cmp_mods_cnt(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' \( -name '*.mods' -o -name '*.mods2' \) ! -name '*.compaction.mods2' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
cmp_mods_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(cmp_mods_cnt "$h" "$1") )); done; echo "$s"; }
# 该库的 TsFile 名列表（判"文件是否被重写/改名"）
cmp_names(){ local h; for h in "${DN[@]}"; do sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$1/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | sort" 2>/dev/null; done | sort | tr '\n' ' '; echo; }
# 残留临时文件（合并中断/恢复后不应留下 *.compaction.log / *.tmp）
cmp_tmp_leftover(){ local h n s=0
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$1/*' \( -name '*.compaction.log' -o -name '*.tmp' -o -name '*.merge' \) 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} )); done; echo "$s"; }

# ---------------------------------------------------------------------------
# 修改数据类型（DT-xx 用例共用）
# ---------------------------------------------------------------------------
# 树模型某序列当前的数据类型（按 `show timeseries` 表头定位 DataType 列，避免列序变化导致误判）
# 用法：cmp_series_type <path> [node]   不给 node 就用 CLI 默认节点
cmp_series_type(){ local p=$1 node=${2:-} out idx
  if [ -n "$node" ]; then out=$(sq_node "$node" "show timeseries $p;" 2>/dev/null); else out=$(sq "show timeseries $p;" 2>/dev/null); fi
  idx=$(printf '%s\n' "$out" | awk -F'|' '/Timeseries/{for(i=1;i<=NF;i++){gsub(/ /,"",$i); if($i=="DataType"){print i; exit}}}')
  [ -z "${idx:-}" ] && { echo "?"; return; }
  printf '%s\n' "$out" | awk -F'|' -v i="$idx" -v p="$p" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); if($2==p){v=$i; gsub(/[ \t]/,"",v); print v; exit}}'; }
# 某序列在**所有副本**上的类型是否都等于期望值（1=一致/0=不一致；不一致时打印差异）
cmp_type_same_all(){ local p=$1 want=$2 h v ok=1
  for h in "${DN[@]}"; do v=$(cmp_series_type "$p" "$h"); [ "$v" = "$want" ] || { ok=0; log "      副本 $h 类型=$v（期望 $want）"; }; done
  echo "$ok"; }
# 单序列数据指纹（任意类型可用；混合类型库不能用 cmp_fp_tree —— sum 会 701）
# ⚠️ 树方言的 FROM 要写**设备路径**：`select s1 from root.db.dev` ✅；写成序列路径 `root.db.dev.s1` 会返回 Empty set
cmp_fp_series(){ local p=$1 dev meas; dev="${p%.*}"; meas="${p##*.}"
  cmp_fingerprint tree "select $meas from $dev order by time;"; }
# 单序列前 N 行的值（`|` 分隔），便于人工核对类型转换（同样用设备路径）
cmp_vals_series(){ local p=$1 n=${2:-5} dev meas; dev="${p%.*}"; meas="${p##*.}"
  sq "select $meas from $dev order by time limit $n;" 2>&1 | grep -E '^\|' | tail -n +2 \
    | awk -F'|' '{v=$3; gsub(/^[ \t]+|[ \t]+$/,"",v); printf "%s|", v}'; echo; }
# 设备路径下的行数（树方言）
cmp_rows_series(){ local p=$1 dev meas; dev="${p%.*}"; meas="${p##*.}"
  sq "select $meas from $dev order by time;" 2>&1 | data_rows | wc -l | tr -dc '0-9'; }
# ---- 表模型结果集：**按列名**取值/数行 -------------------------------------
# 坑（本轮实测）：表模型 `SELECT` **只返回投影列**（不像树模型那样自动带 Time 列），
# `select v from t order by time` 的结果每行只有 1 列（`|11|`），所以**不能**硬编码列序号
# （曾把 c 写成 3 ⇒ 取到空串，断言"值可读"变成空判据）。这里统一按**表头**定位列号。
cmp_tbl_col_vals(){ local sql=$1 col=$2 node=${3:-} out idx
  if [ -n "$node" ]; then out=$(sqt_node "$node" "$sql" 2>&1); else out=$(sqt "$sql" 2>&1); fi
  idx=$(printf '%s\n' "$out" | grep -E '^\|' | head -1 | awk -F'|' -v c="$col" '{for(i=2;i<NF;i++){v=$i; gsub(/^[ \t]+|[ \t]+$/,"",v); if(v==c){print i; exit}}}')
  if [ -z "$idx" ]; then echo "NOCOL:$col"; return; fi
  printf '%s\n' "$out" | table_rows | sed -E 's/[[:space:]]+/ /g' \
    | awk -F'|' -v i="$idx" '{v=$i; gsub(/^[ \t]+|[ \t]+$/,"",v); printf "%s|", v}'; echo; }
# 表模型结果集的**数据行**数（table_rows 已剔除表头与分隔线）
cmp_tbl_rows(){ local sql=$1 node=${2:-} out
  if [ -n "$node" ]; then out=$(sqt_node "$node" "$sql" 2>&1); else out=$(sqt "$sql" 2>&1); fi
  printf '%s\n' "$out" | table_rows | wc -l | tr -dc '0-9'; }
# 各副本 level-0 TsFile 数的**最小值**（cmp_lay 布局串第 1 段）；>=2 才说明"确有文件可合并"
cmp_min_l0(){ local db=$1 lay h n min=999
  lay=$(cmp_lay "$db")
  for h in "${DN[@]}"; do
    n=$(printf '%s\n' "$lay" | tr ' ' '\n' | grep -E "^${h##*.}:" | cut -d: -f2 | cut -d/ -f1)
    [ -n "$n" ] && [ "$n" -lt "$min" ] && min=$n
  done; echo "$min"; }
# 表模型某列的当前类型（`desc` 里 ColumnName→DataType）
cmp_tbl_coltype(){ local tbl=$1 col=$2
  sqt "desc $tbl;" 2>/dev/null | awk -F'|' -v c="$col" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3); if($2==c){print $3; exit}}'; }
# 一条 ALTER TIMESERIES 的响应（去掉表头/耗时行）
cmp_alter_ts(){ sq "alter timeseries $1 set data type $2;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -2 | tr '\n' ' '; }
# 一条表模型 ALTER COLUMN 的响应
cmp_alter_col(){ sqt "$1" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -2 | tr '\n' ' '; }

# ===== inlined lib: common.sh =====
# ============================================================================
# TTL 自动化测试 skill —— 公共库
#   source 本文件后即可使用：集群生命周期、SQL 会话、断言、TTL 证据采集、
#   sync lag / 副本一致性 / CN-DN 日志分析、结果记录。
# ============================================================================

TTL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TTL_SKILL_DIR="$(cd "$TTL_LIB_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# 环境加载
# ---------------------------------------------------------------------------
cmp_load_env(){
  local env_file="${1:-$TTL_SKILL_DIR/conf/env.conf}"
  [ -f "$env_file" ] && . "$env_file"
  DB_DIR="$DB_PARENT_DIR/$V_TESTDB"
  CN_DB_DIR="$CN_DB_PARENT_DIR/$V_TESTDB"
  CLI_DIR="$SHELL_CLIENT_DIR/$V_TESTDB"
  CLI="$CLI_DIR/sbin/start-cli.sh"
  read -ra CN <<<"$CN_NODES"
  read -ra DN <<<"$DN_NODES"
  QDN="${DN[0]}"
  CONSENSUS_CLASS="$(ttl_consensus_class "$DATA_CONSENSUS")"
  export DB_DIR CN_DB_DIR CLI_DIR CLI QDN CONSENSUS_CLASS
}

ttl_consensus_class(){
  case "$1" in
    *IoTConsensusV2) echo "org.apache.iotdb.consensus.iot.IoTConsensusV2" ;;
    *)               echo "org.apache.iotdb.consensus.iot.IoTConsensus" ;;
  esac
}

cmp_parse_args(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --consensus)   DATA_CONSENSUS="$2"; shift 2 ;;
      --framework)   USE_FRAMEWORK="$2";  shift 2 ;;
      --env)         TTL_ENV_FILE="$2";   shift 2 ;;
      --keep-data)   KEEP_DATA=1;         shift   ;;
      *) echo "未知参数: $1" >&2; shift ;;
    esac
  done
  [ -n "${TTL_ENV_FILE:-}" ] && . "$TTL_ENV_FILE"
  CONSENSUS_CLASS="$(ttl_consensus_class "$DATA_CONSENSUS")"
}

# ---------------------------------------------------------------------------
# 用例脚手架
# ---------------------------------------------------------------------------
cmp_case_init(){
  CASE="$1"
  RUN_ID="$(date +%Y%m%d_%H%M%S)"
  OUTDIR="$TTL_SKILL_DIR/results"
  OUT="$OUTDIR/${CASE}_${RUN_ID}.out"
  ART="$OUTDIR/artifact_${CASE}_${RUN_ID}"
  mkdir -p "$OUTDIR" "$ART" "$ART/logs"
  : >"$OUT"
  fail_flag=0
  v_warnMessage=""
  start_epoch=$(date +%s)
  log "=== $CASE 开始 run_id=$RUN_ID ==="
  log "环境: build=$BUILD_TAG consensus=$CONSENSUS_CLASS nodes=[${DN[*]}] db_dir=$DB_DIR framework=$USE_FRAMEWORK"
}

log(){  local m="[$(date '+%F %T')] $*"; printf '%s\n' "$m" >>"$OUT"; printf '%s\n' "$m"; }
note(){ v_warnMessage="${v_warnMessage}$*"; }
warn(){ note "$*"; log "WARN $*"; }
fail(){ fail_flag=$((fail_flag+1)); note "$*"; log "FAIL $*"; }
pass(){ log "PASS $*"; }

# ---------------------------------------------------------------------------
# 断言（都要求传入"已去掉 CLI 回显"的输出）
# ---------------------------------------------------------------------------
assert_contains(){     # 标签 输出 正则
  if printf '%s\n' "$2" | grep -qE "$3"; then pass "$1: 命中 /$3/"; else fail "$1: 未命中 /$3/"; printf '%s\n' "$2" | sed 's/^/    | /' >>"$OUT"; fi
}
assert_not_contains(){ # 标签 输出 正则
  if printf '%s\n' "$2" | grep -qE "$3"; then fail "$1: 不应出现 /$3/"; printf '%s\n' "$2" | grep -nE "$3" | head -5 >>"$OUT"; else pass "$1: 未出现 /$3/"; fi
}
assert_eq(){           # 标签 实际 期望
  if [ "$2" = "$3" ]; then pass "$1: = $3"; else fail "$1: 实际=[$2] 期望=[$3]"; fi
}
assert_error_code(){   # 标签 输出 错误码
  if printf '%s\n' "$2" | grep -qE "IoTDBSQLException: $3|${3}:|SQLSTATE *: *$3"; then pass "$1: 如期报 $3"; else fail "$1: 未见错误码 $3"; printf '%s\n' "$2" | sed 's/^/    | /' >>"$OUT"; fi
}

# ---------------------------------------------------------------------------
# ssh / SQL
# ---------------------------------------------------------------------------
sshx(){ local h=$1; shift; ssh -n $SSH_OPTS "$SSH_USER@$h" "$@"; }
# 去掉 CLI 提示回显（TimechoDB> / TimechoDB:db> / IoTDB> 等）与纯分隔行
strip_echo(){ grep -vE '^[[:alnum:]_:]*DB>([[:space:]]|$)' | grep -vE '^[-+]+$'; }
# 只保留数据行（以时间戳开头）——用于区分"结果里的数据行"与"表头/报错文本"
data_rows(){ grep -E '^\|[0-9]{4}-[0-9]{2}-[0-9]{2}T' ; }
# 去掉表头/分隔线后的所有结果行
table_rows(){ grep -E '^\|' | grep -vE '^\|[-+ ]+\|$' | tail -n +2 ; }

# 单条语句（-e，新会话）
sq(){        timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 -e "$1" 2>&1; }
sq_node(){   timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$1"   -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 -e "$2" 2>&1; }
sqt(){       timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 3600 -e "$1" 2>&1; }
sqt_node(){  timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$1"   -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 3600 -e "$2" 2>&1; }

# 同一个 CLI 会话里按顺序执行多条语句（从 stdin 读语句；保证会话/连接不变）
session_tree(){  timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 2>&1; }
session_table(){ timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 3600 2>&1; }
# 用法： out=$(sql_lines_tree "stmt1;" "stmt2;")   （内部用管道喂给同一个会话）
sql_lines_tree(){  printf '%s\n' "$@" | session_tree; }
sql_lines_table(){ printf '%s\n' "$@" | session_table; }

# 取 SHOW 语句里某行的值： value_of <输出> <行内匹配正则> <取第几个|列分隔>
rows_of(){ printf '%s\n' "$1" | table_rows | sed -E 's/[[:space:]]+/ /g'; }

now_ms(){ date +%s%3N; }

# ---------------------------------------------------------------------------
# 批量写入辅助（多值 INSERT，一条语句默认最多 500 行）
# ---------------------------------------------------------------------------
# 生成 "(ts,val),(ts,val),..." 形式的值列表
gen_values(){ local start=$1 step=$2 n=$3 i out=""
  for ((i=0;i<n;i++)); do out="$out($((start + i*step)),$((i+1))),"; done
  printf '%s' "${out%,}"
}
# 树模型批量写：bulk_tree <database> <device_prefix> <devices> <rows_per_device> <start_ts> <step_ms>
# 返回写入的总点数（每行一个值、值=行号）
bulk_tree(){
  local db=$1 pfx=$2 devs=$3 rows=$4 start=$5 step=$6 d i batch=${7:-500}
  local total=0
  for ((d=1; d<=devs; d++)); do
    local dev="$pfx$d" left=$rows off=0
    while (( left > 0 )); do
      local n=$(( left < batch ? left : batch ))
      local vals; vals=$(gen_values $((start + off*step)) "$step" "$n")
      sq "insert into $db.$dev(time,s1) values $vals;" >/dev/null || return 1
      total=$(( total + n )); left=$(( left - n )); off=$(( off + n ))
    done
  done
  echo "$total"
}
# 表模型批量写：bulk_table <database> <table> <devices> <rows_per_device> <start_ts> <step_ms>
bulk_table(){
  local db=$1 tb=$2 devs=$3 rows=$4 start=$5 step=$6 d i batch=${7:-500}
  local total=0
  for ((d=1; d<=devs; d++)); do
    local dev="d$d" left=$rows off=0
    while (( left > 0 )); do
      local n=$(( left < batch ? left : batch )); local vals="" k
      for ((k=0;k<n;k++)); do vals="$vals($((start + (off+k)*step)),'$dev',$((k+1))),"; done
      vals="${vals%,}"
      sql_lines_table "use $db;" "insert into $tb (time, dev, v) values $vals;" >/dev/null || return 1
      total=$(( total + n )); left=$(( left - n )); off=$(( off + n ))
    done
  done
  echo "$total"
}

# --- 结构化取值（按 | 分列，自动去空白） ---
# 从 SHOW ALL TTL / SHOW TTL ON 结果取规则 TTL：rule_ttl <输出> <路径>
rule_ttl(){ printf '%s\n' "$1" | awk -F'|' -v p="$2" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); if ($2==p){v=$(NF-1); gsub(/[ \t]/,"",v); print v; exit}}'; }
# 从 SHOW DEVICES 结果取设备 TTL
device_ttl(){ printf '%s\n' "$1" | awk -F'|' -v p="$2" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); if ($2==p){v=$(NF-1); gsub(/[ \t]/,"",v); print v; exit}}'; }
# 从 SHOW TABLES 结果取表 TTL
table_ttl(){ printf '%s\n' "$1" | awk -F'|' -v p="$2" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); if ($2==p){v=$(NF-1); gsub(/[ \t]/,"",v); print v; exit}}'; }
# 从 information_schema 结果按整行正则取第 N 个数据列（col 从 1 开始）
row_col(){ printf '%s\n' "$1" | grep -E "$2" | awk -F'|' -v c="$3" '{v=$(c+1); gsub(/^[ \t]+|[ \t]+$/,"",v); print v; exit}'; }
# 结果行数
n_rows(){ printf '%s\n' "$1" | table_rows | wc -l | tr -d ' '; }
# 第一行数据行所有数值列之和（用于 count(*) 通配返回多列的场景）
row_sum(){ printf '%s\n' "$1" | table_rows | head -1 | awk -F'|' '{s=0; for(i=2;i<NF;i++){v=$i; gsub(/[^0-9-]/,"",v); if(v!="")s+=v} print s}'; }
# TTL 检查日志的"行数"（单调递增，适合做基线比较）；以及 Settle 删除全过期文件的行数
ttl_log_line_cnt(){ sshx "$1" "grep -hcE '\[TTL\].*Totally select' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
settle_line_cnt(){ sshx "$1" "grep -hc 'Settle task deletes fully_dirty tsfile' $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
# 选中了"非 0 个全过期文件"的 TTL 日志行数（单调递增，证明 TTL 任务确实挑中了过期文件）
ttl_selected_positive_cnt(){ sshx "$1" "grep -hcE '\[TTL\].*Totally select [1-9][0-9]* all-outdated' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
# 对所有 DN 求和
sum_over(){ local f=$1 s=0 h; for h in "${DN[@]}"; do s=$((s + $($f "$h"))); done; echo "${s:-0}"; }
# 按库对某统计函数求和： sum_over_db <helper> <db>
sum_over_db(){ local f=$1 db=$2 h s=0; for h in "${DN[@]}"; do s=$((s + $($f "$h" "$db"))); done; echo "${s:-0}"; }
# 等某库"真实 settle 任务"数增长 ≥ want；回显 "base cur"，返回 0=已增长 / 1=超时
# 注意：deadline 必须另起一句赋值（同 wait_ttl_closed，见 selftest 的静态检查）。
wait_settle_inc(){ local db=$1 want=${2:-1} timeout=${3:-$CLEANUP_WAIT_SEC} base cur
  local deadline=$(( $(date +%s) + timeout ))
  base=$(sum_over_db settle_task_for_db "$db")
  while (( $(date +%s) < deadline )); do
    cur=$(sum_over_db settle_task_for_db "$db")
    [ $(( cur - base )) -ge "$want" ] && { echo "$base $cur"; return 0; }
    sleep 5
  done
  echo "$base $cur"; return 1
}
# 某库 TsFile 名字里的最大"代"（...-1-<gen>-0.tsfile 的第 3 段）：用于观察是否被反复重写
tsfile_gen_max(){ local db=$1 h v m=0; for h in "${DN[@]}"; do
    v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*${db#root.}*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | grep -oE -- '-[0-9]+-[0-9]+-[0-9]+\\.tsfile\$' | cut -d- -f3 | sort -n | tail -1" 2>/dev/null | tr -dc '0-9')
    [ -n "${v:-}" ] && [ "$v" -gt "$m" ] && m=$v
  done; echo "$m"; }
# 按库统计（[TTL] 日志行里带 "<db>-<region>" 标识，用它把统计限定到本用例的库）
# 表模型库在 DataRegion 日志里可能带 root. 前缀（内部路径），所以统一允许可选前缀。
ttl_check_line_for_db(){ sshx "$1" "grep -hcE '\[TTL\] (root\.)?$2-[0-9]+ Start ttl and modification checking' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
ttl_sel_for_db(){ sshx "$1" "grep -hcE '\[TTL\] (root\.)?$2-[0-9]+ Totally select ([1-9][0-9]* all-outdated|[0-9]+ all-outdated files and [1-9][0-9]* partial-outdated)' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
ttl_last_line_for_db(){ sshx "$1" "grep -hE '\[TTL\] (root\.)?$2-[0-9]+' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -2" 2>/dev/null; }
# 真的起了 settle 合并任务的行数（注意：`Totally select N partial-outdated` 只是"候选"，还要过 expired_data_ratio 门槛才会变成任务）
settle_task_for_db(){ sshx "$1" "grep -hcE '(^|[- ])(root\.)?$2-[0-9]+ \[Compaction\] SettleCompaction task starts with' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
# 该库被 Async close（真正落盘）的 TsFile 条数：**未关闭的 TsFile 不参与 settle 选择**，
# 所以"某副本没 settle"经常只是它还没落盘，而不是阈值没生效——判定前必须先看这个。
ttl_close_cnt(){ sshx "$1" "grep -hcE 'Async close tsfile: .*$2' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
# 反复 flush 直到各 DN 都出现新的 close 事件（`flush;` 不保证在每台机器上及时关闭 memtable，
# 实测曾出现"某副本 5 分钟后才关闭"的情况）。返回 0=全部落盘 / 1=仍有副本未落盘。
ensure_closed(){ local db=$1 att=${2:-3} w=${3:-25} i snap
  for i in $(seq 1 "$att"); do
    snap=$(ttl_close_snapshot "$db")
    sq "flush;" >/dev/null
    if wait_ttl_closed "$db" "$snap" "$w"; then return 0; fi
    log "  第 $i 次 flush 后仍有 DN 未落盘：$(ttl_close_snapshot "$db")"
  done
  return 1
}
# "全过期文件"被选中的真实任务数（authoritative 信号；RC4 的 compaction 日志里
# **没有** `Settle task deletes fully_dirty tsfile` 这行，只有 SettleCompactionTask 的 starts with/finishes）
settle_fully_dirty_cnt(){ sshx "$1" "grep -hcE '(^|[- ])(root\.)?$2-[0-9]+ \[Compaction\] SettleCompaction task starts with [1-9][0-9]* fully_dirty files' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
# 该库出现过"整文件全过期"候选（`Totally select N all-outdated`，N>0）的行数：
# 用来识别"设备独占 TsFile ⇒ deletedDeviceRatio=1"导致的场景退化（此时比例门控根本没参与判定）
ttl_all_outdated_sel_cnt(){ sshx "$1" "grep -hcE '\[TTL\] (root\.)?$2-[0-9]+ Totally select [1-9][0-9]* all-outdated' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
# 该库出现过"部分过期"候选（`... and N partial-outdated`, N>0）的行数：
# **判断比例门控是否生效应该只看这个**——整文件全过期被清是合法的（与 ratio 无关），会污染"有没有被清理"的结论
ttl_partial_sel_cnt(){ sshx "$1" "grep -hcE '\[TTL\] (root\.)?$2-[0-9]+ Totally select [0-9]+ all-outdated files and [1-9][0-9]* partial-outdated' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
# 该库发生过的"含部分过期文件"的真实 settle 任务数（`SettleCompaction task starts with ... and [1-9]+ partially_dirty files`）：
# 判断"比例门控是否拦住了部分过期文件"要看这个计数，而不是 settle 总数——
# 整文件全过期（deletedDeviceRatio=1）走 FULLY_DIRTY，**合法地绕过** ratio，会污染"有没有被清理"的结论
settle_partial_task_for_db(){ sshx "$1" "grep -hcE '(^|[- ])(root\.)?$2-[0-9]+ \[Compaction\] SettleCompaction task starts with .* and [1-9][0-9]* partially_dirty files' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
# ---------------------------------------------------------------------------
# TDB-610 相关：同一个 DataRegion 被注册两次 ⇒ 该 region 每个 ttl_check_interval 被检查两遍
# 某库在某节点上、最近 <win> 秒内，每个 `<db>-<region>` 的 `Start ttl` 行数 / 不同秒数 / 比值
#   比值 1.00 = 正常（每周期一条）；2.00 = 同一周期两条（重复注册）
ttl_check_ratio(){ local h=$1 db=$2 win=$3 tmp from
  from=$(date -d "$win seconds ago" '+%Y-%m-%d %H:%M:%S')
  tmp=$(mktemp)
  sshx "$h" "grep -hE '\[TTL\] (root\.)?$db-[0-9]+ Start ttl and modification checking' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" > "$tmp" 2>/dev/null || true
  awk -v from="$from" '
    { ts = substr($1" "$2, 1, 19); if (ts < from) next
      if (match($0, /\[TTL\] [^ ]+ Start ttl/) == 0) next
      reg = substr($0, RSTART + 6, RLENGTH - 16)
      n[reg]++; sec[reg "|" substr($2, 1, 8)] = 1 }
    END { for (r in n) { c = 0; for (k in sec) { split(k, a, "|"); if (a[1] == r) c++ }
          printf "%s %d %d %.2f\n", r, n[r], c, (c ? n[r] / c : 0) } }' "$tmp"
  rm -f "$tmp"
}
# 从 ttl_check_ratio 的输出里取最大比值（0.00 = 窗口内没有该库的检查日志）
ttl_check_ratio_max(){ printf '%s\n' "$1" | awk 'NF >= 4 { if ($4 + 0 > m) m = $4 + 0 } END { printf "%.2f", m + 0 }'; }
# 某库的 region 目录名（`system/databases/<db>/<regionId>`），用于观察/制造"同步恢复"
ttl_region_ids(){ sshx "$1" "ls -1 $DB_DIR/data/datanode/system/databases/$2 2>/dev/null" 2>/dev/null | tr -d '\r'; }
# 把某库所有 region 的 FileTimeIndexCache_0 挪走（改名为 .bak_dupcase）：制造"启动时同步恢复"，
# 从而稳定复现 TDB-610（该文件只是时间索引缓存，缺失时按同步路径恢复，不影响数据）。返回挪走的个数。
ttl_drop_time_index_cache(){ sshx "$1" "n=0; for d in $DB_DIR/data/datanode/system/databases/$2/*/; do f=\"\${d}FileTimeIndexCache_0\"; if [ -f \"\$f\" ]; then mv -f \"\$f\" \"\${f}.bak_dupcase\" && n=\$((n+1)); fi; done; echo \$n" 2>/dev/null | tr -dc '0-9'; }
# 还原上面挪走的缓存，返回还原个数
ttl_restore_time_index_cache(){ sshx "$1" "n=0; for f in $DB_DIR/data/datanode/system/databases/$2/*/FileTimeIndexCache_0.bak_dupcase; do if [ -f \"\$f\" ]; then mv -f \"\$f\" \"\${f%.bak_dupcase}\" && n=\$((n+1)); fi; done; echo \$n" 2>/dev/null | tr -dc '0-9'; }
# 每个 DN 的落盘条数快照，形如 "192.168.99.77:2 192.168.99.78:2 "
ttl_close_snapshot(){ local db=$1 h s=""; for h in "${DN[@]}"; do s="$s$h:$(ttl_close_cnt "$h" "$db") "; done; echo "$s"; }
# 等所有 DN 都出现新的 close 事件（返回 0 成功 / 1 超时）；参数：<db> <快照串> <超时秒>
# 注意：deadline 必须另起一句赋值。`set -u` 下 `local a=$1 b=$(( ... a ... ))` 会因为
# bash 先展开全部词、后执行赋值而报 "a: unbound variable"（本项目实际踩过）。
wait_ttl_closed(){ local db=$1 snap=$2 timeout=${3:-90} h n w ok
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    ok=1
    for h in "${DN[@]}"; do
      n=$(ttl_close_cnt "$h" "$db"); n=${n:-0}
      w=$(printf '%s' "$snap" | tr ' ' '\n' | sed -n "s/^$h://p"); w=${w:-0}
      [ "$n" -gt "$w" ] || ok=0
    done
    [ "$ok" = 1 ] && return 0
    sleep 5
  done
  return 1
}
# 某 DN 上"真正生效"的 TTL 参数值（table 方言 show configuration，结果三列 name|value|default_value）。
# 注意 tree 方言的 `show variables` 只返回集群级参数，不含这三个键，必须用 table 方言。
ttl_effective_conf(){ local h=$1 k out; out=$(sqt_node "$h" 'show configuration;' 2>/dev/null)
  for k in expired_data_ratio max_expired_time ttl_check_interval; do
    printf '%s=%s ' "$k" "$(printf '%s\n' "$out" | awk -F'|' -v k="$k" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3)} $2==k{print $3; exit}')"
  done
  echo
}
# 实测某库的 TTL 检查周期（秒）：<node> <db> <观察秒数>
# 做法：取同一 `<db>-<region>` 相邻两条 `[TTL] ... Start ttl` 的时间差，只统计"结束时间在观察窗口内"的差，
# 再取中位数。**不要**用"窗口内行数做除法"——一个库可能有多个 region 各打一行，会把周期算成 1/N
# （本项目实测：配置 15s 被测成 6.7s，就是因为按行数除了 2 个 region）。
measure_ttl_interval(){ local h=$1 db=$2 secs=$3
  local start es reg ts gaps=() gap
  start=$(date +%s)
  sleep "$secs"
  local raw; raw=$(sshx "$h" "grep -hE '\[TTL\] (root\.)?$db-[0-9]+ Start ttl' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -80 | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}),.*(root\.)?$db-([0-9]+) .*/\3 \1/'")
  local -A last=()
  while read -r reg ts; do
    [ -n "${reg:-}" ] && [ -n "${ts:-}" ] || continue
    es=$(date -d "$ts" +%s 2>/dev/null) || continue
    if [ -n "${last[$reg]:-}" ] && [ "$es" -ge "$start" ]; then
      gap=$(( es - ${last[$reg]} ))
      # V2（IoTConsensusV2）实测：同一个检查周期会打**两条** `Start ttl`（相差约 1ms），
      # 于是相邻差里混进 0s，中位数被拉成一半（15s 配置被测成 7.5→8s）。
      # 过滤 <2s 的差即等价于"同一 tick 只算一次"，V1 上本来就没有这种重复，不受影响。
      [ "$gap" -ge 2 ] && gaps+=( "$gap" )
    fi
    last[$reg]=$es
  done <<<"$raw"
  [ "${#gaps[@]}" -eq 0 ] && { echo 0; return; }
  printf '%s\n' "${gaps[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2+0.5)}'
}
# 最近一条 [TTL] 日志（证据）
ttl_log_tail(){ local h=$1; sshx "$h" "grep -hE '\[TTL\]|Settle task deletes fully_dirty' $DB_DIR/logs/log_datanode_all.log $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null | tail -4" 2>/dev/null; }
# 查询返回的单个标量（count(*) 等表格第一行第一列）
scalar(){ printf '%s\n' "$1" | table_rows | head -1 | awk -F'|' '{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }
# 断言相等（默认值便于 - 表示空）
assert_scalar(){ local label=$1 got=$2 want=$3; if [ "$got" = "$want" ]; then pass "$label: $got"; else fail "$label: 实际=[$got] 期望=[$want]"; fi; }

# 轮询等待标量结果达到期望（用于 DELETE/TTL 后等副本应用变更；空结果按 0 处理）
wait_scalar_tree(){   # <sql> <期望> [超时秒] [说明]
  local sql=$1 want=$2 timeout=${3:-90} label=${4:-查询} deadline=$(( $(date +%s) + ${3:-90} )) got
  while (( $(date +%s) < deadline )); do
    got=$(scalar "$(sq "$sql")"); got=${got:-0}
    [ "$got" = "$want" ] && { pass "$label: $got"; return 0; }
    sleep 3
  done
  fail "$label: 实际=[$got] 期望=[$want]（等 ${timeout}s 仍未一致）"
  return 1
}
wait_scalar_table(){  # <sql> <期望> [超时秒] [说明]
  local sql=$1 want=$2 timeout=${3:-90} label=${4:-查询} deadline=$(( $(date +%s) + ${3:-90} )) got
  while (( $(date +%s) < deadline )); do
    got=$(scalar "$(sql_lines_table "$sql")"); got=${got:-0}
    [ "$got" = "$want" ] && { pass "$label: $got"; return 0; }
    sleep 3
  done
  fail "$label: 实际=[$got] 期望=[$want]（等 ${timeout}s 仍未一致）"
  return 1
}

# ---------------------------------------------------------------------------
# TTL 证据采集
# ---------------------------------------------------------------------------
# 某 DN 上某 database 的 TsFile 数
tsfile_count(){ local h=$1 db=$2
  local v; v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*${db}*' -name '*.tsfile' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"
}
tsfile_counts_all(){ local db=$1 h out=""; for h in "${DN[@]}"; do out="$out$(tsfile_count "$h" "$db"):"; done; echo "$out"; }

# 各 DN 上 [TTL] 日志统计： Start 检查次数 / 全过期文件被选中次数
ttl_log_stats(){ local h=$1
  sshx "$h" "grep -h -E '\[TTL\].*(Start ttl and modification checking|Totally select)' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -50" 2>/dev/null
}
ttl_selected_all_outdated(){ local h=$1
  sshx "$h" "grep -h -oE 'Totally select [0-9]+ all-outdated files' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | awk '{s+=\$3} END{print s+0}'" 2>/dev/null | tr -dc '0-9'
}

# 轮询等待：过期清理确实选中了文件（all-outdated > 0）或 TsFile 数下降
wait_ttl_cleanup(){   # 用法： wait_ttl_cleanup <db> <清理前 tsfile 计数串 "a:b:c" > [超时秒]
  local db=$1 before=$2 timeout=${3:-$CLEANUP_WAIT_SEC} deadline=$(( $(date +%s) + ${3:-$CLEANUP_WAIT_SEC} )) cur sel
  while (( $(date +%s) < deadline )); do
    cur=$(tsfile_counts_all "$db")
    sel=0; for h in "${DN[@]}"; do sel=$((sel + $(ttl_selected_all_outdated "$h"))); done
    log "  等清理: tsFiles=$cur (清理前=$before) allOutdatedSelected=$sel"
    if [ "$cur" != "$before" ] && [ "${sel:-0}" -gt 0 ]; then
      log "  过期清理已发生：tsFiles $before -> $cur，DN 日志 all-outdated 累计 $sel"
      return 0
    fi
    sleep 5
  done
  warn "等过期清理超时(${timeout}s)：tsFiles=$cur(清理前=$before) allOutdatedSelected=$sel"
  return 1
}

# ---------------------------------------------------------------------------
# 集群生命周期
# ---------------------------------------------------------------------------
cluster_stop(){
  log "--- 停止集群 ---"
  if [ "$USE_FRAMEWORK" = "1" ] && [ -f "$FRAMEWORK_DIR/clean_env/stop_cluster.sh" ]; then
    bash "$FRAMEWORK_DIR/clean_env/stop_cluster.sh" >>"$OUT" 2>&1 || warn "stop_cluster.sh 非 0"
  else
    local h
    for h in "${CN[@]}"; do sshx "$h" "$CN_DB_DIR/sbin/stop-confignode.sh -f >/dev/null 2>&1 || true" || true; done
    for h in "${DN[@]}"; do sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true" || true; done
    sleep 5
    for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
      sshx "$h" "pkill -f 'com\.timecho\.iotdb\.(ConfigNode|DataNode)' >/dev/null 2>&1 || true" || true
    done
    sleep 3
  fi
}
cluster_clean(){
  log "--- 清理 data/logs 并还原 conf_orig ---"
  if [ "$USE_FRAMEWORK" = "1" ] && [ -f "$FRAMEWORK_DIR/clean_env/clean_cluster.sh" ]; then
    bash "$FRAMEWORK_DIR/clean_env/clean_cluster.sh" >>"$OUT" 2>&1 || warn "clean_cluster.sh 非 0"
    bash "$FRAMEWORK_DIR/clean_env/reset_conf.sh"    >>"$OUT" 2>&1 || warn "reset_conf.sh 非 0"
  else
    local h
    for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
      # 受管键复位：conf_orig 可能被历史用例写入非默认值（如 enable_*_space_compaction=false 会让 TTL 永不清理），
      # 还原 conf 后把这些键删掉（删除即走安装包默认值）；用例需要非默认值时由自己的 cluster_write_conf 写入。
      sshx "$h" "rm -rf $DB_DIR/data $DB_DIR/logs; if [ -d $DB_DIR/conf_orig ]; then rm -rf $DB_DIR/conf; cp -rp $DB_DIR/conf_orig $DB_DIR/conf; fi; F=$DB_DIR/conf/iotdb-system.properties; [ -f \$F ] && sed -i -E '/^(enable_seq_space_compaction|enable_unseq_space_compaction|enable_cross_space_compaction|max_expired_time|expired_data_ratio|ttl_check_interval|wal_mode|enable_wal_compression|inner_compaction_candidate_file_num|compaction_schedule_interval_in_ms)=/d' \$F" || warn "清理 $h 失败"
    done
  fi
}
# 写入集群 + TTL 参数（纯 shell，无需 python）
cluster_set_conf(){
  local h=$1
  # 注意：这里不能用 sshx（它带 -n，会吞掉 heredoc），必须显式把脚本喂给远端 bash -s
  ssh $SSH_OPTS "$SSH_USER@$h" "DB='$DB_DIR' bash -s" <<REMOTE || fail "写配置失败: $h"
set -e
P="\$DB/conf/iotdb-system.properties"
[ -f "\$P" ] || { echo "missing \$P"; exit 1; }
set_prop(){ k="\$1"; v="\$2"
  # 先删掉该键的所有行（含注释形式与 SET CONFIGURATION 落盘产生的重复行），再追加一次，保证只有一行
  sed -i -E "/^[#[:space:]]*\${k}[[:space:]]*=/d" "\$P"
  printf '%s=%s\n' "\$k" "\$v" >> "\$P"
}
set_prop cn_seed_config_node       ${CN[0]}:$CN_INTERNAL_PORT
set_prop dn_seed_config_node       ${CN[0]}:$CN_INTERNAL_PORT
set_prop cn_internal_address       $h
set_prop cn_internal_port          $CN_INTERNAL_PORT
set_prop cn_consensus_port         $CN_CONSENSUS_PORT
set_prop dn_rpc_address            $h
set_prop dn_rpc_port               $DN_RPC_PORT
set_prop dn_internal_address       $h
set_prop dn_internal_port          $DN_INTERNAL_PORT
set_prop dn_mpp_data_exchange_port $DN_MPP_PORT
set_prop dn_schema_region_consensus_port $DN_SCHEMA_CONSENSUS_PORT
set_prop dn_data_region_consensus_port   $DN_DATA_CONSENSUS_PORT
set_prop schema_replication_factor $SCHEMA_RF
set_prop data_replication_factor   $DATA_RF
set_prop cluster_name              $CLUSTER_NAME
set_prop data_region_consensus_protocol_class $CONSENSUS_CLASS
set_prop cn_metric_reporter_list   PROMETHEUS
set_prop dn_metric_reporter_list   PROMETHEUS
set_prop cn_metric_prometheus_reporter_port $CN_METRIC_PORT
set_prop dn_metric_prometheus_reporter_port $DN_METRIC_PORT
set_prop ttl_check_interval        $TTL_CHECK_INTERVAL_MS
set_prop max_expired_time          $MAX_EXPIRED_TIME_MS
set_prop expired_data_ratio        $EXPIRED_DATA_RATIO
REMOTE
  # 用例自定的追加键值：EXTRA_CONF="k1=v1,k2=v2"
  # 注意：必须放在 heredoc **之外**——heredoc 内的变量会被本地展开，`set -u` 下未定义变量会直接报错
  # （曾因此把 `$EXTRA_CONF` 写进 heredoc 导致所有用例写配置失败）。
  local kv k v
  for kv in $(cluster_extra_pairs); do
    k="${kv%%=*}"; v="${kv#*=}"
    [ -n "$k" ] || continue
    sshx "$h" "P=$DB_DIR/conf/iotdb-system.properties; sed -i -E '/^[#[:space:]]*${k}[[:space:]]*=/d' \"\$P\"; printf '%s=%s\\n' '$k' '$v' >> \"\$P\"" \
      || fail "写扩展配置失败: $h $k=$v"
  done
}

# EXTRA_CONF 归一化：把 "k1=v1,k2=v2" 变成"同键后者胜"的 "k=v" 行列表。
# 为什么需要：用例常在 *_EXTRA_DEFAULT 之后追加"覆盖同一键"的值，例如
#   EXTRA_CONF="$WAL_EXTRA_DEFAULT,wal_file_size_threshold_in_byte=1048576"
# 写入侧是 sed 删除 + 追加 ⇒ 文件里只剩最后一个值；但校验侧若仍按原始列表逐条比对，
#   前面那条（默认值）必然对不上 ⇒ 每个节点各报 1 条假 FAIL（实测 W-08：3 条）。
# 因此写入 / 逐键校验 / 汇总三处统一走本函数，语义 = "最后出现的值生效"。
cluster_extra_pairs(){
  local kv k order="" seen=" "
  local -A _x=()
  for kv in $(printf '%s' "${EXTRA_CONF:-}" | tr ',' ' '); do
    k="${kv%%=*}"
    [ -n "$k" ] || continue
    case "$seen" in *" $k "*) ;; *) seen="$seen$k "; order="$order $k" ;; esac
    _x["$k"]="${kv#*=}"
  done
  for k in $order; do printf '%s=%s\n' "$k" "${_x[$k]}"; done
}

cluster_write_conf(){
  local h v
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do cluster_set_conf "$h"; done
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    v=$(sshx "$h" "grep -E '^data_region_consensus_protocol_class=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
    [ "$v" = "$CONSENSUS_CLASS" ] || fail "$h 共识协议写入不匹配: '$v' != '$CONSENSUS_CLASS'"
    v=$(sshx "$h" "grep -E '^ttl_check_interval=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
    [ "$v" = "$TTL_CHECK_INTERVAL_MS" ] || fail "$h ttl_check_interval 写入不匹配: '$v'"
    v=$(sshx "$h" "grep -E '^expired_data_ratio=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
    [ "$v" = "$EXPIRED_DATA_RATIO" ] || fail "$h expired_data_ratio 写入不匹配: '$v' != '$EXPIRED_DATA_RATIO'"
    v=$(sshx "$h" "grep -E '^max_expired_time=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
    [ "$v" = "$MAX_EXPIRED_TIME_MS" ] || fail "$h max_expired_time 写入不匹配: '$v' != '$MAX_EXPIRED_TIME_MS'"
    # 追加键值逐节点核对（这些键写错会静默影响用例判定）
    local kv k want
    for kv in $(cluster_extra_pairs); do
      k="${kv%%=*}"; want="${kv#*=}"
      [ -n "$k" ] || continue
      v=$(sshx "$h" "grep -E '^$k=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
      [ "$v" = "$want" ] || fail "$h $k 写入不匹配: '$v' != '$want'"
    done
    # 空值守卫：properties 里出现 `key=`（空值）会让 DN 热加载/启动直接失败
    # （NumberFormatException: For input string "" / No enum constant CompactionPriority.，
    #  实测把 2 个 DN 起挂过：某个用例 SET CONFIGURATION 'X'='' 还原"原本不存在的键"导致）
    local empties
    empties=$(sshx "$h" "grep -nE '^[a-z_]+=\$' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | head -5" 2>/dev/null | tr '\n' ' ')
    [ -n "$empties" ] && fail "$h properties 里有空值行（会让 DN 起不来）：$empties"
  done
  local keys="cluster_name|schema_replication_factor|data_replication_factor|data_region_consensus_protocol_class|ttl_check_interval|max_expired_time|expired_data_ratio" kv
  for kv in $(cluster_extra_pairs); do keys="$keys|${kv%%=*}"; done
  log "  配置确认(${CN[0]}): $(sshx "${CN[0]}" "grep -E '^($keys)=' $DB_DIR/conf/iotdb-system.properties | tail -20" | tr '\n' ' ')"
}
cluster_start(){
  log "--- 启动集群 ---"
  local h
  if [ "$USE_FRAMEWORK" = "1" ] && [ -f "$FRAMEWORK_DIR/prepare_env/start_cluster_v20.sh" ]; then
    cp -f "$FRAMEWORK_CN_LIST" "$FRAMEWORK_DIR/conf/confignode.txt" 2>/dev/null || true
    cp -f "$FRAMEWORK_DN_LIST" "$FRAMEWORK_DIR/conf/datanode.txt"   2>/dev/null || true
    # 加 timeout：框架脚本内部是 `while true; do show cluster; done`（**没有超时**），
    # 一旦集群起不来（残留进程抢端口等）会永久卡住；这里超时后交给我们自己的 wait_cluster_ready 判失败。
    timeout $(( CLUSTER_READY_TIMEOUT + 120 )) bash "$FRAMEWORK_DIR/prepare_env/start_cluster_v20.sh" 1 "$(( ${#CN[@]} + ${#DN[@]} ))" >>"$OUT" 2>&1 \
      || fail "集群启动脚本失败/超时（$(( CLUSTER_READY_TIMEOUT + 120 ))s）"
  else
    for h in "${CN[@]}"; do sshx "$h" "cd $CN_DB_DIR && nohup ./sbin/start-confignode.sh -d >/dev/null 2>&1 &" || warn "启动 CN $h 失败"; done
    sleep 10
    for h in "${DN[@]}"; do sshx "$h" "cd $DB_DIR && nohup ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" || warn "启动 DN $h 失败"; done
  fi
  wait_cluster_ready || fail "集群未在 ${CLUSTER_READY_TIMEOUT}s 内就绪"
}
wait_cluster_ready(){
  local want=$(( ${#CN[@]} + ${#DN[@]} )) deadline=$(( $(date +%s) + CLUSTER_READY_TIMEOUT )) n=0
  while (( $(date +%s) < deadline )); do
    n=$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running|ReadOnly')
    log "  集群就绪: $n/$want"
    [ "$n" -ge "$want" ] && { sq 'show cluster;' >>"$OUT" 2>&1; return 0; }
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------------------
# 指标源：**Prometheus HTTP API**（可选，推荐）或**直连各 DN 的 /metrics**
#
#   Prometheus 路径（用户在 conf/env.conf 里配 PROMETHEUS_URL 即启用）：
#     curl -s -G "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=<promql>"
#     （有账号时加 -u "$PROMETHEUS_USER:$PROMETHEUS_PASS"；用 --data-urlencode 就不必手工 %7B/%22 编码）
#   直连路径（默认回退，不依赖 Prometheus）：curl -s http://$h:$DN_METRIC_PORT/metrics
#
#   两者语义差异（重要）：
#     · 直连 = 该节点**此刻**的值；
#     · Prometheus = 服务端最近一次抓取的样本，抓取间隔见 PROM_SCRAPE_INTERVAL（本环境 10s），
#       且 stop 掉的节点在 **数据过期窗口（默认 5m）** 内仍能查到旧样本 ⇒
#       "等归零"可以放心用 Prometheus；"发现非零"最坏会晚一个抓取周期。
#
#   本环境已就绪（2026-10-20 实测）：99.80:9090 的 Prometheus（scrape_interval=10s）已抓取
#   3 个 DN(:9092) + 3 个 CN(:9091)，标签含 cluster/nodeType/instance/region：
#     {__name__=~"iot_consensus(_v2)?",type="syncLag",cluster="timecho",nodeType="DATANODE"} → 24 series 全 0
#     thrift_connections{cluster="timecho",name="ClientRPC",nodeType="DATANODE"} → 3 series
# ---------------------------------------------------------------------------
PROMETHEUS_URL=${PROMETHEUS_URL:-}
PROMETHEUS_USER=${PROMETHEUS_USER:-}
PROMETHEUS_PASS=${PROMETHEUS_PASS:-}
PROMETHEUS_CLUSTER=${PROMETHEUS_CLUSTER:-${CLUSTER_ID:-timecho}}
PROM_SCRAPE_INTERVAL=${PROM_SCRAPE_INTERVAL:-10}
SYNC_LAG_SOURCE=${SYNC_LAG_SOURCE:-auto}   # auto|prom|direct
PROMETHEUS_TIMEOUT=${PROMETHEUS_TIMEOUT:-20}

prom_healthy(){ [ -n "$PROMETHEUS_URL" ] && curl -s -o /dev/null -m 5 "$PROMETHEUS_URL/-/healthy"; }
# prom_query <promql> -> 原样 JSON；无 URL/查询失败返回非 0
prom_query(){ local q=$1 out
  [ -n "$PROMETHEUS_URL" ] || return 3
  if [ -n "$PROMETHEUS_USER" ]; then
    out=$(curl -s -m "$PROMETHEUS_TIMEOUT" -u "$PROMETHEUS_USER:$PROMETHEUS_PASS" -G \
            "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=$q" 2>/dev/null)
  else
    out=$(curl -s -m "$PROMETHEUS_TIMEOUT" -G \
            "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=$q" 2>/dev/null)
  fi
  [ -n "$out" ] || return 4
  printf '%s' "$out"
}
# prom_series <promql> -> 每行 "<instance> <value> <额外标签摘要>"；status!=success/解析失败返回非 0
prom_series(){ prom_query "$1" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
if d.get("status") != "success": sys.exit(3)
for r in d.get("data",{}).get("result",[]):
    m=r.get("metric",{})
    tags=",".join("%s=%s"%(k,v) for k,v in sorted(m.items()) if k not in ("__name__","instance"))
    print("%s %s %s" % (m.get("instance","?"), r.get("value",[0,"NaN"])[1], tags))
'; }
# prom_values <promql> -> 每行一个数值
prom_values(){ prom_series "$1" | awk '{print $2}'; }
# prom_all_zero <promql>：0=非空且全 0；1=存在非 0；2=无数据或查询失败
prom_all_zero(){ local s n bad
  s=$(prom_series "$1") || return 2
  [ -n "$s" ] || return 2
  n=$(printf '%s\n' "$s" | wc -l | tr -dc '0-9')
  bad=$(printf '%s\n' "$s" | awk '$2+0 > 0.0001' | wc -l | tr -dc '0-9')
  [ "${n:-0}" -gt 0 ] && [ "${bad:-1}" -eq 0 ] && return 0
  return 1
}
# prom_count_nonzero <promql> -> 非 0 series 数（无数据时输出 0）
prom_count_nonzero(){ prom_series "$1" 2>/dev/null | awk '$2+0 > 0.0001' | wc -l | tr -dc '0-9'; }
# prom_wait_all_zero <promql> [超时秒] [标签] —— 阻塞等到该查询"非空且全 0"
#   适合任意指标门禁，例如：prom_wait_all_zero 'thrift_connections{cluster="timecho",name="ClientRPC",nodeType="DATANODE"}' 60 ClientRPC
prom_wait_all_zero(){ local q=$1 to=${2:-120} tag=${3:-metric} dl
  dl=$(( $(date +%s) + to ))
  while (( $(date +%s) < dl )); do
    prom_all_zero "$q" && { log "  [$tag] 已全部归零（数据源 Prometheus）"; return 0; }
    sleep 10
  done
  warn "  [$tag] ${to}s 内未全部归零（Prometheus 查询：$q）"
  return 1
}

# ---------------------------------------------------------------------------
# 收尾检查 1：sync lag 归零
#   数据源：SYNC_LAG_SOURCE=auto（默认，Prometheus 可用就先用）/prom /direct
#   判据（两种源一致）：series > 0 且每条 < 1e-4；Prometheus 侧一次查询同时覆盖 V1/V2 指标名。
# ---------------------------------------------------------------------------
# PromQL 在**调用时**拼（env.conf 里的 PROMETHEUS_CLUSTER 覆盖 lib 默认值后才生效；V1/V2 指标名一起匹配）
sync_lag_promql(){ printf '%s' '{__name__=~"iot_consensus(_v2)?",type="syncLag",cluster="'"${PROMETHEUS_CLUSTER:-timecho}"'",nodeType="DATANODE"}'; }
sync_lag_scan_prom(){ local s n bad q
  q=$(sync_lag_promql)
  s=$(prom_series "$q") || { echo "-1 -1"; return 0; }
  [ -n "$s" ] || { echo "-1 -1"; return 0; }
  n=$(printf '%s\n' "$s" | wc -l | tr -dc '0-9')
  bad=$(printf '%s\n' "$s" | awk '$2+0 > 0.0001' | wc -l | tr -dc '0-9')
  echo "${n:-0} ${bad:-0}"
}
sync_lag_scan_direct(){
  local h body n=0 bad=0 line v
  for h in "${DN[@]}"; do
    body=$(curl -s -m 8 "http://$h:$DN_METRIC_PORT/metrics" 2>/dev/null | grep 'type="syncLag"')
    if [ -z "$body" ]; then echo "-1 -1"; return 0; fi
    while IFS= read -r line; do
      v=${line##* }
      n=$((n+1))
      awk -v x="$v" 'BEGIN{exit !(x+0>0.0001)}' && bad=$((bad+1))
    done <<<"$body"
  done
  echo "$n $bad"
}
sync_lag_scan(){
  local r n bad
  case "$SYNC_LAG_SOURCE" in
    prom)   sync_lag_scan_prom ;;
    direct) sync_lag_scan_direct ;;
    *)      # auto：Prometheus 有数据就用它，否则回退直连
            r=$(sync_lag_scan_prom); read -r n bad <<<"$r"
            if [ "${n:-0}" -gt 0 ]; then echo "$r"; else sync_lag_scan_direct; fi ;;
  esac
}
check_sync_lag(){
  local deadline=$(( $(date +%s) + SYNC_TIMEOUT_SEC )) stable=0 n bad src
  src=$SYNC_LAG_SOURCE; [ -z "$PROMETHEUS_URL" ] && src=direct
  while (( $(date +%s) < deadline )); do
    read -r n bad <<<"$(sync_lag_scan)"
    log "  syncLag series=$n nonzero=$bad （源=$src${PROMETHEUS_URL:+ PROMETHEUS_URL=$PROMETHEUS_URL}）"
    if [ "${n:-0}" -gt 0 ] && [ "${bad:-1}" -eq 0 ]; then stable=$((stable+1)); else stable=0; fi
    [ "$stable" -ge "$SYNC_STABLE_CHECKS" ] && { pass "sync lag 已归零（各数据区域 series 均为 0）"; return 0; }
    sleep 10
  done
  fail "sync lag 未在 ${SYNC_TIMEOUT_SEC}s 内归零 (series=$n nonzero=$bad)"
  return 1
}

# ---------------------------------------------------------------------------
# 一致性校验用到的结果归一化（consistency_check / consistency_check_on 共用）
# ---------------------------------------------------------------------------
q_one(){   # node dialect sql
  local out
  if [ "$2" = "table" ]; then out=$(sqt_node "$1" "$3"); else out=$(sq_node "$1" "$3"); fi
  printf '%s\n' "$out" | rows_of "$(cat)"
}
norm_result(){  # 归一化：报错 => ERROR:xxx；空 => EMPTY；否则数据行
  local txt=$1 rows
  if printf '%s\n' "$txt" | grep -qiE 'IoTDBSQLException|Exception'; then
    printf '%s\n' "$txt" | grep -oiE 'Exception[^|]*' | head -1 | sed 's/^/ERROR:/'; return
  fi
  rows=$(printf '%s\n' "$txt" | table_rows | sed -E 's/[[:space:]]+/ /g')
  if [ -z "$rows" ]; then echo EMPTY; else printf '%s\n' "$rows"; fi
}
query_result(){  # node dialect sql -> 归一化结果
  local out
  if [ "$2" = "table" ]; then out=$(sqt_node "$1" "$3"); else out=$(sq_node "$1" "$3"); fi
  norm_result "$out"
}

# ---------------------------------------------------------------------------
# 收尾检查 2：副本一致性
#   consistency_check <SQL> <dialect: tree|table>
#   做法：全部在线时各副本各查一次比基准；再逐个停 DN，用剩余副本查，仍要与基准一致
#
#   ⚠️ V1 / V2 两套口径（2026-10-17 定性；逐条证据见 _scratch/RC8_V2_DIVERGENCE_TRIAGE.md §3.1/§3.2/§④.1）：
#     ① **取基准之前先 FLUSH 并等"逐副本可见性"收敛**。原来直接
#        `base=$(query_result DN[0] …)`，基准可能取自 leader 的 memtable（内存），
#        follower 上根本没有这些行 —— V2 尤甚：默认 `iot_consensus_v2_mode=batch`
#        （`IoTDBDescriptor.java:1538`，由 `RegionMaintainHandler.java:705` 设进 pipe），
#        抽取器只搬**已 seal 的 TsFile**（`IoTDBDataRegionSource.java:438-447`），
#        而且是异步 connector（不等 follower 应用完）⇒ **已 ACK 但未 seal 的尾部写入不在 follower 上**。
#        DT-02（改类型后补写的 1 行 / kill -9 leader 后缺 1 行）与
#        DT-04（10 行 ACK 且可见 / 停 leader 后只剩 1 行）就是这类行。
#     ② V2 下"停 leader"这一格的判据 = 「剩余副本可见行数 ≥ 基准 − **未 seal 尾部行数**」
#        **且**「剩余行全部是基准行的子集」；未 seal 尾部行数由①的落盘/可见性轮询实测，
#        并打进日志作证据（不再要求与基准**完全相等**）。
#        **越界即 FAIL**：缺口比尾部还多、出现基准里没有的行、查询报错，一律按原口径判失败。
#     ③ **V1 一处不放松**：V1 逐条 WAL 复制，follower 的 memtable 里也有这些行 ⇒
#        停 leader 仍要求与基准完全一致，尾部行数只作证据打印（不使用它放松判据）。
#     ④ 聚合类查询（`select count(x)` 只有一行结果）天然不受这套口径影响：
#        它不满足"子集"条件 ⇒ 仍然硬判（CO-41 的 40/80/120 那种差异照样 FAIL）。
# ---------------------------------------------------------------------------
cons_is_v2(){ case "${DATA_CONSENSUS:-}${CONSENSUS_CLASS:-}" in *IoTConsensusV2*) echo 1 ;; *) echo 0 ;; esac; }
# 归一化结果的行数（EMPTY / ERROR:xxx 记 0）
cons_rows_n(){ local t=$1; case "$t" in EMPTY|ERROR:*) echo 0 ;; *) printf '%s\n' "$t" | sed '/^$/d' | wc -l | tr -dc '0-9' ;; esac; }
# cur 里"基准中没有的行"的条数（0 = cur ⊆ CONS_BASE）
cons_extra_n(){ local cur=$1 n
  n=$(comm -13 <(printf '%s\n' "$CONS_BASE" | sed '/^$/d' | sort) \
               <(printf '%s\n' "$cur"       | sed '/^$/d' | sort) 2>/dev/null | sed '/^$/d' | wc -l | tr -dc '0-9')
  echo "${n:-1}"; }
# 取基准：先 flush + 轮询"逐副本可见性"，把未 seal 尾部量出来（结果放全局，供 cons_judge 用）
#   CONS_BASE 基准结果；CONS_BASE_N 基准行数；CONS_MIN_N 逐副本最小可见行数；CONS_TAIL 未 seal 尾部行数
#
# ⚠️ V2（IoTConsensusV2）的"复制完成"判据 = **syncLag 归零**，而且必须在 flush 之后取：
#   · 指标：`iot_consensus_v2{…type="syncLag"…}`（V1 是 `iot_consensus{…}`），读每个 DN 的
#     `http://<dn>:9092/metrics`；要求**至少 1 条 series 且全部为 0**（见 sync_lag_scan）。
#   · 官方集成测试同口径：`IoTDBIoTConsensusV23C3DBasicITBase.java:817-848`（每条 0.0、容差 0.001、
#     超时 120s），且顺序为 `:150-201` INSERT → **FLUSH(:158)** → verifyDataConsistency → waitForReplicationComplete(:194)
#     → `stopForcibly()`(:201)。即"停 leader 之前必须先等 syncLag 归零"。
#   · 为什么必须先 flush：batch 模式只把**已 seal 的 TsFile**当复制单元
#     （`IoTDBDataRegionSource.java:438-442` ⇒ `PipeRealtimeDataRegionTsFileSource.java:59-62`），
#     replicate index 只在 TsFile 事件上递增（`ReplicateProgressDataNodeManager.java:59-71`
#     + `IoTConsensusV2AsyncSink.java:862-870`）⇒ 未 seal 的 memtable 尾部**不计入 syncLag**，
#     不 flush 就取到的 0 是"没有待复制单元"的空读。
#   ⇒ 本函数顺序：取基准 → flush + 等逐副本可见 → **（V2）等 syncLag 归零** → 归零则把尾部按 0 处理
#     （严格判据），未归零才退化为"允许未 seal 尾部"的容差 + WARN（带证据）。
CONS_VISIBLE_WAIT=${CONS_VISIBLE_WAIT:-60}
CONS_SYNC_WAIT=${CONS_SYNC_WAIT:-120}
CONS_BASE=""; CONS_BASE_N=0; CONS_MIN_N=0; CONS_TAIL=0; CONS_IS_V2=0; CONS_SYNCED=0
# V2 复制模式（`iot_consensus_v2_mode{type="replicateMode"}`）：2=BATCH，1=其它（STREAM/LOG）
#   数据源与 syncLag 一致：Prometheus 可用就查 Prometheus（`iot_consensus_v2_mode{type="replicateMode",cluster=…}`），
#   否则直连各 DN 的 /metrics。
v2_replicate_mode(){ local body m v
  if [ -n "$PROMETHEUS_URL" ] && [ "$SYNC_LAG_SOURCE" != direct ]; then
    v=$(prom_series 'iot_consensus_v2_mode{type="replicateMode",cluster="'"$PROMETHEUS_CLUSTER"'",nodeType="DATANODE"}' 2>/dev/null | head -1 | awk '{print $2}')
    [ -n "${v:-}" ] && { printf '%s' "$v"; return 0; }
  fi
  for h in "${DN[@]}"; do
    body=$(curl -s -m 5 "http://$h:$DN_METRIC_PORT/metrics" 2>/dev/null | grep 'replicateMode' | head -1)
    m=$(printf '%s' "$body" | awk '{print $NF}')
    [ -n "${m:-}" ] && { printf '%s' "$m"; return 0; }
  done
  return 1
}
# 等 V2 syncLag 归零；成功返回 0，并把 CONS_SYNCED 置 1
cons_wait_v2_sync(){ local dl2 n=0 bad=1 mode
  mode=$(v2_replicate_mode) && log "  [场景] iot_consensus_v2_mode(replicateMode)=$mode（2=BATCH ⇒ 复制单元=已 seal 的 TsFile）"
  dl2=$(( $(date +%s) + CONS_SYNC_WAIT ))
  while (( $(date +%s) < dl2 )); do
    read -r n bad <<<"$(sync_lag_scan)"
    [ "${n:-0}" -gt 0 ] && [ "${bad:-1}" -eq 0 ] && break
    log "  [同步] 等 V2 复制完成：syncLag series=${n:-0} nonzero=${bad:-?} ⇒ 再等（batch 只搬已 seal 的 TsFile）"
    sq "flush;" >/dev/null 2>&1
    sleep 5
  done
  if [ "${n:-0}" -gt 0 ] && [ "${bad:-1}" -eq 0 ]; then CONS_SYNCED=1; return 0; fi
  return 1
}
cons_prep(){ local nodes_str=$1 sql=$2 dialect=$3 dl h cur cn
  local nodes=(); read -ra nodes <<<"$nodes_str"
  CONS_BASE=$(query_result "${nodes[0]}" "$dialect" "$sql")
  CONS_BASE_N=$(cons_rows_n "$CONS_BASE"); CONS_MIN_N=$CONS_BASE_N
  dl=$(( $(date +%s) + CONS_VISIBLE_WAIT ))
  while (( $(date +%s) < dl )); do
    sq "flush;" >/dev/null 2>&1
    CONS_MIN_N=$CONS_BASE_N
    for h in "${nodes[@]}"; do
      cur=$(query_result "$h" "$dialect" "$sql"); cn=$(cons_rows_n "$cur"); cn=${cn:-0}
      [ "$cn" -lt "$CONS_MIN_N" ] && CONS_MIN_N=$cn
    done
    [ "$CONS_MIN_N" -ge "$CONS_BASE_N" ] && break
    log "  [落盘] 逐副本可见性未收敛：基准 ${CONS_BASE_N} 行 / 最少副本 ${CONS_MIN_N} 行 ⇒ 再 flush 并等（V2 batch 模式只复制已 seal 的 TsFile）"
    sleep 8
  done
  CONS_TAIL=$(( CONS_BASE_N - CONS_MIN_N )); [ "$CONS_TAIL" -lt 0 ] && CONS_TAIL=0
  log "  [基准] 经 ${nodes[0]} 取基准 ${CONS_BASE_N} 行（取基准前已 flush + 轮询逐副本可见性）；逐副本最小可见 ${CONS_MIN_N} 行 ⇒ **未 seal 尾部 ${CONS_TAIL} 行**"
  # ---- V2：复制完成门禁（syncLag 归零）——归零则尾部按 0 处理，走严格判据 ----
  if [ "${CONS_IS_V2:-0}" = 1 ]; then
    if cons_wait_v2_sync; then
      pass "  [同步] V2 syncLag 已归零（flush 之后取；series 全部 0）⇒ 复制完成，本次比对用**严格相等**判据"
      CONS_TAIL=0; CONS_MIN_N=$CONS_BASE_N
    else
      warn "  [同步] V2 syncLag 在 ${CONS_SYNC_WAIT}s 内未归零 ⇒ 保留\"未 seal 尾部 ${CONS_TAIL} 行\"的容差口径（V2 batch 只复制已 seal 的 TsFile；官方口径要求停节点前必须等 syncLag 归零）"
    fi
  fi
}
# 单格判据：等于基准 ⇒ PASS；V2 且（缺口 ≤ 未 seal 尾部 且 剩余行是基准子集）⇒ WARN（附证据）；否则 FAIL
#   ⚠️ 两个额外的门（避免"整副本空/基准本身就是空的"被误当成"未 seal 尾部"）：
#      · CONS_MIN_N > 0：基准时刻至少有一台副本能看到部分行（否则尾部=基准全部，容差就失去意义）
#      · cur_n > 0：被比较的那台副本至少能看到一些行（EMPTY 一律判 FAIL）
# 【诊断开关（2026-10-21）】CONS_RAW_SQL 设成"行级查询"时，一旦某格不一致就把该节点上的**原始行**落盘，
#   用于回答"count 差异是重复行还是另一份物理状态"这类问题（默认空 ⇒ 行为与之前完全一致）。
#   例：CONS_RAW_SQL='select dev, time, v from db1.t1 order by time;'   CONS_DIALECT=table
CONS_RAW_SQL="${CONS_RAW_SQL:-}"
CONS_DIALECT="${CONS_DIALECT:-}"
cons_dump_raw(){ local tag=$1 h=$2 sql=${3:-} dialect=${4:-} f n
  [ -n "${CONS_RAW_SQL:-}" ] || return 0
  sql=${sql:-$CONS_RAW_SQL}; dialect=${dialect:-${CONS_DIALECT:-tree}}
  f="$ART/consraw_$(printf '%s' "$tag" | tr -c '0-9A-Za-z_.-' '_').txt"
  query_result "$h" "$dialect" "$sql" >"$f" 2>&1
  n=$(wc -l <"$f" 2>/dev/null | tr -dc '0-9')
  log "  [诊断] 不一致格「$tag」经 $h 的原始行已存 $f（${n:-0} 行；SQL: $sql）"
}
# 【可选口径（2026-10-21，研发确认后新增）】CONS_ALLOW_SUPERSET=1：
#   TTL 的物理清理是**各副本本地、异步**的（SettleSelectorImpl.java:281-286/308），而 `ttl=INF` 后
#   过期旧点会重新可见（**属预期**，V1/V2 一致）⇒ 当查询固定读"可用副本列表第 0 个"
#   （AbstractFragmentParallelPlanner.java:120/137-144）时，停掉某副本会换数据源、读数可能变大。
#   本开关只放宽这一种形态：**基准 ⊆ 被测**（一行不少，只多出旧点）⇒ WARN；
#   少行 / 出现从未写入的键 / 查询报错 ⇒ 仍然 FAIL（"数据不能丢、不能凭空出现"不放松）。
CONS_ALLOW_SUPERSET=${CONS_ALLOW_SUPERSET:-0}
cons_judge(){ local tag=$1 cur=$2 node=${3:-} cur_n extra miss
  if [ "$cur" = "$CONS_BASE" ]; then pass "$tag 与基准一致"; return 0; fi
  cur_n=$(cons_rows_n "$cur")
  if [ "${CONS_IS_V2:-0}" = 1 ] && [ "${CONS_MIN_N:-0}" -gt 0 ] && [ "${cur_n:-0}" -gt 0 ] \
     && ! printf '%s' "$cur" | grep -q '^ERROR:'; then
    extra=$(cons_extra_n "$cur"); miss=$(( CONS_BASE_N - cur_n ))
    if [ "${extra:-1}" = 0 ] && [ "$miss" -ge 0 ] && [ "$miss" -le "${CONS_TAIL:-0}" ]; then
      warn "$tag 与基准差 ${miss} 行 ≤ 未 seal 尾部 ${CONS_TAIL} 行 ⇒ 不判数据丢失（V2 batch 只复制已 seal 的 TsFile：RegionMaintainHandler.java:705 + IoTDBDescriptor.java:1538 + IoTDBDataRegionSource.java:438-447；基准 ${CONS_BASE_N} 行 / 实测 ${cur_n} 行，剩余行全部是基准的子集）"
      return 0
    fi
  fi
  [ -n "${node:-}" ] && cons_dump_raw "$tag" "$node"
  # 基准 ⊆ 被测（只多不少）⇒ 视为"读到未清理副本的过期旧点"，记 WARN（见上面的 CONS_ALLOW_SUPERSET 说明）
  if [ "${CONS_ALLOW_SUPERSET:-0}" = 1 ] && [ "${cur_n:-0}" -gt 0 ] \
     && ! printf '%s' "$cur" | grep -q '^ERROR:'; then
    miss=$(comm -23 <(printf '%s\n' "$CONS_BASE" | sed '/^$/d' | sort) \
                    <(printf '%s\n' "$cur"       | sed '/^$/d' | sort) 2>/dev/null | sed '/^$/d' | wc -l | tr -dc '0-9')
    if [ "${miss:-1}" = 0 ]; then
      warn "$tag 读数比基准多 $(( cur_n - CONS_BASE_N )) 行，且**基准的每一行都在**（基准 ⊆ 实测）⇒ 多出的是未清理副本上的过期旧点（`ttl=INF` 后旧行重新可见属预期：SettleSelectorImpl.java:281-286/308 + 各副本本地异步清理；查询固定读副本列表第 0 个：AbstractFragmentParallelPlanner.java:120/137-144）"
      return 0
    fi
  fi
  fail "$tag 与基准不一致: [$(printf '%s' "$cur" | tr '\n' ' ')] vs [$(printf '%s' "$CONS_BASE" | tr '\n' ' ')]"
  return 1
}
consistency_check(){
  local sql=$1 dialect=${2:-tree} h on cur
  log "=== 副本一致性校验（${dialect}）: $sql ==="
  CONS_IS_V2=$(cons_is_v2)
  cons_prep "${DN[*]}" "$sql" "$dialect"
  log "  基准(经 ${DN[0]}): [$(printf '%s' "$CONS_BASE" | tr '\n' ' ')]"
  for h in "${DN[@]}"; do
    [ "$h" = "${DN[0]}" ] && continue
    cur=$(query_result "$h" "$dialect" "$sql")
    cons_judge "全部在线: $h" "$cur" "$h"
  done
  for h in "${DN[@]}"; do
    log "  --- 停 DataNode $h ---"
    sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true; pkill -f 'com\\.timecho\\.iotdb\\.DataNode' >/dev/null 2>&1 || true" || true
    wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "停 $h 后集群仍显示 Running"
    for on in "${DN[@]}"; do
      [ "$on" = "$h" ] && continue
      cur=$(query_result "$on" "$dialect" "$sql")
      cons_judge "停 $h 时经 $on 查询" "$cur" "$on"
    done
    sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}.log 2>&1 </dev/null &" || true
    wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || fail "DataNode $h 未恢复 Running"
  done
}
dn_state(){ sq 'show cluster;' 2>/dev/null | awk -F'|' -v ip="$1" '{gsub(/[[:space:]]/,"",$3);gsub(/[[:space:]]/,"",$4);gsub(/[[:space:]]/,"",$5)} $3=="DataNode" && $5==ip {print $4; exit}'; }
wait_dn_state(){ local ip=$1 want=$2 deadline=$(( $(date +%s) + $3 )) st
  while (( $(date +%s) < deadline )); do
    st=$(dn_state "$ip")
    [ "$want" = running ]    && [ "$st" = "Running" ] && return 0
    [ "$want" = notrunning ] && [ "$st" != "Running" ] && return 0
    sleep 3
  done
  return 1
}

# ---------------------------------------------------------------------------
# 收尾检查 3：CN/DN 异常日志分析
# ---------------------------------------------------------------------------
COMMON_ERR_PAT='NullPointerException|OutOfMemoryError|Java heap space|GC overhead limit exceeded|BufferUnderflowException|IndexOutOfBoundsException|ArrayIndexOutOfBoundsException|NegativeArraySizeException|NumberFormatException|has overlapped data|overlapped data|CompactionTableSchemaNotMatchException|DataTypeInconsistentException|StatisticsClassException|is not in tsFileMetaData|but return HAS_MORE_STATE'
# TTL 专项异常：只匹配"真的失败"，避免 INFO 级正常日志误报
CMP_ERR_PAT='Compaction[^|]*(failed|Failed|FAILED|error|Error)|Failed to (compaction|compact|merge)|task (is )?(killed|aborted)|CompactionException|Failed to recover compaction'
# 已知的正常 INFO 日志（例如 unset 不存在的规则、跨库操作提示），不计入异常
BENIGN_PAT='Not TTL rule set|Failed to execute plan org\.apache\.iotdb\.confignode\.consensus\.request\.write\.database\.SetTTLPlan'
# 用例可以再追加"本用例故意触发、属预期"的 benign 正则：`export CMP_LOG_BENIGN_EXTRA='…'`。
# 注意必须在**调用时**拼进 pattern：lib 是用例开头 source 的，那时 EXTRA 往往还没设（CO-16 踩过）。
#
# ---- 专项 skill 的**可覆盖钩子**（纯增量，默认空 ⇒ 行为与本文件原版逐字一致）----
#   本文件的异常正则与"正证据"是**合并（compaction）语义**（CMP_ERR_PAT / starts-finishes 统计）。
#   其它专项（如 CRUD / WAL）需要自己的异常面与正证据时，**不必改本文件**，只要在用例里导出：
#     · CMP_ERR_PAT_CUSTOM        追加异常正则（与 COMMON_ERR_PAT/CMP_ERR_PAT 取并集）
#     · CMP_POSITIVE_EVIDENCE_FN  "正证据"函数名；**设置后替代**合并专用的 starts/finishes 统计
#   两个钩子都在 check_logs **调用时**读取（用例 source 本文件之后再 export 也生效）。
#   CRUD 侧的默认实现与包装见 lib/crud_ext.sh（crud_positive_evidence / crud_install_err_pat）。
#   —— 本文件是 compaction / crud / wal 三个 skill 的**同一份** lib（md5 必须一致），
#      改这里等于三个 skill 一起改；不设置这两个变量时行为与合并专用版本完全一致。
CMP_ERR_PAT_CUSTOM="${CMP_ERR_PAT_CUSTOM:-}"
CMP_POSITIVE_EVIDENCE_FN="${CMP_POSITIVE_EVIDENCE_FN:-}"
check_logs(){
  local extra=${1:-} benpat="$BENIGN_PAT" pat h files n nodes benign evfn
  [ -n "${CMP_LOG_BENIGN_EXTRA:-}" ] && benpat="$benpat|$CMP_LOG_BENIGN_EXTRA"
  pat="$COMMON_ERR_PAT|$CMP_ERR_PAT${CMP_ERR_PAT_CUSTOM:+|$CMP_ERR_PAT_CUSTOM}${extra:+|$extra}"
  log "=== CN/DN 异常日志分析 ==="
  for role in confignode datanode; do
    if [ "$role" = confignode ]; then nodes=("${CN[@]}"); else nodes=("${DN[@]}"); fi
    for h in "${nodes[@]}"; do
      files=$(sshx "$h" "ls $DB_DIR/logs/*${role}*all*.log $DB_DIR/logs/*${role}*error*.log 2>/dev/null" 2>/dev/null | tr '\n' ' ')
      [ -z "$files" ] && { warn "$role $h 无日志文件"; continue; }
      benign=$(sshx "$h" "grep -hcE '$benpat' $files 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
      n=$(sshx "$h" "grep -hE '$pat' $files 2>/dev/null | grep -vcE '$benpat'" 2>/dev/null | tr -dc '0-9')
      if [ "${n:-0}" -gt 0 ]; then
        fail "$role $h 日志出现 $n 条异常（常见异常/TTL 异常）"
        sshx "$h" "grep -nE '$pat' $files 2>/dev/null | grep -vE '$benpat' | head -20 | cut -c1-240" >>"$OUT" 2>&1
      else
        pass "$role $h 日志无异常（已忽略 $benign 条已知正常 INFO，如 Not TTL rule set）"
      fi
    done
  done
  # 正证据：默认 = 合并任务是否真的跑过（inner/cross/settle 的 starts / finishes 行数）。
  # 若用例层设置了 CMP_POSITIVE_EVIDENCE_FN，则改调它（专项 skill 用自己的正证据；默认未设置 ⇒ 行为不变）。
  evfn="${CMP_POSITIVE_EVIDENCE_FN:-}"
  if [ -n "$evfn" ]; then
    if declare -F "$evfn" >/dev/null 2>&1; then
      "$evfn"
    else
      warn "  CMP_POSITIVE_EVIDENCE_FN=$evfn 未定义 ⇒ 回退到默认（合并任务累计）正证据"
      evfn=""
    fi
  fi
  if [ -z "$evfn" ]; then
    local started finished
    started=$(sum_over cmp_start_cnt_all)
    finished=$(sum_over cmp_finish_cnt_all)
    log "  合并任务累计（全部 DN、全部库）：starts=${started:-0} finishes=${finished:-0}"
  fi
}

# ---------------------------------------------------------------------------
# 备份日志 / 结果
# ---------------------------------------------------------------------------
backup_logs(){
  [ "$LOG_BACKUP" -eq 1 ] || { log "LOG_BACKUP=0，跳过日志备份"; return 0; }
  local dst="$ART/logs" h
  log "=== 备份 CN/DN 日志到 $dst ==="
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    if timeout 900 ssh -n $SSH_OPTS "$SSH_USER@$h" "tar czf - -C '$DB_DIR' logs" >"$dst/$h.logs.tgz" 2>/dev/null; then
      log "  backup $h -> $dst/$h.logs.tgz ($(du -h "$dst/$h.logs.tgz" 2>/dev/null | cut -f1))"
    else
      warn "backup $h 失败"
    fi
  done
}
write_result(){
  local r="FAIL" elapsed=$(( $(date +%s) - start_epoch )) csv msg
  [ "$fail_flag" -eq 0 ] && r="PASS"
  log "RESULT $r fail_flag=$fail_flag case=$CASE consensus=${CONSENSUS_CLASS##*.} build=$BUILD_TAG elapsed=${elapsed}s"
  log "v_warnMessage=${v_warnMessage:-<empty>}"
  printf 'run_id=%s\ncase=%s\nbuild=%s\nconsensus=%s\nresult=%s\nfail_flag=%s\nelapsed_seconds=%s\nartifact=%s\nv_warnMessage=%s\n' \
    "$RUN_ID" "$CASE" "$BUILD_TAG" "$CONSENSUS_CLASS" "$r" "$fail_flag" "$elapsed" "$ART" "${v_warnMessage:-}" \
    >"$OUTDIR/result_${CASE}_${RUN_ID}.txt"
  csv="$OUTDIR/test_result.csv"
  # CSV 里不能有换行（多行 message 会把一行拆成多行，CSV 直接废掉）：
  # v_warnMessage 常含 cmp_wait_merge 的多行等待日志 ⇒ 统一压成单行
  msg=$(printf '%s' "${v_warnMessage:-}" | tr '\n\r' '  ' | tr -s ' ' | tr ',' ';' | tr -d "'" | cut -c1-1200)
  [ -f "$csv" ] || echo 'Time,build,consensus,caseName,result,elapsedSeconds,failCount,artifact,message' >>"$csv"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date --iso-8601=seconds)" "$BUILD_TAG" "${CONSENSUS_CLASS##*.}" "$CASE.sh" "$r" "$elapsed" "$fail_flag" "$ART" "'$msg'" >>"$csv"
  log "结果已追加到 $csv"
}

# 收尾三件套（固定顺序：先等同步归零，再做副本一致性，最后看日志）
post_checks(){
  local sql=$1 dialect=${2:-tree}
  log "--- 收尾检查 1/3：sync lag 归零 ---"
  check_sync_lag || true
  if [ -n "$sql" ]; then
    log "--- 收尾检查 2/3：副本一致性 ---"
    consistency_check "$sql" "$dialect"
  fi
  log "--- 收尾检查 3/3：CN/DN 日志异常分析 ---"
  check_logs
}

# 版本对齐：skill 的 V_TESTDB 与框架 conf/test.conf 必须一致，否则会"框架起 RCx、skill 看 RCy"的错位
# （2026-10-15 实测踩到：test.conf 被切到 RC7 而 skill 默认 RC6 ⇒ 建库在 RC7、看文件/日志却去 RC6 目录）。
# 规则：**skill 的 V_TESTDB 为准**（可用环境变量或 --ver 覆盖），不一致时自动切 test.conf 并备份。
cmp_align_version(){
  [ "${USE_FRAMEWORK:-0}" = "1" ] || return 0
  local conf="$FRAMEWORK_DIR/conf/test.conf" cur cmt
  [ -f "$conf" ] || return 0
  cur=$(grep -E '^v_testdb=' "$conf" | head -1 | cut -d= -f2- | tr -d '\r')
  if [ "$cur" != "$V_TESTDB" ]; then
    cmt="${V_TESTDB##*_}"
    log "  [版本对齐] conf/test.conf v_testdb=$cur ≠ skill V_TESTDB=$V_TESTDB ⇒ 切换 test.conf（备份 ${conf##*/}.bak_$(date +%Y%m%d_%H%M%S)，v_commit=$cmt）"
    cp -p "$conf" "${conf}.bak_$(date +%Y%m%d_%H%M%S)"
    sed -i "s/^v_testdb=.*/v_testdb=$V_TESTDB/; s/^v_commit=.*/v_commit=$cmt/" "$conf"
    grep -E '^v_(testdb|commit)=' "$conf" | sed 's/^/    /'
  else
    log "  [版本对齐] conf/test.conf 与 skill V_TESTDB 一致：$V_TESTDB"
  fi
}

# 用例统一的集群准备：停 -> 清 -> 写参数 -> 启动（SKIP_LIFECYCLE=1 时复用已运行集群）
cmp_cluster_prepare(){
  cmp_align_version
  if [ "${SKIP_LIFECYCLE:-0}" = "1" ] && sq 'show cluster;' 2>/dev/null | grep -qE 'Running|ReadOnly'; then
    log "--- SKIP_LIFECYCLE=1：复用当前已运行的集群 ---"
    wait_cluster_ready || fail "集群未就绪"
    return 0
  fi
  cluster_stop
  # 清理残留 JVM：框架 stop_cluster.sh 偶尔会留下进程，重复进程会抢端口/Raft 锁，
  # 导致框架 start_cluster_v20.sh 里的 `show cluster` 轮询永远等不到 6/6（实测卡死过一次）。
  local _h
  for _h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    sshx "$_h" "pkill -f 'com\.timecho\.iotdb\.(ConfigNode|DataNode)' >/dev/null 2>&1 || true" || true
  done
  sleep 3
  cluster_clean
  cluster_write_conf
  cluster_start
}

# 用例统一收尾：失败备份日志 -> 停集群 -> 写结果
cmp_case_finish(){
  local do_consistency=${1:-} dialect=${2:-tree} sql=${3:-}
  if [ -n "$sql" ]; then consistency_check "$sql" "$dialect" || true; fi
  if [ "$fail_flag" -gt 0 ]; then backup_logs; else log "用例通过，不备份日志"; fi
  [ "${KEEP_DATA:-0}" = "1" ] || cluster_stop
  write_result
}


# ---------------------------------------------------------------------------
# 收尾（可指定节点子集）：REMOVE DATANODE / CONFIGNODE 之后集群节点数变了，
# 一致性只能按"仍在集群里的 DataNode"来比。
#   consistency_check_on "<节点,空格分隔>" <SQL> <tree|table>
# 口径与 consistency_check 完全一致（同一个 cons_prep / cons_judge：取基准前 flush + 等逐副本可见；
# V2 停 leader 允许"未 seal 尾部"的缺口，V1 一处不放松）。
# ---------------------------------------------------------------------------
consistency_check_on(){
  local nodes_str=$1 sql=$2 dialect=${3:-tree} h on cur
  local nodes=(); read -ra nodes <<<"$nodes_str"
  log "=== 副本一致性校验（${dialect}，节点: ${nodes[*]}）: $sql ==="
  CONS_IS_V2=$(cons_is_v2)
  cons_prep "$nodes_str" "$sql" "$dialect"
  log "  基准(经 ${nodes[0]}): [$(printf '%s' "$CONS_BASE" | tr '\n' ' ')]"
  for h in "${nodes[@]}"; do
    [ "$h" = "${nodes[0]}" ] && continue
    cur=$(query_result "$h" "$dialect" "$sql")
    cons_judge "全部在线: $h" "$cur" "$h"
  done
  for h in "${nodes[@]}"; do
    log "  --- 停 DataNode $h ---"
    sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true; pkill -f 'com\\.timecho\\.iotdb\\.DataNode' >/dev/null 2>&1 || true" || true
    wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "停 $h 后集群仍显示 Running"
    for on in "${nodes[@]}"; do
      [ "$on" = "$h" ] && continue
      cur=$(query_result "$on" "$dialect" "$sql")
      cons_judge "停 $h 时经 $on 查询" "$cur" "$on"
    done
    sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}.log 2>&1 </dev/null &" || true
    wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || fail "DataNode $h 未恢复 Running"
  done
}

# ===== inlined lib: crud_ext.sh =====
# ============================================================================
# 存储模块 CRUD 专项 skill —— CRUD 专属日志判据层（可选层；**默认不改变任何行为**）
#
# 背景（为什么需要这一层）：`lib/common.sh` 的 `check_logs` 是逐字节抄自"合并（compaction）专项
# skill"的，它里面有两处是**合并语义**，对 CRUD 用例不合适：
#   · 异常正则：`pat = COMMON_ERR_PAT | CMP_ERR_PAT`，其中
#     `CMP_ERR_PAT='Compaction[^|]*(failed|…) | Failed to (compaction|compact|merge) | …'`
#     —— 全是合并任务的失败模式，CRUD 的删除/加载/LastCache 失败模式一个都不覆盖；
#   · "正证据"：收尾时统计 `Compaction task starts / finishes successfully` 的累计行数
#     —— CRUD 用例里这个数**不会随用例动作增长**，打出来只会误导（"没增长"看起来像用例没生效）。
#
# 本层的做法（与 `lib/common.sh` 新增的两个**可覆盖钩子**配合，钩子是纯增量、默认空）：
#   · `CMP_ERR_PAT_CUSTOM`        追加异常正则（与 COMMON_ERR_PAT/CMP_ERR_PAT 取并集）
#   · `CMP_POSITIVE_EVIDENCE_FN`  "正证据"函数名；设置后 `check_logs` 调用**它**、
#                                 并以**替代**方式跳过合并专用的 starts/finishes 统计
# 提供的接口：
#   `crud_err_pat_extra`        CRUD 专属异常正则（建议集，逐条在 RC7 源码里核对过出处）
#   `crud_install_err_pat [re]` 安装/追加到 `CMP_ERR_PAT_CUSTOM`（**用例显式 opt-in**）
#   `crud_positive_evidence`    CRUD 版正证据（删除写入 / Load 相关 / LastCache 相关行数 + 本用例库 TsFile 数）
#   `crud_log_sum <pat>`        跨 DN 日志行数求和（正证据/断言复用）
#   `crud_check_logs [label]`   包装：装上 CRUD 正证据后调用 `check_logs`（等价于用例里 export 钩子）
#
# 用法（在用例里，**按需**）：
#   . "$HERE/../../lib/crud_ext.sh"
#   export CRUD_EVIDENCE_DB="$DB"                       # 正证据里带出本用例库的 TsFile 数（可选）
#   export CMP_POSITIVE_EVIDENCE_FN=crud_positive_evidence
#   crud_install_err_pat                                # 需要 CRUD 异常面时才装
#   … 之后 post_checks / check_logs 就会用上面的判据
#
# ⚠️ 两条纪律：
#   ① **不要全局默认启用异常正则**：CRUD 用例常有"故意触发报错"的负向相（错误码/非法 DDL），
#      广谱正则会把预期失败误判成产品问题。默认值保持空。
#   ② 钩子只在**调用 `check_logs` 时**读取（lib 是用例开头 source 的，那时用例还没 export）——
#      设置动作要放在 post_checks/check_logs 之前（与 `CMP_LOG_BENIGN_EXTRA` 同一坑，CO-16 踩过）。
#   本层不修改 `lib/common.sh` 的默认语义：不导出任何钩子时，check_logs 与合并 skill 完全一致。
# ============================================================================

# ---------------------------------------------------------------------------
# CRUD 专属异常正则（**建议集**；每条都在 RC7 源码里逐字核对过）
#   Delete ModificationFile {} failed.                     → StorageEngineMessages.java:311
#                                                            （ModificationFileV1.java:161 记 WARN）
#   Failed to read mods from {} for {}                     → StorageEngineMessages.java:492
#   Unrecognized LastCacheLoadStrategy …, fall back to CLEAN_ALL
#                                                          → StorageEngineMessages.java:757
#                                                            （DataRegion.java:5255 记 WARN）
#   Load: Query fallback failed for device …               → StorageEngineMessages.java:1579
# 说明：这些是"出现即真失败/真回退"的模式；不含 IoTDBSQLException 这类**广谱**串
#   （负向相里遍地都是），也不含 TTL/合并的既有模式（COMMON_ERR_PAT/CMP_ERR_PAT 已覆盖）。
CRUD_ERR_PAT_SUGGESTED='Delete ModificationFile .* failed|Failed to read mods from|Unrecognized LastCacheLoadStrategy|Load: Query fallback failed for device'

crud_err_pat_extra(){ printf '%s' "$CRUD_ERR_PAT_SUGGESTED"; }

# 安装（追加）CRUD 专属异常正则到 CMP_ERR_PAT_CUSTOM；不传参数就用建议集
crud_install_err_pat(){ local extra=${1:-$CRUD_ERR_PAT_SUGGESTED}
  if [ -z "$extra" ]; then warn "  crud_install_err_pat：正则为空 ⇒ 不安装（保持默认行为）"; return 0; fi
  if [ -n "${CMP_ERR_PAT_CUSTOM:-}" ]; then CMP_ERR_PAT_CUSTOM="$CMP_ERR_PAT_CUSTOM|$extra"
  else CMP_ERR_PAT_CUSTOM="$extra"; fi
  export CMP_ERR_PAT_CUSTOM
  log "  已安装 CRUD 专属异常正则（与 COMMON_ERR_PAT/CMP_ERR_PAT 取并集）：$CMP_ERR_PAT_CUSTOM"; }

# ---------------------------------------------------------------------------
# 跨 DN 日志行数求和（只读；用于正证据与"无 OOM"这类计数断言）
# ---------------------------------------------------------------------------
crud_log_sum(){ local pat=$1 h files n s=0
  for h in "${DN[@]}"; do
    files=$(sshx "$h" "ls $DB_DIR/logs/*datanode*all*.log $DB_DIR/logs/*datanode*error*.log 2>/dev/null" 2>/dev/null | tr '\n' ' ')
    [ -n "$files" ] || continue
    n=$(sshx "$h" "grep -hE '$pat' $files 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done
  echo "${s:-0}"; }

# ---------------------------------------------------------------------------
# CRUD 版"正证据"（用法：export CMP_POSITIVE_EVIDENCE_FN=crud_positive_evidence）
#   与合并 skill 的 starts/finishes 对应，CRUD 关心三类事件是否真的发生：
#     ① 删除真的落到 Mod 文件（`[Deletion] Deletion {} is written into {} mod files`，源码 :738）
#     ② Load 真的执行（`Successfully auto load tsfile …` :1314 / `Data type conversion for
#        LoadTsFileStatement {} is successful.` :1274 —— 这两条是 Pipe/自动加载与类型转换路径的权威串）
#     ③ LastCache 相关行数（**只说明"日志里提到了 LastCache"，不代表命中率**：
#        矩阵 §4-C5 明确"LastCache 命中率在 RC7 没有可查指标" ⇒ 不要拿它当性能判据）
#   另：设置 `CRUD_EVIDENCE_DB=<库>` 时附带该库的 TsFile 数（文件面正证据）。
# ---------------------------------------------------------------------------
crud_positive_evidence(){ local db="${CRUD_EVIDENCE_DB:-}" del load lc n
  del=$(crud_log_sum '\[Deletion\] Deletion .* is written into')
  load=$(crud_log_sum 'Successfully auto load tsfile|Data type conversion for LoadTsFileStatement .* is successful')
  lc=$(crud_log_sum 'LastCache|last cache')
  log "  CRUD 正证据（全部 DN 日志累计）：Deletion 写入=${del:-0} Load 相关=${load:-0} LastCache 相关=${lc:-0}（LastCache 只有\"提及\"计数，命中率不可观测，见矩阵 §4-C5）"
  if [ -n "$db" ] && declare -F cmp_all_sum >/dev/null 2>&1; then
    n=$(cmp_all_sum "$db")
    log "  CRUD 正证据（库 $db）：TsFile=${n:-0}（文件面；数据面正确性由用例自己的断言负责）"
  fi
  return 0; }

# ---------------------------------------------------------------------------
# 包装：装上 CRUD 正证据后调用 check_logs（不想 export 时可直接在用例里调用它）
#   crud_check_logs [额外异常正则]   —— 额外正则会作为 check_logs 的第 1 个参数追加
# ---------------------------------------------------------------------------
crud_check_logs(){ local extra=${1:-} prev="${CMP_POSITIVE_EVIDENCE_FN:-}"
  CMP_POSITIVE_EVIDENCE_FN="${CMP_POSITIVE_EVIDENCE_FN:-crud_positive_evidence}"
  check_logs "$extra"
  CMP_POSITIVE_EVIDENCE_FN="$prev"; }

# ===== inlined lib: wal_ext.sh =====
# ============================================================================
# 存储模块 WAL（写前日志）专项 skill —— WAL 专属观测/操作层（可选层；**默认不改变任何行为**）
#
# 为什么需要这一层：`lib/cmp.sh` 的观测面全是"合并语义"（TsFile 计数、Compaction 日志、
# writeLock 卡死线程），WAL 用例要的是另一套：
#   · 目录面：WAL 目录（`wal_dirs` 默认 `data/wal`）下的 `_<version>.wal` / `_<version>.checkpoint`
#   · 文件面：WAL 文件总字节（压缩对照用）、文件尾魔数 `WAL-V2`（确认"这真是 WAL 文件"）
#   · 状态面：阻塞中的写入线程（阻写=阻塞而非报错）、DN 进程/堆内存
#   · 故障面：kill -9（模拟掉电）后重启并等重放
#   · 指标面：DN metrics 端口里 WAL 相关指标（文档未给指标名 ⇒ **动态发现**，缺了只 WARN）
#
# 依据：`docs/req_sources/design_extract.md`（目录/文件名/魔数/Type 字节）、
#       `docs/req_sources/feature_extract.md`（压缩/队列内存/OBJECT）、
#       `docs/req_sources/source_grounding.md`（源码 file:line 印证）
#
# ⚠️ 三条纪律：
#   ① 本层**不修改** `lib/common.sh` / `lib/cmp.sh` 的默认语义；不导出钩子时行为完全一致。
#   ② 钩子（`CMP_ERR_PAT_CUSTOM` / `CMP_POSITIVE_EVIDENCE_FN`）只在 `check_logs` **被调用时**读取，
#      设置动作必须放在 post_checks/check_logs 之前。
#   ③ 所有 ssh 命令都必须是**单行、无本地变量泄漏**的：`$DB_DIR` 是本机变量、要让它在本机展开；
#      远端要用的变量用 `\$` 转义（cmp.sh 的 `cmp_log_files` 就是踩过这个坑才写成函数的）。
# ============================================================================

# ---------------------------------------------------------------------------
# ① WAL 目录定位
#   优先级：配置文件里的 wal_dirs/dn_wal_dirs（本机读远端文件）→ 常见相对路径探测 → find 兜底。
#   返回：一行一个绝对路径（可能有多个，wal_dirs 支持逗号分隔的多目录）。
#   ⚠️ RC8 首轮踩过的坑（已修）：
#     a) find 兜底会命中**安装目录**里的同名目录（`<db>/tools/wal`、`<db>/tools/windows/wal`），
#        于是"按库统计"恒为 0 而且**没有任何 WARN**（W-24 观察到此现象）⇒ 兜底时排除
#        `/tools/`、`/windows/`，并且**退化到兜底/结果为空都要 WARN**（不许静默）。
#     b) 本函数在一条用例里会被调用几十次（每次采样都调），WARN 只报一次/每节点，避免刷爆
#        v_warnMessage。
# ---------------------------------------------------------------------------
# 私有：可能没有 $OUT（被其它脚本 source 时）也能安全 WARN
_wal_warn(){ if [ -n "${OUT:-}" ]; then warn "$*"; else printf 'WARN %s\n' "$*" >&2; fi; }
_wal_warn_once(){ local h=$1; shift
  case " ${WAL_DIR_WARNED:-} " in *" $h "*) return 0 ;; esac
  WAL_DIR_WARNED="${WAL_DIR_WARNED:-}$h "; _wal_warn "$*"; }
wal_dir_roots(){ local h=$1 v out="" src=conf
  # 配置键在不同版本可能是 wal_dirs（1.x/2.0 设计文档）或 dn_wal_dirs（2.0 新版模板）
  v=$(sshx "$h" "grep -hE '^[[:space:]]*(wal_dirs|dn_wal_dirs)[[:space:]]*=' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | tail -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r')
  [ -n "$v" ] && out=$(printf '%s' "$v" | tr ',' '\n' | sed 's/[[:space:]]//g' | while read -r p; do
      [ -n "$p" ] || continue
      case "$p" in
        /*) echo "$p" ;;
        *)  echo "$DB_DIR/$p" ;;
      esac
    done)
  # 探测常见路径（设计文档给的是 data/wal；2.0 也有 data/datanode/wal 的布局）
  if [ -z "$out" ]; then
    src=probe
    out=$(sshx "$h" "for p in $DB_DIR/data/wal $DB_DIR/data/datanode/wal $DB_DIR/wal; do [ -d \"\$p\" ] && echo \"\$p\"; done" 2>/dev/null | tr -d '\r')
  fi
  # 兜底：find（限深，避免扫全盘）。**必须排除安装目录里的 tools/**、tools/windows/**
  if [ -z "$out" ]; then
    src=find
    out=$(sshx "$h" "find $DB_DIR -maxdepth 4 -type d -name wal 2>/dev/null | grep -vE '/(tools|windows)/' | head -3" 2>/dev/null | tr -d '\r')
    [ -n "$out" ] && _wal_warn_once "$h" "  [$h] wal_dir_roots 退化到 find 兜底（命中：$(printf '%s' "$out" | tr '\n' ' ')）——请核对 dn_wal_dirs 是否写对；按库统计可能因此恒为 0"
  fi
  if [ -z "$out" ]; then
    _wal_warn_once "$h" "  [$h] wal_dir_roots 没能定位到任何 WAL 目录（conf 键为空、常见路径与 find 兜底都没命中）——后续 WAL 文件面统计会恒为 0，请检查 dn_wal_dirs/数据目录"
  fi
  printf '%s\n' "$out" | sed '/^$/d' | sort -u; }

# 把多目录展开成远端 find 的表达式（`dir1 dir2` → `dir1 dir2`）
wal_roots_arg(){ local h=$1 r; r=$(wal_dir_roots "$h" | tr '\n' ' '); printf '%s' "${r:-$DB_DIR/data/wal}"; }

# WAL 文件数（`*.wal`；可给第 2 个参数：region 过滤，例如 `root.walx-3` 的 `-3` 不参与文件名 ⇒ 用目录过滤）
wal_file_cnt(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# checkpoint 文件数
wal_ckpt_cnt(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -name '*.checkpoint' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# WAL 总字节（压缩对照的核心观测）
wal_dir_bytes(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# WALNode 子目录数（max_wal_nodes_num 用例）
wal_node_dirs(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 文件清单（证据；含大小与相对路径）
wal_ls(){ local h=$1
  sshx "$h" "find $(wal_roots_arg "$h") \\( -name '*.wal' -o -name '*.checkpoint' \\) -printf '%s %p\n' 2>/dev/null | sort -k2 | head -40" 2>/dev/null | tr -d '\r'; }
# 文件尾魔数 `WAL-V2` 命中文件数（确认"这些确实是 WAL 文件"；二进制文件用 -a）
wal_magic_cnt(){ local h=$1 v
  v=$(sshx "$h" "for f in \$(find $(wal_roots_arg "$h") -name '*.wal' 2>/dev/null); do grep -qa 'WAL-V2' \"\$f\" && echo \"\$f\"; done | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 全集群口径（跨 DN 求和）
wal_sum_over_dn(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $($f "$h"))); done; echo "$s"; }
# 逐副本证据串：`77=files/bytes 78=… 79=…`
wal_per_node(){ local h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(wal_file_cnt "$h")f/$(wal_dir_bytes "$h")B "; done; echo "$out"; }

# ---------------------------------------------------------------------------
# ② WAL 日志（文档未给日志关键字 ⇒ 只能按**源码文案**匹配；见 source_grounding.md）
# ---------------------------------------------------------------------------
# 日志文件列表。**必须用函数**（写成单引号变量时 $DB_DIR 不会展开 ⇒ 匹配恒为 0，本项目踩过）
wal_log_files(){ echo "$DB_DIR/logs/log_datanode_all.log $DB_DIR/logs/log_datanode_wal.log"; }
# 跨 DN 日志行数求和（正证据/计数断言复用）
wal_log_sum(){ local pat=$1 h files n s=0
  for h in "${DN[@]}"; do
    files=$(sshx "$h" "ls $(wal_log_files) 2>/dev/null" 2>/dev/null | tr '\n' ' ')
    [ -n "$files" ] || continue
    n=$(sshx "$h" "grep -ahE '$pat' $files 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done
  echo "${s:-0}"; }
# 日志尾部（证据）
wal_log_tail(){ local h=$1 n=${2:-8}
  sshx "$h" "grep -ahEi 'wal' \$(ls $(wal_log_files) 2>/dev/null) 2>/dev/null | tail -$n" 2>/dev/null | tr -d '\r'; }

# ---------------------------------------------------------------------------
# ③ WAL 专属异常正则（**建议集**；每条都在源码里核对过出处后填写）
#   默认**不安装**：WAL 用例的负向相（非法配置、DISABLE 被拒、盘只读）会故意报错，
#   广谱正则会把预期失败误判成产品问题。
# ---------------------------------------------------------------------------
WAL_ERR_PAT_SUGGESTED='WAL[^|]*(failed|Failed to)|Failed to (write|append|fsync|recover|replay|read|delete) WAL|WALEntry[^|]*(failed|corrupt)|corrupt[^|]*WAL|WAL file[^|]*(corrupt|broken)|Failed to recover from WAL'
wal_err_pat_extra(){ printf '%s' "$WAL_ERR_PAT_SUGGESTED"; }
wal_install_err_pat(){ local extra=${1:-$WAL_ERR_PAT_SUGGESTED}
  if [ -z "$extra" ]; then warn "  wal_install_err_pat：正则为空 ⇒ 不安装（保持默认行为）"; return 0; fi
  if [ -n "${CMP_ERR_PAT_CUSTOM:-}" ]; then CMP_ERR_PAT_CUSTOM="$CMP_ERR_PAT_CUSTOM|$extra"
  else CMP_ERR_PAT_CUSTOM="$extra"; fi
  export CMP_ERR_PAT_CUSTOM
  log "  已安装 WAL 专属异常正则：$CMP_ERR_PAT_CUSTOM"; }

# ---------------------------------------------------------------------------
# ④ WAL 版"正证据"（export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence）
#   与合并 skill 的 starts/finishes 对应，WAL 关心：
#     ① WAL entry 落盘/刷盘相关行数   ② 恢复/重放相关行数   ③ WAL 文件删除/检查点相关行数
#     ④ WAL 目录文件数与总字节（文件面）
#   ⚠ 文档未给日志关键字 ⇒ 这里的计数是**弱证据**，只用于"确认 WAL 子系统确实在动"，
#     绝不作为功能判据（功能判据一律是数据面）。
# ---------------------------------------------------------------------------
wal_positive_evidence(){ local db="${WAL_EVIDENCE_DB:-}" w r c n
  w=$(wal_log_sum 'WAL|wal')
  r=$(wal_log_sum 'recover|Recover|replay|Replay')
  c=$(wal_log_sum 'WAL.*(delet|Delet|remov|Remov)|checkpoint|Checkpoint')
  n=$(wal_sum_over_dn wal_file_cnt)
  log "  WAL 正证据（全部 DN 日志累计）：含 wal 字样=${w:-0} 恢复/重放相关=${r:-0} 删除/检查点相关=${c:-0}"
  log "  WAL 正证据（文件面）：跨 DN WAL 文件数=${n:-0} 总字节=$(wal_sum_over_dn wal_dir_bytes)B；逐副本：$(wal_per_node)"
  [ -n "$db" ] && log "  （本用例库 $db；文件面按 WAL 目录统计，不按库过滤——WALNode 与 DataRegion 的映射见 design_extract.md §2）"
  return 0; }

# 包装：装上 WAL 正证据后调用 check_logs
wal_check_logs(){ local extra=${1:-} prev="${CMP_POSITIVE_EVIDENCE_FN:-}"
  CMP_POSITIVE_EVIDENCE_FN="${CMP_POSITIVE_EVIDENCE_FN:-wal_positive_evidence}"
  check_logs "$extra"
  CMP_POSITIVE_EVIDENCE_FN="$prev"; }

# ---------------------------------------------------------------------------
# ⑤ 故障注入：kill -9（掉电）/ 优雅停 / 单 DN 重启
# ---------------------------------------------------------------------------
# **精确取 DataNode 的 JVM pid**（本层唯一取 pid 的入口；用例里的 `*_dn_pid()` 也应改调它）
#   为什么不能用 `pgrep -f com.timecho.iotdb.DataNode`（RC8 首轮的根因）：
#     `sshx "$h" "pgrep -f com.timecho.iotdb.DataNode | head -1"` 这条命令在远端是以
#     `bash -c '<整串>'` 执行的，**这层 shell 自己的命令行里就含有 `com.timecho.iotdb.DataNode`**；
#     pgrep 只排除它自己、不排除父 shell ⇒
#       ① 取 pid 时可能拿到那层 shell（于是 `kill -9` 杀的是 shell，DataNode 毫发无损）；
#       ② **即使 DataNode 真的死了**，"是否已退出"的判断照样非空 ⇒ 表现为
#          "等满 180s 仍未退出 / kill -9 未生效"（W-04/W-05/W-12/W-19/W-26 实测都撞上）。
#   这里扫 `/proc/*/cmdline`，只认**可执行文件是 java**（`${c%% *}` 以 java 结尾）且命令行含
#   `DataNode` 的进程 ⇒ 天然排除 bash/sh/grep/pgrep/启动脚本；找不到就输出空（调用方据此判"没有 DN"）。
#   已核对本版本：`sbin/start-datanode.sh` 的主类是 `com.timecho.iotdb.DataNode`。
wal_dn_pid(){ local h=$1
  sshx "$h" 'for p in /proc/[0-9]*; do
      [ -r "$p/cmdline" ] || continue
      c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null) || continue
      x=${c%% *}
      case "$x" in *java) ;; *) continue ;; esac
      case "$c" in *DataNode*) echo "${p#/proc/}"; break ;; esac
    done' 2>/dev/null | tr -d '\r' | head -1; }
# 某 DN 上 DataNode 是否还活着（0=活着 / 1=没有）：用 `kill -0` 复核真实 pid，不用 pgrep
wal_dn_alive(){ local h=$1 pid=$2
  [ -n "${pid:-}" ] || return 1
  sshx "$h" "kill -0 $pid" >/dev/null 2>&1; }
# 单 DN kill -9：模拟掉电（SIGKILL 不给 JVM 任何收尾机会；进程直接消失）
wal_kill9_dn(){ local h=$1 pid dl
  pid=$(wal_dn_pid "$h")
  [ -n "${pid:-}" ] || { warn "  $h 上没有 DataNode 进程（kill -9 跳过）"; return 1; }
  log "  kill -9 DataNode pid=$pid @ $h（模拟掉电；pid 由 /proc/*/cmdline 精确识别）"
  sshx "$h" "kill -9 $pid" || warn "  kill -9 $h 失败"
  # SIGKILL 正常 1~2s 就消失 ⇒ 只等 30s；超时**不死等**，打证据后返回失败
  dl=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < dl )); do
    wal_dn_alive "$h" "$pid" || { log "  $h DataNode pid=$pid 已退出（kill -0 复核）"; return 0; }
    sleep 2
  done
  warn "  $h DataNode pid=$pid 在 30s 内仍存活（SIGKILL 未生效？）；证据：$(sshx "$h" "ps -o pid,ppid,stat,args -p $pid 2>/dev/null | tail -1" 2>/dev/null | tr -d '\r' | cut -c1-300)"
  return 1; }
# 单 DN 优雅停（正常 stop 脚本；用于"节点下线"类场景）
wal_stop_dn(){ local h=$1 pid dl
  pid=$(wal_dn_pid "$h")
  log "  优雅停止 DataNode @ $h（pid=${pid:-<未找到>}）"
  sshx "$h" "bash $DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true" || warn "  stop-datanode 非 0"
  dl=$(( $(date +%s) + ${DN_DOWN_WAIT_SEC:-180} ))
  while (( $(date +%s) < dl )); do
    wal_dn_alive "$h" "$pid" || { log "  $h DataNode 已停止（kill -0 复核）"; return 0; }
    sleep 2
  done
  warn "  $h DataNode 未在 ${DN_DOWN_WAIT_SEC}s 内停止（pid=${pid:-?}）；证据：$(sshx "$h" "ps -o pid,ppid,stat,args -p ${pid:-0} 2>/dev/null | tail -1" 2>/dev/null | tr -d '\r' | cut -c1-300)"
  return 1; }
# 单 DN 启动（不动其它节点）
wal_start_dn(){ local h=$1
  log "  启动 DataNode @ $h"
  sshx "$h" "cd $DB_DIR && nohup ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" || warn "  启动 $h 失败"
  local dl=$(( $(date +%s) + ${DN_RECOVER_WAIT_SEC:-300} )) st=""
  while (( $(date +%s) < dl )); do
    st=$(dn_state "$h")
    [ "$st" = "Running" ] && { log "  $h DataNode=${st}"; return 0; }
    sleep 5
  done
  warn "  $h DataNode 未在 ${DN_RECOVER_WAIT_SEC}s 内 Running（当前 '$st'）"; return 1; }
# 全集群重启（stop → start → ready）
wal_restart_all(){ cluster_stop; cluster_start; }

# ---------------------------------------------------------------------------
# ⑥ 恢复等待：重启后数据可见（WAL 重放完成）
#   `wait_scalar_tree`/`wait_scalar_table` 已经在 lib 里（轮询到值稳定），这里加一层
#   "WAL 文件被消费"的弱观测，便于打印证据。
# ---------------------------------------------------------------------------
wal_wait_replay(){ local db=$1 win=${2:-${WAL_REPLAY_WIN_SEC:-300}} dl h before after
  before=$(wal_sum_over_dn wal_file_cnt)
  log "  等待 WAL 重放（窗口 ${win}s；重启前 WAL 文件数=$before）"
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    sleep 10
    after=$(wal_sum_over_dn wal_file_cnt)
    if [ "${after:-0}" -lt "${before:-0}" ]; then
      log "  WAL 文件数下降：$before → $after（重放已消费部分 WAL）"; return 0
    fi
  done
  log "  WAL 文件数未下降（$before → ${after:-0}）——恢复后可能已重刷盘（见 design_extract.md §4：恢复后直接刷盘）"
  return 0; }

# ---------------------------------------------------------------------------
# ⑦ 指标面：文档未给 WAL 指标名 ⇒ 动态发现（缺了只 WARN）
# ---------------------------------------------------------------------------
# 列出该 DN metrics 里名字含 wal 的指标（时间序列名，去掉标签）
wal_metric_names(){ local h=$1
  sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -iE '^[a-zA-Z_:]*wal' | sed 's/[ {].*//' | sort -u" 2>/dev/null | tr -d '\r'; }
# 取某指标当前值之和（多标签时求和）；不存在时输出空
wal_metric(){ local h=$1 name=$2
  local pat
  pat=$(printf '%s' "$name" | sed 's/\./\\./g')
  sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -E '^$pat(\\{| )' | awk '{s+=\$NF} END{print s+0}'" 2>/dev/null | tr -dc '0-9.\-'; }
# 概率性指标抓取（写入前后对比方向）
wal_metric_snapshot(){ local h=$1 names; names=$(wal_metric_names "$h" | tr '\n' ' ')
  printf '%s' "$names"; }

# ---------------------------------------------------------------------------
# ⑧ 配置面：热加载 vs restart-only
#   `cmp_eff <h> <key>`（table 方言 show configuration）读**运行期生效值**；
#   `wal_props_get` 读**配置文件里的值**（判断"已落盘但未生效"）。
# ---------------------------------------------------------------------------
wal_props_get(){ local h=$1 k=$2
  sshx "$h" "grep -hE '^[[:space:]]*$k[[:space:]]*=' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | tail -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r'; }
wal_eff(){ local h=$1 k=$2; cmp_eff "$h" "$k"; }
wal_eff_all(){ local h=$1 k=$2; cmp_eff_all "$h" "$k"; }
# SET CONFIGURATION（返回文案是判据的一部分）
wal_set(){ local k=$1 v=$2; cmp_set_hot "$k" "$v"; }

# ---------------------------------------------------------------------------
# ⑨ 阻写观测：阻塞中的写入线程数（阻写=阻塞写入线程，非报错；见 feature_extract.md B）
#   ⚠️ pid 一律用 `wal_dn_pid`：旧的 `pgrep -f com.timecho.iotdb.DataNode` 会拿到远端
#      `bash -c` 包装 shell 的 pid ⇒ `jstack` 打空 ⇒ 阻塞线程数恒 0（假阴性）。
# ---------------------------------------------------------------------------
wal_blocked_writers(){ local h=$1 pid v
  pid=$(wal_dn_pid "$h")
  [ -n "${pid:-}" ] || { echo 0; return; }
  v=$(sshx "$h" "jstack $pid 2>/dev/null | grep -cE 'MemoryControlledWALEntryQueue|nonFullCondition|WALEntryQueue'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# DN 堆使用率（WAL 队列内存用例；只作证据）
wal_heap_ratio(){ local h=$1 pid v
  pid=$(wal_dn_pid "$h")
  [ -n "${pid:-}" ] || { echo ""; return; }
  sshx "$h" "jcmd $pid GC.heap_info 2>/dev/null | grep -oE 'used [0-9]+K' | head -1" 2>/dev/null | tr -dc '0-9'; }
# OOM 相关日志行数（硬判据：必须为 0）
wal_oom_cnt(){ wal_log_sum 'OutOfMemoryError|java\.lang\.OutOfMemory|GC overhead limit exceeded'; }

# ---------------------------------------------------------------------------
# ⑩ OBJECT 目录（表模型 OBJECT 真实内容；WAL 中只存引用）
#   路径：`${data_dir}/object_data/<dataRegionId>/${B32(table)}/…/<timestamp>.bin`
# ---------------------------------------------------------------------------
wal_object_root(){ local h=$1
  sshx "$h" "for p in $DB_DIR/data/datanode/object_data $DB_DIR/data/object_data $DB_DIR/object_data; do [ -d \"\$p\" ] && echo \"\$p\"; done" 2>/dev/null | tr -d '\r' | head -1; }
wal_object_cnt(){ local h=$1 r; r=$(wal_object_root "$h"); [ -n "$r" ] || { echo 0; return; }
  sshx "$h" "find $r -name '*.bin' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'; }

# ---------------------------------------------------------------------------
# ⑪ **权威指标口径**（源码印证：`commons/service/metric/enums/Metric.java:80-85,156-157`；
#    详见 docs/req_sources/source_grounding.md §9）
#   这些指标比"扫目录/数日志"权威得多，**优先用它做过程证据**：
#     file_count{name="wal"}            → WAL 文件数
#     file_size{name="wal"}             → WAL 总字节
#     wal_queue_mem_cost{name="wal_queue_current_mem_cost"|"wal_queue_max_mem_cost"}
#                                       → WAL 队列内存（对应用户可见的"WAL 队列内存"上限/当前值）
#     wal_buffer{name="used_ratio"|"entries_count"|"wal_entry_num_for_one_tsfile"|
#                     "serialized_wal_buffer_size"|"wrote_wal_buffer_size"|
#                     "wal_compress_cost"|"wal_uncompress_cost"|
#                     "read_wal_buffer_size"|"read_wal_buffer_cost"|"write_wal_buffer_cost"}
#     wal_cost{stage="make_checkpoint"|"serialize_wal_entry"|"sync_wal_buffer"}
#     wal_node_num（tag name=wal_nodes_num）
#     wal_node_info{name="effective_ratio_info"|"oldest_mem_table_ram_when_cause_snapshot"|
#                        "oldest_mem_table_ram_when_cause_flush", type=<walNodeId>}
#     flush_memtable_count{type="wal_flush_memtable_count"}
#   ⚠️ 注意：`WALNode.java` 里"删除过期 WAL 条数"的结论文案是 **DEBUG 级**、
#      默认 logback `<root level="info">` 不落盘 ⇒ **不要拿日志文案当判据**，用上面的指标 + 目录文件数。
# ---------------------------------------------------------------------------
# 通用：按"指标名前缀 + 标签子串"求和的取值器
wal_metric_sum(){ local h=$1 pre=$2 tag=${3:-} v
  if [ -n "$tag" ]; then
    v=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -E '^$pre\\{' | grep -F '$tag' | awk '{s+=\$NF} END{print s+0}'" 2>/dev/null | tr -dc '0-9.\-')
  else
    v=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -E '^$pre(\\{| )' | awk '{s+=\$NF} END{print s+0}'" 2>/dev/null | tr -dc '0-9.\-')
  fi
  echo "${v:-0}"; }
wal_metric_exists(){ local h=$1 pre=$2 n
  n=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -cE '^$pre(\\{| )'" 2>/dev/null | tr -dc '0-9')
  [ "${n:-0}" -gt 0 ] && echo 1 || echo 0; }
# WAL 文件数 / 总字节（指标口径）
wal_metric_file_cnt(){ wal_metric_sum "$1" 'file_count' 'name="wal"'; }
wal_metric_file_bytes(){ wal_metric_sum "$1" 'file_size' 'name="wal"'; }
# 队列内存（当前 / 峰值）
wal_metric_queue_cur(){ wal_metric_sum "$1" 'wal_queue_mem_cost' 'wal_queue_current_mem_cost'; }
wal_metric_queue_max(){ wal_metric_sum "$1" 'wal_queue_mem_cost' 'wal_queue_max_mem_cost'; }
# WALBuffer 子指标（如 used_ratio / entries_count / wal_compress_cost）
wal_metric_buffer(){ wal_metric_sum "$1" 'wal_buffer' "name=\"$2\""; }
# WALNode 数量 / 快照与 flush 触发原因
wal_metric_node_num(){ wal_metric_sum "$1" 'wal_node_num'; }
wal_metric_snapshot_ram(){ wal_metric_sum "$1" 'wal_node_info' 'oldest_mem_table_ram_when_cause_snapshot'; }
wal_metric_flush_ram(){ wal_metric_sum "$1" 'wal_node_info' 'oldest_mem_table_ram_when_cause_flush'; }
wal_metric_eff_ratio(){ wal_metric_sum "$1" 'wal_node_info' 'effective_ratio_info'; }
wal_metric_flush_memtable_cnt(){ wal_metric_sum "$1" 'flush_memtable_count' 'wal_flush_memtable_count'; }
# 跨 DN 求和/逐副本证据（指标口径，优先用于压缩对照与清理对照）
wal_metric_sum_over_dn(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $($f "$h"))); done; echo "$s"; }
wal_metric_per_node(){ local f=$1 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$($f "$h") "; done; echo "$out"; }
# 一条命令打印全部关键指标（首轮采样/证据用）
wal_metrics_dump(){ local h=$1
  log "  [$h] WAL 指标：files=$(wal_metric_file_cnt "$h") bytes=$(wal_metric_file_bytes "$h") queue_cur=$(wal_metric_queue_cur "$h") queue_max=$(wal_metric_queue_max "$h") nodes=$(wal_metric_node_num "$h") eff_ratio=$(wal_metric_eff_ratio "$h")"; }

# ===========================================================================
# ⑫ **覆写 `row_sum`（CLI 聚合值的数值解析）** —— RC8 首轮 ≥8 条用例被误判的根因
#
#   被覆写的原实现：`lib/common.sh:171`
#     row_sum(){ ... | awk -F'|' '{s=0; for(i=2;i<NF;i++){v=$i; gsub(/[^0-9-]/,"",v); if(v!="")s+=v} print s}' }
#   它把每个单元格**按字符剥掉非数字**再累加；而 CLI 把 `sum()`/`min()`/`max()` 结果按 **double**
#   打印（`count()` 是 long，所以 count 一直是对的）⇒ 两种失败形态（同一根因）：
#     ① 值 < 1e7：`Double.toString` 打 `8016000.0` ⇒ 剥掉小数点得 `80160000` —— **×10**
#        （W-11 `实际=801600000 / 期望=80160000`；W-16 `804000/80400`；W-17、W-18、W-21、W-23 同）
#     ② 值 ≥ 1e7：`Double.toString` 改用科学计数法 `2.4018E7`（= 每设备 24,018,000）
#        ⇒ 剥成 `24018` + 指数 `7` = `240187` —— **÷100**，方向相反
#        （W-14 `实际=2401870 / 期望=240180000`；W-15 的 `1.604E7→16047`、`1.60613E7→1606137` 同）
#
#   ⇒ 结论（手算逐条核对过）：**离线核算的期望值公式全部正确，错的是"实际值"的解析**。
#     例：W-11 `DEVS=10, ROWS=2000, BATCHES=4`，值 = `k+b` ⇒ 每设备
#         `4*2000*1999/2 + 2000*4*5/2 = 7,996,000+20,000 = 8,016,000`，×10 设备 = 80,160,000 ✓期望；
#         实际日志 801,600,000 = `8,016,000×10`（每列 `8016000.0`→`80160000`）×10 列 ⇒ 解析放大 10 倍。
#     例：W-14 `10×4000×3`，值 = `k+b` ⇒ 每设备 24,018,000，×10 = 240,180,000 ✓期望；
#         实际 2,401,870 = `2.4018E7`→`240187` ×10 列 ⇒ 解析缩小约 100 倍。
#
#   为什么在**本层**覆写（而不是改 lib/common.sh）：`lib/common.sh` 是所有 skill 共用的基线，
#   本专项约定不改它；而 27 条用例的 source 顺序恒为 `common.sh → cmp.sh → wal_ext.sh`
#   （已逐条核对）⇒ 这里后定义者胜，运行期对**用例自身**与 `lib/cmp.sh` 的
#   `cmp_fp_tree`/`cmp_fingerprint` 一并生效（它们也调 row_sum，指纹必须与期望值同口径）。
#
#   语义与原实现保持一致：只取**第一条数据行**、逐列求和、输出整数字符串
#   （整数用 `%.0f`，非整数用 `%.6f`）；差别只在"怎么把一个单元格读成数"。
#   ⚠️ 同类坑本项目已记录过：`diskusage_skill/SKILL.md:60`「表模型聚合列是 double（`1698.0`）
#      ⇒ 数值解析必须用 awk 的 `+0`，不要用 gsub 去非数字字符（会放大 10 倍）」。
# ===========================================================================
row_sum(){ printf '%s\n' "$1" | table_rows | head -1 | awk -F'|' '
  {
    s = 0
    for (i = 2; i < NF; i++) {
      v = $i
      gsub(/^[ \t\r]+/, "", v); gsub(/[ \t\r]+$/, "", v)
      # 只认真正的数值字面量（整数 / 小数 / 科学计数法 / 带符号）；null、空串、表头文本一律跳过
      if (v !~ /^[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$/) continue
      s += v + 0
    }
    if (s == int(s)) printf "%.0f\n", s
    else             printf "%.6f\n", s
  }'; }

# row_sum 单位自测（**离线**：只喂合成的 CLI 片段，不连集群、不读写任何文件）
#   用法： . lib/common.sh; . lib/cmp.sh; . lib/wal_ext.sh; wal_row_sum_selftest
#   ⚠️ 输入必须是**CLI 的真实表形态**：第 1 行是以 `|` 开头的表头（`table_rows` 会丢掉首行），
#      第 2 行才是数据行。聚合结果**没有 Time 列**（现场实测：`|count(root.dtd.m1.s1)|` + `|    2|`）。
_wal_rs_chk(){ local label=$1 input=$2 want=$3 got
  got=$(row_sum "$input")
  if [ "$got" = "$want" ]; then printf '  [ok] %s => %s\n' "$label" "${got:-<空>}"; return 0; fi
  printf '  [FAIL] %s => 实际[%s] 期望[%s]\n' "$label" "${got:-<空>}" "${want:-<空>}"; return 1; }
wal_row_sum_selftest(){ local bad=0 ten10 tenE7
  ten10='|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|'
  tenE7='|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|'
  # ① count（long，无小数位）
  _wal_rs_chk 'count 单列（long）'          $'|count(root.x.d1)|\n|    2|'          '2'         || bad=$((bad+1))
  # ② sum < 1e7 的 double 形态（`8016000.0`）：原实现会给出 80160000（×10）
  _wal_rs_chk 'sum 单列（.0 形态）'         $'|sum(root.x.d1)|\n|8016000.0|'       '8016000'   || bad=$((bad+1))
  # ③ `sum(db.**)` 的真实形态：10 个序列 = 10 列
  _wal_rs_chk 'sum 十列（.0 形态）'         "|sum(**)|
$ten10"                                                                            '80160000'  || bad=$((bad+1))
  # ④ ≥1e7 时 Java 用科学计数法（`2.4018E7` = 24,018,000）：原实现会给出 240187（÷100）
  _wal_rs_chk 'sum 单列（E7 形态）'         $'|sum(root.x.d1)|\n|2.4018E7|'        '24018000'  || bad=$((bad+1))
  _wal_rs_chk 'sum 十列（E7 形态）'         "|sum(**)|
$tenE7"                                                                            '240180000' || bad=$((bad+1))
  # ⑤ 小值 / 负数 / null / 空集 / CRLF
  _wal_rs_chk 'min（1.0）'                  $'|min(root.x.d1)|\n|1.0|'              '1'         || bad=$((bad+1))
  _wal_rs_chk '负数（-1234.0）'             $'|min(root.x.d1)|\n|-1234.0|'          '-1234'     || bad=$((bad+1))
  _wal_rs_chk 'null 单元格跳过'             $'|sum(**)|\n|null|300.0|'               '300'       || bad=$((bad+1))
  _wal_rs_chk 'CRLF 行尾（ssh 带回车）'     "|sum(root.x.d1)|
|300.0|"$'\r'                                                                      '300'       || bad=$((bad+1))
  _wal_rs_chk '空集（调用方用 ${got:-0}）'  'Empty set.'                              ''          || bad=$((bad+1))
  if [ "$bad" = 0 ]; then printf '[ok] row_sum 自测全部通过（10 项）\n'; return 0; fi
  printf '[FAIL] row_sum 自测失败 %s 项\n' "$bad"; return 1; }

# ===========================================================================
# ⑬ **树方言聚合取值 + 序列指纹**（W-04/W-05/W-11/W-12 的指纹共用）
#
#   为什么需要这一层 —— 本版本（RC8 `v20121rc8_1016_ebaf9da`）**原始报错行**（99.80 上
#   `results/wal_compress_recovery_IoTConsensus_20261017_151032.out:226-237`、
#   `results/wal_recovery_flush_boundary_IoTConsensus_20261017_140840.out:320-327`）：
#     ① `select min(s1) from root.walcmp9.**`  ⇒ 701
#        `Error occurred during inferring UDF data type:`
#        同一形态在**设备路径**上也报（`select min(s1) from root.walcmp.d6`）
#        ⇒ 本版本的 `min`/`max` **不是内建聚合名**（被当 UDF ⇒ 类型推断失败）；
#        内建名是 `min_value`/`max_value`（服务端 jar 里聚合清单的正字面量：
#        `\b(count|sum|avg|extreme|max_value|min_value|first_value|last_value|max_time|min_time|…)\b\s*\(`
#        —— 其中**没有**裸 `min`/`max`）。指纹里因此曾经出现 `total_min_sum=ERR`。
#     ② `select count(s1), sum(s1), min(s1), max(s1) from <路径>` ⇒ 701
#        `Raw data and aggregation hybrid query is not supported`
#        （一条查询里混多个聚合；通配路径与设备路径**都**报）
#        ⇒ 而旧代码把它当成"报错才拆分"的兜底，CLI 的错误文本又不含 `Exception`（含 `Msg:`），
#          于是落到 else 分支、`table_rows` 取不到行 ⇒ **静默**打印 `dev_dN=count= sum= min= max=`。
#     ③ `**` 通配路径上的 min/max 汇总本身也不可靠 ⇒ 一律**逐设备取值再在本地汇总**。
#   ⇒ 本层三条约定（以后改指纹不许破）：
#     a) **一条查询只放一个聚合**；b) **不查 `**`**，只查设备路径 `<db>.dN`；
#     c) 取不到值 ⇒ 打印**空**，由调用方写 `ERR`（绝不静默返回 0/空串：
#        "两边都一样空"会假装一致 ⇒ 假通过）。
#   写法探测：按"名字候选 × 路径候选"逐个试，**第一个成功的就是答案**（每项通常只发 1 条查询）。
#     ⚠️ 不要在这里做"探测结果缓存"：调用方一律用 `$(wal_agg1 …)`（子 shell），
#        缓存写不回来；曾写过缓存版，离线单测直接证明它恒为空（tools 里的临时单测）。
#     · 名字候选：min/max → `min_value|max_value`，退回 `min|max`（兼容 RC7 及更早版本）
#     · 路径候选：设备路径 `<db>.dN` → 序列路径 `<db>.dN.s1`（前者是本版本实测可用的聚合口径）
# ===========================================================================
wal_agg_is_err(){ printf '%s\n' "$1" | grep -qE 'IoTDBSQLException|Exception|^[[:space:]]*Msg:|Empty set|hybrid query|inferring UDF|Status code: [0-9]+'; }
# 取"最后一个数值单元格"（聚合结果没有 Time 列 ⇒ 单列；若带 Time 列，取末列同样正确）
wal_agg_pick(){ printf '%s\n' "$1" | table_rows | head -1 | awk -F'|' '
  { for (i = NF - 1; i >= 2; i--) {
      v = $i
      gsub(/^[ \t\r]+/, "", v); gsub(/[ \t\r]+$/, "", v)
      if (v ~ /^[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$/) { print v; exit } } }'; }
# 聚合名候选（min/max 两种写法都试；其余聚合就是它自己）
_wal_agg_names(){ case "$1" in
    min) printf '%s\n' min_value min ;;
    max) printf '%s\n' max_value max ;;
    *)   printf '%s\n' "$1" ;; esac; }
# 单设备单聚合 ⇒ 打印数值文本；所有候选写法都失败 ⇒ 打印空串（调用方转成 ERR）
wal_agg1(){ local fn=$1 dev=$2 name path out v
  for name in $(_wal_agg_names "$fn"); do
    for path in "$dev" "$dev.s1"; do
      out=$(sq "select $name(s1) from $path;")
      wal_agg_is_err "$out" && continue
      v=$(wal_agg_pick "$out")
      [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    done
  done
  return 1; }
# 单设备四项（count/sum/min/max 各一条查询；取不到的项写 ERR）
wal_dev_fp4(){ local dev=$1 c s mn mx
  c=$(wal_agg1 count "$dev")
  s=$(wal_agg1 sum "$dev")
  mn=$(wal_agg1 min "$dev")
  mx=$(wal_agg1 max "$dev")
  printf 'count=%s sum=%s min=%s max=%s' "${c:-ERR}" "${s:-ERR}" "${mn:-ERR}" "${mx:-ERR}" ; }
# 逐设备汇总 min/max（**替代** `select min(s1) from <db>.**`：该写法在本版本直接 701）
wal_dev_sum_of(){ local fn=$1 db=$2 n=$3 i v s=0
  for (( i=1; i<=n; i++ )); do
    v=$(wal_agg1 "$fn" "$db.d$i")
    [ -n "$v" ] || { printf 'ERR'; return 1; }
    s=$(awk -v a="$s" -v b="$v" 'BEGIN{ x = a + b; if (x == int(x)) printf "%.0f", x; else printf "%.6f", x }')
  done
  printf '%s' "$s"; }
# d1 全序列指纹（md5 + 行数）
#   ⚠️ md5 **必须**先 `data_rows`：CLI 的原始输出里含 `It costs 0.0xx s` 统计行（每次都不同）
#      与含序列全路径的表头 ⇒ 直接喂 md5sum 会让"两相永远不等"（假 FAIL）。
#      **判据不变**：两相 `d1_seq_md5` 必须相等（这里只修取值路径）。
wal_seq_fp(){ local db=$1 raw seq
  raw=$(sq "select s1 from $db.d1 order by time;")
  if wal_agg_is_err "$raw"; then printf 'd1_seq_md5=ERR\nd1_seq_rows=ERR\n'; return 1; fi
  seq=$(printf '%s\n' "$raw" | data_rows)
  printf 'd1_seq_md5=%s\n'  "$(printf '%s\n' "$seq" | md5sum | cut -c1-12)"
  printf 'd1_seq_rows=%s\n' "$(printf '%s\n' "$seq" | wc -l | tr -d ' ')"; }

# ===== 用例脚本原文 =====
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
