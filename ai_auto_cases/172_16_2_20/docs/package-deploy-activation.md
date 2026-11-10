# 新版本包部署与激活（3C5D，实测流程）

> 适用：把一个新的 TimechoDB 发行包部署到本 3C5D 集群（3 CN .16/.17/.18 + 5 DN .19/.21/.22/.23/.24），并沿用既有激活状态。
> 基于 2026-11-10 部署 2.0.13.1 RC2（`83183d0`）的实测，含踩过的坑。

## 一、身份继承：`.env` + `activation/`，缺一不可

节点身份由**两项**共同构成，都在实例根目录（`data/` 之外）：

| 文件 | 内容 | 作用 |
| --- | --- | --- |
| `.env` | `node_uuid` | 首次启动随机生成，**参与机器码计算** |
| `activation/system_info` | 机器码（`02-...`） | 由机器信息 + `node_uuid` 生成 |
| `activation/license` | 已落盘激活码 | 激活成功后写入 |

**规则**：新包要沿用旧实例激活状态，必须在**新包首次启动前**，把旧实例的 `.env` **和**整个 `activation/` 逐节点原样复制过去（旧 CN1→新 CN1、旧 CN2→新 CN2……），严禁把一个节点的身份文件广播到全部节点。

### 本次踩的坑

只复制了 `activation/`、没复制 `.env` → 新包首启生成新 `node_uuid` → 机器码变化 → license 被拒：

```
License file detected during ConfigNode's starting.
ERROR Load license fail.
org.apache.iotdb.commons.exception.LicenseException: This license is not allowed to activate this ConfigNode.
```

现象是 `SHOW CLUSTER` 里 8 台都在、版本也对，但全是 `UNACTIVATED`，DN 为 `ReadOnly`，DDL 无法执行。**对照实验**：同一份 `activation/` 在旧包（RC1）上能 `ACTIVE_ACTIVATED`，在新包（RC2）上被拒——差别就是 `.env`。

### 已经误启动的补救

不用重新申请 license：

1. 停止新包全部节点；
2. 备份新包已生成的 `.env` / `activation/`（留证，别直接删）；
3. 从旧实例逐节点复制 `.env` + 整个 `activation/`；
4. 重启，`show cluster` 应恢复 `ACTIVATED`。

## 二、`data/` 与激活无关，可以清

`cluster_ctl reset` 会 `rm -rf $NEW/data $NEW/logs`，**不影响激活**——激活状态在 `.env` + `activation/`。实测旧包经历上百轮 reset 一直是 `ACTIVATED`。

所以「清数据重建集群」和「继承激活」两件事互不冲突：先复制身份文件，再随便清 data。

## 三、部署步骤（逐节点）

```bash
NEW=/data1/iotdb/v2013x_xxx_<build>     # 新包安装路径
OLD=/data1/iotdb/<旧实例>                # 旧实例路径（继承身份用）

# 1) 分发（用 scp；不要用 `ssh -n host "cat > f" < file`，-n 会吞掉 stdin）
for i in 16 17 18 19 21 22 23 24; do
  scp -q pkg.zip root@172.16.2.$i:/tmp/pkg.zip &
done; wait

# 2) 解压（注意：node21/22/23 没有 unzip，用 JDK 的 jar）
cd /tmp && unzip -q -o pkg.zip -d /tmp/x       # 有 unzip 的节点
cd /tmp && $JAVA_HOME/bin/jar xf /tmp/pkg.zip  # 没有 unzip 的节点

# 3) 铺开 + 继承身份
cp -a /tmp/x/<pkg-dir>/. $NEW/
cp -a $OLD/conf/. $NEW/conf/                  # 保持集群名/端口/副本/协议
cp -a $OLD/.env $NEW/.env                     # ← 关键，别漏
rm -rf $NEW/activation && cp -a $OLD/activation $NEW/activation
rm -rf $NEW/data $NEW/logs                    # 需要干净集群时
```

## 四、启动顺序

1. **3 台 CN 必须同时启动**。有存量数据/既有 Raft 组时，只起 seed CN 选不出 leader，会一直 `PRE_VOTE REJECTED received 0 response(s)`；
2. 等 3 台 CN 日志出现 `has successfully started and joined`；
3. 再起 5 台 DN；
4. 等 `SHOW CLUSTER` 8 台 `Running`。

```bash
for i in 16 17 18; do ssh root@172.16.2.$i "setsid bash $NEW/sbin/start-confignode.sh -d >/tmp/cn_$i.log 2>&1 </dev/null &"; done
# 等待 CN 3/3 后再起 DN
for i in 19 21 22 23 24; do ssh root@172.16.2.$i "setsid bash $NEW/sbin/start-datanode.sh -d >/tmp/dn_$i.log 2>&1 </dev/null &"; done
```

## 五、验收三查

| 检查 | 期望 | 方法 |
| --- | --- | --- |
| 版本 | `BuildInfo` = 目标 build（如 `83183d0`） | `SHOW CLUSTER` |
| 激活 | 8 台 `ACTIVATED` / `ACTIVATED(W)` | `SHOW CLUSTER`；CN 日志 `ConfigNode's activation status is ACTIVE_ACTIVATED` |
| 角色 | 8 台 `Running`，无 `ReadOnly` | `SHOW CLUSTER` |

补充：`SHOW SYSTEM INFO` 返回各 ConfigNode 机器码，可与 `activation/system_info` 逐节点比对，确认身份继承正确。

## 六、其他已知坑

1. **2.20 上没有服务端安装**：跑 CLI 需要单独解压一份 client（`unzip pkg.zip -d .../client`），再把 `CLI=/data2/iotdb/<ver>/client/<pkg>/sbin/start-cli.sh` 传给脚本。
2. **`ssh -n` 吞 stdin**：用 `ssh -n` 传文件会得到 0 字节，必须用 `scp`。
3. **节点无 `unzip`**：本集群 node21/22/23 没有 unzip，用 `$JAVA_HOME/bin/jar xf` 代替。
4. **DN/CN 重启竞态**：`kill -9` 后立即拉起可能 `Fail to start server` 或 Ratis `another process has already locked the storage directory`，需等 5~10 秒再起，并重试。
5. **日志按天覆盖 + `cluster_ctl reset` 会删日志**：需要保留现场时，必须在下一轮 reset 前把日志拷走。
