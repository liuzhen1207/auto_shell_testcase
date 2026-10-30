# RegionGroup 积极扩容（PROACTIVE）回归 skill

被测特性：`schema_region_group_extension_policy` / `data_region_group_extension_policy = PROACTIVE`
（RegionGroup 按需积极扩容）。测试形态：3 ConfigNode + 5 DataNode，schema RF=3 / data RF=2，
IoTConsensus 与 IoTConsensusV2 双协议，覆盖默认值、空库/非空库、不同 slot 与同 slot 设备扩容、
单设备多测点（1 → 50 万测点跨时间分区）、资源上限与多库共享、min-group 增长、AUTO/CUSTOM/PROACTIVE 切换、
分配策略 rebalance 与 ConfigNode 恢复、Disabled 回退、高可用（只读 DN、建组过程中停机）、TTL/DELETE 交互、
系统库、整集群重启、1.3 → 2.0 升级。

- 用例数：**216**（目录见 `CATALOG.md`；`cases/` 下每例一个包装脚本，`testcase_ok_list.txt` 为全量清单）
- 判定规格：`references/proactive-spec.md`；参数灯：`references/proactive-knobs.md`；用例族写法：`references/family-authoring.md`
- 本轮执行结论：`REPORT.md`、`FINAL_SUMMARY.md`、`FINAL_ROUND_REPORT.md`；缺陷候选：`DEFECT_CANDIDATES.md`
- 升级族实测：`升级族_两阶段实测_029A333.md`、`MASTER_029A333_全量回归.md`

## 快速开始

```bash
# 0) 选一台能免交互 ssh 到全部集群主机的机器，把本包拷过去
# 1) 改 conf/nodes.conf（拓扑）与 conf/cluster.*.conf（版本包路径、协议、RF）
export CONF=conf/cluster.pg_2011snap_iot.conf

bash scripts/pg.sh --conf $CONF doctor        # 环境自检
bash scripts/pg.sh --conf $CONF deploy        # 部署 + 装 license
bash scripts/pg.sh --conf $CONF prepare       # 清空集群
bash scripts/pg.sh --conf $CONF matrix --tier smoke --run-id my_001
bash scripts/pg.sh --conf $CONF report results/my_001

# 或一键（doctor → prepare → matrix → report）
bash run_all_proactive.sh full
```

单例：

```bash
bash cases/PG-SMK-01.sh          # 等价于 scripts/pg.sh --conf ... run --case PG-SMK-01
```

## 目录

```
conf/            17 个档位 conf（默认值/自定义/AUTO/非法值/slot100/双协议/升级/3C4D 等）+ nodes.conf 拓扑
scripts/pg.sh    入口（→ python3 -m pgkit）
scripts/pgkit/   用例引擎：pgapi 观测层、slots 槽计算、cases 判定与收尾三件套、cases_* 八个用例族
cases/           216 个单用例包装脚本
testcase_ok_list.txt  216 条用例清单
run_all_proactive.sh  一键回归
references/      规格、参数灯、用例族写法、license 激活、文档缺口
docs/            TDB-367 回归报告
```

## 约定

- **凭据**：`conf/cluster.*.conf` 里 `SSH_PASSWORD` 一律留空，请用免密公钥（`SSH_MODE=key`）或自行填入本地密码，不要把密码提交回仓库。
- **运行产物**不提交：`results/`、`__pycache__/`、`*.pyc` 已在 `.gitignore` 中。
- 文档里出现的 `/home/ubuntu/remove_cn_dn/...` 是出报告时的控制机路径，仅用于溯源；实际运行以 `scripts/pg.sh` / `run_all_proactive.sh` 为准。
