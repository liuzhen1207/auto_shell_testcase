#!/bin/bash
# 定点探测：single_target 选择器下 [L1(旧), L0(新)] 在 gap=1 时为什么没合并
#   逐步 dump：每批写完后的"逐 region 文件层级"、以及该库的压缩日志（starts / starts with N files / finishes）
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd $S || exit 1
. $S/lib/common.sh; . $S/lib/cmp.sh
cmp_load_env; cmp_parse_args
cmp_case_init "probe_level_gap"
V=v20121rc6_1010_7ae8713e
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
DBDIR=/data/iotdb/$V
H=192.168.99.77
Q(){ $CLI -h $H -u root -pw 'TimechoDB@2021' -e "$1" 2>&1 | tail -2; }
DB=root.probegap

echo "### 0) 用 gap=1 的准备参数重启集群（single_target / candidate=2 / interval=1000 / seq off）"
# 必须走 cmp_cluster_prepare：它会 stop → 还原 conf_orig → 写 conf（含 EXTRA_CONF）→ 启动
export EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=1000,inner_seq_selector=size_tiered_single_target,max_level_gap_in_inner_compaction=1"
cmp_cluster_prepare
log "  生效值：$(cmp_eff_all "${DN[0]}")"

dump(){ local tag=$1
  echo "  --- [$tag] 逐 region 文件层级 ---"
  for h in "${DN[@]}"; do
    echo "    $h:"
    sshx "$h" "find $DBDIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile' | sort | sed 's|.*/data/||' | awk -F/ '{print \"      \" \$2 \"/\" \$3 \"/\" \$4 \"  \" \$NF}'" 2>/dev/null
  done
  echo "  --- [$tag] 该库压缩日志（starts/finishes/selected）---"
  for h in "${DN[@]}"; do
    sshx "$h" "grep -hE '$DB-[0-9]+ \[Compaction\]' $DBDIR/logs/log_datanode_compaction.log 2>/dev/null | tail -6 | cut -c1-220" 2>/dev/null
  done
}
NOW=$(date +%s%3N); NOW=$(( NOW - 3600000 ))
log "--- 写 2 批 → 等 L1 ---"
for b in 1 2; do for d in 1 2 3; do
    vals=""; for ((k=1;k<=100;k++)); do vals="$vals($(( NOW + b*20000 + k*10 )),$((k+b))),"; done
    sq "insert into $DB.d$d(time,s1) values ${vals%,};" >/dev/null; done; sq "flush;" >/dev/null; done
ensure_closed "$DB" 2 10 || true
cmp_set_hot enable_seq_space_compaction true >/dev/null
for i in $(seq 1 20); do
  n=$(sshx "${DN[0]}" "find $DBDIR/data/datanode/data -path '*/$DB/*' -name '*-1-0.tsfile' | wc -l" 2>/dev/null | tr -dc '0-9')
  [ "${n:-0}" -ge 1 ] && break; sleep 3
done
dump "写 2 批 + 等 L1 之后"

log "--- 再写 1 批（新的 L0）---"
for d in 1 2 3; do
  vals=""; for ((k=1;k<=100;k++)); do vals="$vals($(( NOW + 20000 + k*10 )),$((k+3))),"; done
  sq "insert into $DB.d$d(time,s1) values ${vals%,};" >/dev/null; done; sq "flush;" >/dev/null
ensure_closed "$DB" 2 10 || true
dump "[L1, L0] 场景就绪（gap=1，interval=1000）"
log "--- 等 60s，看是否合并出 L2 ---"
sleep 60
dump "等 60s 之后"
echo "  合并计数：inner finishes=$(cmp_inner_finish "$DB")  TsFile=$(cmp_all_sum "$DB")"
log "--- 热改 gap=2，再等 45s ---"
cmp_set_hot max_level_gap_in_inner_compaction 2 >/dev/null
log "  生效值=$(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction)"
sleep 45
dump "gap=2 等 45s 之后"
echo "### 探测结束 $(date '+%F %T')"
