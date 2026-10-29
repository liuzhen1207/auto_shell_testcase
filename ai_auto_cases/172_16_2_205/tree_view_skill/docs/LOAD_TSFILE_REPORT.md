# LOAD TSFILE × 树转表视图自动补列 测试报告

## 1. 结论

| 指标 | 数值 |
| --- | --- |
| 用例数 | 8（TV-090 ~ TV-097） |
| PASS | 8 |
| FAIL | 0 |
| 执行耗时 | 约 400 秒 |
| 日志 | 全部 0 条非预期 ERROR（TV-097 的重启噪声已在重启完成后重设日志窗口排除） |

**核心结论：`LOAD` 一个 TsFile、其中包含视图前缀下**新测点**时，会触发树转表视图自动补列**——列被正确补上（含数据类型），且加载的数据可立即通过视图查询。这填补了此前"补列触发入口"只覆盖 `CREATE TIMESERIES / INSERT / 模板` 的空白。

## 2. 关键前置：LOAD 的文件必须在执行 DN 本地

`LOAD` 报错 `701: Can not find /path on this machine, notice that load can only handle files on this machine`——文件必须落在**执行该语句的 DataNode** 本地磁盘，而不是客户端（205）。用例统一按下述流程准备：

1. 在目标前缀下建库/测点/写入并 `FLUSH`，得到 TsFile；
2. 在某个 DN 上定位该 TsFile，`cat` 到 205，再 `scp` 到 5 个 DN 的 `/tmp/<db>/load.tsfile`；
3. 删除这些测点（保留库与视图），使 `LOAD` 时是"新建测点"；
4. `LOAD '/tmp/<db>/load.tsfile'` 在首个能读到文件的 DN 上执行。

## 3. 用例与结果

| 用例 | 场景 | 结果 | 观测 |
| --- | --- | --- | --- |
| TV-090 | LOAD 含 3 个新测点（INT32/INT64/FLOAT）的 TsFile | PASS | 视图自动补出 `s1 INT32`、`s2 INT64`、`s3 FLOAT`；`select *` 返回 1 行（d1，s0 为 null） |
| TV-091 | LOAD 的测点列在视图中**已存在** | PASS | 列保持，数据可查；本场景**未**出现 `ViewColumnAutoSyncTrigger 552/305` ERROR |
| TV-092 | 混合：`s1` 已在视图，TsFile 含 `s1 s2 s3` | PASS | `s1` 保持，新增 `s2`、`s3` 补齐 |
| TV-093 | LOAD 的测点落在视图前缀**之外** | PASS | 视图未新增列；数据正确加载到自身前缀 |
| TV-094 | 视图 `auto_sync_schema=false`（默认） | PASS | LOAD 不补列 |
| TV-095 | `RESTRICT`（2 tag）视图 + TsFile 内是 1 层设备 | PASS | 视图行数为 0（层级不匹配不收录） |
| TV-096 | 同一文件 LOAD 两次 | PASS | 列不丢失、不重复；行数行为已记录待研发确认（去重策略） |
| TV-097 | LOAD 补列后重启一台 DN | PASS | 列与数据持久化，重启后仍可查 |

## 4. 与既有缺陷的关系

- 本组**没有**复现 `ViewColumnAutoSyncTrigger 552/305` 日志缺陷（TV-091 这类"列已存在"场景在 LOAD 路径下 0 条 ERROR）——推测 LOAD 侧补列请求的去重/顺序与 `CREATE TIMESERIES` 路径不同，值得研发确认是否属于"两条路径行为不一致"；
- 改名缺陷（TDB-888）与本组无关。

## 5. 需要研发确认的点

1. **重复 LOAD 的去重语义**（TV-096）：目前列不重复，行数是否应去重需明确（本用例只记录，不判定）；
2. **LOAD 路径为何未触发 552/305**：与 `CREATE TIMESERIES` 路径行为不一致，若 `CREATE` 侧修成幂等，LOAD 侧也应统一；
3. **RESTRICT + LOAD**（TV-095）只覆盖了"层级不匹配不收录"，建议补一条"层级匹配时补列"的正例（需要构造 2 层设备的 TsFile）。

## 6. 执行方式

```bash
ssh root@172.16.2.205 'cd /data2/auto_test/treeview_suite && bash suite.sh TV-090 TV-091 TV-092 TV-093 TV-094 TV-095 TV-096 TV-097'
```

| 内容 | 路径 |
| --- | --- |
| 用例脚本 | `scripts/cases/g9_load.sh`（含 `build_tsfile` / `do_load` 助手） |
| 本轮结果 | 远端 `results/run_20261028_210654/`；TV-097 复跑 `results/run_20261028_211502/` |
| 逐例输出 | 同目录 `<ID>.out`、`<ID>_logdelta/` |
