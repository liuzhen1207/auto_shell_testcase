#!/bin/bash
# 批量安装"官方覆盖度补齐"用例（CO-35~CO-42）并做语法/自检。
# 约定：新脚本先 scp 到 99.80 的 /tmp/c33_up/，文件名与最终名一致。
#   scp 全部 co_*.sh + cases.tsv -> root@192.168.99.80:/tmp/c33_up/
#   ssh ... 'bash /data/iotdb/autotest/compaction_skill/tools/install_official_cases.sh'
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
U=/tmp/c33_up
FILES="co_target_split_formula.sh co_fast_fake_overlap.sh co_aligned_grouping.sh co_level_search_gate.sh co_priority_rules.sh co_recovery_branches.sh co_object_ttl.sh co_fast_vs_default_perf.sh"

echo "=== 1) 安装用例脚本（同目录 .new + mv 原子替换）==="
ok=0; miss=0
for f in $FILES; do
  if [ ! -f "$U/$f" ]; then echo "  [缺] $U/$f"; miss=$((miss+1)); continue; fi
  cp -f "$U/$f" "$S/cases/common/$f.new"
  sed -i 's/\r$//' "$S/cases/common/$f.new"
  mv -f "$S/cases/common/$f.new" "$S/cases/common/$f"
  chmod +x "$S/cases/common/$f"
  printf '  [装] %-34s %s B\n' "$f" "$(wc -c <"$S/cases/common/$f")"
  ok=$((ok+1))
done
echo "  已安装 $ok 个，缺 $miss 个"

echo "=== 2) 安装 cases.tsv（若已上传）==="
if [ -f "$U/cases.tsv" ]; then
  cp -f "$U/cases.tsv" "$S/cases/cases.tsv.new"
  sed -i 's/\r$//' "$S/cases/cases.tsv.new"
  mv -f "$S/cases/cases.tsv.new" "$S/cases/cases.tsv"
  echo "  cases.tsv 行数=$(wc -l <"$S/cases/cases.tsv")"
else
  echo "  （未上传 cases.tsv，跳过）"
fi

echo "=== 3) bash -n 语法检查 ==="
bad=0
for f in $FILES; do
  [ -f "$S/cases/common/$f" ] || continue
  if bash -n "$S/cases/common/$f" 2>/tmp/synerr; then
    printf '  OK   %s\n' "$f"
  else
    printf '  FAIL %s -> %s\n' "$f" "$(head -2 /tmp/synerr | tr '\n' ' ')"
    bad=$((bad+1))
  fi
done
echo "  语法失败 $bad 个"

echo "=== 4) harness 自检（无集群）==="
cd "$S" || exit 1
SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh 2>&1 | tail -4
echo "=== 5) 新用例是否归入 --set official ==="
grep -n 'official)' tools/run_all.sh | head -2
