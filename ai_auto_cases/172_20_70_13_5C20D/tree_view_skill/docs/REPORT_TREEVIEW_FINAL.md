# 树转表视图（Tree View）测试最终报告

- 版本：`master_1026_dc11a35`（2.0.11-SNAPSHOT，BuildInfo **dc11a35**）
- 环境：5 ConfigNode + 20 DataNode，**SchemaRegion 3 副本 / DataRegion 3 副本**，共识 `IoTConsensus`（默认）
- 用例集：`scripts/pgkit/cases_treeview.py`（**41 条**）
- 执行方式：每条用例**干净集群**（停 25 节点 → 清 data/logs → 写 conf → 启动）→ 用例 →
  收尾三件套 → FAIL 自动备份 CN/DN 日志
- 收尾三件套：① syncLag 归 0；② 副本一致性（**全在线结果为基线 → 一次性停 2 台 DN** 再查同一数据集逐字比对）；
  ③ CN/DN ERROR·WARN 扫描（按 harness 动作窗口归因）

## 1. 总览

| 项 | 数量 |
|---|---|
| 用例总数 | 41 |
| **PASS** | **35** |
| FAIL | 6 |
| 其中：**TDB-890（已录 PLM）** | 5 条（SYNC-06/10/11/13、LEAK-01）——功能全过，仅日志 ERROR |
| 其中：TV-D3（日志级别，P3） | 1 条（BASE-07） |
| 其中：用例/框架缺陷 | 0（执行中发现的 10 处已全部修正并复跑通过） |

| 统计口径 | 值（50 次用例执行） |
|---|---|
| 停 2 台 DN 的副本一致性对拍 | 全部"各副本结果一致" |
| syncLag 归 0 | 全部达成（worst 观测 2.0） |
| 停 1 台 DN / 停 2 台 DN 期间扩列 | 通过 |
| 整集群重启（共 8 次，含专项 4 轮） | **全部通过**（唯一一次"丢库"已查明为测试并发事故，见 TV-D5 撤回说明） |
| 线程泄漏 | 无（3485 → 3425，递减） |

## 2. 缺陷清单

| 编号 | 标题 | 级别 | 影响用例 |
|---|---|---|---|
| **TV-D1** | 模板激活扩列时同一操作在两副本各触发一次，去重与幂等过滤未生效 → CN 返回 `INTERNAL_SERVER_ERROR(305)` + `COLUMN_ALREADY_EXISTS(552)`，DN 记 2 条 ERROR。**已录入 PLM：`TDB-890`（陈耀斌，itemId=1485）** | P2 | TV-SYNC-06、TV-SYNC-10、TV-SYNC-11、TV-LEAK-01 |
| ~~TV-D2~~ | ~~`SET PROPERTIES auto_sync_schema=true` 遇列类型冲突静默成功~~ | — | **已关闭：研发确认符合预期**——「**仅创建视图时校验类型冲突，其余路径默认忽略**」；TV-SYNC-13 改为行为基线，功能断言全过，仅因 **TDB-890** 日志判 FAIL |
| **TV-D3** | `CREATE VIEW` 因同名测点类型冲突失败（**符合需求**）时，CN 记为 ERROR（302/614）+ procedure 回滚堆栈 | P3 | TV-BASE-07 |
| **TV-D4** | 登录/查询时密码过期检查失败记为带栈 ERROR（`DataNodeAuthUtils:522`，与特性无关） | P3 | 已加白名单，不再影响判定 |
| ~~TV-D5~~ | ~~整集群重启后表库/视图丢失~~ | — | **已撤回：误报**（并发 `prepare` 清库所致，见 `DEFECT_TV_D5_WITHDRAWN.md`） |

> 说明：**没有 P1 级功能缺陷**。TV-D1/D3/D4 属日志与可观测性；TV-D2 是"需求 vs 实现"的语义偏差。
> 树转表特性本身的主流程**全部符合需求**（见 §3）。
> 每条缺陷都有独立报告（含环境/SQL/输出/日志/源码定位/根因/修复建议），索引见 `README_DEFECTS.md`。

## 3. 需求点覆盖与结论

### 3.1 docx 需求（基础树转表视图）

| 需求点 | 用例 | 结论 |
|---|---|---|
| CREATE VIEW 语法（TAG/FIELD/TIME、FROM、COMMENT、RESTRICT、WITH） | BASE-01/04/05/15 | ✅ |
| prefixPath 必须以 `**` 结尾、其它层不得含 `*` | BASE-02 | ✅（3 类非法值均被拒绝） |
| 未指定 FIELD 时扫描全部测点并推断类型 | BASE-03/REF-04 | ✅（省略 dataType 也能推断） |
| 列不支持 ATTRIBUTE | BASE-05 | ✅ 报错 |
| RESTRICT 只含层级等于 tag 数的设备 | BASE-06/REF-02 | ✅（2 TAG + 3 层设备口径） |
| 同名不同类型 / 扫不到测点 → 报错 | BASE-07/08 | ✅ 均报错（但见 TV-D3 的日志问题） |
| OR REPLACE / 与 base table 重名 | BASE-09 | ✅ |
| 视图 TTL 生效且不改变树 TTL | BASE-10 | ✅ |
| 对齐设备全 null 行保留 | BASE-11 | ✅ |
| show tables 的 TableType、show create（含负向） | BASE-12/13 | ✅ |
| ALTER VIEW（rename/rename column/add/drop column/set properties） | BASE-14 | ✅ |
| COMMENT ON VIEW/COLUMN | BASE-15 | ✅ |
| 宽视图（200 列） | REF-05 | ✅ |
| 视图名（中文/空格） | REF-06 | ✅（表模型须用双引号） |
| issue 0335/0364/0367/0420 回归 | REF-01/02/03 | ✅ |

### 3.2 doc 90（`auto_sync_schema`，TDB-343）

| 需求点 | 用例 | 结论 |
|---|---|---|
| 默认 false、可查看、false 时新测点不加列 | SYNC-01/02 | ✅ |
| true + create timeseries / aligned / 批量 | SYNC-03/04 | ✅ |
| true + insert 自动建测点（含多设备） | SYNC-05 | ✅ |
| 模板激活（含批量）与 ALTER SCHEMA TEMPLATE 扩列 | SYNC-06 | ✅ 功能；日志见 TV-D1 |
| 只对树转表视图生效 | SYNC-07 | ✅ base table/逻辑视图均拒绝 |
| 小写同名冲突不加列、类型不被覆盖 | SYNC-08 | ✅ |
| original_name 冲突不加列但数据可查 | SYNC-09 | ✅ |
| 含大写 → 列名小写 + 保留原序列名 | SYNC-10 | ✅ |
| 与 RESTRICT 正交 | SYNC-11 | ✅ |
| SET PROPERTIES true↔false | SYNC-12 | ✅ |
| false→true 类型冲突应失败并保持 false | SYNC-13 | ❌ **TV-D2** |
| 删测点不删列、查询为 null | SYNC-14 | ✅ |
| OBJECT 类型 | SYNC-15/16 | 树模型不能建 OBJECT 测点（符合）；视图可声明 OBJECT 列且恒为 NULL（需求未禁止，建议产品确认） |

### 3.3 doc 913（技术设计约束）

| 约束 | 结论 |
|---|---|
| DN 前缀树匹配（RESTRICT/多层路径） | ✅（BASE-06、SYNC-11、REF-02） |
| CN procedure 驱动、异步生效 | ✅（有界等待内全部生效） |
| leader/follower 去重、幂等过滤 | ❌ **TV-D1**（未生效，重复请求打到 CN） |
| 扩列尽力而为、不阻断写入 | ✅（停 2 台 DN 期间写入与扩列均成功） |
| 视图卸载/重命名/删库后清理前缀树 | ✅（BASE-09/14、LEAK-01 反复建删无残留） |
| 重启后属性持久化 | ⚠️ 功能上 3/4 次通过，**1 次整库丢失**（TV-D5） |

### 3.4 高可用与资源

| 场景 | 结果 |
|---|---|
| 停 1 台 DN 期间新增测点触发扩列 | ✅ PASS（116s） |
| 停 2 台 DN（SR3 仍有副本）期间扩列 | ✅ PASS（123s） |
| 整集群重启后视图与自动扩列 | ✅ PASS（8 次重启全部保留视图定义，重启后自动扩列仍生效） |
| 反复建删视图 + 新增测点（6 轮）的线程/内存 | ✅ 无线程泄漏（3485→3425） |

## 4. 未覆盖项（需额外环境）

| 需求点 | 原因与建议 |
|---|---|
| 权限（CREATE/ALTER/DROP、SELECT 视图不需源序列 READ_DATA） | 需开启鉴权 + 多用户环境；建议用 `create user` + `grant` 搭一套独立用例 |
| 表模型 pipe 同步 VIEW、树模型 inclusion=all 的 pipe 不同步 view | 需两套集群 + pipe；建议在双集群环境补 |
| `SQL SECURITY invoker/definer` | 需鉴权环境 |
| 老版本升级兼容 | 需 1.3 → 2.0 升级链路 |
| 未命中视图时写入性能不下降 | 需 benchmark 对照 |

## 5. 执行过程中修正的测试自身问题（10 处，均已复跑验证）

见 `REPORT_TREEVIEW_MAIN.md` §4–§5：行解析表头、RESTRICT 用例口径、BASE-08 重复建库、
BASE-14 断言笔误、BASE-04 引号、SYNC-11 语法顺序、SYNC-15 口径、REF-06 标识符引号、
日志备份文件名/同机双角色、接力脚本 pgrep 误匹配。

## 6. 结论

1. **树转表视图主功能达标**：41 条用例中 35 条 PASS，覆盖 docx / doc 90 / doc 913 / TDB-343 的全部可实现需求点；
2. **建议修的 P2**：**TV-D1（已录 PLM `TDB-890`，陈耀斌）** —— 扩列重复请求未去重/未幂等 + ERROR 噪声；
3. **建议修的 2 个 P3（日志级别）**：TV-D3（建视图预期失败记 ERROR）、
   TV-D4（密码过期检查降级放行却记带栈 ERROR）；
4. 该特性在 SR3/DR3、停 1~2 台 DN 的场景下表现正常，未发现线程泄漏。
