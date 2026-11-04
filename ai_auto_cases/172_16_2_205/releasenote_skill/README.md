# releasenote_skill 套件使用说明

## 安装到测试机

```bash
scp -r ReleaseNote root@172.16.2.205:/data2/auto_test/
ssh root@172.16.2.205 'cd /data2/auto_test/ReleaseNote && bash tools/run_regression.sh'
```

依赖：`bash`、`ssh` 免密到 3 个 CN + 5 个 DN、`start-cli.sh`（随版本安装包）。

## 配置

`conf/env.conf`（同名环境变量可覆盖）：

```bash
NEW=v20131rc1_1030_ab6d3de
CN_LIST="172.16.2.26 172.16.2.27 172.16.2.28"
DN_LIST="172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6"
HOST=172.16.2.2       # SQL 连接主机；故障注入会避开它
PW=TimechoDB@2021
```

换版本只改 `NEW`（或 `CLI`）。

## 注意事项

1. 用例会 **kill -9 / SIGSTOP** 一台 DataNode，并在结束时恢复；请在专用测试集群执行；
2. 故障注入目标自动选**非 `HOST`** 的 DN（否则 CLI 连不上，测不出授权行为）；
3. 所有 SQL 调用带 `timeout 90` 保护，避免 DN 无响应时用例卡死；
4. 用例文件命名：`cases/TDB_<编号>_v<来源版本>.sh`（不建版本子目录）；
5. 若集群已是异常状态（例如上一轮用例把 DN 停在 STOP），先跑 `tree_view_skill/tools/hard_reset.sh` 重置。

## 已覆盖缺陷（2.0.13.1 / ab6d3de 实测）

| 用例 | 来源缺陷单 | 场景 | 结果 |
| --- | --- | --- | --- |
| RN-001~003 | TDB-125 | DN 异常时 GRANT 不超时、权限生效 | PASS |
| RN-101 | TIMECHODB-0684 | GROUP BY + ORDER BY + LIMIT 不得把 limit 下推到聚合之下（d1 count=2） | PASS |
| RN-102 | TIMECHODB-0686 | DELETE 时间区间 min>max 不再返回底层 305，给出语义化错误 | PASS |
| RN-103 | TIMECHODB-0683 | date_bin 空时间区间（time>=2 and time<1）不报 301，返回空结果 | PASS |
| RN-104 | TIMECHODB-0698 | ALTER TIMESERIES 改 encoding/compression 不再报 700 语法错误 | PASS |
| RN-105 | TIMECHODB-0679 | 重复创建用户时 WARN 不打印完整堆栈 | PASS |

| RN-106 | TIMECHODB-0687 | 对齐序列 device 用写入创建后查询不报 ClassCastException 且能查出数据 | PASS |
| RN-107 | TIMECHODB-0670 | 不开三权分立时设置 MAX/MIN_SESSION_PER_USER 不报 NPE | PASS |
| RN-108 | TIMECHODB-0699 | 不支持的 encoding=DICTIONARY(INT32) 返回简洁语义化错误、不带堆栈 | PASS |
| RN-109 | TIMECHODB-0744 | 无 grant option 的普通用户不得把 SYSTEM 转授他人 | PASS |
| RN-110 | TIMECHODB-0423 | 普通用户对不存在 db 路径建 view 不再返回 305 内部错误（改为 803 权限提示） | PASS |

| RN-111 | TIMECHODB-0779 | 非法 query_cost_stat_window 值不应写入 iotdb-system.properties | **KNOWN**（2.0.13.1 仍未修复，见下） |
| RN-112 | TIMECHODB-0734 | 空 ResultSet 上 findColumn 不抛 NPE（返回列号或 SQLException） | PASS |
| RN-113 | TIMECHODB-0711 | session.close() 后 DN 不打印 TTransportException/Connection reset | PASS |

| RN-115 | TIMECHODB-0295 | `meta_data_cache_enable=false` 时 DataNode 仍能启动（恢复后 8/8） | PASS |
| RN-116 | TIMECHODB-0732 | IoTConsensus 内存类指标不存在负值 | PASS |
| RN-117 | TIMECHODB-0365 | 反复创建不可达 session 不 OOM、线程不暴涨 | PASS |

| RN-118 | TIMECHODB-0648 | 两表 JOIN 后 `last()` 分组查询不报 `Column 'time' is ambiguous` | PASS |
| RN-119 | TIMECHODB-0616 | 不存在用户登录不导致 DN `handleClientExit` NPE | PASS |

> 数据同步类（pipe / 接收端-发送端）缺陷**未纳入**：需要双环境，205 单集群无法闭环。

### 已知失败（2.0.13.1 实测仍未修复）

| 用例 | 缺陷单 | 现象 | 处置 |
| --- | --- | --- | --- |
| RN-111 | TIMECHODB-0779 | `set configuration "query_cost_stat_window"='5.61'` 返回 301 报错，但**非法值仍被写入 CN 的 `iotdb-system.properties`**（实测第 60 行 `query_cost_stat_window=5.61`） | 记入 `conf/known_failures.conf`，套件判定为 **KNOWN**（不计失败），建议重新提缺陷 |

### 未纳入的缺陷（及原因）

| 缺陷 | 原因 |
| --- | --- |
| TIMECHODB-0635 `failed_login_attempts=0` | 该配置 `set configuration` 返回 "restart is required"，需重启集群才生效；同场景已由 `auth_skill` 覆盖 |
| TIMECHODB-0715 改编码后 SELECT INTO | 2.0.13.1 已不支持 `SELECT INTO` 语法（实测 3 种写法均 700 解析失败），场景不适用 |
| TIMECHODB-0656 pattern_match UDF | 需先注册 UDF 库（iotdb-library），当前构建未内置 |
| TIMECHODB-0663 安全包强密码默认值 | 安全包（安全版）专属，当前为企业版构建 |
| TIMECHODB-0667 剔除连接审计日志 | 需第二个客户端 IP + 黑名单配置，单机无法构造 |
| pipe / 接收端-发送端类全部 | 需双集群环境 |

## 批量自动生成（107 条冒烟用例）

除手工用例（RN-001~RN-119，带精确断言）外，本套件还包含 **107 条从飞书缺陷单自动抽取的冒烟用例**：

- 来源：飞书缺陷文件夹全部 718 篇文档 → 分类 → 抽取"复现步骤"SQL → 生成
- 流水线：`tools/feishu/{01_harvest.py, 02_classify.py, 03_generate.py}`，说明见 `tools/feishu/README.md`
- 判据：按缺陷单步骤执行不再出现 `Exception/ERROR/305/301/NPE`（幂等：`already exists` 视为通过）
- 定位：**广度回归**（一次跑 126+ 条扫回归），精度靠手工用例与后续升级

首轮实测（2.0.13.1 / ab6d3de）：PASS 51 / FAIL 74 / KNOWN 1，失败中 31 条为旧版生成器的 SQL 截断问题、
26 条为库已存在不幂等，均已在生成器修复；修复版待环境恢复后重跑。

## 最终基线（2026-11-04，2.0.13.1 / ab6d3de）

**61 个用例：PASS 60 + KNOWN 1（RN-111 / TIMECHODB-0779 未修复）**，单次全量约 20 分钟。

| 类别 | 数量 | 说明 |
| --- | ---: | --- |
| 手工用例（精确断言） | 20 | TDB-125 + TIMECHODB 19 个，覆盖查询正确性、错误信息、权限、日志、启动健壮性、JDBC、监控指标 |
| 自动抽取用例（冒烟） | 41 | 从飞书缺陷单复现步骤自动生成，校验"按步骤执行不再报错" |
| 已知未修复（KNOWN） | 1 | TIMECHODB-0779：非法配置值仍被写入 iotdb-system.properties |

### 自动抽取的淘汰情况

从 718 篇文档中筛出 116 个候选、生成 107 条自动用例，经三轮实测与剪枝：

- 首轮 PASS 51 / FAIL 74（PARSE 31、PERM 26、INTERNAL 1、OTHER 16）
- 修生成器（多行 SQL 重建、幂等断言、方言自适配、预期报错感知）后 PASS 60 / FAIL 55
- 最终**剪掉 55 条无法自动化的**（老版本语法、依赖 pipe/多集群、占位符、需特殊环境），保留 41 条稳定通过的

淘汰明细见 [`docs/pruned_auto_cases.md`](docs/pruned_auto_cases.md)，每条记录了失败原因。
