# treeview_skill —— 树转表（tree → table view）测试技能

被测对象：**TimechoDB 2.0.13.1 RC1（build `ab6d3de`）**，3C3D（SR=3 / DR=3），协议 `IoTConsensus`（也支持 `IoTConsensusV2`）。
需求来源：《树转表——需求分析（V2.0.5.1-开源）》（`D:\IDEA\deepseek\cloud1_ip205\tree_view_skill_case\*.docx`）；
技术设计 PLM docs/913；源码 `D:\IDEA\timechodb_src\v20131\timechodb`。

## 一、跑法

```bash
cd /data/iotdb/autotest/treeview_skill
# 单档
bash tools/run_all.sh --set create  --consensus org.apache.iotdb.consensus.iot.IoTConsensus
bash tools/run_all.sh --set ddl
bash tools/run_all.sh --set query|ttl|security|ha|real|all
# 单条
bash cases/treeview/tv_create_basic.sh --consensus org.apache.iotdb.consensus.iot.IoTConsensusV2
# 复跑时保留集群（省启动时间）
bash tools/run_all.sh --set ddl --keep-cluster
```

产物：`results/<case>_<runid>.out`、`results/artifact_<case>_<runid>/{logs,log_marks.txt,cluster_prepare.log}`、`results/test_result.csv`。

## 二、每条用例的固定收尾（需求要求）

1. **等 sync lag 归零**：抓各 DN `http://<dn>:9092/metrics` 的 `iot_consensus{type="syncLag"}`，要求非零序列数合计 = 0；
2. **副本一致性**：以"全部在线"的查询指纹（count/sum 归一化 + md5）为基线，**逐个停 1 个 DN**（停满 3 轮，每轮用其余两个 DN 各查一次）再与基线比对；
3. **CN/DN 日志**：按每节点**日志行数基线**只扫新增行，`ERROR|WARN` 减去 BENIGN 白名单（Ratis 追加失败、停节点导致的 PageCache 中断等）后必须为 0；
4. **FAIL 即备份日志**：`artifact_<case>_<runid>/logs/192.168.99.{77,78,79}.tgz`。

> BENIGN 白名单在 `lib/common.sh` 的 `TV_LOG_BENIGN`；用例可再加 `TV_LOG_BENIGN_EXTRA`（负向用例用它放行"故意触发的失败语句"产生的 WARN）。

## 三、清洁环境

`tv_prologue <tree_db> <table_db>`：起集群 → 等就绪 → `tv_reset_db` 把本用例自己的**树库/表库 DROP 重建**（集群元数据在 CN 上，删 DN 数据目录清不掉 schema）。
⚠ 不要删 `data/datanode/system`（nodeId）与 `data/confignode`（集群身份/激活），否则 DN 会因"nodeId 已被移除"拒绝启动。

## 四、用例矩阵（需求点 → 用例）

| 需求点（来源） | 用例 | 状态 |
| --- | --- | --- |
| §2.1.1 CREATE 语法/字段解释；TAG↔层级、FIELD↔测点、`FROM original_measurement` 改名、无 FIELD 自动扫描、dataType 自动推断、time 列、视图只读 | `tv_create_basic.sh`（TV-01） | **PASS** |
| §2.1.1.1 负向：prefixPath 必须 `**` 结尾（701）、ATTRIBUTE 不支持（700）、同测点两列（701）、类型冲突（614）、扫描不到测点（528）、重复列名（701） | `tv_create_negative.sh`（TV-02） | **PASS** |
| §2.1.1.1 `OR REPLACE`：view→替换、table→报错、无 OR REPLACE→报错 | `tv_create_negative.sh`（TV-02 第 8 段） | **PASS** |
| §2.1.1.3 RESTRICT 与设备层级（`<= tag` vs `== tag`；tag=0 实测可建但 0 行） | `tv_create_restrict.sh`（TV-03） | **PASS** |
| §2.2 ALTER：ADD COLUMN（含 `FROM` 改名加列、IF NOT EXISTS）、RENAME COLUMN、DROP COLUMN、ALTER COLUMN SET DATA TYPE、RENAME TO、SET PROPERTIES(ttl)、COMMENT ON VIEW/COLUMN、DROP VIEW | `tv_alter.sh`（TV-04） | 已实现，跑 ddl 档 |
| §2.3 SHOW TABLES 的 `TABLE_TYPE`（BASE TABLE / VIEW FROM TREE / SYSTEM VIEW）、SHOW CREATE TABLE/VIEW（可用其 DDL 异地复现）、DESC、information_schema | `tv_show.sh`（TV-05） | 已实现，跑 ddl 档 |
| §2.4 对齐/非对齐设备的 null 行语义（对齐保留全 null 行、非对齐丢弃；行数取决于所选 field 列） | `tv_query_align.sh` | **待实现**（设计已定：造对齐+非对齐设备各一，分别查全 field/部分 field/仅 tag） |
| §2.4/§3 查询能力与树模型对照（投影、where、order/limit、聚合、按 tag group、join、子查询） | `tv_query.sh` | **待实现** |
| §2.1.1.1 `WITH (ttl=...)`：与树 TTL 取更小值、只影响查询不物理删除 | `tv_ttl.sh` | **待实现** |
| §2.7 安全性（CREATE/ALTER/DROP 需对应权限；create or replace 另需 prefixPath 的 READ_SCHEMA/READ_DATA；查视图只需视图 SELECT） | `tv_security.sh` | **待实现** |
| 高可用（停 1 DN / 停 1 CN 后视图 DDL 与查询可用） | `tv_ha.sh` | **待实现** |
| §2.8 元数据同步（tree pipe 不同步 view；table pipe 同步；接收端 isReplace=true、不重扫） | `tv_sync.sh` | **待实现** |
| §2.5 性能（视图查询与普通表同量级） | 并入 `tv_perf` 设计 | **待实现** |
| **可观测性门禁**：预期内的用户输入错误（`CREATE VIEW` 因同名测点类型冲突失败，614）不得在 CN/DN 日志里产生 ERROR/WARN 与异常栈（TDB-894 CN 侧已修；DN 侧 `ConfigExecution:223` 为残留，研发随后续 commit 修） | `tv_log_noise.sh`（TV-LOG-01） | **门禁已就绪**（RC2 上 EXPECTED FAIL：L1 `1→2`、L2 `68→85`；修复后应转 PASS） |
| **多客户端接口建序列**：JDBC(Java) / Python(apache-iotdb) / Go(iotdb-client-go) 建测点后视图自动补列一致（REST/C++ 走官方 rest 接口，需 enable_rest_service） | `tv_client_iface.sh`（TV-CLI-01） | **已实现，跑 client 档** |
| 真实数据集（`root.reactor...AA5.**` 的 TsFile）冒烟 + 查询对照 | `tv_realdata.sh` | **待实现**；数据集 327MB 受跳板链路限制（实测 11KB/s）暂未上传 |

## 五、实测记录（2026-11-04，V1）

| 用例 | 结果 | 耗时 |
| --- | --- | --- |
| TV-01 `tv_create_basic` | **PASS fail_flag=0** | 165s |
| TV-02 `tv_create_negative` | **PASS fail_flag=0** | 165s |
| TV-03 `tv_create_restrict` | **PASS fail_flag=0** | 158s |
| TV-04 `tv_alter` | 见 `results/`（ddl 档） | — |
| TV-05 `tv_show` | 见 `results/`（ddl 档） | — |

已确认的产品行为（写入断言，避免以后误判）：

- prefixPath 违法（中间 `**` / 末级 `*` / 末级非通配）统一 **701 `The last node must be '**'`**；
- 同一测点被两列引用 → **701 `The duplicated source measurement ... is unsupported yet`**；
- 未指定类型且同名测点在不同设备类型不同 → **614 `Multiple types encountered when auto detecting type`**；
- 前缀下扫不到测点 → **528 `Measurements not found for ..., cannot auto detect`**；
- 重复列名 → **701 `Columns in table shall not share the same name`**；
- 列类别 ATTRIBUTE → **700** 语法错误（需求明确不支持）；
- `tag=0 + RESTRICT` → **允许创建，视图为空**（0 行）；
- 视图**只读**：`insert into <view>` 被拒绝（无 successfully）。

## 六、TV-LOG-01 可观测性门禁（tv_log_noise.sh）

**为什么有这条**：CREATE VIEW 因「同名测点类型冲突」失败是**符合需求的预期内错误**（614），
但它不应该在日志里升级成故障信号。

- **CN 侧（TDB-894）**：RC2 已修复 —— TreeDeviceViewFieldDetectionHandler 对
  EXPECTED_FAILURE_CODES{614, 552, COLUMN_CATEGORY_MISMATCH} 记 **INFO**、只带 code+message，不打印 TDeviceViewResp 全文。
- **DN 侧（残留）**：仍打 WARN ConfigExecution:223 + 完整异常栈，因为
  ConfigExecution.userExceptionCodes 里没有 DATA_TYPE_MISMATCH(614)。研发确认随后续 commit 顺带修复，故用本用例守回归。

**判据（严格，不放 benign 白名单）**

| 编号 | 判据 |
| --- | --- |
| L1 | DN 新增 ConfigExecution:223 行数 = 0 |
| L2 | DN 新增异常栈行 = 0 |
| L3 | CN 新增 ERROR.*TreeDeviceViewFieldDetectionHandler = 0 |
| L4 | CN 新增 TDeviceViewResp = 0 |
| L5 | 场景有效性：客户端必须拿到 **614** |
| L6 | 正向对照：显式声明类型后视图可建、可查到 1 行 |

**边界（别写错场景）**：只有**完全不声明 FIELD**（create view db.v (dev STRING TAG) as root.db.**）
才会走服务端自动探测并命中该 WARN；把 FIELD 列出来但不写类型（create view ... (t STRING TAG, temp FIELD)）
不会命中 —— 这也是 	v_create_negative 的 TV-02 一直绿的原因。

**跑法**：ash tools/run_all.sh --set log（已并入 --set all）。

**当前状态**：RC2（83183d0）上 **EXPECTED FAIL**（ail_flag=2：L1 1→2、L2 68→85，其余 14 条 PASS），
研发修复包出来后再跑应转 PASS；转 PASS 前不要把 ConfigExecution 加回 TV_LOG_BENIGN_EXTRA
（	v_create_negative.sh 里那条会掩盖本问题的白名单已于 2026-11-11 收窄删除，收窄后该用例仍 25 PASS）。
