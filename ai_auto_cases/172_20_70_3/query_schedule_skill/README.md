# query_schedule_skill —— 查询调度（Query Scheduler / MLFQ）专项用例

> **位置**：`ai_auto_cases/172_20_70_3/query_schedule_skill/`
> **执行机**：172.20.70.3　**被测形态**：3C5D（3 CN + 5 DN），SR=3、DR=2
> **需求来源**：飞书《V1.0.0.1-计算模块-查询调度》需求分析 / 软件测试文档 / 技术设计（原文见 `requirements/`）

## 覆盖范围

需求把目标定义为三条：**短查询不被长查询阻塞**、**长查询不饿死**、**无需手动指定优先级**。
本 skill 拆成 **16 条需求点**（REQ-01~16），逐条映射用例与判据，见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)。

| 类别 | 需求点 |
|---|---|
| 调度目标 | REQ-01 短查询不被阻塞 / REQ-02 长查询不饿死 / REQ-03 无需手动指定优先级 |
| 线程与中断 | REQ-04 线程数可配 / REQ-05 时间片让出 / REQ-06 超时中断 / REQ-07 主动取消级联 |
| 状态与依赖 | REQ-08 五状态机 / REQ-09 Blocked↔Ready / REQ-10 查询任务组 |
| 队列 | REQ-11 MLFQ+累计执行时间 / REQ-12 队列容量 / REQ-13 队列监控 |
| 安全 | REQ-14 无死锁 / REQ-15 资源释放 / REQ-16 重启恢复 |

## 用例清单（15 条，覆盖 14/16 个需求点）

| 用例 | 覆盖需求点 | 判据 |
|---|---|---|
| `qs_01_thread_config.sh` | REQ-04 线程数可配 | 合法值 2 生效；非法值 0 回退 CPU 核数、节点不崩 |
| `qs_02_short_not_blocked.sh` | **REQ-01 + REQ-02** | 单线程下长查询期间短查询 **P99 < 50ms**；长查询正常结束 |
| `qs_03_long_query_completes.sh` | REQ-02 防饿死 | 短查询压力下长查询 rc=0 且在时限内结束 |
| `qs_04_no_manual_priority.sh` | REQ-03 无需手动优先级 | 配置无优先级项；不设优先级时 P99 < 50ms |
| `qs_05_state_machine.sh` | REQ-08 五状态机 | SHOW QUERIES 可见；KILL 后清理；结束仍可查 |
| `qs_06_timeout_abort.sh` | REQ-06 超时中断 | `query_timeout_threshold=2s` 时长查询报超时；之后仍可用 |
| `qs_07_kill_cascade.sh` | REQ-07 主动取消级联 | KILL QUERY 后指定查询消失；集群正常 |
| `qs_08_blocked_ready.sh` | REQ-09 Blocked→Ready | 大结果集查询完整返回，不卡死 |
| `qs_09_taskgroup_mlfq.sh` | REQ-10 + REQ-11 任务组/MLFQ | 两个长查询并发都能完成；短查询仍有成功 |
| `qs_10_time_slice.sh` | REQ-05 时间片让出 | 时间片 50ms 下 P99 < 50ms 且长查询完成 |
| `qs_11_concurrency_cap.sh` | REQ-12 队列容量 | 并发 6 > 上限 2 时不崩溃、至少 1 个成功 |
| `qs_12_resource_release.sh` | REQ-15 资源释放 | 10 次超时后 RSS 增幅 < 30%、无残留查询 |
| `qs_13_no_deadlock.sh` | REQ-14 无死锁 | 混合负载 3 分钟每轮都有成功、集群始终 8/8 |
| `qs_14_metrics.sh` | REQ-13 队列监控 | 指标端点可用；调度指标缺失记为观察项 |
| `qs_15_restart_recovery.sh` | REQ-16 重启恢复 | 重启 DN 后 8/8、查询与 SHOW QUERIES 正常 |

未单独成例的 2 条：REQ-04「启动后不可改变」由 QS-01 重启前后对比间接覆盖；
REQ-11 的 k=2 期望时间比例属实现细节，由 QS-09 的行为性判据覆盖。

## 运行

```bash
cd query_schedule_skill
vi conf/env.conf                        # 改版本目录与节点

bash cases/qs_02_short_not_blocked.sh   # 单条（约 21 分钟，其中长查询 ~18 分钟）
bash tools/run_all.sh                   # 全部（建议先跑 QS-01/06/11/14 这类轻量项）

# 复用已就绪集群、跳过清理（调试用，快很多）
QS_SKIP_CLEAN=1 USE_FRAMEWORK=0 bash cases/qs_02_short_not_blocked.sh
```

结果写 `results/`，每条用例末尾输出 `RESULT PASS|FAIL ... consensus=<协议>`。

## 实测结果（RC11 `ea4f835`，QS-02 三轮）

| 轮次 | 基线 P99 | 长查询期间 P99 | 长查询 | 结论 |
|---|---|---|---|---|
| #1 | 8.44ms | **6.47ms** | 1101s 正常结束 | 通过 |
| #2 | 6.17ms | **8.01ms** | 700s 被 600s 超时掐断 | 通过 |
| #3 | 1.56ms | **399.57ms** | 1087s 正常结束 | 未通过（尾延迟尖刺） |

详见 [docs/REPORT.md](docs/REPORT.md)，其中分析了 #3 的测量侧干扰（`select *` 全量结果集与压测客户端同机）。
其余 14 条用例**尚未在集群上实测**，仅完成脚本与语法校验。

## 目录

| 目录 | 用途 |
|---|---|
| `cases/` | 15 条用例脚本 + `cases.tsv`（用例矩阵）+ `cases/MANIFEST.md5`（校验清单） |
| `lib/` | 公共库：集群控制、断言、benchmark 封装、调度参数下发与观测 |
| `conf/env.conf` | 唯一需要按环境修改的文件 |
| `docs/` | 需求点拆解（REQUIREMENTS.md）、测试报告（REPORT.md） |
| `requirements/` | 飞书需求原文三篇（需求分析 / 测试文档 / 技术设计） |
| `tools/fetch_feishu.py` | 从飞书拉取需求文档（需要应用已被授权访问目标文件夹） |

## 环境要求

- 执行机可免密 ssh 到全部 CN/DN
- 节点已部署被测版本；执行机有同版本 CLI
- 短查询压测依赖 iot-benchmark（`lib/perf.sh` 的 `PERF_BM_DIR`）
