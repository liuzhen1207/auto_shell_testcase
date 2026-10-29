# RC11 部署记录与授权阻塞说明

| 项 | 内容 |
|---|---|
| 版本 | TimechoDB V2.0.12.1，BuildInfo **`ea4f835`**（RC11） |
| 版本目录 | `v20121rc11_1023_ea4f835` |
| 源码 | `/data/deepseek/timecho_src/timecho_v2_0_12_1`（HEAD = `ea4f835504b`，与包匹配） |
| 测试包 | 172.20.70.3:`/data1/iotdb/testdb/v20121rc11_1023_ea4f835`（`timechodb-2.0.12.1-bin.zip`，106 MB） |
| 部署状态 | ✅ 已完成（6 节点） |
| 集群状态 | ⏸ **未激活，无法启动** |
| 阻塞日期 | 2026-10-23 |

---

## 一、部署已完成

| 节点 | 角色 | 体积 | 说明 |
|---|---|---|---|
| 172.20.70.5 | CN | 122 M | `.env` + `activation/license` 已放置 |
| 172.20.70.4 | CN + DN | 122 M | 同上 |
| 172.20.70.26 | CN + DN | 122 M | 同上 |
| 172.20.70.14 | DN | 118 M | 无需单独授权（从 CN 获取） |
| 172.20.70.27 | DN | 118 M | 同上 |
| 172.20.70.30 | DN | 118 M | 同上 |

- 安装目录：`/data/iotdb/v20121rc11_1023_ea4f835`
- `lib` 下 3 个 fat jar 齐全（`common-dependency.jar` 80 MB / `timechodb-server-2.0.12.1.jar` 37 MB / `tsfile-remote-sink` 2 MB）
- 客户端侧包已解压，`sbin/start-cli.sh` 存在
- 部署方式：客户端扩包 → `tar.gz` → `scp` 到各节点解压（**不要用流式 tar 管道，会截断**）

## 二、RC10 环境已优雅停止

- 使用官方脚本（先 DN 后 CN）停止，所有端口（10710 / 6667 / 9092）释放，无残留 java 进程
- RC10 目录保留在 `/data/iotdb/v20121rc10_1021_c60ce63`（仅作历史参考，不再使用）

---

## 三、阻塞：RC11 无法激活

### 3.1 现象

CN 启动报：

```
ERROR com.timecho.as:469 - Load license fail.
org.apache.iotdb.commons.exception.LicenseException:
    This license is not allowed to activate this ConfigNode.
```

DN 随后被拒绝注册，集群无法就绪：

```
ERROR o.a.i.db.service.DataNode:693 - Deny DataNode registration: Cluster is unactivated now, DataNode is not allowed to join
```

### 3.2 指纹对比

授权指纹格式为 `02-<机器段>-<第二段>-<uuid段>`：

| 节点 | 现有 license 接受 | RC11 实际计算 |
|---|---|---|
| 172.20.70.5 | `02-PZPWR7DQ-F7LR642I-PXAEDQLR` | `02-PZPWR7DQ-`**`3ZEATQL3`**`-PXAEDQLR` |
| 172.20.70.4 | `02-UHGNVQ4C-NGLCNW3P-EDBU4HBG` | `02-UHGNVQ4C-`**`3ZEATQL3`**`-EDBU4HBG` |
| 172.20.70.26 | `02-SBACZCP3-4KDI3ZAF-3CJVOOYE` | `02-SBACZCP3-`**`3ZEATQL3`**`-3CJVOOYE` |

- 第一段（机器）与第三段（`node_uuid` 派生）**均未变化**
- **第二段变化**：`F7LR642I` → `3ZEATQL3`
- 第二段在**三台不同机器上取值相同** ⇒ 不是机器指纹

### 3.3 已排除的原因（逐项核查过）

| 怀疑点 | 核查方法与结果 |
|---|---|
| license 过期 / 日期轮换 | **RC10 今天（20:58）用同一份 license 激活成功** → `Load license success` / `ACTIVE_ACTIVATED` |
| RC11 改了激活代码（源码层） | RC10→RC11 的 10 个提交中**没有** activation/license/fingerprint 相关文件 |
| 激活 SDK 类变了 | `com/timecho/as.class`（38 KB，激活主类）两版 **md5 完全相同** `cb515c6f6de4` |
| 依赖 jar 变了 | `common-dependency.jar` 两版 **md5 完全相同** |
| `lib/bootstrap` 变了 | 12 个 class 文件累积 md5 **完全相同** |
| 全局 `.env` 被改 | `/data/iotdb/.env` 自 2025-03-20 未变 |
| 用旧版 `.env` 可绕过 | 拷贝 RC10 的 `.env` 后，第三段确实匹配了，但第二段仍为 `3ZEATQL3` |
| 用旧版 license 可绕过 | 机器上**只有一份 license**（`e5e3c45ab7`，35 个历史版本 + `timecho_license_new` 全同） |
| 手工写入旧指纹 | 启动时被**覆盖重算** |
| 把 `system_info` 设为 `444 root:root` 阻止覆盖 | **仍被覆盖**（进程有 sudo 权限） |
| 换成中性安装路径（`/data/iotdb/fptest`） | RC11 代码在该路径下仍 **`Load license fail`** |
| 把 RC10 的 `timechodb-server` jar 换进去 | 仍 **`Load license fail`** ⇒ 指纹也不只取决于该 jar |
| 用自动激活（`timechodb.auto.activation.api-key-file`） | 机器上**没有 API Key 文件**，无法自助激活 |
| 用 `chattr +i` 把 `system_info` 设为不可变 | `lsattr` 显示标志未生效，文件被重建为 `3ZEATQL3`⇒ **启动时必然重算并重写，缓存值不可信** |
| **把系统时间回拨到 2026-10-22**（RC10 当日激活成功的那天） | 仍算出 `3ZEATQL3` ⇒ **排除日期/时间窗口因素**（SDK 内虽有 `licenseIssueTimestamp` 字段，但不参与本次指纹计算） |

### 3.4 结论

RC11 的构建（`timechodb-server` jar 有变化，激活类虽同名同 md5 但运行形态不同）在**本机算出了新的指纹第二段**，
现有 license 未覆盖该指纹，因此 **RC11 需要重新签发的 license**。

> 另注：源码仓库 HEAD（`ea4f835`）与包一致，说明**打包的就是这个提交**，不存在"包与源码不符"的情况。

---

## 四、解除阻塞需要什么

按新指纹签发 license（3 个 CN）：

```
172.20.70.5   02-PZPWR7DQ-3ZEATQL3-PXAEDQLR
172.20.70.4   02-UHGNVQ4C-3ZEATQL3-EDBU4HBG
172.20.70.26  02-SBACZCP3-3ZEATQL3-3CJVOOYE
```

DN 专属节点（.14/.27/.30）无需单独签发。

拿到 license 后放置方式：

```bash
VER=v20121rc11_1023_ea4f835
# 每台 CN 放自己的 license
sudo cp <该节点的 license> /data/iotdb/$VER/activation/license
sudo chown -R cluster:cluster /data/iotdb/$VER/activation
# 无需手工创建 system_info，启动时会自动生成
```

校验方式：

```bash
sudo grep -m1 'Load license' /data/iotdb/$VER/logs/log_confignode_all.log
# 期望: com.timecho.as:465 - Load license success.
```

---

## 五、解除阻塞后的执行计划

skill 配置已切到 RC11（`conf/env.conf` 中 `V_TESTDB=v20121rc11_1023_ea4f835`），拿到 license 后直接执行：

```bash
cd /data1/iotdb/testcase/MigrateRegionTest/skill_case/membuf_skill

# 阶段 1：IoTConsensus 功能
DATA_CONSENSUS=IoTConsensus   bash tools/run_until_done.sh --set all --tries 3
# 阶段 2：IoTConsensus 性能
DATA_CONSENSUS=IoTConsensus   bash tools/run_perf.sh --set all
# 阶段 3：IoTConsensusV2 功能
DATA_CONSENSUS=IoTConsensusV2 bash tools/run_until_done.sh --set all --tries 3
# 阶段 4：IoTConsensusV2 性能
DATA_CONSENSUS=IoTConsensusV2 bash tools/run_perf.sh --set all
```

预计总时长约 **11 小时**（参照 RC10 实测：功能 4h48m + 性能 1h + 功能 3h31m + 性能 1h02m）。

### RC11 值得重点观察的三处（与 RC10 的问题对应）

RC11 的 10 个提交里，有两条正好命中 RC10 报出的问题：

| RC11 提交 | 对应的 RC10 问题 |
|---|---|
| `02d5ed9f827` / `92a9a919e5a` Fix same-region flush stalls during write admission | MB-04 / MB-05 的刷盘相关现象 |
| `972b36537d9` [Pipe] Unify TsFile parser allocation and resize quotas | [`DEFECT_RC10_V2_REPLICA.md`](DEFECT_RC10_V2_REPLICA.md) §5.1 的固定 2 MB reader 缓冲问题 |

因此 RC11 回归时应重点复核：

1. **MB-03 / MB-14**（Pipe 池被压干导致 TsFile 传输 OOM）—— 看 `PipeRuntimeOutOfMemoryException` 是否消失
2. **MB-04**（`syncLag` 恒为 1）—— 看是否仍不归零
3. **MB-11**（副本数据落 `unsequence/`）—— 预计仍存在（LOAD 路径硬编码 `setSeq(false)`，本次未改）
