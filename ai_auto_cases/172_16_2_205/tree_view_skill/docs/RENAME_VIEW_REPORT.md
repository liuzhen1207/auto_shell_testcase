# 序列改名 × 树转表视图 测试报告

## 1. 依据

| 来源 | 用到的条款 |
| --- | --- |
| PLM 文档 **211**《树转表——需求分析（V2.0.5.1-开源）》 | §2.1.1.1「TAG：每个 Tag 列按顺序对应 prefixPath 后面层级的路径节点」；§2.1.1.3「视图包含 prefixPath 下一层起的设备，RESTRICT 时层级 == tag 数、否则 <= tag 数」；§2.1.1.4「只包含声明的 FIELD 列对应测点，缺失/类型不符时该列恒为 NULL」 |
| PLM 文档 **210**《树自动转设备表视图——查询规划&执行——详细设计》 | tag 列取值走 deviceId 中的 index（解释了 TAG 为何绑定"物理设备身份"） |
| 源码 dc11a35 | `ALTER TIMESERIES old RENAME TO new` → `RenameTimeSeriesProcedure#processPhysicalToAlias`：新路径 `CREATE_ALIAS_SERIES`、旧路径 `MARK_SERIES_INVALID` |
| 已知缺陷 | **TDB-888**（D1：改名后视图 TAG 返回旧设备名；D2：跨库改名后目标库视图 0 行） |

被测版本：TimechoDB 2.0.11-SNAPSHOT / **dc11a35**；集群 3C5D，SR3/DR2，IoTConsensusV2；客户端 172.16.2.205。

## 2. 结论

| 指标 | 数值 |
| --- | --- |
| 用例数 | 10（TV-080 ~ TV-089） |
| PASS | 6 |
| FAIL | 4 |
| 断言失败全部归因 | 4 条均命中 **TDB-888**（D1 ×3、D2 ×1），无其它断言失败 |
| 执行耗时 | 约 330 秒（每例含 sync lag 归零与 8 节点日志增量检查） |
| 日志 | 仅 TV-088（重启 DN）出现 17 条重启类 ERROR，属预期噪声；其余用例 0 ERROR |

**结论**：改名的"数据结构迁移"和"清理链"是好的（跨库改名后数据确实到了目标库、SHOW INVALID TIMESERIES 能给出 NewPath、删别名后源库可删、RESTRICT 视图仍能命中同层级设备、往返改名数据可见）；**问题集中在视图与改名元数据的同步**：TAG 仍按物理设备身份返回旧名（D1，违反 §2.1.1.1），跨库改名后目标库视图枚举不到别名设备（D2，违反 §2.1.1.3）。两者即 TDB-888 已登记内容，本组用例可作为其回归集。

## 3. 用例与结果

| 用例 | 场景 | 结果 | 关键观测 |
| --- | --- | --- | --- |
| TV-080 | 同库整设备改名（d1→d9）后查视图 TAG | **FAIL** | `select dev from tv080.v1` 返回 `d1`，应为 `d9`（§2.1.1.1） |
| TV-081 | 设备改名 + `auto_sync_schema=true` | **FAIL** | 数据 2 行可见（迁移正常），但 TAG 仍 `d1`（§2.1.1.1） |
| TV-082 | 跨库改名（`root.tv082a` → `root.tv082b`）后目标库视图 | **FAIL** | 树侧 `count(*)=1`，视图 `count(*)=0`（§2.1.1.3） |
| TV-083 | 跨库改名后 `DROP DATABASE` 源库 | PASS | 报 `708 / TSStatus(507): cannot delete database ... contains 1 invalid time series`；`SHOW INVALID TIMESERIES` 给出 `NewPath=root.tv083b.d1.s1` |
| TV-084 | 删别名后删源库（官方清理链） | PASS | `DELETE TIMESERIES <NewPath>` → `SHOW INVALID` 为空 → `DROP DATABASE` 成功 |
| TV-085 | 改名到不存在的库 | PASS（待确认） | 语句成功且自动建库（`root.tv085new` 出现在 `SHOW DATABASES`）——与 `CREATE TIMESERIES` 在不存在库上报错的行为不一致，属 D4 待研发判定 |
| TV-086 | 同设备单测点改名（`s1→s9`）+ auto_sync | PASS | 原列 `s1` 保留；**改名未触发补列**（`s9` 未出现）——符合当前实现"只有 create 事件触发补列"，但与用户直觉可能不符，建议文档明确 |
| TV-087 | `RESTRICT` 2 tag 视图 + 设备改名（`p.q→p.r`） | PASS | 改名后 restrict 视图仍返回 2 行（层级不变） |
| TV-088 | 改名后重启一台 DN，再查 TAG | **FAIL** | 重启后 TAG 仍 `d1`（D1 非内存态，属持久化数据）；17 条 DN 重启类 ERROR 为预期噪声 |
| TV-089 | 往返改名（`s1→s9→s1`）后查视图 | PASS | 2 行数据可见；无残留 invalid 序列告警 |

## 4. 缺陷对照（均已在 TDB-888 登记）

| 编号 | 现象 | 违反条款 | 本组用例 | 置信度 |
| --- | --- | --- | --- | --- |
| D1 | 设备改名后视图 TAG 仍返回旧设备名；改名后写入的数据也显示旧设备名 | §2.1.1.1 TAG = prefixPath 后面的路径节点 | TV-080 / TV-081 / TV-088 | 高，稳定复现 |
| D2 | 跨库改名后目标库视图 0 行（`show devices` / 树查询有数据） | §2.1.1.3 视图应包含 prefixPath 下设备 | TV-082 | 高，稳定复现 |

根因（源码）：`RenameTimeSeriesProcedure#processPhysicalToAlias` 只在新路径建 alias、把旧路径标 invalid，**物理设备节点没有改名**；视图 tag 列取值走 deviceId 里的索引（设计文档 210），因此拿到旧名；视图设备枚举以"有物理序列的设备"为准，别名设备被漏掉。

## 5. 需要研发/文档确认的项

1. **D4**：`ALTER TIMESERIES ... RENAME TO root.<不存在的库>.…` 会自动建库（TV-085）。是否应报错，需与 `CREATE TIMESERIES` 的行为对齐；
2. **改名是否应触发自动补列**（TV-086）：当前不触发（改名不是 create 事件）。若产品期望"改名后视图跟着补列/改名"，则需在 `RenameTimeSeriesProcedure` 后追加视图同步；
3. **TAG 取值口径**：若"TAG 按物理设备身份取值"是既定设计，需求文档需补一句"改名的设备在视图中 TAG 不变"，否则 D1 应视为缺陷修复（当前 TDB-888 已按缺陷登记，待研发结论）。

## 6. 执行方式与证据

```bash
# 只跑改名组
ssh root@172.16.2.205 'cd /data2/auto_test/treeview_suite && bash suite.sh TV-080 TV-081 TV-082 TV-083 TV-084 TV-085 TV-086 TV-087 TV-088 TV-089'
```

| 内容 | 路径 |
| --- | --- |
| 用例脚本 | `scripts/cases/g8_rename.sh` |
| 本轮结果 | 远端 `results/run_20261028_202314/`（TV-082 修正后单独复跑：`run_20261028_203845/`） |
| 逐例输出与日志增量 | 同目录 `<ID>.out`、`<ID>_logdelta/` |
| 需求/设计原文 | `records/plm_211_tree2table_requirement.md`、`records/plm_210_tree2table_design.md` |
| 已知缺陷 | TDB-888（itemId 1480）；确认报告 PLM doc 1225 |
