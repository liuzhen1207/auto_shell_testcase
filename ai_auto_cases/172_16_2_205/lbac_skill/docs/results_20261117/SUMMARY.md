# LBAC 双模式回归结果（197 条，SR3/DR2，2026-11-17）

| 项目 | 内容 |
| --- | --- |
| 需求 | TDB-415 LBAC |
| 版本 | 2.0.13.1 / `83183d0`（RC2） |
| 集群 | 3 CN + 5 DN；**Schema 3 副本 / Data 2 副本**；DataRegion = IoTConsensus V1 |
| 用例 | **197 条**（141 基础 + 37 按研发自测文档扩展 + 19 早期补充） |
| 覆盖 | 研发自测 139 条已全部对齐（详见 `docs/selftest_coverage.md`） |

## 一、结果总览

| 模式 | 用例 | PASS | FAIL | SKIP |
| --- | ---: | ---: | ---: | ---: |
| 普通模式 | 197 | **187** | **0** | 10 |
| 三权分立 | 197 | **188** | **0** | 9 |

**唯一差异：LB-157**（普通模式 SKIP、三权分立 PASS，属设计内条件用例）。

## 二、SKIP 明细（9 条，两模式一致 + LB-157 条件项）

| 用例 | 原因 | 类别 |
| --- | --- | --- |
| LB-109 / LB-122 | 可写视图源为树模型（`VIEW FROM TREE`），不做 LBAC 保护（已确认） | 不适用 |
| LB-143 | TAG / TIME 列是否允许 `SECURED WITH` | 待需求确认 |
| LB-154 | 由 LB-177 覆盖（READ=高标签 + WRITE=低标签） | 替代 |
| LB-158 / LB-159 / LB-160 | 导出（EXPORT）/ pipe / LOAD 是否在 LBAC 检查范围 | 待需求确认 |
| LB-144 / LB-146 | 表模型不支持 `RENAME TABLE` / `CREATE TABLE AS SELECT` / `LIKE` | 语法不支持 |
| LB-157 | 仅三权分立执行（普通模式 SKIP） | 条件项 |

## 三、本轮修正（相对上一版 160 条）

| 项 | 变更 |
| --- | --- |
| 新增 17 条（LB-181~197） | 备注权限、歧义值、SET/TREE 空值三态、多角色多策略、六规则豁免、WRITE_UP/DOWN、SET/TREE 豁免、策略级豁免、多规则撤销、并发 DDL、活跃会话、access 表可见性、跨策略同名标签、**SET/TREE 多值标签** |
| LB-196（SET 多值） | 对象 `(RD,QA)`：用户 `RD` **拒**、用户 `(RD,QA)` **允**（要求覆盖全部） |
| LB-197（TREE 多值） | 对象 `(RND,STORAGE)`：`RND` **允**、`SUPPORT` **拒**、`COMPANY` **允**（任一值命中即放行） |
| LB-164 | 补 TREE 省略位置子句 → **2410**（与 ARRAY 一致） |
| LB-165/166/179/185/186/188/190/195 | 修正测试侧问题（元素表字段名、豁免统计、protect 策略传递、多策略表权限、三组件策略） |

## 四、语义确认（写入用例与文档）

| 项 | 实测结论 |
| --- | --- |
| ARRAY / TREE `ADD ELEMENT` 位置子句 | **必须**指定，省略报 2410；SET 不接受位置子句 |
| SET 多值标签比较 | 用户集合必须**覆盖**对象集合（不覆盖即拒） |
| TREE 多值标签比较 | **任一值命中**（相等或祖先）即放行；与 SET 语义不同 |
| 多值标签语法 | `COMPONENT c 'A', 'B'`（同一 COMPONENT 后逗号分隔，逗号后不带 COMPONENT 关键字） |
| 多值 `label_value` 展示 | 规范化重排，如输入 `'RD','QA'` 展示 `(QA,RD)` |
| 豁免 `GRANT ... ALL`（ARRAY 单组件策略） | 展开 3 行：`LBACREADARRAY` + `LBACWRITEARRAY` ×2（两条字段完全相同，方向未落库，待研发确认） |
| `LBACWRITEARRAY` 豁免 | 必须带方向：`WRITE_UP` / `WRITE_DOWN`；`LBACREADARRAY WRITE_UP` 语法非法（700） |

## 五、日志检查（CN/DN ERROR + WARN）

| 模式 | 总行 | ERROR | WARN |
| --- | ---: | ---: | ---: |
| 普通模式 | 440 | 5 | 435 |
| 三权分立 | 466 | 1 | 465 |

ERROR 全部落在 **HA 用例的节点重启窗口**：

| 模式 | 时间 | 内容 | 对应用例 |
| --- | --- | --- | --- |
| 普通 | 20:25:32、20:33:11 | `CHANGE_REGION_LEADER` 超时、`[LeaderBalancer] Failed to change the leader`、`TransferLeaderRPC`、`INVALIDATE_LAST_CACHE` | LB-132/133（CN/DN 重启） |
| 三权分立 | 23:16:44 | `INVALIDATE_LAST_CACHE` | LB-138/139（DN 重启） |

**逐用例日志窗口**（本次新增能力）：每个用例执行后抓取 3 CN + 5 DN 该时间窗内的 ERROR/WARN，噪声白名单过滤后若仍有非噪声行，会在 `results.tsv` 的 detail 写 `LOG{err=.. warn=.. unexp=..}`。本轮 **197 条无一带 `LOG{}` 标记**，即没有用例级不符合预期的 ERROR/WARN。

## 六、与上一版（160 条，IoTConsensus）对比

| 版本 | 用例 | 普通 | 三权分立 |
| --- | ---: | --- | --- |
| 2026-11-13（SR3/DR2） | 160 | 150 PASS / 0 FAIL / 10 SKIP | 151 PASS / 0 FAIL / 9 SKIP |
| 2026-11-17（SR3/DR2） | **197** | **187 PASS / 0 FAIL / 10 SKIP** | **188 PASS / 0 FAIL / 9 SKIP** |

新增 37 条后仍保持 **0 FAIL**，无回归。

## 七、遗留待确认（4 项）

1. TAG / TIME 列是否允许 LBAC 保护（LB-143）；
2. 导出（EXPORT）/ pipe / LOAD 是否纳入 LBAC 检查范围（LB-158/159/160）；
3. `GRANT EXEMPTION ALL` 中 `LBACWRITEARRAY` 两行字段完全相同（方向未落库）是否预期；
4. 多值 `label_value` 的展示顺序是否应有稳定规则（当前按字典序重排）。

## 八、文件

| 文件 | 内容 |
| --- | --- |
| `f1.md` / `f2.md` | 普通 / 三权分立报告 |
| `f3.md` | 双模式逐条对比（差异仅 LB-157） |
| `f1.tsv` / `f2.tsv` | 逐条结果（197 行） |
| `f1.log` / `f2.log` | CN/DN 日志窗口汇总 |
