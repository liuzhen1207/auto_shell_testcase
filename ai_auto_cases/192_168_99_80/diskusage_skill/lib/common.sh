#!/bin/bash
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
ttl_load_env(){
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

ttl_parse_args(){
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
ttl_case_init(){
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
      sshx "$h" "rm -rf $DB_DIR/data $DB_DIR/logs; if [ -d $DB_DIR/conf_orig ]; then rm -rf $DB_DIR/conf; cp -rp $DB_DIR/conf_orig $DB_DIR/conf; fi" || warn "清理 $h 失败"
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
  for kv in $(printf '%s' "${EXTRA_CONF:-}" | tr ',' ' '); do
    k="${kv%%=*}"; v="${kv#*=}"
    [ -n "$k" ] || continue
    sshx "$h" "P=$DB_DIR/conf/iotdb-system.properties; sed -i -E '/^[#[:space:]]*${k}[[:space:]]*=/d' \"\$P\"; printf '%s=%s\\n' '$k' '$v' >> \"\$P\"" \
      || fail "写扩展配置失败: $h $k=$v"
  done
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
    for kv in $(printf '%s' "${EXTRA_CONF:-}" | tr ',' ' '); do
      k="${kv%%=*}"; want="${kv#*=}"
      [ -n "$k" ] || continue
      v=$(sshx "$h" "grep -E '^$k=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
      [ "$v" = "$want" ] || fail "$h $k 写入不匹配: '$v' != '$want'"
    done
  done
  local keys="cluster_name|schema_replication_factor|data_replication_factor|data_region_consensus_protocol_class|ttl_check_interval|max_expired_time|expired_data_ratio" kv
  for kv in $(printf '%s' "${EXTRA_CONF:-}" | tr ',' ' '); do keys="$keys|${kv%%=*}"; done
  log "  配置确认(${CN[0]}): $(sshx "${CN[0]}" "grep -E '^($keys)=' $DB_DIR/conf/iotdb-system.properties | tail -20" | tr '\n' ' ')"
}
cluster_start(){
  log "--- 启动集群 ---"
  local h
  if [ "$USE_FRAMEWORK" = "1" ] && [ -f "$FRAMEWORK_DIR/prepare_env/start_cluster_v20.sh" ]; then
    cp -f "$FRAMEWORK_CN_LIST" "$FRAMEWORK_DIR/conf/confignode.txt" 2>/dev/null || true
    cp -f "$FRAMEWORK_DN_LIST" "$FRAMEWORK_DIR/conf/datanode.txt"   2>/dev/null || true
    bash "$FRAMEWORK_DIR/prepare_env/start_cluster_v20.sh" 1 "$(( ${#CN[@]} + ${#DN[@]} ))" >>"$OUT" 2>&1 || fail "集群启动脚本失败"
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
# 收尾检查 1：sync lag 归零（抓每个 DN 自己的 exporter）
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
# 收尾检查 2：副本一致性
#   consistency_check <SQL> <dialect: tree|table> [每副本查询次数]
#   做法：全部在线时各副本各查一次比基准；再逐个停 DN，用剩余副本查，仍要与基准一致
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
consistency_check(){
  local sql=$1 dialect=${2:-tree} h on cur base
  log "=== 副本一致性校验（${dialect}）: $sql ==="
  base=$(query_result "${DN[0]}" "$dialect" "$sql")
  log "  基准(经 ${DN[0]}): [$(printf '%s' "$base" | tr '\n' ' ')]"
  for h in "${DN[@]}"; do
    [ "$h" = "${DN[0]}" ] && continue
    cur=$(query_result "$h" "$dialect" "$sql")
    [ "$cur" = "$base" ] && pass "全部在线: $h 与基准一致" || fail "全部在线副本不一致: $h=[$(printf '%s' "$cur" | tr '\n' ' ')] 基准=[$(printf '%s' "$base" | tr '\n' ' ')]"
  done
  for h in "${DN[@]}"; do
    log "  --- 停 DataNode $h ---"
    sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true; pkill -f 'com\\.timecho\\.iotdb\\.DataNode' >/dev/null 2>&1 || true" || true
    wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "停 $h 后集群仍显示 Running"
    for on in "${DN[@]}"; do
      [ "$on" = "$h" ] && continue
      cur=$(query_result "$on" "$dialect" "$sql")
      [ "$cur" = "$base" ] && pass "停 $h 时经 $on 查询一致" || fail "停 $h 后经 $on 查询与基准不一致: [$(printf '%s' "$cur" | tr '\n' ' ')] vs [$(printf '%s' "$base" | tr '\n' ' ')]"
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
COMMON_ERR_PAT='NullPointerException|BufferUnderflowException|but return HAS_MORE_STATE|CompactionTableSchemaNotMatchException|has overlapped data|DataTypeInconsistentException|ArrayIndexOutOfBoundsException|NegativeArraySizeException|StatisticsClassException|is not in tsFileMetaData|No matched database'
# TTL 专项异常：只匹配"真的失败"，避免 INFO 级正常日志误报
TTL_ERR_PAT='FAILED_TTL_DELETION|Settle (task|compaction)[^|]*(failed|Failed|FAILED)|TTL (deletion|cleanup|scan)[^|]*(failed|Failed|FAILED)|Failed to (delete|clean)[^|]*(ttl|TTL|object|tsfile)'
# 已知的正常 INFO 日志（例如 unset 不存在的规则、跨库操作提示），不计入异常
BENIGN_PAT='Not TTL rule set|Failed to execute plan org\.apache\.iotdb\.confignode\.consensus\.request\.write\.database\.SetTTLPlan'
check_logs(){
  local extra=${1:-} pat="$COMMON_ERR_PAT|$TTL_ERR_PAT${extra:+|$extra}" role h files n nodes benign
  log "=== CN/DN 异常日志分析 ==="
  for role in confignode datanode; do
    if [ "$role" = confignode ]; then nodes=("${CN[@]}"); else nodes=("${DN[@]}"); fi
    for h in "${nodes[@]}"; do
      files=$(sshx "$h" "ls $DB_DIR/logs/*${role}*all*.log $DB_DIR/logs/*${role}*error*.log 2>/dev/null" 2>/dev/null | tr '\n' ' ')
      [ -z "$files" ] && { warn "$role $h 无日志文件"; continue; }
      benign=$(sshx "$h" "grep -hcE '$BENIGN_PAT' $files 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
      n=$(sshx "$h" "grep -hE '$pat' $files 2>/dev/null | grep -vcE '$BENIGN_PAT'" 2>/dev/null | tr -dc '0-9')
      if [ "${n:-0}" -gt 0 ]; then
        fail "$role $h 日志出现 $n 条异常（常见异常/TTL 异常）"
        sshx "$h" "grep -nE '$pat' $files 2>/dev/null | grep -vE '$BENIGN_PAT' | head -20 | cut -c1-240" >>"$OUT" 2>&1
      else
        pass "$role $h 日志无异常（已忽略 $benign 条已知正常 INFO，如 Not TTL rule set）"
      fi
    done
  done
  # TTL 检查任务是否真的跑过（正证据）
  local started=0
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "grep -hc 'Start ttl and modification checking' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    started=$((started + ${n:-0}))
  done
  log "  TTL 检查任务累计启动次数(全部 DN): $started"
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
  msg=$(printf '%s' "${v_warnMessage:-}" | tr ',' ';' | tr -d "'")
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

# 用例统一的集群准备：停 -> 清 -> 写参数 -> 启动（SKIP_LIFECYCLE=1 时复用已运行集群）
ttl_cluster_prepare(){
  if [ "${SKIP_LIFECYCLE:-0}" = "1" ] && sq 'show cluster;' 2>/dev/null | grep -qE 'Running|ReadOnly'; then
    log "--- SKIP_LIFECYCLE=1：复用当前已运行的集群 ---"
    wait_cluster_ready || fail "集群未就绪"
    return 0
  fi
  cluster_stop
  cluster_clean
  cluster_write_conf
  cluster_start
}

# 用例统一收尾：失败备份日志 -> 停集群 -> 写结果
ttl_case_finish(){
  local do_consistency=${1:-} dialect=${2:-tree} sql=${3:-}
  if [ -n "$sql" ]; then consistency_check "$sql" "$dialect" || true; fi
  if [ "$fail_flag" -gt 0 ]; then backup_logs; else log "用例通过，不备份日志"; fi
  [ "${KEEP_DATA:-0}" = "1" ] || cluster_stop
  write_result
}
