# sec_skill 用例导入 TimechoPLM 记录（16/16 已导入并执行通过）

> 工具：Timecho **SkillHub** 技能 `timecho-plm-shell-testcase-import@1.3.1`
> 产品：TimechoDB（productId=1）｜目标版本：**2.0.13.1**（PVE 实例 `/opt/timecho/2.0.13.1`）
> 拓扑：**3C3D**（PVE 模板 `3C3D标准模板` 9ea017b6…，rev=1，SHELL，已验证）
> 负责人：刘珍｜类型：安全性测试（按脚本推断）｜执行方式：自动 / shell

## 一、结果总表（16/16，全部 run passed）

| 用例 | PLM 用例号 | 执行器 | 状态 |
| --- | --- | --- | --- |
| SEC-01 密码长度边界校验（12~32） | **TimechoDB-11006**（id 16307） | cfe0c708 | imported |
| SEC-02 密码复杂度校验（四要素） | **TimechoDB-11008**（id 16309） | 9c249e03 | imported |
| SEC-03 密码不得等于用户名 | **TimechoDB-11009**（id 16310） | c1a32d41 | imported |
| SEC-04 强密码开关语义 | **TimechoDB-11011**（id 16312） | f061ea90 | imported |
| SEC-05 历史密码重用限制 | **TimechoDB-11012**（id 16313） | 025d13c3 | imported |
| SEC-06 密码有效期与过期登录拦截 | **TimechoDB-11013**（id 16314） | 8fa79812 | imported |
| SEC-07 安全配置项权限与三权分立边界 | **TimechoDB-11014**（id 16315） | 1530e8ed | imported |
| SEC-08 安全操作审计与日志泄漏检查 | **TimechoDB-11015**（id 16316） | 781a50f4 | imported |
| SEC-09 三副本安全策略一致性 | **TimechoDB-11016**（id 16317） | c3cc6ad8 | imported |
| SEC-10 密码到期提醒 | **TimechoDB-11017**（id 16318） | 64455653 | imported |
| SEC-11 CLI 隐式密码输入（-pw） | **TimechoDB-11018**（id 16319） | a7ca7312 | imported |
| SEC-12 用户与角色基础行为 | **TimechoDB-11019**（id 16320） | 58b135e0 | imported |
| SEC-13 登录失败锁定与解锁边界 | **TimechoDB-11020**（id 16321） | 738747b1 | imported |
| SEC-14 锁定豁免与自动解锁 | **TimechoDB-11021**（id 16322） | a6aca51b | imported |
| SEC-15 防爆破参数边界与双模式角色权限 | **TimechoDB-11022**（id 16323） | e0be96a0 | imported |
| SEC-16 身份鉴别与锁定审计日志 | **TimechoDB-11023**（id 16324） | bb8b861d | imported |

## 二、执行方式说明（重要）

- 执行由 **PLM Open API** 触发：`POST /api/open/test-executors/runs`（body: productId/testCaseId/deadlineMinutes），
  由 PLM 后端创建 **PVE 3C3D 实例**、下发装配后的 shell 脚本、收集退出码，写回运行结果（taskId/attemptId/reportJson）。
- **不是网页"用例执行"页面的手工点击**。PLM Open API 目前**没有**执行单/执行计划类接口
  （探测 `/api/open/test-executions`、`/test-plans`、`/test-tasks`、`/iterations` 均 404），
  所以若"用例执行页面"指的是迭代里的执行单，这些 API 运行不会出现在那份清单里；
  它们记录在**用例/执行器的运行记录**上（可按 taskId/attemptId 查详情与 reportJson）。
- 如需"必须在用例执行页面执行"，两条路：① 你在页面按下面的用例号逐个点执行；
  ② 提供页面上的具体入口/字段，我再定位其对应接口（当前 Open API 未暴露）。

## 三、SEC-01 运行报告（示例，证明非 mock）

```
resultState = passed     cleanupState = RECLAIMED    comparison = NOT_COMPARED
reportJson: dbVersion=2.0.13.1  dbHome=/opt/timecho/2.0.13.1
            vmid=205  ip=10.13.0.110  nodes=[10.13.0.110 10.13.0.140 10.13.0.198]
            exitCode=0  cancelled=false  timedOut=false  mock=false
session:    === SEC-01 密码长度上下限（12~32，无条件生效）开始 run_id=... mode=normal ===
            PASS 11 字符被拒（>=12）...
```

## 四、功能点映射

| 用例 | 功能点 |
| --- | --- |
| SEC-01~06、10、11、13~15 | 安全 / 身份鉴别 / 密码防爆破（1745） |
| SEC-07 | 安全 / 权限管理 / 三权分立账号体系（1749） |
| SEC-08、SEC-16 | 安全 / 安全审计 / 全链路操作审计日志（1734） |
| SEC-09 | 安全 / 身份鉴别 / 密码防爆破（1745） |
| SEC-12 | 安全 / 权限管理 / RBAC用户角色分级（1722） |

## 五、环境映射改进（`conf/env.conf`，本地行为不变）

装配脚本优先取 PLM 注入变量，缺省才回落本地：

| 变量 | 优先级 |
| --- | --- |
| `CN_NODES` / `DN_NODES` | `$CN_NODES` → **`PLM_CLUSTER_CN_NODES`/`PLM_CLUSTER_DN_NODES`** → 192.168.99.77-79 |
| `PRIMARY` | `$PRIMARY` → **`PLM_DB_IP`** → 192.168.99.77 |
| `DB_DIR` / `CLI` | → **`PLM_DB_HOME`** / **`PLM_CLI`** |
| `ROOT_PW` / `ADMIN_PW` | → **`PLM_DB_PASSWORD`** → TimechoDB@2021 |
| `V_TESTDB` | → **`PLM_DB_VERSION`** → `PLM_VERSION_DIR` basename |

## 六、已知问题

1. **SEC-04 重复建了两条**：TimechoDB-**11010**（孤儿，19:20 首批）与 **11011**（台账记录，19:21）；
   原因是首批 kill/重跑与第二批并发导致幂等未生效。需在 PLM 页面删除/关闭 11010（Open API 未提供删除用例接口）。
2. **用例类型为"安全性测试"**（按脚本内容推断），与你之前口头说的"功能测试"不一致；
   如需改为功能测试，只能删除后重建（Open API 无 update）。
3. 本机 `bash` 为 WSL，skill 原脚本 `subprocess.run(..., text=True)` 在读取 `bash -n` 输出时会因编码崩溃，
   已本地打补丁加 `encoding="utf-8", errors="replace"`（备份 `.bak_encoding`）。
