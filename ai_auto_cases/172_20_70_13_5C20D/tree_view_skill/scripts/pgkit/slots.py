"""Device → series slot 计算与设备名生成（PROACTIVE 用例的精确性基础）。

产品实现（唯一依据）：
  iotdb-core/node-commons/.../partition/executor/hash/BKDRHashExecutor.java
      private static final int SEED = 131;
      hash = hash * SEED + (int) device.charAt(i);   // 全路径字符流
      hash &= Integer.MAX_VALUE;                     // 清符号位
      slot = hash % seriesPartitionSlotNum;
  常量：
      IoTDBConstant.PATH_SEPARATOR = '.'                       （IoTDBConstant.java:174）
      NULL_SEGMENT_HASH_NUM = (int) Character.MAX_VALUE + 1 = 65536
                                              （SeriesPartitionExecutor.java:40）
  表模型走 IDeviceID 变体：逐 segment 按字符哈希；null 段贡献 NULL_SEGMENT_HASH_NUM；
  段间（除最后一段）额外混入 PATH_SEPARATOR。

自证：需求文档 docs/360 §3.5 给出 `root.proactive.d0/d1/d2` → slot 327/328/329，
本模块 `tree_slot()` 完全复现（见 `selftest()`），另有集群侧交叉验证用例 PG-OBS-01。

约定：`db` 参数是不含尾点的库路径（如 `root.proactive`），设备名由 `device` 给出（如 `d0`），
拼成 `root.proactive.d0` 后哈希——与产品一致。
"""

from __future__ import annotations

import itertools
from typing import Iterable, Sequence

SEED = 131
NULL_SEGMENT_HASH_NUM = 65536
PATH_SEPARATOR = ord(".")


def _int32(value: int) -> int:
    """Java int 语义：32 位有符号截断。"""
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value >= 0x80000000 else value


def tree_slot(full_path: str, slot_num: int = 1000) -> int:
    """树模型设备路径 → slot（与 BKDRHashExecutor.getSeriesPartitionSlot(String) 等价）。"""
    h = 0
    for ch in full_path:
        h = _int32(h * SEED + ord(ch))
    return (h & 0x7FFFFFFF) % slot_num


def tree_device_slot(db: str, device: str, slot_num: int = 1000) -> int:
    """树模型：库路径 + 设备名 → slot。"""
    return tree_slot(f"{db.rstrip('.')}.{device}", slot_num)


def table_slot(table: str, tags: Sequence[str | None], slot_num: int = 1000) -> int:
    """表模型：表名 + TAG 序列 → slot（IDeviceID 变体；None 表示 TAG 缺失）。"""
    segments: list[str | None] = [table, *tags]
    h = 0
    for idx, seg in enumerate(segments):
        if seg is None:
            h = _int32(h * SEED + NULL_SEGMENT_HASH_NUM)
        else:
            for ch in str(seg):
                h = _int32(h * SEED + ord(ch))
        if idx < len(segments) - 1:
            h = _int32(h * SEED + PATH_SEPARATOR)
    return (h & 0x7FFFFFFF) % slot_num


def find_distinct_slot_devices(
    db: str, count: int, *, slot_num: int = 1000, prefix: str = "pgd", start: int = 0
) -> list[str]:
    """生成 `count` 个**互不相同 slot** 的设备名（树模型口径）。"""
    out: list[str] = []
    seen: set[int] = set()
    for i in itertools.count(start):
        name = f"{prefix}{i}"
        slot = tree_device_slot(db, name, slot_num)
        if slot in seen:
            continue
        seen.add(slot)
        out.append(name)
        if len(out) >= count:
            return out
    raise AssertionError("unreachable")


def find_colliding_devices(
    db: str, count: int, *, slot_num: int = 1000, prefix: str = "pgc", start: int = 0
) -> list[str]:
    """生成 `count` 个**落在同一个 slot** 的设备名（用于共槽用例）。"""
    by_slot: dict[int, list[str]] = {}
    for i in itertools.count(start):
        name = f"{prefix}{i}"
        slot = tree_device_slot(db, name, slot_num)
        bucket = by_slot.setdefault(slot, [])
        bucket.append(name)
        if len(bucket) >= count:
            return bucket
    raise AssertionError("unreachable")


def find_distinct_slot_tags(
    table: str, count: int, *, slot_num: int = 1000, prefix: str = "pgt", start: int = 0
) -> list[str]:
    """生成 `count` 个在**表模型**口径下互不相同 slot 的 TAG 值。"""
    out: list[str] = []
    seen: set[int] = set()
    for i in itertools.count(start):
        tag = f"{prefix}{i}"
        slot = table_slot(table, [tag], slot_num)
        if slot in seen:
            continue
        seen.add(slot)
        out.append(tag)
        if len(out) >= count:
            return out
    raise AssertionError("unreachable")


def distinct_tag_slot_count(table: str, tags: Iterable[str], *, slot_num: int = 1000) -> int:
    return len({table_slot(table, [t], slot_num) for t in tags})


def slot_map(db: str, devices: Iterable[str], *, slot_num: int = 1000) -> dict[str, int]:
    """设备名 → slot。"""
    return {d: tree_device_slot(db, d, slot_num) for d in devices}


def distinct_slot_count(db: str, devices: Iterable[str], *, slot_num: int = 1000) -> int:
    """不同 slot 数（= 产品扩容用的 K 的预期值，见 references/proactive-spec.md §3）。"""
    return len({tree_device_slot(db, d, slot_num) for d in devices})


def slots_for_paths(paths: Iterable[str], *, slot_num: int = 1000) -> dict[str, int]:
    """完整路径（如 root.db.d0）→ slot。"""
    return {p: tree_slot(p, slot_num) for p in paths}


def selftest() -> None:
    """对需求文档 docs/360 §3.5 的例子做回归：d0/d1/d2 → 327/328/329。"""
    got = [tree_device_slot("root.proactive", f"d{i}") for i in range(3)]
    assert got == [327, 328, 329], f"BKDR131 复刻与需求文档不一致：{got} != [327, 328, 329]"
    names = find_distinct_slot_devices("root.db", 50)
    assert distinct_slot_count("root.db", names) == 50
    collide = find_colliding_devices("root.db", 3)
    assert len({tree_device_slot("root.db", d) for d in collide}) == 1


if __name__ == "__main__":  # pragma: no cover - 手工自检入口
    selftest()
    print("slots.selftest OK")
