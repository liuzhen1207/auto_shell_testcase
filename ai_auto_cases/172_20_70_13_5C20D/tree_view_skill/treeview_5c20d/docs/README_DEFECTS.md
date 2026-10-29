# 树转表视图（Tree View）缺陷复现与报告索引

被测版本：`master_1026_dc11a35`（2.0.11-SNAPSHOT，BuildInfo **dc11a35**）
环境：5 CN + 20 DN，SchemaRegion 3 / DataRegion 3，`IoTConsensus`
报告时间：2026-10-28

## 一、缺陷总览

| 编号 | 标题 | 级别 | 复现状态 | 报告 |
|---|---|---|---|---|
| **TV-D1** | 扩列请求在副本间重复触发 → CN `INTERNAL_SERVER_ERROR(305)` / `COLUMN_ALREADY_EXISTS(552)`，DN 记 ERROR。**已录入 PLM：`TDB-890`**（负责人 陈耀斌，itemId=1485） | P2 | **稳定复现**（批量激活模板 + 连续扩模板，2 副本各 2 条 ERROR） | `DEFECT_TV_D1_final.md` |
| ~~TV-Q1~~（原 TV-D2） | ~~`SET PROPERTIES auto_sync_schema=true` 遇列类型冲突的处理口径~~ | — | **已关闭：研发确认"仅创建时校验类型冲突，其余路径默认忽略"，符合预期** | `OPEN_QUESTION_d2_type_conflict.md`（结论 + A–E 对照表） |
| **TV-D3** | `CREATE VIEW` 的预期失败（同名类型冲突）被 CN 记为 **ERROR**。**已录入 PLM：`TDB-894`**（迭代 V2.0.13.1，负责人 陈耀斌，组长 田原，验证 刘珍，发现版本 V2.0.12.1） | P3 | **稳定复现**（每次必现） | `DEFECT_TV_D3_final.md` |
| **TV-D4** | DataNode 启动窗口内首次登录误报 ERROR「Fail to check password expiration」+ 完整 TimeoutException 堆栈。**已录入 PLM：`TDB-896`**（迭代 V2.0.13.1，负责人 江天，验证 刘珍，发现版本 V2.0.12.1，**P2**） | P2 | 回归中命中 2 次；稳定复现见 TDB-896 的 `AUTH-014` | `DEFECT_TV_D4_final.md` |
| ~~TV-D5~~ | ~~整集群重启后表库/视图丢失~~ | — | **已撤回：误报**（测试并发 prepare 清库所致） | `DEFECT_TV_D5_WITHDRAWN.md` |

> 结论：**没有 P1 级功能缺陷**，树转表特性的功能面全部符合需求。
>
> **当前需要研发处理的只有日志/幂等类问题**：
> - **TV-D1（已录 PLM `TDB-890`，陈耀斌）**：扩列重复请求打 ERROR（305/552）；
> - **TV-D3（`TDB-894`）/ TV-D4（`TDB-896`）/ TV-D6**：可预期失败或幂等情形被记为 ERROR/WARN。
>
> TV-D2（类型冲突静默成功）经确认**不是缺陷**，已撤回；相关用例改为"行为固化"。

## 二、每份报告的结构（统一）

1. **测试环境**：版本/BuildInfo、集群规模、副本数、共识协议、部署路径、每轮准备方式；
2. **测试用例**：可直接复制执行的 SQL，说明"最小触发"；
3. **测试结果**：实际输出 vs 需求/期望输出，逐字给出；
4. **CN/DN 日志取证**：主机、文件名、时间戳、线程名、级别、原始行；
5. **源码取证**：`文件:行` + 代码片段 + i18n 文案；
6. **根因**：从日志现象推导到代码路径；
7. **影响与定级**：功能/日志/告警/排查四维；
8. **修复建议**：按优先级给出改法；
9. **复现方式**：一条命令；
10. **证据索引**：122 上的具体路径。

## 三、复现用例（`scripts/pgkit/cases_tv_repro.py`）

| 用例 | 目的 | 断言口径 |
|---|---|---|
| `TV-REPRO-D1` | 批量激活模板 + 连续扩模板，检查 DN 是否出现 `ViewColumnAutoSyncTrigger` ERROR | 断言"不应出现" ⇒ 出现即 FAIL（缺陷复现） |
| `TV-REPRO-D2` | 视图列 `s1 DOUBLE` vs 树侧 `INT32/INT64`，`set properties auto_sync_schema=true` | 断言"应失败且保持 false" ⇒ 成功即 FAIL |
| `TV-REPRO-D3` | 同名测点类型冲突建视图，检查 CN 是否记 ERROR | 断言"应失败但不应记 ERROR" |
| `TV-REPRO-D4` | 多设备写入 + 跨设备查询，检查 DN 密码过期 ERROR | 断言"不应出现 ERROR" |
| `TV-REPRO-D5` | 4 轮整集群重启，检查表库与视图是否保留 | 断言"4/4 保留" ⇒ 实测 4/4 OK（支撑 D5 撤回） |

运行方式（**严格串行，禁止并发**）：

```bash
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp TV-REPRO-D1
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp TV-REPRO-D2
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp TV-REPRO-D3
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp TV-REPRO-D4
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp TV-REPRO-D5
```

> ⚠️ `prepare` 会 `rm -rf data/`。**同一环境同时只允许一个队列**，否则会互相清库，
> 表现为"元数据丢失"的假缺陷（TV-D5 就是这么产生的）。

## 四、一次完整的回归结论（41 条用例）

- PASS 35 / FAIL 6；
- 6 条 FAIL 全部归属上述缺陷：TV-D1（4 条：SYNC-06/10/11、LEAK-01）、
  TV-D2（1 条：SYNC-13）、TV-D3（1 条：BASE-07）；
- 详见 `REPORT_TREEVIEW_FINAL.md`。
