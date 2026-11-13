#!/bin/bash
# ============================================================================
# 生成 LBAC 测试报告
#   usage: report.sh <results_dir> <输出文件> [模式标签]
# ============================================================================
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$BASE/conf/env.conf"
R="${1:?usage: report.sh <results_dir> <out.md> [标签]}"
OUT="${2:-$R/report.md}"
TAG="${3:-normal}"

VARS=$(timeout 40 $CLI -h "$HOST" -p 6667 -u "${SYS_ADMIN:-sys_admin}" -pw "${ADMIN_PW:-$PW}" -sql_dialect table -e "show variables" 2>/dev/null)
[ -z "$VARS" ] && VARS=$(timeout 40 $CLI -h "$HOST" -p 6667 -u root -pw "$PW" -sql_dialect table -e "show variables" 2>/dev/null)
PROTO=$(echo "$VARS" | grep -i DataRegionConsensusProtocolClass | awk -F'|' '{gsub(/ /,"",$3); print $3}')
SR=$(echo "$VARS" | grep -i SchemaReplicationFactor | awk -F'|' '{gsub(/ /,"",$3); print $3}')
DR=$(echo "$VARS" | grep -i DataReplicationFactor | awk -F'|' '{gsub(/ /,"",$3); print $3}')

{
echo "# LBAC 测试报告（${TAG} 模式）"
echo
echo "| 项目 | 内容 |"
echo "| --- | --- |"
echo "| 版本 | 2.0.13.1 / 83183d0（RC2） |"
echo "| 模式 | ${TAG} |"
echo "| 副本 | Schema ${SR:-3} / Data ${DR:-2} |"
echo "| 数据面协议 | ${PROTO:-IoTConsensus} |"
echo "| 用例总数 | 141 |"
echo "| 结果目录 | \`$R\` |"
echo
echo "## 一、总览"
echo
awk -F'\t' 'NR>1{c[$4]++} END{printf "| PASS | FAIL | KNOWN | SKIP |\n| ---: | ---: | ---: | ---: |\n| %d | %d | %d | %d |\n", c["PASS"], c["FAIL"], c["KNOWN"], c["SKIP"]}' "$R/results.tsv"
echo
echo "## 二、按模块统计"
echo
echo "| 模块 | 用例 | PASS | FAIL | SKIP |"
echo "| --- | ---: | ---: | ---: | ---: |"
awk -F'\t' 'NR>1{tot[$2]++; if($4=="PASS") p[$2]++; else if($4=="FAIL") f[$2]++; else if($4=="SKIP") s[$2]++} END{for(k in tot) printf "| %s | %d | %d | %d | %d |\n", k, tot[k], p[k], f[k], s[k]}' "$R/results.tsv" | sort
echo
echo "## 三、失败与跳过明细"
echo
awk -F'\t' 'NR>1 && $4=="FAIL"{print "- **"$1"** ["$2"/"$3"] "$7}' "$R/results.tsv"
[ -z "$(awk -F'\t' 'NR>1 && $4=="FAIL"' "$R/results.tsv")" ] && echo "（无失败）"
echo
awk -F'\t' 'NR>1 && $4=="SKIP"{print "- SKIP **"$1"**："$7}' "$R/results.tsv"
echo
echo "## 四、日志扫描（CN/DN ERROR + WARN）"
echo
if [ -f "$R/log_scan.txt" ]; then
  echo "- 总计：$(wc -l < "$R/log_scan.txt") 行"
  echo '```'
  sed -E 's/^\[[A-Z]+ [0-9.]+\] //; s/^[0-9-]+ [0-9:,]+ \[[^]]*\] //; s/^[A-Z]+ +//' "$R/log_scan.txt" | cut -c1-110 | sort | uniq -c | sort -rn | head -12
  echo '```'
fi
} > "$OUT"
echo "报告：$OUT"
