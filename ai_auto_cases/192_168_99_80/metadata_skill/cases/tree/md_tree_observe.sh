#!/bin/bash
# ============================================================================
# MD-T04 树模型"元数据观测面"闭环（集群/区域/时隙/会话/版本）
#
# 覆盖：
#   SHOW CLUSTER / SHOW CLUSTER DETAILS / SHOW CLUSTERID / SHOW DATANODES / SHOW CONFIGNODES
#   SHOW AVAILABLE URLS / SHOW REGIONS / SHOW SCHEMA REGIONS / SHOW DATA REGIONS OF DATABASE
#   SHOW SCHEMA REGIONID WHERE DATABASE= / SHOW TIMESLOTID WHERE DEVICE=
#   SHOW VARIABLES / SHOW VERSION / SHOW ACTIVATION / SHOW SYSTEM INFO / SHOW QUERIES
#   SHOW CURRENT_USER / SHOW CURRENT_SQL_DIALECT / SHOW CURRENT_TIMESTAMP
#
# 重点判据（做过就会发现的元数据特性）：
#   1) 数据区域是**懒创建**的：库里只有时序、没写数据时 SHOW DATA REGIONS 为空；
#      写入并 flush 之后才出现 DataRegion。
#   2) SHOW VERSION 的 commit 必须与安装目录名里的 commit 一致（环境自检）。
#   3) SHOW CLUSTER 的节点数与 CN/DN 列表一致，且都 Running + ACTIVATED。
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

DB="root.${MD_PREFIX}_t04"
WANT_NODES=$(( ${#CN[@]} + ${#DN[@]} ))
md_case_init "md_tree_observe"
md_cluster_prepare

log "--- 清理历史对象 ---"
drop_tree_db "$DB"
assert_ok "建库" "$(sq "CREATE DATABASE $DB;")"
assert_ok "建时序" "$(sq "CREATE TIMESERIES $DB.d1.s1 INT32;")"

# ---------------------------------------------------------------------------
log "=== 1) 集群拓扑类元数据 ==="
cluster=$(sq 'SHOW CLUSTER;')
assert_eq "SHOW CLUSTER 节点数 == CN+DN" "$(md_count "$(md_rows "$cluster")")" "$WANT_NODES"
assert_eq "SHOW CLUSTER 全部 Running" "$(printf '%s\n' "$cluster" | md_col 3 | sort -u | tr '\n' ',')" "Running,"
assert_eq "SHOW CLUSTER 全部 ACTIVATED" "$(printf '%s\n' "$cluster" | md_last_col | sort -u | tr '\n' ',')" "ACTIVATED,"
det=$(sq 'SHOW CLUSTER DETAILS;')
assert_eq "SHOW CLUSTER DETAILS 节点数一致" "$(md_count "$(md_rows "$det")")" "$WANT_NODES"
plain_cols=$(printf '%s\n' "$cluster" | grep -E '^\+' | head -1 | tr -cd '-' | wc -c | tr -d ' ')
det_cols=$(printf '%s\n' "$det" | grep -E '^\+' | head -1 | tr -cd '-' | wc -c | tr -d ' ')
assert_ge "DETAILS 列数更多" "${det_cols:-0}" "$(( ${plain_cols:-0} + 1 ))"
assert_ok "SHOW CLUSTERID" "$(sq 'SHOW CLUSTERID;')"
assert_eq "SHOW DATANODES 行数 == DN 数" "$(md_count "$(md_rows "$(sq 'SHOW DATANODES;')")")" "${#DN[@]}"
assert_eq "SHOW CONFIGNODES 行数 == CN 数" "$(md_count "$(md_rows "$(sq 'SHOW CONFIGNODES;')")")" "${#CN[@]}"
assert_eq "SHOW AVAILABLE URLS 行数 == DN 数" "$(md_count "$(md_rows "$(sq 'SHOW AVAILABLE URLS;')")")" "${#DN[@]}"

log "=== 2) 区域元数据：DataRegion 懒创建 ==="
dr_before=$(sq "SHOW DATA REGIONS OF DATABASE $DB;")
assert_ok "SHOW DATA REGIONS OF DATABASE（写数据前）" "$dr_before"
assert_eq "只有时序无数据时 DataRegion 为空" "$(md_count "$(md_rows "$dr_before")")" "0"
sr=$(sq "SHOW SCHEMA REGIONS OF DATABASE $DB;")
assert_ge "SchemaRegion 已存在" "$(md_count "$(md_rows "$sr")")" "1"
assert_set_is "SHOW SCHEMA REGIONS 的 Database 列只含本库" \
  "$(printf '%s\n' "$sr" | md_col 4 | sort -u)" "$DB"
rid=$(scalar "$(sq "SHOW SCHEMA REGIONID WHERE DATABASE=$DB;")")
assert_ge "SHOW SCHEMA REGIONID 返回 id" "${rid:-0}" "1"

log "=== 3) 写入数据后 DataRegion / TimeSlot 才出现 ==="
ins=$(sq "INSERT INTO $DB.d1(timestamp, s1) VALUES($(now_ms), 1);")
assert_ok "写入一条数据" "$ins"
sq 'FLUSH;' >/dev/null 2>&1
dr_after=$(sq "SHOW DATA REGIONS OF DATABASE $DB;")
assert_ge "写数据后 DataRegion 出现" "$(md_count "$(md_rows "$dr_after")")" "1"
assert_set_is "SHOW DATA REGIONS 的 Database 列只含本库" \
  "$(printf '%s\n' "$dr_after" | md_col 4 | sort -u)" "$DB"
slot=$(sq "SHOW TIMESLOTID WHERE DEVICE=$DB.d1;")
assert_ok "SHOW TIMESLOTID WHERE DEVICE" "$slot"
assert_ge "TimeSlot 出现" "$(md_count "$(md_rows "$slot")")" "1"

log "=== 4) 会话/版本类元数据 ==="
ver=$(sq 'SHOW VERSION;')
commit="${V_TESTDB##*_}"
assert_contains "SHOW VERSION 的 commit 与安装目录一致（$commit）" "$ver" "$commit"
assert_eq "SHOW CURRENT_USER" "$(scalar "$(sq 'SHOW CURRENT_USER;')")" "$DB_USER"
assert_eq "SHOW CURRENT_SQL_DIALECT" "$(scalar "$(sq 'SHOW CURRENT_SQL_DIALECT;')")" "TREE"
assert_ok "SHOW CURRENT_TIMESTAMP" "$(sq 'SHOW CURRENT_TIMESTAMP;')"
assert_contains "SHOW VARIABLES 含 ClusterName" "$(sq 'SHOW VARIABLES;')" 'ClusterName'
assert_contains "SHOW ACTIVATION 为 ACTIVATED" "$(sq 'SHOW ACTIVATION;')" 'ACTIVATED'
assert_ok "SHOW SYSTEM INFO" "$(sq 'SHOW SYSTEM INFO;')"
assert_contains "SHOW QUERIES 里能看到自己" "$(sq 'SHOW QUERIES;')" 'SHOW QUERIES'
assert_eq "SHOW AINODES 为空（本环境未部署 AINode）" "$(md_count "$(md_rows "$(sq 'SHOW AINODES;')")")" "0"

log "=== 5) 元数据自洽：COUNT DATABASES / COUNT TIMESERIES / COUNT DEVICES ==="
assert_eq "COUNT DATABASES == SHOW DATABASES 行数" \
  "$(scalar "$(sq 'COUNT DATABASES;')")" "$(md_count "$(md_rows "$(sq 'SHOW DATABASES;')")")"
assert_eq "COUNT TIMESERIES == SHOW TIMESERIES 行数" \
  "$(scalar "$(sq "COUNT TIMESERIES $DB.**;")")" "$(md_count "$(md_rows "$(sq "SHOW TIMESERIES $DB.**;")")")"
assert_eq "COUNT DEVICES == SHOW DEVICES 行数" \
  "$(scalar "$(sq "COUNT DEVICES $DB.**;")")" "$(md_count "$(md_rows "$(sq "SHOW DEVICES $DB.**;")")")"

log "--- 清理 ---"
drop_tree_db "$DB"

# 一致性校验用**稳定**的元数据查询：SHOW CLUSTER 会随节点在线状态变化
# （停掉一个 DN 后各节点看到的 NodeStatus 不同），不适合做副本比对。
md_case_finish tree 'SHOW DATABASES;'
