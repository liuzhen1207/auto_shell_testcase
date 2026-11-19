# ai_auto_cases 全部 skill 用例清单

> 用途：回归前先看这张表，确认"哪些 skill、多少用例、上次在哪个版本验过、还有什么没验"，避免遗漏。
> **维护规则**：任何 skill 增删用例、或在一个新版本上跑完回归后，都要回来更新本表。
> 最后更新：2026-11-17（delete_skill 新增 12 例并完成 RC2 两协议 24 轮）。
> 范围：仅本机 172.16.2.20（3C5D）的三个 skill，不包含其他测试床。

## 一、本机（172.16.2.20 / 3C5D）——主力回归环境

集群：3 CN（.16/.17/.18）+ 5 DN（.19/.21/.22/.23/.24），SR3 / DR2，IoTConsensus / IoTConsensusV2。

| skill | 用例数 | 协议轮次 | 最近验证版本 | 最近回归 | 状态 | 文档 |
| --- | ---: | ---: | --- | --- | --- | --- |
| `delete_skill` | **44 定义 / 186 轮** | RC3 精选 **12 轮 IoTV2** | 2.0.13.1 RC3 `ac7f95e` | 2026-11-19 | ✅ 精选 12/12 PASS（全量 186 轮待续） | [RC3 报告](172_16_2_20/docs/RC3-FULL-REPORT.md) |
| `ddl_ha_skill` | **33**（含 `N-012`、`X-003/004/005`） | 33（V1） | 2.0.13.1 RC3 `ac7f95e` | 2026-11-18 | ✅ **33 PASS / 0 失败** | [报告](172_16_2_20/ddl_ha_skill/docs/REPORT-RC3.md) |
| `releasenote_skill` | **2 RN** + **V2.0.11.1 批量**（147 RN：117 可测 / 30 受限，14 项冒烟全 PASS）+ 1 变体 | — | 2.0.13.1 RC2 `83183d0` | 2026-11-17 | ✅ 均已验 | [README](172_16_2_20/releasenote_skill/README.md) |

### delete_skill 最近一次全量（2.0.13.1 RC2，163 轮 → 现 187 轮）

| 协议 | 轮次 | 通过 | 失败 | 耗时 |
| --- | ---: | ---: | ---: | ---: |
| IoTConsensus | 97 | 91 | 6 | 56.57h（85 例部分）+ 新增 12 轮 |
| IoTConsensusV2 | 90 | 90 | 0 | 51.99h（78 例部分）+ 新增 12 轮 |

失败 6 例：`DEL-PRED-007`、`DEL-MEMLEAK-TREE-001/002/003`、`DEL-MEMLEAK-TABLE-001/002` —— 前 5 个属 **TDB-939**（行级删除标记丢失），`TREE-003` 为恢复窗口 lag 尖峰。

### 本轮新增用例（2026-11-16，共 12 例 / 24 轮全 PASS）

`DEL-DEV-001~009`（设备级删除全场景）、`DEL-NEG-004/005`（measurement 条件、标识条件非 `= `）、`DEL-TIME-010`（多时间段 OR）。

关键对照：`DELETE DEVICES` 在"删除 + FLUSH"时序下**不复现** TDB-939，说明设备级删除走不同落盘路径。

## 二、范围说明

本清单只维护本机 **172.16.2.20（3C5D）** 上的回归 skill（`delete_skill`、`ddl_ha_skill`、`releasenote_skill`）。其他测试床（172.16.2.205 / 172.20.70.x / 192.168.99.80 等）的 skill 不在本清单维护范围内，也不再作为回归候选。


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
