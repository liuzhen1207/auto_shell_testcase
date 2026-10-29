# Group 1: property & syntax of auto_sync_schema
prep_tree_view() {  # $1=treeDb $2=viewDb $3=extra-with-clause $4=view name
  T "DROP DATABASE $1" >/dev/null 2>&1
  Q "DROP DATABASE IF EXISTS $2" >/dev/null 2>&1
  T "CREATE DATABASE $1" >/dev/null
  Q "CREATE DATABASE $2" >/dev/null
  T "CREATE TIMESERIES $1.d1.s1 DOUBLE" >/dev/null
  T "INSERT INTO $1.d1(time,s1) VALUES(1,1.0)" >/dev/null
  Q "CREATE VIEW $2.$4(dev STRING TAG) $3 AS $1.**" 
}

case_TV001() {
  local o
  o=$(prep_tree_view root.tv001 tv001 "" v)
  assert_ok "$o" "建视图（默认属性）"
  o=$(Q "SHOW CREATE VIEW tv001.v")
  assert_not_contains "$o" "auto_sync_schema" "默认不应输出 auto_sync_schema"
  T "CREATE TIMESERIES root.tv001.d2.s9 INT32" >/dev/null
  sleep 6
  assert_no_col tv001 v s9 "默认关闭时不应自动补列"
}

case_TV002() {
  local o
  o=$(prep_tree_view root.tv002 tv002 "WITH (auto_sync_schema=false)" v)
  assert_ok "$o" "建视图 auto_sync_schema=false"
  o=$(Q "SHOW CREATE VIEW tv002.v")
  assert_contains "$o" "auto_sync_schema=false" "show create view 应显示 false"
  T "CREATE TIMESERIES root.tv002.d2.s9 INT32" >/dev/null
  sleep 6
  assert_no_col tv002 v s9 "false 时不应补列"
}

case_TV003() {
  local o
  o=$(prep_tree_view root.tv003 tv003 "WITH (auto_sync_schema=true)" v)
  assert_ok "$o" "建视图 auto_sync_schema=true"
  o=$(Q "SHOW CREATE VIEW tv003.v")
  assert_contains "$o" "auto_sync_schema=true" "show create view 应显示 true"
  T "CREATE TIMESERIES root.tv003.d2.s9 INT32" >/dev/null
  sleep 8
  assert_col tv003 v s9 INT32 "true 时应自动补列"
}

case_TV004() {
  local o
  Q "CREATE DATABASE IF NOT EXISTS tv004" >/dev/null
  o=$(Q "CREATE TABLE tv004.t1(tag1 STRING TAG, s1 INT32 FIELD) WITH (auto_sync_schema=true)")
  assert_error "$o" "auto_sync_schema" "普通表带该属性应报错"
  assert_error "$o" "only supported by tree to table views" "错误语义应为仅树转表视图支持"
}

case_TV005() {
  local o
  Q "CREATE DATABASE IF NOT EXISTS tv005" >/dev/null
  Q "CREATE TABLE IF NOT EXISTS tv005.t1(tag1 STRING TAG, s1 INT32 FIELD)" >/dev/null
  o=$(Q "ALTER TABLE tv005.t1 SET PROPERTIES auto_sync_schema=true")
  assert_error "$o" "auto_sync_schema" "ALTER TABLE 设置该属性应报错"
}

case_TV006() {
  local o
  prep_tree_view root.tv006 tv006 "" v >/dev/null
  T "CREATE TIMESERIES root.tv006.d2.s2 INT32" >/dev/null
  sleep 5
  assert_no_col tv006 v s2 "初始关闭不应补列"
  o=$(Q "CREATE OR REPLACE VIEW tv006.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv006.**")
  assert_ok "$o" "CREATE OR REPLACE 打开属性"
  sleep 8
  assert_col tv006 v s2 INT32 "打开后应回填已存在的 s2"
  T "CREATE TIMESERIES root.tv006.d3.s3 INT64" >/dev/null
  sleep 8
  assert_col tv006 v s3 INT64 "打开后新增测点应补列"
}

case_TV007() {
  local o
  Q "CREATE DATABASE IF NOT EXISTS tv007" >/dev/null
  T "CREATE DATABASE root.tv007" >/dev/null 2>&1
  o=$(Q "CREATE VIEW tv007.v(dev STRING TAG) WITH (auto_sync_schema=abc) AS root.tv007.**")
  assert_error "$o" "auto_sync_schema" "非法属性值应报错"
}

case_TV008() {
  local o
  o=$(prep_tree_view root.tv008 tv008 "WITH (ttl=3600000, auto_sync_schema=true)" v)
  assert_ok "$o" "ttl 与 auto_sync_schema 同时指定"
  o=$(Q "SHOW CREATE VIEW tv008.v")
  assert_contains "$o" "auto_sync_schema=true" "应保留 auto_sync_schema"
  assert_contains "$o" "ttl" "应保留 ttl"
}

CASES+=(
"TV-001|属性与语法|正向|默认不开启自动补列，show create view 不输出该属性|case_TV001|SELECT dev,s1,s9 FROM tv001.v ORDER BY time,dev|1"
"TV-002|属性与语法|正向|显式 false：属性可见且不补列|case_TV002|SELECT dev,s1 FROM tv002.v ORDER BY time,dev|0"
"TV-003|属性与语法|正向|显式 true：属性可见且新增测点自动补列|case_TV003|SELECT dev,s1,s9 FROM tv003.v ORDER BY time,dev|0"
"TV-004|属性与语法|反向|普通表带 auto_sync_schema 报 701|case_TV004||0"
"TV-005|属性与语法|反向|ALTER TABLE 设置该属性报错|case_TV005||0"
"TV-006|属性与语法|正向|CREATE OR REPLACE 打开属性后回填并继续补列|case_TV006|SELECT dev,s1,s2,s3 FROM tv006.v ORDER BY time,dev|0"
"TV-007|属性与语法|反向|非法属性值报错|case_TV007||0"
"TV-008|属性与语法|正向|ttl 与 auto_sync_schema 同时生效|case_TV008|SELECT dev,s1 FROM tv008.v ORDER BY time,dev|0"
)
