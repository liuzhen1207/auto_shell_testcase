#!/usr/bin/env bash
# 自动接力：等 IoT core 轮结束 → V2 冒烟轮 → 1.3→2.0 升级两阶段。
# 为什么必须串行：3 个 CN + 5 个 DN 共用固定端口（CN 10720 / DN MPP 10740-10760 /
# metrics 9091-9092 不可配），任何两轮并发都会互相污染甚至起不来。
set -u
cd /home/ubuntu/remove_cn_dn/pg_build/iotdb-proactive-regiongroup
L=/home/ubuntu/remove_cn_dn/pg_build/pipeline.log
PG="bash scripts/pg.sh"
say() { echo "$(date '+%F %T')  $*" >> "$L"; }

say "== 等待 IoT core 轮（pg_core_iot2）结束"
while [[ ! -f /home/ubuntu/remove_cn_dn/pg_build/results/pg_core_iot2/summary.json ]]; do
  pgrep -f "pgki[t]" >/dev/null || { say "  runner 已不在，视为结束/中断"; break; }
  sleep 120
done
say "core 轮结束：$(python3 -c "
import json,collections
d=json.load(open('/home/ubuntu/remove_cn_dn/pg_build/results/pg_core_iot2/summary.json'))
print(dict(collections.Counter(r['status'] for r in d['cases'])))" 2>/dev/null || echo '无 summary')"

# ---- 阶段②：V2 冒烟（含 teardown 主集群 + 独立 DB_DIR 部署）
say "== 阶段② V2 冒烟轮"
bash /home/ubuntu/remove_cn_dn/pg_build/run_v2_smoke.sh
say "  V2 轮结束 rc=$?（收尾① 预期被 D-06 卡住，功能断言仍会执行）"

# ---- 阶段③：1.3 → 2.0 升级（两阶段就地升级）
say "== 阶段③ 升级轮 pre（部署 1.3.7 + 写 conf + 启动）"
$PG --conf conf/cluster.pg_2011snap_iottv2.conf teardown >> "$L" 2>&1
$PG --conf conf/cluster.pg_upg13_iot.conf upgrade >> "$L" 2>&1
say "  pre rc=$?"
PRE=$(ls -dt results/*upgrade* results/pg_upgrade 2>/dev/null | head -1)
$PG --conf conf/cluster.pg_upg13_iot.conf matrix --tier full --area 升级 --run-id pg_upg_pre >> "$L" 2>&1
say "  pre 用例 rc=$?（PG-UPG-01..07 生效，08..16 按阶段 SKIP）"
say "== 阶段③ 升级轮 post（就地覆盖 2.0.11，保留 data/）"
$PG --conf conf/cluster.pg_upg20_iot.conf upgrade >> "$L" 2>&1
say "  post rc=$?"
$PG --conf conf/cluster.pg_upg20_iot.conf matrix --tier full --area 升级 --run-id pg_upg_post >> "$L" 2>&1
say "  post 用例 rc=$?"
for d in results/pg_upg_pre* results/pg_upg_post* results/pg_smoke_v2b*; do
  [ -d "$d" ] && $PG --conf conf/cluster.pg_dev_iot.conf report "$d" >> "$L" 2>&1
done
say "==== 全流水线结束"
