#!/bin/bash
# ============================================================================
# 磁盘占用统计 skill —— 专用 helper（在 lib/common.sh 之上）
#   ① 统计查询：树模型 `SHOW DISK_USAGE FROM <path>` / 表模型 information_schema.table_disk_usage
#   ② 结果解析：表头列序、按列取值、求和
#   ③ 合并观测：某库 TsFile 数、inner compaction starts/finishes 行数、卡在
#      TsFileResource.writeLock 的线程（jstack）——TDB-629 门禁的判据与佐证
#   ④ 参数热改：SET CONFIGURATION（合并开关可热加载）
# 说明：本文件只依赖 lib/common.sh 提供的 sshx/sq/sqt/sq_node/sqt_node/log 等基础函数。
# ============================================================================

# ---------------------------------------------------------------------------
# ⓪ 以指定用户身份执行 SQL（权限用例用；common.sh 里没有）
# ---------------------------------------------------------------------------
sq_as(){  timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$1" -pw "$2" -timeout 3600 -e "$3" 2>&1; }
sqt_as(){ timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$1" -pw "$2" -sql_dialect table -timeout 3600 -e "$3" 2>&1; }

# ---------------------------------------------------------------------------
# ⓪' harness 别名：common.sh 是与 TTL skill 共用的通用 harness（函数前缀 ttl_），
#     这里提供 du_ 前缀的别名，让本 skill 的用例读起来自成一体。
# ---------------------------------------------------------------------------
du_load_env(){ ttl_load_env "$@"; }
du_parse_args(){ ttl_parse_args "$@"; }
du_case_init(){ ttl_case_init "$@"; }
du_case_finish(){ ttl_case_finish "$@"; }
du_cluster_prepare(){ ttl_cluster_prepare; }

# ---------------------------------------------------------------------------
# ① 统计查询
# ---------------------------------------------------------------------------
# 树模型：show disk_usage from <pathPattern>
du_tree(){ sq "show disk_usage from $1;"; }
# 树模型带子句（where/order by/limit 由调用方给全，例如 "root.db.** where SizeInBytes>0"）
du_tree_expr(){ sq "show disk_usage from $1;"; }
# 表模型：information_schema.table_disk_usage
du_table_all(){ sqt "select * from information_schema.table_disk_usage;"; }
du_table_where(){ sqt "select * from information_schema.table_disk_usage where $1;"; }
du_table_sql(){ sqt "$1"; }
# 以指定用户身份执行（权限用例）。注意参数是 <用户> <密码> <SQL> —— 三个都要往下传，
# 曾经写成 `du_tree_as(){ sq_as "$1" "$2"; }` 把 SQL 丢了，表现为 `$3: unbound variable` 且静默返回空。
du_tree_as(){ sq_as "$1" "$2" "${3:-}"; }
du_table_as(){ sqt_as "$1" "$2" "${3:-}"; }

# 树模型结果解析（列：Database|DataNodeId|RegionId|TimePartition|SizeInBytes）
du_tree_rows(){ printf '%s\n' "$1" | table_rows; }
du_tree_row_cnt(){ printf '%s\n' "$1" | table_rows | wc -l | tr -d ' '; }
# 注意：数值一律用 awk 的 `+0` 解析，**不要用 gsub 去非数字字符** ——
# 表模型的聚合列是 double（实测输出形如 `1698.0`），gsub 会把小数点也去掉导致 10 倍误差。
du_tree_size_sum(){ printf '%s\n' "$1" | table_rows | awk -F'|' '{s += ($6 + 0)} END{printf "%d", s+0}'; }
# 树模型某列的唯一值（列号：1=Database 2=DataNodeId 3=RegionId 4=TimePartition 5=SizeInBytes）
du_tree_col_uniq(){ printf '%s\n' "$1" | table_rows | awk -F'|' -v c="$2" '{v=$(c+1); gsub(/^[ \t]+|[ \t]+$/,"",v); print v}' | sort -u | tr '\n' ' '; }
# 树模型：按正则过滤后的行
du_tree_grep(){ printf '%s\n' "$1" | grep -E "$2"; }
# 表模型结果解析（列名见 du_header；**按列名取，不写死列号** ——
# 实测 2.0.12.1 的结果列是 database|table_name|table_type|datanode_id|region_id|time_partition|size_in_bytes，
# 比需求文档（2.0.8.2）多一列 table_type，写死列号会取错 size_in_bytes）
du_table_rows(){ printf '%s\n' "$1" | table_rows; }
du_table_row_cnt(){ printf '%s\n' "$1" | table_rows | wc -l | tr -d ' '; }
du_table_size_sum(){ du_col_sum "$1" size_in_bytes; }
du_table_col_uniq(){ printf '%s\n' "$1" | table_rows | awk -F'|' -v c="$2" '{v=$(c+1); gsub(/^[ \t]+|[ \t]+$/,"",v); print v}' | sort -u | tr '\n' ' '; }

# ---------------------------------------------------------------------------
# ② TsFile / 合并观测
# ---------------------------------------------------------------------------
# 某 DN 上某库的 TsFile 数（数据目录：data/datanode/data/{sequence,unsequence}/<db>/...）
du_tsfile_cnt(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 逐节点一行："node=n node=n ..."
du_tsfile_all(){ local db=$1 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(du_tsfile_cnt "$h" "$db") "; done; echo "$out"; }
# 所有 DN 上该库 TsFile 总数
du_tsfile_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(du_tsfile_cnt "$h" "$db"))); done; echo "$s"; }
# 该库 seq/unseq 分开统计（seq 合并是我们关注的）
du_tsfile_seq_cnt(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data/sequence -path '*/$db/*' -name '*.tsfile' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
du_tsfile_seq_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(du_tsfile_seq_cnt "$h" "$db"))); done; echo "$s"; }
# 列出该库的 TsFile 名字（证据）
du_tsfile_list(){ local h=$1 db=$2; sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | sort"; }
# 该库 TsFile 的物理字节数（校验"统计值 <= 物理文件大小"）
du_tsfile_bytes(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
du_tsfile_bytes_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(du_tsfile_bytes "$h" "$db"))); done; echo "$s"; }
# 结果集表头行（列语义校验）
du_header(){ printf '%s\n' "$1" | grep -m1 '^|'; }
# --- 按列名解析（稳健：不同构建的列集合可能不同，实测 2.0.12.1 的表模型结果里
#     比需求文档多一列 `table_type`，固定列号会取错值）---
# du_col_idx <输出> <列名> → awk -F'|' 的字段号（找不到则空）
du_col_idx(){ printf '%s\n' "$1" | grep -m1 '^|' | awk -F'|' -v want="$2" '{for(i=2;i<NF;i++){h=$i; gsub(/^[ \t]+|[ \t]+$/,"",h); if(tolower(h)==tolower(want)){print i; exit}}}'; }
# du_col_vals <输出> <列名> → 每行该列的值（表头/分隔行不计）
du_col_vals(){ local out=$1 col=$2 idx
  idx=$(du_col_idx "$out" "$col"); [ -n "${idx:-}" ] || return 1
  printf '%s\n' "$out" | table_rows | awk -F'|' -v c="$idx" '{v=$c; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }
# du_col_sum <输出> <列名> → 数值列求和
du_col_sum(){ du_col_vals "$1" "$2" | awk '{s += ($1 + 0)} END{printf "%d", s+0}'; }
# du_col_sum_where <输出> <求和列> <过滤列> <过滤值>
du_col_sum_where(){ local out=$1 scol=$2 fcol=$3 fval=$4 si fi
  si=$(du_col_idx "$out" "$scol"); fi=$(du_col_idx "$out" "$fcol")
  [ -n "${si:-}" ] && [ -n "${fi:-}" ] || { echo 0; return; }
  printf '%s\n' "$out" | table_rows | awk -F'|' -v si="$si" -v fi="$fi" -v fv="$fval" \
    '{f=$fi; gsub(/^[ \t]+|[ \t]+$/,"",f); if(f==fv){s += ($si + 0)}} END{printf "%d", s+0}'; }
# du_col_cnt_where <输出> <过滤列> <过滤值>
du_col_cnt_where(){ local out=$1 fcol=$2 fval=$3 fi
  fi=$(du_col_idx "$out" "$fcol"); [ -n "${fi:-}" ] || { echo 0; return; }
  printf '%s\n' "$out" | table_rows | awk -F'|' -v fi="$fi" -v fv="$fval" '{f=$fi; gsub(/^[ \t]+|[ \t]+$/,"",f); if(f==fv) c++} END{print c+0}'; }
# du_col_sum_2where <输出> <求和列> <过滤列1> <值1> <过滤列2> <值2>
du_col_sum_2where(){ local out=$1 scol=$2 c1=$3 v1=$4 c2=$5 v2=$6 si i1 i2
  si=$(du_col_idx "$out" "$scol"); i1=$(du_col_idx "$out" "$c1"); i2=$(du_col_idx "$out" "$c2")
  [ -n "${si:-}" ] && [ -n "${i1:-}" ] && [ -n "${i2:-}" ] || { echo 0; return; }
  printf '%s\n' "$out" | table_rows | awk -F'|' -v si="$si" -v i1="$i1" -v v1="$v1" -v i2="$i2" -v v2="$v2" \
    '{a=$i1; gsub(/^[ \t]+|[ \t]+$/,"",a); b=$i2; gsub(/^[ \t]+|[ \t]+$/,"",b); if(a==v1 && b==v2){s += ($si + 0)}} END{printf "%d", s+0}'; }
# du_col_cnt_2where <输出> <过滤列1> <值1> <过滤列2> <值2>
du_col_cnt_2where(){ local out=$1 c1=$2 v1=$3 c2=$4 v2=$5 i1 i2
  i1=$(du_col_idx "$out" "$c1"); i2=$(du_col_idx "$out" "$c2")
  [ -n "${i1:-}" ] && [ -n "${i2:-}" ] || { echo 0; return; }
  printf '%s\n' "$out" | table_rows | awk -F'|' -v i1="$i1" -v v1="$v1" -v i2="$i2" -v v2="$v2" \
    '{a=$i1; gsub(/^[ \t]+|[ \t]+$/,"",a); b=$i2; gsub(/^[ \t]+|[ \t]+$/,"",b); if(a==v1 && b==v2) c++} END{print c+0}'; }
# 聚合结果（GROUP BY 输出：database|table_name|<聚合列>）里按 table_name 取最后一列的值
du_group_val(){ local out=$1 t=$2 idx
  idx=$(du_col_idx "$out" table_name); [ -n "${idx:-}" ] || { echo 0; return; }
  printf '%s\n' "$out" | table_rows | awk -F'|' -v i="$idx" -v t="$t" '{n=$i; gsub(/^[ \t]+|[ \t]+$/,"",n); if(n==t){printf "%d\n", ($(NF-1) + 0)}}' | head -1; }

# inner compaction 的 starts / finishes 行数（按库过滤；两个日志文件都扫）。
# 日志文案（源码 StorageEngineMessages）：
#   "{db}-{region} [Compaction] {Sequence|Unsequence} InnerSpaceCompaction task starts with N files, ..."
#   "{db}-{region} [Compaction] {Sequence|Unsequence} InnerSpaceCompaction task finishes successfully, ..."
du_cmp_cnt(){ local h=$1 db=$2 pat=$3 v
  v=$(sshx "$h" "cat $DB_DIR/logs/log_datanode_compaction.log $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -hF '$pat' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
du_cmp_start_cnt(){ du_cmp_cnt "$1" "$2" 'InnerSpaceCompaction task starts with'; }
du_cmp_finish_cnt(){ du_cmp_cnt "$1" "$2" 'InnerSpaceCompaction task finishes successfully'; }
du_cmp_start_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(du_cmp_start_cnt "$h" "$db"))); done; echo "$s"; }
du_cmp_finish_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(du_cmp_finish_cnt "$h" "$db"))); done; echo "$s"; }
# 某库最近几条合并日志（证据）
du_cmp_log_tail(){ local h=$1 db=$2
  sshx "$h" "cat $DB_DIR/logs/log_datanode_compaction.log $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -hE '(root\.)?$db-[0-9]+ \[Compaction\]' | tail -4" 2>/dev/null; }

# 卡在 TsFileResource.writeLock 的线程数（jstack）：修复前统计查询泄漏读锁 ⇒ 合并任务永久等写锁
du_stuck_writelock_cnt(){ local h=$1 pid v
  pid=$(sshx "$h" "pgrep -f com.timecho.iotdb.DataNode | head -1" 2>/dev/null | tr -d '\r')
  [ -n "${pid:-}" ] || { echo 0; return; }
  v=$(sshx "$h" "jstack $pid 2>/dev/null | grep -c 'TsFileResource.writeLock'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
du_stuck_writelock_sum(){ local h s=0; for h in "${DN[@]}"; do s=$((s + $(du_stuck_writelock_cnt "$h"))); done; echo "$s"; }
# 抓卡住线程的栈片段（证据）：打印含 TsFileResource.writeLock 的线程名与前 12 行栈
du_stuck_stack(){ local h=$1 pid
  pid=$(sshx "$h" "pgrep -f com.timecho.iotdb.DataNode | head -1" 2>/dev/null | tr -d '\r')
  [ -n "${pid:-}" ] || { echo "(no DataNode pid on $h)"; return; }
  sshx "$h" "jstack $pid 2>/dev/null | grep -B12 'TsFileResource.writeLock' | grep -E '^\"|TsFileResource.writeLock|Compaction|at org.apache.iotdb' | head -30" 2>/dev/null; }

# 等合并推进：<db> <finish 基线> <tsfile 基线> <窗口秒>；回显 "finish:x tsfile:y"，返回 0=推进 / 1=超时
# 判据：**finish 行数必须增长**（主信号，直接对应"合并完成"）；
#       tsfile 数用"低于传入基线 或 低于窗口内首次采样"（辅信号）——
#       查询之后可能仍有文件在陆续 Async close 落盘，会把计数抬高，用首次采样兜住避免误判。
du_wait_merge(){ local db=$1 fin0=$2 ts0=$3 win=$4 f t first_ts=""
  local deadline=$(( $(date +%s) + win ))
  while (( $(date +%s) < deadline )); do
    sleep 5
    f=$(du_cmp_finish_sum "$db"); t=$(du_tsfile_sum "$db")
    [ -z "$first_ts" ] && first_ts=$t
    log "    等合并: finish=$f(基线$fin0) tsfile=$t(基线$ts0 首次$first_ts)"
    if [ "$f" -gt "$fin0" ] && { [ "$t" -lt "$ts0" ] || [ "$t" -lt "$first_ts" ]; }; then
      echo "finish:$f tsfile:$t"; return 0
    fi
  done
  echo "finish:${f:-0} tsfile:${t:-0}"; return 1
}

# ---------------------------------------------------------------------------
# ③ 参数热改 / 实际生效值
# ---------------------------------------------------------------------------
# 热改配置（表方言 SET CONFIGURATION；合并开关实测可热加载）
du_set_hot(){ sq "set configuration '$1'='$2';"; }
# 某节点实际生效的合并参数（表方言 show configuration，三列 name|value|default_value）
du_cmp_conf(){ local h=$1 k out; out=$(sqt_node "$h" 'show configuration;' 2>/dev/null)
  for k in enable_seq_space_compaction enable_unseq_space_compaction enable_cross_space_compaction inner_compaction_candidate_file_num compaction_schedule_interval_in_ms; do
    printf '%s=%s ' "$k" "$(printf '%s\n' "$out" | awk -F'|' -v k="$k" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3)} $2==k{print $3; exit}')"
  done
  echo; }

# ---------------------------------------------------------------------------
# ④ 造数据（每批 = 一个 TsFile）
# ---------------------------------------------------------------------------
# 树模型：建库+设备+时序，然后写一批数据并落盘。用法：du_make_tree_db <db> <devs> <rows>
du_make_tree_db(){ local db=$1 devs=$2 d
  sq "create database $db;" >/dev/null
  for ((d=1; d<=devs; d++)); do sq "create timeseries $db.d$d.s1 with datatype=int64;" >/dev/null; done
}
# 写一批（时间戳随批次递增，保证不同批落在同一时间分区）：du_write_tree_batch <db> <devs> <rows> <batch_no>
du_write_tree_batch(){ local db=$1 devs=$2 rows=$3 b=${4:-1}
  local base=$(( ($(date +%s) - 3600) * 1000 + b * 100000 ))
  bulk_tree "$db" "d" "$devs" "$rows" "$base" 10 >/dev/null || { warn "写入失败: $db 第 $b 批"; return 1; }
  sq "flush;" >/dev/null
}
# 表模型：建库 + 两张表（t1/t2）。用法：du_make_table_db <db> [表1名] [表2名]
# 注意 DDL 写法（已在 MD-B01 用例里验证过）：`CREATE TABLE <db>.<表> (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD)`
# 别写成 `(time timestamp, dev tag, v int64)` —— 那样建表会失败，而 CLI 退出码仍是 0（静默失败）。
du_make_table_db(){ local db=$1 t1=${2:-t1} t2=${3:-t2} out
  sql_lines_table "create database $db;" >/dev/null
  out=$(sqt "create table $db.$t1 (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD);")
  printf '%s' "$out" | grep -q 'successfully' || warn "建表 $db.$t1 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  out=$(sqt "create table $db.$t2 (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD);")
  printf '%s' "$out" | grep -q 'successfully' || warn "建表 $db.$t2 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  # 场景有效性硬校验：表必须真的存在，否则后续统计/合并都无从谈起
  local tbls; tbls=$(sqt "show tables from $db;")
  printf '%s' "$tbls" | grep -q "$t1" && pass "建表成功：$db.$t1" || fail "场景无效：$db.$t1 未建成（$(printf '%s' "$tbls" | tr '\n' ' ' | cut -c1-160)）"
  printf '%s' "$tbls" | grep -q "$t2" && pass "建表成功：$db.$t2" || fail "场景无效：$db.$t2 未建成"
}
# 写一批（表模型）：du_write_table_batch <db> <table> <devs> <rows> <batch_no>
# 写完会**校验写入可见**（`select count(*)`），失败即 fail（避免 CLI 退出码 0 造成的静默失败）
du_write_table_batch(){ local db=$1 tb=$2 devs=$3 rows=$4 b=${5:-1}
  local base=$(( ($(date +%s) - 3600) * 1000 + b * 100000 ))
  bulk_table "$db" "$tb" "$devs" "$rows" "$base" 10 >/dev/null || { fail "写入失败: $db.$tb 第 $b 批"; return 1; }
  sqt "flush;" >/dev/null
  local cnt; cnt=$(sqt "select count(*) from $db.$tb;" | table_rows | head -1 | awk -F'|' '{v=$2; gsub(/[^0-9]/,"",v); print v+0}')
  if [ "${cnt:-0}" -gt 0 ]; then
    log "    $db.$tb 第 $b 批写入可见：count=$cnt"
  else
    fail "场景无效：$db.$tb 写入后 count=0（第 $b 批）"
  fi
}
