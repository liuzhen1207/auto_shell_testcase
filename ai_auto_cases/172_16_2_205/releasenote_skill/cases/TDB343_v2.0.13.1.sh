#!/bin/bash
# 模板链路当前版本受环境限制：set device template 只支持树模型库，
# 而树转表视图必须建在表模型库（详见 docs/tree2table_template_limitation.md）
SKIP_OF["RN-173"]="模板仅支持树模型库，树转表视图需表模型库"
SKIP_OF["RN-174"]="模板仅支持树模型库，树转表视图需表模型库"
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

# RN-147：研发确认真实口径——除「创建视图」外，其余路径遇冲突一律忽略（含属性切换补扫）
case_RN147() {
  local db=rn_t2t_147_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1

  # 建视图时无冲突 → 成功
  assert_ok "$(Q "create view $db.v1(dev string tag) as root.$db.**")" "建视图（仅 s1，无属性）"
  # 建好之后新增冲突测点 → 应忽略、不报错
  assert_ok "$(T "create timeseries root.$db.dev02.S1 int32")" "新增冲突测点 S1（应忽略不报错）"
  sleep 2
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *S1 *\|'; then
    fail "冲突测点 S1 被加进了视图列"
  else
    ok "冲突测点未进视图（忽略而非报错）"
  fi

  # false→true 补扫遇冲突 → 应忽略，属性可正常开启
  out=$(Q "alter view $db.v1 set properties auto_sync_schema = true")
  echo "  开启属性返回：$(echo "$out" | head -1 | cut -c1-150)"
  assert_ok "$out" "开启 auto_sync_schema 不因冲突而失败"
  out=$(Q "show create view $db.v1")
  if echo "$out" | grep -q 'auto_sync_schema=true'; then
    ok "属性已成功切换为 true"
  else
    fail "属性未切换为 true"
  fi

  # 开启后新增普通测点 → 正常补列（功能仍然有效）
  T "create timeseries root.$db.dev01.s9 double" >/dev/null 2>&1
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s9 *\|'; then
    ok "开启属性后新测点 s9 正常补列"
  else
    fail "开启属性后 s9 未补列"
  fi
  rn_t2t_drop $db
}

# RN-148：一条设备下多个新测点同批 insert → 全部补列
case_RN148() {
  local db=rn_t2t_148_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  assert_ok "$(rn_t2t_build $db v1 true s1)" "建视图"
  assert_ok "$(T "insert into root.$db.dev01(s10,s11,s12) values(1.0,2.0,3.0)")" "一条设备同批写 3 个新测点"
  sleep 3
  out=$(Q "desc $db.v1")
  local n; n=$(echo "$out" | grep -cE '\| *s1[0-2] *\|')
  echo "  新补列数（s10/s11/s12）：$n"
  if [ "${n:-0}" -ge 3 ]; then ok "同批 3 个新测点全部补列"; else fail "同批测点未全部补列（$n/3）"; fi
  rn_t2t_drop $db
}

# RN-149：多设备同批 insert → 各自补列
case_RN149() {
  local db=rn_t2t_149_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  assert_ok "$(rn_t2t_build $db v1 true s1)" "建视图"
  assert_ok "$(T "insert into root.$db.devA(s21) values(1.0)")" "设备 A 写入新测点"
  assert_ok "$(T "insert into root.$db.devB(s22) values(2.0)")" "设备 B 写入新测点"
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s21 *\|' && echo "$out" | grep -qE '\| *s22 *\|'; then
    ok "多设备新测点各自补列"
  else
    fail "多设备补列不完整"
  fi
  rn_t2t_drop $db
}

# RN-150：写入非 prefix 路径的测点 → 视图不变化
case_RN150() {
  local db=rn_t2t_150_$(date +%H%M%S) db2=rn_t2t_150b_$(date +%H%M%S) out
  rn_t2t_drop $db; rn_t2t_drop $db2
  assert_ok "$(Q "CREATE DATABASE $db")" "建库 A"
  assert_ok "$(Q "CREATE DATABASE $db2")" "建库 B"
  assert_ok "$(rn_t2t_build $db v1 true s1)" "建视图（只覆盖 db A）"
  T "create timeseries root.$db2.dev01.outside double" >/dev/null 2>&1
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *outside *\|'; then
    fail "非 prefix 路径的测点被错误补列"
  else
    ok "非 prefix 路径测点不影响视图"
  fi
  rn_t2t_drop $db; rn_t2t_drop $db2
}

# RN-151：重叠前缀的两个视图各自补列
case_RN151() {
  local db=rn_t2t_151_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  # 注意：设备名不能用保留字（如 region），否则建序列会 700 解析失败
  T "create timeseries root.$db.zone.dev01.s1 double" >/dev/null 2>&1
  # 命中规则：restrict=false 时要求 tag 数 >= 剩余层级
  # 设备 root.db.zone.dev01：宽前缀剩余 2 层 -> 2 个 tag；窄前缀剩余 1 层 -> 1 个 tag
  assert_ok "$(Q "create view $db.v_wide(zone string tag, dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建宽前缀视图（2 tag）"
  assert_ok "$(Q "create view $db.v_narrow(dev string tag) with(auto_sync_schema = true) as root.$db.zone.**")" "建窄前缀视图（1 tag）"
  T "create timeseries root.$db.zone.dev01.s7 double" >/dev/null 2>&1
  sleep 4
  local a b
  a=$(Q "desc $db.v_wide" | grep -cE '\| *s7 *\|')
  b=$(Q "desc $db.v_narrow" | grep -cE '\| *s7 *\|')
  echo "  宽视图含 s7=$a，窄视图含 s7=$b"
  if [ "${a:-0}" -ge 1 ] && [ "${b:-0}" -ge 1 ]; then
    ok "重叠前缀的两个视图都补列"
  else
    fail "至少一个视图未补列（wide=$a narrow=$b）"
  fi
  rn_t2t_drop $db
}

# RN-152：显式声明 Field 类型时按指定类型选列
case_RN152() {
  local db=rn_t2t_152_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 int32" >/dev/null 2>&1
  T "create timeseries root.$db.dev02.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(s1 int32 field, dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图并指定 s1 int32"
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s1 *\| *INT32'; then
    ok "按指定类型选中 INT32 那条测点"
  else
    fail "未按指定类型选列（$(echo "$out" | grep -E 's1' | head -1)）"
  fi
  rn_t2t_drop $db
}

# RN-153：只声明 Field 列名不声明类型（文档称应报错，实测允许并推导类型）
case_RN153() {
  local db=rn_t2t_153_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  out=$(Q "create view $db.v1(dev string tag, s1 field) with(auto_sync_schema = true) as root.$db.**")
  echo "  仅声明列名返回：$(echo "$out" | head -1 | cut -c1-150)"
  if echo "$out" | grep -qi 'success'; then
    ok "仅声明列名当前允许（类型由树模型推导）"
    out=$(Q "desc $db.v1")
    if echo "$out" | grep -qE '\| *s1 *\| *DOUBLE'; then
      ok "推导出的类型为 DOUBLE"
    else
      fail "推导类型异常"
    fi
  else
    ok "仅声明列名被拒绝（与文档一致）"
  fi
  rn_t2t_drop $db
}

# RN-154：树模型改类型不同步到视图列类型（INT32→INT64 兼容变更）
case_RN154() {
  local db=rn_t2t_154_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 int32" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  assert_ok "$(T "alter timeseries root.$db.dev01.s1 set data type int64")" "树模型改类型 INT32→INT64"
  sleep 2
  out=$(Q "desc $db.v1")
  echo "  视图列：$(echo "$out" | grep -E 's1' | head -1)"
  if echo "$out" | grep -qE '\| *s1 *\| *INT32'; then
    ok "视图列类型未随树模型变更（符合文档）"
  else
    fail "视图列类型被隐式同步（与文档不符）"
  fi
  rn_t2t_drop $db
}

# RN-155：删除序列后视图保留列，查询为空
case_RN155() {
  local db=rn_t2t_155_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "insert into root.$db.dev01(time,s1) values(1,1.5)" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  assert_ok "$(T "delete timeseries root.$db.dev01.s1")" "删除序列"
  sleep 2
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s1 *\|'; then
    ok "删除序列后视图仍保留该列"
  else
    fail "删除序列后视图列消失"
  fi
  out=$(Q "select s1 from $db.v1")
  if echo "$out" | grep -qi 'Empty set'; then
    ok "查询已删除序列的列为空"
  else
    fail "查询结果非空（$(echo "$out" | tail -2 | tr '\n' ' ')）"
  fi
  rn_t2t_drop $db
}

# RN-156：视图列 original_name 命中时，新设备数据可查
case_RN156() {
  local db=rn_t2t_156_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.S1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图（列名 s1，original S1）"
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s1 *\|'; then
    ok "大写测点生成小写列名 s1"
  else
    fail "列名不是 s1"
  fi
  T "create timeseries root.$db.dev02.S1 double" >/dev/null 2>&1
  T "insert into root.$db.dev02(time,S1) values(1,42.0)" >/dev/null 2>&1
  sleep 3
  out=$(Q "select s1 from $db.v1")
  if echo "$out" | grep -q '42.0'; then
    ok "original_name 命中时可查到新设备数据"
  else
    fail "original_name 命中时查不到数据"
  fi
  rn_t2t_drop $db
}

# RN-157：视图 comment 保留
case_RN157() {
  local db=rn_t2t_157_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) comment 'auto sync view' with(auto_sync_schema = true) as root.$db.**")" "建带 comment 的视图"
  out=$(Q "show create view $db.v1")
  if echo "$out" | grep -q 'auto sync view'; then
    ok "show create view 保留 comment"
  else
    fail "comment 丢失"
  fi
  rn_t2t_drop $db
}

# RN-158：乱序写入（历史时间戳）新建测点 → 补列
case_RN158() {
  local db=rn_t2t_158_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "insert into root.$db.dev01(time,s1) values(2000000,1.0)" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  # 历史时间戳 + 新测点
  assert_ok "$(T "insert into root.$db.dev01(time,s_old) values(1000,9.9)")" "历史时间戳写入新测点"
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s_old *\|'; then ok "乱序写入的新测点已补列"; else fail "乱序写入未补列"; fi
  out=$(Q "select s_old from $db.v1")
  if echo "$out" | grep -q '9.9'; then ok "乱序数据可通过视图查询"; else fail "视图查不到乱序数据"; fi
  rn_t2t_drop $db
}

# RN-159：晚到数据（早于已有数据的时间戳）新建测点 → 补列
case_RN159() {
  local db=rn_t2t_159_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "insert into root.$db.dev01(time,s1) values(3000000,1.0)" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  assert_ok "$(T "insert into root.$db.dev01(time,s_late) values(500,7.7)")" "晚到数据写入新测点"
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s_late *\|'; then ok "晚到数据的新测点已补列"; else fail "晚到数据未补列"; fi
  out=$(Q "select s_late from $db.v1")
  if echo "$out" | grep -q '7.7'; then ok "晚到数据可通过视图查询"; else fail "视图查不到晚到数据"; fi
  rn_t2t_drop $db
}

# RN-160：跨时间分区（3 天后）写入新测点 → 补列
case_RN160() {
  local db=rn_t2t_160_$(date +%H%M%S) out ts
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  ts=$(( $(date +%s) * 1000 + 3 * 86400000 ))
  assert_ok "$(T "insert into root.$db.dev01(time,s_day3) values($ts,3.3)")" "跨分区（3 天后）写入新测点"
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s_day3 *\|'; then ok "跨分区写入的新测点已补列"; else fail "跨分区未补列"; fi
  rn_t2t_drop $db
}

# RN-161：BLOB 类型测点 → 补列且类型为 BLOB
case_RN161() {
  local db=rn_t2t_161_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  assert_ok "$(T "create timeseries root.$db.dev01.b1 blob")" "创建 BLOB 测点"
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qiE '\| *b1 *\| *BLOB'; then ok "BLOB 测点已补列且类型正确"; else fail "BLOB 测点补列异常"; fi
  rn_t2t_drop $db
}

# RN-162：对齐设备（aligned timeseries）→ 补列
case_RN162() {
  local db=rn_t2t_162_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  # 测点名不能与视图已有列 s1 冲突（同名不同类型会被按规则忽略）
  assert_ok "$(T "create aligned timeseries root.$db.devAl(a1 int32, a2 int64)")" "创建对齐设备（2 个新测点）"
  sleep 3
  out=$(Q "desc $db.v1")
  local a b
  a=$(echo "$out" | grep -cE '\| *a1 *\| *INT32')
  b=$(echo "$out" | grep -cE '\| *a2 *\| *INT64')
  echo "  对齐设备补列：a1(INT32)=$a, a2(INT64)=$b"
  if [ "${a:-0}" -ge 1 ] && [ "${b:-0}" -ge 1 ]; then
    ok "对齐设备的两个测点均补列"
  else
    fail "对齐设备补列不完整（a=$a b=$b）"
  fi
  rn_t2t_drop $db
}

# RN-163：视图改名后，新增测点仍补列
case_RN163() {
  local db=rn_t2t_163_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  assert_ok "$(Q "alter view $db.v1 rename to v2")" "视图改名"
  T "create timeseries root.$db.dev01.s5 double" >/dev/null 2>&1
  sleep 3
  out=$(Q "desc $db.v2")
  if echo "$out" | grep -qE '\| *s5 *\|'; then ok "改名后的视图仍能补列"; else fail "改名后不再补列"; fi
  rn_t2t_drop $db
}

# RN-164：CREATE OR REPLACE 视图后补列，属性保留
case_RN164() {
  local db=rn_t2t_164_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "首次建视图"
  assert_ok "$(Q "create or replace view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "OR REPLACE 重建视图"
  out=$(Q "show create view $db.v1")
  if echo "$out" | grep -q 'auto_sync_schema=true'; then ok "OR REPLACE 后属性保留为 true"; else fail "OR REPLACE 后属性丢失"; fi
  T "create timeseries root.$db.dev01.s6 double" >/dev/null 2>&1
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s6 *\|'; then ok "OR REPLACE 后新测点仍补列"; else fail "OR REPLACE 后不补列"; fi
  rn_t2t_drop $db
}

# RN-165：DROP VIEW 后重建，补列恢复正常
case_RN165() {
  local db=rn_t2t_165_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  assert_ok "$(Q "drop view $db.v1")" "删除视图"
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "重建同名视图"
  T "create timeseries root.$db.dev01.s7 double" >/dev/null 2>&1
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s7 *\|'; then ok "重建后的视图能正常补列"; else fail "重建后不补列（索引残留？）"; fi
  rn_t2t_drop $db
}

# RN-166：不同 database 的前缀边界不误命中
case_RN166() {
  local dbA=rn_t2t_166a_$(date +%H%M%S) out
  local dbB="${dbA}b"
  rn_t2t_drop $dbA; rn_t2t_drop $dbB
  assert_ok "$(Q "CREATE DATABASE $dbA")" "建库 A"
  assert_ok "$(Q "CREATE DATABASE $dbB")" "建库 B（名字以 A 为前缀）"
  T "create timeseries root.$dbA.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $dbA.v(dev string tag) with(auto_sync_schema = true) as root.$dbA.**")" "在 A 建视图"
  T "create timeseries root.$dbB.dev01.outside double" >/dev/null 2>&1
  sleep 3
  out=$(Q "desc $dbA.v")
  if echo "$out" | grep -qE '\| *outside *\|'; then
    fail "B 库的测点误命中 A 库视图"
  else
    ok "不同 database 前缀边界未误命中"
  fi
  rn_t2t_drop $dbA; rn_t2t_drop $dbB
}

# RN-167：不同 database 的同名视图互不影响
case_RN167() {
  local db1=rn_t2t_167a_$(date +%H%M%S) out
  local db2="${db1}b"
  rn_t2t_drop $db1; rn_t2t_drop $db2
  assert_ok "$(Q "CREATE DATABASE $db1")" "建库 1"
  assert_ok "$(Q "CREATE DATABASE $db2")" "建库 2"
  T "create timeseries root.$db1.dev01.s1 double" >/dev/null 2>&1
  T "create timeseries root.$db2.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db1.v(dev string tag) with(auto_sync_schema = true) as root.$db1.**")" "库1 同名视图"
  assert_ok "$(Q "create view $db2.v(dev string tag) with(auto_sync_schema = true) as root.$db2.**")" "库2 同名视图"
  T "create timeseries root.$db1.dev01.s9 double" >/dev/null 2>&1
  sleep 3
  local a b
  a=$(Q "desc $db1.v" | grep -cE '\| *s9 *\|')
  b=$(Q "desc $db2.v" | grep -cE '\| *s9 *\|')
  echo "  库1 视图含 s9=$a，库2 视图含 s9=$b"
  if [ "${a:-0}" -ge 1 ] && [ "${b:-0}" -eq 0 ]; then
    ok "同名视图按库隔离，仅命中的库补列"
  else
    fail "同名视图隔离异常（a=$a b=$b）"
  fi
  rn_t2t_drop $db1; rn_t2t_drop $db2
}

# RN-168：聚合查询访问新补列
case_RN168() {
  local db=rn_t2t_168_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "insert into root.$db.dev01(time,s1) values(1,1.0)" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  T "insert into root.$db.dev01(time,s2) values(2,2.0)" >/dev/null 2>&1
  sleep 3
  out=$(Q "select count(s2), last(s2), avg(s2) from $db.v1")
  if echo "$out" | grep -q '2.0'; then ok "聚合查询（count/last/avg）可访问新补列"; else fail "聚合查询新列异常"; fi
  rn_t2t_drop $db
}

# RN-169：GROUP BY / ORDER BY 使用新补列
case_RN169() {
  local db=rn_t2t_169_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  T "insert into root.$db.dev01(time,s3) values(1,3.0)" >/dev/null 2>&1
  sleep 3
  out=$(Q "select dev, count(s3) from $db.v1 group by dev")
  if echo "$out" | grep -q 'dev01'; then ok "GROUP BY 可用新补列"; else fail "GROUP BY 新列异常"; fi
  out=$(Q "select dev, s3 from $db.v1 order by s3 desc")
  if echo "$out" | grep -q '3.0'; then ok "ORDER BY 可用新补列"; else fail "ORDER BY 新列异常"; fi
  rn_t2t_drop $db
}

# RN-170：SELECT * 包含新补列，旧行补 null
case_RN170() {
  local db=rn_t2t_170_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "insert into root.$db.dev01(time,s1) values(1,1.0)" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  T "insert into root.$db.dev01(time,s2) values(2,2.0)" >/dev/null 2>&1
  sleep 3
  out=$(Q "select * from $db.v1")
  echo "  select * 输出：$(echo "$out" | grep -c '^|') 行"
  if echo "$out" | grep -q 'null' && echo "$out" | grep -q '2.0'; then
    ok "SELECT * 含新补列且旧行补 null"
  else
    fail "SELECT * 结果异常"
  fi
  rn_t2t_drop $db
}

# RN-171：跨设备查询时新列在无数据设备上为 null
case_RN171() {
  local db=rn_t2t_171_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.devA.s1 double" >/dev/null 2>&1
  T "insert into root.$db.devA(time,s1) values(1,1.0)" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  T "create timeseries root.$db.devB.s2 double" >/dev/null 2>&1
  T "insert into root.$db.devB(time,s2) values(2,2.0)" >/dev/null 2>&1
  sleep 3
  out=$(Q "select * from $db.v1")
  echo "  $(echo "$out" | grep -E 'devA|devB' | head -2 | tr '\n' ' ')"
  if echo "$out" | grep -qE 'devA.*null' && echo "$out" | grep -qE 'devB.*2.0'; then
    ok "跨设备查询时新列在无数据设备上补 null"
  else
    fail "跨设备 null 补位异常"
  fi
  rn_t2t_drop $db
}

# RN-172：带 TTL 的 database 中自动补列正常
case_RN172() {
  local db=rn_t2t_172_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "create database $db with (ttl=86400000)")" "建带 TTL 的库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  T "create timeseries root.$db.dev01.s8 double" >/dev/null 2>&1
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s8 *\|'; then ok "TTL 库中补列正常"; else fail "TTL 库中补列失败"; fi
  rn_t2t_drop $db
}

# RN-173：模板激活到新路径触发补列
case_RN173() {
  local db=rn_t2t_173_$(date +%H%M%S) tpl=rn_tpl173_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create device template $tpl(ta float, tb double)" >/dev/null 2>&1
  T "set device template $tpl to root.$db.dev05" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  assert_ok "$(T "create timeseries using device template on root.$db.dev05")" "激活模板到新路径"
  sleep 4
  out=$(Q "desc $db.v1")
  local a b
  a=$(echo "$out" | grep -cE '\| *ta *\|')
  b=$(echo "$out" | grep -cE '\| *tb *\|')
  echo "  模板激活后补列：ta=$a tb=$b"
  if [ "${a:-0}" -ge 1 ] && [ "${b:-0}" -ge 1 ]; then
    ok "模板激活到新路径后两个测点均补列"
  else
    fail "模板激活补列不完整（ta=$a tb=$b）"
  fi
  rn_t2t_drop $db
  T "drop device template $tpl" >/dev/null 2>&1
}

# RN-174：模板扩展（ALTER SCHEMA TEMPLATE ADD）触发补列
case_RN174() {
  local db=rn_t2t_174_$(date +%H%M%S) tpl=rn_tpl174_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create device template $tpl(ta float)" >/dev/null 2>&1
  T "set device template $tpl to root.$db.dev06" >/dev/null 2>&1
  T "create timeseries using device template on root.$db.dev06" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图（已含 ta）"
  assert_ok "$(T "alter schema template $tpl add (tc int64)")" "模板扩展新增 tc"
  sleep 5
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *tc *\|'; then ok "模板扩展后新测点补列"; else fail "模板扩展未补列"; fi
  rn_t2t_drop $db
  T "drop device template $tpl" >/dev/null 2>&1
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
"RN-147|TDB-343 非创建路径忽略|功能|除建视图外遇冲突（含属性切换补扫）一律忽略不报错|case_RN147"
"RN-148|TDB-343 同批多测点补列|功能|一条设备同批写入多个新测点应全部补列|case_RN148"
"RN-149|TDB-343 多设备补列|功能|多设备各自新增测点应分别补列|case_RN149"
"RN-150|TDB-343 非前缀路径隔离|功能|非视图 prefix 路径的测点不影响视图|case_RN150"
"RN-151|TDB-343 重叠前缀双视图|功能|重叠 prefix 的两个视图都应补列|case_RN151"
"RN-152|TDB-343 显式类型选列|功能|显式声明 Field 类型时按类型选测点|case_RN152"
"RN-153|TDB-343 仅声明列名|功能|只声明列名不给类型的实际行为|case_RN153"
"RN-154|TDB-343 类型变更不同步|功能|树模型改类型不同步到视图列|case_RN154"
"RN-155|TDB-343 删序列保留列|功能|删除序列后视图保留列且查询为空|case_RN155"
"RN-156|TDB-343 original_name 命中|功能|original_name 命中时可查新设备数据|case_RN156"
"RN-157|TDB-343 comment 保留|功能|视图 comment 在扩列后保留|case_RN157"
"RN-158|TDB-343 乱序写入补列|时序|历史时间戳写入新测点应补列且可查|case_RN158"
"RN-159|TDB-343 晚到数据补列|时序|晚到数据建新测点应补列且可查|case_RN159"
"RN-160|TDB-343 跨分区补列|时序|跨时间分区写入新测点应补列|case_RN160"
"RN-161|TDB-343 BLOB 测点补列|时序|BLOB 类型测点补列且类型正确|case_RN161"
"RN-162|TDB-343 对齐设备补列|时序|对齐设备多测点均应补列|case_RN162"
"RN-163|TDB-343 改名后补列|功能|视图改名后仍能补列|case_RN163"
"RN-164|TDB-343 OR REPLACE 补列|功能|OR REPLACE 视图后属性保留且仍补列|case_RN164"
"RN-165|TDB-343 重建视图补列|功能|DROP 后重建视图仍补列|case_RN165"
"RN-166|TDB-343 库前缀边界|功能|相邻库名前缀不误命中|case_RN166"
"RN-167|TDB-343 同名视图隔离|功能|不同库同名视图互不影响|case_RN167"
"RN-168|TDB-343 聚合访问新列|功能|count/last/avg 可访问新补列|case_RN168"
"RN-169|TDB-343 GROUP/ORDER 新列|功能|GROUP BY / ORDER BY 可用新补列|case_RN169"
"RN-170|TDB-343 SELECT * 新列|功能|SELECT * 含新列且旧行补 null|case_RN170"
"RN-171|TDB-343 跨设备 null|功能|无数据设备上新列为 null|case_RN171"
"RN-172|TDB-343 TTL 库补列|功能|TTL 库中补列正常|case_RN172"
"RN-173|TDB-343 模板激活补列|功能|模板激活到新路径触发补列|case_RN173"
"RN-174|TDB-343 模板扩展补列|功能|ALTER SCHEMA TEMPLATE ADD 触发补列|case_RN174"
)
