"""PROACTIVE 策略/配额在 ``iotdb-system.properties`` 上的读写。

与 ``Cluster.apply_system_properties``（``cluster.py:287-316``）同源实现：同一份
sed/tee 脚本形态、同样的 ``sudo -n`` 回退，因此 ``deploy``/``prepare`` 与本模块
写出来的文件完全一致（避免"两套写法"导致读回不一致）。

键名与默认值以**发布包模板**为准（``references/proactive-knobs.md`` §1）：
``schema_region_group_extension_policy``（:848，默认 PROACTIVE，热加载）、
``default_schema_region_group_num_per_database``（:858，1）、
``schema_region_per_data_node``（:866，1）、
``data_region_group_extension_policy``（:891，PROACTIVE）、
``default_data_region_group_num_per_database``（:901，2）、
``data_region_per_data_node``（:910，0）、
``series_slot_num``（:814，1000，**首次启动确定**）、
``time_partition_interval``（:968）。
"""

from __future__ import annotations

import re
import shlex

#: 生效文件名是 ``conf/iotdb-system.properties``（1.x 的 iotdb-common.properties 不再随包发布）
#: UPG-1.3: 1.3 布局可能不同 —— 1.2 及更早是 ``conf/iotdb-engine.properties``，
#: 1.3.0~1.3.7 企业包同时带 ``iotdb-system.properties``。这里**按顺序探测真实存在的文件名**
#: 再读/写，绝不猜；探测结果由 :meth:`CmpProps.conf_path` 缓存并在证据里回报。
CANDIDATE_FILES: tuple[str, ...] = (
    "conf/iotdb-system.properties",
    "conf/iotdb-common.properties",
    "conf/iotdb-engine.properties",
)

_ACTIVE_PROP = re.compile(r"^\s*([A-Za-z0-9_.]+)\s*=\s*(.*?)\s*$")

#: property name -> PG_* conf key（与 ``Config.region_group_knobs`` 一一对应）
PG_PROP_KEYS: dict[str, str] = {
    "schema_region_group_extension_policy": "PG_SCHEMA_POLICY",
    "data_region_group_extension_policy": "PG_DATA_POLICY",
    "default_schema_region_group_num_per_database": "PG_MIN_SCHEMA_PER_DB",
    "default_data_region_group_num_per_database": "PG_MIN_DATA_PER_DB",
    "schema_region_per_data_node": "PG_SCHEMA_PER_DATA_NODE",
    "data_region_per_data_node": "PG_DATA_PER_DATA_NODE",
    "series_slot_num": "PG_SERIES_SLOT_NUM",
    "time_partition_interval": "PG_TIME_PARTITION_INTERVAL",
}

#: 可按 ``SET CONFIGURATION`` 热加载的键（``series_slot_num`` 首次启动确定，不可热更）
HOT_RELOAD_KEYS: tuple[str, ...] = (
    "schema_region_group_extension_policy",
    "data_region_group_extension_policy",
    "default_schema_region_group_num_per_database",
    "default_data_region_group_num_per_database",
    "schema_region_per_data_node",
    "data_region_per_data_node",
)


class CmpProps:
    """读写 ``iotdb-system.properties`` 里的 PROACTIVE 策略/配额键。"""

    def __init__(self, cfg, ssh, log) -> None:
        self.cfg = cfg
        self.ssh = ssh
        self.log = log
        self.db_dir = cfg.get("DB_DIR")
        self._resolved: dict[str, str] = {}

    def conf_path(self, host: str = "") -> str:
        """**探测**真正存在的配置文件路径（不假设）。"""
        if host in self._resolved:
            return self._resolved[host]
        script = "\n".join(
            f'[[ -f {shlex.quote(self.db_dir)}/{rel} ]] && echo {shlex.quote(self.db_dir)}/{rel}'
            for rel in CANDIDATE_FILES
        ) + "\nexit 0"
        res = self.ssh.run(host or self.cfg.cli_host, script, check=False)
        found = next((line.strip() for line in res.out.splitlines() if line.strip()), "")
        if not found:
            raise RuntimeError(f"{host}: 未找到 {self.db_dir}/conf 下的配置文件"
                               f"（试过 {', '.join(CANDIDATE_FILES)}）")
        self._resolved[host] = found
        return found

    def resolved_path(self, host: str = "") -> str:
        """探测到的真实配置文件路径（供证据/日志写明"读的是哪个文件"）。"""
        try:
            return self.conf_path(host)
        except Exception:  # noqa: BLE001 - 探测失败不拦用例，证据里写空
            return ""

    def read(self, host: str, keys: tuple[str, ...] | None = None) -> dict[str, str]:
        """读取该节点配置文件里的**生效**键值（注释行不算）。"""
        res = self.ssh.run(host, f"cat {shlex.quote(self.conf_path(host))} 2>/dev/null || true",
                           check=False)
        props: dict[str, str] = {}
        for line in res.out.splitlines():
            m = _ACTIVE_PROP.match(line)
            if m:
                props[m.group(1)] = m.group(2)
        if keys:
            return {k: props[k] for k in keys if k in props}
        return props

    def has_key(self, host: str, key: str) -> bool:
        """该键是否**显式**出现在文件里（用于"默认值路径"的取证）。"""
        return key in self.read(host)

    def write(self, updates: dict[str, str], *, hosts: list[str] | None = None) -> list[str]:
        """在每台节点上替换或追加键；返回被改动的节点列表。"""
        payload = "\n".join(f"{k}\t{v}" for k, v in updates.items())
        # UPG-1.3: 不写死 iotdb-system.properties —— 用探测到的真实文件名
        # （1.2 及更早是 iotdb-engine.properties；2.x 仍是 iotdb-system.properties，
        #  探测结果与旧行为一致）。
        script = f"""
set -e
f={shlex.quote(self.conf_path(hosts[0] if hosts else self.cfg.cli_host))}
[[ -f "$f" ]] || {{ echo "MISSING $f" >&2; exit 2; }}
if [[ -w "$f" ]]; then SUDO=""; else SUDO="sudo -n"; fi
while IFS=$'\t' read -r k v; do
  [[ -z "$k" ]] && continue
  if grep -qE "^[[:space:]]*#?[[:space:]]*${{k}}[[:space:]]*=" "$f"; then
    $SUDO sed -i -E "s|^[[:space:]]*#?[[:space:]]*${{k}}[[:space:]]*=.*|${{k}}=${{v}}|" "$f"
  else
    printf '%s=%s\n' "$k" "$v" | $SUDO tee -a "$f" > /dev/null
  fi
done <<'PG_PROPS'
{payload}
PG_PROPS
exit 0
"""
        touched: list[str] = []
        for host in (hosts or self.cfg.all_hosts):
            res = self.ssh.run_script(host, script, check=False)
            if res.rc != 0:
                raise RuntimeError(f"写 {self.resolved_path(host)} 失败 {host}: {res.text}")
            touched.append(host)
        return touched

    def remove_keys(self, keys: tuple[str, ...], *, hosts: list[str] | None = None) -> list[str]:
        """把指定键注释掉（= 恢复出厂默认；用于验证"未显式配置"的默认值路径）。"""
        pattern = "|".join(re.escape(k) for k in keys)
        # UPG-1.3: 同上 —— 用探测到的真实文件名，不写死
        script = f"""
set -e
f={shlex.quote(self.conf_path(hosts[0] if hosts else self.cfg.cli_host))}
[[ -f "$f" ]] || exit 0
if [[ -w "$f" ]]; then SUDO=""; else SUDO="sudo -n"; fi
$SUDO sed -i -E 's|^[[:space:]]*({pattern})[[:space:]]*=.*|#\\1|' "$f"
exit 0
"""
        touched: list[str] = []
        for host in (hosts or self.cfg.all_hosts):
            self.ssh.run_script(host, script, check=False)
            touched.append(host)
        return touched

    def write_from_cfg(self) -> list[str]:
        return self.write(self.cfg.region_group_knobs())
