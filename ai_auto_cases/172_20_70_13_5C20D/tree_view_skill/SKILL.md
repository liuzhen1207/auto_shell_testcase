# 5C20D 树转表视图（Tree View）测试技能

被测对象：图模型→表模型的 **树转表视图**，重点是 V2.0.13.1 新增的
**`auto_sync_schema`（自动检测新增测点并扩列）** 特性。

- 被测版本：`master_1026_dc11a35`（2.0.11-SNAPSHOT，BuildInfo `dc11a35`）
- 集群：5 ConfigNode + 20 DataNode（172.20.70.100-119），**SchemaRegion 3 副本 / DataRegion 3 副本**，
  共识协议用默认 `IoTConsensus`（本特性与协议无关）
- 源码：`/data/deepseek/timecho_src/master/timechodb`
- 需求：`docs/COVERAGE_TREEVIEW.md`（含 docx / PLM doc 90 / doc 913 / TDB-343 的逐条映射）

## 快速开始

```bash
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW
# 1) 部署（一次性；会清空 DB_DIR 并重新解包）
cd treeview_5c20d && bash scripts/pg.sh --conf conf/cluster.treeview_5c20d.conf deploy --clean && cd ..
# 2) 单条用例（干净集群：停 25 节点 → 清 data/logs → 写 conf → 启动）
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf tv1 TV-SYNC-03
# 3) 全量
bash treeview_5c20d/queue_treeview.sh      # 主队列 34 条
bash treeview_5c20d/queue_treeview2.sh     # 补充 7 条（参考用例回归）
```

## 目录

| 路径 | 说明 |
|---|---|
| `scripts/pgkit/cases_treeview.py` | **41 条用例**（`TV-BASE-*` / `TV-SYNC-*` / `TV-HA-*` / `TV-LEAK-*` / `TV-REF-*`） |
| `scripts/pgkit/` | 通用 harness（deploy / prepare / SQL / 收尾三件套 / 报告） |
| `conf/cluster.treeview_5c20d.conf` | 测试档位（SR3/DR3、默认共识、DB_DIR、结果目录） |
| `conf/nodes.conf` | 唯一允许写 IP 的拓扑文件 |
| `run_case_clean.sh` | 单用例驱动：干净集群 + **FAIL 时备份 CN/DN 日志** |
| `queue_treeview.sh` / `queue_treeview2.sh` | 串行队列 |
| `docs/COVERAGE_TREEVIEW.md` | 需求点 → 用例矩阵（含未覆盖项说明） |
| `docs/STATUS.md` | 建设与执行状态 |

## 每条用例固定的收尾三件套（框架自动追加）

1. **sync lag 归 0**（有界等待，超时 FAIL）；
2. **副本一致性**：全在线查询结果为基线 → **一次性停 2 台 DN** → 与基线逐字比对
   （20D 下只停一次，避免逐台停耗时过长）；
3. **CN/DN 日志扫描** ERROR/WARN，按 harness 动作时间窗归因，窗口外的未预期异常判 FAIL。

FAIL / 无结果时，`run_case_clean.sh` 会把该用例的 CN/DN 日志备份到
`results/<run>/cases/<CASE>/evidence/logs/{cn,dn}_<host>.tar.gz`。

## 判定纪律

- 只按 SQL 实际输出判定，不做宽松兜底；
- `SKIP`（环境不具备，例如需要两个集群的 pipe 同步、需要鉴权的权限用例）不算 PASS；
- 一条用例里任一 check 失败即该用例 FAIL。

## 用例族

| 族 | 条数 | 覆盖 |
|---|---|---|
| `TV-BASE-*` | 15 | create 语法、prefixPath 校验、自动扫列、FROM 改名、拒绝 attribute、RESTRICT、TTL、对齐 null 行、show tables/create、alter、comment |
| `TV-SYNC-*` | 16 | `auto_sync_schema` 默认值、create/aligned/multi/insert/模板触发扩列、只对树转表视图生效、大小写与 original_name 冲突、RESTRICT 正交、属性切换、删测点不删列、OBJECT 类型、ADD COLUMN OBJECT |
| `TV-HA-*` | 3 | 停 1 台 DN / 停 2 台 DN（SR3）/ 整集群重启 |
| `TV-LEAK-*` | 1 | 反复建删视图 + 新增测点：DN 线程不持续增长 |
| `TV-REF-*` | 6 | 参考 SQL 用例的回归场景（issue 0335/0364/0367/0420/0422、200 列宽视图、视图名） |
