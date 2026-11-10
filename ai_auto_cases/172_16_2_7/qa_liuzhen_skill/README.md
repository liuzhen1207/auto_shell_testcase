# QA 用例自动化（PingCode「刘珍」）

基于 PingCode 中由刘珍创建/提交的工作项整理，环境 172.16.2.7 + 3C5D。

## 内容

| 文件/目录 | 说明 |
| --- | --- |
| `catalog.md` / `catalog.json` | 131 条工作项（114 条缺陷）的用例目录 |
| `checks.tsv` / `checks.json` | 24 条日志门禁检查（23 条启用 + 1 条已知问题） |
| `cases/` | 场景用例（QA-LZ-001 不存在用户登录、QA-LZ-003 串行缩容/加回） |
| `results/` | RC1 执行记录（含 IoTConsensus V1/V2、缩容循环） |
| `run_qa_lz_001.sh` | QA-LZ-001 执行脚本 |
| `run_pattern_suite.sh` | 标准负载 + 日志门禁扫描 |
| `run_scale_cycle.sh` | 两轮串行缩容/清理/加回循环 |
| `run_suite.sh` | 汇总入口 |
| `CASE_LIBRARY.md` | 原始用例库说明 |

## 结果

- QA-LZ-001：PASS；
- QA-LZ-002：PASS（复用 RN-TDB-122）；
- 23 条日志门禁：PASS（CHK-902 为已知问题）；
- QA-LZ-003：IoTConsensus（V1）两轮 10 次缩容/加回全部 PASS；IoTConsensusV2 在 .12 迁移失败回滚（V2 迁移/缩容未适配）。

## 运行

```bash
cd /tmp/qa-liuzhen
bash run_suite.sh
```
