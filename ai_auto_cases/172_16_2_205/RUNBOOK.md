# 172.16.2.205（3C5D）回归 RUNBOOK

> 本文件说明如何在本环境对任意新版本跑完整回归，以及预期基线。
> 最近一次完整执行：**2.0.13.1 / ab6d3de**（2026-10-30 ~ 11-02），报告见 `REPORT_2.0.13.1_RC1.md`。

## 一、环境

| 项 | 值 |
| --- | --- |
| 跳板/客户端 | 172.16.2.205 |
| ConfigNode | 172.16.2.26 / .27 / .28（10710） |
| DataNode | 172.16.2.2 ~ .6（10730，客户端 6667） |
| 副本 | SchemaRegion 3 / DataRegion 2 |
| 账号 | root / TimechoDB@2021 |
| 套件目录 | `/data2/auto_test/treeview_suite`、`auth_suite`、`releasenote_skill` |

## 二、换版本（部署）

```bash
# 1) 上传安装包到 /data2/iotdb/<NEW>/timechodb-x.y.z-bin.zip，然后部署（保留激活身份）
cd /data2/auto_test/treeview_suite
NEW=vXXXXrcN_YYYY_abcdefg \
PKG_ZIP=/data2/iotdb/vXXXXrcN_YYYY_abcdefg/timechodb-x.y.z-bin.zip \
OLD_CN=/data/iotdb/<当前版本> OLD_DN=/data1/iotdb/<当前版本> \
bash deploy_build.sh

# 2) 三个套件的 NEW 都要改
sed -i 's/^NEW=.*/NEW=vXXXXrcN_YYYY_abcdefg/' /data2/auto_test/auth_suite/conf/env.conf
sed -i 's/^NEW=.*/NEW=vXXXXrcN_YYYY_abcdefg/' /data2/auto_test/releasenote_skill/conf/env.conf
# treeview_suite 靠命令行参数传版本，无需改文件
```

## 三、四条回归命令（共 198 条次）

```bash
# 1) tree-view · IoTConsensusV2（67 条，约 95 分钟）
cd /data2/auto_test/treeview_suite
bash run_regression.sh <NEW> IoTConsensusV2 TDB-343

# 2) tree-view · IoTConsensus 经典（67 条，约 93 分钟）
bash run_regression.sh <NEW> IoTConsensus TDB-343

# 3) 身份鉴别 · normal + 三权分立（27 + 34 条，约 20 分钟；结束自动恢复 normal）
cd /data2/auto_test/auth_suite
bash tools/run_regression.sh

# 4) ReleaseNote 场景（当前 3 条，约 2 分钟）
cd /data2/auto_test/releasenote_skill
bash tools/run_regression.sh
```

## 四、预期基线（2.0.13.1 / ab6d3de 实测）

| 套件 | 用例 | PASS | FAIL | 失败构成 | 耗时 |
| --- | --- | --- | --- | --- | --- |
| tree-view（V2） | 67 | 53 | 14 | TDB-888×4 + TDB-890×10 | 95 分 58 秒 |
| tree-view（经典） | 67 | 48 | 19 | TDB-888×4 + TDB-890×15 | 93 分 20 秒 |
| 身份鉴别（normal） | 27 | 27 | 0 | — | 9 分 13 秒 |
| 身份鉴别（separation） | 34 | 33 | 1 | TDB-899 | 约 10 分 |
| releasenote_skill | 3 | 3 | 0 | — | 约 2 分 |
| **合计** | **198** | **164** | **34** | 全部为已知缺陷 | 约 210 分钟 |

### 已知缺陷（截至 2.0.13.1）

| 缺陷 | 用例 | 现象 |
| --- | --- | --- |
| TDB-888 | TV-080 / 081 / 082 / 088 | 树模型设备改名后视图 TAG 仍为旧名；跨库改名后视图 0 行 |
| TDB-890 | TV-002/003/010~034/038/050~060 中触发者 | 自动补列报 `552 COLUMN_ALREADY_EXISTS` → `305`，功能正确但日志 ERROR |
| TDB-899 | AUTH-019（separation） | 三权分立下 `ALTER USER ... ACCOUNT UNLOCK` 返回 `701 Unsupported author type` |

### 已修复（回归应转 PASS）

| 缺陷 | 用例 | 修复版本 |
| --- | --- | --- |
| TDB-896 | AUTH-014 | 2.0.13.1（已验证 PASS） |
| TDB-125 | RN-001/002/003 | 2.0.13.1（已验证 PASS） |

## 五、常见问题（踩过的坑）

1. **`start_dn` 必须用 `setsid ... < /dev/null &`**：用 `nohup ... &` 经 ssh 启动，DN 进程会随会话退出，导致后续断言在"DN 未恢复"的环境下执行（曾造成 TV-055 误判）。
2. **判定用"过滤后条数"**：`suite.sh` 的 `errs` 必须取 `logdelta.txt` 中 `unexpected=` 之和，否则白名单不生效，HA 日志噪声会把用例判 FAIL。
3. **CN 侧 HA 噪声要白名单**：`RouteBalancer`、`CHANGE_REGION_LEADER`、`PIPE_HEARTBEAT`、`AsyncRequestManager Timeout`、`INVALIDATE_LAST_CACHE`、`DataNodeShutdownHook`。**不要**白名单 `ViewColumnAutoSyncTrigger`（那是补列失败的真实信号）。
4. **故障注入要避开 SQL 主机**：`auth`/`ReleaseNote` 的 kill -9 目标不能是 `HOST`（172.16.2.2），否则 CLI 直接连不上。
5. **CLI 调用加 `timeout`**：DN 被 SIGSTOP 时 CLI 会无限等待，用例会挂死。
6. **三权分立无法用 SQL 关闭**（需求明确不允许切回）：恢复只能改 `iotdb-system.properties` 的 `enable_separation_of_powers=false` + 重启。
7. **Windows 侧脚本必须是 LF**：CRLF 会导致 `bash -n` 报 `$'\r'` 错误。
8. **集群卡住时的重置**：`cd /data2/auto_test/treeview_suite && NEW=<NEW> bash hard_reset.sh`（会清库并重启，约 4 分钟）。

## 六、产物位置

| 套件 | 结果目录 |
| --- | --- |
| tree-view | `treeview_suite/results/REGRESSION_<NEW>_<协议>_<时间戳>/`（`summary.md`、`classified.tsv`、`results.tsv`、`suite.log`、`fail_logs/`） |
| 身份鉴别 | `auth_suite/results/regression_<时间戳>/`（`normal.rundir` / `separation.rundir` 指向逐轮结果） |
| ReleaseNote | `releasenote_skill/results/run_<时间戳>/` |

## 七、releasenote_skill 发版执行清单（2.0.13.1 实测基线）

### 7.1 四步走（约 45 分钟）

```bash
cd /data2/auto_test/releasenote_skill

# 1) 经典协议基线（77 例，约 20 分钟）→ 69 PASS / 1 KNOWN / 7 SKIP
bash tools/suite_rn.sh

# 2) 数据面协议 V2（同样 77 例，约 20 分钟+切换 4 分钟）→ 69 PASS / 1 KNOWN / 7 SKIP
bash tools/mode.sh proto-v2
bash tools/suite_rn.sh
bash tools/mode.sh proto-iot

# 3) 慢用例组（停节点 / ns 精度，4 例，约 10 分钟）
RN_SLOW=1 bash tools/suite_rn.sh

# 4) 三权分立组（3 例）
bash tools/mode.sh on
RN_MODE=separation bash tools/suite_rn.sh RN-121 RN-122 RN-125
bash tools/mode.sh off
```

### 7.2 预期基线

| 维度 | 用例 | PASS | KNOWN | SKIP |
| --- | ---: | ---: | ---: | ---: |
| 经典协议（默认） | 77 | 69 | 1 | 7 |
| IoTConsensusV2 | 77 | 69 | 1 | 7 |
| 慢用例组（RN_SLOW=1） | 4 | 4 | 0 | 0 |
| 三权分立组 | 3 | 3 | 0 | 0 |

- KNOWN 仅 1 条：RN-111 / TIMECHODB-0779（非法配置值仍写入 iotdb-system.properties）
- SKIP 7 条 = 3 条三权分立（普通模式跳过）+ 4 条慢用例（未加 RN_SLOW=1）

### 7.3 判读规则

1. **任何非 KNOWN 的 FAIL 都要当回归缺陷处理**，先用 `results/run_*/<ID>.out` 看具体断言；
2. 出现 `not enough connection resources` 类是连接资源瞬时耗尽（重跑即可），不是产品问题；
3. 协议切换后必须确认 `show cluster` 8/8 再开跑，否则会出现大面积误失败。

### 7.4 模式工具速查

```bash
bash tools/mode.sh on|off            # 三权分立（热加载开启 / 写配置+重启关闭）
bash tools/mode.sh audit-on|audit-off # 审计日志（企业版无操作审计，见 docs/audit_status.md）
bash tools/mode.sh proto-v2|proto-iot # 数据面协议（需清数据重建）
bash tools/mode.sh status             # 查看当前模式
```
