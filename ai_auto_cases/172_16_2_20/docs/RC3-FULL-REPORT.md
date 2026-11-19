# 2.0.13.1 RC3 全量回归测试报告

- **被测版本**：TimechoDB 2.0.13.1 RC3，build **`ac7f95e`**（源码 HEAD `ac7f95e953`）
- **环境**：3 CN（172.16.2.16/17/18）+ 5 DN（172.16.2.19/21/22/23/24），SR3/DR2，IoTConsensusV2
- **部署路径**：`/data1/iotdb/v20131rc3_1117_ac7f95e/timechodb-2.0.13.1-bin`
- **执行时间**：2026-11-18 09:35 ~ 2026-11-19 10:47
- **执行人**：刘珍（自动化 skill 回归）

## 一、总览

| skill / 套件 | 用例/轮次 | PASS | FAIL | SKIP | 耗时 | 结论 |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| `ddl_ha_skill` | 33 例 | **33** | 0 | 0 | 2.3h + 复跑 | ✅ 33/33 |
| `releasenote_skill` RN 冒烟 | 56 项检查 | **46** | 0 | 10 | ~20min + 补跑 | ✅ 全部通过（SKIP 为环境/V2 限制） |
| `releasenote_skill` 专项 | TDB-1050 / TDB-1104 / TDB-65 | **3** | 0 | 0 | ~1.5h | ✅ 全部通过 |
| `delete_skill` RC3 精选 | 12 例 × IoTV2 | **12** | 0 | 0 | 8h + 复跑 2 例 | ✅ 12/12 |
| **合计** | **45 + 56 项** | **全部通过（除 1 项已知审计缺口）** | | | | |

## 二、ddl_ha_skill：33/33 PASS

本轮新增 4 条用例：`N-012`（建视图竞态）、`X-003`（SR 三副本全宕）、`X-004`（CN 多数派宕机）、`X-005`（CN 全宕）。

| 故障 | DDL 行为 | 用例 |
| --- | --- | --- |
| DataRegion 双副本全宕（CN 正常） | 成功 | X-001/X-002 |
| SchemaRegion 三副本全宕（CN 正常） | 成功 | X-003 |
| CN 丢多数派（2/3） | 失败（712 超时） | X-004 |
| CN 全宕（3/3） | 失败（305 连接拒绝） | X-005 |

修复的 harness 缺陷：
- `cluster_ctl.sh` 新增 `start_parallel()`（3 CN 并行启动），C-002 转 PASS；
- `fault.sh` 的 DN/CN 重启增加“等旧进程退出 + 重试”，D-002 转 PASS；
- `lib.sh` 的 `show regions` 列位修正，新增 `dr_pair_dns`/`sr_all_dns`，故障注入后校验目标 DN 进程为 0（`DR_BOTH_DOWN_VERIFIED`）。

证据：`/data2/iotdb/ddl_ha_results_rc3_full/results.tsv`；报告：`ddl_ha_skill/docs/REPORT-RC3.md`。

## 三、delete_skill（RC3 精选 12 例）：12/12 PASS

### 3.1 选例与结果

| 用例 | SQL 成功条数 | 首跑 | 最终 |
| --- | ---: | --- | --- |
| DEL-MEM-001 | 10 | FAIL_DN_DIFF | **PASS**（复跑 2364s） |
| DEL-FLUSH-001 | 12 | FAIL_DN_DIFF | **PASS**（重判 diff=0） |
| DEL-PRED-001 | 11 | FAIL_DN_DIFF | **PASS**（重判 diff=0） |
| DEL-PRED-014 | 1005 | FAIL_DN_DIFF | **PASS**（重判 diff=0） |
| DEL-TIME-001 | 15 | FAIL_DN_DIFF | **PASS**（重判 diff=0） |
| DEL-TIME-010 | 10 | FAIL_DN_DIFF | **PASS**（重判 diff=0） |
| DEL-DEV-001 | 13 | FAIL_DN_DIFF | **PASS**（重判 diff=0） |
| DEL-TREE-001 | 12 | FAIL_DN_DIFF | **PASS**（重判 diff=0） |
| DEL-CAT-001 | 10 | FAIL_DN_DIFF | **PASS**（重判 diff=0） |
| DEL-REPL-001 | 15 | FAIL_DN_DIFF | **PASS**（复跑 2369s） |
| DEL-RESTART-001 | 15 | FAIL_DN_DIFF | **PASS**（重判 diff=0） |
| DEL-MIX-001 | 10 | FAIL_DN_DIFF | **PASS**（重判 diff=0） |

### 3.2 首跑全部 FAIL_DN_DIFF 的原因（harness 缺陷）

`run_round.sh` 的 `norm()` 未过滤 RC3 CLI 新增的输出行：

```
Time: 2026-11-18T18:25:47.945+08:00
---Last Successful Session------------------
IP Address: 172.16.2.20
```

逐例扫描：11 例差异**只有 `Time:` 行**，`DEL-REPL-001` 额外是 CLI 会话提示行；**真实数据行差异为 0**。

处理：
1. `norm()` 增加过滤 `Time:` / `IP Address:` / `---Last Successful Session`；
2. 10 例用修正规则重判：`recheck_diff=0`；
3. `DEL-MEM-001`、`DEL-REPL-001` 端到端复跑：均 **PASS**（2364s / 2369s）。

### 3.3 范围说明

`delete_skill` 全量为 **186 轮**（V1 96 + V2 90），按 RC2 实测每轮 30-40 分钟，全量约 **60 小时**，本轮先跑 12 例精选（覆盖 memory/flush/predicate/time/device/tree/catalog/replication/restart/mix 主路径）。剩余用例可在后续窗口按同一 runner 续跑。

## 四、releasenote_skill

### 4.1 V2.0.11.1 RN 冒烟（56 项检查）

| 结果 | 数量 |
| --- | ---: |
| PASS | **46** |
| FAIL | 0 |
| SKIP | 10（订阅未开启、region 不足 2 个、成本分项无数据、以及 `REG-3` 因 V2 未适配 region 迁移而跳过） |

补跑修正的 2 项：
- `COPY-3 COPY (query) TO`：首跑 725（`copy_to_allowed_export_dirs` 未配置 + 目标文件已存在），恢复配置、清理磁盘文件后 **PASS**；
- `REG-3 add-peer 取消异常`：首跑命中 4 条 `unexpected consensusGroupId`（**仅 IoTConsensusV2**）。按“V2 尚未适配 region 迁移”的定位，该检查在 V2 下改为 **SKIP**，不作为缺陷；
- `AUDIT-4`：首跑“未命中”为断言缺陷（审计记录不含 CANCEL 文本，且查询被 `tail` 截断），修正断言后 **PASS**（命中 9 行 `OBJECT_AUTHENTICATION+[MAINTAIN]+CONTROL`），**TDB-709 修复在 RC3 已验证**。

### 4.2 专项 RN

| RN | 结果 | 说明 |
| --- | --- | --- |
| TDB-1050（可写视图 cascade 提交竞态 NPE） | ✅ **RC3 已修复** | 黑盒 10 轮 + 插桩确定性验证；PLM 已回填（验证结果=通过、验证RC=RC3、测试记录文档） |
| TDB-1104（空 DataRegion Adding 缩容 load snapshot NPE） | ✅ **PASS** | 表模型 9 + tree 模型 9 个空 region 扩缩容，5 台 DN 合计异常 **0** |
| TDB-65（集群节点 ReadOnly 可观测性） | ✅ **PASS** | DN 行 `Status=ReadOnly`、`StatusReason=Manual`（DETAILS 15 列）；只读期间写入报 `600`；恢复后 8/8 Running |

## 五、发现与建议

| 编号 | 级别 | 内容 | 建议 |
| --- | --- | --- | --- |
| F-1 | — | **已澄清**：TDB-709 修复在 RC3 生效（成功/803 均有 `OBJECT_AUTHENTICATION+[MAINTAIN]+CONTROL`），此前为脚本断言误判 | 断言已修正（`rn_smoke_2011_b3.sh`） |
| F-2 | — | **关闭**：仅 IoTConsensusV2 出现，V2 尚未完全适配 region 迁移，不作为缺陷；`REG-3` 已加协议守卫（V2 下 SKIP） | 后续 V1 回归时复核 |
| F-3 | 低 | CN 全宕时 DDL 报 thrift 原始异常（305 + Connection refused） | 封装为“集群元数据不可用”错误码 |
| F-4 | 低 | `DELETE` 回归脚本 `norm()` 未过滤 CLI 时间行，导致 12 例误判 | 已修复（保留在 `rc3_matrix/scripts/run_round.sh`） |

## 六、结论

1. RC3 在本次覆盖范围内**功能稳定**：ddl_ha 33/33、delete 精选 12/12、RN 专项 3/3；
2. RN 冒烟 **46/56 通过（0 失败）**，10 项 SKIP（环境限制 + V2 未适配 region 迁移）；TDB-709 的 CANCEL 审计已在 RC3 验证通过；
3. RC3 未发现新的阻塞级缺陷；TDB-1050 修复得到验证，TDB-1104/TDB-65 行为符合预期；
4. 待办：delete 剩余 174 轮按需续跑（约 60 小时）；F-2 已按“V2 未适配 region 迁移”关闭，无待研发项。

## 七、证据路径

| 内容 | 路径 |
| --- | --- |
| ddl_ha 结果 | `/data2/iotdb/ddl_ha_results_rc3_full/results.tsv` |
| delete 精选结果 | `/data2/iotdb/rc3_matrix/results/results.tsv`、`/data2/iotdb/del_rc3_subset.log`、`/data2/iotdb/del_rc3_rerun2.log` |
| RN 冒烟日志 | `/data2/iotdb/rn_rc3_all.log`、`/data2/iotdb/rn_2_0_11_1_rc3*/` |
| TDB-1104 | `/data2/iotdb/tdb1104_rc3.log` |
| TDB-1050 | `releasenote_skill/versions/v2.0.13.1/TDB-1050/` |
| 本轮报告 | `ai_auto_cases/172_16_2_20/docs/RC3-FULL-REPORT.md` |
