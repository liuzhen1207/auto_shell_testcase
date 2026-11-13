#!/bin/bash
# ============================================================================
# LBAC 三权分立模式回归（与 normal 模式 141 条一一对应：LB-S-xxx ↔ LB-xxx）
#   前置：bash tools/mode_sep.sh on
#   结果：results_sep/run_<ts>/，并生成映射表 cases_sep.tsv
# ============================================================================
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
export SEP=1
export RESULT_BASE="$BASE/results_sep"
. "$BASE/conf/env.conf"

# 确认三权分立已开启
r=$(timeout 60 $CLI -h "$HOST" -p 6667 -u "$SYS_ADMIN" -pw "$ADMIN_PW" -e "show cluster" 2>/dev/null | grep -c Running)
if [ "${r:-0}" -lt 8 ]; then echo "三权分立未开启或集群异常（Running=$r），请先执行 tools/mode_sep.sh on"; exit 4; fi

# 生成一一对应映射
MAP="$BASE/cases_sep.tsv"
if [ ! -f "$MAP" ]; then
  awk -F'\t' '{printf "LB-S-%03d\t%s\t%s\t%s\t%s\t%s\n", NR, $1, $2, $3, $4, $5}' "$BASE/cases.tsv" > "$MAP"
  echo "已生成映射：$MAP"
fi

echo "[$(date '+%T')] 三权分立模式回归开始（SEP=1）"
bash "$BASE/tools/suite.sh" "$@" > "${LOGFILE:-/tmp/lbac_sep_$(date +%H%M%S).log}" 2>&1

tail -30 "${LOGFILE:-/tmp/lbac_sep_$(date +%H%M%S).log}"
