#!/bin/bash
# CO-33 前沿探测（RC7）：① seq TsFile 的 .resource 格式；② 造 overlapping seq 文件的可控方式；
#                          ③ auto-repair 的触发与日志形态；④ load 路径是否可用于导入
# 用法（99.80）： bash /data/iotdb/autotest/compaction_skill/tools/probe_co33.sh
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
. "$S/lib/common.sh"
. "$S/lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
OUT=/tmp/probe_co33_$(date +%Y%m%d_%H%M%S).out
: >"$OUT"
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$OUT"; }

DB=root.c33p
BASE=$(( ($(date +%s) - 7200) * 1000 ))

log "=== 环境 ==="
log "  build=$V_TESTDB consensus=$DATA_CONSENSUS nodes=${DN[*]}"
EXTRA_CONF="$CMP_EXTRA_WRITE,enable_auto_repair_compaction=false" cmp_cluster_prepare

log "=== 1) 建库 + 3 批写入（每批 flush ⇒ 3 个 level-0 seq TsFile）==="
sq "create database $DB;" >/dev/null
sq "create timeseries $DB.d1.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
for b in 1 2 3; do
  sq "insert into $DB.d1(time,s1) values ($(( BASE + (b-1)*1000 + 1 )),$b),($(( BASE + (b-1)*1000 + 2 )),$((b+10)));" >/dev/null
  sq "flush;" >/dev/null; sleep 3
done
sq "flush;" >/dev/null
cmp_wait_lay "$DB" "3/0/0/0" 90 >/dev/null
log "  布局=$(cmp_lay "$DB")  TsFile=$(cmp_all_sum "$DB")"

log "=== 2) .resource 文件格式（.77 上该库的文件与资源）==="
sshx "${DN[0]}" "find \$DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile*' | sort" 2>/dev/null | sed 's|.*/data/datanode/data/||' | sed 's/^/  /' | tee -a "$OUT"
RES=$(sshx "${DN[0]}" "find \$DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile.resource' | sort | head -1" 2>/dev/null | tr -d '\r')
log "  首个 resource: $RES"
sshx "${DN[0]}" "echo '--- cat -A 前 8 行 ---'; head -8 '$RES' | cat -A | cut -c1-200" 2>/dev/null | tee -a "$OUT"

log "=== 3) load 能力探测 ==="
r=$(sq "load '/tmp/co33_no_such_dir';" 2>&1 | tr '\n' ' ' | cut -c1-200)
log "  load 不存在目录 → $r"
r=$(sq "show variables;" 2>&1 | grep -aiE 'repair|unsorted' | head -3 | tr '\n' ' ')
log "  show variables 里的 repair 相关：${r:-（无）}"
log "  enable_auto_repair_compaction 生效值：$(cmp_eff "${DN[0]}" enable_auto_repair_compaction)"
log "  enable_seq_space_compaction 生效值：$(cmp_eff "${DN[0]}" enable_seq_space_compaction)"

log "=== 4) 直接观察：compaction 日志里与 repair 相关的行（基线，应为空）==="
for h in "${DN[@]}"; do
  n=$(sshx "$h" "grep -acE 'RepairScheduler|RepairUnsortedFileCompactionTask|has unsorted data|wrong time statistics|CompactionValidationFailedException' \$DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
  log "  $h: ${n:-0} 行"
done

log "=== 5) 该库 3 个 TsFile 的资源文件原文（用于设计'改统计'）==="
for f in $(sshx "${DN[0]}" "find \$DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile.resource' | sort" 2>/dev/null | tr -d '\r'); do
  log "  --- $f ---"
  sshx "${DN[0]}" "cat '$f'" 2>/dev/null | sed 's/^/    /' | tee -a "$OUT"
done

log "=== 证据：$OUT ==="
