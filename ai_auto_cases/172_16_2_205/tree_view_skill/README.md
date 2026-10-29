# tree_view_skill 使用说明

## 安装到测试机

```bash
# 在跳板机（172.16.2.205）上，把整个目录拷到任意路径即可，路径不写死
scp -r tree_view_skill root@172.16.2.205:/data2/auto_test/
ssh root@172.16.2.205 'cd /data2/auto_test/tree_view_skill && bash tools/suite.sh TV-001'
```

依赖：`bash`、`ssh` 免密到 8 个节点、节点上有 `iptables`（g7 隔离用例用）、`jq` 不需要。

## 配置

所有可变项集中在 `conf/env.conf`，也可用同名环境变量覆盖：

```bash
NEW=master_1026_dc11a35      # 版本安装目录（/data{,1,2}/iotdb/<NEW>）
CN_LIST="172.16.2.26 172.16.2.27 172.16.2.28"
DN_LIST="172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6"
PW=TimechoDB@2021
PROTO=org.apache.iotdb.consensus.iot.IoTConsensus
```

换版本只需 `NEW=<新目录>` 或给 `run_regression.sh` 传参。

## 运行产物

| 路径 | 内容 |
| --- | --- |
| `results/run_<时间戳>/` | 逐用例 `.out`、`_logdelta/`（日志增量与归因）、`results.tsv`、`classified.tsv` |
| `results/REGRESSION_*/` | 一键回归的汇总：`summary.md`、各阶段日志、`show_cluster.txt` |
| `results/fail_logs/<用例ID>/` | FAIL 用例的 CN/DN 日志备份 |

`results/`、`logs/` 不提交到仓库。

## 常用操作

```bash
# 只重建集群（清库 + 按序启动，约 4 分钟）
bash tools/hard_reset.sh

# 跑一组
bash tools/suite.sh TV-080 TV-081 TV-082

# 对某次运行重新归因
bash tools/classify_run.sh results/run_20261028_212543

# 校验用例清单未被改动
cd cases && md5sum -c MANIFEST.md5
```

## 注意事项

1. **`LOAD` 用例**（g9）要求 TsFile 位于**执行该语句的 DataNode** 本地磁盘；用例脚本会自动把文件推到 5 个 DN 的 `/tmp/<db>/load.tsv`，需要节点间 scp 可用（跳板机到各节点免密即可）。
2. **g8 改名用例**会构造 `ALTER TIMESERIES ... RENAME TO` 的 invalid 序列；跑完若残留，用 `SHOW INVALID TIMESERIES` 找 `NewPath` → `DELETE TIMESERIES <NewPath>` 清理，否则源库 `DROP DATABASE` 会被 708/507 拦截（这是预期行为）。
3. **g6/g7 高可用用例**会主动停 DN / CN / 做网络隔离，必须在专用测试集群上跑，日志里出现选主、连接重试类 ERROR 属预期，归因脚本已单列。
