# PROACTIVE 扩充用例（第二批，PGC-53 ~ PGC-84）

> 在 [PROACTIVE-testcases-3C5D.md](PROACTIVE-testcases-3C5D.md) 基础上扩充，重点补升级/混合版本/回退、并发与故障、CUSTOM 边界、配额与配置边界。
> 环境：3C5D（CN .8/.9/.10，DN .11~.15），RC1 `ab6d3de` / RC12 `c05111d` 可切换。

## A. 升级 / 混合版本 / 回退

**PGC-53 RC12→RC1 升级后显式 AUTO 保留**：升级后 `SHOW CONFIGURATION` 与 AUTO 行为均保持。
**PGC-54 升级后历史 RegionGroup 与映射保留**：升级前后 RegionId 集合一致。
**PGC-55 升级后历史数据可读**：`select count/明细` 一致。
**PGC-56 升级后切 PROACTIVE 正常扩容**：单库 9 slot → 2/7。
**PGC-57 升级后切回 AUTO 不回收**：组数保持。
**PGC-58 混合版本下写 PROACTIVE 配置**：旧 CN 拒绝、Leader 是否回滚。
**PGC-59 混合版本下启动新 DN**：新 DN 注册与组分配。
**PGC-60 混合版本下建库/写入**：旧 CN 是否可服务。
**PGC-61 全部节点升级完成后再切 PROACTIVE**：应成功。
**PGC-62 RC1→RC12 回退前恢复 AUTO**：配置可解析。
**PGC-63 RC1→RC12 回退后数据可读**：元数据兼容。
**PGC-64 回退后已有 PROACTIVE 组**：旧版本能否识别/保留。
**PGC-65 回退后再升级**：二次升级幂等。
**PGC-66 升级过程中 ConfigNode 选主**：升级窗口内 Leader 切换。
**PGC-67 升级过程中新建组请求**：请求失败/重试行为。
**PGC-68 升级后配置模板默认值**：省略配置项时默认 PROACTIVE。

## B. 配置边界与并发

**PGC-69 空字符串策略值**：拒绝。
**PGC-70 前后空格策略值**：拒绝或 trim（需确认）。
**PGC-71 超长策略值**：拒绝。
**PGC-72 特殊字符/SQL 注入式策略值**：拒绝且无注入。
**PGC-73 重复设置相同策略值**：幂等。
**PGC-74 两个策略同时热更新（并发）**：最终一致。
**PGC-75 热更新与建库并发**：新库使用哪个策略。
**PGC-76 热更新与扩容请求并发**：组数符合哪次配置。
**PGC-77 配置热更新时 Leader 切换**：最终一致/部分应用。
**PGC-78 无 Leader 时热更新**：报错且不悬挂。
**PGC-79 只读/权限不足用户热更新**：拒绝。
**PGC-80 重启后热更新值是否持久**：重启保持。
**PGC-81 配置文件与热更新冲突**：重启后以哪个为准。
**PGC-82 `SHOW CONFIGURATION` 与实际行为一致性**：显示值=生效值。

## C. CUSTOM 边界

**PGC-83 CUSTOM 配额小于最小组数**：按 min/上限取哪个。
**PGC-84 CUSTOM 配额大于资源上限**：是否被钳制（当前疑点）。
**PGC-85 CUSTOM 建库未指定配额**：使用默认最小数量。
**PGC-86 CUSTOM 下多库配额独立**：互不影响。
**PGC-87 CUSTOM 切 PROACTIVE**：已有组保留、后续按 PROACTIVE。
**PGC-88 CUSTOM 下删除库再建**：配额回收。

## D. 故障与并发

**PGC-89 建组过程中 DataNode 宕机**：Procedure 重试/失败。
**PGC-90 建组过程中 ConfigNode 重启**：恢复后只补差额。
**PGC-91 建组过程中 Leader 切换**：部分成功重试。
**PGC-92 同 slot 并发建组请求**：不重复建组。
**PGC-93 组创建失败后客户端重试**：幂等。
**PGC-94 资源上限降低（删库/停节点）时已有组**：保留。
**PGC-95 资源上限升高后已有 slot 写新时间分区**：补组到新上限。
**PGC-96 Disabled 全组补组**：补 1 组且不超上限（需注入）。

## E. 时序语义

**PGC-97 乱序写入跨多个时间分区**：组选择与数据正确。
**PGC-98 晚到数据写入历史分区**：继承规则。
**PGC-99 TTL 过期后 slot 计数**：不减少（需确认）。
**PGC-100 删除设备/测点后 slot 计数**：不回收。
**PGC-101 新 measurement 不增 slot**：组数不变。
**PGC-102 聚合查询跨新旧组**：结果正确。
**PGC-103 合并/compaction 与建组并发**：无异常。
**PGC-104 数据导入触发建组**：批量导入。

## 不可执行（环境限制）

- 6D/9D、1C3D、3C3D 等拓扑；
- Disabled 注入（需内部接口）；
- Simple/Ratis 共识组合；
- 容器 CPU 变化；
- workbench/多租户。

## 执行优先级建议

1. PGC-83/84（CUSTOM 边界，已有疑点）；
2. PGC-89/90/91（建组故障恢复）；
3. PGC-74/77/82（配置并发与一致性）；
4. PGC-97~100（时序语义）；
5. PGC-62~65（回退）。

## 已执行结果（2026-11-06 / 11-09，RC1 3C5D）

| 用例 | 场景 | 实测 | 结论 |
| --- | --- | --- | --- |
| PGC-83 | CUSTOM 配额 1/1，最小默认 1/2 | 建库被拒绝（525），后续写入自动建库得到 1/2 | 已澄清：**不是缺陷**，是校验拒绝 + 写入自动建库；应验收 525 |
| PGC-74 | 并发 SET 两个策略为 AUTO | 两参数均变为 AUTO | PASS（SHOW CONFIGURATION 第一列为生效值） |
| PGC-82 | PROACTIVE 9 slot（多库共存） | 1/4 | 与 3 个普通库的分摊上限一致，显示值与行为一致 |
| PGC-97 | 乱序/跨 5 个时间分区写入 | 6 行可查，组 1/2 | PASS（数据完整） |
| PGC-09 | RC12→RC1 升级 | 数据/组保留、AUTO 保留、升级后 PROACTIVE 2/7 | PASS |
| PGC-58 | 混合版本下 SET PROACTIVE | 旧 CN 报 PROACTIVE doesn't exist，但 SHOW CONFIG 已变 PROACTIVE | **部分应用，疑点** |

### SHOW CONFIGURATION 列含义

实测两列分别为“生效值 / 默认值”；判断配置是否生效看第一列。
### 11-09 新增执行

| 用例 | 场景 | 结果 |
| --- | --- | --- |
| PGC-89 | 建组中停 DN | 9 次写入全成功、DN 恢复后 5 Running、无重复组，PASS |
| PGC-90 | 建组中重启 CN | 9 次写入全成功、集群恢复，PASS |
| PGC-91 | 建组中 kill Leader | 9 次写入全成功、重启后 8 Running，PASS |
| PGC-62~65 | RC1→RC12 回退 | 8 节点 Running、数据可读、RC12 拒绝 PROACTIVE，PASS |

详见 [PGC-failure-rollback-result.md](PGC-failure-rollback-result.md)。
## CUSTOM + ALTER 用例（PGC-105 ~ PGC-112，已执行 PASS）

> 产品确认：CUSTOM 独立于 AUTO 资源公式；双 CUSTOM 跳过 max 重算，混合只重算 AUTO 侧；ALTER 只能增大/保持，降低返回 525，即使空库。

| 用例 | 场景 | 实测 | 结果 |
| --- | --- | --- | --- |
| PGC-105 | CUSTOM 建库 MAX_SCHEMA=2 / MAX_DATA=3，首个分区 | 2/3 | PASS（一次补齐） |
| PGC-106 | ALTER 增大到 3/5 | 仍 2/3 | PASS（不立即建组） |
| PGC-107 | 新 slot 写入后 | 3/5 | PASS（一次补齐到目标） |
| PGC-108 | ALTER 降低 5→2 | 525 current max=5 | PASS |
| PGC-109 | 空库 4→3 | 525 current max=4 | PASS |
| PGC-110 | ALTER 到 1（< 默认 2） | 525 default=2 | PASS |
| PGC-111 | 混合 Schema=CUSTOM(3)、Data=AUTO，9 slot | 3/2（AUTO 比例未达，仍 min=2） | PASS |
| PGC-112 | 双 CUSTOM 新增第二个库 | 1/2 不变（不重算） | PASS |

其他 CUSTOM 边界：
**PGC-113** ALTER 上限对表模型生效；**PGC-114** ALTER 后重启 ConfigNode 上限保持；**PGC-115** ALTER 上限与 TTL/时间分区间隔同语句修改；**PGC-116** ALTER 失败（降低）后原上限不变；**PGC-117** 双 CUSTOM 下节点增减不改变已有 max。
## 补充用例执行结果（2026-11-10，纯 RC1 干净集群）

| 用例 | 场景 | 结果 |
| --- | --- | --- |
| PGC-118 | 逐 slot 增长（1~6） | Schema 1→2（第 2 个 slot）、Data +1/slot；PASS |
| PGC-119 | 新组承接后续时间分区 | d1 新分区落到新组 20（EXPLAIN），PASS |
| PGC-120 | 阈值边界（非整除） | 新分区落到新组 26/27，PASS |
| PGC-121 | Leader 切换 | 组数与历史映射保留；优选映射恢复需间接观测，部分 PASS |

观测手段：EXPLAIN ... 的 Partition: <RegionGroupId> 可看时间分区落组；SHOW DATA REGIONS 的 TimeSlotNum 不实时更新，不能用于落组判断。

详见 [PROACTIVE-extra-cases-result.md](PROACTIVE-extra-cases-result.md)。
## PGC-124/125/126 执行结果（2026-11-10）

| 用例 | 场景 | 结果 |
| --- | --- | --- |
| PGC-124 | DN 存活数不足 | **PASS**：Schema 2/3 存活时 DDL/DML 成功（Data 仅 1 副本）；Schema 1/3 存活时 DDL/DML 均返回 906，符合 Ratis 多数派 + IoTConsensus 任一副本语义 |
| PGC-125 | 建组中停 DN | 6 次写入全成功、3 组无重复、恢复后保持，PASS |
| PGC-126 | remove DN（cap 6）→ 加回（cap 7） | 9 slot 先 6 组，加回后新分区补到 7 组，PASS |

PGC-124 现象见 [PROACTIVE-dn-shortage-result.md](PROACTIVE-dn-shortage-result.md)，尚未提交 PLM。
## PGC-127 / PGC-122 执行结果（2026-11-10）

| 用例 | 场景 | 结果 |
| --- | --- | --- |
| PGC-127 | 多库取整（3 库 / 5 库） | 3 库 Data=3，5 库新库 Data=2；已有 3 组保留；PASS |
| PGC-122 | 混合版本残留 | 301 复现；旧 CN 重启仍 AUTO（不回填）；新 Leader 下 9 slot→7；切主后新库只建到 2 组（异常，待查）；部分验证 |

详见 [PROACTIVE-pgc127-122-result.md](PROACTIVE-pgc127-122-result.md)。
## PGC-122 二次验证结论（2026-11-10）

- 部分应用 301 复现；CN0/CN1=PROACTIVE，CN2(2.0.12.1)=AUTO；
- 旧 CN 重启仍 AUTO；
- 新 CN 为 Leader：9 slot → Data=7；
- **kill 新 Leader 后旧 CN10 接管**（CN10 日志显示建组 DataRegion id=3/4 成功），9 slot 只建到 **2 组**（AUTO 行为）→ 行为翻转确认。

详见 [PROACTIVE-pgc122-final.md](PROACTIVE-pgc122-final.md)。该证据已追加到 TDB-1047（描述第九节）。
## RC2 用例执行结果（2026-11-10）

| 用例 | 结果 |
| --- | --- |
| PGC-128 表模型 CUSTOM/ALTER | 2/4 → ALTER 不建组 → 新 device 3/6，PASS |
| PGC-129 权限 | 普通用户 803，管理员成功，PASS |
| PGC-130 审计 | enable_audit_log 后产生 CONTROL 审计记录，PASS（基础） |
| PGC-131 删除不回收 | 7 组 / 9 slot 不变，PASS |
| PGC-132 INHERIT/SHUFFLE | INHERIT 同组；SHUFFLE 分散到 18/19，PASS |
| PGC-133 热更新重启 | AUTO 1/2 → 重启后 PROACTIVE 2/7，PASS |
| PGC-135 RC12→RC2 升级 | 数据/组保留、AUTO 保留、切 PROACTIVE 2/7，PASS |
| PGC-136 性能 | 未执行（缺指标） |

详见 [RC2-cases-final.md](RC2-cases-final.md)。