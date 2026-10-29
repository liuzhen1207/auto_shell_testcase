# delete_skill — DELETE 语义全量回归（3C5D / RC10）

TimechoDB DELETE 语义、内存与落盘删除、mods 标记、OBJECT 清理、副本一致性的自动化回归包。
3 CN + 5 DN，SchemaRegion 3 副本、DataRegion 2 副本，按轮次切换 `IoTConsensus` / `IoTConsensusV2`。

## 规模与结果

| 项 | 数值 |
| --- | --- |
| 用例矩阵 | 85 个 CASE ID / **163 个协议轮次**（IoTConsensus 85 + IoTV2 78） |
| 已执行 | 163 / 163 |
| 通过 | **161** |
| 失败 | 2（`DEL-TREE-002` / `DEL-TREE-004`，同一可复现的 1 秒级 syncLag 尖峰） |
| 累计执行时长 | 108h34m（去重后）；含重跑 122h19m / 184 次执行 |
| 单轮实测 | ≈ 40 分钟 |
| 被测版本 | TimechoDB 2.0.12.1 RC10 `c60ce63` |

详细结论见 [`docs/RC10-DELETE-FINAL.md`](docs/RC10-DELETE-FINAL.md)，逐轮机读报告见
[`docs/RC10-DELETE-REPORT.md`](docs/RC10-DELETE-REPORT.md)。

## 目录

| 目录/文件 | 说明 |
| --- | --- |
| `SKILL.md` | 方法论：每轮流程、五道门禁、判定口径、已知坑 |
| `cases.tsv` | 用例矩阵（case_id / model / protocol / stage / scenario / expected） |
| `cases/<CASE_ID>/run.sql` | 每例 SQL（建库建表 → 写入 → FLUSH → DELETE → 验证 SELECT） |
| `cases/<CASE_ID>/post.sh` | 可选钩子，用例执行后运行（目前用于 `DEL-NEG-001` 的权限负向） |
| `cases/MANIFEST.md5` | 用例文件清单，用于 preflight 校验 |
| `conf/env.conf` | 地址、端口、路径、协议、门禁参数（不含口令） |
| `conf/manifest-IoTConsensus.tsv` / `conf/manifest-IoTV2.tsv` | 两协议的执行顺序清单 |
| `lib/` | 集群控制与单轮执行器 |
| `tools/` | 矩阵调度、报告生成、内存泄漏专项 |
| `docs/` | 最终报告与逐轮报告 |

## 快速开始

```bash
# 1) 部署到测试机（默认 /data2/iotdb/rc10_matrix）
scp -r delete_skill root@172.16.2.20:/tmp/
ssh root@172.16.2.20 "bash /tmp/delete_skill/tools/install.sh"

# 2) 先跑单例验证链路（约 40 分钟，含完整门禁）
ssh root@172.16.2.20 "bash /data2/iotdb/rc10_matrix/scripts/run_round.sh IoTConsensus DEL-MEM-001"

# 3) 全量：先 IoTConsensus 85 轮，再 IoTV2 78 轮，结束后自动出报告
ssh root@172.16.2.20 "setsid nohup bash /data2/iotdb/rc10_matrix/scripts/run_all.sh \
  > /data2/iotdb/rc10_matrix/logs/run-all.nohup 2>&1 &"

# 4) 进度与报告
ssh root@172.16.2.20 "cat /data2/iotdb/rc10_matrix/results/results.tsv"
ssh root@172.16.2.20 "bash /data2/iotdb/rc10_matrix/scripts/make_report.sh"
```

矩阵可续跑：`results.tsv` 里已 PASS 的轮次自动跳过；连续 3 次集群级失败自动中止。

## 用例分组

| 分组 | CASE | 关注点 |
| --- | --- | --- |
| 内存阶段 | `DEL-MEM-001..008` | 未 flush 数据删除、删后重写、删后不 flush 重启 |
| 落盘阶段 | `DEL-FLUSH-001..008` | 单/多 TsFile、跨 time partition、删后新写 |
| 混合 | `DEL-MIX-001..003` | 内存 + 落盘同条件删除 |
| 时间谓词 | `DEL-TIME-001..008` | `=`、`<`、`<=`、`>`、`>=`、反向区间、时间精度 |
| 标签谓词 | `DEL-PRED-001..014` | TAG/ATTRIBUTE 组合、OR/DNF、LIKE、IN、负向 |
| 列类别 | `DEL-CAT-001..005` | 整行删除、TAG 仅过滤、ATTRIBUTE、单/多 FIELD 拒绝 |
| OBJECT | `DEL-OBJ-001..008` | 完整对象、多片 EOF、多个对象、JSON 负向、非法 offset、GC 并发 |
| mods | `DEL-MODS-001..005` | 内存标记、mods2、重复/相邻、compaction 前后、重启恢复 |
| 恢复 | `DEL-RESTART-001..002` | 重启 leader / follower 后结果一致 |
| 副本 | `DEL-REPL-001..006` | 全在线基准、逐台停 DN、同步未完成停 follower、停 leader |
| 并发 | `DEL-CONC-001..004` | 相邻/重复删除、与写入、与 FLUSH 并发 |
| 负向 | `DEL-NEG-001..002` | 无权限用户 DELETE（第二会话，803 拒绝）、不存在库/表 |
| 清理 | `DEL-CLEAN-001..002` | 只清本例库、失败保留现场 |
| 树模型 | `DEL-TREE-001..004` | 内存点删、落盘+mods、通配路径、逐 DN 停机 |
| 内存泄漏 | `DEL-MEMLEAK-TREE/TABLE-001..003` | 循环写删/全量删/元数据重建 |

## 注意

- 每轮会清空被测实例的 `data/`、`logs/`（仅 `conf/env.conf` 里的 `BUILD_HOME`），**该实例是专用测试实例**，不要指向共享环境。
- `DEL-NEG-001` 用 `conf/env.conf` 里的只读测试账号 `del_neg_reader` 在独立 CLI 会话执行 DELETE，期望 803 Access Denied。
- 证据（每轮 SQL、输出、lag 采样、五次 DN 门禁）留在测试机 `artifacts/`，不入库。
