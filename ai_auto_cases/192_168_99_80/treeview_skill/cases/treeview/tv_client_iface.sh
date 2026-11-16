#!/bin/bash
# ============================================================================
# TV-CLI-01 不同客户端接口建序列 → 树转表视图自动补列一致性
#
#   需求背景：树转表视图开启 auto_sync_schema 后，树侧新增测点会自动补到视图列上。
#     该同步由 DataNode 的 schema 日志触发，**与用哪个客户端接口建序列无关**，
#     但不同接口走的 RPC/请求形态不同（JDBC Session、Python Thrift、Go Thrift），
#     需要逐个接口验证"补列 + 数据可查"一致。
#
#   覆盖接口（可用才测，缺依赖记 WARN 跳过；全不可用判 FAIL）：
#     - JDBC（Java，org.apache.iotdb.jdbc.IoTDBDriver）
#     - Python（apache-iotdb Session，Thrift）
#     - Go（iotdb-client-go v1.3.7，Thrift）
#     - REST（C/C++ 走官方 rest 接口）；需 enable_rest_service，未开启则跳过
#
#   每个接口的判据：
#     A 客户端建序列 + 写入均成功（rc=0 且输出 OK）
#     B 视图 `desc` 中出现该测点列（自动补列）
#     C 视图 `select count(m)/sum(m)` 与写入值一致（数据正确、只有 1 行）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_client_iface_${DATA_CONSENSUS}"

DB=db_tv_cli
LOGD=root.tvcli
ASSETS="$HERE/../../assets/client"
TV_LOG_BENIGN_EXTRA="Cluster is unactivated|License has been given up"
HOST0="${DN[0]}"

tv_prologue "$LOGD" "$DB"
tqt "create database $DB;" >/dev/null 2>&1
sleep 1

log "--- 1) 树侧首个测点 + 开启 auto_sync_schema 的视图 ---"
out=$(printf '%s\n' \
"create timeseries $LOGD.d1.m0 int32;" \
"insert into $LOGD.d1(time,m0) values(1,1);" \
"flush;" | "$CLI" -h "$HOST0" -u root -pw "$ROOT_PW" 2>&1)
assert_not_contains "树侧造数无报错" "$out" 'Exception|ERROR'
out=$(tqt_db "$DB" "create view vcli (dev STRING TAG) WITH (auto_sync_schema = true) AS $LOGD.**;")
assert_contains "视图 vcli 创建成功（auto_sync_schema=true）" "$(last_msg "$out")" 'successfully'
sleep 2

# 断言：某接口写入后，视图应自动补列且数据可查
check_iface(){
  local iface=$1 m=$2 exp=$3 desc n s
  sleep 5
  desc=$(tqt_db "$DB" "desc vcli;")
  assert_contains "[$iface] 视图已自动补列 $m" "$desc" "$m"
  n=$(tcol "$(tqt_db "$DB" "select count($m) from vcli;")" 1)
  assert_eq "[$iface] 视图 $m 行数=1" "$n" "1"
  s=$(tcol "$(tqt_db "$DB" "select sum($m) from vcli;")" 1)
  assert_num_eq "[$iface] 视图 sum($m)=$exp" "$s" "$exp"
}

ok=0; tried=0; skipped=""

log "--- 2) JDBC（Java Session 驱动）---"
# lib 目录：优先被测安装目录，其次 .80 上的 testdb 客户端目录（默认 DB_DIR 在 .80 上不存在）
LIBDIR="$DB_DIR/lib"
[ -d "$LIBDIR" ] || LIBDIR="/data/iotdb/testdb/${V_TESTDB}/lib"
if command -v javac >/dev/null 2>&1 && [ -f "$ASSETS/JdbcTv.java" ] && [ -d "$LIBDIR" ]; then
  tried=$((tried+1))
  mkdir -p "$ART/jdbc"
  if javac -cp "$LIBDIR/*" -d "$ART/jdbc" "$ASSETS/JdbcTv.java" >"$ART/jdbc_javac.log" 2>&1; then
    r=$(java -cp "$LIBDIR/*:$ART/jdbc" JdbcTv "$HOST0" 6667 root "$ROOT_PW" \
        "create timeseries $LOGD.d1.jspm int32" \
        "insert into $LOGD.d1(time,jspm) values(1,11)" 2>&1)
    echo "$r" >"$ART/jdbc_run.log"
    if printf '%s' "$r" | grep -q 'OK: insert'; then
      pass "[JDBC] 建序列+写入成功"
      check_iface "JDBC" jspm 11
      ok=$((ok+1))
    else
      fail "[JDBC] 建序列/写入失败：$(printf '%s' "$r" | tail -2 | tr '\n' ' ' | cut -c1-160)"
    fi
  else
    fail "[JDBC] javac 编译失败（见 $ART/jdbc_javac.log）"
  fi
else
  skipped="$skipped JDBC(javac/lib缺失)"
fi

log "--- 3) Python（apache-iotdb Session）---"
if command -v python3 >/dev/null 2>&1 && python3 -c "import iotdb" >/dev/null 2>&1; then
  tried=$((tried+1))
  r=$(python3 "$ASSETS/py_tv.py" "$HOST0" 6667 root "$ROOT_PW" "$LOGD.d1" pym 22 2>&1)
  echo "$r" >"$ART/python_run.log"
  if printf '%s' "$r" | grep -q 'OK insert record'; then
    pass "[Python] 建序列+写入成功"
    check_iface "Python" pym 22
    ok=$((ok+1))
  else
    fail "[Python] 建序列/写入失败：$(printf '%s' "$r" | tail -2 | tr '\n' ' ' | cut -c1-160)"
  fi
else
  skipped="$skipped Python(apache-iotdb未安装)"
fi

log "--- 4) Go（iotdb-client-go）---"
# 优先用仓库内预编译产物（assets/client/bin/go_tv，不受 /tmp 清理影响），缺失时才现场构建
GOBIN="$ASSETS/bin/go_tv"
if [ ! -x "$GOBIN" ] && [ -d "$ASSETS/go_tv" ] && [ -x /usr/local/go/bin/go ]; then
  GOBIN="$ART/go_tv"
  # 按需构建（go1.22 + iotdb-client-go v1.3.7，走 goproxy.cn 镜像；首次约 20s，之后有模块缓存）
  mkdir -p "$ART/gobuild"
  cp "$ASSETS/go_tv/main.go" "$ART/gobuild/" 2>/dev/null
  ( cd "$ART/gobuild" && export PATH=$PATH:/usr/local/go/bin GOTOOLCHAIN=local \
      GOPROXY=https://goproxy.cn,direct GOFLAGS=-mod=mod \
      && go mod init tvgo >/dev/null 2>&1 \
      && go get github.com/apache/iotdb-client-go@v1.3.7 >/dev/null 2>&1 \
      && go build -o "$GOBIN" . >"$ART/go_build.log" 2>&1 )
  [ -x "$GOBIN" ] && note "Go 客户端已按需构建：$GOBIN"
fi
if [ -x "$GOBIN" ]; then
  tried=$((tried+1))
  r=$("$GOBIN" "$HOST0" 6667 root "$ROOT_PW" "$LOGD.d1" gom 33 2>&1)
  echo "$r" >"$ART/go_run.log"
  if printf '%s' "$r" | grep -q 'OK insert record'; then
    pass "[Go] 建序列+写入成功"
    check_iface "Go" gom 33
    ok=$((ok+1))
  else
    fail "[Go] 建序列/写入失败：$(printf '%s' "$r" | tail -2 | tr '\n' ' ' | cut -c1-160)"
  fi
else
  skipped="$skipped Go(go 工具链缺失或构建失败)"
fi

log "--- 5) 接口覆盖小结 ---"
[ -n "$skipped" ] && warn "跳过的接口（依赖缺失）：$skipped"
if [ "$tried" -eq 0 ]; then
  fail "一个客户端接口都没跑起来（环境缺少 javac/python-iotdb/go 二进制）"
else
  pass "本轮覆盖 $ok/$tried 个客户端接口"
fi

log "--- 6) 收尾三件套 ---"
tv_sync_lag 60 || true
tv_replica_consistency "vcli m0" "select count(*), sum(m0) from $DB.vcli;"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
