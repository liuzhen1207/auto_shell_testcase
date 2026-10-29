# RC10 部署与激活记录

## 一、部署

1. 测试包：`/data1/iotdb/testdb/v20121rc10_1021_c60ce63/timechodb-2.0.12.1-bin.zip`（102 MB）
2. 客户端解压一次 → `tar czf /tmp/rc10.tgz` → `scp` 到 6 个节点 → 解压到 `/data/iotdb/v20121rc10_1021_c60ce63`
3. 权限：`chown -R cluster:cluster`，`chmod +x sbin/*.sh`
4. 客户端侧同样解压一份（提供 `start-cli.sh`，否则 skill 的 CLI 路径不存在）
5. 校验：每节点 114 MB、`lib/*.jar` 存在、`sbin/start-datanode.sh` 可执行

> ⚠️ 不要用 `tar czf - | ssh ... tar xzf -` 流式传输：本次实测会截断，解压后目录只有 0～4 KB。
> 必须 `scp` 整包再解压。

## 二、企业版激活（关键）

### 现象

复用 RC9 的 `activation/license` 后启动，ConfigNode 报：

```
ERROR com.timecho.as:469 - Load license fail.
org.apache.iotdb.commons.exception.LicenseException:
    This license is not allowed to activate this ConfigNode.
```

DataNode 处于 `ReadOnly(UNACTIVATED)`，写操作返回：

```
307: Schema write operations are not allowed until this node is activated.
```

### 根因

RC10 首次启动会在**自身安装目录**生成 `.env`（内含随机 `node_uuid`），
而 `activation/system_info` 的**第三段由该 uuid 派生**：

| 节点 | RC9 指纹 | RC10 首次启动生成的指纹 |
|---|---|---|
| 172.20.70.5 | `02-PZPWR7DQ-F7LR642I-PXAEDQLR` | `02-PZPWR7DQ-F7LR642I-BRMZDOTX` |
| 172.20.70.4 | `02-UHGNVQ4C-NGLCNW3P-EDBU4HBG` | `02-UHGNVQ4C-NGLCNW3P-JMV2ZV3U` |
| 172.20.70.26 | `02-SBACZCP3-4KDI3ZAF-3CJVOOYE` | `02-SBACZCP3-4KDI3ZAF-BWXJ5X6Z` |

前两段是机器指纹（不变），第三段随 uuid 变化 ⇒ 旧 license 不匹配。
直接拷贝 RC9 的 `system_info` 无效：CN 启动时总会按本地 `.env` 重写该文件。

### 解决

把各节点 **RC9 目录下的 `.env`** 复制到 RC10 目录，使 RC10 沿用原 `node_uuid`：

```bash
OLD=v20121rc9_1020_d206dc2; VER=v20121rc10_1021_c60ce63
for h in 172.20.70.5 172.20.70.4 172.20.70.26 172.20.70.14 172.20.70.27 172.20.70.30; do
  ssh cluster@$h "sudo cp /data/iotdb/$OLD/.env /data/iotdb/$VER/.env && sudo chown cluster:cluster /data/iotdb/$VER/.env"
  ssh cluster@$h "sudo mkdir -p /data/iotdb/$VER/activation && sudo cp /data/iotdb/$OLD/activation/license /data/iotdb/$VER/activation/license && sudo chown cluster:cluster /data/iotdb/$VER/activation/license"
  ssh cluster@$h "sudo rm -f /data/iotdb/$VER/activation/system_info"
done
```

重启后指纹恢复为 RC9 原值，`Load license fail` 计数为 **0**，`show cluster` 全部 **ACTIVATED**。

### 注意

- 指纹在**同一安装路径**下稳定（重建 `data`、重启均不变），可复现。
- 若把 RC10 换到别的路径安装，指纹第三段会再次变化，需重新处理。

## 三、验证

```sql
show cluster;   -- 期望 8/8 Running、BuildInfo c60ce63、ACTIVATED
create database root.acttest;
insert into root.acttest.d1(time,s1) values (1,1);
select count(s1) from root.acttest.**;   -- 期望 1
```
