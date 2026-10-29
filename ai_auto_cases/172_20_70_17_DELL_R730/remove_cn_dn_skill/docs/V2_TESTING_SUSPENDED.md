# remove-cn-dn × IoTConsensusV2：测试暂停（2026-10-13 决策）

## 决定
**暂停**在 `iotdb-remove-cn-dn` 技能矩阵上使用 IoTConsensusV2 跑测（原因：问题较多，研发暂无时间修复）。
**其它场景**（如 CRUD、TTL）不受影响，可继续在 IoTConsensusV2 下测试。

## 暂停时的状态（RC6 `7ae8713e`，2026-10-12/13）
- V2 矩阵结果：**27 FAIL / 1 SKIP / 0 PASS**（`results/matrix_20261012_145510`）
- 单条复现与源码级分析（各 1 份，均已打包）：
  - case1 `dn_running_remove` → `rn_verify/remove-node/v2_per_case/CASE1_dn_running_remove_ANALYSIS.md`
  - case2 `dn_unknown_remove` → `rn_verify/remove-node/v2_per_case/CASE2_dn_unknown_remove_ANALYSIS.md`
- 证据包（含复现 run 全目录与**逐节点 CN/DN 原始日志**）：
  - `rn_verify/remove-node/v2_evidence_case1_dn_running_remove_v2_20261013_1030.tar.gz`（sha256 `533153ee…`，2.5 MB）
  - `rn_verify/remove-node/v2_evidence_case2_dn_unknown_remove_20261013_1054.tar.gz`（sha256 `487d5e4c…`，2.1 MB）
- 类级取证：`rn_verify/remove-node/rc6_v2/{V2_ADD_PEER_ANALYSIS.md, V2_CN_INCONSISTENCY_ANALYSIS.md, familyA_per_case.txt, stall1500_retest.log, v2_matrix.log}`
- 缺陷草稿（**未录 PLM**）：`rn_verify/remove-node/DEFECT_DRAFT_v2_familyA_add_region_peer_not_converging.md`

## 结论必须分成两句（恢复时勿混为一谈）
1. **主要是我方阈值伪影（不可算产品缺陷）**：V2 下 DataRegion add-peer 正常耗时 **5m49s–6m25s**（只搬已 seal 的 TsFile，受 flush 周期约束），
   而 `PROCEDURE_STALL_SEC=300` **低于该正常时长** ⇒ 该负载下每条 DN 移除用例都会被判 wedge；
   判死后 3s/10s 仍有 procedure 成功（case2 `log_confignode_all.log:3480/3612`）。**修：阈值 ≥1500s**。
2. **另有一条真实产品侧缺陷（与阈值无关，需研发）**：管道任务丢失/进度索引不可读时，
   `IoTConsensusV2ServerImpl:315` 的无界等待 + `:405-423 catch(PipeException){LOGGER.info; return false;}` ⇒ 该 Region **永久 WAITING**、`SHOW MIGRATIONS` 永不清空
   （case1 Region 6 吞 12 次；case2 Region 8 吞 7 次；阈值提到 1500s 后仍有用例卡 1551–1557s）。

## 我方工具待修（与协议无关，建议尽快）
- `scripts/rcdn/verify.py:28 r"BufferUnderflowException"`、`:40 r"tsfile error"`：日志门禁**正则过宽**，
  会把 **harness 停机瞬间的噪声**（`cases.py:342 stop_all()` 后 275ms 的 `BufferUnderflowException` + `PipeMemoryBlock Interrupted`）与真实产品 WARN 都判为"意外日志行"；
- `cases.py:1656-1670 _unsyncable_nodes`：把**用例按设计停掉的节点**当成"永不可 drain" ⇒ 误报 sync-lag 门禁，
  并导致 `verify.py:756-760` 在 baseline 前 return ⇒ **副本一致性 sweep 根本没跑**；
- `verify.py` 解析 `show datanodes` 的列名（`InternalAddress` → **`RpcAddress`**）：**已修**（此前导致 forensic 文件清单恒空、输出"各副本一致"的伪结论）。

## 恢复时的检查单
1. 用 `conf/cluster.rc6_iottv2_stall1500.conf`（阈值 1500s），**不要**用 `cluster.rc6_iottv2_matrix.conf`（300s，已产生全量伪 FAIL）；
2. 先修上面两条门禁（日志正则、`_unsyncable_nodes`），再跑矩阵，否则结论不可用；
3. 关注真实缺陷签名：`IoTConsensusV2ServerImpl:420 Failed to get pipe task progress index` / `Pipe meta not found: __consensus.DataRegion[...]`，
   以及 `AddRegionPeerProcedure` 长期 `WAITING` 的 Region 是否在 ≥1500s 后仍未收敛；
4. 目标：把"真缺陷用例集合"与"仅因慢而被判死的用例集合"彻底分开统计。

---

## 附：本轮测试工具改动清单（均与协议无关，已自检）
1. **`scripts/rcdn/cases.py` — `_unsyncable_nodes` 不再把"用例按设计停机"的目标当永久不可同步**
   新增按用例重置的 `self._by_design_gone`（`__init__`/`run()`），DN/CN 移除路径写入被移除主机，门禁跳过它们。
   效果：`sync-lag cannot drain: … is unknown/removing` 伪问题消失，`verify.py` 不再在 baseline 前 `return`，**副本一致性 sweep 得以执行**；
   非设计原因的 `ReadOnly/Unknown` 节点**照旧报错**（单测：`['11.101.10.10 is unknown']`）。
2. **`scripts/rcdn/verify.py` + `cases.py` — 日志门禁按时间定界（非白名单）**
   `_scan_script/scan_logs/check_logs` 新增 `until_epoch`；`cases.py` 在 `-- stage: logs` 的 `stop_all()` 前记录 `harness_stop_epoch`，
   以 `until_epoch=harness_stop_epoch-1` 扫描（停机秒整体归 harness 窗口）；awk 用"最后见到的时间戳"归因续行（`Caused by:` 等）。
   真实日志回放（case2 `dn@11.101.10.9`，9.5 MB）：旧行为命中 `BufferUnderflowException` **1** 次 → 新行为 **0** 次；
   合成用例：停机前的真实 `BufferUnderflowException` **仍被报出**（保持检出力）。
3. `scripts/rcdn/verify.py` — `show datanodes` 列名解析 `InternalAddress` → **`RpcAddress`**（此前导致 forensic 文件清单恒空、输出"各副本一致"的伪结论）。
4. `scripts/rcdn/cases.py` — CN 仲裁相关的用例前置 SKIP 规则（`kill9_cn`/`stop_cn` 计入门槛，`restart_cn` 不计入）；
   以及 3 处 wedge 现场 dump（`wedge_{regions,datanodes,confignodes,migrations}_<ts>.raw`，判定中性、可回退）。
5. `scripts/rcdn/sentinel_times.py` — 基准负载的 retry/rotation 补丁（保持负载可比）。
