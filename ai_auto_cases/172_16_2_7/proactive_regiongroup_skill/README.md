# PROACTIVE RegionGroup 分配策略用例

## 范围

覆盖 TimechoDB 2.0.13.1（RC1 `ab6d3de`、RC2 `83183d0`）的 `PROACTIVE` 扩容策略：

- 默认值、显式 AUTO/CUSTOM、热更新、非法值；
- 计数：不同 slot 数 → 组数、Schema/Data 上限、多库分摊、共槽、封顶；
- 分配与恢复：新组承接后续时间分区、重平衡阈值、INHERIT/SHUFFLE、CN 重启/切主；
- 资源上限与节点变化：`data_region_per_data_node`、remove/add DataNode；
- 升级/回退：RC12→RC1、RC1→RC12、RC12→RC2；
- 故障注入：建组中停 DN、重启 CN、kill Leader；
- 权限/审计：SYSTEM 权限、DDL/DML/QUERY/CONTROL 审计字段；
- CUSTOM 规则：独立于资源公式、ALTER 只能升不能降。

## 结果摘要（RC2 `83183d0`）

| 项 | 结果 |
| --- | --- |
| 通过 | 18 条 |
| 部分通过 | 2 条（混合版本、审计字段已澄清） |
| 未执行 | 性能对比、2 旧 CN 混合、6D/9D |
| 确认非缺陷 | CUSTOM 不受资源上限约束、`MAX_*` 低于默认被拒绝 |
| 缺陷 | TDB-1047：混合版本 SET CONFIGURATION 部分应用；追加验证旧 CN 接管后 PROACTIVE 退化为 AUTO（P2） |

汇总全文见 `results/RC2-测试结果汇总-20261110.md`。

## 目录

- `cases/`：用例设计（3C5D 可执行版、扩充版、升级方案）；
- `results/`：RC1/RC2 执行记录、汇总、审计字段；
- `defects/`：TDB-1047 与 CUSTOM 分析/草稿；
- `scripts/`：执行脚本（计数、节点变化、升级等）；
- `evidence/`：混合版本复现日志包 `mixed_repro_20261110.tar.gz`。

## 运行约定

- 环境：3C5D，`/data1/iotdb/<version>`，`/data1/iotdb` 为数据盘挂载点（fstab UUID）；
- 脚本通过跳板机 172.16.2.7 执行，集群节点 root/`1Qaz2wsx`；
- 配置类用例前建议 `qa_fresh` 清空数据，避免多库分摊影响 cap。
