---
name: iotdb-proactive-regiongroup
description: Deploy a TimechoDB/IoTDB release from a tarball onto given hosts (ssh key or password, install path), activate the licence, configure schema/data replication factors and the data-region consensus protocol, then regression-test the PROACTIVE (积极扩容) RegionGroup extension policy end to end on a real 3-ConfigNode + 5-DataNode cluster: default policy readback, empty/non-empty databases, distinct-slot vs co-slot device scaling, single-device multi-measurement load (1 → 500k measurements across time partitions), resource upper limits and multi-database sharing, min-group incremental growth, AUTO/CUSTOM/PROACTIVE switching, allocation-policy rebalance and ConfigNode recovery, Disabled fallback, high availability (readonly DN, stopped CN/DN during group creation), TTL/DELETE interaction, system databases, whole-cluster restart, upgrade 1.3 → 2.0 and dual consensus protocol (IoTConsensus then IoTConsensusV2) runs — as a conf-driven, IP-agnostic, Chinese-report case matrix.
---

# iotdb-proactive-regiongroup

TDB-367「RegionGroup 积极扩容模式 PROACTIVE」的**可逐版本回归**技能。一句话口径：

> **组数只由"同类型不同 series slot 数（K）"与资源上限（R）决定**，
> 与设备数、测点数、时间分区数无关；且**只增不减**。

* 判定口径（唯一来源）：`references/proactive-spec.md`
  （由 PLM docs/360 需求、docs/341 技术设计、docs/127 分槽验证、RN TDB-367 + 源码逐行核对蒸馏）
* 用例目录：`references/case-catalog.md`；族模块编写规范：`references/family-authoring.md`
* 槽计算：`scripts/pgkit/slots.py`（BKDR131，与 docs/360 §3.5 例子逐值一致）
* 报告（中文，含需求点覆盖矩阵与结论）：`docs/报告_TDB-367_PROACTIVE回归.md`
* 台账：`references/doc-gaps.md`（文档不一致 G-01..G-10）、`DEFECT_CANDIDATES.md`、`HARNESS_FINDINGS.md`

## License / 激活（每次换 DB_DIR 都要做）

激活只需在**一台 ConfigNode** 提交一次激活码即全集群生效，但**每个节点**都要有
`<DB_DIR>/activation/license`（升级档位的 `DB_DIR=/data/mpp_test/pg_upg_13` 与默认目录不同，
旧激活态不会带过来 ⇒ 曾导致升级轮反复 `801: Authentication failed`）。各节点可用的本地源、
手工补齐命令与 kit 的自动做法（`LICENSE_SRC` + `ensure_license()`）见
`references/license-activation.md`。**注意：`.6`/`.10` 的本地 license 不要使用。**

## 快速开始

```bash
cd iotdb-proactive-regiongroup

bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf selftest    # 离线自检（不连集群）
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf doctor      # 集群/依赖体检（只读）
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf list-cases  # 列用例
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf catalog --out CATALOG.md  # 中文用例目录

# 一轮完整回归（IoTConsensus）
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf deploy                      # 上传+解包+激活 licence
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf prepare                     # 停→清 data/logs→写 conf→起
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf matrix --tier smoke         # gate 用例
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf matrix --tier core          # P0+P1（默认）
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf matrix --tier full          # 全部
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf report results/<run_id>    # 生成 REPORT.md

# 单条 / 按领域
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf run --case PG-SMK-04 --case PG-LIM-03
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf matrix --area 高可用 --tier full

# 换协议（IoTConsensusV2）——独立数据目录，需重新 deploy+prepare
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iottv2.conf deploy && \
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iottv2.conf prepare
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iottv2.conf matrix --tier smoke --run-id pg_smoke_v2

# 收尾（必须让 5 台机器 java 进程归零）
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf teardown
```

## 配置档位（conf/cluster.*.conf）

| 档位 | 用途 |
| --- | --- |
| `cluster.pg_2011snap_iot.conf` | 正式回归（IoTConsensus），结果目录 `/data/deepseek/proactive/results` |
| `cluster.pg_2011snap_iottv2.conf` | 正式回归（IoTConsensusV2；Schema 区仍必须 Ratis） |
| `cluster.pg_dev_iot.conf` | 开发/长跑（结果目录在工作区），语义与正式档相同 |
| `cluster.pg_default_iot.conf` | **默认值路径**：不写策略键 ⇒ 验证代码默认 PROACTIVE |
| `cluster.pg_auto_iot.conf` / `cluster.pg_custom_iot.conf` | AUTO / CUSTOM 对照 |
| `cluster.pg_slot100_iot.conf` | `series_slot_num=100`，少量设备即可造大量不同槽 |
| `cluster.pg_badcase_iot.conf` | 非法值 conf 路径（小写 `proactive`） |
| `cluster.pg_upg13_iot.conf` | 升级族：先 1.3.7，再就地升级 2.0.11 |

## 纪律（每条都有实测教训，不得简化）

1. **每用例干净起手**：`prepare` = 停集群 → 清 `data`/`logs` → 写 conf → 启集群；集群级参数
   （`series_slot_num`、副本数、共识协议、`time_partition_interval`）只能重启生效，用例自证读回。
   长跑矩阵在同一档位内保持集群运行（用例之间只清测试库），换档位必须重跑 `prepare`。
2. **收尾三件套**（runner 自动追加，任一不过整例不得 PASS）：
   ① sync lag 持续归 0（`SYNC_STABLE_SECONDS=60`，超时 FAIL 并记最差值）→
   ② 副本一致性：**全在线基线**（每个存活 DN 各查一遍）→ **停 `CONSISTENCY_STOP_NODES`(默认 1) 台 DN**
   再查一遍并比对 → ③ CN/DN 日志 ERROR/WARN 扫描（NPE/数组越界/运行时异常单列）。
3. **日志三档**：未预期 → `log_findings.txt`；harness 动作窗口内 → `log_attributed.txt`（逐条留原文）；
   产品自声明可忽略（需源码出处）→ `log_by_design.txt`（仅 WARN）。**无全局白名单**。
4. **SKIP ≠ PASS**；前置被不可逆污染记 `INVALID`；缺档位/缺包必须 SKIP 并写明原因。
5. **假 PASS 与假 FAIL 同样不可接受**：期望值只来自 spec 公式（`expected_cap()` / `min(K,R)`），
   不得依赖环境相关观察（region 物理放置、节点编号、设备名与组号对应关系）。
6. **集群独占**：一个集群同时只能有一个 runner。并发跑负向 SQL/子代理操作集群，会把
   `ConfigExecution` WARN 打进他人用例窗口造成**假 FAIL**（实测教训，见 `HARNESS_FINDINGS.md` H-05）。
7. 结论要有实锤：每条断言附 SQL 原文与输出、区域快照、日志原文与行号。

## 关键观测口径

| 事项 | 口径 |
| --- | --- |
| 组数 | **`SHOW DATABASES DETAILS` 的 `SchemaRegionGroupNum`/`DataRegionGroupNum`**（直接可观测）；与 `SHOW … REGIONS` 去重 `RegionId` 交叉校验。副本行数 = 组数 × 副本数 |
| 上限 | 同表的 `MaxSchemaRegionGroupNum`/`MaxDataRegionGroupNum`，应等于 `max(min, ceil(weight×resource/(分摊库数×rf)))` |
| 分摊库数 | 树 + 表两类普通库**合并**计数（`SHOW DATABASES DETAILS` 按方言过滤，故 harness 取并集） |
| 树/表方言 | 树：`SHOW DATA REGIONS OF DATABASE <db>`、`SHOW DATA REGIONID WHERE DEVICE=`；表：`SHOW DATA REGIONS FROM <db>`；**表方言不支持 `… REGIONID`/`SHOW TIMESLOTID`** |
| 时间分区 | `SHOW TIMESLOTID WHERE …`、`COUNT TIMESLOTID WHERE …`（树）；长度实测 `TimePartitionInterval`（**毫秒**） |
| 策略热加载 | `SET CONFIGURATION '<key>'='<value>'`：一次一个键、不允许 `ON <nodeId>`、需 SYSTEM 权限、全集群一致；非法值不落盘 |
| 设备落组 | `SHOW DATA REGIONID WHERE DEVICE=<path>`（树） |
| 双盘 | `dn_data_dirs` 指向 `/data/...` 与 `/ssd_data/...` 两个**目录**；本环境无独立 SSD（`/ssd_data` 落在 `sda`），只验证"多目录"语义 |
| 权限用例 | 普通用户 `pg_normal`（无 SYSTEM）与 `pg_system`（有 SYSTEM），由用例创建/清理 |
| 大规模写入 | ≥1 万测点用客户端 benchmark（`PG_BENCH_V20_DIR` 表模型 / `PG_BENCH_V13_DIR` 树模型，`PG_BENCH_SSH` 登录） |
| 升级用例 | 需 1.3 包（`PG_UPGRADE_FROM_TARBALL`）+ 2.0 包（`PG_UPGRADE_TO_TARBALL`）；缺包时 `PG-UPG-*` 整族 SKIP 并写明 |

## 目录结构

```
conf/            9 个档位 conf + nodes.conf + bench_template.properties
scripts/pg.sh    wrapper → python3 -m pgkit
scripts/pgkit/   pgapi.py(操作+观测层) slots.py(BKDR131 槽计算) cases.py(核心 runner/夹具/收尾三件套)
                 cases_{cfg,dev,msr,lim,ops,ops2,swch,upg}.py(用例族, 暴露 SPECS)
                 cluster.py deploy.py upgrade.py verify.py pgprops.py cli.py config.py helpers.py remote.py
references/      proactive-spec.md(判定规格+实测修正) case-catalog.md(用例目录) family-authoring.md
                 proactive-knobs.md doc-gaps.md(G-01..G-10)
docs/            需求/设计/自测文档原文、RN JSON、本任务的执行报告
results/         每轮 run_dir（run.log / summary.json / REPORT.md / cases/<id>/{result.json,actions.log,evidence/}）
```

## 版本与来源

| 项 | 值 |
| --- | --- |
| 被测产物 | `timechodb-2.0.11-SNAPSHOT-bin.zip`（master `3bbeea656114`） |
| 升级前产物 | `iotdb-enterprise-1.3.7-SNAPSHOT-bin.zip` |
| 需求 | PLM docs/360；技术设计 docs/341；分槽验证 docs/127 |
| RN | TDB-367（P0，新功能，V2.0.13.1，负责人 王頔，验证 刘珍） |
| 集群 | 3 CN（11.101.10.9/.8/.7）+ 5 DN（11.101.10.9/.8/.7/.6/.10），schema RF=3、data RF=2 |
| 协议 | 先 `IoTConsensus`，后 `IoTConsensusV2` |
