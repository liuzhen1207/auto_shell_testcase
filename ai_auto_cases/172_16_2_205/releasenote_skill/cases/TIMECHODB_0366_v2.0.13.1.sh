#!/bin/bash
# 来源工作项：TDB-1406 / 【TIMECHODB-0366】
#   [树转表][2.0.5.1 RC2] 元数据导出适配 export-schema.sh 导出的视图定义不正确，
#   生成的 SQL 是"创建表"而不是"创建视图"。
#   期望：导出文件中对树转表视图输出 CREATE VIEW ... WITH (auto_sync_schema=true)
#         AS root."<db>".**，导入后仍为视图且自动扩列可用。
#   RC3 已含修复：#16226 改用 SHOW CREATE TABLE 导出表/视图定义
#   验证版本：2.0.13.1 RC3 / ac7f95e（与安全无关，普通模式验证）
# ============================================================================
RN1406_DB=rn1406_db
RN1406_EXP=/tmp/rn1406_exp

case_RN215() {
  echo "  --- 树转表视图元数据导出/导入（export-schema.sh）---"
  local NEWB=/data2/iotdb/$NEW
  local EXP=$NEWB/tools/schema/export-schema.sh
  local IMP=$NEWB/tools/schema/import-schema.sh
  local dump="$RN1406_EXP/dump_${RN1406_DB}.sql"

  Q "drop database if exists $RN1406_DB" >/dev/null 2>&1
  assert_ok "$(Q "create database $RN1406_DB")" "创建数据库 $RN1406_DB"
  assert_ok "$(T "create timeseries root.$RN1406_DB.d1.s1 double")" "创建序列 d1.s1"
  T "insert into root.$RN1406_DB.d1(time,s1) values(1,1.5)" >/dev/null 2>&1
  assert_ok "$(Q "create view $RN1406_DB.v1(dev string tag) with(auto_sync_schema = true) as root.$RN1406_DB.**")" "创建树转表视图 v1"

  local base; base=$(Q "show create table $RN1406_DB.v1" 2>&1)
  assert_contains "$base" "CREATE VIEW" "导出前 SHOW CREATE TABLE 为 CREATE VIEW（基线）"

  # 导出
  rm -rf "$RN1406_EXP"; mkdir -p "$RN1406_EXP"
  local expout
  expout=$(timeout 180 bash "$EXP" -sql_dialect table -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -t "$RN1406_EXP" -db "$RN1406_DB" 2>&1)
  if echo "$expout" | grep -q "Export completely"; then
    ok "export-schema.sh 执行完成"
  else
    fail "export-schema.sh 未正常完成：$(echo "$expout" | tail -2 | tr '\n' ' ' | cut -c1-160)"
  fi
  [ -f "$dump" ] && ok "导出文件存在：$(basename "$dump")" || fail "未生成导出文件 $dump"

  # 导出内容断言：视图定义必须是 CREATE VIEW
  local sql; sql=$(cat "$dump" 2>/dev/null)
  assert_contains "$sql" "CREATE VIEW" "导出 SQL 含 CREATE VIEW"
  assert_contains "$sql" "auto_sync_schema" "导出 SQL 保留 auto_sync_schema 属性"
  assert_contains "$sql" "AS root" "导出 SQL 含视图 AS 定义"
  if echo "$sql" | grep -qE "CREATE TABLE[^;]*\"v1\""; then
    fail "导出 SQL 仍把视图 v1 写成 CREATE TABLE（缺陷未修复）"
  else
    ok "导出 SQL 未把视图写成 CREATE TABLE"
  fi

  # 删除视图后导入，验证恢复为视图
  assert_ok "$(Q "drop view $RN1406_DB.v1")" "删除视图（准备导入）"
  local impout
  impout=$(timeout 180 bash "$IMP" -sql_dialect table -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -s "$RN1406_EXP" -db "$RN1406_DB" 2>&1)
  if echo "$impout" | grep -qiE "Import completely|successfully"; then
    ok "import-schema.sh 执行完成"
  else
    fail "import-schema.sh 未正常完成：$(echo "$impout" | tail -2 | tr '\n' ' ' | cut -c1-160)"
  fi

  local restored; restored=$(Q "show create table $RN1406_DB.v1" 2>&1)
  assert_contains "$restored" "CREATE VIEW" "导入后对象仍是视图（CREATE VIEW）"
  assert_contains "$restored" "auto_sync_schema" "导入后 auto_sync_schema 属性保留"
  local desc; desc=$(Q "desc $RN1406_DB.v1" 2>&1)
  assert_contains "$desc" "s1" "导入后视图包含 FIELD 列 s1"

  # 导入后自动扩列仍生效
  assert_ok "$(T "create timeseries root.$RN1406_DB.d1.imported_col double")" "导入后新建序列"
  sleep 5
  local after; after=$(Q "desc $RN1406_DB.v1" 2>&1)
  assert_contains "$after" "imported_col" "导入后视图仍能自动扩列（imported_col 出现）"

  Q "drop database if exists $RN1406_DB" >/dev/null 2>&1
}

CASES+=(
"RN-215|TDB-1406 树转表视图元数据导出为 CREATE VIEW|功能|export-schema.sh 导出视图定义正确（非 CREATE TABLE），导入后仍为视图且自动扩列可用|case_RN215"
)
