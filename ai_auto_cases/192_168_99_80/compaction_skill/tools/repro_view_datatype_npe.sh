#!/bin/bash
# ============================================================================
# 缺陷最小复现：`ALTER VIEW … ALTER COLUMN … SET DATA TYPE` 触发 ConfigNode 共识状态机 NPE
#
#   现象：ConfigNode follower 反复打印
#     java.lang.NullPointerException: Cannot invoke
#       "org.apache.iotdb.commons.request.IConsensusRequest.markAsGeneratedByRemoteConsensusLeader()" because "<local7>" is null
#     根因日志：java.io.IOException: Unknown Procedure type: 766
#
#   用法（在 192.168.99.80 上执行，需要已部署的技能目录与 RC6）：
#     bash repro_view_datatype_npe.sh [--consensus IoTConsensus]
#
#   退出码：**1 = 已复现**（缺陷存在）；0 = 未复现（疑似已修复）。
#   证据：完整日志写在 $OUT（脚本结尾会打印路径），其中含首条 NPE 堆栈 + `Unknown Procedure type: 766` 上下文。
#
#   注意：脚本不关集群（方便研发自己上去看日志）；需要停集群可执行
#         bash /data/iotdb/autotest/compaction_skill/tools/stop_cluster.sh（若存在）或框架的 stop 脚本。
# ============================================================================
set -uo pipefail
SKILL=${SKILL:-/data/iotdb/autotest/compaction_skill}
. "$SKILL/lib/common.sh"
. "$SKILL/lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "dt07_repro_${DATA_CONSENSUS}"

SRC=root.dt07src
VDB=dt07vw
BASE=$(( ($(date +%s) - 3600) * 1000 ))

log "=== 环境 ==="
log "  build=$V_TESTDB consensus=$DATA_CONSENSUS CN=[${CN[*]}] DN=[${DN[*]}]"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare

log "=== 1) 建树库 + 序列 + 写 2 行 ==="
sq "create database $SRC;" >/dev/null
sq "create timeseries $SRC.d1.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
sq "create timeseries $SRC.d1.s2 with datatype=DOUBLE, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
sq "insert into $SRC.d1(time,s1,s2) values ($(( BASE + 100 )),7,1.5),($(( BASE + 110 )),8,2.5);" >/dev/null
sq "flush;" >/dev/null; sleep 4
log "  源库数据行数=$(cmp_rows_series "$SRC.d1.s1")"

log "=== 2) 建表库 + 树转表视图 ==="
sqt "create database $VDB;" >/dev/null 2>&1
r=$(sqt "create view $VDB.v1 (s1 INT32 FIELD FROM s1, s2 DOUBLE FIELD FROM s2) as $SRC.d1.**;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -1)
log "  create view -> $(printf '%s' "$r" | cut -c1-160)"
log "  视图结构: $(sqt "desc $VDB.v1;" 2>&1 | grep -E '^\|' | tr '\n' ' ' | cut -c1-160)"

log "=== 3) 触发动作：ALTER VIEW ... ALTER COLUMN ... SET DATA TYPE ==="
r=$(cmp_alter_col "alter view $VDB.v1 alter column s1 set data type DOUBLE;")
log "  ALTER VIEW -> $(printf '%s' "$r" | cut -c1-160)"
sleep 6
log "  改后视图结构: $(sqt "desc $VDB.v1;" 2>&1 | grep -E '^\|' | tr '\n' ' ' | cut -c1-160)"
log "  视图读数（s1 应按新类型呈现）: $(cmp_tbl_col_vals "select s1 from $VDB.v1 order by time;" s1)"

log "=== 4) 取证：ConfigNode 日志（只有 follower 会打，leader 用本地对象应用）==="
NPE=0; UNK=0
for h in "${CN[@]}"; do
  n=$(sshx "$h" "grep -c 'NullPointerException' $DB_DIR/logs/log_confignode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'); n=${n:-0}
  u=$(sshx "$h" "grep -c 'Unknown Procedure type: 766' $DB_DIR/logs/log_confignode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9'); u=${u:-0}
  NPE=$(( NPE + n )); UNK=$(( UNK + u ))
  log "  $h: NullPointerException=$n  'Unknown Procedure type: 766'=$u"
  if [ "$n" -gt 0 ]; then
    { echo "----- $h: 首条 NullPointerException（含前 2 行触发日志 + 后 18 行堆栈）-----"
      sshx "$h" "grep -n -m 1 -B 2 -A 18 'NullPointerException' $DB_DIR/logs/log_confignode_all.log 2>/dev/null" 2>/dev/null | cut -c1-220
      echo "----- $h: 'Unknown Procedure type: 766' 上下文 -----"
      sshx "$h" "grep -m 1 -B 8 -A 8 'Unknown Procedure type: 766' $DB_DIR/logs/log_confignode_all.log 2>/dev/null" 2>/dev/null | cut -c1-220
    } >>"$OUT" 2>&1
  fi
done

log "=== 结论 ==="
log "  NPE=$NPE 条，Unknown Procedure type: 766=$UNK 条（3 个 CN 合计）"
log "  完整证据：$OUT"
if [ "$NPE" -gt 0 ] || [ "$UNK" -gt 0 ]; then
  log "  **已复现**：ALTER VIEW 改列类型后 ConfigNode follower 抛 NPE（procedure 类型 766 未注册反序列化分支）"
  exit 1
else
  log "  未复现：ConfigNode 日志中没有 NPE / 'Unknown Procedure type: 766'（疑似已修复，请用回归门禁 DT-07 复核）"
  exit 0
fi
