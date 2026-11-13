# LBAC 测试报告（三权分立 模式）

| 项目 | 内容 |
| --- | --- |
| 版本 | 2.0.13.1 / 83183d0（RC2） |
| 模式 | 三权分立 |
| 副本 | Schema 3 / Data 2 |
| 数据面协议 | org.apache.iotdb.consensus.iot.IoTConsensus |
| 用例总数 | 141 |
| 结果目录 | `/data2/auto_test/lbac_results_sep_20261112_165337/run_20261112_165347` |

## 一、总览

| PASS | FAIL | KNOWN | SKIP |
| ---: | ---: | ---: | ---: |
| 139 | 0 | 0 | 2 |

## 二、按模块统计

| 模块 | 用例 | PASS | FAIL | SKIP |
| --- | ---: | ---: | ---: | ---: |
| 一致性 | 2 | 2 | 0 | 0 |
| 写入 | 3 | 2 | 0 | 1 |
| 删除 | 3 | 3 | 0 | 0 |
| 审计 | 2 | 2 | 0 | 0 |
| 并发 | 1 | 1 | 0 | 0 |
| 持久化 | 1 | 1 | 0 | 0 |
| 授权 | 14 | 14 | 0 | 0 |
| 日志 | 1 | 1 | 0 | 0 |
| 更新 | 1 | 1 | 0 | 0 |
| 查询 | 5 | 5 | 0 | 0 |
| 标签 | 11 | 11 | 0 | 0 |
| 比较 | 28 | 28 | 0 | 0 |
| 策略 | 15 | 15 | 0 | 0 |
| 系统表 | 7 | 7 | 0 | 0 |
| 组件 | 20 | 20 | 0 | 0 |
| 绑定 | 12 | 12 | 0 | 0 |
| 缓存 | 2 | 2 | 0 | 0 |
| 视图 | 2 | 1 | 0 | 1 |
| 豁免 | 8 | 8 | 0 | 0 |
| 高可用 | 3 | 3 | 0 | 0 |

## 三、失败与跳过明细

（无失败）

- SKIP **LB-109**：可写视图源为树模型（root.db.**），底层无表级 LBAC 绑定，无法验证；逻辑视图场景见 LB-110
- SKIP **LB-122**：同上（可写视图写入检查）

## 四、日志扫描（CN/DN ERROR + WARN）

- 总计：605 行
```
     30 o.a.i.d.c.IoTDBDescriptor:225 - Cannot find IOTDB_HOME or IOTDB_CONF environment variable when loading config 
      6 o.a.r.g.s.GrpcLogAppender:262 - 3@group-00020000013F->7-GrpcLogAppender: Follower failed (request=null, errorC
      6 o.a.r.g.s.GrpcLogAppender:262 - 0@group-000000000000->2-GrpcLogAppender: Follower failed (request=null, errorC
      6 o.a.r.g.s.GrpcLogAppender:262 - 0@group-000000000000->1-GrpcLogAppender: Follower failed (request=null, errorC
      5 o.a.i.d.c.IoTDBDescriptor:332 - Couldn't load the configuration iotdb-system.properties from any of the known 
      4 o.a.r.g.s.GrpcLogAppender:262 - 5@group-00020000013F->7-GrpcLogAppender: Follower failed (request=null, errorC
      4 o.a.ratis.util.LogUtils:127 - 5: APPEND_ENTRIES onError, lastRequest: null: org.apache.ratis.thirdparty.io.grp
      4 o.a.i.c.p.i.s.AbstractOperateSubscriptionProcedure:268 - ProcedureId 11229: Subscription lock is not acquired,
      4 o.a.i.c.p.i.s.AbstractOperateSubscriptionProcedure:152 - ProcedureId 11229 release lock. No need to release su
      2 o.a.r.s.impl.ServerState:364 - 7@group-0002000000BB: Failed to recognize 3 as leader for APPEND_ENTRIES since 
      2 o.a.r.g.s.GrpcLogAppender$AppendLogResponseHandler:591 - 0@group-000000000000->2-AppendLogResponseHandler: rec
      2 o.a.r.g.s.GrpcLogAppender$AppendLogResponseHandler:583 - 3@group-0002000000BB->7-AppendLogResponseHandler: rec
```
