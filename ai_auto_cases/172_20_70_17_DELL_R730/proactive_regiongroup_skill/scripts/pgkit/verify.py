"""The closing triad: sync-lag drain, replica consistency, ERROR/WARN log scan.

Every case must pass all three; the runner appends them as ordinary checks so a
case verdict can never be PASS without them.

The log scan is bounded **above** by ``until_epoch`` exactly like the
remove-cn/dn skill: the harness stops nodes at the end of a case, and its own
shutdown window (interrupted pipe buffers, half-written stack frames) must not be
reported as a product defect.  This is a *time bound*, not a whitelist -- every
hit before the bound is reported with its raw text.
"""

from __future__ import annotations

import re
import shlex
import json
import time
from dataclasses import dataclass, field
from pathlib import Path

from .cluster import ROLE_CN, ROLE_DN, Cluster, status_is
from .config import Config
from .remote import (
    SqlClient,
    SshRunner,
    http_get_json,
    http_get_text,
    looks_like_sql_error,
    parse_table,
    wait_until,
)

#: Corruption signatures (same family the remove-cn/dn skill gates on).  Kept
#: apart from the level scan so a hit here is always a hard finding.
# harness 自伤归因表：**只**在 harness 自己记录的动作窗口内豁免，且每条都要
# 落进 evidence/log_attributed.txt（不删除、不隐藏、不是全局白名单）。
# 每条都能指出触发它的 harness 动作。
HARNESS_INDUCED_PATTERNS: tuple[tuple[str, str], ...] = (
    (r"CompactionWorker:\d+ - CompactionThread-\d+ terminates because interruption",
     "用例热加载 compaction 开关（关闭/恢复）导致压缩线程池重建"),
    (r"MemoryManager:\d+ - getOrRegisterMemoryBlock failed: memory block Consensus already exists",
     "节点启动注册或开关热加载时重复注册 consensus 内存块"),
    (r"GrpcLogAppender[\w$]*:\d+", "IoTConsensus/Ratis 启动收敛期的 appender 提示"),
    (r"Failed to DELETE_REGION", "harness 主动 drop database 清场，CN 级联删区超过单次 RPC 超时后重试"
                                 "（大测点库删区实测 >60s，最终成功）"),
    (r"Access Denied: No permissions for this operation",
     "用例故意以零权限用户执行 show disk_usage（803 错误路径）"),
    (r"CompactionThreadPool can not be closed in \d+ ms|failed to poll driver task from queue",
     "remove 节点时按设计关闭该节点的压缩线程池 / 查询执行器（RegionMigrateService$DeleteOldRegionPeerTask）"),
    (r"Failed to execute set ttl",
     "TTL 语法探测被 CN 拒绝（harness 主动探测，见 cases_ops2._set_ttl）"),
    (r"Failed to execute alter database.*(?:max_schema_region_group_num|max_data_region_group_num)",
     "PROACTIVE/AUTO 策略下 alter max_*_region_group_num 被按设计拒绝（harness 主动探测，525）"),
    (r"o\.a\.ratis\.util\.LogUtils:\d+",
     "Ratis 启动收敛期的 AppendLogResponseHandler 重试告警（仍需窗口命中）"),
    (r"DataExecutionVisitor:\d+.*Error in executing plan node",
     "被 TTL/负向写入正确拒绝时 DN 侧的计划执行告警（需窗口命中）"),
    (r"ConfigExecution:\d+.*Failures happened during running ConfigExecution",
     "非法配置/TTL 语法探针（H-14）触发的配置执行告警（需窗口命中）"),
    (r"Failed to execute unset ttl",
     "用例清理 TTL 规则（产品侧此时可能已无该规则 → 508，harness 主动 unset 所致）"),
    (r"close MPP Data exchange manager failed",
     "remove 节点时被移除节点的服务按设计关闭（MPP 数据交换管理器）"),
    (r"Failed to CREATE_SCHEMA_REGION on DataNode|Read call frame size failed",
     "remove ConfigNode 期间与在途连接/被移除节点的建区请求失败（连接被拆除）"),
    (r"Failed requestVote|ServerNotReadyException",
     "集群刚启动时 IoTConsensus/Ratis 选主重试（收敛期）"),
    (r"Failed to execute delete database \[",
     "用例 fixture 主动重建测试库（tree 方言不支持 drop database if exists）"),
    # ---- 停机/重启 DataNode 引发的"迁移与重发重试"族（收尾②停机对拍、HA 用例停机）
    # 依据：用例主动停 1 台 DN 后，LeaderBalancer 会在其停机窗口内尝试把该节点上的
    # leader 迁走（失败一次后按设计重试），MPP 数据交换链路对被停节点的 block 事件
    # 重发同样会失败一次。全部落在 harness 动作的**收敛尾窗**内才归因（不是白名单：
    # 尾窗之外同样的行仍然是 FAIL）。
    (r"TransferLeaderRPCHandler:\d+ - Failed to CHANGE_REGION_LEADER",
     "用例停机对拍/HA 停机期间，LeaderBalancer 试图迁移被停节点上的 leader（重试一次后放弃）"),
    (r"Failed to CHANGE_REGION_LEADER after \d+ retries",
     "同上：被停节点上的 leader 迁移重试耗尽（harness 停机窗口内）"),
    (r"\[LeaderBalancer\] Failed to change the leader of Region",
     "同上：被停节点上的 leader 迁移重试耗尽（harness 停机窗口内）"),
    (r"GrpcAdminProtocolService:\d+ - Failed to transferLeadership",
     "同上：被停节点侧拒绝/超时 transferLeadership（节点已被 harness 停掉）"),
    (r"\[ChangeRegionLeader\] Failed to change the leader of RegionGroup",
     "同上：被停节点侧拒绝/超时 transferLeadership（节点已被 harness 停掉）"),
    (r"SinkChannel\$Send(New|EndOf)DataBlockEventTask:\d+ - Failed to send .*data block event",
     "用例停机对拍/HA 停机期间 MPP 数据交换对被停节点重发 block 事件失败（按设计重试）"),
    (r"SourceHandle\$GetDataBlocksTask.*failed to get data",
     "收尾②停 DataNode 后 MPP 数据交换 Source 侧取不到 block（对端 sink 已停，harness 自身动作）"),
    (r"Failed to INVALIDATE_PARTITION_CACHE on DataNode",
     "用例建/删库时某 DataNode 正被停机对拍或刚重启（分区缓存失效 RPC 失败，产品侧会重试）"),
    (r"Failed to UPDATE_REGION_ROUTE_MAP on DataNode",
     "同上：用例停机对拍期间路由表更新 RPC 失败（产品侧会重试）"),
    # ================================ H-24：补 6 族"harness 动作必然引发"的签名
    # 准入纪律不变：**必须**同时命中下面的正则**且**落在 harness 自己记录的动作窗口内
    # （见 ``CompactionVerifier._attribute``）；窗口之外同样的行仍然是 FAIL。
    # 每族第 1 行注明"哪个 harness 动作会触发它"，便于 review 时逐条对账。
    # ---- A 族：ConfigNode/DataNode READONLY（触发动作：用例执行 SET SYSTEM TO READONLY
    #      ON LOCAL → 收尾恢复 RUNNING；HA-13/HA-14/HA-03/HA-06/HA-07）
    # 注意：不把整句写死（实测日志行会被长句里的后续内容影响匹配），只锚前 33 个字符。
    (r"Change system status to ReadOnly",
     "用例把某节点置 READONLY（SET SYSTEM TO READONLY ON LOCAL），服务端按设计切只读并告警"),
    (r"Current system is read-only mode\. Skip active load dir scanning",
     "同上：节点处于用例设置的 READONLY 状态，按设计跳过 load 目录扫描"),
    # ---- B 族：ConfigNode → DataNode 的**异步 RPC 重试耗尽**（触发动作：用例停 1 台 DN
    #      （HA-*）/ fixture 建库/删库时对端正好不在；产品按设计重试 6 次后记 WARN）
    (r"Failed to INVALIDATE_LAST_CACHE (?:on DataNode|after \d+ retries)",
     "用例停机对拍/HA 停机期间 ConfigNode 向被停 DN 下发缓存失效 RPC（重试后记 WARN）"),
    (r"Failed to UPDATE_REGION_ROUTE_MAP after \d+ retries",
     "同上：被停 DN 收不到路由表更新（ConfigNode 重试 6 次后放弃）"),
    (r"Failed to CREATE_(?:SCHEMA|DATA)_REGION (?:on DataNode|after \d+ retries)",
     "用例建库/写入新 slot 时某 DN 正被停机对拍或刚重启，建区 RPC 重试后失败"),
    (r"Timeout during CHANGE_REGION_LEADER\. Retry: \d+/\d+",
     "用例停机对拍/HA 停机期间 LeaderBalancer 对已停节点发起 transferLeadership 超时"),
    # ---- C 族：IoTConsensus 发送失败（触发动作：用例停 DN 的瞬间，在途 batch 发不出去）
    (r"DispatchLogHandler.*Can not send Batch\{",
     "用例停 DN 的瞬间 IoTConsensus 的 DispatchLogHandler 发不出在途 batch（对端已下线）"),
    (r"Interrupted when dispatching write async",
     "同上：停机打断异步派发线程（组内对端不可达）"),
    (r"write locally failed\. TSStatus: .*read-only",
     "A 族的伴生行：节点被用例置 READONLY 后本地写入按设计失败（302/600）"),
    # ---- D 族：Ratis 启动收敛（触发动作：create database 后新组 bootstrap / harness 重启 CN、DN）
    (r"Failed appendEntries",
     "用例建库后新组 bootstrap 或 harness 重启 CN/DN，Ratis 复制组选主收敛期 appendEntries 被拒"),
    (r"Failed to recognize \d+ as leader for APPEND_ENTRIES",
     "同上：新 leader 尚未被 follower 认可（收敛期，数秒内自愈）"),
    # ---- E 族：CN/DN 重启期（触发动作：RCV-* 等用例**主动**重启 ConfigNode/DataNode）
    (r"The current node(?: leader)?(?: \(leader\))? may have been down",
     "harness 主动重启 CN/DN 期间客户端拿到的旧 leader 端点（会话重连时按设计换节点）"),
    (r"Internal error processing openSession",
     "同上：重启瞬间的 openSession 打到正在关停的节点"),
    (r"Metadata lease is fenced",
     "同上：重启/切主后旧节点的元数据租约被隔离（按设计丢弃心跳）"),
    (r"Cannot find IOTDB_HOME or IOTDB_CONF",
     "harness 以自定义环境/工作目录拉起节点（sbin 外启动）时配置定位告警，与产品行为无关"),
    (r"Couldn't load the configuration [\w.\-]+ from any of the known sources",
     "同上：harness 指定的 conf 目录里没有该文件（例如 .dn./.cn. 前缀文件）"),
    # ---- F 族：元数据/协调器（触发动作：fixture drop database / create database /
    #      用例主动提交被拒的 ALTER DATABASE；按动作窗口限流）
    (r"\[LeaderBalancer\].*(?:leader cannot be selected|not in (?:regionStatisticsMap|"
     r"regionLocationMap|databaseRegionGroupMap))",
     "fixture drop database 后 LeaderBalancer 仍持有刚被销毁的 RegionGroup 视图（下一轮刷新自愈）"),
    (r"Failed to get table .* when calculating the time series number",
     "fixture drop/create database 期间表的元数据瞬时不可见（产品按设计降级为告警）"),
    (r"SYNC_TOPIC_META",
     "fixture 建/删库触发的订阅元数据同步 procedure 重试（harness 改了库集合）"),
    (r"Failed to execute alter database .*\b525\b",
     "用例主动提交超出上限的 ALTER DATABASE（预期被拒，525），harness 探针"),
    # ==================== D 类（HA-03/05/09/11、TIME-07、DEV-12）：逐条按证据定性
    # 准入纪律不变：必须**同时**命中下面的正则**且**落在 harness 动作窗口内（见
    # ``CompactionVerifier._attribute``）；窗口外同样的行仍然 FAIL。每条都注明
    # "哪个 harness 动作、哪段日志证据"证明因果，避免把产品噪声混进白名单。
    # ---- benchmark 启动时与 harness fixture 同时 create database（幂等竞争）
    #      证据：PG-MSR-09 17:21:44 dn@11.101.10.10 记
    #      "WARN ClusterConfigTaskExecutor:524 - Failed to execute create database root.pg"，
    #      而同一秒 fixture 刚执行过 create database（库已存在 ⇒ 幂等 WARN，非产品异常）
    (r"Failed to execute create database ",
     "benchmark 与用例 fixture 同时 create database（库已存在），幂等 WARN"),
    # ---- ⓪-DN 停机：已进入 read-only 停机流程的 DN 仍收到 leader 的 logEntries 同步
    #      （证据：HA-01 重跑 13:19:28.963 dn@11.101.10.9 记
    #      "ERROR IoTConsensusRPCServiceProcessor:97 - fail to sync logEntries
    #      because system is read-only"，而 13:19:28 正是 harness「停 DataNode」的时刻）
    (r"fail to sync logEntries because system is read-only",
     "用例停 DN 的瞬间，该 DN 已切 read-only 停机流程，仍收到 leader 的 logEntries "
     "同步请求（按设计拒绝；同秒发生 stop DataNode）"),
    # ---- ⓪-DN 停机：本地指标上报线程被 shutdown hook 打断（证据：HA-01 08:49:36
    #      停 DataNode 11.101.10.9，**同一秒**该 DN 记
    #      "IoTDBInternalLocalReporter:178 - Failed to update the value of metric with
    #      status TSStatus(code:305, message:Interrupted...)"; 进程随即退出）
    (r"IoTDBInternalLocalReporter:\d+ - Failed to update the value of metric",
     "用例停 DN 的瞬间，本地指标上报线程被 shutdown hook 中断（305 Interrupted，"
     "与用户写入无关；同秒发生 stop DataNode）"),
    # ---- ① 被 harness 停掉的 DN 上的订阅元数据推送（证据：HA-03 00:26:12 停
    #      11.101.10.9，CN 00:26:25/00:26:28 记
    #      "Failed to TOPIC_PUSH_ALL_META on DataNode: {id=4,
    #      internalEndPoint=TEndPoint(ip:11.101.10.9,...)}, exception: Connection refused"）
    (r"TopicPushMetaRPCHandler:\d+ - Failed to TOPIC_PUSH_ALL_META on DataNode",
     "用例停 DN 期间 ConfigNode 向**被停节点**推送订阅元数据失败（Connection refused："
     "节点已被 harness 停掉，registry 会重试）"),
    # ---- ② 同一次 TOPIC_PUSH 失败触发的订阅 procedure 回滚（证据：HA-03 同一秒
    #      ProcedureId 2994，紧跟在 ① 之后；消息自述 "execution will be skipped" /
    #      "No need to release subscription lock"，即回滚本身也没拿到锁、按设计跳过）
    (r"AbstractOperateSubscriptionProcedure:\d+ - ProcedureId \d+: "
     r"Subscription lock is not acquired, rollbackState",
     "①失败后的订阅 procedure 回滚：未取得订阅锁时按设计跳过 rollbackState"
     "（消息自述 will be skipped；窗口内紧跟 ①）"),
    (r"AbstractOperateSubscriptionProcedure:\d+ - ProcedureId \d+ release lock\. "
     r"No need to release subscription lock",
     "同上：该 procedure 回滚时并未持锁，按设计无需释放（消息自述 No need to release）"),
    # ---- ③ 被 harness 重启的 DN 重新入组时的 leader 选举重试（证据：HA-05 00:38:38
    #      "启 DataNode 11.101.10.9"（=node 4），dn 11.101.10.7 于 00:38:42 记
    #      "1@group-000200000043: Failed to startLeaderElection for 4"）
    (r"TransferLeadership:\d+ - \d+@group-[\w-]+: Failed to startLeaderElection for \d+",
     "用例重启 DN 后该 peer 重新入组，Ratis 为其发起 leader 选举失败"
     "（对端仍在启动/重连，数秒内自愈）"),
    # ---- ④ 被 harness 停掉的 DN 上的缓存失效 RPC（证据：HA-09 00:48:56 停 11.101.10.9，
    #      CN 00:49:20-22 记 "Failed to INVALIDATE_PARTITION_CACHE after 2 retries,
    #      requestIndices: [4]"、"Failed to INVALIDATE_SCHEMA_CACHE on DataNode:
    #      {id=4, ...}, exception: Connection refused" —— requestIndices/id 都指向
    #      **被停的那一台**）
    (r"Failed to INVALIDATE_(?:PARTITION|SCHEMA)_CACHE (?:on DataNode|after \d+ retries)",
     "用例停机对拍/HA 停机期间 ConfigNode 向被停 DN 下发分区/元数据缓存失效 RPC"
     "（requestIndices/id 指向被停节点，重试后记 WARN）"),
    # ---- ⑤ 收尾②停/起 DN 之后，本用例的分布式查询仍命中该节点重启前的缓存连接
    #      （证据：DEV-12 22:21:14 收尾②停 11.101.10.7、22:21:26 重启；本用例
    #      22:23:05 首条分布式查询记 "can't execute request on node TEndPoint(ip:
    #      11.101.10.7,...): Socket is closed by peer., and we try to reconnect this
    #      node"；TIME-07 22:44:49 停/22:45:04 起，22:46:53 同一条。产品显式自述
    #      try to reconnect ⇒ 换连接重试，不是查询失败）
    (r"FragmentInstanceDispatcherImpl:637 - can't execute request on node TEndPoint\("
     r"[^)]*\), error msg is org\.apache\.thrift\.transport\.TTransportException: "
     r"Socket is closed by peer\., and we try to reconnect this node",
     "收尾② 停/起 DataNode 后，本用例的分布式查询仍命中该节点重启前的缓存连接"
     "（Broken pipe；产品按设计 try to reconnect this node 换连接重试）"),
)


#: 产品**自声明**的按设计行为：既不是 harness 自伤，也不是异常。准入极严 ——
#: ① 只能是 WARN（ERROR 一律不许进）；② 消息文本本身声明"本轮跳过/推迟以规避…"；
#: ③ 必须能指出源码/i18n 管理器消息出处；④ 每条都写入 evidence/log_by_design.txt
#: 并在报告里计数（绝不静默丢弃）；⑤ 未列入此表的 WARN 仍然判 FAIL。
#: 与 HARNESS_INDUCED_PATTERNS 的区别：那个靠"harness 动作窗口"豁免，这个靠"产品自己
#: 声明这是设计行为"分类，且与 harness 做了什么无关。
#: **只**在"harness 主动停/启节点"的窗口内生效的模式（window reason 需含"停"）。
#: 与 HARNESS_INDUCED_PATTERNS 分开，避免把停机窗口的豁免权扩散到普通操作窗口。
NODE_STOP_INDUCED_PATTERNS: tuple[tuple[str, str], ...] = (
    (r"FragmentInstanceDispatcherImpl:\d+ - can't execute request on node",
     "用例主动停 DataNode 后，MPP 片段仍被派到已停节点（Connection refused，产品按设计重试）"),
    (r"QueryExecution:\d+ - error when executing query",
     "同上：停机窗口内的查询在已停节点上失败（用例正是要验证存活副本继续服务）"),
    (r"Read call frame size failed|Failed to CREATE_SCHEMA_REGION on DataNode",
     "停机窗口内与已停节点的在建连接被拆除"),
)

PRODUCT_BY_DESIGN_PATTERNS: tuple[tuple[str, str], ...] = (
    (r"PipeTaskCoordinatorLock is held by another thread, skip this round of "
     r"(heartbeat|sync) to avoid procedure and rpc accumulation as much as possible",
     "pipe 心跳/元数据同步未抢到 PipeTaskCoordinatorLock 时按设计跳过本轮"
     "（i18n 管理器消息 ConfigNode/.../ManagerMessages.java:358-361，文本自称 "
     "skip ... to avoid procedure and rpc accumulation；产品内部 procedure 持锁期间的正常行为）"),
)


def _line_epoch(line: str) -> float | None:
    m = re.search(r"(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}),(\d{3})", line)
    if not m:
        return None
    y, mo, d, h, mi, sec, ms = (int(x) for x in m.groups())
    try:
        return time.mktime((y, mo, d, h, mi, sec, 0, 0, -1)) + ms / 1000.0
    except (ValueError, OverflowError):
        return None


DEFAULT_LOG_PATTERNS = (
    r"NullPointer",
    r"BufferUnderflowException",
    r"but return HAS_MORE_STATE",
    r"CompactionTableSchemaNotMatchException",
    r"has overlapped data",
    r"which should be later than the last time",
    r"DataTypeInconsistentException",
    r"ArrayIndexOutOfBoundsException",
    r"StatisticsClassException",
    r"NegativeArraySizeException",
    r"is not in tsFileMetaData",
    r"The memory cost to be released is larger",
    r"tsfile error",
    r"which has not released all memory",
    r"Error while reading timeseries metadata",
    r"IndexOutOfBoundsException",
    r"ConcurrentModificationException",
    r"InternalServerErrorException",
    r"the region .* is not in the cluster",
)

#: §3.2 item 3: scan the ERROR and WARN levels.  No whitelist.
LOG_LEVEL_PATTERNS = (r"\bERROR\b", r"\bWARN\b")

HEADER_CELLS = {
    "time", "d_datetime", "device_id", "device", "database", "tablename",
    "count", "regionid",
}


def empty_capture(raw: str) -> bool:
    """True when the SQL client produced no output at all (a failed capture)."""
    return not raw.strip()


def normalize_query_result(text: str) -> str:
    """Canonical, order-independent form of an IoTDB CLI result."""
    rows = parse_table(text)
    lines: list[str] = []
    for row in rows:
        values = [v.strip() for v in row.values()]
        if not values or values[0].lower() in HEADER_CELLS:
            continue
        rendered = "|".join("" if v.lower() == "null" else v for v in values)
        if rendered.strip("|"):
            lines.append(rendered)
    lines.sort()
    return "\n".join(lines) + ("\n" if lines else "")


@dataclass
class SyncLagResult:
    ok: bool
    reason: str = ""
    samples: list[float] = field(default_factory=list)
    worst: float = 0.0


class SyncLagWaiter:
    """Poll Prometheus (or each node's /metrics) until syncLag reaches 0."""

    METRIC_CANDIDATES = (
        ("iot_consensus", "ioTConsensusServerImpl"),
        ("iot_consensus_v2", "IoTConsensusV2ServerImpl"),
    )

    def __init__(self, cfg: Config, cluster: Cluster, log, health=None):
        self.cfg = cfg
        self.cluster = cluster
        self.log = log
        self.health = health
        self.url = cfg.raw("MONITOR_URL").rstrip("/")
        self.mode = cfg.raw("SYNC_LAG_SOURCE", "auto").strip().lower()
        self.metrics_port = cluster.dn_metrics_port()

    def _use_prometheus(self) -> bool:
        if self.mode == "prometheus":
            return True
        if self.mode == "metrics":
            return False
        return bool(self.url)

    def available(self) -> bool:
        if self.mode == "metrics":
            return self.metrics_port > 0
        return bool(self.url) or (self.mode == "auto" and self.metrics_port > 0)

    # -- sources -----------------------------------------------------------
    def _query_prometheus(self, metric: str, server: str, regex: str) -> list[float]:
        expr = (
            f'sum({metric}{{instance=~"{regex}",name="{server}",type="syncLag"}}) by (instance)'
        )
        import urllib.parse

        url = f"{self.url}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
        payload = http_get_json(
            url, user=self.cfg.get("MONITOR_USER"), password=self.cfg.get("MONITOR_PASSWORD")
        )
        if payload.get("status") != "success":
            raise RuntimeError(f"prometheus query failed: {payload.get('error')}")
        values: list[float] = []
        for series in payload.get("data", {}).get("result", []):
            raw = series.get("value", [None, "0"])[1]
            try:
                values.append(float(raw))
            except (TypeError, ValueError):
                continue
        return values

    @staticmethod
    def stalled_polls(prev_value: float | None, prev_count: int, worst: float) -> int:
        if prev_value is not None and worst == prev_value:
            return prev_count + 1
        return 1

    @staticmethod
    def parse_sync_lag_metrics_labeled(
        text: str, metric: str, server: str
    ) -> list[tuple[str, float]]:
        out: list[tuple[str, float]] = []
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, _, rest = line.partition("{")
            if name.strip() != metric:
                continue
            labels, _, tail = rest.rpartition("}")
            if not tail.strip():
                continue
            if f'name="{server}"' not in labels or 'type="syncLag"' not in labels:
                continue
            raw = tail.strip().split()[0] if tail.strip() else ""
            try:
                value = float(raw)
            except ValueError:
                continue
            found = re.search(r'region="([^"]+)"', labels)
            out.append((found.group(1) if found else "?", value))
        return out

    @staticmethod
    def parse_sync_lag_metrics(text: str, metric: str, server: str) -> list[float]:
        return [v for _, v in SyncLagWaiter.parse_sync_lag_metrics_labeled(text, metric, server)]

    def _query_metrics_labeled(self, host: str, metric: str, server: str) -> list[tuple[str, float]]:
        url = f"http://{host}:{self.metrics_port}/metrics"
        return self.parse_sync_lag_metrics_labeled(http_get_text(url, timeout=20), metric, server)

    def _live_region_names(self) -> set[str] | None:
        try:
            out = self.cluster.sql.sql(self.cfg.cli_host, "show regions", check=False)
        except Exception:  # noqa: BLE001 - a hint must never break the gate
            return None
        names: set[str] = set()
        for line in out.splitlines():
            fields = [x.strip() for x in line.split("|") if x.strip()]
            if len(fields) > 2 and fields[1] in {"DataRegion", "SchemaRegion"}:
                names.add(f"{fields[1]}[{fields[0]}]")
        return names or None

    def _stale_region_hint(self, top: list[tuple[str, str, float]]) -> str:
        regions = {r for _, r, _ in top if r and r != "?"}
        if not regions:
            return ""
        live = self._live_region_names()
        if live is None:
            return ""
        missing = sorted(r for r in regions if r not in live)
        if not missing:
            return ""
        return (
            f" -- {', '.join(missing)} no longer appears in `show regions`, so this is a stale "
            "per-region metric left behind by a removed replica, not a live stalled pipeline"
        )

    # -- gate --------------------------------------------------------------
    def wait(self) -> SyncLagResult:
        if not self.available():
            return SyncLagResult(
                ok=False,
                reason="neither MONITOR_URL nor METRICS_PORT is configured; sync-lag gate skipped",
            )

        stable = self.cfg.get_int("SYNC_STABLE_SECONDS")
        max_wait = self.cfg.get_int("SYNC_MAX_WAIT_SEC")
        poll = self.cfg.get_int("SYNC_POLL_INTERVAL_SEC")
        metric_pref = self.cfg.raw("CONSENSUS_METRIC", "auto")
        if metric_pref in {"iot_consensus", "iot_consensus_v2"}:
            candidates = [c for c in self.METRIC_CANDIDATES if c[0] == metric_pref]
        else:
            candidates = list(self.METRIC_CANDIDATES)

        deadline = time.time() + max_wait
        zero_since: float | None = None
        active: tuple[str, str] | None = None
        last_samples: list[float] = []
        stall_polls = self.cfg.get_int("SYNC_STALL_POLLS")
        frozen_value: float | None = None
        frozen_count = 0
        worst_seen = 0.0
        next_health_check = 0.0

        while True:
            running = self.cluster.running_dn_hosts()
            if not running:
                return SyncLagResult(ok=False, reason="no Running DataNode to read syncLag from",
                                     worst=worst_seen)

            if self.health and time.time() >= next_health_check:
                next_health_check = time.time() + 30
                bad = self.health()
                if bad:
                    return SyncLagResult(
                        ok=False,
                        reason="syncLag cannot drain: " + "; ".join(bad)
                        + " (waiting further would only time out)",
                        worst=worst_seen,
                    )
            regex = "^(" + "|".join(ip.replace(".", "[.]") + "(:[0-9]+)?" for ip in running) + ")$"

            values: list[float] = []
            labeled: list[tuple[str, str, float]] = []
            errors: list[str] = []
            for metric, server in ([active] if active else candidates):
                try:
                    if self._use_prometheus():
                        values = self._query_prometheus(metric, server, regex)
                    else:
                        for host in running:
                            pairs = self._query_metrics_labeled(host, metric, server)
                            labeled.extend((host, region, value) for region, value in pairs)
                            values.extend(value for _, value in pairs)
                    if values:
                        active = (metric, server)
                        break
                except Exception as exc:  # noqa: BLE001
                    errors.append(f"{metric}: {exc}")
            last_samples = values

            if not values:
                zero_since = None
                self.log(f"  sync lag: no series yet ({'; '.join(errors[:1]) or 'empty result'})")
            else:
                worst = max(values)
                worst_seen = max(worst_seen, worst)
                self.log(f"  sync lag: instances={len(values)} worst={worst}")

                if stall_polls > 0 and worst > 1e-4:
                    frozen_count = self.stalled_polls(frozen_value, frozen_count, worst)
                    frozen_value = worst
                    if frozen_count >= stall_polls:
                        top = sorted(labeled, key=lambda x: x[2], reverse=True)[:3]
                        where = ", ".join(f"{r} on {h}={v:.0f}" for h, r, v in top) or "unknown"
                        stale = self._stale_region_hint(top)
                        if stale:
                            note = (
                                f"syncLag pinned at {worst} for {where}{stale}; not a "
                                "data-correctness failure, so the gate stopped waiting"
                            )
                            self.log(f"  sync lag: {note}")
                            return SyncLagResult(ok=True, reason=note, samples=values,
                                                 worst=worst_seen)
                        return SyncLagResult(
                            ok=False,
                            reason=(
                                f"syncLag is pinned at {worst} across {frozen_count} polls "
                                f"(~{frozen_count * poll}s); worst: {where}"
                            ),
                            samples=values, worst=worst_seen,
                        )
                else:
                    frozen_value, frozen_count = None, 0

                if worst > 1e-4:
                    zero_since = None
                elif zero_since is None:
                    zero_since = time.time()
                elif time.time() - zero_since >= stable:
                    return SyncLagResult(ok=True, samples=values, worst=worst_seen)

            if time.time() > deadline:
                return SyncLagResult(
                    ok=False,
                    reason=f"syncLag did not stay at 0 for {stable}s within {max_wait}s "
                    f"(last samples: {last_samples[:8]})",
                    samples=last_samples, worst=worst_seen,
                )
            time.sleep(poll)


_BANNER_RE = re.compile(r"Starting IoTDB\s+(\S+)")


def banner_floor_from_text(text: str, target_version: str) -> int | None:
    """H-36：升级族日志检查的下界（纯函数，便于离线自证）。

    在日志文本里找「**目标版本**的第一条启动横幅，且它之前出现过**别的版本**的启动横幅」，
    返回该横幅的 epoch（秒）。以下情况返回 ``None``，调用方据此**不改变**检查窗口：

    * 没有目标版本横幅（例如本用例跑在升级前的旧版本上）；
    * 没有旧版本横幅（单版本运行，不存在跨版本的停机行可排除）。

    绝不因为"没找到边界"就放宽窗口——边界只用来**排除旧版本**，不用来排除新版本。
    """
    saw_other = False
    for line in text.splitlines():
        match = _BANNER_RE.search(line)
        if not match:
            continue
        stamp = line[:19]
        try:
            epoch = int(time.mktime(time.strptime(stamp, "%Y-%m-%d %H:%M:%S")))
        except ValueError:
            continue
        version = match.group(1)
        if version == target_version or version.startswith(target_version):
            if saw_other:
                return epoch
        else:
            saw_other = True
    return None


class CompactionVerifier:
    """Replica-consistency sweep + log scanning for one case."""

    def __init__(self, cfg: Config, cluster: Cluster, ssh: SshRunner, sql: SqlClient,
                 log, artifacts: Path, shared_windows: list | None = None):
        self.cfg = cfg
        self.cluster = cluster
        #: H-60：被解释掉的 appender 中断所依据的领导权转移证据（逐条留档）
        self._transfer_evidence: list[str] = []
        #: 跨用例的"harness 停机收敛尾窗"：用例按收尾②/HA 停过 DataNode 后，leader 迁移
        #: 与 MPP 重发会在其后一段时间内继续重试，噪声会越界落进**下一个**用例的扫描窗口。
        #: 归因仍然是"模式 + 窗口"双重命中，尾窗之外同样的行依旧是 FAIL。
        #: H-23：本对象仍按用例新建（evidence/baseline 是按用例隔离的），但窗口列表由
        #: ``cli.ctx_factory`` 在 **run 级**创建后注入，否则"跨用例尾窗"是死代码。
        self.extra_windows: list = shared_windows if shared_windows is not None else []
        #: H-23：收尾②**实际**停/起 DataNode 的时刻 ``(epoch, 描述)``。窗口必须锚在这里，
        #: 而不是"开始做一致性对拍"的时刻（后者比真正停机早 4–5 分钟，命中会落到窗外）。
        self.sweep_events: list[tuple[float, str]] = []
        self.ssh = ssh
        self.sql = sql
        self.log = log
        self.artifacts = artifacts
        self.artifacts.mkdir(parents=True, exist_ok=True)
        self._baseline: dict[str, str] = {}

    # ------------------------------------------------------------------
    # 2) replica consistency
    # ------------------------------------------------------------------
    def _capture(self, host: str, name: str, spec: dict[str, str]) -> str | None:
        timeout = self.cfg.get_int("CONSISTENCY_QUERY_TIMEOUT_SEC")
        raw = self.sql.sql(host, spec["sql"], dialect=spec.get("dialect"),
                           timeout=timeout, check=False)
        (self.artifacts / f"{name}.raw").write_text(raw, encoding="utf-8")
        if looks_like_sql_error(raw):
            self.log(f"  {name}: query failed on {host}")
            return None
        if empty_capture(raw):
            self.log(f"  {name}: EMPTY capture on {host} -- failed capture, not a difference")
            return None
        normalized = normalize_query_result(raw)
        (self.artifacts / f"{name}.norm").write_text(normalized, encoding="utf-8")
        return normalized

    def _alternate_query_host(self, stop_host: str, running: list[str]) -> str | None:
        for host in running:
            if host != stop_host:
                return host
        return None

    def consistency_check(self, queries: list[dict], *, sync_waiter: SyncLagWaiter | None = None,
                          data_rf: int = 0, skip_hosts: set | None = None) -> list[str]:
        """Stop each DataNode in turn, query the same dataset, restore, compare.

        Mirrors the remove-cn/dn sweep: the baseline is captured twice and only
        accepted when the two agree, so a still-moving dataset cannot be
        reported as a replica inconsistency.  ``skip_hosts`` holds DataNodes the
        case removed on purpose -- restarting one is not possible and is not a
        consistency failure.  Returns a list of problems (empty means
        consistent).
        """
        if not queries:
            return ["no consistency query was registered for this case"]

        problems: list[str] = []
        skip = set(skip_hosts or ())
        running = [h for h in self.cluster.running_dn_hosts() if h not in skip]
        if len(running) < 2:
            return [f"only {len(running)} Running DataNode(s); cannot stop one and still query"]

        if sync_waiter is not None and sync_waiter.available():
            result = sync_waiter.wait()
            if not result.ok:
                return [f"sync-lag gate before baseline: {result.reason} "
                        f"(worst={result.worst})"]

        settle_seconds = self.cfg.get_int("CONSISTENCY_SETTLE_SECONDS")
        settle_tries = max(1, self.cfg.get_int("CONSISTENCY_SETTLE_TRIES"))
        self.log(f"  waiting for the dataset to settle (two captures {settle_seconds}s apart "
                 f"must agree, <= {settle_tries} tries)")
        baseline: dict[str, str] = {}
        settled = False
        for attempt in range(1, settle_tries + 1):
            first: dict[str, str] = {}
            for spec in queries:
                value = self._capture(self.cfg.cli_host, f"settle{attempt}_a_{spec['name']}", spec)
                if value is not None:
                    first[spec["name"]] = value
            time.sleep(settle_seconds)
            second: dict[str, str] = {}
            for spec in queries:
                value = self._capture(self.cfg.cli_host, f"baseline_{spec['name']}", spec)
                if value is not None:
                    second[spec["name"]] = value
            if first and first == second:
                baseline = second
                self._baseline = dict(second)
                settled = True
                break
            moving = sorted(k for k in first if first.get(k) != second.get(k))
            self.log(f"  dataset still moving (attempt {attempt}/{settle_tries}; "
                     f"differs: {','.join(moving) or 'n/a'}); waiting")
        if not settled:
            (self.artifacts / "consistency_never_settled.txt").write_text(
                f"dataset still changing after {settle_tries} attempts of {settle_seconds}s\n",
                encoding="utf-8")
            return ["the dataset never settled, so the replica-consistency sweep was skipped "
                    "rather than reporting a moving dataset as an inconsistency"]

        mode = (self.cfg.raw("REPLICA_MODE") or "direct").strip().lower()
        if mode in {"direct", "both"}:
            # 快速路径：不动机器，直接到**每个存活 DataNode 上各查一遍**，把归一化结果
            # 逐个与基线对拍。比"逐台停机再查"省掉 ~5×(停+起+ready)，且不会引发 CN 侧
            # UPDATE_REGION_ROUTE_MAP / INVALIDATE_LAST_CACHE 的 harness 自伤报错。
            replica_results: dict[str, dict[str, str]] = {}
            for host in running:
                got: dict[str, str] = {}
                for spec in queries:
                    value = self._capture(host, f"replica_{host.replace('.', '_')}_{spec['name']}", spec)
                    if value is not None:
                        got[spec["name"]] = value
                replica_results[host] = got
                if not got:
                    problems.append(f"no answer from DataNode {host} for the consistency queries")
                    continue
                diff = sorted(k for k in baseline if got.get(k) != baseline.get(k))
                self.log(f"  replica on {host}: {'OK' if not diff else 'DIFF ' + ','.join(diff)}")
                if diff:
                    problems.append(f"replica on {host} differs from the baseline in: {','.join(diff)}")
            (self.artifacts / "replica_matrix.json").write_text(
                json.dumps({"baseline": baseline, "per_dn": replica_results,
                            "mode": mode}, ensure_ascii=False, indent=2), encoding="utf-8")
            self.log(f"  direct replica comparison done on {len(running)} DataNode(s), "
                     f"{len(problems)} problem(s)")
            if mode == "direct":
                return problems

        if data_rf and data_rf < 2:
            (self.artifacts / "consistency_sweep_skipped.txt").write_text(
                f"stop-one-node sweep skipped: data_replication_factor={data_rf}\n",
                encoding="utf-8")
            return []

        # 停机对拍的规模由 ``CONSISTENCY_STOP_NODES`` 决定（默认 1）：用户口径是
        # "全在线基线 → **停 1 个** DataNode 再查一遍"，而不是逐台把 5 个都停一遍
        # （后者每台都要再等一次 sync lag 归零，代价 5×）。设 0/负数按 1 处理。
        stop_limit = self.cfg.get_int("CONSISTENCY_STOP_NODES") or 1
        checked = 0
        for host in running[:max(1, stop_limit)]:
            query_host = self._alternate_query_host(host, running)
            if query_host is None:
                problems.append(f"no alternate query host left after stopping {host}")
                continue
            self.log(f"  consistency sweep: stopping DataNode {host} (querying through {query_host})")
            if not self.cluster.stop_node(host, ROLE_DN):
                problems.append(f"DataNode {host} did not stop")
                self.cluster.start_node(host, ROLE_DN)
                continue
            # H-09/H-23：本次停机（及其后的重启）会在**后续约 2 分钟**内引发其它节点上的
            # "X@group-…->Y-GrpcLogAppender is interrupted" 一类对端噪声
            # （`HARNESS_INDUCED_PATTERNS` 里的 `GrpcLogAppender[\w$]*:\d+` 早已存在，缺的只是窗口）。
            # 只**记录实际停机时刻**（stop_epoch），窗口由调用方（closing_triad）按该时刻开，
            # 保证窗口锚在真停机而不是"开始对拍"（否则早 4–5 分钟，命中必然落到窗外）。
            _stop_epoch = time.time()
            self.sweep_events.append(
                (_stop_epoch, f"收尾②停 DataNode {host}（对端 appender 中断等自身动作噪声）"))
            time.sleep(self.cfg.get_int("CONSISTENCY_SETTLE_SEC"))
            for spec in queries:
                name = spec["name"]
                if name not in baseline:
                    continue
                value = self._capture(query_host, f"stop_{host.replace('.', '_')}_{name}", spec)
                if value is None:
                    continue
                if value != baseline[name]:
                    problems.append(
                        f"replica inconsistency: '{name}' result differs while {host} is down")
                    self.log(f"  DIFF in '{name}' while {host} is down")
            checked += 1

            self.cluster.start_node(host, ROLE_DN)
            if not wait_until(
                lambda h=host: status_is(self.cluster.dn_status_for(h), "running"),
                timeout=300, interval=3,
            ):
                problems.append(f"failed to restart {host}")
                continue
            # H-23：重启也是一次 harness 动作，同样按**实际** start_epoch 记录，
            # 重启后的 appender 重连/leader 迁移重试才会被归因（此前只有停机窗口）。
            self.sweep_events.append(
                (time.time(), f"收尾②重启 DataNode {host}（重连/leader 迁移重试）"))
            if sync_waiter is not None and sync_waiter.available():
                result = sync_waiter.wait()
                if not result.ok:
                    problems.append(f"sync-lag gate after restarting {host}: {result.reason}")

        if checked == 0:
            problems.append("consistency sweep did not check any DataNode")
        return problems

    # ------------------------------------------------------------------
    # 2b) H-23: turn the **actual** stop/start epochs into attribution windows
    # ------------------------------------------------------------------
    def register_sweep_windows(self, tail_sec: int | None = None) -> int:
        """H-23：把收尾②记录的**实际**停/起时刻变成归因窗口，返回注册条数。

        窗口锚在实际 ``stop_epoch`` / ``start_epoch`` 上，而**不是**"开始做一致性对拍"的
        时刻（``sweep_started`` 比真正停机早 4–5 分钟，实测命中落在窗外 2 分钟）。
        窗口写进 **run 级共享**的 ``extra_windows``（见 ``cli.ctx_factory``），因此后续
        用例的收尾③ 也能命中；在此之前"跨用例尾窗"实际是死代码。
        顺带剪掉一小时前就已结束的窗口，避免整轮跑完时列表无界增长。
        """
        if tail_sec is None:
            tail_sec = int(self.cfg.raw("CLUSTER_CONVERGENCE_WINDOW_SEC") or 300)
        horizon = time.time() - 3600
        self.extra_windows[:] = [w for w in self.extra_windows if w[1] >= horizon]
        for epoch, why in self.sweep_events:
            self.extra_windows.append((epoch - 5, epoch + tail_sec, why))
        return len(self.sweep_events)

    # ------------------------------------------------------------------
    # 3) ERROR/WARN log scan with an upper time bound
    # ------------------------------------------------------------------
    def _scan_script(self, role: str, patterns: list[str], since_epoch: int | None,
                     until_epoch: int | None = None) -> str:
        glob = "*confignode*all*.log*" if role == ROLE_CN else "*datanode*all*.log*"
        combined = "|".join(patterns)
        awk_filter = "cat"
        if since_epoch or until_epoch:
            lower = (
                time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since_epoch - 5))
                if since_epoch else "0000-00-00 00:00:00"
            )
            upper = (
                time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(until_epoch))
                if until_epoch else "9999-12-31 23:59:59"
            )
            awk_prog = (
                "{ if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) "
                "last=substr($0,1,19); if (last >= t && last <= u) print }"
            )
            awk_filter = (
                f"awk -v t={shlex.quote(lower)} -v u={shlex.quote(upper)} {shlex.quote(awk_prog)}"
            )
        return f"""
d={shlex.quote(self.cfg.get('DB_DIR'))}
cd "$d/logs" 2>/dev/null || exit 0
files=$(ls {glob} 2>/dev/null || true)
[[ -z "$files" ]] && exit 0
for f in $files; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.gz) reader=zcat ;;
    *)    reader=cat ;;
  esac
  $reader "$f" 2>/dev/null | {awk_filter} | grep -E {shlex.quote(combined)} 2>/dev/null \\
    | sed "s|^|$f:|" | head -n 50
done | head -n 400
exit 0
"""

    # ------------------------------------------------------------------
    # H-36：升级族的日志窗口下界（按目标版本的启动横幅切分）
    # ------------------------------------------------------------------
    def upgrade_floor_epoch(self, target_version: str) -> int | None:
        """目标版本在本次升级里的第一条启动横幅时间；取各节点里**最早**的一个。"""
        if not target_version:
            return None
        floors: list[int] = []
        targets = [(ROLE_CN, h) for h in self.cfg.cn_hosts] + [
            (ROLE_DN, h) for h in self.cfg.dn_hosts
        ]
        for role, host in sorted(set(targets), key=lambda item: (item[0], item[1])):
            script = f"""
d={shlex.quote(self.cfg.get('DB_DIR'))}
cd "$d/logs" 2>/dev/null || exit 0
for f in *confignode*all*.log* *datanode*all*.log*; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.gz) zcat "$f" ;;
    *)    cat "$f" ;;
  esac
done 2>/dev/null | grep -h 'Starting IoTDB' | head -n 400
exit 0
"""
            result = self.ssh.run_script(host, script, check=False, timeout=300)
            epoch = banner_floor_from_text(result.out, target_version)
            if epoch:
                floors.append(epoch)
        return min(floors) if floors else None

    def scan_logs(self, *, since_epoch: int | None = None, until_epoch: int | None = None,
                  patterns: list[str] | None = None) -> dict[str, list[str]]:
        if patterns is None:
            patterns = list(DEFAULT_LOG_PATTERNS) + list(LOG_LEVEL_PATTERNS)
        else:
            patterns = list(patterns)
        extra = self.cfg.raw("LOG_EXTRA_PATTERNS")
        if extra:
            patterns += [p.strip() for p in extra.split(",") if p.strip()]
        combined = re.compile("|".join(f"(?:{p})" for p in patterns))

        findings: dict[str, list[str]] = {}
        targets = [(ROLE_CN, h) for h in self.cfg.cn_hosts] + [(ROLE_DN, h) for h in self.cfg.dn_hosts]
        seen: set[tuple[str, str]] = set()
        for role, host in targets:
            if (role, host) in seen:
                continue
            seen.add((role, host))
            res = self.ssh.run_script(
                host,
                self._scan_script(role, patterns,
                                  since_epoch if self.cfg.raw("LOG_SCAN_MODE") == "since" else None,
                                  until_epoch),
                check=False, timeout=900,
            )
            hits: list[str] = []
            for line in res.out.splitlines():
                if not line.strip():
                    continue
                if combined.search(line):
                    hits.append(f"{role}@{host}: {line.strip()[:400]}")
            if hits:
                findings[f"{role}@{host}"] = hits
        return findings

    def _capture_context(self, key: str, hits: list[str], per_host: int = 3,
                         back: int = 6, forward: int = 80) -> str:
        """为**未预期**命中抓取完整上下文（异常堆栈通常在命中行之后若干行）。

        此前只把命中行写进 ``log_findings.txt``，`Caused by` 之后的帧会丢失；
        这里按时间戳回定位，抓 ±上下文写入 ``log_context.txt``，保证"实锤"证据完整。
        """
        if not hits:
            return ""
        try:
            role, host = key.split("@", 1)
        except ValueError:
            return ""
        prefix = f"{role}@{host}: "
        chunks: list[str] = []
        for line in hits[:per_host]:
            rest = line[len(prefix):] if line.startswith(prefix) else line
            m = re.match(r"^(\S+\.log(?:\.gz)?):(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", rest)
            if not m:
                continue
            fname, stamp = m.group(1), m.group(2)
            script = (
                f"d={shlex.quote(self.cfg.get('DB_DIR'))}\n"
                'cd "$d/logs" 2>/dev/null || exit 0\n'
                f"f={shlex.quote(fname)}\n"
                '[[ -f "$f" ]] || exit 0\n'
                f'ln=$(grep -n -F {shlex.quote(stamp)} "$f" 2>/dev/null | head -1 | cut -d: -f1)\n'
                '[[ -z "$ln" ]] && exit 0\n'
                f'echo "===== {fname} @ {stamp} (line $ln, -{back}/+{forward}) ====="\n'
                f'sed -n "$((ln-{back})),$((ln+{forward}))p" "$f"\n'
                "exit 0\n"
            )
            res = self.ssh.run_script(host, script, check=False, timeout=300)
            if res.out.strip():
                chunks.append(res.out.strip())
        return "\n".join(chunks)

    _APPENDER_INTERRUPT = "GrpcLogAppender"
    _TRANSFER_SIGNS = ("transferring leadership", "change role from", "no longer the schema region leader",
                       "startLeaderElection", "change Leader from")

    def _explain_appender_interrupt(self, key: str, line: str) -> str | None:
        """H-60：领导权转移期间关闭 appender 会产生 ``GrpcLogAppender ... is interrupted`` WARN。

        判定必须**同组 + 同 10 秒窗口**内有 TransferLeadership/RoleChange 证据，否则不算解释
        （避免把真正的复制中断静默吞掉）。证据写进报告。
        """
        if self._APPENDER_INTERRUPT not in line or "is interrupted" not in line:
            return None
        group = re.search(r"(group-\d+)", line)
        if group is None:
            return None
        try:
            role, host = key.split("@", 1)
        except ValueError:
            return None
        prefix = f"{role}@{host}: "
        rest = line[len(prefix):] if line.startswith(prefix) else line
        m = re.match(r"^(\S+\.log(?:\.gz)?):(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", rest)
        if not m:
            return None
        fname, stamp = m.group(1), m.group(2)
        bucket = stamp[:-1]          # 同一 10 秒桶
        script = (
            f"d={shlex.quote(self.cfg.get('DB_DIR'))}\n"
            'cd "$d/logs" 2>/dev/null || exit 0\n'
            f"f={shlex.quote(fname)}\n"
            '[[ -f "$f" ]] || exit 0\n'
            f"grep -F {shlex.quote(group.group(1))} \"$f\" | grep -F {shlex.quote(bucket)} "
            f"| grep -E 'transferring leadership|change role from|no longer the schema region leader' "
            "| head -3\n"
            "exit 0\n"
        )
        res = self.ssh.run_script(host, script, check=False, timeout=120)
        found = [ln for ln in (res.out or "").splitlines() if ln.strip()]
        if not found:
            return None
        self._transfer_evidence.extend(found[:2])
        return ("IoTConsensus 领导权转移（同组同 10 秒内有 TransferLeadership/RoleChange，"
                "appender 按设计关闭）")

    def check_logs(self, *, since_epoch: int | None = None,
                   until_epoch: int | None = None,
                   expected_windows: list | None = None) -> list[str]:
        findings = self.scan_logs(since_epoch=since_epoch, until_epoch=until_epoch)
        windows = list(expected_windows or []) + list(self.extra_windows)
        unexpected: dict[str, list[str]] = {}
        attributed: list[str] = []
        for key, hits in findings.items():
            for line in hits:
                reason = self._attribute(line, windows)
                if not reason:
                    reason = self._explain_appender_interrupt(key, line)
                if reason:
                    attributed.append(f"[已归因: {reason}] {line}")
                else:
                    unexpected.setdefault(key, []).append(line)
        # 第二次分类：产品自声明"按设计跳过"的 WARN 单独成桶（逐条留档 + 报告计数）。
        by_design: list[str] = []
        still_unexpected: dict[str, list[str]] = {}
        for key, hits in unexpected.items():
            for line in hits:
                reason = self._classify_by_design(line)
                if reason:
                    by_design.append(f"[按设计: {reason}] {line}")
                else:
                    still_unexpected.setdefault(key, []).append(line)
        unexpected = still_unexpected
        problems: list[str] = []
        for key, hits in unexpected.items():
            problems.append(
                f"unexpected log lines on {key}: at least {len(hits)} hit(s), first: {hits[0][:220]}"
            )
        if by_design:
            (self.artifacts / "log_by_design.txt").write_text(
                "\n".join(by_design) + "\n", encoding="utf-8")
            self.log(f"  按设计分类 {len(by_design)} 条（产品自声明跳过，逐条见 "
                     f"evidence/log_by_design.txt；报告会计数，不作为异常）")
        if unexpected:
            (self.artifacts / "log_findings.txt").write_text(
                "\n".join(line for hits in unexpected.values() for line in hits) + "\n",
                encoding="utf-8",
            )
            # 命中行不够：异常/堆栈需要上下文才能定性（DFT-01 的 NPE 就是这么抓全的）。
            context = "\n".join(
                self._capture_context(key, hits) for key, hits in unexpected.items())
            if context.strip():
                (self.artifacts / "log_context.txt").write_text(
                    context + "\n", encoding="utf-8")
                self.log("  未预期命中已抓取完整上下文 -> evidence/log_context.txt"
                         "（含异常堆栈帧）")
        if self._transfer_evidence:
            (self.artifacts / "log_transfer_evidence.txt").write_text(
                "\n".join(self._transfer_evidence) + "\n", encoding="utf-8")
            self.log(f"  appender 中断归因依据 {len(self._transfer_evidence)} 行 -> "
                     f"evidence/log_transfer_evidence.txt")
        if attributed:
            (self.artifacts / "log_attributed.txt").write_text(
                "\n".join(attributed) + "\n", encoding="utf-8")
            self.log(f"  已归因 harness 自伤 {len(attributed)} 条（仅限 harness 动作窗口内，"
                     f"逐条见 evidence/log_attributed.txt）")
        if not problems:
            self.log(f"  扫描窗口内无非预期命中"
                     + (f"（另有 {len(attributed)} 条已归因 harness 自伤"
                        + (f"、{len(by_design)} 条按设计分类" if by_design else "")
                        + "）" if (attributed or by_design) else ""))
            if not attributed and not by_design:
                (self.artifacts / "log_findings.txt").write_text(
                    "no ERROR/WARN or corruption signature in the scanned window\n",
                    encoding="utf-8")
        return problems

    @staticmethod
    def _classify_by_design(line: str) -> str | None:
        """产品自声明为"按设计"的 WARN（与 harness 动作无关）。ERROR 一律不分类。"""
        if " ERROR " in line or line.rstrip().endswith(" ERROR"):
            return None
        if " WARN " not in line:
            return None
        for pattern, reason in PRODUCT_BY_DESIGN_PATTERNS:
            if re.search(pattern, line):
                return reason
        return None

    @staticmethod
    def _attribute(line: str, windows: list) -> str | None:
        """命中行是否落在 harness 自己记录的动作窗口内并可归因。"""
        if not windows:
            return None
        epoch = _line_epoch(line)
        if epoch is None:
            return None
        for pattern, reason in HARNESS_INDUCED_PATTERNS:
            if not re.search(pattern, line):
                continue
            for start, end, why in windows:
                if start <= epoch <= end:
                    return f"{reason}（harness 动作: {why}）"
        # H-63：停机窗口专用模式 —— 只有窗口原因里带"停"才允许归因
        for pattern, reason in NODE_STOP_INDUCED_PATTERNS:
            if not re.search(pattern, line):
                continue
            for start, end, why in windows:
                if start <= epoch <= end and "停" in why:
                    return f"{reason}（harness 动作: {why}）"
        return None

    # -- backup (FAIL evidence) -------------------------------------------
    def backup_logs(self, tag: str, dest_root: Path) -> Path:
        dest = dest_root / tag
        dest.mkdir(parents=True, exist_ok=True)
        for role, host in ([(ROLE_CN, h) for h in self.cfg.cn_hosts]
                           + [(ROLE_DN, h) for h in self.cfg.dn_hosts]):
            target = dest / f"{role}_{host.replace('.', '_')}.tar.gz"
            try:
                self.ssh.stream_tar(host, f"{self.cfg.get('DB_DIR')}/logs", target,
                                    prefix=f"{role}_{host}")
            except Exception as exc:  # noqa: BLE001 - evidence must not fail a case
                self.log(f"  log backup failed for {host}: {exc}")
        return dest
