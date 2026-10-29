# Group 9: LOAD TSFILE 触发创建新序列时，是否触发树转表视图自动补列。
# 实测结论（dc11a35）：LOAD 走 schema 创建路径，会触发补列（TV-090 起固化该行为）。
# 注意：LOAD 的文件必须在「执行该语句的 DataNode」本地磁盘上（报错 701 otherwise），
#       因此用例统一：造 tsfile -> 拉到 205 -> 推到每个 DN 的 /tmp/<db>/load.tsfile -> 在 DN 上 LOAD。

DN_ALL="172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6"

# build_tsfile <root.db> <name:type>...  -> 回显 DN 上的 load 路径
build_tsfile() {
  local db=$1; shift
  local base=${db#root.}
  local cols="" vals="" item name typ ip tsf
  T "DROP DATABASE $db" >/dev/null 2>&1
  T "CREATE DATABASE $db" >/dev/null
  for item in "$@"; do
    name=${item%%:*}; typ=${item##*:}
    T "CREATE TIMESERIES $db.d1.$name $typ" >/dev/null
    cols="$cols,$name"
    case "$typ" in
      FLOAT|DOUBLE) vals="$vals,1.5" ;;
      *) vals="$vals,1" ;;
    esac
  done
  T "INSERT INTO $db.d1(time${cols}) VALUES(1${vals})" >/dev/null
  T "FLUSH" >/dev/null
  sleep 3
  tsf=""
  for ip in $DN_ALL; do
    tsf=$(ssh -o StrictHostKeyChecking=no root@$ip "find /data1/iotdb/$NEW/data/datanode/data -name '*.tsfile' -path '*$base*' 2>/dev/null | head -1" 2>/dev/null)
    [ -n "$tsf" ] && break
  done
  if [ -z "$tsf" ]; then
    fail "无法定位 $db 的 tsfile"
    return 1
  fi
  echo "  tsfile on $ip: $tsf" >&2
  ssh -o StrictHostKeyChecking=no root@$ip "cat $tsf" > /tmp/$base.tsfile 2>/dev/null
  for ip in $DN_ALL; do
    ssh -o StrictHostKeyChecking=no root@$ip "mkdir -p /tmp/$base" 2>/dev/null
    scp -o StrictHostKeyChecking=no /tmp/$base.tsfile root@$ip:/tmp/$base/load.tsfile >/dev/null 2>&1
  done
  echo "/tmp/$base/load.tsfile"
}

# do_load <dn-local-path>
do_load() {
  local p=$1 ip out
  for ip in $DN_ALL; do
    out=$(Tn $ip "LOAD '$p'" 2>&1 | tail -1)
    case "$out" in
      *successfully*) echo "  loaded via $ip"; return 0 ;;
    esac
  done
  echo "  load output: $out"
  fail "LOAD 未成功"
  return 1
}

case_TV090() {
  local p
  p=$(build_tsfile root.tv090 s1:INT32 s2:INT64 s3:FLOAT) || return
  T "DELETE TIMESERIES root.tv090.d1.s1" >/dev/null
  T "DELETE TIMESERIES root.tv090.d1.s2" >/dev/null
  T "DELETE TIMESERIES root.tv090.d1.s3" >/dev/null
  T "CREATE TIMESERIES root.tv090.d0.s0 INT32" >/dev/null
  Q "DROP DATABASE IF EXISTS tv090" >/dev/null 2>&1; Q "CREATE DATABASE tv090" >/dev/null
  Q "CREATE VIEW tv090.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv090.**" >/dev/null
  sleep 5
  do_load "$p" || return
  sleep 10
  assert_col tv090 v s1 INT32 "LOAD 后应补列 s1（LOAD 触发补列）"
  assert_col tv090 v s2 INT64 "LOAD 后应补列 s2"
  assert_col tv090 v s3 FLOAT "LOAD 后应补列 s3"
  local o n
  o=$(Q "SELECT * FROM tv090.v"); n=$(cnt_rows "$(Q "SELECT count(*) FROM tv090.v")")
  echo "  view rows after load: $n"
  [ "${n:-0}" -ge 1 ] || fail "LOAD 的数据应可通过视图查询"
}

case_TV091() {
  local p
  p=$(build_tsfile root.tv091 s1:INT32) || return
  T "CREATE TIMESERIES root.tv091.d0.s0 INT32" >/dev/null
  Q "DROP DATABASE IF EXISTS tv091" >/dev/null 2>&1; Q "CREATE DATABASE tv091" >/dev/null
  Q "CREATE VIEW tv091.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv091.**" >/dev/null
  sleep 5
  assert_col tv091 v s1 INT32 "前置：s1 列已存在"
  T "DELETE TIMESERIES root.tv091.d1.s1" >/dev/null
  sleep 2
  do_load "$p" || return
  sleep 10
  assert_col tv091 v s1 INT32 "LOAD 已存在列后列应保持"
  [ "$(cnt_rows "$(Q "SELECT count(*) FROM tv091.v")")" -ge 1 ] || fail "重载后数据应可见"
  echo "  NOTE: 已存在列的 LOAD 场景已覆盖；若日志出现 ViewColumnAutoSyncTrigger 552/305，属已知日志缺陷"
}

case_TV092() {
  local p
  p=$(build_tsfile root.tv092 s1:INT32 s2:INT64 s3:FLOAT) || return
  T "DELETE TIMESERIES root.tv092.d1.s1" >/dev/null
  T "DELETE TIMESERIES root.tv092.d1.s2" >/dev/null
  T "DELETE TIMESERIES root.tv092.d1.s3" >/dev/null
  # s1 预先加到视图里：用一个已存在的独立测点占位，再让 LOAD 带 s1/s2/s3
  T "CREATE TIMESERIES root.tv092.d0.s1 INT32" >/dev/null
  Q "DROP DATABASE IF EXISTS tv092" >/dev/null 2>&1; Q "CREATE DATABASE tv092" >/dev/null
  Q "CREATE VIEW tv092.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv092.**" >/dev/null
  sleep 6
  assert_col tv092 v s1 INT32 "前置：s1 已存在"
  do_load "$p" || return
  sleep 10
  assert_col tv092 v s1 INT32 "s1 应保持"
  assert_col tv092 v s2 INT64 "新增列 s2 应补上"
  assert_col tv092 v s3 FLOAT "新增列 s3 应补上"
}

case_TV093() {
  local p
  p=$(build_tsfile root.tv093src s1:INT32 s2:INT64) || return
  T "DELETE TIMESERIES root.tv093src.d1.s1" >/dev/null
  T "DELETE TIMESERIES root.tv093src.d1.s2" >/dev/null
  T "CREATE TIMESERIES root.tv093.d0.s0 INT32" >/dev/null
  Q "DROP DATABASE IF EXISTS tv093" >/dev/null 2>&1; Q "CREATE DATABASE tv093" >/dev/null
  Q "CREATE VIEW tv093.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv093.**" >/dev/null
  sleep 5
  do_load "$p" || return
  sleep 8
  assert_no_col tv093 v s1 "视图前缀外的 LOAD 不应补列"
  [ "$(cnt_rows "$(T "SELECT count(*) FROM root.tv093src.d1")")" -ge 1 ] || fail "tsfile 数据应已加载到源前缀"
}

case_TV094() {
  local p
  p=$(build_tsfile root.tv094 s1:INT32 s2:INT64) || return
  T "DELETE TIMESERIES root.tv094.d1.s1" >/dev/null
  T "DELETE TIMESERIES root.tv094.d1.s2" >/dev/null
  T "CREATE TIMESERIES root.tv094.d0.s0 INT32" >/dev/null
  Q "DROP DATABASE IF EXISTS tv094" >/dev/null 2>&1; Q "CREATE DATABASE tv094" >/dev/null
  Q "CREATE VIEW tv094.v(dev STRING TAG) AS root.tv094.**" >/dev/null
  sleep 5
  do_load "$p" || return
  sleep 8
  assert_no_col tv094 v s1 "auto_sync=false 时 LOAD 不应补列"
}

case_TV095() {
  local p
  p=$(build_tsfile root.tv095 s1:INT32 s2:INT64) || return
  # 2 层设备 p.q：restrict 2 tag 视图应命中
  T "DELETE TIMESERIES root.tv095.d1.s1" >/dev/null
  T "DELETE TIMESERIES root.tv095.d1.s2" >/dev/null
  T "CREATE TIMESERIES root.tv095.a.b.s1 INT32" >/dev/null
  Q "DROP DATABASE IF EXISTS tv095" >/dev/null 2>&1; Q "CREATE DATABASE tv095" >/dev/null
  Q "CREATE VIEW tv095.vr(a STRING TAG, b STRING TAG) RESTRICT WITH (auto_sync_schema=true) AS root.tv095.**" >/dev/null
  sleep 5
  # tsfile 里是 1 层设备 d1，restrict 2 tag 不应命中；先补一个 2 层设备的 tsfile 更复杂，这里断言“不命中”
  do_load "$p" || return
  sleep 8
  echo "  NOTE: tsfile 内为 1 层设备，RESTRICT(2 tag) 视图不应对其补列"
  local n; n=$(cnt_rows "$(Q "SELECT count(*) FROM tv095.vr")")
  echo "  restrict view rows for 1-level device: $n"
  [ "${n:-1}" = "0" ] || fail "RESTRICT(2 tag) 视图不应包含 1 层设备 d1"
}

case_TV096() {
  local p
  p=$(build_tsfile root.tv096 s1:INT32) || return
  T "DELETE TIMESERIES root.tv096.d1.s1" >/dev/null
  T "CREATE TIMESERIES root.tv096.d0.s0 INT32" >/dev/null
  Q "DROP DATABASE IF EXISTS tv096" >/dev/null 2>&1; Q "CREATE DATABASE tv096" >/dev/null
  Q "CREATE VIEW tv096.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv096.**" >/dev/null
  sleep 5
  do_load "$p" || return
  sleep 10
  local n1
  n1=$(cnt_rows "$(Q "SELECT count(*) FROM tv096.v")")
  echo "  rows after first load: $n1"
  do_load "$p" || return
  sleep 10
  local n2
  n2=$(cnt_rows "$(Q "SELECT count(*) FROM tv096.v")")
  echo "  rows after second load: $n2"
  assert_col tv096 v s1 INT32 "重复 LOAD 后列不丢失、不重复"
  [ "${n2:-0}" = "${n1:-0}" ] || echo "  NOTE: 重复 LOAD 使行数 $n1 -> $n2（去重行为需研发确认）"
}

case_TV097() {
  local p
  p=$(build_tsfile root.tv097 s1:INT32 s2:INT64) || return
  T "DELETE TIMESERIES root.tv097.d1.s1" >/dev/null
  T "DELETE TIMESERIES root.tv097.d1.s2" >/dev/null
  T "CREATE TIMESERIES root.tv097.d0.s0 INT32" >/dev/null
  Q "DROP DATABASE IF EXISTS tv097" >/dev/null 2>&1; Q "CREATE DATABASE tv097" >/dev/null
  Q "CREATE VIEW tv097.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv097.**" >/dev/null
  sleep 5
  do_load "$p" || return
  sleep 10
  assert_col tv097 v s1 INT32 "LOAD 后应补列 s1"
  echo "  restart one DN to verify persistence"
  stop_dn 172.16.2.4 >/dev/null 2>&1
  start_dn 172.16.2.4 >/dev/null 2>&1
  wait_running 240 >/dev/null 2>&1
  sleep 10
  # 重启会必然产生选主/连接重试类 ERROR，重设日志标记，只统计重启之后的噪声
  log_mark_all >/dev/null 2>&1
  assert_col tv097 v s1 INT32 "重启 DN 后 LOAD 补的列应仍在"
  [ "$(cnt_rows "$(Q "SELECT count(*) FROM tv097.v")")" -ge 1 ] || fail "重启后 LOAD 数据应仍可查"
}

CASES+=(
"TV-090|LOAD与补列|正向|LOAD TSFILE 创建新序列时触发自动补列（列与类型正确、数据可查）|case_TV090||0"
"TV-091|LOAD与补列|边界|LOAD 已存在列的测点：列保持、数据可查（观察是否触发日志缺陷）|case_TV091||0"
"TV-092|LOAD与补列|正向|LOAD 混合场景：已有列保持、新增列补齐|case_TV092||0"
"TV-093|LOAD与补列|反向|LOAD 到视图前缀之外不补列|case_TV093||0"
"TV-094|LOAD与补列|反向|auto_sync=false 时 LOAD 不补列|case_TV094||0"
"TV-095|LOAD与补列|边界|RESTRICT 视图 + LOAD 层级不匹配不补列|case_TV095||0"
"TV-096|LOAD与补列|边界|重复 LOAD 同一文件：列不重复、行数行为记录|case_TV096||0"
"TV-097|LOAD与补列|可靠性|LOAD 补列后重启 DN，列与数据持久化|case_TV097||0"
)
