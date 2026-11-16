#!/bin/bash
# ============================================================================
# treeview_skill / lib/common.sh
#   树转表（tree → table view）测试技能的公共库
#   被 cases/*.sh 与 tools/*.sh source；不单独执行
# ============================================================================
set -uo pipefail

TV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TV_SKILL_DIR="$(cd "$TV_LIB_DIR/.." && pwd)"
export TV_LIB_DIR TV_SKILL_DIR

# ---------------------------------------------------------------------------
# 环境
# ---------------------------------------------------------------------------
tv_load_env(){
  local conf="$TV_SKILL_DIR/conf/env.conf"
  [ -f "$conf" ] && . "$conf"
  V_TESTDB=${V_TESTDB:-v20131rc1_1030_ab6d3de}
  BUILD_TAG=${BUILD_TAG:-ab6d3de}
  DB_DIR=${DB_DIR:-/data/iotdb/$V_TESTDB}
  FRAMEWORK_DIR=${FRAMEWORK_DIR:-/data/iotdb/autotest}
  HOSTS=(${TV_HOSTS:-192.168.99.77 192.168.99.78 192.168.99.79})
  DN=(${TV_DN:-192.168.99.77 192.168.99.78 192.168.99.79})
  CN=(${TV_CN:-192.168.99.77 192.168.99.78 192.168.99.79})
  SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
  ROOT_PW=${ROOT_PW:-TimechoDB@2021}
  CLI=${CLI:-/data/iotdb/testdb/$V_TESTDB/sbin/start-cli.sh}
  CONSENSUS_CLASS=${CONSENSUS_CLASS:-org.apache.iotdb.consensus.iot.IoTConsensus}
  DATA_CONSENSUS=${CONSENSUS_CLASS##*.}
  # 真实数据集（3C3D 上已解压的 load 目录）
  TV_DATA_DIR=${TV_DATA_DIR:-/tmp/treeview/tsfile}
  TV_PREFIX=${TV_PREFIX:-root.reactor}
}

tv_parse_args(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --consensus) CONSENSUS_CLASS="$2"; DATA_CONSENSUS="${2##*.}"; shift 2 ;;
      --hosts) HOSTS=($2); shift 2 ;;
      --prefix) TV_PREFIX="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

sshx(){ local h=$1; shift; ssh $SSH_OPTS root@"$h" "$@" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 日志 / 断言
# ---------------------------------------------------------------------------
tv_case_init(){
  CASE="$1"
  RUN_ID="$(date +%Y%m%d_%H%M%S)"
  OUTDIR="$TV_SKILL_DIR/results"
  OUT="$OUTDIR/${CASE}_${RUN_ID}.out"
  ART="$OUTDIR/artifact_${CASE}_${RUN_ID}"
  mkdir -p "$OUTDIR" "$ART" "$ART/logs"
  : >"$OUT"
  fail_flag=0
  v_warnMessage=""
  start_epoch=$(date +%s)
  log "=== $CASE 开始 run_id=$RUN_ID ==="
  log "环境: build=$BUILD_TAG consensus=$DATA_CONSENSUS nodes=[${DN[*]}] db_dir=$DB_DIR"
}
log(){  local m="[$(date '+%F %T')] $*"; [ -n "${OUT:-}" ] && printf '%s\n' "$m" >>"$OUT"; printf '%s\n' "$m"; }
note(){ v_warnMessage="${v_warnMessage}$*"; }
warn(){ note "$*"; log "WARN $*"; }
fail(){ fail_flag=$((fail_flag+1)); note "$*"; log "FAIL $*"; }
pass(){ log "PASS $*"; }

assert_eq(){ local l=$1 got=${2:-} want=${3:-}; if [ "$got" = "$want" ]; then pass "$l: = $got"; else fail "$l: 实际=[$got] 期望=[$want]"; fi; }
assert_ne(){ local l=$1 a=${2:-} b=${3:-}; if [ "$a" != "$b" ]; then pass "$l: [$a] != [$b]"; else fail "$l: 不应相等（都是 [$a]）"; fi; }
assert_num_eq(){ local l=$1 a=${2:-0} b=${3:-0}; if awk -v x="$a" -v y="$b" 'BEGIN{exit (x==y)?0:1}'; then pass "$l: $a == $b"; else fail "$l: 实际=[$a] 期望=[$b]"; fi; }
assert_contains(){ local l=$1 out=$2 want=$3; if printf '%s' "$out" | grep -qF -- "$want"; then pass "$l: 命中 /$want/"; else fail "$l: 未命中 /$want/ :: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-180)"; fi; }
assert_not_contains(){ local l=$1 out=$2 bad=$3; if printf '%s' "$out" | grep -qE -- "$bad"; then fail "$l: 出现不应有的 /$bad/ :: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-180)"; else pass "$l: 未出现 /$bad/"; fi; }
assert_err_code(){ local l=$1 out=$2 code=$3; if printf '%s' "$out" | grep -qE "(IoTDBSQLException: |Msg: |Error: )$code"; then pass "$l: 如期报错 $code"; else fail "$l: 未见错误码 $code :: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; fi; }

# ---------------------------------------------------------------------------
# SQL（表方言/树方言各一个 CLI 会话）
# ---------------------------------------------------------------------------
_cli(){ "$CLI" -h "${1:-192.168.99.77}" -u root -pw "$ROOT_PW" "${@:2}" 2>&1; }
sql_lines(){ printf '%s\n' "$@" | "$CLI" -h "${TV_HOST:-192.168.99.77}" -u root -pw "$ROOT_PW" 2>&1; }
strip_echo(){ grep -avE '^\s*TimechoDB|^\s*-{3,}|^Starting TimechoDB|^_|^/|^\\|^=|^\s*$' | grep -avE '^\s*$'; }
table_rows(){ grep -aE '^\|' | grep -avE '^\|[-+ ]+\|$' | grep -av '^|NodeID|^|Time'; }
scalar(){ printf '%s\n' "$1" | table_rows | head -1 | awk -F'|' '{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }
tcol(){ # tcol <output> <列号,从1开始（不含前导空列）>
  local col=${2:-1}
  printf '%s\n' "$1" | grep -a '^|' | grep -avE '^\|[-+ |]+\|$' | tail -1 | \
    awk -F'|' -v c="$col" '{v=$(c+1); gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'
}
last_msg(){ printf '%s\n' "$1" | grep -aE '^(Msg|Error):' | tail -1; }
tval(){ printf '%s\n' "$1" | grep -aoE '[-+]?[0-9]+(\.[0-9]+)?' | head -1; }
tvalsum(){ printf '%s\n' "$1" | grep -aoE '[-+]?[0-9]+(\.[0-9]+)?' | awk '{s+=$1} END{print s+0}'; }
row_sum(){ printf '%s\n' "$1" | table_rows | awk -F'|' '{for(i=2;i<=NF-1;i++){v=$i; gsub(/^[ \t]+|[ \t]+$/,"",v); if(v ~ /^[-+]?[0-9]+(\.[0-9]+)?$/) s+=v+0}} END{printf "%g", s+0}'; }

tqt(){ printf 'set sql_dialect=table;\n%s\n' "$@" | "$CLI" -h "${TV_HOST:-192.168.99.77}" -u root -pw "$ROOT_PW" 2>&1; }
tqt_db(){ local db=$1; shift; printf 'set sql_dialect=table;\nuse %s;\n%s\n' "$db" "$@" | "$CLI" -h "${TV_HOST:-192.168.99.77}" -u root -pw "$ROOT_PW" 2>&1; }
sqt_db(){ local db=$1; shift; printf 'set sql_dialect=tree;\nuse %s;\n%s\n' "$db" "$@" | "$CLI" -h "${TV_HOST:-192.168.99.77}" -u root -pw "$ROOT_PW" 2>&1; }

# ---------------------------------------------------------------------------
# 集群生命周期（复用框架脚本；带超时与残留清理）
# ---------------------------------------------------------------------------
# 用 DDL 清掉本用例自己的库（集群元数据在 ConfigNode 上，删数据目录清不掉 schema）
tv_reset_db(){
  local db=$1 dialect=${2:-table}
  if [ "$dialect" = tree ]; then
    printf 'set sql_dialect=tree;\ndrop database %s;\n' "$db" | "$CLI" -h "${TV_HOST:-192.168.99.77}" -u root -pw "$ROOT_PW" >/dev/null 2>&1
  else
    printf 'set sql_dialect=table;\ndrop database %s;\n' "$db" | "$CLI" -h "${TV_HOST:-192.168.99.77}" -u root -pw "$ROOT_PW" >/dev/null 2>&1
  fi
}
# 优雅停集群：DN → CN（用 sbin 脚本），避免 pkill -9 打断 CN 快照写入
# 背景：RC1 已知 bug —— kill -9 撞上快照写入会产生截断快照，CN 之后启动即失败（RC2 修）
tv_graceful_stop(){
  local h i alive
  for h in "${HOSTS[@]}"; do
    sshx "$h" "cd $DB_DIR && bash sbin/stop-datanode.sh >/dev/null 2>&1 || true" >/dev/null 2>&1
  done
  for i in $(seq 1 15); do
    alive=0
    for h in "${HOSTS[@]}"; do
      [ "$(sshx "$h" "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" | tr -dc '0-9')" -gt 0 ] && alive=$((alive+1))
    done
    [ "$alive" -eq 0 ] && break
    sleep 3
  done
  for h in "${HOSTS[@]}"; do
    sshx "$h" "cd $DB_DIR && bash sbin/stop-confignode.sh >/dev/null 2>&1 || true" >/dev/null 2>&1
  done
  for i in $(seq 1 20); do
    alive=0
    for h in "${HOSTS[@]}"; do
      [ "$(sshx "$h" "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" | tr -dc '0-9')" -gt 0 ] && alive=$((alive+1))
    done
    [ "$alive" -eq 0 ] && break
    sleep 3
  done
  # 兜底用 TERM（仍不用 -9）
  for h in "${HOSTS[@]}"; do sshx "$h" "pkill -TERM -f 'com\.timecho\.iotdb' || true" >/dev/null 2>&1; done
  sleep 5
}

tv_cluster_prepare(){
  local mode=${1:-clean}
  log "--- 集群准备（$mode / $DATA_CONSENSUS）---"
  tv_graceful_stop
  if [ "${mode}" = clean ]; then
    for h in "${HOSTS[@]}"; do
      # 只清 DN 的业务数据与 WAL，**保留** data/datanode/system（nodeId）与 configNode 数据（集群身份/激活）
      sshx "$h" "rm -rf $DB_DIR/data/datanode/data/* $DB_DIR/data/datanode/wal/* 2>/dev/null; rm -f $DB_DIR/logs/*.log 2>/dev/null" || true
    done
    log "  已清理 data/wal/logs（保留 conf 与 activation）"
  fi
  local conf="$FRAMEWORK_DIR/conf/test.conf"
  [ -f "$conf" ] && sed -i "s#^v_testdb=.*#v_testdb=$V_TESTDB#; s#^v_commit=.*#v_commit=$BUILD_TAG#" "$conf"
  ( cd "$FRAMEWORK_DIR" && timeout 600 bash prepare_env/start_cluster_v20.sh 1 6 >"$ART/cluster_prepare.log" 2>&1 )
  local rc=$?
  local ready
  ready=$(grep -ac '6/6' "$ART/cluster_prepare.log" 2>/dev/null)
  tv_set_consensus
  log "  启动 rc=$rc ready=${ready:-0}"
  return $rc
}
# 用例开场：起集群 + 等就绪 + 清掉本用例自己的库
tv_prologue(){
  local tree_db=${1:-} table_db=${2:-}
  if [ "${TV_SKIP_PROLOGUE:-0}" = "1" ]; then
    # 复用已运行的集群（环境反复重启容易踩 RC1 的 CN 快照 bug）
    local i
    for i in $(seq 1 60); do
      printf 'set sql_dialect=table;\nshow databases;\n' | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/dev/null 2>&1 && break
      sleep 3
    done
    tv_set_consensus
    tv_log_mark
    [ -n "$table_db" ] && tv_reset_db "$table_db" table
    [ -n "$tree_db" ] && tv_reset_db "$tree_db" tree
    sleep 1
    return 0
  fi
  tv_cluster_prepare >/dev/null 2>&1
  tv_set_consensus
  local i
  for i in $(seq 1 60); do
    printf 'set sql_dialect=table;\nshow databases;\n' | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/dev/null 2>&1 && break
    sleep 3
  done
  tv_log_mark
  [ -n "$table_db" ] && tv_reset_db "$table_db" table
  [ -n "$tree_db" ] && tv_reset_db "$tree_db" tree
  sleep 2
}
# 只起集群、不清理 data/logs（真实数据用例用：数据由 import-data.sh 预先导入）
tv_prologue_keep(){
  local table_db=${1:-}
  if [ "${TV_SKIP_PROLOGUE:-0}" = "1" ]; then
    # 复用已运行的集群（真实数据用例复跑/排查时用）
    local i
    for i in $(seq 1 60); do
      printf 'set sql_dialect=table;\nshow databases;\n' | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/dev/null 2>&1 && break
      sleep 3
    done
    tv_set_consensus
    tv_log_mark
    [ -n "$table_db" ] && tv_reset_db "$table_db" table
    sleep 1
    return 0
  fi
  tv_graceful_stop
  ( cd "$FRAMEWORK_DIR" && timeout 600 bash prepare_env/start_cluster_v20.sh 1 6 >"$ART/cluster_prepare.log" 2>&1 )
  tv_set_consensus
  local i
  for i in $(seq 1 60); do
    printf 'set sql_dialect=table;\nshow databases;\n' | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/dev/null 2>&1 && break
    sleep 3
  done
  tv_log_mark
  [ -n "$table_db" ] && tv_reset_db "$table_db" table
  sleep 1
}
tv_set_consensus(){
  local cls="$CONSENSUS_CLASS"
  for h in "${DN[@]}"; do
    sshx "$h" "grep -q 'data_region_consensus_protocol_class=$cls' $DB_DIR/conf/iotdb-datanode.properties || sed -i 's#^data_region_consensus_protocol_class=.*#data_region_consensus_protocol_class=$cls#' $DB_DIR/conf/iotdb-datanode.properties"
  done
}
tv_cluster_stop(){
  tv_graceful_stop
}

# ---------------------------------------------------------------------------
# 收尾三件套：sync lag → 副本一致性 → 日志扫描
# ---------------------------------------------------------------------------
tv_sync_lag(){
  local h v n=0 tries=${1:-60} i
  for i in $(seq 1 "$tries"); do
    n=0
    for h in "${DN[@]}"; do
      v=$(sshx "$h" "curl -s http://$h:9092/metrics 2>/dev/null | grep -E '^iot_consensus\\{type=\"syncLag\"' | awk '{print \$NF}' | awk '\$1>0' | wc -l" | tr -dc '0-9')
      n=$(( n + ${v:-0} ))
    done
    [ "$n" -eq 0 ] && { pass "sync lag 已归零（各 DN syncLag>0 的序列数=0）"; return 0; }
    sleep 5
  done
  fail "sync lag 未在 $((tries*5))s 内归零（各 DN 非零序列数合计=$n）"
  return 1
}

tv_fp(){ local sql=$1; local o; o=$(tqt "$sql"); printf '%s' "$o" | table_rows | sed 's/[[:space:]]//g' | sort | md5sum | awk '{print $1}'; }
tv_rows_n(){ local sql=$1 o; o=$(tqt "$sql"); printf '%s' "$o" | table_rows | wc -l | tr -d ' '; }
tv_scalar(){ local sql=$1; scalar "$(tqt "$sql")"; }

# 副本一致性：<label> <指纹 SQL>。以"全部在线"为基线，逐个停 1 DN 再从其它 DN 查，比对基线。
tv_replica_consistency(){
  local label=$1 sql=$2 base out h other
  base=$(tv_fp "$sql")
  log "  基线指纹（${label}，经 ${TV_HOST:-192.168.99.77}）= $base"
  for h in "${DN[@]}"; do
    sshx "$h" "cd $DB_DIR && bash sbin/stop-datanode.sh >/dev/null 2>&1 || pkill -TERM -f 'iotdb\.datanode\.DataNode' || true" >/dev/null 2>&1
    sleep 20
    for other in "${DN[@]}"; do
      [ "$h" = "$other" ] && continue
      TV_HOST=$other
      out=""
      for _try in 1 2 3; do
        out=$(tv_fp "$sql")
        [ -n "$out" ] && [ "$out" != "d41d8cd98f00b204e9800998ecf8427e" ] && break
        sleep 5
      done
      [ "$out" = "$base" ] && pass "停 $h 后经 $other 查询与基线一致" || fail "停 $h 后经 $other 查询不一致（$out != $base）"
    done
    # 注意：`&` 必须只作用于 nohup，不能作用于整个 `cd && ...` 列表，
    # 否则后台子 shell 会继续持有 ssh 会话的 stdout，导致 ssh 一直不返回。
    sshx "$h" "cd $DB_DIR; nohup sbin/start-datanode.sh </dev/null >/dev/null 2>&1 &" >/dev/null 2>&1
    sleep 25
  done
  TV_HOST=${DN[0]}
}

TV_LOG_BENIGN='PageCacheDeletionBuffer|Interrupted when waiting|Failed appendEntries|Follower failed|GrpcLogAppender|AppendLogResponseHandler|keep nextIndex|Fail to start server|ClosedChannelException|Connection refused|LEADER_CHANGE|transferLeader|RatisRequestFailedException|Broken pipe|SocketException|Unable to connect|InterruptedException|Fail to check password expiration|Cluster is unactivated|OverlappingFileLockException|Stop DataNode'
tv_check_logs(){
  local since=${1:-} label=${2:-CN/DN 日志}
  local h bad=0 n
  for h in "${HOSTS[@]}"; do
    local mk
    mk=$(awk -v h="$h" '$1==h{print $2}' "$ART/log_marks.txt" 2>/dev/null)
    n=$(sshx "$h" "awk -v n=${mk:-0} 'NR>n' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -aE ' (ERROR|WARN) ' | grep -avE "$TV_LOG_BENIGN${TV_LOG_BENIGN_EXTRA:+|$TV_LOG_BENIGN_EXTRA}" | wc -l" | tr -dc '0-9')
    if [ "${n:-0}" -gt 0 ]; then
      bad=$(( bad + n ))
      sshx "$h" "awk -v n=${mk:-0} 'NR>n' $DB_DIR/logs/log_datanode_all.log | grep -aE ' (ERROR|WARN) ' | grep -avE "$TV_LOG_BENIGN${TV_LOG_BENIGN_EXTRA:+|$TV_LOG_BENIGN_EXTRA}" | head -5" | sed 's/^/    /' | tee -a "$OUT"
    fi
    mk=$(awk -v h="$h" '$1==h{print $2}' "$ART/log_marks.txt" 2>/dev/null)
    n=$(sshx "$h" "awk -v n=${mk:-0} 'NR>n' $DB_DIR/logs/log_confignode_all.log 2>/dev/null | grep -aE ' (ERROR|WARN) ' | grep -avE "$TV_LOG_BENIGN${TV_LOG_BENIGN_EXTRA:+|$TV_LOG_BENIGN_EXTRA}" | wc -l" | tr -dc '0-9')
    if [ "${n:-0}" -gt 0 ]; then
      bad=$(( bad + n ))
      sshx "$h" "awk -v n=${mk:-0} 'NR>n' $DB_DIR/logs/log_confignode_all.log | grep -aE ' (ERROR|WARN) ' | grep -avE "$TV_LOG_BENIGN${TV_LOG_BENIGN_EXTRA:+|$TV_LOG_BENIGN_EXTRA}" | head -5" | sed 's/^/    /' | tee -a "$OUT"
    fi
  done
  [ "$bad" -eq 0 ] && pass "$label 无预期内 ERROR/WARN" || fail "$label 出现 $bad 条预期外 ERROR/WARN（见上）"
}
tv_log_mark(){ # 记录各节点日志行数基线
  local h; : >"$ART/log_marks.txt"
  for h in "${HOSTS[@]}"; do
    echo "$h $(sshx "$h" "wc -l < $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9')" >>"$ART/log_marks.txt"
  done
  log "  日志基线：$(tr '\n' ' ' <"$ART/log_marks.txt")"
}

# ---------------------------------------------------------------------------
# 证据
# ---------------------------------------------------------------------------
tv_backup_logs(){
  local tag=${1:-fail}
  local h d="$ART/logs"
  for h in "${HOSTS[@]}"; do
    sshx "$h" "cd $DB_DIR/logs && tar -czf /tmp/tv_${tag}_${h##*.}.tgz log_*.log 2>/dev/null" >/dev/null 2>&1
    scp $SSH_OPTS root@"$h":/tmp/tv_${tag}_"${h##*.}".tgz "$d/" 2>/dev/null || true
  done
  log "  日志已备份到 $d"
}

tv_case_finish(){
  local extra=${1:-}
  local el=$(( $(date +%s) - start_epoch ))
  if [ "${fail_flag:-0}" -eq 0 ]; then
    log "RESULT PASS fail_flag=0 case=$CASE consensus=$DATA_CONSENSUS build=$BUILD_TAG elapsed=${el}s"
  else
    log "RESULT FAIL fail_flag=$fail_flag case=$CASE consensus=$DATA_CONSENSUS build=$BUILD_TAG elapsed=${el}s"
    tv_backup_logs fail
  fi
  log "v_warnMessage=$v_warnMessage"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$BUILD_TAG" "$DATA_CONSENSUS" \
    "$CASE" "$([ "${fail_flag:-0}" -eq 0 ] && echo PASS || echo FAIL)" "$el" "${fail_flag:-0}" "$ART" "'$v_warnMessage'" \
    >>"$OUTDIR/test_result.csv"
  log "结果已追加到 $OUTDIR/test_result.csv"
}
