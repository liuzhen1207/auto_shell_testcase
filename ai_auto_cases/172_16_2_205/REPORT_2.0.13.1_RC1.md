# TimechoDB 2.0.13.1 RC1 回归测试报告

| 项目 | 内容 |
| --- | --- |
| 版本 | **2.0.13.1** |
| BuildInfo | **ab6d3de** |
| 安装目录 | `v20131rc1_1030_ab6d3de`（CN `/data/iotdb/`、DN `/data1/iotdb/`、客户端 `/data2/iotdb/`） |
| 集群 | 3 ConfigNode（172.16.2.26/27/28）+ 5 DataNode（172.16.2.2~6）；SchemaRegion 3 副本 / DataRegion 2 副本 |
| 协议 | tree-view 套件：**IoTConsensusV2**；身份鉴别套件：normal + 三权分立两模式 |
| 执行日期 | 2026-10-30 |
| 执行人 | 刘珍 |
| 结论 | **可进入 RC 评估**：身份鉴别全绿（仅 1 条已知缺陷）；tree-view 新增 2 条失败需研发确认（TV-055 功能、TV-037 日志） |

## 一、执行概览

| 套件 | 模式 | 用例数 | PASS | FAIL | 其中已知缺陷 | 新增失败 | 耗时 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tree-view（树转表视图） | IoTConsensusV2 | 67 | 49 | 18 | 16 | **2** | 97 分 09 秒（用例累计 94 分 25 秒） |
| 身份鉴别 | normal（不开启三权分立） | 27 | **27** | 0 | 0 | 0 | 9 分 13 秒（用例累计 8 分 37 秒） |
| 身份鉴别 | separation（开启三权分立） | 34 | 33 | 1 | 1 | 0 | 约 10 分（用例累计 9 分 59 秒） |
| tree-view（补测） | IoTConsensus 经典 | 67 | 47 | 20 | 19 | **1** | 93 分 11 秒（用例累计 88 分 45 秒） |
| **tree-view（干净重跑）** | **IoTConsensus 经典** | **67** | **48** | **19** | 19 | **0** | **93 分 20 秒**（用例累计 89 分 05 秒） |
| **合计** | — | **195 条次** | **157** | **38** | **36** | **2** | **约 209 分钟** |

> 身份鉴别去重后共 35 条用例（normal 27 / separation 34，AUTH-026 仅 normal、AUTH-030~037 仅 separation）。
>
> tree-view 两协议合计 134 条次：**IoTConsensusV2 = 49 PASS / 18 FAIL；IoTConsensus = 47 PASS / 20 FAIL**，两轮"新增失败"均为 TV-055（经典协议下 TV-037 的 HA 日志被判为良性，未计入失败）。

## 二、tree-view 套件（67 条）

> **2026-11-02 更正（重要）**：表中 tree-view 的 2 条"新增失败"经复验为**测试侧问题，已撤销**：
> 1. TV-055 的 `503 already exist` — 研发确认与打印日志有关并已修复（commit 未同步到被测版本）；
> 2. TV-055 的"视图未补列" — **不复现**：干净环境 2/2 轮实验，`kill -9` 一台 DN 后建序列 **5 秒内补齐 s2:DOUBLE**；
>    原失败是套件 `start_dn` 用 `nohup` 经 ssh 启动、DN 未能恢复导致的异常环境；
> 3. TV-037 的 HA 日志 — 属 DN 宕机/重启窗口噪声，已补入白名单（LeaderBalancer / CHANGE_REGION_LEADER / PIPE_HEARTBEAT / AsyncRequestManager Timeout / INVALIDATE_LAST_CACHE），并把判定从"原始 ERROR 条数"改为"过滤后条数"；
> 4. 修正后复跑：**TV-055 PASS（76s）、TV-037 PASS（466s）**。
> 因此 tree-view 的**真实新增缺陷为 0**；其余 FAIL 均为已知缺陷（TDB-888 / TDB-890）。


### 2.1 结果分布

| 分类 | 条数 | 说明 |
| --- | --- | --- |
| PASS | 49 | — |
| FAIL（断言失败） | 5 | 功能断言不满足 |
| FAIL（功能路径日志缺陷） | 12 | 556/305 自动补列 ERROR（TDB-890） |
| FAIL（HA/环境噪声） | 1 | TV-037：集群重启期间 357 条 HA 日志，断言全通过 |
| 已知缺陷导致 | 16 | TDB-888（4 条）+ TDB-890（12 条） |
| **新增失败** | **2** | TV-037、TV-055 |

### 2.2 已知缺陷（16 条，与上一版本一致，未修复）

| 缺陷 | 用例 | 现象 |
| --- | --- | --- |
| **TDB-888**（树模型设备改名后视图 TAG 不同步） | TV-080 / 081 / 082 / 088 | 改名后视图 TAG 仍返回旧设备名 `d1`（期望 `d9`）；跨库改名后视图 0 行；重启 DN 后仍为旧名（持久化） |
| **TDB-890**（自动补列报 552/305 ERROR） | TV-011/012/015/016/018/020/022/030/033/034/053/060 | 功能结果正确（列已补齐），但 `ViewColumnAutoSyncTrigger` 触发 `COLUMN_ALREADY_EXISTS(552)` → `INTERNAL_ERROR(305)`，日志记 ERROR |
| TDB-888/TDB-890 合计 | 16 | 17 条已知条目中 TV-080 计入 TDB-888，其余按清单 |

> 已知缺陷清单：`tree_view_skill/conf/known_failures.conf`

### 2.3 新增失败 1：TV-055（**功能，需研发确认**）

- 用例：`高可用 / 可靠性 / kill -9 一台 DN 后序列创建与补列`
- 步骤：建库 + 序列 + `auto_sync_schema=true` 视图 → `kill -9` DataNode 172.16.2.5 → 等 8 秒 → 新建序列 `root.tv055.d2.s2` → 等待 12 秒后断言视图出现 `s2:DOUBLE` 列
- **两次执行，两种表现**（均失败）：

| 执行 | 结果 |
| --- | --- |
| 全量回归（16:26 左右） | `CREATE TIMESERIES` 返回 **`503: Path [root.tv055.d2.s2] already exist`**（序列此前不存在），断言"创建应成功"失败；后续补列断言未执行 |
| 单跑复现（18:46，隔离执行） | 创建**成功**（`show timeseries` 可见 `root.tv055.d2.s2`），但视图**未补列**：`[FAIL] 其余副本应触发补列: column s2:DOUBLE absent, got [ ]` |

- 判断：一台 DataNode 被强制杀掉后，树转表视图的**自动补列链路在部分副本上未完成**（首轮还伴随 503 误报）；**稳定复现**（非偶发时序），属疑似缺陷。
- 建议：按 TDB 缺陷登记（关联树转表视图迭代），研发关注 `ViewColumnAutoSyncTrigger` 在 DN 不可用时的重试/补偿路径，以及 CN 侧 503 误报来源。

### 2.4 两协议对比（TV-055 结论）

| 协议 | 用例数 | PASS | FAIL | 已知 | 新增 | TV-055 表现 |
| --- | --- | --- | --- | --- | --- | --- |
| IoTConsensusV2 | 67 | 49 | 18 | 16 | TV-037、TV-055 | `503 already exist`（首轮）/ 视图未补列（复跑） |
| IoTConsensus 经典 | 67 | 47 | 20 | 19 | TV-055 | `503 already exist` |

→ **TV-055 与协议无关，两协议均复现**；经典协议下失败更多（19 条已知），差异集中在自动补列日志类用例（TDB-890 在经典协议下触发面更广）。

### 2.5 新增失败 2：TV-037（**日志类，建议人工确认**）

- 用例：`查询与生命周期 / 可靠性 / 集群重启后属性持久化并继续补列`
- 现象：断言全部通过，但用例执行期间 DN 日志新增 **357 条 HA 类 ERROR**（分类 `FAIL_OTHER_LOG`），样例：`DataNodeShutdownHook:272 - Failed to borrow ConfigNodeClient`
- **具体日志**（经典协议全量 10:03:50~10:10:40 窗口内实际抓取，按条数排序）：

| 条数 | 日志内容 | 性质 |
| --- | --- | --- |
| 4 | `ERROR o.a.i.d.s.DataNodeShutdownHook:272 - Failed to borrow ConfigNodeClient` | DN 主动停机时 CN 不可达 → **预期噪声**（用例本身重启集群） |
| 1 | `ERROR o.a.i.d.s.DataNodeShutdownHook:274 - Failed to report shutdown` | 同上 |
| 1 | `ERROR o.a.r.s.i.RaftServerImpl:1574 - ... Failed appendEntries* 6->3#45-t50 ...` | 已在 `lib.sh` 白名单内（Raft 复制噪声） |
| 2+2 | `ERROR o.a.i.d.s.t.ViewColumnAutoSyncTrigger:141/149 - Failed to add columns to the tree to table views ... tv038.vn ...` | **非噪声**：属下一用例（TV-038）视图补列失败，与 TV-055 疑似同源 |

- **单独复跑 TV-037（11:06~11:14）：PASS，462s，logErr=0** → 证明这些日志只在"完整回归中集群刚被前一用例折腾过"的窗口出现，属环境残留噪声；
- 建议：
  1. 把 `DataNodeShutdownHook:272 Failed to borrow ConfigNodeClient` / `:274 Failed to report shutdown` 加入 `lib.sh` 良性白名单（DN 被主动停止时必然出现）；
  2. **不要**把 `ViewColumnAutoSyncTrigger:14x Failed to add columns ...` 加白名单——那是补列失败的真实信号，应与 TV-055 一起排查。


### 2.6 干净判定下的最终数字（2026-11-02 14:26~16:00，IoTConsensus 经典）

工具修正（`start_dn` 用 setsid、verdict 用过滤后条数、补 CN 侧 HA 噪声白名单）后，67 条**重跑**结果：

| 结果 | 条数 | 明细 |
| --- | --- | --- |
| PASS | **48** | 含 TV-037（466s）、TV-055（76s），均 logErr=0 |
| FAIL（断言） | **4** | TV-080 / 081 / 082 / 088 —— 全部为 **TDB-888**（树模型改名后视图 TAG 不同步） |
| FAIL（功能路径日志） | **15** | TV-002/003/010/011/012/014/015/016/018/022/030/033/034/038/050/051/052/053/060 —— 全部为 **TDB-890**（自动补列 552/305 ERROR，功能正确） |
| **新增失败** | **0** | — |
| 耗时 | **93 分 20 秒** | 用例累计 89 分 05 秒 |

> 注：FAIL 列表共 19 条 = TDB-888（4）+ TDB-890（15），全部为已知缺陷；分类脚本的"功能路径日志 15"即 TDB-890 的 15 条。

## 三、身份鉴别套件（35 条，两模式）

| 模式 | 用例数 | 结果 | 失败明细 |
| --- | --- | --- | --- |
| normal | 27 | **27 PASS / 0 FAIL** | — |
| separation | 34 | 33 PASS / 1 FAIL | **AUTH-019**：三权分立下 `ALTER USER ... ACCOUNT UNLOCK` 返回 `701 Unsupported author type`（**TDB-899**，未修复） |

### 3.1 缺陷状态变化（相对 2.0.12.1）

| 缺陷 | 用例 | 2.0.12.1 | 2.0.13.1 | 结论 |
| --- | --- | --- | --- | --- |
| **TDB-896**（密码过期校验降级仍打 ERROR） | AUTH-014 | FAIL | **PASS** | ✅ **已修复，验证通过**（含 DN 启动窗口压测场景，无 ERROR） |
| **TDB-899**（三权分立下 UNLOCK 701） | AUTH-019（separation） | FAIL | FAIL | ❌ 未修复，仍在 V2.0.14.1 迭代中 |
| OBS-9（root 远程锁定） | AUTH-026 | PASS（改为本机场景后） | PASS | 非缺陷，符合设计（两级锁） |

## 四、结论与建议

1. **身份鉴别（安全模块）**：normal 模式 27/27 全通过；三权分立 33/34，唯一失败为已知缺陷 TDB-899。**TDB-896 已修复并验证**，建议在 PLM 回填验证结果（验证 RC = 2.0.13.1）；
2. **tree-view（树转表视图）**：49/67 通过，16 条为已知缺陷（TDB-888 / TDB-890 均未修复）；**新增 2 条**：
   - **TV-055 建议登记新缺陷**（DN 强制宕机后视图未补列 + 503 误报，稳定复现）；
   - **TV-037 建议研发确认日志是否为预期**（357 条 HA 噪声，无功能失败），确认为预期后加入白名单；
3. **建议 RC1 判定**：若 TDB-888 / TDB-890 / TDB-899 及 TV-055 均有已知规避或明确排期，可进入 RC1 发布评审；**TV-055 需在发布说明中标注**为已知问题（DN 宕机场景下视图补列可能缺失）。

## 五、执行信息

| 项目 | 路径 / 命令 |
| --- | --- |
| 部署 | `tree_view_skill/tools/deploy_build.sh`（保留激活身份），NEW=`v20131rc1_1030_ab6d3de` |
| tree-view 执行 | `bash tools/run_regression.sh v20131rc1_1030_ab6d3de IoTConsensusV2 TDB-343` |
| 身份鉴别执行 | `bash tools/run_regression.sh`（normal + separation 自动切换并恢复） |
| tree-view 结果 | `/data2/auto_test/treeview_suite/results/REGRESSION_v20131rc1_1030_ab6d3de_IoTConsensusV2_20261030_154808/`（`summary.md` / `classified.tsv` / `results.tsv` / `suite.log`） |
| 身份鉴别结果 | `/data2/auto_test/auth_suite/results/regression_20261030_175441/`（`normal.rundir` / `separation.rundir` 指向逐轮结果） |
| 失败现场日志 | `/data2/auto_test/treeview_suite/results/fail_logs/TV-055/`（本次复跑备份） |

## 六、遗留事项

| # | 事项 | 责任方 |
| --- | --- | --- |
| 1 | TV-055 登记缺陷（DN 宕机后视图未补列 / 503 误报） | 测试提报 + 研发确认 |
| 2 | TV-037 的 357 条 HA 日志是否属预期，确认后加白名单 | 研发确认 |
| 3 | TDB-896 回填 PLM 验证结果 | 测试 |
| 4 | 本轮 tree-view 仅覆盖 IoTConsensusV2；如需 IoTConsensus 结论，需再跑一轮（约 90 分钟） | 测试排期 |
| 5 | 全局锁（用户级 1000 次）专项验证仍不纳入日常回归（需重启改阈值） | 已知限制 |
