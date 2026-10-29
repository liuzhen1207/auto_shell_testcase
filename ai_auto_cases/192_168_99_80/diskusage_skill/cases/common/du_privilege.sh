#!/bin/bash
# ============================================================================
# DU-05 权限与错误路径
#   覆盖（需求文档 §3.3.3.1 访问控制：仅允许拥有 SYSTEM 权限的用户执行）：
#     1) 无 SYSTEM 权限的用户执行 `show disk_usage` 必须被拒（不得返回统计结果）
#     2) 授予 SYSTEM 权限后同一用户可正常执行（树模型接口）
#     3) 非法 pattern（不以 root 开头）报错
#     4) 表模型接口 information_schema.table_disk_usage 的越权行为（记录：本轮以 SYSTEM 授权为准）
#     5) 收尾回收权限并删用户
# 用法： bash du_privilege.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/du.sh"
du_load_env
du_parse_args "$@"
du_case_init "du_privilege_${DATA_CONSENSUS}"

DB=root.dupriv
U=du_priv_u1
# 注意：产品要求密码长度 >= 12（实测 <12 报 `820: The length of password must be greater than or equal to 12`），
# 这里用 13 位；建用户后用例会立刻校验用户是否真的建成（避免后续权限断言落在"用户不存在"的假失败上）。
PW='DuPriv@2026!!'
DEVS=${DU_DEVS:-4}
ROWS=${DU_ROWS:-200}

log "--- 集群准备（关合并）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false" du_cluster_prepare

log "--- 造数据：$DB（$DEVS 设备）---"
du_make_tree_db "$DB" "$DEVS"
du_write_tree_batch "$DB" "$DEVS" "$ROWS" 1
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"

log "--- 建用户 $U（无任何权限）---"
sq "drop user $U;" >/dev/null 2>&1 || true
OUT_MK=$(sqt "create user $U '$PW';")
log "  create user：$(printf '%s' "$OUT_MK" | tr '\n' ' ' | cut -c1-160)"
if sq "list user;" | grep -q "$U"; then
  pass "用户 $U 创建成功（LIST USER 可见）"
else
  fail "场景无效：用户 $U 未创建成功（后续权限断言无意义）"
fi

log "--- 1) 无权限用户执行统计查询（应被拒）---"
OUT_NO=$(du_tree_as "$U" "$PW" "show disk_usage from root.**;")
log "  原始输出：$(printf '%s' "$OUT_NO" | tr '\n' ' ' | cut -c1-260)"
N_NO=$(du_tree_row_cnt "$OUT_NO"); N_NO=${N_NO:-0}
if printf '%s\n' "$OUT_NO" | grep -qE 'IoTDBSQLException|permission|拒绝|no privilege|[0-9]{3}:'; then
  pass "无 SYSTEM 权限时被拒绝：$(printf '%s' "$OUT_NO" | grep -oE '([0-9]{3}: [^"]{0,80}|IoTDBSQLException[^"]{0,80})' | head -1)"
elif [ "$N_NO" -gt 0 ]; then
  fail "无 SYSTEM 权限的用户竟然拿到了统计结果（$N_NO 行）——权限门控失效"
else
  warn "无权限时的表现不是明确报错，输出：$(printf '%s' "$OUT_NO" | tr '\n' ' ' | cut -c1-160)（记录，供研发确认）"
fi

log "--- 2) 授予 SYSTEM 权限后再执行 ---"
OUT_GRANT=$(sq "grant system on root.** to user $U;")
log "  grant system：$(printf '%s' "$OUT_GRANT" | tr '\n' ' ' | cut -c1-160)"
OUT_YES=$(du_tree_as "$U" "$PW" "show disk_usage from root.**;")
CNT_YES=$(du_tree_row_cnt "$OUT_YES")
log "  授权后：$CNT_YES 行；表头 $(du_header "$OUT_YES")"
if printf '%s\n' "$OUT_YES" | grep -qE 'IoTDBSQLException|[0-9]{3}:'; then
  fail "授予 SYSTEM 权限后仍无法执行：$(printf '%s' "$OUT_YES" | grep -oE '[0-9]{3}: [^"]*' | head -1)"
else
  pass "授予 SYSTEM 权限后可以执行（$CNT_YES 行）"
  assert_contains "授权后结果含本库" "$OUT_YES" "$DB"
fi

log "--- 3) 非法 pattern（不以 root 开头）应报错 ---"
OUT_BAD=$(sq "show disk_usage from ${DB#root.}.**;")
log "  原始输出：$(printf '%s' "$OUT_BAD" | tr '\n' ' ' | cut -c1-200)"
if printf '%s\n' "$OUT_BAD" | grep -qE 'IoTDBSQLException|[0-9]{3}:|Error'; then
  pass "非法 pattern 报错：$(printf '%s' "$OUT_BAD" | grep -oE '[0-9]{3}: [^"]{0,60}' | head -1)"
else
  fail "非法 pattern 未报错：$(printf '%s' "$OUT_BAD" | tr '\n' ' ' | cut -c1-160)"
fi

log "--- 4) 表模型接口的越权行为（记录）---"
OUT_T_NO=$(sqt_as "$U" "$PW" "select * from information_schema.table_disk_usage;")
T_NO_ERR=$(printf '%s\n' "$OUT_T_NO" | grep -oE '[0-9]{3}: [^"]{0,60}' | head -1)
T_NO_CNT=$(du_table_row_cnt "$OUT_T_NO")
log "  以 $U（已授 SYSTEM）执行表模型统计：$T_NO_CNT 行；错误=[${T_NO_ERR:-无}]"
if [ -z "$T_NO_ERR" ] && [ "${T_NO_CNT:-0}" -ge 0 ]; then
  log "  （该用户已授 SYSTEM，表模型查询可执行，属预期；未单独验证表模型侧的权限门控）"
else
  warn "已投 SYSTEM 后表模型统计仍被拒：[${T_NO_ERR}]（记录，供研发确认表模型侧权限口径）"
fi
# 未授权用户（新建一个）对表模型接口的越权检查
U2=du_priv_u2
sqt "drop user $U2;" >/dev/null 2>&1 || true
sqt "create user $U2 '$PW';" >/dev/null 2>&1
OUT_T2=$(sqt_as "$U2" "$PW" "select * from information_schema.table_disk_usage;")
T2_ERR=$(printf '%s\n' "$OUT_T2" | grep -oE '[0-9]{3}: [^"]{0,60}' | head -1)
T2_CNT=$(du_table_row_cnt "$OUT_T2")
log "  以零权限用户 $U2 执行表模型统计：$T2_CNT 行；错误=[${T2_ERR:-无}]"
if [ -n "$T2_ERR" ] && [ "${T2_CNT:-0}" -eq 0 ]; then
  pass "零权限用户的表模型统计被拒（$T2_ERR）"
elif [ "${T2_CNT:-0}" -gt 0 ]; then
  fail "零权限用户拿到了表模型统计结果（$T2_CNT 行）——权限门控失效"
else
  warn "零权限用户的表模型统计既没报错也没返回行：$(printf '%s' "$OUT_T2" | tr '\n' ' ' | cut -c1-140)"
fi

log "--- 5) 回收权限并删用户 ---"
sq "revoke system on root.** from user $U;" >/dev/null 2>&1 || warn "revoke $U 失败"
sq "drop user $U;"  >/dev/null 2>&1 || warn "drop $U 失败"
sqt "drop user $U2;" >/dev/null 2>&1 || warn "drop $U2 失败"
log "  收尾后 root 执行统计：$(du_tree_row_cnt "$(du_tree root.**)") 行（root 不受影响）"

log "--- 收尾三件套 ---"
post_checks "select count(*) from $DB.d1.s1;" tree
ttl_case_finish "" tree ""
