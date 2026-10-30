"""PG-REB / PG-HA 用例族：重平衡分摊口径与「Region 创建过程中」的高可用。

期望值的唯一依据（本模块不写死任何设备数、节点编号或物理落点）
==============================================================
* **组数公式** `ClusterSchemaManager.java:594-649`
  ``R = max(min, ceil(weight × resource / (参与分摊库数 × 副本数)))``，
  由 ``cases.group_ceiling()`` 计算；组数 = ``min(K, R)``，K = 本次写入引入的
  **不同 slot 数**（由 ``pgkit.slots`` 的哈希公式在客户端算出，不靠观测反推）。
* **重平衡阈值** `DataPartitionPolicyTable.java:163-173`（PROACTIVE 分支）
  ``mu = max(1, floor(本库非空 slot 数 / 该库 Data 组数))``
  ⇒ 均衡后**每个 Data 组的 SeriesSlotNum ≤ mu**，且组间差 ≤ 1（slot 先在组间
  均分、余数分给前若干组），所有组 slot 之和 == 非空 slot 总数。
  本模块的 ``_mu()`` 用**实测** slot 与**实测**组数按上式现算，绝不写死阈值。
* **高可用口径**：副本数断言为 ``在线副本数 == min(DataRF, 存活 DN 数)``
  （源码：``RegionGroupCache`` 在弱一致下 ≥1 副本存活即可用；**不允许**断言恒等于 RF）。

纪律
====
* 每条用例开头 ``db = reset_db(ctx, model)``；
* 停/启节点前 ``ctx.mark_harness_action``，被停的 DataNode 立即加入
  ``ctx.by_design_gone``（否则收尾①会等一个永远不到的 sync lag），
  用例结束前**必须**恢复并确认 Running（``finally`` 保证，见 ``_dn_lane``）；
* 档位不匹配（DN 数/RF 不足以制造副本丢失、cluster.py 缺只读接口）一律
  ``ctx.skip()`` 并写明原因，**绝不降级成 PASS**。
"""

from __future__ import annotations

import json
import time
from contextlib import contextmanager

from . import slots as pslots
from .cases import (
    CaseSpec,
    Ctx,
    device_set,
    ensure_write_table,
    ensure_write_tree,
    expected_cap,
    expect_groups,
    reset_db,
    group_ceiling,
)

SPECS: list[CaseSpec] = []

_CN, _DN = "cn", "dn"
_RUNNING = "running"
_RESTORE_TIMEOUT = 300
_POLL = 5
#: 表中当前在线的 DataNodeId（用于把 DataNodeId 映射回 host）
_DN_IDS: dict[str, str] = {}

TW = "tree+table"


# ============================================================ 基础工具
def dial(model: str) -> str:
    """模型名 → 方言名（与 cases.dialect_of 同义，本模块内保持短名）。"""
    return "table" if model == "table" else "tree"


def table_of(ctx: Ctx) -> str:
    """表模型测试表名（与 cases.py 的既有夹具同表，便于复用建表幂等逻辑）。"""
    return ctx.cfg.raw("PG_TABLE") or "tb"


def expected_slots(ctx: Ctx, db: str, dialect: str, count: int, *,
                   prefix: str = "pgo", table: str = "") -> list[str]:
    """生成 count 个**互不相同 slot** 的设备名/TAG（客户端哈希，与产品同公式）。"""
    return device_set(ctx, db, count, dialect=dialect, prefix=prefix,
                      table=table or table_of(ctx))


def slot_map_of(ctx: Ctx, db: str, dialect: str, items: list[str], *,
                table: str = "") -> dict[str, int]:
    """设备/TAG → slot 号的客户端计算（期望值的来源，不依赖服务端观测）。"""
    n = int(ctx.cfg.raw("PG_SERIES_SLOT_NUM") or 1000)
    if dialect == "table":
        return pslots.slot_map(table or table_of(ctx), items, slot_num=n)
    return pslots.slot_map(db, items, slot_num=n)


def slot_total(mapping: dict[str, int]) -> int:
    return len(set(mapping.values()))


def write_items(ctx: Ctx, db: str, dialect: str, items: list[str], *, stamp: int = 1,
                table: str = "") -> None:
    """按方言逐个写入设备/TAG（每个 item 一个不同 slot ⇒ 每个新 slot 触发一次扩容）。"""
    if dialect == "table":
        for i, tag in enumerate(items):
            ensure_write_table(ctx, db, table or table_of(ctx), tag, stamp=stamp + i)
        return
    for i, device in enumerate(items):
        ensure_write_tree(ctx, db, device, stamp=stamp + i)


def _mu(slots: list[int], groups: int) -> int:
    """`DataPartitionPolicyTable.java:163-173`：``mu = max(1, floor(非空 slot 数 / 组数))``。"""
    return max(1, len(slots) // max(1, groups))


def _slot_stats(ctx: Ctx, db: str, dialect: str, kind: str = "DATA") -> dict:
    counts = ctx.api.slot_counts(db, kind=kind, dialect=dialect)
    slots = [v for v in counts.values() if v > 0]
    return {"counts": counts, "slots": slots, "groups": len(counts),
            "non_empty": len(slots), "total": sum(slots),
            "mu": _mu(slots, len(counts)),
            "max": max(slots) if slots else 0, "min": min(slots) if slots else 0}


def _dist(ctx: Ctx, db: str, dialect: str, kind: str = "DATA") -> str:
    return str(_slot_stats(ctx, db, dialect, kind)["counts"])


def _dn_id_columns(row: dict) -> tuple[str, str, str]:
    """从 ``SHOW DATANODES`` 一行里取 (NodeId, host, status)，列名差异都兼容。"""
    node_id = ""
    for column in ("NodeID", "NodeId", "node_id", "DataNodeId", "data_node_id", "Id", "id"):
        value = (row.get(column) or "").strip()
        if value:
            node_id = value
            break
    host = ""
    for column in ("RpcAddress", "rpc_address", "InternalAddress", "internal_address",
                   "Address", "address", "Host", "host"):
        value = (row.get(column) or "").strip()
        if value:
            host = value.split(":")[0]
            break
    status = ""
    for column in ("Status", "status"):
        value = (row.get(column) or "").strip()
        if value:
            status = value
            break
    return node_id, host, status


def _is_up(status: str) -> bool:
    """与 ``cluster.running_dn_hosts`` 同口径：Running/ReadOnly 都算"在线"。"""
    base = status.split("(")[0].strip().lower()
    return base in {"running", "readonly"}


def _dn_inventory(ctx: Ctx) -> dict[str, str]:
    """``NodeID -> IP``：以 ``pgapi.PgApi.node_inventory``（``show datanodes``）为唯一来源。

    A 类（HA-02/HA-04）纪律：
    * 映射**不按在线状态过滤** —— 停机目标机必须在映射里，否则停机窗口内的副本裸 id
      会变成"越界副本"（旧实现的 `越界副本=['4']` 就是这么来的）；
    * 顺带刷新 ``_DN_IDS``（双向，供 detail 打印），但**判定**只用本函数的返回值。
    """
    try:
        mapping = ctx.api.node_inventory()
    except Exception:  # noqa: BLE001 - 探针失败时退化为「没有映射」，由调用方给出 unmapped
        mapping = {}
    for node_id, host in mapping.items():
        if node_id and host:
            _DN_IDS.setdefault(node_id, host)
            _DN_IDS.setdefault(host, node_id)
    return dict(mapping)


def _stopped_ips(ctx: Ctx) -> set[str]:
    """**本用例由 harness 实际停掉**的 DataNode IP 集合。

    只认用例自己的动作登记（``Ctx.harness_stopped``，由 ``_stop_dn`` 写入、
    ``_start_dn`` 成功恢复后移除），**不**从全局在线状态反推 —— 否则别的用例刚停过/
    正在收敛的节点会被算成「本用例停的」，而本用例停掉的节点又可能已经回到在线表里。
    """
    return {host for host in ctx.harness_stopped if host}


def _live_ips(ctx: Ctx) -> set[str]:
    """本用例口径下的"在线"IP 集合 = **集群 DN 清单 − 本用例停掉的节点**。"""
    return set(_dn_inventory(ctx).values()) - _stopped_ips(ctx)


def _running_ips(ctx: Ctx) -> set[str]:
    """集群**当前自报** Running/ReadOnly 的 DataNode IP（仅用于"恢复后"的断言）。"""
    ips: set[str] = set()
    try:
        rows = ctx.cluster.datanodes()
    except Exception:  # noqa: BLE001 - 探针失败退化为空集合，由调用方 SKIP
        return ips
    for row in rows:
        _node_id, host, status = _dn_id_columns(row)
        if host and _is_up(status):
            ips.add(host)
    return ips


def _names_for_ids(ctx: Ctx, ids: set[str]) -> list[str]:
    """把 DataNodeId 映射回 host（映射来自 ``cluster.datanodes()``，无法映射时返回原值）。"""
    return sorted(_DN_IDS.get(i, i) for i in ids)


def _refresh_dn_ids(ctx: Ctx) -> None:
    """预刷新 NodeId→host 映射（跑在某台被停之前，保证映射里含这台机器的 NodeId）。"""
    _dn_inventory(ctx)


# ============================================================ 节点生命周期（HA）
def _stop_dn(ctx: Ctx, host: str, label: str) -> None:
    ctx.mark_harness_action(f"{label}：停 DataNode {host}", pad=20)
    ok = ctx.cluster.stop_node(host, _DN)
    ctx.by_design_gone.add(host)          # 必须在 stop 后立刻登记，否则收尾①等不到 lag
    if ok:
        # A 类（HA-02/HA-04）：被停集合只认 harness 自己的动作登记
        ctx.harness_stopped.add(host)
    ctx.check(f"{label}：DataNode {host} 已停止", ok, f"host={host}")


def _start_dn(ctx: Ctx, host: str, label: str) -> bool:
    """把借出的 DataNode 拉回来并确认 Running；**任何**控制流下都要能调（内部不抛）。"""
    if not ctx.cluster.node_running(host, _DN):
        ctx.mark_harness_action(f"{label}：启 DataNode {host}", pad=20)
        ctx.cluster.start_node(host, _DN)
    ok = ctx.cluster.wait_healthy(timeout=ctx.cfg.get_int("CLUSTER_START_TIMEOUT_SEC"))
    deadline = time.time() + _RESTORE_TIMEOUT
    while not ok and time.time() < deadline:
        time.sleep(_POLL)
        ok = ctx.cluster.wait_healthy(timeout=60)
    status = ctx.cluster.dn_status_for(host) or ""
    restored = ok and status.strip().lower().startswith(_RUNNING)
    if restored:
        # 恢复成功 ⇒ 不再算"本用例停掉的节点"，后续（恢复后）断言按全清单比对
        ctx.harness_stopped.discard(host)
    ctx.check(f"{label}：DataNode {host} 已恢复 Running", restored,
              f"healthy={ok}、status={status!r}")
    return ok


@contextmanager
def _dn_lane(ctx: Ctx, label: str):
    """借一个 DataNode：停掉、跑用例体、**任何路径**都在 finally 里恢复并确认 Running。

    用例体自身抛异常时，用 ``except`` 抓住、**先恢复节点**再原样重抛 —— 这样既不会丢用例
    失败原因，也不会让"恢复节点"的异常把它顶掉（节点恢复是硬要求，必须在任何路径上完成）。
    """
    host, stopped = _lane_host(ctx), False
    body_error: BaseException | None = None
    try:
        _refresh_dn_ids(ctx)          # 停机前先把 NodeId→host 映射取全（停机后本机就不在表里了）
        _stop_dn(ctx, host, label)
        stopped = True
        yield host
    except BaseException as exc:      # noqa: BLE001 - 先恢复节点，再把原因抛回去
        body_error = exc
        raise
    finally:
        if not stopped:
            ctx.by_design_gone.add(host)
        try:
            _start_dn(ctx, host, label)
        except Exception as exc:  # noqa: BLE001 - 恢复失败必须显式 FAIL，绝不静默
            if body_error is None:
                raise
            ctx.note(f"    [harness] {label}：恢复 {host} 时异常（用例本身已失败）：{exc}")


def _lane_host(ctx: Ctx) -> str:
    """挑一个「本轮没有被故意停过」的 DataNode（避免跨用例复用同一台）。"""
    hosts = [h for h in ctx.cfg.dn_hosts if h not in ctx.by_design_gone]
    if not hosts:
        hosts = list(ctx.cfg.dn_hosts)
    return hosts[0]


def _live_dn_count(ctx: Ctx) -> int:
    """存活 DataNode 数（集群自报的 Running/ReadOnly 明细，而非单机进程探针）。"""
    try:
        return len(ctx.cluster.running_dn_hosts())
    except Exception:  # noqa: BLE001 - 探测失败退化为逐机进程探针
        return len([h for h in ctx.cfg.dn_hosts if ctx.cluster.node_running(h, _DN)])


def need_dns(ctx: Ctx, minimum: int, why: str) -> bool:
    """档位门禁：DN 数不足则 SKIP（写明原因），绝不降级断言。"""
    have = len(ctx.cfg.dn_hosts)
    if have < minimum:
        ctx.skip(f"需要 ≥{minimum} 个 DataNode 才能{why}，本集群 DN 数={have}")
        return False
    return True


def need_two_dns(ctx: Ctx, why: str) -> bool:
    """副本口径用例的最低档位：≥2 个 DN（停 1 台后仍有节点可承载写入与共识）。

    不断言 ``DataRF > DN 数``：``assert_online_replicas`` 对两种档位都给出**可证伪**的断言
    （期望值 = ``min(RF, 存活 DN 数) − 该组落在被停节点上的副本数``，对存活 ≥ RF 与
    存活 < RF 两种档位都成立），因此不需要为此 SKIP。
    """
    return need_dns(ctx, 2, why)


# ============================================================ 断言
#: 最小组数对应的配置文件键（与 ``cases_cfg._MIN_OF`` 同源）
_MIN_PROP = {"DATA": "default_data_region_group_num_per_database",
             "SCHEMA": "default_schema_region_group_num_per_database"}
_MIN_CONF = {"DATA": "PG_MIN_DATA_PER_DB", "SCHEMA": "PG_MIN_SCHEMA_PER_DB"}


def _live_min(ctx: Ctx, kind: str) -> int:
    """该类最小组数的**生效值**（``SET CONFIGURATION`` 会落盘，读文件比 SQL 更硬）。"""
    key = _MIN_PROP[kind.upper()]
    try:
        raw = (ctx.props.read(ctx.cfg.cn_hosts[0], keys=(key,)).get(key, "") or "").strip()
    except Exception:  # noqa: BLE001 - 读不到 conf 就退回配置口径
        raw = ""
    try:
        return int(raw)
    except ValueError:
        return int(ctx.cfg.raw(_MIN_CONF[kind.upper()]) or 1)


def assert_groups(ctx: Ctx, label: str, db: str, dialect: str,
                  total_slots: int, *, kind: str = "DATA",
                  groups_before: int | None = None, p_count: int = 0) -> int:
    """组数 == 源码公式 ``min(R, max(min(minNum, G+|P|), K))``（组只增不减）。

    H-27：旧实现只算 ``min(K, R)``，漏了 ``minNum`` 项。当"同 slot 申请新时间分区"时
    ``K`` 不变而 ``G+|P|`` 增长（HA-05 实测 G=1、|P|=1、minNum=2、K=1 ⇒ 2 组），
    只按 ``min(K,R)`` 会期望 1 组 ⇒ 把产品正确行为判成失败。
    ``groups_before`` 给出"本次写入前的组数"即启用完整公式；不传则退化为 ``min(K,R)``。
    上限用 ``group_ceiling``（H-19：产品自报的单调存量可能高于公式值）。
    """
    cap = max(expected_cap(ctx, kind, dialect, db), group_ceiling(ctx, kind, dialect, db))
    if groups_before is None:
        want = min(total_slots, cap)
        formula = f"min(K={total_slots}, 上限={cap})"
    else:
        minimum = _live_min(ctx, kind)
        base = min(minimum, groups_before + p_count)
        want = max(groups_before, min(cap, max(base, total_slots)))
        formula = (f"T=min(R={cap}, max(min(minNum={minimum}, G+|P|={groups_before}+{p_count})"
                   f"={base}, K={total_slots}))")
    if kind == "DATA":
        expect_groups(ctx, label, db, dialect, data=want)
    else:
        expect_groups(ctx, label, db, dialect, schema=want)
    got = ctx.api.db_group_num(db, kind, dialect=dialect)
    ctx.check(f"{label}：{kind} 组数应为 {formula}={want}", got == want, f"实际={got}",
              evidence=f"上限复核={cap}")
    return got


def assert_balanced(ctx: Ctx, label: str, db: str, dialect: str, *,
                    groups: int | None = None, total_slots: int | None = None) -> dict:
    """按 ``DataPartitionPolicyTable`` 口径断言分摊均衡。

    * 每组 slot ≤ mu（mu 用**实测** slot/组数现算）；
    * 组间差 ≤ 1（slot 均分、余数分给前若干组）；
    * 有内容时非空组 == 观测组数（不存在被分到 0 个 slot 的组）；
    * 传 ``groups``/``total_slots`` 时同时断言组数与 slot 总数守恒。
    """
    stat = _slot_stats(ctx, db, dialect)
    evidence = f"分布={stat['counts']}、mu={stat['mu']}、非空={stat['non_empty']}、总={stat['total']}"
    if groups is not None:
        ctx.check(f"{label}：Data 组数应为 {groups}", stat["groups"] == groups,
                  f"实际={stat['groups']}", evidence=evidence)
    if total_slots is not None:
        ctx.check(f"{label}：SeriesSlot 总数应守恒为 {total_slots}",
                  stat["total"] == total_slots,
                  f"实际={stat['total']}", evidence=evidence)
    if not stat["slots"]:
        ctx.check(f"{label}：无内容时不应出现非空组", stat["groups"] == 0, evidence=evidence)
        return stat
    ctx.check(f"{label}：每组槽数 ≤ mu(=max(1, floor({stat['non_empty']}/{stat['groups']}))"
              f"={stat['mu']})", stat["max"] <= stat["mu"],
              f"最大={stat['max']}、mu={stat['mu']}", evidence=evidence)
    ctx.check(f"{label}：组间分布不畸变（max-min ≤ 1）", stat["max"] - stat["min"] <= 1,
              f"max={stat['max']}、min={stat['min']}", evidence=evidence)
    ctx.check(f"{label}：非空组数 == 观测组数（无空转组）",
              stat["non_empty"] == stat["groups"],
              f"非空={stat['non_empty']}、组数={stat['groups']}", evidence=evidence)
    return stat


# ================================================ 副本位置：一律归一化到 IP（A 类）
def replica_placement(ctx: Ctx, db: str, dialect: str, kind: str) -> dict[str, dict]:
    """组 → 副本位置明细，**副本标识统一归一化到 IP**。

    字段：``ips``（归一化后的副本 IP，来自行内 ``InternalAddress``/``RpcAddress`` 或
    ``DataNodeId -> IP`` 映射）、``raw``（``DataNodeId`` 裸 id，保留原值对账）、
    ``unmapped``（映射缺失的副本原值，**保留**并进 detail，不静默丢弃）、``status``。

    归一化在 ``pgapi.PgApi.groups()`` 里完成（``show datanodes`` 建立的 NodeID→IP 映射），
    因此裸 id（如 ``4``）与 ``ip:port``（如 ``11.101.10.9:10730``）在这里是同一个 DN。
    """
    out: dict[str, dict] = {}
    for group_id, group in ctx.api.groups(db, kind=kind, dialect=dialect).items():
        out[group_id] = {
            "ips": list(group.replica_addresses),
            "raw": list(group.replicas),
            "unmapped": list(group.unmapped_replicas),
            "status": group.status,
        }
    return out


def online_replica_expectation(rf: int, live_dns: int, lost: int) -> int:
    """该组的在线副本数期望值 = ``min(RF, 存活 DN 数) − 该组落在被停节点上的副本数``。

    依据（也是**不**断言"恒等于 RF"的原因）：

    * ``存活 DN 数 ≥ RF`` 时上限就是 RF；某组**恰好**把副本放在被停节点上，缺几个就少几个
      （产品不保证停机后立刻重复制，见 ``H-33``）；
    * ``存活 DN 数 < RF`` 时上限被存活数压住 —— 任一组都不可能满 RF；
    * ``lost`` **只能**来自本用例 harness 动作停掉的节点（``Ctx.harness_stopped``），
      并由 ``_stopped_ips`` 归一化到 IP。
    """
    return max(0, min(rf, live_dns) - max(0, lost))


def _replica_scan(ctx: Ctx, db: str, dialect: str, kind: str) -> tuple[dict, set, set, int]:
    """(组→位置明细, DN 清单 IP 集, 本用例被停 IP 集, 存活 DN 数) —— A 类的唯一口径。"""
    inventory = _dn_inventory(ctx)
    known = set(inventory.values())
    stopped = _stopped_ips(ctx)
    live = len(known - stopped)
    return replica_placement(ctx, db, dialect, kind), known, stopped, live


def assert_replica_addresses_known(ctx: Ctx, label: str, db: str, dialect: str,
                                   kind: str = "DATA") -> None:
    """全部副本**归一化到 IP 后**必须指向本集群已知 DataNode（不按在线状态过滤）。

    这才是 HA-04 停机窗口内**可证伪**的口径：停机时产品仍把被停节点列在副本集里是预期
    行为（副本集不因停机而重排），所以"所有副本都在线"在停机窗口内恒假；能证伪的是
    "副本里出现了本集群不认识的节点标识"与"标识无法归一化"。
    """
    placed, known, _stopped, _live = _replica_scan(ctx, db, dialect, kind)
    if not known:
        ctx.skip("读不到 DataNode 清单（show datanodes / show cluster 均不可用），"
                 "无法把副本标识归一化到 IP 后比较")
        return
    stray: dict[str, list] = {}
    unmapped: dict[str, list] = {}
    for group_id, info in placed.items():
        bad = sorted({ip for ip in info["ips"] if ip not in known})
        if bad:
            stray[group_id] = bad
        if info["unmapped"]:
            unmapped[group_id] = info["unmapped"]
    ctx.check(f"{label}：{kind} 全部副本归一化到 IP 后都指向本集群已知 DataNode",
              bool(placed) and not stray and not unmapped,
              (f"越界副本={stray or '无'}、无法归一化（保留原值）={unmapped or '无'}、"
               f"DN 清单={sorted(known)}、组数={len(placed)}"),
              evidence=json.dumps({"placement": placed, "inventory": sorted(known)},
                                  ensure_ascii=False)[:4000])


def assert_no_group_fully_offline(ctx: Ctx, label: str, db: str, dialect: str,
                                  kind: str = "DATA") -> None:
    """**归一化到 IP 后**每个组至少还有 1 个副本落在"未被本用例停掉"的节点上。

    与被停集合的比较只用 harness 自己的动作登记（``Ctx.harness_stopped``），
    不用全局在线集合反推；于是这条断言问的是"停掉的这几台机器有没有把某个组整个拿下线"。
    """
    placed, known, stopped, _live = _replica_scan(ctx, db, dialect, kind)
    if not known:
        ctx.skip("读不到 DataNode 清单，无法判定被停节点上的副本")
        return
    if not stopped:
        ctx.check(f"{label}：本用例没有实际停掉任何 DataNode（被停集合为空，"
                  f"该断言无口径可比）", False, f"harness_stopped=∅、DN 清单={sorted(known)}")
        return
    live = known - stopped
    dead = {group_id: sorted({ip for ip in info["ips"] if ip in stopped})
            for group_id, info in placed.items()
            if not ({ip for ip in info["ips"]} & live)}
    ctx.check(f"{label}：{kind} 每个组至少 1 个副本（归一化到 IP 后）"
              f"在未被本用例停掉的节点上", bool(placed) and not dead,
              f"整组离线={dead or '无'}、被停集合={sorted(stopped)}、存活集合={sorted(live)}")


def assert_online_replicas(ctx: Ctx, label: str, db: str, dialect: str,
                           host: str, kind: str = "DATA") -> None:
    """各组的在线副本数 == ``min(RF, 存活 DN 数) − 该组落在被停节点上的副本数``。

    口径（A 类）：
    * 在线/被停**都按归一化后的 IP** 比较；``stopped`` 只来自本用例 harness 动作
      （``_stop_dn`` 登记），存活 DN 数 =「集群 DN 清单 − stopped」（``{host}`` 仅用于标注）；
    * 收敛窗口内轮询，避免刚停机时 ``SHOW REGIONS`` 仍报旧副本集造成假 FAIL；
    * 有副本无法归一化时**不猜**：照实判 FAIL 并把原值写进 detail。
    """
    rf = ctx.cfg.get_int("SCHEMA_REPLICATION_FACTOR" if kind.upper().startswith("S")
                         else "DATA_REPLICATION_FACTOR")
    deadline = time.time() + 120
    placed: dict = {}
    known: set = set()
    stopped: set = set()
    live = 0
    rows: list = []
    while True:
        placed, known, stopped, live = _replica_scan(ctx, db, dialect, kind)
        rows = []
        for group_id, info in sorted(placed.items()):
            ips = info["ips"]
            lost = len([ip for ip in ips if ip in stopped])
            online = len([ip for ip in ips if ip in known and ip not in stopped])
            rows.append((group_id, len(ips), online, lost,
                         online_replica_expectation(rf, live, lost), info["unmapped"]))
        if rows and all(r[2] == r[4] and not r[5] for r in rows):
            break
        if not known or not stopped or time.time() >= deadline:
            break
        time.sleep(_POLL)
    want = online_replica_expectation(rf, live, 0)
    ok = bool(rows) and all(r[2] == r[4] and not r[5] for r in rows) and bool(stopped)
    detail = "；".join(
        f"组{gid}: 副本{tot}/在线{online}/被停{lost}（期望在线{expect}）"
        + (f"/无法归一化={unmapped}" if unmapped else "")
        for gid, tot, online, lost, expect, unmapped in rows)
    ctx.check(f"{label}：{kind} 各组在线副本数（归一化到 IP 后）== "
              f"min(DataRF={rf}, 存活DN={live}) − 该组落在被停节点上的副本数"
              f"（被停节点={sorted(stopped) or '∅'}，上限={want}）",
              ok,
              (detail or "未观测到任何组")
              + f"、存活 DN={live}/{len(known)}（= 集群 DN 清单 − 本用例停掉的节点）",
              evidence=json.dumps({"placement": placed, "inventory": sorted(known),
                                   "stopped": sorted(stopped)}, ensure_ascii=False)[:4000])


def assert_replica_ids_live(ctx: Ctx, label: str, db: str, dialect: str,
                            kind: str = "DATA") -> None:
    """**恢复后**：全部副本归一化到 IP 后都落在集群**当前 Running** 的 DataNode 上。"""
    live_ips = _running_ips(ctx)
    if not live_ips:
        ctx.skip("cluster.datanodes() 未返回 Running 节点，无法做「副本都在在线节点上」的断言")
        return
    placed = replica_placement(ctx, db, dialect, kind)
    stray: dict[str, list] = {}
    unmapped: dict[str, list] = {}
    for group_id, info in placed.items():
        bad = sorted({ip for ip in info["ips"] if ip not in live_ips})
        if bad:
            stray[group_id] = bad
        if info["unmapped"]:
            unmapped[group_id] = info["unmapped"]
    ctx.check(f"{label}：{kind} 全部副本归一化到 IP 后都落在当前 Running 的 DataNode 上",
              bool(placed) and not stray and not unmapped,
              (f"越界副本={stray or '无'}、无法归一化（保留原值）={unmapped or '无'}、"
               f"Running 集合={sorted(live_ips)}、组数={len(placed)}"),
              evidence=json.dumps({"placement": placed, "running": sorted(live_ips)},
                                  ensure_ascii=False)[:4000])


# ============================================================ PG-REB-01 均衡后 ≤ mu
def _reb_base(ctx: Ctx, model: str = "tree", count: int = 6, *, prefix: str = "pgr"):
    """REB 族公共前置：建库 + 写 count 个不同 slot，返回 (db, dialect, slot 映射)。"""
    d = dial(model)
    db = reset_db(ctx, model)
    items = expected_slots(ctx, db, d, count, prefix=prefix)
    mapping = slot_map_of(ctx, db, d, items)
    write_items(ctx, db, d, items)
    return db, d, items, mapping


def case_reb01_balanced_leq_mu(ctx: Ctx) -> None:
    """REB-01 均衡后每组槽数 ≤ mu（mu 由实测 slot/组数按源码公式现算）。"""
    db, d, _items, mapping = _reb_base(ctx, "tree")
    k = slot_total(mapping)
    ctx.check("前置：写入的 6 个设备确实落在 6 个互不相同 slot（客户端哈希计算）",
              k == len(mapping) == 6, f"K={k}、设备数={len(mapping)}、slots={sorted(mapping.values())}")
    assert_groups(ctx, "REB-01 写入后", db, d, k)
    assert_balanced(ctx, "REB-01 均衡分布", db, d, total_slots=k)


def case_reb02_spread_not_distorted(ctx: Ctx) -> None:
    """REB-02 组间分布不畸变：max-min ≤ 1，且与 mu 口径一致。"""
    db, d, _items, mapping = _reb_base(ctx, "tree", count=10, prefix="pgb")
    k = slot_total(mapping)
    stat = assert_balanced(ctx, "REB-02 分布与 mu 口径", db, d, total_slots=k)
    mu = stat["mu"]
    ctx.check("REB-02：mu 与「实测 slot/组数」按源码公式一致",
              mu == max(1, k // max(1, stat["groups"])),
              f"mu={mu}、K={k}、组数={stat['groups']}")
    ctx.check("REB-02：各组槽数落在 [mu-1, mu]（均分 + 余数；不假定余数给哪一组）",
              all(v in (mu - 1, mu) for v in stat["slots"]),
              f"分布={stat['counts']}、mu={mu}")


def case_reb03_new_group_gets_slots(ctx: Ctx) -> None:
    """REB-03 新增组后被分摊到槽：扩容后新组槽数 > 0（无空转组）。"""
    db, d, items, mapping = _reb_base(ctx, "tree", count=4, prefix="pgn")
    before = _slot_stats(ctx, db, d)
    more = expected_slots(ctx, db, d, 8, prefix="pgn")[4:]     # 再引入 4 个新 slot
    write_items(ctx, db, d, more, stamp=100)
    mapping.update(slot_map_of(ctx, db, d, more))
    k = slot_total(mapping)
    new_ids = ctx.api.group_ids(db, kind="DATA", dialect=d) - set(before["counts"])
    stat = assert_balanced(ctx, "REB-03 扩容后", db, d, total_slots=k)
    ctx.check("REB-03：新增了 Data 组（扩容确实发生）", len(new_ids) > 0,
              f"扩容前组数={before['groups']}、扩容后={stat['groups']}、新组={sorted(new_ids)}")
    ctx.check("REB-03：新组的槽数 > 0（被分摊到 slot，非空转）",
              all(stat["counts"].get(gid, 0) > 0 for gid in new_ids),
              f"新组分布={ {g: stat['counts'].get(g, 0) for g in sorted(new_ids)} }")


# ============================================================ PG-REB-04 热加载切回
def case_reb04_hot_reload_auto_back(ctx: Ctx) -> None:
    """REB-04 热加载切到 AUTO 再切回 PROACTIVE：重分摊仍满足 ≤ mu，结束恢复 conf 原值。"""
    keys = ("data_region_group_extension_policy",)
    host = ctx.cfg.cn_hosts[0]
    original = ctx.props.read(host, keys=keys).get(keys[0], "")
    d, db = "tree", reset_db(ctx, "tree")          # 每条用例开头统一重建测试库
    mapping = slot_map_of(ctx, db, d, expected_slots(ctx, db, d, 6, prefix="pgh"))
    write_items(ctx, db, d, expected_slots(ctx, db, d, 6, prefix="pgh"))
    try:
        ctx.mark_harness_action("热加载 data 策略为 AUTO", pad=20)
        ctx.req(ctx.api.set_config(keys[0], "AUTO"), "热加载 AUTO")
        hot_loaded = ctx.props.read(host, keys=keys).get(keys[0], "")
        ctx.check("REB-04：AUTO 已热加载（conf 回读自证）",
                  hot_loaded.strip().upper() == "AUTO", f"回读={hot_loaded!r}")
        ctx.mark_harness_action("热加载 data 策略回 PROACTIVE", pad=20)
        ctx.req(ctx.api.set_config(keys[0], "PROACTIVE"), "热加载回 PROACTIVE")
        back = ctx.props.read(host, keys=keys).get(keys[0], "")
        ctx.check("REB-04：已切回 PROACTIVE（conf 回读自证）",
                  back.strip().upper() == "PROACTIVE", f"回读={back!r}")
    finally:
        if original and original.strip().upper() != "PROACTIVE":
            ctx.mark_harness_action(f"恢复 conf 原值 {keys[0]}={original}", pad=20)
            ctx.req(ctx.api.set_config(keys[0], original), "恢复 conf 原值")
            restored = ctx.props.read(host, keys=keys).get(keys[0], "")
            ctx.check("REB-04：conf 原值已恢复", restored == original, f"回读={restored!r}")
    more = expected_slots(ctx, db, d, 10, prefix="pgh")[6:]
    write_items(ctx, db, d, more, stamp=200)
    mapping.update(slot_map_of(ctx, db, d, more))
    k = slot_total(mapping)
    assert_groups(ctx, "REB-04 切回 PROACTIVE 后写入", db, d, k)
    assert_balanced(ctx, "REB-04 重分摊", db, d, groups=min(k, group_ceiling(ctx, "DATA", d, db)),
                    total_slots=k)


# ============================================================ PG-REB-05..07 边界
def case_reb05_slots_fewer_than_groups(ctx: Ctx) -> None:
    """REB-05 K < 上限：组数 = min(K, 上限)，非空组的槽数之和 == K。"""
    d, db = "tree", reset_db(ctx, "tree")          # 每条用例开头统一重建测试库
    mapping = slot_map_of(ctx, db, d, expected_slots(ctx, db, d, 2, prefix="pgs"))
    write_items(ctx, db, d, expected_slots(ctx, db, d, 2, prefix="pgs"))
    k = slot_total(mapping)
    cap = expected_cap(ctx, "DATA", d, db)
    want = min(k, cap)
    assert_groups(ctx, "REB-05 稀疏写入", db, d, k)
    stat = _slot_stats(ctx, db, d)
    ctx.check("REB-05：非空组槽数之和 == K（无丢失、无重复计数）", stat["total"] == k,
              f"和={stat['total']}、K={k}", evidence=_dist(ctx, db, d))
    ctx.check("REB-05：组数确实是 min(K, 上限) 而非其它", stat["groups"] == want,
              f"min({k},{cap})={want}、实际={stat['groups']}")
    ctx.check("REB-05：仅有的 slot 分布为每非空组 ≤ mu 且总数守恒",
              stat["max"] <= stat["mu"] and stat["total"] == k, evidence=_dist(ctx, db, d))


def case_reb06_empty_db_no_side_effect(ctx: Ctx) -> None:
    """REB-06 空库重平衡无副作用：0 组、0 槽，重算 mu 不崩。"""
    db = reset_db(ctx, "tree")
    expect_groups(ctx, "REB-06 空库", db, "tree", schema=0, data=0)
    stat = _slot_stats(ctx, db, "tree")
    ctx.check("REB-06：空库 slot 数总和为 0（无预建槽）", stat["total"] == 0,
              f"分布={stat['counts']}")
    ctx.check("REB-06：0 组 0 槽时 mu 按 max(1, 0/0) 退化为 1 且不崩",
              stat["mu"] == 1 and stat["groups"] == 0,
              f"mu={stat['mu']}、组数={stat['groups']}")


def case_reb07_single_slot_db(ctx: Ctx) -> None:
    """REB-07 单 slot 库：1 组、1 槽，mu = max(1, 1/1) = 1。"""
    db = reset_db(ctx, "tree")
    ensure_write_tree(ctx, db, "solo", 1, sensors=("s0",))
    expect_groups(ctx, "REB-07 单 slot", db, "tree", schema=1, data=1)
    stat = assert_balanced(ctx, "REB-07 单 slot 分布", db, "tree", groups=1, total_slots=1)
    ctx.check("REB-07：单 slot 时 mu == 1 且该组恰好 1 槽",
              stat["mu"] == 1 and stat["max"] == 1, f"mu={stat['mu']}、分布={stat['counts']}")


# ============================================================ PG-REB-09..14 口径
def case_reb09_conserved_after_multi_slots(ctx: Ctx) -> None:
    """REB-09 多次写入后分布仍守恒：逐批写入，每批后 slot 和 == 累计 K。"""
    d, db = "tree", reset_db(ctx, "tree")
    mapping: dict[str, int] = {}
    for batch in range(1, 4):
        items = expected_slots(ctx, db, d, batch * 3, prefix=f"pgm{batch}")[(batch - 1) * 3:]
        write_items(ctx, db, d, items, stamp=batch * 10)
        mapping.update(slot_map_of(ctx, db, d, items))
        k = slot_total(mapping)
        stat = _slot_stats(ctx, db, d)
        ctx.check(f"REB-09 第 {batch} 批后：slot 总数守恒为 {k}", stat["total"] == k,
                  f"实际={stat['total']}", evidence=_dist(ctx, db, d))
        assert_balanced(ctx, f"REB-09 第 {batch} 批后分布", db, d, total_slots=k)


def case_reb10_mu_changes_with_groups(ctx: Ctx) -> None:
    """REB-10 组数变化后 mu 随之变化：mu 始终 == max(1, floor(实测 slot/实测组数))。"""
    d, db = "tree", reset_db(ctx, "tree")
    mapping: dict[str, int] = {}
    seen: set[int] = set()
    for step in range(1, 7):
        items = expected_slots(ctx, db, d, step, prefix="pgd")[step - 1:]
        write_items(ctx, db, d, items, stamp=step)
        mapping.update(slot_map_of(ctx, db, d, items))
        k = slot_total(mapping)
        stat = _slot_stats(ctx, db, d)
        seen.add(stat["groups"])
        ctx.check(f"REB-10 第 {step} 步：mu == floor(K={k}/组数={stat['groups']}) 口径",
                  stat["mu"] == max(1, k // max(1, stat["groups"])) and stat["total"] == k,
                  f"mu={stat['mu']}、分布={stat['counts']}")
    ctx.check("REB-10：过程中组数确实发生过变化（mu 口径被真正检验）", len(seen) > 1,
              f"观测到的组数集合={sorted(seen)}")


def case_reb11_two_models_same_rule(ctx: Ctx) -> None:
    """REB-11 树/表两模型分布口径一致：同样 K 个 slot 得到同样的组数与均衡条件。"""
    observed = {}
    for model in ("tree", "table"):
        d = dial(model)
        db = reset_db(ctx, model)          # 两个模型分别建库，避免互相占用分摊分母
        mapping = slot_map_of(ctx, db, d, expected_slots(ctx, db, d, 5, prefix="pgx"))
        write_items(ctx, db, d, expected_slots(ctx, db, d, 5, prefix="pgx"))
        k = slot_total(mapping)
        assert_groups(ctx, f"REB-11 {model} 模型", db, d, k)
        observed[model] = assert_balanced(ctx, f"REB-11 {model} 分布口径", db, d, total_slots=k)
    ctx.check("REB-11：两模型组数一致（同为 min(K, 各自上限)）",
              observed["tree"]["groups"] == observed["table"]["groups"],
              f"tree={observed['tree']['groups']}、table={observed['table']['groups']}")
    ctx.check("REB-11：两模型组间差口径一致（均满足 max-min ≤ 1）",
              (observed["tree"]["max"] - observed["tree"]["min"])
              == (observed["table"]["max"] - observed["table"]["min"]),
              f"tree 差={observed['tree']['max'] - observed['tree']['min']}、"
              f"table 差={observed['table']['max'] - observed['table']['min']}")


def case_reb12_write_balance_write(ctx: Ctx) -> None:
    """REB-12 写入→均衡→再写入 累积守恒：三段写入后 slot 和 == 三段 K 的并集。"""
    d, db = "tree", reset_db(ctx, "tree")
    mapping: dict[str, int] = {}
    for stage, count in ((1, 3), (2, 7), (3, 10)):
        items = expected_slots(ctx, db, d, count, prefix="pgc")[len(mapping):]
        write_items(ctx, db, d, items, stamp=stage * 50)
        mapping.update(slot_map_of(ctx, db, d, items))
        k = slot_total(mapping)
        stat = assert_balanced(ctx, f"REB-12 第 {stage} 段累计", db, d, total_slots=k)
        ctx.check(f"REB-12 第 {stage} 段：组数 = min(K={k}, 上限)",
                  stat["groups"] == min(k, group_ceiling(ctx, "DATA", d, db)),
                  f"实际组数={stat['groups']}")


def case_reb13_single_device_multi_sensors(ctx: Ctx) -> None:
    """REB-13 单设备多测点不改变分布：测点数从 1 → N 不新增 slot/组。"""
    d, db = "tree", reset_db(ctx, "tree")
    ensure_write_tree(ctx, db, "multi", 1, sensors=("s0",))
    first = _slot_stats(ctx, db, d)
    for sensors in (("s0", "s1", "s2"), tuple(f"m{i}" for i in range(10))):
        ensure_write_tree(ctx, db, "multi", 2, sensors=sensors)
        stat = _slot_stats(ctx, db, d)
        ctx.check(f"REB-13 扩到 {len(sensors)} 个测点：slot 分布与组数不变",
                  stat["counts"] == first["counts"],
                  f"前={first['counts']}、后={stat['counts']}")
    items = expected_slots(ctx, db, d, 4, prefix="pgq")
    write_items(ctx, db, d, items, stamp=3)
    # H-27：``multi`` 自己已占 1 个 slot，K 必须把历史 slot 一并算上（旧实现只数新写的 4 个
    # ⇒ 实测 5 组被判成"多扩容"）。
    k = slot_total(slot_map_of(ctx, db, d, ["multi"] + items))
    ctx.check(f"REB-13：单设备多测点后再写 4 个 slot，累计 K={k}，组数仍 = min(K, 上限)"
              "（无法「压扁」扩容）",
              ctx.api.db_group_num(db, "DATA", dialect=d)
              == min(k, group_ceiling(ctx, "DATA", d, db)),
              f"实际={ctx.api.db_group_num(db, 'DATA', dialect=d)}、K={k}"
              f"（含 multi 的历史 slot）")


def case_reb14_distribution_after_flush(ctx: Ctx) -> None:
    """REB-14 flush 后分布不变：落盘不触发重平衡。"""
    db, d, _items, mapping = _reb_base(ctx, "tree", count=5, prefix="pgf")
    k = slot_total(mapping)
    before = _slot_stats(ctx, db, d)
    ctx.mark_harness_action("显式 flush 落盘", pad=15)
    ctx.req(ctx.api.flush(), "flush")
    after = _slot_stats(ctx, db, d)
    ctx.check("REB-14：flush 后各组槽数快照完全不变", after["counts"] == before["counts"],
              f"flush 前={before['counts']}、flush 后={after['counts']}")
    assert_balanced(ctx, "REB-14 flush 后分布", db, d, total_slots=k)
    ctx.check("REB-14：flush 后组数仍 = min(K, 上限)",
              after["groups"] == min(k, group_ceiling(ctx, "DATA", d, db)),
              f"实际={after['groups']}")


# ============================================================ PG-HA-01..12
def case_ha01_write_during_dn_stop(ctx: Ctx) -> None:
    """HA-01 停 1 个 DataNode **紧接**继续写 3 个新 slot：写入成功且组数 = min(K, 上限)。"""
    if not need_dns(ctx, 3, "停 1 台后仍满足 DataRF 的多数派"):
        return
    d, db = "tree", reset_db(ctx, "tree")
    first = expected_slots(ctx, db, d, 2, prefix="h1a")
    more = expected_slots(ctx, db, d, 5, prefix="h1a")[2:]          # 停机后立刻写这 3 个新 slot
    write_items(ctx, db, d, first, stamp=1)
    mapping = slot_map_of(ctx, db, d, first)
    with _dn_lane(ctx, "HA-01"):
        write_items(ctx, db, d, more, stamp=10)
        mapping.update(slot_map_of(ctx, db, d, more))
        k = slot_total(mapping)
        ctx.check("HA-01：停机期间 3 个新 slot 的写入全部成功（req 未抛异常）", True,
                  f"K={k}、items={more}")
        assert_groups(ctx, "HA-01 停机期间写入", db, d, k)
        assert_balanced(ctx, "HA-01 停机期间分布", db, d, total_slots=k)
    ctx.check("HA-01：停机期间新写入的数据可查（count == 写入行数）",
              bool(more) and ctx.api.count_rows(f"{db}.{more[-1]}", dialect="tree") == 1,
              f"count={ctx.api.count_rows(f'{db}.{more[-1]}', dialect='tree')}")


def case_ha02_online_replicas(ctx: Ctx) -> None:
    """HA-02 各组在线副本数 == ``min(DataRF, 存活 DN 数)`` − 该组落在被停节点上的副本数。

    副本标识**归一化到 IP** 后比较；被停节点只来自本用例 ``_stop_dn`` 的登记
    （``Ctx.harness_stopped``），存活 DN 数 = 集群 DN 清单 − 被停集合（不再用全局在线集合反推）。
    """
    if not need_two_dns(ctx, "在停 1 台后仍有余量做副本口径断言"):
        return
    d, db = "tree", reset_db(ctx, "tree")
    mapping = slot_map_of(ctx, db, d, expected_slots(ctx, db, d, 4, prefix="h2"))
    write_items(ctx, db, d, expected_slots(ctx, db, d, 4, prefix="h2"))
    assert_groups(ctx, "HA-02 写入后", db, d, slot_total(mapping))
    with _dn_lane(ctx, "HA-02") as host:
        assert_online_replicas(ctx, "HA-02", db, d, host)
        assert_replica_addresses_known(ctx, "HA-02", db, d)


def case_ha03_status_back_running(ctx: Ctx) -> None:
    """HA-03 恢复节点后组状态回 Running（``statuses`` 里只允许 Running）。"""
    if not need_dns(ctx, 3, "停 1 台后仍能恢复共识"):
        return
    d, db = "tree", reset_db(ctx, "tree")
    first = expected_slots(ctx, db, d, 3, prefix="h3")
    more = expected_slots(ctx, db, d, 5, prefix="h3")[3:]        # 停机期间追加 2 个新 slot
    mapping = slot_map_of(ctx, db, d, first)
    write_items(ctx, db, d, first)
    with _dn_lane(ctx, "HA-03"):
        write_items(ctx, db, d, more, stamp=20)
        mapping.update(slot_map_of(ctx, db, d, more))
        assert_groups(ctx, "HA-03 停机期间写入", db, d, slot_total(mapping))
    deadline = time.time() + _RESTORE_TIMEOUT
    states: dict = {}
    while time.time() < deadline:
        states = {gid: (s or "").strip().lower()
                  for gid, s in ctx.api.statuses(db, kind="DATA", dialect=d).items()}
        if states and all(s == _RUNNING for s in states.values()):
            break
        time.sleep(_POLL)
    bad = {gid: s for gid, s in states.items() if s != _RUNNING}
    ctx.check("HA-03：恢复后全部 Data 组状态回到 Running（只允许 Running）", not bad,
              f"非 Running 组={bad or '无'}、组数={len(states)}")


def case_ha04_replica_ids_live(ctx: Ctx) -> None:
    """HA-04 全部副本**归一化到 IP 后**都能定位到本集群的 DataNode（Data + Schema 两组）。

    停机窗口内不再断言"副本全都在线"（产品在停机时仍保留被停节点的副本行是预期行为，
    该断言恒假）；改为：① 副本标识可归一化且属于本集群清单；② 没有被本用例停掉的节点
    "整组拿下线"。恢复后再断言"副本都落在 Running 节点上"。
    """
    if not need_dns(ctx, 3, "停 1 台后其余节点仍在线"):
        return
    d, db = "tree", reset_db(ctx, "tree")
    first = expected_slots(ctx, db, d, 3, prefix="h4")
    more = expected_slots(ctx, db, d, 5, prefix="h4")[3:]
    mapping = slot_map_of(ctx, db, d, first)
    write_items(ctx, db, d, first)
    with _dn_lane(ctx, "HA-04"):
        write_items(ctx, db, d, more, stamp=30)
        assert_replica_addresses_known(ctx, "HA-04 停机期间", db, d)
        assert_replica_addresses_known(ctx, "HA-04 停机期间 Schema", db, d, kind="SCHEMA")
        assert_no_group_fully_offline(ctx, "HA-04 停机期间", db, d)
        assert_no_group_fully_offline(ctx, "HA-04 停机期间 Schema", db, d, kind="SCHEMA")
    assert_replica_ids_live(ctx, "HA-04 恢复后", db, d)


def case_ha05_new_time_partition(ctx: Ctx) -> None:
    """HA-05 停 1 个 DN 期间新时间分区写入（同 slot 新分区）仍能补组到公式值。"""
    if not need_dns(ctx, 3, "停机期间新分区需多数派"):
        return
    d, db = "tree", reset_db(ctx, "tree")
    interval = ctx.api.db_time_partition_interval(db, dialect=d)
    detail = ctx.api.database_details(d).get(db, {})
    origin = 0
    for column in ("TimePartitionOrigin", "time_partition_origin"):
        if detail.get(column, "").strip():
            origin = int(detail[column].strip())
            break
    if interval <= 0:
        ctx.skip(f"读不到 TimePartitionInterval（={interval}），无法构造新时间分区")
        return
    # 时间戳落在不同分区的**边界内**：`[origin + n*interval, origin + (n+1)*interval)`
    base = origin or 0
    stamps = [base + interval + 1, base + 2 * interval + 1, base + 3 * interval + 1]
    device = expected_slots(ctx, db, d, 1, prefix="h5")[0]
    mapping = slot_map_of(ctx, db, d, [device])
    write_items(ctx, db, d, [device], stamp=stamps[0])
    with _dn_lane(ctx, "HA-05"):
        for stamp in stamps[1:]:              # 同一 slot、后续时间分区
            ensure_write_tree(ctx, db, device, stamp, sensors=("s0",))
        k = slot_total(mapping)
        ctx.check("HA-05：新时间分区不新增 SeriesSlot（同 slot）",
                  _slot_stats(ctx, db, d)["total"] == k, evidence=_dist(ctx, db, d))
        # H-27：同 slot 申请新分区 ⇒ G=1、|P|=1、K=1；源码 minNum 项让目标变成 2。
        assert_groups(ctx, "HA-05 停机期间新时间分区写入", db, d, k,
                      groups_before=1, p_count=1)
        rows = ctx.api.snapshot(db, kind="DATA", dialect=d)["groups"]
        time_slots = sorted({g["time_slots"] for g in rows})
        ctx.check("HA-05：确实写进了多个时间分区（TimeSlotNum 增加）",
                  bool(rows) and max(time_slots) >= 2,
                  f"各组 TimeSlotNum={time_slots}、写入时间戳={stamps}、"
                  f"origin={base}、interval={interval}")


def case_ha06_schema_scale_during_stop(ctx: Ctx) -> None:
    """HA-06 停 1 个 DN 期间 Schema 扩容（新 slot）：组数 = min(K, group_ceiling(SCHEMA))。"""
    if not need_dns(ctx, 3, "停机期间 Schema 扩容需多数派"):
        return
    d, db = "table", reset_db(ctx, "table")
    table = table_of(ctx)
    tags = expected_slots(ctx, db, d, 6, prefix="h6", table=table)
    mapping = slot_map_of(ctx, db, d, tags, table=table)
    write_items(ctx, db, d, tags[:2], table=table, stamp=1)
    with _dn_lane(ctx, "HA-06"):
        write_items(ctx, db, d, tags[2:], table=table, stamp=10)
        k = slot_total(mapping)
        cap = expected_cap(ctx, "SCHEMA", d, db)
        want = min(k, cap)
        expect_groups(ctx, "HA-06 停机期间 Schema 扩容", db, d, schema=want)
        got = ctx.api.db_group_num(db, "SCHEMA", dialect=d)
        ctx.check(f"HA-06：Schema 组数应为 min(K={k}, 上限={cap})={want}", got == want,
                  f"实际={got}")
        ctx.check("HA-06：Schema 扩容后 slot 和守恒",
                  sum(v for v in ctx.api.slot_counts(db, kind="SCHEMA", dialect=d).values()) == k,
                  evidence=str(ctx.api.slot_counts(db, kind="SCHEMA", dialect=d)))


def case_ha07_recovery_enables_sync(ctx: Ctx) -> None:
    """HA-07 恢复后 sync lag 归 0（收尾①自动查；本用例只需保证恢复并留证）。"""
    if not need_dns(ctx, 3, "停机后需要多数派恢复"):
        return
    d, db = "tree", reset_db(ctx, "tree")
    first = expected_slots(ctx, db, d, 3, prefix="h7")
    more = expected_slots(ctx, db, d, 4, prefix="h7")[3:]
    mapping = slot_map_of(ctx, db, d, first)
    write_items(ctx, db, d, first)
    with _dn_lane(ctx, "HA-07") as host:
        write_items(ctx, db, d, more, stamp=40)
        mapping.update(slot_map_of(ctx, db, d, more))
        assert_groups(ctx, "HA-07 停机期间写入", db, d, slot_total(mapping))
    live = _live_dn_count(ctx)
    ctx.check("HA-07：被停 DataNode 已回到在线集合（sync lag 归零的前提）",
              live == len(ctx.cfg.dn_hosts) and ctx.cluster.node_running(host, _DN),
              f"在线 DN={live}/{len(ctx.cfg.dn_hosts)}、host={host}")
    ctx.check("HA-07：by_design_gone 已包含恢复的节点（收尾①按此跳过等待）",
              host in ctx.by_design_gone, f"by_design_gone={sorted(ctx.by_design_gone)}")


def case_ha08_stop_and_readonly(ctx: Ctx) -> None:
    """HA-08 同时停 1 DN + 只读 1 DN：剩余 3 个 DN 仍满足多数派，写入与扩容不受影响。

    H-45b：只读档位用产品语句 ``SET SYSTEM TO READONLY``（IoTDBSqlParser.g4:1369）制造，
    恢复用 ``SET SYSTEM TO RUNNING``，两条都在 finally 里执行，任何路径都不留只读节点。
    """
    if not need_dns(ctx, 4, "停 1 + 只读 1 需要 4 个 DN 才能保持多数派"):
        return
    d, db = "tree", reset_db(ctx, "tree")
    items = expected_slots(ctx, db, d, 4, prefix="h8")
    first, more = items[:2], items[2:]
    write_items(ctx, db, d, first)
    mapping = slot_map_of(ctx, db, d, first)
    candidates = [h for h in ctx.cfg.dn_hosts if h not in ctx.by_design_gone]
    with _dn_lane(ctx, "HA-08") as stopped_host:
        ro_host = next((h for h in candidates if h != stopped_host), "")
        if not ro_host:
            ctx.skip("HA-08：无可用于只读档位的 DataNode")
            return
        ctx.mark_harness_action(f"HA-08：把 {ro_host} 置为只读（SET SYSTEM TO READONLY）", pad=15)
        ro = ctx.api.set_system("READONLY", host=ro_host)
        ctx.check(f"HA-08：{ro_host} 已切换为只读（SET SYSTEM TO READONLY）", ro.ok,
                  f"输出={ro.output[-300:]}")
        try:
            write_items(ctx, db, d, more, stamp=60)
            mapping.update(slot_map_of(ctx, db, d, more))
            assert_groups(ctx, "HA-08 停 1 + 只读 1 期间写入", db, d, slot_total(mapping))
            ctx.check("HA-08：只读 DataNode 仍在集群且状态为 ReadOnly",
                      (ctx.cluster.dn_status_for(ro_host) or "").lower().startswith("read"),
                      f"状态={ctx.cluster.dn_status_for(ro_host)}")
        finally:
            back = ctx.api.set_system("RUNNING", host=ro_host)
            ctx.check(f"HA-08：{ro_host} 已恢复 RUNNING", back.ok, f"输出={back.output[-300:]}")
    ctx.check("HA-08：恢复后数据可查",
              ctx.api.count_rows(f"{db}.{items[-1]}", dialect="tree") >= 1,
              f"count={ctx.api.count_rows(f'{db}.{items[-1]}', dialect='tree')}")


def case_ha09_drop_create_during_stop(ctx: Ctx) -> None:
    """HA-09 停 1 个 DN 后 drop+create 库再写：扩容在新库上仍正常。"""
    if not need_dns(ctx, 3, "停机期间重建库需多数派"):
        return
    d, db = "tree", reset_db(ctx, "tree")
    items = expected_slots(ctx, db, d, 4, prefix="h9")
    mapping = slot_map_of(ctx, db, d, items)
    with _dn_lane(ctx, "HA-09"):
        db = reset_db(ctx, "tree")                      # 停机期间重建
        # H-28：旧实现 ``create database root.pg.sub`` 是**非法前置**——产品不允许在
        # 已有库下再建库（实测 ``501: root.pg has already been created as database``）。
        # 改为在同层建一个独立库（与 tests 里其它"额外库"用例一致，收尾登记删除）。
        sub = f"{db}sub"
        ctx.cleanup.append(f"drop database {sub}")
        ctx.req(ctx.api.create_database(sub), f"create database {sub}")
        write_items(ctx, db, d, items, stamp=1)
        k = slot_total(mapping)
        ctx.check("HA-09：停机期间重建库成功且新库可见",
                  db in ctx.api.database_details(d), f"库={db}")
        ctx.check("HA-09：停机期间新建同级库成功且可见（非法建库路径已修正）",
                  sub in ctx.api.database_details(d), f"新库={sub}")
        assert_groups(ctx, "HA-09 新库写入", db, d, k)
    ctx.check("HA-09：恢复后新库数据仍可查",
              ctx.api.count_rows(f"{db}.{items[-1]}", dialect="tree") >= 1,
              f"count={ctx.api.count_rows(f'{db}.{items[-1]}', dialect='tree')}")


def case_ha10_two_rounds_stop_write(ctx: Ctx) -> None:
    """HA-10 连续两轮「停→写→恢复」：每轮都断言组数与公式一致。"""
    if not need_dns(ctx, 3, "两轮停机各需多数派"):
        return
    d, db = "tree", reset_db(ctx, "tree")
    mapping: dict[str, int] = {}
    hosts = [h for h in ctx.cfg.dn_hosts]
    for round_id in (1, 2):
        host = hosts[(round_id - 1) % len(hosts)] if hosts else ""
        with _dn_lane(ctx, f"HA-10 第 {round_id} 轮（借 {host}）"):
            items = expected_slots(ctx, db, d, round_id * 3, prefix="h10")[(round_id - 1) * 3:]
            write_items(ctx, db, d, items, stamp=round_id * 100)
            mapping.update(slot_map_of(ctx, db, d, items))
            k = slot_total(mapping)
            assert_groups(ctx, f"HA-10 第 {round_id} 轮停机期间写入", db, d, k)
            assert_balanced(ctx, f"HA-10 第 {round_id} 轮分布", db, d, total_slots=k)


def case_ha11_no_over_cap(ctx: Ctx) -> None:
    """HA-11 停 DN 期间不出现「组数超过上限」（含热加载上限收紧后的追赶窗口）。"""
    if not need_dns(ctx, 3, "停机期间写入需多数派"):
        return
    d, db = "tree", reset_db(ctx, "tree")
    mapping: dict[str, int] = {}
    with _dn_lane(ctx, "HA-11"):
        for step in range(1, 9):
            items = expected_slots(ctx, db, d, step, prefix="h11")[step - 1:]
            write_items(ctx, db, d, items, stamp=step)
            mapping.update(slot_map_of(ctx, db, d, items))
            # H-35：上限优先取产品自报 MaxDataRegionGroupNum（H-10/H-19 口径）；
            # 读不到才退回公式值，避免"公式 < 产品自报"时把合规判成超限。
            _reported = ctx.api.db_max_group_num(db, "DATA", dialect=d)
            cap = _reported if isinstance(_reported, int) and _reported > 0 else expected_cap(ctx, "DATA", d, db)
            got = ctx.api.db_group_num(db, "DATA", dialect=d)
            detail = ctx.api.database_details(d).get(db, {})
            ctx.check(f"HA-11 第 {step} 步：Data 组数({got}) 未超过产品自报上限({cap})",
                      got <= cap, f"组数={got}、上限={cap}",
                      evidence=str({key: val for key, val in detail.items()
                                    if "GroupNum" in key or "group_num" in key}))
            ctx.check(f"HA-11 第 {step} 步：组数 = min(K={slot_total(mapping)}, 产品自报上限={cap})",
                      got == min(slot_total(mapping), cap),
                      f"实际={got}")


def case_ha12_no_data_loss(ctx: Ctx) -> None:
    """HA-12 停 DN 期间写入不丢数据：恢复后 count_rows 等于写入行数。"""
    if not need_dns(ctx, 3, "停机期间写入需多数派"):
        return
    # H-20：本用例全程走**表模型**（write_items/count_rows/slot_map_of 均用 table 方言），
    # 必须用表模型测试库；原先用树库 root.pg 会被产品以 701（tree model database shall
    # not be specified in table model）**正确**拒绝。
    d, db = "table", reset_db(ctx, "table")
    table = table_of(ctx)
    tags = expected_slots(ctx, db, "table", 5, prefix="h12", table=table)
    mapping = slot_map_of(ctx, db, "table", tags, table=table)
    write_items(ctx, db, "table", tags[:2], table=table, stamp=1)
    with _dn_lane(ctx, "HA-12"):
        write_items(ctx, db, "table", tags[2:], table=table, stamp=10)
        assert_groups(ctx, "HA-12 停机期间写入", db, "table", slot_total(mapping))
    deadline = time.time() + _RESTORE_TIMEOUT
    rows = ctx.api.count_rows(f"{db}.{table}", dialect="table")
    while rows != len(tags) and time.time() < deadline:
        ctx.mark_harness_action("等待恢复后 count 收敛", pad=5)
        ctx.req(ctx.api.flush(), "flush")
        time.sleep(_POLL)
        rows = ctx.api.count_rows(f"{db}.{table}", dialect="table")
    ctx.check(f"HA-12：恢复后行数 == 写入行数（{len(tags)}）", rows == len(tags),
              f"实际 count={rows}")
    ctx.check("HA-12：停机期间的写入确实落到了 Data 组（组数未退化）",
              len(ctx.api.group_ids(db, kind="DATA", dialect="table")) == slot_total(mapping),
              f"实际组数={len(ctx.api.group_ids(db, kind='DATA', dialect='table'))}")


# ============================================================ SPECS
def _spec(case_id, area, model, title, fn, *, note="") -> CaseSpec:
    return CaseSpec(case_id, area, model, title, "P0", fn, note=note)


SPECS.extend([
    _spec("PG-REB-01", "重平衡", TW, "均衡后每组槽数 ≤ mu（mu 由实测 slot/组数现算）",
          case_reb01_balanced_leq_mu,
          note="mu = max(1, floor(非空 slot 数 / Data 组数))，DataPartitionPolicyTable.java:163-173"),
    _spec("PG-REB-02", "重平衡", TW, "组间分布不畸变：max-min ≤ 1 且与 mu 口径一致",
          case_reb02_spread_not_distorted),
    _spec("PG-REB-03", "重平衡", TW, "新增 Data 组后被分摊到槽（新组槽数 > 0）",
          case_reb03_new_group_gets_slots),
    _spec("PG-REB-04", "重平衡", TW, "热加载切 AUTO 再切回 PROACTIVE：重分摊仍 ≤ mu，结束恢复 conf 原值",
          case_reb04_hot_reload_auto_back),
    _spec("PG-REB-05", "重平衡", TW, "K < 上限：组数 = min(K, expected_cap)，非空组槽数和 == K",
          case_reb05_slots_fewer_than_groups),
    _spec("PG-REB-06", "重平衡", TW, "空库重平衡无副作用：0 组、0 槽、mu 退化不崩",
          case_reb06_empty_db_no_side_effect),
    _spec("PG-REB-07", "重平衡", TW, "单 slot 库：1 组、1 槽、mu == 1",
          case_reb07_single_slot_db),
    _spec("PG-REB-09", "重平衡", TW, "多次写入后分布仍守恒（逐批断言 slot 和 == 累计 K）",
          case_reb09_conserved_after_multi_slots),
    _spec("PG-REB-10", "重平衡", TW, "组数变化后 mu 随之变化（mu 始终按实测 slot/组数现算）",
          case_reb10_mu_changes_with_groups),
    _spec("PG-REB-11", "重平衡", TW, "树/表两模型分布口径一致（同 K 同组数同均衡条件）",
          case_reb11_two_models_same_rule),
    _spec("PG-REB-12", "重平衡", TW, "写入→均衡→再写入 累积守恒（三段并集 == slot 总数）",
          case_reb12_write_balance_write),
    _spec("PG-REB-13", "重平衡", TW, "单设备多测点不改变分布（1→N 测点 slot/组数不变）",
          case_reb13_single_device_multi_sensors),
    _spec("PG-REB-14", "重平衡", TW, "flush 后分布与组数不变（落盘不触发重平衡）",
          case_reb14_distribution_after_flush),
    _spec("PG-HA-01", "高可用", TW, "停 1 DN 紧接写 3 个新 slot：写入成功且组数 = min(K, expected_cap)",
          case_ha01_write_during_dn_stop, note="需 ≥3 DN"),
    _spec("PG-HA-02", "高可用", TW,
          "在线副本数（归一化到 IP）== min(DataRF, 存活 DN 数) − 该组落在被停节点上的副本数"
          "（不断言恒等于 RF）",
          case_ha02_online_replicas, note="需 DataRF ≥ 2；被停节点来自 harness 动作登记"),
    _spec("PG-HA-03", "高可用", TW, "恢复节点后组状态回 Running（statuses 只允许 Running）",
          case_ha03_status_back_running, note="需 ≥3 DN"),
    _spec("PG-HA-04", "高可用", TW,
          "全部副本归一化到 IP 后都能定位到本集群 DataNode（Data + Schema），"
          "恢复后都落在 Running 节点上",
          case_ha04_replica_ids_live, note="需 ≥3 DN"),
    _spec("PG-HA-05", "高可用", TW, "停 1 DN 期间新时间分区写入（同 slot 新分区）仍补组到公式值",
          case_ha05_new_time_partition, note="需 ≥3 DN"),
    _spec("PG-HA-06", "高可用", "table",
          "停 1 DN 期间 Schema 扩容（新 slot）：组数 = min(K, group_ceiling(SCHEMA))",
          case_ha06_schema_scale_during_stop, note="需 ≥3 DN"),
    _spec("PG-HA-07", "高可用", TW, "恢复后 sync lag 归 0（收尾①自动查，本用例保证恢复并留证）",
          case_ha07_recovery_enables_sync, note="需 ≥3 DN"),
    _spec("PG-HA-08", "高可用", TW, "停 1 DN + 只读 1 DN：cluster.py 缺只读接口 ⇒ SKIP",
          case_ha08_stop_and_readonly, note="档位缺失，SKIP"),
    _spec("PG-HA-09", "高可用", TW, "停 1 DN 后 drop+create 库再写：扩容在新库上仍正常",
          case_ha09_drop_create_during_stop, note="需 ≥3 DN"),
    _spec("PG-HA-10", "高可用", TW, "连续两轮「停→写→恢复」，每轮组数 = min(K, expected_cap)",
          case_ha10_two_rounds_stop_write, note="需 ≥3 DN"),
    _spec("PG-HA-11", "高可用", TW, "停 DN 期间不出现组数超过上限（逐 slot 断言 ≤ 上限）",
          case_ha11_no_over_cap, note="需 ≥3 DN"),
    _spec("PG-HA-12", "高可用", "table", "停 DN 期间写入不丢数据：恢复后 count_rows == 写入行数",
          case_ha12_no_data_loss, note="需 ≥3 DN"),
])

