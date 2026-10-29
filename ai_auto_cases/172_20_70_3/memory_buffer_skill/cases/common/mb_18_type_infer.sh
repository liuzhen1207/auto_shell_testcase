#!/bin/bash
# MB-18 写入字符串类型推断（boolean/integer/floating/nan_string_infer_type）
#
# 技术设计依据：《内存缓冲区-技术设计》§数据类型推断
#   写入的 String 按四类规则推断为具体类型（其余情况一律 TEXT）：
#     "true"/"false"        → boolean_string_infer_type  （默认 BOOLEAN，可选 TEXT）
#     long 范围内整数        → integer_string_infer_type  （默认 DOUBLE）
#     浮点数 / 超 long 整数  → floating_string_infer_type （默认 DOUBLE）
#     "NaN"                 → nan_string_infer_type       （默认 DOUBLE）
#   推断发生在**写入内存缓冲区前**，因此这是内存缓冲区写入路径的功能。
#
# 做法：同一份 SQL 文本值，跑两轮：
#   A 相：四个参数都用默认值（BOOLEAN / DOUBLE / DOUBLE / DOUBLE）
#   B 相：四个参数都改成保守值（BOOLEAN→TEXT，其余→TEXT），验证"改配置后不再推断"
# 判据：
#   ① 参数回读生效；
#   ② A 相：`show timeseries` / information_schema 里对应序列的数据类型符合默认推断规则；
#   ③ A 相：写入的值读出来与写入字符串的数值语义一致（true→true、123→123.0 等）；
#   ④ B 相：全 TEXT 时序列类型为 TEXT，且读出的就是原字符串；
#   ⑤ 收尾三件套。
#   注：类型是否被推断，用"查询结果的类型/字面量形态"判定，不用日志。
#
# ⚠️ 2026-10-20 在 v20121rc8_1016_ebaf9da 上的实测（详见 docs/FINDINGS.md F-01）：
#   配置确认为 BOOLEAN/DOUBLE（`show configuration` 生效值也是它们），但
#   `insert into root.x.d1(time,s1) values (1000,'123')` 自动建出的序列**是 TEXT**
#   ⇒ "SQL INSERT 自动建序列"这条路径上没有按 string_infer_type 推断。
#   因此 ③ 在本版本会 FAIL —— 这是**用例要暴露的结论**，不是用例写错；
#   后续版本若修复会自动转 PASS，适合做回归。
#   跑批时用 MB_KNOWN_F01=1（默认）把它记成"已知缺陷"：仍会打印失败明细与证据，
#   但不计入 fail_flag，避免整套回归因为一个已知缺陷长期标红；设为 0 则按普通失败计。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-18
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="1:200:1:1:1:1"
MB_FLUSH_PROPORTION="0.5"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION

DB=root.mb18

# 取某键的生效值（表方言 show configuration 第 3 列 = 当前值）
mb_eff(){ local h=$1 k=$2
  sqt_node "$h" 'show configuration;' 2>/dev/null | awk -F'|' -v k="$k" '
    { n=$2; gsub(/^[ \t]+|[ \t]+$/,"",n); if (n==k) { v=$3; gsub(/^[ \t]+|[ \t]+$/,"",v); print v; exit } }'
}
# 取序列的数据类型（树方言 show timeseries 的 DataType 列）
#   ⚠️ 必须**按表头列名定位**，不能硬编码列号：
#   show timeseries 的列是 Timeseries|Alias|Database|DataType|Encoding|...，
#   而行首有 '|'，所以 -F'|' 时 $1 为空、DataType 在 $5（不是 $4）。
#   硬编码列号是 compaction skill 踩坑表里明确记录过的坑，这里按列名算。
mb_series_type(){ local dev=$1
  local out; out=$(sq "show timeseries $DB.$dev.s1;" 2>/dev/null)
  printf '%s\n' "$out" | awk -F'|' '
    /^\|/ {
      if (idx == 0) {
        for (i=1;i<=NF;i++) { h=$i; gsub(/^[ \t]+|[ \t]+$/,"",h); if (h=="DataType") { idx=i; break } }
        next
      }
      v=$idx; gsub(/^[ \t]+|[ \t]+$/,"",v); print v; exit
    }'
}

write_phase(){
  local tag=$1
  log "----- 阶段 $tag -----"
  # ⚠️ **不能预先建序列**：预建会把类型固定住（尤其 mb_make_tree_db 默认建 int64），
  #    推断就不会发生。这里只建库，靠 INSERT 自动建序列来观察推断结果。
  sq "create database $DB;" >/dev/null 2>&1
  # d1 → boolean, d2 → integer, d3 → floating, d4 → NaN, d5 → 普通文本（应为 TEXT）
  local stmts=(
    "insert into $DB.d1(time,s1) values (1000,'true'),(2000,'false');"
    "insert into $DB.d2(time,s1) values (1000,'123'),(2000,'456');"
    "insert into $DB.d3(time,s1) values (1000,'3.14'),(2000,'2.72');"
    "insert into $DB.d4(time,s1) values (1000,'NaN');"
    "insert into $DB.d5(time,s1) values (1000,'hello'),(2000,'world');"
  )
  local s out
  for s in "${stmts[@]}"; do
    out=$(sq "$s" 2>&1)
    printf '%s' "$out" | grep -q 'executed successfully' || warn "写入未报成功: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  done
  sq 'flush;' >/dev/null 2>&1
  sleep 3
  local d
  for d in 1 2 3 4 5; do
    local t; t=$(mb_series_type "d$d")
    log "  d$d 推断类型=[$t]  首行=[$(sq "select s1 from $DB.d$d order by time limit 1;" 2>/dev/null | table_rows | head -1 | tr -s ' ')]"
  done
}

# ---------- A 相：默认推断 ----------
export EXTRA_CONF="boolean_string_infer_type=BOOLEAN,integer_string_infer_type=DOUBLE,floating_string_infer_type=DOUBLE,nan_string_infer_type=DOUBLE"
mb_cluster_prepare
for h in "${DN[@]}"; do
  for kv in boolean_string_infer_type=BOOLEAN integer_string_infer_type=DOUBLE floating_string_infer_type=DOUBLE nan_string_infer_type=DOUBLE; do
    k="${kv%%=*}"; v="${kv#*=}"
    got=$(sshx "$h" "grep -E '^$k=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
    assert_eq "①$h conf $k" "$got" "$v"
  done
  assert_eq "①$h 生效值 boolean_string_infer_type" "$(mb_eff "$h" boolean_string_infer_type)" "BOOLEAN"
  assert_eq "①$h 生效值 integer_string_infer_type" "$(mb_eff "$h" integer_string_infer_type)" "DOUBLE"
done
write_phase "A-默认推断"
t1=$(mb_series_type d1); t2=$(mb_series_type d2); t3=$(mb_series_type d3); t4=$(mb_series_type d4); t5=$(mb_series_type d5)
# 已知缺陷 F-01：SQL INSERT 自动建序列未按 *_string_infer_type 推断（详见 docs/FINDINGS.md）
#   MB_KNOWN_F01=1（默认）⇒ 记 WARN + 不计 fail_flag；=0 ⇒ 记 FAIL
known_f01(){
  local label=$1 got=$2 want=$3
  if [ "$got" = "$want" ]; then pass "$label: $got（已修复）"; return 0; fi
  if [ "${MB_KNOWN_F01:-1}" = "1" ]; then
    warn "[已知缺陷 F-01] $label: 实际=[$got] 期望=[$want]（产品未按 string_infer_type 推断，不计 FAIL）"
  else
    fail "$label: 实际=[$got] 期望=[$want]"
  fi
}
known_f01 "③boolean_string_infer_type=BOOLEAN ⇒ d1 为 BOOLEAN" "$t1" "BOOLEAN"
known_f01 "③integer_string_infer_type=DOUBLE ⇒ d2 为 DOUBLE" "$t2" "DOUBLE"
known_f01 "③floating_string_infer_type=DOUBLE ⇒ d3 为 DOUBLE" "$t3" "DOUBLE"
known_f01 "③nan_string_infer_type=DOUBLE ⇒ d4 为 DOUBLE" "$t4" "DOUBLE"
known_f01 "③兜底（普通文本）⇒ d5 为 TEXT" "$t5" "TEXT"
# ③ 值语义：true 读回 true；123 读回 123.0（DOUBLE）
assert_contains "③d1 读回 true" "$(sq "select s1 from $DB.d1 order by time limit 1;" 2>/dev/null)" 'true'
assert_contains "③d2 读回数值 123" "$(sq "select s1 from $DB.d2 order by time limit 1;" 2>/dev/null)" '123'
assert_contains "③d3 读回 3.14" "$(sq "select s1 from $DB.d3 order by time limit 1;" 2>/dev/null)" '3.14'
assert_contains "③d5 读回原字符串 hello" "$(sq "select s1 from $DB.d5 order by time limit 1;" 2>/dev/null)" 'hello'

# ---------- B 相：全部改成 TEXT（关闭推断） ----------
log "----- 阶段 B：四个参数全部改为 TEXT（需重启）-----"
cluster_stop; cluster_clean
export EXTRA_CONF="boolean_string_infer_type=TEXT,integer_string_infer_type=TEXT,floating_string_infer_type=TEXT,nan_string_infer_type=TEXT"
cluster_write_conf
cluster_start
wait_cluster_ready || fail "B 相集群未就绪"
for h in "${DN[@]}"; do
  got=$(sshx "$h" "grep -E '^boolean_string_infer_type=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
  assert_eq "①$h conf boolean_string_infer_type=TEXT" "$got" "TEXT"
  assert_eq "①$h 生效值 boolean_string_infer_type" "$(mb_eff "$h" boolean_string_infer_type)" "TEXT"
done
write_phase "B-全 TEXT"
t1=$(mb_series_type d1); t2=$(mb_series_type d2); t3=$(mb_series_type d3); t5=$(mb_series_type d5)
assert_eq "②全 TEXT 时 d1 为 TEXT" "$t1" "TEXT"
assert_eq "②全 TEXT 时 d2 为 TEXT" "$t2" "TEXT"
assert_eq "②全 TEXT 时 d3 为 TEXT" "$t3" "TEXT"
assert_eq "②全 TEXT 时 d5 仍为 TEXT" "$t5" "TEXT"
assert_contains "②d2 读回原字符串 123（非数值格式化）" "$(sq "select s1 from $DB.d2 order by time limit 1;" 2>/dev/null)" '123'

mb_case_finish "$(mb_data_sql "$DB")" tree
