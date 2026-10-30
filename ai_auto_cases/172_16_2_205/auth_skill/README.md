# auth_skill 使用说明

## 安装到测试机

```bash
scp -r auth_skill root@172.16.2.205:/data2/auto_test/
ssh root@172.16.2.205 'cd /data2/auto_test/auth_skill && bash tools/run_regression.sh'
```

依赖：`bash`、`ssh` 免密到 8 个节点、`start-cli.sh`（随版本安装包）。不需要 jq。

## 配置

`conf/env.conf`（可用同名环境变量覆盖）：

```bash
NEW=v20121rc12_1027_c05111d
CN_LIST="172.16.2.26 172.16.2.27 172.16.2.28"
DN_LIST="172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6"
HOST=172.16.2.2
PW=TimechoDB@2021
```

换版本只改 `NEW` 或 `CLI`。

## 产物

| 路径 | 内容 |
| --- | --- |
| `results/run_<时间戳>/results.tsv` | 逐用例结论、断言失败数、日志 ERROR 数、耗时 |
| `results/run_<时间戳>/<ID>.out` | 用例输出（含实际报错文本、日志证据片段） |

`results/` 不入库。

## 部署（可选）

`tools/deploy_build.sh` 与 `tools/hard_reset.sh` 用于在新环境部署本 skill 被测版本（保留原集群激活身份、按序启动）：

```bash
NEW=v20121rc12_1027_c05111d PKG_ZIP=/data2/iotdb/$NEW/timechodb-2.0.12.1-bin.zip bash tools/deploy_build.sh
bash tools/hard_reset.sh
```