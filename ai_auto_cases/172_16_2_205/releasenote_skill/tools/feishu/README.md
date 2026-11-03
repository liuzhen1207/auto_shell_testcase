# 飞书缺陷单 → 回归用例 自动流水线

把飞书缺陷文件夹里的历史缺陷单，批量转成 `releasenote_skill` 的可执行用例。

## 三步

```bash
# 0) 前置：准备 fs_files.json（飞书文件夹文件清单，含 name/token/type）
#    以及可用的 app_id/app_secret（脚本从 ~/.claude/settings.json 指向的 MCP 源码中读取，
#    或自行设置 FEISHU_APP_ID / FEISHU_APP_SECRET 环境变量）

# 1) 全量拉取文档正文（718 篇约 3~5 分钟）
python 01_harvest.py          # 产物：feishu_docs/<编号>.md、feishu_index.json

# 2) 分类 + 抽取复现步骤里的 SQL（产物：candidates.json）
python 02_classify.py

# 3) 生成用例（产物：cases/TIMECHODB_<编号>_v2.0.13.1.sh）
python 03_generate.py
```

## 分类规则（02_classify.py）

- **排除**：pipe / 同步 / 接收端 / 发送端 / 双活 / 订阅 / UI(Workbench、气象局) /
  缩容扩容 / region 迁移 / 集群运维 / 压测 / load / SSL / 加密 / WAL / AINode /
  UDF / 审计 / 三权分立 / 安全包 / MQTT / Windows bat / 重启 / 升级 / 磁盘满 /
  OOM / 性能耗时 / 黑名单 / 模板 / 部署
- **保留**：标题干净且"复现步骤"段里能抽出 `create|insert|select|alter|drop|set|show|delete|grant|...` 语句

## 生成规则（03_generate.py）

- **多行 SQL 重建**：遇到括号或引号未闭合就继续拼接下一行，直到配平（解决历史缺陷单里
  `CREATE TABLE` 跨行被截断的问题）
- **方言判定**：出现 `root.db.xx` → tree；出现 `create table x(` → table
- **幂等断言**：执行结果含 `already exists` 视为通过（避免重跑同一批次时大量假失败）
- **失败判据**：出现 `Exception|ERROR|internal error|NullPointerException` 即 FAIL

## 质量边界（重要）

自动生成的用例是**冒烟级**校验：验证"按缺陷单步骤执行不再报错"，**不是**精确行为断言。
例如缺陷单要求"改编码后写回应成功"，自动版只校验"不抛异常"。

- 广度：一次可跑 100+ 条，能快速扫出 305/301/NPE 类回归；
- 精度：关键缺陷建议像 `TIMECHODB_0684/0683/0698` 那样**手工升级**为带断言的用例。

## 首轮实测（2026-11-03，2.0.13.1 / ab6d3de）

126 个用例：**PASS 51 / FAIL 74 / KNOWN 1**，失败分类：

| 类别 | 数量 | 原因 | 处置 |
| --- | ---: | --- | --- |
| PARSE | 31 | 多行 SQL 被截断（旧版生成器） | 已在 03_generate.py 修复（括号配平重建） |
| PERM | 26 | 库已存在（重跑不幂等） | 已改为幂等断言 |
| INTERNAL | 1 | `use <db>` 目标库不存在（用例步骤依赖前置环境） | 需人工补充前置步骤 |
| OTHER | 16 | 多为权限/环境依赖 | 逐条人工判断 |

修复后已重新生成 107 条，**待 172.16.2.205 恢复后重跑验证**。
