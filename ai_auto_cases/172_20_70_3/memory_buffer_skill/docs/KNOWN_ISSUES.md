# 已知问题与处置（本环境 172.20.70.3 / v20121rc8_1016_ebaf9da）

## 1. 经 run_all 调用时，用例偶发被 SIGKILL（rc=137）

**现象**：`tools/run_all.sh` 调用用例时，用例进程在"清理 data/logs 之后 / 写入阶段"被 SIGKILL，
bash 报 `Killed`；`dmesg`、`/var/log/kern.log`、`journalctl -k` 均为空（容器内受限，无法确认是否 OOM）。

**已做的对照实验**：

| 方式 | 结果 |
|---|---|
| 单独执行 `bash cases/common/mb_03_flush_by_proportion.sh` | **PASS 528s**（写入 2000 点 / 31 条语句全成功 / 刷盘 / 一致性 / 日志全 PASS） |
| 经 `run_all.sh`（子进程 `| tee`） | 两次均 rc=137 |
| 经 `run_all.sh`（子进程重定向到文件） | rc=137 |
| 经 `run_all.sh`（子进程 `setsid` 独立会话） | rc=137 |
| 经 `run_all.sh` 跑 MB-01（19:10 那次） | 用例自身 `RESULT PASS`，是 run_all 的判定行 grep 写错才误判 |

**根因（已定位到很实的程度）**：`run_all.sh` 看到的 `rc=137` **不代表用例死了**。
实测证据：

1. 19:04 那次 MB-01 报 `rc=137`，但 MB-01 的 artifact 显示它继续跑到 19:15:35 并写了
   `RESULT PASS fail_flag=0`；
2. 21:26 检查机器时发现 **两个 PPID=1 的 `mb_06_reject_and_recover.sh` 孤儿进程**（etime 4 分钟）仍在跑；
3. 这些孤儿会在下一轮 `run_all` 启动时与新用例**同时操作同一集群**（一个在停、一个在起；
   一个在写库、一个在清 data），于是新用例表现为"莫名 Killed / 写入成功数=0 / 点数对不上"。

也就是说：**ssh/会话层会打断 run_all 与子进程之间的父子关系（子进程被单独 SIGKILL 掉的是"被等待的那一层"），
用例本体脱离成孤儿继续跑完**。dmesg/kern.log/journalctl/cgroup 均无 OOM 记录，systemd-oomd 不存在。

**当前处置（两层）**：

1. `run_all.sh` 启动时 `cleanup_orphans`：只杀 **PPID==1** 的 `mb_xx.sh`（不碰本轮自己拉起的用例，
   因此不会重犯"pkill 误杀本轮"的错）；
2. `run_all.sh` 对子进程 `rc=137` 不再直接判失败，而是**轮询该用例自己写的
   `results/result_<CASE>_<RUNID>.txt`**（最多等 1500s）：等到了就以用例自身结论为准，
   等不到才判环境失败。

**最终定位（22:00）**：所有 `rc=137` 都发生在**运行 8~10 分钟后**；
528s（9 分钟）的 MB-03 能跑完，801s（13 分钟）的 MB-06 跑不完。
机器侧排除：31G 内存 / 可用 25G / cgroup 无限制 / 无 systemd-oomd / dmesg 与 kern.log 均空。
⇒ 是**发起端 ssh 长连接被回收**导致的远端进程组被杀，**不是被测数据库、也不是机器 OOM**。
在真机上用本地终端或 screen/tmux 直接跑不会出现。

**建议**：批量跑之前先单跑一条确认当轮环境正常；长跑用 `tools/run_detached.sh`
（screen/tmux）或保持 ssh 存活；也可分批判跑（`--only MB-01,MB-03`）。

## 2. 客户端 CLI 的两个硬限制（已固化进写入/校验实现）

- **单条 INSERT ≤ 256KB、每次 CLI 调用 ≤ 4 条语句**；
  超过会：1.6MB/语句 → `SQLException: Cannot get id for statement after reconnecting`；
  1.96MB/语句 → 52s 且静默失败；一次 10MB → 客户端 `OutOfMemoryError`。
- **大结果集查询会被截断**：`select s1 ...` 输出 ~8MB 时只回 1000/2000 行。
  ⇒ 数据量与一致性判据一律改成通配聚合 `select count(s1) from <db>.**`。

## 3. 树方言 SQL 的坑

- 聚合只有 `<db>.**` 通配可用：`from db.d1.s1`、`from db.*.**` 都返回 `Empty set.`；
- `show configuration` 在树方言下语法错误，必须 `-sql_dialect table`。

## 4. 框架脚本的坑

- `clean_env/reset_conf.sh` **不能调用**：`conf_orig` 是 tar 包原始配置（`127.0.0.1` + RF=1），
  还原后集群 CN 互相找不到。本 skill 改为按 `conf/env.conf` 全量生成 conf。
- `prepare_env/start_cluster.sh` 必然打 `801 Authentication failed`（它先用 root/root 改密码，
  本版本口令已是 `TimechoDB@2021`），不影响启动，但会让脚本提前退出，故本 skill 自己起进程。
- `start-datanode.sh` 若在 ssh 里以前台方式执行会把 ssh 挂住（实测卡 18 分钟），
  必须 `sudo setsid nohup ... </dev/null &` + `timeout`。

## 环境侧：后台脚本残留会污染测量（2026-10-22 踩过）

1. **现象**：F-10 复测时，"停某节点后查询为 0"的结论一度不可信。事后定位到一个**已运行 50 分钟**的残留脚本，它在后台反复 `stop-datanode` / `start-datanode`，与测量并发。
2. **根因一（模式匹配不到）**：经 `/tmp/execjob.sh` 下发的脚本，远端进程名是 `bash <skill>/runs/job.sh`，**不是脚本自身的文件名**。用 `pkill -f 'v2_cons.sh'` 会 0 命中，进程继续跑。
3. **根因二（自杀）**：`pkill -f 'runs/job.sh'` 会把**执行载体本身**一起杀掉（当前脚本也是 `job.sh` 的子进程），表现为脚本中途退出、后续清理不执行。
4. **根因三（本地 timeout 杀不掉远端）**：`timeout N ssh ...` 只结束 ssh 客户端，远端 `setsid nohup` 的进程会继续存活。
5. **正确做法**：
   - 用 `bash tools/cleanup_strays.sh` 先看候选（按 **PID + etime** 判断，自动排除自身与祖先，只清超过阈值的残留），确认后 `--force`；
   - 起后台任务后，用 `ps -eo pid,etime,args | grep '[j]ob\.sh'` 确认没有**历史遗留**的 `etime` 很大的进程；
   - 关键实验（如停节点对照）**开始前必须确认无并发脚本**，并在报告里注明该前提。
6. **教训**：任何"按时间观察"的结论（停节点、等刷盘、syncLag）都必须在**单任务独占集群**下取得，否则结论可能完全失真。
