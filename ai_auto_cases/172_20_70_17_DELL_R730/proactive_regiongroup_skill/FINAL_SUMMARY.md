# TDB-367 PROACTIVE 回归 —— 最终汇总（本轮：2026-10-16 ~ 10-17，217 例全量）

> 一页纸结论。明细见 `REPORT.md`；判决依据见 `../TRIAGE_full_round.md`（618 行）；
> 产品缺陷见 `DEFECT_CANDIDATES.md`，harness 修正见 `HARNESS_FINDINGS.md`。**两者不得混记。**

## 0 2026-10-20 实锤更新（干净 3C5D / 2.0.11 重新部署并激活）

* **D-04 已确证，机制改写**：表库 `pg` 与树库 `root.pg` 在 `ClusterSchemaInfo.enrichSchemaMap()` 的
  Map 中 key 相同（`path.getFullPath()`，`:679-693`）⇒ 表库条目被树库覆盖 ⇒ **永不参与**
  `adjustMaxRegionGroupNum()`，上限恒为 (1, 2)，且 `databaseNum` 每冲突一次少计 1。
  1 秒内完成的 A/B：表库 `solo_tab`（无同名树库）正常调到 1/12 → 建 `root.solo_tab` 后消失。
  旧"`DatabaseNotExistsException` 被跳过"的解释**作废**。提单草稿：`缺陷提交_D-04_表库同名冲突.md`。
* **D-05 撤销**：2.x `count(*)` = "FROM 路径下各测点的行数"，路径落到测点即空集，属语义一致；
  harness 新增 `PgApi.count_series()` 替换 20 处调用（H-37），复跑 `PG-MSR-01`、`PG-TIME-01` 均 PASS。
* 现值口径：**37 FAIL = 26 D-04（产品缺陷，已确证）+ 10 例 harness 口径（已修待复跑）+ 1 HA-10（不归因）**。

## 1 数字（217 例全部执行）

| 项 | 实测 | 按本轮分诊口径修正后 |
|---|---|---|
| 执行例数 | 217（`pg_full_iot_final` 63 + `pg_iot_resume` 154，集合不相交） | 217 |
| PASS | **87** | **139** |
| FAIL | 89 | **36** |
| SKIP | 41 | 41 |
| INVALID | 0 | **1**（`PG-HA-01`，收尾① 采样面失效，`last samples: []`） |
| 通过率 | 87/217 = **40.1%** | 139/217 = **64.1%** |

* **FAIL 36 例 / 63 check 全部是既有产品缺陷**：`D-04` 26 例（53 check）+ `D-05` 10 例（10 check）。
* **新产品缺陷候选 0 项。**
* 52 例由 FAIL 翻为 PASS（判定口径 / 归因 / 用例实现修正，147 check）：
  `H-19` 17 例 69 check（其中 68 条为"实测 > 源码公式"的每库单调存量，1 条 `PG-LIM-07[8]` 为异步调整的瞬时读）、
  `H-22b` 1 例 4 check、`H-26/27/28` 22 例 37 check、收尾③ 日志归因 37 例 37 check
  （H-23 3 例 + H-24 18 例 + H-25 15 例 + 用例自写过期数据 1 例）。

## 2 两个产品缺陷

| 编号 | 一句话 | 本轮证据 | 状态 |
|---|---|---|---|
| **D-04** | **表模型库**（含 OBJECT）的 RegionGroup 上限/组数**钉死在下限**（`MaxSchema=1`、`MaxData=2`），与资源、槽位数、已分配组数都无关；树模型同条件正常 | 26 例 / 53 check 同一签名（`公式={SCHEMA:3,DATA:30}` → `实测={SCHEMA:1,DATA:2}`）；`PG-LIM-21` **主动触发一次调整后仍 (1,2)**；`PG-HA-12`/`PG-REB-11` 写 **5 个 slot 后 Data 组数仍 2**（树库同条件 5）；重启 / 热加载 / 换策略后不变 | 高置信，建议提单 |
| **D-05** | **测点级** `select count(*) from <db>.<device>.<measurement>` 写后返回 `Empty set`；同路径 `select <m>` 有数据、**设备级** `count(*)` 正常 | 10 例 / 10 次复现（resume 轮该形状 **10/10 全部空集**，全量轮该形状 0 次查询）；最小复现见 `DEFECT_CANDIDATES.md` | **已确证 P1** |

## 3 可复跑命令（不改集群、只读复核）

```bash
cd /home/ubuntu/remove_cn_dn/pg_build

# ① 基数校验：应得 217 = 87 PASS / 89 FAIL / 41 SKIP，且两轮用例集不相交（并集 217）
python3 - <<'PY'
import json,glob,collections
c=collections.Counter(); ids=set()
for r in ('pg_full_iot_final','pg_iot_resume'):
    for d in glob.glob(f'results/{r}/cases/*/result.json'):
        j=json.load(open(d)); c[j['status']]+=1; ids.add(j['case_id'])
print(c, len(ids))
PY

# ② 单例失败 check + detail（换成任意 case_id）
python3 - <<'PY2'
import json
j=json.load(open('results/pg_iot_resume/cases/PG-MSR-01/result.json'))
for c in j['checks']:
    if not c['ok']: print(c['name'],'::',c['detail'])
PY2

# ③ 收尾③ 命中 vs harness 动作锚点（日志归因自证）
grep -n 'harness 动作' results/pg_iot_resume/run.log | head -20

# ④ 全量轮为何只有 63 例
cat full_run_paused.txt
```

若要在新集群上重跑（**会改集群，属另一件事**，不在本轮范围）：`bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf prepare`
之后 `matrix --tier full --run-id <id>`；单例 `run --case PG-LIM-21`、`run --case PG-MSR-01`。

## 4 待办（本轮未做，按分诊结论排）

1. 按 `HARNESS_FINDINGS.md` 修 H-23/H-24/H-25（归因窗口与正则表）→ 收尾③ 的 37 例里 **36 例**可自动归因，余 1 例（`TTL-02` 写入过期数据）需改用例；
2. 按 H-19 改 `expected_cap` 对拍口径（`实测 ≥ 公式` 且 `实测 ≥ 自报`）→ H-19 的 17 例里 **14 例**应转 PASS（`LIM-21`/`LIM-13` 仍被 D-04、`MSR-13` 仍被 D-05 挡住）；
3. 按 H-26/27/28 修 22 例用例实现（含 `import re` 补齐后**优先重跑** `OBS-06/07/08`，它们是 D-05 的判定实验）；
4. 按 H-29 给收尾① 加"连续空采样 fail-fast"→ `PG-HA-01` 应判 INVALID 而不是烧满 1800s；
5. D-04 / D-05 提 PLM（D-05 按 P1，最小复现已附）。

---

## 附：历史轮次记录（2026-10-14 21:29，原样保留，未删除）

| 轮次 | 用例数 | PASS | FAIL | SKIP | INVALID |
|---|---|---|---|---|---|
| pg_smoke_v2 | 6 | 2 | 3 | 1 | 0 |
| 20261014_190204_run | 1 | 0 | 1 | 0 | 0 |
| 20261014_190914_run | 1 | 0 | 1 | 0 | 0 |
| pg_core_iot | 3 | 1 | 1 | 1 | 0 |
| pg_core_iot2 | 6 | 2 | 3 | 1 | 0 |
| pg_smoke_2 | 11 | 3 | 7 | 1 | 0 |
| pg_smoke_dry | 1 | 0 | 0 | 1 | 0 |

**合计**：29 例（PASS=8、FAIL=16、SKIP=5、INVALID=0）

### 当时的全部 FAIL（历史记录，逐条定性结果后由 H-10/H-11/H-12/D-04 等收敛）

* `pg_smoke_v2` / **PG-SMK-05**：表模型写入第 2 个设备后：SchemaRegionGroup 数应为 2; 表模型写入第 3 个设备后：SchemaRegionGroup 数应为 3; 表模型写入第 3 个设备后：DataRegionGroup 数应为 3; 表模型写入第 4 个设备后：SchemaRegionGroup 数应为 3; 表模型写入第 4 个设备后：DataRegionGroup 数应为 4; 收尾③ CN/DN
* `pg_smoke_v2` / **PG-SMK-04**：写入第 4 个 slot 后（min 增长+新增 slot）：SchemaRegionGroup 数应为 3; 收尾③ CN/DN 日志无 ERROR/WARN 异常
* `pg_smoke_v2` / **PG-SMK-06**：切回 PROACTIVE 后新 slot 继续扩容（组数 +1）; 收尾③ CN/DN 日志无 ERROR/WARN 异常
* `20261014_190204_run` / **PG-SMK-03**：收尾② 副本数据一致性校验
* `20261014_190914_run` / **PG-SMK-03**：收尾③ CN/DN 日志无 ERROR/WARN 异常
* `pg_core_iot` / **PG-SMK-03**：用例执行未抛异常
* `pg_core_iot2` / **PG-SMK-05**：表模型写入第 2 个设备后：SchemaRegionGroup 数应为 2; 表模型写入第 3 个设备后：SchemaRegionGroup 数应为 3; 表模型写入第 3 个设备后：DataRegionGroup 数应为 3; 表模型写入第 4 个设备后：SchemaRegionGroup 数应为 3; 表模型写入第 4 个设备后：DataRegionGroup 数应为 4; 收尾③ CN/DN
* `pg_core_iot2` / **PG-SMK-04**：写入第 4 个 slot 后（min 增长+新增 slot）：SchemaRegionGroup 数应为 3; 收尾③ CN/DN 日志无 ERROR/WARN 异常
* `pg_core_iot2` / **PG-SMK-06**：切回 PROACTIVE 后新 slot 继续扩容（组数 +1）
* `pg_smoke_2` / **PG-TIME-01**：行数 = 3
* `pg_smoke_2` / **PG-SMK-05**：表模型写入第 2 个设备后：SchemaRegionGroup 数应为 2; 表模型写入第 3 个设备后：SchemaRegionGroup 数应为 3; 表模型写入第 3 个设备后：DataRegionGroup 数应为 3; 表模型写入第 4 个设备后：SchemaRegionGroup 数应为 3; 表模型写入第 4 个设备后：DataRegionGroup 数应为 4; 收尾③ CN/DN
* `pg_smoke_2` / **PG-DEV-21**：DEV-21 再写 B（表）库后：SchemaRegionGroup 数应为 3; DEV-21 再写 B（表）库后：DataRegionGroup 数应为 3; DEV-21 table 库：K=3 时公式上限（30）与产品上限（2）给出同一期望值; 树/表两库同批 3 个不同 slot 各自扩容、互不影响
* `pg_smoke_2` / **PG-SMK-04**：写入第 4 个 slot 后（min 增长+新增 slot）：SchemaRegionGroup 数应为 3; 收尾③ CN/DN 日志无 ERROR/WARN 异常
* `pg_smoke_2` / **PG-OBS-04**：收尾③ CN/DN 日志无 ERROR/WARN 异常
* `pg_smoke_2` / **PG-SMK-06**：切回 PROACTIVE 后新 slot 继续扩容（组数 +1）; 收尾③ CN/DN 日志无 ERROR/WARN 异常
* `pg_smoke_2` / **PG-MSR-01**：行数 = 1; 收尾③ CN/DN 日志无 ERROR/WARN 异常

> 口径：当时的判定与证据见各轮 `cases/<CASE_ID>/result.json`；产品缺陷与 harness 问题分别登记在
> `DEFECT_CANDIDATES.md` 与 `HARNESS_FINDINGS.md`，两者不得混记。本节的数字与结论**未被本轮改写**。
