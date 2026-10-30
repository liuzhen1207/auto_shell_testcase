# CRUD skill（设计稿）

- 用例矩阵：`cases/crud_cases.tsv`（75 条，格式 `优先级 用例ID 模型 领域 标题`，空白分隔，与 TTL skill 一致）
- 配置：`conf/crud.rc5.conf`（默认指向 RC5：`/data/deepseek/testdb/v20121rc5_1003/timechodb-2.0.12.1-bin.zip`，提交 `aaf460d`）、`conf/nodes.conf`
- 设计说明与移植计划：`references/design-notes.md`
- 现状：75 条用例已实机执行（RC5 74 条 PASS）；新增 `crud_schema_region_group_bootstrap_restart`（RATIS-2661 / TDB-372 建组窗口 kill -9）已在 2.0.13.1 RC1 PASS、2.0.10.2 FAIL

快速查看用例：`awk '{print $1"\t"$2"\t"$3"\t"$4}' cases/crud_cases.tsv | column -t`
