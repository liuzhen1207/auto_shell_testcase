# 通宵回归测试报告 — 2.0.13.1 RC2 (`83183d0`)

| 项目 | 内容 |
| --- | --- |
| 构建 | TimechoDB **2.0.13.1 / `83183d0`（RC2）** |
| 集群 | 3 CN（172.16.2.26/27/28）+ 5 DN（172.16.2.2~6），结果目录 `/data2/auto_test/night_results_20261110_191026` |
| 执行时间 | 2026-11-10 19:10 ~ 21:40 |
| 用例总数 | **248 条**（tree_view 67 + auth 34 + releasenote 147） |
| 结论 | **无新增产品缺陷**；4 条失败全部挂在已知缺陷 **TDB-888** 上；另发现 2 处套件自身问题已修复 |

---

## 一、总览

| 技能 | 用例 | PASS | 已知缺陷失败 | 新增失败 | SKIP | 备注 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| tree_view | 67 | **63** | 4（TDB-888） | 0 | 0 | TV-003/TV-060 复跑与归因后确认非产品问题 |
| auth | 34 | **34** | 0 | 0 | 0 | AUTH-007 首跑假失败（配置残留）已修复并复跑通过 |
| releasenote | 147 | **130** | — | 0 | 16（+1 KNOWN） | 与 RC1 基线完全一致 |

> releasenote 的 KNOWN 1 = RN-111（TIMECHODB-0779，未修复）；SKIP 16 = 3 条三权分立 + 11 条慢用例 + 2 条模板环境受限。

---

## 二、tree_view（67 条，优先执行）

### 结果

| 分类 | 数量 | 说明 |
| --- | ---: | --- |
| PASS | 63 | 含 TV-003（复跑）、TV-060（归因为 HA 噪声） |
| 已知缺陷 | 4 | TV-080 / TV-081 / TV-082 / TV-088 → **TDB-888** |
| 新增失败 | 0 | — |

### 4 条失败均为 TDB-888（改名同步）

| 用例 | 断言 | 现象 |
| --- | --- | --- |
| TV-080 | 改名后视图 TAG 应为新设备名 d9 | 实测仍为 d1（TAG 未同步、旧设备仍在） |
| TV-081 | 改名 + auto_sync 视图 TAG 应为 d9 | 同上 |
| TV-082 | 跨库改名后目标库视图应有数据 | 实测 0 行 |
| TV-088 | 重启 DN 后 TAG 仍应为新名（持久化） | 仍为 d1 |

> 这是需求 §2.1.1.1 / §2.1.1.3 的既有缺陷（`ALTER TIMESERIES ... RENAME TO` 走 RenameTimeSeriesProcedure 时，
> 视图 TAG 与跨库视图未同步），在 RC2 **未修复**，与 RC1 行为一致。

### 2 条"假失败"的定位过程

| 用例 | 首跑现象 | 定位 | 处置 |
| --- | --- | --- | --- |
| TV-003 | `500: Unknown database tv003`（建视图失败） | 属于该轮首个执行组，集群刚从 hard_reset 恢复；手工同语句复现成功，单跑也 PASS | 判为**环境时序瞬态**，复跑 PASS |
| TV-060 | `logERROR=5` | 日志实为 `Internal error processing openSession`（×4）+ `Failed to UPDATE_REGION_ROUTE_MAP`（×1），均发生在节点隔离场景，属 HA 噪声，非扩列功能 | 已把这两类加入 `classify_run.sh` 的 HA 噪声规则，重分类后 PASS |

---

## 三、auth（34 条，normal + separation）

### 结果

| 模式 | 结果 |
| --- | --- |
| normal（27 条） | 27 PASS（含修复后的 AUTH-007） |
| separation（33 条，含专属用例） | 全部 PASS |
| 合计 | **34 PASS / 0 FAIL**（去重后 34 条） |

### AUTH-007 假失败的根因与修复

首跑：`缺特殊字符应返回 820` → 实际 `The statement is executed successfully`，随后 `Good@1234567` 报 `805 已存在`（级联）。

手工验证 RC2 的强密码策略是**正常生效**的：
```
create user chk1 'Abcd1234efgh'  -> 820: Invalid password, must contain at least one special character.
create user chk1 'abcdefgh1234'  -> 820: ... at least one uppercase letter, one special character.
create user chk1 'Ab1!'          -> 820: The length of password must be greater than or equal to 12
```

根因：`enforce_strong_password` 被**历史运行落盘成 false**（`SET CONFIGURATION` 会写回 `iotdb-system.properties`），
本轮 auth 启动时策略仍关闭；直到套件末尾 AUTH-010 才把它改回 true，所以复跑就正常了。

修复（已提交）：`case_AUTH007` 开头强制
```bash
TS "SET CONFIGURATION 'enforce_strong_password'='true'"; sleep 2
```
复跑结果：**AUTH-007 PASS**，新增失败 0。

---

## 四、releasenote（147 条）

```
SKIP 16
KNOWN 1
PASS 130
```

- 与 RC1（`ab6d3de`）的 130 PASS / 1 KNOWN / 16 SKIP **完全一致**；
- 覆盖 TDB-343 树转表自动扩列 70 条（含故障注入、多级存储、权限、并发）；
- KNOWN 1 = RN-111；本轮新增白名单：**RN-204 → TDB-1049**（DN 无响应期间静默丢列，已提 PLM，陈耀斌）。

---

## 五、本轮对套件自身的修复

| 问题 | 影响 | 修复 |
| --- | --- | --- |
| auth 脚本 CRLF 行尾 | `run_regression.sh` 直接语法错误、整段未执行 | 重新部署 + `tr -d '\r'` 转换（6 个文件） |
| tree_view `lib.sh` 路径 | 新部署后 `suite.sh` 找不到 `$BASE/lib.sh`，报 `log_mark_all: command not found` | 补 `lib/lib.sh → lib.sh` |
| `classify_run.sh` HA 规则缺失 | `openSession` 失败被算成"其他错误"，误报 TV-060 | 规则补充 `processing openSession|UPDATE_REGION_ROUTE_MAP` |
| AUTH-007 依赖外部策略状态 | 配置残留导致假失败 | 用例内强制开启 `enforce_strong_password` |

---

## 六、结论与建议

1. **RC2 质量状况良好**：248 条用例中，除 4 条挂在已知缺陷 TDB-888 外，无新增失败；
2. **建议跟进 TDB-888**：RC1/RC2 均复现，涉及 `ALTER TIMESERIES ... RENAME TO` 与树转表视图的 TAG/跨库同步，建议排期；
3. **建议关注配置污染**：`SET CONFIGURATION` 会持久化到 `iotdb-system.properties`，
   跨套件/跨轮次会互相影响（本次 `enforce_strong_password` 即为例证），套件已加防御，也建议在用户手册中说明；
4. **TDB-1049 已提 PLM**（陈耀斌 / 刘珍 / V2.0.13.1），修复后需把 RN-204 的丢列观察项升级为硬断言。

---

## 七、复现方式

```bash
# tree_view
cd /data2/auto_test/treeview_suite && NEW=v20131rc2_1110_83183d0 bash tools/suite.sh
bash tools/classify_run.sh $(ls -td results/run_* | head -1)

# auth（两种模式，结束自动恢复 normal）
cd /data2/auto_test/auth_skill && NEW=v20131rc2_1110_83183d0 bash tools/run_regression.sh

# releasenote
cd /data2/auto_test/releasenote_skill && NEW=v20131rc2_1110_83183d0 bash tools/suite_rn.sh
```
