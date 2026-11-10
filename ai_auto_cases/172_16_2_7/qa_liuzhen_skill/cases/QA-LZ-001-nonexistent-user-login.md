# QA-LZ-001 不存在用户 CLI 登录，DN 不得出现 measurements null NPE

- 来源：PingCode V2-754（刘珍创建）
- 标题：【2.0.9.1】TOE 访问历史【数据库 CLI 登录】使用不存在的用户登录时 DN 抛出空指针异常：
  `Cannot read the array length because "this.measurements" is null`
- 修复版本：2.0.9.1（已发版）
- 回归版本：2.0.13.1 RC1（本次基线）
- 判定：登录失败是预期；DN 日志在登录后 5 分钟内**不得**出现 `this.measurements` 相关 NPE。

## 前置

3C5D 集群已部署被测版本并启动；控制机可 ssh 各节点。

## 步骤

1. 记录开始时间；
2. 用不存在的用户执行一次 CLI 登录/查询：

   ```bash
   start-cli.sh -h 172.16.2.11 -u no_such_user_liuzhen -pw 'x' -e 'show databases;'
   ```

   预期客户端返回鉴权失败（如 700/801），不挂起；
3. 等待 3 秒，扫描 5 台 DN 的 `log_datanode_all.log`，统计开始时间之后包含
   `this.measurements` 或 `NullPointerException` 的行数；
4. 全部为 0 → PASS；任一命中 → FAIL，保留对应日志行。

## 一键执行

```bash
cd skills/timechodb-rn-verify/cases/qa-liuzhen
bash run_qa_lz_001.sh
```

脚本假定控制机为 172.16.2.7、被测目录 `/data1/iotdb/v20131rc1_1030_ab6d3de`；
不同环境改脚本头部的 `TESTDB/DN_LIST/CLI` 变量。

## 历史结果

| 日期 | 版本 | 结果 |
| --- | --- | --- |
| 2026-11-04 | 2.0.13.1 RC1 `ab6d3de` | 见 `results/` |
