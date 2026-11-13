# LBAC 测试报告（三权分立 模式）

| 项目 | 内容 |
| --- | --- |
| 版本 | 2.0.13.1 / 83183d0（RC2） |
| 模式 | 三权分立 |
| 副本 | Schema 3 / Data 2 |
| 数据面协议 | org.apache.iotdb.consensus.iot.IoTConsensus |
| 用例总数 | 141 |
| 结果目录 | `/data2/auto_test/lbac_results_sep2_20261113_182811/run_20261113_182811` |

## 一、总览

| PASS | FAIL | KNOWN | SKIP |
| ---: | ---: | ---: | ---: |
| 151 | 0 | 0 | 9 |

## 二、按模块统计

| 模块 | 用例 | PASS | FAIL | SKIP |
| --- | ---: | ---: | ---: | ---: |
| 一致性 | 2 | 2 | 0 | 0 |
| 写入 | 3 | 2 | 0 | 1 |
| 删除 | 3 | 3 | 0 | 0 |
| 审计 | 2 | 2 | 0 | 0 |
| 并发 | 1 | 1 | 0 | 0 |
| 持久化 | 1 | 1 | 0 | 0 |
| 授权 | 15 | 15 | 0 | 0 |
| 旁路 | 3 | 0 | 0 | 3 |
| 日志 | 1 | 1 | 0 | 0 |
| 更新 | 1 | 1 | 0 | 0 |
| 权限 | 4 | 3 | 0 | 1 |
| 查询 | 11 | 11 | 0 | 0 |
| 标签 | 11 | 11 | 0 | 0 |
| 比较 | 28 | 28 | 0 | 0 |
| 策略 | 15 | 15 | 0 | 0 |
| 系统表 | 7 | 7 | 0 | 0 |
| 组件 | 20 | 20 | 0 | 0 |
| 绑定 | 17 | 14 | 0 | 3 |
| 缓存 | 2 | 2 | 0 | 0 |
| 视图 | 2 | 1 | 0 | 1 |
| 豁免 | 8 | 8 | 0 | 0 |
| 高可用 | 3 | 3 | 0 | 0 |

## 三、失败与跳过明细

（无失败）

- SKIP **LB-143**：待需求确认：TAG / TIME 列是否允许 SECURED WITH（需求未写，暂不判定）
- SKIP **LB-144**：表模型不支持 RENAME TABLE（RENAME 语法报 700），无法验证
- SKIP **LB-146**：表模型不支持 CREATE TABLE ... AS SELECT / LIKE（语法报 700），无继承路径
- SKIP **LB-154**：待需求确认：同一策略下 READ 与 WRITE 能否授予不同标签
- SKIP **LB-158**：待需求确认：导出链路（EXPORT / SELECT INTO）是否在 LBAC 检查范围
- SKIP **LB-159**：待需求确认：pipe / subscription 写入是否在 LBAC 检查范围
- SKIP **LB-160**：待需求确认：LOAD / 批量导入是否在 LBAC 检查范围
- SKIP **LB-109**：不适用（已确认）：可写视图源为树模型（VIEW FROM TREE），不做 LBAC 保护；逻辑视图场景见 LB-110
- SKIP **LB-122**：同上（可写视图写入检查）

## 四、日志扫描（CN/DN ERROR + WARN）

- 总计：406 行
```
     12 o.a.i.d.c.IoTDBDescriptor:225 - Cannot find IOTDB_HOME or IOTDB_CONF environment variable when loading config 
      6 o.a.r.g.s.GrpcLogAppender:262 - 5@group-0002000001C3->7-GrpcLogAppender: Follower failed (request=null, errorC
      6 o.a.r.g.s.GrpcLogAppender:262 - 0@group-000000000000->2-GrpcLogAppender: Follower failed (request=null, errorC
      6 o.a.r.g.s.GrpcLogAppender:262 - 0@group-000000000000->1-GrpcLogAppender: Follower failed (request=null, errorC
      4 o.a.i.c.p.i.s.AbstractOperateSubscriptionProcedure:268 - ProcedureId 12652: Subscription lock is not acquired,
      4 o.a.i.c.p.i.s.AbstractOperateSubscriptionProcedure:152 - ProcedureId 12652 release lock. No need to release su
      3 o.a.ratis.util.LogUtils:127 - 5: APPEND_ENTRIES onError, lastRequest: null: org.apache.ratis.thirdparty.io.grp
      2 o.a.r.g.s.GrpcLogAppender:262 - 7@group-0002000001B9->5-GrpcLogAppender: Follower failed (request=null, errorC
      2 o.a.r.g.s.GrpcLogAppender:262 - 6@group-0002000000BE->7-GrpcLogAppender: Follower failed (request=null, errorC
      2 o.a.r.g.s.GrpcLogAppender:262 - 4@group-000200000000->5-GrpcLogAppender: Follower failed (request=null, errorC
      2 o.a.i.d.s.d.c.s.CompactionWorker:67 - CompactionThread-9 terminates because interruption 
      2 o.a.i.d.s.d.c.s.CompactionWorker:67 - CompactionThread-8 terminates because interruption 
```
