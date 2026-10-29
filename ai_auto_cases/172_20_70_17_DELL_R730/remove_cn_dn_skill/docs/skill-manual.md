# iotdb-remove-cn-dn

在 **ConfigNode / DataNode 集群**上做「并发读写 + 移除节点」的故障注入测试：一边用
`iot-benchmark` 压测，一边执行 `REMOVE DATANODE` / `REMOVE CONFIGNODE`，然后验证
**procedure 全部结束、syncLag 归零、副本一致**。

不依赖任何固定 IP：节点清单来自 `conf/nodes.conf`，或者运行时从 `SHOW CLUSTER`
/ 探测主机自动生成。

---

## 一、运行这个 skill 需要满足什么条件

### 1. 集群规格

| 项 | 要求 |
|----|------|
| 拓扑 | **3C5D**（3 个 ConfigNode + 5 个 DataNode）。脚本按 `nodes.conf` 里声明的角色工作，其他规格也能跑，但 3C5D 是默认验证过的形态 |
| 版本 | TimechoDB / IoTDB **2.0.x**（`-sql_dialect`、`REMOVE CONFIGNODE`、`SHOW MIGRATIONS` 都是 2.0 才有的） |
| 状态 | 集群可以被**反复停掉、清库、重启**。`prepare` / `run` / `matrix` 会删掉每个节点上的 `data/` 和 `logs/` |
| 部署方式 | 每个节点上同一份安装目录（`DB_DIR`），用 `sbin/start-confignode.sh`、`sbin/start-datanode.sh`、`sbin/stop-*.sh` 起停。**不支持** docker/k8s 编排的集群 |
| 部署用户 | 与 SSH 用户一致，例如都用 `cluster`；IoTDB 进程本身通常以 root 跑（脚本用 `sudo` 读 `jps` / 起停 / 清理） |
| 多盘（可选） | 想复现"对象文件跨盘"的形态（TDB-835 / TDB-861 的原始环境都是每节点 3 块盘）就设 `DN_DATA_DIRS=<DB_DIR>/data/datanode/data,<第二块盘路径>/dn_data`，并把盘外那部分写进 `DN_EXTRA_DIRS`；`DN_EXTRA_DIRS` 会在启动前创建、并在每例 `wipe` 时清空。本机 2 块盘（`/dev/sda1`→`/`、`/dev/sdb1`→`/data`）就够用：一个 tier 两个目录，于是每个 DN 有两个 `<data dir>/object`，快照/恢复都必须跨目录汇总 |

### 2. 驱动机（跑这个 skill 的机器）

| 项 | 要求 |
|----|------|
| Python | **Python 3.9+**，只用标准库（`argparse` / `urllib` / `subprocess` / `dataclasses`）。**不需要 pip、不需要装任何包** |
| 网络 | 能 SSH 到所有 CN/DN 主机；能访问 DataNode 的 RPC 端口（默认 6667）；还要能访问 syncLag 数据源（Prometheus 的 9090 或 DataNode 的 `METRICS_PORT`） |
| SSH | 对**每一台**集群主机都能免交互登录。两种任选其一：<br>• 免密公钥（`SSH_MODE=key`，推荐）<br>• 密码（`SSH_MODE=password` + `SSH_PASSWORD`，需要本机有 `sshpass`；没有 `sshpass` 时会自动退回 `SSH_ASKPASS`，OpenSSH 8.4+ 可用） |
| 免密 sudo | 集群主机上 `sudo -n true` 必须成功。脚本要 `sudo jps` 看进程、`sudo sbin/start-*.sh` 起节点、`sudo rm -rf` 清库。**没有 NOPASSWD 会直接失败**（不会卡住等密码） |
| 磁盘 | 驱动机要能写下 `RESULT_DIR`（每跑一个 case 会存查询快照、日志备份） |
| SSH 连接数 | **单用例会发几百条命令**（syncLag 每 10 s 轮询、停机扫描每 3 s 轮询节点状态）。skill 默认开 `SSH_MULTIPLEX=true`，每台主机复用一条连接；关掉它的话整轮 matrix 会有**几万次连接全部来自同一个 IP**，主机的防暴力破解（fail2ban/sshguard）会把这台驱动机封掉 —— 实测 12 个用例后被封约 10 分钟，后续用例全部秒失败。详见 `references/troubleshooting.md` |

### 3. 被测集群每个节点

| 项 | 要求 |
|----|------|
| 安装目录 | `DB_DIR`（例如 `/data/iotdb/v20121_rc1_0906`），里面有 `sbin/`、`conf/`、`lib/` |
| 配置文件 | `$DB_DIR/conf/iotdb-system.properties` 存在且可写。脚本会改写 `cn_seed_config_node`、`cn_internal_address`、`dn_rpc_address`、`*_replication_factor` 等 |
| 客户端 | 二选一：<br>• 留空 `CLI_HOME` → 用节点自带的 `$DB_DIR/sbin/start-cli.sh`（**推荐，零额外依赖**）<br>• 设 `CLI_HOME` → 驱动机上那份 IoTDB 安装的 `sbin/start-cli.sh` |
| License | TimechoDB 企业版需要 license。`LICENSE_SRC` 指向一个 `.license` 文件时会自动分发到每个节点；留空则假设节点上已经有 license |

### 4. iot-benchmark

| 项 | 要求 |
|----|------|
| 位置 | `BM_HOME` 指向驱动机上的 iot-benchmark 根目录，必须有 `benchmark.sh` 和 `conf/config.properties` |
| 版本 | 支持 `IoTDB-200-SESSION_BY_TABLET` 的 iot-benchmark-iotdb-2.0（例如 `bm_20251017_b6be9bd`、`bm_20260519_writeview_v20`） |
| 能力 | 必须支持 `IoTDB_DIALECT_MODE=tree\|table`、`INSERT_DATATYPE_PROPORTION` 含 `OBJECT`、可写视图（`IoTDB_TABLE_WRITABLE_VIEW`）。缺哪项对应 workload 会起不来 |
| 配置 | skill 会复制一份 `conf/config.properties` 到 `results/<run>/benchmark/<workload>/`，只覆盖需要的键，**不改动你的原始文件** |

> 没有 benchmark 时 `doctor` 会直接报错退出。这是硬依赖 —— 「并发读写」正是本 skill 的核心。

### 5. syncLag 数据源（同步延迟归零判定）

**两种来源二选一，不是必须装 Prometheus。**

| 方式 | 配置 | 说明 |
|---|---|---|
| DataNode 自带 exporter（推荐，无需额外组件） | `SYNC_LAG_SOURCE=metrics`，`METRICS_PORT=9092` | 直接抓每台 DataNode 的 `http://<dn>:9092/metrics`，里面有和 Prometheus 一样的 `iot_consensus{...,type="syncLag"}` 序列。脚本按节点把各 region 的样本求和，等价于 Prometheus 的 `sum(...) by (instance)` |
| Prometheus | `MONITOR_URL=http://<prom>:9090` | 用 `SYNC_LAG_SOURCE=prometheus` 强制，或 `auto`（默认：配了 `MONITOR_URL` 就用它） |

`METRICS_PORT` 就是 `iotdb-metric-exporter` 暴露的端口，可在 `iotdb-system.properties`
里用 `dn_metric_port`（默认 9092）确认。两种都不配 → syncLag 归零这一步被跳过，
case 只能给「一致性通过」，不能声称验证了同步收敛。

`doctor` 会真的去读一次，读不到就报错，不会让你带着一个坏的数据源开跑。

### `--repeat N`：把「间歇性」变成复现率

单次运行无法区分「稳定通过」和「碰巧通过」。矩阵里有用例只在被摘节点的 region 放置恰好包含
失联副本时卡死，因此不同轮次会 PASS 与 FAIL 各现，此时跑 N 次、报**比率**才有意义：

```bash
scripts/rcdn.sh --conf conf/cluster.conf run --case dn_remove_other_unknown --repeat 5
```

第 1 次沿用原始用例 id，其余为 `<case>#2` … `<case>#N`，结果目录各自独立。结尾会打印：

```
repeated cases (pass rate):
  dn_remove_other_unknown: FAIL=2  PASS=3   (5 runs)
```
`matrix --limit N` 的 `--limit` 先作用于**用例数**，再展开重复。

### 5b. 用 Prometheus 时

| 项 | 要求 |
|----|------|
| `MONITOR_URL` | 例如 `http://172.20.70.13:9090`。没配的话 **syncLag 归零这一步会被跳过**，case 只能给「一致性通过」的结论，不能声称验证了同步收敛 |
| 指标 | `iot_consensus{name="ioTConsensusServerImpl",type="syncLag"}`（或 V2 的 `iot_consensus_v2`）。没有这个指标 → 同样跳过 |
| 认证 | 默认 `admin/admin`，可用 `MONITOR_USER` / `MONITOR_PASSWORD` 覆盖 |

### 6. 权限与安全

* **会破坏数据**：`prepare` / `run` / `matrix` 会清空集群。只对一次性测试集群用。
* **磁盘满用「调阈值」模拟，不写盘**：`diskfull` 不再填充磁盘。DataNode 变 ReadOnly 的条件是空闲空间比例低于 `disk_space_warning_threshold`（默认 5%），而在 18 TB 的盘上填到 5% 需要 ~928 G —— 不现实。所以 skill 改为**把该节点自己的 `disk_space_warning_threshold` 调到它的真实空闲比例之上**（`DISK_FULL_SIMULATE`，默认 true）：`JVMCommonUtils.hasSpace()` 会对所有目录返回 false → 抛 `DiskSpaceInsufficientException` → `FolderManager.changeToReadOnlyIfDiskFull()` → `setNodeStatus(ReadOnly)` + `setStatusReason(DISK_FULL)`。
  **走的是与真满盘完全相同的状态机，零字节落盘**；该属性支持热加载（`IoTDBDescriptor.loadHotModifiedProps`），用例结束时 skill 会把阈值改回去，节点自行恢复 Running。
  **关键前提：这个状态是在"写入分配"时进入的，不是定时器。** `changeToReadOnlyIfDiskFull` 挂在文件分配路径上，所以该节点必须有写入流量。实测：有写负载时 4 个 DN 在 **5 次 insert** 后全部变为 `ReadOnly(DiskFull)`；空载集群上改阈值则永远停在 `Running`。用例本身都跑在 benchmark 负载下，所以满足该前提。
  另外注意状态串是 `ReadOnly(DiskFull)`，用 `status_is()` 判断（会剥掉 `(qualifier)`），不要和 `"readonly"` 裸比较。
* **两条安全铁律（2026-09-18 实测事故换来的）**：
  1. `set configuration` **必须带 `ON <nodeId>`**。该子句在文法里可选（`IoTDBSqlParser.g4:1326`），**省略即集群级生效** —— 实测把 5 个 DataNode 全部推入 `ReadOnly(DiskFull)`，用例实际测的是"整个集群磁盘满"，产生约 350 条纯属注入泄漏的客户端错误。代码层由 `Remover.disk_threshold_statement()` 强制，取不到 node id 时**直接报错**而非退回集群级。
  2. `set configuration` 会**持久化到 `conf/iotdb-system.properties`**，而用例结束时的还原**本身可能失败** —— 且最可能失败在它最被需要的时刻（用例若已把集群 SQL 通道弄断，还原就送不达）。泄漏不会自愈：一次泄漏让 5 个节点全部磁盘满，**在零告警下毒化了后续 8 个用例**，首个可见症状还是一个看似无关的 `benchmark objects were not created within 900s`。现由**用例启动前**的 `clear_raised_disk_thresholds()` 兜底，并在清理时大声告警。
  **排查口诀**：任何用例在准备阶段莫名失败，先查
  `grep -E '^disk_space_warning_threshold' <DB_DIR>/conf/iotdb-system.properties` —— 有未注释的行就是泄漏。
* **为什么 `dn_diskfull_remove` 不在矩阵里**：它已由 `dn_readonly_remove`（手动 `set system to readonly on local`）覆盖同一摘除路径。`diskfull` selector 的实现保留且可用（新机制已就绪），需要时把那一行加回 `cases/remove_cases.tsv` 即可。矩阵中真正使用新机制的是 `dn_remove_other_diskfull`（tc120）。
* **`dn_added_dn_remove` 不再需要额外主机**：用例把清单里**最后一个 DataNode 先不启动**（`nodes.conf` 里 DN 数为 N 就以 N-1 个起集群），用例开始时再把它拉起来当扩容节点，然后摘除这个**刚加入的节点**（grow-then-shrink）。这样 3C5D 不必再空出一台机器。
  仍可用 `SPARE_DN_HOSTS` 指定清单外的主机；指定了就按老路走（不 hold-back）。
  **为什么不能「等它还在加入」**：新节点 `Unknown` → `Running` 只要约 8 秒，且**不会分到任何 region**（实测 190 秒仍为 0）；`Adding` 是 **RegionStatus**（区域获得 peer 时的状态）而非节点状态——所以「等备用节点离开 Running」的旧判据永远不会成立，只会空等超时。
  若 DN 数不足以在 hold-back 后再摘一个（需 ≥ `max(schema_rf, data_rf)`），用例会 SKIP 并说明差多少。
* **只读命令**：`doctor`、`discover`、`verify`、`diag`、`selftest` 不改任何东西，可以在生产集群上安全执行（`verify` 只发查询、扫日志，日志用 `zcat` 读，**不会就地解压**；`diag` 只读指标与 `show` 查询）。

### 6b. 授权（TimechoDB 企业版必须，实测坑）

TimechoDB 的企业版**每个 ConfigNode 都要有 license**，否则节点起得来但状态是
`ReadOnly(UNACTIVATED)`，压测直接写不进去。两个文件缺一不可：

| 文件 | 位置 | 说明 |
|---|---|---|
| `license` | `<DB_DIR>/activation/license` | 授权文件 |
| `.env` | `<DB_DIR>/.env` | 里面是 `node_uuid=<uuid>`，**每台机器不同** |

```bash
# 对每个 ConfigNode 主机执行（注意 .env 要用本机自己的，不能互相拷）
sudo cp /data/mpp_test/license_2026/.env     <DB_DIR>/.env
sudo cp /data/mpp_test/license_2026/license  <DB_DIR>/activation/license
```

实测结论，踩过的坑：

* **只拷 `license` 不拷 `.env` 会失败**，报
  `LicenseException: This license is not allowed to activate this ConfigNode`。
  加上 `.env` 后立刻 `Load license success` / `ACTIVE_ACTIVATED`。
* `.env` 里的 `node_uuid` **每台不同**（.9/.8/.7 三个值都不一样），必须用本机的。
* **DataNode-only 主机不需要单独授权**：只要同集群的 ConfigNode 激活了，
  DataNode 会自动变成 `ACTIVATED`（实测 .6 上完全没有任何 license，
  `show cluster` 仍显示 `ACTIVATED`）。
* 验证：`show cluster` 的 `ActivateStatus` 列必须全是 `ACTIVATED`。

### 6c. sbin 脚本可执行位（实测坑）

从 tar 包解出来的安装目录**经常丢可执行位**（实测 rc2 的 7 个 `sbin/*.sh`
全是 `664`）。后果很隐蔽：`start-datanode.sh` 根本没跑起来，但用例日志照样
打 "started dn on ..."，然后卡在等健康。

`doctor` 会提前报出来；`prepare` 会自动修复：

```bash
chmod +x <DB_DIR>/sbin/*.sh      # 每台都要
```

### 7. 30 秒自检（不需要集群）

```bash
cd <skill-dir>
cp conf/cluster.conf.example conf/cluster.conf   # 改 SSH / DB_DIR / BM_HOME / MONITOR_URL

scripts/rcdn.sh --conf conf/cluster.conf selftest    # 解析器 / 用例矩阵 / 配置加载
scripts/rcdn.sh --conf conf/cluster.conf smoketest   # 25 个用例全流程跑一遍（全部打桩，不碰任何机器）
scripts/rcdn.sh --conf conf/cluster.conf list-cases  # 打印用例矩阵

scripts/rcdn.sh --conf conf/cluster.conf doctor      # 连集群做只读体检
```

* `selftest` — 用真实 CLI 输出样本验证表格解析、结果归一化、错误识别、用例加载。
* `smoketest` — 把集群、benchmark、SSH、SQL 全部替换成桩，把 25 个用例的**完整代码路径**
  （建集群 → 起压测 → remove → 异常操作 → 等 procedure → 等 syncLag → 一致性校验 →
  扫日志 → 出报告）跑一遍。它证明「配置和代码能跑通」，不接触任何真实节点；
  正常输出结尾是 `no unhandled error in any case; nothing was contacted`。
  其中有 3 个用例会故意报 FAIL（`dn_nonexistent_remove`、`cn_nonexistent_remove`、
  `dn_remove_rf_limit`），因为它们的断言是「remove 必须被拒绝」，桩环境给不出真实拒绝。
* `doctor` — 逐个检查上面 1–5 项，全部通过才打印
  `doctor: all preconditions look satisfied`；否则列出问题并以退出码 2 结束。

**建议顺序**：`selftest` → `smoketest` → `doctor` → `prepare` → `run --case ...`。

### 8. 运行时长与状态（实测）

在 3C4D→3C5D 真机（2.0.12.1）上实测：

| 环节 | 耗时 |
|---|---|
| 单用例总计 | **约 17 分钟**（`dn_running_remove` 在调优前 26 分钟） |
| 其中 cluster reset | ~35 s |
| 压测 + 负载预热 | ~2.5 min |
| remove + region 迁移 | ~1.5 min |
| 每次等 syncLag 归零 | ~70 s（`SYNC_STABLE_SECONDS=60` + 10 s 轮询） |
| 副本一致性扫描 | 每个 DN ~100–130 s（停 → 查 → 起 → 等 syncLag 重新归零） |

一致性校验是 **O(节点数)** 的：5 个 DN 就是 5 轮停机重启，所以单个用例就十几分钟。
rc1/rc2 实测单用例 **15–20 分钟**（`dn_running_remove_1rep` 约 8 分钟），25 个用例全跑 ≈ **7 小时**（2026-09-19 实测：主矩阵 00:08–07:00，6 小时 51 分）。
想快就调小 `SYNC_STABLE_SECONDS`（但别低于 30 s，否则可能把一次瞬时归零误判成收敛）。

**先看这个再决定要不要跑全量**：真机实测里最省时间的不是调参，而是**快速失败**。
没有它们，下面这些情况会把一次 matrix 从 7 小时拖成十几个小时，而且**报出来的错还是假的**：

| 情况 | 没有快速失败 | 有快速失败 |
|---|---|---|
| 磁盘填不满，触发不了 ReadOnly | 填 16 min → 超时 → FAIL | 预检 **0.1 s SKIP**（`dn_remove_other_diskfull` 实测） |
| 故障注入不了却照样判 PASS | 空跑 17 min 得一个**假 PASS** | 预检直接 SKIP，杜绝"没测过却绿了" |
| 摘除后节点起不来（被产品拒绝） | 等满 `CLUSTER_START_TIMEOUT_SEC=900` | 探一次就判定"重启被拒绝"，用例 31 min → 18 min |
| 另一个副本持有者不参与共识 | 等满 `REMOVE_MAX_WAIT_SEC=7200` | `PROCEDURE_STALL_SEC=300` 抓 `Worker stuck`，346 s 结束 |
| syncLag 被钉死不动 | 等满 `SYNC_MAX_WAIT_SEC=3600` | `SYNC_STALL_POLLS=12` 判定停滞 |
| ReadOnly 节点"重启治疗" | 重建后仍是 ReadOnly，白等 900 s | `set system to running on local;` 11 s 复位 |

这些都默认开启；除非要复现某个长等待，否则不要关。

**注意**：`run`/`matrix` 在扫日志前会 `stop_all()`，所以**每个用例结束后集群是停的**
（日志不再滚动才能扫干净）。下一个用例的 `prepare` 会重新拉起。全部跑完后想恢复集群：

```bash
scripts/rcdn.sh --conf conf/cluster.conf prepare    # 或手动起节点
```

`teardown` 只停不删；`teardown --wipe` 会连 `data/` 一起清掉。

---

## 二、快速开始

```bash
cd <skill-dir>

# 1) 配置
cp conf/cluster.conf.example conf/cluster.conf
vi conf/cluster.conf                 # SSH_*、DB_DIR、BM_HOME、MONITOR_URL、RESULT_DIR

# 2) 【全新环境】从压缩包部署 + 激活（集群还不存在时走这步）
#    你只需提供：timechodb 压缩包、机器 IP、SSH 用户名/密码、部署路径
vi conf/cluster.conf                 # DEPLOY_TARBALL / DEPLOY_HOSTS / DEPLOY_DIR / DB_DIR / SSH_*
scripts/rcdn.sh --conf conf/cluster.conf deploy --clean
#    IoTV2 协议：--consensus IoTV2    （等价 IoTConsensusV2）
#    只看解包和配置、先不启动：--no-start      跳过激活：--no-activate

# 2b) 【全新环境】按被测库版本取对应的 benchmark 包
scripts/rcdn.sh --conf conf/cluster.conf benchmark --install

# 3) 离线自检（不碰集群）
scripts/rcdn.sh --conf conf/cluster.conf selftest
scripts/rcdn.sh --conf conf/cluster.conf smoketest

# 4) 节点清单：两种方式任选
scripts/rcdn.sh --conf conf/cluster.conf discover --from-cluster
#   ↑ 集群在跑时，直接读 SHOW CLUSTER 得到拓扑（最准）
scripts/rcdn.sh --conf conf/cluster.conf discover --from-inventory
#   ↑ 集群没起时，探测主机上的 data/confignode、data/datanode、日志、端口

# 5) 体检（只读，对生产集群也安全）
scripts/rcdn.sh --conf conf/cluster.conf doctor

# 6) 重建集群（会清库！）
scripts/rcdn.sh --conf conf/cluster.conf prepare

# 7) 跑用例
scripts/rcdn.sh --conf conf/cluster.conf list-cases
scripts/rcdn.sh --conf conf/cluster.conf run --case dn_running_remove --case cn_leader_remove
scripts/rcdn.sh --conf conf/cluster.conf matrix              # 全量
scripts/rcdn.sh --conf conf/cluster.conf matrix --limit 3    # 先试 3 个

# 8) 收尾
scripts/rcdn.sh --conf conf/cluster.conf teardown --wipe
```

`--conf` / `--quiet` / `--run-id` 放在子命令前或后都可以。

### benchmark 版本必须和被测库大版本对应（实测坑）

iot-benchmark 的每个发行包**只带一个数据库线的客户端**，两者不通用：

| 被测库 | benchmark 包 | `DB_SWITCH` | 压测模型 |
|---|---|---|---|
| 2.x | `iot-benchmark-iotdb-2.0-java17.zip` | `IoTDB-200-SESSION_BY_TABLET` | 树 + 表 + 表视图 |
| 1.x | `iot-benchmark-iotdb-1.3-java17.zip` | `IoTDB-130-SESSION_BY_TABLET` | **仅树** |

实测证据：本机 `bm_20260812_e158c2c_jdk17` 里只有 `iotdb-2.0-1.0.0.jar` 与
`iotdb-session-2.0.11-*.jar`；1.3 包内是 `iotdb-session-1.3.7.jar`。**拿 2.0 的包
去连 1.x，包结构检查全过，直到连接时才失败**，看起来像集群故障。所以这个配对由
skill 推导并校验，不交给人工：

- `DB_VERSION` 或不填时从 `DEPLOY_TARBALL`（最准）/`DB_DIR` 推断；
  像 `v20121rc2_0914_0b4dc9a` 这种没有点号版本的目录**直接报错要求显式指定**，不猜。
- 1.x 会自动去掉表模型类 workload（表模型 2.0 才有），并在日志里记录去掉了哪些。
- `doctor` 会核对 `BM_HOME` 里是否真有对应模块，不匹配就给出下载地址。

```bash
# 看这个版本需要哪个包
scripts/rcdn.sh --conf conf/cluster.conf benchmark --version 1.3.4
# 下载并安装（带缓存，重跑不需要网络）
scripts/rcdn.sh --conf conf/cluster.conf benchmark --install
# 指定 release
scripts/rcdn.sh --conf conf/cluster.conf benchmark --install --tag 2026-08-12-e158c2c9-java17
```

包来自 <https://github.com/thulab/iot-benchmark/releases>，**同一个 release 同时提供
1.3 与 2.0 两个包**。要自己编译最新版，用 `/data/deepseek/ai-bug-verify` 里的
`iot-benchmark` 技能（它负责 maven 构建与缓存），编译完把 `BM_HOME` 指过去即可。
已下载的包会**先按大小命中缓存、再尝试联网**，所以连不上 GitHub 的机器也能用已有的包。

### 从压缩包到跑完用例（`deploy` 约定）

只给四样东西，skill 自己把环境建起来：

| 你提供 | 配置项 |
|---|---|
| timechodb 测试压缩包 | `DEPLOY_TARBALL`（本机路径 → 自动上传；或各节点已有的路径） |
| 机器 IP | `DEPLOY_HOSTS=ip1,ip2,ip3`（每台 1 CN + 1 DN，即 3C3D） |
| 用户名 / 密码 | `SSH_USER` / `SSH_PASSWORD` / `SSH_MODE=password` |
| 部署路径 | `DEPLOY_DIR`（解包目录）、`DB_DIR`（最终安装路径） |

`deploy` 依次做：分发压缩包（**同尺寸已存在则跳过上传**）→ 解包 → 把包内唯一顶层目录
移到 `DB_DIR` → 写配置 → **先起 seed ConfigNode**、就绪后再起其余节点 → 等全部 Running
→ 提交激活码。

默认 `schema_replication_factor=3`、`data_replication_factor=2`、
`data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.IoTConsensus`；
指定 `--consensus IoTV2`（或 `IoTConsensusV2`）则写
`org.apache.iotdb.consensus.iot.IoTConsensusV2`。**协议名不认识时直接中止部署**，
不会静默退回默认值。

> ⚠️ 副本因子、seed 地址、共识协议都是 `effectiveMode: first_start`——**首启后不可改**，
> 配错只能清 `data/` 重新部署。所以 `deploy` 在启动任何东西之前就把配置全部写完，
> 并且在碰任何机器之前先校验协议名。

激活码从技能仓库 `/data/deepseek/ai-bug-verify`
（`skills/timechodb-rn-verify/references/activation.md`）读取，由 `LICENSE_CODE_FILE`
指定，**不在本 skill 里重复保存**；也可用 `LICENSE_CODE` 直接给码。集群任一节点
`activate` 一次即激活全部，状态落在 `activation/`，重启自动恢复。



结果在 `RESULT_DIR/<run_id>/`：`summary.tsv`、`summary.json`、`run.log`、
`cases/<case_id>/result.json`，失败时还有 `log_backup/<case>_<时间戳>/*.tar.gz`。

---

## 三、目录结构

```
SKILL.md                     模型看的执行说明
README.md                    本文件：运行条件
conf/cluster.conf.example    配置模板（无任何硬编码 IP）
conf/nodes.conf              discover 生成，或手写：角色<TAB>IP
cases/remove_cases.tsv       用例矩阵（20 条）
templates/benchmark/         benchmark 配置兜底模板
scripts/rcdn.sh              入口
scripts/rcdn/                Python 实现
  config.py    配置与节点清单解析
  remote.py    SSH / SQL 客户端 / ASCII 表格解析
  cluster.py   集群生命周期、拓扑发现、日志清理
  benchmark.py iot-benchmark 驱动（tree 10 类型 / table 11 类型 / 可写视图）
  remove.py    REMOVE 语句、目标状态构造、异常操作、procedure 等待
  verify.py    副本一致性校验、syncLag、日志扫描、日志备份
  cases.py     用例矩阵解析与编排
  selftest.py  离线解析自检
  smoketest.py 全流程打桩自检
  cli.py       命令行
references/                  参考文档
```

## 四、更多文档

* `references/cases.md` — 用例矩阵每个字段的含义，怎么加用例
* `references/source-testcases.md` — 与原始 `remove_iotv1_testcase_list.txt` 的对应关系
* `references/troubleshooting.md` — 常见失败与排查

## RC5 基线

2.0.12.1 RC5 的 remove 矩阵基线见 `results/BASELINE_RC5.md`：当前指向 run-id `20261009_rc5_clean`
（2026-10-09 17:34 起跑，判定跑完后回填）。旧轮 `matrix_20261005_175940` 已标为**环境异常轮、判定作废**
（见该目录 `VOID_ENV_BROKEN.md`），不要用作基线。已知的 RC5 写路径 NPE（OBJECT 列相关）不重复分析；
重跑只用于判定三类非 NPE 签名：副本不一致 / 迁移过程卡死 / `305: null` 写入失败。

## TDB-861 window injection (object snapshot / GC race)

`dn_object_delete_residue` no longer relies on a DELETE burst: on master `939750de80` a DELETE
reclaims the OBJECT payloads while the TSFile is evicted and writes **no**
`log_datanode_object_deletion.log` record, so the evidence gate could never be met (4-8 records
against a threshold of 20 -> SKIP). The case now:

1. seeds `objprobe.t (time, dev, o object)` with unique payloads (`to_object(true, 0, X'..')` is the
   only accepted OBJECT literal);
2. **overwrites** the same (device, time) rows every `OBJECT_CHURN_INTERVAL_SEC` — each round turns the
   previous payloads into garbage, so the OBJECT GC unlinks and journals ~40 files per DataNode per
   100-row round;
3. while the GC is busy, issues `MIGRATE REGION <id> FROM <leader> TO <free DataNode>` on that table's
   region (must be sent in the **table** dialect — a tree-dialect call fails with `900 ... belong to
   TABLE model`), because the migration snapshot is the other half of the race;
4. audits each replica against the leader: follower-only files ∩ the leader's deletion log = confirmed
   residue.

Run the probe on its own (no benchmark, one region):

```bash
python3 scripts/object_probe.py --conf conf/cluster.conf --db objprobe --table t
python3 scripts/object_probe.py --conf conf/cluster.conf --db objprobe --table t --no-migrate   # control
```

Exit code `0` = window armed and clean, `1` = residue reproduced, `2` = window not armed
(what an inner case run turns into a SKIP). Knobs: `OBJECT_PROBE_MIGRATE`, `OBJECT_PROBE_DB`,
`OBJECT_PROBE_TABLE`, `OBJECT_CHURN_ROWS`, `OBJECT_CHURN_INTERVAL_SEC`, `OBJECT_GC_MIN_RECORDS`.

## Big-OBJECT scenario: ~4 GiB of OBJECT payloads survive a region migration

A single OBJECT point may be up to 4 GiB, which cannot be written through a SQL literal (the
statement would be twice that size). The `dn_object_big_migrate` case therefore writes the volume in
segments through the benchmark (`BM_OBJECT_LENGTH`), then migrates **every** data region of the
database and verifies correctness:

1. wait until the database holds `OBJECT_BIG_TARGET_GIB` (default 4 GiB) of OBJECT payload — the
   audit counts each region once, because RF=2 puts two copies of the same bytes on disk;
2. for each region: `MIGRATE REGION <id> FROM <leader> TO <free DataNode>`;
3. verify: `length(read_object(o))` + `sha256(cast(read_object(o) as string))` sampled before/after
   must be identical (server-side, so the payload never crosses the wire), the two replicas' physical
   `.bin` byte totals must agree, and follower-only files ∩ the leader's deletion log must be empty.

Dedicated conf: `conf/cluster.rc11_bigobj.conf` (8 devices × 50 loops × 2 OBJECT columns × 12 MiB).
Measured on RC11 `ea4f835` (2.0.12.1): 4.10 GiB written, 5 regions migrated (0.52-1.03 GiB each,
24-44 s per migration), content samples identical, replicas byte-equal, 0 residue — the case PASSes.

### A single OBJECT point can be 4 GiB (written in chunks)

`to_object(isEOF, offset, X'<chunk>')` carries an offset and an EOF flag, so one OBJECT value is
assembled from parts — a 4 GiB point is many INSERTs of the same `(device, time)` with increasing
offsets. `dn_object_single_4g` does exactly that with `scripts/java/SingleObjectWriter.java`
(8 MiB per statement, 512 statements) and measures on RC11 `ea4f835`:

- 4096 MiB written in **252 s** (16 MiB/s), object file `.bin` exactly 4 294 967 296 bytes;
- both replicas' `.bin` sha256 = `4bfa1b1094583395a8fe5bbd8417bf9c24186440dcd3f4297d7207dfd289372b`,
  matching the pattern the client wrote;
- `MIGRATE REGION` of that region took **103 s**, the new replica's `.bin` has the same size and sha256;
- whole case PASS in 1421 s (including a cluster reset and the consistency sweep).

Reads are streamed the same way: `read_object(o, offset, length)` returns one slice, so the whole
value never has to fit in a `byte[]`. `read_object(o)` (whole file) still refuses payloads above 2 GiB
(`701: Read object size 4294967296 is too large (size > 2G)`), but the ranged form does not — the case
reads the 4 GiB point back as 16 chunks of 256 MiB and compares `length()` + `sha256()` of every chunk
against the bytes the writer produced, before and after the migration. Measured: write 4096 MiB in
279.5 s (14.7 MiB/s), 16/16 chunks matching on both reads, `MIGRATE REGION` 103 s, `.bin` 4 294 967 296
bytes on both replicas.

## OBJECT cases are part of the full matrix

All four OBJECT cases run in a normal full-matrix run (they were `skip` while the volume was
unproven; they are `running` now, since a full run is preferred over a curated subset).  Budget
the time — they add roughly **2 h 22 min** on top of the rest of the matrix:

| case | what it proves | measured |
|---|---|---|
| `dn_object_single_4g` | one 4 GiB OBJECT point: 512 x 8 MiB `to_object(isEOF, offset, X'..')` writes, 16 x 256 MiB `read_object(o, off, len)` read-backs with per-chunk `length()`+`sha256()`, region migration, then the same read-back | 1419 s |
| `dn_object_big_migrate` | ~4 GiB spread over 12 MiB object files: every region migrated, per-row sha256 identical, no size/index residue | 5320 s |
| `dn_object_manyfiles_residue` | ~1e5 small OBJECT files: delete + migrate, no residue on the new replica | 998 s |
| `dn_object_delete_residue` | TDB-861 snapshot/GC window: a newly added replica must not keep files the leader deleted | 805 s |

Each case starts with its own cluster reset, so they also re-validate the deploy path.  Peak disk
is ~10 GiB per DataNode data dir (the 4 GiB single point plus its two replicas).

## Many-small-files variant of the TDB-861 case

`dn_object_manyfiles_residue` writes ~1e5 small OBJECT files (1 KiB each: 1000 devices x 100 loops x
2 OBJECT columns, `BM_POINT_STEP=0` so every round overwrites the same point), then migrates every
data region and compares the new replica against the leader plus the leader's object-deletion log.
Rationale: the RC11 `SnapshotTaker` copies the whole object directory, so the copy should take long
enough to overlap with the GC unlink. Measured on RC11 `ea4f835`: 108 864 files written, ~21 700 files
per region, ~5 min per migration, and still 0 residue — at that moment every file is still referenced
by a TSFile (leader deletion log = 0), so nothing is pending GC and there is nothing to leak.
Conf: `conf/cluster.rc11_manyobj.conf`.
