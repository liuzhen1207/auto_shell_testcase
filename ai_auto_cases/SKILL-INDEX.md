# ai_auto_cases 全部 skill 用例清单

> 用途：回归前先看这张表，确认"哪些 skill、多少用例、上次在哪个版本验过、还有什么没验"，避免遗漏。
> **维护规则**：任何 skill 增删用例、或在一个新版本上跑完回归后，都要回来更新本表。
> 最后更新：2026-11-17（delete_skill 新增 12 例并完成 RC2 两协议 24 轮）。

## 一、本机（172.16.2.20 / 3C5D）——主力回归环境

集群：3 CN（.16/.17/.18）+ 5 DN（.19/.21/.22/.23/.24），SR3 / DR2，IoTConsensus / IoTConsensusV2。

| skill | 用例数 | 协议轮次 | 最近验证版本 | 最近回归 | 状态 | 文档 |
| --- | ---: | ---: | --- | --- | --- | --- |
| `delete_skill` | **97** | **187**（V1 97 + V2 90） | 2.0.13.1 RC2 `83183d0` | 2026-11-17 | ✅ 已跑完 | [README](172_16_2_20/delete_skill/README.md) |
| `ddl_ha_skill` | **29** | 29（V1） | 2.0.13.1 RC2 `83183d0` | 2026-11-11 | ✅ 已跑完 | [报告](172_16_2_20/ddl_ha_skill/docs/REPORT-RC2.md) |
| `releasenote_skill` | 1 RN（TDB-65） | — | 2.0.13.1 RC1 `ab6d3de` | 2026-11-05 | ✅ 已验并回填 PLM | [README](172_16_2_20/releasenote_skill/README.md) |

### delete_skill 最近一次全量（2.0.13.1 RC2，163 轮 → 现 187 轮）

| 协议 | 轮次 | 通过 | 失败 | 耗时 |
| --- | ---: | ---: | ---: | ---: |
| IoTConsensus | 97 | 91 | 6 | 56.57h（85 例部分）+ 新增 12 轮 |
| IoTConsensusV2 | 90 | 90 | 0 | 51.99h（78 例部分）+ 新增 12 轮 |

失败 6 例：`DEL-PRED-007`、`DEL-MEMLEAK-TREE-001/002/003`、`DEL-MEMLEAK-TABLE-001/002` —— 前 5 个属 **TDB-939**（行级删除标记丢失），`TREE-003` 为恢复窗口 lag 尖峰。

### 本轮新增用例（2026-11-16，共 12 例 / 24 轮全 PASS）

`DEL-DEV-001~009`（设备级删除全场景）、`DEL-NEG-004/005`（measurement 条件、标识条件非 `= `）、`DEL-TIME-010`（多时间段 OR）。

关键对照：`DELETE DEVICES` 在"删除 + FLUSH"时序下**不复现** TDB-939，说明设备级删除走不同落盘路径。

## 二、其他测试床（不在本 3C5D 上，勿混跑）

| 床 | skill | 用例数 | 说明 |
| --- | --- | ---: | --- |
| 172.16.2.205 | `lbac_skill` | 196 | LBAC 权限，2.0.13.1 |
| 172.16.2.205 | `releasenote_skill` | 146 | RN 逐条验证（含 TDB343 等），2.0.13.1 |
| 172.16.2.205 | `tree_view_skill` | 71 | 树转表视图 |
| 172.16.2.205 | `auth_skill` | 39 | 权限/鉴权，2.0.12.1 |
| 172.16.2.7 | `proactive_regiongroup_skill` | 脚本型（6 个 sh） | RegionGroup 主动扩容 |
| 172.16.2.7 | `qa_liuzhen_skill` | 脚本型（4 个 sh） | QA 记录 |
| 172.20.70.3 | `memory_buffer_skill` | 30 | 内存缓冲 |
| 172.20.70.3 | `query_schedule_skill` | 21 | 查询调度 |
| 172.20.70.3 | `region_migrate_skill` | 7 | Region 迁移 |
| 172.20.70.13 | `tree_view_skill` | 脚本型（23 个 sh） | 树转表视图 |
| 172.20.70.13 | `proactive_skill` | 脚本型（1 个 sh） | 主动扩容 |
| 172.20.70.17 | `proactive_regiongroup_skill` | 脚本型（223 个 sh） | RegionGroup 扩容（DELL R730） |
| 172.20.70.17 | `crud_skill` / `remove_cn_dn_skill` | 脚本型 | CRUD / 摘除节点 |
| 192.168.99.80 | `compaction_skill` | 102 | 在线合并（2.0.12.1，单机） |
| 192.168.99.80 | `metadata_skill` | 51 | 元数据 DDL（2.0.12.1） |
| 192.168.99.80 | `wal_skill` | 38 | WAL（2.0.12.1） |
| 192.168.99.80 | `sec_skill` | 35 | 安全（2.0.14.1，含 TDB-1606） |
| 192.168.99.80 | `ttl_skill` | 28 | TTL |
| 192.168.99.80 | `crud_skill` | 27 | CRUD |
| 192.168.99.80 | `treeview_skill` | 21 | 树转表视图 |
| 192.168.99.80 | `diskusage_skill` | 11 | 磁盘占用 |

> 这些床的 skill 绑定各自的 IP/拓扑/单机或集群形态，**不能直接搬到 3C5D**；要用需先移植脚本里的主机路径与拓扑假设。

## 三、回归前检查清单

1. **看本表第一段**：确认要回归的 skill 与用例数；
2. **确认版本**：`SHOW CLUSTER` 的 `BuildInfo` 必须等于目标 build（如 `83183d0`），否则先修部署；
3. **确认环境干净**：无残留 `iptables` 规则、无其他版本的 DN 进程（见 [`docs/package-deploy-activation.md`](172_16_2_20/docs/package-deploy-activation.md)）；
4. **跑完更新本表**：用例数、轮次、通过/失败、总耗时、最近验证版本；
5. **失败处理**：执行器已内置"失败即备份节点日志"（`<case>/logs/`），归因前先看 [`docs/defect-attribution-playbook.md`](172_16_2_20/docs/defect-attribution-playbook.md)。

## 四、已知缺口（待补）

| 缺口 | 说明 |
| --- | --- |
| `C-002` 整集群重启后元数据持久 | ddl_ha_skill 中该用例仍 FAIL_EXPECT（重启流程起不来），需先加固 cluster_ctl stop/start |
| Python / Go / C++ 客户端 | 本机无对应运行时，RN 的接口矩阵只覆盖 CLI / Java Session / JDBC |
| REST 接口 | 2.0.13.1 发行包不含 `org.apache.iotdb.rest.RestService`，启用后 DN 无法启动 |
| `DEL-MEMLEAK-TREE-003` | FAIL_OUTAGE 为 lag 尖峰（2.0s），未定性，建议单独跟踪 |
| 其他床 skill 移植到 3C5D | 需要时按 §二 说明逐个移植，优先 `remove_cn_dn_skill`、`memory_buffer_skill` |

## 五、如何更新本表

用例数可用下面命令快速统计（在仓库根目录）：

```bash
for d in ai_auto_cases/*/*_skill; do
  n=$(awk 'NF' "$d/cases.tsv" 2>/dev/null | tail -n +2 | wc -l)
  c=$(ls -d "$d"/cases/*/ 2>/dev/null | wc -l)
  echo -e "$d\ttsv=$n\tdirs=$c"
done
```

轮次：delete_skill 的 `manifest-IoTConsensus.tsv` / `manifest-IoTV2.tsv` 行数即协议轮次。
