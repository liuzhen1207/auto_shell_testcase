#!/bin/bash
# ============================================================================
# 来源工作项：TDB-1262
#   【2.0.9.1 RC1 新引入问题】数据升级 CN NPE：把旧版本数据目录换到新版本启动，
#   用 benchmark 写入新数据（原树/新表）时 CN 出现数组越界与空指针。
#   另有滚动升级场景：旧版本集群在线 → 逐个升级 CN follower → CN leader → DN
#   （串行），升级过程中有并发读写。
#
#   本文件两个用例（升级版本：2.0.12.1 RC12 → 2.0.13.1 RC3）：
#     RN-219 数据升级（非滚动）：旧集群数据（树 + 表含 OBJECT）→ 整体换二进制启动
#            → 旧数据可查、写入新数据（树/表）成功、无 NPE/数组越界
#     RN-220 滚动升级：旧集群（树 + 表含 OBJECT）在线 + 并发读写 → CN follower →
#            CN leader → DN 串行替换 lib/sbin → 数据完整、最终 8/8 新版本
#
#   前置条件：集群当前运行旧版本（RC12 c05111d），由 tools/upgrade_driver.sh 准备。
# ============================================================================
UPG_TREE_DB=upg_tree
UPG_TABLE_DB=upg_table
UPG_OBJ_HEX='cafebabe'

# 旧版本客户端（升级前使用，to_object 等新语法在旧服务端才可用）
CLI_OLD=/data2/iotdb/$UPG_OLD/sbin/start-cli.sh
TO() { timeout 120 $CLI_OLD -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }
QO() { timeout 120 $CLI_OLD -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "$1" 2>&1; }

_upg_is_old() {  # 当前是否旧版本
  local v; v=$(upg_version)
  [ "${v:-}" = "c05111d" ]
}

_upg_seed_data() {
  local tag=$1
  QO "drop database if exists $UPG_TREE_DB" >/dev/null 2>&1
  QO "drop database if exists $UPG_TABLE_DB" >/dev/null 2>&1
  QO "create database $UPG_TREE_DB" >/dev/null 2>&1
  QO "create database $UPG_TABLE_DB" >/dev/null 2>&1
  TO "create timeseries root.$UPG_TREE_DB.d1.s1 double" >/dev/null 2>&1
  TO "insert into root.$UPG_TREE_DB.d1(time,s1) values(1,1.5),(2,2.5),(3,3.5)" >/dev/null 2>&1
  QO "create table $UPG_TABLE_DB.t1 (time TIMESTAMP TIME, dev STRING TAG, val DOUBLE FIELD, obj OBJECT FIELD)" >/dev/null 2>&1
  QO "insert into $UPG_TABLE_DB.t1(time, dev, val, obj) values(1, 'd1', 1.5, to_object(true, 0, X'$UPG_OBJ_HEX'))" >/dev/null 2>&1
  QO "insert into $UPG_TABLE_DB.t1(time, dev, val) values(2, 'd1', 2.5)" >/dev/null 2>&1
  TO "flush" >/dev/null 2>&1
  sleep 2
  local tc; tc=$(TO "select count(s1) from root.$UPG_TREE_DB.d1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  local bc; bc=$(QO "select count(*) from $UPG_TABLE_DB.t1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${tc:-0}" -ge 3 ] && ok "$tag 树模型基线数据写入（count=$tc）" || fail "$tag 树模型基线数据异常（count=${tc:-空}）"
  [ "${bc:-0}" -ge 2 ] && ok "$tag 表模型基线数据写入（count=$bc）" || fail "$tag 表模型基线数据异常（count=${bc:-空}）"
}

_upg_verify_old_data() {
  local tag=$1
  local tc bc ol
  tc=$(T "select count(s1) from root.$UPG_TREE_DB.d1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${tc:-0}" -ge 3 ] && ok "$tag 旧树模型数据可查（count=$tc）" || fail "$tag 旧树模型数据丢失（count=${tc:-空}）"
  bc=$(Q "select count(*) from $UPG_TABLE_DB.t1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${bc:-0}" -ge 2 ] && ok "$tag 旧表模型数据可查（count=$bc）" || fail "$tag 旧表模型数据丢失（count=${bc:-空}）"
  ol=$(Q "select length(read_object(obj)) from $UPG_TABLE_DB.t1 where time = 1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${ol:-0}" = "4" ] && ok "$tag OBJECT 列值可读（length=$ol）" || fail "$tag OBJECT 列读取异常（length=${ol:-空}）"
}

_upg_write_new_data() {
  local tag=$1 ts
  ts=$(( $(date +%s) * 1000 ))
  assert_ok "$(T "insert into root.$UPG_TREE_DB.d1(time,s1) values($ts, 9.5)")" "$tag 写入新树模型数据"
  assert_ok "$(Q "insert into $UPG_TABLE_DB.t1(time, dev, val, obj) values($ts, 'd2', 9.5, to_object(true, 0, X'$UPG_OBJ_HEX'))")" "$tag 写入新表模型数据（含 OBJECT）"
  sleep 2
  local n; n=$(Q "select count(*) from $UPG_TABLE_DB.t1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${n:-0}" -ge 3 ] && ok "$tag 新写入可见（表 count=$n）" || fail "$tag 新写入不可见（表 count=${n:-空}）"
}

# ---------------------------------------------------------------- RN-219 数据升级
case_RN219() {
  echo "  --- 数据升级：RC12 数据目录 → RC3 二进制（整体替换）---"
  if ! _upg_is_old; then
    fail "当前集群不是 RC12（BuildInfo=$(upg_version)），无法执行数据升级用例"
    return
  fi
  ok "当前为旧版本 RC12（BuildInfo=c05111d）"
  _upg_seed_data "[升级前]"

  local ip
  echo "  停止全部节点…"
  for ip in $CN_LIST; do upg_stop_node "$ip" cn || fail "停止 CN $ip 失败"; done
  for ip in $DN_LIST; do upg_stop_node "$ip" dn || fail "停止 DN $ip 失败"; done

  echo "  替换二进制（lib/sbin → RC3）…"
  for ip in $CN_LIST; do
    upg_swap_build "$ip" cn "$UPG_OLD" "$UPG_RC3" && ok "CN $ip 已替换为 RC3 二进制" || fail "CN $ip 替换失败"
  done
  for ip in $DN_LIST; do
    upg_swap_build "$ip" dn "$UPG_OLD" "$UPG_RC3" && ok "DN $ip 已替换为 RC3 二进制" || fail "DN $ip 替换失败"
  done

  echo "  启动全部节点…"
  for ip in $CN_LIST; do upg_start_node "$ip" cn "$UPG_CN_DIR/$UPG_OLD" >/dev/null 2>&1; done
  sleep 10
  for ip in $DN_LIST; do upg_start_node "$ip" dn "$UPG_DN_DIR/$UPG_OLD" >/dev/null 2>&1; done

  if upg_wait_running 600; then ok "升级后集群 8/8"; else fail "升级后集群未达 8/8"; fi
  local v; v=$(upg_version)
  [ "${v:-}" = "ac7f95e" ] && ok "集群版本已升级为 RC3（ac7f95e）" || fail "集群版本异常（${v:-空}）"

  _upg_verify_old_data "[升级后]"
  _upg_write_new_data "[升级后]"

  # 针对性检查：CN 日志中不得出现 NPE / 数组越界
  local ip2 bad=0
  for ip2 in $CN_LIST; do
    n=$(ssh -n -o StrictHostKeyChecking=no root@$ip2 "grep -cE 'NullPointerException|ArrayIndexOutOfBounds' $UPG_CN_DIR/$UPG_OLD/logs/log_confignode_error.log 2>/dev/null | head -1" 2>/dev/null)
    [ "${n:-0}" -gt 0 ] && { bad=$((bad + n)); echo "    [debug] CN $ip2 命中 $n 条 NPE/数组越界"; }
  done
  [ "$bad" -eq 0 ] && ok "CN 错误日志无 NPE / 数组越界" || fail "CN 错误日志出现 $bad 条 NPE/数组越界（TDB-1262 现象）"

  Q "drop database if exists $UPG_TREE_DB" >/dev/null 2>&1
  Q "drop database if exists $UPG_TABLE_DB" >/dev/null 2>&1
}

# ---------------------------------------------------------------- RN-220 滚动升级
case_RN220() {
  echo "  --- 滚动升级：CN follower → CN leader → DN（并发读写）---"
  if ! _upg_is_old; then
    fail "当前集群不是 RC12（BuildInfo=$(upg_version)），无法执行滚动升级用例"
    return
  fi
  ok "当前为旧版本 RC12（BuildInfo=c05111d）"
  _upg_seed_data "[滚动升级前]"

  # 启动并发读写
  local wdir=/tmp/upg_wl
  WL_NEW=$UPG_OLD bash "$BASE/tools/upgrade_workload.sh" start "$wdir" >/dev/null 2>&1
  sleep 5
  ok "并发读写负载已启动（$(cat "$wdir/pid" 2>/dev/null)）"

  local followers="172.16.2.27 172.16.2.28"
  local leader="172.16.2.26"
  local ip

  for ip in $followers; do
    echo "  升级 CN follower $ip …"
    upg_stop_node "$ip" cn && upg_swap_build "$ip" cn "$UPG_OLD" "$UPG_RC3" && upg_start_node "$ip" cn "$UPG_CN_DIR/$UPG_OLD" >/dev/null 2>&1 \
      && ok "CN follower $ip 升级并启动" || fail "CN follower $ip 升级失败"
    upg_wait_running 300 && ok "  CN follower $ip 升级后集群仍 8/8" || fail "  CN follower $ip 升级后集群未恢复"
  done

  echo "  升级 CN leader $leader（最后）…"
  upg_stop_node "$leader" cn && upg_swap_build "$leader" cn "$UPG_OLD" "$UPG_RC3" && upg_start_node "$leader" cn "$UPG_CN_DIR/$UPG_OLD" >/dev/null 2>&1 \
    && ok "CN leader $leader 升级并启动" || fail "CN leader $leader 升级失败"
  upg_wait_running 300 && ok "CN leader 升级后集群仍 8/8" || fail "CN leader 升级后集群未恢复"

  for ip in $DN_LIST; do
    echo "  升级 DN $ip …"
    upg_stop_node "$ip" dn && upg_swap_build "$ip" dn "$UPG_OLD" "$UPG_RC3" && upg_start_node "$ip" dn "$UPG_DN_DIR/$UPG_OLD" >/dev/null 2>&1 \
      && ok "DN $ip 升级并启动" || fail "DN $ip 升级失败"
    upg_wait_running 300 && ok "  DN $ip 升级后集群仍 8/8" || fail "  DN $ip 升级后集群未恢复"
  done

  # 停止负载并统计
  bash "$BASE/tools/upgrade_workload.sh" stop "$wdir" >/dev/null 2>&1
  local rep; rep=$(bash "$BASE/tools/upgrade_workload.sh" report "$wdir" 2>&1)
  echo "$rep" | sed 's/^/    /'
  local tok bk tek bek
  tok=$(echo "$rep" | awk -F= '/^tree_ok=/{print $2}')
  bk=$(echo "$rep" | awk -F= '/^table_ok=/{print $2}')
  tek=$(echo "$rep" | awk -F= '/^tree_err=/{print $2}')
  bek=$(echo "$rep" | awk -F= '/^table_err=/{print $2}')
  [ "${tok:-0}" -gt 0 ] && [ "${bk:-0}" -gt 0 ] && ok "并发读写期间有成功写入（tree=${tok} table=${bk}）" || fail "并发读写期间无成功写入"

  # 数据完整性
  if upg_wait_running 600; then ok "滚动升级完成后集群 8/8"; else fail "滚动升级完成后集群未达 8/8"; fi
  local v; v=$(upg_version)
  [ "${v:-}" = "ac7f95e" ] && ok "全部节点已升级为 RC3（ac7f95e）" || fail "版本未全部升级（${v:-空}）"
  _upg_verify_old_data "[滚动升级后]"
  _upg_write_new_data "[滚动升级后]"

  # 并发写入的数据应可查（允许少量因节点重启失败的写入）
  local tc; tc=$(T "select count(s1) from root.$UPG_TREE_DB.d1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${tc:-0}" -ge $(( 3 + tok )) ] && ok "并发写入的树数据全部可查（$tc ≥ 3+$tok）" || fail "并发写入的树数据缺失（count=${tc:-空}，期望 ≥ $((3+tok))）"
  local bc; bc=$(Q "select count(*) from $UPG_TABLE_DB.t1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${bc:-0}" -ge $(( 2 + bk )) ] && ok "并发写入的表数据全部可查（$bc ≥ 2+$bk）" || fail "并发写入的表数据缺失（count=${bc:-空}，期望 ≥ $((2+bk))）"

  # 日志：不得出现 NPE / 数组越界
  local bad=0 n
  for ip in $CN_LIST; do
    n=$(ssh -n -o StrictHostKeyChecking=no root@$ip "grep -cE 'NullPointerException|ArrayIndexOutOfBounds' $UPG_CN_DIR/$UPG_OLD/logs/log_confignode_error.log 2>/dev/null | head -1" 2>/dev/null)
    bad=$((bad + ${n:-0}))
  done
  [ "$bad" -eq 0 ] && ok "CN 错误日志无 NPE / 数组越界" || fail "CN 错误日志出现 $bad 条 NPE/数组越界"

  Q "drop database if exists $UPG_TREE_DB" >/dev/null 2>&1
  Q "drop database if exists $UPG_TABLE_DB" >/dev/null 2>&1
}

CASES+=(
"RN-219|TDB-1262 数据升级（RC12→RC3）|升级|旧集群树+表(含 OBJECT)数据整体换二进制启动：旧数据可查、可写新数据、CN 无 NPE/数组越界|case_RN219"
"RN-220|TDB-1262 滚动升级（CN→DN，含并发读写）|升级|旧集群在线+并发读写，逐个升级 CN follower→leader→DN：最终 8/8 新版本、数据完整、无 NPE/数组越界|case_RN220"
)
