# 族模块编写规范（cases_*.py）

你要实现的是**一个族模块文件**：`scripts/pgkit/cases_<族>.py`，暴露 `SPECS: list[CaseSpec]`。
集成由主 agent 完成（主 agent 会在 `cases.py` 底部 `from . import cases_<族>` 并汇入注册表）。
**只写你自己的文件**；`cases.py`/`pgapi.py`/`cli.py`/`conf/*` 一律不要改（会被主 agent 覆盖）。

## 0 先读什么（必须按顺序读）

1. `references/proactive-spec.md` —— **判定口径唯一来源**（组数公式、上限公式、触发条件、重平衡、Disabled 补组、纪律）。
2. `references/case-catalog.md` —— 你负责族的**逐条用例与期望**。
3. `references/proactive-knobs.md` —— 旋钮、可观测量（SQL）、环境事实（无独立 SSD、权限、benchmark）。
4. `scripts/pgkit/cases.py` —— 既有 helper 与**已实现的 14 条用例**（照它的风格写）。
5. `scripts/pgkit/pgapi.py` —— `PgApi` 的全部可观测接口（组观测、库级详情、设备映射、策略、权限、benchmark）。

## 1 模块骨架（复制即可）

```python
"""PG-<族> 用例族：<一句话覆盖的需求点>。

依据：references/case-catalog.md 的 <族> 段；判定口径见 references/proactive-spec.md。
"""

from __future__ import annotations

from .cases import (
    CaseSpec, Ctx, PASS, FAIL, SKIP, INVALID,
    db_of, device_set, dialect_of, ensure_write_table, ensure_write_tree, expect_cap,
    expect_groups, expected_cap, group_counts, reset_db, write_devices,
)

SPECS: list[CaseSpec] = []


def case_xxx(ctx: Ctx) -> None:
    ...


SPECS.append(CaseSpec("PG-XXX-01", "<族名>", "tree", "<标题>", "P0", case_xxx))
```

`CaseSpec(case_id, area, model, title, priority, fn, gate=False, needs_restart=False, note="")`。
`model` 取值：`tree` / `table` / `tree+table` / `both`。`gate=True` 只给"族内最关键"的用例。

## 2 可用的 helper（都在 `cases.py`，不要重复实现）

| helper | 语义 |
| --- | --- |
| `reset_db(ctx, model, db="")` | drop+create 测试库（自动开归因窗口），返回库名 |
| `ensure_write_tree(ctx, db, device, stamp=1, sensors=("s0","s1","s2"), values=None)` | 树模型写一行（insert 自动建序列） |
| `ensure_write_table(ctx, db, table, tag, stamp=1, fields=1, values=None)` | 表模型建表（幂等）+ 写一行 |
| `device_set(ctx, db, count, dialect="tree", prefix="pgd", table="tb")` | **恰好 count 个不同 slot** 的设备名/TAG（树/表各自口径的 BKDR131） |
| `write_devices(ctx, db, devices, model="tree", stamp=1, table="tb", batch=False)` | 逐个写入设备 |
| `expect_groups(ctx, label, db, dialect, schema=None, data=None)` | **组数断言**：`SHOW DATABASES DETAILS` 计数与 `SHOW REGIONS` 去重都必须等于期望；自动写证据 |
| `expected_cap(ctx, kind, dialect, db)` | 按源码公式算该库该类型上限（`min`、参与分摊库数、副本数都按真实 conf/集群计算） |
| `expect_cap(ctx, label, db, dialect)` | 断言观测到的 `Max*RegionGroupNum` 等于公式值 |
| `group_counts(ctx, db, dialect)` | 返回 `(schema详情, schema去重, data详情, data去重)` |

`ctx` 上可用：`ctx.cfg`（conf 读取：`raw/get_int`）、`ctx.api`（`PgApi`）、`ctx.props`（conf 文件读写）、
`ctx.cluster`、`ctx.ssh`、`ctx.check(name, ok, detail, evidence)`、`ctx.req(outcome)`、
`ctx.skip(reason)`、`ctx.invalidate(reason)`、`ctx.note(text)`、`ctx.mark_harness_action(reason, pad=15)`、
`ctx.add_query(name, sql, dialect)`（登记到收尾②的副本一致性对拍）。

`PgApi` 常用方法：`db_group_num/db_max_group_num/database_details/db_time_partition_interval`、
`groups/snapshot/slot_counts/statuses/group_count/group_ids/replica_count`、
`device_group/device_region_id/timeslot_count`、`set_config/set_config_raw/set_config_on_node`、
`policies_on_disk(props)`、`create_user/drop_user/grant_system/grant_write/grant_all`、
`create_database/drop_database/create_timeseries/create_table/show_tables/count_rows`、
`insert_tree/insert_tree_many/insert_table/insert_table_rows/insert_table_many`、
`bench_run(...)`、`run(statement, dialect=..., user=..., password=...)`、`run_as(user, password, stmt)`。

## 3 硬性纪律（违反即视为无效用例）

1. **期望值只能来自 spec 的公式**：组数一律写成 `min(K, expected_cap(...))` 形态，
   **不要**写"设备数"或依赖环境（region 物理放置、DataNode 编号、设备与组号的对应关系）。
2. **不预建**：空库必须断言 `schema=0, data=0`；写入才增长。
3. **cluster 级参数不匹配就 SKIP**：`series_slot_num`、`time_partition_interval`、
   `data_partition_allocation_strategy`、副本数只能重启生效。用例开头读 `ctx.cfg` 校验，
   **不匹配时 `ctx.skip("本轮 PG_XXX=... 不满足本用例要求的 <值>；请用 conf/<档位> 运行")` 并 return**。
   绝不"降级断言后判 PASS"。策略键（`*_region_group_extension_policy`、最小组数、每节点配额）
   **可以热加载**（`ctx.api.set_config(...)`），但切完要读回自证。
4. **故意制造错误**的语句（非法值、无权限、`ON <nodeId>`）之前必须
   `ctx.mark_harness_action("...")` 开归因窗口，否则收尾③会把预期的报错当"非预期异常"。
5. **禁止全局白名单式断言**：不得写"只要不抛异常就算过"；每条 check 必须有明确期望值。
6. 收尾三件套由 runner 自动追加，用例**不要**自己实现；但每例要保证结束时集群可用
   （若你停了节点，必须在用例结束前恢复，并把它写进 `ctx.by_design_gone` 配合 sync 门禁）。
7. 大规模写入（≥10 万测点）用 `ctx.api.bench_run(...)`（在客户端机跑），
   前置不成立（`PG_BENCH_SSH` 未配置、包缺失）时 SKIP 并写明原因。
8. 每个用例最多 ~60 行；重复逻辑抽成模块内私有函数。

## 4 自检（必须做，并把结果写进你的报告）

```bash
cd <skill>/scripts
python3 -c "import ast,pathlib;ast.parse(pathlib.Path('pgkit/cases_<族>.py').read_text());print('syntax ok')"
python3 - <<'PY'
from pgkit import cases
from pgkit.cases_<族> import SPECS
ids=[s.case_id for s in SPECS]
assert len(ids)==len(set(ids)), "case_id 重复"
assert all(i.startswith("PG-") for i in ids)
print(len(ids), "cases:", ids)
PY
```

另外用 `bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf selftest` 确认既有自检仍然全绿
（它不检查你的文件，但能确认你没破坏包结构）。

## 5 报告格式（给主 agent）

* 文件路径与用例条数；
* 用例 id 列表与对应需求点；
* 每条用例的"期望值来源"（公式 or 观测）；
* 需要特殊档位（cluster 级 conf）才能跑的用例清单与原因；
* 你**没能**覆盖的目录条目（如有）与原因（不要静默跳过）；
* 自检命令的实际输出。
