#!/bin/bash
# CO-33 探测 B（RC7）：load 导入路径能否造出"重叠的 seq TsFile"，以及 auto-repair 的真实链路
#   ① 造 1 个 seq TsFile A → 拷贝到 staging → load 回来（同库、同时间范围 ⇒ 重叠/重复）
#   ② 开 seq 合并（auto-repair=false）→ 找 overlap 校验失败证据（负向）
#   ③ 热开 enable_auto_repair_compaction=true → 找修复任务/重写证据（正向）
# 用法（99.80）： V_TESTDB=v20121rc7_1014_7c61428 bash tools/probe_co33b.sh
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
. "$S/lib/common.sh"
. "$S/lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
OUT=/tmp/probe_co33b_$(date +%Y%m%d_%H%M%S).out
: >"$OUT"
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$OUT"; }
PAT='FAILED_TO_PASS_COMPACTION_OVERLAP_VALIDATION|CompactionValidationFailedException|RepairScheduler|RepairUnsortedFileCompactionTask|has unsorted data|can not repair|need to repair|RepairDataFileScanUtil'
scan_logs(){ local h n
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "grep -acE '$PAT' \$DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    log "  $h: 命中 ${n:-0} 行"
    [ "${n:-0}" -gt 0 ] && sshx "$h" "grep -aE '$PAT' \$DB_DIR/logs/log_datanode_all.log | tail -6 | cut -c1-210" 2>/dev/null | sed 's/^/    /' | tee -a "$OUT"
  done; }

DB=root.c33b
BASE=$(( ($(date +%s) - 7200) * 1000 ))
NODE="${DN[0]}"
STAGE=/tmp/co33_stage

log "=== 环境 ==="
log "  build=$V_TESTDB  db_dir=$DB_DIR"
EXTRA_CONF="$CMP_EXTRA_WRITE,enable_auto_repair_compaction=false" cmp_cluster_prepare

log "=== 1) 造 1 个 seq TsFile A（单批写入 + flush）==="
sq "create database $DB;" >/dev/null
sq "create timeseries $DB.d1.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
sq "insert into $DB.d1(time,s1) values ($(( BASE + 1 )),1),($(( BASE + 2 )),2),($(( BASE + 3 )),3),($(( BASE + 4 )),4),($(( BASE + 5 )),5);" >/dev/null
sq "flush;" >/dev/null; sleep 6
log "  布局=$(cmp_lay "$DB") 文件=$(cmp_all_sum "$DB")  行数=$(cmp_rows_series "$DB.d1.s1")"
F=$(sshx "$NODE" "find \$DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile' | sort | head -1" 2>/dev/null | tr -d '\r')
log "  文件 A = $F"

log "=== 2) 拷到 staging（只拷 .tsfile，不拷 .resource）并 load ==="
sshx "$NODE" "rm -rf $STAGE && mkdir -p $STAGE && cp '$F' $STAGE/ && ls -l $STAGE" 2>/dev/null | sed 's/^/  /' | tee -a "$OUT"
r=$(sq "load '$STAGE';" 2>&1 | tr '\n' ' ' | cut -c1-220)
log "  load 响应：$r"
sleep 8
log "  load 后布局=$(cmp_lay "$DB") 文件=$(cmp_all_sum "$DB")  行数=$(cmp_rows_series "$DB.d1.s1")"
sshx "$NODE" "find \$DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile' -printf '%f\n' | sort" 2>/dev/null | sed 's/^/    /' | tee -a "$OUT"

log "=== 3) 开 seq 合并（auto-repair=false）→ 找 overlap 校验失败（负向对照）==="
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 45
log "  布局=$(cmp_lay "$DB") finish=$(cmp_inner_finish "$DB")"
scan_logs

log "=== 4) 热开 enable_auto_repair_compaction=true → 找修复链路（正向）==="
cmp_set_hot enable_auto_repair_compaction true >/dev/null
log "  生效值：auto_repair=$(cmp_eff "$NODE" enable_auto_repair_compaction) seq=$(cmp_eff "$NODE" enable_seq_space_compaction)"
sleep 90
log "  布局=$(cmp_lay "$DB") finish=$(cmp_inner_finish "$DB") 文件=$(cmp_all_sum "$DB") 行数=$(cmp_rows_series "$DB.d1.s1")"
scan_logs

log "=== 5) 收尾证据 ==="
log "  数据指纹=$(cmp_fp_series "$DB.d1.s1")"
log "  load 目录残留：$(sshx "$NODE" "ls $STAGE | tr '\n' ' '" 2>/dev/null)"
log "=== 证据：$OUT ==="
