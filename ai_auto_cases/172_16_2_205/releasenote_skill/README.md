# releasenote_skill 套件使用说明

## 安装到测试机

```bash
scp -r ReleaseNote root@172.16.2.205:/data2/auto_test/
ssh root@172.16.2.205 'cd /data2/auto_test/ReleaseNote && bash tools/run_regression.sh'
```

依赖：`bash`、`ssh` 免密到 3 个 CN + 5 个 DN、`start-cli.sh`（随版本安装包）。

## 配置

`conf/env.conf`（同名环境变量可覆盖）：

```bash
NEW=v20131rc1_1030_ab6d3de
CN_LIST="172.16.2.26 172.16.2.27 172.16.2.28"
DN_LIST="172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6"
HOST=172.16.2.2       # SQL 连接主机；故障注入会避开它
PW=TimechoDB@2021
```

换版本只改 `NEW`（或 `CLI`）。

## 注意事项

1. 用例会 **kill -9 / SIGSTOP** 一台 DataNode，并在结束时恢复；请在专用测试集群执行；
2. 故障注入目标自动选**非 `HOST`** 的 DN（否则 CLI 连不上，测不出授权行为）；
3. 所有 SQL 调用带 `timeout 90` 保护，避免 DN 无响应时用例卡死；
4. 用例文件命名：`cases/TDB_<编号>_v<来源版本>.sh`（不建版本子目录）；
5. 若集群已是异常状态（例如上一轮用例把 DN 停在 STOP），先跑 `tree_view_skill/tools/hard_reset.sh` 重置。