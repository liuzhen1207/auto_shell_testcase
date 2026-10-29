# QUICKSTART —— 5 分钟跑起来

## 0. 先确认三件事
```bash
cd <skill>/ttl-autotest-skill
sed -n '1,20p' conf/env.conf          # 集群 IP / 版本目录 / 密码 / 副本数 / 共识协议
bash tools/selftest.sh                # harness 自检（不跑集群也能过；集群在跑时会顺带测写配置）
```
`tools/selftest.sh` 必须 `failed=0`。它检查的是**harness 自己**（用例语法、按库日志正则能否区分
`ttl_x` 与 `ttl_x2`、`show configuration` 解析、`fail()` 是否真的计入 fail_flag、跨用例重名库、
写配置在 `set -u` 下能否正常展开）。历史上正是这些地方出过问题，看起来却像"产品没清理"。

## 1. 冒烟（约 6 分钟）
```bash
bash tools/run_all.sh --set quick                 # 树+表各一个基本功能用例
tail -3 results/test_result.csv
```

## 2. 想验什么就跑对应集合
| 目的 | 命令 |
| --- | --- |
| TTL 功能/参数值（树） | `bash tools/run_all.sh --set tree` |
| TTL 功能/参数值（表） | `bash tools/run_all.sh --set table` |
| 大数据量 + DELETE + DROP 重建 | `bash tools/run_all.sh --set dml` |
| **参数值/热加载/重启生效** | `bash tools/run_all.sh --set param` |
| **清理阈值 / 写放大缺陷回归门禁** | `bash tools/run_all.sh --set threshold` |
| 全部 | `bash tools/run_all.sh --set all` |
| 换共识协议 | 追加 `--consensus IoTConsensusV2`（或 `IoTConsensus,IoTConsensusV2` 各跑一遍） |

单跑：`bash cases/tree/ttl_tree_scope.sh --consensus IoTConsensus`
复用已运行集群（调试，不重启）：`SKIP_LIFECYCLE=1 bash cases/common/ttl_cleanup_threshold.sh`

## 3. 结果怎么读
- `results/test_result.csv`：`Time,build,consensus,caseName,result,elapsedSeconds,failCount,artifact,message`
- `results/<case>_<runid>.out`：全过程日志（每条 SQL 输出 + 每个 PASS/FAIL 的原因）
- `results/artifact_<case>_<runid>/logs/*.tgz`：失败时自动打包的 CN/DN 日志
- 每条失败都有 `FAIL <说明>`；**WARN 不影响结论**，但常提示"某个副本还没落盘"这类前提问题，值得看一眼。

### 本版本（RC4）上"失败才是正常"的两条
| 用例 | 现象 | 说明 |
| --- | --- | --- |
| `ttl_param_effect`（Part C r1） | FAIL | `expired_data_ratio` 被"过期太久"强制分支短路（`SettleSelectorImpl` L294 把本意的 `3*ttl` 写成 `ttl`） |
| `ttl_cleanup_threshold`（D 相） / `ttl_table_cleanup`（D 相） | FAIL | `expired_data_ratio=0.0` 时零脏数据文件被每个检查周期反复 settle 重写（写放大） |

两条都有完整证据链与修复建议，见 `docs/CALIBRATION.md` 0.6 节与
`D:\IDEA\deepseek\TTL\缺陷报告_TTL过期数据比例失效_20260930.md`。
修复后这两条应转为 PASS（即用例是**回归门禁**，不是期望它一直失败）。

## 4. 排查"清理没发生"的顺序（别跳步）
1. 该副本的 TsFile 是否已 `Async close`？——`ttl_close_cnt`/`ensure_closed`（未落盘的文件**不参与** settle 选择）
2. 参数**生效值**是否为期望值？——table 方言 `show configuration;`（`ttl_effective_conf`），逐节点看
3. `[TTL] ... Totally select N all-outdated files and M partial-outdated files` 是否非 0？（候选）
4. 是否出现真实任务 `SettleCompaction task starts with X fully_dirty files and Y partially_dirty files`？
5. 数据是否真的过期？——`SHOW DEVICES` 看设备生效 TTL；节点间时钟是否已校正（本环境无 NTP）
