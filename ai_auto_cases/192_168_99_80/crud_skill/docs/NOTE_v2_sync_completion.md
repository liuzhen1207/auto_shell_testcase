# V2（IoTConsensusV2）"同步完成"的判据：syncLag 归零（必须先 flush）

> 适用：compaction / crud / wal 三个 skill 共用的 `lib/common.sh`（`sync_lag_scan` / `check_sync_lag` / `cons_wait_v2_sync`）。
> 一句话：**V2 下停节点（尤其停 leader）之前，必须 `flush` 之后等 `syncLag` 全部归零**；否则会把"还没成为复制单元的 memtable 尾部"误判成"数据丢失"。

## 1. 判据

| 项 | 内容 |
| --- | --- |
| 指标名 | V2：`iot_consensus_v2`；V1（对照）：`iot_consensus` |
| tag | `type="syncLag"`；V2 另有 `iot_consensus_v2_mode{type="replicateMode"}` |
| 作用域标签 | `cluster="<PROMETHEUS_CLUSTER>"`、`nodeType="DATANODE"`、`instance="<ip>:9092"`、`region="DataRegion[N]"` |
| 判 0 口径 | **至少 1 条 series，且每条都 < 1e-4** |
| 前置动作 | **先 `flush`**（见 §3） |
| 场景有效性 | `iot_consensus_v2_mode{type="replicateMode"} == 2` ⇒ BATCH（1 ⇒ STREAM/LOG，`IoTConsensusV2ServerImpl.java:488-489`） |
| 超时 | 等待归零建议 120s（与官方集成测试一致）；收尾 `check_sync_lag` 用 `SYNC_TIMEOUT_SEC`（默认 600s，连续 `SYNC_STABLE_CHECKS` 次） |

## 2. 两种数据源（lib 里可切换，默认 `auto`）

### 2.1 Prometheus HTTP API（推荐；本环境 99.80:9090 已就绪）

```bash
# 一次查询同时覆盖 V1/V2 的 syncLag（10s 抓取间隔，见 PROM_SCRAPE_INTERVAL）
q='{__name__=~"iot_consensus(_v2)?",type="syncLag",cluster="timecho",nodeType="DATANODE"}'
curl -s -G "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=$q"
# 需要认证时：curl -s -u "$PROMETHEUS_USER:$PROMETHEUS_PASS" -G … --data-urlencode "query=$q"
```

要点：

- 用 `-G --data-urlencode` 就不必手工把 `{`/`"` 编码成 `%7B`/`%22`（等价于
  `…/api/v1/query?query=thrift_connections%7Bcluster%3D%22timecho%22%2Cname%3D%22ClientRPC%22%2CnodeType%3D%22DATANODE%22%7D` 那种写法）；
- 查询结果为空 `data.result=[]` **不等于** "全部为 0"，要报"无数据"（lib 里返回 `-1 -1` / `prom_all_zero` 返回 2）；
- Prometheus 返回的是**最近一次抓取的样本**，且被 stop 的节点在数据过期窗口（默认 5m）内仍能查到旧样本 ⇒
  "**等归零**"可以放心用 Prometheus；"**发现非零**"最坏会晚一个抓取周期（10s）；
- 本环境实测（2026-10-20，RC8/V1 运行中）：`syncLag` 24 条 series 全 0；`thrift_connections{name="ClientRPC"}` 3 条。

### 2.2 直连各 DataNode 的 `/metrics`（无 Prometheus 时的回退，默认也保留）

```bash
curl -s http://192.168.99.77:9092/metrics | grep 'type="syncLag"'
```

即 `dn_metric_prometheus_reporter_port`（默认 9092）；V2 行形如
`iot_consensus_v2{…,name="IoTConsensusV2ServerImpl",region="DataRegion[N]",type="syncLag",} 0.0`。

### 2.3 配置（`conf/env.conf`）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PROMETHEUS_URL` | `http://127.0.0.1:9090`（99.80 上的实例） | 留空 ⇒ 只用直连 |
| `PROMETHEUS_USER` / `PROMETHEUS_PASS` | 空 | 需要 Basic Auth 时填 |
| `PROMETHEUS_CLUSTER` | `${CLUSTER_NAME}`（`timecho`） | PromQL 的 `cluster=` 过滤值 |
| `PROM_SCRAPE_INTERVAL` | `10` | 抓取间隔（决定"发现非零"的最坏延迟） |
| `SYNC_LAG_SOURCE` | `auto` | `auto`（Prometheus 有数据就用，否则直连）/ `prom` / `direct` |

### 2.4 lib 提供的函数（任意用例/门禁可复用）

| 函数 | 用途 |
| --- | --- |
| `prom_healthy` | Prometheus 可达性 |
| `prom_query <promql>` | 原样 JSON |
| `prom_series <promql>` | 每行 `instance value 标签摘要` |
| `prom_values <promql>` | 每行一个数值 |
| `prom_all_zero <promql>` | 0=非空且全 0；1=有非 0；2=无数据/失败 |
| `prom_count_nonzero <promql>` | 非 0 series 数 |
| `prom_wait_all_zero <promql> [超时] [标签]` | 阻塞等到全 0（任意指标门禁，例如 ClientRPC 连接数） |
| `sync_lag_scan` / `check_sync_lag` | syncLag 扫描/等待（`auto` 源，V1/V2 通用） |
| `v2_replicate_mode` | V2 复制模式（2=BATCH） |
| `cons_wait_v2_sync` | 一致性校验前的 V2 同步门禁（flush 后等 syncLag 归零） |

运维自检：`bash tools/probe_prometheus.sh`（在任一 skill 根目录执行）。

## 3. 唯一容易踩的坑：batch 模式只复制**已 seal** 的 TsFile

- `IoTDBDataRegionSource.java:405-458`：`realtime_mode=batch/file` ⇒ 实时源是 `PipeRealtimeDataRegionTsFileSource`；
- `PipeRealtimeDataRegionTsFileSource.java:42-69`：只有 `TsFileInsertionEvent` 进 `pendingQueue`，其它事件直接丢弃（`:59-62`）；
- `ReplicateProgressDataNodeManager.java:59-71` + `IoTConsensusV2AsyncSink.java:862-870`：replicate index 只在 TsFile 事件上递增；
- ⇒ **未 seal 的 memtable 尾部不计入 syncLag**；不 flush 就取到的 0 是"当前没有待复制单元"的空读。

正确顺序：`写入 → flush（等 Async close/seal）→ 等 syncLag 全 0 → 再停节点/判一致性`。

## 4. 官方依据（同一口径）

| 位置 | 内容 |
| --- | --- |
| `integration-test/.../iotconsensusv2/IoTDBIoTConsensusV23C3DBasicITBase.java:810-811` | 正则 `iot_consensus_v2\{[^}]*type="syncLag"[^}]*\}\s+(\S+)` |
| 同上 `:817-848` | `waitForReplicationComplete(leader)`：每条 0.0（容差 0.001）、至少 1 条、超时 120s |
| 同上 `:150-201` | `INSERT ×3` → **`FLUSH`(:158)** → `verifyDataConsistency` → **`waitForReplicationComplete`(:194)** → `stopForcibly()`(:201) |
| `IoTConsensusV2ServerMetrics.java:95-107` | 指标注册（`name="IoTConsensusV2ServerImpl"`、`type="syncLag"`、`region=<groupId>`） |
| `IoTConsensusV2SyncLagManager.java:58-67,99-118` | `syncLag = max(leaderReplicateProgress − followerApplyProgress, 0)`；**无 pipe task 时返回 0**（follower 侧空读，不代表"不能用 syncLag"） |

## 5. 代码里怎么用

```bash
consistency_check "select s1 from root.db.d1 order by time;" tree
#   cons_prep：取基准 → flush + 逐副本可见性轮询 → cons_wait_v2_sync（V2）
#     ├─ 归零 ⇒ CONS_TAIL=0 ⇒ 严格相等（与 V1 一致）
#     └─ 超时 ⇒ WARN + 保留"未 seal 尾部 N 行"容差（带证据，不判数据丢失）
check_sync_lag        # 收尾：等 syncLag 归零（auto 源：Prometheus 优先）
```

可调参数：`CONS_VISIBLE_WAIT`(60) / `CONS_SYNC_WAIT`(120) / `SYNC_TIMEOUT_SEC`(600) / `SYNC_STABLE_CHECKS`(3)。

## 6. 教训

1. 某个节点读到 `syncLag=0` ≠ "已同步"：先问**这个节点有没有可报告的复制进度**（follower 侧恒 0）。
2. 判"复制完成"必须 **flush/seal + syncLag=0** 同时满足。
3. 源码里的"空读分支"不能当成"指标不可用"的理由——先看官方集成测试怎么用。
4. Prometheus 的 `data.result=[]` 要当"无数据"，不能当"全 0"。
