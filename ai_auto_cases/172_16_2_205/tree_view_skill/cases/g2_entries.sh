# Group 2: every interface that creates measurements triggers the column add
prep2() {  # $1 treeDb $2 viewDb [$3 extra] -> creates db + view with auto_sync=true
  T "DROP DATABASE $1" >/dev/null 2>&1
  Q "DROP DATABASE IF EXISTS $2" >/dev/null 2>&1
  T "CREATE DATABASE $1" >/dev/null
  Q "CREATE DATABASE $2" >/dev/null
  Q "CREATE VIEW $2.v(dev STRING TAG) WITH (auto_sync_schema=true) AS $1.**"
}

case_TV010() {
  local o; o=$(prep2 root.tv010 tv010); assert_ok "$o" "建视图"
  T "CREATE TIMESERIES root.tv010.d1.s1 INT32" >/dev/null
  sleep 8
  assert_col tv010 v s1 INT32 "CREATE TIMESERIES 应补列"
}

case_TV011() {
  local o; o=$(prep2 root.tv011 tv011); assert_ok "$o" "建视图"
  T "CREATE ALIGNED TIMESERIES root.tv011.d1(s1 INT32, s2 DOUBLE)" >/dev/null
  sleep 8
  assert_col tv011 v s1 INT32 "aligned 第一条应补列"
  assert_col tv011 v s2 DOUBLE "aligned 第二条应补列"
}

case_TV012() {
  local o; o=$(prep2 root.tv012 tv012); assert_ok "$o" "建视图"
  T "INSERT INTO root.tv012.d1(time, s1) VALUES (1, 1.0)" >/dev/null
  sleep 8
  assert_col tv012 v s1 DOUBLE "INSERT 自动建序列应补列"
}

case_TV013() {
  local o; o=$(prep2 root.tv013 tv013); assert_ok "$o" "建视图"
  T "INSERT INTO root.tv013.d1(time, s1) VALUES (1, 1)" >/dev/null
  T "INSERT INTO root.tv013.d2(time, s2) VALUES (1, 2.0)" >/dev/null
  sleep 8
  view_cols tv013 v | grep -q "^s1:" || fail "设备1的测点应补列（列缺失）"
  view_cols tv013 v | grep -q "^s2:" || fail "设备2的测点应补列（列缺失）"
}

case_TV014() {
  local o
  T "DROP DATABASE root.tv014" >/dev/null 2>&1
  Q "DROP DATABASE IF EXISTS tv014" >/dev/null 2>&1
  T "CREATE DATABASE root.tv014" >/dev/null
  Q "CREATE DATABASE tv014" >/dev/null
  T "CREATE DEVICE TEMPLATE t_tv014(s1 FLOAT, s2 DOUBLE)" >/dev/null
  T "SET DEVICE TEMPLATE t_tv014 TO root.tv014" >/dev/null
  o=$(Q "CREATE VIEW tv014.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv014.**")
  assert_ok "$o" "带模板前缀建视图"
  T "CREATE TIMESERIES USING DEVICE TEMPLATE ON root.tv014.d1" >/dev/null
  sleep 10
  assert_col tv014 v s1 FLOAT "模板激活后应补列 s1"
  assert_col tv014 v s2 DOUBLE "模板激活后应补列 s2"
}

case_TV015() {
  local o
  T "DROP DATABASE root.tv015" >/dev/null 2>&1
  Q "DROP DATABASE IF EXISTS tv015" >/dev/null 2>&1
  T "DROP DEVICE TEMPLATE t_tv015" >/dev/null 2>&1
  T "CREATE DATABASE root.tv015" >/dev/null
  Q "CREATE DATABASE tv015" >/dev/null
  T "CREATE DEVICE TEMPLATE t_tv015(s1 FLOAT)" >/dev/null
  T "SET DEVICE TEMPLATE t_tv015 TO root.tv015" >/dev/null
  T "CREATE TIMESERIES USING DEVICE TEMPLATE ON root.tv015.d1" >/dev/null
  o=$(Q "CREATE VIEW tv015.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv015.**")
  assert_ok "$o" "建视图"
  assert_col tv015 v s1 FLOAT "初始模板列"
  T "ALTER SCHEMA TEMPLATE t_tv015 ADD (s3 INT64)" >/dev/null
  sleep 10
  assert_col tv015 v s3 INT64 "模板扩展后应补列 s3"
}

case_TV016() {
  local o
  prep2 root.tv016 tv016 >/dev/null
  T "CREATE TIMESERIES root.tv016.old.a.s1 INT32" >/dev/null
  sleep 6
  o=$(Q "CREATE OR REPLACE VIEW tv016.v(dev STRING TAG, grp STRING TAG) WITH (auto_sync_schema=true) AS root.tv016.new.**")
  assert_ok "$o" "替换视图到新前缀"
  T "CREATE TIMESERIES root.tv016.new.b.s2 INT64" >/dev/null
  sleep 8
  assert_col tv016 v s2 INT64 "新前缀下新增测点应补列"
  T "CREATE TIMESERIES root.tv016.old.a.s9 INT32" >/dev/null
  sleep 6
  assert_no_col tv016 v s9 "旧前缀不应再被跟踪"
}

case_TV017() {
  local o
  T "DROP DATABASE root.tv017" >/dev/null 2>&1
  Q "DROP DATABASE IF EXISTS tv017" >/dev/null 2>&1
  T "CREATE DATABASE root.tv017" >/dev/null
  T "CREATE TIMESERIES root.tv017.d1.s1 INT32" >/dev/null
  T "CREATE TIMESERIES root.tv017.d1.s2 DOUBLE" >/dev/null
  Q "CREATE DATABASE tv017" >/dev/null
  o=$(Q "CREATE VIEW tv017.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv017.**")
  assert_ok "$o" "建视图（前缀下已有测点）"
  assert_col tv017 v s1 INT32 "建视图时应扫描已有测点 s1"
  assert_col tv017 v s2 DOUBLE "建视图时应扫描已有测点 s2"
}

case_TV018() {
  local o
  prep2 root.tv018 tv018 >/dev/null
  T "CREATE TIMESERIES root.tv018.d1.s1 INT32" >/dev/null
  sleep 6
  T "CREATE TIMESERIES root.tv018other.d1.s9 INT32" >/dev/null 2>&1
  sleep 6
  assert_no_col tv018 v s9 "前缀外的新增测点不应补列"
}

CASES+=(
"TV-010|补列入口|正向|CREATE TIMESERIES 触发补列|case_TV010|SELECT dev,s1 FROM tv010.v ORDER BY time,dev|0"
"TV-011|补列入口|正向|CREATE ALIGNED TIMESERIES 多列补列|case_TV011|SELECT dev,s1,s2 FROM tv011.v ORDER BY time,dev|0"
"TV-012|补列入口|正向|INSERT 自动建序列触发补列|case_TV012|SELECT dev,s1 FROM tv012.v ORDER BY time,dev|0"
"TV-013|补列入口|正向|多设备写入分别补列|case_TV013|SELECT dev,s1,s2 FROM tv013.v ORDER BY time,dev|0"
"TV-014|补列入口|正向|模板激活到新路径触发补列|case_TV014|SELECT dev,s1,s2 FROM tv014.v ORDER BY time,dev|0"
"TV-015|补列入口|正向|模板扩展触发补列|case_TV015|SELECT dev,s1,s3 FROM tv015.v ORDER BY time,dev|0"
"TV-016|补列入口|正向|CREATE OR REPLACE 后按新前缀补列，旧前缀不再跟踪|case_TV016|SELECT dev,s1,s2,s9 FROM tv016.v ORDER BY time,dev|0"
"TV-017|补列入口|正向|建视图时扫描前缀下已有测点|case_TV017|SELECT dev,s1,s2 FROM tv017.v ORDER BY time,dev|0"
"TV-018|补列入口|反向|前缀外新增测点不触发补列|case_TV018|SELECT dev,s1 FROM tv018.v ORDER BY time,dev|0"
)
