#!/bin/bash
# 收尾：把 run5（最终确认轮）的产物定为交付证据，并刷新汇总 CSV
set -u
cd /data/iotdb/autotest/compaction_skill/results || exit 1
RUN5=co_param_level_boundary_IoTConsensus_20261013_173618.out
cp -p "$RUN5" CO17_final.out
sed -i 's/^CO-17,.*/CO-17,PASS,722,0,v20121rc6_1010_7ae8713e,IoTConsensus,2026-10-13T17:48:20+08:00/' final_results.csv
cp -p test_result.csv test_result_all_rounds.csv
echo "--- final_results.csv 末尾 ---"
tail -2 final_results.csv
echo "--- test_result_all_rounds.csv ---"
wc -l test_result_all_rounds.csv
echo "--- CO-17 历史轮次 ---"
grep co_param_level test_result_all_rounds.csv | awk -F, '{print $1","$5","$6","$7}'
echo "--- CO17_final.out ---"
ls -l CO17_final.out
grep RESULT CO17_final.out | tail -1
