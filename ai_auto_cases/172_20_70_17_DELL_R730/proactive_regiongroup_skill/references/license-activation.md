# License / 激活流程（本环境实测，2026-10-15）

## 一句话
激活**只需在一台 ConfigNode 上提交一次激活码**即可全集群生效；但每个节点需要把
license 文件放到 `<DB_DIR>/activation/license`（缺了就会出现
`activating license … 801: Authentication failed`，集群虽 Running 却报 UNACTIVATED/`ACTIVATED(W)`）。

## 现网可用源（各节点**本地**路径，不要跨机混用）
| 节点 | 本机可用 license 源 | 说明 |
|---|---|---|
| 11.101.10.9 / .8 / .7 | `/data/mpp_test/license_2026/license`（471B）+ `/data/mpp_test/license_2026/.env` | **本项目采用这一份**；这也是 CN 所在的三台 |
| 11.101.10.10 | `/data/mpp_test/license_2026/license`（237B）、`/data/mpp_test/license`（237B） | **不要使用**（用户明示） |
| 11.101.10.6 | `/data/mpp_test/timecho_license_new.1`（237B）、`/data/mpp_test/timecho_license.1`（513B） | **不要使用**（用户明示） |

> `.env` 是**节点特定**的（含 `node_uuid`），只从本机同名目录取；不要跨机复制 `.env`。

## 手工补齐（等价于参考脚本 `start_cluster_v20.sh:29-34`）
```bash
DB=/data/mpp_test/<DB_DIR 末级名>
mkdir -p $DB/activation
cp -fp /data/mpp_test/license_2026/license $DB/activation/license
[ -f $DB/.env ] || cp -fp /data/mpp_test/license_2026/.env $DB/.env
```
上游参考实现（`liuzhen@11.101.10.11:/home/liuzhen/cluster_shell_3c5d/tc2026_releasenote_testcase/prepare_env/start_cluster_v20.sh`）：
```bash
license_dir=${db_parent_dir}/license_2026/
if ssh ${os_user_name}@${line} test -f ${db_dir}/activation/license; then echo "license is exist."
else ssh ${os_user_name}@${line} "sudo cp -rp ${license_dir}/license ${db_dir}/activation/license"
     ssh ${os_user_name}@${line} "sudo cp -rp ${license_dir}/.env ${db_dir}/"; fi
```

## kit 侧（已修）
* `conf/*.conf` 增补 `LICENSE_SRC=/data/mpp_test/license_2026/license`；`Cluster.ensure_license()`
  会在启动前把它拷到 `<DB_DIR>/activation/license`（源不存在则跳过该节点，不会误用别的 license）。
* **升级档位尤其注意**：`pg_upg13/pg_upg20` 的 `DB_DIR=/data/mpp_test/pg_upg_13` 是**另一个目录**，
  旧目录里的激活态不会带过来 —— 这就是 08:46–11:00 升级轮反复 `801: Authentication failed` 的根因。
* 现象对照：`license already active on <host>` = 已就绪；`license activation not confirmed` +
  等待节点 Running 超时 = 该节点缺 license。

## 1.3.7.1 升级族激活（用户指定，2026-10-16）

**权威源**（每台 ConfigNode 各自一份，**必须成对使用该目录自己的 `.env`**）：

| 节点 | license | .env | node_uuid |
|---|---|---|---|
| 11.101.10.9 | `/data/mpp_test/v1373rc1_0422_dd35474d/activation/license`（471 B） | `/data/mpp_test/v1373rc1_0422_dd35474d/.env`（77 B） | `8241478a-bbca-4161-a7ab-b4de18dc1b72` |
| 11.101.10.8 | 同上路径 | 同上 | `3cc32eac-7c2b-4b19-a836-dc7fba9c4d04` |
| 11.101.10.7 | 同上路径 | 同上 | `980553e9-db4c-4e12-ab15-ce99d7f1c7a6` |

* **注意**：该 license 的 **seed CN IP 为 `11.101.10.11`**（用户确认）——激活/组网时 CN 侧地址需与之匹配。
* `.6` / `.10` 无 `system_info`，**不复制 license**（作为 DataNode 无需激活）。
* **执行时机**：等**当前全量 217 例跑完**再复制并跑 1.3.7.1 升级验证（避免与全量轮抢集群）。
* 复制方式（每台，在 DB_DIR 就位后）：
  `cp <src>/activation/license <DB_DIR_1371>/activation/license` 且
  `cp <src>/.env <DB_DIR_1371>/.env`（保持 471 B / 77 B，勿混用其它目录的 `.env`）。
* **2.0 侧无此问题**：2.0.11 ≥ 2.0.10.1，内置 `03-AAATKKLP-XREBT2T7-2QRCC===` 试用码即可
  （已在 `/data/mpp_test/pg_2011snap_3bbeea656114` 实测：集群正常启动并跑完 217 例）。
  升级目标库（2.0.11）同样沿用 03 码即可；license 障碍只存在于 1.3.7.1 源库。
