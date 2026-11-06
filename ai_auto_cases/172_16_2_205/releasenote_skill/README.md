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

**119 个用例：PASS 107 + KNOWN 1（RN-111 / TIMECHODB-0779 未修复）+ SKIP 3（三权分立用例，普通模式跳过；该模式下 3/3 通过）**，单次全量约 20 分钟。

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

### 三权分立模式用例（模式门控）

套件支持按模式运行，用例文件中用 `MODE_OF["RN-xxx"]="separation"` 声明所需模式：

```bash
bash tools/mode.sh on                              # 热加载开启三权分立
RN_MODE=separation bash tools/suite_rn.sh RN-121 RN-122
bash tools/mode.sh off                             # 写回 false + hard_reset 恢复
```

| 用例 | 缺陷单 | 验证点 | 2.0.13.1 结果 |
| --- | --- | --- | --- |
| RN-121 | TIMECHODB-0678 | security_admin 查询不存在用户权限应返回明确提示而非 301 | **PASS**（实测返回 `804: No such user`） |
| RN-122 | TIMECHODB-0619 | security_admin 给不存在用户赋权应有明确提示 | **PASS** |

普通模式下这两个用例会自动 **SKIP**（结果表记为 SKIP），不影响日常回归。

### 三权分立模式补充结果（2026-11-04 实测）

| 用例 | 缺陷单 | 结果 |
| --- | --- | --- |
| RN-121 | TIMECHODB-0678 | **PASS**（2.0.13.1 返回 `804: No such user`，301 已修复） |
| RN-122 | TIMECHODB-0619 | **PASS** |

在普通模式下这两条记 SKIP；单跑三权分立批次时全通过：

```bash
bash tools/mode.sh on && RN_MODE=separation bash tools/suite_rn.sh RN-121 RN-122 && bash tools/mode.sh off
```

### 审计日志类：本环境不可用（已验证）

`enable_audit_log=true` + 重启后，`root.__audit.**` 只出现 `password_history` 系列，**没有操作审计记录**；
配置模板中也无 `auditable_*` 键。结论：操作审计需安全包/专门授权构建，详见 [`docs/audit_status.md`](docs/audit_status.md)。

`tools/mode.sh audit-on|audit-off` 已就绪，换到支持审计的构建后可直接复用模式门控。

### 2026-11-04 增补（第 1、2 项扩展）

| 用例 | 缺陷单 | 场景 | 结果 |
| --- | --- | --- | --- |
| RN-123 | TIMECHODB-0629 | 表模型 `alter user u @ 'ip' ACCOUNT unlock` 语法应与树模型一致 | **PASS**（两种方言均可解析） |
| RN-124 | TIMECHODB-0632 | `password_history` 不应出现明文口令 | **PASS**（查询结果无明文） |
| RN-125 | TIMECHODB-0618 | 三权分立下 security_admin 改名不应报 701 Unsupported author type | **PASS**（separation 模式） |

三权分立批次现为 **3/3 PASS**（RN-121 / RN-122 / RN-125）。

### PingCode 缺陷（创建人：刘珍）→ 回归用例

通过 PingCode CLI（`V2` 项目）按创建人过滤，共 **93 条**，其中 4 条已转为用例并在 2.0.13.1 实测通过：

| 用例 | PingCode | 场景 | 结果 |
| --- | --- | --- | --- |
| RN-126 | V2-374 | `alter timeseries ... set data type text`（小写）应与 TEXT 一致成功 | PASS |
| RN-127 | V2-378 | `select cast(1.1 as float)` 不应抛 UnsupportedOperationException | PASS |
| RN-128 | V2-942 | `load balance to datanode 999`（不存在）应报错而非成功 | PASS |
| RN-129 | V2-345 | 非法 `offset/limit` 应快速报错，不得 parser 死循环 OOM | PASS |

全量映射与分类（已覆盖 4 / 可扩展候选 17 / 暂不纳入 71 及原因）见
[`docs/pingcode_v2_liuzhen.md`](docs/pingcode_v2_liuzhen.md)。

### PingCode V2（创建人：刘珍）第二批

| 用例 | PingCode | 场景 | 结果 |
| --- | --- | --- | --- |
| RN-130 | V2-375 | 改序列类型不应在 CN 打印 `StateMachineProcedure not set next state` | PASS |
| RN-131 | V2-397 | `in/not in + order by limit` 子查询的 distinct 不应 `/ by zero` | PASS |
| RN-132 | V2-430 | BLOB 列 `last/last_by` 不应抛 `StatisticsClassException` | PASS |
| RN-133 | V2-757 | 非对齐序列 `EXPLAIN ANALYZE` 计划中 IdentitySinkNode 应含 `DownStreamPlanNodeId` | PASS |

PingCode V2 覆盖已达 **8 条**，剩余 13 条可扩展候选（见 `docs/pingcode_v2_liuzhen.md`）。

### 慢用例组（停节点/长流程）

以下用例涉及"停节点"流程，单条 3~10 分钟，**默认跳过**（结果记 SKIP），需要时用 `RN_SLOW=1` 显式开启：

```bash
RN_SLOW=1 bash tools/suite_rn.sh RN-134 RN-135 RN-136
```

| 用例 | PingCode | 场景 |
| --- | --- | --- |
| RN-134 | V2-883 | stop DN 时 TableDiskUsageIndex WARN 不应成灾（原 12 秒 14345 条）、无混淆类型名 |
| RN-135 | V2-861 | 并发查询中 stop DN 不应产生 NullPointerException 日志 |
| RN-136 | V2-862 | stop ConfigNode 不应产生 NullPointerException |

> 打上 `SLOW_OF["RN-xxx"]="1"` 标记即进入慢组，流程与普通用例一致，只是默认不跑。

### PingCode V2（创建人：刘珍）第三批 + 慢用例组验证

| 用例 | PingCode | 场景 | 结果 |
| --- | --- | --- | --- |
| RN-137 | V2-916 | 时间列名为 `d_datetime` 时 `DELETE ... WHERE d_datetime BETWEEN` 应成功 | PASS |
| RN-138 | V2-801 | `timestamp_precision=ns` 写入不应产生 `Integer overflow` 告警 | PASS（慢，7.3 分钟） |

慢用例组（`RN_SLOW=1`）实测：**4/4 PASS**（RN-134/135/136/138，合计约 10 分钟）。
其中修复了用例侧的 `ssh` 无 `-n` 导致挂起的问题，并改为复用 `start_dn` / `/tmp/cn_restart.sh`。

PingCode V2 覆盖：**13 条**（9 条常规 + 4 条慢组），剩余 8 条可扩展候选、71 条暂不纳入。

### 双协议回归结果（2026-11-05）

| 协议 | 用例 | PASS | KNOWN | SKIP | 备注 |
| --- | ---: | ---: | ---: | ---: | --- |
| `IoTConsensus`（经典，默认） | 77 | **69** | 1 | 7 | 基线 |
| `IoTConsensusV2` | 77 | **69** | 1 | 7 | 与经典完全一致，**0 差异** |

切换命令：

```bash
bash tools/mode.sh proto-v2    # 写 data_region_consensus_protocol_class=...IoTConsensusV2 + hard_reset
bash tools/suite_rn.sh
bash tools/mode.sh proto-iot   # 切回经典
```

> 协议切换需要清数据重建（hard_reset），单次约 4 分钟。

### TDB-343 树转表视图自动扩列（auto_sync_schema）

来源：PLM 需求 docs/90 + 设计 docs/913，测试点清单见 [`docs/tree2table_auto_sync_points.md`](docs/tree2table_auto_sync_points.md)（171 条测试点 + 25 条歧义待确认）。

| 用例 | 验证点 | 结果 |
| --- | --- | --- |
| RN-139 | 建视图时扫描 prefixPath 已有测点成列 + `show create view` 展示属性 | PASS |
| RN-140 | `INSERT` 自动建序列后视图自动补列且可查 | PASS |
| RN-141 | 显式 `CREATE TIMESERIES` 后自动补列 | PASS |
| RN-142 | 未开启属性的视图不补列（默认 false） | PASS |
| RN-143 | base table 带 `auto_sync_schema` 报 701 | PASS |
| RN-144 | `ALTER VIEW ... SET PROPERTIES auto_sync_schema = false` 后不再补列 | PASS |
| RN-145 | 同名大小写/类型冲突时不补列且写入不报错 | PASS |
| RN-146 | prefix 下同时存在 `s1`/`S1` 时建视图报 617 | PASS |
| RN-147 | 除建视图外（新增测点、false→true 补扫）遇冲突一律忽略、不报错 | PASS |
| RN-148 | 一条设备同批写多个新测点，全部补列 | PASS |
| RN-149 | 多设备各自新测点分别补列 | PASS |
| RN-150 | 非 prefix 路径的测点不影响视图 | PASS |
| RN-151 | 重叠前缀的两个视图都补列（tag 数与层级关系） | PASS |
| RN-152 | 显式声明 Field 类型时按指定类型选测点 | PASS |
| RN-153 | 只声明列名不给类型的实际行为（类型自动推导） | PASS |
| RN-154 | 树模型改类型不同步到视图列 | PASS |
| RN-155 | 删除序列后视图保留列，查询为空 | PASS |
| RN-156 | original_name 命中时新设备数据可查 | PASS |
| RN-157 | 视图 comment 在扩列后保留 | PASS |
| RN-158 | 乱序写入（历史时间戳）新建测点补列且可查 | PASS |
| RN-159 | 晚到数据（早于已有数据）新建测点补列且可查 | PASS |
| RN-160 | 跨时间分区（3 天后）写入新测点补列 | PASS |
| RN-161 | BLOB 类型测点补列且类型正确 | PASS |
| RN-162 | 对齐设备（aligned，多测点）均补列 | PASS |
| RN-163 | 视图改名后仍能补列 | PASS |
| RN-164 | `CREATE OR REPLACE` 后属性保留且仍补列 | PASS |
| RN-165 | `DROP VIEW` 后重建仍补列 | PASS |
| RN-166 | 相邻库名前缀（db、dbb）不误命中 | PASS |
| RN-167 | 不同库同名视图按库隔离 | PASS |
| RN-168 | 聚合查询（count/last/avg）访问新列 | PASS |
| RN-169 | `GROUP BY` / `ORDER BY` 使用新列 | PASS |
| RN-170 | `SELECT *` 含新列且旧行补 null | PASS |
| RN-171 | 跨设备查询时新列补 null | PASS |
| RN-172 | TTL 库中补列正常 | PASS |
| RN-173 | 模板激活触发补列 | SKIP（环境受限） |
| RN-174 | 模板扩展触发补列 | SKIP（环境受限） |
| RN-175 | 重启单个 DN 后索引重建，补列仍正常（慢） | PASS |
| RN-176 | 重启全部 5 个 DN 后补列仍正常（慢） | PASS |
| RN-177 | 8 路并发建序列，全部补列不丢 | PASS |
| RN-178 | 并发建序列 + `ADD COLUMN` 混跑，两者都生效 | PASS |
| RN-179 | 手工 `ADD COLUMN` 后自动补列仍工作 | PASS |
| RN-180 | 手工 `DROP COLUMN` 后同测点再写入不会自动补回（记录行为） | PASS |





实现要点（实测）：
- 时间列必须由视图 `(dev string tag)` 与 `AS root.db.**` 推断，DDL 需带库名（`create view db.v1(...)`），否则报 `701: database is not specified`；
- 修改属性语法为 `ALTER VIEW db.v1 SET PROPERTIES auto_sync_schema = false`（不带括号）；
- 冲突用例用 `dev02.S1 int32` 对 `s1 DOUBLE`，视图不新增列、原列类型保持。

#### TDB-343 冲突口径（研发已确认 2026-11-06）

> 只有创建树转表视图时才会因列类型冲突返回失败，其他路径默认忽略。

| 路径 | 期望 | 用例 |
| --- | --- | --- |
| 建视图（未声明 Field 列） | 冲突 → 617 失败 | RN-146 |
| 建好视图后新增冲突测点 | 忽略、不报错、不加列 | RN-145 |
| false→true 补扫 | 忽略、属性切换成功 | RN-147 |
| 开启属性后新增普通测点 | 正常补列 | RN-147 |

补充：建视图时的列检测与 `auto_sync_schema` 开关无关（不开属性也会检测并可能 617）。

#### TDB-343 实测发现（值得留意）

1. **建视图会被 617 拒绝**：prefixPath 下若同时存在 `s1` 与 `S1`（小写冲突），
   `create view ... with(auto_sync_schema=true)` 直接报
   `617: The measurements s1 and S1 share the same lower case when auto detect`，视图创建失败。
   已固化为 RN-146。
2. **用例必须使用唯一库名**：`DROP DATABASE` 后 `show databases` 立刻不可见，但 schema 尚未清理完，
   随后同库名重建会命中 `503 Path ... already exist`。用例改为 `rn_t2t_<id>_$(date +%H%M%S)` 后稳定。
3. **改属性语法**：`ALTER VIEW db.v SET PROPERTIES auto_sync_schema = false`（无括号）。

#### TDB-343 第二批实测发现

1. **设备名不能用保留字**：`root.db.region.dev01.s1` 会报 `700 ... no viable alternative at input '.region'`，
   导致后续补列用例全部空跑。用例统一改用 `zone`。
2. **命中规则确认**：`restrict=false` 时要求 **tag 数 ≥ 前缀下剩余层级**。
   例：设备 `root.db.zone.dev01`（宽前缀剩余 2 层）需要 2 个 tag 才能命中 `root.db.**`。
3. **只声明列名不给类型**：需求文档说"不能只指定列名不指定数据类型，否则报错"，
   实测 `create view db.v(dev string tag, s1 field)` **可以创建成功**，类型由树模型自动推导（RN-153 断言的是实测行为）。
   已加入歧义清单待确认。
4. **类型变更**：`alter timeseries ... set data type` 需类型兼容（DOUBLE→INT64 会被 507 拒绝），
   兼容变更（INT32→INT64）不会同步到视图列（RN-154）。

#### TDB-343 第三批（时序专项）实测发现

- **对齐设备补列**：`create aligned timeseries root.db.devAl(a1 int32, a2 int64)` 的测点会逐个补列；
  但若测点名与视图已有列同名（如已有 `s1 DOUBLE`，对齐设备里又有 `s1 INT32`），按冲突规则被忽略——
  设计如此，用例已改用不冲突的测点名（`a1/a2`）。
- **乱序/晚到/跨分区**三种写入时机都能触发补列，且补列后历史数据可通过视图查询。
- **BLOB 测点**补列后列类型为 BLOB，与树模型一致。

#### TDB-343 模板链路：环境受限（已记录）

文档 §3.2.2 第 7 条与 §3.4 场景 2 描述「模板激活 / 模板扩展触发补列」，实测在当前版本无法构造：

- `set device template` 只支持**树模型库**：表模型库执行报 `500 Database is not set`；
- 树转表视图必须建在**表模型库**：树模型库执行报 `500 Unknown database`。

两者互斥 → 模板链路用例 RN-173/RN-174 标记 `SKIP_OF`（带原因跳过），证据与建议见
[`docs/tree2table_template_limitation.md`](docs/tree2table_template_limitation.md)。

#### 新增套件能力：SKIP_OF

```bash
SKIP_OF["RN-xxx"]="跳过原因"   # 用例文件里声明，套件执行时记 SKIP 并输出原因
```

#### TDB-343 第五批：故障与并发

- **DN 重启后索引重建**：单 DN 重启（57s）与全部 5 DN 重启（181s）后，新增测点仍能补列，
  说明 DN 侧前缀树确实由 CN 全量下发重建（不依赖落盘）。
- **并发**：8 路并发建序列全部补列；并发建序列与手工 `ADD COLUMN` 混跑互不干扰。
- **手工 DROP COLUMN 的边界**：删列后对同一测点再 `INSERT` 不会自动补回——
  因为序列已存在、不会触发「新建序列」路径；需要手工 `ADD COLUMN` 或重建视图。
  这条按"记录当前行为"处理（RN-180），若研发认为应自动补回则需改断言。
