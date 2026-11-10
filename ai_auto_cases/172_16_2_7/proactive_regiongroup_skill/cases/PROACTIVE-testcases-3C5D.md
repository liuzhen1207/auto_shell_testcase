# PROACTIVE RegionGroup 分配策略 — 基于 3C5D 的测试用例设计

> 依据：需求 [360](https://plm.infra.timecho.com/docs/360)、设计 [341](https://plm.infra.timecho.com/docs/341)
> 环境：3C5D（CN 172.16.2.8/9/10，DN 172.16.2.11~15），RC1 `ab6d3de`，8 核/节点，5×8=40 核
> 基线配置：`schema_replication_factor=3`、`data_replication_factor=3`、`series_slot_num=1000`、两个策略默认 `PROACTIVE`、最小数量 Schema=1 / Data=2

## 0. 本环境可算出的边界

| 项 | 公式 | 1 个普通库 | 2 个普通库 |
| --- | --- | --- | --- |
| SchemaRegionGroup 上限 | max(最小 1, ceil(1×5/库数/3)) | **2** | 1 |
| DataRegionGroup 上限（DR=3） | max(最小 2, ceil(0.5×40/库数/3)) | **7** | 4 |
| DataRegionGroup 上限（DR=2，当前配置） | max(最小 2, ceil(0.5×40/库数/2)) | 10 | 5 |

下文除特别说明外，用例按 **DR=3、1 个普通库** 设计，预期值为：3 个不同 slot → Schema 2 / Data 3；6 个 → 2/6；7 个 → 2/7；≥8 个 → 2/7 封顶。

## 1. 可直接执行的用例（3C5D）

### A. 配置与默认值

**PGC-01 新版本默认策略为 PROACTIVE**
- 前置：删除测试库；两策略参数不显式配置；DR=3。
- 步骤：1) 重启集群使默认配置生效；2) 依次创建 3 个不同 slot 的设备并写入；3) `SHOW SCHEMA/DATA REGIONS OF DATABASE` 统计去重组数。
- 预期：Schema=2、Data=3（AUTO 为 1/2），证明默认 PROACTIVE。

**PGC-02 显式 AUTO 覆盖默认值**
- 前置：配置 `data_region_group_extension_policy=AUTO`、`schema_...=AUTO`，重启。
- 步骤：同 PGC-01 接入 3 个设备。
- 预期：Schema=1、Data=2。

**PGC-03 显式 CUSTOM 按配额建组**
- 前置：两参数设 `CUSTOM`；建库时指定 `schema_region_group_num=3`、`data_region_group_num=4`（或对应建库参数），重启。
- 步骤：空库后执行一次缺失分区请求。
- 预期：Schema=min(3, 上限 2)=2、Data=4（CUSTOM 配额受各自上限钳制）。

**PGC-04 热更新单个 Data 策略**
- 前置：默认 PROACTIVE，已有 2 个 Data 组。
- 步骤：`SET CONFIGURATION 'data_region_group_extension_policy'='AUTO';` 后写入新 slot。
- 预期：仅 Data 行为按 AUTO，Schema 仍 PROACTIVE。

**PGC-05 热更新单个 Schema 策略**
- 步骤：`SET CONFIGURATION 'schema_region_group_extension_policy'='AUTO';` 后新建元数据分区。
- 预期：Schema 按 AUTO，Data 不受影响。

**PGC-06 非法值拒绝**
- 步骤：分别执行 `SET CONFIGURATION ...='proactive'`、`='PROACTIVE '`、`='FOO'`。
- 预期：均报错拒绝；随后查询/建组行为仍为原策略，不解释为 PROACTIVE。

**PGC-07 无 SYSTEM 权限修改被拒**
- 前置：创建仅有读写权限的普通用户。
- 步骤：该用户执行两条 `SET CONFIGURATION`。
- 预期：权限错误，配置不变。

**PGC-08 两参数合并到一条语句**
- 步骤：`SET CONFIGURATION 'schema_...'='PROACTIVE','data_...'='PROACTIVE';`（或语法允许的合并写法）。
- 预期：按文档“不能合并”报错或仅一条生效，需确认（见第 3 节歧义）。

**PGC-09 配置文件显式 AUTO 升级后保留**
- 前置：配置文件写 `AUTO`，重启新版本。
- 预期：仍为 AUTO，不因默认值变 PROACTIVE 而覆盖；再热更新为 PROACTIVE 生效。

**PGC-10 切回 AUTO 不回收组**
- 前置：PROACTIVE 下已有 Data=6。
- 步骤：热更新为 AUTO；继续写入。
- 预期：组数保持 6，不减少；新分区按 AUTO 规则。

### B. 扩容计数与触发

**PGC-11 空库不预建组**
- 步骤：`CREATE DATABASE` 后立即查 Regions。
- 预期：两类组数均为 0。

**PGC-12 仅改配置不建组**
- 步骤：在空库上执行两条 SET CONFIGURATION。
- 预期：组数仍为 0，直到出现缺失分区请求。

**PGC-13 3 个不同 slot 逐个接入**
- 步骤：按 `d0/d1/d2`（BKDR 落 327/328/329）逐个建模+写入。
- 预期：组数依次 1、2、3（Data）；Schema 依次 1、2、2。

**PGC-14 同设备增加测点不增组**
- 步骤：同一设备新增 2 个 measurement 并写入。
- 预期：Schema/Data 组数不变。

**PGC-15 同设备新增时间分区不增 slot 但可触发补组**
- 前置：先用 AUTO 接入 3 个不同 slot（3 个 slot、1 个 Data 组），再切 PROACTIVE，上限 7。
- 步骤：为已有 slot 写入一个新时间分区。
- 预期：不同 slot 数仍 3；因 G=1 < K=3，触发补组到 3，而不是因新增时间分区增加 slot 数。

**PGC-16 共槽设备不增组**
- 前置：构造两个 BKDR 同槽设备名（脚本枚举）。
- 步骤：两个设备分别建模写入。
- 预期：不同 slot 数 1，Data 组数不增加。

**PGC-17 批量请求一次补齐多个组**
- 步骤：单个批量写入请求包含 6 个不同 slot。
- 预期：一次补齐到 Data=6（若当前 1 组），不是逐个请求才增长。

**PGC-18 已达上限不再增**
- 步骤：接入 9 个不同 slot 设备。
- 预期：Data 封顶 7；Schema 封顶 2；仍返回全部 slot 的分区映射。

**PGC-19 请求含已有 slot + 新 slot**
- 前置：已有 3 个 slot、Data=3。
- 步骤：批量请求包含这 3 个 + 3 个新 slot。
- 预期：目标 K=6，新增 3 组，不重复计算已有 slot。

**PGC-20 重复请求不增组**
- 步骤：同一批设备重复写入相同 slot。
- 预期：组数不变。

**PGC-21 表模型同样生效**
- 步骤：在表模型库中建 3 个不同设备的表并写入。
- 预期：表模型 Schema/Data 组数按 PROACTIVE 增长（2/3）。

**PGC-22 多数据库独立计数**
- 前置：2 个普通库，DR=3。
- 步骤：两个库各接入 3 个不同 slot。
- 预期：各自独立计数；上限按 2 库分摊（Schema 1、Data 4）。

**PGC-23 系统库与审计库不计入分摊**
- 步骤：对比仅 1 个普通库与存在审计库时的上限（观察组数封顶）。
- 预期：审计库不降低普通库上限；普通库仍可达 7。

### C. 分配策略与恢复

**PGC-24 新组承接后续时间分区（INHERIT）**
- 前置：Data=2、6 个 slot，扩容到 6 组。
- 步骤：写入新时间分区，查分区映射。
- 预期：新时间分区可落到新增组，已有时间分区映射不变。

**PGC-25 SHUFFLE 不受优选映射影响**
- 前置：分配策略 `SHUFFLE`。
- 步骤：扩容后写新时间分区。
- 预期：按 SHUFFLE 选择，不套用重平衡的优选组。

**PGC-26 ConfigNode 重启后组数与映射保留**
- 步骤：停/启一个 ConfigNode 或重启 Leader；恢复后查组数和旧时间分区映射。
- 预期：组数、历史映射保留；新时间分区可用这些组。

**PGC-27 Leader 切换后策略表恢复**
- 步骤：kill CN leader，触发切换；查组数/映射并写新分区。
- 预期：恢复后映射均衡，新分区可用全部组。

**PGC-28 历史补写与未来分区分配**
- 步骤：扩容后写历史时间分区与未来时间分区各一批。
- 预期：历史补写优先继承后继分区，未来分区用优选组；结果分别符合 INHERIT 规则。

### D. 资源上限与节点变化

**PGC-29 上限随库数变化**
- 步骤：先建 2 个普通库（均无组），再分别接入 9 个不同 slot。
- 预期：每库上限按 2 库分摊为 Data=4、Schema=1，两库各自封顶 4/1；对比 1 库场景的 7/2。

**PGC-30 `data_region_per_data_node` 热更新影响上限**
- 步骤：设 `data_region_per_data_node=2` 后重启/热更新，再接入到封顶。
- 预期：上限变为 max(2, ceil(2×5/1/3))=4（1 库）。

**PGC-31 节点下线后上限重算**
- 步骤：停 1 个 DN，等待节点 Unknown/Stopped，再接入设备。
- 预期：上限按 4 个 DN 重算（Data 6，Schema 2），不超新上限。

**PGC-32 节点恢复后上限提高**
- 步骤：恢复该 DN，再接入新 slot。
- 预期：上限回到 7，后续请求可继续补组。

**PGC-33 已有组数超过新上限时保留**
- 前置：已有 7 组，停节点使上限降到 6。
- 预期：已有 7 组保留，不删除；不再新增。

### E. 权限/审计/兼容

**PGC-34 配置审计字段**
- 前置：开启配置审计。
- 步骤：SYSTEM 用户改策略；普通用户尝试改；构造一次失败修改。
- 预期：审计含操作人、时间、配置键/值、客户端 IP、结果（含拒绝/失败）。

**PGC-35 自动扩容运行日志**
- 步骤：触发批量建组。
- 预期：日志含数据库、Region 类型、组、slot、节点、失败原因，且与请求关联；不含凭据/测点值。

**PGC-36 workbench/管理工具策略白名单**
- 条件：有可用的 workbench/集群管理工具。
- 预期：界面/工具可选 PROACTIVE；不一致修改被拒绝。

## 2. 受限或需要改造环境后可执行的用例（⚠️）

| 用例 | 目标 | 受限原因 | 改造方式 |
| --- | --- | --- | --- |
| PGC-37 升级保留显式 AUTO | RC11→RC1 升级后策略与组数 | 需要旧版本二进制与滚动升级流程 | 用 2.0.12.1 RC11 部署部分节点，升级后验证 |
| PGC-38 混合版本阶段 | 旧版本解析 PROACTIVE 的行为 | 需要新旧节点共存 | 部分节点保留 RC11，显式保持 AUTO |
| PGC-39 降级回退 | 回退前恢复 AUTO、组保留 | 需要回退流程 | 升级后再回退 RC11 |
| PGC-40 3 副本覆盖 9 节点 | 9D 下副本覆盖 | 环境只有 5 个 DN | 扩到 9D 或改用 6D/9D 集群 |
| PGC-41 少设备多测点性能对比 | AUTO vs PROACTIVE 吞吐/延迟 | 性能指标未定义；需 benchmark 设计 | 用 weather 配置改造，先定指标 |
| PGC-42 容器 CPU 限制变化 | 上限按上报 CPU 重算 | 节点非容器/无 cgroup 限制 | 在容器内改 CPU quota 重启 |

## 3. 当前环境不可执行、未设计的用例（❌）

| 用例 | 目标 | 不可执行原因 |
| --- | --- | --- |
| PGC-43 1C3D 拓扑 | 单 CN 三 DN 的组数增长 | 环境固定 3C5D，CN 不可减到 1 |
| PGC-44 1C6D / 1C9D 拓扑 | 6D/9D 上限 27/48 | 只有 5 个 DataNode |
| PGC-45 2C2D / 3C3D / 3C1D | 多拓扑组合 | 同上，拓扑不可变 |
| PGC-46 Disabled 全组补组 | 全部组 Disabled 时补 1 组 | 无公开接口把 LoadManager 组状态置 Disabled |
| PGC-47 组创建中 DataNode 不足 | NotEnoughDataNode 错误 | 需把可用 DN 降到 < 副本数，且不能影响 CN 选主 |
| PGC-48 Simple/Ratis 共识组合 | 不同共识下行为 | 当前仅 IoTConsensus（V1/V2 可切，Ratis 未部署） |
| PGC-49 workbench UI 策略适配 | 界面选项 | 环境无 workbench |
| PGC-50 多租户隔离 | 按租户的组数配额 | 产品当前无租户模型/文档未定义 |
| PGC-51 资源上限=0/1 边界 | 极小上限 | 5D 环境下限由公式决定，无法造 0 |
| PGC-52 最小组数 > 上限 | 上限钳制 | 需修改上限计算相关配额到极端值，可能与节点资源冲突 |

## 4. 未设计的原因汇总

1. **拓扑维度**：文档的 1C3D/1C6D/1C9D/3C3D 等对比依赖可变 CN/DN 数量，3C5D 固定环境无法覆盖；
2. **故障注入维度**：Disabled 全组、DN 不足、Simple/Ratis 共识需要产品内部开关或未暴露接口；
3. **工具维度**：workbench/集群管理工具、审计字段细粒度依赖 GUI/审计开启，当前环境不具备；
4. **版本维度**：升级/降级/混合版本需要旧版本二进制与滚动流程，可在 RC11 上另行搭建，但不在本轮 3C5D 基线内；
5. **性能维度**：文档明确“性能指标待确认”，缺少判定阈值，未设计可判决的性能用例。

## 5. 建议执行顺序

1. 先执行 A 组配置用例（PGC-01~10），确定默认值与热更新基线；
2. 再执行 B 组计数用例（PGC-11~23），每组用例前 `DROP DATABASE` 并重启/清理策略表；
3. 执行 C 组恢复用例（PGC-24~28），需停/起 ConfigNode；
4. 执行 D 组上限用例（PGC-29~33），需改配置/停 DN；
5. 最后执行 E 组权限/审计用例（PGC-34~36）。
