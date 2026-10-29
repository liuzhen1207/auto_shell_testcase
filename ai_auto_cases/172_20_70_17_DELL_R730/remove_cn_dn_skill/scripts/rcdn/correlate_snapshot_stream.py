"""按 snapshotId 把"发送方快照位点"、"接收方装载"、"接收方首个收流索引"串成一条链。

这是唯一能证明/排除"新建副本永久少一段"的判据：

    firstStreamIndex > snapshotIndex + 1   -> 空洞：缺 (snapshotIndex+1 .. firstStreamIndex-1)
    firstStreamIndex <= snapshotIndex + 1  -> 无空洞（重叠/重复投递是安全方向）

为什么必须三方关联：接收端的 ``searchIndex`` 只是它自己 WAL 读到的位点，
**它并不知道自己被装载的快照覆盖到哪一条**，所以单看 "首包索引 vs 本地已应用+1"
会把每一次"快照 + 增量"的正常迁移都误报成缺口。

用法（需要先在 DN 上铺带 diagnostic 日志的构建）::

    PYTHONPATH=scripts python3 -m rcdn.correlate_snapshot_stream conf/cluster.diagnostic.conf [--raw DIR]

--raw DIR 改为读取本地已保存的日志文件（每行形如 ``<host>\t<line>``），便于离线复算。
"""

from __future__ import annotations

import pathlib
import re
import sys

RE_TAKEN = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})\s.*snapshot taken: region=(?P<region>\S+), dir=(?P<sid>snapshot_\S+?), "
    r"searchIndexAtSnapshot=(?P<S>-?\d+), minSyncIndex=(?P<min>-?\d+), pendingResume=\{(?P<pend>.*)\}"
)
RE_LOADED = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})\s.*snapshot loaded: region=(?P<region>\S+), snapshotId=(?P<sid>snapshot_\S+?), "
    r"folders=\d+, result=\S+, localSearchIndex=(?P<local>-?\d+)"
)
RE_BASE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})\s.*receive baseline: region=(?P<region>\S+), source=(?P<src>\d+), "
    r"incoming=\[(?P<first>\d+), (?P<end>\d+)\], localSearchIndex=(?P<local>-?\d+), "
    r"msSinceSnapshotLoad=(?P<ms>-?\d+)"
)


def parse(text: str) -> dict:
    out: dict = {"taken": [], "loaded": [], "base": []}
    for line in text.splitlines():
        for key, rx in (("taken", RE_TAKEN), ("loaded", RE_LOADED), ("base", RE_BASE)):
            m = rx.search(line)
            if m:
                out[key].append(m.groupdict())
                break
    return out


def collect(cfg, ssh) -> dict:
    data: dict = {"taken": [], "loaded": [], "base": []}
    hosts = getattr(cfg, "dn_hosts", None) or cfg.all_hosts
    for host in hosts:
        res = ssh.run(
            host,
            "grep -hE 'diagnostic.*(snapshot taken|snapshot loaded|receive baseline)' "
            f"{cfg.get('DB_DIR')}/logs/log_datanode_all.log",
            check=False,
        )
        part = parse(getattr(res, "out", "") or "")
        for key in data:
            for row in part[key]:
                row["host"] = host
            data[key].extend(part[key])
    return data


def collect_raw(root: pathlib.Path) -> dict:
    data: dict = {"taken": [], "loaded": [], "base": []}
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        for line in path.read_text(errors="replace").splitlines():
            host, _, body = line.partition("\t")
            part = parse(body if _ else line)
            for key in data:
                for row in part[key]:
                    row.setdefault("host", host if _ else path.name)
                data[key].extend(part[key])
    return data


def report(data: dict) -> int:
    by_sid: dict = {}
    for row in data["taken"]:
        resume = [int(x) for x in re.findall(r"\}=(-?\d+)", row["pend"])] or None
        row["resume"] = resume
        by_sid.setdefault(row["sid"], {"taken": None, "loaded": None, "base": None})["taken"] = row
    for row in data["loaded"]:
        by_sid.setdefault(row["sid"], {"taken": None, "loaded": None, "base": None})["loaded"] = row
    # 接收方：装载该 snapshotId 之后、同 region 的第一条收流基线
    for row in data["base"]:
        for entry in by_sid.values():
            loaded = entry["loaded"]
            if not loaded or loaded["region"] != row["region"] or loaded["host"] != row["host"]:
                continue
            if loaded["ts"] > row["ts"]:
                continue
            if entry["base"] is None or row["ts"] < entry["base"]["ts"]:
                entry["base"] = row

    holes = overlap = unknown = 0
    print("  snapshotId  region          发送方S  续传R   接收方   首包索引  判定")
    for sid, entry in sorted(by_sid.items()):
        taken, loaded, base = entry["taken"], entry["loaded"], entry["base"]
        if not taken:
            continue
        S = int(taken["S"])
        R = max(taken["resume"]) if taken["resume"] else None
        if loaded and base:
            first = int(base["first"])
            if first > S + 1:
                print(
                    f"  …{sid[-8:]}  {taken['region']:<15} {S:<8} {str(R):<7} "
                    f"{loaded['host']:<8} {first:<9} ★ 空洞: 缺 {first - S - 1} 条 [{S + 1}..{first - 1}]"
                )
                holes += 1
            else:
                print(
                    f"  …{sid[-8:]}  {taken['region']:<15} {S:<8} {str(R):<7} "
                    f"{loaded['host']:<8} {first:<9} 无空洞（重叠 {S + 1 - first} 条）"
                )
                overlap += 1
        else:
            print(
                f"  …{sid[-8:]}  {taken['region']:<15} {S:<8} {str(R):<7} {'—':<8} {'—':<9} "
                "接收方无对应装载/基线记录"
            )
            unknown += 1
    print(f"\n  ★ 确认空洞: {holes}    无空洞(重叠/相等): {overlap}    无法判定: {unknown}")
    return holes


def main(argv: list[str]) -> int:
    raw = None
    args = list(argv)
    if "--raw" in args:
        i = args.index("--raw")
        raw = pathlib.Path(args[i + 1])
        args = args[:i] + args[i + 2:]
    if raw is not None:
        data = collect_raw(raw)
    else:
        from rcdn.cli import _build, load_config

        cfg = load_config(pathlib.Path(args[0]) if args else None)
        _, _log, ssh, _sql = _build(cfg, "correlate", True)
        data = collect(cfg, ssh)
    print(f"  采集: 快照 {len(data['taken'])} / 装载 {len(data['loaded'])} / 收流基线 {len(data['base'])}")
    return report(data)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
