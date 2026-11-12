# LBAC 测试报告（普通模式 模式）

| 项目 | 内容 |
| --- | --- |
| 版本 | 2.0.13.1 / 83183d0（RC2） |
| 模式 | 普通模式 |
| 副本 | Schema 3 / Data 2 |
| 数据面协议 | org.apache.iotdb.consensus.iot.IoTConsensus |
| 用例总数 | 141 |
| 结果目录 | `/data2/auto_test/lbac_results_normal_20261112_140357/run_20261112_140357` |

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

- 总计：549 行
```
      6 o.a.r.g.s.GrpcLogAppender:262 - 6@group-000200000082->7-GrpcLogAppender: Follower failed (request=null, errorC
      6 o.a.r.g.s.GrpcLogAppender:262 - 4@group-000200000082->7-GrpcLogAppender: Follower failed (request=null, errorC
      6 o.a.r.g.s.GrpcLogAppender:262 - 4@group-000200000000->5-GrpcLogAppender: Follower failed (request=null, errorC
      6 o.a.r.g.s.GrpcLogAppender:262 - 3@group-000200000000->5-GrpcLogAppender: Follower failed (request=null, errorC
      6 o.a.r.g.s.GrpcLogAppender:262 - 0@group-000000000000->1-GrpcLogAppender: Follower failed (request=null, errorC
      5 o.a.r.g.s.GrpcLogAppender:262 - 0@group-000000000000->2-GrpcLogAppender: Follower failed (request=null, errorC
      3 o.a.ratis.util.LogUtils:127 - 5: APPEND_ENTRIES onError, lastRequest: null: org.apache.ratis.thirdparty.io.grp
      2 o.a.r.g.s.GrpcLogAppender:262 - 5@group-0002000000A9->7-GrpcLogAppender: Follower failed (request=null, errorC
      2 o.a.r.g.s.GrpcLogAppender:262 - 3@group-00020000009F->5-GrpcLogAppender: Follower failed (request=null, errorC
      2 o.a.ratis.util.LogUtils:127 - 5: Failed APPEND_ENTRIES request 3->5#1-t1,previous=<PROTO_DEFAULT>,leaderCommit
      2 o.a.i.d.s.d.c.s.CompactionWorker:67 - CompactionThread-9 terminates because interruption 
      2 o.a.i.d.s.d.c.s.CompactionWorker:67 - CompactionThread-8 terminates because interruption 
```
