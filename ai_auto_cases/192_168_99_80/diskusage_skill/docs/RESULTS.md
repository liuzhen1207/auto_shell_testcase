# 实测结果（diskusage_skill）

## 1. TDB-629 门禁：修复前复现 → RC6 验证修复

| 用例 | 版本 | 结果 | 关键数据 |
| --- | --- | --- | --- |
| **DU-01**（树模型 `SHOW DISK_USAGE`） | **RC5 `v20121rc5_1003_aaf460d`** | **FAIL fail_flag=1**（487s） | 阶段 A 正向对照 PASS（finish 0→4）；统计查询 6 行/12278B；开合并后 90s 内 `finish 4→4`、`tsfile 18→24` **毫无推进**；jstack 三节点合计 **6 个 `IoTDB-Compaction-Worker` 卡在 `TsFileResource.writeLock`** |
| **DU-01**（树模型） | **RC6 `v20121rc6_1010_7ae8713e`** | **PASS fail_flag=0**（405s） | 同样流程：统计查询 6 行/12296B；开合并后 7s 内 `finish 4→20`、`tsfile 18→6`；收尾三件套全 PASS |
| DU-02（表模型 `information_schema.table_disk_usage`） | RC5 | PASS fail_flag=0（384s） | **未复现**：统计后合并照常推进（finish 4→20、tsfile 18→6），卡死线程 0 |
| DU-02（表模型） | RC6 | PASS fail_flag=0（385s） | 同 RC5（表模型统计走"命中大小索引不打开文件"的快路径 ⇒ 不泄漏读锁） |

**结论**：TDB-629 在修复前版本可稳定复现（树模型接口，工单描述的就是 `show disk_usage`），
RC6 已修复；字节码层面 `DiskUsageStatisticUtil.class` 在 RC5→RC6 有变化（CRC32 `c0db6916`→`30fbd259`，
常量池 `readLock`/`readUnlock` 1/1→0/0）。

## 2. 补充用例（RC6）

| 用例 | 结果 | 关键实测值 |
| --- | --- | --- |
| **DU-03** 树模型统计正确性（6 设备有数据） | **PASS**（329s） | 表头 5 列；`root.dustata.**` 6 行/**3636B** ≤ 物理 5058B；精确设备 `root.dustata.d1`=**588**；`root.**` 覆盖两库；`ORDER BY … LIMIT 1` 生效；不匹配设备 → 0 |
| **DU-04** 表模型统计正确性（2 库 × 2 表 + 视图） | **PASS**（361s） | 表头 6 列（+ 多一列 `table_type`）；t1=4254B、t2=2226B；库合计 6480 ≤ 物理 8343B；`where database`/`like` 过滤正确；**GROUP BY 聚合 == 明细求和**；不存在的表 → 0 行；视图不出现 |
| **DU-05** 权限与错误路径 | **PASS**（216s） | 零权限执行 `show disk_usage` → **803 please add privilege SYSTEM**；授 `SYSTEM` 后 12 行；非法 pattern → **700**；零权限查表模型 → **803 Access Denied** |

## 3. 实测语义（写断言必读，详见 `SKILL.md`）

1. **树模型 pattern 匹配对象是设备路径**：`root.db.**` = `root.db.*` = 库内所有设备；`root.db.d1` = 该设备（可用）；
   `root.db.d1.**`、`root.db`、`root.*` 都是 0；不匹配设备时**仍出行**、`SizeInBytes=0`。
2. **表模型结果集比需求文档多一列 `table_type`**（7 列）⇒ 一律按列名取值。
3. **表模型聚合列是 double**（`1698.0`）⇒ 数值解析用 awk `+0`，不能"去掉非数字字符"（会放大 10 倍）。
4. 表模型接口**未复现**本缺陷（快路径不打开文件）⇒ 门禁以树模型为准。
5. 建用户密码 **≥12 位**，否则报 `820`；表模型接口同样要求 `SYSTEM` 权限。

## 4. 运行历史说明

`test_result.csv` 保留完整运行历史，包含用例自身缺陷导致的两轮 FAIL（表模型 DDL 写法、按固定列号取值、
建用户密码不足 12 位）与相应的修复后 PASS；每一轮的完整输出在 `results/*.out`，证据在交付目录 `artifacts/evidence/`。
最终结论以上表为准。
