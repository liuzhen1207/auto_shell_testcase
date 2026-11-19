# 2.0.13.1 RC3 验证对照：本地 3C3D vs PLM PVE 实例

> 生成时间：2026-11-19 19:10
> 目的：区分 **产品问题** 与 **PVE 验证环境问题**，供研发评估。

## 一、环境

| 项 | 本地 3C3D | PLM PVE 实例 |
| --- | --- | --- |
| 版本 | **2.0.13.1 / BuildInfo `ac7f95e`（RC3）** | **2.0.13.1 / `ac7f95e`（RC3）**（PLM 默认镜像 `timechodb-2.0.13.1-bin_rc3_202611172215`） |
| 集群 | 3 CN + 3 DN，全部 Running / ACTIVATED | 同（每次运行新建实例） |
| 节点 | 192.168.99.77/78/79 | 10.13.0.x |
| 节点规格 | **31 GB RAM / 8 vCPU / 2 TB 磁盘** | 未知（怀疑偏小，见第五节） |
| 用例来源 | 同一份 skill 源码（装配前） | 同一份脚本装配后（见附件） |

## 二、逐条对照（6 条曾在 PVE 失败的用例）

| 用例 | 本地 RC3 | PVE | 判定 |
| --- | --- | --- | --- |
| **CR-09** Mod 生命周期（`cr_mod_lifecycle.sh`） | ❌ **FAIL fail_flag=1，930s** | ❌ failed | **产品问题**（TDB-1621） |
| CR-01 时间戳精度（`cr_timestamp_precision.sh`） | ✅ PASS，850s | ❌ failed | PVE 环境 |
| W-00 WAL 冒烟（`wal_smoke.sh`） | ✅ PASS，550s | ❌ failed（`SHELL_PROCESS_DISAPPEARED`） | PVE 环境 |
| TT-03 `ttl_tree_dml.sh` | ✅ PASS，382s | ❌ failed | PVE 环境 |
| TB-04 `ttl_table_dml.sh` | ✅ PASS，381s | ❌ failed | PVE 环境 |
| TP-03 `ttl_param_effect_mode.sh` | ✅ PASS，657s | ❌ failed | PVE 环境 |

**结论：6 条里只有 CR-09 是产品问题；其余 5 条在本地 RC3 全部通过。**

## 三、产品问题的证据（CR-09 / TDB-1621）

- 现象：重启恢复时，若 region 内存在 V1 `.mods`，升级流程会把**已存在的 V2 `.mods2`** 再写一遍：
  `1794970437352-….mods2` 35B → **70B**，md5 变化，内容是**同一条删除记录出现两遍**；
- 本地 RC3（`ac7f95e`）稳定复现（930s，fail_flag=1）；
- PLM 记录：**TDB-1621**（代码优化，迭代 V2.0.15.1，负责人 江天，验证 刘珍）；
- 最小复现脚本：`crud_skill/tools/repro_v1mods.sh`（本地可 30 秒级构造 → 重启 → 比对 `.mods2` 字节/md5）。

## 四、PVE 失败的证据（W-00，供研发排查）

| 项 | 值 |
| --- | --- |
| PLM 用例 | **TimechoDB-11210**（caseId 16511） |
| 执行器 | `57e2ea29-c707-4963-92ba-fa13b8099a3c` |
| 失败运行 | task `a930d6c7-0ef5-4f86-aa15-9f832385bd83` / attempt `7849d735-3fe8-4173-ab23-f28369192634` |
| 失败码 | **`SHELL_PROCESS_DISAPPEARED`** |
| session | **空**（进程直接消失，不是断言失败） |
| 实例 | `10.13.0.129`，dbHome `/opt/timecho/2.0.13.1` |

同类：W-02 = TimechoDB-11212（16513）、W-03 = TimechoDB-11214（16515）。

**用例行为**：写 7200 行 → 记录 WAL 目录基线 → `flush` → 校验 WAL 文件 → 重启集群。
**本地 RC3 上同一脚本 PASS（550s）**，所以不是脚本/版本问题。

建议在实例 `10.13.0.129` 上查：
```bash
dmesg -T | grep -i oom
journalctl -k | grep -i oom
ls -l /opt/plm-shell/a930d6c7-0ef5-4f86-aa15-9f832385bd83-7849d735-3fe8-4173-ab23-f28369192634/
```

## 五、资源建议（PVE 实例）

| 档位 | 适用用例 | 每节点 | vCPU | 磁盘 |
| --- | --- | --- | --- | --- |
| 最低 | sec / diskusage / metadata | 8 GB | 4 | 100 GB |
| 推荐 | crud / ttl / wal 常规 | **16 GB** | 8 | 200 GB |
| 重量级 | CR-09/CR-10、ttl `*_dml`、compaction 全量 | **32 GB** | 8 | 400 GB |

依据：本地 DN 峰值 **RSS 4.0 GB**；重启瞬间新旧 JVM 共存 + 页缓存叠加；`SHELL_PROCESS_DISAPPEARED` 符合 OOM-kill 特征。
另建议：**执行超时 90 → 120~150 分钟**（CR-10、TP-01、TB-05 本身 20~40 分钟）。

## 六、附件

| 文件 | 说明 |
| --- | --- |
| `W-00_assembled.sh` | PLM 执行器里实际运行的装配脚本（199 KB，含内联 lib/conf） |
| `crud_skill/tools/repro_v1mods.sh` | TDB-1621 最小复现脚本 |
| `crud_skill/docs/DEFECT_mods2_duplicate_on_upgrade.md` | TDB-1621 缺陷报告 |
| `sec_skill/docs/PLM_IMPORT_PAUSED_20261118.md` | 导入过程与平台问题记录 |
