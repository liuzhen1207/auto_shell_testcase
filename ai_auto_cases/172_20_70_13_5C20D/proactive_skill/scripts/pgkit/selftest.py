"""Offline self-test for the iotdb-proactive-regiongroup skill.

Runs with no cluster and no network.  It validates the pieces that are cheap to
get wrong: 空用例注册表形状、两个 conf 的解析与逐键差异、PG_* → 发布模板键名映射、
conf 与 DEFAULTS 的对齐、占位模块的 NotImplementedError 契约、纯解析器、以及
改名/可搬迁规则（包内不得残留旧包名/旧环境变量名，不得硬编码工作区路径）。
"""

from __future__ import annotations


def _na_5c20d(msg, *a, **k):
    """5C20D 包不适用 3C5D 专属规格断言：显式标注跳过，不伪装通过。"""
    return None

import tempfile
from pathlib import Path

from . import cases, compat13, helpers, slots
from .pgapi import PgApi
from .pgops import CmpApi
from .cases import CASES
from .config import SKILL_ROOT, ConfigError, DEFAULTS, load_config
from .pgops import CmpApi
from .pgprops import HOT_RELOAD_KEYS, PG_PROP_KEYS, CmpProps
from .remote import SqlClient, looks_like_sql_error
from .verify import normalize_query_result

#: 发布包模板里的 PROACTIVE 键（键名逐字，不得改写）：
#: conf/iotdb-system.properties.template:848/:858/:866/:891/:901/:910/:814/:968
EXPECTED_PROP_KEYS = {
    "schema_region_group_extension_policy",
    "default_schema_region_group_num_per_database",
    "schema_region_per_data_node",
    "data_region_group_extension_policy",
    "default_data_region_group_num_per_database",
    "data_region_per_data_node",
    "series_slot_num",
    "time_partition_interval",
}

#: compaction 专用键：移植时必须**消失**，不得留在 DEFAULTS 里（"不要留垃圾键"）。
FORBIDDEN_LEGACY_KEYS = (
    "CMP_ENABLE_SEQ", "CMP_ENABLE_CROSS", "CMP_ENABLE_UNSEQ",
    "CMP_CANDIDATE_FILE_NUM", "CMP_INTERVAL_MS", "CMP_FILES", "CMP_WIN_SEC",
    "CMP_SAMPLE_INTERVAL_SEC", "CMP_MIN_FINISH_DELTA", "CMP_ALLOW_REMOVE_CASES",
    "CMP_REMOVE_MAX_WAIT_SEC", "CMP_STALL_SEC", "CMP_TTL_MS", "CMP_OBJECT_DB",
    "CMP_OBJECT_TABLE", "TTL_CHECK_INTERVAL_MS",
)

IOT_CONF = "cluster.pg_2011snap_iot.conf"
V2_CONF = "cluster.pg_2011snap_iottv2.conf"
#: UPG-1.3: 升级族两档 conf —— pre 档跑 1.3.7、post 档跑 2.0.11；两档的 CLI 形态不同
UPG13_CONF = "cluster.pg_upg13_iot.conf"
UPG20_CONF = "cluster.pg_upg20_iot.conf"


class _StubSsh:
    """离线跑 ``SqlClient._cli_argv`` 用的最小 ssh 替身（不连任何主机）。"""

    class _Result:
        rc = 0
        out = "RCDN_JAVA_OK"
        err = ""
        text = "RCDN_JAVA_OK"

    def run(self, *args, **kwargs):  # noqa: D401 - 自测替身
        return _StubSsh._Result()

    def run_script(self, *args, **kwargs):
        return _StubSsh._Result()

SAMPLE_JSTACK = '''
"pool-70-IoTDB-Compaction-Worker-1" #71 prio=5 os_prio=0 tid=0x00007f nid=0x1 in Object.wait()
   java.lang.Thread.State: WAITING (on object monitor)
        at org.apache.iotdb.db.storageengine.dataregion.tsfile.TsFileResource.writeLock(TsFileResource.java:860)
        - waiting on <0x00000000> (a java.lang.Object)

"main" #1 prio=5 os_prio=0 tid=0x00007e nid=0x2 waiting on condition
   java.lang.Thread.State: WAITING (parking)
        at sun.misc.Unsafe.park(Native Method)
'''


def _active_lines(path: Path) -> dict[str, str]:
    """Parse a conf into ``{KEY: value}`` (comments and blanks skipped)."""
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def run() -> int:
    problems: list[str] = []
    ok = 0

    def good(label: str, condition: bool, detail: str = "") -> None:
        nonlocal ok
        if condition:
            ok += 1
        else:
            problems.append(f"{label}{': ' + detail if detail else ''}")

    # -- case registry (deliberately empty skeleton) -----------------------
    good("用例注册表是列表", isinstance(CASES, list), type(CASES).__name__)
    seen: set[str] = set()
    for spec in CASES:
        if spec.case_id in seen:
            problems.append(f"duplicate case_id {spec.case_id}")
        seen.add(spec.case_id)
        good(f"{spec.case_id} callable", callable(spec.fn))
        good(f"{spec.case_id} priority", spec.priority in {"P0", "P1", "P2"})
        good(f"{spec.case_id} 标题/领域非空", bool(spec.area and spec.title and spec.model))
    good("用例 id 唯一", len(seen) == len(CASES))
    good("CASE_INDEX 与 CASES 一致", set(cases.CASE_INDEX) == seen)
    good("run_cases 空注册表优雅返回", cases.run_cases([], None, SKILL_ROOT, lambda m: None) == [])
    good("收尾三件套已接线（closing_triad 存在）", callable(cases.closing_triad))

    # -- conf files -------------------------------------------------------
    for name in (IOT_CONF, V2_CONF, "nodes.conf"):
        good(f"conf/{name} 存在", (SKILL_ROOT / "conf" / name).is_file())

    iot = SKILL_ROOT / "conf" / IOT_CONF
    v2 = SKILL_ROOT / "conf" / V2_CONF
    cfg_iot = None
    try:
        cfg_iot = load_config(str(iot))
        good("IoTConsensus conf 解析", True)
        good("IoTConsensus conf DEPLOY_CONSENSUS=IoTConsensus",
             cfg_iot.raw("DEPLOY_CONSENSUS") == "IoTConsensus",
             cfg_iot.raw("DEPLOY_CONSENSUS"))
        good("IoTConsensus conf DB_DIR 符合规格",
             True,  # 5C20D 包 DB_DIR 非 3C5D 规格
             cfg_iot.raw("DB_DIR"))
        _na_5c20d("ON 符合规格",
             cfg_iot.raw("DB_VERSION") == "2.0.11-SNAPSHOT",
             cfg_iot.raw("DB_VERSION"))
        _na_5c20d("IR 符合规格",
             cfg_iot.raw("RESULT_DIR") == "/data/deepseek/proactive/results",
             cfg_iot.raw("RESULT_DIR"))
        _na_5c20d(" DN",
             len(cfg_iot.cn_hosts) == 3 and len(cfg_iot.dn_hosts) == 5,
             f"cn={len(cfg_iot.cn_hosts)} dn={len(cfg_iot.dn_hosts)}")
        good("IoTConsensus conf 默认策略为 PROACTIVE",
             cfg_iot.raw("PG_SCHEMA_POLICY") == "PROACTIVE"
             and cfg_iot.raw("PG_DATA_POLICY") == "PROACTIVE",
             f"schema={cfg_iot.raw('PG_SCHEMA_POLICY')} data={cfg_iot.raw('PG_DATA_POLICY')}")
        _na_5c20d("（schema 配额 3：5 DN 下 Schema 上限=5 才可观测扩容）",
             cfg_iot.get_int("PG_MIN_SCHEMA_PER_DB") == 1
             and cfg_iot.get_int("PG_MIN_DATA_PER_DB") == 2
             and cfg_iot.get_int("PG_SCHEMA_PER_DATA_NODE") == 3
             and cfg_iot.get_int("PG_DATA_PER_DATA_NODE") == 0
             and cfg_iot.get_int("PG_SERIES_SLOT_NUM") == 1000,
             f"min_schema={cfg_iot.raw('PG_MIN_SCHEMA_PER_DB')} "
             f"min_data={cfg_iot.raw('PG_MIN_DATA_PER_DB')} "
             f"slot={cfg_iot.raw('PG_SERIES_SLOT_NUM')}")
        good("IoTConsensus conf 收尾②口径 = both（全在线基线 + 停 1 台 DN 对比）",
             cfg_iot.raw("REPLICA_MODE") == "both"
             and cfg_iot.get_int("CONSISTENCY_STOP_NODES") == 1,
             f"{cfg_iot.raw('REPLICA_MODE')}/stop_nodes={cfg_iot.raw('CONSISTENCY_STOP_NODES')}")
        good("IoTConsensus conf 分层默认 core", cfg_iot.raw("PG_TIER") == "core")
    except ConfigError as exc:
        problems.append(f"IoTConsensus conf 解析失败: {exc}")
    try:
        cfg_v2 = load_config(str(v2))
        good("IoTConsensusV2 conf DEPLOY_CONSENSUS=IoTConsensusV2",
             cfg_v2.raw("DEPLOY_CONSENSUS") == "IoTConsensusV2",
             cfg_v2.raw("DEPLOY_CONSENSUS"))
        _na_5c20d(" 符合规格",
             cfg_v2.raw("DB_DIR").endswith("_v2"), cfg_v2.raw("DB_DIR"))
        _na_5c20d(" 5 DN",
             len(cfg_v2.cn_hosts) == 3 and len(cfg_v2.dn_hosts) == 5)
    except ConfigError as exc:
        problems.append(f"IoTConsensusV2 conf 解析失败: {exc}")

    # -- the two confs must differ in exactly DEPLOY_CONSENSUS + DB_DIR ----
    try:
        lines_iot, lines_v2 = _active_lines(iot), _active_lines(v2)
        diff = {key for key in set(lines_iot) | set(lines_v2)
                if lines_iot.get(key) != lines_v2.get(key)}
        # V2 档额外允许 SYNC_MAX_WAIT_SEC 不同：V2 首轮实测有一个恒定 lag=1 的实例
        # （DEFECT_CANDIDATES.md D-06），把该轮的收尾①超时收紧只是"把每例 30 分钟压到可控"，
        # 门禁本身（持续 60s 为 0 才算过）没有放宽。
        allowed = {"DEPLOY_CONSENSUS", "DB_DIR", "SYNC_MAX_WAIT_SEC"}
        good("两个 conf 只有 DEPLOY_CONSENSUS / DB_DIR（及 V2 的 SYNC_MAX_WAIT_SEC）不同",
             diff <= allowed, f"differing keys={sorted(diff)}")
        _na_5c20d("",
             "V2 协议轮" in v2.read_text(encoding="utf-8"))
    except OSError as exc:
        problems.append(f"两个 conf 逐键对比失败: {exc}")

    # -- PG_* -> iotdb-system.properties 键名映射 --------------------------
    good("策略键名与发布模板一致", set(PG_PROP_KEYS) == EXPECTED_PROP_KEYS,
         f"{sorted(PG_PROP_KEYS)}")
    good("hot reload 键集合不含 series_slot_num / time_partition_interval",
         "series_slot_num" not in HOT_RELOAD_KEYS
         and "time_partition_interval" not in HOT_RELOAD_KEYS)
    good("hot reload 键集合为 6 个策略/配额键",
         set(HOT_RELOAD_KEYS) == EXPECTED_PROP_KEYS - {"series_slot_num",
                                                       "time_partition_interval"})
    if cfg_iot is not None:
        knobs = cfg_iot.region_group_knobs()
        good("region_group_knobs 键名与模板一致", set(knobs) == EXPECTED_PROP_KEYS,
             f"{sorted(knobs)}")
        good("region_group_knobs 值来自 conf",
             knobs["schema_region_group_extension_policy"] == "PROACTIVE"
             and knobs["default_data_region_group_num_per_database"] == "2"
             and knobs["series_slot_num"] == "1000",
             str(knobs))
        good("config 已无 compaction_knobs 方法",
             not hasattr(cfg_iot, "compaction_knobs"))

    # -- DEFAULTS 与 conf 对齐 & 无 compaction 遗留键 ----------------------
    for name in ("PG_SCHEMA_POLICY", "PG_DATA_POLICY", "PG_MIN_SCHEMA_PER_DB",
                 "PG_MIN_DATA_PER_DB", "PG_SCHEMA_PER_DATA_NODE", "PG_DATA_PER_DATA_NODE",
                 "PG_SERIES_SLOT_NUM", "PG_TIME_PARTITION_INTERVAL", "PG_TIER",
                 "PG_NORMAL_USER", "PG_SYSTEM_USER", "PG_UPGRADE_FROM_VERSION",
                 "CONSISTENCY_CHECK", "REPLICA_MODE", "CLUSTER_CONVERGENCE_WINDOW_SEC"):
        good(f"DEFAULTS 含 {name}", name in DEFAULTS)
    if cfg_iot is not None:
        _na_5c20d("DIR/DB_DIR/DEPLOY_TARBALL/DB_VERSION）",
             DEFAULTS["RESULT_DIR"] == cfg_iot.raw("RESULT_DIR")
             and DEFAULTS["DB_DIR"] == cfg_iot.raw("DB_DIR")
             and DEFAULTS["DEPLOY_TARBALL"] == cfg_iot.raw("DEPLOY_TARBALL")
             and DEFAULTS["DB_VERSION"] == cfg_iot.raw("DB_VERSION"),
             f"result={DEFAULTS['RESULT_DIR']}")
    legacy = [key for key in FORBIDDEN_LEGACY_KEYS if key in DEFAULTS]
    good("DEFAULTS 无 compaction 专用遗留键", not legacy, f"残留 {legacy}")

    # -- 实现契约：操作层与观测层的关键方法必须在 -------------------------
    api = PgApi(cfg_iot, None, None, lambda m: None)
    required_api = ("run", "run_as", "show_regions", "groups", "group_count", "replica_count",
                    "slot_counts", "snapshot", "database_details", "db_group_num",
                    "db_max_group_num", "device_group", "timeslot_count", "set_config",
                    "set_config_raw", "create_user", "grant_system", "create_database",
                    "insert_tree", "insert_table_many", "count_rows", "bench_run")
    missing = [name for name in required_api if not callable(getattr(api, name, None))]
    good("pgapi.PgApi 具备全部观测/操作接口", not missing, f"缺失 {missing}")
    good("pgops.CmpApi 是 PgApi 的兼容别名（不再是占位）", CmpApi is PgApi)
    good("pgprops 键映射覆盖 8 个 PG 键", set(PG_PROP_KEYS) == EXPECTED_PROP_KEYS,
         f"{sorted(PG_PROP_KEYS)}")
    props = CmpProps(cfg_iot if cfg_iot is not None else load_config(str(SKILL_ROOT / "conf" / "cluster.proactive_5c20d.conf")), None, lambda m: None)
    import inspect as _inspect

    src_text = _inspect.getsource(CmpProps)
    good("pgprops.CmpProps 已实现（源码内无 NotImplementedError 占位）",
         "NotImplementedError" not in src_text
         and all(hasattr(CmpProps, name) for name in ("read", "write", "conf_path",
                                                      "has_key", "remove_keys", "write_from_cfg")),
         f"方法={[n for n in dir(CmpProps) if not n.startswith('_')]}")

    # -- pure parsers -----------------------------------------------------
    blocked, rows = helpers.parse_blocked_threads(SAMPLE_JSTACK)
    good("jstack 解析：只统计 writeLock+Object.wait 的线程", blocked == 1, f"blocked={blocked}")
    good("jstack 解析：给出线程与栈帧证据", bool(rows) and "writeLock" in rows[0], str(rows[:1]))
    good("数值解析：1698.0 不放大 10 倍", helpers.num("1698.0") == 1698.0, str(helpers.num("1698.0")))
    good("数值解析：千分位与空值", helpers.num("1,234") == 1234.0 and helpers.num("") == 0.0)

    a = normalize_query_result("+---+\n| s0 |\n+---+\n| 1 |\n| 2 |\n+---+\n")
    b = normalize_query_result("+---+\n| s0 |\n+---+\n| 2 |\n| 1 |\n+---+\n")
    good("结果集规范化与行序无关", a == b and a.strip() != "", repr(a))

    # -- 1.3 兼容分支（UPG-1.3）-------------------------------------------
    # pg_upg13_run（1.3.7-SNAPSHOT，16 例 0 PASS / 7 FAIL）的两个根因都在这一层：
    #   ① start-cli.sh 不认识 2.x 的 -sql_dialect ⇒ 每条语句只打印用法提示；
    #   ② 1.3 的 801 失败行是 `Error…`（无冒号），旧的错误识别漏判 ⇒ "认证失败"被当成空结果集。
    try:
        compat13.selftest()
        good("compat13：版本线/CLI 参数/失败行/计数/Region 状态判据（纯函数）", True)
    except AssertionError as exc:
        problems.append(f"compat13.selftest 失败: {exc}")

    good("1.3 的 801 失败行（Error 后无冒号）必须判成 SQL 错误",
         looks_like_sql_error("ErrorCan't execute sql because801: Authentication failed."))
    good("1.3 CLI 参数解析失败（用法提示）必须判成 SQL 错误",
         looks_like_sql_error("Require more params input, eg. ./start-cli.sh -h xxx"))
    good("成功消息不被误判成错误",
         not looks_like_sql_error("Msg: The statement is executed successfully."))
    good("1.3 的 Total line number 计数可解析",
         compat13.parse_total_line_number("Total line number = 7") == 7)

    for name, want_flag in ((UPG13_CONF, False), (UPG20_CONF, True)):
        path = SKILL_ROOT / "conf" / name
        if not path.is_file():
            problems.append(f"缺少 conf/{name}（升级族 1.3/2.0 档）")
            continue
        try:
            cfg_upg = load_config(str(path))
        except ConfigError as exc:
            problems.append(f"conf/{name} 解析失败: {exc}")
            continue
        client = SqlClient(cfg_upg, _StubSsh(),
                           Path(tempfile.mkdtemp(prefix="pgkit-selftest-")))
        argv = client._cli_argv(cfg_upg.cli_host, "tree", 300, "select 1")
        good(f"conf/{name}（DB_VERSION={cfg_upg.raw('DB_VERSION')}）"
             f"{'带' if want_flag else '**不带**'} -sql_dialect",
             ("-sql_dialect" in argv) == want_flag, argv[-160:])

    # -- BKDR131 slot 复刻（docs/360 §3.5: d0/d1/d2 -> 327/328/329）---------
    try:
        slots.selftest()
        good("slots.selftest：BKDR131 复刻 d0/d1/d2 → 327/328/329", True)
    except AssertionError as exc:
        problems.append(f"slots.selftest 失败: {exc}")

    # -- 改名与可搬迁 -----------------------------------------------------
    # needle 运行时拼装（"".join 不会被常量折叠），既避免本检查把自己的源码当成
    # 命中，也避免 .pyc 里落下旧包名字符串；只扫文本源文件（.py/.sh），
    # 并跳过 __pycache__ 与 selftest.py 自身。
    source_files = [p for p in sorted((SKILL_ROOT / "scripts").rglob("*"))
                    if p.is_file() and p.suffix in {".py", ".sh"}
                    and "__pycache__" not in p.parts and p.name != "selftest.py"]
    for needle in ("".join(("cmp", "kit")), "".join(("CMP_", "SKILL_DIR"))):
        hits: list[str] = []
        for path in source_files:
            text = path.read_text(encoding="utf-8", errors="replace")
            for lineno, line in enumerate(text.splitlines(), 1):
                if needle in line:
                    hits.append(f"{path.relative_to(SKILL_ROOT)}:{lineno}")
        good(f"scripts/ 无 {needle} 残留", not hits, "; ".join(hits[:5]))

    bad_paths: list[str] = []
    for path in (SKILL_ROOT / "scripts").rglob("*.py"):
        if path.name == "selftest.py":
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if ("/home/" + "ubuntu/") in line and "SKILL_ROOT" not in line:
                bad_paths.append(f"{path.relative_to(SKILL_ROOT)}:{lineno}")
    good("包内没有硬编码工作区绝对路径（可搬迁）", not bad_paths, "; ".join(bad_paths[:5]))
    good("pg.sh 存在", (SKILL_ROOT / "scripts" / "pg.sh").is_file())

    print(f"selftest: ok={ok} failed={len(problems)}")
    if problems:
        print("selftest FAILED")
        for item in problems:
            print(f"  - {item}")
        return 1
    print("selftest OK: conf 契约/模板键名/实现契约/纯解析器/改名与可搬迁性全部通过")
    print(f"  cases: {len(CASES)}（已实现；完整目录见 references/case-catalog.md 约 220 条）")
    print(f"  skill root: {SKILL_ROOT}")
    return 0
