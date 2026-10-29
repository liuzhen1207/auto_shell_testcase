# memory_buffer —— 内存缓冲区专项用例（ai_auto_cases / 172_20_70_3）

> **本目录在仓库中的位置**：`ai_auto_cases/172_20_70_3/memory_buffer/`
> **执行机**：172.20.70.3　**被测形态**：3C5D（3 CN + 5 DN），SchemaRF=3、DataRF=2
> 其他模块（如 `query_schedule`、`region_migrate`）按同样结构并列放在 `172_20_70_3/` 下。

## 快速开始

```bash
cd ai_auto_cases/172_20_70_3/memory_buffer

# 0) 改环境（版本目录、节点 IP、密码）——只改这一处
vi conf/env.conf

# 1) 自检（不碰集群，验证脚本与配置）
bash tools/selftest.sh

# 2) 跑全部用例（19 条功能 + 5 条性能，单协议）
bash tools/run_all.sh

# 3) 只跑某一条
bash cases/common/mb_01_alloc_report.sh

# 4) 指定版本与共识协议
V_TESTDB=v20121rc11_1023_ea4f835 DATA_CONSENSUS=IoTConsensusV2 bash tools/run_all.sh
```

结果写到 `results/`，每条用例一份 `<用例号>_<时间戳>.out`，末尾有 `RESULT PASS|FAIL ... consensus=<协议>` 行，便于汇总。

## 用例清单

| 类别 | 用例 | 覆盖 |
|---|---|---|
| 功能（19） | `cases/common/mb_01..mb_19` | 内存分配比例、定时/按比例刷盘、拒绝与恢复、并发刷盘、WAL 快照与重放、独立数据目录、Chunk 分裂、HA 停 DN、V2 共识、TVList 排序、刷盘线程数、时间分区、类型推断、非法比例 |
| 性能（5） | `cases/perf/p_01..p_05` | 刷盘比例、Chunk 参数、独立数据目录、最新点查询、V2 共识 |

详细索引与"研发文档 → 用例"映射见 [INDEX.md](INDEX.md)，操作手册与踩坑清单见 [SKILL.md](SKILL.md)。

## 目录说明

| 目录 | 用途 |
|---|---|
| `cases/` | 用例脚本（`common/` 功能、`perf/` 性能） |
| `lib/` | 公共库：集群控制、断言、benchmark 封装 |
| `conf/` | `env.conf`（唯一需要按环境修改的文件） |
| `tools/` | 运行器、自检、诊断脚本 |
| `docs/` | 各版本报告、缺陷分析、校准说明 |

## 环境依赖

- 执行机可免密 ssh 到全部 CN/DN 节点
- 节点上已部署被测版本（`${DB_PARENT_DIR}/${V_TESTDB}`），执行机有对应 CLI（`${SHELL_CLIENT_DIR}/${V_TESTDB}`）
- 性能用例依赖 iot-benchmark（路径见 `lib/perf.sh` 的 `PERF_BM_DIR`）

---

# membuf_skill —— 内存缓冲区专项回归用例（可逐版本复用）

面向 **TimechoDB / IoTDB 写内存缓冲区（MemTable + 内存控制）** 的可重复回归套件。
形态 3C5D、SchemaRegion 3 副本、DataRegion 2 副本；默认 IoTConsensus，其次 IoTConsensusV2。

- 操作手册与踩坑清单：[SKILL.md](SKILL.md)
- 用例索引、**研发文档→用例映射**：[INDEX.md](INDEX.md)
- 本轮发现（含疑似缺陷）：[docs/FINDINGS.md](docs/FINDINGS.md)
- 性能对比口径与方法：[docs/PERF.md](docs/PERF.md)
- **RC9 测试报告（最新版，24 条）**：[docs/REPORT_RC9.md](docs/REPORT_RC9.md)
- **缺陷报告 F-07（DN 起不来）**：[docs/DEFECT_F-07.md](docs/DEFECT_F-07.md)
- **缺陷报告 F-09（BACKWARD 查询 301 + 数据丢失）**：[docs/DEFECT_F-09.md](docs/DEFECT_F-09.md)
- **缺陷报告 F-10（配置类名不一致致副本失冗余，P2）**：[docs/DEFECT_F-10.md](docs/DEFECT_F-10.md)
- **根因分析 IoTV2 pipe 未创建**：[docs/RCA_IOTV2_PIPE.md](docs/RCA_IOTV2_PIPE.md)
- **分析：大 payload 写入慢的根因（CLI 逐字符，非死锁/内存）**：[docs/ANALYSIS_WRITE_SLOW.md](docs/ANALYSIS_WRITE_SLOW.md)
- **RC10 测试报告（双协议 24×2 用例 + 耗时）**：[docs/REPORT_RC10.md](docs/REPORT_RC10.md)
- **RC10 部署与激活记录**：[docs/RC10_DEPLOY.md](docs/RC10_DEPLOY.md)
- **PLM 提单：F-07 日志缺失专项**：[docs/PLM_TICKET_F-07_LOGGING.md](docs/PLM_TICKET_F-07_LOGGING.md)
- RC8 全量实跑结果（19 功能 + 5 性能）：[docs/RESULTS.md](docs/RESULTS.md)
- 实跑产物留档：[results_20261021/](results_20261021)

## 目录

```
membuf_skill/
├── SKILL.md                 操作手册（判据、踩坑、结果怎么读）
├── INDEX.md                 用例清单 / 参数覆盖矩阵 / 观测手段
├── conf/env.conf            唯一需要改的环境文件（集群、版本、比例、超时）
├── lib/common.sh            生命周期 + SQL + 断言 + syncLag + 副本一致性 + 日志分析
├── lib/mb.sh                内存分配日志 / 内存与刷盘指标 / 拒绝日志 / 重启与强杀
├── lib/perf.sh              性能对比 helper（benchmark 配置生成/结果解析/对照判定）
├── cases/common/            MB-xx 功能用例（18 条）
├── cases/perf/              P-xx 性能对比用例（5 条）
├── cases/quick.txt          快速门禁（5 条）
├── cases/doc.txt            研发文档新增的 7 条
├── cases/regression.txt     全量回归（18 条）
├── tools/run_all.sh         功能用例入口（flock 串行）
├── tools/run_perf.sh        性能对比入口（与 run_all 互斥）
├── tools/selftest.sh        自检（语法/环境/连通性/模板键）
└── results/                 运行产物（csv、out、artifact）
```

## 三条命令

```bash
SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh    # 自检
bash tools/run_all.sh --set quick               # 快速门禁
bash tools/run_all.sh --set regression          # 全量 18 条（V1）
bash tools/run_all.sh --set doc                 # 研发文档对应的 7 条
bash tools/run_perf.sh --set all                # 性能对比 5 条（必须在 run_all 之后）
bash tools/run_all.sh --set regression --consensus IoTConsensusV2   # V2 复跑
```

## 设计约束（来自本轮需求）

1. **每条用例从干净集群开始**：停集群 → 校验无残留进程 → 清 `data`/`logs` → 写配置 → 启动 → 核对干净；
2. **收尾固定三件套**：`sync lag 归零` → `副本一致性（逐个停 5 个 DN，与全在线基准比对）` → `ERROR/WARN 异常日志`；
3. **协议顺序**：默认 V1；V2 单独一轮（`--consensus IoTConsensusV2`）；
4. **可移植**：换集群/换版本只改 `conf/env.conf`（或用 `--ver` / 环境变量覆盖）。

## 已知边界

- 未能与飞书《研发文档》逐条对齐（应用对该文件夹 `1061004 forbidden`），覆盖矩阵按源码 + 官方 conf 模板语义构建；
- 不做吞吐门槛判定（benchmark 留给性能专项）；
- 不制造真正堆 OOM，只覆盖"内存控制拒绝写入"的受控路径。
