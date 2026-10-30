# 172.20.70.17（DELL R730）

- 每个模块是一个 `*_skill/` 包，可整体拷到测试机直接跑（`tools/run_regression.sh` 一键回归）。
- 运行产物（`results/`、`logs/`、`*.out`）不提交，见仓库根 `.gitignore`；各包内的 `SSH_PASSWORD` 一律留空，请用免密公钥或自行填本地密码。

| 模块 | 覆盖 | 入口 |
|---|---|---|
| `remove_cn_dn_skill/` | 摘除 ConfigNode/DataNode、`MIGRATE REGION`、缩容，以及 OBJECT 字段在迁移下的正确性（含单点 4 GiB） | `tools/run_regression.sh` |
| `proactive_regiongroup_skill/` | RegionGroup 积极扩容（`PROACTIVE` 策略）全量回归：216 例，覆盖默认值/空库/不同 slot 与同 slot 扩容/单设备 50 万测点/资源上限/策略切换/高可用/升级与双协议 | `run_all_proactive.sh` 或 `scripts/pg.sh` |
