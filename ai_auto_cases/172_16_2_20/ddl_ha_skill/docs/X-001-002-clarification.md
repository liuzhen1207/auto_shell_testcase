# X-001 / X-002 口径澄清：DR 双副本全宕时 DDL 仍然成功

> 状态：**待产品确认**（2026-11-18）。本文只陈述事实与建议，不自行改判定。
> 关联：`DDLHA-X-001`（DROP TABLE）、`DDLHA-X-002`（DELETE DEVICES），故障均为 `dr_both_down`。

## 一、文档要求（用例设计依据）

`DDLHA-X-001/002` 的 `spec.env` 中 `EXPECT=fail_expected`，即按 DDL 高可用要求：**表的两个 DataRegion 副本所在 DataNode 同时宕机时，该表上的 DDL 应当失败**（避免在数据不可用的表上做元数据变更）。

## 二、RC3 实际行为（2026-11-18，build `ac7f95e`）

| 用例 | 操作 | 预期 | 实际 | 耗时 |
| --- | --- | --- | --- | --- |
| `DDLHA-X-001` | `DROP TABLE`（DR 双副本全宕） | 失败 | **成功**（`Msg: The statement is executed successfully.`） | 148s |
| `DDLHA-X-002` | `DELETE DEVICES FROM t WHERE dev='dev02'`（DR 双副本全宕） | 失败 | **成功**，返回 `num_of_deleted_devices = 1` | 173s（含 25s 分区等待） |

RC2（`83183d0`）上表现相同，因此不是 RC3 引入的变化。

## 三、为什么“成功”可能合理

1. **DDL 走 ConfigNode 元数据共识**：表/设备的元数据变更由 ConfigNode（Ratis）提交，不依赖 DataRegion 副本是否存活；
2. **元数据仍一致**：这两种操作完成后，各 DataNode 的 `SHOW TABLES` / `SHOW DEVICES` 结果一致（校验通过）；
3. **数据层影响有限**：DR 双副本全宕只影响该 region 的读写；DDL 成功后若副本恢复，元数据变更仍然有效；
4. 对比 `P-002`（分区 DN 上 add_column）：该场景已按“任意失败即可”放宽，说明团队对“元数据面 vs 数据面”已有类似取舍。

## 四、需要谁决定什么

| 选项 | 含义 | 影响 |
| --- | --- | --- |
| A. 更新文档（推荐） | 明确“DR 副本全宕不阻塞表级 DDL（元数据面操作），仅数据面读写受影响” | 用例改为 `EXPECT=success`，X-001/002 转 PASS |
| B. 收敛实现 | DDL 前检查目标表 DR 副本可用性，任一 region 无可用副本则拒绝 | 需要新增可用性检查，可能影响正常缩容/迁移窗口内的 DDL |

**建议 A**：当前行为与 ConfigNode 元数据共识模型一致，且元数据一致性校验通过；强制依赖 DataRegion 可用性会让“副本临时不可用”时的改名/删表等操作被无故阻塞。

## 五、证据

| 内容 | 位置 |
| --- | --- |
| 结果行 | `/data2/iotdb/ddl_ha_results_rc3_full/results.tsv`（X-001/002 均为 `FAIL_NO_ERROR`） |
| 执行输出 | `/data2/iotdb/ddl_ha_results_rc3_full/DDLHA-X-001/sql.out`、`.../DDLHA-X-002/sql.out` |
| 用例定义 | `ddl_ha_skill/cases/DDLHA-X-001/spec.env`、`.../DDLHA-X-002/spec.env` |
