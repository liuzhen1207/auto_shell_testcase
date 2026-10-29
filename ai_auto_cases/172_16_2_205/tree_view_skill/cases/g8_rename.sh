# Group 8: ALTER TIMESERIES ... RENAME TO × tree-to-table view.
# Requirement points (PLM doc 211 树转表——需求分析 V2.0.5.1):
#   §2.1.1.1 TAG 列按顺序对应 prefixPath 后面层级的路径节点
#   §2.1.1.3 视图包含 prefixPath 下一层起的设备（RESTRICT 时层级 == tag 数，否则 <= tag 数）
#   §2.1.1.4 只包含声明的 FIELD 列对应测点，缺失/类型不符时该列恒为 NULL
# Rename semantics (dc11a35): ALTER TIMESERIES old RENAME TO new => 新路径 CREATE_ALIAS_SERIES，
#   旧路径 MARK_SERIES_INVALID（RenameTimeSeriesProcedure#processPhysicalToAlias）。
# Known defects on this path: TDB-888 (D1 TAG 返回旧设备名 / D2 跨库改名后目标库视图 0 行)。

cnt_rows() {  # echo the single integer returned by "select count(*)"
  echo "$1" | grep -E '^\|[[:space:]]*[0-9]+' | head -1 | tr -dc '0-9'
}

case_TV080() {
  T "DROP DATABASE root.tv080" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv080" >/dev/null 2>&1
  T "CREATE DATABASE root.tv080" >/dev/null; Q "CREATE DATABASE tv080" >/dev/null
  T "CREATE TIMESERIES root.tv080.d1.n1 FLOAT" >/dev/null
  T "CREATE TIMESERIES root.tv080.d1.n2 DOUBLE" >/dev/null
  T "INSERT INTO root.tv080.d1(time,n1,n2) VALUES(1,1.0,11.0)" >/dev/null
  Q "CREATE VIEW tv080.v1(dev STRING TAG) AS root.tv080.**" >/dev/null
  T "ALTER TIMESERIES root.tv080.d1.n1 RENAME TO root.tv080.d9.n1" >/dev/null
  T "ALTER TIMESERIES root.tv080.d1.n2 RENAME TO root.tv080.d9.n2" >/dev/null
  T "INSERT INTO root.tv080.d9(time,n1) VALUES(2,2.0)" >/dev/null
  sleep 8
  local o
  o=$(Q "SELECT dev FROM tv080.v1")
  echo "  view TAG values: $(echo "$o" | grep -oE '\| *d[0-9]+ *\|' | tr -d '| ' | sort -u | tr '\n' ' ')"
  echo "$o" | grep -qE '\|[[:space:]]*d9[[:space:]]*\|' || fail "改名后视图 TAG 应返回新设备名 d9（需求 §2.1.1.1），实测 $(echo "$o" | grep -oE '\| *d[0-9]+ *\|' | tr -d '| ' | sort -u | tr '\n' ' ')"
  echo "$o" | grep -qE '\|[[:space:]]*d1[[:space:]]*\|' && fail "改名后视图 TAG 仍返回旧设备名 d1（需求 §2.1.1.1）"
}

case_TV081() {
  T "DROP DATABASE root.tv081" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv081" >/dev/null 2>&1
  T "CREATE DATABASE root.tv081" >/dev/null; Q "CREATE DATABASE tv081" >/dev/null
  T "CREATE TIMESERIES root.tv081.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv081.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv081.**" >/dev/null
  T "INSERT INTO root.tv081.d1(time,s1) VALUES(1,1)" >/dev/null
  sleep 5
  T "ALTER TIMESERIES root.tv081.d1.s1 RENAME TO root.tv081.d9.s1" >/dev/null
  T "INSERT INTO root.tv081.d9(time,s1) VALUES(2,2)" >/dev/null
  sleep 8
  local o n
  o=$(Q "SELECT count(*) FROM tv081.v"); n=$(cnt_rows "$o")
  echo "  rows after rename: $n"
  [ "${n:-0}" -ge 2 ] || fail "改名后 d9 的数据应可见（期望 2 行，实测 ${n:-0}）"
  o=$(Q "SELECT dev FROM tv081.v")
  echo "$o" | grep -qE '\|[[:space:]]*d9[[:space:]]*\|' || fail "auto_sync 视图改名后 TAG 应为 d9（需求 §2.1.1.1）"
}

case_TV082() {
  T "DROP DATABASE root.tv082a" >/dev/null 2>&1; T "DROP DATABASE root.tv082b" >/dev/null 2>&1
  Q "DROP DATABASE IF EXISTS tb082" >/dev/null 2>&1
  T "CREATE DATABASE root.tv082a" >/dev/null; T "CREATE DATABASE root.tv082b" >/dev/null
  Q "CREATE DATABASE tb082" >/dev/null
  Q "CREATE VIEW tb082.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv082b.**" >/dev/null
  T "CREATE TIMESERIES root.tv082a.d1.s1 FLOAT" >/dev/null
  T "INSERT INTO root.tv082a.d1(time,s1) VALUES(1,1.0)" >/dev/null
  sleep 5
  T "ALTER TIMESERIES root.tv082a.d1.s1 RENAME TO root.tv082b.d1.s1" >/dev/null
  sleep 8
  local treerows viewrows
  treerows=$(cnt_rows "$(T "SELECT count(*) FROM root.tv082b.d1")")
  viewrows=$(cnt_rows "$(Q "SELECT count(*) FROM tb082.v")")
  echo "  tree rows=$treerows  view rows=$viewrows"
  [ "${treerows:-0}" -ge 1 ] || fail "树侧 target 库应有数据（前置失败）"
  [ "${viewrows:-0}" -ge 1 ] || fail "跨库改名后目标库视图应包含该设备（需求 §2.1.1.3），实测 ${viewrows:-0} 行"
}

case_TV083() {
  T "DROP DATABASE root.tv083a" >/dev/null 2>&1; T "DROP DATABASE root.tv083b" >/dev/null 2>&1
  T "CREATE DATABASE root.tv083a" >/dev/null; T "CREATE DATABASE root.tv083b" >/dev/null
  T "CREATE TIMESERIES root.tv083a.d1.s1 FLOAT" >/dev/null
  T "INSERT INTO root.tv083a.d1(time,s1) VALUES(1,1.0)" >/dev/null
  T "ALTER TIMESERIES root.tv083a.d1.s1 RENAME TO root.tv083b.d1.s1" >/dev/null
  sleep 3
  local o
  o=$(T "DROP DATABASE root.tv083a" 2>&1)
  echo "  drop source -> $(echo "$o" | head -2 | tr '\n' ' ' | cut -c1-160)"
  echo "$o" | grep -qE '708|507' || fail "跨库改名后源库应被拦截（708/507），实测未拦截"
  o=$(T "SHOW INVALID TIMESERIES")
  echo "$o" | grep -q "root.tv083b.d1.s1" || fail "SHOW INVALID TIMESERIES 应给出 NewPath=root.tv083b.d1.s1"
}

case_TV084() {
  T "DROP DATABASE root.tv084a" >/dev/null 2>&1; T "DROP DATABASE root.tv084b" >/dev/null 2>&1
  T "CREATE DATABASE root.tv084a" >/dev/null; T "CREATE DATABASE root.tv084b" >/dev/null
  T "CREATE TIMESERIES root.tv084a.d1.s1 FLOAT" >/dev/null
  T "INSERT INTO root.tv084a.d1(time,s1) VALUES(1,1.0)" >/dev/null
  T "ALTER TIMESERIES root.tv084a.d1.s1 RENAME TO root.tv084b.d1.s1" >/dev/null
  T "DELETE TIMESERIES root.tv084b.d1.s1" >/dev/null
  sleep 3
  local o
  o=$(T "SHOW INVALID TIMESERIES")
  echo "$o" | grep -q "root.tv084a.d1.s1" && fail "删别名后 SHOW INVALID TIMESERIES 应为空"
  o=$(T "DROP DATABASE root.tv084a" 2>&1)
  assert_ok "$o" "清理别名后源库应可删除"
  T "DROP DATABASE root.tv084b" >/dev/null 2>&1
}

case_TV085() {
  T "DROP DATABASE root.tv085" >/dev/null 2>&1; T "DROP DATABASE root.tv085new" >/dev/null 2>&1
  T "CREATE DATABASE root.tv085" >/dev/null
  T "CREATE TIMESERIES root.tv085.d1.s1 FLOAT" >/dev/null
  T "INSERT INTO root.tv085.d1(time,s1) VALUES(1,1.0)" >/dev/null
  local o
  o=$(T "ALTER TIMESERIES root.tv085.d1.s1 RENAME TO root.tv085new.d1.s1" 2>&1)
  assert_ok "$o" "改名到不存在的库：语句是否成功"
  o=$(T "SHOW DATABASES")
  echo "$o" | grep -q "root.tv085new" || fail "改名到不存在的库应自动建库（当前行为，待研发确认）"
  T "DROP DATABASE root.tv085" >/dev/null 2>&1; T "DROP DATABASE root.tv085new" >/dev/null 2>&1
}

case_TV086() {
  T "DROP DATABASE root.tv086" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv086" >/dev/null 2>&1
  T "CREATE DATABASE root.tv086" >/dev/null; Q "CREATE DATABASE tv086" >/dev/null
  T "CREATE TIMESERIES root.tv086.d1.s1 INT32" >/dev/null
  T "INSERT INTO root.tv086.d1(time,s1) VALUES(1,1)" >/dev/null
  Q "CREATE VIEW tv086.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv086.**" >/dev/null
  sleep 5
  T "ALTER TIMESERIES root.tv086.d1.s1 RENAME TO root.tv086.d1.s9" >/dev/null
  T "INSERT INTO root.tv086.d1(time,s9) VALUES(2,2)" >/dev/null
  sleep 8
  view_cols tv086 v | grep -q "^s1:" || fail "改名后原列 s1 应保留（改名不删除已有列）"
  # 改名不是 schema 创建事件，auto_sync 不应新增 s9 列；这里记录实际行为
  if view_cols tv086 v | grep -q "^s9:"; then echo "  NOTE: 改名触发了补列 s9"; else echo "  NOTE: 改名未触发补列（符合当前实现：仅 create 事件触发）"; fi
  local o
  o=$(Q "SELECT count(*) FROM tv086.v")
  [ "$(cnt_rows "$o")" -ge 2 ] || echo "  NOTE: 改名后写入的数据在视图中为 $(cnt_rows "$o") 行"
}

case_TV087() {
  T "DROP DATABASE root.tv087" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv087" >/dev/null 2>&1
  T "CREATE DATABASE root.tv087" >/dev/null; Q "CREATE DATABASE tv087" >/dev/null
  Q "CREATE VIEW tv087.vr(a STRING TAG, b STRING TAG) RESTRICT WITH (auto_sync_schema=true) AS root.tv087.**" >/dev/null
  T "CREATE TIMESERIES root.tv087.p.q.s1 INT32" >/dev/null
  T "INSERT INTO root.tv087.p.q(time,s1) VALUES(1,1)" >/dev/null
  sleep 6
  T "ALTER TIMESERIES root.tv087.p.q.s1 RENAME TO root.tv087.p.r.s1" >/dev/null
  T "INSERT INTO root.tv087.p.r(time,s1) VALUES(2,2)" >/dev/null
  sleep 8
  local o
  o=$(Q "SELECT count(*) FROM tv087.vr")
  echo "  restrict view rows after rename: $(cnt_rows "$o")"
  [ "$(cnt_rows "$o")" -ge 2 ] || fail "改名后 restrict 视图应仍包含同层级设备（需求 §2.1.1.3）"
}

case_TV088() {
  T "DROP DATABASE root.tv088" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv088" >/dev/null 2>&1
  T "CREATE DATABASE root.tv088" >/dev/null; Q "CREATE DATABASE tv088" >/dev/null
  T "CREATE TIMESERIES root.tv088.d1.n1 FLOAT" >/dev/null
  T "INSERT INTO root.tv088.d1(time,n1) VALUES(1,1.0)" >/dev/null
  Q "CREATE VIEW tv088.v1(dev STRING TAG) AS root.tv088.**" >/dev/null
  T "ALTER TIMESERIES root.tv088.d1.n1 RENAME TO root.tv088.d9.n1" >/dev/null
  T "INSERT INTO root.tv088.d9(time,n1) VALUES(2,2.0)" >/dev/null
  sleep 5
  echo "  restart one DN to verify persistence"
  stop_dn 172.16.2.4 >/dev/null 2>&1
  start_dn 172.16.2.4 >/dev/null 2>&1
  wait_running 240 >/dev/null 2>&1
  sleep 10
  local o
  o=$(Q "SELECT dev FROM tv088.v1")
  echo "  TAG after DN restart: $(echo "$o" | grep -oE '\| *d[0-9]+ *\|' | tr -d '| ' | sort -u | tr '\n' ' ')"
  echo "$o" | grep -qE '\|[[:space:]]*d9[[:space:]]*\|' || fail "重启 DN 后视图 TAG 仍应为新设备名 d9（持久化）"
}

case_TV089() {
  T "DROP DATABASE root.tv089" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv089" >/dev/null 2>&1
  T "CREATE DATABASE root.tv089" >/dev/null; Q "CREATE DATABASE tv089" >/dev/null
  T "CREATE TIMESERIES root.tv089.d1.s1 INT32" >/dev/null
  T "INSERT INTO root.tv089.d1(time,s1) VALUES(1,1)" >/dev/null
  Q "CREATE VIEW tv089.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv089.**" >/dev/null
  sleep 5
  T "ALTER TIMESERIES root.tv089.d1.s1 RENAME TO root.tv089.d1.s9" >/dev/null
  T "ALTER TIMESERIES root.tv089.d1.s9 RENAME TO root.tv089.d1.s1" >/dev/null
  T "INSERT INTO root.tv089.d1(time,s1) VALUES(2,2)" >/dev/null
  sleep 8
  local o
  o=$(Q "SELECT count(*) FROM tv089.v")
  echo "  rows after round-trip rename: $(cnt_rows "$o")"
  [ "$(cnt_rows "$o")" -ge 2 ] || fail "改名往返后数据应仍可见"
  o=$(T "SHOW INVALID TIMESERIES" 2>/dev/null)
  echo "$o" | grep -q "root.tv089" && echo "  NOTE: 往返改名后仍有 invalid 序列"
}

CASES+=(
"TV-080|改名与视图|正向|同库设备改名后视图 TAG 应为新设备名（需求 §2.1.1.1）|case_TV080||0"
"TV-081|改名与视图|正向|设备改名 + auto_sync，改名后数据与 TAG 正确|case_TV081||0"
"TV-082|改名与视图|正向|跨库改名后目标库视图应包含该设备（需求 §2.1.1.3）|case_TV082||0"
"TV-083|改名与视图|边界|跨库改名后源库 DROP 被拦截（708/507）且 SHOW INVALID 给出 NewPath|case_TV083||0"
"TV-084|改名与视图|正向|删别名后源库可删除（官方清理链）|case_TV084||0"
"TV-085|改名与视图|边界|改名到不存在的库自动建库（当前行为，待研发确认）|case_TV085||0"
"TV-086|改名与视图|边界|单测点改名：原列保留、改名不触发补列|case_TV086||0"
"TV-087|改名与视图|边界|RESTRICT 视图在设备改名后仍包含同层级设备|case_TV087||0"
"TV-088|改名与视图|可靠性|重启 DN 后视图 TAG 仍为新设备名（持久化）|case_TV088||0"
"TV-089|改名与视图|边界|改名往返（s1→s9→s1）后视图数据可见|case_TV089||0"
)
