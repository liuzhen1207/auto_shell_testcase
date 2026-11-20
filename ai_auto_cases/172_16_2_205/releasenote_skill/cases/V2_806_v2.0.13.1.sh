#!/bin/bash
# ============================================================================
# 来源工作项：TDB-806（V2-423）使用 SQL 手动修复分区表功能
#   语法（Tree 方言）：
#     REPAIR DATA PARTITION TABLE
#     SHOW REPAIR DATA PARTITION TABLE PROGRESS   → Status / Progress(%) / Message
#   行为：触发前 IDLE / 0%；触发后进度递增至 100%；重复触发幂等；需 SYSTEM 权限；
#         Table 方言应拒绝该语句。
#   参考：测试记录 docs/708（2.0.11.1 RC5，62 项，58 PASS）
#   验证版本：2.0.13.1 RC3 / ac7f95e
# ============================================================================
RN806_TREE_DB=rn806_tree
RN806_TABLE_DB=rn806_tab

# 返回 "STATUS PROGRESS"
_rn806_progress() {
  T "SHOW REPAIR DATA PARTITION TABLE PROGRESS" 2>&1 \
    | awk -F'|' '{s=$2; p=$3; gsub(/ /,"",s); gsub(/ /,"",p); if (s ~ /^[A-Z_]+$/ && p ~ /^[0-9]+(\.[0-9]+)?$/) {print s" "p; exit}}'
}

# 触发修复并等待过程结束：
#   健康集群（无缺失分区）时 procedure 会立即结束（进度保持 IDLE/0），
#   因此以 CN 日志出现 procedure 结束标志或进度=100 作为完成判据。
_rn806_repair_and_wait() {  # $1=标签 $2=超时秒数
  local tag=$1 want=${2:-120} i st prog off newlines
  off=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.26 "wc -l < $UPG_CN_DIR/${UPG_RC3}/logs/log_confignode_all.log 2>/dev/null || echo 0" 2>/dev/null | tr -dc '0-9')
  [ -z "${off:-}" ] && off=0
  assert_ok "$(T "REPAIR DATA PARTITION TABLE")" "$tag 触发 REPAIR DATA PARTITION TABLE"
  for i in $(seq 1 $((want / 2))); do
    st=$(_rn806_progress)
    prog=${st#* }
    if [ -n "${prog:-}" ] && awk -v p="$prog" 'BEGIN{exit !(p+0 >= 100)}'; then
      ok "$tag 修复进度达到 100%（$st）"
      return 0
    fi
    newlines=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.26 "tail -n +$((off + 1)) $UPG_CN_DIR/${UPG_RC3}/logs/log_confignode_all.log 2>/dev/null | grep -cE 'terminating procedure|No databases have lost|repair.*finish|Repair.*complete'" 2>/dev/null | tr -dc '0-9')
    if [ "${newlines:-0}" -ge 1 ]; then
      ok "$tag 修复过程已结束（无缺失分区时进度保持 IDLE/0；$st）"
      return 0
    fi
    sleep 2
  done
  fail "$tag 修复未在 ${want}s 内结束（当前 ${st:-空}）"
  return 1
}

_rn806_seed() {
  Q "drop database if exists $RN806_TREE_DB" >/dev/null 2>&1
  Q "drop database if exists $RN806_TABLE_DB" >/dev/null 2>&1
  Q "create database $RN806_TREE_DB" >/dev/null 2>&1
  Q "create database $RN806_TABLE_DB" >/dev/null 2>&1
  T "create timeseries root.$RN806_TREE_DB.d1.s1 double" >/dev/null 2>&1
  T "create timeseries root.$RN806_TREE_DB.d2.s1 double" >/dev/null 2>&1
  T "insert into root.$RN806_TREE_DB.d1(time,s1) values(1,1.5),(2,2.5),(3,3.5)" >/dev/null 2>&1
  T "insert into root.$RN806_TREE_DB.d2(time,s1) values(1,1.5),(2,2.5)" >/dev/null 2>&1
  Q "create table $RN806_TABLE_DB.t1 (time TIMESTAMP TIME, dev STRING TAG, val DOUBLE FIELD)" >/dev/null 2>&1
  Q "insert into $RN806_TABLE_DB.t1(time, dev, val) values(1,'d1',1.5)" >/dev/null 2>&1
  Q "insert into $RN806_TABLE_DB.t1(time, dev, val) values(2,'d1',2.5)" >/dev/null 2>&1
  T "flush" >/dev/null 2>&1
  sleep 2
}

_rn806_verify_data() {
  local tag=$1 tc bc
  tc=$(T "select count(s1) from root.$RN806_TREE_DB.**" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  bc=$(Q "select count(*) from $RN806_TABLE_DB.t1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${tc:-0}" -ge 5 ] && ok "$tag 树数据完整（count=$tc）" || fail "$tag 树数据异常（count=${tc:-空}）"
  [ "${bc:-0}" -ge 2 ] && ok "$tag 表数据完整（count=$bc）" || fail "$tag 表数据异常（count=${bc:-空}）"
}

# ---------------------------------------------------------------- RN-223 基础修复 + 进度
case_RN223() {
  echo "  --- 基础：REPAIR DATA PARTITION TABLE + 进度查询 ---"
  if [ "$(T "show cluster" 2>/dev/null | grep -c Running)" -lt 8 ]; then fail "集群未达 8/8，跳过修复测试"; return; fi
  _rn806_seed
  local st; st=$(_rn806_progress)
  [ "${st%% *}" = "IDLE" ] && ok "触发前状态 IDLE（${st}）" || fail "触发前状态异常（${st:-空}）"
  if awk -v p="${st#* }" 'BEGIN{exit !(p+0 == 0)}'; then ok "触发前进度 0%（${st}）"; else fail "触发前进度异常（${st:-空}）"; fi

  _rn806_repair_and_wait "[基础]" 120
  _rn806_verify_data "[修复后]"
  Q "drop database if exists $RN806_TREE_DB" >/dev/null 2>&1
  Q "drop database if exists $RN806_TABLE_DB" >/dev/null 2>&1
}

# ---------------------------------------------------------------- RN-224 幂等/重复触发
case_RN224() {
  echo "  --- 幂等：连续触发两次修复，数据不丢 ---"
  _rn806_seed
  _rn806_repair_and_wait "[第一次]" 120
  _rn806_repair_and_wait "[第二次/幂等]" 120
  _rn806_verify_data "[两次修复后]"
  Q "drop database if exists $RN806_TREE_DB" >/dev/null 2>&1
  Q "drop database if exists $RN806_TABLE_DB" >/dev/null 2>&1
}

# ---------------------------------------------------------------- RN-225 权限
case_RN225() {
  echo "  --- 权限：无 SYSTEM 被拒、授予 SYSTEM 后允许 ---"
  _rn806_seed
  local U=rn806_u PW='Rn806@123456'
  T "drop user $U" >/dev/null 2>&1
  # root 账号若已被锁定（822）或认证失败（801），不再重试（避免继续累计失败把账号锁得更久）
  local rootchk create_out
  rootchk=$(T "list user" 2>&1)
  if echo "$rootchk" | grep -qE "822|blocked|801"; then
    fail "root 账号当前不可用（$(echo "$rootchk" | head -1 | cut -c1-100)），跳过权限用例（需重启集群解锁）"
    return
  fi
  create_out=$(T "create user $U '$PW'")
  if echo "$create_out" | grep -qi "success"; then
    ok "创建普通用户 $U"
  else
    fail "创建普通用户 $U 失败：$(echo "$create_out" | head -1 | cut -c1-120)（不再重试，避免账号锁定）"
    return
  fi
  # 先确认该用户能正常登录，避免反复失败登录把账号锁住（822）
  local login; login=$(L "$U" "$PW" "show cluster" 2>&1)
  if echo "$login" | grep -qiE "822|blocked|803|Exception"; then
    fail "普通用户登录失败（$(echo "$login" | head -1 | cut -c1-100)），跳过权限用例"
    T "drop user $U" >/dev/null 2>&1
    return
  fi
  ok "普通用户可正常登录"
  local out; out=$(L "$U" "$PW" "REPAIR DATA PARTITION TABLE" 2>&1)
  if echo "$out" | grep -qE "803|No permissions|permission"; then
    ok "无 SYSTEM 权限执行修复被拒绝（$(echo "$out" | head -1 | cut -c1-80)）"
  else
    fail "无权限用户竟然可以执行修复：$(echo "$out" | head -1 | cut -c1-100)"
  fi
  assert_ok "$(T "grant system on root.** to user $U")" "授予 SYSTEM 权限"
  local out2; out2=$(L "$U" "$PW" "REPAIR DATA PARTITION TABLE" 2>&1)
  if echo "$out2" | grep -qiE "Exception|ERROR"; then
    fail "有 SYSTEM 权限执行修复失败：$(echo "$out2" | head -1 | cut -c1-100)"
  else
    ok "有 SYSTEM 权限执行修复成功"
  fi
  _rn806_repair_and_wait "[有权限]" 120
  T "drop user $U" >/dev/null 2>&1
  Q "drop database if exists $RN806_TREE_DB" >/dev/null 2>&1
  Q "drop database if exists $RN806_TABLE_DB" >/dev/null 2>&1
}

# ---------------------------------------------------------------- RN-226 方言与语法
case_RN226() {
  echo "  --- 方言/语法：Table 方言拒绝、非法 SQL 报错 ---"
  assert_err "$(Q "REPAIR DATA PARTITION TABLE")" "700" "Table 方言拒绝 REPAIR DATA PARTITION TABLE"
  assert_err "$(Q "SHOW REPAIR DATA PARTITION TABLE PROGRESS")" "700" "Table 方言拒绝进度查询语句"
  assert_err "$(T "REPAIR DATA PARTITION TABLES")" "700" "Tree 方言非法表名（TABLES）报语法错误"
  assert_err "$(T "REPAIR DATA PARTITION")" "700" "Tree 方言缺少 TABLE 报语法错误"
}

# ---------------------------------------------------------------- RN-227 worker 参数
case_RN227() {
  echo "  --- 参数：partition_table_recover_worker_num=4 下修复正常 ---"
  _rn806_seed
  assert_ok "$(T "set configuration 'partition_table_recover_worker_num'='4'")" "设置 worker_num=4"
  sleep 3
  _rn806_repair_and_wait "[参数场景]" 120
  _rn806_verify_data "[参数场景]"
  T "set configuration 'partition_table_recover_worker_num'='10'" >/dev/null 2>&1
  Q "drop database if exists $RN806_TREE_DB" >/dev/null 2>&1
  Q "drop database if exists $RN806_TABLE_DB" >/dev/null 2>&1
}

CASES+=(
"RN-223|TDB-806 手动修复分区表基础|功能|REPAIR DATA PARTITION TABLE 触发成功，进度 IDLE/0% → 100%，修复后数据完整|case_RN223"
"RN-224|TDB-806 修复幂等/重复触发|功能|连续两次触发修复均成功且数据不丢|case_RN224"
"RN-225|TDB-806 修复权限控制|异常|无 SYSTEM 权限被拒（803），授予后可执行并完成|case_RN225"
"RN-226|TDB-806 修复 SQL 方言与语法|异常|Table 方言拒绝修复/进度语句；Tree 方言非法语法报 700|case_RN226"
"RN-227|TDB-806 修复 worker 参数|功能|partition_table_recover_worker_num=4 时修复正常完成且数据完整|case_RN227"
)
