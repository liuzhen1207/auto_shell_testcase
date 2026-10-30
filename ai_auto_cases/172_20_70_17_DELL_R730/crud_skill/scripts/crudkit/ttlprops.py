"""The TTL knobs on every node.

``ttl_check_interval`` / ``max_expired_time`` / ``expired_data_ratio`` / ``default_ttl_in_ms``
are **not** hot-reloadable (设备粒度 TTL（新）.txt §2.4), so a case that needs a smaller
interval has to rewrite the file and restart.

Note on the file name: the design documents say ``iotdb-common.properties``, but that is the
1.x name -- the 2.0.12.1 package ships only ``conf/iotdb-system.properties`` (plus a
config-node/datanode shell wrapper).  The path is therefore *probed* on the host instead of
assumed: writing the knobs into a file the node never reads would silently leave the defaults
in place and make a TTL case look like a product failure.
"""
from __future__ import annotations

import shlex

TTL_KEYS = ("ttl_check_interval", "max_expired_time", "expired_data_ratio", "default_ttl_in_ms")
AUDIT_KEY = "auditable_control_event_type"
CANDIDATE_FILES = ("conf/iotdb-system.properties", "conf/iotdb-common.properties")


class TtlProps:
    def __init__(self, cfg, ssh, log) -> None:
        self.cfg = cfg
        self.ssh = ssh
        self.log = log
        self._resolved: dict[str, str] = {}

    def conf_path(self, host: str = "") -> str:
        """Absolute path of the properties file that really exists on ``host``."""
        base = self.cfg.raw("DB_DIR")
        if not host:
            return f"{base}/{CANDIDATE_FILES[0]}"
        if host in self._resolved:
            return self._resolved[host]
        chosen = f"{base}/{CANDIDATE_FILES[0]}"
        for rel in CANDIDATE_FILES:
            res = self.ssh.run(host, f"test -f {shlex.quote(base)}/{rel} && echo yes",
                               timeout=60, check=False)
            if "yes" in (res.out + res.err):
                chosen = f"{base}/{rel}"
                break
        self._resolved[host] = chosen
        self.log(f"    {host}: TTL 参数文件 = {chosen}")
        return chosen

    def read(self, host: str, keys: tuple[str, ...] = TTL_KEYS + (AUDIT_KEY,)) -> dict[str, str]:
        path = self.conf_path(host)
        pattern = "|".join(f"^{k}=" for k in keys)
        cmd = f"grep -E {shlex.quote(pattern)} {shlex.quote(path)} || true"
        res = self.ssh.run(host, cmd, timeout=60, check=False)
        out: dict[str, str] = {}
        for line in (res.out + res.err).splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            out[key.strip()] = value.strip()
        return out

    def write(self, updates: dict[str, str], *, hosts: list[str] | None = None) -> list[str]:
        """Replace or append each key on every host; returns the hosts touched."""
        if not updates:
            return []
        touched = []
        for host in (hosts or self.cfg.all_hosts):
            path = self.conf_path(host)
            script_lines = [f"f={shlex.quote(path)}", 'touch "$f"']
            for key, value in updates.items():
                script_lines += [
                    f"if grep -qE '^{key}=' \"$f\"; then",
                    f"  sed -i -E 's|^{key}=.*|{key}={value}|' \"$f\"",
                    "else",
                    f"  printf '%s\\n' '{key}={value}' >> \"$f\"",
                    "fi",
                ]
            script_lines.append(f"grep -E '^({'|'.join(updates)})=' \"$f\"")
            res = self.ssh.run(host, "\n".join(script_lines), timeout=120, check=False)
            if res.ok:
                touched.append(host)
                self.log(f"    props {host}: " + " ".join((res.out + res.err).split())[:160])
            else:
                self.log(f"    props {host}: FAILED {(res.out + res.err)[:200]}")
        return touched

    def set_audit_event(self, events: list[str]) -> list[str]:
        """Write ``auditable_control_event_type`` on the ConfigNodes.

        The live whitelist is read by the ConfigNode when it validates a control event, so
        this is the node that has to carry the key; it is written on every ConfigNode host so
        a failover does not change the answer.
        """
        return self.write({AUDIT_KEY: ",".join(events)}, hosts=self.cfg.cn_hosts)
