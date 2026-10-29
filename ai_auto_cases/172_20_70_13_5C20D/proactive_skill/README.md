# proactive_skill —— 5C20D 主动扩容（RegionGroup）回归

被测特性：SchemaRegion / DataRegion 的**主动扩容**与相关策略、限流、开关、泄漏观测。

| 项 | 值 |
|---|---|
| 环境 | 5 CN + 20 DN（172.20.70.100–119） |
| 用例数 | **约 170 条**（`cases*.py` 合计） |
| 需求来源 | PROACTIVE 需求文档（见 `references/proactive-spec.md`） |

## 目录

| 路径 | 说明 |
|---|---|
| `scripts/pgkit/` | 用例与 harness（`cases.py` + `cases_cfg/dev/ha5/leak/lim/msr/npe/ops/ops2/swch/upg.py`） |
| `cases/MANIFEST.md5` | 用例模块清单 |
| `MANIFEST.md5` | 本 skill 全量文件清单 |
| `conf/` | 各档位 conf（3C3D / 5C20D / 多协议 / 升级） |
| `docs/`、`references/` | 设计说明与规格速查 |

## 运行

```bash
bash scripts/pg.sh --conf conf/cluster.proactive_5c20d.conf selftest
bash scripts/pg.sh --conf conf/cluster.proactive_5c20d.conf run --case PG-SMK-01
```

> 本目录未包含 `results/` 与日志（按仓库约定不提交运行产物）。
