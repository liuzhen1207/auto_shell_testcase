# 审计日志类缺陷：本环境可行性结论

日期：2026-11-04
版本：TimechoDB 2.0.13.1 / `ab6d3de`（企业版构建）

## 结论

**当前构建未产生"操作审计"记录，审计类用例（TIMECHODB-0624/0625/0626/0627 等）在本环境无法自动化验证。**

## 实测证据

1. 在 CN/DN 的 `iotdb-system.properties` 写入 `enable_audit_log=true`，`hard_reset` 重启，集群 8/8 Running；
2. 执行若干 DDL/DCL 触发审计：`create database`、`create user`、`drop user`、`drop database`；
3. 查询 `root.__audit.**`：

```
root.__audit.password_history._0.password
root.__audit.password_history._0.oldPassword
```

**只有 `password_history`（口令历史）系列，没有任何 `operation_type / sql_string / result` 类操作审计序列。**

4. 配置模板中也查不到审计相关键：

```bash
grep -n "auditable\|enable_audit" conf/iotdb-system.properties.template   # 无输出
```

## 判断

- 操作审计（auditable_operation_type / auditable_operation_level）很可能是**安全包（安全版）或需要审计授权的构建**才启用；
- 企业版仅保留 `password_history`；
- 因此 0624（查询重复记录）、0625（DROP ROLE operation_type 应为 DDL）、0626（list user 审计缺失）、0627（无权限操作 result 应为 false）这类用例，**需要换构建再验证**。

## 已就绪的能力

`tools/mode.sh` 已支持审计开关（配置 + 重启）：

```bash
bash tools/mode.sh audit-on     # 写 enable_audit_log=true 并 hard_reset
bash tools/mode.sh audit-off    # 写回 false 并 hard_reset
```

一旦有支持操作审计的构建，直接写 `MODE_OF["RN-xxx"]="audit"` 的用例即可复用现有模式门控。

## 建议

1. 向研发确认"操作审计"在哪个包/授权下生效；
2. 若仅安全包支持，把审计类缺陷归到安全包专项回归，不进企业版 release 回归；
3. 本环境仍保留 `password_history` 相关能力（可验证口令历史记录，如 TIMECHODB-0632）。
