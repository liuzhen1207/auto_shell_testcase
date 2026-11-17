> 全部 skill 用例清单（回归前先看）：[`ai_auto_cases/SKILL-INDEX.md`](../../SKILL-INDEX.md)

# releasenote_skill — 各版本 Release Note（RN）验证回归

按**版本 → RN** 两级组织，每个版本一个目录，每个 RN 一个用例目录，内含报告、脚本与关键证据。
与同级 `delete_skill/` 并列：delete_skill 是功能专项回归，本目录是**发版 RN 逐条验证**。

> 新版本包部署与激活（含身份继承的坑）：见 [`../docs/package-deploy-activation.md`](../docs/package-deploy-activation.md)

## 目录结构

```
releasenote_skill/
  README.md                 本文件
  SKILL.md                  验证方法与接口矩阵
  cases.tsv                 RN 验证矩阵（版本 / RN / 结论 / 文档链接）
  versions/
    v2.0.13.1/
      README.md             该版本已验 RN 汇总
      TDB-65/
        README.md           任务记录（环境、步骤、阻塞项）
        release_note_test_report.md   正式报告（与 PLM 文档一致）
        scripts/run_matrix.sh         接口 × 方言 × 状态矩阵脚本
        java/SessionShow.java         Java Session 客户端取证程序
        java/JdbcShow.java            JDBC 客户端取证程序
        evidence/                     关键原始输出（全量证据留在测试机）
```

## 已覆盖版本

| 版本 | BuildInfo | 已验 RN | 结论 |
| --- | --- | --- | --- |
| 2.0.13.1 RC1 | `ab6d3de` | TDB-65 | 通过 |

## 新增一个 RN 的步骤

1. 建 `versions/<版本>/<RN-ID>/`，复制上一版的 `scripts/` 与 `java/` 复用。
2. 按 `SKILL.md` 的接口矩阵取证，证据落 `evidence/`（关键文件入库，全量留测试机）。
3. 写 `release_note_test_report.md`（模板见 timechodb-rn-verify 技能）。
4. 回填 PLM：文档 + 验证结果 + 验证RC。
5. 在 `cases.tsv` 与版本 `README.md` 追加一行。

## 约定

- 报告与 PLM 文档内容必须一致；PLM 文档链接记进 `cases.tsv`。
- 不提交大体积运行产物（`*.log`、完整 `evidence/` 全量、jar/zip）；关键输出按上面示例保留。
- 每个 RN 目录的 `README.md` 要写清：环境、版本身份核对结果、**本轮未覆盖的接口及原因**，便于下轮补测。
## v2.0.13.1 已验 RN

| RN | 类型 | 验证版本 | 结果 | 报告 |
| --- | --- | --- | --- | --- |
| TDB-65 | 新功能（集群节点 ReadOnly 可观测性） | RC1 b6d3de | 通过 | [TDB-65](versions/v2.0.13.1/TDB-65/README.md) |
| TDB-1104 | 代码优化（空 DataRegion 缩容 Adding 时 load snapshot 空指针） | RC2 83183d0 | 通过 | [TDB-1104](versions/v2.0.13.1/TDB-1104/README.md) |
## v2.0.11.1 已验 RN（批量）

| 项 | 内容 |
| --- | --- |
| RN 总数 | 147（可测 117 / 环境不满足 30） |
| 用例 | [RN-2.0.11.1-SMOKE](versions/v2.0.11.1/RN-SMOKE.md) |
| 覆盖主题 | 配置热加载、CLI、查询引擎、COPY TO TsFile、迁移取消 |
| 结果 | 14 项检查全部 PASS（RC2 83183d0） |
| 目录 | [RN-CATALOG.md](versions/v2.0.11.1/RN-CATALOG.md) |
| 逐条结论 | [RN-RESULT.md](versions/v2.0.11.1/RN-RESULT.md) |
