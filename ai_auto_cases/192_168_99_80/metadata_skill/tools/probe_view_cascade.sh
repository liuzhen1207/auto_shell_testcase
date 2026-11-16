#!/bin/bash
# ============================================================================
# 可写视图 schema_cascade 语义实测（正确方向：视图 DDL → 源表）
#   A 相 cascade=true  ：ALTER VIEW ADD COLUMN → 源表应**多出**该列
#   B 相 cascade=false ：ALTER VIEW ADD COLUMN → 源表**不应**变化
#   C 相 cascade=true  ：ALTER VIEW DROP COLUMN   → 源表对应列应被删（仅当视图暴露该列）
#   反向（源表加列 → 视图）仅作记录：按需求这不是 cascade 的职责
# ============================================================================
set -uo pipefail
R=/data/iotdb/autotest/metadata_skill
. "$R/lib/common.sh"
md_load_env
md_parse_args "$@"
md_case_init "probe_view_cascade"
md_cluster_prepare

DB=md_casc
base_cols(){ sqt "DESC $DB.t1;" | awk -F'|' 'NF>=3 {gsub(/^[ \t]+|[ \t]+$/,"",$2); if ($2!="") print $2}' | sort | tr '\n' ','; }
view_cols(){ sqt "DESC $1;" | awk -F'|' 'NF>=3 {gsub(/^[ \t]+|[ \t]+$/,"",$2); if ($2!="") print $2}' | sort | tr '\n' ','; }
cleanup(){ for v in wvt wvf; do sqt "DROP VIEW IF EXISTS $DB.$v;" >/dev/null 2>&1; done; sqt "DROP DATABASE IF EXISTS $DB;" >/dev/null 2>&1; }

cleanup
log "=== 准备：基表 t1(v1,v2) ==="
sqt "CREATE DATABASE $DB;" >/dev/null
sqt "CREATE TABLE $DB.t1 (time TIMESTAMP TIME, dev STRING TAG, v1 INT32 FIELD, v2 INT32 FIELD);" >/dev/null
sqt "INSERT INTO $DB.t1 (time,dev,v1,v2) VALUES (1000,'d1',1,2);" >/dev/null
log "  基表列集：$(base_cols)"

log "=== A 相：cascade=true，ALTER VIEW ADD COLUMN ca1 ==="
sqt "CREATE WRITABLE VIEW $DB.wvt AS SELECT dev, v1 FROM $DB.t1 WITH (schema_cascade=true);" >/dev/null
log "  视图列集(前)：$(view_cols $DB.wvt)"
o=$(sqt "ALTER VIEW $DB.wvt ADD COLUMN ca1 INT32 FIELD;")
log "  ALTER 响应：$(printf '%s' "$o" | tr '\n' ' ' | cut -c1-160)"
log "  视图列集(后)：$(view_cols $DB.wvt)"
log "  基表列集(后)：$(base_cols)   ← cascade=true 应出现 ca1"

log "=== B 相：cascade=false，ALTER VIEW ADD COLUMN cb1 ==="
sqt "CREATE WRITABLE VIEW $DB.wvf AS SELECT dev, v1 FROM $DB.t1 WITH (schema_cascade=false);" >/dev/null
o=$(sqt "ALTER VIEW $DB.wvf ADD COLUMN cb1 INT32 FIELD;")
log "  ALTER 响应：$(printf '%s' "$o" | tr '\n' ' ' | cut -c1-160)"
log "  视图列集(后)：$(view_cols $DB.wvf)"
log "  基表列集(后)：$(base_cols)   ← cascade=false 不应出现 cb1"

log "=== C 相：cascade=true，ALTER VIEW DROP COLUMN ca1 ==="
o=$(sqt "ALTER VIEW $DB.wvt DROP COLUMN ca1;")
log "  ALTER 响应：$(printf '%s' "$o" | tr '\n' ' ' | cut -c1-160)"
log "  视图列集(后)：$(view_cols $DB.wvt)"
log "  基表列集(后)：$(base_cols)   ← cascade=true 的 drop 应把源表 ca1 一起去掉"

log "=== D 相：反向（源表加列 → 视图），仅记录 ==="
sqt "ALTER TABLE $DB.t1 ADD COLUMN v9 INT32 FIELD;" >/dev/null
log "  基表列集：$(base_cols)"
log "  wvt(cascade=true) 视图列集：$(view_cols $DB.wvt)"
log "  wvf(cascade=false) 视图列集：$(view_cols $DB.wvf)"

log "=== 汇总 ==="
log "  A(cascade=true,add): 基表含 ca1? $(base_cols | grep -c ca1)"
log "  B(cascade=false,add): 基表含 cb1? $(base_cols | grep -c cb1)"
sqt "DROP VIEW IF EXISTS $DB.wvt;" >/dev/null 2>&1
sqt "DROP VIEW IF EXISTS $DB.wvf;" >/dev/null 2>&1
md_case_finish
