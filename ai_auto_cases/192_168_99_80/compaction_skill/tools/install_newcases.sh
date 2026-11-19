#!/bin/bash
# 把 /tmp/c33_up 里暂存的新文件**原子安装**到 compaction_skill（先 cp 到同目录临时名再 mv）
# 目的：run_all.sh 可能正在跑（bash 边读边执行），必须用 mv 换 inode，不能原地覆盖。
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
U=/tmp/c33_up
set -e
install_one(){ local src=$1 dst=$2
  [ -f "$src" ] || { echo "  缺文件: $src"; return 1; }
  cp -f "$src" "$dst.new.$$"
  sed -i 's/\r$//' "$dst.new.$$"
  mv -f "$dst.new.$$" "$dst"
  echo "  已安装 $dst ($(wc -c <"$dst") B)" ; }
install_one "$U/cases_common_co_repair_unsorted_load.sh" "$S/cases/common/co_repair_unsorted_load.sh"
install_one "$U/cases_common_co_scale_cascade.sh"        "$S/cases/common/co_scale_cascade.sh"
install_one "$U/cases_cases.tsv"                         "$S/cases/cases.tsv"
install_one "$U/tools_run_all.sh"                        "$S/tools/run_all.sh"
install_one "$U/conf_env.conf"                           "$S/conf/env.conf"
mkdir -p "$S/assets/unsorted"
install_one "$U/assets_unsorted_UnsortedTsFileGen.java"  "$S/assets/unsorted/UnsortedTsFileGen.java"
install_one "$U/assets_unsorted_build_gen.sh"            "$S/assets/unsorted/build_gen.sh"
chmod +x "$S/assets/unsorted/build_gen.sh" "$S/cases/common/co_repair_unsorted_load.sh" "$S/cases/common/co_scale_cascade.sh" "$S/tools/run_all.sh"
echo "=== 语法检查 ==="
for f in "$S/cases/common/co_repair_unsorted_load.sh" "$S/cases/common/co_scale_cascade.sh" "$S/tools/run_all.sh" "$S/assets/unsorted/build_gen.sh"; do
  if bash -n "$f"; then echo "  OK   ${f##*/}"; else echo "  FAIL ${f##*/}"; fi
done
echo "=== cases.tsv 行数 ==="; wc -l <"$S/cases/cases.tsv"
echo "=== 新用例是否进了 runner 集合 ==="
grep -n -e repair -e scale "$S/tools/run_all.sh" | head -5
