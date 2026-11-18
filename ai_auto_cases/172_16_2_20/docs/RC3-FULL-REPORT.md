# 2.0.13.1 RC3 全量回归测试报告

- **被测版本**：TimechoDB 2.0.13.1 RC3，build **`ac7f95e`**（源码 HEAD `ac7f95e953`）
- **环境**：3 CN（172.16.2.16/17/18）+ 5 DN（172.16.2.19/21/22/23/24），SR3/DR2
- **部署路径**：`/data1/iotdb/v20131rc3_1117_ac7f95e/timechodb-2.0.13.1-bin`
- **执行时间**：2026-11-18 09:35 ~ 2026-11-19
- **执行人**：刘珍（自动化 skill 回归）

> 本报告在 delete 精选跑完后补全第三节；其余章节已定稿。

## 一、总览

| skill | 用例/轮次 | PASS | FAIL | SKIP | 耗时 | 结论 |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| `ddl_ha_skill` | 33 例 | **33** | 0 | 0 | 2.3h + 复跑 | ✅ 33/33 |
| `releasenote_skill`（RN 冒烟） | 56 项检查（b1~b15） | **46** | 1 | 9 | ~20min + 补跑 | ⚠️ 1 项已知缺口 |
| `releasenote_skill`（专项） | TDB-1104 / TDB-65 / TDB-1050 | 见下 | — | — | — | 2 通过 + 1 待复核 |
| `delete_skill`（RC3 精选） | 12 例 × IoTV2 | 待补 | 待补 | — | ~7h | 跑批中 |

## 二、ddl_ha_skill：33/33 PASS

- 用例：33（本轮新增 `N-012` create_view_race、`X-003` SR 三副本全宕、`X-004` CN 多数派宕机、`X-005` CN 全宕）
- 首轮 30 例：26 PASS；`C-002`（整集群重启）与 `D-002`（DN 重启锁冲突）为 harness 类失败，加固 `cluster_ctl`（并行起 CN）与 `fault.sh`（等锁+重试）后复跑 PASS；
- `X-001/002/003` 的口径经修正后 PASS（详见 `ddl_ha_skill/docs/X-001-002-clarification.md`）；
- 去重后 **33/33 PASS**，结果：`/data2/iotdb/ddl_ha_results_rc3_full/results.tsv`。

关键结论（可用性边界）：

| 故障 | DDL 行为 | 用例 |
| --- | --- | --- |
| DataRegion 双副本全宕（CN 正常） | 成功 | X-001/X-002 |
| SchemaRegion 三副本全宕（CN 正常） | 成功 | X-003 |
| CN 丢多数派（2/3） | 失败（712 超时） | X-004 |
| CN 全宕（3/3） | 失败（305 连接拒绝） | X-005 |

## 三、delete_skill（RC3 精选，跑批中）

待补。

## 四、releasenote_skill：RN 冒烟 + 专项

### 4.1 V2.0.11.1 RN 冒烟（56 项检查）

| 结果 | 数量 |
| --- | ---: |
| PASS | **46** |
| FAIL | 1（`AUDIT-4 CANCEL ALL MIGRATIONS 审计记录` 未命中，与 TDB-709 一致：无独立 CANCEL 事件） |
| SKIP | 9（订阅未开启、region 不足、成本分项等环境项） |

补跑说明：
- `COPY-3 COPY (query) TO` 首跑 725（目标文件已存在 + `copy_to_allowed_export_dirs` 未配置），清理文件、恢复配置后 **PASS**；
- `REG-3 add-peer 取消异常` 首跑命中 4 条 `unexpected consensusGroupId`（RC3，IoTConsensusV2），复跑 **PASS**（1/2 复现，间歇性，数据一致性未受影响）；
- 审计项需要 `enable_audit_log=true`，本轮已恢复。

### 4.2 专项

| 项 | 结果 |
| --- | --- |
| TDB-1050（可写视图 NPE） | **RC3 已修复**（黑盒 10 轮 + 插桩确定性验证，见 `versions/v2.0.13.1/TDB-1050/`） |
| TDB-1104（空 DataRegion Adding 缩容 NPE） | **RC3 PASS**：表模型 9 个空 region、tree 模型 9 个空 region 扩缩容，5 台 DN 合计异常 0 |
| TDB-65（ReadOnly 可观测性） | **待复核**：`SET SYSTEM TO READONLY` 生效（写入报 600），但设置后 2s 内 `SHOW CLUSTER` 仍显示 Running；需等心跳周期后复核 `Status/Reason` 列 |

## 五、发现与建议

| 编号 | 级别 | 内容 | 建议 |
| --- | --- | --- | --- |
| F-1 | 中 | `AUDIT-4`：`CANCEL ALL MIGRATIONS` 无专属审计事件（RC2/RC3 一致） | 研发确认是否补埋点或在文档声明 |
| F-2 | 低 | `REG-3`：EXTEND + CANCEL 间歇出现 `unexpected consensusGroupId` ERROR（V2，1/2 复现，无数据不一致） | 观察项，建议加日志级别或修复竞态 |
| F-3 | 低 | CN 全宕时 DDL 报错为 thrift 原始异常包装（305 + Connection refused） | 封装为“集群元数据不可用” |
| F-4 | 待定 | TDB-65 在 RC3 上 `SHOW CLUSTER` 的 ReadOnly 状态/原因显示需复核（可能是心跳延迟） | 复测确认是否回归 |

## 六、证据路径

| 内容 | 路径 |
| --- | --- |
| ddl_ha 结果 | `/data2/iotdb/ddl_ha_results_rc3_full/results.tsv` |
| RN 冒烟日志 | `/data2/iotdb/rn_rc3_all.log`、`/data2/iotdb/rn_2_0_11_1_rc3*/` |
| TDB-1104 | `/data2/iotdb/tdb1104_rc3.log` |
| delete 精选 | `/data2/iotdb/del_rc3_subset.log`、`/data2/iotdb/rc3_matrix/artifacts/IoTV2/` |
| 报告（仓库） | `ai_auto_cases/172_16_2_20/docs/RC3-FULL-REPORT.md` |
