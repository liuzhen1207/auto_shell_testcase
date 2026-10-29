# 触发器路径模式语义：`ON <设备>` 为什么不触发（**符合预期**）

> **结论先行**：这是**文档规定的行为**，不是缺陷。
> 依据：交付目录下的文档《06-流计算-触发器》（`docs/refs/06-流计算-触发器.pdf`）明确写到：
>
> > 触发器可以注册在**任意路径模式**上。被注册有触发器的**序列**将会被触发器侦听，
> > 当**序列**上有数据变动时，触发器中对应的触发方法将会被调用。
>
> 侦听对象是**序列（measurement）**。`ON root.db.d1` 指向的是**设备节点自身**，
> 它下面没有序列，因此没有任何序列被侦听 → `fire()` 不会被调用。
> 要覆盖整个设备，写 `ON <设备>.**`（或 `.*`，或逐个序列）。

- 版本：TimechoDB / IoTDB 2.0.12.1 RC5 `v20121rc5_1003_aaf460d`（`aaf460d`）
- 用例：`cases/common/md_udf_trigger.sh` 第 11 步（A/B 对照）
- 实验脚本：`docs/experiments/_trgisolate.sh`、`_trgvariant.sh`、`_trgfull.sh`

---

## 1. 实测行为（6 路对照）

同一张表、同一次 device 级写入，6 个触发器同时注册：

| 注册路径 | 指向 | fire 次数 |
| --- | --- | --- |
| `root.db.d1.s1` | 一个序列 | 2 ✅ |
| `root.db.d1.*` | 该设备下**已有及将来**的所有一级序列 | 2 ✅ |
| `root.db.d1.**` | 该设备下所有层级的序列 | 2 ✅ |
| `root.db.**` | 该库下所有序列 | 2 ✅ |
| **`root.db.d1`** | **设备节点本身（不是序列）** | **0（符合预期）** |
| `root.db.d1.s1` + `AFTER INSERT` | 一个序列 | 2 ✅ |

后两行说明：**不是** BEFORE/AFTER 事件类型的问题，而是"路径模式是否落在序列上"的问题。

## 2. 代码层面与文档一致

匹配链路：`TriggerFireVisitor:324 → TriggerManagementService.getMatchedTriggerListForPath:211
→ PatternTreeMap.getOverlapped(devicePath, measurements):191 → searchOverlapped(deviceNodes…):214`。

终端分支只收集两类值：

```java
if (pos == deviceNodes.length - 1) {                          // 走到设备节点
  for (int i = 0; i < measurements.size(); i++) {
    for (… child : node.getMatchChildren(measurements.get(i))) {
      resultSet.get(i).addAll(child.getValues());              // ① 匹配【测量名】的子节点
    }
    if (node.isMultiLevelWildcard()) {
      resultSet.get(i).addAll(node.getValues());               // ② 本节点是 ** 时（等价于"该设备所有层级序列"）
    }
  }
```

即匹配始终发生在**序列这一层**：要么命中具体测量名（①），要么命中 `*`/`**` 这类代表"一批序列"的通配节点（②，以及 `getMatchChildren` 对 `*`/`**` 的天然包含）。
`ON root.db.d1` 的值挂在设备节点上、既不匹配任何测量名也不是 `**`，因此不参与触发——**与"触发器注册在序列上"的语义完全对应**。

> 曾经把这里读成"漏收集设备节点自身的值"并当作疑似缺陷，是**错的**：
> 源码里 `searchDeviceOverlapped:267` 确实会 `addAll(node.getValues())`，但它服务的是
> **设备级**用途（`getDeviceOverlapped`，当前只被单测使用），不能拿来推"触发器也应如此"。
> **教训：源码行为与直觉不符时，先对照产品文档/设计说明，再判缺陷。**

## 3. 使用建议

| 想覆盖的范围 | 推荐写法 |
| --- | --- |
| 某个序列 | `ON root.db.d1.s1` |
| 某设备的全部序列（含以后新增的） | `ON root.db.d1.**` |
| 某设备当前已有的一级序列 | `ON root.db.d1.*` |
| 整个库 | `ON root.db.**` |
| 设备节点本身 | 无意义（设备不是序列，不会触发）——文档语义下属于用法问题，不是 bug |

## 4. 用例现状

`MD-U01` 第 11 步把它写成 **A/B 硬断言**：
- `ON <设备>` **必须不触发**（符合文档语义）；
- 阳性对照 `ON <设备>.**` **必须触发**（覆盖该设备的序列）；
两者若有一个反转，用例会 FAIL，提醒复核文档与实现。
