# WAL（写前日志）专项测试 skill

面向 TimechoDB / IoTDB **写前日志（WAL）** 的自动化测试用例集：以"**WAL 保数据不丢**"为核心，
覆盖 **模式语义 / 掉电恢复 / 文件组织 / 压缩 / 清理与快照 / 内存与背压 / OBJECT / 参数 / 可观测性 / 高可用** 十个面。

- 目标版本：**RC7 `v20121rc7_1014_7c61428`**（`2.0.12.1`）；换环境只改 `conf/env.conf`。
- 集群：3C3D（`192.168.99.77/78/79`，每台 1CN+1DN），RF=3；协议默认 `IoTConsensus`，可 `--consensus IoTConsensusV2`。
- 需求依据：`docs/req_sources/`（飞书《写前日志》需求分析 / 技术设计 / 软件测试文档 / WAL 压缩 / 队列内存 / OBJECT 一期）
  与 **源码印证**（每条判据给 `file:line`）；口径决策见 `docs/DECISIONS.md`，矩阵与构造见 `docs/REQ_MATRIX.md`。

## 快速开始

```bash
# 全量（27 条，单协议）
bash tools/run_all.sh --set all

# 只跑核心 12 条（首轮范围）
bash tools/run_all.sh --only W-00,W-01,W-02,W-03,W-04,W-05,W-08,W-11,W-12,W-14,W-17,W-23

# 按面跑
bash tools/run_all.sh --set recover                 # 掉电恢复/节点下线
bash tools/run_all.sh --set compress                # 压缩
bash tools/run_all.sh --set all --consensus IoTConsensusV2

# 换版本（不改进程内默认值）
V_TESTDB=v20121rc7_1014_7c61428 BUILD_TAG=v20121rc7_1014_7c61428 bash tools/run_all.sh --set smoke

# 自检（离线，不需要集群）
SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh
```

结果：`results/test_result.csv`（build/协议/用例/结果/耗时/fail 数/artifact/message）
+ `results/SUITE_<set>_<runid>.out`（套件日志）+ `results/<用例>_<runid>.out`（单条输出）；
失败用例自动打包 CN/DN 日志到 `results/artifact_*`。

## 用例集合（见 `cases/cases.tsv`，27 条）

| 集合 | 用例 | 覆盖 |
| --- | --- | --- |
| `smoke` | W-00 | 骨架冒烟：写→flush→读数一致 + WAL 目录确有文件 |
| `mode` | W-01~W-03 | `wal_mode` 模式矩阵（ASYNC/SYNC）、**集群下 DISABLE 必须被拒**、restart-only 语义 |
| `recover` | W-04~W-07 | **kill -9 掉电恢复（WAL 重放）**、flush 边界对照、DN 下线期写入、元数据恢复 |
| `file` | W-08~W-10 | 文件轮转阈值、`wal_buffer_size_in_byte`、WALNode 分配 |
| `compress` | W-11~W-13 | 压缩开关对照、压缩态掉电恢复、压缩/未压缩共存兼容性 |
| `cleanup` | W-14~W-16 | 无效 WAL 清理（含**反向断言**：未 flush 不得误删）、最小有效信息比、MemTable 快照 |
| `mem` | W-17~W-18 | WAL 阻写（背压）、大压力下队列内存受控（**无 OOM 是硬断言**） |
| `object` | W-19~W-20 | OBJECT 写入的 WAL 恢复（WAL 中只存引用）、导入后重启一致性 |
| `param` | W-21~W-22 | 非法取值拒绝、参数热加载语义（restart-only 清单） |
| `observe` | W-23~W-24 | 监控指标（动态发现）、WAL 目录配置 |
| `ha` | W-25~W-26 | WAL 盘 readonly、双协议对照 |

## 判定口径（三条铁律）

1. **WAL 三件套**：目录面（`_<version>.wal`/`.checkpoint`、总字节、魔数 `WAL-V2`）+ 日志面（源码文案计数）
   + **数据面（count/sum/指纹）**。**只有数据面能判 FAIL**，前两者是过程证据。
2. **场景有效性硬断言**：WAL 文件数为 0、阈值没生效、kill 没发生、重启没完成 ⇒ `fail "场景无效：…"`，
   **绝不静默通过**（否则会出现"全绿但什么都没测"）。
3. **文档没写清楚 ≠ 产品有问题**：阈值口径矛盾（30M/10M、fsync 键名、阻写键名…）先现场标定；
   性能、压缩率、内存绝对值、指标名一律只 WARN；不可构造的项写明"不可构造 + 逐副本证据"。

详见 `docs/DECISIONS.md`。

## 目录结构

```
wal_skill/
├── conf/env.conf            # 唯一需要按环境修改的文件（含 12 个 WAL 配置项默认值 + 用例规模/窗口）
├── lib/
│   ├── common.sh            # 集群生命周期/SQL/收尾三件套（与合并 skill 同基线）
│   ├── cmp.sh               # 数据/文件观测与合并参数（同基线）
│   └── wal_ext.sh           # ★ WAL 专属：目录/文件/字节/魔数/日志/指标/kill -9/重放/阻写/OBJECT
├── cases/
│   ├── cases.tsv            # 用例矩阵（机器可读；27 条）
│   └── common/wal_*.sh      # 用例脚本
├── tools/
│   ├── run_all.sh           # 集合入口（smoke|mode|recover|file|compress|cleanup|mem|object|param|observe|ha|all）
│   └── selftest.sh          # harness 自检（离线可用；含 planned 计数）
├── docs/
│   ├── REQ_MATRIX.md        # 需求条目 → 用例 → 构造与判据（逐条带出处）
│   ├── DECISIONS.md         # 口径决策：只 WARN 清单、文档矛盾、不可构造项
│   ├── RESULTS.md           # 实跑结果与逐条判定
│   └── req_sources/         # 飞书文档抽取 + 源码印证
└── results/                 # CSV / 套件日志 / 单条输出 / 失败 artifact
```

## 部署与运行位置

| 位置 | 路径 |
| --- | --- |
| 工作区（开发） | `D:\IDEA\deepseek\ip99_80\wal_skill` |
| 运行（99.80） | `/data/iotdb/autotest/wal_skill` |
| 交付 | `D:\IDEA\deepseek\wal` |

同步后**必须**核对关键文件 md5，并跑一次 `SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh`
（历史上出现过"远端脚本被截断 ⇒ 用例静默不生效"的事故）。
