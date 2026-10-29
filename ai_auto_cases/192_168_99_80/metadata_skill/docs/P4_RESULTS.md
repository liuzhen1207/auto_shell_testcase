# P4 三项优先方向 —— 实跑报告（TimechoDB 2.0.12.1 RC5）

在第一轮 10 条用例（树/表 DDL、观测面、失败路径、一致性持久化、权限闭环）之上，
本轮把 `docs/PLAN.md` 里 P4 排名前三的方向做成了正式用例：

| 方向 | 用例 | 结果 | 耗时 |
| --- | --- | --- | --- |
| ① 真实 jar 的 UDF / Trigger 全链路 | **MD-U01** `md_udf_trigger` | PASS | 235s |
| ② 权限矩阵 | **MD-C03** `md_privilege_matrix` | PASS | 109s |
| ③ 元数据规模 | **MD-S01** `md_scale_bulk` | PASS | 87s |

（关于"用户和角色还要不要单独做"：**不用**。`MD-C02` 已经覆盖 USER/ROLE 的元数据闭环，
权限矩阵方向是把用户/角色当**载体**去打权限值 × 路径粒度，所以没有再单开一条。）

---

## 一、MD-U01：UDF / Trigger 全链路（真实 jar）

### 怎么准备 jar

`assets/udf/` 里有 3 个类，用**服务端自己的 jar** 编译（不需要 maven）：

- `mdskill.MdUdtf`：把输入值 ×2，支持 `'factor'='3'` 属性 → 用来证明"注册的 UDF 真被执行"
- `mdskill.MdUdtfErr`：transform 里故意抛异常 → 证明"注册成功 ≠ 能用"
- `mdskill.MdTrigger`：把 `onCreate/restore/onDrop/fire` 追加写到 marker 文件 → 用来判定触发器真的被加载/触发

```bash
bash assets/udf/build_and_deploy.sh
# 用 /data/iotdb/<版本>/lib/timechodb-server-2.0.12.1.jar 编译，打包 mdskill.jar，
# 分发到三台节点的 /data/iotdb/udf_md/mdskill.jar（USING URI 引用同一路径）
```
用例自身会检查 jar 是否在各节点，缺失时自动调用该脚本补齐。

### 实测结论

| 项 | 实测 |
| --- | --- |
| 注册 | `CREATE FUNCTION md_md_double AS 'mdskill.MdUdtf' USING URI 'file:///data/iotdb/udf_md/mdskill.jar'` |
| `SHOW FUNCTIONS` | 类型列是 **external UDTF**（内置的是 `built-in UDTF`，可区分），并记录类名 |
| 执行 | `SELECT md_double(s1)`：1.5/2.5/3.5 → **3.0/5.0/7.0**；带 `'factor'='3'` → **4.5/7.5/10.5** |
| 会抛异常的 UDF | 执行报 **301**，消息透出用户自定义文本 |
| 失败路径 | 重名 **1207** / 类不存在 **1200** / jar 不存在 **1304** / DROP 不存在 **301** |
| 触发器注册 | `CREATE STATELESS TRIGGER … BEFORE INSERT ON <dev>.** … WITH (marker=…, tag=…)` |
| `SHOW TRIGGERS` | 列：`TriggerName\|Event\|Type\|State\|PathPattern\|ClassName\|NodeID`；STATELESS 的 NodeID=**ALL** |
| 回调分布 | `onCreate`/`onDrop` 在**三个节点**都被调用（每个 DN 都加载类）；**`fire` 只在执行写入的那个节点发生** |
| 重启 | 重启后 `SHOW TRIGGERS` 仍列出且 **fire 继续生效**（实测 fire 计数 1 → 2 → 3 跨两次重启） |
| 失败路径 | `validate()` 主动拒绝 → 报错；类不存在 **1303**；DROP 不存在 **1301** |
| `restore()` | **stateless 触发器不会收到**（源码 `TriggerExecutor`：`if (isRestoring && triggerInformation.isStateful())` 才调用）——按设计，非缺陷 |

### 本轮第 3 条：设备级裸路径触发器不触发 —— **文档明确，符合预期（不是缺陷）**

**现象**：设备级路径模式 `ON root.db.d1` 的触发器注册成功（`SHOW TRIGGERS` State=ACTIVE），
但插入数据后 `fire()` 一次都不触发。隔离实验（同一张表、同一次写入，6 个触发器同时注册）：

| 注册路径 | 指向 | fire 总次数 |
| --- | --- | --- |
| `root.db.d1.s1`（序列级） | 一个序列 | 2 ✅ |
| `root.db.d1.*` | 该设备已有的一级序列 | 2 ✅ |
| `root.db.d1.**` | 该设备所有层级的序列 | 2 ✅ |
| `root.db.**` | 该库所有序列 | 2 ✅ |
| **`root.db.d1`（设备节点自身）** | **不是序列** | **0（符合预期）** |
| `ON root.db.d1.s1` + `AFTER INSERT` | 一个序列 | 2 ✅（说明**不是**事件类型问题） |

**结论（依据产品文档）**：文档《06-流计算-触发器》明确——

> 触发器可以注册在**任意路径模式**上。被注册有触发器的**序列**将会被触发器侦听，
> 当**序列**上有数据变动时，触发器中对应的触发方法将会被调用。

侦听对象是**序列**；`ON root.db.d1` 指向设备节点本身，其下没有序列，因此没有序列被侦听，
`fire()` 不执行 —— **设计如此**。要覆盖整个设备请写 `ON <设备>.**`。

代码层面也与之一致：`PatternTreeMap.searchOverlapped(deviceNodes…)` 的终端分支只收集
①"匹配**测量名**的子节点"的值，②"本节点是 `**` 时"本节点的值（`*`/`**` 由 `getMatchChildren` 天然包含），
即匹配始终发生在**序列这一层**。

> ⚠️ **更正记录**：这一条一度被我判为"疑似缺陷：源码漏收集设备节点自身的值"，
> 并把 `searchDeviceOverlapped:267` 的 `addAll(node.getValues())` 当作"实现不一致"的佐证——
> **判错了**：那个方法服务的是**设备级**用途（`getDeviceOverlapped`，当前只被单测使用），
> 不能据此推"触发器也应如此"。**教训：源码行为与直觉不符时，先对照产品文档/设计说明，再判缺陷。**
> 详见 [`NOTE_trigger_path_pattern.md`](NOTE_trigger_path_pattern.md)。

**用例当前的处理**：`MD-U01` 第 11 步做 **A/B 硬断言**——
`ON <设备>` 必须**不触发**（符合文档语义），阳性对照 `ON <设备>.**` 必须**触发**；
两者任一反转则用例 FAIL，提醒复核文档与实现。

---

## 二、MD-C03：权限矩阵

`LIST PRIVILEGES OF USER/ROLE` 的输出是四列：`Role | Scope | Privileges | GrantOption`。

| 维度 | 实测结论 |
| --- | --- |
| 权限值展开 | `GRANT READ` → **READ_DATA + READ_SCHEMA** 两行；`GRANT WRITE` → **WRITE_DATA + WRITE_SCHEMA** |
| 多权限 | `GRANT READ, WRITE ON … WITH GRANT OPTION` 一次成功，4 行 GrantOption 全为 `true` |
| 路径粒度 | `Scope` 列**原样**等于授权时写的路径：`root.db.**` / `root.db.d1.s1` / `root.**` 都验证过 |
| 特殊权限 | `ALL / SYSTEM / SECURITY / AUDIT` **只能授在 `root.**`**；授在子路径报 **701**（`[ALL] can only be set on path: root.**`） |
| 角色 | `LIST PRIVILEGES OF ROLE` 的 Role 列是角色名；把角色授给用户后，**用户的 LIST 里也能看到角色带来的权限**（Role 列=角色名） |
| 回收 | `REVOKE` 后对应行立即消失 |
| **实际生效** | 只有 READ：`SELECT` 通过、`INSERT` 报 **803**（`No permissions …, please add privilege WRITE_DATA on [<path>]`）；补上 WRITE：`INSERT` 通过；只靠角色也能 `SELECT`；角色只给 READ 时写入仍报 803 |

### 观察：读写越权的表现（**已复测修正**）

初版只测了"零权限时读"和"只有 READ 时写"两个**不同前提**，据此写成"读写越权表现不一致"，**前提不齐**。
补齐前提后（树模型 × 表模型 × {零权限/只读/只写} × {读/写}）结论是：**这是两个模型各自的设计，不是缺陷**。

**树模型**（`docs/experiments/_permrw.sh`、`_permwrite.sh`、`_permfilter.sh`）：

| 权限 | SELECT | INSERT |
| --- | --- | --- |
| 零权限 | **空集、不报错** | 803 |
| 只授 READ | 读到数据 | 803 |
| 只授 WRITE | **也能读到数据**（`count(*)`、`SHOW TIMESERIES` 也可以） | 成功 |

- `WRITE` 隐含 `READ`：源码 `PathPrivilege.checkPrivilege()` 里 `READ_DATA` 检查会回退到 `WRITE_DATA`
  （`READ_SCHEMA` ← `WRITE_SCHEMA`），**设计如此**。
- 读是"按权限过滤"：零权限路径读出来是空集；`SELECT s1 FROM db1.d1, db2.d1` 只返回有权限那个；
  `SELECT * FROM root.**` 只展开出有权限的序列列。三个 DataNode 结果一致（不是缓存假象）。

**表模型**（权限模型与树模型完全不同：`SELECT/INSERT/CREATE/DROP/ALTER/DELETE ON DATABASE|TABLE <名>`）：

| 权限 | SELECT | INSERT |
| --- | --- | --- |
| 零权限 | **803** | **803** |
| 只授 SELECT | 读到数据 | 803 |
| 只授 INSERT | **803** | 成功 |

⇒ 表模型读写都是硬校验、权限名与 Scope 也不同（`<库>.*` 而非 `root.**`）。
两者都已写成 `MD-C03` 的硬断言（第 10~12 步），不再作为观察项。

---

## 三、MD-S01：元数据规模（2000 时序 / 200 表）

规模取自 `conf/env.conf`：`MD_BULK_SERIES=2000`、`MD_BULK_TABLES=200`；
树侧用 `CREATE ALIGNED TIMESERIES` 批量建（200 设备 × 10 测量 = 2000 条时序，200 条语句）。

| 检查项 | 结果 |
| --- | --- |
| 批量建 2000 条时序 | 无报错，耗时 ~10s 级 |
| `COUNT TIMESERIES` = 2000、`SHOW TIMESERIES` 行数 = 2000 | ✅ 一致 |
| `COUNT DEVICES` = `SHOW DEVICES` 行数 = 200 | ✅ |
| `COUNT NODES LEVEL=2` = 200（设备）、`LEVEL=3` = 2000（序列） | ✅ |
| `COUNT TIMESERIES … GROUP BY LEVEL=2` 行数 = 200 | ✅ |
| 首/尾设备精确查询各 10 条 | ✅ |
| `LIMIT 100` / `LIMIT 100 OFFSET 100` 都返回 100 行（不截断） | ✅ |
| 200 张表的 `SHOW TABLES` 行数、`information_schema.tables` 行数 | ✅ 一致 |
| 规模下 `DESC` / `SHOW CREATE TABLE` 仍准确 | ✅ |

### 这条用例顺带抓出的一个 **harness 自身的坑**（值得单独记一笔）

第一次跑 MD-S01 时 `SHOW TIMESERIES` 被数成 **2001** 行（期望 2000）。
追查发现：**CLI 在结果超过一批（实测 1000 行/批）时会重复打印表头**——
2000 行的结果里有 2002 个 `|` 行 = 2 个表头 + 2000 行数据。

原来的 `table_rows()` 只丢掉第一行表头，于是**多出来的表头被当成一行数据**。
这在 1000 行以下永远看不出来，只有把规模打上去才暴露。
已修：`table_rows()` 记住第一行表头的**原文**，把所有逐字相同的行都丢掉；
并在 `tools/selftest.sh` 里加了"多批次表头"回归用例（`selftest` 从 ok=42 → **ok=44 failed=0**）。

> 这也说明规模用例的价值：它不只是测产品，也把 harness 里"小数据量下看不出来"的问题逼出来了。

---

## 四、复现方式

```bash
cd /data/iotdb/autotest/metadata_skill
bash tools/selftest.sh                    # ok=44 failed=0
bash assets/udf/build_and_deploy.sh       # 准备 UDF/Trigger 的 jar
bash tools/run_all.sh --set all           # 13 条用例
bash tools/run_all.sh --only MD-U01,MD-C03,MD-S01   # 只跑 P4 三条
```

---

## 五、这一轮又修掉的两个 harness 问题（都是"跨用例污染"）

跑完 P4 三条后重跑全量时，`MD-U01` 与 `MD-S01` 报 FAIL，但**功能断言全过**，失败都来自收尾的日志检查：

1. **日志检查没有"只看本用例"**：CN/DN 日志是跨用例累积的。`MD-U01` 第 8 步会**停/重启集群**，
   在飞的查询片段失败 → 日志里出现 `Execute FragmentInstance in ConsensusGroup SchemaRegion[7] failed.`；
   这条被算到 `MD-U01` 头上还情有可原，但它**又让后面完全无关的 `MD-S01` 也 FAIL**。
   → 现在 `md_cluster_prepare` 结束时会调用新增的 `md_log_mark` 记录每个日志文件的行数基线，
   `check_logs` 只扫基线之后的新增行。
2. **元数据异常的正则太宽**：`SchemaRegion[^|]*(failed|…)` 会匹配到上面那条**查询片段**失败。
   → 收紧成 `SchemaRegion\[[0-9]+\] (failed to|failed because|met error|is not)`，必须让失败描述紧跟 region id；
   同时把 `Execute FragmentInstance in ConsensusGroup … failed` 列入 BENIGN（停/重启节点时的正常现象）。
3. 另外给用例加了 `MD_LOG_BENIGN_EXTRA`：`MD-U01` **故意**让 UDF 抛异常、让触发器 `validate()` 拒绝注册，
   这些预期内的 ERROR/WARN 用该变量排除（只对该用例生效，其它用例照旧会抓）。

修完复现原失败序列 **MD-U01 PASS 345s → MD-S01 PASS 90s**。
