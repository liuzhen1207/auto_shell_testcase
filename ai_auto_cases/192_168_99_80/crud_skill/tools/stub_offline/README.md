# 离线纯桩干跑（`tools/stub_offline/`）

**目的**：在没有集群、或严禁碰集群（例如 99.80 正在跑长回归）时，验证 CRUD 用例脚本的
**代码路径与断言是否真的会触发**——尤其是"改配置不重启无效 / 重启后生效"这类**双证断言**。

**它做什么**：把本 skill 的**真实用例**（每次运行从 `cases/` 复制，不会过期）+ 桩 lib / 桩 CLI
组装到 `/tmp/cr14_stub`（可用 `STUB_ROOT` 改）后执行：

| 桩内路径 | 来源 | 说明 |
| --- | --- | --- |
| `cases/common/cr_load_pipe_last.sh` | **真实文件**（skill 的 `cases/`） | 被验证的用例 |
| `lib/crud_ext.sh` | **真实文件**（skill 的 `lib/`） | CRUD 日志判据层 |
| `lib/common.sh`、`lib/cmp.sh` | 桩 | 假 `ssh/sshx`（在本地"节点目录"上执行命令）、假集群生命周期、假 SQL（转给假 CLI） |
| `bin/fakecli.sh` | 桩 | 假 `start-cli.sh`：只认 CR-14 用到的语句；含 `rows.tsv`（可见数据）、`cache.tsv`（LastCache）、`runtime.properties`（**只有"重启"才会更新**的运行期配置——restart-only 语义的桩实现） |
| `conf/env.conf` | 桩 | 3C3D 拓扑的假配置 |
| `state/`、`results/` | 运行期生成 | 桩状态与桩输出 |

**绝不**：连接任何集群、启停集群、执行真实 SQL、写 skill 之外的目录（除 `$STUB_ROOT`）。

## 用法

```bash
bash tools/stub_offline/run.sh            # 跑 4 个模式（约 3~4 分钟）
bash tools/stub_offline/run.sh ok         # 只跑 ok 模式
```

## 四种模式（故意让"坏产品行为"出现，证明断言不是摆设）

| 模式 | 桩的行为 | 期望结果 |
| --- | --- | --- |
| `ok` | 正常产品行为：`SET CONFIGURATION` 只改配置层，重启才生效 | `RESULT PASS fail_flag=0`（Pipe/性能类只 WARN） |
| `hotapply` | `SET CONFIGURATION` **立即**改运行期生效值 | 断言 `S3：…未重启但…运行期生效值已变成…` FAIL |
| `norestart` | **重启不应用**配置（运行期保持旧值） | 断言 `S1：…生效值不一致` FAIL |
| `stale`（`ok` + `STUB_STALE=1`） | `load` 后不更新 LastCache | 断言 `S5：load 后立即 LAST == CLEAR CACHE 真值` FAIL |

## 已实测结论（2026-10-16，CR-14）

| 模式 | 结果 |
| --- | --- |
| `ok` | `RESULT PASS fail_flag=0`，**0 条 FAIL**、9 条 WARN（Pipe 不可构造 / 性能方向性只 WARN） |
| `hotapply` | `RESULT FAIL fail_flag=18`，恰好是 `S3：…未重启但运行期生效值已变成…`（3 键 × 3 节点 × 多相位） |
| `norestart` | `RESULT FAIL fail_flag=12`，恰好是 `S1：…生效值不一致`（重启后生效那一侧） |
| `ok`+`STUB_STALE=1` | `RESULT FAIL fail_flag=8`，恰好是 `S5：load 后立即 LAST == CLEAR CACHE 真值`（附三副本不一致） |

## 限制（**别把桩当产品证据**）

- 桩只模拟**本用例用到的**语义：load/delete/LastCache 策略/restart-only/权限拒绝；不含真实存储引擎、
  不含合并、不校验真实 TsFile 格式。
- 桩 lib 只提供 CR-14 用到的接口 ⇒ **改 CR-14 的用例逻辑后要同步桩**（缺函数会立刻报未定义）。
- 桩跑出的耗时/延迟数值**没有产品意义**（假 CLI 的进程启动开销占主导）。
