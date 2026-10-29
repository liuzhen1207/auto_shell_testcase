# 现场实验脚本（证据 / 复现用）

这里的脚本**不是** skill 的正式工具，而是 P4 三项方向探测过程中用到的现场脚本，
`docs/P4_RESULTS.md` 里的结论就是它们跑出来的。保留下来是为了"结论可复现"。

在 99.80 上运行（集群需要在跑）：

| 脚本 | 用途 | 对应结论 |
| --- | --- | --- |
| `_recon.sh` / `_recon2.sh` / `_recon3.sh` | 侦察服务端安装布局、jar、`udf_lib_dir`/`trigger_lib_dir`、API 类是否在主 jar 里 | UDF/Trigger jar 的编译与分发方式 |
| `_javap.sh` | 用 `javap` 确认 `Tablet` 的公开 API（`rowSize` 是私有字段） | 触发器代码只用公开 API |
| `_udfprobe.sh` | UDF 手工全链路（注册/SHOW/执行/属性/异常/失败路径） | `SHOW FUNCTIONS` 类型列 = `external UDTF`；错误码 1200/1207/1304/301 |
| `_trgprobe.sh` / `_trgvariant.sh` / `_trgisolate.sh` | 触发器路径模式与事件类型的隔离实验（`d1` / `d1.s1` / `d1.*` / `d1.**` / `db.**`，BEFORE/AFTER，stateless/stateful） | **设备级裸路径 `ON root.db.d1` 不触发=符合预期**（文档：触发器侦听的是**序列**）；行为说明与代码对应见 [`../NOTE_trigger_path_pattern.md`](../NOTE_trigger_path_pattern.md) |
| `_trgfull.sh` | 触发器全链路（注册 → 写入触发 → **重启** → 再写入 → DROP），带 marker 文件跨节点统计 | `onCreate` 多节点、`fire` 只在写入节点、**重启后仍生效**；stateless 不收到 `restore()` |
| `_privprobe.sh` | 权限矩阵侦察（权限值 × 路径粒度 × 用户/角色 + 以用户身份验证越权） | READ→READ_DATA+READ_SCHEMA；`ALL/SYSTEM/SECURITY/AUDIT` 只能授 `root.**`；写越权 803、读被静默过滤为空集（观察 4） |
| `_scaleprobe.sh` / `_hdrprobe.sh` / `_verifyhdr.sh` | 规模用例里"COUNT=2000 但 SHOW 数出 2001 行"的追查 | **CLI 结果超过一批（1000 行）会重复打印表头**；`table_rows` 修复 + selftest 回归用例 |
| `_dropmulti.sh` / `_dropmulti2.sh` | 多路径 `DROP DATABASE` 的存在性校验对照实验（V1-V6 + 10 种写法：`DROP`/`DELETE` × `DATABASE`/`STORAGE GROUP`、位置/空格/个数/非库路径/表方言） | **多路径静默跳过不存在的路径，单路径报 508**（观察 1，对照表见 `RESULTS.md` 2.1） |
| `_rerun_fixed.sh` | 定点复跑改动过的 MD-T01 / MD-T06 | 按用户确认把"视图出现在 SHOW TIMESERIES"改为硬断言后的复跑记录 |
| `_runnew.sh` / `_pack13.sh` | 定点跑新用例 / 打包结果日志 | P4 实跑记录 |

用法示例：

```bash
cd /data/iotdb/autotest/metadata_skill
scp docs/experiments/_trgisolate.sh root@192.168.99.80:/tmp/
ssh root@192.168.99.80 "bash /tmp/_trgisolate.sh"
```
