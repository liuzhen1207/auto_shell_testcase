# 树转表视图测试包 —— 状态（2026-10-28 17:12，已 teardown）

## 1. 交付物

| 项 | 位置（本地 / 122） |
|---|---|
| 测试技能包 | `/data/deepseek/skill_case/treeview_5c20d`<br>`122:/data1/iotdb/5c20dtest/testcase/TREEVIEW/treeview_5c20d` |
| 用例集（**46 条** = 41 回归 + 5 缺陷复现） | `scripts/pgkit/cases_treeview.py`、`scripts/pgkit/cases_tv_repro.py` |
| **缺陷报告（4 份 + 1 份撤回）** | `docs/DEFECT_TV_D1_final.md`、`D2_final`、`D3_final`、`D4_final`、`D5_WITHDRAWN` |
| 缺陷索引（先看这个） | `docs/README_DEFECTS.md` |
| 最终回归报告 | `docs/REPORT_TREEVIEW_FINAL.md`（41 条：35 PASS / 6 FAIL） |
| 需求覆盖矩阵 | `docs/COVERAGE_TREEVIEW.md` |
| 档位 conf | `conf/cluster.treeview_5c20d.conf`（SR3/DR3、默认共识） |
| 驱动 / 队列 | `run_case_clean.sh`、`queue_treeview{1..6}.sh`、`queue_repro{1..5}.sh`、`queue_repro3.sh` |

被测版本：`master_1026_dc11a35`（BuildInfo **dc11a35**），5CN+20DN，SR3/DR3，`IoTConsensus`。

## 2. 缺陷处置结论

| 编号 | 问题 | 级别 | 复现 | 状态 |
|---|---|---|---|---|
| TV-D1 | 扩列请求副本间重复 → CN 305/552，DN 记 ERROR | P2 | **稳定** | **已录 PLM `TDB-890`**（陈耀斌，itemId=1485） |
| ~~TV-D2~~ | ~~false→true 类型冲突静默成功~~ | — | — | **已撤回：非缺陷** |
| TV-D3 | 建视图预期失败被 CN 记 ERROR | P3 | **稳定**（必现） | 待提交 |
| TV-D4 | 密码过期检查降级放行却记带栈 ERROR | P3 | 偶发（专项 3 次未命中） | 观察项 |
| TV-D5 | 重启后表库丢失 | — | 1 次"命中" | **已撤回：并发 prepare 误报** |

PLM 状态：**TV-D1 已录入 `TDB-890`**（负责人 陈耀斌，itemId=1485）；TV-D2 经确认非缺陷、已撤回。
其余（D3/D4/D6）按"先不录 PLM"处理，报告就绪。

## 3. 环境状态

- 集群已 **teardown**（25 节点 java=0，端口释放）；
- 安装目录保留：`/data/iotdb/master_1026_dc11a35`（可用于再次复现）；
- 结果与日志：`TREEVIEW/results/`（每个用例含 `result.json`、`actions.log`、`evidence/`）；
- 缺陷复现结果目录：`rp_TV-REPRO-D1..D5`、`rp3_*`、`rp4_*`、`rp5_*`、`rp6_*`。

## 4. 再次执行

```bash
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW
# 重新部署
(cd treeview_5c20d && bash scripts/pg.sh --conf conf/cluster.treeview_5c20d.conf deploy --clean)
# 单条缺陷复现（严格串行！prepare 会清库）
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp TV-REPRO-D1
# 全量回归
bash treeview_5c20d/queue_treeview.sh
```

## 5. 教训（已写入 README_DEFECTS.md）

同一环境**严禁并发跑两个队列**：`prepare` 会 `rm -rf data/`，
会把另一个用例的库"删掉"，表现为"元数据丢失"的假缺陷（TV-D5 即由此产生）。

## 6. Pipe（数据同步）场景 —— 2026-10-28 新增

**环境改造**：20 节点拆成两套独立集群（10 + 10），每套 **5 CN + 10 DN / SR 5 副本 / DR 3 副本**：

| 角色 | 节点 | conf |
|---|---|---|
| 发送端 | 172.20.70.100–109 | `conf/cluster.pipe_sender.conf` + `conf/nodes.pipe_sender.conf` |
| 接收端 | 172.20.70.110–119 | `conf/cluster.pipe_receiver.conf` + `conf/nodes.pipe_receiver.conf` |

**用例**：`scripts/pgkit/cases_tv_pipe.py`（9 条 `TV-PIPE-01..09`），专用驱动 `run_pipe_case.sh`（两端都 prepare）、
队列 `queue_pipe.sh`；文档 `docs/COVERAGE_PIPE.md`。

**已实测结论**：
1. 视图元数据由 `with source ('inclusion'='schema')` 的 pipe 同步（`schema.table` 不行，`all` 不行）；
2. 视图数据需另一条树数据 pipe（`'data.insert, schema.timeseries'`）；
3. **auto_sync 自动加列能随 pipe 下发到接收端**（列名与类型都一致）；
4. `inclusion='all'` 不同步视图 —— 与需求一致（负向用例）。

**当前结果**：`TV-PIPE-01` PASS；`TV-PIPE-03` 功能三项全 ok（FAIL 仅因已知 TV-D1 日志）；
其余 7 条在 `queue_pipe.sh` 串行执行（每条约 35 分钟，含两端 prepare）。

**注意**：pipe 用例必须用 `run_pipe_case.sh`（两端 prepare），且与单集群队列**不可并发**。

## 7. Pipe 组并入自动化回归（2026-10-29）

**总入口**：`regress_all.sh` —— 单集群 46 条 → 停干净两套 → pipe 组 9 条 → 停干净两套。
详见 `docs/REGRESSION_ENTRY.md`。

**双集群日志检查**：`conf/cluster.pipe_sender.conf` 增加
`LOG_SCAN_EXTRA_CONFS=conf/cluster.pipe_receiver.conf`，收尾③ 会同时扫描
**发送端 + 接收端共 30 个节点的 CN/DN 日志**，接收端命中行以 `R:` 前缀区分；
FAIL 时的日志备份也覆盖两端（`run_pipe_case.sh`）。

**干净隔离**：
- `run_pipe_group.sh`：组开始前 `teardown` 两端 → 跑 9 条 → 组结束后再 `teardown` 两端；
- `regress_all.sh`：全量开始前、单集群组结束后、pipe 组结束后各停一次；
- `run_case_clean.sh` 增加守卫：`TV-PIPE-*` 直接拒绝（必须走 `run_pipe_case.sh`，否则只 prepare 了发送端）。

**pipe 组当前结果**：`TV-PIPE-01` PASS、`TV-PIPE-02` PASS；
`TV-PIPE-03` 功能三项全 ok（FAIL 仅因 TV-D1 日志）；
`TV-PIPE-04` 功能 ok（`all` 不同步视图），FAIL 因**新缺陷 TV-D6**（接收端 WARN）；
其余在 `queue_pipe2.sh` 复跑（修了 `show pipes` 方言、PIPE-08 行数断言、`load_config` 导入）。

**新缺陷 TV-D6（P3）**：pipe 接收端 `createSchemaSnapshotDatabaseIfNecessary`
建库语句漏了 `setEnablePrintExceptionLog(false)`，使"库已存在"的**幂等**情形仍打 WARN（501），
而同文件另一条建库路径已静默。报告：`docs/DEFECT_TV_D6_pipe_receiver_create_db_warn.md`。
