# CR-01 重复行：本地 3C3D 复现结果（2026-11-18）

## 结论

**本地干净 3C3D（同一 build：`v20131rc2_1110_83183d0` / 2.0.13.1）跑 CR-01 → PASS，未复现"停副本后重复行"。**

```
[2026-11-18 09:29:33] RESULT PASS fail_flag=0 case=cr_timestamp_precision_IoTConsensus
                      consensus=IoTConsensus build=v20131rc2_1110_83183d0 elapsed=857s
v_warnMessage=文档-源码差异①：10^13（14 位）源码放行，而文档/模板注释（template:1560）口径为"位数超过 13 位即拒"
              ⇒ 取哪个口径需研发确认（本用例按源码断言放行）
```

## 复现方式（完全同一条用例、同一 build）

| 项 | 值 |
| --- | --- |
| 集群 | 192.168.99.77/78/79，3C3D，SR=3/DR=3，IoTConsensus |
| 版本 | `v20131rc2_1110_83183d0`（BuildInfo 83183d0） |
| 脚本 | `crud_skill/cases/common/cr_timestamp_precision.sh`（从 PVE 导入的同一份） |
| 运行 | 99.80：`cd /data/iotdb/autotest/crud_skill && bash cases/common/cr_timestamp_precision.sh` |
| 覆盖 | ms / us / ns 三相 + 10^13 边界 + 权限相 + 收尾三件套（sync lag → 逐副本停 DN 一致性 → CN/DN 日志） |
| 耗时 | 857s |

## 与 PVE 失败的差异

| 项 | PVE（失败） | 本地（通过） |
| --- | --- | --- |
| 结果 | FAIL fail_flag=2，`SHELL_EXIT_CODE_NONZERO` | PASS fail_flag=0 |
| 失败点 | 停 10.13.0.190 后经两个存活节点查询**多出一行** `.987852987Z|1` | 未出现，逐副本比对一致 |
| 环境 | PVE 实例（3C3D，10.13.0.x） | 物理 3C3D（192.168.99.x） |

⇒ **该失败大概率是 PVE 环境的时序性/副本可见性问题（或数据残留）**，不是稳定的产品缺陷；
建议在 PLM 槽位恢复后**重跑一次 CR-01 确认**；若 PVE 上稳定复现而本地不能，再对比两边的
`iot_consensus_v2_mode` / flush 行为 / 实例是否被复用（同一实例上多次跑过 CR 系列）。

## 仍然成立的一条差异（非本次失败点）

`10^13`（14 位）时间戳：**源码放行**（判据 `time > 10^13`），**文档/模板注释口径为"位数超过 13 位即拒"**。
这条在本地同样出现（用例按源码断言 PASS，并在 `v_warnMessage` 里记录），属**文档/源码口径不一致**，需研发确认取哪个。
