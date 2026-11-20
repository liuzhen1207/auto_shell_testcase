#!/bin/bash
# ============================================================================
# 来源工作项：TDB-1242
#   【2.0.9.1 RC1】开审计日志，数据升级后并发写入新数据，DN 空指针：
#     Cannot invoke "org.apache.iotdb.db.protocol.session.IClientSession.addStatementId(long)"
#     because "<parameter1>" is null
#
#   场景：旧集群开启审计日志 + 有数据 → 数据升级（整体替换二进制）→
#         升级后并发写入新数据（树/表），校验 DN 无 addStatementId NPE、审计正常记录、数据完整。
#
#   升级路径：2.0.12.1 RC12 (c05111d) → 2.0.13.1 RC3 (ac7f95e)
#   前置：集群当前为纯 RC12（由 tools/force_align_build.sh + hard_reset 保证）
# ============================================================================
RN1242_TREE_DB=rn1242_tree
RN1242_TABLE_DB=rn1242_table
RN1242_AUDIT_DB=__audit

# 在所有节点开启审计（写 conf，随后的重启/升级生效）
_rn1242_enable_audit() {
  local ip dir cmd
  for ip in $CN_LIST; do
    dir="$UPG_CN_DIR/$UPG_OLD"
    ssh -n -o StrictHostKeyChecking=no root@$ip "
      f='$dir/conf/iotdb-system.properties'
      if grep -q '^enable_audit_log=' \"\$f\" 2>/dev/null; then
        sed -i 's/^enable_audit_log=.*/enable_audit_log=true/' \"\$f\"
      else
        echo 'enable_audit_log=true' >> \"\$f\"
      fi
      grep '^enable_audit_log=' \"\$f\"
    " 2>/dev/null | sed "s/^/  CN $ip /"
  done
  for ip in $DN_LIST; do
    dir="$UPG_DN_DIR/$UPG_OLD"
    ssh -n -o StrictHostKeyChecking=no root@$ip "
      f='$dir/conf/iotdb-system.properties'
      if grep -q '^enable_audit_log=' \"\$f\" 2>/dev/null; then
        sed -i 's/^enable_audit_log=.*/enable_audit_log=true/' \"\$f\"
      else
        echo 'enable_audit_log=true' >> \"\$f\"
      fi
      grep '^enable_audit_log=' \"\$f\"
    " 2>/dev/null | sed "s/^/  DN $ip /"
  done
}

_rn1242_restart_all() {
  local ip
  for ip in $CN_LIST; do upg_stop_node "$ip" cn >/dev/null 2>&1; done
  for ip in $DN_LIST; do upg_stop_node "$ip" dn >/dev/null 2>&1; done
  for ip in $CN_LIST; do upg_start_node "$ip" cn "$UPG_CN_DIR/$UPG_OLD" >/dev/null 2>&1; done
  sleep 10
  for ip in $DN_LIST; do upg_start_node "$ip" dn "$UPG_DN_DIR/$UPG_OLD" >/dev/null 2>&1; done
  upg_wait_running 600
}

_rn1242_audit_rows() {
  Q "select count(*) from $RN1242_AUDIT_DB.audit_log" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9'
}

# 并发写入：6 个写手，树 + 表各若干
_rn1242_concurrent_write() {
  local wdir=$1 seconds=${2:-30} i
  rm -rf "$wdir"; mkdir -p "$wdir"
  for i in 1 2 3 4 5 6; do
    (
      local n=0 ts out
      local end=$(( $(date +%s) + seconds ))
      while [ "$(date +%s)" -lt "$end" ]; do
        n=$((n+1))
        ts=$(( $(date +%s) * 1000 + i * 1000 + n ))
        out=$(T "insert into root.$RN1242_TREE_DB.d$i(time,s1) values($ts, $i.5)" 2>&1)
        echo "$out" | grep -qi "success" && echo ok >> "$wdir/tree_ok_$i" || echo "$out" >> "$wdir/tree_err_$i"
        out=$(Q "insert into $RN1242_TABLE_DB.t1(time, dev, val) values($ts, 'd$i', $i.5)" 2>&1)
        echo "$out" | grep -qi "success" && echo ok >> "$wdir/table_ok_$i" || echo "$out" >> "$wdir/table_err_$i"
        sleep 0.2
      done
    ) &
  done
  wait
}

case_RN222() {
  echo "  --- TDB-1242 开审计 + 数据升级后并发写入（DN NPE 检查）---"
  if ! _upg_is_old; then
    fail "当前集群不是 RC12（BuildInfo=$(upg_version)），无法执行该用例"
    return
  fi
  ok "当前为旧版本 RC12（BuildInfo=c05111d）"

  # 1) 开启审计并重启（旧版本生效）
  _rn1242_enable_audit
  if _rn1242_restart_all; then ok "开启审计后集群 8/8"; else fail "开启审计后集群未恢复 8/8"; fi

  # 2) 旧集群造数，确认审计已记录
  Q "drop database if exists $RN1242_TREE_DB" >/dev/null 2>&1
  Q "drop database if exists $RN1242_TABLE_DB" >/dev/null 2>&1
  Q "create database $RN1242_TREE_DB" >/dev/null 2>&1
  Q "create database $RN1242_TABLE_DB" >/dev/null 2>&1
  T "create timeseries root.$RN1242_TREE_DB.d0.s1 double" >/dev/null 2>&1
  T "insert into root.$RN1242_TREE_DB.d0(time,s1) values(1,1.0),(2,2.0)" >/dev/null 2>&1
  Q "create table $RN1242_TABLE_DB.t1 (time TIMESTAMP TIME, dev STRING TAG, val DOUBLE FIELD)" >/dev/null 2>&1
  Q "insert into $RN1242_TABLE_DB.t1(time, dev, val) values(1, 'd0', 1.0)" >/dev/null 2>&1
  sleep 5
  local a0; a0=$(_rn1242_audit_rows)
  [ "${a0:-0}" -ge 1 ] && ok "升级前审计日志已记录（audit_log=$a0）" || fail "升级前未见审计记录（audit_log=${a0:-空}）"

  # 3) 数据升级：整体替换二进制
  local ip
  for ip in $CN_LIST; do upg_stop_node "$ip" cn >/dev/null 2>&1; done
  for ip in $DN_LIST; do upg_stop_node "$ip" dn >/dev/null 2>&1; done
  for ip in $CN_LIST; do upg_swap_build "$ip" cn "$UPG_OLD" "$UPG_RC3" >/dev/null 2>&1; done
  for ip in $DN_LIST; do upg_swap_build "$ip" dn "$UPG_OLD" "$UPG_RC3" >/dev/null 2>&1; done
  ok "8 节点已替换为 RC3 二进制"
  for ip in $CN_LIST; do upg_start_node "$ip" cn "$UPG_CN_DIR/$UPG_OLD" >/dev/null 2>&1; done
  sleep 10
  for ip in $DN_LIST; do upg_start_node "$ip" dn "$UPG_DN_DIR/$UPG_OLD" >/dev/null 2>&1; done
  if upg_wait_running 600; then ok "升级后集群 8/8"; else fail "升级后集群未恢复 8/8"; fi
  local v; v=$(upg_version)
  [ "${v:-}" = "ac7f95e" ] && ok "版本已升级为 RC3（ac7f95e）" || fail "版本异常（${v:-空}）"

  # 4) 升级后：旧数据可查
  local tc; tc=$(T "select count(s1) from root.$RN1242_TREE_DB.d0" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${tc:-0}" -ge 2 ] && ok "旧树数据可查（count=$tc）" || fail "旧树数据异常（count=${tc:-空}）"

  # 5) 并发写入新数据（审计开启 + 升级后）
  local wdir=/tmp/rn1242_wl
  _rn1242_concurrent_write "$wdir" 30
  local tok tek bok bek
  tok=$(cat "$wdir"/tree_ok_* 2>/dev/null | wc -l)
  tek=$(cat "$wdir"/tree_err_* 2>/dev/null | wc -l)
  bok=$(cat "$wdir"/table_ok_* 2>/dev/null | wc -l)
  bek=$(cat "$wdir"/table_err_* 2>/dev/null | wc -l)
  echo "    并发写入：tree_ok=$tok tree_err=$tek table_ok=$bok table_err=$bek"
  [ "${tok:-0}" -gt 0 ] && [ "${bok:-0}" -gt 0 ] && ok "并发写入有成功记录（tree=$tok table=$bok）" || fail "并发写入全部失败"
  [ "${tek:-0}" -eq 0 ] && ok "并发树写入无失败" || fail "并发树写入失败 $tek 条"
  [ "${bek:-0}" -eq 0 ] && ok "并发表写入无失败" || fail "并发表写入失败 $bek 条"

  # 6) 审计在升级后仍工作
  sleep 3
  local a1; a1=$(_rn1242_audit_rows)
  [ "${a1:-0}" -gt "${a0:-0}" ] && ok "升级后审计仍在记录（audit_log $a0 → $a1）" || fail "升级后审计未增长（audit_log ${a0:-?} → ${a1:-?}）"

  # 7) 关键：DN 错误日志无 addStatementId NPE
  local bad=0 n
  for ip in $DN_LIST; do
    n=$(ssh -n -o StrictHostKeyChecking=no root@$ip "grep -c 'addStatementId' $UPG_DN_DIR/$UPG_OLD/logs/log_datanode_error.log 2>/dev/null | head -1" 2>/dev/null | tr -dc '0-9')
    [ -z "${n:-}" ] && n=0
    [ "$n" -gt 0 ] && { bad=$((bad + n)); echo "    [debug] DN $ip 命中 addStatementId $n 条"; }
  done
  [ "$bad" -eq 0 ] && ok "DN 错误日志无 addStatementId NPE（TDB-1242 现象未复现）" || fail "DN 错误日志出现 $bad 条 addStatementId NPE（TDB-1242 现象）"

  # 8) 数据完整性抽查（逐设备 count，避免 ** 聚合口径歧义）
  local sum=0 c k
  for k in 0 1 2 3 4 5 6; do
    c=$(T "select count(s1) from root.$RN1242_TREE_DB.d$k" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
    [ -n "${c:-}" ] && sum=$((sum + c))
  done
  [ "${sum:-0}" -ge 2 ] && ok "升级+并发写入后树数据可查（逐设备合计 count=$sum）" || fail "树数据异常（逐设备合计 count=${sum:-0}）"

  Q "drop database if exists $RN1242_TREE_DB" >/dev/null 2>&1
  Q "drop database if exists $RN1242_TABLE_DB" >/dev/null 2>&1
}

CASES+=(
"RN-222|TDB-1242 开审计+数据升级后并发写入|升级|开审计并数据升级后并发写入：DN 无 addStatementId NPE，审计持续记录，数据完整|case_RN222"
)
