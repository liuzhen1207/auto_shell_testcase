#!/bin/bash
# ============================================================================
# 来源 ReleaseNote：TDB-125
#   标题：修复某个 DN 异常时，实际授权成功但是提示授权超时的问题
#   修复版本：V2.0.13.1（验证版本 2.0.13.1 / ab6d3de）
#   场景：某个 CN/DN 处于 unknown 状态时执行 GRANT 会提示"授权超时"，但权限实际已生效
#   修复后语义：DN 不可达 → 返回成功；DN 无响应 → 818 AUTH_OPERATE_EXCEPTION
#              「Auth plan has been committed, but DataNode permission cache invalidation failed」
# ============================================================================
# 修复后：授权 procedure 不再同步等待所有 DN 刷新缓存，DN 不可达时应快速成功。
# 关键判据：①返回成功（无 timeout/超时）②耗时 < 5 秒 ③权限确实生效 ④用户能读到数据

# 故障注入目标：选一个**非 SQL 连接主机**的 DN（否则 CLI 会连不上，测不出授权行为）
BAD_IP=""
for _ip in $DN_LIST; do
  [ "$_ip" = "$HOST" ] && continue
  BAD_IP=$_ip; break
done
[ -z "$BAD_IP" ] && { echo "  [SKIP] 没有可用的非 SQL 主机 DN"; return 0; }
RN_DB=root.rn125
RN_USER=rn125_u
RN_PW='Rn125@123456'

rn_setup() {
  local ip=$1
  start_dn $ip >/dev/null 2>&1
  wait_running 240 >/dev/null 2>&1 || true
  T "drop user $RN_USER" >/dev/null 2>&1
  T "drop database $RN_DB" >/dev/null 2>&1
  T "create database $RN_DB" >/dev/null 2>&1
  T "create timeseries $RN_DB.d1.s1 int32" >/dev/null 2>&1
  T "insert into $RN_DB.d1(time,s1) values(1,7)" >/dev/null 2>&1
  T "create user $RN_USER '$RN_PW'" >/dev/null 2>&1
}

rn_verify_grant() {  # $1=场景名 $2=注入方式
  local name=$1 mode=$2 out priv read
  echo "  故障注入: $mode on $BAD_IP"
  if [ "$mode" = "kill" ]; then
    ssh -o StrictHostKeyChecking=no root@$BAD_IP "pkill -9 -f 'com.timecho.iotdb.DataNode'" 2>/dev/null
    sleep 6
  else
    ssh -o StrictHostKeyChecking=no root@$BAD_IP "pkill -STOP -f 'com.timecho.iotdb.DataNode'" 2>/dev/null
    sleep 3
  fi

  out=$(run_timed "grant read on $RN_DB.** to user $RN_USER")
  echo "  GRANT 耗时 ${TIMED_MS}ms -> $(echo "$out" | head -1 | cut -c1-100)"
  assert_not_contains "$out" 'timeout'  "$name: 不应提示超时"
  assert_not_contains "$out" '超时'      "$name: 不应提示超时(中文)"
  # TDB-125 修复后的预期语义：
  #   DN 不可达（kill -9）→ 返回成功；
  #   DN 无响应（SIGSTOP）→ 允许返回 818 AUTH_OPERATE_EXCEPTION「Auth plan has been committed ...」，
  #   即“授权已提交、仅缓存失效失败”，这是明确的部分成功提示（不再是含糊的 timeout）。
  if echo "$out" | grep -q '818' && echo "$out" | grep -qi 'has been committed'; then
    ok "$name: 返回 818「授权已提交、缓存失效失败」——符合修复后语义"
  else
    assert_ok "$out" "$name: GRANT 应返回成功"
  fi
  if [ "$TIMED_MS" -lt 5000 ]; then ok "$name: 耗时 ${TIMED_MS}ms < 5s"; else fail "$name: 耗时 ${TIMED_MS}ms 超过 5s"; fi

  priv=$(T "list privileges of user $RN_USER" 2>&1 | tr '\n' ' ')
  assert_contains "$priv" 'READ_DATA' "$name: 权限应已生效"

  read=$(L "$RN_USER" "$RN_PW" "select s1 from $RN_DB.d1")
  assert_contains "$read" '7' "$name: 授权后应能读到数据"

  # 恢复
  if [ "$mode" = "stop" ]; then
    ssh -o StrictHostKeyChecking=no root@$BAD_IP "pkill -CONT -f 'com.timecho.iotdb.DataNode'" 2>/dev/null
    sleep 3
  fi
  start_dn $BAD_IP >/dev/null 2>&1
  wait_running 240 >/dev/null 2>&1 || true
}

case_RN001() {
  # 基线：DN 全部正常时授权成功（对照组）
  rn_setup "$BAD_IP"
  local out
  out=$(run_timed "grant read on $RN_DB.** to user $RN_USER")
  echo "  基线 GRANT 耗时 ${TIMED_MS}ms -> $(echo "$out" | head -1 | cut -c1-90)"
  assert_ok "$out" "基线：DN 正常时授权应成功"
  T "drop user $RN_USER" >/dev/null 2>&1
  T "drop database $RN_DB" >/dev/null 2>&1
}

case_RN002() {
  # TDB-125 主场景：kill -9 一台 DN（不可达）后授权
  rn_setup "$BAD_IP"
  rn_verify_grant "RN-002(kill -9)" "kill"
  T "drop user $RN_USER" >/dev/null 2>&1
  T "drop database $RN_DB" >/dev/null 2>&1
}

case_RN003() {
  # TDB-125 强化场景：SIGSTOP 一台 DN（进程活着但不响应，最接近 unknown 状态）
  rn_setup "$BAD_IP"
  rn_verify_grant "RN-003(SIGSTOP)" "stop"
  T "drop user $RN_USER" >/dev/null 2>&1
  T "drop database $RN_DB" >/dev/null 2>&1
}

CASES+=(
"RN-001|TDB-125 授权|正向|基线：DN 正常时 GRANT 成功|case_RN001"
"RN-002|TDB-125 授权|可靠性|kill -9 一台 DN 后 GRANT 不超时且权限生效|case_RN002"
"RN-003|TDB-125 授权|可靠性|SIGSTOP 一台 DN（无响应）后 GRANT 不超时且权限生效|case_RN003"
)
