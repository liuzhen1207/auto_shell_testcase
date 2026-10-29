#!/bin/bash
# ============================================================================
# TT-01 树模型 TTL 基本功能与参数值
#   粒度：database / 设备 / 序列
#   覆盖：SET/UNSET/SHOW、前缀路径规则、INF、继承与优先级、库判定特判、
#         SHOW DEVICES 的 TTL 列、SHOW DATABASES 无 TTL 列、删库删序列后规则保留
# 用法： bash ttl_tree_basic.sh [--consensus IoTConsensus|IoTConsensusV2] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_tree_basic_${DATA_CONSENSUS}"

DB1=root.basic_t          # 普通库
DB2=root.basic_u          # 用于"先建库后设 TTL"的库判定

log "--- 集群准备 ---"
ttl_cluster_prepare

# ---------------------------------------------------------------------------
log "--- 1) 库不存在时设 TTL：只写一条规则 ---"
out=$(sq "set ttl to $DB1 60000;")
assert_contains "set ttl 成功" "$out" "successfully"
sq "create database $DB1;" >/dev/null 2>&1
out=$(sq "show all ttl;")
assert_eq "库不存在时 $DB1 规则值" "$(rule_ttl "$out" "$DB1")" "60000"
assert_eq "此时无 $DB1.** 规则" "$(rule_ttl "$out" "$DB1.**")" ""

log "--- 2) 库已存在时设 TTL：写 $DB1 与 $DB1.** 两条规则 ---"
sq "set ttl to $DB1 120000;" >/dev/null
out=$(sq "show all ttl;")
assert_eq "$DB1 规则值(库级)"      "$(rule_ttl "$out" "$DB1")"    "120000"
assert_eq "$DB1.** 规则值(库级)"   "$(rule_ttl "$out" "$DB1.**")" "120000"

log "--- 3) 前缀路径规则校验（非法路径应报 ILLEGAL_PARAMETER/303） ---"
out=$(sq "set ttl to $DB1.* 1000;")
assert_error_code "中间单星路径被拒" "$out" "303"
out=$(sq "set ttl to $DB1.**.d1 1000;")
assert_error_code "** 不在结尾被拒" "$out" "303"

log "--- 4) 设备级 / 序列级 / INF ---"
sq "create timeseries $DB1.d1.s1 with datatype=int64;"  >/dev/null
sq "create timeseries $DB1.d2.s1 with datatype=int64;"  >/dev/null
out=$(sq "set ttl to $DB1.d1 5000;")
assert_contains "设备级 set ttl 成功" "$out" "successfully"
out=$(sq "show devices;")
assert_eq "d1 命中设备级规则"  "$(device_ttl "$out" "$DB1.d1")" "5000"
assert_eq "d2 继承库级规则"    "$(device_ttl "$out" "$DB1.d2")" "120000"
out=$(sq "show ttl on $DB1.d1;")
assert_eq "SHOW TTL ON 设备路径" "$(rule_ttl "$out" "$DB1.d1")" "5000"

out=$(sq "set ttl to $DB1.d2 INF;")
assert_contains "INF 设置成功" "$out" "successfully"
out=$(sq "show devices;")
assert_eq "d2 TTL=INF" "$(device_ttl "$out" "$DB1.d2")" "INF"

log "--- 5) 序列级 TTL 不生效（不命中任何设备） ---"
out=$(sq "set ttl to $DB1.d1.s1 1000;")
assert_contains "序列级 set ttl 语法通过" "$out" "successfully"
out=$(sq "show devices;")
assert_eq "d1 设备 TTL 仍为设备级规则" "$(device_ttl "$out" "$DB1.d1")" "5000"
sq "unset ttl from $DB1.d1.s1;" >/dev/null 2>&1

log "--- 6) SHOW DATABASES 不含 TTL 列；SHOW ALL TTL 含全局 root.** ---"
out=$(sq "show databases;")
assert_not_contains "SHOW DATABASES 无 TTL 列" "$out" "TTL\(ms\)"
out=$(sq "show all ttl;")
assert_eq "全局 root.** 规则存在" "$(rule_ttl "$out" "root.**")" "INF"

log "--- 7) UNSET：设备级回落到库级；不存在规则报 508；新旧语法等价 ---"
sq "unset ttl from $DB1.d1;" >/dev/null
out=$(sq "show devices;")
assert_eq "unset 后 d1 回落到库级" "$(device_ttl "$out" "$DB1.d1")" "120000"
out=$(sq "unset ttl from $DB1.notexist;")
assert_error_code "unset 不存在的规则报 508" "$out" "508"
out=$(sq "unset ttl to $DB1.d2;")     # 旧语法 TO
assert_contains "旧语法 unset ttl to 可用" "$out" "successfully"
out=$(sq "show devices;")
assert_eq "旧语法 unset 后 d2 回落到库级" "$(device_ttl "$out" "$DB1.d2")" "120000"

log "--- 9) 数据面副本一致性（写入少量数据后三副本比对） ---"
sq "insert into $DB1.d1(time,s1) values($(now_ms), 1);" >/dev/null 2>&1
sq "insert into $DB1.d2(time,s1) values($(now_ms), 2);" >/dev/null 2>&1
out=$(sq "flush;")
log "  flush: $(printf '%s' "$out" | head -1)"
log "--- 10) 集群面收尾检查（sync lag -> 副本一致性 -> 日志） ---"
post_checks "select count(*) from $DB1.**;" tree

log "--- 11) 删序列 / 删库后 TTL 规则仍保留 ---"
sq "delete timeseries $DB1.d1.s1;" >/dev/null 2>&1
out=$(sq "show all ttl;")
assert_eq "删序列后规则仍在" "$(rule_ttl "$out" "$DB1")" "120000"
sq "drop database $DB1;" >/dev/null 2>&1
out=$(sq "show all ttl;")
assert_eq "删库后规则仍在"   "$(rule_ttl "$out" "$DB1")" "120000"

log "--- 12) 清理本用例设置的规则 ---"
for p in "$DB1" "$DB1.**" "$DB1.d2"; do sq "unset ttl from $p;" >/dev/null 2>&1 || true; done
sq "drop database $DB2;" >/dev/null 2>&1 || true
out=$(sq "show all ttl;")
assert_eq "清理后 $DB1 规则已移除" "$(rule_ttl "$out" "$DB1")" ""

ttl_case_finish "" tree ""
