#!/bin/bash
# 汇总最终结果：从多轮 test_result.csv 里取每个用例**最后一条**记录，生成 results/final_results.csv
# 并把"最终一轮"的原始 CSV 存档，便于交付时区分多轮历史。
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
CSV=$S/results/test_result.csv
OUT=$S/results/final_results.csv
[ -f "$CSV" ] || { echo "找不到 $CSV"; exit 1; }

# 只保留 caseName 形如 CO-XX 的行（run_all 写的），每个取最后一条
awk -F, 'NR==1{print; next} $4 ~ /^CO-[0-9]+$/ {line[$4]=$0} END{for (k in line) print line[k]}' "$CSV" \
  | { echo "caseName,result,elapsedSeconds,failCount,build,consensus,Time"; \
      tail -n +2 | sort -t, -k1,1 | awk -F, '{printf "%s,%s,%s,%s,%s,%s,%s\n", $4,$5,$6,$7,$2,$3,$1}'; } > "$OUT"

echo "=== 最终结果（每个用例最后一条）==="
column -s, -t "$OUT" 2>/dev/null || cat "$OUT"
echo
echo "通过数：$(awk -F, 'NR>1 && $2=="PASS"' "$OUT" | wc -l) / $(awk -F, 'NR>1' "$OUT" | wc -l)"
echo "FAIL 数：$(awk -F, 'NR>1 && $2=="FAIL"' "$OUT" | wc -l)"
cp -p "$CSV" "$S/results/test_result_all_rounds.csv"
echo "多轮原始记录已存档：results/test_result_all_rounds.csv"
