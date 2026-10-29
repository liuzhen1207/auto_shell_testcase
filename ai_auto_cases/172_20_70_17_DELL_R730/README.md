# 172.20.70.17（DELL R730）

- 每个模块是一个 `*_skill/` 包，可整体拷到测试机直接跑（`tools/run_regression.sh` 一键回归）。
- 运行产物（`results/`、`logs/`、`*.out`）不提交，见仓库根 `.gitignore`。

| 模块 | 覆盖 | 入口 |
|---|---|---|
| `remove_cn_dn_skill/` | 摘除 ConfigNode/DataNode、`MIGRATE REGION`、缩容，以及 OBJECT 字段在迁移下的正确性（含单点 4 GiB） | `tools/run_regression.sh` |
