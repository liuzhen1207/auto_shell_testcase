# CRUD 专项 skill —— 口径决策记录（用户 2026-10-16 确认「按默认」）

> 背景：`docs/REQ_MATRIX.md` 从 10 篇飞书设计/需求文档抽出 **72 条 R-xx**，其中 3 处文档与 RC7 源码不一致、
> 且文档本身是"讨论稿/未定论"。以下是**用户确认后**的统一口径，实现与复核都以此为准。

## 决策 1：`数据删除功能V2 设计文档` 按「延后 / 待实现设计」处理

- **依据**：该文放在「意见讨论稿」目录，但内容是完整总体设计；其核心方案（**共享 Mod 文件**）在 RC7 被
  **编译期常量关闭**：`TsFileResource.java:153 public static final boolean useSharedModFile = false;`
  （无配置键、无运行时开关；已核验 RC7 `7c61428` 是该源码 HEAD 的祖先，且该文件与 `modification/**` 零改动）。
- **结论**：
  1. **不当作历史废稿**，保留为"延后/待实现"；共享 Mod 相关需求（`<level>-<modFileNum>.mods2` 共享命名、
     `C_Mod` 形态、Res v2 布局）进 `REQ_MATRIX.md` §4 的**不可观测清单**，用例里**只记录 + WARN**，不写硬判据。
  2. 在相关用例头注释标注：**"若将来打开 `useSharedModFile`（或提供配置键），本组判据需回归并升级为硬判据"**。
  3. 可观测的部分（非共享形态：每文件一个 `*.tsfile.mods2`、Entry 首字节区分表/树、`.compaction.mods2`、
     孤儿清理、重启恢复）**照常做硬判据** ⇒ 即 CR-04 / CR-05 / CR-09。
  4. 同类不一致一并记录（均已在矩阵中）：`PartitionLevelModFileManager.java:36-37` 阈值 **硬编码**（30 / 16KB，
     `private final`，模板无对应键）；`TsFileResource.java:129 VERSION_NUMBER` **仍为 1**。

## 决策 2：表模型「只有 Time 列」按**源码现状**写判据（必须拒绝）

- **依据**：`是否允许表模型写入请求只有 Time 列` 是讨论稿，给了方案 1（拒绝）/ 方案 2（允许）但**没写结论**；
  RC7 源码现状 = **方案 1**（拒绝）。同文案在 `TableHeaderSchemaValidator.java:116-119 / 361-364` 抛
  `SemanticException`（≈**507**），而文档逐字写 `1100`。
- **结论**：
  1. CR-03 判据按**必须拒绝**写：**错误码 ∈ {1100, 507, 701} 且文案逐字匹配**（`No column other than Time present, please check the request`），并**打印实测码**。
     **源码更正（2026-10-16，实现代理核对）**：`TSStatusCode.java:131` 里 `SEMANTIC_ERROR = 701`（**507 = METADATA_ERROR**，`1100 = LOAD_FILE_ERROR` 只出现在 load 包装层）⇒ 写入相实测预期是 **701**；矩阵里"SemanticException(≈507)"的说法不准确。实测若为其它码，用例 FAIL 并附原始输出。
  2. 用例头注释写明：**"若最终采纳方案 2（允许），本判据必须反转为『必须接受』"**；
  3. 覆盖两条产文件路径（`DROP COLUMN` 后、以及"全 null 列"写入）+ `load` 侧。

## 决策 3：`Delete 性能优化` 只做**已观测现象**，未定论思路不做判据

- **依据**：该文思路一被明确否定、思路二/三未定论（无结论、无实现）。
- **结论**：
  1. 只把**已观测现象**做成用例：**CR-10「DELETE 阻塞写入的量化」**（固定规模、关/开机制对照，
     **耗时只 WARN**，硬判据 = 结果正确 + 被删数据不可见 + 未删数据不丢）；
  2. 思路二/三**不做判据**，仅在 `REQ_MATRIX.md` 里留档；
  3. 若以后研发确认某优化已落地，再按"新增用例"补齐（走 `--set` 新集合 + 冻结清单准入流程）。

## 附：同时确认的两条实现口径（非用户决策，属工程约定）

- **编号**：冒烟 = `CR-00`；需求用例 = `CR-01…CR-14`。集合语义分组：`write`(CR-01~03) / `delete`(CR-04~10) /
  `load`(CR-13~14) / `object`(CR-11~12) —— `tools/run_all.sh` 的 `case_in_set` 需按此对齐（骨架方原为编号区间占位）。
- **lib 复用边界**：`lib/common.sh`、`lib/cmp.sh` 逐字节复用合并 skill 的版本；其中 `check_logs` 的正证据与
  `CMP_ERR_PAT` 仍是**合并语义** ⇒ CRUD 需要时用**用例内局部**的正则/证据函数覆盖，**不修改 lib**。
