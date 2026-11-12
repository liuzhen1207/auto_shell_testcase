# lbac_skill — LBAC（Label Based Access Control）测试套件

面向 TimechoDB 2.0.13.1（表模型）LBAC 功能的自动化回归，覆盖需求文档与 PLM 技术评审
（`https://plm.infra.timecho.com/docs/1030`）中的全部描述点：组件/策略/标签、授权与撤销、
规则免除权、标签比较语义、对象保护、DML 拦截、系统表、审计、高可用、副本一致性与日志检查。

## 一、被测环境

| 项 | 值 |
| --- | --- |
| 版本 | 2.0.13.1 / `83183d0`（RC2） |
| 集群 | 3 CN（172.16.2.26/27/28）+ 5 DN（172.16.2.2~6） |
| 副本 | Schema 3 副本、Data 2 副本 |
| 数据面协议 | IoTConsensus |

## 二、用例构成（141 条）

| 文件 | 覆盖范围 | 条数 |
| --- | --- | ---: |
| `cases/c1_component.sh` | Component：ARRAY/SET/TREE 创建、元素约束（重名/保留字符/32 字节/层级唯一）、ALTER ADD ELEMENT（BEFORE/AFTER/UNDER/OVER/ROOT）、DROP 依赖、COMMENT | 20 |
| `cases/c2_policy.sh` | Policy：单/多组件、组件顺序、ALTER ADD COMPONENT（含已有标签补空值）、表绑定后禁止、USE/IGNORE ROLE AUTHORIZATIONS、DROP 四类依赖、COMMENT | 15 |
| `cases/c3_label.sh` | Label：单/多组件、多值、全空拒绝、策略外组件拒绝、重名、DROP（被授权/被列引用）、规范化 `label_value` | 11 |
| `cases/c4_grant.sh` | GRANT/REVOKE（READ/WRITE/ALL）、访问类型冲突、授予角色、无 SECURITY 权限拒绝、角色标签参与规则、**规则免除权**（6 规则 + WRITE_UP/WRITE_DOWN + ALL 展开 + 幂等 + REVOKE ALL） | 22 |
| `cases/c5_compare.sh` | **比较语义矩阵**：ARRAY READ 6 组 / ARRAY WRITE 6 组、SET READ/WRITE、TREE READ/WRITE、空值规则、默认空标签、多组件 AND、ALL ACCESS | 28 |
| `cases/c6_object.sh` | 对象绑定：建表绑定策略 + 列保护、标签不属于策略、重复绑定、新增/修改/解除列保护的凭证要求、DROP SECURITY POLICY 级联、视图禁止保护、可写/逻辑视图走底层表检查 | 14 |
| `cases/c7_dml.sh` | DML：SELECT/`SELECT *`/`COUNT(*)`/DESCRIBE、INSERT、UPDATE（ATTRIBUTE）、DELETE（含 WHERE 读凭证）、DROP TABLE、可写视图写入 | 12 |
| `cases/c8_systable_audit.sh` | 系统表 `security_policies`/`security_label_components`/`..._elements`/`security_policy_component_rules`/`security_labels`/`security_label_access`/`security_policy_exemptions`、`tables.security_policy`/`columns.security_label`、审计与 SECURITY 权限 | 9 |
| `cases/c9_ha.sh` | HA/一致性：CN 重启、DN 重启、ALTER COMPONENT 版本补拉、解除保护立即生效、ALTER POLICY 立即生效、3 CN 元数据一致、2 副本数据一致、重启后 grant/exemption 持久化、日志扫描、并发授权 | 10 |

## 三、运行方式

```bash
# 全量
cd /data2/auto_test/lbac_skill
NEW=v20131rc2_1110_83183d0 bash tools/suite.sh

# 指定用例（支持子串）
NEW=v20131rc2_1110_83183d0 bash tools/suite.sh LB-097 LB-111
NEW=v20131rc2_1110_83183d0 bash tools/suite.sh LB-0    # 前 99 条

# 结果
results/run_<ts>/results.tsv     # id/feature/type/verdict/fails/dur/detail
results/run_<ts>/<case>.out      # 每例完整输出
results/run_<ts>/log_scan.txt    # 整轮 CN/DN 日志 ERROR/WARN 扫描
```

## 四、实现约定（重要）

1. **root 不能直接持有 LBAC 凭证**（授权后存在缓存窗口，且同一 policy 下每个主体每种访问类型只能持有一个 label）。
   因此凡需要 LBAC 凭证的操作（列保护、写入受保护列），lib 都用 `with_label <label> <sql>`
   临时创建一个只持有该 label `ALL` 的用户来执行。
2. **清理顺序**：删库（解绑表）→ 删测试用户/角色（解除授权）→ 撤销 root 残留授权 → 删标签 → 删策略 → 删组件。
   顺序错误会导致 `2412/2413/2414` 连锁失败，并把脏状态带给下一个用例。
3. **SET 组件的 `label_value` 元素顺序不稳定**（如 `A:(QA,RD)`），断言需顺序无关；
   单值 SET 展示为 `A:RD`（不带括号，符合需求"仅多值加括号"）。
4. 每个用例自带 `lbac_reset`，可单独重复执行；`ADMIN`/临时用户均以 `lbu_` 前缀命名，便于清理。

## 五、判读规则

- `PASS`：全部断言通过；
- `FAIL`：任一断言失败（detail 列给出前 3 条失败原因）；
- `KNOWN`：命中 `conf/known_failures.conf`（当前为空）；
- 日志扫描：过滤已知 HA/Raft/Pipe 噪声后，剩余 ERROR/WARN 逐条列在 `log_scan.txt`。

## 六、三权分立（separation of powers）模式

141 条用例与普通模式**一一对应**（`LB-S-001 ↔ LB-001` … `LB-S-141 ↔ LB-141`），映射表由
`tools/suite_sep.sh` 首次运行时生成到 `cases_sep.tsv`。

### 6.1 模式切换

```bash
bash tools/mode_sep.sh on     # root 热加载开启（root 会立即被禁止登录）
bash tools/mode_sep.sh off    # 写配置 false + 重启 8 节点（SQL 无法关闭）
bash tools/mode_sep.sh status # 查看 root / sys_admin / security_admin / audit_admin 登录情况
```

### 6.2 三权分立下的权限边界（实测）

| 主体 | 建库/建表 | 读写数据 | LBAC 元数据 / 用户 / 授权 | 审计 |
| --- | --- | --- | --- | --- |
| root | ✗ 禁止登录（803） | ✗ | ✗ | ✗ |
| sys_admin | ✓ | ✗（无 INSERT/SELECT 数据权限） | ✗（无 SECURITY） | ✗ |
| security_admin | ✗ | ✗ | ✓（唯一可做 LBAC DDL、建用户、GRANT） | ✗ |
| audit_admin | ✗ | ✗ | ✗ | ✓ |
| 普通用户 | ✗ | ✓（需 security_admin 授权） | ✗ | ✗ |

因此套件在 SEP=1 时按语句类型分发身份：
- **sys_admin**：`CREATE/DROP DATABASE|TABLE|VIEW`、`INSERT/SELECT/UPDATE/DELETE`、`SHOW/LIST` 集群类；
- **security_admin**：`CREATE/ALTER/DROP SECURITY ...`、`COMMENT ON SECURITY`、`GRANT/REVOKE`、`CREATE/DROP USER|ROLE`、`LIST USER|ROLE`；
- `information_schema.security_*` 查询固定走 security_admin（只有 SECURITY 主体能看到全部记录）。

### 6.3 两个模式差异点（用例层面已处理）

1. **列保护 / 数据读写**：两类管理员都没有业务数据权限，因此统一由 `with_label` 创建
   "只持有某个 label ALL 权限" 的临时用户来执行（建用户与授权走 security_admin）。
2. **`ALTER TABLE ... DROP SECURITY POLICY`**：该操作需要 ALTER(sys_admin) + SECURITY(security_admin)，
   单个主体无法同时具备。用例在三权分立下先由 security_admin 自授 `ALTER ON DATABASE` 再执行（实测可行）。

### 6.4 运行

```bash
# 前置：开启三权分立
bash tools/mode_sep.sh on
# 全量（结果落在 skill 目录外，避免重新部署覆盖）
SEP=1 RESULT_BASE=/data2/auto_test/lbac_results_sep_$(date +%Y%m%d_%H%M%S) \
  nohup setsid bash tools/suite.sh > /tmp/lbac_sep.log 2>&1 &
# 或使用封装脚本
bash tools/suite_sep.sh            # 生成映射 + 运行全量
```
