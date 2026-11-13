# LBAC 双模式回归结果（2.0.13.1 RC2，2026-11-12）

| 项目 | 内容 |
| --- | --- |
| 需求 | TDB-415 LBAC（按用户要求：不写 PLM、不标记测试结果，问题先线下确认） |
| 版本 | 2.0.13.1 / `83183d0`（RC2） |
| 集群 | 3 CN + 5 DN，Schema 3 副本 / Data 2 副本，数据面 IoTConsensus |
| 用例 | 141 条（`lbac_skill`，9 个 case 文件） |
| 模式 | 普通模式 与 三权分立（一一对应，`LB-S-001 ↔ LB-001` … `LB-S-141 ↔ LB-141`） |

## 一、总览

| 模式 | 用例 | PASS | FAIL | SKIP | 备注 |
| --- | ---: | ---: | ---: | ---: | --- |
| 普通模式 | 141 | **139** | **0** | 2 | 结果文件 `results_normal.tsv` |
| 三权分立 | 141 | **139** | **0** | 2 | 结果文件 `results_sep.tsv` |

**两模式逐条结果完全一致**（`lbac_compare.md` 差异项为空）。

SKIP 2 条（两模式相同）：

| 用例 | 原因 |
| --- | --- |
| LB-109 | 可写视图底层源为树模型（`VIEW FROM TREE`），无表级 LBAC 绑定，无法验证；逻辑视图同场景由 LB-110 覆盖 |
| LB-122 | 同上（可写视图写入路径） |

## 二、覆盖范围（与需求/技术评审对齐）

| 模块 | 覆盖内容 | 用例 |
| --- | --- | --- |
| 组件 Component | ARRAY/SET/TREE 创建；元素重名、保留字符、空元素、32 bytes 边界；ALTER ADD（BEFORE/AFTER/UNDER/OVER/ROOT）；DROP 被策略引用拒绝；COMMENT | LB-001~020 |
| 策略 Policy | 单/多组件、组件顺序、ALTER ADD COMPONENT（已有标签补空值）、表绑定后禁止、USE/IGNORE ROLE AUTHORIZATIONS、DROP 四类依赖 | LB-021~035 |
| 标签 Label | 单/多组件、多值、全空拒绝、策略外组件拒绝、重名、DROP（被授权/被列引用）、规范化 label_value | LB-036~046 |
| 授权/撤销 | READ/WRITE/ALL、同类型冲突、授予角色、无 SECURITY 拒绝、角色标签参与规则、**免除权**（6 规则 + WRITE_UP/WRITE_DOWN + ALL 展开 + 幂等 + REVOKE ALL） | LB-047~068 |
| 比较语义 | ARRAY READ/WRITE 各 6 组、SET READ/WRITE、TREE READ/WRITE、空值规则、默认空标签、多组件 AND、ALL ACCESS | LB-069~096 |
| 对象绑定/视图 | 建表绑策略+列保护、标签不属于策略、重复绑定、新增/修改/解除列保护的凭证要求、DROP SECURITY POLICY 级联、视图禁止保护、逻辑视图走底层表检查 | LB-097~110 |
| DML | SELECT / `SELECT *` / `COUNT(*)` / DESCRIBE、INSERT、UPDATE(ATTRIBUTE)、DELETE、DROP TABLE/DATABASE | LB-111~122 |
| 系统表/审计 | 7 张 `security_*` 表、`tables.security_policy` / `columns.security_label`、审计与 SECURITY 权限 | LB-123~131 |
| 高可用/一致性 | CN 重启、DN 重启、ALTER COMPONENT 版本补拉、解除保护立即生效、ALTER POLICY 立即生效、3 CN 元数据一致、2 副本数据一致、重启后 grant/exemption 持久化、日志扫描、并发授权 | LB-132~141 |

## 三、CN/DN 日志检查

按用例窗口收集 CN/DN 日志中的 `ERROR` / `WARN`（`log_scan_normal.txt` / `log_scan_sep.txt`）：

| 模式 | 总行数 | ERROR | WARN |
| --- | ---: | ---: | ---: |
| 普通模式 | 549 | 8 | 541 |
| 三权分立 | 605 | 1 | 604 |

**ERROR 全部为集群重启/选主噪音，与 LBAC 无关**：

| 时间 | 模式 | 内容 | 对应用例 |
| --- | --- | --- | --- |
| 16:27:50 / 16:39:43 | 普通 | `CHANGE_REGION_LEADER` / `INVALIDATE_LAST_CACHE` 超时 + `[LeaderBalancer] Failed to change the leader` | LB-132/133（CN/DN 重启） |
| 19:25:41 | 三权分立 | `Failed to INVALIDATE_LAST_CACHE on DataNode id=7` | LB-138/139（DN 重启） |

WARN 按来源归类（两模式一致）：

| 来源 | 说明 | 是否异常 |
| --- | --- | --- |
| `GrpcLogAppender ... is interrupted / Follower failed` | Ratis 在节点重启/执行器中断时的常规告警 | 否 |
| `StateMachineProcedure ... set next state to N` | Procedure 状态推进日志 | 否 |
| `CompactionWorker ... interruption` | 压缩线程随节点重启中断 | 否 |
| `IoTDBDescriptor: Cannot find IOTDB_HOME` / `Couldn't load the configuration` | 三权分立开启时 DN 进程重启瞬间的告警（集群仍正常） | 否（建议关注启动脚本） |
| `License has not been set...` | 激活服务与 CN 未连通时的既有告警 | 否 |
| `Fail to check password expiration` | 用户无过期策略时的既有告警 | 否 |
| `Failed to get table lb_db.t1 when calculating the time...` | DROP DATABASE 与统计线程竞争 | 否（既有行为） |

**结论：无 LBAC 相关 ERROR/WARN。**

## 四、三权分立模式的关键结论

| 项 | 实测结论 |
| --- | --- |
| root | 开启后禁止登录（803 `SUPER USER is not allowed to login`） |
| sys_admin | 可建库/建表，但**无数据 INSERT/SELECT 权限**；无 SECURITY |
| security_admin | 唯一可做 LBAC DDL、建用户、GRANT；**不能建库建表** |
| audit_admin | 仅审计，不能建用户、不能读数据 |
| 列保护与数据读写 | 两类管理员均无业务数据权限，必须由普通用户（持有标签凭证 + RBAC 授权）执行 |
| `ALTER TABLE ... DROP SECURITY POLICY` | 需要 ALTER(sys_admin) + SECURITY(security_admin)，**单个主体无法同时具备**；实测 security_admin 自授 `ALTER ON DATABASE` 后可执行（建议在文档中说明该组合操作方式） |
| 开启三权分立 | 热加载命令后 DataNode 会重启（日志可见启动告警），需预留重启窗口 |

## 五、复现方式

```bash
cd /data2/auto_test/lbac_skill

# 普通模式
SEP=0 RESULT_BASE=/data2/auto_test/lbac_results_normal_$(date +%Y%m%d_%H%M%S) \
  nohup setsid bash tools/suite.sh > /tmp/lbac_normal.log 2>&1 &

# 三权分立
bash tools/mode_sep.sh on
SEP=1 RESULT_BASE=/data2/auto_test/lbac_results_sep_$(date +%Y%m%d_%H%M%S) \
  nohup setsid bash tools/suite.sh > /tmp/lbac_sep.log 2>&1 &
bash tools/mode_sep.sh off      # 关闭（写配置 + 重启）

# 结果与报告
bash tools/report.sh <results>/run_* /tmp/report.md "普通模式"
```

## 六、遗留与建议

1. ~~可写视图（VIEW FROM TREE）无表级 LBAC 绑定~~ → **已确认（2026-11-13）：可写视图不做 LBAC 保护**，LB-109/122 永久标记为「不适用」，不作为缺口。
2. **三权分立组合操作**：`DROP SECURITY POLICY`、修改列保护等需要跨管理员权限的操作，建议产品提供明确的授权组合方式或在手册中给出操作步骤。
3. 三权分立开启会触发 DN 重启，测试/运维需按变更窗口安排。
