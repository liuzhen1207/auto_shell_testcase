#!/bin/bash
# make_report.sh — 从 results.tsv + manifests 生成 RC10 DELETE 测试报告（Markdown）
# 同一 (协议, 用例) 多次执行时以最后一次为准
set -u
BASE=/data2/iotdb/rc10_matrix
R=$BASE/results/results.tsv
LATEST=$BASE/results/results.latest.tsv
OUT=${1:-$BASE/report/RC10-DELETE-REPORT.md}
mkdir -p "$(dirname "$OUT")"
touch "$R"
tac "$R" | awk -F'\t' '!seen[$1 FS $2]++' | tac > "$LATEST"
bash "$BASE/scripts/summarize.sh" > /dev/null 2>&1 || true

total_planned=$(( $(wc -l < "$BASE/manifest-IoTConsensus.tsv") + $(wc -l < "$BASE/manifest-IoTV2.tsv") ))
total_done=$(awk -F'\t' '$6!="SKIP_NO_SPEC"' "$LATEST" | wc -l)
total_pass=$(awk -F'\t' '$6=="PASS"' "$LATEST" | wc -l)
total_fail=$(awk -F'\t' '$6!="PASS" && $6!="SKIP_NO_SPEC"' "$LATEST" | wc -l)
total_skip=$(awk -F'\t' '$6=="SKIP_NO_SPEC"' "$LATEST" | wc -l)
sum_sec=$(awk -F'\t' '{s+=$5} END{print s+0}' "$LATEST")
raw_sec=$(awk -F'\t' '{s+=$5} END{print s+0}' "$R")
raw_runs=$(wc -l < "$R")
h=$((sum_sec/3600)); m=$(((sum_sec%3600)/60))
rh=$((raw_sec/3600)); rm=$(((raw_sec%3600)/60))

{
echo "# RC10 DELETE 全量测试报告"
echo
echo "- 生成时间：$(date -Is)"
echo "- 版本：TimechoDB 2.0.12.1 RC10，BuildInfo \`c60ce63\`，实例 \`/data1/iotdb/v20121rc10_1021_c60ce63\`"
echo "- 拓扑：3 CN (172.16.2.16/.17/.18) + 5 DN (172.16.2.19/.24/.21/.22/.23)，SchemaRegion 副本 3，DataRegion 副本 2，集群 ClusterID3"
echo "- 用例矩阵：85 个 CASE ID / 163 个协议轮次（IoTConsensus 85 + IoTV2 78）"
echo
echo "## 汇总"
echo
echo "| 指标 | 数值 |"
echo "|---|---|"
echo "| 计划轮次 | $total_planned |"
echo "| 已判定轮次（去重后） | $total_done |"
echo "| 通过 | $total_pass |"
echo "| 失败 | $total_fail |"
echo "| 缺规格跳过 | $total_skip |"
echo "| 去重后累计执行时长 | ${h}h${m}m (${sum_sec}s) |"
echo "| 实际执行总时长（含重跑） | ${rh}h${rm}m (${raw_sec}s，$raw_runs 次执行) |"
echo
echo "## 逐轮结果（每例取最后一次）"
echo
echo "| 协议 | CASE | 开始 | 结束 | 耗时(s) | 结论 |"
echo "|---|---|---|---|---|---|"
awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6}' "$LATEST" | sort -t'|' -k3,3 -k2,2
echo
if [ "$total_fail" -gt 0 ]; then
  echo "## 未通过轮次"
  echo
  awk -F'\t' '$6!="PASS" && $6!="SKIP_NO_SPEC" {printf "- **%s / %s** → %s（证据：artifacts/%s/%s/）\n", $2,$1,$6,$1,$2}' "$LATEST"
  echo
fi
echo "## 实际查询返回（语义核对用）"
echo
echo "行数 = 结果表头 + 数据行；hash 为五台 DN 一致的归一化结果摘要。跨协议同一用例的 hash 应完全相同。"
echo
echo "| CASE | 协议 | 行数 | 结果hash |"
echo "|---|---|---|---|"
if [ -s "$BASE/results/summary.tsv" ]; then
  awk -F'\t' '{printf "| %s | %s | %s | %s |\n", $2,$1,$3,substr($4,1,10)}' "$BASE/results/summary.tsv" | sort
fi
echo
if [ -s "$BASE/results/cross-protocol-diff.txt" ]; then
  echo "### 跨协议不一致"
  echo
  echo '```'
  cat "$BASE/results/cross-protocol-diff.txt"
  echo '```'
  echo
fi
echo "## 判定口径"
echo
echo "每轮独立干净重置（停集群→校验进程归零→清 data/logs→设协议→并行启动→8/8 Running）；"
echo "执行用例 SQL 后按本例相关 DataRegion 采集 5 台 DN 的 syncLag，先等收敛再连续 31 个样本（10s 间隔，共 5 分钟）全为 0；"
echo "随后逐台 kill -9 DN，记录停机期查询，重启并等待进程与 6667 就绪，恢复查询后再过一个 31 样本零 lag 窗口；"
echo "最后五台 DN 同一查询（仅 SELECT，逐字比对）并要求 SHOW CLUSTER 8/8 Running。"
echo "SQL 语义、物理证据、同步收敛、逐 DN 一致性、最终集群状态分别判定。"
} > "$OUT"

echo "report written: $OUT"
head -n 22 "$OUT"
