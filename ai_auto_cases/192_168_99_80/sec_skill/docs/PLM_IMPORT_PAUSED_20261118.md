# PLM 导入 & 验证暂停快照（2026-11-18 20:10）

## 一、暂停原因

用户指示：**PLM 平台资源异常，部分运行失败，暂停导入与验证**。
已停止：
- 自动驱动（`run_all_modules.ps1` / `run_module.ps1`）——已 kill，无残留；
- 正在执行的 `shell_case_import.py` 进程——0 个残留。

## 二、各模块台账现状

| 模块 | 台账条目 | passed | 未通过/待重跑 | 说明 |
| --- | --- | --- | --- | --- |
| sec_skill | 16 | 12 | 4（SEC-03/05/08/11，`runResult` 缺失） | 需重新验证这 4 条 |
| diskusage_skill | 5 | **5** | 0 | 已完成 |
| crud_skill | 15 | 10 | 5（CR-01/07/09/10/14） | CR-09 已确认是产品问题（TDB-1621）；CR-01 本地 3/3 PASS；CR-07 用例场景；CR-10 超时；CR-14 待重验 |
| metadata_skill | 13 | **4**（11123/11124/11125/11127） | 9 | 失败条目 `runTaskId` 缺失 ⇒ 提交/验证阶段失败 |
| ttl_skill | 8 | 0 | 8 | **全部 `runTaskId=None`、`runResult=failed`** ⇒ 平台提交失败 |
| wal_skill | — | — | — | 未开始 |
| compaction_skill | — | — | — | 未开始 |

## 三、关键判断：这批失败大多是**平台侧**，不是用例问题

`ttl_skill`/`metadata_skill` 的失败条目特征：
- `runTaskId` 为空、`runResult=failed`；
- 单条耗时极短（秒级），没有进入 CREATING/EXECUTING；
- 与之前记录的平台问题一致（P1 502、P2 CANCELLED、P3 队列/资源不足）。

⇒ **不能据此判定用例失败**；恢复后应重跑这些条目（台账会因重复导入而跳过"已 passed"，失败条目会重试）。

## 四、恢复后的继续方式（建议）

1. **小批量**：每次 1 个模块、最多 3–5 条，避免打满 3C3D 模板并发（`groupConcurrency=2`）；
2. **失败即停**：一旦出现连续 2 条 `runTaskId=None`，暂停并等平台恢复；
3. **优先补**：
   - sec_skill 的 SEC-03/05/08/11（重新验证，补齐 `runResult`）；
   - crud_skill 的 CR-14（重验）；CR-01 在 PVE 上重跑确认；
   - metadata 剩余 9 条、ttl 8 条、wal 27 条、compaction 52 条；
4. 恢复前先做一次探活：`GET /api/open/staff/me` + 提交一次轻量验证，确认不再 502/秒失败。

## 五、已完成（可作为交付基线）

| 模块 | 结果 |
| --- | --- |
| sec_skill | 16 条全部导入（TimechoDB-11006~11023），其中 12 条台账 passed，4 条待重验 |
| diskusage_skill | **5/5 passed**（11106/11107/11108/11109/11117） |
| crud_skill | 10/15 passed；CR-09 已在 PLM 记为 **TDB-1621（代码优化）** |
| metadata_skill | 4/13 VERIFIED（11123/11124/11125/11127） |
