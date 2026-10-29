# 192.168.99.80 —— 合并 / CRUD / WAL 专项回归用例

本目录是从测试机 **192.168.99.80** 上导出的一套自测用例（三个 skill），在被测集群
**3C3D（192.168.99.77 / .78 / .79，RF=3）** 上以 shell 驱动 TimechoDB 双向验证。

## 一、内容

| 目录 | 用例数 | 覆盖 |
| --- | --- | --- |
| `compaction_skill/` | 52（`cases.tsv`；冻结回归集 51 条，缩容 CO-12 单独跑） | 在线合并：seq/unseq/cross 内部与跨空间合并、DELETE 后合并、元数据变更后合并、多类型多编码、对齐序列、参数矩阵/热加载/Fast/repair/OBJECT TTL settle 等 |
| `crud_skill/` | 15 | CRUD 写路径：INSERT/UPDATE/DELETE、文本与 BLOB、`load`（同步/异步、table/tree、无值列文件）、UPDATE_NO_BLOB 等 |
| `wal_skill/` | 27 | WAL：模式与重启、`wal_dirs`/内存上限、压缩开关、单盘只读、对象文件、WAL 参数合法性、队列内存压力等 |
| `ttl_skill/` | 15 | TTL（数据过期清理）：树/表两模型的基础与过期清理、`SHOW TTL` 作用域、参数值/热加载、**expired_data_ratio 门控与写放大**（TDB-452 门禁）、**DataNode 重启重复注册**（TDB-610 门禁）、**tier 告警文案**（TDB-611 门禁）；含 4 个专项探针 |
| `metadata_skill/` | 13 | 元数据 DDL：DATABASE / TIMESERIES / SCHEMA TEMPLATE、表模型库表列、VIEW+TTL、权限元数据（树/表两套语义）、副本一致性+重启持久化、UDF/Trigger 全链路、权限矩阵、元数据规模（2000 时序 / 200 表）；含 `tools/probe_ddl.sh` 能力探测 |
| `diskusage_skill/` | 5 | `SHOW DISK_USAGE` / `information_schema.table_disk_usage`：**TDB-629 门禁**（统计查询泄漏读锁导致合并卡死，DU-01）、统计正确性、pattern 语义、权限 |

每个 skill 都是同构结构：

```
<skill>/
  cases/          # 用例脚本（common/ tree/ table/）
  cases.tsv       # 用例矩阵：ID / 脚本 / 描述（compaction 有）
  cases/MANIFEST.md5  # 用例与 lib 的校验清单（preflight 用）
  conf/env.conf   # 版本、节点、协议等环境配置
  lib/common.sh   # 断言/集群生命周期/收尾三件套
  lib/wal_ext.sh  # WAL 专用 helper（wal_skill）
  tools/          # run_all.sh / selftest.sh 等入口
  docs/           # 设计与踩坑文档
  README.md / SKILL.md
```

## 二、怎么跑

```bash
# 合并
cd compaction_skill && bash tools/run_all.sh --set regression --consensus IoTConsensus     # 或 IoTConsensusV2
# CRUD
cd crud_skill      && bash tools/run_all.sh --set all --consensus IoTConsensus
# WAL
cd wal_skill       && bash tools/run_all.sh --set all --consensus IoTConsensus
# TTL
cd ttl_skill       && bash tools/run_all.sh --set all --consensus IoTConsensus
# 元数据 DDL
cd metadata_skill  && bash tools/run_all.sh --set all
# 磁盘占用统计（TDB-629 门禁）
cd diskusage_skill && bash tools/run_all.sh --set all
```

> `metadata_skill` 的 `docs/refs/` 下是产品需求文档 PDF（约 4.4MB），未纳入本仓库；
> 需要时请从测试机 `/data/iotdb/autotest/metadata_skill/docs/refs/` 自取。

- 版本切换只改 `/data/iotdb/autotest/conf/test.conf` 的 `v_testdb` / `v_commit`；
  也可用 `V_TESTDB=<版本目录> BUILD_TAG=<commit> bash cases/...` 覆盖。
- 每条用例自管"停集群 → 清 data/logs → 写 conf → 起集群 → 断言 → 收尾"；
  收尾三件套 = **sync lag 归零 → 逐个停 DN 比对副本一致性 → CN/DN 日志异常扫描**。
- 跑前建议先 `bash preflight_manifests.sh`，确保 `cases/MANIFEST.md5` 与实际脚本一致（防"改过用例忘了同步清单"）。
- 缩容用例 `CO-12` 会把 DN/CN 真的移除（集群降为 2C2D，不自动恢复），
  已从冻结回归集里摘出，建议**单独、最后**跑。

## 三、已跑版本与结论（2026-10 ~ 2026-11）

| 版本 | 协议 | 结果 |
| --- | --- | --- |
| RC10 `c60ce63` | V1 / V2 | 160 PASS / 27 FAIL（含 2 条 harness 自身问题） |
| RC11 `ea4f835` | V1 / V2 | 162 / 25；新增失败 **0**（唯一变化是 harness 修复后 W-16 转 PASS） |
| RC12 `c05111d` | V1 → V2 | 进行中 |

**TTL skill 的验证记录**（同一 3C3D）：

| 版本 | 结果 |
| --- | --- |
| RC5 `aaf460d` | **13/13 PASS**（`--set all`，约 1h47m）；随后扩充到 15 条 |
| RC6 `7ae8713e` | TDB-610（`TP-04` 重启重复注册）、TDB-611（`TP-05` tier 告警文案）**均复现 FAIL**；对应修复 `e70fa1fc`、`2212855a76` 只在 master、**未回合 `rc/2.0.12.1`** |

## 四、2026-10-28/29 的用例侧修复（本轮）

| 用例 | 问题 | 修法 |
| --- | --- | --- |
| CO-15 | "场景不成立（副本未 seal）"被计成 FAIL | 降级为 WARN；新增兜底"一条判据都没判到才 FAIL" |
| W-18 | 第 316 行 `if [ ... -ge $(( ... )); then` **少一个 `]`** ⇒ 条件恒假，永远判"压力没打上去" | 补 ` ]` |
| W-19 / W-20 | 表模型库名写成 `root.walobj*`，被方言拒绝（700 mismatched input '.'） | 改为 `walobj` / `walobjld` |
| W-25 | ① "恢复后 WAL 文件数=0"被当失败（checkpoint 后清理属正常）② 副本一致性检查跑在"故意制造 WAL sync 失败"之后 | ① 降为 WARN ② 检测到 error 模式日志时跳过一致性，只做 sync lag + 日志扫描 |
| CO-41 | C 相"未见 object 文件(+0)"误判：全局净增量被同期 GC 抵消（本库精确计数其实是 120=40×3） | 判据改以"本库按 region 精确计数"为主、全局增量仅旁证 |
| W-11 | 16 项指纹里 `d1_seq_md5` 不同；实测两相 8000 行**只差 CLI 列宽对齐空格** | md5 前归一化空白；并在指纹时刻落盘行文件，便于 diff |
| W-24 | `wal_dir_roots` 同时 grep `(wal_dirs\|dn_wal_dirs)` 再 `tail -1`，命中模板里的旧键 `wal_dirs` ⇒ 把自定义目录读成默认目录 | 改为**优先 `dn_wal_dirs`**，旧键仅兜底 |

## 五、已知缺陷（不在本目录，仅供对照）

`CR-03`（load 表模型无值列文件被误判 tree-model、0 点仍返回成功，已登记 **TDB-873**）、
`CO-06`（V2 pipe 子任务 NPE，**TDB-836**）、`DT-09`（停机窗口内改类型 CN procedure 越界，**TDB-837**）、
`W-21`（非法 WAL 参数静默保留，架构问题、暂不提单）。
