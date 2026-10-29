# 172_20_70_13_5C20D —— 5CN + 20DN 专项回归

| 项 | 值 |
|---|---|
| 跳板机 | 172.20.70.13 |
| 集群 | **5 ConfigNode + 20 DataNode**（172.20.70.100–119） |
| 数据面 | `IoTConsensus`（默认） |
| 版本线 | TimechoDB `2.0.11-SNAPSHOT` / `2.0.12.1`，当前验证 BuildInfo **`dc11a35`** |

## 用例包

| 目录 | 模块 | 用例数 | 说明 |
|---|---|---|---|
| `tree_view_skill/` | 树转表视图（含 Pipe 数据同步） | **55** | 单集群 46 + pipe 9；需求 docx / doc 90 / doc 913 / TDB-343 |
| `proactive_skill/` | RegionGroup 主动扩容 | 约 170 | 扩容策略、限流、开关、泄漏、升级 |

## 环境用法要点

- **单集群档位**：5CN + 20DN，SR3/DR3（`tree_view_skill/conf/cluster.treeview_5c20d.conf`）；
- **Pipe 档位**：20 节点拆两套，发送端 .100–.109 / 接收端 .110–.119，各 5CN+10DN、**SR5/DR3**
  （`cluster.pipe_sender.conf` / `cluster.pipe_receiver.conf`）；
- 两套档位**共用同一批物理机**，因此 pipe 组前后都必须 `teardown` 两端；
- `prepare` 会 `rm -rf data/`，**同一环境严禁并发跑两个队列**。

## 已跑版本与结论

| 版本 | 结论 |
|---|---|
| `dc11a35` | 树转表：单集群 35/41 PASS、Pipe 6/9 PASS（功能 9/9 全过）；缺陷 TDB-890 / TDB-894 已录 PLM |
