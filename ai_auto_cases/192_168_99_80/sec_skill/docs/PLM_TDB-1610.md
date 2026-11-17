# PLM 提单记录：TDB-1610（三权分立下 security_admin 无法修改防爆破锁定配置）

| 项目 | 内容 |
| --- | --- |
| PLM 工作项 | **TDB-1610**（itemId **2330**，seq 1610） |
| 链接 | <https://plm.infra.timecho.com/iterations?productId=1&itemId=2330> |
| 标题 | 【V2.0.13.1】【安全模块-身份鉴别】三权分立下 security_admin 无法修改防爆破锁定配置（failed_login_attempts 等返回 803 缺 SYSTEM），仅 sys_admin 可改（研发已提 MR 7532） |
| 类型 / 优先级 / 状态 | 缺陷 / **P2** / 排期确认 |
| 迭代 / 问题发现版本 | **V2.0.13.1** / **V2.0.13.1** |
| 负责人 / 所属组长 / 验证人员 | **高宏志** / 江天 / **刘珍** |
| 模型 / 功能模块 / 需求来源 | 通用 / 安全-身份鉴别-密码防爆破 / 测试需求 |
| 描述长度 | 8007 字符（HTML，11 节） |
| 研发修复 | **MR 7532** <https://gitlab.timecho.com/r-d/db/timechodb/-/merge_requests/7532> |
| 创建时间 | 2026-11-17 15:58:30 |

## 1. 提单命令

```powershell
$env:TIMECHO_PLM_TOKEN="<PLM PAT>"
plm-cli rn create --product-id 1 `
  --title '【V2.0.13.1】【安全模块-身份鉴别】三权分立下 security_admin 无法修改防爆破锁定配置（failed_login_attempts 等返回 803 缺 SYSTEM），仅 sys_admin 可改（研发已提 MR 7532）' `
  --description-file D:\IDEA\deepseek\ip99_80\sec_skill\docs\DEFECT_lock_config_privilege_plm.html `
  --priority P2 --iteration-name V2.0.13.1 `
  --owner ou_f4d3bb2529a54d439ac2f7ea51e156ba `
  --verifier ou_31242c489e94d0c017aaf0e2393d9232 `
  --start-time 2026-11-17 --item-type 缺陷 `
  --set 'cf_1b404e0a05e0=安全-身份鉴别-密码防爆破' `
  --set 'cf_e12d66c788ae=通用' `
  --set 'cf_cb838695b154=测试需求' `
  --set 'cf_6e859ac69388=V2.0.13.1' `
  --non-interactive --yes --json
# -> id=2330, seq=1610
```

## 2. 回查

```text
编号=TDB-1610  类型=缺陷  优先级=P2  状态=排期确认
迭代=V2.0.13.1  问题发现版本=V2.0.13.1
负责人=高宏志  所属组长=江天  验证人员=刘珍
模型=通用  功能模块=安全-身份鉴别-密码防爆破  需求来源=测试需求
描述长度=8007
```

## 3. 描述结构（11 节）

1. 摘要（含"普通模式无此问题" + 研发 MR 7532）
2. 环境（干净 3C3D、三权分立）
3. 复现步骤
4. 实际 vs 期望（security_admin 三键 803 缺 SYSTEM；sys_admin 成功；stale 键镜像 803 缺 SECURITY）
5. **普通模式对照（root 四键全部成功，无此问题）**
6. 根因（模板缺 `# Privilege: SECURITY`；`ConfigurationFileUtils:686` 缺省回退 SYSTEM；`SetConfigurationStatement:81-91`；`TreeAccessCheckVisitor:2163-2178`）
7. 影响
8. 修复方案（补模板注解；关联 MR 7532；建议单测 + 静态校验）
9. 验证方法（修复后 security_admin 可改、sys_admin 应 803，对称）
10. 证据归档路径
11. 备注（与 TDB-1606/1607 无关；show 原值差异不视为缺陷）

## 4. 修复后回归口径

| 检查项 | 期望 |
| --- | --- |
| `security_admin` SET `failed_login_attempts` / `_per_user` / `password_lock_time_minutes` | **成功**（返回 restart 提示） |
| `sys_admin` SET 上述键 | **803 缺 SECURITY**（与 `password_stale_warning_days` 对称） |
| 普通模式 root SET 上述键 | 仍成功（不退化） |
| `sec_skill` 的 `SEC-15` 第 5 步 | 由"按设计/待确认"转为"security_admin 可改"硬断言 |

## 5. 关联材料

| 文件 | 内容 |
| --- | --- |
| `docs/DEFECT_lock_config_privilege.md` | 完整缺陷报告（含清库实测矩阵） |
| `docs/DEFECT_lock_config_privilege_plm.html` | 本单描述 HTML 原文 |
| `docs/CONFIG_SEMANTICS.md` | 配置原值/生效语义对照表（本单相关判读原则） |
| `tools/repro_lockpriv.sh` / `confirm_normal_matrix.sh` | 复现与普通模式确认脚本 |
