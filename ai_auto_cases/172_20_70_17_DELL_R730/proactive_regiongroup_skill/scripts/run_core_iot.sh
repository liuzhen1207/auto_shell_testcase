#!/usr/bin/env bash
set -u
cd /home/ubuntu/remove_cn_dn/pg_build/iotdb-proactive-regiongroup
L=/home/ubuntu/remove_cn_dn/pg_build/core_iot.log
say() { echo "$(date '+%F %T')  $*" >> "$L"; }
say "==== prepare：停集群 → 清 data/logs → 写 conf（time_partition_interval=604800000 等）→ 启动"
bash scripts/pg.sh --conf conf/cluster.pg_dev_iot.conf prepare >> "$L" 2>&1
say "prepare rc=$?"
say "==== core 轮（P0+P1，209 条中的 core 层）"
bash scripts/pg.sh --conf conf/cluster.pg_dev_iot.conf matrix --tier core --run-id pg_core_iot2 >> "$L" 2>&1
say "core rc=$?"
D=$(ls -dt results/pg_core_iot* 2>/dev/null | head -1)
[ -n "$D" ] && bash scripts/pg.sh --conf conf/cluster.pg_dev_iot.conf report "$D" >> "$L" 2>&1 && say "report 已生成: $D/REPORT.md"
say "==== 全部结束"
