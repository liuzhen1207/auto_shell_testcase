#!/bin/bash
# ============================================================================
# 内存缓冲区（MB）专项回归 skill —— 公共库
#   source 本文件后可用：集群生命周期（停/清/写配置/启）、SQL 会话、断言、
#   syncLag 归零、副本一致性（逐个停 5 个 DN）、CN/DN 日志异常分析、结果落盘。
#   设计口径与 compaction skill 一致，便于两套 skill 互相迁移。
# ============================================================================

MB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MB_SKILL_DIR="$(cd "$MB_LIB_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# 环境加载
# ---------------------------------------------------------------------------
mb_paths(){
  DB_DIR="$DB_PARENT_DIR/$V_TESTDB"
  CN_DB_DIR="$CN_DB_PARENT_DIR/$V_TESTDB"
  CLI_DIR="$SHELL_CLIENT_DIR/$V_TESTDB"
  CLI="$CLI_DIR/sbin/start-cli.sh"
  read -ra CN <<<"$CN_NODES"
  read -ra DN <<<"$DN_NODES"
  QDN="${DN[0]}"
  export DB_DIR CN_DB_DIR CLI_DIR CLI QDN
}
mb_consensus_class(){
  case "$DATA_CONSENSUS" in
    *IoTConsensusV2*)
      # ⚠️ **必须用规范值 `...iot.IoTConsensusV2`，不能用 `...pipe.IoTConsensusV2`**。
      #   源码 ConsensusFactory 里：
      #     LEGACY_IOT_CONSENSUS_V2 = "org.apache.iotdb.consensus.pipe.PipeConsensus"
      #     REAL_IOT_CONSENSUS_V2   = "org.apache.iotdb.consensus.pipe.IoTConsensusV2"
      #     IOT_CONSENSUS_V2        = "org.apache.iotdb.consensus.iot.IoTConsensusV2"   ← 规范值
      #   归一化只在 `getConsensusImpl()`（DataNode 侧实例化）里做；
      #   而 ConfigNode 的 `RegionMaintainHandler.isIoTConsensusV2DataRegion()` 是
      #   `IOT_CONSENSUS_V2.equals(CONF.getDataRegionConsensusProtocolClass())` —— **直接比原始字符串、不归一化**。
      #   于是配成 `...pipe.IoTConsensusV2` 时会出现：
      #     · DataNode 正常按 V2 启动（归一化生效）
      #     · ConfigNode 判定"这不是 V2 region" ⇒ **从不创建 consensus pipe** ⇒ follower 永远收不到数据
      #     · 全程无 ERROR、syncLag 仍报 0（静默丢冗余）
      #   实测：用 `pipe.` 配法时 5 个节点只有 1 个有 TsFile；换成 `iot.` 规范值后两个副本都有数据、
      #   CN 日志出现 28 条 consensus pipe 记录。详见 docs/DEFECT_F-10.md。
      CONSENSUS_CLASS="org.apache.iotdb.consensus.iot.IoTConsensusV2"; CONS_TAG="IoTConsensusV2" ;;
    *)                CONSENSUS_CLASS="org.apache.iotdb.consensus.iot.IoTConsensus";   CONS_TAG="IoTConsensus" ;;
  esac
  export CONSENSUS_CLASS CONS_TAG
}

# ---------------------------------------------------------------------------
# Java 可见性（**踩过大坑**）：
#   用 systemd-run / cron / 非 login shell 等方式启动本 skill 时，PATH 里可能没有 java，
#   于是 start-cli.sh 报 `exec: java: not found`（rc=127），所有 SQL 都失败，
#   表现为 `wait_cluster_ready` 永远 0/8（而人工用 CLI 查却是 8/8 全 Running）。
#   这里在加载环境时主动补一次 java 路径，兼容 login / 非 login 两种启动方式。
# ---------------------------------------------------------------------------
mb_ensure_java(){
  command -v java >/dev/null 2>&1 && { export JAVA_HOME="${JAVA_HOME:-}"; return 0; }
  local c
  for c in ${MB_JAVA_CANDIDATES:-/home/cluster/jdk-17.0.9+9/bin /usr/local/share/jdk-17.0.9+9/bin /usr/lib/jvm/*/bin}; do
    if [ -x "$c/java" ]; then
      export PATH="$c:$PATH"
      export JAVA_HOME="${JAVA_HOME:-${c%/bin}}"
      return 0
    fi
  done
  return 1
}

mb_load_env(){
  local env_file="${1:-$MB_SKILL_DIR/conf/env.conf}"
  [ -f "$env_file" ] && . "$env_file"
  mb_paths
  mb_consensus_class
  mb_ensure_java || { echo "WARN: 未找到 java，CLI 可能不可用（可设 MB_JAVA_CANDIDATES 或 JAVA_HOME）" >&2; }
}

mb_parse_args(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --consensus) DATA_CONSENSUS="$2"; shift 2 ;;
      --ver)       V_TESTDB="$2"; BUILD_TAG="$2"; shift 2 ;;
      --env)       MB_ENV_FILE="$2"; shift 2 ;;
      --keep-data) KEEP_DATA=1; shift ;;
      *) echo "未知参数: $1" >&2; shift ;;
    esac
  done
  [ -n "${MB_ENV_FILE:-}" ] && . "$MB_ENV_FILE"
  mb_paths
  mb_consensus_class
  mb_ensure_java || true
}

# ---------------------------------------------------------------------------
# 用例脚手架与日志
# ---------------------------------------------------------------------------
mb_case_init(){
  CASE="$1"
  RUN_ID="$(date +%Y%m%d_%H%M%S)"
  OUTDIR="$MB_SKILL_DIR/results"
  OUT="$OUTDIR/${CASE}_${RUN_ID}.out"
  ART="$OUTDIR/artifact_${CASE}_${RUN_ID}"
  mkdir -p "$OUTDIR" "$ART" "$ART/logs"
  : >"$OUT"
  fail_flag=0
  v_warnMessage=""
  start_epoch=$(date +%s)
  log "=== $CASE 开始 run_id=$RUN_ID ==="
  log "环境: build=$BUILD_TAG consensus=$CONS_TAG nodes=[${DN[*]}] cn=[${CN[*]}] db_dir=$DB_DIR schemaRF=$SCHEMA_RF dataRF=$DATA_RF"
}

log(){  local m="[$(date '+%F %T')] $*"; printf '%s\n' "$m" >>"$OUT"; printf '%s\n' "$m"; }
note(){ v_warnMessage="${v_warnMessage}$* "; }
warn(){ note "$*"; log "WARN $*"; }
fail(){ fail_flag=$((fail_flag+1)); note "$*"; log "FAIL $(printf '%s' "$*" | tr '\n\r' '  ')"; }
pass(){ log "PASS $(printf '%s' "$*" | tr '\n\r' '  ')"; }

assert_contains(){ local l=$1 o=$2 p=$3
  if printf '%s' "$o" | grep -qE "$p"; then pass "$l"; else fail "$l: 期望包含 /$p/，实际=[$(printf '%s' "$o" | tr '\n' ' ' | cut -c1-300)]"; fi; }
assert_not_contains(){ local l=$1 o=$2 p=$3
  if printf '%s' "$o" | grep -qE "$p"; then fail "$l: 不应出现 /$p/，实际=[$(printf '%s' "$o" | grep -E "$p" | head -2 | tr '\n' ' ' | cut -c1-300)]"; else pass "$l"; fi; }
assert_eq(){ local l=$1 g=$2 w=$3
  if [ "$g" = "$w" ]; then pass "$l: $g"; else fail "$l: 实际=[$g] 期望=[$w]"; fi; }
assert_ge(){ local l=$1 g=$2 w=$3
  if [ -n "$g" ] && [ "$g" -ge "$w" ] 2>/dev/null; then pass "$l: $g >= $w"; else fail "$l: 实际=[$g] 期望 >= $w"; fi; }

# ---------------------------------------------------------------------------
# SSH / SQL
# ---------------------------------------------------------------------------
sshx(){ local h=$1; shift; ssh -n $SSH_OPTS "$SSH_USER@$h" "$@" 2>/dev/null; }

strip_echo(){ grep -vE '^[[:alnum:]_:]*DB>([[:space:]]|$)' | grep -vE '^[-+]+$'; }
table_rows(){ grep -E '^\|' | grep -vE '^\|[-+ ]+\|$' | tail -n +2; }

sq(){        timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 -e "$1" 2>&1; }
sq_node(){   timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$1"   -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 -e "$2" 2>&1; }
sqt(){       timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 3600 -e "$1" 2>&1; }
sqt_node(){  timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$1"   -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 3600 -e "$2" 2>&1; }
session_tree(){  timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 2>&1; }
session_node(){  timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$1"   -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 2>&1; }

rows_of(){ printf '%s\n' "$1" | table_rows | sed -E 's/[[:space:]]+/ /g; s/(^\| )|( \|$)//g'; }
n_rows(){ printf '%s\n' "$1" | table_rows | wc -l | tr -d ' '; }
scalar(){ printf '%s\n' "$1" | table_rows | head -1 | awk -F'|' '{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }
# 树方言在"具体设备路径"上做聚合会返回空集（实测：select count(s1) from db.d1.s1 => Empty set），
# 所以单设备行数一律用"原始查询数行"，见 SKILL.md 踩坑表。
# 只数"首列是时间戳"的数据行：树方言结果表头形如 |   Time|root.db.d.s1|，
# 用 table_rows+tail 扣表头在个别结果集上会差 1 行（实测 2000 点被数成 2001），
# 因此这里直接用时间戳形状判定，不依赖表头位置。
mb_time_rows(){ awk -F'|' 'NF>=3 && $2 ~ /^[ \t]*[0-9]{4}-[0-9]{2}-[0-9]{2}T/ {n++} END{print n+0}'; }
mb_rows(){ local out; out=$(sq "$1"); printf '%s\n' "$out" | mb_time_rows; }
mb_rows_node(){ local out; out=$(sq_node "$1" "$2"); printf '%s\n' "$out" | mb_time_rows; }
mb_count_dev(){ mb_rows "select s1 from $1.$2 order by time;"; }
mb_count_devs(){ local db=$1 first=$2 last=$3 d n tot=0; for ((d=first; d<=last; d++)); do n=$(mb_count_dev "$db" "d$d"); tot=$(( tot + ${n:-0} )); done; echo "$tot"; }
# 一致性/数据量判据用 SQL：**通配聚合**（每序列一列 count），输出只有一行，天然紧凑。
#   ⚠️ 不要用"原始查询 + 数行"做 2000 行 × 4KB TEXT 的数据量判据：
#      实测 CLI 侧输出到 ~4MB 后被截断（2000 行只数到 1000 行），会误判"数据丢失"；
#      而且几十 MB 的 bash 变量还会把用例进程拖进 OOM（表现为 rc=137 Killed）。
#   树方言的两个坑（都实测过）：具体设备路径上的聚合返回空集（`from db.d1.s1` ⇒ Empty set），
#      只有 `from db.dN.s1` → 不行、`from db.*.**` → 不行，**只有 `from db.**` 通配聚合可用**。
mb_data_sql(){ printf 'select count(s1) from %s.**;' "$1"; }
# 某库所有序列的点数合计（从通配聚合结果里把各列数值相加）
#
# ⚠️ **必须区分"查询报错"与"结果真的是 0"**（F-09 踩过的大坑）：
#   BACKWARD 排序算法下查询会抛 `301: blocks should never be zero`，CLI 把这段错误文本
#   打到 stdout。原来的实现用 `gsub(/[^0-9]/,"")` 清洗非数字字符，于是
#   `301: blocks should never be zero.` 被洗成 `301`、再被当成年份/数值参与相加，
#   或清洗后为空、最终返回 `0` —— 用例便把"查询崩溃"写成"点数=0（数据丢失）"，
#   把一个 301 报错误判成了数据丢失，白折腾了几轮。
# 现在的约定：
#   · 正常返回一个非负整数；
#   · 查询报错时返回字面量 **QUERY_ERROR**（调用方 assert_eq 自然会 FAIL 并打印原文）。
mb_count_all(){ local out; out=$(sq "$(mb_data_sql "$1")")
  if printf '%s' "$out" | grep -qE 'Msg:|IoTDBSQLException|Exception|Status code: [0-9]+'; then
    printf '%s' "$out" | grep -oE '(Msg:.*|Status code: [0-9]+.*)' | head -1 >&2
    printf 'QUERY_ERROR\n'; return 0
  fi
  printf '%s\n' "$out" | table_rows | head -1 | awk -F'|' '{s=0; for(i=2;i<=NF;i++){v=$i; gsub(/[^0-9]/,"",v); if(v!="")s+=v} print s+0}'; }
# 同上的"严格版"：报错时返回非 0 退出码，供需要区分成败的调用方使用
mb_count_all_strict(){ local n; n=$(mb_count_all "$1")
  [ "$n" = "QUERY_ERROR" ] && return 1
  printf '%s\n' "$n"; }
now_ms(){ date +%s%3N; }

# 树模型建库 + 设备时序：mb_make_tree_db <db> <devs> [dtype]
mb_make_tree_db(){ local db=$1 devs=$2 dtype=${3:-int64} d out
  out=$(sq "create database $db;" 2>&1)
  printf '%s' "$out" | grep -q 'successfully' || warn "建库 $db: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  for ((d=1; d<=devs; d++)); do
    sq "create timeseries $db.d$d.s1 with datatype=$dtype;" >/dev/null 2>&1
  done
  return 0
}

# 批量写 TEXT：mb_bulk_text <db> <dev> <rows> <batch_index> <payload_bytes> [node]
#   ⚠️ 客户端 CLI（start-cli.sh）是**单 JVM 全内存**执行的：实测一次喂 10MB SQL 会
#      `java.lang.OutOfMemoryError: Java heap space`（客户端侧，不是服务端），
#      并且"2MB 单语句"实测 52s 且静默失败。因此这里强制分片：
#        · 每条 INSERT 的载荷 ≤ MB_STMT_PAYLOAD_BYTES（默认 768KB）；
#        · 每次 CLI 调用只喂 MB_STMTS_PER_CHUNK 条语句（默认 1）。
#      输出 "<成功语句数> <失败语句数>"。
mb_bulk_text(){ local db=$1 dev=$2 rows=$3 b=${4:-1} pb=${5:-$MB_PAYLOAD_BYTES} node=${6:-}
  local pay per rows_per_stmt chunk stmts left off=0 k a
  pay=$(head -c "$pb" /dev/zero | tr '\0' 'a')
  per=${MB_STMT_PAYLOAD_BYTES:-786432}
  rows_per_stmt=$(( per / pb )); [ "$rows_per_stmt" -lt 1 ] && rows_per_stmt=1
  chunk=${MB_STMTS_PER_CHUNK:-1}; [ "$chunk" -lt 1 ] && chunk=1
  local total_ok=0 total_bad=0
  local base=$(( b * 100000000 ))
  left=$rows
  while (( left > 0 )); do
    local file="/tmp/mb_${CASE:-x}_${dev}_${b}_$$.sql"; : >"$file"
    stmts=0
    while (( left > 0 && stmts < chunk )); do
      local n=$(( left < rows_per_stmt ? left : rows_per_stmt ))
      printf 'insert into %s.%s(time,s1) values ' "$db" "$dev" >>"$file"
      for ((k=0;k<n;k++)); do
        printf "(%d,'%s')" $(( base + (off+k)*10 )) "$pay" >>"$file"
        (( k < n-1 )) && printf ',' >>"$file"
      done
      printf ';\n' >>"$file"
      left=$(( left - n )); off=$(( off + n )); stmts=$(( stmts + 1 ))
    done
    local wout="/tmp/mb_wout_$$_${RANDOM}.out"
    if [ -n "$node" ]; then session_node "$node" < "$file" >"$wout" 2>&1
    else session_tree < "$file" >"$wout" 2>&1; fi
    n_ok=$(grep -c 'executed successfully' "$wout" 2>/dev/null | tr -dc '0-9')
    total_ok=$(( total_ok + ${n_ok:-0} ))
    # ⚠️ `grep -c` 在 0 匹配时返回 exit 1 且**仍然打印 0**；再写 `|| echo 0` 会得到 "0\n0"，
    # 代入 $(()) 直接语法错（实测 MB-06 因此拿不到写入结果）。这里统一用 tr 兜底。
    n_bad=$(grep -E 'SQLException|OutOfMemoryError|Exception in thread|^Msg: ' "$wout" 2>/dev/null | grep -vc 'executed successfully' | tr -dc '0-9')
    total_bad=$(( total_bad + ${n_bad:-0} ))
    cat "$wout" >>"${MB_WRITE_LOG:-/dev/null}" 2>/dev/null || true
    rm -f "$file" "$wout"
  done
  echo "$total_ok $total_bad"
}

# 批量写 INT64：mb_bulk_int <db> <dev> <rows> <batch_index> [node]
#   与 mb_bulk_text 同样的分片策略；输出 "<成功语句数>"
mb_bulk_int(){ local db=$1 dev=$2 rows=$3 b=${4:-1} node=${5:-}
  local per=${MB_ROWS_PER_STMT:-500} stmts_per=${MB_STMTS_PER_CHUNK:-1} left=$rows off=0 k stmts
  local base=$(( b * 100000000 ))
  local total_ok=0
  while (( left > 0 )); do
    local file="/tmp/mbi_${CASE:-x}_${dev}_${b}_$$.sql"; : >"$file"
    stmts=0
    while (( left > 0 && stmts < stmts_per )); do
      local n=$(( left < per ? left : per ))
      printf 'insert into %s.%s(time,s1) values ' "$db" "$dev" >>"$file"
      for ((k=0;k<n;k++)); do
        printf '(%d,%d)' $(( base + (off+k)*10 )) $(( off+k )) >>"$file"
        (( k < n-1 )) && printf ',' >>"$file"
      done
      printf ';\n' >>"$file"
      left=$(( left - n )); off=$(( off + n )); stmts=$(( stmts + 1 ))
    done
    local wout="/tmp/mbi_wout_$$_${RANDOM}.out"
    if [ -n "$node" ]; then session_node "$node" < "$file" >"$wout" 2>&1
    else session_tree < "$file" >"$wout" 2>&1; fi
    n_ok=$(grep -c 'executed successfully' "$wout" 2>/dev/null | tr -dc '0-9')
    total_ok=$(( total_ok + ${n_ok:-0} ))
    cat "$wout" >>"${MB_WRITE_LOG:-/dev/null}" 2>/dev/null || true
    rm -f "$file" "$wout"
  done
  echo "$total_ok"
}

# ---------------------------------------------------------------------------
# 集群生命周期：停 -> 清 data/logs -> 写配置 -> 启动
#   注意：**不调用框架的 reset_conf.sh**。本环境的 conf_orig 是 tar 包原始配置
#   （127.0.0.1 + RF=1），还原它会直接把集群配成单机单副本、起不来。
#   本 skill 每次从零生成完整 conf（幂等），保证"每用例干净集群 + 已知配置"。
# ---------------------------------------------------------------------------
cluster_stop(){
  log "--- 停止集群 ---"
  if [ "$USE_FRAMEWORK" = "1" ] && [ -f "$FRAMEWORK_DIR/clean_env/stop_cluster.sh" ]; then
    timeout 900 bash "$FRAMEWORK_DIR/clean_env/stop_cluster.sh" >>"$OUT" 2>&1 || warn "stop_cluster.sh 非 0"
  else
    local h
    for h in "${DN[@]}"; do sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true"; done
    for h in "${CN[@]}"; do sshx "$h" "$CN_DB_DIR/sbin/stop-confignode.sh -f >/dev/null 2>&1 || true"; done
    sleep 5
    for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
      sshx "$h" "pkill -f 'com\.timecho\.iotdb\.(ConfigNode|DataNode)' >/dev/null 2>&1 || true"
    done
  fi
  # 兜底：框架脚本可能漏掉残留进程（残留进程会抢端口/Raft 锁，导致启动永久卡住）
  local h
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    sshx "$h" "pkill -9 -f 'com\.timecho\.iotdb\.(ConfigNode|DataNode)' >/dev/null 2>&1 || true"
  done
  sleep 3
}

verify_all_stopped(){
  local h p bad=0
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    p=$(sshx "$h" "sudo jps -l 2>/dev/null | grep -cE 'com\.timecho\.iotdb\.(ConfigNode|DataNode)'" | tr -dc '0-9')
    if [ "${p:-0}" != "0" ]; then fail "节点 $h 仍有 $p 个 IoTDB 进程残留，禁止清理 data/logs"; bad=1; fi
  done
  [ "$bad" = 0 ] && pass "全节点无残余 IoTDB 进程"
  return 0
}

cluster_clean(){
  log "--- 清理 data/logs（不做 conf_orig 还原）---"
  verify_all_stopped
  if [ "$USE_FRAMEWORK" = "1" ] && [ -f "$FRAMEWORK_DIR/clean_env/clean_cluster.sh" ]; then
    timeout 600 bash "$FRAMEWORK_DIR/clean_env/clean_cluster.sh" >>"$OUT" 2>&1 || warn "clean_cluster.sh 非 0"
  fi
  local h
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    sshx "$h" "sudo rm -rf $CN_DB_DIR/data $CN_DB_DIR/logs" || warn "清理 $h data/logs 失败"
  done
  # 清理校验：data 目录必须消失（框架脚本按清单删，清单与 env.conf 不一致时会漏）
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    if sshx "$h" "test -d $CN_DB_DIR/data"; then fail "节点 $h 的 data 目录未被清理"; fi
  done
}

# 生成并写入一个节点的完整 conf。EXTRA_CONF="k1=v1,k2=v2" 追加覆盖。
cluster_write_conf(){
  local h ip kv k v
  local nodes; nodes=$(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u)
  for h in $nodes; do ip="$h"
    # 重试 3 次：框架的 stop/clean 脚本会连续开大量 ssh，sshd 的 MaxStartups 可能瞬时限流
    #（实测 MB-05 一次性 6 个节点全部 "写配置失败"，重试即可恢复）。失败时把 stderr 也记下来。
    local attempt rc_w=0
    for attempt in 1 2 3; do
    ssh $SSH_OPTS "$SSH_USER@$h" "DB='$DB_DIR' bash -s" <<REMOTE

set -e
P="\$DB/conf/iotdb-system.properties"
[ -f "\$P" ] || { echo "missing \$P"; exit 1; }
sudo tee "\$P" >/dev/null <<'CONF'
cluster_name=$CLUSTER_NAME
cn_seed_config_node=${CN[0]}:$CN_INTERNAL_PORT
dn_seed_config_node=${CN[0]}:$CN_INTERNAL_PORT
cn_internal_address=$ip
cn_internal_port=$CN_INTERNAL_PORT
cn_consensus_port=$CN_CONSENSUS_PORT
dn_rpc_address=$ip
dn_rpc_port=$DN_RPC_PORT
dn_internal_address=$ip
dn_internal_port=$DN_INTERNAL_PORT
dn_mpp_data_exchange_port=$DN_MPP_PORT
dn_schema_region_consensus_port=$DN_SCHEMA_CONSENSUS_PORT
dn_data_region_consensus_port=$DN_DATA_CONSENSUS_PORT
schema_replication_factor=$SCHEMA_RF
data_replication_factor=$DATA_RF
data_region_consensus_protocol_class=$CONSENSUS_CLASS
cn_metric_reporter_list=PROMETHEUS
dn_metric_reporter_list=PROMETHEUS
cn_metric_prometheus_reporter_port=$CN_METRIC_PORT
dn_metric_prometheus_reporter_port=$DN_METRIC_PORT
cn_metric_level=IMPORTANT
dn_metric_level=IMPORTANT
schema_region_group_extension_policy=CUSTOM
data_region_group_extension_policy=CUSTOM
default_schema_region_group_num_per_database=1
default_data_region_group_num_per_database=5
dn_thrift_max_frame_size=171966464
region_migration_speed_limit_bytes_per_second=0
# 若用例/环境未指定比例，写产品默认 3:3:1:1:1:1（Pipe 池 ≈1.4 GB），避免写成空值导致 DN 起不来
datanode_memory_proportion=${MB_MEM_PROPORTION:-3:3:1:1:1:1}
storage_engine_memory_proportion=$MB_STORAGE_PROPORTION
write_memory_proportion=$MB_WRITE_PROPORTION
flush_proportion=$MB_FLUSH_PROPORTION
reject_proportion=$MB_REJECT_PROPORTION
wal_buffer_queue_proportion=$MB_WAL_QUEUE_PROPORTION
device_path_cache_proportion=$MB_DEVICE_PATH_PROPORTION
buffered_arrays_memory_proportion=$MB_BUFFERED_ARRAYS_PROPORTION
wal_buffer_size_in_byte=$MB_WAL_BUFFER_SIZE
wal_memtable_snapshot_threshold_in_byte=$MB_WAL_SNAPSHOT_THRESHOLD
max_wal_memtable_snapshot_num=$MB_MAX_WAL_SNAPSHOT_NUM
enable_timed_flush_seq_memtable=$MB_TIMED_FLUSH_SEQ
seq_memtable_flush_interval_in_ms=$MB_SEQ_FLUSH_INTERVAL
seq_memtable_flush_check_interval_in_ms=$MB_SEQ_FLUSH_CHECK
enable_timed_flush_unseq_memtable=$MB_TIMED_FLUSH_UNSEQ
unseq_memtable_flush_interval_in_ms=$MB_UNSEQ_FLUSH_INTERVAL
unseq_memtable_flush_check_interval_in_ms=$MB_UNSEQ_FLUSH_CHECK
check_period_when_insert_blocked=$MB_CHECK_PERIOD_WHEN_BLOCKED
max_waiting_time_when_insert_blocked_in_ms=$MB_MAX_WAIT_WHEN_BLOCKED
io_task_queue_size_for_flushing=$MB_IO_TASK_QUEUE_SIZE
primitive_array_size=$MB_PRIMITIVE_ARRAY_SIZE
CONF
# 追加用例自定义键（先删同名行，保证只有一行）
REMOTE
      rc_w=$?
      [ "$rc_w" -eq 0 ] && break
      warn "写配置失败: $h（第 $attempt 次，rc=$rc_w）"
      sleep 3
    done
    [ "$rc_w" -ne 0 ] && fail "写配置失败: $h（已重试 3 次）"
    for kv in $(printf '%s' "${EXTRA_CONF:-}" | tr ',' ' '); do
      k="${kv%%=*}"; v="${kv#*=}"
      [ -n "$k" ] || continue
      sshx "$h" "P=$DB_DIR/conf/iotdb-system.properties; sudo sed -i -E '/^[#[:space:]]*${k}[[:space:]]*=/d' \"\$P\"; printf '%s=%s\n' '$k' '$v' | sudo tee -a \"\$P\" >/dev/null" \
        || fail "写扩展配置失败: $h $k=$v"
    done
  done
  # 回读校验：空值行会让 DN 热加载/启动直接失败（NumberFormatException: For input string ""）
  for h in $nodes; do
    local empties
    empties=$(sshx "$h" "grep -nE '^[a-z_0-9]+=\$' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | head -5" | tr '\n' ' ')
    [ -n "$empties" ] && fail "$h properties 里有空值行（会让 DN 起不来）：$empties"
    for kv in $(printf '%s' "${EXTRA_CONF:-}" | tr ',' ' '); do
      k="${kv%%=*}"; [ -n "$k" ] || continue
      local got; got=$(sshx "$h" "grep -E '^$k=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
      [ "$got" = "${kv#*=}" ] || fail "$h 配置 $k 写入不匹配: '$got' != '${kv#*=}'"
    done
  done
  log "  配置写入完成（$nodes）：schemaRF=$SCHEMA_RF dataRF=$DATA_RF consensus=$CONS_TAG 内存比例=$MB_MEM_PROPORTION"
}

cluster_start(){
  log "--- 启动集群 ---"
  local h ts rc
  ts=$(date +%s)
  for h in "${CN[@]}"; do
    log "  启动 ConfigNode $h"
    sshx "$h" "sudo rm -f /tmp/cn_${h}.start"
    timeout 60 ssh -n $SSH_OPTS "$SSH_USER@$h" \
      "source /etc/profile; sudo test -f $CN_DB_DIR/activation/license || sudo cp -p $CN_DB_DIR/../timecho_license_new $CN_DB_DIR/activation/license 2>/dev/null; sudo setsid nohup $CN_DB_DIR/sbin/start-confignode.sh -H $CN_DB_DIR/cn_${ts}_heapdump.hprof </dev/null >/tmp/cn_${h}.start 2>&1 &" \
      || fail "启动 CN $h 的命令失败"
    sleep 2
  done
  mb_wait_port_up "$CN_INTERNAL_PORT" "${CN_START_TIMEOUT:-240}" "ConfigNode" cn "${CN[@]}" || fail "ConfigNode 端口未在窗口内就绪"
  for h in "${DN[@]}"; do
    log "  启动 DataNode $h"
    # ⚠️ 先把上一次的 start 日志删掉：崩溃快速失败依赖 `grep /tmp/dn_<h>.start`，
    #    若留着旧文件，上一次的崩溃栈会被当成本次崩溃 —— 实测因此把"集群已 8/8 就绪"
    #    的用例误判成"DataNode 启动即崩溃"（MB-06 就这么被冤枉过一次）。
    sshx "$h" "sudo rm -f /tmp/dn_${h}.start"
    timeout 60 ssh -n $SSH_OPTS "$SSH_USER@$h" \
      "source /etc/profile; sudo setsid nohup $DB_DIR/sbin/start-datanode.sh -H $DB_DIR/dn_${ts}_heapdump.hprof </dev/null >/tmp/dn_${h}.start 2>&1 &" \
      || fail "启动 DN $h 的命令失败"
    sleep 2
  done
  mb_wait_port_up "$DN_RPC_PORT" "$CLUSTER_READY_TIMEOUT" "DataNode" dn "${DN[@]}" || warn "DataNode 端口未全部就绪"
  wait_cluster_ready || fail "集群未在 ${CLUSTER_READY_TIMEOUT}s 内就绪"
}

# 等一组节点的某个端口从本机可连（bash /dev/tcp），失败打印该节点 start 日志尾部
mb_wait_port_up(){
  local port=$1 win=$2 role=$3 prefix=$4; shift 4
  local hosts=("$@") h n deadline=$(( $(date +%s) + win ))
  while (( $(date +%s) < deadline )); do
    n=0
    for h in "${hosts[@]}"; do
      if (exec 3<>"/dev/tcp/$h/$port") 2>/dev/null; then exec 3<&- 3>&-; n=$((n+1)); fi
    done
    log "  ${role} 端口($port)就绪: $n/${#hosts[@]}"
    [ "$n" -ge "${#hosts[@]}" ] && return 0
    # 快速失败：某节点 start 日志里出现 main 线程异常 ⇒ 它不可能起来了，不用等满窗口
    local bad=""
    for h in "${hosts[@]}"; do
      if ssh -n $SSH_OPTS "$SSH_USER@$h" "sudo grep -qE 'Exception in thread \"main\"|Fail to start server|StartupException' /tmp/${prefix}_${h}.start 2>/dev/null" 2>/dev/null; then
        bad="$h"; break
      fi
    done
    if [ -n "$bad" ]; then
      fail "${role} $bad 启动即崩溃（不是慢，是起不来）"
      log "  --- $bad 启动输出（关键行）---"
      ssh -n $SSH_OPTS "$SSH_USER@$bad" "sudo grep -E 'Exception in thread|^\\s+at |Caused by|Fail to start|StartupException' /tmp/${prefix}_${bad}.start 2>/dev/null | head -15 | cut -c1-260" >>"$OUT" 2>&1 || true
      ssh -n $SSH_OPTS "$SSH_USER@$bad" "sudo grep -E 'Exception in thread|^\\s+at |Caused by|Fail to start' /tmp/${prefix}_${bad}.start 2>/dev/null | head -8 | cut -c1-260"
      return 1
    fi
    sleep 5
  done
  for h in "${hosts[@]}"; do
    warn "  $h 未就绪 start 输出: $(ssh -n $SSH_OPTS "$SSH_USER@$h" "sudo tail -3 /tmp/${prefix}_${h}.start 2>/dev/null" | tr '\n' ' ' | cut -c1-300)"
  done
  return 1
}

wait_cluster_ready(){
  local want=$(( ${#CN[@]} + ${#DN[@]} )) deadline=$(( $(date +%s) + CLUSTER_READY_TIMEOUT )) n=0 h
  local ts; ts=$(date +%s)
  while (( $(date +%s) < deadline )); do
    n=$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running|ReadOnly')
    log "  集群就绪: $n/$want"
    [ "$n" -ge "$want" ] && { sq 'show cluster;' >>"$OUT" 2>&1; return 0; }
    # 快速失败：任一 DN 的 start 日志里有 main 线程异常（起不来），就别白等满窗口
    for h in "${DN[@]}"; do
      if ssh -n $SSH_OPTS "$SSH_USER@$h" "sudo grep -qE 'Exception in thread .main.|Fail to start server' /tmp/dn_${h}.start 2>/dev/null" 2>/dev/null; then
        fail "DataNode $h 启动即崩溃（日志有 main 线程异常）⇒ 集群不可能就绪，提前结束等待"
        log "  --- $h 崩溃关键行 ---"
        ssh -n $SSH_OPTS "$SSH_USER@$h" "sudo grep -E 'Exception in thread|Caused by|^\s+at .*(DataNodeMemoryConfig|DevicePathCache|MemoryManager)' /tmp/dn_${h}.start 2>/dev/null | head -10 | cut -c1-240" >>"$OUT" 2>&1 || true
        ssh -n $SSH_OPTS "$SSH_USER@$h" "sudo grep -E 'Exception in thread|Caused by' /tmp/dn_${h}.start 2>/dev/null | head -4 | cut -c1-240"
        return 1
      fi
    done
    sleep 5
  done
  return 1
}

# 用例统一准备：停 -> 清 -> 写配置 -> 启动（SKIP_LIFECYCLE=1 复用已运行集群）
mb_cluster_prepare(){
  if [ "${SKIP_LIFECYCLE:-0}" = "1" ] && sq 'show cluster;' 2>/dev/null | grep -qE 'Running|ReadOnly'; then
    log "--- SKIP_LIFECYCLE=1：复用当前已运行的集群 ---"
    wait_cluster_ready || fail "集群未就绪"
    return 0
  fi
  cluster_stop
  cluster_clean
  cluster_write_conf
  cluster_start
  # 干净集群的启动事实：库列表只应有 __audit/__system
  local dbs; dbs=$(sq 'show databases;' 2>/dev/null | grep -cE '^\|.*root\.')
  log "  启动后库数量=$dbs（干净集群期望 2：__audit/__system）"
  [ "${dbs:-0}" -le 2 ] || warn "启动后库数量=$dbs，可能不是干净集群"
  sq 'show cluster;' >>"$OUT" 2>&1
}

# ---------------------------------------------------------------------------
# 指标源：Prometheus HTTP API 或直连 DN :9092/metrics
# ---------------------------------------------------------------------------
prom_healthy(){ [ -n "$PROMETHEUS_URL" ] && curl -s -o /dev/null -m 5 "$PROMETHEUS_URL/-/healthy"; }
prom_query(){ local q=$1 out
  [ -n "$PROMETHEUS_URL" ] || return 1
  out=$(curl -s -m "$PROMETHEUS_TIMEOUT" -G "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=$q" \
    ${PROMETHEUS_USER:+-u "$PROMETHEUS_USER:$PROMETHEUS_PASS"} 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}
# 输出 "instance value" 每行一条
#   ⚠️ 客户端机 172.20.70.3 **没有 python3**（实测 `python3: command not found`），
#   因此这里用 awk 解析 Prometheus 的 vector JSON，不依赖外部解释器。
#   解析只用 index()/substr()，不用正则，避免 shell / awk 两层转义踩坑。
prom_series(){ prom_query "$1" 2>/dev/null | awk '
  BEGIN { RS = "[}],[{]" }
  {
    inst = ""; val = ""
    p = index($0, "\"instance\":\"")
    if (p > 0) { r = substr($0, p + 12); inst = substr(r, 1, index(r, "\"") - 1) }
    if (inst == "") {
      p = index($0, "\"nodeId\":\"")
      if (p > 0) { r = substr($0, p + 10); inst = substr(r, 1, index(r, "\"") - 1) }
    }
    p = index($0, "\"value\":[")
    if (p > 0) {
      r = substr($0, p + 9)
      q = index(r, ",\"")
      if (q > 0) { t = substr(r, q + 2); val = substr(t, 1, index(t, "\"") - 1) }
    }
    if (val != "") print (inst == "" ? "-" : inst), val
  }'
}
prom_values(){ prom_series "$1" | awk '{print $2}'; }

sync_lag_promql(){ printf '%s' '{__name__=~"iot_consensus(_v2)?",type="syncLag",cluster="'"${PROMETHEUS_CLUSTER}"'",nodeType="DATANODE"}'; }
sync_lag_scan_prom(){ local s n bad
  s=$(prom_series "$(sync_lag_promql)") || { echo "-1 -1"; return 0; }
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
      v=${line##* }; n=$((n+1))
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
    *)      r=$(sync_lag_scan_prom); read -r n bad <<<"$r"
            if [ "${n:-0}" -gt 0 ]; then echo "$r"; else sync_lag_scan_direct; fi ;;
  esac
}

check_sync_lag(){
  local deadline=$(( $(date +%s) + SYNC_TIMEOUT_SEC )) stable=0 n bad src
  src=$SYNC_LAG_SOURCE; [ -z "$PROMETHEUS_URL" ] && src=direct
  while (( $(date +%s) < deadline )); do
    read -r n bad <<<"$(sync_lag_scan)"
    log "  syncLag series=$n nonzero=$bad （源=$src cluster=$PROMETHEUS_CLUSTER）"
    if [ "${n:-0}" -gt 0 ] && [ "${bad:-1}" -eq 0 ]; then stable=$((stable+1)); else stable=0; fi
    [ "$stable" -ge "$SYNC_STABLE_CHECKS" ] && { pass "sync lag 已归零（$n 条 series 全部为 0，连续 $SYNC_STABLE_CHECKS 次）"; return 0; }
    sleep 10
  done
  fail "sync lag 未在 ${SYNC_TIMEOUT_SEC}s 内归零 (series=$n nonzero=$bad)"
  return 1
}

# ---------------------------------------------------------------------------
# 副本一致性：全部在线取基准 -> 逐个停 1 个 DN、用剩余副本查询比对（共 5 轮）
#   ⚠️ 取基准前必须 "flush + 等逐副本可见 + 等 syncLag 归零"：
#      V2(batch 模式) 只复制已 seal 的 TsFile，未 seal 的 memtable 尾部不在 follower 上，
#      不 flush 就取基准会得到"ACK 了但副本没有"的假不一致。
# ---------------------------------------------------------------------------
CONS_BASE=""; CONS_BASE_N=0
norm_result(){
  local txt=$1 rows
  if printf '%s\n' "$txt" | grep -qiE 'IoTDBSQLException|Exception'; then
    printf '%s\n' "$txt" | grep -oiE 'Exception[^|]*' | head -1 | sed 's/^/ERROR:/'; return
  fi
  rows=$(printf '%s\n' "$txt" | table_rows | sed -E 's/[[:space:]]+/ /g')
  if [ -z "$rows" ]; then echo EMPTY; else printf '%s\n' "$rows"; fi
}
query_result(){ local out
  if [ "$2" = "table" ]; then out=$(sqt_node "$1" "$3"); else out=$(sq_node "$1" "$3"); fi
  norm_result "$out"
}
# 结果的"规模"（只作证据打印，判据是结果整体字符串相等）：
#   · 明细结果（首列是时间戳）→ 数据行数；
#   · 聚合结果（如 select count(s1) from db.**）→ 该行各数值列之和（= 总点数）。
#   两者都给一个可读数字，避免聚合结果被打印成"行数=0"这种误导。
cons_rows_n(){ local t=$1; case "$t" in EMPTY|ERROR:*) echo 0 ;; *) printf '%s\n' "$t" | awk -F'|' '
  NF>=3 && $2 ~ /^[ \t]*[0-9]{4}-[0-9]{2}-[0-9]{2}T/ { rows++ ; next }
  NF>=3 && rows==0 { for (i=2;i<NF;i++) { v=$i; gsub(/[^0-9-]/,"",v); if (v!="") agg+=v } }
  END { if (rows>0) print rows+0; else print agg+0 }' ;; esac; }

cons_prep(){
  local nodes_str=$1 sql=$2 dialect=$3 h
  log "  一致性取基准前：逐 DN flush 并等副本可见"
  for h in $nodes_str; do sq_node "$h" 'flush;' >/dev/null 2>&1; done
  sleep 3
  # 等各副本行数一致（未 seal 尾部写完后才稳定）
  local deadline=$(( $(date +%s) + CONS_VISIBLE_WAIT )) counts stable=0
  while (( $(date +%s) < deadline )); do
    counts=""
    for h in $nodes_str; do counts="$counts$(query_result "$h" "$dialect" "$sql" | cons_rows_n):"; done
    local uniq; uniq=$(printf '%s' "$counts" | tr ':' '\n' | sed '/^$/d' | sort -u | wc -l)
    [ "$uniq" -le 1 ] && stable=$((stable+1)) || stable=0
    [ "$stable" -ge 2 ] && { log "  逐副本行数一致: $counts"; break; }
    sleep 3
  done
  [ "$stable" -lt 2 ] && warn "取基准前逐副本行数未收敛（$counts），V2 下可能仍有未 seal 尾部"
  check_sync_lag || warn "取基准前 syncLag 未归零"
  CONS_BASE=$(query_result "${nodes_str%% *}" "$dialect" "$sql")
  CONS_BASE_N=$(cons_rows_n "$CONS_BASE")
  log "  基准（经 ${nodes_str%% *}）值/行数=$CONS_BASE_N"
}

cons_judge(){ local tag=$1 cur=$2 cur_n
  cur_n=$(cons_rows_n "$cur")
  if [ "$cur" = "$CONS_BASE" ]; then pass "副本一致 $tag（值/行数=$cur_n）"
  else
    local diff
    diff=$(diff <(printf '%s\n' "$CONS_BASE") <(printf '%s\n' "$cur") 2>/dev/null | head -6 | tr '\n' ' ')
    fail "副本不一致 $tag: 基准值/行数=$CONS_BASE_N 实际值/行数=$cur_n 差异=[$(printf '%s' "$diff" | cut -c1-400)]"
  fi
}

consistency_check(){
  local sql=$1 dialect=${2:-tree} h on cur nodes_str
  nodes_str="${DN[*]}"
  log "=== 副本一致性校验（${dialect}）: $sql ==="
  # ⚠️【前置门禁】必须先让复制追平，否则"停副本后数据变少"测到的是**复制未追平**，
  #   而不是"副本缺少数据"，会把用例判成假 FAIL。
  #   实测依据：RC10 在 IoTConsensusV2 下，MB-14/MB-03 报"停副本后剩 160/1200"，
  #   而同一数据在 syncLag 归零后用同样方式停副本，两个副本 TsFile 尺寸完全一致、查询均为 1200。
  #   V2(batch) 只复制已 seal 的 TsFile，flush 之后仍需等 pipe 把 TsFile 送到 follower。
  sq 'flush;' >/dev/null 2>&1
  if ! check_sync_lag; then
    warn "syncLag 未在 ${SYNC_TIMEOUT_SEC}s 内归零：复制尚未追平，跳过停副本比对（此时比对无法区分'未追平'与'副本缺数据'）"
    return 1
  fi
  cons_prep "$nodes_str" "$sql" "$dialect"
  for h in "${DN[@]}"; do
    [ "$h" = "${DN[0]}" ] && continue
    cur=$(query_result "$h" "$dialect" "$sql")
    cons_judge "全部在线: $h" "$cur"
  done
  local round=0
  for h in "${DN[@]}"; do
    round=$((round+1))
    log "  --- 停 DataNode $h（第 ${round}/${#DN[@]} 轮）---"
    sshx "$h" "sudo $DB_DIR/sbin/stop-datanode.sh >/dev/null 2>&1 || true; sudo pkill -9 -f 'com\.timecho\.iotdb\.DataNode' >/dev/null 2>&1 || true"
    wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "停 $h 后集群仍显示 Running"
    for on in "${DN[@]}"; do
      [ "$on" = "$h" ] && continue
      cur=$(query_result "$on" "$dialect" "$sql")
      cons_judge "停 $h 时经 $on 查询" "$cur"
    done
    sshx "$h" "source /etc/profile; nohup sudo $DB_DIR/sbin/start-datanode.sh >/dev/null 2>&1 &"
    wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || fail "DataNode $h 未恢复 Running"
  done
  wait_cluster_ready || warn "一致性校验后集群未完全就绪"
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
# CN/DN 异常日志分析
#   判据：ERROR/WARN 中出现"不该出现的异常"——空指针、数组越界、运行时异常等。
#   已知正常日志与用例故意触发的日志用 BENIGN 正则排除（用例可追加 MB_LOG_BENIGN_EXTRA）。
# ---------------------------------------------------------------------------
COMMON_ERR_PAT='NullPointerException|OutOfMemoryError|Java heap space|GC overhead limit exceeded|ArrayIndexOutOfBoundsException|IndexOutOfBoundsException|NegativeArraySizeException|ClassCastException|ConcurrentModificationException|IllegalStateException|UnsupportedOperationException|BufferUnderflowException|BufferOverflowException|NumberFormatException|StringIndexOutOfBoundsException|ArithmeticException|StackOverflowError|has overlapped data|is not in tsFileMetaData'
MB_ERR_PAT='Failed to flush|flush .*failed|MemTable.*(error|Error|failed)|reject status.*error|Failed to allocate memory|memory block.*(negative|over)'
BENIGN_PAT='Not TTL rule set|read-only|Read-only file system|EROFS|Rejecting inserting|Change system to reject status|still in reject status|too large, call for flushing|released memory|Set system mode|Only query statements are permitted|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|ConnectException|Connection refused|SocketException|Broken pipe|Node .* is not in the cluster|UnknownNodeException'
MB_LOG_BENIGN_EXTRA="${MB_LOG_BENIGN_EXTRA:-}"
check_logs(){
  local extra=${1:-} benpat="$BENIGN_PAT" pat h files n1 n2 benign role nodes summary
  [ -n "${MB_LOG_BENIGN_EXTRA:-}" ] && benpat="$benpat|$MB_LOG_BENIGN_EXTRA"
  pat="$COMMON_ERR_PAT|$MB_ERR_PAT${extra:+|$extra}"
  log "=== CN/DN 日志异常分析（ERROR/WARN）==="
  for role in confignode datanode; do
    if [ "$role" = confignode ]; then nodes=("${CN[@]}"); else nodes=("${DN[@]}"); fi
    for h in "${nodes[@]}"; do
      files=$(sshx "$h" "ls $DB_DIR/logs/*${role}*all*.log $DB_DIR/logs/*${role}*error*.log 2>/dev/null" | tr '\n' ' ')
      [ -z "$files" ] && { warn "$role $h 无日志文件"; continue; }
      benign=$(sshx "$h" "grep -hcE '$benpat' $files 2>/dev/null | awk '{s+=\$1} END{print s+0}'" | tr -dc '0-9')
      n1=$(sshx "$h" "grep -hE '^[0-9]{4}-[0-9]{2}-[0-9]{2}.*(ERROR|WARN).*($pat)' $files 2>/dev/null | grep -vcE '$benpat'" | tr -dc '0-9')
      if [ "${n1:-0}" -gt 0 ]; then
        fail "$role $h 日志出现 ${n1:-0} 条异常（ERROR/WARN 命中异常栈特征）"
        sshx "$h" "grep -nE '^[0-9]{4}-[0-9]{2}-[0-9]{2}.*(ERROR|WARN).*($pat)' $files 2>/dev/null | grep -vE '$benpat' | head -20 | cut -c1-240" >>"$OUT" 2>&1
      else
        pass "$role $h 日志无异常（已忽略 ${benign:-0} 条已知正常/预期日志）"
      fi
    done
  done
  # 正证据：本用例关心的"内存缓冲区行为"证据行（由 mb_positive_evidence 打印）
  local evfn="${MB_POSITIVE_EVIDENCE_FN:-}"
  if [ -n "$evfn" ] && declare -F "$evfn" >/dev/null 2>&1; then "$evfn"; fi
}

backup_logs(){
  [ "${LOG_BACKUP:-1}" -eq 1 ] || { log "LOG_BACKUP=0，跳过日志备份"; return 0; }
  local dst="$ART/logs" h
  log "=== 备份 CN/DN 日志到 $dst ==="
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    if timeout 900 ssh -n $SSH_OPTS "$SSH_USER@$h" "tar czf - -C '$DB_DIR' logs" >"$dst/$h.logs.tgz" 2>/dev/null; then
      log "  backup $h -> $h.logs.tgz ($(du -h "$dst/$h.logs.tgz" 2>/dev/null | cut -f1))"
    else warn "backup $h 失败"; fi
  done
}

write_result(){
  local r="FAIL" elapsed=$(( $(date +%s) - start_epoch )) csv msg
  [ "$fail_flag" -eq 0 ] && r="PASS"
  log "RESULT $r fail_flag=$fail_flag case=$CASE consensus=$CONS_TAG build=$BUILD_TAG elapsed=${elapsed}s"
  log "v_warnMessage=${v_warnMessage:-<empty>}"
  printf 'run_id=%s\ncase=%s\nbuild=%s\nconsensus=%s\nresult=%s\nfail_flag=%s\nelapsed_seconds=%s\nartifact=%s\nv_warnMessage=%s\n' \
    "$RUN_ID" "$CASE" "$BUILD_TAG" "$CONS_TAG" "$r" "$fail_flag" "$elapsed" "$ART" "${v_warnMessage:-}" \
    >"$OUTDIR/result_${CASE}_${RUN_ID}.txt"
  csv="$OUTDIR/test_result.csv"
  [ -f "$csv" ] || echo 'Time,build,consensus,caseName,result,elapsedSeconds,failCount,artifact,message' >>"$csv"
  msg=$(printf '%s' "${v_warnMessage:-}" | tr '\n\r' '  ' | tr -s ' ' | tr ',' ';' | tr -d "'" | cut -c1-1200)
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date --iso-8601=seconds)" "$BUILD_TAG" "$CONS_TAG" "$CASE.sh" "$r" "$elapsed" "$fail_flag" "$ART" "'$msg'" >>"$csv"
  log "结果已追加到 $csv"
}

# 收尾三件套（顺序固定：sync lag → 副本一致性 → 日志）
post_checks(){
  local sql=$1 dialect=${2:-tree}
  log "--- 收尾 1/3：sync lag 归零 ---"
  check_sync_lag || true
  if [ -n "$sql" ]; then
    log "--- 收尾 2/3：副本一致性（逐个停 ${#DN[@]} 个 DN）---"
    consistency_check "$sql" "$dialect"
  fi
  log "--- 收尾 3/3：CN/DN 日志异常分析 ---"
  check_logs
}

mb_case_finish(){
  local sql=${1:-} dialect=${2:-tree}
  # 【重要】先把"当前结论"落盘：本环境长跑用例有概率在收尾阶段被 SIGKILL，
  # 若只等全部收尾完再写 result 文件，被杀时这条用例就等于"没有结果"（实测多次）。
  # 先写一份 interim 结论，收尾跑完再覆盖成最终结论。
  log "--- 先落盘 interim 结论（防止收尾阶段被中断导致无结果）---"
  write_result
  post_checks "$sql" "$dialect"
  if [ "$fail_flag" -gt 0 ]; then backup_logs; else log "用例通过，不备份日志"; fi
  [ "${KEEP_DATA:-0}" = "1" ] || cluster_stop
  write_result
}
