"""Match the benchmark build to the database version under test.

iot-benchmark ships one module per database version -- `iotdb-2.0` for the 2.x
line and `iotdb-1.3` for the 1.x line -- and the two are not interchangeable: the
module bundles the client libraries for its own line.  A build carrying only
`iotdb-2.0` will happily accept `DB_SWITCH=IoTDB-130-SESSION_BY_TABLET` in its
config file and then fail at connect time, because the 1.3 module simply is not
there.  That failure mode is why this module exists: the pairing is validated
before a run starts, not discovered halfway through one.

The version also decides what can be tested at all.  The table model (table and
writable-view workloads) only exists from 2.0, so a 1.x target tests the tree
model only.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

# Prebuilt releases and the source repository, for acquiring a benchmark build.
BENCHMARK_RELEASES_URL = "https://github.com/thulab/iot-benchmark/releases"
BENCHMARK_REPO_URL = "https://github.com/thulab/iot-benchmark"

_VERSION_RE = re.compile(r"(\d+)\.(\d+)(?:\.(\d+))?")


@dataclass(frozen=True)
class BenchmarkProfile:
    """The benchmark build and workload set that suit a database version."""

    line: str  # "2.x" or "1.x"
    module: str  # module directory name inside the benchmark's lib/
    db_switch: str
    default_workloads: tuple[str, ...]
    table_model: bool

    @property
    def switch_key(self) -> str:
        """The config key the module is selected with."""
        return "DB_SWITCH"


PROFILES: dict[str, BenchmarkProfile] = {
    "2": BenchmarkProfile(
        line="2.x",
        module="iotdb-2.0",
        db_switch="IoTDB-200-SESSION_BY_TABLET",
        # The table model exists from 2.0, so all three workloads apply.
        default_workloads=("tree", "table", "table_view"),
        table_model=True,
    ),
    "1": BenchmarkProfile(
        line="1.x",
        module="iotdb-1.3",
        db_switch="IoTDB-130-SESSION_BY_TABLET",
        # No table model in 1.x: tree data only.
        default_workloads=("tree",),
        table_model=False,
    ),
}


class VersionError(RuntimeError):
    """The database version could not be determined or is unsupported."""


def parse_db_version(text: str) -> tuple[int, int, int]:
    """Pull a version out of an arbitrary string.

    Handles the shapes that actually turn up: ``2.0.12.1``, a tarball name like
    ``timechodb-2.0.9.1-bin_rc4_202604151136.tar.gz``, an install directory like
    ``v20121rc2_0914_0b4dc9a``, and ``1.3.4``.  A four-part version keeps only
    the first three components, which is all the module choice needs.
    """
    match = _VERSION_RE.search(text or "")
    if not match:
        raise VersionError(f"no version found in {text!r}")
    return (int(match.group(1)), int(match.group(2)), int(match.group(3) or 0))


def detect_db_version(
    *,
    explicit: str = "",
    tarball: str = "",
    db_dir: str = "",
) -> str:
    """Decide which database version is under test.

    An explicit setting always wins.  Otherwise the release tarball name is the
    best evidence -- it names the build exactly -- and the install directory is
    the fallback.  Guessing would be worse than failing: the version decides both
    the benchmark module and whether the table model is testable at all.
    """
    if (explicit or "").strip():
        version = parse_db_version(explicit)
    else:
        for candidate in (tarball, db_dir):
            name = Path(candidate).name if candidate else ""
            if not name:
                continue
            try:
                version = parse_db_version(name)
                break
            except VersionError:
                continue
        else:
            raise VersionError(
                "cannot tell which database version is under test; set DB_VERSION "
                "(e.g. 2.0.12.1 or 1.3.4) -- it decides both the benchmark build "
                "and whether the table model can be tested"
            )
    major = version[0]
    if str(major) not in PROFILES:
        known = ", ".join(sorted(PROFILES))
        raise VersionError(
            f"unsupported database major version {major} (from {version[0]}.{version[1]}.{version[2]}); "
            f"known lines: {known}"
        )
    return f"{version[0]}.{version[1]}.{version[2]}"


def benchmark_profile(version: str) -> BenchmarkProfile:
    """The benchmark build and workloads that match ``version``."""
    major = parse_db_version(version)[0]
    if str(major) not in PROFILES:
        raise VersionError(f"unsupported database major version {major}")
    return PROFILES[str(major)]


def check_benchmark_home(bm_home: Path | str, profile: BenchmarkProfile) -> str | None:
    """Verify the benchmark build carries the module this version needs.

    Returns a problem description, or None when the build is usable.  A build
    with only ``iotdb-2.0`` will still *start* against a 1.x database and fail
    later, at connect time, in a way that looks like a cluster fault -- so the
    check is worth doing up front.
    """
    home = Path(bm_home)
    if not home.is_dir():
        return f"benchmark home {home} does not exist"
    lib = home / "lib"
    if not lib.is_dir():
        return f"benchmark home {home} has no lib/ directory"
    if not any(lib.glob(f"{profile.module}-*.jar")):
        present = sorted(p.name for p in lib.glob("iotdb-*.jar")) or ["(none)"]
        return (
            f"benchmark build at {home} has no {profile.module} module, so it cannot "
            f"test IoTDB {profile.line} (found: {', '.join(present)}). "
            f"Get a matching build from {BENCHMARK_RELEASES_URL} or build one from "
            f"{BENCHMARK_REPO_URL}"
        )
    return None


def restrict_workloads(
    requested: list[str], profile: BenchmarkProfile
) -> tuple[list[str], list[str]]:
    """Split ``requested`` into (usable, dropped-because-unsupported).

    Dropping is only correct for workloads the database line cannot serve at
    all.  A caller asking for the table model on 1.x gets it removed here *and*
    reported, rather than a benchmark run that fails on an unknown dialect.
    """
    if profile.table_model:
        return list(requested), []
    usable = [w for w in requested if w == "tree"]
    dropped = [w for w in requested if w != "tree"]
    return usable or ["tree"], dropped
