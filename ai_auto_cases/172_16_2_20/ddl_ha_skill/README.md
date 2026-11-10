# ddl_ha_skill — DDL 高可用回归（3C5D / SR3 / DR2）

面向需求《DDL 高可用》（PingCode `RD/T79TdX5O`）：**表模型元数据操作在 DN 宕机或网络分区时仍能成功**，并对分区 DN 给出明确的隔离提示。

## 需求点映射

| 需求点（文档章节） | 内容 | 对应用例 |
| --- | --- | --- |
| §3.2.1 创建/修改 | 建表、加列、改列类型、可写视图（建/改名/加列/改列名）、TTL 设置与取消、删库、删设备 | `DDLHA-N-001~011`、`DDLHA-D-001~009` |
| §3.2.2 删除操作 | 删表、删可写视图（含 `schema_cascade` 级联） | `DDLHA-N-008/009`、`DDLHA-D-007` |
| §3.2.1 场景 1 | **输入 SQL 前有 DN 宕机** → 期望执行成功（旧行为：失败回滚） | `DDLHA-D-001~009` |
| §3.2.1 场景 2 | **一个 DN 处于网络分区** → 正常 DN 执行成功；连分区 DN 的操作抛出隔离异常 | `DDLHA-P-001~004` |
| §3.2.2 注意 | 删除类 procedure 在 >1/2 副本不可用时可能失败，且不回滚，需用户感知并重试 | `DDLHA-X-001~002` |
| §3.2.3 异常情况 | 连分区 DN：数据面报"隔离"，元数据面报"无法连接 CN" | `DDLHA-P-002`（元数据）、`DDLHA-P-003`（数据） |
| §3.2.4 新增配置 | `metadata_lease_fence_ms=20000` 自我隔离时长 | `DDLHA-P-*`（分区后等待 25s 触发） |
| §3.3 非功能 | 元数据/写入/查询/视图/同步等兼容性 | 全量用例的元数据与数据一致性校验 |

## 用例分组（29 个）

| 组 | 数量 | 说明 |
| --- | ---: | --- |
| `normal` | 11 | 无故障基线：每条 DDL 正常执行 + 元数据/数据一致性 |
| `dn_down` | 9 | SQL 前 kill 一台持有 SchemaRegion 副本的 DN，期望**执行成功** |
| `partition` | 4 | 分区一台 DN（阻断与 3 台 CN 的 10710）：正常 DN 成功、分区 DN 报隔离、恢复后收敛 |
| `extreme` | 2 | 表的两台 DataRegion 副本全部宕机时执行删除类 procedure，期望失败且不回滚、用户可感知 |
| `ha_event` | 3 | DDL 期间杀 CN leader、DDL 后整集群重启（元数据是否持久）、并发两条 DDL |

## 每轮的判定维度

1. **SQL 结果**：成功 / 失败（负向用例要求失败且报错类型符合预期）
2. **元数据一致性**：5 台 DN 上 `SHOW TABLES` 与 `SHOW CREATE TABLE` 归一化后必须完全一致，且期望对象（表/视图/列/TTL）符合
3. **数据一致性**：5 台 DN 上 `count(*)` 与按设备分组计数必须一致
4. **集群日志**：扫描 6 台节点的 ERROR，白名单外的异常计入 `LOG_SUSPECT`

判定码：`PASS` / `FAIL_SQL` / `FAIL_NO_ERROR` / `FAIL_ERROR_KIND` / `FAIL_META` / `FAIL_DATA` / `FAIL_EXPECT` / `FAIL_LOG` / `FAIL_RESET`。

## 目录

| 路径 | 说明 |
| --- | --- |
| `cases.tsv` | 用例矩阵（case_id / group / op / fault / timing / expect / verify / db） |
| `cases/<ID>/spec.env` | 用例参数（操作、故障类型、目标、期望） |
| `cases/<ID>/setup.sql` | 故障注入前的准备 SQL |
| `cases/<ID>/sql.sql` | 受测 DDL |
| `cases/<ID>/verify.sql` | 校验查询（可选） |
| `tools/gen_cases.py` | 用例生成器（改矩阵后重新生成） |
| `tools/lib.sh` | 公共变量与查询函数 |
| `tools/fault.sh` | 故障注入与恢复（kill DN/CN、iptables 分区、双副本宕机） |
| `tools/check_meta.sh` / `check_data.sh` / `log_scan.sh` | 三类校验 |
| `runner/run_case.sh` / `run_all.sh` | 单用例执行 / 全量执行 |
| `conf/env.conf` | 地址与门禁参数（不含口令） |

## 运行

```bash
# 全量（测试机 172.16.2.20）
bash /data2/iotdb/ddl_ha_skill/runner/run_all.sh
# 指定用例
bash /data2/iotdb/ddl_ha_skill/runner/run_all.sh DDLHA-N-001 DDLHA-D-001
# 单用例
bash /data2/iotdb/ddl_ha_skill/runner/run_case.sh DDLHA-P-002
```

结果写入 `/data2/iotdb/ddl_ha_results/results.tsv`，每例证据在 `/data2/iotdb/ddl_ha_results/<CASE>/`：
`setup.out`、`sql.out`、`fault.txt`、`meta-consistency.txt`、`data-consistency.txt`、`log-scan.txt`、`round.log`。

## 环境

| 项 | 值 |
| --- | --- |
| 版本 | TimechoDB 2.0.13.1 RC1（`ab6d3de`） |
| 拓扑 | 3 CN（.16/.17/.18）+ 5 DN（.19/.21/.22/.23/.24） |
| 副本 | SchemaRegion 3、DataRegion 2 |
| 协议 | IoTConsensus（V1） |
| 隔离参数 | `metadata_lease_fence_ms` 默认 20000（未显式配置） |

## 结果（2026-11-10，29 例）

| 分组 | 用例 | PASS | 非 PASS |
| --- | ---: | ---: | --- |
| normal | 11 | 10 | 1（心跳异常） |
| dn_down | 9 | 8 | 1（DN 重启竞态） |
| partition | 4 | 2 | 2（隔离提示缺失 / 白名单） |
| extreme | 2 | 0 | 2（优于预期，判定口径） |
| ha_event | 3 | 1 | 2（重启竞态 / 整集群重启未恢复） |

**核心结论：DN 宕机前置的 9 类 DDL 全部成功，元数据与数据在 5 台 DN 上始终一致。**

详细结论、缺陷候选与证据索引见 [`docs/REPORT.md`](docs/REPORT.md)。
