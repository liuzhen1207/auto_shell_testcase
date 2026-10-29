# query_schedule_skill —— 查询调度（Query Scheduler / MLFQ）专项用例

> **位置**：`ai_auto_cases/172_20_70_3/query_schedule_skill/`
> **执行机**：172.20.70.3　**被测形态**：3C5D（3 CN + 5 DN），SR=3、DR=2
> **需求来源**：飞书《V1.0.0.1-计算模块-查询调度》需求分析 / 测试文档 / 技术设计（原文见 `requirements/`）

## 覆盖范围

需求文档把目标定义为三条：**短查询不被长查询阻塞**、**长查询不饿死**、**无需手动指定优先级**。
本 skill 把需求拆成 **16 条需求点**（REQ-01~16），逐条映射用例与判据，见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)。

| 类别 | 需求点 |
|---|---|
| 调度目标 | REQ-01 短查询不被阻塞 / REQ-02 长查询不饿死 / REQ-03 无需手动指定优先级 |
| 线程与中断 | REQ-04 线程数可配 / REQ-05 时间片让出 / REQ-06 超时中断 / REQ-07 主动取消级联 |
| 状态与依赖 | REQ-08 五状态机 / REQ-09 Blocked↔Ready / REQ-10 查询任务组 |
| 队列 | REQ-11 MLFQ+累计执行时间 / REQ-12 队列容量 / REQ-13 队列监控 |
| 安全 | REQ-14 无死锁 / REQ-15 资源释放 / REQ-16 重启恢复 |

## 已实现用例

| 用例 | 覆盖 | 判据 |
|---|---|---|
| `cases/qs_02_short_not_blocked.sh` | REQ-01 + REQ-02 + REQ-04 | `query_thread_count=1` 下并发全量查询，短查询 **P99 < 50ms**；长查询正常结束 |

其余 13 条需求点的用例待补（REQUIREMENTS.md 里已列好映射）。

## 运行

```bash
cd query_schedule_skill
vi conf/env.conf                          # 改版本目录与节点
bash cases/qs_02_short_not_blocked.sh     # 单条（约 21 分钟，其中长查询 ~18 分钟）

# 复用已就绪集群、跳过清理（调试用）
QS_SKIP_CLEAN=1 USE_FRAMEWORK=0 bash cases/qs_02_short_not_blocked.sh
```

## 实测结果（RC11 `ea4f835`）

| 轮次 | 基线 P99 | 长查询期间 P99 | 长查询 | 结论 |
|---|---|---|---|---|
| #1 | 8.44ms | **6.47ms** | 1101s 正常结束 | 通过 |
| #2 | 6.17ms | **8.01ms** | 700s 被 600s 超时掐断 | 通过 |
| #3 | 1.56ms | **399.57ms** | 1087s 正常结束 | 未通过（尾延迟尖刺） |

详见 [docs/REPORT.md](docs/REPORT.md)，其中分析了 #3 的测量侧干扰（`select *` 全量结果集与压测客户端同机）。

## 环境要求

- 执行机可免密 ssh 到全部 CN/DN
- 节点已部署被测版本；执行机有同版本 CLI
- 短查询压测依赖 iot-benchmark（`lib/perf.sh` 的 `PERF_BM_DIR`）
