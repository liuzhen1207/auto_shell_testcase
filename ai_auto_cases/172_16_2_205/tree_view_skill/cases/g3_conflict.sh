# Group 3: conflicts (same name / different type, case-only difference, explicit FIELD type)
case_TV020() {
  local o
  T "DROP DATABASE root.tv020" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv020" >/dev/null 2>&1
  T "CREATE DATABASE root.tv020" >/dev/null; Q "CREATE DATABASE tv020" >/dev/null
  T "CREATE TIMESERIES root.tv020.d1.s1 DOUBLE" >/dev/null
  o=$(Q "CREATE VIEW tv020.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv020.**")
  assert_ok "$o" "建视图"; assert_col tv020 v s1 DOUBLE "初始列"
  T "CREATE TIMESERIES root.tv020.d2.s1 INT32" >/dev/null
  T "CREATE TIMESERIES root.tv020.d2.s2 INT32" >/dev/null
  sleep 8
  assert_col tv020 v s1 DOUBLE "同名不同类型不应改列类型"
  assert_col tv020 v s2 INT32 "同批的非冲突测点仍应补列"
}

case_TV021() {
  local o
  T "DROP DATABASE root.tv021" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv021" >/dev/null 2>&1
  T "CREATE DATABASE root.tv021" >/dev/null; Q "CREATE DATABASE tv021" >/dev/null
  T "CREATE TIMESERIES root.tv021.d1.s1 DOUBLE" >/dev/null
  o=$(Q "CREATE VIEW tv021.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv021.**")
  assert_ok "$o" "建视图"
  T "CREATE TIMESERIES root.tv021.d2.S1 DOUBLE" >/dev/null
  sleep 8
  assert_col tv021 v s1 DOUBLE "原列保持"
  assert_no_col tv021 v s1_dup "无重复列"
  # 列数应保持 time/dev/s1 = 3
  o=$(Q "DESC tv021.v")
  assert_rows "$o" 3 "仅大小写不同属冲突，不应新增列"
}

case_TV022() {
  local o
  T "DROP DATABASE root.tv022" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv022" >/dev/null 2>&1
  T "CREATE DATABASE root.tv022" >/dev/null; Q "CREATE DATABASE tv022" >/dev/null
  o=$(Q "CREATE VIEW tv022.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv022.**")
  assert_ok "$o" "建视图"
  T "CREATE TIMESERIES root.tv022.d1.S5 INT32" >/dev/null
  sleep 8
  assert_col tv022 v s5 INT32 "大写原序列名应补成小写列 s5"
  o=$(Q "SHOW CREATE VIEW tv022.v")
  assert_contains "$o" "S5" "show create view 应保留 original name S5"
}

case_TV023() {
  local o
  T "DROP DATABASE root.tv023" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv023" >/dev/null 2>&1
  T "CREATE DATABASE root.tv023" >/dev/null; Q "CREATE DATABASE tv023" >/dev/null
  T "CREATE TIMESERIES root.tv023.d1.s1 INT32" >/dev/null
  T "CREATE TIMESERIES root.tv023.d2.s1 DOUBLE" >/dev/null
  o=$(Q "CREATE VIEW tv023.v(dev STRING TAG, s1 INT32 FIELD) WITH (auto_sync_schema=true) AS root.tv023.**")
  assert_ok "$o" "建视图并指定 FIELD 类型"
  assert_col tv023 v s1 INT32 "应选中 INT32 的那条序列"
}

case_TV024() {
  local o
  T "DROP DATABASE root.tv024" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv024" >/dev/null 2>&1
  T "CREATE DATABASE root.tv024" >/dev/null; Q "CREATE DATABASE tv024" >/dev/null
  T "CREATE TIMESERIES root.tv024.d1.s1 DOUBLE" >/dev/null
  T "INSERT INTO root.tv024.d1(time,s1) VALUES(1,1.0)" >/dev/null
  o=$(Q "CREATE VIEW tv024.v(dev STRING TAG, s1 INT32 FIELD) AS root.tv024.**")
  assert_ok "$o" "指定与两条序列都不匹配的类型"
  assert_col tv024 v s1 INT32 "类型不匹配时视为新列"
  o=$(Q "SELECT s1 FROM tv024.v")
  assert_not_contains "$o" "1.0" "同名序列查询应为空（类型不匹配）"
}

case_TV025() {
  local o
  T "DROP DATABASE root.tv025" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv025" >/dev/null 2>&1
  T "CREATE DATABASE root.tv025" >/dev/null; Q "CREATE DATABASE tv025" >/dev/null
  o=$(Q "CREATE VIEW tv025.v(dev STRING TAG, s1 FIELD) AS root.tv025.**")
  assert_error "$o" "Msg:" "只指定列名不指定类型应报错"
}

case_TV026() {
  local o
  T "DROP DATABASE root.tv026" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv026" >/dev/null 2>&1
  T "CREATE DATABASE root.tv026" >/dev/null; Q "CREATE DATABASE tv026" >/dev/null
  T "CREATE TIMESERIES root.tv026.d1.s1 DOUBLE" >/dev/null
  o=$(Q "CREATE VIEW tv026.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv026.**")
  assert_ok "$o" "建视图"
  # 已作为列存在的 original name 不应再被引用
  T "CREATE TIMESERIES root.tv026.d2.S1 DOUBLE" >/dev/null
  sleep 8
  o=$(Q "DESC tv026.v")
  assert_rows "$o" 3 "S1 与 s1 仅大小写不同，不应补列"
  # 同一设备其它大写测点可补列
  T "CREATE TIMESERIES root.tv026.d3.S7 INT64" >/dev/null
  sleep 8
  assert_col tv026 v s7 INT64 "独立的新测点应补列"
}

CASES+=(
"TV-020|冲突与类型|边界|同名不同类型跳过，同批其它列照补|case_TV020|SELECT dev,s1,s2 FROM tv020.v ORDER BY time,dev|0"
"TV-021|冲突与类型|边界|仅大小写不同的测点视为冲突不补列|case_TV021|SELECT dev,s1 FROM tv021.v ORDER BY time,dev|0"
"TV-022|冲突与类型|正向|大写原序列名补为小写列并保留 original name|case_TV022|SELECT dev,s5 FROM tv022.v ORDER BY time,dev|0"
"TV-023|冲突与类型|正向|指定 FIELD 类型可从同名不同型序列中择优|case_TV023|SELECT dev,s1 FROM tv023.v ORDER BY time,dev|0"
"TV-024|冲突与类型|边界|指定类型都不匹配时视为新列且查询为空|case_TV024||0"
"TV-025|冲突与类型|反向|FIELD 只写列名不写类型报错|case_TV025||0"
"TV-026|冲突与类型|边界|original name 已引用过的测点不再补列|case_TV026|SELECT dev,s1,s7 FROM tv026.v ORDER BY time,dev|0"
)
