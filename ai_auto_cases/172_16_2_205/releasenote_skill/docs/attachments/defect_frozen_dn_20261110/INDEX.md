# 缺陷证据包：DN 失联期间树转表视图静默丢列

| 项目 | 内容 |
| --- | --- |
| **PLM 单号** | **TDB-1049**（id=1677） https://plm.infra.timecho.com/iterations?productId=1&itemId=1677 |
| 负责人 / 验证人 | 陈耀斌 / 刘珍 |
| 缺陷 | DN 失联（`kill -STOP` 冻结）期间新建序列，树转表视图的列永久缺失，客户端无感知 |
| 版本 | RC1 `2.0.13.1/ab6d3de`、RC2 `2.0.13.1/83183d0` 均复现 |
| 概率 | 实验组 11 轮丢 4（约 36%）；对照组 10 轮 0 失败 |
| 环境 | 172.16.2.205 集群，3 CN（.26/.27/.28）+ 5 DN（.2/.3/.4/.5/.6），数据盘 `/data1/iotdb` |
| 冻结对象 | DN6 = 172.16.2.6 |
| 取证时间 | 2026-11-10 17:33 ~ 17:53 |

## 目录结构

```
.
├── tree2table_frozen_dn_missing_column.md    # 缺陷报告（现象/复现/根因/日志/建议）
├── INDEX.md                                  # 本文件
├── logs/                                     # 日志切片（2026-11-10 17:37 丢列轮 defect_frozen_173705）
│   ├── cn_26_warn_err.log                    # CN26 窗口内全部 WARN/ERROR（含 Failed to prove DN is fenced）
│   ├── cn_26_dbmention.log                   # CN26 提及该库的全部行（procedure 各阶段耗时）
│   ├── cn_27_*.log / cn_28_*.log             # 该窗口内无相关日志（空文件，保留以证明"另外两个 CN 无异常"）
│   ├── dn_2_dbmention.log / dn_3_... / dn_5_...  # 健康副本 pre-update / rollback 记录
│   ├── dn_6_dbmention.log                    # 被冻结节点（仅 2 行，冻结期间几乎无日志）
│   ├── dn_*_warn_err.log                     # 各 DN 窗口内 WARN/ERROR（含 Raft heartbeat 超时）
│   └── log_datanode_view_column_auto_sync_error_excerpt.log  # 专门日志抽样（4 轮失败记录）
├── results/
│   ├── control_group_no_freeze.txt           # 对照组 10 轮（全部成功，时延约 2s）
│   └── freeze_rounds_raw.txt                 # 实验组 3 轮原始输出（含 LOST=yes/no）
└── repro/                                    # 复现脚本
    ├── verify_frozen_rc2.sh                  # 单轮冻结复现（跨版本，参数=构建目录）
    ├── collect_defect_logs.sh                # 复现 + 抓取全节点日志切片
    ├── run_defect_rounds.sh                  # 连跑 3 轮，自动记录 LOST
    └── control_group.sh                      # 对照组（不冻结），统计成功率与时延
```

## 复现命令

```bash
# 单轮复现（会冻结 DN6 12 秒）
bash repro/verify_frozen_rc2.sh v20131rc2_1110_83183d0

# 复现并抓日志（输出到 /tmp/defect_logs_<HHMMSS>）
bash repro/collect_defect_logs.sh v20131rc2_1110_83183d0

# 连跑 3 轮
bash repro/run_defect_rounds.sh

# 对照组（不冻结）
bash repro/control_group.sh v20131rc2_1110_83183d0 10
```

## 关键日志速查

```bash
# DN 专门日志（失败记录在这里）
grep -F "Failed to add a column to the view" /data1/iotdb/<build>/logs/log_datanode_view_column_auto_sync_error.log

# CN：fence 证明失败 / RPC 超时
grep -E "Failed to prove.*fenced|Timeout during UPDATE_TABLE" /data/iotdb/<build>/logs/log_confignode_all.log
```

## 结论摘要

- 冻结期间 `create timeseries` 返回成功，但该列在视图里**永久缺失**（120s 内不出现，且无任何用户可见错误）；
- 根因：CN `AddTableColumnProcedure` 的 pre-release 阶段需要「证明不可达 DN 已 fenced」，
  `UPDATE_TABLE` 5s×2 次超时 → pre-release 失败 → rollback 同样失败 → DN `ViewColumnAutoSyncTrigger`
  收到 507 后放弃，不再重试；
- 对照组 10/10 成功、补列时延约 2s，证明差异由「DN 不可达」这一变量直接引起；
- 与设计文档 §4.2.3「集群模式（DN≥3）单个 DN 隔离不影响扩列」的表述不符。
