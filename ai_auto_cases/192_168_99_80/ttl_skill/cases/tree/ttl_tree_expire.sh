#!/bin/bash
# ============================================================================
# TT-02 树模型 TTL 过期清理正确性（数据正确性）
#   粒度：database / 设备
#   覆盖：过期数据查询过滤、TTL 内外边界、写入过期时间戳被拒（607）、
#         FLUSH 后物理删除（TsFile 减少 + Settle 日志）、未设 TTL 库不受影响、
#         取消 TTL 后新数据不再被清理
# 用法： bash ttl_tree_expire.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_tree_expire_${DATA_CONSENSUS}"

DB=root.exp_t        # 设 TTL 的库
DBB=root.exp_b       # 边界库（大 TTL）
DBK=root.exp_keep    # 不设 TTL 的库
# 注意：3 个节点的系统时间彼此可差 ±20s（本环境实测），TTL 太小会导致"写完即过期/该过期还可见"，
# 因此默认用 60s 的观察窗口；需要更快可设 TTL_CASE_MS（须大于节点间最大时钟偏差）。
TTL_MS=${TTL_CASE_MS:-60000}
TTL_WAIT=$(( TTL_MS/1000 + 25 ))   # +25s：查询节点时钟可能比驱动机慢 ~22s
TTL_BIG=300000
settle_cnt(){ sshx "$1" "grep -c 'Settle task deletes fully_dirty tsfile' $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }
settle_total(){ local s=0 h; for h in "${DN[@]}"; do s=$((s + $(settle_cnt "$h"))); done; echo "${s:-0}"; }

log "--- 集群准备 ---"
ttl_cluster_prepare

log "--- 1) 造数据：两个设备各一条当前时间数据（时间戳现算，避免一写就过期） ---"
sq "create database $DB;" >/dev/null
sq "create database $DBK;" >/dev/null
sq "create timeseries $DB.d1.s1 with datatype=int64;"   >/dev/null
sq "create timeseries $DB.d2.s1 with datatype=int64;"   >/dev/null
sq "create timeseries $DBK.keep.s1 with datatype=int64;" >/dev/null
T1=$(now_ms); sq "insert into $DB.d1(time,s1) values($T1, 1);"   >/dev/null
T2=$(now_ms); sq "insert into $DB.d2(time,s1) values($T2, 2);"   >/dev/null
T3=$(now_ms); sq "insert into $DBK.keep(time,s1) values($T3, 9);" >/dev/null
out=$(sq "flush;")
assert_contains "flush 成功" "$out" "successfully"
# 清理判据基线必须在"数据过期之前"采集，否则 TTL 选中/删除可能已经发生，基线之后看不到增量
base_settle=$(sum_over settle_line_cnt); base_ttl=$(sum_over ttl_log_line_cnt); base_sel=$(sum_over ttl_selected_positive_cnt)
after_files=$(tsfile_counts_all "$DB")
c1=$(scalar "$(sq "select count(*) from $DB.d1;")")
c2=$(scalar "$(sq "select count(*) from $DB.d2;")")
assert_scalar "设 TTL 前 d1 点数" "$c1" "1"
assert_scalar "设 TTL 前 d2 点数" "$c2" "1"
before_files=$(tsfile_counts_all "$DB")
log "  设 TTL 前 TsFile 数(各 DN): $before_files"

log "--- 2) 设置库级 TTL=$TTL_MS（先大后小：先用 $TTL_BIG 验证可见性，再用 $TTL_MS 验证过期） ---"
outs=$(sq "set ttl to $DB $TTL_BIG;")
assert_contains "set ttl 成功" "$outs" "successfully"
sq "flush;" >/dev/null
c=$(scalar "$(sq "select count(*) from $DB.d1;")")
assert_scalar "TTL=$TTL_BIG 时 d1 可见" "$c" "1"
outd=$(sq "show devices;")
assert_eq "d1 设备 TTL" "$(device_ttl "$outd" "$DB.d1")" "$TTL_BIG"

log "--- 3) 调小 TTL=$TTL_MS，等过期后查询：应全部不可见（查询侧立即过滤） ---"
sq "set ttl to $DB $TTL_MS;" >/dev/null
sleep "$TTL_WAIT"
c=$(scalar "$(sq "select count(*) from $DB.d1;")")
assert_scalar "${TTL_WAIT}s 后 d1 过期点数" "$c" "0"
c=$(scalar "$(sq "select count(*) from $DB.d2;")")
assert_scalar "${TTL_WAIT}s 后 d2 过期点数" "$c" "0"

log "--- 4) 未设 TTL 的库不受影响 ---"
ck=$(scalar "$(sq "select count(*) from $DBK.keep;")")
assert_scalar "未设 TTL 库数据仍在" "$ck" "1"

log "--- 5) 物理清理：等 TTL 检查 + Settle 删除全过期 TsFile ---"
deadline=$(( $(date +%s) + CLEANUP_WAIT_SEC )); cleaned=0
while (( $(date +%s) < deadline )); do
  cur_settle=$(sum_over settle_line_cnt); cur_ttl=$(sum_over ttl_log_line_cnt); cur_sel=$(sum_over ttl_selected_positive_cnt); cur=$(tsfile_counts_all "$DB")
  log "  等清理: ttlCheckLines=$cur_ttl(+$((cur_ttl-base_ttl))) selectedAllOutdated=$cur_sel(+$((cur_sel-base_sel))) settleDeleted=$cur_settle(+$((cur_settle-base_settle))) tsFiles=$cur"
  if [ "$cur_settle" -gt "$base_settle" ] || [ "$cur_sel" -gt "$base_sel" ] || [ "$cur" != "$after_files" ]; then cleaned=1; break; fi
  sleep 5
done
if [ "$cleaned" = "1" ]; then
  pass "过期清理已发生：settleDeleted +$((cur_settle-base_settle))，tsFiles $after_files -> $cur"
else
  fail "等 ${CLEANUP_WAIT_SEC}s 未见清理动作（settleDeleted +$((cur_settle-base_settle))，tsFiles=$cur）"
fi
log "  DN 日志摘录:"; for h in "${DN[@]}"; do ttl_log_tail "$h" | sed 's/^/    | /' >>"$OUT"; done

log "--- 6) 边界：TTL=$TTL_BIG 时，未过期时间戳可写可见，已过期时间戳被拒(607) ---"
NOW=$(now_ms)
sq "create database $DBB;" >/dev/null
sq "create timeseries $DBB.d1.s1 with datatype=int64;" >/dev/null
sq "set ttl to $DBB $TTL_BIG;" >/dev/null
sq "insert into $DBB.d1(time,s1) values($NOW, 11);" >/dev/null
out=$(sq "insert into $DBB.d1(time,s1) values($(( NOW - TTL_BIG/2 )), 12);")
assert_contains "TTL 内(now-TTL/2)可写" "$out" "successfully"
out=$(sq "insert into $DBB.d1(time,s1) values($(( NOW - TTL_BIG - 5000 )), 13);")
assert_error_code "TTL 外(now-TTL-5s)写入被拒" "$out" "607"
c=$(scalar "$(sq "select count(*) from $DBB.d1;")")
assert_scalar "边界库可见点数(2 条存活)" "$c" "2"

log "--- 7) 取消 TTL 后新写入的数据不再被清理 ---"
DBU=root.exp_unset
sq "create database $DBU;" >/dev/null
sq "create timeseries $DBU.d1.s1 with datatype=int64;" >/dev/null
sq "set ttl to $DBU $TTL_MS;" >/dev/null
sq "insert into $DBU.d1(time,s1) values($(now_ms), 1);" >/dev/null
sq "flush;" >/dev/null
outd=$(sq "show devices;")
assert_eq "unset 用例设备 TTL 已生效" "$(device_ttl "$outd" "$DBU.d1")" "$TTL_MS"
sleep "$TTL_WAIT"
c=$(scalar "$(sq "select count(*) from $DBU.d1;")")
assert_scalar "取消前已过期不可见" "$c" "0"
out=$(sq "unset ttl from $DBU;")
assert_contains "unset ttl 成功" "$out" "successfully"
sq "insert into $DBU.d1(time,s1) values($(now_ms), 2);" >/dev/null
sq "flush;" >/dev/null
sleep "$TTL_WAIT"
c=$(scalar "$(sq "select count(*) from $DBU.d1;")")
assert_scalar "取消 TTL 后数据不再被清理" "$c" "1"

log "--- 8) 集群面收尾检查（sync lag -> 副本一致性 -> 日志） ---"
post_checks "select count(*) from $DBK.keep;" tree
ttl_case_finish "" tree ""
