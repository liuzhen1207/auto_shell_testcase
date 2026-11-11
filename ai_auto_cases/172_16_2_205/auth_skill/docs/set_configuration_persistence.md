# `SET CONFIGURATION` 会持久化到节点配置文件（附证据与影响分析）

| 项目 | 内容 |
| --- | --- |
| 版本 | TimechoDB 2.0.13.1 / `83183d0`（RC2），RC1 行为一致 |
| 涉及语句 | `SET CONFIGURATION '<key>'='<value>'` |
| 落盘位置 | 每个节点的 `conf/iotdb-system.properties`（CN `/data/iotdb/<build>/conf/`，DN `/data1/iotdb/<build>/conf/`） |
| 结论 | 该语句**不只是热生效，还会写回各节点配置文件**，重启后依然生效；反复设置会累积重复行 |
| 源码 | `iotdb-core/node-commons/.../conf/ConfigurationFileUtils#updateConfiguration` |
| 触发发现 | auth 套件 AUTH-007 假失败（上一轮把它置为 false 后未恢复，下一轮弱口令被放行） |

---

## 一、现象

1. 执行 `SET CONFIGURATION 'enforce_strong_password'='false'` 后，**8 个节点**的 `iotdb-system.properties` 在**同一秒内**被改写；
2. 文件末尾新增两行：`#<日期>` 标记 + `键=新值`；
3. **重启进程不会恢复**：kill -9 重启该 DN 后，弱口令依然被接受（说明值来自文件，而非内存）；
4. 反复设置同一键，文件里会**累积多行**（历史行被 `#` 注释，但仍留在文件中）；
5. 节点之间文件**行数不一致**（DN 66 行，CN 70~72 行），内容也不完全一致；
6. **查询能力有限**：`SHOW CONFIGURATION` 不存在（解析报 700，语法文件里没有该规则）；
   唯一相关的 `SHOW VARIABLES` 只返回 **18 项集群参数**，不含 `enforce_strong_password` 这类节点级热配置，
   且不支持按 key 过滤（详见 2.5）。

## 二、证据

### 2.1 变更前：8 个节点都已累积 4 行同名配置

同一时刻（2026-11-10 21:23:39）抓取全部 8 个节点：

```
--- DN 172.16.2.2（其余 4 个 DN 完全相同）---
27:#enforce_strong_password=false
33:#enforce_strong_password=true
47:#enforce_strong_password=false
49:enforce_strong_password=true        <- 唯一生效行
mtime=2026-11-10 21:23:39.342
lines=62

--- CN 172.16.2.26 ---
27:#enforce_strong_password=false
37:#enforce_strong_password=true
51:#enforce_strong_password=false
53:enforce_strong_password=true        <- 生效行
mtime=2026-11-10 21:23:38.936
```

即：这个键被改过至少 3 次，历史值以注释形式全部保留。

### 2.2 受控复现（2026-11-11 09:40）

```sql
SET CONFIGURATION 'enforce_strong_password'='false';
```

DN2 的 `iotdb-system.properties`：

| 阶段 | 行数 | 该键的行号与内容 |
| --- | ---: | --- |
| 变更前 | 62 | 27 `#...false` / 33 `#...true` / 47 `#...false` / 49 `enforce_strong_password=true` |
| 变更后 | 64 | 同上 + 63 `#Wed Nov 11 09:40:10 CST 2026` + 64 `enforce_strong_password=false` |
| 恢复 true 后 | 66 | 同上 + 64 `#enforce_strong_password=false` + 65 `#Wed Nov 11 09:41:05 CST 2026` + 66 `enforce_strong_password=true` |

文件末尾实际内容：

```
password_expiration_days=0
#Tue Nov 10 21:15:44 CST 2026
#password_reuse_interval_days=30
#Tue Nov 10 21:15:52 CST 2026
password_reuse_interval_days=0
#Tue Nov 10 21:15:55 CST 2026
#password_stale_warning_days=1
#Tue Nov 10 21:15:57 CST 2026
password_stale_warning_days=30
enable_separation_of_powers=false
#Wed Nov 11 09:40:10 CST 2026
enforce_strong_password=false        <- 本次追加
```

### 2.3 行为随文件走：重启后策略仍为 false

```
09:40:14  SET CONFIGURATION 'enforce_strong_password'='false'   -> success
09:40:17  CREATE USER cfgchk 'weakpassword'                     -> 成功（策略已关）
09:40:40  kill -9 DN6 + 启动，集群回到 8/8
09:41:00  CREATE USER cfgchk 'weakpassword'                     -> 仍然成功（说明值来自文件）
09:41:05  SET CONFIGURATION 'enforce_strong_password'='true'
09:41:08  CREATE USER cfgchk 'weakpassword'                     -> 820 拒绝（策略恢复）
```

### 2.4 源码依据

`ConfigurationFileUtils#updateConfiguration`（node-commons）：

```java
// 读取旧文件所有行
while ((line = reader.readLine()) != null) { lines.add(line); mergedProps.load(new StringReader(line)); }
for (String key : newConfigItems.stringPropertyNames()) { mergedProps.put(key, newConfigItems.getProperty(key)); }

// 逐行重写：被修改的键，旧行前面加 '#' 变成注释
if (newConfigItems.getProperty(key).equals(value)) { ... } else {
  contentsOfNewConfigurationFile.append("#").append(currentLine).append(lineSeparator);
}
...
// 末尾追加日期标记和新值
writer.write("#" + new Date().toString() + lineSeparator);
for (String key : newConfigItems.stringPropertyNames()) { writer.write(key + "=" + newConfigItems.get(key) + lineSeparator); }
```

即**保留历史是刻意实现**（便于回溯），但没有任何条数上限或清理机制。

### 2.5 查询能力核对：`SHOW VARIABLES` 只覆盖集群参数

命令语法（`IoTDBSqlParser.g4:525`）：

```
showVariables : SHOW VARIABLES        // 无参数、无过滤子句
```

实测 RC2（`-sql_dialect table`）：

```
+----------------------------------+-----------------------------------------------------------------+
|                          Variable|                                                            Value|
+----------------------------------+-----------------------------------------------------------------+
|                       ClusterName|                                                    TREEVIEW_1026|
|             DataReplicationFactor|                                                                2|
|           SchemaReplicationFactor|                                                                3|
|  DataRegionConsensusProtocolClass|                      org.apache.iotdb.consensus.iot.IoTConsensus|
|SchemaRegionConsensusProtocolClass|                  org.apache.iotdb.consensus.ratis.RatisConsensus|
...
```
共 20 行（含表头），**没有 `enforce_strong_password`**；把该键改成 false 后再查，仍然看不到（说明它不展示热配置项）。

不支持的写法（均报 `700`）：

```
show variables 'enforce_strong_password'   -> line 1:16: mismatched input ... Expecting: <EOF>
show variables like '%password%'           -> line 1:16: mismatched input 'like'. Expecting: <EOF>
show configuration                         -> line 1:5 no viable alternative at input 'show configuration'
```

源码依据：`ConfigManager#showVariables()` 直接返回 `getClusterParameters()`，即 `TClusterParameters` 的固定 18 项
（ClusterName、共识协议类、分区数/执行器、时间分区参数、数据/schema 副本数、Region 数、磁盘告警阈值、
一致性级别、时间戳精度、schema 引擎模式、tag 属性总长、数据库数量上限），与热配置无关。

**结论**：想确认 `SET CONFIGURATION` 之后的当前值，无法用 SQL 直接查，只能 `grep` 节点配置文件，
或通过行为验证间接判断 —— 这也是建议里第 5 条（扩展查询能力）的由来。

## 三、影响

| 影响 | 说明 |
| --- | --- |
| **跨轮次/跨套件污染** | 本次实测：上一轮把 `enforce_strong_password` 置 false 后，下一轮 auth 的 AUTH-007 直接假失败（弱口令被接受）。任何脚本中途退出都会留下这种残留 |
| **环境不可预期** | 集群重启、换版本目录（若共用 conf）都不会恢复默认值，只会按文件生效，排障时容易误判"代码改了行为" |
| **文件膨胀与可读性** | 同一键多行，注释行与生效行混杂；8 节点行数还不一致（DN 66 / CN 70~72） |
| **无法自查** | 没有 `SHOW CONFIGURATION`，想确认当前值只能 `grep` 文件或做行为实验 |
| **审计困惑** | 无法区分"默认值"与"被人改过的值"，除非人工比对模板 |

## 四、建议

1. **文档**（最低成本）：在用户手册 / SQL 参考中写明 `SET CONFIGURATION` 会**持久化到各节点配置文件**，
   并给出"成对恢复"的示例；脚本化使用时建议 `try/finally` 恢复。
2. **测试侧规范**（已落地）：所有修改全局配置的用例统一封装
   "设置 → 断言 → 恢复"，并在套件结束时校验终态；本轮已给 `AUTH-007` 加防御性前置。
3. **提供临时语义**：建议支持 `SET CONFIGURATION ... TEMPORARY`（仅内存）或 `RESET CONFIGURATION`，
   避免测试/运维脚本污染环境。
4. **写入去重**：对同一键只保留"1 条历史注释 + 1 条生效行"，或对历史注释加条数上限，避免无限膨胀。
5. **扩展查询能力**：`SHOW VARIABLES` 目前只返回 18 项集群参数，建议把 `SET CONFIGURATION` 涉及的键也纳入，并支持 `SHOW VARIABLES <key>` 过滤；同时在结果里标注"当前值来自文件默认 / 运行时修改"。

## 五、复现脚本

`scripts/cfg_repro.sh`（本地）→ 部署到 205 `/tmp/cfg_repro.sh`，执行
`bash /tmp/cfg_repro.sh` 即可完整复现 2.2 / 2.3 的全部步骤与输出。

## 六、附：AUTH-007 假失败时间线（本问题的直接后果）

| 时间（2026-11-10） | 事件 |
| --- | --- |
| 21:15:44 ~ 21:15:57 | 上一轮 auth 在 separation/恢复阶段多次 `SET CONFIGURATION`（密码策略、三权分立等），写入 8 节点文件 |
| 21:23:39 | auth 套件结束，最后一次写入把 `enforce_strong_password` 落盘为 `true`；但此前 21:03 开始的 normal 阶段读到的是 **false** |
| 21:03:52 | AUTH-007 首跑：`CREATE USER auth007 'NoSpecial123456'` 被接受 → 断言 `820` 失败；后续 `Good@1234567` 报 `805 已存在`（级联） |
| 21:34 | 用例加入前置 `SET CONFIGURATION 'enforce_strong_password'='true'` 后复跑 → **PASS** |
