#!/bin/bash
# ============================================================================
# 来源工作项：TDB-806（V2-423）使用 SQL 手动修复分区表 —— **真正需要修复的场景**
#
#   造数方式（参照用户的 tc2026_April_003602_..._auto_repair_dev_ttl_ns.sh）：
#     2.0.6.1 + timestamp_precision=ns + ttl_check_interval=10000
#     数据跨两个 7 天时间分区（2026-01-01 与当前时间），只对 d1 设设备级 TTL
#     → 2.0.6.1 的 bug：TTL 清理时把整个时间分区条目删除（其它设备一起受害）
#     → 窄时间窗口查询返回 0，但数据仍在 DN（总数仍为 2）
#
#   本用例：构造缺失分区 → 数据升级到 RC3 → REPAIR DATA PARTITION TABLE
#           → 校验 show timepartition 由 1 恢复为 2、窄窗口查询恢复。
#
#   前置：集群运行 2.0.6.1（802dd96），conf 已设 timestamp_precision=ns、
#         ttl_check_interval=10000（tools/run_rn228.sh 准备）
# ============================================================================
RN806B_DB=rn806
RN806B_T1=1767225600000000000     # 2026-01-01T00:00:00Z (ns)
RN806B_OLD=${RN806B_OLD:-v2061_rc7_0915_802dd96}
RN806B_NEW=${UPG_RC3:-v20131rc3_1117_ac7f95e}

# 旧版本（2.0.6.1）客户端
TO() { timeout 90 /data2/iotdb/$RN806B_OLD/sbin/start-cli.sh -h "$HOST" -p 6667 -u root -pw "$PW" -sql_dialect tree -e "$1" 2>&1; }

_rn806b_old_version() {
  TO "show cluster" 2>/dev/null | awk -F'|' '/DataNode/{gsub(/ /,"",$8); print $8; exit}'
}

# 旧版本下的时间分区数量 / 数据点数（2.0.6.1 不支持 count timepartition，用 show 统计行数）
_rn806b_partcount_old() {
  TO "show timepartition where database=root.$RN806B_DB" 2>/dev/null \
    | awk -F'|' 'NF>2 && $2 ~ /^ *[0-9]+ *$/ {c++} END{print c+0}'
}
_rn806b_count_old() {  # $1=device $2=where
  TO "select count(s1) from root.$RN806B_DB.$1 ${2:-}" 2>&1 \
    | awk -F'|' '/\|/{gsub(/ /,"",$2); if ($2 ~ /^[0-9]+$/) {print $2; exit}}'
}

# RC3 下：时间分区数量 / 数据点数
_rn806b_partcount() {
  T "show data partition table" >/dev/null 2>&1   # 预热，忽略结果
  T "count timepartition where database=root.$RN806B_DB" 2>&1 \
    | awk -F'|' '/\|/{gsub(/ /,"",$2); if ($2 ~ /^[0-9]+$/) {print $2; exit}}'
}
_rn806b_partcount_show() {
  T "show timepartition where database=root.$RN806B_DB" 2>/dev/null \
    | awk -F'|' 'NF>2 && $2 ~ /^ *[0-9]+ *$/ {c++} END{print c+0}'
}
_rn806b_count() {  # $1=device $2=where
  T "select count(s1) from root.$RN806B_DB.$1 ${2:-}" 2>&1 \
    | awk -F'|' '/\|/{gsub(/ /,"",$2); if ($2 ~ /^[0-9]+$/) {print $2; exit}}'
}

# 按构建目录强杀（2.0.6.1 主类名与 RC3 不同，不能只按 com.timecho.iotdb 匹配）
_rn806b_stop_all() {
  local ip i n
  for ip in $CN_LIST $DN_LIST; do
    ssh -n -o StrictHostKeyChecking=no root@$ip "pkill -9 -f '$RN806B_OLD' 2>/dev/null || true; pkill -9 -f '$RN806B_NEW' 2>/dev/null || true; pkill -9 java 2>/dev/null || true" 2>/dev/null
  done
  for i in $(seq 1 30); do
    n=0
    for ip in $CN_LIST $DN_LIST; do
      c=$(ssh -n -o StrictHostKeyChecking=no root@$ip "pgrep -c java 2>/dev/null | head -1" 2>/dev/null | tr -dc '0-9')
      n=$((n + ${c:-0}))
    done
    [ "$n" = "0" ] && return 0
    sleep 2
  done
  return 1
}

_rn806b_upgrade_inplace() {
  local ip
  _rn806b_stop_all || return 1
  for ip in $CN_LIST; do upg_swap_build "$ip" cn "$RN806B_OLD" "$RN806B_NEW" >/dev/null 2>&1 || return 1; done
  for ip in $DN_LIST; do upg_swap_build "$ip" dn "$RN806B_OLD" "$RN806B_NEW" >/dev/null 2>&1 || return 1; done
  for ip in $CN_LIST; do upg_start_node "$ip" cn "$UPG_CN_DIR/$RN806B_OLD" >/dev/null 2>&1; done
  sleep 10
  for ip in $DN_LIST; do upg_start_node "$ip" dn "$UPG_DN_DIR/$RN806B_OLD" >/dev/null 2>&1; done
  upg_wait_running 600
}

case_RN228() {
  echo "  --- TDB-806 真正需要修复的场景（2.0.6.1 TTL 误删分区 → 升级 RC3 → REPAIR 恢复）---"
  local v; v=$(_rn806b_old_version)
  if [ "${v:-}" != "802dd96" ]; then
    fail "当前版本不是 2.0.6.1（${v:-空}），无法构造缺失分区"
    return
  fi
  ok "当前为 2.0.6.1（BuildInfo=802dd96）"

  # 1) 造数（跨两个时间分区）
  local T2=$(( $(date +%s) * 1000000000 )) d
  TO "drop database if exists $RN806B_DB" >/dev/null 2>&1
  TO "create database $RN806B_DB" >/dev/null 2>&1
  for d in d1 d2 d3 d4; do
    TO "create timeseries root.$RN806B_DB.$d.s1 double" >/dev/null 2>&1
    TO "insert into root.$RN806B_DB.$d(time,s1) values($RN806B_T1,1.0),($T2,2.0)" >/dev/null 2>&1
  done
  TO "flush" >/dev/null 2>&1
  sleep 3
  local base pc0
  base=$(_rn806b_count_old d2)
  pc0=$(_rn806b_partcount_old)
  [ "${base:-0}" -ge 2 ] && ok "基线数据写入（d2 count=$base）" || fail "基线数据异常（d2 count=${base:-0}）"
  [ "${pc0:-0}" -ge 2 ] && ok "基线时间分区数=$pc0" || fail "基线时间分区异常（${pc0:-0}）"

  # 2) 只对 d1 设 TTL，等待 TTL 清理触发整行分区误删
  local ttl_ms=$(( $(date +%s) - RN806B_T1 / 1000000000 ))
  TO "set ttl to root.$RN806B_DB.d1 $ttl_ms" >/dev/null 2>&1
  ok "已对 d1 设置 TTL=${ttl_ms}ms（其余设备不设）"
  echo "    等待 TTL 检查（约 40s）…"
  sleep 40
  local pc1; pc1=$(_rn806b_partcount_old)
  [ "${pc1:-0}" -lt "${pc0:-0}" ] && ok "已复现：时间分区被误删（$pc0 → $pc1）" || fail "未复现分区误删（$pc0 → ${pc1:-0}）"

  # 3) 数据升级到 RC3（保留 conf/data）
  if _rn806b_upgrade_inplace; then ok "已升级并恢复 8/8"; else fail "升级后集群未恢复 8/8"; fi
  local nv; nv=$(upg_version)
  [ "${nv:-}" = "ac7f95e" ] && ok "集群版本为 RC3（ac7f95e）" || fail "升级后版本异常（${nv:-空}）"

  # 4) 修复前：分区仍缺失，窄窗口查不到，但数据仍在（总数可见）
  local pcu narrow total
  pcu=$(_rn806b_partcount_show)
  [ "${pcu:-0}" -le 1 ] && ok "升级后分区仍缺失（show timepartition=$pcu，符合预期）" || fail "升级后分区已自行恢复（$pcu），无需修复"
  narrow=$(_rn806b_count d2 "where time >= $RN806B_T1 and time <= $RN806B_T1")
  total=$(_rn806b_count d2)
  [ "${narrow:-1}" = "0" ] && ok "修复前 d2 窄窗口查询为空（count=0，缺失分区现象）" || fail "修复前 d2 窄窗口竟可查（count=${narrow:-空}）"
  [ "${total:-0}" -ge 2 ] && ok "修复前 d2 数据仍在 DN（总数=$total）" || fail "修复前 d2 数据异常（总数=${total:-空}）"

  # 5) 手动修复
  local rep; rep=$(T "REPAIR DATA PARTITION TABLE")
  if echo "$rep" | grep -qi "success"; then
    ok "触发 REPAIR DATA PARTITION TABLE"
  elif echo "$rep" | grep -q "304"; then
    ok "修复程序已在运行（304 already submitted）"
  else
    fail "触发修复失败：$(echo "$rep" | head -1 | cut -c1-110)"
  fi

  local i done=0
  for i in $(seq 1 90); do
    pcu=$(_rn806b_partcount_show)
    [ "${pcu:-0}" -ge 2 ] && { done=1; break; }
    sleep 2
  done
  if [ "$done" = "1" ]; then ok "修复后时间分区恢复为 $pcu 个"; else fail "修复未恢复分区（show timepartition=${pcu:-空}）"; fi

  # 6) 修复后窄窗口数据可查
  for d in d2 d3 d4; do
    local c; c=$(_rn806b_count "$d" "where time >= $RN806B_T1 and time <= $RN806B_T1")
    [ "${c:-0}" = "1" ] && ok "修复后 $d 窄窗口数据可查（count=$c）" || fail "修复后 $d 窄窗口仍查不到（count=${c:-空}）"
  done
  local d1c; d1c=$(_rn806b_count d1 "where time >= $RN806B_T1 and time <= $RN806B_T1")
  [ "${d1c:-0}" = "0" ] && ok "d1 旧数据仍被 TTL 清理（符合预期，count=0）" || fail "d1 旧数据异常（count=${d1c:-空}）"

  Q "drop database if exists $RN806B_DB" >/dev/null 2>&1
}

CASES+=(
"RN-228|TDB-806 真正需要修复的分区场景|功能|2.0.6.1 上 TTL 误删时间分区 → 升级 RC3 → REPAIR 恢复分区与窄窗口数据|case_RN228"
)
