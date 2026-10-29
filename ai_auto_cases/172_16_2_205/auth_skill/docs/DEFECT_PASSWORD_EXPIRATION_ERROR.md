# 缺陷描述（待确认后登记）：DataNode 启动窗口内登录误报 ERROR「Fail to check password expiration」

> 状态：**未登记**，按你的要求先给研发确认。可直接用作 PLM 缺陷单的标题与描述。
> 关联用例：`auth_skill/cases/g2_policy.sh::AUTH-014`（强制复现版，稳定 FAIL，约 4 分钟）

## 一、建议字段

| 字段 | 建议值 |
| --- | --- |
| 标题 | 【V2.0.12.1】【安全模块-身份鉴别】DataNode 启动窗口内首次登录误报 ERROR「Fail to check password expiration」并打完整 TimeoutException 堆栈 |
| 类型 | 缺陷 |
| 优先级 | **P2**（日志/可观测性缺陷，认证功能不受影响；若按“ERROR 必须为零”的巡检口径则为阻塞项） |
| 严重程度 | 一般 |
| 复现概率 | 必现（强制手法下稳定复现）；自然场景为“DN 重启后首次登录”时概率性出现 |
| 产品名称 / 企业开源 | TimechoDB / TimechoDB |
| 模型 | 通用 |
| 功能模块 | 安全模块-身份鉴别 |
| 问题发现版本 | V2.0.12.1（build c05111d）；同类现象在 2.0.11-SNAPSHOT（dc11a35）上更频繁 |
| 需求来源 | 测试需求 |
| 负责人 / 验证人员 | 待定（研发确认后填） |

## 二、环境

| 项目 | 值 |
| --- | --- |
| 版本 | TimechoDB **2.0.12.1**，BuildInfo **c05111d** |
| 集群 | 3 ConfigNode（172.16.2.26/27/28）+ 5 DataNode（172.16.2.2~6），SchemaRegion 3 副本、DataRegion 2 副本 |
| 客户端 | 172.16.2.205，`start-cli.sh` |
| 相关配置 | 均为默认：`password_expiration_days=0`（未配置有效期）、`fail` 相关未改动；`mayBypassPasswordCheckInException=true`（默认，允许降级放行） |

## 三、复现步骤

**方式 A（最小复现，概率性）**

1. 重启任一 DataNode；
2. 在 DataNode 启动后立即用 `start-cli` 登录（不等 8 节点全部 Running）；
3. 查看该 DN 的 `logs/log_datanode_all.log`：出现 `ERROR o.a.i.d.u.DataNodeAuthUtils:522 - Fail to check password expiration` 与完整堆栈，而随后紧接 `Login successfully`。

**方式 B（强制复现，稳定）**

1. 停掉全部 5 个 DataNode（`stop-datanode.sh` + `kill -9`）；
2. 同时启动 5 个 DataNode；
3. 在启动的同时，用循环不断发起登录（每秒 2~3 次），持续约 60 秒；
4. 统计各 DN 日志中该字符串的增量——至少一个 DN 新增 1 条以上。

> 方式 B 已固化为用例 `AUTH-014`：`bash tools/suite_auth.sh AUTH-014`，命中即判 FAIL。

## 四、实际现象

日志原文（172.16.2.2，2026-10-29 12:32:59；该 DN 于 12:32:58 启动）：

```
2026-10-29 12:32:59,576 [pool-51-IoTDB-ClientRPC-Processor-1] ERROR o.a.i.d.u.DataNodeAuthUtils:522 - Fail to check password expiration
java.util.concurrent.TimeoutException
        at java.base/java.util.concurrent.FutureTask.get(FutureTask.java:204)
        at org.apache.iotdb.db.utils.DataNodeAuthUtils.executeLoginHistory(DataNodeAuthUtils.java:108)
        at org.apache.iotdb.db.utils.DataNodeAuthUtils.checkPasswordExpiration(DataNodeAuthUtils.java:519)
        at org.apache.iotdb.db.protocol.session.SessionManager.login(SessionManager.java:170)
        at org.apache.iotdb.db.protocol.thrift.impl.ClientRPCServiceImpl.openSession(ClientRPCServiceImpl.java:1763)
        at org.apache.iotdb.service.rpc.thrift.IClientRPCService$Processor$openSession.getResult(IClientRPCService.java:5065)
        at org.apache.iotdb.service.rpc.thrift.IClientRPCService$Processor$openSession.getResult(IClientRPCService.java:5037)
        at org.apache.thrift.ProcessFunction.process(ProcessFunction.java:40)
        at org.apache.iotdb.db.protocol.thrift.ProcessorWithMetrics.process(ProcessorWithMetrics.java:66)
        at org.apache.thrift.server.TThreadPoolServer$WorkerProcess.run(TThreadPoolServer.java:264)
        ...
2026-10-29 12:32:59,580 [pool-51-IoTDB-ClientRPC-Processor-1] INFO  o.a.i.d.a.LoginLockManager:112 - Login lock manager initialized with: IP-level attempts=5, User-level attempts=1000, Lock time=10 minutes
2026-10-29 12:32:59,591 [pool-51-IoTDB-ClientRPC-Processor-1] INFO  o.a.i.d.p.s.SessionManager:343 - IoTDB: Login status: Login successfully. User : root, opens Session-1-root:172.16.2.205:43276
```

要点：

1. 异常是 **`TimeoutException`**（登录历史/密码过期查询超时），不是“用户不存在”或“未配置过期策略”这类业务失败；
2. 同一个登录请求**随后登录成功**（`Login successfully`），说明代码走了降级放行分支；
3. 但降级**之前**已按 ERROR 把异常连同完整堆栈写入日志；
4. 频率：该 DN 日志本轮共 3 条（均为启动窗口内产生），稳态运行期间 0 条。

## 五、期望结果

1. 认证功能不受影响时（降级放行），日志级别应为 **WARN**，且**不带异常堆栈**（最多一行摘要），或按配置可关闭；
2. 若判定为需要感知的异常，应只对“确实无法校验且不放行”的情形记 ERROR；
3. 稳态运行、以及单纯重启 DataNode 后首次登录，不应产生 ERROR 级日志。

## 六、根因分析

```java
// DataNodeAuthUtils.java:79
private static final long VISIT_HISTORY_QUERY_TIMEOUT_IN_MS = 500L;   // 仅 500ms

// :108  executeLoginHistory
return future.get(VISIT_HISTORY_QUERY_TIMEOUT_IN_MS, TimeUnit.MILLISECONDS);

// :519-527  checkPasswordExpiration
try {
  return executeLoginHistory(() -> queryPasswordExpiration(userId, password, useEncryptedPassword));
} catch (Exception e) {
  LOGGER.error(LOG_FAIL_TO_CHECK_PASSWORD_EXPIRATION_4526AEDA, e);      // ← 先记 ERROR + 堆栈
  if (commonConfig.isMayBypassPasswordCheckInException()) {             // ← 再判断是否降级放行
    return new Pair<>(Long.MAX_VALUE, 0L);                              // 默认 true → 放行
  }
  throw new IoTDBRuntimeException(...);
}
```

1. **超时窗口过紧**：登录历史/密码过期查询固定 500ms 超时；DataNode 刚启动、`__audit` 相关 schema/数据尚未就绪时，首次查询超过 500ms 即抛 `TimeoutException`；
2. **日志与降级顺序颠倒**：`LOGGER.error(msg, e)` 在 `isMayBypassPasswordCheckInException()` 判断**之前**执行，于是“可容忍并放行”的路径也留下 ERROR 与堆栈；
3. 缺少针对启动期的重试/短路：没有任何“首次失败后短暂重试”或“启动期已知未就绪则跳过”的处理，因此每次 DN 启动都可能留一条 ERROR；
4. 与设计意图不一致：`mayBypassPasswordCheckInException` 的语义即“允许放行”，说明场景被定义为可容忍，但日志级别是 ERROR。

> 与最初反馈的差异：原描述为“未配置密码过期策略 → 每次查询都失败 → 每次都打印”。在本版本（c05111d）**不是**每次连接都触发，稳态为 0 条，实际触发点是 **DN 启动窗口内的首次登录超时**。较早的 2.0.11-SNAPSHOT（dc11a35）构建上确实观察到更高频的同类 ERROR，建议缺陷单按“影响版本”分别描述。

## 七、影响面

1. **可观测性**：每个 DataNode 启动后都可能留下一条带完整堆栈的 ERROR，巡检/日志告警误报，排查真实认证故障时产生噪声；
2. **验收口径**：安全模块通常要求“运行期无 ERROR 日志”，该现象会直接导致验收不通过；
3. **功能**：无影响——登录成功、业务查询正常（降级放行）；
4. **性能**：每 500ms 超时一次，仅在启动窗口，影响可忽略。

## 八、修复建议

| 方案 | 内容 | 评价 |
| --- | --- | --- |
| A（推荐） | 把 `LOGGER.error` 移到降级判断之后：放行分支记 **WARN 且不带堆栈**，只有不放行才记 ERROR | 改动最小、语义最准 |
| B | 对启动期超时做一次重试（例如 3 × 500ms），重试仍失败再按 A 处理 | 消除启动窗口误报 |
| C | 放宽/可配 `VISIT_HISTORY_QUERY_TIMEOUT_IN_MS`（如 3000ms），并在 DN 未就绪时短路跳过校验 | 需评估对登录延迟的影响 |
| D | 明确 `mayBypassPasswordCheckInException=false` 时的行为与文档（此时 ERROR 合理，但应给出可操作提示） | 文档/产品口径 |

建议 A + B 组合；C 作为可选。

## 九、证据

| 内容 | 位置 |
| --- | --- |
| 用例 | `ai_auto_cases/172_16_2_205/auth_skill/cases/g2_policy.sh` → `AUTH-014` |
| 稳定复现 | `bash tools/suite_auth.sh AUTH-014` → FAIL（约 4 分钟），输出内含上述堆栈 |
| 日志 | 172.16.2.2 `/data1/iotdb/v20121rc12_1027_c05111d/logs/log_datanode_all.log`（12:04、12:32、13:2x 各一次） |
| 测试报告 | `auth_skill/docs/AUTH_TEST_REPORT.md` §4 |

## 十、备注

1. 同批次还发现 5 项待确认观察（用户枚举 804/801 可区分、错误码 701/820 不统一、未授权读返回空集、UNLOCK 仅用户级、最小长度 12 未写入需求），见测试报告 §5，**未作为缺陷**；
2. 本单建议只覆盖“降级放行仍记 ERROR + 堆栈”这一条，便于研发快速定位与修复验证。
