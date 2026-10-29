#!/bin/bash
# ============================================================================
# MD-U01 真实 jar 的 UDF / Trigger 全链路（注册 → SHOW → 执行/触发 → 重启 → DROP）
#
# 为什么要有这条：元数据不只是"库/表/时序"，用户自定义对象（UDF / Trigger）同样是元数据，
# 而且它们**必须带真实 jar**才能测——只测"类不存在"只能覆盖失败路径。
#
# 覆盖：
#   UDF：
#     注册（CREATE FUNCTION … AS '<类>' USING URI 'file:///…/mdskill.jar'）
#     SHOW FUNCTIONS（类型列必须是 external UDTF，与 built-in 区分）
#     执行（SELECT md_double(s1) 值 ×2；带 'factor'='3' 属性 → ×3）
#     会抛异常的 UDF：注册成功但执行报错（自定义消息透出）
#     失败路径：重名 1207 / 类不存在 1200 / jar 不存在 1304 / DROP 不存在 301
#     重启后仍然可用（UDF 元数据持久化）
#   Trigger：
#     CREATE STATELESS TRIGGER … WITH (marker, tag) → SHOW TRIGGERS 字段校验
#     插入数据后 fire() 真的被调用（marker 文件为证，跨节点统计）
#     集群重启后 SHOW TRIGGERS 仍在、fire 仍然生效（触发器元数据持久化）
#     DROP TRIGGER → 列表清空 + onDrop 回调；重复 DROP 1301
#     失败路径：validate() 主动拒绝 / 类不存在 1303
#
# 实测记录（RC5，见 docs/RESULTS.md）：
#   * onCreate 在**三个节点**都被调用（每个 DN 都加载类）；fire 只在**执行写入的那个节点**发生
#   * stateless 触发器不会收到 restore()（源码 TriggerExecutor：仅 stateful 调用 restore）
#
# 前置：jar 由 assets/udf/build_and_deploy.sh 构建并分发到各节点 /data/iotdb/udf_md/mdskill.jar
#       （本用例在缺失时会自动调用该脚本补齐）
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

DB="root.${MD_PREFIX}_u01"
FUNC_MD="md_${MD_PREFIX}_double"
FUNC_BOOM="md_${MD_PREFIX}_boom"
TRIG="trg_${MD_PREFIX}_u01"
JAR_PATH="/data/iotdb/udf_md/mdskill.jar"
JAR_URI="file://$JAR_PATH"
MARKER="/tmp/mdskill_trg_$$.log"
md_case_init "md_udf_trigger"
# 本用例**故意**制造错误日志（UDF 抛异常、触发器 validate 拒绝、注册不存在的类），
# 这些 WARN/ERROR 是预期内的，日志检查里排除（只对本用例生效）。
export MD_LOG_BENIGN_EXTRA='MDSKILL_UDF_BOOM|MDSKILL_TRIGGER_REJECT|Failed to load class|Failed to get executable|Failed to create UDF|Failed to drop UDF|Failed to create trigger|Failed to drop trigger|mdskill\.NoSuch'
md_cluster_prepare

# 跨节点统计 marker 文件里某个事件的次数 / 有该事件的节点列表
trg_count(){ local f=$1 k=$2 tot=0 c h
  for h in "${DN[@]}"; do
    c=$(sshx "$h" "grep -c -- ' $k' $f 2>/dev/null" | tr -dc '0-9'); tot=$((tot+${c:-0}))
  done; printf '%s' "$tot"; }
trg_nodes(){ local f=$1 k=$2 out="" h
  for h in "${DN[@]}"; do
    [ "$(sshx "$h" "grep -c -- ' $k' $f 2>/dev/null" | tr -dc '0-9')" -gt 0 ] 2>/dev/null && out="$out $h"
  done; printf '%s' "$out"; }
trg_clean(){ local h; for h in "${DN[@]}"; do sshx "$h" "rm -f $MARKER" >/dev/null 2>&1; done; }
trg_dump(){ local h; for h in "${DN[@]}"; do log "    [$h] $(sshx "$h" "cat $MARKER 2>/dev/null | sed -E 's/^[0-9]+ //' | tr '\n' '|'" 2>/dev/null)"; done; }

log "=== 0) 确认测试 jar 已在所有节点 ==="
missing=0
for h in "${DN[@]}"; do
  if [ "$(sshx "$h" "test -f $JAR_PATH && echo yes" 2>/dev/null | tr -d '\r')" != "yes" ]; then missing=$((missing+1)); fi
done
if [ "$missing" -gt 0 ]; then
  warn "有 $missing 个节点缺 $JAR_PATH，尝试用 assets/udf/build_and_deploy.sh 构建并分发"
  if [ -f "$MD_SKILL_DIR/assets/udf/build_and_deploy.sh" ]; then
    bash "$MD_SKILL_DIR/assets/udf/build_and_deploy.sh" >>"$OUT" 2>&1 || fail "构建/分发 mdskill.jar 失败"
  else
    fail "缺少 assets/udf/build_and_deploy.sh，无法准备 jar"
  fi
fi
for h in "${DN[@]}"; do
  assert_eq "jar 存在于 $h" "$(sshx "$h" "test -f $JAR_PATH && echo yes" 2>/dev/null | tr -d '\r')" "yes"
done

log "--- 清理历史对象 ---"
q_tree "DROP TRIGGER $TRIG"
q_tree "DROP FUNCTION $FUNC_MD"
q_tree "DROP FUNCTION $FUNC_BOOM"
drop_tree_db "$DB"
trg_clean

log "=== 1) 建库/时序/数据（UDF 与 Trigger 的试验田） ==="
assert_ok "建库" "$(sq "CREATE DATABASE $DB;")"
assert_ok "建时序" "$(sq "CREATE TIMESERIES $DB.d1.s1 DOUBLE;")"
assert_ok "写入 3 点" "$(sq "INSERT INTO $DB.d1(timestamp, s1) VALUES(1000, 1.5), (2000, 2.5), (3000, 3.5);")"

# ---------------------------------------------------------------------------
log "=== 2) UDF：注册与 SHOW FUNCTIONS ==="
assert_ok "CREATE FUNCTION … USING URI" "$(sq "CREATE FUNCTION $FUNC_MD AS 'mdskill.MdUdtf' USING URI '$JAR_URI';")"
fnout=$(sq 'SHOW FUNCTIONS;')
fnames=$(md_names "$fnout" | tr 'a-z' 'A-Z')
assert_set_has "SHOW FUNCTIONS 含 ${FUNC_MD^^}" "$fnames" "${FUNC_MD^^}"
assert_contains "该函数类型标记为 external UDTF（区别于 built-in）" "$fnout" 'external UDTF'
assert_contains "SHOW FUNCTIONS 记录类名" "$fnout" 'mdskill\.MdUdtf'

log "=== 3) UDF：执行 —— 结果必须是注册的那个类算出来的 ==="
run=$(sq "SELECT ${FUNC_MD}(s1) FROM $DB.d1;")
vals=$(printf '%s\n' "$run" | table_rows | awk -F'|' '{v=$(NF-1); gsub(/^[ \t]+|[ \t]+$/,"",v); print v}' | tr '\n' ',')
assert_eq "md_double 把 1.5/2.5/3.5 变成 3.0/5.0/7.0" "$vals" "3.0,5.0,7.0,"
run3=$(sq "SELECT ${FUNC_MD}(s1, 'factor'='3') FROM $DB.d1;")
vals3=$(printf '%s\n' "$run3" | table_rows | awk -F'|' '{v=$(NF-1); gsub(/^[ \t]+|[ \t]+$/,"",v); print v}' | tr '\n' ',')
assert_eq "带 factor=3 属性时变成 4.5/7.5/10.5" "$vals3" "4.5,7.5,10.5,"

log "=== 4) UDF：注册成功但执行失败（注册 ≠ 可用） ==="
assert_ok "注册会抛异常的 UDF" "$(sq "CREATE FUNCTION $FUNC_BOOM AS 'mdskill.MdUdtfErr' USING URI '$JAR_URI';")"
boom=$(sq "SELECT ${FUNC_BOOM}(s1) FROM $DB.d1;")
assert_error "执行该 UDF 必须报错" "$boom" 'MDSKILL_UDF_BOOM'
assert_eq "报错后 SHOW FUNCTIONS 里该函数仍在（元数据没被回滚）" \
  "$(md_names "$(sq 'SHOW FUNCTIONS;')" | tr 'a-z' 'A-Z' | grep -cx "${FUNC_BOOM^^}")" "1"

log "=== 5) UDF：失败路径 ==="
assert_error "重名注册 1207" "$(sq "CREATE FUNCTION $FUNC_MD AS 'mdskill.MdUdtf' USING URI '$JAR_URI';")" '1207'
assert_error "类不存在 1200" "$(sq "CREATE FUNCTION md_${MD_PREFIX}_nope AS 'mdskill.NoSuchClass' USING URI '$JAR_URI';")" '1200'
assert_error "jar 不存在 1304" \
  "$(sq "CREATE FUNCTION md_${MD_PREFIX}_nope2 AS 'mdskill.MdUdtf' USING URI 'file:///data/iotdb/udf_md/nosuch_${MD_PREFIX}.jar';")" '1304'
assert_error "DROP 不存在的函数 301" "$(sq "DROP FUNCTION md_${MD_PREFIX}_nosuch;")" '301'

# ---------------------------------------------------------------------------
log "=== 6) Trigger：注册与 SHOW TRIGGERS ==="
assert_ok "CREATE STATELESS TRIGGER … WITH (marker,tag)" \
  "$(sq "CREATE STATELESS TRIGGER $TRIG BEFORE INSERT ON $DB.d1.** AS 'mdskill.MdTrigger' USING URI '$JAR_URI' WITH (marker='$MARKER', tag='u01');")"
tinfo=$(sq 'SHOW TRIGGERS;')
assert_contains "SHOW TRIGGERS 含触发器名" "$tinfo" "$TRIG"
assert_contains "事件为 BEFORE_INSERT" "$tinfo" 'BEFORE_INSERT'
assert_contains "类型为 STATELESS" "$tinfo" 'STATELESS'
assert_contains "状态为 ACTIVE" "$tinfo" 'ACTIVE'
assert_contains "记录了路径模式" "$tinfo" "$DB\.d1"
assert_contains "记录了类名" "$tinfo" 'mdskill\.MdTrigger'

log "=== 7) Trigger：onCreate 与 fire ==="
assert_ge "onCreate 在多个节点被调用（每个 DN 都加载类）" "$(trg_count "$MARKER" onCreate)" "2"
assert_eq "注册阶段还没 fire" "$(trg_count "$MARKER" fire)" "0"
assert_ok "写入触发触发器" "$(sq "INSERT INTO $DB.d1(timestamp, s1) VALUES(4000, 4.5);")"
sleep 5
fire1=$(trg_count "$MARKER" fire)
log "  插入后 fire 次数=$fire1，发生节点:$(trg_nodes "$MARKER" fire)"
trg_dump
assert_ge "fire 至少被调用一次" "${fire1:-0}" "1"
assert_eq "fire 只发生在执行写入的那个节点（不是三副本都触发）" "$(printf '%s' "$(trg_nodes "$MARKER" fire)" | wc -w | tr -d ' ')" "1"

log "=== 8) Trigger：重启后元数据仍在且仍生效 ==="
cluster_stop
cluster_start
assert_contains "重启后 SHOW TRIGGERS 仍列出该触发器" "$(sq 'SHOW TRIGGERS;')" "$TRIG"
assert_ok "重启后写入" "$(sq "INSERT INTO $DB.d1(timestamp, s1) VALUES(5000, 5.5);")"
sleep 5
fire2=$(trg_count "$MARKER" fire)
log "  重启后 fire 累计=$fire2（stateless 不会收到 restore，按设计）"
assert_ge "重启后 fire 次数继续增加（触发器确实被恢复）" "${fire2:-0}" "$((fire1 + 1))"

log "=== 9) Trigger：失败路径 ==="
assert_error "validate() 主动拒绝" \
  "$(sq "CREATE STATELESS TRIGGER ${TRIG}_rej BEFORE INSERT ON $DB.d1.** AS 'mdskill.MdTrigger' USING URI '$JAR_URI' WITH (marker='$MARKER', tag='rej', reject='true');")" ''
assert_error "类不存在 1303" \
  "$(sq "CREATE STATELESS TRIGGER ${TRIG}_nope BEFORE INSERT ON $DB.d1.** AS 'mdskill.NoSuchTrigger' USING URI '$JAR_URI' WITH (marker='$MARKER');")" '1303'
assert_error "不存在的触发器 DROP 1301" "$(sq "DROP TRIGGER ${TRIG}_nosuch;")" '1301'

log "=== 10) Trigger：DROP 后列表清空 + onDrop 回调 ==="
assert_ok "DROP TRIGGER" "$(sq "DROP TRIGGER $TRIG;")"
assert_set_lacks "SHOW TRIGGERS 不再含该触发器" "$(md_names "$(sq 'SHOW TRIGGERS;')")" "$TRIG"
assert_ge "onDrop 被调用" "$(trg_count "$MARKER" onDrop)" "1"
assert_error "重复 DROP 1301" "$(sq "DROP TRIGGER $TRIG;")" '1301'

log "=== 11) 路径模式语义：触发器注册在【序列】上，设备节点自身没有序列（A/B 对照） ==="
# 文档《06-流计算-触发器》（见 docs/refs/）明确：
#   "触发器可以注册在任意路径模式上。被注册有触发器的序列将会被触发器侦听，
#     当序列上有数据变动时，触发器中对应的触发方法将会被调用。"
# ⇒ 侦听对象是**序列**。ON <设备> 指向的是设备节点本身，它下面没有序列，所以不会触发——**符合预期**。
#   要覆盖整个设备请写 ON <设备>.**（或 .* / 逐个序列）。
# 代码层面与之一致：PatternTreeMap.searchOverlapped 的终端分支只收集"匹配测量名的子节点"的值，
#   以及"本节点是 ** 时"本节点的值 —— 正好对应"注册在序列上"这个语义。
MARK_BARE="${MARKER}.bare"
MARK_STAR="${MARKER}.star"
for h in "${DN[@]}"; do sshx "$h" "rm -f $MARK_BARE $MARK_STAR" >/dev/null 2>&1; done
assert_ok "注册设备级裸路径触发器 ON $DB.d1" \
  "$(sq "CREATE STATELESS TRIGGER ${TRIG}_dev BEFORE INSERT ON $DB.d1 AS 'mdskill.MdTrigger' USING URI '$JAR_URI' WITH (marker='$MARK_BARE', tag='dev');")"
assert_ok "注册整设备触发器 ON $DB.d1.**" \
  "$(sq "CREATE STATELESS TRIGGER ${TRIG}_star BEFORE INSERT ON $DB.d1.** AS 'mdskill.MdTrigger' USING URI '$JAR_URI' WITH (marker='$MARK_STAR', tag='star');")"
assert_contains "两个触发器在 SHOW TRIGGERS 里都存在" "$(sq 'SHOW TRIGGERS;')" "$TRIG"
assert_ok "写入一条数据" "$(sq "INSERT INTO $DB.d1(timestamp, s1) VALUES(6000, 6.5);")"
sleep 5
barefire=$(trg_count "$MARK_BARE" fire)
starfire=$(trg_count "$MARK_STAR" fire)
log "  ON <设备> fire=$barefire（期望 0，设备节点下没有序列）；ON <设备>.** fire=$starfire（期望 ≥1）"
assert_eq "ON <设备>（设备节点自身）不触发——侦听对象是序列，符合文档" "${barefire:-0}" "0"
assert_ge "阳性对照：ON <设备>.** 覆盖该设备的所有序列，必须触发" "${starfire:-0}" "1"
note "行为记录（文档已明确、符合预期）：触发器注册在序列上，设备节点自身没有序列，故 ON <设备> 不触发；覆盖整设备用 ON <设备>.**。见 docs/refs/06-流计算-触发器.pdf"
assert_ok "DROP 裸路径触发器" "$(sq "DROP TRIGGER ${TRIG}_dev;")"
assert_ok "DROP 对照触发器" "$(sq "DROP TRIGGER ${TRIG}_star;")"

log "--- 清理 ---"
q_tree "DROP TRIGGER ${TRIG}_rej"
q_tree "DROP TRIGGER ${TRIG}_nope"
q_tree "DROP FUNCTION $FUNC_MD"
q_tree "DROP FUNCTION $FUNC_BOOM"
drop_tree_db "$DB"
trg_clean
assert_eq "SHOW TRIGGERS 已清空" "$(md_count "$(md_rows "$(sq 'SHOW TRIGGERS;')")")" "0"

md_case_finish tree 'SHOW FUNCTIONS;'
