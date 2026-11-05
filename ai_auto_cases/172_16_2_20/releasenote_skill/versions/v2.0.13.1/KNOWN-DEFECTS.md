# v2.0.13.1 已登记缺陷

本版本回归过程中发现并已录入 PLM 的缺陷。后续 RC/版本回归时按此清单复核。

| 缺陷 | 优先级 | 标题 | 发现方式 | 影响用例 | 状态 |
| --- | --- | --- | --- | --- | --- |
| [TDB-939](https://plm.infra.timecho.com/iterations?productId=1&itemId=1562) | P1 | DELETE 后紧跟 FLUSH 时删除标记未落盘，已删数据重新可见且多副本不一致 | DELETE 全量回归（IoTConsensus 85 轮，2026-11-02~11-05） | `DEL-PRED-007` / `008`、`DEL-MEMLEAK-TABLE-001` / `002`、`DEL-MEMLEAK-TREE-001` / `002` / `003`（7/85 轮，复跑 **7/7 全部复现**） | 排期确认（负责人 江天，迭代 V2.0.15.1） |

## 严重性升级：删除永久丢失（2026-11-05 19:57 复核）

复跑 14:08 结束后集群未再重启。`DEL-MEMLEAK-TABLE-002`（整表 `DELETE FROM t;`，用例内返回 `count=0`）4 小时后复核：

| 时间点 | 结果 |
| --- | --- |
| 删除后（用例内） | `count=0` ✅ |
| 5 分钟后快照 | `count=4` |
| 五台 DN 重启后 | `count=1` |
| **4 小时后、未重启** | **`count=1`（五台 DN 一致）** |

幸存行 `2027-01-05T06:00:00.108 / d8 / 108` 永久存活；DN23 上该表 2 个 TsFile 均无 `.mods2`。**删除丢失不可通过重启恢复**，WAL（20 秒清理）与共识日志（snapshot 截断）越过后即为永久失效。

## 复核要点（下一版本回归时）

1. 跑 `delete_skill` 的 `DEL-PRED-007`、`DEL-PRED-008`（表模型，DELETE 后紧跟 FLUSH），确认不再出现 `FAIL_DN_DIFF`。
2. 同一轮内检查各 DataNode 是否都生成了对应的 `*.tsfile.mods2`（本次复现时 5 台 DN 只有 2 台有）。
3. 复核删除后 5 分钟的快照查询行数是否与删除后立即查询一致（本次 3 行 → 14 行）。
4. 复核不重启节点时的持久性：删除后等待超过 WAL 清理周期（默认 20 秒）与一次快照，再查仍应为删除后的结果——本次 4 小时后仍有 1 行未被删除。

## 详细材料

- 缺陷报告（含时间线证据、代码定位、修复建议）：`../../delete_skill/docs/DEFECT-TDB-939-delete-vs-flush-mods.md`
- 回归全量报告：`../../delete_skill/docs/RC10-DELETE-REPORT.md`（RC1 部分见测试机 `/data2/iotdb/rc10_matrix/report/RC10-DELETE-REPORT.md`）
- 证据目录（测试机 172.16.2.20）：`/data2/iotdb/rc10_matrix/artifacts/IoTConsensus/DEL-PRED-008/`
