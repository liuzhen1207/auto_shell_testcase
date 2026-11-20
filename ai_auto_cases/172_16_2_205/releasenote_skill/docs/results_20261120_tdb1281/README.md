# TDB-1281 旧 PLAIN resource 加载后升级为 ARRAY 验证（2.0.13.1 RC3 `ac7f95e`）

| 项 | 内容 |
| --- | --- |
| 来源工作项 | TDB-1281：PlainDeviceTimeIndex 复用 ArrayDeviceTimeIndex 的 serialize 方法（相当于 serialize 时更新为新版 resource 文件） |
| 修复提交 | `0f4fc87010` support serializing plain device time index (#17285) |
| 验证版本 | 2.0.13.1 **RC3** `ac7f95e`，3C5D（SR3/DR2，IoTConsensus V1），普通模式 |
| 验证用例 | **RN-218**（干净环境 + CN/DN 日志窗口） |
| 结果 | **PASS**（9 项断言，日志 `err=0 warn=0 unexp=0`） |

## 一、对需求的理解（也是本用例的判据）

`PlainDeviceTimeIndex extends ArrayDeviceTimeIndex`。修复前它自己重写了 `serialize()` 并直接
`throw new UnsupportedOperationException()`，即**老格式（PLAIN）的设备索引无法落盘**。

修复做了两件事：

1. 删除 `PlainDeviceTimeIndex.serialize()` → 继承 `ArrayDeviceTimeIndex.serialize()`；
2. `ArrayDeviceTimeIndex.serialize()` 写类型标记时固定写 `ARRAY_DEVICE_TIME_INDEX_TYPE(3)`，
   不再写 `getTimeIndexType()`（对 Plain 来说是 1）。

因此效果是：**加载到老的 PLAIN 索引后，只要再 serialize（flush / 重启 / compaction），
`.tsfile.resource` 就会被写成新版 ARRAY 格式（type=3）**，即“serialize 时更新为新版 resource 文件”。

`.tsfile.resource` 布局：`byte[0] = VERSION_NUMBER(1)`，`byte[1] = timeIndexType`
（1 = PLAIN，3 = ARRAY）。

## 二、验证方法

1. 建库 `rn1281`、写 3 行数据、`flush` 产出 `.tsfile.resource`；
2. 定位该文件（遍历 5 个 DN），确认 `byte[1] = 3`（ARRAY）；
3. **模拟老版本文件**：停 DN → 备份 → 把 `byte[1]` 改成 `1`（PLAIN）→ 启动 DN；
4. 校验：集群 8/8、数据可查（count=3）、**加载后文件 `byte[1]` 已变为 3**；
5. 二次重启 DN，校验数据仍完整、类型仍为 3。

## 三、实测结果

| 检查点 | 实测 |
| --- | --- |
| 初始 resource 类型 | `timeIndexType=3`（ARRAY） |
| 改为旧格式后 | `timeIndexType=1`（PLAIN） |
| 重启加载老文件 | 集群 8/8，数据可查 `count=3` |
| **加载后落盘类型** | **`timeIndexType=3`（已升级为新版 ARRAY 格式）** |
| 二次重启 | 8/8、`count=3`、类型仍 3 |

**结论：RC3 已验证通过** —— 老 PLAIN resource 可正常加载，并在再次落盘时升级为 ARRAY 新版格式，数据不受影响。

## 四、日志检查

`RN_LOG_CHECK=1` 逐用例窗口：**`err=0 warn=0 unexp=0`**。
（用例包含两次 DN 重启，窗口内连接中断/选主等噪声已被白名单过滤。）

## 五、文件

| 文件 | 内容 |
| --- | --- |
| `cases/V2_1281_v2.0.13.1.sh` | RN-218 |
| `RN-218.out` | 断言明细（PASS） |
| `RN-218.tsv` | 结果行（PASS，含 `[LOG err=0 warn=0 unexp=0]`） |
