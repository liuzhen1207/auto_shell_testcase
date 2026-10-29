#!/bin/bash
# 收尾：汇总 final_results.csv（含 DT 批）+ 打包 DT 最终证据
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd "$S" || exit 1
echo "=== 1) 汇总 final_results.csv ==="
bash tools/merge_final_results.sh 2>&1 | tail -25
echo
echo "=== 2) 取每个 DT 用例的**最后一条** canonical 输出，打包 ==="
TMP=$(mktemp -d)
for c in dt_tree_basic dt_tree_negative dt_tree_compaction dt_tree_concurrent dt_table_basic dt_table_compaction dt_view dt_ha_disk_ro dt_ha_stop_nodes; do
  f=$(ls -t results/${c}_IoTConsensus_*.out 2>/dev/null | head -1)
  if [ -n "$f" ]; then cp -p "$f" "$TMP/"; else echo "  缺 $c 的输出"; fi
done
cp -p results/final_results.csv results/test_result.csv results/test_result_all_rounds.csv "$TMP/" 2>/dev/null
for f in $(ls -t results/NEWCHAIN_20261014_*.out | head -8); do cp -p "$f" "$TMP/"; done
cp -p results/CO17_final.out "$TMP/" 2>/dev/null
tar czf results/DT_final_evidence.tgz -C "$TMP" .
rm -rf "$TMP"
ls -lh results/DT_final_evidence.tgz
echo
echo "=== 3) 最终结果总览 ==="
cat results/final_results.csv
echo
awk -F, 'NR>1{n++; if($2=="PASS")p++} END{printf "PASS=%d / 共 %d\n", p, n}' results/final_results.csv
