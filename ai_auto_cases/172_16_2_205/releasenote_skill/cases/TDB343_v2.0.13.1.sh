#!/bin/bash
# ============================================================================
# 来源需求：TDB-343 树转表视图自动扩列（auto_sync_schema）
#   需求文档：PLM docs/90   设计文档：PLM docs/913
#   验证版本：2.0.13.1 / ab6d3de
#   覆盖清单：见 docs/tree2table_auto_sync_points.md
#   注意：每个用例使用独立 database，且删除后等待其真正消失，避免异步 DROP 污染
# ============================================================================

# 删除数据库并等待其从 show databases 中消失（最多 30s）
rn_t2t_drop() {
  local db=$1 i
  Q "DROP DATABASE IF EXISTS $db" >/dev/null 2>&1
  for i in $(seq 1 30); do
    if ! Q "show databases" 2>/dev/null | grep -qE "\| *$db *\|"; then
      return 0
    fi
    sleep 1
  done
  echo "  [warn] 数据库 $db 30s 内未删除干净"
  return 0
}

rn_t2t_build() {  # $1=db $2=view $3=with属性(可空) $4...=树测点
  local db=$1 view=$2 prop=$3; shift 3
  local m
  for m in "$@"; do
    T "create timeseries root.$db.dev01.$m double" >/dev/null 2>&1
  done
  if [ -n "$prop" ]; then
    Q "create view $db.$view(dev string tag) with(auto_sync_schema = $prop) as root.$db.**"
  else
    Q "create view $db.$view(dev string tag) as root.$db.**"
  fi
}

# RN-139：建视图时扫描已有测点 + 属性可见
case_RN139() {
  local db=rn_t2t_139_$(date +%H%M%S) out n
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  out=$(rn_t2t_build $db v1 true s1 s2 s3)
  assert_ok "$out" "建带属性的视图"

  out=$(Q "desc $db.v1")
  n=$(echo "$out" | grep -cE '\| *(s1|s2|s3) *\|')
  echo "  视图列（s1/s2/s3）匹配行数：$n"
  if [ "${n:-0}" -ge 3 ]; then ok "建视图时已扫描到 3 个已有测点"; else fail "建视图时未扫描全已有测点（匹配 $n 行）"; fi

  out=$(Q "show create view $db.v1")
  if echo "$out" | grep -q 'auto_sync_schema=true'; then
    ok "show create view 展示 auto_sync_schema=true"
  else
    fail "show create view 未展示 auto_sync_schema"
  fi
  rn_t2t_drop $db
}

# RN-140：INSERT 自动建序列触发补列 + 新列可查
case_RN140() {
  local db=rn_t2t_140_$(date +%H%M%S) out before after
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  assert_ok "$(rn_t2t_build $db v1 true s1)" "建视图"
  before=$(Q "desc $db.v1" | grep -cE '\| *s[0-9]')

  assert_ok "$(T "insert into root.$db.dev01(s9) values (9.9)")" "insert 新测点（自动建序列）"
  sleep 3
  out=$(Q "desc $db.v1")
  after=$(echo "$out" | grep -cE '\| *s[0-9]')
  echo "  补列前字段数=$before，补列后字段数=$after"
  if [ "${after:-0}" -gt "${before:-0}" ]; then ok "INSERT 新测点后视图自动补列"; else fail "INSERT 后视图未补列（$before -> $after）"; fi
  if echo "$out" | grep -qE '\| *s9 *\|'; then ok "新列 s9 已出现在视图中"; else fail "视图中没有 s9 列"; fi

  out=$(Q "select s9 from $db.v1")
  if echo "$out" | grep -q '9.9'; then ok "通过视图可查到新列数据"; else fail "视图查询不到 s9 数据"; fi
  rn_t2t_drop $db
}

# RN-141：显式 CREATE TIMESERIES 触发补列
case_RN141() {
  local db=rn_t2t_141_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  assert_ok "$(rn_t2t_build $db v1 true s1)" "建视图"

  assert_ok "$(T "create timeseries root.$db.dev01.s5 int64")" "显式建序列"
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s5 *\|.*INT64'; then
    ok "显式建序列后视图补列且类型为 INT64"
  elif echo "$out" | grep -qE '\| *s5 *\|'; then
    ok "显式建序列后视图补列（类型列未匹配）"
  else
    fail "显式建序列后视图未补列"
  fi
  rn_t2t_drop $db
}

# RN-142：未开启属性时新增测点不补列
case_RN142() {
  local db=rn_t2t_142_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  assert_ok "$(rn_t2t_build $db v2 '' s1)" "建视图（不带属性）"

  assert_ok "$(T "create timeseries root.$db.dev01.s8 double")" "新增测点"
  sleep 3
  out=$(Q "desc $db.v2")
  if echo "$out" | grep -qE '\| *s8 *\|'; then fail "未开启属性的视图也补列了（s8 出现）"; else ok "未开启属性的视图不补列"; fi
  rn_t2t_drop $db
}

# RN-143：base table 带属性报错
case_RN143() {
  local db=rn_t2t_143_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  out=$(Q "create table $db.t1(a string tag, b int32 field) with(auto_sync_schema = true)")
  echo "  base table 返回：$(echo "$out" | head -1 | cut -c1-160)"
  if echo "$out" | grep -q '701'; then ok "base table 带 auto_sync_schema 被拒绝（701）"; else fail "base table 带 auto_sync_schema 未报错"; fi
  if echo "$out" | grep -qi 'only supported by tree to table views'; then
    ok "错误信息明确指向树转表视图限制"
  else
    fail "错误信息不明确"
  fi
  rn_t2t_drop $db
}

# RN-144：属性关闭后不再补列
case_RN144() {
  local db=rn_t2t_144_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  assert_ok "$(rn_t2t_build $db v1 true s1)" "建视图（开启属性）"

  assert_ok "$(Q "alter view $db.v1 set properties auto_sync_schema = false")" "关闭属性"
  assert_ok "$(T "create timeseries root.$db.dev01.s7 double")" "关闭后新增测点"
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s7 *\|'; then fail "关闭属性后仍补列（s7 出现）"; else ok "关闭属性后不再补列"; fi
  rn_t2t_drop $db
}

# RN-145：同名大小写/类型冲突不补列且写入成功
case_RN145() {
  local db=rn_t2t_145_$(date +%H%M%S) out n
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  assert_ok "$(rn_t2t_build $db v1 true s1)" "建视图"

  out=$(T "create timeseries root.$db.dev02.S1 int32")
  assert_ok "$out" "创建同名不同大小写/类型的测点（写入侧不报错）"
  sleep 3
  out=$(Q "desc $db.v1")
  n=$(echo "$out" | grep -ciE '\| *s1 *\|')
  echo "  视图中 s1 列行数：$n（应仍为 1）"
  if [ "${n:-0}" -eq 1 ]; then ok "冲突测点未新增列"; else fail "冲突测点产生了额外列（$n 行）"; fi
  if echo "$out" | grep -qiE '\| *s1 *\|.*DOUBLE'; then ok "原 s1 列类型保持 DOUBLE"; else fail "原 s1 列类型被改变"; fi
  rn_t2t_drop $db
}

# RN-146：prefixPath 下存在 s1/S1 小写冲突时建视图被拒绝（实测 617）
case_RN146() {
  local db=rn_t2t_146_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "create timeseries root.$db.dev02.S1 int32" >/dev/null 2>&1

  out=$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")
  echo "  建视图返回：$(echo "$out" | head -1 | cut -c1-170)"
  if echo "$out" | grep -q '617'; then
    ok "小写冲突的 prefix 建视图被拒绝（617）"
  else
    fail "小写冲突未被拒绝（$(echo "$out" | head -1 | cut -c1-120)）"
  fi
  if echo "$out" | grep -qi 'share the same lower case'; then
    ok "错误信息明确提示小写冲突"
  else
    fail "错误信息未提示小写冲突"
  fi
  rn_t2t_drop $db
}

CASES+=(
"RN-139|TDB-343 建视图扫描|功能|建视图时扫描 prefixPath 已有测点成列，且属性可见|case_RN139"
"RN-140|TDB-343 INSERT 补列|功能|INSERT 自动建序列后视图自动补列且可查|case_RN140"
"RN-141|TDB-343 显式建序列补列|功能|CREATE TIMESERIES 后视图自动补列|case_RN141"
"RN-142|TDB-343 默认不补列|功能|未开启 auto_sync_schema 的视图不补列|case_RN142"
"RN-143|TDB-343 base table 拒绝|负向|base table 带 auto_sync_schema 应报 701|case_RN143"
"RN-144|TDB-343 关闭属性|功能|属性关闭后新增测点不再补列|case_RN144"
"RN-145|TDB-343 冲突不补列|功能|同名大小写/类型冲突时不补列且写入不报错|case_RN145"
"RN-146|TDB-343 小写冲突拒绝|负向|prefix 下 s1/S1 小写冲突时建视图应报 617|case_RN146"
)
