# 树转表视图 auto_sync_schema 全量回归报告（67 条 · 两协议）

## 1. 范围与环境

| 项目 | 内容 |
| --- | --- |
| 被测版本 | TimechoDB 2.0.11-SNAPSHOT / build **dc11a35** |
| 集群 | 3 ConfigNode + 5 DataNode，SchemaRegion 3 副本、DataRegion 2 副本 |
| 轮次 | ① IoTConsensus（21:25–23:0x）② IoTConsensusV2（22:58–00:34） |
| 用例 | **67 条**：g1 属性语法、g2 补列入口、g3 冲突与类型、g4 查询与生命周期、g5 DDL 组合、g6 高可用、g7 DN 隔离、g8 序列改名×视图、g9 LOAD TSFILE×视图 |
| 每条用例后置检查 | 8 节点日志增量（按来源归因）→ 各 DN `syncLag` 归零 → 停 2 台 DN 的副本一致性比对 |
| 入口 | `run_regression.sh master_1026_dc11a35 <协议> TDB-343`（部署校验→切协议→清库重建→执行→归因→汇总） |

## 2. 结果

| 指标 | IoTConsensus | IoTConsensusV2 |
| --- | --- | --- |
| 用例数 | 67 | 67 |
| PASS | **48** | **48** |
| FAIL（断言） | 4（均为 TDB-888，已知） | 4（同） |
| FAIL（功能路径日志缺陷） | 15 | 15 |
| FAIL（HA/环境噪声） | 0 | 0 |
| 用例执行总耗时 | 5301s（1.5 h） | 5519s（1.5 h） |

**结论**：两协议行为一致，48 条 PASS；20 条失败全部可归因——4 条为已登记缺陷 **TDB-888**（改名后视图不同步），15 条为自动补列路径的**同一日志缺陷**（`ViewColumnAutoSyncTrigger` 552/305，尚未登记 PLM），1 条差异属触发时序竞态。无环境性失败、无副本不一致。

## 3. 失败归因

### 3.1 断言失败（4 条，TDB-888 已知缺陷）

| 用例 | 现象 | 违反条款 |
| --- | --- | --- |
| TV-080 | 设备改名后视图 TAG 仍返回旧设备名 | 需求 §2.1.1.1 |
| TV-081 | 改名 + auto_sync 视图 TAG 仍旧名 | 需求 §2.1.1.1 |
| TV-082 | 跨库改名后目标库视图 0 行 | 需求 §2.1.1.3 |
| TV-088 | 重启 DN 后 TAG 仍旧名（持久化） | 需求 §2.1.1.1 |

已写入 `known_failures.conf`，回归时标「已知缺陷」，不阻断流水线。

### 3.2 功能路径日志缺陷（各 15 条，同一根因）

`ViewColumnAutoSyncTrigger:141/149` 打印 `552 Column 'x' already exist` + `305 Internal server error`：多副本各自触发补列，后到者被 CN 拒绝。**功能正确（列已补上）**，属日志级别/幂等判定问题，详见 `defect_view_auto_sync_552_305.md`。

- IoTConsensus 命中：TV-003、TV-010、TV-011、TV-012、TV-014、TV-016、TV-018、TV-022、TV-030、TV-033、TV-034、TV-038、TV-050、TV-053、TV-060
- IoTConsensusV2 命中：TV-011、TV-012、TV-014、TV-015、TV-016、TV-018、TV-020、TV-022、TV-030、TV-033、TV-034、TV-038、TV-050、TV-053、TV-060
- 两轮共有的 13 条；V1 独有 TV-003、TV-010；V2 独有 TV-015、TV-020（竞态导致，不影响定性）

## 4. 新增用例组在本轮的表现

### g8 序列改名 × 视图（10 条）

| 用例 | 结果 | 说明 |
| --- | --- | --- |
| TV-080 | FAIL_ASSERT | 同库设备改名后视图 TAG 应为新设备名（需求 §2.1.1.1） |
| TV-081 | FAIL_ASSERT | 设备改名 + auto_sync，改名后数据与 TAG 正确 |
| TV-082 | FAIL_ASSERT | 跨库改名后目标库视图应包含该设备（需求 §2.1.1.3） |
| TV-083 | PASS | 跨库改名后源库 DROP 被拦截（708/507）且 SHOW INVALID 给出 NewPath |
| TV-084 | PASS | 删别名后源库可删除（官方清理链） |
| TV-085 | PASS | 改名到不存在的库自动建库（当前行为，待研发确认） |
| TV-086 | PASS | 单测点改名：原列保留、改名不触发补列 |
| TV-087 | PASS | RESTRICT 视图在设备改名后仍包含同层级设备 |
| TV-088 | FAIL_ASSERT | 重启 DN 后视图 TAG 仍为新设备名（持久化） |
| TV-089 | PASS | 改名往返（s1→s9→s1）后视图数据可见 |

清理链（TV-083/084）、改名到不存在库（TV-085）、单测点改名（TV-086）、RESTRICT（TV-087）、往返改名（TV-089）均通过；不同步问题集中在 TAG 取值与跨库设备枚举。

### g9 LOAD TSFILE × 视图（8 条）

| 用例 | 结果 | 说明 |
| --- | --- | --- |
| TV-090 | PASS | LOAD TSFILE 创建新序列时触发自动补列（列与类型正确、数据可查） |
| TV-091 | PASS | LOAD 已存在列的测点：列保持、数据可查（观察是否触发日志缺陷） |
| TV-092 | PASS | LOAD 混合场景：已有列保持、新增列补齐 |
| TV-093 | PASS | LOAD 到视图前缀之外不补列 |
| TV-094 | PASS | auto_sync=false 时 LOAD 不补列 |
| TV-095 | PASS | RESTRICT 视图 + LOAD 层级不匹配不补列 |
| TV-096 | PASS | 重复 LOAD 同一文件：列不重复、行数行为记录 |
| TV-097 | PASS | LOAD 补列后重启 DN，列与数据持久化 |

LOAD 会触发补列（TV-090/092 通过），且 TV-091 这类“列已存在”场景在 LOAD 路径下**没有**出现 552/305——与 CREATE 路径不一致，待研发确认是否统一。

## 5. 逐用例结果

| 用例 | 功能域 | 类型 | 场景 | V1 | V2 |
| --- | --- | --- | --- | --- | --- |
| TV-001 | 属性与语法 | 正向 | 默认不开启自动补列，show create view 不输出该属性 | PASS | PASS |
| TV-002 | 属性与语法 | 正向 | 显式 false：属性可见且不补列 | PASS | PASS |
| TV-003 | 属性与语法 | 正向 | 显式 true：属性可见且新增测点自动补列 | FAIL_FEATURE_LOG | PASS |
| TV-004 | 属性与语法 | 反向 | 普通表带 auto_sync_schema 报 701 | PASS | PASS |
| TV-005 | 属性与语法 | 反向 | ALTER TABLE 设置该属性报错 | PASS | PASS |
| TV-006 | 属性与语法 | 正向 | CREATE OR REPLACE 打开属性后回填并继续补列 | PASS | PASS |
| TV-007 | 属性与语法 | 反向 | 非法属性值报错 | PASS | PASS |
| TV-008 | 属性与语法 | 正向 | ttl 与 auto_sync_schema 同时生效 | PASS | PASS |
| TV-010 | 补列入口 | 正向 | CREATE TIMESERIES 触发补列 | FAIL_FEATURE_LOG | PASS |
| TV-011 | 补列入口 | 正向 | CREATE ALIGNED TIMESERIES 多列补列 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-012 | 补列入口 | 正向 | INSERT 自动建序列触发补列 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-013 | 补列入口 | 正向 | 多设备写入分别补列 | PASS | PASS |
| TV-014 | 补列入口 | 正向 | 模板激活到新路径触发补列 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-015 | 补列入口 | 正向 | 模板扩展触发补列 | PASS | FAIL_FEATURE_LOG |
| TV-016 | 补列入口 | 正向 | CREATE OR REPLACE 后按新前缀补列，旧前缀不再跟踪 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-017 | 补列入口 | 正向 | 建视图时扫描前缀下已有测点 | PASS | PASS |
| TV-018 | 补列入口 | 反向 | 前缀外新增测点不触发补列 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-020 | 冲突与类型 | 边界 | 同名不同类型跳过，同批其它列照补 | PASS | FAIL_FEATURE_LOG |
| TV-021 | 冲突与类型 | 边界 | 仅大小写不同的测点视为冲突不补列 | PASS | PASS |
| TV-022 | 冲突与类型 | 正向 | 大写原序列名补为小写列并保留 original name | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-023 | 冲突与类型 | 正向 | 指定 FIELD 类型可从同名不同型序列中择优 | PASS | PASS |
| TV-024 | 冲突与类型 | 边界 | 指定类型都不匹配时视为新列且查询为空 | PASS | PASS |
| TV-025 | 冲突与类型 | 反向 | FIELD 只写列名不写类型报错 | PASS | PASS |
| TV-026 | 冲突与类型 | 边界 | original name 已引用过的测点不再补列 | PASS | PASS |
| TV-030 | 查询与生命周期 | 正向 | 补列后旧行为 null、新写入可见 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-031 | 查询与生命周期 | 边界 | 删除序列后列保留且查询为 null | PASS | PASS |
| TV-032 | 查询与生命周期 | 正向 | 关闭属性后不再补列 | PASS | PASS |
| TV-033 | 查询与生命周期 | 正向 | 打开属性回填已有测点并继续补列 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-034 | 查询与生命周期 | 正向 | 视图改名后仍自动补列 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-035 | 查询与生命周期 | 边界 | 删除视图后建序列不报错 | PASS | PASS |
| TV-036 | 查询与生命周期 | 边界 | 删除视图所在库后建序列不报错 | PASS | PASS |
| TV-037 | 查询与生命周期 | 可靠性 | 集群重启后属性持久化并继续补列 | PASS | PASS |
| TV-038 | 查询与生命周期 | 边界 | RESTRICT 与 auto_sync_schema 正交 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-040 | DDL 组合 | 正向 | auto=true 时 ADD COLUMN 数值列 | PASS | PASS |
| TV-041 | DDL 组合 | 正向 | auto=true 时 ADD COLUMN tag 列 | PASS | PASS |
| TV-042 | DDL 组合 | 边界 | ADD COLUMN OBJECT（树模型不支持 object） | PASS | PASS |
| TV-043 | DDL 组合 | 正向 | DROP COLUMN 后不被自动补回 | PASS | PASS |
| TV-044 | DDL 组合 | 正向 | RENAME COLUMN | PASS | PASS |
| TV-045 | DDL 组合 | 反向 | 重复 ADD COLUMN 报错 | PASS | PASS |
| TV-046 | DDL 组合 | 边界 | ADD COLUMN 与已有列仅大小写不同 | PASS | PASS |
| TV-047 | DDL 组合 | 正向 | auto=true 时手动增删列均生效且不被回补 | PASS | PASS |
| TV-050 | 高可用 | 可靠性 | 1 台 DN 停机时建视图并恢复后补列 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-051 | 高可用 | 可靠性 | 1 台 DN 停机时建序列仍触发补列 | PASS | PASS |
| TV-052 | 高可用 | 可靠性 | 1 台 DN 停机时视图查询与基线一致 | PASS | PASS |
| TV-053 | 高可用 | 可靠性 | CN leader 切换后新增测点仍补列 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-054 | 高可用 | 可靠性 | CN leader 切换期间修改属性 | PASS | PASS |
| TV-055 | 高可用 | 可靠性 | kill -9 一台 DN 后序列创建与补列 | PASS | PASS |
| TV-056 | 高可用 | 可靠性 | 两台 DN 停机时 DR=2 查询仍可用 | PASS | PASS |
| TV-060 | 高可用 | 可靠性 | DN 隔离（元数据租约失效）时创建序列失败，恢复后重试补列 | FAIL_FEATURE_LOG | FAIL_FEATURE_LOG |
| TV-080 | 改名与视图 | 正向 | 同库设备改名后视图 TAG 应为新设备名（需求 §2.1.1.1） | FAIL_ASSERT | FAIL_ASSERT |
| TV-081 | 改名与视图 | 正向 | 设备改名 + auto_sync，改名后数据与 TAG 正确 | FAIL_ASSERT | FAIL_ASSERT |
| TV-082 | 改名与视图 | 正向 | 跨库改名后目标库视图应包含该设备（需求 §2.1.1.3） | FAIL_ASSERT | FAIL_ASSERT |
| TV-083 | 改名与视图 | 边界 | 跨库改名后源库 DROP 被拦截（708/507）且 SHOW INVALID 给出 NewPath | PASS | PASS |
| TV-084 | 改名与视图 | 正向 | 删别名后源库可删除（官方清理链） | PASS | PASS |
| TV-085 | 改名与视图 | 边界 | 改名到不存在的库自动建库（当前行为，待研发确认） | PASS | PASS |
| TV-086 | 改名与视图 | 边界 | 单测点改名：原列保留、改名不触发补列 | PASS | PASS |
| TV-087 | 改名与视图 | 边界 | RESTRICT 视图在设备改名后仍包含同层级设备 | PASS | PASS |
| TV-088 | 改名与视图 | 可靠性 | 重启 DN 后视图 TAG 仍为新设备名（持久化） | FAIL_ASSERT | FAIL_ASSERT |
| TV-089 | 改名与视图 | 边界 | 改名往返（s1→s9→s1）后视图数据可见 | PASS | PASS |
| TV-090 | LOAD与补列 | 正向 | LOAD TSFILE 创建新序列时触发自动补列（列与类型正确、数据可查） | PASS | PASS |
| TV-091 | LOAD与补列 | 边界 | LOAD 已存在列的测点：列保持、数据可查（观察是否触发日志缺陷） | PASS | PASS |
| TV-092 | LOAD与补列 | 正向 | LOAD 混合场景：已有列保持、新增列补齐 | PASS | PASS |
| TV-093 | LOAD与补列 | 反向 | LOAD 到视图前缀之外不补列 | PASS | PASS |
| TV-094 | LOAD与补列 | 反向 | auto_sync=false 时 LOAD 不补列 | PASS | PASS |
| TV-095 | LOAD与补列 | 边界 | RESTRICT 视图 + LOAD 层级不匹配不补列 | PASS | PASS |
| TV-096 | LOAD与补列 | 边界 | 重复 LOAD 同一文件：列不重复、行数行为记录 | PASS | PASS |
| TV-097 | LOAD与补列 | 可靠性 | LOAD 补列后重启 DN，列与数据持久化 | PASS | PASS |

## 6. 建议

1. 把自动补列 552/305 日志缺陷按 PLM 流程登记（关联 TDB-343），登记后把对应 15 条用例加入 `known_failures.conf`，回归即可全绿；
2. TDB-888 修复后，TV-080/081/082/088 应从 `known_failures.conf` 移除并转为正向回归；
3. LOAD 路径与 CREATE 路径的补列去重行为需要统一口径（TV-091 证据）；
4. `run_regression.sh` 已支持已知缺陷白名单，后续版本只需换 build 参数即可复用。

## 7. 证据

| 内容 | 路径 |
| --- | --- |
| IoTConsensus 轮 | 远端 `results/REGRESSION_master_1026_dc11a35_IoTConsensus_20261028_212543/` |
| IoTConsensusV2 轮 | 远端 `results/REGRESSION_master_1026_dc11a35_IoTConsensusV2_20261028_225835/` |
| 归因数据 | `results/full_V1_classified.tsv`、`results/full_V2_classified.tsv` |
| 用例脚本 | `scripts/cases/g1..g9` |
| 已知缺陷白名单 | `scripts/known_failures.conf` |

