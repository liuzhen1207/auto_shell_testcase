# diskusage_skill 导入 PLM 结果（5/5 全部 passed）

> 工具：SkillHub `timecho-plm-shell-testcase-import@1.3.1`
> 产品 TimechoDB（productId=1）｜PVE 3C3D（`3C3D标准模板` 9ea017b6…，SHELL，rev=1）｜dbVersion **2.0.13.1**
> 功能点：`存储/LSM 文件整理/在线文件合并/在线文件合并`（PLM 目前没有"磁盘占用统计"专属叶子，暂挂最接近的合并项）

## 一、结果

| 用例 | PLM 用例 | 执行结果 | 说明 |
| --- | --- | --- | --- |
| DU-01 统计后合并仍可推进（树） | **TimechoDB-11106** | ✅ passed | TDB-629 门禁（树模型接口） |
| DU-02 统计后合并仍可推进（表） | **TimechoDB-11107** | ✅ passed | TDB-629 门禁（表模型接口） |
| DU-03 统计正确性（树） | **TimechoDB-11108** | ✅ passed | 列序/字节数/作用域/分页 |
| DU-04 统计正确性（表） | **TimechoDB-11109** | ✅ passed | information_schema 列/过滤/分组 |
| DU-05 权限与错误路径 | **TimechoDB-11117** | ✅ passed | 仅 SYSTEM 可执行、非法 pattern、空结果 |

**5/5 passed**（累计 2 个模块完成：sec_skill 16/16、diskusage_skill 5/5）。

## 二、导入时遇到的三个"非产品"卡点（已解决，供后续模块参考）

| # | 现象 | 原因 | 解决 |
| --- | --- | --- | --- |
| 1 | DU-05 一直"待确认"，`--accept-review` 后仍 pending | `cases/common/*` **推不出树/表模型** → `model=null` 被拦 | 加 `--assume-model tree` |
| 2 | DU-05 二次 pending：拓扑匹配不到模板 | common 用例拓扑为空 → `assign_template` 失败 | 加 `--config-id 9ea017b6…` 强制 3C3D |
| 3 | DU-04、DU-05 出现 `run submit_failed` | 平台侧瞬时失败（与此前 502 同类） | 用 `plm_run_case.py` 直接补跑并回写台账 |

## 三、环境映射改动

`conf/env.conf` 已按 PLM 注入变量改造（本地行为不变）：

| 变量 | 优先级 |
| --- | --- |
| `CLUSTER_NODES` / `CN_NODES` / `DN_NODES` | 本变量 → **PLM_CLUSTER_CN/DN_NODES** → 192.168.99.77-79 |
| `DB_PARENT_DIR` / `SHELL_CLIENT_DIR` | → **PLM_PARENT_DIR**（从 `PLM_DB_HOME` 推导） |
| `V_TESTDB` | → **PLM_DB_VERSION** → `PLM_DB_HOME` 的 basename |
| `ROOT_PW` | → **PLM_DB_PASSWORD** → TimechoDB@2021 |
| `SSH_USER` | → **PLM_SSH_USER** → root |

## 四、产物

- 台账：`diskusage_skill/plm_import/ledger.json`（5 条，幂等）
- 映射：`feature-map.json`、`name-map.json`
- 日志：`import_batch.log`、`import_DU05.log`、`run_du04.log`、`run_du05.log`
- 部署副本：`ai_auto_cases/192_168_99_80/diskusage_skill/`

## 五、备注

1. **功能点缺口**：PLM 树里没有"磁盘占用统计/磁盘用量"叶子，5 条暂时都挂在"在线文件合并"下；
   若后续要按功能点出报告，建议产品侧补一个 `存储 / LSM 文件管理 / 磁盘占用统计` 叶子。
2. 本模块**没有**出现 CR 系列那种"PVE 失败、本地不复现"的现象，5 条一次通过。
