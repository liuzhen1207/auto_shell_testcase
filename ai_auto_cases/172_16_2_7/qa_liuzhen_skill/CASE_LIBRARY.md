# 刘珍提出/创建问题的自动化回归用例集

## 1. 来源与范围

| 项目 | 内容 |
| --- | --- |
| 数据源 | PingCode 项目 V2（TimechoDB-V2.x），列表 URL：https://pingcode.timecho.com/pjm/projects/V2/xE9Rtxmq/X8czxBbY |
| 筛选条件 | 创建人 = 刘珍 **或** 提出人 = 刘珍 |
| 抓取时间 | 2026-11-04 |
| 总量 | **131** 条（缺陷 114、需求/史诗 14、其他 3） |
| 回归基线 | 2.0.13.1 RC1，BuildInfo `ab6d3de`，3C5D（CN 172.16.2.8/9/10，DN 172.16.2.11~15） |

完整清单见 [catalog.md](catalog.md)（机器可读 [catalog.json](catalog.json)）。

## 2. 可行性结论

**可以部分整理，但不能全部自动化。** 131 条中：

| 判定 | 数量 | 说明 |
| --- | --- | --- |
| 已自动化（场景） | 3 | QA-LZ-001（V2-754）、QA-LZ-002（V2-861）、QA-LZ-003（串行缩容/加回两轮） |
| 已自动化（日志门禁） | 23 | checks.json 中 23 条缺陷特征，标准负载后扫日志判定 |
| 可自动化(待设计) | 29 | 需补具体操作序列 |
| 需并发负载 | 15 | 需要 benchmark 并发 + 数据一致性断言 |
| 需升级场景 | 5 | 依赖旧版本升级路径，当前环境不具备 |
| 工具类 | 2 | 验证对象是独立 jar/脚本 |
| 环境不可复现 | 6 | 依赖 5C20D、磁盘/网络故障等特殊环境 |
| 非缺陷 | 14 | 需求/史诗，不做缺陷回归 |
| 待人工确认 | 35 | 标题不足以判定场景，需读描述后决定 |

结论：先把 **已自动化** 的纳入每次发版回归；**可自动化(待设计)** 按模块分批补齐（建议每版补 3~5 条）；其余保持人工验证或标注为不适用。

## 3. 目录结构

```text
cases/qa-liuzhen/
├── README.md                  # 本文件
├── catalog.md / catalog.json  # 131 条清单与自动化判定
├── run_suite.sh               # 一键跑已自动化用例
├── run_qa_lz_001.sh           # V2-754：不存在用户登录 NPE
├── run_scale_cycle.sh         # QA-LZ-003：两轮串行缩容/加回
├── run_pattern_suite.sh       # 标准负载 + 日志门禁（23 项）
├── checks.json / checks.tsv   # 日志门禁的缺陷特征清单
├── cases/
│   └── QA-LZ-001-nonexistent-user-login.md
└── results/                   # 每版回归结果
```

> 2026-11-05 回归结果：QA-LZ-001、QA-LZ-002 与 23 项日志门禁在 2.0.13.1 RC1 上均 **PASS/未命中**，详见
> [results/2026-11-05_RC1.md](results/2026-11-05_RC1.md)；IoTConsensusV2 协议下同样全部通过，见
> [results/2026-11-05_RC1_iocv2.md](results/2026-11-05_RC1_iocv2.md)；QA-LZ-003 缩容循环首轮即发现 .12 迁移失败，见
> [results/2026-11-05_RC1_scale_cycle.md](results/2026-11-05_RC1_scale_cycle.md)；IoTConsensus（V1）下两轮 10 次缩容/加回全部通过，见
> [results/2026-11-05_RC1_scale_cycle_iocv1.md](results/2026-11-05_RC1_scale_cycle_iocv1.md)。2026-11-04 首次试点因集群激活异常阻塞的过程记录保留在
> [results/2026-11-04_RC1_pilot-blocked.md](results/2026-11-04_RC1_pilot-blocked.md)。

QA-LZ-002（V2-861）与 `ReleaseNote-测试/cases/TDB-122-stop-dn-query-error/` 是同一场景（PingCode 的 V2-861 与 PLM 的 TDB-122 对应），直接复用那里的 `run.sh`/`check.sh`，不在本目录重复实现。

## 4. 怎么跑

在控制机（172.16.2.7）执行：

```bash
cd skills/timechodb-rn-verify/cases/qa-liuzhen
bash run_suite.sh
```

前置：

1. 目标版本已部署（默认 `/data1/iotdb/v20131rc1_1030_ab6d3de`）；
2. 集群已启动（脚本不自启，避免影响正在跑的其它用例）；
3. 控制机可 ssh 到 5 台 DN。

结果追加到 `results/<日期>_<版本>.md`。

## 5. 每次发版的回归流程

1. 部署新版本、起集群，把 `TESTDB`/`CLI_ROOT` 指到新版本；
2. 跑 `run_suite.sh`；
3. 结果写 `results/`，失败项对照 catalog 判断是回归还是已知未修复；
4. 新的 V2-754/V2-861 类问题修复后，按 catalog 的「可自动化(待设计)」继续补脚本。

## 6. 局限

1. catalog 的自动化判定基于标题与状态启发式分类，未逐条读描述，标注为「待人工确认」的需要人工二次判断；
2. 依赖旧版本升级、5C20D、磁盘/网络故障的条目不在本环境回归；
3. QA-LZ-002 依赖 benchmark 与停集群，单次约 10 分钟，建议单独跑。
