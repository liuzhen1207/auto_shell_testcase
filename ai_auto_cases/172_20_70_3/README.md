# 172.20.70.3 —— 内存缓冲区专项回归用例

本目录是从测试机 **172.20.70.3** 上导出的一套自测用例，在被测集群
**3C5D**（CN 172.20.70.5 / .4 / .26，DN 172.20.70.4 / .26 / .14 / .27 / .30；SR=3、DR=2）
上以 shell 驱动 TimechoDB 做逐版本回归。

## 一、内容

| 目录 | 用例数 | 覆盖 |
| --- | --- | --- |
| `memory_buffer_skill/` | 24（19 功能 MB-01~19 + 5 性能 P-01~05） | 写内存缓冲区与内存控制：内存块分配比例、按比例/定时刷盘、拒绝与恢复、并发刷盘、WAL 快照与重放、独立数据目录、Chunk 分裂、HA 停 DN、V2 共识、TVList 排序、刷盘线程数、时间分区、类型推断、非法比例；性能项含刷盘比例、Chunk 参数、独立数据目录、最新点查询、V2 共识对比 |

## 二、结构

```
memory_buffer_skill/
  cases/            # 用例脚本（common/ 19 条功能、perf/ 5 条性能）
  cases.tsv         # 用例矩阵：ID / 类别 / 脚本 / 粒度 / 期望
  cases/MANIFEST.md5# 用例与 lib 的校验清单（preflight 用）
  lib/              # 集群控制、断言、benchmark 封装
  conf/env.conf     # 唯一需要按环境修改的文件
  tools/            # 运行器、自检、诊断
  docs/             # 各版本报告、缺陷分析
  README.md
  SKILL.md          # 操作手册与踩坑清单
  INDEX.md          # 用例索引 + 研发文档→用例映射
```

## 三、运行

```bash
cd memory_buffer_skill
vi conf/env.conf          # 改版本目录、节点 IP、密码
bash tools/selftest.sh    # 自检（不碰集群）
bash tools/run_all.sh     # 跑全部
```

结果写 `results/`（已在仓库 .gitignore 中忽略），每条用例末尾输出
`RESULT PASS|FAIL ... consensus=<协议>`。

## 四、环境要求

- 执行机 172.20.70.3 可免密 ssh 到全部 CN/DN 节点
- 节点上已部署被测版本；执行机有同版本 CLI
- 性能用例依赖 iot-benchmark（路径见 `lib/perf.sh` 的 `PERF_BM_DIR`）
