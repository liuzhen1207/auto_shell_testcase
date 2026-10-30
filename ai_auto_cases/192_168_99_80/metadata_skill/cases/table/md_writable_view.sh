#!/bin/bash
# ============================================================================
# MD-B05 表模型「可写视图」元数据闭环 + 并发 ALTER 的缓存一致性（TDB-615）
#
# 需求依据：可写视图需求文档（PingCode RD/ER9exuuY）
#   CREATE WRITABLE VIEW <v> AS SELECT (<col> [as <alias>] ...) FROM <table> [WITH (schema_cascade=true|false)];
#   INSERT/UPDATE/DELETE 通过视图自动映射到底表；普通视图不支持 INSERT INTO VIEW。
#   ALTER VIEW <v> {ADD COLUMN | RENAME COLUMN | DROP COLUMN | RENAME TO | SET PROPERTIES}
#
# TDB-615（P1，迭代 V2.0.13.1）：getTableSchema 先取视图对象、再读缓存版本；DDL 恰好落在
#   两步之间时旧对象可能被缓存成新版本 ⇒ 后续查询**持续**看到旧列名/旧映射。
#   本用例用「并发 ALTER + DDL 收尾后连续读」把它钉住：
#     · 竞态窗口：ALTER 与 DESC/SELECT 并发；
#     · 判据：收尾后连续 20 次列集读必须完全一致且不含临时列，且视图列→底表列的映射按最新定义生效。
#
# 版本：v20131rc1_1030_ab6d3de（2.0.13.1 RC1）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

TDB="${MD_PREFIX}_b05"
md_case_init "md_writable_view"
md_cluster_prepare

# $1 = 视图名；优先 DESC，DESC 不支持视图时退回 SHOW CREATE VIEW 的 select 列表
vw_cols(){
  local v=$1 d c
  d=$(sqt "DESC $v;" 2>/dev/null | awk -F'|' 'NF>=3 {gsub(/^[ \t]+|[ \t]+$/,"",$2); if ($2!="") print $2}' | sort | tr '\n' ',')
  if [ -n "$(printf '%s' "$d" | tr -d ',')" ]; then printf '%s' "$d"; return; fi
  c=$(sqt "SHOW CREATE VIEW $v;" 2>/dev/null | sed -n 's/.*SELECT \(.*\) FROM .*/\1/p' | head -1)
  printf '%s' "$c" | tr ',' '\n' | sed 's/^[ \t]*//; s/[ \t]*$//; s/.* as //I' | sort | tr '\n' ','
}
drop_all(){
  sqt "DROP VIEW IF EXISTS $TDB.wv;"  >/dev/null 2>&1
  sqt "DROP VIEW IF EXISTS $TDB.wv2;" >/dev/null 2>&1
  sqt "DROP VIEW IF EXISTS $TDB.nv;"  >/dev/null 2>&1
  sqt "DROP DATABASE IF EXISTS $TDB;" >/dev/null 2>&1
}

log "--- 清理 + 建基表 ---"
drop_all
assert_ok "建库" "$(sqt "CREATE DATABASE $TDB;")"
assert_ok "建基表 t1(time, dev TAG, v1, v2, v3)" \
  "$(sqt "CREATE TABLE $TDB.t1 (time TIMESTAMP TIME, dev STRING TAG, v1 INT32 FIELD, v2 INT32 FIELD, v3 INT32 FIELD);")"
assert_ok "写入 2 行" "$(sqt "INSERT INTO $TDB.t1 (time, dev, v1, v2, v3) VALUES (1000,'d1',1,2,3),(2000,'d1',10,20,30);")"
base_cnt(){ md_rows "$(sqt "SELECT count(*) AS c FROM $TDB.t1;")" | head -1 | tr -dc '0-9'; }

# ---------------------------------------------------------------------------
log "=== 1) 建可写视图 + 元数据观测 ==="
assert_ok "CREATE WRITABLE VIEW wv（dev, v1→voltage, v2）" \
  "$(sqt "CREATE WRITABLE VIEW $TDB.wv AS SELECT dev, v1 AS voltage, v2, v3 FROM $TDB.t1;")"
scv=$(sqt "SHOW CREATE VIEW $TDB.wv;")
assert_contains "SHOW CREATE VIEW 含 WRITABLE" "$scv" 'WRITABLE'
assert_contains "SHOW CREATE VIEW 含别名 voltage" "$scv" 'voltage'
c_wv=$(vw_cols "$TDB.wv")
log "  wv 列集：$c_wv"
assert_contains "视图列集含视图列 voltage" "$c_wv" 'voltage'

# ---------------------------------------------------------------------------
log "=== 2) 通过可写视图做 DML（映射到底表）==="
n0=$(base_cnt)
assert_ok "视图 INSERT 一行（voltage=777）" \
  "$(sqt "INSERT INTO $TDB.wv (time, dev, voltage, v2) VALUES (3000,'d2',777,888);")"
assert_eq "底表行数 +1" "$(base_cnt)" "$(( ${n0:-0} + 1 ))"
got=$(md_rows "$(sqt "SELECT v1, v2 FROM $TDB.t1 WHERE time=3000;")")
assert_contains "视图写的 voltage 落到源列 v1" "$got" '777'
assert_contains "视图写的 v2 落到源列 v2" "$got" '888'
# 表模型 UPDATE 只允许 ATTRIBUTE 列（IoTDB 既有语义，视图继承）⇒ 更新 FIELD 必须被拒
assert_error "视图 UPDATE FIELD 列被拒（701，表模型 UPDATE 仅支持 ATTRIBUTE 列）" \
  "$(sqt "UPDATE $TDB.wv SET voltage=999 WHERE dev='d2';")" '(701|ATTRIBUTE)'
assert_ok "视图 DELETE 一行（WHERE 用 tag 列 dev）" "$(sqt "DELETE FROM $TDB.wv WHERE dev='d2';")"
assert_eq "DELETE 后底表行数回到原值" "$(base_cnt)" "${n0:-0}"

# ---------------------------------------------------------------------------
log "=== 3) 对照：普通视图不允许 INSERT INTO VIEW ==="
assert_ok "建普通视图 nv" "$(sqt "CREATE VIEW $TDB.nv AS SELECT v2 FROM $TDB.t1;")"
bad=$(sqt "INSERT INTO $TDB.nv (time, dev, v2) VALUES (4000,'d3',1);")
if printf '%s' "$bad" | grep -qiE 'error|exception|not support|不支持|70[01]|507'; then
  pass "普通视图 INSERT 被拒：$(printf '%s' "$bad" | tr '\n' ' ' | cut -c1-140)"
else
  fail "普通视图 INSERT 未被拒（应报错）：$(printf '%s' "$bad" | tr '\n' ' ' | cut -c1-160)"
fi

# ---------------------------------------------------------------------------
log "=== 4) schema_cascade 语义（底表加列后视图是否跟随）==="
assert_ok "建带 schema_cascade=true 的可写视图 wv2（SELECT *）" \
  "$(sqt "CREATE WRITABLE VIEW $TDB.wv2 AS SELECT * FROM $TDB.t1 WITH (schema_cascade=true);")"
pre=$(vw_cols "$TDB.wv2")
log "  底表加列前列集：$pre"
assert_ok "底表 ADD COLUMN v4" "$(sqt "ALTER TABLE $TDB.t1 ADD COLUMN IF NOT EXISTS v4 INT32 FIELD;")"
post=$(vw_cols "$TDB.wv2")
log "  底表加列后列集：$post"
if [ "$pre" = "$post" ]; then
  warn "schema_cascade=true 时底表加列后视图列集未变化（$post）—— 需与需求文档核对是否为预期"
else
  pass "schema_cascade=true：底表加列后视图列集变化（$pre → $post）"
fi

# ---------------------------------------------------------------------------
log "=== 5) TDB-615：并发 ALTER 与查询，收尾后不得残留旧列名 ==="
ROUNDS=${MD615_ROUNDS:-12}
DONE=/tmp/${TDB}_alter.done
SEQ=/tmp/${TDB}_desc_seq.txt
rm -f "$DONE" "$SEQ"
(
  k=1
  while [ "$k" -le "$ROUNDS" ]; do
    sqt "ALTER VIEW $TDB.wv2 ADD COLUMN IF NOT EXISTS c$k INT32 FIELD;" >/dev/null 2>&1
    sqt "ALTER VIEW $TDB.wv2 DROP COLUMN c$k;" >/dev/null 2>&1
    k=$(( k + 1 ))
  done
  : >"$DONE"
) &
A_PID=$!
(
  b=1
  while [ ! -f "$DONE" ] && [ "$b" -le 400 ]; do
    sqt "DESC $TDB.wv2;" >/dev/null 2>&1
    sqt "SELECT count(*) FROM $TDB.wv2;" >/dev/null 2>&1
    b=$(( b + 1 ))
  done
) &
B_PID=$!
wait "$A_PID" 2>/dev/null
wait "$B_PID" 2>/dev/null
log "  并发结束（ALTER ${ROUNDS} 轮 + 并发读）"

expect=$(vw_cols "$TDB.wv2")
log "  期望列集：$expect"
stale=0; i=1
while [ "$i" -le 20 ]; do
  cur=$(vw_cols "$TDB.wv2")
  [ "$cur" != "$expect" ] && { stale=$(( stale + 1 )); log "    !! 第 $i 次读与期望不一致：$cur"; }
  printf '%s\n' "$cur" >>"$SEQ"
  i=$(( i + 1 ))
done
assert_eq "DDL 收尾后 20 次连读列集不漂移（TDB-615 核心判据）" "${stale:-0}" "0"
assert_not_contains "列集不残留并发临时列 c1..cN" "$expect" 'c[0-9]+'

log "  -- 映射一致性：独立视图 wv3 用别名 mapped 映射底表 v3，写唯一值回读 --"
assert_ok "建可写视图 wv3（dev, v3 AS mapped）" \
  "$(sqt "CREATE WRITABLE VIEW $TDB.wv3 AS SELECT dev, v3 AS mapped FROM $TDB.t1;")"
assert_ok "通过视图写 mapped=424242" \
  "$(sqt "INSERT INTO $TDB.wv3 (time, dev, mapped) VALUES (5000,'d9',424242);")"
mv=$(md_rows "$(sqt "SELECT v3 FROM $TDB.t1 WHERE time=5000;")")
if printf '%s' "$mv" | grep -q '424242'; then
  pass "视图列 mapped 映射到底表 v3（写 424242 读回：$mv）"
else
  fail "视图列 mapped 映射错误：底表 v3 读到 [$mv]（期望 424242）"
fi

# ---------------------------------------------------------------------------
log "=== 6) 失败路径 ==="
assert_error "ALTER 不存在的视图报错" "$(sqt "ALTER VIEW $TDB.wv_none ADD COLUMN x INT32 FIELD;")" '(701|500|550|not exist|does not exist)'
assert_error "DROP COLUMN 不存在的列报错" "$(sqt "ALTER VIEW $TDB.wv DROP COLUMN nope;")" '(701|500|550|not exist|Unknown|unknown)'

# ---------------------------------------------------------------------------
log "=== 8) ALTER VIEW：RENAME COLUMN / SET PROPERTIES ==="
assert_ok "视图 RENAME COLUMN voltage → volt2" "$(sqt "ALTER VIEW $TDB.wv RENAME COLUMN voltage TO volt2;")"
c_after=$(vw_cols "$TDB.wv")
assert_contains "重命名后列集出现 volt2" "$c_after" 'volt2'
assert_not_contains "重命名后列集不再有 voltage" "$c_after" 'voltage'
sel2=$(sqt "SELECT volt2 FROM $TDB.wv WHERE dev='d1';")
if printf '%s' "$sel2" | grep -qE '^\|[[:space:]]*[0-9]+'; then
  pass "重命名后可查询新列名（$sel2 已返回数据行）"
else
  fail "重命名后用新列名查询异常：$(printf '%s' "$sel2" | tr '\n' ' ' | cut -c1-140)"
fi

log "=== 9) 基表删掉被视图引用的列 → 必须明确报错 ==="
# wv 引用了 v3；直接删底表 v3，视图查询/写入都应该给明确错误而不是静默返回空
d=$(sqt "DROP TABLE IF EXISTS $TDB.t_tmp;" >/dev/null 2>&1; true)
out_drop=$(sqt "ALTER TABLE $TDB.t1 DROP COLUMN v3;")
if printf '%s' "$out_drop" | grep -qiE 'error|exception|view|referenced|70[01]'; then
  pass "底表删被引用列被拒/报错：$(printf '%s' "$out_drop" | tr '\n' ' ' | cut -c1-120)"
else
  q=$(sqt "SELECT * FROM $TDB.wv WHERE dev='d1';")
  if printf '%s' "$q" | grep -qiE 'error|exception|not exist|70[01]'; then
    pass "底表删列成功，但视图查询给出明确错误：$(printf '%s' "$q" | tr '\n' ' ' | cut -c1-120)"
  else
    warn "底表删掉被视图引用的列后，视图查询仍返回结果（需确认语义）：$(printf '%s' "$q" | tr '\n' ' ' | cut -c1-100)"
  fi
fi

log "=== 10) 普通视图 INSERT 的第二种写法（不带列清单）==="
bad2=$(sqt "INSERT INTO $TDB.nv VALUES (5000,'d9',1);")
if printf '%s' "$bad2" | grep -qiE 'error|exception|not support|70[01]|507'; then
  pass "普通视图 INSERT（无列清单）被拒：$(printf '%s' "$bad2" | tr '\n' ' ' | cut -c1-120)"
else
  fail "普通视图 INSERT（无列清单）未被拒：$(printf '%s' "$bad2" | tr '\n' ' ' | cut -c1-140)"
fi

log "=== 11) 权限：只 READ 的用户不能通过视图写 ==="
U="u_b05_${RANDOM}"
sqt "CREATE USER $U 'Passw0rd_b05!';" >/dev/null 2>&1
sqt "GRANT READ ON DATABASE $TDB TO USER $U;" >/dev/null 2>&1
rd=$(sqt_as "$U" 'Passw0rd_b05!' "SELECT count(*) FROM $TDB.wv;")
wr=$(sqt_as "$U" 'Passw0rd_b05!' "INSERT INTO $TDB.wv (time, dev, volt2, v2) VALUES (6000,'dk',1,2);")
if printf '%s' "$wr" | grep -qiE '803|no permission|permission denied'; then
  pass "只有 READ 时通过视图写被拒（803）：$(printf '%s' "$wr" | tr '\n' ' ' | cut -c1-100)"
else
  fail "只有 READ 时通过视图写未被拒：$(printf '%s' "$wr" | tr '\n' ' ' | cut -c1-140)"
fi
sqt "DROP USER $U;" >/dev/null 2>&1

log "=== 12) 视图 DROP 后重建：缓存必须失效（新定义立即生效）==="
assert_ok "DROP 旧 wv" "$(sqt "DROP VIEW $TDB.wv;")"
assert_ok "以不同列集重建 wv（只 v1→v9）" \
  "$(sqt "CREATE WRITABLE VIEW $TDB.wv AS SELECT v1 AS v9 FROM $TDB.t1;")"
c_re=$(vw_cols "$TDB.wv")
assert_contains "重建后列集包含新列 v9" "$c_re" 'v9'
assert_not_contains "重建后列集不残留旧列 volt2" "$c_re" 'volt2'
q_re=$(sqt "SELECT v9 FROM $TDB.wv LIMIT 1;")
if printf '%s' "$q_re" | grep -qiE 'error|exception'; then
  fail "重建后按新列 v9 查询报错（缓存未失效）：$(printf '%s' "$q_re" | tr '\n' ' ' | cut -c1-140)"
else
  pass "重建后按新列 v9 查询正常"
fi

# ---------------------------------------------------------------------------
log "=== 7) 清理 ==="
assert_ok "DROP VIEW wv"  "$(sqt "DROP VIEW IF EXISTS $TDB.wv;")"
assert_ok "DROP VIEW wv2" "$(sqt "DROP VIEW $TDB.wv2;")"
assert_ok "DROP VIEW nv"  "$(sqt "DROP VIEW $TDB.nv;")"
sqt "DROP VIEW IF EXISTS $TDB.wv3;" >/dev/null 2>&1
assert_set_is "SHOW VIEWS 已清空" "$(md_names "$(sqt "SHOW VIEWS FROM $TDB;")")" ""

md_case_finish
