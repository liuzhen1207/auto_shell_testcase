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

## 已覆盖缺陷（2.0.13.1 / ab6d3de 实测）

| 用例 | 来源缺陷单 | 场景 | 结果 |
| --- | --- | --- | --- |
| RN-001~003 | TDB-125 | DN 异常时 GRANT 不超时、权限生效 | PASS |
| RN-101 | TIMECHODB-0684 | GROUP BY + ORDER BY + LIMIT 不得把 limit 下推到聚合之下（d1 count=2） | PASS |
| RN-102 | TIMECHODB-0686 | DELETE 时间区间 min>max 不再返回底层 305，给出语义化错误 | PASS |
| RN-103 | TIMECHODB-0683 | date_bin 空时间区间（time>=2 and time<1）不报 301，返回空结果 | PASS |
| RN-104 | TIMECHODB-0698 | ALTER TIMESERIES 改 encoding/compression 不再报 700 语法错误 | PASS |
| RN-105 | TIMECHODB-0679 | 重复创建用户时 WARN 不打印完整堆栈 | PASS |

| RN-106 | TIMECHODB-0687 | 对齐序列 device 用写入创建后查询不报 ClassCastException 且能查出数据 | PASS |
| RN-107 | TIMECHODB-0670 | 不开三权分立时设置 MAX/MIN_SESSION_PER_USER 不报 NPE | PASS |
| RN-108 | TIMECHODB-0699 | 不支持的 encoding=DICTIONARY(INT32) 返回简洁语义化错误、不带堆栈 | PASS |
| RN-109 | TIMECHODB-0744 | 无 grant option 的普通用户不得把 SYSTEM 转授他人 | PASS |
| RN-110 | TIMECHODB-0423 | 普通用户对不存在 db 路径建 view 不再返回 305 内部错误（改为 803 权限提示） | PASS |

> 数据同步类（pipe / 接收端-发送端）缺陷**未纳入**：需要双环境，205 单集群无法闭环。
