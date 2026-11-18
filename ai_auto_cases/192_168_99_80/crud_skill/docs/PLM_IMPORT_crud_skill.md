# crud_skill 导入 PLM 结果（2026-11-18）

> 工具：SkillHub `timecho-plm-shell-testcase-import@1.3.1`
> 产品 TimechoDB（productId=1）｜PVE 3C3D（`3C3D标准模板`，SHELL，rev=1）｜dbVersion **2.0.13.1**
> 功能点：`存储/CRUD操作/*`（CR-13/14 挂 `基础写入/单条/批量写入`）

## 一、结果总表

| 用例 | PLM 用例 | 执行结果 | 说明 |
| --- | --- | --- | --- |
| CR-00 冒烟 | TimechoDB-11024 | ✅ passed | |
| CR-01 时间戳精度 | TimechoDB-11025 | ❌ failed | **PVE 特有**：停 DN 后查询多一行；**本地同 build 复跑 PASS**（857s） |
| CR-02 精度×分区 | TimechoDB-11026 | ✅ passed | |
| CR-03 表模型仅 Time 列 | TimechoDB-11027 | ✅ passed | 含停 DN 一致性检查 |
| CR-04 .mods2 基础形态 | TimechoDB-11028 | ✅ passed | |
| CR-05 Mod 分配阈值 | TimechoDB-11029 | ✅ passed | |
| CR-06 删除×合并并发 | TimechoDB-11030 | ✅ passed | 台账曾被旧 `skipped` 覆盖，已修回 |
| CR-07 删除中间态 | TimechoDB-11090 | ❌ failed | **用例侧**：大 payload 写入触发自动 flush，memtable 场景构造不出（250/12000 行） |
| CR-08 Pipe 传删除 | TimechoDB-11091 | ✅ passed | |
| CR-09 Mod 生命周期/重启 | TimechoDB-11092 | ❌ failed | **PVE 特有**：R-28 旧 Mod 生效 + `.mods2` 字节/md5 未变；**本地复跑失败点不同**（合并未推进） |
| CR-10 DELETE 阻塞写入 | TimechoDB-11093 | ❌ error | **SHELL_EXECUTION_TIMEOUT**（量化类超 90 分钟上限） |
| CR-11 OBJECT 手动删除 | TimechoDB-11094 | ✅ passed | |
| CR-12 OBJECT 删除异常 | TimechoDB-11095 | ✅ passed | |
| CR-13 LOAD×LastCache | TimechoDB-11097 | ⏳ 待执行 | 首次导入因功能点非叶子被拦；重导后 PVE 队列 `CREATE_REQUESTED` 排队中 |
| CR-14 LOAD×Pipe | TimechoDB-11096 | ✅ passed | |

**统计：10 passed / 4 failed / 1 待执行。**

## 二、失败分类

| 类型 | 用例 | 依据 |
| --- | --- | --- |
| **PVE 环境特有**（本地不复现） | CR-01、CR-09 | 本地同 build 3C3D 复跑：CR-01 **PASS**；CR-09 失败点不同（"合并未推进"而非 R-28/.mods2） |
| **用例场景不可构造** | CR-07 | 写入期自动 flush，memtable 保留行数 250/12000，用例自身 WARN"场景未成立" |
| **平台超时** | CR-10 | `SHELL_EXECUTION_TIMEOUT`（PLM 执行上限） |
| **平台资源排队** | CR-13 | `CREATE_REQUESTED` 长时间排队（同模板 groupConcurrency=2，前面提交积压） |

## 三、平台侧观察到的问题（建议反馈 PLM）

1. **502**：`POST /api/open/test-executors/runs` 曾返回 502（重试后恢复）；
2. **CANCELLED**：一次被 kill 的运行导致后续多次 `skipped/CANCELLED`（槽位被占，实例未回收）；
3. **CREATE_REQUESTED 排队**：同模板并发只有 2，长用例（CR-10）会长时间占满，导致后续任务排队/超时。

## 四、本地复跑记录

| 用例 | 本地结果 | 耗时 | 日志 |
| --- | --- | --- | --- |
| CR-01 | **PASS** fail_flag=0 | 857s | `/data/iotdb/autotest/rc2_regression_logs/crud01_run.out` |
| CR-09 | FAIL fail_flag=1（合并未推进） | 1076s | `/data/iotdb/autotest/rc2_regression_logs/crud09_run.out` |

结论：这两条在本地干净 3C3D 上都无法复现 PVE 的失败点 ⇒ 优先怀疑 **PVE 实例环境差异**（实例复用/未清 data/配置默认值不同）。
