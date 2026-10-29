#!/bin/bash
# 离线功能验证 run_all.sh 的 case_in_set（纯静态提取 + 调用；不跑任何用例、不碰集群）
set -u
SKILL="${1:-/data/iotdb/autotest/crud_skill}"
sed -n '/^case_in_set(){/,/^}/p' "$SKILL/tools/run_all.sh" > /tmp/cis_extract.sh
. /tmp/cis_extract.sh
ALL="CR-00 CR-01 CR-02 CR-03 CR-04 CR-05 CR-06 CR-07 CR-08 CR-09 CR-10 CR-11 CR-12 CR-13 CR-14"
for s in smoke write delete load object all bogus; do
  SET="$s"; ids=""
  for id in $ALL; do case_in_set "$id" && ids="$ids $id"; done
  printf 'set=%-7s →%s\n' "$s" "$ids"
done
