#!/bin/bash
# ============================================================================
# 元数据 DDL 自动化测试 skill —— 公共库
#
#   source 本文件后即可使用：
#     环境加载 / 集群生命周期 / SQL 会话（树模型 + 表模型）/ 断言 /
#     元数据快照与比对 / 错误码捕获 / sync lag + 副本一致性 + CN-DN 日志分析 / 结果记录
#
#   设计要点（面向"元数据"这个测试目标）：
#     1) 元数据用例的判据几乎都是"SHOW/information_schema 的输出集合"，
#        所以核心工具是 md_digest（把查询结果归一化成**排序后的行集合**），
#        断言 = 集合相等 / 包含 / 不包含 / 行数。
#     2) 重启后元数据必须一致 —— md_snapshot_* + cluster_stop/start + 再比 digest。
#     3) DDL 的"失败路径"同样重要：捕获错误码与错误消息（assert_error）。
# ============================================================================

MD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MD_SKILL_DIR="$(cd "$MD_LIB_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# 环境加载
# ---------------------------------------------------------------------------
md_load_env(){
  local env_file="${1:-$MD_SKILL_DIR/conf/env.conf}"
  [ -f "$env_file" ] && . "$env_file"
  DB_DIR="$DB_PARENT_DIR/$V_TESTDB"
  CN_DB_DIR="$CN_DB_PARENT_DIR/$V_TESTDB"
  CLI_DIR="$SHELL_CLIENT_DIR/$V_TESTDB"
  CLI="$CLI_DIR/sbin/start-cli.sh"
  read -ra CN <<<"$CN_NODES"
  read -ra DN <<<"$DN_NODES"
  QDN="${DN[0]}"
  CONSENSUS_CLASS="$(md_consensus_class "$DATA_CONSENSUS")"
  # 用例脚本普遍 `set -u`，这里给可选变量兜默认值，避免 unbound
  EXTRA_CONF="${EXTRA_CONF:-}"
  KEEP_DATA="${KEEP_DATA:-0}"
  SKIP_LIFECYCLE="${SKIP_LIFECYCLE:-0}"
  MD_ENV_FILE="${MD_ENV_FILE:-}"
  export DB_DIR CN_DB_DIR CLI_DIR CLI QDN CONSENSUS_CLASS EXTRA_CONF KEEP_DATA SKIP_LIFECYCLE
}

md_consensus_class(){
  case "$1" in
    *IoTConsensusV2) echo "org.apache.iotdb.consensus.iot.IoTConsensusV2" ;;
    *)               echo "org.apache.iotdb.consensus.iot.IoTConsensus" ;;
  esac
}

md_parse_args(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --consensus) DATA_CONSENSUS="$2"; shift 2 ;;
      --framework) USE_FRAMEWORK="$2";  shift 2 ;;
      --env)       MD_ENV_FILE="$2";    shift 2 ;;
      --keep-data) KEEP_DATA=1;         shift   ;;
      --skip-lifecycle) SKIP_LIFECYCLE=1; shift ;;
      *) echo "未知参数: $1" >&2; shift ;;
    esac
  done
  [ -n "${MD_ENV_FILE:-}" ] && . "$MD_ENV_FILE"
  CONSENSUS_CLASS="$(md_consensus_class "$DATA_CONSENSUS")"
}

# ---------------------------------------------------------------------------
# 用例脚手架
# ---------------------------------------------------------------------------
md_case_init(){
  CASE="$1"
  RUN_ID="$(date +%Y%m%d_%H%M%S)"
  OUTDIR="$MD_SKILL_DIR/results"
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

# OUT 可能为空（工具脚本/临时脚本 source 本库但没走 md_case_init），此时只打屏不写文件
log(){  local m="[$(date '+%F %T')] $*"; [ -n "${OUT:-}" ] && printf '%s\n' "$m" >>"$OUT"; printf '%s\n' "$m"; }
note(){ v_warnMessage="${v_warnMessage}$*"; }
warn(){ note "$*"; log "WARN $*"; }
fail(){ fail_flag=$((fail_flag+1)); note "$*"; log "FAIL $*"; }
pass(){ log "PASS $*"; }

assert_eq(){ local label=$1 got=$2 want=$3; if [ "$got" = "$want" ]; then pass "$label: $got"; else fail "$label: 实际=[$got] 期望=[$want]"; fi; }
assert_ne(){ local label=$1 got=$2 bad=$3; if [ "$got" != "$bad" ]; then pass "$label: $got（≠ $bad）"; else fail "$label: 实际=[$got] 不应等于 [$bad]"; fi; }
assert_contains(){ local label=$1 out=$2 pat=$3; if printf '%s\n' "$out" | grep -qE "$pat"; then pass "$label: 命中 /$pat/"; else fail "$label: 未命中 /$pat/: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; fi; }
assert_not_contains(){ local label=$1 out=$2 pat=$3; if printf '%s\n' "$out" | grep -qE "$pat"; then fail "$label: 不应出现 /$pat/：$(printf '%s' "$out" | grep -E "$pat" | head -3 | tr '\n' ' ')"; else pass "$label: 未出现 /$pat/"; fi; }
assert_ge(){ local label=$1 got=$2 want=$3; if [ "${got:-0}" -ge "$want" ] 2>/dev/null; then pass "$label: $got ≥ $want"; else fail "$label: 实际=[$got] 期望 ≥ [$want]"; fi; }

# ---------------------------------------------------------------------------
# SQL 会话
# ---------------------------------------------------------------------------
sshx(){ local h=$1; shift; ssh -n $SSH_OPTS "$SSH_USER@$h" "$@"; }
now_ms(){ date +%s%3N; }
sleep_s(){ sleep "$1"; }
# 去掉 CLI 提示回显（TimechoDB> / TimechoDB:db> / IoTDB> 等）与纯分隔行
strip_echo(){ grep -vE '^[[:alnum:]_:]*DB>([[:space:]]|$)' | grep -vE '^[-+]+$'; }
# 取结果表的**数据行**（去掉表头与分隔行）。
# 注意：CLI 在结果超过一批（实测 1000 行/批）时会**重复打印表头**，
#   所以不能只去掉第一行表头。这里先记住"第一个 | 行"（表头原文），
#   再把所有与它逐字相同的行都丢掉 —— 实测两批的表头是逐字一样的。
#   （规模用例就是靠这一点发现问题的：2000 行结果里 2002 个 | 行 = 2 个表头 + 2000 行数据）
table_rows(){
  awk '{ line[NR]=$0 }
    END{
      hdr=""
      for (i=1;i<=NR;i++) if (line[i] ~ /^\|/) { hdr=line[i]; break }
      for (i=1;i<=NR;i++) {
        l=line[i]
        if (l !~ /^\|/) continue                 # 非表格行
        if (l ~ /^\|[-+ ]+\|$/) continue         # |---|---| 形式的分隔行
        if (hdr != "" && l == hdr) continue      # 表头（可能重复出现）
        print l
      }
    }'
}

sq(){        timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 -e "$1" 2>&1; }
# 以指定用户身份执行（权限用例要验证"授了权限真的能用 / 没授就报 803"）
sq_as(){     timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$1" -pw "$2" -timeout 3600 -e "$3" 2>&1; }
sqt_as(){    timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$1" -pw "$2" -sql_dialect table -timeout 3600 -e "$3" 2>&1; }
sq_node(){   timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$1"   -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 -e "$2" 2>&1; }
sqt(){       timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 3600 -e "$1" 2>&1; }
sqt_node(){  timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$1"   -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 3600 -e "$2" 2>&1; }

# 同一 CLI 会话里按顺序执行多条语句（保证 use <db> 生效）
session_tree(){  timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 2>&1; }
session_table(){ timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 3600 2>&1; }
sql_lines_tree(){  printf '%s\n' "$@" | session_tree; }
sql_lines_table(){ printf '%s\n' "$@" | session_table; }
# 多语句会话（同一连接）：SQL 里用 ';;' 分隔语句，例如 "USE db;;SHOW TABLES;"
sql_multi(){ local d=$1 s=$2 h=${3:-$QDN} nl
  nl=$(printf '%s' "$s" | sed 's/;;/\n/g')
  if [ "$d" = table ]; then
    printf '%s\n' "$nl" | timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$h" -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 3600 2>&1
  else
    printf '%s\n' "$nl" | timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$h" -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 2>&1
  fi
}

# sql_on <node> <dialect> <sql>
#   dialect: tree | table | tsess（树模型多语句会话） | tblsess（表模型多语句会话）
sql_on(){ local h=$1 d=$2 s=$3
  case "$d" in
    table)   sqt_node "$h" "$s" ;;
    tsess)   sql_multi tree  "$s" "$h" ;;
    tblsess) sql_multi table "$s" "$h" ;;
    *)       sq_node "$h" "$s" ;;
  esac
}

# 查询返回的单个标量（count(*) 等表格第一行第一列）
scalar(){ printf '%s\n' "$1" | table_rows | head -1 | awk -F'|' '{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }
# 表格第一行的最后一列（CLI 表格行以 '|' 结尾，故取 NF-1）
md_last_col(){ table_rows | head -1 | awk -F'|' '{v=$(NF-1); gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }
# 表格第 n 列（1 基，不含行首空字段）
md_col(){ local n=$1; table_rows | awk -F'|' -v n="$n" '{v=$(n+1); gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }

# ---------------------------------------------------------------------------
# 元数据判据工具（本 skill 的核心）
# ---------------------------------------------------------------------------
# 把一条元数据查询的输出归一化成"排序后的行集合"（去表头、压缩空白、去空行）
md_rows(){ printf '%s\n' "$1" | table_rows | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | sed '/^$/d' | LC_ALL=C sort; }
# md_digest <dialect> <sql> [node]  —— 直接查询并归一化
md_digest(){ local d=$1 s=$2 h=${3:-$QDN}; md_rows "$(sql_on "$h" "$d" "$s")"; }
# 行数（集合大小，重复行会去重）
md_count(){ printf '%s\n' "$1" | sed '/^$/d' | wc -l | tr -d ' '; }
# 从 SHOW ... 结果里按第 1 列（路径/名字）取集合
md_names(){ printf '%s\n' "$1" | table_rows | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); if ($2!="") print $2}' | LC_ALL=C sort -u; }
# 取第 n 列的去重集合（列号 1 基，不含行首空字段）
md_names_of(){ local n=$1; printf '%s\n' "$2" | table_rows | awk -F'|' -v n="$n" '{v=$(n+1); gsub(/^[ \t]+|[ \t]+$/,"",v); if (v!="") print v}' | LC_ALL=C sort -u; }

# 断言两个集合相等（标签、实际、期望）—— 两侧都先排序去空行，忽略顺序
assert_set_eq(){ local label=$1 got want
  got=$(printf '%s\n' "$2" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort)
  want=$(printf '%s\n' "$3" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort)
  if [ "$got" = "$want" ]; then pass "$label: 集合一致（$(md_count "$got") 行）"
  else fail "$label: 集合不一致
---- 实际 ----$(printf '\n%s' "$got")
---- 期望 ----$(printf '\n%s' "$want")"; fi
}
# 断言集合包含 / 不包含某个精确元素
assert_set_has(){ local label=$1 set=$2 item=$3
  if printf '%s\n' "$set" | grep -qxF "$item"; then pass "$label: 含 $item"; else fail "$label: 缺 $item"; fi
}
assert_set_lacks(){ local label=$1 set=$2 item=$3
  if printf '%s\n' "$set" | grep -qxF "$item"; then fail "$label: 不应含 $item"; else pass "$label: 不含 $item"; fi
}

# 错误断言：捕获 DDL 失败时的错误码与消息
#   注意：CLI 对**成功**的 DDL 也会打印 `Msg: The statement is executed successfully.`，
#   所以不能见到 `Msg:` 就当报错（踩过：整份探测结果被误判为 ERR）。
is_error(){
  # 表格行（`| ... |`）里的内容不算错误信息——SHOW PIPES 的结果表里就带 Exception 字样，
  # 曾因此把它误判为报错。
  printf '%s\n' "$1" | grep -vE '^\|' | grep -qE 'IoTDBSQLException|Exception|^Error:|ERROR' && return 0
  if printf '%s\n' "$1" | grep -qE '^Msg:'; then
    printf '%s\n' "$1" | grep -qE '^Msg: The statement is executed successfully\.$' || return 0
  fi
  return 1
}
# 错误码：优先 IoTDBSQLException: NNN，其次 `Msg: NNN:` / `Error: NNN:`
err_code(){
  local o=$1 c
  c=$(printf '%s\n' "$o" | grep -oE 'IoTDBSQLException: [0-9]+' | grep -oE '[0-9]+' | head -1)
  [ -z "$c" ] && c=$(printf '%s\n' "$o" | grep -oE '^(Msg|Error): [0-9]+' | grep -oE '[0-9]+' | head -1)
  printf '%s' "$c"
}
# 错误首行（用于断言消息文本）
err_msg(){
  printf '%s\n' "$1" | grep -E '^(Msg|Error):' | head -1 | sed -E 's/[[:space:]]+/ /g' | cut -c1-300
}
assert_error(){ local label=$1 out=$2 pat=${3:-}
  if ! is_error "$out"; then fail "$label: 期望报错，但执行成功: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; return; fi
  local code; code=$(err_code "$out")
  if [ -z "$pat" ]; then pass "$label: 如期报错（code=${code:-?}）"
  elif printf '%s\n' "$out" | grep -qE "$pat"; then pass "$label: 如期报错且命中 /$pat/（code=${code:-?}）"
  else fail "$label: 报错了但未命中 /$pat/（code=${code:-?}）: $(printf '%s' "$out" | grep -oE 'Msg:[^|]*' | head -1 | cut -c1-200)"; fi
}
assert_ok(){ local label=$1 out=$2
  if is_error "$out"; then fail "$label: 期望成功但报错: $(printf '%s' "$out" | grep -oE 'Msg:[^|]*' | head -1 | cut -c1-200)"
  else pass "$label: 成功"; fi
}

# 元数据快照：把一组查询的结果拼成一个可比较的字符串（含查询名，便于 diff）
#   md_snapshot <dialect> "名字1::SQL1" "名字2::SQL2" ...
md_snapshot(){ local d=$1 spec name sql out=""
  shift
  for spec in "$@"; do
    name="${spec%%::*}"; sql="${spec#*::}"
    out="$out### $name
$(md_digest "$d" "$sql")
"
  done
  printf '%s' "$out"
}
# 比较两份快照：一致则 pass，否则 fail 并打印 diff
assert_snapshot_eq(){ local label=$1 a=$2 b=$3
  if [ "$a" = "$b" ]; then pass "$label: 快照一致（$(printf '%s' "$a" | grep -c '^### ') 组查询）"
  else fail "$label: 快照不一致"; printf '%s\n' "$(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -30)" >>"$OUT"; fi
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
  fi
  sleep 3
}
cluster_clean(){
  log "--- 清理 data/logs 并还原 conf_orig ---"
  if [ "$USE_FRAMEWORK" = "1" ] && [ -f "$FRAMEWORK_DIR/clean_env/clean_cluster.sh" ]; then
    bash "$FRAMEWORK_DIR/clean_env/clean_cluster.sh" >>"$OUT" 2>&1 || warn "clean_cluster.sh 非 0"
    bash "$FRAMEWORK_DIR/clean_env/reset_conf.sh"    >>"$OUT" 2>&1 || warn "reset_conf.sh 非 0"
  else
    local h
    for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
      sshx "$h" "rm -rf $DB_DIR/data $DB_DIR/logs; if [ -d $DB_DIR/conf_orig ]; then rm -rf $DB_DIR/conf; cp -rp $DB_DIR/conf_orig $DB_DIR/conf; fi" || warn "清理 $h 失败"
    done
  fi
}
# 单节点写配置：先删掉该键所有行，再追加一次（保证只有一个有效值）
#   必须用 `ssh "DB='...' bash -s" <<REMOTE`：sshx 带 -n 会吞掉 heredoc。
cluster_set_conf(){
  local h=$1
  ssh $SSH_OPTS "$SSH_USER@$h" "DB='$DB_DIR' bash -s" <<REMOTE || fail "写配置失败: $h"
set -e
P="\$DB/conf/iotdb-system.properties"
[ -f "\$P" ] || { echo "missing \$P"; exit 1; }
set_prop(){ k="\$1"; v="\$2"
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
REMOTE
  # 用例自定的追加键值：EXTRA_CONF="k1=v1,k2=v2"
  local kv k v
  for kv in $(printf '%s' "${EXTRA_CONF:-}" | tr ',' ' '); do
    k="${kv%%=*}"; v="${kv#*=}"
    [ -n "$k" ] || continue
    sshx "$h" "P=$DB_DIR/conf/iotdb-system.properties; sed -i -E '/^[#[:space:]]*${k}[[:space:]]*=/d' \"\$P\"; printf '%s=%s\\n' '$k' '$v' >> \"\$P\"" \
      || fail "写扩展配置失败: $h $k=$v"
  done
}
# 写集群参数（IP/副本数/共识协议 + EXTRA_CONF="k1=v1,k2=v2"），逐节点回读校验
cluster_write_conf(){
  local h kv k want v all
  log "--- 写集群配置（rf=$SCHEMA_RF/$DATA_RF consensus=$CONSENSUS_CLASS${EXTRA_CONF:+ extra=$EXTRA_CONF}）---"
  all=$(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u)
  for h in $all; do cluster_set_conf "$h"; done
  for h in $all; do
    for kv in schema_replication_factor=$SCHEMA_RF data_replication_factor=$DATA_RF data_region_consensus_protocol_class=$CONSENSUS_CLASS; do
      k="${kv%%=*}"; want="${kv#*=}"
      v=$(sshx "$h" "grep -E '^$k=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
      [ "$v" = "$want" ] || fail "$h $k 写入不匹配: '$v' != '$want'"
    done
    v=$(sshx "$h" "grep -E '^cn_seed_config_node=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-; grep -E '^dn_seed_config_node=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r' | tr '\n' ' ')
    case "$v" in *"${CN[0]}:$CN_INTERNAL_PORT"*) ;; *) fail "$h seed_config_node 写入不匹配: '$v'";; esac
    for kv in $(printf '%s' "${EXTRA_CONF:-}" | tr ',' ' '); do
      k="${kv%%=*}"; want="${kv#*=}"; [ -n "$k" ] || continue
      v=$(sshx "$h" "grep -E '^$k=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
      [ "$v" = "$want" ] || fail "$h $k 写入不匹配: '$v' != '$want'"
    done
  done
  local keys="cluster_name|schema_replication_factor|data_replication_factor|data_region_consensus_protocol_class|cn_seed_config_node|dn_seed_config_node"
  for kv in $(printf '%s' "${EXTRA_CONF:-}" | tr ',' ' '); do [ -n "$kv" ] && keys="$keys|${kv%%=*}"; done
  log "  配置确认(${CN[0]}): $(sshx "${CN[0]}" "grep -E '^($keys)=' $DB_DIR/conf/iotdb-system.properties | tail -20" | tr '\n' ' ')"
}

# 拉起单个节点的角色（CN/DN）。用 setsid 脱离会话，避免 ssh 断开把进程带走。
start_role(){
  local role=$1 h=$2 dir script
  if [ "$role" = cn ]; then dir="$CN_DB_DIR"; script="$dir/sbin/start-confignode.sh"
  else                     dir="$DB_DIR";    script="$dir/sbin/start-datanode.sh"; fi
  ssh $SSH_OPTS "$SSH_USER@$h" "source /etc/profile; setsid nohup sudo $script >$dir/start_${role}_md.log 2>&1 < /dev/null & sleep 2" >/dev/null 2>&1 \
    || warn "启动 $role $h 失败"
}
role_proc_cnt(){ sshx "$1" "pgrep -fc com.timecho.iotdb.${2}" 2>/dev/null | tr -dc '0-9'; }
# 硬清残留 JVM：Raft 存储目录有文件锁，上一个进程没退干净时新进程会
#   OverlappingFileLockException 直接启动失败（本环境踩到过，集群起不来）。
kill_stale_nodes(){
  local h n
  log "  --- 清理残留 JVM（避免 Raft 文件锁冲突） ---"
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    n=$(sshx "$h" "pgrep -fc 'com.timecho.iotdb.(ConfigNode|DataNode)'" 2>/dev/null | tr -dc '0-9')
    if [ "${n:-0}" -gt 0 ]; then
      log "    $h 仍有 $n 个残留进程，强制结束"
      sshx "$h" "pkill -9 -f 'com.timecho.iotdb.ConfigNode'; pkill -9 -f 'com.timecho.iotdb.DataNode'; sleep 2" >/dev/null 2>&1
    fi
  done
  sleep 2
}
# CN 可连通：CLI 连的是 DataNode 的 RPC 端口，DN 没起时 `show cluster` 一定是
#   Connection Error —— 所以不能用它判断 CN 是否就绪，要看 CN 内部端口是否在监听。
wait_cn_port(){
  local secs=${1:-${CN_READY_TIMEOUT:-180}}
  local deadline=$(( $(date +%s) + secs )) h up n
  while (( $(date +%s) < deadline )); do
    up=0
    for h in "${CN[@]}"; do
      n=$(sshx "$h" "ss -lnt 2>/dev/null | grep -c ':$CN_INTERNAL_PORT '" 2>/dev/null | tr -dc '0-9')
      [ "${n:-0}" -ge 1 ] && up=$((up+1))
    done
    if [ "$up" -ge "${#CN[@]}" ]; then log "  ConfigNode 端口已监听（$up/${#CN[@]}）"; return 0; fi
    sleep 5
  done
  log "  ConfigNode 端口等待超时（$up/${#CN[@]}）"
  return 1
}
# 兼容旧名：等 CN 端口（不再依赖 CLI）
wait_cn_visible(){ wait_cn_port "$@"; }
# 有界等待：最多等 secs 秒；够 want 个 Running/ReadOnly 就返回 0
wait_cluster_ready(){
  local secs=${1:-$CLUSTER_READY_TIMEOUT}
  local want=$(( ${#CN[@]} + ${#DN[@]} ))
  local deadline=$(( $(date +%s) + secs )) n=0
  while (( $(date +%s) < deadline )); do
    n=$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running|ReadOnly')
    [ "$n" -ge "$want" ] && { log "  集群就绪: $n/$want"; sq 'show cluster;' >>"$OUT" 2>&1; return 0; }
    sleep 5
  done
  log "  集群就绪超时: ${n:-0}/$want"
  return 1
}
# 拉起进程已消失的节点（激活窗口内注册被拒的 DN 会直接退出，需要补起）
restart_missing_nodes(){
  local h
  for h in "${CN[@]}"; do [ "$(role_proc_cnt "$h" ConfigNode)" -lt 1 ] && { warn "CN $h 进程不在，重新拉起"; start_role cn "$h"; }; done
  for h in "${DN[@]}"; do [ "$(role_proc_cnt "$h" DataNode)"   -lt 1 ] && { warn "DN $h 进程不在，重新拉起"; start_role dn "$h"; }; done
}
# 启动顺序：清残留 -> CN 全起 -> 等可连通 -> 等激活落定 -> DN 全起 -> 有界轮询（每轮补起缺失进程）
# 背景：
#   1) clean 掉 data 后集群要重新激活，DN 若在"未激活"窗口内注册会被拒
#      （Deny DataNode registration: Cluster is unactivated now）→ DN 进程直接退出；
#   2) 上一个 JVM 没退干净会占着 Raft 存储锁 → 新进程 OverlappingFileLockException。
cluster_start(){
  log "--- 启动集群（清残留 -> CN -> 激活等待 -> DN -> 有界补起）---"
  local h attempt
  if [ "$USE_FRAMEWORK" = "1" ]; then
    cp -f "$FRAMEWORK_CN_LIST" "$FRAMEWORK_DIR/conf/confignode.txt" 2>/dev/null || true
    cp -f "$FRAMEWORK_DN_LIST" "$FRAMEWORK_DIR/conf/datanode.txt"   2>/dev/null || true
  fi
  kill_stale_nodes
  for h in "${CN[@]}"; do start_role cn "$h"; done
  if wait_cn_visible "${CN_READY_TIMEOUT:-300}"; then
    sleep "${MD_ACTIVATION_SETTLE_SEC:-20}"
  else
    warn "ConfigNode 在 ${CN_READY_TIMEOUT:-300}s 内未可连通，仍尝试拉起 DN"
  fi
  for h in "${DN[@]}"; do start_role dn "$h"; done
  for attempt in 1 2 3 4 5 6; do
    wait_cluster_ready 90 && return 0
    warn "第 $attempt 轮未全部 Running，补起缺失进程后重试"
    restart_missing_nodes
    sleep 15
  done
  fail "集群未在限定时间内就绪"
  return 1
}
# 用例统一的集群准备：停 -> 清 -> 写配置 -> 启动（SKIP_LIFECYCLE=1 且集群在跑时复用）
md_cluster_prepare(){
  if [ "${SKIP_LIFECYCLE:-0}" = "1" ] && sq 'show cluster;' 2>/dev/null | grep -qE 'Running|ReadOnly'; then
    log "--- SKIP_LIFECYCLE=1：复用当前已运行的集群 ---"
    wait_cluster_ready || fail "集群未就绪"
    md_log_mark
    return 0
  fi
  cluster_stop
  cluster_clean
  cluster_write_conf
  cluster_start
  md_log_mark
}

# ---------------------------------------------------------------------------
# 用例环境清理助手（用例开头统一调用，容忍"本来就不存在"）
# ---------------------------------------------------------------------------
q_tree(){  sql_on "$QDN" tree  "$1" >/dev/null 2>&1; return 0; }
q_table(){ sql_on "$QDN" table "$1" >/dev/null 2>&1; return 0; }
# 树模型删库：先卸模板、再删库（有模板/时序时直接删库会失败）
drop_tree_db(){
  local db=$1
  q_tree "UNSET SCHEMA TEMPLATE tpl_md FROM $db"
  q_tree "DROP DATABASE $db"
}
drop_tree_dbs(){ local d; for d in "$@"; do drop_tree_db "$d"; done; }
drop_templates(){ local t; for t in "$@"; do q_tree "DROP SCHEMA TEMPLATE $t"; done; }
drop_table_dbs(){ local d; for d in "$@"; do q_table "DROP DATABASE IF EXISTS $d"; done; }
# 断言某集合恰好等于给定的若干元素（元素写在同一行的空格分隔列表里）
assert_set_is(){ local label=$1 set=$2 want; shift 2
  want=$(printf '%s\n' "$@" | LC_ALL=C sort)
  assert_set_eq "$label" "$set" "$want"
}

# ---------------------------------------------------------------------------
# 收尾检查 1：sync lag 归零
# ---------------------------------------------------------------------------
sync_lag_scan(){
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
check_sync_lag(){
  local deadline=$(( $(date +%s) + SYNC_TIMEOUT_SEC )) stable=0 n bad
  while (( $(date +%s) < deadline )); do
    read -r n bad <<<"$(sync_lag_scan)"
    log "  syncLag series=$n nonzero=$bad"
    if [ "${n:-0}" -gt 0 ] && [ "${bad:-1}" -eq 0 ]; then stable=$((stable+1)); else stable=0; fi
    [ "$stable" -ge "$SYNC_STABLE_CHECKS" ] && { pass "sync lag 已归零（各数据区域 series 均为 0）"; return 0; }
    sleep 10
  done
  fail "sync lag 未在 ${SYNC_TIMEOUT_SEC}s 内归零 (series=$n nonzero=$bad)"
  return 1
}

# ---------------------------------------------------------------------------
# 收尾检查 2：副本一致性（默认用一条元数据查询；<SQL> 为空则跳过）
#   做法：全部在线时各副本各查一次比基准；再逐个停 DN，用剩余副本查，仍要与基准一致
# ---------------------------------------------------------------------------
norm_result(){
  local txt=$1 rows
  if printf '%s\n' "$txt" | grep -qiE 'IoTDBSQLException|Exception'; then
    printf '%s\n' "$txt" | grep -oiE 'Exception[^|]*' | head -1 | sed 's/^/ERROR:/'; return
  fi
  rows=$(printf '%s\n' "$txt" | table_rows | sed -E 's/[[:space:]]+/ /g')
  if [ -z "$rows" ]; then echo EMPTY; else printf '%s\n' "$rows"; fi
}
query_result(){ norm_result "$(sql_on "$1" "$2" "$3")"; }
consistency_check(){
  local sql=$1 dialect=${2:-tree} h on cur base
  [ -z "$sql" ] && { log "=== 副本一致性校验：本次未提供 SQL，跳过 ==="; return 0; }
  log "=== 副本一致性校验（${dialect}）: $sql ==="
  base=$(query_result "${DN[0]}" "$dialect" "$sql")
  log "  基准(经 ${DN[0]}): [$(printf '%s' "$base" | tr '\n' ' ' | cut -c1-160)]"
  for h in "${DN[@]}"; do
    [ "$h" = "${DN[0]}" ] && continue
    cur=$(query_result "$h" "$dialect" "$sql")
    [ "$cur" = "$base" ] && pass "全部在线: $h 与基准一致" || fail "全部在线副本不一致: $h=[$(printf '%s' "$cur" | tr '\n' ' ' | cut -c1-120)] 基准=[$(printf '%s' "$base" | tr '\n' ' ' | cut -c1-120)]"
  done
  if [ "${MD_LIGHT_CHECKS:-0}" = "1" ]; then
    log "  MD_LIGHT_CHECKS=1：跳过逐 DN 停机比对（只做全部在线比对）"
    return 0
  fi
  for h in "${DN[@]}"; do
    log "  --- 停 DataNode $h ---"
    sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true; pkill -f 'com\\.timecho\\.iotdb\\.DataNode' >/dev/null 2>&1 || true" || true
    wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "停 $h 后集群仍显示 Running"
    for on in "${DN[@]}"; do
      [ "$on" = "$h" ] && continue
      cur=$(query_result "$on" "$dialect" "$sql")
      [ "$cur" = "$base" ] && pass "停 $h 时经 $on 查询一致" || fail "停 $h 后经 $on 查询与基准不一致: [$(printf '%s' "$cur" | tr '\n' ' ' | cut -c1-120)] vs [$(printf '%s' "$base" | tr '\n' ' ' | cut -c1-120)]"
    done
    sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}.log 2>&1 </dev/null &" || true
    wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || fail "DataNode $h 未恢复 Running"
  done
}
dn_state(){ sq 'show cluster;' 2>/dev/null | awk -F'|' '{gsub(/[[:space:]]/,"",$3);gsub(/[[:space:]]/,"",$4);gsub(/[[:space:]]/,"",$5)} $3=="DataNode" && $5==ip {print $4; exit}' ip="$1"; }
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
# 收尾检查 3：CN/DN 异常日志分析（元数据专项模式）
# ---------------------------------------------------------------------------
COMMON_ERR_PAT='NullPointerException|BufferUnderflowException|ArrayIndexOutOfBoundsException|NegativeArraySizeException|has overlapped data|is not in tsFileMetaData|No matched database'
# 元数据专项：只匹配"真的失败"，避免 INFO 级正常日志误报
#   注意 `SchemaRegion\[[0-9]+\] (failed to|failed because|met error)` 必须让失败描述**紧跟** region id，
#   否则 "Execute FragmentInstance in ConsensusGroup SchemaRegion[7] failed." 这类
#   **查询片段**失败也会被算成"元数据失败"（踩过：MD-U01 里停/重启集群导致的噪声，还连带污染了下一条用例）。
MD_ERR_PAT='SchemaRegion\[[0-9]+\] (failed to|failed because|met error|is not)|TimeseriesAlreadyExistsException[^|]*(ERROR|error)|Failed to (create|drop|alter|set) (database|timeseries|table|schema template)[^|]*(failed|Failed|FAILED)'
# 已知正常 INFO（例如幂等 DDL 的提示、正常的 plan 失败回执）
#   + 收尾检查自己造成的噪声：
#     - 一致性校验会逐个停 DN，集群随即尝试把该节点的 region leader 转走，RPC 必然失败；
#     - 停/重启节点时在飞的查询片段会失败（Execute FragmentInstance … failed）。
#   这两类都是**测试动作**引起的，不是产品缺陷。
BENIGN_PAT='Not TTL rule set|already exists|AlreadyExists|TableAlreadyExists|DatabaseAlreadyExists|Failed to CHANGE_REGION_LEADER|TransferLeaderRPCHandler|RatisRequestFailedException: Ratis request failed: transferLeader|Execute FragmentInstance in ConsensusGroup [^|]*failed'
# 记录各节点日志的当前行数：check_logs 只看"本用例期间新增的行"。
#   为什么需要：CN/DN 日志是**跨用例累积**的，整文件扫描会把上一条用例产生的行算到下一条头上
#   （踩过：MD-U01 停/重启集群造成的 WARN 让 MD-S01 无端 FAIL）。
LOG_MARK_FILE=""
md_log_mark(){
  LOG_MARK_FILE="$ART/log_marks.txt"
  : >"$LOG_MARK_FILE"
  local h files f n
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    files=$(sshx "$h" "ls $DB_DIR/logs/*all*.log $DB_DIR/logs/*error*.log 2>/dev/null" | tr -d '\r')
    for f in $files; do
      [ -n "$f" ] || continue
      n=$(sshx "$h" "wc -l < $f 2>/dev/null" | tr -dc '0-9')
      printf '%s|%s|%s\n' "$h" "$f" "${n:-0}" >>"$LOG_MARK_FILE"
    done
  done
  log "  日志基线已记录（$(wc -l <"$LOG_MARK_FILE" | tr -d ' ') 个文件，后续只扫新增行）"
}
check_logs(){
  local extra=${1:-} pat="$COMMON_ERR_PAT|$MD_ERR_PAT${extra:+|$extra}"
  # MD_LOG_BENIGN_EXTRA：用例自己**故意**制造的错误日志（例如 MD-U01 故意让 UDF 抛异常）
  local benign="$BENIGN_PAT${MD_LOG_BENIGN_EXTRA:+|$MD_LOG_BENIGN_EXTRA}"
  local h f start n role nodes files total=0 bad=0
  log "=== CN/DN 异常日志分析（只看本用例新增的日志行） ==="
  if [ -z "${LOG_MARK_FILE:-}" ] || [ ! -f "${LOG_MARK_FILE:-}" ]; then
    warn "没有日志基线（未调用 md_log_mark），退化为整文件扫描"
    for role in confignode datanode; do
      if [ "$role" = confignode ]; then nodes=("${CN[@]}"); else nodes=("${DN[@]}"); fi
      for h in "${nodes[@]}"; do
        files=$(sshx "$h" "ls $DB_DIR/logs/*${role}*all*.log $DB_DIR/logs/*${role}*error*.log 2>/dev/null" | tr '\n' ' ')
        [ -z "$files" ] && { warn "$role $h 无日志文件"; continue; }
        n=$(sshx "$h" "grep -hE '$pat' $files 2>/dev/null | grep -vcE '$benign'" | tr -dc '0-9')
        if [ "${n:-0}" -gt 0 ]; then fail "$role $h 日志出现 $n 条异常（整文件扫描）"; bad=$((bad+1))
        else pass "$role $h 日志无异常（整文件扫描）"; fi
      done
    done
    return 0
  fi
  while IFS='|' read -r h f start; do
    [ -n "$h" ] && [ -n "$f" ] || continue
    total=$((total+1))
    n=$(sshx "$h" "tail -n +$(( ${start:-0} + 1 )) $f 2>/dev/null | grep -E '$pat' | grep -vcE '$benign'" | tr -dc '0-9')
    if [ "${n:-0}" -gt 0 ]; then
      fail "$(basename "$f") @$h 本用例新增 $n 条异常日志"
      sshx "$h" "tail -n +$(( ${start:-0} + 1 )) $f 2>/dev/null | grep -E '$pat' | grep -vE '$benign' | head -10 | cut -c1-240" >>"$OUT" 2>&1
      bad=$((bad+1))
    fi
  done <"$LOG_MARK_FILE"
  [ "$bad" -eq 0 ] && pass "CN/DN 日志无异常（扫了 $total 个日志文件的新增行）"
}

# 收尾三件套：sync lag -> 副本一致性（元数据查询）-> 日志
#   post_checks <元数据查询 SQL> [dialect] [每个副本附加查询次数]
post_checks(){
  local sql=$1 dialect=${2:-tree}
  log "--- 收尾检查 1/3：sync lag 归零 ---"
  check_sync_lag || true
  log "--- 收尾检查 2/3：副本一致性（元数据查询） ---"
  consistency_check "$sql" "$dialect"
  log "--- 收尾检查 3/3：CN/DN 日志异常分析 ---"
  check_logs
}

# ---------------------------------------------------------------------------
# 备份日志 / 结果
# ---------------------------------------------------------------------------
backup_logs(){
  [ "${LOG_BACKUP:-0}" -eq 1 ] || { log "LOG_BACKUP=0，跳过日志备份"; return 0; }
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
  msg=$(printf '%s' "${v_warnMessage:-}" | tr ',' ';' | tr -d "'")
  [ -f "$csv" ] || echo 'Time,build,consensus,caseName,result,elapsedSeconds,failCount,artifact,message' >>"$csv"
  printf '%s,%s,%s,%s.sh,%s,%s,%s,%s,%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$BUILD_TAG" "${CONSENSUS_CLASS##*.}" "$CASE" \
    "$r" "$elapsed" "$fail_flag" "$ART" "'${msg}'" >>"$csv"
}
# 用例统一收尾：收尾三件套（sync lag / 副本一致性 / 日志）-> 失败备份日志 -> 停集群 -> 写结果
md_case_finish(){
  local dialect=${1:-tree} sql=${2:-}
  if [ -n "$sql" ]; then
    post_checks "$sql" "$dialect"
  else
    log "--- 收尾：未提供一致性查询，仅做日志异常分析 ---"
    check_logs
  fi
  if [ "$fail_flag" -gt 0 ]; then backup_logs; else log "用例通过，不备份日志"; fi
  # 套件模式（run_all 会导出 MD_NO_STOP_AFTER=1）下不关集群：
  # 下一条用例直接复用，避免每条用例都白花 ~5 分钟在 停/清/启 上。
  if [ "${KEEP_DATA:-0}" = "1" ] || [ "${MD_NO_STOP_AFTER:-0}" = "1" ]; then
    log "保留集群运行（KEEP_DATA=$KEEP_DATA MD_NO_STOP_AFTER=${MD_NO_STOP_AFTER:-0}）"
  else
    cluster_stop
  fi
  write_result
}
