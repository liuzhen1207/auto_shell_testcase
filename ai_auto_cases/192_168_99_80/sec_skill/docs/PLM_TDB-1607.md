# PLM 提单记录：TDB-1607（普通模式下非授权 UNLOCK 触发 NPE，返回 305）

| 项目 | 内容 |
| --- | --- |
| PLM 工作项 | **TDB-1607**（itemId **2327**，seq 1607） |
| 链接 | <https://plm.infra.timecho.com/iterations?productId=1&itemId=2327> |
| 标题 | 【V2.0.13.1】【安全模块-身份鉴别】普通模式下无 SECURITY 权限用户执行 `ALTER USER ... ACCOUNT UNLOCK` 触发 NPE，返回 305 INTERNAL_SERVER_ERROR（应 803；与 TDB-899 属不同路径） |
| 类型 / 优先级 / 状态 | 缺陷 / **P2** / 排期确认 |
| 迭代 / 问题发现版本 | **V2.0.14.1** / **V2.0.13.1** |
| 负责人 / 所属组长 / 验证人员 | **高宏志** / 江天 / **刘珍** |
| 模型 / 功能模块 / 需求来源 | 通用 / 安全-身份鉴别-密码防爆破 / 测试需求 |
| 描述长度 | 9479 字符（HTML） |
| 创建时间 | 2026-11-17 10:10:10 |

## 1. 提单命令（可复现）

```powershell
$env:TIMECHO_PLM_TOKEN="<PLM PAT>"
plm-cli rn create --product-id 1 `
  --title '【V2.0.13.1】【安全模块-身份鉴别】普通模式下无 SECURITY 权限用户执行 ALTER USER ... ACCOUNT UNLOCK 触发 NPE，返回 305 INTERNAL_SERVER_ERROR（应 803；与 TDB-899 属不同路径）' `
  --description-file D:\IDEA\deepseek\ip99_80\sec_skill\docs\DEFECT_unlock_305_npe_plm.html `
  --priority P2 --iteration-name V2.0.14.1 `
  --owner ou_f4d3bb2529a54d439ac2f7ea51e156ba `
  --verifier ou_31242c489e94d0c017aaf0e2393d9232 `
  --start-time 2026-11-17 --item-type 缺陷 `
  --set 'cf_1b404e0a05e0=安全-身份鉴别-密码防爆破' `
  --set 'cf_e12d66c788ae=通用' `
  --set 'cf_cb838695b154=测试需求' `
  --set 'cf_6e859ac69388=V2.0.13.1' `
  --non-interactive --yes --json
# -> id=2327, seq=1607, url=https://plm.infra.timecho.com/iterations?productId=1&itemId=2327
```

## 2. 回查（`rn get --number TDB-1607`）

```text
编号=TDB-1607  类型=缺陷  优先级=P2  状态=排期确认
迭代=V2.0.14.1  问题发现版本=V2.0.13.1
负责人=高宏志  所属组长=江天  验证人员=刘珍
模型=通用  功能模块=安全-身份鉴别-密码防爆破  需求来源=测试需求
描述长度=9479
```

## 3. 描述结构（12 节）

1. 缺陷摘要（含与 TDB-899 的区分说明）
2. 环境（干净集群、普通模式）
3. 复现步骤（3 种写法）
4. 实际 vs 期望（305 vs 803）
5. 对照实验（root 成功 / CREATE USER 803 / GRANT 803 / UNLOCK 305）+ 三权分立下不复现矩阵
6. **完整异常堆栈**（`TreeAccessCheckVisitor.visitAuthor:808` → `Arrays.stream(null)`）
7. 根因（两模式不同 visitor 的源码依据 + 标准 visitor 缺陷）
8. 影响（错误码语义、日志污染、审计分类；不涉提权）
9. 修复建议（标准 visitor 加独立分支、防御式 null、单测、勿动严格 visitor）
10. 验证方法（含三权分立回归，避免回退 TDB-899）
11. 证据归档（artifact 目录 + 日志 tgz + 复现/对照脚本）
12. 关联与备注（TDB-899 已修复建议关闭；root 锁定返回 822 的附带观察）

## 4. 与 TDB-899 的关系（已在描述中写明）

| 项 | TDB-899 | 本单 TDB-1607 |
| --- | --- | --- |
| 模式 | 三权分立 | **普通模式** |
| 执行者 | `security_admin`（有 SECURITY） | **无 SECURITY 权限的普通用户** |
| 现象 | 701 Unsupported author type（执行路径） | **305 INTERNAL_SERVER_ERROR + NPE**（鉴权路径） |
| 现状 | **RC2 实测已修复**（真锁定→解锁→登录成功，DN 日志 0 条 701） | 待修复 |
| 修复点 | 严格 visitor / 执行路径 | **标准 `TreeAccessCheckVisitor`** |
