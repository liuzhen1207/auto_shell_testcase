#!/bin/bash
# run_all.sh [case ...] —— 顺序执行用例；不带参数则跑 cases.tsv 全部
set -u
. "$(dirname "$0")/../tools/lib.sh"
SKILL=${SKILL:-/data2/iotdb/ddl_ha_skill}
ART=${ART:-/data2/iotdb/ddl_ha_results}
mkdir -p "$ART"
[ -f "$ART/results.tsv" ] || printf 'case\tgroup\tverdict\tduration\tchecks\ttarget\n' > "$ART/results.tsv"

if [ $# -gt 0 ]; then
  LIST="$*"
else
  LIST=$(awk -F'\t' 'NR>1{print $1}' "$SKILL/cases.tsv")
fi

for c in $LIST; do
  echo "===== $(date -Is) $c ====="
  bash "$SKILL/runner/run_case.sh" "$c"
done
echo "===== ALL DONE $(date -Is) ====="
