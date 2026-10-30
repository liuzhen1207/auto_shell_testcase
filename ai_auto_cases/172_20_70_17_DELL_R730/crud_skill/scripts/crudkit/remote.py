"""Remote execution and IoTDB SQL access.

Two concerns live here:

* :class:`SshRunner` - run commands (and stream scripts) on the cluster hosts,
  with either key-based auth or password auth through ``sshpass`` /
  ``SSH_ASKPASS``.
* :class:`SqlClient` - issue SQL through ``start-cli.sh``, either from a local
  IoTDB client install or from one of the cluster hosts, and parse the ASCII
  table the CLI prints.
"""

from __future__ import annotations

import atexit
import hashlib
import json
import os
import re
import shlex
import shutil
import socket
import tempfile
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from .config import Config, ConfigError

DEFAULT_TIMEOUT = 120

_TABLE_SEP = re.compile(r"^\+(?:[-+]+\+)+$")
_WARN_PREFIX = re.compile(r"^\s*\d+\s+\[[^\]]*\]\s+(WARN|INFO|DEBUG)\s")
_ERROR_MARKERS = re.compile(
    r"^(Msg:|Error:|.*\bIoTDBSQLException\b|.*\bStatementExecutionException\b|"
    r".*executeStatement failed|.*\bjava\.lang\.[A-Za-z]+Exception)"
)
# Phrases the CLI/benchmark print for a statement that was rejected.
SQL_ERROR_PATTERNS = (
    r"^Error:",
    r"IoTDBSQLException",
    r"StatementExecutionException",
    r"executeStatement failed",
    r"^Exception",
    r"java\.lang\.[A-Za-z]*Exception",
)

# IoTDB prints "Msg:" for both outcomes, so the prefix alone says nothing:
#   success -> "Msg: The statement is executed successfully."
#   failure -> "Msg: 305: The DataNode(s) to be removed [9] are not in the cluster"
_ERROR_WORDS = re.compile(
    r"(exception|error|failed|failure|not exist|not in the cluster|cannot|can't|"
    r"invalid|unsupported|denied|refused|no such|unknown|timeout|out of range|"
    r"already|conflict)",
    re.I,
)
_SUCCESS_WORDS = re.compile(r"(successfully|succeeded|\bsuccess\b)", re.I)


class RemoteError(RuntimeError):
    """A remote command failed."""

    def __init__(self, host: str, cmd: str, result: "Result"):
        self.host = host
        self.cmd = cmd
        self.result = result
        super().__init__(
            f"command failed on {host} (rc={result.rc}): {cmd}\n"
            f"--- stdout ---\n{result.out[-4000:]}\n--- stderr ---\n{result.err[-4000:]}"
        )


@dataclass
class Result:
    rc: int
    out: str
    err: str
    host: str
    cmd: str

    @property
    def ok(self) -> bool:
        return self.rc == 0

    @property
    def text(self) -> str:
        return self.out if self.out else self.err


class SshRunner:
    """Run commands on cluster hosts."""

    def __init__(self, cfg: Config, workdir: Path):
        self.cfg = cfg
        self.user = cfg.get("SSH_USER")
        self.port = cfg.get_int("SSH_PORT")
        self.mode = cfg.get("SSH_MODE")
        self.password = cfg.raw("SSH_PASSWORD")
        self.extra_opts = shlex.split(cfg.raw("SSH_EXTRA_OPTS"))
        self.workdir = workdir
        self._askpass: Path | None = None
        self._sshpass: str | None = None
        self._verbosity = 0
        self._control_dir: Path | None = None
        self._control_hosts: set[str] = set()
        if cfg.get_bool("SSH_MULTIPLEX"):
            self._enable_multiplex()
        if self.mode == "password":
            self._sshpass = shutil.which("sshpass")
            if self._sshpass is None:
                self._askpass = self._make_askpass()

    # -- auth plumbing -----------------------------------------------------
    def _make_askpass(self) -> Path:
        """Create a 0600 helper that echoes the password (OpenSSH >= 8.4)."""
        helper = self.workdir / ".ssh_askpass.sh"
        helper.parent.mkdir(parents=True, exist_ok=True)
        helper.write_text(
            "#!/bin/sh\nprintf '%s\\n' " + shlex.quote(self.password) + "\n",
            encoding="utf-8",
        )
        helper.chmod(0o700)
        return helper

    def _enable_multiplex(self) -> None:
        """Reuse one TCP connection per host instead of one per command.

        Every command used to be a fresh ssh handshake.  A case issues hundreds
        of them and the full matrix tens of thousands, all from the driver's IP,
        which looks exactly like a brute-force attempt: on the 3C5D rc2 run the
        cluster hosts' protection started refusing port 22 to the driver after
        ~12 cases.  A master connection per host removes that failure mode.

        The socket lives in a short, per-user, 0700 directory because
        ``ControlPath`` is a unix socket and the kernel caps its length.
        """
        key = hashlib.sha1(
            f"{self.user}@{self.port}:{self.cfg.get('DB_DIR')}".encode()
        ).hexdigest()[:12]
        directory = Path(tempfile.gettempdir()) / f"rcdn-ssh-{key}"
        try:
            directory.mkdir(parents=True, exist_ok=True)
            directory.chmod(0o700)
        except OSError:
            return  # no writable socket dir: fall back to one connection each
        self._control_dir = directory
        atexit.register(self.close)

    def _connection_opts(self, host: str, *, program: str, port_flag: str) -> list[str]:
        """Transport options shared by ``ssh`` and ``scp``.

        Both tools must use the *same* ControlPath or the file copy would open a
        second authenticated connection per host -- exactly the pattern that gets
        the driver's IP blocked during a long matrix run.
        """
        argv = [program, port_flag, str(self.port), "-o", "BatchMode=no"]
        argv += self.extra_opts
        if self._control_dir is not None:
            self._control_hosts.add(host)
            argv += [
                "-o", "ControlMaster=auto",
                "-o", f"ControlPath={self._control_dir}/%C",
                "-o", f"ControlPersist={self.cfg.get_int('SSH_CONTROL_PERSIST')}",
            ]
        return argv

    def _base_argv(self, host: str) -> list[str]:
        return [
            *self._connection_opts(host, program="ssh", port_flag="-p"),
            f"{self.user}@{host}",
        ]

    def upload(self, local: Path, host: str, remote_path: str, *, timeout: int = 7200) -> None:
        """Copy a local file to ``host``.

        Used to distribute a release tarball to hosts that do not have it.  The
        same authentication and multiplexing as ``ssh`` applies, so a password
        deployment needs no ``sshpass`` here either.
        """
        base = self._connection_opts(host, program="scp", port_flag="-P")
        target = f"{self.user}@{host}:{remote_path}"
        if self.mode == "password" and self._sshpass:
            argv = [self._sshpass, "-p", self.password, *base, str(local), target]
            env = dict(os.environ)
        else:
            argv = [*base, str(local), target]
            env = self._env_for_password() if self.mode == "password" else dict(os.environ)
        proc = subprocess.run(argv, env=env, capture_output=True, timeout=timeout)
        if proc.returncode != 0:
            raise RemoteError(
                host,
                " ".join(argv),
                Result(proc.returncode, "", proc.stderr.decode(errors="replace"), host, ""),
            )

    def close(self) -> None:
        """Tear down the multiplexed master connections (idempotent)."""
        if self._control_dir is None:
            return
        hosts, self._control_hosts = self._control_hosts, set()
        for host in hosts:
            argv = [
                "ssh", "-p", str(self.port),
                "-o", "BatchMode=yes",
                "-o", f"ControlPath={self._control_dir}/%C",
                "-O", "exit",
                f"{self.user}@{host}",
            ]
            try:
                subprocess.run(argv, capture_output=True, timeout=15)
            except (OSError, subprocess.SubprocessError):
                pass

    def _env_for_password(self) -> dict[str, str]:
        env = dict(os.environ)
        if self._askpass is not None:
            env["SSH_ASKPASS"] = str(self._askpass)
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env.setdefault("DISPLAY", ":0")
        return env

    def argv(self, host: str, remote_cmd: str) -> tuple[list[str], dict[str, str]]:
        if self.mode == "password" and self._sshpass:
            argv = [self._sshpass, "-p", self.password, *self._base_argv(host), remote_cmd]
            return argv, dict(os.environ)
        argv = [*self._base_argv(host), remote_cmd]
        if self.mode == "password":
            return argv, self._env_for_password()
        return argv, dict(os.environ)

    # -- public API --------------------------------------------------------
    def run(
        self,
        host: str,
        cmd: str,
        *,
        timeout: int = DEFAULT_TIMEOUT,
        check: bool = True,
        stdin: str | None = None,
    ) -> Result:
        argv, env = self.argv(host, cmd)
        if self._verbosity >= 1:
            print(f"    $ ssh {self.user}@{host} {cmd}")
        try:
            proc = subprocess.run(
                argv,
                input=stdin,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=env,
            )
        except subprocess.TimeoutExpired as exc:
            res = Result(rc=124, out=exc.stdout or "", err=f"timeout after {timeout}s", host=host, cmd=cmd)
            if check:
                raise RemoteError(host, cmd, res) from exc
            return res
        res = Result(rc=proc.returncode, out=proc.stdout or "", err=proc.stderr or "", host=host, cmd=cmd)
        if check and res.rc != 0:
            raise RemoteError(host, cmd, res)
        return res

    def run_script(
        self,
        host: str,
        script: str,
        *,
        timeout: int = DEFAULT_TIMEOUT,
        check: bool = True,
    ) -> Result:
        """Pipe ``script`` into a remote ``bash -s`` (no quoting hazards)."""
        return self.run(host, "bash -s", timeout=timeout, check=check, stdin=script)

    def stream_tar(
        self,
        host: str,
        remote_dir: str,
        local_tar: Path,
        *,
        timeout: int = 900,
        prefix: str = "",
    ) -> bool:
        """Stream ``tar -czf - <remote_dir>`` into ``local_tar``.

        ``prefix`` puts every archive entry under that directory name, which
        keeps identically-named logs from different hosts from colliding when
        the archives are extracted side by side.

        Returns False when the remote directory does not exist.
        """
        local_tar.parent.mkdir(parents=True, exist_ok=True)
        probe = self.run(host, f"test -d {shlex.quote(remote_dir)}", timeout=60, check=False)
        if not probe.ok:
            return False
        # Logs are still being appended to while we read them, so tar reports
        # "file changed as we read it" and exits 1.  That archive is still
        # perfectly usable; only exit 2 (a real error) is fatal.
        # Every host's logs directory contains identically-named files
        # (`log_confignode_all.log`, ...), so archives taken from different hosts
        # overwrite each other the moment they are extracted into one directory
        # -- which silently destroyed all but one node's logs during a real
        # investigation.  Prefix each entry with the host so extraction is safe.
        transform = "--transform " + shlex.quote("s,^\\.," + prefix + ",") if prefix else ""
        cmd = (
            f"tar --warning=no-file-changed --ignore-failed-read {transform} "
            f"-czf - -C {shlex.quote(remote_dir)} ."
        )
        argv, env = self.argv(host, cmd)
        with local_tar.open("wb") as fh:
            proc = subprocess.run(argv, stdout=fh, stderr=subprocess.PIPE, timeout=timeout, env=env)
        if proc.returncode > 1 or local_tar.stat().st_size == 0:
            local_tar.unlink(missing_ok=True)
            raise RemoteError(
                host,
                cmd,
                Result(proc.returncode, "", proc.stderr.decode(errors="replace"), host, cmd),
            )
        return True

    def ping(self, host: str, timeout: int = 15) -> bool:
        res = self.run(host, "echo rcdn-ok", timeout=timeout, check=False)
        return res.ok and "rcdn-ok" in res.out


class SqlError(RuntimeError):
    """The SQL client reported an error (the CLI exits 0 even on failure)."""

    def __init__(self, sql: str, output: str):
        self.sql = sql
        self.output = output
        super().__init__(f"SQL failed: {sql}\n{output[-2000:]}")


_CLIENT_UNREACHABLE = re.compile(
    r"(Connection Error|Can't execute sql|Connection refused|No route to host|"
    r"java: not found|Connection reset|connect timed out)",
    re.I,
)


def _client_unreachable(text: str) -> bool:
    """True when the client could not reach the cluster at all.

    Distinct from a rejected statement: this is what happens when the node the
    client runs on has just been stopped, and it is worth retrying elsewhere.
    """
    return bool(_CLIENT_UNREACHABLE.search(text))


def looks_like_sql_error(text: str) -> bool:
    """True when the CLI output reports a failure rather than a result.

    A bare ``Msg:`` line means nothing on its own; IoTDB uses it for successes
    too, so it is classified by its content.
    """
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("Msg:"):
            body = stripped[4:].strip()
            if _SUCCESS_WORDS.search(body):
                continue
            if re.match(r"^\d+\s*:", body) or _ERROR_WORDS.search(body):
                return True
            continue
        for pattern in SQL_ERROR_PATTERNS:
            if re.search(pattern, stripped):
                return True
    return False


def parse_table(text: str) -> list[dict[str, str]]:
    """Parse the ASCII table printed by the IoTDB CLI into rows of dicts."""
    lines = text.splitlines()
    header: list[str] | None = None
    rows: list[dict[str, str]] = []

    for line in lines:
        stripped = line.strip()
        if _TABLE_SEP.match(stripped):
            # +---+ separators surround the header and close the table body
            continue
        if not stripped.startswith("|"):
            if header is not None:
                # A non-'|' line ends the table body.
                break
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if header is None:
            header = cells
            continue
        if len(cells) != len(header):
            # Ragged row: pad/truncate so callers still get usable data.
            cells = (cells + [""] * len(header))[: len(header)]
        rows.append(dict(zip(header, cells)))
    return rows


class SqlClient:
    """Issue SQL through ``start-cli.sh``.

    ``local`` mode runs an IoTDB client installed on the driver machine.
    ``remote`` mode runs the CLI that ships with the cluster (``DB_DIR/sbin``)
    on :attr:`cli_host`, which avoids any client/server version mismatch.
    """

    def __init__(self, cfg: Config, ssh: SshRunner, workdir: Path):
        self.cfg = cfg
        self.ssh = ssh
        self.workdir = workdir
        self.db_dir = cfg.get("DB_DIR")
        self.user = cfg.get("DB_USER")
        self.password = cfg.get("DB_PASSWORD")
        self.cli_home = cfg.raw("CLI_HOME")
        self.local = bool(self.cli_home)
        self.rpc_port = cfg.dn_rpc_port
        self._outdir = workdir / "sql"
        self._outdir.mkdir(parents=True, exist_ok=True)
        self._local_cli = Path(self.cli_home) / "sbin" / "start-cli.sh" if self.local else None
        self._cli_prefix: str | None = None
        #: Set when `sql()` had to fall back to another host.
        self._last_failover: str | None = None

    # -- invocation --------------------------------------------------------
    def _cli_sudo_prefix(self) -> str:
        """Work out whether the client script needs `sudo -n` to find java.

        `start-cli.sh` resolves java from the environment.  On a cluster where
        java only lives in root's profile the login user gets "java: not found",
        so fall back to running the client as root.  Resolved once and cached.
        """
        if self._cli_prefix is not None:
            return self._cli_prefix
        mode = self.cfg.raw("CLI_SUDO", "auto").strip().lower()
        if mode in {"true", "yes", "1", "always"}:
            self._cli_prefix = "sudo -n "
            return self._cli_prefix
        if mode in {"false", "no", "0", "never"}:
            self._cli_prefix = ""
            return self._cli_prefix
        # auto: does the login user see java?
        res = self.ssh.run(
            self.cfg.cli_host,
            "command -v java >/dev/null 2>&1 && echo RCDN_JAVA_OK || echo RCDN_JAVA_NO",
            check=False,
        )
        if "RCDN_JAVA_OK" in res.out:
            self._cli_prefix = ""
            return self._cli_prefix
        probe = self.ssh.run(
            self.cfg.cli_host,
            "sudo -n bash -c 'command -v java' >/dev/null 2>&1 "
            "&& echo RCDN_SUDO_JAVA_OK || echo RCDN_SUDO_JAVA_NO",
            check=False,
        )
        if "RCDN_SUDO_JAVA_OK" in probe.out:
            self._cli_prefix = "sudo -n "
            return self._cli_prefix
        # Neither works; let it fail with the real error rather than guessing.
        self._cli_prefix = ""
        return self._cli_prefix

    def check_available(self) -> str:
        """Return a human readable description of where SQL will be issued from."""
        if self.local:
            if not self._local_cli or not self._local_cli.is_file():
                raise ConfigError(
                    f"CLI_HOME={self.cli_home} does not contain sbin/start-cli.sh on this machine. "
                    "CLI_HOME must point at an IoTDB install on the DRIVER machine; "
                    "leave CLI_HOME empty to run the cluster's own client over ssh."
                )
            return f"local client {self._local_cli}"
        prefix = self._cli_sudo_prefix()
        how = "as root via sudo -n" if prefix else f"as {self.user}"
        # A tarball unpacked without exec bits leaves start-cli.sh present but
        # unrunnable, which only surfaces much later as "command not found" in
        # the middle of a case.  Check now.
        probe = self.ssh.run(
            self.cfg.cli_host,
            f"cd {shlex.quote(self.db_dir)} && ls -l sbin/start-cli.sh",
            timeout=60,
            check=False,
        )
        text = (probe.out or "") + (probe.err or "")
        if "No such file" in text or not text.strip():
            raise ConfigError(
                f"DB_DIR={self.db_dir} has no sbin/start-cli.sh on {self.cfg.cli_host}. "
                "Point DB_DIR at an IoTDB install, or set CLI_HOME to one on this machine."
            )
        fields = text.split()
        if not text.lstrip().startswith("-") or "x" not in fields[0][1:]:
            raise ConfigError(
                f"{self.db_dir}/sbin/start-cli.sh is not executable on {self.cfg.cli_host} "
                f"(mode {fields[0] if fields else '?'}). "
                f"Fix it with: chmod +x {self.db_dir}/sbin/*.sh on every node."
            )
        return f"{self.db_dir}/sbin/start-cli.sh on {self.cfg.cli_host} ({how})"
    def _cli_argv(self, host: str, dialect: str | None, timeout: int, sql: str) -> str:
        if self.local:
            script = shlex.quote(f"{self.cli_home}/sbin/start-cli.sh")
        else:
            # The sudo prefix must stay OUTSIDE the quotes, otherwise the whole
            # string is looked up as one command name.
            script = f"{self._cli_sudo_prefix()}{shlex.quote('./sbin/start-cli.sh')}"
        parts = [script, "-h", shlex.quote(host), "-p", str(self.rpc_port), "-u", shlex.quote(self.user)]
        if self.password:
            parts += ["-pw", shlex.quote(self.password)]
        if dialect:
            parts += ["-sql_dialect", shlex.quote(dialect)]
        parts += ["-timeout", str(timeout), "-e", shlex.quote(sql)]
        return " ".join(parts)

    def _target_hosts(self, requested: str) -> list[str]:
        """Hosts to point the client at, in order of preference.

        The consistency sweep deliberately stops nodes, and whichever node the
        client targets may be the one that just went down.  Trying the other
        cluster members keeps the control channel alive; the client runs on the
        same host it connects to, which is what a human would do by hand.
        """
        hosts = [requested]
        for host in self.cfg.all_hosts:
            if host not in hosts:
                hosts.append(host)
        return hosts

    def sql(
        self,
        host: str,
        statement: str,
        *,
        dialect: str | None = None,
        timeout: int = 300,
        check: bool = True,
    ) -> str:
        cli = self._cli_argv(host, dialect, timeout, statement)
        if self.local:
            proc = subprocess.run(
                cli, shell=True, capture_output=True, text=True, timeout=timeout + 60
            )
            out = (proc.stdout or "") + (proc.stderr or "")
        else:
            out = ""
            targets = self._target_hosts(host)
            for index, target in enumerate(targets):
                attempt = cli if target == host else self._cli_argv(
                    target, dialect, timeout, statement
                )
                res = self.ssh.run(
                    target,
                    f"cd {shlex.quote(self.db_dir)} && {attempt}",
                    timeout=timeout + 60,
                    check=False,
                )
                out = res.out + res.err
                if not _client_unreachable(out):
                    break
                if index + 1 == len(targets):
                    break
                self._last_failover = target
        if check and looks_like_sql_error(out):
            raise SqlError(statement, out)
        return out

    def sql_file(self, host: str, statement: str, name: str, *, dialect: str | None = None, timeout: int = 300) -> str:
        out = self.sql(host, statement, dialect=dialect, timeout=timeout, check=False)
        (self._outdir / f"{name}.out").write_text(out, encoding="utf-8")
        return out

    # -- convenience queries ----------------------------------------------
    def show_datanodes(self, host: str) -> list[dict[str, str]]:
        return parse_table(self.sql(host, "show datanodes;"))

    def show_confignodes(self, host: str) -> list[dict[str, str]]:
        return parse_table(self.sql(host, "show confignodes;"))

    def show_cluster(self, host: str) -> list[dict[str, str]]:
        return parse_table(self.sql(host, "show cluster;"))

    def show_regions(self, host: str, database: str | None = None, dialect: str | None = None) -> list[dict[str, str]]:
        stmt = f"show regions from {database};" if database else "show regions;"
        return parse_table(self.sql(host, stmt, dialect=dialect))

    def show_migrations(self, host: str, dialect: str | None = None) -> tuple[list[dict[str, str]], bool]:
        """Return (rows, empty). ``empty`` is True when the CLI printed 'Empty set.'"""
        raw = self.sql(host, "show migrations;", dialect=dialect, check=False)
        if "Empty set" in raw:
            return [], True
        rows = parse_table(raw)
        return rows, not rows


def probe_port(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def http_get_json(url: str, *, user: str = "", password: str = "", timeout: int = 30) -> dict:
    """Minimal dependency-free GET returning parsed JSON."""
    import base64
    import urllib.error
    import urllib.parse
    import urllib.request

    request = urllib.request.Request(url)
    if user:
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        request.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", errors="replace"))
    except urllib.error.URLError as exc:  # pragma: no cover - network dependent
        raise RuntimeError(f"HTTP GET {url} failed: {exc}") from exc


def http_get_text(url: str, *, user: str = "", password: str = "", timeout: int = 30) -> str:
    """Minimal dependency-free GET returning the raw body as text."""
    import base64
    import urllib.error
    import urllib.request

    request = urllib.request.Request(url)
    if user:
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        request.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except urllib.error.URLError as exc:  # pragma: no cover - network dependent
        raise RuntimeError(f"HTTP GET {url} failed: {exc}") from exc


def wait_until(predicate, *, timeout: int, interval: int = 5, on_poll=None) -> bool:
    """Poll ``predicate`` until true or ``timeout`` seconds elapse."""
    deadline = time.time() + timeout
    while True:
        if predicate():
            return True
        if time.time() >= deadline:
            return False
        if on_poll:
            on_poll()
        time.sleep(interval)


def strip_blank(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if line.strip())


def first_line(text: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""


def uniq(seq: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for item in seq:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def tail(path: Path, limit: int = 40) -> str:
    if not path.is_file():
        return "<missing>"
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return "\n".join(lines[-limit:])
