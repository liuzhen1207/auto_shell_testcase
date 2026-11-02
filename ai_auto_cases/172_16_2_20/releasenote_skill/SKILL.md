# SKILL — RN 验证方法与接口矩阵

## 1. 判定 RN 类型

- **缺陷修复型**：旧版复现 → 新版同路径对照。
- **新功能型**：按功能设计正/反向用例，不硬凑旧版行为。本次 TDB-65 属此类。

类型判定依据：RN 动作语义（新增/支持 vs 修复）、旧版是否已有该能力、变更性质（见 timechodb-rn-verify `references/rn-type.md`）。

## 2. 源码层核对（必做）

1. 从 RN 描述取 commit，`git show --stat <commit>` 区分生产代码与测试代码。
2. 读关键实现文件，提炼**用户可见契约**：列数、列名、取值、优先级、持久化语义。
3. 把契约写成可断言的检查项，再进入运行时验证——不要先跑再看。

本次 TDB-65 提炼出的契约：

| 语句 | 无原因时列数 | 有原因时列数 | 末列 |
| --- | ---: | ---: | --- |
| `SHOW CLUSTER` | 8 | 9 | `StatusReason` |
| `SHOW CLUSTER DETAILS` | 14 | 15 | `StatusReason` |
| `SHOW DATANODES` | 6 | 7 | `StatusReason` |
| `SHOW CONFIGNODES` | 5 | 5（恒不变） | — |

## 3. 接口 × 方言矩阵

**必备维度**：接口（CLI / Java Session / JDBC / REST / Python / Go / C++）× 方言（树 / 表）× 状态（无原因 / 有原因 / 恢复后）。

- Java Session / JDBC 可直接用发行包 `lib/*` 编译取证程序（`java/SessionShow.java`、`java/JdbcShow.java`），无需额外依赖。
- REST 需要发行包内含 `org.apache.iotdb.rest.RestService`；缺失时启用 `enable_rest_service=true` 会让 DataNode **启动失败**（`ClassNotFoundException`），务必先确认再改配置。
- Python / Go / C++ 需要对应运行时（python3 + apache-iotdb / go ≥1.19 + iotdb-client-go / g++ + thrift + boost）；缺失时在报告 §9 明确写"未覆盖 + 原因"，不要用其他接口代替。

## 4. 状态类 RN 的额外交付

节点状态、原因、持久化这类 RN 必须额外验证：

1. **持久化**：kill CN leader → 等新 leader → 状态与原因仍在；CN 重启后仍在。
2. **清理**：`SET SYSTEM TO RUNNING ON CLUSTER` 清除；单节点重启后该节点清除。
3. **展示语义**：状态列与原因列必须分离，不能合并成 `ReadOnly(Manual)` 这种形式（会破坏老客户端按列取值）。
4. **列数兼容**：无原因时必须回到基线列数，避免老客户端解析错位。

## 5. 取证与回填

- 证据目录：`/data2/iotdb/rc10_matrix/rn_verify/<RN>/evidence/`，每组一条原始输出文件。
- 报告：按 timechodb-rn-verify 模板，§8.1 用例结果表逐条给"实际结果 + 证据文件名"。
- PLM 回填：`plm_ops.py report` 先 dry-run 再 `--apply`，然后 `plm_ops.py verify --result 通过|不通过 --verification-rc <RC>`；写后 `rn get` 回查三个字段。
- 只在结论明确为通过/不通过时回填；部分通过/无法验证只落报告。
