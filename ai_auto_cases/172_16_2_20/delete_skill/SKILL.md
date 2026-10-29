# SKILL — DELETE 语义验证（3C5D）

每轮工作流：独立干净重置 → 配置副本与协议 → 启动 → 执行 SQL → 定位 region → 同步收敛门禁 →
五台 DN 停机恢复门禁 → 逐 DN 查询比对 → 归档证据。

## 1. 环境前提

| 项 | 值（见 `conf/env.conf`） |
| --- | --- |
| 客户端/协调机 | 172.16.2.20 |
| CN | .16 / .17 / .18 |
| DN | .19 / .21 / .22 / .23 / .24 |
| 副本 | SchemaRegion 3、DataRegion 2 |
| 协议 | 每轮写入 `data_region_consensus_protocol_class`（first_start 项，必须清库后重设） |

所有节点 root 免密 SSH。口令不落库，脚本从 `TEST_CONF` 的 `root_pw` 读取。

## 2. 每轮流程（`lib/run_round.sh`）

1. **重置**：停 8 节点 → 逐台校验进程归零 → 删该实例 `data/`、`logs/` → 写本轮协议 → 并行启动
   （seed CN 必须先起）→ 等到 `SHOW CLUSTER` 8/8 Running。
2. **执行用例**：`cases/<CASE>/run.sql` 经 CLI stdin 执行，保留原始输出与成功语句数。
3. **定位 region**：`USE <db>; SHOW REGIONS;` 解析本例 DataRegion；空则重试，再空则从 5 台 DN 的
   `syncLag` 指标枚举兜底；仍为空判 `FAIL_REGION`（不允许空集合静默通过门禁）。
4. **收敛等待**：轮询到每个相关 region 在集群中有 ≥2 个 0 lag 副本（RF=2）后开窗。
5. **基线窗口**：31 个样本 × 10 秒 = 5 分钟，全部为 0 才通过。
6. **五台 DN 停机门禁**：逐台 `kill -9` → 记录进程/端口 → 从存活 DN 查询（停机期行为）→
   重启并等进程与 6667 就绪（上限 360 秒，强杀后先排空 8~10 秒）→ 恢复查询 → 收敛 → 再来一个 31 样本窗口。
7. **逐 DN 比对**：五台 DN 执行同一只读查询，归一化后逐字比对。
8. **收尾**：`SHOW CLUSTER` 必须 8/8 Running；写 `results.tsv` 一行。

判定项相互独立：SQL 语义、物理证据、同步收敛、逐 DN 一致性、最终集群状态。

verdict 取值：`PASS` / `FAIL_LAG` / `FAIL_LAG_CONVERGE` / `FAIL_REGION` / `FAIL_OUTAGE` /
`FAIL_DN_DIFF` / `FAIL_FINAL_CLUSTER` / `FAIL_POST` / `FAIL_RESET` / `FAIL_CLUSTER`。

## 3. 语义与权限

- `PASS` 只代表机械门禁通过；行数/值是否符合预期需对照 `cases.tsv` 的 expected 人工核对。
  报告里保留每轮实际行数与结果 hash，并做**跨协议一致性**校验（同一用例两协议 hash 必须相同）。
- 权限负向（`DEL-NEG-001`）必须用**第二个 CLI 会话**以只读用户登录执行 DELETE，期望
  `803: Access Denied ... please add privilege DELETE`，并由 root 复核数据未变。单会话内无法验证权限。
- OBJECT 写完整对象用 `to_object(true,0,X'...')`；分片必须先 `to_object(false,...)` 再末片 EOF，
  否则对象不可读，不能作为 DELETE 判定依据。

## 4. 已踩过的坑（务必遵守）

| 坑 | 现象 | 规避 |
| --- | --- | --- |
| 用例 SQL 带 UTF-8 BOM | 首条 `SET SQL_DIALECT=TABLE` 解析出隐藏字符，建库失败、整轮空转 | 执行前剥 BOM（`run_round.sh` 生成 sanitized 副本），提交前检查 |
| 验证查询混入 `SHOW REGIONS` | `TsFileSize`/`CompressionRatio` 是各 DN 本地值，逐 DN 比对必然失败 | 验证查询只取 `SELECT` |
| JVM 用相对路径启动 | `-DCONFIGNODE_HOME=sbin/..`，按绝对路径 `pkill` 从不匹配，端口被旧进程占用 | 一律绝对路径启动；按主类 `com[.]timecho[.]iotdb` 匹配进程 |
| CN 主类含包名 | `com.timecho.iotdb.**service**.ConfigNode`，正则少写 `service` 会漏杀 | 用 `com[.]timecho[.]iotdb` 前缀匹配 |
| 强杀后立刻重启 | Ratis gRPC 不抢 TIME_WAIT，报 `Address already in use` | 停止后 `sleep 8~10`，启动失败按 25 秒退避重试 |
| lag 不按 region 过滤 | 无关 region 的残留 lag 计入，永远过不了门禁 | 只采样本例相关 DataRegion |
| 内存泄漏用 RSS 判定 | RSS 含已提交堆，GC 不回落，会把预热当泄漏 | 每 N 轮 `jcmd GC.run` 后读 `GC.heap_info` 的 used，只拟合稳态段 |

## 5. 内存泄漏专项（`tools/memleak_study.sh`）

与矩阵分离：每例 200 轮 × 100 设备的写删 churn，每 20 轮对 5 台 DN 强制 GC 后读堆，
预热段（0~40 轮）不计入拟合，只对 40~200 轮做线性回归，阈值 50 KB/cycle。
分析用 `lib/memleak_analyze.sh`，输出 `studies/analysis.txt`。
