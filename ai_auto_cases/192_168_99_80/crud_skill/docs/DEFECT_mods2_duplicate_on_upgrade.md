# 缺陷报告：重启恢复时 V1→V2 Mod 升级会**重复写入已有的 `.mods2`**（35B → 70B，同一条删除记录两遍）

| 项 | 内容 |
| --- | --- |
| 标题 | 【V2.0.13.1】Region 恢复时若存在 V1 `.mods` 文件，升级流程会把**已存在的 V2 `.mods2`** 再写一遍，导致同一删除记录重复、Mod 文件字节数翻倍 |
| 版本 | TimechoDB **2.0.13.1 RC2**（`v20131rc2_1110_83183d0` / `83183d0`） |
| 环境 | 本地干净 3C3D（192.168.99.77/78/79，SR=3/DR=3，IoTConsensus），**最小脚本复现** |
| 复现概率 | **必现**（2/2 次独立构造；且 PVE 上 CR-09 也出现同一现象） |
| 严重程度 | 数据未丢失（删除语义仍生效），但 Mod 文件内容重复、体积翻倍；对"Mod 持久性"类断言/校验造成误判，长期多次升级场景有放大风险 |
| 发现方式 | CR-09（Mod 生命周期）在 PVE 失败 → 本地按同一注入方式构造最小场景复现 |

## 一、复现步骤（最小）

前提：干净 3C3D，库 `root.moddup`。

1. 写 **d2** 的 5 行 → `flush` → 得到 TsFile **A**（有 `.resource`、无 `.mods2`）；
2. 写 **d1** 的 5 行 → `flush` → 得到 TsFile **B**；
3. `delete from root.moddup.d1.** where time <= 1800000000000` → `flush` ⇒ **B** 生成 `.mods2`（35B，1 条删除记录）；
4. 给 **A** 注入 V1 文本 Mod 文件（模拟旧版本遗留）：
   ```
   DELETION,root.moddup.d2.s1,0,1600000000000,1900000000000   >  <A>.tsfile.mods
   ```
   此时：A 有 `.mods`(57B) 无 `.mods2`；B 有 `.mods2`(35B)；
5. 重启集群（stop → start，**不清数据**）。

## 二、实际结果

| 文件 | 重启前 | 重启后 | 期望 |
| --- | --- | --- | --- |
| **A**（注入 V1 `.mods`） | `.mods` 57B，无 `.mods2` | `.mods2` **35B**（升级产物，符合预期） | 升级出 `.mods2` |
| **B**（已有 `.mods2`） | `.mods2` **35B**，md5 `84150d02…` | `.mods2` **70B**，md5 变化 | **不变（35B）** |

B 的 `.mods2` 十六进制（70B = 35B × 2，**同一条记录出现两遍**）：

```
01 80 00 00 00 00 00 00 00 00 00 01 a3 18 5c 50
00 22 72 6f 6f 74 2e 6d 6f 64 64 75 70 2e 64 31     ← "root.moddup.d1.**"
2e 2a 2a
01 80 00 00 00 00 00 00 00 00 00 01 a3 18 5c 50
00 22 72 6f 6f 74 2e 6d 6f 64 64 75 70 2e 64 31     ← 同一条记录再次出现
2e 2a 2a
```

补充观察：
- **再重启两次不会继续增长**（70B 保持 70B）⇒ 不是每次重启都重复，而是**升级那一趟**重复写了一次（因为升级后不再有 V1 `.mods`）。
- 日志中同一 region 出现**两次** `new single thread pool: root.moddup-13-UpgradeMod`（14:39:59 与 14:40:40），与"升级跑了两趟/两处触发"一致。

## 三、影响

1. **Mod 文件体积翻倍**：删除记录重复存储；若一个 region 里历史 `.mods` 较多，升级后 `.mods2` 体积可能成倍增长。
2. **语义**：本次实测删除仍然生效（d1 查询 0 行），未见数据错误；但重复记录属于无效数据，且会让"Mod 文件持久性/幂等"类校验失败（CR-09 即因此 FAIL）。
3. **与 PVE 失败对应**：CR-09 在 PVE 上 `1794970437352-….mods2` 从 35B → 70B、md5 变化、`.mods2` 数 1→2，与本复现**逐项一致**。

## 四、疑似根因（源码方向，供研发参考）

- 文档/注释的预期：**只对"有 `.resource` 但没有 `<tsfile>.mods2`"的 TsFile 调用 `upgradeModFile()`**
  （见 `crud_skill` CR-09 注释与 `TsFileResource.upgradeModFile()` 的调用点）；
- 实测：region 内**只要存在**一个 V1 `.mods`，升级流程会遍历 region 内 TsFile，
  对**已有 `.mods2` 的文件**也执行了"写 Mod 文件"的动作，且写入方式为**追加**而非截断重写 ⇒ 同一份条目写了两遍。
- 建议核对：
  1. `upgradeModFile()` / `ModFileManagement.recover()` 是否按"has .mods2 → skip"过滤；
  2. 写 `.mods2` 的 writer 是否以 `truncate` 打开（而不是 append）；
  3. 升级线程池是否对同一 region 触发两次（日志出现两个 `…-UpgradeMod` 线程池）。

## 五、待研发确认的第二点（V1 删除是否真的生效）

本次注入的 V1 删除记录（`offset=0`，与 CR-09 用例写法一致）升级后生成了 `.mods2`，
但 **d2 仍然是 5 行**（用例期望 0）。可能原因：
- V1 记录的 `offset` 字段语义（我们传 0）与实际写入位置不匹配 ⇒ 删除不命中；
- 或升级只搬了记录、没重建正确的删除区间。

⇒ 请研发确认 V1 `.mods` 文本格式中 `offset` 的正确取值；若应为真实 offset，我们会在用例里改成按 TsFile 内偏移构造。

## 六、证据路径

| 内容 | 路径 |
| --- | --- |
| 复现日志 | `/data/iotdb/autotest/rc2_regression_logs/v1mods_repro.log` |
| 增长验证 | `/data/iotdb/autotest/rc2_regression_logs/v1mods_growth.log` |
| 行数/十六进制/日志 | `/data/iotdb/autotest/rc2_regression_logs/v1mods_evidence.txt` |
| 复现脚本 | `crud_skill/tools/repro_v1mods.sh`、`_v1mods_growth.sh`、`_v1mods_evidence.sh` |
| 用例侧 | `crud_skill/cases/common/cr_mod_lifecycle.sh`（PVE: TimechoDB-11092） |
