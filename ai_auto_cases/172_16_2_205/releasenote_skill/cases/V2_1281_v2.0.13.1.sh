#!/bin/bash
# ============================================================================
# 来源工作项：TDB-1281
#   PlainDeviceTimeIndex 复用 ArrayDeviceTimeIndex 的 serialize 方法
#   （相当于 serialize 时更新为新版 resource 文件）。
#
#   背景：旧版本可能写出 timeIndexType=1（PLAIN）的 .tsfile.resource；
#         PlainDeviceTimeIndex 原先的 serialize 直接抛 UnsupportedOperationException。
#         修复后删除该重写，继承 ArrayDeviceTimeIndex.serialize，
#         写盘类型标记固定为 3（ARRAY），即加载老文件后再落盘即完成格式升级。
#
#   本用例模拟老版本 resource（把类型字节改为 1）→ 重启 DN →
#   校验：数据可查、resource 类型升级为 3、再次重启仍正常。
#
#   .resource 布局：byte[0]=VERSION_NUMBER(1)，byte[1]=timeIndexType
#                   1=PLAIN，3=ARRAY
#
#   验证版本：2.0.13.1 RC3 / ac7f95e（普通模式）
# ============================================================================
RN1281_DB=rn1281

# 在所有 DN 上找该库的 resource 文件，输出 "ip path"
_rn1281_find_resource() {
  local ip f
  for ip in $DN_LIST; do
    f=$(ssh -n -o StrictHostKeyChecking=no root@$ip "find $DN_DIR/data -name '*.tsfile.resource' -path '*$RN1281_DB*' 2>/dev/null | head -1" 2>/dev/null)
    if [ -n "${f:-}" ]; then echo "$ip|$f"; return 0; fi
  done
  return 1
}

_rn1281_type_byte() {  # $1=ip $2=path
  ssh -n -o StrictHostKeyChecking=no root@$1 "od -An -tu1 -N2 '$2' 2>/dev/null" 2>/dev/null | awk '{print $2}'
}

_rn1281_restart_dn() {  # $1=ip
  ssh -n -o StrictHostKeyChecking=no root@$1 "pkill -9 -f 'com.timecho.iotdb.DataNode'; sleep 3" 2>/dev/null
  start_dn "$1"
  wait_running 300
}

case_RN218() {
  echo "  --- 老版本 PLAIN resource 文件加载后升级为 ARRAY 格式 ---"
  local D=$RN1281_DB

  Q "drop database if exists $D" >/dev/null 2>&1
  assert_ok "$(Q "create database $D")" "创建数据库 $D"
  assert_ok "$(T "create timeseries root.$D.d1.s1 double")" "创建序列"
  T "insert into root.$D.d1(time,s1) values(1,1.0),(2,2.0),(3,3.0)" >/dev/null 2>&1
  T "flush" >/dev/null 2>&1
  sleep 3

  local hit ip path b0 b1
  hit=$(_rn1281_find_resource) || { fail "未找到 $D 的 .tsfile.resource 文件"; return; }
  ip=${hit%%|*}; path=${hit#*|}
  ok "找到 resource：$ip:$path"

  b1=$(_rn1281_type_byte "$ip" "$path")
  [ "${b1:-}" = "3" ] && ok "初始 timeIndexType=3（ARRAY，符合新版格式）" || fail "初始 timeIndexType=${b1:-空}，期望 3"

  # 模拟老版本 PLAIN 文件：备份后把类型字节改为 1
  ssh -n -o StrictHostKeyChecking=no root@$ip "cp '$path' '$path.rn1281bak'" 2>/dev/null
  ssh -n -o StrictHostKeyChecking=no root@$ip "printf '\001' | dd of='$path' bs=1 seek=1 count=1 conv=notrunc 2>/dev/null" 2>/dev/null
  b1=$(_rn1281_type_byte "$ip" "$path")
  [ "${b1:-}" = "1" ] && ok "已将 resource 改为旧格式 PLAIN（timeIndexType=1）" || fail "改写类型字节失败（当前 ${b1:-空}）"

  # 重启 DN：加载老文件
  if _rn1281_restart_dn "$ip"; then ok "重启 DN 后集群 8/8"; else fail "重启 DN 后集群未达 8/8"; fi

  local cnt; cnt=$(T "select count(s1) from root.$D.d1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${cnt:-0}" = "3" ] && ok "老格式 resource 加载成功，数据可查（count=$cnt）" || fail "老格式 resource 加载后数据异常（count=${cnt:-空}）"

  # 核心断言：加载并再次落盘后，resource 升级为 ARRAY 格式
  sleep 3
  b1=$(_rn1281_type_byte "$ip" "$path")
  [ "${b1:-}" = "3" ] && ok "加载后 resource 已升级为 timeIndexType=3（ARRAY，新版格式）" || fail "加载后 timeIndexType=${b1:-空}，未升级为 3"

  # 再重启一次，确认升级后仍可正常加载
  if _rn1281_restart_dn "$ip"; then ok "二次重启后集群 8/8"; else fail "二次重启后集群未达 8/8"; fi
  cnt=$(T "select count(s1) from root.$D.d1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${cnt:-0}" = "3" ] && ok "二次重启后数据仍完整（count=$cnt）" || fail "二次重启后数据异常（count=${cnt:-空}）"
  b1=$(_rn1281_type_byte "$ip" "$path")
  [ "${b1:-}" = "3" ] && ok "二次重启后 timeIndexType 仍为 3" || fail "二次重启后 timeIndexType=${b1:-空}"

  ssh -n -o StrictHostKeyChecking=no root@$ip "rm -f '$path.rn1281bak'" 2>/dev/null
  Q "drop database if exists $D" >/dev/null 2>&1
}

CASES+=(
"RN-218|TDB-1281 旧 PLAIN resource 加载后升级为 ARRAY|兼容性|模拟旧格式 resource(type=1)，重启后数据可查且文件升级为 type=3，二次重启仍正常|case_RN218"
)
