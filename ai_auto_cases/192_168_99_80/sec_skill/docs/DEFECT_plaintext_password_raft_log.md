# 缺陷报告：用户口令以**明文**写入 ConfigNode 共识（Raft）日志

| 项 | 内容 |
| --- | --- |
| 缺陷标题 | 【V2.0.13.1】【安全模块-身份鉴别】`CREATE USER` / `ALTER USER SET PASSWORD` 的口令以**明文**写入 ConfigNode 共识（Raft）日志 `data/confignode/consensus/*/current/log_inprogress_*`，三个 ConfigNode 副本均可直接读出（违反"口令须哈希存储、不得明文"） |
| 被测版本 | TimechoDB **2.0.13.1 RC2**，BuildInfo **`83183d0`**（企业版） |
| 环境 | **干净环境**（3 节点 `data/`、`logs/` 全部清空后重建）；3 ConfigNode + 3 DataNode（192.168.99.77/78/79），SR=3 / DR=3；普通模式 |
| 加密配置 | `encrypt_type=UNENCRYPTED`、`enable_encrypt_config_file=false`、`enable_encrypt_permission_file=false`、`enable_encrypt_audit_log=false` |
| 复现概率 | **必现**（3 个 ConfigNode 全部命中，字节偏移完全相同） |
| 优先级建议 | **P2**（安全类；需要读磁盘/备份的权限才能利用，但一旦获得即等同于拿到账号口令。若按等保"鉴别信息不得明文存储"口径可提 **P1**） |

## 一、复现步骤（约 1 分钟）

```sql
-- 1) 用唯一口令建用户（便于检索）
create user sec_rl_20261117_105111 'RaftLog#Pw20261117_105111';
-- 2) 再改一次密码
alter user sec_rl_20261117_105111 set password 'RaftLog#Pw20261117_105111Alt';
```

```bash
# 3) 在三节点直接检索（注意必须 -r 递归）
grep -ra -l -F -- 'RaftLog#Pw20261117_105111' /data/iotdb/v20131rc2_1110_83183d0/data
```

**实际输出**（三节点一致）：

```
/data/iotdb/.../data/confignode/consensus/47474747-4747-4747-4747-000000000000/current/log_inprogress_329
```

`ALTER` 的新口令同样命中同一文件；用户名也可命中。

## 二、字节级证据（192.168.99.77，`log_inprogress_329`）

**CREATE 的口令**（偏移 **2372187** / 0x24325B）：

```
0024322b  a2 2a 6c 08 03 10 84 75 1a 65 0a 4e 02 6d 00 00   .*l....u.e.N.m..
0024323b  00 16 73 65 63 5f 72 6c 5f 32 30 32 36 31 31 31   ..sec_rl_2026111
0024324b  37 5f 31 30 35 31 31 31 00 00 00 00 00 00 00 19   7_105111........
0024325b  52 61 66 74 4c 6f 67 23 50 77 32 30 32 36 31 31   RaftLog#Pw202611
0024326b  31 37 5f 31 30 35 31 31 31 00 00 00 00 01 00 00   17_105111.......
```

- `00 00 00 16` = 22 = 用户名长度，紧跟 `sec_rl_20261117_105111`
- `00 00 00 19` = 25 = 口令长度，紧跟 **`RaftLog#Pw20261117_105111`（明文）**

**ALTER 的新口令**（偏移 **2373238** / 0x243676）：

```
00243676  52 61 66 74 4c 6f 67 23 50 77 32 30 32 36 31 31   RaftLog#Pw202611
00243686  31 37 5f 31 30 35 31 31 31 41 6c 74 00 00 00 00   17_105111Alt....
```

三节点（.77/.78/.79）的偏移、字节完全相同（Raft 复制）。

## 三、期望

- 磁盘/共识日志中**不得出现**用户口令明文（需求：《身份鉴别功能-需求分析》"密码应以哈希加密的方式存储，不得以明文方式存储在数据库中"）。
- 元数据文件侧已符合：`data/confignode/system/users/*.profile` 里是**哈希**（本次实测：在该目录 `grep -r` 口令明文 → 无命中）。

## 四、根因（源码级）

1. **计划对象明文持有口令**：`AuthorPlan` 的 `password` / `newPassword` 字段（`AuthorPlan.java:31-32`）。
2. **序列化时明文写入**：`AuthorTreePlan.serializeImpl`（`AuthorTreePlan.java:167-172`）

```java
@Override
protected void serializeImpl(DataOutputStream stream) throws IOException {
  ReadWriteIOUtils.write(getType().getPlanType(), stream);
  BasicStructureSerDeUtil.write(userName, stream);
  BasicStructureSerDeUtil.write(roleName, stream);
  BasicStructureSerDeUtil.write(password, stream);       // ← 明文
  BasicStructureSerDeUtil.write(newPassword, stream);    // ← 明文
```

3. **计划进 Raft**：`AuthOperationProcedure.writePlan()` → `ConsensusManager.write(plan)`（`AuthOperationProcedure.java` 的 `writePlan`），
   条目体即上述序列化字节，落盘到 `consensus/<group>/current/log_*`（含 `log_inprogress_*`）。
4. **哈希只发生在应用阶段**：`AuthorPlanExecutor.java:396`

```java
case RCreateUser:
  authorizer.createUser(userName, authorPlan.getPassword());   // ← 直到这里才哈希
```
   `BasicAuthorizer.createUser` → `userManager.createUser(username, password, true, true)`（第 4 参数控制"是否加密"）；
   另有 `createUserWithRawPassword(...)` 走 `createUser(..., true, false)`，用于快照/pipe 回放的"已哈希"语义。

⇒ **口令在"进入 Raft 之前"没有任何哈希/加密**，明文随共识日志持久化。

## 五、影响

1. **可直接读出账号口令**：任何能读 `data/confignode/` 的人（运维、备份/快照拷贝、容器镜像、磁盘丢失）都能拿到 `CREATE USER` / `ALTER USER` 用过的**全部明文口令**，包括管理员账号。
2. **三副本都存**：口令同时落在 3 个 ConfigNode 上，且会保留在日志段中直到快照/截断（重启后在 `log_X-Y` 中仍可读到）。
3. **备份/迁移外泄**：`data/` 目录的常规备份、迁移包、镜像均会携带明文口令。
4. **pipe 链路扩散**（若启用）：配置区快照/计划会被转发到接收端，扩大暴露面。
5. 与需求直接冲突（"口令须哈希存储、不得明文"），且属等保/合规检查的典型项。

## 六、修复建议

1. **主修（推荐）**：在 **DataNode 侧**先哈希再构造计划，计划只携带哈希；CN 应用时按"已哈希"处理
   （复用现成的 `CreateUserWithRawPassword` 语义，`UserManager.createUser(..., encrypt=false)`）。
   - `CREATE USER`：计划中写 `SHA256(password)`
   - `ALTER USER SET PASSWORD`：只写目标哈希，不再写 `newPassword`
2. **备选**：序列化 `password` / `newPassword` 时用 `SecretKey`（TDE 能力）做字段级加密，`AuthorPlanExecutor` 里解密后再哈希；
   好处是对现有链路改动小，但密钥同机。
3. **顺带**：确认 `AuthorPlan.toString()` 是否打印口令（若有，需脱敏），避免日志二次泄漏。
4. **补回归用例**：
   - 执行 `create user u '<唯一口令>'` / `alter user ... set password` 后，`grep -ra <口令> data/` 必须为空；
   - 三节点一致；重启后仍为空；
   - 快照目录（`consensus/*/sm/`、`system/users/`）同样不含明文。
5. **存量数据**：升级后旧日志段仍含明文 → 建议在升级说明中给出"清理/轮转 `consensus` 日志段"的操作指引，或提供工具。

## 七、验证方法（修复后）

1. 干净集群 → `create user u 'UniqPw#20261117'` → `grep -ra -F -- 'UniqPw#20261117' data/` → **无输出**；
2. `alter user u set password 'UniqPw2#20261117'` → 同样无输出；
3. 功能回归：新口令可登录、旧口令失效；
4. 重启 ConfigNode 后再次 grep → 仍无输出；
5. 三节点、快照目录、`system/users/` 全部一致无明文。

## 八、证据归档

**本机（Windows）**：`D:\IDEA\deepseek\ip99_80\sec_skill\artifacts\`
- `raftlog_20261117_105111.tgz`（三节点 `consensus` + `system/users` + CN 日志打包）
- `raftlog_extract/node_77|78|79/...`（解包后的原始文件，可直接 od 复核）
- `cred_20261117_105111.txt`（本次使用的唯一口令与 SHA256）
- 分析脚本：`sec_skill/tools/analyze_raftlog.py`、`show_plaintext_ctx.py`

**192.168.99.80**：`/data/iotdb/autotest/sec_skill/artifacts/`（同上 tgz 与 cred 文件）；
复现/验证脚本：`collect_raftlog.sh`、`verify_plaintext_grep.sh`、`analyze_raftlog.py`、`show_plaintext_ctx.py`。

## 九、附：此前一次"未复现"的更正说明（重要）

2026-11-17 上午我曾在同一干净环境得出"未命中明文"的结论，**该结论是错的**，原因是检索命令写错：

```bash
grep -a -l -F -- '<口令>' $D/data        # ← 少了 -r；对目录搜索直接报 "Is a directory"，结果恒为 0
grep -ra -l -F -- '<口令>' $D/data       # ← 正确写法，立刻命中 log_inprogress_329
```

另外节点上**没有 `strings` 命令**，`strings | wc -l` 恒为 0，也造成了"日志不可读"的误判。
本次已用 `grep -ra` + 本地 Python 字节级复核双重确认，证据可复现。
