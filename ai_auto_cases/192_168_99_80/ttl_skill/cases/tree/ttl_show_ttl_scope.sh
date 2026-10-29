#!/bin/bash
# ============================================================================
# TT-05 TDB-444 回归门禁：`SHOW TTL ON <path>.**` 把权限范围路径当查询路径下发
#
#   缺陷（PLM TDB-444，V2.0.12.1）：超级用户执行 `SHOW TTL ON root.tree.g_0.**` 时，
#   下发的查询路径变成 `root.**`（权限范围路径），于是**返回一堆不相干的全局 TTL 规则**，
#   而不是该子树下的规则。
#
#   判据（区分"修好"与"没修好"的关键是"**不得出现不相干的路径**"，而不是"包含本设备规则"——
#   因为缺陷版本会把所有规则都吐出来，"包含"类断言照样通过）：
#     - `SHOW TTL ON <db>.<dev>.**` 的输出里 **不得** 出现：不相干库的规则、`root.**` 全局规则；
#     - 应出现本设备子树下的规则；
#     - 对照：`SHOW TTL ON <db>.<dev>`（无 `.**`）本来就正确，只返回该路径规则。
#
# 用法： bash ttl_show_ttl_scope.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_show_ttl_scope_${DATA_CONSENSUS}"

DBR=root.t44_rel        # 相关库（被测路径所在）
DBO=root.t44_other      # 不相干库（干扰项）
T_REL=200000
T_DEV=300000
T_OTHER=400000
T_ROOT=100000

log "--- 集群准备 ---"
ttl_cluster_prepare

log "--- 1) 造规则：全局 root.** + 相关库/设备 + 不相干库 ---"
sq "create database $DBR;" >/dev/null
sq "create database $DBO;" >/dev/null
sq "create timeseries $DBR.g_0.s1 with datatype=int64;" >/dev/null
sq "create timeseries $DBO.x_0.s1 with datatype=int64;" >/dev/null
out=$(sq "set ttl to root.** $T_ROOT;");        assert_contains "全局 root.** 规则" "$out" "successfully"
out=$(sq "set ttl to $DBR $T_REL;");           assert_contains "相关库规则" "$out" "successfully"
out=$(sq "set ttl to $DBR.g_0 $T_DEV;");       assert_contains "相关设备规则" "$out" "successfully"
out=$(sq "set ttl to $DBO $T_OTHER;");         assert_contains "不相干库规则" "$out" "successfully"
all=$(sq "show all ttl;")
log "  SHOW ALL TTL（基线，含全部规则）：$(rows_of "$all" | tr '\n' ' ')"
assert_eq "基线里相关设备规则存在" "$(rule_ttl "$all" "$DBR.g_0")" "$T_DEV"
assert_eq "基线里不相干库规则存在" "$(rule_ttl "$all" "$DBO")" "$T_OTHER"

log "--- 2) 复现点：SHOW TTL ON $DBR.g_0.** （TDB-444） ---"
out1=$(sq "show ttl on $DBR.g_0.**;")
log "  输出: $(rows_of "$out1" | tr '\n' ' ')"
assert_not_contains "不得返回不相干库的规则(TDB-444)" "$out1" "$DBO"
assert_not_contains "不得返回全局 root.** 规则(TDB-444)" "$out1" '\|[[:space:]]*root\.\*\*[[:space:]]*\|'
assert_contains     "应包含本设备子树下的规则" "$out1" "$DBR\.g_0"

log "--- 3) 同类：SHOW TTL ON $DBR.** 也不得返回不相干库 ---"
out2=$(sq "show ttl on $DBR.**;")
log "  输出: $(rows_of "$out2" | tr '\n' ' ')"
assert_not_contains "库级 .** 不得返回不相干库的规则" "$out2" "$DBO"

log "--- 4) 对照组：无 .** 的精确路径本来就正确 ---"
out3=$(sq "show ttl on $DBR.g_0;")
log "  输出: $(rows_of "$out3" | tr '\n' ' ')"
assert_eq "精确路径只返回本设备规则" "$(rule_ttl "$out3" "$DBR.g_0")" "$T_DEV"
assert_not_contains "精确路径不含不相干库" "$out3" "$DBO"

log "--- 5) 规则继承/生效值不受影响（旁证） ---"
dev=$(sq "show devices;")
assert_eq "g_0 生效 TTL=设备规则" "$(device_ttl "$dev" "$DBR.g_0")" "$T_DEV"

log "--- 收尾三件套 ---"
post_checks "select count(*) from $DBR.g_0;" tree
ttl_case_finish "" tree ""
