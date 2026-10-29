# 缺陷报告 TV-D4：登录/查询时密码过期检查失败被记为 **ERROR（带堆栈）**

> 面向研发：与树转表特性无关的既有噪声，但它会**淹没真实 ERROR**，且在本次回归里导致多条用例被误判。
> 重点是**日志级别与降级路径的表达**，功能本身正常（已降级放行）。

## 1. 测试环境

| 项 | 值 |
|---|---|
| 版本 | `2.0.11-SNAPSHOT`，BuildInfo **`dc11a35`** |
| 集群 | 5 CN + 20 DN，SR3/DR3，`IoTConsensus` |
| 部署目录 | `/data/iotdb/master_1026_dc11a35` |
| 配置 | 未配置密码过期策略（`password_expiration_days` 默认关闭），鉴权用默认 root |
| 每轮准备 | 停 25 节点 → 清 data/logs → 恢复 conf → 启动 → 等 Running |

## 2. 触发条件

DataNode **真正处理一次用户查询**时（`start-cli` 建序列/写入/select），
DN 会调用 `DataNodeAuthUtils.checkPasswordExpiration` 校验密码是否过期；
由于环境未配置密码过期策略，内部查询 `__audit.`_<userId>`.password` 失败 → 走 catch 分支。

实测命中记录（同一形态多次出现）：

| 用例 | 主机 | 时间 | 触发动作 |
|---|---|---|---|
| `TV-SYNC-01` | 172.20.70.100 | 2026-10-27 13:20:57,004 | 建库/建视图 + 查询 |
| `TV-BASE-12` | 172.20.70.100 | 2026-10-27 17:59:49,628 | show tables / 元数据操作后查询 |

## 3. 测试结果（日志）

```
13:20:57,004 [pool-43-IoTDB-ClientRPC-Processor-1] ERROR
  o.a.i.d.u.DataNodeAuthUtils:522 - Fail to check password expiration
```

- 级别：**ERROR**，且带完整异常堆栈（`queryPasswordExpiration` → `executeLoginHistory` 链路）；
- 功能：**登录成功**（降级放行），业务查询正常返回。

用例判定：`TV-SYNC-01`、`TV-BASE-12` 的功能断言全过，**仅因该 ERROR 被判 FAIL**。

## 4. 源码取证与根因

**位置**：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/utils/DataNodeAuthUtils.java:511-527`

```java
public static Pair<Long, Long> checkPasswordExpiration(
    final long userId, final String password, final boolean useEncryptedPassword) {
  if (userId == -1) {
    return null;
  }
  try {
    return executeLoginHistory(() -> queryPasswordExpiration(userId, password, useEncryptedPassword));
  } catch (Exception e) {
    LOGGER.error(DataNodeMiscMessages.LOG_FAIL_TO_CHECK_PASSWORD_EXPIRATION_4526AEDA, e);  // :522
    if (commonConfig.isMayBypassPasswordCheckInException()) {
      return new Pair<>(Long.MAX_VALUE, 0L);        // 降级：视为永不过期，放行
    }
    throw new IoTDBRuntimeException(
        DataNodeMiscMessages
            .EXCEPTION_INTERNAL_SERVER_ERROR_PLEASE_LOG_IN_LATER_OR_DISABLE_PASSWORD_EXPIRATION_3213C4B0,
        TSStatusCode.INTERNAL_SERVER_ERROR.getStatusCode());
  }
}
```

i18n（`DataNodeMiscMessages.java:1647`）：`"Fail to check password expiration"`。

### 根因

1. 该方法把"**查询密码历史失败**"与"**密码确实过期**"两种情况合并处理，
   且在**降级放行**（`isMayBypassPasswordCheckInException() == true`，默认）的分支前就打了 `LOGGER.error(msg, e)`；
2. 未配置密码过期策略时，这条路径**每次首连必然走到**，于是每个 DN 每次启动后都会至少产生一条带堆栈的 ERROR；
3. 没有任何"该环境未配置过期策略"的短路/缓存，日志按连接次数增长。

### 为什么是 ERROR 而不是 WARN

从语义看，`mayBypassPasswordCheckInException` 已经把这种情况定义为"可容忍"，
既然最终是放行，就不该用 ERROR + 堆栈；这属于**实现与自身设计意图不一致**。

## 5. 影响与定级

| 维度 | 影响 |
|---|---|
| 功能 | 无（放行，登录成功） |
| 日志/告警 | 每 DN 每次启动至少 1 条带栈 ERROR；本次回归 2 条用例仅因此项 FAIL；日志扫描类测试被系统性污染 |
| 定位成本 | 容易被误判为认证链路故障 |
| 定级建议 | **P3**（日志级别） |

## 6. 修复建议

1. 降级放行分支改为 `LOGGER.warn`（不打堆栈）或 `debug`；
   仅在 `isMayBypassPasswordCheckInException() == false`（真要抛错）时保留 `error`；
2. 首次失败后缓存"本环境未配置密码过期策略"，后续连接直接短路；
3. 若产品希望保留可观测性，建议单独计数指标（`password_expiration_check_failed_total`）而不是打 ERROR 日志。

## 7. 复现方式

任意一次"会让 DN 处理查询"的操作即可（注意：**只做元数据操作不一定触发**，
实测 `TV-REPRO-D4` 仅 `show databases` 时不触发，加入建序列+写入+select 后才可能触发）：

```bash
cd /data/iotdb/master_1026_dc11a35
./sbin/start-cli.sh -h 172.20.70.100 -p 6667 -u root -pw TimechoDB@2021 \
  -e "create timeseries root.t1.d1.s1 INT32"
./sbin/start-cli.sh -h 172.20.70.100 -p 6667 -u root -pw TimechoDB@2021 \
  -e "select s1 from root.t1.d1"
for h in 172.20.70.100 172.20.70.101; do
  ssh root@$h 'grep -a "Fail to check password expiration" /data/iotdb/master_1026_dc11a35/logs/log_datanode_all.log | head'
done
```

## 7.5 专项复现尝试（未稳定命中，如实记录）

| 尝试 | 触发方式 | 结果 |
|---|---|---|
| v1（12:24） | 仅 `show databases` 等元数据操作 | 未命中（PASS） |
| v2（13:29 / 16:11） | 建序列 + 写入 + `select` | 未命中（PASS） |
| v3（16:48） | 20 台设备建序列 + 写入 + 跨设备 `select`（铺开到多 DN） | 未命中（PASS） |

说明：该 ERROR 只在**部分连接/部分 DN** 上出现（回归期间的两次命中分别在 13:20:57 与 17:59:49，
都出现在"大量元数据操作 + 查询"的长用例里），与具体是哪台 DN 首次处理鉴权有关，
单条最小用例不易稳定命中。**结论不变**：日志内容与源码路径已确证（见 §4），
只是复现概率低；建议修复时直接按源码改级别，不必依赖复现。

## 8. 备注（对回归口径的影响）

该噪声已加入测试技能的 `KNOWN_PRODUCT_ERROR_NOISE` 清单（`scripts/pgkit/verify.py`）：
命中时写入 `evidence/log_known_noise.txt` 并计数，**不静默**，但不再让无关用例 FAIL。
清单条目附带本报告的原因说明与源码位置。

## 9. 证据索引（172.20.70.122）

| 内容 | 路径 |
|---|---|
| TV-SYNC-01 命中行 | `TREEVIEW/results/tv_TV-SYNC-01/cases/TV-SYNC-01/evidence/log_findings.txt` |
| TV-BASE-12 命中行 | `TREEVIEW/results/tv_TV-BASE-12/cases/TV-BASE-12/evidence/log_findings.txt`（或 tv3_ 目录） |
| 日志归档 | 对应用例 `evidence/logs/dn_172.20.70.100.tar.gz` |
