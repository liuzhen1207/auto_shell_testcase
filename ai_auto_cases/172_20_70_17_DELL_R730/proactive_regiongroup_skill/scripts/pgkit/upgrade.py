"""1.3 → 2.0 就地升级（in-place upgrade）：一条命令跑完两阶段。

阶段由 conf 键 ``PG_UPG_PHASE`` 控制（同一份 1.3 档 conf 可用三档）：

* ``pre``  —— 只跑**阶段 A**：把 ``PG_UPGRADE_FROM_TARBALL``（1.3.7 包，缺省回退
  ``DEPLOY_TARBALL``）部署到 ``DB_DIR``，激活 licence，写 1.3 确实存在的 conf 键，
  启动并等就绪；写 ``upgrade_pre.json`` 后**停下**。留给 PG-UPG-01..07 在 1.3 上跑基线。
* ``post`` —— 只跑**阶段 B**：``stop_all()`` → 确认 java 进程为 0 → 把
  ``PG_UPGRADE_TO_TARBALL``（2.0.11 包）**就地覆盖**到同一 ``DB_DIR``（保留 ``data/``
  与 ``conf/`` 的原有键）→ 启动 → 等就绪；写 ``upgrade_post.json``。之后跑 PG-UPG-08..16。
* 空 —— 一次跑完 A+B（不留给 pre 用例的窗口）。

为什么不用 ``Deployer.configure()``：``cluster.configure()`` 会写
``BASE_CN_PROPS``/``BASE_DN_PROPS``，里面含 ``*_region_group_extension_policy=CUSTOM``
与 ``default_data_region_group_num_per_database=5``。升级族的全部意义就是"**同一份
conf**（不含策略键）在 1.3 下是 AUTO、在 2.0 下默认变成 PROACTIVE"，所以 1.3 阶段
绝不能写 2.0 才认识的取值，也不能写死最小组数。做法：读**包内 template** 的键集合做
白名单过滤，只写模板里确实存在的键（实测依据：1.3.7 包 template :699/:723 默认 AUTO
且注释只列 CUSTOM/AUTO；:244 有 dn_multi_dir_strategy、:230 有 dn_data_dirs，
所以"哪些键是 2.0 才有"不能靠举例，必须按模板判定）。

就地覆盖的做法（``overlay_package``）：
  1. 解包新包到 ``<DEPLOY_DIR>/.upg_stage``（**不动** ``DB_DIR``）；
  2. 备份 ``DB_DIR/conf/iotdb-system.properties``（1.3 时代写下的键，是本次升级的
     被测对象，绝不能被新包的出厂文件覆盖）；
  3. 删掉旧版本残留、且新包不再提供的顶层目录（避免 1.3 的 jar 留在 lib/ 里污染
     classpath —— 1.3 的 lib/ 有 ~200 个 jar，2.0 的只有 2 个）；
  4. 逐项铺新包：``data/`` 跳过；``conf/`` 合并后**还原**第 2 步的生效文件；其余目录
     整体替换；最后恢复 sbin 的可执行位。

证据：``upgrade_pre.json`` / ``upgrade_post.json`` 同时写到本轮 run_dir 与
``<RESULT_DIR>/pg_upgrade/``（稳定副本，供另一个 run_dir 里的用例读取）。

失败一律抛 ``DeployError``，``cmd_upgrade`` 返回非 0。回滚点见 ``rollback_note``：
就地升级不可逆，"回到 1.3" 的唯一路径是用阶段 A 的包重跑 ``pg.sh deploy --clean``
（``DB_DIR`` 与包路径都在 conf 里，无需额外信息）。
"""

from __future__ import annotations

import json
import re
import shlex
import tarfile
import time
import zipfile
from pathlib import Path

from .deploy import Deployer, DeployError, consensus_class, resolve_license_code
from .pgapi import PgApi

#: 升级前后写出的证据文件名（同时写 run_dir 与 <RESULT_DIR>/pg_upgrade/ 稳定副本）
EVIDENCE_PRE = "upgrade_pre.json"
EVIDENCE_POST = "upgrade_post.json"
EVIDENCE_DIRNAME = "pg_upgrade"

#: 就地覆盖时**绝不**替换的顶层目录（数据、licence）。两个包里都有一个空的
#: ``activation/`` 目录，它是集群激活后写 ``license`` 的地方：整目录替换会把
#: licence 删掉，2.0 会以 ReadOnly(UNACTIVATED) 起来，永远等不到 healthy。
PRESERVE_TOP_LEVEL = ("data", "activation")

#: 就地覆盖时**绝不删除**的顶层目录（数据、配置、licence、日志）
KEEP_TOP_LEVEL = ("data", "conf", "activation", "logs")

#: conf 键集合里必须存在的"策略键"（判定 1.3 AUTO / 2.0 PROACTIVE 的那两个键）
POLICY_KEYNAMES = ("schema_region_group_extension_policy",
                   "data_region_group_extension_policy")

#: 1.3 的策略键合法取值（1.3.7 包 template :695-699 / :717-723 只列 CUSTOM/AUTO）。
#: 写成 PROACTIVE 会让 1.3 启动时校验失败，因此阶段 A 只接受这两个值，其余一律不写。
POLICY_VALUES_V13 = ("AUTO", "CUSTOM")

_PROP_LINE = re.compile(r"^\s*#?\s*([A-Za-z0-9_.]+)\s*=")
_VERSION_RE = re.compile(r"\b(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z._-]+)?)")


class UpgradeError(DeployError):
    """升级过程中某一步不满足前置条件。"""


def _cfg(cfg, key: str, default: str = "") -> str:
    """``cfg.raw`` 的薄封装：新键可能不在 ``DEFAULTS`` 里（本任务不允许改 config.py）。"""
    return (cfg.raw(key, default) or "").strip()


def q(text: str) -> str:
    return shlex.quote(text)


# --------------------------------------------------------------------- 包的解析
def from_tarball(cfg) -> str:
    """阶段 A 的包（1.3）：优先 ``PG_UPGRADE_FROM_TARBALL``，回退 ``DEPLOY_TARBALL``。"""
    spec = _cfg(cfg, "PG_UPGRADE_FROM_TARBALL") or _cfg(cfg, "DEPLOY_TARBALL")
    if not spec:
        raise UpgradeError("PG_UPGRADE_FROM_TARBALL 与 DEPLOY_TARBALL 都为空，无法部署 1.3")
    return spec


def to_tarball(cfg) -> str:
    """阶段 B 的包（2.0）：``PG_UPGRADE_TO_TARBALL``。

    刻意**不**回退到 ``DEPLOY_TARBALL``：阶段 A 的包已经占用了那个键，静默回退会变成
    "1.3 覆盖 1.3"的假升级（用例仍会 PASS，因为版本号断言读的是包名）。宁可在这里
    明确报错，也不允许一次没有目标包的升级。
    """
    spec = _cfg(cfg, "PG_UPGRADE_TO_TARBALL")
    if not spec:
        raise UpgradeError(
            "PG_UPGRADE_TO_TARBALL 为空：请在升级档 conf 里指向 2.0 包，例如\n"
            "  PG_UPGRADE_TO_TARBALL=/data/deepseek/timecho_src/master/timechodb/"
            "distribution/target/timechodb-2.0.11-SNAPSHOT-bin.zip"
        )
    return spec


def to_version(cfg) -> str:
    return _cfg(cfg, "PG_UPGRADE_TO_VERSION", "2.0") or "2.0"


def from_version(cfg) -> str:
    return _cfg(cfg, "PG_UPGRADE_FROM_VERSION", "1.3") or "1.3"


def _template_keys_from_zip(path: Path) -> set[str]:
    keys: set[str] = set()
    with zipfile.ZipFile(path) as archive:
        member = next((n for n in archive.namelist()
                       if n.endswith("conf/iotdb-system.properties.template")), "")
        if not member:
            return keys
        text = archive.read(member).decode("utf-8", errors="replace")
    for line in text.splitlines():
        match = _PROP_LINE.match(line)
        if match:
            keys.add(match.group(1))
    return keys


def _template_keys_from_tar(path: Path) -> set[str]:
    keys: set[str] = set()
    with tarfile.open(path, "r:*") as archive:
        member = next((m for m in archive.getmembers()
                       if m.name.endswith("conf/iotdb-system.properties.template")), None)
        if member is None:
            return keys
        handle = archive.extractfile(member)
        text = (handle.read() if handle else b"").decode("utf-8", errors="replace")
    for line in text.splitlines():
        match = _PROP_LINE.match(line)
        if match:
            keys.add(match.group(1))
    return keys


def template_keys(tarball: str, *, ssh=None, host: str = "",
                  db_dir: str = "") -> tuple[set[str], str]:
    """包内 ``conf/iotdb-system.properties.template`` 出现的键集合（含被注释的键）。

    优先直接读本地包（离线、确定）；本地读不到（包只存在于远端）时回退到远端 grep
    ``DB_DIR/conf/iotdb-system.properties.template``。
    """
    local = Path(tarball)
    if local.is_file():
        for loader in (_template_keys_from_zip, _template_keys_from_tar):
            try:
                keys = loader(local)
            except (zipfile.BadZipFile, tarfile.TarError, OSError):
                continue
            if keys:
                return keys, f"本地包 {local.name}"
    if ssh is not None and host and db_dir:
        res = ssh.run(
            host,
            f"grep -hoE '^[[:space:]]*#?[[:space:]]*[A-Za-z0-9_.]+[[:space:]]*=' "
            f"{q(db_dir)}/conf/iotdb-system.properties.template 2>/dev/null "
            f"| tr -d ' #\\t='",
            check=False,
        )
        keys = {token.strip() for token in res.out.split() if token.strip()}
        if keys:
            return keys, f"远端 {host}:{db_dir}/conf/iotdb-system.properties.template"
    raise UpgradeError(
        f"读不到包内模板的键集合（{tarball}）：既不是本地可读的 zip/tar，"
        f"远端 {host}:{db_dir}/conf/iotdb-system.properties.template 也不存在"
    )


# ------------------------------------------------------------------ conf 键构造
def _mapping_for(cfg, host: str, role: str) -> dict[str, str]:
    seed = cfg.seed_cn_endpoint
    values: dict[str, str] = {
        "cluster_name": cfg.raw("CLUSTER_NAME", "defaultCluster") or "defaultCluster",
        "schema_replication_factor": str(cfg.get_int("SCHEMA_REPLICATION_FACTOR")),
        "data_replication_factor": str(cfg.get_int("DATA_REPLICATION_FACTOR")),
        "default_schema_region_group_num_per_database":
            cfg.raw("PG_MIN_SCHEMA_PER_DB") or "1",
        "default_data_region_group_num_per_database":
            cfg.raw("PG_MIN_DATA_PER_DB") or "2",
        "schema_region_per_data_node": cfg.raw("PG_SCHEMA_PER_DATA_NODE") or "1",
        "data_region_per_data_node": cfg.raw("PG_DATA_PER_DATA_NODE") or "0",
        "series_slot_num": cfg.raw("PG_SERIES_SLOT_NUM") or "1000",
        "time_partition_interval": cfg.raw("PG_TIME_PARTITION_INTERVAL") or "604800000",
        "data_region_consensus_protocol_class":
            consensus_class(cfg.raw("DEPLOY_CONSENSUS") or "IoTConsensus"),
        "enable_auto_repair_compaction": "false",
    }
    if role == "cn":
        values.update({
            "cn_seed_config_node": seed,
            "cn_internal_address": host,
            "cn_internal_port": str(cfg.cn_internal_port),
            "cn_metric_reporter_list": "PROMETHEUS",
            "cn_metric_level": "IMPORTANT",
            "cn_metric_prometheus_reporter_port": "9091",
        })
    else:
        values.update({
            "dn_seed_config_node": seed,
            "dn_internal_address": host,
            "dn_internal_port": str(cfg.dn_internal_port),
            "dn_rpc_address": host,
            "dn_rpc_port": str(cfg.dn_rpc_port),
            "dn_metric_reporter_list": "PROMETHEUS",
            "dn_metric_level": "IMPORTANT",
            "dn_metric_prometheus_reporter_port": "9092",
        })
    if cfg.two_disk:
        values["dn_data_dirs"] = ",".join(cfg.data_dirs)
        strategy = cfg.raw("DB_MULTI_DIR_STRATEGY")
        if strategy:
            values["dn_multi_dir_strategy"] = strategy
    return values


def policy_keys_for_phase_a(cfg, available: set[str], log) -> dict[str, str]:
    """1.3 阶段要不要**显式**写策略键。两种子情形由此档位决定：

    * ``PG_OMIT_POLICY_KEYS=true`` 或 ``PG_{SCHEMA,DATA}_POLICY`` 为空/PROACTIVE
      ⇒ 不写 ⇒ 升级到 2.0 后走**代码默认值 PROACTIVE**（核心断言 PG-UPG-09）。
    * ``PG_{SCHEMA,DATA}_POLICY=AUTO``（1.3 合法取值）⇒ 显式写 AUTO
      ⇒ 升级到 2.0 后**保持 AUTO**（独立性断言，同一用例的另一分支）。
    """
    omit = (cfg.raw("PG_OMIT_POLICY_KEYS") or "").strip().lower() in ("1", "true", "yes")
    out: dict[str, str] = {}
    for key, conf_key in (("schema_region_group_extension_policy", "PG_SCHEMA_POLICY"),
                          ("data_region_group_extension_policy", "PG_DATA_POLICY")):
        value = (cfg.raw(conf_key) or "").strip()
        if key not in available:
            log(f"  [1.3 conf] {key} 不在 1.3 模板里 ⇒ 跳过（该键在 1.3 不存在）")
            continue
        if omit or not value:
            log(f"  [1.3 conf] {key} 不写（PG_OMIT_POLICY_KEYS={omit}、值={value or '空'}）"
                f" ⇒ 1.3 走默认 AUTO、2.0 走默认 PROACTIVE")
            continue
        if value.upper() not in POLICY_VALUES_V13:
            log(f"  [1.3 conf] {key}={value} 不是 1.3 合法取值 {POLICY_VALUES_V13} ⇒ 跳过"
                f"（不写，保持 1.3 默认 AUTO；避免 1.3 启动校验失败）")
            continue
        out[key] = value.upper()
        log(f"  [1.3 conf] {key}={value.upper()} 显式写入（升级到 2.0 后应保持不变）")
    return out


def upgrade_keys(cfg, host: str, role: str, available: set[str], *, phase: str,
                 log) -> tuple[dict[str, str], set[str]]:
    """该主机该角色要写的键（只保留 ``available`` 里有的键）。

    返回 ``(要写的键, 被模板过滤掉的键)``。策略键只在阶段 A 由
    ``policy_keys_for_phase_a`` 决定；阶段 B **不碰**策略键（否则会把 1.3 显式写的
    AUTO 覆盖成 PROACTIVE，毁掉独立性断言）。
    """
    wanted = dict(_mapping_for(cfg, host, role))
    if phase == "pre":
        wanted.update(policy_keys_for_phase_a(cfg, available, log))
    dropped = {k for k in wanted if k not in available}
    kept = {k: v for k, v in wanted.items() if k in available}
    return kept, dropped


# ------------------------------------------------------------------- 包的就位
def stage_tarball(cfg, ssh, log, spec: str) -> str:
    """把包就位到 ``DEPLOY_DIR`` 并返回远端路径。

    与 ``Deployer._remote_tarball`` 同源逻辑，但接受**任意** spec（那里写死读
    ``DEPLOY_TARBALL``，阶段 B 的目标包不是它）。
    """
    deploy_dir = cfg.get("DEPLOY_DIR")
    local = Path(spec)
    remote = f"{deploy_dir}/{local.name}"
    for host in cfg.all_hosts:
        ssh.run(host, f"mkdir -p {q(deploy_dir)}", check=False)
    if not local.is_file():
        probe = ssh.run(cfg.all_hosts[0], f"test -f {q(spec)}", check=False)
        if not probe.ok:
            raise UpgradeError(f"{spec} 既不是本地文件，也不在 {cfg.all_hosts[0]} 上")
        log(f"  包 {spec} 已在远端，直接使用")
        return spec
    size = local.stat().st_size
    for host in cfg.all_hosts:
        already = ssh.run(
            host,
            f"test -f {q(remote)} && [[ $(stat -c %s {q(remote)}) -eq {size} ]]",
            check=False,
        )
        if already.ok:
            log(f"  {host}: 包已就位（{size // 1048576} MiB），不重复上传")
            continue
        log(f"  {host}: 上传 {local.name}（{size // 1048576} MiB）")
        ssh.upload(local, host, remote)
    return remote


# ------------------------------------------------------------------- 就地覆盖
_JAVA_COUNT = (
    "ps -eo args --no-headers | awk -v d={db} '/[j]ava/ && index($0, d) {{c++}} "
    "END {{print c+0}}'"
)


def _foreign_java(ssh, host: str) -> list[str]:
    """列出该机上**别的** DB_DIR 的 IoTDB 进程（例如主集群）。

    端口只有 ``CN_INTERNAL_PORT`` / ``DN_INTERNAL_PORT`` / ``DN_RPC_PORT`` 是 conf 可配的，
    ``cn_consensus_port`` 10720、``dn_mpp_data_exchange_port`` 10740、
    schema/data region consensus 10750/10760、metrics 9091/9092 都是固定的：
    所以**升级集群和主集群不能同时跑在同一批机器上**（哪怕 DB_DIR 不同）。
    ``assert_stopped`` 按 DB_DIR 匹配进程，看不到主集群，这里必须另说一句。
    """
    res = ssh.run(
        host,
        "ps -eo args --no-headers 2>/dev/null | "
        "awk '/[j]ava/ && (index($0,\"ConfigNode\")||index($0,\"DataNode\"))' | head -3",
        check=False,
    )
    return [line.strip()[:160] for line in (res.out or "").splitlines() if line.strip()]


def _warn_foreign_java(cfg, ssh, log, db: str) -> None:
    for host in cfg.all_hosts:
        others = _foreign_java(ssh, host)
        if others:
            log(f"  WARN {host}: 还有 {len(others)} 个**其它 DB_DIR** 的 IoTDB 进程在跑，"
                f"它们会占用同样的端口（10720/10740/10750/10760/9091/9092 不可配），"
                f"1.3 会起不来。升级前请先 `pg.sh --conf <主集群档> teardown`。"
                f"样例：{others[0]}")


def assert_stopped(cfg, ssh, log, *, tries: int = 30) -> None:
    """确认每台机器上引用 ``DB_DIR`` 的 java 进程为 0；否则抛 ``UpgradeError``。

    就地覆盖前必须真的停干净：``.iotdb-lock`` / 端口仍被持有会让 2.0 起不来
    （deploy.py 的 unpack 里记录了同类实测故障）。
    """
    db = cfg.get("DB_DIR")
    script = f"set -e\n{_JAVA_COUNT.format(db=q(db))}\nexit 0\n"
    counts: dict[str, int] = {}
    for attempt in range(1, tries + 1):
        counts = {}
        for host in cfg.all_hosts:
            res = ssh.run_script(host, script, check=False)
            text = (res.out or "").strip().splitlines()
            try:
                counts[host] = int(text[-1]) if text else -1
            except ValueError:
                counts[host] = -1
        if all(value == 0 for value in counts.values()):
            log(f"  已确认 {len(counts)} 台机器上引用 {db} 的 java 进程为 0"
                f"（第 {attempt} 次探测）")
            _warn_foreign_java(cfg, ssh, log, db)
            return
        if attempt in (1, tries):
            log(f"  仍有 java 进程持有 {db}：{counts}（第 {attempt}/{tries} 次），等待")
        time.sleep(2)
    raise UpgradeError(
        f"就地覆盖前仍有 java 进程持有 {db}：{counts}；拒绝继续"
        f"（否则 2.0 会因目录锁/端口占用起不来）。"
        f"本检查在**任何写操作之前**执行，手动 kill 掉这些 PID 后重跑 "
        f"`pg.sh --conf <post档> upgrade` 是安全的（不会重复覆盖）。"
    )


def overlay_script(cfg, tarball: str) -> str:
    """把新包铺进 ``DB_DIR`` 的远端脚本（可单测：不依赖远端也能构造出来）。"""
    db_dir = cfg.get("DB_DIR")
    parent = cfg.get("DEPLOY_DIR")
    stage = f"{parent}/.upg_stage"
    keep = " ".join(KEEP_TOP_LEVEL)
    return f"""
set -e
d={q(db_dir)}
stage={q(stage)}
archive={q(tarball)}
rm -rf "$stage"
mkdir -p "$stage"
case "$archive" in
  *.zip) unzip -q -o "$archive" -d "$stage" ;;
  *.tar.gz|*.tgz) tar -xzf "$archive" -C "$stage" ;;
  *.tar) tar -xf "$archive" -C "$stage" ;;
  *) echo "unsupported archive: $archive" >&2; exit 2 ;;
esac
inner=$(ls -A "$stage")
count=$(echo "$inner" | wc -l)
if [[ "$count" -ne 1 ]]; then
  echo "expected exactly one top-level directory in the archive, found $count" >&2
  exit 3
fi
new="$stage/$inner"
# 包自身的顶层条目（注意不是 $stage 的内容，那是"包目录"这一个条目）
entries=$(ls -A "$new")
echo "  new package top level: $inner -> $(echo $entries | tr '\\n' ' ')"
# 1) 备份 1.3 时代写下的生效配置（本次升级的被测对象，不能被新包出厂文件覆盖）
keep_conf="$stage/iotdb-system.properties.keep"
had_conf=0
if [[ -f "$d/conf/iotdb-system.properties" ]]; then
  cp -fp "$d/conf/iotdb-system.properties" "$keep_conf"
  had_conf=1
fi
# 2) 删掉旧版本残留、且新包不再提供的顶层目录（否则 1.3 的 jar 会留在 lib/ 污染 classpath）
for e in $(ls -A "$d" 2>/dev/null); do
  [[ -d "$d/$e" ]] || continue
  case " {keep} " in *" $e "*) continue ;; esac
  for n in $entries; do [[ "$e" == "$n" ]] && continue 2; done
  echo "  removing stale directory $d/$e (not provided by the new package)"
  sudo -n rm -rf "$d/$e" 2>/dev/null || rm -rf "$d/$e"
done
# 3) 逐项铺新包：data/ 与 activation/ 保留；conf/ 合并后还原生效配置；其余整体替换
for n in $entries; do
  case " {" ".join(PRESERVE_TOP_LEVEL)} " in *" $n "*)
    echo "  preserving $d/$n (payload / licence)"
    continue ;;
  esac
  if [[ "$n" == "conf" ]]; then
    sudo -n cp -af "$new/conf/." "$d/conf/" 2>/dev/null || cp -af "$new/conf/." "$d/conf/"
    if [[ "$had_conf" == "1" ]]; then
      cp -fp "$keep_conf" "$d/conf/iotdb-system.properties"
      echo "  merged conf/ (原有 iotdb-system.properties 已还原)"
    else
      echo "  merged conf/"
    fi
    continue
  fi
  sudo -n rm -rf "$d/$n" 2>/dev/null || rm -rf "$d/$n"
  sudo -n cp -af "$new/$n" "$d/$n" 2>/dev/null || cp -af "$new/$n" "$d/$n"
  echo "  replaced $d/$n"
done
rm -rf "$stage"
cd "$d" && (chmod +x sbin/*.sh 2>/dev/null || sudo -n chmod +x sbin/*.sh) || true
echo "  final top level: $(ls -A "$d" | tr '\\n' ' ')"
exit 0
"""


def overlay_package(cfg, ssh, log, tarball: str) -> None:
    """在每台主机上把新包就地铺进 ``DB_DIR``；任一台失败即抛 ``UpgradeError``。"""
    script = overlay_script(cfg, tarball)
    for host in cfg.all_hosts:
        log(f"  {host}: 就地覆盖 {cfg.get('DB_DIR')} ← {tarball}")
        res = ssh.run_script(host, script, check=False, timeout=3600)
        for line in (res.text or "").splitlines():
            if line.strip():
                log(f"    {host}| {line.strip()[:220]}")
        if res.rc != 0:
            raise UpgradeError(f"{host}: 就地覆盖失败（rc={res.rc}）：{(res.text or '').strip()[:400]}")
        log(f"  {host}: 就地覆盖完成")


# ------------------------------------------------------------------- 观测/证据
def _read_policy(cfg, cluster) -> tuple[str, dict[str, dict[str, str]]]:
    """读回每台主机**生效** conf 里的策略键，归纳成一个状态字符串。"""
    per_host: dict[str, dict[str, str]] = {}
    for host in cfg.all_hosts:
        try:
            props = cluster.read_system_properties(host)
        except Exception as exc:  # noqa: BLE001 - 读不到也要留证据
            per_host[host] = {"_error": str(exc)}
            continue
        per_host[host] = {k: props[k] for k in POLICY_KEYNAMES if k in props}
    values = {v for entry in per_host.values() for k, v in entry.items() if not k.startswith("_")}
    if not values:
        state = "absent"
    elif len(values) == 1:
        state = values.pop()
    else:
        state = "mixed:" + ",".join(sorted(values))
    return state, per_host


def observe(cfg, api, log) -> dict:
    """观测当前集群：版本号（SHOW CLUSTER 的 Version 列）+ 库/组数详情。"""
    out = api.run("show cluster")
    column = api.column(out.rows, "Version")
    versions: list[str] = []
    if column:
        versions = sorted({(row.get(column) or "").strip() for row in out.rows
                           if (row.get(column) or "").strip()})
    observed = versions[0] if versions else ""
    if not observed:
        match = _VERSION_RE.search(out.output or "")
        observed = match.group(1) if match else ""
    if len(versions) > 1:
        log(f"  WARN: SHOW CLUSTER 里出现多个版本号 {versions}（取第一个 {observed}）")
    details: dict[str, dict] = {}
    groups: dict[str, dict[str, int]] = {}
    for dialect in ("tree", "table"):
        try:
            details[dialect] = api.database_details(dialect)
        except Exception as exc:  # noqa: BLE001
            details[dialect] = {"_error": str(exc)}
    for db in details.get("tree", {}):
        if any(marker in db for marker in ("__system", "__audit", "information_schema")):
            continue
        groups[db] = {
            "schema": api.db_group_num(db, "SCHEMA", dialect="tree"),
            "schema_max": api.db_max_group_num(db, "SCHEMA", dialect="tree"),
            "data": api.db_group_num(db, "DATA", dialect="tree"),
            "data_max": api.db_max_group_num(db, "DATA", dialect="tree"),
        }
    summary = ", ".join(f"{db}: schema={v['schema']}/{v['schema_max']} "
                        f"data={v['data']}/{v['data_max']}"
                        for db, v in list(groups.items())[:6])
    log(f"  观测：版本={observed or '未知'}；树库 {len(groups)} 个"
        + (f"；{summary}" if summary else ""))
    return {
        "observed_version": observed,
        "show_cluster_ok": out.ok,
        "show_cluster_columns": list(out.rows[0].keys()) if out.rows else [],
        "show_cluster_raw": (out.output or "")[:4000],
        "databases_details": details,
        "tree_groups": groups,
    }


def rollback_note(cfg, source: str) -> dict:
    """失败/回滚点：就地升级不可逆，回到 1.3 的唯一办法是重跑阶段 A 的部署。"""
    return {
        "irreversible": True,
        "db_dir": cfg.get("DB_DIR"),
        "from_tarball": source,
        "to_tarball": _cfg(cfg, "PG_UPGRADE_TO_TARBALL"),
        "how_to_rollback": (
            f"用 1.3 档 conf 重跑：bash scripts/pg.sh --conf <1.3档conf> deploy --clean "
            f"（会重建 {cfg.get('DB_DIR')}，1.3 的数据全部丢失；升级前的数据只在 "
            f"{cfg.get('DB_DIR')}/data 里。若需要保留，必须在阶段 B 之前自行备份该目录）"
        ),
        "phase_b_entry_steps": [
            "cluster.stop_all()",
            "assert_stopped()（引用 DB_DIR 的 java 进程必须为 0）",
            "overlay_package()（就地覆盖；data/ 与 conf/iotdb-system.properties 保留）",
            "重新落盘 env(heap) 与 2.0 需要的 conf 键",
            "Deployer.start() 起 2.0 并等就绪",
        ],
    }


def _evidence_dirs(cfg, run_dir: Path) -> list[Path]:
    dirs = [Path(run_dir)]
    try:
        stable = Path(cfg.result_dir) / EVIDENCE_DIRNAME
        stable.mkdir(parents=True, exist_ok=True)
        dirs.append(stable)
    except OSError:
        pass
    return dirs


def write_evidence(cfg, run_dir: Path, name: str, payload: dict, log) -> list[str]:
    """写证据文件：本轮 run_dir + ``<RESULT_DIR>/pg_upgrade/`` 稳定副本。"""
    text = json.dumps(payload, ensure_ascii=False, indent=2)
    written: list[str] = []
    for directory in _evidence_dirs(cfg, run_dir):
        try:
            directory.mkdir(parents=True, exist_ok=True)
            (directory / name).write_text(text, encoding="utf-8")
            written.append(str(directory / name))
        except OSError as exc:
            log(f"  WARN: 写 {directory / name} 失败：{exc}")
    if written:
        log(f"  证据已写出：{written}")
    return written


def _latest_pointer(cfg, run_dir: Path, log) -> None:
    try:
        stable = Path(cfg.result_dir) / EVIDENCE_DIRNAME
        stable.mkdir(parents=True, exist_ok=True)
        pointer = stable / "latest.json"
        pointer.write_text(json.dumps({
            "run_dir": str(run_dir),
            "conf": str(cfg.path),
            "phase": _cfg(cfg, "PG_UPG_PHASE") or "both",
            "updated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        }, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError as exc:
        log(f"  WARN: 写 latest.json 失败：{exc}")


# ------------------------------------------------------------------- 阶段 A/B
def _roles_of(cfg, host: str) -> list[str]:
    roles = []
    if host in cfg.cn_hosts:
        roles.append("cn")
    if host in cfg.dn_hosts:
        roles.append("dn")
    return roles


def _write_conf(cfg, cluster, log, available: set[str], *, phase: str) -> dict:
    """把该阶段要写的键与环境变量落盘；返回 ``{host: [keys]}``。"""
    written: dict[str, list[str]] = {}
    dropped_all: set[str] = set()
    for host in cfg.all_hosts:
        merged: dict[str, str] = {}
        for role in _roles_of(cfg, host):
            kept, dropped = upgrade_keys(cfg, host, role, available, phase=phase, log=log)
            merged.update(kept)
            dropped_all |= dropped
        cluster.apply_system_properties(host, merged)
        if host in cfg.cn_hosts:
            cluster.apply_env(host, "cn", cfg.get("CN_HEAP"), cfg.get("CN_OFF_HEAP"))
        if host in cfg.dn_hosts:
            cluster.apply_env(host, "dn", cfg.get("DN_HEAP"), cfg.get("DN_OFF_HEAP"))
        written[host] = sorted(merged)
        log(f"  {host}: 写入 {len(merged)} 个键（{phase} 阶段）")
    if dropped_all:
        log(f"  被模板过滤掉的键（该阶段包内模板里不存在）：{sorted(dropped_all)}")
    common = sorted({k for keys in written.values() for k in keys})
    log(f"  {phase} 阶段写入键集合（{len(common)}）：{common}")
    return written


def wait_sql_ready(cfg, sql, log, timeout: int = 420) -> bool:
    """等 ``show cluster`` 能答（与 ``cli.wait_ready`` 同口径，避免反向 import cli）。"""
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        out = sql.sql(cfg.cli_host, "show cluster", check=False, timeout=60)
        if "|" in out and "error" not in out.lower():
            return True
        last = " ".join(out.split())[:160]
        time.sleep(10)
    log(f"  集群在 {timeout}s 内未回答 show cluster（最后回复：{last}）")
    return False


def _activate_code(cfg) -> str:
    if not cfg.get_bool("DEPLOY_ACTIVATE"):
        return ""
    code_file = cfg.raw("LICENSE_CODE_FILE")
    return resolve_license_code(cfg.raw("LICENSE_CODE"),
                                code_file=str(cfg.resolve(code_file)) if code_file else "")


def phase_a(cfg, cluster, deployer: Deployer, ssh, sql, log, run_dir) -> dict:
    """阶段 A：把 1.3 部署到 ``DB_DIR``、写 1.3 键、启动、写 ``upgrade_pre.json``。"""
    api = PgApi(cfg, sql, ssh, log)
    source = from_tarball(cfg)
    log(f"== 阶段 A（1.3）：{source}")
    available, origin = template_keys(source, ssh=ssh, host=cfg.all_hosts[0],
                                     db_dir=cfg.get("DB_DIR"))
    log(f"  1.3 模板键集合 {len(available)} 个（来源：{origin}）")

    original = cfg.values.get("DEPLOY_TARBALL", "")
    swapped = source != original
    if swapped:
        log(f"  临时把 DEPLOY_TARBALL 指向 1.3 包（原值 {original or '空'}），"
            f"仅本阶段有效")
        cfg.values["DEPLOY_TARBALL"] = source
    try:
        log(f"  解包 1.3 到 {cfg.get('DB_DIR')}（clean=True：先停旧进程并重建目录）")
        deployer.unpack(clean=True)
        written = _write_conf(cfg, cluster, log, available, phase="pre")
        code = _activate_code(cfg)
        log("  启动 1.3 集群（seed CN 先起，再 CN/DN，最后等 healthy + 激活）")
        if not deployer.start(activate_code=code):
            raise UpgradeError("阶段 A：1.3 集群未在超时内就绪")
        if not wait_sql_ready(cfg, sql, log):
            raise UpgradeError("阶段 A：集群起来了但 SQL 不应答")
    finally:
        if swapped:
            cfg.values["DEPLOY_TARBALL"] = original

    state, per_host = _read_policy(cfg, cluster)
    observation = observe(cfg, api, log)
    payload = {
        "phase": "pre",
        "from_version": from_version(cfg),
        "from_tarball": source,
        "to_version": to_version(cfg),
        "to_tarball": _cfg(cfg, "PG_UPGRADE_TO_TARBALL"),
        "db_dir": cfg.get("DB_DIR"),
        "hosts": cfg.all_hosts,
        "policy_state": state,
        "policy_keys": per_host,
        "template_key_count": len(available),
        "template_key_source": origin,
        "conf_keys_written": written,
        "observation": observation,
        "rollback": rollback_note(cfg, source),
        "written_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    log(f"  1.3 策略键读回状态：{state}（期望 absent 或 AUTO；PROACTIVE 在 1.3 不存在）")
    log(f"  1.3 观测版本号：{observation['observed_version'] or '未知'}")
    write_evidence(cfg, run_dir, EVIDENCE_PRE, payload, log)
    _latest_pointer(cfg, run_dir, log)
    return payload


def phase_b(cfg, cluster, deployer: Deployer, ssh, sql, log, run_dir) -> dict:
    """阶段 B：停集群 → 就地覆盖 2.0 → 起集群 → 写 ``upgrade_post.json``。"""
    api = PgApi(cfg, sql, ssh, log)
    target = to_tarball(cfg)
    source = from_tarball(cfg)
    if Path(target).name == Path(source).name:
        raise UpgradeError(
            f"阶段 B 的目标包与阶段 A 的包同名（{Path(target).name}）：这会是假升级。"
            f"请把 PG_UPGRADE_TO_TARBALL 指向 2.0 包"
        )
    if not Path(cfg.get("DB_DIR")).is_absolute():
        raise UpgradeError(f"DB_DIR 必须是绝对路径：{cfg.get('DB_DIR')!r}")
    log(f"== 阶段 B（2.0 就地升级）：{target}")
    available, origin = template_keys(target, ssh=ssh, host=cfg.all_hosts[0],
                                     db_dir=cfg.get("DB_DIR"))
    log(f"  2.0 模板键集合 {len(available)} 个（来源：{origin}）")
    log("  回滚点：就地升级不可逆；" + rollback_note(cfg, source)["how_to_rollback"])

    log("  1) 停止全部节点")
    cluster.stop_all()
    log("  2) 确认没有 java 进程还持有 DB_DIR")
    assert_stopped(cfg, ssh, log)
    log("  3) 目标包就位")
    remote = stage_tarball(cfg, ssh, log, target)
    log("  4) 就地覆盖（data/ 保留；conf/ 合并后还原原有生效文件）")
    overlay_package(cfg, ssh, log, remote)
    log("  5) 重新落盘 env(heap) 与 2.0 需要的 conf 键（不碰策略键）")
    written = _write_conf(cfg, cluster, log, available, phase="post")
    code = _activate_code(cfg)
    log("  6) 启动 2.0 集群并等就绪")
    if not deployer.start(activate_code=code):
        raise UpgradeError("阶段 B：2.0 集群未在超时内就绪（就地升级可能不兼容该数据目录）")
    if not wait_sql_ready(cfg, sql, log):
        raise UpgradeError("阶段 B：2.0 集群起来了但 SQL 不应答")

    state, per_host = _read_policy(cfg, cluster)
    observation = observe(cfg, api, log)
    payload = {
        "phase": "post",
        "from_version": from_version(cfg),
        "from_tarball": source,
        "to_version": to_version(cfg),
        "to_tarball": target,
        "db_dir": cfg.get("DB_DIR"),
        "hosts": cfg.all_hosts,
        "policy_state": state,
        "policy_keys": per_host,
        "template_key_count": len(available),
        "template_key_source": origin,
        "conf_keys_written": written,
        "observation": observation,
        "rollback": rollback_note(cfg, source),
        "written_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    log(f"  2.0 策略键读回状态：{state}（无键 ⇒ 代码默认 PROACTIVE；AUTO ⇒ 保持 AUTO）")
    log(f"  2.0 观测版本号：{observation['observed_version'] or '未知'}")
    write_evidence(cfg, run_dir, EVIDENCE_POST, payload, log)
    _latest_pointer(cfg, run_dir, log)
    return payload


# ---------------------------------------------------------------------- 入口
def run_upgrade(cfg, cluster, deployer: Deployer, ssh, sql, log, run_dir) -> bool:
    """按 ``PG_UPG_PHASE`` 跑阶段 A / B / A+B；成功返回 True。"""
    phase = (cfg.raw("PG_UPG_PHASE") or "").strip().lower()
    if phase not in ("", "pre", "post"):
        raise UpgradeError(f"PG_UPG_PHASE={phase!r} 非法：只能是 pre / post / 空")
    log(f"升级：DB_DIR={cfg.get('DB_DIR')}；PG_UPG_PHASE={phase or '（空：一次跑完 A+B）'}")
    log(f"  1.3 包（阶段 A）：{from_tarball(cfg)}")
    if phase in ("", "post"):
        log(f"  2.0 包（阶段 B）：{to_tarball(cfg)}")
    for spec in ([from_tarball(cfg)] + ([to_tarball(cfg)] if phase in ("", "post") else [])):
        local = Path(spec)
        if not local.is_file():
            probe = ssh.run(cfg.all_hosts[0], f"test -f {q(spec)}", check=False)
            if not probe.ok:
                raise UpgradeError(f"预检失败：{spec} 既不在本地，也不在 {cfg.all_hosts[0]} 上")
    if phase in ("", "pre"):
        phase_a(cfg, cluster, deployer, ssh, sql, log, run_dir)
        if phase == "pre":
            log("阶段 A 完成：PG_UPG_PHASE=pre ⇒ 停在 1.3，"
                "供 PG-UPG-01..07 跑升级前基线；随后用 PG_UPG_PHASE=post 档跑 upgrade 做就地升级")
            return True
    if phase in ("", "post"):
        phase_b(cfg, cluster, deployer, ssh, sql, log, run_dir)
    log("升级流程完成")
    return True
