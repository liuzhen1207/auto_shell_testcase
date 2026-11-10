# 升级兼容验证：2.0.12.1 RC12 → 2.0.13.1 RC2（原地升级）

| 项目 | 内容 |
| --- | --- |
| 源版本 | TimechoDB **2.0.12.1 / `c05111d`**（RC12） |
| 目标版本 | TimechoDB **2.0.13.1 / `83183d0`**（RC2） |
| 方式 | 原地升级：停集群 → 只替换 `lib/sbin/tools`（保留 `data`/`conf`/`activation`）→ 启动 |
| 结果 | **通过**：视图与数据完整保留，旧视图 `auto_sync_schema` 行为等同 false，`CREATE OR REPLACE` 可开启 |
| 环境 | 172.16.2.205 集群（3 CN + 5 DN），目录 `/data{,1}/iotdb/v20121rc12_up` |

---

## 一、验证步骤与结果

### 1. 旧版本（2.0.12.1 RC12）建视图与数据

```sql
create database up_t2t_162410;
create timeseries root.up_t2t_162410.dev01.s1 double;
insert into root.up_t2t_162410.dev01(time,s1) values(1000,1.5);
create view up_t2t_162410.v1(dev string tag) as root.up_t2t_162410.**;   -- 旧语法，无 auto_sync 属性
```

旧版本可正常创建树转表视图（此时版本尚无 `auto_sync_schema`）：

```
|  time|TIMESTAMP|    TIME|
|   dev|   STRING|     TAG|
|    s1|   DOUBLE|   FIELD|
```

### 2. 原地升级

- 停掉全部 CN/DN；
- 每节点：`rm -rf lib sbin tools` → 解包 RC2 的 `lib sbin tools`；`activation` 用 RC2 构建的；
- **保留** `data`（含 TsFile、元数据）、`conf`（集群地址与端口不变）；
- 启动顺序：CN26 → CN27/28 → 5 个 DN。

结果：

```
|     3|  DataNode|Running|     172.16.2.2|       10730|2.0.13.1|  83183d0|     ACTIVATED|
|     4|  DataNode|Running|     172.16.2.3|       10730|2.0.13.1|  83183d0|     ACTIVATED|
Running=8
```

### 3. 升级后校验

| 检查项 | 结果 |
| --- | --- |
| 旧视图是否存在 | ✅ `desc` 仍有 `time/dev/s1` 三列 |
| 旧数据是否可读 | ✅ `select s1 from v1` 返回 `1.5` |
| 旧视图下新增测点是否自动补列 | ✅ **不补列**（`old_extra` 列数=0），符合"旧视图默认 false" |
| `CREATE OR REPLACE ... WITH(auto_sync_schema=true)` | ✅ 执行成功，`show create view` 显示 `auto_sync_schema=true` |
| 开启后新增测点是否补列 | ✅ `new_extra` 列数=1；且 OR REPLACE 时的全量重扫把 `old_extra` 也补了进来 |
| 集群恢复 | ✅ 8/8，版本 `83183d0` |

## 二、结论

- **数据与视图兼容**：旧版本创建的树转表视图升级后可直接查询，历史数据无损；
- **属性默认值符合需求**："旧版本创建的树转表视图，该配置项默认为 false" —— 实测行为一致（升级后新增测点不补列）；
- **开启方式可行**：无需 DROP 重建，`CREATE OR REPLACE VIEW ... WITH(auto_sync_schema = true)` 即可开启，并会顺带补扫存量测点。

## 三、升级操作清单（可复用）

```bash
OLD=v20121rc12_up          # 升级目录（保持目录名不变）
PKG=/data2/iotdb/<rc2>/pkg/timechodb-2.0.13.1-bin

# 1) 停
for ip in CN27 CN28 ...; do ssh root@$ip "bash /data/iotdb/$OLD/sbin/stop-confignode.sh"; done
for ip in DN...;        do ssh root@$ip "bash /data1/iotdb/$OLD/sbin/stop-datanode.sh"; done

# 2) 换包（保留 data/conf/activation）
for ip in CN...; do
  tar -C $PKG -cf - lib sbin tools | ssh root@$ip "rm -rf /data/iotdb/$OLD/{lib,sbin,tools}; tar -C /data/iotdb/$OLD -xf -"
done
# DN 同理，路径 /data1/iotdb/$OLD

# 3) 起（CN 先起一个，再起其余，最后 DN）
```

**两个坑（本次踩过）**：
1. 用 `ssh -n` 往远端传 tar 会把 stdin 置空，导致文件根本没解开 → 安装后 `sbin/start-*.sh` 不存在、集群起不来。**传 tar 时不要加 `-n`**；
2. `activation` 要用**目标版本**的，沿用旧版本的会被判定 `deactivated` 并自动退出。

## 四、自动化说明

升级验证依赖两套版本目录与"原地换包"流程，**未放进默认回归套件**（默认套件是单版本、可重复执行的）。
复用此流程时建议起一个独立脚本（本次用的是 `/tmp/upgrade_test.sh` + `/tmp/repair_upgrade.sh` 的组合），
先跑 RC12 建数，再换包启动，最后按上表逐项断言。
