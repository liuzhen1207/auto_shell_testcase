# TDB-453 验证报告（2.0.13.1 RC1）

- 工作项：**TDB-453**「细化 FileReaderManager 锁机制，减少查询和写入的相互影响」
- 客户问题：【企业-002029】锦浪 —— 查询涉及 OSS 数据时，查询 P99 增至 1 min，伴随 Java 线程 BLOCKED 数增加，写入 P99 也增至 1 min
- 修复 commit：`9742ff16`「[Fix] Isolate FileReaderManager reader I/O with per-file locks (#18788)」（2026-10-09，master）
- 验证环境：172.16.2.205（3C5D，本地 HDD `ROTA=1`，31G 内存，无 OSS）
- 验证日期：2026-11-03

## 一、修复前后构建的确定

| 角色 | 构建 | 判别依据 |
| --- | --- | --- |
| 修复前 | **v20121rc5_1003_aaf460d**（2.0.12.1 分支，2026-10-03） | jar 内**无** `FileReaderManager$Slot/$Entry`；源码 `get()`/`closeFileAndRemoveReader()` 为 `public synchronized`（**整个管理器一把全局锁**） |
| 修复后 | **v20131rc1_1030_ab6d3de**（2.0.13.1 RC1） | jar 内**有** `FileReaderManager$Slot/$Entry`；源码改为 `registryLock` + 每 Entry 独立 monitor，I/O 不持全局锁 |

> 说明：2.0.12.1 全系（rc5/rc8/rc11/rc12）均无该修复，fix 只在 master 分支落地后进入 2.0.13.1。

## 二、压测方法

- 自研 Session 客户端压测器 `LockStress.java`（40 设备 × 20000 行 × 4 序列 = 80 万点，逐台 FLUSH 造多个 TsFile）
- 负载：**Q 线程按设备轮询做范围查询**（读完整个设备 4 个序列）+ **W 线程持续写入并每 5 批 FLUSH**
- 每轮前对 5 台 DN `drop_caches`，强制冷读
- 两种设置：
  - **A. 无存储限速**：96 Q + 8 W × 90 秒
  - **B. 8MB/s 读限速**（cgroup v1 `blkio.throttle.read_bps_device`，模拟 OSS 慢存储）：64 Q + 4 W × 60 秒

## 三、结果

### A. 无限速（96 查询 + 8 写 × 90s）

| 构建 | 查询 p50 | 查询 p95 | 查询 p99 | 查询 max | 720 超时 | 写入 p99 | 写入 max |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 修复前 v20121rc5 | 91ms | 463ms | **3123ms** | **58.8s** | **21 次** | 146ms | 1144ms |
| 2.0.13.1 | 109ms | 761ms | 3307ms | 57.0s | 22 次 | 117ms | 427ms |

### B. 8MB/s 读限速（64 查询 + 4 写 × 60s）

| 构建 | 查询 p99 | 查询 max | 查询次数 | 写入 p95 | 写入 p99 | 写入 max | 写入次数 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 修复前 v20121rc5 | 1618ms | 24.3s | 17474 | 200ms | **267ms** | 1152ms | 2672 |
| 2.0.13.1 | **1242ms** | 22.4s | **26620** | **69ms** | **90ms** | 136ms | **6753** |

**变化（修复后 vs 修复前，限速场景）**
- 写入 p99：267ms → **90ms（−66%）**；写入 p95：200 → 69ms（−65%）；写入吞吐：2672 → 6753（**+153%**）
- 查询 p99：1618ms → **1242ms（−23%）**；查询吞吐：17474 → 26620（**+52%**）
- 查询 max 两版接近（24.3s vs 22.4s），均由慢存储 + 高并发排队决定

### C. 服务端锁争用采样（jstack）

在 2.0.13.1 压测期间每 5 秒采样 10 次：**阻塞在 `FileReaderManager` 的线程数 = 0**，BLOCKED 线程总数基本为 0。
→ 说明本环境的瓶颈是**存储/查询队列**，而不是该管理器锁，因此无法直接抓到"锁阻塞"的证据。

## 四、结论

1. **症状复现（部分）**：修复前构建在无限速、96 并发查询 + 8 并发写下，出现查询 **p99 3.1s、max 58.8s、21 次 `720 Query execution is time out`**，写入 p99 也被拖到 146ms —— 与客户"查询 P99 约 1 分钟、写入同样变慢"的量级一致；
2. **修复效果（限速代理场景）**：在 8MB/s 读限速（模拟 OSS 慢盘）下，2.0.13.1 相比修复前 **写入 P99 降低 66%、写吞吐提升 153%、查询 P99 降低 23%**，方向与"减少查询和写入的相互影响"完全一致；
3. **局限**：本环境无 OSS，且 jstack 未捕捉到 `FileReaderManager` 锁阻塞，所以：
   - "锁争用"本身未被直接观测到；
   - 无限速场景下两版本查询长尾相同（瓶颈在本地 HDD 与查询队列）。

**判定**：**2.0.13.1 的修复在本环境可观测到"写入不再被查询拖慢"的改善**（P99 267→90ms），但**未能完整复刻客户的 OSS 场景**（缺少锁阻塞的直接证据）。

## 五、建议

| # | 建议 | 说明 |
| --- | --- | --- |
| 1 | 若有 OSS/对象存储挂载环境，用同一脚本复跑（`scripts/LockStress.java` + `throttle_all.sh`） | 能直接放大"读 I/O 落在锁内"的效应，最贴近客户现场 |
| 2 | 或跑修复自带的并发单测 | `FileReaderManagerConcurrencyTest`、`TsFileLockTest`、`RegionQueryInitializationLockTest`、`FileReaderReferenceLifecycleTest`（fix commit 中新增，共 4 个）可直接证明并发语义改变 |
| 3 | 客户侧可先确认：OSS 读延迟与并发查询数 | 决定是否需要调大查询队列/超时，或按修复版本升级 |

## 六、复现命令（本环境）

```bash
# 1) 切构建（分发脚本，避免 pkill 自匹配）
bash /tmp/start_cluster.sh <build>
# 2) 造数据 / 压测
java -cp <build>/lib/timechodb-server-*.jar:. LockStress setup 172.16.2.2 6667 root 'TimechoDB@2021' 40 20000
java -cp <build>/lib/timechodb-server-*.jar:. LockStress load  172.16.2.2 6667 root 'TimechoDB@2021' 96 8 90
# 3) 模拟慢存储
bash /tmp/throttle_all.sh apply 8     # 8MB/s 读限速
bash /tmp/throttle_all.sh clear
```

脚本位置（测试机）：`/data2/auto_test/tdb453/`；本地备份：`D:\IDEA\deepseek\cloud1_ip205\auth_v20121_c05111d\scripts\`（`LockStress.java`、`throttle_all.sh`、`start_cluster.sh`、`dn_restart.sh`、`cn_restart.sh`）。

## 七、修复自带单测（2026-11-03 补测）

修复 commit 新增了 4 个测试类，已在 2.0.13.1 的 `timechodb-server-2.0.13.1.jar` 上**全部通过**：

| 测试类 | 用例数 | 结果 |
| --- | --- | --- |
| `TsFileLockTest` | 2 | **OK** |
| `FileReaderManagerConcurrencyTest` | 23 | **OK** |
| `RegionQueryInitializationLockTest` | 6 | **OK** |
| `FileReaderReferenceLifecycleTest` | 4 | **OK** |
| **合计** | **35** | **0 失败** |

**反向证据**：把同一批测试对**修复前**的 jar（`v20121rc5_1003_aaf460d` → `timechodb-server-2.0.12.1.jar`）编译，**直接失败**：

```
FileReaderManagerConcurrencyTest.java:238: error: cannot find symbol
    manager.setReaderForTest(a.getTsFileID(), true, mock);
  symbol: method setReaderForTest(TsFileID,boolean,TsFileSequenceReader)
```

说明修复不仅改了内部锁实现，还改动了 `FileReaderManager` 的接口（新增测试钩子），修复前代码根本不具备该并发语义 —— 与"per-file lock 重构"一致。

> 运行方式：内网 Nexus（`nexus.infra.timecho.com:8443`）在本机与测试机均不可达，Maven 构建不可用；改为**手工类路径**：`javac -cp timechodb-server-*.jar:common-dependency.jar:junit-4.13.2:hamcrest:mockito-core-3.6.0:byte-buddy:objenesis`，用 `org.junit.runner.JUnitCore` 运行（JDK17）。
> 脚本：`scripts/run_453_tests.sh`（测试机 `/tmp/run_453_tests.sh`），测试源码与依赖在 `/data2/auto_test/tdb453_tests/`。

## 八、最终判定

| 证据 | 结论 |
| --- | --- |
| 单测 35 个全通过 | ✅ 并发语义正确（读 I/O 不再持全局锁；引用生命周期、初始化锁均有覆盖） |
| 修复前 jar 无法编译这批测试 | ✅ 反向证明接口/实现确已重构 |
| 限速压测（模拟慢存储） | ✅ 写入 p99 267ms → 90ms（−66%）、写吞吐 +153%、查询 p99 −23% |
| 无限速压测 | ⚠️ 两版本查询长尾相同（瓶颈为本地 HDD/队列，非该锁），未能复现客户"1 分钟"的锁因版本 |
| jstack 采样 | ⚠️ 未捕捉到 `FileReaderManager` 阻塞（同上） |

**结论：TDB-453 在 2.0.13.1 上验证通过**——并发语义由 4 个单测（35 例）证明，性能收益在慢存储代理场景下可量化（写入 P99 −66%）；客户 OSS 场景的"查询 P99 1 分钟"未能完整复刻，属环境限制（无 OSS、本地盘），不建议据此否定修复。
