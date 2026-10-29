# Group 6: high availability (DN down / CN leader switch) with the tree view feature
case_TV050() {
  local o
  T "DROP DATABASE root.tv050" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv050" >/dev/null 2>&1
  T "CREATE DATABASE root.tv050" >/dev/null; Q "CREATE DATABASE tv050" >/dev/null
  T "CREATE TIMESERIES root.tv050.d1.s1 INT32" >/dev/null
  stop_dn 172.16.2.3
  sleep 10
  o=$(Q "CREATE VIEW tv050.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv050.**")
  assert_ok "$o" "1 台 DN 停机时建视图"
  start_dn 172.16.2.3
  wait_running 300 >/dev/null 2>&1
  T "CREATE TIMESERIES root.tv050.d2.s2 INT64" >/dev/null
  sleep 10
  assert_col tv050 v s2 INT64 "DN 恢复后新增测点应补列"
}

case_TV051() {
  local o
  T "DROP DATABASE root.tv051" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv051" >/dev/null 2>&1
  T "CREATE DATABASE root.tv051" >/dev/null; Q "CREATE DATABASE tv051" >/dev/null
  T "CREATE TIMESERIES root.tv051.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv051.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv051.**" >/dev/null
  stop_dn 172.16.2.4
  sleep 10
  o=$(T "CREATE TIMESERIES root.tv051.d2.s2 DOUBLE")
  assert_ok "$o" "1 台 DN 停机时创建序列本身应成功"
  sleep 10
  assert_col tv051 v s2 DOUBLE "集群模式下其它副本应触发补列"
  start_dn 172.16.2.4
  wait_running 300 >/dev/null 2>&1
}

case_TV052() {
  local o base
  T "DROP DATABASE root.tv052" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv052" >/dev/null 2>&1
  T "CREATE DATABASE root.tv052" >/dev/null; Q "CREATE DATABASE tv052" >/dev/null
  T "CREATE TIMESERIES root.tv052.d1.s1 INT32" >/dev/null
  T "INSERT INTO root.tv052.d1(time,s1) VALUES(1,10)" >/dev/null
  Q "CREATE VIEW tv052.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv052.**" >/dev/null
  sleep 6
  base=$(norm_sql_out "$(Q 'SELECT dev,s1 FROM tv052.v ORDER BY time')")
  stop_dn 172.16.2.3
  sleep 12
  o=$(norm_sql_out "$(Q 'SELECT dev,s1 FROM tv052.v ORDER BY time')")
  if [ "$o" = "$base" ]; then echo "  DN 停机后查询结果与基线一致"; else fail "DN 停机后查询结果与基线不一致"; fi
  start_dn 172.16.2.3
  wait_running 300 >/dev/null 2>&1
}

case_TV053() {
  local o
  T "DROP DATABASE root.tv053" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv053" >/dev/null 2>&1
  T "CREATE DATABASE root.tv053" >/dev/null; Q "CREATE DATABASE tv053" >/dev/null
  T "CREATE TIMESERIES root.tv053.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv053.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv053.**" >/dev/null
  # 找出当前 CN leader 并停掉它
  local leader
  leader=$(Q "show confignodes;" | awk -F'|' '/Leader/{gsub(/ /,"",$3); print $3}')
  echo "  current CN leader: $leader"
  if [ -n "$leader" ]; then
    stop_cn "$leader"
    sleep 25
    T "CREATE TIMESERIES root.tv053.d2.s2 INT64" >/dev/null
    sleep 12
    assert_col tv053 v s2 INT64 "CN leader 切换后新增测点应补列"
    start_cn "$leader"
    sleep 20
    wait_running 300 >/dev/null 2>&1
  else
    fail "无法识别 CN leader"
  fi
}

case_TV054() {
  local o leader
  T "DROP DATABASE root.tv054" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv054" >/dev/null 2>&1
  T "CREATE DATABASE root.tv054" >/dev/null; Q "CREATE DATABASE tv054" >/dev/null
  T "CREATE TIMESERIES root.tv054.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv054.v(dev STRING TAG) WITH (auto_sync_schema=false) AS root.tv054.**" >/dev/null
  leader=$(Q "show confignodes;" | awk -F'|' '/Leader/{gsub(/ /,"",$3); print $3}')
  echo "  current CN leader: $leader"
  if [ -n "$leader" ]; then
    stop_cn "$leader"
    sleep 25
    o=$(Q "ALTER VIEW tv054.v SET PROPERTIES auto_sync_schema=true")
    echo "  切主期间 SET PROPERTIES 结果: $(echo "$o" | head -2 | tr '\n' ' ' | cut -c1-200)"
    start_cn "$leader"
    sleep 20
    wait_running 300 >/dev/null 2>&1
    sleep 5
    o=$(Q "SHOW CREATE VIEW tv054.v")
    if echo "$o" | grep -q "auto_sync_schema=true"; then
      T "CREATE TIMESERIES root.tv054.d2.s2 INT64" >/dev/null
      sleep 10
      assert_col tv054 v s2 INT64 "切主期间设置成功则补列应生效"
    else
      echo "  切主期间设置未生效，属性保持 false（记录为可接受行为）"
    fi
  else
    fail "无法识别 CN leader"
  fi
}

case_TV055() {
  local o
  T "DROP DATABASE root.tv055" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv055" >/dev/null 2>&1
  T "CREATE DATABASE root.tv055" >/dev/null; Q "CREATE DATABASE tv055" >/dev/null
  T "CREATE TIMESERIES root.tv055.d1.s1 INT32" >/dev/null
  Q "CREATE VIEW tv055.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv055.**" >/dev/null
  ssh -o StrictHostKeyChecking=no root@172.16.2.5 "pkill -9 -f 'com.timecho.iotdb.DataNode'" 2>/dev/null
  sleep 8
  o=$(T "CREATE TIMESERIES root.tv055.d2.s2 DOUBLE")
  assert_ok "$o" "kill -9 一台 DN 后创建序列应成功"
  sleep 12
  assert_col tv055 v s2 DOUBLE "其余副本应触发补列"
  start_dn 172.16.2.5
  wait_running 300 >/dev/null 2>&1
}

case_TV056() {
  local o base
  T "DROP DATABASE root.tv056" >/dev/null 2>&1; Q "DROP DATABASE IF EXISTS tv056" >/dev/null 2>&1
  T "CREATE DATABASE root.tv056" >/dev/null; Q "CREATE DATABASE tv056" >/dev/null
  T "CREATE TIMESERIES root.tv056.d1.s1 INT32" >/dev/null
  T "INSERT INTO root.tv056.d1(time,s1) VALUES(1,7)" >/dev/null
  Q "CREATE VIEW tv056.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv056.**" >/dev/null
  sleep 6
  base=$(norm_sql_out "$(Q 'SELECT dev,s1 FROM tv056.v ORDER BY time')")
  stop_dn 172.16.2.4
  stop_dn 172.16.2.6
  sleep 15
  o=$(norm_sql_out "$(Q 'SELECT dev,s1 FROM tv056.v ORDER BY time')")
  if [ "$o" = "$base" ]; then echo "  两台 DN 停机后 DR=2 仍可查询且结果一致"; else fail "两台 DN 停机后查询结果不一致"; fi
  start_dn 172.16.2.4
  start_dn 172.16.2.6
  wait_running 360 >/dev/null 2>&1
}

CASES+=(
"TV-050|高可用|可靠性|1 台 DN 停机时建视图并恢复后补列|case_TV050|SELECT dev,s1,s2 FROM tv050.v ORDER BY time,dev|0"
"TV-051|高可用|可靠性|1 台 DN 停机时建序列仍触发补列|case_TV051|SELECT dev,s1,s2 FROM tv051.v ORDER BY time,dev|0"
"TV-052|高可用|可靠性|1 台 DN 停机时视图查询与基线一致|case_TV052||0"
"TV-053|高可用|可靠性|CN leader 切换后新增测点仍补列|case_TV053||0"
"TV-054|高可用|可靠性|CN leader 切换期间修改属性|case_TV054||0"
"TV-055|高可用|可靠性|kill -9 一台 DN 后序列创建与补列|case_TV055||0"
"TV-056|高可用|可靠性|两台 DN 停机时 DR=2 查询仍可用|case_TV056||0"
)
