# releasenote_skill 回归套件

把每个版本 ReleaseNote 里的**修复点/改进点**逐条固化为可重复执行的用例，供后续版本回归。

## 快速开始

```bash
# 全量
bash tools/run_regression.sh

# 指定用例
bash tools/run_regression.sh RN-002
```

产物：`results/run_<时间戳>/results.tsv` 与逐用例 `<ID>.out`。

## 当前用例（3 条，均来自 TDB-125）

| 用例 | 场景 | 判据 |
| --- | --- | --- |
| RN-001 | 基线：DN 全部正常时 `GRANT` | 返回成功 |
| RN-002 | `kill -9` 一台 DN（不可达）后 `GRANT` | 返回成功；耗时 < 5s；`LIST PRIVILEGES` 可见；用户能查到数据 |
| RN-003 | `SIGSTOP` 一台 DN（进程存活但无响应，最接近 unknown）后 `GRANT` | 返回成功**或** `818 AUTH_OPERATE_EXCEPTION`（文案含 `Auth plan has been committed`）；耗时 < 5s；权限生效；能查到数据 |

## 关于 818 的预期语义（TDB-125 修复后的行为）

- DN **不可达**（Connection refused，快速失败）→ `GRANT` 返回成功；
- DN **无响应**（TCP 连得上但不回包，例如进程被挂起）→ 返回 `818 AUTH_OPERATE_EXCEPTION`：
  `Auth plan has been committed, but DataNode permission cache invalidation failed. ...`
  即"**授权已提交，仅缓存失效失败**"——这是明确的部分成功提示，**不是**修复前那种含糊的"授权超时"。
- 两种情况下权限均立即生效，客户端可正常读写。

> 源码依据：`TSStatusCode.java:192 AUTH_OPERATE_EXCEPTION(818)`、`ProcedureMessages.java:100`；
> 权限缓存失效已改为异步下发（`AuthOperationProcedure.java:214` → `CnToDnAsyncRequestType.INVALIDATE_PERMISSION_CACHE`）。

## 如何新增一条 ReleaseNote 用例

**命名约定**：`cases/TDB_<编号>_v<来源版本>.sh`，例如 `TDB_125_v2.0.13.1.sh`（不建版本子目录）。

1. 新建上述文件，文件头注释写明来源与标题（便于追溯）：
   ```bash
   # 来源 ReleaseNote：TDB-xxx
   #   标题：<ReleaseNote 标题>
   #   修复版本：Vx.y.z（验证版本 <被测版本> / <build>）
   #   场景/修复后语义：...
   ```
2. 实现 `case_RNxxx()`，断言用 `lib/lib_rn.sh` 的 `ok/fail/assert_*`；
3. 文件末尾加入 `CASES+=("RN-xxx|功能域|类型|说明|case_RNxxx")`；
4. 在 `cases.tsv` 增加一行，`来源版本` 列填该 ReleaseNote 的版本；
5. 若场景**已知会失败**（未修复/环境限制），写到 `conf/known_failures.conf`：
   ```
   RN-004|TDB-xxx|说明
   ```

## 目录

```
releasenote_skill/
├── SKILL.md
├── README.md
├── cases.tsv
├── cases/TDB_125_v2.0.13.1.sh
├── conf/env.conf
├── conf/known_failures.conf
├── lib/lib_rn.sh
├── tools/suite_rn.sh
├── tools/run_regression.sh
└── docs/TDB125_VERIFICATION.md
```
