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

## 二、用例构成（197 条）

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

## 七、最近一次结果（2026-11-17，RC2 `83183d0`，SR3/DR2，197 条）

| 模式 | 用例 | PASS | FAIL | SKIP |
| --- | ---: | ---: | ---: | ---: |
| 普通模式 | 197 | **187** | **0** | 10 |
| 三权分立 | 197 | **188** | **0** | 9 |

两模式唯一差异为 LB-157（仅三权分立执行）。详见 `docs/results_20261117/`（SUMMARY、双模式报告、逐条对比、结果 TSV、日志窗口）。

历史结果：
- 2026-11-13（160 条，SR3/DR2）：普通 150 PASS / 三权分立 151 PASS，0 FAIL
- 2026-11-14（160 条，IoTConsensusV2）：同上，与 IoTConsensus 逐条一致

## 八、补充用例 LB-142 ~ LB-160（2026-11-13）

首轮 141 条之后，针对覆盖缺口补充 19 条（12 条可执行 + 7 条 SKIP）：

| 分组 | 用例 | 结论 |
| --- | --- | --- |
| 绑定生命周期 | LB-142 表切换策略并重新保护列；LB-145 DROP COLUMN 后标签可删 | PASS |
| | LB-143 TAG/TIME 保护（待需求确认）、LB-144 RENAME、LB-146 CTAS/LIKE（语法不支持） | SKIP |
| 查询表达式 | LB-147 聚合 `COUNT/SUM/AVG(受保护列)`；LB-148 `GROUP BY/HAVING/ORDER BY`；LB-149 `WHERE`；LB-150 别名；LB-151 双表 JOIN（AND 语义）；LB-152 `UNION`/子查询 | PASS |
| 权限级联 | LB-153 仅 LBAC 凭证无 RBAC → 803；LB-155 DROP USER 级联清理授权与豁免；LB-156 `GRANT EXEMPTION TO ROLE`（IGNORE/USE）；LB-157 三权分立跨管理员边界 | PASS |
| | LB-154 READ/WRITE 不同标签（待需求确认） | SKIP |
| 数据旁路 | LB-158 导出、LB-159 pipe、LB-160 LOAD（待需求确认是否在 LBAC 范围） | SKIP |

补充过程中确认的实现细节：

- 默认策略模式为 **IGNORE**（`use_role_authorizations=false`），角色豁免需显式 `USE ROLE AUTHORIZATIONS`；
- `DROP COLUMN` 受保护列需要该标签的 **WRITE 凭证**（root 直接执行会 2400）；
- 同一策略下同一用户只能持有一个 READ 标签 → 双表 JOIN 正向场景需两个策略；
- 表模型不支持 `RENAME TABLE` / `CREATE TABLE ... AS SELECT` / `LIKE`（均报 700）；
- 三权分立下 `ALTER TABLE ... DROP SECURITY POLICY` 需 security_admin 自授 `ALTER ON DATABASE` 后执行（LB-142/LB-107 已按此实现）。

## 九、IoTConsensusV2 协议结果（2026-11-14）

| 协议 | 模式 | 用例 | PASS | FAIL | SKIP |
| --- | --- | ---: | ---: | ---: | ---: |
| IoTConsensus | 普通 / 三权分立 | 160 | 150 / 151 | 0 / 0 | 10 / 9 |
| **IoTConsensusV2** | 普通 / 三权分立 | 160 | **150 / 151** | **0 / 0** | **10 / 9** |

逐条判决与 IoTConsensus 完全一致。V2 下日志量约为 IoTConsensus 的 2 倍（`[ConsensusPipeGuard]`、`PIPE_PUSH_*`、`PIPE_HEARTBEAT` 等协议内部管道噪音），无 LBAC 相关 ERROR/WARN。
详见 `docs/results_20261114_v2/`。

## 十、用例总账与回归前自检（防遗漏）

维护两个「单一事实来源」：

| 文件 | 作用 | 生成方式 |
| --- | --- | --- |
| `cases.tsv` | 用例清单（ID/文件/模块/类型/描述/函数），**执行时以它为准** | 手工维护，新增用例必须同步 |
| `docs/CASE_REGISTRY.md` | 人读的用例总账：按模块分组，含状态与四轮判决 | `python3 tools/gen_registry.py` |
| `registry.tsv` | 机器读的总账，用于比对与统计 | 同上 |

### 每次回归的标准流程

```bash
cd /data2/auto_test/lbac_skill

# 1) 自检：cases.tsv / cases/*.sh / registry.tsv 三者对齐（纯 bash，服务器可跑）
bash tools/preflight.sh          # 返回 0 才继续

# 2) 全量回归（160 条；不带参数即全量，避免漏跑）
SEP=0 RESULT_BASE=/data2/auto_test/lbac_results_normal_$(date +%Y%m%d_%H%M%S) \
  nohup setsid bash tools/suite.sh > /tmp/lbac_normal.log 2>&1 &

# 3) 三权分立
bash tools/mode_sep.sh on
SEP=1 RESULT_BASE=/data2/auto_test/lbac_results_sep_$(date +%Y%m%d_%H%M%S) \
  nohup setsid bash tools/suite.sh > /tmp/lbac_sep.log 2>&1 &
```

新增/删改用例后的动作（缺一不可）：

1. 在 `cases/cX_*.sh` 的 `CASES+=(...)` 里加声明 + 实现 `case_LBxxx()`；
2. 在 `cases.tsv` 补一行（ID 连续，不能跳号）；
3. 本地跑 `python3 tools/gen_registry.py` 重新生成总账；
4. 提交前跑 `bash tools/preflight.sh`（或 `python3 tools/check_cases.py`）确认为 0。

### 当前总账基线（2026-11-14）

| 项 | 数量 |
| --- | ---: |
| 用例总数 | **197** |
| 常规执行 | 185 |
| 条件执行（仅三权分立 LB-157） | 1 |
| 跳过（不适用/待确认） | 9 |

跳过 9 条：LB-109/122（可写视图不适用）、LB-143/154/158/159/160（待需求确认）、LB-144/146（语法不支持）。
`preflight.sh` 会校验 ID 连续性，因此**新增用例只能追加在末尾**；如需插入中间 ID，必须整体重排并重新生成总账。

## 十一、按研发自测用例扩展（LB-161 ~ LB-180）

研发 LBAC 自测文档共 139 条（C/P/L/G/R/E/M 七组）。对照后新增 20 条补齐我方未断言的点：

- 组件：单元素/200 元素、零元素、非法类型、ARRAY 省略位置、SET 拒绝位置、TREE OVER 重挂接、双 ROOT、元素插入后比较语义、类型不可变；
- 策略：重复引用组件、空 COMPONENTS、规则集名校验；
- 标签：SET/ARRAY packed string、重复指定组件、裸名必须带策略前缀、ALTER LABEL；
- 授权/比较：同一主体 READ=高标签 + WRITE=低标签；
- 豁免：仅 READARRAY 的分组件豁免、ALL 展开后撤销单规则、角色 READTREE + IGNORE/USE。

完整对照与剩余缺口见 `docs/selftest_coverage.md`（仍有 12 项细粒度场景，列为下一批）。

### 逐用例日志检查（新增能力）

每个用例执行后自动抓取 3 CN + 5 DN 在该用例时间窗内的 `ERROR`/`WARN`，写入 `<CASE>.logwin.txt`；
噪声白名单过滤后仍有非噪声行时，`results.tsv` 的 detail 列会带 `LOG{err=N warn=N unexp=N}`，
可直接定位产生异常日志的用例。

## 十二、第二批自测缺口用例（LB-181 ~ LB-197）

补齐自测文档剩余细粒度场景（17 条，其中 2 条因语法不支持 SKIP）：

| 用例 | 对应自测 | 内容 |
| --- | --- | --- |
| LB-181 | C-24 | 无 SECURITY 用户 / 不存在对象的 COMMENT 被拒 |
| LB-182 | L-21 | 括号不配对、嵌套、冒号跨组件、越界元素、同组件重复 |
| LB-183 / LB-184 | R-12 / R-13 | SET / TREE 维度空值三态 |
| LB-185 | R-21 / R-22 | 多角色 + 两个策略的 USE/IGNORE 混合生效范围 |
| LB-186 | E-01 | 六条内置规则 + WRITEARRAY 两个方向逐一 GRANT/REVOKE |
| LB-187 | E-03~E-05 | WRITE_UP / WRITE_DOWN 方向语义 |
| LB-188 / LB-189 | E-09~E-12 | SET / TREE 维度读写豁免 |
| LB-190 | E-14 | 策略级豁免不跨策略 |
| LB-191 | E-16 / E-17 | 多规则叠加后逐步撤销；非法规则+方向组合 |
| LB-192 | M-07 | 8 并发创建同名组件，仅 1 个成功 |
| LB-193 | M-08 | 必失败操作后原访问与元数据不受影响 |
| LB-194 | G-17 | SECURITY 主体与普通用户对 access 表的可见范围 |
| LB-195 | G-18 | 两个策略下同名标签互不串用 |
| LB-196 / LB-197 | L-03 / L-05 / R-09 / R-10 | SET / TREE 多值标签（写法 `COMPONENT c 'A', 'B'`，实测支持） |

### 语法差异更正（2026-11-17）

先前判定“不支持多值”有误：上述三种写法均非需求语法。需求 L634 的正确写法是
`COMPONENT c 'A', 'B'`（逗号后直接跟值），实测 SET/TREE 多值均创建成功，`label_value` 形如 `(QA,RD)`、`(RND,STORAGE)`。
易混淆点：组件之间与组件内多值都用逗号，区别在逗号后是否出现 `COMPONENT` 关键字。
