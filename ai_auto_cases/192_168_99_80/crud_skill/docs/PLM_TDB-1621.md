# PLM 记录：TDB-1621（V1→V2 Mod 升级重复写 .mods2，代码优化）

| 项目 | 内容 |
| --- | --- |
| PLM 工作项 | **TDB-1621**（itemId **2376**） |
| 链接 | <https://plm.infra.timecho.com/iterations?productId=1&itemId=2376> |
| 类型 | **代码优化** |
| 标题 | 【V2.0.13.1】【存储-LSM 文件管理】重启恢复时 V1→V2 Mod 升级会重复写入已有的 .mods2（35B→70B，同一条删除记录两遍）——代码优化 |
| 迭代 / 问题发现版本 | **V2.0.15.1** / **V2.0.13.1** |
| 负责人 / 所属组长 / 验证人员 | **江天** / 江天（派生）/ **刘珍** |
| 功能模块 / 模型 | 存储-LSM 文件整理-在线文件合并 / 通用 |
| 状态 | 排期确认 |
| 优先级 | 未设置（按"代码优化"类型，用户未指定） |
| 创建时间 | 2026-11-18 17:03:21 |

## 1. 提单命令

```powershell
$env:TIMECHO_PLM_TOKEN = "<PLM PAT>"
plm-cli rn create --product-id 1 `
  --title '【V2.0.13.1】【存储-LSM 文件管理】重启恢复时 V1→V2 Mod 升级会重复写入已有的 .mods2（35B→70B，同一条删除记录两遍）——代码优化' `
  --description-file D:\IDEA\deepseek\ip99_80\crud_skill\docs\OPT_mods2_duplicate_plm.html `
  --item-type '代码优化' --iteration-name 'V2.0.15.1' `
  --owner ou_24b6b584cbe0a1f4ce8ecae7edc1dd08 `
  --verifier ou_31242c489e94d0c017aaf0e2393d9232 `
  --start-time 2026-11-18 `
  --set 'cf_1b404e0a05e0=存储-LSM 文件整理-在线文件合并' `
  --set 'cf_e12d66c788ae=通用' `
  --set 'cf_cb838695b154=测试需求' `
  --set 'cf_6e859ac69388=V2.0.13.1' `
  --non-interactive --yes --json
# -> id=2376, seq=1621
```

## 2. 回查

```text
编号=TDB-1621  itemId=2376
类型=代码优化  状态=排期确认  优先级=（空）
迭代=V2.0.15.1  问题发现版本=V2.0.13.1
负责人=江天  验证人员=刘珍
功能模块=存储-LSM 文件整理-在线文件合并  模型=通用
描述长度=3812
```

## 3. 描述结构（九节）

1. 问题概述（代码优化类：不影响数据正确性，属文件冗余/幂等）
2. 环境（2.0.13.1 / 3C3D / SR3 DR3）
3. 最小复现步骤（A 注入 V1 `.mods`、B 已有 `.mods2` → 重启）
4. 实际结果（B：35B → 70B，十六进制显示同一条 `root.moddup.d1.**` 两遍）
5. 补充观察（再重启不继续增长；UpgradeMod 线程池出现两次；PVE CR-09 同现象）
6. 疑似根因（未按"已有 .mods2 跳过"、写入疑为追加、线程池两处触发）
7. 优化建议（跳过已存在、truncate 重写、单次触发、补幂等单测）
8. 验证方式（复现脚本 .mods2 不变 + CR-09 转 passed）
9. 证据路径

## 4. 优化后回归口径

| 检查项 | 期望 |
| --- | --- |
| 最小复现脚本重启前后 B 的 `.mods2` | 大小与 md5 **完全一致** |
| `crud_skill` **CR-09**（TimechoDB-11092） | 由 failed 转为 **passed** |
| 数据面 | d1 删除语义仍生效（0 行）、三副本一致 |
