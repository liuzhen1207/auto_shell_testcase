# 172.16.2.20（3C5D）回归 RUNBOOK

> 本文件说明本环境有哪些套件、如何部署与执行、预期基线。
> 最近一次记录：**2.0.12.1 RC10 `c60ce63`**（delete_skill 全量）／**2.0.13.1 `ab6d3de`**（releasenote_skill TDB-65）。

## 一、环境

| 项 | 值 |
| --- | --- |
| 跳板/客户端 | 172.16.2.20（用例、客户端、证据都在这台） |
| ConfigNode | 172.16.2.16 / .17 / .18（10710） |
| DataNode | 172.16.2.19 / .21 / .22 / .23 / .24（6667；内部 10730） |
| 副本 | SchemaRegion 3 / DataRegion 2 |
| 集群名 | ClusterID3 |
| 数据面协议 | `IoTConsensus` / `IoTConsensusV2` 按轮切换（切换需清数据目录重建） |
| 数据库目录 | `/data1/iotdb/<BUILD_DIR_NAME>` |
| 运行工作目录 | `/data2/iotdb/rc10_matrix`（用例、证据、结果都落这里） |
| 口令 | **不入库**：脚本从 `/data2/auto_test/cluster_shell_3c5d_no3/tc2026_releasenote_testcase/conf/test.conf` 读 `root_pw` |
| 监控 | 每台 DN `http://<ip>:9092/metrics`（直接抓） |

## 二、套件清单

| 模块 | 内容 | 规模 | 单轮耗时 |
| --- | --- | --- | --- |
| `delete_skill/` | DELETE 语义全量回归：内存/落盘/混合、时间与谓词、列类别、OBJECT、mods、恢复、副本、并发、负向、清理、树模型、内存泄漏 | **85 个 CASE ID / 163 个协议轮次**（IoTConsensus 85 + IoTV2 78） | ≈ 40 分钟 |
| `releasenote_skill/` | 发版 Release Note 逐条验证（按 `versions/<版本>/<RN>/` 组织，含报告、脚本、证据） | 当前 1 条：v2.0.13.1 / TDB-65 | 视 RN 而定 |

## 三、换版本部署

```bash
# 1) 上传安装包并解压到 /data1/iotdb/<BUILD_DIR_NAME>（CN、DN 各自节点）
#    客户端解压到 /data2/iotdb/<BUILD_DIR_NAME>/timechodb-<ver>-bin

# 2) 改 delete_skill/conf/env.conf 的版本段
#    BUILD_VERSION / BUILD_COMMIT / BUILD_DIR_NAME / BUILD_HOME / CLIENT_HOME / CLI

# 3) 部署套件到测试机（默认落到 /data2/iotdb/rc10_matrix）
scp -r delete_skill root@172.16.2.20:/tmp/
ssh root@172.16.2.20 "bash /tmp/delete_skill/tools/install.sh"
```

> 协议切换：`IoTConsensus` ↔ `IoTConsensusV2` 需清数据目录后按新协议重建（脚本已封装在集群控制里）。

## 四、回归命令

### 4.1 delete_skill

```bash
# 单例验证链路（约 40 分钟，含完整门禁）
bash /data2/iotdb/rc10_matrix/scripts/run_round.sh IoTConsensus DEL-MEM-001

# 全量（先 IoTConsensus 85 轮，再 IoTV2 78 轮，结束后自动出报告）
setsid nohup bash /data2/iotdb/rc10_matrix/scripts/run_all.sh \
  > /data2/iotdb/rc10_matrix/logs/run-all.nohup 2>&1 &

# 只看失败项重跑 / 单独出报告
bash /data2/iotdb/rc10_matrix/tools/rerun_failures.sh
bash /data2/iotdb/rc10_matrix/tools/make_report.sh

# 内存泄漏专项（独立批次）
bash /data2/iotdb/rc10_matrix/tools/run_memleak_all.sh
```

### 4.2 releasenote_skill

```bash
# 按 RN 的矩阵脚本执行（以 TDB-65 为例）
bash <repo>/releasenote_skill/versions/v2.0.13.1/TDB-65/scripts/run_matrix.sh
```

## 五、预期基线

### 5.1 delete_skill（2.0.12.1 RC10 `c60ce63`）

| 项 | 数值 |
| --- | --- |
| 协议轮次 | 163 / 163 已执行 |
| 通过 | **161** |
| 失败 | 2：`DEL-TREE-002`、`DEL-TREE-004`（同一可复现的 1 秒级 syncLag 尖峰） |
| 累计耗时 | 108h34m（去重；含重跑 122h19m / 184 次执行） |

### 5.2 releasenote_skill（2.0.13.1 RC1 `ab6d3de`）

| RN | 结论 | 说明 |
| --- | --- | --- |
| TDB-65 | 通过 | 见 `versions/v2.0.13.1/TDB-65/release_note_test_report.md` |

### 5.3 已知缺陷

| 缺陷 | 用例 | 现象 |
| --- | --- | --- |
| 见 `delete_skill/docs/DEFECT-metadata-churn-heap-growth.md` | — | 元数据频繁变更导致堆增长（专项文档） |
| DEL-TREE-002 / 004 | 树模型 | 1 秒级 syncLag 尖峰（RC10 已记录，待研发确认是否预期） |

## 六、注意事项

1. **口令不入库**：所有脚本从测试机既有 `conf/test.conf` 读 `root_pw`，不要把口令写进仓库或 env.conf；
2. **产物不入库**：`results/`、`logs/`、`*.out`、`artifacts/` 已在 `.gitignore` 中排除，证据留在测试机；
3. **每轮 ≈ 40 分钟 × 163 轮**：全量超过 4 天，建议 `setsid nohup` 后台跑并定期看 `results/results.tsv`；
4. **协议切换要清数据**，否则旧协议数据目录会干扰新轮次；
5. **门禁**：每轮有 5 道门禁（集群就绪、协议生效、数据落盘、syncLag、证据落盘），失败先看门禁日志再怀疑产品；
6. **RN 目录约定与 205 不同**：本环境 `releasenote_skill` 用 `versions/<版本>/<RN>/`（含 java/scripts/evidence）；205 环境按 `cases/TDB_<编号>_v<版本>.sh`。若要统一，需要一次迁移（见下）。

## 七、待办（可选）

- [ ] 把本环境 `releasenote_skill` 迁移成与 205 一致的 `cases/TDB_<编号>_v<版本>.sh` + `cases.tsv` 结构；
- [ ] delete_skill 的 `env.conf` 版本段改成脚本参数（避免换版本改文件）；
- [ ] 把 205 的 tree_view_skill / auth_skill 引入本环境（若本环境也需要这两块回归）。
