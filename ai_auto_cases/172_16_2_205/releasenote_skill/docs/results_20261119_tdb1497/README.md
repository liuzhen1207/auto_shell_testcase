# TDB-1497 连接数上限报错文案验证（2.0.13.1 RC3 `ac7f95e`）

| 项 | 内容 |
| --- | --- |
| 来源工作项 | TDB-1497 / 【TIMECHODB-0764】数据库客户端连接达到最大值（默认 1000）时新连接处理不合理 |
| 修复提交 | `dd94f472` IoTDBConnection：`Socket is closed by peer` 与 `Connection reset` 一样映射为连接资源不足文案 |
| 验证版本 | 2.0.13.1 **RC3** `ac7f95e`，3C5D（SR3/DR2，IoTConsensus V1） |
| 验证用例 | **RN-209（普通模式）**、**RN-210（三权分立）**，各自独立、每次从 clean reset 开始 |
| 结果 | **2/2 PASS**（2026-11-19 11:41 / 11:47） |

## 一、验证方法

1. `reset_cluster.sh` 干净重建集群（8/8）；
2. `set configuration 'dn_rpc_max_concurrent_client_num'='6'` 并重启 5 个 DN；
3. JDBC 探针：同时持有多个连接直到被拒，检查第 N+1 个连接的 `SQLException` 文案；
4. CLI 探针：占满连接后执行 `show cluster`，检查 CLI 输出文案；
5. 断言：
   - 新连接被拒绝；
   - 报错文案**可识别**（`not enough connection resources available` 或 `Insufficient connection pool resources`）；
   - 报错**不含旧文案** `Check whether the server exists or is alive`；
   - 已达到上限时已有连接仍可查询；
   - 释放一个连接后新连接可恢复。

## 二、实测结果

### RN-209 普通模式

```
HOLD_OK=6
EXTRA_OK=false
EXTRA_MSG=There are not enough connection resources available: Socket is closed by peer.
HAS_OLD_MSG=false   EXISTING_OK=true   AFTER_RELEASE_OK=true
CLI_RC=1
CLI_OUTPUT=Error: Can't execute sql because There are not enough connection resources available: Socket is closed by peer.
```

### RN-210 三权分立

```
HOLD_FAIL_AT=3  MSG=821: Insufficient connection pool resources, please try again later.
EXTRA_OK=false
HAS_OLD_MSG=false   EXISTING_OK=true   AFTER_RELEASE_OK=true
CLI_RC=1
CLI_OUTPUT=Error: Can't execute sql because 821: Insufficient connection pool resources, please try again later.
```

## 三、结论与观察

- **RC3 已修复**：两种模式下新连接的报错都是**可识别**的资源不足提示，旧的误导文案 `Check whether the server exists or is alive` 不再出现；
- 普通模式走 thrift 层 `dn_rpc_max_concurrent_client_num` 限制 → `There are not enough connection resources available: Socket is closed by peer`（本缺陷修复点）；
- 三权分立下先命中 **ConfigNode 会话总量校验**，返回 `821 Insufficient connection pool resources, please try again later.`（同样是清晰文案，且 CLI 前缀为 `Error: Can't execute sql because`）；
- 两模式均验证：已有连接不受影响、释放连接后可恢复，符合“仅拒绝新连接”的预期。

## 四、用例与环境

| 项 | 值 |
| --- | --- |
| 用例文件 | `cases/TIMECHODB_0764_v2.0.13.1.sh`（RN-209 / RN-210） |
| 工具 | `tools/ConnLimitProbe.java`（JDBC 探针）、`tools/cli_conn_probe.sh`（驱动）、`tools/restart_dns.sh`（重启 DN） |
| 驱动脚本 | `tools/run_tdb1497.sh` 等价（服务器 `/tmp/run_tdb1497.sh`），两模式各自 clean reset |
| 结果目录 | `/data2/auto_test/tdb1497_20261119_113557`（RN-209.out / RN-210.out / 结果 TSV） |
