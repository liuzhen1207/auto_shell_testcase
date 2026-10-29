#!/bin/bash
# 复现失败序列：U01（含停/重启集群）→ S01，验证日志归属修复
cd /data/iotdb/autotest/metadata_skill || exit 1
export MD_NO_STOP_AFTER=1
for c in common/md_udf_trigger common/md_scale_bulk; do
  n=$(basename "$c")
  echo "##### $n $(date '+%F %T')"
  bash "cases/$c.sh" --skip-lifecycle </dev/null >"results/LOGFIX_${n}.out" 2>&1
  grep -E 'RESULT (PASS|FAIL)' "results/LOGFIX_${n}.out" | tail -1 | sed -E 's/^\[[^]]*\] //'
  grep -E '^\[.*\] FAIL' "results/LOGFIX_${n}.out" | sed -E 's/^\[[^]]*\] //' | head -5
  grep -E '日志(无异常|基线)' "results/LOGFIX_${n}.out" | tail -3 | sed -E 's/^\[[^]]*\] /    /'
done
echo "LOGFIX DONE $(date '+%F %T')"
