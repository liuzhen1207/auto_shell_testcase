# 树转表 5C20D 自动化回归入口

## 一条命令跑全量

```bash
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW/treeview_5c20d
nohup bash regress_all.sh > /data1/iotdb/5c20dtest/testcase/PIPE/logs/regress.out 2>&1 &
```

`regress_all.sh` 的顺序（**pipe 组放最后**）：

```
停干净两套集群
  ↓
单集群用例 46 条（TV-BASE / SYNC / HA / LEAK / REF / REPRO）
   每条：停 25 节点 → 清 data/logs → 写 conf → 启动 → 用例 → 收尾三件套
  ↓
停干净两套集群
  ↓
pipe 组 9 条（TV-PIPE-01..09）
   组开始前：teardown 发送端 + 接收端
   每条：两端都 prepare（各 5CN+10DN，SR5/DR3）→ 用例 → 收尾三件套（**两端日志都扫**）
   组结束后：teardown 发送端 + 接收端
  ↓
停干净两套集群
```

## 三套集群/角色的边界（避免互相干扰）

| 集群 | 节点 | conf | 何时使用 |
|---|---|---|---|
| 单集群档位 | 172.20.70.100–119（5CN+20DN） | `conf/cluster.treeview_5c20d.conf` | 单集群用例 |
| pipe 发送端 | 172.20.70.100–109（5CN+10DN） | `conf/cluster.pipe_sender.conf` | pipe 组 |
| pipe 接收端 | 172.20.70.110–119（5CN+10DN） | `conf/cluster.pipe_receiver.conf` | pipe 组 |

- 单集群档位与 pipe 档位**共用同一批物理机**，所以：
  - 单集群用例组跑完后 → `regress_all.sh` **先 teardown 两套**，再进 pipe 组；
  - pipe 组结束后 → **再 teardown 两套**，避免残留进程影响下一轮。
- `run_case_clean.sh` 内置守卫：把 `TV-PIPE-*` 交给它会直接报错退出（提示改用 `run_pipe_case.sh`），
  防止"只 prepare 了发送端"造成假失败。
- **严禁并发**：任何时刻只允许一个队列/一条用例在跑（`prepare` 会 `rm -rf data/`）。

## 收尾三件套在 pipe 场景的差异

| 项 | 单集群 | pipe 组 |
|---|---|---|
| ① syncLag=0 | 主集群 | 主集群（发送端） |
| ② 副本一致性（全在线基线 + 停 2 台 DN） | 主集群 | 主集群（发送端） |
| ③ CN/DN ERROR·WARN 扫描 | 主集群 25 节点 | **发送端 + 接收端 共 30 节点**（接收端命中行带 `R:` 前缀） |
| FAIL 日志备份 | 25 节点 | **两端 30 节点** |

实现：`conf/cluster.pipe_sender.conf` 里 `LOG_SCAN_EXTRA_CONFS=conf/cluster.pipe_receiver.conf`，
`verify.py::scan_logs` 会额外用接收端 conf 构造一个 SshRunner，扫描其 CN/DN 日志，
命中 key 形如 `R:dn@172.20.70.110`，报告里可区分。

## 单独跑某一组

```bash
# 只跑 pipe 组（前后各 teardown 一次）
bash run_pipe_group.sh
# 只跑单条 pipe 用例
bash run_pipe_case.sh conf/cluster.pipe_sender.conf pipe TV-PIPE-03
# 只跑单条单集群用例
bash run_case_clean.sh conf/cluster.treeview_5c20d.conf tv TV-SYNC-03
```
