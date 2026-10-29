# Group 5: DDL combinations on a tree view with auto_sync_schema (add/drop/rename column, object type)
case_TV040() {
  local o
  T "DROP DATABASE root.tv040" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv040" >/dev/null 2>&1
  T "CREATE DATABASE root.tv040" >/dev/null; Q "CREATE DATABASE tv040" >/dev/null
  T "CREATE TIMESERIES root.tv040.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv040.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv040.**" >/dev/null
  o=$(Q "ALTER VIEW tv040.v ADD COLUMN s2 INT64 FIELD")
  assert_ok "$o" "ADD COLUMN 数值列"
  assert_col tv040 v s2 INT64 "新列应存在"
}

case_TV041() {
  local o
  T "DROP DATABASE root.tv041" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv041" >/dev/null 2>&1
  T "CREATE DATABASE root.tv041" >/dev/null; Q "CREATE DATABASE tv041" >/dev/null
  T "CREATE TIMESERIES root.tv041.p.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv041.v(a STRING TAG) WITH (auto_sync_schema=true) AS root.tv041.**" >/dev/null
  o=$(Q "ALTER VIEW tv041.v ADD COLUMN b STRING TAG")
  assert_ok "$o" "ADD COLUMN tag"
  assert_col tv041 v b STRING "新 tag 列应存在"
  o=$(Q "SELECT * FROM tv041.v")
  assert_ok "$o" "新增 tag 后查询"
  assert_contains "$o" "p" "第二级 tag 应能取到值"
}

case_TV042() {
  local o
  T "DROP DATABASE root.tv042" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv042" >/dev/null 2>&1
  T "CREATE DATABASE root.tv042" >/dev/null; Q "CREATE DATABASE tv042" >/dev/null
  T "CREATE TIMESERIES root.tv042.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv042.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv042.**" >/dev/null
  o=$(Q "ALTER VIEW tv042.v ADD COLUMN o1 OBJECT FIELD")
  if echo "$o" | grep -qE "Msg: org.apache.iotdb.jdbc|Exception"; then
    assert_error "$o" "Msg:" "树模型不支持 OBJECT：应被明确拒绝（记录错误信息）"
    echo "  OBJECT 列被拒绝：$(echo "$o" | head -1 | cut -c1-160)"
  else
    assert_col tv042 v o1 OBJECT "允许新增 OBJECT 列时该列应存在"
    local q
    q=$(Q "SELECT o1 FROM tv042.v")
    assert_ok "$q" "OBJECT 列查询不应报错"
    echo "  注意：OBJECT 列被接受但树模型无对象数据，查询为 null"
  fi
}

case_TV043() {
  local o
  T "DROP DATABASE root.tv043" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv043" >/dev/null 2>&1
  T "CREATE DATABASE root.tv043" >/dev/null; Q "CREATE DATABASE tv043" >/dev/null
  T "CREATE TIMESERIES root.tv043.d1.s1 INT32" >/dev/null
  T "CREATE TIMESERIES root.tv043.d1.s2 INT64" >/dev/null
  Q "CREATE VIEW tv043.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv043.**" >/dev/null
  assert_col tv043 v s2 INT64 "初始 s2 存在"
  o=$(Q "ALTER VIEW tv043.v DROP COLUMN s2")
  assert_ok "$o" "DROP COLUMN"
  assert_no_col tv043 v s2 "列应被删除"
  sleep 6
  o=$(Q "DESC tv043.v")
  assert_rows "$o" 3 "自动同步不应把删掉的列补回来"
}

case_TV044() {
  local o
  T "DROP DATABASE root.tv044" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv044" >/dev/null 2>&1
  T "CREATE DATABASE root.tv044" >/dev/null; Q "CREATE DATABASE tv044" >/dev/null
  T "CREATE TIMESERIES root.tv044.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv044.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv044.**" >/dev/null
  o=$(Q "ALTER VIEW tv044.v RENAME COLUMN s1 TO s1_new")
  assert_ok "$o" "RENAME COLUMN"
  assert_col tv044 v s1_new INT32 "新列名存在"
  assert_no_col tv044 v s1 "旧列名不存在"
}

case_TV045() {
  local o
  T "DROP DATABASE root.tv045" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv045" >/dev/null 2>&1
  T "CREATE DATABASE root.tv045" >/dev/null; Q "CREATE DATABASE tv045" >/dev/null
  T "CREATE TIMESERIES root.tv045.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv045.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv045.**" >/dev/null
  o=$(Q "ALTER VIEW tv045.v ADD COLUMN s1 INT32 FIELD")
  assert_error "$o" "Msg:" "重复添加同名列应报错"
}

case_TV046() {
  local o
  T "DROP DATABASE root.tv046" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv046" >/dev/null 2>&1
  T "CREATE DATABASE root.tv046" >/dev/null; Q "CREATE DATABASE tv046" >/dev/null
  T "CREATE TIMESERIES root.tv046.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv046.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv046.**" >/dev/null
  o=$(Q "ALTER VIEW tv046.v ADD COLUMN S1 INT32 FIELD")
  if echo "$o" | grep -qE "Msg: org.apache.iotdb.jdbc|Exception"; then
    echo "  大小写不同的同名列被拒绝"
  else
    local q
    q=$(Q "DESC tv046.v")
    assert_rows "$q" 3 "若允许添加则不应产生第二个 s1 列"
  fi
}

case_TV047() {
  local o
  T "DROP DATABASE root.tv047" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv047" >/dev/null 2>&1
  T "CREATE DATABASE root.tv047" >/dev/null; Q "CREATE DATABASE tv047" >/dev/null
  T "CREATE TIMESERIES root.tv047.d1.s1 INT32" >/dev/null
  T "CREATE TIMESERIES root.tv047.d1.s2 INT64" >/dev/null
  Q "CREATE VIEW tv047.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv047.**" >/dev/null
  o=$(Q "ALTER VIEW tv047.v DROP COLUMN s2")
  assert_ok "$o" "auto=true 时手动删列"
  sleep 8
  assert_no_col tv047 v s2 "自动同步不应把手动删掉的列补回"
  o=$(Q "ALTER VIEW tv047.v ADD COLUMN s2 INT64 FIELD")
  assert_ok "$o" "auto=true 时手动加列"
  assert_col tv047 v s2 INT64 "手动新增列应存在"
}

CASES+=(
"TV-040|DDL 组合|正向|auto=true 时 ADD COLUMN 数值列|case_TV040|SELECT dev,s1,s2 FROM tv040.v ORDER BY time,dev|0"
"TV-041|DDL 组合|正向|auto=true 时 ADD COLUMN tag 列|case_TV041|SELECT * FROM tv041.v ORDER BY time|0"
"TV-042|DDL 组合|边界|ADD COLUMN OBJECT（树模型不支持 object）|case_TV042||0"
"TV-043|DDL 组合|正向|DROP COLUMN 后不被自动补回|case_TV043|SELECT dev,s1 FROM tv043.v ORDER BY time,dev|0"
"TV-044|DDL 组合|正向|RENAME COLUMN|case_TV044|SELECT dev,s1_new FROM tv044.v ORDER BY time,dev|0"
"TV-045|DDL 组合|反向|重复 ADD COLUMN 报错|case_TV045||0"
"TV-046|DDL 组合|边界|ADD COLUMN 与已有列仅大小写不同|case_TV046||0"
"TV-047|DDL 组合|正向|auto=true 时手动增删列均生效且不被回补|case_TV047|SELECT dev,s1,s2 FROM tv047.v ORDER BY time,dev|0"
)
