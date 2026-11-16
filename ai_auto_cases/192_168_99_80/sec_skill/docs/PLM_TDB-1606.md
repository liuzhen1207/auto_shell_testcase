# PLM 提单记录：TDB-1606（password_reuse_interval_days 显式 0 被内部改写为 1 天）

| 项目 | 内容 |
| --- | --- |
| PLM 工作项 | **TDB-1606**（itemId **2326**，seq 1606） |
| 链接 | <https://plm.infra.timecho.com/iterations?productId=1&itemId=2326> |
| 标题 | 【V2.0.13.1】【安全模块-身份鉴别】`password_reuse_interval_days` 显式配置为 0（需求「无历史约束」）被内部改写为 1 天；不显式设置（默认无该键）时无此问题 |
| 类型 / 优先级 / 状态 | 缺陷 / **P3** / 排期确认 |
| 迭代 / 问题发现版本 | **V2.0.14.1** / **V2.0.13.1** |
| 负责人 / 所属组长 / 验证人员 | **江天** / 江天 / **刘珍** |
| 模型 / 功能模块 / 需求来源 | 通用 / 安全-身份鉴别-密码防爆破 / 测试需求 |
| 描述长度 | 5281 字符（HTML） |
| 创建时间 | 2026-11-16 18:00:10 |

## 1. 提单命令（可复现）

```powershell
$env:TIMECHO_PLM_TOKEN="<PLM PAT>"
plm-cli rn create --product-id 1 `
  --title '【V2.0.13.1】【安全模块-身份鉴别】password_reuse_interval_days 显式配置为 0（需求「无历史约束」）被内部改写为 1 天；不显式设置（默认无该键）时无此问题' `
  --description-file D:\IDEA\deepseek\ip99_80\sec_skill\docs\DEFECT_password_reuse_side_effect.html `
  --priority P3 --iteration-name V2.0.14.1 `
  --owner ou_24b6b584cbe0a1f4ce8ecae7edc1dd08 `
  --verifier ou_31242c489e94d0c017aaf0e2393d9232 `
  --start-time 2026-11-16 --item-type 缺陷 `
  --set 'cf_1b404e0a05e0=安全-身份鉴别-密码防爆破' `
  --set 'cf_e12d66c788ae=通用' `
  --set 'cf_cb838695b154=测试需求' `
  --set 'cf_6e859ac69388=V2.0.13.1' `
  --non-interactive --yes --json
# -> id=2326, seq=1606, url=https://plm.infra.timecho.com/iterations?productId=1&itemId=2326
```

## 2. 回查（`rn get --id 2326`）

```text
编号=TDB-1606  类型=缺陷  优先级=P3  状态=排期确认
迭代=V2.0.14.1  问题发现版本=V2.0.13.1
负责人=江天  所属组长=江天  验证人员=刘珍
模型=通用  功能模块=安全-身份鉴别-密码防爆破  需求来源=测试需求
描述长度=5281
```

## 3. 字段取舍说明

1. **功能模块**为必录字段，但 PLM 选项里没有"强安全级别密码/密码策略"，只有
   `安全-身份鉴别-密码防爆破` 与 `安全-身份鉴别-多因素认证`；本单按最接近项填 `安全-身份鉴别-密码防爆破`，
   并在描述「十一、备注」中说明实际范围是"强安全级别密码（历史口令重用策略）"。
2. **优先级 P3**：仅在"显式把 `password_reuse_interval_days` 配成 0"时触发；干净默认（conf 无该键）无问题；
   策略偏严而非绕过，非安全漏洞。
3. **标题**按用户要求包含"不显式设置（默认无该键）时无此问题"，避免研发误以为是默认即触发。

## 4. 关联材料

| 文件 | 内容 |
| --- | --- |
| `sec_skill/docs/DEFECT_password_reuse_interval_days_0.md` | 完整缺陷报告（含范围更正、源码定位、修复建议） |
| `sec_skill/docs/DEFECT_password_reuse_side_effect.html` | 本单描述 HTML 原文 |
| `sec_skill/cases/password/sec_password_reuse.sh` | 回归用例 SEC-05（默认/-1/=1 硬门禁；显式 0 仅 WARN） |
| `sec_skill/docs/RESULTS_dual_mode_20261116.md` | 双模式结果（普通 + 三权分立） |

## 5. 源码位置

- `iotdb-core/node-commons/src/main/java/org/apache/iotdb/commons/conf/CommonConfig.java:3428`（`0 → 1` 改写，缺陷点）
- `iotdb-core/datanode/src/main/java/org/apache/iotdb/db/utils/DataNodeAuthUtils.java:186-206`（`<=0` 即禁用）
- `iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/IoTDBDescriptor.java:1196、2880`（启动/热加载都经 setter）
- `iotdb-core/node-commons/src/assembly/resources/conf/iotdb-system.properties.template:2290-2297`（默认 0 与注释）
