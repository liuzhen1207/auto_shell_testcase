# 磁盘占用统计 skill（diskusage_skill）

IoTDB / TimechoDB **2.0.12.1** 磁盘空间占用统计（`SHOW DISK_USAGE` / `information_schema.table_disk_usage`）
的自动化用例集 + **TDB-629「show disk_usage 导致合并卡死」回归门禁**。

| 项 | 内容 |
| --- | --- |
| 目标版本 | **RC6 `v20121rc6_1010_7ae8713e`（2.0.12.1 / `7ae8713e`）**；门禁另需在修复前版本 **RC5 `v20121rc5_1003_aaf460d`** 对照 |
| 环境 | 99.80 框架机（`/data/iotdb/autotest/`）+ 3C3D 集群 192.168.99.77/78/79，RF=3，IoTConsensus |
| 入口 | `bash tools/run_all.sh --set gate\|stats\|quick\|all [--only DU-01,…] [--ver <版本目录名>]` |
| 双版本门禁 | `bash tools/run_gate_versions.sh`（自动切/还原 `conf/test.conf`，RC5 复现 → RC6 验证） |
| 结果 | `results/test_result.csv`、`results/<ID>_<runid>.out`、`results/SUITE_*.out` |
| 本机路径 | `D:\IDEA\deepseek\ip99_80\diskusage_skill` |
| 交付归档 | `D:\IDEA\deepseek\compaction\`（含本 skill、验证报告与证据） |
| 99.80 部署 | `/data/iotdb/autotest/diskusage_skill` |

## 用例

| ID | 模型 | 覆盖 |
| --- | --- | --- |
| **DU-01** | 树 | **TDB-629 门禁**：`SHOW DISK_USAGE FROM <db>.**` 统计后，被扫过的 TsFile 必须仍能被合并 |
| **DU-02** | 表 | **TDB-629 门禁**：`information_schema.table_disk_usage` 统计后合并必须仍能推进（库内需 ≥2 张表） |
| DU-03 | 树 | 统计正确性（有数据）：列语义、值与物理大小关系、`*`/`**`/设备级 pattern 作用域、多库隔离、ORDER BY/LIMIT、空结果集 |
| DU-04 | 表 | 统计正确性（有数据）：列语义、表间差异、where 过滤、GROUP BY 聚合一致性、不存在的表→空集、视图不出现 |
| DU-05 | 树+表 | 权限与错误路径：无 SYSTEM 权限被拒、授权后可执行、非法 pattern 报错、表模型越权行为 |

## 文档

- `SKILL.md`：操作手册（怎么跑、判据、踩坑清单）
- `docs/DESIGN.md`：功能与代码链、**TDB-629 根因与修复**、门禁设计
- `docs/REQ_diskusage.md` + `docs/req_disk_usage.txt`：需求文档要点与正文抽取件
- `docs/RESULTS.md`：逐轮实测结果（含修复前/后对照）
