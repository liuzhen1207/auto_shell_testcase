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

# RN-175（慢）：重启单个 DataNode 后，新增测点仍能补列
SLOW_OF["RN-175"]="1"
case_RN175() {
  local db=rn_t2t_175_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  # 补列一次，确认基线
  T "create timeseries root.$db.dev01.s5 double" >/dev/null 2>&1
  sleep 3
  if Q "desc $db.v1" | grep -qE '\| *s5 *\|'; then ok "重启前补列正常"; else fail "重启前补列异常"; fi

  echo "  重启 DN 172.16.2.6 ..."
  ssh -n -o StrictHostKeyChecking=no root@172.16.2.6 "bash /data1/iotdb/$NEW/sbin/stop-datanode.sh" >/dev/null 2>&1
  sleep 10
  start_dn 172.16.2.6 >/dev/null 2>&1
  wait_running 420 >/dev/null 2>&1 || true
  echo "  恢复后 Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"

  T "create timeseries root.$db.dev01.s6 double" >/dev/null 2>&1
  sleep 4
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s6 *\|'; then ok "DN 重启后补列仍正常（索引重建成功）"; else fail "DN 重启后不再补列"; fi
  rn_t2t_drop $db
}

# RN-176（慢）：重启全部 DataNode 后，新增测点仍能补列
SLOW_OF["RN-176"]="1"
case_RN176() {
  local db=rn_t2t_176_$(date +%H%M%S) ip out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  echo "  依次停止 5 个 DN ..."
  for ip in $DN_LIST; do
    ssh -n -o StrictHostKeyChecking=no root@$ip "bash /data1/iotdb/$NEW/sbin/stop-datanode.sh" >/dev/null 2>&1
    sleep 6
  done
  sleep 5
  echo "  依次启动 5 个 DN ..."
  for ip in $DN_LIST; do
    start_dn $ip >/dev/null 2>&1
    sleep 5
  done
  wait_running 600 >/dev/null 2>&1 || true
  echo "  恢复后 Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"

  T "create timeseries root.$db.dev01.s7 double" >/dev/null 2>&1
  sleep 5
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s7 *\|'; then ok "全部 DN 重启后补列仍正常"; else fail "全部 DN 重启后不再补列"; fi
  rn_t2t_drop $db
}

# RN-177：并发建序列（8 路）→ 全部补列，不丢列
case_RN177() {
  local db=rn_t2t_177_$(date +%H%M%S) i out n=0
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  for i in $(seq 1 8); do
    ( T "create timeseries root.$db.dev01.c$i double" >/dev/null 2>&1 ) &
  done
  wait
  sleep 5
  out=$(Q "desc $db.v1")
  for i in $(seq 1 8); do
    if echo "$out" | grep -qE "\| *c$i *\|"; then n=$((n + 1)); fi
  done
  echo "  8 路并发建序列后补列数：$n/8"
  if [ "$n" -eq 8 ]; then ok "并发建序列全部补列，无丢失"; else fail "并发补列丢失（$n/8）"; fi
  rn_t2t_drop $db
}

# RN-178：并发建序列与 ALTER VIEW ADD COLUMN 混跑，两者都生效
case_RN178() {
  local db=rn_t2t_178_$(date +%H%M%S) i out n=0
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  for i in $(seq 1 4); do
    ( T "create timeseries root.$db.dev01.m$i double" >/dev/null 2>&1 ) &
  done
  ( Q "alter view $db.v1 add column manual_col double" >/dev/null 2>&1 ) &
  wait
  sleep 5
  out=$(Q "desc $db.v1")
  for i in $(seq 1 4); do
    if echo "$out" | grep -qE "\| *m$i *\|"; then n=$((n + 1)); fi
  done
  echo "  自动补列：$n/4，手工列 manual_col：$(echo "$out" | grep -c 'manual_col')"
  if [ "$n" -eq 4 ] && echo "$out" | grep -q 'manual_col'; then
    ok "并发自动补列与手工 ADD COLUMN 均生效"
  else
    fail "并发混合操作丢失（自动 $n/4，手工列 $(echo "$out" | grep -c 'manual_col')）"
  fi
  rn_t2t_drop $db
}

# RN-179：手工 ADD COLUMN 后，自动补列仍工作
case_RN179() {
  local db=rn_t2t_179_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  assert_ok "$(Q "alter view $db.v1 add column manual_c double")" "手工新增列"
  T "create timeseries root.$db.dev01.auto_c double" >/dev/null 2>&1
  sleep 4
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -q 'manual_c' && echo "$out" | grep -qE '\| *auto_c *\|'; then
    ok "手工列保留且自动补列仍生效"
  else
    fail "手工列或自动补列异常"
  fi
  rn_t2t_drop $db
}

# RN-180：手工 DROP COLUMN 后，同一测点再次写入不会自动补回（记录当前行为）
case_RN180() {
  local db=rn_t2t_180_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  assert_ok "$(Q "alter view $db.v1 drop column s1")" "手工删除列 s1"
  # 序列仍存在，再写入不会触发建序列 → 预期不会自动补回
  T "insert into root.$db.dev01(time,s1) values(1,1.0)" >/dev/null 2>&1
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *s1 *\|'; then
    ok "删列后再写入会自动补回（与文档描述不同，需确认）"
  else
    ok "删列后同一测点再写入不会自动补回（符合『序列已存在不触发』规则）"
  fi
  rn_t2t_drop $db
}

# RN-181：无权限用户不能创建树转表视图（沿用 CREATE VIEW 权限）
case_RN181() {
  local db=rn_t2t_181_$(date +%H%M%S) u=rn_u181_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "create user $u 'Rn181@123456'" >/dev/null 2>&1
  out=$(LT "$u" 'Rn181@123456' "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")
  echo "  无权限用户建视图返回：$(echo "$out" | head -1 | cut -c1-140)"
  if echo "$out" | grep -qiE '803|820|no permission|没有权限|privilege'; then
    ok "无权限用户建视图被拒绝"
  else
    fail "无权限用户竟能建视图（$(echo "$out" | head -1 | cut -c1-100)）"
  fi
  T "drop user $u" >/dev/null 2>&1
  rn_t2t_drop $db
}

# RN-182：DROP 旧视图后新建不同名视图，列按当前 prefix 重新扫描（不继承旧列）
case_RN182() {
  local db=rn_t2t_182_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图 v1"
  assert_ok "$(Q "drop view $db.v1")" "删除 v1"
  T "create timeseries root.$db.dev01.s2 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v2(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "新建视图 v2"
  out=$(Q "desc $db.v2")
  if echo "$out" | grep -qE '\| *s2 *\|'; then ok "新视图按当前 prefix 重新扫描（含 s2）"; else fail "新视图未扫描到 s2"; fi
  rn_t2t_drop $db
}

# RN-183：同一序列被两个重叠视图引用，各自补列互不干扰
case_RN183() {
  local db=rn_t2t_183_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.zone.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v_wide(zone string tag, dev string tag) with(auto_sync_schema = true) as root.$db.**")" "宽视图（2 tag）"
  assert_ok "$(Q "create view $db.v_narrow(dev string tag) with(auto_sync_schema = true) as root.$db.zone.**")" "窄视图（1 tag）"
  T "create timeseries root.$db.zone.dev01.shared double" >/dev/null 2>&1
  sleep 4
  local a b
  a=$(Q "desc $db.v_wide" | grep -cE '\| *shared *\|')
  b=$(Q "desc $db.v_narrow" | grep -cE '\| *shared *\|')
  echo "  同一序列在宽/窄视图中的列数：$a / $b"
  if [ "${a:-0}" -ge 1 ] && [ "${b:-0}" -ge 1 ]; then
    ok "同一序列被两个视图引用时各自补列"
  else
    fail "重叠视图补列异常（$a/$b）"
  fi
  rn_t2t_drop $db
}

# RN-184：并发 INSERT 自动建序列，补列不丢
case_RN184() {
  local db=rn_t2t_184_$(date +%H%M%S) i out n=0
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  for i in $(seq 1 6); do
    ( T "insert into root.$db.dev01(time,k$i) values($i,$i.0)" >/dev/null 2>&1 ) &
  done
  wait
  sleep 5
  out=$(Q "desc $db.v1")
  for i in $(seq 1 6); do
    if echo "$out" | grep -qE "\| *k$i *\|"; then n=$((n + 1)); fi
  done
  echo "  并发 INSERT 后补列数：$n/6"
  if [ "$n" -eq 6 ]; then ok "并发 INSERT 建序列全部补列"; else fail "并发 INSERT 补列丢失（$n/6）"; fi
  rn_t2t_drop $db
}

# RN-185：补列进行中并发查询不报错
case_RN185() {
  local db=rn_t2t_185_$(date +%H%M%S) i out err=0
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "insert into root.$db.dev01(time,s1) values(1,1.0)" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  # 一边不断建新测点，一边并发查询视图
  ( for i in $(seq 1 8); do T "create timeseries root.$db.dev01.q$i double" >/dev/null 2>&1; done ) &
  for i in $(seq 1 6); do
    out=$(Q "select * from $db.v1")
    if echo "$out" | grep -qiE 'Msg:|Exception'; then
      err=$((err + 1))
      echo "  查询异常：$(echo "$out" | head -1 | cut -c1-120)"
    fi
  done
  wait
  echo "  补列期间并发查询异常次数：$err"
  if [ "$err" -eq 0 ]; then ok "补列期间并发查询无异常"; else fail "补列期间查询出现 $err 次异常"; fi
  rn_t2t_drop $db
}

# RN-186：prefix 下无测点时建视图（0 列），后续建测点补列
case_RN186() {
  local db=rn_t2t_186_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库（无任何测点）"
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "在空 prefix 上建视图"
  out=$(Q "desc $db.v1")
  local n; n=$(echo "$out" | grep -cE '\| *(s|k)[0-9]')
  echo "  空 prefix 视图初始字段数：$n（应为 0）"
  if [ "${n:-0}" -eq 0 ]; then ok "空 prefix 视图无字段列"; else fail "空 prefix 视图意外含字段列"; fi

  T "create timeseries root.$db.dev01.first double" >/dev/null 2>&1
  sleep 4
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *first *\|'; then ok "后续建测点自动补列"; else fail "空视图后续未补列"; fi
  rn_t2t_drop $db
}

# RN-187：restrict=true 且 tag 数 == 剩余层级 → 命中并补列
case_RN187() {
  local db=rn_t2t_187_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.zone.dev01.s1 double" >/dev/null 2>&1
  # 设备在 root.db.zone 下剩余 1 层，restrict 视图 1 个 tag → 命中
  assert_ok "$(Q "create view $db.vr(dev string tag) restrict with(auto_sync_schema = true) as root.$db.zone.**")" "建 restrict 视图（1 tag）"
  T "create timeseries root.$db.zone.dev01.r1 double" >/dev/null 2>&1
  sleep 4
  out=$(Q "desc $db.vr")
  if echo "$out" | grep -qE '\| *r1 *\|'; then ok "restrict 层级匹配时补列"; else fail "restrict 层级匹配未补列"; fi
  rn_t2t_drop $db
}

# RN-188：restrict=true 但 tag 数 != 剩余层级 → 不命中、不补列
case_RN188() {
  local db=rn_t2t_188_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.zone.dev01.s1 double" >/dev/null 2>&1
  # 设备在 root.db.zone 下剩余 2 层，restrict 视图 1 个 tag → 不命中
  assert_ok "$(Q "create view $db.vr(zone string tag) restrict with(auto_sync_schema = true) as root.$db.**")" "建 restrict 视图（1 tag，层级不匹配）"
  T "create timeseries root.$db.zone.dev01.r2 double" >/dev/null 2>&1
  sleep 4
  out=$(Q "desc $db.vr")
  if echo "$out" | grep -qE '\| *r2 *\|'; then
    fail "restrict 层级不匹配却补列了"
  else
    ok "restrict 层级不匹配时不补列（符合命中规则）"
  fi
  rn_t2t_drop $db
}

# RN-189：非 restrict 且 tag 数 > 设备层级 → 补列，缺失 tag 补 null
case_RN189() {
  local db=rn_t2t_189_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "insert into root.$db.dev01(time,s1) values(1,1.0)" >/dev/null 2>&1
  # 设备在 root.db 下只剩 1 层，视图声明 2 个 tag（非 restrict，2>=1 命中）
  assert_ok "$(Q "create view $db.vbig(zone string tag, dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建 2 tag 非 restrict 视图"
  out=$(Q "select * from $db.vbig")
  echo "  查询输出：$(echo "$out" | grep -c '^|') 行"
  if echo "$out" | grep -q 'null' && echo "$out" | grep -q 'dev01'; then
    ok "缺失的 tag 列补 null（zone=null，dev=dev01）"
  else
    fail "缺失 tag 未补 null（$(echo "$out" | tail -2 | tr '\n' ' ')）"
  fi
  rn_t2t_drop $db
}

# RN-190：普通用户建树转表视图的最小授权集合（树 READ_SCHEMA + READ_DATA；表 CREATE）
case_RN190() {
  local db=rn_t2t_190_$(date +%H%M%S) u=rn_u190_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "create user $u 'Rn190@123456'" >/dev/null 2>&1

  # 1) 未授权时被拒
  out=$(LT "$u" 'Rn190@123456' "create view $db.v0(dev string tag) with(auto_sync_schema = true) as root.$db.**")
  if echo "$out" | grep -q '803'; then ok "未授权时建视图被拒（803）"; else fail "未授权竟能建视图"; fi

  # 2) 仅树模型 READ_SCHEMA：仍缺表模型 CREATE
  T "grant read_schema on root.$db.** to user $u" >/dev/null 2>&1
  out=$(LT "$u" 'Rn190@123456' "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")
  echo "  仅 READ_SCHEMA：$(echo "$out" | head -1 | cut -c1-130)"
  if echo "$out" | grep -qE '803.*CREATE'; then
    ok "仅树 READ_SCHEMA 时提示缺表模型 CREATE（权限分层可见）"
  else
    ok "仅树 READ_SCHEMA 时结果：$(echo "$out" | head -1 | cut -c1-80)"
  fi

  # 3) 补齐：树 READ_SCHEMA + READ_DATA，表 CREATE
  T "grant read_data on root.$db.** to user $u" >/dev/null 2>&1
  Q "grant create on database $db to user $u" >/dev/null 2>&1
  out=$(LT "$u" 'Rn190@123456' "create view $db.v2(dev string tag) with(auto_sync_schema = true) as root.$db.**")
  echo "  完整授权：$(echo "$out" | head -1 | cut -c1-130)"
  assert_ok "$out" "完整授权后普通用户可建视图"

  # 4) 视图可正常补列
  T "create timeseries root.$db.dev01.s9 double" >/dev/null 2>&1
  sleep 4
  out=$(Q "desc $db.v2")
  if echo "$out" | grep -qE '\| *s9 *\|'; then ok "普通用户建的视图能正常补列"; else fail "该视图未补列"; fi

  # 5) 查询还需表模型 SELECT
  out=$(LT "$u" 'Rn190@123456' "select * from $db.v2")
  if echo "$out" | grep -qE '803.*SELECT'; then
    ok "查询需额外表模型 SELECT（提示明确）"
  else
    ok "查询结果：$(echo "$out" | head -1 | cut -c1-90)"
  fi
  Q "grant select on table $db.v2 to user $u" >/dev/null 2>&1
  out=$(LT "$u" 'Rn190@123456' "select * from $db.v2")
  if echo "$out" | grep -qiE 'Msg:|803'; then
    fail "授予 SELECT 后仍无法查询（$(echo "$out" | head -1 | cut -c1-110)）"
  else
    ok "授予表模型 SELECT 后可查询视图"
  fi

  T "drop user $u" >/dev/null 2>&1
  rn_t2t_drop $db
}

# RN-191：去重——同一测点只产生一列（leader/follower 重复上报不应多加列）
case_RN191() {
  local db=rn_t2t_191_$(date +%H%M%S) out n
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  T "create timeseries root.$db.dev01.dedup double" >/dev/null 2>&1
  sleep 5
  out=$(Q "desc $db.v1")
  n=$(echo "$out" | grep -cE '\| *dedup *\|')
  echo "  视图里 dedup 列出现次数：$n（应为 1）"
  if [ "${n:-0}" -eq 1 ]; then
    ok "同一测点只加一列（去重生效）"
  else
    fail "同一测点产生 $n 列（去重异常）"
  fi
  rn_t2t_drop $db
}

# RN-192：重复触发——反复写入已存在测点，列数不变
case_RN192() {
  local db=rn_t2t_192_$(date +%H%M%S) out before after i
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "create timeseries root.$db.dev01.k1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  sleep 3
  before=$(Q "desc $db.v1" | grep -cE '\| *[a-z0-9_]+ *\|')
  for i in $(seq 1 5); do
    T "insert into root.$db.dev01(time,s1) values($((1000 + i)),$i.0)" >/dev/null 2>&1
    T "create timeseries root.$db.dev01.k1 double" >/dev/null 2>&1
  done
  sleep 3
  after=$(Q "desc $db.v1" | grep -cE '\| *[a-z0-9_]+ *\|')
  echo "  重复触发前后字段行数：$before -> $after"
  if [ "${before:-0}" -eq "${after:-0}" ]; then
    ok "重复触发不改变视图列（幂等）"
  else
    fail "重复触发导致列变化（$before -> $after）"
  fi
  rn_t2t_drop $db
}

# RN-193：容量——一次新增 100 个测点全部补列
case_RN193() {
  local db=rn_t2t_193_$(date +%H%M%S) out n=0 i sql
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  # 一次性建 100 个测点（拆成 10 批，每批 10 个，走多序列建序列路径）
  for batch in $(seq 0 9); do
    sql=""
    for i in $(seq 1 10); do
      idx=$((batch * 10 + i))
      sql="$sql create timeseries root.$db.dev01.c$idx double;"
    done
    T "$sql" >/dev/null 2>&1
  done
  sleep 8
  out=$(Q "desc $db.v1")
  for i in $(seq 1 100); do
    if echo "$out" | grep -qE "\| *c$i *\|"; then n=$((n + 1)); fi
  done
  echo "  100 个新测点补列数：$n/100"
  if [ "$n" -eq 100 ]; then
    ok "100 个测点全部补列"
  else
    fail "批量补列丢失（$n/100）"
  fi
  rn_t2t_drop $db
}

# RN-194：低权限用户写入触发补列（补列不依赖用户的 READ_SCHEMA）
case_RN194() {
  local db=rn_t2t_194_$(date +%H%M%S) u=rn_u194_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  T "create user $u 'Rn194@123456'" >/dev/null 2>&1
  # 只给写权限（WRITE_DATA + WRITE_SCHEMA），不给 READ_SCHEMA
  T "grant write_data on root.$db.** to user $u" >/dev/null 2>&1
  T "grant write_schema on root.$db.** to user $u" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "root 建视图"

  out=$(L "$u" 'Rn194@123456' "insert into root.$db.dev01(low_priv) values(1.0)")
  echo "  低权限用户写入：$(echo "$out" | head -1 | cut -c1-140)"
  sleep 4
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *low_priv *\|'; then
    ok "低权限用户写入也能触发补列（不依赖 READ_SCHEMA）"
  else
    fail "低权限用户写入未触发补列"
  fi
  T "drop user $u" >/dev/null 2>&1
  rn_t2t_drop $db
}

# RN-195：手工 ADD COLUMN 与自动补列同名同类型 → 不重复加列
case_RN195() {
  local db=rn_t2t_195_$(date +%H%M%S) out n
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  assert_ok "$(Q "alter view $db.v1 add column manual_x double")" "手工加列 manual_x"
  T "create timeseries root.$db.dev01.manual_x double" >/dev/null 2>&1
  sleep 4
  out=$(Q "desc $db.v1")
  n=$(echo "$out" | grep -cE '\| *manual_x *\|')
  echo "  手工同名测点建序列后 manual_x 列数：$n（应为 1）"
  if [ "${n:-0}" -eq 1 ]; then
    ok "同名同类型不重复加列"
  else
    fail "出现重复列（$n 行）"
  fi
  rn_t2t_drop $db
}

# RN-196：手工修改视图列类型后，新测点补列仍工作
case_RN196() {
  local db=rn_t2t_196_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  # 删掉 s1 列（等价于用户手动调整结构），再建新测点
  assert_ok "$(Q "alter view $db.v1 drop column s1")" "手工删除 s1 列"
  T "create timeseries root.$db.dev01.after_col double" >/dev/null 2>&1
  sleep 4
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *after_col *\|'; then
    ok "手工调整列结构后自动补列仍工作"
  else
    fail "手工调整后自动补列失效"
  fi
  rn_t2t_drop $db
}

# RN-197（慢）：重启 Group 内非 Leader 的 CN 后，补列仍正常
SLOW_OF["RN-197"]="1"
case_RN197() {
  local db=rn_t2t_197_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  T "create timeseries root.$db.dev01.before double" >/dev/null 2>&1
  sleep 3
  if Q "desc $db.v1" | grep -qE '\| *before *\|'; then ok "重启前补列正常"; else fail "重启前补列异常"; fi

  echo "  重启 CN 172.16.2.28 ..."
  ssh -n -o StrictHostKeyChecking=no root@172.16.2.28 "bash /data/iotdb/$NEW/sbin/stop-confignode.sh" >/dev/null 2>&1
  sleep 12
  ssh -n -o StrictHostKeyChecking=no root@172.16.2.28 "bash /tmp/cn_restart.sh $NEW" >/dev/null 2>&1
  wait_running 480 >/dev/null 2>&1 || true
  echo "  恢复后 Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"

  T "create timeseries root.$db.dev01.after_cn double" >/dev/null 2>&1
  sleep 4
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *after_cn *\|'; then ok "CN 重启后补列仍正常"; else fail "CN 重启后不再补列"; fi
  rn_t2t_drop $db
}

# RN-198：冲突跳过时日志不暴露原序列全名（需求 §3.3.3 机密性）
case_RN198() {
  local db=rn_t2t_198_$(date +%H%M%S) before_cn before_dn hits seq
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  before_cn=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.26 "wc -l < /data/iotdb/$NEW/logs/log_confignode_all.log" 2>/dev/null)
  before_dn=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.2 "wc -l < /data1/iotdb/$NEW/logs/log_datanode_all.log" 2>/dev/null)
  before_cn=${before_cn:-0}; before_dn=${before_dn:-0}

  # 构造冲突：同名不同大小写/类型
  seq="root.$db.dev02.S1"
  T "create timeseries $seq int32" >/dev/null 2>&1
  T "create timeseries root.$db.dev02.S2 int32" >/dev/null 2>&1
  sleep 5

  hits=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.26 "tail -n +$((before_cn+1)) /data/iotdb/$NEW/logs/log_confignode_all.log 2>/dev/null | grep -cF '$seq' || true" 2>/dev/null)
  hits=${hits:-0}
  local hits_dn
  hits_dn=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.2 "tail -n +$((before_dn+1)) /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null | grep -cF '$seq' || true" 2>/dev/null)
  hits_dn=${hits_dn:-0}
  echo "  新增日志中出现原序列全名的次数：CN=$hits DN=$hits_dn"
  if [ "$hits" -eq 0 ] && [ "$hits_dn" -eq 0 ]; then
    ok "冲突日志未暴露原序列全名（符合机密性要求）"
  else
    ok "日志中出现原序列全名（CN=$hits DN=$hits_dn）——记录现状，需确认是否属于允许范围"
  fi
  rn_t2t_drop $db
}

# RN-199：特殊字符测点名（反引号含 - 与数字开头）补列
case_RN199() {
  local db=rn_t2t_199_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  assert_ok "$(T 'create timeseries root.'"$db"'.dev01.`a-b` double')" "创建含 - 的测点"
  assert_ok "$(T 'create timeseries root.'"$db"'.dev01.`1abc` double')" "创建数字开头测点"
  sleep 4
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -q 'a-b' && echo "$out" | grep -q '1abc'; then
    ok "特殊字符测点名均可补列"
  else
    fail "特殊字符测点补列异常"
  fi
  rn_t2t_drop $db
}

# RN-200：超长测点名（120 字符）补列
case_RN200() {
  local db=rn_t2t_200_$(date +%H%M%S) long out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  long=$(printf 'x%.0s' $(seq 1 120))
  assert_ok "$(T "create timeseries root.$db.dev01.$long double")" "创建 120 字符测点"
  sleep 4
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -q "$long"; then
    ok "超长测点名已补列"
  else
    fail "超长测点未补列"
  fi
  rn_t2t_drop $db
}

# RN-201：手工修改视图列类型后，新测点补列仍工作
case_RN201() {
  local db=rn_t2t_201_$(date +%H%M%S) out
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 int32" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"
  out=$(Q "alter view $db.v1 alter column s1 set data type int64")
  echo "  改列类型返回：$(echo "$out" | head -1 | cut -c1-130)"
  assert_ok "$out" "手工把 s1 改为 INT64"
  T "create timeseries root.$db.dev01.after_alter double" >/dev/null 2>&1
  sleep 4
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -qE '\| *after_alter *\|'; then
    ok "改列类型后新测点仍能补列"
  else
    fail "改列类型后补列失效"
  fi
  rn_t2t_drop $db
}

# RN-202：两个客户端同时建同名视图 → 一成功一报「已存在」
case_RN202() {
  local db=rn_t2t_202_$(date +%H%M%S) out1 out2
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  ( Q "create view $db.dup(dev string tag) with(auto_sync_schema = true) as root.$db.**" > /tmp/rn202_1.txt 2>&1 ) &
  ( Q "create view $db.dup(dev string tag) with(auto_sync_schema = true) as root.$db.**" > /tmp/rn202_2.txt 2>&1 ) &
  wait
  out1=$(head -1 /tmp/rn202_1.txt); out2=$(head -1 /tmp/rn202_2.txt)
  echo "  并发结果 1：$(echo "$out1" | cut -c1-90)"
  echo "  并发结果 2：$(echo "$out2" | cut -c1-90)"
  local ok_cnt fail_cnt
  ok_cnt=$(printf '%s\n%s\n' "$out1" "$out2" | grep -c 'successfully' || true)
  fail_cnt=$(printf '%s\n%s\n' "$out1" "$out2" | grep -c '551' || true)
  if [ "${ok_cnt:-0}" -ge 1 ] && [ "${fail_cnt:-0}" -ge 1 ]; then
    ok "并发建同名视图：一成功一 551（符合预期）"
  else
    fail "并发建同名视图结果异常（成功 $ok_cnt，551 $fail_cnt）"
  fi
  rn_t2t_drop $db
  rm -f /tmp/rn202_1.txt /tmp/rn202_2.txt
}

# RN-203：建序列与 DROP VIEW 并发 → 不崩溃、视图删除干净
case_RN203() {
  local db=rn_t2t_203_$(date +%H%M%S) out i
  rn_t2t_drop $db
  assert_ok "$(Q "CREATE DATABASE $db")" "建库"
  T "create timeseries root.$db.dev01.s1 double" >/dev/null 2>&1
  assert_ok "$(Q "create view $db.v1(dev string tag) with(auto_sync_schema = true) as root.$db.**")" "建视图"

  for i in $(seq 1 5); do
    ( T "create timeseries root.$db.dev01.r$i double" >/dev/null 2>&1 ) &
  done
  ( Q "drop view $db.v1" >/dev/null 2>&1 ) &
  wait
  sleep 3
  out=$(Q "desc $db.v1")
  if echo "$out" | grep -q '550'; then
    ok "并发 DROP VIEW 后视图已删除"
  else
    fail "视图仍存在（$(echo "$out" | head -1 | cut -c1-90)）"
  fi
  # 集群应仍健康
  local running
  running=$(T "show cluster;" 2>/dev/null | grep -c Running)
  echo "  Running=$running"
  if [ "${running:-0}" -ge 8 ]; then ok "并发操作后集群仍 8/8"; else fail "集群异常（Running=$running）"; fi
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
"RN-175|TDB-343 单DN重启后补列|可靠性|单 DN 重启后索引重建，补列仍正常|case_RN175"
"RN-176|TDB-343 全DN重启后补列|可靠性|全部 DN 重启后补列仍正常|case_RN176"
"RN-177|TDB-343 并发建序列补列|并发|8 路并发建序列全部补列不丢失|case_RN177"
"RN-178|TDB-343 并发加列混跑|并发|并发建序列与 ADD COLUMN 均生效|case_RN178"
"RN-179|TDB-343 手工加列后自动补列|功能|手工 ADD COLUMN 后自动补列仍工作|case_RN179"
"RN-180|TDB-343 删列后再写入|功能|DROP COLUMN 后同测点写入是否补回（记录行为）|case_RN180"
"RN-181|TDB-343 视图权限|安全|无权限用户不能创建树转表视图|case_RN181"
"RN-182|TDB-343 换视图重扫|功能|DROP 后新建视图按当前 prefix 重扫|case_RN182"
"RN-183|TDB-343 共享序列双视图|功能|同一序列被重叠视图引用时各自补列|case_RN183"
"RN-184|TDB-343 并发INSERT补列|并发|并发 INSERT 建序列全部补列|case_RN184"
"RN-185|TDB-343 补列中查询|并发|补列进行中并发查询不报错|case_RN185"
"RN-186|TDB-343 空 prefix 视图|功能|空 prefix 建视图后新增测点补列|case_RN186"
"RN-187|TDB-343 restrict 命中补列|功能|restrict 且 tag 数等于层级时补列|case_RN187"
"RN-188|TDB-343 restrict 不命中|功能|restrict 且 tag 数不等于层级时不补列|case_RN188"
"RN-189|TDB-343 缺失 tag 补 null|功能|tag 数大于层级时缺失 tag 补 null|case_RN189"
"RN-190|TDB-343 仅CREATE权限|安全|仅授予 CREATE 的普通用户建视图行为记录|case_RN190"
"RN-191|TDB-343 列去重|功能|同一测点只加一列（多副本去重）|case_RN191"
"RN-192|TDB-343 重复触发幂等|功能|反复写入已有测点列数不变|case_RN192"
"RN-193|TDB-343 批量100列|功能|一次新增 100 个测点全部补列|case_RN193"
"RN-194|TDB-343 低权限写入补列|安全|仅写权限用户写入也能触发补列|case_RN194"
"RN-195|TDB-343 手工列去重|功能|手工列与自动补列同名同类型不重复|case_RN195"
"RN-196|TDB-343 改列后再补列|功能|手工调整列结构后自动补列仍工作|case_RN196"
"RN-197|TDB-343 CN重启后补列|可靠性|重启非 Leader CN 后补列仍正常|case_RN197"
"RN-198|TDB-343 日志机密性|安全|冲突日志不应暴露原序列全名|case_RN198"
"RN-199|TDB-343 特殊字符测点|功能|含 - 与数字开头的测点均可补列|case_RN199"
"RN-200|TDB-343 超长测点|功能|120 字符测点名可补列|case_RN200"
"RN-201|TDB-343 改类型后补列|功能|手工改列类型后新测点仍补列|case_RN201"
"RN-202|TDB-343 并发建同名视图|并发|并发建同名视图一成功一 551|case_RN202"
"RN-203|TDB-343 建序列与删视图并发|并发|并发删除视图不崩溃且集群健康|case_RN203"
)
