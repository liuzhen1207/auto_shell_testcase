# 存储模块 CRUD 专项测试 skill

IoTDB / TimechoDB **2.0.12.1** 的**存储模块 CRUD 专项**用例集（骨架）：
覆盖**写入 / 更新 / 删除 / LOAD 导入导出 / 对象与复杂类型**等读写路径，判据一律"数据与文件都对得上"，
**每条用例统一收尾**（sync lag 归零 → 副本一致性 → CN/DN 日志异常），可直接用于每个 RC 的回归。

harness（`lib/`、`tools/`、`conf/`）**复制并适配自"合并（compaction）专项 skill"**，
已按 CRUD 语义改注释、集合名与默认版本；`lib/common.sh`、`lib/cmp.sh` 两套通用 helper
（集群生命周期 / SQL 会话 / 断言 / 布局与指纹 / 一致性 / 收尾三件套）**原样保留**——
唯一例外是 `lib/common.sh` 里新增的两个**默认空**的日志钩子（见"CRUD 专属日志正证据 / 异常正则"一节），
另加一个可选层 `lib/crud_ext.sh`（CRUD 自己的正证据与异常面，不启用则行为不变）。

| 项 | 内容 |
| --- | --- |
| 目标版本 | **RC7 `v20121rc7_1014_7c61428`**（`7c61428`）；换环境**只改 `conf/env.conf`**（或用 `V_TESTDB=… ` / `--ver` 覆盖） |
| 集群 | **3C3D / 三副本**（192.168.99.77/78/79 各 1 CN + 1 DN）；data region 协议可指定：`--consensus IoTConsensus`（默认）/ `IoTConsensusV2` |
| 入口 | `bash tools/run_all.sh --set smoke\|write\|delete\|load\|object\|all [--only CR-01,…] [--consensus …] [--ver …]`（集合 = 显式 ID 清单） |
| 自检（不碰集群） | `SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh` |
| 离线纯桩干跑（不碰集群） | `bash tools/stub_offline/run.sh [ok\|hotapply\|norestart]` —— 真实用例 + 桩 lib/桩 CLI，四种模式验证断言会真的触发（详见 `tools/stub_offline/README.md`） |
| 结果 | `results/test_result.csv`（Time/build/consensus/caseName/result/elapsedSeconds/failCount/artifact/message）、`results/<ID>_<runid>.out`、`results/SUITE_*.out` |
| 本机路径 | `D:\IDEA\deepseek\ip99_80\crud_skill` |
| 99.80 部署 | `/data/iotdb/autotest/crud_skill` |
| 用例矩阵 | `cases/cases.tsv`（机器可读；新增脚本必须登记，否则 selftest 报"未登记"） |
| 需求出处 | `docs/REQ_MATRIX.md`、`docs/req_sources.txt` |

## 目录结构

```
crud_skill/
  lib/common.sh         # 公共库：集群生命周期、SQL 会话、断言、sync lag/副本一致性/日志分析、结果（复制自合并 skill；
                        #   2026-10-16 仅**增量**加两个日志钩子 CMP_ERR_PAT_CUSTOM / CMP_POSITIVE_EVIDENCE_FN，默认空 ⇒ 行为不变）
  lib/cmp.sh            # 通用 helper：造数据、TsFile/布局观测、指纹、合并观测与开关、收尾（复制自合并 skill，未改）
  lib/crud_ext.sh       # ★ CRUD 专属日志判据层（可选）：crud_positive_evidence / crud_install_err_pat / crud_check_logs
  conf/env.conf         # ★ 唯一的环境配置（集群/副本/账号/路径/超时/合并与 TTL 参数）；默认版本 RC7
  tools/run_all.sh      # 用例集合入口（flock 防并发 + mapfile 读矩阵 + CSV 结果 + --only/--consensus/--ver；
                        #   集合 = **显式 ID 清单**，见下 case_in_set）
  tools/selftest.sh     # harness 自检（无集群）：语法、矩阵双向一致、env、helper、断言负向测试、静态坑
  tools/stub_offline/   # ★ 离线**纯桩**干跑（不连集群）：真实用例 + 桩 lib/桩 CLI，验证断言是否真的会触发
  cases/cases.tsv       # 用例矩阵（CR-00 冒烟 + CR-01..CR-14 需求用例，共 15 行）
  cases/common/  cases/tree/  cases/table/   # 用例脚本
  docs/                 # 需求矩阵与出处（REQ_MATRIX.md / req_sources.txt / DECISIONS.md）
  results/              # 运行产物
```

## 用例编号与库名约定

- 编号前缀统一 **`CR-`**；集合（`--set`）是**显式 ID 清单**（`tools/run_all.sh` 的 `case_in_set`）：
  `smoke`=CR-00，`write`=CR-01..CR-03，`delete`=CR-04..CR-10，`load`=CR-13,CR-14，
  `object`=CR-11,CR-12，`all`=全部。**新增用例必须在 `cases.tsv` 登记，并显式决定它属于哪个集合**
  （清单化就是为了避免"编号落在某区间就被误选/漏选"）。
- 库名统一前缀 **`root.cr…`**（如 CR-00 用 `root.crsmoke`、CR-13 用 `root.cr13`、CR-14 用 `root.cr14`），
  不借用其它 skill / 长回归的库名（`tools/selftest.sh` 有静态检查）。
- 当前 **15 条**：`CR-00`（fallback 冒烟）+ `CR-01..CR-14`（需求矩阵 §2 的 14 条建议用例）。
  ⚠ 本 skill **尚未在集群实跑**（99.80 上一直在跑合并/长回归，禁止起停集群），只保证 `bash -n` 与
  `SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh` 通过。

## 用例约定（写新用例必须遵守）

1. **写入期先关机制 → 记基线 → 热开观察**：测试写入阶段先用 `CMP_EXTRA_WRITE`（三类合并全关）建库写数，
   记下基线（TsFile 数 / 文件清单 / 数据指纹），**写完再热开**被观察的机制（如 `cmp_compaction_on`）再看变化。
   若写入时就开着合并/清理，动作在基线之前就完成了 ⇒ 会误判成"没有推进"。
2. **双信号判据**：任何"某机制发生了"的判据都要同时看 ①日志条数增量（如
   `InnerSpaceCompaction task finishes successfully`）**且** ②文件/字节数变化（TsFile 数、目录布局）。
   单信号会误判（日志跨用例累积、或文件已合并但日志被截断）。
3. **场景有效性硬断言**：场景没造出来（起点 TsFile < 2、行数/分区数/文件数不达预期、注入未生效）必须
   `fail`，**不许静默跳过或只 WARN**——否则用例会"假 PASS"。
4. **收尾三件套**（每条用例末尾，`lib/common.sh`）：① sync lag 归零（`check_sync_lag`，缩容场景用 `check_sync_lag_on`）；
   ② 副本一致性（全部在线结果为基准 → **逐个停 1 个 DN** 再查并比对，`consistency_check`/`consistency_check_on`）；
   ③ CN/DN 日志扫异常（`check_logs`/`cmp_check_logs_on`：NPE、OOM、越界、overlap、`CompactionTableSchemaNotMatchException`、
   `DataTypeInconsistentException` 等）。脚本末尾必须调用 `post_checks`（或 `check_sync_lag_on`）+ `cmp_case_finish`（selftest 会检查）。
5. **数据正确性用指纹**：`cmp_fp_tree` / `cmp_fp_table` / `cmp_fingerprint`（归一化后的 count/sum/min/max +
   单设备全序列）前后比对，不用"输出里有没有某个词"这类包含类断言。
6. **自检**：每次改完 harness/用例先 `SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh`（**不启停集群、不跑用例**，
   正在跑长回归时也安全）；期望末行 `=== 自检汇总：ok=N failed=0 ===`。
7. **一条用例一次只跑一个**：`run_all.sh` 已用 `flock` 防并发（并发跑会互相清库/启停节点 ⇒ 假 FAIL）。

## 与合并 skill 的差异（本 skill 改了什么）

- `conf/env.conf`：文件头注释改成 CRUD 专项（"换环境只改本文件"），默认版本 `rc6_1010_7ae8713e` → **`v20121rc7_1014_7c61428`**；
  集群/副本/账号/超时/合并/TTL 变量**全部保留**（CRUD 用例要用）。
- `tools/run_all.sh`：集合改成 `smoke|write|delete|load|object|all`，且 `case_in_set` 由"编号区间占位"改成
  **显式 ID 清单**（`smoke=CR-00` / `write=CR-01..03` / `delete=CR-04..10` / `load=CR-13,14` / `object=CR-11,12` / `all`），
  注释里写明每个集合的含义与"为什么不用区间"；横幅/注释改成 CRUD；
  flock 防并发、`mapfile` 读 `cases.tsv`、CSV 写 `results/test_result.csv`、`--only/--consensus/--ver` 全部保留；
  另加两处防护：**`--set` 白名单**（拼错的集合名直接 rc=2 退出，绝不"默默跑全量"）与
  **空矩阵保护**（`cases.tsv` 只有注释时 rc=3 退出，不留锁文件与空 CSV）。
- `tools/selftest.sh`：文案改 CRUD；用例数阈值 14 → **≥1**；新增 ①矩阵**反向**一致性检查（脚本未登记即 FAIL）
  ②`env.conf` 默认版本必须是 RC7 ③用例 ID 一律 `CR-` 前缀 ④库名一律 `root.cr*` 的静态约定检查
  ⑤`lib/crud_ext.sh` 与两个日志钩子的默认值检查（钩子默认必须为空，保证默认行为不变）；
  把"空矩阵被空数组展开成 1 行"的假象修掉（以矩阵数据行为准）。
- `cases/cases.tsv`：CRUD 表头约定 + 15 行用例（CR-00 冒烟 + CR-01..CR-14），集合列口径与 `run_all.sh` 清单一致。
- `lib/common.sh`：**唯一改动是日志钩子**（2026-10-16）——新增两个默认空的变量
  `CMP_ERR_PAT_CUSTOM` / `CMP_POSITIVE_EVIDENCE_FN`，并在 `check_logs` **调用时**读取它们
  （异常正则取并集；`CMP_POSITIVE_EVIDENCE_FN` 设置后替代合并专用的 starts/finishes 正证据）。
  不设置这两个变量时，`check_logs` 的行为与合并/TTL/元数据 skill 使用的版本**完全一致**（它们是各自独立的
  lib 副本，不受本改动影响）。其余内容仍是逐字节复制。详见下一节。
- `lib/cmp.sh`：**逐字节复制，未改**（内部变量仍叫 `TTL_*` / `cmp_*`，路径由 `$(dirname $BASH_SOURCE)/..` 推导，复制即用）。
- 未复制合并 skill 的 `cases/quick.txt`、`cases/regression.txt`、`tools/` 下的诊断脚本、`assets/`、`SKILL.md`、`docs/*`。
- **新增**（合并 skill 没有）：`lib/crud_ext.sh`（CRUD 日志判据层）与 `tools/stub_offline/`（离线纯桩干跑，
  用于在严禁碰集群时验证用例的断言是否真的会触发——它把**真实用例**配桩 lib/桩 CLI 组装到 `/tmp` 运行）。

## CRUD 专属日志正证据 / 异常正则（`lib/crud_ext.sh`）

**问题**：`lib/common.sh` 的 `check_logs` 里，"异常正则"（`CMP_ERR_PAT`）与"正证据"（`Compaction task
starts / finishes successfully` 累计）都是**合并语义**——对 CRUD 用例来说，前者覆盖不到删除/加载/LastCache
的失败模式，后者在 CRUD 用例里**根本不会增长**（打出来只会误导）。

**做法**（**不改 lib 的默认行为**，二选一里的"钩子 + CRUD 层"）：

| 位置 | 内容 |
| --- | --- |
| `lib/common.sh`（增量） | `CMP_ERR_PAT_CUSTOM`（追加异常正则，与 `COMMON_ERR_PAT`/`CMP_ERR_PAT` 取并集）、`CMP_POSITIVE_EVIDENCE_FN`（"正证据"函数名，设置后**替代**合并专用的 starts/finishes 统计）。两者默认空；都在 `check_logs` **调用时**读取（用例 source lib 之后再 export 也生效） |
| `lib/crud_ext.sh`（新增） | `crud_err_pat_extra`（CRUD 建议正则，逐条在 RC7 源码核对出处）、`crud_install_err_pat`（装进 `CMP_ERR_PAT_CUSTOM`）、`crud_positive_evidence`（CRUD 正证据：Deletion 写入 / Load 相关 / LastCache 相关行数 + 本用例库 TsFile 数）、`crud_log_sum`、`crud_check_logs`（包装） |

**CRUD 用例怎么用**（示例见 `cases/common/cr_load_pipe_last.sh`）：

```bash
. "$HERE/../../lib/crud_ext.sh"
export CRUD_EVIDENCE_DB="$DBR"                       # 正证据里带出本用例库的 TsFile 数
export CMP_POSITIVE_EVIDENCE_FN=crud_positive_evidence
crud_install_err_pat                                 # 需要 CRUD 异常面时才装（按需 opt-in）
# … 之后 post_checks / check_logs 就用上面的判据；也可以用 crud_check_logs 直接调用
```

⚠️ 两条纪律：① **不要默认全局启用异常正则**（CRUD 用例常有"故意触发报错"的负向相，广谱正则会误报）；
② 钩子只在调用 `check_logs` 时读取，设置动作必须放在收尾之前。CRUD 建议正则含 4 条（`Delete ModificationFile
… failed` / `Failed to read mods from` / `Unrecognized LastCacheLoadStrategy` / `Load: Query fallback failed
for device`），每条都在 `lib/crud_ext.sh` 里写明源码出处；LastCache **命中率**在 RC7 没有可查指标
（`docs/REQ_MATRIX.md` §4-C5），所以正证据里只统计"提及行数"，**不要**拿它当性能判据。
