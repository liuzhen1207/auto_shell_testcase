"""1.3.x ←→ 2.x 兼容判据（**纯函数**，不碰集群/网络，便于离线自测）。

本模块只回答"某个字符串/某条 CLI 输出属于哪个版本线、该怎么解读"这一类问题，
上层（``remote``/``cases``/``cases_upg``）据此选分支。所有函数不 import 本包其它
模块，避免循环依赖，也让 ``selftest`` 能在没有集群的情况下回归这些判据。

判据来源（1.3.7-SNAPSHOT 企业包实测，见 ``references/`` 与结果目录证据）：

* ``sbin/start-cli.sh`` 只识别 ``-h/-p/-u/-pw/-D``，其余参数原样透传给
  ``org.apache.iotdb.cli.Cli``；``-sql_dialect`` 是 **2.x 才有的选项**，
  1.3 下会打出一条 ``Require more params input … usage: IoTDB …`` 的用法提示，
  而退出码仍是 0（⇒ 若不识别，会被上层当成"空结果集"）。
* 1.3 的 CLI 失败行是 ``ErrorCan't execute sql because801: Authentication failed.``
  （``Error`` 后面**没有冒号**），2.x 是 ``Error: …``；两种都要当错误。
* 1.3 的默认管理员密码是 ``root``（包内 ``README_zh``：``-u root -pw root``），
  2.0 起是 ``TimechoDB@2021`` —— 用 2.x 密码连 1.3 必然 801。
* 1.3 ``SHOW CLUSTER`` 没有同步延迟列（只有
  ``NodeID|NodeType|Status|InternalAddress|InternalPort|Version|BuildInfo|ActivateStatus``），
  所以"sync lag 归零"这一条必须换成等价判据（全节点 Running + 无 Region 中间态）。
"""

from __future__ import annotations

import re

#: 1.x 版本串前缀（1.3.7-SNAPSHOT / 1.3.0 / 1.2.x …）
V1_PREFIXES: tuple[str, ...] = ("1.", "1.3", "1.2", "1.1", "1.0")

#: 2.x 版本串前缀
V2_PREFIXES: tuple[str, ...] = ("2.", "2.0", "2.1")

#: CLI 参数解析失败的用例提示（1.3 遇到未知选项时打印这段用法）
CLI_USAGE_MARKERS: tuple[str, ...] = (
    "Require more params input",
    "For more information, please check the following hint",
    "usage: IoTDB",
)

#: 认证失败的标志（1.3/2.x 都是 801；1.3 的 "Error" 后面没有冒号）
AUTH_MARKERS: tuple[str, ...] = (
    "Authentication failed",
    "because801",
    " 801:",
)

_SEMVER = re.compile(r"(\d+)\.(\d+)(?:\.(\d+))?")


def version_prefix_of(text: str) -> str:
    """从任意含版本号的串里取 ``major.minor``；取不到返回 ``""``。"""
    match = _SEMVER.search(text or "")
    if not match:
        return ""
    return f"{match.group(1)}.{match.group(2)}"


def is_v13_text(text: str) -> bool:
    """``text`` 里出现的版本号是不是 1.3.x（1.3.7-SNAPSHOT / 1.3.0.1 …）。"""
    return version_prefix_of(text) == "1.3"


def is_v1_text(text: str) -> bool:
    """``text`` 里出现的版本号是不是 1.x 线（含 1.2/1.3）。"""
    prefix = version_prefix_of(text)
    return bool(prefix) and prefix.startswith("1.")


def is_v2_text(text: str) -> bool:
    return version_prefix_of(text).startswith("2.")


def conf_says_v13(cfg) -> bool:
    """conf 里 ``DB_VERSION``（或升级源版本）是否声明了 1.3 线。

    ``cfg`` 只要求有 ``raw(key)``。**判定只看配置，不探测集群** —— 供
    ``remote.SqlClient`` 在"第一条语句之前"就能决定 CLI 参数形态。
    """
    try:
        version = (cfg.raw("DB_VERSION") or "").strip()
    except Exception:  # noqa: BLE001 - 任何异常都按"未知"处理
        version = ""
    return is_v1_text(version)


def cli_allows_sql_dialect(version_text: str) -> bool:
    """该版本线的 ``start-cli.sh`` 是否认识 ``-sql_dialect``（2.x 才认识）。

    未知版本（空串）**保持 2.x 行为**（带该参数），以免影响既有 2.x 轮次；
    1.3 若 conf 没写 DB_VERSION，``SqlClient`` 还有一层"用法提示 → 去掉参数重试"的兜底。
    """
    return not is_v1_text(version_text)


def looks_like_cli_usage_error(text: str) -> bool:
    """CLI 有没有把参数解析失败、打印用法提示（而不是真的执行了语句）。"""
    return any(marker in (text or "") for marker in CLI_USAGE_MARKERS)


def looks_like_auth_error(text: str) -> bool:
    """是不是认证失败（801）。"""
    flat = text or ""
    return any(marker in flat for marker in AUTH_MARKERS)


_TOTAL_LINE = re.compile(r"Total line number\s*=\s*(\d+)", re.I)


def parse_total_line_number(text: str) -> int | None:
    """1.3/2.x CLI 在结果集末尾打印 ``Total line number = N``；取不到返回 ``None``。

    1.3 兼容的计数口径：``select * from <device>`` + 这行的 N，不依赖任何
    2.x 才有的 ``count(*)`` 输出形态。
    """
    found = _TOTAL_LINE.search(text or "")
    return int(found.group(1)) if found else None


#: 节点"活着"的状态（与 ``cluster.status_is`` 同口径，此处保留纯函数副本供离线自测）
NODE_UP_STATUSES: tuple[str, ...] = ("running", "readonly")

#: Region 的**中间态**（迁移/重建/删除中）；出现这些说明还在收敛，等价于 syncLag 没归零
REGION_TRANSITIONAL: tuple[str, ...] = (
    "unknown",
    "unavailable",
    "unavailableconsensus",
    "initializing",
    "creating",
    "removing",
    "removed",
    "deleting",
    "deleted",
    "migrating",
    "extending",
    "shrinking",
    "discouraged",
    "notready",
    "not ready",
    "pending",
    "offline",
    "down",
    "stopped",
)

#: 这些状态名说明"region 已经稳定可用"
REGION_SETTLED: tuple[str, ...] = (
    "running",
    "leader",
    "follower",
    "available",
    "normal",
    "ok",
    "healthy",
    "up",
)


def base_status(raw: str) -> str:
    """把 ``ReadOnly(UNACTIVATED)`` 一类的带限定符状态拆成基态（小写）。"""
    text = (raw or "").strip()
    if text.endswith(")") and "(" in text:
        text = text.split("(", 1)[0]
    return text.strip().lower()


def node_status_ok(raw: str) -> bool:
    return base_status(raw) in NODE_UP_STATUSES


def region_status_settled(raw: str) -> bool:
    """Region 状态是否已稳定（1.3 "无 syncLag" 等价判据的核心谓词）。

    空串（没有该列/没值）按"无从判断"处理 → 返回 ``True``，由调用方在
    detail 里注明"该口径不可观测"，绝不据此判 FAIL。
    """
    status = base_status(raw)
    if not status:
        return True
    if status in REGION_SETTLED:
        return True
    return status not in REGION_TRANSITIONAL and not any(
        word in status for word in REGION_TRANSITIONAL)


def selftest() -> None:
    """离线自测（由 ``pgkit.selftest`` 调用）；断言失败抛 ``AssertionError``。"""
    assert is_v13_text("1.3.7-SNAPSHOT"), "1.3.7-SNAPSHOT 应判为 1.3"
    assert is_v13_text("1.3.0"), "1.3.0 应判为 1.3"
    assert not is_v13_text("2.0.11-SNAPSHOT"), "2.0.11 不该判为 1.3"
    assert is_v1_text("1.3.7-SNAPSHOT") and is_v1_text("1.2.2")
    assert is_v2_text("2.0.11-SNAPSHOT") and not is_v2_text("1.3.7-SNAPSHOT")
    assert version_prefix_of("Version: 1.3.7-SNAPSHOT") == "1.3"
    assert version_prefix_of("") == ""

    # CLI 参数：1.3 不认识 -sql_dialect；未知版本保持 2.x 行为
    assert not cli_allows_sql_dialect("1.3.7-SNAPSHOT")
    assert cli_allows_sql_dialect("2.0.11-SNAPSHOT")
    assert cli_allows_sql_dialect("")

    class _Cfg:
        def __init__(self, values):
            self.values = values

        def raw(self, key, default=""):
            return self.values.get(key, default)

    assert conf_says_v13(_Cfg({"DB_VERSION": "1.3.7-SNAPSHOT"}))
    assert not conf_says_v13(_Cfg({"DB_VERSION": "2.0.11-SNAPSHOT"}))
    # DB_VERSION 缺失时**不**拿 PG_UPGRADE_FROM_VERSION 兜底（它的默认值就是 1.3，
    # 会把所有没写 DB_VERSION 的 2.x 档误判成 1.3）；交给运行时 show cluster 兜底
    assert not conf_says_v13(_Cfg({}))

    # 1.3 的失败行没有 "Error:" 冒号，也必须认出来
    assert looks_like_auth_error(
        "ErrorCan't execute sql because801: Authentication failed.")
    assert looks_like_auth_error("Msg: 801: Authentication failed")
    assert not looks_like_auth_error("Total line number = 1")
    assert looks_like_cli_usage_error(
        "Require more params input, eg. ./start-cli.sh -h xxx.xxx.xxx.xxx -p xxxx")
    assert not looks_like_cli_usage_error("+---+\n| s0 |\n+---+")

    assert parse_total_line_number("+---+\n| s0 |\n+---+\n| 1 |\n+---+\n"
                                  "Total line number = 1\nIt costs 0.004s\n") == 1
    assert parse_total_line_number("") is None

    assert node_status_ok("Running") and node_status_ok("ReadOnly(UNACTIVATED)")
    assert not node_status_ok("Unknown") and not node_status_ok("Stopped")
    assert region_status_settled("Running") and region_status_settled("Leader")
    assert region_status_settled("")            # 不可观测 ≠ 坏
    assert not region_status_settled("Unknown")
    assert not region_status_settled("Removing")
    assert not region_status_settled("Unavailable")
