# PGC-09 升级场景测试方案（2.0.12.1 RC12 → 2.0.13.1 RC1）

## 1. 目标

验证升级后：

1. 显式配置的 `AUTO` 策略被保留，不被新版本默认值 `PROACTIVE` 覆盖；
2. 已有数据库、RegionGroup、分区映射和数据不丢；
3. 升级后切换为 `PROACTIVE` 能正常扩容；
4. 升级过程中配置项在新旧版本间的兼容行为（旧版本不识别 `PROACTIVE`）。

## 2. 环境

| 项 | 值 |
| --- | --- |
| 起始版本 | 2.0.12.1 RC12（待上传） |
| 目标版本 | 2.0.13.1 RC1 `ab6d3de`（已部署在 `/data1/iotdb/v20131rc1_1030_ab6d3de`） |
| 集群 | 3C5D（CN .8/.9/.10，DN .11~.15） |
| 副本 | SR=3 / DR=3 |
| 数据目录 | `/data1/iotdb/<version>/data`（升级时保留） |

## 3. 步骤

### 3.1 RC12 基线

1. 解压 RC12 到 `/data1/iotdb/v20121rc12_*`；
2. 配置节点地址、`cn_seed_config_node=172.16.2.8:10710`、`cluster_name`、SR/DR=3；
3. 显式写入：
   ```properties
   schema_region_group_extension_policy=AUTO
   data_region_group_extension_policy=AUTO
   ```
4. 启动 CN（3 个）→ DN（5 个），确认 8 节点 Running；
5. 建库 `root.upg`，写 6 个不同 slot 设备各 1 条（记录 Data/Schema 组数，预期 AUTO 下 1/2）；
6. 记录 `SHOW SCHEMA/DATA REGIONS OF DATABASE root.upg` 的 RegionId 集合与行数。

### 3.2 升级

1. 停止 DN、再停 CN（保留 `data/`、`conf/`）；
2. 把 RC12 的 `data/` 目录保留，替换二进制为 RC1（或用 RC1 目录 + 软链/拷贝 data）；
3. 启动 RC1 CN（3 个）→ DN（5 个）；
4. 检查：
   - `SHOW CONFIGURATION` 中两策略应为 **AUTO**（显式配置保留）；
   - `root.upg` 组数、RegionId 与升级前一致；
   - `SELECT` 历史数据可读、无丢失。

### 3.3 升级后行为

1. 在 AUTO 下继续接入 3 个新 slot，记录组数（预期按 AUTO 缓慢增长）；
2. 热更新：
   ```sql
   SET CONFIGURATION 'data_region_group_extension_policy'='PROACTIVE';
   SET CONFIGURATION 'schema_region_group_extension_policy'='PROACTIVE';
   ```
3. 为已有 slot 写新时间分区，验证 Data 组补到 `min(K, 上限)`；
4. 切回 AUTO，确认已创建组不回收。

### 3.4 回退（可选）

1. 切回 AUTO 后停集群；
2. 用 RC12 二进制 + 保留数据启动，确认旧版本可读、配置可解析（不含 `PROACTIVE`）。

## 4. 判定

| 检查 | 预期 |
| --- | --- |
| 升级后策略 | 显式 AUTO 保留 |
| 升级后组数/映射 | 与升级前一致 |
| 升级后数据 | 可查询、无丢失 |
| 切换 PROACTIVE | 正常扩容 |
| 回退 RC12 | 可启动、可读数据 |

## 5. 风险

1. RC12 与 RC1 的元数据/分区表格式需兼容，升级前备份 `data/`；
2. 升级过程中旧版本不能解析 `PROACTIVE`，故基线必须显式 AUTO；
3. 3C5D 只有一套环境，升级会覆盖当前 RC1 集群，需要先备份 RC1 目录或使用独立目录。

## 6. 待办

- [ ] 等待 RC12 安装包上传（路径确认后解压部署）；
- [ ] 备份当前 RC1 `data/` 或改用独立目录；
- [ ] 执行 3.1~3.4 并记录结果到 `PGC-09-upgrade-result.md`。
