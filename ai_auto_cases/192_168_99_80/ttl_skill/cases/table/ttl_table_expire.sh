#!/bin/bash
# ============================================================================
# TB-02 表模型 TTL 过期清理正确性（数据正确性）
#   粒度：表 / 视图
#   覆盖：过期行查询过滤、TTL 内外边界、写入过期时间戳被拒(607)、
#         FLUSH 后物理删除（TsFile + Settle 日志）、TTL 放大后旧数据可写、
#         视图读取过期表、库级 TTL 不影响数据（表 TTL 才生效）
# 用法： bash ttl_table_expire.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_table_expire_${DATA_CONSENSUS}"

TDB=ttl_exp
TTL_MS=${TTL_CASE_MS:-60000}   # 节点间时钟可差 ±20s，TTL 必须远大于偏差；写入后先断言可见，再等过期
TTL_BIG=100000
tq(){ sql_lines_table "use $TDB;" "$@"; }
settle_cnt(){ sshx "$1" "grep -c 'Settle task deletes fully_dirty tsfile' $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
settle_total(){ local s=0 h; for h in "${DN[@]}"; do s=$((s + $(settle_cnt "$h"))); done; echo "${s:-0}"; }

log "--- 集群准备 ---"
ttl_cluster_prepare

log "--- 1) 造数据：t_exp(ttl=$TTL_MS) 两条当前时间数据 ---"
out=$(sql_lines_table "create database $TDB with (ttl=$TTL_MS);")
assert_contains "建库(带 ttl)成功" "$out" "successfully"
out=$(tq "create table t_exp (dev string tag, v double field) with (ttl=$TTL_MS);")
assert_contains "建表 t_exp 成功" "$out" "successfully"
out=$(tq "insert into t_exp (time, dev, v) values ($(now_ms), 'd1', 1);" "insert into t_exp (time, dev, v) values ($(now_ms), 'd2', 2);")
assert_contains "写入 2 行成功" "$out" "successfully"
out=$(tq "flush;")
assert_contains "flush 成功" "$out" "successfully"
c=$(scalar "$(sql_lines_table "select count(*) from $TDB.t_exp;")")
assert_scalar "TTL 未到期行数" "$c" "2"
before_files=$(tsfile_counts_all "$TDB")
log "  设 TTL 前 TsFile 数(各 DN): $before_files"

log "--- 2) 等过期后查询：应不可见 ---"
sleep $(( TTL_MS/1000 + 6 ))
c=$(scalar "$(sql_lines_table "select count(*) from $TDB.t_exp;")")
assert_scalar "$(( TTL_MS/1000 + 6 ))s 后过期行数" "$c" "0"

log "--- 3) 物理清理证据（Settle 全过期文件删除 / TsFile 下降） ---"
base_settle=$(sum_over settle_line_cnt); base_ttl=$(sum_over ttl_log_line_cnt); base_sel=$(sum_over ttl_selected_positive_cnt)
deadline=$(( $(date +%s) + CLEANUP_WAIT_SEC )); cleaned=0
while (( $(date +%s) < deadline )); do
  cur_settle=$(sum_over settle_line_cnt); cur_ttl=$(sum_over ttl_log_line_cnt); cur_sel=$(sum_over ttl_selected_positive_cnt); cur=$(tsfile_counts_all "$TDB")
  log "  等清理: ttlCheckLines=$cur_ttl(+$((cur_ttl-base_ttl))) selectedAllOutdated=$cur_sel(+$((cur_sel-base_sel))) settleDeleted=$cur_settle(+$((cur_settle-base_settle))) tsFiles=$cur"
  if [ "$cur_settle" -gt "$base_settle" ] || [ "$cur_sel" -gt "$base_sel" ] || [ "$cur" != "$before_files" ]; then cleaned=1; break; fi
  sleep 5
done
if [ "$cleaned" = "1" ]; then pass "过期清理已发生：settleDeleted +$((cur_settle-base_settle))，tsFiles $before_files -> $cur"
else fail "等 ${CLEANUP_WAIT_SEC}s 未见清理动作（settleDeleted +$((cur_settle-base_settle))，tsFiles=$cur）"; fi
log "  DN 日志摘录:"; for h in "${DN[@]}"; do ttl_log_tail "$h" | sed 's/^/    | /' >>"$OUT"; done

log "--- 4) 边界：TTL=$TTL_BIG 时 TTL 内可写可见、TTL 外被拒(607) ---"
NOW=$(now_ms)
out=$(tq "create table t_big (dev string tag, v double field) with (ttl=$TTL_BIG);")
assert_contains "建表 t_big 成功" "$out" "successfully"
out=$(tq "insert into t_big (time, dev, v) values ($NOW, 'd1', 11);" "insert into t_big (time, dev, v) values ($(( NOW - TTL_BIG/2 )), 'd1', 12);")
assert_contains "TTL 内两条写入成功" "$out" "successfully"
out=$(tq "insert into t_big (time, dev, v) values ($(( NOW - TTL_BIG - 5000 )), 'd1', 13);")
assert_error_code "TTL 外写入被拒(607)" "$out" "607"
c=$(scalar "$(sql_lines_table "select count(*) from $TDB.t_big;")")
assert_scalar "边界表可见行数" "$c" "2"

log "--- 5) TTL 放大为 INF 后允许写入更旧数据 ---"
out=$(tq "alter table t_big set properties ttl='INF';")
assert_contains "改 t_big 为 INF 成功" "$out" "successfully"
out=$(tq "insert into t_big (time, dev, v) values ($(( NOW - 86400000 )), 'd1', 14);")
assert_contains "INF 后可写 1 天前数据" "$out" "successfully"
c=$(scalar "$(sql_lines_table "select count(*) from $TDB.t_big;")")
assert_scalar "INF 后可见行数" "$c" "3"

log "--- 6) 视图读取过期表：过期后视图应查不到 ---"
out=$(tq "create table t_view_src (dev string tag, v double field) with (ttl=$TTL_MS);")
assert_contains "建 t_view_src 成功" "$out" "successfully"
out=$(tq "create writable view v_exp as select dev, v from t_view_src with (ttl=$TTL_MS);")
assert_contains "建视图 v_exp 成功" "$out" "successfully"
NOW=$(now_ms)
tq "insert into t_view_src (time, dev, v) values ($NOW, 'd1', 1);" >/dev/null
tq "flush;" >/dev/null
c=$(scalar "$(sql_lines_table "select count(*) from $TDB.v_exp;")")
assert_scalar "过期前视图行数" "$c" "1"
sleep $(( TTL_MS/1000 + 6 ))
c=$(scalar "$(sql_lines_table "select count(*) from $TDB.v_exp;")")
assert_scalar "过期后视图行数" "$c" "0"

log "--- 7) 集群面收尾检查（sync lag -> 副本一致性 -> 日志） ---"
post_checks "select count(*) from $TDB.t_big;" table
ttl_case_finish "" table ""
