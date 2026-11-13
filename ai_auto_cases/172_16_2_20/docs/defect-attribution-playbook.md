# 缺陷归因避坑手册（从 TDB-1050 三轮误判总结）

> 背景：TDB-1050（updateTable NPE）的归因我前后改了三次，前两次都是错的：
> ① "改视图名必现" → ② "4 参 commitUpdateTable 是改名入口" → ③ 实际是 **CREATE WRITABLE VIEW（cascade=true）的成对提交**。
> 研发两次指出问题（"干净环境没复现""改名根本不走四参"）后，靠**日志时间线 + 子类覆写**才定准。
> 本文把这些坑写成检查清单，避免重复。

## 一、五条硬规则

### 1. 不要用"用例名/操作名"当触发条件
- ❌ 我用例叫 `rename_view`，就推断"改名触发"。
- ✅ 触发条件要从**日志时间线**里读：哪一对 pre-update/commit 落在同一个 RPC、哪一次 SQL 调用在那一秒。

**做法**：把该轮 DN 日志里所有 `Pre-update table`、`Commit-update table`、`by table fetch`、`Skip commit-update` 按时间排开，再和本轮 SQL 的执行时刻（setup / 被测语句）对齐。

TDB-1050 的对齐结果（关键）：

```
18:36:22,321 Pre-update ...v     ┐
18:36:22,322 Pre-update ...t     ┘ 成对 → CREATE WRITABLE VIEW（cascade=true）
18:36:22,485 Update ...t by table fetch
18:36:22,556 Commit ...v OK
18:36:22,557 NPE
18:36:25,925 Pre-update ...v2    ┐
18:36:25,944 Commit ...v2 OK     ┘ 单表 → ALTER VIEW RENAME，干净
```

> 用例名是"测试意图"，不是"代码路径"。

### 2. 单表提交 vs 成对提交，是两条完全不同的路径
- 单表：`commitUpdateTableWithView(...)`（3 参，`req.originalInfo` 未设置）
- 成对：`commitUpdateTable(db1, db2, t1, t2)`（4 参，`req.originalInfo` 已设置，`tableName1`=视图、`tableName2`=源表）

DN 侧分流点：`DataNodeInternalRPCServiceImpl.updateTable` 的 `COMMIT_UPDATE_TABLE` 分支按 **`req.isSetOriginalInfo()`** 判断。
**看日志是"一次 Pre-update"还是"同一毫秒两次 Pre-update"，就能立刻判断走了哪条。**

### 3. 先查子类覆写，再谈"某操作会不会走到这条路"
`getSourceResolutionOverride()` 决定是否解析源表（进而决定是否成对提交）：

| 子类 | 返回值 | 是否成对 |
| --- | --- | --- |
| 基类 | `null` | 看 `isSchemaCascade()` |
| `RenameWritableViewProcedure` | `false` | 永不成对 |
| `RenameWritableViewColumnProcedure` | `false` | 永不成对 |
| `SetWritableViewPropertiesProcedure` | 动态 | 改 cascade 时可能 |
| `CreateWritableViewProcedure` | 未覆写 → `null` | cascade=true 时成对 |
| `AddWritableViewColumnProcedure` | 未覆写 → `null` | cascade=true 时可能 |

> 教训：我第二次误判就是因为没查这个覆写，想当然认为"改名也会带上源表"。

### 4. "发生过" ≠ "可稳定复现"，两件事分开写
- 生产日志出现 2 次 = **发生过**（有现场）。
- 干净环境 15 次黑盒尝试 0 次 = **不可稳定复现**（是竞态）。
- 插桩后 100% = **机制确认**。

写缺陷时必须分开三段写，别用"2/2 复现"去暗示稳定复现——研发会按稳定复现去试，试不出来就会判"不复现/不是缺陷"。

### 5. 不要在没有证据时指认"某提交引入"
我早期写"两版本间 `DataNodeTableCache` 的改动是 `1bbb4ff6db`（+2 行），疑与该路径相关"——纯推测，且后来证明与触发点无关。
**要么有 bisect/对照证据，要么写"触发条件"，不要写"疑似某提交引入"。**

## 二、提交缺陷前的检查清单

1. [ ] 从日志时间线确认**实际触发的那次操作**（不是用例名）
2. [ ] 确认代码路径（单表 / 成对；3 参 / 4 参），并给出**生产构建的行号**
3. [ ] 查相关子类覆写/默认值（如 `schema_cascade` 默认 true，要实测 `SHOW CREATE TABLE`）
4. [ ] 复现性分三段写：发生过 N 次 / 黑盒尝试 M 次结果 / 插桩是否 100%
5. [ ] 不写无证据的"某提交引入"
6. [ ] 给出可执行的复现前置条件（如"视图必须是 cascade=true"）

## 三、插桩证明的标准做法（本次有效）

1. 只改**一个类**：在目标方法取锁前加测试开关（`-Diotdb.test.xxx`），命中时模拟竞争方的动作；
2. `javac` 单类编译：`javac -cp "<安装目录>/lib/*" -d out Xxx.java`（classpath 用 jar 列表，别用通配符被 shell 吞掉）；
3. 备份原 jar，`jar uf` 替换单个 class，只改**目标节点**；
4. JVM 开关加到 `conf/datanode-env.sh` 的 `IOTDB_JMX_OPTS`（该变量会进 JVM 参数）；
5. 复现后**必须**：`cp .orig` 回滚 jar → 删开关 → 重启该节点 → 确认 `SHOW CLUSTER` 8/8 → 再继续回归；
6. 写缺陷时注明**插桩构建的行号偏移**（本次 515/529 对应生产 483/497）。

> 注意：开关要加在"竞争方动作之前、目标锁之外"，加在锁内会让竞争方进不来，等于没测。

## 四、环境类坑（与本缺陷无关但同批踩过）

1. 干净环境验证前，先确认没有残留的 `iptables` 规则和别的版本的 DN 进程（曾导致端口占用、集群起不来）；
2. 跑长时间回归时**不要中途改 jar/配置**——本次为此作废过一轮，必须先停链路；
3. 每个用例 reset 会删日志，取现场必须在下一轮 reset 前拷走（执行器已加"失败即备份日志"）。
