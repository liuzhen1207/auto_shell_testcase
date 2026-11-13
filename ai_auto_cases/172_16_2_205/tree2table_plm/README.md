# 树转表用例 → TimechoPLM 导入归档（2026-11-13）

| 项 | 值 |
| --- | --- |
| 导入时间 | 2026-11-13 |
| 工具 | `timecho-plm-testcase-import@1.4.1`（SkillHub） |
| 产品 | TimechoDB（productId=1） |
| 功能点 | `存储/元数据管理/视图/树转表视图`（featureId=1621，叶子） |
| 用例数 | **137**（releasenote TDB-343 组 70 + tree_view 专项 67） |
| PLM 编号 | `TimechoDB-10687` ~ `TimechoDB-10823`（连续、无重复） |
| 关联 RN | **TDB-343**「树转表视图增加自动识别树模型新增测点的方式」（RN id=822，seq 343，迭代 V2.0.13.1） |
| RN 关联后总数 | 183 条（原有 46 + 本次 137，移除 0） |
| 模型 / 执行方式 | 表模型 / 自动 `shell` |
| 负责人 | 刘珍 |
| 测试类型分布 | 功能测试 80 / 异常测试 28 / 稳定性测试 25 / 安全性测试 4 |
| 用例级别分布 | P1 98 / P2 39 |

## 文件说明

| 文件 | 内容 |
| --- | --- |
| `case_id_mapping.csv` | **编号对应表**：自动化用例 ID（RN-139…RN-208 / TV-001…TV-097）↔ PLM 编号（TimechoDB-10687…10823），含名称、类型、级别、自动化类型、模型、功能点、RN |
| `source_cases.csv` | 导入源文件（17 列模板格式，编号列已由 apply 回填） |
| `rn_mapping.snapshot.json` | RN 关联快照：RN seq:343 的期望全集（原 46 + 新 137），用于幂等复核 |

## 用例来源

- `releasenote_skill/cases.tsv` 中 `TDB-343` 相关 70 条（RN-139 ~ RN-208）：视图创建扫描、INSERT/建序列补列、类型兼容、触发器与 restrict、幂等去重、DDL、并发、故障注入、多级存储、权限、特殊命名
- `tree_view_skill/cases.tsv` 全部 67 条（TV-001 ~ TV-097）：属性与语法、补列入口、冲突、查询开关、DDL 生命周期、HA、隔离、改名、LOAD/负载

## 复现（幂等）

```bash
# 环境：TIMECHO_PLM_BASE_URL / TIMECHO_PLM_TOKEN（READ_WRITE PAT）
cd <skill>/scripts
python convert_case_library.py --input source_cases.csv \
  --product-name TimechoDB --product-id 1 --auto-types shell --out-dir ../converted
python test_case_import.py plan  --input ../converted/cases.csv --mode create-only \
  --rn-mapping rn_mapping.snapshot.json
python test_case_import.py apply --input ../converted/cases.csv --mode create-only \
  --rn-mapping rn_mapping.snapshot.json --confirm-write
python test_case_import.py rn-link plan   --mapping rn_mapping.snapshot.json --backfill-check ../converted/cases.numbered.csv
python test_case_import.py rn-link apply  --mapping rn_mapping.snapshot.json --backfill-check ../converted/cases.numbered.csv --confirm-write
python test_case_import.py rn-link verify --mapping rn_mapping.snapshot.json
```

重跑同一输入会自动跳过已建用例（按 `cases.numbered.csv` 回填编号），不会重复导入。

## 两个执行注意点

> 已于 2026-11-13 通过 `POST /api/pub/skills/timecho-plm-testcase-import/feedback`（type=dislike）向 SkillHub 反馈上述第 1、2 条问题，均返回 `{"code":0,"message":"OK"}`。

1. **1.4.1 的 `convert_case_library.py` 缺 `import re`**，任何输入都会在 `build_feature_paths()` 抛 `NameError: name 're' is not defined`。本机已补 `import re`（仅本地修复，未改版本号）；重新安装 1.4.1 会覆盖，需要再补或等官方修复。
2. **RN 关联是"期望全集"语义**：mapping 里没列出的该 RN 既有用例会被**移除**。首次 plan 显示"移除 46"（原 TDB-343 用例），因此已把原 46 条并入期望集合，最终 `新增 137 / 移除 0`。
3. 导入途中出现过 1 次 `HTTP 502`（nginx 网关瞬断），工具幂等重跑后补齐；最终 137/137、0 失败。

## 校验结果

- `plan` 复跑：`新建 0 / 更新 0 / 跳过 137 / 错误 0`
- `rn-link verify`：`ok: true`，`mismatches: []`
- RN 343 版本推进到 3（`modifiedAt 2026-11-13T09:32:03`）
