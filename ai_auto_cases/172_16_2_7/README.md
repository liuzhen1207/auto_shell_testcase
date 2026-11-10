# 172.16.2.7 — 3C5D 环境用例集

| 项 | 内容 |
| --- | --- |
| 跳板机 | 172.16.2.7 |
| 集群 | 3C5D（CN 172.16.2.8/9/10，DN 172.16.2.11~15） |
| 版本 | 2.0.13.1 RC1 `ab6d3de` / RC2 `83183d0`；2.0.12.1 RC12 `c05111d`（升级/回退用） |
| 副本 | SR=3 / DR=3 |
| 维护人 | 刘珍 |

## 目录

| 目录 | 内容 |
| --- | --- |
| `proactive_regiongroup_skill/` | PROACTIVE RegionGroup 分配策略用例、结果、缺陷证据（含混合版本 TDB-1047、CUSTOM 规则、升级/回退） |
| `qa_liuzhen_skill/` | 基于 PingCode「刘珍」提交的 QA 用例自动化：catalog、日志门禁、缩容循环 |

每个 skill 一个独立目录，内部按 `cases/`、`results/`、`scripts/`、`defects/`、`evidence/` 归档。
