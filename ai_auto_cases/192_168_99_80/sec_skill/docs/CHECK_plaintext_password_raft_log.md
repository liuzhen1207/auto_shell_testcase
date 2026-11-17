# 核查报告：明文口令是否落入 ConfigNode 共识（Raft）日志（V2.0.13.1 RC2）

> **结论先行：在清库重建的干净环境上，多次尝试均**未能**复现"明文口令出现在 ConfigNode 共识日志"；
> 同时源码确认 `AuthorTreePlan` 的序列化确实是**明文**写入计划字节。
> 因此本报告给出的是"**当前版本未复现 + 源码风险点定位**"，不是已确认缺陷；是否提单请研发/你判断。**

| 项 | 内容 |
| --- | --- |
| 被测版本 | TimechoDB **2.0.13.1 RC2**，BuildInfo **`83183d0`**（企业版） |
| 环境 | 干净环境（3 节点 data/logs 全部清空后重建）；3 CN + 3 DN（192.168.99.77/78/79），SR=3 / DR=3 |
| 模式 | 普通模式（`enable_separation_of_powers=false`） |
| 加密相关配置 | `encrypt_type=UNENCRYPTED`、`enable_encrypt_config_file=false`、`enable_encrypt_permission_file=false`、`enable_encrypt_audit_log=false` |

## 一、尝试过的复现路径（全部未命中明文）

| # | 手法 | 结果 |
| --- | --- | --- |
| 1 | `create user`（唯一口令 `Pl4inCreate#<ts>`）+ `alter user`（`Pl4inAlter@<ts>`），立即 grep 三节点 `data/ logs/ conf/` | 未命中 |
| 2 | 再造 20 个用户 + 优雅停集群（TERM，等 20s 再 KILL）后 grep（强制 Raft flush） | 未命中 |
| 3 | 单用户 + 立即 grep，并同时搜 **用户名**、**明文**、**SHA256(口令)** 三种特征 | 三者均未命中 |
| 4 | 建 1 + 300 个用户（制造大日志），grep 全 `data/`（含 `sm/` 快照目录） | 未命中 |
| 5 | **阳性对照**：`SET CONFIGURATION 'password_stale_warning_days'='37'` 后搜配置键/值 | 未命中（说明该日志整体不是明文可读） |

关键观测：

```
CN 共识日志文件头（.77）：
0000000 52 61 66 74 4c 6f 67 31 20 08 01 22 1c 0a 1a 0a  >RaftLog1 .."....<
0000016 01 30 12 13 31 39 32 2e 31 36 38 2e 39 39 2e 37  >.0..192.168.99.7<
...
0000080 ff ff ff ff ff ff ff ff ff ff ff ff 54 44 45 02  >............TDE.<

strings -n 4 log_0-326 | wc -l  →  0
```

- 文件是 Ratis 的 `RaftLog1` 格式，条目体是 protobuf 二进制；出现 `TDE` 标记；
- `strings` 计数为 0（连用户名、配置键都搜不到）⇒ 条目体在落盘时**不是明文**（被编码/加密/压缩）。

## 二、存储侧是哈希（这一条符合需求）

`data/confignode/system/users/*.profile`（未加密目录）中，用户名可见、口令是**非文本摘要**：

```
0000000 00 00 00 03 00 00 00 00 00 00 00 00 00 00 00 04  >................<
0000016 72 6f 6f 74 00 00 00 35 ef bf bd ef bf bd 77 ef  >root...5......w.<   ← 用户名 root，后随 0x20 字节摘要（终端以 U+FFFD 显示）
```

即"用户口令以哈希方式存储"在**元数据文件**层面是成立的。

## 三、源码风险点（为什么仍值得研发确认）

`iotdb-core/confignode/src/main/java/org/apache/iotdb/confignode/consensus/request/write/auth/AuthorTreePlan.java:167-172`

```java
@Override
protected void serializeImpl(DataOutputStream stream) throws IOException {
  ReadWriteIOUtils.write(getType().getPlanType(), stream);
  BasicStructureSerDeUtil.write(userName, stream);
  BasicStructureSerDeUtil.write(roleName, stream);
  BasicStructureSerDeUtil.write(password, stream);        // ← 明文写入计划
  BasicStructureSerDeUtil.write(newPassword, stream);     // ← 明文写入计划
```

- `AuthorPlan` 持有 `password` / `newPassword` 字段（`AuthorPlan.java:31-32`）；
- 计划由 ConfigNode 通过 `AuthOperationProcedure.writePlan()` → `ConsensusManager.write(plan)` 写入 Raft；
- 哈希发生在**应用阶段**：`AuthorPlanExecutor.java:396` `authorizer.createUser(userName, authorPlan.getPassword())`
  → `BasicAuthorizer.createUser` → `userManager.createUser(username, password, true, true)`（第 4 参数控制是否加密）。
  另有 `createUserWithRawPassword(...)` 走 `createUser(username, password, true, **false**)`，即"不再哈希、按原样写入"，
  该路径被 `CNPhysicalPlanGenerator.java:281-289`（从快照流读 `rawPassword` 重建 `CreateUserWithRawPassword` 计划）使用。
- 结论：**计划层确实承载明文口令**；是否以明文落到磁盘，取决于共识日志条目体的编码/加密（本环境实测为不可读）。

## 四、与"昨天那次 grep 命中"的关系（必须说明）

2026-11-16 18:0x，在**另一套集群状态**（同一 build `83183d0`，但此前已做过多次配置变更与重启）上，
我曾在 `data/confignode/consensus/47474747-.../current/log_0-776` 与 `log_inprogress_777` 中 grep 到明文口令
（命令输出见当时的会话记录；该集群随后被清库重建，**原文件已不可回溯**）。

本次在干净环境用 5 种手法均未复现，且阳性对照（配置键/值）也搜不到 ⇒ 更可能是**该次命中的日志处于不同的编码/加密状态**
（例如当时未启用 TDE 的日志条目体），而不是所有部署都必然明文落盘。

**因此：在拿到可重复的复现前，不建议直接按"明文口令落盘"提单**；建议按下方步骤进一步确认。

## 五、建议的进一步确认步骤（给研发/测试）

1. **确认共识日志条目是否加密**：`RaftLog1` + `TDE` 标记是否意味着 config 日志条目走 TDE；若加密，密钥在同机 `data/confignode/system`（`SecretKey`），
   需评估"同机可解密"的威胁模型；若未加密，则只是 protobuf 二进制编码，`strings` 之外用 protobuf 解析即可读出明文。
2. **检查 pipe 链路**：`PipeConfigRegionSnapshotEvent` 涉及 `CreateUserWithRawPassword`，若开启 pipe 到远端，
   计划（含该字段）会经网络/落盘传输，需确认字段语义是"已哈希"还是"原文"（`CNPhysicalPlanGenerator:282` 变量名 `rawPassword` 容易误读）。
3. **定向复现**：在**不启用 TDE** 的配置下（或对 `log_inprogress_*` 直接做 protobuf 解码）验证一次 `create user` 是否可读出明文；
   若可读出 → 按"明文口令写入共识日志"提缺陷（建议 P1/P2，取决于是否需要 root 磁盘权限）。
4. 若最终确认不可读出 → 本条按"**未复现，源码存在明文序列化但落盘侧有保护**"结案，并建议在 `AuthorTreePlan` 序列化处做**字段级加密/哈希前置**以消除隐患。

## 六、证据归档（192.168.99.80）

| 路径 | 内容 |
| --- | --- |
| `/data/iotdb/autotest/rc2_regression_logs/repro_plainpw.log` | 干净环境第 1 轮（create+alter 后立即 grep） |
| `/data/iotdb/autotest/rc2_regression_logs/repro_plainpw2.log` | 第 2 轮（20 用户 + 优雅停 CN 强制 flush） |
| `/data/iotdb/autotest/rc2_regression_logs/detect_plainpw.log` | 第 3 轮（用户名/明文/SHA256 三特征 + 100 用户） |
| `/data/iotdb/autotest/rc2_regression_logs/positive_control.log` | 阳性对照（配置键/值是否可 grep） |
| `/data/iotdb/autotest/rc2_regression_logs/big_plainpw.log` | 第 4 轮（300 用户 + 全目录含 sm/） |
| `/data/iotdb/autotest/sec_skill/results/artifact_plainpw_*/`、`artifact_plainpw2_*/` | 各轮产物（凭据清单、日志 tgz、bundle） |
| `sec_skill/tools/repro_plainpw_raft.sh`、`repro_plainpw_raft2.sh`、`detect_plainpw.sh`、`positive_control.sh`、`big_plainpw.sh`、`diag_raft_bytes.sh` | 一键复现/诊断脚本 |

## 七、结论

- **未能在干净环境复现**"明文口令出现在 ConfigNode 共识日志"（连用户名/配置键都不可 grep，日志条目非明文可读）。
- **源码确有风险**：`AuthorTreePlan.serializeImpl` 明文序列化 `password`/`newPassword`；哈希只在应用阶段做。
- 建议：先按第五节确认日志条目加密/编码状态，再决定是否提单；如确认可读出明文，我这边可立即补一份带字节级证据的缺陷报告。
