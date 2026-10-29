# 元数据 DDL 测试 skill —— 分阶段计划

目标：以 **TimechoDB/IoTDB 2.0.12.1 RC5** 为基线，做一套"以元数据为测试目的"的自动化 skill，
中间结果、用例、报告都放在本目录下，可迁移到其它环境。

"这个目标开始有点大，可以一点点分解" —— 下面按阶段推进，每阶段都有可独立交付的产物。

---

## P0 摸清 DDL 面（已完成）

| 项 | 产物 |
| --- | --- |
| 从源码语法 + 实测两侧确认支持的 DDL | `docs/DDL_INVENTORY.md` |
| 可复跑的探测工具 | `tools/probe_ddl.sh` + `docs/ddl_probe_list.tsv` |
| 探测结果（含错误码/消息） | `docs/DDL_PROBE_RESULT.tsv`（251 条）、`docs/DDL_PROBE_RESULT_r3.tsv`（48 条） |
| harness 与用例骨架 | `lib/common.sh`、`tools/{run_all,selftest,cluster_prepare}.sh`、`cases/cases.tsv` |

结论摘要：树模型 166 条语句可用、表模型亦可用；**85 条"失败"里绝大多数是产品明确的边界**
（未支持的语法/未实现的语句），这些全部转化为用例里的边界断言（`MD-T05`/`MD-B02`）。

---

## P1 树模型元数据基础（已完成，6 条用例）

`MD-T01` DATABASE ／ `MD-T02` TIMESERIES ／ `MD-T03` SCHEMA TEMPLATE ／
`MD-T04` 观测面（集群/区域/时隙/会话/版本） ／ `MD-T05` 失败路径与错误码 ／ `MD-T06` VIEW + TTL

## P2 表模型元数据（已完成，2 条用例）

`MD-B01` DATABASE/TABLE/COLUMN ／ `MD-B02` VIEW + information_schema 交叉校验

## P3 一致性与持久化（已完成，2 条用例）

`MD-C01` 副本一致性 + 重启持久化 + 跨模型命名空间隔离 ／ `MD-C02` 权限元数据

用例总数：**13 条**（P0-P3 的 10 条 + P4 的 3 条）。

---

## P4 三项优先方向（已完成，2026-10-10）

| # | 方向 | 用例 | 结果 |
| --- | --- | --- | --- |
| 1 | **真实 jar 的 UDF / Trigger 全链路** | `MD-U01` `cases/common/md_udf_trigger.sh` + `assets/udf/`（源码与构建分发脚本） | PASS 235s |
| 2 | **权限矩阵**（权限值 × 路径粒度 × 用户/角色） | `MD-C03` `cases/common/md_privilege_matrix.sh` | PASS 109s |
| 3 | **元数据规模**（2000 时序 / 200 表） | `MD-S01` `cases/common/md_scale_bulk.sh` | PASS 87s |

详细结论、失败路径错误码与"待研发确认的行为"见 [`P4_RESULTS.md`](P4_RESULTS.md)。

> 关于"用户和角色要不要再单独做"：**不需要**。USER/ROLE 的元数据闭环已由 `MD-C02` 覆盖；
> 权限矩阵方向是把用户/角色当**载体**去打权限值与路径粒度，没有另开用例。

本轮顺带修掉一个 harness 自身的坑：**CLI 在结果超过一批（1000 行/批）时会重复打印表头**，
旧的 `table_rows()` 只丢第一行表头，导致 2000 行结果被数成 2001 行（`selftest` 已加回归守卫）。

---

## P5 后续可继续分解的方向

按"价值 / 成本"排序：

| # | 方向 | 说明 | 预计用例数 |
| --- | --- | --- | --- |
| 1 | 元数据 DDL **并发** | 多会话同时建/删同库同表同时序，断言最终元数据一致、无残留、无重复注册 | 1~2 |
| 2 | 模板 + 视图 + 触发器 **组合场景** | 同一库上叠加多种元数据对象，重启后快照不变 | 1 |
| 3 | 配额元数据 | 打开 `quota_enable=true` 后 `SHOW SPACE/THROTTLE/USER QUOTA` 与 `SET` 的对应 | 1 |
| 4 | 触发器**状态转移** | `SHOW TRIGGERS` 的 `State` 在什么条件下变 INACTIVE；stateful 触发器 `restore()` 的完整链路（本轮只验证了 stateless） | 1 |
| 5 | 元数据 **磁盘落盘**核对 | 结合 `system/schema/...` 落盘文件与 `SHOW` 结果核对（需要只读 agent 或直接读文件） | 1 |
| 6 | 双协议对照 | 同套 13 条用例在 `IoTConsensusV2` 下复跑（`--consensus IoTConsensusV2`），对比有无差异 | 0（复用） |
| 7 | 表模型 UDF | 表模型支持 scalar/aggregate/table 三类函数（`SHOW FUNCTIONS` 类型列会不同），本轮只做了树模型 UDTF | 1 |

### 待产品确认的行为：**0 条**

四条"与直觉不符"的行为都已确认属于设计如此，并从观察项改成**用例里的硬断言**：

1. 视图出现在 `SHOW TIMESERIES` 列表 → `MD-T06` 第 3 步（研发确认）。
2. 多路径 `DROP DATABASE` 静默跳过不存在的路径、单路径报 508 → `MD-T01` 第 7 步（研发确认）；
   对照表见 `RESULTS.md` 2.1。
3. 权限读写表现（树模型 WRITE 隐含 READ + 读按权限过滤；表模型读写都硬校验）→ `MD-C03` 第 10~12 步
   （源码 `PathPrivilege.checkPrivilege` + 研发确认）。
4. **触发器 `ON <设备>` 不触发** → `MD-U01` 第 11 步（A/B 硬断言）。依据：文档《06-流计算-触发器》
   （`docs/refs/`）明确"被注册有触发器的**序列**将会被触发器侦听"，设备节点自身没有序列；
   详见 [`NOTE_trigger_path_pattern.md`](NOTE_trigger_path_pattern.md)。

> 第 4 条一度被误判为"疑似缺陷（源码漏收集设备节点自身的值）"——**教训：源码行为与直觉不符时，
> 先对照产品文档/设计说明再判缺陷。**

---

## 运行约定（避免重复踩坑）

- 每条用例跑完都会做**收尾三件套**：sync lag 归零 → 副本一致性（逐个停 DN 比对）→ CN/DN 日志异常分析；
  失败自动打包日志到 `results/artifact_<用例>_<runid>/logs/`。
- 用例之间靠 `MD_PREFIX`（默认 `md`）隔离库名，不与 TTL skill 的库冲突。
- `SKIP_LIFECYCLE=1` 复用已在跑的集群；调试单个用例时务必带上，否则每次都会停/清/启集群。
- 集群启停的两个环境坑已在 `lib/common.sh` 里处理：
  1. **激活窗口**：`cluster_clean` 后集群要重新激活，DN 在该窗口内注册会被拒并直接退出
     → 先起 CN、等端口监听、等激活落定，再起 DN，并在 6 轮里补起缺失进程；
  2. **Raft 文件锁**：上一个 JVM 没退干净会让新进程 `OverlappingFileLockException` 起不来
     → 启动前 `kill_stale_nodes` 硬清残留进程。
