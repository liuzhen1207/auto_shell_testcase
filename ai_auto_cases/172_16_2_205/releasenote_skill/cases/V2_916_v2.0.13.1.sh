#!/bin/bash
# ============================================================================
# 来源缺陷单：PingCode V2-916（创建人：刘珍）
#   表模型时间列名不是 time（benchmark 配置 IoTDB_TABLE_TIME_COLUMN=D_DATETIME）时，
#   DELETE ... WHERE d_datetime BETWEEN ... 报 701
#   The column 'd_datetime' does not exist or is not a tag column
#   期望：删除正常执行
#   验证版本：2.0.13.1 / ab6d3de
# ============================================================================
RN916_DB=rn_v2916

case_RN137() {
  local out cnt
  Q "DROP DATABASE IF EXISTS $RN916_DB" >/dev/null 2>&1
  assert_ok "$(Q "CREATE DATABASE $RN916_DB")" "建库"
  # 自定义时间列名 d_datetime
  assert_ok "$(Q "CREATE TABLE $RN916_DB.t(d_datetime TIMESTAMP TIME, tag1 STRING TAG, v INT32 FIELD)")" "建表（时间列名 d_datetime）"
  assert_ok "$(Q "INSERT INTO $RN916_DB.t(d_datetime, tag1, v) VALUES (1779933600000,'a',1),(1779937200000,'a',2)")" "写入 2 行"

  out=$(Q "DELETE FROM $RN916_DB.t WHERE d_datetime >= 1779933600000 AND d_datetime <= 1779937199999")
  echo "  DELETE 返回：$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200)"

  if echo "$out" | grep -q '701'; then
    fail "DELETE ... WHERE d_datetime 仍报 701（缺陷未修复）"
  else
    ok "DELETE 未报 701"
  fi
  assert_ok "$out" "按自定义时间列删除成功"

  out=$(Q "SELECT count(*) FROM $RN916_DB.t")
  echo "  删除后行数：$(echo "$out" | tail -3 | tr '\n' ' ' | cut -c1-120)"
  if echo "$out" | grep -qE '\|[[:space:]]*1[[:space:]]*\|'; then
    ok "剩余 1 行（只删掉了区间内那行）"
  else
    fail "行数不符合预期（$(echo "$out" | tr '\n' ' ' | cut -c1-120)）"
  fi

  Q "DROP DATABASE IF EXISTS $RN916_DB" >/dev/null 2>&1
}

CASES+=(
"RN-137|V2-916 自定义时间列|功能|时间列名为 d_datetime 时 DELETE ... WHERE d_datetime BETWEEN 应成功|case_RN137"
)
