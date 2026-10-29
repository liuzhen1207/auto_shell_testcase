# Group 4: query semantics, property toggle, lifecycle
case_TV030() {
  local o
  T "DROP DATABASE root.tv030" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv030" >/dev/null 2>&1
  T "CREATE DATABASE root.tv030" >/dev/null; Q "CREATE DATABASE tv030" >/dev/null
  T "CREATE TIMESERIES root.tv030.d1.s1 DOUBLE" >/dev/null
  T "INSERT INTO root.tv030.d1(time,s1) VALUES(1,1.0)" >/dev/null
  Q "CREATE VIEW tv030.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv030.**" >/dev/null
  T "CREATE TIMESERIES root.tv030.d1.s2 INT32" >/dev/null
  T "INSERT INTO root.tv030.d1(time,s2) VALUES(2,20)" >/dev/null
  sleep 8
  o=$(Q "SELECT dev,s1,s2 FROM tv030.v ORDER BY time")
  assert_ok "$o" "补列后查询"
  assert_contains "$o" "1.0" "旧行 s1 可见"
  assert_contains "$o" "20" "新列 s2 新写入可见"
  assert_rows "$o" 2 "应有两行"
}

case_TV031() {
  local o
  T "DROP DATABASE root.tv031" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv031" >/dev/null 2>&1
  T "CREATE DATABASE root.tv031" >/dev/null; Q "CREATE DATABASE tv031" >/dev/null
  T "CREATE TIMESERIES root.tv031.d1.s1 DOUBLE" >/dev/null
  T "INSERT INTO root.tv031.d1(time,s1) VALUES(1,1.0)" >/dev/null
  Q "CREATE VIEW tv031.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv031.**" >/dev/null
  sleep 5
  T "DELETE TIMESERIES root.tv031.d1.s1" >/dev/null
  sleep 8
  assert_col tv031 v s1 DOUBLE "删除序列后列应保留"
  o=$(Q "SELECT dev,s1 FROM tv031.v")
  assert_ok "$o" "删除序列后查询不报错"
  assert_not_contains "$o" "1.0" "删除后查询该列为空"
}

case_TV032() {
  local o
  T "DROP DATABASE root.tv032" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv032" >/dev/null 2>&1
  T "CREATE DATABASE root.tv032" >/dev/null; Q "CREATE DATABASE tv032" >/dev/null
  T "CREATE TIMESERIES root.tv032.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv032.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv032.**" >/dev/null
  sleep 5
  o=$(Q "ALTER VIEW tv032.v SET PROPERTIES auto_sync_schema=false")
  assert_ok "$o" "关闭属性"
  o=$(Q "SHOW CREATE VIEW tv032.v")
  assert_contains "$o" "auto_sync_schema=false" "属性应显示 false"
  T "CREATE TIMESERIES root.tv032.d2.s9 INT64" >/dev/null
  sleep 8
  assert_no_col tv032 v s9 "关闭后不应补列"
}

case_TV033() {
  local o
  T "DROP DATABASE root.tv033" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv033" >/dev/null 2>&1
  T "CREATE DATABASE root.tv033" >/dev/null; Q "CREATE DATABASE tv033" >/dev/null
  T "CREATE TIMESERIES root.tv033.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv033.v(dev STRING TAG) WITH (auto_sync_schema=false) AS root.tv033.**" >/dev/null
  T "CREATE TIMESERIES root.tv033.d2.s2 INT64" >/dev/null
  sleep 6
  assert_no_col tv033 v s2 "关闭期间不补列"
  o=$(Q "ALTER VIEW tv033.v SET PROPERTIES auto_sync_schema=true")
  assert_ok "$o" "打开属性"
  sleep 8
  assert_col tv033 v s2 INT64 "打开后应回填已存在测点"
  T "CREATE TIMESERIES root.tv033.d3.s3 DOUBLE" >/dev/null
  sleep 8
  assert_col tv033 v s3 DOUBLE "打开后新增测点继续补列"
}

case_TV034() {
  local o
  T "DROP DATABASE root.tv034" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv034" >/dev/null 2>&1
  T "CREATE DATABASE root.tv034" >/dev/null; Q "CREATE DATABASE tv034" >/dev/null
  T "CREATE TIMESERIES root.tv034.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv034.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv034.**" >/dev/null
  sleep 5
  o=$(Q "ALTER VIEW tv034.v RENAME TO v2")
  assert_ok "$o" "视图改名"
  T "CREATE TIMESERIES root.tv034.d2.s2 INT32" >/dev/null
  sleep 8
  assert_col tv034 v2 s2 INT32 "改名后仍应补列"
  o=$(Q "DESC tv034.v")
  assert_error "$o" "does not exist" "旧名应不存在"
}

case_TV035() {
  local o
  T "DROP DATABASE root.tv035" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv035" >/dev/null 2>&1
  T "CREATE DATABASE root.tv035" >/dev/null; Q "CREATE DATABASE tv035" >/dev/null
  Q "CREATE VIEW tv035.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv035.**" >/dev/null
  o=$(Q "DROP VIEW tv035.v")
  assert_ok "$o" "删除视图"
  o=$(T "CREATE TIMESERIES root.tv035.d1.s1 INT32")
  assert_ok "$o" "视图删除后建序列不应报错"
}

case_TV036() {
  local o
  T "DROP DATABASE root.tv036" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv036" >/dev/null 2>&1
  T "CREATE DATABASE root.tv036" >/dev/null; Q "CREATE DATABASE tv036" >/dev/null
  Q "CREATE VIEW tv036.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv036.**" >/dev/null
  o=$(Q "DROP DATABASE TV036" 2>/dev/null || Q "DROP DATABASE tv036")
  assert_ok "$o" "删除视图所在库"
  o=$(T "CREATE TIMESERIES root.tv036.d2.s2 INT32")
  assert_ok "$o" "库删除后建序列不应报错"
}

case_TV037() {
  local o
  T "DROP DATABASE root.tv037" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv037" >/dev/null 2>&1
  T "CREATE DATABASE root.tv037" >/dev/null; Q "CREATE DATABASE tv037" >/dev/null
  T "CREATE TIMESERIES root.tv037.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv037.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv037.**" >/dev/null
  sleep 5
  # restart the whole cluster (no data wipe)
  for ip in 172.16.2.26 172.16.2.27 172.16.2.28; do stop_cn $ip; done
  for ip in 172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6; do stop_dn $ip; done
  sleep 5
  for ip in 172.16.2.26 172.16.2.27 172.16.2.28; do start_cn $ip; sleep 3; done
  sleep 20
  for ip in 172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6; do start_dn $ip; sleep 2; done
  if wait_running 300; then
    o=$(Q "SHOW CREATE VIEW tv037.v")
    assert_contains "$o" "auto_sync_schema=true" "重启后属性应持久化"
    T "CREATE TIMESERIES root.tv037.d2.s2 INT64" >/dev/null
    sleep 10
    assert_col tv037 v s2 INT64 "重启后新增测点仍应补列"
  else
    fail "重启后集群未恢复到 8 节点"
  fi
}

case_TV038() {
  local o
  T "DROP DATABASE root.tv038" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv038" >/dev/null 2>&1
  T "CREATE DATABASE root.tv038" >/dev/null; Q "CREATE DATABASE tv038" >/dev/null
  # restrict 视图: 2 个 tag => 精确匹配 2 层设备
  Q "CREATE VIEW tv038.vr(a STRING TAG, b STRING TAG) RESTRICT WITH (auto_sync_schema=true) AS root.tv038.**" >/dev/null
  # 非 restrict 视图: 1 个 tag => 匹配 1 层设备
  Q "CREATE VIEW tv038.vn(a STRING TAG) WITH (auto_sync_schema=true) AS root.tv038.**" >/dev/null
  T "CREATE TIMESERIES root.tv038.p.s1 INT32" >/dev/null
  sleep 8
  assert_col tv038 vn s1 INT32 "1 层设备应命中非 restrict 视图"
  assert_no_col tv038 vr s1 "1 层设备不应命中 restrict 视图"
  T "CREATE TIMESERIES root.tv038.p.q.s2 INT64" >/dev/null
  sleep 8
  assert_col tv038 vr s2 INT64 "2 层设备应命中 restrict 视图"
  assert_no_col tv038 vn s2 "2 层设备不应命中非 restrict 视图"
  T "CREATE TIMESERIES root.tv038.p.q.r.s3 DOUBLE" >/dev/null
  sleep 8
  assert_no_col tv038 vr s3 "3 层设备两个视图都不命中"
  assert_no_col tv038 vn s3 "3 层设备两个视图都不命中"
}

CASES+=(
"TV-030|查询与生命周期|正向|补列后旧行为 null、新写入可见|case_TV030|SELECT dev,s1,s2 FROM tv030.v ORDER BY time|0"
"TV-031|查询与生命周期|边界|删除序列后列保留且查询为 null|case_TV031|SELECT dev,s1 FROM tv031.v ORDER BY time|0"
"TV-032|查询与生命周期|正向|关闭属性后不再补列|case_TV032|SELECT dev,s1 FROM tv032.v ORDER BY time|0"
"TV-033|查询与生命周期|正向|打开属性回填已有测点并继续补列|case_TV033|SELECT dev,s1,s2,s3 FROM tv033.v ORDER BY time|0"
"TV-034|查询与生命周期|正向|视图改名后仍自动补列|case_TV034|SELECT dev,s1,s2 FROM tv034.v2 ORDER BY time|0"
"TV-035|查询与生命周期|边界|删除视图后建序列不报错|case_TV035||0"
"TV-036|查询与生命周期|边界|删除视图所在库后建序列不报错|case_TV036||0"
"TV-037|查询与生命周期|可靠性|集群重启后属性持久化并继续补列|case_TV037|SELECT dev,s1,s2 FROM tv037.v ORDER BY time|0"
"TV-038|查询与生命周期|边界|RESTRICT 与 auto_sync_schema 正交|case_TV038|SELECT * FROM tv038.vr ORDER BY time|0"
)
