"""兼容壳：PROACTIVE 操作层已实现在 :mod:`pgkit.pgapi`。

保留本模块名与 ``CmpApi`` 别名，是为了让 ``cli.py`` 等既有引用继续可用；
真正的实现与文档在 ``pgapi.PgApi``（含区域组观测、库级详情上限、设备→组映射、
时间分区计数、策略热加载、权限、benchmark）。
"""

from __future__ import annotations

from .pgapi import Outcome, PgApi

#: 旧名（移植期的占位类名），新代码请直接用 :class:`pgapi.PgApi`
CmpApi = PgApi

__all__ = ["Outcome", "PgApi", "CmpApi"]
