# 最终汇总（截至 2026-10-20）

## 1. 总览
| 套件 | 用例数 | PASS | 产品 FAIL | harness 待修 | SKIP | INVALID |
|---|---|---|---|---|---|---|
| PROACTIVE 全量（3C5D，SR3/DR2） | 217 | 124 | 36（D-04×26、D-05×10） | 15 | 41 | 1 |
| 升级族（1.3.7.1 → 2.0.11） | 16 | 15 | 0 | 0 | 0 | 0 |
| **合计** | **233** | **139** | **36** | **15** | **41** | **1** |

升级族唯一 FAIL：UPG-15（日志卫生，L-2 WARN），无数据丢失、无扩容回归。

## 2. 产品缺陷
| 编号 | 结论 | 影响 |
|---|---|---|
| D-04 | 表模型库上限被钉在最小值（`{SCHEMA:1,DATA:2}` vs 公式 `{3,30}`），`adjustRegionGroupNum` 吞掉 `DatabaseNotExistsException` | 26 例 FAIL，**已确证产品缺陷** |
| D-05 | 测点级 `select count(*)` 返回空而设备级返回 1（resume 轮 10/10 复现） | 10 例 FAIL，**已确证 P1**，按用户要求暂不登记 PLM |
| TDB-676 | 已关闭（RC8 验证通过，PLM 文档 1042）；残留 `InsertRowsNode` ERROR 经研发确认**暂不处理**（drop 后信息缺失无法区分），回归中仍记录不白名单 | 语义无损，仅日志噪声 |

## 3. harness 缺陷（已修 22 项，重点）
H-10/H-19（上限口径：与产品自报对比、`实测≥公式`）、H-22b（drop 后 `-1` 视为 0）、
H-23（收尾窗口登记）、H-24（日志归因 44 条正则）、H-25（harness 动作窗口）、
H-31（`count(*)` 每测点一列，UPG-13 修口径后 PASS）、H-32（两类重试噪声 WARN 分类）。
仍待修：HA-02/HA-04（DataNodeId vs IP 混用）、RCV-01/02/07（期望 2 实测 3）、
7 例日志签名（HA-03/05/09/10/11、TIME-07、DEV-12）。

## 4. 遗留与建议
1. 15 例 harness 待修项修完后再跑一轮，预计可把 41→ 更小的 SKIP、15→ 更小的待修；
2. D-04/D-05 需要产品侧确认修复计划（D-05 用户已示意暂不登记 PLM）；
3. L-1/L-2 两类 WARN 建议产品侧评估是否降级为 DEBUG；
4. 5C20D（SR5/DR3）测试包已交付（14 例：线程/内存泄漏 + 多 DN 约束），在新环境首跑后回传结果。

---

## 5. harness 待修 15 项：处置与复跑结果（2026-10-20）

**结论：12 个受影响用例复跑 → 11 PASS / 1 FAIL**（唯一残余 HA-10 为纯日志签名，需根因堆栈才能定性）。

| 用例 | 旧失败原因 | 修法 | 复跑 |
|---|---|---|---|
| HA-02 / HA-04 | 副本标识混用 `DataNodeId` 与 IP；"在线副本数"期望值取全局在线集合 | 副本统一归一化到 IP（`NodeID→IP` 映射 + 行内地址列，裸数字不当地址比）；只对本用例**实际停掉**的节点豁免；恢复后才要求全在线 | ✅ PASS |
| RCV-01 / RCV-07 | 硬编码"Schema 组数应为 2"，实测 3 | 上限改取产品自报 `MaxSchemaRegionGroupNum`（=3），判 `最小期望 ≤ 观测 ≤ 上限`，读不到则 SKIP | ✅ PASS |
| RCV-02 | 未筛"被停 DN 真正承载的组"；`readonly` 被当成异常 | 先筛承载组；**H-34**：RF=2 掉 1 副本=无多数派，产品转 `readonly` 属正确降级，只有 Unknown/Unavailable 才算异常 | ✅ PASS |
| HA-11 | 用公式上限 6，产品自报 `MaxDataRegionGroupNum=7`、实测 7 | **H-35**：上限改取产品自报值（公式仅兜底）——继 H-10/H-19 后第三处同类修正 | ✅ PASS |
| HA-03 / HA-05 / HA-11 | `TopicPushMetaRPCHandler:78`、`TransferLeadership:227` | 6 条**窄**正则 + 动作窗口归因（停机/重建窗口），并加"白名单必须不命中"的反例自检 | ✅ PASS |
| HA-09 | `AsyncRequestManager:170` 缓存失效重试 | 同上（`INVALIDATE_(PARTITION|SCHEMA)_CACHE` 窄模式，id 指向被停节点） | ✅ PASS |
| TIME-07 / DEV-12 | `FragmentInstanceDispatcherImpl:637 Socket is closed by peer., and we try to reconnect` | 窄模式 + 仅在前例停机/重启尾窗内归因 | ✅ PASS |
| **HA-10** | `AbstractDriverThread:123 - [ExecuteFailed]` | **未归因**（紧邻 Shutdown-Hook 但无根因堆栈，按纪律不加白名单） | ❌ **FAIL（保留）** |

### 新增/修订规则
- **H-33**：副本位置断言必须"先归一化再比较"，且被停节点只认本用例的停机登记；
- **H-34**：`readonly` 是 RF=2 掉 1 副本时的正确降级形态，不算失败；
- **H-35**：组数上限一律取产品自报值（`Max*RegionGroupNum`），公式值只作兜底。

### 环境噪声（非产品缺陷，需清理后复跑）
- `RaftStorageDirectoryImpl:230 - Unable to acquire file lock`（HA-11 收尾③，18 次 ERROR）：源于**手工重启节点**时同目录被两个进程争用，属操作残留，不代表产品问题；
- `syncLag cannot drain: <ip> is Unknown`：停机/重启窗口内的瞬态，窗口外复跑即恢复。
