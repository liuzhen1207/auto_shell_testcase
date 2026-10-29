#!/bin/bash
# ============================================================================
# TT-04 树模型 TTL 作用域 / 继承 / 覆盖 / 热更新 / UNSET 语义
#
#   覆盖（都是"作用域"维度，与 TT-01/02 的功能/清理正确性互补）：
#     1) 三级继承与覆盖：root.** → 库 → 设备；SHOW DEVICES 反映"生效值"（继承后的），
#        SHOW ALL TTL 反映"显式规则"；子级覆盖父级；另一库仍继承 root.**。
#     2) 规则热更新对**已写数据**立即生效（无需重启）：调小 TTL → 立即不可见。
#     3) UNSET 的语义：取消规则后，未被物理删除的过期数据**重新可见**
#        （因此本用例前段关闭 compaction；后段再打开，验证物理清理仍需 compaction）。
#     4) 预置规则作用于"后创建"的设备（先 SET TTL，再建库/建序列/写入）。
#     5) 边界：TTL=0（立即过期）、负数/非法 pattern 报 700、无规则 UNSET 报 508、TTL=INF 等价值。
#
#   为什么前段要关 compaction：RC4 里 expired_data_ratio 默认 0.3、max_expired_time 默认 1 个月，
#   而"过期即清理"（阈值笔误，见 docs/CALIBRATION.md 0.6）会在数据过期后很快物理删除，
#   那样就观察不到"UNSET 后重新可见"。
#
# 用法： bash ttl_tree_scope.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_tree_scope_${DATA_CONSENSUS}"

SMALL=${SCOPE_SMALL_MS:-5000}         # 小 TTL（热更新用）
TINY=0.000001
INF=9223372036854775807
DBA=root.scope_a                      # 继承/覆盖
DBB=root.scope_b                      # 对照组（只继承 root.**）
DBH=root.scope_hot                    # 热更新 / UNSET
DBF=root.scope_future                 # 预置规则
DBZ=root.scope_zero                   # TTL=0

log "--- 集群准备（前段关闭 compaction，观察查询侧语义；expired_data_ratio=$TINY） ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false" \
MAX_EXPIRED_TIME_MS=$INF EXPIRED_DATA_RATIO=$TINY ttl_cluster_prepare

log "--- 1) 造数据：A 库 3 设备、B 库 1 设备（都先写 1 点，时间戳现算） ---"
for db in $DBA $DBB; do sq "create database $db;" >/dev/null; done
for d in d1 d2 d3; do sq "create timeseries $DBA.$d.s1 with datatype=int64;" >/dev/null; done
sq "create timeseries $DBB.d1.s1 with datatype=int64;" >/dev/null
for d in d1 d2 d3; do sq "insert into $DBA.$d(time,s1) values($(now_ms), 1);" >/dev/null; done
sq "insert into $DBB.d1(time,s1) values($(now_ms), 1);" >/dev/null
sq "flush;" >/dev/null

log "--- 2) 三级继承/覆盖：root.** 600s → A 库 400s → A.d1 设备 200s ---"
out=$(sq "set ttl to root.** 600000;");      assert_contains "root.** 设 TTL 成功" "$out" "successfully"
out=$(sq "set ttl to $DBA 400000;");         assert_contains "库级覆盖成功" "$out" "successfully"
out=$(sq "set ttl to $DBA.d1 200000;");      assert_contains "设备级覆盖成功" "$out" "successfully"
dev=$(sq "show devices;"); log "  SHOW DEVICES: $(rows_of "$dev" | tr '\n' ' ')"
assert_eq "A.d1 生效 TTL（设备级覆盖）"      "$(device_ttl "$dev" "$DBA.d1")" "200000"
assert_eq "A.d2 生效 TTL（继承库级）"        "$(device_ttl "$dev" "$DBA.d2")" "400000"
assert_eq "A.d3 生效 TTL（继承库级）"        "$(device_ttl "$dev" "$DBA.d3")" "400000"
assert_eq "B.d1 生效 TTL（只继承 root.**）"  "$(device_ttl "$dev" "$DBB.d1")" "600000"
all=$(sq "show all ttl;"); log "  SHOW ALL TTL: $(rows_of "$all" | tr '\n' ' ')"
assert_eq "SHOW ALL TTL: root.** 规则"      "$(rule_ttl "$all" 'root.**')"          "600000"
assert_eq "SHOW ALL TTL: A 库规则"          "$(rule_ttl "$all" "$DBA")"             "400000"
assert_eq "SHOW ALL TTL: A.d1 设备规则"     "$(rule_ttl "$all" "$DBA.d1")"          "200000"
onA=$(sq "show ttl on $DBA;");               log "  SHOW TTL ON $DBA: $(rows_of "$onA" | tr '\n' ' ')"
assert_eq "SHOW TTL ON 库（只含显式规则）"   "$(rule_ttl "$onA" "$DBA")"             "400000"

log "--- 3) 规则热更新对已写数据立即生效（无需重启）：A.d2 从 400s 调到 ${SMALL}ms ---"
c=$(scalar "$(sq "select count(*) from $DBA.d2;")"); assert_scalar "调小前 A.d2 可见" "${c:-0}" "1"
out=$(sq "set ttl to $DBA.d2 $SMALL;"); assert_contains "热改小 TTL 成功" "$out" "successfully"
deadline=$(( $(date +%s) + SMALL/1000 + 30 )); got=""
while (( $(date +%s) < deadline )); do
  c=$(scalar "$(sq "select count(*) from $DBA.d2;")"); c=${c:-0}
  [ "$c" = "0" ] && { got=1; break; }
  sleep 3
done
[ "$got" = 1 ] && pass "调小 TTL 后已写数据立即不可见（热更新生效，未重启）" \
               || fail "调小 TTL 后数据仍可见（热更新未生效）"
c=$(scalar "$(sq "select count(*) from $DBA.d3;")"); assert_scalar "同库未改规则的 A.d3 仍可见" "${c:-0}" "1"

log "--- 4) UNSET 语义：取消规则后，未被物理删除的过期数据重新可见 ---"
out=$(sq "unset ttl from $DBA.d2;"); assert_contains "unset 设备规则成功" "$out" "successfully"
sleep 3
c=$(scalar "$(sq "select count(*) from $DBA.d2;")"); assert_scalar "UNSET 后过期数据重新可见" "${c:-0}" "1"
dev=$(sq "show devices;")
assert_eq "UNSET 后 A.d2 回到继承值" "$(device_ttl "$dev" "$DBA.d2")" "400000"

log "--- 5) 打开 compaction 后，过期数据最终会被物理清理（对比第 4 步） ---"
sq "set configuration 'enable_seq_space_compaction'='true';" >/dev/null
sq "set configuration 'enable_unseq_space_compaction'='true';" >/dev/null
sq "set ttl to $DBA.d2 $SMALL;" >/dev/null          # 再让它过期
sq "flush;" >/dev/null
sleep $(( SMALL/1000 + 20 ))
c=$(scalar "$(sq "select count(*) from $DBA.d2;")"); assert_scalar "再次过期后不可见" "${c:-0}" "0"
res=$(wait_settle_inc "$DBA" 1 "$CLEANUP_WAIT_SEC") || true
log "  A 库 settle 任务: $res"
[ "$(sum_over_db settle_task_for_db "$DBA")" -gt 0 ] && pass "compaction 打开后过期数据被 settle 清理" \
                                                     || warn "未见 settle 任务（compaction 刚打开，可能需再等一个检查周期）"

log "--- 6) 预置规则作用于后创建的设备：先 SET TTL，再建库/写数据 ---"
out=$(sq "set ttl to $DBF.** $SMALL;"); assert_contains "对尚不存在的库预置 TTL 成功" "$out" "successfully"
sq "create database $DBF;" >/dev/null
sq "create timeseries $DBF.f1.s1 with datatype=int64;" >/dev/null
sq "insert into $DBF.f1(time,s1) values($(now_ms), 1);" >/dev/null
sq "flush;" >/dev/null
dev=$(sq "show devices;")
assert_eq "预置规则对后创建的设备生效（SHOW DEVICES）" "$(device_ttl "$dev" "$DBF.f1")" "$SMALL"
sleep $(( SMALL/1000 + 25 ))
c=$(scalar "$(sq "select count(*) from $DBF.f1;")"); assert_scalar "后创建设备的数据已被 TTL 过滤" "${c:-0}" "0"

log "--- 7) 边界：TTL=0 / 非法值 / 无规则 UNSET ---"
sq "create database $DBZ;" >/dev/null
sq "create timeseries $DBZ.z1.s1 with datatype=int64;" >/dev/null
out=$(sq "set ttl to $DBZ 0;")
assert_contains "TTL=0 可设置" "$out" "successfully"
sq "insert into $DBZ.z1(time,s1) values($(now_ms), 1);" >/dev/null
sq "flush;" >/dev/null
sleep 8
c=$(scalar "$(sq "select count(*) from $DBZ.z1;")"); assert_scalar "TTL=0 时数据立即过期（查询 0）" "${c:-0}" "0"
dev=$(sq "show devices;"); log "  TTL=0 设备的 TTL(ms)=$(device_ttl "$dev" "$DBZ.z1")"
out=$(sq "set ttl to $DBZ.z1 -1;");           assert_error_code "负 TTL 被拒(700)" "$out" "700"
out=$(sq "set ttl to $DBZ.z1+.s1 1000;");     assert_error_code "非法 pattern 被拒(700)" "$out" "700"
out=$(sq "unset ttl from root.scope_norule;"); assert_error_code "无规则 UNSET 报 508" "$out" "508"
out=$(sq "set ttl to $DBZ.z1 9223372036854775807;"); assert_contains "TTL=Long.MAX 可设置（等价 INF）" "$out" "successfully"
dev=$(sq "show devices;"); log "  Long.MAX 设备的 TTL(ms)=$(device_ttl "$dev" "$DBZ.z1")"

log "--- 收尾三件套 ---"
post_checks "select count(*) from $DBB.d1;" tree
ttl_case_finish "" tree ""
