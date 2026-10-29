#!/bin/bash
# ============================================================================
# MD-T05 树模型元数据 DDL 的失败路径与错误码（"不该成功的必须失败"）
#
# 为什么单独一条用例：元数据 DDL 的正向路径容易过，真正的风险在于
#   * 非法输入被**静默接受**（写脏元数据）
#   * 失败后留下半成品元数据（原子性）
#   * 错误码/提示与文档不符
# 本用例把这些逐条钉住；每条都要求"报错 + 错误码"，并在之后复查元数据**没有被改脏**。
#
# 错误码来源：v20121rc5_1003_aaf460d 实测（docs/DDL_PROBE_RESULT*.tsv）
#   501 库已存在 / 503 路径已存在 / 507 属性或模板非法 / 508 路径不存在 /
#   513 无模板 / 515 模板占用中 / 700 语法或操作不支持 / 701 语义不支持 / 820 口令过短
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

DB="root.${MD_PREFIX}_t05"
md_case_init "md_tree_ddl_negative"
md_cluster_prepare

log "--- 清理历史对象 ---"
drop_tree_db "$DB"
assert_ok "建库" "$(sq "CREATE DATABASE $DB;")"
assert_ok "建时序" "$(sq "CREATE TIMESERIES $DB.d1.s1 INT32;")"
before_ts=$(md_rows "$(sq "SHOW TIMESERIES $DB.**;")")
before_db=$(md_rows "$(sq 'SHOW DATABASES;')")

# ---------------------------------------------------------------------------
log "=== 1) 库级失败路径 ==="
assert_error "重复建库 501"                "$(sq "CREATE DATABASE $DB;")" '501'
assert_error "删不存在的库 508"            "$(sq "DROP DATABASE root.${MD_PREFIX}_nosuch;")" '508'
assert_error "库属性用未知键 700"          "$(sq "CREATE DATABASE root.${MD_PREFIX}_t05x WITH NO_SUCH=1;")" '700'
assert_error "库属性用副本数（树模型不支持）700" "$(sq "CREATE DATABASE root.${MD_PREFIX}_t05x WITH SCHEMA_REPLICATION_FACTOR=3;")" '700'
assert_error "CREATE DATABASE IF NOT EXISTS 700" "$(sq "CREATE DATABASE IF NOT EXISTS root.${MD_PREFIX}_t05x;")" '700'
assert_error "DROP DATABASE IF EXISTS 700"       "$(sq "DROP DATABASE IF EXISTS root.${MD_PREFIX}_nosuch;")" '700'
assert_error "ALTER DATABASE TTL 明确不支持 525"  "$(sq "ALTER DATABASE $DB WITH TTL=1000;")" '525'
assert_error "库属性不是整数 700"          "$(sq "CREATE DATABASE root.${MD_PREFIX}_t05x WITH TTL=abc;")" '700'

log "=== 2) 时序级失败路径 ==="
assert_error "重复建时序 503"              "$(sq "CREATE TIMESERIES $DB.d1.s1 INT32;")" '503'
assert_error "非法数据类型 701"            "$(sq "CREATE TIMESERIES $DB.d2.s1 WITH DATATYPE=NOTATYPE;")" '701'
assert_error "编码与类型不匹配 507"        "$(sq "CREATE TIMESERIES $DB.d2.s1 WITH DATATYPE=TEXT, ENCODING=RLE;")" '507'
assert_error "未知属性 COMMENT 507"        "$(sq "CREATE TIMESERIES $DB.d2.s1 WITH DATATYPE=INT32, ENCODING=RLE, COMMENT='x';")" '507'
assert_error "CREATE ... ALIAS 507"        "$(sq "CREATE TIMESERIES $DB.d2.s1 INT32 ALIAS=a1;")" '507'
assert_error "CREATE TIMESERIES IF NOT EXISTS 700" "$(sq "CREATE TIMESERIES IF NOT EXISTS $DB.d1.s1 INT32;")" '700'
assert_error "一次建多条时序 700"          "$(sq "CREATE TIMESERIES $DB.d3.s1 INT32, $DB.d3.s2 INT64;")" '700'
assert_error "DROP 不存在的时序 508"       "$(sq "DROP TIMESERIES $DB.d9.s9;")" '508'
assert_error "ALTER 不存在的时序"      "$(sq "ALTER TIMESERIES $DB.d9.s9 SET DATA TYPE INT64;")" ''
assert_error "ALTER TIMESERIES 用 WITH 前缀（旧写法）700" "$(sq "ALTER TIMESERIES $DB.d1.s1 WITH DATATYPE=INT64;")" '700'

log "=== 3) 模板级失败路径 ==="
assert_error "SHOW SCHEMA TEMPLATE 单数（语法错误）700" "$(sq "SHOW SCHEMA TEMPLATE;")" '700'
assert_error "DROP 不存在的模板 507"       "$(sq "DROP SCHEMA TEMPLATE nosuchtpl_neg;")" '507'
assert_error "CREATE SCHEMA TEMPLATE IF NOT EXISTS 700" "$(sq "CREATE SCHEMA TEMPLATE IF NOT EXISTS tpl_neg (s1 INT32);")" '700'
assert_error "ALIGNED 写在测量列表之后（语法错误）700" \
  "$(sq "CREATE SCHEMA TEMPLATE tpl_neg2 (a1 INT32) ALIGNED;")" '700'
assert_error "UNSET 不存在的模板 507"      "$(sq "UNSET SCHEMA TEMPLATE nosuchtpl_neg FROM $DB;")" '507'

log "=== 4) 其它 DDL 的「未支持」行为（记录产品当前边界） ==="
assert_error "CREATE FUNCTION 缺 AS 子句" "$(sq "CREATE FUNCTION f_neg AS;")" ''
assert_error "DROP 不存在的 UDF 301"       "$(sq "DROP FUNCTION nosuchfunc_neg;")" '301'
assert_error "DROP 不存在的触发器 1301"    "$(sq "DROP TRIGGER nosuchtrg_neg;")" '1301'
assert_error "计算点 DDL 未支持 700"       "$(sq "CREATE CALCULATION POINT $DB.cp1 AS s1 + 1 'm1';")" '700'
assert_error "服务管理 SQL 未支持 305"     "$(sq "CREATE SERVICE svc_neg AS 'com.example.X';")" '305'
assert_error "START TRIGGER 未支持 700"    "$(sq "START TRIGGER nosuchtrg_neg;")" '700'
assert_error "建用户口令过短 820"          "$(sq "CREATE USER ${MD_PREFIX}negu 'short';")" '820'
assert_error "DROP 不存在的用户 804"       "$(sq "DROP USER ${MD_PREFIX}nosuchu;")" '804'
assert_error "DROP 不存在的角色 808"       "$(sq "DROP ROLE ${MD_PREFIX}nosuchr;")" '808'

log "=== 5) 失败之后元数据没有被改脏（原子性） ==="
after_ts=$(md_rows "$(sq "SHOW TIMESERIES $DB.**;")")
assert_set_eq "时序集合与失败前一致" "$after_ts" "$before_ts"
after_db=$(md_rows "$(sq 'SHOW DATABASES;')")
assert_set_eq "库集合与失败前一致（没有多出 t05x）" "$after_db" "$before_db"
assert_set_lacks "没有残留 root.md_t05x" "$(md_names "$(sq 'SHOW DATABASES;')")" "root.${MD_PREFIX}_t05x"
assert_set_lacks "没有残留时序 $DB.d2.s1" "$(md_names "$(sq "SHOW TIMESERIES $DB.**;")")" "$DB.d2.s1"
assert_set_lacks "没有残留时序 $DB.d3.s1" "$(md_names "$(sq "SHOW TIMESERIES $DB.**;")")" "$DB.d3.s1"

log "--- 清理 ---"
drop_templates tpl_neg tpl_neg2
drop_tree_db "$DB"
q_tree "DROP DATABASE root.${MD_PREFIX}_t05x"

md_case_finish tree "SHOW TIMESERIES $DB.**;"
