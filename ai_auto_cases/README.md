# ai_auto_cases

AI 辅助生成 / 维护的自动化回归用例集，按**被测环境**分目录存放。

## 目录

| 目录 | 环境 | 内容 |
| --- | --- | --- |
| `192_168_99_80/` | 跳板机 192.168.99.80 + 3C3D 集群（192.168.99.77 / .78 / .79，RF=3） | TimechoDB 2.0.12.1 的**合并 / CRUD / WAL** 三套专项回归（compaction 52、crud 15、wal 27） |
| `172_16_2_205/` | 跳板机 172.16.2.205 + 3C5D 集群（CN .26/.27/.28，DN .2~.6，SR=3 / DR=2） | 树转表视图 `auto_sync_schema` 回归（tree_view_skill，67 条） |

## 与原 `auto_shell_testcase/` 的关系

`auto_shell_testcase/` 下是历史手工维护的用例（按机房/集群分目录）。
本目录是**新的组织方式**：用例以 skill（可独立运行、带自检与清单校验的用例包）为单位提交，
每个 skill 自带 `lib/`、`conf/`、`tools/`、`docs/`，可直接拷到测试机上跑。

## 约定

- 用例源码与 `cases/MANIFEST.md5` 必须同步提交（清单用于 preflight 校验）。
- 不提交 `results/`、`*.out`、日志与 artifact（运行产物）。
- 每个环境目录下写一份 `README.md`，说明用例清单、运行方式、已跑版本与结论。
