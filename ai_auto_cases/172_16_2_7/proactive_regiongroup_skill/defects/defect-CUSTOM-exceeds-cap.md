# 待确认单（已关闭）：CUSTOM 不受资源上限约束

> **状态：已确认非缺陷，设计如此（2026-11-09 产品确认）**
> 版本：2.0.13.1 RC1 `ab6d3de`
> 分析：[CUSTOM-rootcause-analysis.md](CUSTOM-rootcause-analysis.md)

## 结论

1. CUSTOM 的 `MAX_SCHEMA_REGION_GROUP_NUM` / `MAX_DATA_REGION_GROUP_NUM` **独立于 AUTO 资源公式**，ConfigNode 在 CUSTOM 下跳过 max 重算；
2. 两个策略都为 CUSTOM 时完全跳过；混合配置只重算 AUTO 的一侧；
3. CUSTOM 用 `ALTER DATABASE ... WITH MAX_*_REGION_GROUP_NUM=n` 调整上限：
   - 只能增大或保持，降低返回 525（即使空库、尚无组）；
   - 修改上限不立即建组，新分区请求时一次补齐到目标数量。

## 原“现象”与解释

- `MAX_SCHEMA_REGION_GROUP_NUM=3` 实际建 3 个组：CUSTOM 按用户配额，符合设计；
- `MAX_DATA_REGION_GROUP_NUM=1` 实际 1/2：建库被 525 拒绝（低于默认 2），后续写入自动建默认库，**不是缺陷**。

## 后续动作

- 测试用例按“CUSTOM 不受资源上限约束”修正预期；
- 建议文档补充 CUSTOM 的独立配额语义，避免与需求 3.2 表述冲突。
