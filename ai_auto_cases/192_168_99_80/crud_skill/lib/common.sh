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
