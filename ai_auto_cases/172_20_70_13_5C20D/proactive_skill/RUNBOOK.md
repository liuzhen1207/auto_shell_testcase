# 执行手册（5C20D）

## 推荐顺序（约 6-8 小时，含等待）
1. **基线**：`LEAK-THR-01`、`LEAK-MEM-01` 首轮 —— 先确认采样通道可用（jcmd 能连上进程）。
2. **副本分布**：`MULTI-01`、`MULTI-02` —— 最快暴露 SR5/DR3 配置错误，10 分钟内出结论。
3. **循环泄漏**：`LEAK-THR-02`、`LEAK-THR-03`、`LEAK-MEM-02`、`LEAK-MEM-03`。
4. **故障**：`MULTI-03`（停 1 台 DN）。
5. **回收与收敛**：`MULTI-05`、`MULTI-06`。
6. **长跑（可选）**：`LEAK-MEM-04`，需 benchmark。

## 判定口径
- 线程：看**斜率**不看绝对值（JIT/连接池预热会让首轮偏高）；`LEAK_THREAD_SLOPE_MAX` 默认 0.5。
- 堆：**强制 GC 后**采样（`jcmd GC.run` + `GC.heap_info`）；看锯齿，不看单点。
- 均衡：`max/min ≤ BALANCE_RATIO_MAX`（默认 2）。
- 上限：实测 **≥** 公式才算通过（PROACTIVE 只会放大不会缩小上限）。

## 常见假阳性
| 现象 | 原因 | 处理 |
|---|---|---|
| 首轮线程/堆偏高 | JIT、连接池、页缓存预热 | 用第 2 个采样点做基线 |
| 堆没回落 | 未强制 GC | 用例已内置 `GC.run`，手工验证时也要先 GC |
| 组数分布不均 | 扩容未收敛 | 等 `CLUSTER_CONVERGENCE_WINDOW_SEC`（默认 60s）再看 |
| MULTI-03 查询失败 | 停的是承载该设备 region 的 DN | 属预期（DR3 时若 3 副本全停才不可用），检查 `show regions` |

## benchmark（可选）
`conf/bench_template.properties` 为模板；benchmark 目录不存在时 `LEAK-MEM-04` 自动 SKIP。

## 结果回传
`results/<run-id>/` 整目录打包回传；`report` 子命令生成汇总。
