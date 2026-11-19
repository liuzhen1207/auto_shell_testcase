#!/bin/bash
# ============================================================================
# 来源工作项：TDB-1352
#   表视图（定义基于树模型非对齐设备）last 查询优化：
#   原实现不下推、正序扫描全部数据；期望 last 走倒序/末尾读取，避免全量扫描。
#
#   RC3 实测（本用例断言依据）：
#     - EXPLAIN 出现 NonAlignedAggregationTreeDeviceViewScanNode，且 last 聚合在
#       scan 节点内（PARTIAL）→ 聚合已下推
#     - EXPLAIN ANALYZE：last 的扫描输出行数远小于 count（读一个 chunk 即结束），
#       执行耗时也明显低于 count → 未全量扫描
#   注意：计划中的 "ScanOrder: ASC" 表示输出顺序，不代表内部读取方向，
#         因此本用例以 ANALYZE 的读取行数/耗时为判据，不直接断言 ScanOrder。
#
#   验证版本：2.0.13.1 RC3 / ac7f95e（与安全无关，普通模式）
# ============================================================================
RN1352_DB=rn1352_db
RN1352_ROWS=100000

# 从 explain analyze 输出中取：最大 "output: N rows" 与 "Total Wall Time: N ms"
_rn1352_scan_rows() { echo "$1" | grep -oE "output: [0-9]+ rows" | awk '{print $2}' | sort -n | tail -1; }
_rn1352_wall()      { echo "$1" | grep -oE "Total Wall Time: [0-9]+ ms" | head -1 | awk '{print $4}'; }

case_RN216() {
  echo "  --- 非对齐设备表视图 last 查询：下推 + 非全量扫描 ---"
  local D=$RN1352_DB
  Q "drop database if exists $D" >/dev/null 2>&1
  assert_ok "$(Q "create database $D")" "创建数据库 $D"
  assert_ok "$(T "create timeseries root.$D.d1.s1 double")" "创建非对齐设备 d1 序列"
  assert_ok "$(T "create timeseries root.$D.d2.s1 double")" "创建非对齐设备 d2 序列"

  local dev chunk i t v vals
  for dev in d1 d2; do
    for chunk in $(seq 1 $((RN1352_ROWS / 5000))); do
      vals=""
      for i in $(seq 1 5000); do
        t=$(( (chunk-1)*5000 + i )); v=$(( t % 89 ))
        vals="$vals($t,$v.0),"
      done
      vals=${vals%,}
      T "insert into root.$D.$dev(time,s1) values $vals" >/dev/null 2>&1
    done
  done
  local cnt; cnt=$(T "select count(s1) from root.$D.d1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${cnt:-0}" -ge "$RN1352_ROWS" ] && ok "写入数据完成（d1=$cnt 行，共约 $((cnt*2)) 行）" || fail "数据写入不足（d1=${cnt:-0}）"

  assert_ok "$(Q "create view $D.v1(dev string tag) with(auto_sync_schema = true) as root.$D.**")" "创建表视图 v1"

  # 1) 聚合下推
  local plan; plan=$(Q "explain select last(s1) from $D.v1" 2>&1)
  assert_contains "$plan" "NonAlignedAggregationTreeDeviceViewScanNode" "EXPLAIN 出现非对齐视图聚合下推算子"
  if echo "$plan" | grep -q "NonAlignedAggregationTreeDeviceViewScanNode"; then
    local seg; seg=$(echo "$plan" | sed -n '/NonAlignedAggregationTreeDeviceViewScanNode/,/└/p')
    echo "$seg" | grep -q "last(" && ok "last 聚合已下推到 scan 节点" || fail "last 聚合未出现在 scan 节点内（未下推）"
  fi

  # 2) 非全量扫描：EXPLAIN ANALYZE 读取行数对比
  local an_last an_cnt rows_last rows_cnt wall_last wall_cnt
  an_last=$(Q "explain analyze select last(s1) from $D.v1" 2>&1)
  an_cnt=$(Q "explain analyze select count(s1) from $D.v1" 2>&1)
  rows_last=$(_rn1352_scan_rows "$an_last"); rows_cnt=$(_rn1352_scan_rows "$an_cnt")
  wall_last=$(_rn1352_wall "$an_last"); wall_cnt=$(_rn1352_wall "$an_cnt")
  echo "    last: rows=${rows_last:-?} wall=${wall_last:-?}ms | count: rows=${rows_cnt:-?} wall=${wall_cnt:-?}ms"

  if [ -n "${rows_last:-}" ] && [ -n "${rows_cnt:-}" ] && [ "$rows_last" -gt 0 ] 2>/dev/null; then
    if [ $(( rows_last * 5 )) -lt "$rows_cnt" ]; then
      ok "last 扫描行数 ${rows_last} 远小于全量 ${rows_cnt}（<20%），未全表扫描"
    else
      fail "last 扫描行数 ${rows_last} 接近全量 ${rows_cnt}，仍扫描全部数据"
    fi
  else
    fail "未能从 EXPLAIN ANALYZE 取到扫描行数（last=${rows_last:-空} count=${rows_cnt:-空}）"
  fi

  # 耗时仅作记录：ANALYZE 首次执行含计划/预热开销，波动大，不作为判据
  [ -n "${wall_last:-}" ] && ok "记录：last wall=${wall_last}ms / count wall=${wall_cnt}ms（仅供参考）"

  # 3) 功能正确性
  local res; res=$(Q "select last(s1) from $D.v1" 2>&1 | grep -E '^\|' | head -2 | tail -1 | tr -dc '0-9.')
  local expect=$(( RN1352_ROWS % 89 ))
  if [ "${res:-}" = "${expect}.0" ] || [ "${res:-}" = "$expect" ]; then
    ok "last 结果正确（$res）"
  else
    fail "last 结果错误（实际 ${res:-空}，期望 ${expect}）"
  fi

  Q "drop database if exists $D" >/dev/null 2>&1
}

CASES+=(
"RN-216|TDB-1352 非对齐视图 last 查询下推与读取量|性能|EXPLAIN 显示聚合下推；EXPLAIN ANALYZE 中 last 扫描行数远小于全量 count|case_RN216"
)
